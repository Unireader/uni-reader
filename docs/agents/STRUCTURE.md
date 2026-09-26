# 结构要点 — 各模块完整说明

从 `AGENTS.md`「结构要点」拆出的全文（2026-09-26 拆分）。主文件只留一行一模块的速览，动哪个模块前先读这里对应条目 + 该模块的方案文档。

- `Sources/App/` — App 级单例：`AppModel`/`DocSession`（多窗口共享 WS/LANServer）、`WorkspaceManager`（工作区 = `.unrd` 包：UTI 声明在 `Sources/Info.plist`，旧无扩展名工作区首启原地改名迁移、工作区改名联动改包名；双击/拖 Dock 由 `AppDelegate.openFile` → 通知路由到 key 窗口）、`UpdaterService`（Sparkle 2 自动更新薄封装，2026-09-18 加，菜单「检查更新…」与设置 ›「通用」的「更新」区块共用；详见 `docs/agents/BUILD-DETAILS.md`「发布到 GitHub」）、`PageRenderEngine`/`PageLayout`/`PageBitmap`（v2 渲染管线）、`InkEdit`（笔迹纯函数：局部擦除切段/平移/缩放/尺子吸附/自由框选多边形命中，**`splitStroke` 与 web 端 JS 版同算法两份实现，改它必须同步另一边**，测试 `spike/ink-edit-test.swift`）、`InkUndo`+`DocSession+InkUndo`（编辑撤销栈：**增量**记账、瞬态不落库、页内与草稿纸各一条；连续擦除并成一步，抬笔封口）、`InkPaste`（粘贴的摆放数学，纯函数：Mac 本机 ⌘V 与平板 `clip paste` 共用一份）、`InkClipboard`（笔迹剪贴板，系统 `NSPasteboard` 自有类型，条目编码复用落库 payload；两者测试 `spike/ink-undo-test.swift`）、`InkWindow`（笔迹**按页窗口**装载/淘汰的纯函数：`session.strokes` 只是已装载页的集合，整篇操作问库，见 `INK-PAGING-PLAN.md §9`；测试 `spike/ink-window-test.swift`）。笔迹点 `InkPoint = SIMD3<Float>`，「存 Float、算 Double」
- 回收站与备份（`BACKUP-PLAN.md`）：`Store/TrashStore.swift`（`ATTACH` + 按列通用复制，`LibraryStore` 的 DAO
  约定在这里开第二条窄口子，同 `MirrorStore`）+ `App/TrashModel.swift`（纯 Foundation：manifest / 目录扫描 /
  到期判定）+ `App/WorkspaceManager+Trash.swift`（执行层；归档那两个入口是 `Trash` 上的**静态函数**——
  图层面板手上只有 `DocSession`，而 `LibraryStore` 自己知道 `workspaceFolder`）+ `App/BackupRetention.swift`
  （纯函数：保留策略 + 文件命名）+ `App/BackupService.swift`（调度与还原）+ `Window/Sheets/{TrashSheet,BackupsSheet}.swift`。
  🔴 **归档 → 删除，顺序不许反**（先删再存 = 中途失败就没了）；🔴 图片本体的 30 天清理要**跳过回收站还引用着的**
  （`WorkspaceManager.purgeImages` 读 `trashHeldImages`），否则保留期 90 天 / 永不时图片先一步被清、恢复只剩空框。
  测试 `spike/trash-test.swift`（62 项）、`spike/backup-retention-test.swift`（39 项）
