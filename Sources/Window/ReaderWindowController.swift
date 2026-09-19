import AppKit
import Combine
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

/// 本窗口的「外壳状态」——内容层要知道、但不属于任何模型的那几样。
///
/// 单独一个 `ObservableObject` 而不是塞进 `DocSession`：它是**窗口级**的（一扇窗一份），
/// 而会话是**标签级**的（一个标签一份）。阅读区要的 `isActiveWindow` 正是窗口级。
@MainActor
final class WindowChrome: ObservableObject {
    @Published var isKeyWindow = false
    /// 侧栏/Inspector 的折叠态由 `NSSplitViewItem` 说了算，这里只做镜像，供内容层排版参考。
    @Published var inspectorOpen = false
}

/// 一扇阅读窗 = 一个 controller（方案 `APPKIT-WINDOW-PLAN.md` §3）。
///
/// 它持有本窗口的 `WorkspaceManager`（同路径共享同一实例这条红线不变，仍走
/// `WorkspaceRegistry.acquire`）与 `TabsModel`，并负责：窗口生命周期、三段分栏、工具栏、
/// 菜单命令的认领、以及原先散在 `ContentView` 里的那批**窗口级动作**（开 PDF / 选工作区 / 重定位…）。
///
/// 🔴 `RootView` 那套「本窗口属于哪个工作区」的判定整体搬到了 `AppDelegate.openReaderWindow`——
/// 那里是同步的，不再有「body 求值 vs onAppear」的时序问题，`isStrayWindow` 连同它的四条判据
/// 一起删掉了（窗口只在我们调用时才建，没有凭空多出来的）。
@MainActor
final class ReaderWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate {

    let app: AppModel
    let workspace: WorkspaceManager
    let tabs: TabsModel
    let chrome = WindowChrome()

    /// 两个浮窗的窗口级状态（切标签不重建，正是它们要的）。
    private let refWindow = RefWindowModel()
    private let jumpPanel = JumpHistoryPanel()
    /// 参考窗的独立窗口形态（`refWindow.mode == .window` 且开着时才存在，关掉即销毁——
    /// 位置/尺寸靠 frame autosave 记，下次重建照旧）。
    private var refWindowController: RefWindowController?

    /// 在 `WorkspaceRegistry` 的登记号（关窗时按它归还工作区实例）。MCP 的 `window_id` 也用它（`MCPFacade`）。
    let windowId = UUID()
    private var bag = Set<AnyCancellable>()
    private var didChooseInitialDoc = false
    /// 已结清过（见 `shutdown()`）。
    private var didShutdown = false

    private let splitVC = NSSplitViewController()
    /// 当前弹着的面板（目录/OCR/平板共用一个，一次只开一个）。
    private var popover: NSPopover?
    /// 搜索项（⌘F 要让它进入编辑态，校验时也要同步文本）。
    private var searchItem: NSSearchToolbarItem?
    /// 工作区菜单项（标题要跟着工作区名走）。
    private var workspaceItem: NSMenuToolbarItem?
    private var zoomItem: NSToolbarItemGroup?
    private var sidebarItem: NSSplitViewItem!
    private var inspectorItem: NSSplitViewItem!
    /// 阅读窗格（AppKit）。
    private var readerPane: ReaderPaneController?

    private var session: DocSession { tabs.active.session }

    // MARK: - 建窗

