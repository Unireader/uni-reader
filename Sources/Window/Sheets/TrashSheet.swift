import AppKit

/// 回收站面板（方案 `BACKUP-PLAN.md §2.7`）：列出被删掉的文档 / 图层，逐条恢复、彻底删除、清空。
///
/// 全是系统标准控件，没有自绘的仿系统样式（红线）。
@MainActor
final class TrashSheetController: StackPanelController, NSTableViewDataSource, NSTableViewDelegate {
    let workspace: WorkspaceManager
    var onDismiss: () -> Void = {}

    private var entries: [Trash.Entry] = []
    private let table = NSTableView()
    private let emptyLabel = NSTextField(labelWithString: L("Nothing has been deleted recently."))
    private let summaryLabel = NSTextField(labelWithString: "")
    private var restoreButton: NSButton!
    private var purgeButton: NSButton!
    private var emptyButton: NSButton!
    private var retentionPopup: NSPopUpButton!

    init(workspace: WorkspaceManager) {
        self.workspace = workspace
        super.init(width: 520, inset: 20)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) 不支持") }

    private var inner: CGFloat { width - inset * 2 }

    override func viewDidLoad() {
        super.viewDidLoad()
        stack.spacing = 12
        stack.addArrangedSubview(headline(L("Recently Deleted")))
        stack.addArrangedSubview(caption(L("Deleted documents and ink layers are kept here with all of their notes. Nothing else in the workspace is touched — the PDF files themselves are never deleted.")))

        for id in ["item", "kind", "when", "size"] {
            let c = NSTableColumn(identifier: .init(id))
            c.title = columnTitle(id)
            c.width = id == "item" ? 220 : (id == "when" ? 130 : 70)
            table.addTableColumn(c)
        }
        table.rowHeight = 32
        table.usesAlternatingRowBackgroundColors = true
        table.dataSource = self
        table.delegate = self
        table.allowsMultipleSelection = true
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        stack.addArrangedSubview(SheetKit.fixed(scroll, width: inner, height: 260))

        emptyLabel.textColor = .secondaryLabelColor
        stack.addArrangedSubview(emptyLabel)

        summaryLabel.font = .preferredFont(forTextStyle: .callout)
        summaryLabel.textColor = .secondaryLabelColor
        summaryLabel.lineBreakMode = .byTruncatingTail
        stack.addArrangedSubview(SheetKit.fixed(summaryLabel, width: inner))

        retentionPopup = NSPopUpButton()
        retentionPopup.addItems(withTitles: [L("Keep for 30 days"), L("Keep for 90 days"), L("Keep forever")])
        retentionPopup.selectItem(at: [Trash.Retention.days30, .days90, .forever]
            .firstIndex(of: WorkspaceManager.trashRetention) ?? 0)
        retentionPopup.target = self
        retentionPopup.action = #selector(retentionChanged)

        restoreButton = NSButton(title: L("Put Back"), target: self, action: #selector(restore))
        purgeButton = NSButton(title: L("Delete Permanently"), target: self, action: #selector(purge))
        emptyButton = NSButton(title: L("Delete All"), target: self, action: #selector(emptyAll))
        stack.addArrangedSubview(row([retentionPopup, spacer(), emptyButton, purgeButton, restoreButton]))

        let close = NSButton(title: L("Done"), target: self, action: #selector(close))
        close.keyEquivalent = "\r"
        close.bezelStyle = .push
        close.controlSize = .large
        stack.addArrangedSubview(row([SheetKit.spacer(), close]))

        reload()
    }

    private func columnTitle(_ id: String) -> String {
        switch id {
        case "item": return L("Item")
        case "kind": return L("Kind")
        case "when": return L("Deleted")
        default: return L("Size")
        }
    }

    private func reload() {
        entries = workspace.trashEntries
        table.reloadData()
        emptyLabel.isHidden = !entries.isEmpty
        updateButtons()
        resize()
    }

    private var selected: [Trash.Entry] {
        table.selectedRowIndexes.compactMap { entries.indices.contains($0) ? entries[$0] : nil }
    }

    private func updateButtons() {
        let sel = selected
        restoreButton.isEnabled = !sel.isEmpty
        purgeButton.isEnabled = !sel.isEmpty
        emptyButton.isEnabled = !entries.isEmpty
        summaryLabel.stringValue = sel.count == 1 ? describe(sel[0]) : ""
    }

    /// 选中那条的详情：里面有什么，以及恢复时会不会**并入**现有的某篇（方案 §2.5 情形 B）。
    private func describe(_ e: Trash.Entry) -> String {
        var parts: [String] = []
        let c = e.manifest.counts
        func add(_ n: Int, _ fmt: String) { if n > 0 { parts.append(String(format: L(fmt), n)) } }
        add(c.ink, "%d stroke(s)")
        add(c.text, "%d note(s)")
        add(c.highlight, "%d highlight(s)")
        add(c.bookmark, "%d bookmark(s)")
        add(c.image, "%d image note(s)")
        add(c.scratchInk, "%d scratch stroke(s)")
        var s = parts.isEmpty ? L("Nothing inside.") : parts.joined(separator: "、")
        if let target = workspace.trashMergeTarget(e) {
            s += "\n" + String(format: L("“%@” was imported again — putting this back will merge the notes into that document."), target.title)
        }
        return s
    }

    // MARK: 动作

    @objc private func retentionChanged() {
        WorkspaceManager.trashRetention = [Trash.Retention.days30, .days90, .forever][retentionPopup.indexOfSelectedItem]
    }

    @objc private func restore() {
        let sel = selected
        guard !sel.isEmpty else { return }
        var failed: [String] = []
        for e in sel where !workspace.restoreFromTrash(e) { failed.append(e.manifest.title) }
        if !failed.isEmpty { report(L("Could not put these back:"), failed) }
        reload()
    }

    @objc private func purge() {
        let sel = selected
        guard !sel.isEmpty else { return }
        confirm(message: sel.count == 1
                    ? String(format: L("Delete “%@” permanently?"), sel[0].manifest.title)
                    : String(format: L("Delete %d items permanently?"), sel.count),
                info: L("This cannot be undone."),
                button: L("Delete Permanently")) { [weak self] in
            guard let self else { return }
            for e in sel { self.workspace.purgeTrash(e) }
            self.reload()
        }
    }

    @objc private func emptyAll() {
        guard !entries.isEmpty else { return }
        confirm(message: String(format: L("Delete all %d items permanently?"), entries.count),
                info: L("This cannot be undone."),
                button: L("Delete All")) { [weak self] in
            guard let self else { return }
            self.workspace.emptyTrash()
            self.reload()
        }
    }

    @objc private func close() {
        onDismiss()
        dismiss(nil)
    }

    private func confirm(message: String, info: String, button: String, _ go: @escaping () -> Void) {
        let a = NSAlert()
        a.messageText = message
        a.informativeText = info
        a.addButton(withTitle: button).hasDestructiveAction = true
        a.addButton(withTitle: L("Cancel"))
        let finish: (NSApplication.ModalResponse) -> Void = { if $0 == .alertFirstButtonReturn { go() } }
        if let win = view.window { a.beginSheetModal(for: win, completionHandler: finish) } else { finish(a.runModal()) }
    }

    private func report(_ message: String, _ names: [String]) {
        let a = NSAlert()
        a.messageText = message
        a.informativeText = names.joined(separator: "\n")
        a.addButton(withTitle: L("OK"))
        if let win = view.window { a.beginSheetModal(for: win) } else { a.runModal() }
    }

    // MARK: 表格

    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard entries.indices.contains(row), let col = tableColumn?.identifier.rawValue else { return nil }
        let e = entries[row]
        let text: String
        switch col {
        case "item":
            text = e.manifest.kind == .inkLayer && !e.manifest.documentTitle.isEmpty
                ? "\(e.manifest.title) — \(e.manifest.documentTitle)"
                : e.manifest.title
        case "kind":
            text = e.manifest.kind == .document ? L("Document") : L("Ink Layer")
        case "when":
            text = e.deletedAt == .distantPast
                ? "—"
                : e.deletedAt.formatted(date: .abbreviated, time: .shortened)
        default:
            text = ByteCountFormatter.string(fromByteCount: e.bytes, countStyle: .file)
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
