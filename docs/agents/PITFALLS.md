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
- **代码着色绝不能让 highlight.js 猜语言**（2026-10-05 实测）：`hljs.highlightAuto` 把 190 多种语言挨个试，
  60 行要 0.35~0.6 秒、卡主线程；写了语言的约 0.35ms/行。引擎自带的桥接层（`MarkdownEngineCodeBlocks` 的
  `HighlighterSwiftBridge`）在「没写语言」和「不认识的语言」时都退回去猜，所以不用它，Agent 面板用自己的
  `AgentCodeHighlighter`（直接依赖 HighlighterSwift）。引擎只把**闭合了**的围栏当代码块，流式时还在长的那块
  不会来问着色器，每块只在闭合那一刻着一次。
- **代码块底色必须不透明**（同日）：引擎在代码块整行画一遍 `backgroundColor()`、TextKit 又在字形底下按
  `.backgroundColor` 属性画一遍，半透明会叠出一道道深色条；它还按 RGB（容差 0.03、不看透明度）比这个颜色
  来认哪几行是代码块。`textBackgroundColor` 在 Tahoe 深色下和面板底几乎同色、纯白在浅色白面板上看不见。
- **代码块底色一不透明，引擎的两处选中毛病就露出来**（同日用户截图，引擎 fork `0.13.0-unireader.2` 修掉）：
  ① 整行底色按偶奇规则挖掉选区，但每段选区都被拉到整段高度，一行代码折成两行时两块挖空重叠、互相抵消，
  底色盖住了选区——改为每块只盖自己那一行、首末行才贴到底色上下边；② 围栏 ``` 与语言名只靠透明色隐藏，
  选中时系统按「选中文字色」重画就露出来——改为同其他标记一样按近零字号隐藏。App 这边绕不干净：
  把 `selectedTextAttributes` 去掉字色能保住围栏与语法颜色，但字形底下的代码底色又会盖住选区（离屏实测）。
- **行内公式 `$…$` 不渲染、显示成源码，先查是不是这两个原因**（2026-10-07 用户截图，引擎 fork `0.13.0-unireader.3` 修掉）：
  ① 公式里有 `\,` `\{` `\|` 这类「反斜杠 + 标点」：引擎先认 Markdown 转义再认公式，转义占掉的字符让整条公式作废，
  反斜杠还被藏起来（截图里是 `,dx`）——改为认转义时整段跳过合法的 `$…$`；② `$u(x,y)$` 这类没有运算符的
  内容被防误判规则（`$50` 这类价格不算公式）拒掉——改为整段是「字母名 + 括号参数」的也算公式。用户最初以为是
  「加粗里的公式不认」，其实加粗不影响：先查内容。另外公式结尾的 `$` 原先只靠透明色隐藏、保留正文字号
  （给整行只有公式时撑住基线），选中时被系统按选中文字色重画、压在后一个字上——改为缩小字号隐藏，
  再给它一个「正文下行高度」的负基线偏移顶替原来的作用（引擎 `InlineLatexHiddenSourceTests` 量基线与行高）。
  🔴 引擎里任何「隐藏的源码字符」都要按近零字号隐藏，只设透明色一选中就会露出来（这是第二次栽在这上面）。
  同日又修了三处（`0.13.0-unireader.4`）：③ `$y'$` `$y''$` 带撇号、`$0$` 纯数字也被防误判规则拒掉；
  ④ **一条漏认，后面整句错配**：漏认那条的结尾 `$` 会当成开头，跨着中文句子配到下一个 `$`，把中文与里面的 `**` 当成公式
  （SwiftMath 画不出公式里的中文，只剩一串 `*`）——现在 `$…$` 里有不在 `\text{}` 中的中文就不算公式；
  ⑤ `"特征函数"**（` 加粗结束不了：引擎只把半角标点当标点，`**` 前是半角引号、后是全角括号时判成不能结束。
  🔴 **别改成 CommonMark 原样的 Unicode 标点**——那会让 `的**“特征函数”**是`、`**（注）**1` 这类常见中文写法失效
  （实测造 5376 条中文加粗写法对比：改成 Unicode 标点有 504 条原来能认的不认了）。做法是标点仍只算半角，
  再加「`**` 一侧挨着中文 / 全角标点 / 弯引号 / ——  / …… 时，按挨着空白算」（只放宽不收紧：0 条退步，漏判 1852 → 456）。
- **块公式 / 行内公式整条显示源码，而上面几条都不是**：多半是 SwiftMath 不认里面的某个命令，一个不认整条失败
  （2026-10-07 用户报 `\big[`）。查法：`spike/latex-look.swift` 出样张。能一一对应的已在 App 侧 `LatexCompat` 换成同义写法
  （`\big` 一组、`\dfrac`、`\dots`、`\leqslant`、`\lvert`、`\operatorname`、`\iint`、`\pmod`、`\not=`、`\implies`、
  `\boldsymbol`、`\mathscr`、`\varnothing`、`\tag`；测试 `spike/latex-compat-test.swift`）。只能近似的
  （`cases` / `array` / `align` / `gather` / `split` 环境、`\boxed`、`\overset`、`\underset`、`\stackrel`、`\xrightarrow`、
  `\overbrace`、`\underbrace`、`\mathop`、`\limits`、`\because`、`\therefore`）用户定**不做**，改为写进给 Agent 的
  规则（`MCPTools.mathWriting`）让它别用；分段函数让它写 `\left\{\begin{aligned}…\end{aligned}\right.`（实测能渲染）。
- **Debug 包渲染公式时崩在 SwiftMath `MTTypesetter.getInterElementSpace` 的 `assert`**（2026-10-07，引擎 fork `.5` 修掉）：
  空白命令夹在关系符 / 括号 / 标点 / 运算符与加减号之间（`x = \; -1`、`(\,-1)`、`f(x)=x^2, \quad -1\le x`），
  SwiftMath 只看紧挨着的前一个元素来决定加减号算不算二元运算符，看到空白就判错，排版时遇到无效组合触发断言。
  正式版不检查断言（只是那一处间距为 0），所以只有 Debug 包崩；放宽公式识别后原来不渲染的公式开始渲染，才暴露出来。
  修法在引擎桥接层 `SwiftMathBridge.settleBinarySigns`（自己解析、按 TeX 规则跳过空白定好再交给 SwiftMath），没 fork SwiftMath。
  🔴 **验证别经过桥接层的 `render`**：它有磁盘缓存（`~/Library/Caches/MarkdownEngineLatex/`，与 App 共用，`clearCache()` 会删整个目录），
  第二次跑直接读图不排版，改坏了也测不出；引擎测试 `SwiftMathBinarySpacingTests` 直接解析 + 排版。批量 / 随机测试每条包
  `autoreleasepool`、设内存上限、用 `CFFIXED_USER_HOME=<临时目录>` 隔离缓存（2026-10-07 没做这三条，2 万条测试吃满用户内存）。
- **右键点在表格上会选中一块错位的蓝框**（同日）：表格是整张画成的图，宽表格再套一层横向滚动视图
  （引擎 `WideTableOverlay`），图本身没有菜单，右键一路传给文本视图，它选中了表格隐藏源码的一个字符
  （开头的 `|`），那个字符的框是一大块。`AgentMarkdownView.contextMenu` 在点中表格时把这种选区收成插入点。
  点中哪一块按右键事件坐标换算（`characterIndexForInsertion`），认块规则在 `AgentMarkdownBlocks`，
  🔴 必须与引擎 `BlockParser` 一致（行首 ``` 才算围栏、没收尾的不算；表格要紧跟分隔行）。

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
- 缩放中逐帧走的路径（`updateRealized` / 浮层摆放）只许挪位置，别重设内容（2026-10-07 采样）：图钉的 `draw(_:)`
  **每挪一下 AppKit 都会重画**（有没有自己的图层、`redrawPolicy` 设成什么都一样，离屏实测）→ 图钉改 `wantsUpdateLayer`
  + 按样式缓存的图；悬停文字、气泡正文、编辑图标都是「原文没变就不重设」。笔迹层按新倍率重画放后台
  （`PageInkLayer.redrawInBackground`，旧图留着、只替换不清空）。改这几处时别把逐帧重设内容加回去。

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
- **对话记录条目里别套 `NSStackView`，这排视图也别只增不减**（2026-10-10 采样 + 离屏实测）：整个窗口共用一个
  约束引擎，往对话记录里加一条，要重新求解的规模随已有条目数涨（近似平方）。Agent 连着记了几个钟头笔记（每次工具
  调用一来一回就是好几次刷新），主线程被 `NSStackView updateConstraints` / `NSISEngine optimize` 占满、整窗卡。
  原来工具调用 / 思考过程的折叠块每条套三层 `NSStackView`：仿真 40 条时追加一条 26ms、200 条 630ms；**拍平但仍用约束
  只快不到一倍**，非得让行内小件彻底不进引擎——`AgentRowView` 按 frame 摆、只报固有尺寸，折叠块折着时整条在引擎里
  只有它自己一个视图、正文点开才装上——之后 40 条 1.3ms、200 条 15ms。同时贴着底往下说时从顶上摘视图
  （`AgentChatNSView.trimTop`：超过 `AgentTranscript.liveBudget` 才摘，只摘视口顶两屏以外的，最后 `initialBudget`
  那段不动，没贴底不摘）。新加条目类型照此办。正文长高（固有高度变）只要 0.1ms，不是问题；转圈放不放在 stack 里
  也几乎没差别。离屏验证 `spike/agent-flat-row-test.swift`（65 项：与原版逐个子视图对位置、展开收起、放进对话记录不被拉伸、性能对比 + 样张）、
  `spike/agent-transcript-test.swift` 第 9 节。
- **「内容想要多宽」的约束优先级必须低于 250**（2026-10-05 离屏验证抓到）：用户消息气泡按内容收窄时，
  起初用 750 的「正文宽 = 估的宽」+ 常数 10000 表示撑满，结果窗口被撑到 1 万多 pt——窗口保持尺寸只有 500、
  `NSSplitView` 默认保持优先级 250，高过它们的偏好约束会反过来把容器撑宽。现在压在 240，撑满改用相对约束
  （气泡左边 = 条目左边 + 48），气泡也不再放进 `NSStackView`（它的贴边约束会抢）。
  离屏验证 `spike/agent-user-bubble-test.swift`（105 项 + 浅 / 深两张样张）。

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

## 平板上行 / 画板（主线程积压）

- 平板上行的高频消息（`ink` / `erase` move，**每 8ms 一批**）逐条在主线程处理：每条的成本必须**与画板总量无关**，
  否则处理不完的批次在主线程越积越多 → Mac 转彩虹圈，停手后才慢慢缓过来，看着像「时有时无」。
  2026-10-07 实测：分页画板近万条笔迹，平板擦一下 Mac 就卡死——`eraseScratchNear` 对每一批擦除点把全部笔迹逐点
  算距离，Debug 包一批 117ms。修法（`AppModel+Scratch`）：擦除点外框先筛掉远处的笔迹（一批降到 5ms），
  擦除点攒到主线程这一轮排着的消息收齐再擦一遍（慢了只是一遍的点多些，不会越积越多）。
  🔴 `s.scratchStrokes.removeAll { }` 这类**就地改 `@Published` 数组**不管删没删都会发一次变化，下游
  （落库对账、出图对账、平板镜像）整块画板白过一遍——先算出结果，真变了再赋值。
- 查这类「一操作就卡」：**先开连续采样再让用户复现**（每 3 秒 `sample` 一段、只留最近几十段，
  看主线程空闲样本占比），别先猜。这次前后猜了三轮（WiFi 带宽 / 平板比对 / 平板解码）都不是，
  一段采样就看到主线程全在 `eraseScratchNear`。
