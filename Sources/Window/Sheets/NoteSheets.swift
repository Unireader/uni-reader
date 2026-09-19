import AppKit
import Combine
import SwiftUI

// 批注 / 图片笔记的编辑弹窗与看大图（AppKit 版，替代 SwiftUI `NoteEditorSheet` / `ImageNoteEditorSheet` / `ImageViewerSheet`
// / `NoteTypeManagerView`）。唯一的 SwiftUI 是 Markdown 编辑区本身：`swift-markdown-engine` 只公开了 SwiftUI 包装
// （`NativeTextViewWrapper`），由 `MarkdownEditorHost` 托管——方案允许保留的那一块。
// 一律以 sheet 弹出：⌘↩ 保存（编辑框里回车是换行）、Esc 取消。

// MARK: - Markdown 编辑区（托管 SwiftUI 的那一块）

final class MarkdownTextBox: ObservableObject {
    @Published var text: String
    init(_ text: String) { self.text = text }
}

private struct MarkdownEditorRoot: View {
    @ObservedObject var box: MarkdownTextBox
    let documentId: String
    let placeholder: String
    var body: some View {
        MarkdownNoteEditor(text: $box.text, documentId: documentId, placeholder: placeholder)
    }
}

/// 笔记正文 / 图片说明的编辑框（引擎的 `NativeTextViewWrapper`，经 `MarkdownNoteEditor` 配好排版与公式）。
final class MarkdownEditorHost: NSView {
    let box: MarkdownTextBox
    private let host: NSHostingView<MarkdownEditorRoot>

    var text: String { box.text }

    init(text: String, documentId: String, placeholder: String) {
        box = MarkdownTextBox(text)
        host = NSHostingView(rootView: MarkdownEditorRoot(box: box, documentId: documentId, placeholder: placeholder))
        host.sizingOptions = []   // 尺寸归外面给的 frame，别让 SwiftUI 的理想尺寸反过来撑窗口
        super.init(frame: .zero)
        addSubview(host)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) 不支持") }

    override func layout() {
        super.layout()
        host.frame = bounds
    }
}

// MARK: - 小工具

/// 弹窗里的几样通用小控件。
enum SheetKit {
    static func headline(_ s: String) -> NSTextField {
        let t = NSTextField(labelWithString: s)
        t.font = .preferredFont(forTextStyle: .headline)
        return t
    }

    static func secondary(_ s: String) -> NSTextField {
        let t = NSTextField(labelWithString: s)
        t.font = .preferredFont(forTextStyle: .callout)
        t.textColor = .secondaryLabelColor
        return t
    }

    static func spacer() -> NSView {
        let v = NSView()
        v.setContentHuggingPriority(.init(1), for: .horizontal)
        return v
    }

    static func hrow(_ views: [NSView], width: CGFloat, spacing: CGFloat = 8) -> NSStackView {
        let r = NSStackView(views: views)
        r.spacing = spacing
        r.translatesAutoresizingMaskIntoConstraints = false
        r.widthAnchor.constraint(equalToConstant: width).isActive = true
        return r
    }

    static func fixed(_ v: NSView, width: CGFloat? = nil, height: CGFloat? = nil) -> NSView {
        v.translatesAutoresizingMaskIntoConstraints = false
        if let width { v.widthAnchor.constraint(equalToConstant: width).isActive = true }
        if let height { v.heightAnchor.constraint(equalToConstant: height).isActive = true }
        return v
    }

    /// 「展开方式」三选一（点开 / 悬停 / 始终）。
    static func displayControl(_ d: NoteDisplay) -> NSSegmentedControl {
        let c = NSSegmentedControl(labels: [L("On tap"), L("On hover"), L("Always")], trackingMode: .selectOne,
                                   target: nil, action: nil)
        c.selectedSegment = [NoteDisplay.tap, .hover, .always].firstIndex(of: d) ?? 0
        return c
    }

    static func display(of c: NSSegmentedControl) -> NoteDisplay {
        [NoteDisplay.tap, .hover, .always][max(0, min(2, c.selectedSegment))]
    }

