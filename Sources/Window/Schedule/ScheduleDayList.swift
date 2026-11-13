import AppKit

/// 日程页右边的事项列表（`SCHEDULE-PLAN.md §4.2`）：选中那一天的事项；看的是今天时，下面再列「过期没做完」；
/// 最后是「没排日期」。每行一个勾选框（打勾 = 做完）+ 标题 + 一行小字（时间 · 时长 · 计划）。
/// 行可以拖到左边月历的某一天（挪日子）；右键：打勾、挪到今天 / 明天 / 后天 / 下周一 / 不排日期、删除。
/// 键盘：空格打勾、Delete 删除。
@MainActor
final class ScheduleDayList: NSView, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
    enum Row {
        case header(String)
        case item(LibScheduleItem, showDay: Bool)
        case empty(String)
    }

    var onSelect: (LibScheduleItem?) -> Void = { _ in }
    var onToggle: (_ id: String, _ done: Bool) -> Void = { _, _ in }
    var onMove: (_ ids: [String], _ day: String) -> Void = { _, _ in }
    var onDelete: (_ ids: [String]) -> Void = { _ in }

    private let scroll = NSScrollView()
    private let table = ScheduleTable()
    private var rows: [Row] = []
    private var planTitles: [String: String] = [:]
    private var today = ""
    /// 自己在改选中（重载后把选中放回去）：这时的选中变化不往外报。
    private var syncing = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        let col = NSTableColumn(identifier: .init("item"))
        col.resizingMask = .autoresizingMask
        table.addTableColumn(col)
        table.headerView = nil
        table.style = .plain
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.backgroundColor = .clear
        table.dataSource = self
        table.delegate = self
        table.allowsMultipleSelection = true
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.setDraggingSourceOperationMask(.move, forLocal: true)
        table.onKey = { [weak self] k in self?.key(k) ?? false }
        let menu = NSMenu()
        menu.delegate = self
        table.menu = menu
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        addSubview(scroll)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) 不支持") }

    override func layout() {
        super.layout()
        scroll.frame = bounds
        table.sizeLastColumnToFit()
    }

    /// 换一份内容；`select` = 要选中的那一件（还在就选上，不在就不选）。
    func show(_ rows: [Row], planTitles: [String: String], today: String, select: String?) {
        self.rows = rows
        self.planTitles = planTitles
        self.today = today
        syncing = true
        table.reloadData()
        if let select, let i = rows.firstIndex(where: { if case .item(let m, _) = $0 { return m.id == select } else { return false } }) {
            table.selectRowIndexes([i], byExtendingSelection: false)
            table.scrollRowToVisible(i)
        } else {
            table.deselectAll(nil)
        }
        syncing = false
    }

    private func item(_ row: Int) -> LibScheduleItem? {
        guard rows.indices.contains(row), case .item(let m, _) = rows[row] else { return nil }
        return m
    }

    private var selectedItems: [LibScheduleItem] { table.selectedRowIndexes.compactMap(item) }

    // MARK: 表

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        if case .header = rows[row] { return true }
        return false
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { item(row) != nil }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        switch rows[row] {
        case .header: return 26
        case .empty: return 34
        case .item(let m, let showDay):
            return ScheduleFormat.subtitle(m, planTitle: planTitles[m.planId], showDay: showDay, today: today).isEmpty ? 30 : 42
        }
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch rows[row] {
        case .header(let title):
            let f = NSTextField(labelWithString: title)
            f.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
            f.textColor = .labelColor
            let v = NSTableCellView()
            f.translatesAutoresizingMaskIntoConstraints = false
            v.addSubview(f)
            NSLayoutConstraint.activate([
                f.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 8),
                f.centerYAnchor.constraint(equalTo: v.centerYAnchor),
            ])
            return v
        case .empty(let text):
            let f = NSTextField(labelWithString: text)
            f.font = .preferredFont(forTextStyle: .callout)
            f.textColor = .labelColor
            let v = NSTableCellView()
            f.translatesAutoresizingMaskIntoConstraints = false
            v.addSubview(f)
            NSLayoutConstraint.activate([
                f.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 12),
                f.centerYAnchor.constraint(equalTo: v.centerYAnchor),
            ])
            return v
        case .item(let m, let showDay):
            let cell = (tableView.makeView(withIdentifier: ScheduleItemCell.id, owner: nil) as? ScheduleItemCell) ?? ScheduleItemCell()
            let overdue = !m.isDone && !m.day.isEmpty && m.day < today
            cell.set(m, subtitle: ScheduleFormat.subtitle(m, planTitle: planTitles[m.planId], showDay: showDay || overdue, today: today))
            cell.onToggle = { [weak self] done in self?.onToggle(m.id, done) }
            return cell
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !syncing else { return }
        let sel = selectedItems
        onSelect(sel.count == 1 ? sel[0] : nil)
    }

    // 拖到月历上挪日子
    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard let m = item(row) else { return nil }
        let pb = NSPasteboardItem()
        pb.setString(m.id, forType: ScheduleMonthView.dragType)
        return pb
    }

    // MARK: 键盘 / 右键

    private func key(_ event: NSEvent) -> Bool {
        let sel = selectedItems
        guard !sel.isEmpty else { return false }
        switch event.keyCode {
        case 49:   // 空格：打勾 / 取消（几件一起：有没做完的就都打勾）
            let done = sel.contains { !$0.isDone }
            for m in sel { onToggle(m.id, done) }
            return true
        case 51, 117:   // Delete / Forward Delete
            onDelete(sel.map(\.id))
            return true
        default:
            return false
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let clicked = table.clickedRow
        guard item(clicked) != nil else { return }
        if !table.selectedRowIndexes.contains(clicked) { table.selectRowIndexes([clicked], byExtendingSelection: false) }
        let sel = selectedItems
        let ids = sel.map(\.id)
        let allDone = sel.allSatisfy(\.isDone)
        menu.addItem(ClosureMenuItem(allDone ? L("Mark as Not Done") : L("Mark as Done")) { [weak self] in
            for id in ids { self?.onToggle(id, !allDone) }
        })
        menu.addItem(.separator())
        let move = NSMenuItem(title: L("Move To"), action: nil, keyEquivalent: "")
        let sub = NSMenu()
        var targets: [(String, String)] = []
        if let d = ScheduleDay.adding(0, to: today) { targets.append((L("Today"), d)) }
        if let d = ScheduleDay.adding(1, to: today) { targets.append((L("Tomorrow"), d)) }
        if let d = ScheduleDay.adding(2, to: today) { targets.append((L("The Day After Tomorrow"), d)) }
        if let wd = ScheduleDay.weekday(today), let d = ScheduleDay.adding((2 - wd + 7) % 7 == 0 ? 7 : (2 - wd + 7) % 7, to: today) {
            targets.append((L("Next Monday"), d))
        }
        for (title, day) in targets {
            sub.addItem(ClosureMenuItem(title + " · " + ScheduleFormat.day(day, today: today)) { [weak self] in self?.onMove(ids, day) })
        }
        sub.addItem(.separator())
        sub.addItem(ClosureMenuItem(L("No Date")) { [weak self] in self?.onMove(ids, "") })
        move.submenu = sub
        menu.addItem(move)
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(L("Delete…")) { [weak self] in self?.onDelete(ids) })
    }
}

