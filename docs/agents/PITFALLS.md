# 关键坑 — 实测踩过的坑全文

从 `AGENTS.md`「结构要点」拆出的全部「关键坑」条目（2026-09-26 拆分）。主文件红线一节留了最硬几条的浓缩版；动手改对应模块前先读这里全文。

## Markdown 笔记 / 引擎

- **`onLinkClick` 只捕获一次**（2026-09-20 实测）：`NativeTextViewWrapper` 在 `makeCoordinator()` 里把它存进
  协调器，而 `updateNSView` 刷新了另外五个回调（`onCaretRectChange` / `onBuildContextMenu` /
  `onInlineSelectionChange` / `onInlinePreviewKey` / `onCodeBlockSelectionChange`）**唯独不刷新它**。
  所以绝不能「先传个空闭包占位、建完 `NSHostingView` 再换 `rootView`」——首次渲染只要发生在换之前，
  协调器就永久攥着那个空闭包，点链接静悄悄什么都不发生。做法见 `MarkdownDocView.LinkRelay`：
  传一个**身份固定**的中转闭包进去，目标随后再填。
- Markdown 引擎升级前后的重排代价回归：跑 `spike/markdown-relayout-cost.swift`，见
  `docs/agents/BUILD-DETAILS.md`「第三方包」。

## App / 窗口生命周期

- 退出收缩逻辑用 `AppDelegate.applicationShouldTerminate` 置 `isTerminating` 守卫（窗口在 ⌘Q 时也会走关闭路径）。

## 设置页（SwiftUI）

- 开关/下拉「点了没反应」（2026-09-21 用户报）：`Sources/Settings/` 里的每一项**必须绑到 SwiftUI 自己的
  状态**（`@AppStorage` / `@State` / `@ObservedObject`）。拿 `Binding(get:set:)` 包一个静态属性
  （`BackupService.enabled` 那种本机全局设置）看着能跑，实则 body 里没有任何 SwiftUI 状态被读到
  → 选完不重算 → 控件立刻按旧值画回去。要跑副作用（重建定时器之类）用 `.onChange`，别写进 Binding 的 setter。

## Combine / 模型订阅

- `@Published` 在 `willSet` 发出：AppKit 这边用 Combine 订阅模型时，回调里读到的还是旧值——一律
  `.receive(on: DispatchQueue.main)` 推到下一拍再读，多个来源的刷新合并成一次（`queueRefresh` 那种写法）。

## 滚动条（NSScrollView）

- 内容高度**异步**变化（Markdown 排完版才报回来）时，滚动视图自己的 frame 没动就不会重排滚动条，竖滚动条
  会停在上一次的判断上（表现：拖宽面板后滚动条整个消失，改一下窗口大小又回来）。要它重新判断，
  **只能 `needsLayout = true` + `reflectScrolledClipView(_:)`**；🔴 **别手动调 `NSScrollView.tile()`**——
  那是给子类重写布局用的，外面调会把系统 overlay 滚动条的布局搅乱：knob 变成一小块方块卡在角上，
  竖的横的都一样（2026-09-20 实测）。
- 阅读区竖滚动条被页面盖住（2026-09-21 实测）：用户报「把右侧 Inspector 拖到最宽，阅读区竖滚动条就没了，
  滚轮滚也不回来，而且不是每次都出现」。滑块其实一直好好的（日志里 `可用=true`、矩形也对），
  是**不透明的页面画在它上面**——认这个病只看一处：**clip view 的 frame 是不是和滚动条叠在一起**
  （坏：`clip框(0,0 1200×907)` + `竖条框(1183,52 17×838)`；好：clip 是 `1183×890`）。两个成因各修各的：
  ① **页宽不能拿 tile 之后的视口宽来算**——clip 宽是 AppKit 摆放滚动条的**结果**，页宽又是它的**输入**，
  fit 模式下「页宽 = 视口宽」把横滚动条卡在要不要出现的边界上，而「clip 占满整宽 + 页宽 = 整宽 +
  竖条没有自己那一列」是个**自洽且稳定**的解，掉进去就出不来。`ReaderView.fitAvail` /
  `RefPageStreamView.availWidth` 一律按**滚动视图外框**减掉常驻滚动条那一列再留半点余量，与 tile 结果无关、
  与内容无关；滚动条样式变了（系统设置 / 插拔鼠标）要重排一次。② **拖分隔条 / 拖窗口期间 AppKit 不保证
  tile**（有几帧自己又摆对了，所以时有时无），只能在**确实叠上时**叫一次 `tile()`
  （`ReaderView.retileIfScrollersOverlapContent`，实测全程 9000 多行日志只触发 5 次）——🔴 仅限常驻样式，
  覆盖式叠着是对的、也不能对它叫 `tile()`（见上一条）。排这类问题：`touch ~/Library/Logs/UniReader-scroller.log`
  开 `ScrollerLog`（默认关，记 clip / 滚动条 / 滑块 / 分栏各格的完整几何）。

## 阅读进度 / 缩放重排

