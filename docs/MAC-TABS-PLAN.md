# macOS 端多标签页方案（MAC-TABS-PLAN）

> 2026-08-29 立。用户需求原话：
> 「tab 用自建 UI，不走 nswindows 的（过于复杂）；tab 显示在 pdf 区域的底部（盖住 pdf），
> 可以方便快速切换（不需要加载）；同时 tab 也是默认模式，同一个工作区打开都是走新的 tab。」
>
> 同轮拍板的四条：
> ① 标签栏**两种形态都要**（浮动胶囊 ⇄ 贴底整条，可互相切换），**关闭按钮在左侧**；
> ② **≥2 个标签才显示**标签栏（只开一篇时完全不占地方、不盖 PDF）；
> ③ 平板 `openDoc` 改成**开新标签**（推翻 2026-08-05「新开一个 Mac 窗口」的旧决定）；
> ④ 后台标签**每个 tab 独立计数**——像窗口一样各自完整存活，不做 LRU 休眠。

---

## 1. 核心原则：一个标签 = 今天的一个窗口

今天的账是「一窗一 `DocSession`」，而所有跨模块的记账**本来就是按 `DocSession.id` 走的**：

| 记账处 | 键 | 改标签后 |
|---|---|---|
| `AppModel.sessions` / `activeSessionID` / `padSession` | session.id | 语义不变，条目变多 |
| `AppModel.broadcastDocs`（平板文档列表） | session.id | 语义不变，天然列出全部标签 |
| `WorkspaceManager.windowDocs` → 「打开集」 | session.id | 语义不变 |
| `WorkspaceRegistry.windowPaths` / `windowsBySession` | session.id | 每个标签登记一份，指向同一个 NSWindow |

所以本方案的做法是**把「窗口级会话」整体降级成「标签级会话」**，窗口只保留 chrome
（工作区归属 / 侧栏 / 工具栏 / Inspector / AI 面板）。这样上表四处**一行不用改**，
平板协议**一个字节不改**。

🔴 **推论（本方案最重要的一条）**：既然一个标签 = 一个窗口，那么
**「后台标签也必须能自己落库」**——今天后台窗口能落库，是因为每扇窗口都有自己的
`ContentView` 在跑那一堆 `onChange`。标签化之后后台标签**没有视图在跑**，
落库链会静默断掉（表现：平板往后台标签写一笔、AI 面板绑到后台标签，重启后没了）。
故 §3 的「落库搬出视图层」不是重构洁癖，是功能正确性的前提。

---

## 2. 新增两个模型对象

```swift
/// 窗口级：这扇窗口开着哪些标签、当前是哪个。
@MainActor final class TabsModel: ObservableObject {
    let windowID = UUID()                       // 窗口身份（AI 面板宿主键、窗口登记）
    @Published private(set) var tabs: [DocTabModel] = []
    @Published var activeID: UUID?              // = 某个 tab 的 session.id
}

/// 标签级：一个标签的完整状态 + 它自己的加载/落库。**不依赖视图生命周期。**
@MainActor final class DocTabModel: ObservableObject, Identifiable {
    let session = DocSession()
    var id: UUID { session.id }
    // 从 ContentView 搬过来的：loadSelected / load*/persist* / saveProgress / verifyContentHash …
    // 以及原本是 ContentView @State 的 per-doc UI 态：missingDoc / hashMismatch / isHashing
}
```

`TabsModel` 由 `ContentView` 以 `@StateObject` 持有（工作区归属仍归 `RootView`，它不该知道标签）。

### 2.1 落库从 `onChange` 迁到 Combine 订阅

`ContentView` 里那 11 条 `onChange(of: session.xxx)` 全部搬进 `DocTabModel`，形式统一为：

```swift
session.$strokes.removeDuplicates().dropFirst()
    .sink { [weak self] _ in self?.persistInk() }
```

- `removeDuplicates()` 必加：`@Published` 的 publisher 每次赋值都发（不比相等性），
  而 `onChange` 只在值变了才触发——不加就是每次赋值都跑一遍全量对账。
- `dropFirst()` 必加：`$x` 会立刻发一次当前值。
- **安全边界**：这些 `persist*` 全是幂等的增量对账（比 `persistedXxx` 快照），
  多触发一次只是一次空扫描，不会写错数据。这让迁移的风险是「慢一点」而不是「错」。

🔴 **不要用「挂一个零尺寸隐形视图替每个标签跑 onChange」这条捷径**：本项目已经被
「零尺寸视图 SwiftUI 根本不创建」（`RootView.WindowCloser`）和「`onDisappear` 在窗口
建立过程中空放一次」坑过两次，落库正确性不能再押在视图生命周期上。

