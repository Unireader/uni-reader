import AppKit

/// 日程标签在阅读窗格里的样子（`SCHEDULE-PLAN.md §4`）：顶上一条（‹ 月份 › · 今天 · 计划 · 请 Agent 安排），
/// 左边月历、右边选中那一天的事项列表 + 选中那件的详情。窗格切走时整个拆掉，回来重建（停在哪一天记在标签上）。
///
/// 数据每次整份重读（一个月顶多几百件，读一次不到 1 毫秒）：库里日程一变（自己改 / Agent 经 MCP 改 / 同步拉来 /
/// 回收站放回）就在下一拍重读一遍，详情里正在打字的框不被覆盖（`ScheduleItemEditor.show`）。
@MainActor
final class ScheduleTabView: NSView, NSTextFieldDelegate {
    private let workspace: WorkspaceManager
    /// 这扇窗的 id（「请 Agent 安排」把话放进这扇窗的 Agent 输入框，窗格设）。
    var agentWindow: () -> UUID? = { nil }
    /// 点了说明里的链接（窗格接：笔记在本窗口开，书 / 书页走 `DeepLinkRouter`）。
    var onOpenLink: (String) -> Void = { _ in }
    /// 看的那一天 / 选中的那一件变了（窗格写回标签：MCP 与 Agent 上下文读）。
    var onSelectionChange: (_ day: String, _ itemId: String?) -> Void = { _, _ in }
    /// 顶部让开工具栏的高度（由窗格设）。
    var topInset: CGFloat = 0 { didSet { if topInset != oldValue { needsLayout = true } } }
    /// 底下浮着的标签栏占的高度（窗格给）。
    var bottomInset: CGFloat = 0 { didSet { if bottomInset != oldValue { needsLayout = true } } }

    private let header = NSVisualEffectView()
    private let navControl = NSSegmentedControl()
    private let todayButton = NSButton()
    private let monthLabel = NSTextField(labelWithString: "")
    private let plansPopup = NSPopUpButton(frame: .zero, pullsDown: true)
    private let agentButton = NSButton()
    private let headerLine = NSBox()
    private let monthView = ScheduleMonthView()
    private let splitLine = NSBox()
    private let dayTitle = NSTextField(labelWithString: "")
    private let addField = NSTextField()
    private let list = ScheduleDayList()
    private let editorLine = NSBox()
    private let editor = ScheduleItemEditor()
    /// 详情放在滚动视图里：窗口矮时详情放不下，能滚到底下的按钮。
    private let editorScroll = NSScrollView()
    private let editorHint = NSTextField(wrappingLabelWithString: "")

    private var month: String
    private var selectedDay: String
    private var selectedItem: String?
    private var today = ScheduleDay.today()
    private var plans: [String: LibSchedulePlan] = [:]
    private var reloadQueued = false
    private var observers: [NSObjectProtocol] = []

    init(workspace: WorkspaceManager, day: String?, itemId: String?) {
        self.workspace = workspace
        let d = day.flatMap { ScheduleDay.isValid($0) ? $0 : nil } ?? ScheduleDay.today()
        selectedDay = d
        month = ScheduleDay.month(of: d)
        selectedItem = itemId
        super.init(frame: .zero)
        header.material = .headerView
        header.blendingMode = .withinWindow

        navControl.segmentCount = 2
        navControl.trackingMode = .momentary
        navControl.setImage(NSImage(systemSymbolName: "chevron.left", accessibilityDescription: L("Previous Month")), forSegment: 0)
        navControl.setImage(NSImage(systemSymbolName: "chevron.right", accessibilityDescription: L("Next Month")), forSegment: 1)
        navControl.setToolTip(L("Previous Month"), forSegment: 0)
        navControl.setToolTip(L("Next Month"), forSegment: 1)
        navControl.target = self
        navControl.action = #selector(navigate)
        todayButton.bezelStyle = .push
        todayButton.title = L("Today")
        todayButton.target = self
        todayButton.action = #selector(goToday)
        monthLabel.font = .systemFont(ofSize: NSFont.systemFontSize + 4, weight: .semibold)
        monthLabel.textColor = .labelColor

        plansPopup.bezelStyle = .push
        plansPopup.toolTip = L("Plans: see how far each one got, or delete a whole plan")
        agentButton.bezelStyle = .push
        agentButton.title = L("Ask Agent to Plan…")
        agentButton.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil)
        agentButton.imagePosition = .imageLeading
        agentButton.contentTintColor = .labelColor
        agentButton.toolTip = L("Put a request in the Agent panel: the agent looks at your progress and current schedule, then writes a plan into the schedule. You can edit the request before sending.")
        agentButton.target = self
        agentButton.action = #selector(askAgentClicked)

