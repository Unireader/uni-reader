import AppKit
import QuartzCore

// 草稿纸的画布图层（AppKit 版，替代 SwiftUI `ScratchCanvasLayers`）：底纹 / 页面底图 / 笔迹 / 框选装饰 / minimap / 纸样小样。
// 全部是纯绘制：视口一变整层重画（与 SwiftUI 版 Canvas 的开销同量级），没有隐式动画（`QuietLayer`）。

// MARK: - 底纹（点阵 / 小格 + 原点十字）

/// 无限画布的空间参照：一层极淡的点阵 / 细格跟着画布走，平移缩放才看得出「在动」。
/// 屏幕间距自适应（按 2 的幂折进约 22~88 像素），任何缩放下密度都差不多；原点另画一个稍明显的十字。
/// ⚠️ 点的大小 / 浓度与 web `scratch.ts drawPattern` 是同一套数，改一边必须同步另一边。
final class ScratchGridCALayer: QuietLayer {
    var viewport = ScratchViewport()
    var ink: NSColor = .black
    var pattern: ScratchPattern = .dots

    private var step: CGFloat {
        var s: CGFloat = 24
        let z = max(viewport.zoom, 0.0001)
        while s * z < 22 { s *= 2 }
        while s * z > 88 { s /= 2 }
        return s
    }

    override func draw(in ctx: CGContext) {
        guard pattern != .plain else { return }   // 纯色纸：连原点十字都不画
        yDown(ctx)
        let size = bounds.size
        let z = viewport.zoom, o = viewport.origin, st = step
        let dot = max(1.5, min(3, z * 1.8))
        let x0 = (o.x / st).rounded(.down) * st, y0 = (o.y / st).rounded(.down) * st
        let cols = Int(size.width / (st * z)) + 2, rows = Int(size.height / (st * z)) + 2
        guard cols > 0, rows > 0, cols * rows <= 20_000 else { return }   // 极端缩放下的安全阀
        if pattern == .grid {
            ctx.setStrokeColor(ink.withAlphaComponent(0.085).cgColor)
            ctx.setLineWidth(1)
            for i in 0...cols {
                let x = (x0 + CGFloat(i) * st - o.x) * z
                ctx.move(to: CGPoint(x: x, y: 0)); ctx.addLine(to: CGPoint(x: x, y: size.height))
            }
            for j in 0...rows {
                let y = (y0 + CGFloat(j) * st - o.y) * z
                ctx.move(to: CGPoint(x: 0, y: y)); ctx.addLine(to: CGPoint(x: size.width, y: y))
            }
            ctx.strokePath()
        } else {
            ctx.setFillColor(ink.withAlphaComponent(0.18).cgColor)
            for i in 0...cols {
                for j in 0...rows {
                    let cx = x0 + CGFloat(i) * st, cy = y0 + CGFloat(j) * st
                    let p = CGPoint(x: (cx - o.x) * z, y: (cy - o.y) * z)
                    ctx.addRect(CGRect(x: p.x - dot / 2, y: p.y - dot / 2, width: dot, height: dot))
                }
            }
            ctx.fillPath()
        }
        let og = CGPoint(x: -o.x * z, y: -o.y * z)
        if og.x > -40, og.x < size.width + 40, og.y > -40, og.y < size.height + 40 {
            ctx.setStrokeColor(ink.withAlphaComponent(0.16).cgColor)
            ctx.setLineWidth(1)
            ctx.move(to: CGPoint(x: og.x - 9, y: og.y)); ctx.addLine(to: CGPoint(x: og.x + 9, y: og.y))
            ctx.move(to: CGPoint(x: og.x, y: og.y - 9)); ctx.addLine(to: CGPoint(x: og.x, y: og.y + 9))
            ctx.strokePath()
        }
    }
}

// MARK: - 笔迹（已落的 + 正在写的，线宽随缩放变粗，与页内笔迹同一语义）

final class ScratchInkCALayer: QuietLayer {
    var viewport = ScratchViewport()
    var strokes: [InkStroke] = []

