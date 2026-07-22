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
    /// 仅让「首个窗口」恢复工作区上次文档；后续 ⌘N 窗口开空白，不重复蹦同一本书。
    var didRestoreInitial = false

    /// 平板当前工具状态镜像（设备级，跟文档无关）：驱动 Mac 阅读区悬浮笔工具条。
    /// "note" | "erase" | "page"，与 capture.html 的 MODES.key 同值。
    @Published var padMode: String = "note"
    /// 当前笔在 `pens` 里的下标。
    @Published var padPenIndex: Int = 0
    /// 收藏笔列表（唯一状态源）：画布悬浮工具条实时增删改，自动落盘 + 广播给 pad。不再走系统设置页配置。
    @Published var pens: [PenPreset] = PenPresets.load() {
        didSet {
            PenPresets.save(pens)
            broadcastPens()
        }
    }

    private var cancellables = Set<AnyCancellable>()

    // 环形选笔盘 · 长按检测（全部在 Mac 端）。平板只发笔事件；这里判「落笔停住 1s」呼出、笔移选中、抬笔提交。
    private var longPressWork: DispatchWorkItem?
    private var inkStart: (page: Int, nx: Double, ny: Double)?
    private var inkMovedFar = false
    private var inRadial = false
    private let longPressSeconds = 1.0
    private let moveCancelThresh = 0.02   // 归一化位移超此值 → 判为在画，不呼出
    private let radialDeadzone = 0.045     // 归一化半径内 → 中心取消区

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

        // 服务启动后立即推一次当前页、文档列表、收藏笔列表。
        server.$isRunning
            .receive(on: RunLoop.main)
            .sink { [weak self] running in
                if running { self?.push(); self?.broadcastDocs(); self?.broadcastPens() }
            }
            .store(in: &cancellables)

        // 新平板连接 → 补发文档列表、当前页、收藏笔列表。
        server.$clientCount
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.broadcastDocs(); self?.push(); self?.pushLayout(force: true); self?.broadcastPens(); self?.broadcastStrokes()
            }
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
                let type = PenBrushType(rawValue: pen?["t"] as? String ?? "") ?? .ballpoint
                let pts = points(obj["pts"])
                inkBegin(page: page, color: color, width: w, type: type, points: pts)
                beginLongPressWatch(page: page, first: pts.first)
            } else if phase == "move" {
                let pts = points(obj["pts"])
                if inRadial { updateRadial(pts.last) }
                else { inkAppend(pts); checkLongPressMovement(pts.last) }
            } else if phase == "end" {
                endInkOrRadial()
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
        case "mode":
            if let m = obj["mode"] as? String { padMode = m }
        case "pen":
            if let i = (obj["index"] as? NSNumber)?.intValue { padPenIndex = i }
        default:
            break
        }
    }

    // MARK: - 环形选笔盘 · 长按检测（Mac 端）

    /// 落笔即起 1s 定时：期间没大幅移动就呼出环形盘。同时挂进度环（笔尖处）。
    private func beginLongPressWatch(page: Int, first: SIMD3<Double>?) {
        cancelRadial()
        guard let f = first else { return }
        inkStart = (page, f.x, f.y); inkMovedFar = false; inRadial = false
        padSession?.pressRing = PressRing(page: page, nx: f.x, ny: f.y, start: Date())
        let work = DispatchWorkItem { [weak self] in self?.fireLongPress() }
        longPressWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + longPressSeconds, execute: work)
    }

    /// 画的时候（位移超阈值）取消长按候选 + 撤掉进度环。
    private func checkLongPressMovement(_ last: SIMD3<Double>?) {
        guard !inkMovedFar, let s0 = inkStart, let p = last else { return }
        let dx = p.x - s0.nx, dy = p.y - s0.ny
        if dx * dx + dy * dy > moveCancelThresh * moveCancelThresh {
            inkMovedFar = true
            longPressWork?.cancel(); longPressWork = nil
            padSession?.pressRing = nil
        }
    }

    /// 长按达成：丢弃正在成形的这一笔，呼出环形盘（中心在落笔处），并回发 inkCancel 让平板撤掉本地这半笔。
    private func fireLongPress() {
        guard !inkMovedFar, !inRadial, let s0 = inkStart, let s = padSession else { return }
        s.liveStroke = nil
        s.pressRing = nil
        inRadial = true
        s.radial = RadialState(page: s0.page, cx: s0.nx, cy: s0.ny, highlight: -1)
        server.broadcast(["type": "inkCancel"])
    }

    /// 环形盘打开时，笔移 → 按角度算指向第几支笔（页比例换算成屏幕角度，含长宽比校正）。
    private func updateRadial(_ last: SIMD3<Double>?) {
        guard var r = padSession?.radial, let p = last, !pens.isEmpty else { return }
        let dx = p.x - r.cx, dy = p.y - r.cy
        if (dx * dx + dy * dy) < radialDeadzone * radialDeadzone {
            r.highlight = -1
        } else {
            let aspect = currentPageAspect(page: r.page)   // pageH/pageW
            var ang = atan2(dy * aspect, dx) + .pi / 2      // 从正上方起、顺时针
            if ang < 0 { ang += 2 * .pi }
            let n = pens.count
            r.highlight = Int((ang / (2 * .pi) * Double(n)).rounded()) % n
        }
        if r != padSession?.radial { padSession?.radial = r }
    }

    /// 抬笔：环形盘打开则提交选中（中心区=不选），否则正常收笔。
    private func endInkOrRadial() {
        longPressWork?.cancel(); longPressWork = nil
        padSession?.pressRing = nil
        if inRadial {
            if let r = padSession?.radial, r.highlight >= 0, pens.indices.contains(r.highlight) {
                applyPenSelection(index: r.highlight)
            }
            padSession?.radial = nil
        } else {
            inkEnd()
        }
        inRadial = false; inkStart = nil
    }

    private func cancelRadial() {
        longPressWork?.cancel(); longPressWork = nil
        if inRadial { padSession?.radial = nil }
        padSession?.pressRing = nil
        inRadial = false; inkStart = nil; inkMovedFar = false
    }

    private func currentPageAspect(page: Int) -> Double {
        guard let pdf = padSession?.pdf, page >= 0, page < pdf.pageCount, let pg = pdf.page(at: page) else { return 1 }
        let b = pg.bounds(for: .mediaBox)
        return b.width > 0 ? Double(b.height / b.width) : 1
    }

    /// 应用一次选笔（画布悬浮工具条点插槽 / 平板 PageDown 上报，殊途同归）。选笔即回到笔记模式
    /// （跟 pad 自己 PageDown 切笔时顺带把 modeIdx 归零是同一个道理——选了支笔就是要用它画）。
    /// `pens`/`padPenIndex` 是设备级全局状态，不挂在某个文档会话上，故不需要传 `DocSession`。
    func applyPenSelection(index: Int) {
        padPenIndex = index
        server.broadcast(["type": "pen", "index": index])
        setPadMode("note")
    }

    /// 切换当前工具模式（笔记/擦除/翻页）并广播给 pad。画布悬浮工具条的橡皮/翻页按钮走这个。
    func setPadMode(_ mode: String) {
        guard padMode != mode else { return }
        padMode = mode
        server.broadcast(["type": "mode", "mode": mode])
    }

    /// 收藏笔列表变化（新增/删除/改颜色/改粗细/改类型）→ 整体推给 pad（同 layout/docs 的「变了就广播」套路）。
    func broadcastPens() {
        guard server.isRunning else { return }
        server.broadcast([
            "type": "pens",
            "list": pens.map { ["color": $0.color.cssRGBA, "w": $0.width, "t": $0.type.rawValue] },
            "active": padPenIndex
        ])
    }

    /// 新增一支收藏笔（默认样式），立即选中。返回新笔下标，供调用方直接弹出编辑面板。
    @discardableResult
    func addPen() -> Int {
        pens.append(PenPreset(name: L("Pen"), color: InkColor(r: 90, g: 90, b: 90, a: 0.95), width: 8))
        let idx = pens.count - 1
        applyPenSelection(index: idx)
        return idx
    }

    /// 删除一支收藏笔（至少保留 1 支，调用方需先自行判断 `pens.count > 1`）。
    /// 删掉的是当前选中的那支时回退到第 0 支；删掉的在选中项之前则下标平移，避免选中项错位。
    /// **顺序注意**：`pens` 的 `didSet` 会立即广播一次（带着还没修正的旧 `padPenIndex`），
    /// 修正完下标后必须再广播一次纠正——不然 pad 短暂收到一个跟 Mac 实际不一致的 active 下标。
    func removePen(id: UUID) {
        guard pens.count > 1, let idx = pens.firstIndex(where: { $0.id == id }) else { return }
        pens.remove(at: idx)   // didSet 立即广播一次（此时 padPenIndex 还没修正）
        if padPenIndex == idx { padPenIndex = 0 }
        else if padPenIndex > idx { padPenIndex -= 1 }
        broadcastPens()   // 用修正后的 padPenIndex 再广播一次，纠正上面那次的 active 下标
    }

    // 供 WS 与模拟窗口共用的落墨 API。
    func inkBegin(page: Int, color: InkColor, width: Double, type: PenBrushType = .ballpoint, points: [SIMD3<Double>]) {
        guard let s = padSession else { return }
        s.liveStroke = InkStroke(page: page, color: color, width: width, type: type, points: points)
    }
    func inkAppend(_ pts: [SIMD3<Double>]) {
        guard let s = padSession, var st = s.liveStroke else { return }
        st.points.append(contentsOf: pts); s.liveStroke = st
    }
    func inkEnd() {
        guard let s = padSession, let st = s.liveStroke else { return }
        s.strokes.append(st); s.liveStroke = nil
        broadcastStrokes()
    }
    func inkErase(_ pts: [SIMD3<Double>]) {
        guard let s = padSession else { return }
        eraseNear(s, pts)
        broadcastStrokes()
    }

    /// 把平板当前会话的**全部笔迹**推给平板（平板据此显示 + 刷新/重连后恢复）。
    /// 平板本地不落库、只即时回显正在写的这一笔；已成形/已存的笔迹以 Mac 为唯一真源，靠这里回传。
    func broadcastStrokes() {
        guard server.isRunning, let s = padSession else { return }
        let list: [[String: Any]] = s.strokes.map { st in
            ["page": st.page,
             "pen": ["color": st.color.cssRGBA, "w": st.width, "t": st.type.rawValue],
             "pts": st.points.map { [$0.x, $0.y, $0.z] }]
        }
        server.broadcast(["type": "strokes", "list": list])
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
