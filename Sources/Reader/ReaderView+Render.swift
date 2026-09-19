import AppKit
import CoreImage
import PDFKit
import QuartzCore

/// 出图调度（硬指标 1/2：后台出图 + 预缓存；纪律：白纸占位、只替换不清空）。
/// 与 SwiftUI 版 `ReaderSurface+Render` 同一套规则，逐条移植；差别只在「写图」变成给图层赋 `contents`。
extension ReaderView {

    // MARK: 写图

    func setImage(_ page: Int, _ img: CGImage?) {
        images[page] = img
        if let g = groups[page] { g.image.contents = img }
    }

    func setTileImage(_ page: Int, _ t: PageTile?) {
        tiles[page] = t
        groups[page]?.setTile(t?.normRect, image: t?.image)
    }

    // MARK: 基图宽度

    func currentBaseWidth() -> Int {
        min(basePixelCap, max(200, Int((pageW * backingScale).rounded())))
    }

    /// 采纳一个基图宽（最近用过的 4 档，最新在前）。被挤出名单的宽度连带清缓存（否则整套图成死重）。
    func adoptBaseWidth(_ w: Int) {
        basePixelW = w
        guard recentBaseWidths.first != w else { return }
        var l = recentBaseWidths.filter { $0 != w }
        l.insert(w, at: 0)
        var dropped: [Int] = []
        if l.count > 4 {
            dropped = Array(l[4...])
            l.removeLast(l.count - 4)
        }
        recentBaseWidths = l
        for old in dropped { PageRenderEngine.shared.purgeBase(doc: docKey, pixelWidth: old) }
    }

    func baseKey(_ page: Int, width: Int) -> String {
        PageRenderEngine.baseKey(doc: docKey, page: page, pixelWidth: width, night: nightLive)
    }

    func tileKey(page: Int, normRect: CGRect) -> String {
        PageRenderEngine.tileKey(doc: docKey, page: page, normRect: normRect, scale: backingScale, night: nightLive)
    }

    /// 目标宽度还没渲出来时的兜底：以前渲过的任一宽度 → Inspector 缩略图那份（仅亮色）。糊，但不是白纸。
    func fallbackBase(page: Int) -> CGImage? {
        for w in recentBaseWidths where w != basePixelW {
            if let hit = PageRenderEngine.shared.cached(baseKey(page, width: w)) { return hit }
        }
        guard !nightLive else { return nil }
        return PageRenderEngine.shared.cached(
            PageRenderEngine.baseKey(doc: docKey, page: page, pixelWidth: ThumbnailListNSView.pixelWidth, night: false))
    }

    func hasTargetImage(_ page: Int, width: Int) -> Bool {
        guard let cur = images[page] else { return false }
        return cur.width == width && imagesNight == nightLive
    }

    // MARK: 交回缓存

    /// 放手一张页图：先交回缓存再丢（视图持有的图往往已不在缓存里，直接丢就是真丢）。
    func releaseImage(page: Int) {
        guard let img = images.removeValue(forKey: page) else { return }
        groups[page]?.image.contents = nil
        seedToCache(page: page, image: img)
    }

    func handOffImagesToCache() {
        for (p, img) in images { seedToCache(page: p, image: img) }
    }

    private func seedToCache(page: Int, image: CGImage) {
        let w = basePixelW
        guard w > 0, image.width == w else { return }
        PageRenderEngine.shared.seed(image, forKey: PageRenderEngine.baseKey(
            doc: docKey, page: page, pixelWidth: w, night: imagesNight))
    }

    /// 本阅读区销毁时：文档还开在别的标签 / 窗口里 → 只把当前宽度的图交回缓存；没人再看 → 整篇清掉。
    func releaseRenderCache() {
        let stillOpen = app.sessions.contains { $0.displayKey == docKey }
        guard !stillOpen else {
            handOffImagesToCache()
            PageRenderEngine.shared.purgeBase(doc: docKey, keeping: basePixelW)
            return
        }
        PageRenderEngine.shared.purge(doc: docKey)
    }

