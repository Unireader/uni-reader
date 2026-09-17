import CoreGraphics
import PDFKit

/// ⌘F 全文搜索（T2）：复用 PDFKit 内建 `findString`（跨行/跨页鲁棒，不必重新实现词法扫描）。
/// 每个命中取其按行拆分后的每行框（`selectionsByLine`），用与文字选择同一套 rotation-aware
/// 归一化（`PageGeometry.normalizedLineRects`）转成显示坐标，供 `PageStreamView` 画高亮。
enum TextSearch {
    /// `align` = 扫描页对齐参数表（没开传 nil）：命中框要落在对齐后的页面上。
    static func find(query: String, in pdf: PDFDocument, align: ScanAlignTable?) -> [TextMatch] {
        let selections = pdf.findString(query, withOptions: [.caseInsensitive, .diacriticInsensitive])
        var out: [TextMatch] = []
        for sel in selections {
            for (idx, rects) in PageGeometry.normalizedLineRects(of: sel, in: pdf, align: { align?.page($0) }) {
                out.append(TextMatch(page: idx, rects: rects, frac: Double(rects.map(\.minY).min() ?? 0)))
            }
        }
        return out.sorted { $0.page != $1.page ? $0.page < $1.page : $0.frac < $1.frac }
    }
}
