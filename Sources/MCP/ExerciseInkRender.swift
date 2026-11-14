import AppKit

/// 以前手写小画板（v21 `exercise_attempt.ink`，2026-11-14 起改成每道题一张草稿纸、`EXERCISE-PLAN.md §29`）存下的手写怎么出图：
/// MCP `render_exercise_answer` 遇到这道题没有草稿纸、作答里还带着老手写时用。
enum ExerciseInkRender {
    /// 笔宽（逻辑点）。圆珠笔压感 0.5 时实际约 1.9 点粗。
    static let penWidth: Double = 2.6
    static let color = InkColor(r: 28, g: 28, b: 30, a: 1)

    private static func inkStroke(_ s: ExerciseInk.Stroke) -> InkStroke {
        InkStroke(page: 0, color: color, width: s.width, type: .ballpoint,
                  points: s.points.map { q in
                      InkPoint(q.count > 0 ? q[0] : 0, q.count > 1 ? q[1] : 0, q.count > 2 ? q[2] : 0.5)
                  })
    }

    /// 在 `ctx` 里画（y 向下的坐标；1 逻辑点 = `scale` 个单位）。
    private static func draw(_ strokes: [ExerciseInk.Stroke], in ctx: CGContext, scale: CGFloat) {
        for s in strokes {
            InkRenderCG.drawStroke(inkStroke(s), in: ctx, inkScale: scale) { p in
                CGPoint(x: CGFloat(p.x) * scale, y: CGFloat(p.y) * scale)
            }
        }
    }

    /// 白底 PNG（`pixelWidth` 像素宽，高按画板比例）。没有笔画 → nil。
    static func png(_ ink: ExerciseInk, pixelWidth: Int) -> Data? {
        guard !ink.isEmpty, ink.width > 0 else { return nil }
        let scale = CGFloat(pixelWidth) / CGFloat(ink.width)
        let h = max(1, Int((CGFloat(ink.height) * scale).rounded(.up)))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: pixelWidth, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: pixelWidth, height: h))
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)
        draw(ink.strokes, in: ctx, scale: scale)
        guard let img = ctx.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])
    }
}
