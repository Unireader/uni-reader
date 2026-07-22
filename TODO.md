# UniReader TODO

> 规划与待办清单。规格见 `REQUIREMENTS.md`，进度见其第 6 节。

## 🧭 当前状态速览（交接用）

- 工程 xcodegen 管理：改文件后 `xcodegen generate`（新增文件时必做）→ `xcodebuild -project UniReader.xcodeproj -scheme UniReader -destination 'platform=macOS' build CODE_SIGNING_ALLOWED=NO`。非沙盒，**macOS 26+（Tahoe，不做低版本兼容）**。
- **已完成**：hash 去重入库、多窗口 + App 级共享 WS（`AppModel`/`DocSession`）、二维码配对、采集页（压感/防误触/合批/侧键 PageUp 切模式·PageDown 切笔/全屏/WS 延迟/文档下拉）、**S3 实时渲染**（平板 `ink`/`erase` → Mac 墨迹叠加）、**方案 B**：桌面 `PadRenderer`（fit-width 连续布局）+ **模拟平板窗口**（滚轮连续滚动 + 鼠标当笔，走共用落墨 API）、锚点同步 **sim↔Mac 双向已通**、**Mac 阅读区自研页图流 v2（`PageStreamView`，纯 SwiftUI，Preview 级指标，2026-07-20 重写完成待真机验证，见 `PDF-VIEWER-REBUILD-PLAN.md`）**、**文字选择/全文搜索已完成**（T1+T2，2026-07-21，选择走 PDFKit 原生选择引擎 `PageGeometry.swift`+`TextSearch.swift`），**OCR 已接 Paddle PP-OCRv6 API**（T3，2026-07-21，`PaddleOCR.swift`；逐页按需 + 手动全量，结果覆盖不准的原生文本做选择/复制/搜索；系统 Vision provider 仍是空骨架）。
- **⚠️ 阅读区 v1 已被用户删除（缩放跳位/闪烁不达标）**；v2 于 2026-07-20 按五条硬指标（主线程零渲染/预缓存/pinch 锚定/resize 不跳/任何情况零闪烁）重新设计并实现：设计+机制映射+spike 实测结论全在 `PDF-VIEWER-REBUILD-PLAN.md`。**红线：阅读区纯 SwiftUI，严禁 AppKit 视图（含 NSViewRepresentable 包 NSScrollView）**（用户 2026-07-20 明确否决 AppKit 路线）。
- **注意（2026-07-20 更新）**：真平板已接入方案 B（连续多页 + 双向锚点 + 按需取图 `/page.png?i=N` + 双指缩放 + 惯性 + hover 传 Mac + 夜间模式 + 手写板模式 + 锁缩放 + 防误触）；采集页 HTML 已独立为 `Sources/Resources/capture.html`（不再内嵌 Swift 字符串，避免转义坑）；Mac 端滚动**平滑跟随**（跟随器用 CADisplayLink 按刷新率临界阻尼低通逼近最新锚点，过滤 WiFi 突发抖动，**只跟随不预测**；已从旧 `PDFKitView.Coordinator` 移植进独立的 `ScrollFollower`）；**PDF 显示已换成自研页图流 `PageStreamView`（SwiftUI `ScrollView` + 按页渲染图，`PDFKitView`/`InkOverlayView` 已删）**。参数（缩放 catchup、惯性衰减、防误触阈值等）待真机手感微调。
  - **2026-07-20 修复：滚动跟随的"闪回/撤回"**。原「延迟补偿」用锚点到达时刻估速再外推（dead-reckoning），但 WiFi 成批投递 → `Δtarget/Δarrival` 得到荒谬瞬时速度 → 停手/换向时过冲后回弹＝用户看到的闪回+撤回。改为**去掉速度外推**，纯临界阻尼低通（`smCurrent += (smTarget-smCurrent)*catchup`），输出恒为凸组合、目标单调则绝不过冲。合成锚点流实测（`swift spike/scroll-follow-sim.swift`）：外推版过冲 3 页撞顶、方向反转 13 次、单帧跳 1.35 页；修复版过冲 0、反转 0、单帧 0.076 页。
  - **2026-07-20 加入（保留待真机 A/B）：时间戳插值跟随**。采集页 `scroll` 带发送端 `performance.now()`（`t`，ms）；`ScrollAnchor.senderT` 贯通；`PDFKitView.Coordinator` 双模式共用一个 displayLink——**平板路径**（`senderT>0`）估掉平板↔Mac 时钟差（最小延迟滤波），把样本按发送端戳落到本地时间轴，渲染落后 `interpDelay`（默认 **0.08s**，唯一旋钮）做线性插值，越过末样本则保持（**不外推**）；**本地 sim/mac**（无戳）退回纯低通。桌面浏览器滚轮测试(另一台电脑)走的就是平板路径 → 能测到插值。⚠️ **模拟结论：LAN 条件下插值并未胜过纯低通**（`swift spike/scroll-follow-interp-sim.swift`：恶劣 WiFi 下 低通 单帧 0.103/滞后 0.275 vs 插值 0.160/0.295，均零过冲零反转）——要吸收 80ms 成批就得延后 ≥80ms > 低通 ~45ms 时间常数。插值的理论优势（滞后与速度无关、精确跟速）需**持续高速 fling** 或**真实成批很小**才显现，故留待真机手感定夺。嫌重可整套回退到纯低通。

