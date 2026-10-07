# Agent 面板（ACP）方案

> 2026-09-18 用户拍板并当日落地第一批。一句话：**Agent 不自己做**——用 ACP（Agent Client Protocol）
> 把本机的 Agent（首批只接 Kimi）当子进程拉起来，App 只做 Agent 界面；Agent 读写阅读器的能力
> 全部走已有的 MCP 服务（`MCP-PLAN.md`），不另开接口。

## 0. 与「咨询 AI」的关系

| | 咨询 AI（已有） | Agent（本方案） |
|---|---|---|
| 是什么 | 网页版 AI 问答（`Sources/AI/`，WKWebView） | 本机 Agent（`kimi acp`）的原生对话界面 |
| 代码 | `AIPanelModel` / `AIInlineLayer` / `AIPanelWindowController` | `Sources/Agent/` + `AgentChatView` / `AgentInlineLayer` / `AgentWindowController` |
| 形态 | 内置 / 独立窗口 | 内置 / 独立窗口（**各管各的**，两块可同时开）。🔴 **2026-09-19 起改为只住在 Inspector 的「Agent」页**（内置面板与独立窗口都已删，网页 AI 停用），见 `APPKIT-REWRITE-PLAN.md §9.2`；本文件下面讲形态 / 窗口的段落是历史记录 |
| 快捷键 | ⌘⇧A | ⌘⇧K（「AI」菜单 › Agent 面板，可在设置里改） |
| 存数据 | 会话链接落库（`AIThread`） | **什么都不存**（历史由 Agent 自己保存，见 §3） |

用户原话：「现有 AI 只能使用网页进行问答，这部分保留作为咨询 AI 模块」「我们不自己做，使用 ACP 来实现」。

## 1. 拍板记录（2026-09-18）

| # | 决定 | 理由 / 原话 |
|---|---|---|
| D1 | 客户端 SDK = 自家 fork **`Unireader/swift-acp`**（上游 `wiedymi/swift-acp`，为 macOS 应用 Aizen 而写） | 有真实使用场景；fork 了有问题自己改。Rust 官方 SDK 走 FFI 桥接被否（构建链、回调跨 FFI 都重） |
| D2 | **不引入 Node 进程** | 用户：「我是不太希望加个 nodejs 进程的」。Claude 官方适配器要 Node → **首批只做 Kimi，Claude 先不管** |
| D3 | Agent 工作目录 = **工作区 `.unrd` 包所在的目录**（包的上一级），不是包本身 | 用户定 |
| D4 | 会话**不落库** | 用户：「我们不保存具体数据」。Kimi 支持按工作目录列历史（`session/list`）+ 回放（`session/load`），App 连索引都不用存 |
| D5 | Agent 调 `goto` / `open_document` 时阅读区**默认跟着跳**，面板里有「跟随 Agent」开关 | 用户同意 |
| D6 | 界面 = **独立的 Agent 面板**，同时支持内置与独立窗口两种形态，不并进咨询面板 | 用户选「独立 Agent 窗口」并注明「同时支持内联和独立 Window 两个模式」。咨询面板的工具栏全是网页专用的 |

## 2. fork 维护（`Unireader/swift-acp`）

- 已做：去掉上游的 6 个 reference submodule（SwiftPM 解析依赖时会递归拉下来），改成 `reference/README.md`
  列链接 + 上游当时钉的 commit；tag **`v0.1.0-unireader.1`**（= 上游 `9498537` + 这一处改动）。
- `project.yml` 用 `exactVersion: 0.1.0-unireader.1` 钉死。只取 `ACP` + `ACPModel` 两个产品；
  `ACPRegistry`（带「安装 Agent」功能，违背不代装依赖的规矩）和 `ACPHTTP` 不用。
- 改 fork：在 fork 里改、`swift test` 过、打 `v0.1.0-unireader.N` 新 tag，再改 `project.yml` 的版本号。
  协议以官方 Rust SDK 为准（链接在 fork 的 `reference/README.md`）。
