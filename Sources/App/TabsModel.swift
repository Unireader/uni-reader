import AppKit
import Combine
import Foundation

/// **一扇窗口的标签页集合**（方案见 `MAC-TABS-PLAN.md`）。
///
/// 核心原则：**一个标签 = 从前的一个窗口**。全项目的跨模块记账（`AppModel.sessions`、平板 `docs`、
/// 工作区「打开集」`WorkspaceManager.windowDocs`、`WorkspaceRegistry.windowPaths`）本来就按
/// `DocSession.id` 走，所以标签化之后它们**一行不用改**，平板协议**一个字节不改**——
/// 只是条目从「每窗一个」变成「每标签一个」。
///
/// 🔴 **不变式：`tabs` 永远至少有一个**。这样 `active` 是非可选的，`ContentView` 只需把从前的
/// 2026-11-28 起一个标签 = 一扇窗口（系统窗口标签，`NATIVE-TABS-PLAN.md`），本对象恒为一个标签、`tabs` 只剩一个元素。
/// 以下是自建底部标签栏时期的说明：`tab` 换成 `tabs.active`，其余部分几乎不动。「关掉最后一个标签」不存在——标签栏在只有一个标签时
/// 根本不显示（用户 2026-08-29 定），唯一的入口 ⌘W 在只剩一个时关的是窗口（同 Safari）。
/// 「空窗口」表现为「一个没装文档的标签」，即从前的空态。
///
/// 🔴 **工作区仍是窗口级**：切工作区 = 换窗口（`RootView` 的既有纪律），标签不跨工作区
/// ——那要同时挂多份库连接，与「同一个库只许一个连接」的红线顶着来（同安卓端 §13 的拍板）。
@MainActor
final class TabsModel: ObservableObject {
    /// 窗口身份。窗口级的东西按它分而不按标签分，最要紧的是内置 AI 面板那一份网页
    /// （理由见 `DocSession.windowID`）。
    let windowID = UUID()

    @Published private(set) var tabs: [DocTabModel] = []
    @Published private(set) var activeID = UUID()

    /// 当前显示的标签。靠上面的不变式，这里永远取得到。
    var active: DocTabModel { tabs.first { $0.id == activeID } ?? tabs[0] }

    private let app: AppModel
    let workspace: WorkspaceManager
    /// 工具栏「返回」/ ⌘[ ⌘] 的跨标签历史（`TabsModel+Navigation.swift`，2026-11-13）。
    /// 一个标签 = 一扇窗口之后，历史放在工作区上、同组标签共用（`WorkspaceManager.tabNav`）。
    var navHistory: NavHistory<NavPlace> {
        get { workspace.tabNav.history }
        set { workspace.tabNav.history = newValue }
    }
    /// 正在按历史回到某处：这一路上的切标签 / 跳页不再记历史（同组共用）。
    var isNavigatingHistory: Bool {
        get { workspace.tabNav.isNavigating }
        set { workspace.tabNav.isNavigating = newValue }
    }
    /// 这一轮刚到一处（见 `noteArrival`）。
    var arrivingThisTurn = false
    /// 只订阅**活动标签**的变更并转发（`ContentView` 观察 `tabs` 即等价于观察当前会话）。
    /// 不转发后台标签：它们的落笔/落库与界面无关，转发只会让整窗视图树白重算。
    private var activeBag = Set<AnyCancellable>()
    private var bag = Set<AnyCancellable>()
    private var closed = false
    /// 本窗口的 NSWindow（`WindowAccessor` 拿到就交过来）。**新建标签时要立刻替它登记**——
    /// 各处按会话 id 反查窗口（AI 浮窗吸附、⌘W 兜底关窗、「双击已打开的工作区 → 激活那扇窗」），
    /// 只在 `onWindow` 那一下登记的话，之后新开的标签一律查不到。
    ///
    /// 🔴 **必须是 `weak`**（2026-09-10 实测定位，「关掉全部工作区内存仍 1GB」的根因）：
    /// NSWindow → contentViewController → 三个 `NSHostingController` → 根视图 `ReaderPane(tabs:)`
    /// 强持有本对象，这里再强持有窗口就是一个环。窗口关了、controller 也放手了，整扇窗的对象图
    /// （NSWindow / 分栏 / 116 个 hosting 视图 / 阅读区 `@State` 里的页图字典 / 会话 / PDF 文档）
    /// 一个都不释放——`heap` 数出 4 扇早已关闭的窗口原封不动地活着。
    private weak var window: NSWindow?

