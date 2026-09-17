import Combine
import CoreGraphics
import Foundation
import PDFKit

/// 滚动锚点：文档位置（页 + 页内比例），与视口大小/缩放无关。`origin` 标识来源以防回环。
struct ScrollAnchor: Equatable {
    var page: Int
    var frac: Double
    var seq: Int
    var origin: String   // "mac" | "pad" | "toc" | "search" | "restore"
    var senderT: Double = 0   // 发送端单调时钟(ms)，>0 启用时间戳插值；0=本地(sim/mac)走低通

    /// 起步方式：true = 从当前位置起步、交给 `ScrollFollower` 的低通滤波器动画飞过去
    /// （想要「看得见」的跳转，目前只有搜索切换命中）；false = 首帧当帧对齐、瞬间到位
    /// （TOC/restore 要的是即时定位，不需要额外的滚动动画，见 `ScrollFollower.apply`）。
    var animate: Bool { origin == "search" }
}

/// 平板笔悬停位置（**页内**归一化坐标，左上原点）。笔只在 PDF 页上操作 → 光标锚定页内容（随页滚动/缩放），
/// Mac 在页上叠加蓝色笔尖圆环（纯位置指示，不操作任何控件）；离场为 nil。
struct HoverPoint: Equatable {
    var page: Int
    var nx: Double
    var ny: Double
}

/// 环形选笔盘（长按呼出，判定全部在 Mac 端）：`cx`/`cy` 为呼出中心的页内归一化坐标（笔尖处），
/// `highlight` = 当前指向第几个**扇区**（-1 = 中心取消区，不选）。扇区含义见 `RadialLayout.items`。
/// 平板只管发笔事件；检测/选中在 Mac，Mac 再把盘状态镜像下发（`radial` 消息）让平板画同一个盘。
struct RadialState: Equatable {
    var page: Int
    var cx: Double
    var cy: Double
    var highlight: Int
}

/// 环形盘的一个扇区。
enum RadialItem: Equatable {
    case pen(Int)   // `AppModel.pens` 下标
    case erase
    case page
    case scratchAdd   // 新建草稿纸（盘心即锚点，线上 kind=3）
    case textNote     // 新建文字笔记（线上 kind=4，Mac 下发 noteNew 让平板开编辑器）
}

/// 环形选笔盘的布局契约（Mac 判定 / Mac 绘制 / 平板绘制三处唯一真源）。
///
/// **单层整圆**：所有扇区等分 360°，第 0 项中心在正上方（12 点）、顺时针排列。选择只看**角度**、
/// 不看半径——半径分层（旧版内环笔/外环工具）要求用户精确控制笔离中心的距离，而那个距离在页内归一化
/// 坐标里随两端缩放漂移，是「选择很不友好」的根因。现在半径只用来判「有没有离开中心取消区」。
enum RadialLayout {
    /// 扇区顺序：N 支笔在前（0 号笔在正上方），橡皮擦、翻页、新建草稿纸、新建笔记收尾。
    /// ⚠️ 线上 kind 按**追加**扩展（0=pen 1=erase 2=page 3=scratchAdd 4=textNote），顺序与这里一一对应。
    static func items(penCount: Int) -> [RadialItem] {
        (0..<max(0, penCount)).map { RadialItem.pen($0) } + [.erase, .page, .scratchAdd, .textNote]
    }

    // 盘的屏幕尺度。Mac 用 pt、平板用 CSS px，取同一组数值 → 两端看到的是同一个盘。
    // capture.html 的 `RD` 常量必须与此一致。
    static let hubRadius: CGFloat = 46      // 中心 hub = 取消区
    static let innerRadius: CGFloat = 54    // 扇区内缘
    static let outerRadius: CGFloat = 134   // 扇区外缘
    static let gapDegrees: Double = 1.5     // 相邻扇区之间的分隔缝（单边）
}

/// 长按进度环：落笔中心（页内归一化）+ 起始时刻。Mac 据 `start` 到当前的用时画填充进度。
struct PressRing: Equatable {
    var page: Int
    var nx: Double
    var ny: Double
    var start: Date
}

/// 一处全文搜索命中（T2）。可能跨行换行（`rects` 多个，均归一化 0~1 左上原点，页局部）；
/// `frac` = 首行顶部 y，供 `emitAnchor` 精确跳转定位。
struct TextMatch: Identifiable, Equatable {
    let id = UUID()
    var page: Int
    var rects: [CGRect]
    var frac: Double
}

/// 参考窗要的一条文档信息（`WorkspaceManager.refDocIndex()` 产出，随会话快照过一道）。
/// 路径与哈希给取图用，标题与进度给「打开时定位到那本书的进度」用。
struct RefDocInfo: Equatable {
    var path: String
    var hash: String
    var title: String
    var pageCount: Int
    var readPage: Int
    var readFrac: Double
}

/// 一个打开中的 PDF 窗口的运行时状态。每个 reader 窗口一个。
final class DocSession: ObservableObject, Identifiable {
    /// 关标签/关窗后会话是否真的释放（笔迹字典、OCR 文本层、撤销栈都跟它走）：看这一行来不来。
    deinit { wsLog("会话释放 \(title)") }
    let id = UUID()

    /// **本会话所在窗口的身份**（由 `DocTabModel` 在建标签时写入，之后不变）。
    ///
    /// 🔴 为什么把它挂在会话上：多标签之后「一个标签 = 一个会话」，而有些东西是**按窗口**分的，
    /// 最要命的是内置 AI 面板那一份网页（`AIHost.inline(...)`）——按 `session.id` 分宿主的话，
    /// 切标签就是换宿主，而 `AIInlineLayer` 的注释白纸黑字写着「同一宿主被重建 =
    /// `_WebKit_SwiftUI.makeViewProvider` 当场 trap」（2026-08-26「开着 webview 切换书」秒崩）。
    /// 需要窗口身份的地方（`AIInlineLayer` / `ReaderSurface+Snip` 的面板宽度）都在会话拿得到的
    /// 位置，挂这儿就不必层层传参——同 `workspaceFolder` 那几个窗口级快照的先例。
    var windowID = UUID()
    @Published var title = ""
    @Published var contentHash = ""
    @Published var pdf: PDFDocument?
    @Published var currentPageIndex = 0

    /// 当前会话对应的逻辑文档 id（笔迹持久化用；nil = 未加载文档）。
    var documentId: String?

    /// 当前 PDF 的目录树（`loadSelected` 载入时构建）。侧栏 Inspector 与平板 `toc` 广播共用同一份。
    /// `@Published` 安全：只在换文档时写一次，不是每帧量（对比 `readZoom` 的性能红线注释）。
    @Published var toc: [TOCEntry] = []

    // MARK: 所属工作区的快照（`ContentView.syncWorkspaceSnapshot` 注入，主线程写）
    //
    // `AppModel` 是 App 级单例、`WorkspaceManager` 是窗口级（多工作区并存），要把「平板跟随的这个
    // 窗口所在工作区」的书库广播给平板，只能由会话捎带。**存快照而不是持 `WorkspaceManager` 引用**：
    // 那个类是 `@MainActor`，而 `AppModel` 不是，直接引用会在每个 broadcast 里撞上 actor 隔离。
    var workspaceName = ""
    var workspaceFolder: URL?
    var libraryDocs: [LibDocument] = []
    /// 参考窗取图/定位要的索引（id → 路径/哈希/标题/进度）。与 `libraryDocs` 同批注入，
    /// 只在书库真的变了时重建（那次遍历要查 location/variant 两张表）。
    var libraryRefIndex: [String: RefDocInfo] = [:]