- SDK 已处理好的两件事：GUI App 的 PATH 问题（`ShellEnvironment` 读登录 shell 的环境）、子进程单独成组（`setpgid`）。

## 3. 结构

```
Sources/Agent/
  AgentConfig.swift       启动命令（设置 › Agent：命令 + 参数，默认 kimi / acp）+ 按登录 shell 的 PATH 解析绝对路径
  AgentConnection.swift   一个工作目录一个 Agent 进程；握手、通知按 sessionId 分发、权限请求转给对话、⌘Q 同步杀进程组
  AgentChat.swift         一段对话（宿主 × 工作目录一份）：新建 / 回放 / 发消息 / 取消 / 模式 / 配置 / 权限；上下文块
  AgentTranscript.swift   纯函数：把 session/update 碎片拼成条目（正文 / 思考 / 工具 / 计划）；回放时剔除上下文块
  AgentPanelModel.swift   App 级：形态、各窗口展开状态、进程池、对话表、阅读窗口登记、「跟随 Agent」
Sources/Views/AgentChatView.swift      共用内容：对话记录 + 权限卡片（GroupBox）+ 输入框；内置形态多一条标题行（按钮用 ControlGroup）
Sources/Views/AgentInlineLayer.swift   内置形态：`.panel` 与阅读区并排（ReaderPane.readerColumn 的 HStack），`.bubble` 浮在阅读区右下角
Sources/Window/AgentWindowController.swift  独立窗口（全 App 一扇，跟最近那扇 key 阅读窗口的工作区走）；
                                       操作在 NSToolbar 上：[历史 · 新对话] [选项] [置顶]，标题 = 会话标题，副标题 = 工作区
```

界面规矩（用户 2026-09-18「UI 都要优化符合 macOS 设计」）：独立窗口的操作一律放窗口工具栏（NSToolbar，紧凑样式），
不在内容里另画标题行；内置形态挂不了窗口工具栏，用系统 `ControlGroup`；输入框 / 按钮 / 空状态 / 分组框全用系统控件。

输入区（用户 2026-09-18 参考其他 Agent 客户端定）：一个圆角框，上面多行输入（`TextEditor`，默认约三行、随内容长高、
上限后框内滚动；**回车发送、⇧/⌥回车换行、输入法组字时回车放行给输入法**），下面一行左「模式」（审批方式，Kimi 三档按 id
本地化：每次询问 / 只做计划 / 自动批准）、右「模型」（Agent 给的全部配置项）+ 发送 / 停止。**模式与模型只在这里**，
顶部只留面板本身的设置（跟随 Agent / 吸附 / 形态）。附件按钮（A2）将来放在这一行最左边。

接入点：`ReaderWindowController.windowDidBecomeKey` → `noteKeyReader`；`shutdown()` → `readerClosed`；
`AppDelegate.applicationShouldTerminate` → `teardownAll()`（同步 SIGTERM 进程组，不留孤儿进程）；
「AI」菜单 › Agent 面板（`ShortcutAction.agentPanel`，默认 ⌘⇧K）；设置 › Agent 页加了「Agent 面板」分组。

### 3.1 生命周期

- 进程**懒启动**：面板第一次出现且有工作区时拉起、握手、建会话（建会话才拿得到模式 / 模型列表）。
  **例外：设置 › Agent ›「启动时在后台加载」**（2026-10-07 用户：「启动 app 自动加载 agent（后台），这样不用点开才加载了」，
  默认关）：开着时阅读窗口一有工作区（启动时打开 / 换工作区 / 开关刚打开）就替它建好对话
  （`ReaderWindowController.observeAgentPreload` → `AgentPanelModel.preloadChat`），Inspector 的 Agent 页之后拿到同一份对话，
  视图进窗口时的 `start()` 见已有会话就不再建。关掉开关不收已建好的对话（与打开过 Agent 页一样，关窗 / 退出才结束）。
  启动时 MCP 服务先于第一扇窗口开（`applicationDidFinishLaunching` 里的顺序），所以预加载的会话也带得上 unireader 工具。
