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
| 存数据 | 会话链接落库（`AIThread`） | 对话本身不存（历史由 Agent 自己保存，见 §3）；用户点「保存上下文」时 Agent 写的交接摘要存进工作区库（§12） |

用户原话：「现有 AI 只能使用网页进行问答，这部分保留作为咨询 AI 模块」「我们不自己做，使用 ACP 来实现」。

## 1. 拍板记录（2026-09-18）

| # | 决定 | 理由 / 原话 |
|---|---|---|
| D1 | 客户端 SDK = 自家 fork **`Unireader/swift-acp`**（上游 `wiedymi/swift-acp`，为 macOS 应用 Aizen 而写） | 有真实使用场景；fork 了有问题自己改。Rust 官方 SDK 走 FFI 桥接被否（构建链、回调跨 FFI 都重） |
| D2 | **不引入 Node 进程** | 用户：「我是不太希望加个 nodejs 进程的」。Claude 官方适配器要 Node → **首批只做 Kimi，Claude 先不管** |
| D3 | Agent 工作目录 = **工作区 `.unrd` 包所在的目录**（包的上一级），不是包本身 | 用户定 |
| D4 | 会话**不落库** | 用户：「我们不保存具体数据」。Kimi 支持按工作目录列历史（`session/list`）+ 回放（`session/load`），App 连索引都不用存。**2026-11-02 补充**：用户要「换 Agent 接着聊」，对话仍不存，只存用户点「保存上下文」时 Agent 写的那份摘要（§12） |
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

活动标签是习题（练习页）时（2026-11-12，§16），那一行改为 Current tab: Exercises：哪一组、练习还是列表、第几题、`exercise_id`、题型 / 题号 / 页码 / 书名、
答没答（列表里选了几道），并说明「这道题」指它、全文用 `get_current_view`、看原题用 `render_exercise`、带用户去别的题用 `open_exercises`。
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

## 4.0 Qwen Code 支持（2026-10-13，`qwen` 0.25.1，`qwen --acp`）

协议层与 Kimi 一致，客户端没改：握手 `loadSession` / `list` / `resume`、`mcpCapabilities.http`、图片 / 嵌入上下文都支持；
`session/new` 同时给 `modes` 与 `configOptions`（mode + model）；`session/list` 带标题；流式有 `agent_thought_chunk` / `usage_update`。
- 模式五档：`plan` / `default` / `auto-edit` / `auto` / `yolo`（默认进来是 `auto`）。`default`/`plan`/`auto` 复用 Kimi 的本地化文案，
  `auto-edit`、`yolo` 在 `AgentMenus.modeInfo` 里新增。
- 认证：`authMethods` 只给 `openai`（环境变量 `OPENAI_API_KEY`，终端式）；用户先在终端跑一次 `qwen` 配好。
- 设置页 › Agent 加了「Agent」预设选择（Kimi → `kimi acp` / Qwen Code → `qwen --acp` / 自定义），选预设 = 同时写命令与参数。
- 未实测：权限卡片（`default` 模式下的工具批准）、MCP 工具调用、会话回放——待用户实测。

## 4.0.1 Claude Code 支持（2026-10-13，`claude-agent-acp`，npm 包 `@agentclientprotocol/claude-agent-acp`）

用户自己 `npm i -g` 装好（它是 Node 程序，D2 的「不引入 Node」改为：App 不带 Node、用户自装的适配器可选接）。
实测握手：`loadSession` / `list` / `resume` / `fork` / `close` / `delete`，`mcpCapabilities.http`，图片 + 嵌入上下文；`authMethods` 为空（读 Claude Code 自己的登录）。
`session/new` 给 `modes` + `configOptions`；`session/list` 带标题；发话 / 流式 / `usage_update` 都正常。
- 模式六档：`auto`（默认）/ `default` / `acceptEdits` / `plan` / `dontAsk` / `bypassPermissions`；`acceptEdits`、`bypassPermissions` 复用 Qwen 那两条文案，`dontAsk` 新增。
- 设置页预设多一项「Claude Code」= 命令 `claude-agent-acp`、参数留空（按登录 shell 的 PATH 找，nvm 装的也找得到）。
- 未实测：权限卡片、MCP 工具调用、会话回放——待用户实测。

## 4.1 踩过的坑

- **「新对话」把马上要用的进程关了**（2026-09-18 用户实测：报「The file couldn't be saved」，接着「Agent 进程已退出」）：
  换会话时先摘下旧会话，那一刻进程上一段对话都没有，若在这里「关空闲进程」，紧接着的新会话就往已关的管道里写。
  现在只在宿主真的消失时（`AgentChat.teardown`）关空闲进程；`AgentConnection.terminate()` 一开头就置 `isDead`，
  手上还攥着旧引用的对话下次会重开一份。
- **设置里换了 Agent，面板底部的模式 / 模型菜单不变、要重启 App**（2026-10-13 用户报）：进程池按工作目录一个，命令只在
  第一次启动时读；「新对话」照样在旧进程上建会话（设置页写着「修改对新对话生效」，其实没生效）。另外新 Agent 不给模式 / 配置时，
  `applyModes` / `applyConfigs` 遇 nil 直接返回，旧的那套一直挂着。用户定：**点「新对话」才换**，正在聊的不打断。
  现在 `AgentConnection` 建时记下 `AgentConfig.Launch`（命令 + 参数）并按它启动，池子的键 = 工作目录 + 启动配置；
  `newChat` 发现连着的进程和设置对不上 → 清掉模式 / 模型 / 历史、换新进程建会话，建完 `releaseIdleConnections` 关掉没人用的旧进程；
  新会话没报模式 / 配置就清空菜单。面板上的 Agent 名字（标题、空页、占位、「正在启动」、⌥ 拖菜单）一律取这段对话连着的那个（`AgentChat.agentName`）。

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
- **不存会话数据**（D4）：只存用户点「保存上下文」时的那份摘要（§12），不存对话原文、不存历史索引。
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
- ~~**SwiftUI**：引擎只公开了 SwiftUI 包装，这里同样用 `NSHostingView` 托管~~——2026-11-12 起正文**按段显示**、纯 AppKit，
  不再托管引擎编辑器（§19）；本节「宽度防抖」「引擎异步报高度」两条的背景仍有效，做法以 §19 为准。
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
  2026-11-10 起再加**笔记目录**（用户：「支持 @ 引用目录，主要是 markdown 笔记的目录」）：每个笔记源本身 + 各级子目录
  （`AgentMention.noteFolders(in:)`，哪些源、什么顺序同侧栏），排在 PDF / 笔记后面（目录没有「上次打开」），
  给 Agent 的与侧栏「在 Agent 中引用」目录那一份相同（§11 表）；浮窗里用系统文件夹图标。只列笔记目录，不扫任意目录。