---

## 3. `ContentView` 拆两层

- **`ContentView`（窗口壳）**：`NavigationSplitView` + `SidebarView` + `.inspector` + `TabsModel`
  + 工作区快照同步 + 窗口级事件路由（⌘N / ⌘B / ⌘I / 夜间 / 工作区 alert）。
- **`DocPane`（detail 列，新文件）**：`@ObservedObject var tab: DocTabModel`，装今天的
  `detailColumn` / `readerColumn` / `toolbarContent` / `.searchable` / `navigationTitle`
  / `AIInlineLayer` / **标签栏覆盖层**。

🔴 **`DocPane` 不加 `.id(tab.id)`**：加了等于切标签时把 detail 列连工具栏整体重建，
必然闪一下（违反零闪烁纪律）。同一个视图实例换 `tab` 即可；per-doc 的瞬态在
`onChange(of: tab.id)` 里复位（搜索框收起、TOC popover 关闭等）。
阅读区自己的状态复位仍由既有的 `PageStreamView.id(docKey)` 负责——**这条不动**。

### 3.1 「切换不需要加载」到底省掉了什么

切标签**不会**发生：`PDFDocument(url:)`、读库取笔迹/图层/注解/高亮/AI 绑定/草稿纸、
`TOCEntry.build`、OCR 状态重建、进度查询。这些是今天换文档的全部开销。

切标签**仍会**发生：`ReaderSurface` 重建（`.id(docKey)` 变了）→ 重算 `PageLayout`
（纯算术）+ 从 `PageRenderEngine` 全局 LRU **同步取回**已缓存的页图 + 按
`session.scrollAnchor`/`readZoom`/`readHFrac` 复位视口。缓存命中即是一两帧内的事。

⚠️ 唯一会「看得见地加载一下」的情况：那篇的页图已被全局 LRU（默认 256MB，多标签共享）挤掉。
真机验证要专门看这一条（§8）。

---

## 4. 必改项（不改就是 bug，不是可选优化）

1. **AI 内置面板宿主键 `AIHost.inline(session.id)` → `.inline(tabs.windowID)`**。
   `AIInlineLayer` 的注释白纸黑字写着：**同一宿主被重建 = `_WebKit_SwiftUI.makeViewProvider`
   当场 trap**（2026-08-26「开着 webview 切换书」秒崩）。按 session.id 分宿主的话，
   切标签就是换宿主，正好复现那个崩溃。`releaseHost`/`forgetInline` 的调用点仍在窗口关闭时，
   只是 id 换成 windowID。
   而 AI **会话绑定**（`threadUpsert`/`noteRequest`）仍按 `sessionID` 路由 → 由 `TabsModel`
   按 id 找到那个标签的 `DocTabModel` 落库，**哪怕它在后台**（§1 推论的直接受益）。
2. **`WorkspaceRegistry.noteWindowObject(session.id, window:)` 每个标签都登记**一次，
   指向同一个 NSWindow。这样 `window(for:)`（AI 面板吸附）、`activateWindow(forWorkspace:)`
   等既有查询全部照常工作。
3. **`noteWindow(session.id, path:)` 每个标签开一份关一份**。`maybeTeardown` 的语义
   「本工作区已无会话在用 → 关库连接」不变且更准（移动硬盘弹出那条红线不受影响）。
4. **关标签 = `session.teardown()`**（放掉 PDF / 库引用），与关窗同一口径。
   否则移动硬盘弹不出去的老问题会以「关了标签还占着」的新形态回来。
5. **`ContentView.onDisappear` 的关窗收尾要对每个标签跑一遍**（存进度 → `closeWindow(id)`
   → `noteWindow(id, nil)` → `unregister` → `teardown`），且**次序不能变**（写库两步必须
   先于 `noteWindow(nil)`，见 `WorkspaceRegistry.maybeTeardown` 注释）。

---

## 5. 标签栏 UI

### 5.1 形态（两种，可切换）

| | 浮动胶囊 | 贴底整条 |
|---|---|---|
| 材质 | `.regularMaterial in Capsule()` + 0.5 描边 + `shadow(6,2)` | `.regularMaterial` + 顶部 `Divider` |
| 位置 | 阅读区底部居中上浮 12pt，两侧留白 | 贴底满宽 |
| 语言来源 | 与 `PenRackView` / `findBanner` / `snipToast` / 草稿纸工具条**完全同一套** | 系统标准 bar |

