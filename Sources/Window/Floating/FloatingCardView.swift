import AppKit

/// 浮在阅读区上的小卡片（参考窗覆盖层 / 跳转历史共用，AppKit 版）：系统材质底 + 圆角 + 发丝描边 + 阴影，
/// 标题条拖动移动，左 / 上边缘与左上角拖动改尺寸（透明热区，只换指针，不画任何图标——系统窗口也是这样）。
///
/// 摆位口径沿用 SwiftUI 版：`offset` 相对容器**右下角**（≤0 往左上），外边距 14；所以改尺寸时右下角不动。
/// 拖动 / 改尺寸**期间**只动卡片自己的本地量，松手才经 `onCommit` 写回模型（每帧写 `@Published` 会让别的订阅者每帧重算）。
/// 容器变小时（缩窗口、开侧栏）每次布局都重新夹一遍，夹出来的结果也写回——否则卡片会被推到工具栏底下点不到。
final class FloatingCardView: NSView {
    static let corner: CGFloat = 12
    static let margin: CGFloat = 14
    static let edge: CGFloat = 5

    /// 标题条（拖它移动）与内容区，由使用方往里放东西。
    let header = CardHeaderView()
    let body = FlippedView()
    var headerHeight: CGFloat = 30 { didSet { needsLayout = true } }
    var footerHeight: CGFloat = 0 { didSet { needsLayout = true } }
    let footer = FlippedView()

    var size: CGSize
    var offset: CGSize
    var clampSize: (CGSize, CGSize) -> CGSize = { s, _ in s }
    var clampOffset: (CGSize, CGSize, CGSize) -> CGSize = { o, _, _ in o }
    /// 松手 / 容器变小夹取后：把尺寸与摆位写回模型并存盘。
    var onCommit: (CGSize, CGSize) -> Void = { _, _ in }

    private let shell = NSVisualEffectView()
    private let topLine = NSBox()
    private let bottomLine = NSBox()
    private let left = EdgeHandle(horizontal: true, vertical: false)
    private let top = EdgeHandle(horizontal: false, vertical: true)
    private let corner = EdgeHandle(horizontal: true, vertical: true)
    private var container: CGSize = .zero

    override var isFlipped: Bool { true }

    init(size: CGSize, offset: CGSize) {
        self.size = size
        self.offset = offset
        super.init(frame: .zero)
        wantsLayer = true
        shadow = {
            let s = NSShadow()
            s.shadowColor = NSColor.black.withAlphaComponent(0.22)
            s.shadowBlurRadius = 12
            s.shadowOffset = NSSize(width: 0, height: -4)
            return s
        }()
        shell.material = .popover
        shell.blendingMode = .withinWindow
        shell.state = .active
        shell.wantsLayer = true
        shell.layer?.cornerRadius = Self.corner
        shell.layer?.masksToBounds = true
        shell.layer?.borderWidth = 0.5
        shell.layer?.borderColor = NSColor.separatorColor.cgColor
        topLine.boxType = .separator
        bottomLine.boxType = .separator
        addSubview(shell)
        for v in [header, topLine, body, bottomLine, footer] as [NSView] { shell.addSubview(v) }
        for h in [left, top, corner] { shell.addSubview(h) }

        header.onDrag = { [weak self] d, phase in self?.moveDrag(d, phase) }
        for h in [left, top, corner] {
            h.onDrag = { [weak self, weak h] d, phase in
                guard let self, let h else { return }
                self.resizeDrag(d, phase, horizontal: h.horizontal, vertical: h.vertical)
            }
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) 不支持") }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        shell.layer?.borderColor = NSColor.separatorColor.cgColor
    }

    /// 在容器里摆好（容器每次布局都调）。先按当前容器夹一遍，夹出变化就写回。
    func place(in container: CGSize) {
        self.container = container
        guard container.width > 0, container.height > 0 else { return }
        let s = clampSize(size, container), o = clampOffset(offset, s, container)
        if s != size || o != offset {
            size = s
            offset = o
            onCommit(s, o)
        }
        applyFrame()
    }

    private func applyFrame() {
        frame = NSRect(x: container.width - Self.margin - size.width + offset.width,
                       y: container.height - Self.margin - size.height + offset.height,
                       width: size.width, height: size.height)
    }

