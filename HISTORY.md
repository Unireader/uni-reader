# UniReader HISTORY

> 已完成事项归档。**规则（2026-07-25 用户定）**：`TODO.md` 里完成的条目做完即迁移到这里，
> TODO.md 只留进行中/待办/交接状态。本文件按时间倒序 + 主题专节组织。

## 已修（2026-08-29，切标签页每次重下页图 → 两端各加磁盘缓存 / 框选一移动就没了）

用户两条：① 安卓的框选「移动后就消失了，调整为点击其他区域后消失」；② 模式2 的多标签页
「切换的时候始终要重新加载 PDF 页，做一下内存缓存」。②**改了一版没解决**，用户复测「还是会重新
加载」，第二轮把账算清楚才找到真原因，并按用户提的方向（「不管 macOS 还是安卓端都可以利用好
磁盘缓存」）在**两端各加了一层磁盘缓存**。

### ② 页图「每次切标签页都要重下」——三个原因叠在一起

1. **平板换文档就把整份内存缓存倒掉**（`PadActivity.onLayout` 里的 `fetcher.clear()` = `evictAll`）。
   缓存键里本来就带 `v`（Mac 的 `contentHash`），两篇文档的页图根本不会串——清是纯浪费。
2. **Mac 换文档也把它那份倒掉**（`AppModel.setPadRender` 里的 `pageCache.removeAllObjects()`），
   同样的错、同样的理由（键里带 `padRenderKey` = contentHash）。于是平板即便来要，Mac 也得
   **从头渲一遍**，而这活儿占的是 `LANServer` 那条**串行** queue（笔迹 RT 与 WS 广播在同一条上）。
3. **光不清也不够，内存在算术上就装不下**（这是第一版没解决的原因）：横屏一张目标档页图
   2880×4073×4 ≈ **47MB**，而 `LruCache` 额度 = 堆/3，小米 Pad 6 无 `largeHeap` → 堆 256MB
   → 额度 85MB → **同时只装得下一张**。换篇文档翻一页，上一篇必然被挤光。
   ⚠️ 第一版还从这 85MB 里**切了 32MB** 给低清档 → 目标档只剩 53MB，比改之前更糟。
   **低清/字节这类小格必须是「加」上去的，不能从总额里切。**

**改动**（平板 `pad/PageFetcher.kt` + 新 `shared/PageDiskCache.kt`；Mac `AppModel.renderPage` +
新 `Sources/Server/PageDiskCache.swift`）：

| 层 | 平板 | Mac |
|---|---|---|
| 位图/字节 内存 | 目标档（堆/3）+ 低清档（额外 ≤24MB）+ 压缩字节（≤32MB） | `pageCache` NSCache 256MB（换文档**不再清**） |
| **磁盘** | `cacheDir/pageimg`，512MB LRU | `~/Library/Caches/<bundleid>/padpage`，1GB LRU |

- 磁盘存的都是**压缩字节**（Mac 回的 JPEG 原样）：一页才 200~600KB，512MB 装得下上千页、
  好几篇书。键 = 内存那个键（含 contentHash → 改了内容自然换键），文件名折 SHA。
  LRU 按 mtime，超额从最旧删起（删到 90%）；放 `Caches`/`cacheDir`，系统紧张时可自行清掉。
- 于是「切回刚才那篇」的账变成：低清位图立刻贴 → 目标档**从磁盘读几毫秒 + 解码 450~770ms**，
  全程不惊动 Mac。Mac 侧即使被问到，也多半是磁盘命中（几毫秒），不再占串行队列渲图。
- **仍不是「切回来立刻清晰」**：那要求上一篇的目标档**位图**整张留在内存，85MB 装不下。
  三条候选都要先跟用户确认取舍：`largeHeap`（→ 512MB 堆，额度翻倍）、页图解码改 `RGB_565`
  （字节减半、可能有色带）、位图改 `Config.HARDWARE`（走图形内存不占 Java 堆，但不能再被
  软件 canvas 读写）。
- 模式1（本机 Pdfium）**没加磁盘缓存**：那边"重渲"本身就是一次 JPEG 解码 + 缩放，与"读盘 + 解码"
  一个量级，换不到什么，还要多花磁盘与一次编码。它已有的对策是背景标签页把缓存缩到 32MB。
- 已知未做：切文档时 `setPages(reset)` 把滚动清零，`viewport` 广播到达之前会先按第 0 页要一轮图
  （首次进这篇时那一轮是白费的）。属旧行为，不在本次范围。

### ① 框选移动/缩放后选中集留在屏幕上

从前提交后一等到真源镜像回来就 `clearLasso()`——高亮框、手柄、光晕全没，想再挪一次得重新框一遍。
Mac 本来就不是这样（`commitLassoMove` 末尾把 `bounds` 平移后写回 `lassoSelection`），是安卓少做了一步。
现在改成 `settleLasso()`（`shared/PageCanvasView.kt`，两模式共用）：把选区**多边形**按刚提交的那次
变换走一遍（逐点过 `lassoGhost`，含同一套页内 clamp），拿它在真源的新数据上重判一次命中，
乐观变换退场、选中集留下。

- **为什么按多边形重判而不是按 id 认领**：模式2 的笔迹根本没有 id（线格式不传，见 `Ink.Stroke`）。
  而多边形重判恰好与真源下一次收到 `lassoMove` 时的复判是**同一口径**（平移/缩放是仿射变换，
  点在多边形内的关系原样保持），接着拖第二次时两端看的就是同一个多边形。命中为空
  （选中项已被擦除/删除）→ 清，同 Mac 的 `changed == false` 分支。
- **模式1 要推迟一轮消息再结算**（`postSettleLasso`）：那边一趟回推带齐两层，但 `applyStrokes` /
  `applyNotes` 是先后两次调用——在 `setStrokes` 里当场重判会拿**还没更新的注解**去比新多边形，
  注解那半必然落空。模式2 的分层记账（`lassoMirrorSplit`）不受影响，仍是两条镜像到齐才结算。
- **整表替换后要重判**（`refreshLassoSelection`）：选中集现在会一直留着，而擦除/图层显隐/别处的
  框选都会整表换掉 `strokes`，旧下标不再指向同一条笔迹——不重判，光晕就会画到不相干的笔迹上。
- **点击语义**：纯点击（未越过死区）**点在选中框外**才清（含 8dp 抓手余量，与「拖框内 = 移动」
  同一判据）。Mac 是无条件清，安卓这边刻意更宽松一档——用户要的就是「点其他区域才消失」。

验证：安卓 `assembleDebug` + `test`、Mac `xcodebuild` 全绿。**真机待验**（见 TODO 接下来第 16 条）。

## 完成（2026-08-29，内存占用：打开一个 PDF 就 900MB → 滚 65 页 543MB）

用户报「debug 包打开一个 pdf 就占用了 900MB」。`footprint`/`vmmap` 实测（900×450 窗口、
199MB 高清扫描 PDF 340 页）：**纯滚动 60 页、零缩放就能到 1604MB，峰值 1763MB**，且空闲永不回落。

### 根因（按发现顺序，每一条都是实测钉死的）

1. **一张页图在进程里存了三份，而缓存只按一份计费**。vmmap 数出 30/30/30——同一批图同时在
   `MALLOC_LARGE`(CG 的 DefaultPurgeableMallocZone) / `CG raster data`(SM=COW) /
   `CoreAnimation`(SM=SHM)，三者精确字节数互不相同（17,432,576 / 17,383,424 / 17,498,112），
   是三份真拷贝不是重复计账。而 `RenderImageCache` 传的 `cost` 是 `bytesPerRow*height` = 一份
   → 它以为 498MB/512MB 上限，实际吃 1.5GB。设置页写「512 MB」= 真吃 1.5GB。
2. **缩放单调累加**：`baseKey` 含 `pixelWidth`，每档缩放一整套新图，而 `fallbackBase` 只查
   `recentBaseWidths` 那 4 个——挤出名单的整套图从此谁也找不到，纯死重。⌘+ ×5 涨 723MB、
   ⌘0 回 fit 只掉 24MB（那 24MB 还是 IOSurface 释放贴片）。
3. **关窗/换文档不清缓存**：`RenderImageCache` 连 `removeAll` 都没有，只 `setWanted([])`。
4. **贴片与基图共用一个池**：贴片是视口尺寸、单价常比整页还高，而 `tileKey` 把矩形量化到 1/64，
   平移一格就是新键 → 放大后平移几下就能把基图全挤光。
5. **`CGContext(data: nil)` + `makeImage()` 的缓冲不还**：两者共享 COW 缓冲，缓冲归 CG 的
   purgeable zone 管，CGImage 释放后它不跟着还。实测 31 块 17,432,576B 的 `MALLOC_LARGE`
   而活着的 CGImage 只有 11 张 → 20 块 ≈ 348MB 是孤儿，且窗口改尺寸后仍冻在旧尺寸。
6. **像素格式不是 CA 原生格式 → CoreGraphics 每次合成都要转换，转换结果还被它按固定条数缓存住**
   （**本轮最大的一笔**）。原来用 RGBA(`premultipliedLast`)，而 Apple Silicon 上 CoreAnimation 的原生
   格式是 BGRA/BGRX。表现：`MALLOC_LARGE` 一路涨到 **31 块就不涨了**（31×16.6MB≈515MB），静置不降、
   `Reclaimable=0`、改缓存上限完全无效——因为那是 CG 的副本，不是我们的图。
   判别实验：往前滚 24 页 → 涨到 416MB；退回同样 24 页 → 515MB；**再走第三遍同样的页 → 一点不涨**
   （按页缓存、条数封顶）。
7. **malloc 的 large cache 不还给系统**：改成自持 `malloc` 缓冲后，`PageBitmap` 自己数的存活位图
   只剩 4 张/66MB（free 回调确实跑了），`vmmap` 的 `MALLOC_LARGE` 却仍是 632MB。
   ⚠️ **`vmmap` 会把这些块照样列成「已分配」**，光看它会得出「有人在持有」的错误结论（被骗了一轮），
   **以 `PageBitmap.liveImages` 为准**。

### 改动

- `PageRenderEngine`：① `copiesPerImage` 计费系数（现为 **2**，改前先复测三个 zone）；
  ② 基图/贴片**两个独立 LRU**（3:1 分总额）；③ `purge(doc:)`（关窗/换文档，带「别的窗口还在看
  就跳过」的守卫）与 `purgeBase(doc:pixelWidth:)`（缩放换宽度，带「任何窗口仍 wanted 的键不动」守卫）；
  ④ `trim(toFraction:)` + `DispatchSource` 内存压力源（warning 砍半 / critical 砍到 1/4，
  **不改 limit**，压力过去照常回填——与「本缓存不做机会性驱逐」不冲突，那条针对的是 NSCache 的无端清空）；
  ⑤ `trim()` 加 `t !== head` 守卫：单张图自己就超上限时（大窗口高倍贴片能上百 MB）不留这条会写入即自我淘汰、
  缓存恒空、每次 settle 重渲同一张；⑥ `relieveMallocPressure`（限流 2s + **尾随 1.5s**，
  尾随不能省——限流会吞掉最后几次淘汰，而渲染一停就再没人来催）。
- `PageBitmap.draw`（三处，缺一不可）：
  · **像素格式改 BGRX**（`noneSkipFirst | byteOrder32Little`）—— CA 原生格式，CG 不再转换、不再缓存副本。
  页图是不透明的（整张填白后才画 PDF），连 alpha 都不需要。**这一条单独就把滚动路径从 543MB 砍到 275MB。**
  · **自己 `mmap` 像素缓冲 + `CGDataProvider` 回调 `munmap`**，不再走 `CGContext(data: nil)`+`makeImage()`。
  用 mmap 而非 malloc 是为了绕开分配器的大块缓存，释放即还给内核。副作用：`CG raster data` 整类归零。
  · 行宽显式对齐 64 字节；另加 `liveImages` 存活计数（alloc/free 各记一笔）——排查「缓存淘汰了内存却
  不降」时以它为准。
- `ReaderSurface.adoptBaseWidth`：被挤出 `recentBaseWidths` 的宽度连带 `purgeBase`。
- `PageStreamView.onDisappear`：`purge(doc:)`（**必须排在 `setWanted([])` 之后**，否则守卫
  把自己当成「还在看」而跳过）；`DocSession.teardown` 同样清一次（赶在 `contentHash` 清空前）。
- 默认上限 512 → **256**（`ContentView` 与 `SettingsView.@AppStorage` 两处必须一致）；
  设置页加实时诊断行（`TimelineView(.periodic)`——设置窗不销毁，静态取值会一直显示第一次打开时的快照，
  被这个骗过一次）。

### 实测对比（同一协议：900×450 窗口、⌘0 后滚 ~65 页 / ⌘+ ×5）

| 场景 | 改前 | 改后 |
|---|---|---|
| fit | ~200 MB | 207 MB |
| 纯滚动 ~65 页 | **1604 MB**（峰值 1763） | **275 MB**（−83%） |
| 同上的 `MALLOC_LARGE` | 270~515 MB | **17 MB** |
| ⌘+ ×5 | 994 MB，⌘0 只掉 24MB | 612 MB（峰值 641） |

回归：`render-rotation-test` 9/0、`page-layout-test` 25/0（它编译的正是改过的 `PageBitmap.swift`）、
`page-snip-test` 34/0、`xcodebuild` 通过；真机截图确认**日间/夜间两种模式**渲染都无通道错位
（红色水印仍是红的——BGRX 字节序搞反的话会红蓝互换，这是必查项；夜间走 `CIColorInvert`+`CIHueAdjust`
另一条路径，也要单独看一眼）。

### 留在 TODO 的尾巴

缩放路径仍有 ~612MB，但性质变了：现在几乎全是**我们自己的图**（`VM_ALLOCATE` 201MB ↔
`CoreAnimation` 198MB，仍是干净的 1:1），根源是「缩放后页图本身就大」——`basePixelCap=2800` 下
一页 49MB，而 fit 只有 17MB。见 TODO 对应条目。

## 完成（2026-08-29，笔迹闪烁：缩放期改用**墨迹位图快照**，零重画）

页面不闪之后，用户报「手指缩放和按键缩放都会让笔迹出现闪烁」，并直接给了取舍：
**「可以先糊一点，然后再更新」**——这就是这一节做的事。

- **为什么会闪**：缩放中墨迹每帧重画，而快速路径按**屏幕距离**抽稀——每帧缩放比不同、保留的点
  就不同，笔画轮廓于是每帧微微变形；再叠加页面进出视口时整层的出现/消失。只要缩放期间**不重画**，
  两个来源同时消失。这也是为什么前面那一串"把单次绘制做快"的优化治不了它：**闪的根源是"每帧都在画"，
  不是"画得慢"**。
- **做法**（`ReaderSurface.makeInkSnapshots` / `PageCellView.inkSnapshot`）：
  · `beginFastInk()` 起手时，把当前要显示墨迹的页各用 `ImageRenderer` 渲成一张 `CGImage`
  （走 `fast` 的整层分组绘制，不是高质量那条；`scale = 1`，缩放中本来就允许糊）；
  · 缩放期间页元胞显示这张位图，只做纹理拉伸——**一笔都不重画**；
  · 缩小时新滑入实化窗口的页在 `updateRealized` 里**当场补渲一张**（否则那几页没得可拉伸，
  只能退回逐帧重画，日志里就是 `重绘页 p114×4 p111×2 …` 这种视口边缘的页在闪）；
  · `settleRender` 清空 `inkSnaps` → 自动回到矢量 Canvas 按最终倍率重画一次 → 清晰。
- **实测**：缩放期间 `墨迹绘制 … 共 0ms`，重绘页只剩 `p-1`（那是快照生成本身的记账，不是屏幕重绘），
  起手渲快照 **4~7ms**（2~4 页），帧率 54~69fps。缩放期墨迹成本演进：
  **9.6ms/帧（起点）→ 4.3ms/帧（快速描边+抽稀+分组）→ 0ms/帧（快照）**。
- 前面那一串快速路径**没有白做**：快照正是用它渲的（一页几毫秒 vs 高质量的 27ms），
  起手成本能压到一帧以内全靠它。
- 已知边界（都是可接受的取舍）：① 缩放中笔迹是拉伸的位图，会糊，松手即清晰；
  ② 快照在缩放期间不更新，若此刻平板正好写入新笔迹，那一笔要等 settle 才出现（缩放时不会同时写字）；
  ③ 视口外（`inkWanted` 之外）的页缩放中不显示墨迹，settle 后恢复。

## 完成（2026-08-29，缩放时页面闪烁：两处都是上一轮为省性能引入的回归）

卡顿修完后用户报「放大缩小的时候 PDF 页会闪烁」。两个源头都是上一节那几刀的副作用：

1. **实化窗口会收缩了**（上一节为了灭 74 页那个坑，把"只扩不缩"整个去掉）。`realized` 一收缩，
   刚还在屏幕上的 `PageCellView` 当场销毁，下一帧视口晃回来又得重建 —— **闪的是视图的销毁重建**，
   而我当时以为保住"缩放期间不驱逐 `images`/`tiles`"就够了（那只保证重建后有图，保证不了不闪）。
   🔴 正解是**只扩不缩 + 上界**：当年闯祸的是"无上界"，不是"只扩不缩"本身。现在合并窗口，
   但合并结果超过「当前视口窗口 + 8 页」就放弃合并、直接跟随视口 —— 日常缩放里窗口是稳的
   （实测单次缩放内连续多帧同值），只在 offset 真跑远了才收一次。实化稳定在 2~7 页。
2. **页图插值被降成了 `.low`**（上一节为省几毫秒改的）。最近邻式采样在**缩小的文字页**上会产生
   密集噪点，而页面尺寸每帧微变、噪点图案跟着变 —— 看起来就是整页在闪。改 `.medium`（双线性）：
   无噪点，也不用付 `.high` 的多重采样。
   🔴 教训：降画质省性能时，**要看的是"降完长什么样"，不是只看省了几毫秒**——`.low` 省下的那点
   时间，代价是把静态的糊变成了每帧都在变的噪声。

顺带把 `inkWanted` 的余量从半屏加到**一屏**：余量太小时同一页会在"要画/不画"之间反复横跳，
那本身也是一种闪烁（墨迹一会儿有一会儿没有）。

代价：实化页数回到 2~7 页（原来 2~4），墨迹 3~7ms/帧、44~56fps（原来 60~68fps）。
**这个交换是划算的**——掉帧在这个区间用户感知不到，闪烁一眼就看得见。

## 完成（2026-08-29，缩放卡顿收尾：自激循环 / 60Hz 限流 / 整层分组 / 缩放期降插值）

用户反复报「有笔迹的很卡、没笔迹的很丝滑」，且**上面几刀之后仍然卡**。这一轮全程用 `ZoomProbe`
读真机数据（我自己驱动 ⌘-/⌘= 跑，与工具栏按钮同一条路径），逐项砍：

