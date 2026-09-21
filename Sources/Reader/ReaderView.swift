import AppKit
import Combine
import PDFKit
import QuartzCore

/// 阅读区竖滚动条的几何打点。**默认关**（同 `wsLog` 的文件开关）：
/// ```
/// touch ~/Library/Logs/UniReader-scroller.log    # 开启
/// rm    ~/Library/Logs/UniReader-scroller.log    # 关闭
/// ```
/// 排「把右侧 Inspector 拖到最宽之后阅读区竖滚动条不见了」用：每个关口记一行完整几何，
/// 看得出滚动条是**被判定为不需要**（内容高 ≤ 视口）、**被摆到看不见的地方**（frame 在可见区之外），
/// 还是**根本没重排**（外框还是旧宽度、被 Inspector 盖住）。
enum ScrollerLog {
    static let url = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Logs/UniReader-scroller.log")

    static func write(_ s: String) {
        guard let h = try? FileHandle(forWritingTo: url) else { return }   // 文件不在 = 没开
        defer { try? h.close() }
        _ = try? h.seekToEnd()
        try? h.write(contentsOf: Data("\(Date.now.formatted(date: .omitted, time: .standard)) \(s)\n".utf8))
    }
}

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
    /// 右侧 Inspector 盖住的宽度（视图点）：页面适配到左边剩下的那块，外框不变（方案 §3.3）。
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

    /// **正在换基准 / 重排（半成品状态），此刻算出来的位置不作数**（2026-09-21 定，用户报「阅读进度跑到别的页」
    /// 的根因）：`refit` / `rebase` / `applyZoom` 都是「先按新基准重排文档视图、再把画面钉回原处」，
    /// 而改 `fitBasis`、`docView.frame`、`magnification` 每一步都会**同步**触发 clip view 的 bounds 通知 →
    /// `maybeEmit()` 拿**新基准**去解读**还没校正的旧滚动偏移**，算出一个离谱的页码当成「用户滚动到这里」
    /// 上报、存进库（实测 fit 1385→1085 那一次：真实 p88 被报成 p112，画面随后钉回 p88，库里那条错的没人纠正，
    /// 切走再回来就落在 p112）。
    ///
    /// 🔴 各处 `suppressEmitUntil` 是在**重排做完之后**才设的，挡不住这中间的自发上报，必须有这道门。
    var relayouting = false

    // MARK: 缩放

    var isLiveMagnifying = false
    var zoomAnim: ZoomAnimState?

    // MARK: 交互状态（第 2 步：选区 / 框选 / 笔记 / 截图……）

    /// 覆盖层：图钉、气泡、框选路径、橡皮圈等屏幕固定尺寸的东西（`ReaderOverlayView`）。
    let overlay = ReaderOverlayView()
    /// 文字选区（归一化逐页行框 + 原文）。镜像给 MCP（`session.currentSelection`），变了就重画涉及的页。
    var selection: TextSelection? { didSet { selectionChanged(from: oldValue) } }
    /// 框选（笔迹 / 注解）选中集与进行中的形态（文档坐标）。
    var lassoSelection: LassoSelection? { didSet { updateLassoOverlay() } }
    var lassoPath: [CGPoint]?
    var lassoGhostOffset: CGSize = .zero
    var lassoGhostScale: (sx: CGFloat, sy: CGFloat, handle: LassoHandle)?
    /// ⌘+拖框选文字的虚线框（文档坐标）与合并用的逐页命中（见 `+TextSelect`）。
    var boxSelectDrag: (start: CGPoint, current: CGPoint)?
    var boxSelectPages: [Int: [BoxSelectItem]] = [:]
    var boxSelectStrokeBase: [Int: [BoxSelectItem]] = [:]
    /// 点开着的 tap 模式笔记（瞬态、不落库）。
    var expandedNotes: Set<UUID> = [] { didSet { if oldValue != expandedNotes { layoutOverlay() } } }
    /// 指针悬停在哪枚图钉上（hover 模式的展开条件）。
    var hoveredNote: UUID? { didSet { if oldValue != hoveredNote { layoutOverlay() } } }
    /// 被点开的文字高亮（弹操作气泡用）。
    var activeHighlight: HighlightTap?
    var highlightPopover: NSPopover?
    /// 指针此刻在文档坐标里的位置（右键「在此……」、⌘V 落点用）。出了阅读区为 nil。
    var cursorDoc: CGPoint?
    /// 当前这次鼠标拖拽（按下时建，松手清）。
    var mouseTrack: MouseTrack?
    /// 搜索命中切换闪烁（0 → 1）。
    var matchPulseT: CGFloat = 1
    var matchPulseStart: CFTimeInterval = 0
    /// 截图框（文档坐标）与这次是不是 ⌥ 临时触发 / 存为图片笔记。
    var snipRect: (start: CGPoint, end: CGPoint)?
    var keyMonitor: Any?
    /// 当前弹着的编辑 sheet（批注 / 图片笔记 / 看大图）。
    var currentSheet: NSWindow?
    /// 拖进阅读区的**非图片**文件（PDF）交给窗口层入库。图片自己收成图片笔记。
    var onDropFiles: ([URL]) -> Void = { _ in }

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
        overlay.translatesAutoresizingMaskIntoConstraints = false
        addSubview(overlay)
        NSLayoutConstraint.activate([
            overlay.leadingAnchor.constraint(equalTo: leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: trailingAnchor),
            overlay.topAnchor.constraint(equalTo: topAnchor),
            overlay.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        docView.host = self
        follower.interpEnabled = interpEnabled
        installObservers()
        installInteraction()
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

    /// fit 可用宽（视图点）：滚动视图外框宽 − 左右内容内边距（右 = 叠在阅读区上的面板）
    /// − 常驻竖滚动条占掉的那一列 − 半点余量。与内容无关 → 不会互抬成环。
    ///
    /// 🔴 **不能拿 clip view 的实测宽来算**（2026-09-21 实测定，用户报「把右侧 Inspector 拖到最宽，
    /// 阅读区竖滚动条就没了，滚轮滚也不回来，而且不是每次都出现」）：clip 的宽度是 AppKit 摆放滚动条
    /// （tile）的**结果**，而页宽又是它的**输入**——两边互相追。fit 模式下页宽正好等于视口宽，横滚动条
    /// 就卡在「要不要出现」的边界上（日志里它一会儿显一会儿藏），而
    /// 「clip 占满整宽 + 页宽 = 整宽 + 竖条没有自己那一列」是个**自洽且稳定**的解：
    /// 不透明的页面正好盖在竖滚动条上，滑块其实一直好好的（`可用=true`、矩形也对），只是被压住了，
    /// 所以怎么滚都不会露出来。按外框算就与 tile 的结果无关，这个坏解也就不存在了。
    /// 排这类问题：`touch ~/Library/Logs/UniReader-scroller.log` 开 `ScrollerLog`。
    var fitAvail: CGFloat {
        let ci = scrollView.contentInsets
        var w = scrollView.frame.width - ci.left - ci.right
        // 常驻滚动条（系统设置「始终显示滚动条」或接了鼠标）实打实占掉一列；覆盖式是浮在内容上的，不占。
        if scrollView.scrollerStyle == .legacy {
            w -= NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy)
        }
        // 再留半点：页宽正好等于视口宽时，一个浮点零头就能把横滚动条顶出来。
        return max(1, w - 0.5)
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

    /// 第一页上方留白（视图点）：与页间距同宽，滚到顶时第一页不贴着工具栏下沿（Preview 同款，可以再往下拖一点）。
    static let topGap: CGFloat = PageLayout.gap

    func applyInsets() {
        let top = topInset + Self.topGap
        overlay.topOcclusion = topInset
        let ci = scrollView.contentInsets
        if ci.top != top || ci.right != panelInset || ci.left != 0 || ci.bottom != 0 {
            scrollView.contentInsets = NSEdgeInsets(top: top, left: 0, bottom: 0, right: panelInset)
        }
        // 🔴 竖滚动条排在工具栏**下方**（布局上让开，不是压在它底下：用户 2026-09-20），顶端正好抵住工具栏下沿。
        // `scrollerInsets` 是在 `contentInsets` **之上再内缩一次**：内容内边距已经把滚动条推到工具栏下面了，
        // 这里再写一遍工具栏高度就会多推一整个工具栏（实测滑块起点又低了 60pt）。只需把那点顶部留白抵掉。
        let scrollerTop = -Self.topGap
        let si = scrollView.scrollerInsets
        if si.top != scrollerTop || si.bottom != scrollerBottomInset {
            scrollView.scrollerInsets = NSEdgeInsets(top: scrollerTop, left: 0, bottom: scrollerBottomInset, right: 0)
        }
        needsLayout = true
        logScroller("内边距")
    }

    /// 打一行竖滚动条的几何（默认不开，见 `ScrollerLog`）。
    func logScroller(_ tag: String) {
        let ci = scrollView.contentInsets, si = scrollView.scrollerInsets
        let sc = scrollView.verticalScroller
        let hs = scrollView.horizontalScroller
        let viewport = scrollView.contentSize.height
        let content = docView.frame.height * scrollView.magnification
        // 竖滚动条在窗口坐标里的位置：看它是不是被摆到了可见区外 / Inspector 底下
        let inWin = sc.map { scrollView.convert($0.frame, from: $0.superview) } ?? .zero
        // 滑块矩形（滚动条自己的坐标）：轨道在、滑块没画出来的情况全看这一项
        let knob = sc?.rect(for: .knob) ?? .zero
        // 竖条在窗口坐标里的实际位置 + 没被祖先裁掉的那部分：看它是不是根本不在可见区里
        let scWin = sc.map { $0.convert($0.bounds, to: nil) } ?? .zero
        let scVis = sc?.visibleRect ?? .zero
        // 分栏各格在窗口坐标里的位置：拖分隔条时如果隔壁格压过界，就会正好盖住最右边那一列
        var panes = ""
        if let split = window?.contentViewController as? NSSplitViewController {
            panes = split.splitViewItems.map { item -> String in
                let f = item.viewController.view.convert(item.viewController.view.bounds, to: nil)
                return "\(item.isCollapsed ? "收" : "")[\(Int(f.minX))→\(Int(f.maxX))]"
            }.joined()
        }
        ScrollerLog.write("""
            \(tag) 本视图\(Int(bounds.width))×\(Int(bounds.height)) 滚动视图\(Int(scrollView.frame.width))×\
            \(Int(scrollView.frame.height)) 视口\(Int(scrollView.contentSize.width))×\(Int(viewport)) \
            内容\(Int(docView.frame.width))×\(Int(docView.frame.height)) 倍率\(String(format: "%.3f", scrollView.magnification)) \
            折算内容高\(Int(content)) 该有竖条=\(content > viewport + 0.5) \
            内边距[上\(Int(ci.top)) 右\(Int(ci.right))] 条内缩[上\(Int(si.top)) 下\(Int(si.bottom))] \
            fit基准\(Int(fitBasis)) 可用\(Int(fitAvail)) 上次可用\(Int(lastFitAvail)) \
            竖条\(sc == nil ? "无" : (sc!.isHidden ? "藏" : "显"))\
            α\(String(format: "%.2f", sc?.alphaValue ?? -1)) \
            框(\(Int(inWin.minX)),\(Int(inWin.minY)) \(Int(inWin.width))×\(Int(inWin.height))) \
            占比\(String(format: "%.3f", sc?.knobProportion ?? -1)) \
            可用=\(sc?.isEnabled.description ?? "-") 位置\(String(format: "%.3f", sc?.doubleValue ?? -1)) \
            滑块(\(Int(knob.minX)),\(Int(knob.minY)) \(Int(knob.width))×\(Int(knob.height))) \
            可用部件\(sc.map { String(describing: $0.usableParts.rawValue) } ?? "-") \
            横条\(hs == nil ? "无" : (hs!.isHidden ? "藏" : "显"))\(hs?.isEnabled == true ? "可用" : "禁用") \
            clip框(\(Int(clipView.frame.minX)),\(Int(clipView.frame.minY)) \(Int(clipView.frame.width))×\(Int(clipView.frame.height))) \
            竖条窗口x\(Int(scWin.minX))→\(Int(scWin.maxX)) 未被裁\(Int(scVis.width))×\(Int(scVis.height)) \
            分栏\(panes.isEmpty ? "-" : panes) \
            样式\(scrollView.scrollerStyle == .overlay ? "覆盖" : "常驻") 拖动中=\(inLiveResize) 已落位=\(didSetup)
            """)
    }

    // MARK: 布局

    override func layout() {
        super.layout()
        guard !tornDown else { return }
        if !didSetup {
            setupIfPossible()
            return
        }
        retileIfScrollersOverlapContent()
        let avail = fitAvail
        if abs(avail - lastFitAvail) > 0.5 {
            lastFitAvail = avail
            logScroller("摆位(可用宽变了)")
            scheduleRefit()
        }
    }

    /// 常驻滚动条与内容叠在一起时，把它们重新摆一次。
    ///
    /// 🔴 拖分隔条 / 拖窗口期间 AppKit **不保证**重新摆放滚动条（tile）：clip view 占满整宽、
    /// 常驻竖滚动条压在内容上面，而页面是不透明的，正好把它盖住——表现是**拖动过程中竖滚动条不见了、
    /// 松手才回来**（2026-09-21 实测：`clip框(0,0 1200×907)` 与 `竖条框(1183,52 17×838)` 叠着，
    /// 正常时 clip 是 `1183×890`；日志里有几帧它自己又 tile 了，所以时有时无）。
    /// 只在**确实叠上了**时叫一次 `tile()`：
    /// 🔴 覆盖式滚动条本来就浮在内容上（叠着是对的），也**不能**对它叫 `tile()`——会把布局搅乱
    /// （滑块变成一小块方块卡在角上，见 `AGENTS.md`），所以先按样式挡掉。
    private func retileIfScrollersOverlapContent() {
        guard scrollView.scrollerStyle == .legacy else { return }
        let content = clipView.frame
        let overlaps: (NSScroller?) -> Bool = { s in
            guard let s, !s.isHidden else { return false }
            return content.intersects(s.frame.insetBy(dx: 0.5, dy: 0.5))
        }
        guard overlaps(scrollView.verticalScroller) || overlaps(scrollView.horizontalScroller) else { return }
        scrollView.tile()
        logScroller("滚动条压着内容，重摆")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            teardown()
        } else {
            needsLayout = true
        }
    }

    override func viewWillStartLiveResize() {
        super.viewWillStartLiveResize()
        logScroller("拖动开始")
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        logScroller("拖动结束")
        refitNow()
        // 重排是同步的，但滚动条什么时候重判由 AppKit 定：半秒后再记一行「定局」
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.logScroller("定局") }
    }

    /// 跳过 `scheduleRefit` 的防抖，按当前宽度立刻重排（拖窗口结束、Inspector 开合收尾这类一次性动作）。
    func refitNow() {
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

        relayouting = true                       // 首次落位同样是「摆好之前不作数」（同 `refit`）
        defer { relayouting = false }
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
            ProgressLog.log("首帧 落到 \(ProgressLog.pos(a.page, a.frac)) 锚点=\(a.origin)#\(a.seq) "
                + String(format: "zoom=%.3f hfrac=%.3f fit=%.1f ", Double(z), Double(hfrac), Double(fitBasis))
                + "共\(lay.pageCount)页 \(ProgressLog.doc(session.documentId, session.title))")
        } else {
            scroll(toPage: 0, frac: 0, hfrac: 0)
            ProgressLog.log("首帧 没有锚点 → 回到 p1 顶端 "
                + String(format: "zoom=%.3f fit=%.1f ", Double(z), Double(fitBasis))
                + "共\(lay.pageCount)页 \(ProgressLog.doc(session.documentId, session.title))")
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
        var source = "现算"
        if let cached = session.cachedLayout {
            lay = cached
            source = "会话缓存"
        } else if let align {
            lay = PageLayout(heights: align.heights(refWidth: Double(PageLayout.refWidth)).map { CGFloat($0) })
            source = "对齐参数"
        } else if let hs = fromStore {
            lay = PageLayout(heights: hs.map { CGFloat($0) })
            source = "库里页高"
        } else {
            lay = session.openTrace.phase("布局计算", detail: "\(pdf.pageCount)页") { PageLayout(doc: pdf) }
            if let store = session.store, !session.contentHash.isEmpty {
                let hash = session.contentHash, hs = lay.heights.map { Double($0) }
                Task.detached(priority: .utility) { try? store.savePageHeights(contentHash: hash, heights: hs) }
            }
        }
        session.cachedLayout = lay
        // 页高来源对不上 PDF 的页数 = 位置换算的基准本身就是错的（比如缓存串到了上一篇），
        // 进度排查时第一眼要看的就是这条。
        ProgressLog.log("布局 来源=\(source) \(lay.pageCount)页(PDF \(pdf.pageCount)页)"
            + String(format: " 总高=%.0f ", Double(lay.totalHeight))
            + (lay.pageCount != pdf.pageCount ? "⚠️页数对不上 " : "")
            + ProgressLog.doc(session.documentId, session.title))
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
        layoutOverlay()
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
            refreshMarks()
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
        if inLiveResize { ScrollerLog.write("  重排推迟（拖动中，等拖动结束）"); return }
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
        guard abs(newFit - fitBasis) > 0.5 else {
            ScrollerLog.write("重排 跳过（可用宽 \(Int(newFit)) 与 fit 基准 \(Int(fitBasis)) 只差 \(String(format: "%.1f", Double(abs(newFit - fitBasis))))）")
            return
        }
        let anchor = layout.locate(docY: topDocY)
        let hfrac = fitBasis > 0 ? max(0, clipView.bounds.minX) / fitBasis : 0
        let oldPageW = pageW
        let oldFit = fitBasis
        let newZoom = userZoomed ? clampZoom(oldPageW / newFit) : 1
        relayouting = true                      // 🔴 半成品状态不许上报位置（见属性上的红线）
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fitBasis = newFit
        layoutDocument()
        scrollView.magnification = newZoom
        scroll(toPage: anchor.page, frac: anchor.frac, hfrac: userZoomed ? hfrac : 0)
        CATransaction.commit()
        relayouting = false
        lastEmitted = (anchor.page, anchor.frac)   // 位置没变（钉住的就是它），别让下一次去重/跳变判断错位
        ProgressLog.log("重排(宽度变了) 钉住 \(ProgressLog.pos(anchor.page, anchor.frac)) "
            + String(format: "fit %.1f→%.1f zoom=%.3f 缩放过=%@ ", Double(oldFit),
                     Double(newFit), Double(newZoom), userZoomed ? "是" : "否")
            + ProgressLog.doc(session.documentId, session.title))
        suppressEmitUntil = CACurrentMediaTime() + 0.3
        updateRealized()
        scheduleSettle()
        logScroller("重排后")
    }

    // MARK: 活跃窗口

    func activeWindowChanged() {
        guard didSetup, !isZooming else { return }
        updateRealized()
    }

    // MARK: 链接展开笔记

    /// `unireader://open?note=…` 要求展开某条笔记的气泡（`DocSession.revealNoteID`）。取走即清。
    func revealNote(_ id: UUID?) {
        guard let id else { return }
        expandedNotes.insert(id)
        session.revealNoteID = nil
    }

    // MARK: 拆除

    /// 视图离开窗口（切标签 / 换文档 / 关窗）：放掉定时器与帧驱动，页图交回缓存、销账。幂等。
    func teardown() {
        guard !tornDown else { return }
        tornDown = true
        ProgressLog.log("阅读区拆除 最后上报=\(lastEmitted.map { ProgressLog.pos($0.page, $0.frac) } ?? "无") "
            + "会话锚点=\(session.scrollAnchor.map { "\($0.origin)#\($0.seq) \(ProgressLog.pos($0.page, $0.frac))" } ?? "无") "
            + ProgressLog.doc(session.documentId, session.title))
        releaseRetainers()
        removeKeyMonitor()
        dismissHighlightPopover()
        dismissSheet()
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
