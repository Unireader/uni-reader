# APPKIT-WINDOW-PLAN — 窗口层迁到 AppKit

> 2026-09-01 用户拍板：「我们迁移吧，AppKit 在功能上还是要多太多了。」
> 本文是方案与执行清单；落地后按项目惯例把已完成条目迁进 `HISTORY.md`。

## 0. 一句话

**窗口壳归 AppKit，内容仍是 SwiftUI。** `NSWindow` / `NSToolbar` / `NSMenu` / 分栏容器由我们自己建、
自己管生命周期；阅读区、侧栏、Inspector、各浮层照旧是 SwiftUI 视图，装在 `NSHostingController` 里。
**模型层一行不动。**

## 1. 为什么（账本，都是有案可查的）

疼的不是 SwiftUI，是**「SwiftUI 拥有窗口」**这一件事。这个项目为它付过的账：

| 症状 | 现在的补丁 | 出处 |
|---|---|---|
| app 每次激活凭空多开一个空窗口 | `RootView.isStrayWindow` 自毁闸 + `WindowCloser`（还得赶在 orderFront 之前，否则用户看得见闪一下） | 2026-07-29，四条来源全排除过 |
| `onDisappear` 在窗口建立过程中空放一次；Cmd-Q 也触发 | `WindowLifecycle`（`willCloseNotification`）+ `AppDelegate.isTerminating` 守卫 | 同上 |
| ⌘W 抢不过 AppKit 自带的「文件 › 关闭」 | `installCloseTabHotkey` keyDown 本地监视器 | 2026-08-29 |
| 冷启动 `isKeyWindow` 全为假 | 初始内容决策锚到 `applicationDidFinishLaunching` + 一次性缓冲 `consumePendingWorkspace` | 2026-07-29 |
| 会话 ↔ 窗口的对应关系 SwiftUI 不给 | `WorkspaceRegistry` 自己记两张表（`windowsBySession` / `rootWindows`） | — |
| AI 面板要吸附到宿主窗口 | `AIPanelDock` 找 `NSWindow` | — |
| `.toolbar(id:)` 不开 `allowsUserCustomization`，且被反复拍回 | `ToolbarCustomizationEnabler`（KVO + didUpdate 双保险）+ `ToolbarDelegateFilter` | 2026-09-01 |

对照组：**内容层几乎没打过补丁**——阅读区页流、笔迹、草稿纸、参考窗、跳转历史，全是纯 SwiftUI 写下来的。
所以边界划在「壳 / 内容」之间，而不是「AppKit / SwiftUI」之间。

## 2. 边界

| 归 AppKit | 仍是 SwiftUI | 完全不动 |
|---|---|---|
| `@main` 与 `NSApplicationDelegate` | 侧栏 `SidebarView` | `AppModel` |
| 主菜单（代码构建 `NSMenu`） | 阅读区 `PageStreamView` 全家 | `WorkspaceManager` / `WorkspaceRegistry` |
| `NSWindow` 的建立/关闭/身份/激活 | `InspectorView` | `TabsModel` / `DocTabModel` / `DocSession` |
| `NSToolbar` + delegate（含搜索项） | 标签栏、AI 内置层、参考窗、跳转历史、草稿纸 | `LibraryStore` 与全部 `Sources/Store/` |
| 分栏容器 `NSSplitViewController` | 设置页 `SettingsView`（装进自己的窗口） | `Sources/Server/`、协议与 schema |

## 3. 目标结构

```
main.swift                     @main → NSApplicationMain
App/AppDelegate.swift          现有的那个，扩出窗口路由与菜单
App/MainMenu.swift             代码构建主菜单（文件/编辑/显示/窗口/帮助）
Window/ReaderWindowController  NSWindow + NSToolbar + NSSplitViewController
    ├─ sidebar   NSHostingController(SidebarView)
    ├─ content   NSHostingController(ReaderDetail)      ← 现 ContentView 去掉分栏/工具栏/searchable
    └─ inspector NSHostingController(InspectorView)
Window/ReaderToolbar.swift     NSToolbarDelegate：items / 分组 / allowed / 搜索项
Window/SettingsWindowController
Window/AIPanelWindowController
```

**一扇窗口一个 `ReaderWindowController`**，它持有本窗口的 `WorkspaceManager`（沿用
`WorkspaceRegistry.acquire`，同路径共享实例这条规则**不变**）与 `TabsModel`。
`RootView` 的职责（决定本窗属于哪个工作区）整体搬进 controller 的 `init`——那里是同步的、
没有「body 求值 vs onAppear」的时序问题，`isStrayWindow` 那套判定连同它的四条判据一起删掉。

## 4. 逐条对账：迁移后谁负责