## ⏭️ 接下来（建议顺序）

0. ✅ **Mac 阅读区页图流 v2（2026-07-20 重写完成，编译通过 + spike 全绿，待用户真机手感验证）**：纯 SwiftUI（`PageStreamView` + `PageLayout` + `PageBitmap` + `PageRenderEngine` + tick 版 `ScrollFollower`）。关键机制均 spike 实测钉死：同 runloop「改布局+scrollTo」屏幕原子（pinch commit 不闪）、`page.draw` 自带旋转、自研虚拟化（内容尺寸精确，滚动条不漂）、resize 冻结+稳定后单次原子 refit。**用户自测**：pinch 锚定/⌘±/⌘0、窗口缩放与侧栏开合（fit 贴合=行为②，放大态被侧栏盖=行为③）、SimPad↔Mac 锚点、墨迹/hover/夜间/进度、玻璃观感。详见 `PDF-VIEWER-REBUILD-PLAN.md` 顶部「✅ 状态」块。
0b. **📖 文字搜索 / 文字选择（T1+T2）/ OCR（T3，Paddle PP-OCRv6）——均 2026-07-21 完成，编译通过**：详见下方「✅ T1/T2」「✅ T3 OCR」。**用户自测**：① 拖选文字（跨行/跨页）→ ⌘C 复制核对；⌘F 查找边打字边高亮跳转、↑↓/回车切换、关栏清高亮；换文档查找栏清空。② OCR：设置(⌘,)选 Paddle 填 key → 工具栏 `text.viewfinder` 开「用 OCR 文字」→ 滚动看哪页处理哪页 / 「识别全部页」→ 在不准的 PDF 上拖选复制核对是否变准。
1. **真平板接入方案 B**：`PadRenderer` 条带流转给真平板 + 平板回传滚动/落墨（缓冲本地滚动 + progressive 多清晰度）。
2. **S5 长按切笔手势**：重压+静止 >300ms 在 Mac 笔尖处显进度环，>2s 呼出切笔工具（Mac 笔尖处），那一笔预测性清除。
3. ✅ **笔迹持久化（2026-07-20 完成）**：落 `note` 表（kind=2，一笔=一行；`note.id==stroke.id`、page/anchor 走列、payload=JSON `{color:{r,g,b,a},width,points:[[x,y,pressure]]}`），重开恢复。**弃 SwiftData，走工作区 SQLite `note` 表**（跨平台）。详见下方「✅ 手写笔迹持久化」。

## 🐞 已知 Bug（待修）

（暂无）

### 已修（2026-07-21，第二批：交互/工程/设置）

