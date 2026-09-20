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
        emptyLabel.textColor = .secondaryLabelColor
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
    }

    // MARK: 订阅

    private func installObservers() {
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
        refresh()
    }

    @objc private func addBookmark() { session.beginBookmarkAtCurrent() }

    private func applyTab() {
        sectionControl.isHidden = tab != .notes
        sectionControl.selectedSegment = sections.firstIndex(of: notesSection) ?? 0
        lastSignature = ""
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

    private func rebuild(_ views: [NSView]) {
        for v in listStack.arrangedSubviews { listStack.removeArrangedSubview(v); v.removeFromSuperview() }
        for v in views {
            listStack.addArrangedSubview(v)
            v.widthAnchor.constraint(equalTo: listStack.widthAnchor, constant: -32).isActive = true
        }
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
            hash.textColor = .secondaryLabelColor
            let line = hstack([name] + badges + [flexible(), hash])
            let path = label(workspace.resolvedPath(l), .caption2)
            path.textColor = .secondaryLabelColor
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
            out.append(InspectorCard(content: vstack([line, path], spacing: 3), buttons: buttons))
        }
        return out
    }

    // MARK: 笔记页

    private func notesSignature() -> String {
        let s = session
        switch notesSection {
        case .text:
            return "text|\(s.textNotes.map { "\($0.id)\($0.updatedAt.timeIntervalSince1970)" })|\(s.noteTypeFilter)|\(s.noteTypes.map(\.id))"
        case .highlight: return "hl|\(s.highlights.map { "\($0.id)\($0.updatedAt.timeIntervalSince1970)" })"
        case .image: return "img|\(s.imageNotes.map { "\($0.id)\($0.updatedAt.timeIntervalSince1970)" })"
        case .bookmark: return "bm|\(s.bookmarks.map { "\($0.id)\($0.title)\($0.page)" })"
        case .ink: return "ink|\(inkSummaries.map { "\($0.page):\($0.count)" })|\(inkExpanded)"
        case .scratch: return "sc|\(s.scratchPads.map(\.id))|\(s.scratchStrokes.count)"
        case .ai: return "ai|\(s.aiThreads.map { "\($0.id)\($0.title)\($0.state)" })"
        }
    }

    private func notesRows() -> [NSView] {
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

    private func textRows() -> [NSView] {
        let s = session
        let filtered = s.textNotes.filter { n in
            switch s.noteTypeFilter {
            case .all: return true
            case .only(let id): return n.typeId == id
            }
        }
        var out: [NSView] = [sectionTitle("\(L("Text Notes")) · \(filtered.count)")]
        guard !s.textNotes.isEmpty else { out.append(hint(L("No text notes yet."))); return out }
        out.append(typeFilterButton())
        for n in filtered {
            let t = NoteType.resolve(n.typeId, in: s.noteTypes)
            let dot = NSView()
            dot.wantsLayer = true
            dot.layer?.backgroundColor = t.nsColor.cgColor
            dot.layer?.cornerRadius = 4
            dot.widthAnchor.constraint(equalToConstant: 8).isActive = true
            dot.heightAnchor.constraint(equalToConstant: 8).isActive = true
            var head: [NSView] = [dot, symbolLabel(t.icon, String(format: L("Page %d"), n.page + 1))]
            if t.id != NoteType.generalID {
                let tn = label(t.name, .caption1); tn.textColor = .secondaryLabelColor; head.append(tn)
            }
            var lines: [NSView] = [hstack(head)]
            if !n.text.isEmpty { lines.append(multiline(NoteMarkdown.plain(n.text), .callout, lines: 2)) }
            if !n.quote.isEmpty {
                let q = multiline(n.quote.flattenedQuote, .caption1, lines: 2)
                q.textColor = .secondaryLabelColor
                lines.append(q)
            }
            var buttons: [NSButton] = []
            if let src = n.source, src.isAI, AIPanelModel.shared.enabled {
                buttons.append(iconButton("bubble.left.and.text.bubble.right", L("Open the AI conversation this came from"),
                                          tint: .tertiaryLabelColor) { [weak self] in self?.openAISource(src) })
            } else if let src = n.source, src.isAgent {
                let b = iconButton("terminal", String(format: L("Written by an agent (%@)"), src.provider), tint: .tertiaryLabelColor) {}
                b.isEnabled = false
                buttons.append(b)
            }
            let id = n.id
            buttons.append(iconButton("xmark.circle.fill", L("Delete this note")) { [weak self] in
                guard let s = self?.session else { return }
                s.inkEdit("Delete", kind: .delete) { s.textNotes.removeAll { $0.id == id } }
            })
            let card = InspectorCard(content: vstack(lines, spacing: 3), buttons: buttons)
            card.onTap = { [weak self] in self?.jump(n.page, max(0, Double(n.anchor.minY) - 0.03)) }
            out.append(card)
        }
        return out
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

    private func highlightRows() -> [NSView] {
        let s = session
        var out: [NSView] = [sectionTitle("\(L("Highlights")) · \(s.highlights.count)")]
        guard !s.highlights.isEmpty else { out.append(hint(L("No highlights yet."))); return out }
        for h in s.highlights {
            let swatch = NSView()
            swatch.wantsLayer = true
            swatch.layer?.backgroundColor = h.color.nsColor.cgColor
            swatch.layer?.cornerRadius = 3
            swatch.widthAnchor.constraint(equalToConstant: 12).isActive = true
            swatch.heightAnchor.constraint(equalToConstant: 12).isActive = true
            var lines: [NSView] = [symbolLabel(h.style.iconName, String(format: L("Page %d"), h.page + 1))]
            if !h.quote.isEmpty {
                let q = multiline(h.quote.flattenedQuote, .caption1, lines: 2)
                q.textColor = .secondaryLabelColor
                lines.append(q)
            }
            let id = h.id
            let card = InspectorCard(content: hstack([swatch, vstack(lines, spacing: 2)], alignment: .top, spacing: 8),
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
            out.append(card)
        }
        return out
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

    private func imageRows() -> [NSView] {
        let s = session
        var out: [NSView] = [sectionTitle("\(L("Image Notes")) · \(s.imageNotes.count)")]
        guard !s.imageNotes.isEmpty else {
            out.append(hint(L("No image notes yet. ⌥⇧-drag on a page to clip one, or drop an image file onto a page.")))
            return out
        }
        for n in s.imageNotes {
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
                thumb.contentTintColor = .secondaryLabelColor
            }
            thumb.widthAnchor.constraint(equalToConstant: 48).isActive = true
            thumb.heightAnchor.constraint(equalToConstant: 48).isActive = true
            let title = multiline(n.caption.isEmpty ? n.sourceLabel : NoteMarkdown.plain(n.caption), .callout, lines: 2)
            let sub = label(n.caption.isEmpty ? String(format: L("Page %d"), n.page + 1)
                                              : "\(String(format: L("Page %d"), n.page + 1)) · \(n.sourceLabel)", .caption1)
            sub.textColor = .secondaryLabelColor
            let req: (Notification.Name) -> Void = { [weak self] name in
                guard let self else { return }
                NotificationCenter.default.post(name: name, object: ImageNoteRequest(sessionID: self.session.id, noteID: n.id))
            }
            let id = n.id
            let delete: () -> Void = { [weak self] in
                guard let s = self?.session else { return }
                s.inkEdit("Delete Image Note", kind: .delete) { s.imageNotes.removeAll { $0.id == id } }
            }
            let card = InspectorCard(content: hstack([thumb, vstack([title, sub], spacing: 2)], alignment: .top, spacing: 8),
                                     buttons: [iconButton("pencil", L("Edit this image note"), tint: .secondaryLabelColor) { req(.imageNoteEdit) },
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
            out.append(card)
        }
        return out
    }

    private func bookmarkRows() -> [NSView] {
        let s = session
        var out: [NSView] = [sectionTitle("\(L("Bookmarks")) · \(s.bookmarks.count)")]
        let add = NSButton(title: L("Add Bookmark"), image: NSImage(systemSymbolName: "bookmark", accessibilityDescription: nil) ?? NSImage(),
                           target: self, action: #selector(addBookmark))
        add.isBordered = false
        add.contentTintColor = .labelColor
        add.imagePosition = .imageLeading
        out.append(add)
        guard !s.bookmarks.isEmpty else { out.append(hint(L("No bookmarks yet."))); return out }
        for b in s.bookmarks {
            let sub = label(String(format: L("Page %d"), b.page + 1), .caption1)
            sub.textColor = .secondaryLabelColor
            let card = InspectorCard(content: vstack([symbolLabel("bookmark.fill", b.title), sub], spacing: 2),
                                     buttons: [iconButton("pencil", L("Rename this bookmark"), tint: .secondaryLabelColor) { [weak self] in
                                                   self?.session.beginBookmarkRename(b)
                                               },
                                               iconButton("xmark.circle.fill", L("Delete this bookmark")) { [weak self] in
                                                   self?.session.deleteBookmark(id: b.id)
                                               }])
            card.onTap = { [weak self] in self?.session.jump(page: b.page, frac: b.frac, kind: .toc, label: b.title) }
            out.append(card)
        }
        return out
    }

    private func inkRows() -> [NSView] {
        let total = inkSummaries.reduce(0) { $0 + $1.count }
        let head = NSButton(title: "\(L("Ink")) · \(total)", target: self, action: #selector(toggleInk))
        head.setButtonType(.pushOnPushOff)
        head.bezelStyle = .disclosure
        head.state = inkExpanded ? .on : .off
        head.imagePosition = .imageLeading
        head.font = .systemFont(ofSize: NSFont.preferredFont(forTextStyle: .subheadline).pointSize, weight: .semibold)
        var out: [NSView] = [head]
        guard inkExpanded else { return out }
        guard !inkSummaries.isEmpty else { out.append(hint(L("No ink yet."))); return out }
        for s in inkSummaries {
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
            n.textColor = .secondaryLabelColor
            parts.append(n)
            let page = s.page
            let card = InspectorCard(content: hstack(parts), buttons: [iconButton("xmark.circle.fill", L("Delete ink on this page")) { [weak self] in
                guard let sess = self?.session else { return }
                sess.inkEnsureLoaded?(page)   // 不在装载窗口里的页先补读，走内存这条路才可撤销
                sess.inkEdit("Delete", kind: .delete) { sess.strokes.removeAll { $0.page == page } }
            }], plain: true)
            card.onTap = { [weak self] in self?.jump(s.page, max(0, s.minY - 0.05)) }
            out.append(card)
        }
        return out
    }

    @objc private func toggleInk() {
        inkExpanded.toggle()
        lastSignature = ""
        refresh()
    }

    private func scratchRows() -> [NSView] {
        let s = session
        var out: [NSView] = [sectionTitle("\(L("Scratchpads")) · \(s.scratchPads.count)")]
        guard !s.scratchPads.isEmpty else { out.append(hint(L("No scratchpads yet. Right-click in the page to add one."))); return out }
        for (i, pad) in s.scratchPads.enumerated() {
            let count = s.scratchStrokes.count { $0.padId == pad.id }
            let n = label("\(count)", .caption1)
            n.textColor = .secondaryLabelColor
            let id = pad.id
            let card = InspectorCard(content: hstack([symbolLabel("square.and.pencil", pad.displayName(index: i)), flexible(), n]),
                                     buttons: [iconButton("scope", L("Go to anchor"), tint: .tertiaryLabelColor) { [weak self] in
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
            out.append(card)
        }
        return out
    }

    private func aiRows() -> [NSView] {
        let s = session
        var out: [NSView] = [sectionTitle("\(L("AI Chats")) · \(s.aiThreads.count)")]
        guard !s.aiThreads.isEmpty else { out.append(hint(L("No AI chats yet. Right-click in the page to start one."))); return out }
        for t in s.aiThreads {
            let p = label(String(format: L("p.%d"), t.page + 1), .caption1)
            p.textColor = .secondaryLabelColor
            let icon = t.state == .suspect ? "exclamationmark.bubble" : "bubble.left.and.text.bubble.right"
            let id = t.id
            let card = InspectorCard(content: hstack([symbolLabel(icon, t.hasTitle ? t.title : L("Untitled chat")), flexible(), p]),
                                     buttons: [iconButton("scope", L("Go to anchor"), tint: .tertiaryLabelColor) { [weak self] in
                                                   self?.jump(t.page, Double(t.anchor.minY))
                                               },
                                               iconButton("xmark.circle.fill", L("Unbind (the conversation itself stays on the platform)")) { [weak self] in
                                                   self?.session.aiThreads.removeAll { $0.id == id }
                                               }], plain: true)
            card.toolTip = t.state == .suspect ? L("This conversation may no longer exist.") : t.url
            card.onTap = { [weak self] in self?.openAIThread(t) }
            out.append(card)
        }
        return out
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
        t.textColor = .secondaryLabelColor
        return t
    }

    private func hint(_ s: String) -> NSTextField {
        let t = multiline(s, .callout, lines: 0)
        t.textColor = .secondaryLabelColor
        return t
    }

    private func kvRow(_ k: String, _ v: String) -> NSView {
        let kl = label(k, .callout)
        kl.textColor = .secondaryLabelColor
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

    private func iconButton(_ symbol: String, _ tip: String, tint: NSColor = .tertiaryLabelColor,
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

/// Inspector 里的一张条目卡片：淡色圆角底 + 内容（点它 = `onTap`）+ 右侧小按钮；右键 `menuProvider`。
/// `plain` = 不要底色（笔迹 / 草稿纸 / AI 这些一行一条的列表，原版就没有卡片底）。
final class InspectorCard: NSView {
    var onTap: (() -> Void)?
    var menuProvider: (() -> NSMenu?)?

    init(content: NSView, buttons: [NSButton], plain: Bool = false) {
        super.init(frame: .zero)
        wantsLayer = true
        if !plain {
            layer?.backgroundColor = NSColor.quaternaryLabelColor.withAlphaComponent(0.5).cgColor
            layer?.cornerRadius = 7
        }
        let row = NSStackView(views: [content] + buttons)
        row.alignment = .top
        row.spacing = 6
        row.edgeInsets = plain ? NSEdgeInsets(top: 2, left: 0, bottom: 2, right: 0) : NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        content.setContentHuggingPriority(.init(1), for: .horizontal)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
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
