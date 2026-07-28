import SwiftUI
import AppKit

/// 捕获所在 NSWindow，并在其成为/失去 key window 时回调（用于「最后激活窗口」追踪
/// 与把菜单命令路由到当前 key 窗口）。
struct WindowAccessor: NSViewRepresentable {
    /// 非 nil 时同步为窗口标题（window.title）。过长无需手动截断——macOS 标题栏自动以「…」缩略。
    var title: String? = nil
    let onKeyChange: (Bool) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.latestTitle = title
        DispatchQueue.main.async { [weak view, coordinator = context.coordinator] in
            // 注意读 coordinator.latestTitle 而非本闭包捕获的 title：启动恢复 PDF 时
            // updateNSView 已把窗口标题改成文档名，这里若用旧捕获值会把它覆盖回「书库」。
            if let t = coordinator.latestTitle { view?.window?.title = t }
            coordinator.observe(view?.window, onKeyChange: onKeyChange)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.latestTitle = title
        if let title, let window = nsView.window, window.title != title {
            window.title = title
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        /// 最近一次 SwiftUI 侧传入的窗口标题（makeNSView 异步块据此取值，见上）。
        var latestTitle: String?
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
