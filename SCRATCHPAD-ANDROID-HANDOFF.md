# 草稿纸 · 安卓端交接文档

> 写给**接手做安卓草稿纸**的人。Mac 与网页两端已于 2026-08-07 落地并提交
> （`c2c9c91` / `cd46212` / `23ae031` / `28febb8`），**契约已经定死**，安卓照着实现即可，
> 不需要也不应该再改协议或 schema。
>
> 权威文档：`PROTOCOL.md §4.4`（线格式 + 坐标系 + 纸样）、`REQUIREMENTS.md §1.8`（功能规格）、
> `TODO.md`「2026-08-07 草稿纸」条目（踩过的坑）。**本文只讲安卓要做什么、以及会在哪儿栽跟头。**

---

## 0. 这个功能是什么（30 秒版）

草稿纸 = **盖在 PDF 之上的一张无限白板**，不改 PDF 原文、不属于任何一页。

- 在页面任意处新建一张，页面上留一枚**图钉**标记「在哪儿建的」；打开时视口回到画布原点。
- **纸开着时笔迹只落在纸上**，PDF 上一点都不会留下。
- 无限但滑不丢：软边界 + 回中 + 适应内容 + minimap。
- 纸样：底色（预设纸色）× 底纹（纯色 / 点阵 / 小格）。
- **三端各自独立的缩放滚动**，同步的只有「有哪几张纸、开着哪张、纸上有哪些笔迹、纸样」。

安卓有两个模式，**两个都要做，但做法完全不同**：

| | 模式1（`local/`，独立版） | 模式2（`pad/`，输入板） |
|---|---|---|
| 数据来源 | 直接读写 `library.sqlite` | 走线协议，Mac 是唯一真源 |
| 谁决定「开着哪张」 | 自己 | **Mac**（`scratchpads.open`） |
| 笔迹落地 | 自己写 `note` kind=4 | 发 `ink`，等 Mac 回推 `scratchStrokes` |
| 新建/改纸样 | 自己写 `scratch_pad` 表 | 发 `scratchAdd` / `scratchPaper` 请求 |

---

## 1. 🔴 画布坐标系（最重要的一条，弄错了全盘皆错）

**单位 = 逻辑点**（macOS pt / CSS px / Android **dp**），原点 = 创建那一刻的视口中心，
x 向右、y 向下，**无界且可负**。

- 草稿纸上的笔迹点集**不是页内 0~1 归一化**。`Stroke.pts` 里放的是画布坐标，
  可以是 `-1203.5`，也可以是 `8000`。
- `Pen.w`（笔宽）与页内笔迹**同语义**：zoom=1 时的屏幕宽度。
- 屏幕换算只有两条：
  ```
  screen = (canvas − viewportOrigin) × zoom
  canvas = viewportOrigin + screen / zoom
  ```

**⚠️ Android 特有的坑：dp vs px。** Mac 的 pt 和浏览器的 CSS px 都是「逻辑点」，
安卓的 `MotionEvent.getX()` 给的是**物理像素**。触点转画布坐标时必须先除 `density`，
渲染时再乘回去。搞混的表现是：**同一张纸在 Mac 上写的字，到安卓上大小差一个 DPR 倍数**
（3x 屏上差 3 倍，非常显眼）。

这个口径项目里已经定好了，别另起一套：`shared/PadConst.kt` 开头就写着「长度类常量的单位是
**dp**，用时乘 density 折成物理像素……dp ≈ CSS px，两端观感才对得上」。画布坐标属于同一类，
照那条办。

**这个坐标系为什么这么定**：为了让三端现成的笔迹渲染器原样复用。Mac 把 `inkDrawStroke`
的坐标映射抽成闭包、web 把 `buildGeom` 抽成 `buildGeomWith`，页内传「× 页宽」、
草稿纸传「(点 − 视口原点) × zoom」。**安卓要做同样的事**，见 §4。

---

## 2. 存储（schema v9，只跟模式1 有关）

Mac 已经把表建好了。**安卓端不建表、不迁移**（`LibraryStore.kt` 开头就写了这条纪律，别破例）。

### 2.1 新表 `scratch_pad`