        for b in [headerLine, splitLine, editorLine] { b.boxType = .separator }
        dayTitle.font = .systemFont(ofSize: NSFont.systemFontSize + 2, weight: .semibold)
        dayTitle.textColor = .labelColor
        dayTitle.lineBreakMode = .byTruncatingTail
        addField.placeholderString = L("Add to this day, press Return")
        addField.delegate = self
        addField.target = self
        addField.action = #selector(addFromField)
        editorHint.alignment = .center
        editorHint.textColor = .labelColor
        editorHint.font = .preferredFont(forTextStyle: .callout)
        editorHint.stringValue = L("Select an item to see and edit its details.")

        editorScroll.documentView = editor
        editorScroll.hasVerticalScroller = true
        editorScroll.autohidesScrollers = true
        editorScroll.drawsBackground = false
        for v in [monthView, list, editorScroll, editorHint, splitLine, editorLine, header, navControl, todayButton, monthLabel,
                  plansPopup, agentButton, headerLine, dayTitle, addField] as [NSView] {
            addSubview(v)
        }

        monthView.onSelectDay = { [weak self] d in self?.select(day: d, item: nil) }
        monthView.onSelectItem = { [weak self] id, d in self?.select(day: d, item: id) }
        monthView.onDoubleClickDay = { [weak self] d in
            guard let self else { return }
            self.select(day: d, item: nil)
            self.window?.makeFirstResponder(self.addField)
        }
        monthView.onDropItems = { [weak self] ids, d in self?.move(ids, to: d) }
        list.onSelect = { [weak self] m in
            guard let self else { return }
            self.selectedItem = m?.id
            self.showEditor()
            self.monthView.show(month: self.month, days: self.gridDays, items: self.gridItems, selectedDay: self.selectedDay,
                                selectedItem: self.selectedItem, today: self.today, firstWeekday: self.firstWeekday)
            self.reportSelection()
        }
        list.onToggle = { [weak self] id, done in self?.workspace.setScheduleDone(ids: [id], done: done) }
        list.onMove = { [weak self] ids, d in self?.move(ids, to: d) }
        list.onDelete = { [weak self] ids in self?.confirmDelete(itemIds: ids, planIds: []) }
        editor.onChange = { [weak self] m in
            guard let self else { return }
            if self.workspace.updateScheduleItems([m]) == nil { self.report(self.workspace.lastError) }
            if m.day != self.selectedDay, !m.day.isEmpty { self.selectedDay = m.day; self.month = ScheduleDay.month(of: m.day) }
        }
        editor.onDelete = { [weak self] id in self?.confirmDelete(itemIds: [id], planIds: []) }
        editor.onOpenLink = { [weak self] l in self?.onOpenLink(l) }
        editor.onHeightChange = { [weak self] in self?.needsLayout = true }

        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: .scheduleDidChange, object: workspace, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.queueReload() }
        })
        // 过了零点：「今天」换一天
        observers.append(nc.addObserver(forName: .NSCalendarDayChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.queueReload() }
        })
        reload()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) 不支持") }

    deinit { for o in observers { NotificationCenter.default.removeObserver(o) } }

    override var isFlipped: Bool { true }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { editor.commit() }   // 窗格拆掉前把正在改的存下
        super.viewWillMove(toWindow: newWindow)
    }

    private var firstWeekday: Int { Calendar.current.firstWeekday }
    private var gridDays: [String] = []
    private var gridItems: [String: [LibScheduleItem]] = [:]

    // MARK: 去哪

    /// 打开日程时带的去处（窗格转过来）：去那一天、选中那一件。
    func focus(_ f: ScheduleFocus) {
        var day = f.day.flatMap { ScheduleDay.isValid($0) ? $0 : nil }
        if let id = f.itemId, let m = workspace.scheduleItem(id: id), day == nil { day = m.day.isEmpty ? nil : m.day }
        let d = day ?? selectedDay
        selectedDay = d
        month = ScheduleDay.month(of: d)
        selectedItem = f.itemId
        reload()
    }

    private func select(day: String, item: String?) {
        editor.commit()
        selectedDay = day
        if ScheduleDay.month(of: day) != month { month = ScheduleDay.month(of: day) }
        selectedItem = item
        reload()
    }

    @objc private func navigate() {
        let step = navControl.selectedSegment == 0 ? -1 : 1
        guard let m = ScheduleDay.addingMonths(step, to: month) else { return }
        editor.commit()
        month = m
        // 选中的那天跟着挪到新的月里（同一号，没有这一号就挪到月底）
        let dayNum = Int(selectedDay.suffix(2)) ?? 1
        var d = m + String(format: "-%02d", dayNum)
        var n = dayNum
        while !ScheduleDay.isValid(d), n > 28 { n -= 1; d = m + String(format: "-%02d", n) }
        selectedDay = d
        selectedItem = nil
        reload()
    }

    @objc private func goToday() { select(day: ScheduleDay.today(), item: nil) }

    // MARK: 读

    private func queueReload() {
        guard !reloadQueued else { return }
        reloadQueued = true
        DispatchQueue.main.async { [weak self] in
            self?.reloadQueued = false
            self?.reload()
        }
    }

    private func reload() {
        today = ScheduleDay.today()
        plans = Dictionary(workspace.schedulePlans.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        gridDays = ScheduleDay.monthGrid(month, firstWeekday: firstWeekday)
        var byDay: [String: [LibScheduleItem]] = [:]
        if let first = gridDays.first, let last = gridDays.last {
            for m in workspace.scheduleItems(from: first, to: last) { byDay[m.day, default: []].append(m) }
        }
        gridItems = byDay
        // 选中的那件没了（删掉 / 别处删的）就不选
        if let id = selectedItem, workspace.scheduleItem(id: id) == nil { selectedItem = nil }
        monthLabel.stringValue = ScheduleFormat.month(month)
        monthView.show(month: month, days: gridDays, items: gridItems, selectedDay: selectedDay, selectedItem: selectedItem,
                       today: today, firstWeekday: firstWeekday)
        dayTitle.stringValue = ScheduleFormat.day(selectedDay, today: today)
            + (selectedDay == today ? " · " + L("Today") : "")
        todayButton.isEnabled = selectedDay != today || month != ScheduleDay.month(of: today)
        list.show(listRows(), planTitles: plans.mapValues(\.title), today: today, select: selectedItem)
        rebuildPlansMenu()
        showEditor()
        reportSelection()
        needsLayout = true
    }

    private func listRows() -> [ScheduleDayList.Row] {
        var rows: [ScheduleDayList.Row] = []
        let dayItems = gridItems[selectedDay] ?? workspace.scheduleItems(from: selectedDay, to: selectedDay)
        if dayItems.isEmpty {
            rows.append(.empty(L("Nothing planned for this day.")))
        } else {
            rows += dayItems.map { .item($0, showDay: false) }
        }
        if selectedDay == today {
            let overdue = workspace.overdueScheduleItems(before: today)
            if !overdue.isEmpty {
                rows.append(.header(String(format: L("Overdue (%d)"), overdue.count)))
                rows += overdue.map { .item($0, showDay: true) }
            }
        }
        let undated = workspace.undatedScheduleItems
        if !undated.isEmpty {
            rows.append(.header(String(format: L("No Date (%d)"), undated.count)))
            rows += undated.map { .item($0, showDay: false) }
        }
        return rows
    }

    private func showEditor() {
        let m = selectedItem.flatMap { workspace.scheduleItem(id: $0) }
        editor.show(m, plan: m.flatMap { plans[$0.planId] })
        editorScroll.isHidden = m == nil
        editorHint.isHidden = m != nil
        needsLayout = true
    }

    /// 把眼下看的那一天 / 选中的那一件报给窗格（窗格接上回调后先报一次：别等用户点了才知道）。
    func reportSelection() { onSelectionChange(selectedDay, selectedItem) }

    // MARK: 计划菜单

    private func rebuildPlansMenu() {
        let menu = NSMenu()
        menu.addItem(withTitle: L("Plans"), action: nil, keyEquivalent: "")   // 下拉按钮的标题项
        let all = workspace.schedulePlans
        let counts = workspace.schedulePlanCounts()
        if all.isEmpty {
            let none = NSMenuItem(title: L("No plans yet. Ask an agent to make one."), action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
        }
        for p in all {
            let c = counts[p.id] ?? (0, 0)
            let item = NSMenuItem(title: "\(p.title)  \(c.done)/\(c.total)", action: nil, keyEquivalent: "")
            let sub = NSMenu()
            if !p.goal.isEmpty {
                let g = NSMenuItem(title: String(format: L("Goal: %@"), p.goal), action: nil, keyEquivalent: "")
                g.isEnabled = false
                sub.addItem(g)
                sub.addItem(.separator())
            }
            if let first = workspace.scheduleItems(planId: p.id).first(where: { !$0.isDone && !$0.day.isEmpty }) {
                sub.addItem(ClosureMenuItem(L("Go to the Next Item")) { [weak self] in self?.select(day: first.day, item: first.id) })
            }
            sub.addItem(ClosureMenuItem(L("Ask Agent to Adjust This Plan…")) { [weak self] in self?.askAgent(adjusting: p) })
            sub.addItem(.separator())
            sub.addItem(ClosureMenuItem(L("Delete Plan…")) { [weak self] in self?.confirmDelete(itemIds: [], planIds: [p.id]) })
            item.submenu = sub
            menu.addItem(item)
        }
        plansPopup.menu = menu
    }

    // MARK: 改

    @objc private func addFromField() {
        let t = addField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        guard let added = workspace.addScheduleItems([.init(title: t, day: selectedDay)], planId: "", agent: "") else {
            report(workspace.lastError)
            return
        }
        addField.stringValue = ""
        selectedItem = added.first?.id
        // 光标留在输入框：连着加几件
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.window?.makeFirstResponder(self.addField)
        }
    }

    private func move(_ ids: [String], to day: String) {
        editor.commit()
        if !workspace.moveScheduleItems(ids: ids, to: day) { report(workspace.lastError) }
    }

    private func confirmDelete(itemIds: [String], planIds: [String]) {
        let items = itemIds.compactMap { workspace.scheduleItem(id: $0) }
        let planList = planIds.compactMap { workspace.schedulePlan(id: $0) }
        guard !items.isEmpty || !planList.isEmpty else { return }
        let a = NSAlert()
        if let p = planList.first, planList.count == 1, items.isEmpty {
            let n = workspace.scheduleItems(planId: p.id).count
            a.messageText = String(format: L("Delete the plan “%@” and its %d items?"), p.title, n)
        } else if items.count == 1, planList.isEmpty {
            a.messageText = String(format: L("Delete “%@”?"), items[0].title)
        } else {
            a.messageText = String(format: L("Delete %d items?"), items.count)
        }
        a.informativeText = L("It moves to Recently Deleted, where you can put it back.")
        a.addButton(withTitle: L("Delete")).hasDestructiveAction = true
        a.addButton(withTitle: L("Cancel"))
        let go: (NSApplication.ModalResponse) -> Void = { [weak self] r in
            guard let self, r == .alertFirstButtonReturn else { return }
            if !self.workspace.trashSchedule(planIds: planList.map(\.id), itemIds: items.map(\.id)) {
                self.report(self.workspace.lastError)
            }
        }
        if let win = window { a.beginSheetModal(for: win, completionHandler: go) } else { go(a.runModal()) }
    }

    private func report(_ message: String?) {
        let a = NSAlert()
        a.messageText = message ?? L("Could not save the schedule.")
        a.addButton(withTitle: L("OK"))
        if let win = window { a.beginSheetModal(for: win) } else { a.runModal() }
    }

    // MARK: 请 Agent 安排

    /// 把一句请求放进这扇窗的 Agent 输入框（用户可以改了再发），怎么排写在隐藏说明里。
    @objc private func askAgentClicked() { askAgent(adjusting: nil) }

    private func askAgent(adjusting plan: LibSchedulePlan?) {
        guard let win = agentWindow() else { return }
        let text: String
        var note = ScheduleAgentPrompt.planning(today: today, selectedDay: selectedDay)
        if let plan {
            text = String(format: L("Based on how far I got, please adjust the rest of the plan “%@”."), plan.title)
            note += " " + ScheduleAgentPrompt.adjusting(planId: plan.id, title: plan.title)
        } else {
            text = L("Please plan my study schedule for the coming days.")
        }
        if !AgentPanelModel.shared.prepare(text: text, note: note, images: [], from: win) {
            let a = NSAlert()
            a.messageText = String(format: L("%@ is not available."), AgentPanelModel.shared.agentName(for: win))
            if let w = window { a.beginSheetModal(for: w) } else { a.runModal() }
        }
    }

    // MARK: 布局

    override func layout() {
        super.layout()
        let b = bounds
        let headerH: CGFloat = 44
        header.frame = NSRect(x: 0, y: 0, width: b.width, height: topInset + headerH)
        let pad: CGFloat = 16
        let midY = topInset + headerH / 2
        navControl.sizeToFit()
        navControl.frame.origin = NSPoint(x: pad, y: midY - navControl.frame.height / 2)
        todayButton.sizeToFit()
        todayButton.frame.origin = NSPoint(x: navControl.frame.maxX + 8, y: midY - todayButton.frame.height / 2)
        var right = b.width - pad
        agentButton.sizeToFit()
        agentButton.frame.origin = NSPoint(x: right - agentButton.frame.width, y: midY - agentButton.frame.height / 2)
        right = agentButton.frame.minX - 8
        plansPopup.sizeToFit()
        plansPopup.frame = NSRect(x: right - plansPopup.frame.width, y: midY - plansPopup.frame.height / 2,
                                  width: plansPopup.frame.width, height: plansPopup.frame.height)
        right = plansPopup.frame.minX - 12
        let mh = monthLabel.intrinsicContentSize.height
        monthLabel.frame = NSRect(x: todayButton.frame.maxX + 14, y: midY - mh / 2,
                                  width: max(0, right - todayButton.frame.maxX - 14), height: mh)
        headerLine.frame = NSRect(x: 0, y: header.frame.maxY, width: b.width, height: 1)

        let top = headerLine.frame.maxY
        let bottom = max(top, b.height - bottomInset)
        let panelW = min(400, max(300, (b.width * 0.36).rounded()))
        let gridW = max(0, b.width - panelW - 1)
        monthView.frame = NSRect(x: 0, y: top, width: gridW, height: max(0, bottom - top))
        splitLine.frame = NSRect(x: gridW, y: top, width: 1, height: max(0, b.height - top))
        let px = gridW + 1
        dayTitle.frame = NSRect(x: px + 14, y: top + 12, width: panelW - 28, height: dayTitle.intrinsicContentSize.height)
        addField.frame = NSRect(x: px + 12, y: dayTitle.frame.maxY + 8, width: panelW - 24, height: 24)
        let listTop = addField.frame.maxY + 8
        let avail = max(0, bottom - listTop)
        // 详情尽量给够它要的高度，列表至少留 140；再矮就让详情滚动
        let editorH: CGFloat = editorScroll.isHidden ? 64 : min(editor.height(forWidth: panelW), max(min(avail, 180), avail - 140))
        let listH = max(0, avail - editorH - 1)
        list.frame = NSRect(x: px, y: listTop, width: panelW, height: listH)
        editorLine.frame = NSRect(x: px, y: list.frame.maxY, width: panelW, height: 1)
        editorScroll.frame = NSRect(x: px, y: editorLine.frame.maxY, width: panelW, height: max(0, bottom - editorLine.frame.maxY))
        let docW = editorScroll.contentSize.width
        editor.frame = NSRect(x: 0, y: 0, width: docW, height: max(editorScroll.contentSize.height, editor.height(forWidth: docW)))
        editorHint.frame = NSRect(x: px + 20, y: editorLine.frame.maxY + 16, width: panelW - 40, height: 40)
    }
}

