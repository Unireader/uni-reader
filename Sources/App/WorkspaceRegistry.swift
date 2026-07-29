import Foundation
import AppKit

/// 工作区实例池：**同一个 `.unrd` 路径，全 app 只有一个 `WorkspaceManager`**（因而只有一个
/// `LibraryStore` = 一个 SQLite 连接）。多工作区并存靠「多个 manager 各自绑一个窗口」，
/// 而不是「一个 manager 换 folder」——后者正是 2026-07-29 之前的架构，双击另一个工作区会把
/// 所有窗口一起换掉。
///
/// ⚠️ **为什么必须共享而不是每窗口新建一个**：`LibraryStore` 是单连接、非线程安全，且笔迹/
/// 注解/高亮的落库走「内存快照 ↔ 库」增量对账（`persistedStrokes`/`persistedTextNotes` 那套）。
/// 同一工作区若开出两个 store，两份快照互不知情，后写的一方会把先写的成果整段判为「已删除」
/// 而清库 —— 直接丢笔记。所以「同路径同实例」是数据安全红线，不是性能优化。
///
/// 「最近工作区」「上次打开的工作区」是**本机全局**状态（UserDefaults，不进包），故留在这里，
/// 不再挂在某个 manager 上。
@MainActor
final class WorkspaceRegistry: ObservableObject {
    static let shared = WorkspaceRegistry()

    /// 已实例化的工作区（标准化路径 → manager）。
    private var byPath: [String: WorkspaceManager] = [:]
    /// 每个 manager 当前被几个窗口持有；归零即从池中移除（连带释放 SQLite 连接）。
    private var retain: [String: Int] = [:]
    /// 各窗口正在显示的工作区（sessionId → 标准化路径），供「双击已打开的工作区 → 激活那个窗口」。
    private var windowPaths: [UUID: String] = [:]

    /// 最近打开过的工作区（本机全局）。
    @Published private(set) var recents: [URL] = []
    /// 某「最近工作区」项已不存在（已顺带移出列表），非空即弹提示。
    @Published var missingRecentName: String?

    private let recentsKey = "recentWorkspaces"
    private let lastKey = "lastWorkspacePath"

    private init() {
        loadRecents()
        // 把已有的最近列表补喂系统一次：老用户升级上来时，系统那份「最近使用的文稿」还是空的，
        // 不补的话 app 未运行时 Dock 右键什么都看不到，得把每个工作区重新打开一遍才会出现。
        // 倒序喂 —— `noteNewRecentDocumentURL` 总把最新的置顶，倒着喂完顺序才和我们这份一致。
        for url in recents.reversed() { NSDocumentController.shared.noteNewRecentDocumentURL(url) }
    }

    static func key(_ url: URL) -> String { url.standardizedFileURL.path }

    // MARK: - 实例池

    /// 取（或建）某工作区的 manager 并 +1 引用。**同路径必返回同一实例**（红线，见类型注释）。
    /// 「这个目标是不是真实工作区」的严格校验属于用户侧入口的事，在开窗口之前用
    /// `WorkspaceManager.validate` 做掉；走到这里的路径要么是显式指定、要么是上次用过的，
    /// 首次启动还要靠它在默认位置建库。
    func acquire(folder: URL) throws -> WorkspaceManager {
        let k = Self.key(folder)
        if let m = byPath[k] {
            retain[k, default: 0] += 1
            return m
        }
        let m = try WorkspaceManager(folder: folder)
        // 迁移改名（旧式无扩展名工作区）后真实路径可能变了，按最终路径入池。
        let finalKey = m.folder.map(Self.key) ?? k
        byPath[finalKey] = m
        retain[finalKey, default: 0] += 1
        rememberRecent(m.folder ?? folder)
        UserDefaults.standard.set(finalKey, forKey: lastKey)
        return m
    }

    /// 窗口放手：引用归零则移出池（manager 随之析构、关掉 SQLite 连接）。
    func release(_ manager: WorkspaceManager) {
        guard let k = byPath.first(where: { $0.value === manager })?.key else { return }
        releaseKey(k)
    }

    private func releaseKey(_ k: String) {
        retain[k, default: 1] -= 1
        guard retain[k, default: 0] <= 0 else { return }
        retain.removeValue(forKey: k)
        byPath.removeValue(forKey: k)
    }

