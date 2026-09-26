import AppKit
import Combine

/// 右侧 Inspector（AppKit 版，替代 SwiftUI `InspectorView`，内容与行为逐项同原版）：
/// 顶部系统分段切「信息 / 缩略图 / 目录 / 笔记 / Agent」；笔记页再分几个二级分区（记在 `inspectorNotesSection`）。
/// 只刷新看得见的那一页；会话变化合并到下一拍刷一次，且各页按「数据签名」没变就不重建。
/// 「Agent」页 = 本窗口的 Agent 对话（2026-09-19 起 Agent 面板只住在这里）；设置里关掉 Agent 就没有这一段。
@MainActor
final class InspectorViewController: NSViewController {
    let tabs: TabsModel
    let workspace: WorkspaceManager
    /// 切了页（阅读窗口据此刷工具栏 Agent 开关的按下态）。
    var onTabChange: () -> Void = {}
    var currentTab: InspectorTab { tab }

    private let tabControl = NSSegmentedControl()
    private let sectionControl = NSSegmentedControl()
    private let pageHost = NSView()
    private let listScroll = NSScrollView()
    private let listStack = FlippedStackView()
    private let thumbs = ThumbnailListNSView()
    private let toc = TOCOutlineView()
    private let tocAddBookmark = NSButton()
    private let tocPage = NSView()
    private let emptyLabel = NSTextField(wrappingLabelWithString: "")
    private let agentPage = NSView()
    private var agentView: AgentChatNSView?
    private let agentPlaceholder = PlaceholderView()

    private var tab: InspectorTab = .info
    /// 顶部分段此刻有哪几页（Agent 关掉时没有最后那段）。
    private var tabList: [InspectorTab] = []
    private var bag = Set<AnyCancellable>()
    private var sessionBag = Set<AnyCancellable>()
    private weak var boundSession: DocSession?
    private var refreshQueued = false
    private var lastSignature = ""
    private var inkSummaries: [InkPageSummary] = []
    private var inkLoadToken = 0
    private var inkExpanded = true
    private var variants: [LibVariant] = []
    private var locations: [LibLocation] = []
    private var locationsDoc: String?
    /// 还没建成视图的条目（滚到哪建到哪，见 `appendBatch`）。
    private var pendingItems: [() -> NSView] = []
    /// 这一屏已经建出来的条目数；重建列表时照这个数补回去，免得改一条笔记就被拽回第一批。
    private var loadedItems = 0
    /// 重建列表时至少要补回的条目数（见 `rebuild`）。
    private var restoreTarget = 0
    /// 下一拍已经排了建批的活，别重复排。
    private var batchScheduled = false
    /// 一拍建多少条（实测一张卡片 ≈1.4ms 构造 + 布局，12 条一拍 ≈17ms，不掉帧）。
    private static let batchSize = 12