- **PDF 的名字 = 书名 + `.pdf`**（`AgentMention.pdfName`，书名自己带 `.pdf` 就不再加；2026-11-10 用户报「显示的是编号」）：
  原先用文件名，而复制进工作区 / 从服务器下来的副本叫 `PDFs/<UUID>.pdf` / `<内容哈希>.pdf`。留 `.pdf` 是为了与同名笔记分开、
  也免得一本的名字是另一本的前缀时发送误附（`stillReferenced` 按正文里有没有 `@名字` 判断）。
  第二行只在用的是工作区外的原文件、且文件名和名字不同时写那个文件名；侧栏「在 Agent 中引用」PDF 走的是同一个构造。
- 🔴 **只给名字和位置，不给内容**（用户定）：输入框里插 `@文件名 `；发送时对**正文里还留着 `@文件名` 的**
  各附一个 ACP `resource_link`（uri = 本机 file URL，PDF 本机找不到文件时退成 `unireader://` 链接；
  title = 书名 / 所在目录；description 里写 document_id / note_ref，让 Agent 走 MCP 读）。
  `resource_link` 是 ACP 规定所有 Agent 都得收的基本块，不用看握手能力。回放时这种块不拼进用户那句话
  （Agent 把它转成文字发回来的也认得、不显示，见 §17）。
- **匹配**（`AgentMentionMatch`，纯 Foundation，spike `agent-mention-test.swift` 29 项）：`@` 在行首或空白后、
  到光标之间没有空白才算在输入提及（邮箱不算）；分档 名字开头 > 名字含 > 第二行含 > 名字模糊 > 名字 + 第二行模糊，
  不分大小写 / 变音符号，最多 50 条。
- **浮窗**（`Window/AI/AgentMentionPopup`）：不会变成 key 的子窗口，菜单材质 + `.inset` 表格 + 系统文件图标，
  摆在 `@` 上方（放不下才放下方）。焦点始终留在输入框：↑↓ / ⌃P⌃N 选、回车 / Tab 确认、Esc 关（这个 `@`
  不再自己弹出，直到离开它）、鼠标单击也能选；组字中不动它、按键也不截。

## 9. 上下文占用 / 压缩上下文 / 粘贴图片（2026-10-26）

用户提的三件：「agent 页面上下文信息显示（token 占比）」「/compact 命令的支持」「agent ⌘V 图片粘贴」。
2026-10-26 读本机三家 Agent 安装包的源码（Kimi 2.3.2 `~/.kimi-code/bin/kimi` 里打包的 JS、Qwen Code
`~/.local/lib/qwen-code`、Claude Code 适配器 `claude-agent-acp`）定的做法。

### 9.1 上下文占用（`Agent/AgentUsage.swift` + `AgentChatNSView.swift` 的 `AgentUsageView`）

- 只用 Agent 推来的 `usage_update`（`used` / `size`）。🔴 **不按字数自己估**（用户定：估出来的和 Agent 真实上下文对不上，
  不可靠的百分比比空着更糟）——没推就整块不显示。
- 谁什么时候推：Kimi **每轮回答结束推一次**（`used` = 当前上下文 token 数，`size` = 模型窗口）；Claude Code 每轮结束推、
  压缩完马上再推一次；Qwen Code 代码里有，但 2026-10-26 探针（`spike/acp-notify-probe.py`）一轮下来一条都没收到。
- 换会话（新建 / 回放）清零等 Agent 重新报——回放的旧会话 Kimi 要说一句之后才有。发出压缩命令也清零（见 9.2）。
- 界面：输入框底行发送钮左边**只有百分比**「7%」（无边框按钮，字号 / 颜色 / 高度同旁边的模型菜单，数字等宽）。
  悬停 = 具体数字；单击弹菜单：具体数字 +「压缩上下文」（Agent 报了压缩命令才有，回答中灰掉）。
  2026-10-27 用户实测嫌丑（截图）：原来左边还有系统圆形进度（`NSProgressIndicator` 确定进度的 spinning 样式），Tahoe 上画成
  细线圆圈里一块扇形、像钟面；且「7%」比模型菜单的字高出一截——量宽度用了 `sizeToFit()`，它连高度一起改小，宽度没变时
  不再重设 frame。用户在「纯百分比 / 容量条 + 百分比 / token 数」三种离屏样张里选了纯百分比；量宽度改用 `intrinsicContentSize`。
  百分比不用下拉按钮：下拉按钮自带箭头与留白，「5%」要占 100pt。

### 9.2 斜杠命令与压缩（`Agent/AgentCommand.swift`）

- 三家都**只看第一块文字**认命令：`/` 开头，`/` 后到第一个空白是命令名，命令名里有 `/` 不算（路径）。
  Kimi 内置 `compact` / `status` / `usage` / `mcp` / `tasks` / `help` + 技能（`skill:名字`），在本地执行、不走模型；
  Claude Code 交给 SDK（`compact` 等）；Qwen Code 压缩叫 **`compress`**（别名 `summarize`）。
- 🔴 **斜杠命令只发那一块文字**（`AgentChat.send`）：原来照常在后面挂上下文块，Kimi 执行内置命令时把其余块全扔了，
  我们却把上下文记成「已发」，下一句话就不再带；Claude Code 则会把上下文块一起交给命令。现在命令不带上下文块 /
  图片 / `@` 文件，图片和待发说明留着跟下一句话走，`lastContextSent` 不动。
- 命令列表来自 `available_commands_update`（`AgentChat.commands`）。Kimi 特意等 `session/new` 的应答发完才推，但我们这边
  应答经 swift-acp 的 actor 再回主线程、通知直接进泵，仍可能先处理通知、那时会话还没登记 → 丢。所以 `AgentConnection`
  对还没登记的会话**只**暂存命令列表与占用两类（各留最后一条），登记时补交；正文碎片不暂存（被取消的旧会话迟到的碎片
  会在下次回放它时混进去）。
