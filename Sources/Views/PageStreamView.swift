import SwiftUI
import PDFKit
import QuartzCore
import AppKit   // 仅 NSEvent 滚轮监视器（事件管道）；阅读区无 AppKit 视图（红线）

/// 自研 PDF 阅读区 v2：纯 SwiftUI 页图流（设计与硬指标映射见 `PDF-VIEWER-REBUILD-PLAN.md`）。
/// 关键机制（均由 spike 实测钉死）：
///  · 同一 runloop 周期内「改布局 + scrollTo」= 同一次 CA commit = 屏幕原子（atomic-commit-probe）
///  · scrollTo 语义 = contentOffset 直接赋值；**单轴 scrollTo(x:)/(y:) 禁用**——后写覆盖前写、
///    且会把未指定轴重置为 0（scroll-x-probe T1/T4），一律 `scrollTo(point:)` 两轴同写
///  · 自研虚拟化（精确内容尺寸，不用 LazyVStack 估算）→ 滚动条/scrollTo 永不漂移
///  · pinch 双向都逐帧真 commit（锚定捏合点）：滚动条在内容超容器瞬间即现，无松手悬崖
///  · 主线程零渲染：`PageRenderEngine` 后台出图，缓存命中同步取，图只被替换不清空
struct PageStreamView: View {
    @ObservedObject var session: DocSession
    let docKey: String
    let nightMode: Bool
    let interpEnabled: Bool
    let isActiveWindow: Bool

    var body: some View {
        GeometryReader { geo in
            ReaderSurface(session: session,
                          docKey: docKey.isEmpty ? "untitled" : docKey,
                          nightMode: nightMode,
                          interpEnabled: interpEnabled,
                          isActiveWindow: isActiveWindow,
                          unobSize: geo.size)
                .ignoresSafeArea()
        }
        .id(docKey)   // 换文档 = 全新阅读状态
    }
}

extension Notification.Name {
    static let readerZoomIn = Notification.Name("com.xvan.UniReader.readerZoomIn")
    static let readerZoomOut = Notification.Name("com.xvan.UniReader.readerZoomOut")
    static let readerZoomFit = Notification.Name("com.xvan.UniReader.readerZoomFit")
}

// MARK: - 内部实现

/// 滚动几何快照（只存标量，Equatable 供 onScrollGeometryChange 去重）。
private struct GeoSnap: Equatable {
    var offsetX: CGFloat = 0, offsetY: CGFloat = 0
    var containerW: CGFloat = 0, containerH: CGFloat = 0
    var contentW: CGFloat = 0, contentH: CGFloat = 0
    var insetTop: CGFloat = 0, insetLeading: CGFloat = 0
    var insetBottom: CGFloat = 0, insetTrailing: CGFloat = 0
}

/// 高倍清晰贴片：normRect = 页内归一化区域（0~1，左上原点）→ 显示时 × 页尺寸，随缩放拉伸。
private struct PageTile: Equatable {
    var normRect: CGRect
    var image: CGImage
}

/// 捏合手势状态。锚点数学：屏幕不动点 P（相对容器原点）+ 内容锚点 c；
/// 逐帧 commit：c' = c×r，目标偏移 = c' − P（同 runloop 提交 = 屏幕原子，scroll-x-probe T3b）。
/// 放大/缩小都走真 commit：滚动条在内容超过容器的瞬间即出现（Preview 同款），无松手悬崖。
private struct PinchInfo {
    var startZoom: CGFloat
    var viewportP: CGPoint     // 锚点相对容器原点（屏幕不动点）
    var cCur: CGPoint          // 当前布局下的锚点内容坐标（每次 commit 后更新）
}

/// 每帧变化但不应触发 body 重算的暂存（引用类型，@State 持有其身份）。
private final class Scratch {
    var geo = GeoSnap()
    var topDocY: CGFloat = 0
    var basePixelW = 0
    var lastEmitAt: CFTimeInterval = 0
    var lastEmitted: (page: Int, frac: Double)?
    var suppressEmitUntil: CFTimeInterval = 0
    var pendingTarget: CGPoint?
    var pendingTries = 0
    var settleWork: DispatchWorkItem?
    var resizeWork: DispatchWorkItem?
    var pinch: PinchInfo?
    var pendingRestore: ScrollAnchor?
    var lastUnobW: CGFloat = 0
    var didInitialGeo = false
    var didFirstKick = false
    var cursorP: CGPoint?              // 光标在滚动容器坐标里的位置（⌘wheel 缩放锚点；域外为 nil）
    var wheelMonitor: Any?             // ⌘+滚轮的 NSEvent 本地监视器（事件管道，非视图）
    let clientID = UUID().uuidString   // 渲染引擎多窗口 wanted 隔离键
}