    /// 向 `PageHoldings` 回报本阅读区攥着的页位图（设置页诊断 + 缓存额度让位）。
    func reportHoldings() {
        var h = PageHolding(kind: .reader,
                            label: session.title.isEmpty ? String(docKey.prefix(8)) : session.title,
                            active: isActiveWindow, realized: realized)
        for img in images.values { h.imageCount += 1; h.imageBytes += PageHolding.bytes(of: img) }
        for t in tiles.values { h.tileCount += 1; h.tileBytes += PageHolding.bytes(of: t.image) }
        PageHoldings.shared.report(h, client: clientID)
    }

    // MARK: 调度

    /// 实化窗口变了：缺图的页缓存命中同步取（无 pop-in），否则先顶兜底图再入队。
    func kickBaseRenders() {
        guard let pdf = session.pdf else { return }
        if basePixelW == 0 { adoptBaseWidth(currentBaseWidth()) }
        let w = basePixelW
        let zooming = isZooming
        var wanted = Set<String>()
        for i in Self.centerOutOrder(center: session.currentPageIndex, bounds: realized) {
            let key = baseKey(i, width: w)
            wanted.insert(key)
            if images[i] == nil, let hit = PageRenderEngine.shared.cached(key) {
                setImage(i, hit)
                continue
            }
            guard images[i] == nil, i >= 0, i < pdf.pageCount else { continue }
            setImage(i, fallbackBase(page: i))
            // 缩放中不入队：此刻的宽度注定作废，别占住唯一的串行渲染队列
            if !zooming { requestBase(key: key, doc: pdf, index: i, width: w) }
        }
        for t in tiles { wanted.insert(tileKey(page: t.key, normRect: t.value.normRect)) }
        PageRenderEngine.shared.setWanted(wanted, client: clientID)
        reportHoldings()
    }