1. **`verifyPendingTarget` 的自激循环**（最隐蔽的一条）：缩放每帧提交一个新的滚动目标，而
   `onScrollGeometryChange` 的回报是异步慢半拍的 → 每帧都判定"没达成"→ 补一次 `scrollTo` →
   再触发一轮几何回调 + body 重算。**每个动画帧因此有约 2 次 contentBody 求值**，日志里
   「几何回调」在 250ms 窗口占 33~64ms。加 `!isZooming` 后：**64ms → 0~4ms**。
   上一帧的目标本来就已作废，重试它没有意义；收尾那轮不在 `isZooming` 内，兜底照旧。
2. **提交限流到 ~60Hz**（`zoomAnimStep` 与 `pinchChanged` 各一处）：墨迹层的 Canvas 尺寸每帧变 →
   每次提交都要重画整页笔迹，ProMotion 屏按 120Hz 给帧等于这笔钱付两遍，而缩放动画 60 与 120
   肉眼分不出。**注意写法是「不提交也不推进 lastT」**，dt 累积到下次 tick，动画速度不受影响。
3. **实化窗口的一页滞后**：`realized` 是 `@State`，缩放中视口每帧抖一下就写一次 = 一轮 body 重算。
   新窗口被旧窗口包住且没大出两页时沿用旧的（**有上界**，与那个闯祸的"只扩不缩"不是一回事）。
4. **墨迹快速路径三连**（见下一节的 `fast`，这轮继续压）：
   · 按**屏幕距离**抽稀（缩放期 3pt）——用「408学习区」9.2 万个真实点实测：zoom 0.31 时点数只剩
   **16%（省 6.4 倍）**、0.55 剩 23%、1.0 剩 34%，**越缩越省**，正好压在越缩越卡的那一侧；
   · 整条一次 `stroke` 取代逐段（逐段的 API 调用开销才是主项，不是路径复杂度）；
   · **整层分组**（`inkDrawStrokesFast`）：按「颜色 + 0.5pt 粒度线宽 + 是否 marker」把整页笔迹并成
   几条 Path——这个库里 88.8% 是同一支笔，一页的 stroke 调用从 94 次降到个位数。
   样张 `spike/ink-fast-look.swift` 的「混合页」两张图逐张比对过：颜色/粗细/multiply 均未串组。
5. **缩放期把页图插值降到 `.low`**：缩放中显示的本来就是**旧宽度基图被拉伸**的糊图（新宽度要等
   settle 才渲），为它做 high 重采样纯属白付，而一张 2800px 基图的 high 插值每页每帧要几毫秒。

**最终真机读数**（组成原理 p116/p117 两页密页，按钮缩放）：
帧 15~17/250ms（**60~68fps**，即限流上限）｜最长帧 17~25ms｜墨迹 **4.0~4.5ms/帧**｜几何回调 0~5ms。
对比这一系列开始时：**36fps、实化 74 页、每帧 27.8ms、墨迹 9.6ms/帧**。

🔴 **剩下的瓶颈已不在墨迹**：每帧 16.7ms 里墨迹只占 4.3ms，其余约 12ms 是 SwiftUI 自身
（每帧重建 2~4 个 `PageCellView` 的十几层 + CA 提交），`⏱` 里其它计时段全部接近 0。
再往下只剩一条路：**墨迹位图快照**（settle 时渲成 CGImage，缩放中纯纹理拉伸 = 每帧 0 重画，
`spike/reader-zoom-probe.swift` 的 `.snapshot` 模式量过是 126fps 的上界），代价是一套
快照生成/失效/内存的机制，且 `ImageRenderer` 只能在主线程跑（settle 时一页约 24ms）。
**没做**——先看这一轮够不够。

🔴 **探针的两个坑**（读日志前必读，我自己都被坑过）：
① `frame()` 数的是 **contentBody 求值次数，不是屏幕呈现帧数**，别当 fps 用——我曾据此报"145~175fps
不掉帧"，而同一行里墨迹占着 41% 主线程；② `⚠️ 长帧` 里「本轮第 1~2 帧」的长间隔基本都是
**上一次操作后的静止期**（探针分不出"主线程被阻塞"和"这段时间没有更新需求"），要看的是动画中段。

## 完成（2026-08-29，工具栏缩放按钮"生硬"：定时长缓动 → 指数趋近）

上一节修完，捏合已经顺了（132~249fps），但用户报**工具栏放大/缩小按钮仍能看到卡顿**。
`ZoomProbe` 这轮加了「首帧延迟」与「长帧」两项，读数直接把性能嫌疑排除干净：

- 点下按钮到画面开始动 **1~3ms**；动画期间 **145~175 fps**、最长帧 **17~41ms**——帧一点没掉。
- 日志里那些 158/242/261ms 的"长帧"**全部落在 settle 之后的静止期**：探针分不出
  「主线程被阻塞 261ms」与「这 261ms 里压根没有更新需求」，是探针的歧义，不是卡顿。
  🔴 记账时看 `⚠️ 长帧` 那行的「本轮第 N 帧」：第 1~2 帧的长间隔基本都是**上一次操作之后的静止期**，
  真正要看的是**动画中段**的长帧。

于是问用户确认现象，答案是「动画太快太生硬」——**不是性能问题，是曲线问题**：

- 旧实现 = 定时长缓动（0.22s smoothstep，起止速度都是 0）。单次看着还行，**连点第二下会把速度
  重置为 0 再重新加速**，观感就是一跳一跳。
- 改成**指数趋近**目标倍率（`ZoomAnim` 重写：存 `target` + 滚动更新的锚点 `cCur`，每帧
  `zoom += (target − zoom) × (1 − e^(−dt/τ))`，τ=0.13s 是唯一的手感旋钮）。连点/连按只更新
  `target`，速度天然连续，越点越快地滑向更远的目标，没有到点急停。与 `ScrollFollower`
  的「纯临界阻尼低通」同一套手感哲学。
- 单帧提交改成与 `commitZoom` 同款**增量数学**（锚点内容坐标按比率滚动更新），不再依赖起始快照
  ——目标中途变化时旧的 `z0/c0` 快照会算出错的锚点。
- 顺手修掉一个续接的坑：续接时 `fitAfter` 必须**整个换成新命令的（含 nil）**。只在非 nil 时覆盖的话，
  「⌘0 动画途中按 1:1」会留着 ⌘0 的 `fitAfter`，到位后 fitBasis 重定标 + zoom 归 1，把 1:1 的结果当场吃掉。

## 完成（2026-08-29，双指缩放卡顿【真凶】：实化窗口在缩小时膨胀到 74 页）

前一节的墨迹快速描边真机上**仍然卡**。用户接着给了一句关键观察：「我缩放的页**根本没有笔迹**啊」——
这句把方向彻底掰正了。于是先加常驻探针 `ZoomProbe`（`Sources/UniReaderApp.swift`，
`touch ~/Library/Logs/UniReader-zoom.log` 开启，250ms 聚合一行），拿真机数据说话：

```
帧 9 (36 fps)  墨迹绘制 88 次  实化 96…169(74页)  重绘页 p98×4 p99×4 p100×4 p107×4 p110×4 p111×4
                                   ↑ 视口在 p128，却在重画 p98~p118
```

- **真凶**：`updateRealized` 缩放期间把实化窗口冻成**只扩不缩**。缩小时锚点缩放会让 offset 大幅
  移动，那个并集一路涨到 **74 页**（视口里只有 3 页）。成本与页数严格线性——实测
  **实化 14 页 = 195fps / 30 页 = 55fps / 74 页 = 36fps**，每页每帧约 0.25ms（视图构建/布局/渲染）
  外加有笔迹页每次约 1ms 的墨迹绘制。一帧 27.8ms 里，18ms 是那 70 个**看不见的页**。
  这也解释了用户那句观察：**卡的不是他在看的页，是实化窗口里那些看不见的邻页**。
- **改法两刀**：
  ① `updateRealized` 缩放期间**照实跟随视口收缩**（`if !zooming` 的"不驱逐图"守卫保留不变——
  当初"只扩不缩"是为了防白纸，但防白纸靠的是**不驱逐 `images`/`tiles`**，跟窗口大小无关，
  两件事当年被捆在一起了）；
  ② 缩放期间墨迹只画与**真实视口**相交的页（上下各半屏余量，`inkWanted`），实化窗口的
  预热 buffer 不必陪着重画墨迹；松手 `settleRender` 全量高质量重画一次，不留缺口。
- 🔴 **方法论教训（这次连错两轮换来的）**：spike 只能量"一次绘制多贵"，**量不出"每帧到底画了几页"**
  ——而后者才是主项。缩放性能的账必须从真机探针日志读，别再从 spike 外推。
  排查顺序也该更新：每帧 `@Published` → 每帧 `@State` → **每帧实化了多少页 / 重绘了哪几页** → 单次渲染成本。

## 完成（2026-08-28，双指缩放卡顿【第一刀，必要但不充分】：缩放期间墨迹走快速描边）

用户报「408学习区」里双指缩放有卡顿感，**换本没笔记的 PDF 就不卡**——这一句把嫌疑指向墨迹层。
（下面这一刀确实省掉了 4 倍的单次绘制成本，但**没解决用户的卡顿**；真凶见上一节。）

- **根因**：缩放每帧改 `zoom` → 每个实化页的墨迹 Canvas 每帧重画一遍。但**真正贵的不是"重画"，
  是高质量描边**：`inkDrawStroke` 的 ballpoint/fountain/pencil 分支逐段 `strokedPath()` 转轮廓、
  攒成一条上万子路径的自相交 Path、最后一次 `fill()`（当初这么写是为了躲接缝叠色，见那几段注释）。
  该工作区的量级（库里实测）：组成原理 1201 笔 / 5.5MB payload，**单页最密 178 笔 ≈ 15000 点**；
  笔型分布 ballpoint 88.8% / fountain 9.6% / pencil 1.3% / marker 0.2%，**98.4% 是 alpha=0.95**。
- **修法**：`inkDrawStroke` 加 `fast` 开关——逐段直接 `stroke()`，**几何、压感、锥度、线宽一个不变**，
  唯一差别是相邻段共享端点的圆头改回各自半透明合成（接缝略深）。由 `ReaderSurface.inkFastDraw`
  门控（`beginFastInk()` 挂在 pinch 首帧 / `animateZoom` / ⌘滚轮 `zoomCommit` 三条路），
  `settleRender` 收尾即切回高质量重画一次。marker 分支本来就是整条一次 stroke，不受影响。
- **实测**（`spike/reader-zoom-probe.swift`，178 笔/15000 点一页 × 3 页，模拟一次真实捏合 1.0→3.0）：

  | 墨迹渲染 | 每页每次 | 帧率 |
  |---|---|---|
  | 现状 `strokedPath` 转轮廓 + 一次 `fill` | 27 ms | **33 fps** |
  | **逐段 `stroke`（保压感）← 采用** | **6.3 ms** | **99 fps** |
  | 整条一次 `stroke`（丢压感） | 2.3 ms | 118 fps |
  | 墨迹位图快照（0 重画，上界参照） | 0 | 126 fps |

- **样张自查**（`spike/ink-fast-look.swift`，四种笔型 × 高质量/快速各一张）：alpha=0.95 的
  ballpoint/fountain（占 98.4%）两版**肉眼无差**；marker 完全相同；pencil（34 条）与人为调到
  alpha=0.35 的笔会明显变深并出"珠链"纹理——只在**缩放进行中**出现，松手 0.15s 即恢复，故接受。
- 🔴 **走过的弯路（值钱的那条）**：先做的是「冻结墨迹绘制尺度 + `scaleEffect` 等比拉伸」。在只有
  一个 Canvas 的简化 spike 里数据漂亮极了——绘制闭包**全程 1 次**、27→125 fps；**放进真实层级就没用了**
  （绘制 45 次 vs 现状 49 次，33→47 fps），用户实测「还是能感受到卡顿」。原因：外层每帧变的内容尺寸
  与页 offset 会把 Canvas 一并标脏，SwiftUI 照样按新尺度重绘。
  **教训：验证"SwiftUI 会不会复用/跳过"这类问题，探针必须连外层结构一起复刻——孤立组件的读数会骗人。**
  `spike/reader-zoom-probe.swift` 就是照真实层级（每帧变的内容尺寸 + 页 offset + 白纸/基图/墨迹三层
  ZStack）重写的那一版，冻结方案与位图快照方案都留在里面当对照组。
  （连带作废并删除：`spike/ink-zoom-probe.swift`（简化层级，会骗人）、`spike/ink-freeze-geom.swift`
  （验的是已撤销的 scaleEffect 几何等价性）。）
- 顺带查清但**没动**的两项：页图 `.interpolation(.high)` 每帧重采样约 5ms/页（用户实测无笔记 PDF
  不卡 → 它不是瓶颈）；草稿纸的 `ScratchInkLayer` 是同款结构（缩放每帧重画），当前笔迹量小没暴露。
- 验证：`xcodebuild` 通过、样张已逐张目检。**待用户在 408学习区真机验证**（见 TODO「接下来」）。

## 完成（2026-08-28，笔迹镜像改增量：`strokesAppend` 0x4C，把 O(n²) 砍成常数）

`strokes` 是全量镜像，而 Mac **每收一条 `ink end` 就广播一次**，payload 是全文档可见图层的所有点
（`pt3` 12 字节 → 一条 200 点的笔迹 ≈ 2.4KB，一页密字 ≈ 720KB）。于是「写第 N 笔」的开销正比于 N，
整篇下来 **O(n²)**：用户报的「用笔的时候 e2e 数值很高、一直增长」就是它，大帧堵在 WS 上还会把后面
几十字节的控制帧（`radial`/`pressRing`/`inkCancel`）一起压住（「Mac 上盘出来了、安卓上没出来」）。

- **协议加一条**（`PROTOCOL.md §4.2`）：`strokesAppend`(0x4C, S→C)，**payload 与 `strokes` 逐字节相同**，
  语义换成「追加到镜像末尾」。跨端向量 #85 与 #52 除首字节外一模一样，三端编解码共用同一段代码。
- **只有纯追加才用它**：Mac 侧就 `AppModel.inkEnd` 一处（新增 `broadcastStrokeAppended`，不可见图层
  照 `broadcastStrokes` 的口径过滤）。擦除、框选移动/缩放、图层显隐、切档、新客户端接入一律照旧发全量。
  客户端因此不需要任何「能不能追加」的判断，收到哪条按哪条的语义做。
- **发送端合帧要跟着改**（上一轮加的那套）：队列从「最多一份全量」变成「一份全量 + 其后若干追加」，
  **新的全量清空整条队列**（它已含前面所有追加），同族内部保序。另加两道保险：
  ① 没收到过全量的连接**丢弃**追加帧（镜像是空的，追加没有落脚点；新接入本来就会补一份全量）；
  ② 某一路积压超 64 帧追加（≈150KB，多半是连接堵了）就整队作废 + 标记未同步 + 经 `onMirrorDesync`
  请真源重发一份全量——追加不能丢一条留一条，只能整队回到「等一份全量」。
- **与乐观笔迹的对账**：追加帧照样按收件人填 `ackRel`。客户端 `appendStrokes` 在**同一次操作里**
  先追加真源这几条、再把 `seq <= ackRel` 的乐观笔销账，屏幕上恰好一条，不会先双份再闪掉。
  追加**不需要**擦除那道「比 `lastEraseRel` 旧就整份丢弃」的闸——追加不会把擦掉的复活。
- 安卓那条诊断打点改成会区分「追加 / 全量」并打体积：写字时应当基本都是「追加」且恒定在几 KB。

验证：`wire-codec-test`(90，向量 85 条) / `wire-cross-test`(170) / 安卓 `WireCodecTest`（向量表 85）/
`xcodebuild` / `assembleDebug` + `test` / `tsc --noEmit` / `vite build` + `capture.html` 重打包 全绿。

**真机已验（2026-08-28 用户实测，同一份 1201 条笔迹 / 9.2 万点的文档）**：

| | 旧 | 新 |
|---|---|---|
| 每次回推 | 全量 1074–1130KB | 追加 0–6KB（1 条笔迹） |
| e2e | 135ms → 8133ms → 链路堵死（77s / 255s） | 15–224ms，**不随时间涨** |
| ackRel vs sentRel | 落后到 `1667 vs 2494` | 基本咬住（`1086 vs 1086`） |

用户确认**没有丢笔**。剩余的擦除/框选/图层/网页几条回归留在 TODO 接下来第 14 条（都走全量那条路，
本次改动没碰）。两条尾巴（擦除仍全量、全量帧仍走 Foundation 装箱，实测建帧 11–22ms）记在 TODO 已知 Bug 里。

**顺带量掉一个错误怀疑**：e2e 里剩下的百毫秒尖峰曾被怀疑是主线程上每收一笔的 O(笔迹×点) 开销。
打点实测是「派发 ~7.5ms + 对账 ~4ms = 每笔 ~11.5ms」，而写字才 1~2 笔/秒，**解释不了 224ms**——
那更像 WiFi 抖动（与体积完全不相关）。故未改代码，只留 `PadLog` 打点；那 ~11.5ms 随文档长、
且是纯浪费，连同两条改法记进 TODO 已知 Bug。

## 完成（2026-08-28，移动端三件：导航三件套两模式共用 / 长按加速度闸 / 锁定水平滚动）

用户三条：① 模式1 没有目录，模式2 要对齐模式1 的 tab，两模式顶栏统一；② 环形选笔盘「很容易误触」，
补笔尖速度判断，且偶发「Mac 上盘出来了、安卓上没出来」；③ 移动端加锁定水平滚动。

- **导航三件套 `shared/` 化**（安卓）：`ReaderDrawer`（左侧抽屉：目录 / 书库，原 `pad/PadDrawer`）与
  `DocTabsBar`（标签页栏，原 `local/DocTabsBar`）都搬进 `shared/`，数据换成中立模型
  `shared/ReaderNav.kt`（`TocItem`/`LibItem`）——`shared/` 一行都不认识 `WireCodec`（依赖方向照旧单向）。
  - **模式1 有目录了**：`PdfSource.toc` 打开时一次性把 Pdfium 书签递归拍平成 `TocItem`（与线格式
    `toc` 同形：先序 + depth，解不出目标页的坏书签留 `page = -1` 渲染成灰行）。
    **⚠️ `frac` 恒 0**：pdfiumandroid 的书签 API 只给页号，页内位置要 `FPDFDest_GetLocationInPage`，
    那个没暴露 → 模式1 的目录跳转只到页顶，章节从页中部起时会落在上一节末尾附近。
  - **模式2 有标签页栏了**，但它是 Mac 已打开窗口（`docs` 广播）的**只读镜像**：点标签 = `selectDoc`，
    `+`/工作区芯片 = 开书库让 Mac `openDoc`，**不给 ×**（关窗仍在 Mac 上做——线协议里没有「关」，
    用户 2026-08-28 拍板不为它加 opcode）。差异只由 `canClose`/`chipTrailingIcon` 两个开关表达。
  - **顶栏统一**：模式1 补「目录 / 书库」键（与模式2 同位同图标），模式2 去掉「选择文档」键
    （它做的事现在是标签页栏本身）→ 两模式**常驻键完全一致、顺序一致**；⋯ 里前六项也已同序，
    只余各自独有的尾巴（模式1 切工作区 / 模式2 收起顶栏、连接设置）。`pad/PadDocsPicker.kt` 随之删除，
    连同只有它在用的 `ic_sync` 图标（`gen.py` 的「画了没人用」校验当场就报出来了）。
