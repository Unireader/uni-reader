import AppKit

/// 底部标签栏（AppKit 版，替代 SwiftUI `TabStrip`；行为与观感同原版，数全从 `TabBarMetrics` 来）：
///  · 两种形态：浮动胶囊（系统材质，离底 12pt）/ 贴底整条（系统栏材质 + 顶部分隔线），右键切换；
///  · ≥2 个标签才显示（由宿主控制）；关闭按钮在左，只在活动标签或悬停时出现（藏起来时不吃点击）；
///  · 活动标签字重加粗（浅色外观下单靠颜色分不清主次，2026-08-29 样张定）；
///  · 胶囊宽度固定（占满阅读区、左右各留 24pt，宿主定），标签**平分**胶囊里的宽度、开得越多越窄，整排始终显示
///    （用户 2026-11-14 定，同浏览器；原来是胶囊贴着内容、放不下横向滚动）。每个压到 `TabChipView.minWidth` 还放不下才退回横向滚动
///    （竖向滚轮自动转横向，用户 2026-09-17：不用按 Shift）。
/// 🔴 只用系统材质与系统颜色（`quaternaryLabelColor` / `quinaryLabel` 底片），不自绘仿系统样式。
final class TabBarNSView: NSView {
    var onSelect: (UUID) -> Void = { _ in }
    var onClose: (UUID) -> Void = { _ in }
    var onCloseOthers: (UUID) -> Void = { _ in }
    var onRevealInSidebar: (UUID) -> Void = { _ in }
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
    /// 标签之间的间距（浮动胶囊 2、贴底 1）。
    private var spacing: CGFloat = 2
    /// 点了关闭之后先**不重新平分**宽度，等鼠标离开标签栏再放开（同 Firefox，用户 2026-11-17）：
    /// 右边那个标签挪进来、它的关闭键正好落在鼠标底下，可以一直点下去关。
    private var frozenWidth: CGFloat?
    private var barTracking: NSTrackingArea?
    /// 下一次摆位要带动画（标签数变了 / 关闭后放开冻结宽度）。窗口缩放、拖动时不带：要跟手。
    private var animateNextLayout = false
    /// 刚新建、还没摆过的标签：从零宽淡入长出来。
    private var freshChips = Set<ObjectIdentifier>()

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
        // 不接键盘焦点：否则窗口一打开它就是第一个能接键盘的控件，一直套着蓝色焦点框（用户 2026-11-14 报）
        plus.refusesFirstResponder = true
        plus.focusRingType = .none
        row.addSubview(plus)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) 不支持") }

    @objc private func newTab() { onNewTab() }

    static var height: CGFloat { TabBarMetrics.rowHeight + TabBarMetrics.pad * 2 }

    func update(items: [TabBarItem], activeID: UUID, style: TabBarStyle) {
        // 标签变多了（新开）就不再保持关闭时的宽度
        if items.count > chips.count || style != self.style { frozenWidth = nil }
        if items.count != chips.count, style == self.style, window != nil { animateNextLayout = true }
        self.style = style
        while chips.count < items.count {
            let c = TabChipView()
            c.owner = self
            row.addSubview(c)
            chips.append(c)
            if animateNextLayout { freshChips.insert(ObjectIdentifier(c)) }
        }
        while chips.count > items.count { chips.removeLast().removeFromSuperview() }
        spacing = style == .floating ? 2 : 1
        for (c, item) in zip(chips, items) {
            c.configure(item: item, active: item.id == activeID, capsule: style == .floating)
        }
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
        let avail = max(0, b.width - inset * 2)
        scroll.frame = NSRect(x: inset, y: TabBarMetrics.pad, width: avail, height: TabBarMetrics.rowHeight)
        layoutChips(avail: avail)
    }

    /// 按可用宽摆标签：去掉「+」和间距后平分（取整，余下的像素留在末尾），每个至少 `minWidth`，再窄就让整排超出、可以横向滚动。
    private func layoutChips(avail: CGFloat) {
        let n = CGFloat(max(1, chips.count))
        let room = avail - TabBarMetrics.rowHeight - spacing * CGFloat(chips.count)
        var w = max(TabChipView.minWidth, (room / n).rounded(.down))
        // 关掉一个之后平分宽度会变大；保持关闭前的宽度（窗口变窄等放不下时仍按平分的）
        if let f = frozenWidth, f < w { w = f }
        var x: CGFloat = 0
        let animate = animateNextLayout && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        animateNextLayout = false
        var targets: [(NSView, NSRect)] = []
        for c in chips {
            let target = NSRect(x: x, y: 0, width: w, height: TabBarMetrics.rowHeight)
            if freshChips.remove(ObjectIdentifier(c)) != nil, animate {
                c.frame = NSRect(x: x, y: 0, width: 0, height: TabBarMetrics.rowHeight)   // 从零宽长出来
                c.alphaValue = 0
                targets.append((c, target))
            } else if animate, c.frame != target, c.frame.width > 0 {
                targets.append((c, target))
            } else {
                c.frame = target
                c.alphaValue = 1
            }
            x += w + spacing
        }
        freshChips.removeAll()
        let plusTarget = NSRect(x: x, y: 0, width: TabBarMetrics.rowHeight, height: TabBarMetrics.rowHeight)
        if animate {
            // 其余标签平滑挪到新位置 / 新宽度（关闭后放开冻结宽度时就是「展开」），「+」同步滑过去
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.22
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                ctx.allowsImplicitAnimation = true
                for (v, f) in targets { v.animator().frame = f; v.animator().alphaValue = 1 }
                plus.animator().frame = plusTarget
            }
        } else {
            plus.frame = plusTarget
        }
        let total = x + TabBarMetrics.rowHeight
        row.frame = NSRect(x: 0, y: 0, width: max(avail, total), height: TabBarMetrics.rowHeight)
        // 塞得下就不该留着之前滚过的偏移（否则左边一截一直看不见）
        if total <= avail, scroll.contentView.bounds.origin.x != 0 {
            scroll.contentView.scroll(to: .zero)
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        // 标签挪动了而鼠标没动：进出事件不会来，按鼠标此刻的位置重算一遍悬停（关闭键要立刻露出来才能接着点）
        DispatchQueue.main.async { [weak self] in self?.syncHover() }
    }

    /// 关闭键被点：记下当前宽度，鼠标离开标签栏之前一直按这个宽度排。
    func closeTapped(_ id: UUID, chipWidth: CGFloat) {
        frozenWidth = chipWidth
        onClose(id)
    }

    private func syncHover() {
        guard let win = window else { return }
        let p = win.mouseLocationOutsideOfEventStream
        for c in chips { c.setHovering(c.window != nil && c.visibleRect.contains(c.convert(p, from: nil))) }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let barTracking { removeTrackingArea(barTracking) }
        let t = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
        barTracking = t
    }

    override func mouseExited(with event: NSEvent) {
        guard frozenWidth != nil else { return }
        frozenWidth = nil
        animateNextLayout = true   // 关完一串之后放开冻结的宽度：剩下的标签平滑展开
        needsLayout = true
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
/// 标题放不下时尾部省略；悬停一会儿在胶囊上方弹出完整名字（系统 `NSPopover`），用户 2026-11-17 定。
/// （同日试过放不下时来回自动滚动，用户实测滚到一半整段空白、说「滚动拿走吧，tip 就够了」，已删。）
final class TabChipView: NSView {
    weak var owner: TabBarNSView?
    private let close = NSButton()
    private let label = NSTextField(labelWithString: "")
    private let pad = NSImageView()
    private var item = TabBarItem(id: UUID(), title: "", padFollowing: false, hasDocument: false)
    private var active = false
    private var capsule = true
    private var hovering = false { didSet { if oldValue != hovering { refresh(); hoverChanged() } } }
    private var tracking: NSTrackingArea?
    private var tipTimer: Timer?
    private var tip: NSPopover?

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
        close.refusesFirstResponder = true   // 同「+」：别抢键盘焦点、套蓝框
        close.focusRingType = .none
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

    deinit { tipTimer?.invalidate() }

    func configure(item: TabBarItem, active: Bool, capsule: Bool) {
        let titleChanged = item.title != self.item.title
        self.item = item
        self.active = active
        self.capsule = capsule
        label.stringValue = item.title
        label.setAccessibilityLabel(item.title)
        pad.isHidden = !item.padFollowing
        if titleChanged { hideTip() }
        refresh()
    }

    /// 放不下时最多缩到多窄：关闭键 + 两三个字（再窄就退回横向滚动）。
    static let minWidth: CGFloat = 64

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

    /// 标签栏挪动了标签之后按鼠标位置补的悬停（`TabBarNSView.syncHover`）。
    func setHovering(_ on: Bool) { hovering = on }

    private var isTruncated: Bool { label.intrinsicContentSize.width > label.bounds.width + 0.5 }

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

    // MARK: - 悬停显示完整名字

    private func hoverChanged() {
        tipTimer?.invalidate()
        tipTimer = nil
        guard hovering else { hideTip(); return }
        guard isTruncated else { return }
        tipTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.showTip() }
        }
    }

    private func showTip() {
        guard hovering, window != nil, tip == nil, isTruncated else { return }
        let text = NSTextField(wrappingLabelWithString: item.title)
        text.font = .preferredFont(forTextStyle: .callout)
        text.textColor = .labelColor
        text.preferredMaxLayoutWidth = 360
        let fit = text.fittingSize
        let box = NSView(frame: NSRect(x: 0, y: 0, width: fit.width + 20, height: fit.height + 12))
        text.frame = NSRect(x: 10, y: 6, width: fit.width, height: fit.height)
        box.addSubview(text)
        let vc = NSViewController()
        vc.view = box
        let p = NSPopover()
        p.contentViewController = vc
        p.behavior = .applicationDefined   // 不抢点击：鼠标挪开 / 点了标签由我们收
        p.animates = false
        p.show(relativeTo: bounds, of: self, preferredEdge: .minY)   // 翻转坐标：minY = 上方
        tip = p
    }

    private func hideTip() {
        tipTimer?.invalidate()
        tipTimer = nil
        tip?.close()
        tip = nil
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { hideTip() }
        super.viewWillMove(toWindow: newWindow)
    }

    @objc private func closeTapped() {
        hideTip()
        owner?.closeTapped(item.id, chipWidth: bounds.width)
    }

    override func mouseDown(with event: NSEvent) { hideTip() }

    override func mouseUp(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard bounds.contains(p), !(close.frame.contains(p) && !close.isHidden) else { return }
        owner?.onSelect(item.id)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        hideTip()
        let m = NSMenu()
        let id = item.id
        m.addItem(ClosureMenuItem(L("Close Tab")) { [weak self] in self?.owner?.onClose(id) })
        m.addItem(ClosureMenuItem(L("Close Other Tabs")) { [weak self] in self?.owner?.onCloseOthers(id) })
        m.addItem(.separator())
        m.addItem(ClosureMenuItem(L("Reveal in Sidebar")) { [weak self] in self?.owner?.onRevealInSidebar(id) })
        if item.hasDocument {
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
