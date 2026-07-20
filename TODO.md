# UniReader TODO

> 规划与待办清单。规格见 `REQUIREMENTS.md`，进度见其第 6 节。

## 🧭 当前状态速览（交接用）

- 工程 xcodegen 管理：改文件后 `xcodegen generate`（新增文件时必做）→ `xcodebuild -project UniReader.xcodeproj -scheme UniReader -destination 'platform=macOS' build CODE_SIGNING_ALLOWED=NO`。非沙盒，**macOS 26+（Tahoe，不做低版本兼容）**。
- **已完成**：hash 去重入库、PDFKit 阅读、多窗口 + App 级共享 WS（`AppModel`/`DocSession`）、二维码配对、采集页（压感/防误触/合批/侧键 PageUp 切模式·PageDown 切笔/全屏/WS 延迟/文档下拉）、**S3 实时渲染**（平板 `ink`/`erase` → Mac `InkOverlayView`）、**方案 B**：桌面 `PadRenderer`（fit-width 连续布局）+ **模拟平板窗口**（滚轮连续滚动 + 鼠标当笔，走共用落墨 API）、锚点同步 **sim↔Mac 双向已通**。
- **注意（2026-07-20 更新）**：真平板已接入方案 B（连续多页 + 双向锚点 + 按需取图 `/page.png?i=N` + 双指缩放 + 惯性 + hover 传 Mac + 夜间模式 + 手写板模式 + 锁缩放 + 防误触）；采集页 HTML 已独立为 `Sources/Resources/capture.html`（不再内嵌 Swift 字符串，避免转义坑）；Mac 端滚动**平滑跟随**（`PDFKitView` 用 CADisplayLink 按刷新率临界阻尼低通逼近最新锚点，过滤 WiFi 突发抖动，**只跟随不预测**）；PDF 显示已用原生 `PDFKitView` 重建（复刻 Preview）。参数（缩放 catchup、惯性衰减、防误触阈值等）待真机手感微调。
  - **2026-07-20 修复：滚动跟随的"闪回/撤回"**。原「延迟补偿」用锚点到达时刻估速再外推（dead-reckoning），但 WiFi 成批投递 → `Δtarget/Δarrival` 得到荒谬瞬时速度 → 停手/换向时过冲后回弹＝用户看到的闪回+撤回。改为**去掉速度外推**，纯临界阻尼低通（`smCurrent += (smTarget-smCurrent)*catchup`），输出恒为凸组合、目标单调则绝不过冲。合成锚点流实测（`swift spike/scroll-follow-sim.swift`）：外推版过冲 3 页撞顶、方向反转 13 次、单帧跳 1.35 页；修复版过冲 0、反转 0、单帧 0.076 页。
  - **2026-07-20 加入（保留待真机 A/B）：时间戳插值跟随**。采集页 `scroll` 带发送端 `performance.now()`（`t`，ms）；`ScrollAnchor.senderT` 贯通；`PDFKitView.Coordinator` 双模式共用一个 displayLink——**平板路径**（`senderT>0`）估掉平板↔Mac 时钟差（最小延迟滤波），把样本按发送端戳落到本地时间轴，渲染落后 `interpDelay`（默认 **0.08s**，唯一旋钮）做线性插值，越过末样本则保持（**不外推**）；**本地 sim/mac**（无戳）退回纯低通。桌面浏览器滚轮测试(另一台电脑)走的就是平板路径 → 能测到插值。⚠️ **模拟结论：LAN 条件下插值并未胜过纯低通**（`swift spike/scroll-follow-interp-sim.swift`：恶劣 WiFi 下 低通 单帧 0.103/滞后 0.275 vs 插值 0.160/0.295，均零过冲零反转）——要吸收 80ms 成批就得延后 ≥80ms > 低通 ~45ms 时间常数。插值的理论优势（滞后与速度无关、精确跟速）需**持续高速 fling** 或**真实成批很小**才显现，故留待真机手感定夺。嫌重可整套回退到纯低通。

## ⏭️ 接下来（建议顺序）

1. **真平板接入方案 B**：`PadRenderer` 条带流转给真平板 + 平板回传滚动/落墨（缓冲本地滚动 + progressive 多清晰度）。
2. **S5 长按切笔手势**：重压+静止 >300ms 在 Mac 笔尖处显进度环，>2s 呼出切笔工具（Mac 笔尖处），那一笔预测性清除。
3. **笔迹持久化**：落库 SwiftData `Note`（hash+page+归一化锚点+笔画序列化），重开恢复。

## 🐞 已知 Bug（待修）

（暂无）

## ✅ 已结论的布局问题（2026-07-19）

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
- **待补**：① 旧 SwiftData 数据不迁移（需重新导入）；② 手写笔迹真正落 `note` 表（表已就绪，payload=JSON 序列化 InkStroke）；③ 合并的「拆分」逆操作暂无。

## 📋 Backlog（M3 及之后）

- **笔记持久化**：把 overlay 笔迹落库到 `note` 表（kind=2，payload=JSON 序列化 InkStroke；document + page + 归一化锚点），重开自动恢复。（表已就绪，见工作区 §8）
- **三种笔记形态**：文字注解、会话笔记（预留 AI）、手写笔记的编辑 UI 与渲染。
- **文件重定位**：所有路径失效时提示重新关联；hash 变化时提示重关联、保留旧笔记。
- **配对/安全**：二维码 UI 打磨；token 准入已做，考虑连接管理（踢除、显示已连设备）。
- **笔工具**：切笔工具的笔列表可配置（颜色/粗细/荧光笔/橡皮）。
- **性能**：大文件 hash 缓存 `(path,size,mtime)→hash`；页图渲染移出主线程 / 懒渲染窗口。
- **打包**：非沙盒 + 公证发布流程。
