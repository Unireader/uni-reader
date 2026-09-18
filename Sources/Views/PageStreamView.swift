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
    /// 底部标签栏占掉的高度（`TabBarMetrics.inset`，只有一个标签时为 0）。
    /// 用途两处：滚动条不钻到标签栏底下、笔架拖不到标签栏底下。**内容仍然垫到底**（同 topInset 的口径）。
    let bottomInset: CGFloat
    /// 滚动条底部让位。占位式滚动条时为 0（见 `ReaderPane.scrollerLift`）：它的槽固定在最底边，只挪条不挪槽。
    let indicatorBottomInset: CGFloat
    /// 拖进阅读区的**非图片**文件（PDF）往上交给窗口层入库。图片文件阅读区自己收成图片笔记
    /// （`ReaderSurface+ImageNote`），所以拖放得挂在阅读区这一层——只有它知道落点在哪一页。
    var onDropFiles: ([URL]) -> Void = { _ in }

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
                          indicatorTopInset: geo.safeAreaInsets.top,
                          bottomInset: bottomInset,
                          indicatorBottomInset: indicatorBottomInset,
                          onDropFiles: onDropFiles)
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
    let bottomInset: CGFloat       // 底部标签栏占掉的高度（笔架要避让它；内容仍垫底）
    let indicatorBottomInset: CGFloat // 滚动条底部让位（占位式滚动条时为 0）
    /// 拖进阅读区的非图片文件（PDF）交给窗口层入库（见 `PageStreamView.onDropFiles`）。
    let onDropFiles: ([URL]) -> Void
    /// 本次是不是**从快照种下的**（= 切标签回来）。见 `init` 的红线。
    let seededFromSnapshot: Bool

    /// 🔴 **切标签回来必须在这里（首次求值）就把状态摆好，`onAppear` 已经晚一帧**
    /// （2026-08-29 用户录像实测：先空白一下再出内容）。
    ///
    /// 切标签时阅读区被 `PageStreamView` 上的 `.id(docKey)` 整体重建，而 `onAppear` 是**视图首帧
    /// 画完之后**才调用的——在它里面做多少事都救不了那一帧空白（那正是 `geometryChanged` 里
    /// 「宁可白一下也不闪一下」注释描述的状态：`didInitialGeo` 未成立 = 不实化、不出图 = 留白）。
    /// `@State` 的初值则在**结构体第一次被创建**时就定下，赶在首帧之前。
    ///
    /// 种子来自 `DocSession.ReaderSnapshot`（离开时的 fit 基准 / 缩放 / 偏移 / 实化窗口 / 基图宽），
    /// 页图直接从 `PageRenderEngine` 缓存同步取——首帧就是「离开时那一屏」，一帧都不空。
    ///
    /// 三条前提缺一不可，任一不满足就原样走常规首帧路径（开窗 / 换文档都该走那条）：
    /// 有「待种」标记（`readerSeedPending`，切标签时才置）、几何已是真的、**fit 基准没变**
    /// （期间窗口或侧栏尺寸变过的话旧快照是错的）。
    init(session: DocSession, docKey: String, nightMode: Bool, interpEnabled: Bool,
         isActiveWindow: Bool, unobSize: CGSize, fullWidth: CGFloat,
         indicatorTopInset: CGFloat, bottomInset: CGFloat, indicatorBottomInset: CGFloat,
         onDropFiles: @escaping ([URL]) -> Void = { _ in }) {
        _session = ObservedObject(wrappedValue: session)
        self.docKey = docKey
        self.nightMode = nightMode
        self.interpEnabled = interpEnabled
        self.isActiveWindow = isActiveWindow
        self.unobSize = unobSize
        self.fullWidth = fullWidth
        self.indicatorTopInset = indicatorTopInset
        self.bottomInset = bottomInset
        self.indicatorBottomInset = indicatorBottomInset
        self.onDropFiles = onDropFiles

        // ⚠️ 这里用不了实例属性（还没初始化完），故 `layoutW` 就地重算一遍。
        let lw = fullWidth > 0 ? fullWidth : unobSize.width
        let s = session.readerSnapshot
        let lay = session.cachedLayout
        // 🔴 **宽度核对只在「量到的宽度可信」时才做**：`lw < 200` 是 SwiftUI 尚未落位时报的占位几何
        // （侧栏最小宽就有 200，见 `minPlausibleLayoutW`）。占位值什么都证明不了，而 `@State` 初值
        // **只在结构体第一次被创建时生效**——这一次不种，后面再创建也补不上了。所以占位时照种，
        // 真宽度到达后若确实变过，由既有的 `onChange(of: fullWidth)` → `refitToViewport` 收拾。
        let widthChanged = (lw >= 200) && abs((s?.layoutW ?? lw) - lw) > 0.5
        // 位置来自 `scrollAnchor`（页 + 页内比例），没有锚点就没得恢复，不种。
        let anchor = session.scrollAnchor
        guard session.readerSeedPending, let s, let lay, let a = anchor, !widthChanged else {
            // 跳过的原因值得留一行（默认关；`touch ~/Library/Logs/UniReader-zoom.log` 开）：
            // 这条路径静默失效过好几轮，下次再出问题第一眼要看的就是它。
            if session.readerSeedPending {
                let why = s == nil ? "无快照" : (lay == nil ? "无布局缓存"
                        : (anchor == nil ? "无锚点" : "宽度变了 \(Int(s?.layoutW ?? -1))→\(Int(lw))"))
                ZoomProbe.mark("标签种子：跳过（\(why)）")
                session.openTrace?.markOnce("种子", "跳过：\(why)")
            }
            seededFromSnapshot = false
            return
        }
        seededFromSnapshot = true
        let avail = max(1, lw - NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy))
        // 拆成局部常量而不是写进一个大表达式：本项目被 SwiftUI 类型检查器超时坑过多次
        // （ContentView / ReaderSurface 都为此分过层），算术嵌套一深就是下一个。
        let pw: CGFloat = s.fitBasis * s.zoom
        let ds: CGFloat = pw / PageLayout.refWidth
        // **位置由锚点现算**（页 + 页内比例 → docY → 显示偏移），不从快照拿，理由见 `ReaderSnapshot`。
        let offY: CGFloat = lay.docY(page: a.page, frac: a.frac) * ds
        let offX: CGFloat = CGFloat(session.readHFrac) * pw
        let off = CGPoint(x: offX, y: offY)
        // 实化窗口同样现推（上下各留一屏，与 `updateRealized` 同口径）。
        let buffer: CGFloat = unobSize.height / max(0.0001, ds)
        let realizedNow = lay.pageRange(fromDocY: offY / max(0.0001, ds) - buffer,
                                        toDocY: (offY + unobSize.height) / max(0.0001, ds) + buffer)
        _layout = State(initialValue: lay)
        _fitBasis = State(initialValue: s.fitBasis)
        _zoom = State(initialValue: s.zoom)
        _userZoomed = State(initialValue: s.userZoomed)
        _realized = State(initialValue: realizedNow)
        _pos = State(initialValue: ScrollPosition(point: off))
        let seeded = Self.seedImages(docKey: docKey, pages: realizedNow,
                                     width: s.basePixelW, night: nightMode)
        _images = State(initialValue: seeded)
        session.openTrace?.markOnce("种子", "\(seeded.count)/\(realizedNow.count) 张页图")
        let sc = Scratch()
        sc.didInitialGeo = true                       // 首帧就当作「基准已定」，别再等几何回调
        // 首拍几何比 `onAppear` 还早（2026-09-10 第五批账本：`实化 +25(… p283–285 → p284–285)` 再 `+40` 长回来），
        // 这里不种的话 `updateRealized` 按「非活跃窗口 = 不预实化」把种子里多出的那一页先拆再建。
        sc.isActiveWindow = isActiveWindow
        sc.nightLive = nightMode
        sc.imagesNight = nightMode
        sc.basePixelW = s.basePixelW
        sc.recentBaseWidths = s.recentBaseWidths
        sc.seedOffset = off                           // `setup` 拿它显式提交一次滚动
        // 🔴 目标**在这里就登记**，不等 `setup`（2026-09-10 第三批账本：首帧 body 之后、`setup` 之前，
        // ScrollView 先报了一拍 offset 0 的几何——`实化 +28(offY 0 … p283–285 → p1–1)`——实化窗口塌到 p1、
        // 刚种好的页元胞销毁重建、白渲一张 p1）。登记了它，`geometryChanged` 就按目标算实化，陈旧几何不作数。
        sc.pendingTarget = off
        sc.pendingTries = 0
        sc.geo = GeoSnap(offsetX: off.x, offsetY: off.y,
                         containerW: unobSize.width, containerH: unobSize.height,
                         contentW: max(avail, pw), contentH: lay.totalHeight * ds)
        sc.topDocY = offY / max(0.0001, ds)
        _scratch = State(initialValue: sc)
        ZoomProbe.mark("标签种子：p\(a.page)+\(String(format: "%.3f", a.frac)) → y=\(Int(offY))"
            + " 实化 \(realizedNow.lowerBound)…\(realizedNow.upperBound)"
            + " 图 \(seeded.count)/\(realizedNow.count) 张")
    }

    /// 从页图缓存同步取回「离开时那一屏」的图。取不到（被 LRU 挤掉了）就空着，
    /// 常规渲染调度随后会补——那是真正需要重渲的情况，不是本方案能省掉的。
    private static func seedImages(docKey: String, pages: ClosedRange<Int>,
                                   width: Int, night: Bool) -> [Int: CGImage] {
        guard width > 0 else { return [:] }
        var out: [Int: CGImage] = [:]
        for i in pages {
            if let hit = PageRenderEngine.shared.cached(
                PageRenderEngine.baseKey(doc: docKey, page: i, pixelWidth: width, night: night)) {
                out[i] = hit
            }
        }
        return out
    }

    @Environment(\.displayScale) var displayScale

    // 布局/缩放状态
    @State var layout: PageLayout?
    @State var zoom: CGFloat = 1          // 1 = fit-width（相对 fitBasis）
    @State var fitBasis: CGFloat = 0      // fit 基准宽（pt）；resize settle 时重定标
    @State var userZoomed = false
    @State var zoomAnimOn = false         // 缩放动画进行中（驱动 TimelineView 帧源）
    @State var matchPulseOn = false       // 搜索命中切换闪烁进行中（同上，驱动 TimelineView 帧源）
    @State var matchPulseT: CGFloat = 1   // 0=刚切换命中(最亮)…1=已落定(基础透明度)；仅对当前命中生效
    /// 设置里的开关（`SettingsView` 读同一个 key）：关闭时切换命中只显示常态高亮，不播闪烁。
    @AppStorage("matchPulseEnabled") var matchPulseEnabled = true
    /// 缩放进行中：墨迹层走快速描边（见 `inkDrawStroke` 的 `fast`）。
    /// 用 `@State` 而非 `scratch`：进出快速态各需要一次 body 重算（后者要按高质量重画一遍）。
    @State var inkFastDraw = false
    /// 缩放期间各页墨迹的**位图快照**（页 → 图）：起手时一次性渲好，整个缩放过程只做纹理拉伸。
    /// 见 `makeInkSnapshots`。settle 时清空，回到矢量 Canvas。
    @State var inkSnaps: [Int: CGImage] = [:]
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
    /// 画板模式（`session.canvasMode`）下每侧页边的宽度（**页宽的倍数**，见 `CanvasMargin`）。
    /// 由笔迹越界量档位化而来；写到边缘就跳一档（`growCanvasMargin`），改它必走 `setCanvasMargin`
    /// ——内容宽一变页面就在内容里平移，须同 runloop 补一次 `scrollTo`，屏幕上才纹丝不动。
    @State var canvasMarginState: Double = CanvasMargin.step
    // 文字选择（T1）：直接复用 PDFKit 原生选择引擎（`selection(from:at:to:at:)`），拿到与 PDFView 同款
    // 的「视觉阅读顺序」连续选区——不再自研词框排序（旧实现对多栏/思维导图版面会东一块西一块）。
    // 存归一化逐页行框 + 选中串；拖选期间实时重算，随缩放/滚动免重算（归一化随页尺寸自适应）。
    @State var selection: TextSelection?
    /// 拖选文字的算法（设置 → 阅读；默认开 = 框选：拖出矩形，选中与它相交的行/字，⌘+拖可叠加多段；
    /// 关 = 流式选择：起点→终点按阅读顺序连续选，同 PDFView 老手感）。`SettingsView` 读同一个 key。
    @AppStorage("textSelectBoxMode") var textSelectBoxMode = true
    /// 批注编辑器目标（非 nil 即呈现 sheet）：新建（选区草稿）或编辑（点页面图钉）。
    @State var editorTarget: NoteEditorTarget?
    // 框选移动/缩放（pointerTool == .lasso，仅页内；全部瞬态，不持久化——逻辑见 ReaderSurface+Lasso）
    @State var lassoSelection: LassoSelection?      // 选中集（同页笔迹/注解 id + 归一化联合包围盒）
    @State var lassoPath: [CGPoint]?                // 进行中的自由框选路径（视口坐标，≥3pt 抽稀）
    @State var lassoGhostOffset: CGSize = .zero     // 移动中的 ghost 预览偏移（显示点；数据在松手前不动）
    /// 进行中框选文字的拖拽：起点/当前点均容器 `.local` 坐标（画虚线框、与 DragGesture 同空间）；
    /// `additive` = 起手时按住 ⌘（这一框选完加进 `scratch.boxSelectBase`，组成不连续多段选区，见
    /// `ReaderSurface+BoxSelect`）。**必须是 `@State`**（同 `lassoPath` 的理由）：松手只清它、不改
    /// `selection`，若放进引用类型 `Scratch` 就不会触发重算，虚线框会留在原地直到别的状态变化才消失。
    @State var boxSelectDrag: (start: CGPoint, current: CGPoint, additive: Bool)?
    /// 缩放中的 ghost 预览（显示空间缩放比 + 被拖的手柄；anchor = 其对侧手柄；数据在松手前不动）。
    @State var lassoGhostScale: (sx: CGFloat, sy: CGFloat, handle: LassoHandle)?
    /// 点注解图钉拖拽的 ghost 预览偏移（note id + 页内像素位移；数据在松手前不动，逻辑见 ReaderSurface+Selection）。
    @State var notePinDrag: (id: UUID, off: CGSize)?
    /// 点开着的 `tap` 模式笔记气泡（**瞬态、不落库**：换文档/关窗即忘，同选区高亮的口径）。
    @State var expandedNotes: Set<UUID> = []
    /// 被点开的那条文字高亮 + 被点中的那一行（同样瞬态、不落库）：页元胞在那一行上挂删除气泡，见 `readerClickGesture`。
    @State var activeHighlight: HighlightTap?
    /// 指针悬停在哪枚图钉上（`hover` 模式的展开条件；离开即 nil）。
    @State var hoveredNote: UUID?
    /// 笔记气泡跟不跟页缩放（设置 → 阅读；默认关 = 固定尺寸，见 `NoteBubble`）。
    @AppStorage(NoteBubble.followsZoomKey) var bubbleFollowsZoom = false
    /// 气泡正文字号 / 最小宽 / 最大宽（设置 → 阅读；默认 12 / 120 / 280）。
    @AppStorage(NoteBubble.fontSizeKey) var bubbleFontSize = Int(NoteBubble.fixedFont)
    @AppStorage(NoteBubble.minWidthKey) var bubbleMinWidth = Int(NoteBubble.fixedMinWidth)
    @AppStorage(NoteBubble.maxWidthKey) var bubbleMaxWidth = Int(NoteBubble.fixedMaxWidth)
    /// 图片笔记编辑器目标（非 nil 即呈现 sheet；只有「编辑」——新建不弹编辑器，存了就是一条）。
    @State var imageEditor: ImageNote?
    /// 看大图（非 nil 即呈现 sheet）。
    @State var imageViewer: ImageNote?

    @State var snipRect: SnipRect?                  // 进行中的框选截图矩形（容器坐标）
    @State var snipToast: SnipToast?                // 截图投递的即时反馈（自动消失）
    /// 本机擦除的尺寸圆环位置（视口坐标；pointerTool==.ink 且 erase 模式时跟随光标，其余时刻 nil）。
    /// scratch.cursorP 在引用型 scratch 里、不触发刷新，圆环要实时跟手故单独走 @State。
    @State var eraseCursor: CGPoint?

    let zoomMin: CGFloat = 0.25
    let zoomMax: CGFloat = 6
    /// 「这个宽度不可能是真实布局」的下限（pt）：侧栏最小宽就有 200（见 `navigationSplitViewColumnWidth`），
    /// 而 `layoutW` 是**含侧栏延伸区的全窗宽**，比它还窄只能是 SwiftUI 尚未落位时报的占位几何。
    /// 用途见 `geometryChanged` 的首帧定基准（占位宽定基准 = 开窗时小页闪一下）。
    let minPlausibleLayoutW: CGFloat = 200
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

    // MARK: 缩放期间的墨迹渲染（`inkFastDraw`）
    //
    // 🔴 缩放**每帧**都改 `zoom` → 每个实化页的墨迹 Canvas 每帧重画一遍。真正贵的不是"重画"，
    // 是高质量描边那套：逐段 `strokedPath()` 转轮廓、攒成一条上万子路径的自相交 Path、一次 fill。
    // `spike/reader-zoom-probe.swift`（复刻真实层级，178 笔/15000 点一页 × 3 页，一次真实捏合）：
    //   现状 `strokedPath`+`fill`  27ms/页 → **33 fps**
    //   逐段 `stroke`（保压感）    6.3ms/页 → **99 fps**   ← 采用
    //   整条一次 `stroke`（丢压感）2.3ms/页 → 118 fps
    //   墨迹位图快照（0 重画）              → 126 fps（上界）
    // ⚠️ 走过的弯路：先试过「冻结绘制尺度 + `scaleEffect` 拉伸」。在只有一个 Canvas 的简化 spike 里
    // 漂亮得很（绘制闭包全程 1 次、125 fps），**放进真实层级就没用了**（45 次 vs 现状 49 次，
    // 33→47 fps）——外层每帧变的内容尺寸/页 offset 会把 Canvas 一并标脏，SwiftUI 照样按新尺度重绘。
    // 教训：**这类"SwiftUI 会不会复用"的探针必须连外层结构一起复刻**，孤立组件的读数会骗人。
    // 更大的教训：spike 只能量"一次绘制多贵"，量不出"每帧到底画了几页"——后者才是主项，
    // 只有真机探针（`ZoomProbe`）说得清。缩放性能的账要从那份日志读，别再从 spike 外推。

    /// 缩放起手：把当前要显示墨迹的页各渲成一张位图，缩放期间只拉伸它、一笔都不重画。
    ///
    /// 🔴 为什么非这么做不可（2026-08-29 用户报「手指缩放和按键缩放都会让笔迹闪烁」）：
    /// 缩放中墨迹每帧重画，而快速路径按**屏幕距离**抽稀——每帧的缩放比不同，保留下来的点就不同，
    /// 笔画轮廓于是每帧微微变形；叠加页面进出视口时整层的出现/消失，观感就是笔迹在闪。
    /// 只要缩放期间**不重画**，这两个来源同时消失。用户拍板的取舍原话：「可以先糊一点，然后再更新」。
    ///
    /// 成本：起手一次，每页约几毫秒（走 `fast` 的整层分组绘制，不是高质量那条），2~4 页合计
    /// 10~20ms —— 一帧的抖动，换整个缩放过程零重画。`scale = 1` 而非 displayScale：
    /// 缩放中本来就允许糊（同页图用旧宽度基图顶着的既有取舍），还省一半内存与渲染时间。
    /// settle 时 `inkSnaps` 清空 → 自动回到矢量 Canvas 按最终倍率重画一次 → 清晰。
    @MainActor
    func makeInkSnapshots() -> [Int: CGImage] {
        guard let layout else { return [:] }
        return inkSnapshots(for: realized, layout: layout)
    }

    /// 为指定页渲快照（`makeInkSnapshots` 与「缩放中新滑入的页」共用）。
    @MainActor
    func inkSnapshots(for pages: some Sequence<Int>, layout: PageLayout) -> [Int: CGImage] {
        guard !session.strokes.isEmpty, pageW > 1 else { return [:] }
        // 分桶**一次算完**：`visibleStrokesByPage` 是批量版，逐页拿 `i...i` 去调等于每页重扫一遍
        // 全部笔迹（正是它自己注释里那条「按页取用一律走批量版」禁止的用法），也会把它的单槽
        // 记忆一路冲掉。
        let list = Array(pages)
        guard let lo = list.min(), let hi = list.max() else { return [:] }
        let byPage = session.visibleStrokesByPage(in: lo...hi)
        var out: [Int: CGImage] = [:]
        for i in list {
            guard inkWanted(i, layout: layout) else { continue }
            let strokes = byPage[i] ?? []
            guard !strokes.isEmpty else { continue }
            let h = layout.heights[i] * dispScale
            guard h > 1 else { continue }
            let r = ImageRenderer(content:
                InkStaticLayer(strokes: strokes, inkScale: zoom, margin: marginPx, fast: true)
                    .frame(width: pageW + marginPx * 2, height: h))
            r.scale = 1
            if let img = r.cgImage { out[i] = img }
        }
        return out
    }

    /// 缩放中新滑入实化窗口的页**当场补一张快照**——否则它们没得可拉伸，只能退回逐帧重画，
    /// 那几页就会在缩小过程中闪（日志里表现为 `重绘页 p114×4 p111×2 …` 这种视口边缘的页）。
    /// 每页只渲一次（已有的跳过），按各自生成时刻的倍率渲、各自拉伸，互不影响。
    @MainActor
    func addInkSnapshots(for pages: Set<Int>) {
        guard inkFastDraw, let layout else { return }
        let missing = pages.filter { inkSnaps[$0] == nil }
        guard !missing.isEmpty else { return }
        let made = inkSnapshots(for: missing, layout: layout)
        guard !made.isEmpty else { return }
        inkSnaps.merge(made) { a, _ in a }
    }

    /// 缩放进行中：墨迹只画与**真实视口**相交的页（上下各留半屏余量）。
    /// 实化窗口本身要带一屏 buffer（滚动预热），但缩放中给看不见的页重画墨迹是纯浪费——
    /// 真机探针实测每次墨迹绘制约 1ms，缩小态一帧要画 7~10 页，而视口里只有 3 页。
    /// 松手后 `settleRender` 关掉 `inkFastDraw`，全实化窗口按高质量重画一次，不会留缺口。
    func inkWanted(_ i: Int, layout: PageLayout) -> Bool {
        guard inkFastDraw else { return true }
        let ds = dispScale
        let g = scratch.geo
        // 余量给足一屏：缩放中视口在动，余量太小的话同一页会在"要画/不画"之间反复横跳，
        // 那本身就是一种闪烁（墨迹一会儿有一会儿没有）。一屏余量下页进出视口是单向的、不来回。
        let pad = g.containerH
        let top = layout.offsets[i] * ds
        return top + layout.heights[i] * ds >= g.offsetY - pad && top <= g.offsetY + g.containerH + pad
    }
    /// ⚠️ 三条实测钉死的语义（2026-07-21，NSScrollView 层级 dump 实锤，见 PROBE 日志）：
    /// ① **严禁动态切换 ScrollView 轴集合**——轴只在创建时生效，之后变更不应用（水平轴会被永久固化）。
    /// ② **legacy 竖滚动条是「占位」的**：ScrollView 因 ignoresSafeArea 铺满整窗（容器=全窗宽），但真实可视
    ///    视口 `clip.bounds = 容器 − 占位竖滚动条(17pt)`。dump 实测：容器 697 → 视口 680，竖条贴 x=680 吃 17pt。
    ///    → 内容宽下限取 `fitAvail`（= 真实视口）：fit 时 contentW==fitAvail==视口 → 水平区间 0；放大时 contentW==pageW>视口。
    /// ③ **SwiftUI ScrollView 会把「窄于容器的内容」在整窗宽里居中，居中内边距=(全窗宽−内容宽)/2 两侧对称、
    ///    会被算进可滚区间**（= 竖滚动条宽 17）→ 常驻横条。故 body 上加 `.defaultScrollAnchor(.topLeading)` 关掉自动居中；
    ///    页面改由 `pageX` 在 contentW 内居中（页面居中在真实视口/整窗，非在自动居中的整窗）。
    var contentW: CGFloat { contentWidth(margin: canvasMargin) }
    var contentH: CGFloat { (layout?.totalHeight ?? 1) * dispScale }
    var pageX: CGFloat { (contentW - pageW) / 2 }

    /// 画板模式的每侧页边宽度（页宽的倍数）；关着就是 0 = 与画板模式之前逐字节同布局。
    var canvasMargin: Double { session.canvasMode ? canvasMarginState : 0 }
    /// 页边宽度的显示像素（每侧）。
    var marginPx: CGFloat { CGFloat(canvasMargin) * pageW }
    /// 笔迹落点的合法 x 区间（页内 0...1，画板模式放宽到页边）。
    var inkXRange: ClosedRange<Double> { CanvasMargin.xRange(margin: canvasMargin) }

    /// 给定页边宽度时的内容宽。`contentW` 与 `clampOffset` 共用一处公式，别再各写一遍。
    func contentWidth(margin m: Double) -> CGFloat {
        max(fitAvail, pageW * CGFloat(1 + 2 * m))
    }
    var paper: Color { nightMode ? Color(white: 0.10) : .white }
    /// 页与页之间/未实化区域的底色（比 paper 略深，同亮色下"纸张浮在浅灰底"的观感）。
    /// 夜间模式下若仍用系统默认底色（不随 nightMode 变——那是系统外观，与阅读区内切换是两回事），
    /// 未出图区域会露出一块亮色，本该全黑的场景变成"黑纸配白底"。
    var voidColor: Color { nightMode ? Color(white: 0.06) : Color(nsColor: .windowBackgroundColor) }

    var body: some View {
        imageRoutes(snipRoutes(canvasRoutes(editRoutes(surfaceBody))))
    }

    /// Edit 菜单路由（撤销/重做 + 框选选中集的剪切/粘贴/删除）单独包一层，理由同 `canvasRoutes`：
    /// `surfaceBody` 那条修饰符链早就到类型检查器的顶了。
    ///
    /// 认领条件都是「本窗口激活 **且** 没开草稿纸」——纸开着时这些动作归纸自己
    /// （`ScratchPadOverlay` 收同一批通知，对象是纸上的笔迹）。⌘C 例外：先给框选选中集，
    /// 没有选中集才退回「复制选中文字」的老行为，见 `surfaceBody` 里那条。
    private func editRoutes<V: View>(_ content: V) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .readerUndo)) { _ in
                if isActiveWindow, session.openPadID == nil { performUndo(redo: false) }
            }
            .onReceive(NotificationCenter.default.publisher(for: .readerRedo)) { _ in
                if isActiveWindow, session.openPadID == nil { performUndo(redo: true) }
            }
            .onReceive(NotificationCenter.default.publisher(for: .readerCut)) { _ in
                if isActiveWindow, session.openPadID == nil { cutLassoSelection() }
            }
            .onReceive(NotificationCenter.default.publisher(for: .readerPaste)) { _ in
                // 剪贴板里是笔迹就贴笔迹；否则是图片就贴成图片笔记（`ReaderSurface+ImageNote`）
                if isActiveWindow, session.openPadID == nil {
                    if InkClipboard.hasInk() { pasteInk() } else { pasteImageNote() }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .readerDelete)) { _ in
                if isActiveWindow, session.openPadID == nil { deleteLassoSelection() }
            }
    }

    /// 画板模式的两条 onChange 单独包一层。**别往 `surfaceBody` 上继续挂**——那条修饰符链早就到顶，
    /// 再加两个 onChange 就会「the compiler is unable to type-check this expression in reasonable time」
    /// （同 `snipRoutes` 与 ContentView 的 `mainSplit`/`eventRoutes` 分层，实测踩过）。
    private func canvasRoutes<V: View>(_ content: V) -> some View {
        content
            // 画板开/关：两个方向都走原子补偿（内容宽变、页面在屏幕上不动）
            .onChange(of: session.canvasMode) { _, on in canvasModeChanged(on) }
            // 笔画增删（本机落笔收尾、擦除、平板上行、框选提交）→ 重算页边软边界。
            // 用 count 而非整个数组：数组比较是每帧 O(总点数)，而边界只在「有笔画进出」时才可能变；
            // 同一笔被移到页外（count 不变）由 `commitLassoMove`/`commitLassoScale` 显式补一次。
            .onChange(of: session.strokes.count) { _, _ in refreshCanvasMargin() }
            // 平板发起的框选移动/缩放：笔画数不变，`AppModel.lassoApply` 递增这个计数器代替信号
            .onChange(of: session.inkMovedRev) { _, _ in refreshCanvasMargin() }
            // 平板正在写的那一笔（本机落墨在手势里已生长）：笔尖越界即跳档，别等抬笔
            .onChange(of: session.liveStroke?.points.count) { _, _ in growCanvasForLive() }
            // `unireader://open?note=…` 链接要求展开某条笔记的气泡（`DocSession.revealNoteID`）。
            // 挂在这一层同样是因为 `surfaceBody` 那条链再加一个 onChange 就超时（2026-09-14 实测）。
            .onChange(of: session.revealNoteID) { _, id in revealNote(id) }
    }

    /// 阅读区主体。**框选截图的手势与覆盖层单独包一层**（`snipRoutes`，见 `ReaderSurface+Snip`）——
    /// 这条修饰符链早就到顶了，再往上直接加会超类型检查器时限（ContentView 为同一个坑已经分了三层）。
    private var surfaceBody: some View {
        ScrollView([.vertical, .horizontal]) {
            contentBody
        }
        .background(voidColor)   // 页间空隙 / 未实化区域的底色，随夜间模式切换（否则露出系统默认亮底）
        // ⚠️ 关键：内容窄于容器(全窗宽)时，ScrollView 默认「水平居中」，居中内边距=(全窗宽−内容宽)/2 会被算进可滚区间
        //    → 把内容撑回全窗宽 > 真实视口(全窗宽−占位竖滚动条) → 常驻横条。靠首端对齐关掉居中；页面仍由 pageX 在内容内居中。
        .defaultScrollAnchor(.topLeading)
        .contentMargins(.top, indicatorTopInset, for: .scrollIndicators)   // 滚动条不进工具栏区
        .contentMargins(.bottom, indicatorBottomInset, for: .scrollIndicators)   // 也不钻到底部标签栏底下
        .scrollPosition($pos)
        .onScrollGeometryChange(for: GeoSnap.self) { g in
            GeoSnap(offsetX: g.contentOffset.x, offsetY: g.contentOffset.y,
                    containerW: g.containerSize.width, containerH: g.containerSize.height,
                    contentW: g.contentSize.width, contentH: g.contentSize.height,
                    insetTop: g.contentInsets.top, insetLeading: g.contentInsets.leading,
                    insetBottom: g.contentInsets.bottom, insetTrailing: g.contentInsets.trailing)
        } action: { _, new in
            ZoomProbe.measure("几何回调") { geometryChanged(new) }
        }
        .onContinuousHover(coordinateSpace: .local) { phase in
            switch phase {
            case .active(let p):
                scratch.cursorP = p
                if app.pointerTool == .ink && app.padMode == "erase" { eraseCursor = p }
            case .ended:
                scratch.cursorP = nil
                eraseCursor = nil
            }
        }
        // 缩放手势挂在 ScrollView 容器（而非内容层）→ 整个阅读区都能捏合：页间空隙、末页下方空白、
        // zoom<1 时页两侧留白皆可，不再限于 PDF 页面上。startLocation 为容器/视口坐标（与上方 .local 同空间）。
        .simultaneousGesture(magnify)
        // 文字选择拖选（T1）：与 magnify 同容器/同坐标系，鼠标拖拽与双指捏合互不干扰。
        .simultaneousGesture(dragSelectGesture)
        // 本机落墨（pointerTool == .ink 才生效，与拖选互斥门控）：Mac 鼠标/触控板直接画。
        .simultaneousGesture(localInkDragGesture)
        // 框选移动（pointerTool == .lasso 才生效，同上互斥门控）：虚线框选 + 拖选中区平移。
        .simultaneousGesture(lassoGesture)
        // 点注解图钉拖拽（textSelect 模式、起点命中图钉才激活，与拖选互斥让位）：页内调整注解位置。
        .simultaneousGesture(notePinDragGesture)
        // 单击：按下收回键盘焦点、抬手即收选区/框选、点高亮开/收操作气泡——全部抬手即响应，
        // 不走 `.onTapGesture(count: 1)`（那要等系统双击间隔确认「不是双击」，慢半秒）。
        .simultaneousGesture(readerClickGesture)
        // 双击选词：定位取光标最近位置（`.onContinuousHover` 维护），避免 SpatialTapGesture 与拖选/缩放争手势。
        // 双击落在高亮上：第一下已把气泡弹出来了，选词时顺手收掉（气泡与选区不该同时在）。
        // 第二下的抬手不会被上面的单击手势当成单击清掉（`isMultiClick`）。
        .onTapGesture(count: 2) {
            activeHighlight = nil
            // 双击在笔记卡片上不选底下的词（卡片正文本身不能选字）
            if let p = scratch.cursorP, cardHit(p) == nil { selectWord(atContainer: p) }
        }
        // 右键选区 → 「添加批注 / 复制」（原生上下文菜单，非浮层 hack）。菜单项常驻、无选区时禁用，
        // 避免按选区有无条件包裹 ScrollView 改变其身份而重置滚动位置。
        .contextMenu { readerContextMenu }
        // 批注编辑器（原生 .sheet）：新建或编辑同一入口。保存 → 改 session.textNotes（ContentView.onChange 落库）。
        .sheet(item: $editorTarget) { target in
            NoteEditorSheet(quote: target.quote, initialText: target.initialText,
                            initialTypeId: target.initialTypeId,
                            initialDisplay: target.initialDisplay,
                            initialColor: target.initialColor,
                            initialStyle: target.initialStyle,
                            hasRects: target.hasRects,
                            documentId: target.id.uuidString,
                            noteTypes: session.noteTypes,
                            usageCount: { id in session.textNotes.filter { $0.typeId == id }.count },
                            onSave: { saveEditor(target, $0) },
                            onDelete: target.editedNote == nil ? nil : { deleteEditorNote(target) },
                            onChangeTypes: { saveNoteTypes($0) },
                            onCancel: { editorTarget = nil })
        }
        .overlay(alignment: .topLeading) { followTicker }
        // 框选进行中的虚线自由路径（视口坐标，与 DragGesture .local 同空间；不随内容滚动——框选拖动中不滚动）。
        // 选区镜像给 MCP 也搭在这一层里（`DocSession.currentSelection` 是普通属性，写它不触发任何刷新）：
        // 🔴 不能再往主修饰符链上挂一个 `.onChange`——多一个就超类型检查器时限（2026-09-13 实测）。
        .overlay {
            ZStack {
                lassoDragOverlay
                boxSelectDragOverlay
                Color.clear.frame(width: 1, height: 1).allowsHitTesting(false)
                    .onChange(of: selection) { _, s in session.currentSelection = s }
            }
        }
        // 本机擦除的尺寸圆环（同挂 ScrollView 视口坐标系）：pointerTool==.ink 且 erase 模式跟光标，
        // 直径 = 2×eraserRadius×页宽；eraserRing 关则不画。
        .overlay { localEraserOverlay }
        // 草稿纸覆盖层：铺满视口盖住 PDF（**必须排在笔架之前**——笔架要浮在草稿纸之上，
        // 否则纸一开就够不着笔/橡皮/图层了）。它自己吃掉全部指针与滚轮事件，下面的阅读区
        // 手势另有 `session.openPadID == nil` 的显式门控兜底（见各 gesture）。
        .overlay { scratchPadLayer }
        // 笔架悬浮面板：挂在 ScrollView 本身（视口坐标系，不随内容滚动），跟 followTicker 同一个既有机制。
        .overlay { GeometryReader { proxy in PenRackView(session: session, viewportSize: proxy.size, topInset: indicatorTopInset, bottomInset: bottomInset, isActiveWindow: isActiveWindow) } }
        // 只观察**别处**发来的锚点：本机滚动每帧发的 `"mac"` 锚点不写 `foreignAnchor`，
        // 于是滚动不再把整扇窗标脏（红线见 `DocSession.scrollAnchor`）。`incomingAnchor`
        // 本来就要 `origin != "mac"`，语义完全一致。
        .onChange(of: session.foreignAnchor) { _, a in incomingAnchor(a) }
        .onChange(of: app.pointerTool) { _, t in
            if t != .lasso { clearLassoSelection() }   // 切走框选工具即放弃选中（手势已门控，残留高亮框会误导）
            if t != .ink { eraseCursor = nil }         // 切走本机笔即撤擦除圆环
            if t != .textSelect { activeHighlight = nil }   // 高亮气泡是文字工具下的东西，切走就收
        }
        .onChange(of: app.padMode) { _, m in
            if m != "erase" { eraseCursor = nil }      // 离开擦除模式同上
        }
        .onChange(of: nightMode) { _, new in
            scratch.nightLive = new   // 先同步引用侧实时值（键计算全走它），再触发原地反转
            scheduleNightRender()
        }
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
        .onChange(of: isActiveWindow) { _, v in
            scratch.isActiveWindow = v
            // 活跃与否决定实化范围（后台窗口只留可见页，见 `updateRealized`），换了就重算一次。
            if let layout, scratch.didInitialGeo, !isZooming { updateRealized(scratch.geo, layout: layout) }
        }
        .onChange(of: session.ocrEnabled) { _, on in if on { session.enqueueOCR(Array(realized)) } }
        .onAppear {
            scratch.isActiveWindow = isActiveWindow
            // 关窗 teardown 要替本阅读区清 wanted、放监视器（见 `DocSession.renderClients`）。
            // 🔴 闭包只捕获 `scratch`（类），不能捕获 self——否则会话又攥住一份视图拷贝。
            session.renderClients[scratch.clientID] = { [scratch] in scratch.releaseRetainers() }
            setup()
            installWheelMonitor()
            installLassoEscMonitor()
            installToolKeyMonitor()
            // 切文档重建后补跑一次首帧几何求值：onScrollGeometryChange 可能不重发，靠 onAppear(layout 就绪)
            // + fullWidth/unobSize 的 onChange 三路兜底，任一到位即定基准（防新文档首屏空白、须拖窗口才出）。
            if !scratch.didInitialGeo { geometryChanged(scratch.geo) }
        }
        .onDisappear {
            follower.reset()
            // 三个监视器 + 两个防抖闭包一起放（它们都攥着视图拷贝，见 `Scratch.releaseRetainers`）。
            scratch.releaseRetainers()
            // 先销账再交图：本视图的持有量一销，缓存额度才腾得出来接住交回去的图（顺序见 `handOffImagesToCache`）。
            PageHoldings.shared.remove(client: scratch.clientID)
            // 本阅读区不再声明任何 wanted。**必须排在 `releaseRenderCache` 之前**：引擎的 `purge(doc:)`
            // 靠「还有没有窗口声明要这份文档的键」判断，自己的还挂着就会把自己当成「别的窗口」而跳过。
            // （这一句 2026-09-10 前根本不存在——上面那段注释写着「必须排在 setWanted([]) 之后」，
            // 调用本身却在窗口层迁移时丢了；关窗后缓存里的页图从此一张都清不掉。）
            PageRenderEngine.shared.setWanted([], client: scratch.clientID)
            session.renderClients.removeValue(forKey: scratch.clientID)
            releaseRenderCache()
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
        // Edit 菜单 Copy / Select All（UniReaderApp 接管 .pasteboard 组后路由过来）。
        // ⌘C 一键两用：有框选选中集就复制笔迹/注解，没有才退回复制选中文字。
        .onReceive(NotificationCenter.default.publisher(for: .readerCopy)) { _ in
            guard isActiveWindow, session.openPadID == nil else { return }   // 纸开着 = 归纸
            if !copyLassoSelection() { copySelectionToPasteboard() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .readerSelectAll)) { _ in
            if isActiveWindow { selectAllText() }
        }
    }

    // MARK: 内容（自研虚拟化：精确总尺寸 + 只实化窗口内页）

    @ViewBuilder var contentBody: some View {
        if let layout, scratch.didInitialGeo {   // 未定基准前只占位空白（防启动窄宽渲染 → 闪烁）
            // 逐页数据整帧算一次（见 PageBuckets 注释）：旧写法每页各跑一遍全数组过滤，缩放每帧重算 body 时是掉帧大头。
            let buckets = PageBuckets(session: session, range: realized)
            let _ = ZoomProbe.frame(realized: realized)   // 探针：这一帧阅读区内容重算了（默认关，零开销）
            let _ = reportHoldings()                       // 台账：本窗口此刻攥着几张页图（设置页诊断 + 缓存让额度）
            let _ = traceOpenFrame(layout: layout, buckets: buckets)   // 打开耗时：可见页范围 + 各页笔数（有账才记）
            ZStack(alignment: .topLeading) {
                ForEach(Array(realized), id: \.self) { i in
                    pageCell(i, layout: layout, buckets: buckets)
                }
                lassoStrokeHalo  // 框选选中笔迹的光晕边缘（内容坐标，置于页元胞之上，随 ghost 变换）
                lassoHighlight   // 框选选中项高亮框 + 四角缩放手柄 + 移动/缩放 ghost（内容坐标）
            }
            .frame(width: contentW, height: contentH, alignment: .topLeading)
            .transaction { $0.animation = nil }   // 零闪烁纪律 4：阅读区无隐式动画
        } else {
            Color.clear.frame(width: 10, height: 10)
        }
    }

    /// 单页元胞构造。抽成独立函数（而非内联进 ForEach）——参数众多，内联会让 SwiftUI 类型检查器超时。
    @ViewBuilder func pageCell(_ i: Int, layout: PageLayout, buckets: PageBuckets) -> some View {
        PageCellView(size: CGSize(width: pageW, height: layout.heights[i] * dispScale),
                     image: images[i],
                     tile: tiles[i],
                     paper: paper,
                     strokes: inkWanted(i, layout: layout) ? (buckets.strokes[i] ?? []) : [],
                     live: session.liveStroke?.page == i ? session.liveStroke : nil,
                     hover: session.hover?.page == i ? session.hover : nil,
                     inkScale: zoom,
                     selectionRects: selection?.rects[i] ?? [],
                     matchRects: buckets.matchRects[i] ?? [],
                     activeMatchRects: buckets.activeMatch?.page == i ? (buckets.activeMatch?.rects ?? []) : [],
                     matchPulse: buckets.activeMatch?.page == i ? matchPulseT : 1,
                     highlights: buckets.highlights[i] ?? [],
                     activeHighlight: session.openPadID == nil ? activeHighlight : nil,   // 草稿纸盖着时不弹（纸归纸）
                     onDismissHighlight: { activeHighlight = nil },
                     onDeleteHighlight: { deleteHighlight($0) },
                     onRecolorHighlight: { recolorHighlight($0, color: $1) },
                     onRestyleHighlight: { restyleHighlight($0, style: $1) },
                     onNoteFromHighlight: { beginNoteFromHighlight($0) },
                     notes: buckets.notes[i] ?? [],
                     noteTypes: session.noteTypes,
                     ocrBlocks: session.showOCRBlocks ? (session.ocrVisibleRuns(page: i) ?? []) : [],
                     ocrGroups: session.showOCRBlocks && session.ocrBlockGrouped ? session.ocrGroups(page: i) : [],
                     ocrWatermarks: session.showOCRBlocks ? session.ocrWatermarkRuns(page: i) : [],
                     radial: session.radial?.page == i ? session.radial : nil,
                     pens: app.pens,
                     pressRing: session.pressRing?.page == i ? session.pressRing : nil,
                     hoverD: app.padMode == "erase" && app.eraserRing ? app.eraserRadius * 2 * pageW : 10,
                     onOpenNote: { editorTarget = .edit($0) },
                     expandedNotes: expandedNotes,
                     hoverNote: hoveredNote,
                     onToggleNote: { n in
                         if expandedNotes.contains(n.id) { expandedNotes.remove(n.id) }
                         else { expandedNotes.insert(n.id) }
                     },
                     onHoverNote: { id, inside in
                         if inside { hoveredNote = id } else if hoveredNote == id { hoveredNote = nil }
                     },
                     noteDrag: notePinDrag,
                     imageNotes: buckets.imageNotes[i] ?? [],
                     imageInfo: { workspace.imageInfo(sha256: $0) },
                     onOpenImageNote: { imageEditor = $0 },
                     onToggleImageNote: { n in
                         if expandedNotes.contains(n.id) { expandedNotes.remove(n.id) }
                         else { expandedNotes.insert(n.id) }
                     },
                     onViewImageNote: { imageViewer = $0 },
                     onDeleteImageNote: { deleteImageNote($0) },
                     cardsInteractive: app.pointerTool == .textSelect && session.openPadID == nil,
                     onCard: { commitCard($0, card: $1, zone: $2) },
                     onCardFrame: { id, page, rect in scratch.cardFrames[id] = rect.map { (page, $0) } },
                     bubbleFollowsZoom: bubbleFollowsZoom,
                     bubbleFontSize: CGFloat(bubbleFontSize),
                     bubbleMinWidth: CGFloat(bubbleMinWidth),
                     bubbleMaxWidth: CGFloat(bubbleMaxWidth),
                     scratchPins: buckets.scratchPins[i] ?? [],
                     onOpenScratchPad: { session.openPadID = $0 },
                     onCopyScratchLink: { copyLinkToPasteboard(page: i, frac: $1) },
                     bookmarks: buckets.bookmarks[i] ?? [],
                     onRenameBookmark: { session.beginBookmarkRename($0) },
                     onDeleteBookmark: { session.deleteBookmark(id: $0.id) },
                     onCopyBookmarkLink: { copyLinkToPasteboard(note: $0.id) },
                     onCopyNoteLink: { copyLinkToPasteboard(note: $0.id) },
                     inkMargin: marginPx,
                     inkFast: inkFastDraw,
                     pageIndex: i,
                     docKey: docKey,
                     inkSnapshot: inkFastDraw ? inkSnaps[i] : nil)
            .offset(x: pageX, y: layout.offsets[i] * dispScale)
    }

    /// 帧驱动（跟随器 / 缩放动画任一激活即挂载；TimelineView(.animation) 与刷新率同步）。
    @ViewBuilder var followTicker: some View {
        if follower.isActive || zoomAnimOn || matchPulseOn {
            TimelineView(.animation) { tl in
                Color.clear
                    .frame(width: 1, height: 1)
                    .onChange(of: tl.date) { _, _ in
                        if follower.isActive { followStep() }
                        if zoomAnimOn { ZoomProbe.measure("动画帧") { zoomAnimStep() } }
                        if matchPulseOn { matchPulseStep() }
                    }
            }
            .allowsHitTesting(false)
        }
    }

    /// 草稿纸覆盖层（开着才挂载）。`.id(pad.id)` 让切换草稿纸 = 全新视口状态，不带着上一张的缩放滚动。
    /// 外面套一层 ZStack + `.animation(value:)`：开/关不再是硬切，而是 0.16s 的淡入淡出 + 极轻微缩放
    /// （硬切在「盖住整个阅读区」这种大面积变化上特别刺眼）。
    /// ⚠️ 动画**只作用在这一层**，不会渗进 `contentBody`——阅读区的零闪烁纪律是「无隐式动画」。
    @ViewBuilder var scratchPadLayer: some View {
        ZStack {
            if let pad = session.openPad,
               let idx = session.scratchPads.firstIndex(where: { $0.id == pad.id }) {
                ScratchPadOverlay(session: session, pad: pad, padIndex: idx,
                                  topInset: indicatorTopInset, docKey: docKey, voidColor: voidColor)
                    .id(pad.id)
                    .transition(.opacity.combined(with: .scale(scale: 0.99)))
            }
        }
        .animation(.easeOut(duration: 0.16), value: session.openPadID)
    }

    /// 本机擦除的尺寸圆环（pointerTool == .ink 且 erase 模式）：跟随光标（`eraseCursor`，
    /// `.onContinuousHover` 维护的视口坐标），直径 = 2×eraserRadius×当前页宽；`eraserRing` 关则不画。
    @ViewBuilder var localEraserOverlay: some View {
        if app.eraserRing, let p = eraseCursor {
            Circle()
                .stroke(Color.accentColor, lineWidth: 1.5)
                .frame(width: app.eraserRadius * 2 * pageW, height: app.eraserRadius * 2 * pageW)
                .position(p)
                .allowsHitTesting(false)
        }
    }

    // MARK: 生命周期

    /// 阅读区销毁时的页图收尾。**必须排在 `setWanted([])` 之后**——引擎靠「还有没有窗口声明要
    /// 这份文档的键」判断该不该清，顺序反了会把自己当成"还在看"而跳过。多窗口开同一份文档时，
    /// 别的窗口的 wanted 还在，这次清理会被正确跳过。
    ///
    /// 🔴 **「本视图销毁」≠「不再看这份文档」——多标签之后这条前提就不成立了**
    /// （2026-08-29 实测定位，「切标签有加载感」的真凶，与阅读区快照那套毫无关系）：
    /// 切到别的标签只是把这个阅读区拆了（外层 `.id(docKey)`），文档还在后台标签里开着，
    /// 切回来还要用这批图。照旧清的话，每次切回来都得从头重渲一整屏 = 必然的加载感。
    /// 真正该清的时机是**这篇文档不再被任何会话持有**：关标签 / 关窗（`DocSession.teardown`
    /// 里另有一次清理兜底）、或本标签换了文档（那时会话的 `contentHash` 已经是新的了）。
    ///
    /// （抽成方法而不是内联在 `onDisappear` 里：那条修饰符链早就到顶，多两行就
    /// 「unable to type-check in reasonable time」——本文件的老地雷。）
    func releaseRenderCache() {
        let stillOpen = app.sessions.contains { $0.displayKey == docKey }
        guard !stillOpen else {
            // **切到后台的标签**：图要留着（切回来靠它零加载），但只留**当前这一档宽度**。
            // 🔴 原样全留是不行的（2026-08-29 实测：3 个标签用一阵子 footprint 1617MB、峰值 1919MB）——
            // 缩放每停一档就攒下一整套页图，几个标签各攒几档就是几百 MB。而且原来那句 `purge`
            // 顺带干的第二件事**同样重要**：`relieveMallocPressure` 催 malloc 把释放的大块真正还给
            // 系统，去掉它 `MALLOC_LARGE` 就一路挂着不降（见 `PageRenderEngine` 那段注释）。
            // 屏幕上这套图先交回缓存：它们多半已不在缓存里（额度让给了视图持有量），不交就是真丢，
            // 切回来 `seedImages` 一张都取不到 = 重渲一整屏。
            handOffImagesToCache()
            PageRenderEngine.shared.purgeBase(doc: docKey, keeping: scratch.basePixelW)
            return
        }
        PageRenderEngine.shared.purge(doc: docKey)
    }

    func setup() {
        guard let pdf = session.pdf else { return }
        // 布局缓存在会话上：切标签重建时不必再遍历全部页取尺寸（`init` 的种子也读它）。
        let lay: PageLayout
        // 库里有这份内容的每页高度（`page_geom`）就一行读完，不用遍历 340 页 `page.bounds`
        //（冷的外置盘上那是 ~100ms，账本 `布局计算 96(316页)`）。
        var fromStore: [Double]?
        // 开着扫描页对齐：页高直接由参数表算（对齐后页宽统一），不碰 `page_geom`——那张表存的是原始页面的高
        let align = session.scanAlign
        if session.cachedLayout == nil, align == nil, let store = session.store, !session.contentHash.isEmpty {
            let hash = session.contentHash, n = pdf.pageCount
            fromStore = session.openTrace.phase("布局读库") { try? store.pageHeights(contentHash: hash, pageCount: n) }
        }
        if let cached = session.cachedLayout {
            lay = cached
            session.openTrace?.markOnce("布局", "缓存命中")
        } else if let align {
            lay = PageLayout(heights: align.heights(refWidth: Double(PageLayout.refWidth)).map { CGFloat($0) })
            session.openTrace?.markOnce("布局", "对齐参数")
        } else if let hs = fromStore {
            lay = PageLayout(heights: hs.map { CGFloat($0) })
            session.openTrace?.markOnce("布局", "库缓存")
        } else {
            lay = session.openTrace.phase("布局计算", detail: "\(pdf.pageCount)页") { PageLayout(doc: pdf) }
            session.openTrace?.markOnce("布局", "算完")
            // 回填缓存（后台写：一次事务一次 fsync，冷盘几十毫秒，别卡这里）
            if let store = session.store, !session.contentHash.isEmpty {
                let hash = session.contentHash, hs = lay.heights.map { Double($0) }
                Task.detached(priority: .utility) { try? store.savePageHeights(contentHash: hash, heights: hs) }
            }
        }
        session.cachedLayout = lay
        // 种子种下的页图也入账（它们在 init 里就到位了，是「切回来零加载」的那一份）。
        if seededFromSnapshot, let tr = session.openTrace {
            for (p, img) in images where img.width == scratch.basePixelW {
                tr.noteImage(page: p, width: scratch.basePixelW, source: "种子")
            }
        }
        layout = lay
        follower.pageCount = lay.pageCount
        follower.interpEnabled = interpEnabled
        scratch.nightLive = nightMode     // 引用侧实时值（键计算唯一真源，见 baseKey 注释）
        scratch.imagesNight = nightMode   // 首批渲染直接用当前夜间键出图，与本地显示模式对齐
        scratch.appearAt = CACurrentMediaTime()
        // 页边软边界的首值（首帧没有几何可补偿，直接置；笔迹后到由 strokes.count 的 onChange 兜底）。
        // `inkOverflow()` = 库里算出的全篇首值 ∨ 窗口内实扫——内存里只有窗口内的笔迹（`InkWindow`）。
        canvasMarginState = CanvasMargin.margin(overflow: session.inkOverflow())
        // 这条路径绕开了 `applyCanvasMargin`，得自己把广播用的那个数对齐（否则新客户端连上来
        // 收到的还是 `canvasMarginLive` 的初值 step，页边比 Mac 这边窄，远处的笔迹被裁掉）。
        session.canvasMarginLive = session.canvasMode ? canvasMarginState : 0

        // 切标签回来：基准/缩放/实化窗口/页图/滚动位置已由 `init` 的 `@State` 初值种好
        // （赶在首帧之前，见那里的红线）。这里只把「待种」标记用掉，并补一次滚动位置的校验重试。
        if seededFromSnapshot {
            session.readerSeedPending = false
            scratch.pendingZoom = zoom
            if let off = scratch.seedOffset {
                // 🔴 **必须显式滚一次**（2026-08-29 用户报「切 tab 进度没恢复」的根因）：
                //  · `ScrollPosition` 的**初值**（init 里种的那个）不保证被采纳；
                //  · `verifyPendingTarget` 那套兜底重试是**几何回调驱动**的，而页面停着不动
                //    就不会再有几何回调 —— 光挂一个 `pendingTarget` 等于永远不重试。
                // 于是这里主动提交一次，未达再由既有的校验环重试（同 runloop 原子提交见其注释）。
                pos.scrollTo(point: off)
                scratch.pendingTarget = off
                scratch.pendingTries = 0
            }
            return
        }

        scratch.pendingZoom = session.restoreZoom   // 上次缩放：首帧定 fitBasis 后套用（见 geometryChanged）
        scratch.pendingHFrac = session.restoreHFrac > 0.0001 ? session.restoreHFrac : nil   // 横向恢复
        // fitBasis 由首帧 geometryChanged 设定（此处不预设，避免与真实值有偏差）
        // 视图创建前就已发出的 restore/toc 锚点（loadSelected 先 emit 后建视图）
        if let a = session.scrollAnchor, a.origin != "mac" {
            scratch.pendingRestore = a
            lastAppliedSeq = a.seq
        }
        // 视图创建前就到的「展开这条笔记」请求（链接开文档：`DeepLinkRouter` 先置、视图后建），同上补取。
        revealNote(session.revealNoteID)
    }

    /// 应 `unireader://open?note=…` 之请把气泡展开（`DocSession.revealNoteID`）。取走即清，
    /// 下一条同 id 的请求才能再触发 `onChange`。id 不是本文档的笔记也无妨——`expandedNotes` 里多一个
    /// 没人查的 id 什么都不显示。
    func revealNote(_ id: UUID?) {
        guard let id else { return }
        expandedNotes.insert(id)
        session.revealNoteID = nil
    }

}