```sql
scratch_pad(
  id TEXT PRIMARY KEY,
  document_id TEXT NOT NULL REFERENCES document(id) ON DELETE CASCADE,
  title TEXT NOT NULL DEFAULT '',
  anchor_page INTEGER NOT NULL DEFAULT 0,
  anchor_x REAL NOT NULL DEFAULT 0,   -- 页内归一化 0~1（图钉位置，**不是**纸的内容位置）
  anchor_y REAL NOT NULL DEFAULT 0,
  bg TEXT NOT NULL DEFAULT 'rgba(255,255,255,1.0)',   -- 自由 CSS rgba 串
  pattern TEXT NOT NULL DEFAULT 'dots',               -- 'plain' | 'dots' | 'grid'（v9）
  created_at TEXT NOT NULL, updated_at TEXT NOT NULL
)
```

排序一律 `ORDER BY created_at ASC`（**照抄 Mac**，顺序不一致会让「第 2 张纸」在两端不是同一张）。

### 2.2 纸上的笔迹**不另建表**

仍在 `note` 表，但：

- `kind = 4`（页内笔迹是 2）。安卓的常量表在 `local/store/LibraryModels.kt` 的 `object NoteKind`
  （现有 `TEXT=0 / CHAT=1 / INK=2 / HIGHLIGHT=3`），加一个 `SCRATCH_INK = 4`
- `page` 列**恒为 0**（画布不属于任何一页），别拿它做任何判断
- `payload` JSON 里多一个 `padId` 键，指回 `scratch_pad.id`
- `points` 是**画布坐标**（见 §1）

于是安卓端 `LibraryStore.kt` 的读取只要多一条按 `kind` 的分流：

```kotlin
// 页内笔迹：kind == 2（现有逻辑，一个字都不用改）
// 草稿纸笔迹：kind == 4，再按 payload.padId 分到各张纸
```

### 2.3 🔴 三个必须处理的边界

1. **表可能不存在**。安卓不建表，而工作区可能是**老 Mac（v7）建的、还没被 v8+ 的 Mac 打开过**。
   `SELECT * FROM scratch_pad` 会直接抛 `SQLiteException: no such table`。
   → 用 `PRAGMA table_info(scratch_pad)` 探一下，或把查询包在 try 里当「没有草稿纸」处理。
   **绝不能让它把整个开文档流程炸掉。**
2. **`pattern` 列可能不存在**（v8 建的库，还没被 v9 Mac 打开过）。同上，缺则兜底 `dots`。
3. **payload 要原地改，不能整体重建**。`Payloads.kt` 开头那条纪律对 `padId` 同样适用：
   payload 里可能有本端还不认识的键，重建会把它们抹掉。加 `padId` 就只 `put("padId", …)`。

> **顺带提醒**：草稿纸笔迹**不分图层**——`layerId` 对它无意义（Mac 端落库时仍会写，但
> 渲染/擦除一概不按图层过滤）。别顺手把页内那套图层可见性过滤套到草稿纸上，
> 更别去碰 `ink_layer` 表——它有个**已知未修的跨文档 bug**（见 `TODO.md`「已知 Bug」
> 与 `ANDROID-STANDALONE-PLAN.md §9.11`），跟草稿纸无关，别在这轮里搅进去。

### 2.4 删纸

删 `scratch_pad` 一行 **＋** 删掉所有 `padId` 指向它的 `note` 行。两步都要做——
Mac 端是靠内存对账做的，安卓这边得显式删。漏了第二步就是一堆无处可归的孤儿笔迹留在库里。

### 2.5 🔴 局部擦除必须继承 `padId`

`InkEdit.splitStroke` 切段时如果不把 `padId` 带给每一段，被擦过的笔迹会**当场从界面上消失**
（按 padId 过滤取不到），却以 `kind=2` 的身份留在库里**污染页内笔迹**。
Mac 端为此专门加了注释和测试用例，安卓的 `shared/InkEdit.kt` 要照做。

---

## 3. 协议（只跟模式2 有关）

`Sources/Resources/wire.js` 与 `Sources/Server/WireCodec.swift` 是双真源，
`android/.../pad/WireCodec.kt` 要跟它们**字节级一致**。

### 3.1 新增四条消息

