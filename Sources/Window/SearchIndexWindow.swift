import AppKit
import Combine

/// 「查看索引内容」窗口（设置 › Agent › 搜索 › 查看索引内容…，`SEARCH-PLAN.md §7`）：一个工作区的搜索索引里有什么。
/// 三层可展开：种类（PDF 页 / 笔记 / 批注 / 习题 / …）→ 来源（每本书、每篇笔记…）→ 每一块（页码或行号 + 开头的字 + 有没有向量）。
/// 块那一层展开时才去读。只读；不自动刷新（自动刷新会把展开的层收起来），右上角「刷新」。
@MainActor
final class SearchIndexWindowController: NSWindowController, NSWindowDelegate, NSOutlineViewDataSource, NSOutlineViewDelegate {
    private static var shared: SearchIndexWindowController?

    /// 设置页那一行同一个工作区：key 窗口的，没有就第一个开着的。
    static func show() {
        if let c = shared {
            c.window?.makeKeyAndOrderFront(nil)
            c.reload()
            return
        }
        let c = SearchIndexWindowController()
        shared = c
        if c.window?.setFrameUsingName("SearchIndexWindow") != true { c.window?.center() }
        c.window?.makeKeyAndOrderFront(nil)
        c.reload()
    }

    private final class Node {
        enum Kind { case group, source, chunk }
        let kind: Kind
        let title: String
        var chunks = 0, vectors = 0
        let sourceKey: String?
        var children: [Node]?          // nil = 还没读（来源层展开时才读块）
        var hasVector = false
        init(_ kind: Kind, _ title: String, sourceKey: String? = nil) { self.kind = kind; self.title = title; self.sourceKey = sourceKey }
    }

    private let outline = NSOutlineView()
    private let summary = NSTextField(wrappingLabelWithString: "")
    private var groups: [Node] = []
    private var index: SearchIndex?
    private var bag = Set<AnyCancellable>()

    /// 来源键前缀 → 种类名（顺序即显示顺序）
    private static let kinds: [(prefix: String, title: String)] = [
        ("pdf:", L("PDF Pages")), ("md:", L("Markdown Notes")), ("ann:", L("Annotations")), ("ex:", L("Exercises")),
        ("ctx:", L("Agent Contexts")), ("mem:", L("Agent Memories")), ("conv:", L("Agent Conversations")),
    ]

    private init() {
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 560),
                           styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        win.title = L("Search Index")
        win.minSize = NSSize(width: 480, height: 300)
        win.isReleasedWhenClosed = false
        super.init(window: win)
        win.delegate = self
        win.setFrameAutosaveName("SearchIndexWindow")
        build(in: win)
        // ⌘W / ⇧⌘W 是 App 级广播（`MainMenu`），各窗口自己认领：key 窗口是这扇就关它（同设置窗）
        for name in [Notification.Name.closeTabRequested, .closeWindowRequested] {
            NotificationCenter.default.publisher(for: name)
                .sink { [weak self] _ in
                    guard let self, self.window?.isKeyWindow == true else { return }
                    self.window?.performClose(nil)
                }
                .store(in: &bag)
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) 不支持") }

    func windowWillClose(_ notification: Notification) { Self.shared = nil }

    private func build(in win: NSWindow) {
        let root = NSView()
        summary.font = .systemFont(ofSize: NSFont.systemFontSize)
        summary.textColor = .labelColor
        summary.isSelectable = true
        let refresh = NSButton(title: L("Refresh"), target: self, action: #selector(reloadAction))

        for (id, title, width) in [("name", L("Name"), 480.0), ("chunks", L("Pieces"), 90.0), ("vectors", L("With Vectors"), 110.0)] {
            let c = NSTableColumn(identifier: .init(id))
            c.title = title
            c.width = width
            if id != "name" { c.headerCell.alignment = .right }
            outline.addTableColumn(c)
            if id == "name" { outline.outlineTableColumn = c }
        }
        outline.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        outline.usesAlternatingRowBackgroundColors = true
        outline.rowHeight = 22
        outline.dataSource = self
        outline.delegate = self
        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder

        for v in [summary, refresh, scroll] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(v) }
        NSLayoutConstraint.activate([
            summary.topAnchor.constraint(equalTo: root.topAnchor, constant: 14),
            summary.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            summary.trailingAnchor.constraint(lessThanOrEqualTo: refresh.leadingAnchor, constant: -12),
            refresh.centerYAnchor.constraint(equalTo: summary.centerYAnchor),
            refresh.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            scroll.topAnchor.constraint(equalTo: summary.bottomAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),
        ])
        win.contentView = root
    }

