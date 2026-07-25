# AGENTS.md — UniReader

macOS 26+ PDF 阅读器（非沙盒，Tahoe 专属，不做低版本兼容）。Swift 5 / SwiftUI / xcodegen 管理。

## 构建与验证

```bash
xcodegen generate   # 新增/删除源文件后必做；UniReader.xcodeproj 是生成物，勿手改
xcodebuild -project UniReader.xcodeproj -scheme UniReader -destination 'platform=macOS' build CODE_SIGNING_ALLOWED=NO
```

- 无测试 target；验证走 spike 脚本：`swift spike/<name>.swift`（如 `store-test.swift` 32 项 DAO、`ink-store-test.swift` 21 项）。
- 项目级用户规则：不代用户执行安装（brew/pip/npm 一律给脚本让用户跑）；交流用中文或英文。

## 文档地图（改代码前先读）

- `TODO.md` — 交接状态速览 + 已知坑，**第一优先**
- `REQUIREMENTS.md` — 需求与 §8 工作区持久化方案
- `PDF-VIEWER-REBUILD-PLAN.md` — 阅读区 v2（`PageStreamView`）的五条硬指标与零闪烁纪律

## 红线（用户明确否决过，勿重走）

- 阅读区**纯 SwiftUI**，严禁 AppKit 视图（含 NSViewRepresentable 包 NSScrollView / PDFView）。v1 因缩放跳位/闪烁已被用户删除。
- 存储**弃用 SwiftData**，用工作区 SQLite（`Sources/Store/`，系统 libsqlite3、零第三方依赖，跨平台 payload 用显式 JSON 数组）。
- 代码库**禁用单轴 `scrollTo(x:)`/`scrollTo(y:)`**（后写覆盖前写、未指定轴归零，spike 实测），一律 `scrollTo(point:)`。
- 滚动跟随**只跟随不预测**：纯临界阻尼低通，禁速度外推（WiFi 成批投递导致过冲闪回，已修过一次）。
- 重建 PDF 显示前必须先与用户确认方案，不要自行动手。

## 结构要点

- `Sources/App/` — App 级单例：`AppModel`/`DocSession`（多窗口共享 WS/LANServer）、`WorkspaceManager`、`PageRenderEngine`/`PageLayout`/`PageBitmap`（v2 渲染管线）
- `Sources/Server/` — LAN WS 服务、二维码配对、`capture.html`（采集页，独立文件勿内嵌 Swift 字符串）、UDP RT 上行（`UDPTransport` + 纯逻辑 `UDPReorder`，契约 `PROTOCOL.md §6`）
- `Sources/Views/` — `ContentView`、`PageStreamView`、`ScrollFollower`
- 关键坑：`onDisappear` 在 Cmd-Q 也触发 → 退出收缩逻辑用 `AppDelegate.applicationShouldTerminate` 置 `isTerminating` 守卫；NSViewRepresentable 存储属性不变会跳过 `updateNSView`，需把变化值显式传入。
