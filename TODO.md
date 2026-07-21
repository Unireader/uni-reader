# UniReader TODO

> 规划与待办清单。规格见 `REQUIREMENTS.md`，进度见其第 6 节。

## 🧭 当前状态速览（交接用）

- 工程 xcodegen 管理：改文件后 `xcodegen generate`（新增文件时必做）→ `xcodebuild -project UniReader.xcodeproj -scheme UniReader -destination 'platform=macOS' build CODE_SIGNING_ALLOWED=NO`。非沙盒，**macOS 26+（Tahoe，不做低版本兼容）**。
- **已完成**：hash 去重入库、多窗口 + App 级共享 WS（`AppModel`/`DocSession`）、二维码配对、采集页（压感/防误触/合批/侧键 PageUp 切模式·PageDown 切笔/全屏/WS 延迟/文档下拉）、**S3 实时渲染**（平板 `ink`/`erase` → Mac 墨迹叠加）、**方案 B**：桌面 `PadRenderer`（fit-width 连续布局）+ **模拟平板窗口**（滚轮连续滚动 + 鼠标当笔，走共用落墨 API）、锚点同步 **sim↔Mac 双向已通**、**Mac 阅读区自研页图流 v2（`PageStreamView`，纯 SwiftUI，Preview 级指标，2026-07-20 重写完成待真机验证，见 `PDF-VIEWER-REBUILD-PLAN.md`）**、**文字搜索/选择/OCR 预留架构已落地**（`PageText.swift`+`OCR.swift`+`ocr_page` 表 v3，见 `TEXT-SEARCH-OCR-PLAN.md`）。
- **⚠️ 阅读区 v1 已被用户删除（缩放跳位/闪烁不达标）**；v2 于 2026-07-20 按五条硬指标（主线程零渲染/预缓存/pinch 锚定/resize 不跳/任何情况零闪烁）重新设计并实现：设计+机制映射+spike 实测结论全在 `PDF-VIEWER-REBUILD-PLAN.md`。**红线：阅读区纯 SwiftUI，严禁 AppKit 视图（含 NSViewRepresentable 包 NSScrollView）**（用户 2026-07-20 明确否决 AppKit 路线）。
- **注意（2026-07-20 更新）**：真平板已接入方案 B（连续多页 + 双向锚点 + 按需取图 `/page.png?i=N` + 双指缩放 + 惯性 + hover 传 Mac + 夜间模式 + 手写板模式 + 锁缩放 + 防误触）；采集页 HTML 已独立为 `Sources/Resources/capture.html`（不再内嵌 Swift 字符串，避免转义坑）；Mac 端滚动**平滑跟随**（跟随器用 CADisplayLink 按刷新率临界阻尼低通逼近最新锚点，过滤 WiFi 突发抖动，**只跟随不预测**；已从旧 `PDFKitView.Coordinator` 移植进独立的 `ScrollFollower`）；**PDF 显示已换成自研页图流 `PageStreamView`（SwiftUI `ScrollView` + 按页渲染图，`PDFKitView`/`InkOverlayView` 已删）**。参数（缩放 catchup、惯性衰减、防误触阈值等）待真机手感微调。
  - **2026-07-20 修复：滚动跟随的"闪回/撤回"**。原「延迟补偿」用锚点到达时刻估速再外推（dead-reckoning），但 WiFi 成批投递 → `Δtarget/Δarrival` 得到荒谬瞬时速度 → 停手/换向时过冲后回弹＝用户看到的闪回+撤回。改为**去掉速度外推**，纯临界阻尼低通（`smCurrent += (smTarget-smCurrent)*catchup`），输出恒为凸组合、目标单调则绝不过冲。合成锚点流实测（`swift spike/scroll-follow-sim.swift`）：外推版过冲 3 页撞顶、方向反转 13 次、单帧跳 1.35 页；修复版过冲 0、反转 0、单帧 0.076 页。
  - **2026-07-20 加入（保留待真机 A/B）：时间戳插值跟随**。采集页 `scroll` 带发送端 `performance.now()`（`t`，ms）；`ScrollAnchor.senderT` 贯通；`PDFKitView.Coordinator` 双模式共用一个 displayLink——**平板路径**（`senderT>0`）估掉平板↔Mac 时钟差（最小延迟滤波），把样本按发送端戳落到本地时间轴，渲染落后 `interpDelay`（默认 **0.08s**，唯一旋钮）做线性插值，越过末样本则保持（**不外推**）；**本地 sim/mac**（无戳）退回纯低通。桌面浏览器滚轮测试(另一台电脑)走的就是平板路径 → 能测到插值。⚠️ **模拟结论：LAN 条件下插值并未胜过纯低通**（`swift spike/scroll-follow-interp-sim.swift`：恶劣 WiFi 下 低通 单帧 0.103/滞后 0.275 vs 插值 0.160/0.295，均零过冲零反转）——要吸收 80ms 成批就得延后 ≥80ms > 低通 ~45ms 时间常数。插值的理论优势（滞后与速度无关、精确跟速）需**持续高速 fling** 或**真实成批很小**才显现，故留待真机手感定夺。嫌重可整套回退到纯低通。