- 换基准途中算出来的位置不作数（2026-09-21 实测）：`refit` / `rebase` / `applyZoom` 都是「先按新基准重排
  文档视图、再把画面钉回原处」，而改 `fitBasis` / `docView.frame` / `magnification` 每一步都会**同步**触发
  clip view 的 bounds 通知 → `maybeEmit()` 拿**新基准**解读**还没校正的旧滚动偏移**，算出一个离谱的页码当成
  「用户滚动到这里」上报并**存进阅读进度**（实测：窗口宽 1385→1085 时，真实 p88 被报成 p112，画面随后钉回
  p88 而库里那条错的没人纠正 → 切走再回来就落在 p112）。各处 `suppressEmitUntil` 是**重排做完之后**才设的，
  挡不住这中间的自发上报，所以有 `ReaderView.relayouting` 这道门；新增任何「重排 + 钉回」的事务都要包上它。
  查阅读进度的问题别再猜，`touch ~/Library/Logs/UniReader-progress.log` 开 `ProgressLog`（`[PROG]`，
  覆盖全部会改 `document.read_*` 的路径，含离线镜像合并那条）。

## Agent 面板（NSStackView / 流式刷新）

- 增量重排 + 约束激活顺序（2026-09-21 实测）：Agent 面板的对话记录**不能每次刷新都把整排视图拆下来再装
  回去**——`NSStackView` 每增删一个 arranged subview 都要重建一整串间距 / 对齐约束，而流式回复每个碎片都
  来一次，于是「回答长了就卡」。做法是先算出这排视图应该是什么样，再只动第一处不一样的位置往后那一段
  （`AgentChatNSView.applyTranscriptViews`），最常见的情况（最后一条又长了一段、就地换文字）一动不动；
  标题行 / 提示条 / 权限卡片 / 输入区那两个下拉菜单同样「值变了才重建」。🔴 **新建的条目视图必须先进 stack
  再激活宽度约束**：约束两端要有共同祖先，刚建出来的视图还没有父视图，当场激活是 `NSGenericException` +
  「进程 abort」（改对了顺序才不崩；那次一点历史对话就崩）。另外这排视图变了要叫一次滚动条重算（见上一条），
  **面板尺寸变了也要**——正文没重排就没人报高度，滚动条会停在上次的判断上。🔴 **尺寸连着变（拖分隔条 /
  拖窗口）的整个过程里这块面板停住不动**（用户 2026-09-21 定：「拖拽过程中不更新 UI，直到松手后再重新布局
  对话流」）：`layout` 里发现距上次尺寸变化不到 120ms 就直接不摆位、起一只表等停手，停手后 `finishResize`
  按新尺寸摆位 → 叫每条正文 `flushNow()` 立刻重排（不等它自己那 150ms 防抖）→ 重算滚动条；停住期间内容还是
  旧宽度，所以面板要 `clipsToBounds`。排滚动条的问题别再猜，`touch ~/Library/Logs/UniReader-agent-scroll.log`
  开几何打点（`AgentScrollLog`，默认关）。离屏验证 `spike/agent-transcript-test.swift`（42 项：增量结果、
  零操作、约束只加一次、约束激活顺序）。

## 隐藏视图的布局代价

- 子视图看不见也在布局（2026-09-20 实测）：`InspectorViewController.viewDidLayout` 给**每一页**（含隐藏的）
  设 frame，拖分隔条时逐帧来一遍。页里挂了重排代价大的东西（Markdown 引擎、TextKit 2）就必须自己挡：
  看不见（`window == nil || isHiddenOrHasHiddenAncestor`）时只攒不排，`viewDidUnhide` /
  `viewDidMoveToWindow` 时补；宽度变化一律防抖到停手再排。

## 工具栏（Tahoe）

- 胶囊合并规则（2026-07-28 实测）：`ToolbarItemGroup` 里**只有连续的纯图标 Button（Image label）才会被系统
  合并渲染成单一玻璃胶囊分段组**；掺一个 `Text` label（如 `1:1`）整组立刻散成独立圆钮。`ControlGroup` 在
  Tahoe 工具栏里反而不分组（同样拆成独立圆钮），别再用它做工具栏分组。相邻两组想分成两个胶囊，中间插
  `ToolbarSpacer()`，否则 Tahoe 会把相邻 item 粘进同一胶囊。
- 玻璃工具栏按钮变浅（2026-09-19 录屏实测，macOS 27）：**别去改阅读区滚动视图的外框宽度**（比如并排一块
  面板让它变窄）——每改一次，内容区上方那几组玻璃工具栏按钮就被系统重判一次深浅、整几组变浅（拖窗口、
  开合 Inspector 都不会）。（那次是 SwiftUI 时代并排一块内置 AI 面板的情形；2026-09-20 Inspector 改真分栏后，
  开合同样在改外框宽度，实测**没有**复现变浅。）另：`refreshToolbarStates` 这类跟着会话每次变化跑的刷新，
  给工具栏 item 写值一律「值变了才写」。
