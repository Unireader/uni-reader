# APPKIT-REWRITE-PLAN — 界面整体重写为 AppKit（含阅读区）

> **2026-09-19 用户拍板**：「开一个新的分支，完全重构为 AppKit」；范围**包括阅读区**（推翻「阅读区纯 SwiftUI」红线）；
> 节奏 = **整体重写后再测**（中间不保证可用，写完统一实测）。
> 分支：`appkit-rewrite`（从 `main` `2465a27` 开出）。**`main` 上红线仍然有效，直到本分支合并。**
>
> **状态（2026-09-19）：第 1–8 步代码已全部写完并逐步提交，`Sources/Views/` 已删除，Debug 包可编译；等用户按 §7 清单实测。**
> 实现记录见 §9。

---

## 0. 一句话

**所有界面改成 AppKit（NSView / NSViewController / CALayer），模型层与纯逻辑一行不动。**
SwiftUI 只允许在一处残留：笔记 Markdown 编辑 / 只读渲染（第三方包只给了 SwiftUI 包装，见 §5 风险 3）。

## 1. 为什么（今天之前的账）

混合写法的别扭集中在三处衔接（2026-09-19 讨论）：
1. 工具栏等 AppKit 外壳的状态靠手工同步（`refreshToolbarStates` 挂七八个信号），漏一个就不同步；
2. 跨层通信靠 43 个自定义通知广播 + 各处认领；
3. 系统玻璃效果与 SwiftUI 布局互相影响（外框宽度变 → 工具栏按钮变浅；`.clipped()` 裁掉工具栏下内容），
   SwiftUI 这一层看不见 AppKit 在做什么，只能靠录屏 + 对照实验反推。

阅读区当年选 SwiftUI 的前提（v1 用 `PDFView` + `NSScrollView` 包装导致缩放跳位 / 闪烁）现在不成立：
v1 的问题出在 **PDFView**（私有 clip view 缺陷，见 memory `pdfkit-horizontal-insets-broken`）和
「SwiftUI 包 NSScrollView」的双层几何，**不是 AppKit 本身**。本方案不用 PDFView，也不再有 SwiftUI 外层。

## 2. 范围

| 重写（SwiftUI → AppKit） | 不动 |
|---|---|
| `Sources/Views/` 全部（约 1.56 万行） | `Sources/Store/`（SQLite、schema） |
| `Sources/Window/` 里的 `NSHostingController` 与 SwiftUI 根视图 | `Sources/Server/`、`PROTOCOL.md`、`web/`、`android/` |
| `UniReaderApp.swift` 里的 SwiftUI 部分、`App/WindowAccessor` | `Sources/MCP/` 全部（`MCPFacade` 只拼 DTO，不碰视图） |
| `AI/AIWebView`（`NSViewRepresentable` → 直接用 `WKWebView`） | `Sources/Agent/` 逻辑（`AgentChat` / `Connection` / `Transcript` / `PanelModel`） |
| | `App/` 纯逻辑：`PageRenderEngine` / `PageLayout` / `PageBitmap` / `InkEdit` / `InkUndo` / `InkPaste` / `InkClipboard` / `InkWindow` / `ScanAlign*` / `DeepLink*` 等 |
| | 模型：`AppModel` / `DocSession` / `TabsModel` / `WorkspaceManager` 等。保留 `ObservableObject` + `@Published`，AppKit 侧用 Combine 订阅（不改 `@Observable`，减少改动面） |

模型里零星的 SwiftUI 类型（`Color` 等）改成 `NSColor` / `CGColor`，只改类型不改逻辑。

## 3. 阅读区（🔴 需要你确认）

### 3.1 结构

```
ReaderScrollView : NSScrollView            ← 外框永远铺满内容区（今天的坑天然规避）
 └ NSClipView
    └ ReaderDocumentView : NSView (flipped, layer-backed, 不写 draw(_:))
       ├ PageHost × 可见±N 页（复用池）    ← 每页一个 CALayer 子树
       │   纸底层 / 页图层（整页或贴片）/ 高亮层 / 已落笔迹层 / 实时笔迹层 / 选区层
       ├ 笔记气泡 / 图片笔记 = NSView 子视图（要接鼠标）
       └ 框选 / 截图 / 橡皮圈 等覆盖层 = CALayer
```