## ⏭️ 接下来（建议顺序）

0. ✅ **Mac 阅读区页图流 v2（2026-07-20 重写完成，编译通过 + spike 全绿，待用户真机手感验证）**：纯 SwiftUI（`PageStreamView` + `PageLayout` + `PageBitmap` + `PageRenderEngine` + tick 版 `ScrollFollower`）。关键机制均 spike 实测钉死：同 runloop「改布局+scrollTo」屏幕原子（pinch commit 不闪）、`page.draw` 自带旋转、自研虚拟化（内容尺寸精确，滚动条不漂）、resize 冻结+稳定后单次原子 refit。**用户自测**：pinch 锚定/⌘±/⌘0、窗口缩放与侧栏开合（fit 贴合=行为②，放大态被侧栏盖=行为③）、SimPad↔Mac 锚点、墨迹/hover/夜间/进度、玻璃观感。详见 `PDF-VIEWER-REBUILD-PLAN.md` 顶部「✅ 状态」块。
0b. **📖 文字搜索 / 文字选择 / 扫描版 OCR（架构已预留，见 `TEXT-SEARCH-OCR-PLAN.md`）**：统一「页面文本层」`PageTextLayer`（native | ocr 同一模型）；`ocr_page` 缓存表(v3) + `OCRProvider` 可插拔（系统 Vision / 用户配 API）+ provider 协议骨架均已落。按 T1(原生文本+选择)→T2(搜索)→T3(OCR) 实现，接手无需再定架构。OCR 结果进工作区库、provider 配置进 UserDefaults。
1. **真平板接入方案 B**：`PadRenderer` 条带流转给真平板 + 平板回传滚动/落墨（缓冲本地滚动 + progressive 多清晰度）。
2. **S5 长按切笔手势**：重压+静止 >300ms 在 Mac 笔尖处显进度环，>2s 呼出切笔工具（Mac 笔尖处），那一笔预测性清除。
3. ✅ **笔迹持久化（2026-07-20 完成）**：落 `note` 表（kind=2，一笔=一行；`note.id==stroke.id`、page/anchor 走列、payload=JSON `{color:{r,g,b,a},width,points:[[x,y,pressure]]}`），重开恢复。**弃 SwiftData，走工作区 SQLite `note` 表**（跨平台）。详见下方「✅ 手写笔迹持久化」。

## 🐞 已知 Bug（待修）

（暂无）

### 已修（2026-07-21，第二批：交互/工程/设置）

