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
- **UDP（仅原生客户端，RT 上行）**：一个 UDP 数据报 = `[传输头][帧本体]`，传输头带 session id + 单调 seq（自管乱序/丢弃/轻量重传），格式见 §6。浏览器用不了原生 UDP，永远走 WS。WS 与 UDP 复用同一套帧本体（§4）。

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
| `0x24` | textNote | C→S | 可靠 |
| `0x30` | page | S→C | 可靠 |
| `0x31` | layout | S→C | 可靠 |
| `0x32` | viewport | S→C | 可靠 |
| `0x33` | docs | S→C | 可靠 |
| `0x34` | pens | S→C | 可靠 |
| `0x35` | inkCancel | S→C | 可靠 |
| `0x36` | strokes | S→C | 可靠 |
| `0x37` | radial | S→C | 可靠 |
| `0x38` | pressRing | S→C | 可靠 |
| `0x39` | notes | S→C | 可靠 |
| `0x40` | scroll | C→S | **RT** |
| `0x41` | hover | C→S | **RT** |
| `0x42` | ink | C→S | **RT** |
| `0x43` | erase | C→S | **RT** |
| `0x44` | probe | C→S | **RT** |
| `0x45` | padGeom | C→S | 可靠 |
| `0x50` | nack | S→C | 可靠 |

（`C`=客户端/平板，`S`=服务端/Mac。`RT`=高频实时流，UDP 阶段可改走 UDP。）

## 4. 各消息 payload 布局

### 4.1 握手 / 心跳 / 控制（可靠）

| opcode | payload | 对象形状 |
|---|---|---|
| `auth` | `str token` | `{type:"auth", token}` |
| `authOK` | `u32 session` · `u16 udpPort` | `{type:"authOK", session, udpPort}`（UDP 会话号 + Mac UDP 端口；浏览器忽略。解码兼容空 payload → 0）|
| `authFail` | 空 | `{type:"authFail"}` |
| `ping` | `f64 t` | `{type:"ping", t}`（`t=Date.now()`）|
| `pong` | `f64 t` | `{type:"pong", t}`（回显 ping 的 t）|
| `latency` | `f32 ms` | `{type:"latency", ms}` |
| `selectDoc` | `str id` | `{type:"selectDoc", id}`（UUID 串或 ""）|
| `pageTurn` | `u8 dir` | `{type:"pageTurn", dir}`（"prev"/"next"）|
| `mode` | `u8 mode` | `{type:"mode", mode}`（"note"/"erase"/"page"）|
| `pen` | `u16 index` | `{type:"pen", index}` |
| `textNote` | `str id` · `u8 op` · `u32 page` · `f32 nx` · `f32 ny` · `str text` | `{type:"textNote", id, op, page, nx, ny, text}` |
| `padGeom` | `f32 pageW` | `{type:"padGeom", pageW}` |

`textNote`（平板自由文字笔记，C→S）：`op` u8 `0=upsert 1=delete`。`id` 由平板生成（UUID 串），
Mac 按 id upsert/删除文档的文字注解（kind=0 点注解：零尺寸 anchor=落点、无 quote/rects）；
**空文本 upsert 视为 delete**（对齐 Mac 端丢弃空点注解的语义）。坐标为页内归一化（与 ink 同系）。
文本内容丢不得，永远走可靠通道。

`padGeom`：平板上报**自己**当前的内容页宽（CSS px，= 页在平板屏幕上的显示宽度）。Mac 端环形选笔盘的
「中心取消区半径」「长按位移阈值」都是**平板屏幕上的物理尺度**，必须用平板页宽把归一化位移换算成
平板 px——用 Mac 阅读区页宽换算会让选择手感随任一端缩放而漂移。平板在布局/缩放变化时发（值变才发）。

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
| `radial` | `u8 open` · open=1 时续 `u32 page` · `f32 cx` · `f32 cy` · `u16 highlight` · `u16 n` · `n ×( u8 kind, pen )` |
| `pressRing` | `u8 on` · on=1 时续 `u32 page` · `f32 nx` · `f32 ny` |
| `notes` | `u16 n` · `n ×( str id, u32 page, f32 nx, f32 ny, str text )` |
| `nack` | `u16 n` · `n × u32 seq`（UDP REL 重传请求，见 §6；浏览器收到忽略）|

`radial`（环形选笔盘）：长按检测、扇区判定、选中提交**全部在 Mac**，这条只是把盘的状态镜像给平板去画
（平板不做任何判定）。`open=0` 时 payload 到此为止（收盘）。`highlight` = 当前指向的扇区下标，
`0xFFFF` = 无（指针在中心取消区）；解码后对象里是 `-1`。`kind` u8：`0=pen 1=erase 2=page`，
`kind≠0` 的项 `pen` 字节为占位 0（保持定长）。扇区**整圆均分**，第 0 项中心在正上方（12 点）、顺时针排列。

