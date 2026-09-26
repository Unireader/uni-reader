# AGENTS.md — UniReader

macOS 26+ PDF 阅读器（非沙盒，Tahoe 专属，不做低版本兼容）。Swift 5 / AppKit / xcodegen 管理；界面全部 AppKit，SwiftUI 只许出现在红线②列的两处（详见 `APPKIT-REWRITE-PLAN.md`）。

> 本文件只留每次会话都要用的硬规则与索引；完整细节拆在 `docs/agents/`（同一条规则只在一处维护）：
> `BUILD-DETAILS.md` 发布流程 / Sparkle 密钥 / SPM 包 / 采集页构建 / 子工程约定，
> `STRUCTURE.md` 各模块结构全文，`PITFALLS.md` 全部「关键坑」实录。

## 构建与验证

```bash
xcodegen generate   # 新增/删除源文件后必做；UniReader.xcodeproj 是生成物，勿手改
xcodebuild -project UniReader.xcodeproj -scheme UniReader -destination 'platform=macOS' \
  -configuration Debug -derivedDataPath build/dev build CODE_SIGNING_ALLOWED=NO
# → 产物 build/dev/Build/Products/Debug/UniReader.app（open 它就能测）
```

- 无测试 target；验证走 spike 脚本：`swift spike/<name>.swift`（如 `store-test.swift` 32 项 DAO、`ink-store-test.swift` 21 项）。
- 🔴 **产物只许落在**下表的位置（2026-09-03 定）：

  | 用途 | 路径 | 怎么出 |
  |---|---|---|
  | 开发/测试包（含只为验证编译） | `build/dev/` | 上面那条 `-derivedDataPath build/dev` |
  | 正式分发包 | `build/UniReader-<版本>.zip` | `scripts/package.sh` |
  | GitHub 发布 | 同上 zip + `.dmg` | `scripts/release.sh` |

  `-derivedDataPath build/dev` **不是可选项**（省掉就写进随机 DerivedData 路径）；编译验证也走这条。
  给用户实测**别跑 `package.sh`**（Release + 公证 + 自动 bump 版本），Debug 包够用。
  背景与例外见 `docs/agents/BUILD-DETAILS.md`。
- 发布到 GitHub（`scripts/release.sh` + 发布日志 + appcast/Sparkle）与 **SPM 第三方包**（`swift-markdown-engine` fork、Sparkle、`swift-acp`）：全流程与细则在 `docs/agents/BUILD-DETAILS.md`，**发布/升包前必读**。
- 采集页前端 `web/` 改动后跑 `scripts/build-web.sh` 再编译 App（`capture.html` 是构建产物、不入 git）。
- 项目级用户规则：不代用户执行安装（brew/pip/npm 一律给脚本让用户跑）；交流用中文或英文。
- Android 端（`android/`）：构建 `cd android && ./gradlew assembleDebug`，打包 `android/pack.sh`。**其余规则、结构与坑全在 `android/AGENTS.md`（改安卓代码前先读它），本文件不重复。**

## 文档地图（改代码前先读对应方案文档）