    /// 阅读区当前缩放倍率（相对 fit-width，1=贴合宽度）。ContentView 读来存进度。
    /// ⚠️ **只许在缩放稳定后（settleRender）写一次，严禁每帧回报**（2026-07-29 掉帧根因）：
    /// 这是个 `@Published`，每写一次就向所有订阅 `DocSession` 的视图广播一遍 `objectWillChange`
    /// ——ContentView、Inspector、侧栏、缩略图列表、笔架全在订阅。缩放动画逐帧写它，等于每帧把整个
    /// 窗口的视图树重算一遍，阅读区自己那点渲染优化再怎么做都补不回来。相邻的 `readHFrac` 正是
    /// 为同一个理由被刻意排除在 `@Published` 之外。
    /// 仍保留 `@Published`：ContentView 靠它的 `onChange` 触发进度落库，稳定后一次的频率完全够用。
    @Published var readZoom: CGFloat = 1
    /// 待恢复的缩放倍率（loadSelected 从库读入，PageStreamView 首帧定基准后一次性套用）。非 @Published。
    var restoreZoom: CGFloat = 1
    /// 阅读区当前横向滚动比例（offsetX / pageW）。PageStreamView 每帧写、存进度时读。
    /// **非 @Published**——每帧刷新，若发布会导致每帧重渲。
    var readHFrac: Double = 0
    /// 待恢复的横向滚动比例（loadSelected 读入，PageStreamView 首帧定位后一次性套用）。
    var restoreHFrac: CGFloat = 0

    /// 阅读区**「离开时长什么样」的快照**，切标签回来时用它让重建后的**首帧就是对的**。
    ///
    /// 🔴 为什么需要它（2026-08-29 用户报「切换标签有加载感，有点闪烁」）：切标签时阅读区被
    /// `PageStreamView` 上的 `.id(docKey)` 整体重建，而常规首帧路径要等 `onScrollGeometryChange`
    /// 回调才 `didInitialGeo` → 定基准 → 实化 → 出图，那是**下一拍**的事；这一拍屏幕上是空的
    /// （`voidColor`）。开窗时那是刻意的取舍（「宁可白一下也不闪一下」，见 `geometryChanged`），
    /// 但切标签时用户刚刚还在看这一页，白一下就是「加载感」。
    ///
    /// 有了它，`ReaderSurface.setup`（仍在本次事务内）就能把基准/缩放/实化窗口/页图/滚动位置
    /// 一次摆好——项目实测「同一 runloop 周期内改布局 + scrollTo = 同一次 CA commit = 屏幕原子」。
    ///
    /// **非 @Published**：每次滚动几何回调都写，发布出去就是每帧重算整窗视图树（同 `readHFrac`）。
    /// 换文档时由 `DocTabModel.load` 清空——那时该走库里的进度，不是上一篇的屏幕状态。
    struct ReaderSnapshot {
        /// 拍快照时的**布局宽**（`layoutW`，含侧栏延伸区的全窗宽）。核对「窗口宽有没有变过」只能用它：
        /// 🔴 别拿 `fitBasis` 去和现算的 `fitAvail` 比——`fitAvail` 要减 `scrollerAllowance`，
        /// 而那个值在触摸板（overlay 滚动条）机器上运行时会被校正成 0，与 init 里现算的 legacy 宽度
        /// 差着 15pt，核对必然不通过、种子永远种不上（2026-08-29 第一版就栽在这儿）。
        var layoutW: CGFloat
        var fitBasis: CGFloat
        var zoom: CGFloat
        var userZoomed: Bool
        var basePixelW: Int            // 当时用的基图像素宽 —— 用它去缓存里取图才命中得上
        var recentBaseWidths: [Int]
        // 🔴 **这里刻意不存「滚动偏移」和「实化窗口」**（2026-08-29 实测教训）：
        // 那两个是**每帧都在变的量**，而视图销毁前会来最后一拍零几何，正好把它们写成
        // `offset=0 / realized=0…0` —— 快照存的位置于是永远是文档顶端，切回来自然回不到原处。
        // 位置改从 `scrollAnchor`（页 + 页内比例）+ `readHFrac` 现算：那是阅读区一路维护、
        // **存阅读进度也在用**的可靠真相，跟视图的生死无关。实化窗口据算出来的偏移现推即可。
        // 留在这里的几项都是「慢变量」（fit 基准 / 缩放 / 基图宽），零几何那一拍不会污染它们。
    }
    var readerSnapshot: ReaderSnapshot?

    /// 「**下一次阅读区重建要用快照种子**」——由 `DocTabModel.prepareForReactivation` 在切到这个
    /// 标签之前置上，`ReaderSurface.setup` 用掉即清。
    /// 没有这个门的话，`ReaderSurface` 的 init（写字时每落一个点都会重建一次 struct）每次都要去
    /// 页图缓存里查一轮，纯浪费。**故意不在 init 里清**：SwiftUI 允许在一次布局里多次创建 struct，
    /// 清早了真正被装载的那一次就拿不到种子了。
    var readerSeedPending = false

    /// 页面布局缓存（`PageLayout(doc:)` 要遍历全部页取尺寸，切标签重建时不该重算）。
    /// 换文档时由 `DocTabModel.load` 清空。
    var cachedLayout: PageLayout?
    /// 正在替本会话向 `PageRenderEngine` 声明 wanted 的阅读区（键 = `Scratch.clientID`，值 = 它的
    /// 收尾闭包，**只捕获 `Scratch`、不捕获视图**）。`teardown` 要先替它们把 wanted 清空、放掉
    /// NSEvent 监视器与防抖闭包，再 `purge`——引擎靠「还有没有窗口声明要这份文档的键」判断能不能清，
    /// 而关窗时 `teardown` 跑在阅读区 `onDisappear` **之前**（AppKit 直接销毁 hosting 视图，后者来不来
    /// 没有保证），自己的 wanted 还挂着就会把自己当成「别的窗口还在看」而跳过——2026-09-10 实测：
    /// 关掉全部工作区，缓存里 18 张页图一张没清；监视器不放，视图拷贝连着页图也永远活着。
    var renderClients: [String: () -> Void] = [:]
    /// 本次打开/切标签的耗时账本（`DocTabModel.select` / `prepareForReactivation` 开账，
    /// 阅读区与笔迹层往里记，齐了自动结账进 `OpenStats`）。非 @Published：纯记账，不驱动界面。
    var openTrace: OpenTrace?
    /// 画板模式（v12，逐文档记）：页面两侧的空白也是可书写区，横向按笔迹软边界生长。
    /// 页边笔迹仍是**页内笔迹**（note kind=2、归属那一页），只是归一化 x 越出 0~1 —— 见 `CanvasMargin`。
    @Published var canvasMode = false
    /// 当前每侧页边宽度（页宽的倍数）。阅读区（`ReaderSurface.applyCanvasMargin`）是唯一写入方，
    /// `AppModel.broadcastCanvas` 读它推给平板。**非 @Published**——同 `readHFrac`，避免跳档时
    /// 把整窗视图树重算一遍（它只是给广播看的一个数，界面自己有 `canvasMarginState`）。
    var canvasMarginLive: Double = CanvasMargin.step
    /// 已落库的笔画快照（id → 值），用于增量对账（新增/内容变更 upsert、擦除 delete），非 @Published。
    /// 值快照而非纯 id 集合：框选移动后 id 不变、点集变，纯 id 对账会漏写（仿 `persistedTextNotes`）。
    var persistedStrokes: [UUID: InkStroke] = [:]
    /// 笔迹**异步装载**的代次（`DocTabModel.ensureInkWindow`）：每次开文档 +1，后台读库/解码完成回主线程时
    /// 对不上就丢弃——用户在解码期间已经切走/关掉了。非 @Published。
    var inkLoadGeneration = 0
    /// 笔迹还在后台装载（页图先出、笔迹随后补上）。视图不读它；打开耗时账本据此不提前结账。
    var inkLoading = false

