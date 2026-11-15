# 安卓 Agent 方案（模式1）

> 2026-11-15 用户拍板并开工：「开始开发安卓的 agent，支持配置 openai 兼容的地址，建议是走现成的开源框架，如果有合适的，不行再自己开发」。
> 一句话：**平板上直接连 OpenAI 兼容接口**（DeepSeek / 通义 / 本地服务…），Agent 的能力是本机实现的一组工具，
> 名字与参数照 Mac 的 MCP。Mac 那套（ACP 拉起 `kimi acp` 子进程 + MCP）在安卓上做不到，所以两端各走各的路。

## 1. 拍板记录（2026-11-15）

| # | 决定 | 理由 / 原话 |
|---|---|---|
| D1 | 框架 = **JetBrains Koog 1.3.0**（Apache 2.0），先验证编译再往下做 | 用户选「Koog，先验证编译」。纯 Kotlin、1.0 起核心接口稳定、Maven 上有 `*-android` 包；`OpenAIClientSettings` 可改 `baseUrl` / `chatCompletionsPath` |
| D2 | 位置 = **阅读界面右侧一栏**，只在模式1 | 用户选「阅读界面右侧抽屉」；对应 Mac Inspector 的「Agent」页 |
| D3 | 第一批工具 = 只读为主 + 记忆 + 跳页 | 用户选「只读为主 + 记忆」；写笔记（`add_note` / `edit_markdown`）下一批，要接撤销栈 |
| D4 | 接口配置**存本机、Key 加密**，不进工作区、不随同步 | 用户选；Key 用 Android Keystore 的 AES-GCM 密钥加密后存 SharedPreferences |
| D5 | 对话不落库（本轮） | 同 Mac D4 的起点；Mac 的 `agent_turn` 对话记录（§22）安卓下一批再接 |

## 2. Koog 怎么用（只用一半）

- 依赖（`android/app/build.gradle.kts`）：`prompt-executor-openai-client`、`http-client-okhttp`、`agents-tools`（都是 1.3.0）+ `kotlinx-coroutines-android`。
  **不要 `koog-agents` 全家桶**（带进全部厂商客户端）；HTTP 走 Koog 的 OkHttp 适配（与本工程同一个 OkHttp 5.3.2），不引 Ktor 引擎。
  Koog 的 `prompt-executor-clients-android` 在运行时带了 `slf4j-simple`，已在 `configurations` 里排除。
- **工具链**：Koog 1.3.0 是 Kotlin 2.3.10 编的（元数据 2.3），AGP 9.2.0 内置的 Kotlin 2.2.0 读得了（2026-11-15 实测编译通过）。
  它的字节码是 JVM 17，本工程 `jvmTarget` / `compileOptions` 随之由 11 提到 17。**升 Koog 前先查它的 Kotlin 版本**（同 pdfiumandroid 那条）。
- 用了 Koog 的：`OpenAILLMClient`（Chat Completions 流式；分段工具调用拼接；`reasoning_content`）、`Prompt` 当对话历史、`ToolDescriptor` 生成工具的 JSON Schema。
- **没用 Koog 的 `AIAgent`**：它一次 `run` 一个输入就结束，多轮对话要外挂聊天记忆，界面拿流式文字也绕。
  「调工具 → 结果放回历史 → 再请求」的循环在 `AgentEngine.send`，几十行；取消协程 = 停止。
- 第三方模型 Koog 不认识：`LLModel(OpenAILLMProvider, <模型名>, [Completions, Tools, ToolChoice, Temperature])` 自己声明，
  声明了 `Completions` 它就走 Chat Completions（不走 Responses API）。
- 一处绕开：Koog 的 `toMessageResponse` 对空串参数 `Json.parseToJsonElement("")` 会抛异常（有的服务调无参数工具时就给空串），
  `AgentEngine.toAssistant` 自己转、空串按 `{}`。
- 工具参数不用 Koog 的 `@Serializable` 参数类（要 serialization 编译插件，本工程不装）：`AgentTool.run(JSONObject)` 收原始 JSON。

