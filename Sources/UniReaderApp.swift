import SwiftUI
import AppKit

/// 用于区分「用户关某个窗口」与「整个 app 退出」：退出时不收缩工作区打开文档集，留给下次恢复。
final class AppDelegate: NSObject, NSApplicationDelegate {
    static var isTerminating = false
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        AppDelegate.isTerminating = true
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

        Window(L("Simulated Tablet"), id: "simPad") {
            SimPadView()
                .environmentObject(app)
                .environmentObject(workspace)
                .frame(minWidth: 360, minHeight: 480)
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
        }
    }
}

extension Notification.Name {
    static let openPDFRequested = Notification.Name("com.xvan.UniReader.openPDFRequested")
}
