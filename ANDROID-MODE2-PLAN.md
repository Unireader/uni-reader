# 安卓模式2 输入板 — Demo 实施方案

> 「整体优化」需求④的**第一阶段：可上手 demo**。目标：Kotlin 原生「输入板」，等价浏览器采集页（capture.html）的核心链路，RT 流走 UDP。
> 本文是给**新会话**的实施包：协议契约、参考实现、范围裁剪、验收标准全在下面。Mac 侧已全部就绪，**不需要改 Mac 代码**。
> 代码放工作区内 `android/` 子目录（独立 git 仓库，用户已定）。

## 0. 一句话

安卓平板跑原生 App：WS auth 拿 session → UDP 发 RT（ink/erase/hover/scroll，自管双 seq + NACK 重传）→ Mac 实时叠墨迹/跟随滚动；WS 收 page/layout/strokes 做显示与恢复。写笔时本地即时回显。

## 1. 必读契约与参考实现（按序）

| 材料 | 内容 |
|---|---|
| `PROTOCOL.md` | **唯一线格式真源**。§2 字节序/原语、§3 opcode 表、§4 帧本体（每个消息的字节布局）、§6 UDP 传输头 |
| `UDP-PLAN.md` | 设计理由 + §7 客户端发送端职责 + §13 评审定案（不做降级、HELLO 只一发、probe 保持 REL、ringCap=512） |
| `spike/udp-pad-sim.py` | **最近真机验证过的参考实现**（Python 单文件）：WS 握手、帧编解码、UDP 发送、ring 重传、量化面板。Kotlin 版照它翻 |
| `Sources/Resources/wire.js` | JS codec（浏览器/node 共用），交叉验证用 |
| `spike/wire-vectors-swift.txt` | canonical 字节向量（31 条 hex）。**Kotlin codec 必须逐字节对齐** |
| `Sources/Resources/capture.html` | 完整浏览器采集页（本 demo 是它的裁剪版；交互细节参考） |

## 2. Demo 范围（裁剪，别贪多）

**做**：连接配置（手输 host/token）→ WS auth → 显示当前页 PNG（HTTP `GET /page.png?i=N`）→ 手写笔/手指落墨（ink，本地回显）→ 橡皮 → 翻页按钮 → 双指滚动（scroll）→ 手写笔悬停（hover）→ 切笔（4 支内置预设）→ 量化状态栏。

**不做**（留给后续迭代）：双指缩放/惯性、文档列表切换（selectDoc/docs）、pens 下发同步、probe/环形盘、夜间模式、笔迹成形回显（strokes 渲染只用于 e2e 计时，不画出来）、锁缩放/防误触、设置持久化。理由：demo 的目的是验证「原生 + UDP」手感与延迟，不是复刻采集页。

## 3. 技术选型（demo 刻意从简）

- **单 app module**，Kotlin，minSdk 26+（手写笔 API 都全），只依赖 **OkHttp**（WS 客户端）。不用 Hilt/Room/模块化——demo 不背架构债；正式版再按 NowInAndroid 拆 feature/core 模块。
- **WS**：OkHttp `WebSocket`（`newWebSocket(Request, Listener)`），二进制帧 = `ByteString`。
- **UDP**：`java.net.DatagramSocket` + `DatagramPacket`，发送即 `send()`（本机栈内拷贝，调用线程直接发即可，不必开线程池）。
- **UI**：**经典 View 体系，一个自定义 `PadView extends View`**——`onTouchEvent`/`onGenericMotionEvent` 对 MotionEvent（toolType/pressure/hover/历史点）的掌控最直接，Compose 在手写笔 hover 与高压感采样上反而绕。页图 + 本地笔迹都在 `onDraw` 里画。外层套一个状态栏 TextView + 连接表单。
- **线程**：OkHttp 回调在后台线程 → `runOnUiThread` 更新状态；输入事件在主线程直接编码发送（编码是纯内存操作，~µs 级）。
- 权限只 `INTERNET`。`keepScreenOn`。

## 4. 结构建议

```
android/
  app/src/main/java/com/xvan/unireader/pad/
    MainActivity.kt        // 连接表单 + PadView + 状态栏，生命周期
    WireCodec.kt           // 帧编解码（PROTOCOL.md §4），ByteBuffer LITTLE_ENDIAN
    UdpSender.kt           // 传输头（§6）、双 seq、ring(512)、nack 重发、HELLO
    MacClient.kt           // OkHttp WS：auth/收帧路由/ping/收 nack → UdpSender.resend
    PadView.kt             // 输入采集 + 本地回显 + 页图显示 + 坐标归一化
    PageFetcher.kt         // HTTP /page.png?i=N → Bitmap（带简单 LruCache）
  app/src/test/.../WireCodecTest.kt   // 对 spike/wire-vectors-swift.txt 逐字节比对
```

