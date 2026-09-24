# AGENTS.md — UniReader

macOS 26+ PDF 阅读器（非沙盒，Tahoe 专属，不做低版本兼容）。Swift 5 / AppKit / xcodegen 管理
（`appkit-rewrite` 分支起界面全部是 AppKit，SwiftUI 只剩 Markdown 引擎托管那一处，见 `APPKIT-REWRITE-PLAN.md`）。

## 构建与验证

```bash
xcodegen generate   # 新增/删除源文件后必做；UniReader.xcodeproj 是生成物，勿手改
xcodebuild -project UniReader.xcodeproj -scheme UniReader -destination 'platform=macOS' \
  -configuration Debug -derivedDataPath build/dev build CODE_SIGNING_ALLOWED=NO
# → 产物 build/dev/Build/Products/Debug/UniReader.app（open 它就能测）
```

### 🔴 产物只许落在这两个地方（2026-09-03 定，起因是同一份 app 在 build/ 和 DerivedData 各躺了一个）

| 用途 | 路径 | 怎么出 |
|---|---|---|
| **开发/测试包**（含只为验证编译） | `build/dev/` | 上面那条 `-derivedDataPath build/dev` |
| **正式分发包** | `build/UniReader-<版本>.zip` | `scripts/package.sh` |
| **GitHub 发布** | `build/UniReader-<版本>.zip` + `.dmg` | `scripts/release.sh`（见下方「发布到 GitHub」） |

- **`-derivedDataPath build/dev` 不是可选项**——省掉它，xcodebuild 就写进
  `~/Library/Developer/Xcode/DerivedData/UniReader-<一长串随机码>/`：路径随机、用户找不到、
  也不知道该清哪个，于是同一份 app 到处都是。编译验证也走这条，别为「反正不要产物」而省。
- 给用户实测**别跑 `package.sh`**：那是 Release + Developer ID + 公证（要等几分钟）且会自动
  bump 版本号。Debug 包够用。（同款规矩：安卓是 `android/pack.sh --debug`，产物在 gradle
  标准位 `android/app/build/outputs/apk/debug/`。）
- `package.sh` 只清自己的 archive/export/zip，**不碰 `build/dev`**，两者可以长期共存。
- 整个 `build/` 已在 `.gitignore` 里；要清干净就 `rm -rf build`。
- 例外只有一个：**用 Xcode GUI 打开项目时它仍写自己的 DerivedData**，那份不归本约定管、也别拿它
  当交付物；命令行一律按上表来。

### 发布到 GitHub（`scripts/release.sh`，2026-09-16 加，2026-09-18 补 Sparkle 自动更新）

公开仓库 `Unireader/uni-reader` 的 release，附件 = 公证并装订过的 zip + dmg；正式版还会把这次更新
写进仓库根目录的 `appcast.xml`（Sparkle 用，托管在 `raw.githubusercontent.com` 的 `main` 分支，
Swift 侧集成见 `Sources/App/UpdaterService.swift`）。流程：

1. **Agent 先写发布日志** `release-notes/v<版本>.md`：中文 + 英文各一份，只写上次发布以来的改动，
   按功能归类、用日常说法（commit 里的内部实现细节不写），界面文案以 `Localizable.strings` 为准。
   两段标题（`## 中文` / `## English`）前各加一行不可见的 `<!-- lang:zh -->` / `<!-- lang:en -->`
   HTML 注释——GitHub 正文渲染不受影响，release.sh 靠它把 appcast 里的更新说明拆成中英文两份，
   Sparkle 按用户系统语言显示对应的那份；没打这两行 marker 的旧发布日志会退化成一份不分语言的说明。
2. 演练：`./scripts/release.sh <版本> --notes-file release-notes/v<版本>.md --dry-run`
   （检查 + 改版本号 + Debug 编译，跑完还原 `project.yml`；不提交、不公证、不推送、不碰 appcast）。
3. 正式发布：同一条命令去掉 `--dry-run`。会推送 main 和 tag 并公开发布，**Agent 跑之前必须先得到用户确认**。
   2026-09-16 在 Agent 会话里 `notarytool history` 曾两次报「No Keychain password item found」，
   过一会儿又能读到（原因未确认）；再遇到就重试一次，仍失败再问用户。