    /// 关窗后整扇窗的对象图是否真的释放了，看这一行有没有来（`touch ~/Library/Logs/UniReader-ws.log`）。
    deinit { wsLog("TabsModel 释放（窗口对象图已回收）") }

    init(app: AppModel, workspace: WorkspaceManager) {
        self.app = app
        self.workspace = workspace
        let first = DocTabModel(app: app, workspace: workspace, windowID: windowID)
        first.isActive = true
        tabs = [first]
        adoptForNavigation(first)
        activeID = first.id
        bindActive()
        bindPadPin()
    }

    /// 平板可以把跟随**钉**到任意一个会话上（`padSelectedSessionID`），包括本窗口某个还没装载的
    /// 后台标签——那时推给平板的是一份空会话（没有 PDF、没有笔迹），平板上就是一片空白。
    /// 所以钉过来就把那个标签装出来；装完 `load()` 末尾的 `sessionDocumentChanged` 会再推一次。
    private func bindPadPin() {
        app.$padSelectedSessionID
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] sid in
                MainActor.assumeIsolated {
                    guard let self, let sid, let t = self.tabs.first(where: { $0.id == sid }) else { return }
                    t.realize()
                }
            }
            .store(in: &bag)
    }

    /// 转发活动标签的变更。切标签时要重订一次——`DocTabModel` 又转发着它自己会话的变更，
    /// 于是链路是 会话 → 标签 → 本对象 → `ContentView`，与从前 `@StateObject var session` 等价。
    private func bindActive() {
        activeBag.removeAll()
        active.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &activeBag)
    }

    // MARK: - 打开 / 切换 / 关闭

    /// 打开一篇文档（侧栏点选、导入完成、平板 `openDoc` 都走这里）。
    /// 语义（用户 2026-08-29 定「同一个工作区打开都是走新的 tab」；2026-11-28 起标签 = 系统窗口标签，见 `place`）：
    ///  · 这个工作区已经有标签开着它 → **切过去**，不重复开；
    ///  · 当前标签还空着 → 就装进当前这个（否则浏览书库会永远拖着一个空标签）；
    ///  · 否则 → **新开一个标签**（一扇新窗口）并切过去。
    @discardableResult
    func open(_ docID: String?) -> DocTabModel {
        guard let docID else { active.select(nil); persist(); return active }
        return place(existing: { $0.docID == docID }, load: { $0.select(docID) })
    }

    /// 开一篇 Markdown 笔记（v15）。规矩与 `open(_:)` 一致。
    @discardableResult
    func openMarkdown(_ ref: NoteRef) -> DocTabModel {
        place(existing: { $0.noteRef == ref }, load: { $0.openMarkdown(ref) })
    }

    /// 开一篇画板笔记（v16，`BOARD-NOTE-PLAN.md §3.1`）。规矩同上（装载末尾自己会 `setActive`）。
    @discardableResult
    func openBoard(_ id: UUID) -> DocTabModel {
        place(existing: { $0.boardID == id }, load: { $0.openBoard(id) })
    }

    /// 开一组习题（v20，`EXERCISE-PLAN.md §4.1`）。走统一的「同目录共用一个标签」（`openShared`）：
    /// 习题整段算一个目录，设置里开着就都在一个标签里换；`newTab` = ⌘ 单击 / 右键单独开。
    @discardableResult
    func openExercises(_ scope: ExerciseScope, newTab: Bool = false) -> DocTabModel {
        openShared(.exercise, group: "", independent: newTab,
                   existing: { $0.exerciseScope == scope }, load: { $0.openExercises(scope) })
    }

    /// 「同一目录 / 分组下打开的占用同一个标签」（用户 2026-11-21 定，设置里按 PDF / 习题 / 笔记各一个开关，默认开）。
    /// 侧栏**单击**打开：
    ///  · 已经有标签开着它 → 切过去（`independent` 时顺带把那个共用标签转成独立的，别再被换掉）；
    ///  · 开着开关、且这个目录已有共用标签 → 在它里面换成这一项；
    ///  · 否则同 `open(_:)`：当前标签空着就就地开，再否则新开一个——开关开着时它成为这个目录的共用标签。
    /// ⌘ 单击 / 右键「在新标签页中打开」= `independent`：开出来的是独立标签。
    @discardableResult
    func openShared(_ kind: ShareKind, group: String, independent: Bool,
                    existing: (DocTabModel) -> Bool, load: (DocTabModel) -> Void) -> DocTabModel {
        let key = "\(kind.rawValue)|\(group)"
        let group = peers
        if let hit = group.first(where: { existing($0.active) }) {
            if independent { hit.active.shareKey = nil }
            hit.focusWindow()
            persist()
            return hit.active
        }
        let share = !independent && kind.isOn
        if share, let shared = group.first(where: { $0.active.shareKey == key }) {
            if shared === self { noteLeaving(); noteArrival() }   // 就在眼下这个标签里换内容
            load(shared.active)
            shared.focusWindow()
            persist()
            return shared.active
        }
        let t: DocTabModel
        if active.isEmptyTab {
            t = active
            load(t)
            noteArrival()
        } else {
            t = spawn(load)
        }
        t.shareKey = share ? key : nil
        persist()
        return t
    }

    /// 侧栏单击一本 PDF：同一个分组共用一个标签（`openShared`）。
    @discardableResult
    func openDocShared(_ docID: String, independent: Bool = false) -> DocTabModel {
        let group = workspace.document(id: docID)?.group ?? ""
        return openShared(.pdf, group: group, independent: independent,
                          existing: { $0.docID == docID }, load: { $0.select(docID) })
    }

    /// 侧栏单击一篇 Markdown 笔记：同一目录（源 + 所在文件夹）共用一个标签。
    @discardableResult
    func openMarkdownShared(_ ref: NoteRef, independent: Bool = false) -> DocTabModel {
        let dir = (ref.relPath as NSString).deletingLastPathComponent
        return openShared(.markdown, group: "\(ref.sourceID):\(dir)", independent: independent,
                          existing: { $0.noteRef == ref }, load: { $0.openMarkdown(ref) })
    }

    enum ShareKind: String {
        case pdf, exercise, markdown
        /// 设置开关的键（`@AppStorage` 同一把），默认开。
        var settingKey: String { "shareTab." + rawValue }
        var isOn: Bool { UserDefaults.standard.object(forKey: settingKey) as? Bool ?? true }
    }

    /// 打开日程（v26，`SCHEDULE-PLAN.md §4`）：一个工作区至多一个日程标签——开着就切过去（带上要去的地方），
    /// 当前标签空着就就地开，否则新开一个。
    @discardableResult
    func openSchedule(focus: ScheduleFocus? = nil) -> DocTabModel {
        if let hit = peers.first(where: { $0.active.showsSchedule }) {
            hit.active.openSchedule(focus: focus)
            hit.focusWindow()
            persist()
            return hit.active
        }
        return place(existing: { _ in false }, load: { $0.openSchedule(focus: focus) })
    }

    /// 打开一份网页（`WEB-DOC-PLAN.md §3`）：已经有标签开着它就切过去，当前标签空着就就地开，否则新开一个（同画板）。
    @discardableResult
    func openWebDoc(_ id: String) -> DocTabModel {
        place(existing: { $0.webDocID == id }, load: { $0.openWebDoc(id) })
    }

    // MARK: - 原生窗口标签（`NATIVE-TABS-PLAN.md §2`）
    //
    // 一个标签 = 一扇阅读窗口（系统窗口标签，同工作区同一组）；本对象只装一个 `DocTabModel`。
    // 「已开着就切过去」的查找范围是**这个工作区的全部阅读窗口**（`peers`），新开 = 在本窗口的标签组里加一扇窗口。

    /// 这个工作区全部阅读窗口的标签集合（含自己），按系统标签组的左右顺序（本窗口所在的组在前）。
    var peers: [TabsModel] { AppDelegate.shared?.tabPeers(of: self) ?? [self] }

    /// 本窗口的 NSWindow（标签组排序 / 选中用）。
    var nsWindow: NSWindow? { window }

    /// 把本窗口这个标签切到前面：系统标签组里选中它；App 在前台时顺带成为 key（平板跟随随之拉过来）。
    func focusWindow() {
        if let w = window {
            if let g = w.tabGroup, g.selectedWindow !== w { g.selectedWindow = w }
            // App 不在前台时也要设成 key：否则前台一切过来，系统把原来那扇 key 窗口重新选中，标签又切回去了
            //（用户 2026-11-28 报：点 `unireader://` 链接能打开但不切到那个标签）。不会抢前台。
            if !w.isKeyWindow { w.makeKeyAndOrderFront(nil) }
        }
        activate(active.id)
    }

    /// 三段式打开：组里已有标签显示着它 → 切过去；当前标签空着 → 就地装；否则新开一个标签（一扇新窗口）装。
    @discardableResult
    private func place(existing: (DocTabModel) -> Bool, load: (DocTabModel) -> Void) -> DocTabModel {
        if let hit = peers.first(where: { existing($0.active) }) {
            hit.focusWindow()
            return hit.active
        }
        if active.isEmptyTab {
            load(active)
            noteArrival()
            persist()
            return active
        }
        return spawn(load)
    }

    /// 在本窗口的标签组里新开一扇窗口，把内容装进它的那个标签并切过去。
    /// 开不出窗口（本窗口还没上屏等，按理不会）就退回在当前标签里换内容。
    @discardableResult
    func spawn(_ load: (DocTabModel) -> Void) -> DocTabModel {
        guard let c = AppDelegate.shared?.spawnTab(after: self, select: true) else {
            noteLeaving()
            load(active)
            noteArrival()
            persist()
            return active
        }
        let t = c.tabs.active
        load(t)
        c.syncSidebarSelectionNow()   // 新窗口已经露面：侧栏选中当场跟上，别等下一拍（否则那一行先不亮、再亮，看着像闪）
        c.tabs.noteArrival()
        c.tabs.focusWindow()
        c.tabs.persist()
        return t
    }

    /// 某篇文档（或它某一章）的习题标签：文档被删了 → 退回空态（标签 = 窗口，不替用户关掉它，同 `pruneMissingBoards`）。
    func pruneMissingExerciseScopes() {
        for t in tabs {
            guard let id = t.exerciseScope?.documentId, workspace.document(id: id) == nil else { continue }
            t.closeExercisesIfGone()
        }
        persist()
    }

    /// 一篇 md 笔记改名 / 挪了目录：开着它的标签跟过去，并把标签组存一下（不存的话冷启动恢复时按旧路径找不到，标签就丢了）。
    func noteMoved(from old: NoteRef, to new: NoteRef) {
        var changed = false
        for t in tabs where t.noteMoved(from: old, to: new) { changed = true }
        if changed { persist() }
    }

    /// 某本书的章节分级刚被移除（`EXERCISE-PLAN.md §14`）：开着它某一章的习题标签换成整本书那一级
    /// （书底下 / 错题本底下 / 收藏底下各对各的），不留一个空章节在那儿。
    func exerciseChaptersRemoved(documentId: String) {
        var changed = false
        for t in tabs {
            let to: ExerciseScope
            switch t.exerciseScope {
            case .chapter(documentId, _)?: to = .document(documentId)
            case .wrongChapter(documentId, _)?: to = .wrongDocument(documentId)
            case .starredChapter(documentId, _)?: to = .starredDocument(documentId)
            default: continue
            }
            t.openExercises(to)
            changed = true
        }
        if changed { persist() }
    }

    /// 习题分组刚改了名（`EXERCISE-PLAN.md §33`）：开着这个分组（或它底下某一节）的习题标签跟着换成新名字，
    /// 不然留着一个空的旧分组。
    func exerciseGroupRenamed(from old: String, to new: String) {
        let loose = ExerciseScope.looseId
        func moved(_ p: [String]) -> [String]? { p.first == old ? [new] + p.dropFirst() : nil }
        var changed = false
        for t in tabs {
            let to: ExerciseScope
            switch t.exerciseScope {
            case .chapter(loose, let p)?: guard let q = moved(p) else { continue }; to = .chapter(loose, q)
            case .wrongChapter(loose, let p)?: guard let q = moved(p) else { continue }; to = .wrongChapter(loose, q)
            case .starredChapter(loose, let p)?: guard let q = moved(p) else { continue }; to = .starredChapter(loose, q)
            default: continue
            }
            t.openExercises(to)
            changed = true
        }
        if changed { persist() }
    }

    /// 新建一篇画板笔记并打开（侧栏「＋」/ 菜单 / 平板 `boardAdd`）。
    @discardableResult
    func newBoard(spec: WorkspaceManager.BoardSpec = .infinite) -> DocTabModel? {
        guard let b = workspace.createBoard(spec: spec) else { return nil }
        return openBoard(b.id)
    }

    /// 画板被删掉 / 镜像合并掉 → 开着它的标签退回空态（同 `pruneMissing`）。
    func pruneMissingBoards() {
        let live = Set(workspace.boards.map(\.id))
        for t in tabs where t.boardID != nil && !live.contains(t.boardID!) {
            t.closeBoardIfGone()
        }
        persist()
    }


    func activate(_ id: UUID) {
        guard let next = tabs.first(where: { $0.id == id }) else { return }
        // 懒装载：切过去才真装。**必须在 `activeID != id` 判断之外**——冷启动恢复完那一组标签后
        // `activate` 点的常常就是当前这个（`tabs[0]`），走进去反而不装了，界面就是一片空白。
        next.realize()
        if activeID != id {
            noteLeaving()   // 工具栏「返回」的跨标签历史（要在换掉 activeID 之前取眼下这一处）
            noteArrival()
            // 阅读区马上要为这个标签整体重建，先把它「停在哪儿」翻译成待恢复值（见那个方法的红线）。
            next.prepareForReactivation()
            let trace = next.session.openTrace   // 打开耗时账本：切标签的同步段也记（用户报来回切要 150ms）
            trace.phase("切换登记") {
                activeID = id
                for t in tabs { t.isActive = (t.id == id) }
                bindActive()
                persist()
            }
            // 每次都调（不只是切换时）：窗口重新成为 key window 也要把平板跟随拉回本标签。
            trace.phase("平板同步") { app.setActive(active.session) }
            trace?.mark("activate 返回")
            // 下一轮 runloop：本轮同步工作（含 SwiftUI 重建两侧栏与阅读区的 body）都做完了才轮到它。
            if let trace { DispatchQueue.main.async { trace.mark("下一拍") } }
            return
        }
        // 每次都调（不只是切换时）：窗口重新成为 key window 也要把平板跟随拉回本标签。
        app.setActive(active.session)
    }

    /// 关窗：每个标签各自结清。**必须逐个调 `close()`**，否则后台标签的进度/打开集/工作区登记
    /// 全部留在原地（库连接就永远关不掉 → 移动硬盘弹不出去）。
    func closeWindow() {
        guard !closed else { return }
        closed = true
        // 关掉的标签不记成「离开的那一处」（同原来关标签不进历史）
        if workspace.tabNav.front === self { workspace.tabNav.front = nil }
        activeBag.removeAll()
        for t in tabs { t.close() }
    }

    // MARK: - 窗口级转发（原先 ContentView 对单个标签做的，现在对每个标签做一遍）

    func syncWorkspaceSnapshot() { for t in tabs { t.syncWorkspaceSnapshot() } }

    func noteWorkspacePath(_ path: String?) { for t in tabs { t.noteWorkspacePath(path) } }

    /// 每个标签的会话都登记到**同一扇** NSWindow：`WorkspaceRegistry.window(for:)`
    /// （AI 浮窗吸附、「双击已打开的工作区 → 激活那扇窗」）按会话 id 查，不登记就查不到。
    func noteWindowObject(_ window: NSWindow?) {
        self.window = window
        for t in tabs { WorkspaceRegistry.shared.noteWindowObject(t.session.id, window: window) }
    }

    /// 文档被删除/合并掉后从库里消失 → 开着它的标签退回空态（标签 = 窗口，不替用户关掉它）。
    func pruneMissing(_ docs: [LibDocument]) {
        let live = Set(docs.map(\.id))
        for t in tabs where t.docID != nil && !live.contains(t.docID!) {
            t.select(nil)
        }
        syncTitles(docs)
    }

    /// PDF 标签的书名跟着库走（侧栏改名，2026-11-02）：会话里的 `title` 是窗口标题、标签名与平板 `docs` 广播读的那份。
    /// 只碰 PDF 标签（画板 / 习题也借 `session.title` 放自己的名字）；文件找不到的标签显示 `missingDoc` 的名字，一并换。
    private func syncTitles(_ docs: [LibDocument]) {
        let byID = Dictionary(docs.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for t in tabs where t.noteRef == nil && t.boardID == nil && t.exerciseScope == nil {
            guard let id = t.docID, let d = byID[id] else { continue }
            if !t.session.title.isEmpty, t.session.title != d.title { t.session.title = d.title }
            if t.missingDoc?.id == id, t.missingDoc?.title != d.title { t.missingDoc = d }
        }
    }

    /// 这个会话是不是本窗口的某个标签（平板发来的请求带的是**会话 id**，可能指向后台标签）。
    func owns(_ sessionID: UUID) -> Bool { tabs.contains { $0.id == sessionID } }

    // MARK: - 标签组的持久化与恢复

    /// 存在 `UserDefaults`（按工作区路径分键），**不动 SQLite schema**：
    /// 库里的「打开集」`openDocs` 是 MRU 序、职责是「下次该恢复哪几篇 + 平板书库的 open 标记」，
    /// 而这里要的是**标签的左右顺序**与「当时停在哪一个」，两回事。
    /// 做法照搬安卓模式1 的标签页组（`SharedPreferences` 按工作区路径分键，只存开着哪几篇，
    /// 进度仍在库里）。
    private var storeKey: String? {
        workspace.folder.map { "tabs:" + $0.standardizedFileURL.path }
    }

    /// 标签组自己的稳定身份。PDF 与 Markdown 共用一张标签栏，但各自的真身份不同：
    /// PDF = 库文档 UUID；Markdown = `NoteRef`（源 id + 源内相对路径）。
    /// 加前缀后存成 property-list 字符串，既保留左右顺序，也不会把 Markdown 再误当成空标签。
    private enum StoredTab: Equatable {
        case pdf(String)
        case markdown(NoteRef)
        case board(UUID)
        case exercises(ExerciseScope)
        /// 日程（v26），一扇窗口至多一个。
        case schedule
        /// 网页（`WEB-DOC-PLAN.md`）。
        case web(String)

        static let separateExercisePrefix = "exs:"

        var key: String {
            switch self {
            case .pdf(let id): return "pdf:" + id
            case .markdown(let ref): return "md:" + ref.key
            case .board(let id): return BoardNote.rowPrefix + id.uuidString
            case .exercises(let scope): return scope.rowID
            case .schedule: return ScheduleFocus.rowID
            case .web(let id): return LibWebDoc.rowPrefix + id
            }
        }

        init?(key: String) {
            if key == ScheduleFocus.rowID {
                self = .schedule
            } else if key.hasPrefix(LibWebDoc.rowPrefix) {
                let id = String(key.dropFirst(LibWebDoc.rowPrefix.count))
                guard !id.isEmpty else { return nil }
                self = .web(id)
            } else if let scope = ExerciseScope(rowID: key) {
                self = .exercises(scope)
            } else if key.hasPrefix(Self.separateExercisePrefix),
                      let scope = ExerciseScope(key: String(key.dropFirst(Self.separateExercisePrefix.count))) {
                self = .exercises(scope)   // 旧版「单独开」的记录：现在一律按普通习题标签恢复
            } else if key.hasPrefix("pdf:") {
                let id = String(key.dropFirst(4))
                guard !id.isEmpty else { return nil }
                self = .pdf(id)
            } else if key.hasPrefix(BoardNote.rowPrefix),
                      let id = UUID(uuidString: String(key.dropFirst(BoardNote.rowPrefix.count))) {
                self = .board(id)
            } else if key.hasPrefix("md:"),
                      let ref = NoteRef(key: String(key.dropFirst(3))) {
                self = .markdown(ref)
            } else {
                return nil
            }
        }
    }

    private func storedTab(_ tab: DocTabModel) -> StoredTab? {
        if let ref = tab.noteRef { return .markdown(ref) }
        if let id = tab.boardID { return .board(id) }
        if let scope = tab.exerciseScope { return .exercises(scope) }
        if tab.showsSchedule { return .schedule }
        if let id = tab.webDocID { return .web(id) }
        if let id = tab.docID { return .pdf(id) }
        return nil
    }

    /// 这一项算哪一类、哪个目录的共用标签（与 `openDocShared` / `openMarkdownShared` / `openExercises` 同一口径）。
    private func shareSlot(_ item: StoredTab) -> (ShareKind, String)? {
        switch item {
        case .pdf(let id): return (.pdf, workspace.document(id: id)?.group ?? "")
        case .markdown(let ref): return (.markdown, "\(ref.sourceID):\((ref.relPath as NSString).deletingLastPathComponent)")
        case .exercises: return (.exercise, "")
        default: return nil
        }
    }

    private func isRestorable(_ item: StoredTab) -> Bool {
        switch item {
        case .pdf(let id): return workspace.document(id: id) != nil
        case .markdown(let ref): return workspace.note(ref: ref) != nil
        case .board(let id): return workspace.boards.contains { $0.id == id }
        case .exercises(let scope): return scope.documentId.map { workspace.document(id: $0) != nil } ?? true
        case .schedule: return true
        case .web(let id): return workspace.webDoc(id: id) != nil
        }
    }

    /// 关掉某工作区的最后一扇窗（不是退出 App）时调：写一条空的 v2 记录，下次打开这个工作区不再恢复文档
    /// （只有「退出时开着的窗口」在下次启动时原样恢复，见 `AppDelegate.restoreWindowsAtLaunch`）。
    static func clearSavedTabs(folder: URL) {
        UserDefaults.standard.set(["version": 2, "items": [String](), "docs": [String](), "active": ""],
                                  forKey: "tabs:" + folder.standardizedFileURL.path)
    }

    /// 存这个工作区的打开集：**整个工作区的标签**（全部阅读窗口，按系统标签组顺序），活动项 = 本组选中的那个。
    /// 退出过程中不写（逐扇结清时列表会越存越短，`NATIVE-TABS-PLAN.md §4`）；退出前由 `AppDelegate` 先存一次。
    func persist() {
        guard !AppDelegate.isTerminating, let k = storeKey else { return }
        let group = peers
        let selected = window?.tabGroup?.selectedWindow ?? window
        let current = group.first { $0.window != nil && $0.window === selected } ?? self
        let items = group.compactMap { storedTab($0.active) }
        UserDefaults.standard.set([
            "version": 2,
            "items": items.map(\.key),
            // 留着旧字段，降级到旧版本时至少还能恢复 PDF 标签。
            "docs": group.compactMap(\.active.docID),
            "active": storedTab(current.active)?.key ?? "",
            // 哪些标签是「同目录共用」的（`DocTabModel.shareKey`）：重启后还要是共用的，单击才继续在里面换
            "shared": group.filter { $0.active.shareKey != nil }.compactMap { storedTab($0.active) }.map(\.key),
        ], forKey: k)
    }

    /// 冷启动恢复本工作区上次开着的那组标签。**每个工作区只做一次**，由
    /// `WorkspaceRegistry.claimRestore` 把关（`ContentView.decideInitialContent`）。
    ///
    /// 上限 `max`：从前是「本窗口开第一篇 + 最多再开 4 扇窗口」，现在全在一扇窗口里，
    /// 同样要有个数，否则「最近打开」很长时冷启动要一口气装载十几篇 PDF。
    func restoreTabs(max: Int = 8) {
        // 存档里记的共用标签；老存档没有这个字段 → 退回按目录推（每个目录第一个标签算共用）
        let sharedKeys: Set<String>? = storeKey
            .flatMap { UserDefaults.standard.dictionary(forKey: $0)?["shared"] as? [String] }.map(Set.init)
        var savedTabs: [StoredTab]
        var wantActive: StoredTab?
        if let k = storeKey,
           let d = UserDefaults.standard.dictionary(forKey: k),
           (d["version"] as? Int) == 2 {
            // v2 记录在就以它为准，**空也算数**：关掉某工作区的最后一扇窗会写一条空记录（`clearSavedTabs`），
            // 下次打开它就是空窗口——不能再退回库里的「打开集」把文档又开回来（用户 2026-10-29 定：只做窗口恢复）。
            savedTabs = ((d["items"] as? [String]) ?? []).compactMap(StoredTab.init(key:))
            wantActive = (d["active"] as? String).flatMap(StoredTab.init(key:))
        } else if let k = storeKey,
                  let d = UserDefaults.standard.dictionary(forKey: k),
                  let saved = d["docs"] as? [String], !saved.isEmpty {
            // v1：只存 PDF id，active 也是裸 id。
            savedTabs = saved.map(StoredTab.pdf)
            wantActive = (d["active"] as? String).flatMap { $0.isEmpty ? nil : .pdf($0) }
        } else {
            // 没有标签序记录（首次升级）→ 退回库里的 PDF「打开集」。
            savedTabs = workspace.restoreDocIds.map(StoredTab.pdf)
            wantActive = savedTabs.first
        }
        savedTabs = savedTabs.filter(isRestorable)   // 已删掉 / 引用源已移除的内容不恢复
        guard !savedTabs.isEmpty else { return }
        let restoring = Array(savedTabs.prefix(max))
        wsLog("restoreTabs：\(savedTabs.count) 项 → 本窗口开 \(restoring.count) 个标签（PDF 只装活动项）")
        // PDF 一律 `stage`（只记 id 不装），最后由下面的 `activate` 把用户上次停在的那一个装出来。
        // 从前这里是逐个 `select`，等于冷启动就把每一篇的 PDF、目录、笔迹全读一遍——而窗口里
        // 只有一个标签看得见（2026-09-02 剖析：大书一篇 0.33s，冷盘上近 1s）。
        // Markdown 没有 PDF 装载成本，只把 `noteRef` 放进标签；编辑器仍只为活动标签创建。
        // 第一项装进本窗口；其余每项在本窗口的标签组里各开一扇窗口（下一拍：本窗口此刻还没上屏）。
        var sharedSeen = Set<String>()
        func apply(_ item: StoredTab, to target: DocTabModel) {
            switch item {
            case .pdf(let id): target.stage(id)
            case .markdown(let ref): target.stageMarkdown(ref)
            case .board(let id): target.stageBoard(id)
            case .exercises(let scope): target.openExercises(scope)
            case .schedule: target.openSchedule()   // 存下的组里至多一个（`openSchedule` 保证）
            case .web(let id): target.openWebDoc(id, recordOpen: false)
            }
            // 还原共用标记（设置里对应的开关关着就不标）；老存档没有记录 → 每个目录第一个算共用
            if let (kind, group) = shareSlot(item), kind.isOn {
                let key = "\(kind.rawValue)|\(group)"
                let wanted = sharedKeys.map { $0.contains(item.key) } ?? !sharedSeen.contains(key)
                if wanted { target.shareKey = key; sharedSeen.insert(key) }
            }
        }
        // 上次停在的那个装进本窗口、马上显示；它左边的各项插在它左边，右边的依次接在右边。
        // 其余标签只建壳（标题 + 记下要开哪篇），界面第一次被选中时才建（`NATIVE-TABS-PLAN.md §4`）。
        let ai = wantActive.flatMap { restoring.firstIndex(of: $0) } ?? 0
        apply(restoring[ai], to: active)
        activate(active.id)
        guard restoring.count > 1 else { persist(); return }
        DispatchQueue.main.async { [weak self] in   // 下一拍：本窗口此刻还没上屏
            guard let self else { return }
            for item in restoring[..<ai] {
                guard let c = AppDelegate.shared?.spawnTab(after: self, select: false, ordered: .below) else { break }
                apply(item, to: c.tabs.active)
            }
            var host = self
            for item in restoring[(ai + 1)...] {
                guard let c = AppDelegate.shared?.spawnTab(after: host, select: false) else { break }
                apply(item, to: c.tabs.active)
                host = c.tabs
            }
            self.persist()
        }
    }
}
