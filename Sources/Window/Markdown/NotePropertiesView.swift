import AppKit

/// 笔记顶上的「属性」栏（frontmatter 的 `键: 值`，`MarkdownProperties`）：可收起、可加可删可改。
/// 只做界面：改动经 `onSet` / `onRemove` 交给上层写回正文。按 frame 摆（行数随属性变）。
final class NotePropertiesView: NSView, NSTextFieldDelegate {
    var onSet: (String, String) -> Void = { _, _ in }
    var onRemove: (String) -> Void = { _ in }
    /// 高度变了（行数变 / 收起展开），上层重新摆位。
    var onHeightChange: () -> Void = {}

    private static let expandedKey = "noteProperties.expanded"
    private static let rowH: CGFloat = 26
    private static let keyW: CGFloat = 110

    private let toggle = NSButton()
    private let add = NSButton()
    private let line = NSBox()
    private var rows: [NSView] = []
    private var entries: [MarkdownProperties.Entry] = []
    private var editable = true
    /// 正在新建的一行（键和值两个输入框）。
    private var newKey: NSTextField?
    private var newValue: NSTextField?
    private(set) var height: CGFloat = 0
    /// 是否建过第一遍（没有任何属性的笔记也要建：标题、加号、高度都靠它）。
    private var built = false

