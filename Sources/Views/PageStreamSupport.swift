import SwiftUI

/// 被点开的那条文字高亮 + **被点中的那一行**（页内归一化框）。
/// 存行框而不是整条高亮的包围盒：跨行高亮的包围盒可能有半页高，从它底下弹删除气泡离手指老远。
struct HighlightTap: Equatable {
    let id: UUID
    let rect: CGRect
}
import PDFKit
import QuartzCore
import AppKit

extension Notification.Name {
    static let readerZoomIn = Notification.Name("com.xvan.UniReader.readerZoomIn")
    static let readerZoomOut = Notification.Name("com.xvan.UniReader.readerZoomOut")
    static let readerZoomFit = Notification.Name("com.xvan.UniReader.readerZoomFit")
    static let readerZoomActual = Notification.Name("com.xvan.UniReader.readerZoomActual")
    static let readerCopy = Notification.Name("com.xvan.UniReader.readerCopy")
    static let readerSelectAll = Notification.Name("com.xvan.UniReader.readerSelectAll")
    // 编辑（Edit 菜单里没人接时路由给阅读区/草稿纸；对象都是**框选选中集**，见 `ReaderSurface+InkClip`）
    static let readerCut = Notification.Name("com.xvan.UniReader.readerCut")
    static let readerPaste = Notification.Name("com.xvan.UniReader.readerPaste")
    static let readerDelete = Notification.Name("com.xvan.UniReader.readerDelete")
    static let readerUndo = Notification.Name("com.xvan.UniReader.readerUndo")
    static let readerRedo = Notification.Name("com.xvan.UniReader.readerRedo")
    // 图片笔记：Inspector 那边点「编辑 / 查看」→ 阅读区弹 sheet（编辑器与看大图的 @State 都在 `ReaderSurface`）。
    // `object` = `ImageNoteRequest`（会话 id + 笔记 id），非本会话的窗口不认领。
    static let imageNoteEdit = Notification.Name("com.xvan.UniReader.imageNoteEdit")
    static let imageNoteView = Notification.Name("com.xvan.UniReader.imageNoteView")
}

/// `imageNoteEdit` / `imageNoteView` 通知的载荷。
struct ImageNoteRequest {
    var sessionID: UUID
    var noteID: UUID
}

// MARK: - 内部实现

/// 滚动几何快照（只存标量，Equatable 供 onScrollGeometryChange 去重）。
struct GeoSnap: Equatable {
    var offsetX: CGFloat = 0, offsetY: CGFloat = 0
    var containerW: CGFloat = 0, containerH: CGFloat = 0
    var contentW: CGFloat = 0, contentH: CGFloat = 0
    var insetTop: CGFloat = 0, insetLeading: CGFloat = 0
    var insetBottom: CGFloat = 0, insetTrailing: CGFloat = 0
}

/// 高倍清晰贴片：normRect = 页内归一化区域（0~1，左上原点）→ 显示时 × 页尺寸，随缩放拉伸。
struct PageTile: Equatable {
    var normRect: CGRect
    var image: CGImage
}

/// 一次文字选择的结果（T1）：逐页归一化行框/行内片段框（画高亮）+ 选中纯文本（⌘C 复制）。
/// 归一化 0~1 左上原点 → 随页尺寸自适应，缩放/滚动免重算；原生页由 PDFKit 选择引擎产出，OCR 页由 `OCRTextSelect` 行内字符级裁剪产出。
struct TextSelection: Equatable {
    var rects: [Int: [CGRect]]   // page → 该页归一化行框（OCR 选区首末行可能是行内片段框）
    var text: String
}

/// 「添加批注」草稿：右键选区触发，捕获选区起始页 + 归一化锚点/行框 + 原文，待编辑器填批注后落成 `TextNote`。
struct PendingNote: Identifiable {
    let id = UUID()
    var page: Int
    var anchor: CGRect       // 归一化包围盒 0~1（页局部）
    var rects: [CGRect]      // 选区逐行归一化框（页局部）
    var quote: String        // 选中原文
}

/// 批注编辑器目标：新建（选区草稿）或编辑（已存在注解）。统一走一个 `.sheet(item:)`，避免多 sheet 竞态。
enum NoteEditorTarget: Identifiable {
    case new(PendingNote)
    case edit(TextNote)

    var id: UUID {
        switch self {
        case .new(let p): return p.id
        case .edit(let n): return n.id
        }
    }
    var quote: String {
        switch self {
        case .new(let p): return p.quote
        case .edit(let n): return n.quote
        }
    }
    var initialText: String {
        switch self {
        case .new: return ""
        case .edit(let n): return n.text
        }
    }
    var initialTypeId: UUID? {
        switch self {
        case .new: return nil
        case .edit(let n): return n.typeId
        }
    }
    /// 展开方式：新建按默认（tap），编辑取这条笔记自己的。
    var initialDisplay: NoteDisplay {
        switch self {
        case .new: return .tap
        case .edit(let n): return n.display
        }
    }
    /// 编辑已存在注解时才给「删除」入口（新建草稿没有可删的东西）。
    var editedNote: TextNote? {
        if case .edit(let n) = self { return n }
        return nil
    }
}