    private static let sectionKey = "inspectorNotesSection"
    private var notesSection: NotesSection {
        get {
            let s = NotesSection(rawValue: UserDefaults.standard.string(forKey: Self.sectionKey) ?? "") ?? .text
            return sections.contains(s) ? s : .text
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: Self.sectionKey) }
    }
    /// 二级分区：网页 AI 停用期间没有「AI 对话」（`AIPanelModel.available`）。
    private let sections = NotesSection.allCases.filter { $0 != .ai || AIPanelModel.available }

    init(tabs: TabsModel, workspace: WorkspaceManager) {
        self.tabs = tabs
        self.workspace = workspace
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) 不支持") }

    private var session: DocSession { tabs.active.session }
    private var documentId: String? { tabs.active.docID }

    // MARK: 视图

    override func loadView() {
        let root = FlippedView()
        tabControl.segmentDistribution = .fillEqually
        tabControl.trackingMode = .selectOne
        // 顶部分段 = 切页的标签（Xcode 的 Inspector 同款）：macOS 27 起用 `role = .tabs`，
        // 选中块的液态玻璃滑动由系统画，我们不自绘（用户 2026-09-20）。
        if #available(macOS 27.0, *) { tabControl.role = .tabs }
        tabControl.target = self
        tabControl.action = #selector(tabChanged)
        rebuildTabControl()
        sectionControl.segmentCount = sections.count
        for (i, s) in sections.enumerated() {
            sectionControl.setImage(NSImage(systemSymbolName: s.icon, accessibilityDescription: s.title), forSegment: i)
            sectionControl.setToolTip(s.title, forSegment: i)
        }
        sectionControl.segmentDistribution = .fillEqually
        sectionControl.trackingMode = .selectOne
        if #available(macOS 27.0, *) { sectionControl.role = .tabs }   // 与顶部分段同款液态玻璃
        sectionControl.target = self
        sectionControl.action = #selector(sectionChanged)

        listStack.orientation = .vertical
        listStack.alignment = .leading
        listStack.spacing = 8
        listStack.edgeInsets = NSEdgeInsets(top: 12, left: 16, bottom: 16, right: 16)
        listScroll.documentView = listStack
        listScroll.drawsBackground = false
        listScroll.hasVerticalScroller = true
        listScroll.autohidesScrollers = true
        listStack.translatesAutoresizingMaskIntoConstraints = false
        listStack.widthAnchor.constraint(equalTo: listScroll.contentView.widthAnchor).isActive = true
        listScroll.contentView.postsBoundsChangedNotifications = true

        tocAddBookmark.title = L("Add Bookmark")
        tocAddBookmark.image = NSImage(systemSymbolName: "bookmark", accessibilityDescription: nil)
        tocAddBookmark.imagePosition = .imageLeading
        tocAddBookmark.isBordered = false
        tocAddBookmark.contentTintColor = .labelColor   // 红线：玻璃底上别用次要色
        tocAddBookmark.target = self
        tocAddBookmark.action = #selector(addBookmark)
        tocPage.addSubview(tocAddBookmark)
        tocPage.addSubview(toc)
        toc.onSelect = { [weak self] e in
            guard let self, let page = e.pageIndex else { return }
            self.session.jump(page: page, frac: e.frac, kind: .toc, label: e.label)
        }
        toc.onSelectBookmark = { [weak self] b in self?.session.jump(page: b.page, frac: b.frac, kind: .toc, label: b.title) }
        toc.onRenameBookmark = { [weak self] b in self?.session.beginBookmarkRename(b) }
        toc.onDeleteBookmark = { [weak self] b in self?.session.deleteBookmark(id: b.id) }
        thumbs.onSelect = { [weak self] p in self?.session.jump(page: p, frac: 0, kind: .list) }

        emptyLabel.alignment = .center
        emptyLabel.textColor = .labelColor
        for v in [tabControl, sectionControl, pageHost, emptyLabel] as [NSView] { root.addSubview(v) }
        for v in [listScroll, thumbs, tocPage, agentPage] as [NSView] { pageHost.addSubview(v) }
        agentPlaceholder.set(symbol: "folder", title: L("No Workspace"), detail: L("Open a workspace to talk to the agent about it."))
        view = root
        installObservers()
        applyTab()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        let b = view.bounds
        let top = view.safeAreaInsets.top
        tabControl.frame = NSRect(x: 12, y: top + 10, width: b.width - 24, height: 28)
        var y = tabControl.frame.maxY + 8
        if !sectionControl.isHidden {
            sectionControl.frame = NSRect(x: 12, y: y, width: b.width - 24, height: 24)
            y = sectionControl.frame.maxY + 6
        }
        pageHost.frame = NSRect(x: 0, y: y, width: b.width, height: max(0, b.height - y))
        for v in [listScroll, thumbs, tocPage, agentPage] as [NSView] { v.frame = pageHost.bounds }
        for v in agentPage.subviews { v.frame = agentPage.bounds }
        let bs = tocAddBookmark.fittingSize
        tocAddBookmark.frame = NSRect(x: tocPage.bounds.width - 12 - bs.width, y: 0, width: bs.width, height: bs.height)
        toc.frame = NSRect(x: 0, y: bs.height + 6, width: tocPage.bounds.width, height: max(0, tocPage.bounds.height - bs.height - 6))
        emptyLabel.frame = NSRect(x: 20, y: b.height / 2 - 30, width: b.width - 40, height: 60)
        // 窗口变高 / 列表刚建完第一批：可视区还空着就接着建（滚动那一路走 `boundsDidChange`）
        loadMoreIfNeeded()
    }

    // MARK: 订阅

    private func installObservers() {
        // 滚动到离底不足一屏就再建一批条目
        NotificationCenter.default.publisher(for: NSView.boundsDidChangeNotification, object: listScroll.contentView)
            .sink { [weak self] _ in self?.loadMoreIfNeeded() }
            .store(in: &bag)
        tabs.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.queueRefresh() }
            .store(in: &bag)
        workspace.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.queueRefresh() }
            .store(in: &bag)
        // 设置里开 / 关 Agent：分段加 / 减最后那段；关掉时对话已被模型结束，视图一并丢掉
        AgentPanelModel.shared.$enabled
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                if !AgentPanelModel.shared.enabled { self.dropAgentView() }
                self.rebuildTabControl()
            }
            .store(in: &bag)
    }

    /// 顶部分段按当前可用的页重建（只在页的组成变了时动）；当前页没了就回「信息」。
    private func rebuildTabControl() {
        var defs: [(InspectorTab, String, String)] = [
            (.info, "info.circle", L("Info")), (.thumbnails, "rectangle.grid.1x2", L("Thumbnails")),
            (.contents, "list.bullet.indent", L("Contents")), (.notes, "note.text", L("Notes")),
        ]
        if AgentPanelModel.shared.enabled { defs.append((.agent, "sparkles", L("Agent"))) }
        let list = defs.map(\.0)
        guard list != tabList else { return }
        tabList = list
        tabControl.segmentCount = defs.count
        for (i, d) in defs.enumerated() {
            tabControl.setImage(NSImage(systemSymbolName: d.1, accessibilityDescription: d.2), forSegment: i)
            tabControl.setToolTip(d.2, forSegment: i)
        }
        if !list.contains(tab) {
            show(tab: .info)
        } else {
            tabControl.selectedSegment = list.firstIndex(of: tab) ?? 0
        }
    }

    /// 切到某一页（Agent 开关 / 框选截图投给 Agent 从外面调）。
    func show(tab t: InspectorTab) {
        guard tabList.contains(t) else { return }
        tabControl.selectedSegment = tabList.firstIndex(of: t) ?? 0
        guard t != tab else { return }
        tab = t
        applyTab()
        onTabChange()
    }

    private func bindSession() {
        let s = session
        guard boundSession !== s else { return }
        boundSession = s
        sessionBag.removeAll()
        lastSignature = ""
        resetPaging()   // 换了文档 = 换了一份列表
        s.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.queueRefresh() }
            .store(in: &sessionBag)
        // 笔迹按页汇总：每写一笔 `inkRev` 都变，歇 0.3s 再查（连着写字时前面的请求作废）
        s.$strokes
            .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.loadInkSummaries() }
            .store(in: &sessionBag)
        loadInkSummaries()
    }

    private func queueRefresh() {
        guard !refreshQueued else { return }
        refreshQueued = true
        DispatchQueue.main.async { [weak self] in
            self?.refreshQueued = false
            self?.refresh()
        }
    }

    // MARK: 切页

    @objc private func tabChanged() {
        tab = tabList[max(0, min(tabControl.selectedSegment, tabList.count - 1))]
        applyTab()
        onTabChange()
    }

    @objc private func sectionChanged() {
        notesSection = sections[max(0, sectionControl.selectedSegment)]
        lastSignature = ""
        resetPaging()
        refresh()
    }

    @objc private func addBookmark() { session.beginBookmarkAtCurrent() }

    private func applyTab() {
        sectionControl.isHidden = tab != .notes
        sectionControl.selectedSegment = sections.firstIndex(of: notesSection) ?? 0
        lastSignature = ""
        resetPaging()
        view.needsLayout = true
        refresh()
    }

    // MARK: 刷新

    private func refresh() {
        bindSession()
        let s = session
        thumbs.isHidden = tab != .thumbnails
        tocPage.isHidden = tab != .contents
        agentPage.isHidden = tab != .agent
        let needsDoc = tab == .info || tab == .notes
        let doc = documentId.flatMap { workspace.document(id: $0) }
        listScroll.isHidden = !(needsDoc && doc != nil)
        emptyLabel.isHidden = !(needsDoc && doc == nil)
        if needsDoc && doc == nil {
            emptyLabel.stringValue = "\(L("No Document"))\n\(L("Select a document to see its info and notes."))"
        }
        switch tab {
        case .agent:
            ensureAgentContent()
        case .thumbnails:
            thumbs.update(pdf: s.pdf, docKey: s.displayKey, align: s.scanAlign, currentPage: s.currentPageIndex)
        case .contents:
            tocAddBookmark.isEnabled = s.documentId != nil
            toc.update(entries: s.toc, bookmarks: s.bookmarks, currentPage: s.currentPageIndex)
        case .info:
            guard let doc else { return }
            if locationsDoc != doc.id { reloadLocations(doc.id) }
            let sig = "info|\(doc.id)|\(doc.title)|\(s.currentPageIndex)|\(locations.map { "\($0.id)\($0.isValid)" })"
            guard sig != lastSignature else { return }
            lastSignature = sig
            rebuild(infoRows(doc))
        case .notes:
            guard doc != nil else { return }
            let sig = notesSignature()
            guard sig != lastSignature else { return }
            lastSignature = sig
            rebuild(notesRows())
        }
    }

    // MARK: Agent 页

    /// 头一次切到 Agent 页才建对话视图（视图进窗口时才连 Agent，别让没打开过的窗口白拉起进程）；
    /// 换了工作区 → 模型给的是另一份对话，视图重建。
    private func ensureAgentContent() {
        guard AgentPanelModel.shared.enabled else { return }
        guard let folder = workspace.folder else {
            dropAgentView()
            setAgentContent(agentPlaceholder)
            return
        }
        let chat = AgentPanelModel.shared.chat(for: tabs.windowID, cwd: folder.deletingLastPathComponent())
        if agentView?.chat !== chat {
            let v = AgentChatNSView(chat: chat, workspaceName: workspace.name, showsHeader: true)
            agentView = v
            setAgentContent(v)
        } else if agentView?.workspaceName != workspace.name {
            agentView?.workspaceName = workspace.name
        }
    }

    private func setAgentContent(_ v: NSView) {
        guard v.superview !== agentPage else { return }
        for s in agentPage.subviews { s.removeFromSuperview() }
        v.frame = agentPage.bounds
        agentPage.addSubview(v)
    }

    private func dropAgentView() {
        agentView?.removeFromSuperview()
        agentView = nil
    }

    // MARK: 列表分页

    /// 重建列表：头部（标题 / 筛选器这些，条数固定）当场建，条目**一条都不当场建**。
    /// 🔴 切页那一拍里一条都别建：实测一张卡片 ≈0.6ms 构造 + 0.8ms 布局 + 1ms 绘制，
    /// 首屏 30 条就是 70ms 上下，切到「笔记」页会明显顿一下（用户 2026-09-20 报）。
    /// 所以切过去先把页面切开、列表留空，条目按拍补（`scheduleBatch`），每拍只建一小批。
    private func rebuild(_ rows: InspectorRows) {
        for v in listStack.arrangedSubviews { listStack.removeArrangedSubview(v); v.removeFromSuperview() }
        for v in rows.head { addRow(v) }
        pendingItems = rows.items
        // 重建前已经建出多少条，就补回多少条：删一条 / 改一条笔记会重建整张列表，
        // 要是退回第一批，用户滚到的位置就没了。这一段同样按拍补，不在一拍里补几百条。
        restoreTarget = min(loadedItems, rows.items.count)
        loadedItems = 0
        loadMoreIfNeeded()
    }

    private func rebuild(_ views: [NSView]) { rebuild(InspectorRows(head: views)) }

    private func addRow(_ v: NSView) {
        listStack.addArrangedSubview(v)
        v.widthAnchor.constraint(equalTo: listStack.widthAnchor, constant: -32).isActive = true
    }

    /// 建下一批条目。
    private func appendBatch() {
        guard !pendingItems.isEmpty else { return }
        let n = min(Self.batchSize, pendingItems.count)
        for make in pendingItems.prefix(n) { addRow(make()) }
        pendingItems.removeFirst(n)
        loadedItems += n
    }

    /// 还该不该接着建：补回重建前的条数，或者内容还没盖过「可视区再往下一屏」。
    private func needsMoreItems() -> Bool {
        guard !pendingItems.isEmpty else { return false }
        if loadedItems < restoreTarget { return true }
        let clip = listScroll.contentView.bounds
        guard clip.height > 0, !listScroll.isHidden else { return false }
        return listStack.frame.height - clip.maxY < clip.height
    }

    /// 要建就排到下一拍建（切页 / 滚动 / 布局都走这里）。每拍只建一小批，建完接着排下一拍，
    /// 直到填满可视区——这样主线程每拍只占十几毫秒，切页和滚动都不会被卡住。
    private func loadMoreIfNeeded() {
        guard !batchScheduled, needsMoreItems() else { return }
        batchScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.batchScheduled = false
            self.appendBatch()
            self.listStack.layoutSubtreeIfNeeded()   // 量到新高度，下一拍才知道还差多少
            self.loadMoreIfNeeded()
        }
    }

    /// 把一串数据包成「怎么建」的闭包。🔴 `self` 一律弱捕获——这些闭包由 `self` 存着（`pendingItems`），
    /// 强捕获就是一个环，列表没滚完的窗口关掉后整个 Inspector 都不释放。
    private func lazyItems<T>(_ list: [T], _ make: @escaping (InspectorViewController, T) -> NSView) -> [() -> NSView] {
        list.map { e in { [weak self] in self.map { make($0, e) } ?? NSView() } }
    }

    /// 换了页 / 换了分区 / 换了文档：列表是另一份了，从第一批重来并回到顶部。
    private func resetPaging() {
        loadedItems = 0
        restoreTarget = 0
        pendingItems = []
        listScroll.contentView.scroll(to: .zero)
        listScroll.reflectScrolledClipView(listScroll.contentView)
    }

    private func reloadLocations(_ id: String) {
        locationsDoc = id
        variants = workspace.variants(documentId: id)
        locations = workspace.locations(documentId: id)
    }

    private func loadInkSummaries() {
        inkLoadToken += 1
        let token = inkLoadToken
        let store = session.store, doc = documentId
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let loaded = InkPageSummary.load(store: store, documentId: doc)
            DispatchQueue.main.async {
                guard let self, token == self.inkLoadToken else { return }
                self.inkSummaries = loaded
                if self.tab == .notes, self.notesSection == .ink { self.lastSignature = ""; self.refresh() }
            }
        }
    }

    // MARK: 信息页

    private func infoRows(_ doc: LibDocument) -> [NSView] {
        var out: [NSView] = [sectionTitle(L("Document"))]
        let cur = min(session.currentPageIndex + 1, max(1, doc.pageCount))
        let pct = doc.pageCount > 0 ? Int((Double(cur) / Double(doc.pageCount) * 100).rounded()) : 0
        out.append(kvRow(L("Title"), doc.title))
        out.append(kvRow(L("Pages"), "\(doc.pageCount)"))
        out.append(kvRow(L("Progress"), "\(cur) / \(doc.pageCount) · \(pct)%"))
        out.append(kvRow(L("Added"), doc.addedAt.formatted(date: .abbreviated, time: .shortened)))
        out.append(kvRow(L("Last Opened"), doc.lastOpenedAt.formatted(date: .abbreviated, time: .shortened)))
        out.append(spacer(14))
        out.append(sectionTitle("\(L("Files")) · \(locations.count)"))
        let hashByVar = Dictionary(variants.map { ($0.id, $0.contentHash) }, uniquingKeysWith: { a, _ in a })
        for l in locations {
            let name = label(URL(fileURLWithPath: l.path).lastPathComponent, .callout)
            name.lineBreakMode = .byTruncatingTail
            var badges: [NSView] = []
            if l.inWorkspace { badges.append(badge(L("In Workspace"), .systemGreen)) }
            else if l.isRelative { badges.append(badge(L("Same Drive"), .systemBlue)) }
            if !l.isValid { badges.append(badge(L("Missing"), .systemOrange)) }
            let hash = label(String((hashByVar[l.variantId] ?? "").prefix(8)), .caption2)
            hash.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize - 2, weight: .regular)
            hash.textColor = .labelColor
            let line = hstack([name] + badges + [flexible(), hash])
            let path = label(workspace.resolvedPath(l), .caption2)
            path.textColor = .labelColor
            path.lineBreakMode = .byTruncatingMiddle
            var buttons: [NSButton] = []
            if locations.count > 1 {   // 至少保留一项
                buttons.append(iconButton("xmark.circle.fill",
                                          l.inWorkspace ? L("Delete this workspace copy") : L("Remove this file entry")) { [weak self] in
                    guard let self, self.locations.count > 1 else { return }
                    self.workspace.deleteLocation(l)
                    self.reloadLocations(doc.id)
                    self.lastSignature = ""
                    self.refresh()
                })
            }
            out.append(InspectorCard(content: vstack([line, path], spacing: 5), buttons: buttons))
        }
        return out
    }

    // MARK: 笔记页

    /// 列表内容的指纹（没变就不重建）。🔴 别拿字符串拼：会话每变一下（翻页也算）都要跑一次，
    /// 上千条笔记时每次都在造一个几十 KB 的串再扔掉；一路 `Hasher` 只出 8 个字节。
    private func notesSignature() -> String {
        let s = session
        var h = Hasher()
        h.combine(notesSection)
        switch notesSection {
        case .text:
            for n in s.textNotes { h.combine(n.id); h.combine(n.updatedAt) }
            switch s.noteTypeFilter {
            case .all: h.combine(0)
            case .only(let id): h.combine(1); h.combine(id)
            }
            for t in s.noteTypes { h.combine(t.id) }
        case .highlight:
            for x in s.highlights { h.combine(x.id); h.combine(x.updatedAt) }
        case .image:
            for x in s.imageNotes { h.combine(x.id); h.combine(x.updatedAt) }
        case .bookmark:
            for b in s.bookmarks { h.combine(b.id); h.combine(b.title); h.combine(b.page) }
        case .ink:
            for k in inkSummaries { h.combine(k.page); h.combine(k.count) }
            h.combine(inkExpanded)
        case .scratch:
            for p in s.scratchPads { h.combine(p.id) }
            h.combine(s.scratchStrokes.count)
        case .ai:
            for t in s.aiThreads { h.combine(t.id); h.combine(t.title); h.combine(t.state) }
        }
        return String(h.finalize())
    }

    private func notesRows() -> InspectorRows {
        switch notesSection {
        case .text: return textRows()
        case .highlight: return highlightRows()
        case .image: return imageRows()
        case .bookmark: return bookmarkRows()
        case .ink: return inkRows()
        case .scratch: return scratchRows()
        case .ai: return aiRows()
        }
    }

    private func jump(_ page: Int, _ frac: Double) { session.jump(page: page, frac: frac, kind: .list) }

    private func textRows() -> InspectorRows {
        let s = session
        let filtered = s.textNotes.filter { n in
            switch s.noteTypeFilter {
            case .all: return true
            case .only(let id): return n.typeId == id
            }
        }
        var head: [NSView] = [sectionTitle("\(L("Text Notes")) · \(filtered.count)")]
        guard !s.textNotes.isEmpty else { head.append(hint(L("No text notes yet."))); return InspectorRows(head: head) }
        head.append(typeFilterButton())
        return InspectorRows(head: head, items: lazyItems(filtered) { me, n in me.textCard(n) })
    }

    private func textCard(_ n: TextNote) -> NSView {
        let s = session
        let t = NoteType.resolve(n.typeId, in: s.noteTypes)
        let dot = NSView()
        dot.wantsLayer = true
        dot.layer?.backgroundColor = t.nsColor.cgColor
        dot.layer?.cornerRadius = 4
        dot.widthAnchor.constraint(equalToConstant: 8).isActive = true
        dot.heightAnchor.constraint(equalToConstant: 8).isActive = true
        var head: [NSView] = [dot, symbolLabel(t.icon, String(format: L("Page %d"), n.page + 1))]
        if t.id != NoteType.generalID {
            let tn = label(t.name, .caption1); tn.textColor = .labelColor; head.append(tn)
        }
        var lines: [NSView] = [hstack(head)]
        if !n.text.isEmpty { lines.append(multiline(NoteMarkdown.plain(n.text), .callout, lines: 2)) }
        if !n.quote.isEmpty {
            let q = multiline(n.quote.flattenedQuote, .caption1, lines: 2)
            q.textColor = .labelColor
            lines.append(q)
        }
        var buttons: [NSButton] = []
        if let src = n.source, src.isAI, AIPanelModel.shared.enabled {
            buttons.append(iconButton("bubble.left.and.text.bubble.right", L("Open the AI conversation this came from"),
                                      tint: .labelColor) { [weak self] in self?.openAISource(src) })
        } else if let src = n.source, src.isAgent {
            let b = iconButton("terminal", String(format: L("Written by an agent (%@)"), src.provider), tint: .labelColor) {}
            b.isEnabled = false
            buttons.append(b)
        }
        let id = n.id
        // 编辑：跟图片笔记一样发通知给本会话的阅读区，由它弹批注编辑器（`ReaderView.openNoteEditor`）
        buttons.append(iconButton("pencil.circle.fill", L("Edit this note"), tint: .labelColor) { [weak self] in
            guard let self else { return }
            NotificationCenter.default.post(name: .textNoteEdit,
                                            object: NoteRequest(sessionID: self.session.id, noteID: id))
        })
        buttons.append(iconButton("xmark.circle.fill", L("Delete this note")) { [weak self] in
            guard let s = self?.session else { return }
            s.inkEdit("Delete", kind: .delete) { s.textNotes.removeAll { $0.id == id } }
        })
        let card = InspectorCard(content: vstack(lines, spacing: 5), buttons: buttons)
        card.onTap = { [weak self] in self?.jump(n.page, max(0, Double(n.anchor.minY) - 0.03)) }
        return card
    }

    private func typeFilterButton() -> NSView {
        let s = session
        let title: String
        switch s.noteTypeFilter {
        case .all: title = L("All Types")
        case .only(let id):
            title = id.flatMap { i in s.noteTypes.first { $0.id == i }?.name } ?? L("General")
        }
        let b = NSPopUpButton(frame: .zero, pullsDown: true)
        b.isBordered = false
        b.font = .preferredFont(forTextStyle: .caption1)
        let menu = NSMenu()
        let head = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        head.image = NSImage(systemSymbolName: "line.3.horizontal.decrease.circle", accessibilityDescription: nil)
        menu.addItem(head)
        let all = ClosureMenuItem(L("All Types")) { [weak s] in s?.noteTypeFilter = .all }
        all.image = NSImage(systemSymbolName: "line.3.horizontal.decrease.circle", accessibilityDescription: nil)
        menu.addItem(all)
        let gen = ClosureMenuItem(L("General")) { [weak s] in s?.noteTypeFilter = .only(nil) }
        gen.image = NSImage(systemSymbolName: NoteType.general.iconName, accessibilityDescription: nil)
        menu.addItem(gen)
        for t in s.noteTypes {
            let i = ClosureMenuItem(t.name) { [weak s] in s?.noteTypeFilter = .only(t.id) }
            i.image = NSImage(systemSymbolName: t.icon, accessibilityDescription: nil)
            menu.addItem(i)
        }
        b.menu = menu
        return b
    }

    private func openAIThread(_ t: AIThread) {
        guard let docId = documentId else { return }
        let s = session
        AIPanelModel.shared.present(window: s.windowID)
        AIPanelModel.shared.openThread(t, in: AIBindContext(sessionID: s.id, documentId: docId, docTitle: s.title,
                                                            page: t.page, anchor: t.anchor))
    }

    private func openAISource(_ src: NoteSource) {
        if let tid = src.threadId, let t = session.aiThreads.first(where: { $0.id == tid }) { openAIThread(t); return }
        AIPanelModel.shared.present(window: session.windowID)
        AIPanelModel.shared.openLoose(src.url, provider: src.provider)
    }

    private func highlightRows() -> InspectorRows {
        let s = session
        var head: [NSView] = [sectionTitle("\(L("Highlights")) · \(s.highlights.count)")]
        guard !s.highlights.isEmpty else { head.append(hint(L("No highlights yet."))); return InspectorRows(head: head) }
        return InspectorRows(head: head, items: lazyItems(s.highlights) { me, h in me.highlightCard(h) })
    }

    private func highlightCard(_ h: Highlight) -> NSView {
        let swatch = NSView()
        swatch.wantsLayer = true
        swatch.layer?.backgroundColor = h.color.nsColor.cgColor
        swatch.layer?.cornerRadius = 3
        swatch.widthAnchor.constraint(equalToConstant: 12).isActive = true
        swatch.heightAnchor.constraint(equalToConstant: 12).isActive = true
        var lines: [NSView] = [symbolLabel(h.style.iconName, String(format: L("Page %d"), h.page + 1))]
        if !h.quote.isEmpty {
            let q = multiline(h.quote.flattenedQuote, .caption1, lines: 2)
            q.textColor = .labelColor
            lines.append(q)
        }
        let id = h.id
        let card = InspectorCard(content: hstack([swatch, vstack(lines, spacing: 5)], alignment: .top, spacing: 8),
                                 buttons: [iconButton("xmark.circle.fill", L("Delete this highlight")) { [weak self] in
                                     self?.session.highlights.removeAll { $0.id == id }
                                 }])
        card.onTap = { [weak self] in self?.jump(h.page, max(0, Double(h.anchor.minY) - 0.03)) }
        // 右键：换色 / 换画法 / 删除（与页面上的高亮气泡对应）
        card.menuProvider = { [weak self] in
            let m = NSMenu()
            let colors = NSMenu()
            for item in Highlight.palette {
                colors.addItem(ClosureMenuItem(L(item.name)) { self?.recolor(id, item.color) })
            }
            let c = NSMenuItem(title: L("Highlight Color"), action: nil, keyEquivalent: "")
            c.submenu = colors
            m.addItem(c)
            let styles = NSMenu()
            for st in HighlightStyle.allCases {
                let i = ClosureMenuItem(st.title) { self?.restyle(id, st) }
                i.state = h.style == st ? .on : .off
                styles.addItem(i)
            }
            let sm = NSMenuItem(title: L("Mark"), action: nil, keyEquivalent: "")
            sm.submenu = styles
            m.addItem(sm)
            m.addItem(ClosureMenuItem(L("Delete Highlight")) { self?.session.highlights.removeAll { $0.id == id } })
            return m
        }
        return card
    }

    private func recolor(_ id: UUID, _ c: InkColor) {
        guard let i = session.highlights.firstIndex(where: { $0.id == id }), session.highlights[i].color != c else { return }
        session.highlights[i].color = c
        session.highlights[i].updatedAt = .now
    }

    private func restyle(_ id: UUID, _ st: HighlightStyle) {
        guard let i = session.highlights.firstIndex(where: { $0.id == id }), session.highlights[i].style != st else { return }
        session.highlights[i].style = st
        session.highlights[i].updatedAt = .now
    }

    private func imageRows() -> InspectorRows {
        let s = session
        var head: [NSView] = [sectionTitle("\(L("Image Notes")) · \(s.imageNotes.count)")]
        guard !s.imageNotes.isEmpty else {
            head.append(hint(L("No image notes yet. ⌥⇧-drag on a page to clip one, or drop an image file onto a page.")))
            return InspectorRows(head: head)
        }
        return InspectorRows(head: head, items: lazyItems(s.imageNotes) { me, n in me.imageCard(n) })
    }

    /// 缩略图在这里才读盘 / 才解码——分页之后没滚到的图片笔记就不读（`ImageThumbCache` 仍然负责缓存）。
    private func imageCard(_ n: ImageNote) -> NSView {
        let info = workspace.imageInfo(sha256: n.image)
        let thumb = NSImageView()
        thumb.wantsLayer = true
        thumb.layer?.cornerRadius = 4
        thumb.layer?.masksToBounds = true
        thumb.layer?.backgroundColor = NSColor.quaternaryLabelColor.withAlphaComponent(0.6).cgColor
        thumb.imageScaling = .scaleProportionallyUpOrDown
        if let info, let cg = ImageThumbCache.shared.image(url: info.url, maxPixel: 96) {
            thumb.image = NSImage(cgImage: cg, size: .zero)
        } else {
            thumb.image = NSImage(systemSymbolName: info == nil ? "photo.badge.exclamationmark" : "photo", accessibilityDescription: nil)
            thumb.contentTintColor = .labelColor
        }
        thumb.widthAnchor.constraint(equalToConstant: 48).isActive = true
        thumb.heightAnchor.constraint(equalToConstant: 48).isActive = true
        let title = multiline(n.caption.isEmpty ? n.sourceLabel : NoteMarkdown.plain(n.caption), .callout, lines: 2)
        let sub = label(n.caption.isEmpty ? String(format: L("Page %d"), n.page + 1)
                                          : "\(String(format: L("Page %d"), n.page + 1)) · \(n.sourceLabel)", .caption1)
        sub.textColor = .labelColor
        let req: (Notification.Name) -> Void = { [weak self] name in
            guard let self else { return }
            NotificationCenter.default.post(name: name, object: NoteRequest(sessionID: self.session.id, noteID: n.id))
        }
        let id = n.id
        let delete: () -> Void = { [weak self] in
            guard let s = self?.session else { return }
            s.inkEdit("Delete Image Note", kind: .delete) { s.imageNotes.removeAll { $0.id == id } }
        }
        let card = InspectorCard(content: hstack([thumb, vstack([title, sub], spacing: 2)], alignment: .top, spacing: 8),
                                 buttons: [iconButton("pencil.circle.fill", L("Edit this image note"), tint: .labelColor) { req(.imageNoteEdit) },
                                           iconButton("xmark.circle.fill", L("Delete this image note"), action: delete)])
        card.onTap = { [weak self] in self?.jump(n.page, max(0, Double(n.anchor.minY) - 0.03)) }
        card.menuProvider = {
            let m = NSMenu()
            m.addItem(ClosureMenuItem(L("Edit…")) { req(.imageNoteEdit) })
            let v = ClosureMenuItem(L("View Full Size")) { req(.imageNoteView) }
            v.isEnabled = info != nil
            m.autoenablesItems = false
            m.addItem(v)
            m.addItem(.separator())
            m.addItem(ClosureMenuItem(L("Delete Image Note"), action: delete))
            return m
        }
        return card
    }

    private func bookmarkRows() -> InspectorRows {
        let s = session
        var head: [NSView] = [sectionTitle("\(L("Bookmarks")) · \(s.bookmarks.count)")]
        let add = NSButton(title: L("Add Bookmark"), image: NSImage(systemSymbolName: "bookmark", accessibilityDescription: nil) ?? NSImage(),
                           target: self, action: #selector(addBookmark))
        add.isBordered = false
        add.contentTintColor = .labelColor
        add.imagePosition = .imageLeading
        head.append(add)
        guard !s.bookmarks.isEmpty else { head.append(hint(L("No bookmarks yet."))); return InspectorRows(head: head) }
        return InspectorRows(head: head, items: lazyItems(s.bookmarks) { me, b in me.bookmarkCard(b) })
    }

    private func bookmarkCard(_ b: Bookmark) -> NSView {
        let sub = label(String(format: L("Page %d"), b.page + 1), .caption1)
        sub.textColor = .labelColor
        let card = InspectorCard(content: vstack([symbolLabel("bookmark.fill", b.title), sub], spacing: 2),
                                 buttons: [iconButton("pencil.circle.fill", L("Rename this bookmark"), tint: .labelColor) { [weak self] in
                                               self?.session.beginBookmarkRename(b)
                                           },
                                           iconButton("xmark.circle.fill", L("Delete this bookmark")) { [weak self] in
                                               self?.session.deleteBookmark(id: b.id)
                                           }])
        card.onTap = { [weak self] in self?.session.jump(page: b.page, frac: b.frac, kind: .toc, label: b.title) }
        return card
    }

    private func inkRows() -> InspectorRows {
        let total = inkSummaries.reduce(0) { $0 + $1.count }
        let title = NSButton(title: "\(L("Ink")) · \(total)", target: self, action: #selector(toggleInk))
        title.setButtonType(.pushOnPushOff)
        title.bezelStyle = .disclosure
        title.state = inkExpanded ? .on : .off
        title.imagePosition = .imageLeading
        title.font = .systemFont(ofSize: NSFont.preferredFont(forTextStyle: .subheadline).pointSize, weight: .semibold)
        var head: [NSView] = [title]
        guard inkExpanded else { return InspectorRows(head: head) }
        guard !inkSummaries.isEmpty else { head.append(hint(L("No ink yet."))); return InspectorRows(head: head) }
        return InspectorRows(head: head, items: lazyItems(inkSummaries) { me, s in me.inkCard(s) })
    }

    private func inkCard(_ s: InkPageSummary) -> NSView {
        var parts: [NSView] = [symbolLabel("pencil.tip", String(format: L("Page %d"), s.page + 1)), flexible()]
        for c in s.colors.prefix(6) {
            let dot = NSView()
            dot.wantsLayer = true
            dot.layer?.backgroundColor = c.nsColor.cgColor
            dot.layer?.cornerRadius = 5
            dot.widthAnchor.constraint(equalToConstant: 10).isActive = true
            dot.heightAnchor.constraint(equalToConstant: 10).isActive = true
            parts.append(dot)
        }
        let n = label("\(s.count)", .caption1)
        n.textColor = .labelColor
        parts.append(n)
        let page = s.page
        let card = InspectorCard(content: hstack(parts), buttons: [iconButton("xmark.circle.fill", L("Delete ink on this page")) { [weak self] in
            guard let sess = self?.session else { return }
            sess.inkEnsureLoaded?(page)   // 不在装载窗口里的页先补读，走内存这条路才可撤销
            sess.inkEdit("Delete", kind: .delete) { sess.strokes.removeAll { $0.page == page } }
        }], plain: true)
        card.onTap = { [weak self] in self?.jump(s.page, max(0, s.minY - 0.05)) }
        return card
    }

    @objc private func toggleInk() {
        inkExpanded.toggle()
        lastSignature = ""
        refresh()
    }

    private func scratchRows() -> InspectorRows {
        let s = session
        // 画板笔记标签：会话里那张「纸」就是画板本身，不能在这里当草稿纸列出来（删它 = 删掉整篇画板的笔迹）
        if s.isBoard {
            return InspectorRows(head: [sectionTitle(L("Scratchpads")), hint(L("Boards have no scratchpads."))])
        }
        var head: [NSView] = [sectionTitle("\(L("Scratchpads")) · \(s.scratchPads.count)")]
        guard !s.scratchPads.isEmpty else {
            head.append(hint(L("No scratchpads yet. Right-click in the page to add one.")))
            return InspectorRows(head: head)
        }
        let pads = Array(s.scratchPads.enumerated())
        return InspectorRows(head: head, items: lazyItems(pads) { me, e in me.scratchCard(e.element, index: e.offset) })
    }

    private func scratchCard(_ pad: ScratchPad, index: Int) -> NSView {
        let s = session
        let count = s.scratchStrokes.count { $0.padId == pad.id }
        let n = label("\(count)", .caption1)
        n.textColor = .labelColor
        let id = pad.id
        let card = InspectorCard(content: hstack([symbolLabel("square.and.pencil", pad.displayName(index: index)), flexible(), n]),
                                 buttons: [iconButton("scope", L("Go to anchor"), tint: .labelColor) { [weak self] in
                                               self?.jump(pad.anchorPage, pad.anchorY)
                                           },
                                           iconButton("xmark.circle.fill", L("Delete this scratchpad and its ink")) { [weak self] in
                                               guard let s = self?.session else { return }
                                               if s.openPadID == id { s.openPadID = nil; s.scratchLive = nil }
                                               s.scratchPads.removeAll { $0.id == id }
                                               s.scratchStrokes.removeAll { $0.padId == id }
                                           }], plain: true)
        card.toolTip = String(format: L("Open · anchored on page %d"), pad.anchorPage + 1)
        card.onTap = { [weak self] in self?.session.openPadID = id }
        return card
    }

    private func aiRows() -> InspectorRows {
        let s = session
        var head: [NSView] = [sectionTitle("\(L("AI Chats")) · \(s.aiThreads.count)")]
        guard !s.aiThreads.isEmpty else {
            head.append(hint(L("No AI chats yet. Right-click in the page to start one.")))
            return InspectorRows(head: head)
        }
        return InspectorRows(head: head, items: lazyItems(s.aiThreads) { me, t in me.aiCard(t) })
    }

    private func aiCard(_ t: AIThread) -> NSView {
        let p = label(String(format: L("p.%d"), t.page + 1), .caption1)
        p.textColor = .labelColor
        let icon = t.state == .suspect ? "exclamationmark.bubble" : "bubble.left.and.text.bubble.right"
        let id = t.id
        let card = InspectorCard(content: hstack([symbolLabel(icon, t.hasTitle ? t.title : L("Untitled chat")), flexible(), p]),
                                 buttons: [iconButton("scope", L("Go to anchor"), tint: .labelColor) { [weak self] in
                                               self?.jump(t.page, Double(t.anchor.minY))
                                           },
                                           iconButton("xmark.circle.fill", L("Unbind (the conversation itself stays on the platform)")) { [weak self] in
                                               self?.session.aiThreads.removeAll { $0.id == id }
                                           }], plain: true)
        card.toolTip = t.state == .suspect ? L("This conversation may no longer exist.") : t.url
        card.onTap = { [weak self] in self?.openAIThread(t) }
        return card
    }

    // MARK: 小零件

    private func label(_ s: String, _ style: NSFont.TextStyle) -> NSTextField {
        let t = NSTextField(labelWithString: s)
        t.font = .preferredFont(forTextStyle: style)
        t.lineBreakMode = .byTruncatingTail
        t.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return t
    }

    private func multiline(_ s: String, _ style: NSFont.TextStyle, lines: Int) -> NSTextField {
        let t = NSTextField(wrappingLabelWithString: s)
        t.font = .preferredFont(forTextStyle: style)
        t.maximumNumberOfLines = lines
        t.lineBreakMode = .byTruncatingTail
        t.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return t
    }

    private func symbolLabel(_ symbol: String, _ text: String) -> NSView {
        let img = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage())
        img.symbolConfiguration = .init(textStyle: .callout)
        return hstack([img, label(text, .callout)], spacing: 4)
    }

    private func sectionTitle(_ s: String) -> NSTextField {
        let t = label(s, .subheadline)
        t.font = .systemFont(ofSize: t.font?.pointSize ?? 11, weight: .semibold)
        t.textColor = .labelColor
        return t
    }

    private func hint(_ s: String) -> NSTextField {
        let t = multiline(s, .callout, lines: 0)
        t.textColor = .labelColor
        return t
    }

    private func kvRow(_ k: String, _ v: String) -> NSView {
        let kl = label(k, .callout)
        kl.textColor = .labelColor
        kl.setContentCompressionResistancePriority(.required, for: .horizontal)
        let vl = multiline(v, .callout, lines: 0)
        vl.alignment = .right
        return hstack([kl, flexible(), vl], alignment: .firstBaseline, spacing: 12)
    }

    private func badge(_ text: String, _ color: NSColor) -> NSView {
        let t = NSTextField(labelWithString: text)
        t.font = .preferredFont(forTextStyle: .caption2)
        t.textColor = color
        t.wantsLayer = true
        t.setContentCompressionResistancePriority(.required, for: .horizontal)
        let box = NSView()
        box.wantsLayer = true
        box.layer?.backgroundColor = color.withAlphaComponent(0.2).cgColor
        box.layer?.cornerRadius = 7
        t.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(t)
        NSLayoutConstraint.activate([
            t.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 5),
            t.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -5),
            t.topAnchor.constraint(equalTo: box.topAnchor, constant: 1),
            t.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -1),
        ])
        return box
    }

    private func iconButton(_ symbol: String, _ tip: String, tint: NSColor = .labelColor,
                            action: @escaping () -> Void) -> NSButton {
        let b = ClosureButton(action: action)
        b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
        b.imagePosition = .imageOnly
        b.isBordered = false
        b.contentTintColor = tint
        b.toolTip = tip
        return b
    }

    private func hstack(_ v: [NSView], alignment: NSLayoutConstraint.Attribute = .centerY, spacing: CGFloat = 6) -> NSStackView {
        let s = NSStackView(views: v)
        s.orientation = .horizontal
        s.alignment = alignment
        s.spacing = spacing
        return s
    }

    private func vstack(_ v: [NSView], spacing: CGFloat) -> NSStackView {
        let s = NSStackView(views: v)
        s.orientation = .vertical
        s.alignment = .leading
        s.spacing = spacing
        return s
    }

    private func flexible() -> NSView {
        let v = NSView()
        v.setContentHuggingPriority(.init(1), for: .horizontal)
        v.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        return v
    }

    private func spacer(_ h: CGFloat) -> NSView {
        let v = NSView()
        v.heightAnchor.constraint(equalToConstant: h).isActive = true
        return v
    }
}

