# 关键坑 — 实测踩过的坑全文

从 `AGENTS.md`「结构要点」拆出的全部「关键坑」条目（2026-09-26 拆分）。主文件红线一节留了最硬几条的浓缩版；动手改对应模块前先读这里全文。

## Markdown 笔记 / 引擎

- 🔴 **渲染成整块的表格 / 公式块，选区不许停在它中间**（2026-11-12 用户截图：从表格下面往上拖选，一块错位的底色盖住右半张表和下面几行）。
  引擎把表格源码在文本里压成零宽，只留一个被拉宽成整张表的锚点字符；拖选终点落在表上时，系统按「点在这个字符的左半 / 右半」定在它前后，
  选区就从表格中间开始。引擎 fork 改成选区（非空）一伸进这种块就扩到整块（`NativeTextView+RenderedBlockSelection.swift`，
  重写 `setSelectedRanges`，鼠标拖选、⇧方向键都走它）；插入点不动（点进表格照旧开单元格编辑）。只认「渲染图 + 源码隐藏」的块，
  源码露着的（`.visibleSource`）不管。测试 `RenderedBlockSelectionTests`。🔴 合成鼠标拖选（`postEvent` + `mouseDown`）在 `swift test`
  里能跑通但会让测试进程提前退出，别写成测试，手工探针验证。
- 🔴 **行内公式附件的基线：`bounds.origin.y = -baselineOffset`**（2026-11-12 离屏样张：公式整体飘在字上面）。SwiftMath 给的
  `LatexRenderResult.baselineOffset` 是公式在基线**以下**的深度（正数），`NSTextAttachment.bounds.origin.y` 是相对基线**往上**的偏移，
  照抄成正值就把公式抬高两倍深度。引擎表格单元格里一直是正值（表格里的行内公式偏高、行也被撑高），fork 同日一起改了。
- **表格样式 `TableAppearance`（fork，2026-11-12）**：`.grid` 默认（Perch 用），`.rounded` 本 App 打开。格子位置（`TableGeometry`）在出图时记下，
  单元格编辑框照它摆、内边距与表头字体跟样式走（`TableAppearance.Metrics` 一处定，画图 / 编辑框都读它）；宽表格的横向滚动层把裁剪区
  调成正好表格高（滚动条那一条比滚动条本身高几点），再给它的图层设圆角 + 裁边——别用图层遮罩（`layer.mask`）：可滚动区域的图层坐标
  随滚动偏移，遮罩位置要跟着算，而且离屏截图（`cacheDisplay`、`CALayer.render(in:)`）都不画遮罩，样张里看不出对错。
  验圆角就读角上的像素（`CALayer.render(in:)` 画圆角裁边）。
- **拖动改宽度（fork，2026-11-12）**：宽度 0.2 秒内连着变 = 正在拖（分隔条、窗口、SwiftUI 逐帧给宽度都算），拖动中：没人用「代码块选中」
  就不为它整篇排版（原来每帧 `ensureLayout(documentRange)`，占 73% 采样）；整页编辑器按宽度比例估总高度、只排露出来的部分；
  `.fitsContent` 且底边在视口外的，只排到视口底再按字数比例估剩下的；停手 0.15 秒精确排一次。表格**不走**省事路径——拖动中每帧
  按新宽度重画（原作者的测试要求；缩放旧图只省 1ms，用户定去掉）。测试：引擎原有的 `TableWidthChangeRestyleTests` 全过即可。
- **只读按段接口 `MarkdownDisplayRenderer`（fork，2026-11-12）**：给只显示不编辑的地方（Agent 面板、习题）用，解析同编辑器（`DocumentAST`）。
  段内换行输出 U+2028（换成 `\n` 会变成新段落、吃段距）；行内公式附件带 `sourceAttribute`（`$…$` 原文），复制时换回；`[[…]]` 的 `.link`
  是 `x-markdown-wiki:` 开头。用法见 `ACP-AGENT-PLAN.md §19`。
