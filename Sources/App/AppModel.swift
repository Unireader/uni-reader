import Foundation
import PDFKit
import Combine

/// App 级单例：持有唯一的 `LANServer`，管理所有打开中的 `DocSession`。
/// 平板显示的会话 = 平板手动选中的（padSelectedSessionID），否则跟随最后激活窗口（activeSessionID）。
final class AppModel: ObservableObject {
    let server = LANServer()
    @Published private(set) var sessions: [DocSession] = []
    @Published var activeSessionID: UUID?
    @Published var padSelectedSessionID: UUID?

    private var cancellables = Set<AnyCancellable>()

    init() {
        // 平板翻页 → 应用到平板当前会话，并重推页图。
        server.$requestedPageIndex
            .compactMap { $0 }
            .receive(on: RunLoop.main)
            .sink { [weak self] idx in
                guard let self, let s = self.padSession else { return }
                if s.currentPageIndex != idx { s.currentPageIndex = idx }
                self.push()
            }
            .store(in: &cancellables)

        // 服务启动后立即推一次当前页与文档列表。
        server.$isRunning
            .receive(on: RunLoop.main)
            .sink { [weak self] running in if running { self?.push(); self?.broadcastDocs() } }
            .store(in: &cancellables)

        // 新平板连接 → 补发文档列表与当前页。
        server.$clientCount
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.broadcastDocs(); self?.push(); self?.pushLayout(force: true) }
            .store(in: &cancellables)

        // 平板切换文档。
        server.$requestedDocID
            .compactMap { $0 }
            .receive(on: RunLoop.main)
            .sink { [weak self] id in self?.selectPadDoc(id) }
            .store(in: &cancellables)

        // 平板手写/擦除消息 → 应用到平板当前会话。
        server.onMessage = { [weak self] obj in self?.handleInk(obj) }

        // 方案 B：平板按需取任意页图（带缓存，服务 queue 上调用）。
        server.pageProvider = { [weak self] idx in self?.renderPage(idx) }

