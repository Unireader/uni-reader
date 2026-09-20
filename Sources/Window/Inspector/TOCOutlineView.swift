import AppKit

/// 目录树（AppKit 版，替代 SwiftUI `TOCListView`；Inspector 目录页、工具栏目录弹窗、参考窗三处共用）。
///  · **书签与目录合并显示**（`REQUIREMENTS.md §1.9`）：落位规则在 `TOCMerge`（纯函数、三端契约），这里只把落位表翻成树；
///  · **当前页追踪**：归属当前页的目录项（页码 ≤ 当前页里最大的，并列取先序靠后 = 更深一层）自动展开祖先链、
///    强调显示、滚动到位；只增展开，不动用户手动折叠的其它分支；书签行不参与追踪；
///  · 有书签的组自动展开（不然「加完书签在目录里找不到」，2026-09-02 安卓实测）；
///  · 坏书签（无目标页）不显示页码、点不动。
final class TOCOutlineView: NSView, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate {
    var onSelect: (TOCEntry) -> Void = { _ in }
    var onSelectBookmark: ((Bookmark) -> Void)?
    var onRenameBookmark: ((Bookmark) -> Void)?
    var onDeleteBookmark: ((Bookmark) -> Void)?

    private let outline = NSOutlineView()
    private let scroll = NSScrollView()
    private let empty = NSStackView()
    private var roots: [TOCNode] = []
    private var byID: [UUID: TOCNode] = [:]
    private var entries: [TOCEntry] = []
    private var bookmarks: [Bookmark] = []
    private var currentPage = -1
    private var currentID: UUID?
    private var entriesToken: [UUID] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        outline.headerView = nil
        outline.style = .plain
        outline.backgroundColor = .clear
        outline.rowSizeStyle = .default
        outline.indentationPerLevel = 14
        let col = NSTableColumn(identifier: .init("toc"))
        outline.addTableColumn(col)
        outline.outlineTableColumn = col
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.action = #selector(clicked)
        let menu = NSMenu()
        menu.delegate = self
        outline.menu = menu
        scroll.documentView = outline
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        addSubview(scroll)
        let icon = NSImageView(image: NSImage(systemSymbolName: "list.bullet.indent", accessibilityDescription: nil) ?? NSImage())
        icon.symbolConfiguration = .init(textStyle: .title2)
        icon.contentTintColor = .labelColor
        let label = NSTextField(labelWithString: L("No table of contents"))
        label.textColor = .labelColor
        label.font = .preferredFont(forTextStyle: .callout)
        empty.orientation = .vertical
        empty.spacing = 8
        empty.addArrangedSubview(icon)
        empty.addArrangedSubview(label)
        addSubview(empty)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) 不支持") }

    override func layout() {
        super.layout()
        scroll.frame = bounds
        let s = empty.fittingSize
        empty.frame = NSRect(x: (bounds.width - s.width) / 2, y: (bounds.height - s.height) / 2, width: s.width, height: s.height)
    }

    /// 喂数据。目录 / 书签变了重建树（展开态按 id 保留）；只有当前页变了就只做追踪。
    func update(entries: [TOCEntry], bookmarks: [Bookmark], currentPage: Int) {
        let token = entries.map(\.id)
        let rebuild = token != entriesToken || bookmarks.map(\.id) != self.bookmarks.map(\.id)
            || bookmarks != self.bookmarks
        let bookmarksCountChanged = bookmarks.count != self.bookmarks.count
        self.entries = entries
        self.bookmarks = bookmarks
        entriesToken = token
        empty.isHidden = !(entries.isEmpty && bookmarks.isEmpty)
        scroll.isHidden = !empty.isHidden
        if rebuild {
            let expanded = Set(byID.values.filter { outline.isItemExpanded($0) }.map(\.id))
            buildTree()
            outline.reloadData()
            for n in byID.values where expanded.contains(n.id) { outline.expandItem(n) }
            if bookmarksCountChanged || expanded.isEmpty { revealBookmarks() }
        }
        if rebuild || currentPage != self.currentPage {
            self.currentPage = currentPage
            track()
        }
    }

    // MARK: 建树（先序拍平 → 书签按 `TOCMerge` 插位 → 按深度还原成树）

    private struct Flat { let node: TOCNode; let depth: Int }

    private func buildTree() {
        var base: [Flat] = []
        func walk(_ list: [TOCEntry], depth: Int) {
            for e in list {
                base.append(Flat(node: TOCNode(entry: e), depth: depth))
                walk(e.children, depth: depth + 1)
            }
        }
        walk(entries, depth: 0)
        var flat = base
        if !bookmarks.isEmpty {
            let slots = TOCMerge.place(rows: base.map { TOCMerge.Row(depth: $0.depth, page: $0.node.page) },
                                       bookmarkPages: bookmarks.map(\.page))
            var insertions: [Int: [Flat]] = [:]
            for (i, b) in bookmarks.enumerated() {
                insertions[slots[i].insertBefore, default: []].append(Flat(node: TOCNode(bookmark: b), depth: slots[i].depth))
            }
            flat = []
            for (i, f) in base.enumerated() {
                if let ins = insertions[i] { flat.append(contentsOf: ins) }
                flat.append(f)
            }
            if let tail = insertions[base.count] { flat.append(contentsOf: tail) }
        }
        roots = []
        byID = [:]
        var stack: [(depth: Int, node: TOCNode)] = []
        for f in flat {
            byID[f.node.id] = f.node
            while let last = stack.last, last.depth >= f.depth { stack.removeLast() }
            if let parent = stack.last?.node {
                f.node.parent = parent
                parent.children.append(f.node)
            } else {
                roots.append(f.node)
            }
            stack.append((f.depth, f.node))
        }
    }

    /// 带书签的组展开（只增不减）。
    private func revealBookmarks() {
        for n in byID.values where n.bookmark != nil {
            var p = n.parent
            var chain: [TOCNode] = []
            while let x = p { chain.append(x); p = x.parent }
            for x in chain.reversed() { outline.expandItem(x) }
        }
    }

    /// 当前页追踪：取页码 ≤ 当前页里最大的目录项（并列取先序靠后）；展开祖先、滚到正中。
    private func track() {
        var best: (page: Int, node: TOCNode)?
        func walk(_ list: [TOCNode]) {
            for n in list {
                if let e = n.entry, let p = e.pageIndex, p <= currentPage, !(best.map { p < $0.page } ?? false) {
                    best = (p, n)
                }
                walk(n.children)
            }
        }
        walk(roots)
        let newID = best?.node.id
        let old = currentID
        currentID = newID
        if let n = best?.node {
            var chain: [TOCNode] = []
            var p = n.parent
            while let x = p { chain.append(x); p = x.parent }
            for x in chain.reversed() { outline.expandItem(x) }
            let row = outline.row(forItem: n)
            if row >= 0 { outline.scrollRowToVisible(row) }
        }
        for id in [old, newID].compactMap({ $0 }) {
            if let n = byID[id] { outline.reloadItem(n) }
        }
    }

    // MARK: 数据源

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        (item as? TOCNode)?.children.count ?? roots.count
    }
    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        (item as? TOCNode)?.children[index] ?? roots[index]
    }
    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        !((item as? TOCNode)?.children.isEmpty ?? true)
    }
    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool { false }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let n = item as? TOCNode else { return nil }
        let cell = NSTableCellView()
        let title = NSTextField(labelWithString: "")
        title.lineBreakMode = .byTruncatingTail
        let page = NSTextField(labelWithString: "")
        page.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        var views: [NSView] = []
        if let b = n.bookmark {
            let icon = NSImageView(image: NSImage(systemSymbolName: "bookmark.fill", accessibilityDescription: nil) ?? NSImage())
            icon.symbolConfiguration = .init(pointSize: 9, weight: .regular)
            icon.contentTintColor = .controlAccentColor
            icon.widthAnchor.constraint(equalToConstant: 14).isActive = true
            views.append(icon)
            title.stringValue = b.title
            title.textColor = .labelColor
            page.stringValue = "\(b.page + 1)"
            page.textColor = .labelColor   // 红线：材质底上别用次要色，层级靠字号
        } else if let e = n.entry {
            let isCurrent = n.id == currentID
            title.stringValue = e.label.isEmpty ? "—" : e.label
            title.textColor = isCurrent ? .controlAccentColor : (e.pageIndex == nil ? .tertiaryLabelColor : .labelColor)
            page.stringValue = e.pageIndex.map { "\($0 + 1)" } ?? ""   // 坏书签留空
            page.textColor = isCurrent ? .controlAccentColor : .labelColor
            cell.wantsLayer = true
            cell.layer?.cornerRadius = 6
            cell.layer?.backgroundColor = isCurrent ? NSColor.controlAccentColor.withAlphaComponent(0.16).cgColor : nil
        }
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        views += [title, spacer, page]
        let stack = NSStackView(views: views)
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 4, bottom: 0, right: 6)
        stack.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(stack)
        cell.textField = title
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: cell.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: cell.trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    @objc private func clicked() {
        guard let n = outline.item(atRow: outline.clickedRow) as? TOCNode else { return }
        if let b = n.bookmark { onSelectBookmark?(b) }
        else if let e = n.entry, e.pageIndex != nil { onSelect(e) }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let b = (outline.item(atRow: outline.clickedRow) as? TOCNode)?.bookmark else { return }
        if let rename = onRenameBookmark { menu.addItem(ClosureMenuItem(L("Rename…")) { rename(b) }) }
        if let del = onDeleteBookmark { menu.addItem(ClosureMenuItem(L("Delete")) { del(b) }) }
    }
}

/// 目录树的一个节点（目录项或书签）。
final class TOCNode: NSObject {
    let entry: TOCEntry?
    let bookmark: Bookmark?
    weak var parent: TOCNode?
    var children: [TOCNode] = []

    init(entry: TOCEntry) { self.entry = entry; self.bookmark = nil }
    init(bookmark: Bookmark) { self.entry = nil; self.bookmark = bookmark }

    var id: UUID { entry?.id ?? bookmark!.id }
    var page: Int? { entry?.pageIndex ?? bookmark?.page }
}
