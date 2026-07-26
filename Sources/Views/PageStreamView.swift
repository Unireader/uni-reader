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
    @State var fullWidth: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
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

struct ReaderSurface: View {
    @EnvironmentObject var app: AppModel
    @EnvironmentObject var workspace: WorkspaceManager
    @ObservedObject var session: DocSession
    let docKey: String
    let nightMode: Bool
    let interpEnabled: Bool
    let isActiveWindow: Bool
    let unobSize: CGSize          // 未遮视口尺寸（fit 基准；GeometryReader 提供，与内容无关）
    let fullWidth: CGFloat        // 全宽（第二个 GeometryReader；区分窗口缩放 vs 侧栏开合）
    let indicatorTopInset: CGFloat // 滚动条顶端下压量（避让玻璃工具栏；内容仍垫底）

    @Environment(\.displayScale) var displayScale

    // 布局/缩放状态
    @State var layout: PageLayout?
    @State var zoom: CGFloat = 1          // 1 = fit-width（相对 fitBasis）
    @State var fitBasis: CGFloat = 0      // fit 基准宽（pt）；resize settle 时重定标
    @State var userZoomed = false
    @State var zoomAnimOn = false         // 缩放动画进行中（驱动 TimelineView 帧源）
    // 滚动
    @State var pos = ScrollPosition()
    // 视图数据
    @State var realized: ClosedRange<Int> = 0...0
    @State var images: [Int: CGImage] = [:]
    @State var tiles: [Int: PageTile] = [:]
    // 跟随
    @StateObject var follower = ScrollFollower()
    @State var lastAppliedSeq = 0
    // 非渲染暂存
    @State var scratch = Scratch()
    // 文字选择（T1）：直接复用 PDFKit 原生选择引擎（`selection(from:at:to:at:)`），拿到与 PDFView 同款
    // 的「视觉阅读顺序」连续选区——不再自研词框排序（旧实现对多栏/思维导图版面会东一块西一块）。
    // 存归一化逐页行框 + 选中串；拖选期间实时重算，随缩放/滚动免重算（归一化随页尺寸自适应）。
    @State var selection: TextSelection?
    /// 批注编辑器目标（非 nil 即呈现 sheet）：新建（选区草稿）或编辑（点页面图钉）。
    @State var editorTarget: NoteEditorTarget?

    let zoomMin: CGFloat = 0.25
    let zoomMax: CGFloat = 6
    let basePixelCap = 2800               // 整页基图像素宽上限；超出由贴片补清晰

