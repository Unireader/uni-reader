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

    let app: AppModel
    let workspace: WorkspaceManager
    private var bag = Set<AnyCancellable>()

    /// 本标签当前显示的库文档 id（原 `ContentView.selectedDocID`）。
    @Published private(set) var docID: String?
    /// 本标签当前显示的 **Markdown 笔记**（v15，`MARKDOWN-NOTES-PLAN.md`）：源 + 源内相对路径。
    ///
    /// 🔴 **与 `docID` 互斥**：开 md 笔记前先 `select(nil)` 把 PDF 那边清干净。这样全项目
    /// 所有按 PDF 记账的地方（平板 `docs` 广播 / 工作区打开集 / MCP / 参考窗 / 笔架 / 草稿纸）
    /// 看到的就是一个**空标签**——那是它们本来就支持的状态，一行都不用改。
    @Published private(set) var noteRef: NoteRef? {
        didSet {
            guard (oldValue == nil) != (noteRef == nil) else { return }
            session.showsMarkdown = noteRef != nil
            app.broadcastBoards()   // 平板据 `boards.kind` 显示「Mac 正在看 Markdown 笔记」
        }
    }
    /// 本标签当前显示的**画板笔记**（v16，`BOARD-NOTE-PLAN.md`）。与 `docID` / `noteRef` 三者互斥，
    /// 同 Markdown 的做法：开画板前先 `select(nil)` 把 PDF 那边清干净。会话里的状态在 `session.board`。
    /// `staged` 为真时只记了身份、还没装（冷启动恢复的后台标签）。
    @Published var boardID: UUID?
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
    var staged = false

    /// 本标签是不是窗口里**正显示着**的那个（由 `TabsModel` 维护）。
    /// 🔴 `load()` 只在自己是活动标签时才 `app.setActive` —— 否则冷启动恢复一组标签时，
    /// 每装载一个后台标签就把平板抢过去一次，最后平板跟着的是恢复顺序里的最后一篇而不是用户那篇。
    var isActive = false

    /// 标签栏上显示的标题：会话标题为空（空标签 / 路径失效）时退回库里的文档名，再退回「新标签页」。
    var tabTitle: String {
        if let ref = noteRef { return ref.title }
        if let b = session.board { return b.displayName }
        if let bid = boardID { return workspace.boards.first { $0.id == bid }?.displayName ?? L("Untitled Board") }
        if !session.title.isEmpty { return session.title }
        if let d = missingDoc { return d.title }
        if let id = docID, let d = workspace.document(id: id) { return d.title }
        return L("New Tab")
    }

    /// 什么都没装的空标签（PDF / Markdown / 画板都没有）：打开新内容时就地复用它。
    var isEmptyTab: Bool { docID == nil && noteRef == nil && boardID == nil }

    /// 侧栏 / 标签栏用的选中键（PDF 与 md 笔记在同一张表里列，得能区分）。
    var rowID: String? {
        if let ref = noteRef { return "md:" + ref.key }
        if let bid = boardID { return BoardNote.rowPrefix + bid.uuidString }
        return docID
    }

    /// 「同路径换内容」待确认：文件存在但 hash 与入库版本不符（用户原地覆盖了 PDF）。
    struct HashMismatch: Identifiable {
        let docId: String; let path: String; let newHash: String
        var id: String { docId }
    }

    private var lastProgressSave = Date.distantPast
    private var progressSaveTask: Task<Void, Never>?   // 节流窗内被丢变化的尾随补存
    private(set) var closed = false
    /// 本次装载完成时 `session.scrollAnchor` 的序号（进度排查用，见 `ProgressLog`）。
    /// 存进度时用的锚点若 **≤ 这个数**，说明它是**上一篇**留下来的——换文档时 `scrollAnchor`
    /// 没人清，而新文档的库里进度若正好是 p1 顶端（`load` 里那条 `page > 0 || frac > 0` 不成立）
    /// 就不会发新锚点。真出现就在日志里带「⚠️ 锚点早于本次装载」，一眼可辨。
    private var anchorSeqAtLoad = 0

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
            s.saveProgress(why: "翻页")   // 翻页即存，避免只靠节流/关窗丢进度
        }
        // 锚点走**回调**而不是 `@Published`（红线在 `DocSession.scrollAnchor` 上）：本机滚动每帧
        // 发一次，挂在 `objectWillChange` 上就是每帧把整扇窗标脏。这两件事都不刷新视图，所以
        // 同步调即可 —— `emitAnchor` 是**先赋值后回调**，此刻 `session.scrollAnchor` 已是新值，
        // 不存在 `on(...)` 当年非要 `receive(on:)` 才能绕开的那个「willSet 里读到旧值」问题。
        session.onAnchorChanged = { [weak self] _ in
            guard let self, !self.closed else { return }
            self.app.macScrolled(self.session)
            self.saveProgressThrottled(self.session.scrollAnchor, why: "滚动")
        }
        on(session.$readZoom) { s in
            // 缩放变化也存（含 restore 后手动缩放）
            s.saveProgressThrottled(s.session.scrollAnchor, why: "缩放")
        }
        on(session.$strokes) { s in
            s.persistInk()               // 笔画完成/擦除/框选移动时增量落库（liveStroke 变化不触发）
        }
        // 阅读区 settle 后报实化范围 → 装缺的页、卸远的页（`InkWindow`）。不是 @Published，一次 settle 一发。
        session.inkWindowRequests
            .receive(on: DispatchQueue.main)
            .sink { [weak self] range in
                MainActor.assumeIsolated {
                    guard let self, !self.closed else { return }
                    self.ensureInkWindow(realized: range)
                }
            }
            .store(in: &bag)
        // 平板要对某页动手（擦除/框选/粘贴）而那页还没装：同步补读那一页。
        session.inkEnsureLoaded = { [weak self] page in
            guard let self, !self.closed else { return }
            self.ensureInkPageLoaded(page)
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
        on(session.$imageNotes) { s in
            s.persistImageNotes()        // 图片笔记新建/编辑/删除时增量落库（不上线：平板本轮不认识 kind=6）
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
        on(session.$boardImages) { s in
            s.persistBoardImages()       // 画板上加图 / 挪图 / 删图时增量落库
            s.app.broadcastBoardImages()
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
        session.openTrace?.finish("中断：关闭")
        session.openTrace = nil
        progressSaveTask?.cancel()
        progressSaveTask = nil
        scanAlignCancel?.set()   // 在测的扫描页对齐停掉（工作线程各开着一份 PDF，不停就吊着文件）
        bag.removeAll()          // 先断订阅，避免下面这几步自己又触发一轮
        flushPersist()
        saveProgress(why: "关闭标签")
        workspace.closeWindow(session.id)
        WorkspaceRegistry.shared.noteWindow(session.id, path: nil)
        app.unregister(session)
        session.teardown()       // 放掉本标签持有的 PDF / 库引用（不然移动硬盘弹不出去）
    }

    /// 把可能还排在异步队列里的落库同步补齐（见 `close()` 的红线）。全部幂等。
    func flushPersist() {
        persistInk()
        persistInkLayers()
        persistTextNotes()
        persistHighlights()
        persistImageNotes()
        persistBookmarks()
        persistAIThreads()
        persistScratchPads()
        persistScratchStrokes()
        persistBoardImages()
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
        session.workspaceBoards = workspace.boards
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
        guard id != docID || noteRef != nil || boardID != nil else { return }
        noteRef = nil       // PDF 与 md 笔记互斥
        leaveBoard()        // 与画板也互斥（先结清画板的落库再清状态）
        // 打开耗时账本从这一刻起算（用户点下去 = 这里）。上一本还没齐的按中断结账。
        session.openTrace?.finish("中断：换文档")
        session.openTrace = id.map { OpenTrace(title: workspace.document(id: $0)?.title ?? $0, reason: "打开") }
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
        saveProgress(documentId: old, why: "切走（换文档）")
        load(id)
        workspace.setWindowDoc(session.id, id)   // 更新工作区打开文档集
        // 换文档 = 标题/书库 open 标记/目录都变；平板发起的 openDoc 也在这里收尾（锁到新会话）。
        // 挂在这里而不是 load 内部：那个函数有三条早退路径（无文档/路径失效/正常），
        // 出口逐个补一遍迟早漏掉一条。
        session.openTrace.phase("会话变更广播") { app.sessionDocumentChanged(session) }
        if let trace = session.openTrace {
            trace.mark("select 返回")
            DispatchQueue.main.async { trace.mark("下一拍") }   // 本轮同步工作（含 SwiftUI 重建）都做完
        }
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
        // 切标签也开一本账（没有装载段，只有视图侧的里程碑）：「切回来要等多久才齐」正是用户报的那种慢。
        // `activate` 同一轮里先 `realize()` 开的「打开」账（视图还没上过一笔）沿用，别作废。
        if !(session.openTrace?.isFreshWithoutView ?? false) {
            session.openTrace?.finish("中断：再次切换")
            let trace = OpenTrace(title: tabTitle, reason: "切标签")
            session.openTrace = trace
            OpenStats.bind(trace, docKey: session.displayKey)
        }
        // 有快照就叫阅读区**在重建的首次求值里**用它种状态（一帧都不空；细节见 `ReaderSurface.init`）。
        // 下面那条 restore 锚点是兜底：窗口尺寸变过导致快照作废时，靠它把位置恢复回来（慢一拍但不丢）。
        session.readerSeedPending = (session.readerSnapshot != nil)
        ZoomProbe.mark("切到标签「\(tabTitle)」：待种=\(session.readerSeedPending)"
            + " 布局缓存=\(session.cachedLayout != nil)")
        session.restoreZoom = session.readZoom
        session.restoreHFrac = CGFloat(session.readHFrac)
        let a = session.scrollAnchor
        ProgressLog.log("切回标签 用锚点=\(a.map { "\($0.origin)#\($0.seq) \(ProgressLog.pos($0.page, $0.frac))" } ?? "无(用currentPageIndex p\(session.currentPageIndex + 1))") "
            + String(format: "zoom=%.3f hfrac=%.3f ", Double(session.readZoom), session.readHFrac)
            + "快照=\(session.readerSnapshot != nil) \(ProgressLog.doc(docID, session.title))")
        session.openTrace.phase("恢复锚点") {   // 含 `onAnchorChanged` → 平板 viewport 广播 + 进度节流存
            session.emitAnchor(page: a?.page ?? session.currentPageIndex,
                               frac: a?.frac ?? 0, origin: "restore")
        }
    }

    /// 开一篇 Markdown 笔记（v15）。
    ///
    /// 先把 PDF 那边收干净（`select(nil)`：结清落库 / 存进度 / 退出工作区打开集 / 放掉 PDF），
    /// 再记下要显示哪篇笔记。笔记本身不进工作区「打开集」——那一套是给 PDF 会话用的
    /// （平板广播等仍只认 PDF）；Markdown 标签由 `TabsModel` 的混合标签组单独持久化。
    func openMarkdown(_ ref: NoteRef) {
        guard noteRef != ref else { return }
        if docID != nil || boardID != nil { select(nil) }
        noteRef = ref
        staged = false
        workspace.noteWasOpened(ref)
    }

    /// 冷启动恢复 Markdown 标签：只恢复身份，不改「最近打开」时间。
    /// 编辑器由 `ReaderPaneController` 仅为活动标签创建，因此后台 Markdown 标签也没有额外布局成本。
    func stageMarkdown(_ ref: NoteRef) {
        guard docID == nil, noteRef != ref else { return }
        noteRef = ref
        staged = false
    }

    /// 这篇 md 笔记被删了 / 不在了 → 标签退回空态。
    func closeMarkdownIfGone() {
        guard let ref = noteRef, workspace.note(ref: ref) == nil else { return }
        noteRef = nil
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
        if staged, let bid = boardID { realizeBoard(bid); return }
        guard staged, let id = docID else { return }
        // `select` 按「id 没变就早退」设计，这里先把 `docID` 抹掉，让它把这次当成「从空态开一篇」。
        // 同一轮同步跑完，界面看不到中间那一下。
        docID = nil
        select(id)
    }

    private func load(_ id: String?) {
        session.clearSearch()   // 换文档：旧文档的查找命中/高亮不应带过去
        session.clearJumps()    // 跳转历史按文档分（`JumpHistory`）：换文档 = 换一条新轨迹
        session.currentSelection = nil   // MCP 的选区镜像也跟着清（阅读区的选区状态随后会自己清）
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
        session.scanAlign = nil                         // 扫描页对齐按内容记，下面拿到内容哈希后按库覆盖
        session.canvasMode = false                      // 画板模式逐文档记，同上按库覆盖
        guard let id, let doc = workspace.document(id: id) else {
            session.pdf = nil; missingDoc = nil; session.toc = []; session.title = ""
            clearInk(); clearInkLayers(); clearTextNotes(); clearHighlights(); clearBookmarks(); clearScratch()
            clearAIThreads(); clearImageNotes()
            session.reloadOCRState(); return
        }
        let trace = session.openTrace
        let target = workspace.openTarget(documentId: id)
        let opened = target.flatMap { t in trace.phase("开PDF") { PDFDocument(url: URL(fileURLWithPath: t.path)) } }
        guard let target, let pdf = opened else {
            trace?.finish(target == nil ? "中断：文件路径失效" : "中断：PDF 打不开")
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
            clearImageNotes()
            return
        }
        missingDoc = nil
        session.pdf = pdf
        session.title = doc.title
        session.contentHash = target.hash
        // 扫描页对齐（`SCAN-ALIGN-PLAN.md`）：**必须赶在一切出图 / 布局 / 平板广播之前**——它决定了「页面」长什么样
        session.scanAlign = workspace.scanAlign(contentHash: target.hash, pageCount: pdf.pageCount)
        if let trace { OpenStats.bind(trace, docKey: session.displayKey) }   // 从此视图层/笔迹层按 docKey 找得到账本
        session.toc = []
        buildTOC(documentId: id, path: target.path)   // 目录在后台建（账本记里程碑「目录到位」），先空着
        trace.phase("OCR") { session.reloadOCRState() }   // 换文档重置 OCR；该内容已有缓存则自动启用
        resetInk(documentId: id)                   // 笔迹归零；首窗在下面读到进度页之后装（读库+解码全在后台，账本记里程碑「笔迹到位」）
        trace.phase("图层", detail: "\(session.inkLayers.count)层") { loadInkLayers(documentId: id) }   // 恢复该文档的图层注册表（含自愈补建）
        session.noteTypes = workspace.noteTypes()  // 工作区笔记类型（通用内置兜底，不在列）
        session.noteTypeFilter = .all              // 筛选仅内存，开文档复位
        // 各段 detail 记条数：账本上「注解 154ms」这种数字没有条数就分不清是量大还是单价贵。
        trace.phase("注解", detail: "\(session.textNotes.count)条") { loadTextNotes(documentId: id) }    // 恢复该文档已落库的文字注解
        trace.phase("高亮", detail: "\(session.highlights.count)条") { loadHighlights(documentId: id) }   // 恢复该文档已落库的高亮
        trace.phase("图片", detail: "\(session.imageNotes.count)条") { loadImageNotes(documentId: id) }  // 恢复该文档已落库的图片笔记
        trace.phase("书签", detail: "\(session.bookmarks.count)条") { loadBookmarks(documentId: id) }    // 恢复该文档已落库的书签（与目录合并显示）
        trace.phase("AI", detail: "\(session.aiThreads.count)条") { loadAIThreads(documentId: id) }      // 恢复该文档已落库的 AI 会话绑定
        trace.phase("草稿纸", detail: "\(session.scratchPads.count)张") { loadScratch(documentId: id) }  // 恢复该文档的草稿纸（纸上笔迹后台读，默认不打开任何一张）
        // 恢复阅读进度：缩放倍率 + 定页 + 精确滚到页内比例（restore 锚点，阅读区会跟随）。
        let p = trace.phase("进度") { workspace.progress(documentId: id) }
        session.restoreZoom = CGFloat(p.zoom)      // 首帧定基准后由 PageStreamView 套用
        session.readZoom = CGFloat(p.zoom)
        session.restoreHFrac = CGFloat(p.hfrac)    // 横向滚动比例（缩放态/画板模式才非 0）
        session.readHFrac = p.hfrac
        session.canvasMode = p.canvas              // 画板模式（v12）
        let page = min(max(0, p.page), max(0, pdf.pageCount - 1))
        session.currentPageIndex = page
        ensureInkWindow(realized: page...page)     // 首窗：进度页 ± pad（阅读区首次 settle 再按真实实化范围补齐）
        lastProgressSave = .now                    // 避免恢复动作立刻又写一遍
        ProgressLog.log("恢复 库里=\(ProgressLog.pos(p.page, p.frac)) → 摆到=\(ProgressLog.pos(page, p.frac)) "
            + String(format: "zoom=%.3f hfrac=%.3f ", p.zoom, p.hfrac)
            + "共\(pdf.pageCount)页 "
            + "留着的旧锚点=\(session.scrollAnchor.map { "\($0.origin)#\($0.seq) \(ProgressLog.pos($0.page, $0.frac))" } ?? "无") "
            + ProgressLog.doc(id, doc.title))
        // 进度排查基线：**先取**上一篇留下的那条锚点的序号，此后发出来的（含下面这条 restore）
        // 才算「本篇的」；存进度时拿到的锚点序号 ≤ 它，就是上一篇的残留（见 `anchorSeqAtLoad`）。
        anchorSeqAtLoad = session.scrollAnchor?.seq ?? 0
        if page > 0 || p.frac > 0 {
            session.emitAnchor(page: page, frac: p.frac, origin: "restore")
        }
        // 只有活动标签才抢平板跟随（后台标签装载时不许动，见 `isActive` 注释）。
        trace.phase("平板广播") {
            if isActive { app.setActive(session) }
            app.sessionChanged(session)
            app.broadcastStrokes()   // 新文档的已存笔迹回传平板（平板本地不落库，靠 Mac 回显）
        }
        trace?.mark("装载完成", "\(pdf.pageCount)页 → p\(page + 1)")
        verifyContentHash(documentId: id, openedPath: target.path, storedHash: target.hash)
    }

    /// 目录在**后台**建（2026-09-10 账本：`目录 128~143ms`，是装载段里最大的项之一，全在遍历 PDF 大纲——
    /// 每个条目解 destination、取页对象）。另开一份 `PDFDocument` 专供遍历：主线程那份不能被并发碰
    /// （`PageRenderEngine` 的规矩），开一份只要几毫秒，建完即弃。回主线程按 documentId + contentHash 核对，
    /// 换了文档就丢弃；到位后补一次平板广播（`load()` 里那次广播出去的是空目录）。
    private func buildTOC(documentId id: String, path: String) {
        let hash = session.contentHash
        let align = session.scanAlign
        let t0 = CFAbsoluteTimeGetCurrent()
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let doc = PDFDocument(url: URL(fileURLWithPath: path)) else { return }
            let toc = TOCEntry.build(from: doc, align: align)
            let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000
            await MainActor.run { [weak self] in
                guard let self, !self.closed, self.session.documentId == id, self.session.contentHash == hash else { return }
                self.session.toc = toc
                self.app.broadcastTOC()
                var n = 0
                func count(_ es: [TOCEntry]) { for e in es { n += 1; count(e.children) } }
                count(toc)
                self.session.openTrace?.mark("目录到位", "\(n)项 后台 \(Int(ms.rounded()))ms")
            }
        }
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
        refreshScanAlignForCurrentContent()
        session.reloadOCRState()
    }

    /// 「文件已变化」→ 仍打开（不改库：本次按实际内容打开，下次打开仍会提示）。
    func openAnyway(_ m: HashMismatch) {
        session.contentHash = m.newHash
        refreshScanAlignForCurrentContent()
        session.reloadOCRState()
    }

    /// 内容哈希原地换了（文件被替换）→ 对齐参数按新内容重取。页面长相变了的话，布局缓存与屏幕快照一并作废
    /// （阅读区挂在 `.id(displayKey)` 上，键一变自己会重建，重建时不能再拿旧布局）。
    private func refreshScanAlignForCurrentContent() {
        let before = session.displayKey
        session.scanAlign = workspace.scanAlign(contentHash: session.contentHash, pageCount: session.pdf?.pageCount ?? 0)
        guard session.displayKey != before else { return }
        session.cachedLayout = nil
        session.readerSnapshot = nil
        session.readerSeedPending = false
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

    // MARK: - 扫描页对齐（`SCAN-ALIGN-PLAN.md`）

    /// 切换前的确认（非 nil = 阅读区弹窗）。
    struct ScanAlignConfirm: Identifiable {
        let id = UUID()
        let turnOn: Bool
        /// 挂在页面坐标上的批注条数（切换后不跟着动，会偏）。
        let notes: Int
        /// 已识别的 OCR 页数（切换时清掉）。
        let ocrPages: Int
        /// 打开且还没测过：要先测全书。
        let needsMeasure: Bool
    }
    @Published var scanAlignConfirm: ScanAlignConfirm?

    /// 测量进度（nil = 没在测）。阅读区顶部的提示读它。
    struct ScanAlignProgress: Equatable { var done: Int; var total: Int }
    @Published var scanAlignProgress: ScanAlignProgress?
    private var scanAlignCancel: ScanAlignCancelFlag?

    var isScanAlignOn: Bool { session.scanAlign != nil }

    /// 菜单「对齐扫描页」。有批注或 OCR 结果会受影响时先弹窗确认（用户 2026-09-17 定：不换算、提示条数），否则直接切。
    func toggleScanAlign() {
        guard session.pdf != nil, let id = docID, !session.contentHash.isEmpty, scanAlignProgress == nil else { return }
        let turnOn = !isScanAlignOn
        let impact = workspace.scanAlignImpact(documentId: id, contentHash: session.contentHash)
        let c = ScanAlignConfirm(turnOn: turnOn, notes: impact.notes, ocrPages: impact.ocrPages,
                                 needsMeasure: turnOn && !workspace.hasScanAlignParams(
                                    contentHash: session.contentHash, pageCount: session.pdf?.pageCount ?? 0))
        if c.notes == 0 && c.ocrPages == 0 { applyScanAlign(c) } else { scanAlignConfirm = c }
    }

    /// 确认后真正切换：关 = 只改开关；开 = 测过就只改开关，没测过先在后台测全书、落库。
    /// 两条路最后都是「清这份内容的 OCR → 存进度 → 整篇重载」——页面长相变了，布局 / 页图 / 平板广播全得按新的来，
    /// 重载是现成的、验熟了的那条路（重定位也走它），别在这里一件件手动刷新。
    func applyScanAlign(_ c: ScanAlignConfirm) {
        scanAlignConfirm = nil
        guard let pdf = session.pdf, let id = docID, !session.contentHash.isEmpty, scanAlignProgress == nil else { return }
        let hash = session.contentHash, n = pdf.pageCount
        guard c.turnOn else {
            workspace.setScanAlignEnabled(contentHash: hash, on: false)
            finishScanAlignSwitch(hash)
            return
        }
        if workspace.hasScanAlignParams(contentHash: hash, pageCount: n) {
            workspace.setScanAlignEnabled(contentHash: hash, on: true)
            finishScanAlignSwitch(hash)
            return
        }
        guard let url = pdf.documentURL else { return }
        let flag = ScanAlignCancelFlag()
        scanAlignCancel = flag
        scanAlignProgress = ScanAlignProgress(done: 0, total: n)
        let step = max(1, n / 60)   // 进度最多报 60 次：每次都是一次 @Published → 阅读区那一层重算
        let t0 = CFAbsoluteTimeGetCurrent()
        Task.detached(priority: .userInitiated) { [weak self] in
            let ms = ScanAlignRunner.measure(url: url, pageCount: n, isCancelled: { flag.isSet }) { done in
                guard done % step == 0 || done == n else { return }
                DispatchQueue.main.async { [weak self] in
                    guard let self, !flag.isSet, self.scanAlignProgress != nil else { return }
                    self.scanAlignProgress = ScanAlignProgress(done: done, total: n)
                }
            }
            let table = ms.map { ScanAlignSolver.solve($0) }
            let secs = CFAbsoluteTimeGetCurrent() - t0
            await MainActor.run { [weak self] in
                guard let self else { return }
                if self.scanAlignCancel === flag { self.scanAlignCancel = nil; self.scanAlignProgress = nil }
                guard let table, !flag.isSet, !self.closed, self.docID == id, self.session.contentHash == hash else { return }
                wsLog(String(format: "扫描页对齐：测完 %d 页 %.1fs，戳 %@", n, secs, table.stamp))
                self.workspace.saveScanAlign(contentHash: hash, table: table)
                self.finishScanAlignSwitch(hash)
            }
        }
    }

    private func finishScanAlignSwitch(_ hash: String) {
        workspace.deleteOCR(contentHash: hash)   // 行框按切换前的页面存的，留着就错位（方案 §1）
        // 参考索引平时只在书库变了才重建（`syncWorkspaceSnapshot`），开关不算书库变化——手动刷一次，
        // 否则平板参考窗看这本书时还按切换前的页面出图
        session.libraryRefIndex = workspace.refDocIndex()
        saveProgress(why: "扫描页对齐切换")        // 重载按库里的进度恢复位置
        reload()
    }

    // MARK: - 阅读进度

    private func saveProgressThrottled(_ a: ScrollAnchor?, why: String = "节流") {
        guard docID != nil else { return }
        let now = Date.now
        let elapsed = now.timeIntervalSince(lastProgressSave)
        if elapsed > 0.7 {
            lastProgressSave = now
            progressSaveTask?.cancel()
            progressSaveTask = nil
            saveProgress(anchor: a, why: why)
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
            self.saveProgress(why: "\(why)·尾随补存")
        }
    }

    /// 存**本标签当前文档**的进度。
    func saveProgress(anchor: ScrollAnchor? = nil, why: String = "未注明") {
        saveProgress(documentId: docID, anchor: anchor, why: why)
    }

    /// 存**指定文档**的进度。`documentId == nil` 就什么都不做。
    ///
    /// 🔴 **这里绝不能把 nil 兜底成「当前文档」**（2026-08-29 用户报「进度没有保存/恢复」的根因，
    /// 是第 1 步搬家时把原来的 `guard let docId else { return }` 误改成 `docId ?? docID` 埋下的）：
    /// `select()` 会用「切走前的旧文档 id」调它，而窗口第一次开文档时那个 id 是 **nil**——
    /// 兜底成当前文档的话，就会在 `load()` **读取进度之前**，先拿空会话的状态（第 0 页、缩放 1）
    /// 把这篇文档存着的进度覆盖掉。表现就是每次打开文档都自毁一次进度，从来回不到上次的位置。
    private func saveProgress(documentId: String?, anchor: ScrollAnchor? = nil, why: String = "未注明") {
        guard let id = documentId else {
            ProgressLog.log("跳过（没有 documentId）why=\(why) 本标签=\(ProgressLog.doc(docID, session.title))")
            return
        }
        // 🔴 **还没装载过的标签没有「当前位置」**：此刻 `session` 还是空的（第 0 页、缩放 1），
        // 存下去就是把库里那篇真正的进度抹成开头。这是懒装载引进来的头号陷阱——关窗（`close`）
        // 与切走（`select` 存旧文档）两条路都会打到这里，所以守卫放在这个最里层的出口。
        guard !staged else {
            ProgressLog.log("跳过（标签还没装载）why=\(why) \(ProgressLog.doc(id, session.title))")
            return
        }
        let a = anchor ?? session.scrollAnchor
        let page = a?.page ?? session.currentPageIndex
        let frac = a?.frac ?? 0
        if ProgressLog.enabled {
            // 🔴 锚点比本次装载还旧 = 它是上一篇留下来的（换文档时没人清 `scrollAnchor`）。
            let stale = (a?.seq ?? 0) <= anchorSeqAtLoad && anchorSeqAtLoad > 0
            ProgressLog.log("存 \(ProgressLog.pos(page, frac)) "
                + String(format: "zoom=%.3f hfrac=%.3f ", Double(session.readZoom), session.readHFrac)
                + "why=\(why) 锚点=\(a.map { "\($0.origin)#\($0.seq)" } ?? "无(用currentPageIndex)") "
                + "装载基线#\(anchorSeqAtLoad) \(stale ? "⚠️锚点早于本次装载 " : "")"
                + "活动=\(isActive) 窗口=\(String(session.id.uuidString.prefix(4))) "
                + ProgressLog.doc(id, session.title))
        }
        workspace.saveProgress(documentId: id, page: page, frac: frac,
                               zoom: Double(session.readZoom), hfrac: session.readHFrac)
    }

    // MARK: - 手写笔迹持久化（note kind=2）

    /// 加载文档时清空内存笔迹与对账集（无文档 / 路径失效时用）。
    private func clearInk() {
        session.documentId = nil
        resetInkState()
    }

    /// 换文档：笔迹归零。**不在这里读库**——第一批窗口由 `load()` 读到进度页之后 `ensureInkWindow` 装
    /// （`INK-PAGING-PLAN.md §4.2`：首窗 = 进度页 ± pad，不必等首帧）。
    private func resetInk(documentId id: String) {
        session.documentId = id
        resetInkState()
    }

    private func resetInkState() {
        session.strokes = []
        session.liveStroke = nil
        session.persistedStrokes = [:]
        session.inkLoadGeneration += 1   // 在途的后台读库/解码作废
        session.inkLoading = false
        session.inkLoadedPages = []
        session.inkLoadingPages = []
        session.inkOverflowSeed = 0
    }

    /// 笔迹**按页窗口**装载与淘汰（`InkWindow`，`INK-PAGING-PLAN.md §4`）。阅读区每次 settle 报一次实化范围
    /// （`session.inkWindowRequests`），开文档由 `load()` 用进度页调第一次：
    /// - 装：`realized ± pad` 里还没有的页，**后台**读库（`LibraryStore.inkRows(pages:)`，走页索引）+ 并行解码，
    ///   回主线程按 `inkLoadGeneration` 核对后并入（`InkWindow.merge`：期间新画的排在库批后面）；
    /// - 卸：`realized ± keep` 之外、撤销栈没钉住、且已全部落库的页，同步摘掉，一次 `strokes` 赋值。
    /// 🔴 **读库 + 解码都在后台**（2026-09-10 用户定：「先展示窗口和 PDF 内容，笔迹异步处理好后再显示」）：
    /// `SQLiteDB` 一条语句一把锁，后台线程用主线程那条连接是既有做法（离线镜像早就这么干）。
    /// 主线程只剩置位；账本记里程碑 `笔迹到位`（读库 / 解码各记各的毫秒）。
    func ensureInkWindow(realized: ClosedRange<Int>) {
        guard let id = session.documentId, let pageCount = session.pdf?.pageCount, pageCount > 0,
              let store = workspace.store else { return }
        evictInk(outside: InkWindow.keepRange(realized: realized, pageCount: pageCount))
        let want = InkWindow.want(realized: realized, pageCount: pageCount)
        let segments = InkWindow.missing(want: want, loaded: session.inkLoadedPages, inFlight: session.inkLoadingPages)
        guard !segments.isEmpty else { return }
        let pages = Set(segments.flatMap { Array($0) })
        session.inkLoadingPages.formUnion(pages)
        session.inkLoading = true
        session.openTrace?.inkPending = true
        let gen = session.inkLoadGeneration
        let firstBatch = session.inkLoadedPages.isEmpty   // 第一批顺便把全篇页边溢出首值算出来
        let t0 = CFAbsoluteTimeGetCurrent()
        Task.detached(priority: .userInitiated) { [weak self] in
            var rows: [LibInkRow] = []
            for seg in segments {   // 段按页升序，拼起来仍是「页 → 落库时间」序 = 绘制叠放序
                rows += (try? store.inkRows(documentId: id, kind: InkStroke.noteKind, pages: seg)) ?? []
            }
            let extent = firstBatch ? ((try? store.inkXExtent(documentId: id)) ?? nil) : nil
            let t1 = CFAbsoluteTimeGetCurrent()
            let loaded = InkStroke.decodeAll(rows)
            let t2 = CFAbsoluteTimeGetCurrent()
            await MainActor.run { [weak self] in
                guard let self, !self.closed,
                      self.session.inkLoadGeneration == gen, self.session.documentId == id else { return }
                self.session.inkLoadingPages.subtract(pages)
                if let extent {
                    self.session.inkOverflowSeed = max(self.session.inkOverflowSeed, 0, -extent.minX, extent.maxX - 1)
                }
                self.applyInkBatch(loaded, pages: pages, documentId: id,
                                   detail: "p\(want.lowerBound + 1)–\(want.upperBound + 1) 后台读库 \(Int(((t1 - t0) * 1000).rounded()))ms + 解码 \(Int(((t2 - t1) * 1000).rounded()))ms")
            }
        }
    }

    /// 一批页读完 → 并入内存、入对账集、补建缺失图层、回传平板。
    /// 一笔没有也走到这里（`inkLoading` 要在这儿归零、账本才放行），只是不必再向平板推一遍。
    private func applyInkBatch(_ loaded: [InkStroke], pages: Set<Int>, documentId id: String, detail: String) {
        let (merged, added) = InkWindow.merge(existing: session.strokes, loaded: loaded, pages: pages)
        for s in added { session.persistedStrokes[s.id] = s }   // 库里读来的 = 已落库；对账别把它们当新增再写一遍
        session.inkLoadedPages.formUnion(pages)
        session.inkLoading = !session.inkLoadingPages.isEmpty
        session.strokes = merged                 // 空对空也照样赋值：@Published 触发下一次 body，账本在那里放行
        ensureInkLayers(documentId: id)   // 自愈：这批笔迹引用了不存在的图层就补建（孤儿层随滚动逐步补齐）
        if !added.isEmpty { app.broadcastStrokes() }   // 平板那份是「Mac 当前窗口」（PROTOCOL.md §4.2），窗口长了就整替一次
        // 账本的 `inkPending` 由阅读区下一次 body 求值放行（那时各页笔数才是新的，见 `traceOpenFrame`）。
        session.openTrace?.mark("笔迹到位", "\(added.count)笔 \(detail)")
    }

    /// 淘汰保留区间之外、没被撤销栈钉住（`InkUndoStack.referencedPages`）、且已全部落库的页。
    /// `strokes` 与 `persistedStrokes` **在同一同步块里**一起改：紧随其后的 `persistInk` 才不会把它们
    /// 当成「已擦除」去删库。
    private func evictInk(outside keep: ClosedRange<Int>) {
        var pages = InkWindow.evictable(loaded: session.inkLoadedPages, keep: keep,
                                        pinned: session.inkUndo.referencedPages)
        guard !pages.isEmpty else { return }
        pages = pages.filter { InkWindow.fullyPersisted(page: $0, strokes: session.strokes, persisted: session.persistedStrokes) }
        guard !pages.isEmpty else { return }
        let (kept, removed) = InkWindow.evict(from: session.strokes, pages: pages)
        for sid in removed { session.persistedStrokes.removeValue(forKey: sid) }
        session.inkLoadedPages.subtract(pages)
        session.strokes = kept
    }

    /// 「这一页现在就要在内存里」（平板对某页擦除/框选/粘贴前、检查器删整页前）：不在窗口里就**同步**
    /// 读这一页——十几行、几毫秒。后台若恰好也在读它，回来时 `InkWindow.merge` 按 id 去重，等价。
    private func ensureInkPageLoaded(_ page: Int) {
        guard let id = session.documentId, let store = workspace.store,
              !session.inkLoadedPages.contains(page) else { return }
        let rows = (try? store.inkRows(documentId: id, kind: InkStroke.noteKind, pages: page...page)) ?? []
        session.inkLoadingPages.remove(page)
        applyInkBatch(rows.compactMap(InkStroke.init(row:)), pages: [page], documentId: id, detail: "p\(page + 1) 同步补读")
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
        let loaded = workspace.inkLayers(documentId: id).sorted { $0.sortOrder < $1.sortOrder }
        session.persistedInkLayers = Dictionary(uniqueKeysWithValues: loaded.map { ($0.id, $0) })
        session.inkLayers = loaded
        session.activeLayerID = loaded.first?.id
        ensureInkLayers(documentId: id)
    }

    /// 图层自愈：笔迹引用了不存在的图层 → 逐个补建并落库；一层都没有 → 建默认层。
    /// 两处调：`loadInkLayers`（此时笔迹多半还在后台解码，只兜得住「一层都没有」）与
    /// `applyLoadedInk`（笔迹到齐，缺失引用这时才看得见）。幂等：没缺的什么都不做。
    private func ensureInkLayers(documentId id: String) {
        var layers = session.inkLayers
        let knownIDs = Set(layers.map(\.id))
        var missing = Set(session.strokes.map(\.layerId)).subtracting(knownIDs)
        if layers.isEmpty { missing.insert(InkLayer.defaultID) }   // 全新/老文档兜底建第一层
        guard !missing.isEmpty else { return }
        var nextOrder = (layers.map(\.sortOrder).max() ?? -1) + 1
        for missingID in missing.sorted(by: { $0.uuidString < $1.uuidString }) {
            let name = String(format: L("Layer %d"), nextOrder + 1)
            let layer = InkLayer(id: missingID, name: name,
                                 colorKey: InkLayer.rotatingColorKey(existingCount: layers.count),
                                 sortOrder: nextOrder, visible: true)
            layers.append(layer)
            workspace.saveInkLayer(documentId: id, layer)
            nextOrder += 1
        }
        layers.sort { $0.sortOrder < $1.sortOrder }
        session.persistedInkLayers = Dictionary(uniqueKeysWithValues: layers.map { ($0.id, $0) })
        session.inkLayers = layers
        if session.activeLayerID == nil { session.activeLayerID = layers.first?.id }
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

    // MARK: - 图片笔记持久化（note kind=6，`IMAGE-NOTE-PLAN.md`）

    /// 清空内存图片笔记与对账集（对账集先于列表赋值，同 loadTextNotes 防切档误删）。
    private func clearImageNotes() {
        session.persistedImageNotes = [:]
        session.imageNotes = []
    }

    private func loadImageNotes(documentId id: String) {
        let loaded = workspace.imageNotes(documentId: id)
        session.persistedImageNotes = Dictionary(uniqueKeysWithValues: loaded.map { ($0.id, $0) })
        session.imageNotes = loaded
    }

    /// 内存图片笔记 ↔ 库对账：新增/改说明/改展开方式/挪位 upsert；已无的 delete。
    /// 删那条时把它指向的 sha 一并交给 `deleteImageNote` —— 最后一条引用没了，那张图当场进待删除。
    private func persistImageNotes() {
        guard let id = session.documentId else { return }
        let current = session.imageNotes
        let currentIDs = Set(current.map(\.id))
        for n in current where session.persistedImageNotes[n.id] != n {
            workspace.saveImageNote(documentId: id, n)
        }
        for (goneID, old) in session.persistedImageNotes where !currentIDs.contains(goneID) {
            workspace.deleteImageNote(id: goneID, image: old.image)
        }
        session.persistedImageNotes = Dictionary(uniqueKeysWithValues: current.map { ($0.id, $0) })
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
    func clearScratch() {
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
        session.persistedScratchPads = Dictionary(uniqueKeysWithValues: pads.map { ($0.id, $0) })
        session.persistedScratchStrokes = [:]
        session.scratchPads = pads
        session.scratchStrokes = []
        // 纸上笔迹（kind=4）在后台读 + 解码（账本 `草稿纸 29ms` 全是它）：同页内笔迹一个套路——
        // 代次核对、期间新画的排在库批之后、库批入对账集。开文档时纸默认不开，几乎不会撞上。
        guard let store = workspace.store else { return }
        let gen = session.inkLoadGeneration
        let t0 = CFAbsoluteTimeGetCurrent()
        Task.detached(priority: .userInitiated) { [weak self] in
            let rows = (try? store.inkRows(documentId: id, kind: InkStroke.scratchNoteKind)) ?? []
            let loaded = InkStroke.decodeAll(rows)
            let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000
            await MainActor.run { [weak self] in
                guard let self, !self.closed,
                      self.session.inkLoadGeneration == gen, self.session.documentId == id else { return }
                let existing = self.session.scratchStrokes
                let existingIDs = Set(existing.map(\.id))
                let added = loaded.filter { !existingIDs.contains($0.id) }
                for s in added { self.session.persistedScratchStrokes[s.id] = s }
                if !added.isEmpty { self.session.scratchStrokes = added + existing }   // @Published → 对账 + 平板广播
                self.session.openTrace?.mark("草稿纸笔迹到位", "\(added.count)笔 后台 \(Int(ms.rounded()))ms")
            }
        }
    }

    /// 内存草稿纸 ↔ 库对账：新增/改名/改底色 upsert；已删除的 delete（纸上笔迹由下面那个函数
    /// 一并对账掉——删纸时调用方要同时把它的笔迹从 `scratchStrokes` 里摘掉）。
    private func persistScratchPads() {
        if session.isBoard { persistBoardRow(); return }   // 画板：那张「纸」就是画板本身
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
        if session.isBoard { persistBoardStrokes(); return }   // 画板：写 board_item kind=1
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