    // 笔迹按页窗口装载（`InkWindow` / `INK-PAGING-PLAN.md §4`）：`strokes` 只是**已装载页**的集合。全部非 @Published。
    /// 已装载的页（这些页的笔迹在 `strokes` 里、对账集里）。
    var inkLoadedPages = Set<Int>()
    /// 正在后台读的页（别重复发请求）。
    var inkLoadingPages = Set<Int>()
    /// 阅读区在 settle 后报的实化范围 → `DocTabModel` 据此装载/淘汰。不是 @Published：每次 settle 一发，
    /// 不走视图树。
    let inkWindowRequests = PassthroughSubject<ClosedRange<Int>, Never>()
    /// 「这一页现在就要在内存里」（平板对某页擦除/框选/粘贴前调）：不在窗口里就同步读那一页。
    /// 由 `DocTabModel` 装上。
    var inkEnsureLoaded: ((Int) -> Void)?
    /// 画板模式页边溢出的**全篇**首值（开文档一条 SQL 从 anchor 列算出，`LibraryStore.inkXExtent`）：
    /// 内存里只有窗口内的笔迹，光扫它们会把远处页边的笔迹裁掉。只增不减（同 `growCanvasMargin`）。
    var inkOverflowSeed: Double = 0
    /// 全篇的页边溢出量 = 首值 ∨ 窗口内实扫（新画的、平板发来的都在窗口里）。替代原来的 `CanvasMargin.overflow(strokes)`。
    func inkOverflow() -> Double { max(inkOverflowSeed, CanvasMargin.overflow(strokes)) }

    /// 某图层**全篇**笔数（窗口外的也算：一条 `json_extract` 的 GROUP BY，几千行几十毫秒——只在删层确认时问一次）。
    /// 库不可用时退回内存计数。
    func inkStrokeCount(layerId: UUID) -> Int {
        guard let id = documentId, let store, let counts = try? store.inkLayerCounts(documentId: id) else {
            return strokes.filter { $0.layerId == layerId }.count
        }
        var n = counts[layerId.uuidString.uppercased()] ?? 0
        if layerId == InkLayer.defaultID { n += counts[""] ?? 0 }   // 老行没有 `layerId` 键 = 默认图层
        return n
    }

    /// 删整层的笔迹：内存里的摘掉（对账把它们删库），窗口外的行直接一条 SQL 删——那些内存里没有、对账够不着。
    func deleteInkStrokes(layerId: UUID) {
        strokes.removeAll { $0.layerId == layerId }
        guard let id = documentId, let store else { return }
        try? store.deleteInkStrokes(documentId: id, layerId: layerId.uuidString,
                                    isDefaultLayer: layerId == InkLayer.defaultID)
    }

    /// 编辑撤销栈（页内笔迹 + 文字注解 / 草稿纸笔迹各一条，见 `InkUndo.swift`）。
    /// **瞬态、非 @Published**：换文档由 `DocTabModel` 清空；菜单可用性在 `validateMenuItem`
    /// 里现问现答，不必让它每记一笔就把整窗视图树重算一遍。
    let inkUndo = InkUndoStack()
    let scratchUndo = InkUndoStack()

    /// 上一次收笔的时刻（`AppModel.inkEnd` 写，`ContentView.persistInk` 读）。**非 @Published**——
    /// 纯诊断用：它与 `persistInk` 开跑那一刻的差 = 「SwiftUI 从 `strokes` 变到把 onChange 派下来」
    /// 花了多久（含它对整个 `[InkStroke]` 数组做的相等性比较，那是 O(笔迹数 × 点数)）。
    /// 只有开了 `PadLog` 才会被读，平时零成本。
    var lastInkEndAt: CFAbsoluteTime = 0

    /// 「有笔迹被原地挪动/缩放过」的计数器（平板发起的框选提交，`AppModel.lassoApply` 递增）。
    /// 阅读区靠它补一次 `refreshCanvasMargin()`——那边的触发器是 `strokes.count`（数组整体比较是
    /// 每帧 O(总点数)，红线），而框选移动**不改笔画数**，只能另给一个便宜的信号。
    @Published var inkMovedRev: Int = 0

    // 实时手写：已完成笔画 + 正在书写的一笔。
    @Published var strokes: [InkStroke] = [] { didSet { inkRev &+= 1 } }
    @Published var liveStroke: InkStroke?

    // 笔迹图层（挂逻辑文档，全版本共用）：按 sortOrder 升序维护。
    @Published var inkLayers: [InkLayer] = [] { didSet { inkRev &+= 1 } }

    /// 笔迹/图层的修改序号：[strokes] 或 [inkLayers] 每被写一次就 +1，给
    /// [visibleStrokesByPage] 的记忆化当键。**只数次数、不比内容**——比数组内容正是那条
    /// 「每帧 O(总点数)」的红线（同 `inkMovedRev` 存在的理由）。改笔色/改线宽/切图层可见性
    /// 都是对数组本身赋值，一样会命中 `didSet`，所以这个键是完备的。
    private(set) var inkRev: UInt64 = 0
    /// [visibleStrokesByPage] 的单槽记忆（同一 `inkRev` + 同一 `range` 直接复用）。
    private var strokeBuckets: (rev: UInt64, range: ClosedRange<Int>, out: [Int: [InkStroke]])?
    /// 已落库的图层快照（id → 值），用于增量对账，非 @Published。
    var persistedInkLayers: [UUID: InkLayer] = [:]
    /// 新笔画落在哪一层；不持久化，每次开文档默认第一层（`loadInkLayers` 设置）。
    @Published var activeLayerID: UUID?

    /// 当前可见的图层 id 集合（渲染/擦除/框选公用）。
    var visibleLayerIDs: Set<UUID> { Set(inkLayers.filter(\.visible).map(\.id)) }

