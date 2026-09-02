import SwiftUI
import PDFKit
import QuartzCore
import AppKit
import CoreImage   // CIContext（夜间原地反转）

extension ReaderSurface {
    // MARK: 渲染调度（硬指标 1/2：后台出图 + 预缓存；纪律 1/2：白纸占位、只替换）

    func currentBaseWidth() -> Int {
        min(basePixelCap, max(200, Int((pageW * displayScale).rounded())))
    }

    /// 采纳一个基图像素宽（记进 `recentBaseWidths`：最新在前、去重、最多 4 个），供缺图回退查找。
    ///
    /// 🔴 被挤出名单的宽度**必须连带清缓存**：`fallbackBase` 只查名单里那 4 个，出了名单的整套页图
    /// 从此谁也找不到，纯粹是死重。而连续缩放每停一档就产生一整套（键含 `w<pixelWidth>`）——
    /// 2026-08-29 实测 ⌘+ ×5 内存单调涨 723MB、⌘0 回 fit 只掉 24MB，堆的就是这批图。
    func adoptBaseWidth(_ w: Int) {
        scratch.basePixelW = w
        guard scratch.recentBaseWidths.first != w else { return }
        var l = scratch.recentBaseWidths.filter { $0 != w }
        l.insert(w, at: 0)
        var dropped: [Int] = []
        if l.count > 4 {
            dropped = Array(l[4...])
            l.removeLast(l.count - 4)
        }
        scratch.recentBaseWidths = l
        for old in dropped { PageRenderEngine.shared.purgeBase(doc: docKey, pixelWidth: old) }
    }

    /// 目标宽度的图还没渲出来时的**兜底图**：拿这一页以前渲过的任意宽度的缓存图先顶上。
    /// 它比目标宽度糊（或过清），但绝不是白纸——真图渲好后由完成回调原位替换，用户只见"由糊变清"。
    /// 连续缩放时 settle 每 0.15s 就换一次目标宽，旧宽度的图必然大量 miss，没有这条回退就会一路白屏。
    /// 最后再兜一层 Inspector 缩略图那份 160px 图（同 doc/page 键空间，仅亮色）——很糊，但仍胜过白纸。
    func fallbackBase(page: Int) -> CGImage? {
        for w in scratch.recentBaseWidths where w != scratch.basePixelW {
            if let hit = PageRenderEngine.shared.cached(baseKey(page, width: w)) { return hit }
        }
        guard !scratch.nightLive else { return nil }
        return PageRenderEngine.shared.cached(
            PageRenderEngine.baseKey(doc: docKey, page: page,
                                     pixelWidth: ThumbnailListView.pixelWidth, night: false))
    }

    /// ⚠️ 夜间标志一律读 `scratch.nightLive`（Scratch 是引用类型）：逃逸闭包（渲染完成回调、
    /// 夜间 flip 写回）捕获的 self 是值拷贝，其 `nightMode` 在请求发出后可能已切换——用拷贝值算
    /// 「当前期望键」会让守卫失效，陈旧完成穿透写回旧模式图（夜间「切不回来」的根因之一）。
    func baseKey(_ page: Int, width: Int) -> String {
        PageRenderEngine.baseKey(doc: docKey, page: page, pixelWidth: width, night: scratch.nightLive)
    }

    /// 实化窗口变化时：为缺图页出图（缓存命中同步取 → 无 pop-in）。
    /// 入队按「当前页 → 由近及远」：渲染引擎是单串行队列、按提交序出图，可视页必须先排上。
    func kickBaseRenders() {
        guard let pdf = session.pdf else { return }
        if scratch.basePixelW == 0 { adoptBaseWidth(currentBaseWidth()) }
        let w = scratch.basePixelW
        let zooming = isZooming
        var wanted = Set<String>()
        for i in Self.centerOutOrder(center: session.currentPageIndex, bounds: realized) {
            let key = baseKey(i, width: w)
            wanted.insert(key)
            if images[i] == nil, let hit = PageRenderEngine.shared.cached(key) {
                images[i] = hit
                continue
            }
            guard images[i] == nil, let page = pdf.page(at: i) else { continue }
            images[i] = fallbackBase(page: i)   // 先顶一张旧宽度的图（可能为 nil = 这页从没渲过，只能白纸）
            // 缩放进行中不入队：此刻的 `w` 是缩放前的宽度，缩放一停 settleRender 立刻换新宽重排，
            // 这批请求注定作废，却会先把唯一的串行渲染队列占满、把真正要看的那一版挤到后面。
            if !zooming { requestBase(key: key, page: page, index: i, width: w) }
        }
        for t in tiles { wanted.insert(tileKeyFor(page: t.key, normRect: t.value.normRect)) }
        PageRenderEngine.shared.setWanted(wanted, client: scratch.clientID)
    }

