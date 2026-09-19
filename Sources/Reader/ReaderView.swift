import AppKit
import Combine
import PDFKit
import QuartzCore

/// AppKit 版阅读区（`APPKIT-REWRITE-PLAN.md` §3，替代 SwiftUI 的 `PageStreamView` / `ReaderSurface`）。
///
/// 结构：`ReaderScrollView` → `ReaderClipView` → `ReaderDocumentView`（flipped）→ 每页一组 `PageLayerGroup`。
///
/// **坐标约定**（全文件只有这一套）：
///  · 布局单位 = `PageLayout` 的文档单位（参考宽 1000）；
///  · 文档坐标 = 文档视图的点，页宽恒为 `fitBasis`（fit 宽）——`ds = fitBasis / refWidth` 把布局单位换成文档坐标；
///  · 缩放 = 滚动视图的 `magnification`（= SwiftUI 版的 `zoom`，相对 fit 的倍率），屏幕页宽 = `fitBasis × zoom`；
///  · 视图点 = 屏幕点；`contentInsets`（上 = 工具栏、右 = 内置 AI 面板）是视图点，换成文档坐标要 ÷ zoom。
///
/// 五条硬指标怎么落在 AppKit 上见方案 §3.2；本文件只放几何、实化、位置与生命周期，
/// 出图在 `+Render`、缩放在 `+Zoom`、锚点与跟随在 `+Follow`。
@MainActor
final class ReaderView: NSView {
    let session: DocSession
    let app: AppModel
    let workspace: WorkspaceManager
    /// 显示身份（`DocSession.displayKey`）：页图缓存键的 doc 部分。换了就整个换一个 `ReaderView`。
    let docKey: String

    // MARK: 宿主给的输入

    /// 工具栏占掉的顶部高度（视图点）。页面从它下面开始、滚上去从它底下透过去。
    var topInset: CGFloat = 0 { didSet { if oldValue != topInset { applyInsets() } } }
    /// 右侧内置 AI 面板盖住的宽度（视图点）：页面适配到左边剩下的那块，外框不变（方案 §3.3）。
    var panelInset: CGFloat = 0 { didSet { if oldValue != panelInset { applyInsets() } } }
    /// 滚动条底部让位（底部标签栏）。内容仍垫到底。
    var scrollerBottomInset: CGFloat = 0 { didSet { if oldValue != scrollerBottomInset { applyInsets() } } }
    var isActiveWindow = false { didSet { if oldValue != isActiveWindow { activeWindowChanged() } } }
    var interpEnabled = true { didSet { follower.interpEnabled = interpEnabled } }

    // MARK: 视图

    let scrollView = ReaderScrollView()
    let clipView = ReaderClipView()
    let docView = ReaderDocumentView()

    // MARK: 布局 / 缩放状态

    /// 页面布局（纯数学，`PageLayout`）。不叫 `layout`：那是 `NSView.layout()`。
    var pageLayout: PageLayout?
    /// fit 基准宽（文档坐标里的页宽）。窗口 / 面板宽度变了、稳定后重定（`refit`）。
    var fitBasis: CGFloat = 0
    /// 用户缩放过（捏合 / ⌘± / ⌘滚轮）：宽度变化时保持屏幕页宽，而不是重新 fit。
    var userZoomed = false
    /// 画板模式每侧页边（页宽的倍数），见 `CanvasMargin`。
    var canvasMarginState: Double = CanvasMargin.step
    let zoomMin: CGFloat = 0.25
    let zoomMax: CGFloat = 6
    let basePixelCap = 2800
    /// 「这个宽度不可能是真实布局」的下限：落位前的占位几何别拿来定基准（开窗一瞬页面很小再放大）。
    let minPlausibleWidth: CGFloat = 200

    // MARK: 实化 / 页图