/// 「请 Agent 安排」随那句话一起发出去的隐藏说明（英文：给模型看的）。
enum ScheduleAgentPrompt {
    static func planning(today: String, selectedDay: String) -> String {
        "The user opened the schedule (日程) in UniReader and wants you to plan their study. Today is \(today); "
            + "they were looking at \(selectedDay). First look at where they are: workspace_stats (reading progress, exercises, "
            + "mistakes, recent practice), list_schedule (existing items, what is overdue, and the notes they wrote on how "
            + "finished items went), and their memories. If the goal, the deadline or how much time they have each day is "
            + "unclear, ask briefly before writing anything. Then propose the plan in a few lines and write it with "
            + "add_schedule_items as one plan (plan title + goal): one item per concrete task on a specific day, a realistic "
            + "amount per day, start times only if the user gave them, an estimated duration, and in detail the exact pages "
            + "as [[book title#page=N]] links or the exercises to do. Don't duplicate items already in the schedule."
    }

    static func adjusting(planId: String, title: String) -> String {
        "They want you to adjust the existing plan \"\(title)\" (plan_id \(planId)): read it with list_schedule plan_id, "
            + "see what is done, overdue or noted as hard, then move or rewrite the remaining items with "
            + "update_schedule_items and add new ones to the same plan with add_schedule_items plan_id. Don't touch finished items."
    }
}
