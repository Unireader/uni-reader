import AppKit

/// 两块内置面板（Agent / 咨询 AI）共用的标题行（AppKit 版，替代 SwiftUI `InlinePanelHeader`）：
/// 左边图标 + 两行文字（标题 / 副标题），右边一组按钮用系统分段控件分组（瞬时按下，可挂菜单），高度固定 48。
/// 🔴 玻璃底：文字一律 `labelColor`（红线：别用次要色）。
final class InlinePanelHeaderView: NSView {
    struct Button {
        var symbol: String
        var tip: String
        var menu: (() -> NSMenu)?
        var action: (() -> Void)?
    }

    static let height: CGFloat = 48

    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let subtitle = NSTextField(labelWithString: "")
    private let group = NSSegmentedControl()
    private var buttons: [Button] = []

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        icon.symbolConfiguration = .init(pointSize: 15, weight: .regular)
        icon.contentTintColor = .labelColor
        title.font = .preferredFont(forTextStyle: .headline)
        title.textColor = .labelColor
        title.lineBreakMode = .byTruncatingTail
        subtitle.font = .preferredFont(forTextStyle: .caption1)
        subtitle.textColor = .labelColor
        subtitle.lineBreakMode = .byTruncatingMiddle
        group.trackingMode = .momentary
        group.segmentStyle = .automatic
        group.target = self
        group.action = #selector(tapped)
        for v in [icon, title, subtitle, group] as [NSView] { addSubview(v) }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) 不支持") }

    func configure(icon symbol: String, title t: String, subtitle s: String?, buttons: [Button]) {
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        title.stringValue = t
        subtitle.stringValue = s ?? ""
        subtitle.isHidden = (s ?? "").isEmpty
        if buttons.map(\.symbol) != self.buttons.map(\.symbol) {
            group.segmentCount = buttons.count
            for (i, b) in buttons.enumerated() {
                group.setImage(NSImage(systemSymbolName: b.symbol, accessibilityDescription: b.tip), forSegment: i)
                group.setToolTip(b.tip, forSegment: i)
                group.setShowsMenuIndicator(b.menu != nil, forSegment: i)
                group.setWidth(0, forSegment: i)
            }
        }
        self.buttons = buttons
        for (i, b) in buttons.enumerated() { group.setMenu(b.menu?(), forSegment: i) }
        needsLayout = true
    }

    @objc private func tapped() {
        let i = group.selectedSegment
        guard buttons.indices.contains(i) else { return }
        // 挂了菜单（带菜单指示）的段由系统自己弹菜单，这里只处理普通按钮
        buttons[i].action?()
    }

    override func layout() {
        super.layout()
        let h = bounds.height
        group.sizeToFit()
        let g = group.frame.size
        group.frame = NSRect(x: bounds.width - 12 - g.width, y: (h - g.height) / 2, width: g.width, height: g.height)
        icon.frame = NSRect(x: 12, y: (h - 22) / 2, width: 22, height: 22)
        let textX: CGFloat = 12 + 22 + 8
        let textW = max(0, group.frame.minX - 4 - textX)
        let th = title.intrinsicContentSize.height
        let sh = subtitle.isHidden ? 0 : subtitle.intrinsicContentSize.height
        let top = (h - th - sh - (sh > 0 ? 1 : 0)) / 2
        title.frame = NSRect(x: textX, y: top, width: textW, height: th)
        subtitle.frame = NSRect(x: textX, y: top + th + 1, width: textW, height: sh)
    }
}
