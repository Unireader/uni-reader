# SEMANTIC-SYNC-PLAN.md — 块向量经服务器同步 + 安卓语义搜索

> 2026-11-16 开工。前置实测在 `SEARCH-PLAN.md §5.5`（Q8_0 查询向量与 MLX bf16 检索效果一样；Pad 6 一条查询 85~128 ms）。
> 本文是三端（Mac / 服务器 / 安卓）的方案；线格式落地时写进 `PROTOCOL.md §9.7`（跨端契约，以那里为准）。

## 0. 已定（用户 2026-11-16）

| 项 | 决定 |
|---|---|
| 分工 | 安卓**不计算、不更新**块向量，只在搜索时算查询向量 |
| 块向量来源 | Mac 算好，**经服务器同步**给安卓（补上服务器同步） |
| 安卓推理 | llama.cpp + 官方 GGUF Q8_0（`Qwen/Qwen3-Embedding-0.6B-GGUF`），只用 CPU 4 线程 |

范围：只对**服务器工作区**生效（本地工作区没有服务器可同步，安卓上照旧只有关键词）。
只同步本机模型（`vec.model` 以 `local|` 开头）的向量；OpenAI 兼容接口算的向量不上传（安卓没法用同一个接口算查询，见 §6）。

## 1. 关键设计：按正文内容寻址，不按块 id

Mac 索引里向量挂在 `chunk.id` 上，id 是本机自增、别的设备没有意义。所以同步的单位是：

```
键 = (模型标识, SHA-256(块正文的 UTF-8 字节))     值 = Int8 × 维数（与 Mac 索引里 vec.v 同一份字节：单位向量 ×127 取整）
```

- **块正文** = `chunk.body` 原文（截到 1500 字之前的那份；Mac `SearchIndex.embedInput` 再截，块一般不到 500 字，截断只影响极少数块）。
- 安卓搜索时现场切块（`WorkspaceSearch`，已照抄 Mac 的 `SearchText`），对每块正文算 SHA-256 去查向量：**查到就参与语义排序，查不到就只参与关键词**。
  两端切出来的正文不一样（例如某页安卓没有 OCR、用了 PDF 文字层）就是查不到，不会挂错块——这是按内容寻址的好处，不需要两端块 id 对齐。
- 同一段正文不管出现在哪本书、哪一页，只存一份向量；正文改了就是新键，旧键成了没人用的「孤儿」，靠 §3.4 清理。
- 不需要合并与冲突处理：同一个键的值只取决于模型与正文，谁先传都一样（MLX 与 llama.cpp 的细微差别不影响排序，`SEARCH-PLAN.md §5.5`）。

🔴 **算哈希的正文必须两端逐字一致**：安卓 `SearchText` 与 Mac 已是「同一算法两份实现」（`ANDROID-AGENT-PLAN.md §5.6`），
此后切块规则一改，向量就全部对不上（不会错，只会查不到）——改切块时两边一起改，并在 §7 的命中率测试里看出来。

## 2. 服务器

### 2.1 存哪

`<数据目录>/vectors/<workspace_id>.sqlite`，与 `workspaces/` 并列，**不进工作区包**：
派生数据，不进备份、不进快照、不随「下载为本地工作区」导出；删掉只是让 Mac 重传一遍。删除工作区时一起删（派生数据，不走回收站，红线⑪管的是用户数据）。

```sql
CREATE TABLE vec(
  model TEXT NOT NULL, hash BLOB NOT NULL,   -- hash = 32 字节 SHA-256
  v BLOB NOT NULL, rev INTEGER NOT NULL,
  PRIMARY KEY(model, hash)) WITHOUT ROWID;
CREATE INDEX vec_rev ON vec(model, rev);
CREATE TABLE meta(key TEXT PRIMARY KEY, value TEXT NOT NULL);   -- head（最大 rev）、epoch（每次清理换一个新随机串）
```

### 2.2 接口（都要令牌；请求体 / 响应体二进制，格式见 §5）

| 接口 | 用途 |
|---|---|
| `POST /v1/workspaces/:ws/vectors/missing` | 体 = 一组哈希（某模型）→ 回服务器**没有**的那些，外加服务器上这个模型的总条数 |
| `POST /v1/workspaces/:ws/vectors` | 上传一批（某模型、维数、若干 哈希+向量）；已有的跳过；每条新的 `rev = head+1` |
| `GET /v1/workspaces/:ws/vectors?model=&since=&epoch=&limit=` | 增量拉取 `rev > since`，按 rev 排；`epoch` 与服务器不同 → 从头给（并在响应里带新 epoch） |
| `POST /v1/workspaces/:ws/vectors/prune` | 体 = 某模型**仍在用**的全部哈希 → 删掉这个模型其余的条目，换新 epoch |

