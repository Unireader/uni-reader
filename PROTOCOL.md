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
**mode（工具模式）u8**：`0=note 1=erase 2=page 3=lasso`（`lasso`=框选移动，2026-07-27 新增）。
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
| `0x25` | penset | C→S | 可靠 |
| `0x26` | layerSelect | C→S | 可靠 |
| `0x27` | layerVisible | C→S | 可靠 |
| `0x28` | layerAdd | C→S | 可靠 |
| `0x29` | gotoPage | C→S | 可靠 |
| `0x2A` | openDoc | C→S | 可靠 |
| `0x2B` | scratchOpen | C→S | 可靠 |
| `0x2C` | scratchAdd | C→S | 可靠 |
| `0x2D` | scratchPaper | C→S | 可靠 |
| `0x2E` | scratchMove | C→S | 可靠 |
| `0x2F` | scratchPageShow | C→S | 可靠 |
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
| `0x3A` | layers | S→C | 可靠 |
| `0x3B` | library | S→C | 可靠 |
| `0x3C` | toc | S→C | 可靠 |
| `0x3D` | scratchpads | S→C | 可靠 |
| `0x3E` | scratchStrokes | S→C | 可靠 |
| `0x3F` | noteNew | S→C | 可靠 |
| `0x40` | scroll | C→S | **RT** |
| `0x41` | hover | C→S | **RT** |
| `0x42` | ink | C→S | **RT** |
| `0x43` | erase | C→S | **RT** |
| `0x44` | probe | C→S | **RT** |
| `0x45` | padGeom | C→S | 可靠 |
| `0x46` | eraser | 双向 | 可靠 |
| `0x47` | lassoMove | C→S | 可靠 |
| `0x48` | scratchDelete | C→S | 可靠 |
| `0x49` | scratchRename | C→S | 可靠 |
| `0x4A` | lassoScale | C→S | 可靠 |
| `0x4B` | canvas | 双向 | 可靠 |
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
| `gotoPage` | `u32 page` · **可选** `f32 frac` | `{type:"gotoPage", page, frac}`（0-based 目标页号，平板输入的是 1-based，本地转 0 后上行）|
| `openDoc` | `str docId` | `{type:"openDoc", id}`（**库** docId，见 `library`）|
| `scratchOpen` | `u16 index` | `{type:"scratchOpen", index}`（开第几张草稿纸；`0xFFFF` = 关闭，对象里 `-1`）|
| `scratchAdd` | `u32 page` · `f32 nx` · `f32 ny` | `{type:"scratchAdd", page, nx, ny}`（在该页该处新建一张并打开）|
| `scratchPaper` | `u16 index` · `u8 r` · `u8 g` · `u8 b` · `f32 a` · `u8 pattern` | `{type:"scratchPaper", index, bg, pattern}`（改第几张纸的纸样）|
| `scratchMove` | `u16 index` · `f32 nx` · `f32 ny` | `{type:"scratchMove", index, nx, ny}`（把第几张纸的图钉锚点挪到**同页内**该处，页不变）|
| `scratchPageShow` | `u16 index` · `u8 show` | `{type:"scratchPageShow", index, show}`（第几张纸要不要在纸上垫它锚定的那一页，见 §4.4）|
| `scratchDelete` | `u16 index` | `{type:"scratchDelete", index}`（删第几张纸，连同纸上笔迹）|
| `scratchRename` | `u16 index` · `str title` | `{type:"scratchRename", index, title}`（改第几张纸的名字；空串 = 回到「草稿纸 N」兜底名）|
| `mode` | `u8 mode` | `{type:"mode", mode}`（"note"/"erase"/"page"）|
| `pen` | `u16 index` | `{type:"pen", index}` |
| `penset` | `u16 active` · `u16 n` · `n × pen` | `{type:"penset", list:[{color,w,t}], active}`（布局与 `pens` 相同）|
| `eraser` | `f32 size` · `u8 mode` · `u8 ring` | `{type:"eraser", size, mode, ring}` |
| `textNote` | `str id` · `u8 op` · `u32 page` · `f32 nx` · `f32 ny` · `str text` · `u8 display` | `{type:"textNote", id, op, page, nx, ny, text, display}` |
| `padGeom` | `f32 pageW` | `{type:"padGeom", pageW}` |
| `layerSelect` | `u16 index` | `{type:"layerSelect", index}` |
| `layerVisible` | `u16 index` · `u8 visible` | `{type:"layerVisible", index, visible}` |
| `layerAdd` | 空 | `{type:"layerAdd"}` |
| `lassoMove` | `u32 page` · `f32 x0` · `f32 y0` · `f32 x1` · `f32 y1` · `f32 dx` · `f32 dy` · 〔可选〕`u16 n` · n×(`f32 x` `f32 y`) | `{type:"lassoMove", page, x0, y0, x1, y1, dx, dy, poly?}` |
| `lassoScale` | `u32 page` · `f32 x0` · `f32 y0` · `f32 x1` · `f32 y1` · `f32 ax` · `f32 ay` · `f32 sx` · `f32 sy` · 〔可选〕`u16 n` · n×(`f32 x` `f32 y`) | `{type:"lassoScale", page, x0, y0, x1, y1, ax, ay, sx, sy, poly?}` |

