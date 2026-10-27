import AppKit

/// 题目笔记（`EXERCISE-PLAN.md §12.1`）：练习页上**判完才出现**（同解析，用户 2026-10-27 定——重做错题时笔记先把答案剧透了），
/// 摆在解析下面。
/// - 没写过：只有一个「添加笔记」按钮。
/// - 写过：「笔记」标题 + 渲染好的笔记（Markdown + `$…$`，Markdown 引擎只读渲染，红线 ② 那一处例外）+「编辑笔记」。
/// - 编辑：多行输入框（随内容长高到 320 点）+「完成」。**边写边存**：停手一会儿就存一次，「完成」/ ⌘Return / Esc 收起时、
///   输入框失去焦点时、换题或切走标签时都先存下，写了一半的不丢。
/// 排版同作答区：按 frame 手摆，`height(forWidth:)` 与 `layout()` 走同一个 `arrange`。
@MainActor
final class ExerciseNoteView: NSView, NSTextViewDelegate {
    /// 高度变了（练习页整列重摆）。
    var onHeightChange: () -> Void = {}
    /// 存这道题的笔记（原文，去首尾空白和「没变不写」由执行层做）。
    var onSave: (_ exerciseId: String, _ text: String) -> Void = { _, _ in }
    /// 收起了输入框（练习页把键盘焦点拿回去：← → / Return 下一题）。
    var onEndEditing: () -> Void = {}

    private let title = NSTextField(labelWithString: L("Notes"))
    private let rendered = AgentMarkdownView(text: "", fontSize: 14, documentId: "exercise-note")
    private let editButton = NSButton()
    private let textScroll = NSScrollView()
    private let textView = NSTextView()
    private let placeholder = NSTextField(labelWithString: L("Write a note for this question. Use $…$ for formulas."))
    private let doneButton = NSButton()
    private var textHeight: CGFloat = 96

    /// 显示的是哪道题的笔记。
    private(set) var exerciseId = ""
    /// 库里的笔记（渲染的就是它）。
    private var note = ""
    private var renderedText = ""
    /// 输入框开着。
    private(set) var isEditing = false
    /// 最近一次交出去存的（同一段话不重复存）。
    private var savedText = ""
    private var pendingSave: DispatchWorkItem?
    /// 停手多久存一次。
    private static let saveDelay: TimeInterval = 0.8

    init() {
        super.init(frame: .zero)
        title.font = .preferredFont(forTextStyle: .headline)
        title.textColor = .labelColor
        rendered.onHeightChange = { [weak self] in self?.heightMayChange() }
        setup(editButton, symbol: "square.and.pencil", title: L("Add a Note"), action: #selector(beginEditing))
        setup(doneButton, symbol: nil, title: L("Done"), action: #selector(finishEditing))
        doneButton.keyEquivalent = "\r"
        doneButton.keyEquivalentModifierMask = .command
        textScroll.hasVerticalScroller = true
        textScroll.borderType = .bezelBorder
        textScroll.autohidesScrollers = true
        textView.isRichText = false
        textView.allowsUndo = true
        textView.font = .systemFont(ofSize: 14)
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
        placeholder.font = .systemFont(ofSize: 14)
        placeholder.textColor = .placeholderTextColor
        for v in [title, rendered, editButton, textScroll, placeholder, doneButton] as [NSView] { addSubview(v) }
        refreshControls()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) 不支持") }

    override var isFlipped: Bool { true }

    private func setup(_ b: NSButton, symbol: String?, title: String, action: Selector) {
        b.bezelStyle = .push
        b.title = title
        if let symbol { b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil); b.imagePosition = .imageLeading }
        b.target = self
        b.action = action
        b.contentTintColor = .labelColor
    }

    // MARK: - 显示

    /// 显示这道题的笔记。换了题而输入框还开着：先把上一题写的存下、收起。
    /// 同一道题、正在写：库里的变了（自己刚存的，或 Agent 改的）也不动输入框里的字。
    func show(note: String, exerciseId id: String) {
        if id != exerciseId { commit() }
        exerciseId = id
        self.note = note
        guard !isEditing else { return }
        if note != renderedText { renderedText = note; rendered.update(text: note) }
        refreshControls()
        heightMayChange()
    }

    /// 输入框开着就存下并收起（换题 / 这一块要藏起来 / 切走标签前调）。
    func commit() {
        guard isEditing else { return }
        flush()
        isEditing = false
        note = savedText
        if note != renderedText { renderedText = note; rendered.update(text: note) }
        refreshControls()
        heightMayChange()
    }

    /// 切走标签（整个练习页被拆掉）/ 关窗：写着的先存下。
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { commit() }
        super.viewWillMove(toWindow: newWindow)
    }

    private func refreshControls() {
        let has = !note.isEmpty
        title.isHidden = !(isEditing || has)
        rendered.isHidden = isEditing || !has
        editButton.isHidden = isEditing
        editButton.title = has ? L("Edit Note") : L("Add a Note")
        textScroll.isHidden = !isEditing
        doneButton.isHidden = !isEditing
        placeholder.isHidden = !isEditing || !textView.string.isEmpty
    }

    private func heightMayChange() {
        needsLayout = true
        onHeightChange()
    }

    // MARK: - 编辑

    @objc private func beginEditing() {
        guard !isEditing, !exerciseId.isEmpty else { return }
        isEditing = true
        savedText = note
        textView.string = note
        textView.undoManager?.removeAllActions()
        fitTextHeight()
        refreshControls()
        heightMayChange()
        window?.makeFirstResponder(textView)
        textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))
    }

    @objc private func finishEditing() {
        guard isEditing else { return }
        commit()
        onEndEditing()
    }

    /// 写着的交出去存（和上次存的一样就不交）。
    private func flush() {
        pendingSave?.cancel()
        pendingSave = nil
        let t = textView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isEditing, !exerciseId.isEmpty, t != savedText else { return }
        savedText = t
        onSave(exerciseId, t)
    }

    func textDidChange(_ notification: Notification) {
        placeholder.isHidden = !textView.string.isEmpty
        fitTextHeight()
        pendingSave?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.flush() }
        pendingSave = w
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.saveDelay, execute: w)
    }

    /// 点到别处（输入框不再是焦点）：先存下，输入框照旧开着。
    func textDidEndEditing(_ notification: Notification) { flush() }

    /// Esc 收起（字已经存了，没有「取消」——要改回去用 ⌘Z）。
    func textView(_ textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        if sel == #selector(NSResponder.cancelOperation(_:)) || sel == #selector(NSTextView.complete(_:)) {
            finishEditing()
            return true
        }
        return false
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
        if !title.isHidden {
            put(title, NSRect(x: 0, y: y, width: w, height: 20))
            y += 26
        }
        if !rendered.isHidden {
            let h = rendered.intrinsicContentSize.height
            put(rendered, NSRect(x: 0, y: y, width: w, height: h))
            y += h + 10
        }
        if !textScroll.isHidden {
            put(textScroll, NSRect(x: 0, y: y, width: w, height: textHeight))
            put(placeholder, NSRect(x: 9, y: y + 7, width: max(0, w - 18), height: 20))
            y += textHeight + 10
        }
        for b in [editButton, doneButton] where !b.isHidden {
            b.sizeToFit()
            put(b, NSRect(x: 0, y: y, width: max(b === doneButton ? 96 : 0, b.frame.width), height: b.frame.height))
            y += b.frame.height
        }
        return y
    }
}
