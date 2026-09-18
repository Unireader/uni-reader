import AppKit
import Foundation

/// AI 浮窗的**吸附**：贴在当前活跃阅读窗口的右侧，并跟着它一起移动。
///
/// 跟随用的是 AppKit 的 **子窗口**（`addChildWindow`）而不是「监听 didMove 再算位移」：
/// 子窗口的跟随由窗口服务器做，拖主窗口时严丝合缝；自己算位移在快速拖动时必然掉队抖动。
/// 代价是子窗口会跟着父窗口一起关、且恒在父窗口之上——对一块「贴着书的面板」来说正是想要的。
///
/// **主窗口最大化/全屏时不吸附**：那时右边压根没有地方，硬贴会把面板顶到屏幕外
/// （用户 2026-08-26 明确「如果窗口不是最大化的情况」）。这种情况下面板保持自由浮动。
///
/// **两份实例**（2026-09-18 起）：`shared` 管咨询 AI 的浮窗，`agent` 管 Agent 面板的浮窗
/// （用户：「独立窗口没有跟随主窗口高度」）。两扇都吸附在同一扇阅读窗口上时，Agent 那扇排在咨询那扇的**右边**
/// （`besides`），不互相压住；咨询那扇重新贴边后顺手让 Agent 那扇跟着重排（`follower`）。
@MainActor
final class AIPanelDock {
    static let shared = AIPanelDock(floatingKey: "aiPanelFloating")
    static let agent: AIPanelDock = {
        let d = AIPanelDock(floatingKey: AgentPanelModel.floatingKey, besides: .shared)
        AIPanelDock.shared.follower = d
        return d
    }()

    /// 面板与主窗口之间的缝。
    static let gap: CGFloat = 8

    private weak var panel: NSWindow?
    private weak var host: NSWindow?
    private var enabled = false
    private var resizeToken: Any?
    /// 置顶开关的 UserDefaults 键（贴边后要补一次 level，见 `reapply`）。
    private let floatingKey: String
    /// 同一扇阅读窗口上已经贴着的另一扇面板：本面板排在它右边。
    private weak var besides: AIPanelDock?
    /// 排在本面板右边的那一扇：本面板位置变了要让它重排。
    private weak var follower: AIPanelDock?

    private init(floatingKey: String, besides: AIPanelDock? = nil) {
        self.floatingKey = floatingKey
        self.besides = besides
    }

    /// 本面板此刻是不是贴在 `host` 上（给排在右边的那扇找位置用）。
    fileprivate func dockedFrame(on host: NSWindow) -> NSRect? {
        guard let panel, panel.isVisible, panel.parent === host else { return nil }
        return panel.frame
    }

    /// AI 面板窗口本体（`AIPanelView` 挂载时捕获）。
    func setPanel(_ window: NSWindow?) {
        guard window !== panel else { return }
        detach()
        panel = window
        reapply()
    }

    /// 当前活跃的阅读窗口（哪扇窗口是 key 就贴哪扇）。
    func setHost(_ window: NSWindow?) {
        guard window !== host else { return }
        detach()
        host = window
        observeResize()
        reapply()
    }

    func setEnabled(_ on: Bool) {
        guard on != enabled else { return }
        enabled = on
        if on { reapply() } else { detach() }
    }

    /// 主窗口大小变了 → 重新判定还能不能吸附（变成最大化就该松开），能则重新贴边。
    private func observeResize() {
        if let resizeToken { NotificationCenter.default.removeObserver(resizeToken) }
        resizeToken = nil
        guard let host else { return }
        resizeToken = NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification, object: host, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.reapply() } }
    }

    private func detach() {
        guard let panel, let parent = panel.parent else { return }
        parent.removeChildWindow(panel)
    }

    /// 重新评估并施加吸附。条件不满足就只是松开，不去动面板的位置（用户自己摆的别乱改）。
    func reapply() {
        defer { follower?.reapply() }   // 本面板动了（或松开了），排在右边的那扇跟着重排
        guard let panel, panel.isVisible else { return }
        detach()
        guard enabled, let host, host.isVisible, canDock(host) else { return }
        // 另一扇面板已贴在同一扇阅读窗口上 → 排在它右边
        let anchor = besides?.dockedFrame(on: host) ?? host.frame
        position(panel, rightOf: anchor, host: host)
        host.addChildWindow(panel, ordered: .above)
        // ⚠️ `addChildWindow` 会把子窗口的层级拉到跟父窗口一致，把「置顶」按钮的效果抹掉 →
        // 贴完再补一次（`WindowLevelAccessor` 只在 SwiftUI 更新时跑，赶不上这一下）。
        panel.level = UserDefaults.standard.bool(forKey: floatingKey) ? .floating : .normal
    }

    /// 能不能吸附：主窗口既不是全屏、也不是（近似）铺满可用区域。
    private func canDock(_ host: NSWindow) -> Bool {
        if host.styleMask.contains(.fullScreen) { return false }
        guard let visible = host.screen?.visibleFrame else { return true }
        let f = host.frame
        // 用「近似铺满」而不是 `isZoomed`：手动拖到几乎满屏也一样没地方放面板。
        let fillsWidth = f.width >= visible.width - 24
        let fillsHeight = f.height >= visible.height - 24
        return !(fillsWidth && fillsHeight)
    }

    /// 贴到主窗口右侧、上下对齐、同高。屏幕右边放不下就贴屏幕右缘（宁可压住主窗口一点，
    /// 也别把面板推到屏幕外面去找不着）。
    /// `anchor` = 贴在谁的右边（阅读窗口本身，或已贴在它右边的另一扇面板）；高度一律跟阅读窗口。
    private func position(_ panel: NSWindow, rightOf anchor: NSRect, host: NSWindow) {
        let h = host.frame
        var f = panel.frame
        f.origin.x = anchor.maxX + Self.gap
        f.origin.y = h.minY
        f.size.height = h.height

        if let visible = (host.screen ?? NSScreen.main)?.visibleFrame {
            if f.maxX > visible.maxX { f.origin.x = max(visible.minX, visible.maxX - f.width) }
            f.size.height = min(f.size.height, visible.height)
            f.origin.y = max(visible.minY, min(f.origin.y, visible.maxY - f.size.height))
        }
        panel.setFrame(f, display: true)
    }
}
