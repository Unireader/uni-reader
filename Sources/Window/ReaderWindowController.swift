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

    /// 在 `WorkspaceRegistry` 的登记号（关窗时按它归还工作区实例）。
    private let windowId = UUID()
    private var bag = Set<AnyCancellable>()
    private var didChooseInitialDoc = false

    private let splitVC = NSSplitViewController()
    /// 当前弹着的面板（目录/OCR/平板共用一个，一次只开一个）。
    private var popover: NSPopover?
    /// 搜索项（⌘F 要让它进入编辑态，校验时也要同步文本）。
    private var searchItem: NSSearchToolbarItem?
    private var sidebarItem: NSSplitViewItem!
    private var inspectorItem: NSSplitViewItem!

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
        // 系统的窗口状态恢复照旧关掉：本 app 自己管着「上次开了哪些文档」（每个工作区的打开集 →
        // restoreTabs），系统再恢复一遍是重复的。迁移前这是 `.restorationBehavior(.disabled)`。
        win.isRestorable = false
        super.init(window: win)

        buildPanes()
        win.contentViewController = splitVC
        win.delegate = self
        win.toolbarStyle = .unified
        win.toolbar = makeToolbar()

        WorkspaceRegistry.shared.noteRootWindow(windowId)
        WorkspaceRegistry.shared.bindRootWindow(windowId, workspace)
        tabs.noteWindowObject(win)

        bindTitle()
        observeToolbarStates()
        observeMenuCommands()
        decideInitialContent(launchDocId: launchDocId)

        // 先摆位再挂 autosave：autosave 会把上次记下的 frame 应用上来（第一扇窗因此回到原处），
        // 多开的那几扇由 `AppDelegate` 再 cascade 错开，否则会精确叠在一起。
        win.center()
        win.setFrameAutosaveName("UniReaderReaderWindow")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) 不支持——窗口一律由代码建") }

    /// 三段分栏：侧栏 / 阅读区 / Inspector，各装一个 `NSHostingController`。
    ///
    /// 🔴 用 `NSSplitViewController` 而不是继续套 `NavigationSplitView`：后者会往
    /// `window.toolbar` 里塞侧栏按钮和搜索框，等于又来抢工具栏——那正是这次迁移要根除的
    /// （方案 §2）。侧栏/Inspector 用系统的 `sidebarWithViewController` /
    /// `inspectorWithViewController`，观感与折叠动画都是系统的，不自绘。
    private func buildPanes() {
        let sidebar = NSHostingController(rootView: SidebarPane(
            tabs: tabs,
            onChooseWorkspace: { [weak self] in self?.chooseWorkspace() },
            onCreateWorkspace: { [weak self] in self?.createNewWorkspace() },
            onOpenRecent: { [weak self] in self?.openRecentWorkspace($0) },
            onDropFiles: { [weak self] in self?.ingest(urls: $0) },
            onOpenPDF: { [weak self] in self?.openPDF() },
            onOpenInNewWindow: { [weak self] docId in
                guard let self else { return }
                AppDelegate.shared?.openReaderWindow(
                    workspacePath: self.workspace.folder?.standardizedFileURL.path, docId: docId)
            })
            .environmentObject(app)
            .environmentObject(workspace))

        let content = NSHostingController(rootView: ReaderPane(
            tabs: tabs, chrome: chrome, refWindow: refWindow, jumpPanel: jumpPanel,
            onRelocate: { [weak self] doc in self?.relocate(doc) },
            onIngest: { [weak self] urls in self?.ingest(urls: urls) })
            .environmentObject(app)
            .environmentObject(workspace))

        let inspector = NSHostingController(rootView: InspectorPane(tabs: tabs)
            .environmentObject(app)
            .environmentObject(workspace))

        // 🔴 **三段都要关掉尺寸传播**：`NSHostingController` 默认把 SwiftUI 内容的 fitting size
        // 报成 `preferredContentSize`，AppKit 于是拿它去调整窗口——2026-09-01 用户实测的两个症状
        // 都是它：⌘T 开一个空标签（内容只有一个 `ContentUnavailableView`）整扇窗当场缩成一小块；
        // autosave 存下来的窗口尺寸也会被这一下覆盖，看起来就是「窗口大小没恢复」。
        // 窗口尺寸该由 autosave 和用户拖动决定，内容只负责填满给它的地方。
        // （三个 hosting controller 的泛型参数各不相同，装不进同一个数组，只能逐个设。）
        sidebar.sizingOptions = []
        content.sizingOptions = []
        inspector.sizingOptions = []

        sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sidebarItem.allowsFullHeightLayout = true   // 侧栏一路铺到标题栏后面（默认就是 true，写明意图）
        sidebarItem.minimumThickness = 200
        sidebarItem.maximumThickness = 420
        let contentItem = NSSplitViewItem(viewController: content)
        contentItem.minimumThickness = 400
        inspectorItem = NSSplitViewItem(inspectorWithViewController: inspector)
        inspectorItem.minimumThickness = 240
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
        jumpPanel.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshToolbarStates() }
            .store(in: &bag)
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshToolbarStates() }
            .store(in: &bag)
    }

    private func refreshTitle() {
        let s = session
        window?.title = s.title.isEmpty ? L("Library") : s.title
        window?.subtitle = s.pdf.map { "\(s.currentPageIndex + 1)/\($0.pageCount)" } ?? ""
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
        on(.newTabRequested) { _ = $0.tabs.newTab() }
        on(.closeTabRequested) { $0.closeTabOrWindow() }
        on(.closeWindowRequested) { $0.window?.performClose(nil) }
        on(.nextTabRequested) { $0.tabs.activate(offset: 1) }
        on(.prevTabRequested) { $0.tabs.activate(offset: -1) }
        on(.toggleSidebar) { $0.sidebarItem.animator().isCollapsed.toggle() }
        on(.toggleInspector) { $0.toggleInspector() }
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
        if AIPanelModel.shared.mode == .inline {
            AIPanelModel.shared.setActiveHost(.inline(session.windowID))
        }
    }

    func windowDidResignKey(_ notification: Notification) { chrome.isKeyWindow = false }

    /// 关窗结清。次序与迁移前的 `ContentView.onDisappear` **完全一致**（那套次序有讲究，
    /// 全在 `DocTabModel.close()` 里写着）——只是触发点从 SwiftUI 的生命周期换成了
    /// AppKit 的 `windowWillClose`，而后者每扇窗口只发一次、就是关闭那一刻。
    func windowWillClose(_ notification: Notification) {
        refWindow.close()
        AIPanelModel.shared.releaseHost(.inline(session.windowID))
        AIPanelModel.shared.forgetInline(session.windowID)
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
        tabs.restoreTabs()
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
                let hash = await Task.detached(priority: .userInitiated) {
                    (try? FileHasher.sha256Cached(of: url)) ?? ""
                }.value
                let pageCount = PDFDocument(url: url)?.pageCount ?? 0
                if let doc = self.workspace.ingest(path: url.path, hash: hash,
                                                   title: url.deletingPathExtension().lastPathComponent,
                                                   pageCount: pageCount) {
                    lastId = doc.id
                }
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
    //
    // 🔴 **item id 沿用 SwiftUI 时期那套**（`zoom.out`…`inspector`）：系统按 id 记住用户摆好的
    // 工具栏，改 id 等于那一枚变成「新按钮」弹回默认位，用户白摆。
    //
    // ✅ 迁移的直接收益：这份 allowed 清单是我们自己写的——空格类只报一次（AppKit 惯例）、
    // 也不会混进 SwiftUI 那两个每次启动都变的 UUID 项。为此写的那两层兜底
    // （`ToolbarDelegateFilter` 去重代理、`ToolbarCustomizationEnabler` 的 KVO/didUpdate 双保险）
    // 已随 M3 删除——`allowsUserCustomization` 现在没人会把它拍回 false。

    private enum ToolID {
        static let zoomOut = NSToolbarItem.Identifier("zoom.out")
        static let zoomActual = NSToolbarItem.Identifier("zoom.actual")
        static let zoomIn = NSToolbarItem.Identifier("zoom.in")
        static let contents = NSToolbarItem.Identifier("nav.contents")
        static let jumpBack = NSToolbarItem.Identifier("nav.back")
        static let jumpHistory = NSToolbarItem.Identifier("nav.history")
        static let ocr = NSToolbarItem.Identifier("doc.ocr")
        static let canvas = NSToolbarItem.Identifier("doc.canvas")
        static let night = NSToolbarItem.Identifier("doc.night")
        static let reference = NSToolbarItem.Identifier("aux.reference")
        static let tablet = NSToolbarItem.Identifier("aux.tablet")
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

    /// 🔴 **`.sidebarTrackingSeparator` 不能省**：它是「侧栏区 ↔ 内容区」的分界，工具栏靠它知道
    /// 哪些 item 属于侧栏那一侧。少了它，侧栏开关会被当成普通 item 排到内容区里去
    /// （2026-09-01 用户实测：「左侧边栏按钮跑右边去了」）。
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, .sidebarTrackingSeparator,
         ToolID.zoomOut, ToolID.zoomActual, ToolID.zoomIn, .space,
         ToolID.contents, ToolID.jumpBack, ToolID.jumpHistory, .space,
         ToolID.ocr, ToolID.canvas, ToolID.night, .space,
         ToolID.reference, ToolID.tablet,
         .flexibleSpace, ToolID.search, ToolID.inspector]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, .sidebarTrackingSeparator, .space, .flexibleSpace,
         ToolID.zoomOut, ToolID.zoomActual, ToolID.zoomIn,
         ToolID.contents, ToolID.jumpBack, ToolID.jumpHistory,
         ToolID.ocr, ToolID.canvas, ToolID.night,
         ToolID.reference, ToolID.tablet, ToolID.search, ToolID.inspector]
    }

    /// Inspector 那枚钉死不许移除：它是笔记/目录/信息整个面板的唯一入口，拖丢了用户找不回来。
    func toolbarImmovableItemIdentifiers(_ toolbar: NSToolbar) -> Set<NSToolbarItem.Identifier> {
        [ToolID.inspector]
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch id {
        case ToolID.zoomOut:
            return button(id, L("Zoom Out"), "minus.magnifyingglass", #selector(zoomOut))
        case ToolID.zoomActual:
            return button(id, L("Actual Size"), "1.magnifyingglass", #selector(zoomActual))
        case ToolID.zoomIn:
            return button(id, L("Zoom In"), "plus.magnifyingglass", #selector(zoomIn))
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
            return toggleButton(id, L("Night Mode"), "moon.fill", #selector(toggleNight))
        case ToolID.reference:
            return toggleButton(id, L("Reference Window"), "rectangle.on.rectangle", #selector(toggleReference))
        case ToolID.tablet:
            return popoverButton(id, L("Tablet"), "wifi", #selector(showTablet(_:)))
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
    private func refreshToolbarStates() {
        guard let items = window?.toolbar?.items else { return }
        let night = UserDefaults.standard.bool(forKey: "nightMode")
        for it in items {
            guard let btn = it.view as? NSButton else { continue }
            switch it.itemIdentifier {
            case ToolID.canvas: btn.state = session.canvasMode ? .on : .off
            case ToolID.night:
                btn.state = night ? .on : .off
                btn.image = NSImage(systemSymbolName: night ? "sun.max.fill" : "moon.fill",
                                    accessibilityDescription: nil)
            case ToolID.reference: btn.state = refWindow.isOpen ? .on : .off
            case ToolID.jumpHistory: btn.state = jumpPanel.isOpen ? .on : .off
            default: break
            }
        }
    }

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

    @objc private func zoomOut() { NotificationCenter.default.post(name: .readerZoomOut, object: nil) }
    @objc private func zoomActual() { NotificationCenter.default.post(name: .readerZoomActual, object: nil) }
    @objc private func zoomIn() { NotificationCenter.default.post(name: .readerZoomIn, object: nil) }
    @objc private func jumpBack() { session.jumpBack() }
    @objc private func toggleJumpHistory() { jumpPanel.toggle() }
    @objc private func toggleCanvas() { tabs.active.toggleCanvasMode() }
    @objc private func inspectorToggled() { toggleInspector() }

    @objc private func toggleNight() {
        let d = UserDefaults.standard
        d.set(!d.bool(forKey: "nightMode"), forKey: "nightMode")   // 与内容层的 @AppStorage 同一个键
    }

    @objc private func toggleReference() {
        if refWindow.isOpen { refWindow.close() }
        else { refWindow.open(preferring: tabs.active.docID, workspace: workspace) }
    }

    @objc private func searchChanged(_ sender: NSSearchField) {
        session.searchQuery = sender.stringValue
        session.scheduleSearch()
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
        case ToolID.zoomOut, ToolID.zoomActual, ToolID.zoomIn, ToolID.contents, ToolID.ocr:
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