- 切换入口：**右键标签栏 → 「固定到底部 / 浮动」**（不占工具栏）。存 `@AppStorage("tabBarStyle")`，
  app 级（不逐窗口）。
- 🔴 **严禁自绘仿系统样式**（用户 2026-07-25 明确否决）：两种形态都只用系统材质与标准控件，
  系统渲染成什么样就什么样。
- 🔴 **交付前用 `ImageRenderer` 出样张逐张目检**（`spike/tabbar-look.swift`，照
  `spike/scratch-look.swift` 的先例办）：浅/深两套外观 × 两种形态 × 1/3/8 个标签。
  草稿纸那轮的教训是——**样张里没复刻到的那一件，就是下一个漏网的**，所以样张必须把
  关闭按钮、活动态、hover 态、溢出滚动都画出来。

### 5.2 标签本身

- **关闭按钮在左侧**（用户明确要求，也是 macOS 惯例：Safari / Xcode 同款）。
  常态淡显、hover 变实；活动标签常显。
- 内容：`关闭按钮 · 标题`。宽度自适应，clamp 120…220pt，超出窗口宽则**横向滚动**
  （不做「越开越窄」的挤压）。
- 右端一枚 `+`：开新标签（= 空态，侧栏点一篇即装载）。
- **平板正在跟随的那个标签**画一枚小标记（`ipad` SF Symbol）——平板可以跟随后台标签
  （见 §6.3），没有标记的话用户完全不知道自己的笔写到哪儿去了。
- 拖拽重排（`onMove`）：做，因为标签顺序要持久化（§7）。

### 5.3 挂载点与避让

- 🔴 **必须挂在 `readerColumn` 这一层**，与 `AIInlineLayer` 同一层、同样的两条理由：
  ① 身份要稳定（不能落进 `PageStreamView` 的 `.id(docKey)` 下游，否则每次换标签整体重建）；
  ② 要能挡住阅读区那四个挂在 `ScrollView` 容器上的拖拽手势（`.overlay` 加在同一个视图上挡不住）。
- **笔架避让**：把标签栏高度作为底部 inset 传给 `PenRackView`（它已有 `topInset` 同款先例），
  否则浮动笔架会和标签栏叠在一起。
- **滚动条避让**：贴底形态会盖住阅读区滚动指示器的底端，需要给它加 bottom inset
  （`indicatorTopInset` 已有同类先例）。
- **草稿纸打开时隐藏标签栏**：草稿纸是盖住阅读区的全屏覆盖层，它自己有工具条与 minimap，
  再叠一条标签栏就是三层浮层打架。

### 5.4 键盘 / 鼠标

| 手势 | 行为 |
|---|---|
| ⌘1…⌘9 | 切到第 N 个标签（⌘9 = 最后一个，Safari 口径） |
| ⌃Tab / ⌃⇧Tab | 下一个 / 上一个标签 |
| ⌘W | **关当前标签**（改动：今天是关窗口） |
| ⇧⌘W | 关窗口 |
| 中键点标签 | 关闭 |

---

## 6. 打开语义

### 6.1 本机

| 入口 | 今天 | 改后 |
|---|---|---|
| 侧栏点一篇文档 | 顶掉本窗口当前文档 | **已开着 → 切到那个标签；没开 → 新标签** |
| 侧栏右键「在新窗口打开」 | 新窗口 | 不变（显式要窗口就给窗口） |
| ⌘N | 同工作区新窗口 | 不变 |
| 双击另一个 `.unrd` | 新窗口 | 不变（工作区仍是窗口级，红线不动） |

🔴 **工作区仍然是窗口级**：切工作区 = 换窗口，不是换当前窗口的内容（`RootView` 的既有纪律）。
标签**属于窗口**，因而也属于那个工作区——不做跨工作区混排的标签（与安卓端 §13 同一条拍板：
那要同时挂多份库连接，与单写者红线顶着来）。

### 6.2 关掉最后一个标签

**窗口保留，回到空态**（`ContentView` 已有的 "No Document" 态，侧栏还在）。
理由：这扇窗口的身份是「一个工作区」，不是「一篇文档」。要关窗口有 ⇧⌘W。

### 6.3 平板

- `docs` 列表 = 全部标签（代码不用改，`sessions` 天然变成标签集）。**协议零改动。**
- `openDoc`（平板书库里点一篇没开的）→ **在平板当前跟随的那个窗口里开新标签**并切过去。
  `AppModel.padOpenDocRequest` 保留，只是接收方从 `openWindow(...)` 改成 `tabs.open(docId:)`；
  `pendingPadFollowDocId` 那套「新会话 id 此刻还不存在，等 `sessionDocumentChanged` 再锁过去」
  的机制**原样沿用**。