    /// `range` 内各页当前可见的笔迹，按图层 `sortOrder` 排（同层内保持原相对顺序），供渲染直接消费。
    /// ⚠️ **按页取用请一律走这个批量版**：阅读区每帧要为每一实化页各取一次，逐页版等于每页都重建一次
    /// 图层序字典 + 全量扫描 + 排序，复杂度 O(页数 × 笔迹数 × log)，缩放动画下直接吃光帧预算
    /// （2026-07-29 按钮缩放掉帧的成因之一）。批量版把它压回一次 O(笔迹数)。
    func visibleStrokesByPage(in range: ClosedRange<Int>) -> [Int: [InkStroke]] {
        guard !strokes.isEmpty else { return [:] }
        // 记忆化（键 = `inkRev` + `range`，见 [inkRev]）：本函数在**每次 body 求值**时都被
        // `PageBuckets.init` 调一遍，而滚动/缩放期间 body 一秒要跑几十次、笔迹却基本不动。
        // 2026-09-05 采样实测它占主线程 126ms/8s（全窗每帧重建那条链修好后仍是白扫）。
        if let c = strokeBuckets, c.rev == inkRev, c.range == range { return c.out }
        let order = Dictionary(uniqueKeysWithValues: inkLayers.enumerated().map { ($1.id, $0) })
        let vis = visibleLayerIDs
        var acc: [Int: [(seq: Int, stroke: InkStroke)]] = [:]
        for (seq, s) in strokes.enumerated() where range.contains(s.page) && vis.contains(s.layerId) {
            acc[s.page, default: []].append((seq, s))
        }
        let out = acc.mapValues { items in
            items.sorted { (order[$0.stroke.layerId] ?? 0, $0.seq) < (order[$1.stroke.layerId] ?? 0, $1.seq) }
                 .map(\.stroke)
        }
        strokeBuckets = (inkRev, range, out)
        return out
    }

    // MARK: 草稿纸（scratch_pad 表 + note kind=4，v8）
    //
    // 草稿纸是**盖在 PDF 之上的一层 UI**，不属于任何一页；一篇文档可有多张，各自锚在创建处。
    // 打开哪张是**窗口级**状态（`openPadID`），平板跟随它（见 `AppModel.broadcastScratchPads`）。

    /// 本文档的全部草稿纸（按创建序）。
    @Published var scratchPads: [ScratchPad] = []
    /// 已落库的草稿纸快照（id → 值），增量对账用，非 @Published。
    var persistedScratchPads: [UUID: ScratchPad] = [:]
    /// 当前打开的草稿纸（nil = 没开，阅读区照常）。开着时笔迹只落在草稿纸上（用户要求）。
    @Published var openPadID: UUID?
    /// **全部**草稿纸上的已完成笔迹（不分纸；点集是画布坐标）。渲染时按 `padId` 过滤一次即可
    /// ——同时只可能开一张纸，不像页内笔迹要每帧按页分桶，故不做 `visibleStrokesByPage` 那种批量版。
    @Published var scratchStrokes: [InkStroke] = []
    /// 已落库的草稿纸笔迹快照（id → 值），增量对账用，非 @Published。
    var persistedScratchStrokes: [UUID: InkStroke] = [:]
    /// 草稿纸上正在书写的那一笔（与页内的 `liveStroke` 分开，免得两条链路互相看见对方的半成品）。
    @Published var scratchLive: InkStroke?

    var openPad: ScratchPad? { scratchPads.first { $0.id == openPadID } }
    /// 某张草稿纸上的笔迹（按原顺序）。
    func strokes(pad: UUID) -> [InkStroke] { scratchStrokes.filter { $0.padId == pad } }

    // 文字注解（note kind=0）。运行时驻留于此，阅读区(渲染标记)与 Inspector(列表) 共读；
    // 由 ContentView `.onChange` 增量对账落库（新增/编辑 upsert、删除 delete），与手写笔迹同套路。
    @Published var textNotes: [TextNote] = []
    /// 已落库的文字注解快照（id → 值），用于增量对账（检测新增/内容变更/删除），非 @Published。
    var persistedTextNotes: [UUID: TextNote] = [:]
    /// 「把这条笔记的气泡展开」的一次性请求（`unireader://open?note=…` 链接，见 `DeepLinkRouter`）。
    /// 气泡开合是阅读区的视图状态（`PageStreamView.expandedNotes`，瞬态不落库），会话够不着，
    /// 只能把 id 放在这里等阅读区来取：视图在就 `onChange` 当场取走，视图还没建（文档刚开）就在
    /// 首帧 `setup` 里取。取走即置 nil。文字笔记与图片笔记共用（两者本来就共用 `expandedNotes`）。
    @Published var revealNoteID: UUID?

    // 笔记类型（工作区级，meta JSON 持久化）。阅读区（图钉/编辑器）与 Inspector（标识/筛选）共读；
    // 由 ReaderSurface.saveNoteTypes 增删改并整体落库；「通用」为内置兜底，不在此数组。
    @Published var noteTypes: [NoteType] = []
    /// Inspector 笔记列表筛选：.all 全部 / .only(nil) 通用 / .only(id) 指定类型。仅内存，重启复位。
    @Published var noteTypeFilter: NoteTypeFilter = .all

    // AI 会话绑定（note kind=1）。同上套路：Inspector 列表读它，ContentView `.onChange` 增量对账落库。
    // 谁往里写：AI 面板捕到会话 URL 后经 `AIPanelModel.threadUpsert` 请求，由**发起绑定的那个窗口**
    // 的 ContentView 应用到这里（面板是 App 级、库是窗口级，跨不过去——同 `broadcastLibrary` 走快照的理由）。
    @Published var aiThreads: [AIThread] = []
    /// 已落库的 AI 会话快照（id → 值），增量对账用，非 @Published。
    var persistedAIThreads: [UUID: AIThread] = [:]

    // 文字高亮（note kind=3）。同上套路：阅读区铺色 + Inspector 列表，ContentView `.onChange` 增量对账。
    @Published var highlights: [Highlight] = []
    /// 已落库的高亮快照（id → 值），增量对账用，非 @Published。
    var persistedHighlights: [UUID: Highlight] = [:]

    // 图片笔记（note kind=6，`IMAGE-NOTE-PLAN.md`）。同上套路：阅读区图钉/气泡 + Inspector 列表，
    // `DocTabModel` 的 `.onChange` 增量对账落库（落库那一步顺带对账图片本体的待删除状态）。
    @Published var imageNotes: [ImageNote] = []
    /// 已落库的图片笔记快照（id → 值），增量对账用，非 @Published。
    var persistedImageNotes: [UUID: ImageNote] = [:]

    // 书签（note kind=5，`REQUIREMENTS.md §1.9`）。同上套路：目录树里与 TOC 合并显示，
    // `DocTabModel` 的 `.onChange` 增量对账落库。列表**恒按 `Bookmark.before` 有序**
    // （读库时排一次，新增/改名后再排一次）——合并算法与三端显示都指望这个不变量。
    @Published var bookmarks: [Bookmark] = []
    /// 已落库的书签快照（id → 值），增量对账用，非 @Published。
    var persistedBookmarks: [UUID: Bookmark] = [:]

    /// 待命名的书签（非 nil = 正在弹命名框）。名字必填，所以「加书签」这个动作分两步：
    /// 先记下落点，输入并确认后才真的落进 [bookmarks]。取消 = 什么都不留下。
    @Published var bookmarkDraft: BookmarkDraft?

