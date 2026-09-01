import Foundation
import SwiftUI
import WebKit

/// 面板当前在为「哪个窗口的哪本书的哪一页」服务。由阅读区发起绑定时设入；
/// nil = 用户自己在面板里随便聊，**不落库**。
struct AIBindContext: Equatable {
    var sessionID: UUID     // 发起的那个阅读窗口——只有它负责落库
    var documentId: String  // 库文档 id（不是窗口会话 id、也不是内容哈希，见 PROTOCOL.md §4.1 的三 id 空间警告）
    var docTitle: String
    var page: Int
    var anchor: CGRect = .zero
}

/// 面板 → 阅读窗口的落库请求。面板**不碰库**（库是窗口级、同一个库只许一个连接，
/// `REQUIREMENTS.md §8.1` 红线），只把要写的东西递出去，由认领的窗口写进
/// `session.aiThreads`，再由既有的增量对账落库。见 `ContentView.applyAIThreadUpsert`。
struct AIThreadUpsert: Equatable {
    /// 每次请求唯一：内容相同也要触发一次 `onChange`（比如把同一条从 suspect 改回 ok 又改回来）。
    var token = UUID()
    var sessionID: UUID
    var documentId: String
    var thread: AIThread
}

/// AI 面板的 App 级模型：管平台表、每个宿主一份网页（`AIPageBox`）、登录态与生命周期。
///
/// **形态：全局唯一浮窗**（`Window` scene，id = `windowID`），不是每个阅读窗口一个。
/// 形态有两种（浮窗 / 窗口内置），网页按**宿主**分配 —— 每扇阅读窗口的内置面板、以及那扇浮窗，
/// 各自一份 `AIPageBox`（我们自己持有的 `WKWebView`，见 `AIWebView.swift`）。
///
/// **登录态**：所有平台共用 `WKWebsiteDataStore.default()`（非沙盒，落
/// `~/Library/WebKit/tech.xvanturing.UniReader`），关 app 不掉登录。
///
/// **内存**：每个宿主一个独立 WebContent 进程 ≈ 100~110MB（2026-08-26 实测，见 `AI-PLAN.md §11.6`），所以 `maxLive` 封顶、按 LRU 淘汰，关窗只留当前这家
/// （`releaseIdle`），退出全放（`teardownAll`）——沿用 `REQUIREMENTS.md §8.1`
/// 「关闭 = 当场显式放掉，别等 ARC」的纪律。
/// 面板 → 阅读窗口的**建笔记**请求（S5：webview 里选一段回答 → 回填成文字笔记）。
/// 与 `AIThreadUpsert` 同一条纪律：面板不碰库，只递请求。
struct AINoteRequest: Equatable {
    var token = UUID()
    var sessionID: UUID
    var documentId: String
    var note: TextNote
}

/// JS → 原生的桥。目前只有一种消息：webview 里的选区。
///
/// 为什么要它：`.webViewContextMenu` 给的 `ActivatedElementInfo` **只有 linkURL**，拿不到选中文字
/// （已核 SDK swiftinterface），所以选区必须靠注入脚本推上来。
final class AIMessageBridge: NSObject, WKScriptMessageHandler {
    func userContentController(_ controller: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard let d = message.body as? [String: Any],
              d["type"] as? String == "selection" else { return }
        let text = d["text"] as? String ?? ""
        Task { @MainActor in AIPanelModel.shared.noteSelection(text) }
    }
}

/// 挂着网页的宿主。**每个宿主一份自己的 `AIPageBox`**（见 `AIPanelModel` 的说明）。
enum AIHost: Hashable {
    /// 独立浮窗（全 app 只有一扇）。
    case window
    /// 某扇阅读窗口的内置面板（用它的 `DocSession.id` 区分）。
    case inline(UUID)
}

/// 面板的两种形态。
enum AIPanelMode: String {
    /// 独立浮窗（可吸附到主窗口右侧、可置顶）。
    case window
    /// 内置：以悬浮面板的形式贴在阅读窗口右侧，收起时是右下角一枚气泡按钮。
    case inline
}

@MainActor
final class AIPanelModel: ObservableObject {
    static let shared = AIPanelModel()

    /// `Window` scene 的 id，`openWindow(id:)` 用。
    static let windowID = "ai-panel"