`textNote`（平板自由文字笔记，C→S）：`op` u8 `0=upsert 1=delete`。`id` 由平板生成（UUID 串），
Mac 按 id upsert/删除文档的文字注解（kind=0 点注解：零尺寸 anchor=落点、无 quote/rects）；
**空文本 upsert 视为 delete**（对齐 Mac 端丢弃空点注解的语义）。坐标为页内归一化（与 ink 同系）。
文本内容丢不得，永远走可靠通道。

`display` u8（2026-08-27 加）= **这条笔记的正文在页面上怎么展开**：`0=点击 1=悬停 2=始终`
（**只许尾部追加**新态；未知值各端一律回落 0）。它是**笔记自己的属性**、跟着笔记落库
（Mac payload 的 `display` 键，值是同义小写串 `tap`/`hover`/`always`；旧笔记无此键 = 0，零迁移），
所以 upsert 时和正文一起改：Mac `applyTextNote` 收到就写进 `TextNote.display`。
`delete` 帧照样带这个字节（定长），值无意义。
**「哪几条此刻正展开着」不上线**——那是各端自己的瞬态显示状态（同缩放/滚动的口径），
Mac 上点开的气泡不会跟着同步到平板。
悬停模式在触摸端由**笔悬停**触发；纯手指的设备退化成点击展开（各端本地决定，不改线格式）。

`padGeom`：平板上报**自己**当前的内容页宽（CSS px，= 页在平板屏幕上的显示宽度）。Mac 端环形选笔盘的
「中心取消区半径」「长按位移阈值」都是**平板屏幕上的物理尺度**，必须用平板页宽把归一化位移换算成
平板 px——用 Mac 阅读区页宽换算会让选择手感随任一端缩放而漂移。平板在布局/缩放变化时发（值变才发）。

`penset`（平板改笔宽后上行，C→S）：payload 布局与 `pens` 完全相同（`active` = 平板当前笔下标）。
线上不带 id/name，Mac **按下标对齐**写回 `app.pens` 的 color/width/type；数目不符说明两端列表版本错位，
整包丢弃。写回触发 `pens` 的 didSet 自动落盘并 `broadcastPens` 全端对齐（平板会收到自己改动经 Mac 确认后的回声）。

`eraser`（橡皮设置，双向）：`size` = **归一化半径**（页宽比，默认 0.02；直径 = 2×size，与 `eraseNear`/
`InkEdit.splitStroke` 的命中半径同义）；`mode` u8 `0=整笔 1=局部`（默认 1：整笔=任一点命中即删整条，
局部=剔除命中点、剩余连续段各成新笔画）；`ring` u8 `0=关 1=开`（默认 1：笔尖/光标处的橡皮尺寸圆环）。
C→S：平板改橡皮设置；S→C：Mac 侧变更（或新客户端接入补发）时下发同步。

`layerSelect`/`layerVisible`/`layerAdd`（多层笔迹，平板发起，全部 C→S）：图层的增删改全部由 Mac 判定，
平板只发「请求」，Mac 执行后照旧广播 `layers`（§4.2）把权威状态推下来——与 `pen`（切换）/`penset`
（改值）之于 `pens` 是同一套「请求 + 权威回推」惯例，只是这里拆成三条各司其职的小消息而非复用
`penset` 那种整表覆盖（图层要支持**新增**，`penset` 按下标对齐、数目不符即整包丢弃的设计天生做不到这点，
见 `penset` 说明）。`layerSelect.index`/`layerVisible.index` 都是 `layers` 列表里的下标（不是图层 id，
两端按下标对齐，同 `pen`/`penset`）；`layerAdd` 空 payload，新图层的名字/颜色/顺序由 Mac 决定
（`InkLayer.next(after:)`），追加后立即设为当前作画图层。