    // 平板笔悬停位置（nil = 无悬停 / 已落笔）。
    @Published var hover: HoverPoint?

    // 环形选笔盘（nil = 未呼出）。长按触发，判定全程 Mac 端处理。
    @Published var radial: RadialState?

    // 长按进度环（nil = 无）：落笔起计，Mac 在笔尖处 300ms 起显示、1s 填满，随后展开成 radial。
    @Published var pressRing: PressRing?

    // 滚动锚点（跨视口同步）。
    //
    // 🔴 **这条绝不能是 `@Published`**（2026-09-05 `sample` 实测定位，触控板滚动掉帧的根因）。
    // 本机滚动时 `ReaderSurface.maybeEmit` 每帧（120Hz 节流）写它一次，而 `DocTabModel.bind`
    // 把本会话的 `objectWillChange` 转发给自己、`TabsModel` 再转发一层 → **每帧把整扇窗标脏**：
    // 侧栏 `List` 全量重建（每行还各查一次 SQLite + stat，见 `SidebarView.row`）、
    // 工具栏重跑一遍 AutoLayout、窗口标题重刷。8 秒采样里 `CA::Transaction::commit` 独占主线程
    // 2571ms（= 忙碌时间的 80%），而同期页图渲染队列只有 85ms —— 卡的从来不是渲染。
    // 与 `readZoom` 上那条注释是同一个病，这里是**滚动路径**上没修的那一半。
    //
    // 于是拆成两条：本条是**真相源**（普通属性，谁要谁读，不触发任何刷新），可观察的那条是
    // [foreignAnchor] —— 需要「被通知」的只有别处发来的锚点，本机自己滚出来的没人需要观察。
    private(set) var scrollAnchor: ScrollAnchor?

    /// **非本机**滚动产生的锚点（平板 `"pad"` / 恢复 `"restore"` / 跳转 `"toc"` …）。
    /// 阅读区只观察这一条（`PageStreamView` 的 `onChange`）；`origin == "mac"` 不写这里，
    /// 所以本机滚动一帧都不会惊动视图树。理由见上面 [scrollAnchor] 的红线。
    @Published private(set) var foreignAnchor: ScrollAnchor?

    /// 锚点变化的**非观察式**回调（由 `DocTabModel.bind` 装上：平板广播 + 进度节流落库）。
    /// 这两件事本来就不刷新任何视图，走回调而不是 `@Published`，理由同上。
    var onAnchorChanged: ((ScrollAnchor) -> Void)?

    private var anchorSeq = 0
    func emitAnchor(page: Int, frac: Double, origin: String, senderT: Double = 0) {
        anchorSeq += 1
        let a = ScrollAnchor(page: page, frac: min(max(0, frac), 1), seq: anchorSeq,
                             origin: origin, senderT: senderT)
        scrollAnchor = a                          // 真相源先落定
        if origin != "mac" { foreignAnchor = a }   // 只有别处来的才惊动视图
        onAnchorChanged?(a)
    }

    // MARK: 跳转历史（每文档一份，纯内存不落库；见 `JumpHistory`）

    /// 本文档走过的跳转轨迹。换文档时由 `DocTabModel.load` 清空。
    @Published var jumps = JumpHistory()

    /// 阅读区当前文字选区的镜像（MCP `get_current_view` 给 Agent 看「用户选中了什么」）。
    /// 选区本体在 `ReaderSurface` 的 `@State` 里，模型层拿不到；阅读区在选区变化时写这里一次。
    /// **普通属性、不 `@Published`**：拖选期间每个鼠标事件都在改它，进视图树就是每次拖动重算整窗
    /// （`readZoom` 那条红线的同款）。换文档时 `DocTabModel.load` 清空。
    var currentSelection: TextSelection?

    /// 此刻停在哪儿 —— 作为「离开点」入历史。位置取一路维护着的 `scrollAnchor`
    /// （本机滚动每帧在写），它比 `currentPageIndex` 多一个页内比例，回来才回得准。
    var currentMark: JumpMark {
        JumpMark(page: scrollAnchor?.page ?? currentPageIndex,
                 frac: scrollAnchor?.frac ?? 0, kind: .reading)
    }

    /// **所有非连续跳转的唯一入口**：记一条历史 + 定页 + 发锚点。
    ///
    /// 连续滚动（origin `"mac"`/`"pad"`）与开文档/切标签的恢复（`"restore"`）**不走这里**——
    /// 那些不是「跳转」，记进历史只会把轨迹淹掉。
    func jump(page: Int, frac: Double, kind: JumpKind, label: String = "", origin: String = "toc") {
        jumps.record(leaving: currentMark,
                     to: JumpMark(page: page, frac: frac, kind: kind, label: label))
        currentPageIndex = page
        emitAnchor(page: page, frac: frac, origin: origin)
    }

    /// 历史内导航（后退/前进/点浮窗列表）：跳过去，但**不再记新历史**——
    /// 否则每退一步都会生出一条新记录，越退越多、再也退不回去（自噬）。
    private func goToMark(_ m: JumpMark) {
        currentPageIndex = m.page
        emitAnchor(page: m.page, frac: m.frac, origin: "toc")
    }

    func jumpBack() { if let m = jumps.back() { goToMark(m) } }
    func jumpForward() { if let m = jumps.forward() { goToMark(m) } }
    func jumpToMark(id: UUID) { if let m = jumps.go(to: id) { goToMark(m) } }
    func clearJumps() { jumps.reset() }

    // MARK: 全文搜索（T2）——PDFKit `findString` 找命中，防抖后台跑，边打字边高亮+跳首个命中。

    @Published var searchQuery = ""
    @Published var searchMatches: [TextMatch] = []
    @Published var currentMatchIndex: Int?
    @Published var isSearching = false
    private var searchTask: Task<Void, Never>?

