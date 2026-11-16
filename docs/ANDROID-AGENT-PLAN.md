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
| D5 | 对话不落库（本轮） | 同 Mac D4 的起点；2026-11-16 接上 Mac 的 `agent_turn` 对话记录（§5.4） |

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
- 正文并成一段（`toAssistant`）：Kimi 在思考那几块里带着 `"content": ""`，Koog 每切换一次就收尾一段文字，
  一条回复切成几段、其中有空串，回传历史时发成 content 数组 → Kimi 回 400「text content is empty」（2026-11-16 真机第二轮踩到；
  `AgentEngineTest` 的假服务照 Kimi 发、对空文字回 400）。
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
| `list_annotations` | 批注 / 高亮 / 书签 / 图片笔记（带 id，删除用） |
| `list_markdown_notes` / `read_markdown` | 内建 `Notes/` 里的笔记（带行号、按行段读） |
| `list_memories` / `save_memory` | 工作区记忆（`agent_memory`，SQL 照抄 Mac）；删除见 §5.3 |

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
- 没做：`update_markdown`（整篇覆盖，有 `edit_markdown` 够用）、改名 / 挪目录。

### 5.3 第三批：删除（2026-11-16）

| 工具 | 说明 |
|---|---|
| `delete_annotations` | 按 id（完整或前 8 位）删一篇里的高亮 / 批注 / 书签 / 图片笔记；有一个对不上就一条都不删。一次调用 = 回收站里一条「批注」条目（名字「“引文前 24 字”及另外 N 条」，同 Mac） |
| `delete_memory` | 按 id 删记忆，进回收站「Agent 记忆」条目（一条时名字 = 第一行前 40 字） |

- 🔴 红线 11：`Trash.deleteAnnotations` / `deleteAgentMemories` 先归档（`TrashStore.archiveNotes` / `archiveAgentMemories`，同 Mac 只搬 `note` / `agent_memory` 一张表），
  归档到的条数对得上才删行。manifest 与 Mac 同格式，两端回收站互相认得、能恢复。
- 删批注**不进撤销栈**（同 Mac 经 MCP 删的：找回靠回收站）；删完宿主 `AgentHost.annotationsDeleted` 让开着的标签从库里重读批注 / 图片笔记、刷书签。

### 5.4 对话记录（2026-11-16）

- 同 Mac §22：面板一轮**正常答完**记一行 `agent_turn`（用户那句话 + 回复正文；上下文块、工具输出、思考过程不记；停止 / 出错的不记）。
  `conversation_id` 新对话 / 换设置 / 换工作区各换一个；`agent` 列 = `unireader-android`。只追加、随同步（`MirrorFp` 早已含这张表）。
- 工具 `list_conversations` / `read_conversation`（按轮分页），文案照 Mac。系统提示里提了一句，模型想回顾以前聊过什么会用它们。
- 按内容找以前的对话：`search` 的 `conversation` 一类（§5.6）。

### 5.5 Agent 上下文（2026-11-16）

同 Mac §12（换个 Agent 接着做的交接摘要，`agent_context` v23，本端早已建表、随同步）：
- 工具 `list_agent_contexts` / `read_agent_context` / `save_agent_context`（带 `id` = 改那份，没变不写），文案照 Mac MCP；系统提示里加了 Mac 面板上下文块那句。
- 面板标题行 ⋯ 改成系统菜单：**保存这段对话为上下文**（说过话、空闲时可点）/ **随下一句话带上 ›**（已存的，最多 30 份，打勾 = 挂着）/ 设置…。
  - 保存 = 发一句可见的请求 + 隐藏的写法要求（`AgentContextText.SAVE_INSTRUCTION`），这一轮正常答完按第一个标题行切成标题与正文存下，
    对话里提示「已保存为上下文「…」」；停止 / 出错 / 没写出正文 = 不存并提示。这一轮不记进对话记录（同 Mac）。
  - 挂着的显示在输入框上方（「随下一句话带上的上下文」+ 移除），随下一句放进上下文块（`AgentContextText.handoff`），对话里提示「已带上上下文「…」」，带完摘下。
- 文字规则 `AgentContextText` 逐条照 Mac（JVM 单测 `AgentContextTextTest` ↔ `spike/agent-context-test.swift` 前三段）；交接块里「unireader MCP tools」改成「the tools」。
- 没做：管理窗口（改标题 / 摘要、删除进回收站）——要改要删先在 Mac 上做，或让 Agent 用 `save_agent_context` 带 `id` 改。

### 5.6 全工作区搜索（2026-11-16，关键词版）