- 同一工作目录下的对话（浮窗 + 各窗口内置面板）**共用一个进程**，各自是 Agent 里的一个 session。
- 最后一段对话走了（关窗 / 换会话 / 关浮窗）就关进程（`releaseIdleConnections`）。
- 进程意外退出：SDK 结束通知流 → 对话里显示「Agent 进程已退出」，点「重试 / 新对话」重开一个。
- 启动失败（找不到命令）：这份连接作废、从池子摘掉（`terminate` 后通知流已结束，不能复用）。

### 3.2 发给 Agent 的上下文块（契约）

每次发消息时现取「用户在看什么」，**和上次发过的不一样才带**，用标签对包起来：

```
<unireader-context>
…UniReader 的 Agent 面板；用用户的语言回答
Workspace: 名字. 库在工作目录里的「名字.unrd」包内——不要直接读写包里的文件，库里的东西一律走 unireader MCP 工具
Current document: "标题" (document_id …), page N of M, reader tab session_id …, window_id …
</unireader-context>
```

活动标签是 Markdown 笔记时，Current document 那行改为 Current Markdown note，并带笔记标题、note_ref、
来源、相对路径、标签 session_id、window_id 与 unireader:// 链接。上下文只带身份，不把整篇正文塞进每条消息；
Agent 要读时调用 get_current_view，拿编辑器里的实时正文与 revision（包括还没走完 0.8 秒自动保存的改动）；
修改时调用 update_markdown，把原 revision 与完整新正文一起交回。revision 不一致就拒绝，避免覆盖用户刚输入的内容。
（2026-09-24 起上下文里改为指引 read_markdown 读取、edit_markdown 局部修改，update_markdown 只用于整篇重写，见 `MCP-PLAN.md §19`。）
Agent 仍不得绕过 MCP 直接修改文件。

**两种笔记**（2026-10-05 用户：「需要 Agent 区分文字笔记和 Markdown 笔记，文字笔记是右键添加或者选中文字的那个
Add Note Here」）：上下文块最后多一行（`AgentReaderContext.noteKinds`），说清**文字笔记**（批注 / 文字笔记 =
钉在 PDF 页面某处，右键「在此添加批注」或选中文字后添加；工具 add_note / list_annotations / delete_annotations）
与 **Markdown 笔记**（独立的 .md 文件、在自己的标签页里打开；工具 *_markdown）。用户只说「笔记」没讲哪种时
**按当前标签页猜**（用户定）：PDF 标签 = 这篇文档上的文字笔记，Markdown 笔记标签 = Markdown 笔记（多半就是这篇），
都没开 = 问用户。MCP 的 `instructions` 与 add_note / list_annotations / list_markdown_notes 三个工具说明里
也写了同样的区分（外部 Agent 也受益）；上下文块里再写一遍，是因为不是每个 Agent 都读 `instructions`。

- 🔴 **用户的话放第一块、上下文块放后面**：Kimi 拿第一块文字给会话起标题（spike 实测），反过来历史列表里
  每条都叫「<unireader-context>」。
- 回放历史时 `AgentTranscript.stripHidden` 按标签对把它从「用户说的话」里剔掉（Kimi 自己注入的
  `<system-reminder>` 同样剔）。
- 🔴 `.unrd` 包就在工作目录里，Agent 自带的文件工具理论上够得着库里的 SQLite。两道防线：上下文块里的明文要求 +
  权限请求如实展示给用户批。**不声明** `fs` / `terminal` 客户端能力（我们不是编辑器）。

### 3.3 MCP 交给 Agent

`session/new` / `session/load` 时带上：`{type: http, url: http://127.0.0.1:<端口>/mcp, headers: [x-unireader-agent: 1, Authorization（设了口令才带）]}`。
MCP 服务没开 → 不带，面板顶部提示「开启并重新连接」（**不自动开**：监听方式可能是所有接口，开服务是用户的决定）。

### 3.4 「跟随 Agent」

