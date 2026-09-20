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
/// `tab` 换成 `tabs.active`，其余部分几乎不动。「关掉最后一个标签」不存在——标签栏在只有一个标签时
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
    private let workspace: WorkspaceManager
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
    /// 语义（用户 2026-08-29 定「同一个工作区打开都是走新的 tab」）：
    ///  · 已经有标签开着它 → **切过去**，不重复开；
    ///  · 当前标签还空着 → 就装进当前这个（否则浏览书库会永远拖着一个空标签）；
    ///  · 否则 → **新开一个标签**并切过去。
    @discardableResult
    func open(_ docID: String?) -> DocTabModel {
        guard let docID else { active.select(nil); persist(); return active }
        if let hit = tabs.first(where: { $0.docID == docID }) {
            activate(hit.id)
            return hit
        }
        if active.docID == nil {
            active.select(docID)
            persist()
            return active
        }
        let t = appendTab(docID: docID)
        activate(t.id)
        return t
    }

    /// 开一篇 Markdown 笔记（v15）。规矩与 `open(_:)` 一致：已经开着就切过去，
    /// 当前标签是空的就就地开，否则新开一个标签。
    @discardableResult
    func openMarkdown(_ ref: NoteRef) -> DocTabModel {
        if let hit = tabs.first(where: { $0.noteRef == ref }) {
            activate(hit.id)
            return hit
        }
        if active.docID == nil && active.noteRef == nil {
            active.openMarkdown(ref)
            persist()
            return active
        }
        let t = DocTabModel(app: app, workspace: workspace, windowID: windowID)
        tabs.append(t)
        WorkspaceRegistry.shared.noteWindowObject(t.session.id, window: window)
        t.openMarkdown(ref)
        activate(t.id)
        persist()
        return t
    }

    /// 标签栏的 `+` / ⌘T 不再开空标签，而是弹本工作区的选文档弹窗（`DocPickerView`，用户 2026-09-17 定），
    /// 选中后走 `open`。弹窗挂在「+」上；标签栏不显示时挂在阅读区底部（见 `ReaderPane.tabBar`）。
    @Published var docPickerPresented = false

    /// 建标签但**不切过去**（冷启动恢复一组标签时用：切来切去会让平板跟随反复易主）。
    /// `staged` = 只记下要开哪篇、先不装（见 `DocTabModel.staged`），由 `activate` 负责装。
    @discardableResult
    private func appendTab(docID: String?, staged: Bool = false) -> DocTabModel {
        let t = DocTabModel(app: app, workspace: workspace, windowID: windowID)
        tabs.append(t)
        WorkspaceRegistry.shared.noteWindowObject(t.session.id, window: window)
        if let docID {
            if staged { t.stage(docID) } else { t.select(docID) }
        }
        persist()
        return t
    }

    func activate(_ id: UUID) {
        guard let next = tabs.first(where: { $0.id == id }) else { return }
        // 懒装载：切过去才真装。**必须在 `activeID != id` 判断之外**——冷启动恢复完那一组标签后
        // `activate` 点的常常就是当前这个（`tabs[0]`），走进去反而不装了，界面就是一片空白。
        next.realize()
        if activeID != id {
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

    func activate(offset: Int) {
        guard tabs.count > 1, let i = tabs.firstIndex(where: { $0.id == activeID }) else { return }
        let n = tabs.count
        activate(tabs[((i + offset) % n + n) % n].id)   // 循环，两头都能转回来
    }

    /// 关一个标签。只剩一个时不关（不变式）——调用方据 `canCloseTab` 决定是不是该关窗口。
    func close(_ id: UUID) {
        guard tabs.count > 1, let i = tabs.firstIndex(where: { $0.id == id }) else { return }
        // 关掉的正好是平板跟随的那个会话时，`AppModel.unregister` 会把跟随随手交给 `sessions.last`
        // ——那**可能是另一扇窗口的标签**。本窗口还开着，跟随理应留在本窗口，故记一笔、收尾时拉回来。
        let stealsFollow = (app.activeSessionID == id)
        let closing = tabs[i]
        tabs.remove(at: i)
        closing.close()   // 结清落库 → 退出打开集 → 交还工作区登记 → 注销会话 → 放掉 PDF（次序见那里）
        if activeID == id {
            let next = tabs[min(i, tabs.count - 1)]
            next.prepareForReactivation()
            activeID = next.id
            for t in tabs { t.isActive = (t.id == activeID) }
            bindActive()
            app.setActive(active.session)
        } else if stealsFollow {
            app.setActive(active.session)
        }
        persist()
    }

    /// 还能不能再关标签（false = 只剩一个，⌘W 该关窗口了）。
    var canCloseTab: Bool { tabs.count > 1 }

    func closeOthers(than id: UUID) {
        for t in tabs where t.id != id { close(t.id) }
    }

    /// 关窗：每个标签各自结清。**必须逐个调 `close()`**，否则后台标签的进度/打开集/工作区登记
    /// 全部留在原地（库连接就永远关不掉 → 移动硬盘弹不出去）。
    func closeWindow() {
        guard !closed else { return }
        closed = true
        activeBag.removeAll()
        for t in tabs { t.close() }
    }

    func move(from source: IndexSet, to destination: Int) {
        tabs.move(fromOffsets: source, toOffset: destination)
        persist()
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

    /// 文档被删除/合并掉后从库里消失 → 开着它的标签退回空态（只剩一个标签时不关，同不变式）。
    func pruneMissing(_ docs: [LibDocument]) {
        let live = Set(docs.map(\.id))
        for t in tabs where t.docID != nil && !live.contains(t.docID!) {
            if tabs.count > 1 { close(t.id) } else { t.select(nil) }
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

    private func persist() {
        guard let k = storeKey else { return }
        UserDefaults.standard.set(["docs": tabs.compactMap(\.docID),
                                   "active": active.docID ?? ""], forKey: k)
    }

    /// 冷启动恢复本工作区上次开着的那组标签。**每个工作区只做一次**，由
    /// `WorkspaceRegistry.claimRestore` 把关（`ContentView.decideInitialContent`）。
    ///
    /// 上限 `max`：从前是「本窗口开第一篇 + 最多再开 4 扇窗口」，现在全在一扇窗口里，
    /// 同样要有个数，否则「最近打开」很长时冷启动要一口气装载十几篇 PDF。
    func restoreTabs(max: Int = 8) {
        var ids: [String]
        var wantActive: String?
        if let k = storeKey,
           let d = UserDefaults.standard.dictionary(forKey: k),
           let saved = d["docs"] as? [String], !saved.isEmpty {
            ids = saved
            wantActive = (d["active"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        } else {
            ids = workspace.restoreDocIds        // 没有标签序记录（首次升级）→ 退回库里的「打开集」
            wantActive = ids.first
        }
        ids = ids.filter { workspace.document(id: $0) != nil }   // 已删掉的不恢复
        guard !ids.isEmpty else { return }
        wsLog("restoreTabs：\(ids.count) 篇 → 本窗口开 \(min(ids.count, max)) 个标签（只装活动那一个）")
        // 🔴 一律 `stage`（只记 id 不装），最后由下面那句 `activate` 把用户上次停在的那一个装出来。
        // 从前这里是逐个 `select`，等于冷启动就把每一篇的 PDF、目录、笔迹全读一遍——而窗口里
        // 只有一个标签看得见（2026-09-02 剖析：大书一篇 0.33s，冷盘上近 1s）。
        for id in ids.prefix(max) where !tabs.contains(where: { $0.docID == id }) {
            if active.docID == nil && tabs.count == 1 { active.stage(id) } else { appendTab(docID: id, staged: true) }
        }
        if let wantActive, let hit = tabs.first(where: { $0.docID == wantActive }) {
            activate(hit.id)
        } else {
            activate(tabs[0].id)
        }
    }
}
