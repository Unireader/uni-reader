import AppKit

/// Agent 的计划（ACP `plan` 更新，Kimi 的待办清单）：系统分组框里「计划」一行 + 每项「状态图标 + 会折行的文字」。
///
/// 🔴 **别再写 `box.contentView = stack`**（2026-10-27 用户截图：二十来项的计划整片叠在上面的条目上）：
/// 那样 box 的内容视图走 autoresizing，里面的约束传不到 box 的高度上，box 只有一行字高，内容溢出去盖住别的条目
/// （权限卡片 2026-09-26 栽过同一个坑）。也别在对话记录条目里套 `NSStackView`（`AgentRowView` 那条）。
/// 所以这里**自己按 frame 摆、对外只报高度**：分组框只当底，铺满整块；宽度变了重算高度（文字会折行），
/// 计划更新就地换内容（`update`），不重建视图。离屏验证 `spike/agent-plan-view-test.swift`。
@MainActor
final class AgentPlanView: NSView {
    /// 高度变了（宽度变了重新折行 / 计划更新）：对话记录据此重新对齐滚动位置。
    var onHeightChange: (() -> Void)?
    private(set) var entries: [AgentPlanEntry]
    private let box = NSBox()
    private let title = NSTextField(labelWithString: L("Plan"))
    private var rows: [(icon: NSImageView, text: NSTextField)] = []
    private var height: CGFloat = 0

    private static let padX: CGFloat = 12
    private static let padY: CGFloat = 10
    private static let iconSide: CGFloat = 16
    private static let iconGap: CGFloat = 6
    private static let rowGap: CGFloat = 4
    private static let titleGap: CGFloat = 6

    init(entries: [AgentPlanEntry]) {
        self.entries = entries
        super.init(frame: .zero)
        box.titlePosition = .noTitle
        title.font = .systemFont(ofSize: NSFont.preferredFont(forTextStyle: .callout).pointSize, weight: .semibold)
        title.textColor = .labelColor
        for v in [box, title] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = true
            addSubview(v)
        }
        makeRows()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) 不支持") }

    override var isFlipped: Bool { true }

    /// 计划整体替换（Agent 每次推的都是完整清单）：内容没变不动，变了就地换行、重算高度。
    func update(_ entries: [AgentPlanEntry]) {
        guard entries != self.entries else { return }
        self.entries = entries
        for r in rows { r.icon.removeFromSuperview(); r.text.removeFromSuperview() }
        makeRows()
        remeasure()
        needsLayout = true
    }

    private func makeRows() {
        let font = NSFont.preferredFont(forTextStyle: .callout)
        rows = entries.map { e in
            let symbol: String
            switch e.status {
            case .pending: symbol = "circle"
            case .inProgress: symbol = "circle.lefthalf.filled"
            case .completed: symbol = "checkmark.circle"
            case .cancelled: symbol = "xmark.circle"
            }
            let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage())
            icon.symbolConfiguration = .init(textStyle: .callout)
            icon.contentTintColor = .labelColor
            let text = NSTextField(wrappingLabelWithString: e.text)
            text.font = font
            text.textColor = .labelColor
            for v in [icon, text] as [NSView] {
                v.translatesAutoresizingMaskIntoConstraints = true
                addSubview(v)
            }
            return (icon, text)
        }
    }

    // MARK: 尺寸

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: height) }

    /// 宽度由对话记录的约束给；宽度一变，文字折行跟着变，高度要重算。
    override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = newSize.width != frame.width
        super.setFrameSize(newSize)
        if widthChanged { remeasure() }
        needsLayout = true
    }

    private func remeasure() {
        guard bounds.width > 0 else { return }
        let h = arrange(width: bounds.width, apply: false)
        guard abs(h - height) > 0.5 else { return }
        height = h
        invalidateIntrinsicContentSize()
        onHeightChange?()
    }

    override func layout() {
        super.layout()
        _ = arrange(width: bounds.width, apply: true)
    }

    /// 按给定宽度从上往下排一遍，返回总高。`apply` = 真的设 frame（量高度时只算不摆）。
    private func arrange(width: CGFloat, apply: Bool) -> CGFloat {
        let inner = max(0, width - 2 * Self.padX)
        var y = Self.padY
        let th = ceil(title.intrinsicContentSize.height)
        if apply { title.frame = NSRect(x: Self.padX, y: y, width: inner, height: th) }
        y += th + Self.titleGap
        let textX = Self.padX + Self.iconSide + Self.iconGap
        let textW = max(0, width - textX - Self.padX)
        let font = NSFont.preferredFont(forTextStyle: .callout)
        let lineH = ceil(font.ascender - font.descender + font.leading)
        for (k, r) in rows.enumerated() {
            if r.text.preferredMaxLayoutWidth != textW { r.text.preferredMaxLayoutWidth = textW }
            let h = max(ceil(r.text.intrinsicContentSize.height), Self.iconSide)
            if apply {
                r.text.frame = NSRect(x: textX, y: y, width: textW, height: h)
                // 图标对齐第一行文字（多行的那项不居中到整段中间）
                r.icon.frame = NSRect(x: Self.padX, y: y + max(0, (lineH - Self.iconSide) / 2),
                                      width: Self.iconSide, height: Self.iconSide)
            }
            y += h + (k == rows.count - 1 ? 0 : Self.rowGap)
        }
        y += Self.padY
        if apply { box.frame = NSRect(x: 0, y: 0, width: width, height: bounds.height) }
        return ceil(y)
    }
}
