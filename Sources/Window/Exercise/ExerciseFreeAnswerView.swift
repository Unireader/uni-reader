import AppKit

/// 填空 / 主观题的作答区（`EXERCISE-PLAN.md §11.2`）：练习页里选项那一块换成它。
/// - 填空：每空一个输入框；交卷后锁住，对得上参考答案的空标绿勾（最终判错时对不上的标红叉）。
/// - 主观题：多行输入框（`$…$` 写公式）；交卷后换成渲染好的「你的作答」。
/// - 两种都能打开手写小画板（`ExerciseInkPad`），开没开记在本机，下一题照旧。
/// 交卷后下面亮出参考答案。对错、评语、自己判的按钮在练习页上，和选择题共用结果那一行。
/// 排版同练习页：按 frame 手摆，`height(forWidth:)` 与 `layout()` 走同一个 `arrange`。
@MainActor
final class ExerciseFreeAnswerView: NSView, NSTextFieldDelegate, NSTextViewDelegate {
    /// 高度变了（练习页整列重摆）。
    var onHeightChange: () -> Void = {}
    /// 输入变了（练习页存草稿、刷「提交」能不能点）。
    var onEdit: () -> Void = {}
    /// 在最后一空按回车 = 提交。
    var onSubmit: () -> Void = {}

    private var kind: ExerciseKind = .subjective
    private var locked = false
    /// 显示的是交过的作答（只读）。
    var isLocked: Bool { locked }

    private var blankLabels: [NSTextField] = []
    private var blankFields: [NSTextField] = []
    private var blankMarks: [NSImageView] = []

    private let textScroll = NSScrollView()
    private let textView = NSTextView()
    private let placeholder = NSTextField(labelWithString: L("Write your answer here. Use $…$ for formulas."))
    private var textHeight: CGFloat = 96

    private let handButton = NSButton()
    private let toolControl = NSSegmentedControl(labels: [L("Pen"), L("Eraser")], trackingMode: .selectOne,
                                                 target: nil, action: nil)
    private let undoButton = NSButton()
    private let clearButton = NSButton()
    private let growButton = NSButton()
    private let pad = ExerciseInkPad()
    private var handOn = false

    private let mineTitle = NSTextField(labelWithString: L("Your Answer"))
    private let mineView = AgentMarkdownView(text: "", fontSize: 15, documentId: "exercise-mine")
    private let refTitle = NSTextField(labelWithString: L("Reference Answer"))
    private let refView = AgentMarkdownView(text: "", fontSize: 15, documentId: "exercise-reference")
    private var mineText = ""
    private var refText: String?

    /// 手写开着没有（本机记住，下一题照旧）。
    private static let handKey = "exercise.handwriting"