    /// **同一个宿主**最多留几份页面（= 几个平台）。跨宿主永远不互相淘汰——
    /// 每扇阅读窗口的对话状态是各自独立的，用户 2026-08-26 明确要求保留。
    private static let maxPagesPerHost = 2

    /// 默认 UA 尾巴：WKWebView 的 UA 是「Safari 内核串 + applicationNameForUserAgent」，
    /// 填成这个就得到一条与 Safari 等价的 UA。个别站点还要更彻底的伪装，走
    /// `AIProvider.userAgent` 整条覆盖。
    private static let safariAppName = "Version/26.0 Safari/605.1.15"

    private static let lastProviderKey = "aiProviderID"
    private static let modeKey = "aiPanelMode"
    private static let dockKey = "aiPanelDock"
    private static let inlineOpenKey = "aiInlineOpen"
    private static let inlineWidthKey = "aiInlineWidth"

    @Published private(set) var providers: [AIProvider] = []
    @Published private(set) var currentID: String = ""
    /// 当前前台宿主那一份页面。**只在动作里换，不在 body 里创建**（body 里建会触发
    /// 「Modifying state during view update」）。
    @Published private(set) var current: AIPageBox?
    /// 平台表是否来自外部配置文件（UI 上标一下，免得改了文件却不知道有没有生效）。
    @Published private(set) var usingExternalConfig = false

    // MARK: 形态（浮窗 / 内置）

    /// 当前形态。两种形态互斥是**产品语义**（用户要么用浮窗要么用内置），
    /// 不再是崩溃的防线——那条已由「webview 归我们自己持有」（`AIWebView.swift`）彻底解决。
    @Published private(set) var mode: AIPanelMode = .window
    /// 内置模式下，**哪几扇阅读窗口**的面板是展开的（其余收成气泡）。
    /// 🔴 **按窗口分别记**：内置模式下**每扇阅读窗口都显示自己的聊天**，展开/收起也各管各的
    /// （用户 2026-08-26：「我要每个 windows 同时显示聊天」）。早先「只有活跃窗口显示」是为了
    /// 规避崩溃临时加的——那条现在由「webview 归我们自己持有」彻底解决，这个限制没有任何存在理由。
    @Published private(set) var inlineOpenWindows: Set<UUID> = []
    /// 新窗口的默认展开状态（持久化；session id 每次启动都是新的，存 id 没意义）。
    @Published private(set) var inlineOpenDefault = false
    /// 浮窗吸附到主窗口右侧并跟随移动。
    @Published private(set) var docked = true
    /// 内置面板宽度（左缘可拖）。
    @Published private(set) var inlineWidth: Double = 400

    func setMode(_ m: AIPanelMode) {
        guard m != mode else { return }
        // 把当前对话的 URL 带给新宿主：两种形态各有自己的页面，不带的话切过去就回首页。
        carryURL = current?.url?.absoluteString
        mode = m
        UserDefaults.standard.set(m.rawValue, forKey: Self.modeKey)
        if m == .inline {
            inlineOpenDefault = true
            UserDefaults.standard.set(true, forKey: Self.inlineOpenKey)
            if case .inline(let id) = activeHost { inlineOpenWindows.insert(id) }
        }
    }

    func isInlineOpen(_ window: UUID) -> Bool { inlineOpenWindows.contains(window) }

    func setInlineOpen(_ open: Bool, for window: UUID) {
        if open { inlineOpenWindows.insert(window) } else { inlineOpenWindows.remove(window) }
        guard open != inlineOpenDefault else { return }
        inlineOpenDefault = open        // 新开的窗口沿用最后一次选择
        UserDefaults.standard.set(open, forKey: Self.inlineOpenKey)
    }

    func toggleInline(_ window: UUID) { setInlineOpen(!isInlineOpen(window), for: window) }

    /// ⌘⇧A 用：切当前 key 窗口那一扇（`activeHost` 跟着 key 窗口走）。
    func toggleInlineActive() {
        guard case .inline(let id) = activeHost else { return }
        toggleInline(id)
    }

