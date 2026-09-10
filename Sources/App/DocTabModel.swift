import Combine
import Foundation
import PDFKit

/// **一个标签页的完整状态与落库**（多标签方案见 `MAC-TABS-PLAN.md`）。
///
/// 这些代码原本散在 `ContentView` 里，靠十几条 `.onChange` 驱动。搬到这里的理由只有一条，
/// 但它是硬的：
///
/// 🔴 **落库不能押在视图生命周期上。** 多标签之后「一个标签 = 今天的一个窗口」，而后台标签
/// **没有视图在跑**——平板往后台标签写一笔、AI 面板绑到后台标签，若落库仍挂在
/// `ContentView.onChange` 上就会静默丢数据。本类的订阅在 `init` 里建、在 `close()` 里断，
/// 与「这个标签当前可不可见」完全无关。
///
/// （本项目已被视图生命周期坑过两次——「零尺寸视图 SwiftUI 根本不创建」`RootView.WindowCloser`
/// 与「`onDisappear` 在窗口建立过程中空放一次」`WindowLifecycle`——所以也没走「给每个标签挂一个
/// 隐形视图替它跑 onChange」那条捷径。前者随 2026-09-01 的 AppKit 窗口层迁移一并删除，
/// 教训仍然成立：**别把落库押在视图生命周期上**。）
///
/// 与 `DocSession` 的分工：`DocSession` 是**运行时状态**（当前 PDF / 笔迹 / 选区 / 滚动锚点，
/// 阅读区和平板广播都读它）；本类是**这个标签的账房**（加载、增量对账落库、进度存取、
/// 工作区登记），不参与渲染。
@MainActor
final class DocTabModel: ObservableObject, Identifiable {
    /// 标签身份 = 会话身份。全项目的跨模块记账（`AppModel.sessions`、平板 `docs`、
    /// 工作区「打开集」`windowDocs`、`WorkspaceRegistry.windowPaths`）都按这个 id 走，
    /// 标签化之后它们的语义一行不用改——只是条目从「每窗一个」变成「每标签一个」。
    let id: UUID
    let session: DocSession

    private let app: AppModel
    private let workspace: WorkspaceManager
    private var bag = Set<AnyCancellable>()

    /// 本标签当前显示的库文档 id（原 `ContentView.selectedDocID`）。
    @Published private(set) var docID: String?
    /// 选中但所有路径失效 → 显示重定位提示。
    @Published var missingDoc: LibDocument?
    /// 同路径内容被替换（hash 与入库版本不符）待确认。
    @Published var hashMismatch: HashMismatch?
    /// 正在算 hash 入库（导入 / 重定位）→ 阅读区顶部显示「正在索引…」。
    @Published var isHashing = false

    /// **只记下了要开哪篇、还没真装**（懒装载）。
    ///
    /// 「装」= 打开 PDF + 解目录 + 把这篇的笔迹/注解/高亮/AI 会话/草稿纸全读进来。2026-09-02 实测
    /// 一篇 586 页、3506 条笔记的书要 0.33s（冷盘上还要再加 0.6s，见 `HISTORY.md` 同日那条剖析），
    /// 而冷启动 `restoreTabs` 会一口气恢复一组标签——**一扇窗里只有一个看得见**，其余全是白装。
    /// 现在只装活动那一个，其余等切过去再装（同安卓模式1 早就有的懒装载）。
    private(set) var staged = false

    /// 本标签是不是窗口里**正显示着**的那个（由 `TabsModel` 维护）。
    /// 🔴 `load()` 只在自己是活动标签时才 `app.setActive` —— 否则冷启动恢复一组标签时，
    /// 每装载一个后台标签就把平板抢过去一次，最后平板跟着的是恢复顺序里的最后一篇而不是用户那篇。
    var isActive = false

    /// 标签栏上显示的标题：会话标题为空（空标签 / 路径失效）时退回库里的文档名，再退回「新标签页」。
    var tabTitle: String {
        if !session.title.isEmpty { return session.title }
        if let d = missingDoc { return d.title }
        if let id = docID, let d = workspace.document(id: id) { return d.title }
        return L("New Tab")
    }

    /// 「同路径换内容」待确认：文件存在但 hash 与入库版本不符（用户原地覆盖了 PDF）。
    struct HashMismatch: Identifiable {
        let docId: String; let path: String; let newHash: String
        var id: String { docId }
    }

    private var lastProgressSave = Date.distantPast
    private var progressSaveTask: Task<Void, Never>?   // 节流窗内被丢变化的尾随补存
    private var closed = false

    deinit { wsLog("标签释放") }

    init(app: AppModel, workspace: WorkspaceManager, windowID: UUID) {
        let s = DocSession()
        s.windowID = windowID   // 窗口级的东西（内置 AI 面板宿主）按它分，不按标签分
        self.session = s
        self.id = s.id
        self.app = app
        self.workspace = workspace
        // 必须在 register 之前：AppModel 要靠会话捎带的工作区快照才知道该把哪个书库广播给平板。
        syncWorkspaceSnapshot()
        app.register(s)
        WorkspaceRegistry.shared.noteWindow(s.id, path: workspace.folder?.path)
        bind()
    }

    // MARK: - 订阅（替代原先 ContentView 的十几条 .onChange）

