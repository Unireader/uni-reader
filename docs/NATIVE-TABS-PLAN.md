# 原生窗口标签方案（NATIVE-TABS-PLAN）

> 2026-11-28 立，取代 `MAC-TABS-PLAN.md` 的「自建底部标签栏」（那份留作历史，§1 的「一个标签 = 从前的一个窗口」原则仍然成立）。
> 用户原话：「我确实觉得需要原生的那个 tab 了」「把原来底部的 tab，改成 window，每一个都是这样就好」。
> 依据：`spike/native-tabs` 分支上的实验包（同工作区阅读窗口 `tabbingMode = .preferred` + 同一个 `tabbingIdentifier`，
> 「在新窗口打开」改为 `addTabbedWindow`），用户实测认可观感与手感。
> 背景：macOS 没有可单独使用的系统标签栏控件（Tahoe SDK 头文件核过），系统标签只有 NSWindow 窗口标签这一种 = 一个标签一扇窗口。

---

## 1. 目标形态

- **一个标签 = 一扇 `ReaderWindowController` 窗口，窗口里只装一个 `DocTabModel`**。标签栏由系统画在工具栏下面。
- 同一个工作区的窗口用同一个 `tabbingIdentifier`（`UniReader.reader.<工作区路径>`），不同工作区不混进同一组。
- 底部胶囊 / 贴底标签栏（`TabBarNSView`、`TabBarMetrics`、两种形态切换、各页面为它让出的底部距离）**整体删除**。
- 系统白送的：拖动排序、拖出成独立窗口 / 拖回合并、「显示所有标签页」总览（`docs/TODO.md` 的「卡片总览」随之了结）、
  ⌃Tab / ⌃⇧Tab 切换、⌘W 关标签、「关闭其他标签页」「将标签页移到新窗口」「合并所有窗口」菜单项。

## 2. 核心做法：TabsModel 退化为「单标签」，开新标签改为开新窗口

现有跨模块记账全按 `DocSession.id` 走（`MAC-TABS-PLAN.md §1` 那张表），一个标签一扇窗口后**这些一行不用改**，平板协议、MCP 对外接口不改。

改的是「在哪儿开」这一层：

1. `TabsModel` 保留类名与对外接口（避免 27 个文件 / 115 处引用全改），**不变式从「至少一个标签」收紧为「恰好一个」**；
   `tabs` 数组、`activate(offset:)`、`close(_:)`、`closeOthers`、`move`、`canCloseTab` 删除或退化。
2. 新增应用级的 **`TabGroupRouter`**（按工作区），所有 `open*` 的「已开着就切过去 / 当前空着就就地开 / 否则新开」三段统一走它：
   - 查找范围从「本窗口的标签」扩大到「**这个工作区的所有阅读窗口**」，命中就 `makeKeyAndOrderFront`（系统会把那个标签选中）；
   - 当前窗口空着 → 就地装；
   - 否则 → `AppDelegate.makeReaderWindow(…, tabbedInto: 当前窗口)` 新开一扇，装进新窗口的那个标签。
   - 现有 `open` / `openMarkdown` / `openBoard` / `openShared`（含「同目录共用一个标签」）/ `openSchedule` / `openWebDoc`
     六份几乎一样的三段代码收成一个 `place(existing:load:)`。
3. `AppDelegate.showDocument` / `showMarkdown` / `showBoard`（MCP 与 `unireader://` 共用的唯一入口）、平板 `openDoc`、⌘P、侧栏点选
   全部经 router，规则不变：已开着 → 切过去；否则开在 key 的那扇窗口所在组里。
4. 「同目录共用一个标签」（设置里三个开关）保留：共用标签 = 组里某扇窗口，`shareKey` 照旧挂在它的 `DocTabModel` 上，router 跨窗口查找。

## 3. 窗口级状态：哪些在组内同步

一个标签一扇窗口后，侧栏、工具栏、Inspector、Agent / AI 面板**每个标签各一份**。不处理的话切标签时这些会跳（实验包里已能看到）。