## 3. 配置（`local/agent/AgentConfig.kt`）

服务地址（`https://api.deepseek.com/v1` 这种写法，与 OpenAI 官方 SDK 的 base_url 同）+ API Key + 模型名 + 可选请求路径（默认 `chat/completions`）。
请求地址 = 地址 + `/` + 路径。Key 解不开（换机恢复、密钥被清）当没配过。入口：面板标题行 ⋯。

## 4. 宿主接口（`AgentHost`，`ReaderActivity.agentHost`）

工具只认这个接口（同 Mac 的 `MCPFacade`），全部在主线程调：工作区目录 / 名字 / 库队列、当前标签、已装载的 PDF（Pdfium + 画布上的 OCR 行）、
打开文档、跳页（复用习题「到 PDF 原页」那条：没装载完先记着、几何就绪再跳，记进跳转历史）。页码对内 0 起、对模型 1 起，换算只在 `AgentToolset`。

## 5. 工具（`local/agent/AgentTools.kt`）

### 5.1 第一批：只读 + 记忆

| 工具 | 说明 |
|---|---|
| `get_state` | 工作区 + 当前标签（类型 / id / 标题 / 页） |
| `list_documents` | 书库 |
| `read_pages` | 页面文字：有 OCR 用 OCR，否则 PDF 自带文字层；一次最多 20 页 |
| `search_text` | 一本书里找字（`shared/TextSearch`，同搜索面板），最多 100 处 |
| `goto` / `open_document` | 让用户看到某页 / 某本 |
| `list_annotations` | 批注 / 高亮 / 书签 |
| `list_markdown_notes` / `read_markdown` | 内建 `Notes/` 里的笔记（带行号、按行段读） |
| `list_memories` / `save_memory` | 工作区记忆（`agent_memory`，SQL 照抄 Mac）；删除没做（要先归档进回收站） |

### 5.2 第二批：写入（2026-11-15）

| 工具 | 说明 |
|---|---|
| `add_note` | 批注：给 `quote` 就在那页找原文、钉在它上面（选区批注）；给 `rect` 钉在那块；都没有 = 页左上一条横条（同 Mac）。payload 带 `source: {kind: "agent", provider: "unireader-android"}`（同 Mac 经 MCP 写的）。可选 `type`（已有的笔记类型名）/ `display` |
| `add_highlight` | 高亮：`quote` 必须是那页原文；颜色 Yellow / Green / Blue / Pink（值同 Mac `Highlight.palette`）或 `#RRGGBB`；画法 fill / underline / box / strike；找不到就报错、不猜 |
| `add_bookmark` | 书签：页 + 可选页内位置；写完刷抽屉 |
| `create_markdown` | 在 `Notes/`（可带子目录，没有就建）新建一篇；重名不写、返回已有那篇的 note_ref；写完重扫目录树、服务器工作区马上推 |
| `edit_markdown` | 查找替换 / 按行插入，一条或多条（`edits`），全成或全不成；规则逐条照 Mac `MCPMarkdownText.apply`（`MdEdit`，JVM 单测 `MdEditTest`）。🔴 **开着那篇时改的是编辑器里的字**（用户没存的输入保留）并马上存（`MdNoteController.liveText` / `applyExternalText`）；没开着读写文件。守红线 9：只改模型要改的那几处 |

- 找原文（`AgentToolset.locate`）同 Mac `MCPDocReader.locate`：那页有 OCR 在 OCR 行里找（与手划高亮同一套框），否则 PDF 自带文字层 + `PdfSource.charRects`；忽略大小写、空白与换行。要那本书在标签里装载着（没开就替用户开）。
- 批注 / 高亮写进**开着的**那篇时走画布 `LocalCanvasView.writeNotesExternally`：先 `pushNoteUndo()`（用户能撤销）、写库、回推显示，同界面新建；没开着的直接写库。宿主口 `AgentHost.writeNotes`。
- 没做：`delete_annotations` / `delete_memory`（先归档进回收站，红线 11；本端回收站还不会建这两种条目）、`update_markdown`（整篇覆盖，有 `edit_markdown` 够用）、改名 / 挪目录。