private struct ReaderSurface: View {
    @ObservedObject var session: DocSession
    let docKey: String
    let nightMode: Bool
    let interpEnabled: Bool
    let isActiveWindow: Bool
    let unobSize: CGSize          // 未遮视口尺寸（fit 基准；GeometryReader 提供）

    @Environment(\.displayScale) private var displayScale

    // 布局/缩放状态
    @State private var layout: PageLayout?
    @State private var zoom: CGFloat = 1          // 1 = fit-width（相对 fitBasis）
    @State private var fitBasis: CGFloat = 0      // fit 基准宽（pt）；resize settle 时重定标
    @State private var userZoomed = false
    // 滚动
    @State private var pos = ScrollPosition()
    // 视图数据
    @State private var realized: ClosedRange<Int> = 0...0
    @State private var images: [Int: CGImage] = [:]
    @State private var tiles: [Int: PageTile] = [:]
    // 跟随
    @StateObject private var follower = ScrollFollower()
    @State private var lastAppliedSeq = 0
    // 非渲染暂存
    @State private var scratch = Scratch()

    private let zoomMin: CGFloat = 0.25
    private let zoomMax: CGFloat = 6
    private let basePixelCap = 2800               // 整页基图像素宽上限；超出由贴片补清晰

    // MARK: 布局换算

    private var basis: CGFloat { fitBasis > 0 ? fitBasis : max(1, unobSize.width) }
    private var pageW: CGFloat { basis * zoom }
    private var dispScale: CGFloat { pageW / PageLayout.refWidth }
    private var contentW: CGFloat { max(unobSize.width, pageW) }
    private var contentH: CGFloat { (layout?.totalHeight ?? 1) * dispScale }
    private var pageX: CGFloat { (contentW - pageW) / 2 }
    private var paper: Color { nightMode ? Color(white: 0.10) : .white }

    var body: some View {
        ScrollView([.vertical, .horizontal]) {
            contentBody
        }
        .scrollPosition($pos)
        .onScrollGeometryChange(for: GeoSnap.self) { g in
            GeoSnap(offsetX: g.contentOffset.x, offsetY: g.contentOffset.y,
                    containerW: g.containerSize.width, containerH: g.containerSize.height,
                    contentW: g.contentSize.width, contentH: g.contentSize.height,
                    insetTop: g.contentInsets.top, insetLeading: g.contentInsets.leading,
                    insetBottom: g.contentInsets.bottom, insetTrailing: g.contentInsets.trailing)
        } action: { _, new in
            geometryChanged(new)
        }
        .onContinuousHover(coordinateSpace: .local) { phase in
            switch phase {
            case .active(let p): scratch.cursorP = p
            case .ended: scratch.cursorP = nil
            }
        }
        .overlay(alignment: .topLeading) { followTicker }
        .onChange(of: session.scrollAnchor) { _, a in incomingAnchor(a) }
        .onChange(of: unobSize.width) { _, _ in viewportWidthChanged() }
        .onChange(of: nightMode) { _, _ in scheduleSettleRender() }
        .onChange(of: interpEnabled) { _, v in follower.interpEnabled = v }
        .onAppear {
            setup()
            installWheelMonitor()
        }
        .onDisappear {
            follower.reset()
            removeWheelMonitor()
            PageRenderEngine.shared.setWanted([], client: scratch.clientID)
        }
        .onReceive(NotificationCenter.default.publisher(for: .readerZoomIn)) { _ in
            if isActiveWindow { commandZoom(factor: 1.25) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .readerZoomOut)) { _ in
            if isActiveWindow { commandZoom(factor: 1 / 1.25) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .readerZoomFit)) { _ in
            if isActiveWindow { commandZoomFit() }
        }
    }

    // MARK: 内容（自研虚拟化：精确总尺寸 + 只实化窗口内页）