    /// settle（滚动/缩放稳定 0.15s）后：按精确宽重渲可见窗口 + 刷新贴片。
    func scheduleSettleRender() {
        // 缩放进行中每帧都会走到这里（zoomAnimFrame 的 scrollTo → geometryChanged），而 0.15s 内
        // 必然又被下一帧取消 —— 每帧白白 cancel + 新建 DispatchWorkItem + asyncAfter。直接让路：
        // 缩放收尾处（pinchEnded / zoomAnimStep 到位分支）都会显式再排一次，不会漏。
        guard !isZooming else { scratch.settleWork?.cancel(); return }
        scratch.settleWork?.cancel()
        let work = DispatchWorkItem { ZoomProbe.measure("settle") { settleRender() } }
        scratch.settleWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    /// 夜间切换（2026-07-26 重设计）：**原地反转当前正在显示的图**，不再靠「键翻转 → 缓存 miss →
    /// 整窗重渲/反转」。切换只依赖本地 `images`/`tiles`（必然就是屏幕当前内容），与全局缓存是否
    /// 驱逐无关 → 双向都即时（并发像素反转，毫秒级）；反色自逆（CIColorInvert+CIHueAdjust 两次还原），
    /// 切回就是再翻一次。反转结果同时喂回引擎缓存（新夜间键），收尾 settleRender 直接命中不重复劳动。
    /// 快速连切：一次只跑一个 flip，飞行中再切记 `nightFlipTo`，落地连锁再翻 → 收敛到最终模式。
    /// 写回按对象同一性逐页守卫：期间被渲染完成回调换掉的页不覆盖（渲染回调本身有键守卫挡陈旧图）。
    func scheduleNightRender() {
        guard scratch.imagesNight != scratch.nightLive else {
            settleRender(nightRadius: Self.nightWarmRadius)   // 已一致：只补 wanted/贴片/预热
            return
        }
        guard !scratch.nightFlipping else {
            scratch.nightFlipTo = scratch.nightLive   // 有 flip 在飞：记目标，落地连锁
            return
        }
        scratch.nightFlipping = true
        scratch.imagesNight = scratch.nightLive       // 乐观置位：本 flip 完成后即此模式
        let snapImg = images, snapTiles = tiles
        let w = currentBaseWidth()
        DispatchQueue.global(qos: .userInitiated).async {
            let ci = CIContext()   // CIContext 线程安全（filter 在 invert 内逐次新建），并发共享
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
                for (i, inv) in outImg where images[i] === snapImg[i] {
                    images[i] = inv
                    PageRenderEngine.shared.seed(inv, forKey: baseKey(i, width: w))
                }
                for (i, t) in outTiles where tiles[i]?.image === snapTiles[i]?.image {
                    tiles[i] = t
                    PageRenderEngine.shared.seed(t.image, forKey: tileKeyFor(page: i, normRect: t.normRect))
                }
                scratch.nightFlipping = false
                let pending = scratch.nightFlipTo
                scratch.nightFlipTo = nil
                if pending != nil {
                    scheduleNightRender()   // 飞行中又切过：连锁再翻（快照已是 flip 后的图）
                } else {
                    settleRender(nightRadius: Self.nightWarmRadius)
                }
            }
        }
    }

    static let nightWarmRadius = 10