    /// 底部按钮：取消（Esc）+ 主按钮（⌘↩，强调色）。
    static func cancelButton(_ target: AnyObject, _ action: Selector) -> NSButton {
        let b = NSButton(title: L("Cancel"), target: target, action: action)
        b.keyEquivalent = "\u{1b}"
        return b
    }

    static func primaryButton(_ title: String, _ target: AnyObject, _ action: Selector) -> NSButton {
        let b = NSButton(title: title, target: target, action: action)
        b.keyEquivalent = "\r"
        b.keyEquivalentModifierMask = .command
        b.bezelColor = .controlAccentColor
        return b
    }

    /// 实心色点图（弹出菜单项的图标用）。
    static func dot(_ color: NSColor, size: CGFloat = 10) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: false) { r in
            color.setFill()
            NSBezierPath(ovalIn: r).fill()
            return true
        }
    }
}

// MARK: - 批注编辑器

/// 文字注解编辑器（新建 / 编辑复用）：被注解的原文（只读引文）+ Markdown 编辑区 + 类型选择（含「管理类型…」）
/// + 选区注解才有的「标记」行（色点：第一枚 = 跟随类型色 + 铺色 / 画线 / 画框）+ 展开方式。
final class NoteEditorController: StackPanelController {
    struct Config {
        var quote: String
        var initialText: String
        var initialTypeId: UUID?
        var initialDisplay: NoteDisplay = .tap
        var initialColor: InkColor?
        var initialStyle: HighlightStyle = .fill
        var hasRects = true
        var documentId = "note-draft"
        var noteTypes: [NoteType]
        var usageCount: (UUID) -> Int
        var saveTitle = L("Save")
        var onSave: (NoteEditorOutput) -> Void
        var onDelete: (() -> Void)?
        var onChangeTypes: ([NoteType]) -> Void
        var onCancel: () -> Void
    }

    private var cfg: Config
    private var typeId: UUID?
    private var color: InkColor?
    private var editor: MarkdownEditorHost!
    private let typePopup = NSPopUpButton(frame: .zero, pullsDown: true)
    private var colorDots: [(InkColor?, SwatchButton)] = []
    private let styleControl = NSSegmentedControl()
    private var displayControl: NSSegmentedControl!
    private let actions = ButtonActions()

    init(_ cfg: Config) {
        self.cfg = cfg
        typeId = cfg.initialTypeId
        color = cfg.initialColor
        super.init(width: 640, inset: 16)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) 不支持") }

    private var current: NoteType { NoteType.resolve(typeId, in: cfg.noteTypes) }
    private var inner: CGFloat { width - inset * 2 }