    override func draw(in ctx: CGContext) {
        guard !strokes.isEmpty else { return }
        yDown(ctx)
        let o = viewport.origin, z = viewport.zoom
        let vis = CGRect(origin: .zero, size: bounds.size).insetBy(dx: -60, dy: -60)
        for st in strokes {
            // 整笔都在视口外就不画（大纸平移时省下大半）
            if let b = Self.bounds(st), !vis.intersects(CGRect(x: (b.minX - o.x) * z, y: (b.minY - o.y) * z,
                                                                width: b.width * z, height: b.height * z)) { continue }
            InkRenderCG.drawStroke(st, in: ctx, inkScale: z) {
                CGPoint(x: (CGFloat($0.x) - o.x) * z, y: (CGFloat($0.y) - o.y) * z)
            }
        }
    }

    static func bounds(_ st: InkStroke) -> CGRect? {
        guard !st.points.isEmpty else { return nil }
        var lo = SIMD2<Double>(.infinity, .infinity), hi = SIMD2<Double>(-.infinity, -.infinity)
        for p in st.points {
            lo = SIMD2(min(lo.x, p.dx), min(lo.y, p.dy))
            hi = SIMD2(max(hi.x, p.dx), max(hi.y, p.dy))
        }
        let pad = st.width * 2
        return CGRect(x: lo.x - pad, y: lo.y - pad, width: hi.x - lo.x + pad * 2, height: hi.y - lo.y + pad * 2)
    }
}

// MARK: - 页面底图（v10）

/// 把这张纸锚定的那一页垫在纸上当参照（几何是三端契约 `ScratchPad.pageRect`）。
/// 页图之上还有笔迹；不跟夜间反色；图没到时先铺白 + 描边占位（白页压白纸看不出页边）。
final class ScratchPageCALayer: QuietLayer {
    private let image = QuietLayer()

    override init() {
        super.init()
        backgroundColor = CGColor(gray: 1, alpha: 1)
        borderWidth = 1
        image.contentsGravity = .resize
        image.minificationFilter = .trilinear
        addSublayer(image)
    }
    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { fatalError("init(coder:) 不支持") }

    func set(image img: CGImage?, frame f: CGRect, ink: NSColor) {
        frame = f
        image.frame = CGRect(origin: .zero, size: f.size)
        image.contents = img
        borderColor = ink.withAlphaComponent(0.3).cgColor
    }
}

// MARK: - 画板笔记上的图（v16，`BOARD-NOTE-PLAN.md §3.3`）

/// 画板上的图：每张一个子图层，按画布矩形映到视口。层序在笔迹之下、底纹之上。
/// 图本体由调用方按 sha 喂进来（`setImage`，后台解码好的 CGImage），没到之前铺一块淡灰占位。
final class BoardImagesCALayer: QuietLayer {
    var viewport = ScratchViewport()
    private var subs: [UUID: QuietLayer] = [:]
    private var items: [BoardImage] = []
    private var bitmaps: [String: CGImage] = [:]

    /// 换一批图（增删 / 挪动 / 缩放后）：子图层按新顺序重排，多余的撤掉。
    func sync(_ images: [BoardImage]) {
        items = images
        let live = Set(images.map(\.id))
        for (id, l) in subs where !live.contains(id) { l.removeFromSuperlayer(); subs[id] = nil }
        for (i, im) in images.enumerated() {
            let l = subs[im.id] ?? {
                let n = QuietLayer()
                n.contentsGravity = .resize
                n.minificationFilter = .trilinear
                n.backgroundColor = CGColor(gray: 0.5, alpha: 0.12)
                subs[im.id] = n
                return n
            }()
            if l.superlayer !== self || (sublayers?.firstIndex(of: l) ?? -1) != i { insertSublayer(l, at: UInt32(i)) }
            l.contents = bitmaps[im.image]
            if l.contents != nil { l.backgroundColor = nil }
        }
        relayout()
    }