`lassoMove`（框选移动提交，平板发起，C→S）：`mode=lasso` 下平板本地用与 Mac 端
`ReaderSurface+Lasso.finishLassoSelect` 同一套算法对本地镜像的
`strokes`/`notes` 做框选判定与拖动 ghost 预览，这一步**纯本地、不上行**（同 `eraseHit` 先例：
命中算法客户端复刻一份，只为即时回显）；只有松手提交移动时才发这一条：`x0,y0,x1,y1` = 框选
区域的包围盒（页内归一化，`min≤max`），`dx,dy` = 拖动位移（页内归一化，可为负）。Mac 收到后
**不信任平板的本地判定结果**，而是用同一套命中算法在自己的真源 `session.strokes`/`textNotes`
上重新框选、`InkEdit.translated` 平移命中项、持久化，再 `broadcastStrokes`/
`broadcastNotes` 把结果镜像回所有客户端——与 `erase`（平板发点、Mac 用真源做 `eraseNear`）是
同一套「客户端乐观预览 + 服务端复判执行」惯例，规避了 `strokes`/`notes` 线上不带稳定 id、
平板无法直接引用具体某条笔迹/注解的问题。

**尾部可选多边形**（同 `gotoPage.frac` 先例，缺省 = 老形态字节不变）：自由框选（2026-08-17 起，
三端框选一律为不规则路径而非矩形）时，平板把框选路径逐点附上——`u16 n` + n 个 (`f32 x`,`f32 y`)
页内归一化点（n≥3，首尾自动闭合；JSON 形态为扁平数组 `poly:[x0,y0,x1,y1,…]`）。有尾部时 Mac 按
**多边形命中**复判（笔迹任一点落多边形内、注解 anchor 中心落多边形内，`InkEdit.pointInPolygon`
射线法）；无尾部则按 `x0..y1` 矩形命中（兼容老客户端）。命中规则与 Mac 本机
`finishLassoSelect` 严格一致——多端实现同一算法，改动必须三端同步。

`lassoScale`（框选缩放提交，平板发起，C→S，2026-08-17 新增）：与 `lassoMove` 同一套
「客户端乐观预览 + 服务端复判执行」惯例，提交的是缩放而非平移：`ax,ay` = 缩放锚点（被拖手柄的
对侧手柄，页内归一化；角手柄默认等比、边中点手柄单轴——这个交互约束只影响客户端怎么算
`sx,sy`，线上不体现），`sx,sy` = 按轴缩放比（正数，客户端 clamp 0.05...20）。Mac 复判命中后
`InkEdit.scaled`（点集绕锚点按轴缩放 + clamp 0...1、线宽 ×√(sx·sy)、注解 anchor/rects 同缩放）、
持久化、镜像回所有客户端。多边形尾部语义与 `lassoMove` 完全相同。

`gotoPage` 的 `frac`（**尾部可选 f32**，同 `ink begin` 的 `flags` 先例）：目标页内的纵向归一化位置，
语义与 `viewport.frac`/`scroll.frac` 完全一致（0=页顶）。**缺省或 0 时编码端一律省略这 4 字节**——
于是「只跳页」的老形态字节不变，老客户端与新 Mac、新客户端与老 Mac 都能对上。收到带 frac 的
`gotoPage`，Mac 走的是与自己点侧栏目录同一条 `origin:"toc"` 锚点路径（`emitAnchor`），跳完照例经
`viewport` 回推给所有客户端。目录跳转必须带 frac：章节标题常在页中部起，只跳页会落在上一节末尾。

`openDoc`（平板打开工作区里尚未打开的文档，C→S）：`docId` 是 `library`（§4.2）里的**库文档 id**。
Mac 收到后：该文档已在本工作区某个窗口打开 → 等价于 `selectDoc` 切到那个窗口；否则**新开一个 Mac 窗口**
装它（用户 2026-08-05 拍板：不就地顶掉当前窗口的文档，也不做「只在平板上换、Mac 不动」的隐藏会话），
并在新窗口的文档就位后把平板锁定跟随过去。工作区归属 = **平板当前跟随的那个会话所属的工作区**
（Mac 是窗口级工作区、多工作区并存，见 `REQUIREMENTS.md §8.1`）。

> ⚠️ **线上有三个互不相通的 id 空间，别混用**：
> `docs`(0x33)/`selectDoc`(0x20) 的 id = **窗口会话 id**（`DocSession.id`，一个窗口一个）；
> `library`(0x3B)/`openDoc`(0x2A) 的 id = **库文档 id**（`LibDocument.id`，SQLite 主键，跨窗口稳定）；
> `layout`(0x31) 的 `docId`/`v` 与 `toc`(0x3C) 的 `docId` = **内容哈希**（`DocSession.contentHash`，
> 同一文件的不同窗口相同）。平板判「这份目录是不是当前这本书的」只能用第三种。