- **长按呼盘加第二道闸：笔尖速度**。原判据只看「离落笔点的总位移超 14dp」，挡不住小字——
  写一个小字全程都在 14dp 半径里打转，停满 1s 盘就凭空弹出来。新增滑动窗口（150ms）内的平均速度，
  超 30dp/s 即判为「在写字」撤销候选（写字必然在动、长按必然不动）。两处实现同步改：
  Mac `AppModel`（模式2 与网页的判定跑在 Mac）+ 安卓 `local/RadialController`（模式1 本机判）。
- **「Mac 显示了盘、安卓没显示」**：查到的机制是 **WS 队头阻塞**——盘/进度环/inkCancel 都是几十字节的
  控制帧，却和 `strokes` 全量镜像挤同一条有序通道，镜像大起来就把它们压在后面，等它到时人已抬笔
  （`endPen` 抬笔即无条件收盘）。**止血**：`LANServer` 给 `strokes`/`scratchStrokes` 加**合帧**——
  整份镜像后一份完全覆盖前一份，上一份还没写完时新的直接顶掉它（每路只留最新一份，最后一份必发，
  客户端看到的最终状态不变；`PROTOCOL.md` 本来就写明这两条镜像到达顺序无保证）。
  两端各加了一条打点（Mac「环形盘呼出…下发中」/ 安卓「收到 radial … 笔还在纸上=」），
  真机上一减就知道还剩多少路上时间。**根账仍未算**：见 TODO 已知 Bug 里那条 O(n²)。
- **锁定水平滚动**（三端：安卓两模式 + 网页采集页）：开了之后拖动与松手惯性都只走纵向，
  **缩放引起的横向重锚不受影响**（zoom 没变的双指整体挪动才挡，否则放大后画面会横向乱跳）。
  安卓在 ⋯ 里（与「双指滚动」同组，模式1 存 `ToolPrefs`、切标签页跟着走），网页在顶栏加了一颗按钮。

验证：`xcodebuild` / 安卓 `assembleDebug` + `test` / `gen.py --check`(31) / `tsc --noEmit` /
`vite build` + `capture.html` 重打包 全绿。**真机待验**（见 TODO 接下来第 13 条）。

## 已修（2026-08-28，模式2「上一个字的笔画依次闪烁」——ackRel 的两处误用）

用户报：安卓模式2 连续写字时上一个字的笔画会依次闪一下，同时顶栏 e2e 读数很高且一路增长。
根因**两条独立的**、都出在「回推快照与本端输入的对账」（`PROTOCOL.md §4.2` 的 `ackRel`）：

- **客户端把「落墨」和「擦除」用同一条判据管**（`PageCanvasView.setStrokes` / `PadScratch.applyStrokes`）：
  原判据是「`sentRel > ackRel` 就整份丢弃」，而 `sentRel` 是**全部** REL 帧的最新序号 —— 连续写字时
  ink move 每 8ms 就涨一个，回推路上必然又涨了好几个 → **快照一份都进不来**，乐观笔迹只能等 3s
  兜底超时被撤掉（`乐观笔迹 opt:N 等真源超时，撤掉`），到下一次快照才恢复 = 逐笔闪烁。
  改法：整份丢弃只看**最后一帧擦除**的序号（`lastEraseRel`，只有擦除会被旧快照实质破坏）；落墨改
  **逐条认领**——每条乐观笔记下自己 `ink end` 帧的 REL 序号，`ackRel` 追上才销账，没追上的原样叠在
  快照之上继续画。兜底超时也从「等够 3s 就撤」改成「**3s 内一份回推都没收到**才撤」（真源哑了才算掉线）。
  配套：`UdpSender.sendRel` 改**同步定序**并返回本帧序号（原先 seq 是在 io 线程上加的，
  `onInkEnd()` 之后读回来的是上一帧的号）。

- **Mac 填的 `ackRel` 与快照内容对不上**（`LANServer`）：原先在 `rawSend` 里现取 `UDPTransport.ackRel`
  ＝ 网络队列上的**接收**进度，而帧的效果是 `DispatchQueue.main.async` 到主线程才应用、快照也在主线程建。
  于是「快照里还没有那一笔、`ackRel` 却已经盖过它」，客户端据此撤掉尚未回来的乐观笔迹 = 同样是闪一下；
  **回推越大、发送队列越堵，窗口越宽**，正好解释了「e2e 越高闪得越凶」。改法：`UDPTransport.onFrame`
  多带一个本帧 REL 序号，LANServer 在**主线程上、应用该帧之前**把 `appliedRel` 推到它；`broadcast()` 在
  **建快照的那一刻**（主线程）取 `appliedRel` 快照随消息带到发送队列，`rawSend` 只按收件人取值。
  解不出/连接已断的帧照样推进记账，否则 `ackRel` 会永久卡住。`PROTOCOL.md §4.2` 的 `ackRel` 定义
  已同步改写为「**已应用到**」并记了这两个反面教材。

验证：`xcodebuild` / 安卓 `assembleDebug` + `test` / `udp-reorder-test`(26) 全绿。**真机待验**（见 TODO 接下来）。
顺带加了一条 1s 节流的诊断打点（`回推 strokes N条/M点 ≈XKB ackRel=… e2e=…`），用来定 e2e 爬升是不是
被全量镜像体积拖的 —— 该问题本身**未修**，见 TODO「已知 Bug」。

## 完成（2026-08-21，工作区内文档一级分组 + Keychain 密钥 + 两个 UI 小需求 + 页码恢复 bug）

- **工作区内一级分组（schema v11）**：`document.group_name TEXT NOT NULL DEFAULT ''`（空串=未分组）。
  用户要的是「快速筛选」，在一级分组与 tag 间选定**一级分组**（每篇至多一个组）。刻意**不建分组表**：
  分组没有独立元数据（按名字排序），整组改名/解散 = 一条 `UPDATE ... WHERE group_name=?`，跨端读取零成本
  （安卓 `SELECT *` 直接忽略未知列）。侧栏：有分组时按分组分段（未分组在前、原生可折叠 Section），
  文档右键「Move to Group」（现有分组 / 新建分组… / 无分组），分组段头右键改名/删除（删除=文档回未分组）。
  `spike/store-test.swift` 38/38（新增分组读写/整组改名/解散 4 项）。安卓分组 UI 未做，见 TODO Backlog。
- **API 密钥改存 Keychain**：新增 `Sources/Support/Keychain.swift`（Security 框架 generic password 极简封装）。
  PaddleOCR key 从 UserDefaults 明文迁走——`PaddleOCR.apiKey()` 首次读取时一次性迁移并清掉 plist 旧值；
  设置页改 `@State` 读写 Keychain。配对 token 不动（印在二维码/地址栏，且有明确的持久化决策）。
- **文字笔记编辑弹窗加删除按钮**：`NoteEditorSheet` 新增可选 `onDelete`（仅编辑已存在笔记时传入），
  删除走 `session.textNotes` 移除 → onChange 对账删库，与 Inspector 删除同路径。
- **索套工具在草稿纸上可用**：草稿纸开着时 `pointerTool == .lasso` 框选纸上笔迹 → 拖框移动、角/边手柄缩放，
  与页内框选同一套交互。画布坐标无界，不能用 `InkEdit.translated/scaled`（clamp 0...1），扩展内写无 clamp
  版本，其余语义对齐（线宽 ×√(sx·sy)，clamp 0.5...40）。提交只改 `session.scratchStrokes` → 对账落库 +
  广播镜像。细节：Esc 有选中集时先清选中（不再直接关纸）；切走工具自动清选中。
- **fix：打开 PDF 页码显示 1/xxxx 直到滚动才更新**：`geometryChanged` 里 `updateRealized` 先于
  `pendingRestore` 恢复锚点执行，首帧偏移为 0 把已恢复的 `currentPageIndex` 回写成第 1 页；随后恢复滚动
  全程抑制不再回写。回写与 `maybeEmit` 均加 `pendingRestore == nil` 守卫。

## 完成（2026-08-12，安卓模式2「历史设备」+ Mac 新增 HTTP `/info` + 配对码持久化）

用户需求：**模式2 连 Mac 做历史设备记录，方便选择，设备名就用连接的那台机器的主机名**。
设计与名单规则见 `ANDROID-STANDALONE-PLAN.md §15`，这里记 Mac 侧与共性结论。

- **Mac 侧只加了一条 HTTP 路由**：`LANServer.route` 的 `GET /info` →
  `{"name": Host.current().localizedName, "hostName": ProcessInfo.hostName}`（`JSONSerialization`
  拼，机器名里带中文/引号是常态）。**刻意不动线格式**——往 `authOK` 里加个字段就是三端同步 +
  重出字节向量（`PROTOCOL.md` 开头的红线），而这只是一句展示用的文本。不校验 token，与
  `/page.png`、`/health` 同级。
- **探不到名字不算失败**：安卓侧 3s 超时，拿不到就先按 IP 显示，下次连上再补；连旧版 Mac
  （没有这条路由）也是这个下场，功能不残废。
- **配对 token 改成持久（同日用户拍板「token 也持久化」）**：原先 `LANServer.token` 是每次启动现
  生成的，历史条目里的 token 在 Mac 重开 App 后必然失效 → 点了必 authFail，名单只剩「省了打 IP」
  这点用。现在走 `Pairing.persistentToken()`（存 `UserDefaults` 的 `pairingToken`），同一台 Mac
  长期是同一个码。**配套给了一颗「重置配对码」**（面板 URL 行下面，`LANServer.resetToken()`）：
  码持久了就必须有作废的路——旧码立即失效、连着的平板被踢，重扫即可。
  - 两处线程细节：鉴权那份 token 只在服务 queue 上读（HTTP 路由 / WS `auth`），所以拆成
    `authToken`（queue）+ `@Published token`（主线程镜像，只给面板/二维码）；换码时 `queue.async`
    写前者、主线程写后者。另外 `stop()` 把 `isRunning` 置回 false 是 `main.async` 的，**紧接着
    调 `start()` 会被 `guard !isRunning` 挡掉**，重启必须也排到主线程队列后面去。
- 连接弹窗同时改成**预填这次尝试的 host/token**（原先读的是 prefs 里最后一次**成功**的那组，等于把
  用户刚点的那台冲掉了）：重置过配对码、或名单里存着更早的旧码时都会走到这条。
- 顺带把启动页私有的「图标 + 主行 + 灰次行」一行挪进 `shared`（`PadPanels.twoLineRow`），
  历史设备列表与「最近打开 / 扫描结果 / 存储卷」从此是同一份。
- 验证：`xcodebuild` 绿、安卓 `assembleDebug` + JVM 单测绿；名单规则的插桩测试
  `KnownMacsTest`（7 项：重连保名、换 IP 清同名僵尸、探测失败原样返回、超量截断、中文往返、
  坏数据不炸、prefs 往返）在**小米 Pad 6 真机上跑过全绿**。整条连接链路的人眼部分未验，
  攒进 `ANDROID-STANDALONE-PLAN.md §11.1` 第 49 条。

## 完成（2026-08-12，三端防误触：双指滚动模式 + 锁缩放常驻）

用户两条需求：模式1 的缩放锁定提到顶栏并持久化；网站与平板加「双指滚动」模式减少误触
（双指滚动依然可以缩放）。**设计与三端落点见 `ANDROID-STANDALONE-PLAN.md §14`**，这里只记
网页端与共性结论。

- **挡的是落笔之前那一下**：既有的两道防线（笔落下后忽略手指、大面积接触忽略）只覆盖书写期间；
  虎口/小指在笔 down 之前蹭到屏幕，面积不大、笔也没落，就被当成正经的单指平移。开关一开，
  **单指划动不再平移**，滚动/缩放一律双指——双指捏合的锚点比例本来就跟随中点，所以「还能缩放」
  是天然成立的。单指仍可轻点图钉开纸、按住图钉拖动（刻意动作，不算误触）。
- **坑**：单指划一道再抬手时 `panStarted` 仍是 false，会掉进「单击开图钉」那条路。挡下的那一下
  要记 `gestureBlocked`，抬手一并否掉单击，否则误触换个门又进来了。
- 网页端：`G.twoFinger`（顶栏图标 + `S.twoFinger` 回显），闸门落在 `input.ts` 的死区判定处；
  草稿纸层同一开关（`scratch.ts`）。
- **顺带修掉一个旧缺陷**：草稿纸上**双指整体挪动拖不动纸**（安卓 `ScratchCanvas` 与 web
  `scratch.ts` 两处 `pinchMove` 都只把中点当缩放锚点，两指齐挪时 factor≈1、`zoomAt` 原地返回）。
  页内那份用的是「固定内容比例跟随中点」，不受影响。不修的话双指滚动模式下草稿纸等于被钉死。
- 验证：安卓 `assembleDebug` 绿、web `tsc --noEmit` 绿 + `capture.html` 已重打包。**手感/观感
  一律未真机验**，攒进 `ANDROID-STANDALONE-PLAN.md §11.1` 第 46~48 条。

## 已修 / 完成（2026-08-10，macOS：重开工作区不恢复缩放 + 开窗小页闪一下）

用户报：⌘W 关掉全部窗口（app 留在 Dock）→ 点 Dock 图标重开上个工作区 → **PDF 恢复了但缩放没恢复，
必现**。两个 bug 其实是同一处的正反两面，**均已由用户实测确认修好**。

**排查手段**：没有靠猜——先在整条链上加了一版临时 `[ZOOM]` 打点（复用 `wsLog` 的文件通道，
`touch ~/Library/Logs/UniReader-ws.log` 开），覆盖「关窗保存 → 库写入 → 库读出 → `loadSelected`
注入 `restoreZoom` → 首帧套用 → refit 分支 → `settleRender` 回写」七个点，一轮实测就把两个根因
同时钉死了（打点已在本次提交里撤掉，需要时从本提交的上一版捡回来）。关键两行长这样：

```
首帧定基准 fitBasis=83.0  fullWidth=100.0  pending=0.87 → zoom=0.87
refit 恢复倍率重算：fit 基准 83.0 → 883.0
```

- **根因①：恢复来的倍率被 refit 的「尺寸保持」洗掉**。`refitToViewport` 的启动稳定窗写的是
  `!userZoomed && ...`，而首帧套用恢复缩放时会把 `userZoomed` 置真 —— 于是这层保护**恰好在恢复了
  缩放时失效**，窗口宽度落位时走进「尺寸保持」分支：它保的是**绝对页宽**，把首帧那个瞬态宽度对应的
  页宽锁死，倍率被反算成 `瞬态宽 × 倍率 / 落位宽`。更糟的是 `settleRender` 随后把这个新倍率回写
  `session.readZoom` → 落库，**上次那个倍率被永久覆盖**，所以是「必现」且每重开一次就更接近 100%。
  修法：`Scratch.zoomFromRestore` 标记「这个倍率是从库里恢复来的」，启动窗内窗宽落位时按**新的 fit
  基准保持倍率**（库里存的本来就是相对 fit 的倍数）并按比例重锚滚动位置；用户一动缩放
  （捏合 / ⌘± / ⌘0 / ⌘滚轮）即清标记，之后完全走手动缩放的既有语义。
- **根因②：首帧拿 SwiftUI 的占位几何定基准**（= 用户随后报的「开窗一瞬页面很小、然后突然放大」）。
  原来的门槛只有 `fullWidth > 0`，挡不住 `fullWidth=100`（真实值 900）这种占位值：按它定基准就是
  整条页图流按 83pt 页宽排版**并真的出图**，200ms 后 refit 才跳到 883。修法：加一条下限
  `layoutW >= minPlausibleLayoutW`（200pt）—— `layoutW` 是含侧栏延伸区的全窗宽，而侧栏自己的最小宽
  就是 200，比这还窄不可能是真实布局。没等到真实测量前 `didInitialGeo` 保持假 = 不实化不渲染 =
  **留白**，与 `RootView.resolve` 同一取舍：宁可白一下也不闪一下。重新进入由
  `onChange(of: fullWidth)` / `onChange(of: unobSize.width)` / `onScrollGeometryChange` 三路兜底。
- **顺带**：`scheduleRefit` 在启动落位期（`appearAt` 起 1.5s 内）**不再走 200ms 防抖**直接同步 refit
  —— 那 200ms 是为「用户拖窗口边框」准备的，落位期没什么好等，每多等一帧就是可见的跳变。这是宽度
  分两步到位时的第二道防线。

**教训（与 [[silent-failure-instrument-first]] 同一条）**：`userZoomed` 这种「用户是不是缩过」的
布尔量被两种来源共用（手动缩放 / 从库恢复），保护逻辑就会在其中一种来源下静默失效。区分来源比给
保护条件打补丁更可靠。

## 已修 / 完成（2026-08-05，第二批：安卓笔迹卡顿/闪烁）

用户报两个 bug，均已定位并修，**待真机验证**（见 [[verify-backlog-not-verified]]）：

- **安卓有笔迹显示时滚动/缩放/书写卡顿**：`PageCanvasView.onDraw()` 里页图、文字铺色、图钉三层都
  按可见页区间裁剪了（滚到哪画哪），**唯独笔迹层没裁剪**——`strokes` 是全文档笔迹而不是当前页，
  每帧不管滚到哪都要把全书每一条笔迹的每个点重新过一遍 `InkRenderer` 重建 Path 再画一遍，笔迹越多
  （不管在不在当前视口）就越卡。修复：借用页图循环顺手求出的可见页区间（连续竖排布局，可见页必是
  一段连续区间），笔迹循环按 `page` 落在这个区间内才画，落在区间外的直接跳过。
- **模式1连续快速写字，上一笔会闪一下**：`endPen()` 收笔后本来「本地不落 strokes（回读才是真源），
  cur 先留着等 setStrokes 回推再清」，但下一笔的 `penDown()` 会**无条件清空活体层**——连续快写时，
  若上一笔的落库+回读还没跑完就按下了下一笔，上一笔会在活体层与 `strokes` 之间出现一段两头都没有
  的空窗，肉眼看到闪一下。修复：`onInkEnd()` 改成乐观提交——落笔结束立刻用本地已有的 pts/pen/id
  合成一条 `Stroke` 直接放进 `strokes`（同擦除/框选移动既有的乐观预览套路），`curPts` 随即清空，
  不必等回读。顺带把「写成功也整篇重读」改成「只有写失败才重读纠偏」（同 `onEraseEnd` 已有的
  「没变化就不重读」套路）——`StoreQueue` 是单线程 FIFO，写成功后再整篇重读拿到的仍是**写这一笔
  那一刻**的快照，如果下一笔已经乐观落地但自己的落库作业还没轮到，这份旧快照回来 `setStrokes`
  整表替换时会把下一笔也冲掉，等于重新制造同一种闪烁；只在失败时才读真源，兼顾了性能（不必每笔
  都整篇反序列化）与正确性。