    @ViewBuilder private var contentBody: some View {
        if let layout {
            ZStack(alignment: .topLeading) {
                ForEach(Array(realized), id: \.self) { i in
                    PageCellView(size: CGSize(width: pageW, height: layout.heights[i] * dispScale),
                                 image: images[i],
                                 tile: tiles[i],
                                 paper: paper,
                                 strokes: session.strokes.filter { $0.page == i },
                                 live: session.liveStroke?.page == i ? session.liveStroke : nil,
                                 hover: session.hover?.page == i ? session.hover : nil,
                                 inkScale: zoom)
                        .offset(x: pageX, y: layout.offsets[i] * dispScale)
                }
            }
            .frame(width: contentW, height: contentH, alignment: .topLeading)
            .simultaneousGesture(magnify)
            .transaction { $0.animation = nil }   // 零闪烁纪律 4：阅读区无隐式动画
        } else {
            Color.clear.frame(width: 10, height: 10)
        }
    }

    /// 跟随器帧驱动（仅激活期间挂载；TimelineView(.animation) 与刷新率同步）。
    @ViewBuilder private var followTicker: some View {
        if follower.isActive {
            TimelineView(.animation) { tl in
                Color.clear
                    .frame(width: 1, height: 1)
                    .onChange(of: tl.date) { _, _ in followStep() }
            }
            .allowsHitTesting(false)
        }
    }

    // MARK: 生命周期

    private func setup() {
        guard let pdf = session.pdf else { return }
        let lay = PageLayout(doc: pdf)
        layout = lay
        follower.pageCount = lay.pageCount
        follower.interpEnabled = interpEnabled
        if fitBasis == 0 { fitBasis = max(1, unobSize.width) }
        scratch.lastUnobW = unobSize.width
        // 视图创建前就已发出的 restore/toc 锚点（loadSelected 先 emit 后建视图）
        if let a = session.scrollAnchor, a.origin != "mac" {
            scratch.pendingRestore = a
            lastAppliedSeq = a.seq
        }
    }

    // MARK: 滚动几何（锚点上报 / 实化窗口 / commit 校验）

    private func geometryChanged(_ n: GeoSnap) {
        scratch.geo = n
        guard let layout else { return }
        if !scratch.didInitialGeo, n.containerW > 0 {
            scratch.didInitialGeo = true
            if fitBasis == 0 { fitBasis = max(1, unobSize.width) }
            scratch.lastUnobW = unobSize.width
        }
        verifyPendingTarget(n)
        scratch.topDocY = (n.offsetY + n.insetTop) / max(0.0001, dispScale)
        updateRealized(n, layout: layout)
        if let a = scratch.pendingRestore {
            scratch.pendingRestore = nil
            follower.pageCount = layout.pageCount
            follower.apply(a)
        }
        maybeEmit(n, layout: layout)
        scheduleSettleRender()
    }

    /// commit 校验环：同 runloop 原子提交已由 spike 证实；此处兜底（万一被夹取/竞争）。
    private func verifyPendingTarget(_ n: GeoSnap) {
        guard let t = scratch.pendingTarget else { return }
        if abs(n.offsetX - t.x) <= 1, abs(n.offsetY - t.y) <= 1 {
            scratch.pendingTarget = nil
        } else if scratch.pendingTries < 5 {
            scratch.pendingTries += 1
            pos.scrollTo(point: t)   // ⚠️ 单轴 scrollTo(x:)/(y:) 是后写覆盖+重置另一轴（scroll-x-probe T1/T4），全文件禁用
        } else {
            scratch.pendingTarget = nil
            NSLog("[Reader] commit 目标未达 Δ=(%.1f, %.1f)", n.offsetX - t.x, n.offsetY - t.y)
        }
    }

    private func updateRealized(_ n: GeoSnap, layout: PageLayout) {
        let ds = max(0.0001, dispScale)
        let buffer = n.containerH / ds                    // 上下各约一屏预实化
        let top = n.offsetY / ds - buffer
        let bottom = (n.offsetY + n.containerH) / ds + buffer
        let range = layout.pageRange(fromDocY: top, toDocY: bottom)
        if range != realized || !scratch.didFirstKick {
            scratch.didFirstKick = true
            realized = range
            var evict = [Int]()
            for k in images.keys where k < range.lowerBound - 2 || k > range.upperBound + 2 { evict.append(k) }
            for k in evict { images.removeValue(forKey: k) }
            for k in tiles.keys where !(range ~= k) { tiles.removeValue(forKey: k) }
            kickBaseRenders()
        }
        // 顶端页 → currentPageIndex（非程序化滚动期间；平板/进度依赖它）
        if !follower.isSuppressing, CACurrentMediaTime() >= scratch.suppressEmitUntil {
            let page = layout.locate(docY: scratch.topDocY).page
            if session.currentPageIndex != page { session.currentPageIndex = page }
        }
    }