### 4.2 Mac→平板 状态下发（可靠）

| opcode | payload |
|---|---|
| `page` | `u32 v` · `u32 index` · `u32 count` · `f32 w` · `f32 h` |
| `layout` | `str docId` · `str v` · `u32 count` · `count ×(f32 w, f32 h)` |
| `viewport` | `u32 page` · `f32 frac` · `u32 seq` · `u8 force` |
| `docs` | `u8 following` · `str selected` · `u16 n` · `n ×(str id, str title)` |
| `pens` | `u16 active` · `u16 n` · `n × pen` |
| `inkCancel` | 空 |
| `strokes` | `u32 ackRel` · `u32 n` · `n ×( u32 page, pen, u16 m, m × pt3 )` |
| `radial` | `u8 open` · open=1 时续 `u32 page` · `f32 cx` · `f32 cy` · `u16 highlight` · `u16 n` · `n ×( u8 kind, pen )` |
| `pressRing` | `u8 on` · on=1 时续 `u32 page` · `f32 nx` · `f32 ny` |
| `notes` | `u16 n` · `n ×( str id, u32 page, f32 nx, f32 ny, str text, u8 display )` |
| `layers` | `u16 active` · `u16 n` · `n ×( u8 r, u8 g, u8 b, u8 visible, str name )` |
| `library` | `str wsName` · `u16 n` · `n ×( str id, str title, u8 open )` |
| `toc` | `str docId` · `u16 n` · `n ×( u8 depth, u8 hasPage, u32 page, f32 frac, str label )` |
| `scratchpads` | `u16 open` · `u16 n` · `n ×( str id, str title, u32 page, f32 nx, f32 ny, u8 r, u8 g, u8 b, f32 a, u8 pattern, u8 showPage )` |
| `scratchStrokes` | `u32 ackRel` · `u32 n` · `n ×( pen, u16 m, m × pt3 )` |
| `noteNew` | `u32 page` · `f32 nx` · `f32 ny` |
| `canvas` | `u8 on` · `f32 margin` |
| `nack` | `u16 n` · `n × u32 seq`（UDP REL 重传请求，见 §6；浏览器收到忽略）|

`canvas`（画板模式，v12 起）：页面**两侧的空白也是可书写区**，横向按笔迹「软边界」生长。
`margin` = **每侧**页边宽度，单位是**页宽的倍数**（0.5 = 每侧半个页宽；`on=0` 时编 0）。
**双向**（同 `mode`/`pen`/`eraser` 的先例）：C→S 是「请求切开关」，客户端**只有 `on` 有意义**、
`margin` 一律编 0（页边宽度轮不到客户端定）；Mac 执行后照旧广播权威值回来。

> **页边笔迹不是新的东西**：它仍是**页内笔迹**（`strokes`/`ink` 里那一套，归属那一页），
> 只是页内归一化 `x` 越出 `0…1`（单位还是页宽的倍数，`x=-0.5` = 页左边缘再往左半个页宽；
> `y` 永远还在 `0…1`，页边只横向延伸）。**故本条之外的线格式一个字节都没变**——
> 老客户端收到越界的 x 会把笔迹画到页外被裁掉，不崩、不丢数据。

内容宽 = `页宽 × (1 + 2×margin)`，页面居中其中。三端布局必须按同一个 `margin` 算，否则
「Mac 上写在公式右边、平板上写到了页面里」。**`margin` 由 Mac 单方面决定**（同 `radial`/`pressRing`
的「Mac 判定、平板照画」惯例）：Mac 按可见图层笔迹的最大横向越界量档位化（每档 0.5 页宽，
写到离边界不足 0.35 页宽就跳一档，上限 8），变了就重发本条。客户端**落笔中可以本地乐观跳档**
（同一组档位常数，避免等一个 RTT 才有地方下笔），Mac 的下发值一到即以它为准。

