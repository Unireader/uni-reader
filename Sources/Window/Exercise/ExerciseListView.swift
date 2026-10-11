import AppKit

/// 列表：一行一题（`EXERCISE-PLAN.md §4.2`）。双击 = 从这一题开始练；右键：重做（可多选）/ 收藏 / 移出错题本 /
/// 到 PDF 原页 / 删除。
/// 题干只显示一行纯文本（公式源码原样）——几百行都走引擎渲染太重，看全题去练习页。
@MainActor
final class ExerciseListView: NSView, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
    private let deck: ExerciseDeck
    private weak var workspace: WorkspaceManager?
    var onPractice: (Int) -> Void = { _ in }
    var onOpenSource: (Exercise) -> Void = { _ in }
    /// 右键「重做」：这几道题（id）当没答过，从第几行开始练。
    var onRedo: ([String], Int) -> Void = { _, _ in }

    private let scroll = NSScrollView()
    private let table = NSTableView()

    private enum Col: String, CaseIterable {
        case number, stem, chapter, page, type, mine, tries, status
        var title: String {
            switch self {
            case .number: return L("No.")
            case .stem: return L("Question")
            case .chapter: return L("Chapter")
            case .page: return L("Page")
            case .type: return L("Type")
            case .mine: return L("My Answer")
            case .tries: return L("Practiced")
            case .status: return L("Marks")
            }
        }
        var width: CGFloat {
            switch self {
            case .number: return 56
            case .stem: return 360
            case .chapter: return 140
            case .page: return 48
            case .type: return 64
            case .mine: return 76
            case .tries: return 110
            case .status: return 56
            }
        }
    }

    init(deck: ExerciseDeck, workspace: WorkspaceManager) {
        self.deck = deck
        self.workspace = workspace
        super.init(frame: .zero)
        for c in Col.allCases {
            let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(c.rawValue))
            col.title = c.title
            col.width = c.width
            col.minWidth = 36
            if c == .stem { col.resizingMask = [.autoresizingMask, .userResizingMask] }
            table.addTableColumn(col)
        }
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        table.usesAlternatingRowBackgroundColors = true
        table.style = .inset
        table.allowsMultipleSelection = true
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(doubleClicked)
        let menu = NSMenu()
        menu.delegate = self
        table.menu = menu
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.automaticallyAdjustsContentInsets = false
        addSubview(scroll)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) 不支持") }

    override func layout() {
        super.layout()
        scroll.frame = bounds
        table.sizeLastColumnToFit()
    }

    func reload() {
        table.reloadData()
        if deck.items.indices.contains(deck.index) {
            table.selectRowIndexes(IndexSet(integer: deck.index), byExtendingSelection: false)
            table.scrollRowToVisible(deck.index)
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { deck.items.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard deck.items.indices.contains(row), let id = tableColumn?.identifier,
              let col = Col(rawValue: id.rawValue) else { return nil }
        let e = deck.items[row]
        let cellID = NSUserInterfaceItemIdentifier("ex.\(col.rawValue)")
        let cell = (tableView.makeView(withIdentifier: cellID, owner: nil) as? NSTableCellView) ?? Self.makeCell(cellID, icons: col == .status)
        switch col {
        case .number: cell.textField?.stringValue = e.number
        case .stem: cell.textField?.stringValue = e.plainStem
        case .chapter:
            cell.textField?.stringValue = e.chapter.last ?? ""
            cell.toolTip = e.chapter.isEmpty ? nil : ExerciseChapter.display(e.chapter)
        case .page: cell.textField?.stringValue = e.page.map { String($0 + 1) } ?? ""
        case .type: cell.textField?.stringValue = e.kind == .multiple ? L("Multiple") : L("Single")
        case .mine:
            // 和练习页显示的是同一份：这一轮答的，否则上次作答，再否则书上的作答
            let a = deck.answer(for: e)
            let mine = a.map { Exercise.answerString($0.chosen) } ?? ""
            cell.textField?.stringValue = a?.correct.map { String(format: L("%@ (%@)"), mine, $0 ? L("right") : L("wrong")) } ?? mine
            switch a?.earlier {
            case .book?: cell.toolTip = L("Marked in the book")
            case .practiced?: cell.toolTip = L("Last time")
            case nil: cell.toolTip = a == nil ? nil : L("This round")
            }
        case .tries:
            let s = deck.stats[e.id]
            cell.textField?.stringValue = (s?.attempts ?? 0) == 0 ? "" :
                String(format: L("%d× · %d right"), s?.attempts ?? 0, s?.correct ?? 0)
        case .status:
            var parts: [String] = []
            if e.starred { parts.append("★") }
            if e.wrong { parts.append("✗") }
            cell.textField?.stringValue = parts.joined(separator: " ")
            cell.toolTip = [e.starred ? L("Starred") : nil, e.wrong ? L("In Mistakes") : nil]
                .compactMap { $0 }.joined(separator: " · ")
        }
        return cell
    }

    private static func makeCell(_ id: NSUserInterfaceItemIdentifier, icons: Bool) -> NSTableCellView {
        let cell = NSTableCellView()
        let f = NSTextField(labelWithString: "")
        f.lineBreakMode = .byTruncatingTail
        f.textColor = .labelColor
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
    }

    @objc private func doubleClicked() {
        let row = table.clickedRow
        guard deck.items.indices.contains(row) else { return }
        onPractice(row)
    }

    // MARK: - 右键

    /// 右键作用的那几行：点在选中行上 = 全部选中行；点在别处 = 只那一行。
    private func targetRows() -> [Int] {
        let clicked = table.clickedRow
        guard clicked >= 0 else { return Array(table.selectedRowIndexes) }
        return table.selectedRowIndexes.contains(clicked) ? Array(table.selectedRowIndexes) : [clicked]
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let rows = targetRows().filter { deck.items.indices.contains($0) }
        guard !rows.isEmpty else { return }
        let items = rows.map { deck.items[$0] }
        // 重做：选中的里面有显示着作答的才有（没答过的题直接练就是）
        let redoable = items.filter { deck.answer(for: $0) != nil }.count
        if rows.count == 1 {
            add(menu, L("Practice from Here"), #selector(menuPractice))
            if redoable > 0 { add(menu, L("Try Again"), #selector(menuRedo)) }
            if items[0].documentId != nil, items[0].page != nil { add(menu, L("Open Page"), #selector(menuOpen)) }
            menu.addItem(.separator())
        } else if redoable > 0 {
            add(menu, String(format: L("Redo %d Questions"), redoable), #selector(menuRedo))
            menu.addItem(.separator())
        }
        let allStarred = items.allSatisfy(\.starred)
        add(menu, allStarred ? L("Unstar") : L("Star"), #selector(menuStar))
        // 章节：一次只能改同一本书里的题（下拉框列的是那本书的目录）
        let docs = Set(items.map { $0.documentId ?? "" })
        if docs.count == 1, let d = docs.first, !d.isEmpty { add(menu, L("Set Chapter…"), #selector(menuChapter)) }
        if items.contains(where: \.wrong) { add(menu, L("Remove from Mistakes"), #selector(menuUnmistake)) }
        menu.addItem(.separator())
        add(menu, rows.count == 1 ? L("Delete Exercise…") : String(format: L("Delete %d Exercises…"), rows.count),
            #selector(menuDelete))
    }

    private func add(_ menu: NSMenu, _ title: String, _ action: Selector) {
        let it = NSMenuItem(title: title, action: action, keyEquivalent: "")
        it.target = self
        menu.addItem(it)
    }

    @objc private func menuPractice() { if let r = targetRows().first { onPractice(r) } }
    /// 选中的题里显示着作答的那几道重做，从其中第一道开始练。
    @objc private func menuRedo() {
        let rows = targetRows().filter { deck.items.indices.contains($0) && deck.answer(for: deck.items[$0]) != nil }.sorted()
        guard let first = rows.first else { return }
        onRedo(rows.map { deck.items[$0].id }, first)
    }
    @objc private func menuOpen() { if let r = targetRows().first, deck.items.indices.contains(r) { onOpenSource(deck.items[r]) } }

    @objc private func menuStar() {
        let items = targetRows().compactMap { deck.items.indices.contains($0) ? deck.items[$0] : nil }
        let on = !items.allSatisfy(\.starred)
        for e in items { deck.setStarred(e, on) }
    }

    /// 「设置章节…」：读那本书的目录，弹一张表让用户选（按页码自动 / 目录里的某一节 / 不设 / 手填）。
    @objc private func menuChapter() {
        let items = targetRows().compactMap { deck.items.indices.contains($0) ? deck.items[$0] : nil }
        guard let docId = items.first?.documentId, let ws = workspace, let win = window else { return }
        let ids = items.map(\.id)
        ExerciseOriginal.chapters(documentId: docId, workspace: ws) { [weak self, weak win] toc in
            guard let self, let win, win.attachedSheet == nil else { return }
            ExerciseChapterPicker.present(on: win, toc: toc, current: items.count == 1 ? items[0].chapter : nil) { choice in
                guard let ws = self.workspace else { return }
                switch choice {
                case .auto: ws.autoAssignExerciseChapters(ids: ids, toc: toc)
                case .path(let p): ws.setExerciseChapter(ids: ids, p)
                }
            }
        }
    }

    @objc private func menuUnmistake() {
        for r in targetRows() where deck.items.indices.contains(r) && deck.items[r].wrong { deck.setWrong(deck.items[r], false) }
    }

    @objc private func menuDelete() {
        let ids = targetRows().compactMap { deck.items.indices.contains($0) ? deck.items[$0].id : nil }
        guard !ids.isEmpty, let win = window else { return }
        let a = NSAlert()
        a.messageText = ids.count == 1 ? L("Delete this exercise?") : String(format: L("Delete %d exercises?"), ids.count)
        a.informativeText = L("Its practice history is deleted too. You can put it back from Recently Deleted.")
        a.addButton(withTitle: L("Delete"))
        a.addButton(withTitle: L("Cancel"))
        a.buttons.first?.hasDestructiveAction = true
        a.beginSheetModal(for: win) { [weak self] resp in
            guard resp == .alertFirstButtonReturn, let ws = self?.workspace else { return }
            if !ws.trashExercises(ids: ids), let msg = ws.lastError {
                let e = NSAlert()
                e.messageText = msg
                e.runModal()
            }
        }
    }
}
