# UniReader TODO

> 规划与待办清单。规格见 `REQUIREMENTS.md`，进度见其第 6 节。
> **已完成项全部归档在 `HISTORY.md`（2026-07-25 起，条目做完即迁移），本文件只留进行中/待办/交接状态。**

## 🧭 当前状态速览（交接用）

- 工程 xcodegen 管理：改文件后 `xcodegen generate`（新增文件时必做）→ `xcodebuild -project UniReader.xcodeproj -scheme UniReader -destination 'platform=macOS' build CODE_SIGNING_ALLOWED=NO`。非沙盒，**macOS 26+（Tahoe，不做低版本兼容）**。
- 已完成清单（工作区持久化/多窗口/采集页/方案 B/阅读区 v2/T1-T3 OCR/笔迹持久化/笔架/二进制协议/UDP/各批 bug 修复）**见 `HISTORY.md`**。当前要点：
  - **阅读区 v2（`PageStreamView`，纯 SwiftUI）已重写完成待真机验证**，五条硬指标与机制见 `PDF-VIEWER-REBUILD-PLAN.md`。**红线：阅读区纯 SwiftUI，严禁 AppKit 视图（含 NSViewRepresentable 包 NSScrollView）**。
  - 真平板已接入方案 B（连续多页 + 双向锚点 + 按需取图 `/page.png?i=N` + 双指缩放 + 惯性 + hover + 夜间 + 手写板模式 + 锁缩放 + 防误触）；采集页 HTML 独立为 `Sources/Resources/capture.html`。参数（缩放 catchup、惯性衰减、防误触阈值等）待真机手感微调。
  - 滚动跟随 `ScrollFollower`：**只跟随不预测**（纯临界阻尼低通，禁速度外推）；时间戳插值路径保留待真机 A/B（模拟结论：LAN 下未胜纯低通，详见 HISTORY）。
  - **2026-07-25：SimPad 已移除**；搜索改标准 `.searchable`；工具栏缩放组（缩小|1:1|放大）带 0.22s 逐帧动画；悬浮笔工具条更名「笔架」`PenRack.swift` 并加位置限制。
  - 通信协议 = 二进制线格式 v1（`PROTOCOL.md` 唯一契约）+ UDP RT 上行（Mac 端就绪）。
  - **2026-07-29：工作区改窗口级，多工作区并存**（双击另一个 `.unrd` = 新开窗口，原窗口不动）。方案、红线与踩坑见 **`REQUIREMENTS.md §8.1`**（权威）。三条要记住的：① **同一工作区路径必须共享同一个 `WorkspaceManager`**，否则两个 `LibraryStore` 会互相清库丢笔记；② 「双击/打开文档」这条链路的初始内容决策必须锚到 `applicationDidFinishLaunching`，且**别拿 `isKeyWindow` 当认领条件**（冷启动时全为假）；③ SwiftUI 每次 app 激活会凭空多开一个空窗口，四条来源已全部排除、只能识别后关掉。排障：`touch ~/Library/Logs/UniReader-ws.log` 开全链路日志（unified logging 抓不到本 app 输出）。
  - **2026-07-26：笔&笔架&笔迹四项已落地**（尺子模式 / 橡皮局部擦除+尺寸与笔宽两端同步 / Mac 本机落墨临时模式 / 笔记框选移动），机制与验证见 `HISTORY.md`，真机回归待做（见「接下来」）。
  - **2026-07-27：多层笔迹已落地**（图层作用域=整篇文档，相互独立、可同时显示/只显示一层、动态新建不设上限）：`InkStroke` 加 `layerId`（`InkLayer` 注册表，schema v7 新表 `ink_layer`）；`AppModel.eraseNear`/框选/`broadcastStrokes` 均按可见图层过滤；PenRack 新增「图层」弹出面板（`LayerRack.swift`，显示/隐藏、改名/改色、拖拽排序、删除）；线协议新增 `layers`（0x3A，S→C）同步图层表+当前作画图层给平板（`strokes` 广播已按可见性过滤，故平板天然只见可见图层；`capture.html` 暂不做图层 UI/HUD）。编译通过 + `wire-codec-test`/`wire-cross-test`/`ink-store-test`/`ink-edit-test` 全绿，**待用户真机验证**（多图层显示/隐藏/擦除隔离/持久化/平板同步）。
  - **2026-07-27：web 端（平板）新增框选移动**（此前只有 Mac 本机 `pointerTool==.lasso` 能框选移动，平板端是新能力）：`mode` 加第 4 态 `lasso`（PageUp 循环切入，与 note/erase/page 同款）；平板本地用与 Mac `finishLassoSelect` 同一算法复刻一份命中判定（`render.ts lassoHitTest`/`pageLocClamped`）做即时框选高亮 + 拖动 ghost 预览（纯本地、不上行，同 `eraseHit` 先例）；松手提交移动才发新增的 `lassoMove`（0x47，C→S：框选矩形 + 位移，均页内归一化）——Mac 收到后**不信任平板的本地判定**，用真源 `session.strokes`/`textNotes` 按同一算法重新命中、`InkEdit.translated` 平移、持久化，再 `broadcastStrokes`/`broadcastNotes` 镜像回所有端（`AppModel.applyLassoMove`）；平板侧提交后到权威回传之间做乐观位移渲染（避免弹回原位再跳新位置的闪烁），1s 兜底超时防止 Mac 零命中时永久卡住预览。协议改动：`wire.js`/`WireCodec.swift` 的 `MODEK`/`modes` 表从 3 项扩到 4 项 + 新 opcode `lassoMove`；`wire-codec-test`（55 通过）/`wire-cross-test`（100 通过）全绿，`tsc --noEmit`/`vite build`/`xcodebuild` 均过。**待用户真机验证**（框选/移动手感、跨图层命中是否符合预期、Mac↔平板双向模式切换是否同步）。
  - **2026-08-05：触摸板端可以「开工作区文档」与「用目录跳转」了**（网页采集页 + 安卓输入板两端同步落地，**待真机验证**）。此前平板只能在 Mac **已经打开**的窗口之间切（`docs`/`selectDoc`），工作区里没开的文档看不见，目录更是从未上过线。
    - **协议加三条 + 扩一条**（契约 `PROTOCOL.md`，三端字节级一致）：`openDoc`(0x2A, C→S)、`library`(0x3B, S→C, 工作区书库全量镜像带 open 标记)、`toc`(0x3C, S→C, PDF 目录先序拍平 + depth)；`gotoPage`(0x29) 加**尾部可选 f32 frac**（0/缺省即省略那 4 字节，故「只跳页」的老形态字节不变，同 `ink begin` 的 flags 先例）。
    - **⚠️ 线上从此有三个互不相通的 id 空间**（`PROTOCOL.md §4.1` 有专门的警告块）：`docs`/`selectDoc` = 窗口会话 id；`library`/`openDoc` = 库文档 id；`layout`/`toc` 的 docId = 内容哈希。平板判「这份目录是不是当前这本书的」只能用第三种——切档时 `layout` 与 `toc` 两条广播的先后没有保证，不核对就会把上一本的目录挂到新书上（两端都做了核对）。
    - **打开语义＝新开一个 Mac 窗口**（2026-08-05 用户拍板，不顶掉当前窗口的文档、也不做「只在平板上换、Mac 不动」的隐藏会话）。已在同工作区某窗口开着的则等价切过去，不重复开窗。实现要点：`openWindow` 是 View 层的 environment action，App 级的 `AppModel` 够不着 → `padOpenDocRequest` 带 `sessionID`，只有平板当前跟随的那个窗口执行（不带 sessionID 的话每个窗口都会开一个）；新窗口的会话 id 此刻还不存在 → `pendingPadFollowDocId` 记着，等它 `loadSelected` 完成（`sessionDocumentChanged`）再把平板锁过去。
    - **`WorkspaceManager` 是 `@MainActor` 而 `AppModel` 不是**：`broadcastLibrary` 直接引用工作区会撞 actor 隔离，故改由 `DocSession` 捎带**快照**（`workspaceName`/`workspaceFolder`/`libraryDocs`，`ContentView.syncWorkspaceSnapshot` 注入）。目录同理挪进 `session.toc`（原来是 ContentView 的 `@State`，App 级广播够不着）。
    - **两端 UI 都是左侧拉抽屉**（`web/src/Drawer.svelte`、`android/…/pad/PadDrawer.kt`），两页：目录（可折叠树 + 当前章节自动展开祖先链并滚到视野中间 + 点条目跳到章节标题那一行后自动收起）／书库（列工作区全部文档、已打开的标徽标）。**坏书签**（destination 解不出目标页）线上 `hasPage=0`、解码后 `page = -1`，两端一律渲染成不可点的灰行、不显示页码、不参与当前章节追踪——与 Mac 端 `TOCListView` 同款语义（真实 PDF 里空 destination 很常见，当成第 0 页会把高亮永远钉在最后一项）。
    - 验证：`wire-codec-test`(61)／`wire-cross-test`(112)／安卓 `WireCodecTest`(5 组，向量扩到 56 条)／`xcodebuild`／`tsc --noEmit`／`svelte-check`／`gradle assembleDebug` 全绿。**真机待验**见「接下来」第 5 条。

  - **2026-08-05：安卓模式1 阅读界面改成「一个工作区」的多标签页界面**（用户需求「可以多tab 打开工作区的多个pdf，也可以快捷切换多个工作区」，方案与实证见 `ANDROID-STANDALONE-PLAN.md §13`）。两条拍板：**标签页属于工作区**（切工作区整组换、切回来原样恢复，不做跨工作区混排——那要同时挂多份库连接，与 §9.2 单写者顶着来）；**切工作区的入口＝标签页栏最左的工作区芯片**（列最近 + 扫描到的，末项「打开其它 .unrd…」跳启动页）。架构：一个工作区一份 `LibraryStore`+`StoreQueue`（全部标签页共用，作业闭包各自认准自己的 `docId`）／标签页**懒装载**、LRU 只保活 3 篇、背景标签页丢页图位图 + Pdfium 缓存从堆 1/3 缩到 32MB（不缩就是三份各占 1/3 = 必然 OOM）／打开分两跳（库队列读文档行与笔迹 → 主线程 → `Bg` 开 Pdfium，不让读页尺寸表堵住别人的落笔）／标签页组存 `SharedPreferences`（按工作区路径分键，只存开着哪几篇，进度仍在库里）／`REORDER_TO_FRONT|SINGLE_TOP` 保证从书库再点一篇是回到**同一个实例**加标签页。模拟器整链路跑过（开/切/关、切工作区来回、LRU 卸载与重装、两个标签页各写一笔各归其档、冷启恢复、栈里只有一个 ReaderActivity、无崩溃），**观感/手感/慢卷耗时/内存待真机**（§11.1 新增 41~44 条）。
  - **2026-08-05：关掉工作区 = 当场放掉全部文件引用**（用户报：工作区在移动硬盘上，关窗后 Finder 仍说「磁盘正在使用中」，必须退出整个 app 才能弹）。根因是整条链路都在等 ARC：库连接的 fd、阅读区 PDF、OCR 渲染副本的强引用全在 SwiftUI 的 `@State`/`@StateObject` 里（关窗后何时释放没有保证），外加 `AppModel.padRenderPDF` 是 App 级单例持有的第三份 PDF、压根不随窗口走。改成三处显式 teardown（`DocSession` / `WorkspaceManager` / `AppModel`），**关库时机由 `willClose` 与 `onDisappear` 两个触发点合判**（两者先后无保证，早关一步就是静默丢进度）。方案与红线见 `REQUIREMENTS.md §8.1`「关掉工作区 = 当场放掉它的所有文件引用」。编译通过，**待用户在真移动硬盘上验证**（见「接下来」第 7 条）。

  - **2026-08-07：草稿纸落地（Mac + 网页平板，安卓未做）**——盖在 PDF 之上的无限白板覆盖层，不改 PDF 原文。
    规格见 `REQUIREMENTS.md §1.8`，线格式见 `PROTOCOL.md §4.4`。要点：
    - **schema v8**：新表 `scratch_pad`（挂逻辑文档，锚点＝页 + 页内归一化点）；纸上的笔迹**不另建表**，
      仍走 `note` 但 `kind=4`、`page` 恒 0、payload 带 `padId`，于是 `ContentView` 的增量对账/级联删除/
      `mergeDocument` 迁移全部原样继承（只多了两个 `onChange`）。
    - **🔴 画布坐标系**：单位 = 逻辑点（pt/CSS px/dp），原点 = 创建点，**可负无界**，笔宽与页内同语义。
      这么定是为了三端笔迹渲染器**一份实现两处用**——Mac 把 `inkDrawStroke` 的坐标映射抽成闭包、
      web 把 `buildGeom` 抽成 `buildGeomWith`，页内传「× 页宽」、草稿纸传「(点 − 视口原点) × zoom」。
      橡皮半径按 `eraserRefWidth = 800` 从页宽归一化折成画布点，**三端必须同一个数**。
    - **协议加四条**：`scratchpads`(0x3D,S→C 列表+开着第几张)／`scratchStrokes`(0x3E,S→C 全量镜像，无 page 字段)／
      `scratchOpen`(0x2B,C→S)／`scratchAdd`(0x2C,C→S)。**RT 流一个字节没改**——Mac 是「哪张纸开着」的唯一真源，
      纸开着时 `ink`/`erase` 的坐标就按画布坐标解释，`page` 字段作废。
    - **视口不上线也不落库**：三端各自独立的缩放滚动就靠这一条；打开一律回画布原点（用户要的「从该处显示」）。
    - **软边界**：可视区必须与「内容包围盒 ± 1.5 屏」相交，空白纸只能在原点附近晃（避免滑到无限远找不回来）。
    - 验证：`spike/scratch-store-test.swift`(35)／`wire-codec-test`(67)／`wire-cross-test`(124)／
      `xcodebuild`／`tsc --noEmit`／`vite build` 全绿。**待真机验证**见「接下来」第 8 条。
    - **2026-08-07 用户报的两处当场修掉**：① 网页端**入口整个看不见**——PadBar 曾是全项目唯一带
      组件内 `<style>` 的 Svelte 组件，而 Svelte 5 对带 `class:` 指令的元素会漏掉作用域类
      （生成 `#padOpenBtn.svelte-xxxx{}` 规则，元素上却没那个类）→ 样式整块失效、按钮退回
      `position:static` 被 z-index 1~7 的 canvas 盖死。**样式已全部挪回 `web/src/app.css`**
      （与其余组件一致），入口也从「右上角浮动按钮」改到**顶栏**（用户就是在顶栏找的）。
      🔴 教训：`web/src/*.svelte` 一律不写 `<style>` 块，样式统一进 `app.css`。
      ② 网页端**没有草稿纸图钉**——只在 Mac 端画了。现已补上（`render.ts drawPadPins`，与文字笔记
      标记同 hover 层；圆角方片 + 两道字迹，与笔记的圆形蓝底一眼分得清），**手指单击**图钉即打开
      那张纸（只认手指不认笔——笔是用来写字的，让笔点图钉必然会在图钉上落笔时误触发）。
    - **2026-08-07 macOS 端 UI 二轮（用户报「很生硬」）**：首版是一条 `.bar` 全宽横杠把阅读区一刀切开、
      一块纯白无参照的画布、直角深色 minimap、开关硬切、无光标反馈。改动：
      ① **工具条改悬浮胶囊**，与 `PenRackView`/`findBanner` 完全同一套（`.regularMaterial in Capsule()`
      \+ 0.5 描边 + `shadow(6,2)`）——它现在读起来是「浮在纸上的控件」而不是「劈开界面的梁」；
      缩放读数只在非 100% 时出现（常驻一个 100% 是纯噪音）。
      ② **加淡点阵 + 原点十字**（`ScratchGridLayer`）：纯白纸平移时看不出自己在动、缩放时看不出缩了多少，
      这是「生硬」的另一半。点阵屏幕间距按 2 的幂自适应到 [22,88]px，任何缩放级别密度都差不多；
      透明度 0.10，纸仍是白底。墨色由**纸色明度**推（不能用 `Color.primary`——它跟系统深浅走，
      深色外观 + 白纸时网格会整个消失）。用方点不用圆点：这层每帧平移都重画，大屏一屏上万个点。
      ③ **minimap** 改圆角 + material + 内边距 9pt + 圆角裁剪（原来内容与视口框直抵边框，像被裁掉），
      视口框改淡填充 + 细描边（原来 1.5pt 实线比笔迹还抢戏），且**空纸时不显示**。
      ④ 开/关加 0.16s 淡入淡出（动画只作用在覆盖层，不渗进 `contentBody` 的零闪烁纪律）。
      ⑤ **光标反馈**：`.grabIdle/.grabActive` 平移、`.rectSelection`（macOS 上即十字）落墨。
      注：`PointerStyle` 没有 `.crosshair`。
      ⑥ 空白纸给一行极淡引导（有笔迹即消失）。
      三个画布层拆到 `Sources/Views/ScratchCanvasLayers.swift`（纯绘制、不碰 AppModel/DocSession），
      于是 **`spike/scratch-look.swift` 能只编这几个文件用 ImageRenderer 出样张**——自绘图形交付前
      逐张看过再说（minimap 贴边、视口框过重两处就是这么看出来的，靠脑补看不出来）。
    - **2026-08-07 UI 三轮（用户报两处看不清）**：
      ① **胶囊里的非激活按钮几乎看不见**——`.buttonStyle(.borderless)` 在 material 底上把图标画得极淡，
      截图里只有显式染了强调色的 minimap 那枚看得见。改成 `.plain` + 显式 `.primary` + 24×24 命中区
      （禁用态交给系统压暗）。**`spike/scratch-look.swift` 已补上胶囊的浅/深两张对比度样张**——
      对比度看代码看不出来，只能出图；改了 toolbar 的按钮样式要同步改那份复刻。
      ② **app 自己的工具栏在草稿纸打开后看不清**——根因不在工具栏：macOS 26 工具栏是玻璃的、
      图标颜色跟外观走（深色外观＝白图标），而草稿纸是**白纸**且一路铺到工具栏底下 → 白图标压白纸。
      修法：草稿纸在 `topInset` 那条带子后面铺回**阅读区自己的 `voidColor`**，工具栏拿回平时的背景。
      🔴 这条依赖 `indicatorTopInset`（= `geo.safeAreaInsets.top`）确实非 0；若真机上工具栏仍发白，
      说明该值是 0，得改用别的方式拿工具栏高度。
      ③ **缩放读数仍然很浅**（同一轮又报一次）：它当时还留着 `.secondary`。已同为 `.primary`。
      🔴 真正的教训在这儿：**样张的复刻里当时压根没画这个读数**，所以上一轮「逐张看过」也看不出来。
      `spike/scratch-look.swift` 的 `capsuleMock` 与 `ScratchPadView.toolbar` **必须逐件对齐**，
      少复刻一件，那件就是下一个漏网的。

