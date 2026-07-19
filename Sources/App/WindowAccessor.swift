import SwiftUI
import AppKit

/// 捕获所在 NSWindow，并在其成为/失去 key window 时回调（用于「最后激活窗口」追踪
/// 与把菜单命令路由到当前 key 窗口）。
struct WindowAccessor: NSViewRepresentable {
    let onKeyChange: (Bool) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { [weak view] in
            context.coordinator.observe(view?.window, onKeyChange: onKeyChange)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        private var tokens: [Any] = []

        func observe(_ window: NSWindow?, onKeyChange: @escaping (Bool) -> Void) {
            guard let window else { return }
            onKeyChange(window.isKeyWindow)
            let nc = NotificationCenter.default
            tokens.append(nc.addObserver(forName: NSWindow.didBecomeKeyNotification,
                                         object: window, queue: .main) { _ in onKeyChange(true) })
            tokens.append(nc.addObserver(forName: NSWindow.didResignKeyNotification,
                                         object: window, queue: .main) { _ in onKeyChange(false) })
        }

        deinit { tokens.forEach { NotificationCenter.default.removeObserver($0) } }
    }
}