    // MARK: 读数据

    @objc private func reloadAction() { reload() }

    func reload() {
        let key = AppDelegate.shared?.readerWindowControllers.first { $0.window?.isKeyWindow == true }?.workspace
        guard let ws = key ?? WorkspaceRegistry.shared.openManagers.first,
              let id = SearchSources.indexID(ws), let index = try? SearchIndex.shared(workspaceID: id) else {
            index = nil; groups = []; outline.reloadData()
            summary.stringValue = L("No workspace is open")
            return
        }
        self.index = index
        window?.title = String(format: L("Search Index — %@"), ws.name)
        Task { @MainActor in
            let sources = await index.sourceSummaries()
            let model = await index.vectorModel
            var gs: [Node] = []
            for k in Self.kinds {
                let mine = sources.filter { $0.key.hasPrefix(k.prefix) }
                guard !mine.isEmpty else { continue }
                let g = Node(.group, k.title)
                g.children = mine.map { s in
                    let n = Node(.source, s.title.isEmpty ? s.key : s.title, sourceKey: s.key)
                    n.chunks = s.chunks; n.vectors = s.vectors
                    return n
                }
                g.chunks = mine.reduce(0) { $0 + $1.chunks }
                g.vectors = mine.reduce(0) { $0 + $1.vectors }
                gs.append(g)
            }
            groups = gs
            outline.reloadData()
            let total = sources.reduce(0) { $0 + $1.chunks }, vec = sources.reduce(0) { $0 + $1.vectors }
            var text = String(format: L("%d sources, %d pieces of text, %d with vectors"), sources.count, total, vec)
            if let model { text += "\n" + String(format: L("Vector model: %@"), model) }
            summary.stringValue = text
        }
    }

    private func loadChunks(_ n: Node) {
        guard n.kind == .source, n.children == nil, let key = n.sourceKey, let index else { return }
        n.children = []
        Task { @MainActor in
            let rows = await index.chunkSummaries(source: key)
            n.children = rows.map { r in
                var where_ = ""
                if let p = r.page { where_ = String(format: L("p. %d"), p + 1) }
                else if let l = r.line { where_ = String(format: L("line %d"), l) }
                let head = r.heading.isEmpty ? "" : r.heading + " · "
                let body = r.body.replacingOccurrences(of: "\n", with: " ")
                let c = Node(.chunk, (where_.isEmpty ? "" : where_ + "  ") + head + body)
                c.hasVector = r.hasVector
                return c
            }
            outline.reloadItem(n, reloadChildren: true)
        }
    }

    // MARK: NSOutlineView

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let n = item as? Node else { return groups.count }
        return n.children?.count ?? 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let n = item as? Node else { return groups[index] }
        return n.children![index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? Node).map { $0.kind != .chunk } ?? false
    }

    func outlineViewItemWillExpand(_ notification: Notification) {
        if let n = notification.userInfo?["NSObject"] as? Node { loadChunks(n) }
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let n = item as? Node, let col = tableColumn?.identifier.rawValue else { return nil }
        let id = NSUserInterfaceItemIdentifier("cell." + col)
        let cell = (outlineView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView) ?? {
            let c = NSTableCellView()
            c.identifier = id
            let t = NSTextField(labelWithString: "")
            t.lineBreakMode = .byTruncatingTail
            t.translatesAutoresizingMaskIntoConstraints = false
            c.addSubview(t)
            c.textField = t
            NSLayoutConstraint.activate([
                t.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 2),
                t.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -2),
                t.centerYAnchor.constraint(equalTo: c.centerYAnchor),
            ])
            return c
        }()
        let t = cell.textField!
        t.textColor = .labelColor
        t.alignment = col == "name" ? .left : .right
        // 层级用字号与字重区分（红线④：不用次要色）
        switch n.kind {
        case .group: t.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        case .source: t.font = .systemFont(ofSize: NSFont.systemFontSize)
        case .chunk: t.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        }
        switch col {
        case "name": t.stringValue = n.title; t.toolTip = n.kind == .chunk ? n.title : nil
        case "chunks": t.stringValue = n.kind == .chunk ? "" : "\(n.chunks)"
        default: t.stringValue = n.kind == .chunk ? (n.hasVector ? "✓" : "—") : "\(n.vectors)"
        }
        return cell
    }
}
