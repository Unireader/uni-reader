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
        // OCR 已启用（文本更准）→ 搜已识别页的 OCR 文本（行级）；否则走 PDFKit 原生 findString。
        let matches: [TextMatch]
        if ocrEnabled, !ocrRuns.isEmpty {
            matches = searchOCR(q)
        } else {
            matches = await Task.detached(priority: .userInitiated) {
                TextSearch.find(query: q, in: pdf)
            }.value
        }
        // 过期结果丢弃：搜索期间用户又改了词，只认最新一次。
        guard searchQuery.trimmingCharacters(in: .whitespacesAndNewlines) == q else { return }
        searchMatches = matches
        isSearching = false
        if matches.isEmpty { currentMatchIndex = nil } else { jumpToMatch(0) }
    }

    /// OCR 文本搜索：逐行匹配（大小写不敏感），命中行整框高亮。只覆盖已识别页。
    private func searchOCR(_ q: String) -> [TextMatch] {
        let ql = q.lowercased()
        var out: [TextMatch] = []
        for (page, runs) in ocrRuns {
            for r in runs where r.text.lowercased().contains(ql) {
                out.append(TextMatch(page: page, rects: [r.rect], frac: r.y))
            }
        }
        return out.sorted { $0.page != $1.page ? $0.page < $1.page : $0.frac < $1.frac }
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

    // MARK: OCR（T3，Paddle PP-OCRv6）——逐页按需 + 手动全量；结果=准确文本层，选择/复制/搜索改用它。
    // 数据流：可见页 → 查 ocr_page 缓存(命中即用) → miss 则渲页图上传 Paddle → 回填缓存 → ocrRuns 刷新。
    // 缓存键 = (内容 hash, 页, provider)，随内容走、换机复用；网络任务并发上限 3。

    @Published var ocrEnabled = false                     // 本文档启用 OCR 文本层
    @Published var ocrRuns: [Int: [TextRun]] = [:]        // 页 → 已识别的行级文本框（阅读顺序）
    @Published var ocrActivePages: Set<Int> = []          // 正在网络识别的页
    @Published var ocrLastError: String?
    @Published private var ocrQueue: [Int] = []           // 待识别队列（@Published 让面板进度实时刷新）
    private var ocrInFlight = 0
    private let ocrMaxConcurrent = 3
    /// 供 OCR 缓存读写（App 级 `WorkspaceManager.store`，由 `ContentView.loadSelected` 注入）。仅主线程访问。
    var store: LibraryStore?
    /// OCR 页图渲染用串行队列（PDFPage 跨线程只读，与 `PageRenderEngine` 同先例）。
    private static let ocrRenderQueue = DispatchQueue(label: "com.xvan.unireader.ocr-render", qos: .userInitiated)

    var ocrDoneCount: Int { ocrRuns.count }
    var ocrTotalPages: Int { pdf?.pageCount ?? 0 }
    var ocrPendingCount: Int { ocrQueue.count + ocrActivePages.count }
    var ocrRunning: Bool { ocrPendingCount > 0 }

    /// 换文档时重置 OCR 状态；若该内容已有缓存则自动启用（缓存直接复用，无需重跑）。
    func reloadOCRState() {
        ocrQueue = []; ocrInFlight = 0; ocrActivePages = []; ocrRuns = [:]; ocrLastError = nil
        ocrEnabled = false
        guard let store, !contentHash.isEmpty else { return }
        if let c = try? store.ocrPageCount(contentHash: contentHash, provider: PaddleOCR.providerID), c > 0 {
            ocrEnabled = true
        }
    }

    /// 用户在 OCR 面板里开关。开 → 立刻处理当前页（reader 的可见窗口会补齐其余）。
    func setOCREnabled(_ on: Bool) {
        ocrEnabled = on
        if on { enqueueOCR([currentPageIndex]) }
    }

    /// 手动「识别全部页」：全量入队（缓存命中的秒回，其余排队跑）。
    func ocrAllPages() {
        ocrEnabled = true
        enqueueOCR(Array(0..<ocrTotalPages))
    }

    /// 入队若干页：已识别/在跑/在队的跳过；缓存命中直接应用（不占网络槽）；缺失且已配置 key 才排队跑网络。
    func enqueueOCR(_ pages: [Int]) {
        guard ocrEnabled else { return }
        let configured = PaddleOCR.configFromDefaults() != nil
        for p in pages where p >= 0 && p < ocrTotalPages
            && ocrRuns[p] == nil && !ocrActivePages.contains(p) && !ocrQueue.contains(p) {
            if let cached = loadCachedOCR(p) { ocrRuns[p] = cached; continue }
            if configured { ocrQueue.append(p) }
        }
        pumpOCR()
    }

    private func pumpOCR() {
        while ocrInFlight < ocrMaxConcurrent, !ocrQueue.isEmpty {
            startNetworkOCR(ocrQueue.removeFirst())
        }
    }

    private func startNetworkOCR(_ page: Int) {
        guard let pdf, let config = PaddleOCR.configFromDefaults() else { return }
        let hash = contentHash
        ocrActivePages.insert(page)
        ocrInFlight += 1
        Task { [weak self] in
            let img = await Self.renderPageForOCR(pdf: pdf, page: page)
            var runs: [TextRun]?
            var err: String?
            if let img {
                do { runs = try await PaddleOCR.recognize(image: img, config: config) }
                catch { err = error.localizedDescription }
            }
            let imgW = img.map { Double($0.width) } ?? 0
            let imgH = img.map { Double($0.height) } ?? 0
            await MainActor.run {
                guard let self else { return }
                // 换文档后旧任务回来：内容 hash 变了就整个丢弃——此时新文档的计数器已被 reloadOCRState 归零，
                // 绝不能再动它（否则 ocrInFlight 被减成负、并发失控）。
                guard self.contentHash == hash else { return }
                self.ocrInFlight -= 1
                self.ocrActivePages.remove(page)
                if let runs {
                    self.ocrRuns[page] = runs
                    self.saveCachedOCR(page: page, runs: runs, imgW: imgW, imgH: imgH)
                } else if let err {
                    self.ocrLastError = err
                }
                self.pumpOCR()
            }
        }
    }

    private static func renderPageForOCR(pdf: PDFDocument, page: Int, pixelWidth: Int = 2400) async -> CGImage? {
        await withCheckedContinuation { cont in
            ocrRenderQueue.async {
                cont.resume(returning: pdf.page(at: page).flatMap { PageBitmap.render(page: $0, pixelWidth: pixelWidth) })
            }
        }
    }

    private func loadCachedOCR(_ page: Int) -> [TextRun]? {
        guard let store,
              let row = try? store.ocrPage(contentHash: contentHash, page: page, provider: PaddleOCR.providerID),
              let payload = try? JSONDecoder().decode(OCRPagePayload.self, from: row.payload) else { return nil }
        return payload.runs
    }

    private func saveCachedOCR(page: Int, runs: [TextRun], imgW: Double, imgH: Double) {
        guard let store,
              let data = try? JSONEncoder().encode(OCRPagePayload(w: imgW, h: imgH, runs: runs)) else { return }
        try? store.upsertOCRPage(OCRPage(contentHash: contentHash, page: page,
                                         provider: PaddleOCR.providerID, payload: data,
                                         lang: nil, createdAt: Date()))
    }
}
