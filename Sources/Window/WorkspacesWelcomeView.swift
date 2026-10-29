import AppKit

/// 启动页「工作区」的视图（纯 AppKit，不碰 App 的单例：数据由 `WorkspacesViewController` 喂进来，
/// 离屏样张 `spike/workspaces-welcome-look.swift` 直接编本文件出图自查）。
///
/// 版式照 macOS 的欢迎窗（Xcode 那种）：左边 App 图标 + 名字 + 版本 + 三个大号标准按钮；右边是侧栏材质上的分段列表
/// （「本机」一段 + 每台服务器一段，用户 2026-10-29 选的「一个列表分段」）。只用标准控件与系统材质（红线③），
/// 文字一律显式 `labelColor`、层级靠字号（红线④）。
@MainActor
final class WorkspacesWelcomeView: NSView, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {

    /// 列表里的一行。
    enum Item {
        case header(String)
        case entry(icon: NSImage, title: String, detail: String)
        case message(String)
    }

    static let size = NSSize(width: 780, height: 480)
    private static let leftWidth: CGFloat = 300

    var items: [Item] = [] {
        didSet {
            let selected = table.selectedRow
            table.reloadData()
            if items.indices.contains(selected), isEntry(selected) {
                table.selectRowIndexes([selected], byExtendingSelection: false)
            }
        }
    }

    var onOpen: (Int) -> Void = { _ in }
    var onNew: () -> Void = {}
    var onOpenExisting: () -> Void = {}
    var onConnect: () -> Void = {}
    /// 右键某一行时的菜单项（标题 + 动作）；空 = 这一行没有右键菜单。
    var contextItems: (Int) -> [(title: String, action: () -> Void)] = { _ in [] }

    private let table = WelcomeTable()
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let spinner = NSProgressIndicator()