    init(app: AppModel, workspace: WorkspaceManager, launchDocId: String?) {
        self.app = app
        self.workspace = workspace
        self.tabs = TabsModel(app: app, workspace: workspace)

        // 🔴 **`.fullSizeContentView` 不能省**：没有它，内容区从标题栏**下方**才开始，侧栏就被切在
        // 标题栏之下——2026-09-01 用户报的「侧边栏不是 macOS 新版本的（没顶到窗口顶部）」。
        // 现代侧栏（Finder/Mail 那样一路延伸到顶、标题栏浮在它上面）要三件齐备：这条 styleMask、
        // `NSSplitViewItem(sidebarWithViewController:)`（下面）、以及工具栏里的
        // `.sidebarTrackingSeparator`。内容的安全区由 AppKit 自动下推，SwiftUI 那边照旧遵守。
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 860),
                           styleMask: [.titled, .closable, .miniaturizable, .resizable,
                                       .fullSizeContentView],
                           backing: .buffered, defer: false)
        win.tabbingMode = .disallowed   // 我们自己有标签栏（`MAC-TABS-PLAN.md`），别再叠一层系统标签
        win.minSize = NSSize(width: 720, height: 480)
        // 🔴 **窗口后备存储用 sRGB，与页图（`PageBitmap`：sRGB + BGRX）同一个色彩空间**（2026-09-13 实测定）。
        // 默认值是所在显示器的 ICC（Color LCD / 外接屏各自一套）：一不相等，SwiftUI 显示每张页图都要经
        // `_SwiftUIProxyImage prepare → CA::Render::create_image_by_rendering` 用 CG 整张**重画一遍做色彩转换**——
        // 一张 2800px 页图除了我们的 mmap 缓冲，还多出 CA 副本 41.7MB + CG 给源图挂的转换缓存 43.7MB
        //（purgeable zone、非 volatile、不随页图释放，攒到 CG 自己的上限才丢）。平板驱动阅读区跟随时
        // 页图进出频繁，10 秒就攒出 600MB（用户报「连接设备后内存飙升」，`malloc_history` 抓到的栈）。
        // 两边同为 sRGB，CA 直接引用我们的缓冲：零副本、零转换、prepare-image 线程也不再烧 CPU；
        // 显示器色彩匹配由窗口服务器在合成时做（GPU），观感不变。对照实验：`spike/window-colorspace-probe.swift`。
        win.colorSpace = .sRGB
        // 系统的窗口状态恢复照旧关掉：本 app 自己管着「上次开了哪些文档」（每个工作区的打开集 →
        // restoreTabs），系统再恢复一遍是重复的。迁移前这是 `.restorationBehavior(.disabled)`。
        win.isRestorable = false
        super.init(window: win)

        buildPanes()
        win.contentViewController = splitVC
        win.delegate = self
        win.toolbarStyle = .unified
        win.toolbar = makeToolbar()
        adoptNewToolbarItems()

        WorkspaceRegistry.shared.noteRootWindow(windowId)
        WorkspaceRegistry.shared.bindRootWindow(windowId, workspace)
        tabs.noteWindowObject(win)

        bindTitle()
        observeToolbarStates()
        observeMenuCommands()
        decideInitialContent(launchDocId: launchDocId)

        // ⚠️ `NSWindowController.shouldCascadeWindows` 默认 true，`showWindow` 时会**覆盖**
        // 我们刚恢复的位置（AppKit 文档原话：设了 frame 记忆就该把它关掉）。多开时的错位由
        // `AppDelegate.openReaderWindow` 自己做。
        shouldCascadeWindows = false
        restoreFrame(win)
        frameRestored = true
        logFrame("init 末")
    }

    /// 两侧栏的最小宽度（pt）。用户 2026-09-03 定：原来的 200/240 太窄，信息页里
    /// 「Title / Last Opened」这类左键右值的行挤成两截。
    ///
    /// 用 `minimumThickness` 而不是给 SwiftUI 内容加 `.frame(minWidth:)`：这一处同时管住
    /// **初始宽度**（AppKit 展开一栏至少给到最小厚度）和**拖动下限**，而且四个页签
    /// （信息/目录/笔记/AI）一视同仁——挂在某个页签的内容上就只有那一页撑得开。
    ///
    /// 🔴 **不做跨重启的宽度记忆**（2026-09-03 用户明确否决）：`setPosition`（要等布局稳定，
    /// 早于上屏调就被抹掉）、`preferredThicknessFraction`（初始布局吃、**展开时不吃**）、
    /// 宽度约束（priority 压在 `holdingPriority` 之下）三条路都试过，
    /// 「先动画展到默认宽、再瞬间跳到记忆宽」那下补偿始终甩不掉，观感不合格。想再做先解决这个。
    private static let paneMinWidth: CGFloat = 300

    /// 所有阅读窗共用一个 frame 记忆名（多开时靠 `AppDelegate` 错开摆位）。
    static let frameAutosaveName = "UniReaderReaderWindow"
    /// 初始 frame 已经定好了 —— 在此之前不许存（见 `saveFrame`）。
    private var frameRestored = false

    /// 恢复上次的窗口尺寸与位置。
    ///
    /// 🔴 **不能用 `setFrameAutosaveName`**（2026-09-02 用户报「关掉窗口再开就变成中小尺寸」，
    /// 日志实证）：那个名字要求**整个 app 内唯一**，而「关掉再开一扇」时旧 `NSWindow` 往往还没
    /// 析构、名字仍被它占着 —— 第二扇拿到 `false`，于是**既不恢复、以后也不自动存**，窗口就停在
    /// `contentViewController` 把它压下去的 `minSize`（720×500）。日志原文：第一扇
    /// `autosave=true` frame 1442×854，第二扇 `autosave=false` frame 720×500。
    ///
    /// 改成两头自己管：这里显式 `setFrameUsingName`（不看名字归谁，任何时候都生效），
    /// 存挂在 `windowDidResize`/`windowDidMove`/`shutdown` 上。键与 AppKit 那套完全一样
    /// （`NSWindow Frame <名字>`），老用户存下的尺寸原样接着用。
    private func restoreFrame(_ win: NSWindow) {
        guard !win.setFrameUsingName(Self.frameAutosaveName) else { return }
        // 从没记过（首次运行）→ 给个像样的初始尺寸再居中。**不能就这么让它去**：
        // `contentViewController` 已经把窗口压到 minSize 了，不管就是一扇 720×500 的小窗。
        win.setContentSize(NSSize(width: 1280, height: 860))
        win.center()
    }

    /// 记住窗口尺寸与位置。理由见 `restoreFrame` 的红线——AppKit 那套在名字被占用时不替我们存。
    private func saveFrame() {
        guard frameRestored, let w = window,
              !w.styleMask.contains(.fullScreen)   // 全屏时 frame = 整块屏，记下来下次会开出一扇巨窗
        else { return }
        w.saveFrame(usingName: Self.frameAutosaveName)
    }

    func windowDidResize(_ notification: Notification) { saveFrame() }
    func windowDidMove(_ notification: Notification) { saveFrame() }

    /// 窗口尺寸这条链路的打点（`~/Library/Logs/UniReader-ws.log` 存在时才写）。
    /// 「关掉窗口再开就变小」这类问题只能靠它定位：是恢复没生效，还是恢复完又被谁改了。
    private func logFrame(_ tag: String) {
        guard let w = window else { return }
        let saved = UserDefaults.standard.string(forKey: "NSWindow Frame \(Self.frameAutosaveName)") ?? "无"
        wsLog(String(format: "窗口 %@：frame=%.0f,%.0f %.0fx%.0f 屏=%.0fx%.0f 存档=[%@]",
                     tag, w.frame.minX, w.frame.minY, w.frame.width, w.frame.height,
                     w.screen?.frame.width ?? 0, w.screen?.frame.height ?? 0, saved))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) 不支持——窗口一律由代码建") }

    /// 关窗结清后 controller 本身应当立刻释放（`AppDelegate.forget` 放掉最后一个强引用）。
    /// 没来这一行 = 又有谁攥着它；来了但 `TabsModel 释放` 没来 = 窗口对象图里还有环（见 `TabsModel.window`）。
    deinit { wsLog("ReaderWindowController 释放") }

    /// 三段分栏：侧栏 / 阅读区 / Inspector，各装一个 `NSHostingController`。
    ///
    /// 🔴 用 `NSSplitViewController` 而不是继续套 `NavigationSplitView`：后者会往
    /// `window.toolbar` 里塞侧栏按钮和搜索框，等于又来抢工具栏——那正是这次迁移要根除的
    /// （方案 §2）。侧栏/Inspector 用系统的 `sidebarWithViewController` /
    /// `inspectorWithViewController`，观感与折叠动画都是系统的，不自绘。
    private func buildPanes() {
        // 侧栏：AppKit（`APPKIT-REWRITE-PLAN.md` 第 4 步，替代 SwiftUI `SidebarView`）
        let sidebar = SidebarViewController(tabs: tabs, workspace: workspace)
        sidebar.onChooseWorkspace = { [weak self] in self?.chooseWorkspace() }
        sidebar.onCreateWorkspace = { [weak self] in self?.createNewWorkspace() }
        sidebar.onOpenRecent = { [weak self] in self?.openRecentWorkspace($0) }
        sidebar.onDropFiles = { [weak self] in self?.ingest(urls: $0) }
        sidebar.onOpenPDF = { [weak self] in self?.openPDF() }
        sidebar.onOpenInNewWindow = { [weak self] docId in
            guard let self else { return }
            AppDelegate.shared?.openReaderWindow(workspacePath: self.workspace.folder?.standardizedFileURL.path, docId: docId)
        }

        // 阅读窗格：AppKit（`APPKIT-REWRITE-PLAN.md` 第 3 步，替代 SwiftUI `ReaderPane`）
        let content = ReaderPaneController(tabs: tabs, chrome: chrome, refWindow: refWindow, jumpPanel: jumpPanel,
                                           app: app, workspace: workspace)
        content.onRelocate = { [weak self] doc in self?.relocate(doc) }
        content.onIngest = { [weak self] urls in self?.ingest(urls: urls) }
        readerPane = content

        // Inspector：AppKit（第 4 步，替代 SwiftUI `InspectorView`）
        let inspector = InspectorViewController(tabs: tabs, workspace: workspace)

        // 🔴 **三段都要关掉尺寸传播**：`NSHostingController` 默认把 SwiftUI 内容的 fitting size
        // 报成 `preferredContentSize`，AppKit 于是拿它去调整窗口——2026-09-01 用户实测的两个症状
        // 都是它：⌘T 开一个空标签（内容只有一个 `ContentUnavailableView`）整扇窗当场缩成一小块；
        // autosave 存下来的窗口尺寸也会被这一下覆盖，看起来就是「窗口大小没恢复」。
        // 窗口尺寸该由 autosave 和用户拖动决定，内容只负责填满给它的地方。
        // （三个 hosting controller 的泛型参数各不相同，装不进同一个数组，只能逐个设。）

        sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sidebarItem.allowsFullHeightLayout = true   // 侧栏一路铺到标题栏后面（默认就是 true，写明意图）
        sidebarItem.minimumThickness = Self.paneMinWidth
        sidebarItem.maximumThickness = 420
        let contentItem = NSSplitViewItem(viewController: content)
        contentItem.minimumThickness = 400
        // macOS 26：侧栏/Inspector 叠在内容之上，被遮住的宽度以 `safeAreaInsets` 交给内容。
        // 这一行是**唯一**的改动——先看 AppKit + 现有阅读区代码的原生默认表现，再决定要不要动几何。
        contentItem.automaticallyAdjustsSafeAreaInsets = true
        inspectorItem = NSSplitViewItem(inspectorWithViewController: inspector)
        inspectorItem.minimumThickness = Self.paneMinWidth
        inspectorItem.maximumThickness = 400
        inspectorItem.isCollapsed = true

        splitVC.addSplitViewItem(sidebarItem)
        splitVC.addSplitViewItem(contentItem)
        splitVC.addSplitViewItem(inspectorItem)
    }

    // MARK: - 标题

    /// 标题 = 文档名，副标题 = 当前页/总页数。
    /// 迁移前这是 `navigationTitle`/`navigationSubtitle`（SwiftUI 接管标题栏后不许再直写
    /// `window.title`）；现在窗口是我们的，直写即可，那条禁令随之作废。
    private func bindTitle() {
        tabs.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshTitle() }
            .store(in: &bag)
        refreshTitle()
    }

    private func observeToolbarStates() {
        refWindow.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshToolbarStates() }
            .store(in: &bag)
        // 参考窗的独立窗口按 model 开合：开着且是窗口形态 → 有这扇窗；否则没有。
        // model 是唯一真源——覆盖层顶栏的「弹出」、独立窗口工具栏的「改回内置」、工具栏开关、
        // 红色关闭钮，全都只改 model，窗口的存在与否由这一条订阅统一推。
        Publishers.CombineLatest(refWindow.$isOpen, refWindow.$mode)
            .receive(on: RunLoop.main)
            .sink { [weak self] open, mode in self?.syncRefWindow(open: open, mode: mode) }
            .store(in: &bag)
        jumpPanel.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshToolbarStates() }
            .store(in: &bag)
        // Agent / 咨询 AI 两枚开关：内置侧栏开合、形态切换（模型发布），独立窗口显示 / 隐藏 / 关闭（通知）
        let agent = AgentPanelModel.shared, consult = AIPanelModel.shared
        Publishers.Merge4(agent.$inlineOpenWindows.map { _ in () }, agent.$mode.map { _ in () },
                          consult.$inlineOpenWindows.map { _ in () }, consult.$mode.map { _ in () })
            .merge(with: NotificationCenter.default.publisher(for: .auxPanelVisibilityChanged).map { _ in () },
                   agent.$enabled.map { _ in () }, consult.$enabled.map { _ in () })
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.refreshToolbarStates() }
            .store(in: &bag)
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshToolbarStates() }
            .store(in: &bag)
    }

    private func refreshTitle() {
        let s = session
        // 只在真变了时写（标题 / 副标题在 Tahoe 上画在工具栏里，写一次可能让工具栏重排）；写了记一行 `[TB]`
        let title = s.title.isEmpty ? L("Library") : s.title
        let subtitle = s.pdf.map { "\(s.currentPageIndex + 1)/\($0.pageCount)" } ?? ""
        if let w = window, w.title != title || w.subtitle != subtitle {
            wsLog("[TB] 窗口标题 → \(title) · \(subtitle)")
            if w.title != title { w.title = title }
            if w.subtitle != subtitle { w.subtitle = subtitle }
        }
        refreshToolbarStates()   // 会话的任何变化都过这里，画板模式的按下态跟着刷
    }

    // MARK: - 菜单命令（本窗口是 key 才认领）

    /// 认领条件从 `ContentView` 的 `isKeyWindow` @State 换成直接问窗口——同一个语义，
    /// 但不再依赖视图的异步回填（冷启动时那份 @State 全是假，正是老 bug 的根因之一）。
    private var isKey: Bool { window?.isKeyWindow == true }

    private func on(_ name: Notification.Name, _ action: @escaping (ReaderWindowController) -> Void) {
        NotificationCenter.default.publisher(for: name)
            .sink { [weak self] _ in
                guard let self, self.isKey else { return }
                action(self)
            }
            .store(in: &bag)
    }

    private func observeMenuCommands() {
        on(.openPDFRequested) { $0.openPDF() }
        on(.newWindowRequested) { c in
            AppDelegate.shared?.openReaderWindow(
                workspacePath: c.workspace.folder?.standardizedFileURL.path, docId: nil)
        }
        on(.newTabRequested) { $0.tabs.docPickerPresented = true }
        on(.closeTabRequested) { $0.closeTabOrWindow() }
        on(.closeWindowRequested) { $0.window?.performClose(nil) }
        on(.nextTabRequested) { $0.tabs.activate(offset: 1) }
        on(.prevTabRequested) { $0.tabs.activate(offset: -1) }
        on(.toggleSidebar) { $0.sidebarItem.animator().isCollapsed.toggle() }
        on(.toggleInspector) { $0.toggleInspector() }
        on(.toggleRefWindow) { $0.toggleReference() }
        // ⌘F：让工具栏的搜索框进入编辑态（迁移前是 `.searchable` 的 isPresented）
        on(.readerFind) { $0.searchItem?.beginSearchInteraction() }

        // 平板请求打开工作区里尚未打开的文档 → 在它跟随的那扇窗口里开新标签
        app.$padOpenDocRequest
            .compactMap { $0 }
            .receive(on: RunLoop.main)
            .sink { [weak self] req in
                guard let self, self.tabs.owns(req.sessionID) else { return }
                self.app.padOpenDocRequest = nil
                _ = self.tabs.open(req.docId)
            }
            .store(in: &bag)

        // 文档被删除/改名 → 标签与平板书库跟着变
        workspace.$documents
            .receive(on: RunLoop.main)
            .sink { [weak self] docs in
                guard let self else { return }
                self.tabs.pruneMissing(docs)
                self.tabs.syncWorkspaceSnapshot()
                self.app.broadcastLibrary()
                // `docs` 每项带工作区名（客户端按它分组），而那个名字就是刚 sync 进去的快照
                self.app.broadcastDocs()
            }
            .store(in: &bag)
    }

    func toggleInspector() {
        inspectorItem.animator().isCollapsed.toggle()
        chrome.inspectorOpen = !inspectorItem.isCollapsed
    }

    /// ⌘W：**关当前标签**，只剩一个标签时才关窗口（同 Safari / Xcode）。
    /// 🔴 迁移后这条不再需要 keyDown 监视器去抢——菜单项是我们自己的，AppKit 那个「文件 › 关闭」
    /// 压根不存在了（2026-08-29 那笔账就此了结）。
    func closeTabOrWindow() {
        if tabs.canCloseTab { tabs.close(tabs.activeID) }
        else { window?.performClose(nil) }
    }

    // MARK: - 窗口生命周期

    func windowDidBecomeKey(_ notification: Notification) {
        chrome.isKeyWindow = true
        app.setActive(session)
        AIPanelDock.shared.setHost(window)
        AIPanelDock.agent.setHost(window)
        if AIPanelModel.shared.mode == .inline {
            AIPanelModel.shared.setActiveHost(.inline(session.windowID))
        }
        AgentPanelModel.shared.noteKeyReader(self)
    }

    func windowDidResignKey(_ notification: Notification) { chrome.isKeyWindow = false }

    /// 关窗结清。次序与迁移前的 `ContentView.onDisappear` **完全一致**（那套次序有讲究，
    /// 全在 `DocTabModel.close()` 里写着）——只是触发点从 SwiftUI 的生命周期换成了
    /// AppKit 的 `windowWillClose`，而后者每扇窗口只发一次、就是关闭那一刻。
    func windowWillClose(_ notification: Notification) { shutdown() }

    /// 本窗口的全部结清动作。**两个触发点共用同一份次序**：正常关窗（`windowWillClose`）
    /// 与 ⌘Q 退出（`AppDelegate.applicationShouldTerminate` 逐扇调）。
    ///
    /// 🔴 **AppKit 退出根本不关窗**：`NSApp.terminate:` 问完 `applicationShouldTerminate`
    /// 就直接发 `willTerminate` 并结束进程，**一扇窗的 `windowWillClose` 都不发**。
    /// 迁移前这条链路是 SwiftUI 的 `onDisappear` 兜着的（它在 ⌘Q 时**会**触发——代码里为此
    /// 还专门有 `AppDelegate.isTerminating` 守卫去区分「退出关窗」和「⌘W 关窗」），
    /// 换成 AppKit 自建窗口后就断了：表现是 **⌘Q 退出后进度、最后一笔笔迹/注解没落库**
    /// （用户 2026-09-02 报）。所以退出时必须由 delegate 显式把每扇窗都结清一遍。
    ///
    /// 幂等（`didShutdown`）：万一将来某条路径两边都走到，第二次是空操作。
    func shutdown() {
        guard !didShutdown else { return }
        didShutdown = true
        logFrame("结清（关窗/退出）")
        saveFrame()          // ⌘Q 不发 `windowWillClose`，最后这一下尺寸靠这里落下来
        refWindow.close()
        dismissRefWindow()   // 订阅要下一拍才跑，关窗/退出等不起，这里直接关
        AIPanelModel.shared.releaseHost(.inline(session.windowID))
        AIPanelModel.shared.forgetInline(session.windowID)
        AgentPanelModel.shared.readerClosed(tabs.windowID)
        tabs.closeWindow()
        WorkspaceRegistry.shared.closeRootWindow(windowId)
        AppDelegate.shared?.forget(self)
    }

    // MARK: - 初始内容

    /// 本窗口开哪篇。工作区归属在建窗前就定好了，这里只管选文档：
    /// `launchDocId` 指定了就用它，否则恢复该工作区的「上次打开集」（每个工作区只做一次）。
    private func decideInitialContent(launchDocId: String? = nil) {
        guard !didChooseInitialDoc else { return }
        didChooseInitialDoc = true
        if let id = launchDocId { _ = tabs.open(id); return }
        guard let folder = workspace.folder else { return }
        guard WorkspaceRegistry.shared.claimRestore(folder) else {
            wsLog("decideInitialContent：本工作区已恢复过，留空窗口")
            return
        }
        wsTime("恢复标签(读库+开 PDF)") { tabs.restoreTabs() }
    }

    // MARK: - 窗口级动作（原先散在 ContentView 里）

    func openPDF() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return }
        ingest(urls: panel.urls)
    }

    /// 导入一批 PDF（打开面板 / 拖拽都走这里）：逐个算 hash 入库，选中最后一个。
    func ingest(urls: [URL]) {
        let pdfs = urls.filter { $0.pathExtension.lowercased() == "pdf" }
        guard !pdfs.isEmpty else { return }
        tabs.active.isHashing = true
        Task { [weak self] in
            guard let self else { return }
            var lastId: String?
            for url in pdfs {
                if let r = await self.workspace.importPDF(at: url) { lastId = r.document.id }   // 与 MCP import_pdf 同一条路
            }
            self.tabs.active.isHashing = false
            if let lastId { _ = self.tabs.open(lastId) }
        }
    }

    /// 打开一个**已存在**的工作区包（`.unrd`）：只认真实工作区，不接受普通/空文件夹，
    /// 也不允许现场新建（那是 `createNewWorkspace()` 的职责）。
    func chooseWorkspace() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.canCreateDirectories = false
        panel.treatsFilePackagesAsDirectories = false
        panel.allowedContentTypes = [UTType(exportedAs: "tech.xvanturing.unireader.workspace")]
        panel.allowsMultipleSelection = false
        panel.message = L("Choose an existing UniReader workspace (.unrd).")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        routeToWorkspace(url, strict: true)
    }

    /// 新建工作区：选位置 + 起名，创建全新 `.unrd` 包并开一扇窗。
    func createNewWorkspace() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(exportedAs: "tech.xvanturing.unireader.workspace")]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = L("Untitled Workspace")
        panel.prompt = L("Create")
        panel.message = L("Choose a location and name for the new workspace.")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        // 目标已经是工作区会在这里报错而非覆盖——不能因为面板弹过「替换」就删掉一整库笔记。
        do { try WorkspaceManager.createWorkspace(at: url) } catch {
            present(error.localizedDescription)
            return
        }
        routeToWorkspace(url, strict: true)
    }

    /// 「最近工作区」里的一项：已不存在或已不是真实工作区 → 提示 + 自动移除。
    func openRecentWorkspace(_ url: URL) {
        do {
            try WorkspaceManager.validate(url)
        } catch {
            WorkspaceRegistry.shared.removeRecent(url)
            WorkspaceRegistry.shared.missingRecentName = WorkspaceManager.defaultWorkspaceName(for: url)
            return
        }
        routeToWorkspace(url, strict: false)   // 刚验过，不必再验一遍
    }

    private func routeToWorkspace(_ url: URL, strict: Bool) {
        do { try WorkspaceRegistry.shared.route(to: url, strict: strict) }
        catch { present(error.localizedDescription) }
    }

    /// 选文件（面板留在窗口层），改库 + 重载交给标签自己（`DocTabModel.relocate`）。
    func relocate(_ doc: LibDocument) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = String(format: L("Choose the file for “%@”."), doc.title)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        tabs.active.relocate(doc, url: url)
    }

    private func present(_ message: String) {
        let a = NSAlert()
        a.messageText = L("Workspace Error")
        a.informativeText = message
        a.addButton(withTitle: L("OK"))
        if let window { a.beginSheetModal(for: window) } else { a.runModal() }
    }

    // MARK: - 工具栏
    //
    // 🔴 **每枚按钮一个独立 item，分组靠 `.space` 断开**，不用 `NSToolbarItemGroup`：group 在
    // 「自定工具栏…」面板里是一整块、拆不开，而用户 2026-09-01 明确要的是一枚一枚能增删
    // （「一整个巨大的组！而不是一个一个（或者小组）」）。Tahoe 会把相邻的图标 item 自动粘成一个
    // 玻璃胶囊，正好用来表达四组：缩放 | 去哪儿 | 这一篇怎么读 | 另开一块。
    // **唯一的例外是缩放那三枚**（2026-09-07 用户改主意：「调整为固定（不可拆分）组」），见 `zoomGroup`。
    //
    // 🔴 **item id 沿用 SwiftUI 时期那套**（`zoom.out`…`inspector`）：系统按 id 记住用户摆好的
    // 工具栏，改 id 等于那一枚变成「新按钮」弹回默认位，用户白摆。
    //
    // ✅ 迁移的直接收益：这份 allowed 清单是我们自己写的——空格类只报一次（AppKit 惯例）、
    // 也不会混进 SwiftUI 那两个每次启动都变的 UUID 项。为此写的那两层兜底
    // （`ToolbarDelegateFilter` 去重代理、`ToolbarCustomizationEnabler` 的 KVO/didUpdate 双保险）
    // 已随 M3 删除——`allowsUserCustomization` 现在没人会把它拍回 false。

    private enum ToolID {
        static let addPDF = NSToolbarItem.Identifier("sidebar.addPDF")
        static let workspace = NSToolbarItem.Identifier("sidebar.workspace")
        /// 缩放三枚合成的**固定组**，见 `zoomGroup(_:)` 上那段红线。
        /// 🔴 raw value 仍是老的 `zoom.out`（**不是**笔误）：换 id 等于旧位置作废。
        static let zoom = NSToolbarItem.Identifier("zoom.out")
        static let contents = NSToolbarItem.Identifier("nav.contents")
        static let jumpBack = NSToolbarItem.Identifier("nav.back")
        static let jumpHistory = NSToolbarItem.Identifier("nav.history")
        static let ocr = NSToolbarItem.Identifier("doc.ocr")
        static let canvas = NSToolbarItem.Identifier("doc.canvas")
        static let night = NSToolbarItem.Identifier("doc.night")
        static let reference = NSToolbarItem.Identifier("aux.reference")
        static let tablet = NSToolbarItem.Identifier("aux.tablet")
        static let agent = NSToolbarItem.Identifier("aux.agent")
        static let consult = NSToolbarItem.Identifier("aux.consult")
        static let search = NSToolbarItem.Identifier("search")
        static let inspector = NSToolbarItem.Identifier("inspector")
    }

    private func makeToolbar() -> NSToolbar {
        let tb = NSToolbar(identifier: "reader")
        tb.delegate = self
        tb.displayMode = .iconOnly
        tb.allowsUserCustomization = true      // 🔴 这个开关现在是我们的了，没人会把它拍回去
        tb.autosavesConfiguration = true
        return tb
    }

    /// 🔴 **补插后加的 item**：`autosavesConfiguration` 存下来的是**用户当时**那份清单，后来新增的
    /// default item 不会自己冒出来——用户得先去「自定工具栏…」点恢复默认才看得见（2026-09-01
    /// 加回「加书 / 工作区菜单」两枚时踩到：它们在 default 清单里，屏幕上却没有）。
    /// 这里只补「配置里确实没有」的那几枚，用户主动拖走的不会被硬塞回来（拖走 = 配置里也没有，
    /// 但那是用户的选择——所以只在**第一次**引入某枚时补，靠 UserDefaults 记一笔）。
    private func adoptNewToolbarItems() {
        guard let tb = window?.toolbar else { return }
        let key = "toolbarAdopted.reader"
        var adopted = Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
        var index = 1   // 紧跟在 toggleSidebar 之后
        for id in [ToolID.addPDF, ToolID.workspace] where !adopted.contains(id.rawValue) {
            adopted.insert(id.rawValue)
            if !tb.items.contains(where: { $0.itemIdentifier == id }) {
                tb.insertItem(withItemIdentifier: id, at: min(index, tb.items.count))
            }
            index += 1
        }
        // Agent / 咨询 AI 两枚（2026-09-19 加）：接在平板 / 参考窗后面；两枚都被拖走了就放到弹性空白前
        for id in [ToolID.agent, ToolID.consult] where !adopted.contains(id.rawValue) {
            adopted.insert(id.rawValue)
            guard !tb.items.contains(where: { $0.itemIdentifier == id }) else { continue }
            let ids = tb.items.map(\.itemIdentifier)
            let at = [ToolID.agent, ToolID.tablet, ToolID.reference].lazy
                .compactMap { ids.lastIndex(of: $0) }.first.map { $0 + 1 }
                ?? ids.firstIndex(of: .flexibleSpace) ?? ids.count
            tb.insertItem(withItemIdentifier: id, at: at)
        }
        UserDefaults.standard.set(Array(adopted), forKey: key)
    }

    /// 🔴 **`.sidebarTrackingSeparator` 不能省**：它是「侧栏区 ↔ 内容区」的分界，工具栏靠它知道
    /// 哪些 item 属于侧栏那一侧。少了它，侧栏开关会被当成普通 item 排到内容区里去
    /// （2026-09-01 用户实测：「左侧边栏按钮跑右边去了」）。
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, ToolID.addPDF, ToolID.workspace, .sidebarTrackingSeparator,
         ToolID.zoom, .space,
         ToolID.contents, ToolID.jumpBack, ToolID.jumpHistory, .space,
         ToolID.ocr, ToolID.canvas, ToolID.night, .space,
         ToolID.reference, ToolID.tablet, .space,
         ToolID.agent, ToolID.consult,
         .flexibleSpace, ToolID.search, ToolID.inspector]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, ToolID.addPDF, ToolID.workspace, .sidebarTrackingSeparator,
         .space, .flexibleSpace,
         ToolID.zoom,
         ToolID.contents, ToolID.jumpBack, ToolID.jumpHistory,
         ToolID.ocr, ToolID.canvas, ToolID.night,
         ToolID.reference, ToolID.tablet, ToolID.agent, ToolID.consult,
         ToolID.search, ToolID.inspector]
    }

    /// Inspector 那枚钉死不许移除：它是笔记/目录/信息整个面板的唯一入口，拖丢了用户找不回来。
    func toolbarImmovableItemIdentifiers(_ toolbar: NSToolbar) -> Set<NSToolbarItem.Identifier> {
        [ToolID.inspector]
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch id {
        case ToolID.addPDF:
            return button(id, L("Open PDF…"), "plus", #selector(addPDF))
        case ToolID.workspace:
            let it = NSMenuToolbarItem(itemIdentifier: id)
            it.label = L("Workspace")
            it.paletteLabel = L("Workspace")
            it.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
            it.menu = workspaceMenu()
            workspaceItem = it
            workspaceSymbol = "folder"   // 新建的这一枚挂的就是它；是镜像的话下一次刷新会换
            return it
        case ToolID.zoom:
            return zoomGroup(id)
        case ToolID.contents:
            return popoverButton(id, L("Contents"), "list.bullet.indent", #selector(showContents(_:)))
        case ToolID.jumpBack:
            return button(id, L("Back to Previous Position"), "arrow.uturn.backward", #selector(jumpBack))
        case ToolID.jumpHistory:
            return toggleButton(id, L("Jump History"), "clock.arrow.circlepath", #selector(toggleJumpHistory))
        case ToolID.ocr:
            return popoverButton(id, L("Text Recognition (OCR)"), "text.viewfinder", #selector(showOCR(_:)))
        case ToolID.canvas:
            return toggleButton(id, L("Canvas Mode"), "arrow.left.and.right.square", #selector(toggleCanvas))
        case ToolID.night:
            nightSymbol = "moon.fill"   // 同工作区那枚：记下新建时挂的图标
            return toggleButton(id, L("Night Mode"), "moon.fill", #selector(toggleNight))
        case ToolID.reference:
            return toggleButton(id, L("Reference Window"), "rectangle.on.rectangle", #selector(toggleReference))
        case ToolID.tablet:
            return popoverButton(id, L("Tablet"), "wifi", #selector(showTablet(_:)))
        case ToolID.agent:
            return toggleButton(id, L("Agent Panel"), "sparkles", #selector(toggleAgentPanel))
        case ToolID.consult:
            return toggleButton(id, L("AI Panel"), "bubble.left.and.text.bubble.right", #selector(toggleConsultPanel))
        case ToolID.inspector:
            return button(id, L("Inspector"), "sidebar.right", #selector(inspectorToggled))
        case ToolID.search:
            let it = NSSearchToolbarItem(itemIdentifier: id)
            it.label = L("Find in Document")
            it.paletteLabel = L("Find in Document")
            it.searchField.target = self
            it.searchField.action = #selector(searchChanged(_:))
            it.searchField.sendsWholeSearchString = false
            it.searchField.sendsSearchStringImmediately = true   // 边打边搜（会话内自带 250ms 防抖）
            searchItem = it
            return it
        default:
            return nil
        }
    }

    private func button(_ id: NSToolbarItem.Identifier, _ label: String,
                        _ symbol: String, _ sel: Selector) -> NSToolbarItem {
        let it = NSToolbarItem(itemIdentifier: id)
        it.label = label
        it.paletteLabel = label
        it.toolTip = label
        it.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        it.target = self
        it.action = sel
        it.isBordered = true
        return it
    }

    /// 缩放三枚 = **一个不可拆分的 `NSToolbarItemGroup`**（2026-09-07 用户拍板）。
    ///
    /// 🔴 这是上面「每枚一个独立 item」那条原则**故意留的唯一例外**：缩小 / 实际大小 / 放大
    /// 语义上是一件事的三档，没人会只留其中一枚。做成 group 后「自定工具栏…」面板里它就是
    /// 一整块——只能整组拖走、整组拖回，拆不开。
    /// 🔴 **group 的 id 复用旧的 `zoom.out`**：`autosavesConfiguration` 存的是 id 清单，换新 id
    /// 等于这一枚变「新按钮」弹回默认位。沿用 `zoom.out` 后，老配置里的 `zoom.actual` / `zoom.in`
    /// 因为不在 allowed 清单里被系统丢掉，group 正好落在原来那三枚的位置上。
    /// 🔴 `controlRepresentation = .expanded`：`.automatic` 会在窄窗口里把整组塌成一枚下拉菜单，
    /// 缩放是高频动作，不能藏进二级菜单。
    /// ⚠️ 带 view 的 item 拿不到 `validateToolbarItem`（见 `toggleButton` 那条），group 走不走这条
    /// 校验只能真机看——所以启禁两边都写：这里留 `validateToolbarItem` 的分支，
    /// `refreshToolbarStates` 里再显式推一次 `isEnabled`。
    private func zoomGroup(_ id: NSToolbarItem.Identifier) -> NSToolbarItemGroup {
        let specs = [(L("Zoom Out"), "minus.magnifyingglass"),
                     (L("Actual Size"), "1.magnifyingglass"),
                     (L("Zoom In"), "plus.magnifyingglass")]
        let images = specs.map {
            NSImage(systemSymbolName: $0.1, accessibilityDescription: $0.0) ?? NSImage()
        }
        let g = NSToolbarItemGroup(itemIdentifier: id, images: images,
                                  selectionMode: .momentary, labels: specs.map(\.0),
                                  target: self, action: #selector(zoomSegment(_:)))
        g.label = L("Zoom")
        g.paletteLabel = L("Zoom")
        g.controlRepresentation = .expanded
        for (sub, spec) in zip(g.subitems, specs) { sub.toolTip = spec.0 }
        zoomItem = g
        return g
    }

    /// 开关型按钮（画板 / 夜间 / 参考窗 / 跳转历史窗）。
    ///
    /// 🔴 **必须用 `pushOnPushOff` 让系统画选中背景**：只换 SF Symbol 的 fill 变体那点差别
    /// 根本看不出来（2026-09-01 用户报「Canvas Mode 的 toggle 看不出来了」）。
    /// 🔴 而且这类 item **拿不到 `validateToolbarItem`**——AppKit 对带 view 的 item 不走那条校验，
    /// 状态得我们自己推（见 `refreshToolbarStates`）。
    private func toggleButton(_ id: NSToolbarItem.Identifier, _ label: String,
                              _ symbol: String, _ sel: Selector) -> NSToolbarItem {
        let it = NSToolbarItem(itemIdentifier: id)
        let btn = NSButton(frame: NSRect(x: 0, y: 0, width: 34, height: 26))
        btn.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        btn.imagePosition = .imageOnly
        btn.bezelStyle = .texturedRounded
        btn.setButtonType(.pushOnPushOff)
        btn.target = self
        btn.action = sel
        it.view = btn
        it.label = label
        it.paletteLabel = label
        it.toolTip = label
        return it
    }

    /// 把开关型按钮的按下态刷成当前状态。挂在几条现成的信号上：标签/会话的任何变化
    /// （`tabs.objectWillChange`，画板模式就在里面）、参考窗开合、以及 `UserDefaults`
    /// （夜间模式是 `@AppStorage`，内容层和菜单都可能改它）。
    ///
    /// 🔴 **每一处都只在值真变了时才写**（2026-09-19 用户报：内置面板滑入结束时整排工具栏按钮闪）。
    /// 这个函数跟着会话的每次变化跑（翻页 / 缩放 / 适配宽度），而给工具栏 item 换图标、改 `isHidden`、
    /// 改启用状态，哪怕是同一个值也可能让工具栏重排一遍。图标尤其如此：每次 `NSImage(systemSymbolName:)`
    /// 都是新对象，系统没法知道它和原来那张一样。真写了就记一行日志（`[TB]`），再闪时对照时间点看是不是这里。
    private func refreshToolbarStates() {
        guard let items = window?.toolbar?.items else { return }
        let night = UserDefaults.standard.bool(forKey: "nightMode")
        // 缩放组：group 走不走 `validateToolbarItem` 不好赌，这里显式推一次（两边同一个条件）。
        if let g = zoomItem {
            let on = session.pdf != nil
            if g.isEnabled != on {
                wsLog("[TB] 缩放组 isEnabled → \(on)")
                g.isEnabled = on
            }
            for sub in g.subitems where sub.isEnabled != on { sub.isEnabled = on }
        }
        func setState(_ btn: NSButton, _ on: Bool) {
            let s: NSControl.StateValue = on ? .on : .off
            if btn.state != s { btn.state = s }
        }
        for it in items {
            guard let btn = it.view as? NSButton else { continue }
            switch it.itemIdentifier {
            case ToolID.canvas: setState(btn, session.canvasMode)
            case ToolID.night:
                setState(btn, night)
                let symbol = night ? "sun.max.fill" : "moon.fill"
                if nightSymbol != symbol {
                    wsLog("[TB] 夜间按钮图标 → \(symbol)")
                    nightSymbol = symbol
                    btn.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
                }
            case ToolID.reference: setState(btn, refWindow.isOpen)
            case ToolID.jumpHistory: setState(btn, jumpPanel.isOpen)
            case ToolID.agent:
                let p = AgentPanelModel.shared
                // 设置里关掉了就不显示（自定工具栏里仍在，打开后原位回来）
                if it.isHidden == p.enabled {
                    wsLog("[TB] Agent 按钮 isHidden → \(!p.enabled)")
                    it.isHidden = !p.enabled
                }
                setState(btn, p.mode == .inline ? p.isInlineOpen(tabs.windowID) : AgentWindowController.isShown)
            case ToolID.consult:
                let p = AIPanelModel.shared
                if it.isHidden == p.enabled {
                    wsLog("[TB] AI 按钮 isHidden → \(!p.enabled)")
                    it.isHidden = !p.enabled
                }
                setState(btn, p.mode == .inline ? p.isInlineOpen(tabs.windowID) : AIPanelWindowController.isShown)
            default: break
            }
        }
        // 工作区菜单那枚：标题/图标跟着当前工作区走（镜像换个图标就够了——用户要的是
        // 「一眼认出这不是硬盘上那份」，不是一段说明）。
        let tip = workspace.name.isEmpty ? L("Workspace") : workspace.name
        if workspaceItem?.toolTip != tip { workspaceItem?.toolTip = tip }
        let wsSymbol = workspace.isMirror ? "externaldrive.badge.timemachine" : "folder"
        if let item = workspaceItem, workspaceSymbol != wsSymbol {
            wsLog("[TB] 工作区按钮图标 → \(wsSymbol)")
            workspaceSymbol = wsSymbol
            item.image = NSImage(systemSymbolName: wsSymbol, accessibilityDescription: nil)
        }
    }
    /// 上面两枚按钮此刻挂着的图标名（判断「真变了没有」用；新建的 `NSImage` 之间没法比）。
    private var nightSymbol: String?
    private var workspaceSymbol: String?

    /// 要弹面板的三枚（目录 / OCR / 平板）得自带一个 `NSButton` 当 view —— `NSPopover` 必须锚在
    /// 一个真实的 view 上，而标准 `NSToolbarItem` 不把它内部那个按钮交出来。
    /// ⚠️ 外观因此可能与相邻的标准 item 略有出入（Tahoe 的玻璃胶囊怎么处理带 view 的 item，
    /// 只能真机看）；若不一致，退路是把这三个面板改成浮在阅读区上的层（同跳转历史窗）。
    private func popoverButton(_ id: NSToolbarItem.Identifier, _ label: String,
                               _ symbol: String, _ sel: Selector) -> NSToolbarItem {
        let it = NSToolbarItem(itemIdentifier: id)
        let btn = NSButton(frame: NSRect(x: 0, y: 0, width: 34, height: 26))
        btn.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        btn.imagePosition = .imageOnly
        btn.bezelStyle = .texturedRounded
        btn.isBordered = true
        btn.target = self
        btn.action = sel
        it.view = btn
        it.label = label
        it.paletteLabel = label
        it.toolTip = label
        return it
    }

    // MARK: 工具栏动作

    /// 整组共用一个 action，按 `selectedIndex` 分派（`.momentary` 下它就是刚点的那一格）。
    @objc private func zoomSegment(_ sender: NSToolbarItemGroup) {
        let names: [Notification.Name] = [.readerZoomOut, .readerZoomActual, .readerZoomIn]
        guard names.indices.contains(sender.selectedIndex) else { return }
        NotificationCenter.default.post(name: names[sender.selectedIndex], object: nil)
    }
    @objc private func jumpBack() { session.jumpBack() }
    @objc private func toggleJumpHistory() { jumpPanel.toggle() }
    @objc private func toggleCanvas() { tabs.active.toggleCanvasMode() }
    @objc private func inspectorToggled() { toggleInspector() }

    /// Agent / 咨询 AI 两枚开关（用户 2026-09-19：和参考窗一样用工具栏按钮切换，不再在阅读区里画气泡）。
    /// 内置形态切**本窗口**的侧栏，独立窗口形态显示 ⇄ 隐藏——与菜单 / 快捷键同一套语义，
    /// 只是作用对象明确是按钮所在的这扇窗（菜单那条走「当前 key 窗口」）。
    @objc private func toggleAgentPanel() {
        let p = AgentPanelModel.shared
        if p.mode == .inline { p.setInlineOpen(!p.isInlineOpen(tabs.windowID), for: tabs.windowID) }
        else { AgentWindowController.toggle() }
        refreshToolbarStates()
    }

    @objc private func toggleConsultPanel() {
        let p = AIPanelModel.shared
        if p.mode == .inline {
            p.setActiveHost(.inline(tabs.windowID))
            p.toggleInline(tabs.windowID)
        } else {
            AIPanelWindowController.toggle()
        }
        refreshToolbarStates()
    }

    @objc private func toggleNight() {
        let d = UserDefaults.standard
        d.set(!d.bool(forKey: "nightMode"), forKey: "nightMode")   // 与内容层的 @AppStorage 同一个键
    }

    @objc private func toggleReference() {
        if refWindow.isOpen { refWindow.close() }
        else { refWindow.open(preferring: tabs.active.docID, workspace: workspace) }
    }

    /// 参考窗独立窗口的开合（见 `observeToolbarStates` 里那条订阅）。
    private func syncRefWindow(open: Bool, mode: RefWindowMode) {
        guard open, mode == .window else { dismissRefWindow(); return }
        if refWindowController == nil {
            refWindowController = RefWindowController(
                model: refWindow, workspace: workspace, app: app,
                currentDocID: { [weak self] in self?.tabs.active.docID },
                onGotoMain: { [weak self] page in self?.session.jump(page: page, frac: 0, kind: .list) })
        }
        refWindowController?.show(attachedTo: window)
    }

    private func dismissRefWindow() {
        guard let c = refWindowController else { return }
        refWindowController = nil
        c.dismiss()
    }

    @objc private func searchChanged(_ sender: NSSearchField) {
        session.searchQuery = sender.stringValue
        session.scheduleSearch()
    }

    // MARK: 工作区菜单
    //
    // 迁移前这是 `SidebarView` 里一条 SwiftUI `.toolbar`（装进 hosting controller 后整块失效）。
    // 「打开 / 新建 / 最近」窗口层自己就能做；「重命名 / 离线副本 / 同步」要弹的是侧栏那边的
    // sheet，发通知过去（见 `SidebarView` 里接住的那四条）。

    private func workspaceMenu() -> NSMenu {
        let m = NSMenu()
        m.delegate = self
        m.identifier = NSUserInterfaceItemIdentifier("workspace")
        buildWorkspaceMenu(m)
        return m
    }

    private func buildWorkspaceMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        add(menu, L("Open Workspace…"), #selector(menuOpenWorkspace), symbol: "folder")
        add(menu, L("New Workspace…"), #selector(menuNewWorkspace), symbol: "folder.badge.plus")
        add(menu, L("Rename Workspace…"), #selector(menuRenameWorkspace), symbol: "pencil")
        menu.addItem(.separator())
        // 镜像与源盘互斥：镜像不能再做镜像，源盘也没有「同步回去」这回事——
        // 两个入口只出现一个，不给用户做无效选择的机会（沿用迁移前的判断）。
        if workspace.isMirror {
            add(menu, L("Sync to Source…"), #selector(menuSyncToSource),
                symbol: "arrow.triangle.2.circlepath")
        } else {
            // 「保留离线副本」是**状态**不是动作：勾上 = 这个工作区我要能离线用。
            let keep = add(menu, L("Keep Offline Copy"), #selector(menuToggleOfflineCopy),
                           symbol: "externaldrive.badge.timemachine")
            keep.state = keptOffline ? .on : .off
            if keptOffline { menu.addItem(.sectionHeader(title: lastSyncedLine)) }
        }
        let recents = WorkspaceRegistry.shared.recents
        if !recents.isEmpty {
            menu.addItem(.separator())
            // 侧栏只留「快速切过去」；移除/清空统一在「文件 → 最近打开」。
            menu.addItem(.sectionHeader(title: L("Recent Workspaces")))
            for r in recents {
                let it = NSMenuItem(title: r.name, action: #selector(menuOpenRecent(_:)), keyEquivalent: "")
                it.target = self
                it.representedObject = WorkspaceRegistry.resolveOrSource(r).path
                // 换图标就够了，不加字：一眼看出「点它现在是离线读」
                it.image = NSImage(systemSymbolName: WorkspaceRegistry.opensOffline(r)
                                   ? "externaldrive.badge.timemachine" : "folder",
                                   accessibilityDescription: nil)
                menu.addItem(it)
            }
        }
    }

    @discardableResult
    private func add(_ menu: NSMenu, _ title: String, _ sel: Selector, symbol: String? = nil) -> NSMenuItem {
        let it = NSMenuItem(title: title, action: sel, keyEquivalent: "")
        it.target = self
        if let symbol { it.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
        menu.addItem(it)
        return it
    }

    /// 这个工作区当下**确实**有一份可用的离线副本（记录挂着、文件也还在）。
    private var keptOffline: Bool {
        guard let folder = workspace.folder else { return false }
        return WorkspaceRegistry.shared.mirrorPath(forSource: folder, id: workspace.workspaceId) != nil
    }

    /// 借出记录就在源库自己的 meta 里，读它不额外开连接。
    private var lastSyncedLine: String {
        guard let at = workspace.checkouts.first?.lastSyncedAt, let d = ISO.date(at) else {
            return L("Never synced back")
        }
        return String(format: L("Last synced %@"), d.formatted(date: .abbreviated, time: .shortened))
    }

    @objc private func addPDF() { openPDF() }
    @objc private func menuOpenWorkspace() { chooseWorkspace() }
    @objc private func menuNewWorkspace() { createNewWorkspace() }
    @objc private func menuRenameWorkspace() {
        NotificationCenter.default.post(name: .workspaceRenameRequested, object: nil)
    }
    @objc private func menuSyncToSource() {
        NotificationCenter.default.post(name: .workspaceSyncToSourceRequested, object: nil)
    }
    @objc private func menuToggleOfflineCopy() {
        NotificationCenter.default.post(name: keptOffline ? .workspaceDropMirrorRequested
                                                          : .workspaceMakeMirrorRequested, object: nil)
    }
    @objc private func menuOpenRecent(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        openRecentWorkspace(URL(fileURLWithPath: path))
    }

    // MARK: 弹出面板

    @objc private func showContents(_ sender: NSButton) {
        present(NSHostingController(rootView: TOCPopoverContent(tabs: tabs, onPicked: { [weak self] in
            self?.popover?.performClose(nil)
        }).environmentObject(app).environmentObject(workspace)), from: sender)
    }

    @objc private func showOCR(_ sender: NSButton) {
        present(NSHostingController(rootView: OCRPopoverContent(tabs: tabs)
            .environmentObject(app).environmentObject(workspace)), from: sender)
    }

    @objc private func showTablet(_ sender: NSButton) {
        present(NSHostingController(rootView: ServerPanel(server: app.server)
            .environmentObject(app).environmentObject(workspace)), from: sender)
    }

    /// 一次只开一个面板：再点同一枚就是关掉（与 SwiftUI `.popover(isPresented:)` 的手感一致）。
    ///
    /// 位置不对时先看这行日志（`touch ~/Library/Logs/UniReader-ws.log` 开）：锚点 view 到底在不在
    /// 窗口层级里、它在窗口坐标里的矩形是什么。**「面板跑到很高的地方」的两种成因完全不同**——
    /// 边选错了（上下颠倒）看 `翻转=`，锚点本身就不对（比如 AppKit 没用我们这个 view）看 `窗口内=`。
    private func present(_ vc: NSViewController, from view: NSView) {
        if let p = popover, p.isShown {
            p.performClose(nil)
            popover = nil
            return
        }
        let p = NSPopover()
        p.contentViewController = vc
        p.behavior = .transient
        popover = p
        // 尺寸显式给死：`NSHostingController` 不一定把 SwiftUI 的固有尺寸报给 popover，
        // 而尺寸不定的 popover 定位起来就是「跑偏」。三个面板内容本来都带 `.frame(...)`。
        p.contentSize = vc.view.fittingSize
        let inWindow = view.superview?.convert(view.frame, to: nil) ?? .zero
        wsLog("popover 锚点：bounds=\(view.bounds) 窗口内=\(inWindow)"
              + " 翻转=\(view.isFlipped) 尺寸=\(p.contentSize)"
              + " 屏幕高=\(view.window?.screen?.frame.height ?? -1)"
              + " 窗口frame=\(view.window?.frame ?? .zero)")
        // 🔴 **`.maxY` 才是这里的「按钮下方」**：`NSToolbarItemViewer` 里那个 `NSButton`
        // 是**翻转坐标系**（2026-09-01 日志实测 `翻转=true`），翻转视图里 maxY 是视觉下边。
        // 别照搬「非翻转时 minY 在下」的直觉——工具栏这一层恰恰相反。
        p.show(relativeTo: view.bounds, of: view, preferredEdge: .maxY)
    }

    /// 校验 + **顺带刷新图标**：AppKit 每轮事件循环都会调它，正好用来让那几枚开关型按钮的图标
    /// 跟着状态走（夜间的日月、画板的实心/空心、参考窗的开合），不必再各挂一条订阅。
    func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        let s = session
        switch item.itemIdentifier {
        case ToolID.zoom, ToolID.contents, ToolID.ocr:
            return s.pdf != nil
        case ToolID.jumpBack:
            return s.jumps.canGoBack
        case ToolID.jumpHistory:
            return s.pdf != nil
        // 画板 / 夜间 / 参考窗 / 跳转历史这几枚是带 view 的开关，**不走这条校验**，
        // 状态由 `refreshToolbarStates` 推（见那里的红线）。
        case ToolID.search:
            // 搜索词可能被别处改（换标签会 clearSearch），同步回输入框——但**正在输入时不碰**，
            // 否则每轮校验都把光标顶掉。
            if let f = searchItem?.searchField, f.currentEditor() == nil,
               f.stringValue != s.searchQuery {
                f.stringValue = s.searchQuery
            }
            return s.pdf != nil
        default:
            return true
        }
    }
}

extension ReaderWindowController: NSMenuDelegate {
    /// 工作区菜单**展开前**重建：离线副本的开关状态、最近列表都可能在两次点击之间变了。
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu.identifier?.rawValue == "workspace" else { return }
        buildWorkspaceMenu(menu)
    }
}