/// Inspector 列表的一段内容：`head` 是条数固定的头部（分区标题、筛选器、空列表提示），
/// `items` 是条目**怎么建**而不是建好的视图——建不建由滚动位置决定（见 `InspectorViewController.rebuild`）。
struct InspectorRows {
    var head: [NSView] = []
    var items: [() -> NSView] = []
}

/// Inspector 里的一张条目卡片：淡色圆角底 + 内容（点它 = `onTap`）+ 右侧小按钮；右键 `menuProvider`。
/// `plain` = 不要底色（笔迹 / 草稿纸 / AI 这些一行一条的列表，原版就没有卡片底）。
final class InspectorCard: NSView {
    var onTap: (() -> Void)?
    var menuProvider: (() -> NSMenu?)?

    init(content: NSView, buttons: [NSButton], plain: Bool = false) {
        super.init(frame: .zero)
        wantsLayer = true
        if !plain {
            // 🔴 卡片底用**系统材质**，别用 `quaternaryLabelColor` 那种淡色（它本身就是半透明标签色，
            // 再乘 0.5 之后在 Inspector 的材质底上根本看不出有块，文字跟着糊成一片：用户 2026-09-20 报）。
            let bg = NSVisualEffectView()
            bg.material = .contentBackground
            bg.blendingMode = .withinWindow
            bg.state = .followsWindowActiveState
            bg.wantsLayer = true
            bg.layer?.cornerRadius = 7
            bg.translatesAutoresizingMaskIntoConstraints = false
            addSubview(bg)
            NSLayoutConstraint.activate([
                bg.leadingAnchor.constraint(equalTo: leadingAnchor),
                bg.trailingAnchor.constraint(equalTo: trailingAnchor),
                bg.topAnchor.constraint(equalTo: topAnchor),
                bg.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
        }
        // 🔴 按钮**用约束钉在右上角**，不要靠 stack view 里 content 拉不拉得开（短文本的条目里
        // 删除按钮会跟在文字屁股后面，不在右边：用户 2026-09-20 报「文字笔记的关闭按钮要右对齐」）。
        let padH: CGFloat = plain ? 0 : 10
        let padV: CGFloat = plain ? 2 : 10   // 8 → 10：卡片显得挤（Files / 高亮两处用户实测）
        content.setContentHuggingPriority(.init(1), for: .horizontal)
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        var cs: [NSLayoutConstraint] = [
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: padH),
            content.topAnchor.constraint(equalTo: topAnchor, constant: padV),
            content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -padV),
        ]
        if buttons.isEmpty {
            cs.append(content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -padH))
        } else {
            // 🔴 **别用 NSStackView 装这几枚按钮**：它按 gravity area 分布，一枚按钮时碰巧贴右、
            // 加到两枚就把它们按在左侧、跟在文字屁股后面（用户 2026-09-20 两次报「按钮没贴右」）。
            // 逐枚从右往左用约束钉死，与内容宽度无关。
            var anchor = trailingAnchor
            var gap = -padH
            for b in buttons.reversed() {
                b.setContentHuggingPriority(.required, for: .horizontal)
                b.setContentCompressionResistancePriority(.required, for: .horizontal)
                b.translatesAutoresizingMaskIntoConstraints = false
                addSubview(b)
                cs += [
                    b.trailingAnchor.constraint(equalTo: anchor, constant: gap),
                    b.topAnchor.constraint(equalTo: topAnchor, constant: padV),
                    b.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -padV),
                ]
                anchor = b.leadingAnchor
                gap = -4
            }
            // content 优先撑到最左那枚按钮旁边（低优先级，放不下时收缩）；按钮的位置是 required，跑不掉
            let fill = content.trailingAnchor.constraint(equalTo: anchor, constant: -6)
            fill.priority = .defaultLow
            cs += [fill, content.trailingAnchor.constraint(lessThanOrEqualTo: anchor, constant: -6)]
        }
        NSLayoutConstraint.activate(cs)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) 不支持") }

    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onTap?() }
    }

    override func menu(for event: NSEvent) -> NSMenu? { menuProvider?() }
}

/// 带闭包的按钮。
final class ClosureButton: NSButton {
    private let handler: () -> Void
    init(action: @escaping () -> Void) {
        handler = action
        super.init(frame: .zero)
        target = self
        self.action = #selector(fire)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) 不支持") }
    @objc private func fire() { handler() }
}

/// flipped 的竖排栈（放在滚动视图里从顶上往下排）。
final class FlippedStackView: NSStackView {
    override var isFlipped: Bool { true }
}