`search` 工具：参数（`query` / `kinds` / `document_ids` / `note_folder` / `limit`）、匹配、打分、去重、输出格式照 Mac `MCPTools+Search.swift` 的关键词那一路；
范围同 Mac：PDF 每页文字、Markdown 笔记（按标题分段、给行号）、批注、习题、上下文、记忆、对话记录。
- 纯函数 `local/search/SearchText`（归一化：全角→半角、小写、去掉全部空白；切词 / 切块 / 摘要 / 打分）**逐条照抄 Mac `Sources/Search/SearchText.swift`**，
  JVM 单测 `SearchTextTest` ↔ `spike/search-test.swift` 1)~4)。🔴 同一算法两份实现，改一边要同步另一边。
- 与 Mac 的差别：**不建持久索引**（Mac 是 SQLite 索引 + 可选语义搜索），每次现场取：库里的行在库队列上读，`Notes/` 读文件。
  PDF 用库里 `ocr_page` 的 OCR 文字（滤过水印），按「文档 id + 标题 + 内容 hash」缓存**切好、归一化好的块**（OCR 行数 / 最新时间变了才重读，最多 12 本）。
  2000 页 × 约 800 字实测（`AgentToolsTest.searchTiming`，小米 Pad 6）：首次 2.2 秒（解析 OCR），之后 0.07~0.3 秒。
  没 OCR 的页：书开在标签里就用 PDF 自带文字层补；整本没 OCR 又没开的书搜不到正文，结果末尾列出书名、建议用 `open_document` / `search_text`。
- 没做：语义搜索（方向已定：安卓只算查询向量、块向量经服务器同步过来，Q8_0 一致性已实测，见 `SEARCH-PLAN.md §5.5`）；Mac 引用的外部笔记目录（本端只有内建 `Notes/`，没有 `note_source` 参数）；习题标签（本端习题模型没有这一列）。

### 5.7 改批注（2026-11-16）

`update_annotations`：照 Mac `MCPFacade+Annotations.updateAnnotations`——批注改正文 / 颜色（`none` = 回到类型色）/ 画法 / 类型 / 展开方式，高亮改颜色 / 画法，
书签改名，图片笔记改说明 / 展开方式；有一条不合规（id 不对、字段不属于那一种、类型不存在…）就一条都不改。只动 payload 里要改的键，其余原样。
写入走 `AgentHost.writeNotes`（开着的那篇进撤销栈、马上显示），写完 `annotationsChanged` 重读图片笔记、刷书签。

- 读文字要那本书**在标签里装载着**（本机只有标签里的 Pdfium 实例）；没开就替用户开、等它装好（最多 10 秒）。
- 返回给模型的是纯文字（Mac MCP 的 `text` 部分），不带结构化 JSON。

### 5.8 习题（2026-11-16）

| 工具 | 说明 |
|---|---|
| `list_exercises` | 一本书（或 `all_documents`）的题，按练习顺序；`exercise_ids` / `filter`（mistakes / starred）/ 分页。只回文字，所以每道题把题干、选项、参考答案、章节、错题 / 收藏、练习统计都写出来（Mac 的文字只给一行、细节在结构化结果里） |
| `list_exercise_attempts` | 作答，最新的在前：题干、参考答案（同 Mac `referenceAnswerText`）、用户的作答（填空逐空 + 每空对不对得上）、判定（谁判的）、评语；`ungraded_only` = 还没判的填空 / 主观题。SQL 照 Mac `exerciseAttemptPage` |
| `grade_exercise_attempts` | 批改填空 / 主观题：`judged_by = 'agent'` + 评语，判错进错题本；选择题不能批；整批先校验，有一条不对就一条都不写（同 Mac） |
| `open_exercises` | 在公用习题标签里开一组（全部 / 错题本 / 收藏，可限一本书），`exercise_id` = 停在那道题（`ExerciseController.focus`） |

- 批改后宿主 `AgentHost.exercisesChanged` → 开着的练习页就地刷新，练习页本来就显示「Agent 评语」。
- 没做：Mac 的 `pages` / `chapter` / `tag` 筛选、看原题图与手写作答（`render_exercise*`，要图片输入）、导入 / 改题 / 删题。

### 5.9 日程（2026-11-16）

