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
    private let placeholder = PlaceholderView()
    private let findBanner = FindBannerView()
    private let badge = StatusBadgeView()
    private let tabBar = TabBarNSView()
    private var panels: InlineAIPanelsView!
    /// 参考窗覆盖层 / 跳转历史：摆在安全区里（让开工具栏与内置 AI 面板），身份跟窗口走（切标签不重建）。
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
        // 右侧两块内置 AI 面板：最上层，浮在阅读区上；盖住的宽度交给阅读区适配、浮层跟着让位
        panels = InlineAIPanelsView(windowID: tabs.windowID, workspace: workspace)
        panels.onInset = { [weak self] inset, animated in
            guard let self else { return }
            self.readerView?.panelInset = inset
            if animated {
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.28
                    ctx.allowsImplicitAnimation = true
                    self.layoutChrome()
                }
            } else {
                self.layoutChrome()
            }
        }
        v.addSubview(panels)
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
            (.toggleScanAlign, { $0.tab.toggleScanAlign() }),
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
        // 阅读区：会话 / 显示身份（扫描页对齐一切换就变）/ PDF 变了才重建
        if s.pdf != nil {
            let key = s.displayKey.isEmpty ? "untitled" : s.displayKey
            if readerView == nil || readerView?.session !== s || readerView?.docKey != key {
                readerView?.removeFromSuperview()
                let r = ReaderView(session: s, app: app, workspace: workspace, docKey: key)
                r.onDropFiles = { [weak self] urls in self?.onIngest(urls) }
                r.panelInset = panels.inset
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
        syncScratchPad()
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
            r.scrollerBottomInset = legacyScroller ? 0 : tabBarInset
        }

        // 查找条 / 角标
        let searching = !s.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        findBanner.isHidden = !searching
        if searching { findBanner.update(s) }
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

    @objc private func prevMatch() { session.prevMatch() }
    @objc private func nextMatch() { session.nextMatch() }

    // MARK: 布局

    /// 浮层摆在安全区里（让开侧栏 / 工具栏 / 右侧内置 AI 面板）；阅读区与空白提示铺满。
    /// 工具栏盖住窗格顶部多高。直接按窗口的 `contentLayoutRect`（工具栏以下的可用区）算，不单靠 `safeAreaInsets`：
    /// 分栏中间这一格的安全区顶边并不总是带上工具栏高度（AI 面板顶到工具栏底下、按钮点不着，2026-09-19 用户报）。
    private var toolbarInset: CGFloat {
        guard let win = view.window, view.superview != nil else { return view.safeAreaInsets.top }
        let usable = view.convert(win.contentLayoutRect, from: nil)   // 窗口坐标 → 本视图（翻转）坐标
        return max(view.safeAreaInsets.top, max(0, usable.minY))
    }
    private var loggedInset: (CGFloat, CGFloat)?

    private func layoutChrome() {
        let b = view.bounds
        let top = toolbarInset
        if loggedInset.map({ $0 != (top, view.safeAreaInsets.top) }) ?? true {
            loggedInset = (top, view.safeAreaInsets.top)
            wsLog("[PANE] 顶部让位 = \(top)（safeAreaInsets.top = \(view.safeAreaInsets.top)）")
        }
        readerView?.frame = b
        readerView?.topInset = top
        panels.frame = b
        panels.topInset = top
        let panel = panels.inset
        var si = view.safeAreaInsets
        si.top = top
        let safe = NSRect(x: si.left, y: si.top, width: max(0, b.width - si.left - si.right - panel),
                          height: max(0, b.height - si.top - si.bottom))
        placeholder.frame = safe
        floating.frame = safe
        if let pad = scratchPad {
            pad.frame = NSRect(x: 0, y: 0, width: max(0, b.width - panel), height: b.height)   // 给右侧内置 AI 面板让位
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
