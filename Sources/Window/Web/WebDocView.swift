import AppKit
import WebKit

/// 网页标签在阅读窗格里的样子（`docs/WEB-DOC-PLAN.md §3`）：顶上一条（后退 / 前进 · 回到首页 · 重新载入 · 标题 · 在浏览器中打开），
/// 下面整块是 `WKWebView`。文件经自定义协议 `unireader-web://<网页 id>/<路径>` 从工作区的 `Web/` 里读，**不开端口**；
/// 每份网页的 id 当主机名，所以各份网页是不同的源（`localStorage` 互不串）。
///
/// 页面里有 `window.unireader`（`WebBridgeScript`）：存进工作区的数据随同步走；别处改了会收到 `unireader:change`。
///
/// 沉浸（2026-11-28）：网页铺满整块，伸到工具栏和顶上那一条后面，靠 `obscuredContentInsets` 让出版面。
/// macOS 26 的 `WKWebView` 设了顶部内边距会自己挂一层系统边缘效果（`NSScrollPocket`，离屏实测），和 PDF 阅读区同一种模糊；
/// 所以顶上那一条**不要再垫不透明的底**，按钮直接浮在这层模糊上；模糊层的颜色由 `underPageBackgroundColor` 定（见 init）。
@MainActor
final class WebDocView: NSView, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandlerWithReply {
    static let scheme = "unireader-web"

    let webId: String
    private let workspace: WorkspaceManager
    /// 顶部让开工具栏的高度（窗格设）/ 底部要让出的高度（原先给底部标签栏，现恒为 0）。
    var topInset: CGFloat = 0 { didSet { if topInset != oldValue { needsLayout = true } } }
    var bottomInset: CGFloat = 0 { didSet { if bottomInset != oldValue { needsLayout = true } } }

    /// 顶上那一条的底：透明，只负责接住空白处的点击（不漏给后面的网页）、拖动窗口、把滚轮转给网页。
    private let header = WebHeaderStrip()
    private let navControl = NSSegmentedControl()
    private let homeButton = NSButton()
    private let reloadButton = NSButton()
    private let titleLabel = NSTextField(labelWithString: "")
    private let browserButton = NSButton()
    private let notice = NSTextField(wrappingLabelWithString: "")
    private let web: WKWebView
    private let handler: WebDocSchemeHandler
    private var observations: [NSKeyValueObservation] = []
    private var observers: [NSObjectProtocol] = []
    /// 清单变了（重新导入 / 同步拉到新版）时整页重新载入；记下上次装的那份。
    private var loadedManifest = ""
    /// 下一次页面来问时要不要把记下的位置交出去滚回去（打开 / 重新载入时置上，交一次就落下）。
    /// 到页面来问时才读记忆：重新载入前最后那一下滚动在旧页面卸下时（`pagehide`）才报上来，排在新页面的询问之前。
    fileprivate var restorePending = false
    /// 标签切走时窗格把它藏起来留着（`ReaderPaneController.parkedWebViews`）。藏着时不往页面推变动通知：
    /// 页面收到「习题有变」会把做题记录整个重查一遍，在习题页每答一题后台就卡一下。攒着，显示出来时各推一次。
    var isParked = false {
        didSet {
            guard !isParked, oldValue else { return }
            for js in pendingEvents { web.evaluateJavaScript(js) }
            pendingEvents.removeAll()
        }
    }
    private var pendingEvents: [String] = []

    /// 往页面推一条变动通知；藏着时先攒下（同一条只留一次）。
    private func dispatchEvent(_ js: String) {
        if isParked {
            if !pendingEvents.contains(js) { pendingEvents.append(js) }
        } else {
            web.evaluateJavaScript(js)
        }
    }