    var realized: ClosedRange<Int> = 0...0
    var didRealize = false
    var groups: [Int: PageLayerGroup] = [:]
    var pool: [PageLayerGroup] = []
    var images: [Int: CGImage] = [:]
    var tiles: [Int: PageTile] = [:]
    var basePixelW = 0
    var recentBaseWidths: [Int] = []
    /// 允许留图的页范围（实化窗口 ± 余量）。迟到的渲染完成按它守门。
    var keepRange: ClosedRange<Int> = 0...Int.max
    /// 渲染引擎的多窗口 wanted 隔离键。
    let clientID = UUID().uuidString
    // 夜间模式「原地反转」
    var nightLive = false
    var imagesNight = false
    var nightFlipping = false
    var nightFlipTo: Bool?

    // MARK: 滚动 / 锚点

    let follower = ScrollFollower()
    var lastAppliedSeq = 0
    var suppressEmitUntil: CFTimeInterval = 0
    var lastEmitAt: CFTimeInterval = 0
    var lastEmitted: (page: Int, frac: Double)?
    var matchPulsePending = false

    // MARK: 缩放

    var isLiveMagnifying = false
    var zoomAnim: ZoomAnimState?

    // MARK: 生命周期

    var didSetup = false
    var tornDown = false
    var appearAt: CFTimeInterval = 0
    var lastFitAvail: CGFloat = 0
    var settleWork: DispatchWorkItem?
    var refitWork: DispatchWorkItem?
    var frameLink: CADisplayLink?
    var bag = Set<AnyCancellable>()
    var observers: [NSObjectProtocol] = []

    init(session: DocSession, app: AppModel, workspace: WorkspaceManager, docKey: String) {
        self.session = session
        self.app = app
        self.workspace = workspace
        self.docKey = docKey.isEmpty ? "untitled" : docKey
        super.init(frame: .zero)
        wantsLayer = true
        nightLive = UserDefaults.standard.bool(forKey: "nightMode")
        imagesNight = nightLive

        scrollView.contentView = clipView
        scrollView.documentView = docView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.allowsMagnification = true
        scrollView.minMagnification = zoomMin
        scrollView.maxMagnification = zoomMax
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.drawsBackground = true
        scrollView.backgroundColor = voidColor
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        clipView.postsBoundsChangedNotifications = true
        addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        scrollView.onCommandWheel = { [weak self] factor, p in self?.commandWheel(factor: factor, docPoint: p) ?? false }
        follower.interpEnabled = interpEnabled
        installObservers()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) 不支持") }

    // MARK: 颜色

    var paperColor: CGColor { nightLive ? CGColor(gray: 0.10, alpha: 1) : CGColor(gray: 1, alpha: 1) }
    /// 页与页之间 / 未实化区域的底色。夜间模式下不能用系统底色（会露出一块亮的）。
    var voidColor: NSColor { nightLive ? NSColor(white: 0.06, alpha: 1) : .windowBackgroundColor }

    // MARK: 几何换算

    var zoom: CGFloat { scrollView.magnification }
    var ds: CGFloat { fitBasis / PageLayout.refWidth }
    var canvasMargin: Double { session.canvasMode ? canvasMarginState : 0 }
    /// 画板页边宽（文档坐标，每侧）。
    var marginDoc: CGFloat { fitBasis * CGFloat(canvasMargin) }
    var backingScale: CGFloat { window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2 }
    /// 屏幕上的页宽（点）。
    var pageW: CGFloat { fitBasis * zoom }

    /// fit 可用宽（视图点）：clip view 宽 − 左右内容内边距（右 = AI 面板）。与内容无关 → 不会互抬成环。
    var fitAvail: CGFloat {
        let ci = scrollView.contentInsets
        return max(1, clipView.frame.width - ci.left - ci.right)
    }

    func pageFrame(_ i: Int) -> CGRect {
        guard let layout = pageLayout else { return .zero }
        return CGRect(x: marginDoc, y: layout.offsets[i] * ds, width: fitBasis, height: layout.heights[i] * ds)
    }

