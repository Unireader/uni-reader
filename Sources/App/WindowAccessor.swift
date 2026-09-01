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

/// 给 SwiftUI 的工具栏 delegate 包一层，**只改一件事**：修整「自定工具栏…」面板的可选项清单
/// （空格类只留一份、滤掉 SwiftUI 那两个一次性 UUID 项）。其余方法一律原样转发。
///
/// 为什么要包：AppKit 的惯例是 `NSToolbarSpaceItem`/`NSToolbarFlexibleSpaceItem` 在 allowed 里
/// 只报**一次**（面板给你一个「空格」，往工具栏里想拖几个拖几个），而 SwiftUI 是有几个
/// `ToolbarSpacer` 就报几次——我们三个分组分隔加上它自己在最前和搜索框前塞的两个，面板里就是
/// 一排一模一样的「空格 / 可变宽度空格」（2026-09-01 用户报）。`.customizationBehavior(.disabled)`
/// 管不着这个。
///
/// 🔴 **只去重 allowed，不动 default**：default 是**实际摆放**，那三个空格正是四个玻璃胶囊的
/// 分界，去掉分组就没了。
///
/// 🔴 **`NSToolbar.delegate` 是 weak**：包完之后原 delegate 必须有人强持有，否则 SwiftUI 那个
/// 对象没人要了会当场释放、工具栏变空。所以这里强引用它。
final class ToolbarDelegateFilter: NSObject, NSToolbarDelegate {
    private let wrapped: NSToolbarDelegate

    init(wrapping d: NSToolbarDelegate) { wrapped = d }

    func wraps(_ d: NSToolbarDelegate) -> Bool { wrapped === d }

    private func cleaned(_ ids: [NSToolbarItem.Identifier]) -> [NSToolbarItem.Identifier] {
        var seen = Set<NSToolbarItem.Identifier>()
        return ids.filter { id in
            if id == .space || id == .flexibleSpace { return seen.insert(id).inserted }
            return !isEphemeral(id)
        }
    }

    /// SwiftUI 给标题/副标题区生成的内部项：标识符是**每次启动都不一样的 UUID**
    /// （2026-09-01 三次运行三组不同的值，日志实测），面板里显示成 «Open PDF…»、«301» 这种
    /// 当时的窗口标题/页码。既没有稳定身份（autosave 记下来下次也对不上）、也不该让用户拖动，
    /// 所以不进 allowed —— **只挡面板，不动 default**，工具栏上照旧显示。
    ///
    /// 判据只认「36 字符的标准 UUID 形态」，我们自己的 id（`zoom.out` 那些）与系统的
    /// `com.apple.*` 都不会被误伤。
    private func isEphemeral(_ id: NSToolbarItem.Identifier) -> Bool {
        UUID(uuidString: id.rawValue) != nil
    }

    // MARK: 转发

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        cleaned(wrapped.toolbarAllowedItemIdentifiers?(toolbar) ?? [])
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        wrapped.toolbarDefaultItemIdentifiers?(toolbar) ?? []
    }

    func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        wrapped.toolbarSelectableItemIdentifiers?(toolbar) ?? []
    }

    func toolbarImmovableItemIdentifiers(_ toolbar: NSToolbar) -> Set<NSToolbarItem.Identifier> {
        wrapped.toolbarImmovableItemIdentifiers?(toolbar) ?? []
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        wrapped.toolbar?(toolbar, itemForItemIdentifier: id, willBeInsertedIntoToolbar: flag)
    }

    func toolbar(_ toolbar: NSToolbar, itemIdentifier: NSToolbarItem.Identifier,
                 canBeInsertedAt index: Int) -> Bool {
        wrapped.toolbar?(toolbar, itemIdentifier: itemIdentifier, canBeInsertedAt: index) ?? true
    }

    func toolbarWillAddItem(_ notification: Notification) {
        wrapped.toolbarWillAddItem?(notification)
    }

    func toolbarDidRemoveItem(_ notification: Notification) {
        wrapped.toolbarDidRemoveItem?(notification)
    }
}

