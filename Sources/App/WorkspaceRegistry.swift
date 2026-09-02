import Foundation
import AppKit
import SwiftUI

/// 「最近工作区」的一条记录。
///
/// 🔴 **列的是工作区身份，不是某个副本的路径**。一个工作区可能同时有两份副本——源盘上那份、
/// 本机的离线副本——但在用户眼里**永远只有一个工作区**：点开哪一份由
/// `WorkspaceRegistry.resolve` 当场决定（盘在就用盘上的，盘不在就用本机的）。
///
/// 离线副本因此**从不单独出现在最近列表 / Dock 菜单 / 文件→最近打开里**。
/// 这正是「自动维护的副本」与「你自己拷了一份」的分界：后者要用户记住它在哪、
/// 每次在两条记录里挑一条——那还不如手动复制。
struct RecentWorkspace: Codable, Hashable, Identifiable {
    /// `workspace_id`。迁移老记录时盘不在、读不出来，就先拿源路径顶着，下次成功打开即补正
    var id: String
    var name: String
    /// 源工作区（可能在一块没插上的盘上）
    var sourcePath: String
    /// 本机离线副本，由 App 维护，用户不需要知道这个路径
    var mirrorPath: String?
}

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
    ///
    /// ⚠️ **弱持有**：强引用在窗口那边（`RootView` 的 `@State`），池只登记「这条路径现在归谁」。
    /// 早先是强引用 + 引用计数归零就摘掉条目，但那时旧实例**还活着**（SwiftUI 关窗后 `@State` 的
    /// 释放是延后的，`ContentView` 的尾随进度补存也还能写库），这段空窗里同路径再 `acquire` 就会给
    /// 同一个库开出第二个 `LibraryStore` —— 正是本类型开头那条红线禁止的状态。改成弱引用后，
    /// 「同路径同实例」只取决于旧实例是否还活着，不再取决于引用计数的时序。
    ///
    /// 条目在 `maybeTeardown`（无窗口 + 写库已落地）里摘掉。**那一刻摘是安全的**：连接已被显式关闭、
    /// 旧实例的 `store` 已置 nil，它再也写不进库，所以「同时存在两个活 store」这件事不会发生
    /// ——红线约束的是**活着的连接**，不是活着的实例。
    private var byPath: [String: Weak] = [:]
    /// 当前有几个窗口在显示该工作区（不负责生命周期，见上）；归零时清掉「已恢复过」的记号（`claimRestore`）。
    private var retain: [String: Int] = [:]

    private final class Weak {
        weak var manager: WorkspaceManager?
        init(_ m: WorkspaceManager) { manager = m }
    }
    /// 各窗口正在显示的工作区（sessionId → 标准化路径），供「双击已打开的工作区 → 激活那个窗口」。
    private var windowPaths: [UUID: String] = [:]

    /// 最近打开过的工作区（本机全局）。**列的是工作区身份，不是副本路径**——见 `RecentWorkspace`。
    @Published private(set) var recents: [RecentWorkspace] = []
    /// 某「最近工作区」项已不存在（已顺带移出列表），非空即弹提示。
    @Published var missingRecentName: String?

    private let recentsKey = "recentWorkspaces"        // 老格式：[String]（纯路径）
    private let recentsKeyV2 = "recentWorkspacesV2"    // 新格式：[RecentWorkspace] JSON
    private let lastKey = "lastWorkspacePath"

    private init() {
        loadRecents()
        // 把已有的最近列表补喂系统一次：老用户升级上来时，系统那份「最近使用的文稿」还是空的，
        // 不补的话 app 未运行时 Dock 右键什么都看不到，得把每个工作区重新打开一遍才会出现。
        // 倒序喂 —— `noteNewRecentDocumentURL` 总把最新的置顶，倒着喂完顺序才和我们这份一致。
        // 喂的是**源盘那份**：系统那张表点开走 `application(_:open:)`，不经我们的副本解析，
        // 喂副本进去就等于把 `~/Library` 里那个路径捅到用户面前了。
        for r in recents.reversed() {
            NSDocumentController.shared.noteNewRecentDocumentURL(URL(fileURLWithPath: r.sourcePath))
        }
    }

    static func key(_ url: URL) -> String { url.standardizedFileURL.path }

    // MARK: - 一条记录**现在**该打开哪一份副本

    /// 源盘在就开源盘，不在就开本机离线副本；两个都没有 → nil（调用方照旧走「工作区不存在」）。
    ///
    /// 这一步是整个离线功能的枢纽：用户点的是「工作区」，选副本是 App 的事。
    static func resolve(_ r: RecentWorkspace) -> URL? {
        let src = URL(fileURLWithPath: r.sourcePath)
        if WorkspaceManager.hasLibrary(src) { return src }
        if let m = r.mirrorPath {
            let mirror = URL(fileURLWithPath: m)
            if WorkspaceManager.hasLibrary(mirror) { return mirror }
        }
        return nil
    }

    /// 点它会开离线副本吗（= 源盘此刻没连接，但本机有副本）。列表据此换个图标。
    static func opensOffline(_ r: RecentWorkspace) -> Bool {
        guard !WorkspaceManager.hasLibrary(URL(fileURLWithPath: r.sourcePath)),
              let m = r.mirrorPath else { return false }
        return WorkspaceManager.hasLibrary(URL(fileURLWithPath: m))
    }

    /// 解析不出来时**照旧交源路径**给调用方：让既有的「工作区不存在 → 提示 + 移出列表」原样生效。
    static func resolveOrSource(_ r: RecentWorkspace) -> URL {
        resolve(r) ?? URL(fileURLWithPath: r.sourcePath)
    }

    /// 这个工作区**此刻有没有活着的实例**（不 +1 引用、不新建）。
    ///
    /// 给「同步到源盘」用：源盘那个工作区可能正被另一个窗口开着，那就必须写它那条连接，
    /// 不能另开一条 —— 两条活连接同时写同一个库，正是 §8.1 红线要根除的。
    func openManager(at folder: URL) -> WorkspaceManager? { byPath[Self.key(folder)]?.manager }

    // MARK: - 实例池

    /// 取（或建）某工作区的 manager 并 +1 引用。**同路径必返回同一实例**（红线，见类型注释）。
    ///
    /// 这里**不校验**目标是不是真实工作区，因为它同时承担「首次启动在默认位置建库」。
    /// 「是不是真实工作区」由所有**用户手势**入口在此之前用 `WorkspaceManager.validate` 判掉：
    /// 热启动走 `ContentView.routeToWorkspace`，冷启动双击与显式指定走 `RootView.resolve` 的 strict 分支。
    /// 唯一不校验的来源是「上次/默认工作区」这条兜底。
    func acquire(folder: URL) throws -> WorkspaceManager {
        let k = Self.key(folder)
        if let m = byPath[k]?.manager {
            retain[k, default: 0] += 1
            wsLog("acquire：复用实例 \(folder.lastPathComponent) retain=\(retain[k] ?? 0)")
            return m
        }
        let m = try WorkspaceManager(folder: folder)
        // 迁移改名（旧式无扩展名工作区）后真实路径可能变了，按最终路径入池。
        let finalKey = m.folder.map(Self.key) ?? k
        byPath[finalKey] = Weak(m)
        retain[finalKey, default: 0] += 1
        rememberRecent(m.folder ?? folder)
        UserDefaults.standard.set(finalKey, forKey: lastKey)
        wsLog("acquire：新建实例 \(folder.lastPathComponent) retain=\(retain[finalKey] ?? 0)")
        return m
    }

    /// 窗口放手：最后一个窗口关掉后（且该窗口的写库已落地），`maybeTeardown` 显式关掉 SQLite 连接
    /// 并摘掉池条目 —— **不等 manager 自己析构**：那个时机挂在 SwiftUI 的 `@State` 上，没有保证，
    /// 而连接一天不关，工作区所在的可移动硬盘就一天弹不出去。
    func release(_ manager: WorkspaceManager) {
        guard let k = byPath.first(where: { $0.value.manager === manager })?.key else {
            wsLog("release：⚠️ 实例不在池中，什么都没做（\(manager.folder?.lastPathComponent ?? "nil")）")
            return
        }
        releaseKey(k)
    }

    private func releaseKey(_ k: String) {
        retain[k, default: 1] -= 1
        wsLog("release：\((k as NSString).lastPathComponent) retain=\(retain[k] ?? 0)")
        guard retain[k, default: 0] <= 0 else { return }
        retain.removeValue(forKey: k)
        wsLog("release：窗口数归零，归还「已恢复过」记号")
        // 「本工作区已恢复过整组文档」的记号跟着窗口数归零一起还回去：否则同一次运行里关掉某工作区的
        // 全部窗口再打开它，会得到一个空窗口 —— 而「打开集」在关最后一个窗口时是特意保留的
        // （`WorkspaceManager.closeWindow`），两边的时间尺度必须一致。
        restoredWorkspaces.remove(k)
        byPath = byPath.filter { $0.value.manager != nil }   // 顺手清掉已析构的空条目
        maybeTeardown(k)
    }

    /// 「这个工作区已经没有任何窗口在用了」→ **立刻**关掉它的库连接并摘掉池条目。
    ///
    /// ⚠️ **必须显式关，不能等 ARC**（2026-08-05 用户报的可移动硬盘问题）：关窗后 manager 的强引用
    /// 还在 SwiftUI 的 `@State` 里，何时释放没有保证；只要 `library.sqlite` 的 fd 还开着，工作区所在的
    /// 移动硬盘在 Finder 里就弹不出去，用户只能退出整个 app。会话那边的 PDF 文件引用同理，由
    /// `DocSession.teardown` 负责。
    ///
    /// **两个触发点都要调**（`releaseKey` 与 `noteWindow(_:nil)`）：AppKit 的 `willClose` 与 SwiftUI 的
    /// `onDisappear` 没有保证的先后，而条件里的两项恰好分别由这两条路清零。后发生的那一个才同时满足
    /// 「窗口没了」+「该窗口最后一次写库（进度 / 打开集，都在 `ContentView.onDisappear` 里**同步**完成）
    /// 已经落地」—— 早关一步就是静默丢进度。
    ///
    /// 摘条目**不违反**「同路径同实例」红线（见类型注释）：连接已关、`store` 已置 nil，那个旧实例
    /// 再也写不进库，下次 `acquire` 新建的实例仍是这个库唯一的连接。
    private func maybeTeardown(_ k: String) {
        guard retain[k, default: 0] <= 0, !windowPaths.values.contains(k) else { return }
        guard let m = byPath.removeValue(forKey: k)?.manager else { return }
        m.teardown()
        // 诊断：连接已关，弹盘不再受阻；实例本身若迟迟不释放说明别处还强引用着它（只记一笔，不影响功能）。
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak m] in
            if m != nil { wsLog("teardown：⚠️ manager 仍存活（连接已关，仅记录）\((k as NSString).lastPathComponent)") }
        }
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
        if let k = windowPaths[sessionId] { activateIfPending(k) }
    }

    /// 「这个工作区的窗口**一出现**就把它调到前台。」
    ///
    /// 弹盘切副本时用：那扇窗是我们**替用户开的**，开在别人后面等于没开
    /// （用户 2026-09-01 实测：老窗关了、新窗开了，但躲在其他窗口后面）。
    /// `activateWindow` 顶不了这个班——它要求窗口**此刻已经登记过**，而这里窗口还没建出来
    /// （`openWindow` 是异步的）。所以记一笔待激活，等窗口登记时再兑现。
    ///
    /// 还必须 `NSApp.activate`：弹出是在 Finder 里点的，此刻前台是 Finder 不是我们。
    func requestActivation(forWorkspace folder: URL) {
        let k = Self.key(folder)
        pendingActivation = k
        activateIfPending(k)   // 窗口本来就开着的话，当场兑现
    }

    private func activateIfPending(_ k: String) {
        guard pendingActivation == k,
              let sid = windowPaths.first(where: { $0.value == k })?.key,
              let win = windowsBySession[sid] else { return }
        pendingActivation = nil
        wsLog("激活等待中的窗口：\((k as NSString).lastPathComponent)")
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
    }

    private var pendingActivation: String?

    /// 取某个会话的窗口（AI 面板吸附要知道贴到哪一扇上）。
    func window(for sessionId: UUID) -> NSWindow? { windowsBySession[sessionId] }

    private var windowsBySession: [UUID: NSWindow] = [:]

    /// 上次使用的工作区路径（冷启动默认打开它）；没有则用内置默认工作区。
    func lastOrDefaultFolder() -> URL {
        if let p = UserDefaults.standard.string(forKey: lastKey) {
            let u = URL(fileURLWithPath: p)
            var d: ObjCBool = false
            if FileManager.default.fileExists(atPath: u.path, isDirectory: &d), d.boolValue { return u }
            // 上次那个工作区在一块现在没插的盘上：有本机离线副本就开副本，
            // 而不是把用户扔回内置默认工作区——「拔了盘照样接着读」正是这个功能的全部意义。
            if let r = recents.first(where: { $0.sourcePath == p }), let alt = Self.resolve(r) { return alt }
        }
        return WorkspaceManager.defaultFolder()
    }

    // MARK: - 打开工作区的唯一路由

    /// **打开某个工作区 = 开一个属于它的窗口**（已有窗口则激活它），而不是把某个窗口换过去。
    /// 双击 `.unrd` / 侧栏「打开工作区…」/ 最近工作区 / 新建 / Dock 菜单，全部走这里。
    /// `strict` = 严格校验（必须是含 `library.sqlite` 的真实工作区，不静默建空库）；校验失败抛错，
    /// 由调用方决定怎么提示（各窗口自己的 alert）。
    ///
    /// ⚠️ **这件事是 app 级的，不能挂在某个窗口的 `ContentView` 上**（2026-07-29 实测踩到）：
    /// 屏幕上只剩一个「打不开工作区」的错误态窗口时，那个窗口根本没有 `ContentView`，于是全 app
    /// 没有任何订阅者，双击请求被**静默丢弃**、`pendingWorkspacePath` 还留着陈旧值。
    /// 🔴 2026-09-01 窗口层迁到 AppKit 后，`openWindow` 那个参数没了——开窗归
    /// `AppDelegate.openReaderWindow`，app 级代码直接够得着。上面那条「只剩错误态窗口时请求被
    /// 静默丢弃」的老账也随之作废（不再依赖任何窗口来认领）。
    func route(to url: URL, strict: Bool) throws {
        if strict {
            do { try WorkspaceManager.validate(url) } catch {
                wsLog("route 校验失败：\(error.localizedDescription)")
                throw error
            }
        }
        if hasWindow(forWorkspace: url) {
            wsLog("route：该工作区已有窗口，激活它 \(url.path)")
            activateWindow(forWorkspace: url)
            return
        }
        wsLog("route：开新窗口 \(url.path)")
        AppDelegate.shared?.openReaderWindow(workspacePath: url.standardizedFileURL.path, docId: nil)
    }

    // MARK: - 窗口 ↔ 工作区

    func noteWindow(_ sessionId: UUID, path: String?) {
        if let path {
            let k = Self.key(URL(fileURLWithPath: path))
            windowPaths[sessionId] = k
            activateIfPending(k)   // 两处登记谁先谁后没保证，两边都试一下（见 requestActivation）
        }
        else {
            let gone = windowPaths.removeValue(forKey: sessionId)
            windowsBySession.removeValue(forKey: sessionId)
            // 关窗时这里是「本窗口对工作区的最后一次写库之后」的那一刻（`ContentView.onDisappear`
            // 的调用次序），故要在此再判一次能否收尾——willClose 可能已经先跑过 `releaseKey` 了。
            if let gone { maybeTeardown(gone) }
        }
    }

    // MARK: - 盘要弹了

    /// 这个卷上现在开着哪些工作区。判据见 `VolumeScope.contains`
    /// （按路径分量比，别让 `/Volumes/备份` 把 `/Volumes/备份2` 也算进去）。
    func openWorkspaces(onVolume volume: URL) -> [URL] {
        byPath.compactMap { key, box in
            guard box.manager != nil,
                  VolumeScope.contains(key, volume: volume.path) else { return nil }
            return URL(fileURLWithPath: key)
        }
    }

    /// 盘要弹了：**当场**关掉这个工作区的库连接，并关掉显示它的窗口。
    ///
    /// 🔴 连接必须**同步**关（不能等窗口拆完）：只要 `library.sqlite` 的 fd 还开着，
    /// Finder 就报「磁盘正在使用中」——这正是 `WorkspaceManager.teardown()` 那条注释里
    /// 用户 2026-08-05 报过的「必须退出整个 app 才能弹盘」。PDF 的文件句柄挂在窗口的
    /// 视图状态上，随窗口关闭走既有的那条结清链路（`ContentView.onDisappear`）。
    func evacuate(_ folder: URL) {
        let k = Self.key(folder)
        wsLog("evacuate：盘要弹了，撤离 \((k as NSString).lastPathComponent)")
        byPath[k]?.manager?.teardown()
        for (sid, path) in windowPaths where path == k {
            windowsBySession[sid]?.close()
        }
    }

    /// 该工作区是否已有窗口在显示。
    func hasWindow(forWorkspace folder: URL) -> Bool {
        windowPaths.values.contains(Self.key(folder))
    }

    /// 屏幕上是否已经有本 app 的窗口（`RootView` 一级，**含尚未绑定工作区的错误态窗口**）。
    /// 供 `RootView.isStrayWindow` 判定「SwiftUI 激活时凭空塞的空窗口」：用户开窗的两条路都显式带
    /// 工作区路径，所以「没指定工作区 + 已经有窗口」= 幻影；一个窗口都没有时才是「点 Dock 图标重开」，
    /// 该放行去开上次的工作区。
    ///
    /// ⚠️ 不能拿 `windowPaths` 代替：那张表由 `ContentView` 登记，**错误态窗口不在其中**
    /// （2026-07-29 实测：双击坏包后只剩一个错误窗，幻影窗口因此没被认出来，转正成了一个用户没要的
    /// 「上次工作区」窗口）。
    /// ⚠️ 必须**排除本窗口自己**：`onAppear` 登记在前、`didFinishLaunching` 那一轮的判定在后，
    /// 不排除的话冷启动第一个窗口会数到自己、把自己判成幻影而自杀（普通启动直接白屏）。

    /// `RootView` 级窗口登记（不管有没有成功绑定工作区，错误态窗口也要登记）。
    func noteRootWindow(_ id: UUID) { rootWindows.insert(id) }

    /// 该窗口领到工作区实例了 —— 记下来，好在窗口关闭时替它放手（关闭回调只带得动一个不变的 id）。
    func bindRootWindow(_ id: UUID, _ manager: WorkspaceManager) { rootWindowWorkspace[id] = manager }

    /// 窗口**真正关闭**（AppKit `willClose`，不是 SwiftUI 的 onDisappear——理由见 `WindowLifecycle`）：
    /// 注销登记并替它向实例池放手。重复调用是安全的（第二次取不到条目就什么都不做）。
    func closeRootWindow(_ id: UUID) {
        let known = rootWindows.remove(id) != nil
        let manager = rootWindowWorkspace.removeValue(forKey: id)
        wsLog("closeRootWindow：登记过=\(known) 工作区=\(manager?.folder?.lastPathComponent ?? "无")")
        if let manager { release(manager) }
    }

    private var rootWindows: Set<UUID> = []
    private var rootWindowWorkspace: [UUID: WorkspaceManager] = [:]

    /// 认领「恢复上次打开的整组文档」这件事：每个工作区在本次运行内**只做一次**，首个认领者返回 true。
    /// ⚠️ 没有这道闸会连锁开窗：`restoreSession` 自己就会 `openWindow`，而每个新窗口的 ContentView
    /// 又会跑一次 restore。以前靠 App 级的 `didRestoreInitial` 挡着（全 app 只恢复一次），改成
    /// 多工作区后那个标志失效了 —— 得按工作区各挡各的。⌘N 开的第二个窗口也会被这里挡下
    /// （它要的是一个空窗口，不是再恢复一遍）。
    func claimRestore(_ folder: URL) -> Bool {
        let ok = restoredWorkspaces.insert(Self.key(folder)).inserted
        wsLog("claimRestore(\(folder.lastPathComponent)) = \(ok)")
        return ok
    }

    private var restoredWorkspaces: Set<String> = []

    // MARK: - 最近工作区（本机全局）

    private func loadRecents() {
        if let data = UserDefaults.standard.data(forKey: recentsKeyV2),
           let arr = try? JSONDecoder().decode([RecentWorkspace].self, from: data) {
            recents = arr
            return
        }
        recents = Self.migrateRecents((UserDefaults.standard.array(forKey: recentsKey) as? [String]) ?? [])
        saveRecents()
    }

    private func saveRecents() {
        if let data = try? JSONEncoder().encode(recents) {
            UserDefaults.standard.set(data, forKey: recentsKeyV2)
        }
    }

    /// 老格式（纯路径数组）→ 身份记录。**离线副本并入它源工作区那一条**，不单独留一行：
    /// 老列表里副本和源是两条并排的记录，正是这次要消灭的东西。
    ///
    /// 盘没插 → 读不出 `workspace_id`，先用路径顶着当 id，下次成功打开时 `rememberRecent` 补正。
    private static func migrateRecents(_ paths: [String]) -> [RecentWorkspace] {
        var out: [RecentWorkspace] = []
        var mirrors: [(of: String, hint: String, name: String, path: String)] = []
        for p in paths {
            let url = URL(fileURLWithPath: p)
            let fallbackName = WorkspaceManager.defaultWorkspaceName(for: url)
            let peek = LibraryStore.peekIdentity(folder: url)
            if let of = peek?.mirrorOf {
                mirrors.append((of, peek?.sourceHint ?? "", peek?.name ?? fallbackName, p))
            } else {
                out.append(RecentWorkspace(id: peek?.id ?? p, name: peek?.name ?? fallbackName,
                                           sourcePath: p, mirrorPath: nil))
            }
        }
        for m in mirrors {
            if let i = out.firstIndex(where: { $0.id == m.of }) {
                out[i].mirrorPath = m.path
            } else if !m.hint.isEmpty {
                // 源盘这次没在最近列表里，但副本记着它上次在哪 —— 够撑起一条记录
                out.append(RecentWorkspace(id: m.of, name: m.name, sourcePath: m.hint, mirrorPath: m.path))
            }
            // 连 hint 都没有的副本：这条最近记录丢掉（副本本体不动）。它没有源，列出来也没法解析
        }
        return out
    }

    /// 记一次「打开过」。
    ///
    /// 🔴 打开的若是**离线副本**，只更新它所属工作区那一条记录的 `mirrorPath`，**绝不新建条目**：
    /// 副本不是一个独立的工作区，用户不该在列表里看见它、更不该在两条里挑。
    func rememberRecent(_ url: URL) {
        let peek = LibraryStore.peekIdentity(folder: url)
        let name = peek?.name ?? WorkspaceManager.defaultWorkspaceName(for: url)
        var list = recents
        if let of = peek?.mirrorOf {
            if let i = list.firstIndex(where: { $0.id == of }) {
                var r = list.remove(at: i)
                r.mirrorPath = url.path
                list.insert(r, at: 0)
            } else if let hint = peek?.sourceHint, !hint.isEmpty {
                list.insert(RecentWorkspace(id: of, name: name, sourcePath: hint,
                                            mirrorPath: url.path), at: 0)
            }
            recents = Array(list.prefix(10))
            saveRecents()
            return   // 系统那份「最近使用的文稿」不喂副本 —— 理由见 init
        }
        let id = peek?.id ?? url.path
        if let i = list.firstIndex(where: { $0.id == id || $0.sourcePath == url.path }) {
            var r = list.remove(at: i)
            r.id = id; r.name = name; r.sourcePath = url.path
            list.insert(r, at: 0)
        } else {
            list.insert(RecentWorkspace(id: id, name: name, sourcePath: url.path, mirrorPath: nil), at: 0)
        }
        recents = Array(list.prefix(10))
        saveRecents()
        // 同时喂给系统的「最近使用的文稿」：**app 未运行时** Dock 右键显示的是这一份
        // （自定义的 applicationDockMenu 只在运行时生效），点击它会正常走 application(_:open:)。
        // 顺带也让「文件 → 打开最近使用」有内容。
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
    }

    /// 找某个源工作区那条记录：**先按 id，再按路径**——迁移上来的记录 id 可能是拿路径顶的，
    /// 而工作区的 `workspace_id` 也可能是刚建镜像时才补上的。
    private func recentIndex(id: String?, path: String) -> Int? {
        if let id, let i = recents.firstIndex(where: { $0.id == id }) { return i }
        return recents.firstIndex(where: { $0.sourcePath == path })
    }

    /// 给某个工作区挂上/摘掉它的离线副本（「保留离线副本」开关落到这里）。
    /// 顺手把记录的 id 补正——第一次建副本时源工作区才拿到 `workspace_id`。
    func setMirror(_ mirrorPath: String?, forSource folder: URL, id: String?) {
        guard let i = recentIndex(id: id, path: folder.path) else { return }
        if let id { recents[i].id = id }
        recents[i].mirrorPath = mirrorPath
        saveRecents()
    }

    /// 这个工作区在本机有没有离线副本（**记录里挂着、且那份文件确实还在**）。
    func mirrorPath(forSource folder: URL, id: String?) -> String? {
        guard let i = recentIndex(id: id, path: folder.path),
              let p = recents[i].mirrorPath,
              WorkspaceManager.hasLibrary(URL(fileURLWithPath: p)) else { return nil }
        return p
    }

    /// 从最近列表移除一条记录（只删记录，不动工作区本身）。
    /// ⚠️ 系统那份「最近使用的文稿」**没有删单条的 API**（`NSDocumentController` 只给整体
    /// `clearRecentDocuments`），所以这条移除只对运行时的 Dock 菜单与 App 内菜单生效；
    /// app 未运行时 Dock 右键里那条还会在。要清干净得用 `clearRecents()`。
    /// 按**任一副本的路径**移除（调用方手上通常只有刚才没打开成的那个 URL）。
    func removeRecent(_ url: URL) {
        recents.removeAll { $0.sourcePath == url.path || $0.mirrorPath == url.path }
        saveRecents()
    }

    /// 清空最近列表（只删记录，不动任何工作区）。**两份数据源一起清**——自己这份 +
    /// 系统的「最近使用的文稿」，否则 app 未运行时 Dock 右键里旧条目照旧列出来（见 `rememberRecent`）。
    func clearRecents() {
        recents = []
        saveRecents()
        NSDocumentController.shared.clearRecentDocuments(nil)
    }

    /// 工作区原地改名后，把最近列表里的旧路径替换为新路径（去重保序），并跟进池的键。
    func replaceRecent(old: URL, new: URL) {
        // 改名动的是源盘那份（副本在 ~/Library 下、名字由 App 定，用户改不到它）
        for i in recents.indices where recents[i].sourcePath == old.path {
            recents[i].sourcePath = new.path
            recents[i].name = WorkspaceManager.defaultWorkspaceName(for: new)
        }
        saveRecents()

        let ok = Self.key(old), nk = Self.key(new)
        if let box = byPath.removeValue(forKey: ok) {
            byPath[nk] = box
            retain[nk] = retain.removeValue(forKey: ok) ?? 1
            if restoredWorkspaces.remove(ok) != nil { restoredWorkspaces.insert(nk) }
            for (sid, p) in windowPaths where p == ok { windowPaths[sid] = nk }
        }
        if UserDefaults.standard.string(forKey: lastKey) == ok {
            UserDefaults.standard.set(nk, forKey: lastKey)
        }
    }
}