## 已修 / 完成（2026-08-05）

用户报三个 bug，均已定位并修，**待真机验证**（见 [[verify-backlog-not-verified]]）：

- **macOS 切工作区导致 pad 丢进度**：根因是 `AppModel.setActive()`/`unregister()`（窗口切焦点/关窗
  时平板跟随的会话跟着换）只调用了 `push()`，没有像 `selectPadDoc()` 那样补一次
  `pushCurrentViewport()`。`push()→pushLayout()` 一旦文档 `contentHash` 变化就广播新 `layout`，
  Android/网页两端收到后都会**无条件清零本地滚动位置**（`PageCanvasView.setPages(reset=true)`、
  `web/src/lib/ws.ts setLayout`），指望后续的 `viewport` 消息把位置续上——而这条切换路径从未发过
  `viewport`，平板于是停在文档顶部；此时若用户在平板上划一下，这个假位置还会经
  `onScroll→saveProgressThrottled` 反写回数据库覆盖真实进度，造成永久丢失。
  修复：`Sources/App/AppModel.swift` 的 `setActive()`（判定 `padSelectedSessionID == nil &&
  activeSessionID != s.id` 时补推）与 `unregister()`（判定被关掉的窗口正是平板当时跟随的会话时
  补推）都补上 `pushCurrentViewport()`。`xcodebuild` 编译通过。
- **Android Pad app 相对路径误判失效**：`android/.../local/Workspace.kt` 的 `resolvePdf` 此前对
  `location.is_relative=1` 直接返回 `null`（注释称"安卓与 Mac 挂载点不同，猜不出真实路径"）——这个
  前提是错的：`is_relative` 存的本就是**相对工作区文件夹**的路径（可含 `..`），拼接基准是当前设备
  上已经打开的工作区目录本身，和 `in_workspace` 走同一套 `File(workspaceDir, path)`，不存在挂载点
  换算的问题（对照 Mac 端 `WorkspaceManager.resolvedPath`：两者一视同仁）。改成 `is_relative` 与
  `in_workspace` 同一分支解析；`LibraryModels.kt`/`LibraryActivity.kt` 的文案与
  `ANDROID-STANDALONE-PLAN.md §6` 一并更正。Gradle 编译 + 单测全绿。
- **Pad 左下角笔信息缺笔颜色**：网页端 `PenStat.svelte` 笔记模式下有 `<span class="sw"
  style:background={S.pen.color}>` 色块，Android 两个模式（`PadActivity`/`ReaderActivity`，
  两处胶囊文案「逐字一致」是既有约定）都只有文字、没有色块。新增 `shared/Widgets.kt` 的
  `TextView.setPenSwatch(color)`（复用同一个 `GradientDrawable` 换色，不逐帧重建，同
  `setTextIfChanged` 的性能纪律），两处 `refresh()`/`refreshHud()` 在笔记模式下按当前笔的
  `argb(a,r,g,b)` 设置圆点，非笔记模式清空。Gradle 编译通过。

## 已修 / 完成（2026-07-30）

- **侧栏目录的当前项高亮永远钉在最后一项**（用户报，样本：`2027数据结构_高清带书签版.pdf`，
  404 页 / 478 书签）。根因不在追踪逻辑，在 `TOCEntry.build` 里 `var pageIndex = 0` 这个默认值：
  该 PDF 末尾两项（「归纳总结」「思维拓展」）是**空 destination** 的残项（PDFKit 给
  `destination == nil`，PyMuPDF 看到的是 `page=0, to=Point(0,0)`），解不出目标页就落到了默认的
  第 0 页；而当前项判定 `flat.last { $0.pageIndex <= currentPage }` **隐含要求先序页码单调不减**，
  两个 `pageIndex = 0` 又排在先序最末，`0 ≤ 任何页` 恒成立 → 任何页都命中最后一项。页码列显示
  「1」、点击跳回首页，是同一个默认值的连带伤害。三处一起改（`TOCView.swift` + `ContentView.swift`）：
  - `TOCEntry.pageIndex` 改 `Int?`，解不出即 nil；顺带挡住 `doc.index(for:)` 返回 `NSNotFound`
    （= `Int.max`）的越界项；
  - 当前项判定改 **argmax**（页码 ≤ 当前页里页码最大的，并列取先序靠后＝更深一层）：正常单调目录
    下与 `last` 完全等价，但对坏项与乱序书签免疫——PDF 书签页码本就不保证单调；
  - 无目标页的行：页码列留空 + `.disabled`，`jumpToTOC` 直接 return，不再把它当第 1 页。
  离线验证（`swift` 脚本照抄两段逻辑喂真实 PDF，非启动 App）：p13→「2．数据元素」、p207→
  「6.1.1　图的定义」、p403→「二、综合应用题」，旧逻辑这些行全是「思维拓展」。p1 无高亮属正确
  （首个有效书签是 p4「前言」）。**安卓下一版做目录会遇到同一件事**，坑与三条硬约束记进
  `ANDROID-STANDALONE-PLAN.md §9.7`（Pdfium 对坏 dest 的 `pageIdx` 给什么必须实测，不许假定）。
  UI 观感（灰行、追踪滚动）仍待你手测。

- **「最近打开」进主菜单栏**（用户提，参考 Obsidian 的 `File → Open Recent`）：数据层（
  `WorkspaceRegistry.recents`）本来就有，缺的是菜单栏入口——此前只有 Dock 右键菜单和侧栏工具栏
  的工作区下拉。现在 `文件 → 最近打开 ▸`（`Open PDF…` 之下，同 macOS 惯例位置）列出最近工作区
  （folder 图标 + 名字），末尾 `清空最近打开`。
  - 点击走 `AppDelegate.deliverWorkspace`——与 Dock 菜单、双击 `.unrd` 同一条投递链路
    （已有窗口则激活，否则开新窗口）；菜单栏是 App 级的，不经由某个窗口的回调。
  - 新增 `clearRecents()`：**两份数据源一起清**（自己那份 UserDefaults + 系统
    `NSDocumentController.clearRecentDocuments`），否则 app 未运行时 Dock 右键里旧条目照旧列出来。
    顺带在 `removeRecent` 上记了一句：系统那份**没有删单条的 API**，所以逐条移除天生清不干净——
    这也是移除操作统一收敛到「清空」的原因。
  - 菜单项必须抽成独立 `View`（`OpenRecentMenu`）自己持 `@ObservedObject`：`.commands { }` 的内容
    不在窗口视图层级里，把 `registry.recents` 直接写进 commands 闭包只在启动那刻求值一次，之后
    打开新工作区菜单不会更新。
  - 侧栏那套顺势收敛：删掉「从最近列表移除」的**三级嵌套子菜单**（不是 macOS 的排法，且与菜单栏
    两处维护同一件事），侧栏只留"快速切过去"。显示名两处统一到 `defaultWorkspaceName(for:)`
    ——原先侧栏用 `deletingPathExtension().lastPathComponent`，含点的文件夹名会被截断
    （「v1.2 notes」→「v1」）。
  - 文案两语言齐（`Open Recent` / `Clear Recent`），删掉已无引用的 `Remove from Recents`。
  **菜单实际观感与动态更新待你手测**（要点见下次交接：打开一个新工作区后菜单是否立刻多一条、
  清空后是否变灰）。

## 已修 / 完成（2026-07-29）

- **多工作区方案复审后的四处加固**（审 §8.1 + 实现，找出「模型没贯彻到底」的接缝；细节见 §8.1）：
  ① **红线不再依赖引用计数的时序**——实例池改弱持有、条目不随窗口计数摘除。原先计数归零就摘条目，
  可那一刻旧实例还活着（SwiftUI 关窗后 `@State` 释放延后、尾随进度补存最长还能再写 0.7s），这段空窗里
  同路径被重开就会给一个库开出两个 `LibraryStore`；配套让 `ContentView.onDisappear` 主动取消尾随补存。
  ② **冷启动双击也过 `validate`**——此前只有热启动路由校验，同一个双击手势会因 app 当时开没开而两种行为：
  热启动弹「这不是工作区」，冷启动却在那个包里静默建空库（正是 §8 要根除的表现）。
  ③ **「新建工作区」不再覆盖已有工作区**——`createWorkspace` 目标已含 `library.sqlite` 时报错而非整个删掉
  （保存面板那句「替换」在用户眼里是替换一个文件，实际是连笔记删一整库；目标还可能正被另一个窗口开着）；
  顺带它不再自己 `new` manager（实例一律由 `acquire` 分配）。
  ④ **`claimRestore` 的闸挂到池的生命周期上**——窗口数归零即归还，否则同一次运行里关掉某工作区全部窗口
  再打开它会得到空窗口，而「打开集」在关最后一个窗口时是特意保留的，两边时间尺度对不上。
  ⑤ **幻影空窗口的判据换成直接量**（验证 ② 时钓出来的真 bug）：原判据「它要落到的那个工作区已有窗口」
  在「屏幕上只剩一个错误态窗口」时失效 —— 双击坏包后，激活带来的幻影窗口没被认出来、转正成了一个用户
  根本没要的「上次工作区」窗口。改成「屏幕上已经有本 app 的其它窗口」（`RootView` 级登记，错误窗也算，
  且判定要排除自己，否则冷启动第一个窗口会自杀）。
  ⑥ **「打开工作区」的路由提到 app 级**（验证 ⑤ 时又钓出一个静默丢弃）：路由原先挂在
  `ContentView.routeToWorkspace`，而错误态窗口没有 `ContentView` —— 屏幕上只剩一个错误窗时，双击
  `.unrd` 全 app 没有订阅者，请求被静默丢掉且 `pendingWorkspacePath` 留下陈旧值。改成
  `WorkspaceRegistry.route` 一份实现，热启动订阅挂 `RootView`（每个窗口都有），侧栏入口同调。
  ⑦ **关窗信号改用 AppKit `willClose`**（验证 ④ 时发现 ④ 根本没生效）：`RootView.onDisappear` 在**窗口
  建立过程中就空放一次**（那时还没绑定工作区），我为防重复释放加的一次性标志被这一下烧掉，真关窗时
  什么都不做 —— 引用计数不减、记号不还，「关光某工作区的窗口再打开 = 空窗口」。改挂
  `WindowLifecycle`（`NSWindow.willCloseNotification`），关闭回调只捕获不变的 `windowId`、
  由 registry 按 id 放手；`RootView` 的分支也从 `Group` 换成 `@ViewBuilder`（Group 会把修饰符下发给分支）。
  教训写进 §8.1 的红线小节：**SwiftUI 的 `onDisappear` 不是「窗口关闭」信号**。
  另清理了三处注释漂移（自毁闸位置、pending 消费点、`wsLog` 重复文档块）与死代码。
  §8.1 补「已知边界」（重启只恢复最后一个工作区、同工作区多窗口时激活任意一个）与空窗口的未试线索。
- **多工作区并存**（用户报「双击打开一个工作区，把旧窗口的工作区也替换掉了」）：工作区从 App 级单例
  改成**窗口级**。方案与红线见 `REQUIREMENTS.md §8.1`（权威），要点：新增 `WorkspaceRegistry` 按路径分配
  `WorkspaceManager`（**同路径必须同实例**——`LibraryStore` 是单 SQLite 连接且笔迹/注解走「内存快照 ↔ 库」
  增量对账，同一个库开两个 store 会互相把对方的成果判为「已删除」而清库，直接丢笔记）；新增 `RootView`
  决定每个窗口归属哪个工作区再注入子树，故 `ContentView` 及下游那 28 处 `workspace.` 用法一行未改；
  所有「打开工作区」入口统一成「已有窗口则激活、否则开新窗口」；`restoreSession` 改为每工作区只做一次
  （`claimRestore`，不设闸会连锁开窗）；⌘N 由 app 接管（系统默认那个开出来的窗口不带工作区，会跑去开
  「上次使用的工作区」）。用户已验证：两个工作区窗口并存互不影响、重复双击只激活、笔迹未丢。
- **双击 `.unrd` 冷启动打不开该工作区**（停在旧工作区；此前已改错三轮）。真根因是两层叠加，靠自建文件
  日志一次跑出来（`log show`/`log stream` **抓不到本 app 任何输出**，按进程过滤零条，为此白费两轮）：
  ① SwiftUI 的 `onAppear` 早于 AppKit 投递 open 事件，在那里判定初始内容时缓冲还是空的 → 先恢复了上一个
  工作区；② 事件随后到达时**没有任何窗口是 key**（`isKeyWindow` 由 `WindowAccessor` 异步回填），
  `if isKeyWindow` 让所有窗口一起跳过 = 请求静默丢弃。修法：初始内容决策锚到 `applicationDidFinishLaunching`
  （AppKit 保证 open 事件在它之前投递完），热启动路由改用「谁 `consumePendingWorkspace()` 抢到谁处理」。
  时序表见 `REQUIREMENTS.md §8.1`。
- **Dock 图标右键「最近的工作区」**（新功能）：两套机制各管一半场景——app **运行时**走
  `applicationDockMenu`（用 registry 那份列表，点击与双击 `.unrd` 同一路由）；app **未运行时**那个方法根本
  不会被调用，Dock 显示的是系统「最近使用的文稿」，由 `NSDocumentController.noteNewRecentDocumentURL` 喂
  （registry 初始化倒序补喂一次已有列表，否则老用户升级后未运行时的 Dock 右键是空的）。
- **SwiftUI 凭空多开一个空窗口**（每次 app 被激活都来一个，双击 `.unrd` 必然激活 → 一次双击两个窗口）：
  **未根治**，已识别并在上屏前关掉。四条怀疑全部被日志排除（`applicationShouldHandleReopen` 压根没被调用 /
  `NSDocumentController` 没介入 / 去掉 `defaultValue` 无效 / `isRestorable=false` 不是状态恢复），排除表与
  两个实现细节（判定必须在 body 求值时而非 `onAppear`，否则窗口已上屏 = 用户看到闪一下；`WindowCloser` 要在
  `viewWillMove(toWindow:)` 就设 `alphaValue=0`+禁动画，且**不能给零尺寸 frame** 否则 NSView 根本不被创建）
  见 `REQUIREMENTS.md §8.1`。用户已验证无闪烁。
- **阅读区缩放掉帧**：根因不在渲染，在广播——`DocSession.readZoom` 是 `@Published` 且被逐帧回报，
  每帧向所有订阅 `DocSession` 的视图（ContentView/Inspector/侧栏/缩略图/笔架）广播 `objectWillChange`
  = 每帧重算整个窗口视图树。改为只在 `settleRender` 稳定后回报一次。其余每帧重复劳动：`PageBuckets`
  把逐页全数组过滤压成整帧算一次（取笔迹原本每页重建图层序字典 + 全量排序）、缩放中 settle 不再每帧重排、
  实化窗口不收缩、不入队注定作废宽度的渲染、`userZoomed` 不逐帧写同值。
- **缩放白屏**：① `updateRealized` 收缩实化窗口时驱逐的正是刚还在屏幕上的页，缩放到一半它又回视口 → 白纸；
  缩放期间改为只扩不缩、不驱逐。② `requestBase` 完成回调原本只认当前期望键，连续缩放时 settle 每 0.15s
  换一次目标宽，前一轮**渲好且已进缓存**的图全被丢弃、该页一直空着；改为该页正空着且夜间标志相符就先顶上。
  ③ 新增 `fallbackBase`：目标宽度未就绪时拿该页以前渲过的任意宽度图先顶，最后兜一层 Inspector 缩略图那份
  160px 图。
- Inspector 缩略图页图本身没裁圆角，方角图正好盖住圆角底 → 加 `clipShape`，圆角值抽成 `ThumbnailListView.corner`
  供底/图/选中描边共用。

## 已修 / 完成（2026-07-27）

- **尺子（直线）笔三个独立缺陷**（用户报：①平板显示是直线、Mac 显示成歪笔迹，抬笔落下的也是歪的；
  ②线段终点跟不上笔尖、比实际短很多）：
  ① **Mac 收到的是「一串移动中的终点」而不是一条直线**（`web/src/lib/input.ts` ↔
  `Sources/App/AppModel.swift handleInk`）。平板尺子模式每个 pointermove 把吸附后的终点 **push 进
  batch** 上行，本地却是整笔替换成 `[首点, 终点]`——协议上 `ink move` 的语义是**追加点**，于是 Mac
  把拖动过程中的每个终点都串成一条歪线，抬笔提交/回传的自然也是歪的。改法：`ink begin` 尾部加一个
  **可选 flags 字节**（bit0=`line`，见 `PROTOCOL.md §4.3`；安卓 `WireCodec.kt` 早已按这个形状编码，
  Swift/JS 这次补齐），落笔那一刻把尺子开关锁进这一笔随 begin 上报；平板 batch 改为**只留最新终点**，
  Mac 见 `line=1` 走新的 `inkLineTo`（整笔恒为 `[起点, 当前终点]`，取批里最后一个点，替换而非追加）。
  吸附仍只在平板算一次（Mac 复算只会两端各画一条），Mac 只认「两点」这个语义。
  ② **两点直线只画一半**（`web/src/lib/render.ts drawStroke` / `Sources/Views/InkLayers.swift
  inkDrawStroke` / `android PadView.kt drawStroke` 三份同算法实现全中）：中点二次贝塞尔平滑每步只画到
  「相邻两点的中点」，**末点从来没被连上**——长笔画差这半段看不出来，两点直线就是整整少画一半，
  表现为「线尾追不上笔尖、比实际短很多」。三端各补一段 `lastMid → 末点`（笔宽取末点压感）。
  ③ **吸附的 45° 不是看上去的 45°**（`InkEdit.rulerSnap` / `shared.ts rulerSnap` 同算法两份实现）：
  角度是在**页内归一化**空间量的，而 x/y 尺度不同（A4 上 y 被压 √2），于是屏幕上的 45° 只有 35°、
  永远不吸附，真吸上的是屏幕 54.7°。两份实现都加 `aspect`（页高/页宽）参数：先把 y 折算成与 x 同尺度
  再量角、贴合完折回去，长度也按视觉长度保持；`aspect=1` 退化回旧行为。调用点：平板传
  `dispH[page]/pw()`，Mac ⇧ 尺子传新的 `ReaderSurface.pageAspect(page:)`。
  ④ 顺带：`PenBrushType.fountainTaper` 对 `n<=2` 不再锥度。锥度按**点下标**算，两点笔画（尺子直线 /
  擦除切出的碎段）整条都落在「两端」→ Mac 把整条画成 0.18 倍细线，而平板端根本不做锥度，同一条线
  两端粗细差 5 倍。
  验证：`spike/ink-edit-test.swift` 38 项（新增 5 项 aspect 用例）、`spike/wire-codec-test.swift` 49 项
  + 新增 `ink begin line=1` canonical 向量（第 44 条）、`spike/wire-cross-test.js` 88 项 Swift↔JS 字节级
  比对全过；`tsc --noEmit` + `build-web.sh` + xcodebuild BUILD SUCCEEDED。真机手感待用户验。
