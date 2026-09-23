import AppKit
import Combine

/// 阅读窗格（分栏的中间那段，AppKit 版，替代 SwiftUI `ReaderPane`）：
/// 当前标签的阅读区（`ReaderView`）或空白提示 + 查找条 + 角标 + 底部标签栏 + 书签命名框 + 两种确认弹窗，
/// 以及归这一层认领的菜单命令（夜间 / 画板 / 跳转 / 书签 / 扫描页对齐）。
///
/// 阅读区**铺满整个窗格**（伸到侧栏 / Inspector 的玻璃与工具栏底下，Preview 式）；浮在上面的部件
/// 摆在安全区里（让开侧栏、工具栏与右侧内置 AI 面板）。
@MainActor
final class ReaderPaneController: NSViewController {
    let tabs: TabsModel
    let chrome: WindowChrome
    let refWindow: RefWindowModel
    let jumpPanel: JumpHistoryPanel
    let app: AppModel
    let workspace: WorkspaceManager
    var onRelocate: (LibDocument) -> Void = { _ in }
    var onIngest: ([URL]) -> Void = { _ in }

    private(set) var readerView: ReaderView?
    /// 当前标签开的是 Markdown 笔记时的整篇编辑区（v15）。
    /// 与 `readerView` 互斥——标签里 `docID` 与 `mdID` 本来就互斥。
    private var mdView: MarkdownDocView?
    private let placeholder = PlaceholderView()
    private let findBanner = FindBannerView()
    private let badge = StatusBadgeView()
    private let tabBar = TabBarNSView()
    /// 参考窗覆盖层 / 跳转历史：摆在安全区里（让开工具栏与左右两侧栏），身份跟窗口走（切标签不重建）。
    private let floating = FloatingLayerView()
    private var refCard: RefCard!
    /// 笔架：有 PDF 时浮在阅读区上（设备级全局状态，图层按当前文档）。
    private var penRack: PenRackNSView?
    /// 开着的草稿纸（盖满阅读区，笔架仍在它上面可用）。
    private var scratchPad: ScratchPadNSView?
    private var jumpCard: JumpHistoryCard!
    private var docPicker: NSPopover?
    private var bookmarkSheet: NSWindow?
    private var alertShowing = false
    /// 「跳转到指定页」的输入框正开着（⌃G 连按不叠第二张）。与 `alertShowing` 分开：
    /// 那一个是「文件已变化 / 扫描页对齐」两张**被动**弹窗的互斥位，这一张是用户主动按出来的。
    private var gotoPageShowing = false

    private var bag = Set<AnyCancellable>()
    private var sessionBag = Set<AnyCancellable>()
    private var observers: [NSObjectProtocol] = []
    private var boundSession: DocSession?
    private var refreshQueued = false

    init(tabs: TabsModel, chrome: WindowChrome, refWindow: RefWindowModel, jumpPanel: JumpHistoryPanel,
         app: AppModel, workspace: WorkspaceManager) {
        self.tabs = tabs
        self.chrome = chrome
        self.refWindow = refWindow
        self.jumpPanel = jumpPanel
        self.app = app
        self.workspace = workspace
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) 不支持") }

    private var tab: DocTabModel { tabs.active }
    private var session: DocSession { tab.session }