    /// 输入防抖（250ms）触发搜索；由 UI 层在 `searchQuery` 变化时调用。
    func scheduleSearch() {
        let q = searchQuery
        searchTask?.cancel()
        searchTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            await self?.performSearch(q)
        }
    }

    private func performSearch(_ query: String) async {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let pdf, !q.isEmpty else {
            searchMatches = []; currentMatchIndex = nil; isSearching = false
            return
        }
        isSearching = true
        // OCR 已启用（文本更准）→ 搜已识别页的 OCR 文本（行级）；否则走 PDFKit 原生 findString。
        let matches: [TextMatch]
        if ocrEnabled, !ocrRuns.isEmpty {
            matches = searchOCR(q)
        } else {
            matches = await Task.detached(priority: .userInitiated) {
                TextSearch.find(query: q, in: pdf)
            }.value
        }
        // 过期结果丢弃：搜索期间用户又改了词，只认最新一次。
        guard searchQuery.trimmingCharacters(in: .whitespacesAndNewlines) == q else { return }
        searchMatches = matches
        isSearching = false
        // 新一轮搜索的首个跳转目标不是文档里排最前的那个，是离当前阅读位置最近的那个
        // （用户 2026-09-17 拍板：正在看第 300 页时搜索，不该先跳回第 1 页）。
        if matches.isEmpty { currentMatchIndex = nil } else { jumpToMatch(nearestMatchIndex(in: matches)) }
    }

    /// `matches` 里离当前阅读位置（`currentMark`）最近的下标，按文档纵向距离（page+frac）算，
    /// 前后不分方向——就是「哪个离我最近」。
    private func nearestMatchIndex(in matches: [TextMatch]) -> Int {
        let cur = Double(currentMark.page) + currentMark.frac
        var best = 0
        var bestDist = Double.greatestFiniteMagnitude
        for (i, m) in matches.enumerated() {
            let dist = abs(Double(m.page) + m.frac - cur)
            if dist < bestDist { bestDist = dist; best = i }
        }
        return best
    }

    /// OCR 文本搜索：逐行匹配（大小写不敏感），只框住命中的那一段（有单字框数据时）。只覆盖已识别页。
    /// 走**可见行**——不然搜书名里的字（扫描件水印常就是出版方名字）会命中满屏水印碎片。
    private func searchOCR(_ q: String) -> [TextMatch] {
        let ql = q.lowercased()
        var out: [TextMatch] = []
        for page in ocrRuns.keys {
            guard let runs = ocrVisibleRuns(page: page) else { continue }
            for r in runs {
                let lowered = r.text.lowercased()
                guard let range = lowered.range(of: ql) else { continue }
                out.append(TextMatch(page: page, rects: [matchRect(r, range: range, in: lowered)], frac: r.y))
            }
        }
        return out.sorted { $0.page != $1.page ? $0.page < $1.page : $0.frac < $1.frac }
    }

    /// 命中行里只框住匹配到的那一段，不是整行：有逐字符边界（`chars`，PP-OCRv6 单字框）就按字符
    /// 比例精确截取；老缓存/无单字框数据时退回整行框（唯一能给的粒度）。
    private func matchRect(_ r: TextRun, range: Range<String.Index>, in lowered: String) -> CGRect {
        guard let chars = r.chars, chars.count == r.text.count + 1 else { return r.rect }
        let start = lowered.distance(from: lowered.startIndex, to: range.lowerBound)
        let end = lowered.distance(from: lowered.startIndex, to: range.upperBound)
        guard chars.indices.contains(start), chars.indices.contains(end) else { return r.rect }
        let x0 = r.x + chars[start] * r.w
        let x1 = r.x + chars[end] * r.w
        return CGRect(x: x0, y: r.y, width: max(0, x1 - x0), height: r.h)
    }

    func clearSearch() {
        searchTask?.cancel()
        searchQuery = ""
        searchMatches = []
        currentMatchIndex = nil
        isSearching = false
    }

    func nextMatch() { advanceMatch(by: 1) }
    func prevMatch() { advanceMatch(by: -1) }

    private func advanceMatch(by delta: Int) {
        guard !searchMatches.isEmpty else { return }
        let n = searchMatches.count
        let cur = currentMatchIndex ?? -1
        jumpToMatch(((cur + delta) % n + n) % n)
    }

    private func jumpToMatch(_ index: Int) {
        guard searchMatches.indices.contains(index) else { return }
        currentMatchIndex = index
        let m = searchMatches[index]
        // 记历史：同一个搜索词的连续「下一个」会就地更新那一条，不会刷屏（`JumpHistory` 规则 ③）。
        jump(page: m.page, frac: m.frac, kind: .search,
             label: searchQuery.trimmingCharacters(in: .whitespacesAndNewlines), origin: "search")
    }

    // MARK: OCR（T3，Paddle PP-OCRv6）——逐页按需 + 手动全量；结果=准确文本层，选择/复制/搜索改用它。
    // 数据流：可见页 → 查 ocr_page 缓存(命中即用) → miss 则渲页图上传 Paddle → 回填缓存 → ocrRuns 刷新。
    // 缓存键 = (内容 hash, 页, provider)，随内容走、换机复用；网络任务并发上限 3。

    @Published var ocrEnabled = false                     // 本文档启用 OCR 文本层
    /// 页 → 已识别的行级文本框（阅读顺序）。**这是真源**（落库、建水印指纹都用它）；
    /// 选择/分组/上色一律走 `ocrVisibleRuns(page:)`（滤掉水印块），别直接消费这个字典。
    @Published var ocrRuns: [Int: [TextRun]] = [:] {
        didSet { invalidateOCRDerived() }                  // 行变了 → 分组/水印/可见行缓存全作废（懒重算）
    }
    private var ocrGroupCache: [Int: [Int]] = [:]         // 页 → 分组 id（列/块聚类，与**可见**行同序）
    /// 某页 OCR 行的列/块分组（`OCRFlow.columnGroups`），带缓存——拖选/渲染多次访问不重复跑并查集。
    /// ⚠️ 基于**可见行**（已滤水印）算，下标与 `ocrVisibleRuns(page:)` 一一对应。
    func ocrGroups(page: Int) -> [Int] {
        if let c = ocrGroupCache[page] { return c }
        guard let runs = ocrVisibleRuns(page: page) else { return [] }
        let g = OCRFlow.columnGroups(runs)
        ocrGroupCache[page] = g
        return g
    }

    // MARK: 水印块忽略（`OCRWatermark`）——扫描件的平铺水印会被 OCR 认成一堆大字块，混进正文选择

    /// 忽略平铺水印块（默认开，OCR 面板可关）。关掉 = 拿到全部识别行（含水印）。
    @Published var ocrIgnoreWatermark = true {
        didSet { invalidateOCRDerived() }
    }
    private var ocrMaskCache: [Int: [Bool]] = [:]         // 页 → 水印掩码（与该页原始行同序）
    private var ocrVisibleCache: [Int: [TextRun]] = [:]   // 页 → 已滤水印的行（拖选每个事件都要，别重复过滤）
    private var wmProfile = OCRWatermark.Profile()        // 全书水印指纹（跨页统计）
    private var wmProfilePages = 0                        // 建指纹时的样本页数（用于决定何时重建）

    /// 该页**可见**的 OCR 行：滤掉被判为水印的块。选择/复制/分组/调试上色都用它。
    /// 返回 nil = 该页没有可用文本层（与老的 `ocrRuns[page]` 空判语义一致）。
    func ocrVisibleRuns(page: Int) -> [TextRun]? {
        guard let runs = ocrRuns[page], !runs.isEmpty else { return nil }
        guard ocrIgnoreWatermark else { return runs }
        if let c = ocrVisibleCache[page] { return c.isEmpty ? nil : c }
        let m = ocrMask(page: page, runs: runs)
        let kept = zip(runs, m).compactMap { $1 ? nil : $0 }
        ocrVisibleCache[page] = kept
        return kept.isEmpty ? nil : kept
    }

    /// 清掉一切由 `ocrRuns` + 指纹派生的缓存（可见行 / 掩码 / 分组）。三者必须一起清——
    /// 分组下标是按可见行算的，只清一半就会出现「分组指到别的行」。
    private func invalidateOCRDerived() {
        ocrVisibleCache = [:]; ocrMaskCache = [:]; ocrGroupCache = [:]
    }

    /// 该页被判为水印的行（只给调试上色看；正常路径不消费）。
    func ocrWatermarkRuns(page: Int) -> [TextRun] {
        guard ocrIgnoreWatermark, let runs = ocrRuns[page], !runs.isEmpty else { return [] }
        let m = ocrMask(page: page, runs: runs)
        return zip(runs, m).compactMap { $1 ? $0 : nil }
    }

    private func ocrMask(page: Int, runs: [TextRun]) -> [Bool] {
        if let c = ocrMaskCache[page] { return c }
        let m = OCRWatermark.mask(runs: runs, profile: wmProfile)
        ocrMaskCache[page] = m
        return m
    }

    /// 重建水印指纹：**一次性把库里这本书已缓存的全部 OCR 页读出来**做跨页统计。
    /// 为什么不用 `ocrRuns`：阅读区是逐页懒加载的，翻开第一页时手上只有 1 页，跨页重复根本无从谈起；
    /// 而库里往往整本都已经跑完（本文档打开时自动启用 OCR 就是凭这个）。
    /// 读库 + 解码 JSON 都放后台（一本 340 页的书约 3MB；2026-09-10 账本 `OCR 28ms` 全是主线程读这几 MB blob），
    /// 回主线程才落 `wmProfile`。`SQLiteDB` 一条语句一把锁，后台用主线程那条连接是既有做法。
    private func rebuildWatermarkProfile() {
        guard let store, !contentHash.isEmpty else { return }
        let hash = contentHash
        Task.detached(priority: .utility) { [weak self] in
            guard let raw = try? store.allOCRPayloads(contentHash: hash, provider: PaddleOCR.providerID),
                  !raw.isEmpty else { return }
            let dec = JSONDecoder()
            var pages: [Int: [TextRun]] = [:]
            for (page, data) in raw {
                if let payload = try? dec.decode(OCRPagePayload.self, from: data) { pages[page] = payload.runs }
            }
            let profile = OCRWatermark.buildProfile(pages)
            let sampled = raw.count
            await MainActor.run {
                // 换文档后旧任务回来：内容 hash 变了就整个丢弃（同 startNetworkOCR 的守卫）。
                guard let self, self.contentHash == hash else { return }
                self.wmProfilePages = sampled
                self.wmProfile = profile
                self.invalidateOCRDerived()
                self.objectWillChange.send()   // 掩码变了 → 选择/上色要按新的可见行重画
            }
        }
    }
    @Published var showOCRBlocks = false                  // 调试/demo：把 OCR 识别块按块上色画出来（量化排版/选择）
    @Published var ocrBlockGrouped = false                // 调试上色模式：false=每块独立色 / true=可选分组同色（列/块聚类）
    @Published var ocrActivePages: Set<Int> = []          // 正在网络识别的页
    @Published var ocrLastError: String?
    @Published private var ocrQueue: [Int] = []           // 待识别队列（@Published 让面板进度实时刷新）
    private var ocrInFlight = 0
    private let ocrMaxConcurrent = 3
    /// 供 OCR 缓存读写（App 级 `WorkspaceManager.store`，由 `ContentView.loadSelected` 注入）。仅主线程访问。
    var store: LibraryStore?
    /// OCR 页图渲染用串行队列。
    private static let ocrRenderQueue = DispatchQueue(label: "com.xvan.unireader.ocr-render", qos: .userInitiated)
    /// OCR 渲染专用的**独立 `PDFDocument` 实例**（懒建，换文档时由 `reloadOCRState` 置空）。
    /// ⚠️ 理由同 `AppModel.setPadRender`（2026-07-27 实测）：`PDFDocument`/`PDFPage` 不是线程安全的，
    /// 而 OCR 渲染跑在 `ocrRenderQueue`、Mac 阅读区渲染跑在 `PageRenderEngine` 的串行队列——
    /// 共用 `self.pdf` 就是两个后台队列并发操作同一份 PDFKit 内部状态（平板那条管线因此白过屏）。
    private var ocrRenderPDF: PDFDocument?
    /// 在途的网络 OCR 任务（页 → task）。留着句柄只为**关窗时能取消**：任务闭包捕获着
    /// `ocrRenderPDF`，不取消的话那份 PDF 会一直吊到网络请求自己结束（见 `teardown`）。
    private var ocrTasks: [Int: Task<Void, Never>] = [:]

    /// 取 OCR 渲染用的文档实例（懒建独立副本；拿不到 URL 时退回共用）。仅主线程调用。
    private func ocrRenderDocument() -> PDFDocument? {
        if let d = ocrRenderPDF { return d }
        guard let pdf else { return nil }
        let d = pdf.documentURL.flatMap { PDFDocument(url: $0) } ?? pdf
        ocrRenderPDF = d
        return d
    }

    var ocrDoneCount: Int { ocrRuns.count }
    var ocrTotalPages: Int { pdf?.pageCount ?? 0 }
    var ocrPendingCount: Int { ocrQueue.count + ocrActivePages.count }
    var ocrRunning: Bool { ocrPendingCount > 0 }

    /// 换文档时重置 OCR 状态；若该内容已有缓存则自动启用（缓存直接复用，无需重跑）。
    func reloadOCRState() {
        for t in ocrTasks.values { t.cancel() }   // 在途任务捕获着旧 ocrRenderPDF，不取消就放不掉那份文件
        ocrTasks = [:]
        ocrQueue = []; ocrInFlight = 0; ocrActivePages = []; ocrRuns = [:]; ocrLastError = nil
        ocrCacheLoading = []   // 在途的后台缓存读回来按 contentHash 核对，对不上就丢
        ocrEnabled = false
        ocrRenderPDF = nil   // 换文档 → 丢弃旧的 OCR 渲染副本，下次用时按新 pdf 懒建
        invalidateOCRDerived(); wmProfile = OCRWatermark.Profile(); wmProfilePages = 0
        guard let store, !contentHash.isEmpty else { return }
        if let c = try? store.ocrPageCount(contentHash: contentHash, provider: PaddleOCR.providerID), c > 0 {
            ocrEnabled = true
            rebuildWatermarkProfile()   // 库里已有整本的识别结果 → 第一页就能按跨页统计滤水印
        }
    }

    /// 用户在 OCR 面板里开关。开 → 立刻处理当前页（reader 的可见窗口会补齐其余）。
    func setOCREnabled(_ on: Bool) {
        ocrEnabled = on
        if on { enqueueOCR([currentPageIndex]) }
    }

    /// 手动「识别全部页」：全量入队（缓存命中的秒回，其余排队跑）。
    func ocrAllPages() {
        ocrEnabled = true
        enqueueOCR(Array(0..<ocrTotalPages))
    }

    /// 入队若干页：已识别/在跑/在队的跳过；缓存命中直接应用（不占网络槽）；缺失且已配置 key 才排队跑网络。
    ///
    /// 🔴 **缓存读在后台，一批一次写 `ocrRuns`**（2026-09-10 第三批账本：有 OCR 缓存的那本冷开后首帧
    /// 到 `下一拍` 之间主线程连着忙 350ms、阅读区 body 跑了 7 次，没缓存的那本只要 50ms——这条原来在
    /// `updateRealized` 里**同步**读每页几十 KB 的 blob（外置盘、冷缓存）再逐页写 @Published，
    /// 一页一次整窗重算）。读完回主线程按 contentHash 核对，一次合并写入。
    func enqueueOCR(_ pages: [Int]) {
        guard ocrEnabled else { return }
        let want = pages.filter { p in
            p >= 0 && p < ocrTotalPages && ocrRuns[p] == nil && !ocrActivePages.contains(p)
                && !ocrQueue.contains(p) && !ocrCacheLoading.contains(p)
        }
        guard !want.isEmpty else { pumpOCR(); return }
        ocrCacheLoading.formUnion(want)
        guard let store else { ocrCacheLoading.subtract(want); return }
        let hash = contentHash
        Task.detached(priority: .userInitiated) { [weak self] in
            var found: [Int: [TextRun]] = [:]
            let dec = JSONDecoder()
            for p in want {
                if let row = try? store.ocrPage(contentHash: hash, page: p, provider: PaddleOCR.providerID),
                   let payload = try? dec.decode(OCRPagePayload.self, from: row.payload) {
                    found[p] = payload.runs
                }
            }
            await MainActor.run { [weak self] in
                guard let self, self.contentHash == hash else { return }
                self.ocrCacheLoading.subtract(want)
                guard self.ocrEnabled else { return }
                if !found.isEmpty {
                    var runs = self.ocrRuns
                    for (p, r) in found where runs[p] == nil { runs[p] = r }
                    self.ocrRuns = runs      // 一次写 = 一次整窗重算，而不是一页一次
                    self.openTrace?.mark("OCR缓存到位", "\(found.count)页 后台")
                }
                if PaddleOCR.configFromDefaults() != nil {
                    for p in want where found[p] == nil && self.ocrRuns[p] == nil
                        && !self.ocrActivePages.contains(p) && !self.ocrQueue.contains(p) {
                        self.ocrQueue.append(p)
                    }
                }
                self.pumpOCR()
            }
        }
    }
    /// 正在后台读缓存的页（别重复读）。换文档 `reloadOCRState` 清空。
    private var ocrCacheLoading = Set<Int>()

    private func pumpOCR() {
        while ocrInFlight < ocrMaxConcurrent, !ocrQueue.isEmpty {
            startNetworkOCR(ocrQueue.removeFirst())
        }
    }

    private func startNetworkOCR(_ page: Int) {
        guard let pdf = ocrRenderDocument(), let config = PaddleOCR.configFromDefaults() else { return }
        let hash = contentHash
        ocrActivePages.insert(page)
        ocrInFlight += 1
        ocrTasks[page] = Task { [weak self] in
            let img = await Self.renderPageForOCR(pdf: pdf, page: page)
            var runs: [TextRun]?
            var err: String?
            if let img {
                do { runs = try await PaddleOCR.recognize(image: img, config: config) }
                catch { err = error.localizedDescription }
            }
            let imgW = img.map { Double($0.width) } ?? 0
            let imgH = img.map { Double($0.height) } ?? 0
            await MainActor.run {
                guard let self else { return }
                // 换文档后旧任务回来：内容 hash 变了就整个丢弃——此时新文档的计数器已被 reloadOCRState 归零，
                // 绝不能再动它（否则 ocrInFlight 被减成负、并发失控）。
                guard self.contentHash == hash else { return }
                self.ocrInFlight -= 1
                self.ocrActivePages.remove(page)
                self.ocrTasks.removeValue(forKey: page)
                if let runs {
                    self.ocrRuns[page] = runs
                    self.saveCachedOCR(page: page, runs: runs, imgW: imgW, imgH: imgH)
                } else if let err {
                    self.ocrLastError = err
                }
                self.pumpOCR()
            }
        }
    }

    private static func renderPageForOCR(pdf: PDFDocument, page: Int, pixelWidth: Int = 2400) async -> CGImage? {
        await withCheckedContinuation { cont in
            ocrRenderQueue.async {
                cont.resume(returning: pdf.page(at: page).flatMap { PageBitmap.render(page: $0, pixelWidth: pixelWidth) })
            }
        }
    }


    private func saveCachedOCR(page: Int, runs: [TextRun], imgW: Double, imgH: Double) {
        guard let store,
              let data = try? JSONEncoder().encode(OCRPagePayload(w: imgW, h: imgH, runs: runs)) else { return }
        try? store.upsertOCRPage(OCRPage(contentHash: contentHash, page: page,
                                         provider: PaddleOCR.providerID, payload: data,
                                         lang: nil, createdAt: Date()))
        // 边跑边识别的新书：每多攒够一批页就重建一次水印指纹（样本越多越准；
        // 样本不足时 `OCRWatermark.mask` 只靠同页伙伴那条判据兜着）。
        if ocrRuns.count >= wmProfilePages + OCRWatermark.minRepeatPages { rebuildWatermarkProfile() }
    }

    // MARK: - 关窗收尾

    /// 关窗时**立刻**放掉本会话持有的一切文件引用：两份 `PDFDocument`（阅读区的 + OCR 渲染副本）、
    /// 库连接引用、在途的网络 OCR 任务（它们捕获着 OCR 那份 PDF）。
    ///
    /// ⚠️ 为什么要显式做、而不是等这个 `DocSession` 自己析构：它的强引用在 `ContentView` 的
    /// `@StateObject` 里，SwiftUI 关窗后何时释放没有保证；只要 `PDFDocument` 活着，那本 PDF 的文件
    /// 就一直被打开着，工作区所在的**可移动硬盘弹不出去**（用户 2026-08-05 报）。
    ///
    /// ⚠️ **严禁在这里清 `strokes` / `inkLayers` / `textNotes` / `highlights` / `scratchPads` /
    /// `scratchStrokes`**：它们的落库是 `ContentView` 里的 `onChange` 增量对账，清空 = 对账认定
    /// 「用户删光了」→ 把整篇笔记从库里删掉。本方法只碰**文件引用**，不碰任何会被对账看到的数据。
    func teardown() {
        clearSearch()
        for t in ocrTasks.values { t.cancel() }
        ocrTasks = [:]
        ocrQueue = []
        ocrRenderPDF = nil
        // 这份文档的页图缓存整批清掉（`docKey` 就是 contentHash，见 `ContentView` 传给阅读区那处）。
        // 不清的话关窗/换文档后那几百 MB 会一直挂到被别的文档慢慢挤掉——引擎内部会先确认
        // 没有别的窗口还在看同一份文档，多窗口场景不会误伤。**必须赶在 contentHash 清空之前。**
        // 先把本会话自己的阅读区从「还在看」的名单里摘掉（理由见 `renderClients`），否则清不动。
        for (c, cleanup) in renderClients {
            PageRenderEngine.shared.setWanted([], client: c)
            PageHoldings.shared.remove(client: c)
            cleanup()
        }
        renderClients.removeAll()
        PageRenderEngine.shared.purge(doc: contentHash)
        contentHash = ""     // 在途 OCR 任务回主线程时按 hash 自弃（既有机制），不会再动已清空的状态
        store = nil
        toc = []
        weak var probe = pdf
        pdf = nil
        // 诊断：`pdf` 置 nil 后这份文档理应立刻销毁；若 SwiftUI 视图树还吊着它（阅读区/缩略图列表
        // 是按值传进去的），文件就还开着 —— 静默失效最难查，留个可开关的观察窗口（见 `wsLog`）。
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            if probe != nil { wsLog("teardown：⚠️ PDFDocument 仍存活（文件未关闭）\(self?.title ?? "")") }
        }
    }
}