- 「压缩上下文」菜单项 = 发 Agent 报的那条命令（`compact` 或 `compress`），和用户自己打一样。
- Kimi 的 `/compact` 在后台跑：先回一句「Context compaction started …」结束这一轮，几秒后**在轮次外**再推一条
  「Compaction completed. Tokens before / after …」。轮次结束超过 0.5 秒还来的回复文字单起一条
  （`AgentChat.apply`），不接在上一条后面；半秒内的仍算这一轮（通知与应答到主线程的先后不定）。
- 没做：输入 `/` 时弹命令候选（像 `@` 那样）。命令列表已经拿到了，要做时复用 `AgentMentionPopup` 的做法。

### 9.3 ⌘V 粘贴图片（`Agent/AgentPaste.swift` + `ComposerTextView.paste`）

- 编辑菜单的「粘贴」先走响应者链（`MenuActions.route`），焦点在输入框时由 `ComposerTextView.paste` 先看剪贴板：
  访达里复制的图片文件 → 按文件附上；只有位图（截图、预览、浏览器「拷贝图像」）→ 附上；其余照常粘文字。
- 🔴 同时有文字和 RTF / HTML 的是**文档里复制的文字**（Pages / Word / Excel 复制文字都会另附一张渲染图）→ 粘文字；
  访达里复制的不是图片的文件（带图标图）→ 粘文件名；剪贴板里的 PDF 不当位图。
- 位图与选文件走同一条 `AgentImageFile`：摆正、长边压到 2000、转 JPEG / PNG（截图原生 TIFF 不压缩，直接 base64 能有几十 MB）。
- 纯文本输入框只认文字类型，剪贴板只有图时右键菜单的「粘贴」原本是灰的，`validateUserInterfaceItem` 放行。
- spike `agent-usage-test.swift` 38 项（占用显示 / 命令认法 / 剪贴板分类，含一块私有命名剪贴板核对 AppKit 类型名）。**待用户实测**。

### 9.4 计划条目叠到别的条目上（2026-10-27 用户截图）

Kimi 导习题时推来二十来项的待办（ACP `plan`），整片清单叠在上面的工具调用 / 思考条目上。原因是计划条目写成了
`NSBox` + `box.contentView = stack`：box 的内容视图走 autoresizing，约束传不到 box 的高度上，box 只有一行字高
（权限卡片 2026-09-26 栽过同一个坑）；另外条目里还套了两层 `NSStackView`，违反「对话记录条目里别套 stack」。
现在是 `Window/AI/AgentPlanView`：分组框只当底，「计划」+ 每项「状态图标 + 会折行的文字」按 frame 摆、对外只报高度；
宽度变了重算高度并让对话记录重新对齐滚动位置；Agent 每次推完整清单时就地换内容，不再整条重建。
离屏验证 `spike/agent-plan-view-test.swift` 33 项 + 浅 / 深样张。**待用户实测**。

## 10. 消息排队（2026-10-27）

用户原话：「agent 要有消息队列过去，不能必需打断才能发消息」。

- 原先回答中输入框的回车和按钮走同一个 `sendTapped`：按钮那时是「停止」，所以**回答中一按回车就把回答停了**。
- 现在回答中：**回车 = 排队**（`AgentChat.queued`，连同此刻挂在输入框上的图片、`@` 的文件；斜杠命令不带图片，同 §9.2），
  输入框空着按回车什么都不做；**按钮仍是「停止」**（⌘. 也是）。占位文字改成「回答完再发：输入后按回车排队…」。
- 这一轮正常答完（含 Agent 因长度上限 / 拒绝而停）→ 发排着的下一条，**一轮一条、按先后**；上下文块、图片说明、
  「让 Agent 批改」的隐藏说明都在真正发出那一刻现取（排队时不取）。
- **不自动发、全部退回输入框**（话接在输入框已有的后面，图片挂回、`@` 文件带回）：用户按了停止、这一轮出错、换会话（新对话 / 回放）、
  Agent 进程退出。理由：停止 = 用户想停下来重新想；出错了接着发多半也是错；排着的话属于眼前这段对话。一句也不丢。
- 界面：输入框上方一块「排队中：回答完后逐条发送」（`Window/AI/AgentQueueView`，分组框当底、按 frame 摆、只报高度），
  每条一行：带了几张图（放前面）+ 话的第一行（长的省略，悬停看全文）+「编辑」（退回输入框）/「移除」。
  离屏验证 `spike/agent-queue-view-test.swift` 15 项 + 浅 / 深样张。**待用户实测**。

## 11. 侧栏「复制名称」「在 Agent 中引用」（2026-10-31）

用户原话：「侧边栏的任何条目，又可以右键复制名称，以及在 agent 中引用」。

- **哪些**：侧栏每一种条目——书库段头（整个书库 / 未分组 / 某个分组）、PDF、笔记源段头、笔记子目录、Markdown 笔记、
  画板段头、画板、习题段头、习题的每一行（全部 / 错题本 / 收藏 / 书 / 章，含错题本、收藏底下那几级）。只有顶上的同步提示条没有。
  右键菜单末尾两项，点在多选里的那一行就对选中的全部。
- **复制名称**：复制侧栏上显示的那个名字（多选时一行一个）。
- **在 Agent 中引用**：这扇窗的 Agent 页亮出来，输入框**在光标处**插 `@名字 `（前面不是空白就补一个空格），发送时照 `@` 选的一样
  附 `resource_link`（`AgentPanelModel.reference` → `AgentChat.requestMentions` → 输入框 `insertMentions`；会话还没建好时输入框不可编辑，
  所以直接改字串、不走 `insertText`）。Agent 没开 / 没工作区时这一项是灰的。
- **给 Agent 的是什么**（`Agent/AgentMention+Workspace.swift`，`@` 候选的 PDF / 笔记也改由它造，两条路给的是同一份）：
  🔴 仍然**只给名字、位置和「用哪个工具读」，不给内容**（§8）。

  | 种类 | 名字 | 位置（uri） | 说明里写什么 |
  |---|---|---|---|
  | PDF / 笔记 | PDF = 书名 + `.pdf`（§8，2026-11-10 前是文件名），笔记 = 文件名 | file URL（PDF 没文件时退成 `unireader://`） | 同 §8 |
  | 笔记目录 / 笔记源 | 目录名 + `/` | 目录的 file URL | 源名 + 相对路径（含子目录），`list_markdown_notes`（source / folder）+ `read_markdown` |
  | 一组 PDF | 段头名 | 工作区链接 | 是哪一组、几本，每本书名 + document_id（最多列 40 本，多了指 `list_documents`） |
  | 画板 / 全部画板 | 画板名 / 「画板笔记」 | 工作区链接 | 名字与 board id；**MCP 还读不了画板上的笔迹**，要内容就问用户 |
  | 习题的一组 | 标签页标题那种全称（「高数 · 第一章」） | 工作区链接 | 是哪一组、几道，`list_exercises` 该带的参数（document_id / all_documents、chapter、filter） |

