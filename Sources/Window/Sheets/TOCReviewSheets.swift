import AppKit

/// 自建目录项、回顾点的编辑框（`TOC-REVIEW-PLAN.md`）。用系统 `NSAlert` + 附加视图：外观全是标准控件。
/// 必填项空着时「添加 / 存储」是灰的。
@MainActor
enum TOCReviewSheets {

    /// 目录项：名字 + 层级。`completion(名字, 层级 0 起)`。
    static func tocEntry(in window: NSWindow?, isNew: Bool, hint: String, name: String, level: Int,
                         completion: @escaping (String, Int) -> Void) {
        let alert = NSAlert()
        alert.messageText = isNew ? L("Add Contents Entry") : L("Edit Contents Entry")
        alert.informativeText = hint
        let ok = alert.addButton(withTitle: isNew ? L("Add") : L("Save"))
        alert.addButton(withTitle: L("Cancel"))

        let field = NSTextField(string: name)
        field.placeholderString = L("Entry title")
        let levelPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        for i in 0...CustomTOCItem.maxLevel { levelPopup.addItem(withTitle: String(format: L("Level %d"), i + 1)) }
        levelPopup.selectItem(at: min(max(0, level), CustomTOCItem.maxLevel))
        let grid = NSGridView(views: [
            [label(L("Title")), field],
            [label(L("Level")), levelPopup],
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.rowSpacing = 8
        grid.columnSpacing = 8
        field.widthAnchor.constraint(equalToConstant: 260).isActive = true
        grid.frame = NSRect(origin: .zero, size: grid.fittingSize)
        alert.accessoryView = grid

        let guardian = RequiredFieldGuard(button: ok, fields: [field])
        alert.window.initialFirstResponder = field
        run(alert, in: window) { confirmed in
            _ = guardian
            guard confirmed, CustomTOCItem.validTitle(field.stringValue) else { return }
            completion(field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines), levelPopup.indexOfSelectedItem)
        }
    }

    /// 回顾点：标签（可选已有的）+ 期号 + 备注。`completion(标签, 期号, 备注)`。
    static func review(in window: NSWindow?, isNew: Bool, hint: String, tags: [String],
                       tag: String, period: Int, remark: String,
                       completion: @escaping (String, Int, String) -> Void) {
        let alert = NSAlert()
        alert.messageText = isNew ? L("Add Review Point") : L("Edit Review Point")
        alert.informativeText = hint
        let ok = alert.addButton(withTitle: isNew ? L("Add") : L("Save"))
        alert.addButton(withTitle: L("Cancel"))

        let tagBox = NSComboBox()
        tagBox.addItems(withObjectValues: tags)
        tagBox.stringValue = tag
        tagBox.placeholderString = L("Tag")
        tagBox.completes = true
        let periodField = NSTextField(string: "\(max(1, period))")
        let fmt = NumberFormatter()
        fmt.allowsFloats = false
        fmt.minimum = 1
        fmt.maximum = 9999
        periodField.formatter = fmt
        periodField.alignment = .right
        let stepper = NSStepper()
        stepper.minValue = 1
        stepper.maxValue = 9999
        stepper.increment = 1
        stepper.valueWraps = false
        stepper.integerValue = max(1, period)
        let stepperLink = StepperLink(field: periodField, stepper: stepper)
        let periodRow = NSStackView(views: [periodField, stepper])
        periodRow.spacing = 4
        periodField.widthAnchor.constraint(equalToConstant: 64).isActive = true
        let remarkField = NSTextField(string: remark)
        remarkField.placeholderString = L("Remark (optional)")
        remarkField.usesSingleLineMode = false
        remarkField.cell?.wraps = true
        remarkField.cell?.isScrollable = false
        remarkField.lineBreakMode = .byWordWrapping
        let grid = NSGridView(views: [
            [label(L("Tag")), tagBox],
            [label(L("Period")), periodRow],
            [label(L("Remark")), remarkField],
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.rowSpacing = 8
        grid.columnSpacing = 8
        tagBox.widthAnchor.constraint(equalToConstant: 260).isActive = true
        remarkField.widthAnchor.constraint(equalToConstant: 260).isActive = true
        remarkField.heightAnchor.constraint(equalToConstant: 60).isActive = true
        grid.frame = NSRect(origin: .zero, size: grid.fittingSize)
        alert.accessoryView = grid

        let guardian = RequiredFieldGuard(button: ok, fields: [tagBox])
        alert.window.initialFirstResponder = tagBox
        run(alert, in: window) { confirmed in
            _ = guardian; _ = stepperLink
            let t = ReviewMark.cleanTag(tagBox.stringValue)
            guard confirmed, !t.isEmpty else { return }
            completion(t, max(1, Int(periodField.stringValue) ?? stepper.integerValue),
                       remarkField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    // MARK: 共用

    private static func label(_ s: String) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        l.textColor = .labelColor
        return l
    }

    private static func run(_ alert: NSAlert, in window: NSWindow?, done: @escaping (Bool) -> Void) {
        if let window {
            alert.beginSheetModal(for: window) { done($0 == .alertFirstButtonReturn) }
        } else {
            done(alert.runModal() == .alertFirstButtonReturn)
        }
    }
}

/// 必填输入框空着时把确定键置灰。
private final class RequiredFieldGuard: NSObject, NSTextFieldDelegate, NSComboBoxDelegate {
    let button: NSButton
    let fields: [NSTextField]
    init(button: NSButton, fields: [NSTextField]) {
        self.button = button
        self.fields = fields
        super.init()
        for f in fields { f.delegate = self }
        sync()
    }
    func controlTextDidChange(_ obj: Notification) { sync() }
    func comboBoxSelectionDidChange(_ notification: Notification) {
        DispatchQueue.main.async { self.sync() }   // 选中项要到下一拍才写进 stringValue
    }
    private func sync() {
        button.isEnabled = fields.allSatisfy { !$0.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
}

/// 期号输入框与旁边的上下箭头互相跟随。
private final class StepperLink: NSObject, NSTextFieldDelegate {
    let field: NSTextField
    let stepper: NSStepper
    init(field: NSTextField, stepper: NSStepper) {
        self.field = field
        self.stepper = stepper
        super.init()
        field.delegate = self
        stepper.target = self
        stepper.action = #selector(stepped)
    }
    @objc private func stepped() { field.stringValue = "\(stepper.integerValue)" }
    func controlTextDidChange(_ obj: Notification) {
        if let v = Int(field.stringValue), v >= 1 { stepper.integerValue = v }
    }
}
