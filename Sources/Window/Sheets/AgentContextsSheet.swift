import AppKit

/// 「管理上下文」（`ACP-AGENT-PLAN.md §12`）：列出这个工作区存下的 Agent 上下文，看 / 改标题与摘要、删除（先进回收站）、
/// 带到这段对话里。从 Agent 页标题行的「上下文」菜单打开。
///
/// 全是系统标准控件（红线③）。摘要是 Agent 写的 Markdown，这里按原文编辑（等宽字体），不渲染。
@MainActor
final class AgentContextsSheetController: StackPanelController, NSTableViewDataSource, NSTableViewDelegate, NSTextViewDelegate, NSTextFieldDelegate {
    let workspace: WorkspaceManager
    /// 「带到这段对话」：挂到输入框上（宿主接 `AgentChat.attachContext`）。
    var onAttach: (LibAgentContext) -> Void = { _ in }

    private var contexts: [LibAgentContext] = []
    private let table = NSTableView()
    private let emptyLabel = NSTextField(labelWithString: L("No contexts saved yet. In a chat, choose Save This Chat as a Context."))
    private let titleField = NSTextField()
    private let summaryView = NSTextView()
    private let metaLabel = NSTextField(labelWithString: "")
    private var saveButton: NSButton!
    private var deleteButton: NSButton!
    private var attachButton: NSButton!
    /// 正在编辑的那一份（换选中 / 关窗前改过就先存）。
    private var editingId: String?
    private var observer: NSObjectProtocol?
    /// 自己在写库：那一下发出的「上下文变了」不重读（换选中途中重排表格会打乱选中）。
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
        stack.addArrangedSubview(headline(L("Agent Contexts")))
        stack.addArrangedSubview(caption(L("Summaries of earlier Agent chats, saved in this workspace. Attach one in a new chat with any agent and it can carry on from there."), color: .labelColor))

        for id in ["title", "agent", "when"] {
            let c = NSTableColumn(identifier: .init(id))
            c.title = id == "title" ? L("Title") : (id == "agent" ? L("Agent") : L("Updated"))
            c.width = id == "title" ? 290 : (id == "agent" ? 110 : 140)
            table.addTableColumn(c)
        }
        table.rowHeight = 26
        table.usesAlternatingRowBackgroundColors = true
        table.dataSource = self
        table.delegate = self
        table.allowsMultipleSelection = true
        table.target = self
        table.doubleAction = #selector(attach)
        let tableScroll = NSScrollView()
        tableScroll.documentView = table
        tableScroll.hasVerticalScroller = true
        tableScroll.borderType = .bezelBorder
        stack.addArrangedSubview(SheetKit.fixed(tableScroll, width: inner, height: 170))
        emptyLabel.textColor = .labelColor
        stack.addArrangedSubview(emptyLabel)

        titleField.placeholderString = L("Title")
        titleField.delegate = self
        stack.addArrangedSubview(SheetKit.fixed(titleField, width: inner))
        summaryView.isRichText = false
        summaryView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        summaryView.isAutomaticQuoteSubstitutionEnabled = false
        summaryView.isAutomaticDashSubstitutionEnabled = false
        summaryView.allowsUndo = true
        summaryView.delegate = self
        summaryView.isVerticallyResizable = true
        summaryView.autoresizingMask = [.width]
        summaryView.textContainerInset = NSSize(width: 4, height: 6)
        let summaryScroll = NSScrollView()
        summaryScroll.documentView = summaryView
        summaryScroll.hasVerticalScroller = true
        summaryScroll.borderType = .bezelBorder
        stack.addArrangedSubview(SheetKit.fixed(summaryScroll, width: inner, height: 240))
        metaLabel.font = .preferredFont(forTextStyle: .callout)
        metaLabel.textColor = .labelColor
        metaLabel.lineBreakMode = .byTruncatingTail
        stack.addArrangedSubview(SheetKit.fixed(metaLabel, width: inner))

