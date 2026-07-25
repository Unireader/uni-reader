import CoreGraphics
import PDFKit

/// fit-width 连续布局（纯数学）。「文档单位」= 参考宽 `refWidth = 1000` 下的 pt，
/// 与视口/缩放完全解耦；显示换算只需 `dispScale = 显示页宽 / refWidth`。
/// 锚点契约与平板一致：(page, 页内比例 frac 0~1)，页间隙归属下一页。
struct PageLayout {
    static let refWidth: CGFloat = 1000
    static let gap: CGFloat = 8

    private(set) var heights: [CGFloat] = []   // 每页高（文档单位）
    private(set) var offsets: [CGFloat] = []   // 每页顶 docY（文档单位）
    private(set) var totalHeight: CGFloat = 1
    var pageCount: Int { heights.count }

    init(doc: PDFDocument) {
        heights.reserveCapacity(doc.pageCount)
        offsets.reserveCapacity(doc.pageCount)
        var y: CGFloat = 0
        for i in 0..<doc.pageCount {
            let s = doc.page(at: i).map { PageBitmap.displaySize($0) } ?? CGSize(width: 1, height: 1.4)
            let h = s.width > 0 ? s.height / s.width * Self.refWidth : Self.refWidth * 1.4
            offsets.append(y)
            heights.append(h)
            y += h + Self.gap
        }
        totalHeight = max(1, y - Self.gap)
    }

    /// docY（文档单位）→ (页, 页内比例)。页间隙 → 下一页 frac=0；越界两端 clamp。
    func locate(docY: CGFloat) -> (page: Int, frac: Double) {
        guard pageCount > 0 else { return (0, 0) }
        var lo = 0, hi = pageCount - 1
        while lo < hi {                        // 最后一个 offsets[i] <= docY 的页
            let mid = (lo + hi + 1) / 2
            if offsets[mid] <= docY { lo = mid } else { hi = mid - 1 }
        }
        let f = (docY - offsets[lo]) / max(1, heights[lo])
        if f > 1, lo + 1 < pageCount { return (lo + 1, 0) }
        return (lo, Double(min(max(0, f), 1)))
    }

    func docY(page: Int, frac: Double) -> CGFloat {
        guard pageCount > 0 else { return 0 }
        let p = min(max(0, page), pageCount - 1)
        return offsets[p] + CGFloat(min(max(0, frac), 1)) * heights[p]
    }

    /// 全局进度（page + frac 连续量，跟随器输出）→ docY。越界先 clamp 再拆页。
    func docY(progress: Double) -> CGFloat {
        guard pageCount > 0 else { return 0 }
        let pr = min(max(0, progress), Double(pageCount - 1) + 0.9999)
        let p = Int(pr.rounded(.down))
        return docY(page: p, frac: pr - Double(p))
    }

    /// docY 区间 → 页索引闭区间（可见/实化窗口）。
    func pageRange(fromDocY a: CGFloat, toDocY b: CGFloat) -> ClosedRange<Int> {
        guard pageCount > 0 else { return 0...0 }
        let lo = locate(docY: min(a, b)).page
        let hi = locate(docY: max(a, b)).page
        return lo...max(lo, hi)
    }
}
