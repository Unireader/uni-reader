import Foundation
import PDFKit

/// 滚动锚点：文档位置（页 + 页内比例），与视口大小/缩放无关。`origin` 标识来源以防回环。
struct ScrollAnchor: Equatable {
    var page: Int
    var frac: Double
    var seq: Int
    var origin: String   // "sim" | "mac" | "pad"
}

/// 一个打开中的 PDF 窗口的运行时状态。每个 reader 窗口一个。
final class DocSession: ObservableObject, Identifiable {
    let id = UUID()
    @Published var title = ""
    @Published var contentHash = ""
    @Published var pdf: PDFDocument?
    @Published var currentPageIndex = 0

    // 实时手写：已完成笔画 + 正在书写的一笔。
    @Published var strokes: [InkStroke] = []
    @Published var liveStroke: InkStroke?

    // 滚动锚点（跨视口同步）。
    @Published var scrollAnchor: ScrollAnchor?
    private var anchorSeq = 0
    func emitAnchor(page: Int, frac: Double, origin: String) {
        anchorSeq += 1
        scrollAnchor = ScrollAnchor(page: page, frac: min(max(0, frac), 1), seq: anchorSeq, origin: origin)
    }
}