        deleteButton = NSButton(title: L("Delete…"), target: self, action: #selector(deleteSelected))
        saveButton = NSButton(title: L("Save Changes"), target: self, action: #selector(saveEdits))
        attachButton = NSButton(title: L("Attach to This Chat"), target: self, action: #selector(attach))
        stack.addArrangedSubview(row([deleteButton, spacer(), saveButton, attachButton]))

        let close = NSButton(title: L("Done"), target: self, action: #selector(close))
        close.keyEquivalent = "\u{1b}"
        close.bezelStyle = .push
        close.controlSize = .large
        stack.addArrangedSubview(row([SheetKit.spacer(), close]))

        // 别处改了（同步拉下来、MCP 存了一份、回收站放回）→ 下一拍重读；自己在编辑的那份不打断（`showSelection`）。
        // 发通知的一定是主线程（`WorkspaceManager` 在主线程），`queue: nil` = 当场在发的线程上跑，好认出是不是自己写的
        observer = NotificationCenter.default.addObserver(forName: .agentContextsDidChange, object: workspace,
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
        contexts = workspace.agentContexts
        table.reloadData()
        let rows = IndexSet(contexts.indices.filter { keep.contains(contexts[$0].id) })
        if !rows.isEmpty { table.selectRowIndexes(rows, byExtendingSelection: false) }
        else if !contexts.isEmpty, editingId == nil { table.selectRowIndexes([0], byExtendingSelection: false) }
        emptyLabel.isHidden = !contexts.isEmpty
        showSelection()
        resize()
    }

    private var selected: [LibAgentContext] {
        table.selectedRowIndexes.compactMap { contexts.indices.contains($0) ? contexts[$0] : nil }
    }

    /// 选中一份 = 下面显示它的标题与摘要（可改）；选中几份 / 没选 = 下面空着、不可编辑。
    private func showSelection() {
        let sel = selected
        let one = sel.count == 1 ? sel[0] : nil
        if one?.id != editingId || one == nil {
            editingId = one?.id
            titleField.stringValue = one?.title ?? ""
            summaryView.string = one?.summary ?? ""
        }
        titleField.isEnabled = one != nil
        summaryView.isEditable = one != nil
        if let c = one {
            let when = c.updatedAt.formatted(date: .abbreviated, time: .shortened)
            metaLabel.stringValue = c.agent.isEmpty ? when : String(format: L("Written by %@ · %@"), c.agent, when)
        } else {
            metaLabel.stringValue = sel.count > 1 ? String(format: L("%d selected"), sel.count) : ""
        }
        updateButtons()
    }

    private var dirty: Bool {
        guard let id = editingId, let c = contexts.first(where: { $0.id == id }) else { return false }
        return titleField.stringValue != c.title || summaryView.string != c.summary
    }

    private func updateButtons() {
        let sel = selected
        deleteButton.isEnabled = !sel.isEmpty
        attachButton.isEnabled = sel.count == 1
        saveButton.isEnabled = dirty
    }

    func textDidChange(_ notification: Notification) { updateButtons() }
    func controlTextDidChange(_ obj: Notification) { updateButtons() }

    // MARK: 动作

    /// 「保存修改」：写库，再按库里存下的样子重填（标题会被规整）、重排（改过的排到最前）。
    @objc private func saveEdits() {
        guard commitEdits() else { return }
        editingId = nil
        reload()
    }

    /// 把正在编辑的那份写进库，**不碰表格**（换选中途中也调它）。标题空着不存（响一声）。返回 false = 没存成。
    @discardableResult
    private func commitEdits() -> Bool {
        guard dirty, let id = editingId else { return true }
        let title = titleField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { NSSound.beep(); return false }
        selfWriting = true
        let saved = workspace.updateAgentContext(id: id, title: title, summary: summaryView.string)
        selfWriting = false
        guard let saved else {
            report(workspace.lastError ?? L("Could not save the context."))
            return false
        }
        if let i = contexts.firstIndex(where: { $0.id == id }) {
            contexts[i] = saved
            table.reloadData(forRowIndexes: [i], columnIndexes: IndexSet(integersIn: 0..<table.numberOfColumns))
        }
        return true
    }

    @objc private func attach() {
        guard selected.count == 1, commitEdits() else { return }
        guard let c = selected.first.flatMap({ workspace.agentContext(id: $0.id) }) else { return }
        onAttach(c)
        dismiss(nil)
    }

    @objc private func deleteSelected() {
        let sel = selected
        guard !sel.isEmpty else { return }
        let a = NSAlert()
        a.messageText = sel.count == 1 ? String(format: L("Delete the context “%@”?"), sel[0].title)
                                       : String(format: L("Delete %d contexts?"), sel.count)
        a.informativeText = L("It moves to Recently Deleted, where you can put it back.")
        a.addButton(withTitle: L("Delete")).hasDestructiveAction = true
        a.addButton(withTitle: L("Cancel"))
        let go: (NSApplication.ModalResponse) -> Void = { [weak self] r in
            guard let self, r == .alertFirstButtonReturn else { return }
            self.selfWriting = true
            let ok = self.workspace.trashAgentContexts(ids: sel.map(\.id))
            self.selfWriting = false
            if !ok {
                self.report(self.workspace.lastError ?? L("Could not delete the context."))
            }
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

    func numberOfRows(in tableView: NSTableView) -> Int { contexts.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard contexts.indices.contains(row), let col = tableColumn?.identifier.rawValue else { return nil }
        let c = contexts[row]
        let text: String
        switch col {
        case "title": text = c.title
        case "agent": text = c.agent
        default: text = c.updatedAt.formatted(date: .abbreviated, time: .shortened)
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
        v.toolTip = col == "title" ? String(c.summary.prefix(400)) : nil
        return v
    }

    /// 换选中之前：正在编辑的那份改过就先存下（不弹窗问——和习题笔记一样「写了就存」）。
    func selectionShouldChange(in tableView: NSTableView) -> Bool { commitEdits() }

    func tableViewSelectionDidChange(_ notification: Notification) { showSelection() }
}