- **PDFKit 仍然只用 `PDFDocument` / `PDFPage` 解析与出图，严禁 `PDFView`**（这条红线保留）。
- 出图照旧走 `PageRenderEngine` 后台串行队列、`PageLayout` 算页位置——这两块一行不改。
- 参考窗（`RefPageStream`）与草稿纸画布复用同一套 `ReaderDocumentView` 的精简版。

### 3.2 五条硬指标 → AppKit 机制

| # | 硬指标 | AppKit 机制 |
|---|---|---|
| 1 | 主线程不卡顿 | 主线程零渲染不变：出图全在 `PageRenderEngine`；主线程只算可见页 + 给 `layer.contents` 赋 `CGImage` |
| 2 | 预缓存页面 | 滚动通知（`NSView.boundsDidChangeNotification` on clip view）驱动实化 ±N 页；缓存命中同步赋图 |
| 3 | 窗口缩放 / 捏合不闪烁 | 所有层的隐式动画关掉（`actions` 置空 + `CATransaction.setDisableActions`）；图只替换不清空；布局与滚动在同一个 `CATransaction` 里提交 |
| 4 | 缩放锚定不跳位 | **用 `NSScrollView` 自带缩放**（`allowsMagnification`）：捏合的锚点、惯性由系统做，和 Preview 同一套；缩放过程中 GPU 拉伸旧图，`didEndLiveMagnify` 后按新倍率后台重渲，就绪原位替换。⌘+ / ⌘− 用 `setMagnification(_:centeredAt:)` |
| 5 | 任何情况零闪烁 | 同 3；换图永远是「新图就绪后原位替换」 |

第 4 条是最大的简化：SwiftUI 版里整套手写的逐帧锚定（`ReaderSurface+Zoom`、`ZoomAnim`、校验环）
是因为 SwiftUI 没有原生缩放；AppKit 有，而且就是 Preview 用的那一套。

### 3.3 宽度变化

- **拖窗口**：`inLiveResize` 期间冻结页尺寸，`viewDidEndLiveResize` 后按新宽度适配一次，锚定顶部文档点（与现在一致）。
- **侧栏 / Inspector**：系统给安全区内边距，页面不动、玻璃盖住（与现在一致，Preview 式）。
- **内置 AI 面板**：面板浮在右侧；阅读区用 `contentInsets.right` 让出宽度 → 外框不变（今天录屏确认的那条坑）。

### 3.4 输入

- 鼠标 / 触控板：直接在 `ReaderDocumentView` 的 `mouseDown/Dragged/Up`、`scrollWheel`、`magnify` 里处理，
  替代现在的 `DragGesture` + `NSEvent` 本地监视器；⌥ 拖截图、⇧ 尺子等修饰键直接读 `event.modifierFlags`。
- 数位板本机落墨可直接读 `NSEvent.pressure`（SwiftUI 版拿不到）。
- 平板跟随：保留「只跟随不预测、临界阻尼低通」的 `ScrollFollower` 逻辑，改由 `NSView.displayLink` 驱动
  `clipView.scroll(to:)` + `reflectScrolledClipView`。

## 4. 其余界面 → AppKit 对照