    /// 某张图的像素到了（同一张图在画板上贴了几次就填几处）。
    func setImage(_ img: CGImage, sha: String) {
        bitmaps[sha] = img
        for im in items where im.image == sha {
            subs[im.id]?.contents = img
            subs[im.id]?.backgroundColor = nil
        }
    }

    func hasImage(_ sha: String) -> Bool { bitmaps[sha] != nil }

    /// 视口变了：只改子图层 frame（位图不重画），视口外的藏起来。
    func relayout() {
        let o = viewport.origin, z = viewport.zoom
        let vis = CGRect(origin: .zero, size: bounds.size).insetBy(dx: -40, dy: -40)
        for im in items {
            guard let l = subs[im.id] else { continue }
            let r = CGRect(x: (im.rect.minX - o.x) * z, y: (im.rect.minY - o.y) * z,
                           width: im.rect.width * z, height: im.rect.height * z)
            l.isHidden = !vis.intersects(r)
            if !l.isHidden { l.frame = r }
        }
    }
}

// MARK: - 框选装饰（选中光晕 + 高亮框 / 手柄 + 进行中的虚线路径，全是视图坐标）

final class ScratchLassoCALayer: QuietLayer {
    /// 选中笔迹（已按 ghost 变换映到视图坐标的折线）+ 每笔的视图线宽。
    var halo: [(points: [CGPoint], width: CGFloat)] = []
    /// 高亮框（ghost 变换后的手柄外接框）与手柄点。
    var box: CGRect?
    var handles: [CGPoint] = []
    var path: [CGPoint] = []

    override func draw(in ctx: CGContext) {
        yDown(ctx)
        let accent = NSColor.controlAccentColor
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        for h in halo {
            ctx.setStrokeColor(accent.withAlphaComponent(0.35).cgColor)
            ctx.setFillColor(accent.withAlphaComponent(0.35).cgColor)
            if h.points.count == 1 {
                let p = h.points[0], r = h.width / 2
                ctx.fillEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2))
            } else if h.points.count > 1 {
                ctx.setLineWidth(h.width)
                ctx.addLines(between: h.points)
                ctx.strokePath()
            }
        }
        if let b = box {
            let rr = CGPath(roundedRect: b, cornerWidth: 4, cornerHeight: 4, transform: nil)
            ctx.addPath(rr)
            ctx.setFillColor(accent.withAlphaComponent(0.08).cgColor)
            ctx.fillPath()
            ctx.addPath(rr)
            ctx.setStrokeColor(accent.cgColor)
            ctx.setLineWidth(1.5)
            ctx.setLineDash(phase: 0, lengths: [6, 4])
            ctx.strokePath()
            ctx.setLineDash(phase: 0, lengths: [])
            for p in handles {
                let r = CGRect(x: p.x - 4.5, y: p.y - 4.5, width: 9, height: 9)
                ctx.setFillColor(accent.withAlphaComponent(0.25).cgColor)
                ctx.fillEllipse(in: r)
                ctx.setStrokeColor(accent.cgColor)
                ctx.setLineWidth(1.5)
                ctx.strokeEllipse(in: r)
            }
        }
        if path.count >= 2 {
            ctx.addLines(between: path)
            ctx.closePath()
            ctx.setFillColor(accent.withAlphaComponent(0.06).cgColor)
            ctx.fillPath()
            ctx.addLines(between: path)
            ctx.closePath()
            ctx.setStrokeColor(accent.cgColor)
            ctx.setLineWidth(1)
            ctx.setLineDash(phase: 0, lengths: [5, 4])
            ctx.strokePath()
        }
    }
}

// MARK: - minimap

