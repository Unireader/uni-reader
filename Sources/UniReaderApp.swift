import SwiftUI
import AppKit

/// 单实例守卫（新实例接管 / last-wins）：本次启动时若已有同一 App 在跑，
/// 优雅终止旧实例并接管——释放局域网服务端口（8770/8771），杜绝多份状态与端口冲突。
/// 选 last-wins 而非 first-wins：Xcode 每次 Run = 新进程，需保证看到的永远是最新构建，
/// 且旧进程即便未被及时回收也会被这里清掉。正式发布如需「第二次打开只激活已有窗口」再切 first-wins。
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        guard let bundleId = Bundle.main.bundleIdentifier else { return }
        let me = NSRunningApplication.current
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId)
            .filter { $0.processIdentifier != me.processIdentifier && !$0.isTerminated }
        for other in others { other.terminate() }   // 优雅退出：旧实例走正常关窗流程（存进度）并释放端口
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

        Window(L("Simulated Tablet"), id: "simPad") {
            SimPadView()
                .environmentObject(app)
                .environmentObject(workspace)
                .frame(minWidth: 360, minHeight: 480)
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
        }
    }
}

extension Notification.Name {
    static let openPDFRequested = Notification.Name("com.xvan.UniReader.openPDFRequested")
    static let readerFind = Notification.Name("com.xvan.UniReader.readerFind")
}
