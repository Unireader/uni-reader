# AGENTS.md — UniReader

macOS 26+ PDF 阅读器（非沙盒，Tahoe 专属，不做低版本兼容）。Swift 5 / SwiftUI / xcodegen 管理。

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

- **唯一的第三方包**：`swift-markdown-engine`（SPM，`project.yml` 里 `exactVersion` 钉死；只取核心产品 `MarkdownEngine`，
  零外部依赖）——笔记编辑器 sheet 用它（`MarkdownNoteEditor`），**不进阅读区**。包解析落在 `build/dev/SourcePackages/`，
  新克隆或 `rm -rf build` 之后首次编译要先 `xcodebuild … -derivedDataPath build/dev -resolvePackageDependencies`
  （联网拉包 = 装依赖，**按用户规矩给命令让用户跑**，别自己跑）。升版本只改 `project.yml` 再解析。
- 无测试 target；验证走 spike 脚本：`swift spike/<name>.swift`（如 `store-test.swift` 32 项 DAO、`ink-store-test.swift` 21 项）。
- 采集页前端（`web/`，Svelte + Vite）：改动后跑 `scripts/build-web.sh`（npm install + 单文件构建 + 占位符自检 + 覆盖 `Sources/Resources/capture.html`），再重新编译 App。`capture.html` 是构建产物、**不入 git**——新克隆先跑一次 `build-web.sh`；`scripts/package.sh` 打包时会自动重建。
- 项目级用户规则：不代用户执行安装（brew/pip/npm 一律给脚本让用户跑）；交流用中文或英文。
- Android 端（`android/`）：构建 `cd android && ./gradlew assembleDebug`，打包 `android/pack.sh`。**其余规则、结构与坑全在 `android/AGENTS.md`（改安卓代码前先读它），本文件不再重复。**

## 文档地图（改代码前先读）

- `TODO.md` — 交接状态速览 + 待办 + 已知坑，**第一优先**（只留进行中/待办）
- `HISTORY.md` — 已完成事项归档；**TODO 里的条目做完即迁移到这里**
- `REQUIREMENTS.md` — 需求与 §8 工作区持久化方案
- `PDF-VIEWER-REBUILD-PLAN.md` — 阅读区 v2（`PageStreamView`）的五条硬指标与零闪烁纪律
- `REF-WINDOW-PLAN.md` — 参考窗（只读浮窗，各端）：一句话定义 + 被砍清单 + 三端落地要点
- `OFFLINE-MIRROR-PLAN.md` — 工作区离线镜像（Mac + 安卓模式1）：整份复制到本机、离线写笔迹、接回硬盘三方合并
- `APPKIT-WINDOW-PLAN.md` — 窗口层迁到 AppKit（壳归 AppKit / 内容仍 SwiftUI，2026-09-01 拍板，进行中）
- `INK-PAGING-PLAN.md` — 笔迹内存：点压到 f32 + 按页窗口加载/淘汰（**`session.strokes` 不再是全集**；2026-09-10 已落地，§9 是落地记录，改笔迹代码前先读）
- `PROTOCOL.md` — 二进制线格式**唯一契约**（Mac / web / 安卓三端字节级一致），改协议先改它
- `MCP-PLAN.md` — MCP 服务（给外部 Agent 用，App 内置 HTTP 端点，默认回环、可绑所有接口+口令）：分批工具目录、协议层、线程红线、写入策略（2026-09-13 方案已拍板，未动代码）
- `IMAGE-NOTE-PLAN.md` — 图片笔记（note kind=6 + `image` 表 v13 + `Images/`）：内容寻址、引用计数数出来、待删除 30 天、⌥⇧ 拖节选、离线镜像 additive 通道（2026-09-13 Mac 端已落地）
- **`android/AGENTS.md`** — 安卓端（两种模式）的构建、结构、红线与坑；**动安卓代码只需读它 + 上面的跨端契约**

### 子目录可以自带 AGENTS.md（`android/` 就是这么做的）

