import AppKit
import SwiftUI

/// 设置窗（⌘,）。迁移前是 SwiftUI 的 `Settings` scene；现在是一扇普通窗口装
/// `NSHostingController(SettingsView)`，**全 app 只有一扇**（再按 ⌘, 是把它调到前面）。
@MainActor
final class SettingsWindowController: NSWindowController {
    private static var shared: SettingsWindowController?

    static func show() {
        if let c = shared, c.window != nil {
            c.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        guard let app = AppDelegate.shared?.appModel else { return }
        let c = SettingsWindowController(app: app)
        shared = c
        c.window?.center()
        c.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    init(app: AppModel) {
        let host = NSHostingController(rootView: SettingsView().environmentObject(app))
        let win = NSWindow(contentViewController: host)
        win.title = L("Settings")
        win.styleMask = [.titled, .closable, .miniaturizable]
        win.isReleasedWhenClosed = false
        super.init(window: win)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) 不支持") }
}

/// AI 面板浮窗（⇧⌘A 的「浮窗模式」）。**全局唯一**——迁移前用 `Window` scene 表达的正是这个语义
/// （每家平台一个 WebPage 已经够用，还顺带绕开「一个 WKWebView 不能同时挂两个视图」）。
@MainActor
final class AIPanelWindowController: NSWindowController {
    private static var shared: AIPanelWindowController?

    static func show() {
        if let c = shared, c.window != nil {
            c.window?.makeKeyAndOrderFront(nil)
            return
        }
        guard let app = AppDelegate.shared?.appModel else { return }
        let c = AIPanelWindowController(app: app)
        shared = c
        c.window?.makeKeyAndOrderFront(nil)
    }

    init(app: AppModel) {
        let host = NSHostingController(rootView: AIPanelView().environmentObject(app))
        let win = NSWindow(contentViewController: host)
        win.title = L("AI")
        win.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        win.setContentSize(NSSize(width: 480, height: 760))
        win.isReleasedWhenClosed = false
        // 紧凑工具栏（系统标准样式）：一个聊天浮窗不该拿两行去放标题。
        win.toolbarStyle = .unifiedCompact
        super.init(window: win)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) 不支持") }
}
