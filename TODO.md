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

  - **2026-08-17：框选三增强，三端落地**（自由框选 + 选中笔迹光晕 + 手柄缩放）：① 矩形框选改为**自由路径框选**（路径抽稀 → 页内归一化不规则多边形，`pointInPolygon` 射线法命中，边界算内、凹形凹槽不算；**Mac `InkEdit` / web `render.ts` / 安卓 `shared/InkEdit.kt` 同一算法三份实现，改它必须三端同步**；跨页点 clamp 到锚点页边缘的「仅页内」语义不变）；② 选中笔迹画半透明蓝**光晕边缘**（线宽=笔宽+5 同尺度，所见即所选；注解仍由高亮框覆盖）；③ 高亮框加 **8 缩放手柄**（四角 = **等比**（Mac 上 ⇧ 临时自由两轴）、四边中点 = **单轴**，anchor = 对侧手柄，clamp 0.05...20），松手一次性提交：点集绕 anchor 按轴缩放 + clamp 0...1、**线宽 ×√(sx·sy)** clamp 0.5...40、注解 anchor/rects 同缩放（字号不变）。**协议扩两条**（`PROTOCOL.md`）：`lassoMove` 加尾部可选多边形（u16 n + n×f32 点对，缺省 = 矩形命中兼容老客户端）、新增 `lassoScale`(0x4A, C→S)——均沿用「客户端乐观预览 + Mac 真源复判 + 广播镜像」惯例（`AppModel.lassoApply` 共用命中：多边形优先/矩形兜底）。Mac 端 `ReaderSurface+Lasso` 重写（手势三形态：手柄→缩放/框内→移动/空白→自由框选）；web 端 `lassoCurBox`→`lassoPath`；安卓两模式共用 `shared/PageCanvasView.kt`（模式2 上行带 poly，模式1 本地多边形复判 + `InkEdit.scaled` 落库）。验证：`ink-edit-test`(62)／`wire-codec-test`(83)／`wire-cross-test`(156)／安卓单测（WireCodecTest 5 组 78 向量、InkEditTest 14）／`xcodebuild`／`tsc --noEmit`／`vite build`／`assembleDebug` 全绿。**2026-08-18 真机修掉两个 bug**：① web 框选后虚线路径残留（`finishLasso` 先清手势瞬态再重绘）；② web+模式2 提交后笔迹闪烁——Mac 的 strokes/notes 是**两条独立镜像广播**，客户端收到任意一条就清全部乐观预览导致另一层跳回再跳来，改为**分层记账**（`lassoSyncStrokes/lassoSyncNotes`，哪条到了哪层画真源、两条到齐才清选中；安卓以 `lassoMirrorSplit` 开关只开模式2）+ Mac `lassoApply` **零命中也回传**未变镜像（不再靠 1s 超时弹回）。安卓仓库已提交（`413aba0`）。
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
    - **2026-08-07 纸样（schema v9，Mac + 网页）**：用户要「几个模板」——底纹（纯色 / 点阵 / 小格）
      × 纸色（纸白/米白/浅灰/牛皮/护眼绿/淡蓝）两个维度，两端都能改、跨端同步。
      · `scratch_pad` 加 `pattern` 列（v8→v9 补列，老纸兜底 `dots` = 与 v8 观感一致）；
      `bg` 仍是**自由 CSS rgba 串**，色板只是各端 UI 的备选项，加减颜色不影响任何一端解码。
      · 协议：`scratchpads`(0x3D) 每项尾部加 `u8 pattern`；新增 `scratchPaper`(0x2D, C→S) 改纸样。
      · **网页端此前根本没画底纹**（Mac 才有），这轮一并补齐——`scratch.ts drawPattern` 与
      Mac `ScratchGridLayer` 是同一套数：步长从 24 起按 2 的幂折到屏幕 [22,88]px、墨色由**纸色明度**
      推（不跟系统外观走）、方点不用圆点。这三条改一边必须同步另一边，否则同一张纸两端长得不一样。
      · 样张已扩到 3 底纹 × 3 纸色 + 选择器小样。**顺带靠样张抓到一处**：小样那张图第一次看像是
      plain 也画了点阵，实为 HStack 宽度溢出被压缩的假象——加宽后确认正确（别急着改代码）。
      · 验证：`scratch-store-test` 44（含 v8→v9 迁移 + plain 不被默认值吃掉）／`wire-codec-test` 69／
      `wire-cross-test` 128／`store-test` 34／`ink-store-test` 21／`ocr-store-test` 15／
      `xcodebuild`／`tsc`／`vite build` 全绿。
      🔴 **PROTOCOL.md §4.1 的三条草稿纸 C→S 行当初是漏的**——首版那次 `s.replace` 没加断言、
      静默没命中。这轮补齐（scratchOpen/scratchAdd/scratchPaper）。改文档的脚本一律要断言。
  - **2026-08-07：草稿纸安卓两模式落地（按 `SCRATCHPAD-ANDROID-HANDOFF.md` 执行，待真机验证）**：
    - **数据层（模式1）**：`NoteKind.SCRATCH_INK=4`；`ScratchPad` 模型；`LibraryStore` 加 `scratch_pad`
      读写（`PRAGMA table_info` 探表、v7 无表当空、v8 无 `pattern` 列兜底 dots + 降级 upsert、删纸连带删
      kind=4 笔迹、`scratchStrokes` 按 padId 分纸、孤儿行判坏）；`Payloads` 原地加 `padId` 键；
      `Stroke.padId`（空=页内）；🔴 `InkEdit.splitStroke` 抽成纯函数且切段**继承 id/layerId/padId**
      （不继承会被擦笔迹当场消失并污染页内）。测试：`InkEditTest` 7/7（+4）、新建 androidTest
      `ScratchPadStoreTest`（8 用例，无设备只过了编译）。
    - **协议（模式2）**：`WireCodec.kt` 加五条消息（scratchpads/scratchStrokes/scratchOpen/scratchAdd/
      scratchPaper），与 Swift/JS 字节级一致；`WireCodecTest` 向量补到 64 条（#57~#64，含 `open=-1`↔0xFFFF
      与 `pattern=plain`=0 两个易被兜底吃掉的值），`wire-cross-test` 128 通过。
    - **渲染+画布**：`InkRenderer.build` 泛化为「点→像素映射 + 线宽倍率」（页内走 `buildPage` 行为不变）；
      新建 `shared/ScratchGeom.kt`（纯几何：底纹契约数/CSS rgba 解析/软边界 ±1.5 屏/回中/适应内容，
      `ScratchGeomTest` 12/12）+ `shared/ScratchCanvas.kt`（两模式共用无限画布：方点底纹、原点十字、
      单指平移/双指捏合、minimap、橡皮圆环；触点 ÷density 只在 `toCanvas` 一处——dp 坑就守在这里；
      线宽 ×zoom、几何缓存键页宽换 zoom）。**草稿纸层不挂夜间反色滤镜**（独立 View 天然排除）。
    - **模式1**：`local/ScratchController.kt`（StoreQueue 读写 + 乐观落地 + reconcileScratchStrokes）；
      顶栏入口 + Sheet 列表/纸样面板（六色板）+ 悬浮胶囊浮条；图钉画在页面上、**手指单击**开纸（不认笔）；
      覆盖层加在 chrome 之下让开顶栏（§7.1 白压白坑）；返回键先关纸。模拟器冒烟过：读出 Mac 建的纸、
      笔迹位置/粗细一致、点阵像素级核对、改纸样落库确认。
    - **模式2**：`pad/PadScratch.kt`（收 `scratchpads` 照做、换纸 `openSession` 回中、ackRel 判据与页内
      `setStrokes` 一字不差、乐观落地 3s 兜底）；**纸开着时 ink/erase 发画布坐标、page 填 0，编码函数
      一行未动**；不发 probe 不呼环形盘；不写库；图钉手指单击发 `scratchOpen`；`MacClient` 加两条路由。
      🔗 新依赖方向：pad→local 引用了 `ScratchController.PALETTE` 等三个常量（介意可上移到 shared）。
    - **未做/待验**：纸上「笔当橡皮」（侧键/橡皮头）与环形盘不做（同 web 决策）；真机联调清单见
      「接下来」第 8 条。
    - **2026-08-07：圆盘加「新建草稿纸/新建文字笔记」扇区 + 图钉页内拖动（三端，待真机验证）**：
      · **协议扩展（只追加）**：`radial`(0x37) kind 表加 `3=scratchAdd 4=textNote`；新 opcode
        `scratchMove`(0x2E, C→S：`u16 index·f32 nx·f32 ny`，图钉同页内挪锚点，回推为权威）与
        `noteNew`(0x3F, S→C：`u32 page·f32 nx·f32 ny`，叫平板在该点开笔记编辑器，保存走现有
        textNote 上行闭环）。向量 #65~#69，`wire-codec-test` 74 / `wire-cross-test` 138 全绿。
      · **Mac**：`RadialItem` 加两 case（扇区顺序：笔…/橡皮/翻页/新建草稿纸/新建笔记）；commit
        建纸走右键菜单同路径、textNote 广播 noteNew；`applyScratchMove` 钳位 0~1、越界丢弃。
        Mac 本机图钉 UI 拖动没做（用户没要求）。
      · **安卓两模式**：模式1 `RadialController` 加两扇区（建纸锚点=盘心 / 该点开编辑器）；
        模式2 只画新扇区（判定在 Mac），noteNew 先 `scrollToPageFrac` 本地定位（不发 gotoPage
        抢 Mac 视口）再开编辑器。**图钉拖动**：基类 `PageCanvasView` 加手指拖动钩子（越过平移
        死区才转拖动、单击开纸不变、只认手指），模式1 松手落库、模式2 发 scratchMove 乐观预览。
      · **web**：新扇区绘制 + noteNew 开编辑器 + 图钉拖动（pinGhost 乐观，回推对齐）。
      · 真机待验：新扇区图标/高亮观感、拖图钉松手后回推不跳位、textNote 扇区提交后平板弹编辑器。
    - **2026-08-13：页面底图（v10）+ 客户端删除/改名（四端全做，待真机验证）**——用户两条需求：
      「所在 pdf 页面显示在草稿纸上面（可以切换显示）」「客户端现在可以管理（删除）草稿纸吗，没有需要加上」。
      · **schema v10**：`scratch_pad` 加 `show_page` 列。**新建的纸默认开、v9 老纸补列即关**
        （不惊扰既有白纸）。安卓不建表不迁移 → v9 老库照旧探列降级（写不进去，读回兜底关）。
      · **🔴 页面底图几何是三端契约**（`PROTOCOL.md §4.4`）：页宽恒 **800 画布点**
        （`ScratchPad.pageRefWidth` / `PAD_PAGE_REF_W` / `ScratchGeom.PAGE_REF_W`，**三端同一个数**），
        高 = 800 × 页纵横比（显示尺寸口径：CropBox 优先 + rotation），**锚点落在画布原点**
        → 「打开 = 回原点」正好摆出当初创建它的那一处。对不上的表现是「同一张纸，Mac 上写在公式旁边、
        平板上写到了页边空白处」。层序：纸色 → 底纹 → 页图 → 笔迹；页图**不反色**；
        开着时页矩形**计入内容包围盒**（软边界/适应内容/minimap），否则空纸垫了页也走不到页边。
      · **协议加三条**（只追加）：`scratchPageShow`(0x2F)、`scratchDelete`(0x48)、`scratchRename`(0x49)，
        `scratchpads`(0x3D) 每项尾部加 `u8 showPage`。向量 #70~#75（含 show=0 与空标题两个易被兜底吃掉的值）。
      · **页图从哪来**：Mac 走阅读区同一个 `PageRenderEngine`（同 docKey 键空间、`night:false`、
        像素宽按缩放折档）；web 复用 `G.imgs` + `/page.png`；安卓两模式复用各自的 `PageImageSource`
        （模式1 Pdfium / 模式2 PageFetcher）且档位走共用的 `PageWidths.snap`——另立档位 = 每张纸重渲一份大图。
      · **管理**：网页在草稿纸列表里逐行改名/删除（删除两步确认）；安卓模式2 在纸样面板补「管理」组
        （与模式1 一字排开）；Mac/模式1 本来就有。客户端一律只发请求，回推为权威。
      · 验证：`wire-codec-test` 80 / `wire-cross-test` 150 / 安卓 `WireCodecTest`(75 向量)+`ScratchGeomTest` 14 /
        `scratch-store-test` 53（含**真·v9 形状**老库迁移）/ `xcodebuild` / `tsc` / `vite build` /
        `gradle assembleDebug + test + assembleDebugAndroidTest` 全绿。样张 `spike/scratch-look.swift`
        新增 `page-*`/`minimap-page`（页边描边、占位白、层序都靠它看出来）。
    - **2026-08-07 点阵强化**（用户报「太小了基本看不出来」）：点从 `max(.8, min(1.6, z))` / 0.10
      放到 `max(1.5, min(3, z*1.8))` / 0.18。间距本来就有 22~88px，点再细就没了。
      **Mac `ScratchGridLayer` 与 web `scratch.ts drawPattern` 是同一套数，改一边必须同步另一边。**

  - **2026-08-25：AI 面板 S1 落地（macOS，仅 Mac 端）**——**不接 API key**，内嵌 webview 直接用各家 AI
    网页版。完整方案（S1~S6、存储契约、红线）见 **`AI-PLAN.md`**（权威），本条只留交接要点：
    - **全原生**：macOS 26 的 WebKit for SwiftUI（`WebView` + `WebPage`），**没有 NSViewRepresentable 包
      `WKWebView`**。`Configuration.userContentController`／`urlSchemeHandlers`／`customUserAgent`／
      `callJavaScript(…contentWorld:)` 都是公开 API（已核 SDK swiftinterface），S3 的注入适配器够用。
      ⚠️ 但 `.webViewContextMenu` 的 `ActivatedElementInfo` **只有 `linkURL`，拿不到选中文字** ——
      S5 的「右键加到笔记」必须靠注入脚本回传选区。
    - **形态 = 全局唯一浮窗**（`Window` scene，⌘⇧A / 菜单栏「AI」），每家平台一个 `WebPage`、
      共享 `WKWebsiteDataStore.default()`；`maxLive=3` LRU，关窗只留当前那家。
      不是每个阅读窗口一个 —— 那会撞上「一个 WKWebView 不能同时挂两个视图」。
    - **存储（S2 用，尚未写）**：会话绑定**复用 `note` 表 kind=1**（`REQUIREMENTS.md §1.2` 早就预留的
      「会话笔记」），payload 存 `{provider,url,title,state,contexts[]}`，`contexts[0]` 的页与归一化矩形
      写进 note 的 page/anchor 列。**零 schema 迁移**，级联删除/`mergeDocument` 迁移/跨端读取全部原样继承
      （同草稿纸笔迹复用 kind=4 的先例）。
    - 新增 `Sources/AI/{AIProvider,AIPanelModel}.swift` + `Sources/Views/AIPanelView.swift`，
      `WindowAccessor.swift` 加 `WindowLevelAccessor`（置顶用 AppKit 设 `NSWindow.level`，
      不用 scene 级 `.windowLevel()`——后者对已开着的窗口是否即时生效没把握）。中英双语已补。
      `xcodebuild` 通过，**真机待验见「接下来」第 10 条**。
  - **2026-08-25：内置平台表收窄到只有 DeepSeek**（用户「先只做 deepseek，我目前也只用 deepseek」）。
    其余七家的 home / 会话 URL 形态移到 `AI-PLAN.md §7` 当参考（一条都没实测过，留在代码里会被
    当成「已支持」）；想加就写外部配置。工具栏在**只有一家平台时不摆切换器**。
    另：首版工具栏用户报「太大太高」→ 改用系统的 `.windowToolbarStyle(.unifiedCompact(showsTitle: false))`
    并去掉 `.navigationSubtitle`（副标题把标题区撑成两行，是偏高的主因）。两处都是系统 API。
  - **2026-08-25：AI 面板 S2 落地（会话绑定）**。规格见 `AI-PLAN.md §1/§2/§11.1`，交接要点：
    - **绑定落 `note` 表 kind=1**，零 schema 迁移（`REQUIREMENTS.md §1.2` 早就预留的槽位，
      本次把它的定义从「消息数组」改写成「外链会话 + 上下文列表」）。payload 存
      `{provider,url,title,state,contexts[],last_opened_at}`；**page/anchor 走 note 的列、取
      `contexts[0]`**（用户定的「多张图用第一张」），于是图钉位置与回填锚点都不用另存。
    - 🔴 **面板不碰库**：面板是 App 级、`LibraryStore` 是窗口级且同库只许一个连接（§8.1 红线）。
      面板只发 `AIThreadUpsert`，由 **sessionID + documentId 双对**的窗口认领 → 写
      `session.aiThreads` → 既有增量对账落库。别图省事在面板里直接开库。
    - **两段式绑定**：发起时还没有会话 URL（各家都要发出第一条消息才 `replaceState` 出唯一链接），
      所以先记 pending 上下文，等捕到匹配 `threadPattern` 的 URL 才 commit。
      「新对话」不清 bindContext——还是为那一页服务。
    - `WebPage` 是 Observation 类型，**模型自己订阅不了**：URL/标题/加载状态由 `PageObservers`
      这个 ViewModifier 在视图里读到再转交模型。
    - **又撞一次类型检查器时限**：两条 `onChange` 挂进 `mainSplit` 当场超时 → 照 `scratchRoutes`
      先例抽出 `aiRoutes` 一层。这个坑在本文件里已经是第三次了。
    - 验证：`spike/ai-thread-store-test.swift` **41/41**（round-trip / 第一条决定锚点 / kind 隔离与
      损坏容错 / **会话 URL 正则**四块）+ `xcodebuild`。真机待验见「接下来」第 10 条。
  - **2026-08-25：AI 面板 S3+S4 落地（框选截图 → 自动发过去）**。用户要求「一定要方便」。
    规格见 `AI-PLAN.md §4/§5/§11.2`，交接要点：
    - **⌥ 拖是主入口**（任何工具下按住 ⌥ 拖，松手回原工具），另有常驻工具 `PointerTool.snip`
      （笔架一枚 / ⌥S）。另外三个拖拽手势在 ⌥ 按下时**只让「尚未起手」的那一次**——
      已经在拖的不打断（读 `snipModifierDown` + 各自锚点，等价于不用新状态的闩）。
    - 🔴 **不截屏幕，按页重渲染**：`PageSnip.slices` 折成逐页归一化矩形 → `PageBitmap.renderTile`
      重出图，倍率按目标长边定（1.5~4×）**与当前缩放无关**。缩小状态下直接截屏 = 小字全糊。
      跨页各切一片纵向拼接（中间 8px 浅灰分隔）。夜间反色**天然不进截图**（`renderTile` 不反色，
      反色是 `PageRenderEngine` 之后才加的）。
    - 🔴 **渲染走 `PageRenderEngine.renderOffMain`（新增）那条队列**，不在主线程：阅读区页图渲染
      就在它上面，同一份 `PDFDocument` 不能并发使用。
    - **注入适配器三级回退 + 逐级验证**（`Sources/Resources/ai-adapters.js`）：file input → 合成 drop
      → 合成 paste。**光派发了事件不等于站点收下了** → 每级之后看证据（冒出 blob:/data: 预览，
      或正文里出现我们的文件名——所以文件名取页面上不可能自然出现的串）。三级全哑老实报失败。
    - 🔴 **base64 走 `callJavaScript` 参数传、JS 里手工 atob**，不用 `fetch(dataURL)`（站点 CSP 的
      connect-src 会挡）；脚本注入 **`.page` world**（隔离世界里造的 File/DataTransfer 页面 React 拿不到）。
      适配器可被 `~/Library/Application Support/UniReader/ai-adapters.js` 覆盖，站点改版不用发版。
    - **不自动按发送**：填好图 + 一行上下文（`《书名》· p.12 · 章节`）后聚焦输入框，用户自己发。
    - 又为类型检查器分了一层：`ReaderSurface.body` 拆出 `surfaceBody` + `snipRoutes`。
    - 验证：`spike/page-snip-test.swift` **34/34**（几何）、`spike/ai-adapter-test.html` **13/13**
      （三条链路 + 退级 + 全哑报错，Chromium 实跑）、`xcodebuild`。真机待验见「接下来」第 10 条。
  - **2026-08-26：AI 面板 S5 落地（webview 选区 → 回填文字笔记）**——用户三条核心需求的最后一条。
    规格见 `AI-PLAN.md §6/§11.3`，交接要点：
    - **选区必须靠注入脚本推上来**：`.webViewContextMenu` 的 `ActivatedElementInfo` **只有 linkURL**。
      ⚠️ **messageHandler 的 contentWorld 必须与注入脚本一致**（都 `.page`）——不一致时
      `webkit.messageHandlers.unireader` 是 undefined，而 postMessage 包在 try 里，**不报错、
      只是一声不响什么都收不到**。这是本功能最像「静默失效」的一处。
    - ⚠️ `.webViewContextMenu` **取代**系统默认网页右键菜单 → 剪切/拷贝/粘贴要自己补回来
      （`NSApp.sendAction` 转发响应链）。
    - **锚点 = `boundThread.contexts.first`**（用户定的「多张图用第一张」）；没发过东西就回落到
      发起绑定的页 + 零尺寸锚点（同点注解形态）。
    - `TextNote.source`（provider/url/thread_id/at）**零迁移**：旧 payload 无此键 → nil；
      没有来源时也不写这个键。Inspector 笔记行加 💬 徽标点回出处对话（绑定已解则 `openLoose`
      只开 URL、不重建绑定 —— 否则点一下「看看出处」就凭空多一条会话）。
    - 验证：`spike/ai-thread-store-test.swift` 扩到 **53/53**（新增第 ⑤ 块：source round-trip +
      零迁移 + 「没有来源不写 source 键」）、自检页仍 13/13、`xcodebuild`。真机待验见第 10 条。
  - **2026-08-26：面板快捷键修复**（用户报「⌘C ⌘V 这些基本快捷键还是要有」）。
    🔴 根因：`UniReaderApp` 的 `CommandGroup(replacing: .pasteboard)` 用
    `firstResponder is NSText` 当判据，而面板的第一响应者是 **WKWebView** → 走 else 分支发
    `.readerCopy` 通知 → 那时没有任何 ContentView 是 key 窗口 → **⌘C 一声不响什么都不做**。
    改成**先试响应链、没人接才回落阅读区**（`NSApp.sendAction` 的返回值就是「有没有响应者接住」，
    纯 SwiftUI 的阅读区不在链上必然 false，正好当分流开关）。⌘X/⌘V/Delete 本来就无条件 sendAction。
    另加窗口级 ⌘R / ⌘[ / ⌘] / ⌘G，以及 ⌘F 页内查找（走注入侧 `window.find()`——
    WebKit for SwiftUI 没有 `findNavigator`，`WKWebView.find` 又够不着 `WebPage`）。
    ⌘±/⌘0 刻意不接：捏合缩放已可用，CSS `zoom` 会搞坏聊天站点的固定定位布局。
  - **2026-08-26：AI 面板吸附 + 内置模式**（用户需求）。方案见 `AI-PLAN.md §11.5`，要点：
    - **吸附**（`AIPanelDock`）：用 AppKit **子窗口**（`addChildWindow`）跟随，不用「监听 didMove
      算位移」（快拖必掉队抖动）。**主窗口最大化/全屏时不吸附**（右边没地方）。
      ⚠️ `addChildWindow` 会把子窗口层级拉成与父一致、**抹掉「置顶」**，贴完要补一次 `panel.level`。
      宿主 = 当前 key 的阅读窗口，换窗口跟过去。
    - **内置模式**：面板显示在阅读窗口右侧，收起是右下角气泡。🔴 **与浮窗互斥**——同一个
      `WebPage` 只能被一个 `WebView` 挂着，真源 `AIPanelModel.mode`，浮窗那边在内置时改画占位。
      网页区抽成共用的 `AIWebArea`。
    - 🔴 **内置层挂在 `PageStreamView` 而不是 `ReaderSurface` 里**：阅读区四个拖拽手势挂在
      ScrollView 容器上，用 `.overlay` 加在**同一个视图**上的覆盖层挡不住它们（草稿纸正是为此
      才要在每个 gesture 里写 `openPadID == nil`）。挂到上一层 = 普通遮挡，一行门控都不用加。
      挂在 `.id(docKey)` **之后**，换文档不重建面板。
    - 只在 `app.activeSessionID` 那扇窗口里出现（单值 → 天然只有一个宿主）。
    - 各入口统一走 `AIPanelModel.present(_:)`（内置展开侧栏 / 浮窗开窗口）。
    - toast 让开内置面板宽度，但**刻意不让 ReaderSurface observe AIPanelModel**——订阅 App 级
      `@Published` 会让面板任何变化都重算整个阅读区（`readZoom` 性能红线同款）。
    - 🔴🔴 **2026-08-26 崩四次后定案：弃用 SwiftUI 的 `WebView`/`WebPage`，webview 归我们自己持有**
      （`Sources/AI/AIWebView.swift`：`AIPageBox` 持 `WKWebView` + KVO 镜像状态，
      `AIWebHost` 只是个空容器把它 `addSubview` 进来）。四次全停在
      `_WebKit_SwiftUI.makeViewProvider`——视图一重建，框架就再造一个 WebView 挂同一个 WebPage。
      前四次的修法（按 mode 分支 / token 交接 / 每宿主一份 page / 换「身份稳定」的挂载点）
      **共同错误是试图约束 SwiftUI 的视图生命周期** —— 它有权随时重建任何视图（实测连启动都重建两次）。
      现在重建 = 把同一个 NSView 重新挂一次父，合法幂等，最多闪一下。
      顺带修好：右键菜单改由 `willOpenMenu` **追加**到系统菜单（之前 `.webViewContextMenu` 是**取代**，
      把剪切/拷贝/粘贴/查询/服务全弄没了，是我引入的回退）。
      **规则：往 app 里放任何 AppKit 承载的长驻视图，生命周期都要自己管。**
    - **闪烁**（不崩之后剩的视觉问题）拆两件：① `@State` 缓存页面 → 重建后先渲一帧占位，
      **必然闪** → 改成 body 直接 `existingPage(for:)` 纯查找（创建仍只在 onAppear），
      配 `pagesRevision` 触发刷新；② 重新挂父的重排 → `AIPageBox` 自持常驻容器
      （**webview 的父永不更换**，移动的是容器）+ Auto Layout 钉四边（`autoresizingMask` 会先把
      webview 压成 0×0 再撑开，WebKit 整页重排）。
      ⚠️ `makeNSView` 刻意不直接返回常驻容器（SwiftUI 拆旧 representable 时会摘掉它给出的视图）。
    - 🔴 **「整块变白、按快捷键才回来」**：隔一层外壳还不够——外壳被拆时会把容器一并带走，
      而活着的那个**不会再收到 `updateNSView`**（输入没变），容器再也回不来。
      修法：外壳自己抢，规则是**「谁在窗口里，谁才有资格抢」**（`AIWebShell.claim()`，
      `viewDidMoveToWindow`/`layout` 里做，`window != nil` 才动手）；外加**离场交接**
      （发现自己 `window == nil` 且容器还在自己这儿 → `box.rehome()` 交给还在窗口里的外壳），
      补「被拆的那个在离场前刚好抢走、活着的那个不保证再布局」这个缝。
    - **页面仍按宿主分配**（`AIHost` × 平台，独立于上面的所有权问题）：
      每扇阅读窗口的内置面板、那扇浮窗各一份，登录态共用 dataStore。
    - 🔴 **内置层的挂载点必须是稳定身份**（第三次同一处崩溃：开着 webview 切换书）。
      「每宿主一份页面」只保证**不同宿主**不撞，**挡不住同一宿主的挂载点被重建**——重建时新实例
      拿到的还是同一个 `WebPage`，旧 `WebView` 尚未拆干净。原先挂在 `PageStreamView` 里
      `.id(docKey)` 之后（我以为 `.id` 之后不受影响，**实测会跟着重建**），现移到
      `ContentView.readerColumn` 外层：不在任何 `if` 分支里、不在任何 `.id()` 下游，
      且仍在阅读区手势视图的上一层（挡手势不用加门控）。
      **规则：以后往阅读窗口里加任何长驻的 AppKit 承载视图，挂载点都要先确认身份稳定。**
      排障：同一宿主 0.5s 内重复取页面会往 `UniReader-ws.log` 写警告行。
    - 🔴 **内置模式下每扇阅读窗口都显示自己的聊天**（用户明确要求）。原先门控成
      `activeSessionID == session.id`（只有活跃窗口显示）**是为了规避崩溃临时加的限制、不是设计**，
      页面按宿主分配后早该拆掉。展开/收起按窗口分别记（`inlineOpenSessions`）。
      ⚠️ `activeHost` 只能由「哪扇是 key 窗口」决定，**不能在内置层 onAppear 里抢**——
      多扇面板同时出现时谁最后 appear 谁赢，那是错的。
    - 🔴 **页面只在「宿主消失」时释放**（用户：多个窗口的状态本身就不一样，保留很重要）：
      淘汰只在同一宿主内部发生（`maxPagesPerHost=2`），**绝不跨宿主淘汰**；
      切窗口/收气泡都不算消失；回收在浮窗关闭与 `ContentView.onDisappear`（阅读窗口关闭）。
    - 🔴 **「谁在接键盘」不能按具体类型猜**：单键工具快捷键（`e` 橡皮等）原来判
      `firstResponder is NSText`，**WKWebView 不是 NSText** → 内置面板里打字被抢（输入 `e` 变橡皮）。
      与 ⌘C 那次同一类错误。统一改用 `aiWebInputHasFocus()`（沿响应链找 WKWebView），
      单键监视器与 Esc 监视器都加了。**以后凡是「阅读区要不要吃掉这个键」都要算上 webview。**
    - ✅ **webview 内存已实测**（`AI-PLAN.md §11.6`）：**每个宿主一个独立 WebContent 进程，
      约 100~110MB，同源不共享、线性叠加**；代价按「同时可见的面板数」算。现行策略
      （`maxPagesPerHost=2` + 只在宿主消失时释放）不用改。
      量法两个坑：`ps` 的 RSS 严重低估（同进程 RSS 82MB / footprint 1361MB，**看 footprint**）；
      WebContent 的 ppid 是 1，只能用「基准 + 增量」归属。
    - 吸附部分用户已验：「比想要的还好」——可自由拖动又保持相对位置，缩放主窗口会重新贴回右侧。
    - `xcodebuild` 通过，**内置模式仍待真机验证**（气泡与展开/拖左缘改宽/弹出为独立窗口来回切/
      内置面板上拖动不穿透到阅读区/切活跃窗口面板跟过去不崩）。

  - **2026-08-27：文字笔记可在 PDF 页上展开正文，三端落地**（用户需求：三种显示模式，每条笔记自己的属性）。
    规格见 `REQUIREMENTS.md §1.2` 的「文字注解的展开方式」表，线格式见 `PROTOCOL.md`。四条拍板（用户选的）：
    ① 气泡只显示**批注正文**（原文靠页面荧光高亮，不重复占地方）；② 尺寸**跟页缩放**（全是页宽比例）；
    ③ 编辑入口 = 气泡右上角**铅笔**（点击模式下点图钉 = 展开/收起，故「看」与「改」分得开；
    悬浮/始终模式点图钉直接进编辑器）；④ 悬浮模式在触摸端**笔悬停触发、手指降级为点击**。
    - **模型零迁移**：`TextNote.display`（`NoteDisplay` 枚举 tap/hover/always）落 payload 的 `display` 键
      （小写串，跨平台可读），旧笔记无此键 = tap，与 `type_id`/`source` 同一先例。安卓 `TextNotePayload`
      同款读写。**空正文的笔记任何模式都不展开**（选区注解可能只是个标记）。
    - **协议扩两条**：`notes`(0x39) 每项尾部 + `textNote`(0x24) 尾部各追加 `u8 display`
      （0=点击 1=悬停 2=始终，只许尾部追加）。三端同版本，老形态字节各多一个 `00`。
      🔴 **「此刻哪几条展开着」不上线也不落库**——那是各端自己的瞬态显示状态（同缩放/滚动的口径）。
    - 🔴 **气泡的比例常数是三端契约**（Mac `Sources/Views/NoteBubbleView.swift` 的 `NoteBubble` /
      web `render.ts` 的 `BUB` / 安卓 `shared/NoteBubbleGeom.kt`）：宽 0.30×页宽、字号 0.022×页宽、
      行高 1.35、内边距 0.55、圆角 0.5、间隙 0.25、铅笔 1.7、最多 10 行 —— **改一处必须同步另外两处**
      （同 `InkEdit.splitStroke` / 草稿纸底纹的先例）。折行各端用自己的排版引擎，断点允许细微差异；
      位置规则三端一致（图钉右侧优先 → 放不下翻左 → 钳进页内）。配色纸白底 + 发丝描边、**无投影无渐变**。
    - 三端入口：Mac 编辑器 sheet 加分段 `Picker`（新增 5 条 en/zh-Hans 文案）；网页/安卓编辑器加同款
      三格分段（安卓复用 `PadPanels.segButton`）。安卓的手指轻点分派改成 **`onFingerTap` 返回 Boolean**
      （草稿纸图钉优先，没吃掉才判笔记标记/铅笔，与 web `endTouch` 同序）。
    - 验证：`note-type-test`(27，新增 display 三态回环/旧 payload 兜底/线上编号)／`wire-codec-test`(85)／
      `wire-cross-test`(160)／安卓 `WireCodecTest`(向量扩到 80 条) + 新 `NoteBubbleGeomTest`(13)／
      `xcodebuild`／`tsc --noEmit`／`vite build`／`assembleDebug` 全绿。
    - **待真机验证**：① 三种模式在 Mac/网页/安卓两模式下的观感与手感（尤其气泡在缩小页面时是否还读得清、
      跟页缩放是否如预期）；② 平板笔悬停能否稳定触发悬浮展开（安卓 `ACTION_HOVER_MOVE`）；
      ③ 「始终展示」多条并存时是否糊页（需要的话再谈自动避让）；④ 三端改展开方式后互相同步。

  - **2026-08-28：PDF 画板模式（Mac only，待真机验证）**——页面两侧的空白也是可书写区，横向按笔迹
    「软边界」生长（用户要的「类似草稿纸那种」）。用户拍板四条：**页宽不变、内容变宽**（开关时页面
    纹丝不动，需要时出横向滚动条，不重新 fit）／**逐文档记**开关／**先只做 Mac**／宽度不固定、按草稿纸
    那种无限感来。
    - **不引入新坐标系**：页边笔迹仍是**页内笔迹**（`note` kind=2、归属那一页），只是归一化 `x` 越出
      `0...1`（单位还是「页宽的倍数」）。于是 schema、`PROTOCOL.md` 线格式、Inspector 分页统计、
      擦除/框选/图层全都不用动，旧数据天然还在 `0...1` 里。**唯一的 schema 改动是 v11→v12 给
      `document` 加一列 `canvas_mode`**（开关本身，老库补列即 0）。
    - **「无限」= 软边界生长**（`Sources/App/CanvasMargin.swift`，照搬草稿纸 `ScratchBounds` 的思路
      但只做横向）：每侧宽度按 `step=0.5` 页宽取档，写到离边界不足 `slack=0.35` 就往外跳一档，
      上限 8 页宽（防坏数据）。阅读区是页流 + `ScrollView`，内容宽必须有限——档位化就是为了少动布局。
    - **🔴 每次改内容宽都必须同 runloop 补一次 `scrollTo`**（`ReaderSurface+Canvas.swift`
      `applyCanvasMargin`）：内容一变宽页面就在内容里右移 Δ/2，不补偿则页面在笔下平移。补偿后
      `scratch.geo` 要等下一帧才汇报，故 `containerPointToPageNorm` 改用 `anchorOffset`（同缩放路径的坑，
      不改的话跳档那一瞬笔尖会整整偏出半个页宽）。
    - 渲染：`PageCellView.wide {}` 把**纸面与墨迹两层**的 frame 撑到 `页宽 + 2×margin`、外层再钳回页尺寸
      （SwiftUI 的 frame 只定布局不裁剪 → 居中溢出），跨页边的笔画因此**整条画在同一层**；其余各层
      （页图/高亮/选择/图钉/光标）一律仍是页内坐标。
    - `InkEdit.translated/scaled` 加 `xRange` 参数，**默认仍是 `0...1`** → web/安卓那两份实现无需同步。
    - 入口：工具栏（夜间模式左边）+ 菜单「显示 › 画板模式」⌥⌘C。
    - 验证：`canvas-margin-test`(24 新增)／`ink-edit-test`(62)／`store-test`(38)／`ink-store-test`(21)／
      `xcodebuild` 全绿。**待真机验证**见「接下来」第 11 条。
  - **2026-08-28（同日）：画板模式补齐 web + 安卓两端**（用户「给其他两个端也做一下」）。
    - **协议只加一条**：`canvas`(0x4B, S→C) = `u8 on · f32 margin`（每侧页边宽度 ÷ 页宽）。
      页边笔迹本身仍走既有的 `strokes`/`ink`（只是 x 越出 0…1），**除这一条外线格式一个字节没变**
      ——老客户端收到越界的 x 会把笔迹画到页外被裁掉，不崩、不丢数据。
    - **页边宽度由 Mac 单方面决定**（同 radial/pressRing 的「Mac 判定、平板照画」）：
      `ReaderSurface.applyCanvasMargin` → `session.canvasMarginLive` → `AppModel.broadcastCanvas`；
      切文档（`pushStrokesIfDocChanged`）与跳档时各发一次。客户端**落笔中可乐观跳档**
      （三端同一组档位常数），下一条下发即以 Mac 为准。
    - **三端各一处渲染红线**：页外的点**不能靠 clamp 收边**（那会压成页边一条竖线），
      一律「放宽 clamp + 整层 clip 到内容宽」——Mac 是 `PageCellView.wide` 的双层 frame、
      web 是 `clipContent`、安卓是 `onDraw` 里那次 `canvas.clipRect`。画板一关，页外笔迹随之看不见
      （数据还在）。安卓另需 `ink.clearCache()`：几何是按 clamp 后的点建的，页边一变旧几何就是错的。
    - **两端各修一个同款 bug**：捏合锚点的 `scrollX` 基准是**内容**左缘而 `fx` 抓的是**页内**比例，
      画板模式下要补上左侧页边那一段（web `input.ts` / 安卓 `pinchMove`），否则一捏合页面就横跳。
    - **安卓两模式真源不同**：模式2 用 Mac 下发值；模式1（独立版）本机就是真源，
      从库里的 `canvas_mode` 列 + 笔迹越界量自己算（`shared/CanvasMargin.kt`），开关在顶栏 ⋯ 菜单。
      **`presetCanvas` 必须赶在首次几何就绪之前调**，否则 `applyHFrac` 用的还是没有页边的内容宽、
      上次的横向位置会落偏。`updateProgress` 的 hfrac 上限同 Mac 放宽到 20（页边让它可以大于 1）。
    - **开关三端都有**（用户 2026-08-28 追问「web 端没看到 toggle 是没做吗」——第一版确实只做了
      跟随显示 + 书写，开关只在 Mac）：`canvas` 改成**双向**（同 mode/pen/eraser 的先例），
      C→S 只有 `on` 有意义、`margin` 恒编 0。客户端**只发请求不改本地**（同 openPad 的惯例），
      Mac 执行后广播权威值回来才改布局。Mac 侧照 `padOpenDocRequest` 的老路子走
      `AppModel.padCanvasRequest` → 那个窗口的 ContentView 认领 → 与工具栏按钮共用 `setCanvasMode`
      （AppModel 够不着 @MainActor 的 WorkspaceManager，落库只能在 View 层做）。
      入口：web 顶栏画板按钮／安卓模式2 顶栏 ⋯ 菜单／安卓模式1 同菜单（本机真源，直接改库）。
      **ContentView 又踩了一次类型检查器超时**——这条 onChange 只能单独包一层 `canvasRoutes`。
    - 验证：`canvas-margin-test`(24)／`ink-edit-test`(62)／`store-test`(38)／`ink-store-test`(21)／
      `wire-codec-test`(89)／`wire-cross-test`(168)／安卓 `WireCodecTest`(向量扩到 84 条) +
      新 `CanvasMarginTest`(4)／`xcodebuild`／`tsc --noEmit`／`vite build`／`assembleDebug` 全绿。
      **待真机验证**见「接下来」第 11 条 ⑧⑨⑩。

  - **2026-08-29：内存占用大修（纯滚动 65 页 1604MB → 275MB，−83%）**，根因与改动全在 `HISTORY.md` 同日条目。
    四条要记住的（都是 `PageBitmap.draw` 里几行代码的事，但少一条就前功尽弃）：
    ① 🔴 **页图像素格式必须是 BGRX**（`noneSkipFirst | byteOrder32Little`，CA 在 Apple Silicon 上的原生格式）。
    用 RGBA 的话 CG 每次合成都要转换、转换结果还按固定条数缓存住，表现是 `MALLOC_LARGE` 涨到 31 块
    （≈515MB）就封顶、静置不降、`Reclaimable=0`、**改缓存上限完全无效**。改格式后要**日间+夜间各看一眼截图**：
    字节序搞反会红蓝互换。
    ② **像素缓冲自己 `mmap`/`munmap`**，别退回 `CGContext(data: nil)`+`makeImage()`（缓冲归 CG 的
    purgeable zone，CGImage 死了它不还），也别改用 `malloc`（分配器的 large cache 同样不还）。
    ③ **缓存计费要乘 `PageRenderEngine.copiesPerImage`**（现为 2 = 我们的缓冲 + CA 的合成副本）：
    只按 `bytesPerRow*height` 计费就是「设置页写 512MB、实际吃 1.5GB」。改这个系数前先 `vmmap` 复测。
    ④ **排查这类问题别信 `vmmap` 的「已分配」**：free 掉但被分配器缓存的大块照样列成已分配，
    以 `PageBitmap.liveImages`（我们自己数的存活位图）为准——我为此绕了一整轮。

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

7. **缩放路径的内存尾巴**（2026-08-29 大修后的残留，见 `HISTORY.md` 同日条目「留在 TODO 的尾巴」）：
   滚动路径已降到 275MB，但 ⌘+ ×5 后仍有 ~612MB 且 ⌘0 回不来。性质是干净的：几乎全是**我们自己的图**
   （`VM_ALLOCATE` 201MB ↔ `CoreAnimation` 198MB，1:1），根源就一条——**缩放后页图本身就大**：
   `basePixelCap=2800` 下一页 49MB，而 fit 只有 17MB。
   候选做法（都需先验手感，别直接改）：`recentBaseWidths` 4 → 2（`fallbackBase` 的兜底深度，减了可能在
   连续缩放时露白，撞「零闪烁纪律」）；或缩放 settle 后主动清掉非当前档的宽度。
   **另外**：本轮全部实测都在 900×450 小窗口做的，日常是 4K 大窗口——那时 `pageW*displayScale`
   顶到 `basePixelCap`，单页标称 50MB，量级完全不同，**真机得按真实窗口重测一遍**。

8. **移动硬盘弹出验证**（2026-08-05 落地，见上）：工作区放在移动硬盘上 → 打开、翻几页、写几笔 → **只关窗口不退出 app** → Finder 弹出该盘应当立刻成功。反例排查（先 `touch ~/Library/Logs/UniReader-ws.log` 开日志，再看有没有 `⚠️ PDFDocument 仍存活` / `⚠️ manager 仍存活`）：
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
   - **安卓模式1（独立版）**：顶栏入口/列表/新建；纸上写字与擦除（模拟器验不了 stylus，这条最关键）；
     **笔迹大小与 Mac 一致吗**（dp 坑，3x 屏最容易露馅）；双指捏合/软边界/回中/适应内容/minimap 手感；
     图钉点得开吗；底纹三种 × 纸色六种观感、深色主题下底纹不消失；橡皮半径手感（×800 不对就调，
     三端一起改）；v7 老库（无 `scratch_pad` 表）打开不炸、新建有提示。
   - **安卓模式2（输入板）**：Mac 开纸 → 安卓自动跟过去（换纸回中、关纸回 PDF）；安卓落笔/擦除 →
     Mac 出现；纸样两端互改；**缩放滚动与 Mac 各自独立**；快速连写乐观笔迹与回推不闪；擦除中途
     快照不复活已擦笔迹（ackRel）；断线重连后纸状态恢复；返回键先关纸。
   - **页面底图 + 客户端管理（2026-08-13 落地，四端）**：
     ① 新建一张纸 → 默认就垫着它锚定的那一页，且**页面上你点的那一处正落在视口正中**
     （位置不对就是三端契约或锚点算错了，先看 Mac 与平板是不是同一处）；
     ② 工具条那枚「显示所在页面」开关：Mac 关 → 平板跟着关（跨端同步）、重开文档还记得；
     ③ 页图清晰度：捏合放大后有没有一直糊着（档位没跟上）、缩放时会不会每帧都在重渲/重下（卡）；
     ④ **v9 老纸**（这次升级前建的）打开应当**不垫页**，观感与升级前一模一样；
     ⑤ 白纸 + 白页时页边那条描边看不看得见；牛皮纸/护眼绿上呢；
     ⑥ 「适应内容」在空纸垫页时应当装下整页（不是回中）；minimap 里那个淡页框会不会盖住笔迹骨架；
     ⑦ 网页列表里逐行改名/删除（删除要点两下才生效）；删掉开着的那张 → 纸当场收起、笔迹一并没；
     ⑧ 安卓模式2 纸样面板的「管理」组改名/删除是否同样落到 Mac。

9. **框选三增强真机验证**（2026-08-17 三端落地；2026-08-18 两个 bug 已修：web 虚线路径残留、提交后分层镜像闪烁，web 侧已用户确认）：① 自由框选：凹形凹槽内笔迹应**不**被选中、边缘擦到算选中；跨页 clamp 在起笔页内。② 光晕所见即所选，ghost 期间随预览走。③ 缩放：角手柄等比（Mac ⇧ 放开两轴）、边中点单轴；线宽随框变、贴页边 clamp 不越界。④ 回归：框内移动、单击/Esc/切工具清选中、隐藏图层不命中。**剩最后一项**：安卓模式2 连 Mac 提交移动/缩放后，笔迹与注解两层应各自随镜像就位、不再跳回（分层记账刚装上，`413aba0`）；验过即可把本条与状态速览的 2026-08-17 条目迁往 HISTORY。

10. **AI 面板 S1 真机验证**（2026-08-25 落地；方案与后续步骤见 `AI-PLAN.md`）。⌘⇧A 或菜单栏「AI」打开浮窗：
    ① 各平台能否**正常登录并聊天**——内置八家（ChatGPT / DeepSeek / Kimi / Qwen / Doubao / Claude / Grok / Gemini），
    Gemini 是已知风险项（Google 常拒 WKWebView 登录，UA 已伪装成 Safari 试一次，**不行就从内置表里去掉**）；
    ② **置顶**（图钉按钮）是否真的生效——`WindowLevelAccessor` 直接设 `NSWindow.level`，是这版唯一没把握的点，
    按了没反应就是它；③ 切平台再切回来**是否保留原页面状态**（不重新登录、不丢输入框草稿）；
    ④「更多 → 清除登录数据」后是否**确实需要重新登录**（不需要 = `AIProvider.dataDomains` 的域名单不够，
    登录常挂在另一个域上）；⑤ 关掉面板再 ⌘⇧A 打开，当前这家应当**即时出现、不重新加载**
    （`releaseIdle` 只留当前那一家）；⑥ 需要代理的平台走系统代理能不能通。
    ⑦ 工具栏高度现在可以接受吗（已改 `.unifiedCompact(showsTitle: false)` + 去 subtitle）。
    **S2 部分**（2026-08-25 同日落地）：① 右键「用 DeepSeek 讨论本页」→ 面板开、新对话、上下文条
    显示《书名》+ 页码 +「等待第一条消息」；② 发出第一条消息 → 上下文条变 🔗 已绑定、Inspector
    「笔记」页的「AI 会话」出现一条；③ 关文档再打开，那条还在；④ 点列表条目回到那次对话，点 ⊙
    跳到那一页；⑤ **在 DeepSeek 上删掉那个对话**再从列表打开 → 应标「⚠️ 可能已不存在」而不是
    静默显示首页；⑥ 换文档/关窗后上下文条不该还挂着上一本书。
    （`threadPattern` 已用用户实测 URL 核对并钉进 spike 第 ④ 块，不必再手工对。）
    **S3+S4 部分**（框选截图，同日落地）：① 按住 **⌥ 拖**一个框 → 区域外压暗、框角显示 p.N；
    ② 松手 → 面板开、右下角「已加到 DeepSeek」→ **DeepSeek 输入框里出现图片附件 + 一行上下文**；
    ③ **把阅读区缩到很小再框一小块公式** → 发过去应当依然清晰（这条就是「按页重渲染」的意义，
    也是最能证伪的一条）；④ 跨页框选 → 两段纵向拼接、中间一条浅灰分隔；⑤ 夜间模式下框选 →
    发过去的图应当是**白底黑字**；⑥ ⌥ 没按住时拖选文字/本机落墨/框选移动都不受影响。
    **投递失败怎么给我信息**：先 `touch ~/Library/Logs/UniReader-ws.log`，复现后找 `[SNIP] 投递失败
    tried=...` 那一行——它写明三级各自的结果（`input:no-evidence, drop:ok` 之类），一眼能定位断在哪。
    站点改版嫌疑先跑自检页：`cd ~/agent-home/uni-reader && python3 -m http.server 8899 &`
    然后 `open http://127.0.0.1:8899/spike/ai-adapter-test.html`（三条链路各出 PASS/FAIL，
    一分钟分清是脚本坏了还是站点变了）。
    **S5 部分**（选区回填笔记）：① 面板里选中一段回答 → 右键「添加到文字笔记」→ 上下文条闪
    「已加到笔记」；② Inspector 笔记页出现这条、正文是那段回答、行尾有 💬 徽标；③ 点 💬 回到
    那次对话，点条目本身跳到**第一张图那一页那一处**；④ 右键菜单里的剪切/拷贝/粘贴仍可用
    （这条菜单换掉了系统默认的）；⑤ 没选中文字 / 没绑定时「添加到文字笔记」应当是灰的；
    ⑥ 关文档再打开，笔记与徽标都在。
    **吸附 + 内置模式**（2026-08-26）：① 主窗口**非最大化**时开面板 → 自动贴右侧、上下同高，
    拖主窗口面板跟着走；② 主窗口最大化 → 面板**松开**、不被顶出屏幕，还原后重新贴上；
    ③ 两扇阅读窗口来回切 → 面板跟到当前那扇；④ 吸附状态下「置顶」图钉仍有效
    （这条专补 `addChildWindow` 抹掉层级的坑）；⑤「更多 → 改为窗口内置」→ 浮窗关掉、
    右下角出气泡，点开是侧面板，左缘可拖改宽；⑥ 内置面板里「弹出为独立窗口」→ 回浮窗，
    登录/草稿/滚动都不丢；⑦ **在内置面板上拖动不该触发阅读区的拖选/落墨/框选**；
    ⑧ 内置模式下 ⌘⇧A 是展开/收起而不是开窗口。

11. **PDF 画板模式真机验证**（2026-08-28 落地，Mac only，见状态速览）：
    ① **零跳变**：工具栏按钮/⌥⌘C 开关的那一下，页面在屏幕上应当纹丝不动（只是两侧多出空白、
       出现横向滚动条）；关掉时若正停在页边区，视口应落回页面左缘而不是乱跳。
    ② **写不到头**：一直往右（或往左）写，写到接近边界时边界自己往外长一档——**页面不能在笔下平移**、
       笔尖不能与墨迹分家（这条是本功能最容易出错的地方，见 `applyCanvasMargin` 的补偿）。
    ③ 跨页边的一笔（从页内画到页外）应当是**连续一条**，不被页图切断。
    ④ 缩放（捏合/⌘±/1:1/fit）后页边应当跟着等比变，横向滚动范围不越界、不出现常驻横条。
    ⑤ 页边笔迹的擦除、框选（自由路径圈到页外）、移动/缩放手柄、图层显隐是否都正常。
    ⑥ **重开文档**：页边笔迹与横向位置都应在原处；画板开关本身逐文档记（另一本书不受影响）。
    ⑦ 夜间模式下页边纸色应与页面一致（同一张纸的横向延伸，不是灰底）。
    ⑦.5 **三端的开关互相同步**：在任一端切画板，另外两端应当跟着变（平板切 = 只发请求、
       等 Mac 广播回来才动；所以平板上按下去到画面变化之间有一个 RTT，确认这个延迟能接受）。
    ⑧ **网页采集页**（平板）：Mac 开画板 → 平板应当跟着长出页边并能在上面写；平板写到页边时
       边界自己往外长（本地乐观跳档，不该等一个 RTT 才有地方下笔）；双指捏合缩放后页面不横跳。
    ⑨ **安卓两模式**：模式2 同上；模式1（独立版）顶栏 ⋯ →「画板模式」开关逐文档记，
       **重开这篇文档时横向位置应当还在页边那处**（`presetCanvas` 的时序坑）；
       两模式下页边笔迹的擦除/框选/图层显隐是否都正常。
    ⑩ 三端**同一篇文档**互看：同一笔页边笔迹在 Mac/网页/安卓上应当落在同一个位置
       （页边宽度对不上的表现是「Mac 上写在公式右边、平板上写到了页面里」）。

12. **模式2 笔画闪烁真机验证**（2026-08-28 修，见 `HISTORY.md`；Mac 与安卓**都要重装**，
    两端各改了一半，只更一端不生效）：
    ① **连续快写一整段字**（重点：不要写两笔就停，闪烁只在连续书写时复现），已写完的笔画
       在整段过程中都不该消失/闪一下；写完停手后也不该有笔画凭空少掉。
    ② 已经写了几百笔、e2e 读数明显变高之后**再**按 ① 走一遍——旧版正是「e2e 越高闪得越凶」。
    ③ **擦除回归**（别修好一头坏另一头）：连续擦一片笔迹，不能出现「删掉了又出现，过一会才真的删掉」。
    ④ 草稿纸上同样走 ①③。
    ⑤ `adb logcat -s UniReader/Canvas`：正常情况下**不该**再出现
       `乐观笔迹 opt:N 等真源超时（3000ms 无回推），撤掉`；出现了就说明 Mac 那边真的断了回推。
    ⑥ 顺带回传 `回推 strokes N条/M点 ≈XKB … e2e=…` 这条（1s 一条）的头尾各几行，
       用来定「已知 Bug」里那条 O(n²) 的实际量级。

13. **移动端三件真机验证**（2026-08-28 落地，见 `HISTORY.md`；Mac 与安卓都要重装，网页刷新即可）：
    - **导航（模式1）**：顶栏最左新的「目录 / 书库」键 → 目录树折叠/展开、当前章节高亮与自动定位、
      点条目跳过去（**只到页顶**，这是 Pdfium API 的限制，见 HISTORY）、坏书签行灰掉点不动；
      书库页列本工作区全部文档、已开的标「已打开」、点一篇开成新标签页；返回键先关抽屉。
    - **导航（模式2）**：顶栏下多出一条标签页栏，列的是 **Mac 已打开的窗口**；
      ① 点某个标签 → Mac 切过去、平板跟过去；② 在 Mac 上开/关窗口 → 栏上跟着增减；
      ③ 芯片/`+` 开书库 → 点一篇没开的，Mac 应新开一个窗口；④ 标签页**没有 ×**（这是刻意的）；
      ⑤ 「收起顶栏」应当把顶栏与标签页栏**一起**收掉，画布跟着补满，展开再复原；
      ⑥ 草稿纸浮条 / 延迟折线图的上边距要落在标签页栏**下面**，不能压住。
    - **两模式顶栏对照着看**：常驻键应当一模一样、顺序一样；⋯ 里前六项同序。
    - **长按呼盘**（两模式都要试）：① 正常写小字、写得慢一点、笔尖在小范围里绕——**都不该弹出盘**；
      ② 落笔不动约 1s——盘要照常弹出来，且手感与之前一样（进度环起显示的时机没动）；
      ③ 边界：写完一笔停在纸上不抬笔，停够 1s 会弹盘（这是设计如此，不是 bug）。
    - **模式2 的盘偶发不显示**：按老办法复现几次，同时抓两边日志对时间——
      Mac `log stream --predicate 'process=="UniReader"' | grep 环形盘`（或看 Xcode 控制台），
      安卓 `adb logcat -s UniReader/Canvas | grep radial`。两条时间戳一减 = 这一帧在路上的时间；
      若已明显变短（合帧生效）但仍偶发不显示，就该动 O(n²) 那条根账了。
    - **锁定水平滚动**（安卓两模式 ⋯ 里 / 网页顶栏那颗新按钮）：开了之后
      ① 单指或双指怎么划都不横移，纵向照常；② 松手惯性不带横向；③ **捏合缩放仍然正常**
      （放大后画面不该横向乱跳——这是刻意留的例外）；④ 画板模式下在页边写字时开着它最有用，
      试试是不是真的不跑偏了；⑤ 模式1 退出再进、切标签页，开关状态都该还在。

14. **笔迹镜像改增量：剩余真机回归**（2026-08-28 落地，主路径已验，见 `HISTORY.md`）。
    ~~① e2e 不再爬~~ / ~~② 一笔都不丢~~ **2026-08-28 用户已确认**（读数见 HISTORY）。剩下几条
    都是**走全量那条路**的老功能，改动没碰它们，属于回归性质、不急：
    ④ **擦除**：连续擦一片，不能出现「删掉了又出现」；擦完再写，新笔迹照样上屏。
    ⑤ **框选移动/缩放**：提交后镜像回来位置对、不闪。
    ⑥ **图层显隐**：切可见性后平板上的笔迹跟着增减。
    ⑦ **网页采集页**：写一段看丢没丢、位置对不对（它没有乐观笔迹，不涉及销账那套）。
    ⑧ 顺带看：模式2 的环形盘是不是不再偶发不显示了（大帧不再堵 WS 之后应当好很多）。

15. **缩放卡顿：手感确认**（2026-08-29 连做五轮，机制/实测/踩过的坑全在 `HISTORY.md` 三节里）。
    客观指标已经从 **36fps / 每帧 27.8ms** 到 **60~68fps / 每帧 16.7ms（墨迹占 4.3ms）**，
    剩余瓶颈是 SwiftUI 自身的视图重建，不在墨迹。**需要的是手感确认，不是再读日志**：
    在组成原理 p116/p117 那种密页上用按钮和捏合各来几次，感觉够不够。
    · **墨迹位图快照已落地**（2026-08-29 末轮，用户拍板"先糊一点再更新"）：缩放期墨迹
    **零重画**，起手渲快照 4~7ms。笔迹闪烁由此解决，见 HISTORY 对应节。
    · 嫌动画快慢不对 → 只调 `ReaderSurface+Zoom.zoomAnimTau`（0.13）这一个数。
    · 要复查性能 → `touch ~/Library/Logs/UniReader-zoom.log` 开探针，**读之前先看 HISTORY 里
    「探针的两个坑」**（`frame()` 不是 fps；静止期会被记成长帧）。
    以下是眼睛要过的几条：
    「408学习区」的**组成原理 p117 / p38-39 / p125** 一带（单页 100~178 笔）与**数据结构选择部分
    p10-30** 上验三件事：
    ① 双指捏合放大/缩小跟手不掉帧（主目标）；工具栏缩放按钮/⌘±、⌘0/1:1、**⌘+滚轮连滚**同样不卡
    ——三条路都走了 `beginFastInk()`，哪条还卡就是那条没切上快速描边；
    ② 缩放**过程中**笔迹是**拉伸的位图**（会糊、且是恒宽无压感——快照就是用快速路径渲的），
    松手 0.15s 换回矢量即清晰。这是用户拍板的取舍（"先糊一点，然后再更新"）。糊得过头就说一声，
    把 `makeInkSnapshots` 里的 `r.scale` 从 1 提到 2 即可（内存与起手耗时翻倍）；
    ③ **画板模式**（`session.canvasMode`）下页边上的笔迹跟着一起缩、不错位。
    ④ **缩放中不该出现白页**：实化窗口改成照实跟随视口收缩了（原来是"只扩不缩"），防白纸现在
    全靠"缩放期间不驱逐 `images`/`tiles`"这一条。**来回快速捏合几次**，滑回来的页应当立刻有图；
    真见到白页，说明驱逐守卫漏了，不要退回"只扩不缩"（那是 74 页的来源）。
    ⑤ 缩放**过程中**滑进视口的页，墨迹不该有可察觉的缺口（`inkWanted` 留了半屏余量；
    余量不够就把 `pad` 从 0.5 屏加大）。
    另：草稿纸（`ScratchInkLayer`）是同款结构、这次**没改**——哪天某张纸写满了、捏合发卡，
    照本条同法处理（给它的 `inkDrawStroke` 也接上 `fast`）。

## 🐞 已知 Bug（待修）

- ~~`broadcastStrokes` 是 O(n²)~~ **2026-08-28 已修（待真机确认）**：加了增量 opcode
  `strokesAppend`(0x4C)，收笔那一处只发新增的这一条（体积与文档大小无关），擦除/框选/图层/切档
  仍发全量。详见 `HISTORY.md`。真机实测 1074KB/次 → 0~6KB/次，e2e 从「爬到 8 秒直至堵死」→ 15~224ms。

- **每收一笔主线程还有 ~11.5ms 的 O(笔迹×点) 开销**（2026-08-28 实测，`PadLog` 打点已在树上）。
  **不紧急**：它解释不了剩下那些百毫秒 e2e 尖峰（写字才 1~2 笔/秒，占用率百分之几；尖峰更像 WiFi
  抖动——e2e 跳的时候看一眼顶栏 `rtt` 就能分辨：rtt 跟着跳=链路，rtt 平稳而 e2e 独跳=Mac 侧）。
  但它**随文档长**（1233 条笔迹 / 9.5 万点时 11.5ms，写到 5000 条就是 ~45ms 一笔，那时 Mac 端
  写字会开始掉帧），而且干的是「比对 9.5 万个点只为发现多了一条」，纯浪费。两处各自独立、都不动协议：

  | 读数 | 现在 | 改成 |
  |---|---|---|
  | **派发 ~7.5ms** | `ContentView` 的 `.onChange(of: session.strokes)` 让 SwiftUI 比整个 `[InkStroke]` 数组 | 加 `session.inkVersion: Int`，每次改笔迹自增，`onChange` 盯这个 Int |
  | **对账 ~4ms** | `persistInk` 扫全表做整值比较 + `Dictionary(uniqueKeysWithValues:)` 重建整张快照 | 脏集合驱动：追加时只有新那条是脏的，字典增量更新 |

  现场数据（Mac，默认关）：
  ```
  touch ~/Library/Logs/UniReader-pad.log      # 开
  grep 收笔对账 ~/Library/Logs/UniReader-pad.log | tail -30
  grep 全量镜像 ~/Library/Logs/UniReader-pad.log | tail -10
  rm ~/Library/Logs/UniReader-pad.log         # 关（它与页图那条账共用一个文件，别常开）
  ```

- **全量帧的编码走 Foundation 装箱**（每个点一个 `[NSNumber]`）：实测建一帧 1202 条要 **11~22ms**。
  改成 `[InkStroke]` 直编字节能省掉那几十万次分配；线上字节数不变，所以**只在擦除/框选/切档那几下
  有意义**（收笔已经走追加帧了）。擦除路径已被发送端合帧压到 ~1 帧/RTT，暂不阻塞。
- **擦除路径仍是全量镜像**（每收一批擦除点广播一次）。要做成增量得给笔迹上**稳定 id**，
  而线上是刻意不带 id 的（见 `PROTOCOL.md` 的 `lassoMove`），改动量大得多。

- ~~安卓圆盘工具图标观感偏小~~ **2026-08-07 已修（待真机确认）**：根因是**单位搞混**——工具图标的
  缩放系数写的是 `k = r/dp(13f)`（dp 值除像素值），单位网格被压掉一个 density 倍（3x 屏上小 2.6 倍），
  笔图标用纯像素比 `r×0.62` 所以正常。修为 `k = r/17f`，与 web `drawRadialIcon` 的 `scale(r/17)` 完全一致
  （web 本来就是对的，不用改）。验证手段：`androidTest/.../shared/RadialIconProbeTest.kt`（渲染探针，
  把整个盘按设备 density 画成 PNG 落 app 专属目录，pull 出来逐像素看）——修前图标占圆片 27%、修后 ~50%，
  与 Mac 的 46% 持平。教训：**跨端抄绘制几何时先确认两端坐标单位**（web canvas 是 px，安卓这里 `dp()`
  换算过的也是 px，但 `dp(常量)` 是「dp 常量折 px」，两者混用就出这种 density 倍数的错）。
- **一个工作区里只有第一篇文档能有默认图层**（2026-08-05 做安卓多标签页时撞见，**Mac 与安卓同病，未修**）：`ink_layer.id` 是全局主键而默认图层用固定 UUID，`ensureDefaultLayer` 的 `ON CONFLICT(id) DO UPDATE` **不更新 `document_id`** → 第二篇起插不进自己的行，图层面板是空的、笔迹的 `layerId` 指向别人家那一行。当前不丢数据（可见性过滤按 `document_id` 取，取不到＝全可见），但按 id 做重命名/删除/改色时会跨文档互相影响。**默认图层 id 的语义是三端契约，要两端一起改**：① 默认层也用随机 UUID，没有 `layerId` 的老笔迹兜底到该文档第一层；② 主键改 `(id, document_id)`（要迁移）。证据与实证见 `ANDROID-STANDALONE-PLAN.md §9.11`。
- 笔迹打磨（已知简化，非阻塞）：马克笔叠笔接缝变深；pad 实时反馈阶段铅笔无抖动纹理。**原计划靠路线图 ⑤ 三端算法统一一并解决，该路线 2026-07-30 已搁置** → 现在是「各端各修、谁碍眼修谁」，两条都还没修。
- ~~安卓 marker 观感偏暗发浊~~ **2026-07-30 已修**（`ANDROID-STANDALONE-PLAN.md §9.4`，两模式共用 `shared/InkRenderer.kt`）：`PorterDuffXfermode(MULTIPLY)`（预乘 alpha 的老式合成）换成 API 29+ 的 `BlendMode.MULTIPLY`，26~28 保留兜底。模拟器用 `screencap` 逐像素对过公式：白底量到 (255,239,169)、压在蓝笔上量到 (36,92,141)，与 W3C multiply 逐位相符。**并排观感仍待真机**（§11.1 第 4 条）。

## 📋 Backlog（M3 及之后）

- **🚀 大分支：Android Pad 版本**（2026-07-22 提出；**2026-07-26 用户：暂缓，优先级下调**）：不再是「Mac 端投屏给 pad 采集页 HTML」的方案 B 模式，而是直接做一个 Android 原生/独立 App，能在平板上打开工作区项目（读同一份跨平台 SQLite `library.sqlite` + 文档 + 笔迹）。呼应此前存储选型就是为跨平台（Windows/Android）预留的决定。范围大，需要单独立项拆解，不塞进当前 M3 迭代。（路线图 ③ 即此。）
- **三种笔记形态**：文字注解、手写笔记、高亮均已落地（见 HISTORY）；**会话笔记（kind=1，预留 AI）** 用户 2026-07-21 明确暂不做（消息流 UI + 锚定 + AI 接口整套未起）。
- **移动端文字笔记功能对齐 Mac**（2026-08-07 用户提）：目前移动端（安卓两模式 + web 采集页）的文字笔记只有「新建/编辑/删除」，缺 Mac 侧的**笔记类型（NoteType）体系**——工作区级类型管理（新建/改名/配色）、编辑器里选类型、图钉/高亮按类型配色、Inspector 按类型筛选（Mac 侧在 `DocSession.noteTypes` + `NoteEditorSheet` + Inspector）。要做的话类型表得上线（协议现在没带），三端一起设计，别各端各拍。
- **文件重定位**：所有路径失效时提示重新关联（`missingDoc` + Re-link 已在）；hash 命中加路径 / 未命中作同文档新版本、笔记挂文档不丢（`relocate` 已较健壮）。
- **配对/安全**：连接管理已在（`ServerPanel` 逐个断开）；二维码 UI 打磨仍可做。
- **T1/T2 遗留**：旋转页坐标未用真实旋转 PDF 验证；超大文档搜索可换 PDFKit 渐进式 API；拖到页边缘不自动滚动（非阻塞）。
- **T3 OCR 遗留**：整文件一次上传快路；跨「OCR 页↔原生页」混合边界拖选；搜索只覆盖已识别页；网络任务无取消；Vision 离线 OCR 未接。
- **打包**：非沙盒 + 公证发布流程。
- **安卓端文档分组 UI 未实现**（2026-08-21 Mac 侧已做）：schema v11 加了 `document.group_name`（一级分组，空串=未分组），安卓 `SELECT *` 读兼容、只会忽略该列；要在安卓侧栏加分组展示/筛选时按 Mac 的语义实现即可（不建分组表，整组改名 = 一条 UPDATE）。