`radial`（环形选笔盘）：长按检测、扇区判定、选中提交**全部在 Mac**，这条只是把盘的状态镜像给平板去画
（平板不做任何判定）。`open=0` 时 payload 到此为止（收盘）。`highlight` = 当前指向的扇区下标，
`0xFFFF` = 无（指针在中心取消区）；解码后对象里是 `-1`。`kind` u8：`0=pen 1=erase 2=page 3=scratchAdd 4=textNote`
（**只许尾部追加**），`kind≠0` 的项 `pen` 字节为占位 0（保持定长）。扇区**整圆均分**，第 0 项中心在正上方（12 点）、顺时针排列。
`scratchAdd` = 盘心新建一张草稿纸并打开（与 `scratchAdd`(0x2C) 上行殊途同归，只是落点取盘心）；
`textNote` = Mac 提交后下发 `noteNew`（§4.2）让平板在盘心点开文字笔记编辑器。

`pressRing`（长按进度环，环形盘的前置动画）：同样是 Mac 判定、平板照画。落笔即 `on=1`（Mac 起 1s 定时），
判为在画（位移超阈值）/ 长按达成转成盘 / 抬笔，都发 `on=0`。**不下发时间戳**——平板收到 `on=1` 就用
本机时钟起计，两端的 300ms 起显示 / 1s 填满是各自硬编码的同一组常量（局域网 RTT 造成的几毫秒偏差不可察觉）。

对象形状（与旧 JSON 逐字段一致）：
- `page` → `{type:"page", v, index, count, w, h}`（方案 B 下平板忽略，仍编码）
- `layout` → `{type:"layout", docId, v, count, pages:[[w,h],…]}`
- `viewport` → `{type:"viewport", page, frac, seq, force}`（`force` 布尔；`macScrolled` 走 seq、`pushCurrentViewport` 走 force=true）
- `docs` → `{type:"docs", list:[{id,title},…], selected, following}`
- `pens` → `{type:"pens", list:[{color,w,t},…], active}`
- `strokes` → `{type:"strokes", ackRel, list:[{page, pen:{color,w,t}, pts:[[x,y,pressure],…]},…]}`

  **`ackRel` = 生成这份快照时，Mac 已连续处理到的该客户端 REL 序号**（§6 的 `seqRel`；
  `= relExpected - 1`，`0` 表示不适用——没建 UDP 会话的客户端如浏览器，或还没收过任何 REL 包）。
  它按**收件人**逐连接填（`LANServer.rawSend`），因为每个客户端的可靠流进度各不相同。

  用途是让客户端分得清「这份快照含不含我刚发出去的输入」。`strokes` 是**全量镜像**，而 Mac 每收到
  一批擦除点就广播一次（`AppModel.inkErase`），于是擦除途中会连着回来一串**中途快照**，每份都比
  客户端本地的乐观状态旧。客户端照单全收的话，已擦掉的笔迹会被一份份恢复出来再擦掉
  （用户实测：「删掉了又出现，过一会才真的被删除」）。判据只有一条：
  **`ackRel >= 本端已发出的最后一个 seqRel` → 这份快照含我的全部输入，应用；否则是中途快照，丢弃。**

  > 这条判据同时替掉了客户端侧「按发出批数记账」那类**单边对账**——它靠猜「一批擦除恰好回一次广播」
  > 的隐含契约，还得配超时兜底，安卓端为此翻车两次（补丁史见 `ANDROID-STANDALONE-PLAN.md §9.9`）。
  > `ackRel` 单调递增且由真源侧给出，不需要兜底：它最终必然追上。乐观笔迹同理——快照一旦满足判据，
  > 就说明所有已发出的 `ink end` 都已进真源，本端的乐观副本可以整批撤掉，不必逐条配对。
- `radial` → `{type:"radial", open:true, page, cx, cy, highlight, items:[{kind:"pen"|"erase"|"page"|"scratchAdd"|"textNote", color, w, t},…]}`；收盘 → `{type:"radial", open:false}`
- `pressRing` → `{type:"pressRing", on:true, page, nx, ny}`；撤环 → `{type:"pressRing", on:false}`
- `canvas` → `{type:"canvas", on, margin}`（画板模式；`on` 布尔，`margin` = 每侧页边宽度 ÷ 页宽。
  C→S 时只带 `on`，`margin` 编 0——客户端不决定页边宽度）
- `noteNew` → `{type:"noteNew", page, nx, ny}`（Mac 在环形盘提交「新建文字笔记」扇区后下发：
  平板在 `page` 页内 (nx, ny) 处点开文字笔记编辑器；编辑完成走现有 `textNote`(0x24) 上行闭环）
- `notes` → `{type:"notes", list:[{id, page, nx, ny, text, display},…]}`（文字笔记**全量镜像**，类比 strokes：
  Mac 是唯一真源，平板不落库；对选区锚定的注解用 anchor 原点作 nx/ny。文档切换/增删后重发。
  `display` = 展开方式 `0=点击 1=悬停 2=始终`，语义见 §4.1 的 `textNote`）
