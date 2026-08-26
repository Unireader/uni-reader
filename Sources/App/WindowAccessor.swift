import SwiftUI
import AppKit

/// 一挂进窗口层级就把所在窗口撤下并关掉——用于消灭「app 激活时 SwiftUI 凭空开出来的空窗口」
/// （判定见 `RootView.resolve` 的自毁闸）。
///
/// ⚠️ **必须用 `viewDidMoveToWindow`，不能像 `WindowAccessor` 那样 `DispatchQueue.main.async`
/// 延一拍**：延一拍时窗口已经上屏，用户会看到一个窗口闪一下再消失（2026-07-29 实测确认）。
/// `viewDidMoveToWindow` 在视图被挂进窗口层级的当下同步触发，早于窗口 orderFront，
/// 此时 `orderOut` 就能赶在它上屏之前把它撤下。`close()` 仍延一拍，避免在窗口布局途中重入。
struct WindowCloser: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { CloserView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class CloserView: NSView {
        /// 比 `viewDidMoveToWindow` 还早一步：视图**即将**挂进窗口时就把窗口设成全透明并禁掉动画。
        /// 只在 didMove 里 orderOut 仍会被瞥见——那时窗口的出现动画已由 CoreAnimation 启动，
        /// orderOut 追不上，用户能看到窗口底边冒出来一截又缩回去（2026-07-29 实测截图确认）。
        /// alphaValue=0 是即时生效的，动画就算在跑也什么都看不到。
        override func viewWillMove(toWindow newWindow: NSWindow?) {
            super.viewWillMove(toWindow: newWindow)
            newWindow?.animationBehavior = .none
            newWindow?.alphaValue = 0
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let w = window else { return }
            wsLog("关掉多余空窗口：isRestorable=\(w.isRestorable) identifier=\(w.identifier?.rawValue ?? "nil")")
            w.alphaValue = 0
            w.orderOut(nil)
            DispatchQueue.main.async { w.close() }
        }
    }
}

/// 窗口**真正关闭**的信号（AppKit `NSWindow.willCloseNotification`）。
///
/// ⚠️ **不能用 SwiftUI 的 `onDisappear` 代替**（2026-07-29 日志实测）：窗口建立过程中 `onDisappear`
/// 会**空放一次**（那时 `RootView` 还没绑定工作区），于是任何「一次性」的关窗处理都会被这一下烧掉，
/// 真关窗时反而什么都不做 —— 表现为引用计数不减、「已恢复过」的记号不归还，关掉某工作区的全部窗口
/// 再打开它得到一个空窗口。AppKit 这个通知每个窗口只发一次，且就是关闭那一刻。
struct WindowLifecycle: NSViewRepresentable {
    /// 只捕获不可变的 windowId 之类的值 —— 别在这里捕获会变的状态（闭包在挂载时就定型了）。
    let onClose: () -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { [weak view] in
            context.coordinator.observe(view?.window, onClose: onClose)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        private var token: Any?
        private var fired = false

        func observe(_ window: NSWindow?, onClose: @escaping () -> Void) {
            guard let window, token == nil else { return }
            token = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification, object: window, queue: .main
            ) { [weak self] _ in
                guard let self, !self.fired else { return }
                self.fired = true
                onClose()
            }
        }

        deinit { if let token { NotificationCenter.default.removeObserver(token) } }
    }
}

/// 捕获所在 NSWindow，并在其成为/失去 key window 时回调（用于「最后激活窗口」追踪
/// 与把菜单命令路由到当前 key 窗口）。
struct WindowAccessor: NSViewRepresentable {
    let onKeyChange: (Bool) -> Void
    /// 窗口本体（供「双击已打开的工作区 → 激活那个窗口」登记到 WorkspaceRegistry）。
    var onWindow: (NSWindow?) -> Void = { _ in }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { [weak view] in
            onWindow(view?.window)
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

/// 把所在窗口的层级设成浮动/普通——AI 面板的「置顶」开关。
///
/// ⚠️ 用 AppKit 而不是 scene 级的 `.windowLevel()`：后者对**已经开着**的窗口是否即时生效没把握，
/// 而「按了没反应」正是最难查的那类静默失效（见 `WindowCloser` 上方那段同类教训）。
/// `floating` 必须是本结构体的**存储属性**——存储属性不变时 SwiftUI 会跳过 `updateNSView`，
/// 变化值不显式传进来就永远只应用初值。
struct WindowLevelAccessor: NSViewRepresentable {
    let floating: Bool

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { [weak view] in apply(view?.window) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) { apply(nsView.window) }

    private func apply(_ window: NSWindow?) {
        window?.level = floating ? .floating : .normal
    }
}