    /// 把显示该工作区的窗口调到前台（「双击已打开的工作区」= 激活，不重复开窗）。
    func activateWindow(forWorkspace folder: URL) {
        let k = Self.key(folder)
        guard let sid = windowPaths.first(where: { $0.value == k })?.key,
              let win = windowsBySession[sid] else {
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
    }

    /// 登记窗口本体（`WindowAccessor` 拿到 NSWindow 时回填），供上面的激活用。
    func noteWindowObject(_ sessionId: UUID, window: NSWindow?) {
        if let window { windowsBySession[sessionId] = window }
        else { windowsBySession.removeValue(forKey: sessionId) }
    }

    private var windowsBySession: [UUID: NSWindow] = [:]

    /// 上次使用的工作区路径（冷启动默认打开它）；没有则用内置默认工作区。
    func lastOrDefaultFolder() -> URL {
        if let p = UserDefaults.standard.string(forKey: lastKey) {
            let u = URL(fileURLWithPath: p)
            var d: ObjCBool = false
            if FileManager.default.fileExists(atPath: u.path, isDirectory: &d), d.boolValue { return u }
        }
        return WorkspaceManager.defaultFolder()
    }

    // MARK: - 窗口 ↔ 工作区

    func noteWindow(_ sessionId: UUID, path: String?) {
        if let path { windowPaths[sessionId] = Self.key(URL(fileURLWithPath: path)) }
        else {
            windowPaths.removeValue(forKey: sessionId)
            windowsBySession.removeValue(forKey: sessionId)
        }
    }

    /// 该工作区是否已有窗口在显示。
    func hasWindow(forWorkspace folder: URL) -> Bool {
        windowPaths.values.contains(Self.key(folder))
    }

    /// 认领「恢复上次打开的整组文档」这件事：每个工作区在本次运行内**只做一次**，首个认领者返回 true。
    /// ⚠️ 没有这道闸会连锁开窗：`restoreSession` 自己就会 `openWindow`，而每个新窗口的 ContentView
    /// 又会跑一次 restore。以前靠 App 级的 `didRestoreInitial` 挡着（全 app 只恢复一次），改成
    /// 多工作区后那个标志失效了 —— 得按工作区各挡各的。⌘N 开的第二个窗口也会被这里挡下
    /// （它要的是一个空窗口，不是再恢复一遍）。
    func claimRestore(_ folder: URL) -> Bool {
        restoredWorkspaces.insert(Self.key(folder)).inserted
    }

    private var restoredWorkspaces: Set<String> = []

    // MARK: - 最近工作区（本机全局）

    private func loadRecents() {
        let arr = (UserDefaults.standard.array(forKey: recentsKey) as? [String]) ?? []
        recents = arr.map { URL(fileURLWithPath: $0) }
    }

    func rememberRecent(_ url: URL) {
        var paths = recents.map(\.path).filter { $0 != url.path }
        paths.insert(url.path, at: 0)
        paths = Array(paths.prefix(10))
        UserDefaults.standard.set(paths, forKey: recentsKey)
        recents = paths.map { URL(fileURLWithPath: $0) }
        // 同时喂给系统的「最近使用的文稿」：**app 未运行时** Dock 右键显示的是这一份
        // （自定义的 applicationDockMenu 只在运行时生效），点击它会正常走 application(_:open:)。
        // 顺带也让「文件 → 打开最近使用」有内容。
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
    }

    /// 从最近列表移除一条记录（只删记录，不动工作区本身）。
    func removeRecent(_ url: URL) {
        let paths = recents.map(\.path).filter { $0 != url.path }
        UserDefaults.standard.set(paths, forKey: recentsKey)
        recents = paths.map { URL(fileURLWithPath: $0) }
    }

    /// 工作区原地改名后，把最近列表里的旧路径替换为新路径（去重保序），并跟进池的键。
    func replaceRecent(old: URL, new: URL) {
        var paths = recents.map(\.path)
        if let i = paths.firstIndex(of: old.path) { paths[i] = new.path }
        var seen = Set<String>()
        paths = paths.filter { seen.insert($0).inserted }
        UserDefaults.standard.set(paths, forKey: recentsKey)
        recents = paths.map { URL(fileURLWithPath: $0) }

        let ok = Self.key(old), nk = Self.key(new)
        if let m = byPath.removeValue(forKey: ok) {
            byPath[nk] = m
            retain[nk] = retain.removeValue(forKey: ok) ?? 1
            for (sid, p) in windowPaths where p == ok { windowPaths[sid] = nk }
        }
        if UserDefaults.standard.string(forKey: lastKey) == ok {
            UserDefaults.standard.set(nk, forKey: lastKey)
        }
    }
}