        // 方案 B：平板本地滚动 → 落为平板当前会话的锚点（origin=pad），驱动 Mac PDFView 跟随。
        server.onScroll = { [weak self] page, frac, t in
            guard let self, let s = self.padSession else { return }
            s.emitAnchor(page: page, frac: frac, origin: "pad", senderT: t)
        }
    }

    // MARK: - 方案 B：按页渲染缓存

    private let renderLock = NSLock()
    private var padRenderPDF: PDFDocument?
    private var padRenderKey = ""              // = 文档 contentHash，作缓存/版本键
    private let pageCache = NSCache<NSString, NSData>()

    /// 更新按页渲染的文档源；文档变（key 变）时清空页图缓存。主线程调用。
    private func setPadRender(pdf: PDFDocument, key: String) {
        renderLock.lock(); defer { renderLock.unlock() }
        if padRenderKey != key {
            pageCache.removeAllObjects()
            padRenderKey = key
        }
        padRenderPDF = pdf
    }

    /// 渲染平板当前会话的第 idx 页（缓存命中直接返回）。服务 queue 上调用。
    func renderPage(_ idx: Int) -> Data? {
        renderLock.lock()
        let pdf = padRenderPDF
        let key = padRenderKey
        let ck = "\(key)#\(idx)" as NSString
        if let cached = pageCache.object(forKey: ck) { renderLock.unlock(); return cached as Data }
        renderLock.unlock()

        guard let pdf, idx >= 0, idx < pdf.pageCount, let page = pdf.page(at: idx),
              let png = PageRenderer.png(page: page, maxWidth: 1600) else { return nil }
        renderLock.lock(); pageCache.setObject(png as NSData, forKey: ck); renderLock.unlock()
        return png
    }

    // MARK: - 手写路由

    private func handleInk(_ obj: [String: Any]) {
        guard let s = padSession else { return }
        switch obj["type"] as? String {
        case "ink":
            let phase = obj["phase"] as? String ?? ""
            if phase == "begin" {
                let page = (obj["page"] as? NSNumber)?.intValue ?? s.currentPageIndex
                let pen = obj["pen"] as? [String: Any]
                let color = InkColor.parse(pen?["color"] as? String)
                let w = (pen?["w"] as? NSNumber)?.doubleValue ?? 8
                inkBegin(page: page, color: color, width: w, points: points(obj["pts"]))
            } else if phase == "move" {
                inkAppend(points(obj["pts"]))
            } else if phase == "end" {
                inkEnd()
            }
        case "erase":
            if obj["phase"] as? String == "move" { inkErase(points(obj["pts"])) }
        case "hover":
            if (obj["phase"] as? String) == "end" {
                s.hover = nil
            } else {
                let page = (obj["page"] as? NSNumber)?.intValue ?? s.currentPageIndex
                let nx = (obj["nx"] as? NSNumber)?.doubleValue ?? 0
                let ny = (obj["ny"] as? NSNumber)?.doubleValue ?? 0
                s.hover = HoverPoint(page: page, nx: nx, ny: ny)
            }
        default:
            break
        }
    }

    // 供 WS 与模拟窗口共用的落墨 API。
    func inkBegin(page: Int, color: InkColor, width: Double, points: [SIMD3<Double>]) {
        guard let s = padSession else { return }
        s.liveStroke = InkStroke(page: page, color: color, width: width, points: points)
    }
    func inkAppend(_ pts: [SIMD3<Double>]) {
        guard let s = padSession, var st = s.liveStroke else { return }
        st.points.append(contentsOf: pts); s.liveStroke = st
    }
    func inkEnd() {
        guard let s = padSession, let st = s.liveStroke else { return }
        s.strokes.append(st); s.liveStroke = nil
    }
    func inkErase(_ pts: [SIMD3<Double>]) {
        guard let s = padSession else { return }
        eraseNear(s, pts)
    }

    private func points(_ any: Any?) -> [SIMD3<Double>] {
        guard let raw = any as? [[NSNumber]] else { return [] }
        return raw.map { p in
            SIMD3(p.count > 0 ? p[0].doubleValue : 0,
                  p.count > 1 ? p[1].doubleValue : 0,
                  p.count > 2 ? p[2].doubleValue : 0.5)
        }
    }

    private func eraseNear(_ s: DocSession, _ es: [SIMD3<Double>]) {
        guard !es.isEmpty else { return }
        let r2 = 0.02 * 0.02
        let page = s.currentPageIndex
        s.strokes.removeAll { st in
            guard st.page == page else { return false }
            for sp in st.points {
                for e in es {
                    let dx = sp.x - e.x, dy = sp.y - e.y
                    if dx * dx + dy * dy <= r2 { return true }
                }
            }
            return false
        }
    }

    /// 当前应显示到平板的会话。
    var padSession: DocSession? {
        let id = padSelectedSessionID ?? activeSessionID
        return sessions.first { $0.id == id }
    }

    // MARK: - 会话注册

    func register(_ s: DocSession) {
        if !sessions.contains(where: { $0.id == s.id }) { sessions.append(s) }
        if activeSessionID == nil { activeSessionID = s.id }
        broadcastDocs()
    }

    func unregister(_ s: DocSession) {
        sessions.removeAll { $0.id == s.id }
        if padSelectedSessionID == s.id { padSelectedSessionID = nil }
        if activeSessionID == s.id { activeSessionID = sessions.last?.id }
        push()
        broadcastDocs()
    }

    /// 窗口成为 key window。
    func setActive(_ s: DocSession) {
        if activeSessionID != s.id { activeSessionID = s.id }
        if padSelectedSessionID == nil { push() }   // 平板在跟随模式 → 切到新激活窗口
        broadcastDocs()
    }

    /// 某会话页码变化（Mac 滚动或加载新文档）。
    func sessionChanged(_ s: DocSession) {
        if s.id == padSession?.id { push() }
        broadcastDocs()   // 标题可能刚更新
    }

    /// 平板选择要看的文档（空串 = 跟随激活窗口）。
    func selectPadDoc(_ idString: String) {
        padSelectedSessionID = idString.isEmpty ? nil : UUID(uuidString: idString)
        push()
        broadcastDocs()
    }

    /// 广播打开中的文档列表给平板。
    func broadcastDocs() {
        guard server.isRunning else { return }
        let list: [[String: Any]] = sessions.map {
            ["id": $0.id.uuidString, "title": $0.title.isEmpty ? "未命名" : $0.title]
        }
        server.broadcast([
            "type": "docs",
            "list": list,
            "selected": padSession?.id.uuidString ?? "",
            "following": padSelectedSessionID == nil
        ])
    }

    // MARK: - 推页图给平板

    func push() {
        guard server.isRunning, let s = padSession, let pdf = s.pdf,
              let page = pdf.page(at: s.currentPageIndex) else { return }
        setPadRender(pdf: pdf, key: s.contentHash)   // 方案 B：更新按页渲染源
        let b = page.bounds(for: .mediaBox)
        let png = PageRenderer.png(page: page, maxWidth: 1600) ?? Data()
        server.setPage(index: s.currentPageIndex,
                       count: pdf.pageCount,
                       width: Double(b.width),
                       height: Double(b.height),
                       png: png)
        pushLayout()
    }

    // MARK: - 方案 B：布局与视口

    private var pushedLayoutKey = ""
    /// 推平板当前会话的文档布局（每页原始宽高）。仅文档变化时推；`force` 用于新平板连接时补发。
    /// 避免每次滚动/翻页重广播 layout，减少平板端无谓 relayout 与回环噪声。
    func pushLayout(force: Bool = false) {
        guard server.isRunning, let s = padSession, let pdf = s.pdf else { return }
        if !force && s.contentHash == pushedLayoutKey { return }
        pushedLayoutKey = s.contentHash
        var pages: [[Double]] = []
        pages.reserveCapacity(pdf.pageCount)
        for i in 0..<pdf.pageCount {
            let b = pdf.page(at: i)?.bounds(for: .mediaBox) ?? .zero
            pages.append([Double(b.width), Double(b.height)])
        }
        server.broadcast([
            "type": "layout",
            "docId": s.contentHash,
            "v": s.contentHash,
            "count": pdf.pageCount,
            "pages": pages
        ])
    }

    /// Mac 用户滚动 → 广播视口锚点给平板（origin=mac 才发，避免与平板回传成环）。
    func macScrolled(_ s: DocSession) {
        guard server.isRunning, s.id == padSession?.id,
              let a = s.scrollAnchor, a.origin == "mac" else { return }
        server.broadcast(["type": "viewport", "page": a.page, "frac": a.frac, "seq": a.seq])
    }
}
