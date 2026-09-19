import AppKit

/// 环形选笔盘（平板长按呼出，页锚定于笔尖处；纯显示，扇区判定由 Mac 按笔位算好放进 `RadialState.highlight`）。
/// 形制、半径、角度、配色全部同 SwiftUI 版 `RadialMenuView`（布局契约 `RadialLayout`，平板 `capture.html` 画同一个盘）。
/// 盘底 = 系统最薄一档材质 + 很淡的压暗（底下页面要透出来），对比度靠各图标自带的色片。
final class RadialMenuNSView: NSView {
    private let base = NSVisualEffectView()
    private let drawing = RadialDrawingView()

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    static var side: CGFloat { (RadialLayout.outerRadius + 14) * 2 }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        base.material = .hudWindow
        base.blendingMode = .withinWindow
        base.state = .active
        base.wantsLayer = true
        addSubview(base)
        addSubview(drawing)
        shadow = {
            let s = NSShadow()
            s.shadowColor = NSColor.black.withAlphaComponent(0.3)
            s.shadowBlurRadius = 16
            s.shadowOffset = NSSize(width: 0, height: -4)
            return s
        }()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) 不支持") }

    /// 摆在 `center`（覆盖层坐标）处，按当前状态重画。
    func show(_ radial: RadialState, pens: [PenPreset], center: CGPoint) {
        let side = Self.side
        frame = NSRect(x: center.x - side / 2, y: center.y - side / 2, width: side, height: side)
        let r = RadialLayout.outerRadius
        base.frame = NSRect(x: side / 2 - r, y: side / 2 - r, width: r * 2, height: r * 2)
        base.layer?.cornerRadius = r
        base.layer?.masksToBounds = true
        drawing.frame = bounds
        drawing.radial = radial
        drawing.pens = pens
        drawing.needsDisplay = true
        isHidden = false
    }
}

private final class RadialDrawingView: NSView {
    var radial = RadialState(page: 0, cx: 0, cy: 0, highlight: -1)
    var pens: [PenPreset] = []

    private static let baseDim = 0.10
    private static let wedgeDim = 0.16
    private static let hubDim = 0.22

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let items = RadialLayout.items(penCount: pens.count)
        let n = max(1, items.count)
        let c = CGPoint(x: bounds.midX, y: bounds.midY)
        let outerR = RadialLayout.outerRadius, innerR = RadialLayout.innerRadius, hubR = RadialLayout.hubRadius
        let iconR = (innerR + outerR) / 2