单次上传 / 拉取上限 2000 条（约 2 MB）。响应走 gzip（与快照同）。

## 3. Mac

### 3.1 何时上传

服务器工作区 + 语义搜索开着 + 模型是本机模型时：

- 一轮向量算完（`SearchIndex.embedAll` 结束）后；
- 打开工作区、索引建完且向量齐了之后（补上次没传完的）；
- 不跟着行同步的 2 秒节奏走：向量是成批出来的，上一轮还在传就跳过。

### 3.2 怎么传

1. 读出 `vec.model = 当前模型` 的全部 `(chunk.body, vec.v)`，算 SHA-256（7000 块约几十毫秒；去重）。
2. `missing` 问服务器缺哪些（7000 个哈希 = 224 KB），只传缺的，每批 2000 条。
3. 断网 / 出错：停下，下次再来（内容寻址，重传不会出错）。
4. 不在本机记「传过哪些」：每次靠 `missing` 对账，省掉一张要维护的表（`SearchIndex` 表结构不动，`schemaVersion` 不加，免得全部向量重算）。

### 3.3 清理孤儿

`missing` 的响应带服务器上这个模型的总条数 N。本机索引**建完且向量齐**、而 N 比本机去重后的条数多 30% 以上时，发一次 `prune`（全部在用的哈希）。
只有「索引完整」的设备才许清理，否则会把别处还在用的删掉。多台 Mac 同时用同一个服务器工作区时，各自的索引内容相同（同一份同步数据），不会互删。

## 4. 安卓

### 4.1 本机向量缓存

`<应用私有目录>/search-vec/<workspace_id>.sqlite`：`vec(hash PRIMARY KEY, v)` + `meta(model, epoch, since)`。派生数据，不进 `library.sqlite`、不进备份。

- 何时拉：服务器同步一轮结束后（语义搜索开着且模型文件已就位时）；增量，通常几条到几百条。
- `epoch` 变了：清空本地表，从 `since = 0` 重拉。
- 模型标识只认常量 `local|Qwen3-Embedding-0.6B@97b0c614`（与 Mac `LocalEmbeddingModel` 同一个）。Mac 换了模型而安卓没跟上：服务器上没有这个模型的向量 → 退回关键词，并说明原因。

### 4.2 搜索（照 Mac `MCPTools+Search.swift` 的混合那一路）

1. 关键词照旧（`WorkspaceSearch.keyword`）。
2. 语义：查询加任务说明 `Instruct: Given a web search query, retrieve relevant passages that answer the query\nQuery:` → llama.cpp 算向量 →
   量化成 Int8 → 与「本次切出的块里查得到向量的那些」逐个点积 → 取前 300。
   块的哈希随 `WorkspaceSearch` 现有的按书缓存一起缓存（PDF 部分已按 OCR 指纹缓存）；向量表整份读进内存（7000 条约 7 MB），表一变作废。
3. 合并：倒数排名融合 k = 60，参数与 Mac 一致；`mode`（auto / keyword / semantic / hybrid）语义照 Mac。
4. Agent 工具 `search` 的返回里带 `semantic{enabled, vectors, matched, error}`：`matched` = 本次切出的块里查到向量的块数，命中率低就是两端切块不一致。

### 4.3 推理

- llama.cpp 钉在 Mac 实测同一提交（`b1b770d90`，build 12359），只编 `arm64-v8a`，`-march=armv8.2-a+dotprod+fp16`，无 OpenMP。
- 一个很薄的 JNI 封装（`load(path, threads) / embed(text): FloatArray / unload()`），上下文 `n_ctx = 512`、一段、`pooling = last`、取出后归一化；
  末尾的 `<|endoftext|>` 由 llama.cpp 按 GGUF 元数据自动补（已实测，`SEARCH-PLAN.md §5.5`）。
- 用到时才加载（约 1 秒），闲置 2 分钟卸载；开着权重重排（查询快 70%，多占约 0.4 GB）。
- 模型文件：Q8_0（639 MB）放 `<应用私有目录>/models/`，设置里下载（Hugging Face / hf-mirror.com，钉提交、按 SHA-256 校验、断点续传，照 Mac `LocalModelDownloader`），
  也可以自己放文件（`adb push` 后点「检查文件」）。

### 4.4 设置

设置里「搜索」一节：「同时按意思搜索」开关、模型一行（未下载 / 下载进度 / 已就位 + 删除）、向量一行（本工作区已同步多少条、上次出错）。中英两套文案。

