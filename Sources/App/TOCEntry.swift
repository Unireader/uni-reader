import PDFKit

/// PDF 目录项（可嵌套）。pageIndex + frac 用于跳转（页 + 页内归一化比例）。
///
/// `pageIndex` 是 optional：**坏书签**（destination 解不出目标页）为 nil，不可当成第 0 页。
/// 现实里的坏书签形态：outline 项写了个空 destination（`/Dest [null 0 0 0]` 之类），PDFKit 直接
/// 给 `destination == nil`；也见过 dest 的 page 不属于本文档（`doc.index(for:)` 返回 NSNotFound）。
/// 这类项一律 nil —— 不显示页码、不可跳转、不参与当前页追踪。
struct TOCEntry: Identifiable {
    let id = UUID()
    let label: String
    let pageIndex: Int?
    let frac: Double
    var children: [TOCEntry]
    var childrenOrNil: [TOCEntry]? { children.isEmpty ? nil : children }

    /// 从 PDF 的 outlineRoot 递归构建目录树。
    /// `align` = 扫描页对齐参数表（没开传 nil）：开着时落点的页内比例按对齐后的页面算。
    static func build(from doc: PDFDocument, align: ScanAlignTable?) -> [TOCEntry] {
        guard let root = doc.outlineRoot else { return [] }
        func walk(_ o: PDFOutline) -> [TOCEntry] {
            var out: [TOCEntry] = []
            for i in 0..<o.numberOfChildren {
                guard let c = o.child(at: i) else { continue }
                var pageIndex: Int? = nil, frac = 0.0
                if let dest = c.destination, let page = dest.page {
                    let idx = doc.index(for: page)
                    if idx >= 0, idx < doc.pageCount {          // NSNotFound（=Int.max）等越界一律作废
                        pageIndex = idx
                        let b = page.bounds(for: PageBitmap.effectiveBox(page))
                        let y = dest.point.y
                        if y.isFinite, b.height > 0 { frac = min(max(0, Double((b.maxY - y) / b.height)), 1) }
                        // 对齐：落点过一道对齐变换再取纵向比例（x 没给就按页中线；旋转角很小，x 只影响零点几 pt）
                        if let pa = align?.page(idx), b.width > 0 {
                            let x = dest.point.x
                            let nx = (x.isFinite && x >= b.minX && x <= b.maxX) ? Double((x - b.minX) / b.width) : 0.5
                            let q = pa.toAligned(CGPoint(x: nx * pa.sw, y: frac * pa.sh))
                            frac = min(max(0, Double(q.y) / pa.sh), 1)
                        }
                    }
                }
                out.append(TOCEntry(label: (c.label ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                                    pageIndex: pageIndex, frac: frac, children: walk(c)))
            }
            return out
        }
        return walk(root)
    }

    /// 某页归属的章节名（先序里起点不晚于该页、页码最大的那项；并列取先序靠后 = 更深一层）。
    /// 与目录树的当前章节追踪同一口径。跳转历史里没有现成名字的条目靠它显示「落在哪一章」。
    /// 没有目录或没命中时返回空串。
    static func chapterLabel(for page: Int, in entries: [TOCEntry]) -> String {
        var best: (page: Int, label: String)? = nil
        func walk(_ list: [TOCEntry]) {
            for e in list {
                if let p = e.pageIndex, p <= page, !(best.map { p < $0.page } ?? false) {
                    best = (p, e.label)
                }
                walk(e.children)
            }
        }
        walk(entries)
        return best?.label.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}
