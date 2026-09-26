import AppKit

/// 新建画板笔记（`BOARD-NOTE-PLAN.md §9.4`）：先选模式——无限画布 / 分页；分页再选页面大小（含横竖）、
/// 背景模板、初始页数。模式建好之后不再转换。系统控件 + 表单布局（`NSGridView`），以 sheet 弹出。
final class NewBoardSheetController: NSViewController {
    var onCreate: (WorkspaceManager.BoardSpec) -> Void = { _ in }
    var onCancel: () -> Void = {}

    private let mode = NSSegmentedControl(labels: [L("Infinite Canvas"), L("Paged")], trackingMode: .selectOne,
                                          target: nil, action: nil)
    private let size = NSPopUpButton(frame: .zero, pullsDown: false)
    private let orient = NSSegmentedControl(labels: [L("Portrait"), L("Landscape")], trackingMode: .selectOne,
                                            target: nil, action: nil)
    private let template = NSPopUpButton(frame: .zero, pullsDown: false)
    private let count = NSTextField(string: "1")
    private let stepper = NSStepper()
    private var pagedRows: [NSGridRow] = []
    private let sizes = BoardPageSize.allCases

    /// 上次选的记在本机（下次新建默认同样的设置）。
    private let defaults = UserDefaults.standard

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 240))
        let title = NSTextField(labelWithString: L("New Board"))
        title.font = .systemFont(ofSize: NSFont.systemFontSize + 2, weight: .semibold)

        mode.target = self
        mode.action = #selector(modeChanged)
        mode.selectedSegment = defaults.integer(forKey: "newBoard.mode") == 1 ? 1 : 0
        for s in sizes { size.addItem(withTitle: s.label) }
        size.selectItem(at: min(max(0, defaults.integer(forKey: "newBoard.size")), sizes.count - 1))
        orient.selectedSegment = defaults.integer(forKey: "newBoard.orient") == 1 ? 1 : 0
        for t in BoardTemplate.allCases { template.addItem(withTitle: t.label) }
        template.selectItem(at: min(max(0, defaults.integer(forKey: "newBoard.template")), BoardTemplate.allCases.count - 1))
        stepper.minValue = 1
        stepper.maxValue = 100
        stepper.integerValue = 1
        stepper.target = self
        stepper.action = #selector(stepped)
        count.integerValue = 1
        count.alignment = .right
        count.widthAnchor.constraint(equalToConstant: 56).isActive = true
        count.target = self
        count.action = #selector(typed)
        let countRow = NSStackView(views: [count, stepper])
        countRow.spacing = 4

        func label(_ s: String) -> NSTextField {
            let f = NSTextField(labelWithString: s)
            f.alignment = .right
            return f
        }
        let grid = NSGridView(views: [
            [label(L("Mode")), mode],
            [label(L("Page Size")), NSStackView(views: [size, orient])],
            [label(L("Background")), template],
            [label(L("Page Count")), countRow],
        ])
        grid.rowSpacing = 10
        grid.columnSpacing = 10
        grid.column(at: 0).xPlacement = .trailing
        pagedRows = (1...3).map { grid.row(at: $0) }

        let cancel = NSButton(title: L("Cancel"), target: self, action: #selector(cancelTapped))
        cancel.keyEquivalent = "\u{1b}"
        let create = NSButton(title: L("Create"), target: self, action: #selector(createTapped))
        create.keyEquivalent = "\r"
        let buttons = NSStackView(views: [NSView(), cancel, create])
        buttons.spacing = 8

        let stack = NSStackView(views: [title, grid, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stack.topAnchor.constraint(equalTo: root.topAnchor),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
        ])
        view = root
        modeChanged()
    }

    @objc private func modeChanged() {
        let paged = mode.selectedSegment == 1
        for r in pagedRows { r.isHidden = !paged }
    }
    @objc private func stepped() { count.integerValue = stepper.integerValue }
    @objc private func typed() {
        let n = min(max(1, count.integerValue), 100)
        count.integerValue = n
        stepper.integerValue = n
    }

    @objc private func cancelTapped() { onCancel() }

    @objc private func createTapped() {
        typed()
        defaults.set(mode.selectedSegment, forKey: "newBoard.mode")
        defaults.set(size.indexOfSelectedItem, forKey: "newBoard.size")
        defaults.set(orient.selectedSegment, forKey: "newBoard.orient")
        defaults.set(template.indexOfSelectedItem, forKey: "newBoard.template")
        guard mode.selectedSegment == 1 else { onCreate(.infinite); return }
        let screen = NSScreen.main?.visibleFrame.size ?? CGSize(width: 1280, height: 800)
        var s = sizes[max(0, size.indexOfSelectedItem)].portrait(screen: screen)
        if orient.selectedSegment == 1 { s = CGSize(width: s.height, height: s.width) }
        let t = BoardTemplate.allCases[max(0, template.indexOfSelectedItem)]
        onCreate(WorkspaceManager.BoardSpec(paged: (s, t, count.integerValue)))
    }
}