- `layers` → `{type:"layers", active, list:[{r,g,b,visible,name},…]}`（多层笔迹的图层表，类比 `pens`：
  `list` 按图层 `sortOrder` 排、**按下标对齐**，`active` = 当前作画图层在 `list` 里的下标；
  颜色只是图层列表的色点标识（与笔画自身墨色无关），Mac 端由 `colorKey` 解析成 r/g/b 再打包。
  `strokes` 广播前已按图层可见性过滤，故平板看到的笔迹天然只含当前可见图层；平板端 `LayerStat` 组件
  据此渲染图层胶囊/面板，并通过 `layerSelect`/`layerVisible`/`layerAdd`（§4.1）发起切换/显示隐藏/新增请求）
- `library` → `{type:"library", ws, list:[{id, title, open},…]}`（**工作区书库全量镜像**，平板据此
  列出「Mac 还没打开的文档」并用 `openDoc`（§4.1）请求打开。`id` = 库文档 id（**不是** `docs` 的窗口
  会话 id，见 §4.1 的三个 id 空间）；`open` u8 = 该文档当前是否已在本工作区某个窗口里打开（平板给个
  标记，点它走 `selectDoc` 而不是 `openDoc` 更快，但发 `openDoc` 也对——Mac 会自己识别并切过去）；
  `ws` = 工作区显示名，纯展示。
  **发送时机**：客户端接入、平板跟随的会话变化（换窗口＝可能换工作区）、该工作区文档表增删改、
  任一窗口换了文档（`open` 标记会变）。空工作区发 `n=0`，平板显示空态而不是一直转圈）
- `toc` → `{type:"toc", docId, list:[{depth, page, frac, label},…]}`（**当前文档的 PDF 目录**，
  由 `TOCEntry.build` 从 `outlineRoot` 递归构建后**先序拍平**：`depth` 从 0 起，客户端按它重建折叠树
  （比嵌套编码省事，且天然定长前缀）。`docId` = 内容哈希，与 `layout` 的 `docId`/`v` 同一口径——
  平板必须核对它与当前显示文档一致才应用，否则切档瞬间会把上一本的目录挂到新书上。
  **坏书签**（destination 解不出目标页，现实里常见：空 dest、dest 指向别的文档）线上 `hasPage=0`、
  `page`/`frac` 填 0，解码后对象里 **`page = -1`**；平板必须把它渲染成不可点的灰行，**不能当第 1 页**
  （Mac 端 `TOCListView` 同款语义：不显示页码、disabled、不参与当前章节追踪）。
  没有目录的 PDF 发 `n=0`（平板显示「无目录」空态）。**发送时机**：文档载入完成、客户端接入、
  平板跟随的会话变化）
- `scratchpads` → `{type:"scratchpads", open, list:[{id, title, page, nx, ny, bg, pattern, showPage},…]}`（**草稿纸列表全量镜像**）
- `scratchStrokes` → `{type:"scratchStrokes", ackRel, list:[{pen:{color,w,t}, pts:[[x,y,pressure],…]},…]}`

  见下方 §4.4。
- `nack` → `{type:"nack", seqs:[…]}`
- `eraser` → `{type:"eraser", size, mode, ring}`（双向消息，布局见 §4.1；S→C 方向用于 Mac 侧变更/新客户端补发）

### 4.3 平板→Mac 实时流（RT，UDP 阶段可迁 UDP）

带 `phase` 的消息按阶段变长：

| opcode | phase | payload |
|---|---|---|
| `scroll` | — | `u32 page` · `f32 frac` · `f64 t` |
| `hover` | move(1) | `u8 phase` · `u32 page` · `f32 nx` · `f32 ny` |
| `hover` | end(2) | `u8 phase` |
| `ink` | begin(0) | `u8 phase` · `u32 page` · `pen` · `u16 m` · `m × pt3` · `u8 flags` |
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
- `ink` begin → `{type:"ink", phase:"begin", page, pen:{color,w,t}, pts, line}`；move → `{…, phase:"move", pts}`；end → `{…, phase:"end"}`
- `erase` move → `{type:"erase", phase:"move", page, pts}`；end → `{…, phase:"end"}`
- `probe` 同 erase 结构（外加 begin）

> 注：`erase`/`probe` 的 `pts` 元素只有 `[nx,ny]` 两个数；Mac 端 `points()` 对缺压感的点补默认 0.5，不影响擦除/探针（都不吃压感）。