    /// 滚动 / 缩放稳定 0.15s 后按精确宽度重渲 + 刷新贴片。缩放进行中不排（收尾处会显式再排）。
    func scheduleSettle(after delay: TimeInterval = 0.15) {
        settleWork?.cancel()
        guard !isZooming else { settleWork = nil; return }
        let work = DispatchWorkItem { [weak self] in
            self?.settleWork = nil
            self?.settleRender()
        }
        settleWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    func settleRender(nightRadius: Int = 0) {
        guard let layout = pageLayout, let pdf = session.pdf, didSetup else { return }
        geoLog("settle")
        adoptBaseWidth(currentBaseWidth())
        let settled = updateRealized()
        // 笔迹按页窗口装载：只在 settle 时报范围（逐帧装卸 = 逐帧写 @Published strokes，红线）
        session.inkWindowRequests.send(settled)
        // 缩放稳定了才回报倍率（供进度持久化）；`readZoom` 是 @Published，别逐帧写
        if session.readZoom != zoom { session.readZoom = zoom }
        refreshInkScale()
        refreshMarks()   // 标记层同样按新倍率重画（固定屏幕点的线宽 / 外扩跟着换算）
        layoutOverlay()
        let w = basePixelW
        var wanted = Set<String>()
        // 贴片先行：放大超过基图上限后清晰全靠它，必须排在基图重渲之前
        wanted.formUnion(refreshTiles(layout: layout, pdf: pdf))
        for i in Self.centerOutOrder(center: session.currentPageIndex, bounds: realized) {
            guard i >= 0, i < pdf.pageCount else { continue }
            let key = baseKey(i, width: w)
            wanted.insert(key)
            if let hit = PageRenderEngine.shared.cached(key) {
                if images[i] !== hit { setImage(i, hit) }
            } else if hasTargetImage(i, width: w) {
                // 屏幕上已经是这张（只是缓存那份引用被淘汰了）——不重渲
            } else {
                if images[i] == nil { setImage(i, fallbackBase(page: i)) }   // 只替换不清空
                requestBase(key: key, doc: pdf, index: i, width: w)
            }
        }
        if nightRadius > 0 {
            wanted.formUnion(warmNeighborKeys(pdf: pdf, pageCount: layout.pageCount, width: w, radius: nightRadius))
        }
        PageRenderEngine.shared.setWanted(wanted, client: clientID)
        reportHoldings()
    }

    /// 当前页 ± radius 页的缓存预热（夜间切换用）：只进全局缓存，不写本地 `images`。
    func warmNeighborKeys(pdf: PDFDocument, pageCount: Int, width: Int, radius: Int) -> Set<String> {
        let center = session.currentPageIndex
        guard pageCount > 0 else { return [] }
        let bounds = max(0, center - radius)...min(pageCount - 1, center + radius)
        var keys = Set<String>()
        for i in Self.centerOutOrder(center: center, bounds: bounds) where !realized.contains(i) {
            guard let page = pdf.page(at: i) else { continue }
            let key = baseKey(i, width: width)
            keys.insert(key)
            guard PageRenderEngine.shared.cached(key) == nil else { continue }
            PageRenderEngine.shared.request(.init(key: key, page: page, pixelWidth: width,
                                                  tileRect: nil, tileScale: 1, night: nightLive,
                                                  diskCache: !isZooming, align: session.pageAlign(i))) { _, _ in }
        }
        return keys
    }

    /// `bounds` 内全部页，按离 `center` 由近及远（渲染优先级）。`center` 先夹进 `bounds`
    /// （2026-07-27 白屏根因：不夹取时返回空数组，整批页永远发不出请求）。
    static func centerOutOrder(center: Int, bounds: ClosedRange<Int>) -> [Int] {
        let c = min(max(center, bounds.lowerBound), bounds.upperBound)
        var order = [c]
        order.reserveCapacity(bounds.count)
        var d = 1
        while order.count < bounds.count, d <= bounds.count {
            if bounds.contains(c - d) { order.append(c - d) }
            if bounds.contains(c + d) { order.append(c + d) }
            d += 1
        }
        return order
    }

    func requestBase(key: String, doc: PDFDocument, index: Int, width: Int) {
        let night = nightLive
        PageRenderEngine.shared.request(.init(key: key, doc: doc, index: index, pixelWidth: width,
                                              night: night, diskCache: !isZooming,
                                              align: session.pageAlign(index))) { [weak self] doneKey, img in
            guard let self, !self.tornDown else { return }
            // 页已滚出留图范围：不写（图已在缓存里，滑回来照样命中）
            guard self.keepRange.contains(index) else { return }
            if doneKey == self.baseKey(index, width: self.basePixelW) {
                self.setImage(index, img)
                return
            }
            // 宽度已变（连续缩放）：这页空着就先顶上，等正解替换；夜间标志必须相符
            if self.images[index] == nil, night == self.nightLive { self.setImage(index, img) }
        }
    }

    // MARK: 高倍清晰贴片

    /// 基图上限之外由视口贴片补清晰（只在 settle 后刷新，替换式更新）。
    func refreshTiles(layout: PageLayout, pdf: PDFDocument) -> Set<String> {
        var wanted = Set<String>()
        let scale = backingScale
        let needTiles = pageW * scale > CGFloat(basePixelCap) + 1
        guard needTiles else {
            for k in Array(tiles.keys) { setTileImage(k, nil) }   // 基图已够清晰，移除无视觉变化
            return wanted
        }
        let vis = clipView.bounds
        let d = max(0.0001, ds)
        let visPages = layout.pageRange(fromDocY: vis.minY / d, toDocY: vis.maxY / d)
        for i in Self.centerOutOrder(center: session.currentPageIndex, bounds: visPages) {
            guard let page = pdf.page(at: i) else { continue }
            let pf = pageFrame(i)
            // 视口 ∩ 页（文档坐标），四周外扩 15%，折成页内归一化并量化到 1/64（缓存友好）
            let r = vis.insetBy(dx: -vis.width * 0.15, dy: -vis.height * 0.15).intersection(pf)
            guard !r.isNull, r.width > 0.5, r.height > 0.5 else { continue }
            func q(_ v: CGFloat) -> CGFloat { (v * 64).rounded() / 64 }
            let norm = CGRect(x: q((r.minX - pf.minX) / pf.width), y: q((r.minY - pf.minY) / pf.height),
                              width: q(r.width / pf.width), height: q(r.height / pf.height))
                .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
            guard norm.width > 0, norm.height > 0 else { continue }
            let key = tileKey(page: i, normRect: norm)
            wanted.insert(key)
            let wantPx = Int((norm.width * pageW * scale).rounded())
            if let t = tiles[i], t.normRect == norm, abs(t.image.width - wantPx) <= 2, imagesNight == nightLive { continue }
            if let hit = PageRenderEngine.shared.cached(key) {
                setTileImage(i, PageTile(normRect: norm, image: hit))
                continue
            }
            let align = session.pageAlign(i)
            let natural = PageBitmap.displaySize(page, align: align)
            let sub = CGRect(x: norm.minX * natural.width, y: norm.minY * natural.height,
                             width: norm.width * natural.width, height: norm.height * natural.height)
            let tileScale = (pageW * scale) / max(1, natural.width)
            PageRenderEngine.shared.request(.init(key: key, page: page, pixelWidth: nil,
                                                  tileRect: sub, tileScale: tileScale, night: nightLive,
                                                  align: align)) { [weak self] doneKey, img in
                guard let self, !self.tornDown, self.keepRange.contains(i) else { return }
                if doneKey == self.tileKey(page: i, normRect: norm) {
                    self.setTileImage(i, PageTile(normRect: norm, image: img))
                }
            }
        }
        for k in Array(tiles.keys) where !visPages.contains(k) { setTileImage(k, nil) }
        return wanted
    }

    // MARK: 夜间模式（原地反转）

    static let nightWarmRadius = 10

    /// 夜间切换：**原地反转屏幕上正显示的图**（并发像素反转，毫秒级），反转结果喂回缓存（新夜间键）。
    /// 快速连切：一次只跑一个，飞行中再切记下目标，落地连锁再翻。写回按对象同一性逐页守卫。
    func scheduleNightRender() {
        applyNightColors()
        guard imagesNight != nightLive else {
            settleRender(nightRadius: Self.nightWarmRadius)
            return
        }
        guard !nightFlipping else {
            nightFlipTo = nightLive
            return
        }
        nightFlipping = true
        imagesNight = nightLive
        let snapImg = images, snapTiles = tiles
        let w = currentBaseWidth()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let ci = CIContext()
            let lock = NSLock()
            var outImg = [Int: CGImage](), outTiles = [Int: PageTile]()
            let imgEntries = Array(snapImg), tileEntries = Array(snapTiles)
            DispatchQueue.concurrentPerform(iterations: imgEntries.count + tileEntries.count) { k in
                if k < imgEntries.count {
                    let (i, img) = imgEntries[k]
                    if let inv = PageBitmap.invert(img, ci: ci) { lock.lock(); outImg[i] = inv; lock.unlock() }
                } else {
                    let (i, t) = tileEntries[k - imgEntries.count]
                    if let inv = PageBitmap.invert(t.image, ci: ci) {
                        lock.lock(); outTiles[i] = PageTile(normRect: t.normRect, image: inv); lock.unlock()
                    }
                }
            }
            DispatchQueue.main.async {
                guard let self, !self.tornDown else { return }
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                for (i, inv) in outImg where self.images[i] === snapImg[i] {
                    self.setImage(i, inv)
                    PageRenderEngine.shared.seed(inv, forKey: self.baseKey(i, width: w))
                }
                for (i, t) in outTiles where self.tiles[i]?.image === snapTiles[i]?.image {
                    self.setTileImage(i, t)
                    PageRenderEngine.shared.seed(t.image, forKey: self.tileKey(page: i, normRect: t.normRect))
                }
                CATransaction.commit()
                self.nightFlipping = false
                let pending = self.nightFlipTo
                self.nightFlipTo = nil
                if pending != nil { self.scheduleNightRender() }
                else { self.settleRender(nightRadius: Self.nightWarmRadius) }
            }
        }
    }

    /// 纸色 / 空隙底色跟着夜间模式走（与页图反转同一拍提交）。
    func applyNightColors() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        scrollView.backgroundColor = voidColor
        for g in groups.values { g.paper.backgroundColor = paperColor }
        CATransaction.commit()
    }
}
