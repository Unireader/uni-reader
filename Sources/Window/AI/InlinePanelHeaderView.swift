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
        needsLayout = true
    }

    /// 单击就执行：普通按钮调动作；带菜单的段在它下方弹出菜单。
    /// 不用 `setMenu(_:forSegment:)`：那样系统要**按住**才弹菜单，单击什么都不发生（2026-09-19 用户报「按钮失效」）。
    @objc private func tapped() {
        let i = group.selectedSegment
        guard buttons.indices.contains(i) else { return }
        let b = buttons[i]
        if let make = b.menu {
            let m = make()
            let x = segmentMinX(i)
            let y: CGFloat = group.isFlipped ? group.bounds.maxY + 4 : -4
            m.popUp(positioning: nil, at: NSPoint(x: x, y: y), in: group)
        } else {
            b.action?()
        }
    }

    /// 第 i 段的左边缘（段宽自动时按控件总宽平均分，够用来定菜单位置）。
    private func segmentMinX(_ i: Int) -> CGFloat {
        var x: CGFloat = 0
        var widths: [CGFloat] = []
        for k in 0..<group.segmentCount { widths.append(group.width(forSegment: k)) }
        if widths.contains(0) {
            return group.bounds.width / CGFloat(max(1, group.segmentCount)) * CGFloat(i)
        }
        for k in 0..<i { x += widths[k] }
        return x
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