    init(webId: String, workspace: WorkspaceManager) {
        self.webId = webId
        self.workspace = workspace
        handler = WebDocSchemeHandler(workspace: workspace)
        let cfg = WKWebViewConfiguration()
        cfg.setURLSchemeHandler(handler, forURLScheme: Self.scheme)
        cfg.preferences.javaScriptCanOpenWindowsAutomatically = false
        cfg.mediaTypesRequiringUserActionForPlayback = []
        let title = workspace.webDoc(id: webId)?.title ?? ""
        let script = WKUserScript(source: WebBridgeScript.source(webId: webId, title: title, transport: .webkit),
                                  injectionTime: .atDocumentStart, forMainFrameOnly: false)
        cfg.userContentController.addUserScript(script)
        // 记住滚动位置：放在隔离的脚本环境（`.defaultClient`）里，页面自己的脚本看不到、也改不了它
        let scroll = WKUserScript(source: WebBridgeScript.scrollSource(
            post: "function (o) { o.op = 'save'; window.webkit.messageHandlers.\(Self.scrollHandler).postMessage(o); }",
            ask: "function () { return window.webkit.messageHandlers.\(Self.scrollHandler).postMessage({ op: 'target' }); }"),
            injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .defaultClient)
        cfg.userContentController.addUserScript(scroll)
        web = WKWebView(frame: .zero, configuration: cfg)
        super.init(frame: .zero)
        // 消息处理挂一个弱引用的中转：`WKUserContentController` 强持有处理者，直接挂 self 会循环引用
        cfg.userContentController.addScriptMessageHandler(WeakScriptHandler(self), contentWorld: .page, name: "unireader")
        cfg.userContentController.addScriptMessageHandler(WeakScriptHandler(self), contentWorld: .defaultClient, name: Self.scrollHandler)
        web.navigationDelegate = self
        web.uiDelegate = self
        web.allowsBackForwardNavigationGestures = true
        web.allowsMagnification = true
        web.isInspectable = true   // 课件作者可以在 Safari 的「开发」菜单里调试
        // 🔴 顶上那层模糊（WebKit 自己的 `NSScrollPocket`）取色就是这个颜色，默认 = 网页底色：白底网页会把模糊层、
        // 连带工具栏都带成浅色，深色外观下顶上那一条的字就看不见了（2026-11-28 用户报，离屏实测取色跟着它走）。
        // 钉成窗口底色（随系统深浅外观变），与 PDF 阅读区页外空白同色；网页拉过头回弹时露出的也是它。
        web.underPageBackgroundColor = .windowBackgroundColor

        header.web = web
        navControl.segmentCount = 2
        navControl.trackingMode = .momentary
        navControl.setImage(NSImage(systemSymbolName: "chevron.left", accessibilityDescription: L("Back")), forSegment: 0)
        navControl.setImage(NSImage(systemSymbolName: "chevron.right", accessibilityDescription: L("Forward")), forSegment: 1)
        navControl.setToolTip(L("Back"), forSegment: 0)
        navControl.setToolTip(L("Forward"), forSegment: 1)
        navControl.target = self
        navControl.action = #selector(navigate)
        homeButton.bezelStyle = .push
        homeButton.image = NSImage(systemSymbolName: "house", accessibilityDescription: L("Go to Start Page"))
        homeButton.contentTintColor = .labelColor
        homeButton.toolTip = L("Go to Start Page")
        homeButton.target = self
        homeButton.action = #selector(goHome)
        reloadButton.bezelStyle = .push
        reloadButton.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: L("Reload"))
        reloadButton.contentTintColor = .labelColor
        reloadButton.toolTip = L("Reload")
        reloadButton.target = self
        reloadButton.action = #selector(reloadPage)
        titleLabel.font = .systemFont(ofSize: NSFont.systemFontSize + 2, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        browserButton.bezelStyle = .push
        browserButton.title = L("Open in Browser")
        browserButton.image = NSImage(systemSymbolName: "safari", accessibilityDescription: nil)
        browserButton.imagePosition = .imageLeading
        browserButton.contentTintColor = .labelColor
        browserButton.toolTip = L("Open this web page in your default browser (served from this Mac only)")
        browserButton.target = self
        browserButton.action = #selector(openInBrowser)
        notice.textColor = .labelColor
        notice.font = .preferredFont(forTextStyle: .callout)
        notice.alignment = .center
        notice.isHidden = true
        for v in [web, header, notice, navControl, homeButton, reloadButton, titleLabel, browserButton] as [NSView] { addSubview(v) }

        observations = [
            web.observe(\.canGoBack) { [weak self] _, _ in MainActor.assumeIsolated { self?.updateNav() } },
            web.observe(\.canGoForward) { [weak self] _, _ in MainActor.assumeIsolated { self?.updateNav() } },
            web.observe(\.url) { [weak self] _, _ in MainActor.assumeIsolated { self?.updateNav() } },
            web.observe(\.title) { [weak self] _, _ in MainActor.assumeIsolated { self?.updateTitle() } },
        ]
        observers.append(NotificationCenter.default.addObserver(forName: .webKVDidChangeRemotely, object: workspace, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.dispatchEvent(WebBridgeScript.changeEvent) }
        })
        // 习题 / 作答有变 → 页面收到 unireader:exercises（页面自己重查；脚本那头停手才调、这里不必合并）
        for name in [Notification.Name.exercisesDidChange, .exerciseDoneDidChange, .exerciseAttemptDidRecord] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: workspace, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.dispatchEvent(WebBridgeScript.exercisesEvent) }
            })
        }
        observers.append(NotificationCenter.default.addObserver(forName: .webDocNavigate, object: workspace, queue: .main) { [weak self] n in
            MainActor.assumeIsolated {
                guard let self, (n.userInfo?["id"] as? String) == self.webId, let p = n.userInfo?["path"] as? String,
                      let url = Self.url(webId: self.webId, path: p) else { return }
                self.web.load(URLRequest(url: url))
            }
        })
        updateNav()
        load()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) 不支持") }

    deinit {
        for o in observers { NotificationCenter.default.removeObserver(o) }
    }

    override var isFlipped: Bool { true }

    /// 系统深浅外观切换：动态色 WebKit 可能只在设置时取一次，重设一遍让顶上模糊层跟上。
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        web.underPageBackgroundColor = .windowBackgroundColor
    }

    /// 网页列表变了（改名 / 重新导入 / 同步拉到新版 / 文件下完了）：标题跟上，清单变了就重新载入。
    /// 窗格每次刷新都会调（很频繁）：只比内存里的列表，文件只在提示条开着时才去看。
    func refreshFromWorkspace() {
        guard let w = workspace.webDocs.first(where: { $0.id == webId }) else { return }
        updateTitle()
        updateNav()   // 首页可能换了（侧栏右键「首页」/ MCP `start_page`）
        if w.manifest != loadedManifest { load(); return }
        guard !notice.isHidden else { return }
        let missing = workspace.webDocFilesMissing(w)
        if missing == 0 { load() } else { updateNotice(missing) }
    }

    private func load() {
        guard let w = workspace.webDoc(id: webId) else {
            notice.stringValue = L("This web page is no longer in the workspace.")
            notice.isHidden = false
            needsLayout = true
            return
        }
        loadedManifest = w.manifest
        handler.invalidate()
        updateNotice(workspace.webDocFilesMissing(w))
        // 回到上次看到的那一页（本机记忆，不同步）；那一页不在了就从入口开始
        let last = UserDefaults.standard.string(forKey: Self.lastPathKey(webId))
        let path = last.flatMap { p in w.entries.contains { $0.p == p } ? p : nil } ?? w.entry
        guard let url = Self.url(webId: webId, path: path) else { return }
        // 连同那一页里滚到的位置（页面加载好后来问；记的不是这一页时页面自己会认出来不滚）
        restorePending = true
        web.load(URLRequest(url: url))
    }

    private func updateNotice(_ missing: Int) {
        notice.isHidden = missing == 0
        notice.stringValue = missing == 0 ? ""
            : String(format: L("%d file(s) of this web page are not on this device yet. They are downloaded when the workspace syncs."), missing)
        needsLayout = true
    }

    static func url(webId: String, path: String) -> URL? {
        var c = URLComponents()
        c.scheme = scheme
        c.host = webId.lowercased()
        c.path = "/" + path
        return c.url
    }

    private static func lastPathKey(_ id: String) -> String { "web.lastPath." + id.uppercased() }
    /// 上次滚到哪（本机记忆，不同步）：`{ p: 页面的 location.pathname, x, y, s?, sx?, sy? }`，见 `WebBridgeScript.scrollSource`。
    fileprivate static func scrollKey(_ id: String) -> String { "web.scroll." + id.uppercased() }
    private static let scrollHandler = "unireaderScroll"

    /// 记下「下次打开这份网页时停在哪一页」（MCP `open_web_page` 在标签还没开时用）。
    static func rememberPath(webId: String, path: String) {
        UserDefaults.standard.set(path, forKey: lastPathKey(webId))
    }

    private func updateNav() {
        navControl.setEnabled(web.canGoBack, forSegment: 0)
        navControl.setEnabled(web.canGoForward, forSegment: 1)
        homeButton.isEnabled = !isOnStartPage
    }

    /// 眼下是不是就在首页（同一个文件；页内 `#锚点` 不算离开；`/`、`chapter/` 这种目录地址按它的 index 认）。
    /// 还没载入 / 载入的不是本网页 = 不是。导航时会调几次：只看内存里的列表，不查库、不解清单。
    private var isOnStartPage: Bool {
        guard let u = web.url, u.scheme == Self.scheme,
              let entry = workspace.webDocs.first(where: { $0.id == webId })?.entry else { return false }
        return WebAssets.resolve(u.path, in: [entry: WebAssets.Entry(p: entry, h: "", n: 0)]) != nil
    }

    private func updateTitle() {
        let name = workspace.webDoc(id: webId)?.title ?? ""
        let page = web.title ?? ""
        titleLabel.stringValue = page.isEmpty || page == name ? name : "\(name) — \(page)"
    }

    @objc private func navigate() {
        if navControl.selectedSegment == 0 { web.goBack() } else { web.goForward() }
    }

    /// 鼠标侧键（`ReaderPaneController` 接）：网页自己还能后退 / 前进就走一步，返回 true；走不了返回 false，由窗口的历史接着走。
    func navigateHistory(back: Bool) -> Bool {
        if back, web.canGoBack { web.goBack(); return true }
        if !back, web.canGoForward { web.goForward(); return true }
        return false
    }

    @objc private func reloadPage() { web.reload() }

    /// 回到首页：课件的子页面不一定有回首页的链接，重新打开时又停在上次那一页（后退历史是空的），没有这个键就回不去。
    /// 走普通导航（进后退历史），点后退还能回到刚才那页。
    @objc private func goHome() {
        guard let w = workspace.webDoc(id: webId), let url = Self.url(webId: webId, path: w.entry) else { return }
        web.load(URLRequest(url: url))
    }

    @objc private func openInBrowser() {
        // 浏览器里也打开眼下这一页（不是入口）
        let path = web.url.flatMap { $0.scheme == Self.scheme ? String($0.path.drop(while: { $0 == "/" })) : nil }
        do {
            try WebDocLocalServer.shared.open(webId: webId, workspace: workspace, path: path)
        } catch {
            let a = NSAlert()
            a.messageText = L("Could not open the web page in the browser.")
            a.informativeText = error.localizedDescription
            if let win = window { a.beginSheetModal(for: win) } else { a.runModal() }
        }
    }

    override func layout() {
        super.layout()
        let b = bounds
        let headerH: CGFloat = 40
        header.frame = NSRect(x: 0, y: topInset, width: b.width, height: headerH)
        let pad: CGFloat = 12, midY = topInset + headerH / 2
        navControl.sizeToFit()
        navControl.frame.origin = NSPoint(x: pad, y: midY - navControl.frame.height / 2)
        homeButton.sizeToFit()
        homeButton.frame.origin = NSPoint(x: navControl.frame.maxX + 8, y: midY - homeButton.frame.height / 2)
        reloadButton.sizeToFit()
        reloadButton.frame.origin = NSPoint(x: homeButton.frame.maxX + 4, y: midY - reloadButton.frame.height / 2)
        browserButton.sizeToFit()
        browserButton.frame.origin = NSPoint(x: b.width - pad - browserButton.frame.width, y: midY - browserButton.frame.height / 2)
        let th = titleLabel.intrinsicContentSize.height
        let tx = reloadButton.frame.maxX + 12
        titleLabel.frame = NSRect(x: tx, y: midY - th / 2, width: max(0, browserButton.frame.minX - 12 - tx), height: th)
        var top = header.frame.maxY
        if !notice.isHidden {
            // 提示条也算在让出的版面里（同在边缘效果下面），网页内容从它下面开始
            let h = notice.sizeThatFits(NSSize(width: max(0, b.width - 32), height: .greatestFiniteMagnitude)).height
            notice.frame = NSRect(x: 16, y: top + 4, width: max(0, b.width - 32), height: h)
            top = notice.frame.maxY + 8
        }
        if web.frame != b { web.frame = b }
        let insets = NSEdgeInsets(top: top, left: 0, bottom: bottomInset, right: 0)
        let cur = web.obscuredContentInsets
        if cur.top != insets.top || cur.bottom != insets.bottom || cur.left != 0 || cur.right != 0 {
            web.obscuredContentInsets = insets
        }
    }

    // MARK: - 导航

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        // 重新载入（顶上的按钮 / 右键菜单 / 页面自己调）也由脚本滚回去：WebKit 自己恢复时内容还没撑高（图片、公式晚到），
        // 位置被截短，连着刷新就一路往上跑；铺满的滚动容器里的位置它干脆不恢复
        if navigationAction.navigationType == .reload, navigationAction.targetFrame?.isMainFrame ?? false { restorePending = true }
        guard let url = navigationAction.request.url, let scheme = url.scheme?.lowercased() else { decisionHandler(.allow); return }
        if scheme == Self.scheme || scheme == "about" || scheme == "data" || scheme == "blob" {
            decisionHandler(.allow)
            return
        }
        // 外面的网站 / 邮件 / 其他协议：主框架点出去的交给系统（默认浏览器），子框架里的照常载入（嵌入的视频之类）
        if navigationAction.targetFrame?.isMainFrame ?? true {
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
        } else {
            decisionHandler(.allow)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if let u = webView.url, u.scheme == Self.scheme {
            UserDefaults.standard.set(String(u.path.drop(while: { $0 == "/" })), forKey: Self.lastPathKey(webId))
        }
        updateTitle()
    }

    /// `target="_blank"` / `window.open`：本网页里的在这里开，外面的交给系统浏览器。
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url {
            if url.scheme == Self.scheme { webView.load(URLRequest(url: url)) } else { NSWorkspace.shared.open(url) }
        }
        return nil
    }

    // MARK: - JS 弹窗（不接的话 alert / confirm / prompt 会被悄悄吞掉）

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor () -> Void) {
        let a = NSAlert()
        a.messageText = message
        a.addButton(withTitle: L("OK"))
        present(a) { _ in completionHandler() }
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor (Bool) -> Void) {
        let a = NSAlert()
        a.messageText = message
        a.addButton(withTitle: L("OK"))
        a.addButton(withTitle: L("Cancel"))
        present(a) { completionHandler($0 == .alertFirstButtonReturn) }
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor (String?) -> Void) {
        let a = NSAlert()
        a.messageText = prompt
        let field = NSTextField(string: defaultText ?? "")
        field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        a.accessoryView = field
        a.addButton(withTitle: L("OK"))
        a.addButton(withTitle: L("Cancel"))
        present(a) { completionHandler($0 == .alertFirstButtonReturn ? field.stringValue : nil) }
    }

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor ([URL]?) -> Void) {
        let p = NSOpenPanel()
        p.allowsMultipleSelection = parameters.allowsMultipleSelection
        p.canChooseDirectories = parameters.allowsDirectories
        p.canChooseFiles = true
        let done: (NSApplication.ModalResponse) -> Void = { completionHandler($0 == .OK ? p.urls : nil) }
        if let win = window { p.beginSheetModal(for: win, completionHandler: done) } else { done(p.runModal()) }
    }

    private func present(_ a: NSAlert, _ done: @escaping (NSApplication.ModalResponse) -> Void) {
        if let win = window { a.beginSheetModal(for: win, completionHandler: done) } else { done(a.runModal()) }
    }

    // MARK: - window.unireader

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage,
                               replyHandler: @escaping @MainActor (Any?, String?) -> Void) {
        // 只认自己这份网页的页面发来的（别的源 = 页面里嵌了外面的网站，不给它碰数据）
        guard message.frameInfo.securityOrigin.protocol == Self.scheme,
              message.frameInfo.securityOrigin.host.lowercased() == webId.lowercased() else {
            replyHandler(nil, "unireader is only available to the web page itself")
            return
        }
        if message.name == Self.scrollHandler {
            replyHandler(scrollMessage(message), nil)
            return
        }
        guard let body = message.body as? [String: Any], let op = body["op"] as? String else {
            replyHandler(nil, "bad request")
            return
        }
        do {
            replyHandler(try workspace.webKV(webId: webId, op: op, key: body["key"] as? String, value: body["value"] as? String), nil)
        } catch {
            replyHandler(nil, error.localizedDescription)
        }
    }
}