`ink begin` 的 `flags`（**尾部可选字节**：读完 `pts` 就够解出完整语义，老客户端不发 → 视为 0，故加它不算破坏兼容）：

| bit | 名字 | 含义 |
|---|---|---|
| 0 | `line` | 这一笔是**直线（尺子）笔**：整笔恒为「起点 + 当前终点」两点 |

`line=1` 时后续 `ink move` 的点是**替换终点**而不是追加：Mac 取该批的**最后一个点**（前面的是拖动过程中的中间终点，丢弃），把活体笔迹重置为 `[起点, 该点]`，抬笔提交的就是一条两点直线。45° 吸附本身在**客户端**算完再上行（客户端要即时回显，Mac 复算只会两端算出两条线），Mac 只负责认「两点」这个语义。`line=0` 或缺 flags = 老行为（move 追加点）。

### 4.4 草稿纸（v8 起，0x2B~0x2F / 0x3D / 0x3E / 0x48 / 0x49）

草稿纸 = 盖在 PDF 之上的**无限白板**，不改 PDF 原文、不属于任何一页。一篇文档可有多张，
各自由 (页, 页内归一化点) 锚定「当初在哪儿建的」（页面上留一枚图钉）。

#### 🔴 画布坐标系（三端契约，改它等于改数据格式）

**单位 = 逻辑点**（macOS pt / CSS px / Android dp），原点 = 创建那一刻的视口中心，
x 向右 y 向下，**无界且可负**。因此：

- `scratchStrokes` 的 `pts` 与草稿纸打开时上行的 `ink`/`erase` 的 `pts`，**都是画布坐标**，
  不是页内 0~1 归一化。线上都是 `f32`，负值/大值天然装得下。
- 笔宽 `pen.w` 与页内笔迹**同语义**（zoom=1 时的屏幕宽度）→ 三端现成的笔迹渲染器只要把
  「点 × 页宽」换成「(点 − 视口原点) × zoom」就能原样复用，四种笔型的观感不用重新对。
- 橡皮半径线上仍是 `eraser.size`（页宽归一化），草稿纸上按固定基准折成画布点：
  **`画布半径 = size × 800`**。三端必须用同一个 800，否则同一次擦除两端擦掉的笔迹不一样多。

#### 🔴 `ink`/`erase` 的解释取决于「哪张纸开着」，线格式一个字节没改

Mac 是「当前打开哪张草稿纸」的唯一真源（`scratchpads.open`）。草稿纸打开时：

- 客户端把触点换算成**画布坐标**再发 `ink`/`erase`，`page` 字段作废（填什么都行，Mac 不读）；
- Mac 收到后整条走草稿纸链路，**不会落到 PDF 页面上**（「笔迹只能在草稿纸上使用」是这个功能的定义）；
- `probe`（长按环形选笔盘的探针流）在草稿纸上**不生效**：那套判定全建立在页内归一化 +
  `padGeom.pageW` 上，喂画布坐标进去阈值会整个失真。两端都不呼盘。

于是加草稿纸没有动 RT 流的任何字节。代价是两端必须对「开着哪张」有一致认知——靠 `scratchpads`
这条可靠通道的全量镜像保证，且开/关纸时 Mac 会先 `inkCancel` 丢掉在飞的半截笔。

#### 🔴 纸样（v9）：底色 × 底纹

`bg` = **自由 CSS rgba 串**（不是枚举，各端 UI 给的备选项互不约束，加减颜色不影响解码）。
`pattern` = **u8 枚举**：`0=plain 1=dots 2=grid`（同 brush/mode 的编码惯例，越界回退 `dots`）。

- 底纹只是无限画布的**定位参照**（纯色纸平移时看不出自己在动），画在纸色之上、笔迹之下。
- **底纹墨色由纸色明度推**（`0.299R+0.587G+0.114B > 0.5` → 深纹，否则浅纹），
  **不许跟系统深浅外观走**——纸色是这张纸自己的属性，深色外观 + 白纸时跟外观走就整个消失了。
- 网格步长也是契约：画布步长从 **24** 起按 2 的幂折算，直到屏幕间距落进 **[22, 88] px**。
  不统一的话同一张纸在两端的格子大小不一样。
- 夜间模式下草稿纸**不反色**（它是一张纸，不是 PDF 内容）。

#### 🔴 页面底图（v10）：把纸锚定的那一页垫在纸下面

