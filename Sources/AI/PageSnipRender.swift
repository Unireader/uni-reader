import CoreGraphics
import Foundation
import PDFKit

extension PageSnip {
    /// 一次截图的成品。
    struct Shot {
        var data: Data              // JPEG
        var pixelSize: CGSize
        var pageCount: Int          // 跨了几页（1 = 页内）
    }

    /// 🔴 **不截屏幕，按页重渲染。**
    ///
    /// 屏幕上那份页位图在缩小状态下本来就是低分辨率的，直接截屏发过去小字全糊。这里把归一化切片
    /// 折回「页显示坐标 pt」，走与阅读区同一条渲染原语 `PageBitmap.renderTile` 重新出图，
    /// 倍率按目标像素定（`PageSnip.scale`），与当前缩放无关。
    ///
    /// **夜间反色不进截图**：`renderTile` 本身不反色（反色是 `PageRenderEngine` 拿到图之后才加的），
    /// 所以这里天然拿到原始白底黑字——正是要发给模型的样子。
    static func render(pdf: PDFDocument, region: Region,
                       quality: CGFloat = PageRenderer.defaultJPEGQuality) -> Shot? {
        let sl = slices(region)
        guard !sl.isEmpty else { return nil }

        // ① 归一化切片 → 该页的显示坐标矩形（pt，左上原点，正是 renderTile 要的形状）
        var boxes: [(page: PDFPage, rect: CGRect)] = []
        var ptW: Double = 0
        var ptH: Double = 0
        for s in sl {
            guard let page = pdf.page(at: s.page) else { continue }
            let disp = PageBitmap.displaySize(page)
            let r = CGRect(x: s.rect.minX * disp.width, y: s.rect.minY * disp.height,
                           width: s.rect.width * disp.width, height: s.rect.height * disp.height)
            guard r.width > 0.5, r.height > 0.5 else { continue }
            ptW = max(ptW, Double(r.width))
            ptH += Double(r.height)
            boxes.append((page, r))
        }
        guard !boxes.isEmpty, ptW > 0, ptH > 0 else { return nil }

        // ② 倍率按目标像素定
        let s = CGFloat(scale(ptWidth: ptW, ptHeight: ptH))
        let tiles = boxes.compactMap { PageBitmap.renderTile(page: $0.page, subRect: $0.rect, scale: s) }
        guard !tiles.isEmpty else { return nil }

        // ③ 单页直接用，跨页纵向拼接
        let pxW = Int((ptW * Double(s)).rounded())
        guard let out = tiles.count == 1 ? tiles[0] : stack(tiles, width: pxW),
              let data = PageRenderer.encode(out, format: .jpeg(quality: quality))
        else { return nil }
        return Shot(data: data, pixelSize: CGSize(width: out.width, height: out.height),
                    pageCount: tiles.count)
    }

    /// 跨页：各页切片纵向拼接，中间留一条浅灰分隔（不留的话跨页处会被看成一段连续正文）。
    private static func stack(_ tiles: [CGImage], width: Int) -> CGImage? {
        let h = tiles.reduce(0) { $0 + $1.height } + gap * (tiles.count - 1)
        guard width > 0, h > 0,
              let ctx = CGContext(data: nil, width: width, height: h, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        ctx.interpolationQuality = .high
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: h))
        ctx.setFillColor(CGColor(gray: 0.85, alpha: 1))
        var y = h                       // CG 原点在左下，所以从上往下摆要倒着走
        for (i, t) in tiles.enumerated() {
            y -= t.height
            ctx.draw(t, in: CGRect(x: 0, y: y, width: width, height: t.height))
            if i < tiles.count - 1 {
                y -= gap
                ctx.fill(CGRect(x: 0, y: y, width: width, height: gap))
            }
        }
        return ctx.makeImage()
    }
}