- **选中高亮是系统私有视图画的（fork，2026-11-13）**：TextKit 2 的选中色由 `_NSTextSelectionView` 里的一行行子视图画，**不经过** `drawBackground(in:)`
  （改它没用，实测）；行的位置来自 `NSTextLayoutManager.enumerateTextSegments(type: .selection)`。所以引擎的 `NativeTextView.init(frame:)`
  手工建 TextKit 2（容器宽 = frame 宽、跟随视图宽、高 1000 万，同 `NSTextView(frame:)`），换上 `MarkdownTextLayoutManager` 改这一种分段；
  系统调用时带 `.rangeNotRequired`（不给范围），要认出是哪段字得自己去掉这个选项。`NSTextLayoutManager` 对内容管理器是弱引用，视图要自己留着 `NSTextContentStorage`。
- **表格图片是显示时才画的**（`NSImage(size:flipped:drawingHandler:)`），颜色按画的时候的外观取。🔴 **要它画得不一样，就出一张新图，别改同一张再叫重画**
  （2026-11-13 用户实测踩到）：编辑框第一版在同一张图上改「藏哪一格」、`recache()`、把同一张图重新设给宽表格的图片视图、让窄表格那一行重新排版——
  屏幕上的图一直落后一步（刚打开叠字、换格后上一格空白），一打字整张重画成新图就对了。现在 `hiddenCell` 是出图时定的、算进缓存键，
  编辑框打开 / 换格 / 关闭时走拖动改宽度那条重画（`rerenderTablesForCellEditor` → `restyleTablesForWidthChange` + `updateWideTableOverlays`）。
  🔴 **离屏测试看不出这类问题**：`cacheDisplay` 会让每个视图当场重画，连 `CALayer.render(in:)` 读到的也是对的；「屏幕上没更新」只能靠用户实测，
  或者在测试里断言「换了一张新图」（`RenderedBlockSelectionTests` 就是这么验的）。
- **`NSTextView` 不调 `updateLayer`**：它用 `draw(_:)` 画，`updateLayer` 里设的图层边框颜色永远不生效，边框是 CALayer 默认的黑色（单元格编辑框原来就是这样）。
  图层属性在初始化 / `viewDidChangeEffectiveAppearance` 里按 `effectiveAppearance` 显式设。
- **文字视图上面的小控件拿不到光标**：`NSTextView` 每次鼠标移动都设一次输入竖线，子视图的光标区域会被盖掉；要在 `NativeTextView.mouseMoved`
  里先认出指针在控件上、直接设对的光标并跳过 super（复选框、宽表格滚动条、表格手柄都是这样）。
- **中文表格的列宽（fork，2026-11-13）**：列的最小宽度 = 最长的不能断开的一段。原来只在空格处断，中文整句算一个词 → 中文表格一律横向滚动。
  现在中日韩文字旁边按 Unicode 换行规则也算断点（`MarkdownStyler.cjkLineBreakOpportunities`，`CFStringTokenizer` 的断行单位），
  两边都不是中日韩文字的断点不算——别换成「全部按 Unicode 规则断」：那样网址会在 `/` 处断、`well-know-` 在连字符处断，英文表格的排法跟着变。

