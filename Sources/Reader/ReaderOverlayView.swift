import AppKit
import QuartzCore

/// 阅读区上方的覆盖层（与滚动视图同大，flipped，**屏幕点**坐标）：放那些「屏幕上固定大小、不随页面缩放」的东西——
/// 图钉、笔记气泡、框选路径 / 选中框 / 手柄 / 光晕、框选文字的虚线框、橡皮圈、平板笔尖光标、长按进度环、
/// 环形选笔盘、截图框、提示条。页面滚动 / 缩放时由 `ReaderView.layoutOverlay` 重新摆放。
///
/// 命中：只有图钉 / 气泡（及提示条之外的交互子视图）接鼠标，其余位置返回 nil，事件落到下面的滚动视图。
final class ReaderOverlayView: NSView {
    override var isFlipped: Bool { true }

    /// 窗口工具栏盖住的顶部高度（屏幕点）。阅读区本身仍铺到工具栏后面，让页面从玻璃后透过去；
    /// 只有图钉 / 笔记卡片在这里明确裁到工具栏下沿，避免它们作为交互浮层画到工具栏之上。
    var topOcclusion: CGFloat = 0 {
        didSet {
            if abs(oldValue - topOcclusion) > 0.5 { needsLayout = true }
        }
    }

    // 图钉 / 气泡（键：见 `ReaderView+Overlay`）
    var pins: [String: ReaderPinView] = [:]
    var noteBubbles: [UUID: NoteBubbleNSView] = [:]
    var imageBubbles: [UUID: ImageBubbleNSView] = [:]

    /// 装图钉与气泡的容器（在形状图层之下；气泡盖住图钉，所以气泡后加）。
    let pinLayerView = PassThroughView()
    let bubbleLayerView = PassThroughView()

    // 纯显示的形状
    let lassoPath = QuietShapeLayer()
    let boxSelect = QuietShapeLayer()
    let lassoHalo = QuietShapeLayer()
    let lassoBox = QuietShapeLayer()
    let lassoHandles = QuietShapeLayer()
    let eraserRing = QuietShapeLayer()
    let tabletHover = QuietShapeLayer()
    let pressTrack = QuietShapeLayer()
    let pressFill = QuietShapeLayer()
    let snipDim = QuietShapeLayer()
    let snipBorder = QuietShapeLayer()
    let snipBadge = CATextLayer()
    let radial = RadialMenuNSView()
    let toast = ReaderToastView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        for v in [pinLayerView, bubbleLayerView] {
            v.frame = bounds
            v.wantsLayer = true
            v.layer?.masksToBounds = true
            addSubview(v)
        }
        let accent = NSColor.controlAccentColor
        lassoPath.fillColor = accent.withAlphaComponent(0.06).cgColor
        lassoPath.strokeColor = accent.cgColor
        lassoPath.lineWidth = 1
        lassoPath.lineDashPattern = [5, 4]
        boxSelect.fillColor = accent.withAlphaComponent(0.08).cgColor
        boxSelect.strokeColor = accent.cgColor
        boxSelect.lineWidth = 1
        boxSelect.lineDashPattern = [5, 4]
        lassoHalo.fillColor = nil
        lassoHalo.strokeColor = accent.withAlphaComponent(0.35).cgColor
        lassoHalo.lineCap = .round
        lassoHalo.lineJoin = .round
        lassoBox.fillColor = accent.withAlphaComponent(0.08).cgColor
        lassoBox.strokeColor = accent.cgColor
        lassoBox.lineWidth = 1.5
        lassoBox.lineDashPattern = [6, 4]
        lassoHandles.fillColor = accent.withAlphaComponent(0.25).cgColor
        lassoHandles.strokeColor = accent.cgColor
        lassoHandles.lineWidth = 1.5
        eraserRing.fillColor = nil
        eraserRing.strokeColor = accent.cgColor
        eraserRing.lineWidth = 1.5
        tabletHover.fillColor = nil
        tabletHover.strokeColor = accent.cgColor
        tabletHover.lineWidth = 2
        pressTrack.fillColor = nil
        pressTrack.strokeColor = NSColor.white.withAlphaComponent(0.25).cgColor
        pressTrack.lineWidth = 3
        pressFill.fillColor = nil
        pressFill.strokeColor = accent.cgColor
        pressFill.lineWidth = 3
        pressFill.lineCap = .round
        snipDim.fillColor = NSColor.black.withAlphaComponent(0.28).cgColor
        snipDim.fillRule = .evenOdd
        snipBorder.fillColor = nil
        snipBorder.strokeColor = accent.cgColor
        snipBorder.lineWidth = 1
        snipBadge.fontSize = 11
        snipBadge.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        snipBadge.alignmentMode = .center
        snipBadge.foregroundColor = NSColor.labelColor.cgColor
        snipBadge.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.92).cgColor
        snipBadge.cornerRadius = 8
        snipBadge.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        snipBadge.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull(), "hidden": NSNull()]
        for l in [lassoHalo, lassoBox, lassoHandles, lassoPath, boxSelect, eraserRing, tabletHover,
                  pressTrack, pressFill, snipDim, snipBorder, snipBadge] as [CALayer] {
            l.isHidden = true
            layer?.addSublayer(l)
        }
        radial.isHidden = true
        addSubview(radial)
        toast.isHidden = true
        addSubview(toast)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) 不支持") }

    override func layout() {
        super.layout()
        let top = min(max(topOcclusion, 0), bounds.height)
        let visible = NSRect(x: bounds.minX, y: bounds.minY + top,
                             width: bounds.width, height: bounds.height - top)
        for v in [pinLayerView, bubbleLayerView] {
            // frame 与 bounds 使用同一坐标原点：子视图仍按覆盖层全局坐标摆放，只裁掉顶部。
            if v.frame != visible { v.frame = visible }
            if v.bounds != visible { v.bounds = visible }
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let v = super.hitTest(point)
        return (v === self || v === pinLayerView || v === bubbleLayerView || v === radial || v === toast
                || v?.isDescendant(of: toast) == true) ? nil : v
    }

    /// 形状图层的「隐藏 / 设路径」一步到位。
    static func set(_ l: CAShapeLayer, _ path: CGPath?) {
        if let path { l.path = path; l.isHidden = false } else { l.isHidden = true; l.path = nil }
    }
}