    override func layout() {
        super.layout()
        let b = bounds
        shell.frame = b
        header.frame = NSRect(x: 0, y: 0, width: b.width, height: headerHeight)
        topLine.frame = NSRect(x: 0, y: headerHeight, width: b.width, height: 1)
        let fh = footerHeight
        footer.isHidden = fh == 0
        bottomLine.isHidden = fh == 0
        footer.frame = NSRect(x: 0, y: b.height - fh, width: b.width, height: fh)
        bottomLine.frame = NSRect(x: 0, y: b.height - fh - 1, width: b.width, height: 1)
        body.frame = NSRect(x: 0, y: headerHeight + 1, width: b.width,
                            height: max(0, b.height - headerHeight - 1 - (fh > 0 ? fh + 1 : 0)))
        let e = Self.edge
        left.frame = NSRect(x: 0, y: 0, width: e, height: b.height)
        top.frame = NSRect(x: 0, y: 0, width: b.width, height: e)
        corner.frame = NSRect(x: 0, y: 0, width: e * 3, height: e * 3)
    }

    // MARK: 拖动（基准在起手时定死：位移是相对起点的累计量）

    private var baseOffset: CGSize = .zero
    private var baseSize: CGSize = .zero

    private func moveDrag(_ d: CGSize, _ phase: EdgeHandle.Phase) {
        switch phase {
        case .began: baseOffset = offset
        case .changed:
            offset = clampOffset(CGSize(width: baseOffset.width + d.width, height: baseOffset.height + d.height), size, container)
            applyFrame()
        case .ended: onCommit(size, offset)
        }
    }

    /// 往左上拖 = 变大（取负），右下角固定不动。
    private func resizeDrag(_ d: CGSize, _ phase: EdgeHandle.Phase, horizontal: Bool, vertical: Bool) {
        switch phase {
        case .began: baseSize = size
        case .changed:
            size = clampSize(CGSize(width: baseSize.width - (horizontal ? d.width : 0),
                                    height: baseSize.height - (vertical ? d.height : 0)), container)
            applyFrame()
        case .ended:
            offset = clampOffset(offset, size, container)
            applyFrame()
            onCommit(size, offset)
        }
    }
}

/// 可拖动的透明热区：回调「相对起点的累计位移」（y 向下为正）。改尺寸的边缘热区带对应的指针。
class EdgeHandle: NSView {
    enum Phase { case began, changed, ended }
    let horizontal: Bool
    let vertical: Bool
    var onDrag: (CGSize, Phase) -> Void = { _, _ in }
    private var start: NSPoint?

    init(horizontal: Bool, vertical: Bool) {
        self.horizontal = horizontal
        self.vertical = vertical
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) 不支持") }

    override var isFlipped: Bool { true }

    override func resetCursorRects() {
        let pos: NSCursor.FrameResizePosition = horizontal && vertical ? .topLeft : (horizontal ? .left : .top)
        addCursorRect(bounds, cursor: .frameResize(position: pos, directions: .all))
    }

    override func mouseDown(with event: NSEvent) {
        start = event.locationInWindow
        onDrag(.zero, .began)
    }
    override func mouseDragged(with event: NSEvent) {
        guard let s = start else { return }
        let p = event.locationInWindow
        onDrag(CGSize(width: p.x - s.x, height: -(p.y - s.y)), .changed)   // 窗口坐标 y 向上，翻成向下
    }
    override func mouseUp(with event: NSEvent) {
        guard start != nil else { return }
        start = nil
        onDrag(.zero, .ended)
    }
}

/// 卡片标题条：空白处（含纯文字标签）拖动 = 移动卡片；按钮照常吃点击。
final class CardHeaderView: EdgeHandle {
    init() { super.init(horizontal: false, vertical: false) }
    required init?(coder: NSCoder) { fatalError("init(coder:) 不支持") }
    override func resetCursorRects() {}
}

/// 卡片标题条上的小图标按钮：无边框、主色（材质底上别用次要色，红线）、20×20。
final class CardIconButton: NSButton {
    private var handler: () -> Void = {}

    convenience init(_ symbol: String, _ tip: String, _ action: @escaping () -> Void) {
        self.init(frame: NSRect(x: 0, y: 0, width: 20, height: 20))
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .regular))
        imagePosition = .imageOnly
        isBordered = false
        contentTintColor = .labelColor
        toolTip = tip
        handler = action
        target = self
        self.action = #selector(fire)
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        widthAnchor.constraint(equalToConstant: 20).isActive = true
        heightAnchor.constraint(equalToConstant: 20).isActive = true
    }

    @objc private func fire() { handler() }
}

/// 浮层的容器：铺满阅读区，自己不吃鼠标（空白处透到下面的阅读区），只摆里面的卡片。
final class FloatingLayerView: NSView {
    var onLayout: (CGSize) -> Void = { _ in }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? {
        let v = super.hitTest(point)
        return v === self ? nil : v
    }
    override func layout() {
        super.layout()
        onLayout(bounds.size)
    }
}
