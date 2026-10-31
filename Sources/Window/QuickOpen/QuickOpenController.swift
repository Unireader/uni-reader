import AppKit

/// ⌘P 快速打开（`QUICK-OPEN-PLAN.md`，用户 2026-10-31 要的「像聚焦搜索那样」）：浮在**当前窗口上方居中**的一块玻璃，
/// 上面一个大号输入框、下面是结果；搜当前窗口工作区里的 PDF / Markdown 笔记 / 画板 / 习题的一组。
///
/// - 外观全用系统件：`NSGlassEffectView`（系统玻璃）+ 无边框输入框 + `.inset` 表格的系统选中样式 + SF Symbols。
///   玻璃上的字一律 `labelColor`，层级用字号区分（红线④）。
/// - 是阅读窗的子窗口（跟着窗口走），能成为 key（要打字）；失去 key（点了别处 / 切走 App）就收起。
/// - 键盘：↑↓（⌃P / ⌃N）选、回车打开、Esc 收起、再按一次 ⌘P 收起；鼠标单击一行直接打开。
/// - 打开 = 侧栏单击那一行（`TabsModel.open` / `openMarkdown` / `openBoard` / `openExercises`）。
@MainActor
final class QuickOpenController: NSObject, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate {
    static let shared = QuickOpenController()

    static let width: CGFloat = 640
    static let searchHeight: CGFloat = 54
    static let rowHeight: CGFloat = 44
    static let maxRows = 8
    static let cornerRadius: CGFloat = 22

    private let panel: Panel
    private let content = FlippedView()
    private let icon = NSImageView()
    let field = NSTextField()
    private let separator = NSBox()
    private let scroll = NSScrollView()
    private let table = ClickTableView()
    private let emptyLabel = NSTextField(labelWithString: L("No Results"))
    private weak var reader: ReaderWindowController?
    private var all: [QuickOpenItem] = []
    private(set) var shown: [QuickOpenItem] = []

