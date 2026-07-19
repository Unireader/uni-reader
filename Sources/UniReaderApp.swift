import SwiftUI
import SwiftData

@main
struct UniReaderApp: App {
    @StateObject private var app = AppModel()
    let container: ModelContainer

    init() {
        do {
            container = try ModelContainer(
                for: Document.self, DocumentLocation.self, LibraryGroup.self, Note.self
            )
        } catch {
            fatalError("无法创建 ModelContainer: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(app)
        }
        .modelContainer(container)

        Window(L("Simulated Tablet"), id: "simPad") {
            SimPadView()
                .environmentObject(app)
                .frame(minWidth: 360, minHeight: 480)
        }
        .modelContainer(container)
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
