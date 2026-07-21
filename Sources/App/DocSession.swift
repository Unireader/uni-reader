import CoreGraphics
import Foundation
import PDFKit

/// 滚动锚点：文档位置（页 + 页内比例），与视口大小/缩放无关。`origin` 标识来源以防回环。
struct ScrollAnchor: Equatable {
    var page: Int
    var frac: Double
    var seq: Int
    var origin: String   // "sim" | "mac" | "pad" | "toc" | "search" | "restore"
    var senderT: Double = 0   // 发送端单调时钟(ms)，>0 启用时间戳插值；0=本地(sim/mac)走低通
}

/// 平板笔悬停位置（页 + 页内归一化坐标，左上原点）。Mac 在 PDF 上叠加笔尖圆环；离开近场为 nil。
struct HoverPoint: Equatable {
    var page: Int
    var nx: Double
    var ny: Double
}

/// 一处全文搜索命中（T2）。可能跨行换行（`rects` 多个，均归一化 0~1 左上原点，页局部）；
/// `frac` = 首行顶部 y，供 `emitAnchor` 精确跳转定位。
struct TextMatch: Identifiable, Equatable {
    let id = UUID()
    var page: Int
    var rects: [CGRect]
    var frac: Double
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

    // MARK: 全文搜索（T2）——PDFKit `findString` 找命中，防抖后台跑，边打字边高亮+跳首个命中。

    @Published var searchQuery = ""
    @Published var searchMatches: [TextMatch] = []
    @Published var currentMatchIndex: Int?
    @Published var isSearching = false
    private var searchTask: Task<Void, Never>?

    /// 输入防抖（250ms）触发搜索；由 UI 层在 `searchQuery` 变化时调用。
    func scheduleSearch() {
        let q = searchQuery
        searchTask?.cancel()
        searchTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            await self?.performSearch(q)
        }
    }

    private func performSearch(_ query: String) async {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let pdf, !q.isEmpty else {
            searchMatches = []; currentMatchIndex = nil; isSearching = false
            return
        }
        isSearching = true
        let matches = await Task.detached(priority: .userInitiated) {
            TextSearch.find(query: q, in: pdf)
        }.value
        // 过期结果丢弃：搜索期间用户又改了词，只认最新一次。
        guard searchQuery.trimmingCharacters(in: .whitespacesAndNewlines) == q else { return }
        searchMatches = matches
        isSearching = false
        if matches.isEmpty { currentMatchIndex = nil } else { jumpToMatch(0) }
    }

    func clearSearch() {
        searchTask?.cancel()
        searchQuery = ""
        searchMatches = []
        currentMatchIndex = nil
        isSearching = false
    }

    func nextMatch() { advanceMatch(by: 1) }
    func prevMatch() { advanceMatch(by: -1) }

    private func advanceMatch(by delta: Int) {
        guard !searchMatches.isEmpty else { return }
        let n = searchMatches.count
        let cur = currentMatchIndex ?? -1
        jumpToMatch(((cur + delta) % n + n) % n)
    }

    private func jumpToMatch(_ index: Int) {
        guard searchMatches.indices.contains(index) else { return }
        currentMatchIndex = index
        let m = searchMatches[index]
        currentPageIndex = m.page
        emitAnchor(page: m.page, frac: m.frac, origin: "search")
    }
}