| 状态 | 建议 |
|---|---|
| 侧栏开合、宽度 | **组内同步**（同 Safari）：任一窗口改了，组里其他窗口跟着改；新开的标签继承 |
| Inspector 开合、宽度、当前页 | **组内同步** |
| Agent 面板的对话（现按 `windowID` 记，§13 多对话标签条） | **改按工作区记**：否则每开一个标签就是一个空的 Agent 面板 |
| AI 面板（内置网页，按 `windowID` 记宿主） | 按 key 窗口挂（`AIPanelDock` 现有做法），确认切标签时不重载网页 |
| 工具栏 | 系统按同一 identifier 同步「自定工具栏」的配置；开关态（画板 / 夜间等）本来就跟当前会话走 |
| 窗口位置大小 | 标签组统一，系统管 |
| 工具栏「返回」/ ⌘[ ⌘] 跨标签历史（`TabsModel+Navigation`） | 历史挪到组级（router 里按组存），「回到上一处」可以切回另一个标签 |

## 4. 打开集的保存与恢复

- 现状：`TabsModel.persist()` 按工作区存一份「标签顺序 + 活动项 + 共用标记」（`UserDefaults` `tabs:<路径>`，v2），
  `restoreTabs` 冷启动在一扇窗口里恢复（最多 8 个，只装活动的那个）。
- 改为：**保存时按系统标签组顺序**（`window.tabGroup.windows`）把这个工作区所有窗口收成一份列表，活动项 = 组里选中的窗口；
  恢复时第一项装进第一扇窗口，其余每项 `addTabbedWindow` 一扇。
- 🔴 **退出时不能边关边存**：退出过程中逐扇结清，列表会越存越短。沿用 `AppDelegate.isTerminating` 守卫（`persistOpenWindows` 已有同款）。
- 🔴 **后台标签窗口要懒建内容**：恢复 8 个标签 = 一次建 8 扇完整窗口（侧栏、Inspector、阅读窗格…）。
  标签栏只需要标题，所以后台窗口先只建壳（标题、`DocTabModel` 的 `stage`），**第一次被选中时**才建侧栏 / 阅读窗格等视图。
  这一条决定冷启动快不快，第一批就做。
- 同一工作区被拖成两组（两扇独立窗口各带若干标签）：第一版合并成一份列表、恢复成一组；要不要分组记，看实测再定。
- 关掉某工作区的最后一扇窗 → `clearSavedTabs` 照旧。

## 5. 删除与迁移的入口

| 原来 | 改为 |
|---|---|
| 底部标签栏 `+` / ⌘T 弹选文档弹窗 | ⌘T = 系统「新建标签页」→ `newWindowForTab` 开空标签，并在新标签里直接弹选文档弹窗 |
| 标签右键「关闭其他标签」 | 系统菜单项（标签上右键自带） |
| 标签右键「在侧栏中显示」 | 挪进菜单栏（文件 / 显示菜单），快捷键不变 |
| 标签右键「在新窗口打开」 | 系统「将标签页移到新窗口」；侧栏右键改名「在新标签页中打开」 |
| 标签栏形态切换（浮动 / 贴底）与对应设置 | 删除 |
| ⌘⇧[ ⌘⇧] / `activate(offset:)` | 交给系统的「显示上一个 / 下一个标签页」 |
| 各页面底部为标签栏让出的距离（`tabBarInset` / `scrollerLift`，约 12 处） | 删除，滚动条与内容到底 |
| 「⌘W 只剩一个标签时关窗口」 | 天然成立（⌘W 就是关这扇窗口 = 关这个标签） |

## 6. 不改的

- 平板协议、`docs/PROTOCOL.md`、服务器、安卓（安卓模式1 自己的标签页组照旧）。
- `DocTabModel` 的装载 / 落库 / 结清次序（`close()` 里那套）。
- 参考窗、Markdown 独立笔记窗口仍是 `.disallowed`，不进标签组。

## 7. 分批

1. **router + 单标签 TabsModel + 开新窗口**：所有打开路径改走 router；底部标签栏暂时隐藏不删。可实测「开、切、关、MCP / 平板打开」。
2. **恢复 / 保存 + 后台窗口懒建内容 + 退出守卫**。
3. **组内同步**：侧栏、Inspector、Agent 对话改按工作区、跨标签历史。
4. **删除底部标签栏**及其设置、让出的底部距离；菜单入口迁移（§5）。
5. 文档：`AGENTS.md` 文档地图、`docs/agents/STRUCTURE.md`、`MAC-TABS-PLAN.md` 头部标注被本方案取代；`docs/TODO.md` / `HISTORY.md`。