`android/` 是**独立 git 仓库**（根仓库 `.gitignore` 忽略了它，安卓改动在那边单独提交），所以安卓端的规则
**写在 `android/AGENTS.md` 里**（`android/CLAUDE.md` 是它的软链，与根目录同款约定），跟着安卓仓库一起走；
根目录这份只留一句引用，不复制内容——**同一条规则只在一处维护**，避免两边各改一半互相矛盾。

新增其他子工程（如将来的 Windows 端）照此办理：子目录自己写 `AGENTS.md` + `CLAUDE.md` 软链，
根目录在「文档地图」加一行指过去。跨端契约（`PROTOCOL.md`、schema、跨平台方案文档）仍留在根目录，
子目录用 `../` 相对路径引用，别在子目录里复制一份。

## 红线（用户明确否决过，勿重走）

- 阅读区**纯 SwiftUI**，严禁 AppKit 视图（含 NSViewRepresentable 包 NSScrollView / PDFView）。v1 因缩放跳位/闪烁已被用户删除。
  **唯一例外（用户 2026-09-13 拍板）**：笔记气泡里的正文用 `swift-markdown-engine` 只读渲染（`MarkdownNoteReader`，
  `isEditable: false`、`.fitsContent`、外观钉死浅色）——限定在气泡正文那一块，滚动/缩放面本身仍是 SwiftUI，别往外扩。
- UI 外观**严禁自绘仿系统样式**（用户 2026-07-25 明确否决）：分组/胶囊这类系统观感只能用系统标准 API（如 `ControlGroup`），系统渲染成什么样就什么样；做不到就保持系统默认，不要自己画。
- **material / 玻璃底上的文字与按钮别用 `.secondary` / `.borderless`**：系统会把它们画得极淡，
  表现是「元素还在、就是看不见」。已踩两次——2026-08-07 草稿纸工具条的非激活按钮、2026-09-01
  AI 内置面板 header 里绑定的文档名与页码。层级差异改用**字号**表达，颜色一律显式 `.primary`。
- **显示页图的窗口 `colorSpace` 必须与页图色彩空间一致**（页图 = sRGB，`ReaderWindowController`/`RefWindowController`
  都设 `win.colorSpace = .sRGB`；2026-09-13 实测定）：不一致时 SwiftUI 显示每张 `Image(decorative:)` 都要 CA 用 CG
  整张重画转色 → 每张页图三份（mmap + CA 副本 + CG 转换缓存），连平板滚 10 秒就多 600MB。新开一种带页图的窗口照此设。
- 存储**弃用 SwiftData**，用工作区 SQLite（`Sources/Store/`，系统 libsqlite3、零第三方依赖，跨平台 payload 用显式 JSON 数组）。
- 代码库**禁用单轴 `scrollTo(x:)`/`scrollTo(y:)`**（后写覆盖前写、未指定轴归零，spike 实测），一律 `scrollTo(point:)`。
- 滚动跟随**只跟随不预测**：纯临界阻尼低通，禁速度外推（WiFi 成批投递导致过冲闪回，已修过一次）。
- 重建 PDF 显示前必须先与用户确认方案，不要自行动手。

## 结构要点