/// 框选移动（pointerTool == .lasso，仅页内）的选中集：同页笔迹 id + 文字注解 id + 联合包围盒
/// （页内归一化 0~1，画高亮框/ghost 与命中「拖选中区」用）。**瞬态**（ReaderSurface @State，随窗口），不持久化。
struct LassoSelection: Equatable {
    var page: Int
    var strokeIDs: Set<UUID>
    var noteIDs: Set<UUID>
    var bounds: CGRect
}

/// 进行中的框选手势形态：拖空白 = 重新框选（自由路径虚线）；拖选中高亮框内 = 移动选中项（ghost 预览）；
/// 拖手柄 = 缩放（ghost 预览：**角手柄 = 等比**（⇧ 临时自由两轴）、**边中点手柄 = 单轴**；anchor = 对角/对边中点）。
enum LassoDragMode: Equatable {
    case select, move, scale(LassoHandle)
}

/// 高亮框缩放手柄：四角（等比缩放）+ 四边中点（单轴缩放）。
enum LassoHandle: Equatable, CaseIterable {
    case tl, tr, bl, br, t, b, l, r

    var isCorner: Bool {
        switch self {
        case .tl, .tr, .bl, .br: return true
        case .t, .b, .l, .r: return false
        }
    }

    /// 手柄在 rect 上的点（角 / 边中点）。
    func point(in r: CGRect) -> CGPoint {
        switch self {
        case .tl: return CGPoint(x: r.minX, y: r.minY)
        case .tr: return CGPoint(x: r.maxX, y: r.minY)
        case .bl: return CGPoint(x: r.minX, y: r.maxY)
        case .br: return CGPoint(x: r.maxX, y: r.maxY)
        case .t:  return CGPoint(x: r.midX, y: r.minY)
        case .b:  return CGPoint(x: r.midX, y: r.maxY)
        case .l:  return CGPoint(x: r.minX, y: r.midY)
        case .r:  return CGPoint(x: r.maxX, y: r.midY)
        }
    }

    /// 对侧手柄（缩放 anchor：角的对角 / 边的对边中点）。
    var opposite: LassoHandle {
        switch self {
        case .tl: return .br
        case .tr: return .bl
        case .bl: return .tr
        case .br: return .tl
        case .t:  return .b
        case .b:  return .t
        case .l:  return .r
        case .r:  return .l
        }
    }
}

/// 一帧内共享的逐页数据分桶。
/// `pageCell` 原本对每一实化页各跑一遍全数组 `filter`（笔迹/命中/高亮/注解），
/// 取笔迹更是每页重建一次图层序字典 + 全量排序 → 整体 O(页数 × 条目数)。
/// 缩放**每帧**都重算 body，这份开销随文档笔记量线性放大，是按钮缩放掉帧的主因之一。
/// 改为整帧算一次（O(条目数)）、逐页 O(1) 取。
struct PageBuckets {
    var strokes: [Int: [InkStroke]] = [:]
    var matchRects: [Int: [CGRect]] = [:]
    var highlights: [Int: [Highlight]] = [:]
    var notes: [Int: [TextNote]] = [:]
    /// 本窗口内各页的图片笔记（kind=6，`IMAGE-NOTE-PLAN.md`）。
    var imageNotes: [Int: [ImageNote]] = [:]
    /// 本窗口内各页的草稿纸图钉（id + 页内归一化位置 + 显示名）。
    var scratchPins: [Int: [(id: UUID, nx: Double, ny: Double, name: String)]] = [:]
    /// 本窗口内各页的书签（页边小旗标；`REQUIREMENTS.md §1.9`）。
    var bookmarks: [Int: [Bookmark]] = [:]
    var activeMatch: TextMatch?

    init(session: DocSession, range: ClosedRange<Int>) {
        strokes = session.visibleStrokesByPage(in: range)
        for m in session.searchMatches where range.contains(m.page) {
            matchRects[m.page, default: []].append(contentsOf: m.rects)
        }
        for h in session.highlights where range.contains(h.page) {
            highlights[h.page, default: []].append(h)
        }
        for n in session.textNotes where range.contains(n.page) {
            notes[n.page, default: []].append(n)
        }
        for n in session.imageNotes where range.contains(n.page) {
            imageNotes[n.page, default: []].append(n)
        }
        for (i, p) in session.scratchPads.enumerated() where range.contains(p.anchorPage) {
            scratchPins[p.anchorPage, default: []].append(
                (p.id, p.anchorX, p.anchorY, p.displayName(index: i)))
        }
        for b in session.bookmarks where range.contains(b.page) {
            bookmarks[b.page, default: []].append(b)
        }
        activeMatch = session.currentMatchIndex.flatMap {
            session.searchMatches.indices.contains($0) ? session.searchMatches[$0] : nil
        }
    }
}

