import AppKit
import Combine

/// 分页画板的「页面」面板（工具条那颗按钮弹出，`BOARD-NOTE-PLAN.md §9.4`）：
///  · 整本页面大小：预设（A4 / A5 / Letter / 当前屏幕）× 横竖；
///  · 页列表（系统表格，⌘ / ⇧ 多选，⌘A 全选，双击跳过去）→ 给选中的页批量设背景、在后面插一页、删掉。
/// 全部走系统控件；数据只改 `DocSession`，落库与平板广播由会话那边对账。
final class BoardPagesPanel: NSView, NSTableViewDataSource, NSTableViewDelegate {
    var onDelete: (Set<Int>) -> Void = { _ in }
    var onJump: (Int) -> Void = { _ in }

    private let session: DocSession
    private let sizePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let orient = NSSegmentedControl(labels: [L("Portrait"), L("Landscape")], trackingMode: .selectOne,
                                            target: nil, action: nil)
    private let table = NSTableView()
    private let bgPopup = NSPopUpButton(frame: .zero, pullsDown: true)
    private var bag = Set<AnyCancellable>()
    private let sizes = BoardPageSize.allCases

    override var isFlipped: Bool { true }

    init(session: DocSession) {
        self.session = session
        super.init(frame: NSRect(x: 0, y: 0, width: 300, height: 420))
        build()
        session.$boardPages.receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.reload() }.store(in: &bag)
        reload()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) 不支持") }

    private func build() {
        let sizeTitle = NSTextField(labelWithString: L("Page Size"))
        sizeTitle.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        for s in sizes { sizePopup.addItem(withTitle: s.label) }
        sizePopup.target = self
        sizePopup.action = #selector(sizeChanged)
        orient.target = self
        orient.action = #selector(sizeChanged)
        let sizeRow = NSStackView(views: [sizePopup, orient])
        sizeRow.spacing = 8

        let pagesTitle = NSTextField(labelWithString: L("Page List"))
        pagesTitle.font = sizeTitle.font
        let col = NSTableColumn(identifier: .init("page"))
        table.addTableColumn(col)
        table.headerView = nil
        table.allowsMultipleSelection = true
        table.usesAlternatingRowBackgroundColors = true
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(jump)
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder

        bgPopup.addItem(withTitle: L("Background"))   // 下拉按钮的标题项
        for t in BoardTemplate.allCases {
            let item = NSMenuItem(title: t.label, action: #selector(setBackground(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = t.rawValue
            bgPopup.menu?.addItem(item)
        }
        let insert = NSButton(title: L("Insert Page"), target: self, action: #selector(insertPage))
        let delete = NSButton(title: L("Delete"), target: self, action: #selector(deletePages))
        let buttons = NSStackView(views: [bgPopup, insert, delete])
        buttons.spacing = 8
        let tip = NSTextField(wrappingLabelWithString: L("Select several pages with ⌘ or ⇧ to change them together."))
        tip.font = .preferredFont(forTextStyle: .caption1)
        tip.textColor = .labelColor

        let stack = NSStackView(views: [sizeTitle, sizeRow, pagesTitle, scroll, buttons, tip])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28),
            scroll.heightAnchor.constraint(equalToConstant: 220),
            tip.widthAnchor.constraint(equalTo: scroll.widthAnchor),
        ])
    }

    private func reload() {
        let keep = table.selectedRowIndexes
        table.reloadData()
        table.selectRowIndexes(IndexSet(keep.filter { $0 < session.boardPages.count }), byExtendingSelection: false)
        let l = session.boardLayout
        let landscape = l.width > l.height
        orient.selectedSegment = landscape ? 1 : 0
        let screen = NSScreen.main?.visibleFrame.size ?? CGSize(width: 1280, height: 800)
        let portrait = CGSize(width: min(l.width, l.height), height: max(l.width, l.height))
        let hit = sizes.firstIndex { s in
            let p = s.portrait(screen: screen)
            return abs(p.width - portrait.width) < 1 && abs(p.height - portrait.height) < 1
        }
        if let hit { sizePopup.selectItem(at: hit) } else { sizePopup.select(nil) }
    }

    // MARK: 表格

    func numberOfRows(in tableView: NSTableView) -> Int { session.boardPages.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard session.boardPages.indices.contains(row) else { return nil }
        let id = NSUserInterfaceItemIdentifier("cell")
        let cell = (tableView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView) ?? {
            let c = NSTableCellView()
            c.identifier = id
            let f = NSTextField(labelWithString: "")
            f.translatesAutoresizingMaskIntoConstraints = false
            c.addSubview(f)
            c.textField = f
            NSLayoutConstraint.activate([
                f.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 4),
                f.trailingAnchor.constraint(lessThanOrEqualTo: c.trailingAnchor, constant: -4),
                f.centerYAnchor.constraint(equalTo: c.centerYAnchor),
            ])
            return c
        }()
        cell.textField?.stringValue = String(format: L("Page %d"), row + 1) + " · " + session.boardPages[row].template.label
        return cell
    }

    // MARK: 动作

    /// 选中的页；什么都没选 = 全部（批量设背景时最常见的意图）。
    private var targets: Set<Int> {
        let sel = Set(table.selectedRowIndexes)
        return sel.isEmpty ? Set(session.boardPages.indices) : sel
    }

    @objc private func sizeChanged() {
        let i = sizePopup.indexOfSelectedItem
        guard sizes.indices.contains(i) else { return }
        let screen = NSScreen.main?.visibleFrame.size ?? CGSize(width: 1280, height: 800)
        var s = sizes[i].portrait(screen: screen)
        if orient.selectedSegment == 1 { s = CGSize(width: s.height, height: s.width) }
        session.setBoardPageSize(width: Double(s.width), height: Double(s.height))
    }

    @objc private func setBackground(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String else { return }
        session.setBoardTemplate(BoardTemplate(raw: raw), pages: targets)
    }

    @objc private func insertPage() {
        let after = table.selectedRowIndexes.last ?? (session.boardPages.count - 1)
        session.insertBoardPage(at: after + 1)
    }

    @objc private func deletePages() {
        let sel = Set(table.selectedRowIndexes)
        guard !sel.isEmpty else { NSSound.beep(); return }
        onDelete(sel)
    }

    @objc private func jump() {
        let r = table.clickedRow
        if session.boardPages.indices.contains(r) { onJump(r) }
    }
}