| opcode | 名称 | 方向 | payload |
|---|---|---|---|
| `0x3D` | scratchpads | S→C | `u16 open` · `u16 n` · `n ×( str id, str title, u32 page, f32 nx, f32 ny, u8 r, u8 g, u8 b, f32 a, u8 pattern )` |
| `0x3E` | scratchStrokes | S→C | `u32 ackRel` · `u32 n` · `n ×( pen, u16 m, m × pt3 )` |
| `0x2B` | scratchOpen | C→S | `u16 index`（`0xFFFF` = 关闭 → 对象里 -1） |
| `0x2C` | scratchAdd | C→S | `u32 page` · `f32 nx` · `f32 ny` |
| `0x2D` | scratchPaper | C→S | `u16 index` · `u8 r` · `u8 g` · `u8 b` · `f32 a` · `u8 pattern` |

- `scratchpads.open` = 当前打开的是 `list` 里第几张，`0xFFFF` = 一张都没开。
- `scratchStrokes` = **当前打开那张纸**上的全量笔迹镜像，**没有 page 字段**。
  没开纸时 Mac 发 `n=0`，客户端据此清掉本地残留。
- `ackRel` 语义与 `strokes` 完全一致（按收件人填，用来分辨中途快照）。安卓已有那套判据，照用。
- `pattern` u8：`0=plain 1=dots 2=grid`，越界回退 `dots`（同 brush/mode 的编码惯例）。

### 3.2 🔴 RT 流一个字节都没改

Mac 是「当前开着哪张纸」的唯一真源。**纸开着时**：

- 客户端把触点换算成**画布坐标**再发 `ink`/`erase`，`page` 字段作废（填 0 即可，Mac 不读）；
- Mac 收到后整条走草稿纸链路，不会落到 PDF 页面上；
- **`probe`（长按环形选笔盘）在纸上不生效**——那套判定全建立在页内归一化 + `padGeom.pageW` 上，
  喂画布坐标进去阈值会整个失真。**安卓端在纸开着时也不要发 probe、不要呼盘。**

所以模式2 的改动量比看上去小：`ink`/`erase` 的编码函数一行都不用动，只要**在换算坐标那一步分叉**。

### 3.3 🔴 测试向量的行号纪律

`spike/wire-codec-test.swift` 的 canonical 表**只允许在末尾追加**，
`android/.../WireCodecTest.kt` 是按**行号索引**去对 `spike/wire-vectors-swift.txt` 的。

现状：向量共 **64 条**，安卓测试目前只断言前 **56** 条（草稿纸那 8 条是 #57~#64，安卓还没覆盖）。
本轮 Mac 侧改动**只追加、没往中间插**，所以安卓现有测试仍然全绿（已实测：`WireCodecTest` 5/5、
`InkEditTest` 3/3）。

**你要做的**：把 #57~#64 补进 `WireCodecTest.kt`。重新生成向量的命令：

```bash
swiftc spike/wire-codec-test.swift Sources/Server/WireCodec.swift -o /tmp/wct && /tmp/wct
node spike/wire-cross-test.js      # Swift↔JS 字节级比对，应当 128 通过
```

向量里特意放了两个**容易被兜底逻辑吃掉**的值，别漏测：
- `scratchpads.open = -1`（线上 `0xFFFF`）
- `scratchPaper.pattern = "plain"`（编码为 **0**，最容易被 `?: 1` 这类兜底悄悄改成 dots）

---

## 4. 渲染（两个模式共用）

### 4.1 复用现成的笔迹渲染器，别抄第二份

`shared/InkRenderer.kt` 的 `drawStroke(c, s, m: PageMapper, ox, oy)` 现在是**按页**取几何的：
它从 `PageMapper` 拿页的 left/top/pw/ph，再把归一化点乘上去。

草稿纸要的是另一套映射。**照 Mac 与 web 的做法办**——把坐标映射抽出来，让两条路走同一份
几何构建与上色代码：

- Mac：`inkDrawStroke(_:in:inkScale:map:)`（`Sources/Views/InkLayers.swift`）
- web：`buildGeomWith(s, px, py, wScale, key)`（`web/src/lib/render.ts`）