- `selectDoc` 选中一个后台标签 → **Mac 不强制跟着切**（与今天「平板选另一扇窗口的会话、
  Mac 那扇窗口不会跳到前台」保持一致）。后台标签能独立落库（§1 推论），所以这是安全的；
  用户侧靠 §5.2 的标签标记感知。

---

## 7. 持久化与恢复

- `workspace.setWindowDoc(session.id, docId)` 每个标签调 → 「打开集」`openDocs` 自动变成
  「所有标签的文档集」，`persistOpenDocs` / 平板 `library` 的 open 标记全部照旧。
- **标签顺序 + 活动标签**另存：`UserDefaults` 键 `tabs:<工作区标准化路径>` → `{ docIds: [...], active: n }`。
  **不动 SQLite schema**（`openDocs` 是 MRU 序，不是标签左右序，两者职责不同）。
  照搬安卓端「标签页组存 SharedPreferences、按工作区路径分键、只存开着哪几篇，进度仍在库里」的做法。
- `restoreSession` 改写：不再 `openWindow` 开 4 扇窗口，而是**在本窗口把整组开成标签**
  （顺序取 UserDefaults，缺失则退回 `restoreDocIds`）。`WorkspaceRegistry.claimRestore(folder)`
  「每个工作区只恢复一次」的记号保持不变。
- ⌘Q 退出时 `AppDelegate.isTerminating` 保护「打开集」不被清空的既有逻辑不变。

---

## 8. 内存账（用户拍板：每个 tab 独立、不休眠）

每个标签独立持有：`PDFDocument` + `strokes`/`inkLayers`/`textNotes`/`highlights`/`scratchPads` 数组
+ PDFKit 自己的解析缓存。**页图位图不在此列**——它们在 `PageRenderEngine.shared` 的全局 LRU 里
（默认 256MB 硬上限、按真实份数计费、多标签共享），所以标签数**不会**线性放大位图那笔账，
只会让同一份预算被更多文档分。

要做的三件事：
1. 设置页把 `PageRenderEngine.debugSummary` 露出来，并补一行「当前标签数 / 各标签活位图」。
2. 真机记一组数：1 / 3 / 6 个标签各自的 footprint（手法见 `unireader-memory-profiling` 的纪律：
   footprint 看分类、vmmap 看块尺寸，**「已分配」会骗人，要自己数存活对象**）。
3. 若 6 个标签就顶到不可接受，再回头加 LRU 休眠（安卓模式1 已有现成方案可抄）。
   **这一步不预先做**——用户明确要「独立」，先量再说。

---

## 9. 分两步走（每步可单独编译、单独回滚、单独验）

### 第 1 步：落库搬家（行为一字不变）—— ✅ 2026-08-29 已落地，待用户真机回归

新建 `Sources/App/DocTabModel.swift`（672 行），`ContentView` 1146 → 645 行。搬过去的东西：
16 条 per-doc `onChange`（含 `canvasRoutes`/`aiRoutes`/`scratchRoutes` 三层包装，它们当初纯粹
是为绕开类型检查器超时才拆的，现在不需要了）、`loadSelected`→`select`/`load`、全部
`clear*`/`load*`/`persist*`、`saveProgress(+Throttled)`、`verifyContentHash`、
`setCanvasMode`、`relocate` 的改库那半段，以及 `selectedDocID`/`missingDoc`/`hashMismatch`/
`isHashing` 四个 per-doc 状态。会话注册 / 工作区快照 / `noteWindow` 登记进 `init`，
关窗收尾整块进 `close()`。

**实作中撞到三个坑，都写进代码注释了**：

① 🔴 **`@Published` 是在 `willSet` 发的** —— 同步的 `sink` 里 `session.x` 读到的还是**旧值**，
而所有 `persist*` / `app.broadcast*` 都直接读 `session.x`。少了这一跳，落库和广播会整体
**慢一个版本**（写进库的是上一次的内容）。故 `on()` 一律带 `.receive(on: DispatchQueue.main)`；
顺带也解决了「在 willSet 里反手改另一个 `@Published`」的重入（`consumeUpsert` / `padCanvasRequest = nil`
都是这种）。与 `onChange` 的唯一语义差是「同一轮赋 N 次值 = N 次回调」，而 `persist*` 全幂等，
多跑几次只是空扫描。