- 版本号由脚本改（构建号自动 +1），发布日志随版本号一起提交成 `release: v<版本>`；要求工作区干净（发布日志除外）、在 `main` 上、不落后 `origin/main`。
- 公证全部通过后才打 tag、`git push --atomic` 推 main + tag，再 `gh release create --verify-tag`；中途失败远端不变，脚本会打印撤销命令。
- appcast.xml 的提交/推送放在 `gh release create` **之后**（这样 appcast 里的下载链接一发布出去就能打开）；
  这一步失败时 release 本身已经发出去了，脚本会打印手动补推 appcast 的命令。
- 编译走 `-derivedDataPath build/dev -disableAutomaticPackageResolution`，不联网拉包；采集页走 `build-web.sh --no-install`，不装依赖；
  Sparkle 的 `sign_update`/`generate_keys` 工具也是从 `build/dev/SourcePackages` 这份缓存里找，同样不现场拉包。
- 公证配置名默认 `noticky-notary`，不同就 `NOTARY_PROFILE=<配置名> ./scripts/release.sh …`。
- **`--prerelease` 版本不进 Sparkle 更新通道**（appcast.xml 只收录正式版）——本项目暂不做「预发布 beta
  channel」这层偏好开关，2026-09-18 与用户确认过，以后要加再补；用这个方式最简单也最安全，不会有人被
  自动推到未测试的构建。
- **Sparkle EdDSA 密钥**（`Sources/Info.plist` 的 `SUPublicEDKey` + 本机登录钥匙串里的私钥）首次发布前
  只需生成一次：`xcodegen generate` → 解析 SPM（`xcodebuild … -resolvePackageDependencies`）→
  `build/dev/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys` 打印公钥，粘进
  `Sources/Info.plist` 再 `xcodegen generate` 一次。⚠️ 公钥一旦随首次发布公开，**严禁更换**——换了
  老版本会拒绝所有未来更新。密钥生成这步涉及本机 Keychain 写入，按项目规矩交给用户自己跑，Agent 不代跑。

- **第三方包（SPM）**，目前三个：`swift-markdown-engine`（`project.yml` 里 `exactVersion` 钉死，现 **0.13.0**；
  🔴 **升级前后都跑一遍 `spike/markdown-relayout-cost.swift`**——0.9.0 每敲一个字按整篇算账，17K 字的笔记 56ms/字、
  52K 字 159ms/字（一帧才 16.7ms），0.13.0 恒定 9~12ms/字不随全文长度涨；量的是主线程 CPU 时间，用法见文件头，
  改动前后对比一眼就知道有没有退步）——笔记编辑器 sheet
  （`MarkdownNoteEditor`）与气泡正文只读渲染（`MarkdownNoteReader`，允许 SwiftUI 的两处之一）用它。取两个产品：核心 `MarkdownEngine`
  （零外部依赖）+ `MarkdownEngineLatex`（2026-09-16 加，笔记里的 `$…$` / `$$…$$` 公式；传递依赖 **SwiftMath**，MIT，
  带 ~7MB 数学字体进 app 包）。公式渲染器 = `NoteLatexRenderer`（套在引擎的 `SwiftMathBridge` 外面：`$$` 块加 `\displaystyle` 按块排版 + 缓存封顶）；
  某条公式能不能渲染，用 `spike/latex-look.swift` 出样张看（SwiftMath 不支持的命令会原样显示源码）。另一个是
  **Sparkle**（`from: "2.9.1"`，2026-09-18 加）——`Sources/App/UpdaterService.swift` 薄封装
  `SPUStandardUpdaterController`，菜单「UniReader › 检查更新…」与设置 ›「通用」的「更新」区块共用它；
  UniReader 不在 sandbox，不需要 Installer XPC service 或额外 entitlements。第三个是 **`swift-acp`**（自家 fork
  `Unireader/swift-acp`，`exactVersion: 0.1.0-unireader.1`，2026-09-18 加，MIT）——Agent 面板的 ACP 客户端，取 `ACP` + `ACPModel`
  两个产品；fork 怎么改、怎么打 tag 见 `ACP-AGENT-PLAN.md §2`。包解析落在 `build/dev/SourcePackages/`，
  新克隆或 `rm -rf build` 之后首次编译要先 `xcodebuild … -derivedDataPath build/dev -resolvePackageDependencies`
  （联网拉包 = 装依赖，**按用户规矩给命令让用户跑**，别自己跑）。升版本只改 `project.yml` 再解析。