- **连续翻页卡顿（大 PDF 尤甚）根因 = 主线程为平板同步渲整页 PNG**（`Sources/App/AppModel.swift`
  `push()`、`Sources/Server/LANServer.swift`）：`push()` 由 `sessionChanged` 驱动，**每跨一页边界
  在主线程跑一次** `PageRenderer.png(maxWidth: 1600)` = PDFKit 渲染整页 → NSImage → TIFF（~13MB
  未压缩）→ 重解码 → PNG deflate，无缓存无去重；大扫描件单次上百毫秒，还与 `PageRenderEngine`
  后台队列抢 PDFDocument 锁 → 滚动中每翻一页顿一下。用户二分实测钉死：**关掉平板服务即消失**
  （`guard server.isRunning` 早退），关 Inspector / 关 OCR 均无效。
  而那张图只写进 `LANServer.pagePNG`，仅供「无 `?i=` 的旧采集页」兜底——现役两端（web
  `render.ts`、安卓 `PageFetcher.kt`）一律走 `/page.png?i=N` → `pageProvider` → `renderPage`
  （服务 queue + NSCache）。即纯浪费的方案 A 遗留。
  改法：`push()` 只发页元信息（`setPage` 去掉 `png` 参数、删 `pagePNG` 字段），兜底路由改为同样走
  `pageProvider?(currentPageIndex)`（有缓存、不占主线程），平板行为不变。
  验证：xcodebuild 过 + 用户确认卡顿消失。
- **阅读区整片白屏（滚快一点必现，settle 反复重试也不恢复）根因 = `centerOutOrder` 会返回空数组**
  （`Sources/Views/ReaderSurface+Render.swift`）。旧实现从 `center` 向两侧外扩固定 `radius` 步、
  只收落在 `bounds` 内的页，于是 **`center` 离 `bounds` 超过 `radius` 时返回空数组** →
  `kickBaseRenders` / `settleRender` / `refreshTiles` 的渲染循环**一次都不进** → 那批页永远发不出
  渲染请求。而 `center`（`session.currentPageIndex`）的更新在 `updateRealized` 里被
  `follower.isSuppressing` / `suppressEmitUntil` 门控（平板跟随、缩放/refit 期间停更），
  用户快滚一下 `realized` 就能跳出那点距离，于是整屏白。
  修：`center` 先夹取进 `bounds`，覆盖面恒等于 `bounds`，`center` 只影响出图**顺序**、不影响出图
  **与否**；`radius` 参数随之取消（四个调用点本就都是「覆盖 bounds 全部」）。
  ⚠️ **定位过程记账（三次归因错误，教训）**：先后错怪过「PDFDocument 跨队列竞争」和「44MB 页图
  撑爆缓存导致 CGContext 分配失败」，都靠加打点实测排除——真实日志是 `ENQUEUE == START == 121`
  （队列没卡死）、无 `RENDER-FAIL`/`CGCONTEXT-FAIL`（没失败）、内存仅 176MB（没爆），
  而白屏期间 **17 秒 5 次 settle、missing 恒为同样 5 页、零 `ENQUEUE`**——请求压根没发出去，
  这才把范围逼到"循环没执行"。**这类"静默不工作"的 bug 不要靠读代码猜，靠打点把请求生命周期
  （ENQUEUE/START/DONE/DROP/SKIP）打全，空白处即答案。**
  验证：xcodebuild 过 + 用户确认白屏消失；诊断代码（`RenderDiag` 及各处调用）定位后已全部移除。
- 上条排查途中顺带修掉的两处真实隐患（**与白屏根因无关**，但都该改）：
  ① `AppModel.setPadRender` 里 `padRenderPDF` 直接就是 `session.pdf` 本尊，而平板页图在 `LANServer`
  服务 queue、Mac 阅读区在 `PageRenderEngine` 串行队列——`PDFDocument`/`PDFPage` 非线程安全，
  两个后台队列共用一个文档对象是隐患。改为用 `pdf.documentURL` 另开独立实例（惰性解析，只多一份
  xref 表内存），同 key 不重开；`DocSession` 的 OCR 渲染（`ocrRenderQueue`）同样处理（懒建
  `ocrRenderPDF`，`reloadOCRState` 换文档置空）。`PageBitmap` 文档注释列出三条管线各持哪份实例。
  ② `PageRenderer.png` 原是 AppKit 实现（`page.thumbnail` → `NSImage` → `tiffRepresentation` →
  `NSBitmapImageRep`），挪下主线程后变成后台线程用 AppKit。改写为纯 CoreGraphics/ImageIO
  （`PageBitmap.render` + `CGImageDestination`），顺带去掉 ~13MB 未压缩 TIFF 中转与一次全量重解码。

- **笔架收起/展开弹簧动画 + 靠左收拢（`Sources/Views/PenRack.swift`）**：两态共用一个胶囊外壳
  （padding/背景/描边/阴影上移到外层 `bar`，分支内容只做过渡），`spring(duration: 0.32, bounce: 0.15)`
  整体缩放。三个坑：① 原 `.transaction { $0.animation = nil }` 一刀切禁动画 → 删掉，拖拽位移改在
  手势 `updating` 闭包里 `transaction.animation = nil`（`.animation(nil, value:)` 有连坐，勿用）；
  ② **`@AppStorage` 写入经 UserDefaults 通知异步回投，`withAnimation` 包不住它的更新**（实测就是
  没动画的根因）→ 布局改读本地 `@State collapsedUI`，AppStorage 仅作持久化，`onChange` 镜像同步
  多窗口；③ 位置存储从「中心锚」改「左上缘锚」（key 沿用，旧值一次性右移半宽、夹取自愈），
  收起时左缘固定右侧收进 = 靠左对齐；`onGeometryChange` 的尺寸写入走同一条 spring，
  动画期间夹取跟随不跳位。验证：xcodebuild 过 + 用户确认动画生效。
- **笔架从按钮上起拖不跟手（松手瞬移）修复**：`.gesture` → `.highPriorityGesture`——Button 会吃掉
  mouse-down，普通优先级拖拽手势全程拿不到事件流，松手才补 end → 瞬移。`minimumDistance: 6`
  不变，点按按钮不受影响。验证：xcodebuild 过 + 用户从笔插槽起拖确认跟手。
- **大纲（TOC）当前页追踪**：归属当前页的条目（先序拍平后「最后一个 pageIndex ≤ 当前页」，
  命中最深一层）自动展开整条祖先链 + 淡强调色高亮 + 滚动到位（只增展开，不动用户手动折叠的
  分支）。Inspector 目录页与工具栏目录弹窗共用。⚠️ 系统 `List(children:)` 大纲不支持程序化
  展开/定位，`TOCListView` 因此改自持展开态的手动树（ScrollView + LazyVStack + `expanded`
  Set，reveal 走 `formUnion(ancestors)` + ScrollViewReader 定位），行外观维持原纯文字行 + 页码。
  验证：xcodebuild 过 + 用户确认真机效果。

## 已修 / 完成（2026-07-26）

- **点注解图钉页内拖拽调位置**：无选中文字的 text note（rects 空、零尺寸 anchor 的点注解）图钉在
  textSelect 模式下可直接拖拽换位（选区注解不可拖，保持 Button 点开编辑器）。手势走 **ScrollView 容器
  simultaneous 拖拽**（`ReaderSurface+Selection.notePinDragGesture`，与 lasso 同款已验证模式：
  起点 `pointNotePinHit` 命中图钉定锚存 `scratch.noteDragID` → 拖动只动 ghost（`notePinDrag` @State
  传到 `PageCellView` 挪图钉显示位，位移 clamp 到锚点不出本页）→ 松手 `commitNoteDrag` 一次性提交
  （页内像素位移 → 归一化 dx/dy → `InkEdit.translated` 写回 `session.textNotes`，onChange 对账自动
  落库 + 恰是 padSession 时广播镜像平板）。拖选手势靠同一起点命中测试反向让位（命中图钉则
  selDragAnchor 保持 nil 整段不启动）。ink/lasso 模式不可拖（lasso 本就有框选移动）。
  ⚠️ 教训一：初版把 DragGesture 挂在图钉子视图上（`.local` 坐标系随图钉移动吃掉 translation）→
  不跟手 + 鬼影；阅读区拖拽一律挂容器、状态走 @State/scratch，别在会移动的视图上挂手势。
  教训二：图钉 Button 本体不能跟手挪位（松手时光标仍在 Button 内会误触发开编辑器）——原位 Button
  只变淡，另画 `allowsHitTesting(false)` 的 ghost 跟手。
  验证：xcodebuild 过；手感/真机回归待做。

- **橡皮增强：整笔/局部双模式 + 尺寸圆环（2026-07-26 用户反馈，承接下方四项批）**：
  `eraser`（0x46）payload 扩为 `f32 size · u8 mode · u8 ring`（本会话新增消息、无存量客户端，直接改格式；
  mode 0=整笔/1=局部、ring 控制尺寸圆环，两端同步）。Mac `eraseNear` 按模式分派（整笔=旧 removeAll 语义、
  局部=splitStroke）；网页 `eraseHit` 同款分派。尺寸圆环三处：网页擦除模式笔尖（hover/落笔/拖动，
  直径=2×eraserSize×页显示宽，双描边深浅页可读）、Mac 本机橡皮跟光标（`localEraserOverlay`，纯 SwiftUI）、
  平板上行 hover 在 Mac 的光标 erase 模式改按橡皮直径画（ring 关时回退 10pt 位置环）。设置入口：
  Mac 笔架橡皮 popover（segmented + Toggle）、网页 PenStat 弹层（分段按钮 + checkbox，随 eraser 消息防抖上行）。
  验证：wire-codec-test 48/48 + wire-cross-test 86/86；ink-edit-test 33/33；build-web + tsc + xcodebuild 过。

- **feat 批：笔&笔架&笔迹四项（尺子模式 / 橡皮局部擦除+尺寸同步 / Mac 本机落墨 / 框选移动）**：
  ① **尺子模式画笔**：采集页 TopBar 加尺子开关（`G.rulerOn`，纯本地），note 模式 pointermove 以首点
  为锚做 45° 倍数吸附（阈值 7°，`shared.ts rulerSnap` / Mac 侧 `InkEdit.rulerSnap` 同算法两份实现），
  `G.cur.pts` 替换为两点直线后照常上行——**协议零改动**（吸附在上行点生成处做，Mac 收到即普通直线点列）；
  ② **橡皮局部擦除 + 尺寸可调 + 网页端调笔宽**：擦除从整笔删改为 `InkEdit.splitStroke` 点级切段
  （剔除命中点、连续段各成新笔画**新 UUID**——对账自动「旧 id 删 + 新 id 增」，持久化零改动；零命中原样
  返回）；网页端 `eraseHit` 换等价 JS 切段（同步纪律注释在 `InkEdit.swift` 头部），并补同页过滤（旧版
  跨页/页缝都擦，与 Mac 对不上）。协议新 opcode 追加 canonical 表末尾：`penset`（0x25，C→S，整包笔列表，
  Mac `applyPenSet` 写回 `app.pens` 全端对齐）与 `eraser`（0x46，双向，f32 归一化半径默认 0.02；
  `app.eraserRadius` UserDefaults 持久化 + didSet 广播）。UI：Mac 笔架橡皮按钮在 erase 模式下再点弹
  尺寸 slider；网页端 `PenStat` 重写为可点弹层（每支笔宽 slider 2...40 + 橡皮直径 1...12%，300ms 防抖
  上行）。顺手修 fountain 公式漂移（`shared.ts` 1.15→1.3 对齐 `PenPreset.swift`）；
  ③ **Mac 本机鼠标/触控板落墨（临时笔迹模式）**：`AppModel.pointerTool`（.textSelect/.ink/.lasso，
  设备级全局、与 padMode 同生命周期），笔架加「本机笔」toggle；`localInkDragGesture`
  （`ReaderSurface+Selection`）仅 .ink 生效、dragSelect 反向门控，`containerPointToPageNorm` 换算 +
  压感 0.5 + 共用当前选中笔；`padMode==erase` 走 inkErase；落墨 API 加 session 参数（默认 padSession，
  本机传窗口自己的 session——对账落库 + 镜像平板零额外工作）；⇧ 拖动 = 尺子直线
  （`InkEdit.rulerSnap` + `NSEvent.modifierFlags`）；落墨不跨页；
  ④ **笔记框选移动（仅页内）**：pointerTool 加 .lasso + 笔架按钮；新扩展 `ReaderSurface+Lasso.swift`
  （框选虚线矩形/命中/移动/Esc 监视器）。命中 = 同页 strokes 任一点入框 + textNotes anchor 相交；
  移动拖动只动 ghost offset（选中高亮框即 ghost，存 ReaderSurface @State），松手一次性
  `InkEdit.translated` 平移（strokes 点集 / 注解 anchor+rects，clamp 页内）+ 条件广播；
  **`persistInk` 从 id 集合对账升级为值快照对账**（`persistedStrokes: [UUID: InkStroke]`，
  同 id 内容变更 → upsert，仿 persistTextNotes）。
  验证：`wire-codec-test.swift` 48/48 + `wire-cross-test.js` 86/86；`ink-edit-test.swift` 33/33（新建，
  覆盖 split/rulerSnap/translated）；`build-web.sh` + `tsc --noEmit` 过；xcodebuild BUILD SUCCEEDED。
  真机手测（尺子吸附手感 / 局部擦除两端一致 / 本机落墨 / 框选拖动）留给用户。

- **feat 批：⌘F 复核 / ServerPanel 地址复制 / 同路径 hash 校验 / 快捷键体系 / 平板文字笔记**：
  ① **⌘F 查找**：GUI 实测已可用（字段展开聚焦、输入即搜、461 命中）——2026-07-25 改 `.searchable` 时
  链路（菜单 ⌘F → `.readerFind` → key 窗口 `searchIsActive=true`）已接通，TODO「必须补」条目过时，仅归档；
  ② **ServerPanel 采集页地址**：加一键复制按钮（`NSPasteboard`，点击 ✓ 反馈 1.2s）+ 长地址改
  `fixedSize` 完整换行（不再截断）；③ **同路径内容变化 hash 校验**：打开文档后后台重算
  `FileHasher.sha256Cached`（缓存键含 mtime，内容变必重算），与入库版本不符 → 弹窗二选一：
  「关联为新版本」走 `WorkspaceManager.rekeyLocation`（摘除同路径旧 location **记录**不删物理文件、
  按实际 hash 挂版本、保留 inWorkspace/相对路径标志——不修正旧记录会每次打开重复提示）；
  「仍打开」仅本次按实际内容打开（下次仍提示）。两路 `session.contentHash` 都用真实 hash（OCR 缓存键一致）；
  ④ **快捷键体系**（`UniReaderApp` commands，与笔架/环形盘同一套 apply 路径）：⌥1–4 选笔槽
  （`applyPenSelection`，选中即回书写模式）、⌥E 橡皮 / ⌥V 翻页 / ⌥B 书写（`setPadMode`）、
  ⌥⌘N 夜间（`.toggleNightMode` 通知 → key 窗口翻 `nightMode` @AppStorage）；
  ⑤ **平板自由文字笔记**：协议加 `textNote`（0x24，C→S，`{id,op:upsert/delete,page,nx,ny,text}`，
  **空文本 upsert 视为删除**，可靠通道）与 `notes`（0x39，S→C 全量镜像，类比 strokes 真源）；
  Mac `AppModel.applyTextNote` 落 `padSession.textNotes`（点注解：零尺寸 anchor、无 quote/rects，
  ContentView 对账自动落库）+ `broadcastNotes`（换文档 `pushStrokesIfDocChanged`/新平板连接补发，
  textNotes onChange 随动）；web 端 TopBar 加「文字笔记」**独立本地开关**（不动 mode 协议枚举），
  noteMode 下笔点页面开圆形选择器风格编辑器（`TextNoteEditor.svelte`，保存/删除/取消，乐观更新
  `G.notes`，该分支不发 probe/ink 防误触环形盘），hover 层画圆形标记（蓝底白边 + 首字符，深浅页面通用；
  `clearHover` 改重画标记防悬停收尾抹掉标记）。
  验证：`wire-codec-test.swift` 45/45 + `wire-cross-test.js` 80/80；`build-web.sh` + `tsc --noEmit` 过；
  xcodebuild BUILD SUCCEEDED。⌘F 经 GUI 自动化实测；其余 GUI 手测留给用户。
  附带修复：`ContentView` body 修饰符链超类型检查器时限 → 拆 `mainSplit` + `eventRoutes` 两段
  （与 `toolbarContent` 同款处理）。

- **夜间模式切换慢 + 黑切白切不回（2026-07-26 用户两轮反馈，最终重设计）**：第一版快路
  （`flippedNightKey` 异色键缓存反转）实测仍 3s+ 且出现切不回，深挖出三个叠加根因：
  ① **wanted 竞态丢请求**——`settleRender`/`kickBaseRenders` 先 `request` 后 `setWanted`，
  渲染线程在窗口期内按旧 wanted 集把新请求误判丢弃，完成回调永不触发 → 页面永久停在旧模式图
  （引擎改为入队 1s 内放行、滞留超 1s 且无人要才丢）；
  ② **完成回调键守卫被值拷贝穿透**——逃逸闭包捕获 struct self，`nightMode` 是请求时旧值，
  陈旧完成的键比较照样通过、把旧模式图写回（所有键计算改读 `scratch.nightLive` 引用侧实时值，
  `requestBase` 守卫收紧为纯键匹配）；
  ③ **整窗重渲本身慢**——最终重设计：夜间切换 = **原地反转当前正在显示的 `images`/`tiles`**
  （`scheduleNightRender`，并发像素反转、毫秒级、与缓存驱逐无关），结果 `seed` 回引擎缓存；
  快速连切串行 flip + `nightFlipTo` 连锁收敛；引擎保留异色键反转快路作新滚入页/预热页兜底。

- **PDF 放大后高清重渲染不及时（2026-07-26 用户反馈）**：根因——渲染引擎单串行队列按提交序
  出图，而 `settleRender` 先按页码序重渲整个实化窗口的基图、最后才排视口贴片；放大超过基图
  上限后清晰全靠贴片，眼前这页排在长队尾。修法（`ReaderSurface+Render`）：贴片请求提到基图
  之前；`settleRender`/`kickBaseRenders`/`refreshTiles` 入队顺序全部改「当前页 → 由近及远」
  （复用 `centerOutOrder`）。

- **按钮命中区域过小（2026-07-26 用户反馈，搜索导航 + 笔架两处）**：根因——`Image` 用
  `frame` 扩出的空白不参与命中测试，只有点到图标字形才触发。修法：两处按钮 label 补
  `.contentShape(Rectangle())` 并略放大 frame（搜索上/下一个 22→24；笔架收起/添加/橡皮/
  翻页 26→28）。