- **切换文件后阅读区空白、须拖窗口才显示**（`PageStreamView`）：切文档 `.id(docKey)` 重建 `ScrollView`，`onScrollGeometryChange` 在容器尺寸与旧文档相同时不重发首帧几何 → `didInitialGeo` 卡 false → 首屏只画 10×10 空白。修法：`geometryChanged` 在 scroll 几何缺席（`containerW≤0`）时用外层 GeometryReader 的 `unobSize` 兜底填容器尺寸（**仅供实化窗口/偏移，绝不参与宽度/fit 决策**，不违反宽度反馈环红线）；`onAppear`(layout 就绪)/`fullWidth` onChange/`unobSize` onChange **三路兜底 bootstrap**，谁最后到位谁触发，不再单靠 onScrollGeometryChange。日志 `[RD] bootstrap ... via scrollGeo|unobSize`。
- **双指缩放只在 PDF 页上生效、页外空白不缩放**：`magnify` 手势从内容 ZStack 移到 `ScrollView` 容器（整个阅读区可捏合：页间空隙/末页下方/zoom<1 两侧留白）；`pinchChanged` 锚点从「内容坐标」改「容器/视口坐标 P，c=offset+P」，与 ⌘滚轮 `zoomCommit(anchorP:)` 及 `onContinuousHover(.local)` 同坐标系。
- **每次重编译反复弹「下载」目录 TCC 授权**：ad-hoc 签名 cdhash 每次变 → TCC 当新 App 重新弹。修法：`project.yml` 固定 `DEVELOPMENT_TEAM: T8F5T6HKG8`（zqsd 团队，含 Developer ID，后续公证复用）→ TCC 按 Team+BundleID(designated requirement) 记账，授权一次永久生效。zqsd 本机暂无 Apple Development 证书，Xcode 自动签名会按需创建；报错则回退手动 Developer ID 签名。
- **cmd+w 关闭的 PDF 从「下次启动恢复组」被移除**：`open_documents` 改为 MRU「最近打开」（前=最近，cap 10，去重）。打开/切换置顶并持久化；**cmd+w 只解绑窗口不移除**（`closeWindow` 仅动 `windowDocs`）；仅「删除/合并文档」才 `forgetRecent` 剔除。`restoreSession` 最近的进主窗口、其余**最多再开 4 窗**（防最近列表长时弹一堆窗口）。**旧 `AppDelegate.isTerminating`/`applicationShouldTerminate` 防退出收缩机制已删**（MRU 语义下不需要）。
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
- **多窗口 + 会话恢复（2026-07-20）**：方案 2（多个完整工作区窗口，⌘N）+ 侧栏右键「在新窗口打开」（`WindowGroup(id:"docWindow", for:String)` + `openWindow(value:)`）。打开文档集实时存 `meta.open_documents`（JSON，随文件夹走）；启动首窗恢复整组（其余各开一窗，`AppModel.didRestoreInitial` 防重复）。**（2026-07-21 更新）** `open_documents` 已改为 **MRU「最近打开」** 语义（前=最近，cap 10）：打开/切换置顶，**cmd+w 不移除**（下次仍恢复），仅删除/合并才剔除；`restoreSession` 恢复窗口上限 5（主窗口+4）。旧的 `AppDelegate.isTerminating`/`applicationShouldTerminate` 防退出收缩机制已删（MRU 下不需要）。`AppModel`/`WorkspaceManager` App 级单例，全窗口共享 WS/LANServer，平板跟随激活窗口；**单实例 last-wins**（新进程终止旧进程接管，见「已修 2026-07-21」）。
- **待补**：① 旧 SwiftData 数据不迁移（需重新导入）；② ✅ 手写笔迹已落 `note` 表（见下方专节）；③ 合并的「拆分」逆操作暂无；④ meta 里 `last_document_id` 是旧单文档设计的残留键（已弃用不读，无害）。

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

- ✅ **手写笔迹持久化**（2026-07-20 完成，见上「✅ 手写笔迹持久化」专节）。文字注解 / 会话笔记的落库与编辑 UI 仍待做（`note` kind=0/1）。
- **三种笔记形态**：文字注解、会话笔记（预留 AI）、手写笔记的编辑 UI 与渲染。
- **文件重定位**：所有路径失效时提示重新关联；hash 变化时提示重关联、保留旧笔记。
- **配对/安全**：二维码 UI 打磨；token 准入已做，考虑连接管理（踢除、显示已连设备）。
- **笔工具**：切笔工具的笔列表可配置（颜色/粗细/荧光笔/橡皮）。
- **性能**：大文件 hash 缓存 `(path,size,mtime)→hash`；页图渲染移出主线程 / 懒渲染窗口。
- **打包**：非沙盒 + 公证发布流程。
