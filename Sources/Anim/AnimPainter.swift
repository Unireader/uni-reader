import AppKit

// 分步演示的绘制：两帧之间按物件 id 配对插值（位置、大小、颜色、线的进度），只在一边有的淡入 / 淡出（线是「长出来」）。
// 静态图、MCP 出图、实时视图都走这里，于是画面一致（`ANIM-BLOCK-PLAN.md §2`）。坐标翻转（原点左上）。

/// 颜色表：按深浅色把角色映射成 sRGB 颜色（系统动态色在指定外观下取值）。
struct AnimPalette {
    let dark: Bool
    private var colors: [String: CGColor] = [:]

    init(dark: Bool) {
        self.dark = dark
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
        var out: [String: CGColor] = [:]
        appearance.performAsCurrentDrawingAppearance {
            func put(_ key: String, _ c: NSColor) { out[key] = (c.usingColorSpace(.sRGB) ?? c).cgColor }
            let label = NSColor.labelColor
            put("ink", label)
            put("secondary", NSColor.secondaryLabelColor)
            put("grid", label.withAlphaComponent(0.32))
            put("background", NSColor.textBackgroundColor)
            let base: [AnimTone: NSColor] = [.active: .systemBlue, .done: .systemGreen, .wrong: .systemRed, .new: .systemOrange]
            for tone in AnimTone.allCases {
                switch tone {
                case .normal:
                    put("fill.normal", label.withAlphaComponent(0.04))
                    put("stroke.normal", label.withAlphaComponent(0.5))
                    put("text.normal", label)
                case .muted:
                    put("fill.muted", label.withAlphaComponent(0.06))
                    put("stroke.muted", label.withAlphaComponent(0.3))
                    put("text.muted", label.withAlphaComponent(0.38))
                default:
                    let c = base[tone]!
                    put("fill.\(tone.rawValue)", c.withAlphaComponent(dark ? 0.3 : 0.2))
                    put("stroke.\(tone.rawValue)", c)
                    put("text.\(tone.rawValue)", c)
                }
            }
        }
        colors = out
    }

    func color(_ role: AnimRole) -> CGColor {
        let key: String
        switch role {
        case .ink: key = "ink"
        case .secondary: key = "secondary"
        case .grid: key = "grid"
        case .background: key = "background"
        case .fill(let t): key = "fill.\(t.rawValue)"
        case .stroke(let t): key = "stroke.\(t.rawValue)"
        case .text(let t): key = "text.\(t.rawValue)"
        }
        return colors[key] ?? CGColor(gray: 0.5, alpha: 1)
    }
}

enum AnimPainter {
    /// 补间时长（秒）。
    static let transition: Double = 0.45

    /// 画 `from` → `to` 的第 `t`（0…1，已缓动）时刻；`to == nil` 就是只画 `from`。调用前 `NSGraphicsContext.current` 须是翻转的。
    static func draw(_ from: AnimFrame, _ to: AnimFrame?, t: CGFloat, palette: AnimPalette) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        guard let to, t > 0 else {
            for item in from.items { draw(item.shape, alpha: item.alpha, palette: palette, ctx: ctx) }
            return
        }
        if t >= 1 {
            for item in to.items { draw(item.shape, alpha: item.alpha, palette: palette, ctx: ctx) }
            return
        }
        let old = Dictionary(from.items.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let new = Set(to.items.map(\.id))
        // 先画要消失的（在底下），再按新帧顺序画
        for item in from.items where !new.contains(item.id) {
            draw(item.shape, alpha: item.alpha * (1 - t), palette: palette, ctx: ctx)
        }
        for item in to.items {
            if let a = old[item.id] {
                blend(a, item, t: t, palette: palette, ctx: ctx)
            } else if case .line(let pts, let role, let w, let dashed, let arrow, let progress) = item.shape {
                // 新出现的线：从 0 长出来
                draw(.line(pts, role: role, width: w, dashed: dashed, arrow: arrow, progress: progress * t), alpha: item.alpha, palette: palette, ctx: ctx)
            } else {
                draw(item.shape, alpha: item.alpha * t, palette: palette, ctx: ctx)
            }
        }
    }

    static func ease(_ x: Double) -> CGFloat {
        let v = min(max(x, 0), 1)
        return CGFloat(v < 0.5 ? 2 * v * v : 1 - pow(-2 * v + 2, 2) / 2)
    }

