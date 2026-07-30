# UniReader TODO

> 规划与待办清单。规格见 `REQUIREMENTS.md`，进度见其第 6 节。
> **已完成项全部归档在 `HISTORY.md`（2026-07-25 起，条目做完即迁移），本文件只留进行中/待办/交接状态。**

## 🧭 当前状态速览（交接用）

- 工程 xcodegen 管理：改文件后 `xcodegen generate`（新增文件时必做）→ `xcodebuild -project UniReader.xcodeproj -scheme UniReader -destination 'platform=macOS' build CODE_SIGNING_ALLOWED=NO`。非沙盒，**macOS 26+（Tahoe，不做低版本兼容）**。
- 已完成清单（工作区持久化/多窗口/采集页/方案 B/阅读区 v2/T1-T3 OCR/笔迹持久化/笔架/二进制协议/UDP/各批 bug 修复）**见 `HISTORY.md`**。当前要点：
  - **阅读区 v2（`PageStreamView`，纯 SwiftUI）已重写完成待真机验证**，五条硬指标与机制见 `PDF-VIEWER-REBUILD-PLAN.md`。**红线：阅读区纯 SwiftUI，严禁 AppKit 视图（含 NSViewRepresentable 包 NSScrollView）**。
  - 真平板已接入方案 B（连续多页 + 双向锚点 + 按需取图 `/page.png?i=N` + 双指缩放 + 惯性 + hover + 夜间 + 手写板模式 + 锁缩放 + 防误触）；采集页 HTML 独立为 `Sources/Resources/capture.html`。参数（缩放 catchup、惯性衰减、防误触阈值等）待真机手感微调。
  - 滚动跟随 `ScrollFollower`：**只跟随不预测**（纯临界阻尼低通，禁速度外推）；时间戳插值路径保留待真机 A/B（模拟结论：LAN 下未胜纯低通，详见 HISTORY）。
  - **2026-07-25：SimPad 已移除**；搜索改标准 `.searchable`；工具栏缩放组（缩小|1:1|放大）带 0.22s 逐帧动画；悬浮笔工具条更名「笔架」`PenRack.swift` 并加位置限制。
  - 通信协议 = 二进制线格式 v1（`PROTOCOL.md` 唯一契约）+ UDP RT 上行（Mac 端就绪）。
  - **2026-07-29：工作区改窗口级，多工作区并存**（双击另一个 `.unrd` = 新开窗口，原窗口不动）。方案、红线与踩坑见 **`REQUIREMENTS.md §8.1`**（权威）。三条要记住的：① **同一工作区路径必须共享同一个 `WorkspaceManager`**，否则两个 `LibraryStore` 会互相清库丢笔记；② 「双击/打开文档」这条链路的初始内容决策必须锚到 `applicationDidFinishLaunching`，且**别拿 `isKeyWindow` 当认领条件**（冷启动时全为假）；③ SwiftUI 每次 app 激活会凭空多开一个空窗口，四条来源已全部排除、只能识别后关掉。排障：`touch ~/Library/Logs/UniReader-ws.log` 开全链路日志（unified logging 抓不到本 app 输出）。
  - **2026-07-26：笔&笔架&笔迹四项已落地**（尺子模式 / 橡皮局部擦除+尺寸与笔宽两端同步 / Mac 本机落墨临时模式 / 笔记框选移动），机制与验证见 `HISTORY.md`，真机回归待做（见「接下来」）。
  - **2026-07-27：多层笔迹已落地**（图层作用域=整篇文档，相互独立、可同时显示/只显示一层、动态新建不设上限）：`InkStroke` 加 `layerId`（`InkLayer` 注册表，schema v7 新表 `ink_layer`）；`AppModel.eraseNear`/框选/`broadcastStrokes` 均按可见图层过滤；PenRack 新增「图层」弹出面板（`LayerRack.swift`，显示/隐藏、改名/改色、拖拽排序、删除）；线协议新增 `layers`（0x3A，S→C）同步图层表+当前作画图层给平板（`strokes` 广播已按可见性过滤，故平板天然只见可见图层；`capture.html` 暂不做图层 UI/HUD）。编译通过 + `wire-codec-test`/`wire-cross-test`/`ink-store-test`/`ink-edit-test` 全绿，**待用户真机验证**（多图层显示/隐藏/擦除隔离/持久化/平板同步）。
  - **2026-07-27：web 端（平板）新增框选移动**（此前只有 Mac 本机 `pointerTool==.lasso` 能框选移动，平板端是新能力）：`mode` 加第 4 态 `lasso`（PageUp 循环切入，与 note/erase/page 同款）；平板本地用与 Mac `finishLassoSelect` 同一算法复刻一份命中判定（`render.ts lassoHitTest`/`pageLocClamped`）做即时框选高亮 + 拖动 ghost 预览（纯本地、不上行，同 `eraseHit` 先例）；松手提交移动才发新增的 `lassoMove`（0x47，C→S：框选矩形 + 位移，均页内归一化）——Mac 收到后**不信任平板的本地判定**，用真源 `session.strokes`/`textNotes` 按同一算法重新命中、`InkEdit.translated` 平移、持久化，再 `broadcastStrokes`/`broadcastNotes` 镜像回所有端（`AppModel.applyLassoMove`）；平板侧提交后到权威回传之间做乐观位移渲染（避免弹回原位再跳新位置的闪烁），1s 兜底超时防止 Mac 零命中时永久卡住预览。协议改动：`wire.js`/`WireCodec.swift` 的 `MODEK`/`modes` 表从 3 项扩到 4 项 + 新 opcode `lassoMove`；`wire-codec-test`（55 通过）/`wire-cross-test`（100 通过）全绿，`tsc --noEmit`/`vite build`/`xcodebuild` 均过。**待用户真机验证**（框选/移动手感、跨图层命中是否符合预期、Mac↔平板双向模式切换是否同步）。

