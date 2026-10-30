# 笔迹点集改存二进制（schema v18）

> 状态：**已实现，待用户实测**（2026-09-26）。两端（Mac + 安卓模式1）同一次改；schema 是两端共同的契约。
> 用户定（2026-09-26，第二轮）：**默认就把 JSON 点清掉，不留兼容副本、不弹确认、不备份**。
> 第一轮做过「兼容模式 + 手动清理 + 先备份」，用户实测清理后打开很快，随即改成默认，那套代码已删（§10）。

## 1. 为什么

安卓模式1 打开一篇 1640 条 / 16.8 万点的画板，光解析笔迹 payload 就 1.1s（已经是手写扫描点集的快路径；剩下的时间几乎全在
「十进制文本 → 浮点」：点是 Float，经 Double 写成 17 位小数，一个数约 2µs）。点集改成原样的 float32 字节，读就是一次内存拷贝。
体积顺带减半以上：文本一个点约 25~55 字节，二进制 12 字节。

## 2. 存储

- `note` 与 `board_item` 各加两列（新库在 `CREATE TABLE` 里就有；老库 `ADD COLUMN`，可空）：
  - `points BLOB` —— 点集。格式：`u8 版本 = 1` + n ×（`f32 x` `f32 y` `f32 z`），小端，n = (长度 − 1) / 12。
    坐标系与 payload 里 JSON `points` 原来的语义完全相同（页内归一化 / 画布坐标 / 分页画板的页内坐标），只换编码。
  - `points_at TEXT` —— 写 `points` 那一刻这一行的 `updated_at`。用来判断二进制是不是最新的（见 §3）。
- payload（JSON）照旧存颜色 / 线宽 / 笔型 / 图层 / padId / page；`points` 键保留但写成 `[]`。
- `schema_version` → 18。

## 3. 读：以哪份为准

旧版 App 不认识新列：它改一条笔迹时只改 payload 里的 `points` 并刷新 `updated_at`，新列原样留着——二进制就过期了。
离线镜像合并、旧版写进来的行也可能只有 JSON 点。规则（两端同一份：Mac `InkStrokePayload.read`、安卓 `InkPayload.readStroke`）：

1. `points` 非空 且 `points_at == updated_at`（原始字符串相等）→ 用二进制；
2. 否则 payload 里有非空 `points` → 用 JSON；
3. 否则 `points` 非空 → 用二进制；
4. 都没有 → 空笔迹。

## 4. 写

每次写笔迹：写 `points` + `points_at = updated_at`，payload 里的 `points` 摘成 `[]`。
摘除集中在存储层的一处（Mac `LibraryStore.inkPayloadForWrite`、安卓同名），两个 upsert 都经过；上层照旧产出带点的完整 JSON
（剪贴板 `InkClipboard` 用 `toNote().payload`，那条要带点）。

## 5. 打开工作区时整理（后台）

找出「二进制缺失 / 过期，或 payload 里还带 JSON 点」（`payload LIKE '%"points":[[%'`）的笔迹行，一行一次写好：
- 二进制有效 → 以二进制为准，只摘 JSON 点；
- 否则 → 以 JSON 点为准，编成二进制并摘掉。

`updated_at` 不动（`points_at` 仍等于它）。按 id 翻页、每批一个事务、写时再核一次 `updated_at`；可中断、可重入。
Mac 走后台线程（`WorkspaceManager.startInkPointsCompaction`），安卓一批一个 `StoreQueue` 任务（`compactInkPointsStep`，用户落笔可以插队）。

⚠️ 代价（用户已知并接受）：整理后，**没更新的旧版 App 打开这个工作区，笔迹是空的**。

## 6. 离线镜像 / 回收站 / 剪贴板

- 指纹：新两列不进指纹（列表与跨端向量不改）。整理改了 payload（摘点），指纹会变——两边各自整理完字节相同
  （摘除只替换 `"points":[…]` 那一段，别处一个字节不动），三方合并里「两边改成同一个值」不冲突；只有一边整理了，就按普通改动带过去。
  合并按两边库的列取交集写，新列自动带过去。
- 回收站：快照 `SELECT *` 带上新列，恢复按快照列名 `INSERT`。
- 剪贴板：见 §4。

## 7. 验证

- Mac `spike/ink-blob-test.swift`：编解码与跨端向量、新写的行不带 JSON 点、旧版改过后判过期读 JSON、整理（老行 / 旧版改过的 /
  兼容模式留下的三种）、可重入、画板分页坐标。跨端向量 `spike/ink-blob-vectors.txt`（安卓 `InkPointsBlobTest` 读同一份）。
- 真机：「英语草稿纸」打开时间。

## 8. 相关文档

`REQUIREMENTS.md §8`（v18）、`INK-PAGING-PLAN.md`（原「不做二进制 payload」约束的注记）、`OFFLINE-MIRROR-PLAN.md §3.3`、`android/AGENTS.md`。

## 10. 实现记录（2026-09-26）

- **Mac**：编解码 `Sources/Store/InkPointsBlob.swift`；`InkPayloadFast` 从 `InkModel.swift` 挪到 `Sources/Store/InkPayloadFast.swift`
  （存储层的整理要用，而存储层不依赖 App 层；点类型写 `SIMD3<Float>` = `InkPoint`），加了 `stripPoints`。
  整理 `LibraryStore.compactInkPoints`（JSON 点读取由 App 层传入带 `JSONDecoder` 兜底的 `InkStroke.jsonPoints`）。
- **安卓模式1**：`local/store/InkPointsBlob.kt`、`InkPayload.readStroke(blob, blobValid)` / `jsonPoints` / `stripPoints`、`Schema` v18、
  `LibraryStore.compactInkPointsStep`；`ReaderActivity.attachWorkspace` 之后开始。本端不用 SQL 的 `json_*`（API 26 不保证有 JSON1）。
- **第一轮做过又删掉的**（用户改了主意，别再加回来）：兼容模式（`meta.ink_points_compat`）、只补二进制不动 payload 的迁移、
  Mac 设置「通用 ▸ 笔迹存储」与安卓「切换工作区 ▸ 笔迹存储…」两个清理入口、清理前的强制备份。
- **实测**（第一轮兼容模式，安卓）：打开 1412ms → 约 450ms（解析 1104ms → 约 250ms）；用户手动清理后「速度很快」。
- **验证**：Mac spike `ink-blob` 37/37，回归 `ink-store` / `ink-window` / `ink-undo` / `scratch-store` / `board-store` / `store` / `trash` /
  `mirror-fp` / `mirror-diff` / `mirror-build` / `mirror-align` 全绿（`mirror-apply` 有一条「上次打开取较晚」在改动前的 HEAD 上就失败，
  与本方案无关）。安卓 JVM 129/129。安卓数据层设备测试（`connectedAndroidTest`）没跑：会卸载用户平板上装着的 App。