## 🔧 整体优化路线图（2026-07-25 起，用户需求「整体优化」）

四项大改，分里程碑推进。用户已定：UDP=整条实时流走 UDP（原生客户端自管序号/丢弃/轻量重传，控制握手仍走可靠通道，浏览器用不了 UDP 永远走 WS）；安卓 = 工作区内 `android/` 子目录独立 git 仓库。

- ✅ ① 通信协议改二进制 / ✅ ② 加 UDP 传输——已完成，见 `HISTORY.md`。
- 🧊 **⑤ 笔迹算法三端统一（Rust 核心）——2026-07-30 用户拍板：搁置**（「收益好像也不是很大」）。方案文档 `INK-CORE-UNIFY-PLAN.md` 保留作存档，不实施；两个卡口问题（笔宽缩放语义 / 要不要引入 Rust）随之作废，将来重提再议。**连带口径变更：三端笔迹观感的分叉从此各端各修，不再等「统一后一并解决」**——安卓 §9.4 的 marker 混合模式就按本地修法处理（`BlendMode.MULTIPLY`），马克笔叠笔接缝、pad 铅笔抖动纹理这类也一样，谁碍眼修谁。下面是搁置前的方案摘要，仅供将来重启时参考：起因：marker 混合模式 bug 暴露 macOS/Web/Android 笔迹渲染是各自独立实现而非同一算法移植（pencil 抖动纹理/fountain 起收锥度/ballpoint 半透明接缝黑点瑕疵，Web/Android 均缺或未修，见该文档 §1 逐项证据）。方向：Rust 核心只产出平台无关绘制图元（变宽描边转**闭合轮廓**、三端 nonzero 一次 fill），三端原生 2D API 仍各自负责上色/合成，不引入 Skia、不碰阅读区纯 SwiftUI 红线、不改线格式。**2026-07-30 二轮审核已修订该文档**：一轮"输出三角网格 + `lyon`"的选型与三端 `fill(Path)` 自相矛盾，已改为 stroke→outline（候选 `kurbo`，待 spike）；补了三端已分叉的 alpha/起笔/**笔宽是否随缩放**语义决策、输出坐标空间与缓存策略、`android/` 独立仓库的依赖形态、测试验收（golden 无法逐点比对）、以及不引入 Rust 的两个更轻替代方案对照。**待用户拍板：① 笔宽缩放语义（第一个卡口）② 是否引入 Rust 这一中间语言 / 何时开工。**
- 🚧 **③ 安卓模式1 独立版**：**设计方案已出 → `ANDROID-STANDALONE-PLAN.md`**（2026-07-29）。用户已定三条：全盘文件权限直开工作区文件夹 / 与模式2 同一个 App（启动二选一）/ 首版范围＝阅读+手写。技术选型：PdfiumAndroid 渲染、裸 `SQLiteDatabase`（不用 Room，schema 是 Mac 定的跨平台契约）、Compose 外壳 + 自定义 View 画布。核心设计＝把「页图哪来」「笔迹提交给谁」抽成两个注入口（`PageImageSource`/`InkBackend`），两模式共用全部几何/输入/渲染/笔迹算法。**最大风险：页面尺寸 box 口径两端必须一致（CropBox 有效则 CropBox，否则 MediaBox），不然笔迹整体漂移**，见该文档 §9.1。**2026-07-30 进度：M0~M6 已落地**（骨架/数据层/阅读/手写/擦除/多图层/笔架与图层面板/框选移动/尺子/文字注解 CRUD/已有高亮与选区注解铺色/长按环形选笔盘本地判定；M7 也做掉了三件不依赖设备的：阅读顶栏补夜间/页图/锁缩放、工具状态持久化（`ToolPrefs`：笔宽/当前笔/橡皮/夜间，模式1 没有 Mac 推笔架，不存就每次回到内置四支）、WAL 建不起来时的降级与文案）。**§9.5 的残留也清了（2026-07-30）**：新增 `StoreQueue`——单线程 executor 独占 `LibraryStore`，落笔/擦除/框选/注解/图层/进度七处写库连同它们后面的重读全部离开主线程，主线程只 `submit` 参数、拿回快照刷界面；关库排在队尾，退出前提交的写一定先落盘。改的过程中**修掉两个丢数据 BUG**：① 擦除对齐改成「头一段沿用原 id」，否则回推没到就再擦一次会把整页笔迹删光（旧实现实测 3 段变 0 段）；② 擦除对齐会把**隐藏图层**的笔迹当成「被擦光了」全删掉（藏一层再随便擦一下那层就没了，界面上看不出来）。**UI 现代化（2026-07-30 用户提「UI 太 demo 了」）**：从无到有建 `res/`（深浅两套语义色板 + 主题 + 28 个手写 VectorDrawable 图标）、`shared/Ui.kt` 设计系统（扁平/原生/颜色只走语义名三条硬规矩）、`shared/TopBar.kt` **两模式共用顶栏**（全图标单行 + 系统 PopupMenu 溢出菜单 + 窄屏自动把键收进 ⋯，触摸目标不缩）、启动页与书库重做、画布底色跟随主题；**十处弹窗全部换成 `shared/Sheet.kt`**（笔/橡皮、图层、文字笔记、跳页、文档下拉、连接 Mac、目录浏览器、正在打开、两处提示——第一轮只改了界面外壳，弹窗还是框架默认样式）。方案 §4 的「Compose 做外壳」口径同时改成经典 View（一路没引，零 compose 依赖）。详见该文档 §9.6。**找工作区三件（2026-08-03 用户提，见 §9.8）**：新增 `local/StorageScan.kt`——① **外部存储**：目录浏览器第一层改成**存储卷列表**（内部存储/SD 卡/OTG U 盘），卷路径四条来源合并去重（`StorageManager`／`getExternalFilesDirs` 剥 `Android/` 上一级／`Environment`／直接列 `/storage`+`/mnt/media_rw`），哪条在哪个 ROM 失灵事先猜不到所以全都试；② **只认 `.unrd`**：删掉「选当前目录」，普通文件夹只能点进去，`.unrd` 行尾给「打开」；站在一个自己有 `library.sqlite` 但没 `.unrd` 后缀的文件夹里会当场提示改名；③ **扫描**：拿到权限且没扫过就自动扫一遍全部卷（不弹窗，结果进卡片），另有「重新扫描存储」实时弹层（边扫边冒结果、关窗即停）与浏览器里的「在这里扫描」；广度优先、深度 6 层/45s/2 万目录三重上限，**没走完一律把原因显示出来**。**用户设备不在手上，真机验证统一延后——待验项一律攒在该文档 §11.1（现 30 条，新增 SD/U 盘枚举、大盘扫描时限、扫描中途停止三条），别当已验收；§11.2 写了模拟器能证明什么、不能证明什么（新增一条：像素值与布局 bounds 是能证明的，「好不好看」不是）。**
- 🧪 **④ 安卓模式2 输入板**：demo（`ANDROID-MODE2-PLAN.md`）已真机验收通过；**2026-07-29 补齐到与网页采集页对齐，待用户真机验证**——新增 probe 流(0x44)/环形选笔盘(0x37)/长按进度环(0x38)/padGeom(0x45)/框选移动(mode=3+0x47)/多图层(0x3A+0x26~0x28)/文字笔记(0x39+0x24)/橡皮双向同步(0x46，含局部擦除 splitStroke)/penset(0x25)/docs+selectDoc/gotoPage(0x29)/latency(0x12)/尺子模式(ink begin line 标记)；修 marker 逐段画成圆斑串、fountain 系数 1.15→1.3（一直画细）、滚动每帧无脑 setText、MacClient 三组状态跨线程；加 WS 自动重连+心跳看门狗、夜间/页图显隐/锁缩放/沉浸全屏/顶栏收起/侧键。字节向量单测扩到全部 51 条（含 radial/notes/layers/eraser/lasso/probe），编译+测试全绿。**未提交，等验收。**

## ⏭️ 接下来（建议顺序）

1. **真平板方案 B 打磨**：缓冲本地滚动 + progressive 多清晰度（PadRenderer/SimPad 已删，真平板链路已通，剩画质/带宽优化）。
2. **笔&笔架&笔迹四项真机回归**（2026-07-26 已落地，见 HISTORY）：尺子吸附手感 / 局部擦除两端一致 / 本机落墨（含 ⇧ 尺子）/ 框选移动（含重开文档位置保持、平板镜像）——手测发现问题即在此开新条目。
3. **安卓输入板补全真机验证**（2026-07-29，见路线图 ④）：重点验环形选笔盘（长按呼出/扇区高亮/取消区手感——这条链路此前平板端完全缺失）、框选移动、多图层、局部擦除与 Mac 是否一致、marker 荧光笔观感、断线自动重连。
4. **web 端框选移动真机验证**（2026-07-27 已落地，见上）：PageUp 切到「框选」模式后拖框选中 / 拖高亮框内移动 / 单击清选中 / Esc 清选中；跨图层命中是否符合预期（当前不按图层过滤，同 Mac 端 `finishLassoSelect` 对文字注解不分图层一致，但笔迹命中理应只认可见图层——若真机发现隐藏图层的笔迹被误选中，check `AppModel.applyLassoMove` 的 `vis.contains` 过滤是否与预期一致）。
5. **平板「开文档 + 目录跳转」真机验证**（2026-08-05 落地，见上）：① 抽屉「书库」点一个 Mac 没开的文档 → Mac 是否**新开窗口**装它、平板是否自动跟过去；点已打开的是否只是切过去而不是又开一个窗；② 目录树的折叠/当前章节高亮与自动定位；③ 点目录条目后落点是否在章节标题那一行（而不是页顶）——这条要拿**章节从页中部起**的书试才看得出来；④ 坏书签行是否灰掉且点不动；⑤ 多工作区并存时，平板列的是不是**它当前跟随的那个窗口**所属工作区的书库（切窗口/切工作区后要跟着换）；⑥ 安卓端返回键是先关抽屉。

6. **安卓模式1 多标签页真机验证**（2026-08-05 落地，见上；清单在 `ANDROID-STANDALONE-PLAN.md §11.1` 第 41~44 条）：① 两条栏叠起来会不会太吃阅读区、34dp 的 × 会不会误触（想切标签结果关掉了）；② 慢卷上切标签页的快慢——保活着的应当瞬间，被 LRU 卸过的要重开 Pdfium，那一下有多长决定 `MAX_LIVE` 要不要调大；③ 开满 8 个（含几百页的大书）来回切的内存与卡顿；④ 用工作区芯片在两个慢卷工作区之间来回切，进度与标签页组是否都在原处。

7. **移动硬盘弹出验证**（2026-08-05 落地，见上）：工作区放在移动硬盘上 → 打开、翻几页、写几笔 → **只关窗口不退出 app** → Finder 弹出该盘应当立刻成功。反例排查（先 `touch ~/Library/Logs/UniReader-ws.log` 开日志，再看有没有 `⚠️ PDFDocument 仍存活` / `⚠️ manager 仍存活`）：
   ```
   lsof -p $(pgrep -x UniReader) | grep /Volumes/<盘名>     # 关窗后应当一条都没有
   ```
   要一并确认**没有丢进度**：重新打开该工作区，页码/缩放/横向位置、笔迹、注解、高亮都应在原处（关库时机若抢在最后一次写库之前，表现就是「进度回退一点点」这种不易察觉的静默丢失）。另需覆盖：① 同一工作区开两个窗口，关掉其中一个后另一个仍能正常读写；② 关光全部窗口后再打开同一个工作区，笔记完好（走的是新建实例这条路）。

8. **草稿纸真机验证**（2026-08-07 落地，见上）：
   - **Mac**：阅读区右键「在此新建草稿纸」→ 纸是否从创建处（画布原点居中）打开；拖动平移 / 捏合与 ⌘滚轮
     缩放的手感；笔架切到「本机落墨」后笔迹是否**只落在纸上、PDF 上一点没有**；橡皮圆环大小是否合理
     （`eraserRefWidth=800` 这个基准是拍的，手感不对就调它，但**三端要一起改**）；「回中」「适应内容」
     是否如预期；minimap 点/拖定位准不准；Esc 关纸；双击标题改名；页面图钉与 Inspector 列表能否打开/删除。
   - **平板（网页采集页）**：Mac 开纸后平板是否自动跟着切进同一张、笔迹双向同步；平板顶栏草稿纸按钮的
     列表/新建；平板上单指平移、双指缩放、minimap 是否**与 Mac 各自独立**（这是这个功能的设计前提）；
     尺子模式在纸上画直线（这条走的是 `line` 标记的替换终点语义，最容易出「歪线」）。
   - **边界**：一篇文档开多张纸来回切、关掉文档再打开笔迹还在、删纸后纸上笔迹是否一并从库里清掉、
     多窗口各开一张纸时滚轮不串窗口。
   - **未做**：安卓两模式（模式1 独立版 / 模式2 输入板）都还没有草稿纸，下一轮再补。

## 🐞 已知 Bug（待修）

- **一个工作区里只有第一篇文档能有默认图层**（2026-08-05 做安卓多标签页时撞见，**Mac 与安卓同病，未修**）：`ink_layer.id` 是全局主键而默认图层用固定 UUID，`ensureDefaultLayer` 的 `ON CONFLICT(id) DO UPDATE` **不更新 `document_id`** → 第二篇起插不进自己的行，图层面板是空的、笔迹的 `layerId` 指向别人家那一行。当前不丢数据（可见性过滤按 `document_id` 取，取不到＝全可见），但按 id 做重命名/删除/改色时会跨文档互相影响。**默认图层 id 的语义是三端契约，要两端一起改**：① 默认层也用随机 UUID，没有 `layerId` 的老笔迹兜底到该文档第一层；② 主键改 `(id, document_id)`（要迁移）。证据与实证见 `ANDROID-STANDALONE-PLAN.md §9.11`。
- 笔迹打磨（已知简化，非阻塞）：马克笔叠笔接缝变深；pad 实时反馈阶段铅笔无抖动纹理。**原计划靠路线图 ⑤ 三端算法统一一并解决，该路线 2026-07-30 已搁置** → 现在是「各端各修、谁碍眼修谁」，两条都还没修。
- ~~安卓 marker 观感偏暗发浊~~ **2026-07-30 已修**（`ANDROID-STANDALONE-PLAN.md §9.4`，两模式共用 `shared/InkRenderer.kt`）：`PorterDuffXfermode(MULTIPLY)`（预乘 alpha 的老式合成）换成 API 29+ 的 `BlendMode.MULTIPLY`，26~28 保留兜底。模拟器用 `screencap` 逐像素对过公式：白底量到 (255,239,169)、压在蓝笔上量到 (36,92,141)，与 W3C multiply 逐位相符。**并排观感仍待真机**（§11.1 第 4 条）。

## 📋 Backlog（M3 及之后）

- **🚀 大分支：Android Pad 版本**（2026-07-22 提出；**2026-07-26 用户：暂缓，优先级下调**）：不再是「Mac 端投屏给 pad 采集页 HTML」的方案 B 模式，而是直接做一个 Android 原生/独立 App，能在平板上打开工作区项目（读同一份跨平台 SQLite `library.sqlite` + 文档 + 笔迹）。呼应此前存储选型就是为跨平台（Windows/Android）预留的决定。范围大，需要单独立项拆解，不塞进当前 M3 迭代。（路线图 ③ 即此。）
- **三种笔记形态**：文字注解、手写笔记、高亮均已落地（见 HISTORY）；**会话笔记（kind=1，预留 AI）** 用户 2026-07-21 明确暂不做（消息流 UI + 锚定 + AI 接口整套未起）。
- **文件重定位**：所有路径失效时提示重新关联（`missingDoc` + Re-link 已在）；hash 命中加路径 / 未命中作同文档新版本、笔记挂文档不丢（`relocate` 已较健壮）。
- **配对/安全**：连接管理已在（`ServerPanel` 逐个断开）；二维码 UI 打磨仍可做。
- **T1/T2 遗留**：旋转页坐标未用真实旋转 PDF 验证；超大文档搜索可换 PDFKit 渐进式 API；拖到页边缘不自动滚动（非阻塞）。
- **T3 OCR 遗留**：整文件一次上传快路；跨「OCR 页↔原生页」混合边界拖选；搜索只覆盖已识别页；网络任务无取消；Vision 离线 OCR 未接。
- **打包**：非沙盒 + 公证发布流程。