② 🔴 **`session` 从 `@StateObject` 变成计算属性 = `ContentView` 不再观察它**。标题栏、工具栏
禁用态、查找条、OCR 面板全靠它刷新（表现会是「翻页了副标题还停在旧页码」）。修法：`DocTabModel`
把 `session.objectWillChange` 原样转发给自己，观察 `tab` 即等价于观察会话，刷新频率与从前一致
（`readZoom`「稳定后才写一次」、`readHFrac` 不 `@Published` 这两条性能红线不受影响）。
附带：没有 `$session` 投影了，`.searchable`/`Toggle`/`Picker` 改用 `bind(\.keyPath)` helper。

③ 🔴 **异步跳拍开了一个「切文档/关窗把最后一次改动甩掉」的窗口** —— 排队中的那一拍会落在
`load(新文档)` 或库连接关闭**之后**，那时会话里装的已经是别的东西，旧改动被当成无事发生。
故 `select()` 与 `close()` 开头都同步跑一遍 `flushPersist()`（七个 `persist*`，幂等，
没待写内容时就是空扫描）。

验证：`xcodebuild` 零 error 零 warning；`store-test`(38) / `ink-store-test`(21) /
`ink-edit-test`(62) / `scratch-store-test`(53) / `ocr-store-test`(15) / `ai-thread-store-test`(53) /
`note-type-test`(27) / `canvas-margin-test`(24) / `page-layout-test`(25) / `page-snip-test`(34) /
`ocr-char-select-test`(26) / `udp-reorder-test`(26) / `wire-codec-test`(90，导出向量与库里的
`wire-vectors-swift.txt` 逐字节一致 → 跨端向量未变) 全绿。

**待用户真机回归**（确认「搬家没搬丢东西」，界面上应当看不出任何区别）：开/切文档、落笔与擦除、
文字注解、高亮、图层显示隐藏、草稿纸、AI 绑定与「选中回答建笔记」、阅读进度（页/缩放/横向）恢复、
画板模式（按钮与 ⌥⌘C）、平板全链路（跟随/落笔/换文档/草稿纸/画板上行）、
文件被原地替换的提示、重定位、关窗后移动硬盘能否立刻弹出。

### 第 2 步：标签化 —— ✅ 2026-08-29 已落地，待真机验证

新增 `Sources/App/TabsModel.swift`、`Sources/Views/TabBarChrome.swift`（纯呈现层）、
`Sources/Views/TabBarView.swift`（适配器）、`spike/tabbar-look.swift`（样张）。

**`DocPane` 拆层没做，也不需要做。** 它当初是为了「让视图观察得到当前标签的会话」，
而 `TabsModel` 只转发**活动标签**的 `objectWillChange`（链路：会话 → 标签 → TabsModel →
`ContentView`）就已经等价于从前的 `@StateObject var session`，且churn 小得多。
`ContentView` 里只把 `tab` 改成 `tabs.active` 一行，其余基本没动。

落地要点（与方案不同处已在此说明）：
- **不变式：`tabs` 永远至少有一个** → `active` 非可选。于是「关掉最后一个标签保留窗口回空态」
  这条自然成立：标签栏只有 ≥2 个才显示，唯一能关最后一个的入口是 ⌘W，而 ⌘W 在只剩一个时关的是
  **窗口**（同 Safari）。「空窗口」就表现为「一个没装文档的标签」，即从前的空态。
- **`DocSession.windowID`**：窗口身份挂在会话上，需要它的两处（`AIInlineLayer`、
  `ReaderSurface+Snip` 的面板宽度）不必层层传参。AI 内置面板宿主全线改按窗口分
  （`AIPanelModel` 的 `session:` 参数一并改名 `window:`，`inlineOpenSessions` → `inlineOpenWindows`）。
- **`DocTabModel.isActive`**：`load()` 只在自己是活动标签时才 `app.setActive`。不加这条，
  冷启动恢复一组标签时每装载一个后台标签就把平板抢过去一次。
- **恢复**：标签序 + 活动标签存 `UserDefaults`（键 `tabs:<工作区路径>`），缺失则退回库里的
  「打开集」。上限 8 个标签（从前是「本窗口 1 篇 + 最多 4 扇窗口」）。
- **`bottomInset`**：`TabBarMetrics.inset` 一路传到 `ReaderSurface`，用于滚动条
  `contentMargins(.bottom)` 与笔架拖拽夹取的下界。只有一个标签时为 0，阅读区一寸不让。
- 草稿纸打开时隐藏标签栏（三层浮层打架）。

**实作中撞到三个坑**：