每张纸带一个 `showPage` 开关（线上 `u8`，`scratchpads` 每项尾部；库里 `scratch_pad.show_page`）。
开着时，纸上垫一张**它锚定的那一页**的页图（只是参照物，不是 PDF 编辑——纸上的笔迹仍只属于这张纸）。

**几何是三端契约**（对不上就是「同一张纸在 Mac 上写在公式旁边、在平板上写到页边空白处」）：

- 页图宽度恒为 **`pageRefWidth = 800` 画布点**，高 = `800 × 页高/页宽`（**显示尺寸**口径：
  CropBox 有效则 CropBox、否则 MediaBox，含 rotation——与页内笔迹用的是同一个页面尺寸）。
- 位置：这张纸的**锚点** (`nx`,`ny`) 落在**画布原点** (0,0) → 页矩形 = `(−nx·W, −ny·H, W, H)`。
  于是「打开纸 = 回画布原点」正好把当初创建它的那一处摆在视口正中（同一句「从该处显示」）。
- 层序：**纸色 → 底纹 → 页图 → 笔迹**（页图盖住它底下的底纹，笔迹永远在页图之上）。
- 页图**不参与夜间反色**（草稿纸整体不反色的既有规则），并沿页边描一条淡边——白页压白纸看不出边界。
- 开着时，「内容包围盒」（软边界 / 适应内容 / minimap）= 笔迹包围盒 **∪ 页矩形**，
  否则空白纸上垫了页也走不到页边（软边界只认笔迹）。

`showPage` 是**纸的属性**（跟着纸走、跨端同步、重开文档还在），不是视口那种各端私有状态。
默认值：**新建的纸开**（在这一处做草稿，页面就该在眼前）、**v9 迁移过来的老纸关**（不惊扰既有的白纸）。

#### 消息细节

- `scratchpads`：**全量镜像**（类比 `strokes`/`notes`，Mac 唯一真源，客户端不落库）。
  `open` = 当前打开的是 `list` 里第几张，`0xFFFF` = 一张都没开（解码后 **-1**）。
  `bg` 线上按 `pen` 同款拆成 `r/g/b/a`，对象模型里仍是 CSS 串（默认 `rgba(255,255,255,1.0)`）。
  `page`/`nx`/`ny` = 锚点（图钉画在这儿），不是纸的内容位置。
  **发送时机**：客户端接入、服务启动、草稿纸增删改、开/关纸、平板跟随的会话变化（换窗口＝换文档＝换一整套）。
- `scratchStrokes`：**当前打开那张纸**上的全量笔迹（没开纸就发 `n=0`，客户端据此清掉本地残留）。
  **没有 `page` 字段**。`ackRel` 语义与 `strokes` 完全一致（按收件人填，客户端靠它分辨中途快照）。
- `scratchOpen`：平板请求开/关。Mac 判定后回推 `scratchpads`+`scratchStrokes`，两端自然一致。
- `scratchAdd`：平板请求新建一张并打开（锚在它给的页与页内位置）。
- `scratchPaper`：平板请求改第 `index` 张纸的纸样。Mac 判定 + 落库后回推 `scratchpads`。
- `scratchMove`：平板请求把第 `index` 张纸的图钉锚点挪到**同页内** (nx, ny)（页不变；
  nx/ny 越界由 Mac 钳位到 0~1，index 越界整帧丢弃——同 `scratchPaper` 的防御风格）。
  Mac 判定 + 落库后照旧回推 `scratchpads`（锚点字段就在全量镜像里，两端自然一致）。
- `scratchPageShow`：平板请求开/关第 `index` 张纸的页面底图（`show` 非 0 即开）。同上，回推为准。
- `scratchDelete`：平板请求删掉第 `index` 张纸，**连同纸上的全部笔迹**（Mac 侧与本机删除同一条路径）。
  删的若正是开着的那张，Mac 顺手关纸；回推 `scratchpads` + `scratchStrokes`（后者此时是空表）。
- `scratchRename`：平板请求改第 `index` 张纸的名字。空串 = 清掉自定义名，回到「草稿纸 N」兜底显示。
  Mac 只做 trim，不做去重/长度限制（同本机改名）。

以上三条与 `scratchPaper`/`scratchMove` 同一套防御风格：**`index` 越界整帧丢弃**，
Mac 判定 + 落库后以 `scratchpads` 全量回推为权威，客户端不自作主张改本地列表。

**视口不上线**：每一端的滚动/缩放/minimap 各自独立（用户明确要求），打开一律回到画布原点。
库里也不存视口——存了就会变成「谁最后关谁说了算」的跨端争用。

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