`list_schedule` / `add_schedule_items` / `update_schedule_items` / `delete_schedule`，参数、校验、文字输出照 Mac `MCPTools+Schedule.swift`（批 8）。
本端**没有日程界面**：Agent 在平板上排的计划随同步到 Mac，在 Mac 的日程页 / Inspector「今天」看；`open_schedule` 不做。
- 纯规则 `local/schedule/Schedule.kt`（`ScheduleDay` / `ScheduleTime` / `ScheduleText.agentLine`，JVM 单测 `ScheduleTest` ↔ `spike/schedule-test.swift`）。
- 库层 SQL 照抄 Mac（排序 `day, start_min, seq, created_at, id`；按 id 前缀找 `scheduleItemsByPrefix`）；写入语义照 Mac `WorkspaceManager+Schedule`：
  同一天新加的排在最后、一批 `created_at` 依次加 1 毫秒保住先后；改的时候跟库里一样的不写、挪到别的日子的排到那天最后；整批先校验。
- 删除先归档（`Trash.deleteSchedule`，回收站「日程」条目，同 Mac 的格式）。
- 新对话第一句带上 Mac 那一行日程摘要（今天几件、过期几件、几份计划）。

### 5.10 Markdown 笔记：打开 / 改名挪目录 / 删除（2026-11-16）

- `open_markdown`：在标签里打开一篇。
- `rename_markdown`：改名（`title`）和 / 或挪到 `Notes/` 里另一个目录（`folder`，没有就建）；撞名不改。开着的标签跟着换身份、没存的输入先存。
  🔴 红线 9：不改别人的正文；改名前后各认一遍别的笔记里的 `[[…]]`（`MdNotes.backlinks` + `Index.note`），断了的列给模型（同 Mac）。挪目录名字不变，`[[名字]]` 照样认得。
- `delete_markdown`：挪进 `Notes/.trash/`（同界面删除，Obsidian 的回收站目录），开着的标签关掉；指向它的链接列出来。
- 抽屉菜单里的「改名 / 删除」与 Agent 共用 `ReaderActivity.renameMarkdown` / `deleteMarkdown`（原先写在菜单回调里）。
- 没做：Mac 的引用外部目录（note source）之间搬、`move_markdown_folder`（整个目录改名）、`update_markdown`（整篇覆盖，有 `edit_markdown`）。

### 5.11 书：目录 / 改名改分组（2026-11-16）

- `get_document`：页数、分组、读到哪、几页有 OCR，加 PDF 目录（1 起的页码，缩进表示层级）；目录从标签里的 Pdfium 读（没开就替用户开），`AgentHost.documentToc`。
- `update_document`：改书名（只改库里的名字）/ 改分组（`""` = 不分组），`document_ids` 一次挪几本；写完 `AgentHost.libraryChanged` 刷抽屉和标签上的名字。

## 6. 界面（`local/agent/AgentPanel.kt`）

- 顶栏「agent」键（`ic_agent`，默认在「页面」组）开关；返回键先关它。贴右边满高，宽 `min(440dp, 屏宽 92%)`，**不盖遮罩**：面板外照常翻书写字。
- 标题行：新对话（＋）/ 设置（⋯）/ 关闭。输入框多行，按钮在「发送 / 停止」之间切。
- 一轮的显示按到达顺序：思考（一行，说完收成「思考过程（点开查看）」）/ 正文（流式只追加文字，一段说完按 Markdown + 公式重画，`MathText.bind`）/
  工具调用（一行 `… name` → `✓ name` / `✗ name`，点开看参数与结果）。
- 每条消息前拼一段用户看不到的上下文块（工作区、当前标签与页）；新对话第一句再带上工作区记忆（最多 50 条，同 Mac §21）。
- 换工作区清空对话；改了设置下一句起用新引擎（对话清空）。

## 7. 没做 / 下一批

- Agent 上下文的管理窗口（改 / 删，§5.5）。
- `workspace_stats`（Mac `StatsStore` 557 行 SQL；按标签统计用了 JSON1 的 `json_each`，本端约定不用 SQL 的 `json_*`，要改写法）。
- 画板（`list_boards` / `render_board`）、知识关联（`links` / `markdown_links`）、`render_page`（要模型支持图片）。
- 语义搜索（§5.6）。
- `render_page`（多模态看图）：要模型支持图片输入，设置里加开关。
- 模式2（连 Mac）不做：那边直接用 Mac 的 Agent 面板。

## 8. 验证

- `AgentEngineTest`（插桩，`androidTest/…/local/agent/`）：测试进程里起一个 127.0.0.1 的假 OpenAI 兼容 SSE 服务，
  验路径拼接、鉴权头、分段参数拼接、工具结果带 `tool_call_id` 回传、`reasoning_content`、空参数工具调用、多轮历史。不要 API Key、不碰界面。
