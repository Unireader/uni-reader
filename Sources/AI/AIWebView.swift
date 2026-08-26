import AppKit
import Combine
import SwiftUI
import WebKit

/// 一份长驻的网页（我们自己持有的 `WKWebView` + 它的可观察状态）。
///
/// 🔴 **为什么不用 macOS 26 那套 SwiftUI `WebView`/`WebPage`。**
/// 那套把 webview 的生命周期交给框架：视图一被重建，SwiftUI 就再造一个 `WebView` 去挂同一个
/// `WebPage`，WebKit 当场 trap（`_WebKit_SwiftUI.makeViewProvider`）。2026-08-26 为此崩了四次，
/// 每次我都在找「一个保证不会被重建的挂载点」——**那个前提本身不成立**，SwiftUI 有权随时重建任何视图。
///
/// 现在换成：**webview 归我们自己持有**，SwiftUI 那边只是一个稳定的容器
/// （`AIWebHost` → `makeNSView` 返回一个空 `NSView`，`updateNSView` 把 webview 挂进去）。
/// 视图重建时只是把**同一个** NSView 重新挂一次父——AppKit 的 `addSubview` 本来就会先从旧父移除，
/// 合法、幂等、最多闪一下，**不可能 trap**。
///
/// 换个说法：把「不能有两个 WebView 挂同一个 page」这条约束，从「靠视图树的时序维持」
/// 变成「压根只有一个 webview 对象」。
@MainActor
final class AIPageBox: ObservableObject {
    let web: AIWebView

    /// 常驻容器：**webview 的父视图永远是它，从不更换**。SwiftUI 那边重建时移动的是这个容器，
    /// webview 底下整棵渲染树原封不动 —— 比直接搬 webview 少一次重排，闪得轻得多。
    let container = NSView()

    // 供 SwiftUI 读的镜像状态（KVO → @Published）。
    @Published private(set) var url: URL?
    @Published private(set) var title: String = ""
    @Published private(set) var isLoading = false
    @Published private(set) var progress: Double = 0
    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false

    private var observations: [NSKeyValueObservation] = []

    /// 挂过这份网页的外壳（弱表）。用来在**持有者离场**时把容器转交给还在窗口里的那一个。
    private let shells = NSHashTable<AIWebShell>.weakObjects()

    func register(_ shell: AIWebShell) { shells.add(shell) }

    /// 容器的当前持有者要离场了 → 找一个**还在窗口里**的外壳接手。
    ///
    /// 补的是这个缺口：被拆的外壳可能在离开窗口**之前**刚好抢走了容器，而活着的那个不一定会
    /// 再来一次布局（`layout()` 不保证被调用），于是容器就悬着，面板空白到下次更新为止。
    func rehome() {
        guard let target = shells.allObjects.first(where: { $0.window != nil }) else { return }
        target.claimNow()
    }

