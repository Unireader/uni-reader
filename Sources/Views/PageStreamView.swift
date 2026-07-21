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

    /// 全宽（含侧栏/Inspector 玻璃下延伸区）。与未遮宽对比可区分「窗口缩放」vs「侧栏开合」。
    @State private var fullWidth: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            let _ = NSLog("[RD] outerGeo size=%.1fx%.1f safeArea L%.1f R%.1f T%.1f B%.1f fullW=%.1f",
                          geo.size.width, geo.size.height,
                          geo.safeAreaInsets.leading, geo.safeAreaInsets.trailing,
                          geo.safeAreaInsets.top, geo.safeAreaInsets.bottom, fullWidth)
            ReaderSurface(session: session,
                          docKey: docKey.isEmpty ? "untitled" : docKey,
                          nightMode: nightMode,
                          interpEnabled: interpEnabled,
                          isActiveWindow: isActiveWindow,
                          unobSize: geo.size,
                          fullWidth: fullWidth,
                          indicatorTopInset: geo.safeAreaInsets.top)
                .ignoresSafeArea()
        }
        .background {
            GeometryReader { g in
                Color.clear
                    .onAppear { fullWidth = g.size.width }
                    .onChange(of: g.size.width) { _, w in fullWidth = w }
            }
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

/// 一次文字选择的结果（T1）：逐页归一化行框（画高亮）+ 选中纯文本（⌘C 复制）。
/// 归一化 0~1 左上原点 → 随页尺寸自适应，缩放/滚动免重算；由 PDFKit 原生选择引擎产出（视觉阅读顺序）。
private struct TextSelection: Equatable {
    var rects: [Int: [CGRect]]   // page → 该页归一化行框
    var text: String
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
    var lastRefitFullW: CGFloat = 0        // 上次 refit 时的全宽（区分窗口缩放 vs 侧栏/Inspector 开合）
    var appearAt: CFTimeInterval = 0       // 视图出现时刻：启动稳定窗内宽度变化一律真 fit（防瞬态宽被锁死）
    var lastDbgAt: CFTimeInterval = 0      // 临时诊断日志节流
    var didInitialGeo = false
    var didFirstKick = false
    var cursorP: CGPoint?              // 光标在滚动容器坐标里的位置（⌘wheel 缩放锚点 / 双击选词定位；域外为 nil）
    var selDragAnchor: (page: Int, pt: CGPoint)?   // 进行中拖选的页空间锚点（页号 + 该页 PDF 页坐标）
    var wheelMonitor: Any?             // ⌘+滚轮的 NSEvent 本地监视器（事件管道，非视图）
    var copyMonitor: Any?              // ⌘C 的 NSEvent 本地监视器（.onCopyCommand 依赖响应链/焦点，在纯
                                        // ScrollView 容器上不可靠触发；改走事件管道直写 NSPasteboard）
    var isActiveWindow = false         // 供 copyMonitor 闭包读取的实时值（struct let 会在 onAppear 后过期，需经 scratch 转发）
    let clientID = UUID().uuidString   // 渲染引擎多窗口 wanted 隔离键
}

private struct ReaderSurface: View {
    @ObservedObject var session: DocSession
    let docKey: String
    let nightMode: Bool
    let interpEnabled: Bool
    let isActiveWindow: Bool
    let unobSize: CGSize          // 未遮视口尺寸（fit 基准；GeometryReader 提供，与内容无关）
    let fullWidth: CGFloat        // 全宽（第二个 GeometryReader；区分窗口缩放 vs 侧栏开合）
    let indicatorTopInset: CGFloat // 滚动条顶端下压量（避让玻璃工具栏；内容仍垫底）

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
    // 文字选择（T1）：直接复用 PDFKit 原生选择引擎（`selection(from:at:to:at:)`），拿到与 PDFView 同款
    // 的「视觉阅读顺序」连续选区——不再自研词框排序（旧实现对多栏/思维导图版面会东一块西一块）。
    // 存归一化逐页行框 + 选中串；拖选期间实时重算，随缩放/滚动免重算（归一化随页尺寸自适应）。
    @State private var selection: TextSelection?

    private let zoomMin: CGFloat = 0.25
    private let zoomMax: CGFloat = 6
    private let basePixelCap = 2800               // 整页基图像素宽上限；超出由贴片补清晰

    /// legacy（占空间）滚动条宽度（系统度量；触摸板 overlay 模式 = 0）。
    /// ⚠️ 教训（2026-07-21 实测，日志复现）：**严禁用 `ScrollGeometry.containerSize` 当宽度真相源**——
    /// 在 ignoresSafeArea + 动态轴组合下它跟随 `contentW + 滚动条槽`（非独立视口测量，contentInsets 恒 0），
    /// 内容宽再由它推导 = 闭环互抬，每帧 +17pt 无限放大。宽度输入必须全部与内容无关（GeometryReader + 系统度量）。
    /// ⚠️ 启动抖动坑（2026-07-21 实测）：`NSScroller.preferredScrollerStyle` 在进程刚启动会**瞬时误报 overlay(→0)**，
    /// ~300ms 后系统探测到鼠标才切 legacy 并发通知。若首帧按 0 定基准，内容=全容器宽，legacy 竖条落位后瞬间溢出
    /// 17pt = 横条闪一下。故一律按 legacy 占位(worst-case)起步：legacy 用户零抖动、内容==视口；overlay 用户仅右侧
    /// 多留 17pt 悬浮条位（无横条无抖动，合理保留）。运行时真改样式仍由 preferredScrollerStyleDidChangeNotification 校正。
    @State private var scrollerAllowance: CGFloat =
        NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy)

    // MARK: 布局换算

    /// 布局基准宽（Option A / Preview 式，用户 2026-07-21 选定）：全窗宽（含侧栏/Inspector 玻璃下延伸区）。
    /// 页面按整窗 fit、开合侧栏纹丝不动——布局只依赖 `fullWidth`，侧栏是 safe-area inset（不改 fullWidth），
    /// 故侧栏开合对 fit 基准零影响 = 天然零位移零缩放（半透明玻璃盖住页面左侧，能透过看到）。
    /// 启动瞬时 fullWidth 未到（=0）时回退未遮宽兜底。
    private var layoutW: CGFloat { fullWidth > 0 ? fullWidth : unobSize.width }
    /// fit 页宽基准：全窗宽 − legacy 滚动条占位（= 真实 clip 视口宽）。两输入都与内容无关 → 无反馈环。
    private var fitAvail: CGFloat { max(1, layoutW - scrollerAllowance) }
    private var basis: CGFloat { fitBasis > 0 ? fitBasis : fitAvail }
    private var pageW: CGFloat { basis * zoom }
    private var dispScale: CGFloat { pageW / PageLayout.refWidth }
    /// ⚠️ 三条实测钉死的语义（2026-07-21，NSScrollView 层级 dump 实锤，见 PROBE 日志）：
    /// ① **严禁动态切换 ScrollView 轴集合**——轴只在创建时生效，之后变更不应用（水平轴会被永久固化）。
    /// ② **legacy 竖滚动条是「占位」的**：ScrollView 因 ignoresSafeArea 铺满整窗（容器=全窗宽），但真实可视
    ///    视口 `clip.bounds = 容器 − 占位竖滚动条(17pt)`。dump 实测：容器 697 → 视口 680，竖条贴 x=680 吃 17pt。
    ///    → 内容宽下限取 `fitAvail`（= 真实视口）：fit 时 contentW==fitAvail==视口 → 水平区间 0；放大时 contentW==pageW>视口。
    /// ③ **SwiftUI ScrollView 会把「窄于容器的内容」在整窗宽里居中，居中内边距=(全窗宽−内容宽)/2 两侧对称、
    ///    会被算进可滚区间**（= 竖滚动条宽 17）→ 常驻横条。故 body 上加 `.defaultScrollAnchor(.topLeading)` 关掉自动居中；
    ///    页面改由 `pageX` 在 contentW 内居中（页面居中在真实视口/整窗，非在自动居中的整窗）。
    private var contentW: CGFloat { max(fitAvail, pageW) }
    private var contentH: CGFloat { (layout?.totalHeight ?? 1) * dispScale }
    private var pageX: CGFloat { (contentW - pageW) / 2 }
    private var paper: Color { nightMode ? Color(white: 0.10) : .white }

    var body: some View {
        ScrollView([.vertical, .horizontal]) {
            contentBody
        }
        // ⚠️ 关键：内容窄于容器(全窗宽)时，ScrollView 默认「水平居中」，居中内边距=(全窗宽−内容宽)/2 会被算进可滚区间
        //    → 把内容撑回全窗宽 > 真实视口(全窗宽−占位竖滚动条) → 常驻横条。靠首端对齐关掉居中；页面仍由 pageX 在内容内居中。
        .defaultScrollAnchor(.topLeading)
        .contentMargins(.top, indicatorTopInset, for: .scrollIndicators)   // 滚动条不进工具栏区
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
        // 缩放手势挂在 ScrollView 容器（而非内容层）→ 整个阅读区都能捏合：页间空隙、末页下方空白、
        // zoom<1 时页两侧留白皆可，不再限于 PDF 页面上。startLocation 为容器/视口坐标（与上方 .local 同空间）。
        .simultaneousGesture(magnify)
        // 文字选择拖选（T1）：与 magnify 同容器/同坐标系，鼠标拖拽与双指捏合互不干扰。
        .simultaneousGesture(dragSelectGesture)
        // 双击选词 / 单击取消选择。用 `.onTapGesture` 的单双击分级（单击等一拍确认非双击，同 macOS 原生手感）；
        // 双击定位取光标最近位置（`.onContinuousHover` 维护），避免 SpatialTapGesture 与拖选/缩放争手势。
        .onTapGesture(count: 2) { if let p = scratch.cursorP { selectWord(atContainer: p) } }
        .onTapGesture(count: 1) { clearSelection() }
        .overlay(alignment: .topLeading) { followTicker }
        .onChange(of: session.scrollAnchor) { _, a in incomingAnchor(a) }
        .onChange(of: nightMode) { _, _ in scheduleSettleRender() }
        .onChange(of: fullWidth) { _, _ in
            // fullWidth 到位前首帧已早退；到位后补跑首帧定基准+首次实化（消除启动窄→宽闪烁）。窗口真实缩放走 refit。
            if scratch.didInitialGeo { scheduleRefit() } else { geometryChanged(scratch.geo) }
        }
        .onChange(of: unobSize.width) { _, _ in
            if scratch.didInitialGeo { scheduleRefit() }   // 侧栏开合(unobW 变但 fullWidth 不变 → refit 内早退，零变化)
            else { geometryChanged(scratch.geo) }          // 首帧兜底：unobSize 就绪即尝试定基准（切文档防空白）
        }
        .onReceive(NotificationCenter.default.publisher(
            for: NSScroller.preferredScrollerStyleDidChangeNotification)) { _ in
            // 鼠标插拔切换 overlay/legacy 滚动条 → fit 可用宽变了
            scrollerAllowance = NSScroller.preferredScrollerStyle == .legacy
                ? NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy) : 0
            scheduleRefit()
        }
        .onChange(of: interpEnabled) { _, v in follower.interpEnabled = v }
        .onChange(of: isActiveWindow) { _, v in scratch.isActiveWindow = v }
        .onAppear {
            scratch.isActiveWindow = isActiveWindow
            setup()
            installWheelMonitor()
            installCopyMonitor()
            // 切文档重建后补跑一次首帧几何求值：onScrollGeometryChange 可能不重发，靠 onAppear(layout 就绪)
            // + fullWidth/unobSize 的 onChange 三路兜底，任一到位即定基准（防新文档首屏空白、须拖窗口才出）。
            if !scratch.didInitialGeo { geometryChanged(scratch.geo) }
        }
        .onDisappear {
            follower.reset()
            removeWheelMonitor()
            removeCopyMonitor()
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
        if let layout, scratch.didInitialGeo {   // 未定基准前只占位空白（防启动窄宽渲染 → 闪烁）
            let activeMatch = session.currentMatchIndex.flatMap { session.searchMatches.indices.contains($0) ? session.searchMatches[$0] : nil }
            ZStack(alignment: .topLeading) {
                ForEach(Array(realized), id: \.self) { i in
                    PageCellView(size: CGSize(width: pageW, height: layout.heights[i] * dispScale),
                                 image: images[i],
                                 tile: tiles[i],
                                 paper: paper,
                                 strokes: session.strokes.filter { $0.page == i },
                                 live: session.liveStroke?.page == i ? session.liveStroke : nil,
                                 hover: session.hover?.page == i ? session.hover : nil,
                                 inkScale: zoom,
                                 selectionRects: selection?.rects[i] ?? [],
                                 matchRects: session.searchMatches.filter { $0.page == i }.flatMap(\.rects),
                                 activeMatchRects: activeMatch?.page == i ? activeMatch!.rects : [])
                        .offset(x: pageX, y: layout.offsets[i] * dispScale)
                }
            }
            .frame(width: contentW, height: contentH, alignment: .topLeading)
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
        scratch.appearAt = CACurrentMediaTime()
        // fitBasis 由首帧 geometryChanged 设定（此处不预设，避免与真实值有偏差）
        // 视图创建前就已发出的 restore/toc 锚点（loadSelected 先 emit 后建视图）
        if let a = session.scrollAnchor, a.origin != "mac" {
            scratch.pendingRestore = a
            lastAppliedSeq = a.seq
        }
    }

    // MARK: 滚动几何（锚点上报 / 实化窗口 / commit 校验）

    private func geometryChanged(_ raw: GeoSnap) {
        var n = raw
        // 首帧兜底：切文档时 ScrollView 被 `.id(docKey)` 整体重建，onScrollGeometryChange 未必重发首帧
        // 几何（容器尺寸与旧文档相同 → SwiftUI 认为"没变化"不回调）→ 新文档首屏空白，须拖窗口才恢复。
        // scroll 几何缺席（containerW≤0）时，用外层 GeometryReader 的 unobSize（布局同步可得、与内容无关）
        // 兜底填容器尺寸，仅供实化窗口/偏移使用，**绝不参与宽度/fit 决策**（那些只依赖 fullWidth，见 fitAvail 注释）。
        if n.containerW <= 0, unobSize.width > 0 {
            n.containerW = unobSize.width
            n.containerH = unobSize.height
        }
        scratch.geo = n
        guard let layout else { return }
        // ⚠️ 此处严禁读取 n.containerW/contentW 做宽度决策（会与内容互抬成环，见 fitAvail 注释）。
        // 首帧定基准必须等 `fullWidth > 0`（后台 GeometryReader 慢半拍）——否则 layoutW 回退未遮宽=窄，
        // 会把窄页渲染出来、40ms 后再跳到整窗宽 = 启动闪烁。未就绪则整体早退（didInitialGeo 前不实化/不渲染）。
        if !scratch.didInitialGeo {
            guard n.containerW > 0, fullWidth > 0 else { return }
            scratch.didInitialGeo = true
            fitBasis = fitAvail                   // 首帧定 fit 基准（全窗宽 − legacy 滚动条占位）
            scratch.lastRefitFullW = fullWidth
            NSLog("[RD] bootstrap didInitialGeo=1 via %@ containerW=%.1f fullW=%.1f unobW=%.1f",
                  raw.containerW > 0 ? "scrollGeo" : "unobSize", n.containerW, fullWidth, unobSize.width)
        }
        let dbgNow = CACurrentMediaTime()
        if dbgNow - scratch.lastDbgAt > 0.25 {
            scratch.lastDbgAt = dbgNow
            NSLog("[RD] state pageW=%.1f fitBasis=%.1f zoom=%.3f unobW=%.1f fullW=%.1f allow=%.1f content=%.1fx%.0f container=%.1fx%.1f off=(%.1f,%.1f) hbar=%d",
                  pageW, fitBasis, zoom, unobSize.width, fullWidth, scrollerAllowance,
                  n.contentW, n.contentH, n.containerW, n.containerH, n.offsetX, n.offsetY,
                  pageW > fitAvail + 0.5 ? 1 : 0)   // 真实横条判据：内容宽(=max(fitAvail,pageW)) 超真实视口 fitAvail
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

    // MARK: 文字选择（T1：拖选 = PDFKit 原生选择引擎；双击选词；单击取消；⌘C 复制）

    /// 容器/视口坐标 P（与 pinch/hover 同 `.local` 空间）→ (页, 该页 PDF 页空间点)。
    /// 越界点按页边缘 clamp（拖到页外 = 选到页边）；产出的页空间点直接喂 PDFKit `selection(from:at:to:at:)`。
    private func containerPointToPageSpace(_ P: CGPoint) -> (page: Int, pt: CGPoint)? {
        guard let layout, let pdf = session.pdf else { return nil }
        let g = scratch.geo
        let ds = max(0.0001, dispScale)
        let cx = g.offsetX + P.x, cy = g.offsetY + P.y            // 内容坐标
        let page = layout.locate(docY: cy / ds).page
        guard let pdfPage = pdf.page(at: page) else { return nil }
        let pageTopDisp = layout.offsets[page] * ds
        let pageHDisp = layout.heights[page] * ds
        guard pageW > 0, pageHDisp > 0 else { return nil }
        let nx = min(max((cx - pageX) / pageW, 0), 1)
        let ny = min(max((cy - pageTopDisp) / pageHDisp, 0), 1)
        let mb = pdfPage.bounds(for: .mediaBox)
        return (page, PageGeometry.pageSpacePoint(normX: nx, normY: ny, mediaBox: mb, rotation: pdfPage.rotation))
    }

    /// 由 PDFKit 原生选区（可跨页）落成 `selection`：空/无字则清空。选区的可视顺序、跨行跨页、CJK
    /// 都交给 PDFKit（与 PDFView 同引擎），本层只做坐标进出 + 归一化行框。
    private func setSelection(_ sel: PDFSelection?) {
        guard let pdf = session.pdf, let sel, sel.string?.isEmpty == false else {
            if selection != nil { selection = nil }
            return
        }
        selection = TextSelection(rects: PageGeometry.normalizedLineRects(of: sel, in: pdf),
                                  text: sel.string ?? "")
    }

    private func clearSelection() { if selection != nil { selection = nil } }

    /// 双击选词：光标处取整词选区（PDFKit `selectionForWord`）。
    private func selectWord(atContainer P: CGPoint) {
        guard let pdf = session.pdf, let hit = containerPointToPageSpace(P),
              let page = pdf.page(at: hit.page) else { return }
        setSelection(page.selectionForWord(at: hit.pt))
    }

    /// 拖选：起点定锚（一次），移动实时向 PDFKit 要「锚点→当前」的连续选区。与 magnify 同容器；捏合进行中不选。
    /// minimumDistance 2 → 纯单击不触发拖选（交给 `.onTapGesture` 取消），2px 内抖动不误选。
    private var dragSelectGesture: some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .local)
            .onChanged { v in
                guard scratch.pinch == nil else { return }
                if scratch.selDragAnchor == nil {
                    scratch.selDragAnchor = containerPointToPageSpace(v.startLocation)
                }
                guard let a = scratch.selDragAnchor, let f = containerPointToPageSpace(v.location),
                      let pdf = session.pdf, let pa = pdf.page(at: a.page), let pf = pdf.page(at: f.page)
                else { return }
                setSelection(pdf.selection(from: pa, at: a.pt, to: pf, at: f.pt))
            }
            .onEnded { _ in scratch.selDragAnchor = nil }
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
        let cw = max(fitAvail, pw)                      // 与 contentW 同源
        let ch = layout.totalHeight * pw / PageLayout.refWidth
        // 水平有效视口 = fitAvail（= 未遮宽 − 占位竖滚动条 = 真实 clip 视口；ScrollGeometry 的 insets/containerW 不可用作视口）
        let minX: CGFloat = 0
        let maxX = max(0, cw - fitAvail)
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
            // 手势现挂在 ScrollView 容器 → startLocation 为容器/视口坐标 P（屏幕不动点，与 ⌘wheel/anchorP 同约定）；
            // 内容锚点 c = 偏移 + P。（旧实现挂 content 层取内容坐标，捏合页外空白无手势 → 不缩放。）
            let P = v.startLocation
            let c = CGPoint(x: g.offsetX + P.x, y: g.offsetY + P.y)
            scratch.pinch = PinchInfo(startZoom: zoom, viewportP: P, cCur: c)
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

    /// ⌘C 直写剪贴板（不用 `.onCopyCommand`：它靠 NSResponder 焦点链触发，纯 `ScrollView` 容器
    /// 拿不到焦点、菜单/快捷键完全不响应）。只在本窗口是 key window 且确有文字选区时消费事件并拦下；
    /// 其余情况（普通输入框、无选区、非当前窗口）原样放行，不影响系统默认 Cmd+C。
    private func installCopyMonitor() {
        guard scratch.copyMonitor == nil else { return }
        scratch.copyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard scratch.isActiveWindow,
                  event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                  event.charactersIgnoringModifiers?.lowercased() == "c",
                  let text = selection?.text, !text.isEmpty,
                  !(NSApp.keyWindow?.firstResponder is NSText) else { return event }
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(text, forType: .string)
            return nil
        }
    }

    private func removeCopyMonitor() {
        if let m = scratch.copyMonitor {
            NSEvent.removeMonitor(m)
            scratch.copyMonitor = nil
        }
    }

    /// ⌘0：回 fit-width（基准重定标到当前实测可用宽），未遮视口中心为锚。
    private func commandZoomFit() {
        guard layout != nil, scratch.didInitialGeo else { return }
        let g = scratch.geo
        let newBasis = fitAvail
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
    // 变化期间布局冻结（页尺寸不变 → 纵向绝对稳定）；稳定 0.2s 后一次性处理：
    //   · 侧栏/Inspector 开合（Option A / Preview 式）→ fullWidth 不变 → fitAvail 不变 → **guard 早退，纯 no-op**
    //     （页面纹丝不动，半透明玻璃盖住左侧——用户 2026-07-21 选定）。unobW 已不参与布局，仅 debug 日志留存。
    //   · 窗口宽真变（fullWidth 变，含 legacy 滚动条出现/消失）→ fit 模式做单次原子锚定 refit；
    //     手动缩放态只重定标基准保持页宽（Preview 的绝对尺寸语义）

    private func scheduleRefit() {
        guard scratch.didInitialGeo else { return }
        scratch.resizeWork?.cancel()
        let work = DispatchWorkItem { refitToViewport() }
        scratch.resizeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }

    private func refitToViewport() {
        guard layout != nil, scratch.didInitialGeo else { return }
        let g = scratch.geo
        let newW = fitAvail                              // 全窗宽 − 滚动条占位（与内容无关，无环；侧栏开合不改它 → 下方 guard 早退）
        let windowWidthChanged = abs(fullWidth - scratch.lastRefitFullW) > 0.5
        NSLog("[RD] refit newW=%.1f fullW=%.1f(last %.1f) winChanged=%d userZoomed=%d zoom=%.3f fitBasis=%.1f pageW=%.1f unobW=%.1f",
              newW, fullWidth, scratch.lastRefitFullW, windowWidthChanged ? 1 : 0, userZoomed ? 1 : 0,
              zoom, fitBasis, pageW, unobSize.width)
        scratch.lastRefitFullW = fullWidth
        guard abs(newW - fitBasis) > 0.5 || windowWidthChanged else { return }   // 无实质变化
        // 启动稳定窗（窗口恢复/分栏落位的瞬态宽度会连环变化）：未缩放前一律真 fit，
        // 否则首帧捕获的瞬态宽会被「零视觉变化」重定标逻辑永久锁死（页宽偏窄、跑到左边）。
        let startupSettling = !userZoomed && CACurrentMediaTime() - scratch.appearAt < 1.5
        if userZoomed || (!windowWidthChanged && !startupSettling) {
            // 尺寸保持：显示页宽不变，仅重定标 fit 基准 → 零视觉变化（窗口缩放且手动缩放态走这里）
            let eff = pageW
            var t = Transaction(); t.animation = nil
            withTransaction(t) {
                fitBasis = newW
                zoom = min(max(eff / newW, zoomMin), zoomMax)
            }
        } else {
            // fit 模式 + 窗口宽变化：单次原子锚定 refit（顶部文档点钉住）
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
    var selectionRects: [CGRect] = []      // 文字选择高亮（T1），归一化 0~1 左上原点
    var matchRects: [CGRect] = []          // 搜索命中高亮，归一化 0~1 左上原点（T2，全部命中，淡黄）
    var activeMatchRects: [CGRect] = []    // 当前命中（同上坐标，橙色强调）

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
            if !matchRects.isEmpty || !activeMatchRects.isEmpty {
                Canvas { ctx, sz in
                    for r in matchRects { fillNorm(r, in: &ctx, size: sz, color: .yellow.opacity(0.35)) }
                    for r in activeMatchRects { fillNorm(r, in: &ctx, size: sz, color: .orange.opacity(0.55)) }
                }
                .allowsHitTesting(false)
            }
            if !selectionRects.isEmpty {
                Canvas { ctx, sz in
                    for r in selectionRects { fillNorm(r, in: &ctx, size: sz, color: .accentColor.opacity(0.35)) }
                }
                .allowsHitTesting(false)
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

    /// 归一化矩形（0~1，左上原点）→ 页内像素矩形并填充（文字选择/搜索命中高亮共用）。
    private func fillNorm(_ r: CGRect, in ctx: inout GraphicsContext, size: CGSize, color: Color) {
        let px = CGRect(x: r.minX * size.width, y: r.minY * size.height,
                        width: r.width * size.width, height: r.height * size.height)
        ctx.fill(Path(roundedRect: px.insetBy(dx: -1, dy: -0.5), cornerRadius: 2), with: .color(color))
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