- `AgentToolsTest`（插桩）：cacheDir 里新建真工作区 + 手写两页 PDF + 不经界面的假宿主，十几个工具逐个跑、回库 / 文件核对
  （高亮的行框位置、批注的锚点与 `source`、书签、Markdown 新建 / 编辑 / 报错、记忆改写；删除：有一个 id 对不上一条不删、
  回收站条目种类 / 计数 / 名字、从回收站放回去；对话：列表先后、分页、同 id 不覆盖；上下文：标题规整、带 id 改且没变不写）。
  搜索：OCR 跨行命中、没 OCR 的页用自带文字层补、各类都搜得到、按类筛、退回「任一词」；`searchTiming` 只打日志量速度。
  `MdEditTest`（JVM）6 条、`AgentContextTextTest`（JVM）3 条、`SearchTextTest`（JVM）4 条。
- **真机冒烟（2026-11-15，用户授权我自己测）**：Mac 上起假的 OpenAI 兼容服务（只读剧本：`get_state` → `read_pages` → 正文），
  `adb reverse` 接到平板，在 408学习区 里经界面配设置、发一句话：三次请求都带鉴权与 16 个工具，工具结果是真实状态，
  界面依次显示思考 / `✓ get_state` / `✓ read_pages` / Markdown 正文，输入框随键盘顶起，无崩溃。测完删了设置、结束了进程。
  写入类在真机上**没走界面**（不往用户的工作区写），只有上面的插桩测试。
- 手感 / 观感（面板宽度、流式滚动）由用户在真机上测，结论记在 §8.1。

### 8.1 真机待测

- [x] 设置里填地址 / Key / 模型，问「这页讲了什么」→ `read_pages` 后作答（2026-11-16 Kimi `kimi-for-coding` 实测；它直接用上下文块里的页码，没先调 `get_state`）
- [ ] 「跳到第 N 页」→ 阅读区跟着跳（2026-11-16 实测跳到了、后退键亮了），能用后退键退回来（没按过）
- [ ] 「记住我在复习第 3 章」→ `save_memory`；新对话里它知道
- [ ] 回答中途点「停止」；面板开着时在左边继续写字
- [x] 键盘弹出时输入框不被挡住（冒烟测试里看到输入框随键盘顶起）
- [ ] 「在这段话上加个批注 / 把这句标黄」→ 页面上马上出现，撤销键能撤掉
- [ ] 开着一篇 Markdown 笔记边打字边让 Agent 改它 → 没存的输入还在
- [ ] 「把刚才那条高亮删掉」→ 页面上马上没了；⋯「回收站…」里有一条「批注」，恢复后又出现
- [ ] 「把关于第三章的那条记忆删了」→ 回收站里有「Agent 记忆」条目；Mac 上打开同一工作区的回收站也认得
- [ ] 聊两轮后点 ＋ 开新对话，问「上次我们聊了什么」→ 它调 `list_conversations` / `read_conversation` 答得出
- [ ] ⋯ 弹出菜单（一句没说时「保存这段对话为上下文」是灰的）；聊几句后点它 → 对话里多一句请求、答完提示「已保存为上下文「…」」
- [ ] 点 ＋ 开新对话 → ⋯「随下一句话带上」里有刚才那份 → 点它：输入框上方出现那一块；说「接着做」→ 提示「已带上上下文「…」」，它知道之前做到哪
- [ ] Mac 打开同一工作区：「管理上下文…」里看得到平板存的那份（Agent 列 `unireader-android`）
- [ ] 「在整个工作区里找一下讲进程调度的地方」→ 它调 `search`，列出几本书的页 / 笔记段落，再 `read_pages` 读
- [ ] 「把那条高亮改成绿色 / 把书签改个名」→ `update_annotations`，页面上马上变，撤销键能撤回
- [ ] 在平板上做几道填空 / 主观题（打字作答、先别自己判）→ 「帮我批改刚才做的题」→ 练习页出现「Agent 评语」，判错的进错题本
- [ ] 「打开错题本」/「打开刚才那道题」→ 练习标签切过去、停在那道题
- [ ] 抽屉里长按一篇笔记「改名 / 删除」照旧好用（代码挪成了与 Agent 共用的函数）；让 Agent「把这篇笔记改名为…/挪到某目录」→ 标签跟着变，它报出断了的链接
- [ ] 「帮我排两周的第三章复习计划」→ `add_schedule_items` 建一份计划；Mac 同步后日程页里看得到；「把昨天没做完的挪到明天」→ `update_schedule_items`