- `Sources/Server/` — LAN WS 服务、二维码配对、UDP RT 上行（`UDPTransport` + 纯逻辑 `UDPReorder`，契约 `PROTOCOL.md §6`）
- `Sources/MCP/` — MCP 服务（给外部 Agent 用，`MCP-PLAN.md`）：`MCPModels`/`MCPHTTP`/`MCPCatalog`/`MCPProtocol` 四个**只依赖 Foundation** 的纯逻辑文件（spike `mcp-protocol-test.swift` 直接编它们）+ `MCPServer`（`NWListener`，与 `LANServer` **不共用端口和队列**）+ `MCPFacade`（🔴 **唯一**碰 App 活状态的地方，`@MainActor`，只拼 DTO）+ `MCPDocReader`（私有 `PDFDocument`，`session.pdf` 不出主线程）+ `MCPTools*`（工具目录）+ `MCPResources`（资源 = 调同名工具）。页码对外 1 起、对内 0 起，**换算只在 `PageNo`**。🔴 写入按「文档开没开」分两条路（开着只改 `DocSession` 数组，见 `MCPFacade.writeTarget`）。设置页在 `Settings/MCPSettingsView.swift`
- `Sources/Agent/` — Agent 面板（`ACP-AGENT-PLAN.md`）：`AgentConnection`（一个工作目录一个 `kimi acp` 子进程，swift-acp 的 `Client`）+ `AgentChat`（一段对话，**不落库**）+ `AgentTranscript`（纯函数：`session/update` 拼条目、回放时剔上下文块）+ `AgentPanelModel`（总开关 / 进程池 / 对话表，每扇阅读窗口一段对话）。界面 `Window/AI/AgentChatNSView`，**只住在 Inspector 的「Agent」页**（2026-09-19 用户定；浮在阅读区右侧的内置面板与独立窗口已删）。回复与思考的正文走 Markdown 引擎只读渲染（`Window/AI/AgentMarkdownView`，2026-09-20，`ACP-AGENT-PLAN.md §7`）——🔴 **流式碎片只就地换文字、不重建视图**，且按 80ms 并成一次交给引擎；工具输出照旧是等宽纯文本。与咨询 AI（`Sources/AI/`）**各管各的**，别混。MCP 这边只多了一个请求头 `x-unireader-agent`（「跟随 Agent」开关，`AgentFollow`）。输入框 `@` 选文件（`AgentMention` 纯逻辑 + `Window/AI/AgentMentionPopup` 浮窗，`ACP-AGENT-PLAN.md §8`）：🔴 只附 `resource_link`（名字 + 位置），**不带文件内容**
- `unireader://` 链接（`URL-SCHEME-PLAN.md`）：`App/DeepLink`（纯 Foundation 的解析 / 生成，spike `deep-link-test.swift`）+ `App/DeepLinkRouter`（找工作区 → 开窗 → 开文档 → 跳位置 → `DocSession.revealNoteID` 展开气泡）；入口 `AppDelegate.application(_:open:)` 按 scheme 分流、冷启动缓冲 `pendingDeepLinkURL`。🔴 **「让某篇显示出来」只有 `AppDelegate.showDocument` 一份**（MCP `open_document` 与链接共用），别在任何一边另写找标签 / 挑窗口的规则
- `web/` — 平板采集页前端工程（Svelte 5 + Vite + TypeScript，`vite-plugin-singlefile` 单文件构建）。`Sources/Resources/capture.html` 是它的**构建产物，勿手改**；源在 `web/src/`（`App/TopBar/StatsPanel/PenStat/TextNoteEditor.svelte`（文字笔记编辑器）+ `lib/`：shared 状态袋与公式（含 `GState` 等共享类型）/ hud.svelte.ts 响应式 HUD / render / input / ws / capture 装配）。占位符 `__WS_PORT__`/`__TOKEN__`/`__PENS__` 在 `web/index.html` 内联脚本里（不过 bundler），由 `CapturePage.swift` 运行时替换；`wire.js` 协议编解码器由 `web/src/lib/wire.ts` 直接 import `Sources/Resources/wire.js`（单一真源，勿复制）构建期内联。
- `Sources/Reader/` — 阅读区（AppKit）：`ReaderView`（主类：输入量、状态、实化页、图层池）+ 扩展 `Render`（出图调度 / 贴片 / 夜间）、`Zoom`（⌘滚轮 / 捏合 / 缩放动画 / 换基准）、`Follow`（滚动回报 + 平板跟随，`ScrollFollower` 由 `NSView.displayLink` 驱动）、`Canvas`（画板页边）、`Marks`（坐标换算 + 标记层刷新）、`Overlay`（图钉 / 气泡 / 橡皮圈 / 提示条）、`Input`（鼠标按指针工具分派 + 键盘 + 拖放）、`TextSelect`、`Lasso`、`Actions`（批注 / 高亮 / 图片笔记 / 书签 / 草稿纸入口）、`Menus`（右键菜单与高亮气泡）、`Snip`（⌥ 拖截图：松手弹一个菜单选「问 Agent / 问网页 AI / 复制图片 / 存为图片笔记」，2026-09-24 并成一个；⌥⇧ 拖仍直接存图片笔记）；`ReaderScrollView`（居中 clip view + ⌘滚轮 + 翻转文档视图）、`ReaderLayers` / `PageMarksLayer`（每页图层树，全部无隐式动画）、`InkRenderCG`（四种笔型的 CoreGraphics 画法）、`ReaderSupportTypes`（选择 / 框选 / 批注草稿 / 菜单命令通知等纯数据）。子目录：`Pane/`（阅读窗格 `ReaderPaneController`：阅读区 + 查找条 + 标签栏 + 笔架 + 草稿纸 + 浮层的装配与摆位）、`Ref/`（参考窗页流）、`Rack/`（笔架 + 图层面板）、`Scratch/`（草稿纸）。本机指针工具 = `AppModel.pointerTool`（textSelect/ink/lasso/snip，设备级全局，笔架切换）
- `Sources/Window/` — 窗口壳与其余界面：`ReaderWindowController`（三段分栏 + `NSToolbar`）、`Sidebar/`、`Inspector/`（含「Agent」页；🔴 **真分栏、不叠在阅读区上**——`contentItem.automaticallyAdjustsSafeAreaInsets` 保持默认 `false`，工具栏必须带 `.inspectorTrackingSeparator`，详见 `APPKIT-REWRITE-PLAN.md §9.2`）、`AI/`（Agent 对话视图 + 网页 AI 面板；网页 AI 2026-09-19 起停用，`AIPanelModel.available = false`，代码留着）、`Floating/`（浮在阅读区上的卡片：参考窗覆盖层、跳转历史）、`Panels/`（工具栏弹出面板、选文档弹窗）、`Sheets/`（批注 / 图片笔记编辑、看大图、类型管理、离线镜像两张面板）；设置窗壳 `SettingsWindowController` / `SettingsTabController` 在 `AuxWindows.swift`
- `Sources/Settings/` — 设置窗六页的 SwiftUI 表单（`SettingsView` 含快捷键页、`MCPSettingsView`），允许 SwiftUI 的两处之一
- `Sources/Markdown/` — `MarkdownNoteEditor.swift`：Markdown 引擎的 SwiftUI 包装、公式渲染器 `NoteLatexRenderer`、`NoteLinkClick`（允许 SwiftUI 的另一处）；
  `WorkspaceWikiIndex.swift`（v15）= 引擎的两个服务：`[[…]]` 解析（`WikiLinkResolver`）+ `![[…]]` 图片（`EmbeddedImageProvider`）。
  🔴 **一个工作区一个**（`WorkspaceManager.wiki`，`refreshNotes()` 里换快照）——名字只在自己工作区里有意义，做成全局单例
  会把 A 工作区的 `[[极限]]` 连到 B 工作区同名那篇去。编辑器 / 气泡 / 整篇编辑区三处都由上层把它传进去；
  `MarkdownDocEditor.swift` 是整篇笔记的编辑区（允许 SwiftUI 的第三处）
