import Foundation
import PDFKit

/// 滚动锚点：文档位置（页 + 页内比例），与视口大小/缩放无关。`origin` 标识来源以防回环。
struct ScrollAnchor: Equatable {
    var page: Int
    var frac: Double
    var seq: Int
    var origin: String   // "sim" | "mac" | "pad"
    var senderT: Double = 0   // 发送端单调时钟(ms)，>0 启用时间戳插值；0=本地(sim/mac)走低通
}

/// 平板笔悬停位置（页 + 页内归一化坐标，左上原点）。Mac 在 PDF 上叠加笔尖圆环；离开近场为 nil。
struct HoverPoint: Equatable {
    var page: Int
    var nx: Double
    var ny: Double
}

/// 一个打开中的 PDF 窗口的运行时状态。每个 reader 窗口一个。
final class DocSession: ObservableObject, Identifiable {
    let id = UUID()
    @Published var title = ""
    @Published var contentHash = ""
    @Published var pdf: PDFDocument?
    @Published var currentPageIndex = 0

    /// 当前会话对应的逻辑文档 id（笔迹持久化用；nil = 未加载文档）。
    var documentId: String?
    /// 已落库的笔画 id 集合，用于增量对账（新增 upsert / 擦除 delete），非 @Published。
    var persistedStrokeIDs: Set<UUID> = []

    // 实时手写：已完成笔画 + 正在书写的一笔。
    @Published var strokes: [InkStroke] = []
    @Published var liveStroke: InkStroke?

    // 平板笔悬停位置（nil = 无悬停 / 已落笔）。
    @Published var hover: HoverPoint?

    // 滚动锚点（跨视口同步）。
    @Published var scrollAnchor: ScrollAnchor?
    private var anchorSeq = 0
    func emitAnchor(page: Int, frac: Double, origin: String, senderT: Double = 0) {
        anchorSeq += 1
        scrollAnchor = ScrollAnchor(page: page, frac: min(max(0, frac), 1), seq: anchorSeq, origin: origin, senderT: senderT)
    }
}