/// 捏合手势状态。锚点数学：屏幕不动点 P（相对容器原点）+ 内容锚点 c；
/// 逐帧 commit：c' = c×r，目标偏移 = c' − P（同 runloop 提交 = 屏幕原子，scroll-x-probe T3b）。
/// 放大/缩小都走真 commit：滚动条在内容超过容器的瞬间即出现（Preview 同款），无松手悬崖。
struct PinchInfo {
    var startZoom: CGFloat
    var viewportP: CGPoint     // 锚点相对容器原点（屏幕不动点）
    var cCur: CGPoint          // 当前布局下的锚点内容坐标（每次 commit 后更新）
}

/// 命令式缩放动画（工具栏按钮 / ⌘± / ⌘0 / 1:1）：**log 空间匀速直线**，定时长
/// （`ReaderSurface.zoomAnimDuration`），每帧走与 pinch 相同的「布局+scrollTo 同 runloop 原子 commit」。
///
/// 🔴 **不许再往回加缓动**（smoothstep / spring / ease-*）——用户 2026-09-02 定：「就线性的就好了，
/// 不要弹性」。这条曾来回过三版，各自的死因都在这儿写着，别再走一遍：
///  · **0.22s smoothstep**（最早）：起止速度都是 0，**连点第二下把速度重置为 0 再加速**，一跳一跳。
///    （当轮 `ZoomProbe` 日志证明帧一点没掉：145~175fps、首帧延迟 1~3ms —— 问题从来不在性能，在曲线。）
///  · **指数趋近 tau=0.13**：连点顺了，但「起步最快、尾巴无限长」，一步 1.25× 要 750ms 才收敛，
///    观感是猛地一下然后黏很久。
///  · **临界阻尼弹簧**：S 形、零过冲，但那份加减速就是用户说的「弹性」。
///
/// 匀速为什么不会有 smoothstep 那个毛病：线性没有「起步阶段」，连点只是从当前位置换一条新斜率，
/// 位置连续、速度也只是台阶式变化，看不出跳。
/// 而**在 log 空间匀速**是因为缩放是乘性量：倍率上做算术插值看着「先快后慢」（1→2 前半程涨 50%、
/// 后半程只涨 33%），每帧乘同一个系数才是眼睛看到的匀速。
struct ZoomAnim {
    var target: CGFloat        // 目标缩放（连点时就地更新，不重建动画）
    var anchorP: CGPoint       // 屏幕不动点（容器坐标）
    var cCur: CGPoint          // 当前布局下的锚点内容坐标（每帧按比率更新，同 `PinchInfo.cCur`）
    var lastT: CFTimeInterval  // 上一帧时刻（算 dt；掉帧时 dt 被钳住，不会一步跨过头）
    var from: CGFloat          // 本段起点倍率（连点时就地换成"当前值"，见 `animateZoom`）
    var progress: CGFloat = 0  // 0…1，**匀速**推进（线性，不做任何缓动）
    var fitAfter: CGFloat?     // 非 nil（⌘0）：动画到位后 fitBasis 重定标为该值、zoom 归 1（pageW 不变，零跳变）
}

/// 每帧变化但不应触发 body 重算的暂存（引用类型，@State 持有其身份）。
final class Scratch {
    /// 阅读区的 `@State` 存储盒是否真的放了（页图字典跟它同生死）：关窗/切标签后看这一行来不来
    /// （`touch ~/Library/Logs/UniReader-ws.log`）。没来 = 又有谁攥着视图拷贝，见 `releaseRetainers`。
    deinit { wsLog("阅读区状态释放（页图已放）") }