| 现在 | 迁移后 |
|---|---|
| `RootView.isStrayWindow` + `WindowCloser` | **删**。窗口只在我们调用时才建，不存在凭空多出来的 |
| `WindowLifecycle`（willClose） | `NSWindowDelegate.windowWillClose` |
| `TabsModel.closeWindow()` 的调用点（`onDisappear`） | `windowWillClose`（次序照旧：掐尾随补存 → 补落库 → 存进度 → 退出打开集 → 注销会话 → 放引用） |
| ⌘W keyDown 监视器 | `NSMenuItem` + `validateMenuItem`（关标签 / 只剩一个时关窗） |
| 菜单命令走 `NotificationCenter` 广播 + `isKeyWindow` 认领 | 菜单直连**第一响应者链**，key 窗口的 controller 天然认领 |
| `AppDelegate.pendingWorkspacePath` 一次性缓冲 + `didFinishLaunching` 时序 | 直接在 `application(_:open:)` 里建窗口；启动阶段的判定不再和视图生命周期赛跑 |
| `WorkspaceRegistry.rootWindows` / `windowsBySession` | 保留（跨窗口记账仍需要），但 `noteWindowObject` 那条异步回填链路可以简化 |
| 工具栏三处兜底 | **删**。`NSToolbar` 是我们建的：`allowsUserCustomization`、allowed 清单、`NSToolbarItemGroup` 分组全归自己 |
| `.searchable` | `NSSearchToolbarItem`，文本绑 `DocSession.searchQuery` |
| `AIPanelDock` 找宿主窗口 | 直接从 `ReaderWindowController` 拿 |

## 5. 里程碑

- **M0 骨架**：`main.swift` + 主菜单 + `ReaderWindowController`（三段分栏 + 空工具栏），
  能开出一扇窗显示现有阅读内容。此时 SwiftUI Scene 全部下线。
- **M1 窗口路由与身份**：多工作区并存、双击 `.unrd` / Dock 菜单 / 最近打开、⌘N/⌘T/⌘W/⌃Tab、
  冷启动恢复标签组（沿用 `TabsModel.restoreTabs`）。
- **M2 工具栏**：`ReaderToolbar` 自己的 delegate——四组用 `NSToolbarItemGroup`、搜索用
  `NSSearchToolbarItem`、allowed 清单干净、「自定工具栏…」天然可用（**item id 沿用现有那 11 个**，
  用户已摆好的配置不作废）。
- **M3 拆补丁**：删 `WindowCloser`/`WindowLifecycle`/`isStrayWindow`/⌘W 监视器/
  `ToolbarCustomizationEnabler`/`ToolbarDelegateFilter`，`RootView` 整个删掉。
- **M4 其余窗口**：设置窗（⌘,）、AI 面板浮窗（保持「全局唯一」语义）。
- **M5 回归**：按 §7 清单真机过一遍。

## 5.1 落地记录（2026-09-01）

**M0 / M1 / M2 / M3 已完成并经用户真机验证**，剩 M4（辅助窗口的细节）与 M5（完整回归）。
以下是过程中**只有真机才能发现**的坑，逐条记在这里——同类问题下次直接查表：

| 症状 | 根因 | 修法 |
|---|---|---|
| ⌘T 开空标签，整扇窗当场缩成一小块；窗口尺寸也不恢复 | `NSHostingController` 默认把 SwiftUI 内容的 fitting size 报成 `preferredContentSize`，AppKit 拿它调整窗口；autosave 的尺寸随之被覆盖 | 三段一律 `sizingOptions = []` |
| 侧栏开关跑到工具栏右边去了 | 少了 `.sidebarTrackingSeparator` —— 它是「侧栏区 ↔ 内容区」的分界 | default/allowed 里补上，摆在 `toggleSidebar` 之后 |
| 侧栏没顶到窗口顶部（不是现代侧栏） | 窗口 styleMask 缺 `.fullSizeContentView`，内容区从标题栏下方才开始 | 补上；现代侧栏要三件齐备：这条 + `sidebarWithViewController` + `sidebarTrackingSeparator` |
| 侧栏「不沉浸」（不透明底、方角选中行） | 原先在 `NavigationSplitView` 的 sidebar 位置上 SwiftUI 自动套 `.sidebar` 外观，装进 hosting controller 后没人替它决定 | 显式 `.listStyle(.sidebar)` + `.scrollContentBackground(.hidden)`（后者是另一半：List 那层不透明底会挡住 `NSSplitViewItem` 的侧栏材质） |
| **工具栏的 popover 全弹到标题栏上方老远处** | **`NSToolbarItemViewer` 里那个 `NSButton` 是翻转坐标系**（日志实测 `翻转=true`），翻转视图里 `.maxY` 才是**视觉下边**——照搬「非翻转时 minY 在下」的直觉正好反了 | `preferredEdge: .maxY`；顺带把 `p.contentSize = vc.view.fittingSize` 给死，尺寸不定的 popover 定位也会跑偏 |