- 🔴 **`[[` 候选列表要方向键 / 回车 / Esc，必须给 `NativeTextViewWrapper` 传一个能写的 `isWikiLinkActive:` 绑定**（2026-11-12 用户报「不能用方向键选择」）。
  引擎只在这个状态为真时才把 ↑↓ / 回车 / Esc 交给 `onInlinePreviewKey`；不传就是它的默认 `.constant(false)`，它写不进去，
  键全归编辑器挪光标——`onInlinePreviewKey` 接了也白接。11-10 做候选列表时就漏了，一直没人发现。App 侧存在 `NoteLinkCompleter.wikiActive`，
  回归测试 `spike/note-link-complete-test.swift` §4。

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
  （当时 SwiftMath 画不出公式里的中文，只剩一串 `*`）——现在 `$…$` 里有不在 `\text{}` 中的中文就不算公式；
  2026-11-11（`0.14.0-xvan.9`，用户报习题题干 `若$[X]_补$=…` 显示源码）放宽为：写在下标 / 上标（`[X]_补`、`x_{补码}`）
  或 `\mathrm{}` 里的中文也算，其余位置照旧不算。同时修了「认了也画不出」：SwiftMath **解析时就丢掉所有非 ASCII 字符**
  （西里尔字母、带重音的拉丁字母除外），以前 `\text{且}` 一直是空的；桥接层改为把中文先换成公式里没用到的西里尔字母、
  解析完换回去，由 Core Text 自动换中文字体画。`_补码` 按 TeX 只下标「补」，整个做下标要写 `_{补码}`。
  原样的 Unicode 数学符号（`≤` `×` `α`）同样会被丢掉，这次没处理；
  ⑤ `"特征函数"**（` 加粗结束不了：引擎只把半角标点当标点，`**` 前是半角引号、后是全角括号时判成不能结束。
  🔴 **别改成 CommonMark 原样的 Unicode 标点**——那会让 `的**“特征函数”**是`、`**（注）**1` 这类常见中文写法失效
  （实测造 5376 条中文加粗写法对比：改成 Unicode 标点有 504 条原来能认的不认了）。做法是标点仍只算半角，
  再加「`**` 一侧挨着中文 / 全角标点 / 弯引号 / ——  / …… 时，按挨着空白算」（只放宽不收紧：0 条退步，漏判 1852 → 456）。
  ⑥ 2026-11-11（`0.14.0-xvan.10`，用户报习题选项 `若 $x, y$ 和 $z$ …` 里 `$x, y$` 显示源码）：没有运算符的内容只放行
  「3 个以内纯字母 / 带撇号 / 带括号的函数写法」三种，逗号分隔的变量列表不在其中——加了第四种：两项以上、每项 1~3 个字母
  再跟可选的数字与撇号（`x, y`、`a,b,c`、`x1, x2`、`y', z`），`$5, and $` 这类仍不算。
  🔴 **防误判规则每次只按实际漏认的写法加一种形状**，别整体放宽（比如「没有运算符也算」），否则价格、错配又回来了。
- **块公式 / 行内公式整条显示源码，而上面几条都不是**：多半是 SwiftMath 不认里面的某个命令，一个不认整条失败
  （2026-10-07 用户报 `\big[`）。查法：`spike/latex-look.swift` 出样张。能一一对应的已在 App 侧 `LatexCompat` 换成同义写法
  （`\big` 一组、`\dfrac`、`\dots`、`\leqslant`、`\lvert`、`\operatorname`、`\iint`、`\pmod`、`\not=`、`\implies`、
  `\boldsymbol`、`\mathscr`、`\varnothing`、`\tag`；测试 `spike/latex-compat-test.swift`）。只能近似的
  （`cases` / `array` / `align` / `gather` / `split` 环境、`\boxed`、`\overset`、`\underset`、`\stackrel`、`\xrightarrow`、
  `\overbrace`、`\underbrace`、`\mathop`、`\limits`、`\because`、`\therefore`）用户定**不做**，改为写进给 Agent 的
  规则（`MCPTools.mathWriting`）让它别用；分段函数让它写 `\left\{\begin{aligned}…\end{aligned}\right.`（实测能渲染）。
  🔴 **SwiftMath 的 `aligned` 只认两列**（2026-10-27 用户报习题题干）：Agent 照上面那句写分段函数，又按 LaTeX 惯用法用 `&&`
  把条件对成第二列（`&0, && n=0`，一行四格），整条失败。SwiftMath **认两列的 `cases`**（2026-09-16 的「`cases` 不认」用的是
  一列样例，报的是「只能两列」），所以 `LatexCompat.piecewise` 把「`\left\{` + 多于两列的 `aligned` + `\right.`」每两格并一格、
  换成两列 `cases`，显示与 LaTeX 一致。查列数问题：`MTMathListBuilder.build(fromString:error:)` 的错误信息直接写着「can only have N columns」。