## 5. 线格式

已落地：**以 `PROTOCOL.md §9.7` 为准**（`VecHashes` / `VecMissing` / `VecPut` / `VecPage` 四种消息 + 四个接口），
Swift `Sources/Sync/SyncVecWire.swift`，跨端向量 `vec_*` 五条追加在 `spike/sync-wire-vectors.txt`。

## 6. 不做 / 以后

- 安卓本地工作区（没连服务器）的语义搜索：需要平板自己算全部块向量（整库 1.5~2.5 小时），不做。
- OpenAI 兼容接口的向量：安卓已有 OpenAI 兼容客户端（Agent 用），以后可以「查询也走同一个接口」，那时再同步 `openai|…` 的向量。
- 第二台 Mac 直接拉向量、省掉本机重算：同一套接口就能做，本期不做。
- iQOO 15：同一套代码，速度只会更快；NPU 不用。

## 7. 验证

- 服务器：`swift test` 加向量库的增删拉 + epoch + 线格式；`spike/server-client-test.sh` 加 Mac 上传 → 拉取。
- 线格式：Mac `spike/sync-wire-test.swift` 与安卓 `SyncWireTest` 比对新增的三条消息。
- 命中率：同一个工作区，安卓切出的块里查到向量的比例（期望 PDF OCR 页、笔记、批注接近 100%；只有文字层的页会低）。
- 效果：安卓上拿 `SEARCH-PLAN.md` 那 33 条换说法的问题（Agent 的 `search` 工具）对比 Mac。
- 实测清单（用户在平板上）：开语义搜索 → 下载模型 → 同步后「已同步向量」数对上 Mac → 换个说法搜 → 结果里混进意思相近的段落；搜索不卡界面。

## 8. 实现记录

### 8.1 2026-11-16：线格式 + 服务器 + Mac 上传

- **线格式**：`Sources/Sync/SyncVecWire.swift`（`SyncWire` 的扩展；`Reader.fixed` / `Writer.raw` 两个小方法加在 `SyncWire.swift`），
  契约 `PROTOCOL.md §9.7`；`spike/sync-wire-test.swift` 追加 `vec_*` 五条（26 项全过，原有向量一字未变）。
- **服务器**：`server/Sources/UniServerCore/WorkspaceVectors.swift`（每个工作区一个 `vectors/<id>.sqlite`，字节进字节出的 public 接口给 HTTP 层），
  `WorkspaceHost.vectors(_:)`（工作区必须存在；删除工作区时关掉并删文件，`closeAll` 也关），路由在 `ServerApp.swift`。
  测试：`VectorsTests`（去重、维数不同拒收、分页、清理换 epoch、坏请求体 400、随工作区删除）+ `HTTPTests.testVectors`；`swift test` 59 项全过；Linux 交叉编译通过。
- **Mac**：`SearchIndex.vectorSignature()`（本机模型向量条数 + 最大块 id + 是否算齐，一条 COUNT）/ `vectorExport()`（按正文 SHA-256 去重）；
  `Sources/ServerSync/ServerVectorSync.swift`（问缺哪些 → 每批 2000 条上传 → 算齐且服务器多出 30% 以上才清理）；
  `ServerSyncCoordinator` 的会话每 60 秒看一次指纹，变了才传（日志前缀 `[SYNC-VEC]`）；服务器太旧（不带说明的 404/405）本次会话不再试。
  `ServerClient` 加 `vectorsMissing` / `putVectors` / `pruneVectors` / `vectorPage`（最后一个只给测试用）。
- **端到端**：`spike/server-client-test.swift` 加 ⑪（2500 条跨批上传、再传只传缺的、分页拉全、清理后旧 epoch 从头给）：本机服务器 102 项全过，
  **NAS 上的 Linux 版 102 项全过**（注意：远端模式会先交叉编译，交叉编译会构建网页要 `npm`，从非登录 shell 跑找不到 `npm`，用 `zsh -lc`）。
- 未实测：用户真实的服务器工作区里 Mac 真的把向量传上去（打开工作区、语义搜索开着、算齐之后约 1 分钟内，日志看 `[SYNC-VEC]`）。

### 8.2 2026-11-16：安卓（只算查询向量，块向量从服务器拉）

文件都在 `android/`（独立仓库）：

