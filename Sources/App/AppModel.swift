import Foundation
import PDFKit
import Combine

/// 本机指针工具：Mac 鼠标/触控板在阅读区干什么——默认文字选择；`.ink` = 本机直接落墨/擦除
/// （共用笔架当前选中笔与橡皮）；`.lasso` = 框选移动/缩放（页内：同页笔迹+文字注解；草稿纸：纸上笔迹）。
enum PointerTool: String {
    case textSelect
    case ink
    case lasso
    /// 框选截图：拖一个矩形 → 按页重渲染 → 塞进 AI 面板当前对话（见 `ReaderSurface+Snip`）。
    /// 常驻用这个；临时截一块直接按住 ⌥ 拖即可，不必切工具。
    case snip
}

/// 橡皮擦除模式：整笔（任一点命中即删整条）/ 局部（剔除命中点、剩余连续段各成新笔画）。
enum EraserMode: String, CaseIterable {
    case stroke, partial
    var label: String { self == .stroke ? L("Whole Stroke") : L("Partial") }
}

/// App 级单例：持有唯一的 `LANServer`，管理所有打开中的 `DocSession`。
/// 平板显示的会话 = 平板手动选中的（padSelectedSessionID），否则跟随最后激活窗口（activeSessionID）。
final class AppModel: ObservableObject {
    let server = LANServer()
    @Published private(set) var sessions: [DocSession] = []
    @Published var activeSessionID: UUID?
    @Published var padSelectedSessionID: UUID?

    /// 平板要打开一个尚未打开的工作区文档 → 请某个窗口去开新窗口（`openWindow` 是 View 层的
    /// environment action，App 级单例够不着）。`sessionID` = 该由哪个窗口执行，其余窗口忽略，
    /// 否则每个窗口都会开一个。
    struct PadOpenDocRequest: Equatable {
        let id = UUID()
        let sessionID: UUID
        let workspacePath: String
        let docId: String
    }
    @Published var padOpenDocRequest: PadOpenDocRequest?
    /// 平板请求切画板模式（`canvas` 上行）：由 `sessionID` 那个窗口的 ContentView 认领并落库。
    struct PadCanvasRequest: Equatable {
        let id = UUID()
        let sessionID: UUID
        let on: Bool
    }
    @Published var padCanvasRequest: PadCanvasRequest?
    /// 平板发起 `openDoc` 后等待就位的库文档 id：新窗口装好它就把平板锁过去（见 `sessionDocumentChanged`）。
    private var pendingPadFollowDocId: String?
    /// `library`/`toc` 广播去重签名（内容没变就不重发，同 `pushedLayoutKey`）。
    private var pushedLibraryKey = ""
    private var pushedTOCKey = ""