请求头 `x-unireader-agent` → `MCPCallContext.fromInAppAgent`。开关关着时 `goto` / `open_document` 不动阅读区，
回 Agent 一句「用户关了跟随，没有跳转」（`AgentFollow.declined`）；`open_document` 带 `path` 的导入照做（那是写入不是导航）。
这个头只用来**收紧**，不授予任何权限，伪造了也占不到便宜。外部 Agent（终端里的 Claude Code 等）不带这个头，行为不变。

## 4. Kimi 实测事实（2026-09-18，`kimi` 2.0.0，spike 在会话临时目录，未入库）

- 握手：`loadSession: true`、`mcpCapabilities.http: true`、`promptCapabilities.image: true`、`embeddedContext: true`；
  `sessionCapabilities` 有 list / resume / close / delete / fork。
- 模式三档：Default（每次手动批准）/ Plan（只读，不执行工具）/ Auto（安全操作自动批准）。模型走 `configOptions`（select）。
- 未登录：`authMethods` 给出 `kimi login` 的终端登录方式；App 只提示用户去终端跑，不代跑。
- 空会话（一句没说）也会出现在 `session/list` 里、没有标题 → 历史列表按「有标题」过滤；当前会话一句没说时「新对话」直接复用。
- 每次调工具前后会发内容为空的 `agent_thought_chunk` → 空片段不建条目。
- 调 unireader 的 MCP 工具时没有发权限请求（读类工具）。
- 🔴 **Kimi 的 MCP 客户端严格按 `outputSchema` 校验 `structuredContent`**（我们的 schema 全是 `additionalProperties: false`），
  返回里多一个 schema 没声明的键，整个调用就判失败（`-32602 … must NOT have additional properties`）。Claude Code 不校验，
  所以 MCP 批 2 起漏的两处一直没暴露：`get_current_view.file_missing`、`list_annotations.ai_threads[].created_at`（2026-09-18 已补进 schema）。
  **以后给 MCP 工具加返回字段，schema 必须同步加。** 只读工具对着运行中的 App 自动比对：`python3 spike/mcp-schema-audit.py`
  （`tools/list` 取 schema → 逐个调用只读工具 → 递归检查多余键 / 缺 required / 类型；写入 / 导航类只列出来提醒人工比对）。

## 4.1 踩过的坑

- **「新对话」把马上要用的进程关了**（2026-09-18 用户实测：报「The file couldn't be saved」，接着「Agent 进程已退出」）：
  换会话时先摘下旧会话，那一刻进程上一段对话都没有，若在这里「关空闲进程」，紧接着的新会话就往已关的管道里写。
  现在只在宿主真的消失时（`AgentChat.teardown`）关空闲进程；`AgentConnection.terminate()` 一开头就置 `isDead`，
  手上还攥着旧引用的对话下次会重开一份。

## 5. 分批

| 批 | 内容 | 状态 |
|---|---|---|
| A1 | 进程管理 + ACP 客户端 + 文字对话 + 工具卡片 + 权限卡片 + 自动交 MCP + 两种形态 + 历史列表 / 回放 + 模式 / 配置 + 跟随开关 + 设置页 | ✅ 2026-09-18 |
| A2 | 附带页面截图（复用 `PageSnip`，Kimi 支持图片）、选中文字作为引用发给 Agent | 截图部分 2026-09-19 已写（待编译 + 用户实测）：⌥ 拖松手在指针处弹系统菜单选「Agent / 网页 AI」（本窗口没开工作区时不问，直接给网页 AI）；发给 Agent = 图片挂在输入框上方（可移除），和下一句话一起发，块顺序「用户文字 → 图片 → 隐藏块（图片来源：文档 / 页 / 归一化区域）→ 上下文块」；握手声明不收图时不发并提示；回放时图片挂回用户消息。选中文字待做 |
| A3 | 块级 Markdown（标题 / 列表 / 代码块 / 表格 / 公式）：回复与思考过程都改用笔记那套 Markdown 引擎只读渲染（`AgentMarkdownView`，见 §7） | ✅ 2026-09-20（待用户实测） |
| A4 | 独立窗口吸附到阅读窗口旁、同高、跟着移动：`AIPanelDock` 泛化成两份实例（`shared` 咨询 / `agent`），两扇都吸附时 Agent 排在咨询右边；选项菜单里「吸附到阅读窗口」，默认开 | ✅ 2026-09-18 |
| — | 两块内置面板改为与阅读区**并排**（阅读区 \| Agent \| 咨询），展开时把 PDF 往左推，不再盖在上面；气泡仍浮在阅读区右下角（`InlinePanelPart`）；展开不做动画（逐帧重排阅读区会卡） | ✅ 2026-09-18 |
| — | 其他 Agent（Claude 等）：只要改设置里的命令即可接；Claude 要 Node 适配器，用户暂不考虑 | 暂缓 |