    /// 顶部内边距（工具栏）折成文档坐标。
    var insetTopDoc: CGFloat { scrollView.contentInsets.top / max(0.0001, zoom) }

    /// 视口顶边（工具栏下沿）对应的布局单位 docY——锚点、当前页都按它算。
    var topDocY: CGFloat { (clipView.bounds.minY + insetTopDoc) / max(0.0001, ds) }

    // MARK: 内边距

    func applyInsets() {
        let ci = scrollView.contentInsets
        if ci.top != topInset || ci.right != panelInset || ci.left != 0 || ci.bottom != 0 {
            scrollView.contentInsets = NSEdgeInsets(top: topInset, left: 0, bottom: 0, right: panelInset)
        }
        let si = scrollView.scrollerInsets
        if si.bottom != scrollerBottomInset {
            scrollView.scrollerInsets = NSEdgeInsets(top: 0, left: 0, bottom: scrollerBottomInset, right: 0)
        }
        needsLayout = true
    }

    // MARK: 布局

    override func layout() {
        super.layout()
        guard !tornDown else { return }
        if !didSetup {
            setupIfPossible()
            return
        }
        let avail = fitAvail
        if abs(avail - lastFitAvail) > 0.5 {
            lastFitAvail = avail
            scheduleRefit()
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            teardown()
        } else {
            needsLayout = true
        }
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        guard didSetup else { return }
        refitWork?.cancel(); refitWork = nil
        refit()
    }

    /// 首次落位：布局就绪、宽度可信时一次性摆好基准 / 缩放 / 位置 / 首屏图——都在第一次上屏之前，
    /// 所以切标签回来不会先白一帧（SwiftUI 版为此专门做过「快照种子」，AppKit 里天然同步）。
    func setupIfPossible() {
        guard session.pdf != nil, bounds.width >= minPlausibleWidth, clipView.frame.width >= minPlausibleWidth else { return }
        guard let lay = loadLayout() else { return }
        pageLayout = lay
        follower.pageCount = lay.pageCount
        appearAt = CACurrentMediaTime()
        canvasMarginState = CanvasMargin.margin(overflow: session.inkOverflow())
        session.canvasMarginLive = session.canvasMode ? canvasMarginState : 0

        applyInsets()
        fitBasis = fitAvail
        lastFitAvail = fitBasis
        // 缩放：切标签回来用会话当前倍率（`readZoom`），冷开用库里恢复的倍率（`restoreZoom`）
        let z = clampZoom(session.readerSeedPending ? session.readZoom : session.restoreZoom)
        userZoomed = abs(z - 1) > 0.001
        session.readerSeedPending = false

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layoutDocument()
        scrollView.magnification = z
        // 位置：会话记着的锚点（恢复进度 / 切标签 / 目录跳转）直接到位，不走跟随动画
        if let a = session.scrollAnchor {
            lastAppliedSeq = a.seq
            let hfrac = session.readHFrac > 0.0001 ? CGFloat(session.readHFrac)
                      : (session.restoreHFrac > 0.0001 ? session.restoreHFrac : 0)
            scroll(toPage: a.page, frac: a.frac, hfrac: hfrac)
        } else {
            scroll(toPage: 0, frac: 0, hfrac: 0)
        }
        didSetup = true
        updateRealized()
        CATransaction.commit()

        suppressEmitUntil = CACurrentMediaTime() + 0.3
        scheduleSettle(after: 0)
        revealNote(session.revealNoteID)
    }