    private func maybeEmit(_ n: GeoSnap, layout: PageLayout) {
        let now = CACurrentMediaTime()
        guard !follower.isSuppressing,
              now >= scratch.suppressEmitUntil,
              scratch.pendingTarget == nil,
              now - scratch.lastEmitAt >= 1.0 / 120 else { return }
        let (page, frac) = layout.locate(docY: scratch.topDocY)
        if let last = scratch.lastEmitted, last.page == page, abs(last.frac - frac) < 0.0005 { return }
        scratch.lastEmitAt = now
        scratch.lastEmitted = (page, frac)
        session.emitAnchor(page: page, frac: frac, origin: "mac")
    }

    // MARK: 渲染调度（硬指标 1/2：后台出图 + 预缓存；纪律 1/2：白纸占位、只替换）

    private func currentBaseWidth() -> Int {
        min(basePixelCap, max(200, Int((pageW * displayScale).rounded())))
    }

    private func baseKey(_ page: Int, width: Int) -> String {
        PageRenderEngine.baseKey(doc: docKey, page: page, pixelWidth: width, night: nightMode)
    }

    /// 实化窗口变化时：为缺图页出图（缓存命中同步取 → 无 pop-in）。
    private func kickBaseRenders() {
        guard let pdf = session.pdf else { return }
        if scratch.basePixelW == 0 { scratch.basePixelW = currentBaseWidth() }
        let w = scratch.basePixelW
        var wanted = Set<String>()
        for i in realized {
            let key = baseKey(i, width: w)
            wanted.insert(key)
            if images[i] == nil, let hit = PageRenderEngine.shared.cached(key) {
                images[i] = hit
                continue
            }
            guard images[i] == nil, let page = pdf.page(at: i) else { continue }
            requestBase(key: key, page: page, index: i, width: w)
        }
        for t in tiles { wanted.insert(tileKeyFor(page: t.key, normRect: t.value.normRect)) }
        PageRenderEngine.shared.setWanted(wanted, client: scratch.clientID)
    }