## 5. 关键实现要点（坑都标了）

### 5.1 线格式 codec（先做，带单测）
- `ByteBuffer.allocate(...).order(LITTLE_ENDIAN)`；`f32`=float、`f64`=double、`str`=u16 长度+UTF-8。
- 只需实现：编码 auth/ping/pageTurn/scroll/hover/ink/erase；解码 authOK/nack/page/layout/pong/strokes（strokes 只读个数用于 e2e 计时，可不解析笔迹）。
- **验收**：读 `spike/wire-vectors-swift.txt`，对 auth/pageTurn/scroll/hover/ink/erase 各 canonical 消息 encode 结果与 hex 逐字节相等（数值见 `spike/wire-codec-test.swift` 的 canonical 表，两边一一对应）。

### 5.2 UDP 发送端（UDP-PLAN.md §7 原样落地）
- 两个计数器 `seqUnrel`/`seqRel` 各从 1 递增。
- REL：组 `[01 02 session seq]+帧本体` → 存 ring（`LinkedHashMap<seq, ByteArray>`，cap 512 淘汰最旧）→ 发。
- UNREL：组 `[01 01 session seq]+帧本体` → 发，不留存。
- 收 WS `nack{seqs}`：ring 里有就原样重发（含原 seq），没有就跳过。
- 拿到 authOK 后立刻发一发 HELLO `[01 03 session]`；**不保活、不做 UDP 不通降级**（评审定案）。
- BYE `[01 04 session]` 在退出时发（可选）。

### 5.3 输入采集（手感关键，别偷懒）
- `onTouchEvent`：`ACTION_DOWN`→ink begin（`getToolType`/`getPressure`，手指默认 0.5）；`ACTION_MOVE`→**必须展开历史点**（`getHistoricalX/Y/Pressure(i)` + 当前点，Android 按 batch 投递，不展开等于自降采样率）攒进批缓冲；`ACTION_UP`→flush + ink end。
- 批缓冲 8ms flush（`Handler.postDelayed`），等价 capture.html 合批。
- **本地即时回显**：落笔即画（ Path + 压感宽度），用户看到的线是 0ms 的；Mac 屏幕那条才是网络+渲染延迟。这是采集页的既定 UX，demo 必须一致，否则手感评测全歪。
- 橡皮：模式切换按钮；erase 只有 move/end（无 begin），move 每帧带 page。
- hover：`onGenericMotionEvent` 的 `ACTION_HOVER_MOVE/EXIT`（手写笔悬停）→ UNREL。
- scroll：双指拖（`getPointerCount()==2` 时取双指中点位移）→ 维护本地锚点 (page,frac)，UNREL 发 scroll；页高按页图显示高度换算。方向以真机手感为准。
- 坐标：全部**页内归一化** [0,1]（y 向下），`nx=x/页图显示宽`，`ny=y/页图显示高`。页图 fit-width 居中显示，换算时注意上下留白的偏移。

### 5.4 页图显示
- 连上后收 WS `page{v,index,count,w,h}` → `GET http://host:8770/page.png?i=index`（token 不用带，Mac 端该路由不校验）→ Bitmap 画到 PadView 中央。`page` 消息 index 变化时重新取。demo 只显示当前页（不做连续多页）。
- `layout` 消息存页尺寸表（滚动跨页用；demo 也可以只当前页内滚动，翻页走按钮）。

### 5.5 量化状态栏（验收用，照 py sim）
实时显示四项：
- `rtt`：WS ping/pong（2s 间隔）；
- `e2e`：ink end 发出 → 收到 strokes 广播；
- `nackRTT`：seq 首发时刻 → 收到含该 seq 的 nack（sendTime 表随 ring 淘汰）；
- `mv/s`：每秒 move 帧数 + `nack`/`resend` 累计。
判读标准见 `spike/udp-pad-sim.py` 头部注释与 UniReader TODO.md ②。

## 6. 实施顺序（给新会话的 checklist）

1. `WireCodec.kt` + 向量单测（**先过字节级一致再谈后面**）。
2. `MacClient`：WS auth → authOK 解析 → ping/pong。
3. `UdpSender`：HELLO + REL/UNREL + ring + nack 重发。
4. `PadView`：页图显示 + ink 本地回显 + ink/erase 发送。
5. hover/scroll/翻页/切笔/橡皮按钮。
6. 量化状态栏。
7. **真机验收**（见 §7）→ 与 py sim 并排对比。

## 7. 验收标准（真机）