## 6. 刻意没做

- **不做 `ACPRegistry` 的「发现并安装 Agent」**：违背不代装依赖的规矩。
- **不存会话数据**（D4）。
- **不自动开 MCP 服务**（§3.3）。
- **不做 MCP-over-ACP**（SDK 支持的实验性能力：MCP 直接走 ACP 通道、不要 HTTP 端口）：现在的 HTTP 方案够用，Kimi 是否支持也没核实。

## 7. 正文的 Markdown 渲染（2026-09-20，A3）

Agent 的回复从前只解析行内语法（`AttributedString(markdown:)` 的 `inlineOnlyPreservingWhitespace`），
标题 / 列表 / 代码块 / 表格 / 公式全是原样的源码。现在改成与笔记同一个引擎（`swift-markdown-engine`）的
只读渲染：`Sources/Window/AI/AgentMarkdownView.swift`。

- **谁用**：Agent 回复（13pt）与思考过程（折叠块里，12pt）；2026-10-05 起**用户自己发的话**也是（气泡里，
  13pt，见下面「用户消息气泡」）。**工具输出不用**——那是 JSON / diff 这类原样的东西，照旧等宽纯文本。
- **配置**（`AgentMarkdown.configuration`）：`heightBehavior = .fitsContent`（高度由内容定，滚轮交给
  对话记录那个滚动视图）、不要自带滚动条与留白、不做拼写检查；标题 / 列表缩进的尺度与公式渲染器
  跟笔记共用一套（`MarkdownNoteEditor.applyNoteTypography`）。主题用引擎默认的——`bodyText` 就是
  `labelColor`，跟系统外观走；**气泡那套 `readerTheme` 是钉死浅色的（纸白底），不能拿来用**。
- 🔴 **流式必须就地更新，不能重建视图**：回复是一个碎片一个碎片来的，每片都要把整条重新渲染一遍。
  `AgentItemViews.update(_:to:)` 认出是同一条就只换文字（`AgentMarkdownView.update(text:)`），
  重建只发生在真的新增条目时。另外连着来的碎片按 **80ms** 并成一次交给引擎（一条几千字的回复否则要
  整篇重排几百遍）。`AgentDisclosureView` 也因此从构造函数改成了类——顺带治好「展开着的思考过程
  一来新内容就被折回去」。
- 🔴 **宽度变化要防抖，看不见就一次都不排**（用户实测「拖侧边栏很卡，不管在不在 Agent 页」）：
  `InspectorViewController.viewDidLayout` **每次布局都给 Agent 页及其子视图设 frame**，不管这页显不显示——
  拖分隔条时逐帧改宽度，照排就是每帧把每条回复整篇重排一遍。所以宽度变化只在停手 150ms 后排一次；
  不在窗口 / 自己或祖先隐藏（切到别的 Inspector 页、折叠着的思考过程）时文本与宽度都只攒着，
  `viewDidUnhide` / `viewDidMoveToWindow` 时再补排。`AgentChatNSView.layout` 同理，看不见直接返回。
  拖动中正文还按旧宽度画，所以 `AgentMarkdownView` 开了 `clipsToBounds`。