    init() {
        super.init(frame: .zero)
        textScroll.hasVerticalScroller = true
        textScroll.borderType = .bezelBorder
        textScroll.autohidesScrollers = true
        textView.isRichText = false
        textView.allowsUndo = true
        textView.font = .systemFont(ofSize: 15)
        textView.textColor = .labelColor
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainerInset = NSSize(width: 4, height: 6)
        textView.delegate = self
        textScroll.documentView = textView
        placeholder.font = .systemFont(ofSize: 15)
        placeholder.textColor = .placeholderTextColor

        setup(handButton, symbol: "pencil.and.scribble", title: L("Handwriting"), action: #selector(toggleHand))
        handButton.setButtonType(.pushOnPushOff)
        toolControl.target = self
        toolControl.action = #selector(toolChanged)
        toolControl.setImage(NSImage(systemSymbolName: "pencil.tip", accessibilityDescription: nil), forSegment: 0)
        toolControl.setImage(NSImage(systemSymbolName: "eraser", accessibilityDescription: nil), forSegment: 1)
        toolControl.selectedSegment = 0
        setup(undoButton, symbol: "arrow.uturn.backward", title: L("Undo"), action: #selector(undoInk))
        setup(clearButton, symbol: "trash", title: L("Clear"), action: #selector(clearInk))
        setup(growButton, symbol: "arrow.down.to.line", title: L("More Space"), action: #selector(growInk))
        pad.onChange = { [weak self] in self?.inkChanged() }

        for t in [mineTitle, refTitle] {
            t.font = .preferredFont(forTextStyle: .headline)
            t.textColor = .labelColor
        }
        for v in [mineView, refView] { v.onHeightChange = { [weak self] in self?.heightMayChange() } }
        for v in [textScroll, placeholder, handButton, toolControl, undoButton, clearButton, growButton, pad,
                  mineTitle, mineView, refTitle, refView] as [NSView] { addSubview(v) }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) 不支持") }

    override var isFlipped: Bool { true }

    private func setup(_ b: NSButton, symbol: String, title: String, action: Selector) {
        b.bezelStyle = .push
        b.title = title
        b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        b.imagePosition = .imageLeading
        b.target = self
        b.action = action
        b.contentTintColor = .labelColor
    }

    // MARK: - 换题 / 显示

    /// 等着作答：空输入框（有草稿就填回去）。
    func begin(_ e: Exercise, draft: ExerciseResponse?) {
        kind = e.kind
        locked = false
        makeBlanks(e.kind == .fill ? e.blankCount : 0)
        for (i, f) in blankFields.enumerated() {
            f.stringValue = draft.map { $0.blanks.indices.contains(i) ? $0.blanks[i] : "" } ?? ""
            f.isEditable = true
            f.isSelectable = true
            blankMarks[i].image = nil
        }
        if textView.string != (draft?.text ?? "") { textView.string = draft?.text ?? "" }
        textView.isEditable = true
        fitTextHeight()
        pad.load(draft?.ink)
        pad.isEditable = true
        handOn = !(draft?.ink?.isEmpty ?? true) || UserDefaults.standard.bool(forKey: Self.handKey)
        handButton.state = handOn ? .on : .off
        mineText = ""
        refText = nil
        mineView.update(text: "")
        refView.update(text: "")
        refreshControls()
        heightMayChange()
    }

    /// 交过了：锁住、显示作答（`ink` 由练习页从库里那条取来——统计里不带笔迹）和参考答案。
    func showAnswered(_ e: Exercise, answer a: ExerciseDeck.Answer, ink: ExerciseInk?) {
        kind = e.kind
        locked = true
        makeBlanks(e.kind == .fill ? e.blankCount : 0)
        let matches = e.blankMatches(a.response.blanks)
        for (i, f) in blankFields.enumerated() {
            f.stringValue = a.response.blanks.indices.contains(i) ? a.response.blanks[i] : ""
            f.isEditable = false
            f.isSelectable = true
            if matches.indices.contains(i), matches[i] {
                blankMarks[i].image = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: L("Correct"))
                blankMarks[i].contentTintColor = .systemGreen
            } else if a.correct == false, e.hasAnswer {
                blankMarks[i].image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: L("Wrong"))
                blankMarks[i].contentTintColor = .systemRed
            } else {
                blankMarks[i].image = nil
            }
        }
        textView.isEditable = false
        let shownInk = ink ?? a.response.ink
        pad.load(shownInk)
        pad.isEditable = false
        handOn = !(shownInk?.isEmpty ?? true)
        let mine = e.kind == .subjective ? a.response.text.trimmingCharacters(in: .whitespacesAndNewlines) : ""
        if mine != mineText { mineText = mine; mineView.update(text: mine) }
        let ref = Self.referenceMarkdown(e)
        if ref != refText { refText = ref; refView.update(text: ref ?? "") }
        refreshControls()
        heightMayChange()
    }

    /// 现在输入框里写的（交卷 / 存草稿用）。
    var response: ExerciseResponse {
        var r = ExerciseResponse()
        switch kind {
        case .fill: r.blanks = blankFields.map { $0.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) }
        case .subjective: r.text = textView.string
        default: break
        }
        if handOn, !pad.ink.isEmpty { r.ink = pad.ink }
        return r
    }

    /// 参考答案那一块的 Markdown：填空每空一行（另外认可的写法跟在后面）；主观题就是参考答案正文。没有 → nil。
    static func referenceMarkdown(_ e: Exercise) -> String? {
        switch e.kind {
        case .fill:
            guard e.hasAnswer else { return nil }
            return (0..<e.blankCount).map { i in
                let forms = e.acceptedForms(blank: i)
                var s = forms.first ?? ""
                if forms.count > 1 {
                    s = String(format: L("%@ (also accepted: %@)"), s, forms.dropFirst().joined(separator: " / "))
                }
                return "- " + String(format: L("Blank %d: %@"), i + 1, s)
            }.joined(separator: "\n")
        case .subjective: return e.referenceText
        default: return nil
        }
    }

    private func makeBlanks(_ n: Int) {
        guard blankFields.count != n else { return }
        for v in blankLabels + blankFields + blankMarks as [NSView] { v.removeFromSuperview() }
        blankLabels = (0..<n).map { i in
            let l = NSTextField(labelWithString: String(format: L("Blank %d"), i + 1))
            l.font = .systemFont(ofSize: 14, weight: .semibold)
            l.textColor = .labelColor
            return l
        }
        blankFields = (0..<n).map { _ in
            let f = NSTextField(string: "")
            f.font = .systemFont(ofSize: 15)
            f.bezelStyle = .roundedBezel
            f.delegate = self
            f.lineBreakMode = .byTruncatingTail
            return f
        }
        blankMarks = (0..<n).map { _ in
            let m = NSImageView()
            m.symbolConfiguration = .init(pointSize: 16, weight: .regular)
            return m
        }
        for (i, f) in blankFields.enumerated() where i + 1 < n { f.nextKeyView = blankFields[i + 1] }
        for v in blankLabels + blankFields + blankMarks as [NSView] { addSubview(v) }
    }

    private func refreshControls() {
        let fill = kind == .fill
        textScroll.isHidden = fill || locked
        placeholder.isHidden = textScroll.isHidden || !textView.string.isEmpty
        handButton.isHidden = locked
        for v in [toolControl, undoButton, clearButton, growButton] as [NSView] { v.isHidden = locked || !handOn }
        pad.isHidden = !handOn
        undoButton.isEnabled = pad.canUndo
        clearButton.isEnabled = !pad.ink.isEmpty
        growButton.isEnabled = pad.canGrow
        mineTitle.isHidden = !locked || mineText.isEmpty
        mineView.isHidden = mineTitle.isHidden
        refTitle.isHidden = !locked || refText == nil
        refView.isHidden = refTitle.isHidden
    }

    private func heightMayChange() {
        needsLayout = true
        onHeightChange()
    }

    // MARK: - 操作

    @objc private func toggleHand() {
        handOn = handButton.state == .on
        UserDefaults.standard.set(handOn, forKey: Self.handKey)
        refreshControls()
        heightMayChange()
        onEdit()
    }

    @objc private func toolChanged() { pad.tool = toolControl.selectedSegment == 1 ? .eraser : .pen }
    @objc private func undoInk() { pad.undo() }
    @objc private func clearInk() { pad.clear() }
    @objc private func growInk() { pad.grow() }

    private func inkChanged() {
        refreshControls()
        heightMayChange()
        onEdit()
    }

    func controlTextDidChange(_ obj: Notification) { onEdit() }

    /// 填空框里按回车：跳到下一空；最后一空 = 提交。
    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        guard sel == #selector(NSResponder.insertNewline(_:)), let f = control as? NSTextField,
              let i = blankFields.firstIndex(of: f) else { return false }
        if i + 1 < blankFields.count { window?.makeFirstResponder(blankFields[i + 1]) } else { onSubmit() }
        return true
    }