    /// `nightRadius>0`（仅夜间模式切换触发）时，在可见窗口之外**额外预热当前页 ± nightRadius 页**，
    /// 按「离当前页近→远」顺序入队（渲染引擎单串行队列按提交序处理，近的先出图）——只翻夜间模式那一刻
    /// 起效的页永远是当前正看的页，不会被"从第 1 页往下"排在后面；继续往外翻也大概率已在缓存里、不再现渲。
    /// 只声明进渲染引擎的全局 LRU 缓存，**不写本地 `images`**：那些页不在 `realized` 里、没有 `PageCellView`
    /// 承载，写了也用不上，还会绕开 `updateRealized` 的驱逐逻辑白占内存（本地 dict 强引用会拖住缓存该淘汰的图）。
    func settleRender(nightRadius: Int = 0) {
        // 墨迹换回高质量描边：缩放停了，按最终倍率重画一次（缩放期间走的是快速路径，半透明笔的
        // 接缝会略深）。放在 guard 之前——没有 layout/pdf 时同样不该把快速态留在屏幕上。
        if inkFastDraw {
            inkFastDraw = false
            inkSnaps = [:]     // 丢掉位图快照 → 页元胞自动回到矢量 Canvas，按最终倍率重画一次
            ZoomProbe.mark("settle → 墨迹换回矢量高质量（zoom \(String(format: "%.2f", zoom))）")
        }
        guard let layout, let pdf = session.pdf, scratch.didInitialGeo else { return }
        // 先定新宽再收窗口：`updateRealized` 内部的 kickBaseRenders 才会按最终宽度入队（顺序反了
        // 就会先照旧宽度发一批注定作废的请求）。缩放期间**不驱逐**任何已出图的页（见 updateRealized），
        // 这里是缩放收尾的第一站，补跑一次把真正出界的那些驱逐掉。
        adoptBaseWidth(currentBaseWidth())
        updateRealized(scratch.geo, layout: layout)
        // 缩放稳定了才回报倍率（供进度持久化）。这是缩放路径上**唯一**该写 `session.readZoom` 的地方
        // ——它是 @Published，逐帧写会每帧广播给整窗视图树，见 DocSession.readZoom 的告警注释。
        if session.readZoom != zoom { session.readZoom = zoom }
        let w = scratch.basePixelW
        var wanted = Set<String>()
        // 贴片先行：放大超过基图上限后，清晰全靠视口贴片——必须排在基图重渲之前，
        // 否则要等整个实化窗口的基图渲完才轮到眼前这页的清晰贴片（用户感知的「放大后糊很久」）。
        wanted.formUnion(ZoomProbe.measure("贴片") { refreshTiles(layout: layout, pdf: pdf) })
        // 基图按「当前页 → 由近及远」入队：单串行队列按提交序出图，可视页插队先清晰。
        for i in Self.centerOutOrder(center: session.currentPageIndex, bounds: realized) {
            guard let page = pdf.page(at: i) else { continue }
            let key = baseKey(i, width: w)
            wanted.insert(key)
            if let hit = PageRenderEngine.shared.cached(key) {
                if images[i] !== hit { images[i] = hit }
            } else {
                // 已有图的页保持旧图（只是分辨率不对，糊一点）——纪律 2「只替换不清空」；
                // 空着的页先拿旧宽度的兜底图顶上，别让用户对着白纸等这一轮渲染。
                if images[i] == nil { images[i] = fallbackBase(page: i) }
                requestBase(key: key, page: page, index: i, width: w)
            }
        }
        if nightRadius > 0 {
            wanted.formUnion(warmNeighborKeys(pdf: pdf, pageCount: layout.pageCount, width: w, radius: nightRadius))
        }
        PageRenderEngine.shared.setWanted(wanted, client: scratch.clientID)
    }