- 无测试 target；验证走 spike 脚本：`swift spike/<name>.swift`（如 `store-test.swift` 32 项 DAO、`ink-store-test.swift` 21 项）。
- 采集页前端（`web/`，Svelte + Vite）：改动后跑 `scripts/build-web.sh`（npm install + 单文件构建 + 占位符自检 + 覆盖 `Sources/Resources/capture.html`），再重新编译 App。`capture.html` 是构建产物、**不入 git**——新克隆先跑一次 `build-web.sh`；`scripts/package.sh` 打包时会自动重建（`release.sh` 用 `--no-install` 只构建不装依赖）。
- 项目级用户规则：不代用户执行安装（brew/pip/npm 一律给脚本让用户跑）；交流用中文或英文。
- Android 端（`android/`）：构建 `cd android && ./gradlew assembleDebug`，打包 `android/pack.sh`。**其余规则、结构与坑全在 `android/AGENTS.md`（改安卓代码前先读它），本文件不再重复。**

## 文档地图（改代码前先读）

- `TODO.md` — 交接状态速览 + 待办 + 已知坑，**第一优先**（只留进行中/待办）
- `HISTORY.md` — 已完成事项归档；**TODO 里的条目做完即迁移到这里**
- `REQUIREMENTS.md` — 需求与 §8 工作区持久化方案
- `PDF-VIEWER-REBUILD-PLAN.md` — 阅读区 v2（`PageStreamView`）的五条硬指标与零闪烁纪律
- `REF-WINDOW-PLAN.md` — 参考窗（只读浮窗，各端）：一句话定义 + 被砍清单 + 三端落地要点
- `OFFLINE-MIRROR-PLAN.md` — 工作区离线镜像（Mac + 安卓模式1）：整份复制到本机、离线写笔迹、接回硬盘三方合并
- `APPKIT-WINDOW-PLAN.md` — 窗口层迁到 AppKit（壳归 AppKit / 内容仍 SwiftUI，2026-09-01 拍板；已被下一份取代）
- **`APPKIT-REWRITE-PLAN.md`** — 界面整体重写为 AppKit（含阅读区，2026-09-19 拍板，`appkit-rewrite` 分支）：阅读区结构与五条硬指标的 AppKit 做法、对照表、**§7.1 实测清单**、**§9 实现记录（目录 / 与方案的出入 / 已知遗留）**
- `INK-PAGING-PLAN.md` — 笔迹内存：点压到 f32 + 按页窗口加载/淘汰（**`session.strokes` 不再是全集**；2026-09-10 已落地，§9 是落地记录，改笔迹代码前先读）
- `PROTOCOL.md` — 二进制线格式**唯一契约**（Mac / web / 安卓三端字节级一致），改协议先改它
- `MCP-PLAN.md` — MCP 服务（给外部 Agent 用，App 内置 HTTP 端点，默认回环、可绑所有接口+口令）：分批工具目录、协议层、线程红线、写入策略（2026-09-13 拍板并同日三批全部落地合入 `main`，**§15/§16/§17 是实现记录**；批 1 用户实测通过，批 2/3 待实测）
- `IMAGE-NOTE-PLAN.md` — 图片笔记（note kind=6 + `image` 表 v13 + `Images/`）：内容寻址、引用计数数出来、待删除 30 天、⌥⇧ 拖节选、离线镜像 additive 通道（2026-09-13 Mac 端已落地）
- `SCAN-ALIGN-PLAN.md` — 扫描页对齐（每页旋转 + 平移，「视图」菜单「对齐扫描页」开关，按内容哈希记）：**开着时对齐后的页面就是页面坐标**；变换公式 / `page_align` 表（v14）/ 显示身份 `displayKey` / 离线镜像通道是三端契约（2026-09-17 Mac + 安卓模式1 落地）
- **`BACKUP-PLAN.md`** — 两套兜底（2026-09-21 落地）：**回收站**（删文档 / 删笔迹图层前先把库行归档成
  `<工作区>/UniReader/Trash/<条目>/snapshot.sqlite` + `manifest.json`，**schema 不变、安卓不用动**；
  恢复时若那份 PDF 已被重新导入就并入现有那篇）+ **定时备份**（`VACUUM INTO` 出 `UniReader/Backups/`，
  分级稀释，还原 = 留还原点 → 关连接 → 换文件 → 退出 App）
