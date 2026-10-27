import AppKit

/// Agent 面板输入框上方的「排队中」（`AgentChat.queued`）：回答中按回车排上队的话，这一轮答完依次发出去。
/// 每条一行：带了几张图（放在前面，长句省略时也看得见）+ 话的第一行（太长省略）+「编辑」（退回输入框）/「移除」两个图标按钮。
///
/// 同 `AgentPlanView`：分组框只当底，里面按 frame 摆、对外只报高度（`preferredHeight`），由面板按 frame 摆它。
/// 离屏验证 `spike/agent-queue-view-test.swift`。
@MainActor
final class AgentQueueView: NSView {
    struct Item: Equatable {
        let id: UUID
        let text: String
        let images: Int
    }

    var onEdit: (UUID) -> Void = { _ in }
    var onRemove: (UUID) -> Void = { _ in }

    private let box = NSBox()
    private let header = NSTextField(labelWithString: L("Queued — sent after this reply"))
    private var rows: [(id: UUID, text: NSTextField, edit: NSButton, remove: NSButton)] = []
    private(set) var items: [Item] = []

    private static let padX: CGFloat = 10
    private static let padY: CGFloat = 6
    private static let headerH: CGFloat = 20
    private static let rowH: CGFloat = 24
    private static let buttonSide: CGFloat = 22

    init() {
        super.init(frame: .zero)
        box.titlePosition = .noTitle
        header.font = .systemFont(ofSize: NSFont.preferredFont(forTextStyle: .callout).pointSize, weight: .semibold)
        header.textColor = .labelColor
        header.lineBreakMode = .byTruncatingTail
        for v in [box, header] as [NSView] { addSubview(v) }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) 不支持") }

    override var isFlipped: Bool { true }

    var preferredHeight: CGFloat {
        items.isEmpty ? 0 : 2 * Self.padY + Self.headerH + CGFloat(items.count) * Self.rowH
    }

    /// 排队的内容变了才重建行（流式回复每个碎片都会叫一次面板刷新）。
    func update(_ items: [Item]) {
        guard items != self.items else { return }
        self.items = items
        for r in rows { r.text.removeFromSuperview(); r.edit.removeFromSuperview(); r.remove.removeFromSuperview() }
        rows = items.map { item in
            let firstLine = item.text.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? item.text
            let shown = item.images > 0 ? String(format: L("%d images"), item.images) + " · " + firstLine : firstLine
            let text = NSTextField(labelWithString: shown)
            text.font = .preferredFont(forTextStyle: .callout)
            text.textColor = .labelColor
            text.lineBreakMode = .byTruncatingTail
            text.toolTip = item.text
            let edit = button("pencil", L("Edit")) { [weak self] in self?.onEdit(item.id) }
            let remove = button("xmark", L("Remove")) { [weak self] in self?.onRemove(item.id) }
            for v in [text, edit, remove] as [NSView] { addSubview(v) }
            return (item.id, text, edit, remove)
        }
        needsLayout = true
    }

    private func button(_ symbol: String, _ tip: String, action: @escaping () -> Void) -> NSButton {
        let b = ClosureButton(action: action)
        b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
        b.imagePosition = .imageOnly
        b.isBordered = false
        b.contentTintColor = .labelColor   // 无边框按钮不设颜色会画得很淡
        b.toolTip = tip
        return b
    }

    override func layout() {
        super.layout()
        box.frame = bounds
        let w = bounds.width
        var y = Self.padY
        header.frame = NSRect(x: Self.padX, y: y + 1, width: max(0, w - 2 * Self.padX), height: Self.headerH - 2)
        y += Self.headerH
        let s = Self.buttonSide
        for r in rows {
            let removeX = w - Self.padX - s
            let editX = removeX - 2 - s
            r.remove.frame = NSRect(x: removeX, y: y + (Self.rowH - s) / 2, width: s, height: s)
            r.edit.frame = NSRect(x: editX, y: y + (Self.rowH - s) / 2, width: s, height: s)
            let th = ceil(r.text.intrinsicContentSize.height)
            r.text.frame = NSRect(x: Self.padX, y: y + (Self.rowH - th) / 2, width: max(0, editX - 6 - Self.padX), height: th)
            y += Self.rowH
        }
    }
}