① 🔴 **切回标签会跳回「装载那一刻」的位置**。切标签时阅读区整体重建（`.id(docKey)`），
而 `ReaderSurface.setup` 的首帧只认 `restoreZoom`/`restoreHFrac` 和**来源不是 "mac"** 的锚点
——本机滚动发出的锚点 origin 恰恰是 "mac"（那条判断是为了不让视图重建时把自己刚发的锚点吃回去）。
修法：`DocTabModel.prepareForReactivation()` 在切过去之前把活值翻译成一条 `restore` 锚点，
走的正是「开文档恢复进度」那条验熟了的路。

② 🔴 **样张当场抓到两处布局/对比度问题**（`spike/tabbar-look.swift`，编的是**真实的 `TabStrip`**
而不是复刻——草稿纸那轮的教训是「少复刻一件，那件就是下一个漏网的」）：
 · 横向 `ScrollView` 是贪心的，会把浮动胶囊撑成**整条阅读区宽**（就不是胶囊而是圆角横杠了），
   且 `ImageRenderer` 画 ScrollView 是**整块空白**、根本没法目检 → 改 `ViewThatFits`
   （放得下整排铺开、放不下才滚动）+ 给标签排加 `fixedSize(horizontal:)`（标签用的是弹性
   `minWidth/maxWidth`，HStack 会把可用宽平摊给它们）。
 · 只靠 `.primary`/`.secondary` 分主次时，**浅色外观下活动标签反而比非活动的更浅**
   （`.quaternary` 底片会把文字一起提亮）→ 活动标签**加粗**，字重是唯一不受底色影响的区分手段。
   另：样张里活动标签一定要取**中间那个**，取第一个的话「浅的是活动的还是第一个」分不清。

③ **关标签会把平板跟随交给另一扇窗口**：`AppModel.unregister` 在关掉的正好是被跟随的会话时
把跟随交给 `sessions.last`。本窗口还开着，跟随理应留在本窗口 → `TabsModel.close` 收尾时拉回来。

**故意没做的**（真要再加）：标签拖拽重排、⌘1…⌘9 切第 N 个。前者要自己算落点、后者要 9 个菜单项，
都不是这一轮的必需；标签顺序按创建序持久化，不重排也是稳的。

**2026-08-29 用户真机报的四处，全部修掉**（① ② 是主干，③ ④ 是排查途中翻出来的真 bug）。

> 🔴 **这一节最该记住的不是某个修法，是排查方式**：①「切标签有加载感」我在渲染时序里连猜三次
> （`@Published` willSet 时序 / `@State` 同趟读写 / 退化几何帧）——**那三处都是真 bug、都该修，
> 但没有一个是主因**。主因是一句业务假设过期了（见 ①）。转去按仓库自己的纪律
> 「静默失效先打点再改码」加了三处 `ZoomProbe.mark` 之后，**第一份日志就把答案摆在脸上了**
> （`快照有料 / 种子命中 / 图 0 张` —— 「图 0 张」那三个字就是答案，我却先去追 realized 了）。
> 结论：**这类「改了没效果」的问题，打点的成本永远低于再猜一轮。**

**① 「切换标签有加载感，有点闪烁」**——这是本方案的头号指标，必须治本。

🔴 **真凶：`ReaderSurface.onDisappear` 里那句 `PageRenderEngine.shared.purge(doc: docKey)`。**
它的注释写着「本窗口不再看这份文档了（关窗 / 换文档）」——在单窗口时代这个前提是对的：
阅读区外层挂着 `.id(docKey)`，视图销毁只可能是关窗或换文档。**多标签之后它不成立了**：
切走标签只是把这个阅读区拆了，文档还在后台标签里开着，可它把整篇的页图（几百 MB）全清了，
于是每次切回来都要从头重渲一整屏 = 必然的加载感，与下面那套快照种子毫无关系。
修法：只有**这篇文档不再被任何会话持有**时才清（`app.sessions` 里没人拿着这个 `contentHash`）
——关标签 / 关窗（`DocSession.teardown` 另有一次兜底）/ 本标签换了文档。抽成
`releaseRenderCache()` 而不是内联，`onDisappear` 那条修饰符链多两行就类型检查器超时。

下面这套「首帧种子」是同一轮里另建的机制，它让**重建后的首帧直接是离开时那一屏**
（否则即使图还在缓存里，也要等几何回调那一拍才实化出图）：
根因：切标签时阅读区被 `.id(docKey)` 整体重建，而常规首帧路径要等 `onScrollGeometryChange`
回调才 `didInitialGeo` → 定 fit 基准 → 实化 → 出图，那是**下一拍**的事；这一拍屏幕上是
`voidColor` 空白。开窗时那是刻意取舍（「宁可白一下也不闪一下」），但切标签时用户刚刚还在看
这一页，白一下就是加载感。
修法：`DocSession.ReaderSnapshot`——阅读区每次几何回调留一份「现在长什么样」
（fit 基准 / 缩放 / 偏移 / 实化窗口 / 基图像素宽），重建时拿它把状态种回去：定基准、置实化窗口、
**从页图缓存同步取图填 `images`**、`ScrollPosition` 直接落在原偏移。