    /// legacy（占空间）滚动条宽度（系统度量；触摸板 overlay 模式 = 0）。
    /// ⚠️ 教训（2026-07-21 实测，日志复现）：**严禁用 `ScrollGeometry.containerSize` 当宽度真相源**——
    /// 在 ignoresSafeArea + 动态轴组合下它跟随 `contentW + 滚动条槽`（非独立视口测量，contentInsets 恒 0），
    /// 内容宽再由它推导 = 闭环互抬，每帧 +17pt 无限放大。宽度输入必须全部与内容无关（GeometryReader + 系统度量）。
    /// ⚠️ 启动抖动坑（2026-07-21 实测）：`NSScroller.preferredScrollerStyle` 在进程刚启动会**瞬时误报 overlay(→0)**，
    /// ~300ms 后系统探测到鼠标才切 legacy 并发通知。若首帧按 0 定基准，内容=全容器宽，legacy 竖条落位后瞬间溢出
    /// 17pt = 横条闪一下。故一律按 legacy 占位(worst-case)起步：legacy 用户零抖动、内容==视口；overlay 用户仅右侧
    /// 多留 17pt 悬浮条位（无横条无抖动，合理保留）。运行时真改样式仍由 preferredScrollerStyleDidChangeNotification 校正。
    @State var scrollerAllowance: CGFloat =
        NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy)

    // MARK: 布局换算

    /// 布局基准宽（Option A / Preview 式，用户 2026-07-21 选定）：全窗宽（含侧栏/Inspector 玻璃下延伸区）。
    /// 页面按整窗 fit、开合侧栏纹丝不动——布局只依赖 `fullWidth`，侧栏是 safe-area inset（不改 fullWidth），
    /// 故侧栏开合对 fit 基准零影响 = 天然零位移零缩放（半透明玻璃盖住页面左侧，能透过看到）。
    /// 启动瞬时 fullWidth 未到（=0）时回退未遮宽兜底。
    var layoutW: CGFloat { fullWidth > 0 ? fullWidth : unobSize.width }
    /// fit 页宽基准：全窗宽 − legacy 滚动条占位（= 真实 clip 视口宽）。两输入都与内容无关 → 无反馈环。
    var fitAvail: CGFloat { max(1, layoutW - scrollerAllowance) }
    var basis: CGFloat { fitBasis > 0 ? fitBasis : fitAvail }
    var pageW: CGFloat { basis * zoom }
    var dispScale: CGFloat { pageW / PageLayout.refWidth }
    /// ⚠️ 三条实测钉死的语义（2026-07-21，NSScrollView 层级 dump 实锤，见 PROBE 日志）：
    /// ① **严禁动态切换 ScrollView 轴集合**——轴只在创建时生效，之后变更不应用（水平轴会被永久固化）。
    /// ② **legacy 竖滚动条是「占位」的**：ScrollView 因 ignoresSafeArea 铺满整窗（容器=全窗宽），但真实可视
    ///    视口 `clip.bounds = 容器 − 占位竖滚动条(17pt)`。dump 实测：容器 697 → 视口 680，竖条贴 x=680 吃 17pt。
    ///    → 内容宽下限取 `fitAvail`（= 真实视口）：fit 时 contentW==fitAvail==视口 → 水平区间 0；放大时 contentW==pageW>视口。
    /// ③ **SwiftUI ScrollView 会把「窄于容器的内容」在整窗宽里居中，居中内边距=(全窗宽−内容宽)/2 两侧对称、
    ///    会被算进可滚区间**（= 竖滚动条宽 17）→ 常驻横条。故 body 上加 `.defaultScrollAnchor(.topLeading)` 关掉自动居中；
    ///    页面改由 `pageX` 在 contentW 内居中（页面居中在真实视口/整窗，非在自动居中的整窗）。
    var contentW: CGFloat { max(fitAvail, pageW) }
    var contentH: CGFloat { (layout?.totalHeight ?? 1) * dispScale }
    var pageX: CGFloat { (contentW - pageW) / 2 }
    var paper: Color { nightMode ? Color(white: 0.10) : .white }
    /// 页与页之间/未实化区域的底色（比 paper 略深，同亮色下"纸张浮在浅灰底"的观感）。
    /// 夜间模式下若仍用系统默认底色（不随 nightMode 变——那是系统外观，与阅读区内切换是两回事），
    /// 未出图区域会露出一块亮色，本该全黑的场景变成"黑纸配白底"。
    var voidColor: Color { nightMode ? Color(white: 0.06) : Color(nsColor: .windowBackgroundColor) }

    var body: some View {
        ScrollView([.vertical, .horizontal]) {
            contentBody
        }
        .background(voidColor)   // 页间空隙 / 未实化区域的底色，随夜间模式切换（否则露出系统默认亮底）
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
        // 右键选区 → 「添加批注 / 复制」（原生上下文菜单，非浮层 hack）。菜单项常驻、无选区时禁用，
        // 避免按选区有无条件包裹 ScrollView 改变其身份而重置滚动位置。
        .contextMenu { readerContextMenu }
        // 批注编辑器（原生 .sheet）：新建或编辑同一入口。保存 → 改 session.textNotes（ContentView.onChange 落库）。
        .sheet(item: $editorTarget) { target in
            NoteEditorSheet(quote: target.quote, initialText: target.initialText,
                            initialTypeId: target.initialTypeId,
                            noteTypes: session.noteTypes,
                            usageCount: { id in session.textNotes.filter { $0.typeId == id }.count },
                            onSave: { saveEditor(target, text: $0, typeId: $1) },
                            onChangeTypes: { saveNoteTypes($0) },
                            onCancel: { editorTarget = nil })
        }
        .overlay(alignment: .topLeading) { followTicker }
        // 笔架悬浮面板：挂在 ScrollView 本身（视口坐标系，不随内容滚动），跟 followTicker 同一个既有机制。
        .overlay { GeometryReader { proxy in PenRackView(viewportSize: proxy.size, topInset: indicatorTopInset, isActiveWindow: isActiveWindow) } }
        .onChange(of: session.scrollAnchor) { _, a in incomingAnchor(a) }
        .onChange(of: nightMode) { _, _ in scheduleNightRender() }
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
        .onChange(of: zoom) { _, z in session.readZoom = z }   // 回报当前缩放，供进度持久化
        .onChange(of: interpEnabled) { _, v in follower.interpEnabled = v }
        .onChange(of: isActiveWindow) { _, v in scratch.isActiveWindow = v }
        .onChange(of: session.ocrEnabled) { _, on in if on { session.enqueueOCR(Array(realized)) } }
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
        .onReceive(NotificationCenter.default.publisher(for: .readerZoomActual)) { _ in
            if isActiveWindow { commandZoomActual() }
        }
    }

    // MARK: 内容（自研虚拟化：精确总尺寸 + 只实化窗口内页）

    @ViewBuilder var contentBody: some View {
        if let layout, scratch.didInitialGeo {   // 未定基准前只占位空白（防启动窄宽渲染 → 闪烁）
            let activeMatch = session.currentMatchIndex.flatMap { session.searchMatches.indices.contains($0) ? session.searchMatches[$0] : nil }
            ZStack(alignment: .topLeading) {
                ForEach(Array(realized), id: \.self) { i in
                    pageCell(i, layout: layout, activeMatch: activeMatch)
                }
            }
            .frame(width: contentW, height: contentH, alignment: .topLeading)
            .transaction { $0.animation = nil }   // 零闪烁纪律 4：阅读区无隐式动画
        } else {
            Color.clear.frame(width: 10, height: 10)
        }
    }

    /// 单页元胞构造。抽成独立函数（而非内联进 ForEach）——参数众多，内联会让 SwiftUI 类型检查器超时。
    @ViewBuilder func pageCell(_ i: Int, layout: PageLayout, activeMatch: TextMatch?) -> some View {
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
                     activeMatchRects: activeMatch?.page == i ? activeMatch!.rects : [],
                     highlights: session.highlights.filter { $0.page == i },
                     notes: session.textNotes.filter { $0.page == i },
                     noteTypes: session.noteTypes,
                     ocrBlocks: session.showOCRBlocks ? (session.ocrRuns[i] ?? []) : [],
                     ocrGroups: session.showOCRBlocks && session.ocrBlockGrouped ? session.ocrGroups(page: i) : [],
                     radial: session.radial?.page == i ? session.radial : nil,
                     pens: app.pens,
                     pressRing: session.pressRing?.page == i ? session.pressRing : nil,
                     onOpenNote: { editorTarget = .edit($0) })
            .offset(x: pageX, y: layout.offsets[i] * dispScale)
    }

    /// 帧驱动（跟随器 / 缩放动画任一激活即挂载；TimelineView(.animation) 与刷新率同步）。
    @ViewBuilder var followTicker: some View {
        if follower.isActive || zoomAnimOn {
            TimelineView(.animation) { tl in
                Color.clear
                    .frame(width: 1, height: 1)
                    .onChange(of: tl.date) { _, _ in
                        if follower.isActive { followStep() }
                        if zoomAnimOn { zoomAnimStep() }
                    }
            }
            .allowsHitTesting(false)
        }
    }

    // MARK: 生命周期

    func setup() {
        guard let pdf = session.pdf else { return }
        let lay = PageLayout(doc: pdf)
        layout = lay
        follower.pageCount = lay.pageCount
        follower.interpEnabled = interpEnabled
        scratch.appearAt = CACurrentMediaTime()
        scratch.pendingZoom = session.restoreZoom   // 上次缩放：首帧定 fitBasis 后套用（见 geometryChanged）
        scratch.pendingHFrac = session.restoreHFrac > 0.0001 ? session.restoreHFrac : nil   // 横向恢复
        // fitBasis 由首帧 geometryChanged 设定（此处不预设，避免与真实值有偏差）
        // 视图创建前就已发出的 restore/toc 锚点（loadSelected 先 emit 后建视图）
        if let a = session.scrollAnchor, a.origin != "mac" {
            scratch.pendingRestore = a
            lastAppliedSeq = a.seq
        }
    }

}
