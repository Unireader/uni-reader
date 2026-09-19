import AppKit

/// 底部标签栏（AppKit 版，替代 SwiftUI `TabStrip`；行为与观感同原版，数全从 `TabBarMetrics` 来）：
///  · 两种形态：浮动胶囊（系统材质，离底 12pt）/ 贴底整条（系统栏材质 + 顶部分隔线），右键切换；
///  · ≥2 个标签才显示（由宿主控制）；关闭按钮在左，只在活动标签或悬停时出现（藏起来时不吃点击）；
///  · 活动标签字重加粗（浅色外观下单靠颜色分不清主次，2026-08-29 样张定）；
///  · 放不下时横向滚动，竖向滚轮自动转横向（用户 2026-09-17：不用按 Shift）。
/// 🔴 只用系统材质与系统颜色（`quaternaryLabelColor` / `quinaryLabel` 底片），不自绘仿系统样式。
final class TabBarNSView: NSView {
    var onSelect: (UUID) -> Void = { _ in }
    var onClose: (UUID) -> Void = { _ in }
    var onCloseOthers: (UUID) -> Void = { _ in }
    var onOpenInNewWindow: (UUID) -> Void = { _ in }
    var onNewTab: () -> Void = {}
    var onToggleStyle: () -> Void = {}

    private(set) var style: TabBarStyle = .floating
    private let floating = CapsuleMaterialView()
    private let docked = NSVisualEffectView()
    private let dockedLine = NSBox()
    private let scroll = HorizontalWheelScrollView()
    private let row = FlippedView()
    private var chips: [TabChipView] = []
    let plus = NSButton()
    private var contentWidth: CGFloat = 0

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        docked.material = .headerView
        docked.blendingMode = .withinWindow
        docked.state = .followsWindowActiveState
        dockedLine.boxType = .separator
        addSubview(docked)
        addSubview(dockedLine)
        addSubview(floating)
        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = false
        scroll.hasVerticalScroller = false
        scroll.documentView = row
        addSubview(scroll)
        plus.image = NSImage(systemSymbolName: "plus", accessibilityDescription: L("New Tab"))
        plus.imagePosition = .imageOnly
        plus.isBordered = false
        plus.contentTintColor = .labelColor
        plus.toolTip = L("New Tab")
        plus.target = self
        plus.action = #selector(newTab)
        row.addSubview(plus)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) 不支持") }

    @objc private func newTab() { onNewTab() }

    /// 标签栏自己想要多宽（浮动形态：贴着内容走；由宿主再夹到可用宽）。
    var preferredWidth: CGFloat {
        contentWidth + TabBarMetrics.pad * 2 + TabBarMetrics.capsuleSideInset * 2
    }
    static var height: CGFloat { TabBarMetrics.rowHeight + TabBarMetrics.pad * 2 }

    func update(items: [TabBarItem], activeID: UUID, style: TabBarStyle) {
        self.style = style
        while chips.count < items.count {
            let c = TabChipView()
            c.owner = self
            row.addSubview(c)
            chips.append(c)
        }
        while chips.count > items.count { chips.removeLast().removeFromSuperview() }
        let spacing: CGFloat = style == .floating ? 2 : 1
        var x: CGFloat = 0
        for (c, item) in zip(chips, items) {
            c.configure(item: item, active: item.id == activeID, capsule: style == .floating)
            let w = c.preferredWidth
            c.frame = NSRect(x: x, y: 0, width: w, height: TabBarMetrics.rowHeight)
            x += w + spacing
        }
        plus.frame = NSRect(x: x, y: 0, width: TabBarMetrics.rowHeight, height: TabBarMetrics.rowHeight)
        contentWidth = x + TabBarMetrics.rowHeight
        row.frame = NSRect(x: 0, y: 0, width: contentWidth, height: TabBarMetrics.rowHeight)
        floating.isHidden = style != .floating
        docked.isHidden = style != .docked
        dockedLine.isHidden = style != .docked
        // 浮动胶囊的投影挂在外层（胶囊本身按圆角裁剪，裁剪层上的阴影画不出来）
        shadow = style == .floating ? {
            let s = NSShadow()
            s.shadowColor = NSColor.black.withAlphaComponent(0.25)
            s.shadowBlurRadius = 6
            s.shadowOffset = NSSize(width: 0, height: -2)
            return s
        }() : nil
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let b = bounds
        floating.frame = b
        docked.frame = b
        dockedLine.frame = NSRect(x: 0, y: 0, width: b.width, height: 1)
        let inset = style == .floating ? TabBarMetrics.pad + TabBarMetrics.capsuleSideInset : 8
        // 标签排在滚动视图里，滚动视图的边界就把标签裁在胶囊内边距以内（窄到放不下时不会画到胶囊外）
        scroll.frame = NSRect(x: inset, y: TabBarMetrics.pad, width: max(0, b.width - inset * 2),
                              height: TabBarMetrics.rowHeight)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let m = NSMenu()
        m.addItem(ClosureMenuItem(style == .floating ? L("Pin to Bottom") : L("Float")) { [weak self] in self?.onToggleStyle() })
        return m
    }
}