## 🔧 整体优化路线图（2026-07-25 起，用户需求「整体优化」）

四项大改，分里程碑推进。用户已定：UDP=整条实时流走 UDP（原生客户端自管序号/丢弃/轻量重传，控制握手仍走可靠通道，浏览器用不了 UDP 永远走 WS）；安卓 = 工作区内 `android/` 子目录独立 git 仓库。

- ✅ ① 通信协议改二进制 / ✅ ② 加 UDP 传输——已完成，见 `HISTORY.md`。
- 📝 **⑤ 笔迹算法三端统一（Rust 核心）**：**方案已出 → `INK-CORE-UNIFY-PLAN.md`**（2026-07-30，方案讨论稿，未实施）。起因：marker 混合模式 bug 暴露 macOS/Web/Android 笔迹渲染是各自独立实现而非同一算法移植（pencil 抖动纹理/fountain 起收锥度/ballpoint 半透明接缝黑点瑕疵，Web/Android 均缺或未修，见该文档 §1 逐项证据）。方向：Rust 核心只产出平台无关绘制图元（变宽描边转**闭合轮廓**、三端 nonzero 一次 fill），三端原生 2D API 仍各自负责上色/合成，不引入 Skia、不碰阅读区纯 SwiftUI 红线、不改线格式。**2026-07-30 二轮审核已修订该文档**：一轮"输出三角网格 + `lyon`"的选型与三端 `fill(Path)` 自相矛盾，已改为 stroke→outline（候选 `kurbo`，待 spike）；补了三端已分叉的 alpha/起笔/**笔宽是否随缩放**语义决策、输出坐标空间与缓存策略、`android/` 独立仓库的依赖形态、测试验收（golden 无法逐点比对）、以及不引入 Rust 的两个更轻替代方案对照。**待用户拍板：① 笔宽缩放语义（第一个卡口）② 是否引入 Rust 这一中间语言 / 何时开工。**
- 🚧 **③ 安卓模式1 独立版**：**设计方案已出 → `ANDROID-STANDALONE-PLAN.md`**（2026-07-29）。用户已定三条：全盘文件权限直开工作区文件夹 / 与模式2 同一个 App（启动二选一）/ 首版范围＝阅读+手写。技术选型：PdfiumAndroid 渲染、裸 `SQLiteDatabase`（不用 Room，schema 是 Mac 定的跨平台契约）、Compose 外壳 + 自定义 View 画布。核心设计＝把「页图哪来」「笔迹提交给谁」抽成两个注入口（`PageImageSource`/`InkBackend`），两模式共用全部几何/输入/渲染/笔迹算法。**最大风险：页面尺寸 box 口径两端必须一致（CropBox 有效则 CropBox，否则 MediaBox），不然笔迹整体漂移**，见该文档 §9.1。**2026-07-30 进度：M0~M6 已落地**（骨架/数据层/阅读/手写/擦除/多图层/笔架与图层面板/框选移动/尺子/文字注解 CRUD/已有高亮与选区注解铺色/长按环形选笔盘本地判定；只剩 M7 收尾＝最近工作区打磨、异常态文案、真机调参）。**用户设备不在手上，真机验证统一延后——待验项一律攒在该文档 §11.1（现 18 条），别当已验收；§11.2 写了模拟器能证明什么、不能证明什么。**
- 🧪 **④ 安卓模式2 输入板**：demo（`ANDROID-MODE2-PLAN.md`）已真机验收通过；**2026-07-29 补齐到与网页采集页对齐，待用户真机验证**——新增 probe 流(0x44)/环形选笔盘(0x37)/长按进度环(0x38)/padGeom(0x45)/框选移动(mode=3+0x47)/多图层(0x3A+0x26~0x28)/文字笔记(0x39+0x24)/橡皮双向同步(0x46，含局部擦除 splitStroke)/penset(0x25)/docs+selectDoc/gotoPage(0x29)/latency(0x12)/尺子模式(ink begin line 标记)；修 marker 逐段画成圆斑串、fountain 系数 1.15→1.3（一直画细）、滚动每帧无脑 setText、MacClient 三组状态跨线程；加 WS 自动重连+心跳看门狗、夜间/页图显隐/锁缩放/沉浸全屏/顶栏收起/侧键。字节向量单测扩到全部 51 条（含 radial/notes/layers/eraser/lasso/probe），编译+测试全绿。**未提交，等验收。**

## ⏭️ 接下来（建议顺序）

1. **真平板方案 B 打磨**：缓冲本地滚动 + progressive 多清晰度（PadRenderer/SimPad 已删，真平板链路已通，剩画质/带宽优化）。
2. **笔&笔架&笔迹四项真机回归**（2026-07-26 已落地，见 HISTORY）：尺子吸附手感 / 局部擦除两端一致 / 本机落墨（含 ⇧ 尺子）/ 框选移动（含重开文档位置保持、平板镜像）——手测发现问题即在此开新条目。
3. **安卓输入板补全真机验证**（2026-07-29，见路线图 ④）：重点验环形选笔盘（长按呼出/扇区高亮/取消区手感——这条链路此前平板端完全缺失）、框选移动、多图层、局部擦除与 Mac 是否一致、marker 荧光笔观感、断线自动重连。
4. **web 端框选移动真机验证**（2026-07-27 已落地，见上）：PageUp 切到「框选」模式后拖框选中 / 拖高亮框内移动 / 单击清选中 / Esc 清选中；跨图层命中是否符合预期（当前不按图层过滤，同 Mac 端 `finishLassoSelect` 对文字注解不分图层一致，但笔迹命中理应只认可见图层——若真机发现隐藏图层的笔迹被误选中，check `AppModel.applyLassoMove` 的 `vis.contains` 过滤是否与预期一致）。

## 🐞 已知 Bug（待修）

- 笔迹打磨（已知简化，非阻塞）：马克笔叠笔接缝变深；pad 实时反馈阶段铅笔无抖动纹理。根治路径见路线图 ⑤ `INK-CORE-UNIFY-PLAN.md`（三端算法统一后一并解决，非局部打补丁）。

## 📋 Backlog（M3 及之后）

- **🚀 大分支：Android Pad 版本**（2026-07-22 提出；**2026-07-26 用户：暂缓，优先级下调**）：不再是「Mac 端投屏给 pad 采集页 HTML」的方案 B 模式，而是直接做一个 Android 原生/独立 App，能在平板上打开工作区项目（读同一份跨平台 SQLite `library.sqlite` + 文档 + 笔迹）。呼应此前存储选型就是为跨平台（Windows/Android）预留的决定。范围大，需要单独立项拆解，不塞进当前 M3 迭代。（路线图 ③ 即此。）
- **三种笔记形态**：文字注解、手写笔记、高亮均已落地（见 HISTORY）；**会话笔记（kind=1，预留 AI）** 用户 2026-07-21 明确暂不做（消息流 UI + 锚定 + AI 接口整套未起）。
- **文件重定位**：所有路径失效时提示重新关联（`missingDoc` + Re-link 已在）；hash 命中加路径 / 未命中作同文档新版本、笔记挂文档不丢（`relocate` 已较健壮）。
- **配对/安全**：连接管理已在（`ServerPanel` 逐个断开）；二维码 UI 打磨仍可做。
- **T1/T2 遗留**：旋转页坐标未用真实旋转 PDF 验证；超大文档搜索可换 PDFKit 渐进式 API；拖到页边缘不自动滚动（非阻塞）。
- **T3 OCR 遗留**：整文件一次上传快路；跨「OCR 页↔原生页」混合边界拖选；搜索只覆盖已识别页；网络任务无取消；Vision 离线 OCR 未接。
- **打包**：非沙盒 + 公证发布流程。
