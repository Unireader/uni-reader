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