    /// 能成为 key（要打字）的无边框浮窗。⌘P（或用户改成的那个键）在这里先截下来收起自己——
    /// 不走菜单那条路：菜单发的通知只有 key 阅读窗认领，面板是 key 时没人接。
    private final class Panel: NSPanel {
        var onToggleKey: (() -> Void)?
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { false }
        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            if let c = KeyCombo(event: event), c == Shortcuts.shared.combo(for: .quickOpen) {
                onToggleKey?()
                return true
            }
            return super.performKeyEquivalent(with: event)
        }
    }

    /// 从上往下排版（搜索行在顶上，高度随结果变时顶边不动）。
    final class FlippedView: NSView {
        override var isFlipped: Bool { true }
    }

    /// 焦点一直在输入框里，表格不当第一响应者；单击一行就打开。
    private final class ClickTableView: NSTableView {
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    }

    /// 表格不是第一响应者，系统会把选中行画成灰的「非活动」样式；这里始终按活动样式画（同 `AgentMentionPopup`）。
    private final class RowView: NSTableRowView {
        override var isEmphasized: Bool { get { true } set {} }
    }

    override init() {
        panel = Panel(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: Self.searchHeight),
                      styleMask: [.borderless], backing: .buffered, defer: true)
        super.init()
        panel.isReleasedWhenClosed = false
        panel.hasShadow = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.delegate = self
        panel.onToggleKey = { [weak self] in self?.close() }

        let glass = NSGlassEffectView()
        glass.cornerRadius = Self.cornerRadius
        glass.contentView = content
        panel.contentView = glass

        let sym = NSImage.SymbolConfiguration(pointSize: 18, weight: .regular)
        icon.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)?.withSymbolConfiguration(sym)
        icon.contentTintColor = .labelColor
        content.addSubview(icon)

        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 20)
        field.textColor = .labelColor
        field.placeholderString = L("Search PDFs, notes, boards and exercises")
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.delegate = self
        content.addSubview(field)

        separator.boxType = .separator
        content.addSubview(separator)

        let col = NSTableColumn(identifier: .init("item"))
        table.addTableColumn(col)
        table.headerView = nil
        table.style = .inset
        table.rowHeight = Self.rowHeight
        table.backgroundColor = .clear
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(clicked)
        table.refusesFirstResponder = true
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        content.addSubview(scroll)

        emptyLabel.font = .systemFont(ofSize: 14)
        emptyLabel.textColor = .labelColor
        emptyLabel.alignment = .center
        content.addSubview(emptyLabel)
    }

    var isShown: Bool { panel.isVisible }

    // MARK: 开 / 关

    /// ⌘P：开着就收起，否则在这扇阅读窗上方居中弹出（每次弹出现取一遍工作区里的东西）。
    func toggle(for c: ReaderWindowController) {
        if panel.isVisible { close(); return }
        guard let win = c.window else { return }
        reader = c
        all = QuickOpenItem.all(in: c.workspace)
        field.stringValue = ""
        // 顶边：窗口顶往下约六分之一（至少让开工具栏），左右居中；放不进屏幕就往里挪
        let wf = win.frame
        let w = min(Self.width, max(360, wf.width - 48))
        let top = wf.maxY - max(80, wf.height * 0.16)
        var x = wf.midX - w / 2
        if let screen = (win.screen ?? NSScreen.main)?.visibleFrame {
            x = min(max(x, screen.minX + 8), screen.maxX - w - 8)
        }
        panel.setFrame(NSRect(x: x, y: top - Self.searchHeight, width: w, height: Self.searchHeight), display: false)
        if panel.parent !== win {
            panel.parent?.removeChildWindow(panel)
            win.addChildWindow(panel, ordered: .above)
        }
        refilter()
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(field)
    }

    /// 收起，焦点交还给原来那扇阅读窗。
    func close() {
        guard panel.isVisible else { return }
        let parent = panel.parent
        parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        parent?.makeKey()
    }

    func windowDidResignKey(_ notification: Notification) { close() }

    // MARK: 过滤 / 排版

    private func refilter() {
        shown = QuickOpenItem.rank(all, query: field.stringValue)
        table.reloadData()
        if !shown.isEmpty {
            table.selectRowIndexes([0], byExtendingSelection: false)
            table.scrollRowToVisible(0)
        }
        resize()
    }

    /// 结果区的高：有结果 = 行数（最多 8 行，再多就滚）；输入了但没结果 = 一行「没有找到」；没输入也没东西 = 不显示。
    var listHeight: CGFloat {
        if !shown.isEmpty { return CGFloat(min(shown.count, Self.maxRows)) * Self.rowHeight + 12 }
        return field.stringValue.isEmpty ? 0 : Self.rowHeight
    }

    /// 高度随结果变，顶边不动。
    private func resize() {
        let list = listHeight
        let h = Self.searchHeight + (list > 0 ? 1 + list : 0)
        var f = panel.frame
        f.origin.y = f.maxY - h
        f.size.height = h
        panel.setFrame(f, display: true)
        layoutContent(width: f.width)
        panel.invalidateShadow()
    }

    /// 摆各部件（`content` 是翻转坐标，从上往下）。离屏测试直接调它。
    func layoutContent(width: CGFloat) {
        let list = listHeight
        let h = Self.searchHeight + (list > 0 ? 1 + list : 0)
        content.frame = NSRect(x: 0, y: 0, width: width, height: h)
        icon.frame = NSRect(x: 18, y: (Self.searchHeight - 24) / 2, width: 24, height: 24)
        let fh = ceil(field.intrinsicContentSize.height)
        field.frame = NSRect(x: 52, y: (Self.searchHeight - fh) / 2, width: width - 52 - 18, height: fh)
        separator.isHidden = list == 0
        separator.frame = NSRect(x: 0, y: Self.searchHeight, width: width, height: 1)
        let listRect = NSRect(x: 0, y: Self.searchHeight + 1, width: width, height: list)
        scroll.isHidden = shown.isEmpty
        scroll.frame = listRect
        emptyLabel.isHidden = !shown.isEmpty || list == 0
        let lh = ceil(emptyLabel.intrinsicContentSize.height)
        emptyLabel.frame = NSRect(x: 16, y: listRect.minY + (list - lh) / 2, width: width - 32, height: lh)
    }

    // MARK: 键盘

    func controlTextDidChange(_ obj: Notification) { refilter() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        switch sel {
        case #selector(NSResponder.moveUp(_:)): move(-1); return true
        case #selector(NSResponder.moveDown(_:)): move(1); return true
        case #selector(NSResponder.insertNewline(_:)):
            if shown.indices.contains(table.selectedRow) { open(shown[table.selectedRow]) }
            return true
        case #selector(NSResponder.cancelOperation(_:)): close(); return true
        default: return false
        }
    }

    /// ↑ / ↓：循环移动选中行。
    private func move(_ delta: Int) {
        guard !shown.isEmpty else { return }
        let cur = max(0, table.selectedRow)
        let next = ((cur + delta) % shown.count + shown.count) % shown.count
        table.selectRowIndexes([next], byExtendingSelection: false)
        table.scrollRowToVisible(next)
    }

    @objc private func clicked() {
        guard shown.indices.contains(table.clickedRow) else { return }
        open(shown[table.clickedRow])
    }

    /// 同侧栏单击那一行。先收起（焦点回到阅读窗）再开。
    private func open(_ item: QuickOpenItem) {
        guard let c = reader else { close(); return }
        close()
        switch item.target {
        case .document(let id): _ = c.tabs.open(id)
        case .markdown(let ref): c.tabs.openMarkdown(ref)
        case .board(let id): c.tabs.openBoard(id)
        case .exercises(let scope): c.tabs.openExercises(scope)
        }
    }

    // MARK: 表格

    func numberOfRows(in tableView: NSTableView) -> Int { shown.count }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { RowView() }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = (tableView.makeView(withIdentifier: Cell.id, owner: nil) as? Cell) ?? Cell()
        cell.show(shown[row])
        return cell
    }

    /// 一行：图标 + 名字（14pt）+ 第二行（11pt）。都用 `labelColor`，层级靠字号（红线④）。
    private final class Cell: NSTableCellView {
        static let id = NSUserInterfaceItemIdentifier("quickOpenCell")
        private let symbol = NSImageView()
        private let title = NSTextField(labelWithString: "")
        private let detail = NSTextField(labelWithString: "")

        init() {
            super.init(frame: .zero)
            identifier = Self.id
            symbol.contentTintColor = .labelColor
            symbol.symbolConfiguration = .init(pointSize: 16, weight: .regular)
            title.font = .systemFont(ofSize: 14)
            title.textColor = .labelColor
            title.lineBreakMode = .byTruncatingMiddle
            detail.font = .systemFont(ofSize: 11)
            detail.textColor = .labelColor
            detail.lineBreakMode = .byTruncatingTail
            for v in [symbol, title, detail] as [NSView] {
                v.translatesAutoresizingMaskIntoConstraints = false
                addSubview(v)
            }
            title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            NSLayoutConstraint.activate([
                symbol.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
                symbol.centerYAnchor.constraint(equalTo: centerYAnchor),
                symbol.widthAnchor.constraint(equalToConstant: 22),
                title.leadingAnchor.constraint(equalTo: symbol.trailingAnchor, constant: 10),
                title.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
                title.bottomAnchor.constraint(equalTo: centerYAnchor, constant: 1),
                detail.leadingAnchor.constraint(equalTo: title.leadingAnchor),
                detail.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
                detail.topAnchor.constraint(equalTo: centerYAnchor, constant: 2),
            ])
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) 不支持") }

        func show(_ item: QuickOpenItem) {
            symbol.image = NSImage(systemSymbolName: item.symbol, accessibilityDescription: nil)
            title.stringValue = item.title
            detail.stringValue = item.detail
        }
    }
}