**M4（辅助窗口）另有三条**，都在「AppKit 工具栏 vs SwiftUI 习惯」的接缝上：

| 症状 | 根因 | 修法 |
|---|---|---|
| AI 浮窗**整条工具栏不见了** | `AIPanelView` 那条 `.toolbar { }` 是 SwiftUI 的，只作用于 SwiftUI 自己创建的窗口，装进 `NSHostingController` 后对 AppKit 窗口无效 | 工具栏改由 `AIPanelWindowController` 建 `NSToolbar`；平台/更多两枚用 `NSMenuToolbarItem` + `menuNeedsUpdate` 按需重建 |
| 画板/夜间/参考窗/置顶这些**开关看不出状态** | ① 只换 SF Symbol 的 fill 变体差别太小；② **带 view 的 item 拿不到 `validateToolbarItem`** —— AppKit 对 view-based item 不走那条校验，写在那里的图标切换代码根本没执行 | 改 `pushOnPushOff` 让系统画按下态；状态由自己推（`refreshToolbarStates`），挂在 `tabs.objectWillChange` / 浮窗 model 的 `objectWillChange` / `UserDefaults.didChangeNotification` 上 |
| 工具栏图标偏大、顶到上下边缘、标题栏跟着高 | 不给 symbol configuration 时用默认大号；换成死的 `pointSize` 仍偏大 | 用 `.init(scale: .small)` —— 让符号按系统给的上下文自己缩 |

🔴 最后一条值得单独记住：**工具栏这一层的坐标系与常识相反**。当时连试两个方向都不对，是靠在
`present` 里打一行锚点日志（bounds / 窗口内矩形 / `isFlipped` / 有没有窗口）才定位的——
「面板跑到很高的地方」有两种完全不同的成因（边选反了 vs 锚点 view 根本不对），
不打点分不清，这正是本项目「静默失效先打点再改码」那条纪律的又一例。

M3 顺带删掉的（迁移让它们变成死代码）：`WindowCloser`、`ToolbarCustomizationEnabler`、
`ToolbarDelegateFilter`、`WorkspaceRegistry.hasOtherRootWindow`。
`WindowLifecycle`/`WindowAccessor`/`WindowLevelAccessor` **保留**——AI 浮窗那个 SwiftUI 视图还在用，
等 M4 把它也收进 `AIPanelWindowController` 再说。

## 6. 红线

- **阅读区纯 SwiftUI 不变**：内容层一行不改，只是外面套 `NSHostingController`。
- **不自绘系统样式**：分栏用 `NSSplitViewController`，侧栏用 `NSSplitViewItem(sidebarWithViewController:)`，
  Inspector 用 `NSSplitViewItem(inspectorWithViewController:)`，搜索用 `NSSearchToolbarItem`——
  系统渲染成什么样就什么样。
- **同一工作区路径共享同一个 `WorkspaceManager`**（`REQUIREMENTS.md §8.1` 第一条红线）不变。
- **关工作区 = 当场放掉全部文件引用**，`DocTabModel.close()` 里那套次序原样保留，只换触发点。
- **协议与 schema 一个字节不改**；平板三端不受影响。
- **工具栏 item 的 id 不变**（`zoom.out`…`inspector`），否则用户刚摆好的自定义白摆。

## 7. 验证清单（真机，M5）

1. 冷启动：普通启动 / 双击 `.unrd` 拉起 / Dock 菜单拉起，各开出**恰好一扇**正确的窗口（老 bug 是多一扇空的）；
2. 热启动：双击另一个 `.unrd` = 新窗口，原窗口不动；双击已打开的 = 激活那扇；
3. 多工作区并存：两扇窗各自的库互不串（笔记不丢，这是 §8.1 那笔账）；
4. 标签：⌘T/⌘W/⇧⌘W/⌃Tab、关最后一个标签才关窗、冷启动恢复标签组与活动标签；
5. 关窗：进度落库、移动硬盘能立刻弹出（引用全放掉）；
6. 菜单：全部快捷键在正确的窗口生效；文本编辑上下文里 ⌘C/⌘V/⌘A 仍是系统语义；
7. 工具栏：四组胶囊、自定工具栏面板（增删/排序/仅图标）、搜索框、配置重启后还在；
8. AI 面板吸附、参考窗、跳转历史窗、草稿纸四个浮层与新窗口壳的层次关系；
9. 全屏、多显示器、窗口最小尺寸；
10. Cmd-Q：`applicationShouldTerminate` 那条收缩链路照旧（`isTerminating` 守卫的语义在新壳下重新确认）。

## 8. 回退

独立分支开发；合并前给当前 SwiftUI 版本打 tag。M0~M2 之间任何一步觉得不对，回到 tag 即可——
模型层没动过，回退不会丢数据层的任何改动。