/// 打开窗口工具栏的「自定工具栏…」。
///
/// 🔴 **`.toolbar(id:)` 自己不会打开它**：2026-09-01 用户实测，改成可定制工具栏之后右键工具栏
/// 仍然只有「图标和文本 / 仅图标 …」那几项显示模式，没有「自定工具栏…」——即 NSToolbar 的
/// `allowsUserCustomization` 还是 false，那条菜单项由 AppKit 按这个开关决定给不给。
/// SwiftUI 那边没有对应的修饰符可用，所以这里补一刀 AppKit（只碰这两个开关，不接管工具栏内容）。
///
/// ⚠️ **必须重试**：工具栏是 SwiftUI 在窗口上屏之后才装配的，`viewDidMoveToWindow` 这一拍
/// `window.toolbar` 常常还是 nil；只设一次的话就是「设了个寂寞」。日志一行写清当时的状态
/// （`touch ~/Library/Logs/UniReader-ws.log` 开），下次再哑火一眼能分清是没 toolbar 还是设了没用。
struct ToolbarCustomizationEnabler: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { EnablerView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class EnablerView: NSView {
        private var token: Any?
        private var kvo: [NSKeyValueObservation] = []
        private var refixes = 0
        /// 面板可选项去重层（见 `ToolbarDelegateFilter`）。自己也持一份：SwiftUI 若把
        /// `toolbar.delegate` 换回它自己，下一拍要拿它原样装回去，不必重新包一个。
        private var filter: ToolbarDelegateFilter?
        private var refilters = 0

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let w = window else { return }
            enable(attempt: 0)
            // 🔴 **设一次不够**：SwiftUI 每次重建工具栏内容都会重新配置这个 NSToolbar，
            // 很可能把开关拍回 false（本 app 的工具栏内容跟着 `session` 变，重建很频繁）。
            // 挂窗口的 didUpdate 通知持续纠正——回调里只读一个 Bool，不满足条件立刻返回。
            guard token == nil else { return }
            token = NotificationCenter.default.addObserver(
                forName: NSWindow.didUpdateNotification, object: w, queue: .main
            ) { [weak self] _ in self?.reassert() }
        }

        deinit { if let token { NotificationCenter.default.removeObserver(token) } }

        private func enable(attempt: Int) {
            guard let w = window else { return }
            if let tb = w.toolbar {
                tb.allowsUserCustomization = true
                tb.autosavesConfiguration = true
                installFilter(tb)
                watch(tb)
                // 回读：设完立刻再读一次，才知道是「设不进去」还是「设进去了又被拍回」。
                wsLog("工具栏：id=\(tb.identifier) items=\(tb.items.count) 第 \(attempt) 拍"
                      + " → 设置后 可定制=\(tb.allowsUserCustomization)"
                      + " 自动保存=\(tb.autosavesConfiguration)")
                dumpStructure(tb)
                return
            }
            guard attempt < 15 else { wsLog("工具栏：等了 15 拍仍然没有 NSToolbar，放弃"); return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                self?.enable(attempt: attempt + 1)
            }
        }

