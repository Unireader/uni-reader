import SwiftUI
import AppKit

/// 工作区打开链路的诊断日志（`[WS-OPEN]` 前缀）。
/// 这条链路横跨 LaunchServices → AppDelegate → 通知/冷启动缓冲 → ContentView，任一环静默断掉
/// 都只表现为「双击 .unrd 没反应」，从表象反推排不出来（已为此改错两轮）。统一打点后，答案是
/// **日志里该有却没有的那一行**。
/// 打开工作区链路的诊断日志。**文件通道默认关闭**——只在日志文件已存在时才追加：
/// ```
/// touch ~/Library/Logs/UniReader-ws.log    # 开启
/// rm    ~/Library/Logs/UniReader-ws.log    # 关闭
/// ```
/// 为什么要自建通道而不用系统日志：双击启动的 app 不挂在 Xcode 控制台下（`print` 看不到），
/// 而 unified logging（`log show`/`log stream`）在这台机器上**抓不到本 app 的任何输出**
/// （2026-07-29 实测：按进程过滤零条记录，连系统框架的日志都没有）。这条链路又横跨
/// LaunchServices → AppDelegate → 通知 → ContentView，任一环静默断掉都只表现为「双击没反应」，
/// 已为此改错三轮——留个随时可开、平时零开销的观察窗口。
let wsLogURL = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Logs/UniReader-ws.log")

func wsLog(_ msg: String) {
    NSLog("[WS-OPEN] %@", msg)   // Xcode 里跑时直接可见
    guard let h = try? FileHandle(forWritingTo: wsLogURL) else { return }   // 文件不存在 = 通道关闭
    defer { try? h.close() }
    let line = "\(Date.now.formatted(date: .omitted, time: .standard)) [\(ProcessInfo.processInfo.processIdentifier)] \(msg)\n"
    guard let data = line.data(using: .utf8) else { return }
    _ = try? h.seekToEnd()
    try? h.write(contentsOf: data)
}

