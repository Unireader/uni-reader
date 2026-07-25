# UniReader 通信协议（二进制线格式 v1）

> Mac ↔ 平板（浏览器采集页 / 安卓输入板）之间的**唯一线格式契约**。
> 三端实现必须字节级一致：Swift `Sources/Server/WireCodec.swift`、JS `Sources/Resources/wire.js`、（后续）Kotlin。
> 改这里 = 改三端 + `spike/wire-codec-test.swift` + `spike/wire-cross-test.js`。

## 0. 为什么是二进制

原 JSON-over-WebSocket 的问题：高频 `ink/erase/scroll/hover` 每点一串 `[[x,y,p],…]` 文本，解析开销与带宽都浪费；浮点转字符串来回丢精度；`JSON.parse` 每帧建对象。二进制定长打包后：ink 每点 12 字节固定、无解析歧义、精度由 f32 明确界定。

**设计原则：换序列化器、不换对象模型。** Mac 端 `AppModel`/`handleInk`/各 `broadcast*` 仍在 `[String:Any]` 上工作；平板端 `capture.html` 逻辑不动。只有两个咽喉换掉 JSON：
- Swift：`LANServer.rawSend`（发）/ `receiveWS`（收）。
- JS：`send()`（发）/ `ws.onmessage`（收）。
编解码器保证「解出来的对象」与旧 JSON 解出来的**形状完全一致**，故上层零改动。

## 1. 传输与分帧

- **WebSocket（可靠，全客户端）**：opcode 从 `.text` 改为 `.binary`；`ws.binaryType = "arraybuffer"`。一个 WS 二进制消息 = 一个协议帧（WS 自带消息边界，帧内**不需要**长度前缀）。
- **UDP（后续阶段，仅原生客户端）**：一个 UDP 数据报 = 一个协议帧，但**帧外**再包一层传输头（session id + 单调 seq，用于自管乱序/丢弃/轻量重传）。浏览器用不了原生 UDP，永远走 WS。UDP 头格式在 v2 段落定义，本 v1 只定义**帧本体**（下方 §4），WS 与 UDP 复用同一套帧本体。

握手（`auth`/`authOK`/`authFail`）与所有**控制类**消息永远走可靠通道；只有高频实时流（§4.3 标注 `RT`）在 UDP 阶段可改走 UDP。

## 2. 字节序与原语

**全部多字节小端（little-endian）**——Mac/安卓/JS TypedArray 硬件都是小端，免字节交换。

| 原语 | 布局 | 说明 |
|---|---|---|
| `u8` | 1 字节 | |
| `u16` | 2 字节 LE | 计数/下标 |
| `u32` | 4 字节 LE | 页号、版本、seq |
| `f32` | 4 字节 IEEE754 LE | 归一化坐标(0~1)、压感、页宽高比例、frac、宽度、alpha |
| `f64` | 8 字节 IEEE754 LE | 时间戳（`Date.now()` ~1.7e12、`performance.now()`）|
| `str` | `u16 len` + `len` 字节 UTF-8 | 最长 65535 字节 |
| `pt2` | `f32 x` + `f32 y` | 擦除/探针点（归一化，无压感）|
| `pt3` | `f32 x` + `f32 y` + `f32 pressure` | 笔迹点（归一化 + 压感）|
| `pen` | `u8 r`+`u8 g`+`u8 b`+`f32 a`+`f32 w`+`u8 brush` | 12 字节。r/g/b 0~255，a 0~1，w 线宽，brush 见下 |

**brush（笔头类型）u8**：`0=ballpoint 1=fountain 2=marker 3=pencil`，越界回退 0。
**mode（工具模式）u8**：`0=note 1=erase 2=page`。
**phase（阶段）u8**：`0=begin 1=move 2=end`。
**dir（翻页方向）u8**：`0=prev 1=next`。

`pen` 的颜色在对象模型里仍是 CSS 串 `rgba(r,g,b,a)`（Mac 端 `InkColor.parse` 消费、JS 端 canvas 消费）；编码时**解析成 r/g/b/a 打包**，解码时**重建 CSS 串**。故上层永远只见 CSS 串。

## 3. 帧结构

```
[u8 opcode][payload...]
```

opcode 单字节，全局唯一（收发同用一张表；某 opcode 由哪端发是约定，不冲突）。

### opcode 表

| opcode | 名称 | 方向 | 通道 |
|---|---|---|---|
| `0x01` | auth | C→S | 可靠 |
| `0x02` | authOK | S→C | 可靠 |
| `0x03` | authFail | S→C | 可靠 |
| `0x10` | ping | C→S | 可靠 |
| `0x11` | pong | S→C | 可靠 |
| `0x12` | latency | C→S | 可靠 |
| `0x20` | selectDoc | C→S | 可靠 |
| `0x21` | pageTurn | C→S | 可靠 |
| `0x22` | mode | 双向 | 可靠 |
| `0x23` | pen | 双向 | 可靠 |
| `0x30` | page | S→C | 可靠 |
| `0x31` | layout | S→C | 可靠 |
| `0x32` | viewport | S→C | 可靠 |
| `0x33` | docs | S→C | 可靠 |
| `0x34` | pens | S→C | 可靠 |
| `0x35` | inkCancel | S→C | 可靠 |
| `0x36` | strokes | S→C | 可靠 |
| `0x40` | scroll | C→S | **RT** |
| `0x41` | hover | C→S | **RT** |
| `0x42` | ink | C→S | **RT** |
| `0x43` | erase | C→S | **RT** |
| `0x44` | probe | C→S | **RT** |