    override func loadView() {
        let v = ReaderPaneRootView()
        v.onDrop = { [weak self] urls in self?.onIngest(urls) }
        v.onLayout = { [weak self] in self?.layoutChrome() }
        view = v
        placeholder.isHidden = true
        for sub in [placeholder, badge, findBanner, tabBar, floating] as [NSView] { v.addSubview(sub) }
        refCard = RefCard(model: refWindow, workspace: workspace)
        refCard.currentDocID = { [weak self] in self?.tab.docID }
        refCard.onGotoMain = { [weak self] page in self?.session.jump(page: page, frac: 0, kind: .list) }
        jumpCard = JumpHistoryCard(panel: jumpPanel)
        for sub in [jumpCard.card, refCard.card, refCard.bubble] as [NSView] { floating.addSubview(sub) }
        floating.onLayout = { [weak self] size in
            self?.refCard.layout(in: size)
            self?.jumpCard.layout(in: size)
        }
        findBanner.isHidden = true
        badge.isHidden = true
        tabBar.isHidden = true
        findBanner.prev.target = self
        findBanner.prev.action = #selector(prevMatch)
        findBanner.next.target = self
        findBanner.next.action = #selector(nextMatch)
        tabBar.onSelect = { [weak self] in self?.tabs.activate($0) }
        tabBar.onClose = { [weak self] in self?.tabs.close($0) }
        tabBar.onCloseOthers = { [weak self] in self?.tabs.closeOthers(than: $0) }
        tabBar.onOpenInNewWindow = { [weak self] id in
            guard let self, let d = self.tabs.tabs.first(where: { $0.id == id })?.docID else { return }
            AppDelegate.shared?.openReaderWindow(workspacePath: self.workspace.folder?.standardizedFileURL.path, docId: d)
        }
        tabBar.onNewTab = { [weak self] in self?.tabs.docPickerPresented = true }
        tabBar.onToggleStyle = {
            let d = UserDefaults.standard
            let cur = TabBarStyle(rawValue: d.string(forKey: TabBarStyle.key) ?? "") ?? .floating
            d.set((cur == .floating ? TabBarStyle.docked : .floating).rawValue, forKey: TabBarStyle.key)
        }
        installObservers()
        refresh()
    }

    // MARK: 订阅（标签 / 会话 / 窗口 / 偏好）