- **推理（llama.cpp 预编译 .so）**：`native/embed_jni.cpp`（JNI 薄封装：`nativeLoad / nativeEmbed / nativeUnload`，n_ctx 512、一段、pooling last、开着权重重排、取出后 L2 归一化；
  文字按 UTF-8 字节传，超过 512 token 只留前 512、最后一位换回结尾记号）+ `native/CMakeLists.txt` + `native/exports.map`（只导出 `Java_…EmbedNative_*`）。
  `native/build-embed.sh`：llama.cpp 浅拉到仓库根 `build/llama-embed-src`（钉 `b1b770d90…`）、NDK 30.0.16248370 + Homebrew cmake / ninja、
  `ANDROID_PLATFORM=android-26`（= minSdk，编得过、用到的 libc 符号 26 里都有）、`-march=armv8.2-a+dotprod+fp16`、`c++_static`、无 OpenMP，
  链成一个 `libunireader_embed.so`（strip 后 4.7 MB，依赖只有 liblog / libm / libdl / libc），放 `app/src/main/jniLibs/arm64-v8a/`、**提交进仓库**，Gradle 构建不碰 native。
- **Kotlin**（`app/src/main/java/com/xvan/unireader/local/search/`）：
  `EmbedNative`（JNI）、`QueryEmbedder`（一条线程串行；用到时载入约 0.6 秒，闲置 2 分钟卸载；查询前加任务说明）、
  `EmbedModel`（模型常量：`Qwen/Qwen3-Embedding-0.6B-GGUF` 提交 `370f27d7…`、639,150,592 字节、SHA-256 `06507c7b…e439`；
  放 `/sdcard/Android/data/<包名>/files/models/`——`adb push` 进得去；下载照 Mac `LocalModelDownloader`：`.part` + Range 续传、下完验 SHA-256，Hugging Face / hf-mirror.com 可选，走系统代理；「检查文件」验大小 + SHA-256）、
  `Semantic`（纯规则：模型标识 / 查询前缀常量、正文 SHA-256、Int8 量化（按 Float 算、远离零舍入，与 Swift `rounded()` 一致）、点积排序取前 600 再按页 / 段去重、倒数排名融合 k = 60；JVM 单测 `SemanticTest`）、
  `SemanticVectors`（开关 + 本机缓存 `<noBackupFilesDir>/search-vec/<服务器工作区 id>.sqlite` 的 `vec` / `meta(model, epoch, since)` + 增量拉 + 整份读进内存，表一变作废）、
  `SemanticSearchSheet`（设置：开关 / 模型一行 / 本工作区已同步条数与上次出错；入口 Agent 面板 ⋯「搜索设置…」）。
  `WorkspaceSearch.SearchChunk.hashHex`（懒算，PDF 的块随 OCR 块缓存一起留着）；`dedupeKey` 抽出来给去重与合并共用。
- **线格式**：`local/server/SyncWire.kt` 加 `VecHashes / VecMissing / VecPut / VecPage` 编解码；`SyncWireTest` 比对 `vec_*` 五条 + 解出字段 + 截断解不出。
- **何时拉**：`ServerSync` 完整一轮成功后、开着时拉到行之后（`SemanticVectors.pullAsync`，同一工作区默认至少隔 20 秒）；设置页打开开关 / 模型刚就位时立即拉；
  搜索时离上次超过 5 分钟顺带拉（不等）。服务器回 404 / 405 → 记为不支持，只用关键词。
- **搜索**：Agent `search` 多一个 `mode`（auto / keyword / semantic / hybrid，语义照 Mac）；返回文字末尾一行
  `semantic: {"enabled", "vectors", "matched", "error"}`；只对服务器工作区、开关开着、模型就位时走语义一路。

验证：

- `./gradlew assembleDebug test`：257 项全过（含 `SyncWireTest` 5 项、`SemanticTest` 4 项）；APK 里带 `lib/arm64-v8a/libunireader_embed.so`。
- `llvm-nm -D`：只导出三个 `Java_com_xvan_unireader_local_search_EmbedNative_*`。
- 平板（小米 Pad 6）：`native/check/pad-check.sh`（app_process 经 JNI 直接调这个 .so，与同一台平板上 `/data/local/tmp/embed/llama-embedding` 同一条查询比）：
  q00 / q13 / q37 余弦都是 1.000000；载入约 610 ms，一条查询 98~137 ms。

还没验证：

- 安卓对着真服务器拉向量（没有跑会清数据的插桩测试；拉取代码只经编译 + 线格式向量验过）、命中率（`matched` / 切出的块数）、
  33 条换说法的问题与 Mac 对比、App 里真的走一遍（下载模型 → 同步 → 搜索），都待用户在平板上实测（§7 实测清单）。
- 模型下载放在进程内线程里（不是前台服务）：退到后台被系统杀掉时下一次接着下（断点续传），没做通知。