- `AgentMention` 改动：`Kind` 多了 `folder` / `documents` / `board` / `boards` / `exercises`；新几种的说明构造时写进 `info`；
  `mimeType` 变成可空（目录给 `inode/directory`，其余新种类不给）。仍只依赖 Foundation，`spike/agent-mention-test.swift` 直接编它。
- 验证：`spike/agent-mention-test.swift` 39 项全过（2026-11-10 加 PDF 名字与目录候选后 43 项）（新加 4 项：新几种的说明 / mime / 中文名字 / 发送时照样按正文里还在不在附上）；
  Mac Debug 编译通过。🔴 没在真 App 里跑过。
- 实测清单（用户）：
  63. 侧栏各种条目右键都有「复制名称」「在 Agent 中引用」；复制出来的是侧栏上那个名字；多选几本书复制 = 一行一个。
  64. 「在 Agent 中引用」：Agent 页亮出来，输入框光标处多了 `@名字 `；连着引用几样都插在光标处；发出去后 Agent 知道是什么
      （PDF / 笔记能读；目录能列出里面的笔记；习题组能用 list_exercises 列出那一组；画板它会说读不了内容）。
  65. Agent 关着（设置里关掉）时这一项是灰的。

## 12. Agent 上下文：换 Agent 接着聊（2026-11-02，schema v23）

用户原话：「agent 上下文可以记录下来，在任何 agent 都可以复用」。问过后用户选的三条：
① 是「**换 Agent 接着聊**」（不是每次都自动带上的长期备忘）；② 存的是**当前 Agent 写的摘要**（不是对话原文）；
③ 存在**工作区库里新建的一张表**（随离线副本 / 服务器同步，要升表结构，Mac + 安卓 + 服务器一起改）。

起因：每家 Agent 的历史只存在它自己那里（`session/load` 只能回放同一家的），Kimi 里聊到一半换成 Claude Code 就接不上。

### 12.1 数据（`agent_context`，v23）

```
id TEXT PRIMARY KEY, title, summary（Markdown，不含标题行）, agent（写摘要的 Agent 名）,
session_id（那段对话在原 Agent 里的 id，只对同一家有意义）, created_at, updated_at
```

- 工作区级，不挂文档、没有子表。安卓 `Schema.kt` 逐字相同（安卓没有 Agent 面板，只建表、随同步带着走）。
- 同步：进 `MirrorFp.specs`（`exercise_attempt` 之后、`meta` 之前，7 列全 TEXT，按 `updated_at` 取新）；跨端向量 `spike/mirror-fp-vectors.txt` #34。
  服务器经符号链接编同一份 Store / Sync，不用另改；⚠️ 但**旧版服务器不认这张表**：推上去它答「一致」、客户端照样记下基线，
  之后这几份不会再推（同侧栏顺序键那条，`SIDEBAR-DRAG-PLAN.md §2`）。服务器换新版之后，在那之前存的上下文要改一下（改个字再改回）才会传上去。
- 删除先归档（红线⑪）：回收站新种类 `agentContexts`（manifest 计数键 `agentContext`），快照里只有 `agent_context` 一张表，放回 = OR REPLACE。安卓回收站认这个种类。

### 12.2 界面（Agent 页标题行多一个「上下文」按钮，`tray.full`）

菜单三段：
- **保存这段对话为上下文**：这段对话里说过话、眼下空闲时可点。发一句可见的请求（「请把这段对话写成交接摘要…」）+ 隐藏块里的写法要求
  （`AgentContextText.saveInstruction`：用户的语言、Markdown、**第一行 `# 标题`**、目标 / 做了什么 / 关键事实（书名 + document_id、note_ref、页码、题目 id）/
  现状 / 待办 / 用户的要求；不调工具；只回摘要）。这一轮**正常答完**就把它的回复（思考过程不算）按第一个标题行切成标题与正文存下（`AgentContextText.parse`：
  标题行前面的客套话丢掉；没有标题行 = 第一行当标题、整段当正文；正文空就不存），对话里加一条提示「已保存为上下文「…」」。
  停止 / 出错 / 换会话 = 不存。
- **随下一句话带上**：已存的上下文（最近改过的在前，最多 30 条，副标题 = Agent · 日期）。点一下 = 挂到输入框上方（「随下一句话带上的上下文」那块，
  和排队那块同一个视图，只有「移除」），再点一下取下。随下一句话放进隐藏上下文块（`AgentContextText.handoff`：说明这是之前对话的交接摘要 + 标题 / context_id /
  谁写的 / 日期 + 摘要原文），对话里加一条提示「已带上上下文「…」」；回放时随隐藏块一起剔掉。斜杠命令不带，留着跟下一句话走（同图片说明）。
- **管理上下文…**：一个表单窗（`Window/Sheets/AgentContextsSheet`）：列表（标题 / Agent / 更新时间，可多选）+ 下面编辑选中那份的标题与摘要原文（等宽字体，不渲染）
  +「删除…」（进回收站）/「保存修改」/「带到这段对话」/「完成」（Esc）。换选中、点「完成」、点「带到这段对话」前，改过的先存下（不弹窗问）。

典型用法：Kimi 里聊到一半 → 「保存这段对话为上下文」→ 设置里换成 Claude Code → 「新对话」→ 「上下文」菜单点那一份 → 说一句「接着做」。

### 12.3 MCP（批 5，任何 Agent 都能用，包括终端里的外部 Agent）

| 工具 | 级别 | 作用 |
|---|---|---|
| `list_agent_contexts` | read | 列出工作区里存的上下文（id / 标题 / Agent / 时间 / 摘要字数） |
| `read_agent_context` | read | 读一份的全文（id 可给前 8 位） |
| `save_agent_context` | write | 存一份（`agent` = 调用方 `clientInfo` 的名字）；给 `id` = 改已有那份。说明里写明**只在用户要求时存** |

`MCPServer.instructions` 与面板上下文块（`AgentReaderContext.contexts`）各加一句：用户说「接着上次的」就用前两个找、读。

### 12.4 代码落点