- **切换文件后阅读区空白、须拖窗口才显示**（`PageStreamView`）：切文档 `.id(docKey)` 重建 `ScrollView`，`onScrollGeometryChange` 在容器尺寸与旧文档相同时不重发首帧几何 → `didInitialGeo` 卡 false → 首屏只画 10×10 空白。修法：`geometryChanged` 在 scroll 几何缺席（`containerW≤0`）时用外层 GeometryReader 的 `unobSize` 兜底填容器尺寸（**仅供实化窗口/偏移，绝不参与宽度/fit 决策**，不违反宽度反馈环红线）；`onAppear`(layout 就绪)/`fullWidth` onChange/`unobSize` onChange **三路兜底 bootstrap**，谁最后到位谁触发，不再单靠 onScrollGeometryChange。日志 `[RD] bootstrap ... via scrollGeo|unobSize`。
- **双指缩放只在 PDF 页上生效、页外空白不缩放**：`magnify` 手势从内容 ZStack 移到 `ScrollView` 容器（整个阅读区可捏合：页间空隙/末页下方/zoom<1 两侧留白）；`pinchChanged` 锚点从「内容坐标」改「容器/视口坐标 P，c=offset+P」，与 ⌘滚轮 `zoomCommit(anchorP:)` 及 `onContinuousHover(.local)` 同坐标系。
- **每次重编译反复弹「下载」目录 TCC 授权**：ad-hoc 签名 cdhash 每次变 → TCC 当新 App 重新弹。修法：`project.yml` 固定 `DEVELOPMENT_TEAM: T8F5T6HKG8`（zqsd 团队，含 Developer ID，后续公证复用）→ TCC 按 Team+BundleID(designated requirement) 记账，授权一次永久生效。zqsd 本机暂无 Apple Development 证书，Xcode 自动签名会按需创建；报错则回退手动 Developer ID 签名。
- **会话恢复 = 「打开集」语义（2026-07-21 重做，修「启动开一堆」）**：`open_documents` **不再是累积 MRU**（旧 MRU 只增不减、cap 10，每次启动重开 5 个→用户报「始终开很多文件」）。改为 **`openDocs` = 当前所有窗口的文档**（`= Set(windowDocs.values)`，去重保序）：`setWindowDoc` → `syncOpenDocs` 重同步（窗口里切文档，旧文档不再被任何窗口显示就退出打开集 → 不累积）；**cmd+w** `closeWindow` 逐个移除该窗口文档，**但**①退出中(`AppDelegate.isTerminating`)不动 ②关最后一个窗口不动（保留最后一本）。**`AppDelegate.isTerminating` 重新加回**（`applicationShouldTerminate` 在关窗前置位）用于区分 cmd+q（全恢复）vs cmd+w（逐个移除）。历史膨胀列表在**首次启动**由 `syncOpenDocs` 自动收敛到真正开出来的窗口。`restoreSession` 仍主窗口+最多再开 4 窗（安全上限，正常用不到，因打开集≈实际窗口数）。
- **单实例（last-wins）**：`AppDelegate.applicationWillFinishLaunching` 检测同 bundle 其它进程 → 优雅 `terminate()` 旧实例并接管（释放 8770/8771 端口，保证 Xcode Run 永远看到最新构建、旧进程即便没被回收也清掉）。正式发布如需「第二次打开只激活已有窗口」再切 first-wins。
- **标准设置页（⌘,）**：新增 `Settings` 场景 + `SettingsView`（双语，`@AppStorage` 持久化），三项：① 自动夜间模式（跟随系统深色，`ContentView` 监听 `colorScheme`）；② 延迟处理方式（插值/低通 Picker，复用既有 `scrollInterp`，与工具栏 A/B 按钮同 key 双向同步）；③ 启动自动开平板服务（勾选即启、启动即 `server.start()`）。

### 已修（2026-07-20，阅读区 v2）

- **切换侧栏触发内容放大/缩小**：原 fit 模式侧栏开合会整页 refit。改为**侧栏/Inspector 开合零视觉变化**（只重定标 fitBasis/zoom，页面允许被玻璃盖住、可横向拖出）；仅窗口宽度真变（含 legacy 滚动条出现/消失）才触发 fit 锚定 refit。行为②按用户新要求更新（见 REQUIREMENTS §0）。
- **鼠标接入（legacy 占空间滚动条）时关侧栏后水平滚动条常驻**：fit 宽原不含 legacy 竖滚动条占位 → 恒差 ~16pt。修法：fit 基准 = 未遮宽 − `NSScroller.scrollerWidth`（overlay=0，鼠标插拔经 `preferredScrollerStyleDidChange` 刷新）+ **fit 状态只声明垂直滚动轴**（`pageW ≤ 未遮宽` 时不声明 `.horizontal`）。
- **回归「一直在放大」（2026-07-21，上一条的首版修复引入，真机日志实锤后重写）**：曾把 `ScrollGeometry.containerSize` 当宽度真相源——实测它在 ignoresSafeArea + 动态轴下**跟随 contentW+17pt**（非独立视口测量，contentInsets 恒 0），内容宽由它推导 = 闭环互抬每帧 +17 无限放大。**铁律：阅读区宽度输入必须全部与内容无关（GeometryReader + NSScroller 系统度量）；ScrollGeometry 只用于 offset/可见区**。窗口缩放 vs 侧栏开合用双 GeometryReader（全宽 vs 未遮宽）判别；开合已验证 pageW 全程不变（零视觉变化）。