- **文字笔记类型（批注自定义类型）**：批注不再只有「通用」一种——可自建类型（名字 + 色板颜色 + SF Symbol 图标），
  批注挂类型后页面图钉与选区高亮用该类型的颜色/图标，Inspector 笔记列表显示色点+图标并可按类型筛选。
  关键机制：① 类型表存**工作区 meta**（`note_types`，JSON 数组，snake_case 键，工作区级隔离、随文件夹走），
  `Sources/App/NoteTypeModel.swift`（`NoteType` + 色板/图标候选 + `resolve` 解析）；② 批注 payload 加
  **可选 `type_id`**（`TextNote.typeId`），旧数据无此键 → nil，**零迁移**；③ **通用兜底**——nil/未知 typeId
  一律解析到固定的「通用」类型（`note.text` 黄色原样式），删除类型时其笔记回落通用（确认框提示 N 条回落）；
  ④ 类型管理入口就在**批注编辑器内**（类型菜单「管理类型…」→ `NoteTypeManagerView` 新建/改名/换色/换图标/
  删除），改动即时反映到已有笔记的图钉与侧边栏；⑤ 本地化 en/zh-Hans 双语言补齐。
  验证：`spike/note-type-test.swift` 16/16、`spike/store-test.swift` 34/34 全绿；xcodebuild BUILD SUCCEEDED。
  （GUI 手测清单未执行——无图形会话，留给用户按 brief 七项过一遍。）

- **采集页提取为 Svelte 前端工程（`web/`）**：原 923 行单文件 `capture.html`（CSS+DOM+IIFE）拆成
  Vite + Svelte 5 工程——`App/TopBar/StatsPanel/PenStat.svelte` 四个组件（顶栏/统计面板/笔状态胶囊
  改 runes 响应式，读 `lib/hud.svelte.js` 的 `S`），命令式逻辑按职责拆 `lib/`：`shared.js`
  （常量/公式/`G` 全局状态袋）、`render.js`（画布/几何/笔迹/环形盘）、`input.js`（指针/触摸/惯性/合批）、
  `ws.js`（连接/重连/消息分发）、`capture.js`（装配 + actions）。行为逐行移植（环形盘常量、惯性、
  合批时序等与 Mac 对齐处全保留）；原版 `drawHover()` 是定义了从未调用的死代码，按死代码丢弃
  （悬停光标本就 Mac 端画）。协议编解码器由 `lib/wire.js` 直接 import `Sources/Resources/wire.js`
  （**单一真源不动**，构建期内联，原 `__WIRE_JS__` 占位符与 Swift 侧注入代码随之删除）。
  构建：`vite-plugin-singlefile` 出单文件 HTML，`scripts/build-web.sh` 装依赖 + 构建 + 占位符
  （`__WS_PORT__`/`__TOKEN__`/`__PENS__，放 `web/index.html` 内联脚本里不过 bundler）自检后覆盖
  `Sources/Resources/capture.html`（产物勿手改）。验证：全部 JS `node --check` 过；
  `wire-codec-test.swift` 42/42、`wire-cross-test.js` 74/74 全绿；xcodebuild 编译过。

## 已修 / 完成（2026-07-25）

- **平板端半透明笔（荧光笔）画成一串圆斑（2026-07-25 用户反馈「和 macOS 端不统一」）**：根因——
  `capture.html` 的 `drawStroke` 对**所有**笔型都逐段 `stroke()` + 圆线帽，相邻段的线帽互相重叠，
  不透明笔看不出来，alpha<1 的笔在每个接缝处叠深一圈。实测（浏览器内定量采样，alpha=0.4/w=22）：
  沿中心线 alpha 在 163~200 间周期波动（**18.5%**），且整条都比设定的 102 深——重复叠加所致。
  修法两处，都是向 Mac 端 `inkDrawStroke` 对齐：
  ① **marker 整条一次成 path** + 平头 + multiply（Mac 端 marker 分支早就是这么做的，注释也写明了原因），
  修后中心线 alpha 恒为 102、零波动；
  ② **拆出活体层**——原本正在写的那一笔是往 `#ink` 上**增量叠加**画的（`liveBegin`/`liveTo`），
  半透明同样会累积，且抬笔前后观感不一致。改成新增 `#live` canvas（z-index 3，其余层顺延），
  `cur` 每次落点**整条重画**、`drawStroke(ctx, s)` 收 context 参数供两层共用——与 Mac 的
  `InkStaticLayer`/`InkLiveLayer` 同构。顺带两个好处：静态层不再因一笔在写而全量重绘；
  活体笔画改走 `pageToView`（原来直接用视口坐标硬画），写字途中滚动/缩放不再错位。

- **环形选笔盘改版：UX + Surface Dial 形制 + 平板同步显示（2026-07-25 用户反馈三点）**：
  ① **选择手感**——根因是旧版「半径分层」（内环笔/外环工具）要求精确控制笔离中心的距离，而那个距离
  由**页内归一化位移 × Mac 阅读区页宽**换算，随两端缩放漂移。改成 **`RadialLayout` 单层整圆**：所有扇区
  等分 360°、只看**角度**选中（角度做长宽比校正后即真实方向，天生与缩放无关），半径只判「是否离开中心
  取消区」；取消区半径与长按位移阈值改按**平板屏幕像素**判——新增 `padGeom`（C→S）让平板上报自己的
  页宽 CSS px，`AppModel.padPageWidth` 消费（未上报则回退旧的归一化阈值，安卓端不受影响）。
  顺带删掉已无读者的 `DocSession.pageViewWidth`。
  ② **视觉**——`RadialMenuView` 重写成 Surface Dial 的 radial menu 形制：毛玻璃盘 + 甜甜圈楔形扇区
  （选中整块亮起 + 白描边）+ 中心 hub 回显当前指向项名字（无高亮时显示「取消」）。
  **通透度（2026-07-25 用户反馈「好厚看不到底」后重调）**：盘底压暗从 0.46 降到 `baseDim` 0.10，
  扇区 `wedgeDim` 0.16、hub `hubDim` 0.22（`capture.html` 有对应的一组 + `#radialGlass` 的 CSS 底色）——
  **对比度不靠盘底堆**，改由「每个图标自带彩色圆片」+ hub 文字阴影提供；橡皮/翻页原本是裸白符号
  （盘一淡就会被白页吞掉），一并改成与笔同形制的彩色圆片（`disc`），视觉语言也随之统一。
  ③ **平板也显示**——新增 `radial`（S→C）把盘状态镜像下发（判定仍全在 Mac，平板不做任何判定），
  `capture.html` 新增 `#radial` canvas 用同一组半径/角度常量画同一个盘；断线/抬笔兜底收盘。
  **长按进度环（盘的前置动画）同样补到平板**（2026-07-25 用户追加）：新增 `pressRing`（S→C，`on` +
  页内归一化坐标），落笔发 on、判为在画/转成盘/抬笔发 off；**不带时间戳**——平板收到 on 用本机时钟起计，
  两端各自硬编码同一组常量（300ms 起显示 / 1s 填满 / 直径 30 线宽 3 / 正上方顺时针），局域网 RTT 的
  几毫秒偏差不可察觉。环与盘互斥，共用 `#radial` 这一层画。
  盘底做**真毛玻璃**：canvas 画不了 `backdrop-filter`，故底盘是圆形 div `#radialGlass`（z-index 4，
  `blur(16px) saturate(140%)` + 底色 `rgba(20,23,28,.16)`），扇区/图标/hub 由上面的 canvas（z-index 5）
  叠着画；`@supports` 兜底——浏览器不支持毛玻璃时退回高不透明度深色，保住对比度。
  三端契约同步：`PROTOCOL.md` + `WireCodec.swift` + `wire.js` + 两个 spike 一致性测试（新向量**追加在
  canonical 表末尾**——安卓 `WireCodecTest.kt` 按行号索引该表，往中间插会静默错位）。
- **笔迹多的页面卡顿（2026-07-25 用户反馈）**：根因——`PageStreamView` 持有 `@ObservedObject session`，
  hover 光标 / liveStroke / pressRing 等高频 `@Published` 更新（UDP 下笔尖移动可达百 Hz）会让所有实化页
  body 重算；墨迹 `Canvas` 不可比较 → 每帧把整页全部笔迹重新栅格化（逐点 `ctx.stroke`，笔多即上万次 draw call/帧）。
  修法：`PageStreamView.swift` 墨迹拆成两个 **Equatable 层**——`InkStaticLayer`（已完成笔迹，
  集合/线宽没变就跳过 body、复用已栅格化内容，只在落笔入库/擦除/缩放时重绘）+ `InkLiveLayer`
  （正在落的单笔，每帧只重画这一笔）；`drawStroke` 改为文件级 `inkDrawStroke` 供两层共用，渲染算法不变。
- **阅读区视图拆分（2026-07-25 用户要求，纯代码搬迁零行为变化）**：`PageStreamView.swift`（1580 行）
  拆出三个子 UI 文件——`Sources/Views/PageCellView.swift`（单页元胞：纸底/基图/贴片/各高亮层/墨迹/
  图钉/hover/进度环）、`Sources/Views/InkLayers.swift`（`InkStaticLayer`/`InkLiveLayer`/`inkDrawStroke`）、
  `Sources/Views/RadialMenuView.swift`（环形选笔盘）；`PageTile` 随之改 internal。主文件剩 1240 行
  （外壳 + `ReaderSurface` 滚动/缩放核心）。**同日二拆**：`PageStreamView.swift` 再拆为
  `PageStreamSupport.swift`（GeoSnap/Scratch/PinchInfo 等支持类型）+ 四个 `extension ReaderSurface`
  文件——`ReaderSurface+Scroll.swift`（滚动几何/refit/锚点跟随）、`ReaderSurface+Render.swift`
  （渲染调度/清晰贴片）、`ReaderSurface+Selection.swift`（文字选择/注解/复制）、
  `ReaderSurface+Zoom.swift`（pinch/命令缩放动画/滚轮与复制监视器）；`ReaderSurface` 及成员改
  internal（跨文件扩展需要），`zoomAnimDuration` 改计算属性（扩展不能有存储属性）。主文件剩 306 行。
- **SimPad 移除 + 工具栏精简 + 搜索/缩放 UI 改版（2026-07-25 用户要求四项）**：
  ① **SimPad 模拟平板窗口整体移除**——`Sources/Views/SimPad.swift`、`Sources/App/PadRenderer.swift`
  删除，`Window(id:"simPad")` 场景与工具栏按钮移除（真平板/网页采集页已够测滚动与落墨链路）；
  ② **工具栏缩放组**（缩小 | 1:1 | 放大，参考 Preview，位于工具栏最左 TOC 左侧）——按钮发通知
  （`readerZoomOut/In` 复用菜单同一通道 + 新增 `readerZoomActual`）路由到本窗口 `PageStreamView`；
  **成组用 `ControlGroup`（macOS 工具栏里渲染成单一胶囊分段组，Preview 同款；`ToolbarItemGroup`
  只摆一排独立按钮不成组）**，放在 `ToolbarItem` 里、带溢出 label；**命令式缩放（按钮/⌘±/⌘0/1:1）
  走 0.22s 逐帧动画**（`animateZoom`/`zoomAnimStep`，smoothstep 缓动，每帧 = pinch 同款
  「布局+scrollTo 同 runloop 原子 commit」，平滑且零闪烁；pinch/⌘滚轮等连续输入接管即取消动画）；
  `commandZoomActual()`：当前页 1 PDF pt = 1 屏幕 pt（未遮视口中心为锚，抽出共用 `viewportCenter`）；
  ⌘0 fit 动画到位后经 `fitAfter` 重定标基准（pageW 不变零跳变）。工具栏整体抽出
  `@ToolbarContentBuilder toolbarContent` + `zoomButtons`（内联会让类型检查器超时）；
  ③ **查找改标准 macOS 搜索**：放大镜 popover 移除，改 `.searchable(text:isPresented:placement:.toolbar)`
  工具栏搜索字段（⌘F 菜单激活、边打字边搜沿用 DocSession 250ms 防抖、回车跳下一个命中、收起字段即
  `clearSearch`）；阅读区顶部 Safari 式胶囊条（`findBanner`）只补命中计数 + 上/下一个导航；
  ④ **工具栏「跟随：插值/低通」A/B 切换按钮隐藏**——`scrollInterp` 逻辑与设置页 Picker 保留不变。
- **「笔架」位置限制 + 更名（2026-07-25）**：悬浮笔工具条改名**笔架**（`PenToolbar.swift`→
  `Sources/Views/PenRack.swift`，`PenToolbarView`→`PenRackView`；`@AppStorage` key 沿用旧名保住
  已存位置/收起态）。位置限制：整个胶囊（含拖拽手柄）始终完整落在阅读区内，上沿不进工具栏玻璃区
  （`topInset` 传入）——`clampedCenter` 按实测胶囊尺寸（`onGeometryChange`）算半宽半高留边，
  拖拽过程实时夹取、松手写回夹取后的落点；`reclampedStored` 在 onAppear/视口变化时校正存储值
  （旧版本无限制留下的越界值会被拉回可见区，不会再「贴死边缘拖不到」）。
- **笔粗细收敛两位小数（2026-07-25）**：裸 Slider 会产出 8.379999… 超长小数（既落盘又广播到 pad），
  滑杆写入时 `(w*100).rounded()/100` 收敛；网页端状态胶囊显示时 `Math.round(w*100)/100` 兜底。
- **网页端笔迹不立即下发（切档/换窗口后笔迹消失，要写一笔才回来）**：根因——平板收到新 docId 的
  `layout` 会清空本地笔迹（capture.html `setLayout`），但 Mac 端只在「新客户端连接」和「平板写/擦之后」
  才 `broadcastStrokes()`；pad 下拉切档（`selectPadDoc`）、Mac 切激活窗口（`setActive`）、关窗
  （`unregister`）这些路径只推 layout 不推笔迹。修法：所有换文档路径都汇到 `AppModel.push()`，在其中
  `pushLayout` 之后按文档键（`documentId ?? contentHash`，`pushedStrokesKey` 去重，翻页不重推）调
  `pushStrokesIfDocChanged` 补发该文档全部笔迹——顺序保证平板上「layout 清空在前、strokes 恢复在后」。
- **feat：网页端显示笔的用途状态**：capture.html 左下角加浮动状态胶囊（`#penStat`，`pointer-events:none`
  不挡落笔）——笔记模式显示当前笔（色块+笔头类型+粗细），擦除/翻页模式显示模式名。状态源统一走
  `updateHud()`（本地侧键 `cycleMode`/`cyclePen`、Mac 下发的 `pens`/`pen`/`mode` 消息都汇到这里）。
- **Xcode 重跑（⌘R）后缩放丢失**：缩放/滚动变化只走 `saveProgressThrottled`（0.7s 节流，只存领先帧），
  节流窗内被丢的尾帧没有补存；而 Xcode 重跑时旧进程是被 lldb 直接杀掉，走不到 `onDisappear` 的兜底
  保存 → 缩完立刻重跑，最后一次缩放永久丢失（翻页不丢是因为翻页有独立立即保存，掩盖了这个问题）。
  修法：`saveProgressThrottled` 加尾随补存——节流窗内的变化合批成一个 `Task` 延迟落库（读触发时最新
  的 page/frac/zoom/hfrac），新变化到来则取消重排；领先帧仍立即存。注：工程曾因 `InkMetrics.swift`/
  `InkWire.swift` 删除后未重跑 `xcodegen generate` 而编译失败，已重新生成。
- ✅ **① 通信协议改二进制**（2026-07-25 完成，编译过 + 跨语言测试全绿）：JSON→二进制线格式 v1。契约见 **`PROTOCOL.md`**（唯一真源）；三端字节级一致由 `Sources/Server/WireCodec.swift`（Swift，仅 Foundation）+ `Sources/Resources/wire.js`（浏览器/node 共用）保证。做法=**换序列化器不换对象模型**：`AppModel`/`handleInk`/各 `broadcast*` 的 `[String:Any]` 全不动，只在 `LANServer.rawSend`/`receiveWS`（WS opcode `.text`→`.binary`）与 capture.html 的 `send`/`onmessage`（`binaryType="arraybuffer"` + `Wire.encode/decode`）两个咽喉换掉。全 opcode 表 + 每消息字节布局见 `PROTOCOL.md §3/§4`。测试：`spike/wire-codec-test.swift`（Swift round-trip + 坏帧安全 34/34）+ `spike/wire-cross-test.js`（node JS round-trip + 与 Swift 导出向量 `spike/wire-vectors-swift.txt` 逐字节比对 58/58）。
- ✅ **② 加 UDP 传输**（2026-07-25 Mac 端完成，编译过 + 测试全绿；客户端侧并入安卓模式2）：RT 流（scroll/hover/ink/erase/probe）走 UDP，控制握手/下发/NACK 仍走 WS。传输头 `[u8 ver][u8 ptype][u32 session][u32 seq]+帧本体` 见 **`PROTOCOL.md §6`**；两个独立 seq 空间——UNREL（scroll/hover）最新胜、REL（ink/erase/probe）重排+NACK 经 WS 轻量重传+`stallMs=200` 缺口超时兜底。Mac 端：`Sources/Server/UDPReorder.swift`（纯逻辑重排）+ `UDPTransport.swift`（NWListener udp:8772 + 传输头解析）+ `LANServer` session 登记（authOK 带 `session`/`udpPort`，新 opcode `nack 0x50`，WS 已开 `TCP_NODELAY`）。**注意**：`flushStale` 卡死判据是「缺口首次出现时刻 `gapSince`」而非上次交付时刻——否则两笔之间的静置空档会让新缺口被立即跳过、NACK 来不及跑（集成测试抓出来的真 bug）。评审定案：不做 UDP 连通性首帧回执/降级（先看效果）、HELLO 只发一发不保活、probe 保持 REL、ringCap=512 待真机验证。测试：`spike/udp-reorder-test.swift`（26/26）+ `spike/udp-client-test.js`（node dgram 端到端，自动编译 harness 起真 LANServer，6/6：乱序补齐/NACK 重传/flushStale 兜底/UNREL 最新胜/坏 session 丢弃）。

## 已修（2026-07-23）

- **pad 打开后停在第 1 页、不跳 Mac 当前进度；TOC/搜索跳转 pad 也不同步**：`macScrolled` 原来只放行 `origin=="mac"` 的锚点，restore/search/toc 等 Mac 侧导航一律被过滤；且新平板连接时只补发 layout/docs/pens/strokes，从不发当前视口。修法：① `macScrolled` 改为 `origin != "pad"` 统一下发（回环风险只有 pad 来源，`maybeEmit` 有 `follower.isSuppressing` 守卫不会回声）；② 新增 `AppModel.pushCurrentViewport()`（带 `force` 标志绕过 pad 端 seq 去重），在新平板连接（`clientCount` sink，必须在 `pushLayout` 之后）和 `selectPadDoc` 切档后补发当前位置；③ pad 端 `applyViewport` 支持 `force`（不更新 vpSeq，避免与后续真实锚点 seq 冲突）。
- **pad 翻页按钮卡死（按一次后「下一页」永久失效、「上一页」连跳两页）**：根因是 `topVisiblePage`/`emitScroll` 的边界判断 `scrollY <= offY[i]+dispH[i]+GAP`——`turn()`/`applyViewport()` 都把 scrollY 精确落在某页顶部（=上页底+GAP），等号成立导致误算成上一页，`turn("next")` 目标=当前页原地不动。改严格 `<` 后验证：连续 next/prev 逐页正常、scroll 上报页码正确、seq 去重不受影响（Playwright + mock WS 实测）。
- **pad 翻页按钮在 layout 未到时按下会把 scrollY 置 NaN 整页卡死**：`turn()` 加 `pageCount/offY` 空值守卫。