    /// 布局：会话缓存 → 扫描页对齐参数 → 库里存的页高 → 现算（现算完后台回填库）。与 SwiftUI 版 `setup` 同一顺序。
    func loadLayout() -> PageLayout? {
        guard let pdf = session.pdf else { return nil }
        let lay: PageLayout
        let align = session.scanAlign
        var fromStore: [Double]?
        if session.cachedLayout == nil, align == nil, let store = session.store, !session.contentHash.isEmpty {
            let hash = session.contentHash, n = pdf.pageCount
            fromStore = session.openTrace.phase("布局读库") { try? store.pageHeights(contentHash: hash, pageCount: n) }
        }
        if let cached = session.cachedLayout {
            lay = cached
        } else if let align {
            lay = PageLayout(heights: align.heights(refWidth: Double(PageLayout.refWidth)).map { CGFloat($0) })
        } else if let hs = fromStore {
            lay = PageLayout(heights: hs.map { CGFloat($0) })
        } else {
            lay = session.openTrace.phase("布局计算", detail: "\(pdf.pageCount)页") { PageLayout(doc: pdf) }
            if let store = session.store, !session.contentHash.isEmpty {
                let hash = session.contentHash, hs = lay.heights.map { Double($0) }
                Task.detached(priority: .utility) { try? store.savePageHeights(contentHash: hash, heights: hs) }
            }
        }
        session.cachedLayout = lay
        return lay
    }

    /// 按当前 `fitBasis` / 页边摆文档视图与所有已实化的页。调用方负责包 CATransaction（或本来就在无动画图层上）。
    func layoutDocument() {
        guard let layout = pageLayout else { return }
        let docW = fitBasis * CGFloat(1 + 2 * canvasMargin)
        let docH = layout.totalHeight * ds
        let f = NSRect(x: 0, y: 0, width: docW, height: docH)
        if docView.frame != f { docView.frame = f }
        let m = marginDoc
        for (i, g) in groups { g.place(frame: pageFrame(i), margin: m) }
    }

    // MARK: 滚动定位

    /// 让文档坐标点 `origin` 成为 clip view 的 bounds 原点（经系统夹取），并同步滚动条。
    func scrollClip(to origin: NSPoint) {
        let r = clipView.constrainBoundsRect(NSRect(origin: origin, size: clipView.bounds.size))
        clipView.scroll(to: r.origin)
        scrollView.reflectScrolledClipView(clipView)
    }

    /// 滚到某页某比例（贴在工具栏下沿）。`hfrac` = 横向滚动占页宽的比例（nil = 保持当前横向）。
    func scroll(toPage page: Int, frac: Double, hfrac: CGFloat?) {
        guard let layout = pageLayout else { return }
        let y = layout.docY(page: page, frac: frac) * ds - insetTopDoc
        let x = hfrac.map { $0 * fitBasis } ?? clipView.bounds.minX
        scrollClip(to: NSPoint(x: x, y: y))
    }

    // MARK: 实化

    /// 按当前可见区（活跃窗口上下各多一屏）决定哪些页要有图层；变了才增删。返回实化范围。
    @discardableResult
    func updateRealized() -> ClosedRange<Int> {
        guard let layout = pageLayout, didSetup else { return realized }
        let b = clipView.bounds
        let d = max(0.0001, ds)
        // 非活跃窗口只实化可见页、图也只留可见页（多窗口内存，2026-09-10 定）
        let buffer = isActiveWindow ? b.height : 0
        let keepMargin = isActiveWindow ? 2 : 0
        var range = layout.pageRange(fromDocY: (b.minY - buffer) / d, toDocY: (b.maxY + buffer) / d)
        let zooming = isZooming
        if zooming {
            // 缩放中只扩不缩（带上界），刚还在屏幕上的页别被拆掉又重建（同 SwiftUI 版的两条教训）
            let merged = min(range.lowerBound, realized.lowerBound)...max(range.upperBound, realized.upperBound)
            if merged.count <= range.count + 8 { range = merged }
        } else {
            keepRange = max(0, range.lowerBound - keepMargin)...(range.upperBound + keepMargin)
        }
        if range != realized || !didRealize {
            didRealize = true
            realize(range, evict: !zooming)
            kickBaseRenders()
            if session.ocrEnabled { session.enqueueOCR(Array(range)) }
        }
        // 顶端页 → 当前页（程序化滚动 / 缩放期间停更，平板与进度依赖它）
        if !follower.isSuppressing, CACurrentMediaTime() >= suppressEmitUntil {
            let page = layout.locate(docY: topDocY).page
            if session.currentPageIndex != page { session.currentPageIndex = page }
        }
        return range
    }

