import SwiftUI

@main
struct UniReaderApp: App {
    @StateObject private var app = AppModel()
    @StateObject private var workspace = WorkspaceManager()

    var body: some Scene {
        WindowGroup {
            ContentView()
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
        }
    }
}

extension Notification.Name {
    static let openPDFRequested = Notification.Name("com.xvan.UniReader.openPDFRequested")
}