- 读文字要那本书**在标签里装载着**（本机只有标签里的 Pdfium 实例）；没开就替用户开、等它装好（最多 10 秒）。
- 返回给模型的是纯文字（Mac MCP 的 `text` 部分），不带结构化 JSON。

## 6. 界面（`local/agent/AgentPanel.kt`）

- 顶栏「agent」键（`ic_agent`，默认在「页面」组）开关；返回键先关它。贴右边满高，宽 `min(440dp, 屏宽 92%)`，**不盖遮罩**：面板外照常翻书写字。
- 标题行：新对话（＋）/ 设置（⋯）/ 关闭。输入框多行，按钮在「发送 / 停止」之间切。
- 一轮的显示按到达顺序：思考（一行，说完收成「思考过程（点开查看）」）/ 正文（流式只追加文字，一段说完按 Markdown + 公式重画，`MathText.bind`）/
  工具调用（一行 `… name` → `✓ name` / `✗ name`，点开看参数与结果）。
- 每条消息前拼一段用户看不到的上下文块（工作区、当前标签与页）；新对话第一句再带上工作区记忆（最多 50 条，同 Mac §21）。
- 换工作区清空对话；改了设置下一句起用新引擎（对话清空）。

## 7. 没做 / 下一批

- 删除类：`delete_annotations`、`delete_memory`（先归档进回收站，红线 11）。
- 对话记录 `agent_turn`（Mac §22）、Agent 上下文 `agent_context`（Mac §12）。
- `render_page`（多模态看图）：要模型支持图片输入，设置里加开关。
- 模式2（连 Mac）不做：那边直接用 Mac 的 Agent 面板。

## 8. 验证

- `AgentEngineTest`（插桩，`androidTest/…/local/agent/`）：测试进程里起一个 127.0.0.1 的假 OpenAI 兼容 SSE 服务，
  验路径拼接、鉴权头、分段参数拼接、工具结果带 `tool_call_id` 回传、`reasoning_content`、空参数工具调用、多轮历史。不要 API Key、不碰界面。
- `AgentToolsTest`（插桩）：cacheDir 里新建真工作区 + 手写两页 PDF + 不经界面的假宿主，十几个工具逐个跑、回库 / 文件核对
  （高亮的行框位置、批注的锚点与 `source`、书签、Markdown 新建 / 编辑 / 报错、记忆改写）。`MdEditTest`（JVM）6 条。
- **真机冒烟（2026-11-15，用户授权我自己测）**：Mac 上起假的 OpenAI 兼容服务（只读剧本：`get_state` → `read_pages` → 正文），
  `adb reverse` 接到平板，在 408学习区 里经界面配设置、发一句话：三次请求都带鉴权与 16 个工具，工具结果是真实状态，
  界面依次显示思考 / `✓ get_state` / `✓ read_pages` / Markdown 正文，输入框随键盘顶起，无崩溃。测完删了设置、结束了进程。
  写入类在真机上**没走界面**（不往用户的工作区写），只有上面的插桩测试。
- 手感 / 观感（面板宽度、流式滚动）由用户在真机上测，结论记在 §8.1。

### 8.1 真机待测

- [ ] 设置里填 DeepSeek（或别的）地址 / Key / 模型，问「这页讲了什么」→ 先 `get_state` 再 `read_pages`
- [ ] 「跳到第 N 页」→ 阅读区跟着跳，能用后退键退回来
- [ ] 「记住我在复习第 3 章」→ `save_memory`；新对话里它知道
- [ ] 回答中途点「停止」；面板开着时在左边继续写字
- [x] 键盘弹出时输入框不被挡住（冒烟测试里看到输入框随键盘顶起）
- [ ] 「在这段话上加个批注 / 把这句标黄」→ 页面上马上出现，撤销键能撤掉
- [ ] 开着一篇 Markdown 笔记边打字边让 Agent 改它 → 没存的输入还在