    /// settle（滚动/缩放/夜间稳定 0.15s）后：按精确宽重渲可见窗口 + 刷新贴片。
    private func scheduleSettleRender() {
        scratch.settleWork?.cancel()
        let work = DispatchWorkItem { settleRender() }
        scratch.settleWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    private func settleRender() {
        guard let layout, let pdf = session.pdf, scratch.didInitialGeo else { return }
        scratch.basePixelW = currentBaseWidth()
        let w = scratch.basePixelW
        var wanted = Set<String>()
        for i in realized {
            guard let page = pdf.page(at: i) else { continue }
            let key = baseKey(i, width: w)
            wanted.insert(key)
            if let hit = PageRenderEngine.shared.cached(key) {
                if images[i] !== hit { images[i] = hit }
            } else {
                requestBase(key: key, page: page, index: i, width: w)
            }
        }
        wanted.formUnion(refreshTiles(layout: layout, pdf: pdf))
        PageRenderEngine.shared.setWanted(wanted, client: scratch.clientID)
    }

    private func requestBase(key: String, page: PDFPage, index: Int, width: Int) {
        PageRenderEngine.shared.request(.init(key: key, page: page, pixelWidth: width,
                                              tileRect: nil, tileScale: 1, night: nightMode)) { doneKey, img in
            // 只替换（纪律 2）：仍无图 → 直接用；有图 → 仅当仍是当前期望键才替换
            if images[index] == nil || doneKey == baseKey(index, width: scratch.basePixelW) {
                images[index] = img
            }
        }
    }

    // MARK: 高倍清晰贴片（基图上限之外由视口贴片补清晰；只在 settle 后刷新，替换式更新）

    private func tileKeyFor(page: Int, normRect: CGRect) -> String {
        PageRenderEngine.tileKey(doc: docKey, page: page, normRect: normRect,
                                 scale: displayScale, night: nightMode)
    }

    private func refreshTiles(layout: PageLayout, pdf: PDFDocument) -> Set<String> {
        var wanted = Set<String>()
        let needTiles = pageW * displayScale > CGFloat(basePixelCap) + 1
        guard needTiles else {
            if !tiles.isEmpty { tiles = [:] }   // 基图已够清晰，贴片移除不产生视觉变化
            return wanted
        }
        let g = scratch.geo
        let ds = max(0.0001, dispScale)
        let visTop = g.offsetY / ds, visBottom = (g.offsetY + g.containerH) / ds
        for i in layout.pageRange(fromDocY: visTop, toDocY: visBottom) {
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
                                                  tileRect: sub, tileScale: scale, night: nightMode)) { doneKey, img in
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

    // MARK: 缩放（硬指标 3/4：锚定捏合点，不跳位、不闪烁）

    private func clampZoom(_ z: CGFloat) -> CGFloat { min(max(z, zoomMin), zoomMax) }

    /// 目标偏移夹取（用给定显示页宽下的内容尺寸）。
    private func clampOffset(_ o: CGPoint, pageWidth pw: CGFloat) -> CGPoint {
        guard let layout else { return o }
        let g = scratch.geo
        let cw = max(unobSize.width, pw)
        let ch = layout.totalHeight * pw / PageLayout.refWidth
        let minX = -g.insetLeading
        let maxX = max(minX, cw - g.containerW + g.insetTrailing)
        let minY = -g.insetTop
        let maxY = max(minY, ch - g.containerH + g.insetBottom)
        return CGPoint(x: min(max(o.x, minX), maxX), y: min(max(o.y, minY), maxY))
    }

    private var magnify: some Gesture {
        MagnifyGesture()
            .onChanged { v in pinchChanged(v) }
            .onEnded { _ in pinchEnded() }
    }

    private func pinchChanged(_ v: MagnifyGesture.Value) {
        guard layout != nil, scratch.didInitialGeo else { return }
        if scratch.pinch == nil {
            follower.reset()                                   // 用户接管
            let g = scratch.geo
            let c = v.startLocation                            // 内容坐标（手势挂在 content 上）
            scratch.pinch = PinchInfo(startZoom: zoom,
                                      viewportP: CGPoint(x: c.x - g.offsetX, y: c.y - g.offsetY),
                                      cCur: c)
            scratch.suppressEmitUntil = CACurrentMediaTime() + 0.3
        }
        guard var p = scratch.pinch else { return }
        let m = max(0.05, v.magnification)
        commitZoom(to: clampZoom(p.startZoom * m), pinch: &p)  // 逐帧真 commit（两方向统一）
        scratch.pinch = p
        scratch.suppressEmitUntil = CACurrentMediaTime() + 0.3
    }

    private func pinchEnded() {
        guard scratch.pinch != nil else { return }
        scratch.pinch = nil
        scratch.suppressEmitUntil = CACurrentMediaTime() + 0.3
        scheduleSettleRender()
    }

    /// 原子缩放提交：布局（zoom）与偏移（scrollTo）同 runloop 写入 = 同一次 CA commit。
    private func commitZoom(to z1raw: CGFloat, pinch p: inout PinchInfo) {
        let z0 = zoom
        let z1 = clampZoom(z1raw)
        guard abs(z1 - z0) > 0.0001 else { return }
        let r = z1 / z0
        let c1 = CGPoint(x: p.cCur.x * r, y: p.cCur.y * r)
        let target = clampOffset(CGPoint(x: c1.x - p.viewportP.x, y: c1.y - p.viewportP.y),
                                 pageWidth: basis * z1)
        var t = Transaction(); t.animation = nil
        withTransaction(t) {
            zoom = z1
            userZoomed = true
            pos.scrollTo(point: target)
        }
        p.cCur = c1
        scratch.pendingTarget = target
        scratch.pendingTries = 0
        scratch.suppressEmitUntil = CACurrentMediaTime() + 0.3
    }

    /// 以容器坐标 anchorP 为屏幕不动点做单次缩放 commit（⌘±/⌘wheel 共用）。
    private func zoomCommit(factor: CGFloat, anchorP P: CGPoint) {
        guard layout != nil, scratch.didInitialGeo else { return }
        follower.reset()
        let g = scratch.geo
        let c = CGPoint(x: g.offsetX + P.x, y: g.offsetY + P.y)
        var p = PinchInfo(startZoom: zoom, viewportP: P, cCur: c)
        commitZoom(to: clampZoom(zoom * factor), pinch: &p)
        scheduleSettleRender()
    }

    /// ⌘+/⌘−：未遮视口中心为锚。
    private func commandZoom(factor: CGFloat) {
        let g = scratch.geo
        let P = CGPoint(x: g.insetLeading + (g.containerW - g.insetLeading - g.insetTrailing) / 2,
                        y: g.insetTop + (g.containerH - g.insetTop - g.insetBottom) / 2)
        zoomCommit(factor: factor, anchorP: P)
    }

    // MARK: ⌘+滚轮缩放（光标为锚；系统缩放同向：自然滚动下两指上滑/滚轮向上 = 放大）
    // SwiftUI 无滚轮 API → NSEvent 本地监视器（纯事件管道，无 AppKit 视图）。
    // 只在「⌘按住 + 光标在本阅读区内 + 非动量惯性 + 无进行中 pinch」时消费事件，其余原样放行。

    private func installWheelMonitor() {
        guard scratch.wheelMonitor == nil else { return }
        scratch.wheelMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            guard event.modifierFlags.contains(.command),
                  event.momentumPhase == [],
                  let p = scratch.cursorP,
                  layout != nil, scratch.didInitialGeo, scratch.pinch == nil else { return event }
            var delta = event.scrollingDeltaY
            if !event.hasPreciseScrollingDeltas { delta *= 10 }   // 有级滚轮（行单位）放大到像素量级
            guard delta != 0 else { return nil }
            let factor = min(max(exp(-delta * 0.008), 0.5), 2)    // 手感旋钮：0.008；负号=系统缩放方向约定
            zoomCommit(factor: factor, anchorP: p)
            return nil   // 消费：⌘滚轮不再触发滚动
        }
    }

    private func removeWheelMonitor() {
        if let m = scratch.wheelMonitor {
            NSEvent.removeMonitor(m)
            scratch.wheelMonitor = nil
        }
    }

    /// ⌘0：回 fit-width（基准重定标到当前未遮宽），未遮视口中心为锚。
    private func commandZoomFit() {
        guard layout != nil, scratch.didInitialGeo else { return }
        let g = scratch.geo
        let newBasis = max(1, unobSize.width)
        let r = newBasis / pageW
        let P = CGPoint(x: g.insetLeading + (g.containerW - g.insetLeading - g.insetTrailing) / 2,
                        y: g.insetTop + (g.containerH - g.insetTop - g.insetBottom) / 2)
        let c = CGPoint(x: g.offsetX + P.x, y: g.offsetY + P.y)
        let target = clampOffset(CGPoint(x: c.x * r - P.x, y: c.y * r - P.y), pageWidth: newBasis)
        var t = Transaction(); t.animation = nil
        withTransaction(t) {
            fitBasis = newBasis
            zoom = 1
            userZoomed = false
            pos.scrollTo(point: target)
        }
        scratch.pendingTarget = target
        scratch.pendingTries = 0
        scratch.suppressEmitUntil = CACurrentMediaTime() + 0.3
        scheduleSettleRender()
    }

    // MARK: 窗口/侧栏宽度变化（硬指标 3/4：resize 不闪、不跳）
    // 拖动期间布局冻结（页尺寸不变 → 纵向绝对稳定；水平居中随容器平滑跟随）；
    // 稳定 0.2s 后单次原子锚定 refit（fit 模式贴合新宽；手动缩放态只重定标基准，零视觉变化）。

    private func viewportWidthChanged() {
        guard scratch.didInitialGeo, unobSize.width > 0,
              abs(unobSize.width - scratch.lastUnobW) > 0.5 else { return }
        scratch.resizeWork?.cancel()
        let work = DispatchWorkItem { refitToViewport() }
        scratch.resizeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }

    private func refitToViewport() {
        guard layout != nil, scratch.didInitialGeo else { return }
        let newW = max(1, unobSize.width)
        scratch.lastUnobW = newW
        if userZoomed {
            // 绝对尺寸保持（Preview 同款）：显示页宽不变，仅重定标 fit 基准 → 零视觉变化
            let eff = pageW
            var t = Transaction(); t.animation = nil
            withTransaction(t) {
                fitBasis = newW
                zoom = min(max(eff / newW, zoomMin), zoomMax)
            }
        } else {
            // fit 模式：单次原子锚定 refit（顶部文档点钉住）
            let g = scratch.geo
            let r = newW / pageW
            let topDispY = g.offsetY + g.insetTop
            let target = clampOffset(CGPoint(x: -g.insetLeading, y: topDispY * r - g.insetTop),
                                     pageWidth: newW)
            var t = Transaction(); t.animation = nil
            withTransaction(t) {
                fitBasis = newW
                zoom = 1
                pos.scrollTo(point: target)
            }
            scratch.pendingTarget = target
            scratch.pendingTries = 0
            scratch.suppressEmitUntil = CACurrentMediaTime() + 0.3
        }
        scheduleSettleRender()
    }

    // MARK: 锚点接收 / 跟随

    private func incomingAnchor(_ a: ScrollAnchor?) {
        guard let a, a.origin != "mac", a.seq > lastAppliedSeq else { return }
        lastAppliedSeq = a.seq
        guard let layout, scratch.didInitialGeo else {
            scratch.pendingRestore = a
            return
        }
        follower.pageCount = layout.pageCount
        follower.interpEnabled = interpEnabled
        follower.apply(a)
    }

    private func followStep() {
        guard let layout else { follower.reset(); return }
        guard let prog = follower.step(now: CACurrentMediaTime()) else { return }
        let y = layout.docY(progress: prog) * dispScale - scratch.geo.insetTop
        // 只驱动 y，x 显式带当前值（单轴 scrollTo 会把另一轴重置为 0——scroll-x-probe T4）
        let clamped = clampOffset(CGPoint(x: scratch.geo.offsetX, y: y), pageWidth: pageW)
        pos.scrollTo(point: clamped)
    }
}

// MARK: - 页元胞（白纸底 + 基图 + 贴片 + 墨迹 + hover）

private struct PageCellView: View {
    let size: CGSize
    let image: CGImage?
    let tile: PageTile?
    let paper: Color
    let strokes: [InkStroke]
    let live: InkStroke?
    let hover: HoverPoint?
    let inkScale: CGFloat   // = zoom：墨迹线宽随页缩放（fit 时与采集端观感一致）