- UniReader 开文档 + Tablet Handwriting 面板 Start；安卓机同 LAN，手输 IP/token 连接。
- 画快笔：本地回显即时；Mac 屏幕墨迹肉眼无拖尾。与 `spike/udp-pad-sim.py`（另一台 Mac）并排对比，Android 的 `mv/s` 应 ≥ py sim（历史点展开后通常 90~120Hz）。
- 状态栏：LAN 正常 `rtt` 个位数 ms、`nack`≈0、`e2e` 20~50ms。
- Network Link Conditioner（或路由器限速）10% 丢包下：笔迹仍完整（`nack`/`resend` 涨），无 TCP 式整段卡顿——对照浏览器采集页同条件下的队头阻塞。
- 橡皮/翻页/hover/切笔功能正确；断 WS 重连后 session 更新、UDP 自动恢复（重 auth 即可）。

## 8. 已知坑（前面踩过的，别再踩）

- **Android 模拟器测 UDP**：模拟器在 NAT 后，`host` 填宿主机局域网 IP 即可（出站 UDP 没问题），但手感测试必须真机。
- **MotionEvent 不展开历史点** = 采样率腰斩，笔迹发虚/折线感（见 §5.3）。
- **不要做本地网络权限处理**：Android 的 INTERNET 就够；macOS 侧的「本地网络」弹窗坑（见 `git log` d1d1e58 前后排查记录）是 Apple 平台特产，Android 没有。
- **erase 每帧都会触发 Mac 全量 broadcastStrokes**（Mac 现状），擦除时 WS 下行会有流量尖峰，正常现象，不要在 demo 里「优化」它。
- 线格式任何改动 = 三端同步 + 更新向量（`PROTOCOL.md` 开头红线）。

---

## 9. 待做：模式2 的划字（高亮 / 笔记）

> **2026-09-04 定的方案，还没动手。** 起因：模式1（独立版）当天做完了「选字」模式
> （划字高亮 + 划字笔记，见 `android/AGENTS.md` 的结构要点），用户问模式2 有没有——没有，
> 而且**刻意没做**：`mode` 是双向 u8、`PROTOCOL.md §4.1` 写死 `0..3`，模式2 的模式键要是能
> 循环到第五档，就会把一个 Mac 不认识的 `mode=4` 发过去。用户拍板「先不做，留好方案」。

### 9.1 现状（模式2 今天是什么样）

- **划字：一处都没有。** `pad/` 目录下 `MODE_TEXT`/`TextSelect`/`textSelection` 零命中，
  文本层也没人注入（`setTextRuns` 只有模式1 的 `LocalCanvasView` 调）。
- **图钉：样式与尺寸跟着模式1 一起对齐了 macOS**（那半在 `shared/PadOverlays` +
  `PageCanvasView`，两模式共用）：暖黄圆底 + `note.text` 图标 + 0.5 描边、固定 9dp 不跟页缩放、
  钳进页内 12/10。⚠️ 顺带的变化：图钉热区从「`r+6dp`，r 最大 22dp ⇒ 最大 28dp」变成固定 22dp，
  放大看的时候比以前小一点（与 Mac 一致了，但确实是变化）。
- **两个缺口**（模式2 独有）：
  - 类型色/类型图标没有 —— `setNoteTypes` 只有模式1 注入，模式2 的图钉一律通用暖黄；
  - 选区注解的图钉仍落锚点、不挪到行末右侧 —— `notes` 消息只发 anchor 左上角，
    `TextNote.aw` 恒 0（见 §9.3 的补法）。

### 9.2 选定方案：**平板本地判定，Mac 只执行动作**

两条路各自的样子：

| | A：Mac 判定，平板只画 | **B：平板本地判定（选定）** |
|---|---|---|
| 拖动中 | 每一帧一次往返，Mac 算完把逐行框回推 | 零往返，本地直接算 |
| 手感 | WiFi 上 e2e 20~50ms，而且回推走可靠通道要排在大帧后面 → 划字必然拖 | 与模式1 一样跟手 |
| 代码 | Mac 侧现成，平板要新写"只画不判"的一层 | **直接复用**模式1 刚写的 `shared/OcrText.kt` + `shared/TextSelect.kt` |
| 一致性风险 | 天然一致 | 靠 `TextSelectTest` ↔ Mac spike 那套已有的跨端用例守 |
| 协议 | 起止点上行 + 逐行框回推 + 动作上行（3 条） | 文本层下发 + 动作上行（2 条） |

**选 B。** 理由：① 划字是**连续手势**，A 的往返延迟直接毁手感，这与环形选笔盘那条
「判定留在 Mac」的纪律不冲突——那条针对的是**长按计时**（时序判定，平板算会与 Mac 的状态打架），
而选区是**纯几何**，两端跑同一份纯函数得同一个结果；② 那份纯函数模式1 已经写完并与 Mac
逐条对齐、有 14 项 JVM 用例守着，B 是复用，A 是另写一套。

### 9.3 协议增量

**预留 opcode（`PROTOCOL.md §3` 表当前用到 `0x51`）**：