安卓建议同样把 `build(pen, pts, pw, ph)` 泛化成「给我一个点→像素的映射 + 一个线宽倍率」。
**抄一份出来的后果**：四种笔型（ballpoint / fountain / marker / pencil）的观感立刻分叉，
而 §5 的路线图 ⑤（三端算法统一）已经搁置，分叉了就没人给你合回去。

线宽：草稿纸上 `lineWidth = strokeWidthFor(...) × zoom`——**放大就该连笔迹一起放大**，
无限画布上「放大后线还是 2px」等于改了画的内容。（这一点 Mac 与 web 已统一，安卓照做。）

几何缓存：几何建在「画布坐标 × zoom」里，于是**平移只是 translate，缓存不失效**，只有缩放才重建。
安卓 `InkRenderer` 已有 LRU 缓存，缓存键把页宽换成 zoom 即可。

### 4.2 底纹（`plain` / `dots` / `grid`）

**这三个数是三端契约，Mac 与 web 已经对齐，安卓必须一致**，否则同一张纸在两端格子大小不一样：

| | 值 |
|---|---|
| 画布步长 | 从 **24** 起，按 **2 的幂**折算，直到屏幕间距落进 **[22, 88] px** |
| 点（dots） | 边长 `max(1.5, min(3, zoom × 1.8))`，不透明度 **0.18**，**方点不用圆点** |
| 线（grid） | 线宽 1，不透明度 **0.085** |
| 原点十字 | 半长 9，线宽 1，不透明度 **0.16**（画布 0,0 处；`plain` 时连它也不画） |

参考实现：`Sources/Views/ScratchCanvasLayers.swift` 的 `ScratchGridLayer`、
`web/src/lib/scratch.ts` 的 `drawPattern`。

**🔴 底纹墨色由「纸色明度」推，不许跟系统深浅外观走**：

```kotlin
val inkIsDark = (0.299 * r + 0.587 * g + 0.114 * b) / 255 > 0.5   // 浅纸 → 深纹
```

跟外观走的话，深色外观 + 白纸时网格会整个消失。**这条已经在 Mac 上以另一种形式栽过一次**
（工具栏发白，见 §7），别再犯。

同理：**夜间模式下草稿纸不反色**——它是一张纸，不是 PDF 内容。安卓两模式的夜间实现（bg 反色滤镜）
都要把草稿纸层排除在外。

### 4.3 方点为什么不用圆点

底纹层每帧平移都要重画，平板全屏一屏可能上万个点。圆点（`drawCircle`/`addEllipse`）比
方点（`drawRect`）贵得多，而 1.5~3px 上两者肉眼无差。

---

## 5. 无限画布的行为

### 5.1 软边界（用户明确要求，不能省）

真无限会让人一路滑进空无一物的远方再也找不回来。规则只有一条：

**可视区必须与「内容包围盒 ± 1.5 屏」相交，越界即拉回。**

内容为空时退化成「围着原点的一块」，于是新建的空白纸只能在原点附近小范围移动。
参考 `ScratchBounds`（`Sources/App/ScratchPadModel.swift`）。

### 5.2 回中 / 适应内容

- **回中** = 画布原点回到视口正中、zoom 复位 1。这就是「打开后从该处显示」的落点。
- **适应内容** = 把全部笔迹的包围盒（留边距）装进视口；空纸退化为回中。
- **打开一张纸一律回中**，不恢复上次视口——视口**不落库也不上线**（三端各自独立的缩放滚动
  就是靠这一条；存了就变成「谁最后关谁说了算」的跨端争用）。

### 5.3 minimap

右下角小窗：全部笔迹**骨架线**（不必还原笔型/压感）+ 当前视口框，点/拖即跳。
Mac 侧踩过两个观感坑，安卓照着避开：内容与视口框**别贴边**（留内边距 + 圆角裁剪），
视口框**别用重实线**（会比笔迹还抢戏，改淡填充 + 细描边）。空纸时干脆不显示。

### 5.4 橡皮半径换算

`eraser.size` 是**页宽归一化**的（0.02 = 页宽 2%），而草稿纸没有「页宽」。三端统一按：

```
画布半径 = eraserSize × 800      // ScratchPad.eraserRefWidth
```

**800 这个数三端必须一致**，否则同一次擦除在两端擦掉的笔迹不一样多。