    private func realize(_ range: ClosedRange<Int>, evict: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (i, g) in groups where !range.contains(i) {
            g.removeFromSuperlayer()
            g.reset()
            groups.removeValue(forKey: i)
            pool.append(g)
        }
        let strokes = session.visibleStrokesByPage(in: range)
        let live = session.liveStroke
        let m = marginDoc
        for i in range where groups[i] == nil {
            let g = pool.popLast() ?? PageLayerGroup()
            g.pageIndex = i
            g.paper.backgroundColor = paperColor
            g.place(frame: pageFrame(i), margin: m)
            g.image.contents = images[i]
            if let t = tiles[i] { g.setTile(t.normRect, image: t.image) }
            configureInkLayer(g.ink, strokes: strokes[i] ?? [])
            configureInkLayer(g.live, strokes: live.flatMap { $0.page == i ? [$0] : nil } ?? [])
            docView.layer?.addSublayer(g)
            groups[i] = g
        }
        realized = range
        if evict {
            for k in images.keys where !keepRange.contains(k) { releaseImage(page: k) }
            for k in tiles.keys where !range.contains(k) { tiles.removeValue(forKey: k) }
        }
        CATransaction.commit()
    }

    // MARK: 笔迹层

    /// 笔迹层的像素密度：屏幕倍率 × 缩放，封顶（一页笔迹位图最多约 1600 万像素 ≈ 64MB）。
    /// 更高倍率下笔迹会比页图略糊——整页一张位图的代价，真要清得换视口贴片那一套（记在方案风险里）。
    func inkContentsScale(for size: CGSize) -> CGFloat {
        let want = backingScale * max(1, zoom)
        let cap = (16_000_000 / max(1, size.width * size.height)).squareRoot()
        return max(1, min(want, cap))
    }

    func configureInkLayer(_ l: PageInkLayer, strokes: [InkStroke]) {
        let scale = inkContentsScale(for: l.bounds.size)
        var dirty = false
        if l.strokes != strokes { l.strokes = strokes; dirty = true }
        if abs(l.contentsScale - scale) > 0.01 { l.contentsScale = scale; dirty = true }
        if dirty {
            if strokes.isEmpty { l.contents = nil } else { l.setNeedsDisplay() }
        }
    }

    /// 会话笔迹变了（落笔收尾 / 擦除 / 平板上行 / 框选提交 / 按页窗口装卸）：只重画真的变了的页。
    func refreshInk() {
        guard didSetup, !groups.isEmpty else { return }
        let byPage = session.visibleStrokesByPage(in: realized)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (i, g) in groups { configureInkLayer(g.ink, strokes: byPage[i] ?? []) }
        CATransaction.commit()
    }

    /// 正在写的那一笔（平板 / 本机）：只重画它所在那一页的活体层。
    func refreshLive() {
        guard didSetup else { return }
        let live = session.liveStroke
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (i, g) in groups {
            let want: [InkStroke] = live.flatMap { $0.page == i ? [$0] : nil } ?? []
            if want.isEmpty && g.live.strokes.isEmpty { continue }
            g.live.strokes = want
            let scale = inkContentsScale(for: g.live.bounds.size)
            if abs(g.live.contentsScale - scale) > 0.01 { g.live.contentsScale = scale }
            if want.isEmpty { g.live.contents = nil } else { g.live.setNeedsDisplay() }
        }
        CATransaction.commit()
    }