    /// 当前页 ± radius 页（去掉已在 `realized` 内、已由上面处理的）的缓存预热键，按近→远顺序请求。
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
                                                  tileRect: nil, tileScale: 1, night: scratch.nightLive,
                                                  diskCache: !isZooming)) { _, _ in }
        }
        return keys
    }

    /// `bounds` 内的**全部**页，按「离 `center` 由近及远」排序（渲染优先级：越靠近当前页越先出图）。
    ///
    /// ⚠️ **`center` 必须先夹取进 `bounds`**（2026-07-27 实测定位的白屏根因）：旧实现从 `center`
    /// 向两侧外扩固定 `radius` 步、只收落在 `bounds` 内的页，于是 `center` 离 `bounds` 超过 `radius`
    /// 时**返回空数组**——调用方的渲染循环一次都不进，那批页永远发不出渲染请求。
    /// 而 `center`（`session.currentPageIndex`）的更新在 `updateRealized` 里被 `follower.isSuppressing`
    /// / `suppressEmitUntil` 门控（平板跟随、缩放/refit 期间停更），用户快滚一下 `realized` 就能跳出
    /// 那点距离 → 屏幕整片白，且 settle 每 0.15s 重试一次也永远是空转（实测：17 秒里 5 次 settle，
    /// missing 恒为同样 5 页，零 ENQUEUE）。夹取后无论 `center` 在哪，覆盖面都恒等于 `bounds`，
    /// 只影响出图**顺序**、不影响出图**与否**。
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

    func requestBase(key: String, page: PDFPage, index: Int, width: Int) {
        let night = scratch.nightLive
        // 🔴 缩放**过程中**的中间宽度不落盘：`currentBaseWidth()` 不分档，每停一下就是一整套新键，
        // 全写进去就是拿磁盘换一堆再也不会被问到的图（同 `recentBaseWidths` 只留 4 档的账）。
        PageRenderEngine.shared.request(.init(key: key, page: page, pixelWidth: width,
                                              tileRect: nil, tileScale: 1, night: night,
                                              diskCache: !isZooming)) { doneKey, img in
            ZoomProbe.measure("图落地") {
            // 「仍是当前期望键」（键含夜间标志与宽度）= 正解，直接写入。
            if doneKey == baseKey(index, width: scratch.basePixelW) {
                images[index] = img
                return
            }
            // 宽度已经变了（连续缩放时 settle 每 0.15s 就换一次目标宽，前一轮的完成必然全部落到这里）。
            // 旧规矩是一律丢弃 —— 图明明渲好了、也已进缓存，却因为宽度对不上被扔掉，而这一页正空着，
            // 用户就得对着白纸干等下一轮渲染（连续缩放白屏的主因）。改为：这页空着就先顶上，等正解替换。
            // **夜间标志必须相符**，否则会把亮色图糊到夜间模式上（夜间"切不回来"那类 bug 的老路）。
            if images[index] == nil, night == scratch.nightLive { images[index] = img }
            }
        }
    }

    // MARK: 高倍清晰贴片（基图上限之外由视口贴片补清晰；只在 settle 后刷新，替换式更新）

    func tileKeyFor(page: Int, normRect: CGRect) -> String {
        PageRenderEngine.tileKey(doc: docKey, page: page, normRect: normRect,
                                 scale: displayScale, night: scratch.nightLive)
    }

    func refreshTiles(layout: PageLayout, pdf: PDFDocument) -> Set<String> {
        var wanted = Set<String>()
        let needTiles = pageW * displayScale > CGFloat(basePixelCap) + 1
        guard needTiles else {
            if !tiles.isEmpty { tiles = [:] }   // 基图已够清晰，贴片移除不产生视觉变化
            return wanted
        }
        let g = scratch.geo
        let ds = max(0.0001, dispScale)
        let visTop = g.offsetY / ds, visBottom = (g.offsetY + g.containerH) / ds
        let visPages = layout.pageRange(fromDocY: visTop, toDocY: visBottom)
        // 同样按「当前页 → 由近及远」入队：跨页视口时当前页贴片最先出图。
        for i in Self.centerOutOrder(center: session.currentPageIndex, bounds: visPages) {
            guard let page = pdf.page(at: i) else { continue }
            let pageH = layout.heights[i] * ds
            // 视口 ∩ 页（页内显示 pt，左上原点），四周外扩 15%
            let pageTopDisp = layout.offsets[i] * ds
            var r = CGRect(x: g.offsetX - pageX,
                           y: g.offsetY - pageTopDisp,
                           width: g.containerW, height: g.containerH)
                .insetBy(dx: -g.containerW * 0.15, dy: -g.containerH * 0.15)
                .intersection(CGRect(x: 0, y: 0, width: pageW, height: pageH))
            guard !r.isNull, r.width > 1, r.height > 1 else { continue }
            // 归一化 + 1/64 量化（缓存友好）
            func q(_ v: CGFloat) -> CGFloat { (v * 64).rounded() / 64 }
            let norm = CGRect(x: q(r.minX / pageW), y: q(r.minY / pageH),
                              width: q(r.width / pageW), height: q(r.height / pageH))
                .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
            guard norm.width > 0, norm.height > 0 else { continue }
            let key = tileKeyFor(page: i, normRect: norm)
            wanted.insert(key)
            if tiles[i]?.normRect == norm,
               let hit = PageRenderEngine.shared.cached(key), tiles[i]?.image === hit { continue }
            if let hit = PageRenderEngine.shared.cached(key) {
                tiles[i] = PageTile(normRect: norm, image: hit)
                continue
            }
            // 子矩形按页自然显示坐标（pt）+ 像素比例
            let natural = PageBitmap.displaySize(page)
            let sub = CGRect(x: norm.minX * natural.width, y: norm.minY * natural.height,
                             width: norm.width * natural.width, height: norm.height * natural.height)
            let scale = (pageW * displayScale) / max(1, natural.width)
            let idx = i
            PageRenderEngine.shared.request(.init(key: key, page: page, pixelWidth: nil,
                                                  tileRect: sub, tileScale: scale, night: scratch.nightLive)) { doneKey, img in
                if doneKey == tileKeyFor(page: idx, normRect: norm) {
                    tiles[idx] = PageTile(normRect: norm, image: img)
                }
            }
        }
        // 不再可见的页贴片移除（页外，无视觉影响）
        let visible = layout.pageRange(fromDocY: visTop, toDocY: visBottom)
        for k in tiles.keys where !(visible ~= k) { tiles.removeValue(forKey: k) }
        return wanted
    }

}