---

## 6. UI 落点

### 6.1 模式1（独立版）

- **入口**：`shared/TopBar.kt` 加一枚图标（`topBar.icon(key, iconRes, desc) { … }`，
  窄屏会自动收进 ⋯ 溢出菜单，不用自己处理）。点开列出本文档的草稿纸 + 「在当前位置新建」。
- **面板**一律走 `shared/Sheet.kt`（十处弹窗已全部统一到它，别再用框架默认样式）。
- **图钉**：画在页面上（`LocalCanvasView` 的绘制链路里），点开对应的纸。
- **纸样面板**：底纹三选一 + 纸色六选一。色板见 `ScratchPad.paperPalette`
  （纸白/米白/浅灰/牛皮/护眼绿/淡蓝）——**这不是契约**，`bg` 是自由 CSS rgba 串，
  安卓可以给一样的六个，也可以多给几个，不影响任何一端解码。
- **落笔路由**：纸开着时，`LocalCanvasView` 的落墨/擦除全部改走画布坐标 + 写 kind=4。
  **PDF 上一笔都不能留**——这是这个功能的定义。

### 6.2 模式2（输入板）

- **跟随 Mac**：收到 `scratchpads` 就照做（开/关/换纸），本地只发请求不自作主张。
  换纸时要丢掉上一张的本地状态并**回中**（与 Mac 的 `.id(pad.id)` 同语义）。
- **入口**：顶栏同款按钮 → 列表（切换 + 新建）+ 纸样面板。
- **网页端可以直接抄交互**：`web/src/PadBar.svelte` + `web/src/lib/scratch.ts` 就是同一个
  设备形态（触摸 + 笔）上已经做过一遍的答案——单指平移、双指捏合、笔落墨、
  minimap 可点可拖、图钉**手指单击**打开（**不认笔**：笔是用来写字的，让笔点图钉必然会在
  图钉上落笔时误触发）。
- **写库？不写。** 模式2 一行库都不碰，笔迹真源在 Mac。

### 6.3 UI 纪律（`ANDROID-STANDALONE-PLAN.md §9.6` 已有，这里只提醒）

扁平 / 原生 / 颜色只走语义名。新图标进 `res/` 的手写 VectorDrawable。

---

## 7. 前面两端踩过、你大概率也会踩的坑

1. **白纸铺到工具栏底下 → 工具栏当场看不见**。macOS 26 的玻璃工具栏图标颜色跟外观走
   （深色外观 = 白图标），白纸一路铺过去就是白压白。Mac 的修法是在工具栏那条带子后面
   铺回阅读区自己的底色。**安卓的沉浸式顶栏/状态栏有完全一样的风险**，尤其是深色主题下。
2. **非激活控件在半透明底上看不清**。Mac 首版用了低对比的默认按钮样式，用户当场报「看不清」。
   安卓要注意同一件事：纸是浅色的，压在纸上的浮层控件必须显式给足对比度。
3. **底纹太淡等于没有**。首版点阵是 1.6px / 0.10，用户报「基本看不出来」，
   现在是 3px / 0.18。**§4.2 的表是改过之后的值，直接用，别自己重新拍。**
4. **样张的复刻不完整 = 白看**。Mac 侧有 `spike/scratch-look.swift`（ImageRenderer 出样张），
   但第一版漏画了缩放读数，于是「逐张看过」照样漏了它的对比度问题。
   安卓这边如果也做样张（模拟器 `screencap` 逐像素量是既有手段，见 §11.2），
   **要确保样张里的元素与真实界面逐件对齐**。
5. **模拟器能证明什么、不能证明什么**：`ANDROID-STANDALONE-PLAN.md §11.2` 已经写清楚。
   像素值与布局 bounds 是能证明的，「好不好看」「手感如何」不是——那些一律攒进 §11.1 等真机。

---

## 8. 建议的推进顺序

> 每步都能独立验证，别攒到最后一起调。

1. **数据层（模式1）**：`scratch_pad` 读写 + kind=4 分流 + `padId` 进 payload +
   表/列缺失的兜底 + 删纸连带删笔迹 + `splitStroke` 继承 `padId`。
   验证：仿 `spike/scratch-store-test.swift`（44 条）写一份 androidTest，
   用 Mac 建的真库跑一遍（**跨端读同一个库**才是这层的意义）。