- `TODO.md` — 交接状态速览 + 待办 + 已知坑，**第一优先**（只留进行中/待办）；`HISTORY.md` — 已完成事项归档（TODO 条目做完即迁入）
- `REQUIREMENTS.md` — 需求与 §8 工作区持久化方案
- `PROTOCOL.md` — 二进制线格式**唯一契约**（Mac / web / 安卓三端字节级一致），改协议先改它
- `PDF-VIEWER-REBUILD-PLAN.md` — 阅读区 v2（`PageStreamView`）的五条硬指标与零闪烁纪律
- **`APPKIT-REWRITE-PLAN.md`** — 界面整体重写为 AppKit（含阅读区，2026-09-19 拍板，`appkit-rewrite` 分支）：§7.1 实测清单、§9 实现记录；`APPKIT-WINDOW-PLAN.md` 是被它取代的前身
- `REF-WINDOW-PLAN.md` — 参考窗（只读浮窗）；`OFFLINE-MIRROR-PLAN.md` — 工作区离线镜像（Mac + 安卓模式1，三方合并）
- `INK-PAGING-PLAN.md` — 笔迹内存按页窗口加载/淘汰（**`session.strokes` 不再是全集**）；改笔迹代码前先读
- `MCP-PLAN.md` — MCP 服务（内置 HTTP 端点给外部 Agent）；§15/§16/§17 是实现记录
- `ACP-AGENT-PLAN.md` — Agent 面板（ACP 客户端）；§2 fork 做法、§7 Markdown 正文、§8 `@` 选文件
- `IMAGE-NOTE-PLAN.md` — 图片笔记（note kind=6 + `image` 表 v13 + `Images/`，内容寻址、待删除 30 天）
- `SCAN-ALIGN-PLAN.md` — 扫描页对齐（每页旋转+平移，按内容哈希记）：**开着时对齐后的页面就是页面坐标**；变换/`page_align`(v14)/`displayKey` 是三端契约
- `SCAN-ENHANCE-PLAN.md` — 扫描页增强（出图时处理、不改 PDF）：算法版已落地，AI 调研暂停、接着做看 §3.5
- **`BACKUP-PLAN.md`** — 回收站 + 定时备份两套兜底（`Trash/` 快照归档、`VACUUM INTO` 分级稀释）
- `URL-SCHEME-PLAN.md` — `unireader://open?…` 链接（Obsidian / Agent 点回某页某条笔记）；导出 Obsidian 不做进 App，按 `skills/unireader-obsidian-export/SKILL.md` 做
- **`MARKDOWN-NOTES-PLAN.md`** — 工作区 Markdown 笔记（内建 `Notes/` + 引用的外部目录；侧栏多级树；标签页编辑自动保存）
- **`BOARD-NOTE-PLAN.md`** — 画板笔记（v16 无限白板 + v17 分页模式）：运行时 = 会话里一张永远开着的草稿纸；协议 0x52~0x55；§8/§9 是实现记录
- `docs/agents/BUILD-DETAILS.md` · `docs/agents/STRUCTURE.md` · `docs/agents/PITFALLS.md` — 本文件拆出的三份细节
- 子目录可自带 `AGENTS.md`（`android/` 即独立 git 仓库 + 自带规则）；新子工程照此办理，跨端契约仍留根目录，见 `docs/agents/BUILD-DETAILS.md`

## 红线（用户明确否决过，勿重走）

1. 阅读区**严禁 `PDFView`**（PDFKit 私有 clip view 缺陷 → 缩放跳位/闪烁）。PDFKit 只用 `PDFDocument`/`PDFPage` 解析与出图。**零闪烁纪律照旧**：阅读区图层一律无隐式动画（`QuietLayer`/`QuietShapeLayer`），图只替换不清空，缩放用滚动视图自带放大倍率。
2. **SwiftUI 只用在两处**，其余界面一律 AppKit：① Markdown 引擎的 SwiftUI 包装（笔记气泡只读渲染、笔记编辑区、Agent 回复正文，都经 `NSHostingView` 托管）；② 设置窗每页表单（`Sources/Settings/`）。
3. UI 外观**严禁自绘仿系统样式**：系统观感只能用标准控件与材质（`NSVisualEffectView` 等），做不到就用系统默认。
4. **材质/玻璃底上的文字与按钮别用次要色/无边框淡样式**（`secondaryLabelColor`、不设 `contentTintColor` 的 borderless）——系统画得极淡、看不见。层级差异用**字号**表达，颜色一律显式 `labelColor`。
5. **显示页图的窗口 `colorSpace` 必须 = 页图色彩空间（sRGB）**（`ReaderWindowController`/`RefWindowController` 都设 `win.colorSpace = .sRGB`）：不一致时每张页图被 CA 整张重画转色，连滚 10 秒多 600MB。新开带页图的窗口照此设。
6. 存储**弃用 SwiftData**，用工作区 SQLite（`Sources/Store/`，系统 libsqlite3、零第三方依赖；跨平台 payload 用显式 JSON 数组）。
7. 滚动跟随**只跟随不预测**：纯临界阻尼低通，禁速度外推（WiFi 成批投递导致过冲闪回）。
8. 重建 PDF 显示前**必须先与用户确认方案**，不要自行动手。
9. Markdown 笔记**自动维护不许改正文**（用户原话「不要改 `[[]]` 现有的哪怕不兼容也不要改」）：导入/改名/挪目录/扫描都不动正文；`[[…]]` 按名字解析，断链是明确接受的代价、不自动修。只有用户显式编辑或明确要求走 MCP `edit_markdown`/`update_markdown` 才写。
10. `InkEdit.splitStroke` 与 web 端 JS 版**同算法两份实现，改一边必须同步另一边**。
11. 删除类操作**先归档再删除，顺序不许反**（回收站；先删再存 = 中途失败就没了）。