🔴 **种在 `ReaderSurface.init` 的 `@State` 初值里，不能种在 `onAppear`**（第一版就栽在这儿，
用户录像复测「还是先空白再出内容」）：`onAppear` 是**视图首帧画完之后**才调用的，在它里面做多少事
都救不了那一帧空白。`@State` 的初值则在**结构体第一次被创建**时定下，赶在首帧之前。
连带两件事：`PageLayout` 缓存到会话上（init 里现算要遍历全部页）；用一个一次性标记
`readerSeedPending`（`prepareForReactivation` 置、`setup` 清）挡住无谓的缓存查询——
`ReaderSurface` 的 init 在写字时每落一个点都会重跑一次。**故意不在 init 里清那个标记**：
SwiftUI 允许一次布局里多次创建 struct，清早了真正被装载的那一次就拿不到种子。

三条前提缺一不可，任何一条不满足就原样退回常规首帧路径（开窗 / 换文档都该走那条）：
有「待种」标记、有锚点、**布局宽没变**（期间窗口或侧栏尺寸变过的话旧快照是错的；
那时靠 `prepareForReactivation` 发的 `restore` 锚点兜底，慢一拍但位置不丢）。
换文档时 `DocTabModel.load` 清空快照与布局缓存——那时该走库里的进度，不是上一篇的屏幕状态。
🔴 快照非 `@Published`（每次几何回调都写，发布出去就是每帧重算整窗视图树，同 `readHFrac`）。

🔴 **快照里只许放「慢变量」**（fit 基准 / 缩放 / 基图像素宽），**滚动偏移与实化窗口这种
每帧都在变的量绝不能放**——视图销毁前会来最后一拍**零几何**，正好把它们写成
`offset=0 / realized=0…0`，快照记住的位置于是永远是文档顶端（表现：图种上了、不闪了，
但**切回来回到顶部**）。位置改从 `session.scrollAnchor`（页 + 页内比例）+ `readHFrac`
**现算**：那是阅读区一路维护、**存阅读进度也在用**的可靠真相，与视图的生死无关；
实化窗口据算出来的偏移现推（与 `updateRealized` 同口径，上下各留一屏）。

🔴 **种下位置之后必须显式 `pos.scrollTo(point:)` 一次**：`ScrollPosition` 的**初值**不保证被采纳，
而 `verifyPendingTarget` 那套兜底重试是**几何回调驱动**的——页面停着不动就不会再有几何回调，
光挂一个 `pendingTarget` 等于永远不重试。

另外两处顺带修掉的真 bug（都不是主因，但都会独立咬人）：
· `@Published` 是在 **willSet** 发的 → `DocTabModel` 的订阅必须 `receive(on:)` 跳一拍（见第 1 步）；
· `@State` **同一趟更新里刚写完再读回来拿到的是旧值** → `updateRealized` 改为**返回**它 settle 后的
  实化窗口，调用方一律用返回值，别回头读 `realized`；首帧那一趟 `fitBasis`/`zoom` 同理不可信，
  故那一趟不拍快照；
· `geometryChanged` 原本只兜「宽退化」（`containerW <= 0`），**高退化（`containerH == 0`）会一路走下去**
  ——`updateRealized` 据它把实化窗口算成 `0…0`，紧接着「驱逐窗口外页图」把 `images` 清空。
  现在先用未遮视口高度兜一次，仍退化就整帧丢掉。

**② ⌘W 关掉了整扇窗口**——之前预判的冲突坐实了：AppKit 自带的「文件 › 关闭」也占着 ⌘W，
菜单快捷键抢不过它。
修法：**本地 keyDown 监视器**（`ContentView.installCloseTabHotkey`）——它跑在**菜单等价键判定
之前**，可靠。每扇窗口各装一个，先核对「本窗口是不是 key window」再认领，不是就原样放行；
**只剩一个标签时也放行**，让系统照常关窗（同 Safari 的语义，且省得自己再走一遍 performClose）。
两个坑：监视器句柄存在引用类型的 `MonitorBox` 里而不是 `@State`（`onDisappear` 闭包拿到的是
View 的值拷贝，摘除时可能读到 nil，监视器就永远留在 app 里）；闭包里**先把 `TabsModel` 取出来
再捕获**，别从 View 的值拷贝上读 `@StateObject` 包装器（那属于「未安装在视图上」的访问）。