- Markdown 笔记（`MARKDOWN-NOTES-PLAN.md`）：纯逻辑在 `Sources/App/` —— `NoteTree`（`NoteRoot` 两种源 /
  `NoteRef` = 源+相对路径 = **笔记的身份** / `NoteFolder` 多级树 / `NoteIndex` 按名字解析）+
  `MarkdownLink`（**只扫描不改写**：保护区、`[[…]]` 目标名、图片引用、frontmatter 别名）+
  `MarkdownImport`（路径与文件工具 + 整目录复制）。执行层 `WorkspaceManager+Markdown`
  （源管理 / 扫描与库对账 / 读写 / 导入）。测试 `spike/markdown-link-test.swift`（66 项）
- Markdown 笔记的界面：标签页里开一篇 = `DocTabModel.noteRef`（🔴 **与 `docID` 互斥**，开笔记前先
  `select(nil)`——所有按 PDF 记账的地方看到的就是一个空标签，一行都不用改）；混合标签组由
  `TabsModel` 另存 PDF / Markdown 的类型与身份，跨启动恢复时仍保持原顺序和活动标签；
  窗格里的 `MarkdownDocView`（`Sources/Window/Markdown/`）托管 `MarkdownDocEditor`，**自动保存三条**：
  停手 0.8 秒 / 视图离开窗口 / App 退出。存正文**刻意不调 `refreshNotes()`**（打字时每 0.8 秒重扫一遍目录
  + 侧栏整棵树重建，代价完全不对等）。侧栏在 `SidebarNode` 的 `md` / `noteFolder` / `noteSection` 三个 case，
  选中键 `rowID`（`"md:"+NoteRef.key`，与 PDF 的 `docID` 区分开）
