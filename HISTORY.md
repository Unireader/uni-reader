# UniReader HISTORY

> 已完成事项归档。**规则（2026-07-25 用户定）**：`TODO.md` 里完成的条目做完即迁移到这里，
> TODO.md 只留进行中/待办/交接状态。本文件按时间倒序 + 主题专节组织。

## 交接速览归档（2026-09-13 从 `TODO.md` 迁入：2026-07-25 ~ 2026-09-10 的逐日落地记录，原文未改）

`TODO.md`「当前状态速览」积到 800 行、几乎全是已完成条目，2026-09-13 整段迁到这里。**两条裁决**：
① 文中所有「待真机验证 / 待用户实测 / 待验」字样一律作废——2026-09-07 用户已把当时的全部验收挂账结清
（见本文件「真机验收批量结清」一节），2026-09-13 用户再次裁决「目前没有什么问题，有问题会说的」，09-07 之后新落地的
（09-10 三窗口内存五处修复 / 打开耗时后几轮 / 笔迹按页窗口装载 / 09-13 图片笔记与 Markdown 气泡 /
内存 sRGB 后 `copiesPerImage` 2→1 的设置页数字 / MCP 批 2、3）也一并按通过理解，`TODO.md` 从此不挂验收类条目；
② 本节按**原顺序**保留、不按日期重排——「真机验收批量结清」表里的日期就是查这里的索引。
其中**只记在这里、别处没有**的：多层笔迹 / 平板开文档 + 目录 / 框选三增强 / 草稿纸四端全部轮次 /
AI 面板 S1~S5 与吸附、内置模式 / 文字笔记展开方式 / PDF 画板模式三端 / 多标签页第 1、2 步 / 08-30 两处修复 /
打开耗时日志第二~六批 / 09-03 Inspector 三处、点高亮删除与侧栏排序 / 整体优化路线图 ③④ 原文 / 离线镜像 M1~M7.1。
（09-13 图片笔记、内存 sRGB、09-10 三窗口内存、09-02 撤销与剪贴板这几条 TODO 里只是 HISTORY 同日条目的摘要，未重复迁入。）
本文件其他条目里写的「教训写进 TODO 状态速览同日条目」「见 TODO 接下来第 N 条」，现在都指本节。

### 旧「当前状态速览」原文（`TODO.md` 2026-09-13 之前的版本）

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

  - **2026-09-06：划字发送 + 等页面就绪再投递 + DeepSeek 模式切换**（用户三条需求）。细节与待验清单见
    `AI-PLAN.md §11.8`，要点：右键选区多一项「问 %@（选中文字）」→ `AIPanelModel.attachText`
    （新增，只填字不带附件，适配器加 `insert(text)`）；投递前一律 `waitUntilReady()` 轮询等
    「页面已建 + 适配器 `ready()`」，**首次打开面板时这三件事一件都没发生**，从前是静默扑空；
    顺手修掉 `noteSentContext` 在会话 URL 出现前**直接丢掉上下文**的老毛病（改为 `pendingContexts` 攒着补记）。
    **模式**（用户截图确认页面结构后落地）：有图 → 识图模式、无图 → 专家模式，可在菜单里钉死某一档；
    🔴「只在新建对话时切一次」**不靠我们记状态**——那条分段控件只长在新对话页上，聊起来站点自己就收走了，
    适配器找不到就什么都不做。切不动**不挡投递**。自检页 `spike/ai-adapter-test.html` 18 项全绿（headless 实跑）。
    **2026-09-12 站点撤掉了模式**（用户实测只剩一种），内置表不再填 `modes`，机制保留给外部配置——见 `HISTORY.md` 同日条目。

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

  - **2026-08-29：修「新客户端连上来收不到画板状态」**（用户报：Mac 开着画板，安卓模式2 进来同步不到，
    状态就错了）。根因两处，都在 Mac 侧：
    - **连接时不补发 `canvas`**：`broadcastCanvas` 只在切开关/跳档（`applyCanvasMargin`）和**换文档**
      （`pushStrokesIfDocChanged`）时发，而后者被 `pushedStrokesKey` 挡着——同一本书不会再触发。
      于是新客户端连上来根本没收到过这条，画的还是页宽布局（页边笔迹被裁、写到页边也回不去）。
      修法：`AppModel` 的**新客户端**（`server.$clientCount`）与**服务起来**（`$isRunning`）两条补发链
      里各加一发。位置必须在 `pushLayout` 之后、`pushCurrentViewport` 之前（layout 会重置几何）。
    - **`canvasMarginLive` 在载入文档时没对齐**：`ReaderSurface.setup()` 是直接置 `canvasMarginState`
      的（首帧没有几何可补偿），绕开了 `applyCanvasMargin` 那个唯一写入方 → 广播读到的还是初值
      `step`（半个页宽）。表现是页边已长过几档的文档，客户端连上来页边比 Mac 窄、远处笔迹被裁。
      修法：`setup()` 里跟着同步一次。
    - 验证：`xcodebuild` 全绿；**真机验证见「接下来」第 11 条 ⑪**。

  - **2026-09-10：打开耗时账本落地**（用户报「有时候打开 tab 挺久才显示完整页面 + 笔迹」，先量化）。
    `Sources/App/OpenTrace.swift`：每次「打开」（`DocTabModel.select`）或「切标签」（`prepareForReactivation`）
    开一本账，**从点下去到可见页的页图 + 笔迹都画出来**为止自动结账；30s 未齐按超时结，换文档/关闭按中断结。
    记什么：同步装载分段（开PDF / 目录 / OCR / 笔迹(几笔) / 图层 / 注解 / 高亮 / 书签 / AI / 草稿纸 /
    进度 / 平板广播）+ 里程碑（种子 / 布局 / 定基准 / 首批页图(实化范围·缓存几张·需渲几张) / 可见页 /
    首张页图 / 首页墨迹）+ 页图逐页来源与耗时（`种子` / `缓存` / `磁盘12ms` / `渲染163ms` / `反色`，
    引擎 `noteSource` 记）+ 墨迹逐页首绘时刻与绘制毫秒（`InkStaticLayer` 的 Canvas 里按 `docKey` 找账）。
    看哪里：设置 → **诊断** 页签（最近 20 次，展开看分段与里程碑）；同一行摘要进 `wsLog`
    （`touch ~/Library/Logs/UniReader-ws.log`），形如
    `打开「王道…」(切标签) 完成 总 1840ms | 装载 0ms[] | 种子 +3(6/6 张页图) · 布局 +5(缓存命中) · 定基准 +9 ·
    首批页图 +11(实化 p12–17 宽2100 缓存6 需渲0) · 可见页 +12(p12–13) · 首张页图 +6(p12 种子) ·
    首页墨迹 +140(p12 361笔 绘92ms) | 页图齐 +6ms（种子2） | 墨迹齐 +205ms（2页 520笔 绘170ms）`。
    读法：`装载` 大 = 读库/开 PDF 慢（看哪一段）；`首批页图` 里 `需渲` 多且页图来源是 `渲染NNNms` = 冷渲慢；
    `墨迹齐` 远大于 `页图齐` = 笔迹 Canvas 绘制慢（看 `绘…ms` 与笔数，铅笔三道是三倍成本）；
    `超时（未齐）` = 有可见页始终没拿到当前宽度的图或墨迹没画（缩放中走位图快照那条路不经 Canvas，会这样）。
    **首条结论（同日，用户第一批日志）**：三次打开总耗时 189 / 227 / 857ms，最慢那次 `笔迹 506ms(2616笔)`
    占六成——`JSONDecoder` 解 `[[Double]]` 是 Codable 逐元素走容器协议，一个数 1~2µs，二十几万个点
    就是半秒。修：`InkPayloadFast.splitPoints`（`InkModel.swift` 末尾）在原始字节里找到 `points` 数组、
    `strtod` 直接扫进 `SIMD3<Double>`，其余百来字节照旧 JSONDecoder；形态不认识回落原路径，结果逐位相同
    （`spike/ink-payload-fast-test.swift` 22 项：逐位比对 / 各种写法 / 坏形态回落 / 计时 15MB 257→51ms，5×）。
    payload 格式**没动**（三端契约）。`loadInk` 的账拆成「笔迹读库 / 笔迹解码 / 笔迹入账」三段，下次日志能看出
    剩下的在哪一半。**待用户验证**：同一篇文档再开一次，「笔迹解码」应从几百 ms 降到几十 ms。
    其余两项可看的：`目录 57~117ms`（`TOCEntry.build` 遍历 PDF 大纲）、`平板广播 55ms`（有平板连着时的笔迹回传）——
    都还没到要动的量级。
    **第二轮（同日）**：Debug 包实测「笔迹解码 360ms」仍嫌久，用户定「先展示窗口和 PDF，笔迹异步处理好再显示」：
    ① `loadInk` 改**后台并行解码**（`InkStroke.decodeAll`，`concurrentPerform` 分块、保序），读库仍在主线程；
    回主线程按 `session.inkLoadGeneration` 核对，期间切走/关掉即丢弃，期间新画的笔迹合并保留
    （`applyLoadedInk`）；图层自愈挪到笔迹到位后（`ensureInkLayers`）；账本 `inkPending` 挡住提前结账；
    ② 数字解析从 `strtod` 换成 `Double(String)`：strtod 多线程**不伸缩**（300k 次 1 线程 10ms、8 线程 20ms），
    换后单线程略慢（51→99ms）但 12 核并行 20ms（spike ⑤：与顺序解逐条相同、保序）；
    ③ **切标签 150ms 的主项**：「开机自启平板服务」开着时，`AppModel` 所有 `broadcast*`/`push*` 只看
    `server.isRunning`，没有一个客户端也照样把整篇笔迹装箱、目录/书库拼字典再扔进空连接列表——
    守卫一律改 `server.hasClients`（新客户端接入时 `clientCount` sink 补发全量，跳过不丢状态）；
    ④ 切标签的同步段也入账：`恢复锚点 / 切换登记 / 平板同步 / activate 返回 / 下一拍 / 首帧 body`。
    ⚠️ Debug 包的纯 Swift 循环（解码、墨迹绘制）比 Release 慢 3~8 倍，量这类段落要看 Release：
    `xcodebuild … -configuration Release -derivedDataPath build/dev`（产物仍在 `build/dev`，不走 package.sh）。
    **用户实测（同日）：打开 / 切标签的延迟降到 30~60ms，「好多了」。** 本项结清，归档见 `HISTORY.md` 同日
    「打开耗时」条目；账本与诊断页保留，下次再有「有时候慢」直接看记录。
    **第四轮（同日，待用户验证）**：日志里还剩「笔迹读库 158ms · 2616 条」在主线程——读库也挪进解码那个
    后台任务，并改走窄查询 `LibraryStore.inkRows`（四列、免字典；细节见 HISTORY 同条第 4 点）。账本里
    「装载」段不再有「笔迹读库」，改看里程碑 `笔迹到位 N笔 后台读库 Xms + 解码 Yms`。

  - **2026-09-10：笔迹内存——点压到 f32 + 按页窗口装载/淘汰，已落地，待用户实测**（方案与落地记录
    `INK-PAGING-PLAN.md`，尤其 §9）。起因：用户定「1~10MB 以内可以全部加载，再多就很有问题」，而整篇笔迹
    一次进内存、`SIMD3<Double>` 每点 32B，这篇 2616 笔 ≈ 9~10MB 常驻、开文档峰值 25~30MB，正卡在线上。
    ① `InkPoint = SIMD3<Float>`（每点 16B；线格式本来就是 f32），「存 Float、算 Double」，payload 写 `[[Float]]`
    读 `[[Double]]`；② **`session.strokes` 不再是全集**，只装阅读区实化范围 ± 4 页、± 12 页之外淘汰
    （`InkWindow`，settle 时由 `ReaderSurface+Render` 报范围、`DocTabModel.ensureInkWindow` 装卸），
    整篇操作改问库：检查器按页列表 `InkPageSummary`（GROUP BY + `json_extract`）、删层 `DELETE … json_extract`、
    层计数、画板页边首值 `inkXExtent`；撤销栈引用的页钉住；平板对未装载页动手先 `inkEnsureLoaded` 同步补读。
    🔴 **改笔迹相关代码前先看 §9**——凡是把 `session.strokes` 当全篇用的写法现在都是错的。
    验证：`spike/ink-window-test.swift` 29/0、`ink-edit` 75/0、`ink-undo` 40/0、`canvas-margin` 24/0、
    `scratch-store` 53/0、`ink-store` 25/0、`ink-payload-fast` 25/0、`wire-codec` 100/0、`xcodebuild` Debug。
    **待用户实测**（`INK-PAGING-PLAN.md §6`）：① 同一篇 `footprint` 前后对比（预期 ~10MB → <1MB）；
    ② 快滚 / 跳页 / 平板 gotoPage 时笔迹不闪不缺不重；③ 擦除→滚远→滚回→撤销仍正确；④ 删整层 / 删整页后
    重开文档库里确实没了；⑤ 画板模式页边宽度开文档即正确；⑥ 检查器「笔迹」按页列表全篇都在、色点是去重后的颜色。
    **用户定的验证方式（2026-09-10）：不做一次性全量测试，边用边测，有问题再报。** 首批日志（新包，同日 15:19）：
    笔迹这边已经不是账上的项——`笔迹到位 13笔 p281–289 后台读库 2ms + 解码 0ms`（此前整篇 2616 笔 158ms + 360ms）；
    切标签 48~87ms。**日志里现在最大的项与笔迹无关**——同日第二轮把它们也处理了（待用户看下一批日志）：
    - `目录 143`（`TOCEntry.build` 遍历 PDF 大纲，每项解 destination + 取页对象）→ **后台建**
      （`DocTabModel.buildTOC`：另开一份 `PDFDocument` 专供遍历，主线程那份不被并发碰；到位后补平板广播）。
      账本改看里程碑 `目录到位 N项 后台 Xms`。参考小窗 `RefWindowModel` 仍同步建，开小窗时那一下没改。
    - `注解 154`：不是解码贵（实测 JSONDecoder 首次 0.1ms、ISO 格式器 4ms），八成是**外置盘冷缓存的 I/O**——
      `document_id=? AND kind=?` 只有 `(document_id, page)` 索引时要把这篇每一行的表页翻一遍再筛 kind，
      三百多个表页；笔迹读库挪去后台后，「注解」成了第一条碰 note 表的查询，这笔账就换了个名字
      （此前正是「笔迹读库 158ms」）。加索引 `idx_note_document_kind_page (document_id, kind, page)`
      （`CREATE INDEX IF NOT EXISTS`，不升 schema_version：索引不是数据契约；安卓 `Schema.kt` 可选同步加）。
      各段 detail 现在记条数（`注解 N条` …），下一批日志能分清量大还是单价贵。
    - `OCR 28`：`rebuildWatermarkProfile` 在主线程读整本 OCR blob（几 MB）→ 读库也挪进那个后台任务。
    - `草稿纸 29`：纸上笔迹（kind=4）改后台读 + 解码，同页内笔迹的套路（代次核对、期间新画的排后面）；
      账本记 `草稿纸笔迹到位 N笔`。
    - 「打开」路径首帧实化 **p1–1** 再跳 p285、p1 白渲 200ms：`ReaderSurface+Scroll.geometryChanged` 里
      `pendingRestore` 改到 `updateRealized` **之前**处理，本帧实化输入按恢复位置算（滚动本身照旧交给
      `followStep`）。切标签路径不经此（快照种子）。**阅读区改动，请留意冷开有进度的文档：不闪、落在对的页。**
    - `笔迹到位 +768` 但读库只 2ms：后台早就读完，是回主线程排队等前面的布局/渲染——主线程忙，不是笔迹慢。
    **第二批日志（同日 15:36，第二轮改完的包）**：「王道计组」冷开 788 → **364ms**，装载 366 → **22ms**
    （`注解 1(52条)`、`高亮 2(120条)`、`AI 0(20条)`——索引那条判断对了，同样 52 条注解从 154 到 1；`目录到位 485项 后台 15ms`；
    `草稿纸笔迹到位 163笔 后台 16ms`；首帧实化已是 `p284–285 需渲2`，不再白渲 p1）。「计算机网络」冷开 306 → 113ms。切标签 51~85ms。
    **剩下的一笔**：王道计组 `首张页图 +118` 之后主线程连着忙到 `下一拍 +351`（计算机网络只忙到 +110，切标签 +85）——
    +15 → +351 是**同一趟主线程**（`下一拍` 是 select 后 `main.async` 排的，它排到时前面全跑完了）。装载只占 22ms，
    其余是首窗视图树。王道与网络的差别：52 注解 + 120 高亮 + 20 AI + 有 OCR 缓存 + 2 张草稿纸。嫌疑按序：
    检查器「笔记」页一次建几百行（Debug 下 SwiftUI 每行 ~1ms）、OCR 启用后的 `enqueueOCR`（`ocrRuns` 三次 @Published
    = 整窗三次重算）。**先打点不猜**：账本加了 `检查器 body（tab 注解N 高亮N AIN）`、`阅读区段 body`、
    以及每次实化变更的几何输入 `实化 offY H ds pA–B → pC–D`——后者顺带查切标签日志里那条一直很怪的
    `首批页图 实化 p1–1 需渲1`（首帧 body 明明已是 p283–285，说明某一拍几何 offset 是 0，白渲一张 p1 还占着渲染队列；
    切标签的 `下一拍 +85` 里可能也有它）。下一批日志看这几行。
    **第三批日志（同日 15:42）坐实了后者**：切标签 `实化 +16(offY 0 H 875 … p283–285 → p1–1)` → `实化 +30(offY 400327 … → p283–285)`
    ——种子在 `setup` 里提交的 `scrollTo(off)` 慢半拍，先来一拍 offset 0 的几何，窗口塌到 p1（三个刚种好的页元胞
    销毁再重建）、白渲一张 p1。冷开也一样：恢复锚点那帧之后 `实化 +113(offY 0 …→ p1–1)` 再 `+123` 回来。
    **修**（`ReaderSurface+Scroll.geometryChanged`）：`pendingTarget` 非空（= 刚提交的目标还没被 ScrollView 报出来，
    `verifyPendingTarget` 达成即清）期间，实化输入一律按目标算而不是按这一拍几何；恢复锚点也登记成 `pendingTarget`
    （与跟随器同一个目标，幂等）；横向恢复滚了 x 就把目标换成带 x 的。缩放中不这么做（那条路每帧一个新目标）。
    **待用户看**：切标签/冷开的 `实化` 行不该再出现 `→ p1–1`；切标签、冷开都别闪。
    另一条线索：冷开王道 `实化 +244(p284–285 → p283–285)`——`isActiveWindow` 在首帧后 ~150ms 才翻真（buffer 从 0 变一屏），
    多实化一页；`+123 → +244 → +342` 那两段各 ~100ms 还没归因，加了 `body#k`（阅读区前 12 次 body 的时刻）与
    `页元胞 pN（图/笔/高亮/注解）` 两种打点，下一批日志对照看。`检查器 body` 这批没出现 = 检查器没开，排除。
    **第四批日志（同日 15:47，这次盘是冷的）**：
    - 上一条 `pendingTarget` 修法**没生效**：切标签仍 `实化 +28(offY 0 … → p1–1)`——首拍几何在 `setup`（+30 `布局`）
      **之前**就来了，而 `pendingTarget` 是 `setup` 才登记的。改成 `PageStreamView.init` 种子路径里就登记。
    - 冷开王道 606ms，全是**外置盘冷缓存**：`装载 101ms[图层 54 · 注解 13 · 进度 9]` 都是第一次碰那几张表页的寻道；
      `装载完成 +92 → select 返回 +242` 这 150ms 是 `setOpenDocuments` 一次写的 WAL fsync。
      **改**：进度 / 打开集 / 最近打开 / 路径有效性这四类「最后一次为准」的小写走 `WorkspaceManager.bookkeeping`
      串行后台队列（同键 FIFO；`progress()` 读之前同一文档还有写在排队就先排空；`teardown()` 与退出前
      `flushAllBookkeeping()` 排空再关连接）。笔迹/注解对账写**不走**它。
    - 首帧后 `body#2 +337 → body#3 +490 → … body#7 +597`：有 OCR 缓存的那本冷开后阅读区 body 跑了 7 次、主线程连忙 350ms，
      没缓存的那本 50ms——`enqueueOCR` 在 `updateRealized` 里**同步**读每页几十 KB 的 OCR blob（冷盘）再逐页写
      `ocrRuns`（@Published，一页一次整窗重算）。**改**：缓存读放后台，一批合并成一次写；账本记 `OCR缓存到位 N页`。
    - 可选再往前一步（**用户定**）：`PRAGMA synchronous=NORMAL`（WAL 下只在 checkpoint 时 fsync）——app 崩溃不丢，
      掉电/直接拔盘可能丢最近几笔；现在外置盘本来就得先退出 app 才能弹出，风险窗口不大，但这是耐久性取舍，不擅自改。
    **第五批日志（同日 15:56）**：切标签修好了——`实化 +25(offY 400327 …)`、`需渲0`、`页图齐 +25ms（种子2）`，总 26~50ms
    （还剩一处小抖动：首拍按「非活跃窗口」把种子多出的一页先拆再建，`+25 → p284–285`、`+40 → p283–285`，
    已改成 `init` 种子路径就把 `isActiveWindow` 种进 scratch）。冷开 `装载完成 +86 → select 返回 +86`，后台小写生效。
    冷开王道 470ms 里还剩两段：① `阅读区段 body +97 → 布局 +167`：一半是首窗视图树，一半是 `PageLayout(doc:)`
    遍历 340 页 `page.bounds`（冷盘 PDF 解析，网络那本 `布局计算 96(316页)`）→ **加 `page_geom` 缓存表**
    （按内容 hash 存每页高度，additive 缓存表同 `ocr_page` 性质，镜像的显式列表不认它、不升 schema_version；
    命中记 `布局 库缓存`，未命中算完后台回填）；② `body#2 +180 → body#3 +356` 176ms 没有任何里程碑，
    +356 是 `isActiveWindow` 翻真触发的 onChange——**这一段打点看不出来了，要用 `sample` 采主线程栈**（见下）。
    **第六批日志（同日 16:03）**：切标签王道「总 703 / 709 / 1176ms」是**账本的假象**——页图 +27、墨迹 +37 早齐了，
    但账本按 `scratch.geo.offsetY == 0`（首拍陈旧几何，`scratch.geo = n` 赋在替换之前）把可见页算成 p1–1、
    等一张永远不会来的 p1 页图，直到 0.7s 后进度节流存那一拍才有下一次 body 重算。修：替换后 `scratch.geo` 也换成
    按目标算的那份（`refitToViewport` 的锚定、`followStep` 也读它，本来就不该看到那个 0）。冷开的 `可见页 +83(p1–1)`
    同一根源。`page_geom` 命中（`布局 +75(库缓存)`、`布局读库 0`），冷开王道 345ms。
    **仍未归因**：冷开王道 `body#2 +91 → body#3 +227` 这 136ms（网络那本同一段 6ms）。打点已到头，等用户的 `sample`：
    `sample UniReader 3 1 -mayDie -file ~/Desktop/unireader-open.txt`，跑起来 3 秒内冷开王道，看主线程最深最密的子树。
    **采样结果（同日 16:24，2398 次采样）：主线程 81% 在 `mach_msg2_trap` 等事件，剩下的几乎全是
    `-[NSControl _mouseDown:] → NSButtonCell trackMouse … untilMouseUp` 里的 tracking runloop 等鼠标抬起（217 + 129 次）**，
    真正的 SwiftUI/渲染工作只有几十毫秒。所以 `body#2 → body#3` 那段是**用户按着鼠标的时长**（每次 6~260ms 不等）：
    `select()` 在 mouse-down 就跑了，之后主线程在 tracking 模式里等抬起，**主队列（`DispatchQueue.main.async`、
    `MainActor.run`、Combine `receive(on: .main)`）的东西要等抬起才派发**——`下一拍`、`笔迹到位`、`目录到位`、
    页图渲染完成回调全都挤在抬起那一刻（日志里它们的时刻永远相同）；`isActiveWindow` 翻真也是那一拍
    （用户从设置窗口/终端点过来，这一下同时把阅读窗口变成 key）。SwiftUI 的 body 走 CA 事务观察者，
    tracking 期间照跑，所以首帧不受影响。**结论：打开路径的主线程账已经清完；剩下的是鼠标和窗口激活，不是代码。**
    要让渲染结果在按住鼠标期间就上屏，得把完成回调改走 `RunLoop.main.perform`（common modes）——观感收益是
    「松手瞬间已在」变「按住时就在」，几十毫秒的事，没动。
    顺手改了一处真的主线程 I/O：`kickBaseRenders` / `settleRender` 里 `pdf.page(at:)`（冷盘一页 ~20ms，
    `实化 +63 → 首批页图 +127` 那 64ms）挪到渲染队列上取（`PageRenderEngine.PageSource.lazy`）。

  - **2026-08-29：macOS 多标签页第 2 步「标签化」已落地，待真机验证**（方案 `MAC-TABS-PLAN.md §9`）。
    新增 `TabsModel`（窗口的标签集，不变式：永远至少一个标签，故 `active` 非可选）、
    `TabBarChrome.swift`（纯呈现层，只吃值）+ `TabBarView.swift`（适配器）+ `spike/tabbar-look.swift`（样张）。
    - **`DocPane` 拆层没做也不需要**：`TabsModel` 只转发**活动标签**的 `objectWillChange`
      （会话 → 标签 → TabsModel → ContentView）就等价于从前的 `@StateObject var session`，
      `ContentView` 只把 `tab` 改成 `tabs.active` 一行。
    - 语义：侧栏点文档 = 已开着就切过去、没开就新标签；平板 `openDoc` 改成**开新标签**；
      ⌘W 关标签（只剩一个时关窗口，同 Safari）、⇧⌘W 关窗口、⌘T 新标签、⌃Tab / ⌃⇧Tab；
      标签序 + 活动标签存 `UserDefaults`（不动 SQLite schema），冷启动最多恢复 8 个标签。
    - **必改项已改**：AI 内置面板宿主从 `session.id` 改成 **`session.windowID`**——按标签分的话
      切标签就是换宿主，会复现 2026-08-26「开着 webview 切换书」那个 WebKit trap。
    - **三个坑（细节在方案 §9）**：① 切回标签会跳回「装载那一刻」的位置（阅读区首帧只认
      非 "mac" 来源的锚点，而本机滚动发的正是 "mac"）→ `prepareForReactivation()` 把活值翻译成
      `restore` 锚点；② **样张当场抓到**横向 ScrollView 把浮动胶囊撑成满宽 + 浅色下活动标签反而更浅
      → `ViewThatFits` + `fixedSize` + 活动标签加粗；③ 关标签会把平板跟随交给另一扇窗口。
    - **2026-08-29 用户真机报的四处，已全部修掉并复验通过**（细节与教训全在 `MAC-TABS-PLAN.md §9`）：
      ① 「切换标签有加载感、闪烁」——**真凶是 `ReaderSurface.onDisappear` 里的
      `PageRenderEngine.purge(doc:)`**：它的前提「视图销毁 = 不再看这份文档」在多标签下不成立，
      切走标签只是拆了阅读区，文档还在后台标签开着，却把整篇几百 MB 页图全清了 → 每次切回来
      都要从头重渲。改成「这篇文档不再被任何会话持有」时才清。同轮另建「首帧种子」机制让重建后
      的首帧直接是离开时那一屏（种在 `ReaderSurface.init` 的 `@State` 初值里——`onAppear` 是
      **首帧画完之后**才调用的，在它里面做什么都救不了那一帧）。
      ② **⌘W 关掉了整扇窗口**（预判的冲突坐实）——AppKit 自带「文件 › 关闭」也占 ⌘W，菜单快捷键
      抢不过。改用**本地 keyDown 监视器**（跑在菜单等价键判定之前），每窗一个、先核对是不是
      key window，只剩一个标签时放行让系统关窗。
      ③ **阅读进度整个不保存/不恢复**——**第 1 步「纯搬家」埋的**，与标签无关、所有窗口都中招：
      `saveProgress` 原本 `guard let docId else { return }`，我加默认参数改成 `docId ?? docID`，
      于是 `select()` 里「窗口第一次开文档、旧 id 为 nil」那一下被兜底成「存到当前这篇」，
      在 `load()` 读进度**之前**用空会话状态（第 0 页）把它覆盖了。每次打开文档都自毁一次进度。
      ④ **切标签位置回不去**——快照里存了「滚动偏移/实化窗口」这种**每帧都在变的量**，而视图销毁前
      会来最后一拍零几何把它们写成 0。改成快照只放慢变量，位置从 `scrollAnchor`（页+页内比例）
      现算；且种下后必须**显式 `scrollTo` 一次**（`ScrollPosition` 初值不保证被采纳，而兜底重试是
      几何回调驱动的，页面不动就永远不重试）。
      🔴 **排查方式本身是这轮最大的收获**：① 我在渲染时序里连猜三次（`@Published` willSet /
      `@State` 同趟读写 / 退化几何帧）——那三处都是真 bug 也都修了，**但没有一个是主因**。
      改按仓库纪律「静默失效先打点再改码」加了三处 `ZoomProbe.mark` 后，**第一份日志就给出了答案**。
      这类「改了没效果」的问题，打点的成本永远低于再猜一轮。
    - 故意没做：标签拖拽重排、⌘1…⌘9。
    - 验证：编译零 error 零 warning；13 个 spike 全绿（向量逐字节未变）；16 张样张已逐张目检。
      **真机清单见「接下来」第 9 条。**

  - **2026-08-29：macOS 多标签页第 1 步「落库搬家」已落地，待真机回归**（方案与全部决策见
    **`MAC-TABS-PLAN.md`**，那是这件事的唯一权威）。用户需求：标签自建 UI 不走 NSWindow 原生标签、
    标签栏浮在 PDF 区域底部、切换零加载、同工作区打开一律走新标签。四条拍板：标签栏**两种形态都要**
    （浮动胶囊 ⇄ 贴底整条，可互切）且**关闭按钮在左**／**≥2 个标签才显示**／平板 `openDoc` 改成
    **开新标签**（推翻 2026-08-05「新开 Mac 窗口」的旧决定）／后台标签**每个 tab 独立存活，不做 LRU 休眠**。
    - **核心原则：一个标签 = 今天的一个窗口。** `AppModel.sessions`、平板 `docs`、工作区「打开集」
      `windowDocs`、`WorkspaceRegistry.windowPaths` 这四处记账本来就按 `DocSession.id` 走，
      所以标签化后它们语义一行不改，**平板协议一个字节不改**。
    - **本次只做第 1 步（纯搬家，界面上零区别）**：新建 `Sources/App/DocTabModel.swift`，
      `ContentView` 1146 → 645 行。16 条 per-doc `onChange`（含 `canvasRoutes`/`aiRoutes`/`scratchRoutes`
      三层包装，它们当初纯为绕开类型检查器超时才拆的，现在不需要了）+ `loadSelected` + 全部
      `clear*`/`load*`/`persist*` + 进度存取 + `verifyContentHash` + `setCanvasMode` + 四个 per-doc 状态
      整体搬进去，`onChange` 换成 Combine 订阅。
      🔴 **为什么必须搬**：多标签之后后台标签**没有视图在跑**，落库若仍挂在 `ContentView.onChange` 上，
      平板往后台标签写一笔、AI 面板绑到后台标签就会**静默丢数据**。
    - **搬的过程中撞到三个坑（都写进代码注释了，细节见方案 §9）**：
      ① `@Published` 在 **willSet** 发送 → 同步 sink 里读 `session.x` 拿到的是**旧值**，
      落库和广播会整体慢一个版本 → `on()` 一律 `.receive(on: DispatchQueue.main)` 跳一拍；
      ② `session` 从 `@StateObject` 变计算属性 = **ContentView 不再观察它**（标题栏/工具栏禁用态/
      查找条/OCR 面板全靠它刷新）→ `DocTabModel` 转发 `session.objectWillChange`；
      没有 `$session` 投影了，`.searchable`/`Toggle`/`Picker` 改用 `bind(\.keyPath)`；
      ③ 异步跳拍开了「切文档/关窗把最后一次改动甩掉」的窗口 → `select()` 与 `close()` 开头
      同步跑一遍 `flushPersist()`（七个 persist 全幂等）。
    - 验证：`xcodebuild` 零 error 零 warning；13 个 spike 全绿（`store-test` 38／`ink-store-test` 21／
      `ink-edit-test` 62／`scratch-store-test` 53／`ocr-store-test` 15／`ai-thread-store-test` 53／
      `note-type-test` 27／`canvas-margin-test` 24／`page-layout-test` 25／`page-snip-test` 34／
      `ocr-char-select-test` 26／`udp-reorder-test` 26／`wire-codec-test` 90 且导出向量与库里的
      `wire-vectors-swift.txt` 逐字节一致 → 跨端向量未变）。**真机回归清单见「接下来」第 8 条。**
      验过再做第 2 步（标签栏 UI + 打开语义改道 + AI 宿主键改窗口 id + 平板 openDoc 改道 + 恢复成多标签）。

  - **2026-08-30：用户报的两处已修（待真机验证）**。
    - **非活动标签的标题几乎看不清**（`TabBarChrome.TabChip`）：原来非活动走 `Color.secondary`
      ——`secondaryLabelColor` 本身只有五成不透明度，再叠在浮动胶囊的半透明 material 上、
      底下还透着 PDF 白纸，实际对比度掉到勉强能认字。主次本来就由**字重**分开（活动 semibold /
      非活动 regular，这是 2026-08-29 定的：浅色下 `.quaternary` 底片会把活动标签的字一起提亮，
      颜色分主次会反过来），所以颜色这一路只留一档：非活动改 `Color.primary.opacity(0.78)`。
      样张 `spike/tabbar-look.swift` 浅/深两套外观逐张看过。
    - **画板模式下框选移动会把笔迹压缩**（用户是在**平板**上报的；三条权威路径全改）。
      根因一句话：**整团平移用了逐点 clamp**。`InkEdit.translated` 是逐点 `clamp` 的，
      一团笔迹撞上 x 边界时越界的那一头被逐个摁在边界线上 = 笔画被压扁成一条线。
      三条路径当时各错各的：
      · **平板**（网页采集页 / 安卓模式2 → `AppModel.applyLassoMove`/`applyLassoScale`）**最糟**：
        `xRange` 压根没传，用的是默认值 `0...1` = 页内 —— 画板模式下只要笔迹有一点在页外，
        平板一移动就把它整条摁回页边。**这就是用户看到的那个。**
      · **Mac 本机**（`ReaderSurface+Lasso.commitLassoMove`）：传了 `inkXRange`，但那是**当前那一档
        软边界**，只比现有笔迹宽半页（`CanvasMargin.slack`），往页边一挪照样撞。
      · **安卓模式1**（`local/LocalCanvasView.onLassoMoveCommit`）：同 Mac 本机，传的是 `cmargin()`。
      三处统一成两条规矩：① **刚性平移**——位移先经新的纯函数 `InkEdit.fitTranslation`
      （Kotlin 同名一份）按选中集包围盒整体夹住，再原样平移每个点（笔迹按 x 区间、注解按页内
      `0...1`，取交集；选中集比区间还宽的退化情形不夹，保形优先）；② 框选编辑期间的 x 区间用
      **硬上限**（Mac `lassoEditXRange` / 安卓 `cmarginMax()`：画板开 = `±CanvasMargin.limit`，
      关 = 页内 `0...1`），不再拿「还没长出来的」软边界卡住提交——提交后 `refreshCanvasMargin()`
      本来就会跳到够用的档位。缩放提交是同一个压扁机制，一并改。
      另外两笔：**平板路径漏了页边生长**（笔画数不变 → 阅读区那个 `onChange(of: strokes.count)`
      不触发，`AppModel.lassoApply` 现在递增 `DocSession.inkMovedRev` 补一个便宜的信号；
      不补的后果不是压缩而是「挪出去就看不见」）；Mac 两处的 `sel.bounds` 改为**按真实数据重算**
      （`lassoSelectionBounds`）——原先顺着 `translatedRect`/`scaledRect` 递推，那两个函数把结果
      夹在 `0...1`，页边笔迹一动选中框就塌回页边。
      🔴 **`translated`/`scaled` 自身一个字没改**（三端逐点 clamp 的语义不动），改的是**调用方
      先夹位移**；两条权威路径（Mac、安卓模式1）都夹了，所以两端形状仍然一致。web / 安卓模式2
      的**乐观预览**没夹，撞边界时预览会比权威结果多走一点、等镜像回来归位——比原来「压扁」轻，
      但真机上留意一下这一下归位是否碍眼。
      **2026-08-30 用户在模式2 上实测，又揪出两条**（都在「平板那一侧自己算/自己画」的部分，
      Mac 改完不会顺带修好，这就是「三条权威路径」之外还要看的第四件事——**客户端的渲染与预览**）：
      · **还是挤成一团**（数据已经对了）：**平板的渲染是按它自己那份页边宽度 clamp 的**
        （安卓 `InkRenderer.buildPage` 的 `coerceIn(-xm, 1+xm)` / web `drawStroke` 的
        `inkXMin()/inkXMax()`——页外笔迹本来就该按页边裁）。Mac 随后是会广播新档位（`canvas` 0x4B），
        但那是**另一条独立广播**，到达有先后，中间那一拍屏幕上就是错的；万一没发出去就永远卡着。
        → 两端各加**本地自愈**：真源回推的笔迹越出当前档位就先放宽一档（只增不减，Mac 下发仍是权威，
        与落笔中那条 `growCanvas` 同一惯例）——安卓 `PageCanvasView.growCanvasFor`（`setStrokes` 里调）、
        web `growCanvasForStrokes`（`ws.ts` 的 `strokes` 分支里调）。
      · **拖到扩展区后选中框变得很大，左边从 PDF 页边起算**：安卓/web 那两份 `lassoHitTest` 的
        包围盒**初值取的是页角**（`lox = 1f; hix = 0f`），笔迹在 x=1.2…1.8 时 `min(1, 1.2)` 还是 1，
        框的那条边就永远钉在页边上。Mac 那份早改成「取首个点」了（`InkEdit.bounds`），这两份复刻没跟上
        → 三处统一成 ±∞ 起算。顺带修同源的两个**预览夹取**：安卓 `lassoGhost` 夹在当前档位、
        web `lassoXform` 干脆夹在页内 `0…1`（往页边拖时预览被摁回页里），都改成与提交口径一致。
      验证：`ink-edit-test` **75/75**（+13，含一条把 bug 本身钉住的反例）／安卓 `InkEditTest`
      **17/17**（+3，同一批数字）／`xcodebuild`／`assembleDebug`／`tsc --noEmit`／`build-web.sh` 全绿。
      Mac 侧留了两行 `PadLog` 打点（`applyLassoMove` 的「框选移动 …夹后位移/x区间」+
      `applyCanvasMargin` 的「页边档位 → …（pad=）」），`touch ~/Library/Logs/UniReader-pad.log` 开——
      下次再出这类事，一行就能分清是数据、是档位、还是没广播。

  - **2026-09-03：Inspector 三处小改**（②③ 用户当场实测通过，① 待验）。
    ① **引文在列表里折成一行**（`String.flattenedQuote`，放 `HighlightModel.swift`）：跨行选区的
    `quote` 是按行 `\n` 拼的，直接进 `Text(...).lineLimit(2)` 会在**原文换行处**断行，一条五行的
    引文只看得见头两行的头两截。抹平后交给 SwiftUI 按列宽折行，`lineLimit(2)` 才是「显示两行」。
    接缝补不补空格看两边字符（CJK 之间直接接，一侧是西文/数字补一个）。高亮条目与文字笔记条目共用；
    **落库的 `quote` 一个字没动**（复制、笔记编辑器的引文块、AI 引用都保持原样）。
    ② **两侧栏最小宽度 300**（`ReaderWindowController.paneMinWidth`，原来左 200 / 右 240）：
    信息页里「Title / Last Opened」这类左键右值的行挤成两截。用 `minimumThickness` 而不是给
    SwiftUI 内容加 `.frame(minWidth:)`——一处同时管住**初始宽度**（AppKit 展开一栏至少给到最小
    厚度）和**拖动下限**，且四个页签一视同仁；挂在某页签的内容上就只有那一页撑得开。
    🔴 **跨重启的宽度记忆做过又撤了**（2026-09-03 用户否决观感，代码已全部删除，勿再恢复）。
    三条路都试过，都栽在**展开动画**上：`setPosition` 要等布局稳定，早于上屏调就被下一次布局抹掉；
    `preferredThicknessFraction` 初始布局吃、**展开时不吃**；宽度约束（priority 压在
    `holdingPriority` 之下）也没顶住。结果都是「先动画展到默认宽、再瞬间跳到记忆宽」，
    用户原话「先动画慢慢打开一部分，然后瞬间切换到最终位置」。
    要重做先解决这个：得自己驱动展开动画（展开瞬间把宽度压到 0，再用 `NSAnimationContext`
    把 divider 从 0 拉到目标位置，全程不让 AppKit 决定终点），别再试上面那三条。
    顺带留下的东西：`wsTime()` 启动分段计时（`UniReaderApp.swift`，写 `wsLog` 那条通道）。
    实测冷启动 ~2.1s / 热启动 ~0.7s：dyld+静态初始化 170~640ms、开库 14~68ms、
    恢复标签(读库+开 PDF) 350~620ms、首次布局约 390ms，建三棵 SwiftUI 树只要 1ms。
    真要提速得把开 PDF 挪出主线程——那是动加载链路，**先跟用户过方案**。
    ③ **缩略图渲染像素宽 160 → 480**（`ThumbnailListView.pixelWidth`）：栏宽 300pt 减内边距
    ≈276pt，Retina 下 552 物理像素，160 要放大 3.4 倍 → 用户报「糊得几乎认不出任何文字」。
    480 只放大 1.15 倍；插值给到 `.high`（缩略图静态，不像阅读区每帧重画）。
    ⚠️ **改大它必须连带管内存**：View 层 `images` 字典原来**没有上限**，160px 一张 0.14MB 攒
    几百页还行，480px 一张约 1.3MB、340 页就是 440MB。已加 `maxKeptImages = 48`，超额丢离当前页
    最远的（丢掉的在 `PageRenderEngine` LRU 与磁盘缓存里都还在）。磁盘那头 `PageDiskCache`
    自带 1GB 上限 + trim。阅读区的 `fallbackBase` 读同一套键，占位图跟着变清楚。

  - **2026-09-03：点高亮能删 + 侧栏手动排序（Mac，待用户实测）**。两条都是用户当天提的。
    ① **单击文字高亮 → 弹删除气泡**（引文一行 + 页码 + 「删除高亮」）。命中判定放在**容器手势**
    那一层（`ReaderSurface.highlightHit`，逐行框 + 2pt 容差，重叠时取最后铺的那条），气泡由页元胞
    在**被点中的那一行**上挂一枚不吃点击的透明锚 + 原生 popover（同书签旗标那条渲染路径）。
    🔴 **不能给铺色层加 Button**：高亮是铺在正文上的，一旦吃命中，它盖住的那块字就选不了、
    框选不到了。🔴 **`.popover` 必须排在 `.position` 之前**——`.position` 之后视图的布局尺寸会撑满
    父容器，附着矩形变成「整页」（内容坐标里上万点高），气泡直接弹到窗口外（用户当天报，已修）。
    删除走 `session.highlights` 内存移除 → 增量对账删库（与 Inspector 的 × 同一条路径；
    高亮不进笔迹撤销栈，两处一致）。切走文字工具 / 草稿纸盖上来时气泡自动收。
    ② **侧栏手动排序 = 右键「上移 / 下移」**（`moveSelection`）：只在**同一分组段内**换位（列表就是
    按分组分段显示的），多选时整批一起动、保持彼此相对顺序，边界上或跨分组混选时菜单项灰掉。
    落库写 `document.sort_order`（此前建表就有这一列、但一直恒 0，排序实际只由 `last_opened_at DESC`
    决定 —— 也就是「开过谁谁就跳到最上面」）；一次操作把**整份书库**重排一遍写 1..N（位次是全局的，
    只写挪动的那几行会与别人撞号），**没排过的书 `sort_order=0` 仍排在最前**，于是「新加的书出现在
    顶上」这条老观感不变。
    🔴 **拖拽排序做过三版、全部撤销，勿再尝试**（用户 2026-09-03 明确否决：「你没这个能力做好这个
    功能」）：命中行整行铺色（「UI 不好看」）→ 行间插入线（「交互太垃圾」）→ 实时让位（拖起即离列、
    动画防抖都做了，仍不达标）。踩到的坑记在 `SidebarView` 头注释里（起手只能 `.draggable`、
    拖拽图像的拍摄时机与配色、`public.file-url` conform 到 `public.text` 会吃掉「拖 PDF 进书库」、
    SwiftUI 没有 dragEnd 回调），**将来真要再做从那里起步，别重走这三版**。
    ③ **「拖文档行到段头换分组」也一并移除**（用户当天要求）：侧栏从此**没有任何行级拖拽**，
    换分组走右键「Move to Group」、排序走右键上移/下移；整表那个「从 Finder 拖 PDF 进来」的落点
    （`dropDestination(for: URL.self)`）保留。
    待验：① 高亮气泡的落位与点细行的准头；② 上移/下移的段内语义与多选整批是否符合直觉；
    ③ 排完再开别的书，顺序应当不再变。