- `Sources/App/` — App 级单例：`AppModel`/`DocSession`（多窗口共享 WS/LANServer）、`WorkspaceManager`（工作区 = `.unrd` 包：UTI 声明在 `Sources/Info.plist`，旧无扩展名工作区首启原地改名迁移、工作区改名联动改包名；双击/拖 Dock 由 `AppDelegate.openFile` → 通知路由到 key 窗口）、`PageRenderEngine`/`PageLayout`/`PageBitmap`（v2 渲染管线）、`InkEdit`（笔迹纯函数：局部擦除切段/平移/缩放/尺子吸附/自由框选多边形命中，**`splitStroke` 与 web 端 JS 版同算法两份实现，改它必须同步另一边**，测试 `spike/ink-edit-test.swift`）、`InkUndo`+`DocSession+InkUndo`（编辑撤销栈：**增量**记账、瞬态不落库、页内与草稿纸各一条；连续擦除并成一步，抬笔封口）、`InkPaste`（粘贴的摆放数学，纯函数：Mac 本机 ⌘V 与平板 `clip paste` 共用一份）、`InkClipboard`（笔迹剪贴板，系统 `NSPasteboard` 自有类型，条目编码复用落库 payload；两者测试 `spike/ink-undo-test.swift`）、`InkWindow`（笔迹**按页窗口**装载/淘汰的纯函数：`session.strokes` 只是已装载页的集合，整篇操作问库，见 `INK-PAGING-PLAN.md §9`；测试 `spike/ink-window-test.swift`）。笔迹点 `InkPoint = SIMD3<Float>`，「存 Float、算 Double」
- `Sources/Server/` — LAN WS 服务、二维码配对、UDP RT 上行（`UDPTransport` + 纯逻辑 `UDPReorder`，契约 `PROTOCOL.md §6`）
- `web/` — 平板采集页前端工程（Svelte 5 + Vite + TypeScript，`vite-plugin-singlefile` 单文件构建）。`Sources/Resources/capture.html` 是它的**构建产物，勿手改**；源在 `web/src/`（`App/TopBar/StatsPanel/PenStat/TextNoteEditor.svelte`（文字笔记编辑器）+ `lib/`：shared 状态袋与公式（含 `GState` 等共享类型）/ hud.svelte.ts 响应式 HUD / render / input / ws / capture 装配）。占位符 `__WS_PORT__`/`__TOKEN__`/`__PENS__` 在 `web/index.html` 内联脚本里（不过 bundler），由 `CapturePage.swift` 运行时替换；`wire.js` 协议编解码器由 `web/src/lib/wire.ts` 直接 import `Sources/Resources/wire.js`（单一真源，勿复制）构建期内联。
- `Sources/Views/` — `ContentView`（body 拆 `mainSplit` + `eventRoutes` 两段——修饰符链挂一个表达式会超类型检查器时限，与 `toolbarContent` 抽出同款）；阅读区 v2 拆分为 `PageStreamView`（外壳 + `ReaderSurface` 主体）+ `ReaderSurface+Scroll/Render/Selection/Zoom/Lasso/InkClip`（六个扩展：滚动几何与跟随 / 渲染调度与贴片 / 文字选择与注解+本机落墨手势 / 缩放与事件监视 / 框选——自由路径框选+移动+角手柄缩放+选中笔迹光晕 / 选中集的剪切复制粘贴删除+撤销入口）+ `PageStreamSupport`（GeoSnap/Scratch 等支持类型）+ `PageCellView`/`InkLayers`/`RadialMenuView`（页元胞/墨迹层/环形选笔盘）；`ScrollFollower`。本机指针工具 = `AppModel.pointerTool`（textSelect/ink/lasso，设备级全局，笔架切换）
- 关键坑：`onDisappear` 在 Cmd-Q 也触发 → 退出收缩逻辑用 `AppDelegate.applicationShouldTerminate` 置 `isTerminating` 守卫；NSViewRepresentable 存储属性不变会跳过 `updateNSView`，需把变化值显式传入。
- OCR 文本层：消费方（选择/复制/⌘A/OCR 搜索/分组/调试上色）一律走 `DocSession.ocrVisibleRuns(page:)`——它已滤掉扫描件的平铺水印块（`OCRWatermark`，几何 + 跨页重复判定，不认具体文字）；`ocrRuns` 是真源，只给落库与建指纹用，**别直接消费**（`ocrGroups` 的下标是按可见行算的，混用即错位）。
- 关键坑（Tahoe 工具栏胶囊合并规则，2026-07-28 实测）：`ToolbarItemGroup` 里**只有连续的纯图标 Button（Image label）才会被系统合并渲染成单一玻璃胶囊分段组**；掺一个 `Text` label（如 `1:1`）整组立刻散成独立圆钮。`ControlGroup` 在 Tahoe 工具栏里反而不分组（同样拆成独立圆钮），别再用它做工具栏分组。相邻两组想分成两个胶囊，中间插 `ToolbarSpacer()`，否则 Tahoe 会把相邻 item 粘进同一胶囊。