extension WebDocView {
    /// 滚动位置脚本的两种消息：`save` = 存下（只认主框架）；`target` = 这次要不要滚回去（只给一次）。
    fileprivate func scrollMessage(_ message: WKScriptMessage) -> Any? {
        guard message.frameInfo.isMainFrame, let body = message.body as? [String: Any] else { return nil }
        switch body["op"] as? String {
        case "save":
            if let pos = WebBridgeScript.sanitizeScroll(body) { UserDefaults.standard.set(pos, forKey: Self.scrollKey(webId)) }
            return nil
        case "target":
            guard restorePending else { return nil }
            restorePending = false
            return UserDefaults.standard.dictionary(forKey: Self.scrollKey(webId)).flatMap(WebBridgeScript.sanitizeScroll)
        default:
            return nil
        }
    }
}

/// 顶上那一条的透明底：空白处的点击不漏给后面的网页（那里被模糊盖着，点到了也看不见点了什么），
/// 按住可以拖动窗口（和工具栏一样），滚轮转给网页。
private final class WebHeaderStrip: NSView {
    weak var web: WKWebView?
    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { true }
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { window?.performZoom(nil) } else { window?.performDrag(with: event) }
    }
    override func scrollWheel(with event: NSEvent) { web?.scrollWheel(with: event) }
}

