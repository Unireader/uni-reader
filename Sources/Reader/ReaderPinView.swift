import AppKit

/// 页面上的一枚图钉（文字批注 / 图片笔记 / 草稿纸 / 书签缎带），浮在阅读区上方的覆盖层里（`ReaderOverlayView`），
/// **屏幕点固定尺寸**，不随页面缩放（与 SwiftUI 版一样）。
///
/// 形制：扁平圆底 + SF Symbol + 0.5 描边，无渐变高光（红线）；书签是右端切 V 口的缎带。
/// 交互：单击 → `onClick`；可拖的图钉（批注 / 图片笔记）拖动中跟手、松手 `onDragEnd(位移)`；
/// 悬停进出 → `onHover`（hover 模式的笔记靠它展开）；右键 → `menuProvider`。
final class ReaderPinView: NSView {
    enum Kind: Equatable {
        case note(symbol: String, color: NSColor)
        case image
        case scratch
        case bookmark
    }

    var kind: Kind = .image { didSet { if oldValue != kind { needsDisplay = true } } }
    var onClick: (() -> Void)?
    /// 非 nil = 可拖。参数是屏幕点位移（已由提供方夹进页内）。
    var onDragEnd: ((CGSize) -> Void)?
    /// 把原始位移夹成合法位移（锚点不出页）。
    var clampDrag: ((CGSize) -> CGSize)?
    var onHover: ((Bool) -> Void)?
    var menuProvider: (() -> NSMenu?)?

    static let noteSize = CGSize(width: 18, height: 18)
    static let scratchSize = CGSize(width: 16, height: 16)
    static let ribbonSize = CGSize(width: 26, height: 15)
    /// 图钉半径（气泡避让用，= SwiftUI 版 `PageCellView.pinRadius`）。
    static let pinRadius: CGFloat = 9

    static func size(for kind: Kind) -> CGSize {
        switch kind {
        case .note, .image: return noteSize
        case .scratch: return scratchSize
        case .bookmark: return ribbonSize
        }
    }

    /// 悬停文字是按哪些原文算的：原文没变就不重算、不重设。笔记正文转纯文字要解析一遍 Markdown，
    /// 而滚动 / 缩放停下时每枚图钉都要重摆一遍（2026-10-07 采样：缩放卡顿里有它一份）。
    private var tipSource: [String]?
    func setToolTip(source: [String], _ make: () -> String?) {
        guard source != tipSource else { return }
        tipSource = source
        toolTip = make()
    }

    private var downWindow: NSPoint?
    private var dragging = false
    private var restFrame: NSRect = .zero
    private var tracking: NSTrackingArea?

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: 外观：按样式画好一张图、缓存起来，作为图层内容

    /// 🔴 不用 `draw(_:)`：那样图钉每挪一下位置 AppKit 都要它重画一遍（2026-10-07 离屏实测，
    /// 有没有自己的图层、redrawPolicy 设成什么都一样），缩放时一页几十枚图钉逐帧重画，动画掉帧。
    /// 改成交一张现成的图给图层，挪动时一次都不重画。
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        let scale = window?.backingScaleFactor ?? 2
        layer?.contentsGravity = .resize
        layer?.contentsScale = scale
        layer?.contents = Self.image(kind, size: bounds.size, scale: scale)
    }

    override func setFrameSize(_ newSize: NSSize) {
        let changed = newSize != frame.size
        super.setFrameSize(newSize)
        if changed { needsDisplay = true }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsDisplay = true   // 换到不同倍率的屏幕：按新倍率取图
    }

    /// 同一种样式（图标 + 颜色 + 尺寸 + 屏幕倍率）只画一次。
    private static var imageCache: [String: CGImage] = [:]

    private static func image(_ kind: Kind, size: CGSize, scale: CGFloat) -> CGImage? {
        let w = Int((size.width * scale).rounded()), h = Int((size.height * scale).rounded())
        guard w > 0, h > 0 else { return nil }
        let key = "\(kind)|\(w)x\(h)"
        if let img = imageCache[key] { return img }
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                      | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        // 与从前在 flipped 视图里 `draw(_:)` 同一套坐标：左上原点、y 向下，单位 = 点
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: scale, y: -scale)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        paint(kind, in: CGRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        let img = ctx.makeImage()
        imageCache[key] = img
        return img
    }

    private static func paint(_ kind: Kind, in b: CGRect) {
        switch kind {
        case .bookmark:
            let notch: CGFloat = 5
            let p = NSBezierPath()
            p.move(to: NSPoint(x: b.minX, y: b.minY))
            p.line(to: NSPoint(x: b.maxX, y: b.minY))
            p.line(to: NSPoint(x: b.maxX - notch, y: b.midY))
            p.line(to: NSPoint(x: b.maxX, y: b.maxY))
            p.line(to: NSPoint(x: b.minX, y: b.maxY))
            p.close()
            ReaderMarkColors.bookmarkMarker.setFill()
            p.fill()
            NSColor.black.withAlphaComponent(0.18).setStroke()
            p.lineWidth = 0.5
            p.stroke()
        case .note(let symbol, let color):
            drawDisc(in: b, fill: color, symbol: symbol, pointSize: 11)
        case .image:
            drawDisc(in: b, fill: ReaderMarkColors.imageMarker, symbol: "photo", pointSize: 11)
        case .scratch:
            drawDisc(in: b, fill: ReaderMarkColors.scratchMarker, symbol: "square.and.pencil", pointSize: 10)
        }
    }

    private static func drawDisc(in b: CGRect, fill: NSColor, symbol: String, pointSize: CGFloat) {
        let d = min(b.width, b.height)
        let r = NSRect(x: b.midX - d / 2, y: b.midY - d / 2, width: d, height: d).insetBy(dx: 0.25, dy: 0.25)
        let circle = NSBezierPath(ovalIn: r)
        fill.setFill()
        circle.fill()
        NSColor.black.withAlphaComponent(0.15).setStroke()
        circle.lineWidth = 0.5
        circle.stroke()
        let cfg = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold)
            .applying(.init(paletteColors: [NSColor.black.withAlphaComponent(0.75)]))
        guard let img = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(cfg) else { return }
        let s = img.size
        img.draw(in: NSRect(x: b.midX - s.width / 2, y: b.midY - s.height / 2, width: s.width, height: s.height))
    }

    // MARK: 鼠标

    override func mouseDown(with event: NSEvent) {
        downWindow = event.locationInWindow
        dragging = false
        restFrame = frame
    }

    override func mouseDragged(with event: NSEvent) {
        guard let d0 = downWindow, onDragEnd != nil else { return }
        var t = CGSize(width: event.locationInWindow.x - d0.x, height: -(event.locationInWindow.y - d0.y))
        if !dragging {
            guard hypot(t.width, t.height) > 2 else { return }
            dragging = true
        }
        if let clampDrag { t = clampDrag(t) }
        setFrameOrigin(NSPoint(x: restFrame.minX + t.width, y: restFrame.minY + t.height))
    }

    override func mouseUp(with event: NSEvent) {
        defer { downWindow = nil; dragging = false }
        guard let d0 = downWindow else { return }
        if dragging {
            var t = CGSize(width: event.locationInWindow.x - d0.x, height: -(event.locationInWindow.y - d0.y))
            if let clampDrag { t = clampDrag(t) }
            setFrameOrigin(restFrame.origin)   // 真正的新位置由数据变化后的重新摆放给出
            onDragEnd?(t)
        } else {
            onClick?()
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? { menuProvider?() }

    // MARK: 悬停

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
        tracking = t
    }

    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }
}
