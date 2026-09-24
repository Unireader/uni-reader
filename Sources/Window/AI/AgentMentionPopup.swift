import AppKit
import UniformTypeIdentifiers

/// Agent 输入框里 `@` 的候选列表（`ACP-AGENT-PLAN.md §8`）：贴着 `@` 浮在输入框上方，随输入过滤。
///
/// 做成**不会变成 key 的子窗口**，而不是 `NSPopover`：焦点必须一直留在输入框里（接着打字、组字），
/// ↑↓ / 回车 / Tab / Esc 由输入框截下来转给这里（`AgentComposerView.handleMentionKey`）。
/// 外观全用系统件：菜单材质 + `.inset` 表格的系统选中样式 + 系统文件图标。
@MainActor
final class AgentMentionPopup: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private let panel: Panel
    private let table = FirstClickTableView()
    private let scroll = NSScrollView()
    private(set) var items: [AgentMention] = []
    var onPick: (AgentMention) -> Void = { _ in }

    private static let rowHeight: CGFloat = 36
    private static let width: CGFloat = 340
    private static let maxRows = 8

    /// 不抢焦点的浮窗。
    private final class Panel: NSPanel {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }

    /// 窗口不是 key，第一下点击也要算数（否则要点两下才选得中）。
    private final class FirstClickTableView: NSTableView {
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    }

    /// 窗口永远不是 key，系统会把选中行画成灰的「非活动」样式；这里始终按活动样式画。
    private final class RowView: NSTableRowView {
        override var isEmphasized: Bool { get { true } set {} }
    }

    override init() {
        panel = Panel(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 100),
                      styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        super.init()
        panel.isReleasedWhenClosed = false
        panel.hasShadow = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.becomesKeyOnlyIfNeeded = true

        let effect = NSVisualEffectView()
        effect.material = .menu
        effect.state = .active
        effect.blendingMode = .behindWindow
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 10
        effect.layer?.cornerCurve = .continuous
        effect.layer?.masksToBounds = true
        panel.contentView = effect

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
        scroll.autoresizingMask = [.width, .height]
        scroll.frame = effect.bounds
        effect.addSubview(scroll)
    }

    var isShown: Bool { panel.isVisible }

    var selectedItem: AgentMention? {
        items.indices.contains(table.selectedRow) ? items[table.selectedRow] : nil
    }

    /// 显示 / 更新。`anchor` = `@` 那一处的屏幕矩形（`firstRect(forCharacterRange:)`）。
    /// 默认摆在它上方（输入框在面板最底下），上方放不下才放下方。
    func show(_ list: [AgentMention], anchor: NSRect, parent: NSWindow) {
        let changed = list.map(\.id) != items.map(\.id)
        items = list
        if changed {
            table.reloadData()
            table.selectRowIndexes([0], byExtendingSelection: false)
            table.scrollRowToVisible(0)
        }
        let rows = min(list.count, Self.maxRows)
        // `.inset` 样式上下各留一点边
        let h = CGFloat(rows) * Self.rowHeight + 12
        var origin = NSPoint(x: anchor.minX - 12, y: anchor.maxY + 4)
        if let screen = (parent.screen ?? NSScreen.main)?.visibleFrame {
            if origin.y + h > screen.maxY { origin.y = anchor.minY - 4 - h }
            origin.x = min(max(origin.x, screen.minX + 4), screen.maxX - Self.width - 4)
        }
        panel.setFrame(NSRect(x: origin.x, y: origin.y, width: Self.width, height: h), display: true)
        if panel.parent !== parent {
            panel.parent?.removeChildWindow(panel)
            parent.addChildWindow(panel, ordered: .above)
        }
        if !panel.isVisible { panel.orderFront(nil) }
    }

    func hide() {
        guard panel.isVisible || panel.parent != nil else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }

    /// ↑ / ↓：循环移动选中行。
    func move(_ delta: Int) {
        guard !items.isEmpty else { return }
        let cur = max(0, table.selectedRow)
        let next = ((cur + delta) % items.count + items.count) % items.count
        table.selectRowIndexes([next], byExtendingSelection: false)
        table.scrollRowToVisible(next)
    }

    @objc private func clicked() {
        guard items.indices.contains(table.clickedRow) else { return }
        onPick(items[table.clickedRow])
    }

    // MARK: 表格

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { RowView() }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = (tableView.makeView(withIdentifier: Cell.id, owner: nil) as? Cell) ?? Cell()
        cell.show(items[row])
        return cell
    }

    /// 一行：文件图标 + 文件名，下面一行小字（书名 / 所在目录）。
    /// 🔴 材质底上的文字一律 `labelColor`，层级差别用字号表达（红线，见 AGENTS.md）。
    private final class Cell: NSTableCellView {
        static let id = NSUserInterfaceItemIdentifier("mention")
        private let icon = NSImageView()
        private let name = NSTextField(labelWithString: "")
        private let detail = NSTextField(labelWithString: "")

        private static let pdfIcon = NSWorkspace.shared.icon(for: .pdf)
        private static let noteIcon = NSWorkspace.shared.icon(for: UTType(filenameExtension: "md") ?? .plainText)

        init() {
            super.init(frame: .zero)
            identifier = Self.id
            name.font = .systemFont(ofSize: NSFont.systemFontSize)
            name.textColor = .labelColor
            name.lineBreakMode = .byTruncatingMiddle
            detail.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            detail.textColor = .labelColor
            detail.lineBreakMode = .byTruncatingMiddle
            for v in [icon, name, detail] as [NSView] {
                v.translatesAutoresizingMaskIntoConstraints = false
                addSubview(v)
            }
            imageView = icon
            textField = name
            NSLayoutConstraint.activate([
                icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
                icon.centerYAnchor.constraint(equalTo: centerYAnchor),
                icon.widthAnchor.constraint(equalToConstant: 24),
                icon.heightAnchor.constraint(equalToConstant: 24),
                name.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
                name.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4),
                detail.leadingAnchor.constraint(equalTo: name.leadingAnchor),
                detail.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4),
            ])
            nameCenter = name.centerYAnchor.constraint(equalTo: centerYAnchor)
            nameTop = name.bottomAnchor.constraint(equalTo: centerYAnchor, constant: 1)
            detailTop = detail.topAnchor.constraint(equalTo: centerYAnchor, constant: 1)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) 不支持") }

        private var nameCenter: NSLayoutConstraint!
        private var nameTop: NSLayoutConstraint!
        private var detailTop: NSLayoutConstraint!

        func show(_ m: AgentMention) {
            icon.image = m.kind == .pdf ? Self.pdfIcon : Self.noteIcon
            name.stringValue = m.name
            detail.stringValue = m.detail
            let two = !m.detail.isEmpty
            detail.isHidden = !two
            // 没有第二行就把文件名放在正中
            nameCenter.isActive = !two
            nameTop.isActive = two
            detailTop.isActive = two
        }
    }
}