- `SCAN-ENHANCE-PLAN.md` — 扫描页增强（出图时处理、不改 PDF）：算法版 2026-09-23 落地（颗粒感那次取舍的来龙去脉）；
  AI 模型调研 + 样张结论（Real-ESRGAN general / anime_6B 值得继续、DocRes 放弃），**用户定暂停研究**，接着做看 §3.5
- `URL-SCHEME-PLAN.md` — `unireader://open?ws=&doc=&page=&frac=&note=` 链接（从 Obsidian / Agent 写的清单点回 App 的某页某条笔记）：参数契约、解析顺序、与 MCP 共用的 `showDocument`；MCP 的文档 / 批注 / 位置 DTO 都带现成 `link`（2026-09-14 落地，用户实测通过）。**导出到 Obsidian 不做进 App**，由 Agent 按 `skills/unireader-obsidian-export/SKILL.md` 做
- **`MARKDOWN-NOTES-PLAN.md`** — 工作区里的 Markdown 笔记（Obsidian 格式，2026-09-20 拍板并落地，当天改版三次）：
  **两种源**——内建 `Notes/`（导入 = 整个目录复制进来）与**引用的外部目录**（不复制、就地编辑，
  列表存 `meta.note_sources`，**不进库也不同步**）；侧栏按**真实目录层级多级展开**；标签页里编辑、自动保存。
  🔴 **自动维护不许改笔记正文**（用户原话「不要改 `[[]]` 现有的哪怕不兼容也不要改」）：导入 / 改名 /
  挪目录 / 扫描不改正文；`[[…]]` 按**名字**解析，改名 / 挪目录就断链，这是明确接受的代价。用户显式编辑
  或明确要求 Agent 通过 MCP `update_markdown` 修改正文可以写；工具用 revision 防并发覆盖，不自动修链接。
  `md_doc`（v15）只是内建源的**扫描缓存**，真源永远是文件

### 子目录可以自带 AGENTS.md（`android/` 就是这么做的）

`android/` 是**独立 git 仓库**（根仓库 `.gitignore` 忽略了它，安卓改动在那边单独提交），所以安卓端的规则
**写在 `android/AGENTS.md` 里**（`android/CLAUDE.md` 是它的软链，与根目录同款约定），跟着安卓仓库一起走；
根目录这份只留一句引用，不复制内容——**同一条规则只在一处维护**，避免两边各改一半互相矛盾。

新增其他子工程（如将来的 Windows 端）照此办理：子目录自己写 `AGENTS.md` + `CLAUDE.md` 软链，
根目录在「文档地图」加一行指过去。跨端契约（`PROTOCOL.md`、schema、跨平台方案文档）仍留在根目录，
子目录用 `../` 相对路径引用，别在子目录里复制一份。

## 红线（用户明确否决过，勿重走）

- 阅读区**严禁 `PDFView`**（v1 因缩放跳位 / 闪烁被用户删除，根因是 PDFKit 私有 clip view 缺陷）。PDFKit 只用
  `PDFDocument` / `PDFPage` 解析与出图。2026-09-19 起阅读区改为 AppKit（`NSScrollView` + 每页一棵 `CALayer`，
  用户拍板推翻原「阅读区纯 SwiftUI」红线，`APPKIT-REWRITE-PLAN.md`）；**零闪烁纪律照旧**：阅读区图层一律无隐式动画
  （继承 `QuietLayer` / `QuietShapeLayer`），图只替换不清空，缩放用滚动视图自带的放大倍率。
- **SwiftUI 只用在两处**，其余界面一律 AppKit（重要部分用 SwiftUI 会有控制不了的毛病，用户 2026-09-19 定）：
  ① Markdown 引擎（`swift-markdown-engine` 只公开了 SwiftUI 包装）：笔记气泡正文只读渲染（`BubbleMarkdownHost` →
  `MarkdownNoteReader`，外观钉死浅色、不吃鼠标，链接由卡片单击去开）、编辑弹窗里的编辑区（`MarkdownEditorHost` →
  `MarkdownNoteEditor`）、整篇笔记的编辑区（`MarkdownDocEditor`）与 **Agent 面板的回复 / 思考正文**
  （`AgentMarkdownHost` → `AgentMarkdownView`，2026-09-20 加，主题跟系统外观走、可选中复制），都用
  `NSHostingView` 托管；② **设置窗每页的表单**（`Sources/Settings/`，`NSHostingController`
  装进 `SettingsTabController`）——简单表单是 SwiftUI 的长处，`NSGridView` 版排出来变形，用户要求改回。