    /// 缩放停下后：笔迹层按新倍率重画一次（由糊变清）。
    func refreshInkScale() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for g in groups.values {
            for l in [g.ink, g.live] where !l.strokes.isEmpty {
                let s = inkContentsScale(for: l.bounds.size)
                if abs(l.contentsScale - s) > 0.01 { l.contentsScale = s; l.setNeedsDisplay() }
            }
        }
        CATransaction.commit()
    }

    // MARK: 宽度变化（硬指标 3/4：不闪、不跳）

    /// 宽度变了（窗口 / AI 面板）。拖窗口期间冻结（结束时 `viewDidEndLiveResize` 一次处理）；
    /// 其余变化稳定 0.2s 后处理；刚出现的 1.5s 内（窗口帧恢复、分栏落位）不防抖，直接到位。
    func scheduleRefit() {
        guard didSetup else { return }
        refitWork?.cancel(); refitWork = nil
        if inLiveResize { return }
        if CACurrentMediaTime() - appearAt < 1.5 { refit(); return }
        let work = DispatchWorkItem { [weak self] in
            self?.refitWork = nil
            self?.refit()
        }
        refitWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }

    /// 按新宽度重定基准，顶部文档点钉住。fit 模式：页宽跟着新宽度走；缩放过：屏幕页宽不变。
    func refit() {
        guard let layout = pageLayout, didSetup else { return }
        let newFit = fitAvail
        lastFitAvail = newFit
        guard abs(newFit - fitBasis) > 0.5 else { return }
        let anchor = layout.locate(docY: topDocY)
        let hfrac = fitBasis > 0 ? max(0, clipView.bounds.minX) / fitBasis : 0
        let oldPageW = pageW
        let newZoom = userZoomed ? clampZoom(oldPageW / newFit) : 1
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fitBasis = newFit
        layoutDocument()
        scrollView.magnification = newZoom
        scroll(toPage: anchor.page, frac: anchor.frac, hfrac: userZoomed ? hfrac : 0)
        CATransaction.commit()
        suppressEmitUntil = CACurrentMediaTime() + 0.3
        updateRealized()
        scheduleSettle()
    }

    // MARK: 活跃窗口

    func activeWindowChanged() {
        guard didSetup, !isZooming else { return }
        updateRealized()
    }

    // MARK: 链接展开笔记（第 2 步接气泡）

    func revealNote(_ id: UUID?) {
        guard id != nil else { return }
        session.revealNoteID = nil
    }

    // MARK: 拆除

    /// 视图离开窗口（切标签 / 换文档 / 关窗）：放掉定时器与帧驱动，页图交回缓存、销账。幂等。
    func teardown() {
        guard !tornDown else { return }
        tornDown = true
        releaseRetainers()
        follower.reset()
        bag.removeAll()
        NotificationCenter.default.removeObserver(self)
        for o in observers { NotificationCenter.default.removeObserver(o) }
        observers.removeAll()
        PageHoldings.shared.remove(client: clientID)
        PageRenderEngine.shared.setWanted([], client: clientID)
        session.renderClients.removeValue(forKey: clientID)
        releaseRenderCache()
    }

    /// 放掉会长期持有本视图的东西（帧驱动、防抖任务）。`DocSession.teardown` 关窗时也会经 `renderClients` 调到。
    func releaseRetainers() {
        stopFrameLink()
        settleWork?.cancel(); settleWork = nil
        refitWork?.cancel(); refitWork = nil
    }
}

/// 命令式缩放动画的状态（⌘± / 工具栏 / ⌘0 / 1:1）：**log 空间匀速直线**，0.18s，连点只换目标不重置速度。
/// 🔴 不许加缓动（用户 2026-09-02 定：「就线性的就好了，不要弹性」，来龙去脉见 SwiftUI 版 `ZoomAnim` 注释）。
struct ZoomAnimState {
    var from: CGFloat
    var target: CGFloat
    var progress: CGFloat = 0
    var lastT: CFTimeInterval
    /// 锚点：文档坐标里的点 + 它在 clip view 里的视图位置（屏幕不动点）。
    var anchorDoc: NSPoint
    var anchorView: NSPoint
    /// 非 nil（⌘0）：到位后把 fit 基准重定为这个宽度、倍率归 1（屏幕页宽不变，零跳变）。
    var fitAfter: CGFloat?
}
