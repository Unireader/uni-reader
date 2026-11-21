import AppKit

/// Markdown 笔记的目录树（Inspector「目录」页，笔记标签时代替 PDF 目录）。数据来自 `MarkdownOutline`。
/// 点一行 → `onSelect(序号)`，由上层让编辑区滚到第几个标题。
final class NoteOutlineView: NSView, NSOutlineViewDataSource, NSOutlineViewDelegate {
    var onSelect: (Int) -> Void = { _ in }

    private let outline = NSOutlineView()
    private let scroll = NSScrollView()
    private let empty = NSTextField(labelWithString: "")
    private var roots: [MarkdownOutlineNode] = []
    private var shown: [MarkdownHeading] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        outline.headerView = nil
        outline.style = .plain
        outline.backgroundColor = .clear
        outline.indentationPerLevel = 14
        let col = NSTableColumn(identifier: .init("note-toc"))
        outline.addTableColumn(col)
        outline.outlineTableColumn = col
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.action = #selector(clicked)
        scroll.documentView = outline
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        addSubview(scroll)
        empty.stringValue = L("No headings in this note")
        empty.textColor = .labelColor   // 红线：材质底上别用次要色
        empty.font = .preferredFont(forTextStyle: .callout)
        empty.alignment = .center
        addSubview(empty)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) 不支持") }

    override func layout() {
        super.layout()
        scroll.frame = bounds
        let s = empty.fittingSize
        empty.frame = NSRect(x: 0, y: (bounds.height - s.height) / 2, width: bounds.width, height: s.height)
    }

    /// 喂正文。标题没变不重建（自动保存每 0.8 秒一次，别让列表跟着闪、展开态别丢）。
    func update(text: String) {
        let hs = MarkdownOutline.headings(in: text)
        empty.isHidden = !hs.isEmpty
        scroll.isHidden = !hs.isEmpty ? false : true
        guard hs != shown else { return }
        shown = hs
        roots = MarkdownOutlineNode.tree(from: hs)
        outline.reloadData()
        outline.expandItem(nil, expandChildren: true)
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        (item as? MarkdownOutlineNode)?.children.count ?? roots.count
    }
    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        (item as? MarkdownOutlineNode)?.children[index] ?? roots[index]
    }
    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        !((item as? MarkdownOutlineNode)?.children.isEmpty ?? true)
    }
    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool { false }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let n = item as? MarkdownOutlineNode else { return nil }
        let cell = NSTableCellView()
        let title = NSTextField(labelWithString: n.heading.title.isEmpty ? "—" : n.heading.title)
        title.lineBreakMode = .byTruncatingTail
        title.textColor = .labelColor
        title.font = n.heading.level == 1 ? .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
                                          : .systemFont(ofSize: NSFont.systemFontSize)
        title.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(title)
        cell.textField = title
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            title.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
            title.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    @objc private func clicked() {
        guard let n = outline.item(atRow: outline.clickedRow) as? MarkdownOutlineNode else { return }
        onSelect(n.ordinal)
    }
}