## 已修（2026-07-22）

- **切换夜间模式慢，且离当前页越远越慢**：原实现夜间切换只借用滚动/缩放 settle 的 `realized`（视口±约 1 屏）小范围重渲，本身不该慢；但也没有为「切完立刻往下翻」预热任何缓存，翻页时仍要逐页现渲染（串行队列，CI 反色本身有开销）。改为夜间切换专属的 `scheduleNightRender()` → `settleRender(nightRadius: 10)`：在原有 `realized` 之外，**额外按「离当前页（`session.currentPageIndex`）近→远」的顺序预热 ±10 页**（`warmNeighborKeys`/`centerOutOrder`）——渲染引擎单串行队列按提交序处理，当前页永远最先出图，不会排在文档靠前页之后；预热只灌进渲染引擎的全局 LRU 缓存，**不写本地 `images` 字典**（那些页没有 `PageCellView` 承载，写了也用不上，还会绕开 `updateRealized` 的驱逐、白占内存）。
- **未出图区域底色不随夜间模式变**：单页占位色 `paper` 早已按 nightMode 取深浅，但页与页间隙、未实化区域露出的是 `ScrollView` 自身默认底色（系统外观，与阅读区内的「夜间模式」按钮是两回事）——夜间模式下这块区域仍是亮色。加 `voidColor`（深色 `Color(white:0.06)` / 浅色回退系统 `windowBackgroundColor`）并 `.background()` 到 `ScrollView` 上。
- **用户自测**：翻到一本较长 PDF 靠后的页，切夜间模式按钮 → 应立即变暗（含空白区域），无长时间卡顿；随后连续下翻数十页应基本无逐页现渲染的卡顿感。

## 已修（2026-07-21，第二批：交互/工程/设置）

- **切换文件后阅读区空白、须拖窗口才显示**（`PageStreamView`）：切文档 `.id(docKey)` 重建 `ScrollView`，`onScrollGeometryChange` 在容器尺寸与旧文档相同时不重发首帧几何 → `didInitialGeo` 卡 false → 首屏只画 10×10 空白。修法：`geometryChanged` 在 scroll 几何缺席（`containerW≤0`）时用外层 GeometryReader 的 `unobSize` 兜底填容器尺寸（**仅供实化窗口/偏移，绝不参与宽度/fit 决策**，不违反宽度反馈环红线）；`onAppear`(layout 就绪)/`fullWidth` onChange/`unobSize` onChange **三路兜底 bootstrap**，谁最后到位谁触发，不再单靠 onScrollGeometryChange。日志 `[RD] bootstrap ... via scrollGeo|unobSize`。
- **双指缩放只在 PDF 页上生效、页外空白不缩放**：`magnify` 手势从内容 ZStack 移到 `ScrollView` 容器（整个阅读区可捏合：页间空隙/末页下方/zoom<1 两侧留白）；`pinchChanged` 锚点从「内容坐标」改「容器/视口坐标 P，c=offset+P」，与 ⌘滚轮 `zoomCommit(anchorP:)` 及 `onContinuousHover(.local)` 同坐标系。
- **每次重编译反复弹「下载」目录 TCC 授权**：ad-hoc 签名 cdhash 每次变 → TCC 当新 App 重新弹。修法：`project.yml` 固定 `DEVELOPMENT_TEAM: T8F5T6HKG8`（zqsd 团队，含 Developer ID，后续公证复用）→ TCC 按 Team+BundleID(designated requirement) 记账，授权一次永久生效。zqsd 本机暂无 Apple Development 证书，Xcode 自动签名会按需创建；报错则回退手动 Developer ID 签名。
- **会话恢复 = 「打开集」语义（2026-07-21 重做，修「启动开一堆」）**：`open_documents` **不再是累积 MRU**（旧 MRU 只增不减、cap 10，每次启动重开 5 个→用户报「始终开很多文件」）。改为 **`openDocs` = 当前所有窗口的文档**（`= Set(windowDocs.values)`，去重保序）：`setWindowDoc` → `syncOpenDocs` 重同步（窗口里切文档，旧文档不再被任何窗口显示就退出打开集 → 不累积）；**cmd+w** `closeWindow` 逐个移除该窗口文档，**但**①退出中(`AppDelegate.isTerminating`)不动 ②关最后一个窗口不动（保留最后一本）。**`AppDelegate.isTerminating` 重新加回**（`applicationShouldTerminate` 在关窗前置位）用于区分 cmd+q（全恢复）vs cmd+w（逐个移除）。历史膨胀列表在**首次启动**由 `syncOpenDocs` 自动收敛到真正开出来的窗口。`restoreSession` 仍主窗口+最多再开 4 窗（安全上限，正常用不到，因打开集≈实际窗口数）。
- **单实例（last-wins）**：`AppDelegate.applicationWillFinishLaunching` 检测同 bundle 其它进程 → 优雅 `terminate()` 旧实例并接管（释放 8770/8771 端口，保证 Xcode Run 永远看到最新构建、旧进程即便没被回收也清掉）。正式发布如需「第二次打开只激活已有窗口」再切 first-wins。
- **标准设置页（⌘,）**：新增 `Settings` 场景 + `SettingsView`（双语，`@AppStorage` 持久化），三项：① 自动夜间模式（跟随系统深色，`ContentView` 监听 `colorScheme`）；② 延迟处理方式（插值/低通 Picker，复用既有 `scrollInterp`）；③ 启动自动开平板服务（勾选即启、启动即 `server.start()`）。
- ✅ **配对/安全 连接管理**（2026-07-21）：`LANServer.clientList`（地址+id）+ `kick(id)`，`ServerPanel` 列出已连平板逐个「断开」。二维码 UI 打磨仍可做。
- ✅ **保存/恢复 PDF 上次缩放 + 横向滚动**（2026-07-21）：schema v3→v5 加 `read_zoom`（相对 fit 倍率）+ `read_hfrac`（offsetX/pageW）；`DocSession.readZoom/restoreZoom/readHFrac/restoreHFrac`，`PageStreamView` 首帧套用，`ContentView` 进度保存带 zoom+hfrac。
- ✅ **笔预设可配置**（2026-07-21：`PenPreset`/`PenPresets`，设置页编辑名字/颜色含透明度/粗细，注入采集页 `__PENS__`；荧光笔=半透明宽笔、橡皮独立擦除模式）。
- ✅ **性能**：大文件 hash 缓存 `(path,size,mtime)→hash`（2026-07-21，`FileHasher.sha256Cached`）；页图缓存换自研 LRU（硬上限不机会性驱逐）+ 设置页可配上限（128M~2G，默认 512M）；懒渲染窗口已在（`PageRenderEngine` setWanted）。

## 已修（2026-07-20，阅读区 v2）

- **切换侧栏触发内容放大/缩小**：原 fit 模式侧栏开合会整页 refit。改为**侧栏/Inspector 开合零视觉变化**（只重定标 fitBasis/zoom，页面允许被玻璃盖住、可横向拖出）；仅窗口宽度真变（含 legacy 滚动条出现/消失）才触发 fit 锚定 refit。行为②按用户新要求更新（见 REQUIREMENTS §0）。
- **鼠标接入（legacy 占空间滚动条）时关侧栏后水平滚动条常驻**：fit 宽原不含 legacy 竖滚动条占位 → 恒差 ~16pt。修法：fit 基准 = 未遮宽 − `NSScroller.scrollerWidth`（overlay=0，鼠标插拔经 `preferredScrollerStyleDidChange` 刷新）+ **fit 状态只声明垂直滚动轴**（`pageW ≤ 未遮宽` 时不声明 `.horizontal`）。
- **回归「一直在放大」（2026-07-21，上一条的首版修复引入，真机日志实锤后重写）**：曾把 `ScrollGeometry.containerSize` 当宽度真相源——实测它在 ignoresSafeArea + 动态轴下**跟随 contentW+17pt**（非独立视口测量，contentInsets 恒 0），内容宽由它推导 = 闭环互抬每帧 +17 无限放大。**铁律：阅读区宽度输入必须全部与内容无关（GeometryReader + NSScroller 系统度量）；ScrollGeometry 只用于 offset/可见区**。窗口缩放 vs 侧栏开合用双 GeometryReader（全宽 vs 未遮宽）判别；开合已验证 pageW 全程不变（零视觉变化）。
- **放大出水平滚动条后跳到最左 + 闪烁；滚动条松手才出现**。根因两个：
  ① `ScrollPosition` 单轴 `scrollTo(x:)`/`scrollTo(y:)` 是「后写覆盖前写 + 未指定轴重置为 0」（`spike/scroll-x-probe.swift` T1/T4 实测）→ commit 里 x 请求丢失；**修法：全代码库禁用单轴 scrollTo，一律 `scrollTo(point:)`**（两轴同写 + 同 transaction 改尺寸超旧范围也原子生效，T3b）。
  ② pinch 放大原为「视觉变换、松手才真 commit」→ 布局不变，滚动条松手才出现；**修法：pinch 双向统一逐帧真 commit**（同 runloop 原子已被 atomic-commit-probe 证明）。
- **2026-07-20 修复：滚动跟随的"闪回/撤回"**。原「延迟补偿」用锚点到达时刻估速再外推（dead-reckoning），但 WiFi 成批投递 → `Δtarget/Δarrival` 得到荒谬瞬时速度 → 停手/换向时过冲后回弹＝用户看到的闪回+撤回。改为**去掉速度外推**，纯临界阻尼低通（`smCurrent += (smTarget-smCurrent)*catchup`），输出恒为凸组合、目标单调则绝不过冲。合成锚点流实测（`swift spike/scroll-follow-sim.swift`）：外推版过冲 3 页撞顶、方向反转 13 次、单帧跳 1.35 页；修复版过冲 0、反转 0、单帧 0.076 页。
- **2026-07-20 加入（保留待真机 A/B）：时间戳插值跟随**。采集页 `scroll` 带发送端 `performance.now()`（`t`，ms）；`ScrollAnchor.senderT` 贯通；`ScrollFollower` 双模式共用一个 tick——**平板路径**（`senderT>0`）估掉平板↔Mac 时钟差（最小延迟滤波），把样本按发送端戳落到本地时间轴，渲染落后 `interpDelay`（默认 **0.08s**，唯一旋钮）做线性插值，越过末样本则保持（**不外推**）；**本地 mac**（无戳）退回纯低通。桌面浏览器滚轮测试(另一台电脑)走的就是平板路径 → 能测到插值。⚠️ **模拟结论：LAN 条件下插值并未胜过纯低通**（`swift spike/scroll-follow-interp-sim.swift`：恶劣 WiFi 下 低通 单帧 0.103/滞后 0.275 vs 插值 0.160/0.295，均零过冲零反转）——要吸收 80ms 成批就得延后 ≥80ms > 低通 ~45ms 时间常数。插值的理论优势（滞后与速度无关、精确跟速）需**持续高速 fling** 或**真实成批很小**才显现，故留待真机手感定夺。嫌重可整套回退到纯低通。
- ✅ **S3 实时渲染**（首版）：平板 `ink`/`erase` → `AppModel` 路由到 padSession → 阅读区叠加渲染（压感变宽 + 笔色 + 擦除），随缩放/滚动重绘对齐。
- ✅ **锚点同步 sim↔Mac 双向**（方案 B 时代）：根因曾是 `SimPadRepresentable` 的存储属性在锚点变化时全都不变，SwiftUI 视图值比较判定"没变"直接跳过 `updateNSView`；修法是把 `scrollAnchor` 作为存储属性传入 representable。（SimPad 已于 2026-07-25 移除，此条存档备查同类坑。）

## ✅ 已结论的布局问题（2026-07-19）

> **2026-07-20 现状**：阅读区已按 `PDF-VIEWER-REBUILD-PLAN.md` 重建为自研页图流 `PageStreamView`（SwiftUI `ScrollView` + 页图）。本节是**重建前的排查历史**（PDFView 时代的坑），红线（严禁非原生味 hack / 严禁再套 PDFView + ignoresSafeArea 等）**仍然有效**，勿重走。

- **[布局] PDF 显示实现已整体移除（2026-07-19，用户指示"全部删除不要再实现"）**：`PDFKitView.swift` 已删；`ContentView` 保留原生框架（玻璃侧栏 NavigationSplitView + `.inspector` 笔记占位 + 工具栏）与文档加载（`session.pdf`），阅读区暂为占位。**重建 PDF 显示前必须先与用户确认方案，不要自行动手。**
  - 重建目标行为（用户三次确认）：① 侧栏叠加在 PDF 上（玻璃虚化真实内容）；② fit 时开侧栏页面挤到右侧可见区居中；③ 手动放大后允许被侧栏覆盖。
  - **红线：严禁任何非原生味的写法**。已试并被否/失败的路线：ZStack 仿侧栏（丑）、`.prominentDetail`+全边 ignoresSafeArea（内容整体左移一个侧栏宽度）、普通三栏（两侧不透明）、`backgroundExtensionEffect`（镜像反射非真内容）、嵌入式 NSSplitViewController + `automaticallyAdjustsSafeAreaInsets`（SwiftUI 窗口内不生效，需作窗口根控制器）、contentInsets + 各种归位/闭环校正（页面总差一个左 inset 或宽度异常）。
  - 排查方法论备忘：布局 bug 用临时分布式通知钩子 + 几何日志实测；注意 `layout()` 不触发 ≠ 视图没动（frame 原点平移不走 layout），要监控页面矩形 `convert(page.bounds, from: page)`。

## ✅ 工作区文件夹持久化（2026-07-20 首版完成，见 REQUIREMENTS §8）

- **决策**：因**确定要做 Windows/Android 版**，存储改用**自有 schema 的跨平台 SQLite**（`<工作区>/UniReader/library.sqlite`，系统 libsqlite3、无第三方依赖），**弃用 SwiftData**。
- **已实现（schema v2）**：`Sources/Store/`（`SQLite.swift` + `LibraryModels.swift` + `LibraryStore.swift`：建表/迁移/多 hash `findOrCreate`/`mergeDocument`/`addVariant`/`add·removeLocation`/`updateProgress`/notes CRUD）；`WorkspaceManager`（工作区 + 最近 + 导入 + 探测路径优先工作区副本 + 进度 + 复制/移出工作区 + 重定位 + 合并）；SwiftData 整套移除；默认工作区自动建。
- **UI 已加**：侧栏工作区切换 + **重命名**；文档右键 **复制到工作区 / 从工作区删除**、**关联为同一文档**（合并带确认）；路径失效 **重新关联文件** 提示；**阅读进度**自动记录 + 重开恢复。
- **运行时验证**：建库/schema/meta/WAL、`sqlite3` 直读、**v1→v2 迁移**、**32/32 DAO 测试**（`spike/store-test.swift`）。
- **多窗口 + 会话恢复（2026-07-20）**：方案 2（多个完整工作区窗口，⌘N）+ 侧栏右键「在新窗口打开」（`WindowGroup(id:"docWindow", for:String)` + `openWindow(value:)`）。打开文档集实时存 `meta.open_documents`（JSON，随文件夹走）；启动首窗恢复整组（其余各开一窗，`AppModel.didRestoreInitial` 防重复）。**（2026-07-21 更新）** `open_documents` = **当前所有窗口的文档集**（`openDocs`/`syncOpenDocs`，见「会话恢复=打开集语义」）：cmd+w 逐个移除、最后一个窗口/cmd+q 退出不移除（`AppDelegate.isTerminating` 区分）；`restoreSession` 恢复窗口上限 5（主窗口+4，安全上限）。`AppModel`/`WorkspaceManager` App 级单例，全窗口共享 WS/LANServer，平板跟随激活窗口；**单实例 last-wins**。
- **待补**：① 旧 SwiftData 数据不迁移（需重新导入）；② ✅ 手写笔迹已落 `note` 表（见专节）；③ 合并的「拆分」逆操作暂无；④ meta 里 `last_document_id` 是旧单文档设计的残留键（已弃用不读，无害）。
- **✅ 外部文件同盘相对路径（2026-07-22，schema v6）**：导入/重定位外部 PDF（未拷入工作区）时，若其路径与工作区文件夹**同属一块可移动/外置卷**（`URLResourceKey.volumeIsInternal==false`，如移动硬盘/外置 SSD；**不判 removable/ejectable**——同款外置 SSD 实测这两个 key 常是 false，只有 `volumeIsInternal` 可靠区分，`/Volumes/SSD` 本机验证过），改存**相对工作区文件夹的路径**（`location.is_relative=1`，可含 `..`，如 `../Papers/foo.pdf`）而非绝对路径；换电脑插上同一块盘（挂载点从 `/Volumes/X` 变 `/Volumes/X 1` 之类）依然能解析到文件。系统内置盘不做此处理（挂载点恒定，绝对路径已够用，且相对化反而会在「只挪工作区文件夹、不挪源文件」时失效）。Inspector「文件」列表新增 **同盘相对路径** 徽章区分。**用户自测**：工作区放外置盘上，从同一块盘的其它目录导入一个不拷贝进工作区的 PDF → Inspector 应显示「同盘相对路径」徽章；把盘换个挂载名重插（或换电脑插上）→ 该文档应仍能自动找到、无需重新关联。

## ✅ T1/T2 文字选择 / 全文搜索（2026-07-21 完成）

- **T1 文字选择（2026-07-21 重做，弃自研词框排序，改 PDFKit 原生选择引擎）**：原生数字版 PDF 的选择
  **不再自研**——直接复用 `PDFDocument.selection(from:at:to:at:)`（与 PDFView 同引擎），可视阅读顺序、
  多栏/跨行/跨页、CJK 全由 PDFKit 负责，本层只做坐标进出。链路（`Sources/Views/PageStreamView.swift`）：
  拖选 `dragSelectGesture`（`DragGesture(minimumDistance:2)`，挂 ScrollView 容器、与 pinch 同 `.local` 坐标）
  → 起点/当前点经 `containerPointToPageSpace` 换成 PDF 页空间点（`PageGeometry.pageSpacePoint`，
  `normalizedRect` 的点级逆变换，越界按页边 clamp）→ `pdf.selection(from:at:to:at:)` 拿原生选区 →
  `PageGeometry.normalizedLineRects`（`selectionsByLine` 逐行框、同一套 rotation-aware 归一化）落成
  `TextSelection{rects:[page:[CGRect]], text}` → `PageCellView` 淡蓝 Canvas 画高亮（归一化随页尺寸自适应，
  缩放/滚动免重算）。**双击选词** `.onTapGesture(count:2)` → `PDFPage.selectionForWord`（光标位取自
  `.onContinuousHover` 维护的 `cursorP`）；**单击空白取消** `.onTapGesture(count:1)`（修掉旧实现「点空白
  不取消」——旧的 `minimumDistance:1` 拖选纯单击不触发、`onEnded` 清空逻辑根本不跑）；**⌘C** NSEvent 本地
  监视器直写 `NSPasteboard`（`selection.text`；`.onCopyCommand` 依赖 NSResponder 焦点链，纯 `ScrollView`
  容器拿不到焦点、⌘C 没反应）。**扫描页/OCR 页无原生文本 → 无选择**，留给 T3 走 `PageTextLayer`（`OCR.swift`）。