| 层 | 文件 |
|---|---|
| 存储 | `Store/LibraryStore.swift`（v23 DDL、DAO）、`Store/LibraryModels.swift`（`LibAgentContext`）、`Store/MirrorFingerprint.swift`、`Store/TrashStore.swift` |
| 执行层 | `App/WorkspaceManager+AgentContext.swift`（存 / 改 / 删先归档、`.agentContextsDidChange`）、`App/WorkspaceManager+Trash.swift`、`App/TrashModel.swift` |
| Agent | `Agent/AgentContextText.swift`（纯 Foundation：写法要求 / 切标题 / 带过去的那一块）、`Agent/AgentChat.swift`（`saveContext` / `handoffs`）、`Agent/AgentPanelModel.swift` |
| 界面 | `Window/AI/AgentChatNSView.swift`（标题行按钮 + `AgentMenus.contexts` + 输入框上方那块）、`Window/AI/AgentQueueView.swift`（可换标题、可不要「编辑」）、`Window/Sheets/AgentContextsSheet.swift`、`Window/Sheets/TrashSheet.swift` |
| MCP | `MCP/MCPTools+AgentContext.swift`（工具 + 执行）、`MCP/MCPTools.swift`、`MCP/MCPServer.swift` |
| 安卓 | `local/store/Schema.kt`（v23）、`MirrorFp.kt`（含 `needsMigrate`）、`MirrorReport.kt`、`TrashStore.kt` / `Trash.kt` / `TrashSheet.kt`、`MirrorFpTest` |

### 12.5 验证（2026-11-02）

- `spike/agent-context-test.swift`（新）49 项全过：切标题与正文（标题行 / 客套话 / 二级标题 / 没有标题行 / `#标签` / 空）、标题规整、带过去的那一块、
  库的读写（排序、覆盖写不动 created_at）、指纹规格与列序、回收站归档 → 删 → 放回（逐字段相同、重复放回幂等）、manifest 键名与老条目、v22 库升级补表。
- `spike/agent-queue-view-test.swift` 19 项（新加 4 项：只有「移除」的那一种）；`trash-test` 71、`store-test` 54、`mirror-fp-test` 66 全过；
  `mirror-apply-test` 55 过 1 不过（TODO 里那条老的）。
- 服务器 `swift test` 全过、Linux 交叉编译通过、`spike/server-client-test.sh` 47 项全过。安卓 `assembleDebug` + JVM 单测 181 项全过。
- Mac Debug 编译通过、改动的文件没有新警告。
- 🔴 没在真 App 里跑过：保存（Agent 真写出来的摘要能不能切对）、带上、管理窗口、MCP 三个工具（`python3 spike/mcp-schema-audit.py` 要对着运行中的 App 跑）都由用户实测。

### 12.6 实测清单（用户）

  78. Agent 页标题行多了「上下文」按钮；一句没说时「保存这段对话为上下文」是灰的。
  79. 和 Kimi 聊几句 → 「保存这段对话为上下文」：对话里多一句请求、Kimi 写出带 `# 标题` 的摘要，答完出现「已保存为上下文「…」」。
  80. 设置里换成 Claude Code（或 Qwen）→「新对话」→「上下文」菜单里看到刚才那份（副标题 Kimi · 日期）→ 点它：输入框上方出现「随下一句话带上的上下文」；
      说「接着做」→ 对话里出现「已带上上下文「…」」，Claude Code 知道之前做到哪了。再点一次菜单里那份（打勾的）= 取下。
  81. 「管理上下文…」：列表、改标题 / 摘要后点「保存修改」或直接换选中 / 点「完成」都存下；「带到这段对话」= 挂到输入框；「删除…」后在回收站里能放回。
  82. 存的时候按停止：不存，提示「上下文没有保存」。
  83. 终端里的外部 Agent（经 MCP）：「列出 UniReader 里存的上下文」「读第一份」能做到；「把我们这次的对话存成上下文」→ 管理窗口里出现，Agent 列是它的名字。
  84. 连服务器的工作区：NAS 上的服务器换成新版之后，另一台设备同步后能看到这些上下文（旧版服务器不传，见 §12.1）。

## 13. 多 Agent 并行（2026-11-02）

用户要求：「多 Agent 并行」。做法：**一扇阅读窗口里同时开几段对话**，每段各连一个 Agent（可以不是同一个），后台的照常收回复、等批准。

- 模型（`AgentPanelModel`）：`chats[窗口] = [AgentChat]`，`activeChatID[窗口]` 是眼前这段；最多 `maxParallel = 6` 段。
  `chat(for:cwd:)` 仍返回**眼前这段**（框选截图 / `@` 引用 / 习题批改的投递都落在它上），`chats(for:cwd:)` 给全部，
  `addChat(in:cwd:launch:)` / `selectChat` / `closeChat`（最后一段不关）。换工作目录 = 整批结束重建。`chatListRevision` 通知界面。
- 进程：不变——一个「工作目录 + 启动配置」一个进程，同进程里每段对话是一个 ACP session（`AgentConnection.chats` 本来就按 sessionId 分发）。
  所以两段都用 Kimi 只有一个 `kimi acp` 进程；选 Qwen / Claude 就多一个进程。
- `AgentChat.pinnedLaunch`：并行对话新建时选的 Agent，钉死；点它的「新对话」不会被设置里的新选择换走。第一段（`nil`）保持原来的「跟设置、点新对话才换」。
- 界面：Inspector「Agent」页外壳换成 `AgentChatsView`——顶上一条 `NSSegmentedControl`（一段一格，格上小图标：回答中 / 等你批准 / 出错）+「＋」（弹 Agent 列表：Kimi / Qwen / Claude + 设置里自填的）+「✕」（关眼前这段）；
  下面是眼前这段的 `AgentChatNSView`。后台的对话**没有视图**，切回来才重建（长对话分段建视图的老办法照旧）。
- 没做：不同段之间互相传话；每段单独的 MCP 口令；窗口之间共享并行对话（每扇窗口各管各的）。
- 同日顺手：工具调用的标题只留第一行 160 字、工具输出入库前截到 8000 字（`AgentTranscript.clampTitle`）——
  怀疑有的 Agent 把调用参数拼进标题，`import_exercises` 一次几十道题时单行标签每次量宽都排整段文字，拖动 Inspector 时主线程被占满。**这是推测，未经采样证实**，见 TODO。

## 14. 输入 `/` 弹命令候选 + 选中文字作为引用（2026-11-10）