    private var isExpanded: Bool {
        get { UserDefaults.standard.object(forKey: Self.expandedKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: Self.expandedKey) }
    }

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        toggle.isBordered = false
        toggle.imagePosition = .imageLeading
        toggle.contentTintColor = .labelColor   // 红线：别用次要色
        toggle.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        toggle.alignment = .left
        toggle.target = self
        toggle.action = #selector(toggleExpanded)
        add.image = NSImage(systemSymbolName: "plus", accessibilityDescription: L("Add Property"))
        add.imagePosition = .imageOnly
        add.isBordered = false
        add.contentTintColor = .labelColor
        add.toolTip = L("Add Property")
        add.target = self
        add.action = #selector(addProperty)
        line.boxType = .separator
        for v in [toggle, add, line] as [NSView] { addSubview(v) }
        wantsLayer = true
        layer?.masksToBounds = true   // 高度还没算出来时别把按钮画到编辑区上
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) 不支持") }

    /// 喂数据。正在输入时不重建（别把打了一半的字吞掉）。
    func update(entries new: [MarkdownProperties.Entry], editable: Bool) {
        if let w = window?.firstResponder as? NSText, w.isDescendant(of: self) { return }
        guard !built || new != entries || editable != self.editable else { return }
        built = true
        entries = new
        self.editable = editable
        rebuild()
    }

    private func rebuild() {
        for r in rows { r.removeFromSuperview() }
        rows = []
        newKey = nil; newValue = nil
        toggle.title = "\(L("Properties")) · \(entries.count)"
        toggle.image = NSImage(systemSymbolName: isExpanded ? "chevron.down" : "chevron.right", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 9, weight: .semibold))
        add.isHidden = !editable
        if isExpanded {
            for e in entries { rows.append(makeRow(e)) }
        }
        for r in rows { addSubview(r) }
        relayout()
    }

    private func makeRow(_ e: MarkdownProperties.Entry) -> NSView {
        let row = NSView()
        let key = NSTextField(labelWithString: e.key)
        key.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        key.textColor = .labelColor
        key.lineBreakMode = .byTruncatingTail
        key.toolTip = e.key
        let value = NSTextField(string: e.value)
        value.identifier = NSUserInterfaceItemIdentifier(e.key)
        value.isEditable = editable && e.editable
        value.isSelectable = true
        value.isBordered = false
        value.drawsBackground = false
        value.focusRingType = .none
        value.font = .systemFont(ofSize: NSFont.systemFontSize)
        value.textColor = .labelColor
        value.lineBreakMode = .byTruncatingTail
        value.cell?.isScrollable = true
        value.delegate = self
        value.toolTip = e.editable ? nil : L("Lists and multi-line values are read-only here")
        row.addSubview(key); row.addSubview(value)
        if editable {
            let del = NSButton()
            del.image = NSImage(systemSymbolName: "xmark.circle", accessibilityDescription: L("Remove Property"))
            del.imagePosition = .imageOnly
            del.isBordered = false
            del.contentTintColor = .labelColor
            del.toolTip = L("Remove Property")
            del.identifier = NSUserInterfaceItemIdentifier(e.key)
            del.target = self
            del.action = #selector(removeProperty(_:))
            row.addSubview(del)
        }
        return row
    }

    override func layout() {
        super.layout()
        let w = bounds.width
        toggle.frame = NSRect(x: 12, y: 0, width: max(0, w - 12 - 36), height: Self.rowH)
        add.frame = NSRect(x: w - 32, y: 0, width: 24, height: Self.rowH)
        var y = Self.rowH
        for r in rows {
            r.frame = NSRect(x: 0, y: y, width: w, height: Self.rowH)
            let subs = r.subviews
            subs[0].frame = NSRect(x: 28, y: 4, width: Self.keyW, height: 18)
            let right: CGFloat = subs.count > 2 ? 32 : 12
            subs[1].frame = NSRect(x: 28 + Self.keyW + 8, y: 3, width: max(0, w - 28 - Self.keyW - 8 - right), height: 20)
            if subs.count > 2 { subs[2].frame = NSRect(x: w - 30, y: 1, width: 24, height: 24) }
            y += Self.rowH
        }
        line.frame = NSRect(x: 0, y: y, width: w, height: 1)
    }

    private func relayout() {
        let h = Self.rowH + (isExpanded ? CGFloat(rows.count) * Self.rowH : 0) + 1
        let changed = h != height
        height = h
        needsLayout = true
        if changed { onHeightChange() }
    }

    // MARK: 动作

    @objc private func toggleExpanded() {
        isExpanded.toggle()
        rebuild()
    }

    @objc private func removeProperty(_ sender: NSButton) {
        guard let k = sender.identifier?.rawValue else { return }
        onRemove(k)
    }

    /// 加一行：键、值两个输入框（回车在键里跳到值，值里回车 = 提交）。
    @objc private func addProperty() {
        if !isExpanded { isExpanded = true; rebuild() }
        guard newKey == nil else { window?.makeFirstResponder(newKey); return }
        let row = NSView()
        let k = NSTextField(string: "")
        k.placeholderString = L("Name")
        let v = NSTextField(string: "")
        v.placeholderString = L("Value")
        for f in [k, v] {
            f.isBordered = true
            f.bezelStyle = .roundedBezel
            f.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            f.delegate = self
            row.addSubview(f)
        }
        newKey = k; newValue = v
        rows.append(row)
        addSubview(row)
        relayout()
        layoutNewRow(row)
        window?.makeFirstResponder(k)
    }

    private func layoutNewRow(_ row: NSView) {
        let w = bounds.width
        row.subviews[0].frame = NSRect(x: 28, y: 2, width: Self.keyW, height: 22)
        row.subviews[1].frame = NSRect(x: 28 + Self.keyW + 8, y: 2, width: max(0, w - 28 - Self.keyW - 8 - 12), height: 22)
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        if let r = newKey?.superview { DispatchQueue.main.async { [weak self] in self?.layoutNewRow(r) } }
    }

    // MARK: 输入框

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        guard let f = control as? NSTextField else { return false }
        if sel == #selector(NSResponder.cancelOperation(_:)) {
            if f === newKey || f === newValue { cancelNew() } else { rebuildKeepingEntries() }
            return true
        }
        if sel == #selector(NSResponder.insertNewline(_:)) {
            if f === newKey { window?.makeFirstResponder(newValue); return true }
            window?.makeFirstResponder(nil)   // 触发 end editing → 提交
            return true
        }
        return false
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let f = obj.object as? NSTextField else { return }
        if f === newKey || f === newValue {
            // 从键跳到值不算结束；值编辑完才提交
            guard f === newValue else { return }
            let k = newKey?.stringValue.trimmingCharacters(in: .whitespaces) ?? ""
            let v = newValue?.stringValue ?? ""
            cancelNew()
            if !k.isEmpty { onSet(k, v) }
            return
        }
        guard let k = f.identifier?.rawValue, let e = entries.first(where: { $0.key == k }),
              e.editable, f.stringValue != e.value else { return }
        onSet(k, f.stringValue)
    }

    private func cancelNew() {
        newKey?.superview?.removeFromSuperview()
        rows.removeAll { $0.superview == nil }
        newKey = nil; newValue = nil
        relayout()
    }

    private func rebuildKeepingEntries() {
        window?.makeFirstResponder(nil)
        rebuild()
    }
}