（`C`=客户端/平板，`S`=服务端/Mac。`RT`=高频实时流，UDP 阶段可改走 UDP。）

## 4. 各消息 payload 布局

### 4.1 握手 / 心跳 / 控制（可靠）

| opcode | payload | 对象形状 |
|---|---|---|
| `auth` | `str token` | `{type:"auth", token}` |
| `authOK` | 空 | `{type:"authOK"}` |
| `authFail` | 空 | `{type:"authFail"}` |
| `ping` | `f64 t` | `{type:"ping", t}`（`t=Date.now()`）|
| `pong` | `f64 t` | `{type:"pong", t}`（回显 ping 的 t）|
| `latency` | `f32 ms` | `{type:"latency", ms}` |
| `selectDoc` | `str id` | `{type:"selectDoc", id}`（UUID 串或 ""）|
| `pageTurn` | `u8 dir` | `{type:"pageTurn", dir}`（"prev"/"next"）|
| `mode` | `u8 mode` | `{type:"mode", mode}`（"note"/"erase"/"page"）|
| `pen` | `u16 index` | `{type:"pen", index}` |

### 4.2 Mac→平板 状态下发（可靠）

| opcode | payload |
|---|---|
| `page` | `u32 v` · `u32 index` · `u32 count` · `f32 w` · `f32 h` |
| `layout` | `str docId` · `str v` · `u32 count` · `count ×(f32 w, f32 h)` |
| `viewport` | `u32 page` · `f32 frac` · `u32 seq` · `u8 force` |
| `docs` | `u8 following` · `str selected` · `u16 n` · `n ×(str id, str title)` |
| `pens` | `u16 active` · `u16 n` · `n × pen` |
| `inkCancel` | 空 |
| `strokes` | `u32 n` · `n ×( u32 page, pen, u16 m, m × pt3 )` |

对象形状（与旧 JSON 逐字段一致）：
- `page` → `{type:"page", v, index, count, w, h}`（方案 B 下平板忽略，仍编码）
- `layout` → `{type:"layout", docId, v, count, pages:[[w,h],…]}`
- `viewport` → `{type:"viewport", page, frac, seq, force}`（`force` 布尔；`macScrolled` 走 seq、`pushCurrentViewport` 走 force=true）
- `docs` → `{type:"docs", list:[{id,title},…], selected, following}`
- `pens` → `{type:"pens", list:[{color,w,t},…], active}`
- `strokes` → `{type:"strokes", list:[{page, pen:{color,w,t}, pts:[[x,y,pressure],…]},…]}`

### 4.3 平板→Mac 实时流（RT，UDP 阶段可迁 UDP）

带 `phase` 的消息按阶段变长：

| opcode | phase | payload |
|---|---|---|
| `scroll` | — | `u32 page` · `f32 frac` · `f64 t` |
| `hover` | move(1) | `u8 phase` · `u32 page` · `f32 nx` · `f32 ny` |
| `hover` | end(2) | `u8 phase` |
| `ink` | begin(0) | `u8 phase` · `u32 page` · `pen` · `u16 m` · `m × pt3` |
| `ink` | move(1) | `u8 phase` · `u16 m` · `m × pt3` |
| `ink` | end(2) | `u8 phase` |
| `erase` | move(1) | `u8 phase` · `u32 page` · `u16 m` · `m × pt2` |
| `erase` | end(2) | `u8 phase` |
| `probe` | begin(0) | `u8 phase` · `u32 page` · `u16 m` · `m × pt2` |
| `probe` | move(1) | `u8 phase` · `u16 m` · `m × pt2` |
| `probe` | end(2) | `u8 phase` |

对象形状：
- `scroll` → `{type:"scroll", page, frac, t}`
- `hover` move → `{type:"hover", page, nx, ny}`；end → `{type:"hover", phase:"end"}`
- `ink` begin → `{type:"ink", phase:"begin", page, pen:{color,w,t}, pts}`；move → `{…, phase:"move", pts}`；end → `{…, phase:"end"}`
- `erase` move → `{type:"erase", phase:"move", page, pts}`；end → `{…, phase:"end"}`
- `probe` 同 erase 结构（外加 begin）

> 注：`erase`/`probe` 的 `pts` 元素只有 `[nx,ny]` 两个数；Mac 端 `points()` 对缺压感的点补默认 0.5，不影响擦除/探针（都不吃压感）。

## 5. 兼容与版本

- 本版为 **v1**，无版本前缀字节——线格式由 opcode 表隐式定义，收发端同版本。
- 未知 opcode：解码端**丢弃该帧**（返回 null / 不回调），不崩。
- 后续加消息：分配新 opcode，旧端遇到即丢弃，天然向前兼容。
- UDP 传输头（session/seq/ack）在实装 UDP 时补 §6，不影响 §4 帧本体。

## 6. 一致性验证

- `spike/wire-codec-test.swift`：Swift 端全消息 encode→decode round-trip。
- `spike/wire-cross-test.js`：node 加载 `wire.js` 做 JS round-trip，并读 Swift 导出的 canonical 字节向量 `spike/wire-vectors-swift.txt`，逐字节比对，证明 **Swift 与 JS 编码结果字节级一致**（canonical 消息用 f32 精确值：0.5/0.25/整数，避免浮点表示差异）。