- **放大出水平滚动条后跳到最左 + 闪烁；滚动条松手才出现**。根因两个：
  ① `ScrollPosition` 单轴 `scrollTo(x:)`/`scrollTo(y:)` 是「后写覆盖前写 + 未指定轴重置为 0」（`spike/scroll-x-probe.swift` T1/T4 实测）→ commit 里 x 请求丢失；**修法：全代码库禁用单轴 scrollTo，一律 `scrollTo(point:)`**（两轴同写 + 同 transaction 改尺寸超旧范围也原子生效，T3b）。
  ② pinch 放大原为「视觉变换、松手才真 commit」→ 布局不变，滚动条松手才出现；**修法：pinch 双向统一逐帧真 commit**（同 runloop 原子已被 atomic-commit-probe 证明）。

## ✅ 已结论的布局问题（2026-07-19）

> **2026-07-20 现状**：阅读区已按 `PDF-VIEWER-REBUILD-PLAN.md` 重建为自研页图流 `PageStreamView`（SwiftUI `ScrollView` + 页图）。本节是**重建前的排查历史**（PDFView 时代的坑），红线（严禁非原生味 hack / 严禁再套 PDFView + ignoresSafeArea 等）**仍然有效**，勿重走。

- **[布局] PDF 显示实现已整体移除（2026-07-19，用户指示"全部删除不要再实现"）**：`PDFKitView.swift` 已删；`ContentView` 保留原生框架（玻璃侧栏 NavigationSplitView + `.inspector` 笔记占位 + 工具栏）与文档加载（`session.pdf`，模拟平板/真平板渲染不受影响），阅读区暂为占位。**重建 PDF 显示前必须先与用户确认方案，不要自行动手。**
  - 重建目标行为（用户三次确认）：① 侧栏叠加在 PDF 上（玻璃虚化真实内容）；② fit 时开侧栏页面挤到右侧可见区居中；③ 手动放大后允许被侧栏覆盖。
  - **红线：严禁任何非原生味的写法**。已试并被否/失败的路线：ZStack 仿侧栏（丑）、`.prominentDetail`+全边 ignoresSafeArea（内容整体左移一个侧栏宽度）、普通三栏（两侧不透明）、`backgroundExtensionEffect`（镜像反射非真内容）、嵌入式 NSSplitViewController + `automaticallyAdjustsSafeAreaInsets`（SwiftUI 窗口内不生效，需作窗口根控制器）、contentInsets + 各种归位/闭环校正（页面总差一个左 inset 或宽度异常）。
  - 排查方法论备忘：布局 bug 用临时分布式通知钩子 + 几何日志实测（详见 memory）；注意 `layout()` 不触发 ≠ 视图没动（frame 原点平移不走 layout），要监控页面矩形 `convert(page.bounds, from: page)`。

## 🚧 进行中 / 下一步

- ✅ **S3 实时渲染**（已完成首版）：平板 `ink`/`erase` → `AppModel` 路由到 padSession → `InkOverlayView` 叠加在 PDFView 上渲染（压感变宽 + 笔色 + 擦除），随缩放/滚动重绘对齐。待调优：线宽标定、擦除粒度、高频消息性能。
- **S2b 连续滚动（方案 B：桌面权威流转）**：
  - ✅ `PadRenderer` + 模拟平板窗口（桌面连续滚动 + 鼠标当笔，已能测）。
  - ✅ 锚点同步 **sim→Mac**（连续镜像：Mac 视口顶部对齐锚点）。
  - ✅ 锚点同步 **Mac→sim**（已修）。根因：`SimPadRepresentable` 的存储属性（`app`/`session` 引用 + `tick`）在锚点变化时全都不变，SwiftUI 视图值比较判定"没变"直接跳过 `updateNSView`，sim 侧永远收不到锚点；笔迹能同步正是因为 `tick` 变了。修法：把 `scrollAnchor` 作为存储属性传入 representable。顺带加固：`PDFKitView.updateNSView` 里刷新 `coordinator.parent = self`。
  - ⬜ 把 `PadRenderer` 条带流转给真平板：缓冲本地滚动、progressive 多清晰度、平板回传滚动/落墨坐标。
