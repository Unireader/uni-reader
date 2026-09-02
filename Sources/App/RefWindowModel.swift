import Combine
import CoreGraphics
import Foundation
import PDFKit

/// 参考窗（只读浮窗）的状态与文档持有。方案见 `REF-WINDOW-PLAN.md`。
///
/// 定义只有一句话：**一个浮在阅读区上的、只读的、可自由滚动的 PDF 显示窗，打开时定位到那本书的阅读进度。**
/// 没有笔迹、没有批注、没有选择、没有选笔盘（用户 2026-08-30：「小窗没有任何附加功能」）。
///
/// 🔴 **一扇窗口一份**（`ContentView` 的 `@StateObject`，而 `ContentView` 是每窗口一个实例）。
/// 按会话 id 分的话「切标签 = 换宿主」，小窗会被重建；按窗口分才有「切到另一个标签，参考还摆在
/// 旁边」——正是对照场景要的（同 AI 内置面板按 `windowID` 分宿主的拍板）。
///
/// 🔴 **一份也不落库、一个字节不上线**：开着没有 / 摆在哪 / 多大 / 开的哪本 / 滚到哪，
/// 全是本端私有视口状态。因此这个功能不碰 `PROTOCOL.md` 也不碰 schema。
@MainActor
final class RefWindowModel: ObservableObject {

    /// 本端记忆的键（`UserDefaults`）。**刻意不记「开着没有」**——冷启动自动弹一个小窗太突兀。
    private enum K {
        static let doc = "refWindowDocID"
        static let w = "refWindowW", h = "refWindowH"
        static let dx = "refWindowDX", dy = "refWindowDY"
    }

    static let minSize = CGSize(width: 260, height: 220)
    static let defaultSize = CGSize(width: 420, height: 520)

    @Published var isOpen = false
    /// 折叠成一枚气泡（不丢上下文，也不占版面）。折叠→展开**保持**滚动位置，
    /// 关闭→重开**回到进度**（视口记忆刻意分两级，见方案 §6）。
    @Published var collapsed = false

    @Published private(set) var docID: String?
    @Published private(set) var title = ""
    @Published private(set) var pdf: PDFDocument?
    @Published private(set) var layout: PageLayout?
    /// 页图缓存键的 doc 段 = 内容哈希，与阅读区同口径 —— 参考的若正是当前这本，**缓存直接共用**。
    @Published private(set) var docKey = ""
    /// 这本书的目录（`TOCEntry.build` 是纯函数，与阅读区同一份解析，含坏书签的处置）。
    /// 用户 2026-09-02：「参考小窗支持 toc 跳转」——对照习题/答案时按章节翻比拖滚动条实在。
    /// 仍不违反「只读」：跳转只动小窗自己的视口，**不写回那本书的阅读进度**（方案 §3 红线）。
    @Published private(set) var toc: [TOCEntry] = []

    /// 打开时的定位：那本书在库里的阅读进度（用户 2026-08-30：「默认是从 pdf 的进度打开」）。
    private(set) var seedPage = 0
    private(set) var seedFrac: Double = 0
    /// 每次 `load` 递增。页流据此重做一次「回到进度」的定位——同一本书再点一次「回到进度」也能回去。
    @Published private(set) var seedRev = 0

    // MARK: 视口记忆（**必须放在 model 里，不能放页流的 `@State`**）
    //
    // 折叠成气泡时面板整个从视图树里消失 → 页流被销毁、`@State` 全部归零。位置若记在页流里，
    // 展开后就会被当成「首次打开」重新定位到进度，而方案 §6 要的是两级语义：
    // **折叠→展开保持滚动位置；关闭→重开才回到进度**。
    //
    // 🔴 三个都**不是** `@Published`：滚动每帧都在写 `viewDocY`，发布出去等于每帧重算整个浮窗视图树
    // （同 `DocSession.readHFrac` 被刻意排除在 @Published 之外的理由）。
    /// 上次视口顶端的文档纵坐标（**文档单位**，与缩放无关）。nil = 还没看过。
    var viewDocY: CGFloat?
    /// 上次的缩放倍率。
    var viewZoom: CGFloat = 1
    /// 已经按第几版 `seedRev` 定位过了。`-1` = 还没定位（下次一定回到进度）。
    var seededRev = -1

    /// 渲染引擎的认领 id（一扇窗口一个）。
    /// 🔴 不声明 `setWanted` 的话，`PageRenderEngine` 会把入队超 1s 无人认领的请求直接丢弃，
    /// 结果是「完成回调永不触发、小窗永远停在占位图」。
    let clientID: String

    // 浮窗几何（本端记忆）。`offset` 是相对**右下角**的偏移（≤0 往左上）——
    // 这样改尺寸时右下角不动、只有左上角伸缩，缩放手柄放左上角即可。
    @Published var size: CGSize
    @Published var offset: CGSize

    /// ⚠️ 身份靠 `@StateObject` 保证：`ContentView` 每窗口一个实例、`@StateObject` 只建一次，
    /// 所以这里自己生成的 id 天然就是「一扇窗口一个」。**刻意不从外面传 `windowID` 进来**——
    /// 那会逼 `ContentView.init` 在 `StateObject(wrappedValue:)` 的 autoclosure 之外先建一个
    /// `TabsModel` 取它的 id，等于每次结构体重建都白建一个（那个类的构造是有副作用的）。
    init() {
        clientID = "ref-\(UUID().uuidString)"
        let d = UserDefaults.standard
        let w = d.double(forKey: K.w), h = d.double(forKey: K.h)
        size = (w >= Self.minSize.width && h >= Self.minSize.height)
            ? CGSize(width: w, height: h) : Self.defaultSize
        offset = CGSize(width: d.double(forKey: K.dx), height: d.double(forKey: K.dy))
    }

