import AppKit

// 阅读窗格上的几样小部件（AppKit 版，替代 `ReaderPane` 里的 SwiftUI 浮层）。
// 🔴 外观红线：只用系统材质与系统控件；材质底上的文字 / 图标一律主色（`labelColor`），层级差异用字号表达。

// MARK: - 材质胶囊（查找条 / 角标共用的底）

/// 系统材质 + 胶囊圆角 + 发丝描边。圆角跟着高度走（永远是胶囊）。
class CapsuleMaterialView: NSVisualEffectView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        material = .popover
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.masksToBounds = true   // 材质按胶囊裁（阴影要挂在外层视图上，裁剪层上的阴影画不出来）
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor.white.withAlphaComponent(0.15).cgColor
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) 不支持") }

    override func layout() {
        super.layout()
        layer?.cornerRadius = bounds.height / 2
    }
}

// MARK: - 查找状态条（Safari 式：命中计数 + 上 / 下一个）

/// 有搜索词时浮在阅读区顶部。输入框在工具栏（`NSSearchToolbarItem`），这里只补「导航」这一层。
final class FindBannerView: CapsuleMaterialView {
    let label = NSTextField(labelWithString: "")
    let prev = NSButton()
    let next = NSButton()

    override init(frame: NSRect) {
        super.init(frame: frame)
        label.font = .preferredFont(forTextStyle: .caption1)
        label.textColor = .labelColor
        for (b, symbol, tip) in [(prev, "chevron.up", L("Previous")), (next, "chevron.down", L("Next"))] {
            b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
            b.imagePosition = .imageOnly
            b.isBordered = false
            b.contentTintColor = .labelColor
            b.toolTip = tip
            b.widthAnchor.constraint(equalToConstant: 24).isActive = true
            b.heightAnchor.constraint(equalToConstant: 24).isActive = true
        }
        let stack = NSStackView(views: [label, prev, next])
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 3, left: 12, bottom: 3, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) 不支持") }

    func update(_ session: DocSession) {
        let q = session.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let text: String
        if session.isSearching { text = L("Searching…") }
        else if q.isEmpty { text = "" }
        else if session.searchMatches.isEmpty { text = L("No matches") }
        else { text = String(format: L("%d of %d"), (session.currentMatchIndex ?? 0) + 1, session.searchMatches.count) }
        if label.stringValue != text { label.stringValue = text }
        prev.isEnabled = !session.searchMatches.isEmpty
        next.isEnabled = !session.searchMatches.isEmpty
    }
}

// MARK: - 角标（正在索引 / 正在对齐扫描页）

final class StatusBadgeView: CapsuleMaterialView {
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        material = .headerView
        icon.contentTintColor = .labelColor
        label.textColor = .labelColor
        label.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        let stack = NSStackView(views: [icon, label])
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 6, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) 不支持") }

    func set(symbol: String, text: String) {
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        if label.stringValue != text { label.stringValue = text }
    }
}

// MARK: - 空白提示（没有文档 / 文件找不到）

/// 系统「内容不可用」的样子：大号符号 + 标题 + 说明 + 可选按钮，居中。
final class PlaceholderView: NSView {
    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(wrappingLabelWithString: "")
    private let button = NSButton()
    private var action: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 40, weight: .regular)
        icon.contentTintColor = .secondaryLabelColor
        title.font = .systemFont(ofSize: 17, weight: .bold)
        title.alignment = .center
        detail.font = .preferredFont(forTextStyle: .body)
        detail.textColor = .secondaryLabelColor
        detail.alignment = .center
        detail.preferredMaxLayoutWidth = 360
        button.bezelStyle = .push
        button.target = self
        button.action = #selector(tapped)
        let stack = NSStackView(views: [icon, title, detail, button])
        stack.orientation = .vertical
        stack.spacing = 8
        stack.setCustomSpacing(14, after: icon)
        stack.setCustomSpacing(16, after: detail)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -40),
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) 不支持") }

    func set(symbol: String, title t: String, detail d: String, button b: String? = nil, action: (() -> Void)? = nil) {
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        title.stringValue = t
        detail.stringValue = d
        button.isHidden = b == nil
        button.title = b ?? ""
        self.action = action
    }

    @objc private func tapped() { action?() }
}