/// 列表里能接空格 / Delete 的表（其余键照常）。
private final class ScheduleTable: NSTableView {
    var onKey: (NSEvent) -> Bool = { _ in false }
    override func keyDown(with event: NSEvent) {
        if !onKey(event) { super.keyDown(with: event) }
    }
}

/// 一件事那一行：勾选框 + 标题（做完的划掉）+ 一行小字。
private final class ScheduleItemCell: NSTableCellView {
    static let id = NSUserInterfaceItemIdentifier("schedule.item")
    var onToggle: (Bool) -> Void = { _ in }
    private let check = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let title = NSTextField(labelWithString: "")
    private let sub = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        identifier = Self.id
        check.target = self
        check.action = #selector(toggled)
        title.lineBreakMode = .byTruncatingTail
        title.font = .preferredFont(forTextStyle: .body)
        title.textColor = .labelColor
        sub.lineBreakMode = .byTruncatingTail
        sub.font = .preferredFont(forTextStyle: .caption1)
        sub.textColor = .labelColor
        for v in [check, title, sub] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        sub.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        NSLayoutConstraint.activate([
            check.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            check.centerYAnchor.constraint(equalTo: centerYAnchor),
            title.leadingAnchor.constraint(equalTo: check.trailingAnchor, constant: 4),
            title.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            sub.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            sub.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            sub.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 1),
        ])
        titleCenter = title.centerYAnchor.constraint(equalTo: centerYAnchor)
        titleTop = title.topAnchor.constraint(equalTo: topAnchor, constant: 5)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) 不支持") }

    private var titleCenter: NSLayoutConstraint!
    private var titleTop: NSLayoutConstraint!

    func set(_ m: LibScheduleItem, subtitle: String) {
        check.state = m.isDone ? .on : .off
        check.toolTip = m.isDone ? L("Mark as Not Done") : L("Mark as Done")
        var attrs: [NSAttributedString.Key: Any] = [.font: NSFont.preferredFont(forTextStyle: .body), .foregroundColor: NSColor.labelColor]
        if m.isDone { attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        title.attributedStringValue = NSAttributedString(string: m.title, attributes: attrs)
        sub.stringValue = subtitle
        sub.isHidden = subtitle.isEmpty
        titleCenter.isActive = subtitle.isEmpty
        titleTop.isActive = !subtitle.isEmpty
        toolTip = m.detail.isEmpty ? nil : String(m.detail.prefix(400))
    }

    @objc private func toggled() { onToggle(check.state == .on) }
}
