import SwiftUI
import AppKit

/// 每个窗口的根：**决定本窗口属于哪个工作区**，领到 `WorkspaceManager` 后注入子树。
/// `ContentView` 及其下游（侧栏/Inspector/阅读区）仍照旧用 `@EnvironmentObject var workspace`，
/// 只是拿到的实例现在**因窗口而异**——这正是多工作区并存的关键，也让那 28 处既有用法一行不用改。
///
/// 工作区归属定下来后就不再变（切工作区 = 换窗口，不是换当前窗口的内容）。
struct RootView: View {
    let target: WindowTarget?

    @EnvironmentObject private var app: AppModel
    @Environment(\.openWindow) private var openWindow
    @State private var workspace: WorkspaceManager?
    @State private var failure: String?
    @State private var selfClose = false
    @State private var windowId = UUID()  // 本窗口在 registry 的登记号（幻影判定要数「屏上有几个窗口」）
    @State private var routeError: String?   // 双击/Dock 来的工作区打不开（校验失败）待提示

    /// 本窗口是不是「SwiftUI 在 app 激活时凭空塞出来的空窗口」。
    ///
    /// ⚠️ **必须在 body 求值时判定，不能等 `onAppear`**：onAppear 是窗口**显示之后**才调用的，
    /// 那时窗口已经上屏，再 `orderOut` 就是用户看到的「闪一下又消失」（2026-07-29 实测确认）。
    /// body 求值早于视图挂载和窗口 orderFront，此刻决定才来得及。
    ///
    /// 判定四条缺一不可：没绑定过工作区（绑定了就是正经窗口，否则窗口自己注册完会把自己判成多余的
    /// 而自杀）、不是错误态、没指定工作区（用户开窗的两条路 ⌘N 和「打开工作区」都显式带路径）、
    /// 且**屏幕上已经有本 app 的窗口**。冷启动第一个窗口不会命中：那时 didFinishLaunching 还是假。
    ///
    /// 最后一条早先写的是「它要落到的那个工作区已经有窗口」——间接量，会漏。2026-07-29 实测：双击一个
    /// 坏包后屏幕上只剩错误窗，「上次工作区」确实没有窗口，于是幻影窗口没被认出来、转正成了一个用户
    /// 根本没要的「上次工作区」窗口。改用直接量后，`isStrayWindow` 也不再和 `resolve` 各写一套
    /// 「本窗口会落到哪个工作区」的预测。
    private var isStrayWindow: Bool {
        guard workspace == nil, failure == nil,
              target?.workspacePath == nil,
              AppDelegate.didFinishLaunching else { return false }
        return WorkspaceRegistry.shared.hasOtherRootWindow(than: windowId)
    }

    var body: some View {
        content
            // 窗口关闭 = AppKit 的 willClose，**不是** SwiftUI 的 onDisappear（后者在窗口建立过程中
            // 会空放一次，理由与后果见 `WindowLifecycle`）。闭包只捕获不会变的 windowId，
            // 「这个窗口持有哪个工作区」记在 registry 里，免得捕获到过期的 workspace。
            .background(WindowLifecycle(onClose: {
                WorkspaceRegistry.shared.closeRootWindow(windowId)
            }))
        .onAppear {
            // 已判定为多余窗口就锁定（body 里的 isStrayWindow 依赖 workspace==nil，一旦 resolve
            // 绑定了工作区它就会翻假、把这个本该关掉的窗口又显示出来），并且**不要** resolve。
            if isStrayWindow { selfClose = true; return }
            // 登记在 resolve 之前：错误态窗口也算「屏幕上的一个窗口」，否则下一个幻影窗口认不出来。
            WorkspaceRegistry.shared.noteRootWindow(windowId)
            resolve(from: "onAppear")
        }
        .onReceive(NotificationCenter.default.publisher(for: .appDidFinishLaunching)) { _ in
            if isStrayWindow { selfClose = true; return }
            resolve(from: "didFinishLaunching")
        }
        .onReceive(NotificationCenter.default.publisher(for: .openWorkspaceRequested)) { note in
            // Finder 双击 / 拖到 Dock 的 .unrd（**app 已在运行**时）→ 开一个属于它的窗口（已有则激活），
            // 当前窗口不受影响。挂在 `RootView` 而不是 `ContentView`：错误态窗口没有 ContentView，
            // 只剩错误窗时请求会被静默丢弃（2026-07-29 实测），而每个窗口都有 RootView。
            //
            // ⚠️ 两处易错，都踩过：
            // ① **冷启动这一下不归这里管**：那时窗口正在建，缓冲要留给 `resolve` 消费。若这里也插手，
            //    就会既在本窗口 resolve 一次、又路由出一个新窗口 = 两个窗口开同一个工作区。
            // ② **不能用 `isKeyWindow` 当认领条件**（异步回填，冷启动时全为假，所有窗口一起跳过 =
            //    请求静默丢弃，这正是双击一直没反应的老根因）。改用「谁 consume 到缓冲谁处理」：
            //    消费是一次性的且都在主线程，天然选出唯一认领者，也不会漏。
            guard let path = note.object as? String else { return }
            guard AppDelegate.didFinishLaunching else {
                wsLog("收到 openWorkspaceRequested：冷启动中，留给 resolve 处理")
                return
            }
            guard AppDelegate.consumePendingWorkspace() != nil else { return }   // 已被别的窗口认领
            wsLog("收到 openWorkspaceRequested（热启动）：路由 \(path)")
            do {
                try WorkspaceRegistry.shared.route(to: URL(fileURLWithPath: path), strict: true,
                                                   openWindow: openWindow)
            } catch {
                routeError = error.localizedDescription
            }
        }
        .alert(L("Workspace Error"),
               isPresented: Binding(get: { routeError != nil }, set: { if !$0 { routeError = nil } })
        ) {
            Button(L("OK")) {}
        } message: {
            Text(routeError ?? "")
        }
    }