    var body: some View {
        ZStack(alignment: .topLeading) {
            paper                                        // 纪律 1：未出图 = 一张白纸，永不闪灰/黑
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: size.width, height: size.height)
            }
            if let tile {
                Image(decorative: tile.image, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: tile.normRect.width * size.width,
                           height: tile.normRect.height * size.height)
                    .offset(x: tile.normRect.minX * size.width,
                            y: tile.normRect.minY * size.height)
            }
            if !strokes.isEmpty || live != nil {
                Canvas { ctx, sz in
                    for st in strokes { drawStroke(st, in: &ctx, size: sz) }
                    if let live { drawStroke(live, in: &ctx, size: sz) }
                }
                .allowsHitTesting(false)
            }
            if let hover {
                Circle()
                    .stroke(Color.accentColor, lineWidth: 2)
                    .frame(width: 14, height: 14)
                    .position(x: hover.nx * size.width, y: hover.ny * size.height)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: size.width, height: size.height)
    }

    /// 二次贝塞尔中点平滑 + 压感变宽（与 SimPad.drawStroke 同数学；墨迹不随夜间反色）。
    private func drawStroke(_ st: InkStroke, in ctx: inout GraphicsContext, size: CGSize) {
        guard !st.points.isEmpty else { return }
        let color = Color(red: st.color.r / 255, green: st.color.g / 255, blue: st.color.b / 255,
                          opacity: st.color.a)
        let pts = st.points.map { CGPoint(x: $0.x * size.width, y: $0.y * size.height) }
        if pts.count == 1 {
            let r = (0.6 + st.points[0].z * st.width) * inkScale / 2
            ctx.fill(Path(ellipseIn: CGRect(x: pts[0].x - r, y: pts[0].y - r, width: r * 2, height: r * 2)),
                     with: .color(color))
            return
        }
        var lastMid = pts[0]
        var lastPt = pts[0]
        for i in 1..<pts.count {
            let mid = CGPoint(x: (lastPt.x + pts[i].x) / 2, y: (lastPt.y + pts[i].y) / 2)
            var p = Path()
            p.move(to: lastMid)
            p.addQuadCurve(to: mid, control: lastPt)
            ctx.stroke(p, with: .color(color),
                       style: StrokeStyle(lineWidth: (0.6 + st.points[i].z * st.width) * inkScale,
                                          lineCap: .round, lineJoin: .round))
            lastMid = mid
            lastPt = pts[i]
        }
    }
}
