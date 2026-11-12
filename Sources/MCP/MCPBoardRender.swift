import AppKit

/// 画板出图（MCP `render_board`，`BOARD-NOTE-PLAN.md §10`，用户 2026-11-12：Agent 看不到画板上手写的东西）。
///
/// 层序与画布一致：纸色 → 页面格线（分页画板）→ 图片 → 笔迹。坐标 = 画布逻辑点（左上原点），
/// 同 `ScratchInkTiles` 的出图：上下文翻成 y 向下，`InkRenderCG.drawStroke` 按 `(p - 原点) × k` 映射，`inkScale` = k。
/// 纯 CG，不碰主线程；图片的文件位置由调用方在主线程查好（`imageInfo(sha256:)`）。
enum MCPBoardRender {
    struct Input {
        var paper: InkColor
        /// 要出的那块（画布坐标）：分页画板 = 那一页；无限画板 = 内容包围盒加边。
        var area: CGRect
        /// 分页画板那一页的格线（页内坐标）与它在画布上的原点；无限画板 nil。
        var template: (shape: BoardTemplateGeometry.Shape, origin: CGPoint)?
        var strokes: [InkStroke]
        var images: [(rect: CGRect, url: URL?)]
    }

    /// 出图像素上限（宽 × 高）：很高的无限画板按比例缩小，别一张图几十兆。
    static let maxPixels: CGFloat = 16_000_000

    static func render(_ input: Input, pixelWidth: Int, format: PageRenderer.Format) -> (data: Data, width: Int, height: Int)? {
        let a = input.area
        guard a.width > 0, a.height > 0 else { return nil }
        var k = CGFloat(pixelWidth) / a.width
        if a.width * a.height * k * k > maxPixels { k = (maxPixels / (a.width * a.height)).squareRoot() }
        let w = max(1, Int((a.width * k).rounded())), h = max(1, Int((a.height * k).rounded()))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)
        func map(_ p: CGPoint) -> CGPoint { CGPoint(x: (p.x - a.minX) * k, y: (p.y - a.minY) * k) }
        func mapRect(_ r: CGRect) -> CGRect { CGRect(origin: map(r.origin), size: CGSize(width: r.width * k, height: r.height * k)) }

        let paper = input.paper
        ctx.setFillColor(CGColor(srgbRed: paper.r / 255, green: paper.g / 255, blue: paper.b / 255, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))

        if let t = input.template {
            // 同 `BoardPagesCALayer`：浅色纸画黑线、深色纸画白线
            let r: Double = paper.r, g: Double = paper.g, b: Double = paper.b
            let lum: Double = (0.299 * r + 0.587 * g + 0.114 * b) / 255
            let light = lum > 0.5
            let ink: CGFloat = light ? 0 : 1
            func pm(_ p: CGPoint) -> CGPoint { map(CGPoint(x: p.x + t.origin.x, y: p.y + t.origin.y)) }
            if !t.shape.thin.isEmpty {
                ctx.setStrokeColor(CGColor(gray: ink, alpha: 0.14))
                ctx.setLineWidth(max(0.5, k))
                for (p, q) in t.shape.thin { ctx.move(to: pm(p)); ctx.addLine(to: pm(q)) }
                ctx.strokePath()
            }
            if !t.shape.bold.isEmpty {
                ctx.setStrokeColor(CGColor(gray: ink, alpha: 0.30))
                ctx.setLineWidth(max(0.75, 1.5 * k))
                for (p, q) in t.shape.bold { ctx.move(to: pm(p)); ctx.addLine(to: pm(q)) }
                ctx.strokePath()
            }
            if !t.shape.dots.isEmpty {
                ctx.setFillColor(CGColor(gray: ink, alpha: 0.30))
                let d = max(1, BoardTemplateGeometry.dotSize * k)
                for p in t.shape.dots { let q = pm(p); ctx.addRect(CGRect(x: q.x - d / 2, y: q.y - d / 2, width: d, height: d)) }
                ctx.fillPath()
            }
        }

        let maxSide = Int(max(CGFloat(w), CGFloat(h)))
        for im in input.images where im.rect.intersects(a) {
            guard let url = im.url, let cg = ImageAssets.load(url, maxPixel: maxSide) else { continue }
            let r = mapRect(im.rect)
            // 上下文是翻过的：图片要再翻回来画，不然上下颠倒
            ctx.saveGState()
            ctx.translateBy(x: r.minX, y: r.maxY)
            ctx.scaleBy(x: 1, y: -1)
            ctx.draw(cg, in: CGRect(origin: .zero, size: r.size))
            ctx.restoreGState()
        }

        for st in input.strokes {
            InkRenderCG.drawStroke(st, in: ctx, inkScale: k) { p in
                CGPoint(x: (CGFloat(p.x) - a.minX) * k, y: (CGFloat(p.y) - a.minY) * k)
            }
        }

        guard let img = ctx.makeImage(), let data = PageRenderer.encode(img, format: format) else { return nil }
        return (data, w, h)
    }
}