| 现在（SwiftUI） | AppKit |
|---|---|
| 侧栏 `SidebarView`（文档列表、分组） | `NSOutlineView`（source list 样式），拖放、右键菜单原生 |
| Inspector（信息 / 缩略图 / 目录 / 笔记分区） | 顶部 `NSSegmentedControl` + 各页：信息 `NSGridView`；缩略图 `NSCollectionView`；目录 `NSOutlineView`；笔记 `NSTableView` |
| 标签栏 `TabBarView` / `TabBarChrome` | 自定义 `NSView` + 系统控件（样式按系统，不仿绘） |
| Agent 面板 `AgentChatView` | `NSScrollView` + `NSStackView` 放消息行；输入框 `NSTextView`；菜单用 `NSPopUpButton` / `NSMenu`；底用 `NSGlassEffectView` |
| 咨询 AI 面板 `AIPanelView` / `AIInlineLayer` | 直接挂 `WKWebView`（去掉 `NSViewRepresentable` 那层，2026-08-26 的「重建视图 → 同一网页挂两次」崩溃根源随之消失） |
| 设置 `SettingsView` / `MCPSettingsView` | `NSTabViewController` + `NSGridView` 表单 |
| 各种 sheet（书签命名、笔记编辑、镜像、笔记类型管理） | `NSViewController` 以 sheet 弹出 |
| 工具栏弹出面板（目录 / OCR / 平板） | `NSPopover` + `NSViewController` |
| 笔架 / 图层架 / 环形选笔盘 / 跳转历史 / 草稿纸 | `NSView` + `CALayer`，浮在阅读区上 |
| 笔记气泡正文、Markdown 编辑器 | 见 §5 风险 3 |

外观原则不变：**只用系统控件与系统材质，严禁自绘仿系统样式**；玻璃底上的文字一律 `labelColor`（对应现在的 `.primary`）。

## 5. 风险

1. **工作量**：约 1.56 万行界面代码重写，加窗口层改动。整体重写期间分支不可用，问题集中在最后暴露（你选的节奏）。
2. **手感回归**：五条硬指标、笔迹落点、选字手感都要你真机逐条验收；我不能自己判手感。
3. **Markdown 引擎**：`swift-markdown-engine` 的 `NativeTextView` 是包内部类型，对外只有 SwiftUI 的
   `NativeTextViewWrapper`。两个选择：a) 这两处用 `NSHostingView` 托管 wrapper（唯一 SwiftUI 残留，范围很小）；
   b) fork 这个包把 `NativeTextView` 改成 public（和 swift-acp 同样的做法）。**建议先 a，后续再议 b。**
4. **Tahoe / macOS 27 外观**：玻璃、工具栏、分栏在 AppKit 里是一手接口（`NSGlassEffectView`、`NSSplitViewItem`），
   这是收益；但第一次写出来的样子要你对照现有版本看。

## 6. 写的顺序（整体重写，但按依赖顺序写）

1. **阅读区核心**：`ReaderScrollView` / `ReaderDocumentView` / 页层复用 / 出图接线 / 缩放 / 宽度变化 / 平板跟随
2. **阅读区功能层**：笔迹（本机落墨、擦除、尺子）、选字与高亮、框选（移动 / 缩放 / 剪贴板 / 撤销）、⌥ 拖截图、
   笔记气泡、图片笔记、画板模式、夜间模式、扫描页对齐
3. **窗口壳去 SwiftUI**：三段分栏直接放 AppKit 视图控制器；查找条、标签栏、各浮层
4. **侧栏、Inspector**
5. **Agent / 咨询 AI 面板**（内置 + 独立窗口）
6. **参考窗、草稿纸、跳转历史、笔架、图层架、环形选笔盘**
7. **设置、各类 sheet、工具栏弹出面板**
8. **删掉全部 SwiftUI 视图代码**，更新 `AGENTS.md`（红线、结构要点、文档地图）、`TODO.md`

每一步结束都保证**能编译**（`xcodebuild … -derivedDataPath build/dev`），但不保证功能完整。

## 7. 验收

- 纯逻辑 spike 照跑（`swift spike/*.swift`，Store / 笔迹 / 协议这些不受影响）。
- 界面：全部写完后给你 Debug 包，按下面的清单逐条实测。**我没有自己启动 App 测过任何一条**（项目规矩：实测归用户）。

### 7.1 实测清单