/// `WKUserContentController` 强持有消息处理者：中转一层弱引用，视图拆掉时不被它留着。
private final class WeakScriptHandler: NSObject, WKScriptMessageHandlerWithReply {
    weak var target: WKScriptMessageHandlerWithReply?
    init(_ t: WKScriptMessageHandlerWithReply) { target = t }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage,
                               replyHandler: @escaping @MainActor (Any?, String?) -> Void) {
        guard let target else { replyHandler(nil, "gone"); return }
        target.userContentController(userContentController, didReceive: message, replyHandler: replyHandler)
    }
}

/// `unireader-web://<网页 id>/<路径>` → 工作区 `Web/` 里的文件（`WebDocFiles`，支持 Range：视频要用）。
/// 读文件在后台队列；回给 WebKit 回到主线程，任务被停掉了就不回（回了会抛异常）。
final class WebDocSchemeHandler: NSObject, WKURLSchemeHandler {
    private weak var workspace: WorkspaceManager?
    private var files: [String: WebDocFiles] = [:]
    /// 还在等回答的任务（停掉的从这里拿走，读完文件时不在了就不回）。
    private var active = Set<ObjectIdentifier>()
    private let queue = DispatchQueue(label: "unireader.web-scheme", qos: .userInitiated, attributes: .concurrent)