- **S5 长按切笔手势**：笔重压 + 静止 >300ms 在 **Mac 笔尖处**显示圆形进度环，>2s 呼出**切笔工具**（Mac 笔尖处）；那一笔预测性立即清除（不等 300ms）。

## ✅ 工作区文件夹持久化（2026-07-20 首版完成，见 REQUIREMENTS §8）

- **决策**：因**确定要做 Windows/Android 版**，存储改用**自有 schema 的跨平台 SQLite**（`<工作区>/UniReader/library.sqlite`，系统 libsqlite3、无第三方依赖），**弃用 SwiftData**。
- **已实现（schema v2）**：`Sources/Store/`（`SQLite.swift` + `LibraryModels.swift` + `LibraryStore.swift`：建表/迁移/多 hash `findOrCreate`/`mergeDocument`/`addVariant`/`add·removeLocation`/`updateProgress`/notes CRUD）；`WorkspaceManager`（工作区 + 最近 + 导入 + 探测路径优先工作区副本 + 进度 + 复制/移出工作区 + 重定位 + 合并）；SwiftData 整套移除；默认工作区自动建。
- **UI 已加**：侧栏工作区切换 + **重命名**；文档右键 **复制到工作区 / 从工作区删除**、**关联为同一文档**（合并带确认）；路径失效 **重新关联文件** 提示；**阅读进度**自动记录 + 重开恢复。
- **运行时验证**：建库/schema/meta/WAL、`sqlite3` 直读、**v1→v2 迁移**、**32/32 DAO 测试**（`spike/store-test.swift`）。
- **多窗口 + 会话恢复（2026-07-20）**：方案 2（多个完整工作区窗口，⌘N）+ 侧栏右键「在新窗口打开」（`WindowGroup(id:"docWindow", for:String)` + `openWindow(value:)`）。打开文档集实时存 `meta.open_documents`（JSON，随文件夹走）；启动首窗恢复整组（其余各开一窗，`AppModel.didRestoreInitial` 防重复）。**（2026-07-21 更新）** `open_documents` = **当前所有窗口的文档集**（`openDocs`/`syncOpenDocs`，见上「会话恢复=打开集语义」）：cmd+w 逐个移除、最后一个窗口/cmd+q 退出不移除（`AppDelegate.isTerminating` 区分）；`restoreSession` 恢复窗口上限 5（主窗口+4，安全上限）。`AppModel`/`WorkspaceManager` App 级单例，全窗口共享 WS/LANServer，平板跟随激活窗口；**单实例 last-wins**（新进程终止旧进程接管，见「已修 2026-07-21」）。
- **待补**：① 旧 SwiftData 数据不迁移（需重新导入）；② ✅ 手写笔迹已落 `note` 表（见下方专节）；③ 合并的「拆分」逆操作暂无；④ meta 里 `last_document_id` 是旧单文档设计的残留键（已弃用不读，无害）。

## ✅ T1/T2 文字选择 / 全文搜索（2026-07-21 完成）

- **T1 文字选择（2026-07-21 重做，弃自研词框排序，改 PDFKit 原生选择引擎）**：原生数字版 PDF 的选择
  **不再自研**——直接复用 `PDFDocument.selection(from:at:to:at:)`（与 PDFView 同引擎），可视阅读顺序、
  多栏/跨行/跨页、CJK 全由 PDFKit 负责，本层只做坐标进出。链路（`Sources/Views/PageStreamView.swift`）：
  拖选 `dragSelectGesture`（`DragGesture(minimumDistance:2)`，挂 ScrollView 容器、与 pinch 同 `.local` 坐标）
  → 起点/当前点经 `containerPointToPageSpace` 换成 PDF 页空间点（`PageGeometry.pageSpacePoint`，
  `normalizedRect` 的点级逆变换，越界按页边 clamp）→ `pdf.selection(from:at:to:at:)` 拿原生选区 →
  `PageGeometry.normalizedLineRects`（`selectionsByLine` 逐行框、同一套 rotation-aware 归一化）落成
  `TextSelection{rects:[page:[CGRect]], text}` → `PageCellView` 淡蓝 Canvas 画高亮（归一化随页尺寸自适应，
  缩放/滚动免重算）。**双击选词** `.onTapGesture(count:2)` → `PDFPage.selectionForWord`（光标位取自
  `.onContinuousHover` 维护的 `cursorP`）；**单击空白取消** `.onTapGesture(count:1)`（修掉旧实现「点空白
  不取消」——旧的 `minimumDistance:1` 拖选纯单击不触发、`onEnded` 清空逻辑根本不跑）；**⌘C** NSEvent 本地
  监视器直写 `NSPasteboard`（`selection.text`；`.onCopyCommand` 依赖 NSResponder 焦点链，纯 `ScrollView`
  容器拿不到焦点、⌘C 没反应）。**扫描页/OCR 页无原生文本 → 无选择**，留给 T3 走 `PageTextLayer`（`OCR.swift`）。