- UI 外观**严禁自绘仿系统样式**（用户 2026-07-25 明确否决）：分组 / 胶囊这类系统观感只能用系统标准控件与材质（`NSVisualEffectView` / `NSGlassEffectView` / 系统按钮），系统渲染成什么样就什么样；做不到就保持系统默认，不要自己画。
- **材质 / 玻璃底上的文字与按钮别用次要色 / 无边框的淡样式**（SwiftUI 时代的 `.secondary` / `.borderless`；AppKit 里对应
  `secondaryLabelColor` 与不设 `contentTintColor` 的无边框按钮）：系统会把它们画得极淡，表现是「元素还在、就是看不见」。
  已踩两次——2026-08-07 草稿纸工具条的非激活按钮、2026-09-01 AI 内置面板 header 里的文档名与页码。
  层级差异改用**字号**表达，颜色一律显式 `labelColor`。
- **显示页图的窗口 `colorSpace` 必须与页图色彩空间一致**（页图 = sRGB，`ReaderWindowController`/`RefWindowController`
  都设 `win.colorSpace = .sRGB`；2026-09-13 实测定）：不一致时 CA 每张页图都要用 CG 整张重画转色 →
  每张页图三份（mmap + CA 副本 + CG 转换缓存），连平板滚 10 秒就多 600MB。新开一种带页图的窗口照此设。
- 存储**弃用 SwiftData**，用工作区 SQLite（`Sources/Store/`，系统 libsqlite3、零第三方依赖，跨平台 payload 用显式 JSON 数组）。
- 滚动跟随**只跟随不预测**：纯临界阻尼低通，禁速度外推（WiFi 成批投递导致过冲闪回，已修过一次）。
- 重建 PDF 显示前必须先与用户确认方案，不要自行动手。

## 结构要点

- `Sources/App/` — App 级单例：`AppModel`/`DocSession`（多窗口共享 WS/LANServer）、`WorkspaceManager`（工作区 = `.unrd` 包：UTI 声明在 `Sources/Info.plist`，旧无扩展名工作区首启原地改名迁移、工作区改名联动改包名；双击/拖 Dock 由 `AppDelegate.openFile` → 通知路由到 key 窗口）、`UpdaterService`（Sparkle 2 自动更新薄封装，2026-09-18 加，菜单「检查更新…」与设置 ›「通用」的「更新」区块共用；详见「发布到 GitHub」一节）、`PageRenderEngine`/`PageLayout`/`PageBitmap`（v2 渲染管线）、`InkEdit`（笔迹纯函数：局部擦除切段/平移/缩放/尺子吸附/自由框选多边形命中，**`splitStroke` 与 web 端 JS 版同算法两份实现，改它必须同步另一边**，测试 `spike/ink-edit-test.swift`）、`InkUndo`+`DocSession+InkUndo`（编辑撤销栈：**增量**记账、瞬态不落库、页内与草稿纸各一条；连续擦除并成一步，抬笔封口）、`InkPaste`（粘贴的摆放数学，纯函数：Mac 本机 ⌘V 与平板 `clip paste` 共用一份）、`InkClipboard`（笔迹剪贴板，系统 `NSPasteboard` 自有类型，条目编码复用落库 payload；两者测试 `spike/ink-undo-test.swift`）、`InkWindow`（笔迹**按页窗口**装载/淘汰的纯函数：`session.strokes` 只是已装载页的集合，整篇操作问库，见 `INK-PAGING-PLAN.md §9`；测试 `spike/ink-window-test.swift`）。笔迹点 `InkPoint = SIMD3<Float>`，「存 Float、算 Double」
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
- `Sources/Reader/` — 阅读区（AppKit）：`ReaderView`（主类：输入量、状态、实化页、图层池）+ 扩展 `Render`（出图调度 / 贴片 / 夜间）、`Zoom`（⌘滚轮 / 捏合 / 缩放动画 / 换基准）、`Follow`（滚动回报 + 平板跟随，`ScrollFollower` 由 `NSView.displayLink` 驱动）、`Canvas`（画板页边）、`Marks`（坐标换算 + 标记层刷新）、`Overlay`（图钉 / 气泡 / 橡皮圈 / 提示条）、`Input`（鼠标按指针工具分派 + 键盘 + 拖放）、`TextSelect`、`Lasso`、`Actions`（批注 / 高亮 / 图片笔记 / 书签 / 草稿纸入口）、`Menus`（右键菜单与高亮气泡）、`Snip`（⌥ 拖截图）；`ReaderScrollView`（居中 clip view + ⌘滚轮 + 翻转文档视图）、`ReaderLayers` / `PageMarksLayer`（每页图层树，全部无隐式动画）、`InkRenderCG`（四种笔型的 CoreGraphics 画法）、`ReaderSupportTypes`（选择 / 框选 / 批注草稿 / 菜单命令通知等纯数据）。子目录：`Pane/`（阅读窗格 `ReaderPaneController`：阅读区 + 查找条 + 标签栏 + 笔架 + 草稿纸 + 浮层的装配与摆位）、`Ref/`（参考窗页流）、`Rack/`（笔架 + 图层面板）、`Scratch/`（草稿纸）。本机指针工具 = `AppModel.pointerTool`（textSelect/ink/lasso/snip，设备级全局，笔架切换）
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
- 关键坑（Markdown 引擎的 `onLinkClick` **只捕获一次**，2026-09-20 实测）：`NativeTextViewWrapper`
  在 `makeCoordinator()` 里把它存进协调器，而 `updateNSView` 刷新了另外五个回调（`onCaretRectChange` /
  `onBuildContextMenu` / `onInlineSelectionChange` / `onInlinePreviewKey` / `onCodeBlockSelectionChange`）
  **唯独不刷新它**。所以绝不能「先传个空闭包占位、建完 `NSHostingView` 再换 `rootView`」——首次渲染只要
  发生在换之前，协调器就永久攥着那个空闭包，点链接静悄悄什么都不发生。做法见 `MarkdownDocView.LinkRelay`：
  传一个**身份固定**的中转闭包进去，目标随后再填。