    /// 把一条 `@Published` 接成「与 SwiftUI `onChange` 等价」的订阅。
    ///
    /// 🔴 三个修饰符一个都不能少，理由各不相同：
    ///
    /// · **`removeDuplicates()`** —— `@Published` 的 publisher **每次赋值都发**，不比相等性；
    ///   `onChange` 只在值真变了才触发。少了它，赋同值也会跑一遍全量对账。
    ///   **必须排在 `dropFirst()` 前面**：这样首值也参与比较，「赋一个与初值相同的值」才不会
    ///   因为它恰好是去重流的第一个元素而漏网。
    ///
    /// · **`dropFirst()`** —— `$x` 在订阅瞬间会先发一次当前值，`onChange` 不会。
    ///
    /// · **`receive(on: DispatchQueue.main)`** —— 最要命的一条：`@Published` 是在 **`willSet`**
    ///   发送的，同步回调里 `session.x` 读到的还是**旧值**，而下面这些 `persist*` /
    ///   `app.broadcast*` 全都直接读 `session.x`。异步跳一拍、等值落定之后再跑，语义才与
    ///   `onChange` 一致。顺带还解决了「在 willSet 里反手改另一个 `@Published`」的重入问题
    ///   （`aiPanel.consumeUpsert()`、`app.padCanvasRequest = nil` 都是这种）。
    ///
    /// ⚠️ 与 `onChange` 唯一的语义差：**同一轮里对同一个属性赋 N 次值 = N 次回调**
    /// （`onChange` 会合并成一次带最终值的回调）。因为异步跳拍，这 N 次读到的都是同一份最终状态，
    /// 而所有 `persist*` 都是幂等的增量对账，所以多跑的那几次只是空扫描，不会写错。
    /// 实际会重复的只有 `readZoom`（`load` 里先置 1 再套用库里的值）这种，无伤。
    private func on<P: Publisher>(_ pub: P,
                                  _ action: @escaping (DocTabModel) -> Void)
    where P.Output: Equatable, P.Failure == Never {
        pub.removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, !self.closed else { return }
                    action(self)
                }
            }
            .store(in: &bag)
    }

    private func bind() {
        // 🔴 **把会话的变更原样转发给本对象**。`ContentView` 以前是 `@StateObject var session`、
        // 直接观察会话；现在它只观察 `tab`，少了这一条，标题栏 / 工具栏禁用态 / 查找条 / OCR 面板
        // 就再也不会跟着会话刷新（表现：翻页了副标题还停在旧页码）。转发之后二者等价，
        // 刷新频率也与从前一模一样——`readZoom` 仍是「缩放稳定后才写一次」，
        // `readHFrac` 仍被刻意排除在 `@Published` 之外（那两条性能红线不受影响）。
        session.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &bag)

        on(session.$currentPageIndex) { s in
            s.app.sessionChanged(s.session)
            s.saveProgress()             // 翻页即存，避免只靠节流/关窗丢进度
        }
        // 锚点走**回调**而不是 `@Published`（红线在 `DocSession.scrollAnchor` 上）：本机滚动每帧
        // 发一次，挂在 `objectWillChange` 上就是每帧把整扇窗标脏。这两件事都不刷新视图，所以
        // 同步调即可 —— `emitAnchor` 是**先赋值后回调**，此刻 `session.scrollAnchor` 已是新值，
        // 不存在 `on(...)` 当年非要 `receive(on:)` 才能绕开的那个「willSet 里读到旧值」问题。
        session.onAnchorChanged = { [weak self] _ in
            guard let self, !self.closed else { return }
            self.app.macScrolled(self.session)
            self.saveProgressThrottled(self.session.scrollAnchor)
        }
        on(session.$readZoom) { s in
            s.saveProgressThrottled(s.session.scrollAnchor)   // 缩放变化也存（含 restore 后手动缩放）
        }
        on(session.$strokes) { s in
            s.persistInk()               // 笔画完成/擦除/框选移动时增量落库（liveStroke 变化不触发）
        }
        on(session.$inkLayers) { s in
            s.persistInkLayers()         // 新建/改名/改色/改可见性/重排序时增量落库
            s.app.broadcastLayers()
            // 可见性变化（或删除图层连带删笔迹）会改变 broadcastStrokes 的过滤结果，但笔迹本身
            // （session.strokes）没变、不会触发上面那条——必须在这里补发一次，否则平板画布上
            // 已经画出来的笔迹在切可见性后不会跟着增减，只有等下一笔画/擦除才会捎带刷新。
            s.app.broadcastStrokes()
        }
        on(session.$activeLayerID) { s in
            s.app.broadcastLayers()      // 当前作画图层变化也同步给平板
        }
        on(session.$textNotes) { s in
            s.persistTextNotes()         // 文字注解新建/编辑/删除时增量落库
            s.app.broadcastNotes()       // 同步镜像给平板（圆形标记；非 padSession 时为空操作/重发同值）
        }
        on(session.$highlights) { s in
            s.persistHighlights()        // 高亮新建/改色/删除时增量落库
        }
        on(session.$bookmarks) { s in
            s.persistBookmarks()         // 书签新建/改名/删除时增量落库
            // 镜像给平板（非 padSession 时 broadcastBookmarks 内部会挑真正跟随的那个会话，
            // 本标签不是它就等于重发同值——同 broadcastNotes 的惯例）
            s.app.broadcastBookmarks()
        }
        on(session.$aiThreads) { s in
            s.persistAIThreads()         // 新建/改标题/改失效状态/解绑时增量落库
        }
        on(session.$scratchPads) { s in
            s.persistScratchPads()       // 草稿纸新建/改名/删除时增量落库
            s.app.broadcastScratchPads() // 列表变了 → 平板的草稿纸列表跟着变
        }
        on(session.$scratchStrokes) { s in
            s.persistScratchStrokes()    // 草稿纸上落笔/擦除时增量落库（scratchLive 变化不触发）
            s.app.broadcastScratchStrokes()
        }
        on(session.$openPadID) { s in
            // 打开/关闭草稿纸 = 平板跟着切过去（笔迹共享、视图各自独立）；同时把纸上的笔迹推过去。
            s.app.broadcastScratchPads()
            s.app.broadcastScratchStrokes()
        }
        // 平板请求切画板模式（`canvas` 上行）：只有 sessionID 对上的那个标签认领。
        on(app.$padCanvasRequest) { s in
            guard let req = s.app.padCanvasRequest, req.sessionID == s.session.id else { return }
            s.app.padCanvasRequest = nil
            s.setCanvasMode(req.on)      // 与工具栏按钮同一条路径（改 session + 逐文档落库）
        }
        // AI 面板捕到会话 URL / 选中一段回答建笔记：只有发起绑定的那个标签认领落库。
        on(AIPanelModel.shared.$threadUpsert) { s in
            s.applyAIThreadUpsert(AIPanelModel.shared.threadUpsert)
        }
        on(AIPanelModel.shared.$noteRequest) { s in
            s.applyAINoteRequest(AIPanelModel.shared.noteRequest)
        }
    }

    // MARK: - 关闭

    /// 关标签 / 关窗：把这个标签对工作区的账**全部结清**再放手。
    ///
    /// 🔴 **次序有讲究，别调换**（原 `ContentView.onDisappear` 的纪律）：写库那两步
    /// （进度 / 打开集）必须**先**做完，`noteWindow(nil)` 才可以把「本工作区已无会话」告诉
    /// registry —— 它据此关掉库连接（`WorkspaceRegistry.maybeTeardown`）。早关一步就是静默丢进度。
    ///
    /// 🔴 **`flushPersist()` 是订阅异步化之后新增的一道保险**：`on()` 把落库跳到了下一拍，
    /// 万一「最后一笔/最后一次擦除」和关窗落在同一轮，那一拍就会排在库连接关闭之后 → 静默丢。
    /// 这里同步补跑一遍（全是幂等增量对账，没有待写内容时就是一次空扫描）。
    func close() {
        guard !closed else { return }
        closed = true
        progressSaveTask?.cancel()
        progressSaveTask = nil
        bag.removeAll()          // 先断订阅，避免下面这几步自己又触发一轮
        flushPersist()
        saveProgress()
        workspace.closeWindow(session.id)
        WorkspaceRegistry.shared.noteWindow(session.id, path: nil)
        app.unregister(session)
        session.teardown()       // 放掉本标签持有的 PDF / 库引用（不然移动硬盘弹不出去）
    }

    /// 把可能还排在异步队列里的落库同步补齐（见 `close()` 的红线）。全部幂等。
    private func flushPersist() {
        persistInk()
        persistInkLayers()
        persistTextNotes()
        persistHighlights()
        persistBookmarks()
        persistAIThreads()
        persistScratchPads()
        persistScratchStrokes()
    }

    // MARK: - 工作区快照

    /// 把本标签所属工作区的名字/路径/书库拷进会话，供 `AppModel.broadcastLibrary`（App 级、
    /// 够不着窗口级的 `@MainActor WorkspaceManager`）与 `openPadDoc` 判定「这个文档是不是
    /// 同工作区里已开着的」。
    func syncWorkspaceSnapshot() {
        session.workspaceName = workspace.name
        session.workspaceFolder = workspace.folder
        // 书库没变就别重建参考索引：那次遍历要逐篇查 location + variant 两张表，而本方法的触发点
        // 很密（换文档 / 开关窗口 / 工作区改名都会调）。
        if session.libraryDocs != workspace.documents {
            session.libraryDocs = workspace.documents
            session.libraryRefIndex = workspace.refDocIndex()
        }
    }

    /// 工作区路径变了（改名联动改包名）→ 把「会话↔工作区」的登记跟到新路径。
    func noteWorkspacePath(_ path: String?) {
        WorkspaceRegistry.shared.noteWindow(session.id, path: path)
    }

    // MARK: - 选中加载

    /// 切到另一篇文档（原 `ContentView.onChange(of: selectedDocID)` 那一整块）。
    func select(_ id: String?) {
        guard id != docID else { return }
        staged = false          // 从这一刻起这个标签是"装过的"（哪怕装成空态），进度可以存了
        let old = docID
        // 🔴 **先把旧文档还排在异步队列里的落库同步结清**（同 `close()` 的理由）：`on()` 把落库
        // 跳到了下一拍，万一「最后一次擦除」和「点侧栏切文档」落在同一轮，那一拍就会排到
        // `load(新文档)` 之后跑——那时会话里装的已经是新文档，旧文档那次改动会被当成无事发生。
        // 此刻会话仍是旧文档的内容，同步跑一遍正好把它写掉（没待写内容时就是一次空扫描）。
        flushPersist()
        docID = id
        // 切走前先存旧文档的进度（此刻会话仍是旧文档的锚点/缩放）。`old == nil`（本标签本来就空）
        // 时那个方法什么都不做——**别在那里兜底成当前文档**，理由见它的红线。
        saveProgress(documentId: old)
        load(id)
        workspace.setWindowDoc(session.id, id)   // 更新工作区打开文档集
        // 换文档 = 标题/书库 open 标记/目录都变；平板发起的 openDoc 也在这里收尾（锁到新会话）。
        // 挂在这里而不是 load 内部：那个函数有三条早退路径（无文档/路径失效/正常），
        // 出口逐个补一遍迟早漏掉一条。
        app.sessionDocumentChanged(session)
    }

    /// 强制重新加载当前文档（重定位之后用；`select` 会因 id 没变而早退）。
    func reload() { load(docID) }

    /// **切到这个标签之前**，把当前活着的阅读位置重新摆成「待恢复」值。
    ///
    /// 🔴 不做这一步，切回来会跳回**装载那一刻**的位置，而不是离开时停的地方。
    /// 因为切标签时阅读区会整体重建（`PageStreamView` 上的 `.id(docKey)`），而它的首帧
    /// （`ReaderSurface.setup`）只认两样东西：`restoreZoom`/`restoreHFrac`，以及**来源不是
    /// "mac" 的**那个锚点——本机滚动发出来的锚点 origin 恰恰就是 "mac"（那条判断存在的理由是
    /// 别让视图重建时把自己刚发的锚点又吃回去）。所以这里把活值翻译成一条 `restore` 锚点，
    /// 走的正是「开文档恢复进度」那条早就验熟了的路。
    ///
    /// 没装文档的空标签直接跳过（没有位置可言）。
    func prepareForReactivation() {
        guard session.pdf != nil else { return }
        // 有快照就叫阅读区**在重建的首次求值里**用它种状态（一帧都不空；细节见 `ReaderSurface.init`）。
        // 下面那条 restore 锚点是兜底：窗口尺寸变过导致快照作废时，靠它把位置恢复回来（慢一拍但不丢）。
        session.readerSeedPending = (session.readerSnapshot != nil)
        ZoomProbe.mark("切到标签「\(tabTitle)」：待种=\(session.readerSeedPending)"
            + " 布局缓存=\(session.cachedLayout != nil)")
        session.restoreZoom = session.readZoom
        session.restoreHFrac = CGFloat(session.readHFrac)
        let a = session.scrollAnchor
        session.emitAnchor(page: a?.page ?? session.currentPageIndex,
                           frac: a?.frac ?? 0, origin: "restore")
    }

    // MARK: - 懒装载

    /// 记下这个标签要开哪篇，但**先不装**（见 `staged`）。冷启动恢复标签组用。
    ///
    /// 标签栏照常显示书名——`tabTitle` 本来就会退回库里的文档名，不依赖已加载的会话。
    /// 「打开集」也照常登记：它管的是「这个窗口开着哪几篇」，与装没装无关（下次启动仍要恢复它）。
    func stage(_ id: String) {
        guard docID != id else { return }
        docID = id
        staged = true
        // 书名先填上：平板那份会话列表（`AppModel` 的 `docs` 广播）读的是 `session.title`，
        // 不填的话后台标签在平板上会显示成「未命名」。纯展示字段，装载时照常被 `load` 覆盖。
        session.title = workspace.document(id: id)?.title ?? ""
        workspace.setWindowDoc(session.id, id)
    }

    /// 真正装载（切到这个标签时调）。已经装过、或本来就没 stage 过 → 空操作。
    func realize() {
        guard staged, let id = docID else { return }
        // `select` 按「id 没变就早退」设计，这里先把 `docID` 抹掉，让它把这次当成「从空态开一篇」。
        // 同一轮同步跑完，界面看不到中间那一下。
        docID = nil
        select(id)
    }

    private func load(_ id: String?) {
        session.clearSearch()   // 换文档：旧文档的查找命中/高亮不应带过去
        session.clearJumps()    // 跳转历史按文档分（`JumpHistory`）：换文档 = 换一条新轨迹
        // 换文档 = 撤销链作废：栈里存的是**上一篇**那些条目的增量，套到新文档上就是凭空造笔迹。
        session.inkUndo.reset()
        session.scratchUndo.reset()
        // 换文档 → 本标签发起的那条 AI 绑定上下文作废，否则面板的上下文条会一直显示上一本书。
        AIPanelModel.shared.noteDocumentChanged(sessionID: session.id, documentId: id)
        session.store = workspace.store   // OCR 缓存读写用（仅主线程）
        session.restoreZoom = 1; session.readZoom = 1   // 默认 fit-width；成功路径按库覆盖
        session.restoreHFrac = 0; session.readHFrac = 0
        // 换文档 = 上一篇的屏幕快照与布局缓存全作废（该走库里的进度，不是上一篇的实化窗口与偏移）。
        session.readerSnapshot = nil
        session.readerSeedPending = false
        session.cachedLayout = nil
        session.canvasMode = false                      // 画板模式逐文档记，同上按库覆盖
        guard let id, let doc = workspace.document(id: id) else {
            session.pdf = nil; missingDoc = nil; session.toc = []; session.title = ""
            clearInk(); clearInkLayers(); clearTextNotes(); clearHighlights(); clearBookmarks(); clearScratch()
            clearAIThreads()
            session.reloadOCRState(); return
        }
        guard let target = workspace.openTarget(documentId: id),
              let pdf = PDFDocument(url: URL(fileURLWithPath: target.path)) else {
            session.pdf = nil
            session.title = ""
            missingDoc = doc                       // 所有路径失效 → 显示重定位提示
            session.toc = []
            clearInk()
            clearInkLayers()
            clearTextNotes()
            clearHighlights()
            clearBookmarks()
            clearScratch()
            clearAIThreads()
            return
        }
        missingDoc = nil
        session.pdf = pdf
        session.toc = TOCEntry.build(from: pdf)
        session.title = doc.title
        session.contentHash = target.hash
        session.reloadOCRState()                   // 换文档重置 OCR；该内容已有缓存则自动启用
        loadInk(documentId: id)                    // 恢复该文档已落库的手写笔迹
        loadInkLayers(documentId: id)              // 恢复该文档的图层注册表（含自愈补建）
        session.noteTypes = workspace.noteTypes()  // 工作区笔记类型（通用内置兜底，不在列）
        session.noteTypeFilter = .all              // 筛选仅内存，开文档复位
        loadTextNotes(documentId: id)              // 恢复该文档已落库的文字注解
        loadHighlights(documentId: id)             // 恢复该文档已落库的高亮
        loadBookmarks(documentId: id)              // 恢复该文档已落库的书签（与目录合并显示）
        loadAIThreads(documentId: id)              // 恢复该文档已落库的 AI 会话绑定
        loadScratch(documentId: id)                // 恢复该文档的草稿纸与纸上笔迹（默认不打开任何一张）
        // 恢复阅读进度：缩放倍率 + 定页 + 精确滚到页内比例（restore 锚点，阅读区会跟随）。
        let p = workspace.progress(documentId: id)
        session.restoreZoom = CGFloat(p.zoom)      // 首帧定基准后由 PageStreamView 套用
        session.readZoom = CGFloat(p.zoom)
        session.restoreHFrac = CGFloat(p.hfrac)    // 横向滚动比例（缩放态/画板模式才非 0）
        session.readHFrac = p.hfrac
        session.canvasMode = p.canvas              // 画板模式（v12）
        let page = min(max(0, p.page), max(0, pdf.pageCount - 1))
        session.currentPageIndex = page
        lastProgressSave = .now                    // 避免恢复动作立刻又写一遍
        if page > 0 || p.frac > 0 {
            session.emitAnchor(page: page, frac: p.frac, origin: "restore")
        }
        // 只有活动标签才抢平板跟随（后台标签装载时不许动，见 `isActive` 注释）。
        if isActive { app.setActive(session) }
        app.sessionChanged(session)
        app.broadcastStrokes()   // 新文档的已存笔迹回传平板（平板本地不落库，靠 Mac 回显）
        verifyContentHash(documentId: id, openedPath: target.path, storedHash: target.hash)
    }

    /// 同路径内容校验：文件仍在但可能已被原地替换。后台重算 hash（FileHasher 缓存键含 mtime，
    /// 内容变必重算），与入库版本不符 → 弹窗请用户选「关联为新版本 / 仍打开」。
    private func verifyContentHash(documentId: String, openedPath: String, storedHash: String) {
        guard !storedHash.isEmpty else { return }
        Task.detached(priority: .utility) { [weak self] in
            guard let actual = try? FileHasher.sha256Cached(of: URL(fileURLWithPath: openedPath)),
                  !actual.isEmpty, actual != storedHash else { return }
            // 内层再捕一次 weak self：直接沿用外层那个 `weak var self` 会跨并发边界引用一个 var
            // （Swift 6 语言模式下是错误）。
            await MainActor.run { [weak self] in
                guard let self else { return }
                // 用户可能已切走文档：仍停留在该文档才提示
                guard self.docID == documentId else { return }
                self.hashMismatch = HashMismatch(docId: documentId, path: openedPath, newHash: actual)
            }
        }
    }

    /// 「文件已变化」→ 关联为新版本（改库，OCR 缓存键跟实际内容走）。
    func linkAsNewVersion(_ m: HashMismatch) {
        workspace.rekeyLocation(documentId: m.docId, absolutePath: m.path,
                                newHash: m.newHash, pageCount: session.pdf?.pageCount ?? 0)
        session.contentHash = m.newHash
        session.reloadOCRState()
    }

    /// 「文件已变化」→ 仍打开（不改库：本次按实际内容打开，下次打开仍会提示）。
    func openAnyway(_ m: HashMismatch) {
        session.contentHash = m.newHash
        session.reloadOCRState()
    }

    // MARK: - 重定位

    func relocate(_ doc: LibDocument, url: URL) {
        isHashing = true
        Task {
            let hash = await Task.detached(priority: .userInitiated) {
                (try? FileHasher.sha256Cached(of: url)) ?? ""
            }.value
            let pageCount = PDFDocument(url: url)?.pageCount ?? 0
            workspace.relocate(documentId: doc.id, path: url.path, hash: hash, pageCount: pageCount)
            isHashing = false
            load(doc.id)
        }
    }

    // MARK: - 画板模式（v12）

    /// 切画板模式（工具栏按钮 / ⌥⌘C）。
    func toggleCanvasMode() { setCanvasMode(!session.canvasMode) }

    /// 设画板模式：改 session（阅读区 onChange 里做布局补偿 + 广播给平板）+ 立即落库（逐文档记，
    /// 不走阅读进度那套节流——它不像滚动位置那样每帧都变）。没开文档时空转。
    /// 本机按钮与**平板上行**（`padCanvasRequest`）共用这一条，别在两处各写一遍落库。
    func setCanvasMode(_ on: Bool) {
        guard session.pdf != nil, let id = docID, session.canvasMode != on else { return }
        session.canvasMode = on
        workspace.setCanvasMode(documentId: id, on: on)
    }

    // MARK: - 阅读进度

    private func saveProgressThrottled(_ a: ScrollAnchor?) {
        guard docID != nil else { return }
        let now = Date.now
        let elapsed = now.timeIntervalSince(lastProgressSave)
        if elapsed > 0.7 {
            lastProgressSave = now
            progressSaveTask?.cancel()
            progressSaveTask = nil
            saveProgress(anchor: a)
            return
        }
        // 尾随补存：节流窗内被丢的变化（缩放/滚动尾帧）延迟落库一次。Xcode 重跑(⌘R)是被 lldb
        // 直接杀进程，走不到关窗的兜底保存，没有尾随补存最后一次缩放就永久丢失。
        //
        // ⚠️ **已经排着一个就别重排**：截止点恒为 `lastProgressSave + 0.7`（不随新事件后移），
        // 重排出来的是同一个时刻，纯属白扔 —— 而本机滚动**每帧**都会走到这儿，等于每秒
        // cancel + 新建上百个 `Task`。到点时它自己去读最新的 `session.scrollAnchor`
        // （`saveProgress()` 不带参，见下面那个重载），所以期间的变化一样存得到。
        guard progressSaveTask == nil else { return }
        progressSaveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64((0.7 - elapsed) * 1_000_000_000))
            guard let self else { return }
            self.progressSaveTask = nil        // 先腾出槽位，否则被取消那次会把后续补存永久挡住
            guard !Task.isCancelled, !self.closed else { return }
            self.lastProgressSave = .now
            self.saveProgress()
        }
    }

    /// 存**本标签当前文档**的进度。
    func saveProgress(anchor: ScrollAnchor? = nil) {
        saveProgress(documentId: docID, anchor: anchor)
    }

    /// 存**指定文档**的进度。`documentId == nil` 就什么都不做。
    ///
    /// 🔴 **这里绝不能把 nil 兜底成「当前文档」**（2026-08-29 用户报「进度没有保存/恢复」的根因，
    /// 是第 1 步搬家时把原来的 `guard let docId else { return }` 误改成 `docId ?? docID` 埋下的）：
    /// `select()` 会用「切走前的旧文档 id」调它，而窗口第一次开文档时那个 id 是 **nil**——
    /// 兜底成当前文档的话，就会在 `load()` **读取进度之前**，先拿空会话的状态（第 0 页、缩放 1）
    /// 把这篇文档存着的进度覆盖掉。表现就是每次打开文档都自毁一次进度，从来回不到上次的位置。
    private func saveProgress(documentId: String?, anchor: ScrollAnchor? = nil) {
        guard let id = documentId else { return }
        // 🔴 **还没装载过的标签没有「当前位置」**：此刻 `session` 还是空的（第 0 页、缩放 1），
        // 存下去就是把库里那篇真正的进度抹成开头。这是懒装载引进来的头号陷阱——关窗（`close`）
        // 与切走（`select` 存旧文档）两条路都会打到这里，所以守卫放在这个最里层的出口。
        guard !staged else { return }
        let a = anchor ?? session.scrollAnchor
        workspace.saveProgress(documentId: id, page: a?.page ?? session.currentPageIndex,
                               frac: a?.frac ?? 0, zoom: Double(session.readZoom),
                               hfrac: session.readHFrac)
    }

    // MARK: - 手写笔迹持久化（note kind=2）

    /// 加载文档时清空内存笔迹与对账集（无文档 / 路径失效时用）。
    private func clearInk() {
        session.documentId = nil
        session.strokes = []
        session.liveStroke = nil
        session.persistedStrokes = [:]
    }

    /// 恢复该文档已落库的手写笔迹到内存，并记录对账集（避免加载即被判为“新增”而重复落库）。
    private func loadInk(documentId id: String) {
        session.documentId = id
        session.liveStroke = nil
        let loaded = workspace.inkStrokes(documentId: id)
        session.persistedStrokes = Dictionary(uniqueKeysWithValues: loaded.map { ($0.id, $0) })
        session.strokes = loaded
    }

    /// 内存笔画 ↔ 库对账：新增或内容变更的 → upsert；曾落库而现已无的（擦除）→ delete。
    /// 用值快照比较（仿 `persistTextNotes`）：同 id 内容变更（框选移动）也识别为“变更”并 upsert——
    /// 旧版只对账 id 集合，移动笔迹后 id 不变、内容变，会被漏写。
    private func persistInk() {
        guard let id = session.documentId else { return }
        let t0 = CFAbsoluteTimeGetCurrent()
        let current = session.strokes
        let currentIDs = Set(current.map(\.id))
        var upserts = 0, deletes = 0
        for st in current where session.persistedStrokes[st.id] != st {
            workspace.saveInkStroke(documentId: id, st)
            upserts += 1
        }
        for goneID in session.persistedStrokes.keys where !currentIDs.contains(goneID) {
            workspace.deleteInkStroke(id: goneID)
            deletes += 1
        }
        session.persistedStrokes = Dictionary(uniqueKeysWithValues: current.map { ($0.id, $0) })
        // 每收一笔主线程要花的账（`PadLog`，默认关；开关见 UniReaderApp.swift）。
        // 三段各自的量纲不同，要分开看：
        // - **派发**＝ `strokes` 变了到这里开跑（现在是 Combine 订阅跳一拍，见 `on()`）；
        // - **对账**＝ 本函数自身：逐条整值比较（比的是全部点）+ 重建整张 id→笔迹 快照；
        // 后者是 O(笔迹数 × 点数)、每收一笔跑一遍，写久了的文档就是它在吃主线程。
        if session.lastInkEndAt > 0 {
            let dispatch = t0 - session.lastInkEndAt
            let reconcile = CFAbsoluteTimeGetCurrent() - t0
            // 字符串（含那个数点数的 reduce）在 PadLog 的 @autoclosure 里，关着的时候一行都不跑
            PadLog.log("收笔对账 \(current.count)条/\(current.reduce(0) { $0 + $1.points.count })点："
                + "派发 \(PadLog.ms(dispatch))，对账 \(PadLog.ms(reconcile))（写 \(upserts) 删 \(deletes)）")
            session.lastInkEndAt = 0   // 只量收笔那一次；擦除/框选也会进来，别混进同一条读数
        }
    }

    // MARK: - 笔迹图层持久化（ink_layer 表，v7）

    /// 加载文档时清空内存图层与对账集（无文档 / 路径失效时用）。
    private func clearInkLayers() {
        session.inkLayers = []
        session.persistedInkLayers = [:]
        session.activeLayerID = nil
    }

    /// 恢复该文档已落库的图层到内存（按 sortOrder）。**必须在 `loadInk` 之后调用**：
    /// 自愈逻辑要看 `session.strokes` 里实际出现过哪些 `layerId`。老文档（升级前落库、
    /// 尚无 `ink_layer` 行）或笔迹引用了缺失图层（如合并文档留下的孤儿层）时，
    /// 为每个缺失 id 各补建一条图层并立即落库——否则那些笔迹在图层面板里无处可归、
    /// 也无法被可见性开关命中，页面上会“凭空”多出/少掉一批笔迹。
    private func loadInkLayers(documentId id: String) {
        var loaded = workspace.inkLayers(documentId: id).sorted { $0.sortOrder < $1.sortOrder }
        let knownIDs = Set(loaded.map(\.id))
        var missing = Set(session.strokes.map(\.layerId)).subtracting(knownIDs)
        if loaded.isEmpty { missing.insert(InkLayer.defaultID) }   // 全新/老文档兜底建第一层
        if !missing.isEmpty {
            var nextOrder = (loaded.map(\.sortOrder).max() ?? -1) + 1
            for missingID in missing.sorted(by: { $0.uuidString < $1.uuidString }) {
                let name = String(format: L("Layer %d"), nextOrder + 1)
                let layer = InkLayer(id: missingID, name: name,
                                     colorKey: InkLayer.rotatingColorKey(existingCount: loaded.count),
                                     sortOrder: nextOrder, visible: true)
                loaded.append(layer)
                workspace.saveInkLayer(documentId: id, layer)
                nextOrder += 1
            }
            loaded.sort { $0.sortOrder < $1.sortOrder }
        }
        session.persistedInkLayers = Dictionary(uniqueKeysWithValues: loaded.map { ($0.id, $0) })
        session.inkLayers = loaded
        session.activeLayerID = loaded.first?.id
    }

    /// 内存图层 ↔ 库对账：新增/改名/改色/改可见性/重排序 → upsert；已删除的 → delete。
    private func persistInkLayers() {
        guard let id = session.documentId else { return }
        let current = session.inkLayers
        let currentIDs = Set(current.map(\.id))
        for l in current where session.persistedInkLayers[l.id] != l {
            workspace.saveInkLayer(documentId: id, l)
        }
        for goneID in session.persistedInkLayers.keys where !currentIDs.contains(goneID) {
            workspace.deleteInkLayer(id: goneID)
        }
        session.persistedInkLayers = Dictionary(uniqueKeysWithValues: current.map { ($0.id, $0) })
    }

    // MARK: - 文字注解持久化（note kind=0）

    /// 加载文档时清空内存文字注解与对账集（无文档 / 路径失效时用）。
    private func clearTextNotes() {
        session.persistedTextNotes = [:]
        session.textNotes = []
    }

    /// 恢复该文档已落库的文字注解到内存，并记录对账集（避免加载即被判为“新增”而重复落库）。
    /// ⚠️ 对账集必须**先于** `textNotes` 赋值（与 `loadInk` 同序）：`textNotes=` 会触发订阅→
    /// `persistTextNotes`，若此时快照仍是旧文档，会拿旧快照对账新列表 → 误删旧文档的注解行。
    private func loadTextNotes(documentId id: String) {
        let loaded = workspace.textNotes(documentId: id)
        session.persistedTextNotes = Dictionary(uniqueKeysWithValues: loaded.map { ($0.id, $0) })
        session.textNotes = loaded
    }

    /// 内存注解 ↔ 库对账：新增或内容变更的 → upsert；曾落库而现已无的（删除）→ delete。
    /// 用值快照比较，故编辑（改文本 / bump updatedAt）也会被识别为“变更”并 upsert。
    private func persistTextNotes() {
        guard let id = session.documentId else { return }
        let current = session.textNotes
        let currentIDs = Set(current.map(\.id))
        for n in current where session.persistedTextNotes[n.id] != n {
            workspace.saveTextNote(documentId: id, n)
        }
        for goneID in session.persistedTextNotes.keys where !currentIDs.contains(goneID) {
            workspace.deleteTextNote(id: goneID)
        }
        session.persistedTextNotes = Dictionary(uniqueKeysWithValues: current.map { ($0.id, $0) })
    }

    // MARK: - AI 会话绑定持久化（note kind=1）

    /// 清空内存 AI 会话与对账集（对账集先于列表赋值，同 loadTextNotes 防切档误删）。
    private func clearAIThreads() {
        session.persistedAIThreads = [:]
        session.aiThreads = []
    }

    private func loadAIThreads(documentId id: String) {
        let loaded = workspace.aiThreads(documentId: id)
        session.persistedAIThreads = Dictionary(uniqueKeysWithValues: loaded.map { ($0.id, $0) })
        session.aiThreads = loaded
    }

    private func persistAIThreads() {
        guard let id = session.documentId else { return }
        let current = session.aiThreads
        let currentIDs = Set(current.map(\.id))
        for t in current where session.persistedAIThreads[t.id] != t {
            workspace.saveAIThread(documentId: id, t)
        }
        for goneID in session.persistedAIThreads.keys where !currentIDs.contains(goneID) {
            workspace.deleteAIThread(id: goneID)
        }
        session.persistedAIThreads = Dictionary(uniqueKeysWithValues: current.map { ($0.id, $0) })
    }

    /// 应用 AI 面板发来的落库请求。
    ///
    /// **为什么要绕这一圈**：面板是 App 级单例（一个浮窗服务所有窗口），而 `LibraryStore` 是
    /// 工作区级且同一个库只许一个连接（`REQUIREMENTS.md §8.1` 红线）。面板不碰库，只发请求，
    /// 由**发起这次绑定的那个标签**认领落库——认领条件是 `sessionID` + `documentId` 双对
    /// （同 `padOpenDocRequest` 带 sessionID 的理由：不带的话每个标签都会执行一遍）。
    /// 写进 `session.aiThreads` 之后，上面的订阅会增量对账写库，不在这里直接写。
    private func applyAIThreadUpsert(_ req: AIThreadUpsert?) {
        guard let req, req.sessionID == session.id, req.documentId == session.documentId else { return }
        if let i = session.aiThreads.firstIndex(where: { $0.id == req.thread.id }) {
            session.aiThreads[i] = req.thread
        } else {
            session.aiThreads.append(req.thread)
        }
        AIPanelModel.shared.consumeUpsert()
    }

    /// 认领 AI 面板发来的建笔记请求（S5）。认领条件与 `applyAIThreadUpsert` 一样是
    /// **sessionID + documentId 双对**；写进 `session.textNotes` 之后，既有订阅会增量对账落库。
    private func applyAINoteRequest(_ req: AINoteRequest?) {
        guard let req, req.sessionID == session.id, req.documentId == session.documentId else { return }
        session.textNotes.append(req.note)
        AIPanelModel.shared.consumeNoteRequest()
    }

    // MARK: - 文字高亮持久化（note kind=3）

    /// 清空内存高亮与对账集（对账集先于列表赋值，同 loadTextNotes 防切档误删）。
    private func clearHighlights() {
        session.persistedHighlights = [:]
        session.highlights = []
    }

    private func loadHighlights(documentId id: String) {
        let loaded = workspace.highlights(documentId: id)
        session.persistedHighlights = Dictionary(uniqueKeysWithValues: loaded.map { ($0.id, $0) })
        session.highlights = loaded
    }

    /// 内存高亮 ↔ 库对账：新增/改色 upsert；已无的 delete。用值快照比较，改色也识别为“变更”。
    private func persistHighlights() {
        guard let id = session.documentId else { return }
        let current = session.highlights
        let currentIDs = Set(current.map(\.id))
        for h in current where session.persistedHighlights[h.id] != h {
            workspace.saveHighlight(documentId: id, h)
        }
        for goneID in session.persistedHighlights.keys where !currentIDs.contains(goneID) {
            workspace.deleteHighlight(id: goneID)
        }
        session.persistedHighlights = Dictionary(uniqueKeysWithValues: current.map { ($0.id, $0) })
    }

    // MARK: - 书签持久化（note kind=5，`REQUIREMENTS.md §1.9`）

    /// 清空内存书签与对账集（对账集先于列表赋值，同 `clearHighlights` 防切档误删）。
    private func clearBookmarks() {
        session.bookmarkDraft = nil
        session.persistedBookmarks = [:]
        session.bookmarks = []
    }

    private func loadBookmarks(documentId id: String) {
        let loaded = workspace.bookmarks(documentId: id)   // 已按 Bookmark.before 排好
        session.persistedBookmarks = Dictionary(uniqueKeysWithValues: loaded.map { ($0.id, $0) })
        session.bookmarks = loaded
        // 打点（`touch ~/Library/Logs/UniReader-ws.log` 才写盘）：页右缘那枚旗标只画在**书签自己
        // 那一页**上，所以「看不到」时第一件要分清的事就是「库里有没有、在第几页」。
        if !loaded.isEmpty {
            wsLog("书签装载 \(loaded.count) 枚，页码 \(loaded.map { $0.page + 1 })")
        }
    }

    /// 内存书签 ↔ 库对账：新增/改名 upsert；已无的 delete。用值快照比较，改名也识别为「变更」。
    private func persistBookmarks() {
        guard let id = session.documentId else { return }
        let current = session.bookmarks
        let currentIDs = Set(current.map(\.id))
        for b in current where session.persistedBookmarks[b.id] != b {
            workspace.saveBookmark(documentId: id, b)
        }
        for goneID in session.persistedBookmarks.keys where !currentIDs.contains(goneID) {
            workspace.deleteBookmark(id: goneID)
        }
        session.persistedBookmarks = Dictionary(uniqueKeysWithValues: current.map { ($0.id, $0) })
    }

    // MARK: - 草稿纸持久化（scratch_pad 表 + note kind=4，v8）

    /// 加载文档时清空内存草稿纸/纸上笔迹与两份对账集（无文档 / 路径失效时用）。
    /// ⚠️ 与 `clearInk` 同一条纪律：对账集必须**先于**列表赋值，否则订阅会拿旧文档的
    /// 快照对账新（空）列表，把上一篇的草稿纸整个从库里删掉。
    private func clearScratch() {
        session.openPadID = nil
        session.scratchLive = nil
        session.persistedScratchPads = [:]
        session.persistedScratchStrokes = [:]
        session.scratchPads = []
        session.scratchStrokes = []
    }

    /// 恢复该文档已落库的草稿纸与纸上笔迹。**默认一张都不打开**——草稿纸是覆盖层，
    /// 开着文档就弹一张纸盖住正文不是用户要的语义（要看哪张走图钉/侧栏列表）。
    private func loadScratch(documentId id: String) {
        session.openPadID = nil
        session.scratchLive = nil
        let pads = workspace.scratchPads(documentId: id)
        let strokes = workspace.scratchStrokes(documentId: id)
        session.persistedScratchPads = Dictionary(uniqueKeysWithValues: pads.map { ($0.id, $0) })
        session.persistedScratchStrokes = Dictionary(uniqueKeysWithValues: strokes.map { ($0.id, $0) })
        session.scratchPads = pads
        session.scratchStrokes = strokes
    }

    /// 内存草稿纸 ↔ 库对账：新增/改名/改底色 upsert；已删除的 delete（纸上笔迹由下面那个函数
    /// 一并对账掉——删纸时调用方要同时把它的笔迹从 `scratchStrokes` 里摘掉）。
    private func persistScratchPads() {
        guard let id = session.documentId else { return }
        let current = session.scratchPads
        let currentIDs = Set(current.map(\.id))
        for p in current where session.persistedScratchPads[p.id] != p {
            workspace.saveScratchPad(documentId: id, p)
        }
        for goneID in session.persistedScratchPads.keys where !currentIDs.contains(goneID) {
            workspace.deleteScratchPad(id: goneID)
        }
        session.persistedScratchPads = Dictionary(uniqueKeysWithValues: current.map { ($0.id, $0) })
    }

    /// 内存草稿纸笔迹 ↔ 库对账（与 `persistInk` 同套路，只是走 kind=4）。
    private func persistScratchStrokes() {
        guard let id = session.documentId else { return }
        let current = session.scratchStrokes
        let currentIDs = Set(current.map(\.id))
        for st in current where session.persistedScratchStrokes[st.id] != st {
            workspace.saveInkStroke(documentId: id, st)
        }
        for goneID in session.persistedScratchStrokes.keys where !currentIDs.contains(goneID) {
            workspace.deleteInkStroke(id: goneID)
        }
        session.persistedScratchStrokes = Dictionary(uniqueKeysWithValues: current.map { ($0.id, $0) })
    }
}