**阅读区五条硬指标**
1. 滚动长文档不卡（快速拖滚动条、触控板惯性滚动）
2. 滚到新页时页图已在（预缓存），没有白页一闪
3. 拖窗口改大小、开关侧栏 / Inspector、开关内置 AI 面板时不闪烁，面板开合时阅读区跟着让位
4. 捏合 / ⌘滚轮 / ⌘+ ⌘− 缩放锚点不跳（指针下的字不动），松手后由糊变清
5. 夜间模式切换、扫描页对齐切换、换标签时零闪烁

**阅读区功能**
6. 本机落墨（笔架「本机笔」）：四种笔型、⇧ 尺子直线、橡皮（整笔 / 局部）+ 尺寸圆环
7. 选字：拖选、双击选词、⌘A、⌘ 拖框选（合并 / 反选两种设置）、OCR 页选字、⌘C 复制
8. 高亮 / 画线 / 画框、点高亮弹出的换色气泡、转笔记、删除
9. 批注：新建（选区 / 右键点注解）、编辑器（Markdown + 公式、类型选择与管理类型、标记行、展开方式）、气泡展开（点开 / 悬停 / 始终）、卡片拖动与改大小、气泡里的链接
10. 图片笔记：拖图片进阅读区、⌥⇧ 拖节选、编辑说明、看大图（复制图片 / 在访达中显示）
11. 框选（笔架「框选」）：自由路径选中、拖动、角 / 边手柄缩放、剪切 / 复制 / 粘贴 / 删除、⌘Z / ⇧⌘Z
12. ⌥ 拖截图：松手弹「发给 Agent / 网页 AI」菜单，两边都能收到图
13. 书签：⌘D 命名框、页边缎带、Inspector 目录页里改名 / 删除
14. 画板模式、查找条（⌘F、上一个 / 下一个、命中闪烁）、跳转后退 / 前进
15. 右键菜单各项、环形选笔盘（平板长按）

**平板联动**
16. 平板跟随滚动（插值 / 低通两种）、平板写字实时出现、平板擦除 / 框选 / 粘贴、换标签后平板跟随正确的那本

**浮层与窗口**
17. 笔架：拖到别处（从按钮上起手也能拖）、收起 / 展开动画、加笔、改色 / 粗细 / 笔型、橡皮设置、图层面板（显示隐藏、拖动排序、改名改色、删除、新建）
18. 参考窗覆盖层：打开回到进度、滚动 / 缩放、折叠成气泡再展开保持位置、改大小 / 拖动、选书、目录跳转、回到进度、在主视图显示这一页、弹成独立窗口再改回来
19. 跳转历史浮窗：列表、点条目跳转、后退 / 前进、清空、拖动 / 改大小
20. 草稿纸：新建 / 打开、落墨 / 擦除 / 尺子、平移（拖动 / 滚轮）、捏合 / ⌘滚轮缩放、回中、适应内容、minimap 点跳、页面底图开关、纸样（底纹 × 底色）、改名、框选四件套、Esc 关闭
21. 标签栏两种形态、⌘T 选文档弹窗（搜索、方向键、回车）

**侧栏 / Inspector / AI**
22. 侧栏文档列表、分组、拖放导入、离线镜像两张面板（建镜像 / 同步预览）
23. Inspector 四页（信息 / 缩略图 / 目录 / 笔记七分区）
24. 内置 Agent 面板与网页 AI 面板：开合动画、改宽度、玻璃底；Agent 独立窗口、网页 AI 独立窗口（吸附、置顶、⌘F）
25. 工具栏弹出面板：目录、OCR、平板服务（二维码、复制地址、断开设备）

**设置与其他**
26. 设置六页：通用（夜间自动、更新、AI 开关、图片清理）、平板、阅读（字号 / 宽度 / 缓存 / 内存台账 / OCR key）、快捷键（录制 / 冲突提示 / 恢复默认）、Agent（MCP 服务、端口回车生效、口令、配置片段、客户端 / 最近调用）、诊断（打开耗时展开）
27. MCP 工具与 `unireader://` 链接跳转（开文档、跳页、展开笔记）

## 8. 明确不做

- 不改模型层、存储、协议、平板采集页、安卓端。
- 不借机加新功能；行为以 `main` 上现有版本为准，只换实现。

