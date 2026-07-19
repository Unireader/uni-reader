import AppKit
import PDFKit

/// 桌面权威渲染：把文档按给定宽度做 fit-width 连续布局，可渲染任意竖向视口条带，
/// 并在「视口点 ↔ (页, 归一化坐标)」间换算。方案 B 的核心（平板/模拟窗口都用它）。
final class PadRenderer {
    let doc: PDFDocument
    let width: CGFloat
    let gap: CGFloat = 8

    private(set) var pageOffsets: [CGFloat] = []   // 每页顶部的文档 Y
    private(set) var pageHeights: [CGFloat] = []
    private(set) var totalHeight: CGFloat = 0

    init(doc: PDFDocument, width: CGFloat) {
        self.doc = doc
        self.width = max(1, width)
        layout()
    }

    private func layout() {
        var y: CGFloat = 0
        for i in 0..<doc.pageCount {
            guard let p = doc.page(at: i) else { continue }
            let b = p.bounds(for: .mediaBox)
            let h = b.width > 0 ? b.height / b.width * width : width
            pageOffsets.append(y)
            pageHeights.append(h)
            y += h + gap
        }
        totalHeight = max(0, y - gap)
    }

    /// 渲染文档 Y 区间 [topDocY, topDocY+height] 的条带。
    func render(topDocY: CGFloat, height: CGFloat) -> NSImage {
        let size = CGSize(width: width, height: max(1, height))
        let img = NSImage(size: size)
        img.lockFocus()
        NSColor(white: 0.12, alpha: 1).setFill()
        CGRect(origin: .zero, size: size).fill()
        if let ctx = NSGraphicsContext.current?.cgContext {
            for i in pageOffsets.indices {
                let pageTop = pageOffsets[i], pageH = pageHeights[i]
                if pageTop + pageH < topDocY || pageTop > topDocY + height { continue }
                guard let page = doc.page(at: i) else { continue }
                let yFromTop = pageTop - topDocY
                let dest = CGRect(x: 0, y: height - yFromTop - pageH, width: width, height: pageH)
                ctx.saveGState()
                ctx.setFillColor(NSColor.white.cgColor)
                ctx.fill(dest)
                let b = page.bounds(for: .mediaBox)
                ctx.translateBy(x: dest.minX, y: dest.minY)
                ctx.scaleBy(x: dest.width / b.width, y: dest.height / b.height)
                ctx.translateBy(x: -b.minX, y: -b.minY)
                page.draw(with: .mediaBox, to: ctx)
                ctx.restoreGState()
            }
        }
        img.unlockFocus()
        return img
    }

    /// 视口点（x 自左，yFromTop 自视口顶）→ (页, 归一化 x, 归一化 y 左上原点)。
    func locate(x: CGFloat, yFromTop: CGFloat, topDocY: CGFloat) -> (page: Int, nx: Double, ny: Double)? {
        let docY = topDocY + yFromTop
        for i in pageOffsets.indices where docY >= pageOffsets[i] && docY <= pageOffsets[i] + pageHeights[i] {
            let nx = Double(min(max(0, x / width), 1))
            let ny = Double(min(max(0, (docY - pageOffsets[i]) / pageHeights[i]), 1))
            return (i, nx, ny)
        }
        return nil
    }

    /// (页, 归一化) → 视口点（yFromTop 自视口顶）。
    func point(page: Int, nx: Double, ny: Double, topDocY: CGFloat) -> CGPoint {
        guard page < pageOffsets.count else { return .zero }
        let docY = pageOffsets[page] + CGFloat(ny) * pageHeights[page]
        return CGPoint(x: CGFloat(nx) * width, y: docY - topDocY)
    }

    func maxScroll(viewportHeight: CGFloat) -> CGFloat { max(0, totalHeight - viewportHeight) }
}