    // MARK: 插值

    private static func blend(_ a: AnimItem, _ b: AnimItem, t: CGFloat, palette: AnimPalette, ctx: CGContext) {
        let alpha = a.alpha + (b.alpha - a.alpha) * t
        switch (a.shape, b.shape) {
        case let (.box(r0, rad0, f0, s0, w0, _), .box(r1, rad1, f1, s1, w1, d1)):
            drawBox(arc(r0, r1, t), radius: lerp(rad0, rad1, t),
                    fill: mix(f0, f1, t, palette), stroke: mix(s0, s1, t, palette), lineWidth: lerp(w0, w1, t), dashed: d1, alpha: alpha, ctx: ctx)
        case let (.text(s0, f0, z0, b0, c0, a0, k0), .text(s1, f1, z1, _, c1, _, k1)):
            let frame = arc(f0, f1, t)
            if s0 == s1 && z0 == z1 {
                drawText(s1, frame: frame, size: z1, bold: b0, color: blendColor(palette.color(c0), palette.color(c1), t), align: a0,
                         backdrop: k1, palette: palette, alpha: alpha, ctx: ctx)
            } else {
                // 字变了：前半程旧字淡出、后半程新字淡入，不同时出现（同时交叉淡化会两个字叠在一格里，用户 2026-11-13 报「重叠 01」）
                let out = max(0, 1 - 2 * t), into = max(0, 2 * t - 1)
                drawText(s0, frame: frame, size: z0, bold: b0, color: palette.color(c0), align: a0, backdrop: k0, palette: palette, alpha: alpha * out, ctx: ctx)
                draw(b.shape.with(frame: frame), alpha: alpha * into, palette: palette, ctx: ctx)
            }
        case let (.line(p0, r0, w0, _, _, g0), .line(p1, r1, w1, d1, arrow, g1)):
            let pts = p0.count == p1.count ? zip(p0, p1).map { lerp($0, $1, t) } : p1
            drawLine(pts, color: blendColor(palette.color(r0), palette.color(r1), t), width: lerp(w0, w1, t), dashed: d1, arrow: arrow,
                     progress: lerp(g0, g1, t), alpha: alpha, ctx: ctx)
        case let (.cross(c0, z0, r0), .cross(c1, z1, r1)):
            drawCross(lerp(c0, c1, t), size: lerp(z0, z1, t), color: blendColor(palette.color(r0), palette.color(r1), t), alpha: alpha, ctx: ctx)
        default:
            draw(a.shape, alpha: a.alpha * (1 - t), palette: palette, ctx: ctx)
            draw(b.shape, alpha: b.alpha * t, palette: palette, ctx: ctx)
        }
    }