    init(configuration: WKWebViewConfiguration, userAgent: String?) {
        web = AIWebView(frame: .init(x: 0, y: 0, width: 800, height: 600),
                        configuration: configuration)
        if let userAgent { web.customUserAgent = userAgent }
        web.allowsBackForwardNavigationGestures = true
        web.allowsMagnification = true
        // S3 要靠 Web Inspector 调适配器脚本；正式发布前再决定是否收起来。
        web.isInspectable = true

        // 图层化 + Auto Layout 钉死四边。
        // 不用 autoresizingMask：新容器初始 bounds 是 .zero，先把 webview 压成 0×0 再撑开，
        // WebKit 会整页重排一次 —— 那是闪烁的另一半。
        container.wantsLayer = true
        web.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(web)
        NSLayoutConstraint.activate([
            web.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            web.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            web.topAnchor.constraint(equalTo: container.topAnchor),
            web.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        observe()
    }

    /// `url`/`title`/`isLoading`/`estimatedProgress`/`canGoBack`/`canGoForward` 都是 KVO 兼容的，
    /// 镜像成 `@Published` 供 SwiftUI 用（`WebPage` 那套 Observation 的替代）。
    private func observe() {
        func bind<V>(_ kp: KeyPath<AIWebView, V>, _ apply: @escaping @MainActor (V) -> Void) {
            observations.append(web.observe(kp, options: [.initial, .new]) { web, _ in
                let value = web[keyPath: kp]
                Task { @MainActor in apply(value) }
            })
        }
        bind(\.url) { [weak self] in self?.url = $0 }
        bind(\.title) { [weak self] in self?.title = $0 ?? "" }
        bind(\.isLoading) { [weak self] in self?.isLoading = $0 }
        bind(\.estimatedProgress) { [weak self] in self?.progress = $0 }
        bind(\.canGoBack) { [weak self] in self?.canGoBack = $0 }
        bind(\.canGoForward) { [weak self] in self?.canGoForward = $0 }
    }

    // MARK: 操作

    func load(_ url: URL?) {
        guard let url else { return }
        web.load(URLRequest(url: url))
    }

    func reload() { web.reload() }
    func stop() { web.stopLoading() }
    func goBack() { web.goBack() }
    func goForward() { web.goForward() }

    /// 在 page world 里跑一段 JS（发送适配器、页内查找都走它）。
    @discardableResult
    func callJS(_ body: String, arguments: [String: Any] = [:]) async -> Any? {
        try? await web.callAsyncJavaScript(body, arguments: arguments,
                                           in: nil, contentWorld: .page)
    }

    /// 显式拆掉：停加载、断 KVO、从视图层级摘下来。不等 ARC（同 §8.1 的既有纪律）。
    func teardown() {
        web.stopLoading()
        observations.forEach { $0.invalidate() }
        observations.removeAll()
        container.removeFromSuperview()
    }
}

/// 我们自己的 `WKWebView` 子类，只为一件事：**在系统右键菜单上加一项**，而不是把它整个换掉。
///
/// 早先用 SwiftUI 的 `.webViewContextMenu` 时，系统菜单是被**取代**的——剪切/拷贝/粘贴、
/// 查询、服务全没了，只能自己一条条补回来（还补不全）。`willOpenMenu` 是追加，原生菜单原样保留。
final class AIWebView: WKWebView {
    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)
        let panel = AIPanelModel.shared
        guard panel.canMakeNote else { return }
        let item = NSMenuItem(title: L("Add to Text Notes"),
                              action: #selector(addSelectionToNotes(_:)), keyEquivalent: "")
        item.target = self
        menu.insertItem(item, at: 0)
        menu.insertItem(.separator(), at: 1)
    }

    @objc private func addSelectionToNotes(_ sender: Any?) {
        AIPanelModel.shared.requestNoteFromSelection()
    }
}

/// 承载壳：SwiftUI 那边的一层普通 `NSView`，负责把 `box.container` 拉到自己底下。
///
/// 🔴 **「谁在窗口里，谁才有资格抢」** —— 这是整块能自愈的关键。
///
/// 2026-08-26 踩过：外壳被 SwiftUI 拆除时，会把当时挂在它里面的常驻容器一并带走；而**活着的那个
/// 外壳不会再收到 `updateNSView`**（它的输入没变），于是容器再也回不来 —— 面板整块空白，
/// 直到用户碰个快捷键触发一次更新才恢复。
///
/// 所以不能只在 `updateNSView` 里挂：外壳自己在 `viewDidMoveToWindow` / `layout` 里检查并抢回来，
/// 且**只有 `window != nil` 时才抢**。于是：
///  · 刚建好还没进窗口的外壳 → 不抢（不会从活着的那个手里偷走）
///  · 正在被拆、已离开窗口的外壳 → 不抢（也就带不走）
///  · 真正在显示的那个 → 每次布局都会把容器拉回来（自愈，不依赖 SwiftUI 什么时候更新）
final class AIWebShell: NSView {
    var box: AIPageBox? {
        didSet {
            box?.register(self)
            claim()
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            // 自己要离场了：若容器还在我这儿，交给还在窗口里的外壳。
            if box?.container.superview === self { box?.rehome() }
        } else {
            claim()
        }
    }

    override func layout() {
        super.layout()
        claim()
        box?.container.frame = bounds
    }

    /// 供 `AIPageBox.rehome()` 调用的对外入口。
    func claimNow() { claim() }

    private func claim() {
        guard window != nil, let container = box?.container else { return }
        guard container.superview !== self else { return }
        // 不显式 removeFromSuperview：`addSubview` 本来就会先从旧父摘掉，一步到位少一帧空档。
        container.frame = bounds
        addSubview(container)
    }
}

/// SwiftUI 侧的承载壳（见 `AIWebShell`）。
struct AIWebHost: NSViewRepresentable {
    /// ⚠️ 必须是**存储属性**：存储属性不变时 SwiftUI 会跳过 `updateNSView`
    /// （`WindowAccessor.swift` 里记过同款坑），换了 box 就挂不过去。
    let box: AIPageBox

    func makeNSView(context: Context) -> AIWebShell {
        let shell = AIWebShell()
        shell.wantsLayer = true
        shell.autoresizesSubviews = false      // 容器的 frame 由 `layout()` 直接给
        shell.box = box
        return shell
    }

    func updateNSView(_ shell: AIWebShell, context: Context) {
        if shell.box !== box { shell.box = box }
        shell.needsLayout = true               // 触发一次 claim（万一容器被别处带走了）
    }
}
