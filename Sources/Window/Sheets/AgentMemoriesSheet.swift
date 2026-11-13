import AppKit

/// 「管理记忆」（`ACP-AGENT-PLAN.md §21`）：列出这个工作区的 Agent 记忆，看 / 改正文、自己加一条、删除（先进回收站）。
/// 从 Agent 页标题行的「上下文」菜单打开。记忆随每段新对话的第一句话自动带给 Agent。
///
/// 全是系统标准控件（红线③）。正文是 Markdown，这里按原文编辑，不渲染。
@MainActor
final class AgentMemoriesSheetController: StackPanelController, NSTableViewDataSource, NSTableViewDelegate, NSTextViewDelegate {
    let workspace: WorkspaceManager

    private var memories: [LibAgentMemory] = []
    private let table = NSTableView()
    private let emptyLabel = NSTextField(labelWithString: L("No memories yet. Agents save what is worth remembering as you chat; you can also add one."))
    private let contentView = NSTextView()
    private let metaLabel = NSTextField(labelWithString: "")
    private var saveButton: NSButton!
    private var deleteButton: NSButton!
    /// 正在编辑的那一条（换选中 / 关窗前改过就先存）；`addingNew` = 正在写一条新的。
    private var editingId: String?
    private var addingNew = false
    private var observer: NSObjectProtocol?
    /// 自己在写库：那一下发出的「记忆变了」不重读（换选中途中重排表格会打乱选中）。
    private var selfWriting = false

    init(workspace: WorkspaceManager) {
        self.workspace = workspace
        super.init(width: 600, inset: 20)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) 不支持") }

    private var inner: CGFloat { width - inset * 2 }