- **贴底与滚动条**：正文高度是引擎排完版**异步**报回来的，那时再按几何判断「刚才在不在底部」已经晚了。
  所以滚动时就把 `stickBottom` 记下来（监听 clip 的 `boundsDidChange`），高度变化时走 `syncScroll()`：
  本来贴底的继续贴底、内容变矮后滚动位置超界的钳回来、最后让滚动条重新判断一次。推到下一拍执行，
  别在排版过程里再 `layoutSubtreeIfNeeded` 一次。
  🔴 让滚动条重新判断只能 `needsLayout = true` + `reflectScrolledClipView`，**不许手动调 `tile()`**——
  那是给 `NSScrollView` 子类重写布局用的，外面调会把系统 overlay 滚动条的布局搅乱：knob 变成一小块方块
  卡在角上，竖的横的都一样（2026-09-20 踩过）。
- **SwiftUI**：引擎只公开了 SwiftUI 包装，这里同样用 `NSHostingView` 托管——与笔记气泡 / 编辑弹窗 /
  整篇编辑区同属「Markdown 引擎」那条例外，界面其余部分仍是 AppKit。
- **没做**：裸 URL 不会自动变成链接（引擎只认 Markdown 语法写的链接）；`~~删除线~~` 引擎也是选配扩展，没开。

### 7.1 用户消息气泡 + 两种高亮（2026-10-05）

用户原话：「用户输入到 agent 的也展示为 markdown」「输出添加高亮支持」（问过：两种高亮都做）。

- **用户消息**（`Window/AI/AgentUserMessageView`）：气泡正文换成 `AgentMarkdownView`（同回复的字号、配置），
  回放时分片推回来的同一句话就地换文字（`AgentItemViews.update` 认 `.user`）。气泡**按内容收窄、靠右**：
  引擎只按给定宽度报高度、不报「最窄要多宽」，所以按原文逐行量宽估（`AgentMarkdown.fittingWidth`）——引擎是
  「原文就地加样式」，换行照原文、标记藏起来，量原文大致就是排出来的宽度；量不准的块级结构（标题 / 列表 /
  引用 / 代码块 / 表格 / 块公式 / 图片）直接撑到上限（条目宽 − 48）；含行内代码 / 公式的行按等宽字体量（宁宽勿窄）。
  🔴 两条「想要多宽」的约束压在优先级 240（低于分栏 250、窗口 500），见 `docs/agents/PITFALLS.md`。
- **`==荧光笔==`**：开引擎自带的 `HighlightExtension`（默认不开），底色是引擎主题的 `highlightColor`。
  只开在 Agent 面板，笔记那边没动。已知：引擎的 `==` 不要求贴着文字，正文里裸写的 `a == b 和 c == d`
  会把中间那段当高亮（反引号里的代码不受影响）。
- **代码块着色**（`AgentCodeHighlighter`）：直接依赖 HighlighterSwift（highlight.js 跑在 JavaScriptCore），
  **不用**引擎的 `MarkdownEngineCodeBlocks` 桥接层——它在没写语言 / 不认识的语言时让 highlight.js 挨个猜，
  实测 60 行 0.35~0.6 秒卡主线程（用户选了「直接链接 HighlighterSwift」）。规矩：只着围栏上写了、且
  highlight.js 认得的语言（别名它自己认），绝不猜；GitHub 浅 / 深两套主题各着一遍合成动态颜色（切外观不重排）；
  代码块底色浅 0.96 / 深 0.08、必须不透明。开销：首次建两份 highlight.js 约 90ms，之后约 0.35ms/行，
  每块只在围栏闭合那一刻着一次（引擎不把没闭合的围栏当代码块），之后走缓存。