        /// 把 NSToolbar 的真实结构打进日志：自定工具栏面板里**能单独拖的单位**就是这些
        /// identifier，若 SwiftUI 把相邻按钮合成了 `NSToolbarItemGroup`，那一组在面板里就是
        /// 一整块、拆不开（2026-09-01 用户报「是一整个巨大的组」）。allowed/default 两行是
        /// delegate 报给面板的清单——面板里列什么，以它为准。
        private func dumpStructure(_ tb: NSToolbar) {
            let ids = tb.items.map { it -> String in
                // 带上 label/paletteLabel：面板里那几个 UUID 项到底是什么，只有名字认得出来
                let name = it.paletteLabel.isEmpty ? it.label : it.paletteLabel
                let tag = name.isEmpty ? "" : "«\(name)»"
                if let g = it as? NSToolbarItemGroup {
                    let subs = g.subitems.map { $0.itemIdentifier.rawValue }.joined(separator: ",")
                    return "\(it.itemIdentifier.rawValue)\(tag)[组:\(g.subitems.count)={\(subs)}]"
                }
                return it.itemIdentifier.rawValue + tag
            }
            wsLog("工具栏 items: " + ids.joined(separator: " | "))
            guard let d = tb.delegate else { wsLog("工具栏 delegate: 无"); return }
            let allowed = (d.toolbarAllowedItemIdentifiers?(tb) ?? []).map(\.rawValue)
            let def = (d.toolbarDefaultItemIdentifiers?(tb) ?? []).map(\.rawValue)
            wsLog("工具栏 allowed(\(allowed.count)): " + allowed.joined(separator: " | "))
            wsLog("工具栏 default(\(def.count)): " + def.joined(separator: " | "))
        }

        /// KVO 盯住那个开关：SwiftUI 一把它拍回 false，这里当场改回来。
        ///
        /// 🔴 **不能只靠它**：`allowsUserCustomization` 是不是 KVO-compliant，AppKit 没有承诺
        /// （NSToolbar 的属性来自 ObjC，通常是，但「通常」不算数）。所以下面 `reassert` 那条
        /// 走窗口 didUpdate 的兜底照旧留着——静默失效是本项目吃过亏的那类 bug，宁可两条路都在。
        /// 日志标了来源，长跑之后一看就知道哪条在干活、另一条能不能撤。
        private func watch(_ tb: NSToolbar) {
            guard kvo.isEmpty else { return }
            kvo.append(tb.observe(\.allowsUserCustomization, options: [.new]) { [weak self] tb, _ in
                guard !tb.allowsUserCustomization else { return }
                tb.allowsUserCustomization = true
                tb.autosavesConfiguration = true
                self?.noteRefix("KVO")
            })
        }

        /// 兜底：窗口每次 update 检查一次（回调里只读一个 Bool，不满足立刻返回）。
        /// 顺带看住 delegate ——那个换手 KVO 盯不住（weak 属性的 KVO 更不牢靠）。
        private func reassert() {
            guard let tb = window?.toolbar else { return }
            if !tb.allowsUserCustomization {
                tb.allowsUserCustomization = true
                tb.autosavesConfiguration = true
                noteRefix("didUpdate")
            }
            installFilter(tb)
        }

        /// 纠正计数。**第 1 次 + 此后每 20 次**记一行：它可能每帧都发生，每次都写就把日志淹了，
        /// 一次不写又会让「到底还在不在发生」变成无法回答的问题。
        private func noteRefix(_ source: String) {
            refixes += 1
            guard refixes == 1 || refixes % 20 == 0 else { return }
            wsLog("工具栏：allowsUserCustomization 被 SwiftUI 拍回 false，已纠正"
                  + "（来源=\(source) 累计 \(refixes) 次）")
        }

        /// 装上去重层。三种情形分别处理：已经是我们的 → 什么都不做；换回了**同一个**原 delegate
        /// → 把旧 filter 装回去；换成了另一个 delegate → 重新包一个。
        private func installFilter(_ tb: NSToolbar) {
            guard let d = tb.delegate else { return }
            if let f = filter {
                if d === f { return }
                if f.wraps(d) {
                    tb.delegate = f
                    refilters += 1
                    if refilters <= 3 { wsLog("工具栏 delegate：被换回原样，已重新装上去重层（第 \(refilters) 次）") }
                    return
                }
            }
            let f = ToolbarDelegateFilter(wrapping: d)
            filter = f
            tb.delegate = f
            wsLog("工具栏 delegate：已包上空格去重层")
        }
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