- **T2 全文搜索**：复用 PDFKit 内建 `PDFDocument.findString`（不重新实现词法扫描，跨行/跨页鲁棒），
  `TextSearch.find`（`Sources/App/TextSearch.swift`）→ `PageGeometry.normalizedLineRects` 逐行取框归一化。
  状态落 `DocSession`（`searchQuery`/`searchMatches`/`currentMatchIndex`，250ms 防抖，边打字边高亮+跳首个
  命中，类 Safari）。UI：工具栏放大镜 popover + ⌘F 菜单命令（`.readerFind` notification，与缩放命令同路由）。
  命中高亮：全部命中淡黄、当前命中橙色（`PageCellView` 同一 Canvas 机制）。
- **坐标真相源**：`Sources/App/PageGeometry.swift` —— `normalizedRect`（页空间→显示归一化，正变换）+
  `pageSpacePoint`（逆变换，选择用）+ `normalizedLineRects`（选区/命中共用行框）。搜索与选择共享同一套，
  避免两套坐标对不上。
- **为什么弃旧方案**：旧 T1 自己抽词框（`PageTextEngine` 缓存 `PageTextLayer` 词级 run）+ `geometricOrder`
  重排 + 按序位切片跨词选区。问题：① 选择粒度只能到「词」run（CJK 无空格退化成整行），起止不精确、观感乱；
  ② 几何行聚类对多栏/思维导图版面不稳，选区仍会东一块西一块；③ 纯单击不取消选择。PDFKit 原生选择引擎
  一次性解决全部，且与 T2 搜索同源。`PageTextEngine.swift` 已删；`PageText.swift` 回到桩（`TextRun`/
  `PageTextLayer` 仍作 T3 OCR 文本层「货币」保留，`OCR.swift` 依赖）。
- **已知待办**：
  - 旋转页（90/180/270）的坐标进出未用真实旋转 PDF 验证（`rotation=0` 是绝大多数文档、已确定正确，
    进/出用的是同一套逆/正变换、互为反函数）；找一份旋转 PDF 实测选区/搜索高亮是否对齐页面内容。
  - `PDFDocument.findString` 同步扫描，超大文档（几千页）搜索可能有感知延迟；已放到 `Task.detached`
    不卡 UI，真机验证够不够快，不够再换 PDFKit 渐进式 `beginFindString` 委托 API。
  - 拖到页边缘暂不自动滚动（PDFView 有）；跨页拖选需先滚到目标页再继续拖。非阻塞项。
  - 系统 Vision OCR（`VisionOCRProvider`）仍是空骨架（离线备选，未接）；`HTTPOCRProvider` 通用骨架未用（Paddle 走独立 `PaddleOCR.swift`）。

## ✅ T3 OCR（Paddle PP-OCRv6，2026-07-21 完成，编译通过）

- **动机**：用户实测——**原生 PDF 内嵌文本层本身不准**（错字漏字，坏 CMap/劣质旧 OCR），PDFKit 抽出来就是错的。
  接 Paddle 云 OCR 拿准确文本，覆盖原生文本做选择/复制/搜索。
- **模型 = PP-OCRv6**（用户选）：纯 OCR，返回逐行 `rec_texts` + 行框 `rec_boxes`（输入图像素坐标、左上原点）。
  行级框天然贴合可选/可搜文本层；VL-1.6 只给块级框（段落级）不适合选择，故不用。
- **客户端 `Sources/App/PaddleOCR.swift`**：异步 job——`POST /api/v2/ocr/jobs`(multipart 上传单页 PNG，`model`+`optionalPayload`
  两个 form 字段) → 轮询 `GET .../{jobId}` 到 `done`(2.5s 间隔，~5min 超时) → 下预签名 JSONL → 解析
  `result.ocrResults[].prunedResult.rec_texts`/`rec_boxes` → 按图宽高归一化成 `TextRun`(0~1 左上原点)、按 y→x 排阅读顺序。
  Auth `Authorization: bearer <key>`。**页图由 `PageBitmap.render` 出**（显示朝向、top-origin，与阅读区同款）→
  OCR 框和显示页天然同坐标系，**无需 rotation 变换**（比原生选择还省事）。