    func textDidChange(_ notification: Notification) {
        placeholder.isHidden = !textView.string.isEmpty
        fitTextHeight()
        onEdit()
    }

    /// 输入框随内容长高：约四行起步，最多 320，超出框内滚。
    private func fitTextHeight() {
        guard let lm = textView.layoutManager, let tc = textView.textContainer else { return }
        lm.ensureLayout(for: tc)
        let h = min(320, max(96, lm.usedRect(for: tc).height + 14))
        if abs(h - textHeight) > 0.5 { textHeight = h; heightMayChange() }
    }

    // MARK: - 排版

    func height(forWidth w: CGFloat) -> CGFloat { arrange(width: w, apply: false) }

    override func layout() {
        super.layout()
        _ = arrange(width: bounds.width, apply: true)
    }

    private func arrange(width w: CGFloat, apply: Bool) -> CGFloat {
        func put(_ v: NSView, _ r: NSRect) { if apply { v.frame = r } }
        var y: CGFloat = 0
        // 填空：一空一行
        let labelW: CGFloat = 64, markW: CGFloat = 26
        for i in blankFields.indices {
            put(blankLabels[i], NSRect(x: 0, y: y + 4, width: labelW, height: 18))
            put(blankFields[i], NSRect(x: labelW + 4, y: y, width: max(60, w - labelW - 4 - markW), height: 26))
            put(blankMarks[i], NSRect(x: w - 20, y: y + 3, width: 20, height: 20))
            y += 34
        }
        if !blankFields.isEmpty { y += 4 }
        // 主观题：输入框 / 交卷后的「你的作答」
        if !textScroll.isHidden {
            put(textScroll, NSRect(x: 0, y: y, width: w, height: textHeight))
            put(placeholder, NSRect(x: 9, y: y + 7, width: max(0, w - 18), height: 20))
            y += textHeight + 10
        }
        if !mineView.isHidden {
            put(mineTitle, NSRect(x: 0, y: y, width: w, height: 20))
            y += 26
            let h = mineView.intrinsicContentSize.height
            put(mineView, NSRect(x: 0, y: y, width: w, height: h))
            y += h + 12
        }
        // 手写：开关 + 工具一行，下面画板
        if !handButton.isHidden {
            var x: CGFloat = 0
            for b in [handButton, toolControl, undoButton, clearButton, growButton] as [NSControl] where !b.isHidden {
                b.sizeToFit()
                put(b, NSRect(x: x, y: y, width: b.frame.width, height: b.frame.height))
                x += b.frame.width + (b === handButton ? 14 : 6)
            }
            y += 34
        }
        if !pad.isHidden {
            let h = pad.height(forWidth: w)
            put(pad, NSRect(x: 0, y: y, width: w, height: h))
            y += h + 12
        }
        if !refView.isHidden {
            put(refTitle, NSRect(x: 0, y: y, width: w, height: 20))
            y += 26
            let h = refView.intrinsicContentSize.height
            put(refView, NSRect(x: 0, y: y, width: w, height: h))
            y += h + 6
        }
        return y
    }
}