    init(workspace: WorkspaceManager) { self.workspace = workspace }

    /// 清单变了：下次请求重新建表。
    @MainActor func invalidate() { files = [:] }

    @MainActor private func files(for host: String) -> WebDocFiles? {
        let key = host.lowercased()
        if let f = files[key] { return f }
        guard let ws = workspace, let folder = ws.folder,
              let doc = ws.webDocs.first(where: { $0.id.lowercased() == key }) ?? ws.webDoc(id: key.uppercased()) ?? ws.webDoc(id: key)
        else { return nil }
        let f = WebDocFiles(doc: doc, folder: folder)
        files[key] = f
        return f
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        MainActor.assumeIsolated {
            let req = urlSchemeTask.request
            guard let url = req.url, let host = url.host, let f = files(for: host) else {
                respond(urlSchemeTask, url: req.url, reply: WebDocFiles.Reply(status: 404, headers: [:], file: nil, range: nil,
                                                                              body: Data("Not found".utf8)), data: Data("Not found".utf8))
                return
            }
            let reply = f.reply(path: url.path, rangeHeader: req.value(forHTTPHeaderField: "Range"))
            let id = ObjectIdentifier(urlSchemeTask)
            active.insert(id)
            queue.async { [weak self] in
                let data = (try? f.body(of: reply)) ?? Data()
                DispatchQueue.main.async {
                    guard let self else { return }
                    MainActor.assumeIsolated {
                        guard self.active.remove(id) != nil else { return }
                        self.respond(urlSchemeTask, url: url, reply: reply, data: data)
                    }
                }
            }
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {
        MainActor.assumeIsolated { _ = active.remove(ObjectIdentifier(urlSchemeTask)) }
    }

    @MainActor private func respond(_ task: any WKURLSchemeTask, url: URL?, reply: WebDocFiles.Reply, data: Data) {
        guard let url, let resp = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/1.1",
                                                   headerFields: reply.headers) else {
            task.didFailWithError(URLError(.badURL))
            return
        }
        task.didReceive(resp)
        task.didReceive(data)
        task.didFinish()
    }
}
