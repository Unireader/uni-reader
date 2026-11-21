import AppKit

/// 新建标签时的选文档弹窗（AppKit 版，替代 SwiftUI `DocPickerView`；标签栏「+」与 ⌘T 共用）：
/// 搜索框 + 本工作区文档列表（最近打开的在前），回车 / 单击打开，方向键在搜索框里也能挑。
/// 只列书库里已有的文档，不导入新文件；选中交给 `TabsModel.open`（已开着的就切过去）。
/// 🔴 弹窗底是系统材质：文字一律主色，次要信息靠字号 + 不透明度区分；列表不画自己的底色。
@MainActor
final class DocPickerController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    private let documents: [LibDocument]
    private let openIDs: Set<String>
    private let onPick: (String) -> Void

    private let field = NSTextField()
    private let table = NSTableView()
    private let scroll = NSScrollView()
    private let empty = NSTextField(labelWithString: "")
    private var filtered: [LibDocument] = []
    /// 按分组分段显示（参考窗选书用）：每组一个小标题，组内最近打开的在前；没分组的归「未分组」放最后。
    private let grouped: Bool
    private enum Row { case header(String), doc(LibDocument) }
    private var rows: [Row] = []

    private static let width: CGFloat = 420
    private static let rowHeight: CGFloat = 44
    private static let maxVisibleRows = 7
    private static let headerH: CGFloat = 46

    static func forTabs(_ tabs: TabsModel, workspace: WorkspaceManager) -> DocPickerController {
        DocPickerController(documents: workspace.documents, openIDs: Set(tabs.tabs.compactMap(\.docID))) { [weak tabs] id in
            tabs?.docPickerPresented = false
            tabs?.open(id)
        }
    }

    /// 参考窗（独立窗口 / 覆盖层）换书用：同一个搜索选书面板放进 popover，选中后自动收起。
    /// 当前这本在副标题里标「已打开」。
    static func popover(workspace: WorkspaceManager, current: String?,
                        onPick: @escaping (String) -> Void) -> NSPopover {
        let p = NSPopover()
        p.behavior = .transient
        let vc = DocPickerController(documents: workspace.documents, openIDs: current.map { [$0] } ?? [], grouped: true) { [weak p] id in
            p?.performClose(nil)
            onPick(id)
        }
        p.contentViewController = vc
        return p
    }

    init(documents: [LibDocument], openIDs: Set<String>, grouped: Bool = false, onPick: @escaping (String) -> Void) {
        self.grouped = grouped
        self.documents = documents
        self.openIDs = openIDs
        self.onPick = onPick
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) 不支持") }

    override func loadView() {
        let root = FlippedView(frame: NSRect(x: 0, y: 0, width: Self.width, height: 200))
        let icon = NSImageView(image: NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil) ?? NSImage())
        icon.symbolConfiguration = .init(textStyle: .title3)
        icon.contentTintColor = .labelColor
        icon.frame = NSRect(x: 14, y: 11, width: 22, height: 24)
        field.placeholderString = L("Search Documents")
        field.font = .preferredFont(forTextStyle: .title3)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.delegate = self
        field.frame = NSRect(x: 44, y: 12, width: Self.width - 58, height: 24)
        let line = NSBox()
        line.boxType = .separator
        line.frame = NSRect(x: 0, y: Self.headerH - 1, width: Self.width, height: 1)
        let col = NSTableColumn(identifier: .init("doc"))
        table.addTableColumn(col)
        table.headerView = nil
        table.style = .inset
        table.backgroundColor = .clear
        table.rowHeight = Self.rowHeight
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(clicked)
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false   // 占位式滚动条会在右侧留槽；滚轮与方向键照样能滚
        empty.font = .preferredFont(forTextStyle: .callout)
        empty.textColor = NSColor.labelColor.withAlphaComponent(0.7)
        empty.alignment = .center
        for v in [icon, field, line, scroll, empty] as [NSView] { root.addSubview(v) }
        view = root
        reload()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(field)
    }

    private func reload() {
        let q = field.stringValue.trimmingCharacters(in: .whitespaces)
        let sorted = documents.sorted { $0.lastOpenedAt > $1.lastOpenedAt }
        filtered = q.isEmpty ? sorted
            : sorted.filter { $0.title.localizedCaseInsensitiveContains(q) || $0.group.localizedCaseInsensitiveContains(q) }
        rows = filtered.map { .doc($0) }
        if grouped {
            var order: [String] = [], byGroup: [String: [LibDocument]] = [:]
            for d in filtered {   // filtered 已按最近打开排好：组按首次出现的顺序，组内保持
                if byGroup[d.group] == nil { order.append(d.group) }
                byGroup[d.group, default: []].append(d)
            }
            order.sort { a, b in
                if a.isEmpty != b.isEmpty { return b.isEmpty }          // 未分组放最后
                return a.localizedStandardCompare(b) == .orderedAscending
            }
            rows = order.flatMap { g in [Row.header(g.isEmpty ? L("Ungrouped") : g)] + byGroup[g]!.map { .doc($0) } }
        }
        table.reloadData()
        if let first = rows.firstIndex(where: { if case .doc = $0 { true } else { false } }) {
            table.selectRowIndexes([first], byExtendingSelection: false)
        }
        // 高度随条数走：两三篇时不留一大截空白，多了封顶滚动
        let listH: CGFloat
        if filtered.isEmpty {
            empty.stringValue = documents.isEmpty ? L("No documents in this workspace.") : L("No matching documents.")
            empty.isHidden = false
            scroll.isHidden = true
            listH = 64
            empty.frame = NSRect(x: 0, y: Self.headerH + 22, width: Self.width, height: 20)
        } else {
            empty.isHidden = true
            scroll.isHidden = false
            let headers = rows.count - filtered.count
            listH = CGFloat(min(rows.count, Self.maxVisibleRows)) * Self.rowHeight + 16
            _ = headers
            scroll.frame = NSRect(x: 0, y: Self.headerH, width: Self.width, height: listH)
        }
        let size = NSSize(width: Self.width, height: Self.headerH + listH)
        view.setFrameSize(size)
        preferredContentSize = size
    }

    private func pickSelection() {
        let r = table.selectedRow
        if rows.indices.contains(r), case .doc(let d) = rows[r] { onPick(d.id) } else if let f = filtered.first { onPick(f.id) }
    }

    @objc private func clicked() {
        let r = table.clickedRow
        if rows.indices.contains(r), case .doc(let d) = rows[r] { onPick(d.id) }
    }

    private func move(_ step: Int) {
        guard !rows.isEmpty else { return }
        var i = table.selectedRow >= 0 ? table.selectedRow : (step > 0 ? -1 : rows.count)
        repeat { i += step } while rows.indices.contains(i) && { if case .header = rows[i] { true } else { false } }()
        guard rows.indices.contains(i) else { return }
        table.selectRowIndexes([i], byExtendingSelection: false)
        table.scrollRowToVisible(i)
    }

    // 搜索框

    func controlTextDidChange(_ obj: Notification) { reload() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        switch sel {
        case #selector(NSResponder.insertNewline(_:)): pickSelection(); return true
        case #selector(NSResponder.moveDown(_:)): move(1); return true
        case #selector(NSResponder.moveUp(_:)): move(-1); return true
        default: return false
        }
    }

    // 列表

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        if case .doc = rows[row] { return true } else { return false }
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        if case .header = rows[row] { return 26 } else { return Self.rowHeight }
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard case .doc(let d) = rows[row] else {
            if case .header(let g) = rows[row] {
                let l = NSTextField(labelWithString: g)
                l.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
                l.textColor = .labelColor   // 红线：材质底上别用次要色
                l.lineBreakMode = .byTruncatingTail
                let v = NSTableCellView()
                l.translatesAutoresizingMaskIntoConstraints = false
                v.addSubview(l)
                NSLayoutConstraint.activate([
                    l.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 8),
                    l.trailingAnchor.constraint(lessThanOrEqualTo: v.trailingAnchor, constant: -8),
                    l.bottomAnchor.constraint(equalTo: v.bottomAnchor, constant: -3),
                ])
                return v
            }
            return nil
        }
        let id = NSUserInterfaceItemIdentifier("docRow")
        let v = (tableView.makeView(withIdentifier: id, owner: nil) as? DocPickerRow) ?? {
            let r = DocPickerRow()
            r.identifier = id
            return r
        }()
        // 第二行固定有内容（页数总在），行高才一致：分组 · 页数 · 已打开
        var parts: [String] = []
        if !d.group.isEmpty { parts.append(d.group) }
        parts.append(String(format: L("%d pages"), d.pageCount))
        if openIDs.contains(d.id) { parts.append(L("Already Open")) }
        v.set(title: d.title, detail: parts.joined(separator: " · "))
        return v
    }
}

private final class DocPickerRow: NSTableCellView {
    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        icon.image = NSImage(systemSymbolName: "doc.richtext", accessibilityDescription: nil)
        icon.symbolConfiguration = .init(textStyle: .title2)
        icon.contentTintColor = .labelColor
        title.font = .preferredFont(forTextStyle: .body)
        title.lineBreakMode = .byTruncatingMiddle
        detail.font = .preferredFont(forTextStyle: .caption1)
        detail.textColor = NSColor.labelColor.withAlphaComponent(0.7)
        detail.lineBreakMode = .byTruncatingTail
        for v in [icon, title, detail] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        for t in [title, detail] { t.setContentCompressionResistancePriority(.init(1), for: .horizontal) }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 24),
            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            title.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4),
            title.bottomAnchor.constraint(equalTo: centerYAnchor, constant: 1),
            detail.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            detail.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4),
            detail.topAnchor.constraint(equalTo: centerYAnchor, constant: 2),
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) 不支持") }

    func set(title t: String, detail d: String) {
        title.stringValue = t
        detail.stringValue = d
    }
}