    private static func lerp(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat { a + (b - a) * t }
    private static func lerp(_ a: CGPoint, _ b: CGPoint, _ t: CGFloat) -> CGPoint { CGPoint(x: lerp(a.x, b.x, t), y: lerp(a.y, b.y, t)) }
    private static func lerp(_ a: CGRect, _ b: CGRect, _ t: CGFloat) -> CGRect {
        CGRect(x: lerp(a.minX, b.minX, t), y: lerp(a.minY, b.minY, t), width: lerp(a.width, b.width, t), height: lerp(a.height, b.height, t))
    }

    /// 横着换位置的格子（交换）走弧线：往右的从上面过、往左的从下面过，半路不叠在一起。
    private static func arc(_ a: CGRect, _ b: CGRect, _ t: CGFloat) -> CGRect {
        var r = lerp(a, b, t)
        let dx = b.midX - a.midX
        if abs(dx) > 1, abs(b.midY - a.midY) < 1 {
            r.origin.y -= (dx > 0 ? 1 : -1) * sin(.pi * t) * min(a.height * 0.55, 20)
        }
        return r
    }

    private static func mix(_ a: AnimRole?, _ b: AnimRole?, _ t: CGFloat, _ palette: AnimPalette) -> CGColor? {
        switch (a, b) {
        case (nil, nil): return nil
        case (let x?, nil): return palette.color(x).copy(alpha: palette.color(x).alpha * (1 - t))
        case (nil, let y?): return palette.color(y).copy(alpha: palette.color(y).alpha * t)
        case (let x?, let y?): return blendColor(palette.color(x), palette.color(y), t)
        }
    }

    private static func blendColor(_ a: CGColor, _ b: CGColor, _ t: CGFloat) -> CGColor {
        guard t > 0 else { return a }
        guard t < 1, let ca = a.components, let cb = b.components, ca.count == 4, cb.count == 4 else { return t >= 1 ? b : a }
        return CGColor(srgbRed: lerp(ca[0], cb[0], t), green: lerp(ca[1], cb[1], t), blue: lerp(ca[2], cb[2], t), alpha: lerp(ca[3], cb[3], t))
    }

    // MARK: 画

    static func draw(_ shape: AnimShape, alpha: CGFloat, palette: AnimPalette, ctx: CGContext) {
        guard alpha > 0.003 else { return }
        switch shape {
        case let .box(r, radius, fill, stroke, w, dashed):
            drawBox(r, radius: radius, fill: fill.map(palette.color), stroke: stroke.map(palette.color), lineWidth: w, dashed: dashed, alpha: alpha, ctx: ctx)
        case let .text(s, frame, size, bold, role, align, backdrop):
            drawText(s, frame: frame, size: size, bold: bold, color: palette.color(role), align: align, backdrop: backdrop, palette: palette, alpha: alpha, ctx: ctx)
        case let .line(pts, role, w, dashed, arrow, progress):
            drawLine(pts, color: palette.color(role), width: w, dashed: dashed, arrow: arrow, progress: progress, alpha: alpha, ctx: ctx)
        case let .cross(c, size, role):
            drawCross(c, size: size, color: palette.color(role), alpha: alpha, ctx: ctx)
        }
    }

    private static func drawBox(_ r: CGRect, radius: CGFloat, fill: CGColor?, stroke: CGColor?, lineWidth: CGFloat, dashed: Bool, alpha: CGFloat, ctx: CGContext) {
        ctx.saveGState()
        ctx.setAlpha(alpha)
        let path = CGPath(roundedRect: r, cornerWidth: min(radius, r.width / 2), cornerHeight: min(radius, r.height / 2), transform: nil)
        if let fill {
            ctx.addPath(path)
            ctx.setFillColor(fill)
            ctx.fillPath()
        }
        if let stroke, lineWidth > 0 {
            ctx.addPath(path)
            ctx.setStrokeColor(stroke)
            ctx.setLineWidth(lineWidth)
            if dashed { ctx.setLineDash(phase: 0, lengths: [3, 3]) }
            ctx.strokePath()
        }
        ctx.restoreGState()
    }

    private static func drawText(_ s: String, frame: CGRect, size: CGFloat, bold: Bool, color: CGColor, align: AnimAlign,
                                 backdrop: Bool, palette: AnimPalette, alpha: CGFloat, ctx: CGContext) {
        guard !s.isEmpty else { return }
        if backdrop {
            drawBox(frame, radius: 3, fill: palette.color(.background).copy(alpha: 0.92), stroke: nil, lineWidth: 0, dashed: false, alpha: alpha, ctx: ctx)
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = align == .center ? .center : align == .right ? .right : .left
        paragraph.lineBreakMode = .byWordWrapping
        let font = AnimMetrics.font(size, bold: bold) as NSFont
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor(cgColor: color)?.withAlphaComponent((NSColor(cgColor: color)?.alphaComponent ?? 1) * alpha) ?? NSColor.labelColor,
            .paragraphStyle: paragraph,
        ]
        let text = NSAttributedString(string: s, attributes: attrs)
        let bounds = text.boundingRect(with: CGSize(width: frame.width, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading])
        let h = ceil(bounds.height)
        // 一行的字在框里竖直居中；多行的（说明）从顶上排
        let y = h <= frame.height && (align == .center || backdrop || frame.height <= 20) ? frame.minY + (frame.height - h) / 2 : frame.minY
        text.draw(with: CGRect(x: frame.minX, y: y, width: frame.width, height: max(h, frame.height)), options: [.usesLineFragmentOrigin, .usesFontLeading])
        _ = ctx
    }

    private static func drawLine(_ pts: [CGPoint], color: CGColor, width: CGFloat, dashed: Bool, arrow: Bool, progress: CGFloat, alpha: CGFloat, ctx: CGContext) {
        guard pts.count >= 2, progress > 0.001 else { return }
        var lengths: [CGFloat] = []
        for i in 1..<pts.count { lengths.append(hypot(pts[i].x - pts[i - 1].x, pts[i].y - pts[i - 1].y)) }
        let total = lengths.reduce(0, +)
        guard total > 0 else { return }
        var remaining = total * min(progress, 1)
        var drawn = [pts[0]]
        for i in 1..<pts.count {
            let l = lengths[i - 1]
            if remaining >= l {
                drawn.append(pts[i])
                remaining -= l
            } else {
                let f = l > 0 ? remaining / l : 0
                drawn.append(lerp(pts[i - 1], pts[i], f))
                break
            }
        }
        ctx.saveGState()
        ctx.setAlpha(alpha)
        ctx.setStrokeColor(color)
        ctx.setLineWidth(width)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        if dashed { ctx.setLineDash(phase: 0, lengths: [5, 4]) }
        ctx.addLines(between: drawn)
        ctx.strokePath()
        if arrow, drawn.count >= 2 {
            let tip = drawn[drawn.count - 1], prev = drawn[drawn.count - 2]
            let angle = atan2(tip.y - prev.y, tip.x - prev.x)
            let size: CGFloat = 7
            ctx.setLineDash(phase: 0, lengths: [])
            ctx.setFillColor(color)
            ctx.move(to: tip)
            ctx.addLine(to: CGPoint(x: tip.x - size * cos(angle - 0.4), y: tip.y - size * sin(angle - 0.4)))
            ctx.addLine(to: CGPoint(x: tip.x - size * cos(angle + 0.4), y: tip.y - size * sin(angle + 0.4)))
            ctx.closePath()
            ctx.fillPath()
        }
        ctx.restoreGState()
    }

    private static func drawCross(_ c: CGPoint, size: CGFloat, color: CGColor, alpha: CGFloat, ctx: CGContext) {
        ctx.saveGState()
        ctx.setAlpha(alpha)
        ctx.setStrokeColor(color)
        ctx.setLineWidth(2)
        ctx.setLineCap(.round)
        ctx.move(to: CGPoint(x: c.x - size, y: c.y - size)); ctx.addLine(to: CGPoint(x: c.x + size, y: c.y + size))
        ctx.move(to: CGPoint(x: c.x + size, y: c.y - size)); ctx.addLine(to: CGPoint(x: c.x - size, y: c.y + size))
        ctx.strokePath()
        ctx.restoreGState()
    }
}

private extension AnimShape {
    func with(frame: CGRect) -> AnimShape {
        if case let .text(s, _, size, bold, role, align, backdrop) = self {
            return .text(s, frame: frame, size: size, bold: bold, role: role, align: align, backdrop: backdrop)
        }
        return self
    }
}

// MARK: - 整块：画布 + 错误 + 控制条位置

/// 一块演示的完整尺寸：画布（布局）+ 错误行 + 控制条。静态图和实时视图按同一份算，叠上去严丝合缝。
struct AnimBlockMetrics {
    static let controlsHeight: CGFloat = 32
    static let minWidth: CGFloat = 280
    static let maxWidth: CGFloat = 720
    static let maxErrorLines = 4

