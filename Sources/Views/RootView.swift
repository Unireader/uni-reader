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

    var body: some View {
        Group {
            if selfClose {
                // 兜底：系统凭空塞进来的空窗口，拿到 NSWindow 立刻关掉（判定见 resolve）。
                Color.clear.background(WindowAccessor(onKeyChange: { _ in }, onWindow: { $0?.close() }))
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
        .onAppear { resolve(from: "onAppear") }
        .onReceive(NotificationCenter.default.publisher(for: .appDidFinishLaunching)) { _ in
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

        // 兜底闸：**没指定工作区、而它解析到的工作区已经有窗口了** = 一个没人要过的空窗口。
        // 用户主动开窗的两条路都不会落到这里：⌘N 走 newWindowRequested、显式带 workspacePath；
        // 「打开工作区」也总带路径。冷启动的第一个窗口虽然没有 target，但那时还没有任何窗口登记过，
        // 也不会命中。留这道闸是因为「谁开的窗口」在 SwiftUI 侧不完全可控（见 WindowGroup 的注释）。
        if target?.workspacePath == nil, AppDelegate.didFinishLaunching,
           WorkspaceRegistry.shared.hasWindow(forWorkspace: folder) {
            wsLog("RootView.resolve(\(source))：多余空窗口（\(folder.lastPathComponent) 已有窗口），关掉自己")
            selfClose = true
            return
        }

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