    /// 某扇阅读窗口的内置层首次出现时，按持久化的默认值决定展开还是收成气泡。
    func seedInlineOpen(_ window: UUID) {
        guard !inlineOpenWindows.contains(window), inlineOpenDefault else { return }
        inlineOpenWindows.insert(window)
    }

    /// 阅读窗口关闭：把它的展开记号一并去掉（session id 不会复用）。
    func forgetInline(_ window: UUID) { inlineOpenWindows.remove(window) }

    func setInlineWidth(_ w: Double) {
        let clamped = min(max(w, 300), 900)
        guard abs(clamped - inlineWidth) > 0.5 else { return }
        inlineWidth = clamped
        UserDefaults.standard.set(clamped, forKey: Self.inlineWidthKey)
    }

    func setDocked(_ on: Bool) {
        guard on != docked else { return }
        docked = on
        UserDefaults.standard.set(on, forKey: Self.dockKey)
        AIPanelDock.shared.setEnabled(on)
    }

    /// 让面板出现在用户眼前：内置模式展开**这扇窗口**的侧栏，浮窗模式开窗口。
    /// 各处入口（右键讨论本页 / 框选投递 / 从列表打开会话）都走它，免得每处各写一遍分支。
    /// 顺手把 `activeHost` 指到这一扇——发起动作的那扇窗口就该是模型级操作的作用对象。
    /// 🔴 2026-09-01 窗口层迁到 AppKit 后**不再需要外面传 `openWindow` 进来**：浮窗由
    /// `AIPanelWindowController` 建，模型直接叫得动它（迁移前 `openWindow` 是 SwiftUI 的
    /// environment action，只有视图够得着，于是四处调用点各传一份闭包）。
    func present(window: UUID) {
        if mode == .inline {
            setActiveHost(.inline(window))
            setInlineOpen(true, for: window)
        } else {
            setActiveHost(.window)
            AIPanelWindowController.show()
        }
    }

    // MARK: 宿主与页面
    //
    // 🔴 **webview 的生命周期归我们自己管，不交给 SwiftUI**（见 `AIWebView.swift` 顶部那段）。
    // 2026-08-26 用 macOS 26 那套 SwiftUI `WebView`/`WebPage` 崩了四次，每次都停在
    // `_WebKit_SwiftUI.makeViewProvider` —— 视图一被重建，框架就再造一个 `WebView` 去挂同一个
    // `WebPage`，WebKit 当场 trap。我四次都在找「一个保证不会被重建的挂载点」，
    // **那个前提本身不成立**：SwiftUI 有权随时重建任何视图（实测连启动都会重建两次）。
    //
    // 现在网页是 `AIPageBox`（我们持有的 `WKWebView`），SwiftUI 那边只是个稳定容器；
    // 视图重建 = 把同一个 NSView 重新挂一次父，合法且幂等。
    //
    // 页面按 **宿主 × 平台** 分配：每扇阅读窗口的内置面板、那扇浮窗，各自一份。
    // 登录态不受影响（共用 `WKWebsiteDataStore.default()`）。

    /// 用户此刻在跟哪个宿主打交道。模型级操作（绑定捕获 / 投递 / 导航按钮）都作用在它的页面上。
    @Published private(set) var activeHost: AIHost = .window

    /// 切形态时把当前对话的 URL 带给新宿主，免得一切过去就回首页。
    private var carryURL: String?

    // MARK: 会话绑定（S2）

    /// 面板此刻为哪一页服务。`goHome()`（新对话）不清它——还是同一页，只是换一次对话。
    @Published private(set) var bindContext: AIBindContext?
    /// 当前 URL 对应的那条已落库会话；nil = 还没 commit（新对话尚未发出第一条消息）。
    @Published private(set) var boundThread: AIThread?
    /// 页面集合的版本号：新建/放掉页面时 +1，让读 `existingPage` 的视图能被刷新
    /// （`pages` 本身是普通字典，不发布）。
    @Published private(set) var pagesRevision = 0

    /// 待认领的落库请求（见 `AIThreadUpsert`）。
    @Published private(set) var threadUpsert: AIThreadUpsert?

    // MARK: 选区回填（S5）

    /// webview 里最近一次选区（由注入脚本推上来）。右键菜单项直接用它。
    @Published private(set) var pageSelection = ""
    /// 待认领的建笔记请求。
    @Published private(set) var noteRequest: AINoteRequest?
    /// 面板里一闪而过的提示（「已加到笔记」之类），几秒后自己消失。
    @Published private(set) var flash: String?

