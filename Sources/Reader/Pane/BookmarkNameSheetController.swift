import AppKit

/// 书签命名框（新建 / 改名共用，AppKit 版，替代 SwiftUI `BookmarkNameSheet`）。
/// 名字**必填**（用户 2026-09-02）：空白时确定键是灰的。新建不预填（章节 · 页码只做占位提示），改名预填原名。
final class BookmarkNameSheetController: NSViewController, NSTextFieldDelegate {
    private let draft: BookmarkDraft
    private let onSave: (String) -> Void
    private let onCancel: () -> Void
    private let field = NSTextField()
    private let saveButton = NSButton()

    init(draft: BookmarkDraft, onSave: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
        self.draft = draft
        self.onSave = onSave
        self.onCancel = onCancel
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) 不支持") }

    private var isNew: Bool { draft.editing == nil }

    override func loadView() {
        let title = NSTextField(labelWithString: isNew ? L("Add Bookmark") : L("Rename Bookmark"))
        title.font = .preferredFont(forTextStyle: .headline)
        let hint = NSTextField(labelWithString: draft.hint)
        hint.font = .preferredFont(forTextStyle: .caption1)
        hint.textColor = .labelColor
        field.placeholderString = L("Bookmark name")
        field.stringValue = draft.currentTitle
        field.delegate = self
        field.widthAnchor.constraint(equalToConstant: 320).isActive = true
        let cancel = NSButton(title: L("Cancel"), target: self, action: #selector(cancelTapped))
        cancel.keyEquivalent = "\u{1b}"
        saveButton.title = isNew ? L("Add") : L("Save")
        saveButton.bezelStyle = .push
        saveButton.keyEquivalent = "\r"
        saveButton.target = self
        saveButton.action = #selector(saveTapped)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let buttons = NSStackView(views: [spacer, cancel, saveButton])
        let stack = NSStackView(views: [title, hint, field, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        buttons.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32).isActive = true
        stack.widthAnchor.constraint(equalToConstant: 360).isActive = true
        view = stack
        syncEnabled()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(field)
    }

    func controlTextDidChange(_ obj: Notification) { syncEnabled() }

    private func syncEnabled() { saveButton.isEnabled = Bookmark.validTitle(field.stringValue) }

    @objc private func saveTapped() {
        guard Bookmark.validTitle(field.stringValue) else { return }
        onSave(field.stringValue)
    }

    @objc private func cancelTapped() { onCancel() }
}