    init(appName: String, version: String, icon: NSImage) {
        super.init(frame: NSRect(origin: .zero, size: Self.size))

        // —— 左边：图标、名字、版本、三个按钮、状态 ——
        let iconView = NSImageView(image: icon)
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.widthAnchor.constraint(equalToConstant: 112).isActive = true
        iconView.heightAnchor.constraint(equalToConstant: 112).isActive = true

        let name = NSTextField(labelWithString: appName)
        name.font = .systemFont(ofSize: 30, weight: .bold)
        name.textColor = .labelColor
        let ver = NSTextField(labelWithString: version)
        ver.font = .preferredFont(forTextStyle: .callout)
        ver.textColor = .labelColor

        let buttons = NSStackView(views: [
            Self.bigButton(L("New Workspace…"), "plus.rectangle.on.folder", self, #selector(newTapped)),
            Self.bigButton(L("Open Workspace…"), "folder", self, #selector(openExistingTapped)),
            Self.bigButton(L("Connect to Server…"), "server.rack", self, #selector(connectTapped)),
        ])
        buttons.orientation = .vertical
        buttons.spacing = 10

        statusLabel.font = .preferredFont(forTextStyle: .callout)
        statusLabel.textColor = .labelColor
        statusLabel.alignment = .center
        statusLabel.preferredMaxLayoutWidth = Self.leftWidth - 48
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        let status = NSStackView(views: [spinner, statusLabel])
        status.orientation = .vertical
        status.spacing = 6

        let left = NSStackView(views: [iconView, name, ver, buttons, status])
        left.orientation = .vertical
        left.alignment = .centerX
        left.spacing = 6
        left.setCustomSpacing(14, after: iconView)
        left.setCustomSpacing(28, after: ver)
        left.setCustomSpacing(18, after: buttons)
        left.translatesAutoresizingMaskIntoConstraints = false
        addSubview(left)

        // —— 右边：侧栏材质上的分段列表 ——
        let material = NSVisualEffectView()
        material.material = .sidebar
        material.blendingMode = .behindWindow
        material.state = .followsWindowActiveState
        material.translatesAutoresizingMaskIntoConstraints = false
        addSubview(material)

        let col = NSTableColumn(identifier: .init("ws"))
        table.addTableColumn(col)
        table.headerView = nil
        table.style = .sourceList
        table.backgroundColor = .clear
        table.intercellSpacing = NSSize(width: 0, height: 2)
        table.floatsGroupRows = false   // 浮动的分组行会在第一段标题下画一道线
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(openTapped)
        table.onReturn = { [weak self] in self?.openTapped() }
        let menu = NSMenu()
        menu.delegate = self
        table.menu = menu
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(top: 34, left: 0, bottom: 12, right: 0)   // 让开透明标题栏
        scroll.translatesAutoresizingMaskIntoConstraints = false
        material.addSubview(scroll)

        NSLayoutConstraint.activate([
            left.centerXAnchor.constraint(equalTo: leadingAnchor, constant: Self.leftWidth / 2),
            left.centerYAnchor.constraint(equalTo: centerYAnchor, constant: 6),
            left.widthAnchor.constraint(lessThanOrEqualToConstant: Self.leftWidth - 32),
            buttons.widthAnchor.constraint(equalToConstant: 220),
            material.topAnchor.constraint(equalTo: topAnchor),
            material.bottomAnchor.constraint(equalTo: bottomAnchor),
            material.trailingAnchor.constraint(equalTo: trailingAnchor),
            material.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.leftWidth),
            scroll.topAnchor.constraint(equalTo: material.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: material.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: material.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: material.trailingAnchor),
        ])
        setStatus("", busy: false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) 不支持") }

    /// 底下那行状态（从服务器下载资料库时的进度 / 出错原因）；空串 = 不显示。
    func setStatus(_ text: String, busy: Bool) {
        statusLabel.stringValue = text
        statusLabel.isHidden = text.isEmpty
        if busy { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
    }

    var selectedIndex: Int { table.selectedRow }

    private static func bigButton(_ title: String, _ symbol: String, _ target: AnyObject, _ action: Selector) -> NSButton {
        let b = NSButton(title: title, target: target, action: action)
        b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        b.imagePosition = .imageLeading
        b.controlSize = .large
        b.bezelStyle = .push
        return b
    }

    @objc private func newTapped() { onNew() }
    @objc private func openExistingTapped() { onOpenExisting() }
    @objc private func connectTapped() { onConnect() }
    @objc private func openTapped() {
        let i = table.selectedRow
        if isEntry(i) { onOpen(i) }
    }

    private func isEntry(_ i: Int) -> Bool {
        guard items.indices.contains(i) else { return false }
        if case .entry = items[i] { return true }
        return false
    }

    // MARK: 右键菜单

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let row = table.clickedRow
        guard items.indices.contains(row) else { return }
        for entry in contextItems(row) { menu.addItem(ActionMenuItem(entry.title, entry.action)) }
    }

    // MARK: 表格

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        if case .header = items[row] { return true }
        return false
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { isEntry(row) }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        switch items[row] {
        case .header: return 28
        case .message: return 30
        case .entry: return 46
        }
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch items[row] {
        case .header(let title):
            let cell = NSTableCellView()
            let t = NSTextField(labelWithString: title)
            // 🔴 不交给系统画：侧栏分组标题的系统样式是极淡的灰（红线④），显式 labelColor，层级靠小一号的粗体
            t.font = .systemFont(ofSize: 11, weight: .semibold)
            t.textColor = .labelColor
            t.lineBreakMode = .byTruncatingTail
            t.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(t)
            NSLayoutConstraint.activate([
                t.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                t.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -4),
                t.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            return cell
        case .message(let text):
            let cell = NSTableCellView()
            let t = NSTextField(labelWithString: text)
            t.font = .preferredFont(forTextStyle: .callout)
            t.textColor = .labelColor
            t.lineBreakMode = .byTruncatingTail
            t.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(t)
            NSLayoutConstraint.activate([
                t.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 12),
                t.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -8),
                t.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            return cell
        case .entry(let icon, let title, let detail):
            return EntryCell(icon: icon, title: title, detail: detail)
        }
    }
}

/// 一行工作区：32pt 图标 + 名字 + 一行说明。是 `NSTableCellView`：选中时系统会把 `labelColor` 的字换成反白。
private final class EntryCell: NSTableCellView {
    init(icon: NSImage, title: String, detail: String) {
        super.init(frame: .zero)
        let iv = NSImageView(image: icon)
        iv.imageScaling = .scaleProportionallyUpOrDown
        iv.contentTintColor = .labelColor
        iv.symbolConfiguration = .init(pointSize: 20, weight: .regular)
        let name = NSTextField(labelWithString: title)
        name.font = .systemFont(ofSize: 13, weight: .medium)
        name.textColor = .labelColor
        name.lineBreakMode = .byTruncatingTail
        let sub = NSTextField(labelWithString: detail)
        sub.font = .systemFont(ofSize: 11)
        sub.textColor = .labelColor
        sub.lineBreakMode = .byTruncatingMiddle
        for v in [iv, name, sub] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        imageView = iv
        textField = name
        NSLayoutConstraint.activate([
            iv.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            iv.centerYAnchor.constraint(equalTo: centerYAnchor),
            iv.widthAnchor.constraint(equalToConstant: 32),
            iv.heightAnchor.constraint(equalToConstant: 32),
            name.leadingAnchor.constraint(equalTo: iv.trailingAnchor, constant: 10),
            name.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),
            name.bottomAnchor.constraint(equalTo: centerYAnchor, constant: 1),
            sub.leadingAnchor.constraint(equalTo: name.leadingAnchor),
            sub.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),
            sub.topAnchor.constraint(equalTo: centerYAnchor, constant: 2),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) 不支持") }
}

/// 带闭包的菜单项（本文件自带一份，好让离屏样张只编这一个文件）。
private final class ActionMenuItem: NSMenuItem {
    private let run: () -> Void

    init(_ title: String, _ run: @escaping () -> Void) {
        self.run = run
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError("init(coder:) 不支持") }

    @objc private func fire() { run() }
}

/// 回车 = 打开选中的那一行（表格默认不认回车）。
private final class WelcomeTable: NSTableView {
    var onReturn: () -> Void = {}

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76 { onReturn() } else { super.keyDown(with: event) }
    }
}
