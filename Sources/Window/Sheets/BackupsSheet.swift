import AppKit

/// 工作区备份面板（方案 `BACKUP-PLAN.md §3.5`）：列出快照、立即备份、还原、在 Finder 中显示、删除。
@MainActor
final class BackupsSheetController: StackPanelController, NSTableViewDataSource, NSTableViewDelegate {
    let workspace: WorkspaceManager
    var onDismiss: () -> Void = {}

    private var items: [BackupService.Item] = []
    private let table = NSTableView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let enabledBox = NSButton(checkboxWithTitle: L("Back up the library automatically"), target: nil, action: nil)
    private var intervalPopup: NSPopUpButton!
    private var backupButton: NSButton!
    private var restoreButton: NSButton!
    private var revealButton: NSButton!
    private var deleteButton: NSButton!
    private var running = false

    private static let intervals = [1, 6, 12, 24]

    init(workspace: WorkspaceManager) {
        self.workspace = workspace
        super.init(width: 520, inset: 20)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) 不支持") }

    private var inner: CGFloat { width - inset * 2 }

    override func viewDidLoad() {
        super.viewDidLoad()
        stack.spacing = 12
        stack.addArrangedSubview(headline(L("Workspace Backups")))
        stack.addArrangedSubview(caption(L("A consistent snapshot of library.sqlite — every stroke, note, highlight, bookmark and scratch pad. It lives inside the workspace, so it travels with it. PDFs are not copied.")))

        enabledBox.state = BackupService.enabled ? .on : .off
        enabledBox.target = self
        enabledBox.action = #selector(toggleEnabled)
        intervalPopup = NSPopUpButton()
        for h in Self.intervals {
            intervalPopup.addItem(withTitle: h == 1 ? L("Every hour") : String(format: L("Every %d hours"), h))
        }
        intervalPopup.selectItem(at: Self.intervals.firstIndex(of: BackupService.intervalHours) ?? 1)
        intervalPopup.target = self
        intervalPopup.action = #selector(intervalChanged)
        stack.addArrangedSubview(row([enabledBox, spacer(), intervalPopup]))

        for id in ["when", "size", "note"] {
            let c = NSTableColumn(identifier: .init(id))
            c.title = id == "when" ? L("Taken") : (id == "size" ? L("Size") : L("Note"))
            c.width = id == "when" ? 190 : (id == "size" ? 80 : 160)
            table.addTableColumn(c)
        }
        table.rowHeight = 28
        table.usesAlternatingRowBackgroundColors = true
        table.dataSource = self
        table.delegate = self
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        stack.addArrangedSubview(SheetKit.fixed(scroll, width: inner, height: 240))

        statusLabel.font = .preferredFont(forTextStyle: .callout)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        stack.addArrangedSubview(SheetKit.fixed(statusLabel, width: inner))

        backupButton = NSButton(title: L("Back Up Now"), target: self, action: #selector(backupNow))
        restoreButton = NSButton(title: L("Restore…"), target: self, action: #selector(restore))
        revealButton = NSButton(title: L("Show in Finder"), target: self, action: #selector(reveal))
        deleteButton = NSButton(title: L("Delete"), target: self, action: #selector(deleteOne))
        stack.addArrangedSubview(row([backupButton, spacer(), revealButton, deleteButton, restoreButton]))

        let close = NSButton(title: L("Done"), target: self, action: #selector(close))
        close.keyEquivalent = "\r"
        close.bezelStyle = .push
        close.controlSize = .large
        stack.addArrangedSubview(row([SheetKit.spacer(), close]))

        reload()
    }

    private func reload() {
        items = workspace.folder.map { BackupService.items(in: $0) } ?? []
        table.reloadData()
        let total = items.reduce(Int64(0)) { $0 + $1.bytes }
        statusLabel.stringValue = items.isEmpty
            ? L("No backups yet.")
            : String(format: L("%d backups, %@ in total. Kept: the 5 most recent, one a day for a week, one a week for a month."),
                     items.count, ByteCountFormatter.string(fromByteCount: total, countStyle: .file))
        updateButtons()
        resize()
    }

    private var selected: BackupService.Item? {
        let r = table.selectedRow
        return items.indices.contains(r) ? items[r] : nil
    }

    private func updateButtons() {
        let has = selected != nil
        restoreButton.isEnabled = has && !running
        revealButton.isEnabled = has
        deleteButton.isEnabled = has
        backupButton.isEnabled = !running
        intervalPopup.isEnabled = BackupService.enabled
    }

    // MARK: 动作

    @objc private func toggleEnabled() {
        BackupService.enabled = enabledBox.state == .on
        updateButtons()
    }

    @objc private func intervalChanged() {
        BackupService.intervalHours = Self.intervals[intervalPopup.indexOfSelectedItem]
    }

    @objc private func backupNow() {
        running = true
        updateButtons()
        statusLabel.stringValue = L("Backing up…")
        BackupService.shared.runInBackground(workspace, force: true) { [weak self] out in
            guard let self else { return }
            self.running = false
            if case .failed(let e) = out { self.statusLabel.stringValue = "\(e)" ; self.updateButtons(); return }
            self.reload()
        }
    }

    @objc private func reveal() {
        guard let item = selected else { return }
        NSWorkspace.shared.activateFileViewerSelecting([item.url])
    }

    @objc private func deleteOne() {
        guard let item = selected else { return }
        let a = NSAlert()
        a.messageText = String(format: L("Delete the backup from %@?"),
                               item.date.formatted(date: .abbreviated, time: .shortened))
        a.addButton(withTitle: L("Delete")).hasDestructiveAction = true
        a.addButton(withTitle: L("Cancel"))
        let finish: (NSApplication.ModalResponse) -> Void = { [weak self] r in
            guard let self, r == .alertFirstButtonReturn else { return }
            try? FileManager.default.removeItem(at: item.url)
            self.reload()
        }
        if let win = view.window { a.beginSheetModal(for: win, completionHandler: finish) } else { finish(a.runModal()) }
    }

    /// 还原。说清楚会发生什么（**整库退回** + **App 会退出**），别让人以为只是「恢复几条笔记」。
    @objc private func restore() {
        guard let item = selected else { return }
        let a = NSAlert()
        a.messageText = String(format: L("Restore the library to %@?"),
                               item.date.formatted(date: .abbreviated, time: .shortened))
        a.informativeText = [
            L("Everything written since then — strokes, notes, highlights, reading positions — goes back to how it was at that moment."),
            L("The current library is saved as a restore point first, so this itself can be undone."),
            L("UniReader will quit afterwards. Open the workspace again to continue."),
        ].joined(separator: "\n\n")
        a.addButton(withTitle: L("Restore and Quit")).hasDestructiveAction = true
        a.addButton(withTitle: L("Cancel"))
        let finish: (NSApplication.ModalResponse) -> Void = { [weak self] r in
            guard let self, r == .alertFirstButtonReturn else { return }
            do { try BackupService.shared.restore(item, into: self.workspace) }
            catch {
                let e = NSAlert(error: error)
                if let win = self.view.window { e.beginSheetModal(for: win) } else { e.runModal() }
            }
        }
        if let win = view.window { a.beginSheetModal(for: win, completionHandler: finish) } else { finish(a.runModal()) }
    }

    @objc private func close() {
        onDismiss()
        dismiss(nil)
    }

    // MARK: 表格

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard items.indices.contains(row), let col = tableColumn?.identifier.rawValue else { return nil }
        let it = items[row]
        let text: String
        switch col {
        case "when": text = it.date.formatted(date: .abbreviated, time: .standard)
        case "size": text = ByteCountFormatter.string(fromByteCount: it.bytes, countStyle: .file)
        default: text = it.isRestorePoint ? L("Restore point") : ""
        }
        let id = NSUserInterfaceItemIdentifier("cell.\(col)")
        let v = (tableView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView) ?? {
            let cell = NSTableCellView()
            let f = NSTextField(labelWithString: "")
            f.lineBreakMode = .byTruncatingTail
            f.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(f)
            cell.textField = f
            NSLayoutConstraint.activate([
                f.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                f.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
                f.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            cell.identifier = id
            return cell
        }()
        v.textField?.stringValue = text
        return v
    }

    func tableViewSelectionDidChange(_ notification: Notification) { updateButtons() }
}