    let layout: AnimLayout
    let errorLines: [String]
    let errorHeight: CGFloat

    init(run: AnimRun, width: CGFloat) {
        layout = AnimLayout(run: run, width: width)
        var lines = run.errors.prefix(Self.maxErrorLines).map { String(format: L("Line %ld: %@"), $0.line, $0.message) }
        if run.errors.count > Self.maxErrorLines { lines.append("…") }
        errorLines = lines
        errorHeight = lines.isEmpty ? 0 : AnimMetrics.measure(lines.joined(separator: "\n"), size: AnimMetrics.small, maxWidth: width - 2 * AnimMetrics.pad).height + 8
    }

    var canvasHeight: CGFloat { layout.height + errorHeight }

    func height(withControls: Bool) -> CGFloat { ceil(canvasHeight + (withControls ? Self.controlsHeight : 0)) }

    static func clampedWidth(_ w: CGFloat) -> CGFloat { min(max(w, minWidth), maxWidth).rounded(.down) }

    /// 错误行（红字，画在布局下面）。
    func drawErrors(palette: AnimPalette) {
        guard !errorLines.isEmpty else { return }
        let rect = CGRect(x: AnimMetrics.pad, y: layout.height, width: layout.width - 2 * AnimMetrics.pad, height: errorHeight)
        AnimPainter.draw(.text(errorLines.joined(separator: "\n"), frame: rect, size: AnimMetrics.small, bold: false, role: .text(.wrong),
                               align: .left, backdrop: false), alpha: 1, palette: palette, ctx: NSGraphicsContext.current!.cgContext)
    }
}

// MARK: - 出图

enum AnimSnapshot {
    /// 一步的图（`controls` = 在下方留出控制条的位置并写上「▶ 0 / N」，给编辑区里的静态图用）。
    static func image(run: AnimRun, width: CGFloat, step: Int, dark: Bool, scale: CGFloat, controls: Bool) -> CGImage? {
        let metrics = AnimBlockMetrics(run: run, width: width)
        let size = CGSize(width: width, height: metrics.height(withControls: controls))
        let palette = AnimPalette(dark: dark)
        return render(size: size, scale: scale, background: nil) {
            AnimPainter.draw(metrics.layout.frame(step: step), nil, t: 0, palette: palette)
            metrics.drawErrors(palette: palette)
            if controls {
                let text = "▶  \(step) / \(max(run.stepCount - 1, 0))"
                let r = CGRect(x: AnimMetrics.pad, y: metrics.canvasHeight, width: width - 2 * AnimMetrics.pad, height: AnimBlockMetrics.controlsHeight)
                AnimPainter.draw(.text(text, frame: r, size: AnimMetrics.body, bold: false, role: .secondary, align: .left, backdrop: false),
                                 alpha: 1, palette: palette, ctx: NSGraphicsContext.current!.cgContext)
            }
        }
    }