## 结构要点（速览）

目录地图：`Sources/App/`（单例 + 渲染管线 + 笔迹纯函数 `InkEdit`/`InkUndo`/`InkWindow` 等）、`Sources/Store/`（工作区 SQLite）、`Sources/Server/`（LAN WS + UDP，契约 `PROTOCOL.md §6`）、`Sources/MCP/`、`Sources/Agent/`、`Sources/Reader/`（阅读区 AppKit，`ReaderView` + 扩展 + `Pane/Ref/Rack/Scratch/`）、`Sources/Window/`、`Sources/Settings/`、`Sources/Markdown/`、`web/`（采集页前端）。**改哪个模块，先读 `docs/agents/STRUCTURE.md` 对应条目 + 该模块方案文档**（文件头还有各 spike 测试）。跨条目的硬约束已抄进上面的红线；其余不变量：

- MCP：`MCPFacade` 是唯一碰 App 活状态处；页码对外 1 起、对内 0 起，换算只在 `PageNo`。
- DeepLink/MCP：🔴 「让某篇显示出来」只有 `AppDelegate.showDocument` 一份，别在两边各写找标签/挑窗口。
- Agent 面板：只住 Inspector「Agent」页；流式碎片只就地换文字、不重建视图；与咨询 AI（`Sources/AI/`）别混。
- Markdown 笔记：`DocTabModel.noteRef` 与 `docID` 互斥；`WorkspaceWikiIndex` 一个工作区一个；存正文刻意不调 `refreshNotes()`。
- OCR：消费方一律 `DocSession.ocrVisibleRuns(page:)`（已滤水印块），`ocrRuns` 只给落库、别直接消费。
- 扫描页对齐：新增出图口必须传 `session.pageAlign(i)`；显示身份用 `displayKey` 别用 `contentHash`。
- Inspector：真分栏、不叠在阅读区上（工具栏带 `.inspectorTrackingSeparator`）。

## 已知关键坑（速记）

全文在 **`docs/agents/PITFALLS.md`**（按模块分节，含排障打点日志开关）。最常撞的：

- 设置页每项必须绑 SwiftUI 自己的状态（`Binding` 包静态属性 = 点了没反应）；`@Published` 在 `willSet` 发出，Combine 回调里读到旧值。
- 滚动条：异步高度变化后**只能 `needsLayout` + `reflectScrolledClipView(_:)`，别手动 `tile()`**；页宽不能拿 tile 后的视口宽算（`fitAvail` 按滚动视图外框）。
- 「重排 + 钉回」事务（refit/rebase/applyZoom）必须包 `ReaderView.relayouting` 门，否则错误页码会写进阅读进度。
- 流式/列表 UI 增量重排，新视图先进 stack 再激活约束；隐藏页只攒不排、停手再排。
- Markdown 引擎 `onLinkClick` 只在 `makeCoordinator` 捕获一次，传固定身份中转闭包（`LinkRelay`）。
- Tahoe 工具栏：只有连续纯图标 Button 才合并成玻璃胶囊，两组间插 `ToolbarSpacer()`。