每批编译 + 交用户实测后再进下一批。

## 8. 风险

- **冷启动与内存**：每个标签一整扇窗口的视图树。靠 §4 懒建内容兜住；第 2 批做完要量一次「恢复 8 个标签」的耗时与内存。
- **窗口级单例的假设**：`AIPanelDock`、`AgentPanelModel.noteKeyReader`、`QuickOpenController`、`WorkspaceRegistry` 的根窗口登记
  都默认「一个工作区通常一两扇窗」，现在会是十几扇。逐个过一遍查找逻辑（尤其「找 key 窗口，没有就第一扇」这类挑窗口规则）。
- **工具栏玻璃变色**（`PITFALLS.md`「工具栏」）：切标签 = 换窗口，不会改阅读区外框，预计不触发；实测时留意。

## 9. 实现记录

### 9.1 第 1 + 2 批（2026-11-28，`spike/native-tabs` 分支，用户实测通过）

- **打开**：`TabsModel` 只装一个 `DocTabModel`（`tabs` 数组保留、恒为一个元素，旁人照旧能遍历）；
  `open` / `openMarkdown` / `openBoard` / `openSchedule` / `openWebDoc` 收进 `place(existing:load:)`，`openShared` 同口径；
  `peers`（`AppDelegate.tabPeers`）= 同工作区全部阅读窗口、本组按标签左右顺序在前；`spawn` = `AppDelegate.spawnTab` 在本组新开一扇。
  `focusWindow` = 标签组 `selectedWindow` + `makeKeyAndOrderFront`（**App 不在前台时也要设 key**，否则前台一切过来系统把原来那扇选回去）。
- 🔴 **装进组里另一扇窗口之后，调用方必须对「装着它的那扇」操作**（`AppDelegate.controller(owning:)`）：
  `showDocument` / `showInWorkspace` / `showExercises` / `showSchedule` / MCP `open_document` 指定窗口那一支都改了。
  曾经漏掉 `showExercises`：`openExercises` 已切到另一扇，随后又对原窗口 `makeKeyAndOrderFront`，标签被切回去（习题链接不切标签）。
- **保存**：`persist()` 按组顺序收整个工作区的标签存一份（`tabs:<路径>` v2 不变）；关一个标签由剩下的窗口重存（`AppDelegate.forget`）；
  退出前 `applicationShouldTerminate` 先每个工作区存一次，再置 `isTerminating`（之后 `persist` 不写）。
- **恢复**：上次停的那项装进第一扇、立刻显示；它左边的各项 `addTabbedWindow(.below)` 插在它左边，右边的依次 `.above`（离屏实测：
  `.below` = 左、`.above` = 右；不 `showWindow` 也进组、选中项不变）。
- **后台标签懒建界面**：`ReaderWindowController(lazyChrome:)` 只建壳；`realizeChrome()` 建分栏 / 工具栏 / 工具栏状态订阅 / Agent 预加载。
  触发点 `ReaderNSWindow.beforeShow`：系统切标签先 `makeKey` 再 `order`，那时窗口还没露面（离屏实测）。
  `sidebarItem` / `inspectorItem` / `inspectorVC` / `readerPane` 取值处先 `realizeChrome()`——哪条路径先碰到就当场建，不会取到空值。
- 底部标签栏：第 1 批起不显示、不让底部距离（`showTabs = false`、`tabBarInset = 0`），代码第 4 批删。
  选文档弹窗改挂阅读区顶部正中、工具栏下沿往下弹。
- **⌘N / ⌘T / 系统标签栏「+」同一个动作**（`ReaderWindowController.newTab`，用户定「这两个作用应该是一样的」）：
  当前标签空着就地弹；否则本组新开一个空标签、下一拍在它上面弹（当场弹会被切标签抢走 key、面板随即收起）。
  弹的是 **⌘P 快速打开**（`QuickOpenController.show(for:)`，用户：「弹窗选择太少了…换成 cmd p 那个还可以模糊搜索」），
  选中项落进那个空标签；原来只列 PDF 的选文档弹窗（`DocPickerController.forTabs` / `docPickerPresented`）删除，参考窗选书仍用它。
  ⌘N 菜单名仍叫「新建窗口」（系统「优先使用标签页」时的惯例）。
