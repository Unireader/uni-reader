import AppKit

/// 新建画板笔记（`BOARD-NOTE-PLAN.md §9.4`）：先选模式——无限画布 / 分页；分页再选页面大小（含横竖）、
/// 背景模板、初始页数。模式建好之后不再转换。系统控件 + 表单布局（`NSGridView`），以 sheet 弹出。
/// 尺寸由内容自己撑出来（不给固定 frame，否则控件溢出 / 留大块空白）；无限画布时分页那几行**禁用而不隐藏**，
/// 切模式时表单大小不跳。
final class NewBoardSheetController: NSViewController {
    var onCreate: (WorkspaceManager.BoardSpec) -> Void = { _ in }
    var onCancel: () -> Void = {}

    private let mode = NSSegmentedControl(labels: [L("Infinite Canvas"), L("Paged")], trackingMode: .selectOne,
                                          target: nil, action: nil)
    private let size = BoardPageSizeControl()
    private let template = NSPopUpButton(frame: .zero, pullsDown: false)
    private let count = NSTextField(string: "1")
    private let stepper = NSStepper()
    private var pagedLabels: [NSTextField] = []

    /// 上次选的记在本机（下次新建默认同样的设置）。
    private let defaults = UserDefaults.standard

    override func loadView() {
        let root = NSView()
        let title = NSTextField(labelWithString: L("New Board"))
        title.font = .systemFont(ofSize: NSFont.systemFontSize + 2, weight: .semibold)

        mode.target = self
        mode.action = #selector(modeChanged)
        mode.selectedSegment = defaults.integer(forKey: "newBoard.mode") == 1 ? 1 : 0
        let w = defaults.double(forKey: "newBoard.width"), h = defaults.double(forKey: "newBoard.height")
        if BoardPageSizeControl.range.contains(w), BoardPageSizeControl.range.contains(h) {
            size.size = CGSize(width: w, height: h)
        }
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
        pagedLabels = [label(L("Page Size")), label(L("Background")), label(L("Page Count"))]
        let grid = NSGridView(views: [
            [label(L("Mode")), mode],
            [pagedLabels[0], size.presetRow],
            [NSGridCell.emptyContentView, size.sizeRow],   // 宽 × 高手输，归在「页面大小」下
            [pagedLabels[1], template],
            [pagedLabels[2], countRow],
        ])
        grid.rowSpacing = 10
        grid.columnSpacing = 8
        grid.column(at: 0).xPlacement = .trailing
        grid.yPlacement = .center

        let cancel = NSButton(title: L("Cancel"), target: self, action: #selector(cancelTapped))
        cancel.keyEquivalent = "\u{1b}"
        let create = NSButton(title: L("Create"), target: self, action: #selector(createTapped))
        create.keyEquivalent = "\r"
        let buttons = NSStackView()
        buttons.setViews([cancel, create], in: .trailing)
        buttons.spacing = 8

        let stack = NSStackView(views: [title, grid, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.setCustomSpacing(20, after: grid)
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stack.topAnchor.constraint(equalTo: root.topAnchor),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
            // 纵向 stack 不会自己被表格撑宽（控件被挤出右边），显式要求容得下
            grid.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor, constant: -40),
        ])
        root.setFrameSize(root.fittingSize)
        preferredContentSize = root.frame.size
        view = root
        modeChanged()
    }

    @objc private func modeChanged() {
        let paged = mode.selectedSegment == 1
        size.isEnabled = paged
        for c in [template, count, stepper] as [NSControl] { c.isEnabled = paged }
        for l in pagedLabels { l.textColor = paged ? .labelColor : .disabledControlTextColor }
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
        size.commitEditing()
        let s = size.size
        defaults.set(mode.selectedSegment, forKey: "newBoard.mode")
        defaults.set(Double(s.width), forKey: "newBoard.width")
        defaults.set(Double(s.height), forKey: "newBoard.height")
        defaults.set(template.indexOfSelectedItem, forKey: "newBoard.template")
        guard mode.selectedSegment == 1 else { onCreate(.infinite); return }
        let t = BoardTemplate.allCases[max(0, template.indexOfSelectedItem)]
        onCreate(WorkspaceManager.BoardSpec(paged: (s, t, count.integerValue)))
    }
}