- **Debug 包渲染公式时崩在 SwiftMath `MTTypesetter.getInterElementSpace` 的 `assert`**（2026-10-07，引擎 fork `.5` 修掉）：
  空白命令夹在关系符 / 括号 / 标点 / 运算符与加减号之间（`x = \; -1`、`(\,-1)`、`f(x)=x^2, \quad -1\le x`），
  SwiftMath 只看紧挨着的前一个元素来决定加减号算不算二元运算符，看到空白就判错，排版时遇到无效组合触发断言。
  正式版不检查断言（只是那一处间距为 0），所以只有 Debug 包崩；放宽公式识别后原来不渲染的公式开始渲染，才暴露出来。
  修法在引擎桥接层 `SwiftMathBridge.settleBinarySigns`（自己解析、按 TeX 规则跳过空白定好再交给 SwiftMath），没 fork SwiftMath。
  🔴 **验证别经过桥接层的 `render`**：它有磁盘缓存（`~/Library/Caches/MarkdownEngineLatex/`，与 App 共用，`clearCache()` 会删整个目录），
  第二次跑直接读图不排版，改坏了也测不出；引擎测试 `SwiftMathBinarySpacingTests` 直接解析 + 排版。批量 / 随机测试每条包
  `autoreleasepool`、设内存上限、用 `CFFIXED_USER_HOME=<临时目录>` 隔离缓存（2026-10-07 没做这三条，2 万条测试吃满用户内存）。
- ~~**右键点在表格上会选中一块错位的蓝框**（同日）~~：Agent 面板 2026-11-12 起按段显示，表格 / 代码块各自一个视图、自带右键菜单，
  这条连同认块的 `AgentMarkdownBlocks` 一起作废；笔记编辑区里拖选停在表格中间的同类问题，引擎 fork 同日从根上修了（本节开头那条）。

## App / 窗口生命周期

- 退出收缩逻辑用 `AppDelegate.applicationShouldTerminate` 置 `isTerminating` 守卫（窗口在 ⌘Q 时也会走关闭路径）。
- 「文件已变化」弹窗点完还一直弹（2026-10-11 用户报）：SwiftUI 版的 `.alert(isPresented:)` 关掉时 Binding 自动把
  `hashMismatch` 置空，AppKit 重写改成 `syncAlerts` 里手弹 `NSAlert` 后**没人清**它 → 每次同步看见它还在就再弹。
  模型上「待确认」类状态（`hashMismatch` / `scanAlignConfirm` …）在处理函数**第一行**清掉，早于任何会触发同步的改动。

## 设置页（SwiftUI）

- 开关/下拉「点了没反应」（2026-09-21 用户报）：`Sources/Settings/` 里的每一项**必须绑到 SwiftUI 自己的
  状态**（`@AppStorage` / `@State` / `@ObservedObject`）。拿 `Binding(get:set:)` 包一个静态属性
  （`BackupService.enabled` 那种本机全局设置）看着能跑，实则 body 里没有任何 SwiftUI 状态被读到
  → 选完不重算 → 控件立刻按旧值画回去。要跑副作用（重建定时器之类）用 `.onChange`，别写进 Binding 的 setter。

## Combine / 模型订阅

- `@Published` 在 `willSet` 发出：AppKit 这边用 Combine 订阅模型时，回调里读到的还是旧值——一律
  `.receive(on: DispatchQueue.main)` 推到下一拍再读，多个来源的刷新合并成一次（`queueRefresh` 那种写法）。
- `ImageThumbCache.image(url:maxPixel:)` 未命中时**只发起后台解码、当场返回 nil**，解好了靠 `objectWillChange` 通知。
  只取一次不订阅 = 永远停在占位图标上（AppKit 改写后 Inspector 图片条目就这样，2026-10-13 用户报；现由 `InspectorImageThumb` 自己订阅）。
  新加缩略图消费方照气泡 / 编辑器 / `InspectorImageThumb` 的写法订阅。

## 文字框（NSTextField）

- **要两行折行的标签别给 `.byTruncatingTail`**（2026-10-19 搜索结果浮窗离屏样张实测）：文字框的 `lineBreakMode`
  一设成截断就退回单行，`maximumNumberOfLines = 2` 也没用。做法：`.byWordWrapping` + `maximumNumberOfLines` +
  `cell.truncatesLastVisibleLine = true`（最后一行末尾省略），富文本里也别塞截断式段落样式。