    override func viewDidLoad() {
        super.viewDidLoad()
        stack.spacing = 12
        stack.addArrangedSubview(headline(L("Agent Memories")))
        stack.addArrangedSubview(caption(L("Short facts agents keep for later chats in this workspace. They are attached to the first message of every new chat."), color: .labelColor))

        for id in ["memory", "agent", "when"] {
            let c = NSTableColumn(identifier: .init(id))
            c.title = id == "memory" ? L("Memory") : (id == "agent" ? L("Agent") : L("Updated"))
            c.width = id == "memory" ? 290 : (id == "agent" ? 110 : 140)
            table.addTableColumn(c)
        }
        table.rowHeight = 26
        table.usesAlternatingRowBackgroundColors = true
        table.dataSource = self
        table.delegate = self
        table.allowsMultipleSelection = true
        let tableScroll = NSScrollView()
        tableScroll.documentView = table
        tableScroll.hasVerticalScroller = true
        tableScroll.borderType = .bezelBorder
        stack.addArrangedSubview(SheetKit.fixed(tableScroll, width: inner, height: 200))
        emptyLabel.textColor = .labelColor
        stack.addArrangedSubview(emptyLabel)

        contentView.isRichText = false
        contentView.font = .systemFont(ofSize: NSFont.systemFontSize)
        contentView.isAutomaticQuoteSubstitutionEnabled = false
        contentView.isAutomaticDashSubstitutionEnabled = false
        contentView.allowsUndo = true
        contentView.delegate = self
        contentView.isVerticallyResizable = true
        contentView.autoresizingMask = [.width]
        contentView.textContainerInset = NSSize(width: 4, height: 6)
        let contentScroll = NSScrollView()
        contentScroll.documentView = contentView
        contentScroll.hasVerticalScroller = true
        contentScroll.borderType = .bezelBorder
        stack.addArrangedSubview(SheetKit.fixed(contentScroll, width: inner, height: 120))
        metaLabel.font = .preferredFont(forTextStyle: .callout)
        metaLabel.textColor = .labelColor
        metaLabel.lineBreakMode = .byTruncatingTail
        stack.addArrangedSubview(SheetKit.fixed(metaLabel, width: inner))

        deleteButton = NSButton(title: L("Delete…"), target: self, action: #selector(deleteSelected))
        let addButton = NSButton(title: L("New Memory"), target: self, action: #selector(addNew))
        saveButton = NSButton(title: L("Save Changes"), target: self, action: #selector(saveEdits))
        stack.addArrangedSubview(row([deleteButton, spacer(), addButton, saveButton]))

        let close = NSButton(title: L("Done"), target: self, action: #selector(close))
        close.keyEquivalent = "\u{1b}"
        close.bezelStyle = .push
        close.controlSize = .large
        stack.addArrangedSubview(row([SheetKit.spacer(), close]))

        // 别处改了（Agent 经 MCP 记了一条、同步拉下来、回收站放回）→ 下一拍重读；自己在编辑的那条不打断。
        observer = NotificationCenter.default.addObserver(forName: .agentMemoriesDidChange, object: workspace,
                                                          queue: nil) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.selfWriting else { return }
                DispatchQueue.main.async { [weak self] in self?.reload() }
            }
        }
        reload()
    }

    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

    private func reload() {
        let keep = Set(selected.map(\.id))
        memories = workspace.agentMemories
        table.reloadData()
        let rows = IndexSet(memories.indices.filter { keep.contains(memories[$0].id) })
        if !rows.isEmpty { table.selectRowIndexes(rows, byExtendingSelection: false) }
        else if !memories.isEmpty, editingId == nil, !addingNew { table.selectRowIndexes([0], byExtendingSelection: false) }
        emptyLabel.isHidden = !memories.isEmpty
        showSelection()
        resize()
    }

    private var selected: [LibAgentMemory] {
        table.selectedRowIndexes.compactMap { memories.indices.contains($0) ? memories[$0] : nil }
    }

    /// 选中一条 = 下面显示它的正文（可改）；在写新的 = 下面空着可写；选中几条 / 没选 = 不可编辑。
    private func showSelection() {
        if addingNew {
            contentView.isEditable = true
            metaLabel.stringValue = L("New memory")
            updateButtons()
            return
        }
        let sel = selected
        let one = sel.count == 1 ? sel[0] : nil
        if one?.id != editingId || one == nil {
            editingId = one?.id
            contentView.string = one?.content ?? ""
        }
        contentView.isEditable = one != nil
        if let m = one {
            let when = m.updatedAt.formatted(date: .abbreviated, time: .shortened)
            metaLabel.stringValue = m.agent.isEmpty ? when : String(format: L("Written by %@ · %@"), m.agent, when)
        } else {
            metaLabel.stringValue = sel.count > 1 ? String(format: L("%d selected"), sel.count) : ""
        }
        updateButtons()
    }

    private var dirty: Bool {
        let text = contentView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        if addingNew { return !text.isEmpty }
        guard let id = editingId, let m = memories.first(where: { $0.id == id }) else { return false }
        return text != m.content
    }

    private func updateButtons() {
        deleteButton.isEnabled = !selected.isEmpty && !addingNew
        saveButton.isEnabled = dirty
    }

    func textDidChange(_ notification: Notification) { updateButtons() }

    // MARK: 动作

    @objc private func addNew() {
        guard commitEdits() else { return }
        addingNew = true
        editingId = nil
        table.deselectAll(nil)
        contentView.string = ""
        showSelection()
        view.window?.makeFirstResponder(contentView)
    }

    @objc private func saveEdits() {
        guard commitEdits() else { return }
        editingId = nil
        reload()
    }

    /// 把正在编辑 / 新写的那条写进库，**不碰表格**（换选中途中也调它）。返回 false = 没存成。
    @discardableResult
    private func commitEdits() -> Bool {
        guard dirty else {
            if addingNew { addingNew = false }
            return true
        }
        selfWriting = true
        defer { selfWriting = false }
        if addingNew {
            guard workspace.addAgentMemory(content: contentView.string, agent: "") != nil else {
                report(workspace.lastError ?? L("Could not save the memory."))
                return false
            }
            addingNew = false
            return true
        }
        guard let id = editingId else { return true }
        guard let saved = workspace.updateAgentMemory(id: id, content: contentView.string) else {
            report(workspace.lastError ?? L("Could not save the memory."))
            return false
        }
        if let i = memories.firstIndex(where: { $0.id == id }) {
            memories[i] = saved
            table.reloadData(forRowIndexes: [i], columnIndexes: IndexSet(integersIn: 0..<table.numberOfColumns))
        }
        return true
    }

    @objc private func deleteSelected() {
        let sel = selected
        guard !sel.isEmpty else { return }
        let a = NSAlert()
        a.messageText = sel.count == 1 ? String(format: L("Delete the memory “%@”?"), AgentMemoryText.title(sel[0].content))
                                       : String(format: L("Delete %d memories?"), sel.count)
        a.informativeText = L("It moves to Recently Deleted, where you can put it back.")
        a.addButton(withTitle: L("Delete")).hasDestructiveAction = true
        a.addButton(withTitle: L("Cancel"))
        let go: (NSApplication.ModalResponse) -> Void = { [weak self] r in
            guard let self, r == .alertFirstButtonReturn else { return }
            self.selfWriting = true
            let ok = self.workspace.trashAgentMemories(ids: sel.map(\.id))
            self.selfWriting = false
            if !ok { self.report(self.workspace.lastError ?? L("Could not delete the memory.")) }
            self.editingId = nil
            self.reload()
        }
        if let win = view.window { a.beginSheetModal(for: win, completionHandler: go) } else { go(a.runModal()) }
    }

    @objc private func close() {
        guard commitEdits() else { return }
        dismiss(nil)
    }

    private func report(_ message: String) {
        let a = NSAlert()
        a.messageText = message
        a.addButton(withTitle: L("OK"))
        if let win = view.window { a.beginSheetModal(for: win) } else { a.runModal() }
    }

    // MARK: 表格

    func numberOfRows(in tableView: NSTableView) -> Int { memories.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard memories.indices.contains(row), let col = tableColumn?.identifier.rawValue else { return nil }
        let m = memories[row]
        let text: String
        switch col {
        case "memory": text = AgentMemoryText.title(m.content)
        case "agent": text = m.agent
        default: text = m.updatedAt.formatted(date: .abbreviated, time: .shortened)
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
        v.toolTip = col == "memory" ? String(m.content.prefix(400)) : nil
        return v
    }

    /// 换选中之前：正在编辑的那条改过就先存下（「写了就存」）。
    func selectionShouldChange(in tableView: NSTableView) -> Bool { commitEdits() }

    func tableViewSelectionDidChange(_ notification: Notification) {
        if !table.selectedRowIndexes.isEmpty { addingNew = false }
        showSelection()
    }
}