    /// 本窗口该显示什么。**不用 `Group`**：Group 会把外层修饰符逐个下发给它的分支，
    /// 生命周期钩子容易跟着分支切换空放（这条链路已经被 onDisappear 坑过一次）。
    @ViewBuilder
    private var content: some View {
        if selfClose || isStrayWindow {
            // 赶在上屏之前撤下并关掉。**不能用 `.frame(width: 0, height: 0)`**——零尺寸时
            // SwiftUI 根本不会创建那个 NSView，`viewDidMoveToWindow` 永不触发，窗口就留在屏幕上了
            // （实测：判定了 4 次，只关掉 2 个）。挂在撑满的 Color.clear 背景上才保证被挂载。
            Color.clear.background(WindowCloser())
        } else if let workspace {
            ContentView(launchDocId: target?.docId)
                .environmentObject(workspace)
        } else if let failure {
            ContentUnavailableView {
                Label(L("Cannot Open Workspace"), systemImage: "exclamationmark.triangle")
            } description: {
                Text(failure)
            }
        } else {
            // 决定中（冷启动等 didFinishLaunching，见 resolve()）。留白而非转圈：这一步通常
            // 只有几十毫秒，转圈反而闪一下。
            Color.clear
        }
    }

    /// 定下本窗口的工作区。三种来源，按优先级：
    ///  ① `target.workspacePath` —— 显式指定（双击 .unrd 开的新窗口、「在新窗口打开文档」）；
    ///  ② 冷启动缓冲 —— 双击 .unrd 拉起 app 的那一下（见 AppDelegate.pendingWorkspacePath）；
    ///  ③ 上次使用的工作区 —— 普通启动 / ⌘N。
    ///
    /// ⚠️ **② 必须等到 `applicationDidFinishLaunching` 之后才能判定**（2026-07-29 日志钉死的时序）：
    /// `onAppear` 早于 AppKit 投递 open 事件，此刻缓冲还是空的，直接落到 ③ 就会先开上一个工作区、
    /// 事件到达后再切走（用户能看到那段来回切换）。故 `onAppear` 时若启动尚未完成就**挂起不决定**，
    /// 等 `didFinishLaunching` 通知再来一次——那一刻缓冲必然已就位。
    private func resolve(from source: String) {
        guard workspace == nil, failure == nil else { return }

        var folder: URL?
        var strict = true   // ①② 是用户指着某个具体工作区说「打开它」，必须是真实工作区
        if let p = target?.workspacePath {
            folder = URL(fileURLWithPath: p)
        } else if let p = AppDelegate.consumePendingWorkspace() {
            wsLog("RootView.resolve(\(source))：消费到冷启动缓冲 \(p)")
            folder = URL(fileURLWithPath: p)
        } else if AppDelegate.didFinishLaunching {
            folder = WorkspaceRegistry.shared.lastOrDefaultFolder()
            strict = false   // ③ 是兜底：首次启动要靠它在默认位置**建**库，校验必然失败
            wsLog("RootView.resolve(\(source))：用上次/默认工作区 \(folder?.path ?? "nil")")
        } else {
            wsLog("RootView.resolve(\(source))：启动未完成，挂起等 didFinishLaunching")
            return
        }
        guard let folder else { return }

        do {
            // 冷启动双击的这一下（②）与热启动走的 `routeToWorkspace` 必须是**同一种严格**：
            // 不然同一个手势会因 app 当时开没开而两种行为——热启动弹「这不是工作区」，
            // 冷启动却在那个包里静默建一个空库（`LibraryStore` 缺库即建），正是 §8 要根除的表现。
            if strict { try WorkspaceManager.validate(folder) }
            let m = try WorkspaceRegistry.shared.acquire(folder: folder)
            workspace = m
            // 登记「本窗口持有这个实例」——窗口关闭时由 registry 替它放手（关闭回调只带 windowId）。
            WorkspaceRegistry.shared.bindRootWindow(windowId, m)
            wsLog("RootView.resolve(\(source))：绑定工作区 \(workspace?.folder?.path ?? "nil")")
        } catch {
            failure = error.localizedDescription
            wsLog("RootView.resolve(\(source))：失败 \(error.localizedDescription)")
        }
    }
}