/// 横向标签排的滚动视图：悬停时竖向滚轮转横向（本身带横向分量的触控板横扫原样放过）。
final class HorizontalWheelScrollView: NSScrollView {
    override func scrollWheel(with event: NSEvent) {
        guard event.scrollingDeltaX == 0, event.scrollingDeltaY != 0, let cg = event.cgEvent?.copy() else {
            super.scrollWheel(with: event); return
        }
        let pairs: [(CGEventField, CGEventField)] = [
            (.scrollWheelEventDeltaAxis1, .scrollWheelEventDeltaAxis2),
            (.scrollWheelEventFixedPtDeltaAxis1, .scrollWheelEventFixedPtDeltaAxis2),
            (.scrollWheelEventPointDeltaAxis1, .scrollWheelEventPointDeltaAxis2),
        ]
        for (y, x) in pairs {
            cg.setDoubleValueField(x, value: cg.getDoubleValueField(y))
            cg.setDoubleValueField(y, value: 0)
        }
        super.scrollWheel(with: NSEvent(cgEvent: cg) ?? event)
    }
}

/// 一个标签：关闭按钮（左）+ 标题 + 平板跟随标记。点击选中，右键「关闭 / 关闭其他 / 在新窗口打开」。
final class TabChipView: NSView {
    weak var owner: TabBarNSView?
    private let close = NSButton()
    private let label = NSTextField(labelWithString: "")
    private let pad = NSImageView()
    private var item = TabBarItem(id: UUID(), title: "", padFollowing: false, hasDocument: false)
    private var active = false
    private var capsule = true
    private var hovering = false { didSet { if oldValue != hovering { refresh() } } }
    private var tracking: NSTrackingArea?

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        close.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: L("Close Tab"))?
            .withSymbolConfiguration(.init(pointSize: 9, weight: .semibold))
        close.imagePosition = .imageOnly
        close.isBordered = false
        close.contentTintColor = .labelColor
        close.target = self
        close.action = #selector(closeTapped)
        close.setAccessibilityLabel(L("Close Tab"))
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        pad.image = NSImage(systemSymbolName: "ipad", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 9, weight: .regular))
        pad.contentTintColor = .labelColor
        pad.toolTip = L("The tablet is following this tab")
        for v in [close, label, pad] as [NSView] { addSubview(v) }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) 不支持") }

    func configure(item: TabBarItem, active: Bool, capsule: Bool) {
        self.item = item
        self.active = active
        self.capsule = capsule
        label.stringValue = item.title
        toolTip = item.title
        pad.isHidden = !item.padFollowing
        refresh()
    }

    /// 标题自然宽（最小 96 / 最大 220，同原版）。
    var preferredWidth: CGFloat {
        let titleW = (item.title as NSString).size(withAttributes: [.font: font]).width.rounded(.up)
        let w = 8 + 15 + 5 + titleW + (item.padFollowing ? 5 + 12 : 0) + 8
        return min(max(w, 96), 220)
    }

    private var font: NSFont {
        let base = NSFont.preferredFont(forTextStyle: .callout)
        return active ? NSFont.systemFont(ofSize: base.pointSize, weight: .semibold) : base
    }

    private func refresh() {
        label.font = font
        // 非活动标签不用 secondary（材质 + 白纸上几乎看不清，用户 2026-08-30）：主色压一档不透明度
        label.textColor = active ? .labelColor : NSColor.labelColor.withAlphaComponent(0.78)
        let showsClose = active || hovering
        close.isHidden = !showsClose   // 藏起来时同时不吃点击（只改透明度会误关）
        layer?.backgroundColor = active ? NSColor.quaternaryLabelColor.cgColor
            : (hovering ? NSColor.quinaryLabel.cgColor : NSColor.clear.cgColor)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let h = bounds.height
        layer?.cornerRadius = capsule ? h / 2 : 6
        layer?.cornerCurve = .continuous
        close.frame = NSRect(x: 8, y: (h - 15) / 2, width: 15, height: 15)
        let padW: CGFloat = item.padFollowing ? 12 : 0
        let labelX: CGFloat = 8 + 15 + 5
        let labelW = max(0, bounds.width - labelX - 8 - (padW > 0 ? padW + 5 : 0))
        let lh = label.intrinsicContentSize.height
        label.frame = NSRect(x: labelX, y: (h - lh) / 2, width: labelW, height: lh)
        pad.frame = NSRect(x: bounds.width - 8 - padW, y: (h - 12) / 2, width: padW, height: 12)
    }

    @objc private func closeTapped() { owner?.onClose(item.id) }

    override func mouseUp(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard bounds.contains(p), !(close.frame.contains(p) && !close.isHidden) else { return }
        owner?.onSelect(item.id)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let m = NSMenu()
        let id = item.id
        m.addItem(ClosureMenuItem(L("Close Tab")) { [weak self] in self?.owner?.onClose(id) })
        m.addItem(ClosureMenuItem(L("Close Other Tabs")) { [weak self] in self?.owner?.onCloseOthers(id) })
        if item.hasDocument {
            m.addItem(.separator())
            m.addItem(ClosureMenuItem(L("Open in New Window")) { [weak self] in self?.owner?.onOpenInNewWindow(id) })
        }
        return m
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
        tracking = t
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
}