    var geo = GeoSnap()
    var topDocY: CGFloat = 0
    var basePixelW = 0
    /// 本窗口最近用过的基图像素宽（最新在前，最多 4 个）。目标宽度的图还没渲出来时，
    /// 按这个顺序去缓存里找"这一页以前渲过的图"先顶上，避免白纸（见 `fallbackBase`）。
    var recentBaseWidths: [Int] = []
    var lastEmitAt: CFTimeInterval = 0
    var lastEmitted: (page: Int, frac: Double)?
    var suppressEmitUntil: CFTimeInterval = 0
    var pendingTarget: CGPoint?
    var pendingTries = 0
    var settleWork: DispatchWorkItem?
    var resizeWork: DispatchWorkItem?
    var pinch: PinchInfo?
    var lastPinchCommitAt: CFTimeInterval = 0   // 捏合提交限流（~60Hz，见 pinchChanged）
    var zoomAnim: ZoomAnim?        // 进行中的命令式缩放动画（pinch/⌘wheel 介入即取消）
    var pendingRestore: ScrollAnchor?
    var pendingZoom: CGFloat = 1           // 待恢复的缩放倍率（首帧定基准后套用）
    /// 当前 `zoom` 是「从库里恢复来的倍率」而非用户手动缩的。启动稳定窗内窗口宽度落位时，它必须按
    /// **新的 fit 基准重算倍率**（存的是相对 fit 的倍数），不能走 refit 的「尺寸保持」把首帧那个瞬态
    /// 宽度对应的**绝对页宽**锁死——那正是「上次缩放没恢复」的根因，见 `refitToViewport`。
    /// 用户一动缩放（捏合/⌘±/⌘0/⌘滚轮）即清零，之后一律按手动缩放的既有语义走。
    var zoomFromRestore = false
    var pendingHFrac: CGFloat?             // 待恢复的横向滚动比例（首帧定位后一次性套用，nil=无）
    var lastRefitFullW: CGFloat = 0        // 上次 refit 时的全宽（区分窗口缩放 vs 侧栏/Inspector 开合）
    var appearAt: CFTimeInterval = 0       // 视图出现时刻：启动稳定窗内宽度变化一律真 fit（防瞬态宽被锁死）
    var didInitialGeo = false
    /// 切标签种子算出的滚动偏移（`ReaderSurface.init` 写、`setup` 读着提交一次）。
    var seedOffset: CGPoint?
    var didFirstKick = false
    /// 打开耗时账本：本次打开里阅读区 body 跑了几次（`traceOpenFrame` 记前 12 次）。
    var traceBodies = 0
    /// 视图层**允许留图**的页范围（实化窗口 ± 余量，`updateRealized` 维护）。渲染完成回调按它守门：
    /// 快滚时发出去的请求会在页早已滚出窗口之后才完成，不守门就写进 `images`，要等下一次窗口变动
    /// 才被驱逐——空闲窗口里就一直挂着（2026-09-10 三窗口实测的「账外」页图来源之一）。
    /// 放 `Scratch` 而不是读 `realized`：逃逸闭包捕获的是 struct 拷贝，@State 读出来可能是旧值。
    var keepRange: ClosedRange<Int> = 0...Int.max
    var cursorP: CGPoint?              // 光标在滚动容器坐标里的位置（⌘wheel 缩放锚点 / 双击选词定位；域外为 nil）
    var selDragAnchor: (page: Int, nx: CGFloat, ny: CGFloat)?   // 进行中拖选的锚点（页号 + 页内归一化坐标）
    var localInkStart: (page: Int, nx: Double, ny: Double)?     // 进行中本机落墨的起点（⇧ 尺子锚点；非 nil = 有一笔/一次擦除在画）
    var lassoDragMode: LassoDragMode?  // 进行中框选手势的形态（nil = 无框选/移动在飞）
    var snipViaOption = false          // 这次框选截图是 ⌥ 临时触发的（松手后不该留在 snip 工具上）
    var snipToNote = false             // 这次框选是 ⌥⇧（或 snip 工具 + ⇧）起手的 → 存为图片笔记而不是发给 AI
    var noteDragID: UUID?              // 进行中点注解图钉拖拽的 note id（起点命中定锚一次；非 nil = 有图钉在拖）
    var lassoEscMonitor: Any?          // Esc 清除框选选中集的 NSEvent 本地监视器（事件管道，非视图）
    var toolKeyMonitor: Any?           // 单键工具切换（e 橡皮 / 数字选笔等）的 NSEvent 本地监视器
    var wheelMonitor: Any?             // ⌘+滚轮的 NSEvent 本地监视器（事件管道，非视图）
    var isActiveWindow = false         // 供监视器闭包读取的实时值（struct let 会在 onAppear 后过期，需经 scratch 转发）
    let clientID = UUID().uuidString   // 渲染引擎多窗口 wanted 隔离键
    // 夜间切换「原地反转」（见 ReaderSurface+Render.scheduleNightRender）
    var nightLive = false              // 实时夜间模式（onChange 同步；逃逸闭包捕获的 struct self 里 nightMode 会过期，键计算一律读这里）
    var imagesNight = false            // 当前 images/tiles 对应的夜间模式（setup 时对齐 nightMode）
    var nightFlipping = false          // 一次原地反转在飞（串行化快速连切）
    var nightFlipTo: Bool?             // flip 飞行中用户又切换的目标模式（落地后连锁再翻，收敛到最终态）
}