- 折行标签的**固有高度按 `preferredMaxLayoutWidth` 算**，不给就按单行宽度算 → 只用居中约束时被压成一行。
  在所在视图的 `layout()` 里先按实际宽度设好它再 `super.layout()`（见 `SearchHitRowView`）。

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

- **用户系统设置是「总是显示滚动条」（常驻样式）**（2026-10-27 用户截图：习题练习页题目不够一屏也有一条竖滚动条）：
  新建的 `NSScrollView` 只设 `hasVerticalScroller = true` 的话，常驻样式下**不管内容多高都画一条**。内容可能不满一屏的
  一律加 `autohidesScrollers = true`（对话记录、`@` 候选早就加了）。别拿覆盖式滚动条的开发机效果当准。
- **侧栏整树重建会把滚动位置压回顶上**（2026-10-31 用户：「agent 更新的时候不要刷新重置侧边栏滚动位置」）：
  `SidebarViewController.reload()` 换新节点时它们先是全收起的，内容变矮、clip view 被压回顶上，展开回来位置已经丢了。
  现在 `reload()` 前后记下 / 放回 `contentView.bounds.origin`（`restoreScroll`）。以后别的整表重建（`reloadData` + 重新展开）照此办。
- **侧栏拖拽排序别用 `.gap` 反馈**（2026-10-31 用户截图：拖「收藏」后那一行成了空白）：`.gap` 拖动时把被拖的行藏起来，
  要数据源在 `acceptDrop` 里用 `moveItem` 动画挪完才放出来；侧栏放下后是整树重建，藏起来的行视图被复用到别的行上 → 空白行。
  现在用 `.sourceList`（插入线）、拖动期间不重建；另外 `canDragRows` 必须拦住不能拖的行，否则按住它往下拉会把**别的选中行**拖走。
  见 `SIDEBAR-DRAG-PLAN.md §6`。
- **浮动标签栏会盖住窗格底部**：两个以上标签时胶囊（或贴底整条）浮在窗格最底下，阅读区 / 画板之外的内容视图要自己让位——
  让多少统一用窗格的 `tabBarInset + scrollerLift`（笔架、习题页都是这个数；常驻滚动条时标签栏还会抬高一条槽）。
  钉在底部的控件（习题的「上一题 / 下一题」）摆在它上面；可滚动的列表照样铺满、用 `contentInsets.bottom` 让最后几行滚得上来。

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

- **Kimi 把 MCP 结果的 `structuredContent` 拼在工具输出文字后面**（2026-11-13 用户截图，`ACP-AGENT-PLAN.md §20`）：
  `<mcp-result-extras>{"structuredContent":…}</mcp-result-extras>`，内容和正文重复（`read_pages` / `read_markdown` 的正文在结构化结果里又有一份）。
  显示前在 `AgentToolText.clean` 去掉；🔴 清理时只去正文**末尾**的空白——`read_markdown` 第一行是 `  36⇥…`，开头空格去了，第一行就和下面的行号对不齐
  （第一版就这么错了，测试的预期值也被同样去了空格，没抓到）。

- **回放时 Agent 发回来的用户消息和我们发出去的不一样**（2026-11-12，`ACP-AGENT-PLAN.md §17`）：`resource_link` 会被 Agent 转成文字
  （Kimi = 本机路径，Claude Code = `[@名字](file://…)`）单独一块发回来；ACP 的 `user_message_chunk` 不带消息 id，几条消息的边界只能靠
  「我们每条只有一块看得见的文字」来分。改发送的块结构（比如再加一块用户看得见的文字）时，回放的拆分规则要跟着改。
  气泡下面那行「上下文」（§18）也是从发出去的原文认的：隐藏说明的开头一律用 `AgentSentContext.Marker` 里的常量，
  **已有的开头别改**（旧对话回放就认不出来了），要新写一种说明就往 `Marker` 里加一个、`parse` 里认一下。

