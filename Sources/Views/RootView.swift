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
    @State private var workspace: WorkspaceManager?
    @State private var failure: String?
    @State private var selfClose = false

    /// 本窗口是不是「SwiftUI 在 app 激活时凭空塞出来的空窗口」。
    ///
    /// ⚠️ **必须在 body 求值时判定，不能等 `onAppear`**：onAppear 是窗口**显示之后**才调用的，
    /// 那时窗口已经上屏，再 `orderOut` 就是用户看到的「闪一下又消失」（2026-07-29 实测确认）。
    /// body 求值早于视图挂载和窗口 orderFront，此刻决定才来得及。
    ///
    /// 判定三条缺一不可：没绑定过工作区（绑定了就是正经窗口，否则窗口自己注册完会把自己判成多余的
    /// 而自杀）、没指定工作区（用户开窗的两条路 ⌘N 和「打开工作区」都显式带路径）、
    /// 且它要落到的那个工作区已经有窗口了。冷启动第一个窗口不会命中：那时 didFinishLaunching 还是假。
    private var isStrayWindow: Bool {
        guard workspace == nil, failure == nil,
              target?.workspacePath == nil,
              AppDelegate.didFinishLaunching else { return false }
        return WorkspaceRegistry.shared.hasWindow(forWorkspace: WorkspaceRegistry.shared.lastOrDefaultFolder())
    }

    var body: some View {
        Group {
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
        .onAppear {
            // 已判定为多余窗口就锁定（body 里的 isStrayWindow 依赖 workspace==nil，一旦 resolve
            // 绑定了工作区它就会翻假、把这个本该关掉的窗口又显示出来），并且**不要** resolve。
            if isStrayWindow { selfClose = true; return }
            resolve(from: "onAppear")
        }
        .onReceive(NotificationCenter.default.publisher(for: .appDidFinishLaunching)) { _ in
            if isStrayWindow { selfClose = true; return }
            resolve(from: "didFinishLaunching")
        }
        .onDisappear {
            if let workspace { WorkspaceRegistry.shared.release(workspace) }
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
        if let p = target?.workspacePath {
            folder = URL(fileURLWithPath: p)
        } else if let p = AppDelegate.consumePendingWorkspace() {
            wsLog("RootView.resolve(\(source))：消费到冷启动缓冲 \(p)")
            folder = URL(fileURLWithPath: p)
        } else if AppDelegate.didFinishLaunching {
            folder = WorkspaceRegistry.shared.lastOrDefaultFolder()
            wsLog("RootView.resolve(\(source))：用上次/默认工作区 \(folder?.path ?? "nil")")
        } else {
            wsLog("RootView.resolve(\(source))：启动未完成，挂起等 didFinishLaunching")
            return
        }
        guard let folder else { return }

        do {
            // 这里的来源要么是显式指定、要么是上次用过的，都不是「用户随手选的文件夹」，
            // 故不再校验（首次启动还要靠它在默认位置建库）；用户侧入口的严格校验在 routeToWorkspace。
            workspace = try WorkspaceRegistry.shared.acquire(folder: folder)
            wsLog("RootView.resolve(\(source))：绑定工作区 \(workspace?.folder?.path ?? "nil")")
        } catch {
            failure = error.localizedDescription
            wsLog("RootView.resolve(\(source))：失败 \(error.localizedDescription)")
        }
    }
}