- **`/` 候选**：整段话以 `/` 开头、光标还在命令名里（没有空白、没有第二个 `/`）→ 弹出 Agent 报上来的斜杠命令
  （`available_commands_update`，`AgentChat.commands`；Agent 没报过就不弹，照样能手打）。排序：名字开头 > 名字里含 > 说明里含。
  ↑↓ / 回车 / Tab / Esc 同 `@` 候选（同一块 `AgentMentionPopup`，候选项 `AgentMention.Kind.command`）；选中 = 换成 `/命令名 ` 接着写参数。
  已经把唯一那条完整打出来时列表自己收起——这时回车是发送，不是再选一遍。纯逻辑 `AgentSlash.activeQuery` / `rank`。
- **选中文字 → 引用**：阅读区选中文字右键「在 <Agent 名> 中引用这段文字」（这扇窗能发给 Agent 时才有）：输入框里放一段 Markdown 引用块
  （`AgentQuote.markdown`，每行 `> `，下面空一行接着写问题），「出自哪本书（document_id）第几页」进随下一次发送带走的隐藏上下文
  （`AgentPanelModel.prepare`，同习题「让 Agent 批改」那条路），Agent 页亮出来等用户发。
- 验证：`spike/agent-usage-test.swift` 51 项全过（新加 13 项）；Mac Debug 编译通过。🔴 界面由用户实测：① 输入框打 `/` 出命令列表、打 `/com` 只剩相关的、
  回车补全成 `/compact `；② 完整打 `/compact` 回车直接发送；③ 选中一段文字右键 →「在 … 中引用这段文字」→ Agent 页输入框里是引用块。

## 15. 引用某一道题（2026-11-12）

用户原话：「支持引用某一题到 agent」。侧栏只能引用习题的**一组**（§11），这一轮补上单题。

- **入口**：练习页顶行「在 Agent 中引用」（`at` 图标；这扇窗能发给 Agent 时才显示；顶行挤不下时只留图标）；
  列表右键「在 Agent 中引用」（可多选，一道一个 `@`；Agent 不可用时灰掉）。两处都走 `ExercisePracticeView.reference` → `AgentPanelModel.reference`，
  与侧栏同一条路：输入框光标处插 `@名字 `，发送时附 `resource_link`。
- **名字**：练习页顶行那几样——`书名 · 第 12 页 · 题号 3`（没题号写题型）。带页码是因为不少书每章题号从 1 重来。
- **给 Agent 的说明**（`AgentMention.exercise`，`Kind.exercise`）：🔴 仍然只给位置不给内容——题型、题号、页码、书名 + document_id、章节、`exercise_id`，
  指它用 `list_exercises (exercise_ids [...])` 读题干 / 选项 / 参考答案 / 解析 / 笔记 / 练习统计，`list_exercise_attempts (exercise_ids [...])` 读作答，
  带图的题用 `render_page` 看页面。uri = 那一页的 `unireader://` 链接。
- **MCP 配套**：`list_exercises` 加了 `exercise_ids`（完整 id 或前 8 位，按给的顺序返回；给了它就不看 document_id / all_documents / pages / filter / chapter / tag）。
  原先没有按 id 读单题的办法——`list_exercise_attempts` 只在做过的题上有结果。
- 验证：`spike/agent-mention-test.swift` 47 项全过（新加 4 项：单题的说明 / mime、名字带空格和 · 照样按正文认出、去重、与习题组不互相去重）；
  Mac Debug 编译通过。🔴 没在真 App 里跑过。
- 实测清单（用户）：
  103. 练习页顶行有「在 Agent 中引用」，点了 Agent 页亮出来、输入框里是 `@书名 · 第 N 页 · 题号 X `；问一句「这题怎么做」，Agent 能读出这道题。
  104. 列表里多选几道右键「在 Agent 中引用」：一道一个 `@`；删掉其中一个再发，Agent 只收到剩下的。
  105. 设置里关掉 Agent：练习页那个按钮不见、列表右键那一项灰掉。

## 16. Agent 看得到、打得开练习页上的题（2026-11-12）

用户原话：「看下现在 Agent 可以直接打开某一题吗」「拓展下 Agent 能够查看题目，打开题目，处理题目的能力」。此前习题标签上 Agent 什么都看不到
（上下文块写「没有打开文档」，`get_current_view` 回 `empty`），也没有带用户去某一道题的办法（`link` 只到 PDF 出处页）。

- **上下文块**（`AgentReaderContext.ExerciseTab`，`AgentPanelModel.exerciseTab`）：见 §3.2。只带身份；翻题 / 交卷 / 换视图后和上次不一样，下一条消息重新带。
- **工具**（`MCP-PLAN.md §29`、`EXERCISE-PLAN.md §27`）：`get_current_view` 认习题标签（当前题全文 + 屏幕上的作答 + `attempt_id`）、
  `open_exercises`（导航级，「跟随 Agent」关着时同 `goto` 不动界面）、`render_exercise`（原题图）。
- **引用某一道题**（§15）的 uri 改成 `unireader://open?ex=<id>`（在练习页打开它），说明里多指一句 `render_exercise` / `open_exercises`。
- 验证：Mac Debug 编译通过；`spike/deep-link-test.swift` 47 项。🔴 上下文块与三个工具都没在真 App 里跑过。
- 实测清单（用户）：
  115. 练习页停在某题，在 Agent 面板问「这道题怎么做」→ Agent 不用问就知道是哪道（不再说「没打开文档」）。
  116. 交了卷再问「我这题错在哪」→ Agent 读到你的作答和对错；填空 / 主观题说「帮我批改这题」→ 直接批改，练习页上出现评语。
  117. 说「打开第二章的错题」「带我去第 5 页那道题」「把上次做错的重做一遍」→ 练习页跟着换；关掉「跟随 Agent」再说一次 → 界面不动，Agent 说明没跳。
  118. 说「看看这道题的图」→ Agent 调 `render_exercise` 看原题图（跨页的是拼好的那张）。

## 17. 回放旧对话：用户消息后面拼着一串路径（2026-11-12）

用户截图：打开以前的会话，自己那条消息后面跟着 `/Users/…/PDFs/<哈希>.pdf/Users/…/06. 法律建设.md继续`。

- **原因**：Agent 存历史时把我们附的 `@` 附件（`resource_link`）**转成了文字**，回放时作为一块单独的文字发回来——
  Kimi 是本机路径（`file://` 的）或 `<resource_link uri="…" name="…" />` 标签（`unireader://` 的，比如引用某一道题；同日第二张截图），
  Claude Code 适配器是 `[@名字](file:///…)`。`AgentTranscript.apply` 只跳过原样的 `resource_link` 块，
  转成文字的照样拼进了那句话；而且同一个气泡里来的文字一律往后接，所以那句话之后 Agent 没回、又发的「继续」也接了上去。
