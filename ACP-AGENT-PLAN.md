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
| A3 | 块级 Markdown（标题 / 列表 / 代码块 / 公式）：现在只做行内语法；可评估复用 `MarkdownNoteReader` 的渲染 | 待做 |
| A4 | 独立窗口吸附到阅读窗口旁、同高、跟着移动：`AIPanelDock` 泛化成两份实例（`shared` 咨询 / `agent`），两扇都吸附时 Agent 排在咨询右边；选项菜单里「吸附到阅读窗口」，默认开 | ✅ 2026-09-18 |
| — | 两块内置面板改为与阅读区**并排**（阅读区 \| Agent \| 咨询），展开时把 PDF 往左推，不再盖在上面；气泡仍浮在阅读区右下角（`InlinePanelPart`）；展开不做动画（逐帧重排阅读区会卡） | ✅ 2026-09-18 |
| — | 其他 Agent（Claude 等）：只要改设置里的命令即可接；Claude 要 Node 适配器，用户暂不考虑 | 暂缓 |

## 6. 刻意没做

- **不做 `ACPRegistry` 的「发现并安装 Agent」**：违背不代装依赖的规矩。
- **不存会话数据**（D4）。
- **不自动开 MCP 服务**（§3.3）。
- **不做 MCP-over-ACP**（SDK 支持的实验性能力：MCP 直接走 ACP 通道、不要 HTTP 端口）：现在的 HTTP 方案够用，Kimi 是否支持也没核实。