- OCR 文本层：消费方（选择/复制/⌘A/OCR 搜索/分组/调试上色）一律走 `DocSession.ocrVisibleRuns(page:)`——它已滤掉扫描件的平铺水印块（`OCRWatermark`，几何 + 跨页重复判定，不认具体文字）；`ocrRuns` 是真源，只给落库与建指纹用，**别直接消费**（`ocrGroups` 的下标是按可见行算的，混用即错位）。
- 扫描页对齐（`SCAN-ALIGN-PLAN.md`）：纯逻辑 `App/ScanAlign`（变换 / 参数表 / 测量 / 定中心，spike `scan-align-test.swift`；真 PDF 出对比图用 `scan-align-real.swift`）+ `App/ScanAlignRunner`（多份 `PDFDocument` 并行测全书）。🔴 **「页面」在开着对齐时就是对齐后的那张**：`PageBitmap.displaySize/render/renderTile` 的 `align` 参数**刻意不给默认值**，新增出图口必须传 `session.pageAlign(i)`（漏一处就是那一处的页图和笔迹对不上）；页图缓存键 / 阅读区 `.id` / 平板 `layout.v` 一律用 `DocSession.displayKey`，别用 `contentHash`；与 PDF 原生页坐标互转（选字 / 搜索 / 目录）走 `PageGeometry` 带 `align` 的重载。开关切换 = 清这份内容的 OCR + 整篇重载（`DocTabModel.applyScanAlign`）
- 扫描页增强（2026-09-23 加，**只在出图时处理、不改 PDF**）：`App/ScanEnhance`（参数 + Core Image 滤镜链：降噪 → 估纸色 → 原图÷纸色 → 软色阶 → 轻锐化 / 去色，可选 2 倍超采样）+ `PageBitmap.renderEnhanced/renderTileEnhanced`（贴片外扩 `marginPt` 再裁回，防接缝）。开关**按内容哈希记在本机 UserDefaults**（「视图 › 增强扫描页」，不进库、不同步），参数在设置 ›「阅读」。缓存键在页号后插 `#e<参数签名>`（`PageRenderEngine.baseKey/tileKey` 的 `enhance`），**不动 `displayKey`**。🔴 本版**只作用于阅读区**（`ReaderView`）；参考窗 / 缩略图 / 草稿纸 / 平板 / MCP / OCR 仍是原图。参数一变屏幕上的旧图记进 `staleImages/staleTiles`，只替换不清空。🔴 **软色阶不能改回硬切**（`(x-lo)/(hi-lo)` 那种）：用户实测嫌颗粒感，根因就是字边灰度被切成非黑即白。样张 + 贴片一致性检查 `spike/scan-enhance-look.swift`；取舍与 AI 调研见 `SCAN-ENHANCE-PLAN.md`

各条对应的界面/滚动类「关键坑」全文在 `docs/agents/PITFALLS.md`。