/// 右下角缩略图：「全部笔迹包围盒 ∪ 当前视口」等比装进小窗，画笔迹骨架 + 当前视口框；点 / 拖即跳（回调画布坐标）。
final class ScratchMinimapView: NSView {
    var strokes: [InkStroke] = [] { didSet { needsDisplay = true } }
    var viewport = ScratchViewport() { didSet { if oldValue != viewport { needsDisplay = true } } }
    var viewSize: CGSize = .zero { didSet { if oldValue != viewSize { needsDisplay = true } } }
    var pageRect: CGRect? { didSet { if oldValue != pageRect { needsDisplay = true } } }
    /// 画板笔记上的图（画布矩形）：画成淡框，也计入装框范围。
    var imageRects: [CGRect] = [] { didSet { if oldValue != imageRects { needsDisplay = true } } }
    var onJump: (CGPoint) -> Void = { _ in }

    private let shell = NSVisualEffectView()
    private let canvas = MinimapCanvas()
    private static let inset: CGFloat = 9

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        shadow = {
            let s = NSShadow()
            s.shadowColor = NSColor.black.withAlphaComponent(0.3)
            s.shadowBlurRadius = 6
            s.shadowOffset = NSSize(width: 0, height: -2)
            return s
        }()
        shell.material = .popover
        shell.blendingMode = .withinWindow
        shell.state = .active
        shell.wantsLayer = true
        shell.layer?.cornerRadius = 10
        shell.layer?.cornerCurve = .continuous
        shell.layer?.masksToBounds = true
        shell.layer?.borderWidth = 0.5
        shell.layer?.borderColor = NSColor.white.withAlphaComponent(0.15).cgColor
        addSubview(shell)
        canvas.owner = self
        shell.addSubview(canvas)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) 不支持") }

    override var needsDisplay: Bool {
        didSet { if needsDisplay { canvas.needsDisplay = true } }
    }

    override func layout() {
        super.layout()
        shell.frame = bounds
        canvas.frame = bounds
    }

    fileprivate struct Fit {
        let world: CGRect, s: CGFloat, ox: CGFloat, oy: CGFloat
        func map(_ x: Double, _ y: Double) -> CGPoint {
            CGPoint(x: ox + (CGFloat(x) - world.minX) * s, y: oy + (CGFloat(y) - world.minY) * s)
        }
        func unmap(_ p: CGPoint) -> CGPoint {
            CGPoint(x: world.minX + (p.x - ox) / s, y: world.minY + (p.y - oy) / s)
        }
    }

    fileprivate func fit() -> Fit {
        let vis = viewport.visibleRect(viewport: viewSize)
        var content = ScratchBounds.contentBounds(strokes, page: pageRect)
        for r in imageRects { content = content.map { $0.union(r) } ?? r }
        var w = content.map { $0.union(vis) } ?? vis
        if w.width < 1 || w.height < 1 { w = CGRect(x: -400, y: -300, width: 800, height: 600) }
        w = w.insetBy(dx: -w.width * 0.08, dy: -w.height * 0.08)
        let box = bounds.size
        let iw = max(1, box.width - Self.inset * 2), ih = max(1, box.height - Self.inset * 2)
        let s = min(iw / max(w.width, 1), ih / max(w.height, 1))
        return Fit(world: w, s: s, ox: Self.inset + (iw - w.width * s) / 2, oy: Self.inset + (ih - w.height * s) / 2)
    }

    override func mouseDown(with event: NSEvent) { jump(event) }
    override func mouseDragged(with event: NSEvent) { jump(event) }
    private func jump(_ event: NSEvent) {
        let f = fit()
        guard f.s > 0 else { return }
        onJump(f.unmap(convert(event.locationInWindow, from: nil)))
    }
}

