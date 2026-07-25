import CoreGraphics
import Foundation
import PDFKit

/// 滚动锚点：文档位置（页 + 页内比例），与视口大小/缩放无关。`origin` 标识来源以防回环。
struct ScrollAnchor: Equatable {
    var page: Int
    var frac: Double
    var seq: Int
    var origin: String   // "mac" | "pad" | "toc" | "search" | "restore"
    var senderT: Double = 0   // 发送端单调时钟(ms)，>0 启用时间戳插值；0=本地(sim/mac)走低通
}

/// 平板笔悬停位置（**页内**归一化坐标，左上原点）。笔只在 PDF 页上操作 → 光标锚定页内容（随页滚动/缩放），
/// Mac 在页上叠加蓝色笔尖圆环（纯位置指示，不操作任何控件）；离场为 nil。
struct HoverPoint: Equatable {
    var page: Int
    var nx: Double
    var ny: Double
}

/// 环形选笔盘（长按呼出，判定全部在 Mac 端）：`cx`/`cy` 为呼出中心的页内归一化坐标（笔尖处），
/// `highlight` = 当前指向第几个**扇区**（-1 = 中心取消区，不选）。扇区含义见 `RadialLayout.items`。
/// 平板只管发笔事件；检测/选中在 Mac，Mac 再把盘状态镜像下发（`radial` 消息）让平板画同一个盘。
struct RadialState: Equatable {
    var page: Int
    var cx: Double
    var cy: Double
    var highlight: Int
}

/// 环形盘的一个扇区。
enum RadialItem: Equatable {
    case pen(Int)   // `AppModel.pens` 下标
    case erase
    case page
}

/// 环形选笔盘的布局契约（Mac 判定 / Mac 绘制 / 平板绘制三处唯一真源）。
///
/// **单层整圆**：所有扇区等分 360°，第 0 项中心在正上方（12 点）、顺时针排列。选择只看**角度**、
/// 不看半径——半径分层（旧版内环笔/外环工具）要求用户精确控制笔离中心的距离，而那个距离在页内归一化
/// 坐标里随两端缩放漂移，是「选择很不友好」的根因。现在半径只用来判「有没有离开中心取消区」。
enum RadialLayout {
    /// 扇区顺序：N 支笔在前（0 号笔在正上方），橡皮擦、翻页收尾。
    static func items(penCount: Int) -> [RadialItem] {
        (0..<max(0, penCount)).map { RadialItem.pen($0) } + [.erase, .page]
    }

    // 盘的屏幕尺度。Mac 用 pt、平板用 CSS px，取同一组数值 → 两端看到的是同一个盘。
    // capture.html 的 `RD` 常量必须与此一致。
    static let hubRadius: CGFloat = 46      // 中心 hub = 取消区
    static let innerRadius: CGFloat = 54    // 扇区内缘
    static let outerRadius: CGFloat = 134   // 扇区外缘
    static let gapDegrees: Double = 1.5     // 相邻扇区之间的分隔缝（单边）
}

/// 长按进度环：落笔中心（页内归一化）+ 起始时刻。Mac 据 `start` 到当前的用时画填充进度。
struct PressRing: Equatable {
    var page: Int
    var nx: Double
    var ny: Double
    var start: Date
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

    /// 阅读区当前缩放倍率（相对 fit-width，1=贴合宽度）。PageStreamView 写、ContentView 读来存进度。
    @Published var readZoom: CGFloat = 1
    /// 待恢复的缩放倍率（loadSelected 从库读入，PageStreamView 首帧定基准后一次性套用）。非 @Published。
    var restoreZoom: CGFloat = 1
    /// 阅读区当前横向滚动比例（offsetX / pageW）。PageStreamView 每帧写、存进度时读。
    /// **非 @Published**——每帧刷新，若发布会导致每帧重渲。
    var readHFrac: Double = 0
    /// 待恢复的横向滚动比例（loadSelected 读入，PageStreamView 首帧定位后一次性套用）。
    var restoreHFrac: CGFloat = 0
    /// 已落库的笔画 id 集合，用于增量对账（新增 upsert / 擦除 delete），非 @Published。
    var persistedStrokeIDs: Set<UUID> = []

    // 实时手写：已完成笔画 + 正在书写的一笔。
    @Published var strokes: [InkStroke] = []
    @Published var liveStroke: InkStroke?

    // 文字注解（note kind=0）。运行时驻留于此，阅读区(渲染标记)与 Inspector(列表) 共读；
    // 由 ContentView `.onChange` 增量对账落库（新增/编辑 upsert、删除 delete），与手写笔迹同套路。
    @Published var textNotes: [TextNote] = []
    /// 已落库的文字注解快照（id → 值），用于增量对账（检测新增/内容变更/删除），非 @Published。
    var persistedTextNotes: [UUID: TextNote] = [:]

    // 文字高亮（note kind=3）。同上套路：阅读区铺色 + Inspector 列表，ContentView `.onChange` 增量对账。
    @Published var highlights: [Highlight] = []
    /// 已落库的高亮快照（id → 值），增量对账用，非 @Published。
    var persistedHighlights: [UUID: Highlight] = [:]

    // 平板笔悬停位置（nil = 无悬停 / 已落笔）。
    @Published var hover: HoverPoint?

    // 环形选笔盘（nil = 未呼出）。长按触发，判定全程 Mac 端处理。
    @Published var radial: RadialState?

    // 长按进度环（nil = 无）：落笔起计，Mac 在笔尖处 300ms 起显示、1s 填满，随后展开成 radial。
    @Published var pressRing: PressRing?

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
    @Published var ocrRuns: [Int: [TextRun]] = [:] {      // 页 → 已识别的行级文本框（阅读顺序）
        didSet { ocrGroupCache = [:] }                    // 行变了 → 分组缓存作废（懒重算）
    }
    private var ocrGroupCache: [Int: [Int]] = [:]         // 页 → 分组 id（列/块聚类，与 runs 同序）
    /// 某页 OCR 行的列/块分组（`OCRFlow.columnGroups`），带缓存——拖选/渲染多次访问不重复跑并查集。
    func ocrGroups(page: Int) -> [Int] {
        if let c = ocrGroupCache[page] { return c }
        guard let runs = ocrRuns[page] else { return [] }
        let g = OCRFlow.columnGroups(runs)
        ocrGroupCache[page] = g
        return g
    }
    @Published var showOCRBlocks = false                  // 调试/demo：把 OCR 识别块按块上色画出来（量化排版/选择）
    @Published var ocrBlockGrouped = false                // 调试上色模式：false=每块独立色 / true=可选分组同色（列/块聚类）
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