- **触发（用户要「手动 + 逐页按需」两种都要）**：
  - 逐页按需——`session.ocrEnabled` 时，阅读区 `updateRealized` 把**可见窗口**入队（「看到哪页处理哪页」）。
  - 手动全量——OCR 面板「识别全部页」`ocrAllPages()` 全量入队。
  - 编排在 `DocSession`：`ocrRuns[page]` / `ocrQueue`(@Published) / `ocrActivePages` / 并发上限 3 / `pumpOCR`。
    每页先查 `ocr_page` 缓存(命中秒回、不占网络槽)，miss 且已配 key 才排队跑网络；跑完回填缓存 + 刷 `ocrRuns`。
- **缓存**：`ocr_page(content_hash,page,provider="paddle-ppocrv6")`，payload=JSON `OCRPagePayload{w,h,runs}`。
  打开文档 `reloadOCRState()` 查 `ocrPageCount>0` → **自动启用**（换机/重开秒复用，无 key 也能用缓存做选择）。
  换文档旧任务回调靠 `contentHash==hash` 守卫整个丢弃（不动新文档计数器）。
- **选择/搜索集成（`PageStreamView`/`DocSession`）**：某页有 OCR 层就覆盖原生——
  拖选/双击在 OCR 页走**行级**选择（`setOCRSelection`/`ocrLineHit`，锚点→焦点按页号+行序切连续行，高亮行框+拼文本，
  ⌘C 得准确 OCR 文本）；原生页仍走 PDFKit 选择引擎。搜索 `ocrEnabled` 时搜 OCR 文本(`searchOCR`，行级命中)否则 findString。
- **设置/UI**：设置页(⌘,) OCR 段——引擎 Picker(关闭/Paddle) + `SecureField` key（存 UserDefaults：`ocrEngine`/`ocrPaddleKey`，
  含密钥不进工作区）。阅读区工具栏 `text.viewfinder` 图标 → OCR 面板：开关「用 OCR 文字」+ 进度(已识别 X/N、排队数) +
  「识别全部页」+ 错误提示；未配置 key 时引导去设置。
- **已知待办**：① 整文档识别是逐页 N 个 job（非整文件 1 job）——匹配「逐页按需」，大书 job 数多但增量可缓存/可续；
  需要再加「整文件一次上传」快路。② 拖选跨「OCR 页↔原生页」混合边界只做尽力(焦点页无 OCR 时冻结)；③ 搜索只覆盖
  已识别页（按需模型下未识别页搜不到，先跑 OCR 再搜）；④ 网络任务无取消（换文档靠 hash 守卫忽略，浪费但无害）；
  ⑤ Vision 离线 OCR 未接。

## ✅ 手写笔迹持久化（2026-07-20 完成）

- **模型**：一条笔画 = `note` 表一行，`kind=2`。`note.id = stroke.id.uuidString`（擦除 → `deleteNote(id:)` 一一映射）；`page` / `anchor`（点集**归一化**包围盒 0~1）走列；`payload` = 干净跨平台 JSON `{color:{r,g,b,a}, width, points:[[x,y,pressure]]}`（显式数组，非 SIMD 编码；Windows/Android 易读）。笔记挂**逻辑文档**（全 variant 共用），与阅读进度同源。
- **映射**：`Sources/App/InkModel.swift`——`InkColor: Codable`、`InkStroke.id` 改可赋值 `var`、`InkStroke.toNote(documentId:)` / `init?(note:)` / `normalizedBounds` / 私有 `InkStrokePayload`。
- **对账落库**（`ContentView`）：`.onChange(of: session.strokes)` → `persistInk()`——当前有而未落库 → upsert；曾落库而现已无（擦除）→ delete；用 `session.persistedStrokeIDs` 增量对账（liveStroke 变化**不**触发，仅完成/擦除才写）。
- **加载**：`loadSelected` → `loadInk(documentId:)` 恢复到 `session.strokes` 并置对账集（避免加载即被判「新增」重复写）；切文档/路径失效 → `clearInk()`（顺带修了旧 bug：换文档未清空内存笔迹）。`DocSession` 加 `documentId` + `persistedStrokeIDs`（非 @Published）。
- **落地即渲染**：`session.strokes.count` 变 → `inkTick` 变 → `PDFKitView` 刷 `InkOverlayView`；Inspector「笔记」页画笔区读同一 `session.strokes`，自动显示恢复的笔迹。
- **验证**：`spike/ink-store-test.swift`（21/21）——round-trip、note 列语义、payload JSON 形态、擦除删除、空笔画跳过、非 ink/损坏 payload 容错、多笔增量对账。App 整体 `xcodebuild` 通过。
- **待调**：擦除仅删内存对应笔画后异步删行（已覆盖）；大量笔画时 `notes(documentId:)` 全量读+client 端 filter kind==2，量大再加 `kind` 查询或分页。
- **UX 补充（2026-07-20）**：
  - **修 bug**：墨迹滚到顶部会从半透明工具栏透出、浮在标题栏上 → `InkOverlayView.draw` 用 `window.contentLayoutRect`（排除标题栏/工具栏）裁剪绘制。
  - Inspector 画笔区：每页一行**可点击跳转**（`onJumpTo(page, frac)`，frac 取该页最靠上笔迹）+ 尾部 **× 删本页手写**（移除内存笔画 → onChange 对账删 note）。
  - Inspector 文件区：每条 location 尾部 **× 删除**（`WorkspaceManager.deleteLocation`，工作区副本连文件删；**仅多于一项时可删**，至少保留一项）。