/// 只做容器、自己不接鼠标的视图（点到空白处要透下去）。
final class PassThroughView: NSView {
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? {
        let v = super.hitTest(point)
        return v === self ? nil : v
    }
}

// MARK: - 提示条（截图 / 划字发送 / 导入图片的即时反馈）

/// 系统材质胶囊 + 转圈 / 图标 + 一行字，贴阅读区右下角，不接鼠标。
final class ReaderToastView: NSVisualEffectView {
    enum Kind { case working, ok, fail }
    private let spinner = NSProgressIndicator()
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private var hideWork: DispatchWorkItem?

    override init(frame: NSRect) {
        super.init(frame: frame)
        material = .popover
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 16
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor.separatorColor.cgColor
        spinner.style = .spinning
        spinner.controlSize = .small
        label.font = .preferredFont(forTextStyle: .callout)
        label.textColor = .labelColor   // 材质底上一律主色（红线）
        label.maximumNumberOfLines = 2
        label.lineBreakMode = .byTruncatingTail
        for v in [spinner, icon, label] as [NSView] { addSubview(v) }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) 不支持") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// 显示一条反馈并定时收起（working 12s 兜底，正常会被结果那条顶掉；失败 4.5s；成功 2.4s）。
    func show(_ kind: Kind, _ text: String, in container: NSView, trailingInset: CGFloat) {
        hideWork?.cancel()
        label.stringValue = text
        spinner.isHidden = kind != .working
        icon.isHidden = kind == .working
        if kind == .working { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        let symbol = kind == .ok ? "checkmark.circle" : "exclamationmark.triangle"
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        icon.contentTintColor = kind == .fail ? .systemOrange : .labelColor
        let maxW: CGFloat = 320
        let textSize = label.sizeThatFits(NSSize(width: maxW - 48, height: 60))
        let w = min(maxW, textSize.width + 48), h = max(32, textSize.height + 16)
        frame = NSRect(x: container.bounds.width - trailingInset - 18 - w,
                       y: container.bounds.height - 18 - h, width: w, height: h)
        spinner.frame = NSRect(x: 12, y: (h - 16) / 2, width: 16, height: 16)
        icon.frame = spinner.frame
        label.frame = NSRect(x: 35, y: (h - textSize.height) / 2, width: w - 47, height: textSize.height)
        layer?.cornerRadius = h / 2
        isHidden = false
        let delay: TimeInterval = kind == .working ? 12 : (kind == .fail ? 4.5 : 2.4)
        let work = DispatchWorkItem { [weak self] in self?.isHidden = true }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
}