    private func installObservers() {
        tabs.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.queueRefresh() }
            .store(in: &bag)
        tabs.$activeID
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.session.clearSearch() }   // 换标签 = 换一本书，上一本的命中不带过来
            .store(in: &bag)
        chrome.$isKeyWindow
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.queueRefresh() }
            .store(in: &bag)
        // md 笔记改名 / 被删 / 新导入 → 侧栏与标签栏跟着变
        workspace.$noteTrees
            .map { $0.flatMap { $0.root.allNotes.map(\.id) } }
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.tabs.tabs.forEach { $0.closeMarkdownIfGone() }
                self?.queueRefresh()
            }
            .store(in: &bag)
        // 平板跟随的是哪个标签（`padSession` 是计算属性，跟着 AppModel 的变化走；刷新本来就合并到下一拍）
        app.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.queueRefresh() }
            .store(in: &bag)
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.queueRefresh() }
        })
        observers.append(nc.addObserver(forName: NSScroller.preferredScrollerStyleDidChangeNotification, object: nil,
                                        queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.queueRefresh() }
        })
        let commands: [(Notification.Name, (ReaderPaneController) -> Void)] = [
            (.toggleNightMode, { _ in
                let d = UserDefaults.standard
                d.set(!d.bool(forKey: "nightMode"), forKey: "nightMode")
            }),
            (.toggleCanvasMode, { $0.tab.toggleCanvasMode() }),
            (.jumpBackRequested, { $0.session.jumpBack() }),
            (.jumpForwardRequested, { $0.session.jumpForward() }),
            (.toggleJumpHistory, { $0.jumpPanel.toggle() }),
            (.addBookmarkRequested, { c in if c.session.documentId != nil { c.session.beginBookmarkAtCurrent() } }),
            (.gotoPageRequested, { $0.promptGotoPage() }),
            (.toggleScanAlign, { $0.tab.toggleScanAlign() }),
            (.toggleScanEnhance, { c in
                guard c.session.pdf != nil else { return }
                ScanEnhance.toggle(c.session.contentHash)   // 写 UserDefaults，各阅读区自己听到后换图
            }),
        ]
        for (name, action) in commands {
            observers.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.chrome.isKeyWindow else { return }
                    action(self)
                }
            })
        }
        // 自动夜间：跟系统外观走
        observers.append(DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("AppleInterfaceThemeChangedNotification"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.syncAutoNight() }
        })
        syncAutoNight()
    }

    /// 当前标签的会话换了：重接会话上的订阅。
    private func bindSession() {
        let s = session
        guard boundSession !== s else { return }
        boundSession = s
        sessionBag.removeAll()
        s.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.queueRefresh() }
            .store(in: &sessionBag)
        tab.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.queueRefresh() }
            .store(in: &sessionBag)
        s.$searchQuery
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak s] _ in s?.scheduleSearch() }
            .store(in: &sessionBag)
    }

    private func syncAutoNight() {
        let d = UserDefaults.standard
        guard d.bool(forKey: "autoNightMode") else { return }
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        if d.bool(forKey: "nightMode") != dark { d.set(dark, forKey: "nightMode") }
    }

    /// 会话每次变化都会来（滚动时当前页也在变）：合并到下一拍只刷一次，且刷新本身只改真的变了的东西。
    private func queueRefresh() {
        guard !refreshQueued else { return }
        refreshQueued = true
        DispatchQueue.main.async { [weak self] in
            self?.refreshQueued = false
            self?.refresh()
        }
    }

    // MARK: 刷新

    private var tabBarStyle: TabBarStyle {
        TabBarStyle(rawValue: UserDefaults.standard.string(forKey: TabBarStyle.key) ?? "") ?? .floating
    }
    private var tabBarInset: CGFloat { TabBarMetrics.inset(style: tabBarStyle, tabCount: tabs.tabs.count) }
    private var legacyScroller: Bool { NSScroller.preferredScrollerStyle == .legacy }
    /// 占位式滚动条的槽固定在最底边：那时滚动条不让位，改由标签栏抬高一条槽的高度（2026-09-17 用户报）。
    private var scrollerLift: CGFloat {
        legacyScroller && tabBarInset > 0 ? NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy) : 0
    }

    func refresh() {
        bindSession()
        let s = session
        // Markdown 笔记标签（v15）：换一篇就重建（旧那份离开窗口时自己补存）。
        // 🔴 **不能在这里早退**——后面还有查找条 / 角标 / **标签栏**要刷，早退一次就是一个
        // 「开了笔记之后标签栏不更新」的 bug。
        if let ref = tab.noteRef {
            readerView?.removeFromSuperview(); readerView = nil
            placeholder.isHidden = true
            if mdView?.ref != ref {
                mdView?.flush()
                mdView?.removeFromSuperview()
                let v = MarkdownDocView(ref: ref, workspace: workspace)
                // 引擎回调给的是文件里写的那个**名字**（不是 NoteRef.key），统一交给 `note(key:)` 认
                v.onOpenNote = { [weak self] target in
                    guard let self, let item = self.workspace.note(key: target) else { return }
                    self.tabs.openMarkdown(item.ref)
                }
                v.onSearchStateChange = { [weak self] in self?.queueRefresh() }
                view.addSubview(v, positioned: .below, relativeTo: placeholder)
                mdView = v
                view.needsLayout = true
            }
        } else {
            if mdView != nil {
                mdView?.flush()
                mdView?.removeFromSuperview()
                mdView = nil
            }
            readerPart(s)
        }
        syncScratchPad()
        finishRefresh(s)
    }

    /// 阅读区本体（有 PDF 就建 / 复用 `ReaderView`，没有就是占位）。
    private func readerPart(_ s: DocSession) {
        // 阅读区：会话 / 显示身份（扫描页对齐一切换就变）/ PDF 变了才重建
        if s.pdf != nil {
            let key = s.displayKey.isEmpty ? "untitled" : s.displayKey
            if readerView == nil || readerView?.session !== s || readerView?.docKey != key {
                readerView?.removeFromSuperview()
                let r = ReaderView(session: s, app: app, workspace: workspace, docKey: key)
                r.onDropFiles = { [weak self] urls in self?.onIngest(urls) }
                view.addSubview(r, positioned: .below, relativeTo: placeholder)
                readerView = r
                view.needsLayout = true
            }
            placeholder.isHidden = true
        } else {
            readerView?.removeFromSuperview()
            readerView = nil
            placeholder.isHidden = false
            if let doc = tab.missingDoc {
                placeholder.set(symbol: "questionmark.folder", title: L("File Not Found"),
                                detail: String(format: L("All known paths for “%@” are unavailable. Re-link the file to continue."), doc.title),
                                button: L("Re-link File…")) { [weak self] in self?.onRelocate(doc) }
            } else {
                placeholder.set(symbol: "doc.richtext", title: L("No Document"), detail: L("Open a PDF to start reading."))
            }
        }
    }

    /// 阅读区 / 笔记区之外的那一堆（笔架 / 查找条 / 角标 / 标签栏…），两种内容都要跑。
    private func finishRefresh(_ s: DocSession) {
        if readerView != nil {
            if let rack = penRack {
                rack.bind(s)
            } else {
                let rack = PenRackNSView(app: app, session: s)
                view.addSubview(rack, positioned: .below, relativeTo: floating)
                penRack = rack
            }
        } else if let rack = penRack {
            rack.removeFromSuperview()
            penRack = nil
        }
        if let r = readerView {
            r.isActiveWindow = chrome.isKeyWindow
            r.interpEnabled = UserDefaults.standard.object(forKey: "scrollInterp") as? Bool ?? true
            // 滚动条始终贴窗格底边（用户 2026-09-19：横向滚动条别跑到浮动标签胶囊上面）；
            // 只有贴底整条的标签栏是实心条、会挡住它，那时才让到标签栏上面
            r.scrollerBottomInset = (legacyScroller || tabBarStyle == .floating) ? 0 : tabBarInset
        }

        // 查找条 / 角标
        let query = searchQuery
        let searching = !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        findBanner.isHidden = !searching
        if searching {
            if let mdView {
                findBanner.update(query: mdView.searchQuery, searching: false,
                                  currentIndex: mdView.currentSearchIndex, matchCount: mdView.searchRanges.count)
            } else {
                findBanner.update(s)
            }
        }
        if tab.isHashing {
            badge.set(symbol: "clock", text: L("Indexing…"))
            badge.isHidden = false
        } else if let p = tab.scanAlignProgress, s.pdf != nil {
            badge.set(symbol: "text.alignleft", text: String(format: L("Aligning scanned pages… %d/%d"), p.done, p.total))
            badge.isHidden = false
        } else {
            badge.isHidden = true
        }

        // 标签栏（≥2 个标签才显示；草稿纸开着时不显示——它自带工具条）
        let showTabs = tabs.tabs.count > 1 && s.openPadID == nil
        tabBar.isHidden = !showTabs
        if showTabs {
            tabBar.update(items: tabs.tabs.map {
                TabBarItem(id: $0.id, title: $0.tabTitle, padFollowing: $0.id == app.padSession?.id, hasDocument: $0.docID != nil)
            }, activeID: tabs.activeID, style: tabBarStyle)
        }
        // 参考窗 / 跳转历史：草稿纸开着时隐去（它盖满阅读区）
        jumpCard.bind(s)
        jumpCard.suppressed = s.openPadID != nil
        refCard.suppressed = s.openPadID != nil
        refCard.sync()
        syncDocPicker()
        syncBookmarkSheet()
        syncAlerts()
        layoutChrome()
    }

    /// 草稿纸：换一张 = 全新视口（新建一个视图）；开 / 关淡入淡出 0.16s。
    private func syncScratchPad() {
        let s = session
        let want = readerView != nil ? s.openPadID : nil
        // 阅读区重建过（换了显示身份）也要重建：新阅读区是插在最底下那一层之上的，旧纸会被它盖住
        if let cur = scratchPad, cur.padID == want, cur.session === s, cur.docKey == readerView?.docKey { return }
        if let old = scratchPad {
            scratchPad = nil
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.16
                old.animator().alphaValue = 0
            }, completionHandler: { old.removeFromSuperview() })
        }
        guard let id = want, let r = readerView else { return }
        let v = ScratchPadNSView(app: app, session: s, padID: id, docKey: r.docKey)
        v.alphaValue = 0
        view.addSubview(v, positioned: .above, relativeTo: r)
        scratchPad = v
        layoutChrome()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.16
            v.animator().alphaValue = 1
        }
    }

    /// 当前内容的查找状态。PDF 仍由 `DocSession` 管；Markdown 笔记由编辑器按屏幕上的 display text 管。
    var searchQuery: String { mdView?.searchQuery ?? session.searchQuery }

    /// 当前活动 Markdown 编辑器里的实时正文；不是这篇时不拿别篇视图的数据兜底。
    func markdownText(for ref: NoteRef) -> String? {
        guard let mdView, mdView.ref == ref else { return nil }
        return mdView.currentText
    }

    func applyMarkdownText(_ text: String, for ref: NoteRef) {
        guard let mdView, mdView.ref == ref else { return }
        mdView.applySavedText(text)
    }

    func setSearchQuery(_ value: String) {
        if let mdView { mdView.setSearchQuery(value) }
        else {
            session.searchQuery = value
            session.scheduleSearch()
        }
        queueRefresh()
    }

    @objc private func prevMatch() {
        if let mdView { mdView.previousSearchMatch() } else { session.prevMatch() }
    }
    @objc private func nextMatch() {
        if let mdView { mdView.nextSearchMatch() } else { session.nextMatch() }
    }

    // MARK: 布局

    /// 浮层摆在安全区里（让开侧栏 / 工具栏 / 右侧内置 AI 面板）；阅读区与空白提示铺满。
    /// 工具栏盖住窗格顶部多高。直接按窗口的 `contentLayoutRect`（工具栏以下的可用区）算，不单靠 `safeAreaInsets`：
    /// 分栏中间这一格的安全区顶边并不总是带上工具栏高度（AI 面板顶到工具栏底下、按钮点不着，2026-09-19 用户报）。
    private var toolbarInset: CGFloat {
        guard let win = view.window, view.superview != nil else { return view.safeAreaInsets.top }
        let usable = view.convert(win.contentLayoutRect, from: nil)   // 窗口坐标 → 本视图（翻转）坐标
        return max(view.safeAreaInsets.top, max(0, usable.minY))
    }

    private func layoutChrome() {
        let b = view.bounds
        let top = toolbarInset
        readerView?.frame = b
        // 阅读区外框铺到工具栏底下（页面滚上去从玻璃后面透过去），顶部内边距交给它自己让开工具栏那段高度。
        // 🔴 这一行 2026-09-19 删内置 AI 面板时被误删，后果是第一页整段压在工具栏底下（2026-09-20 用户报）。
        readerView?.topInset = top
        var si = view.safeAreaInsets
        si.top = top
        // 右侧被别的分栏项叠住的宽度（= 安全区右边）交给阅读区自己用 contentInsets 让开。
        // Inspector 2026-09-20 起是**真分栏**（`contentItem.automaticallyAdjustsSafeAreaInsets = false`），
        // 内容格外框本身就变窄了，所以这里恒为 0；这条路留着，将来再有叠在阅读区上的面板可以直接用。
        let panel = si.right
        readerView?.panelInset = panel
        ScrollerLog.write("窗格摆位 窗格\(Int(b.width))×\(Int(b.height)) 安全区[上\(Int(si.top)) 左\(Int(si.left)) 右\(Int(si.right))] 工具栏\(Int(top)) 标签栏\(Int(tabBarInset))")
        let safe = NSRect(x: si.left, y: si.top, width: max(0, b.width - si.left - si.right),
                          height: max(0, b.height - si.top - si.bottom))
        placeholder.frame = safe
        floating.frame = safe
        if let md = mdView {
            md.frame = NSRect(x: si.left, y: 0, width: max(0, b.width - si.left - si.right), height: b.height)
            md.topInset = si.top
        }
        if let pad = scratchPad {
            pad.frame = NSRect(x: 0, y: 0, width: max(0, b.width - panel), height: b.height)   // 给右侧 Inspector 让位
            pad.topInset = si.top
        }
        penRack?.place(viewport: NSRect(x: si.left, y: 0, width: max(0, b.width - si.left - panel), height: b.height),
                       topInset: si.top, bottomInset: tabBarInset + scrollerLift)
        if !findBanner.isHidden {
            let s = findBanner.fittingSize
            findBanner.frame = NSRect(x: safe.midX - s.width / 2, y: safe.minY + 8, width: s.width, height: max(30, s.height))
        }
        if !badge.isHidden {
            let s = badge.fittingSize
            let y = safe.minY + 8 + (findBanner.isHidden ? 0 : 38)
            badge.frame = NSRect(x: safe.midX - s.width / 2, y: y, width: s.width, height: s.height)
        }
        if !tabBar.isHidden {
            let h = TabBarNSView.height
            if tabBar.style == .floating {
                let w = min(tabBar.preferredWidth, max(60, safe.width - 48))
                tabBar.frame = NSRect(x: safe.midX - w / 2, y: b.height - TabBarMetrics.floatBottom - scrollerLift - h,
                                      width: w, height: h)
            } else {
                tabBar.frame = NSRect(x: safe.minX, y: b.height - scrollerLift - h, width: safe.width, height: h)
            }
        }
    }

    // MARK: 选文档弹窗（⌘T / 标签栏「+」）

    private func syncDocPicker() {
        if tabs.docPickerPresented {
            guard docPicker == nil else { return }
            let pop = NSPopover()
            pop.behavior = .transient
            let vc = DocPickerController.forTabs(tabs, workspace: workspace)
            pop.contentViewController = vc
            _ = vc.view
            pop.contentSize = vc.preferredContentSize
            let closer = PopoverCloseRelay { [weak self] in self?.tabs.docPickerPresented = false }
            pop.delegate = closer
            objc_setAssociatedObject(pop, &PopoverCloseRelay.key, closer, .OBJC_ASSOCIATION_RETAIN)
            docPicker = pop
            if !tabBar.isHidden {
                pop.show(relativeTo: tabBar.plus.bounds, of: tabBar.plus, preferredEdge: .maxY)
            } else {
                // 标签栏没显示（只有一个标签 / 草稿纸开着）：挂在阅读区底部正中
                let b = view.bounds
                pop.show(relativeTo: NSRect(x: b.midX, y: b.height - TabBarMetrics.floatBottom - 1, width: 1, height: 1),
                         of: view, preferredEdge: .maxY)
            }
        } else if let pop = docPicker {
            docPicker = nil
            pop.close()
        }
    }

    // MARK: 书签命名框（⌘D / 右键 / Inspector 目录页的 + 三条入口都只写 `session.bookmarkDraft`）

    private func syncBookmarkSheet() {
        let s = session
        if let draft = s.bookmarkDraft {
            guard bookmarkSheet == nil, let win = view.window else { return }
            let vc = BookmarkNameSheetController(
                draft: draft,
                onSave: { [weak s] title in s?.commitBookmarkDraft(title: title) },
                onCancel: { [weak s] in s?.bookmarkDraft = nil })
            let sheet = NSWindow(contentViewController: vc)
            bookmarkSheet = sheet
            win.beginSheet(sheet)
        } else if let sheet = bookmarkSheet {
            bookmarkSheet = nil
            view.window?.endSheet(sheet)
        }
    }

    // MARK: 跳转到指定页（⌃G）

    /// 弹一张系统提示框问页码，回车 / 「跳转」即跳（`session.jump`，与点目录、点缩略图同一条路，
    /// 所以进得了跳转历史、⌘[ 回得来）。没开 PDF（空标签 / Markdown 笔记）时什么都不做——
    /// 菜单项那边也会灰掉（`MainMenu.validateMenuItem`）。
    private func promptGotoPage() {
        guard !gotoPageShowing, let pdf = session.pdf, pdf.pageCount > 0, let win = view.window else { return }
        let total = pdf.pageCount
        let current = min(max(0, session.currentPageIndex), total - 1)
        gotoPageShowing = true

        let a = NSAlert()
        a.messageText = L("Go to Page")
        a.informativeText = String(format: L("Enter a page number between 1 and %d."), total)
        let go = a.addButton(withTitle: L("Go"))
        a.addButton(withTitle: L("Cancel"))
        let field = NSTextField(string: "\(current + 1)")
        field.frame = NSRect(x: 0, y: 0, width: 200, height: 24)
        field.alignment = .left
        // 回车 = 按「跳转」（NSAlert 的 accessory 里不接这一下的话，回车会先被输入框吃掉）
        field.target = go
        field.action = #selector(NSButton.performClick(_:))
        a.accessoryView = field
        a.window.initialFirstResponder = field

        a.beginSheetModal(for: win) { [weak self] resp in
            guard let self else { return }
            self.gotoPageShowing = false
            guard resp == .alertFirstButtonReturn else { return }
            // 输进来的是人用的页码（1 起），会话内部 0 起；超出范围就夹到两端，不报错也不静默跳过
            let typed = field.stringValue.trimmingCharacters(in: .whitespaces)
            guard let n = Int(typed) else { return }
            let idx = min(max(0, n - 1), total - 1)
            // 仍是这篇、这个标签才跳（弹着的时候可能已经切走了）
            guard self.session.pdf === pdf else { return }
            self.session.jump(page: idx, frac: 0, kind: .list,
                              label: String(format: L("Page %d"), idx + 1))
        }
        // 预填当前页码并全选：直接打数字就是覆盖，不用先清空。
        // 推到下一拍——`beginSheetModal` 返回时表单还没上屏，字段编辑器（`currentEditor`）此刻多半还不存在。
        DispatchQueue.main.async { field.currentEditor()?.selectAll(nil) }
    }

    // MARK: 确认弹窗（文件已变化 / 扫描页对齐）

    private func syncAlerts() {
        guard !alertShowing, let win = view.window else { return }
        let t = tab
        if let m = t.hashMismatch {
            alertShowing = true
            let a = NSAlert()
            a.messageText = L("File Changed")
            a.informativeText = String(format: L("The file “%@” was replaced on disk and no longer matches the version in your library. Link it as a new version of this document? (Notes are kept either way.)"),
                                       (m.path as NSString).lastPathComponent)
            a.addButton(withTitle: L("Link as New Version"))
            a.addButton(withTitle: L("Open Anyway"))
            a.beginSheetModal(for: win) { [weak self, weak t] resp in
                self?.alertShowing = false
                guard let t else { return }
                if resp == .alertFirstButtonReturn { t.linkAsNewVersion(m) } else { t.openAnyway(m) }
            }
        } else if let c = t.scanAlignConfirm {
            alertShowing = true
            let a = NSAlert()
            a.messageText = L("Align Scanned Pages")
            var parts: [String] = []
            if c.notes > 0 {
                parts.append(String(format: L("This document has %d annotations. They will not move with the pages and may end up out of place."), c.notes))
            }
            if c.ocrPages > 0 {
                parts.append(String(format: L("Text recognition results for %d pages will be cleared and need to be recognized again."), c.ocrPages))
            }
            if c.needsMeasure { parts.append(L("The whole document will be analyzed first, which may take a few seconds.")) }
            a.informativeText = parts.joined(separator: "\n\n")
            a.addButton(withTitle: c.turnOn ? L("Align Pages") : L("Turn Off Alignment"))
            a.addButton(withTitle: L("Cancel"))
            a.beginSheetModal(for: win) { [weak self, weak t] resp in
                self?.alertShowing = false
                guard let t else { return }
                if resp == .alertFirstButtonReturn { t.applyScanAlign(c) } else { t.scanAlignConfirm = nil }
            }
        }
    }

    deinit {
        for o in observers {
            NotificationCenter.default.removeObserver(o)
            DistributedNotificationCenter.default().removeObserver(o)
        }
    }
}

/// 窗格的根视图：拖进来的文件（PDF）交给窗口层入库；尺寸变了通知控制器重摆浮层。
final class ReaderPaneRootView: NSView {
    var onDrop: ([URL]) -> Void = { _ in }
    var onLayout: () -> Void = {}

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) 不支持") }

    override func layout() {
        super.layout()
        onLayout()
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = (sender.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                         options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        guard !urls.isEmpty else { return false }
        onDrop(urls)
        return true
    }
}

/// 弹出框关掉时回调一句（系统点外面收起时也能把模型里的「开着」标记清掉）。
final class PopoverCloseRelay: NSObject, NSPopoverDelegate {
    static var key: UInt8 = 0
    private let onClose: () -> Void
    init(_ onClose: @escaping () -> Void) { self.onClose = onClose }
    func popoverDidClose(_ notification: Notification) { onClose() }
}