## 📋 Backlog（M3 及之后）

- ✅ **手写笔迹持久化**（2026-07-20）+ ✅ **文字注解 kind=0**（2026-07-21：选区右键加批注 / 点注解锚页面坐标 / 页面荧光高亮+图钉查看编辑 / Inspector 列表跳转删 / 落库对账）+ ✅ **文字高亮 kind=3**（2026-07-21：选区右键调色板一键上色 / 页面铺色 / Inspector 列表）。
- **三种笔记形态**：✅ 文字注解、✅ 手写笔记、✅ 高亮均已落地；**会话笔记（kind=1，预留 AI）** 用户 2026-07-21 明确暂不做（消息流 UI + 锚定 + AI 接口整套未起）。
- **文件重定位**：所有路径失效时提示重新关联（`missingDoc` + Re-link 已在）；hash 命中加路径 / 未命中作同文档新版本、笔记挂文档不丢（`relocate` 已较健壮）。**待补**：路径存在但内容变（同路径换内容）时的 hash 校验提示。
- ✅ **配对/安全 连接管理**（2026-07-21）：`LANServer.clientList`（地址+id）+ `kick(id)`，`ServerPanel` 列出已连平板逐个「断开」。二维码 UI 打磨仍可做。
- **笔工具**：✅ 笔预设可配置（2026-07-21：`PenPreset`/`PenPresets`，设置页编辑名字/颜色含透明度/粗细，注入采集页 `__PENS__` + SimPad 用第一支；荧光笔=半透明宽笔、橡皮独立擦除模式）。切笔工具 UI 打磨仍可做。
- **性能**：✅ 大文件 hash 缓存 `(path,size,mtime)→hash`（2026-07-21，`FileHasher.sha256Cached`）；✅ 页图缓存换自研 LRU（硬上限不机会性驱逐）+ 设置页可配上限（128M~2G，默认 512M）；懒渲染窗口已在（`PageRenderEngine` setWanted）。
- **打包**：非沙盒 + 公证发布流程。
- ✅ **保存/恢复 PDF 上次缩放 + 横向滚动**（2026-07-21）：schema v3→v5 加 `read_zoom`（相对 fit 倍率）+ `read_hfrac`（offsetX/pageW）；`DocSession.readZoom/restoreZoom/readHFrac/restoreHFrac`，`PageStreamView` 首帧套用，`ContentView` 进度保存带 zoom+hfrac。

### OCR 文字选择优化（2026-07-21）
- ✅ **选择「分组感知」**（`PageStreamView.ocrGroupSelection` + `DocSession.ocrGroups` 缓存）：只选锚点所在分组内、纵向落带内的行 → 与「可选分组」视图**同色块严格一致（所见即所选）**；单行横拖 fallback 线性（保页码）；跨页仍线性。
- ✅ **OCR 识别块调试可视化**（OCR 面板「显示识别块 · 每块独立/可选分组」）：`OCRFlow.columnGroups` 并查集列/块聚类。**可调旋钮**：分组间隙 1.2 行高 / 重叠 35%（同时驱动视图与选择）；单行 1.8 行高。