/// 单实例守卫（新实例接管 / last-wins）：本次启动时若已有同一 App 在跑，
/// 优雅终止旧实例并接管——释放局域网服务端口（8770/8771），杜绝多份状态与端口冲突。
/// 选 last-wins 而非 first-wins：Xcode 每次 Run = 新进程，需保证看到的永远是最新构建，
/// 且旧进程即便未被及时回收也会被这里清掉。正式发布如需「第二次打开只激活已有窗口」再切 first-wins。
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// 是否正在退出（cmd+q / 被单实例守卫接管）。用于区分「退出关窗」vs「cmd+w 单独关窗」：
    /// 退出时**不修改**工作区「打开集」（下次启动原样恢复所有窗口）；cmd+w 才逐个移除。
    /// `applicationShouldTerminate` 在各窗口 `onDisappear` **之前**触发，故此标志对关窗回调可见。
    static var isTerminating = false

    /// 冷启动时被双击/拖入的 .unrd 路径（视图树尚未就绪、通知无人接收时兜底），首个窗口 onAppear 消费。
    static var pendingWorkspacePath: String?

    /// Finder 双击 / 拖到 Dock 图标的 .unrd 工作区包（**现代入口**）。
    /// AppKit 只要 delegate 实现了这个方法就一律走它，下面那个 `openFile:` 版本便再也不会被调用
    /// （`openFile:`/`openFiles:` 都是 deprecated 的旧签名）。两个都留着并各自打点，日志即可判明
    /// 系统实际投递到了哪一条。
    func application(_ application: NSApplication, open urls: [URL]) {
        wsLog("application(open:) urls=\(urls.map(\.path))")
        guard let u = urls.first(where: { $0.pathExtension == WorkspaceManager.packageExtension }) else {
            wsLog("application(open:) 里没有 .\(WorkspaceManager.packageExtension) 包，忽略")
            return
        }
        Self.deliverWorkspace(u.path)
    }

    /// 同上的旧签名入口（保留兜底：万一某条路径/某个系统版本仍走它）。
    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        wsLog("application(openFile:) \(filename)")
        Self.deliverWorkspace(filename)
        return true
    }

    /// 统一投递：冷启动缓冲 + 发通知。两个入口共用，并做一次短时去重
    /// （同一路径 1s 内只投一次），免得将来两条都被调用时把工作区切两遍。
    static func deliverWorkspace(_ path: String) {
        let now = Date.now
        if let last = lastDelivered, last.path == path, now.timeIntervalSince(last.at) < 1 {
            wsLog("重复投递，忽略：\(path)")
            return
        }
        lastDelivered = (path, now)
        pendingWorkspacePath = path
        wsLog("投递 → 置 pendingWorkspacePath + 发通知：\(path)")
        NotificationCenter.default.post(name: .openWorkspaceRequested, object: path)
    }

    private static var lastDelivered: (path: String, at: Date)?

    /// 取出并清空冷启动缓冲的工作区路径（只消费一次，避免多窗口重复切换）。
    static func consumePendingWorkspace() -> String? {
        defer { pendingWorkspacePath = nil }
        return pendingWorkspacePath
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        guard let bundleId = Bundle.main.bundleIdentifier else { return }
        let me = NSRunningApplication.current
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId)
            .filter { $0.processIdentifier != me.processIdentifier && !$0.isTerminated }
        wsLog("willFinishLaunching：单实例守卫将终止 \(others.count) 个旧实例")
        for other in others { other.terminate() }   // 优雅退出：旧实例走正常关窗流程（存进度）并释放端口
    }

    /// 首个窗口该显示什么，要等到这里才能决定 —— 见 `ContentView.decideInitialContent`。
    /// AppKit 保证「双击文档启动」的 open 事件在本回调**之前**投递，故此刻 `pendingWorkspacePath`
    /// 必然已经就位（若确实是双击启动）。
    func applicationDidFinishLaunching(_ notification: Notification) {
        wsLog("didFinishLaunching：pendingWorkspacePath=\(Self.pendingWorkspacePath ?? "nil")")
        Self.didFinishLaunching = true
        NotificationCenter.default.post(name: .appDidFinishLaunching, object: nil)
    }

    /// 是否已过 `applicationDidFinishLaunching`（= 冷启动的 open 事件窗口已关闭）。
    static var didFinishLaunching = false

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Self.isTerminating = true
        return .terminateNow
    }
}