    override func viewDidLoad() {
        super.viewDidLoad()
        stack.spacing = 12
        typePopup.isBordered = false
        typePopup.setContentHuggingPriority(.required, for: .horizontal)
        rebuildTypeMenu()
        stack.addArrangedSubview(SheetKit.hrow([SheetKit.headline(L("Note")), SheetKit.spacer(), typePopup], width: inner))

        if !cfg.quote.isEmpty {
            let q = NSTextField(wrappingLabelWithString: cfg.quote)
            q.font = NSFontManager.shared.convert(.preferredFont(forTextStyle: .callout), toHaveTrait: .italicFontMask)
            q.textColor = .secondaryLabelColor
            q.maximumNumberOfLines = 4
            q.lineBreakMode = .byTruncatingTail
            q.preferredMaxLayoutWidth = inner - 16
            let box = NSView()
            box.wantsLayer = true
            box.layer?.cornerRadius = 6
            box.layer?.backgroundColor = NSColor.quaternaryLabelColor.withAlphaComponent(0.25).cgColor
            q.translatesAutoresizingMaskIntoConstraints = false
            box.addSubview(q)
            NSLayoutConstraint.activate([
                q.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 8),
                q.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -8),
                q.topAnchor.constraint(equalTo: box.topAnchor, constant: 8),
                q.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -8),
            ])
            stack.addArrangedSubview(SheetKit.fixed(box, width: inner))
        }

        // 编辑框：sheet 满宽 × 340（原来 380×170，写几行公式就挤得没法输入，用户 2026-09-16 报）
        editor = MarkdownEditorHost(text: cfg.initialText, documentId: cfg.documentId, placeholder: L("Write a note… (Markdown)"))
        stack.addArrangedSubview(SheetKit.fixed(editor, width: inner, height: 340))

        if cfg.hasRects {
            var row: [NSView] = [SheetKit.secondary(L("Mark"))]
            let typeDot = SwatchButton(color: current.nsColor)
            typeDot.toolTip = L("Type color")
            colorDots.append((nil, typeDot))
            for item in Highlight.palette {
                let b = SwatchButton(color: item.color.nsColor)
                b.toolTip = L(item.name)
                colorDots.append((item.color, b))
            }
            for (value, b) in colorDots {
                actions.bind(b) { [weak self] in
                    self?.color = value
                    self?.refreshDots()
                }
                row.append(b)
            }
            row.append(SheetKit.spacer())
            styleControl.segmentCount = HighlightStyle.allCases.count
            styleControl.trackingMode = .selectOne
            for (i, s) in HighlightStyle.allCases.enumerated() {
                styleControl.setImage(NSImage(systemSymbolName: s.iconName, accessibilityDescription: s.title), forSegment: i)
                styleControl.setToolTip(s.title, forSegment: i)
            }
            styleControl.selectedSegment = HighlightStyle.allCases.firstIndex(of: cfg.initialStyle) ?? 0
            row.append(styleControl)
            stack.addArrangedSubview(SheetKit.hrow(row, width: inner))
            refreshDots()
        }

        displayControl = SheetKit.displayControl(cfg.initialDisplay)
        stack.addArrangedSubview(SheetKit.hrow([SheetKit.secondary(L("Show note")), displayControl, SheetKit.spacer()], width: inner))

        var buttons: [NSView] = []
        if cfg.onDelete != nil {
            let del = NSButton(title: L("Delete"), target: self, action: #selector(deleteTapped))
            del.hasDestructiveAction = true
            buttons.append(del)
        }
        buttons += [SheetKit.spacer(), SheetKit.cancelButton(self, #selector(cancelTapped)),
                    SheetKit.primaryButton(cfg.saveTitle, self, #selector(saveTapped))]
        stack.addArrangedSubview(SheetKit.hrow(buttons, width: inner))
        resize()
        view.setFrameSize(preferredContentSize)
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        MarkdownNoteEditor.focusEditor()   // 打开编辑器就把光标放进去
    }

    private func refreshDots() {
        for (value, b) in colorDots { b.selectedRing = value == color }
    }

    /// 类型选择：通用恒为第一项；按钮上显示当前类型色点 + 名称；底部「管理类型…」。
    private func rebuildTypeMenu() {
        let m = NSMenu()
        let head = NSMenuItem(title: current.id == NoteType.generalID ? L("General") : current.name, action: nil, keyEquivalent: "")
        head.image = SheetKit.dot(current.nsColor)
        m.addItem(head)   // 下拉式按钮的第一项 = 按钮上显示的那一项
        let general = ClosureMenuItem(L("General"), action: { [weak self] in self?.setType(nil) })
        general.image = NSImage(systemSymbolName: NoteType.general.iconName, accessibilityDescription: nil)
        m.addItem(general)
        for t in cfg.noteTypes {
            let it = ClosureMenuItem(t.name, action: { [weak self] in self?.setType(t.id) })
            it.image = NSImage(systemSymbolName: t.icon, accessibilityDescription: nil)
            m.addItem(it)
        }
        m.addItem(.separator())
        m.addItem(ClosureMenuItem(L("Manage Types…"), action: { [weak self] in self?.manageTypes() }))
        typePopup.menu = m
    }

    private func setType(_ id: UUID?) {
        typeId = id
        rebuildTypeMenu()
        if let first = colorDots.first?.1 {   // 「跟随类型色」那枚色点换成新类型的颜色
            let b = SwatchButton(color: current.nsColor)
            b.toolTip = first.toolTip
            b.selectedRing = color == nil
            actions.bind(b) { [weak self] in
                self?.color = nil
                self?.refreshDots()
            }
            first.superview.flatMap { $0 as? NSStackView }?.insertArrangedSubview(b, at: 1)
            first.removeFromSuperview()
            colorDots[0] = (nil, b)
        }
    }

    private func manageTypes() {
        let vc = NoteTypeManagerController(noteTypes: cfg.noteTypes, usageCount: cfg.usageCount) { [weak self] types in
            guard let self else { return }
            self.cfg.onChangeTypes(types)
            self.cfg.noteTypes = types
            if let id = self.typeId, !types.contains(where: { $0.id == id }) { self.typeId = nil }
            self.rebuildTypeMenu()
            self.setType(self.typeId)
        }
        presentAsSheet(vc)
    }

    private var output: NoteEditorOutput {
        NoteEditorOutput(text: editor.text, typeId: typeId, display: SheetKit.display(of: displayControl), color: color,
                         style: cfg.hasRects ? HighlightStyle.allCases[max(0, styleControl.selectedSegment)] : cfg.initialStyle)
    }

    @objc private func saveTapped() { cfg.onSave(output) }
    @objc private func cancelTapped() { cfg.onCancel() }
    @objc private func deleteTapped() { cfg.onDelete?() }
}

// MARK: - 类型管理

/// 笔记类型管理（编辑器里「管理类型…」弹出）：列表 + 新建 / 编辑 / 删除。「通用」内置兜底不在列、不可改。
/// 改动经 `onChange` 整体回写（调用方负责落库 + 被删类型的笔记回落）。
final class NoteTypeManagerController: StackPanelController {
    private var noteTypes: [NoteType]
    private let usageCount: (UUID) -> Int
    private let onChange: ([NoteType]) -> Void
    private let list = NSStackView()
    private let actions = ButtonActions()

    init(noteTypes: [NoteType], usageCount: @escaping (UUID) -> Int, onChange: @escaping ([NoteType]) -> Void) {
        self.noteTypes = noteTypes
        self.usageCount = usageCount
        self.onChange = onChange
        super.init(width: 340, inset: 16)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) 不支持") }

    private var inner: CGFloat { width - inset * 2 }

    override func viewDidLoad() {
        super.viewDidLoad()
        stack.spacing = 12
        stack.addArrangedSubview(SheetKit.headline(L("Manage Types")))
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 8
        stack.addArrangedSubview(list)
        let add = NSButton(title: L("New Type"), target: self, action: #selector(newType))
        let done = NSButton(title: L("Done"), target: self, action: #selector(doneTapped))
        done.keyEquivalent = "\r"
        stack.addArrangedSubview(SheetKit.hrow([add, SheetKit.spacer(), done], width: inner))
        rebuild()
    }

    private func rebuild() {
        for v in list.arrangedSubviews { v.removeFromSuperview() }
        if noteTypes.isEmpty {
            list.addArrangedSubview(SheetKit.secondary(L("No custom types yet.")))
        }
        for t in noteTypes {
            let dot = NSImageView(image: SheetKit.dot(t.nsColor))
            let icon = NSImageView(image: NSImage(systemSymbolName: t.icon, accessibilityDescription: nil) ?? NSImage())
            icon.contentTintColor = .labelColor
            let name = NSTextField(labelWithString: t.name)
            name.lineBreakMode = .byTruncatingTail
            name.setContentCompressionResistancePriority(.init(1), for: .horizontal)
            let edit = iconButton("pencil", L("Edit Type")) { [weak self] in self?.editType(t, isNew: false) }
            let del = iconButton("trash", L("Delete")) { [weak self] in self?.confirmDelete(t) }
            list.addArrangedSubview(SheetKit.hrow([dot, SheetKit.fixed(icon, width: 16), name, SheetKit.spacer(), edit, del],
                                                  width: inner))
        }
        resize()
        view.window?.setContentSize(preferredContentSize)
    }

    private func iconButton(_ symbol: String, _ tip: String, _ h: @escaping () -> Void) -> NSButton {
        let b = NSButton()
        b.isBordered = false
        b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
        b.imagePosition = .imageOnly
        b.contentTintColor = .labelColor
        b.toolTip = tip
        actions.bind(b, h)
        return b
    }

    @objc private func newType() {
        editType(NoteType(name: "", colorKey: NoteType.palette[0].key, iconName: NoteType.iconCandidates[0]), isNew: true)
    }

    private func editType(_ t: NoteType, isNew: Bool) {
        let vc = NoteTypeEditController(draft: t, isNew: isNew) { [weak self] saved in
            guard let self else { return }
            if let i = self.noteTypes.firstIndex(where: { $0.id == saved.id }) { self.noteTypes[i] = saved }
            else { self.noteTypes.append(saved) }
            self.onChange(self.noteTypes)
            self.rebuild()
        }
        presentAsSheet(vc)
    }

    private func confirmDelete(_ t: NoteType) {
        guard let win = view.window else { return }
        let n = usageCount(t.id)
        let a = NSAlert()
        a.messageText = String(format: L("Delete type “%@”?"), t.name)
        if n > 0 { a.informativeText = String(format: L("%d note(s) will revert to General."), n) }
        a.addButton(withTitle: L("Delete")).hasDestructiveAction = true
        a.addButton(withTitle: L("Cancel"))
        a.beginSheetModal(for: win) { [weak self] resp in
            guard let self, resp == .alertFirstButtonReturn else { return }
            self.noteTypes.removeAll { $0.id == t.id }
            self.onChange(self.noteTypes)
            self.rebuild()
        }
    }

    @objc private func doneTapped() { dismiss(self) }
}

/// 单个类型的新建 / 编辑：名称 + 固定色板 + 图标网格。名称为空禁存。
final class NoteTypeEditController: StackPanelController, NSTextFieldDelegate {
    private var draft: NoteType
    private let isNew: Bool
    private let onDone: (NoteType) -> Void
    private let name = NSTextField()
    private var swatches: [(String, SwatchButton)] = []
    private var icons: [(String, NSButton)] = []
    private var save: NSButton!
    private let actions = ButtonActions()

    init(draft: NoteType, isNew: Bool, onDone: @escaping (NoteType) -> Void) {
        self.draft = draft
        self.isNew = isNew
        self.onDone = onDone
        super.init(width: 320, inset: 16)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) 不支持") }

    private var inner: CGFloat { width - inset * 2 }

    override func viewDidLoad() {
        super.viewDidLoad()
        stack.spacing = 12
        stack.addArrangedSubview(SheetKit.headline(isNew ? L("New Type") : L("Edit Type")))
        name.stringValue = draft.name
        name.placeholderString = L("Type Name")
        name.delegate = self
        stack.addArrangedSubview(SheetKit.fixed(name, width: inner))
        var dots: [NSView] = []
        for sw in NoteType.palette {
            let b = SwatchButton(color: NSColor(srgbRed: sw.r / 255, green: sw.g / 255, blue: sw.b / 255, alpha: 1))
            let key = sw.key
            actions.bind(b) { [weak self] in
                self?.draft.colorKey = key
                self?.refresh()
            }
            swatches.append((key, b))
            dots.append(b)
        }
        let dotRow = NSStackView(views: dots)
        dotRow.spacing = 8
        stack.addArrangedSubview(dotRow)
        let grid = NSGridView()
        grid.rowSpacing = 8
        grid.columnSpacing = 8
        var row: [NSView] = []
        for name in NoteType.iconCandidates {
            let b = NSButton()
            b.isBordered = false
            b.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
            b.imagePosition = .imageOnly
            b.contentTintColor = .labelColor
            b.wantsLayer = true
            b.layer?.cornerRadius = 6
            _ = SheetKit.fixed(b, width: 28, height: 28)
            actions.bind(b) { [weak self] in
                self?.draft.iconName = name
                self?.refresh()
            }
            icons.append((name, b))
            row.append(b)
            if row.count == 8 { grid.addRow(with: row); row = [] }
        }
        if !row.isEmpty { grid.addRow(with: row) }
        stack.addArrangedSubview(grid)
        save = SheetKit.primaryButton(L("Save"), self, #selector(saveTapped))
        save.keyEquivalentModifierMask = []
        stack.addArrangedSubview(SheetKit.hrow([SheetKit.spacer(), SheetKit.cancelButton(self, #selector(cancelTapped)), save],
                                               width: inner))
        refresh()
        resize()
        view.setFrameSize(preferredContentSize)
    }

    private func refresh() {
        for (k, b) in swatches { b.selectedRing = k == draft.colorKey }
        for (n, b) in icons {
            b.layer?.backgroundColor = n == draft.iconName ? NSColor.controlAccentColor.withAlphaComponent(0.25).cgColor : nil
        }
        save?.isEnabled = !name.stringValue.trimmingCharacters(in: .whitespaces).isEmpty
    }

    func controlTextDidChange(_ obj: Notification) { refresh() }

    @objc private func saveTapped() {
        draft.name = name.stringValue
        onDone(draft)
        dismiss(self)
    }
    @objc private func cancelTapped() { dismiss(self) }
}

// MARK: - 图片笔记编辑器

/// 缩略图 + 来源一行 + 说明（Markdown）+ 展开方式；删除 / 看原图在左下。
final class ImageNoteEditorController: StackPanelController {
    private let note: ImageNote
    private let info: (url: URL, size: CGSize)?
    private let onSave: (String, NoteDisplay) -> Void
    private let onDelete: () -> Void
    private let onView: () -> Void
    private let onCancel: () -> Void
    private var editor: MarkdownEditorHost!
    private var displayControl: NSSegmentedControl!
    private let preview = NSImageView()
    private var bag = Set<AnyCancellable>()

    init(note: ImageNote, info: (url: URL, size: CGSize)?, onSave: @escaping (String, NoteDisplay) -> Void,
         onDelete: @escaping () -> Void, onView: @escaping () -> Void, onCancel: @escaping () -> Void) {
        self.note = note
        self.info = info
        self.onSave = onSave
        self.onDelete = onDelete
        self.onView = onView
        self.onCancel = onCancel
        super.init(width: 420, inset: 16)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) 不支持") }

    private var inner: CGFloat { width - inset * 2 }

    override func viewDidLoad() {
        super.viewDidLoad()
        stack.spacing = 12
        let src = SheetKit.secondary(note.sourceLabel)
        src.lineBreakMode = .byTruncatingTail
        src.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        stack.addArrangedSubview(SheetKit.hrow([SheetKit.headline(L("Image Note")), SheetKit.spacer(), src], width: inner))
        preview.imageScaling = .scaleProportionallyDown
        preview.wantsLayer = true
        preview.layer?.cornerRadius = 6
        preview.layer?.backgroundColor = NSColor.quaternaryLabelColor.withAlphaComponent(0.25).cgColor
        stack.addArrangedSubview(SheetKit.fixed(preview, width: inner, height: 220))
        refreshPreview()
        ImageThumbCache.shared.objectWillChange.receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshPreview() }.store(in: &bag)
        editor = MarkdownEditorHost(text: note.caption, documentId: note.id.uuidString, placeholder: L("Caption… (Markdown)"))
        stack.addArrangedSubview(SheetKit.fixed(editor, width: 380, height: 100))
        displayControl = SheetKit.displayControl(note.display)
        stack.addArrangedSubview(SheetKit.hrow([SheetKit.secondary(L("Show note")), displayControl, SheetKit.spacer()], width: inner))
        let del = NSButton(title: L("Delete"), target: self, action: #selector(deleteTapped))
        del.hasDestructiveAction = true
        let view = NSButton(title: L("View Full Size"), target: self, action: #selector(viewTapped))
        view.isEnabled = info != nil
        stack.addArrangedSubview(SheetKit.hrow([del, view, SheetKit.spacer(), SheetKit.cancelButton(self, #selector(cancelTapped)),
                                                SheetKit.primaryButton(L("Save"), self, #selector(saveTapped))], width: inner))
        resize()
        self.view.setFrameSize(preferredContentSize)
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        MarkdownNoteEditor.focusEditor()
    }

    private func refreshPreview() {
        if let info, let cg = ImageThumbCache.shared.image(url: info.url, maxPixel: 1024) {
            preview.image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
            preview.imageScaling = .scaleProportionallyDown
        } else {
            preview.image = NSImage(systemSymbolName: info == nil ? "photo.badge.exclamationmark" : "photo",
                                    accessibilityDescription: nil)?.withSymbolConfiguration(.init(textStyle: .largeTitle))
            preview.contentTintColor = .secondaryLabelColor
        }
    }

    @objc private func saveTapped() { onSave(editor.text, SheetKit.display(of: displayControl)) }
    @objc private func cancelTapped() { onCancel() }
    @objc private func deleteTapped() { onDelete() }
    @objc private func viewTapped() { onView() }
}

// MARK: - 看大图

/// 原图等比铺满（窗口 = 屏幕的 70%，图小于窗口时按原像素显示不放大）+ 复制图片 / 在访达中显示 / 关闭。
final class ImageViewerController: NSViewController {
    private let note: ImageNote
    private let url: URL
    private let onClose: () -> Void
    private let imageView = NSImageView()
    private let sizeLabel = SheetKit.secondary("")
    private let spinner = NSProgressIndicator()
    private var image: CGImage?
    private var copyButton: NSButton!

    init(note: ImageNote, url: URL, onClose: @escaping () -> Void) {
        self.note = note
        self.url = url
        self.onClose = onClose
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) 不支持") }

    override func loadView() {
        let screen = NSScreen.main?.visibleFrame.size ?? CGSize(width: 1200, height: 800)
        let size = NSSize(width: screen.width * 0.7, height: screen.height * 0.7)
        let root = NSView(frame: NSRect(origin: .zero, size: size))
        let title = SheetKit.headline(note.caption.isEmpty ? note.sourceLabel : note.caption)
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        imageView.imageScaling = .scaleProportionallyDown   // 小图按原像素显示，不拉大
        spinner.style = .spinning
        spinner.startAnimation(nil)
        copyButton = NSButton(title: L("Copy Image"), target: self, action: #selector(copyImage))
        copyButton.isEnabled = false
        let finder = NSButton(title: L("Show in Finder"), target: self, action: #selector(showInFinder))
        let close = NSButton(title: L("Close"), target: self, action: #selector(closeTapped))
        close.keyEquivalent = "\u{1b}"
        let top = NSStackView(views: [title, SheetKit.spacer(), sizeLabel])
        let bottom = NSStackView(views: [copyButton, finder, SheetKit.spacer(), close])
        for v in [top, imageView, spinner, bottom] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        NSLayoutConstraint.activate([
            top.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            top.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            top.topAnchor.constraint(equalTo: root.topAnchor, constant: 16),
            bottom.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            bottom.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            bottom.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),
            imageView.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            imageView.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            imageView.topAnchor.constraint(equalTo: top.bottomAnchor, constant: 10),
            imageView.bottomAnchor.constraint(equalTo: bottom.topAnchor, constant: -10),
            spinner.centerXAnchor.constraint(equalTo: imageView.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: imageView.centerYAnchor),
            root.widthAnchor.constraint(equalToConstant: size.width),
            root.heightAnchor.constraint(equalToConstant: size.height),
        ])
        view = root
        let u = url
        Task.detached {
            let img = ImageAssets.load(u)
            await MainActor.run { [weak self] in self?.loaded(img) }
        }
    }

    private func loaded(_ img: CGImage?) {
        spinner.stopAnimation(nil)
        spinner.isHidden = true
        image = img
        guard let img else { return }
        let scale = view.window?.backingScaleFactor ?? 2
        imageView.image = NSImage(cgImage: img, size: NSSize(width: CGFloat(img.width) / scale, height: CGFloat(img.height) / scale))
        sizeLabel.stringValue = "\(img.width) × \(img.height)"
        copyButton.isEnabled = true
    }

    @objc private func copyImage() {
        guard let image else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        if let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) {
            pb.setData(data, forType: .png)
        }
    }
    @objc private func showInFinder() { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    @objc private func closeTapped() { onClose() }
}