- 关键坑：退出收缩逻辑用 `AppDelegate.applicationShouldTerminate` 置 `isTerminating` 守卫（窗口在 ⌘Q 时也会走关闭路径）。
- 关键坑（设置页的开关/下拉「点了没反应」，2026-09-21 用户报）：`Sources/Settings/` 里的每一项**必须绑到
  SwiftUI 自己的状态**（`@AppStorage` / `@State` / `@ObservedObject`）。拿 `Binding(get:set:)` 包一个
  静态属性（`BackupService.enabled` 那种本机全局设置）看着能跑，实则 body 里没有任何 SwiftUI 状态被读到
  → 选完不重算 → 控件立刻按旧值画回去。要跑副作用（重建定时器之类）用 `.onChange`，别写进 Binding 的 setter。
- 关键坑（`@Published` 在 `willSet` 发出）：AppKit 这边用 Combine 订阅模型时，回调里读到的还是旧值——一律 `.receive(on: DispatchQueue.main)` 推到下一拍再读，多个来源的刷新合并成一次（`queueRefresh` 那种写法）。
- OCR 文本层：消费方（选择/复制/⌘A/OCR 搜索/分组/调试上色）一律走 `DocSession.ocrVisibleRuns(page:)`——它已滤掉扫描件的平铺水印块（`OCRWatermark`，几何 + 跨页重复判定，不认具体文字）；`ocrRuns` 是真源，只给落库与建指纹用，**别直接消费**（`ocrGroups` 的下标是按可见行算的，混用即错位）。
- 扫描页对齐（`SCAN-ALIGN-PLAN.md`）：纯逻辑 `App/ScanAlign`（变换 / 参数表 / 测量 / 定中心，spike `scan-align-test.swift`；真 PDF 出对比图用 `scan-align-real.swift`）+ `App/ScanAlignRunner`（多份 `PDFDocument` 并行测全书）。🔴 **「页面」在开着对齐时就是对齐后的那张**：`PageBitmap.displaySize/render/renderTile` 的 `align` 参数**刻意不给默认值**，新增出图口必须传 `session.pageAlign(i)`（漏一处就是那一处的页图和笔迹对不上）；页图缓存键 / 阅读区 `.id` / 平板 `layout.v` 一律用 `DocSession.displayKey`，别用 `contentHash`；与 PDF 原生页坐标互转（选字 / 搜索 / 目录）走 `PageGeometry` 带 `align` 的重载。开关切换 = 清这份内容的 OCR + 整篇重载（`DocTabModel.applyScanAlign`）
- 扫描页增强（2026-09-23 加，**只在出图时处理、不改 PDF**）：`App/ScanEnhance`（参数 + Core Image 滤镜链：降噪 → 估纸色 → 原图÷纸色 → 软色阶 → 轻锐化 / 去色，可选 2 倍超采样）+ `PageBitmap.renderEnhanced/renderTileEnhanced`（贴片外扩 `marginPt` 再裁回，防接缝）。开关**按内容哈希记在本机 UserDefaults**（「视图 › 增强扫描页」，不进库、不同步），参数在设置 ›「阅读」。缓存键在页号后插 `#e<参数签名>`（`PageRenderEngine.baseKey/tileKey` 的 `enhance`），**不动 `displayKey`**。🔴 本版**只作用于阅读区**（`ReaderView`）；参考窗 / 缩略图 / 草稿纸 / 平板 / MCP / OCR 仍是原图。参数一变屏幕上的旧图记进 `staleImages/staleTiles`，只替换不清空。🔴 **软色阶不能改回硬切**（`(x-lo)/(hi-lo)` 那种）：用户实测嫌颗粒感，根因就是字边灰度被切成非黑即白。样张 + 贴片一致性检查 `spike/scan-enhance-look.swift`；取舍与 AI 调研见 `SCAN-ENHANCE-PLAN.md`
- 关键坑（滚动条，2026-09-20 实测）：内容高度是**异步**变的（Markdown 排完版才报回来）时，滚动视图自己的 frame 没动就不会重排滚动条，竖滚动条会停在上一次的判断上（表现：拖宽面板后滚动条整个消失，改一下窗口大小又回来）。要它重新判断，**只能 `needsLayout = true` + `reflectScrolledClipView(_:)`**；🔴 **别手动调 `NSScrollView.tile()`**——那是给子类重写布局用的，外面调会把系统 overlay 滚动条的布局搅乱：knob 变成一小块方块卡在角上，竖的横的都一样。
- 关键坑（阅读区竖滚动条被页面盖住，2026-09-21 实测）：用户报「把右侧 Inspector 拖到最宽，阅读区竖滚动条就没了，滚轮滚也不回来，而且不是每次都出现」。滑块其实一直好好的（日志里 `可用=true`、矩形也对），是**不透明的页面画在它上面**——认这个病只看一处：**clip view 的 frame 是不是和滚动条叠在一起**（坏：`clip框(0,0 1200×907)` + `竖条框(1183,52 17×838)`；好：clip 是 `1183×890`）。两个成因各修各的：① **页宽不能拿 tile 之后的视口宽来算**——clip 宽是 AppKit 摆放滚动条的**结果**，页宽又是它的**输入**，fit 模式下「页宽 = 视口宽」把横滚动条卡在要不要出现的边界上，而「clip 占满整宽 + 页宽 = 整宽 + 竖条没有自己那一列」是个**自洽且稳定**的解，掉进去就出不来。`ReaderView.fitAvail` / `RefPageStreamView.availWidth` 一律按**滚动视图外框**减掉常驻滚动条那一列再留半点余量，与 tile 结果无关、与内容无关；滚动条样式变了（系统设置 / 插拔鼠标）要重排一次。② **拖分隔条 / 拖窗口期间 AppKit 不保证 tile**（有几帧自己又摆对了，所以时有时无），只能在**确实叠上时**叫一次 `tile()`（`ReaderView.retileIfScrollersOverlapContent`，实测全程 9000 多行日志只触发 5 次）——🔴 仅限常驻样式，覆盖式叠着是对的、也不能对它叫 `tile()`（见上一条）。排这类问题：`touch ~/Library/Logs/UniReader-scroller.log` 开 `ScrollerLog`（默认关，记 clip / 滚动条 / 滑块 / 分栏各格的完整几何）。
- 关键坑（换基准途中算出来的位置不作数，2026-09-21 实测）：`refit` / `rebase` / `applyZoom` 都是「先按新基准重排文档视图、再把画面钉回原处」，而改 `fitBasis` / `docView.frame` / `magnification` 每一步都会**同步**触发 clip view 的 bounds 通知 → `maybeEmit()` 拿**新基准**解读**还没校正的旧滚动偏移**，算出一个离谱的页码当成「用户滚动到这里」上报并**存进阅读进度**（实测：窗口宽 1385→1085 时，真实 p88 被报成 p112，画面随后钉回 p88 而库里那条错的没人纠正 → 切走再回来就落在 p112）。各处 `suppressEmitUntil` 是**重排做完之后**才设的，挡不住这中间的自发上报，所以有 `ReaderView.relayouting` 这道门；新增任何「重排 + 钉回」的事务都要包上它。查阅读进度的问题别再猜，`touch ~/Library/Logs/UniReader-progress.log` 开 `ProgressLog`（`[PROG]`，覆盖全部会改 `document.read_*` 的路径，含离线镜像合并那条）。
- 关键坑（`NSStackView` 增量重排 + 约束激活顺序，2026-09-21 实测）：Agent 面板的对话记录**不能每次刷新都把整排视图拆下来再装回去**——`NSStackView` 每增删一个 arranged subview 都要重建一整串间距 / 对齐约束，而流式回复每个碎片都来一次，于是「回答长了就卡」。做法是先算出这排视图应该是什么样，再只动第一处不一样的位置往后那一段（`AgentChatNSView.applyTranscriptViews`），最常见的情况（最后一条又长了一段、就地换文字）一动不动；标题行 / 提示条 / 权限卡片 / 输入区那两个下拉菜单同样「值变了才重建」。🔴 **新建的条目视图必须先进 stack 再激活宽度约束**：约束两端要有共同祖先，刚建出来的视图还没有父视图，当场激活是 `NSGenericException` +「进程 abort」（改对了顺序才不崩；那次一点历史对话就崩）。另外这排视图变了要叫一次滚动条重算（见上一条），**面板尺寸变了也要**——正文没重排就没人报高度，滚动条会停在上次的判断上。🔴 **尺寸连着变（拖分隔条 / 拖窗口）的整个过程里这块面板停住不动**（用户 2026-09-21 定：「拖拽过程中不更新 UI，直到松手后再重新布局对话流」）：`layout` 里发现距上次尺寸变化不到 120ms 就直接不摆位、起一只表等停手，停手后 `finishResize` 按新尺寸摆位 → 叫每条正文 `flushNow()` 立刻重排（不等它自己那 150ms 防抖）→ 重算滚动条；停住期间内容还是旧宽度，所以面板要 `clipsToBounds`。排滚动条的问题别再猜，`touch ~/Library/Logs/UniReader-agent-scroll.log` 开几何打点（`AgentScrollLog`，默认关）。离屏验证 `spike/agent-transcript-test.swift`（42 项：增量结果、零操作、约束只加一次、约束激活顺序）。
- 关键坑（子视图看不见也在布局，2026-09-20 实测）：`InspectorViewController.viewDidLayout` 给**每一页**（含隐藏的）设 frame，拖分隔条时逐帧来一遍。页里挂了重排代价大的东西（Markdown 引擎、TextKit 2）就必须自己挡：看不见（`window == nil || isHiddenOrHasHiddenAncestor`）时只攒不排，`viewDidUnhide` / `viewDidMoveToWindow` 时补；宽度变化一律防抖到停手再排。
- 关键坑（Tahoe 工具栏胶囊合并规则，2026-07-28 实测）：`ToolbarItemGroup` 里**只有连续的纯图标 Button（Image label）才会被系统合并渲染成单一玻璃胶囊分段组**；掺一个 `Text` label（如 `1:1`）整组立刻散成独立圆钮。`ControlGroup` 在 Tahoe 工具栏里反而不分组（同样拆成独立圆钮），别再用它做工具栏分组。相邻两组想分成两个胶囊，中间插 `ToolbarSpacer()`，否则 Tahoe 会把相邻 item 粘进同一胶囊。
- 关键坑（玻璃工具栏按钮变浅，2026-09-19 录屏实测，macOS 27）：**别去改阅读区滚动视图的外框宽度**（比如并排一块面板让它变窄）——每改一次，内容区上方那几组玻璃工具栏按钮就被系统重判一次深浅、整几组变浅（拖窗口、开合 Inspector 都不会）。（那次是 SwiftUI 时代并排一块内置 AI 面板的情形；2026-09-20 Inspector 改真分栏后，开合同样在改外框宽度，实测**没有**复现变浅。）另：`refreshToolbarStates` 这类跟着会话每次变化跑的刷新，给工具栏 item 写值一律「值变了才写」。