| opcode | 名 | 方向 | 通道 | 用途 |
|---|---|---|---|---|
| `0x52` | `textLayer` | S→C | 可靠 | 一页的 OCR 行（Mac 已滤水印，见下） |
| `0x53` | `textAct` | C→S | 可靠 | 划完之后的动作：高亮 / 批注 |

- **`textLayer`**：`u32 page` · `u16 n` · `n ×( str text, f32 x, f32 y, f32 w, f32 h, u16 nc, nc × f32 )`。
  `nc` = 单字边界个数（= 字数+1），**`0` 表示这行没有实测字位**，平板回落权重近似
  （与模式1 读 `ocr_page` 时 `chars` 缺键同义）。
  - **下发时机：跟着页图走。** 平板要哪页的 `page.png` 就顺带推哪页的 `textLayer`，
    不新增请求消息。一本书整份 OCR JSON 是几 MB，一页只有几十 KB。
  - 🔴 **Mac 发的必须是 `ocrVisibleRuns`（已滤平铺水印）**，不是 `ocrRuns`。跨页水印统计的样本
    本来就在 Mac 那边现成（`OCRWatermark.Profile`），平板没有整本的样本、自己算不准。
    这条同时省掉平板跑 `OcrWatermark`。
- **`textAct`**：`u8 act`（`0`=高亮 `1`=批注） · `u8 r` · `u8 g` · `u8 b`（act=0 才有意义）·
  `u32 page` · `str quote` · `str text`（act=1 的正文，act=0 空串）· `u16 nRects` · `nRects × 4×f32`。
  Mac 收到后走它已有的落库路径（`Highlight` / `commitNote(draft:)`），照常 `notes` 全量镜像回来。
  - **批注的编辑器在平板本地弹**（模式1 已有那一份 `PadPanels.showNoteEditor`），
    保存了才发这一帧 —— 与模式1 的两段式一致，点一下再返回不留空注解。
- **顺带补 `notes`（0x39）**：每条追加 `f32 aw` · `f32 ah`（anchor 的宽高）。
  有了 `aw>0` 平板才分得出选区注解与点注解，图钉才能挪到行末右侧（补掉 §9.1 的缺口）。
  同时追加 `str type_id`（或直接 `u8 r,g,b`），把类型色那个缺口一起补上。
  ⚠️ 这是**改已有消息**：三端同步 + 更新 `spike/wire-vectors-swift.txt` 向量，
  按 `PROTOCOL.md` 开头那条红线办，别只改一端。

### 9.4 平板侧要动的地方

1. `PadConst.MODE_LABELS` 加第五档「选字」，**同时把 `mode` 的取值范围在 `PROTOCOL.md §4.1`
   改成 `0..4`** —— 这两件事必须一起做，只做前一件就是本节开头说的那个 bug。
   做完 `PageCanvasView.modeLabels` 那个 `open val` 与 `LOCAL_MODE_LABELS` 就可以删掉，
   两模式回到同一张表。
2. `PadView` 收 `textLayer` → `setTextRuns()`（基类已有，模式1 在用）。**别在平板上跑
   `OcrWatermark`**（见 §9.3）。
3. `PadView` 覆写 `onTextSelectionChanged` → 弹那条「四色高亮 / 批注 / 复制」浮条
   （`local/TextSelectBar.kt` 要从 `local/` 挪到 `shared/`，两模式共用）。
4. 动作出口：模式1 是落本机库（`commitHighlight` / `saveSelectionNote`），
   模式2 编成 `textAct` 发给 Mac —— 与「同一个基类两个子类，差别只在覆写的那几个钩子」同构。
5. `notes` 解析补 `aw`/类型色；`PadView` 调 `setNoteTypes()`。

### 9.5 Mac 侧要动的地方

- `LANServer`：页图响应旁边推 `textLayer`（取 `DocSession.ocrVisibleRuns(page:)`）；
  收 `textAct` → 走 `addHighlight` / `commitNote` 的现成路径。
- `WireCodec.swift` + `Sources/Resources/wire.js` + 安卓 `WireCodec.kt` 三份编解码同步，
  向量表跟着更新（`PROTOCOL.md` 开头的红线）。
- web 采集页（`web/`）要不要跟着做划字：**可以先不做**，但 `wire.js` 的编解码得跟上，
  否则它连不上新版 Mac。

### 9.6 什么时候值得做

模式2 的场景是「人就坐在 Mac 前面，平板当手写板」——**Mac 上划字本来就更顺手**。
所以这件事的价值不在"能划"，而在「平板拿在手里读、顺手划一段」。
等模式2 真的被当成第二屏在读的时候再做；在那之前，现在这个边界（模式1 有、模式2 没有）
是清楚的，不是遗漏。