    /// 消息桥。**强持有**：`WKUserContentController` 对 handler 是强引用，这里再持一份是为了
    /// 一个实例服务所有页面（本类是 App 级单例，不构成环）。
    private let bridge = AIMessageBridge()

    /// 正在打开的那条已存会话 id：用于**失效检测**——加载停下来那一刻若 URL 不再匹配会话正则，
    /// 说明被重定向回首页/登录页（会话已删或掉登录），标 `suspect`。
    private var openingThreadID: UUID?

    private var pages: [PageKey: AIPageBox] = [:]
    private var liveKeys: [PageKey] = []

    private init() {
        let d = UserDefaults.standard
        mode = AIPanelMode(rawValue: d.string(forKey: Self.modeKey) ?? "") ?? .window
        inlineOpenDefault = d.object(forKey: Self.inlineOpenKey) as? Bool ?? false
        docked = d.object(forKey: Self.dockKey) as? Bool ?? true
        inlineWidth = min(max(d.object(forKey: Self.inlineWidthKey) as? Double ?? 400, 300), 900)
        reloadConfig()
    }

    // MARK: - 平台表（内置 + 外部覆盖）

    /// 外部配置目录：`~/Library/Application Support/UniReader/`（非沙盒，直接可写）。
    static var configFolder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support")
        return base.appendingPathComponent("UniReader", isDirectory: true)
    }

    static var configFile: URL { configFolder.appendingPathComponent("ai-providers.json") }

    /// 发送适配器脚本的外部覆盖路径。内置那份在 app 资源里（`Sources/Resources/ai-adapters.js`）；
    /// 这个文件存在且非空就用它——**站点改版时不用重编译发版就能救**（用户 2026-08-25 定的
    /// 「先做成支持外部配置，但也有内部配置」）。
    static var adapterFile: URL { configFolder.appendingPathComponent("ai-adapters.js") }

    /// 取适配器脚本：外部覆盖优先，否则内置。两份都没有就不注入（`attach` 会老实报失败）。
    private static func adapterSource() -> String? {
        if let s = try? String(contentsOf: adapterFile, encoding: .utf8),
           !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return s }
        guard let url = Bundle.main.url(forResource: "ai-adapters", withExtension: "js") else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    /// 读平台表：外部文件解得出**至少一项合法**才用它，否则一律回落内置。
    /// 「解不出就静默用内置」是刻意的——但 `usingExternalConfig` 会告诉 UI 到底用的哪份，
    /// 不让它变成查不出的静默失效。
    func reloadConfig() {
        var list = AIProvider.builtin
        var external = false
        if let data = try? Data(contentsOf: Self.configFile),
           let decoded = try? JSONDecoder().decode([AIProvider].self, from: data) {
            let valid = decoded.filter { !$0.id.isEmpty && $0.homeURL != nil }
            if !valid.isEmpty { list = valid; external = true }
        }
        providers = list
        usingExternalConfig = external

        // 当前选中项在新表里还在吗？不在就回落第一项。
        let remembered = UserDefaults.standard.string(forKey: Self.lastProviderKey) ?? ""
        let wanted = list.contains { $0.id == currentID } ? currentID
                   : (list.contains { $0.id == remembered } ? remembered : list.first?.id ?? "")
        // 表换了，已建的页面里凡是新表没有的一律放掉。
        for key in pages.keys where !list.contains(where: { $0.id == key.provider }) { drop(key) }
        if !wanted.isEmpty { select(wanted) }
    }

    /// 把内置表导出成外部配置模板（已存在则不覆盖），返回配置文件路径。
    @discardableResult
    func exportBuiltinConfig() -> URL {
        let fm = FileManager.default
        try? fm.createDirectory(at: Self.configFolder, withIntermediateDirectories: true)
        if !fm.fileExists(atPath: Self.configFile.path) {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let data = try? encoder.encode(AIProvider.builtin) {
                try? data.write(to: Self.configFile)
            }
        }
        return Self.configFile
    }

    var currentProvider: AIProvider? { providers.first { $0.id == currentID } }

    func provider(_ id: String) -> AIProvider? { providers.first { $0.id == id } }

    // MARK: - 页面生命周期

    /// 页面的键：**宿主 × 平台**。同一个平台在浮窗和各扇阅读窗口里各有一份。
    private struct PageKey: Hashable {
        var host: AIHost
        var provider: String
    }

    /// 切平台。当前宿主的那一份没建过就现建，建过就复用（保留登录/滚动/草稿）。
    func select(_ id: String) {
        guard provider(id) != nil else { return }
        currentID = id
        UserDefaults.standard.set(id, forKey: Self.lastProviderKey)
        _ = page(for: activeHost)
    }

    /// 谁在前台。宿主视图上线/成为活跃窗口时调。
    func setActiveHost(_ host: AIHost) {
        guard host != activeHost else { return }
        activeHost = host
        refreshCurrent()
    }

    /// **纯查找，不创建** —— 给 `body` 用。
    ///
    /// 🔴 视图 body 里必须用这个，别用 `@State` 缓存页面：视图一被重建 `@State` 就归 nil，
    /// body 会先渲一帧「没有页面」的占位、等 `onAppear` 再把页面塞回来 —— 那一下**必然闪**
    /// （2026-08-26 用户报的闪烁，一半是它）。从模型直接查，重建后第一帧就能拿到同一个页面。
    func existingPage(for host: AIHost) -> AIPageBox? {
        pages[PageKey(host: host, provider: currentID)]
    }

    /// 取（必要时新建）某个宿主的页面。
    ///
    /// ⚠️ **只许在 `onAppear`/`onChange` 里调，别在 `body` 里调**——它会建对象、改 `@Published`，
    /// 在 body 里就是「更新中改状态」。宿主视图各自用 `@State` 存住取回来的 page 再渲染。
    @discardableResult
    func page(for host: AIHost) -> AIPageBox? {
        guard let p = currentProvider else { return nil }
        let key = PageKey(host: host, provider: p.id)
        if let existing = pages[key] {
            // 注：同一宿主短时间内重复取同一份页面 = SwiftUI 重建了挂载点。**这是正常且无害的**——
            // webview 归 `AIPageBox` 持有，重建只是把同一个 NSView 重新挂一次父。
            // （这里原先有条告警，是排「重建导致第二个 WebView 挂同一个 WebPage」那个崩溃时加的；
            //   根因已由所有权方案解决，告警会在正常重建时误报，故去掉。）
            touch(key)
            refreshCurrent()
            return existing
        }
        let page = makePage(p)
        pages[key] = page
        touch(key)
        evictIfNeeded(host: host)
        page.load(carryURL.flatMap { URL(string: $0) } ?? p.homeURL)
        carryURL = nil
        pagesRevision &+= 1
        refreshCurrent()
        return page
    }

    private func refreshCurrent() {
        current = pages[PageKey(host: activeHost, provider: currentID)]
    }

    private func makePage(_ p: AIProvider) -> AIPageBox {
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .default()                    // 🔴 持久化登录态，别用 ephemeral
        cfg.applicationNameForUserAgent = Self.safariAppName
        // 发送适配器注入 page world。
        // 🔴 **必须是 `.page` 而不是默认的隔离世界**：在隔离世界里造的 File/DataTransfer，
        // 页面自己的 React 处理器拿不到。另：user script **不受站点 CSP 约束**（页面内的 fetch 才受），
        // 所以这条注入本身不会被 chat 站点的 CSP 挡掉。
        if let src = Self.adapterSource() {
            cfg.userContentController.addUserScript(
                WKUserScript(source: src, injectionTime: .atDocumentEnd,
                             forMainFrameOnly: true, in: .page))
        }
        // 选区回传通道。**contentWorld 必须与脚本一致**（都是 `.page`），否则脚本里
        // `webkit.messageHandlers.unireader` 是 undefined —— 而那条 postMessage 包在 try 里，
        // 不一致的话不会报错，只会一声不响地什么都收不到。
        cfg.userContentController.removeScriptMessageHandler(forName: "unireader", contentWorld: .page)
        cfg.userContentController.add(bridge, contentWorld: .page, name: "unireader")
        return AIPageBox(configuration: cfg, userAgent: p.userAgent)
    }

    /// LRU 记账：把键挪到尾部（最近使用）。
    private func touch(_ key: PageKey) {
        liveKeys.removeAll { $0 == key }
        liveKeys.append(key)
    }

    /// 🔴 **淘汰只在同一个宿主内部发生**（同一扇窗口里切过好几个平台时，放掉不用的那几个）。
    /// **绝不跨宿主淘汰**：每扇阅读窗口的内置面板是一段独立的对话状态，被别的窗口挤掉就是丢东西
    /// （用户 2026-08-26：「保留页面这个很重要，并且多个窗口的状态本身就是不一样的」）。
    /// 真正的回收靠「宿主消失就 `releaseHost`」——窗口关了才放。
    private func evictIfNeeded(host: AIHost) {
        let keep = PageKey(host: host, provider: currentID)
        while liveKeys.filter({ $0.host == host }).count > Self.maxPagesPerHost,
              let victim = liveKeys.first(where: { $0.host == host && $0 != keep }) {
            drop(victim)
        }
    }

    /// 显式放掉一个页面：先停在途加载再断引用，不等 ARC。
    private func drop(_ key: PageKey) {
        pages[key]?.teardown()
        pages.removeValue(forKey: key)
        liveKeys.removeAll { $0 == key }
        pagesRevision &+= 1
        refreshCurrent()
    }

    /// 某个宿主**彻底消失**时才放掉它的页面（浮窗关闭 / 阅读窗口关闭）。
    /// ⚠️ **不要在「内置层暂时不显示」时调**（切到别的阅读窗口、收成气泡都不算消失）——
    /// 那会把那扇窗口正在进行的对话状态清掉，切回去还得重新加载。
    func releaseHost(_ host: AIHost) {
        for key in pages.keys where key.host == host { drop(key) }
    }

    /// 退出 / 彻底关闭：全放。
    func teardownAll() {
        for key in pages.keys { drop(key) }
        current = nil
    }

    // MARK: - 导航

    var canGoBack: Bool { current?.canGoBack ?? false }
    var canGoForward: Bool { current?.canGoForward ?? false }

    func goBack() { current?.goBack() }
    func goForward() { current?.goForward() }
    func reload() { current?.reload() }
    func stop() { current?.stop() }

    /// 回首页（相当于「新开一个对话」的入口，具体新建语义 S2 再细化）。
    func goHome() {
        guard let box = current, let p = currentProvider else { return }
        box.load(p.homeURL)
    }

    /// 当前地址（S2 的会话绑定要读它，S1 只显示）。
    var currentURL: URL? { current?.url }

    // MARK: - 登录数据

    /// 清掉某平台的全部网站数据（cookie / localStorage / 缓存），并把它的页面放掉重建。
    /// 站点域用 `AIProvider.clearDomains`——只清主域往往不够（登录常挂在另一个域上）。
    func clearData(for p: AIProvider) async {
        let store = WKWebsiteDataStore.default()
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        let records = await store.dataRecords(ofTypes: types)
        let domains = p.clearDomains
        let hits = records.filter { rec in
            domains.contains { $0 == rec.displayName || $0.hasSuffix("." + rec.displayName) }
        }
        if !hits.isEmpty { await store.removeData(ofTypes: types, for: hits) }

        for key in pages.keys where key.provider == p.id { drop(key) }
        if currentID == p.id { _ = page(for: activeHost) }
    }

    // MARK: - 会话绑定

    /// 从阅读区发起：把接下来这次对话绑到某一页，并**开一个新对话**。
    /// 此刻还没有会话 URL（各家都是发出第一条消息才 `replaceState` 出唯一链接），
    /// 所以只记下 pending 的上下文，等 `syncFromPage` 捕到匹配的 URL 再 commit。
    func beginBind(_ ctx: AIBindContext) {
        bindContext = ctx
        boundThread = nil
        openingThreadID = nil
        goHome()
    }

    /// 从 Inspector 列表打开一条已存会话。
    func openThread(_ t: AIThread, in ctx: AIBindContext) {
        if t.provider != currentID, provider(t.provider) != nil { select(t.provider) }
        bindContext = ctx
        var opened = t
        opened.lastOpenedAt = .now
        boundThread = opened
        openingThreadID = t.id
        publish(opened)
        if let url = URL(string: t.url) { current?.load(url) }
    }

    /// 解绑：只断开面板这一侧的关联，**不删库里的记录、也不动平台上那个对话**。
    func unbind() {
        bindContext = nil
        boundThread = nil
        openingThreadID = nil
    }

    /// 阅读窗口换了文档 → 属于它的绑定上下文作废（否则上下文条会一直显示上一本书）。
    func noteDocumentChanged(sessionID: UUID, documentId: String?) {
        guard let ctx = bindContext, ctx.sessionID == sessionID, ctx.documentId != documentId else { return }
        unbind()
    }

    /// 页面的 URL / 标题变了就调一次（由 `AIPanelView` 的 `onChange` 驱动——`WebPage` 是
    /// Observation 类型，视图读它才有跟踪，模型这边没法自己订阅）。
    ///
    /// 这里是**两段式绑定**的第二段：URL 一旦匹配平台的会话正则，就把 pending 的上下文 commit 成
    /// 一条 `AIThread`；已绑的则同步 URL/标题（标题是模型事后才起的，会晚几秒才到）。
    func syncFromPage(_ host: AIHost) {
        guard host == activeHost, let p = currentProvider else { return }
        let urlStr = current?.url?.absoluteString ?? ""
        let title = current?.title ?? ""

        guard p.matchesThread(urlStr) else {
            // 不在任何会话页上（首页 / 登录页 / 用户点了「新对话」）：断开当前这条，但**保留
            // `bindContext`**——还是为那一页服务，下一条消息会开出一条新的会话并绑到同一页。
            if openingThreadID == nil { boundThread = nil }
            return
        }

        if var t = boundThread {
            guard t.url != urlStr || t.title != title else { return }
            t.url = urlStr
            t.title = title
            t.updatedAt = .now
            boundThread = t
            publish(t)
        } else if let ctx = bindContext {
            let t = AIThread(page: ctx.page, anchor: ctx.anchor, provider: p.id,
                             url: urlStr, title: title, lastOpenedAt: .now)
            boundThread = t
            publish(t)
        }
        // 没有 bindContext = 用户自己在面板里随便聊，不落库。
    }

    /// 一次加载停下来了（`isLoading` 转 false）。只为**失效检测**服务：
    /// 打开一条已存会话后若落地 URL 不再匹配会话正则，就是被重定向了 → 标 `suspect`，别静默。
    func noteLoadSettled(_ host: AIHost) {
        guard host == activeHost, let openingID = openingThreadID,
              let p = currentProvider else { return }
        openingThreadID = nil
        guard var t = boundThread, t.id == openingID else { return }
        let want: AIThread.State = p.matchesThread(current?.url?.absoluteString ?? "") ? .ok : .suspect
        guard t.state != want else { return }
        t.state = want
        t.updatedAt = .now
        boundThread = t
        publish(t)
    }

    /// 落库请求已被窗口认领。
    func consumeUpsert() { threadUpsert = nil }

    // MARK: - 发送（S3）

    /// 一次投递的结果。`method` = 最终走通的那一级（input / drop / paste），三级全哑则 nil。
    struct AttachOutcome {
        var ok: Bool
        var method: String?
        var tried: String
        var textOK: Bool
    }

    /// 把一张 JPEG 塞进当前对话的输入框，并填一行上下文（书名 + 页码）。
    ///
    /// **不自动按发送**（`AI-PLAN.md §3`）：填好让用户自己发——对 ToS 友好，也避免被判成 bot。
    /// 适配器里的 `editor.focus()` 只在页面内生效，**不抢窗口焦点**（用户还在读书）。
    func attach(imageJPEG: Data, fileName: String, prompt: String) async -> AttachOutcome {
        guard let box = current else {
            return AttachOutcome(ok: false, method: nil, tried: "no page", textOK: false)
        }
        let body = """
        if (!window.__unireader) return null;
        return await window.__unireader.attach(b64, name, mime, text);
        """
        let args: [String: Any] = [
            // base64 走**参数**传进去，JS 里手工 atob —— 不用 fetch(dataURL)，站点 CSP 的
            // connect-src 会把那条挡掉。
            "b64": imageJPEG.base64EncodedString(),
            "name": fileName,
            "mime": "image/jpeg",
            "text": prompt,
        ]
        let raw = await box.callJS(body, arguments: args)
        guard let d = raw as? [String: Any] else {
            return AttachOutcome(ok: false, method: nil, tried: "adapter missing", textOK: false)
        }
        return AttachOutcome(ok: d["ok"] as? Bool ?? false,
                             method: d["method"] as? String,
                             tried: d["tried"] as? String ?? "",
                             textOK: d["textOK"] as? Bool ?? false)
    }

    /// 记一条「发过去的东西」到当前绑定的会话（`contexts`）。还没 commit（新对话尚无 URL）时
    /// 只留在内存里，等 URL 出来那一刻一并落库。
    func noteSentContext(_ c: AIContext) {
        guard var t = boundThread else { return }
        t.addContext(c)
        boundThread = t
        publish(t)
    }

    /// 框选发送前的准备：确保绑定上下文对得上这一页。
    /// **不强制新对话**——框第二块时多半是想接着刚才那个对话继续问。
    func prepareForSend(_ ctx: AIBindContext) {
        if bindContext == nil {
            bindContext = ctx
        } else if bindContext?.sessionID != ctx.sessionID || bindContext?.documentId != ctx.documentId {
            bindContext = ctx
            boundThread = nil          // 换了书/换了窗口：这条对话不该再算在旧绑定上
        }
    }

    // MARK: - 选区 → 文字笔记（S5）

    func noteSelection(_ text: String) {
        pageSelection = text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 有没有条件回填：得有选中的文字，且面板此刻确实绑在某本书的某一页上。
    var canMakeNote: Bool { !pageSelection.isEmpty && bindContext != nil }

    /// 把当前选中的这段回答回填成一条文字笔记。
    ///
    /// **锚点规则（用户定的）**：位置参考「所用的图片」，多张用**第一张** —— 也就是
    /// `boundThread.contexts.first`。一次都没发过东西（纯文字提问）时回落到发起绑定时所在的页，
    /// 用一个靠页面左上的零尺寸锚点（跟阅读区「在此添加批注」的点注解同形态），**别丢**。
    func requestNoteFromSelection() {
        guard let ctx = bindContext, let p = currentProvider, !pageSelection.isEmpty else { return }
        let first = boundThread?.contexts.first
        let page = first?.page ?? ctx.page
        let anchor = first?.rect ?? (ctx.anchor == .zero ? CGRect(x: 0.06, y: 0.06, width: 0, height: 0)
                                                         : ctx.anchor)
        // 这次对话里若发过引文，就把它填进 quote（Inspector 行的第二行显示它）。
        let quote = boundThread?.contexts.first { $0.kind == .quote }?.text ?? ""

        var note = TextNote(page: page, anchor: anchor, quote: quote, text: pageSelection, rects: [])
        note.source = NoteSource(kind: NoteSource.aiKind, provider: p.id,
                                 url: boundThread?.url ?? (current?.url?.absoluteString ?? ""),
                                 threadId: boundThread?.id, at: .now)
        noteRequest = AINoteRequest(sessionID: ctx.sessionID, documentId: ctx.documentId, note: note)
        showFlash(L("Added to notes"))
    }

    func consumeNoteRequest() { noteRequest = nil }

    /// 只按 URL 打开一次对话，**不建立绑定**（笔记记的那条会话已被解绑时用）。
    /// 刻意不合成一条 `AIThread` 去走 `openThread` —— 那会顺手 publish 出一条新绑定记录，
    /// 等于用户点一下「看看出处」就凭空多出一条会话。
    func openLoose(_ urlString: String, provider providerID: String) {
        if providerID != currentID, provider(providerID) != nil { select(providerID) }
        guard let u = URL(string: urlString) else { return }
        unbind()
        current?.load(u)
    }

    private func showFlash(_ s: String) {
        flash = s
        let mine = s
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_400_000_000)
            if flash == mine { flash = nil }
        }
    }

    private func publish(_ t: AIThread) {
        guard let ctx = bindContext else { return }
        threadUpsert = AIThreadUpsert(sessionID: ctx.sessionID, documentId: ctx.documentId, thread: t)
    }

}
