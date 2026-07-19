# UniReader TODO

> 规划与待办清单。规格见 `REQUIREMENTS.md`，进度见其第 6 节。

## 🧭 当前状态速览（交接用）

- 工程 xcodegen 管理：改文件后 `xcodegen generate`（新增文件时必做）→ `xcodebuild -project UniReader.xcodeproj -scheme UniReader -destination 'platform=macOS' build CODE_SIGNING_ALLOWED=NO`。非沙盒，**macOS 26+（Tahoe，不做低版本兼容）**。
- **已完成**：hash 去重入库、PDFKit 阅读、多窗口 + App 级共享 WS（`AppModel`/`DocSession`）、二维码配对、采集页（压感/防误触/合批/侧键 PageUp 切模式·PageDown 切笔/全屏/WS 延迟/文档下拉）、**S3 实时渲染**（平板 `ink`/`erase` → Mac `InkOverlayView`）、**方案 B**：桌面 `PadRenderer`（fit-width 连续布局）+ **模拟平板窗口**（滚轮连续滚动 + 鼠标当笔，走共用落墨 API）、锚点同步 **sim↔Mac 双向已通**。
- **注意（2026-07-20 更新）**：真平板已接入方案 B（连续多页 + 双向锚点 + 按需取图 `/page.png?i=N` + 双指缩放 + 惯性 + hover 传 Mac + 夜间模式 + 手写板模式 + 锁缩放 + 防误触）；采集页 HTML 已独立为 `Sources/Resources/capture.html`（不再内嵌 Swift 字符串，避免转义坑）；Mac 端加了滚动**延迟补偿**（`PDFKitView` 用 CADisplayLink 按刷新率平滑跟随，过滤 WiFi 抖动）；PDF 显示已用原生 `PDFKitView` 重建（复刻 Preview）。参数（缩放 catchup、惯性衰减、防误触阈值等）待真机手感微调。

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

## 📋 Backlog（M3 及之后）

- **笔记持久化**：把 overlay 笔迹落库到 SwiftData `Note`（hash + page + 归一化锚点 + 笔画序列化），重开自动恢复。
- **三种笔记形态**：文字注解、会话笔记（预留 AI）、手写笔记的编辑 UI 与渲染。
- **文件重定位**：所有路径失效时提示重新关联；hash 变化时提示重关联、保留旧笔记。
- **工作区文件夹持久化**（替代分组，见 REQUIREMENTS §8，**动手前需与用户确认方案**）：一个可移动文件夹 = 一个工作区 = 一套 PDF；只存路径不存 PDF 本体；一个文档可配多文件/多 hash（加 TOC 致 hash 变仍视为同一文档）；配置 + 笔记存该文件夹，供两台电脑 / 未来独立 app 复用。原「分组」取消。
- **配对/安全**：二维码 UI 打磨；token 准入已做，考虑连接管理（踢除、显示已连设备）。
- **笔工具**：切笔工具的笔列表可配置（颜色/粗细/荧光笔/橡皮）。
- **性能**：大文件 hash 缓存 `(path,size,mtime)→hash`；页图渲染移出主线程 / 懒渲染窗口。
- **打包**：非沙盒 + 公证发布流程。