- 增量重排 + 约束激活顺序（2026-09-21 实测）：Agent 面板的对话记录**不能每次刷新都把整排视图拆下来再装
  回去**——`NSStackView` 每增删一个 arranged subview 都要重建一整串间距 / 对齐约束，而流式回复每个碎片都
  来一次，于是「回答长了就卡」。做法是先算出这排视图应该是什么样，再只动第一处不一样的位置往后那一段
  （`AgentChatNSView.applyTranscriptViews`），最常见的情况（最后一条又长了一段、就地换文字）一动不动；
  标题行 / 提示条 / 权限卡片 / 输入区那两个下拉菜单同样「值变了才重建」。🔴 **新建的条目视图必须先进 stack
  再激活宽度约束**：约束两端要有共同祖先，刚建出来的视图还没有父视图，当场激活是 `NSGenericException` +
  「进程 abort」（改对了顺序才不崩；那次一点历史对话就崩）。另外这排视图变了要叫一次滚动条重算（见上一条），
  **面板尺寸变了也要**——正文没重排就没人报高度，滚动条会停在上次的判断上。🔴 **尺寸连着变（拖分隔条 /
  拖窗口）时**：~~整块面板停住不动（2026-09-21 定）~~ → **2026-11-12 用户要「拖的时候也重排」，改成边拖边排**：
  面板照常摆位；正文按段显示（`ACP-AGENT-PLAN.md §19`），**露在视口里的**当场按新宽度重排（文字段只重新折行、表格按新宽度重画，
  离屏实测一条 3000 字带 10 张表的回复 2.3ms），**视口外的**停手再排，停手后 `finishResize` 叫每条 `flushNow()` 补齐、重算滚动条；
  仍要 `clipsToBounds`。（中间试过「引擎编辑器 + 50ms 节拍」，用户嫌有延迟，已被按段显示取代。）排滚动条的问题别再猜，`touch ~/Library/Logs/UniReader-agent-scroll.log`
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
- **流式来的工具输出只换正文文字，别整条重建**（2026-11-10 采样：Kimi 导习题时 UniReader 一直占 80% 以上 CPU）：
  Kimi 生成工具调用的参数（`import_exercises` 一次几十道题）时，每出一段就推一次带全文的 `tool_call_update`；
  原来每推一次就把这条工具调用的视图拆了重建，新建那个最长 4000 字的换行标签要整段量一遍，再加旧视图释放、
  整排重排重画，主线程占满。现在只有输出变了（状态 / 标题没动）时走 `AgentItemViews.update` → `AgentDisclosureView.update(plain:)`
  就地换文字（折着时正文不在视图树里，不排版）；内容没变的更新 `AgentTranscript.apply` 不写回条目。
  同一次采样还查出**侧栏每收一次 `workspace.objectWillChange` 就整棵重载一遍**（一次习题写入连改三个 `@Published` = 三遍），
  已并成一拍一次（`SidebarViewController.queueReload`）。🔴 正式版没有符号，`sample` 只看得到系统帧，
  我按形态猜成 Inspector 猜错了——这类问题直接让用户开 `build/dev` 的 Debug 包再采。
  `spike/agent-flat-row-test.swift` 加了 3b 节，但该脚本头部的编译命令已过期（缺 `GrapherFencedRenderer` / `TableEditMenu`），这一节没跑过。
- **`NSBox` 别写 `box.contentView = stack`**（踩了两次：2026-09-26 权限卡片「元素全挤在一行」、2026-10-27 Kimi 的
  二十来项待办整片叠在上面的条目上）：box 的内容视图走 autoresizing，里面的约束传不到 box 的高度上，`fittingSize`
  只算出一行字高，内容溢出去盖住别的视图。权限卡片改成内容视图用约束钉在 box 四边；对话记录里的计划条目
  （`Window/AI/AgentPlanView`）干脆按 frame 摆、对外只报高度（宽度变了重算、计划更新就地换内容），box 只当底。
  离屏验证 `spike/agent-permission-card-test.swift`、`spike/agent-plan-view-test.swift`（33 项 + 浅 / 深样张）。
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