    /// 上次看的那本（记忆），没有就 nil。
    var rememberedDocID: String? {
        let s = UserDefaults.standard.string(forKey: K.doc) ?? ""
        return s.isEmpty ? nil : s
    }

    // MARK: - 开关

    /// 打开小窗。没指定看哪本就沿用上次那本，再没有就看当前这本。
    func open(preferring current: String?, workspace: WorkspaceManager) {
        isOpen = true
        collapsed = false
        let want = docID ?? rememberedDocID ?? current
        if let want, want != docID || pdf == nil { load(documentId: want, workspace: workspace) }
    }

    /// 换一本书看（顶栏的文档选择器）。
    func load(documentId: String, workspace: WorkspaceManager) {
        // 解析路径必须在主线程做：`WorkspaceManager` 是 `@MainActor`（方案 §4 红线 3）。
        guard let target = workspace.openTarget(documentId: documentId),
              let doc = PDFDocument(url: URL(fileURLWithPath: target.path)) else { return }
        // 🔴 **独立的 `PDFDocument` 实例**：`PDFDocument`/`PDFPage` 不是线程安全的，而这一份只归
        // `PageRenderEngine` 那条串行队列用。共用别人的文档对象 = 两个后台队列并发操作同一份
        // PDFKit 内部状态，2026-07-27 实测表现为 Mac 阅读区整片白屏、须手动翻页才恢复。
        releaseRenderClaim()
        docID = documentId
        pdf = doc
        layout = PageLayout(doc: doc)
        toc = TOCEntry.build(from: doc)
        docKey = target.hash.isEmpty ? documentId : target.hash
        title = workspace.document(id: documentId)?.title ?? ""
        let p = workspace.progress(documentId: documentId)
        seedPage = min(max(0, p.page), max(0, doc.pageCount - 1))
        seedFrac = p.frac
        seedRev &+= 1
        viewDocY = nil          // 换书 = 全新一份视口
        viewZoom = 1
        UserDefaults.standard.set(documentId, forKey: K.doc)
    }

    /// 跳到某页（目录点选）。**复用「定位」那条既有通路**：`seedRev` 一涨，页流的 `seedIfReady`
    /// 下一拍就把视口挪过去——不必再写第二套 scrollTo，也就不会有第二套「几何还没就位」的时序坑。
    func goto(page: Int, frac: Double = 0) {
        guard let pdf else { return }
        seedPage = min(max(0, page), max(0, pdf.pageCount - 1))
        seedFrac = min(max(0, frac), 1)
        seedRev &+= 1
    }

    /// 重新定位到那本书的进度（顶栏「回到进度」）。
    func rewindToProgress(workspace: WorkspaceManager) {
        guard let docID else { return }
        let p = workspace.progress(documentId: docID)
        seedPage = min(max(0, p.page), max(0, (pdf?.pageCount ?? 1) - 1))
        seedFrac = p.frac
        seedRev &+= 1
    }

    /// 关闭并**当场放掉文件引用**。
    ///
    /// 🔴 这是「一直开着的文件」：2026-08-05 用户报过工作区在移动硬盘上关窗后弹不出去，根因就是
    /// 漏了一份没显式释放的 PDF。关小窗 / 关标签 / 关窗口都要走到这里。
    func close() {
        isOpen = false
        releaseRenderClaim()
        pdf = nil
        layout = nil
        toc = []            // 下次打开走 `load` 重建（`pdf == nil` 时 `open` 必定重载）
        // 关闭→重开要回到进度（对比折叠→展开保持位置），所以这里才清视口记忆。
        viewDocY = nil
        viewZoom = 1
        seededRev = -1
        // `docID`/`title` 留着：下次打开还是这本（本端记忆）。
    }

    /// 交还渲染认领。
    /// ⚠️ **刻意不 `purge(doc:)`**：参考的若正是主视图那本书，purge 会把阅读区的页图一并清掉。
    /// 让 LRU 自然淘汰即可——反复开关小窗时还能直接命中。
    private func releaseRenderClaim() {
        PageRenderEngine.shared.setWanted([], client: clientID)
    }

    // MARK: - 几何（本端记忆）

    /// 夹取规则做成静态的：拖动/改尺寸**期间**用的是视图本地的临时量（见 `RefWindowView` 里
    /// 那两个 delta），不能每帧写回 `@Published` —— 那会让页流跟着每帧重算（用户 2026-08-30
    /// 报的「拖拽小窗时内容上下抖动」就是它）。
    static func clampSize(_ s: CGSize, in container: CGSize) -> CGSize {
        let maxW = max(minSize.width, container.width - 24)
        let maxH = max(minSize.height, container.height - 24)
        return CGSize(width: min(max(s.width, minSize.width), maxW),
                      height: min(max(s.height, minSize.height), maxH))
    }

    /// 夹在容器内：小窗右下角贴着容器右下角时 offset = 0，往左上是负值。
    static func clampOffset(_ o: CGSize, size: CGSize, in container: CGSize) -> CGSize {
        let minX = -max(0, container.width - size.width - 16)
        let minY = -max(0, container.height - size.height - 16)
        return CGSize(width: min(0, max(o.width, minX)),
                      height: min(0, max(o.height, minY)))
    }

    func setSize(_ s: CGSize, in container: CGSize) { size = Self.clampSize(s, in: container) }

    func setOffset(_ o: CGSize, in container: CGSize) {
        offset = Self.clampOffset(o, size: size, in: container)
    }

    func persistGeometry() {
        let d = UserDefaults.standard
        d.set(size.width, forKey: K.w); d.set(size.height, forKey: K.h)
        d.set(offset.width, forKey: K.dx); d.set(offset.height, forKey: K.dy)
    }
}