`pressRing`（长按进度环，环形盘的前置动画）：同样是 Mac 判定、平板照画。落笔即 `on=1`（Mac 起 1s 定时），
判为在画（位移超阈值）/ 长按达成转成盘 / 抬笔，都发 `on=0`。**不下发时间戳**——平板收到 `on=1` 就用
本机时钟起计，两端的 300ms 起显示 / 1s 填满是各自硬编码的同一组常量（局域网 RTT 造成的几毫秒偏差不可察觉）。

对象形状（与旧 JSON 逐字段一致）：
- `page` → `{type:"page", v, index, count, w, h}`（方案 B 下平板忽略，仍编码）
- `layout` → `{type:"layout", docId, v, count, pages:[[w,h],…]}`
- `viewport` → `{type:"viewport", page, frac, seq, force}`（`force` 布尔；`macScrolled` 走 seq、`pushCurrentViewport` 走 force=true）
- `docs` → `{type:"docs", list:[{id,title},…], selected, following}`
- `pens` → `{type:"pens", list:[{color,w,t},…], active}`
- `strokes` → `{type:"strokes", list:[{page, pen:{color,w,t}, pts:[[x,y,pressure],…]},…]}`
- `radial` → `{type:"radial", open:true, page, cx, cy, highlight, items:[{kind:"pen"|"erase"|"page", color, w, t},…]}`；收盘 → `{type:"radial", open:false}`
- `pressRing` → `{type:"pressRing", on:true, page, nx, ny}`；撤环 → `{type:"pressRing", on:false}`
- `notes` → `{type:"notes", list:[{id, page, nx, ny, text},…]}`（文字笔记**全量镜像**，类比 strokes：
  Mac 是唯一真源，平板不落库；对选区锚定的注解用 anchor 原点作 nx/ny。文档切换/增删后重发）
- `nack` → `{type:"nack", seqs:[…]}`

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
- UDP 传输头见 §6，自带 `ver` 字节，与帧本体版本相互独立。

## 6. UDP 传输头（仅原生客户端，RT 上行）

RT 流（scroll/hover/ink/erase/probe）在原生客户端上改走 UDP，消除 TCP 丢包队头阻塞。
控制握手与所有 Mac→端下发仍走 WS；NACK（重传请求）也走 WS。浏览器永远 WS，Mac 两条路都收。

一个 UDP 数据报 = `[传输头][帧本体]`，帧本体就是 §4 的 `[u8 opcode][payload]`（原封不动）。全小端。

```
[u8  ver = 0x01]          传输头版本
[u8  ptype]               包类型：1=DATA_UNREL  2=DATA_REL  3=HELLO  4=BYE
[u32 session]             会话号（authOK 下发；鉴权/路由）
── ptype ∈ {DATA_UNREL, DATA_REL} 时： ──
[u32 seq]                 该类别内的单调序号（从 1）
[帧本体 = u8 opcode + payload]   见 §4.3（scroll/hover/ink/erase/probe）
── ptype ∈ {HELLO, BYE} 时：无更多字节 ──
```

- **两个独立 seq 空间**（客户端自管 `seqUnrel`/`seqRel`，各从 1 递增），避免不可靠包在可靠序列里造成假缺口。
- **UNREL**（scroll/hover）：最新胜。Mac 记 `lastUnrel`，`seq > lastUnrel` 才应用，旧/重复丢弃。
- **REL**（ink/erase/probe）：有序不丢。Mac 记 `relExpected` + 重排缓冲：乱序入缓冲并触发 NACK（经 WS 发 `nack{seqs}`，节流汇总）；客户端从环形缓冲重发对应数据报；缺口卡死超 `stallMs` 则放弃丢失帧跳到缓冲最小学号继续（接受一小段豁口，记日志），避免单帧永久丢失堵死整条流。
- `HELLO`：客户端拿到 session 后**发一发**，让 Mac 校验 session 就绪（LAN 无 NAT，不做保活定时器）。
- `BYE`：客户端主动告知不再用 UDP（可选，纯优化；Mac 重置该 session 的重排状态）。
- 头部固定 10 字节（DATA）/ 6 字节（HELLO/BYE）。
- 会话生命周期：WS auth 成功 → Mac 生成随机 u32 session 随 `authOK` 下发；带未知 session 的 UDP 数据报一律丢弃（防注入）；WS 断开 → 注销 session。
- 默认参数：`udpPort=8772`、`stallMs=200ms`、NACK 节流 `~30ms`、客户端重传环形缓冲 `ringCap=512` 帧。

## 7. 一致性验证

- `spike/wire-codec-test.swift`：Swift 端全消息 encode→decode round-trip。**新消息一律追加在 canonical 表末尾**——安卓 `WireCodecTest.kt` 硬编码了该表向量并按行号索引，往中间插会静默错位掉整套跨语言凭据。
- `spike/wire-cross-test.js`：node 加载 `wire.js` 做 JS round-trip，并读 Swift 导出的 canonical 字节向量 `spike/wire-vectors-swift.txt`，逐字节比对，证明 **Swift 与 JS 编码结果字节级一致**（canonical 消息用 f32 精确值：0.5/0.25/整数，避免浮点表示差异）。