## 9. 实现记录（2026-09-19）

### 9.1 目录

| 目录 | 内容 |
|---|---|
| `Sources/Reader/` | 阅读区：`ReaderView`（+ `Render / Zoom / Follow / Canvas / Marks / Overlay / Input / TextSelect / Lasso / Actions / Menus / Snip` 扩展）、`ReaderScrollView`（滚动 / clip / 文档视图）、`ReaderLayers` + `PageMarksLayer`（页的图层树，全部无隐式动画）、`InkRenderCG`（四种笔的 CoreGraphics 画法）、气泡 / 图钉 / 覆盖层 / 环形选笔盘、`ReaderSupportTypes`（选择 / 框选 / 批注草稿等纯数据 + 菜单命令通知）、`ScrollFollower` |
| `Sources/Reader/Pane/` | 阅读窗格：`ReaderPaneController`（阅读区 + 查找条 + 角标 + 标签栏 + 浮层 + 草稿纸的装配与摆位）、标签栏、书签命名框 |
| `Sources/Reader/Ref/` | 参考窗页流 `RefPageStreamView`（覆盖层与独立窗口共用） |
| `Sources/Reader/Rack/` | 笔架 `PenRackNSView`（笔 / 橡皮编辑面板）、图层面板 `LayerManagerNSView` |
| `Sources/Reader/Scratch/` | 草稿纸 `ScratchPadNSView`（画布 / 工具条 / 框选）+ `ScratchCanvasNSLayers`（底纹 / 页面底图 / 笔迹 / minimap / 纸样） |
| `Sources/Window/` | 窗口壳：阅读窗、侧栏、Inspector、AI 面板（`AI/`）、浮层卡片（`Floating/`：参考窗覆盖层、跳转历史）、工具栏弹出面板与选文档弹窗（`Panels/`）、各种 sheet（`Sheets/`）、设置（`Settings/`） |
| `Sources/Markdown/` | `MarkdownNoteEditor.swift`：Markdown 引擎的 SwiftUI 包装 + 公式渲染器（**唯一的 SwiftUI**，见 §5 风险 3 的方案 a） |

### 9.2 与方案的出入

- **设置页**按方案用 `NSGridView`：左列说明右对齐、右列控件，是传统 macOS 设置窗的排法，**和原来 SwiftUI 分组表单
  （圆角分组底板）长得不一样**——AppKit 没有这种分组表单的系统控件，自己画底板又违反「严禁自绘仿系统样式」。要你看过再定。
- **笔架**拖动：从按钮上按下、挪过 6pt 就算拖（原版同款手感，由每个格子自己转交给笔架）。
- **参考窗页流**缩放改用滚动视图自带的放大倍率（与阅读区同一套），原版手写的锚点账本不再需要。
- 草稿纸视口动画（回中 / 适应内容）用显示刷新逐帧插值，0.18s 缓出，与原版同时长。

### 9.3 已知遗留（不影响编译，合并前要处理或确认）

- `spike/` 里几份**出样张**的脚本编的是已删除的 SwiftUI 视图，已失效：`note-bubble-look`、`note-bubble-icon-look`、
  `note-bubble-engine-look`、`image-bubble-look`、`tabbar-look`、`scratch-look`、`doc-picker-look`、`bookmark-flag-look`、
  `ink-fast-look`。要不要改写成 AppKit 版或删掉，等你定。
- `spike/ink-cross/`（Mac / web / 安卓三端笔迹对照）的 Mac 一侧编的是已删除的 `InkLayers.swift`，要改成编 `Sources/Reader/InkRenderCG.swift`。
- `spike/follower-step-test.swift` 本来就编不过（它只带了 `DocSession.swift`，而这个文件 09-17 起依赖 `ScanAlignTable`），与本次改写无关，路径已改到新位置。
- 纯逻辑回归照跑通过：`ink-store-test` 25/25、`ink-edit-test` 75/75、`ink-undo-test` 40/40、`ink-window-test` 32/32。