private final class MinimapCanvas: NSView {
    weak var owner: ScratchMinimapView?
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let o = owner, let ctx = NSGraphicsContext.current?.cgContext else { return }
        let f = o.fit()
        let ink = NSColor.labelColor
        if let pr = o.pageRect {
            let tl = f.map(Double(pr.minX), Double(pr.minY))
            let box = CGRect(x: tl.x, y: tl.y, width: pr.width * f.s, height: pr.height * f.s)
            ctx.setFillColor(ink.withAlphaComponent(0.06).cgColor)
            ctx.fill(box)
            ctx.setStrokeColor(ink.withAlphaComponent(0.3).cgColor)
            ctx.setLineWidth(0.75)
            ctx.stroke(box)
        }
        for ir in o.imageRects {
            let tl = f.map(Double(ir.minX), Double(ir.minY))
            let box = CGRect(x: tl.x, y: tl.y, width: ir.width * f.s, height: ir.height * f.s)
            ctx.setFillColor(ink.withAlphaComponent(0.12).cgColor)
            ctx.fill(box)
        }
        // 骨架线即可（不必还原笔型 / 压感）
        ctx.setStrokeColor(ink.withAlphaComponent(0.62).cgColor)
        ctx.setLineWidth(1)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        for st in o.strokes where st.points.count > 1 {
            ctx.move(to: f.map(st.points[0].dx, st.points[0].dy))
            for p in st.points.dropFirst() { ctx.addLine(to: f.map(p.dx, p.dy)) }
        }
        ctx.strokePath()
        // 当前视口框：淡填充 + 细描边
        let vis = o.viewport.visibleRect(viewport: o.viewSize)
        let tl = f.map(Double(vis.minX), Double(vis.minY))
        let r = CGRect(x: tl.x, y: tl.y, width: max(6, vis.width * f.s), height: max(6, vis.height * f.s))
        let accent = NSColor.controlAccentColor
        let path = CGPath(roundedRect: r, cornerWidth: 2, cornerHeight: 2, transform: nil)
        ctx.addPath(path)
        ctx.setFillColor(accent.withAlphaComponent(0.06).cgColor)
        ctx.fillPath()
        ctx.addPath(path)
        ctx.setStrokeColor(accent.withAlphaComponent(0.85).cgColor)
        ctx.setLineWidth(1)
        ctx.strokePath()
    }
}

// MARK: - 纸样小样（选择器里的缩略预览，固定步长）

final class PaperSwatchView: NSView {
    var bg: InkColor = .paper { didSet { needsDisplay = true } }
    var pattern: ScratchPattern = .dots { didSet { needsDisplay = true } }
    var selected = false { didSet { needsDisplay = true } }
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let r = bounds.insetBy(dx: 1, dy: 1)
        let clip = CGPath(roundedRect: r, cornerWidth: 5, cornerHeight: 5, transform: nil)
        ctx.saveGState()
        ctx.addPath(clip)
        ctx.clip()
        ctx.setFillColor(bg.nsColor.cgColor)
        ctx.fill(r)
        let lum = (0.299 * bg.r + 0.587 * bg.g + 0.114 * bg.b) / 255
        let ink: NSColor = lum > 0.5 ? .black : .white
        let st: CGFloat = 7
        switch pattern {
        case .plain: break
        case .dots:
            ctx.setFillColor(ink.withAlphaComponent(0.32).cgColor)
            var y = r.minY + st / 2
            while y < r.maxY {
                var x = r.minX + st / 2
                while x < r.maxX { ctx.addRect(CGRect(x: x, y: y, width: 1.2, height: 1.2)); x += st }
                y += st
            }
            ctx.fillPath()
        case .grid:
            ctx.setStrokeColor(ink.withAlphaComponent(0.26).cgColor)
            ctx.setLineWidth(0.7)
            var x = r.minX + st / 2
            while x < r.maxX { ctx.move(to: CGPoint(x: x, y: r.minY)); ctx.addLine(to: CGPoint(x: x, y: r.maxY)); x += st }
            var y = r.minY + st / 2
            while y < r.maxY { ctx.move(to: CGPoint(x: r.minX, y: y)); ctx.addLine(to: CGPoint(x: r.maxX, y: y)); y += st }
            ctx.strokePath()
        }
        ctx.restoreGState()
        ctx.addPath(clip)
        ctx.setStrokeColor(selected ? NSColor.controlAccentColor.cgColor : NSColor.labelColor.withAlphaComponent(0.22).cgColor)
        ctx.setLineWidth(selected ? 2 : 0.5)
        ctx.strokePath()
    }
}