- **改法**（`AgentTranscript.apply` 的 `userMessageChunk`）：
  - 跟在用户那句话后面、**整块只是路径 / 链接**的（`AgentMention.isLinkEcho`：三级以上的绝对路径、`@/路径`、`~/路径`、
    `file://` / `unireader://` 链接、目标是这两种的 Markdown 链接、一个或几个 `<resource_link …/>` 标签）→ 不显示。一句话里提到路径、多行、网页链接、`/compact` 这类都不算。
  - 我们每条消息只有**一块**看得见的文字（其余是附件 / 图片 / 上下文块），所以眼前这条已经有字时再来的字 = 下一句，另起一个气泡。
- 历史里已经写进去的老名字（2026-11-10 之前 `@` 插的是 `<哈希>.pdf` 这种文件名）是当时真发出去的话，回放照原样显示，没法改。
- 验证：`spike/agent-mention-test.swift` 62 项（新加 15 项）；Mac Debug 编译通过。`apply` 本身连着 ACP 库，spike 编不进来，靠用户实测。
- 实测清单（用户）：
  120. 打开截图里那两段旧会话：消息后面不再有路径；「继续」单独一个气泡；引用某一道题的那条后面不再多一个 `<resource_link …/>` 气泡。
  121. 新发一条带 `@` 的消息，切到别的对话再切回来（回放）：同样干净。用 Claude Code 当 Agent 时再看一次（它存的是 `[@名字](file://…)`）。

## 18. 气泡下面一行「上下文」：这条消息带了什么（2026-11-12）

用户原话：「就是加一个显示，这样知道这个会话加载了什么上下文」（起因：引用某一道题时，附带给 Agent 的说明在气泡里看不见）。

- **显示**（`AgentUserMessageView`）：用户气泡下面一行小字，`上下文：` + 每样一个图标 + 名字，靠右；一行放不下就折行（只在两项之间折），
  悬停看发给 Agent 的原话（引用的说明 / 链接、摘要正文……，每项最多 400 字）。没有就不占地方。
  字号 11、`labelColor`（红线 4）；🔴 横向抗压缩 200 + 显式宽度（优先级 999，`layout` 里按「一行的宽」与上限取小）——折行标签没有确定的
  自然宽度，不明说就含糊、还可能把面板撑宽（离屏验证里先撞上了）。
- **显示哪些**（`AgentSentContext`，纯 Foundation）：`@` 引用（PDF / 笔记 / 目录 / 一组 PDF / 画板 / 一组题 / 一道题）、
  「正在看」（PDF 第几页 / Markdown 笔记 / 练哪一组第几题——那块「用户在看什么」只在变了时才随消息发，所以只有那几条消息上有）、
  引用文字的出处、批改请求、带进来的交接摘要、写交接摘要的说明。图片的说明不列（图片本身已显示在气泡上方）。
  带进来的交接摘要以前另起一行「已带上上下文「…」」，现在归到这一行里，那行提示去掉了。
- **从哪认**：发送时（`AgentChat.dispatch`）与回放时（`AgentTranscript.apply`）都从**发出去的原文**认、走同一个 `AgentSentContext.parse`：
  隐藏上下文块里按几个固定开头认（`AgentSentContext.Marker`：`Current document: ` / `Current Markdown note: ` / `Current tab: Exercises` /
  引用出处 / 批改 / 交接摘要 / 写摘要，写说明的地方都改用这些常量）；`@` 引用发送时直接取，回放时取原样的 `resource_link` 块，
  或 Agent 转成的那几种文字（§17：路径 / `<resource_link …/>` / `[@名字](file://…)`，按 mime / `ex=` / 扩展名猜是什么）。
  回放时 Kimi 转成路径的 PDF 只剩文件名（`<哈希>.pdf`），认不回书名——气泡正文里的 `@书名` 还在。
- 条目：`AgentItem.Kind.user` 多一个 `context`；上下文变了整条重建（回放期间不建视图，代价小）。
- 验证：`spike/agent-sent-context-test.swift` 19 项（认法）；`spike/agent-user-bubble-test.swift` 144 项（编真代码，新加「上下文」一段：
  靠右、一行收窄 / 两行 / 多行、不撑宽窗口、不压气泡、有悬停说明；出了浅 / 深样张自查过。顺手把它过时的编译命令补全了）；
  Mac Debug 编译通过。🔴 真 App 里没跑过。
- 实测清单（用户）：
  122. `@` 一本书和一道题再发：气泡下面一行「上下文：📄 书名.pdf  ❓ 书名 · 第 22 页 · 题号 11  👁 正在看《…》第 N 页」，悬停看得到说明。
  123. 阅读区选中文字「在 Agent 中引用」后发：多一项「引用出处：《…》第 N 页」；练习页「让 Agent 批改」：多一项「批改请求」；挂上一份上下文发：「交接摘要「…」」。
  124. 切到别的对话再切回来（回放）：同样那一行还在（Kimi 回放时 PDF 那项显示的是文件名）。

## 19. 正文按段显示（2026-11-12）

用户原话：「拖拽的时候不 relayout」→「好一些了，但是开会有点延迟」→「我看 xcode 里面支持的很好的 ai 输出的显示，你可以分析下吗？」
→ 选「引擎收尾 + 改按块渲染」；表格「复用引擎的新样式表格」（表格样式见 `docs/agents/BUILD-DETAILS.md` 引擎那条与 `PITFALLS.md`）。

- **Xcode 的做法**（Xcode 27.2 `IDEIntelligenceChat.framework` 静态分析：类型名、链接库）：一条回复拆成段落 / 列表 / 表格 / 代码卡片等小块，
  各自一个视图；文字是 SwiftUI `Text`（底下是 CoreText），表格是 `Grid`；自己写的懒排布 `AssistantLazyStackLayout` 只排看得见的、记住尺寸；
  流式按段累积（`StreamedParagraphAccumulator`）。没有公式支持。
- **原来为什么慢**：整条回复是一个引擎编辑器（TextKit 2，源码就地隐藏、表格整张画成图），改一次宽度就整篇重排、重上样式。
  同一篇（3600 字、10 张表）按段用 CoreText 量高度 0.87ms，引擎 8–19ms（Debug 引擎）。