- **退出耗时**（用户报「退出变慢」，打点实测）：3 扇窗口结清合计 17ms；慢的是服务器工作区「关闭后那一轮」同步约 1.9 秒
  （退出时先结清各窗 → 最后一扇关掉触发完整一轮推 + 拉 → `waitForQuit` 等它），改造前一扇窗口时同样如此，不是本方案引入的。
  用户随即定：加设置「退出前与服务器同步」、默认关（`SERVER-MODE-PLAN.md §13.13`）。

### 9.2 第 3 批（2026-11-28，用户实测通过）

- **切标签时侧栏 / Inspector 不跳**：`ReaderNSWindow.willShow`（`makeKey` 每次都调；`order` 只在还没露面时调）→
  `realizeChrome` + `adoptChromeFromFrontTab`：照**上一个成为 key 的标签**（`TabNavGroup.chromeSource`，须同一标签组）抄 ① 侧栏 / Inspector 开合
  ② 宽度（`setPosition` 绝对值）③ Inspector 当前页 ④ 侧栏展开状态（不同才整棵重建）+ 滚动位置（`SidebarViewController.ViewState`）。
  关掉最前面的标签时 `shutdown` 先留一份（`closedChrome` + 当时同组的其余窗口），给系统接着选中的相邻标签用。
  🔴 第一版按 `isVisible` 找来源、只在「还没露面」时抄，用户实测侧栏滚动 / Inspector 页 / Agent 都不同步：
  标签显示过一次之后切走，窗口 `isVisible` 仍是 true（离屏实测），切回它时根本不进来、找来源也会找到旧标签。
  另：Inspector 页签列表是异步订阅下一拍建的，刚建好的 Inspector 里 `show(tab:)` 会被 `guard tabList.contains` 挡掉——空着时当场建。
- **Agent 对话按工作区记**：`AgentPanelModel` 对外仍收窗口 id，进来经 `groupKey` 换成 `WorkspaceManager.agentChatKey`；
  每扇窗口建好就 `registerReader`（**先于建界面**）；上下文 / `@` 候选 / 工作区取这个工作区眼下最前面的标签（`frontReader`）；
  最后一个标签关掉才结束对话。各窗口的 Inspector 各建一份对话视图（模型共用）——输入框里没发出去的草稿不跨标签。
- **「返回」跨标签**：历史挪到 `WorkspaceManager.tabNav`（`TabNavGroup`：历史 + 回放中标记 + 最前面的标签），`TabsModel.navHistory` /
  `isNavigatingHistory` 转发过去；切标签（窗口成 key）时 `cameToFront` 从上一个标签记「离开的那一处」；关掉的标签不记；
  回放时那个标签还开着（同组任一扇）就 `focusWindow` 切过去，否则按内容重开。

### 9.3 第 4 批（2026-11-28）：删底部标签栏

- 删 `Sources/Reader/Pane/TabBarNSView.swift`（含 `TabChipView` / `HorizontalWheelScrollView`）、`TabBarMetrics.swift`（`TabBarStyle` / `TabBarItem`）、
  离屏样张 `spike/tabbar-look.swift`；`ReaderPaneController` 里的标签栏装配、刷新、摆位、`tabBarInset` / `scrollerLift` 一并删，
  习题 / 日程 / 网页 / 笔架的底部让位不再设（这些视图的 `bottomInset` 属性留着、恒为 0）。`CapsuleMaterialView` 还有查找条等在用，留着。
- `TabsModel` 删 `close(_:)` / `closeOthers` / `move` / `activate(offset:)` / `canCloseTab`；文档 / 画板 / 习题被删时只退回空态（不替用户关窗口）；
  ⌘W = `performClose`。
- 「在侧栏中显示当前标签」菜单栏早就有（⌘⇧J），不用挪。5 条只给标签栏用的文案从两份 `Localizable.strings` 删掉。
- 偏好键 `tabBarStyle` 不再读，留在用户的 UserDefaults 里无害。

### 9.4 第 5 批（2026-11-28）：文档

`AGENTS.md` 文档地图加本方案；`docs/agents/STRUCTURE.md` 加「标签 = 系统窗口标签」一条、改窗格 / 返回历史两条；
`MAC-TABS-PLAN.md` 头部标注被取代；`HISTORY.md` 归档。