**③ 阅读进度整个不保存/不恢复**——**这是第 1 步「纯搬家」时埋的**，与标签无关，
所有窗口都中招，只是当时那轮回归没验到。
原来的 `saveProgress(docId: String?)` 开头是 `guard let docId else { return }`（没有旧文档就什么都不做），
我搬家时顺手加了默认参数，变成 `docId ?? docID` —— 于是「没有旧文档」被兜底成了「存到当前这篇」。
而 `select()` 的调用正是 `saveProgress(docId: old)`，**窗口第一次开文档时 `old` 就是 nil**：
```
select(id) → docID = id
           → saveProgress(nil) → 兜底成 id，用空会话状态（第 0 页 / 缩放 1）覆盖这篇的进度  ← 自毁
           → load(id)          → 从库里读，读到的正是刚被覆盖掉的第 0 页
```
每次打开文档都先把自己的进度抹掉再读。现在拆成两个方法：`saveProgress()` 存当前文档、
`saveProgress(documentId:)` 存指定文档且 **nil 就什么都不做**，红线注释写明「绝不能兜底成当前文档」。
🔴 教训：**给一个「传 nil 表示不做事」的参数加默认值兜底，等于把「不做事」翻译成了「对当前对象做事」**
——搬家时这种「顺手改善签名」最危险，它不在 diff 的显眼处，也不会让任何测试变红。

**④ 快捷路径「带着错数据成功」**——③ 之外，②/① 排查途中还栽过一次同款：
坏快照把偏移种成 0，而种子一旦「命中」，`setup()` 就跳过了原来的锚点恢复兜底，
于是**位置直接丢了，比原来那点闪烁严重得多**。
🔴 教训：**新加的快捷路径可以失败，但不能带着错数据成功**——要么自校验后失败并完整退回旧路径，
要么根本别跳过旧路径。

验证：`xcodebuild` 零 error 零 warning；13 个 spike 全绿（数目同第 1 步，`wire-vectors-swift.txt`
逐字节未变）；`spike/tabbar-look.swift` 出 16 张样张（两形态 × 浅深 × 2/5/9 标签 + 4 张特写）已逐张目检。

---

## 10. 真机验证清单（用户执行，攒进 `REQUIREMENTS.md §11.1` 口径）

1. 切标签**看不看得出加载**（重点：页图被 LRU 挤掉的那种情况）。
2. 切标签后阅读位置/缩放/横向滚动**精确复位**，不跳、不闪（第 2 步坑 ① 就是修这条的）。
3. 两种标签栏形态的观感、对比度（浅/深外观）、关闭按钮在左的手感；**右键切形态**。
4. 标签栏与笔架、滚动条、草稿纸、AI 面板的遮挡关系。
5. 平板：`docs` 列表列出全部标签；书库点一篇没开的 → Mac **开新标签**并跟过去；
   平板跟随后台标签时标签上那枚 iPad 标记看不看得见。
6. 后台标签独立落库：平板往后台标签写一笔 → Mac 切过去/重启后仍在。
7. 内存：1 / 3 / 6 个标签的 footprint。
8. 关标签后移动硬盘能不能立刻弹出（`teardown` 有没有跟上）。
9. 冷启动恢复：标签顺序与活动标签是否照旧。
10. **⌘W 关的是标签还是整扇窗**（第 2 步末尾 ⚠️ 那条冲突）；⇧⌘W 关窗口；⌘T 新标签；
    ⌃Tab / ⌃⇧Tab 前后切。
11. 标签开到十几个时的横向滚动（样张里 `ScrollView` 渲染是空白，这条只能真机看）。
12. AI 内置面板：**开着 webview 切标签**不崩（宿主改按窗口分就是为这条），切回来对话还在。

---

## 11. 红线汇总（本方案不许碰的）

- 阅读区**纯 SwiftUI**，标签栏也一样（不许 `NSTabView`/`NSSegmentedControl` 包进来）。
- **不走 NSWindow 原生标签**（用户明确否决，「过于复杂」）——不要 `tabbingMode` 那一套。
- 工作区**仍是窗口级**；标签不跨工作区。
- **零闪烁纪律**：切标签不许出现工具栏/标题栏/阅读区的整体重建闪动。
- UI **不自绘仿系统样式**；自绘图形交付前先出样张自查。
- 落库正确性**不押在视图生命周期上**（§2.1）。