### 🔧 整体优化路线图（2026-07-25 起，用户需求「整体优化」）

四项大改，分里程碑推进。用户已定：UDP=整条实时流走 UDP（原生客户端自管序号/丢弃/轻量重传，控制握手仍走可靠通道，浏览器用不了 UDP 永远走 WS）；安卓 = 工作区内 `android/` 子目录独立 git 仓库。

- ✅ ① 通信协议改二进制 / ✅ ② 加 UDP 传输——已完成，见 `HISTORY.md`。
- ❌ **⑤ 笔迹算法三端统一（Rust 核心）——2026-09-07 用户正式放弃**（2026-07-30 先搁置，理由「收益好像也不是很大」）。方案文档 `INK-CORE-UNIFY-PLAN.md` 保留作存档，不实施；两个卡口问题（笔宽缩放语义 / 要不要引入 Rust）随之作废。**它当初要解决的观感分叉改由 `spike/ink-cross/`（三端绘制对比工具）接手**——先量出差异，再各端各修，不做统一实现；2026-09-07 首轮已修掉钢笔锥度与铅笔纹理两条，见 `HISTORY.md` 同日条目。**连带口径变更：三端笔迹观感的分叉从此各端各修，不再等「统一后一并解决」**——安卓 §9.4 的 marker 混合模式就按本地修法处理（`BlendMode.MULTIPLY`），马克笔叠笔接缝、pad 铅笔抖动纹理这类也一样，谁碍眼修谁。下面是搁置前的方案摘要，仅供将来重启时参考：起因：marker 混合模式 bug 暴露 macOS/Web/Android 笔迹渲染是各自独立实现而非同一算法移植（pencil 抖动纹理/fountain 起收锥度/ballpoint 半透明接缝黑点瑕疵，Web/Android 均缺或未修，见该文档 §1 逐项证据）。方向：Rust 核心只产出平台无关绘制图元（变宽描边转**闭合轮廓**、三端 nonzero 一次 fill），三端原生 2D API 仍各自负责上色/合成，不引入 Skia、不碰阅读区纯 SwiftUI 红线、不改线格式。**2026-07-30 二轮审核已修订该文档**：一轮"输出三角网格 + `lyon`"的选型与三端 `fill(Path)` 自相矛盾，已改为 stroke→outline（候选 `kurbo`，待 spike）；补了三端已分叉的 alpha/起笔/**笔宽是否随缩放**语义决策、输出坐标空间与缓存策略、`android/` 独立仓库的依赖形态、测试验收（golden 无法逐点比对）、以及不引入 Rust 的两个更轻替代方案对照。**待用户拍板：① 笔宽缩放语义（第一个卡口）② 是否引入 Rust 这一中间语言 / 何时开工。**
- 🚧 **③ 安卓模式1 独立版**：**设计方案已出 → `ANDROID-STANDALONE-PLAN.md`**（2026-07-29）。用户已定三条：全盘文件权限直开工作区文件夹 / 与模式2 同一个 App（启动二选一）/ 首版范围＝阅读+手写。技术选型：PdfiumAndroid 渲染、裸 `SQLiteDatabase`（不用 Room，schema 是 Mac 定的跨平台契约）、Compose 外壳 + 自定义 View 画布。核心设计＝把「页图哪来」「笔迹提交给谁」抽成两个注入口（`PageImageSource`/`InkBackend`），两模式共用全部几何/输入/渲染/笔迹算法。**最大风险：页面尺寸 box 口径两端必须一致（CropBox 有效则 CropBox，否则 MediaBox），不然笔迹整体漂移**，见该文档 §9.1。**2026-07-30 进度：M0~M6 已落地**（骨架/数据层/阅读/手写/擦除/多图层/笔架与图层面板/框选移动/尺子/文字注解 CRUD/已有高亮与选区注解铺色/长按环形选笔盘本地判定；M7 也做掉了三件不依赖设备的：阅读顶栏补夜间/页图/锁缩放、工具状态持久化（`ToolPrefs`：笔宽/当前笔/橡皮/夜间，模式1 没有 Mac 推笔架，不存就每次回到内置四支）、WAL 建不起来时的降级与文案）。**§9.5 的残留也清了（2026-07-30）**：新增 `StoreQueue`——单线程 executor 独占 `LibraryStore`，落笔/擦除/框选/注解/图层/进度七处写库连同它们后面的重读全部离开主线程，主线程只 `submit` 参数、拿回快照刷界面；关库排在队尾，退出前提交的写一定先落盘。改的过程中**修掉两个丢数据 BUG**：① 擦除对齐改成「头一段沿用原 id」，否则回推没到就再擦一次会把整页笔迹删光（旧实现实测 3 段变 0 段）；② 擦除对齐会把**隐藏图层**的笔迹当成「被擦光了」全删掉（藏一层再随便擦一下那层就没了，界面上看不出来）。**UI 现代化（2026-07-30 用户提「UI 太 demo 了」）**：从无到有建 `res/`（深浅两套语义色板 + 主题 + 28 个手写 VectorDrawable 图标）、`shared/Ui.kt` 设计系统（扁平/原生/颜色只走语义名三条硬规矩）、`shared/TopBar.kt` **两模式共用顶栏**（全图标单行 + 系统 PopupMenu 溢出菜单 + 窄屏自动把键收进 ⋯，触摸目标不缩）、启动页与书库重做、画布底色跟随主题；**十处弹窗全部换成 `shared/Sheet.kt`**（笔/橡皮、图层、文字笔记、跳页、文档下拉、连接 Mac、目录浏览器、正在打开、两处提示——第一轮只改了界面外壳，弹窗还是框架默认样式）。方案 §4 的「Compose 做外壳」口径同时改成经典 View（一路没引，零 compose 依赖）。详见该文档 §9.6。**找工作区三件（2026-08-03 用户提，见 §9.8）**：新增 `local/StorageScan.kt`——① **外部存储**：目录浏览器第一层改成**存储卷列表**（内部存储/SD 卡/OTG U 盘），卷路径四条来源合并去重（`StorageManager`／`getExternalFilesDirs` 剥 `Android/` 上一级／`Environment`／直接列 `/storage`+`/mnt/media_rw`），哪条在哪个 ROM 失灵事先猜不到所以全都试；② **只认 `.unrd`**：删掉「选当前目录」，普通文件夹只能点进去，`.unrd` 行尾给「打开」；站在一个自己有 `library.sqlite` 但没 `.unrd` 后缀的文件夹里会当场提示改名；③ **扫描**：拿到权限且没扫过就自动扫一遍全部卷（不弹窗，结果进卡片），另有「重新扫描存储」实时弹层（边扫边冒结果、关窗即停）与浏览器里的「在这里扫描」；广度优先、深度 6 层/45s/2 万目录三重上限，**没走完一律把原因显示出来**。**用户设备不在手上，真机验证统一延后——待验项一律攒在该文档 §11.1（现 30 条，新增 SD/U 盘枚举、大盘扫描时限、扫描中途停止三条），别当已验收；§11.2 写了模拟器能证明什么、不能证明什么（新增一条：像素值与布局 bounds 是能证明的，「好不好看」不是）。**
- 🧪 **④ 安卓模式2 输入板**：demo（`ANDROID-MODE2-PLAN.md`）已真机验收通过；**2026-07-29 补齐到与网页采集页对齐，待用户真机验证**——新增 probe 流(0x44)/环形选笔盘(0x37)/长按进度环(0x38)/padGeom(0x45)/框选移动(mode=3+0x47)/多图层(0x3A+0x26~0x28)/文字笔记(0x39+0x24)/橡皮双向同步(0x46，含局部擦除 splitStroke)/penset(0x25)/docs+selectDoc/gotoPage(0x29)/latency(0x12)/尺子模式(ink begin line 标记)；修 marker 逐段画成圆斑串、fountain 系数 1.15→1.3（一直画细）、滚动每帧无脑 setText、MacClient 三组状态跨线程；加 WS 自动重连+心跳看门狗、夜间/页图显隐/锁缩放/沉浸全屏/顶栏收起/侧键。字节向量单测扩到全部 51 条（含 radial/notes/layers/eraser/lasso/probe），编译+测试全绿。**未提交，等验收。**

### 🗂️ 工作区离线镜像（2026-08-30 定方案，M1 已落地）

方案：**`OFFLINE-MIRROR-PLAN.md`**（Mac + 安卓模式1；外置盘工作区整份复制到本机内部存储，
离线照常写笔迹，接回硬盘做**三方合并**双向同步）。

**用户已拍板四条**（方案 §13）：阅读进度跨镜像同步（LWW，`last_opened_at` 取 max 且不进指纹）/
安卓镜像放 `/storage/emulated/0/Documents/UniReader/` / 一次做到 L2 双向 /
**镜像上加的书必须拷进工作区**（`in_workspace=1`，不允许外部引用 —— 回灌的文件搬运因此退化成一条幂等补齐规则）。

- ✅ **M1 指纹算法 + `workspace_id`**（2026-08-30）：
  - `Sources/Store/MirrorFingerprint.swift` ↔ 安卓 `local/store/MirrorFp.kt`，**跨端字节一致**；
    向量表 `spike/mirror-fp-vectors.txt` 由 `spike/mirror-fp-test.swift` 生成、安卓 `MirrorFpTest` 逐条比对
    （**只许在末尾追加**，同 `wire-cross-test` 纪律）。
  - 三条设计要点，都是踩过同类坑才这么定的：① **REAL 走 IEEE754 原始字节**而非十进制文本
    （`%.17g` 两端不保证逐字符一致，fp 差一字符 = 全表误判）；② **首字节是类型标签**（0..4），
    编码因此单射，不靠「同列声明类型固定」侥幸；③ **列顺序写死不读 `PRAGMA table_info`**
    ——全新 v12 库与 v1 一路 ALTER 上来的 v12 库列序不同，拿它当契约就是同一份数据两台机器两个 fp。
  - 参与同步的表恰好 6 张（`document`/`variant`/`note`/`ink_layer`/`scratch_pad`/`meta`）；
    🔴 **`location` 不在其中**——「文件在哪」是设备本地事实，同步它 = 制造满屏假「路径失效」。
  - `meta.workspace_id`（`LibraryStore.ensureWorkspaceId`，两端各一份）：**懒建**，不塞进 `migrate`
    ——绝大多数工作区永远不会做镜像。名字会改、路径必变，只有它能让镜像认出源盘。
  - 验证：`spike/mirror-fp-test.swift` 50/50、`spike/store-test.swift` 42/42、
    安卓 `./gradlew test` 66/66（含 `MirrorFpTest` 6）、`xcodebuild` + `assembleDebug` 均过。
- ✅ **M2 建镜像**（2026-08-30）：Mac `Sources/Store/MirrorStore.swift`+`MirrorBuilder.swift`
  ↔ 安卓 `local/mirror/MirrorStore.kt`+`MirrorBuilder.kt`。
  - **拷库用 `VACUUM INTO` 而不是 cp 那三个文件**：`.sqlite`/`-wal`/`-shm` 分三次拷不是原子的，
    中间还有写入就拿到一份撕裂的库；`VACUUM INTO` 在一个读事务里生成，天生一致还顺带压缩。
    安卓 minSdk 26 但它要 SQLite 3.27（API 30）→ 留了「checkpoint + 整文件拷」兜底，
    **那条路只因为建镜像独占 `StoreQueue` 线程才安全**；30+ 上用例断言必须走 VACUUM，不许悄悄退到兜底。
  - **工作区内副本保持同一条相对路径**拷过去 → 镜像库里那行 location 原样有效，一个字都不用改；
    只有外部文件才内化（补一条 `in_workspace=1`，原来那条留着不动）。
  - **镜像必须换一个自己的 `workspace_id`**：拷出来的副本原样带着源库的 id，不换的话
    「扫一圈盘按 workspace_id 找源」会把镜像自己也认成源。
  - 借出记录 JSON 是**跨端契约**：键按字典序 + `last_synced_at` 为空时**省略整个键**
    （Swift `JSONEncoder` 对 nil Optional 的默认行为，写成 `null` 两端字节就对不上）。
    向量 `spike/mirror-checkout-vector.json` 由 Mac 生成、安卓逐字比对。
  - 验证：`spike/mirror-build-test.swift` 50/50；安卓 `MirrorBuilderTest` 4/4（模拟器 API 36）。
    ⚠️ 同一次 `connectedDebugAndroidTest` 里另有 **30 条既有失败**（`LibraryStoreTest`/
    `ScratchPadStoreTest`/`StoreQueueTest`/`StrokeEchoTest`）——它们要 `/sdcard/Download/内覆盖.unrd`
    这个真工作区 fixture + 全盘权限，**换台干净模拟器就必然全红**；`git stash -u` 跑过基线，
    改动前后同样是这 30 条。
- ✅ **M4 三方 diff + 干跑预览**（2026-08-30）：Mac `MirrorDiff.swift`+`MirrorReport.swift`
  ↔ 安卓 `local/mirror/MirrorDiff.kt`+`MirrorReport.kt`。**只算不写**——干跑是这个功能唯一的
  安全闸，它必须能在完全不碰任何库的前提下跑出完整结论；算和写混在一起，预览就永远只是
  「大概会这样」。四条要点：
  - 判定表**每一格都有用例**，包括「什么都不该做」的那几格（两边都删 / 改成一样了 /
    各自新增了一模一样的行）——漏判成「要删」和漏判成「不管」一样致命。
  - **一端删、一端改 → 保留「改」**（不丢用户数据优先）；两端都改 → `note`/`scratch_pad`
    按 `updated_at` 取新的，没有时间戳列的表保留源盘并报告。LWW 直接**比字符串**：
    时间戳是定宽 UTC，不引入日期解析也就没有「两端解析器对同一个串给出不同结果」这条缝。
  - `document.last_opened_at` 不进指纹，但 `Plan.lastOpenedMerges` 单独带出「两端取较晚的」
    交给 M5。这条规则不在主流程里，只写在文档里迟早被漏掉，所以让它出现在 Plan 的类型上。
  - **报告里一行 id 都不许出现**：按「类别 + 增/删/改」聚合，明细按书分组（用户是按书记事的，
    不是按表）。删除那条 `row` 是 null，所以 docId/kind/page 在产生 Change 时就取下来存着。
  验证：`spike/mirror-diff-test.swift` 42/42（含真库端到端）、安卓 `MirrorDiffTest` 8 项（JVM）
  + `MirrorSyncTest` 2 项（插桩，模拟器 API 36）。
- ✅ **M3 镜像 UI**（2026-08-30，**观感待真机**，见方案 §12.1 第 5~6 条）：
  - Mac：侧栏工作区菜单按「是不是镜像」**互斥**地给一条动作（制作离线镜像… / 同步到源盘…），
    菜单标签换 `externaldrive.badge.timemachine` 图标；没带 PDF 的书灰一档 + 换图标
    （**不隐藏**——隐藏了用户会以为笔记也没了）；两张 sheet 全是系统标准控件
    （`Sources/Views/MirrorSheets.swift`）。文案已补 zh-Hans + en 各 15 条。
  - 安卓：书库右上「更多」同样互斥给一条动作；统计行加「离线副本」/「借出 N 份」；没带 PDF
    的书文案改成「没有离线——插回源盘才能看」（原来那句「重新添加/重新关联」会把用户引到
    一条根本不该走的路上）。流程全在 `local/mirror/MirrorUi.kt` 一处——两条流程都要
    「开连接 → 后台跑 → 关连接 → 刷界面」，抄两遍必然有一遍忘了关连接（U 盘就拔不掉了）。
  - 找源盘**按 `workspace_id`**，不认路径也不认名字（路径换台设备必变、名字会被改、盘上可能
    同时躺着源和同名镜像）；候选里必须排掉「带 `mirror_of` 的」，否则会把镜像自己认成源。
  - 同步面板**刻意不给「应用」按钮**（M5 才做）：给一个点了没反应的按钮比没有更糟。
- ✅ **M5 应用合并**（2026-08-31）：Mac `MirrorApply.swift` ↔ 安卓 `local/mirror/MirrorApply.kt`。
  这是整个功能里**唯一会大批量改用户数据**的一段，四道保险：合并前把源库整份备份出来
  （`VACUUM INTO`，留最近 3 份，失败即中止——没有备份就动手是把"最坏情况"从回滚变成没得救）/
  每一侧的行操作在一个事务里 / 文件搬运在事务外、幂等可重入 / 基线**两侧都成功了才重算**。
  - **先源盘后镜像**：源盘在可移动介质上，中途被拔的概率更高，让它先落地、失败也只是回滚到原样。
  - 🔴 **半途而废不需要补偿逻辑**。跨库事务不存在，所以「源盘写了、镜像没写」是可能的；但下次
    跑 diff 时那些已落到源盘的行会变成「两端相对基线都改成了同一个样子」→ 判为无操作，
    没落的照常算出来。**这个性质只在「基线最后才重算」时成立**，所以那一步的位置不能动。
  - **一侧内先删后插**：反过来会撞 `variant.content_hash` 的 UNIQUE（「删掉旧版本、换一份同内容
    的进来」在同一批里就是先插会重）。插入按表依赖序（document 在前）。
  - 🔴 **外键孤儿丢掉并计数，不让它炸整次同步**：「源盘上把这本书删了、同时我在镜像上给它写了
    新笔迹」——那条笔迹推到源盘时父文档已经没了，不过滤就是整个事务回滚、整次同步失败。
    宁可丢一行并报出来，也不要让用户面对一个「点了没反应、也不知道为什么」的同步。
  - UI：预览页确认一次、弹窗再确认一次才执行；**用的是干跑给用户看的那一份 Plan，不重算**
    ——重算就意味着「用户看到的」和「实际做的」可能不是同一件事。
  - `LibraryStore` 加 `withMirrorDB`/`withMirrorDb`（作用域式交出连接）：本类「所有读写走 DAO」
    的**唯一例外**，因为合并要对任意表做通用 upsert/delete。名字里带 mirror 便于 grep，
    **别拿它当"拿连接的口子"用**。
  - 验证：`spike/mirror-apply-test.swift` 33/33（双向合并后两端逐行一致 / 备份是合并前的样子 /
    半途而废自愈 / 孤儿不炸 / 文件补齐幂等）；安卓 `MirrorApplyTest` 4 项，**模拟器 API 36 与
    真机小米 Pad 6（Android 14）各 10/10**（含 Builder/Sync/Apply 三个类）。
- ✅ **M6 多镜像**（2026-08-31）：一个源盘 + 两份镜像 A/B 轮流同步。
  方案 §8.4 原本只是断言「多镜像天然可用」；**这一轮是去验它，不是去复述它**——结果是
  机制确实成立，但顺手实测出一个会让整次同步失败的真 bug。
  - 验过并成立：二手传播（A 改/加的东西经源盘到 B）、**删除的二手传播**（A 删的 B 也跟着删，
    这条最容易漏）、跨镜像冲突按时间戳收敛（A 先同步、B 后同步，B 的基线还是老的 →
    源盘那份对它就是「变过了」→ 判成两端都改 → LWW）、两条借出记录各自记账互不覆盖。
  - 🔴 **实测抓到的 bug**：同一份 PDF 在两份镜像上**各自入过库**时（内容 hash 相同、
    variant id 不同），推到对面就是 `UNIQUE constraint failed: variant.content_hash`
    → 整个事务回滚 → **整次同步失败**，而且抛给用户的是一句看不懂的 SQLite 报错。
    修法与「外键孤儿」同一条原则：**跳过并计数**（同 hash 即同内容，那一行本来就是冗余的），
    结果里明说跳过了几个版本、该怎么处理。
  - ⚠️ **已知取舍（用例把它钉死了）**：被跳过的那条**不会自动收敛**，下次干跑还会算成待写。
    这是刻意的——「这两本是不是同一本书」是用户的语义判断，书库里有现成的
    「关联为同一文档」，同步这一步不该替他决定。用例里专门断言「它仍然待写」，
    哪天有人"顺手修好"它，得先来改那条用例。
  - 验证：`spike/mirror-multi-test.swift` 27/27；安卓 `MirrorMultiTest` 3 项。
    安卓插桩 13 项（Builder 4 + Sync 2 + Apply 4 + Multi 3）**在真机小米 Pad 6
    （pipa, Android 14）上全绿**。

- ✅ **M7 交互重做：副本自动维护，不再是「一个复制备份」**（2026-09-01，Mac）。
  用户否决了 M3 那版的形状：**建完副本就进最近列表 → 源和副本并排两条 → 用户自己挑**
  ——「那为什么不手动复制呢？」。分界线是**副本要自动维护**，用户永远只面对一个工作区。
  - 最近列表列的是**工作区身份**（`RecentWorkspace` = `workspace_id` + 源盘路径 + 本机副本路径），
    点一条由 `WorkspaceRegistry.resolve` 当场定用哪份：源盘在开源盘，不在开本机副本。
    副本**从不单独出现**在最近列表 / Dock 菜单 / 文件→最近打开（系统那份「最近使用的文稿」
    也只喂源盘路径）。冷启动同理：盘没插就开副本，不把人扔回默认工作区。
    老数据迁移 `recentWorkspaces`→`recentWorkspacesV2`，并排的副本条目**并入**源那一条。
  - 入口从一次性「制作离线镜像…」改成**持续开关「保留离线副本」**；关掉 = 连副本一起删
    （确认一次 + 说清未同步改动会一起没 + 抹掉源库那条借出记录）。
  - **自动收口**，只提示不打断（用户拍板）：在副本里且源盘插上 →「源盘已连接 · 同步并切回」；
    在源盘上且副本有改动 →「离线期间有 N 处改动 · 同步回来」。后者要从源盘侧发起，
    新增 `mirrorDryRunFromSource`/`mirrorApplyFromSource`——与镜像侧**角色对调、逻辑一份没多写**。
  - 镜像位置改成不让用户挑（固定 `~/Library/Application Support/UniReader/Mirrors/`），
    躲开 iCloud「桌面与文稿」的上传与 dataless 驱逐——那会让副本**当场打不开**，而它正是
    「盘不在时唯一能读的那份」。
  - 🔴 **顺带修掉两个真 bug**：① 点「同步到源盘…」**必崩**——`MirrorSyncSheet` 写了
    `@EnvironmentObject var registry`，但全项目从没注入过 `WorkspaceRegistry`；
    ② 备份文件名只带毫秒时间戳，**同一毫秒内连做两次合并就撞名**，而 `VACUUM INTO` 遇到
    已存在文件是直接报错 → 整次同步中止、抛给用户一句 `output file already exists`
    （`spike/mirror-apply-test.swift` 以前是**随机挂**的，现在连备份三次把它钉死；安卓同修）。
  - 验证：Mac spike store 42 / fp 50 / build 50 / diff 42 / **apply 37**（连跑 5 次稳定）/ multi 27；
    安卓 JVM 74/74、插桩镜像相关全绿（`StrokeEchoTest` 那条是**既有失败**，
    `git stash -u` 空树跑一遍照样红）。
  - **待真机验**：最近列表拔盘/插盘的图标与自动选副本是否如实；两条提示条出现时机；
    「保留离线副本」开关取消时删得干不干净。
- ✅ **M7.1 用户实测第一份干跑报告 → 抓到两个真 bug**（2026-09-01，两端同修）。
  现象：在一份**几乎没动过**的副本上点同步，收到「冲突 1 条：**的**一条文档信息：两端都改过，
  这张表没有时间戳可比 —— 保留了硬盘上那份」。
  - 🔴 **阅读进度被静默丢弃**：`document` 表带 `read_page/read_frac/read_zoom/read_hfrac`，
    两端各翻过同一本书就判成「两端都改」；而这张表**没有 `updated_at`**，原先 `lww = nil`
    ⇒ 一律保留硬盘那份 ⇒ 离线副本上读到哪儿，同步一次就没了——与方案 §13
    「阅读进度跨镜像同步」直接矛盾。改用 **`last_opened_at` 当 LWW 依据**（NOT NULL 一定有值，
    语义正好：谁最后打开过这本书，谁那份进度更近）。
  - 🔴 **只差进度不该报成冲突**：两端各读过同一本书是正常使用，不是要用户裁决的事。
    现在先比「除进度列外的指纹」，一致就照常按 `last_opened_at` 选一边写但**不进 conflicts**，
    只在报告里说一句「另有 N 篇文档两端都读过，阅读进度取最近读的那次」。
  - 报告两处措辞 bug（都在那张截图里）：① `document` 表**自己那行没有 `document_id` 列**
    → `Change.docId` 是 nil → 被归进「工作区级设置」，改为按主键归到它自己那本书名下；
    ② 查不到书名/页码时拼出「**的**一条…」断头句，现在没有定位信息就直接说是哪张表的事。
  - 验证：Mac `mirror-diff-test` 53/53（新增 6 条钉死新行为）、安卓 JVM 75/75。

---
## 笔记卡片：宽公式把正文挤歪 + 卡片可拖动 / 改大小（2026-09-16，Mac，接在公式渲染之后）

用户附截图：「悬浮渲染有问题」（气泡里正文整体右移、右边被裁，公式左右都露出去；编辑器里正常），并提
「卡片要么做一下可以拖拽边缘调整大小吧，然后记录下大小，同时卡牌的朝向也可拖拽，不按照空间来锁死」。

### 宽公式把整篇挤歪（先修）

- **离屏复现**（引擎 + 同配置 + 宽 250pt，与截图量出来的一致）后 dump 视图几何：`NSTextView` 宽 250 没问题，
  但 `usageBoundsForTextContainer` 的 x 变成 **-28.5**，所有行的 `_NSTextViewportElementView` 跟着右移 28.5。
  根因：块公式是一行居中的图，图宽过文本容器 → TextKit 2 的使用范围左边变负 → **整篇**往右挪。与 `\displaystyle`
  无关（行内样式时 x = -17，同病）；编辑框 600 宽放得下所以看着正常。
- **修法**：宽过容器的公式按比例缩到正好放下（`FittedLatexRenderer`，行内公式一起缩）。渲染接口拿不到视图宽度 →
  宽度跟着**每个视图自己的配置**走（`MarkdownNoteReader` 显式传 `width`；编辑框量自己的宽）；宽度变了要让引擎整篇重排，
  引擎唯一的公开开关是 `images.fingerprint()` 变化 → 塞一个只报宽度当指纹的 `WidthKeyedImageProvider`。
  离屏实测 400→250→180→400 每一档 usage.x 都是 0；**对照组**（指纹钉死）250 / 180 两档照样右移 → 指纹是必需的。
- 气泡的 `width` 必须显式传、不能自己量：自己量第一帧没宽度，公式没缩，整篇先歪一帧再归位（阅读区零闪烁纪律）。

### 卡片可拖动 / 改大小（文字笔记 + 图片笔记）

四处拍板：存进笔记本身（payload）；高度是**上限**（内容短就收、长就在卡片里滚——初版是裁掉，用户随后改成滚动，见下面「第二轮」；
取代「最多 14 行」）；**关闭卡片里的文字选择**，
按住卡片任意处拖 = 移动、四边四角 = 改大小；文字 / 图片笔记都做。

- **数据**：`NoteCard { dx, dy, w?, h? }`（`TextNoteModel.swift`），`TextNote.card` / `ImageNote.card`，payload 键 `card`，
  旧数据缺键 = 自动规则。`dx/dy` = 卡片左上角相对**图钉中心**（拖图钉、框选移动笔记时卡片跟着走）；任何一次拖动都把位置钉住
  （否则改宽时自动规则会把卡片从图钉右边翻到左边）。单位 = 固定口径的点，跟页缩放口径 × `Metrics.unit`（页宽 ÷ 参考页宽，
  与宽度设置同一个折算）。卡片钳在本页内（出了页会被下一页的元胞盖住）。
- **几何纯函数** `NoteCardDrag.card(translation:…)` + `NoteCardZone.at`（边 5pt、角 12pt）：拖左 / 上边时对边不动；拖上边超过
  内容高时上限照记、可见高收到内容高、下边仍不动。`spike/note-type-test` 加 15 项（53/53）。
- **视图**：`NoteCardInteraction`（`NoteBubbleView.swift`，两种气泡共用）——手势取页元胞的具名坐标系
  （`PageCellView.cardSpace`，卡片自己在动，取自己的坐标系会自激）；位移 ≤2pt 算单击；拖动中写 `live` 预览，松手提交与清预览同一拍；
  指针用系统样式（`.frameResize(position:)` / `.grabIdle` / `.grabActive`）。悬停预览、非文字工具、草稿纸盖着时不可拖。
- **正文不吃鼠标**（`MarkdownNoteReader` `.allowsHitTesting(false)`）：链接改由卡片单击去开（`NoteLinkClick`：按事件位置找只读
  `NSTextView`，核对字形框真的罩住鼠标再取 `.link`）。图片卡片的「点缩略图看原图」与右键菜单挪到整张卡片上（缩略图自己挂点击会抢拖动）。
  右键加「复制笔记正文」（选不了字的补偿）与「恢复卡片默认大小和位置」。
- **让位**：阅读区容器上的手势全是 simultaneous，按在卡片上照样收得到（合成事件实测：外层拖动手势收到 10 次回调）。
  卡片把此刻位置报进 `Scratch.cardFrames`（普通属性，不发通知），`ReaderSurface.cardHit` 命中则拖选 / 单击 / 双击选词 /
  本机落墨 / 框选 / 图钉拖拽都让位。
- **提交**：`commitCard` 就地改笔记 + bump `updatedAt`，进撤销栈（移动记「移动」、改大小记「调整大小」）；不广播平板。
- **合成鼠标事件实测**（离屏窗口里的真 `NoteBubbleView`，12 项全过）：点铅笔按钮照常响应、按住正文拖移动、拖右边改宽、
  拖下边超过内容可见高不变、往上收被裁、拖左上角右下角不动、单击链接认得出 URL、单击非链接处卡片不动、置 nil 回到自动位置。
- **没做**：网页 / 安卓不认 `card`（记进 `TODO.md`）；指针样子与真实手感只能用户实测。

### 第二轮（同日，用户实测后三条）

1. **「拖拽笔记的时候，会触发文字选择」**：容器的拖选在还没起手时，**每个回调**都拿按下点问 `cardHit`；而卡片拖动中一直在报
   **活位置**——卡片跟手走远，按下点就落到卡片外面，拖选随即在底下起手。合成事件复现（移动 +60 起手 1 次、向内拖左边 40 起手 1 次）。
   修：`NoteCardInteraction` 拖动中不报新位置、报的一直是按下时那块，松手补报一次。复测起手 0 次；空白处拖选照常。
2. **「不允许渲染窗覆盖自己的图钉」**：`NoteCardPin`（纯函数）——禁区 = 图钉中心 ± (图钉半径 + 间隙)。移动压进去就**整块挪开**
   （图钉右 / 左 / 下 / 上四个贴边位置钳进页内后，取不压住且离原位最近的）；改大小时拖的那条边**停在禁区边上**；画的时候
   `NoteBubble.placed` 再兜一道（存着的旧位置、拖图钉后、自动规则在窄页上钳进页内时都可能压住）。spike 加 7 项（60/60）。
3. **「高度不够时，内容滚动」**（推翻初版的「裁掉」）：卡片正文包进 SwiftUI `ScrollView`，放得下时 `.scrollDisabled`（常驻容器只切禁用：
   按放不放得下换两种容器的话，拖动改高度跨线时正文引擎视图会被重建）；图片卡片同样，并按滚动距离换算「点缩略图看原图」的位置；
   去掉了初版「上限比内容矮先压缩略图」那段。
   - 离屏查命中链：卡片上的点落在**卡片自己的** `HostingScrollView` 里（正文不吃鼠标不影响）。中途一度以为要垫一层吃命中的透明底，
     是调试代码把 `hitTest` 的坐标系传错了（要父视图坐标，我传了自身翻转坐标）；最小对照实验证实不垫也命中，已删。
   - ⚠️ **滚轮本身没验证成**：合成的滚轮事件连空白页面都滚不动（对照组也失败），滚不滚、放得下时滚轮会不会穿透到页面，只能用户实测。
4. **「文字超出左边边界了」**（接着第 3 条）：macOS 上**可滚动**的 SwiftUI `ScrollView` 给竖滚动条让位——底层 `HostingScrollView`
   比给它的 frame 宽 17pt、往左多出 8.5pt，内容贴它左边放 → 正文越出卡片左边 8.5pt、右边被裁。系统是浮动滚动条也一样；禁用滚动时不会，
   所以只有溢出的卡片中招。纯 SwiftUI 最小对照量了七种写法：只有 `.scrollIndicators(.never)` 能消掉（`.hidden` /
   `contentMargins(for: .scrollIndicators)` / `scrollEdgeEffectHidden` 都不行）。两种卡片都改成 `.never`（代价：卡片里没有滚动条，
   靠底部被截断看出还有内容）。复测卡片宽 90 / 160 / 280 正文左边差都是 0。**以后在阅读区里再用 ScrollView 记得这一条。**
5. **「滚动区域即使到头了，也不滚动页面，避免意外滚动」**：SwiftUI 滚动容器没有「不向外传」的开关，就在阅读区已有的滚轮监视器
   （⌘ 缩放那个，`installWheelMonitor`）里拦：指针在卡片上（`cardHit`）+ 命中点最近的滚动视图是**嵌在阅读区里的那一层** + 可滚 +
   这个方向已到头 → 返回 nil 吞掉。到没到头读 AppKit 滚动视图当前位置（同步，不用晚一拍的 SwiftUI 滚动几何回调）。
   纯横向吞掉；零位移的手势开始 / 结束帧放行（别打断滚动视图的手势跟踪）；放得下的卡片不拦；⌘ 按住时不拦（缩放优先）。
   判定抽成 `NoteCardWheel.shouldSwallow`，离屏按真视图树程序化设滚动位置验了 10 项（顶 / 中 / 底 × 上 / 下、横向、零位移、
   不在卡片上、页面空白、放得下的卡片）。真滚轮的手感仍只能用户实测。

## 笔记 Markdown 的 LaTeX 公式渲染 + 编辑框放大（2026-09-16，Mac）

用户：「做一下文字笔记 markdown 的 latex 公式渲染」；做的过程中附截图补一条「编辑窗口也需要大一些，现在很难输入」
（380×170 的框里写两行 `$$\frac…$$` 就挤满了）。

- **依赖**：引擎本来就有 `LatexRenderer` 接口和现成的 `MarkdownEngineLatex` 产品（`project.yml` 早留了「用到再加」），
  这次加上；传递依赖 SwiftMath 1.7.3（MIT，~7MB 数学字体进 app 包）。它在首次解析引擎时就已经拉到
  `build/dev/SourcePackages/` 里了，所以**没有联网**——编译加了 `-disableAutomaticPackageResolution` 确认这一点。
- **语法**（引擎定的，不是我们定的）：`$…$` 行内（带防误判：`$5` 这类金额不算公式）、单独成段的 `$$…$$` 块（可跨行）。
  `\(…\)` / `\[…\]` 不认。编辑器里光标不在公式里显示渲染结果、光标进去显示源码；气泡里始终显示渲染结果。
  SwiftMath 不认的命令（实测 `\begin{cases}`）原样显示源码，不会出空白。
- **`NoteLatexRenderer`**（`MarkdownNoteEditor.swift`）：套在 `SwiftMathBridge` 外面，管两件事。
  ① **块公式按块排版**：bridge 对所有公式一律用行内样式（分式缩小、∑ 上下限在旁边），引擎调渲染接口时块和行内传的参数
  一模一样，分不出来（第一版交付时就是这样，用户追问「`$$` 应该是块吧，为啥是 inline」）。改成自己记一张块公式表：
  气泡 / 编辑器的 `body` 登记源码里的 `$$…$$`（扫法照抄引擎分词器）；编辑器里新敲 / 粘贴的块，因为引擎是先排版、
  后**异步**回写 binding，查不到时从 key 窗口第一响应者那个 `NSTextView` 当场扫；命中就前面加 `\displaystyle`。
  比对去掉全部空白。代价：行内公式与某个块公式内容完全相同时也按块排（只有含分式 / 求和这类才看得出，接受）。
  ② **缓存封顶**：（公式, 字号）超过 160 种就整个清缓存。bridge 的缓存从不淘汰，而气泡开「跟页缩放」时字号随缩放连续变，
  缩放几个来回每条公式能攒几十张图。
- **气泡公式颜色**：`readerTheme` 的 `latexLightModeText` / `latexDarkModeText` 都钉成正文色——bridge 判深浅色看的是
  **key 窗口**的外观，不看气泡被钉成的浅色；系统深色时会挑白色，压在纸白气泡上就看不见了。
- **编辑框**：sheet 420 → 640 宽，编辑区 380×170 → 满宽 × 340。
- **MCP**：`add_note` 的 `text` 说明写明公式语法（免得 Agent 写 `\(…\)` 渲染不出来）。
- **样张工具**：`spike/latex-look.swift`（用 Debug 产物的 .o 链接，出 PNG；某条公式能不能渲染先拿它看）。
- **没做**：网页 / 安卓气泡照旧显示源码（记进 `TODO.md` 那条「气泡画的是 Markdown 原样源码」）；Inspector 列表 / 悬停提示
  用 `NoteMarkdown.plain`，公式在那里是源码。

## 高亮画线 / 画框 + 高亮转文字笔记 + 文字笔记多色（2026-09-16，Mac，用户三条）

用户原话：「添加画框，类似高亮只有边」「高亮补充为文字笔记，文字笔记支持多色高亮」「高亮支持画线模式（原来小写 h，画线大写 H）」。
四处拍板：画框**每行一个框**（不是整段包围盒）；画框默认键 **⌥H**；「补充为文字笔记」= **转换**（原高亮条目消失）；
文字笔记设了显式颜色**图钉仍按类型色**，颜色只管选中文字上的标记。

- **数据**：`HighlightStyle`（`fill` / `underline` / `box`，定义在 `TextNoteModel.swift`——spike 都编它、不编 `HighlightModel.swift`）；
  `Highlight.style` 与 `TextNote.style` 各一份，payload 新键 `style`（小写串），旧 payload 缺省 `fill`，零迁移。
  `TextNote.color`（payload 早有、从没用过）启用：nil = 按类型色 / 通用暖黄。schema 不变（都在 `note.payload` JSON 里）。
  `spike/note-type-test` 加 11 项（38/38）。
- **渲染**（`PageCellView.markNorm`，高亮层与笔记层共用）：铺色照旧；画线 = 每个行框底边一条线，粗细约行高 7%（下限 1.5pt），
  落在底边略下免得压到下伸部；画框 = 每个行框描 1.5pt 圆角边。画线 / 画框用基色 × 0.9（`Highlight.strokeOpacity`），
  不像铺色那样降到四成。
- **入口**：右键菜单「高亮 / 画线 / 画框」三个子菜单各带四色；阅读区单键 `h` 铺色 / `⇧H` 画线 / `⌥H` 画框
  （`ShortcutAction.underlineSelection` / `.boxSelection`，设置页可改），三者共用一份「上次用过的颜色」；
  高亮气泡里加画法三选一（segmented）+「添加批注…」；Inspector 高亮右键加「标记」子菜单，条目图标随画法。
- **高亮 → 文字笔记**（`beginNoteFromHighlight`）：`PendingNote` 带 `color / style / replacesHighlight`，编辑器保存时
  `commitNote` 落笔记并删原高亮（高亮不进撤销栈，与删除高亮同口径）；取消则什么都不动。
- **编辑器**（`NoteEditorSheet`）：选区注解多一行「标记」= 色点（第一枚跟随类型色 + 调色板四色）+ 画法三选一；点注解不给这一行。
  `onSave` 从三个参数改成一包 `NoteEditorOutput`。
- **MCP**：`add_highlight` 加可选 `style`；`list_annotations` 高亮 DTO 带 `style`、笔记 DTO 带 `style` 与（设了才有的）`color`。
- **没做**：安卓模式1 直接读 payload，`style` 与笔记 `color` 它都不认——画线 / 画框在那边暂按铺色画，笔记显式颜色被忽略，
  记进 `TODO.md` 已知欠账。Inspector 高亮右键没有「添加批注…」（编辑器挂在阅读区那一层，Inspector 没有开它的路）。

## `unireader://` 链接 + MCP 带 `link` + Obsidian 导出 skill（2026-09-14，Mac，分支 `worktree-url-scheme`）

起因：2026-09-13 用户问「怎么和 Obsidian 打通」。分析给了四条路（App 内导出 / 自动同步 / MCP 让 Agent 搬 / Obsidian 插件读库），
用户拍板：**「回跳很重要，优先做；已经做了 Agent 接入，不考虑导出了，Agent 可以帮我们；导出部分提供一套 skill/提示词」**。

- **链接契约**（`URL-SCHEME-PLAN.md §1`）：`unireader://open?ws=<.unrd 路径>&wsid=&doc=&hash=&page=<1 起>&frac=<0…1>&note=<笔记 id>`，
  每个参数可省；`note` 给了就跳到那条并展开气泡（文字 / 图片笔记）。生成时按 RFC 3986 unreserved 严格编码——
  链接的归宿是 Markdown 的 `[text](url)`，空格 / 括号 / `#` 漏一个就断。
- **落地**：`Info.plist` 注册 scheme；`DeepLink`（纯 Foundation，spike 34 项全绿）+ `DeepLinkRouter`；`AppDelegate.application(_:open:)`
  按 scheme 分流、冷启动缓冲；`DocSession.revealNoteID` → `PageStreamView.revealNote`（`onChange` 挂 `canvasRoutes` 层——
  `surfaceBody` 那条链再加一个 onChange 就超类型检查器时限，又踩一次）。
- **与 MCP 合流**：`MCPFacade.openDocument` 的中段抽成 `AppDelegate.showDocument`（🔴 唯一一份「找标签 / 挑窗口」）；
  `documentDTO` / `list_annotations` 每条 / `get_current_view` / `open_document` / `goto` 都带 `link`，`get_state.app.deep_link` 是格式说明。
- **导出**：`skills/unireader-obsidian-export/SKILL.md`——Agent 用 `list_annotations` 读、写成「每篇一文件 + frontmatter + 生成区标记 +
  callout + 末尾回跳链接」，图片从 `<工作区>/Images/<sha>.*` 复制（不碰 `library.sqlite`）。
- 实测清单在 `URL-SCHEME-PLAN.md §6`。

## 内存（2026-09-13，Mac：「连接设备后 macOS 内存飙升」→ 窗口色彩空间改 sRGB，用户实测「暴降」）

用户报连平板后内存飙升。对正在跑的进程 1 秒一采（`footprint` 分类 + 平板日志增量 + 阅读区 body 重算次数），
两轮重连平板实测，最后一轮带 `MallocStackLogging=1` 抓分配栈。

### 实测时间线（第一轮，Debug 包，窗口在外接 LG 1x 屏）

| 时刻 | 发生什么 | footprint | 我们的页图 (VM_ALLOCATE) | CoreAnimation | MALLOC_LARGE |
|---|---|---|---|---|---|
| 平板连上（补发全量） | | 990 → 921 MB | 254 | 245 | 194 |
| 平板滚动、Mac 跟随（视图树每秒重算 40~56 次） | | ~1.0–1.1 GB | 254→329 | 245→320 | 129~170 |
| **平板持续滚动、没取页图**（pad 日志 +0）| 10 秒 | 1353 → **1605 MB** | 350↔392（稳定） | 341↔383（稳定） | **314 → 598，每秒 +42 MB** |
| 平板取了一批页图 | | 1191 | 504 | 403 | **152（一下全放了）** |

峰值 1678 MB。平板取页图那条路（渲 2160px → JPEG → NSCache）不是主项——涨得最凶的 10 秒里一张都没取。

### 根因：页图 sRGB ≠ 窗口后备存储的色彩空间 → SwiftUI 显示每张页图都要 CG 整张重画转色

`vmmap`：`DefaultPurgeableMallocZone` 里一块块 43,728,896 B（= 2800×3902×4 页图尺寸）、非 volatile、
不随页图释放。`malloc_history` 栈（4 块全同）：

```
-[_SwiftUIProxyImage prepare]（com.apple.SwiftUI.prepare-image 队列）
→ CA::Render::copy_image → CA::Render::create_image_by_rendering
→ CGContextDrawImage → ripc_AcquireRIPImageData → CGSImageDataLock → img_data_lock → create_image_data_handle
```

`sample` 看到 `img_data_lock` 下面是 `img_raw_read → provider_for_destination_get_bytes_at_position
→ memmove / CGColorTransformConvertUsingCMSConverter → vImage`：**CG 在给整张页图做色彩空间转换**，
转换结果挂在源图上当缓存（攒到 CG 自己的上限才丢），这条线程在 3 秒采样里几乎满载。
窗口 `colorSpace` 默认 = 所在显示器的 ICC（Color LCD / LG HDR WFHD），页图是 sRGB，两者不等，
CA 就不能直接引用我们的缓冲，改用 CG 重画（产生 CA 副本）+ 挂转换缓存。**每张页图三份**。

对照探针 `spike/window-colorspace-probe.swift`（SwiftUI 离屏、阅读区同构：ScrollView + scrollPosition 50Hz
推滚 + 每秒换页；两块屏都跑）：窗口 `colorSpace = .sRGB` → 只剩我们的 mmap，**CA 副本消失**；
默认 / Display P3 / Generic RGB → 每张多一份 CA 副本（栈同上）。探针里复现不出 app 那块转换缓存，
但同为 sRGB 之后根本不走重画，两笔一起没了。

### 改动

- `ReaderWindowController` / `RefWindowController`：建窗时 `win.colorSpace = .sRGB`。显示器色彩匹配改由
  窗口服务器合成时做（GPU），观感不变；代价是窗口画不出 sRGB 之外的广色域（本 app 用不到）。
- **用户实测（同日）：「内存暴降」。** 新包连平板滚 15 秒后 `footprint` 185 MB（峰值 344 MB，改前 1.0–1.7 GB）、
  `CoreAnimation` 3.5 MB（改前 ≈ 页图总量）、页图尺寸的 purgeable 块 0 个。
- `PageRenderEngine.copiesPerImage` 2 → **1**（CA 副本没了；按 2 计同一个上限只装得下一半的页），
  `MemoryDiag.bitmapFootprint` 与设置页「存活页图」行跟着去掉「+ CA」那一截。
  🔴 **2026-09-10 那条「CA 副本跟着 CGImage 走」的结论其实就是这个转换副本**，不是 CA 的必然开销。

### 教训（进 memory：`unireader-memory-profiling` 第 6、7 条）

「谁分配的」这种问题直接 `MallocStackLogging` + `malloc_history`（终端起 app，`open -a` 起的附不上），
别再拿离线探针猜——这次探针试了六轮都复现不出，一轮 `malloc_history` + `sample` 就定了。

### 顺带看到、没动

平板滚动时 `foreignAnchor`（`@Published`）每个 scroll 事件写一次 → 整窗视图树每秒重算 40~56 次
（ws 日志里那串「阅读区状态释放」= 每次重算扔掉的临时 `Scratch`）。CPU 账，记在 TODO 已知欠账。

## 快捷键映射 + ⌘⇧A/参考窗开关（2026-09-13，用户四条，第四条撤回）

1. **快捷键可改**（`Sources/App/Shortcuts.swift`）：`KeyCombo`（键 + ⌘⇧⌥⌃；存储串 `"shift+cmd+a"`，显示 `⇧⌘A`）、
   `ShortcutAction`（默认值都在 `defaultCombo`）、`Shortcuts`（只存改过的那几条到 UserDefaults `shortcutOverrides`，
   空串 = 清掉；改动发 `.shortcutsChanged`）。主菜单（`MainMenu`）可改项按动作登记，收到通知就地重设 key equivalent、
   不重建菜单；阅读区单键监视器（`installToolKeyMonitor`）每次按键现查 `readerAction(for:)`。设置多了一页「快捷键」
   （`ShortcutsSettings`/`ShortcutRow`：点按钮录制、Esc 取消、⌫ 清掉、改过才出现「恢复默认」+ 全部恢复默认；
   录制时本地监视器把键吃掉，否则 ⌘Q 之类会先被菜单接走）。冲突：撞上别的动作或基础命令一律拒绝并在行下说明；
   菜单类动作要求带 ⌘/⌥/⌃（功能键除外）——裸字母挂上菜单在文本框里打字也会触发。
   **不进映射表**（用户「基础的比如复制粘贴就不用支持设置了」）：App/文件/编辑/窗口菜单的基础命令，以及数字键 1–9 选笔。
   两处行为变化：① `n` 没选区时不再当「书写」用（以前 `b`/`n` 都是书写，现在 `n` 只归「选中文字加批注」，`b` 书写）；
   ② 阅读区单键可以录成带修饰键的组合，监视器照样只在没有文本焦点时吃。
2. **⌘⇧A 浮窗模式改成显示 ⇄ 隐藏**（`AIPanelWindowController.toggle`）：隐藏 = 摘掉子窗口关系 + `orderOut`，网页与对话原样
   留着（探针实测 `orderOut` 不触发 SwiftUI `onDisappear`，`releaseHost` 不会跑）；再按回来并重新吸附。内置模式照旧展开/收起。
3. **参考窗开关快捷键**：视图菜单新增「参考窗」（默认 ⌥⌘R，通知 `.toggleRefWindow`）；阅读窗是 key 时走工具栏那枚同一个
   `toggleReference`；独立窗口形态下参考窗自己是 key 时由 `RefWindowController` 关掉自己（只改 model，窗口由既有订阅收）。
4. ~~双击空白开合两侧栏~~：做了一版（双击手势里按「是否落在文字行上」分流），用户实测后决定**不要这个功能**，
   整条撤掉（含设置项与文案）。别再提。

## 图片笔记（2026-09-13，Mac + 离线镜像：「从外部导入 / 从 pdf 节选出图片，图片按引用计数管理，30 天后彻底删除」）

方案 `IMAGE-NOTE-PLAN.md`、规格 `REQUIREMENTS.md §1.10`。四条拍板（用户选的）：图钉 + 气泡呈现／⌥⇧ 拖当节选入口
（⌥拖发 AI 不动）／离线镜像这轮一起带上图片／「待删除」只在设置里加一行。

- **存储**：schema v13 新表 `image`（`sha256` 主键、ext/宽高/字节/`created_at`/`orphaned_at`），文件 `Images/<sha>.<ext>`
  （`ImageAssets`：png/jpg/gif/webp 原字节存，其它转 PNG，长边 >4096 缩到 4096，`.part` 原子写）。笔记复用 `note` 表 kind=6
  （`ImageNote`，payload `image`/`caption`/`display`/`source`），增量对账/级联删除/`mergeDocument` 原样继承。
- **引用计数不存列、数出来**（`LibraryStore.imageRefCounts`）：`reconcileImageOrphans` 只在「有引用 ↔ 无引用」翻转时改
  `orphaned_at`（已待删除的不重置，免得越拖越长）；`purgeableImages(before:)` + `WorkspaceManager.purgeImages` 删文件再删行；
  打开工作区、删/存笔记、镜像合并后、设置页「立即清理」四处触发。
- **入口**：`ReaderSurface+Snip` ⇧ 分流 → `finishSnipAsImageNote`（与 AI 截图同一条渲染路径 `PageSnip.renderImage`，出 PNG）；
  `ReaderSurface+ImageNote`：拖文件（阅读区 `dropDestination` 接图片、PDF 转交 `onDropFiles` 入库）、右键「在此导入图片…」
  （`NSOpenPanel`）、⌘V（笔迹剪贴板优先，否则文件 URL → png → tiff）。新建不弹编辑器。
- **呈现**：`PageCellView` 淡青 `photo` 图钉（节选落框右上角外侧、导入落锚点）+ `ImageBubbleView`（尺寸走 `NoteBubble`
  同一套页宽比例，缩略图高 ≤ 气泡宽，说明 ≤3 行）；三态展开与文字笔记同款、共用 `expandedNotes`/`hoveredNote`；
  图钉拖拽与点注解共用 `notePinDragGesture`（`draggablePinHit`/`pinAnchor`）；`ImageNoteEditorSheet`（说明 + 展开方式 + 删除）；
  `ImageViewerSheet`（原图、复制、Finder）；缩略图走 `ImageThumbCache`（后台解码、按 256/512/1024 档缓存、只有叶子视图订阅）。
  Inspector「笔记」页新增「图片」分段（编辑/查看经通知请阅读区弹 sheet）。撤销栈 `InkPatch` 加 `images` 一栏。
- **镜像**：`image` 表走 OCR 那条 additive 通道——`MirrorBuilder` 带 `Images/`（到期的不带、估算计字节）、
  `MirrorStore.imageKeys`（有行 ∧ 文件在 ∧ 没到期）、`MirrorDiff.Plan.imagesToSource/ToMirror`（缺行**或**缺文件都算缺）、
  `MirrorApply.fillImages`（`INSERT OR IGNORE` + 拷文件，**`orphaned_at` 原样带过去**）后两侧各对账；报告多一行；
  与 OCR 同样不挡自动推送。
- **设置**：通用页「图片笔记」区块按打开着的工作区逐个列「图片 N 张 · 待删除 M 张 · 占用」+「立即清理」。
- 验证：`spike/image-store-test`(39)／`image-mirror-test`(31)／`ink-undo-test`(40)／store／mirror-*／scratch-store／ink-store／page-snip
  全绿；`xcodebuild` 过。真机待验清单见 `TODO.md` 同日条目。范围外：平板/安卓（`notes` 广播不发 kind=6）。
  ✅ 用户 2026-09-13 实测「功能上都正常」。
- **UI 二轮（2026-09-13，用户四条，文字/图片气泡都涉及）**：
  ① 「边界有点宽」→ 内边距改「很窄的边」（固定 5pt / 比例 0.30）；
  ② 「随 pdf 缩放可以保留但默认关闭」→ `NoteBubble.Metrics` 两种口径：**固定尺寸**（默认：280pt 宽 / 12pt / 行高 1.25 / 最多 14 行）
  与**跟页缩放**（设置 → 阅读 →「笔记气泡跟随页面缩放」，比例常数三端契约，同步调小了 web `BUB` 与安卓 `NoteBubbleGeom`：
  字号 0.017 / 行高 1.25 / 内边距 0.30 / 圆角 0.4；网页/安卓没有开关、恒跟页缩放）；
  ③ 「图片展开后的编辑图标很突兀」→ 图片气泡去掉铅笔，点缩略图看原图、右键「查看原图 / 编辑… / 删除」；
  顺手：竖图气泡收窄贴图（不留两侧大片空白）、图不在时占位一小条；
  ④ 「文字字体太大、行距大」→ 固定口径 12pt/1.25 解决；顺手修了一条老 bug：`textHeight` 量正文高度时没把 `lineSpacing`
  算进去，多行笔记会从气泡底边溢出（样张里能看出来）。样张：`spike/note-bubble-look.swift`（两种口径各三档）、
  新增 `spike/image-bubble-look.swift`。
  ✅ 用户 2026-09-13 实测「可以了」。
- **Markdown 编辑器接入（2026-09-13，用户拍板「直接就用 `swift-markdown-engine`」，Perch 里用过）**：
  项目第一个 SPM 依赖（`project.yml` 钉 0.9.0，只取核心产品 `MarkdownEngine`，零外部依赖；解析命令给用户跑）。
  `MarkdownNoteEditor` 包一层 `NativeTextViewWrapper`（13pt、去底部留白、竖滚动条、开 sheet 自动进焦点——AppKit 视图
  得自己找第一响应者），文字笔记正文与图片笔记说明两个 sheet 都换上，⌘↩ 保存（回车是换行）。**存的仍是纯文本**
  （Markdown 源），库/协议/镜像零改动。页面气泡不能进 AppKit（阅读区红线）→ `NoteMarkdown` 把源折成 `Text` 能画的
  `AttributedString`（行内样式系统解析；块级近似：标题→粗体行、列表→•、任务→☐/☑、引用→│、围栏去掉、水平线→横线），
  量高度改按折算后的字体特征量。Inspector 列表与图钉提示显示去记号的纯文字。`spike/note-markdown-test.swift` 31 项全绿，
  样张 `note-bubble-look` 第二条改成 Markdown 源看过。网页/安卓端画原样源码，未动。
  **同日二轮**：用户实测编辑器可以，但「气泡渲染效果不好，很多东西没处理，最好也用这个渲染，关闭编辑即可」→
  气泡正文改成同一个引擎**只读**渲染（`MarkdownNoteReader`：`isEditable: false`、`.fitsContent`（滚轮交给下一响应者，
  鼠标停在气泡上照样滚阅读区）、无内边距无滚动条、`.environment(\.colorScheme, .light)` 钉死浅色外观（气泡永远纸白）、
  主题字色钉死、字号按 0.5pt 取整少触发重排）。**这是阅读区「纯 SwiftUI」红线的唯一例外**，记进 `AGENTS.md`。
  高度：引擎 `.fitsContent` 报回 → `onGeometryChange`，第一帧按 `NoteBubble.textHeight` 估计占位；
  🔴 量的是 `fixedSize(vertical:)` 下的理想高度，再由外层 `frame(height:)` 钳到行数上限 + `clipped()`——
  别用 `.frame(maxHeight:)`，它把提议高度整个吃下来，量到的就是提议值，气泡每帧长一圈内边距直到长到上限
  （样张里一行字的气泡长成十四行那么高，就是这么来的）。引擎默认是整页文档的尺度（一级标题 2 倍、列表缩进 27.5pt），
  给笔记收成 1.4 倍 / 16pt（`applyNoteTypography`，编辑器与气泡共用）。`NoteMarkdown.attributed` 不再被视图用，
  `plain()`（列表/提示）与 `nsAttributed()`（估高度）还在用。
  样张：新增 `spike/note-bubble-engine-look.swift`——`ImageRenderer` 画不出 AppKit 视图，改为开一扇不上屏的窗
  `cacheDisplay` 截真实渲染（链接 `build/dev/…/MarkdownEngine.o`），深色外观下截、验字色不变白。
- **字号设置（同日，用户：「设置添加字体大小，包括编辑框的笔记的大小」）**：设置 → 阅读 → 「气泡正文字号」（默认 12）与
  「编辑框字号」（默认 13）两个 Picker，档位 10~24。固定口径下编辑按钮/行距按「÷ 12」等比随字号（宽度那一半随即被下一条推翻）；跟页缩放口径下
  同一倍率乘到字号比例上，三端契约常数不动（`NoteBubble.metrics(pageWidth:followsZoom:fontSize:…)`）；编辑框
  `MarkdownNoteEditor` 自己读 `noteEditorFontSize`，两个 sheet 都跟着变。
- **宽度按内容收窄 + 最小/最大宽设置（同日，用户：「短文按内容收窄，然后有个最小和最大宽度，一样在设置里面设置」）**：
  `NoteMarkdown.naturalWidth` 不折行逐行量最宽一行（标题按放大后的粗体、列表加缩进、任务加勾选框、引用加竖条、
  水平线不算），`NoteBubble.fitWidth` 加 4% + 6pt 余量后钳在设置的最小…最大之间（估窄了顶多多折一行，不会溢出）；
  图片气泡横图撑到最大宽、竖图收窄贴图但不低于最小宽。设置 → 阅读 两个 Stepper（默认 120 / 280，80~800 步进 20，
  互相钳住）。**宽度从此不跟字号**（上一条里「宽随字号等比」的做法作废——宽度自己是设置项了）。跟页缩放口径下
  按参考页宽 933pt 折算。`note-markdown-test` 加到 40 项；样张 `note-bubble-engine-look` 多摆三条短的看过收窄效果。

## 阅读区收回键盘焦点 + 点击即取消选择 + DeepSeek 撤掉模式（2026-09-12，Mac，用户四条）

1. **点阅读区把第一响应者交还给窗口**（`ReaderSurface.takeKeyboardFocus`，挂在 `readerClickGesture`
   的按下与抬手两处）。根因一条、症状两条：阅读区是纯 SwiftUI、没有可聚焦的东西，AppKit 不会因为点了它
   就挪第一响应者——① 工具栏搜索框一旦激活就永远攥着键盘（用户：「搜索栏一旦激活就不能失焦」）；
   ② 内置 AI 面板的 `WKWebView` 认领 `copy:`，Edit 菜单先走响应者链（`MenuActions.route`），⌘C 被它
   接走、选中的 PDF 文字复制不到（用户：「AI 侧边小窗导致不能复制 pdf 的文字」）。
   spike 实测 `NSWindow` / `NSHostingView` 都不认领剪贴板五项，`makeFirstResponder(nil)` 之后
   ⌘C 自然落到 `.readerCopy`。只碰事件所在的那扇窗（AI 浮窗是子窗口时 `keyWindow` 可能不是它）。
2. **单击即取消选择**：`.onTapGesture(count: 1) { tapReader() }` 删掉，收选区/收框选并进
   `readerClickGesture`（原 `highlightClickGesture`，`DragGesture(minimumDistance: 0)` 抬手 ≤3pt 算单击），
   与高亮气泡同一条路——不再等系统双击间隔那一拍。**双击的第二下不算单击**（`isMultiClick` 读
   `NSApp.currentEvent.clickCount`，先验事件类型），否则会把刚选好的词又清掉。
3. **DeepSeek 内置表不再填 `modes`**：用户实测站点已撤掉「快速 / 专家 / 识图」三段控件、只剩一种，
   图片上传照常。模式菜单随之隐藏、投递前不再找控件；机制整套保留，外部配置填上就能回来。
   ⚠️ 若 `~/Library/Application Support/UniReader/ai-providers.json` 存在（之前导出过模板），它整份覆盖
   内置表，里面的 `modes` 要自己删掉。
   ✅ 用户 2026-09-12 实测四条全部通过（搜索框失焦 / 内置面板后 ⌘C / 点空白即取消 / 双击选词）。

## 高亮三项（2026-09-12，Mac：选中按 h 高亮 / 按 n 笔记 · 高亮可换色 · 点高亮气泡即时出）

1. **选中文字后 `h` 快速高亮、`n` 文字笔记**：接进既有的单键工具监视器（`installToolKeyMonitor`，
   `ReaderSurface+Zoom`），只在「有选区 + 草稿纸没盖着」时这两个键归选区，否则 `n` 仍是书写模式。
   输入法/文本框：监视器原有守卫已覆盖——文本框焦点（`firstResponder is NSText`）与内置 AI 网页焦点
   一律放行；没有文本输入焦点时输入法根本不介入，按键原样到监视器。`h` 用的颜色 =
   **最近一次选过的**荧光色（`AppModel.quickHighlightColor`，UserDefaults 持久化，首次黄）。
2. **高亮换色**：页面上点高亮弹出的气泡里加一排调色板色点（当前色描圈），Inspector 高亮列表右键
   「高亮颜色」子菜单；`recolorHighlight` 就地改色 + bump `updatedAt`，`persistHighlights` 对账识别为变更
   并 upsert。气泡/右键菜单里选过的颜色都记成下次 `h` 的颜色。
3. **点高亮气泡慢半秒**：根因是 `.onTapGesture(count: 1)` 为区分双击要等系统双击间隔才回调。
   高亮命中改挂 `highlightClickGesture`（`DragGesture(minimumDistance: 0)`，抬手位移 ≤3pt 算单击）
   抬手即开/收气泡；`tapReader` 只剩收选区/收框选。双击落在高亮上先收气泡再选词。
   起点在点注解图钉上让位（同拖选规则）。
   待用户实测：气泡打开后紧接着点别处/点另一条高亮的手感（弹窗是 transient，点外面关的那一下
   会不会吞掉鼠标按下）。

## 参考窗独立窗口形态（2026-09-11，Mac：「参考小窗支持独立小窗口（类似 AI 窗口那样）」）

覆盖层顶栏多一枚「弹出为独立窗口」，弹出后是阅读窗的**子窗口**（恒在其上、跟着走、随它最小化，
不贴边不定位）；工具栏「改为窗口内置」切回。两种形态共用同一份 `RefWindowModel`，开的哪本 / 滚到哪 /
缩放多少切换时原样带过去；形态偏好全 app 一份（`refWindowMode`），只在从关闭状态打开时对齐。
文件：`Sources/Window/RefWindowController.swift`（新）+ model / 页流 / 覆盖层各改一处。
机制与两条坑（认领 id 按页流实例分、独立窗口关掉时只交自己那份认领）记在 `REF-WINDOW-PLAN.md §11.3`。
待用户真机验：子窗口在阅读窗全屏时的表现、首次弹出的落点、紧凑工具栏的标题/页码排法。

## 打开耗时（2026-09-10，Mac：「有时候打开 tab 挺久才显示完整页面 + 笔迹」→ 30~60ms）

先量再修。`OpenTrace`/`OpenStats`（设置 → 诊断 + `wsLog` 摘要行）把每次打开/切标签从点下去到
「可见页的页图 + 笔迹都画出来」逐段记账，用户第一批日志就把病根钉出来了，三轮改完用户实测
**打开 / 切标签 30~60ms**（此前 857ms / 150ms）。

1. **笔迹解码 506ms（2616 笔）**：`JSONDecoder` 解 `[[Double]]` 是 Codable 逐元素走容器协议，一个数
   1~2µs。`InkPayloadFast.splitPoints`（`InkModel.swift` 末尾）在原始字节里定位 `points` 数组自己扫，
   其余百来字节照旧 JSONDecoder；形态不认识回落，结果逐位相同。payload 格式不动（三端契约）。
2. **仍 360ms（Debug 包）→ 后台并行解码**（用户定「先展示窗口和 PDF，笔迹异步处理好再显示」）：
   `loadInk` 读库在主线程，解码 `InkStroke.decodeAll` 多核分块保序，回主线程按 `inkLoadGeneration`
   核对，期间新画的笔迹合并保留；图层自愈挪到笔迹到位后。顺带发现 **`strtod` 多线程不伸缩**
   （300k 次：1 线程 10ms、8 线程 20ms），换 `Double(String)` 后 12 核并行 20ms。
3. **切标签 150ms 的主项是空跑的平板广播**：「开机自启平板服务」开着时 `AppModel` 全部
   `broadcast*`/`push*` 只看 `server.isRunning`，零客户端也在装箱整篇笔迹、拼目录/书库字典——守卫
   改 `server.hasClients`，新客户端接入由 `clientCount` sink 补全量。
4. **第四轮：「笔迹读库 158ms · 2616 条」也离开主线程 + 窄查询**（用户问「是一次性读全部吗」——是）。
   `loadInk` 现在只剩置位，读库与解码同在一个 `Task.detached` 里（`SQLiteDB` 一条语句一把锁，后台用
   主线程那条连接是离线镜像的既有做法）；账本从「装载」同步段挪到里程碑 `笔迹到位`（读库 / 解码各记）。
   读库改 `LibraryStore.inkRows`：只取 `id, kind, page, payload` 四列、`SQLiteDB.query(_:_:row:)` 按列位置
   读、不建 `[String: Any]`——整行版每行为 11 列造列名字符串 + 装箱 + 插字典，还解两个不用的时间戳。
   合成库（2616 行 / 15MB）实测：Debug 32 → 9.5ms，Release 13.8 → 9.0ms；真机那 158ms 里剩下的部分
   多半是外置盘 I/O，正好也不在主线程了。草稿纸笔迹（kind=4）同走窄查询。
   `InkStroke(note:)` / `InkStroke(row:)` 共用一个私有解码本体；`decodeAll` 改吃 `[LibInkRow]`。

验证：`spike/ink-payload-fast-test.swift` 25 项（逐位比对 / 各种写法 / 坏形态回落 / 并行保序 / 计时）、
`ink-store-test` 25/0（第四轮加 4 项：窄查询四列一致 / 两条解码入口同结果 / kind 筛净 / 排序）、
`xcodebuild`；用户实测通过（前三轮）。教训写进 TODO 状态速览同日条目。

## 内存（2026-09-10，Mac：Release 开三个文档 2.34GB，设置页却只写「缓存 366MB」）

用户报：Release 包开三个文档，活动监视器 2.34GB；设置页缓存上限 512、显示已用 366；
「Preview 开三个也不到 2GB」。对正在跑的进程 71350 直接量（`footprint` / `vmmap` / `heap`）。

### 实测拆分（`footprint` 2384 MB = 活动监视器那 2.34 GB，同一口径）

| 类别 | 大小 | 内容 |
|---|---|---|
| `VM_ALLOCATE` | 975 MB | **49 张整页位图**（`PageBitmap` 自己 mmap 的 BGRX 缓冲，11.2~27.6 MB/张，精确合计 963.7 MB） |
| `CoreAnimation` | 931 MB | **46 块，字节数与上面逐一相等**（28,901,376 B ×5、24,788,992 B ×5 …）——CA 的合成副本 |
| `MALLOC_LARGE` | 231 MB | **11 张页尺寸的图归 CoreGraphics 管**（`DefaultPurgeableMallocZone`，24,805,376 B ×5 …），字节数与 mmap 那批都对不上 |
| `MALLOC_SMALL` | 218 MB | 普通堆：`heap` 63 万对象共 368 MB，扣掉上面 237 MB 剩 ~131 MB 真对象（37 MB 是 11,335 个笔迹点数组 `[SIMD3<Double>]`），其余 ~110 MB 碎片（分配器自报 51%） |
| 其它 | ~29 MB | IOSurface、`__DATA`、页表等 |

其中 2.2 GB 已被系统压缩/换出，常驻只有 685 MB（三个窗口都不在前台）；活动监视器把压缩掉的照算。

### 三条根因（都能对上数）

1. **366 MB 只是 LRU 里的那部分**（计费含 ×2 → 真位图约 183 MB ≈ 8 张）。进程里活着 49 张，
   另外 41 张（~780 MB）是三个窗口各自的 `images`/`tiles` 攥着的——LRU 淘汰只放掉缓存这份引用，
   视图还持有就不释放；缓存上限根本管不到视图层，开几个窗口乘几倍。
2. **CA 副本对每一张活着的图都存在**（49 ↔ 46，字节相等）。2026-08-29 那轮以为「只有正在显示的
   才有副本」，其实是副本跟着 `CGImage` 生命周期走——显示过一次、只要图还活着副本就在。
   所以 `copiesPerImage = 2` 对视图持有的图同样成立，之前只给缓存那 8 张计过。
3. **231 MB 完全账外**：夜间反色 `PageBitmap.invert` 走 `CIContext.createCGImage`，像素归 CI/CG 管
   （purgeable zone），不进 `mmap`、不进 `liveImages`。一个窗口开着夜间模式就是这 11 张。

顺带查出两个漏：**参考窗 `RefPageStream.images` 从不驱逐**（只在换书时 `removeAll`，滚过的页与
缩放换档前的旧宽度图全留着）；**渲染完成回调不看页还在不在窗口里**（快滚时发出去的请求在页
滚出窗口后才完成，照样写进 `images`，要等下一次窗口变动才驱逐——空闲窗口里就一直挂着）。
另一处浪费：多窗口把缓存挤满后，`settleRender` 发现屏幕上的页「缓存里没有」就**重渲一遍**，
渲完替换同一张图——纯 CPU 白烧 + 瞬时双份。

### 改动

- **诊断**：新文件 `Sources/App/MemoryDiag.swift`——`footprintBytes()`（`task_info` 的
  `phys_footprint`，活动监视器口径）、`mstats()` 堆用量、`Snapshot`/`report()`；`PageHoldings`
  台账：每个持有者（阅读区 / 参考窗 / 缩略图栏）在自己 body 求值里回报 `images`/`tiles`/`inkSnaps`
  的张数与字节，消失时销账。设置页「渲染」区块改为分项列出：App 内存 / 存活页图（+CA 副本）/
  缓存里（含可用额度）/ 窗口持有 / 逐窗口一行（● 活跃 ○ 非活跃，实化范围、张数、字节）/ 堆。
- **夜间反色渲进 mmap 缓冲**（`PageBitmap.invert` → `ci.render(_:toBitmap:)` 到 `makeImageRaw`）：
  与亮色图同一出口、同一套记账与释放。`makeImage` 拆成 `makeImageRaw`（裸缓冲）+ CGContext 壳。
  `spike/night-invert-test.swift` 14 项：方向没翻、通道没串（BGRX）、与老路径逐通道一致（±3）、
  进出 `liveImages` 的账。
- **参考窗驱逐**：`RefPageStream.updateRealized` 丢掉窗口外的图；回调按 `RefScratch.keepRange` 守门。
- **阅读区回调守门**：`Scratch.keepRange`（实化窗口 ± 余量，`updateRealized` 维护），
  `requestBase` / 贴片回调页不在范围内就不写。
- **不重渲屏幕上已是目标宽度的页**（`hasTargetImage`；贴片同款按像素宽判）。
- **视图放手的图先交回缓存**（`releaseImage` / `handOffImagesToCache`）：视图持有的图多半已不在
  缓存里（额度让出去了），直接丢就是真丢，切标签回来 `seedImages` 一张都取不到。切标签的
  `onDisappear` 里**先 `PageHoldings.remove` 销账再交图**，否则额度还被自己占着、交回去当场被 trim。
- **非活跃窗口只实化可见页、图也只留可见页**（`updateRealized` 的 `buffer`/`keepMargin` 按
  `scratch.isActiveWindow` 分支；`onChange(of: isActiveWindow)` 补跑一次）。上下各一屏预实化 +
  ±2 页余量是给正在滚的窗口准备的，后台窗口没人滚却各攥一套。**代价**：在非活跃窗口里滚动，
  滑入的页要等渲染/磁盘解码才出图。
- **缓存上限 = 页位图总预算**：`RenderImageCache.reservedCost`（视图持有量 × 份数）从 `limit`
  里扣，`effectiveLimit = max(limit/4, limit − reserved)`；`PageHoldings` 总量一变就回报
  `PageRenderEngine.setExternalHoldings`。缓存至少保住 1/4，别被挤成零（回看/换标签/夜间快路全靠它）。

验证：`xcodebuild` 通过；`night-invert-test` 14/0、`page-layout-test` 25/0、`render-rotation-test`
9/0、`page-disk-cache-test` 5/0。**内存数字与观感待用户实测**（见 TODO 状态速览同日条目）。

### 续：关掉全部工作区仍 1.1GB —— 整扇窗的对象图根本没释放（同日，用户实测新包后报）

用户装上面那版后报「关闭工作区后内存没有释放，0 个工作区 1G」。对进程再量：`footprint` 1105 MB，
`VM_ALLOCATE` 18 张页图 367 MB、`CoreAnimation` 16 块 318 MB、`MALLOC_LARGE` 12 块 248 MB
（CG purgeable zone，5 块常驻 108 MB）、`MALLOC_SMALL` 205 MB。`heap` 一数就清楚了：
**0 个工作区开着，进程里还活着 5 个 NSWindow、4 个 `WorkspaceManager`/`TabsModel`/`RefWindowModel`/
`WindowChrome`/`NSSplitViewController`/`NSToolbar`、116 个 `NSHostingViewBase`、9 个 `DocSession`、
7 个 `Scratch`（= 7 个阅读区的 `@State`，页图字典就挂在那）、5 个 `CGPDFDocument`。**
四扇早已关闭的窗口原封不动。

两条根因：

1. **retain 环**：`TabsModel.window` 是强引用，而 NSWindow → `contentViewController` → 三个
   `NSHostingController` → 根视图 `ReaderPane(tabs:)` 强持有 `TabsModel`。controller 被
   `AppDelegate.forget` 放掉之后，这个环让整扇窗（含阅读区 `@State` 里的页图、会话、PDF 文档及其
   CG 解码缓存）永远活着。改 `weak`。
2. **`purge(doc:)` 被自己挡住**：引擎按「还有没有窗口声明要这份文档的键」决定能不能清，而阅读区
   `onDisappear` 里**从来没有** `setWanted([])`（注释写着「必须排在 setWanted([]) 之后」，调用本身
   在窗口层迁移时丢了）；且关窗时 `DocSession.teardown` 跑在 `onDisappear` 之前。于是关窗后
   缓存里的页图一张都清不掉，只能等别的文档慢慢挤。改：`DocSession.renderClients` 登记阅读区的
   `clientID`，`teardown` 先替它们 `setWanted([])` + `PageHoldings.remove` 再 `purge`；
   `onDisappear` 也补上 `setWanted([])`（排在 `releaseRenderCache` 之前）。

顺手加了两行释放日志（`ReaderWindowController 释放` / `TabsModel 释放（窗口对象图已回收）`，
`touch ~/Library/Logs/UniReader-ws.log` 开）：关一扇窗两行都该来；来了第一行没第二行 = 对象图里又有环。

**第二轮（用户装上后报仍 1.5GB）**：两行释放日志都来了，窗口对象图确实放了，但 `heap` 里
**9 个 `Scratch` + 9 个 `ScrollFollower`** 还活着 = 9 个阅读区的 `@State` 存储盒没放（页图字典就在盒里，
596MB `VM_ALLOCATE` + 595MB CA 副本）。谁攥着？**捕获了 `ReaderSurface` 拷贝的闭包**——struct 拷贝连着
`@State` 的存储盒（`_images`/`_scratch` 的 location 是类）和 `@ObservedObject session`：
3. **`scratch.settleWork` / `resizeWork`（DispatchWorkItem）成环**：闭包捕获 self 拷贝 → 拷贝持有
   `scratch` 的存储盒 → `scratch` 持有 work item。跑完没人置空，视图拆了也永远在。改：闭包体第一句
   `scratch.settleWork = nil` / `resizeWork = nil`。
4. **三个 NSEvent 监视器**（⌘滚轮 / Esc / 单键工具）只在 `onDisappear` 移除，而关窗时 AppKit 直接销毁
   hosting 视图，`onDisappear` 来不来没有保证。改：`Scratch.releaseRetainers()`（三监视器 + 两 work item
   一起放，幂等），`onDisappear` 与 `DocSession.teardown` 两个入口都调——后者经 `renderClients`
   登记的闭包，**闭包只捕获 `scratch`（类），不捕获视图**，否则会话又攥住一份拷贝。参考窗同款
   （`RefWindowModel.viewCleanup`）。
5. `Scratch.deinit` 加日志「阅读区状态释放（页图已放）」：切标签/关窗后不来这一行 = 又有谁攥着视图拷贝。

**未处理**：草稿纸 `ScratchPadView` 的两个监视器令牌存在 `@State` 里、闭包捕获视图，关窗时纸若开着
同样会漏（一张页图 + CA 副本）。纸开着关窗少见，先记在 TODO 已知欠账。

**第三轮（用户报关窗后回收了、但仍 ~400MB，怀疑关标签漏）**：对当时进程（一扇窗开着、无页图）量到
219 MB，构成是：`MALLOC_LARGE (empty)` 100 MB —— 3 块 31.7/34.3/34.3 MB **已 free 但分配器攥着**的
大块（尺寸 = 2800px 宽整页解码缓冲，ImageIO 解 JPEG / CG 解扫描页图用的临时缓冲）；
`DefaultMallocZone` 174 MB 虚拟、只有 **27 MB 真在用**、68 MB 碎片（72%）；其余是框架基线。
也就是说关完文档后剩下的几百 MB 基本是**分配器没还给内核的空闲内存**（活动监视器照算，内核缺内存时
才回收），不是谁还攥着对象。关标签这条路（`TabsModel.close` → `DocTabModel.close` → `teardown`）
逐项核过：`app.sessions` 注销、订阅全 `[weak self]`、`bag` 清空、阅读区拷贝的持有者已在第二轮堵上，
没找到新的持有点。顺手修一处真漏：**缩略图栏不按文档重建**（`InspectorView` 里 `ThumbnailListView`
没有 `.id`），切标签后上一本书的缩略图（最多 48 张 + CA 副本）留在字典里、还会先顶在新书同页号的
格子上——加 `.id(session.contentHash)`。诊断行「堆（malloc）」拆成「在用 / 已释放未归还」两个数，
设置页上就能分清「泄漏」和「分配器缓存」；`DocSession`/`DocTabModel` 加释放日志（`会话释放` / `标签释放`），
关标签后不来这两行才是真漏。

## 三端笔迹绘制对比工具 + 两条分叉修掉（2026-09-07，三端）

用户拍板：路线图 ⑤（Rust 笔迹核心）正式放弃，改做**对比工具**——「将多端的绘制汇总起来对比，
找到差异，然后修复」。

### 工具（`spike/ink-cross/`）

一份共同向量 → 三端各自用**产品代码本身**渲成 PNG → 并排 + 差值图 + 指标表。
`spike/ink-cross/run.sh` 一条命令跑完，`out/report.html` 用浏览器打开。

🔴 **工具里没有一行复刻的渲染算法**。复刻一份就等于自己跟自己比，分叉照样藏着：
`mac.swift` 调 `inkDrawStroke`；`web/ink-cross.html` import `web/src/lib/inkGeom.ts`；
安卓 `InkCrossProbeTest` 调 `shared/InkRenderer`。

为此把 `buildGeomWith`/`paintGeomAt` 从 `render.ts` 的 `initRender` 闭包搬进新模块
`web/src/lib/inkGeom.ts`（纯搬迁、零行为变化——它们本来就没用到任何闭包变量）。

**三端出图的共同口径**（改一处必须同时改另两处，否则比的是口径不是算法）：
位图 = `canvas.w × canvas.h × canvas.scale`（1800×1200）／笔宽 = `width × scale` 物理像素
（mac `ImageRenderer.scale=2`、web `wScale=scale`、安卓 `InkRenderer(scale)`）／白色不透明底／无重采样。
🔴 安卓那个参数名叫 density 但喂的是 **scale 不是设备真实 density**——用设备 density 的话，
同一份向量在 3x 屏和 2x 屏上粗细不同，比的就成了设备。

**指标不做逐像素 diff**（三端抗锯齿天生不同，那个数字没信息量），改用结构性指标：
墨量 / 包围盒 / `taper`（端部÷中部墨量，锥度判据）/ `rough`（列墨量差分，纹理判据）。

四个坑记在代码里：
- 报告的墨判定用**「离白最远的通道」而不是亮度**：荧光笔 `rgba(250,204,21,0.4)` 压白纸后
  亮度只比白低 0.09，按亮度算整条被滤成空白、bbox 直接是 None。
- `run.sh` 的截图循环用 `while read` 而不是 `for in $NAMES`：**zsh 默认不做单词分割**，
  会把整串名字当成一个（脚本常被人从 zsh 里拷去手跑）。
- Mac 端源码要拷成 **`main.swift`**：swiftc 只允许这一个文件名带顶层表达式，叫别的名字会报
  一串 `expressions are not allowed at the top level`（报的是结果不是原因）。
- 安卓端必须带 **`leaveApksInstalledAfterRun`**：AGP 默认跑完卸载 app，而图写在 app 专属目录，
  卸载连图一起没（第一次就栽在这儿：测试全绿、目录不存在）。

浏览器用的是 playwright 已下载的 `chrome-headless-shell` 二进制——**没装它的 npm 包**
（`npx playwright` 会触发安装，而这个项目的规矩是不代用户装依赖）。

### 首轮结果与两条修复

| 判读 | 条目 |
|---|---|
| 三端一致 | ballpoint 各形态、marker 单笔与叠笔、尺子两点线、单点、急转折返 |
| ✅ 修掉 | **钢笔起收锥度**：Mac 有 `fountainTaper`，web 与安卓一行都没有（墨量差 13~20%）→ 1%/3% |
| ✅ 修掉 | **铅笔三道石墨纹理**：Mac 三道半透明微波动叠加，web 与安卓是一条光溜实线（墨量差 65%）→ 0%/2% |
| 🔍 证伪 | **marker 叠笔接缝三端差 0%** |

**钢笔锥度**：三端补成逐字同式（`n<=2` 不锥／`t=i/(n-1)`／`edge=0.16`／
`a>=1 ? 1 : smoothstep(a)*0.82+0.18`）。web 的起笔圆点也要吃 taper，否则起笔处凭空鼓一个圆头。

**铅笔纹理**：比 TODO 里记的「pad 实时反馈阶段无纹理」严重——**静态显示也没有**，
深浅也不对（Mac 三道叠加等效 alpha ≈0.53，平板是 `0.95×0.85=0.81`）。移植时三条一个都不能少：
① 波动相位按**累计弧长**推进不按点序号（按序号走会把波形在减速的笔尾压成锯齿）；
② 抖动种子用**归一化坐标**不是屏幕坐标（否则一缩放颗粒重新洗牌、滚动时纹理会爬）；
③ 波幅里的线宽项要封顶（`PENCIL_WOBBLE_REF_W=9`）。
🔴 铅笔从此**不吃 `opacityMultFor(0.85)`**：透明感由三道 alpha 叠出来，再乘 0.85 是叠两遍。
🔴 安卓 `inkJitter` 的中间量必须用 **Double**：`sin(...)*43758.5453` 放到 1e4 量级，
Float 只有 24 位尾数，取小数部分时低位全丢 → 与另两端出的「随机数」对不上，纹理就不一样。

结构改动：web `InkSeg` 加可选 `color`；安卓 `Geom` 从「一条 path + 整条一个 alpha」
改成 `layers: List<Layer>`（path + 该道 alpha 倍率），`render` 逐道上色。

⚠️ **web 有一处做不到的残差**（写在注释里）：Mac 把每段描边转成填充轮廓攒起来一次 fill，
Canvas2D **没有 stroke→outline 的 API**，只能把宽度相近的段攒进一条 Path2D 再 stroke，
段接缝仍会轻微叠色。安卓有 `getFillPath`，照 Mac 那条路走。

验证：三端出图 11/11（安卓在真机小米 Pad 6 上跑）；既有 `InkRendererTest` 6 项仍全过；
`tsc` / `build-web.sh` / `gradlew test` 全绿。

## 真机验收批量结清（2026-09-07，用户统一裁决）

**这不是逐条实测记录，是一次范围裁决**——用户原话「测试部分可以认为都正常了」。
`TODO.md` 里积压的全部「待真机验证 / 待用户真机验证 / 待真机确认」条目就此结清，
不再逐条挂账。哪天某一条真出问题，按日期回到本文件（或对应方案文档）里那段实现记录查。

结清的范围：

| 条目 | 落地日（= 查记录的索引） |
|---|---|
| 模式2 多工作区切换 + 撤销/重做图标 | 2026-09-06 |
| 参考窗三端（含顶栏拖拽把手 / 目录跳转） | 2026-08-30 / 09-02 |
| 编辑撤销重做 + 笔迹剪贴板（平板三端 + 边界项） | 2026-09-02 |
| 书签（Mac 边界项 + 三端同步） | 2026-09-02 |
| 安卓划字（选字 / 四色高亮 / 批注 / 图钉） | 2026-09-04 |
| 笔&笔架&笔迹四项回归 + 尺子线粗细 | 2026-07-26 / 09-06 |
| 安卓输入板补全（环形盘 / 框选 / 多图层 / marker / 重连） | 2026-07-29 |
| web 框选移动 | 2026-07-27 |
| 平板开文档 + 目录跳转 | 2026-08-05 |
| 安卓模式1 多标签页 | 2026-08-05 |
| 移动硬盘关窗即弹出 | 2026-08-05 |
| 草稿纸四端（含页面底图 + 客户端管理） | 2026-08-07 / 08-13 |
| 框选三增强（自由框选 / 光晕 / 手柄缩放） | 2026-08-17 |
| AI 面板 S1~S5 + 吸附 / 内置模式 | 2026-08-25 / 08-26 |
| PDF 画板模式（三端页边对齐） | 2026-08-28 |
| 模式2 笔画闪烁 / 移动端三件 / 笔迹镜像改增量 | 2026-08-28 |
| 缩放卡顿手感 + 切标签页不重下页图 + 框选留选中 | 2026-08-29 |
| macOS 多标签页第 1 步落库搬家 / 第 2 步标签化 | 2026-08-29 |
| 离线镜像 M3 观感 / M7 副本自动维护 | 2026-08-30 / 09-01 |
| 安卓圆盘工具图标观感、marker 并排观感 | 2026-08-07 / 07-30 |
| `broadcastStrokes` O(n²) → `strokesAppend` 增量 | 2026-08-28 |
| 安卓模式2 环形选笔盘三症状（见下一节） | 2026-09-02 |

🔴 **裁决的边界**：结清的是「验收挂账」，**不是**「这些代码都没问题」。`TODO.md` 里留着的
「已知欠账」——默认图层 id 跨文档串行、安卓划字两个缺口、三端笔迹观感分叉、几条性能欠账
——**不在结清范围内**，它们是已知没做，不是待验。

## 安卓模式2 环形选笔盘：三症状同根（2026-09-02 修，2026-09-07 结清）

用户 2026-09-02 报三个症状 → 同日改四处 → 用户真机实测「好多了」；2026-09-07 随上面那次
批量裁决一并结清。**三个症状是同一个根**：控制帧被大帧压在后面 + 平板对迟到帧毫无防御。

症状：① 动不动突然冒出「进度条」（= 长按进度环 `PadOverlays.drawPressRing`）；
② 圆圈位置不对，不在笔尖；③ 正常长按反而唤不出盘。

`LANServer.swift` 合帧那段注释早就写明了这条路径：`radial`/`pressRing`/`inkCancel` 是几十字节的
控制帧，与 `strokes` 全量镜像走**同一条有序 WS 通道**，大帧一在飞它们就得排队。于是：
`pressRing on=true` 落在**抬笔之后**才到 → 环按上一笔的落笔点凭空画出来（症状 ①），
而那时笔根本不在纸上（症状 ②）；真想长按时 `radial` 同样迟到，被 `endPen` 收掉（症状 ③）。

- **Mac ①：擦除没擦到东西就什么都不做**（`AppModel.eraseNear` 改成返回「这批擦到了没有」，
  `inkErase` 据此决定发不发全量镜像）。从前橡皮**停着不动**时，平板照样每 8ms 送一批点上来，
  每批都无条件 `s.strokes = out` + 广播一份几百 KB 的全量镜像 —— 而擦除模式下长按呼盘时橡皮
  恰恰是停着的，**信道必然被自己灌满**。顺带省掉每批一次的 `@Published` 全窗重算 + 全表对账。
- **Mac ②：撤环那一帧不会再被吞掉**。去重从前写成 `guard padSession?.pressRing != r`，而
  `padSession` 是**计算属性**（`padSelectedSessionID ?? activeSessionID`）——手势中途切个标签它就
  换了对象，`nil != nil` 为假 → 直接 return → 平板上留着一个永不消失的环。改为记在 AppModel 级
  （`sentPressRing`），并在换会话时把旧会话上的环/盘一起收掉（`adoptOverlaySession`）。
- **平板 ③：迟到帧不许凭空画东西**（`PageCanvasView.overlayAllowed`）。`pressRing on=true` /
  `radial open=true` 到达时若笔已不在纸上，**一律丢弃并打一行 logcat**；`penDown` 也顺手再收一次
  上一笔的残留。`false`（撤环/收盘）永远照收——那是清理。
- **平板 ④：翻页模式拖动不再被误判成长按**。探针坐标改用**落笔那一刻冻结的坐标系**
  （`beginProbe` 记下落点与页宽页高，`probeAt` 把屏幕位移折成归一化量，且**刻意不 clamp**）。
  从前笔拖着页面一起走 → 笔相对**页面**几乎没动 → 判定方看到「一支停着不动的笔」，
  拖着翻页滚半天照样满 1s 呼盘。擦除模式下页面不动，`probeAt` 与老算法逐值相等（不受影响）。
  **两模式同时受益**（模式1 的 `RadialController` 吃的是同一条探针流）。

**改之前先记住这套架构**（不然会在平板上改画的那一半）：模式2 的**判定全部在 Mac**——
`AppModel.beginLongPressWatch` / `checkLongPressMovement` / `fireLongPress` / `updateRadial`；
平板只照着下发状态画（`PageCanvasView` + `PadOverlays`）。下行三条：`pressRing`(0x38)、
`radial`(0x37)、`inkCancel`(0x35)；上行是 `ink`/`probe` 两条 RT 流（UDP）。所有距离阈值靠平板
上报的 `padGeom.pageW`（**dp**）换算（`AppModel.exceedsPad`）。
**模式1 是同一套判定的 Kotlin 复刻**（`local/RadialController.kt`，用本机时钟与本机页宽）
→ **复发时第一步就在模式1 上做同样的动作**：两模式表现是否一致，一步就能把嫌疑劈成
「判定逻辑本身错」还是「模式2 这条链路错」。

**万一复发，按这个顺序查**（先看日志，**别一上来调 `PadConst.LP` 的常量**——那是最后一步）：
1. **平板 logcat 里有没有「丢弃迟到的 …：笔已不在纸上」**（`adb logcat -s UniReader/Canvas`）。
   有 = 控制帧仍然在路上被压着，那就该做「暂停全量镜像下发」（`LANServer` 加 hold 开关，
   长按候选期 / 盘开着时挂起，手势结束再放）；一条都没有 = 迟到已经不是问题了，往下查。
2. **`padGeom.pageW` 到没到 Mac / 值对不对**。`PageCanvasView.emitGeom` 只在页宽变化 ≥0.5dp 时
   发一次（静止零流量），连接后靠 `PadActivity.syncToolState()` 补发。Mac 侧 `padPageWidth == 0`
   时全部阈值退回**归一化兜底**（`moveCancelNorm 0.02` / `holdSpeedNorm 0.043` /
   `radialDeadzoneNorm 0.045`），那口径随缩放漂移，一条就能同时解释三个症状。
3. **位置还是不对**：环画在 `viewX(pr.page, pr.nx)`，nx/ny 是平板自己上报的落笔点原样回发，
   笔在纸上时理应正好压在笔尖底下。仍偏就看：① `page` 兜底兜错了（`handleInk` 里几处
   `?? s.currentPageIndex`，换文档/跨页那一瞬）；② **草稿纸开着**——Mac 把 ink 整条改走画布坐标
   （`handleScratchInput`），而 pressRing 仍按页内归一化画。**「偏一点」是 ①，「完全在另一处」是 ②。**
4. **两端计时起点不同**：平板收到 `on=true` 用**本机时钟**起计（`pressT0`，300ms 起显示、
   700ms 填满），Mac 那边的 1s 定时是从**它收到 ink begin** 起计。链路一抖就会出现
   「环刚填满盘没来」或「环还没满盘就来了」。
两边抓时刻对：Mac `log stream --predicate 'process=="UniReader"' | grep 环形盘`、
安卓 `adb logcat -s UniReader/Canvas UniReader/Radial`。

⚠️ **没做的那一半**：控制帧与全量镜像共用一条有序通道这件事本身没改——合帧只压掉了
**排队中**的镜像，**在飞**的那一份仍然会挡路。症状既然消了就先不动（用户 2026-09-07 裁决
性能类欠账「先记录，不做」），复发时按上面第 1 条办。

## 模式2 多工作区切换 + 撤销/重做图标重画（2026-09-06，协议 + 安卓模式2）

用户报两条：「安卓模式2 Tab 处多工作区切换，或者书库显示全部打开的工作区」「尺子工具右边多了
两个图标，不知道干啥的」。

**① 多工作区：根因是 `docs` 广播本来就是跨工作区的，却没带工作区标识。** Mac 的工作区是**窗口级**、
多个可以同时开着（`REQUIREMENTS.md §8.1`），而 `AppModel.broadcastDocs` 发的是 `sessions`
= **全部窗口**。平板照单全收铺成标签页 → 几个工作区的文档混成一排、长得一模一样，点过去工作区
凭空换掉（书库、目录整套跟着变），用户根本无从预期。

- **协议扩一处**（`PROTOCOL.md §4.2`）：`docs`(0x33) 每项从 `(str id, str title)` 变成
  `(str id, str title, str ws)`，`ws` = 那个窗口所属工作区的名字（`DocSession.workspaceName`，
  窗口还没装上工作区时是空串）。三端同步：`WireCodec.swift` / `wire.js` / `pad/WireCodec.kt`。
- **Mac**：`broadcastDocs` 带上 `ws`；`ReaderWindowController` 里 `workspace.$documents` 那条
  sink 补发一次 `broadcastDocs()`——工作区名是刚 `syncWorkspaceSnapshot` 进去的快照，
  只发 `library` 的话标签页栏拿到的还是旧名。
- **安卓模式2**：标签页栏只列**当前工作区那几篇**（`PadActivity.rebuildTabs`，`visDocs` 过滤，
  栏上的下标就是它的下标）；工作区芯片从「📖 开书库」改回与模式1 同义的「`⌄` 切工作区」，
  点开是 `docs` 按 `ws` 分组的一张表（每行「工作区名 · N 篇」，当前那行打勾），点一行 =
  对那个工作区里**上次待过的那一篇**发 `selectDoc`（`lastDocInWs`，没待过就第一篇）。
  书库入口还有两个（芯片右边的 `+`、抽屉的「书库」页），芯片不必再兼这一职。
  平板**不能新开工作区**（那是 Mac 的窗口级概念），所以没有模式1 那个「打开其它 .unrd…」。
  🔴 **当前工作区取 `docs` 里 selected 那项的 `ws`，不取 `library` 广播的 wsName**：两条广播的
  先后没有保证（同 `layout`/`toc` 那个老坑），拿另一条的字段来分组会在切档瞬间错位一拍。
- `DocTabsBar.chipTrailingIcon` 这个开关随之删除（两模式尾标统一 `⌄`，没有第二种取值了）。

**② 图标：首版 undo/redo 画的是「一个几乎闭合的大圆环 + 上方一个小箭头」**，19dp 下读起来是
"刷新/重置"——这才是「不知道干啥的」的真正原因（模式2 那两个键本身没问题：撤销/重做，栈在 Mac、
本端只发意图帧，故常亮不灰）。重画成通行的 ↩/↪ 弯钩箭头：一横 + 右端 180° 回转 + 左端左指箭头，
回来那截刻意短一些（两截等长会读成闭合的 U，看不出是箭头绕回来的）。几何仍在 `tools/icons/gen.py`
一处，`--check` 量出 bbox `[4.80,5.70]-[19.20,18.30]`、span 14.40、两个互为精确镜像。

**验证**：`wire-codec-test`(100)／`wire-cross-test`(190)／安卓 `assembleDebug` + JVM 单测
（`WireCodecTest` 向量 #16 已换成两项分属不同工作区的新形态）／`xcodebuild`／`tsc --noEmit`／
`vite build` + `capture.html` 回写 全绿；`gen.py --check` 39 个图标通过。**待真机验证**见
`TODO.md` 接下来。

## 修复（2026-09-06，三端：尺子（直线）笔画出来的线细成头发丝）

用户报「直线模式下落笔后笔迹很细很细」。**根因是压感取样点**，不是线宽公式：尺子笔整笔恒为
「起点 + 当前终点」两点，而三端渲染器（`InkLayers.swift` default 分支 / `render.ts buildGeomWith`
/ `InkRenderer.build`）的线宽一律 `strokeWidthFor(末点压感)`——首点压感只用来画起笔圆点。
偏偏这个终点**每一帧都被整个替换掉**，最后留下的是**抬笔前最后一个采样**：笔尖正在离开屏幕，
压感几乎为 0 → `0.6 + p·w`（钢笔更狠，`0.3 + p^1.6·w·1.3`）当场退化成一条一两像素的头发丝。
落笔起手那一下压感也还没上来，所以快划一条同样细。普通笔迹只有笔尾那半段受影响、看不出来，
两点直线是整条线只剩这一个采样。

**改法：尺子笔的压感锁成「这一笔见过的峰值」，两个端点同值**（直线本就恒宽，峰值 =「按多重
画多粗」）。落点生成处各改一处，五个地方：`web/src/lib/input.ts`（页内）+ `scratch.ts`（草稿纸，
新增 `G.linePress`）、`android PageCanvasView.penMove` + `ScratchCanvas.stylusMove`（新增 `linePress`，
两模式共用）、Mac 接收侧 `AppModel.inkLineTo` / `scratchInkLineTo`（抽 `AppModel.linePressure`
一处实现两处用）。平板已按同规则算过一遍（本地即时回显要对得上），Mac 再取一次 max 是幂等的，
顺带兜住不带这条规则的旧采集页；模式1 的 `LocalCanvasView.onInkMove` 落库前把首点一并抬到同值。
Mac 本机 ⇧ 尺子压感恒 0.5，不受影响、无需改。

验证：`tsc --noEmit` + `build-web.sh` + xcodebuild + 安卓 `assembleDebug`/`test` 全绿。
**手感（峰值是不是「按多重画多粗」的那个粗）待用户真机验。**

## 性能（2026-09-05，Mac：触控板滚动帧率不够高）

起因是用户拿《王道2027计算机组成原理》（199MB / 340 页）报滚动掉帧。**结论：跟这个 PDF 基本无关，
是整扇窗每帧重建。**

**先排除掉的（都有实测，别再重走）：**
- 该 PDF 每页是一整张 1443×2011 的 24-bit RGB 位图、FlateDecode，解压后 8.5MB/页；单页渲染
  17~19ms（inflate 约 11ms + 缩放绘制约 7ms），与输出尺寸基本无关。工作区里另外三本王道扫描件
  同一模子（18~22ms/页），纯矢量的 A4 做题本只要 7ms。**这是物理下限。**
- **重压成 JPEG 没用**：同样 12 页转 JPEG(q0.82) 后解码+绘制 21.3ms，比走 Flate 原路的 17.2ms
  还慢，体积还涨（717KB vs 613KB/页）。这种黑白扫描件 zlib 解得比 JPEG 快。
- **降分辨率会真的变糊**：192 DPI 的源在用户常用页宽下已经要被放大 1.16×。
- `PageBuckets` 全量扫 2762 笔：Debug 0.55ms / Release 0.14ms；墨迹深比较 ≈ 0。都不是那 50ms。

**真凶（`sample <pid> 8` 一次定位）：** 主线程 8 秒里 `CA::Transaction::commit` 占 2571ms
（= 忙碌时间的 80%），同期页图渲染队列只有 85ms。每个显示周期整扇窗的 NSView 树重新布局，
三个 `NSHostingView` 各把 SwiftUI 图重算一遍：阅读区 1245ms / 侧栏 638ms / 工具栏 140ms + 约束
求解 229ms。链路是 `maybeEmit` 每帧写 `@Published scrollAnchor` → `DocTabModel` 转发
`objectWillChange` → `TabsModel` 再转发 → `SidebarPane(@ObservedObject tabs)` → 重建
`SidebarView`（6 个闭包属性，永远不相等）→ `List`/`ForEach` 全重建 → 每行 `hasLocalFile`
查一次 SQLite JOIN + 对 /Volumes/SSD 做一次 stat + 重建 `contextMenu`。

**改动：**
1. `DocSession.scrollAnchor` 降为普通属性（真相源），新增 `@Published foreignAnchor` 只在
   `origin != "mac"` 时写；阅读区改观察它。副作用（平板广播 + 进度落库）改走
   `onAnchorChanged` 回调。**根因修复**，红线注释在 `scrollAnchor` 上。
2. `WorkspaceManager.localFileFlags` 缓存 + `hasLocalFileCached`，视图不再在 body 里查库/stat；
   库变化（`refresh()`）与卷挂载/卸载时重算（`willUnmount` 那段仍然一次 I/O 都不做）。
3. `visibleStrokesByPage` 记忆化（键 = 新增的 `inkRev` + range）；`inkSnapshots` 不再逐页拿
   `i...i` 去调批量版。
4. `saveProgressThrottled` 不再每帧 cancel + 新建 `Task`（截止点本来就不随新事件后移）。

**方法论教训**（已进记忆）：`ZoomProbe` 数的是「contentBody 被重算了几次」，「长帧 100ms」
分不清「主线程被卡住」和「那段没东西要重画」，而且 `measure` 只包了我们自己那几段，
SwiftUI diff/layout/CA commit 全在打点之外——恰好就是钱花掉的地方。这类问题别再加打点，
直接 `sample`。

## 修复（2026-09-04，Mac：拔盘后副本窗口还挂着「源盘已连接」）

用户报「SSD 断开后，打开的 mirror 窗口也会出现显示 source is connected（过一会 UI 刷新没了）」。

**根因两条，缺一条都还会漏：**

① **压根没人通知副本窗口。** `AppDelegate.handleUnmount` 只处理 `openWorkspaces(onVolume:)`
——**开在那个卷上的**工作区；而副本的工作区在内置盘上，不在受影响之列。侧栏那条提示只接了
`.volumeDidMount`（插盘），**卸载一侧一个观察者都没有**。于是横幅要等到下次切窗口 / 加书 /
`willResignActive` 才被顺带刷掉，就是用户说的"过一会"。

② **在飞的那一趟会把横幅原样写回去。** 弹出 SSD 时 `handleUnmount` 会当场把副本窗口开出来，
这扇新窗 `onAppear` 立刻跑一次 `refreshNotice()` —— 那一刻卷还没卸载，`findMirrorSource` 当然
找得到源盘，于是「源盘已连接」被写上去。哪怕补了卸载观察者，这趟回来还是会覆盖掉刚撤下的横幅。
所以加了纪元号 `noticeEpoch`：卷一变就自增，后台那趟回来对不上号就**丢结果**
（但 `finishNotice()` 照走，否则 `noticeBusy` 永远放不掉，之后再也不刷新）。

**两段分开发，不能合成一条**（`.volumeWillUnmount` / `.volumeDidUnmount`，`object` = 卷 URL）：
`willUnmount` 那段**一次 I/O 都不许做**，只撤掉指向该卷的横幅 —— `findMirrorSource` 会挨个打开
候选工作区的 `library.sqlite`（包括正要走的那个卷上的），在弹出的窗口期多开一个 fd 就是 Finder
那句「磁盘正在使用中」，正是 `REQUIREMENTS.md §8.1` 那条红线。真正的重算只在 `didUnmount` 之后跑；
硬拔只发 `didUnmount`，那一条也就把两种拔法都盖住了。

**待用户在真移动硬盘上验证**（弹出 + 硬拔各一次）。

## 修复（2026-09-04，Mac + 安卓：离线镜像终于同步 OCR 识别结果）

用户报「OCR 相关的东西好像没能在 mirror 同步，包括设置以及 OCR 的结果」。

**根因是方案与实现不符**：`OFFLINE-MIRROR-PLAN.md §4` 那张表里 `ocr_page` 一直写着
「✅ 双向 `INSERT OR IGNORE`」，但两端代码里一行都没有 —— `MirrorFp.specs` 没收它，
只在旁边留了句「纯 additive 不需要 base」的注释就没有下文，于是 `MirrorDiff` / `MirrorApply` /
`MirrorStore.snapshot` 从头到尾看不见这张表。建镜像那一刻的结果靠 `VACUUM INTO` 整库复制带过去
了，所以初看像是"同步了"；之后两边各自跑的**永远互不相见**。用户说的「书本开启 OCR 没同步」
是同一个 bug 的表现：那个开关不落库，`DocSession.reloadOCRState()` 数 `ocrPageCount > 0` 推出来，
缓存没过去它自然就是关的。

改法（细节与取舍见方案新增的 §4.1）：`MirrorDiff.OCRKey` + `Plan.ocrToSource/ocrToMirror`
（只带键不带 payload，干跑不许读几百 MB 的 JSON）→ `MirrorApply.fillOCR` 在事务外双向补齐
（additive、幂等、`INSERT OR IGNORE` 覆盖不掉对面已有的那份）→ 干跑报告多一条「补齐文字识别
结果」并按书展开。三个刻意的取舍：**删除不传播**（清缓存＝腾空间，不是作废）、**不参与
「副本→源必须人工确认」那条不对称**（它不进 `sync_base`，没有可被抹掉的证据，挡住只会让人白花
一次 API 钱）、**不计进 `pendingToSource`**（它不是用户产出）。

**OCR 的引擎选择与 API key 不在此列**：引擎在 UserDefaults、key 在 Keychain，都是设备本地事实，
按原设计不进工作区（密钥尤其不该进共享文件夹）。换台机器仍要自己填一次 key。

验证：Mac 五个镜像 spike 全绿（`mirror-apply` 50 项含新增 ⑦ 段 13 项、`mirror-autopush` 17 项
含新增 ②.5 段 5 项、`mirror-diff` 58／`mirror-build` 50／`mirror-multi` 27／`mirror-fp` 50）；
安卓 `./gradlew test` 的 `MirrorDiffTest` 10 项通过，插桩的 `MirrorApplyTest` 新增一例
**已编译未运行**（手上没有设备）。

## 改动（2026-09-03，Mac：OCR 页的文字选择改用「单字框」，不再按权重猜字宽）

用户报「现在的算法总是选半个字很难受」。

**⚠️ 旧 OCR 缓存全部失效、需重跑**（用户当天拍板「问题不大」）：`PaddleOCR.providerID` 从
`paddle-ppocrv6` bump 到 `paddle-ppocrv6-w`，`ocr_page` 按 provider 做键，于是老行不再命中、
按需重新识别；老行留在表里不管（不占逻辑，只占点空间）。**副作用**：已 OCR 过的书重开时
`ocrPageCount` 归零 → OCR 文本层不再自动启用，要重新跑一遍才回来。

### 根因

`rec_boxes` 只有**行框**，行内字位靠 `OCRTextSelect.charWeights` 摊（CJK 1.0 / ASCII 0.55 /
空格 0.3）。全角标点实际排版比一个汉字窄得多，权重却按 1.0 算，误差沿行累积——越往行尾偏得
越多，就是「选半个字」。（实测首行：末字与「行宽等分」的偏差累积到 +25.7px ≈ 0.77 个字。）

### 解法：`returnWordBox`

提交时 `optionalPayload` 多带一个 `"returnWordBox": true`，模型仍是 PP-OCRv6。
**百度那三份 AI Studio 文档都没列这个字段**（用户给的 Fmfz6oh2e / Kmfl2ycs0 / Cmkz2m0ma 三页
只列到产线层参数），2026-09-03 拿真实页图实测云端认——响应里多出 `text_word` +
`text_word_boxes` 两列。中文按**单字**切、拉丁按空格切词；底层是 CTC 时间步对齐，是真实字位
不是等分。

- 实测 `''.join(text_word) == rec_texts` **27/27 逐字节相等**，所以「第 i 个条目 → 原文哪几个
  字符」是精确映射，不用做模糊对齐。
- **PaddleOCR-VL 这条线拿不到单字框**：它是 VLM 自回归生成 Markdown，压根没有 CTC 时间步对齐。
  要单字框只能走 PP-OCRv6 / PP-StructureV3 这条 CTC 检测+识别线。

### 🔴 只用框的中心，不用框宽

云端给中文字的框宽是**全行均值**（清一色 36~37px），给标点/窄字母的框会退化成 1 个 CTC cell
的细条——实测「，」只有 **4px ≈ 12% 汉字宽**。所以边界取**相邻字心的中点**、两端夹到行框；
重建后那个「，」拿到 **97.6% 汉字宽**。完整推导在 `OCRTextSelect.boundsFromWordBoxes` 注释里。

字心的抖动是纯量化误差：相邻字心间距全是 4.57px（= 行宽/CTC 列数）的整数倍，即 **±7% 字宽**，
远小于权重法的累积偏差。

### 落地

- `TextRun` 新增可选 `chars`（行框内比例 0~1，单调不减，`count == 字数+1`，首 0 末 1）。落库
  JSON additive，老 payload 缺这个键即解成 nil → **自动回落权重近似**；`chars` 个数对不上 /
  非单调 / 越出 [0,1] 也一律回落。两条路都走 `OCRTextSelect.bounds` 这**一个入口**，命中与裁剪
  口径才一致。
- `clip` 会把 `chars` 按子区间重新归一化跟着切下去，子行框还能继续被裁；但**原行没有单字框时
  不凭空造**（权重逐字独立，子串重摊与整行切片本就等价）。
- 边界值收成 4 位小数（1/10000 行宽 ≈ 0.14px，远细于 CTC 量化）——不收的话 JSON 里全是
  `0.42372881355932203` 这种 19 位字面量。payload 体积实测 **×2.13**（340 页的书 1.7MB → 3.6MB）。
- **不碰线格式、不碰安卓**：`TextRun`/`ocr_page` 都不在 `PROTOCOL.md` 上，安卓只镜像 `ocr_page`
  表、不消费它做选择。

### 验证

- `spike/ocr-char-select-test.swift` **61/61**（原有 25 条一条没动，无回归）。
- 新增 `spike/ocr-parse-test.swift` **13/13**，跑真实云端响应样本 `spike/ocr-wordbox-vector.jsonl`
  （裁到只剩 parse 消费的四个键——原始响应里的 `inputImage`/`ocrImage` 是**带签名的预签名 URL**，
  不入库）。它守的是**与云端的字段契约**：哪天 `text_word`/`text_word_boxes` 改名或换形状，这里
  先红。样本 807 个字逐个验过「格内取点必命中该字」「每个字都能单独裁出」。
- `ocr-watermark-test` 29/29、`xcodebuild` Debug 绿。**用户 2026-09-03 实测通过。**

### 两个假警报（都写进注释了，别重踩）

- `x86` / `call` / `ECX` 这些半角字母的格宽只有「行宽÷字数」的 31~49%——**是对的**，中英混排行里
  半角本来就占半个汉字宽。别拿「行宽÷字数」当每个字的应有宽度。
- 3 字短行「机教育」中间格 63%——文本检测框带 unclip 外扩，短行里这点 padding 占行宽比例大，
  会把平均值抬高，与字位无关。故等宽断言只对 ≥8 字的纯汉字行生效。

## 改动（2026-09-03，Mac：扫描件的平铺水印块不再进文字选择）

用户报：扫描件上大块的独立水印（「王道计算机教育」，常被裁掉半截、字也认错）被 OCR 认成一堆
大字块散在正文里，`OCRFlow.columnGroups` 又只看几何相邻，落进正文列的水印块会被并进正文分组
——拖选正文就带出一串水印碎片，复制出来全是噪音。

### 判据：几何 + 跨页统计，不认具体文字（`Sources/App/OCRWatermark.swift`，纯函数）

- **候选** = 行高 ≥ 2.5×页内行高中位数 **且包围盒近方形**（w/h ∈ [0.7, 3.5]）。近方形是**斜排**的
  签名：n 个字水平排 w/h≈n、竖排 ≈1/n，只有旋转 ~45° 才让水平包围盒接近正方。于是竖排框图标签
  （w/h≈0.28）、整行水平大字标题（w/h≈11）压根进不了候选，天然免疫。
- **跨页重复** = 候选的位置格（4% 网格 + 3×3 邻域容错，容同一水印在不同页的中心漂移）或归一化
  文本，在 ≥ max(8, 6%×页数) 页出现。绝对下限 8 是必需的：章标题也在每章固定位置，一本书几个章
  刚好卡在 5~6 次，阈值再低就会误杀。
- **同页伙伴兜底** = 一页里候选 ≥3 个、且某块与同页另一块文本相同或有 ≥2 字公共子串（把
  「算机教育」「卓机教育」「算机」认成一家）。这条不需要样本量，供刚开始逐页识别时用。

**指纹一次性从库里读全书**（新增 `LibraryStore.allOCRPayloads`，JSON 解码放后台 Task）——阅读区
是逐页懒加载的，翻开第一页时手上只有 1 页、跨页重复无从谈起；而库里往往整本都跑完了（打开文档
自动启用 OCR 就是凭这个）。边识别边读的新书每多攒 8 页重建一次指纹。

### 落地面：`ocrVisibleRuns` 是唯一出口

- `DocSession.ocrVisibleRuns(page:)`（滤过水印）供**选择/复制/⌘A/OCR 搜索/分组/调试上色**；
  `ocrRuns` 仍是真源，只给落库与建指纹用。🔴 `ocrGroups` 的下标是按**可见行**算的，
  混用两者即错位——三个派生缓存（可见行/掩码/分组）统一由 `invalidateOCRDerived()` 一起清。
- OCR 搜索也改走可见行：不然搜书名里的字（扫描件水印常就是出版方名字）会命中满屏水印碎片。
- OCR 面板加开关「忽略平铺水印块」（默认开）；开「显示识别块（调试）」时被剔除的块画成
  **灰色虚线框**，一眼看出哪些没进选择。

### 实测

《王道 2027 计算机组成原理》340 页 21842 行：候选 2569、判水印 2563，剩下 6 条全是正文章标题
（「第2章」「3章」「第4章」「第5章」「6章」），**零误伤**；同库另一本无水印的排版书候选数 0
（不动一行）。只喂 6 页样本时靠同页伙伴仍抓到 42/48。
验证：`spike/ocr-watermark-test.swift`(29 项手造样本)／`spike/ocr-watermark-real.swift`
（连真实工作区库回归，改阈值必跑）／`ocr-char-select-test`(26)／`xcodebuild` 全绿。
**用户 2026-09-03 实测通过**（「效果很好」）。

## 改动（2026-09-02，三端：平板也能撤销/剪切复制粘贴 + 安卓按钮整体收 15%）

Mac 端那套（见下一条）铺到 web 采集页、安卓模式2、安卓模式1。

### 线格式：两个新上行 op（`PROTOCOL.md` 先改）

- **`undo` 0x4F**（`u8 redo`）：**撤销栈只有 Mac 一份**，平板只是一个按钮。平板**不做乐观预览**
  ——撤销要么整步成立要么不动，没有中间态可预览，而抢先撤了再被真源纠正是最难看的一种闪烁。
- **`clip` 0x51**（`u8 op` · `u32 page` · `f32 nx` · `f32 ny` · 〔可选〕多边形尾部）：
  `0=copy 1=cut 2=paste`。剪贴板是 **Mac 的系统剪贴板**，线上不传数据——于是平板复制的东西
  可以在 Mac 上粘、也能粘进另一篇文档。copy/cut 的选区语义与 `lassoMove` 逐字相同（Mac 用真源
  复判命中，不信平板的本地判定）；paste 的 `nx,ny` 是落点，内容包围盒中心对齐到它。
- 三端编解码器同步 + 跨语言向量 5 条（#91~#95）：Swift `wire-codec-test` 100 项、
  JS `wire-cross-test` 190 项逐字节比对、安卓 `WireCodecTest` 95 条向量，全绿。

### Mac 端接活

- `lassoApply` 里的命中判定拆成 `lassoHits`，与剪贴板 copy/cut 共用（复制不该顺带广播一份全量镜像）。
- 粘贴的**摆放数学**抽成 `InkPaste`（纯函数）：Mac 本机 ⌘V 与平板 `clip paste` 共用一份。
  抽它的直接原因是后者——阅读区那版把「算落点」和「读视图几何」缠在一起，平板路径根本没有视图可读。
- 平板发起的撤销按「此刻开着哪张画布」选栈（草稿纸 / 页内），与 Mac 上 ⌘Z 语义逐字一致。

### web 采集页

顶栏加撤销/重做（常亮）+ 框选模式下才出现的剪切/复制/粘贴；剪切/复制没选中就灰掉。
粘贴落点 = **视口正中**那一页那一处（平板没有鼠标指针）。新增 5 个图标（undo/redo/scissors/copy/paste）。

### 安卓两模式

- `shared/PageCanvasView` 加三个入口（`requestUndo`/`requestClipCopy`/`requestClipPaste`）+ 两个
  注入钩子（`onUndoRequested`/`onClipCommit`）+ 选中集变化回调 `onLassoSelChanged`
  （**写成 `lassoSelection` 的 setter**：这个字段有七八处赋值点，逐个补调用迟早漏一处）。
  另加 `onEraseBegin`（一次擦除拖动动手之前叫一次，模式1 的撤销栈要在那时留快照）。
- **模式2** 照旧只发帧。**模式1 本机就是真源**：`LocalCanvasView` 自带一条撤销栈 + 进程级剪贴板
  `InkClipLocal`。栈存的是**整份可见笔迹的快照**而不是 Mac 那种增量——`Stroke` 是不可变 data class，
  一份快照只是一串引用；恢复直接走既有的 `reconcileStrokes`（擦除在用的那条），
  连「隐藏图层一条都不碰」的规矩也一起继承了。**模式1 只管笔迹**，注解不进栈（记在 TODO）。
- 顶栏按钮：两模式同一批键、同一套文案与可见性规则（`shared/TopBar` 本来就是共用的那一条栏）。

### 安卓按钮整体收 15%（用户 2026-09-02 要求「太大了」）

`Ui.TOUCH` 48→41、`Ui.ICON` 22→19、`TopBar.BAR_H` 56→48。**这三个数一改，全 App 的图标按钮
一起变**（顶栏、草稿纸浮条、参考窗、抽屉都走 `Ui.iconButton`）——这正是「整体缩小」的意思。
原来那条「触摸目标不缩：48dp 是无障碍下限」的注释同步改掉了（代码与注释不一致比不改更糟）：
这个 App 的图标按钮全是密排的，目标之间没有别的可点物，41dp 对笔和手指都还宽裕；40dp 以下就别调了。

## 改动（2026-09-02，Mac：编辑撤销/重做 + 笔迹剪切复制粘贴（跨页/跨文档/跨草稿纸））

用户要的两件事：「编辑优化 undo redo 支持」「笔迹框选后支持剪切粘贴复制（这样就能实现跨页粘贴了）」。

### 撤销栈：增量而不是快照

`Sources/App/InkUndo.swift`（纯逻辑、无 UI 依赖，spike 直接可测）+ `DocSession+InkUndo.swift`（薄封装）。

- 一步 = 一条 `InkPatch`：**只存受影响的那几条**的 `before`/`after`（外加 `before` 的原下标，
  撤销一次删除时插回原位、z 序不乱）。写满的文档几千条笔迹几十万个点，整份快照压一步就是几百 KB。
- 增量与落库天然同构：`persistInk`/`persistTextNotes` 本来就是按 id 比值快照，撤销把值改回去之后
  它照常认得出「哪几条 upsert、哪几条 delete」——**没有另开一条持久化路径**。
- 记账口径：所有改 `strokes`/`textNotes`/`scratchStrokes` 的动作从 `session.inkEdit("Move", kind: .move) {}`
  里走一遭，前后一比就是增量。唯独**收笔**（`inkEnd`/`scratchInkEnd`）走 `recordAdded` ——
  那是最热的路径，纯追加自己就知道差在哪，免掉一次整表 diff。
- **连续擦除并成一步**：一次拖动每 8ms 就来一批擦除点，一批一条会当场把栈冲爆。同种类 + 未封口 +
  1.2s 时间窗内即合并（`InkPatch.merge`：before 留最早、after 换最新）；抬笔封口
  （`endInkOrRadial` / 本机手势 onEnded / 草稿纸手势 onEnded）。
- 两条栈：页内（笔迹 + 文字注解）一条、草稿纸一条，`activeUndo` 按「纸开着没有」选——⌘Z 跟着眼前
  那张画布走。**瞬态不落库**，换文档即 `reset()`（增量指的是上一篇那些 id，套到新文档上就是凭空造笔迹）。
- 覆盖的动作：书写 / 擦除 / 框选移动 / 框选缩放 / 删除 / 粘贴 / 文字注解增删改 / 图钉拖动 /
  Inspector 里删该页笔迹与删注解。**平板发起的那条路径（`applyLassoMove`/`applyLassoScale`/
  `applyTextNote`/`inkErase`）同样记账**——在 Mac 上 ⌘Z 就能撤掉平板刚做的那一步。

### 菜单：⌘Z / ⇧⌘Z 与剪贴板四项

- Edit 菜单加 Undo/Redo，标题跟着栈顶走（「撤销 移动」/「撤销 擦除」），空栈即灰
  （`MenuActions` 实现 `NSMenuItemValidation`）。
- 🔴 **撤销的分流判据与 Copy 那四项反着来**：先判焦点、后 `sendAction`。`undo:` 会被响应者链上不少
  东西认领（字段编辑器、WKWebView，SwiftUI 还可能在窗口上挂自己的 UndoManager），先发出去就等于把
  阅读区的撤销**永远**交出去了。焦点确实在文本框/网页里才让给系统。
- Cut/Paste/Delete 补上「没人接就发通知给阅读区」的回退（从前只有 Copy/Select All 有），四项收成一个
  `route(_:to:sender:)`，顺手打一行点——「⌘V 一点反应都没有」这类静默失效，第一眼要看的就是它被谁吃了。

### 笔迹剪贴板（`InkClipboard.swift`）

- 走系统 `NSPasteboard` 自有类型 `tech.xvanturing.unireader.ink`，于是跨窗口/跨文档/跨工作区天然都通；
  条目编码**直接复用落库那套 payload**（`InkStroke.toNote` / `init?(note:)`），模型加字段时不必两处维护。
  另附一份纯文本（注解正文）当兜底。
- 读回来时**每条换新 id**：与源共用 id 的话，同篇文档里粘一次就把源覆盖了（`persistInk` 按 id 对账）。
- **粘贴落点 = 粘贴那一刻指针所在的那一页**（`scratch.cursorP`，与右键「在此添加批注」同一个光标源）
  ——这就是用户要的「跨页粘贴」：第 3 页复制、滚到第 40 页粘。指针不在页上（走菜单、指针在页间空隙）
  就落到当前页原位并错开 0.02，免得完全压住源。位移同样**先夹再整体平移**（`InkEdit.fitTranslation`），
  撞页边只是停住、不会被逐点摁扁（那是 2026-08-30 「框选移动把笔迹压缩了」的老账）。
- 跨文档粘贴时源图层/笔记类型多半不存在于这一篇：图层落到当前作画图层，类型回落通用——不造孤儿。
- 粘完即选中 + 切到框选工具，接着拖就能摆位置。
- 入口：Edit 菜单四项、阅读区右键菜单、⌫/⌦ 删除选中集（Esc 监视器扩成 Esc + 删除两支）。
  ⌘C 一键两用：有框选选中集就复制笔迹/注解，没有才退回复制选中文字。

### 真机验收（2026-09-02，用户）

页内：撤销/重做笔迹 ✅、跨页复制粘贴与剪切 ✅、右键四项 ✅；草稿纸：撤销/重做 ✅、剪贴板 ✅
（「可以 效果不错」）。剩余零星条目见 `TODO.md` 「接下来 0.5」。

**踩了一次**：用户第一次试「⌘Z 没反应」——我全程只用裸 `xcodebuild`（默认 DerivedData）验证能不能
编译，而他双击跑的是 `build/dd/.../UniReader.app`，那份包里压根没有这些代码。查法是对的（先确认
在跑的是哪份包：`ps -Ao pid,lstart,comm | grep UniReader.app` + 看包内 `Localizable.strings`
有没有新文案），但本来不该发生：**交给他测之前必须往 `build/dd` 构建一次**，并提醒 ⌘Q 退旧进程
（覆盖构建换不掉已经跑着的那个）。

### 补：草稿纸也接上剪贴板（同日，用户验完页内那半边后报「草稿纸里面没有复制粘贴，也没有右键」）

原本划在范围外的理由是「纸是画布点、页是页内归一化，跨空间要先定换算约定」。定了：
**1 个页宽 = `ScratchPad.pageRefWidth`（800）画布点** —— 这不是新造的常数，正是草稿纸上垫着的那一页
的铺法（三端契约，`ScratchPad.pageRect`），于是从纸上抄一段公式粘到页边，大小与在纸上看到的一致。
y 另乘页的纵横比（归一化 y 相对的是页高）；**线宽不换算**——页内笔迹的 `width` 本来就是「显示点」
这个绝对量、与页面大小无关，同橡皮 `eraserRefWidth` 那条换算的口径。

- 剪贴板 payload 加 `space`（page/canvas）+ `aspect`（源页纵横比），粘贴方按需折算
  （`InkClipboard.scaled`）。**`init(from:)` 手写**：合成解码器遇缺键会抛，那样上一版留在剪贴板里的
  内容就永远粘不出来且毫无提示（⌘V 静默无反应）——同 note payload「新键一律兜底」的既有惯例。
- 序列化前一律抹掉 `padId`：剪贴板里只有「一团笔迹」，落到纸上还是页上由粘贴方决定
  （留着它草稿纸笔迹会以 kind=4 进剪贴板，粘到页里就是看不见的孤儿）。
- 草稿纸：右键菜单（剪切/复制/粘贴/删除，原生 `.contextMenu`）+ Edit 菜单五项 + 撤销/重做，
  六条 onReceive 抽成 `editRoutes` 一层（同阅读区，防类型检查器超时）。落点 = 指针处，无 clamp
  （画布无界，同 `shifted` 不走 `InkEdit.translated` 的理由）。粘完即选中 + 切框选工具。
- 认领分工：纸开着时这批动作全归纸（`claims`），阅读区那边按 `openPadID == nil` 让开——
  ⌘C 也一并让开，否则纸开着时 ⌘C 会去复制底下那页的选中文字。

### 验证

`spike/ink-undo-test.swift` **40/40 通过**：diff/apply（新增/删除/改值/插回原位）、撤销-重做往返、
擦除合并与封口、新动作作废重做链、栈深封顶、注解走同一套、剪贴板往返（新 id / 逐字段还原 / 文本兜底 /
`padId` 被抹 / 缺 `space` 键的旧内容兜底）、页 ⇄ 纸换算往返无损（用私有命名剪贴板跑，不动用户的系统剪贴板）。视图层与菜单一如既往零覆盖，待真机手测（清单见 `TODO.md`）。

## 改动（2026-09-02，Mac：大工作区打开慢 —— 量化后修掉两处读路径）

用户报「稍大的工作区打开速度就很慢」，先量再改（剖析脚本 `spike/workspace-open-profile.swift`，
在**库副本**上跑：`LibraryStore.init` 会 migrate，不能拿用户的库量）。

样本：3 篇文档、`note` 表 3506 行 / 13.9MB payload（页内笔迹 2066 条 8.9MB + 草稿纸笔迹 1411 条
5.4MB，全挂在 586 页那一篇），库文件 23.8MB，PDF 本体 353MB。冷启动 `restoreTabs` 恢复 3 个标签，
每篇都要走一遍 `DocTabModel.load()`，**全部同步在主线程**。

### 量出来的账（单篇，热缓存）

| 段 | 改前 | 改后 |
|---|---:|---:|
| `notes(documentId:)` ×5 | **1090 ms** | **31 ms** |
| 解码 InkStroke（kind2 + kind4） | 239 ms | 239 ms |
| `PDFDocument(url:)` / 目录 / 逐页 bounds | 55 ms | 55 ms |
| 合计 | ≈1.39 s | ≈0.33 s |

（冷启动另加 PDF 冷开 ~440ms + 解目录 ~230ms，那是 PDFKit 与 353MB 文件的账，本轮没动。）

### 根因一：五个 loader 各读一次全表

`inkStrokes` / `textNotes` / `highlights` / `aiThreads` / `scratchStrokes` 全都调
`notes(documentId:)`（`SELECT * FROM note WHERE document_id=?`，**无 kind 过滤**），把 13.9MB
连同全部 payload 读回来，再在 Swift 里 `compactMap` 筛 kind —— 一次开档读了**五遍全表**。
新增 `LibraryStore.notes(documentId:kind:)`，五个 loader 各查各的（0 文字注解 / 1 AI 会话 /
2 页内笔迹 / 3 高亮 / 4 草稿纸笔迹）。总行数从 17530 降到 3506。

### 根因二：每行两个 ISO 时间戳都过 `ISO8601DateFormatter`

拆解那 270ms：SQL + 建行字典 61ms、**时间戳解析 209ms（77%）**、只取需要的列 7.7ms
（真正的磁盘 I/O 几乎免费）。而笔迹那 99% 的行根本不读 `createdAt`/`updatedAt`
——`InkStroke(note:)` 只取 id/page/payload。

`ISO.date` 改成：规范形态 `YYYY-MM-DDTHH:MM:SS.sssZ` 走手写解析（days-from-civil，
不碰 `Calendar`/`DateComponents`），认不出来的照旧回落 formatter。约 30µs → 0.2µs。
🔴 秒的上界取 **59** 而不是 60：闰秒 `…:60Z` 被 formatter 判为非法，两边结论必须一致。

验证：拿真库全部 **7410 个时间戳** + 18 个边界/畸形串逐个与 formatter 对比，全一致；
`store-test`(50) / `ink-store-test`(21) / `scratch-store-test`(53) / `ocr-store-test`(15) 全绿。

### 还剩什么（没做，留着）

- **草稿纸笔迹的 96ms 解码**：`loadScratch` 在开档时把全部 1411 条都解了，而草稿纸默认一张都不打开。
  改懒加载的拦路虎是 **pad 归属在 payload JSON 里、没有 `pad_id` 列** → 删纸时无法只按 pad 删，
  得先把 kind=4 全读回来。可行但要动删除路径，单独评估。

## 改动（2026-09-02 下午，Mac：后台标签懒装载 + 阅读区磁盘页图缓存）

接着上面那条。用户追问「是不是启动一次下次会快」——是，而且那是 **macOS 的文件缓存**，
不是 app 存了什么：同一份二进制连跑两遍剖析，`PDFDocument(url:)` 442→24ms、目录构建 247→25ms、
逐页 bounds 20→6.5ms，每篇大书约 **0.64s 纯粹是「第一次从盘上读」**（工作区在外置 SSD、PDF 353MB）。
于是两条一起做：**别装那么多**（懒装载）+ **让渲染成果活过进程**（磁盘缓存）。

### 一、后台标签懒装载

`restoreTabs` 从前逐个 `select`，等于冷启动就把每一篇的 PDF、目录、笔迹全读一遍——**而一扇窗里
只有一个标签看得见**。现在一律 `stage`（只记 id 不装），由 `activate` 把用户上次停在的那一个装出来；
其余等切过去再装（安卓模式1 早就是懒装 + LRU 保活 3 篇）。

🔴 **懒装载的头号陷阱是把进度抹了**：没装载过的标签 `session` 是空的（第 0 页、缩放 1），
而「关窗结清」和「切走时存旧文档」两条路都会调 `saveProgress` —— 存下去就等于把库里那篇真正的
进度清成开头。守卫放在最里层出口（`saveProgress(documentId:anchor:)` 里 `guard !staged`），
两条路一并挡住。

另外两处配套：① `stage` 时把书名填进 `session.title`（平板那份会话列表读它，不填会显示「未命名」）；
② 平板可以把跟随**钉**到任意会话上，包括还没装载的后台标签 —— `TabsModel` 订阅
`padSelectedSessionID`，钉过来就 `realize()`，否则平板上是一片空白。

### 二、Mac 阅读区的磁盘页图缓存（`PageDiskCache.reader`）

从前只有平板 `/page.png` 那条路有磁盘缓存（`padpage/`）；Mac 阅读区的页图**纯内存**，
进程一退全没。实测（586 页那本）：

| | |
|---|---:|
| 同一页**第一次**栅格化（PDF 内容流要现解析） | 87~168 ms |
| 同进程内再渲一次 | ~41 ms |
| **磁盘命中**：解码 + 重绘进 mmap 缓冲 | **5~13 ms** |
| JPEG q85 编码（落盘那一下，在磁盘缓存自己的队列上） | 6~19 ms，一页 340KB~1.1MB |
| PNG 编码（**没选它**） | 86~228 ms |

四条纪律，都写在代码里：

- 🔴 **命中后必须把图重绘进我们自己的 mmap 缓冲**（`PageBitmap.decode`）。直接把 ImageIO 那张
  `CGImage` 塞进 LRU 的话，像素归 CoreGraphics 管、释放不还给系统，且不进 `liveImages` 的账
  ——正是 2026-08-29 那轮内存排查的病根。重绘 5~13ms，仍比重渲便宜一个数量级。
- 🔴 **盘上只存亮色那一版**（键尾 `#n0`）：夜间反色是纯像素且自逆，读回来当场反一次即可。
  省一半磁盘，也免得「白天读过的书夜里第一次开还要重渲」。
- 🔴 **贴片不落盘、缩放过程中的中间宽度不落盘**：贴片键把归一化矩形量化到 1/64，平移一格就是新键；
  而 `currentBaseWidth()` 不分档，缩放每停一下就是一整套新键。**读**永远试一次（失败的 open
  只要几十微秒），**写**由调用方用 `Request.diskCache` 挑（稳定态的整页基图 + 侧栏缩略图 + 参考窗）。
- **编码也甩到磁盘缓存自己的队列**，不占渲染队列；队列里最多压 8 张（闭包捕着 mmap 缓冲，
  快滚时 LRU 淘汰比排干快，压太多等于替它续命）。丢一张只是下次慢一次。

验证：新增 `spike/page-disk-cache-test.swift`（11 项：键的亮/夜换算、贴片键判别、
**解码图计进 liveImages 且释放后退出**）；`store-test`(50) 回归全绿。

### 还剩什么

- 冷启动的 PDF 打开与目录构建（~0.7s，且是**活动那一篇**躲不掉的）：PDFKit 的账，
  要挪后台或懒构建目录（目录被跳转历史的「落在哪一章」依赖，要一并处理）。

## 改动（2026-09-01，Mac：工具栏分四组 + 改成系统可定制工具栏）

用户两句：「toolbar 再分几个组吧，后面几个全在一起也不好」→「把夜间模式也加到可选显示的…
事实上都可以加到可选…你看下我们自己做和 macOS 自带的 toolbar 编辑有啥区别，SwiftUI 能不能做」。
拍板：**走系统那套**（`.toolbar(id:)`），设置页不再放显隐开关。

### 分组：按「做什么」分，不按加进来的先后

缩放 │ **去哪儿**（目录/返回上一位置/跳转历史）│ **这一篇怎么读**（文字识别/画板/夜间）│
**另开一块**（参考窗/平板），右端 Inspector 单独一枚。组与组之间靠 `ToolbarSpacer()` 断开——
不插的话 Tahoe 把相邻 item 粘进同一胶囊（CLAUDE.md 2026-07-28 那条实测规则的另一半用法）。

### 可定制：11 枚各自带 id

`.toolbar { }` → `.toolbar(id: "reader") { }`，每枚 `ToolbarItem(id:)`（`zoom.out`…`inspector`）。
用户可增删、排序、切「仅图标 / 图标和文字」，系统按 id 持久化，多窗口共享。

- 🔴 **`ToolbarItemGroup` 进不来**：它不是 `CustomizableToolbarContent`，SDK 里没有 id 版本
  （只有 `ToolbarItem`/`ToolbarSpacer` 有）。分组只能靠「相邻自动合并 + spacer 断开」。
- 🔴 **item 的 id 一旦发布就不能改**：系统按 id 记用户摆好的位置，改 id = 那枚变「新按钮」弹回默认位。
- 缩放三枚原来是裸 `Image`，改成 `Label`：标题不上屏，但**自定工具栏面板靠它显示名字**。
- Inspector 那枚 `.customizationBehavior(.disabled)` 钉死：它是笔记/目录/信息整个面板的唯一入口。
- 设置页三个 `@AppStorage` 开关（`showTOCButton`/`showOCRButton`/`showJumpHistoryButton`）全删，
  「工具栏」那栏换成一句指路——两套状态并存必然打架。

### 🔴 三处 AppKit 兜底（`Sources/App/WindowAccessor.swift`，全是日志实测逼出来的）

`.toolbar(id:)` 只是**声明内容可定制**，右键菜单里那条「自定工具栏…」归 AppKit 管，它看的是
`NSToolbar.allowsUserCustomization`——而 SwiftUI 不开它，也没给对应修饰符。排查全程靠
`ToolbarCustomizationEnabler` 往 `~/Library/Logs/UniReader-ws.log` 打点（先打点再改码）：

1. **打开那两个开关**（`allowsUserCustomization`/`autosavesConfiguration`）。必须**重试**：
   工具栏是 SwiftUI 在窗口上屏之后才装配的，`viewDidMoveToWindow` 那一拍 `window.toolbar` 还是 nil。
2. **持续纠正**：SwiftUI 每次重建工具栏都把开关拍回 false（实测启动阶段就 3 次）。
   KVO 盯 `allowsUserCustomization` 精准改回，**另留窗口 `didUpdate` 兜底**——AppKit 没承诺这个
   属性 KVO-compliant，只押一条万一它不发通知就是静默失效（本项目在静默失效上吃过亏）。
   日志第 1 次 + 此后每 20 次记一行，并标来源（`KVO`/`didUpdate`），跑一阵就知道哪条在干活。
3. **`ToolbarDelegateFilter` 修整面板清单**（转发 SwiftUI 原 delegate，只改 allowed）：
   · **空格类只留一份**——AppKit 的惯例是 space/flexibleSpace 在 allowed 里报一次（面板给一个，
     想拖几个拖几个），而 SwiftUI 有几个 `ToolbarSpacer` 就报几次，面板里排出一列一模一样的项；
   · **滤掉一次性 UUID 项**——SwiftUI 给标题/副标题区生成的内部项，标识符**每次启动都不一样**
     （三次运行三组不同 UUID），面板里显示成当时的窗口标题/页码（«Open PDF…»、«301»）；
   · **只改 allowed，不动 default**：default 是实际摆放，那三个空格正是四个胶囊的分界。
   🔴 `NSToolbar.delegate` 是 **weak**，包完必须强引用原 delegate，否则 SwiftUI 那个对象没人要
   会当场释放、工具栏变空。delegate 也会被 SwiftUI 换回去，同样在 `didUpdate` 里装回来。
4. 菜单「显示 › 自定工具栏…」作保底入口（`runCustomizationPalette`），不依赖右键菜单。

实测数据（日志）：`id=reader items=22`；allowed 22 →（空格去重）19 →（滤 UUID）17。

**不走「纯 AppKit 自己建 NSToolbar」**（2026-09-01 用户问过、当场评估后否掉）：那要和
`NavigationSplitView` 的侧栏开关、`.searchable` 的搜索框、标题区抢同一个 `window.toolbar`
的所有权，失败后果是整条工具栏被换掉（搜索框和侧栏按钮一起没），赌注比「一个 Bool 被拍回」大得多。

## 新增（2026-09-01，Mac：跳转历史 + 悬浮窗）

用户需求：「跳转历史记录，方便在多个 toc 跳转，做一个悬浮窗，方便在多个历史切换」。
四条当场拍板：**记所有非连续跳转** / **窗口内浮层**（不新增 Scene）/ **历史按文档分** /
顺带做 **⌘[ ⌘] 与工具栏返回按钮**；**不落库、不上线**（不碰 `PROTOCOL.md`，不碰 schema）。

### 数据：一条线性轨迹 + 一个游标，纯值类型

`Sources/App/JumpHistory.swift`：`JumpMark` = 页 + 页内比例，**与 `ScrollAnchor` 同口径**——
于是「回到这一条」就是原样发一次锚点，不必再算任何几何；`JumpHistory` 是浏览器式的轨迹 + 游标。

**是 struct 而不是 ObservableObject**：作为 `DocSession.jumps` 的 `@Published` 存放，借道现成的
`DocSession → DocTabModel → TabsModel → ContentView` 转发链自动刷新（工具栏按钮禁用态、浮窗列表
都靠它），不必再嵌一层手工转发。每文档一份，`DocTabModel.load` 里随 `clearSearch` 一起清空。

### 记录口径：`DocSession.jump(...)` 是所有非连续跳转的唯一入口

目录 / 搜索 / Inspector 各列表 / 缩略图 / 参考窗「在主视图显示这一页」/ 平板点目录**全部改走它**
（原先各自裸调 `emitAnchor`）；连续滚动（`origin` `"mac"`/`"pad"`）与恢复进度（`"restore"`）
照旧不入历史——那些不是「跳转」，记进去只会把轨迹淹掉。

🔴 后退/前进走私有的 `goToMark`，**不记新历史**：记了就是自噬，每退一步生一条、再也退不回去。

三条防刷屏规则（全在 `record` 里，`spike/jump-history-test.swift` 34 项钉住）：
- **离开点与当前条不同处才补记**——跳完又滚了一段再跳，回得去刚才读到的地方；
- 后退到中途再跳，**前进分支作废**；
- 落到同一处（同页 ±1% 页高）、或**同一次搜索**就地更新那一条。搜索这条的判定是
  「词相同**或互为前缀**」：查找是防抖 250ms 跑一批、每批自动跳首个命中，只比相等的话打
  「傅里叶」会在历史里留下「傅」「傅里」两条半截词。

### UI：逐条照搬参考窗的浮层范式

`Sources/Views/JumpHistoryView.swift`（浮层）+ `Sources/App/JumpHistoryPanel.swift`（摆位/开关，
**窗口级** `@StateObject` + `UserDefaults` 记忆）。挂在 `ContentView.readerColumn`——与标签栏/
AI 面板/参考窗同层，同样两条理由（身份要稳、要挡得住阅读区那四个挂在 `ScrollView` 上的拖拽手势）。
拖动/改尺寸期间只动本地 `@State`、松手才写回 `@Published`（参考窗「拖拽时内容抖动」那笔账）、
标题栏条高锁死 + 标题可截断（窄窗下 `Text` 换行撑高整条）也都照搬。首次打开摆**左下角**，
错开参考窗默认的右下角。刻意**不做折叠气泡**：历史窗关掉不丢任何东西（数据在会话上）。

行没有现成名字时（缩略图/笔记列表跳转/离开点）显示**它落在哪一章**——新增
`TOCEntry.chapterLabel(for:in:)`，与 `TOCListView` 的当前章节追踪同一套 argmax（对乱序书签与
坏书签免疫）。

入口：工具栏两枚（返回 + 历史窗，`showJumpHistoryButton` 可在设置里关）、菜单 ⌘[ / ⌘] / **⌥⌘J**
（⌥⌘H 是系统「隐藏其他」，抢不得）。

### 🔴 实测坑：工具栏 Button 上的 `.contextMenu` 是死的

首版给返回键挂了 `.contextMenu`（想长按/右键弹最近 10 条），**2026-09-01 用户真机实测长按和右键
都没有任何反应**——Tahoe 工具栏的 item 不走视图那套 contextMenu。已删（连同那份菜单代码），
挑着跳请开浮窗。想在工具栏上做下拉只能换 `Menu`，而那会把这一组的玻璃胶囊拆成独立圆钮
（CLAUDE.md 里那条 2026-07-28 的实测规则），不值当。

验证：`spike/jump-history-test.swift` **34 项全绿**、`xcodebuild` 通过、**用户 2026-09-01 真机
测过没问题**（轨迹语义、⌘[ ⌘]、浮窗摆位与胶囊分组均正常）。

## 新增（2026-08-30，安卓模式1：本机新建工作区 + 添加 PDF；顺带把界面上的长段落换成一行提示）

用户两条：①「给安卓模式1 也加上创建存储库的功能」；②「做一下用户优化，移除掉页面上那种大段的
技术性的描述，按需要可以使用 tips 来提示用户」。范围经确认取**建库 + 本机导入 PDF**——只建一个
空库的话，安卓端没有任何把 PDF 加进去的入口，新建出来的工作区点不出东西，等于死路。

### 建库：DDL 只此一处，且必须与 Mac 的 v12 逐列一致

`local/store/Db` 原来的口径是「**DDL 一个字都不写**，建库永远是 Mac 的事」——那条规矩针对的是
**已经存在**的共享库（往 Mac 建的库里偷偷补表/补列，会让两端对 schema 的认知悄悄分叉）。
从零建一个新库不存在这个问题，所以新增 `local/store/Schema.kt` 收着**唯一**一份建表语句，
只在「文件还不存在」时跑一次，永不碰已有的库。DDL 从 `Sources/Store/LibraryStore.swift`
的 `migrate()` 逐字抄来（schema **v12**），只把多语句拆成列表（`execSQL` 一次只吃一条）。

- `Workspace.create(parent, name)`：净化名字（口径同 Mac `sanitizedPackageName`，另挡了
  FAT32/exFAT 上非法的 `*?"<>|` 与结尾的点）→ 建 `<名字>.unrd/{UniReader/,PDFs/}` → 建库
  → 写 `meta` 的 `schema_version`/`created_at`/`workspace_name`。**重名不覆盖**（那可能是用户真正的
  库），**中途失败连整个新建的文件夹一起删**（留半个骨架比没建成难查得多）。
- `LibraryStore.SCHEMA_VERSION` 从写死的 7 改成 `Schema.VERSION`：Mac 早就是 12，于是从前
  **每开一个正常的库都要 warn 一次**，噪音盖住了真正对不上的情况。

**跨端验证（宿主机，已过）**：拿 `Sources/Store/*.swift` 编一个小程序建一个全新的 Mac 库，
再用脚本把 `Schema.kt` 里的 DDL 抽出来在本机 sqlite3 上建一个，两边**逐表逐列**比
（列名/类型/NOT NULL/默认值/主键 + 外键 + 索引）：8 张表、5 个索引、全部一致。

### 添加 PDF：hash 是身份，文件一定拷进工作区

`local/PdfImport.kt`：**先探页数（顺带回答「Pdfium 认不认这个文件」）→ 算 SHA-256 → 再拷贝**。
顺序是刻意的，坏文件在第一步就被挡住，不会先拷进 `PDFs/` 再发现打不开、留一份垃圾。

- **内容 SHA-256 是文档的身份**（与 Mac `FileHasher.sha256` 同口径：4MB 分块、小写十六进制），
  同一份内容再导一次只多一条 location，不多出一本书。
- **与 Mac 的唯一差别是这里一定拷贝**：安卓上没有「跨设备稳定的绝对路径」这回事（换挂载点、
  拿到 Mac 上开，绝对路径一律作废），所以库里存的直接是工作区相对路径 `PDFs/<uuid>.pdf`。
- 入库 SQL（`LibraryStore.findOrCreate`）逐条照抄 Mac 的同名方法。
- 界面：书库右上角一颗「＋」/ 空态一颗「添加 PDF」→ 文件浏览器**点一个加一本、窗不关**，
  行上就地显示「添加中…／已添加／已在库中」。整轮共用**一条可写连接**（`StoreQueue` 独占线程），
  关窗才收——每本重开一次库等于每本都付一遍慢卷上的开库 + `wal_checkpoint`。

### 目录浏览器提取成 `local/FileBrowser.kt`（三种模式一份实现）

启动页那个只能选 `.unrd` 的浏览器，被「选新建位置」和「挑 PDF」各要一遍。与其抄三份异步/令牌/
卷枚举，不如提出来按 `Mode` 分：`WORKSPACE`（只有 `.unrd` 能选中）/ `FOLDER`（什么都选不中，
靠右下主操作对当前目录下手）/ `PDF`（列出 `.pdf`，点一个加一本、不关窗）。

### 用户优化：长段落 → 一行 ⓘ 提示

新增 `Ui.tip()`（ⓘ + 一行小字，可点开看细节）与配套的 `ic_info`（照旧由 `tools/icons/gen.py`
生成，不手写 XML）。规矩：**正文一句话说完，真要展开的背景知识点了才弹**。改到的地方：

| 位置 | 从前 | 现在 |
|---|---|---|
| 启动页·单写者警告 | 三行灰字（别两端同开 + 搬运带 -wal/-shm + 云盘危险） | 一行「同一个工作区，同一时间只能一端打开 · 详情」，点开才是那三句 |
| 启动页·权限卡 | 两句（为什么要 + 国产 ROM 要单独允许） | 一句「打开工作区需要「所有文件访问权限」」+ 一条 ⓘ 提示 |
| 启动页·模式卡 | 「直接读 .unrd 里的 library.sqlite 与 PDFs/…」 | 「不用连 Mac，直接读平板上的 .unrd。」 |
| 目录浏览器 | 两句口径说明 | 一行「只有 .unrd 结尾的文件夹是工作区，点它就是打开」 |
| 书库空态 | 「先在 Mac 上导入 PDF 并「拷进工作区」，再把整个 .unrd 搬过来。」 | 「还没有文档」+「添加 PDF」按钮 + 一行 ⓘ 兜住 Mac 那条路 |
| 打不开库的报错 | 四条带序号的成因清单 | 一句「可能是存储被拔出、卷只读，或库文件损坏」+ 原始错误（清单本来就没人在弹窗里读完，要查看日志更准） |

按钮也跟着收：模式1 卡片上原本竖着堆「选择 .unrd 文件夹…」+「扫描存储查找 .unrd」，
现在是一颗主操作 + 并排两颗次要的「新建」「扫描」。

### 验证

- `assembleDebug` / `test`（JVM 单测）/ `assembleDebugAndroidTest` 全绿；`gen.py --check` 全绿（32 个图标）。
- 新增 `androidTest/.../WorkspaceCreateTest`（6 项，**真机 Pad 6 跑过全绿**）：新建的工作区能被自己
  打开且 meta 对、**表结构与 Mac v12 逐列一致**、同名不覆盖、名字净化、同 hash 入两次只有一本书、
  SHA-256 与 Mac 同口径（`"abc"` 的向量）。
- **待真机**（`ANDROID-STANDALONE-PLAN.md §11.1` 新增 54~57）：三种卷上建库、大文件与 U 盘上加书、
  安卓建的库拿回 Mac 开、文案瘦身后的观感。

## 已修（2026-08-29，切标签页每次重下页图 → 磁盘缓存 + 额度按设备内存重算 / 框选一移动就没了）

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
- **第三轮（同日，用户「多缓存几页」）：额度公式本身记错了账**。`maxMemory()/3` 量的是
  **Java 堆**，而**从 Android 8.0（API 26）起 `Bitmap` 像素住在 native 堆**、压根不占 Java 堆
  ——于是 8GB 内存的平板上只肯留 85MB＝一张横屏页图。（同理**`largeHeap` 对页图没有用**，
  它只抬 Java 堆；我先前建议过它，作废。）两模式统一改成 `PageWidths.cacheBytes(ctx)` =
  **设备总内存/20，夹 64…384MB**（8GB → 384MB ≈ 8 张横屏页图，够两三篇文档的当前屏），
  低内存设备（`isLowRamDevice`）64MB。**额度大了就必须还得回去**：native 内存超支不抛 OOM，
  是整个进程被 lowmemorykiller 干掉、回来冷启，所以两模式都接上了 `onTrimMemory`——
  `UI_HIDDEN`(20) 及以上缩到背景额度 32MB、`RUNNING_LOW/CRITICAL`(10/15，**还在前台**)只砍一半
  且不动当前这屏、`COMPLETE`(80) 连位图一起让；回前台由 `onResume` 复原
  （⚠️ 这几个常量不是一条单调刻度，15 < 20，判据顺序写反就会在前台把画面丢了）。
  模式1 的 `PdfSource` 同步换成这个口径，背景标签页那 32MB 也并到 `PageWidths` 一处定义。
- **还剩两条没做**（都要先确认取舍）：模式2 解码改 `Config.HARDWARE`（像素进图形内存、几乎不占
  进程内存，代价是页图不能再被软件 canvas 读写——模式1 的 Pdfium 是**往位图里写**像素，那边用不了；
  还要备好分配失败的兜底）；或 `RGB_565`（每张字节减半，扫描件可能有色带）。
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

验证：安卓 `assembleDebug` + `test`、Mac `xcodebuild` 全绿。

**真机已验（2026-08-29 用户实测，小米 Pad 6 + Mac 模式2）**：
- 第二轮（磁盘缓存）后：「安卓比之前好多了。虽然会闪一下，但是**没有从 macOS 加载了**。」
- 第三轮（额度 85MB → 384MB + `onTrimMemory`）后：「**感觉好多了**」。
- 顺带量到的设备口径（下次别再靠猜）：Pad 6 `MemTotal` **15.97GB**、
  `dalvik.vm.heapgrowthlimit=256m`、`dalvik.vm.heapsize=512m` —— 正是「页图不住在这 256MB 里」
  的现场证据。新公式在这台机上取到封顶值 **384MB ≈ 8 张横屏页图**。

**仍待验**（见 TODO 接下来第 16 条）：额度提上去之后的**内存回归**（长时间来回切/退后台/开重应用
不该被 LMK 干掉）、框选那几条、模式1 的同款口径。另：用户报的「还会闪一下」**不是缓存问题**
——`setPages(reset=true)` 清 `images` + 滚动归零，要等 Mac 的 `viewport` 广播回来才跳到原位，
图全在缓存里也照闪。根治要让平板自己记住每篇的滚动位置（`v → scrollY/zoom`）、换文档立刻恢复，
不等那条广播。**未做，等用户拍板。**

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