    /// 平板当前工具状态镜像（设备级，跟文档无关）：驱动 Mac 阅读区悬浮笔工具条。
    /// "note" | "erase" | "page"，与 capture.html 的 MODES.key 同值。
    @Published var padMode: String = "note"
    /// 当前笔在 `pens` 里的下标。
    @Published var padPenIndex: Int = 0
    /// 本机指针工具（见 `PointerTool`）。设备级全局、与 `padMode` 同生命周期：笔架是每个窗口都显示的
    /// 设备级控制面板，各窗口手势只读这个全局开关，多窗口不会互相打架。
    @Published var pointerTool: PointerTool = .textSelect
    /// 收藏笔列表（唯一状态源）：画布悬浮工具条实时增删改，自动落盘 + 广播给 pad。不再走系统设置页配置。
    @Published var pens: [PenPreset] = PenPresets.load() {
        didSet {
            PenPresets.save(pens)
            broadcastPens()
        }
    }
    /// 橡皮半径（页宽归一化，默认 0.02；直径 = 2×半径）：本机持久化，改动即广播 `eraser` 给 pad 双向对齐。
    @Published var eraserRadius: Double = AppModel.loadEraserRadius() {
        didSet {
            UserDefaults.standard.set(eraserRadius, forKey: AppModel.eraserRadiusKey)
            broadcastEraser()
        }
    }
    private static let eraserRadiusKey = "eraserRadius"
    private static func loadEraserRadius() -> Double {
        let v = UserDefaults.standard.double(forKey: eraserRadiusKey)
        return v > 0 ? v : 0.02
    }
    /// 橡皮模式（整笔/局部，默认局部）与尺寸圆环开关（默认开）：与 eraserRadius 同款持久化 + didSet 广播。
    @Published var eraserMode: EraserMode = EraserMode(rawValue: UserDefaults.standard.string(forKey: "eraserMode") ?? "") ?? .partial {
        didSet {
            UserDefaults.standard.set(eraserMode.rawValue, forKey: "eraserMode")
            broadcastEraser()
        }
    }
    @Published var eraserRing: Bool = UserDefaults.standard.object(forKey: "eraserRing") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(eraserRing, forKey: "eraserRing")
            broadcastEraser()
        }
    }
    /// 应用平板上行 `eraser` 时置真：抑制 didSet 的回播（值来自 pad，回声无意义还会三连发）。
    private var applyingRemoteEraser = false

    private var cancellables = Set<AnyCancellable>()

    // 环形选笔盘 · 长按检测（全部在 Mac 端）。平板只发笔事件；这里判「落笔停住 1s」呼出、笔移选中、抬笔提交。
    private var longPressWork: DispatchWorkItem?
    private var inkStart: (page: Int, nx: Double, ny: Double)?
    private var inkMovedFar = false
    private var inRadial = false
    private let longPressSeconds = 1.0
    /// 平板这一笔是不是直线（尺子）笔：ink begin 的 flags bit0 带来，决定后续 move 是替换终点还是追加点。
    /// **非 private**：草稿纸链路（`AppModel+Scratch`）要用同一个标记——漏了它，平板上用尺子画的直线
    /// 到了草稿纸上会把一路的中间终点全追加进来，成一条歪歪扭扭的线。
    var padInkLine = false
    /// 平板上报的内容页宽（CSS px）。长按/选盘的距离阈值都是**平板屏幕上的**物理尺度，必须用它换算——
    /// 用 Mac 阅读区页宽（`pageViewWidth`）换算的话，手感会随任意一端的缩放漂移。0 = 平板没上报（旧端）。
    private var padPageWidth: Double = 0
    private let moveCancelPx = 14.0        // 平板屏幕位移超此值 → 判为在画，不呼出
    private let moveCancelNorm = 0.02      // 同上，`padPageWidth` 未知时的归一化回退
    private let radialDeadzoneNorm = 0.045 // 中心取消区，`padPageWidth` 未知时的归一化回退

    /// 长按判据的**第二道闸：笔尖速度**（2026-08-28 用户报「很容易误触」）。
    ///
    /// 只看「离落笔点的总位移」挡不住小字：写一个小字全程都在 14px 半径里打转，
    /// 停留满 1s 就被当成长按，盘凭空弹出来。而**写字必然在动、长按必然不动**——
    /// 用滑动窗口内的平均速度一判就分得干净。两道闸并存：位移管「跑远了」，速度管「一直在动」。
    ///
    /// ⚠️ 这三个数与安卓模式1 的 `PadConst.LP`（`SPEED_WINDOW_MS`/`MOVE_CANCEL_SPEED`/
    /// `MOVE_CANCEL_SPEED_NORM`）是**同一套常量的两份实现**，改一边必须同步另一边，
    /// 否则同一个动作在两种模式下呼出不同的东西。
    private let holdSpeedWindow = 0.15     // 速度判定的滑动窗口（秒）
    private let holdSpeedPx = 30.0         // 窗口内平均速度超此 平板px/s → 判为在画
    private let holdSpeedNorm = 0.043      // 同上的归一化/秒回退（≈ holdSpeedPx / 700，与位移那对同比例）

    /// 长按候选期间的笔位采样（y 已乘页面纵横比折成与 x 同尺度），只保留窗口内的那几个。
    private var holdSamples: [(p: SIMD2<Double>, t: Date)] = []

    /// 已经下发给平板的环/盘状态，**记在 AppModel（设备级）而不是 `DocSession` 上**。
    ///
    /// 🔴 2026-09-02 修：`padSession` 是**计算属性**（`padSelectedSessionID ?? activeSessionID`），
    /// 手势中途切个标签它就换了一个对象。从前的去重写成 `guard padSession?.pressRing != r`，
    /// 于是「撤环」那一帧会被新会话的空状态吃掉（`nil != nil` 为假 → 直接 return）——
    /// 平板上就留着一个永远不消失的环。判定本身是设备级的（`inkStart`/`inRadial` 都在这儿），
    /// 下发记账也必须跟着放在设备级。
    private var sentPressRing: PressRing?
    /// 环/盘当前挂在哪个会话上（换会话时把旧的那份清掉，否则旧标签上会残留一个画不掉的环/盘）。
    private weak var overlaySession: DocSession?

    init() {
        // 平板翻页 → 应用到平板当前会话，并重推页图。
        server.$requestedPageIndex
            .compactMap { $0 }
            .receive(on: RunLoop.main)
            .sink { [weak self] idx in
                guard let self, let s = self.padSession else { return }
                if s.currentPageIndex != idx { s.currentPageIndex = idx }
                self.push()
            }
            .store(in: &cancellables)

        // 服务启动后立即推一次当前页、文档列表、收藏笔列表。
        server.$isRunning
            .receive(on: RunLoop.main)
            .sink { [weak self] running in
                if running {
                    self?.push(); self?.broadcastDocs(); self?.broadcastPens(); self?.broadcastEraser()
                    self?.broadcastLibrary(force: true); self?.broadcastTOC(force: true)
                    self?.broadcastBookmarks()
                    self?.broadcastScratchPads(); self?.broadcastScratchStrokes()
                    self?.broadcastCanvas()   // 画板模式：新起的服务也要把当前状态交代一遍
                }
            }
            .store(in: &cancellables)

        // 某个客户端堵住、追加队列被迫作废 → 重发一份全量把它拉回同步（见 `LANServer.desync`）
        server.onMirrorDesync = { [weak self] in
            DispatchQueue.main.async { self?.broadcastStrokes(); self?.broadcastScratchStrokes() }
        }

        // 新平板连接 → 补发文档列表、当前页、收藏笔列表、当前阅读位置。
        server.$clientCount
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.broadcastDocs(); self?.push(); self?.pushLayout(force: true); self?.broadcastPens(); self?.broadcastEraser(); self?.broadcastStrokes(); self?.broadcastNotes(); self?.broadcastLayers()
                self?.broadcastLibrary(force: true); self?.broadcastTOC(force: true)   // 新客户端要补书库 + 目录
                self?.broadcastBookmarks()                                             // 书签与目录合并显示，一起补
                self?.broadcastScratchPads(); self?.broadcastScratchStrokes()          // 草稿纸列表 + 开着那张的笔迹
                // 画板模式（PROTOCOL.md `canvas`）：Mac 是唯一真源，但只在切开关/跳档时广播 ——
                // 新客户端不补这一发就永远收不到（`pushStrokesIfDocChanged` 那处被 pushedStrokesKey
                // 挡住，同一本书不会再触发）。表现：Mac 开着画板，平板/安卓模式2 连上来仍是页宽布局，
                // 页边笔迹被裁掉、写到页边也回不去。必须在 pushLayout 之后（layout 会重置几何）。
                self?.broadcastCanvas()
                self?.pushCurrentViewport()   // 必须在 pushLayout 之后：平板端收到 layout 会重置滚动/seq
            }
            .store(in: &cancellables)

        // 平板切换文档。
        server.$requestedDocID
            .compactMap { $0 }
            .receive(on: RunLoop.main)
            .sink { [weak self] id in self?.selectPadDoc(id) }
            .store(in: &cancellables)

        // 平板点目录/输入页码 → 跳到（页, 页内比例）。走的是与 Mac 侧点目录同一条 origin="toc"
        // 锚点路径：阅读区跟随滚动，`macScrolled` 再把结果 viewport 回推给所有客户端。
        server.$requestedGoto
            .compactMap { $0 }
            .receive(on: RunLoop.main)
            .sink { [weak self] t in
                guard let self, let s = self.padSession else { return }
                // 走 `jump` 而不是裸 `emitAnchor`：平板点目录/输入页码同样是「非连续跳转」，
                // 该和 Mac 侧点目录一样在跳转历史里留一条（`JumpHistory`）。
                s.jump(page: t.page, frac: t.frac, kind: .toc)
                self.push()
            }
            .store(in: &cancellables)

        // 平板请求打开工作区里的某个文档（库文档 id）。
        server.$requestedOpenDocID
            .compactMap { $0 }
            .receive(on: RunLoop.main)
            .sink { [weak self] id in self?.openPadDoc(id) }
            .store(in: &cancellables)

        // 平板手写/擦除消息 → 应用到平板当前会话。
        server.onMessage = { [weak self] obj in self?.handleInk(obj) }

        // 方案 B：平板按需取任意页图（带缓存，服务 queue 上调用）。
        server.pageProvider = { [weak self] req in self?.renderPage(req) }
        server.docMetaProvider = { [weak self] id in self?.refDocMeta(id) }

        // 方案 B：平板本地滚动 → 落为平板当前会话的锚点（origin=pad），驱动 Mac PDFView 跟随。
        server.onScroll = { [weak self] page, frac, t in
            guard let self, let s = self.padSession else { return }
            s.emitAnchor(page: page, frac: frac, origin: "pad", senderT: t)
        }
    }

    // MARK: - 方案 B：按页渲染缓存

    private let renderLock = NSLock()
    private var padRenderPDF: PDFDocument?
    private var padRenderKey = ""              // = 文档 contentHash，作缓存/版本键
    /// 平板页图缓存。**按字节记额度**（`cost` = 编码后的字节数）：档位化之后同一页会有不止一份，
    /// 按条数记的 `countLimit` 拦不住内存。256MB 够装满一整本中等厚度的书的常看那几十页。
    private let pageCache: NSCache<NSString, NSData> = {
        let c = NSCache<NSString, NSData>()
        c.totalCostLimit = 256 * 1024 * 1024
        return c
    }()

    /// 更新按页渲染的文档源；文档变（key 变）时清空页图缓存。主线程调用。
    ///
    /// ⚠️ **必须为平板另开一个 `PDFDocument` 实例，严禁共用 `session.pdf`**（2026-07-27 实测定）：
    /// PDFKit 的 `PDFDocument`/`PDFPage` 不是线程安全的，而两条渲染管线跑在不同队列上——
    /// 平板页图在 `LANServer` 的服务 queue（`pageProvider` → `renderPage`），Mac 阅读区在
    /// `PageRenderEngine` 的串行队列。共用同一个文档对象 = 两个后台队列并发操作同一份 PDFKit
    /// 内部状态，实测表现为 **Mac 阅读区整片白屏、须手动翻页才恢复**（旧实现里平板那张图是在
    /// 主线程渲的，撞不上；把它挪下主线程修翻页卡顿后，这条竞争才暴露出来）。
    /// 各开各的实例即彻底解耦：`PDFDocument` 惰性解析，多开一份主要只是 xref 表的内存。
    /// 取不到 URL（极少见）时退回共用——功能优先，这条路径本来就没有并发保证。
    private func setPadRender(pdf: PDFDocument, key: String) {
        renderLock.lock(); defer { renderLock.unlock() }
        // 同文档已建好独立实例就不重开（`push()` 每次翻页都会调进来）。
        guard padRenderKey != key || padRenderPDF == nil else { return }
        // ⚠️ **换文档不清 `pageCache`**（2026-08-29 修，用户报「平板切标签页每次都要重新加载 PDF 页」）：
        // 缓存键里本来就带 `padRenderKey`（= contentHash），两篇文档的页图不会串；一清，平板切回
        // 上一篇就得让 Mac 把每一页重渲一遍，而这活儿占的是 `LANServer` 那条串行 queue（连笔迹 RT
        // 一起压）。额度是按字节的 NSCache，多留一篇挤不爆；真挤了也只是按 LRU 淘汰。
        padRenderKey = key
        padRenderPDF = pdf.documentURL.flatMap { PDFDocument(url: $0) } ?? pdf
    }

    /// 已经没有任何会话在用这份平板渲染副本了 → **立刻**丢掉它。
    ///
    /// ⚠️ 这是个 App 级单例持有的独立 `PDFDocument`（= 一个一直开着的文件）：不显式清的话，
    /// 关掉全部窗口后它仍吊着最后看过的那本书，工作区所在的**可移动硬盘照样弹不出去**
    /// （用户 2026-08-05 报）—— 会话那边清干净了也没用，漏一处就前功尽弃。主线程调用。
    private func releasePadRenderIfUnused() {
        releaseRefRender()
        renderLock.lock(); defer { renderLock.unlock() }
        guard padRenderPDF != nil else { return }
        if !padRenderKey.isEmpty, sessions.contains(where: { $0.contentHash == padRenderKey }) { return }
        padRenderPDF = nil
        padRenderKey = ""
        pageCache.removeAllObjects()
    }

    // MARK: - 参考窗（`/page.png?d=` 与 `/docmeta?d=`）

    /// 参考文档的渲染实例。**又是独立的一份**，理由与 `padRenderPDF` 完全相同（PDFKit 文档对象
    /// 不能跨队列共用，2026-07-27 阅读区整片白屏那笔账）；这一份只归服务 queue 用。
    /// 只留最近一本——参考窗一次只看一本书，换书即换实例。
    private var refRenderPDF: PDFDocument?
    private var refRenderDocId = ""
    private var refRenderKey = ""      // = contentHash，页图缓存/磁盘缓存的键前缀

    /// 库文档 id → 路径/哈希/标题/进度。主线程注入（`WorkspaceManager` 是 `@MainActor`，
    /// 服务 queue 够不着它），由 `push()` 顺带从会话快照捎带过来。
    private var refIndex: [String: RefDocInfo] = [:]

    /// 服务 queue 上按 id 取参考文档的渲染实例。**必须在 `renderLock` 内调用。**
    private func refDocLocked(_ docId: String) -> (PDFDocument?, String) {
        if docId == refRenderDocId, refRenderPDF != nil { return (refRenderPDF, refRenderKey) }
        guard let info = refIndex[docId] else { return (nil, "") }
        let doc = PDFDocument(url: URL(fileURLWithPath: info.path))
        refRenderPDF = doc
        refRenderDocId = doc == nil ? "" : docId
        refRenderKey = doc == nil ? "" : (info.hash.isEmpty ? docId : info.hash)
        return (refRenderPDF, refRenderKey)
    }

    /// 参考窗要的文档元信息：页尺寸表 + 页数 + 进度。**JSON 走 HTTP，刻意不进线格式**——
    /// 加一条带大数组的消息就要三端同步 + 重出字节向量（`PROTOCOL.md` 开头那条），
    /// 而这只是客户端自己按需拉一次的只读数据（同 `/info` 的先例）。服务 queue 上调用。
    func refDocMeta(_ docId: String) -> Data? {
        renderLock.lock()
        let info = refIndex[docId]
        let (pdf, _) = refDocLocked(docId)
        renderLock.unlock()
        guard let info, let pdf else { return nil }
        var pages: [[Double]] = []
        pages.reserveCapacity(pdf.pageCount)
        for i in 0..<pdf.pageCount {
            guard let p = pdf.page(at: i) else { pages.append([612, 792]); continue }
            // 与页内笔迹/平板 `layout` 同一个口径：CropBox 有效则 CropBox、否则 MediaBox，含 rotation。
            let sz = PageBitmap.displaySize(p)
            pages.append([Double(sz.width), Double(sz.height)])
        }
        let dict: [String: Any] = [
            "title": info.title, "pageCount": pdf.pageCount,
            "readPage": info.readPage, "readFrac": info.readFrac, "pages": pages,
        ]
        return try? JSONSerialization.data(withJSONObject: dict)
    }

    /// 主线程注入参考索引（书库变了才会真的换一份）。
    private func setRefIndex(_ idx: [String: RefDocInfo]) {
        renderLock.lock()
        if idx.count != refIndex.count || idx != refIndex { refIndex = idx }
        renderLock.unlock()
    }

    /// 参考文档也要能**当场放掉**：它同样是「一直开着的文件」，漏一处工作区所在的可移动硬盘
    /// 就弹不出去（2026-08-05 那笔账）。主线程调用。
    func releaseRefRender() {
        renderLock.lock()
        refRenderPDF = nil
        refRenderDocId = ""
        refRenderKey = ""
        renderLock.unlock()
    }

    /// 渲染平板当前会话的第 idx 页（缓存命中直接返回）。服务 queue 上调用。
    /// `req.docId` 非空 = 参考窗在取**别的**文档的页图，走 `refRenderPDF` 那份实例。
    func renderPage(_ req: LANServer.PageImageRequest) -> Data? {
        let t0 = CFAbsoluteTimeGetCurrent()
        let idx = req.index
        renderLock.lock()
        let pdf: PDFDocument?
        let key: String
        if req.docId.isEmpty {
            pdf = padRenderPDF
            key = padRenderKey
        } else {
            (pdf, key) = refDocLocked(req.docId)
        }
        // 缓存键必须含宽度与格式：平板按视口宽度取图（`?w=`），同一页会有不止一个档位。
        let ck = "\(key)#\(idx)@\(req.width)/\(req.format.name)" as NSString
        if let cached = pageCache.object(forKey: ck) {
            renderLock.unlock()
            PadLog.log("页图 #\(idx)@\(req.width) 缓存命中 \(PadLog.ms(CFAbsoluteTimeGetCurrent() - t0))，\(cached.length / 1024)KB")
            return cached as Data
        }
        renderLock.unlock()

        // 内存没有再问磁盘：这张图很可能上次开这本书时就渲过了（跨换文档/关窗/重启都留着，
        // 见 `PageDiskCache`）。读几百 KB 是几毫秒，而重渲是 100~300ms 且压着本条串行 queue。
        if let disk = PageDiskCache.shared.data(for: ck as String), !disk.isEmpty {
            renderLock.lock(); pageCache.setObject(disk as NSData, forKey: ck, cost: disk.count); renderLock.unlock()
            PadLog.log("页图 #\(idx)@\(req.width) 磁盘命中 \(PadLog.ms(CFAbsoluteTimeGetCurrent() - t0))，\(disk.count / 1024)KB")
            return disk
        }

        PadLog.log("页图 #\(idx)@\(req.width) 未命中，开渲…")
        guard let pdf, idx >= 0, idx < pdf.pageCount, let page = pdf.page(at: idx),
              let data = PageRenderer.image(page: page, pixelWidth: CGFloat(req.width), format: req.format) else {
            PadLog.log("页图 #\(idx)@\(req.width) 渲染失败（\(PadLog.ms(CFAbsoluteTimeGetCurrent() - t0))）")
            return nil
        }
        // cost = 字节数：档位化之后同一页可能有好几份，按条数记的 NSCache 拦不住内存
        renderLock.lock(); pageCache.setObject(data as NSData, forKey: ck, cost: data.count); renderLock.unlock()
        PageDiskCache.shared.store(data, for: ck as String)   // 异步落盘，不占本条服务 queue
        PadLog.log("页图 #\(idx)@\(req.width) 渲染完成 \(PadLog.ms(CFAbsoluteTimeGetCurrent() - t0))，\(data.count / 1024)KB")
        return data
    }

    // MARK: - 手写路由

    private func handleInk(_ obj: [String: Any]) {
        // 平板几何上报（环形盘的像素判定要用）：与文档会话无关，放在 padSession 判空之前。
        if obj["type"] as? String == "padGeom" {
            padPageWidth = max(0, (obj["pageW"] as? NSNumber)?.doubleValue ?? 0)
            return
        }
        // 平板改笔宽/橡皮尺寸：设备级状态（不挂文档会话），同样放判空之前。
        if obj["type"] as? String == "penset" { applyPenSet(obj); return }
        if obj["type"] as? String == "eraser" {
            applyingRemoteEraser = true
            defer { applyingRemoteEraser = false }
            let v = (obj["size"] as? NSNumber)?.doubleValue ?? 0
            if v > 0 { eraserRadius = v }
            eraserMode = ((obj["mode"] as? NSNumber)?.intValue ?? 1) == 0 ? .stroke : .partial
            eraserRing = ((obj["ring"] as? NSNumber)?.intValue ?? 1) != 0
            return
        }
        guard let s = padSession else { return }
        // 草稿纸打开时，笔只能落在草稿纸上（功能定义，用户要求）：`ink`/`erase`/`probe` 整条拦下改走
        // 画布坐标那套（见 `AppModel+Scratch`）。线格式没改——Mac 是「哪张纸开着」的唯一真源。
        if handleScratchInput(obj, to: s) { return }
        switch obj["type"] as? String {
        case "ink":
            let phase = obj["phase"] as? String ?? ""
            if phase == "begin" {
                let page = (obj["page"] as? NSNumber)?.intValue ?? s.currentPageIndex
                let pen = obj["pen"] as? [String: Any]
                let color = InkColor.parse(pen?["color"] as? String)
                let w = (pen?["w"] as? NSNumber)?.doubleValue ?? 8
                let type = PenBrushType(rawValue: pen?["t"] as? String ?? "") ?? .ballpoint
                let pts = points(obj["pts"])
                // 直线（尺子）笔：整笔只有「起点 + 当前终点」两点，move 来的点是**替换终点**而不是追加
                // （吸附在平板侧做完，Mac 收到的已是吸附后的终点）。见 PROTOCOL.md §4.3 ink begin flags。
                padInkLine = (obj["line"] as? Bool) ?? false
                inkBegin(page: page, color: color, width: w, type: type, points: pts)
                beginLongPressWatch(page: page, first: pts.first)
            } else if phase == "move" {
                let pts = points(obj["pts"])
                if inRadial { updateRadial(pts.last) }
                else if padInkLine { inkLineTo(pts.last); checkLongPressMovement(pts.last) }
                else { inkAppend(pts); checkLongPressMovement(pts.last) }
            } else if phase == "end" {
                endInkOrRadial()
            }
        case "erase":
            if obj["phase"] as? String == "move" {
                let page = (obj["page"] as? NSNumber)?.intValue ?? s.currentPageIndex
                inkErase(points(obj["pts"]), page: page)
            }
        case "probe":
            // 擦除/翻页模式下的平行探针流：不落墨，只驱动长按检测/环形盘（pad 本地擦除/平移照跑）。
            let phase = obj["phase"] as? String ?? ""
            if phase == "begin" {
                let page = (obj["page"] as? NSNumber)?.intValue ?? s.currentPageIndex
                beginLongPressWatch(page: page, first: points(obj["pts"]).first)
            } else if phase == "move" {
                let pts = points(obj["pts"])
                if inRadial { updateRadial(pts.last) } else { checkLongPressMovement(pts.last) }
            } else if phase == "end" {
                endInkOrRadial()
            }
        case "hover":
            if (obj["phase"] as? String) == "end" {
                s.hover = nil
            } else {
                let page = (obj["page"] as? NSNumber)?.intValue ?? s.currentPageIndex
                let nx = (obj["nx"] as? NSNumber)?.doubleValue ?? 0
                let ny = (obj["ny"] as? NSNumber)?.doubleValue ?? 0
                s.hover = HoverPoint(page: page, nx: nx, ny: ny)
            }
        case "mode":
            if let m = obj["mode"] as? String { padMode = m }
        // 平板请求切画板模式（C→S 只有 on 有意义）。这里**不直接改 session**——开关要逐文档落库，
        // 而 `WorkspaceManager` 是 @MainActor、AppModel 够不着；照 `padOpenDocRequest` 的老路子
        // 发个请求，由那个窗口的 ContentView 认领（它知道 selectedDocID，也拿得到 workspace）。
        case "canvas":
            if let on = obj["on"] as? Bool {
                padCanvasRequest = PadCanvasRequest(sessionID: s.id, on: on)
            }
        case "pen":
            if let i = (obj["index"] as? NSNumber)?.intValue { padPenIndex = i }
        // 多层笔迹：平板只发「请求」，图层的增删改全部由 Mac 判定；应用后 s.inkLayers/activeLayerID
        // 的 @Published 变化被 ContentView 的 onChange 捕获→落库+broadcastLayers，权威状态自动回推。
        case "layerSelect":
            if let i = (obj["index"] as? NSNumber)?.intValue, s.inkLayers.indices.contains(i) {
                s.activeLayerID = s.inkLayers[i].id
            }
        case "layerVisible":
            if let i = (obj["index"] as? NSNumber)?.intValue, s.inkLayers.indices.contains(i) {
                s.inkLayers[i].visible = (obj["visible"] as? Bool) ?? false
            }
        case "layerAdd":
            let layer = InkLayer.next(after: s.inkLayers)
            s.inkLayers.append(layer)
            s.activeLayerID = layer.id
        case "textNote":
            applyTextNote(obj, to: s)
        case "bookmarkEdit":
            applyBookmarkEdit(obj, to: s)
        case "lassoMove":
            applyLassoMove(obj, to: s)
        case "lassoScale":
            applyLassoScale(obj, to: s)
        case "undo":
            applyUndo(obj, to: s)
        case "clip":
            applyClip(obj, to: s)
        // 草稿纸：平板只发「请求」，开哪张/新建全部由 Mac 判定（同多层笔迹的 layerSelect 一族）。
        case "scratchOpen":
            applyScratchOpen(obj, to: s)
        case "scratchAdd":
            applyScratchAdd(obj, to: s)
        case "scratchPaper":
            applyScratchPaper(obj, to: s)
        case "scratchMove":
            applyScratchMove(obj, to: s)
        case "scratchPageShow":
            applyScratchPageShow(obj, to: s)
        case "scratchDelete":
            applyScratchDelete(obj, to: s)
        case "scratchRename":
            applyScratchRename(obj, to: s)
        default:
            break
        }
    }

    // MARK: - 平板发起的框选移动/缩放（0x47 lassoMove / 0x4A lassoScale）

    /// 平板本地框选/拖动/缩放只是乐观预览（同 `eraseHit` 先例，命中算法客户端复刻一份）；真正的命中判定
    /// 与数据变更在这里用真源重做一遍——与 Mac 本机 `ReaderSurface+Lasso` 同一套算法（2026-08-17 起：
    /// 有多边形尾部按多边形命中——笔迹任一点/注解 anchor 中心落多边形内，`InkEdit.pointInPolygon`；
    /// 无尾部按矩形命中，兼容老客户端），只是这里没有 ghost 阶段：选区与位移/缩放一起送达，
    /// 一次性判定 + 变更 + 持久化 + 镜像回所有客户端。
    private func applyLassoMove(_ obj: [String: Any], to s: DocSession) {
        let page = (obj["page"] as? NSNumber)?.intValue ?? s.currentPageIndex
        let rawDx = (obj["dx"] as? NSNumber)?.doubleValue ?? 0
        let rawDy = (obj["dy"] as? NSNumber)?.doubleValue ?? 0
        guard rawDx != 0 || rawDy != 0 else { return }
        lassoApply(obj, to: s, page: page, label: "Move", kind: .move) { changed in
            // 🔴 两处都不能省（用户 2026-08-30 报「平板上框选移动把笔迹压缩了」）：
            //  ① `xRange` 要按画板模式放宽——不传就是默认页内 `0...1`，页边笔迹一移动就被
            //     逐点摁回页边（平板这条路径比 Mac 本机那条更糟：那边至少还是当前那档软边界）；
            //  ② 位移先经 `fitTranslation` 整体夹住再平移 = **刚性**，撞上边界也只是停住、不变形。
            let xr = CanvasMargin.xRange(margin: s.canvasMode ? CanvasMargin.limit : 0)
            let (dx, dy) = InkEdit.fitTranslation(
                dx: rawDx, dy: rawDy,
                inkBounds: InkEdit.bounds(changed.strokes.map { s.strokes[$0] }), xRange: xr,
                noteBounds: changed.notes.reduce(CGRect.null) { $0.union(s.textNotes[$1].anchor) })
            guard dx != 0 || dy != 0 else { return }
            // 打点（touch ~/Library/Logs/UniReader-pad.log 开）：这条一行就能判「压缩」出在哪一侧——
            // 夹后位移与原始位移差很多 = 撞了边界；x 区间是 0...1 = 画板没开到 Mac 这边。
            PadLog.log("框选移动 page=\(page) 命中 笔迹=\(changed.strokes.count) 注解=\(changed.notes.count) "
                       + "d=(\(String(format: "%.4f", rawDx)),\(String(format: "%.4f", rawDy)))"
                       + "→(\(String(format: "%.4f", dx)),\(String(format: "%.4f", dy))) "
                       + "canvas=\(s.canvasMode) x区间=\(String(format: "%.1f…%.1f", xr.lowerBound, xr.upperBound)) "
                       + "margin=\(String(format: "%.2f", s.canvasMarginLive))")
            for i in s.strokes.indices where s.strokes[i].page == page && changed.strokes.contains(i) {
                s.strokes[i] = InkEdit.translated(s.strokes[i], dx: dx, dy: dy, xRange: xr)
            }
            for i in s.textNotes.indices where s.textNotes[i].page == page && changed.notes.contains(i) {
                s.textNotes[i] = InkEdit.translated(s.textNotes[i], dx: dx, dy: dy)
            }
        }
    }

    /// 框选缩放提交（0x4A）：复判命中后 `InkEdit.scaled`（点集绕锚点按轴缩放 + clamp、线宽 ×√(sx·sy)、
    /// 注解 anchor/rects 同缩放），持久化 + 镜像，与 move 同一套机制。
    private func applyLassoScale(_ obj: [String: Any], to s: DocSession) {
        let page = (obj["page"] as? NSNumber)?.intValue ?? s.currentPageIndex
        let a = SIMD2((obj["ax"] as? NSNumber)?.doubleValue ?? 0,
                      (obj["ay"] as? NSNumber)?.doubleValue ?? 0)
        let sx = (obj["sx"] as? NSNumber)?.doubleValue ?? 1
        let sy = (obj["sy"] as? NSNumber)?.doubleValue ?? 1
        guard sx > 0, sy > 0, sx != 1 || sy != 1 else { return }
        lassoApply(obj, to: s, page: page, label: "Resize", kind: .scale) { changed in
            // xRange 同 applyLassoMove：不放宽的话画板模式下页边笔迹一缩放就被摁回页内
            let xr = CanvasMargin.xRange(margin: s.canvasMode ? CanvasMargin.limit : 0)
            for i in s.strokes.indices where s.strokes[i].page == page && changed.strokes.contains(i) {
                s.strokes[i] = InkEdit.scaled(s.strokes[i], anchor: a, sx: sx, sy: sy, xRange: xr)
            }
            for i in s.textNotes.indices where s.textNotes[i].page == page && changed.notes.contains(i) {
                s.textNotes[i] = InkEdit.scaled(s.textNotes[i], anchor: a, sx: sx, sy: sy)
            }
        }
    }

    /// lassoMove/lassoScale 共用：按消息里的选区（多边形尾部优先，否则 x0..y1 矩形）在真源上复判命中
    /// （只过滤可见图层；规则与 `ReaderSurface+Lasso.finishLassoSelect` 严格一致），命中下标交给
    /// `mutate` 做平移/缩放；有实际变更才广播镜像（落库由 ContentView 值快照对账自动做）。
    /// 按消息里的选区在**真源**上复判命中，返回命中的下标集（`lassoApply` 与剪贴板 copy/cut 共用）。
    /// 选区：多边形尾部（≥3 点）优先；否则 `x0..y1` 矩形（兼容老客户端）。
    /// 规则与 Mac 本机 `ReaderSurface+Lasso.finishLassoSelect` 严格一致——笔迹任一点落多边形内、
    /// 注解 anchor 中心落多边形内，且只认可见图层。
    private func lassoHits(_ obj: [String: Any], in s: DocSession, page: Int)
    -> (strokes: Set<Int>, notes: Set<Int>) {
        s.inkEnsureLoaded?(page)   // 笔迹按页窗口装载：这一页不在内存里就先同步补读，否则命中的是空集
        var poly: [SIMD2<Double>]?
        if let flat = obj["poly"] as? [Any], flat.count >= 6 {
            let vals = flat.map { ($0 as? NSNumber)?.doubleValue ?? 0 }
            poly = stride(from: 0, to: vals.count - vals.count % 2, by: 2).map { SIMD2(vals[$0], vals[$0 + 1]) }
        }
        let x0 = (obj["x0"] as? NSNumber)?.doubleValue ?? 0
        let y0 = (obj["y0"] as? NSNumber)?.doubleValue ?? 0
        let x1 = (obj["x1"] as? NSNumber)?.doubleValue ?? 0
        let y1 = (obj["y1"] as? NSNumber)?.doubleValue ?? 0
        let rect = CGRect(x: min(x0, x1), y: min(y0, y1), width: abs(x1 - x0), height: abs(y1 - y0))
        func strokeHit(_ p: InkPoint) -> Bool {
            if let poly { return InkEdit.pointInPolygon(SIMD2(p.dx, p.dy), polygon: poly) }
            return rect.contains(CGPoint(x: p.dx, y: p.dy))
        }
        func noteHit(_ n: TextNote) -> Bool {
            if let poly { return InkEdit.pointInPolygon(SIMD2(n.anchor.midX, n.anchor.midY), polygon: poly) }
            return rect.intersects(n.anchor) || rect.contains(CGPoint(x: n.anchor.midX, y: n.anchor.midY))
        }
        let vis = s.visibleLayerIDs
        var hitS = Set<Int>(), hitN = Set<Int>()
        for i in s.strokes.indices where s.strokes[i].page == page && vis.contains(s.strokes[i].layerId) {
            if s.strokes[i].points.contains(where: strokeHit) { hitS.insert(i) }
        }
        for i in s.textNotes.indices where s.textNotes[i].page == page {
            if noteHit(s.textNotes[i]) { hitN.insert(i) }
        }
        return (hitS, hitN)
    }

    private func lassoApply(_ obj: [String: Any], to s: DocSession, page: Int,
                            label: String, kind: InkPatch.Kind,
                            mutate: (_ changed: (strokes: Set<Int>, notes: Set<Int>)) -> Void) {
        let (hitS, hitN) = lassoHits(obj, in: s, page: page)
        guard !hitS.isEmpty || !hitN.isEmpty else {
            // 零命中也要回传未变镜像：客户端提交后进入乐观预览并等回传（web/安卓都是「两条镜像
            // 到齐才清预览」），不回传它只能等 1s 超时弹回——慢网络下肉眼可见闪烁（2026-08-18 用户报）。
            if s.id == padSession?.id { broadcastStrokes(); broadcastNotes() }
            return
        }
        s.inkEdit(label, kind: kind) { mutate((hitS, hitN)) }   // 撤销记账（平板发起的这条路径同样可撤）
        // 页边软边界得跟上：笔画**数**没变，阅读区那个 `onChange(of: strokes.count)` 不会触发
        // （Mac 本机框选是在 commitLassoMove 里显式补的一次，平板这条路径当初漏了）。
        // 不补的后果不是「压缩」而是「看不见」：笔迹被挪到当前内容宽之外，两端都画在可视区外面。
        s.inkMovedRev &+= 1
        if s.id == padSession?.id { broadcastStrokes(); broadcastNotes() }
    }

    // MARK: - 平板发起的撤销/重做（0x4F undo）与剪贴板（0x51 clip）

    /// 平板按了撤销/重做。**栈只有 Mac 一份**，平板不做乐观预览（`PROTOCOL.md §4.1`）：
    /// 撤/重做哪一条栈按「此刻开着哪张画布」选，与 Mac 上 ⌘Z 的语义逐字一致。
    private func applyUndo(_ obj: [String: Any], to s: DocSession) {
        let redo = (obj["redo"] as? Bool) ?? ((obj["redo"] as? NSNumber)?.boolValue ?? false)
        if s.openPadID != nil { undoScratch(in: s, redo: redo) } else { undoInk(in: s, redo: redo) }
        PadLog.log("平板\(redo ? "重做" : "撤销")：\(s.openPadID != nil ? "草稿纸" : "页内")")
    }

    /// 平板发起的剪切/复制/粘贴。剪贴板是 **Mac 的系统剪贴板**，线上不传数据（`PROTOCOL.md §4.1`）
    /// —— 于是平板复制的东西能在 Mac 上粘、也能粘进另一篇文档。
    ///
    /// copy/cut 的命中同样**用真源复判**（`lassoHits`，与 `lassoMove` 同一套），不信任平板的本地判定。
    private func applyClip(_ obj: [String: Any], to s: DocSession) {
        let op = obj["op"] as? String ?? "copy"
        let page = (obj["page"] as? NSNumber)?.intValue ?? s.currentPageIndex
        if op == "paste" { applyClipPaste(obj, to: s, page: page); return }

        // 草稿纸开着时，选区/坐标都是画布坐标，跟页内这套命中对不上 —— 直接不理（平板那边也不会给入口）。
        guard s.openPadID == nil else { PadLog.log("平板 clip \(op)：草稿纸开着，忽略"); return }
        let (hitS, hitN) = lassoHits(obj, in: s, page: page)
        guard !hitS.isEmpty || !hitN.isEmpty else { PadLog.log("平板 clip \(op)：零命中"); return }
        let strokes = hitS.map { s.strokes[$0] }
        let notes = hitN.map { s.textNotes[$0] }
        InkClipboard.write(strokes: strokes, notes: notes, space: .page,
                           aspect: pageAspect(of: s, page: page))
        PadLog.log("平板 clip \(op)：笔迹 \(strokes.count) 注解 \(notes.count)")
        guard op == "cut" else { return }
        let goneS = Set(strokes.map(\.id)), goneN = Set(notes.map(\.id))
        s.inkEdit("Delete", kind: .delete) {
            s.strokes.removeAll { goneS.contains($0.id) }
            s.textNotes.removeAll { goneN.contains($0.id) }
        }
        s.inkMovedRev &+= 1
        if s.id == padSession?.id { broadcastStrokes(); broadcastNotes() }
    }

    /// 粘贴：落点 = 平板给的页内归一化点（内容包围盒中心对齐到它）。摆放数学走 `InkPaste`
    /// （与 Mac 本机 ⌘V 同一份纯函数）。草稿纸开着时粘到纸上（画布坐标，另一条）。
    private func applyClipPaste(_ obj: [String: Any], to s: DocSession, page: Int) {
        guard let clip = InkClipboard.read() else { PadLog.log("平板 clip paste：剪贴板空"); return }
        s.inkEnsureLoaded?(page)   // 粘贴进未装载的页：先把那页读进来，新笔迹才按「后画在上」排在库批之后
        let nx = (obj["nx"] as? NSNumber)?.doubleValue ?? 0.5
        let ny = (obj["ny"] as? NSNumber)?.doubleValue ?? 0.5
        if let padID = s.openPadID {
            // 纸上：落点是**画布坐标**——平板发的是页内归一化，这里没有它的视口可换算，
            // 故一律落在画布原点附近（纸打开时视口就居中在原点）。够用：粘完就能拖着摆。
            let out = InkPaste.placeOnCanvas(strokes: clip.strokes, space: clip.space,
                                             sourceAspect: clip.aspect, pad: padID, center: nil)
            guard !out.isEmpty else { return }
            s.scratchEdit("Paste", kind: .paste) { s.scratchStrokes.append(contentsOf: out) }
            PadLog.log("平板 clip paste：纸上 \(out.count) 条")
            if s.id == padSession?.id { broadcastScratchStrokes() }
            return
        }
        let xr = CanvasMargin.xRange(margin: s.canvasMode ? CanvasMargin.limit : 0)
        let out = InkPaste.place(
            strokes: clip.strokes, notes: clip.notes, space: clip.space, sourceAspect: clip.aspect,
            page: page, center: CGPoint(x: nx, y: ny), targetAspect: pageAspect(of: s, page: page),
            xRange: xr, layers: Set(s.inkLayers.map(\.id)),
            fallbackLayer: s.activeLayerID ?? InkLayer.defaultID,
            types: Set(s.noteTypes.map(\.id)))
        guard !out.strokes.isEmpty || !out.notes.isEmpty else { return }
        s.inkEdit("Paste", kind: .paste) {
            s.strokes.append(contentsOf: out.strokes)
            s.textNotes.append(contentsOf: out.notes)
        }
        PadLog.log("平板 clip paste：页 \(page) 落 \(out.strokes.count) 笔 \(out.notes.count) 注解")
        s.inkMovedRev &+= 1   // 可能粘到了页边更远处，软边界要跟上（同 lassoApply）
        if s.id == padSession?.id { broadcastStrokes(); broadcastNotes() }
    }

    /// 某页的显示纵横比（页高/页宽，CropBox 优先 + rotation，与页内笔迹同一个口径）。
    /// 阅读区那份在视图里（`ReaderSurface.pageAspect`），这里是模型侧的同款——平板路径够不着视图。
    private func pageAspect(of s: DocSession, page: Int) -> Double {
        guard let p = s.pdf?.page(at: page) else { return 1.4142 }
        let size = PageBitmap.displaySize(p)
        return size.width > 0 ? Double(size.height / size.width) : 1.4142
    }

    // MARK: - 平板自由文字笔记（kind=0 点注解）

    /// 平板放置/编辑/删除一条自由文字笔记：upsert 按 id 更新或新建（零尺寸 anchor=落点、无 quote/rects
    /// 的点注解）；delete 或空文本 upsert 按 id 删除（对齐 Mac 端丢弃空点注解的语义）。
    /// 落进 `padSession.textNotes` 后由 ContentView 的对账机制自动落库 + 回传 notes 镜像，无需显式调用。
    private func applyTextNote(_ obj: [String: Any], to s: DocSession) {
        guard let idStr = obj["id"] as? String, let uuid = UUID(uuidString: idStr) else { return }
        let text = obj["text"] as? String ?? ""
        let isDelete = (obj["op"] as? String) == "delete" || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if isDelete {
            s.inkEdit("Delete", kind: .delete) { s.textNotes.removeAll { $0.id == uuid } }
            return
        }
        let maxPage = max(0, (s.pdf?.pageCount ?? 1) - 1)
        let page = min(max(0, (obj["page"] as? NSNumber)?.intValue ?? 0), maxPage)
        let nx = (obj["nx"] as? NSNumber)?.doubleValue ?? 0
        let ny = (obj["ny"] as? NSNumber)?.doubleValue ?? 0
        // 展开方式随正文一起改（平板编辑器里也能选）：线上没带这个字节的老客户端解码出 0 = tap。
        let display = NoteDisplay.fromWire(UInt8(clamping: (obj["display"] as? NSNumber)?.intValue ?? 0))
        s.inkEdit("Note", kind: .note) {
            if let i = s.textNotes.firstIndex(where: { $0.id == uuid }) {
                s.textNotes[i].text = text
                s.textNotes[i].display = display
                s.textNotes[i].updatedAt = .now
            } else {
                s.textNotes.append(TextNote(id: uuid, page: page,
                                            anchor: CGRect(x: nx, y: ny, width: 0, height: 0),
                                            quote: "", text: text, rects: [], display: display))
            }
        }
    }

    // MARK: - 环形选笔盘 · 长按检测（Mac 端）

    /// 落笔即起 1s 定时：期间没大幅移动就呼出环形盘。同时挂进度环（笔尖处）。
    private func beginLongPressWatch(page: Int, first: InkPoint?) {
        cancelRadial()
        guard let f = first else { return }
        inkStart = (page, f.dx, f.dy); inkMovedFar = false; inRadial = false
        holdSamples = [(SIMD2(f.dx, f.dy * currentPageAspect(page: page)), Date())]
        setPressRing(PressRing(page: page, nx: f.dx, ny: f.dy, start: Date()))
        let work = DispatchWorkItem { [weak self] in self?.fireLongPress() }
        longPressWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + longPressSeconds, execute: work)
    }

    /// 画的时候取消长按候选 + 撤掉进度环。**两道闸，任一条中即撤**：
    /// ① 离落笔点的总位移超 [moveCancelPx]（跑远了）；
    /// ② [holdSpeedWindow] 窗口内的平均速度超 [holdSpeedPx]（一直在动 = 在写字，见那里的注释）。
    private func checkLongPressMovement(_ last: InkPoint?) {
        guard !inkMovedFar, let s0 = inkStart, let p = last else { return }
        let aspect = currentPageAspect(page: s0.page)
        let dx = p.dx - s0.nx, dy = (p.dy - s0.ny) * aspect
        var moving = exceedsPad((dx * dx + dy * dy).squareRoot(), px: moveCancelPx, norm: moveCancelNorm)

        // 速度闸：只保留窗口内的采样（外加**窗口外最近的那一个**当参照点，否则刚落笔时无从比起）
        let now = Date()
        let cur = SIMD2(p.dx, p.dy * aspect)
        holdSamples.append((cur, now))
        while holdSamples.count > 1, now.timeIntervalSince(holdSamples[1].t) > holdSpeedWindow {
            holdSamples.removeFirst()
        }
        if !moving, let ref = holdSamples.first {
            let dt = now.timeIntervalSince(ref.t)
            // dt 太小时分母噪声会放大成假速度（WiFi 成批投递，一批点的时间戳几乎相同）
            if dt >= 0.04 {
                let d = (cur - ref.p)
                moving = exceedsPad((d.x * d.x + d.y * d.y).squareRoot() / dt,
                                    px: holdSpeedPx, norm: holdSpeedNorm)
            }
        }

        if moving {
            inkMovedFar = true
            longPressWork?.cancel(); longPressWork = nil
            setPressRing(nil)
        }
    }

    /// 设长按进度环并镜像给平板（值没变就不发，免得每次落笔来回空广播）。
    /// 平板收到 `on=1` 用本机时钟起计，两端的起显示/填满时长是各自硬编码的同一组常量。
    ///
    /// 去重记在 [sentPressRing]（设备级）而不是会话上——理由见那里的注释。
    private func setPressRing(_ r: PressRing?) {
        adoptOverlaySession()
        padSession?.pressRing = r
        guard server.hasClients, sentPressRing != r else { return }
        sentPressRing = r
        if let r {
            server.broadcast(["type": "pressRing", "on": true, "page": r.page, "nx": r.nx, "ny": r.ny])
        } else {
            server.broadcast(["type": "pressRing", "on": false])
        }
    }

    /// 环/盘换了会话就把旧会话上那份瞬态覆盖层收掉（它俩只该出现在平板当前跟随的那个标签上）。
    private func adoptOverlaySession() {
        let cur = padSession
        if let old = overlaySession, old !== cur { old.pressRing = nil; old.radial = nil }
        overlaySession = cur
    }

    /// 页内归一化距离（已做长宽比校正）是否超过给定的**平板屏幕**阈值。
    /// 平板报了页宽就按平板 px 判（所见即所得，与平板上画出的盘同尺度）；没报则退回归一化阈值。
    private func exceedsPad(_ normDist: Double, px: Double, norm: Double) -> Bool {
        padPageWidth > 0 ? normDist * padPageWidth > px : normDist > norm
    }

    /// 长按达成：丢弃正在成形的这一笔，呼出环形盘（中心在落笔处），并回发 inkCancel 让平板撤掉本地这半笔。
    private func fireLongPress() {
        guard !inkMovedFar, !inRadial, let s0 = inkStart, let s = padSession else { return }
        s.liveStroke = nil
        setPressRing(nil)   // 环展开成盘，两者互斥
        inRadial = true
        s.radial = RadialState(page: s0.page, cx: s0.nx, cy: s0.ny, highlight: -1)
        // 打点：用户报「Mac 上盘出来了、安卓上没出来」。盘的下发走 WS，与 `strokes` 全量镜像同一条
        // 有序通道 —— 镜像大起来就会把这一帧压在后面（队头阻塞）。要判断是不是这个，就得两边都有
        // 时刻：这里记发出时刻，安卓 `UniReader/Canvas` 记收到时刻，一减就是这一帧在路上花的时间。
        NSLog("环形盘呼出 page=%d cx=%.3f cy=%.3f（下发中）", s0.page, s0.nx, s0.ny)
        server.broadcast(["type": "inkCancel"])
        broadcastRadial()
    }

    /// 环形盘打开时，笔移 → **只看角度**定扇区（`RadialLayout`：整圆均分，0 号正上方起顺时针）；
    /// 半径只用来判「有没有离开中心取消区」。角度天生与缩放无关（长宽比校正后即真实方向），
    /// 取消区半径按平板屏幕像素判 —— 两者合起来让选择手感不再随任一端缩放漂移。
    private func updateRadial(_ last: InkPoint?) {
        guard var r = padSession?.radial, let p = last else { return }
        let items = RadialLayout.items(penCount: pens.count)
        guard !items.isEmpty else { return }
        let dx = p.dx - r.cx
        let dy = (p.dy - r.cy) * currentPageAspect(page: r.page)   // 归一化 y → 与 x 同尺度，方向才是真实方向
        let dist = (dx * dx + dy * dy).squareRoot()
        if !exceedsPad(dist, px: Double(RadialLayout.hubRadius), norm: radialDeadzoneNorm) {
            r.highlight = -1
        } else {
            var ang = atan2(dx, -dy)   // 正上方为 0、顺时针（页坐标 y 向下，故取 -dy）
            if ang < 0 { ang += 2 * .pi }
            let n = items.count
            r.highlight = Int((ang / (2 * .pi) * Double(n)).rounded()) % n
        }
        if r != padSession?.radial { padSession?.radial = r; broadcastRadial() }
    }

    /// 抬笔：环形盘打开则提交选中扇区（中心取消区 = 不选），否则正常收笔。
    private func endInkOrRadial() {
        longPressWork?.cancel(); longPressWork = nil
        setPressRing(nil)
        if inRadial {
            let items = RadialLayout.items(penCount: pens.count)
            if let r = padSession?.radial, items.indices.contains(r.highlight) {
                switch items[r.highlight] {
                case .pen(let i): applyPenSelection(index: i)   // 选笔 → 顺带回笔记模式
                case .erase: setPadMode("erase")
                case .page: setPadMode("page")
                case .scratchAdd:
                    // 盘心即锚点：与右键菜单「在此新建草稿纸」同一条路径（建纸+打开，回推 scratchpads）
                    if let s = padSession { addScratchPad(in: s, page: r.page, nx: r.cx, ny: r.cy) }
                case .textNote:
                    // 让平板在该处点开文字笔记编辑器（平板编辑完走 textNote 上行闭环，Mac 不落任何数据）
                    server.broadcast(["type": "noteNew", "page": r.page, "nx": r.cx, "ny": r.cy])
                }
            }
            padSession?.radial = nil
            broadcastRadial()
        } else {
            inkEnd()
        }
        // 抬笔 = 撤销栈上这一组擦除封口（下一批擦除另起一步；擦除模式下走的是并行的 probe 流，
        // 它的 end 也落到这里）。落墨本来就一笔一步，封不封口都一样。
        padSession?.inkUndo.seal()
        padSession?.scratchUndo.seal()
        inRadial = false; inkStart = nil
    }

    private func cancelRadial() {
        longPressWork?.cancel(); longPressWork = nil
        if inRadial { padSession?.radial = nil; broadcastRadial() }
        setPressRing(nil)
        inRadial = false; inkStart = nil; inkMovedFar = false
        holdSamples.removeAll(keepingCapacity: true)
    }

    /// 把环形盘状态镜像给平板（平板照着画，不做任何判定）。盘一收就发 `open:false`。
    /// 只在 `radial` 真的变了时调用——`updateRadial` 已用 Equatable 去重，跨扇区才发一帧。
    private func broadcastRadial() {
        guard server.hasClients else { return }
        guard let r = padSession?.radial else {
            server.broadcast(["type": "radial", "open": false])
            return
        }
        // 工具扇区不吃 pen 字段，但线格式定长，填占位色即可（见 PROTOCOL.md §4.2 radial）。
        func entry(_ kind: String, _ pen: PenPreset?) -> [String: Any] {
            ["kind": kind,
             "color": pen?.color.cssRGBA ?? "rgba(0,0,0,1)",
             "w": pen?.width ?? 0,
             "t": (pen?.type ?? .ballpoint).rawValue]
        }
        let items: [[String: Any]] = RadialLayout.items(penCount: pens.count).map { item in
            switch item {
            case .pen(let i): return entry("pen", pens.indices.contains(i) ? pens[i] : nil)
            case .erase: return entry("erase", nil)
            case .page: return entry("page", nil)
            case .scratchAdd: return entry("scratchAdd", nil)
            case .textNote: return entry("textNote", nil)
            }
        }
        server.broadcast(["type": "radial", "open": true, "page": r.page, "cx": r.cx, "cy": r.cy,
                          "highlight": r.highlight, "items": items])
    }

    private func currentPageAspect(page: Int) -> Double {
        guard let pdf = padSession?.pdf, page >= 0, page < pdf.pageCount, let pg = pdf.page(at: page) else { return 1 }
        let b = pg.bounds(for: PageBitmap.effectiveBox(pg))
        return b.width > 0 ? Double(b.height / b.width) : 1
    }

    /// 应用一次选笔（画布悬浮工具条点插槽 / 平板 PageDown 上报，殊途同归）。选笔即回到笔记模式
    /// （跟 pad 自己 PageDown 切笔时顺带把 modeIdx 归零是同一个道理——选了支笔就是要用它画）。
    /// `pens`/`padPenIndex` 是设备级全局状态，不挂在某个文档会话上，故不需要传 `DocSession`。
    func applyPenSelection(index: Int) {
        padPenIndex = index
        server.broadcast(["type": "pen", "index": index])
        setPadMode("note")
    }

    /// 切换当前工具模式（笔记/擦除/翻页）并广播给 pad。画布悬浮工具条的橡皮/翻页按钮走这个。
    func setPadMode(_ mode: String) {
        guard padMode != mode else { return }
        padMode = mode
        server.broadcast(["type": "mode", "mode": mode])
    }

    /// 收藏笔列表变化（新增/删除/改颜色/改粗细/改类型）→ 整体推给 pad（同 layout/docs 的「变了就广播」套路）。
    func broadcastPens() {
        guard server.hasClients else { return }
        server.broadcast([
            "type": "pens",
            "list": pens.map { ["color": $0.color.cssRGBA, "w": $0.width, "t": $0.type.rawValue] },
            "active": padPenIndex
        ])
    }

    /// 平板调笔宽后上行全量笔列表（`penset`，payload 布局同 `pens`）：线上不带 id/name，
    /// **按下标对齐**写回 color/width/type；数目不符 = 两端列表版本错位，整包丢弃。
    /// 整体一次赋值，只触发一次 `pens` didSet（落盘 + broadcastPens 回声全端对齐）。
    private func applyPenSet(_ obj: [String: Any]) {
        guard let list = obj["list"] as? [[String: Any]], list.count == pens.count else { return }
        var np = pens
        for (i, p) in list.enumerated() {
            np[i].color = InkColor.parse(p["color"] as? String)
            if let w = (p["w"] as? NSNumber)?.doubleValue, w > 0 { np[i].width = w }
            if let t = PenBrushType(rawValue: p["t"] as? String ?? "") { np[i].type = t }
        }
        pens = np
        if let a = (obj["active"] as? NSNumber)?.intValue, pens.indices.contains(a) { padPenIndex = a }
    }

    /// 橡皮设置变更 → 推给 pad（服务启动/新客户端接入时也补发一次，双向同步的 Mac→pad 方向）。
    /// 平板上行应用期间（`applyingRemoteEraser`）抑制回播（值来自 pad，回声无意义还会三连发）。
    func broadcastEraser() {
        guard !applyingRemoteEraser, server.hasClients else { return }
        server.broadcast(["type": "eraser", "size": eraserRadius,
                          "mode": eraserMode == .partial ? 1 : 0,
                          "ring": eraserRing ? 1 : 0])
    }

    /// 新增一支收藏笔（默认样式），立即选中。返回新笔下标，供调用方直接弹出编辑面板。
    @discardableResult
    func addPen() -> Int {
        pens.append(PenPreset(name: L("Pen"), color: InkColor(r: 90, g: 90, b: 90, a: 0.95), width: 8))
        let idx = pens.count - 1
        applyPenSelection(index: idx)
        return idx
    }

    /// 删除一支收藏笔（至少保留 1 支，调用方需先自行判断 `pens.count > 1`）。
    /// 删掉的是当前选中的那支时回退到第 0 支；删掉的在选中项之前则下标平移，避免选中项错位。
    /// **顺序注意**：`pens` 的 `didSet` 会立即广播一次（带着还没修正的旧 `padPenIndex`），
    /// 修正完下标后必须再广播一次纠正——不然 pad 短暂收到一个跟 Mac 实际不一致的 active 下标。
    func removePen(id: UUID) {
        guard pens.count > 1, let idx = pens.firstIndex(where: { $0.id == id }) else { return }
        pens.remove(at: idx)   // didSet 立即广播一次（此时 padPenIndex 还没修正）
        if padPenIndex == idx { padPenIndex = 0 }
        else if padPenIndex > idx { padPenIndex -= 1 }
        broadcastPens()   // 用修正后的 padPenIndex 再广播一次，纠正上面那次的 active 下标
    }

    // 供 WS、模拟窗口与本机落墨共用的落墨 API。`in session` 缺省 = 平板当前会话（handleInk 既有调用点
    // 不传，行为不变）；本机落墨传当前窗口自己的 session——写进 session.strokes 后 ContentView 对账
    // 自动落库，若恰是 padSession 则广播自动镜像到平板，零额外工作。
    func inkBegin(in session: DocSession? = nil, page: Int, color: InkColor, width: Double, type: PenBrushType = .ballpoint, points: [InkPoint]) {
        guard let s = session ?? padSession else { return }
        s.liveStroke = InkStroke(page: page, color: color, width: width, type: type, points: points,
                                 layerId: s.activeLayerID ?? InkLayer.defaultID)
    }
    func inkAppend(_ pts: [InkPoint], in session: DocSession? = nil) {
        guard let s = session ?? padSession, var st = s.liveStroke else { return }
        st.points.append(contentsOf: pts); s.liveStroke = st
        // 书写中笔尖圆环跟随（落笔后 hover 消息停发，不更新会残留死圆圈在落笔点）
        if let last = pts.last { s.hover = HoverPoint(page: st.page, nx: last.dx, ny: last.dy) }
    }
    /// 直线（尺子）笔的落点：整笔恒为「起点 → 当前终点」两点，新点**替换**终点而不是追加
    /// （平板已按 45° 吸附算好终点；一批里只有最后一个点是当前终点，中间的是过程点，丢弃）。
    /// 与 `localInkDragGesture` 的 ⇧ 尺子分支同语义。
    ///
    /// 压感取**这一笔的峰值**、两端同值（`linePressure`）：两点直线的线宽只由终点压感决定，
    /// 而终点每帧被整个替换掉——抬笔前最后一个采样的压感几乎为 0，整条线于是在抬笔那一刻
    /// 缩成头发丝（用户报）。平板侧同规则先算一遍（本地即时回显要对得上），这里再取一次
    /// max 是幂等的，顺带兜住不带这条规则的旧采集页。
    func inkLineTo(_ p: InkPoint?, in session: DocSession? = nil) {
        guard let p, let s = session ?? padSession, var st = s.liveStroke,
              let a = st.points.first else { return }
        let z = AppModel.linePressure(st.points, p)
        st.points = [InkPoint(a.x, a.y, z), InkPoint(p.x, p.y, z)]; s.liveStroke = st
        s.hover = HoverPoint(page: st.page, nx: p.dx, ny: p.dy)
    }
    /// 尺子笔的恒定压感 = 起点、上一个终点、这个新终点里的最大值（见 `inkLineTo`）。
    /// 页内与草稿纸两条链路共用一份，别各写各的。
    static func linePressure(_ points: [InkPoint], _ p: InkPoint) -> Float {
        var z = p.z
        for q in points.prefix(2) { z = max(z, q.z) }
        return z
    }
    func inkEnd(in session: DocSession? = nil) {
        guard let s = session ?? padSession, let st = s.liveStroke else { return }
        let t0 = CFAbsoluteTimeGetCurrent()
        s.strokes.append(st); s.liveStroke = nil
        // 撤销记账。**刻意不走 `s.inkEdit {}`**：那个要把前后两份数组整表 diff 一遍，而收笔是
        // 最热的那条路径（每一笔都跑，见下面那几行的收笔计时）；纯追加自己就知道差在哪，直接记。
        s.inkUndo.recordAdded(label: "Draw", kind: .draw, strokes: [st])
        // 纯追加：只发这一条（非平板会话只落库，不做无谓广播）。**唯一用追加帧的地方**，理由见那里。
        broadcastStrokeAppended(st, in: s)
        // 收笔那一刻记时（诊断用，见 `DocSession.lastInkEndAt` / `ContentView.persistInk`）
        s.lastInkEndAt = CFAbsoluteTimeGetCurrent()
        PadLog.log("收笔 广播 \(PadLog.ms(s.lastInkEndAt - t0))（本笔 \(st.points.count) 点）")
    }
    func inkErase(_ pts: [InkPoint], page: Int, in session: DocSession? = nil) {
        guard let s = session ?? padSession else { return }
        s.inkEnsureLoaded?(page)          // 笔迹按页窗口装载：这一页不在内存里就先同步补读（否则擦的是空集）
        let before = s.strokes            // COW 快照，O(1)；只有真擦到了才拿它去比差异
        let changed = eraseNear(s, pts, page: page)
        // 撤销记账：一次拖动里每 8ms 就来一批，靠 `InkPatch` 的合并把整条拖动并成**一步**
        // （封口在抬笔处 `endInkOrRadial` / 本机手势的 onEnded）。
        if changed {
            s.inkUndo.record(label: "Erase", kind: .erase, strokesBefore: before, strokesAfter: s.strokes)
        }
        // 擦除中笔尖圆环同样跟随
        if let last = pts.last { s.hover = HoverPoint(page: page, nx: last.dx, ny: last.dy) }
        // 🔴 **没擦到东西就什么都不做**（2026-09-02）。橡皮压在纸上不动、或从空白处划过时，平板照样
        // 每 8ms 送一批擦除点上来；从前每一批都无条件 `s.strokes = out` + 广播一份**全量镜像**，于是
        // ① 每批都把整个窗口的视图树重算一遍（`@Published` 扇出）+ 走一遍 `persistInk` 全表对账；
        // ② WS 上常驻一个几百 KB 的大帧在飞，把后面那些几十字节的控制帧（`radial`/`pressRing`/
        //    `inkCancel`）全压住 —— 那正是「长按呼盘：环乱冒、盘唤不出」的信道成因（见 `LANServer`
        //    合帧那段注释与 `TODO.md` 已知 Bug）。擦除模式下长按呼盘时，橡皮恰恰是**停着不动**的，
        //    也就是每一批都擦不到东西 —— 这条路径于是从「必然堵」变成「一帧不发」。
        if changed, s.id == padSession?.id { broadcastStrokes() }
    }

    // MARK: - 撤销 / 重做（页内笔迹 + 文字注解 / 草稿纸笔迹）

    /// 撤销或重做一步**页内**编辑。落库仍由 `DocTabModel` 的值快照对账自动完成，这里只补两件
    /// 数组变更本身表达不了的事：给阅读区一个「有笔迹原地动过」的信号（页边软边界要跟上，
    /// 笔画数不变时那个 `onChange(of: strokes.count)` 不会响），以及恰是 padSession 时补发镜像
    /// （与框选提交同一条口径——擦除/改动改不出追加帧，只能发全量）。
    func undoInk(in s: DocSession, redo: Bool) {
        guard s.applyInkUndo(redo: redo) else { return }
        s.inkMovedRev &+= 1
        if s.id == padSession?.id { broadcastStrokes(); broadcastNotes() }
    }

    /// 撤销或重做一步**草稿纸**编辑（同上，镜像走草稿纸那条）。
    func undoScratch(in s: DocSession, redo: Bool) {
        guard s.applyScratchUndo(redo: redo) else { return }
        if s.id == padSession?.id { broadcastScratchStrokes() }
    }

    /// 把平板当前会话**内存里的笔迹**（= Mac 当前装载窗口，`InkWindow`；不保证全篇，PROTOCOL.md §4.2）
    /// 推给平板（平板据此显示 + 刷新/重连后恢复）。窗口随滚动长了/变了，`DocTabModel.applyInkBatch` 再整替一次。
    /// 平板本地不落库、只即时回显正在写的这一笔；已成形/已存的笔迹以 Mac 为唯一真源，靠这里回传。
    func broadcastStrokes() {
        guard server.hasClients, let s = padSession else { return }
        let t0 = CFAbsoluteTimeGetCurrent()
        let vis = s.visibleLayerIDs
        let list = strokeDicts(s.strokes.filter { vis.contains($0.layerId) })
        server.broadcast(["type": "strokes", "list": list])
        // 全量镜像的建帧成本（`PadLog`，默认关）：擦除时每收一批点就走一遍这里，
        // 每个点都要装箱成 `[NSNumber]`——这是「已知 Bug」里那条尾巴的现场读数。
        PadLog.log("全量镜像 \(list.count)条：建 \(PadLog.ms(CFAbsoluteTimeGetCurrent() - t0))")
    }

    /// 只把**新追加的这几条**推给平板（`strokesAppend`, `PROTOCOL.md §4.2`）。
    ///
    /// 为什么非有它不可：`broadcastStrokes` 是全量镜像，而每收一条笔迹就要广播一次，payload 是
    /// 全文档可见图层的所有点（`pt3` 12 字节 → 一页密字 ≈ 720KB）。于是「写第 N 笔」的开销正比于 N，
    /// 整篇下来是 **O(n²)**：`e2e` 随累计笔迹一路爬，大帧还会在 WS 上把后面几十字节的控制帧
    /// （`radial`/`pressRing`/`inkCancel`）一起压住。追加帧的体积与文档大小无关，这条路径于是变成常数。
    ///
    /// **只许在纯追加处调用**（当前就 `inkEnd` 一处）：擦除、框选、图层显隐、切档一律照旧发全量——
    /// 它们会删改已有笔迹，追加表达不了。不可见图层的笔迹照 `broadcastStrokes` 的口径过滤掉。
    func broadcastStrokeAppended(_ st: InkStroke, in s: DocSession) {
        guard server.hasClients, s.id == padSession?.id, s.visibleLayerIDs.contains(st.layerId) else { return }
        server.broadcast(["type": "strokesAppend", "list": strokeDicts([st])])
    }

    private func strokeDicts(_ strokes: [InkStroke]) -> [[String: Any]] {
        strokes.map { st in
            ["page": st.page,
             "pen": ["color": st.color.cssRGBA, "w": st.width, "t": st.type.rawValue],
             "pts": st.points.map { [$0.x, $0.y, $0.z] }]
        }
    }

    /// 把平板当前会话的图层表（名字/颜色/可见性）+ 当前作画图层推给平板（同 `broadcastPens` 套路）。
    func broadcastLayers() {
        guard server.hasClients, let s = padSession else { return }
        let active = s.inkLayers.firstIndex(where: { $0.id == s.activeLayerID }) ?? 0
        let list: [[String: Any]] = s.inkLayers.map { l in
            let rgb = NoteType.paletteRGB(l.colorKey)
            return ["r": rgb.r, "g": rgb.g, "b": rgb.b, "visible": l.visible, "name": l.name]
        }
        server.broadcast(["type": "layers", "active": active, "list": list])
    }

    /// 把平板当前会话的**全部文字笔记**推给平板（平板画圆形标记；Mac 为唯一真源，类比 strokes 镜像）。
    /// 对选区锚定的注解用 anchor 原点作标记位置。
    func broadcastNotes() {
        guard server.hasClients, let s = padSession else { return }
        let list: [[String: Any]] = s.textNotes.map { n in
            ["id": n.id.uuidString, "page": n.page,
             "nx": n.anchor.minX, "ny": n.anchor.minY, "text": n.text,
             "display": Int(n.display.wire)]
        }
        server.broadcast(["type": "notes", "list": list])
    }

    private func points(_ any: Any?) -> [InkPoint] {
        guard let raw = any as? [[NSNumber]] else { return [] }
        return raw.map { p in
            InkPoint(p.count > 0 ? p[0].floatValue : 0,
                     p.count > 1 ? p[1].floatValue : 0,
                     p.count > 2 ? p[2].floatValue : 0.5)
        }
    }

    /// 擦除分派（半径都是 `eraserRadius`，页内归一化）：
    /// - 整笔（`.stroke`）：任一点命中即删整条（旧 eraseNear 的 removeAll 语义）；
    /// - 局部（`.partial`）：逐笔用 `InkEdit.splitStroke` 切段替换——剔除命中点，连续未命中段各成新笔画
    ///   （空 = 整笔消除）；新 id 被 persistInk 对账识别为「旧删新增」，持久化零改动。
    /// 返回**这一批到底擦掉了东西没有**。没擦到就一个字节都不写回 `s.strokes`——那次赋值本身
    /// （`@Published`）就是一次全窗视图树重算 + 一次全表对账，调用方还会据此决定发不发全量镜像。
    @discardableResult
    private func eraseNear(_ s: DocSession, _ es: [InkPoint], page: Int) -> Bool {
        guard !es.isEmpty else { return false }
        let r2 = Float(eraserRadius * eraserRadius)
        let vis = s.visibleLayerIDs   // 橡皮只影响可见图层：隐藏的图层不该被误擦
        if eraserMode == .stroke {
            let before = s.strokes.count
            var kept: [InkStroke] = []
            kept.reserveCapacity(before)
            for st in s.strokes {
                var hit = false
                if st.page == page, vis.contains(st.layerId) {
                    outer: for sp in st.points {
                        for e in es {
                            let dx = sp.x - e.x, dy = sp.y - e.y
                            if dx * dx + dy * dy <= r2 { hit = true; break outer }
                        }
                    }
                }
                if !hit { kept.append(st) }
            }
            guard kept.count != before else { return false }
            s.strokes = kept
            return true
        }
        // 擦除点无压感，z 槽位按 `InkEdit.splitStroke` 约定改装页号（跨页不串）。
        let eps = es.map { InkPoint($0.x, $0.y, Float(page)) }
        var out: [InkStroke] = []
        out.reserveCapacity(s.strokes.count)
        var changed = false
        for st in s.strokes {
            if st.page == page, vis.contains(st.layerId) {
                let parts = InkEdit.splitStroke(st, erasePts: eps, r: eraserRadius)
                // 「原样一条、点数不变」＝这一笔没被碰到。切了段（parts 变多/变空）或剔了点
                // （点数变少）才算改过 —— 逐点比值没必要，splitStroke 只会删点不会改点。
                if parts.count != 1 || parts[0].points.count != st.points.count { changed = true }
                out.append(contentsOf: parts)
            } else {
                out.append(st)
            }
        }
        guard changed else { return false }
        s.strokes = out
        return true
    }

    /// 当前应显示到平板的会话。
    var padSession: DocSession? {
        let id = padSelectedSessionID ?? activeSessionID
        return sessions.first { $0.id == id }
    }

    // MARK: - 会话注册

    func register(_ s: DocSession) {
        if !sessions.contains(where: { $0.id == s.id }) { sessions.append(s) }
        if activeSessionID == nil { activeSessionID = s.id }
        broadcastDocs()
        broadcastLibrary()   // 新窗口 → 书库的 open 标记会变（文档要等 loadSelected 才就位）
    }

    func unregister(_ s: DocSession) {
        sessions.removeAll { $0.id == s.id }
        if padSelectedSessionID == s.id { padSelectedSessionID = nil }
        let followedClosed = activeSessionID == s.id
        if followedClosed { activeSessionID = sessions.last?.id }
        push()
        // 平板正跟着被关掉的窗口 → push() 已把 layout 切到接班会话（清空平板本地滚动位置），
        // 必须补一次 viewport 才能落到接班会话的当前进度，否则平板会卡在该文档顶部，
        // 一旦用户在平板上滑动还会把这个假位置写回数据库覆盖真实进度（同 setActive 的时序坑）。
        if followedClosed { pushCurrentViewport() }
        broadcastDocs()
        broadcastLibrary(); broadcastTOC(); broadcastBookmarks()   // 接班会话可能属于另一个工作区、装着另一本书
        broadcastScratchPads(); broadcastScratchStrokes()   // 草稿纸挂文档，换会话即换一整套
        releasePadRenderIfUnused()           // 被关掉的那本若已无人在看 → 放掉平板那份 PDF 副本
    }

    /// 窗口成为 key window。
    func setActive(_ s: DocSession) {
        let followedSwitched = padSelectedSessionID == nil && activeSessionID != s.id
        if activeSessionID != s.id { activeSessionID = s.id }
        if padSelectedSessionID == nil { push() }   // 平板在跟随模式 → 切到新激活窗口
        // 切工作区/切窗口焦点会让平板跟随的文档换掉（push()→pushLayout() 广播新 docId，
        // 两端收到都会把本地滚动位置清零），不补推 viewport 平板就停在第 1 页——同 selectPadDoc。
        if followedSwitched { pushCurrentViewport() }
        broadcastDocs()
        if followedSwitched {
            broadcastLibrary(); broadcastTOC(); broadcastBookmarks()                   // 跟随模式换窗口 = 可能换工作区/换书
            broadcastScratchPads(); broadcastScratchStrokes()    // …连草稿纸也是另一篇文档的那套
        }
    }

    /// 某会话页码变化（Mac 滚动或加载新文档）。
    func sessionChanged(_ s: DocSession) {
        if s.id == padSession?.id { push() }
        broadcastDocs()   // 标题可能刚更新
    }

    /// 平板选择要看的文档（空串 = 跟随激活窗口）。
    func selectPadDoc(_ idString: String) {
        padSelectedSessionID = idString.isEmpty ? nil : UUID(uuidString: idString)
        push()
        broadcastDocs()
        broadcastLibrary(); broadcastTOC(); broadcastBookmarks()   // 换会话 = 可能换工作区、必然可能换书
        pushCurrentViewport()   // 平板切文档后落到该文档在 Mac 端的当前进度
    }

    /// 平板请求打开工作区里的某个文档（库文档 id）。
    ///
    /// 已在**同一工作区**的某个窗口里开着 → 等价于平板选中那个窗口（不重复开窗）；否则请求「平板当前
    /// 跟随的那个窗口」去 `openWindow` 一个新窗口装它（用户 2026-08-05 定：新开窗口，不顶掉当前文档）。
    /// 新窗口的会话 id 此刻还不存在，故先把 docId 记进 `pendingPadFollowDocId`，等它 `loadSelected`
    /// 完成时（`sessionDocumentChanged`）再把平板锁过去。
    func openPadDoc(_ docId: String) {
        guard !docId.isEmpty, let cur = padSession else { return }
        let folder = cur.workspaceFolder
        if let hit = sessions.first(where: { $0.documentId == docId && $0.workspaceFolder == folder }) {
            selectPadDoc(hit.id.uuidString)
            return
        }
        guard let path = folder?.standardizedFileURL.path else { return }
        pendingPadFollowDocId = docId
        padOpenDocRequest = PadOpenDocRequest(sessionID: cur.id, workspacePath: path, docId: docId)
    }

    /// 某会话换了文档（`ContentView.loadSelected` 之后）：标题/书库 open 标记/目录全会变。
    /// 平板发起的 `openDoc` 也在这里收尾——新窗口装的正是它要的文档，就把平板锁过去。
    func sessionDocumentChanged(_ s: DocSession) {
        if let want = pendingPadFollowDocId, s.documentId == want {
            pendingPadFollowDocId = nil
            selectPadDoc(s.id.uuidString)   // 内含 push/broadcastDocs/pushCurrentViewport
        }
        broadcastDocs()
        broadcastLibrary()
        broadcastTOC()
        broadcastBookmarks()   // 换文档 = 换一套书签
    }

    /// 广播「平板跟随的那个窗口所属工作区」的书库给平板（平板据此打开尚未打开的文档）。
    /// 内容未变则不发（`force` 用于新客户端接入补发）——书库列表比 `docs` 大得多，且触发点很密
    /// （每次换文档/开关窗口 open 标记都可能变）。
    func broadcastLibrary(force: Bool = false) {
        guard server.hasClients, let s = padSession, s.workspaceFolder != nil else { return }
        // 参考窗的取图索引跟着书库一起更新。**放在这里而不是 `push()`**：那边要求当前标签已经
        // 打开了 PDF（空标签时不跑），而参考窗恰恰可以在空标签上看别的书。
        setRefIndex(s.libraryRefIndex)
        let folder = s.workspaceFolder
        let openIds = Set(sessions.compactMap { $0.workspaceFolder == folder ? $0.documentId : nil })
        let list: [[String: Any]] = s.libraryDocs.map {
            ["id": $0.id, "title": $0.title.isEmpty ? L("Untitled") : $0.title, "open": openIds.contains($0.id)]
        }
        let key = s.workspaceName + "|" + list.map { "\($0["id"] ?? "")\($0["title"] ?? "")\($0["open"] ?? "")" }.joined(separator: ",")
        if !force && key == pushedLibraryKey { return }
        pushedLibraryKey = key
        server.broadcast(["type": "library", "ws": s.workspaceName, "list": list])
    }

    /// 广播平板当前会话的 PDF 目录（先序拍平 + depth）。坏书签 `page = -1`（见 PROTOCOL.md §4.2）。
    func broadcastTOC(force: Bool = false) {
        guard server.hasClients, let s = padSession else { return }
        var list: [[String: Any]] = []
        func walk(_ es: [TOCEntry], _ depth: Int) {
            for e in es {
                list.append(["depth": depth, "page": e.pageIndex ?? -1, "frac": e.frac, "label": e.label])
                walk(e.children, depth + 1)
            }
        }
        walk(s.toc, 0)
        let key = s.contentHash + "#\(list.count)"
        if !force && key == pushedTOCKey { return }
        pushedTOCKey = key
        server.broadcast(["type": "toc", "docId": s.contentHash, "list": list])
    }

    /// 把当前文档的书签全量镜像推给平板（`PROTOCOL.md` 的 `bookmarks`，规格 `REQUIREMENTS.md §1.9`）。
    ///
    /// 与 `broadcastTOC` 同一套惯例：`docId` = 内容哈希（客户端必须核对，否则切档瞬间会把上一本的
    /// 书签挂到新书上），列表**已按 `Bookmark.before` 有序**（客户端直接用，不要再排）。
    /// 不做「内容没变就不发」的去重——书签表本来就小，而增删改后必须立刻回推（客户端不做乐观更新）。
    func broadcastBookmarks() {
        guard server.hasClients, let s = padSession else { return }
        let list: [[String: Any]] = s.bookmarks.map {
            ["id": $0.id.uuidString, "page": $0.page, "frac": $0.frac, "title": $0.title]
        }
        server.broadcast(["type": "bookmarks", "docId": s.contentHash, "list": list])
    }

    /// 平板/网页请求加/改名/删一枚书签（`bookmarkEdit` 上行）。**Mac 是唯一真源**：这里落进
    /// `session.bookmarks`（`DocTabModel` 的增量对账负责落库），再以 `bookmarks` 全量回推。
    private func applyBookmarkEdit(_ obj: [String: Any], to s: DocSession) {
        let op = (obj["op"] as? NSNumber)?.intValue ?? 0
        let idStr = obj["id"] as? String ?? ""
        guard let uuid = UUID(uuidString: idStr) else { return }
        let title = (obj["title"] as? String ?? "")
        switch op {
        case 0:   // add：id 由客户端生成；名字必填这条判据在 Mac 侧也守一遍（不能只靠 UI 禁用）
            guard Bookmark.validTitle(title) else { return }
            let maxPage = max(0, (s.pdf?.pageCount ?? 1) - 1)
            let page = min(max(0, (obj["page"] as? NSNumber)?.intValue ?? 0), maxPage)
            let frac = min(max(0, (obj["frac"] as? NSNumber)?.doubleValue ?? 0), 1)
            guard !s.bookmarks.contains(where: { $0.id == uuid }) else { return }   // 重发的同一帧
            s.bookmarks.append(Bookmark(id: uuid, page: page, frac: frac,
                                        title: title.trimmingCharacters(in: .whitespacesAndNewlines)))
            s.bookmarks.sort(by: Bookmark.before)
        case 1:   // rename：找不到 id 就静默丢（客户端可能拿着过期镜像）
            s.renameBookmark(id: uuid, to: title)
        default:  // delete
            s.deleteBookmark(id: uuid)
        }
        broadcastBookmarks()
    }

    /// 广播打开中的文档列表给平板。
    ///
    /// ⚠️ 这份列表是**跨工作区**的（`sessions` = 全部窗口，而工作区是窗口级的，`REQUIREMENTS.md §8.1`），
    /// 所以每项必须带上 `ws` = 那个窗口的工作区名——客户端拿它分组，否则标签页栏会把几个工作区的
    /// 文档混成一排、点过去工作区凭空换掉（`PROTOCOL.md §4.2` 的 `docs`）。
    func broadcastDocs() {
        guard server.hasClients else { return }
        let list: [[String: Any]] = sessions.map {
            ["id": $0.id.uuidString, "title": $0.title.isEmpty ? "未命名" : $0.title, "ws": $0.workspaceName]
        }
        server.broadcast([
            "type": "docs",
            "list": list,
            "selected": padSession?.id.uuidString ?? "",
            "following": padSelectedSessionID == nil
        ])
    }

    // MARK: - 推当前页元信息给平板

    /// 推平板当前会话的页元信息（页号/总页数/页尺寸）。**只发标量，不在这里渲染页图**。
    /// ⚠️ 性能红线（2026-07-27 实测定位）：本方法由 `sessionChanged` 驱动，即**每翻过一页边界就跑一次，
    /// 且在主线程**。旧实现在这里同步跑 `PageRenderer.png(maxWidth: 1600)` = PDFKit 渲染整页 →
    /// NSImage → TIFF（~13MB 未压缩）→ 重解码 → PNG deflate，大扫描件单次上百毫秒，还要和
    /// `PageRenderEngine` 的后台队列抢 PDFDocument 锁 → 连续翻页每跨一页卡顿一下（关掉平板服务即消失）。
    /// 而那张图只存进 `LANServer.pagePNG` 给「无 `?i=` 的旧采集页」兜底，现役两端（web `render.ts`、
    /// 安卓 `PageFetcher.kt`）一律走 `/page.png?i=N` → `pageProvider` → `renderPage`（服务 queue + NSCache）。
    /// 即：纯浪费。故整段删除，兜底路由改为同样走 `pageProvider`（见 `LANServer.route`）。
    func push() {
        guard server.hasClients, let s = padSession, let pdf = s.pdf,
              let page = pdf.page(at: s.currentPageIndex) else { return }
        setPadRender(pdf: pdf, key: s.contentHash)   // 方案 B：更新按页渲染源
        let b = page.bounds(for: PageBitmap.effectiveBox(page))
        server.setPage(index: s.currentPageIndex,
                       count: pdf.pageCount,
                       width: Double(b.width),
                       height: Double(b.height))
        pushLayout()
        pushStrokesIfDocChanged(s)
    }

    /// 平板端最近一次已同步笔迹的文档键（documentId 优先，退 contentHash）。
    private var pushedStrokesKey = ""
    /// 平板看到的文档变了（pad 下拉切档 / Mac 切激活窗口 / 重载文档）→ 立即补发该文档全部笔迹与文字笔记。
    /// 平板收到新 docId 的 layout 会清空本地笔迹，不补发就得等下一次书写/擦除才恢复。
    /// 必须在 pushLayout 之后调用：平板上 layout 清空在前、strokes 恢复在后。
    private func pushStrokesIfDocChanged(_ s: DocSession) {
        let key = s.documentId ?? s.contentHash
        guard !key.isEmpty, key != pushedStrokesKey else { return }
        pushedStrokesKey = key
        broadcastStrokes()
        broadcastNotes()
        broadcastLayers()
        broadcastCanvas()   // 画板模式逐文档记，换文档必须跟着换（否则平板还按上一本的页边布局画）
    }

    /// 把画板模式（开关 + 每侧页边宽度）推给平板。**Mac 是唯一真源**（同 radial/pressRing 的惯例）：
    /// 页边宽度由阅读区按笔迹越界量档位化（`CanvasMargin`），跳档时经 `session.canvasMarginLive` 落到
    /// 这里再广播。页边笔迹本身仍走既有的 `strokes`/`ink`（只是 x 越出 0…1），故不需要别的协议改动。
    func broadcastCanvas() {
        guard server.hasClients, let s = padSession else { return }
        server.broadcast(["type": "canvas", "on": s.canvasMode,
                          "margin": s.canvasMode ? s.canvasMarginLive : 0])
    }

    // MARK: - 方案 B：布局与视口

    private var pushedLayoutKey = ""
    /// 推平板当前会话的文档布局（每页原始宽高）。仅文档变化时推；`force` 用于新平板连接时补发。
    /// 避免每次滚动/翻页重广播 layout，减少平板端无谓 relayout 与回环噪声。
    func pushLayout(force: Bool = false) {
        guard server.hasClients, let s = padSession, let pdf = s.pdf else { return }
        if !force && s.contentHash == pushedLayoutKey { return }
        pushedLayoutKey = s.contentHash
        var pages: [[Double]] = []
        pages.reserveCapacity(pdf.pageCount)
        for i in 0..<pdf.pageCount {
            let b = pdf.page(at: i).map { $0.bounds(for: PageBitmap.effectiveBox($0)) } ?? .zero
            pages.append([Double(b.width), Double(b.height)])
        }
        server.broadcast([
            "type": "layout",
            "docId": s.contentHash,
            "v": s.contentHash,
            "count": pdf.pageCount,
            "pages": pages
        ])
    }

    /// Mac 侧导航 → 广播视口锚点给平板。origin=pad 不回发（避免与平板回传成环）；
    /// 其余来源（mac 滚动 / toc 跳转 / search 命中 / restore 进度恢复 / sim）都是 Mac 侧位置变化，统一下发。
    func macScrolled(_ s: DocSession) {
        guard server.hasClients, s.id == padSession?.id,
              let a = s.scrollAnchor, a.origin != "pad" else { return }
        server.broadcast(["type": "viewport", "page": a.page, "frac": a.frac, "seq": a.seq])
    }

    /// 把平板当前会话的阅读位置补发给平板（force 绕过平板端 seq 去重，seq 可能早已应用过）。
    /// 用于新平板连接、平板切换文档后，让平板立即落到 Mac 当前进度，而不是停在第 1 页。
    func pushCurrentViewport() {
        guard server.hasClients, let s = padSession else { return }
        let page = s.scrollAnchor?.page ?? s.currentPageIndex
        let frac = s.scrollAnchor?.frac ?? 0
        guard page > 0 || frac > 0 else { return }   // 本来就在第 1 页顶部，无需下发
        server.broadcast(["type": "viewport", "page": page, "frac": frac, "force": true])
    }
}