2. **协议（模式2）**：`WireCodec.kt` 四条新消息 + `WireCodecTest.kt` 补 #57~#64。
   验证：`gradle test`，字节要与 `spike/wire-vectors-swift.txt` 逐字节相同。
3. **渲染**：`InkRenderer` 泛化坐标映射 + 底纹层 + 画布坐标的笔迹绘制。
   验证：模拟器上写几笔，`adb pull` 库文件（**记得带 `-wal`**，否则看到的是旧数据）
   拿到 Mac 上打开，笔迹位置/大小应当与安卓上一致。
4. **无限画布交互**：平移/缩放/软边界/回中/适应内容/minimap。
5. **UI**：入口、列表、图钉、纸样面板；两个模式各接一遍。
6. **模式2 联调**：Mac 开纸 → 安卓跟过去；安卓落笔 → Mac 上出现；纸样两端互改。

---

## 9. 关键文件对照表

| 关心的事 | Mac | web | 安卓（要改/新建） |
|---|---|---|---|
| 数据模型 + 坐标系契约 | `Sources/App/ScratchPadModel.swift` | `web/src/lib/shared.ts`（`Pad`） | `local/store/LibraryModels.kt`、`shared/Ink.kt` |
| 表读写 | `Sources/Store/LibraryStore.swift` | — | `local/store/LibraryStore.kt`、`Payloads.kt` |
| 落墨/擦除/开关纸 | `Sources/App/AppModel+Scratch.swift` | `web/src/lib/scratch.ts` | `local/LocalCanvasView.kt`、`pad/PadView.kt` |
| 线格式 | `Sources/Server/WireCodec.swift` | `Sources/Resources/wire.js` | `pad/WireCodec.kt` |
| 覆盖层 UI | `Sources/Views/ScratchPadView.swift` | `web/src/PadBar.svelte` | 新建（建议 `shared/ScratchPadView.kt`，两模式共用） |
| 画布层（网格/笔迹/minimap） | `Sources/Views/ScratchCanvasLayers.swift` | `web/src/lib/scratch.ts` | 新建（建议 `shared/ScratchCanvas.kt`） |
| 样张自查 | `spike/scratch-look.swift` | — | 模拟器 `screencap` |
| 持久化测试 | `spike/scratch-store-test.swift`（44） | — | 新建 androidTest |

---

## 10. 怎么编译与测试（安卓）

`android/` 是**独立 git 仓库**（改动在那边单独提交），**构建与验证的权威说明在 `android/AGENTS.md`**：

```bash
cd android
./gradlew test            # 单测（wrapper 已补齐，2026-08-12 起不必再找 ~/.gradle 里的裸 gradle）
./gradlew assembleDebug   # 打包
```

模拟器验证的四个已知坑（`ANDROID-STANDALONE-PLAN.md §11.2`，别重新踩）：
`adb pull` 库要**带 `-wal`** / 按文本点击别记坐标 / stylus swipe 终点走不到 / 长按用分次 motionevent。

---

## 11. 验收（真机，不能自证）

手感/观感类结论**一律不能靠模拟器或截图自证**，攒进 `ANDROID-STANDALONE-PLAN.md §11.1` 等真机。
至少要覆盖：

- 新建 → 是否从创建处（画布原点居中）打开；页面上图钉位置对不对、点得开吗。
- **笔迹只落纸上**：纸开着时在 PDF 区域怎么画都不该留下东西。
- 平移/捏合缩放手感；软边界会不会「拉不动」得莫名其妙；回中/适应内容/minimap。
- **笔迹大小与 Mac 一致吗**（§1 的 dp 坑就看这个）。
- 底纹三种 × 纸色六种的观感；深色主题下底纹会不会消失。
- 橡皮半径手感（`eraserRefWidth=800` 是拍的，不对就调——**但三端要一起改**）。
- 模式2：Mac 开纸 → 安卓自动跟过去；笔迹双向同步；**缩放滚动与 Mac 各自独立**（设计前提）。
- 边界：一篇文档多张纸来回切、关文档再开笔迹还在、删纸后笔迹一并清掉。