- **T2 全文搜索**：复用 PDFKit 内建 `PDFDocument.findString`（不重新实现词法扫描，跨行/跨页鲁棒），
  `TextSearch.find`（`Sources/App/TextSearch.swift`）→ `PageGeometry.normalizedLineRects` 逐行取框归一化。
  状态落 `DocSession`（`searchQuery`/`searchMatches`/`currentMatchIndex`，250ms 防抖，边打字边高亮+跳首个
  命中，类 Safari）。命中高亮：全部命中淡黄、当前命中橙色（`PageCellView` 同一 Canvas 机制）。
  （2026-07-25 UI 改版：搜索框改标准 `.searchable` 工具栏字段 + Safari 式导航胶囊条，见 2026-07-25 节。）
- **坐标真相源**：`Sources/App/PageGeometry.swift` —— `normalizedRect`（页空间→显示归一化，正变换）+
  `pageSpacePoint`（逆变换，选择用）+ `normalizedLineRects`（选区/命中共用行框）。搜索与选择共享同一套，
  避免两套坐标对不上。
- **为什么弃旧方案**：旧 T1 自己抽词框（`PageTextEngine` 缓存 `PageTextLayer` 词级 run）+ `geometricOrder`
  重排 + 按序位切片跨词选区。问题：① 选择粒度只能到「词」run（CJK 无空格退化成整行），起止不精确、观感乱；
  ② 几何行聚类对多栏/思维导图版面不稳，选区仍会东一块西一块；③ 纯单击不取消选择。PDFKit 原生选择引擎
  一次性解决全部，且与 T2 搜索同源。`PageTextEngine.swift` 已删；`PageText.swift` 回到桩（`TextRun`/
  `PageTextLayer` 仍作 T3 OCR 文本层「货币」保留，`OCR.swift` 依赖）。
- **已知待办**：
  - 旋转页（90/180/270）的坐标进出未用真实旋转 PDF 验证（`rotation=0` 是绝大多数文档、已确定正确，
    进/出用的是同一套逆/正变换、互为反函数）；找一份旋转 PDF 实测选区/搜索高亮是否对齐页面内容。
  - `PDFDocument.findString` 同步扫描，超大文档（几千页）搜索可能有感知延迟；已放到 `Task.detached`
    不卡 UI，真机验证够不够快，不够再换 PDFKit 渐进式 `beginFindString` 委托 API。
  - 拖到页边缘暂不自动滚动（PDFView 有）；跨页拖选需先滚到目标页再继续拖。非阻塞项。
  - 系统 Vision OCR（`VisionOCRProvider`）仍是空骨架（离线备选，未接）；`HTTPOCRProvider` 通用骨架未用（Paddle 走独立 `PaddleOCR.swift`）。

## ✅ T3 OCR（Paddle PP-OCRv6，2026-07-21 完成，编译通过）

- **动机**：用户实测——**原生 PDF 内嵌文本层本身不准**（错字漏字，坏 CMap/劣质旧 OCR），PDFKit 抽出来就是错的。
  接 Paddle 云 OCR 拿准确文本，覆盖原生文本做选择/复制/搜索。
- **模型 = PP-OCRv6**（用户选）：纯 OCR，返回逐行 `rec_texts` + 行框 `rec_boxes`（输入图像素坐标、左上原点）。
  行级框天然贴合可选/可搜文本层；VL-1.6 只给块级框（段落级）不适合选择，故不用。
- **客户端 `Sources/App/PaddleOCR.swift`**：异步 job——`POST /api/v2/ocr/jobs`(multipart 上传单页 PNG，`model`+`optionalPayload`
  两个 form 字段) → 轮询 `GET .../{jobId}` 到 `done`(2.5s 间隔，~5min 超时) → 下预签名 JSONL → 解析
  `result.ocrResults[].prunedResult.rec_texts`/`rec_boxes` → 按图宽高归一化成 `TextRun`(0~1 左上原点)、按 y→x 排阅读顺序。
  Auth `Authorization: bearer <key>`。**页图由 `PageBitmap.render` 出**（显示朝向、top-origin，与阅读区同款）→
  OCR 框和显示页天然同坐标系，**无需 rotation 变换**（比原生选择还省事）。
- **触发（用户要「手动 + 逐页按需」两种都要）**：
  - 逐页按需——`session.ocrEnabled` 时，阅读区 `updateRealized` 把**可见窗口**入队（「看到哪页处理哪页」）。
  - 手动全量——OCR 面板「识别全部页」`ocrAllPages()` 全量入队。
  - 编排在 `DocSession`：`ocrRuns[page]` / `ocrQueue`(@Published) / `ocrActivePages` / 并发上限 3 / `pumpOCR`。
    每页先查 `ocr_page` 缓存(命中秒回、不占网络槽)，miss 且已配 key 才排队跑网络；跑完回填缓存 + 刷 `ocrRuns`。
- **缓存**：`ocr_page(content_hash,page,provider="paddle-ppocrv6")`，payload=JSON `OCRPagePayload{w,h,runs}`。
  打开文档 `reloadOCRState()` 查 `ocrPageCount>0` → **自动启用**（换机/重开秒复用，无 key 也能用缓存做选择）。
  换文档旧任务回调靠 `contentHash==hash` 守卫整个丢弃（不动新文档计数器）。
- **选择/搜索集成（`PageStreamView`/`DocSession`）**：某页有 OCR 层就覆盖原生——
  拖选/双击在 OCR 页走**行级**选择（`setOCRSelection`/`ocrLineHit`，锚点→焦点按页号+行序切连续行，高亮行框+拼文本，
  ⌘C 得准确 OCR 文本）；原生页仍走 PDFKit 选择引擎。搜索 `ocrEnabled` 时搜 OCR 文本(`searchOCR`，行级命中)否则 findString。
- **设置/UI**：设置页(⌘,) OCR 段——引擎 Picker(关闭/Paddle) + `SecureField` key（存 UserDefaults：`ocrEngine`/`ocrPaddleKey`，
  含密钥不进工作区）。阅读区工具栏 `text.viewfinder` 图标 → OCR 面板：开关「用 OCR 文字」+ 进度(已识别 X/N、排队数) +
  「识别全部页」+ 错误提示；未配置 key 时引导去设置。
- **已知待办**：① 整文档识别是逐页 N 个 job（非整文件 1 job）——匹配「逐页按需」，大书 job 数多但增量可缓存/可续；
  需要再加「整文件一次上传」快路。② 拖选跨「OCR 页↔原生页」混合边界只做尽力(焦点页无 OCR 时冻结)；③ 搜索只覆盖
  已识别页（按需模型下未识别页搜不到，先跑 OCR 再搜）；④ 网络任务无取消（换文档靠 hash 守卫忽略，浪费但无害）；
  ⑤ Vision 离线 OCR 未接。

## ✅ 手写笔迹持久化（2026-07-20 完成）

- **模型**：一条笔画 = `note` 表一行，`kind=2`。`note.id = stroke.id.uuidString`（擦除 → `deleteNote(id:)` 一一映射）；`page` / `anchor`（点集**归一化**包围盒 0~1）走列；`payload` = 干净跨平台 JSON `{color:{r,g,b,a}, width, points:[[x,y,pressure]]}`（显式数组，非 SIMD 编码；Windows/Android 易读）。笔记挂**逻辑文档**（全 variant 共用），与阅读进度同源。
- **映射**：`Sources/App/InkModel.swift`——`InkColor: Codable`、`InkStroke.id` 改可赋值 `var`、`InkStroke.toNote(documentId:)` / `init?(note:)` / `normalizedBounds` / 私有 `InkStrokePayload`。
- **对账落库**（`ContentView`）：`.onChange(of: session.strokes)` → `persistInk()`——当前有而未落库 → upsert；曾落库而现已无（擦除）→ delete；用 `session.persistedStrokeIDs` 增量对账（liveStroke 变化**不**触发，仅完成/擦除才写）。
- **加载**：`loadSelected` → `loadInk(documentId:)` 恢复到 `session.strokes` 并置对账集（避免加载即被判「新增」重复写）；切文档/路径失效 → `clearInk()`（顺带修了旧 bug：换文档未清空内存笔迹）。`DocSession` 加 `documentId` + `persistedStrokeIDs`（非 @Published）。
- **落地即渲染**：`session.strokes` 变 → 阅读区/Inspector 画笔区同读，自动显示恢复的笔迹。
- **验证**：`spike/ink-store-test.swift`（21/21）——round-trip、note 列语义、payload JSON 形态、擦除删除、空笔画跳过、非 ink/损坏 payload 容错、多笔增量对账。App 整体 `xcodebuild` 通过。
- **待调**：擦除仅删内存对应笔画后异步删行（已覆盖）；大量笔画时 `notes(documentId:)` 全量读+client 端 filter kind==2，量大再加 `kind` 查询或分页。
- **UX 补充（2026-07-20）**：
  - **修 bug**：墨迹滚到顶部会从半透明工具栏透出、浮在标题栏上 → 绘制用 `window.contentLayoutRect`（排除标题栏/工具栏）裁剪。
  - Inspector 画笔区：每页一行**可点击跳转**（`onJumpTo(page, frac)`，frac 取该页最靠上笔迹）+ 尾部 **× 删本页手写**（移除内存笔画 → onChange 对账删 note）。
  - Inspector 文件区：每条 location 尾部 **× 删除**（`WorkspaceManager.deleteLocation`，工作区副本连文件删；**仅多于一项时可删**，至少保留一项）。
- ✅ **文字注解 kind=0**（2026-07-21：选区右键加批注 / 点注解锚页面坐标 / 页面荧光高亮+图钉查看编辑 / Inspector 列表跳转删 / 落库对账）+ ✅ **文字高亮 kind=3**（2026-07-21：选区右键调色板一键上色 / 页面铺色 / Inspector 列表）。

## ✅ 笔工具重做：画布悬浮可拖拽面板（笔架）+ 收藏笔插槽 + 真实笔触渲染（2026-07-22 完成，编译通过）

> **取代了上一版「长按切笔 + 工具栏徽章」**（原 S5 长按呼出面板 + `ContentView.penStatusBadge` 已整体拆掉）。
> 用户实测反馈：笔的颜色/类型/粗细不该是「系统设置里固定配置好」的东西，
> 应该像 GoodNotes/Notability/Apple Notes Markup 那样——画布上一个可拖拽的浮动工具条，装几个「收藏笔」插槽，
> 再点一下已选中插槽才弹出调整面板（颜色/粗细/笔头类型），改完立刻生效，**调整入口永远在画布现场**；且笔
> 相关的一切不放操作栏，整体挪进 PDF 阅读区域。四个关键决策：只做 Mac 阅读区（pad 不变，继续吃 Mac 下发的
> 笔定义本地画）/ 保留多支收藏笔插槽（GoodNotes 式）/「笔类型」是真正不同的笔触渲染（不是换个名字的颜色
> 预设）/ 与上一版整体替换（不并存）。（2026-07-25 该面板更名「笔架」并加位置限制，见 2026-07-25 节。）
- **笔触类型 `PenBrushType`**（`Sources/App/PenPreset.swift`）：`ballpoint`/`fountain`/`marker`/`pencil` 四种，
  各自笔宽公式不同（`strokeWidth(pressure:base:)`）——圆珠笔 `0.6+p·w`（原公式不变）、钢笔 `0.3+p^1.6·w·1.15`
  （压感响应更夸张）、马克笔恒定 `w`（不吃压感）、铅笔 `0.5+p·w·0.85` 且不透明度 ×0.85 + 逐点沿路径垂线方向
  加确定性抖动（`pseudoJitter`，种子取归一化坐标而非真随机——`Canvas`/`GraphicsContext` 每次重绘都重跑这段
  代码，真随机会导致铅笔笔迹每次重绘/滚动都在抖）。**Mac**（`PageStreamView.drawStroke`）和**pad**
  （`capture.html` 的 `strokeWidthFor`/`scaledColor`）各自实现同一套公式（两个语言没法共享代码，靠公式对齐）；
  pad 的实时手感反馈阶段（`liveBegin`/`liveTo`）不做铅笔抖动（增量画的时候还不知道下一个点，没法算稳定的
  垂线方向，等落成完整笔画走 `drawStroke` 回放才有纹理）——**已知简化，先能用后续再打磨**，马克笔叠笔接缝
  变深的问题同理留到下一轮。
- **迁移坑**：`PenPreset`/`InkStrokePayload`（落库 payload）都是 `Codable`，旧数据 JSON 里没有 `type` 键——
  Swift 合成的 `Decodable` 对缺失 key **不会**自动填默认值，直接 decode 会整条失败。两处都手写了
  `init(from decoder:)`，`decodeIfPresent(forKey:.type) ?? .ballpoint` 兜底，旧笔预设/旧笔迹都能正常加载。
- **`AppModel.pens` 成为收藏笔唯一状态源**：`@Published var pens: [PenPreset]` 的 `didSet` 自动
  `PenPresets.save()` 落盘 + `broadcastPens()` 广播给 pad（`{"type":"pens","list":[...],"active":N}`，连接/
  服务启动时也补发一次，同 `layout`/`docs` 的「变了就广播」套路）；`addPen`/`removePen` 两个方法处理下标平移
  （删除当前选中项时回退第 0 支、删除项在选中项之前时选中下标要跟着 −1，`removePen` 里有个顺序坑：`pens`
  的 `didSet` 会带着**还没修正的旧下标**先广播一次，修正完 `padPenIndex` 后必须再手动 `broadcastPens()`
  纠正一次，不然 pad 短暂收到跟 Mac 不一致的 active 下标）。
- **悬浮可拖拽面板**（`Sources/Views/PenRack.swift`，`PenRackView`）：挂在 `ReaderSurface` 的
  `ScrollView` 本身（`.overlay { GeometryReader { ... } }`，视口坐标系不随内容滚动，跟已有的 `followTicker`
  同一个机制）。`.regularMaterial` 胶囊：拖拽手柄 + N 个笔插槽圆形色块（选中的套 `.accentColor` 描边）+
  `+`（新增笔，立即选中+弹出编辑器）+ 橡皮/翻页两个模式按钮。点未选中插槽切笔；再点一次已选中插槽弹出
  `.popover` 编辑器（`ColorPicker`+粗细 `Slider`+类型 `Picker(.segmented)`，任何一项改动直接写
  `app.pens[i]`，无「保存」按钮）；插槽右键菜单删除（至少保留 1 支）。拖拽用
  `DragGesture(minimumDistance:6)`（阈值参考代码库里 `dragSelectGesture`/pad 端平移死区的先例，避免跟插槽
  点击手势打架），位置存 `@AppStorage`（`penToolbarFracX`/`Y`，视口宽高的 0~1 比例而非绝对像素，窗口缩放后
  仍在合理位置）。
- **修 bug（首版上线即反馈"什么也看不到"）**：首版按 `hover` 圆环的老规矩把显示条件挂在
  `app.padSession?.id == session.id`（只在当前正被 pad 镜像的那个窗口显示）——但 `pens`/`padPenIndex` 是
  **设备级全局状态**，不像 hover 那样是某次 pad 事件路由到的具体会话，挂错了作用域：没连 pad / `padSession`
  解析恰好不等于当前窗口时，面板直接不出现，跟长按机制一起被拆掉后就变成真的"什么都没有"。改用
  `isActiveWindow`（当前 key window，`ReaderSurface` 已有的既有参数，跟 ⌘±/⌘0 缩放快捷键同一套判定）——只跟
  "你在操作哪个窗口"有关，不依赖任何 pad 连接/路由状态，更简单也更对。顺带把 `applyPenSelection`/`addPen`
  两个方法上完全没用到的 `session: DocSession` 参数删掉（S5 版本遗留，新版本压根不需要）。
- **设置页（⌘,）不再是笔的编辑入口**：`SettingsView.swift` 的「Pens」整个 `Section` 删掉。
- **已移除的上一版实现**：`ContentView.penStatusBadge`；`AppModel` 的 `holdTask`/`startHoldWatch`/
  `endHoldWatch`/`handlePenMenuTap` 长按状态机 + `"tap"` inbound case；`DocSession.PenHoldState`/`penHold`；
  `PageCellView` 里进度环/横排色块面板那段渲染；`capture.html` 的 `holdSuppressed`/`menuSuppressed`/
  `penHoldAbort`/`penMenuOpen`/`penMenuClose`/`"tap"` 收发。**保留**：`padMode`/`padPenIndex`、
  `applyPenSelection`（新面板继续用，现在还顺带把模式拉回笔记模式）、pad 端 `cyclePen()`/`cycleMode()`
  （PageUp/PageDown 侧键仍然工作，只是现在操作的是 Mac 推下来的动态列表）。
- **用户自测**：Mac 阅读区应出现可拖拽胶囊面板（工具栏笔相关的东西彻底消失）；拖到任意位置松手生效，缩放
  窗口/重开 App 后面板仍在合理位置；点插槽切笔 → pad 落墨颜色/粗细跟着变；再点一次当前插槽 → 弹出编辑器，
  改颜色/拖粗细/切类型立刻在 pad 和 Mac 两边生效，不需要任何保存操作；四种类型轮流试应有明显视觉差别（马克
  笔恒定宽度、钢笔压感对比明显、铅笔偏淡边缘不光滑、圆珠笔是原来的样子）；⌘, 设置页「Pens」分区已消失；
  断开重连 pad / 重开 App → 收藏笔列表和当前选中的笔应保持上次退出时的状态；pad 侧键 PageDown 仍能在收藏笔
  间循环，且循环到的笔跟 Mac 面板里实际存在的插槽一致。

### OCR 文字选择优化（2026-07-21）
- ✅ **选择「分组感知」**（`PageStreamView.ocrGroupSelection` + `DocSession.ocrGroups` 缓存）：只选锚点所在分组内、纵向落带内的行 → 与「可选分组」视图**同色块严格一致（所见即所选）**；单行横拖 fallback 线性（保页码）；跨页仍线性。
- ✅ **OCR 识别块调试可视化**（OCR 面板「显示识别块 · 每块独立/可选分组」）：`OCRFlow.columnGroups` 并查集列/块聚类。**可调旋钮**：分组间隙 1.2 行高 / 重叠 35%（同时驱动视图与选择）；单行 1.8 行高。