- **现在**：`AgentMarkdownView`（`Sources/Window/AI/AgentMarkdownView.swift`）+ 各段视图（`AgentMarkdownBlocksView.swift`），纯 AppKit、按 frame 竖着摆。
  解析用引擎 fork 新加的只读接口 `MarkdownDisplayRenderer.segments`——与笔记**同一套解析**（`$` 的规则、转义、`==高亮==`、列表层级）：
  - 连着的段落 / 标题 / 列表合成**一段文字**（`AgentTextBlockView`：TextKit 1 的 `NSTextView`，只读、可选中、链接可点），这一段里能跨段选中；
    段内换行是 U+2028（不吃段距）；标题的段前距 TextKit 1 在文本开头不给，由外层加进块间距；
  - 引用：左边竖条 + 文字；代码块：着色（`AgentCodeHighlighter`）、不折行、横向滚动、圆角底；```grapher 画成图；
  - 块公式：`NoteLatexRenderer` 出图、居中，比版面宽就等比缩小；行内公式是文字里的图片附件（🔴 基线见 `PITFALLS.md`）；
  - 表格：`MarkdownDisplayRenderer.tableImage`（与笔记同一画法、圆角样式），比版面宽就在圆角里横向滚动；分隔线：系统分隔线；
  - 图片 `![](…)`：仍不显示图本身（原来的配置也不给图），显示成链接。
- **流式**：照旧 80ms 并流；源码没变的段原样留着，变了的（通常是最后一段文字）换内容不换视图。
- **宽度**：视口里的当场重排（文字段只重新折行，表格按新宽度重画），视口外的停手再排，看不见的不排（同 §7）。
- 🔴 **横向滚动的块（代码 / 宽表格）**：竖向滚动一律交给外面的对话记录——一次触控板手势按第一下有位移的方向定给谁、从头到尾不换，
  鼠标滚轮每一格单独判断（同引擎 `0.15.0-xvan.2` 宽表格）。
- **代价（用户接受）**：选中文字只能在一段文字里，跨不过代码块 / 表格 / 公式；每段右键都有「复制全文（Markdown）」拿整条原文。
  复制选中的文字时公式换回 `$…$`。`[[…]]` 点了不跳（没有工作区上下文可解析，原来也不跳）。
- **用在哪**：Agent 回复 / 思考过程 / 用户消息气泡；习题的题干 / 选项 / 解析 / 笔记 / 作答（都是 `AgentMarkdownView`）。
  笔记编辑区、批注气泡仍是引擎编辑器。
- **右键**：表格「复制表格」、代码块「复制代码」（剪贴板内容同 §7.1）。原来按点击位置认块的 `Sources/Agent/AgentMarkdownBlocks.swift`
  与它的 spike 已删（每段自己就是一个视图，不用认了；右键表格选中半张表的老毛病也随之没了）。
- **实测**（离屏，Debug 引擎，3000 字回复带 10 张表 + 代码 + 列表 + 引用）：改宽度重排中位 2.3ms（原来同类 18–20ms）；
  流式每 40 字更新一次中位 2ms；第一次建 48ms（10 张表出图）。
- 验证：`spike/agent-user-bubble-test.swift` 147 项（右键一节按段重写，加「复制时公式还原」；补了 `NoteLinkCompleter` 桩——
  `[[` 选择框加进来后它编不过）；离屏样张（浅 / 深、行内与块公式、超宽公式、grapher、表格、代码、列表）看过；Mac Debug 编译通过。2026-11-13 用户实测 152 通过，153–156 待测。
- 实测清单（用户）：
  152. 拖 Inspector 分隔条 / 窗口：Agent 回复（含表格、代码、公式）跟着重排、不卡、不延迟。 ✅ 2026-11-13 用户在 MBP 上实测「很流畅很舒服」。
  153. 流式回复：边出字边显示、不闪；表格、代码块出完整后正常显示。
  154. 选中文字复制（含公式）→ 公式是 `$…$`；右键表格 / 代码块 / 文字各自的菜单项。
  155. 宽表格、长代码行：触控板横划只滚这一块，竖划滚整个对话。
  156. 习题：题干、选项、解析里的公式（行内与文字对齐、块公式居中）。

## 20. 工具调用展开后的显示（2026-11-13）

用户：「优化下 tool 调用展开的显示」（两张截图：`read_pages` / `read_markdown` 展开后整屏等宽字、和回复连成一片，行号贴着正文，
末尾又是一大段 `<mcp-result-extras>{"structuredContent":…}` JSON）。

- **重复的 JSON**：Kimi 把 MCP 结果的 `structuredContent` 原样拼在文字后面（`<mcp-result-extras>…</mcp-result-extras>`）。
  `Agent/AgentToolText.clean` 在存进条目前去掉它（没收尾的去到末尾）；只有这一段时把里面的 JSON 排成多行；整段是 JSON 的也排成多行（键按字母序）。
  🔴 只去正文**末尾**的空白：开头的空格是第一行行号的对齐。
- **显示**（`Window/AI/AgentToolOutputView`，按 frame 摆、不进约束引擎）：浅底圆角块（同代码块底色）；
  `cat -n` 式行号（`  36⇥正文`）单独一栏、正文对齐，折行的接续行也对齐正文（原来默认制表位 28pt，四位行号正好占满）；
  长输出先显示前 12 行 / 1500 字，底下「显示全部 N 行」，展开后「收起」；右键多一项「复制输出」（整段）。
  折叠块就地换文字走 `AgentPlainTextBody` 协议（`AgentDisclosureView` 不直接认这个类，别的 spike 的编译命令不用改）。
- 没改：表头还是工具名；Kimi 给模型的内容里是不是也带着这段 JSON（等于读一遍结果花两份 token）要看 Kimi 那边，App 这里只管显示。
- 验证：`spike/agent-tool-output-test.swift` 35 项 + 浅 / 深样张；`agent-flat-row-test` 73、`agent-user-bubble-test` 147、
  `exercise-note-test` 26、`exercise-free-answer-test` 59 照旧全过；Mac Debug 编译通过。
- 实测清单（用户）：
  162. 让 Agent 读一页 PDF、读一篇笔记：展开工具调用，没有末尾那段 JSON；行号一栏对齐；长的只显示开头，「显示全部」/「收起」可用。
  163. 工具还在跑时展开（如 `import_exercises`）：内容跟着更新、不闪、不折回去。