@main
struct UniReaderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var app = AppModel()
    @StateObject private var workspace = WorkspaceManager()

    var body: some Scene {
        // 主窗口组：⌘N 开新的完整工作区窗口（方案 2）。
        WindowGroup {
            ContentView(launchDocId: nil)
                .environmentObject(app)
                .environmentObject(workspace)
        }

        // 文档窗口组：openWindow(id:"docWindow", value: docId) 在新窗口打开指定 PDF。
        WindowGroup(id: "docWindow", for: String.self) { $docId in
            ContentView(launchDocId: docId)
                .environmentObject(app)
                .environmentObject(workspace)
        }

        // 标准设置窗口（⌘,）：夜间模式自动化 / 平板滚动跟随算法 / 平板服务自启。
        Settings {
            SettingsView()
                .environmentObject(app)
        }
        .commands {
            // 保留默认「新建窗口」(⌘N)，另加「打开 PDF」(⌘O)。
            CommandGroup(after: .newItem) {
                Button(L("Open PDF…")) {
                    NotificationCenter.default.post(name: .openPDFRequested, object: nil)
                }
                .keyboardShortcut("o", modifiers: .command)
            }
            // 阅读区缩放（由 key 窗口的 PageStreamView 响应）。
            CommandGroup(after: .sidebar) {
                Divider()
                Button(L("Zoom In")) {
                    NotificationCenter.default.post(name: .readerZoomIn, object: nil)
                }
                .keyboardShortcut("=", modifiers: .command)
                Button(L("Zoom Out")) {
                    NotificationCenter.default.post(name: .readerZoomOut, object: nil)
                }
                .keyboardShortcut("-", modifiers: .command)
                Button(L("Zoom to Fit Width")) {
                    NotificationCenter.default.post(name: .readerZoomFit, object: nil)
                }
                .keyboardShortcut("0", modifiers: .command)
                Divider()
            }
            // ⌘F 查找（由 key 窗口的 ContentView 响应，弹查找栏；同一套 notification 路由已被
            // 缩放命令验证可靠，见上）。
            CommandGroup(after: .textEditing) {
                Divider()
                Button(L("Find…")) {
                    NotificationCenter.default.post(name: .readerFind, object: nil)
                }
                .keyboardShortcut("f", modifiers: .command)
            }
            // Edit 菜单剪切板组整体接管（replacing: .pasteboard）：阅读区是纯 SwiftUI 不在响应链上，
            // 系统 Copy/Select All 永远灰色。重建 5 项——文本框焦点（查找/笔记编辑器）时转发响应链，
            // 否则发通知路由到 key 窗口阅读区（PageStreamView 接收，与缩放命令同款）。
            // 只读 PDF 不支持 Cut/Paste/Delete 改文档，它们只服务文本框。
            CommandGroup(replacing: .pasteboard) {
                Button(L("Cut")) { NSApp.sendAction(#selector(NSText.cut(_:)), to: nil, from: nil) }
                    .keyboardShortcut("x")
                Button(L("Copy")) {
                    if NSApp.keyWindow?.firstResponder is NSText {
                        NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil)
                    } else {
                        NotificationCenter.default.post(name: .readerCopy, object: nil)
                    }
                }
                .keyboardShortcut("c")
                Button(L("Paste")) { NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil) }
                    .keyboardShortcut("v")
                Button(L("Delete")) { NSApp.sendAction(#selector(NSText.delete(_:)), to: nil, from: nil) }
                Button(L("Select All")) {
                    if NSApp.keyWindow?.firstResponder is NSText {
                        NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
                    } else {
                        NotificationCenter.default.post(name: .readerSelectAll, object: nil)
                    }
                }
                .keyboardShortcut("a")
            }
            // 笔架/模式快捷键（设备级全局状态，直接调 AppModel——与画布笔架、平板环形盘
            // 同一套 apply 路径，广播到平板的分支天然生效）。
            CommandGroup(after: .sidebar) {
                Divider()
                Button(String(format: L("Pen Slot %d"), 1)) { if app.pens.count > 0 { app.applyPenSelection(index: 0) } }
                    .keyboardShortcut("1", modifiers: .option)
                Button(String(format: L("Pen Slot %d"), 2)) { if app.pens.count > 1 { app.applyPenSelection(index: 1) } }
                    .keyboardShortcut("2", modifiers: .option)
                Button(String(format: L("Pen Slot %d"), 3)) { if app.pens.count > 2 { app.applyPenSelection(index: 2) } }
                    .keyboardShortcut("3", modifiers: .option)
                Button(String(format: L("Pen Slot %d"), 4)) { if app.pens.count > 3 { app.applyPenSelection(index: 3) } }
                    .keyboardShortcut("4", modifiers: .option)
                Button(L("Eraser")) { app.setPadMode("erase") }
                    .keyboardShortcut("e", modifiers: .option)
                Button(L("Page Turn")) { app.setPadMode("page") }
                    .keyboardShortcut("v", modifiers: .option)
                Button(L("Write")) { app.setPadMode("note") }
                    .keyboardShortcut("b", modifiers: .option)
                Divider()
                Button(L("Night Mode")) {
                    NotificationCenter.default.post(name: .toggleNightMode, object: nil)
                }
                .keyboardShortcut("n", modifiers: [.command, .option])
            }
        }
    }
}

extension Notification.Name {
    static let openPDFRequested = Notification.Name("com.xvan.UniReader.openPDFRequested")
    static let openWorkspaceRequested = Notification.Name("com.xvan.UniReader.openWorkspaceRequested")
    static let appDidFinishLaunching = Notification.Name("com.xvan.UniReader.appDidFinishLaunching")
    static let readerFind = Notification.Name("com.xvan.UniReader.readerFind")
    static let toggleNightMode = Notification.Name("com.xvan.UniReader.toggleNightMode")
}