    /// 所有步的缩略图拼板（MCP 给 Agent 一次看完整个过程）：每格左上角标步号。
    static func contactSheet(run: AnimRun, width: CGFloat, dark: Bool, scale: CGFloat) -> CGImage? {
        let metrics = AnimBlockMetrics(run: run, width: width)
        let steps = run.stepCount
        let columns = steps <= 1 ? 1 : 2
        let rows = (steps + columns - 1) / columns
        let cellW = width, cellH = metrics.canvasHeight
        let gap: CGFloat = 10
        let size = CGSize(width: CGFloat(columns) * cellW + CGFloat(columns - 1) * gap,
                          height: CGFloat(rows) * (cellH + 18) + CGFloat(rows - 1) * gap)
        let palette = AnimPalette(dark: dark)
        return render(size: size, scale: scale, background: palette.color(.background)) {
            guard let ctx = NSGraphicsContext.current?.cgContext else { return }
            for k in 0..<steps {
                let col = k % columns, row = k / columns
                let origin = CGPoint(x: CGFloat(col) * (cellW + gap), y: CGFloat(row) * (cellH + 18 + gap))
                AnimPainter.draw(.text(L("Step") + " \(k)", frame: CGRect(x: origin.x + 4, y: origin.y, width: cellW, height: 16), size: AnimMetrics.small,
                                       bold: true, role: .text(.active), align: .left, backdrop: false), alpha: 1, palette: palette, ctx: ctx)
                AnimPainter.draw(.box(CGRect(x: origin.x, y: origin.y + 18, width: cellW, height: cellH), radius: 6, fill: nil, stroke: .grid,
                                      lineWidth: 1, dashed: false), alpha: 1, palette: palette, ctx: ctx)
                ctx.saveGState()
                ctx.translateBy(x: origin.x, y: origin.y + 18)
                AnimPainter.draw(metrics.layout.frame(step: k), nil, t: 0, palette: palette)
                if k == 0 { metrics.drawErrors(palette: palette) }
                ctx.restoreGState()
            }
        }
    }

    /// 在翻转的位图上下文里画（`body` 里 `NSGraphicsContext.current` 已设好）。
    static func render(size: CGSize, scale: CGFloat, background: CGColor?, body: () -> Void) -> CGImage? {
        let pw = Int((size.width * scale).rounded()), ph = Int((size.height * scale).rounded())
        guard pw > 0, ph > 0, pw * ph <= 40_000_000,
              let ctx = CGContext(data: nil, width: pw, height: ph, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        if let background {
            ctx.setFillColor(background)
            ctx.fill(CGRect(x: 0, y: 0, width: pw, height: ph))
        }
        ctx.translateBy(x: 0, y: CGFloat(ph))
        ctx.scaleBy(x: scale, y: -scale)
        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        body()
        NSGraphicsContext.current = previous
        return ctx.makeImage()
    }
}