        // 盘底压暗 + 发丝描边
        let disc = CGRect(x: c.x - outerR, y: c.y - outerR, width: outerR * 2, height: outerR * 2)
        ctx.setFillColor(NSColor.black.withAlphaComponent(Self.baseDim).cgColor)
        ctx.fillEllipse(in: disc)
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.22).cgColor)
        ctx.setLineWidth(1)
        ctx.strokeEllipse(in: disc.insetBy(dx: 0.5, dy: 0.5))

        // 扇区（0 = 正上方、顺时针）
        let step = 360.0 / Double(n)
        let gap = min(RadialLayout.gapDegrees, step / 4)
        for i in 0..<n {
            let a0 = (Double(i) * step - step / 2 + gap - 90) * .pi / 180
            let a1 = (Double(i) * step + step / 2 - gap - 90) * .pi / 180
            let p = CGMutablePath()
            p.addArc(center: c, radius: outerR, startAngle: a0, endAngle: a1, clockwise: false)
            p.addArc(center: c, radius: innerR, startAngle: a1, endAngle: a0, clockwise: true)
            p.closeSubpath()
            let on = radial.highlight == i
            ctx.addPath(p)
            ctx.setFillColor(on ? tint(items[i]).withAlphaComponent(0.92).cgColor
                                : NSColor.black.withAlphaComponent(Self.wedgeDim).cgColor)
            ctx.fillPath()
            if on {
                ctx.addPath(p)
                ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.65).cgColor)
                ctx.setLineWidth(1.5)
                ctx.strokePath()
            }
        }

        // 图标：彩色圆片 + 符号
        for i in 0..<n {
            let deg = Double(i) * step - 90
            let pt = CGPoint(x: c.x + iconR * CGFloat(cos(deg * .pi / 180)), y: c.y + iconR * CGFloat(sin(deg * .pi / 180)))
            drawIcon(items[i], on: radial.highlight == i, at: pt, in: ctx)
        }

        // 中心 hub：取消区 + 当前指向项回显
        let sel = items.indices.contains(radial.highlight) ? items[radial.highlight] : nil
        let hub = CGRect(x: c.x - hubR, y: c.y - hubR, width: hubR * 2, height: hubR * 2)
        ctx.setFillColor(NSColor.black.withAlphaComponent(sel == nil ? Self.hubDim + 0.06 : Self.hubDim).cgColor)
        ctx.fillEllipse(in: hub)
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(sel == nil ? 0.55 : 0.2).cgColor)
        ctx.setLineWidth(sel == nil ? 2 : 1)
        ctx.strokeEllipse(in: hub.insetBy(dx: 1, dy: 1))
        let title = hubTitle(sel)
        let sub = hubSubtitle(sel)
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.55)
        shadow.shadowBlurRadius = 3
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        let tAttr: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13, weight: .semibold),
                                                     .foregroundColor: NSColor.white.withAlphaComponent(sel == nil ? 0.85 : 1),
                                                     .shadow: shadow]
        let sAttr: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 10, weight: .medium),
                                                     .foregroundColor: NSColor.white.withAlphaComponent(0.7), .shadow: shadow]
        let maxW = hubR * 2 - 16
        let ts = fitted(title, tAttr, maxW)
        let tSize = ts.size()
        if let sub {
            let ss = fitted(sub, sAttr, maxW)
            let sSize = ss.size()
            let total = tSize.height + 2 + sSize.height
            ts.draw(at: CGPoint(x: c.x - tSize.width / 2, y: c.y - total / 2))
            ss.draw(at: CGPoint(x: c.x - sSize.width / 2, y: c.y - total / 2 + tSize.height + 2))
        } else {
            ts.draw(at: CGPoint(x: c.x - tSize.width / 2, y: c.y - tSize.height / 2))
        }
    }

    /// 放不下就等比缩小字号（最多到 60%，同 SwiftUI 版 `minimumScaleFactor(0.6)`）。
    private func fitted(_ s: String, _ attr: [NSAttributedString.Key: Any], _ maxW: CGFloat) -> NSAttributedString {
        var a = attr
        let base = (attr[.font] as? NSFont) ?? .systemFont(ofSize: 12)
        let w = (s as NSString).size(withAttributes: attr).width
        if w > maxW {
            let k = max(0.6, maxW / w)
            a[.font] = NSFont.systemFont(ofSize: base.pointSize * k, weight: .semibold)
        }
        return NSAttributedString(string: s, attributes: a)
    }

    private func drawIcon(_ item: RadialItem, on: Bool, at p: CGPoint, in ctx: CGContext) {
        let d: CGFloat = on ? 34 : 28
        let r = CGRect(x: p.x - d / 2, y: p.y - d / 2, width: d, height: d)
        let fill: NSColor, symbol: String, symbolColor: NSColor
        switch item {
        case .pen(let i):
            guard pens.indices.contains(i) else { return }
            fill = pens[i].color.nsColor
            symbol = pens[i].type.systemImage
            let c = pens[i].color
            symbolColor = (0.299 * c.r + 0.587 * c.g + 0.114 * c.b) / 255 > 0.62 ? .black : .white
        case .erase: fill = tint(.erase); symbol = "eraser.fill"; symbolColor = .white
        case .page: fill = tint(.page); symbol = "hand.raised.fill"; symbolColor = .white
        case .scratchAdd: fill = tint(.scratchAdd); symbol = "doc.badge.plus"; symbolColor = .white
        case .textNote: fill = tint(.textNote); symbol = "note.text.badge.plus"; symbolColor = .white
        }
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 1), blur: on ? 5 : 3, color: NSColor.black.withAlphaComponent(0.3).cgColor)
        ctx.setFillColor(fill.cgColor)
        ctx.fillEllipse(in: r)
        ctx.restoreGState()
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(on ? 0.9 : 0.55).cgColor)
        ctx.setLineWidth(on ? 2 : 1)
        ctx.strokeEllipse(in: r.insetBy(dx: on ? 1 : 0.5, dy: on ? 1 : 0.5))
        let cfg = NSImage.SymbolConfiguration(pointSize: on ? 15 : 13, weight: .semibold)
            .applying(.init(paletteColors: [symbolColor]))
        if let img = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(cfg) {
            let s = img.size
            img.draw(in: CGRect(x: p.x - s.width / 2, y: p.y - s.height / 2, width: s.width, height: s.height))
        }
    }

    private func tint(_ item: RadialItem) -> NSColor {
        switch item {
        case .pen(let i): return pens.indices.contains(i) ? pens[i].color.nsColor : .controlAccentColor
        case .erase: return NSColor(srgbRed: 0.96, green: 0.55, blue: 0.20, alpha: 1)
        case .page: return NSColor(srgbRed: 0.25, green: 0.72, blue: 0.70, alpha: 1)
        case .scratchAdd: return NSColor(srgbRed: 0.60, green: 0.45, blue: 0.90, alpha: 1)
        case .textNote: return NSColor(srgbRed: 0.30, green: 0.60, blue: 0.95, alpha: 1)
        }
    }

    private func hubTitle(_ item: RadialItem?) -> String {
        switch item {
        case .none: return L("Cancel")
        case .pen(let i): return pens.indices.contains(i) ? pens[i].name : L("Pen")
        case .erase: return L("Eraser")
        case .page: return L("Page Turn")
        case .scratchAdd: return L("New Scratchpad")
        case .textNote: return L("New Text Note")
        }
    }

    private func hubSubtitle(_ item: RadialItem?) -> String? {
        guard case .pen(let i) = item, pens.indices.contains(i) else { return nil }
        let p = pens[i]
        let r = (p.width * 100).rounded() / 100
        let w = r == r.rounded() ? String(Int(r)) : String(r)
        return "\(p.type.label) · \(w)pt"
    }
}
