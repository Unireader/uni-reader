# AGENTS.md — UniReader

macOS 26+ PDF 阅读器（非沙盒，Tahoe 专属，不做低版本兼容）。Swift 5 / SwiftUI / xcodegen 管理。

## 构建与验证

```bash
xcodegen generate   # 新增/删除源文件后必做；UniReader.xcodeproj 是生成物，勿手改
xcodebuild -project UniReader.xcodeproj -scheme UniReader -destination 'platform=macOS' build CODE_SIGNING_ALLOWED=NO
```

- 无测试 target；验证走 spike 脚本：`swift spike/<name>.swift`（如 `store-test.swift` 32 项 DAO、`ink-store-test.swift` 21 项）。
- 采集页前端（`web/`，Svelte + Vite）：改动后跑 `scripts/build-web.sh`（npm install + 单文件构建 + 占位符自检 + 覆盖 `Sources/Resources/capture.html`），再重新编译 App。`capture.html` 是构建产物、**不入 git**——新克隆先跑一次 `build-web.sh`；`scripts/package.sh` 打包时会自动重建。
- 项目级用户规则：不代用户执行安装（brew/pip/npm 一律给脚本让用户跑）；交流用中文或英文。
- Android 端（`android/`，Gradle 工程，wrapper 已补齐）：构建 `./gradlew assembleDebug`；打包 `android/pack.sh`（release，adb 恰好一台设备时顺带安装，`--debug`/`--no-install`）。签名：debug/release 共用 `~/.keystores/xVanTuring.jks`（alias `key0`），密码从 `android/local.properties` 的 `releaseStorePassword`/`releaseKeyPassword` 读（本机文件，不入 git）。

## 文档地图（改代码前先读）

- `TODO.md` — 交接状态速览 + 待办 + 已知坑，**第一优先**（只留进行中/待办）
- `HISTORY.md` — 已完成事项归档；**TODO 里的条目做完即迁移到这里**
- `REQUIREMENTS.md` — 需求与 §8 工作区持久化方案
- `PDF-VIEWER-REBUILD-PLAN.md` — 阅读区 v2（`PageStreamView`）的五条硬指标与零闪烁纪律

## 红线（用户明确否决过，勿重走）

- 阅读区**纯 SwiftUI**，严禁 AppKit 视图（含 NSViewRepresentable 包 NSScrollView / PDFView）。v1 因缩放跳位/闪烁已被用户删除。
- UI 外观**严禁自绘仿系统样式**（用户 2026-07-25 明确否决）：分组/胶囊这类系统观感只能用系统标准 API（如 `ControlGroup`），系统渲染成什么样就什么样；做不到就保持系统默认，不要自己画。
- 存储**弃用 SwiftData**，用工作区 SQLite（`Sources/Store/`，系统 libsqlite3、零第三方依赖，跨平台 payload 用显式 JSON 数组）。
- 代码库**禁用单轴 `scrollTo(x:)`/`scrollTo(y:)`**（后写覆盖前写、未指定轴归零，spike 实测），一律 `scrollTo(point:)`。
- 滚动跟随**只跟随不预测**：纯临界阻尼低通，禁速度外推（WiFi 成批投递导致过冲闪回，已修过一次）。
- 重建 PDF 显示前必须先与用户确认方案，不要自行动手。

## 结构要点

- `Sources/App/` — App 级单例：`AppModel`/`DocSession`（多窗口共享 WS/LANServer）、`WorkspaceManager`（工作区 = `.unrd` 包：UTI 声明在 `Sources/Info.plist`，旧无扩展名工作区首启原地改名迁移、工作区改名联动改包名；双击/拖 Dock 由 `AppDelegate.openFile` → 通知路由到 key 窗口）、`PageRenderEngine`/`PageLayout`/`PageBitmap`（v2 渲染管线）、`InkEdit`（笔迹纯函数：局部擦除切段/平移/尺子吸附，**与 web 端 JS 版同算法两份实现，改一边必须同步另一边**，测试 `spike/ink-edit-test.swift`）
- `Sources/Server/` — LAN WS 服务、二维码配对、UDP RT 上行（`UDPTransport` + 纯逻辑 `UDPReorder`，契约 `PROTOCOL.md §6`）
- `web/` — 平板采集页前端工程（Svelte 5 + Vite + TypeScript，`vite-plugin-singlefile` 单文件构建）。`Sources/Resources/capture.html` 是它的**构建产物，勿手改**；源在 `web/src/`（`App/TopBar/StatsPanel/PenStat/TextNoteEditor.svelte`（文字笔记编辑器）+ `lib/`：shared 状态袋与公式（含 `GState` 等共享类型）/ hud.svelte.ts 响应式 HUD / render / input / ws / capture 装配）。占位符 `__WS_PORT__`/`__TOKEN__`/`__PENS__` 在 `web/index.html` 内联脚本里（不过 bundler），由 `CapturePage.swift` 运行时替换；`wire.js` 协议编解码器由 `web/src/lib/wire.ts` 直接 import `Sources/Resources/wire.js`（单一真源，勿复制）构建期内联。
- `Sources/Views/` — `ContentView`（body 拆 `mainSplit` + `eventRoutes` 两段——修饰符链挂一个表达式会超类型检查器时限，与 `toolbarContent` 抽出同款）；阅读区 v2 拆分为 `PageStreamView`（外壳 + `ReaderSurface` 主体）+ `ReaderSurface+Scroll/Render/Selection/Zoom/Lasso`（五个扩展：滚动几何与跟随 / 渲染调度与贴片 / 文字选择与注解+本机落墨手势 / 缩放与事件监视 / 框选移动）+ `PageStreamSupport`（GeoSnap/Scratch 等支持类型）+ `PageCellView`/`InkLayers`/`RadialMenuView`（页元胞/墨迹层/环形选笔盘）；`ScrollFollower`。本机指针工具 = `AppModel.pointerTool`（textSelect/ink/lasso，设备级全局，笔架切换）
- 关键坑：`onDisappear` 在 Cmd-Q 也触发 → 退出收缩逻辑用 `AppDelegate.applicationShouldTerminate` 置 `isTerminating` 守卫；NSViewRepresentable 存储属性不变会跳过 `updateNSView`，需把变化值显式传入。
- 关键坑（Tahoe 工具栏胶囊合并规则，2026-07-28 实测）：`ToolbarItemGroup` 里**只有连续的纯图标 Button（Image label）才会被系统合并渲染成单一玻璃胶囊分段组**；掺一个 `Text` label（如 `1:1`）整组立刻散成独立圆钮。`ControlGroup` 在 Tahoe 工具栏里反而不分组（同样拆成独立圆钮），别再用它做工具栏分组。相邻两组想分成两个胶囊，中间插 `ToolbarSpacer()`，否则 Tahoe 会把相邻 item 粘进同一胶囊。