- **代码块选中**（同日用户截图：折行的代码行底色盖住选区、围栏 ```fortran 露出来）：是引擎的两处毛病，
  代码块有了不透明底色才暴露。用户选了「保留底色、修引擎 fork」→ `0.13.0-unireader.2`（细节 `docs/agents/PITFALLS.md`）。
- **右键「复制表格 / 复制代码」**（同日用户：「table 表格支持右键复制表格，代码块也是」；另报「直接右键表格会出现
  错误的高亮选中」）：走引擎的 `onBuildContextMenu`，`AgentMarkdownView.contextMenu` 按右键坐标换算出点中的字符、
  `AgentMarkdownBlocks` 认出所在的块，在系统菜单顶上加一项（系统原有的项不动）。复制表格 = 纯文本放 Markdown 原文 +
  HTML 放渲染好的表格（贴进 Numbers / Excel / Pages 是真表格）；复制代码 = 两行围栏之间的代码。右键表格时把落在
  表格里的选区收成插入点（那是右键自动选中的隐藏源码，蓝框错位盖住半张表）。用户消息气泡里的表格 / 代码块同样有。
- 离屏验证：`spike/agent-user-bubble-test.swift`（编真代码，115 项 + 浅 / 深两张样张 + 代码块整块选中样张；跑法在文件头）、
  `spike/agent-markdown-blocks-test.swift`（认块纯逻辑 26 项）。

### 7.2 长对话分段建视图（2026-10-07）

用户原话：「长对话渲染…可以一段一段，向上滚动的时候再加载吗？不然长对话要渲染加载好几秒」。

- 回放期间一条视图都不建（顶上「正在载入对话…」照常显示），回放完只给**最后一段**建视图；往上翻到离顶不足一屏再往前补一段，
  补的那段直接插在这排视图最前面。一段按分量取（`AgentTranscript.windowStart`：正文按字数 + 每条固定开销，先建约 4000、
  每次补约 3000）。
- 没贴底时钉住视口里最上面那条：上面补进条目、或正文排完版变高，都把滚动位置挪回去，眼前内容不跳。高度是排完版异步报回来的，
  所以「要不要再补一段」等高度停止变化一会儿再判断（不然刚建出来每条只有一行高，会一口气全补出来）。
- 离屏验证 `spike/agent-transcript-test.swift` 132 项（视图那边同款算法的第二份实现，改了要同步）。**待用户实测**。

## 8. 输入框 `@` 选文件（2026-09-24）

- **候选** = 这扇窗口工作区书库里的 PDF + 全部笔记源（内建 + 引用）里的 Markdown 笔记，混在一起按
  「上次打开」排（`AgentPanelModel.mentions(in:)`，经 `AgentChat.mentionProvider` 取；PDF 要逐篇查库 + stat，
  所以**一次弹出只取一次**，打字只重新过滤）。用户 2026-09-24 在「只列笔记 / 扫 Agent 工作目录」之间选了这一种。
- 🔴 **只给名字和位置，不给内容**（用户定）：输入框里插 `@文件名 `；发送时对**正文里还留着 `@文件名` 的**
  各附一个 ACP `resource_link`（uri = 本机 file URL，PDF 本机找不到文件时退成 `unireader://` 链接；
  title = 书名 / 所在目录；description 里写 document_id / note_ref，让 Agent 走 MCP 读）。
  `resource_link` 是 ACP 规定所有 Agent 都得收的基本块，不用看握手能力。回放时这种块不拼进用户那句话。
- **匹配**（`AgentMentionMatch`，纯 Foundation，spike `agent-mention-test.swift` 29 项）：`@` 在行首或空白后、
  到光标之间没有空白才算在输入提及（邮箱不算）；分档 名字开头 > 名字含 > 第二行含 > 名字模糊 > 名字 + 第二行模糊，
  不分大小写 / 变音符号，最多 50 条。
- **浮窗**（`Window/AI/AgentMentionPopup`）：不会变成 key 的子窗口，菜单材质 + `.inset` 表格 + 系统文件图标，
  摆在 `@` 上方（放不下才放下方）。焦点始终留在输入框：↑↓ / ⌃P⌃N 选、回车 / Tab 确认、Esc 关（这个 `@`
  不再自己弹出，直到离开它）、鼠标单击也能选；组字中不动它、按键也不截。
