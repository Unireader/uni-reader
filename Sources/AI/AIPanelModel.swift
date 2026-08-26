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

/// AI 面板的 App 级模型：管平台表、每家一个 `WebPage`、登录态与生命周期。
///
/// **形态：全局唯一浮窗**（`Window` scene，id = `windowID`），不是每个阅读窗口一个。
/// 早先方案里写的「每窗口独立 WebPage」是给 Inspector 内嵌准备的；改成单浮窗后每家平台
/// 一个 `WebPage` 就够，还顺带绕开了「一个 WKWebView 不能同时挂两个视图」这条硬约束。
///
/// **登录态**：所有平台共用 `WKWebsiteDataStore.default()`（非沙盒，落
/// `~/Library/WebKit/tech.xvanturing.UniReader`），关 app 不掉登录。
///
/// **内存**：一个 webview 100~300MB，所以 `maxLive` 封顶、按 LRU 淘汰，关窗只留当前这家
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

@MainActor
final class AIPanelModel: ObservableObject {
    static let shared = AIPanelModel()

    /// `Window` scene 的 id，`openWindow(id:)` 用。
    static let windowID = "ai-panel"

    /// 同时存活的 webview 上限（LRU 淘汰）。
    private static let maxLive = 3

    /// 默认 UA 尾巴：WKWebView 的 UA 是「Safari 内核串 + applicationNameForUserAgent」，
    /// 填成这个就得到一条与 Safari 等价的 UA。个别站点还要更彻底的伪装，走
    /// `AIProvider.userAgent` 整条覆盖。
    private static let safariAppName = "Version/26.0 Safari/605.1.15"

    private static let lastProviderKey = "aiProviderID"

    @Published private(set) var providers: [AIProvider] = []
    @Published private(set) var currentID: String = ""
    /// 当前显示的页面。**只在动作里换，不在 body 里创建**（body 里建会触发
    /// 「Modifying state during view update」）。
    @Published private(set) var current: WebPage?
    /// 已创建的平台 id，按最近使用排序（尾部最新）——LRU 淘汰与 UI 上的「已加载」标记都读它。
    @Published private(set) var liveIDs: [String] = []
    /// 平台表是否来自外部配置文件（UI 上标一下，免得改了文件却不知道有没有生效）。
    @Published private(set) var usingExternalConfig = false

    // MARK: 会话绑定（S2）

    /// 面板此刻为哪一页服务。`goHome()`（新对话）不清它——还是同一页，只是换一次对话。
    @Published private(set) var bindContext: AIBindContext?
    /// 当前 URL 对应的那条已落库会话；nil = 还没 commit（新对话尚未发出第一条消息）。
    @Published private(set) var boundThread: AIThread?
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

    private var pages: [String: WebPage] = [:]

    private init() {
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
        for id in pages.keys where !list.contains(where: { $0.id == id }) { drop(id) }
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

    /// 切到某个平台：没建过就现建并载入首页，建过就直接复用（保留登录/滚动/草稿）。
    func select(_ id: String) {
        guard let p = provider(id) else { return }
        currentID = id
        UserDefaults.standard.set(id, forKey: Self.lastProviderKey)

        let page: WebPage
        if let existing = pages[id] {
            page = existing
        } else {
            page = makePage(p)
            pages[id] = page
            page.load(p.homeURL)
        }
        current = page
        touch(id)
        evictIfNeeded()
    }

    private func makePage(_ p: AIProvider) -> WebPage {
        var cfg = WebPage.Configuration()
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
        let page = WebPage(configuration: cfg)
        if let ua = p.userAgent { page.customUserAgent = ua }
        // S3 要靠 Web Inspector 调适配器脚本；正式发布前再决定是否收起来。
        page.isInspectable = true
        return page
    }

    /// LRU 记账：把 id 挪到尾部（最近使用）。
    private func touch(_ id: String) {
        liveIDs.removeAll { $0 == id }
        liveIDs.append(id)
    }

    /// 超出上限就从头（最久未用）开始放，当前这家永不淘汰。
    private func evictIfNeeded() {
        while liveIDs.count > Self.maxLive, let victim = liveIDs.first(where: { $0 != currentID }) {
            drop(victim)
        }
    }

    /// 显式放掉一个页面：先停在途加载再断引用，不等 ARC。
    private func drop(_ id: String) {
        pages[id]?.stopLoading()
        pages.removeValue(forKey: id)
        liveIDs.removeAll { $0 == id }
        if currentID == id { current = nil }
    }

    /// 关窗：只留当前这家（重开面板即时可用），其余全放。
    func releaseIdle() {
        for id in pages.keys where id != currentID { drop(id) }
    }

    /// 退出 / 彻底关闭：全放。
    func teardownAll() {
        for id in pages.keys { drop(id) }
        current = nil
    }

    // MARK: - 导航

    var canGoBack: Bool { !(current?.backForwardList.backList.isEmpty ?? true) }
    var canGoForward: Bool { !(current?.backForwardList.forwardList.isEmpty ?? true) }

    func goBack() {
        guard let page = current, let item = page.backForwardList.backList.last else { return }
        page.load(item)
    }

    func goForward() {
        guard let page = current, let item = page.backForwardList.forwardList.first else { return }
        page.load(item)
    }

    func reload() { current?.reload() }

    func stop() { current?.stopLoading() }

    /// 回首页（相当于「新开一个对话」的入口，具体新建语义 S2 再细化）。
    func goHome() {
        guard let page = current, let p = currentProvider else { return }
        page.load(p.homeURL)
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

        let wasCurrent = (currentID == p.id)
        drop(p.id)
        if wasCurrent { select(p.id) }
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
    func syncFromPage() {
        guard let p = currentProvider else { return }
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
    func noteLoadSettled() {
        guard let openingID = openingThreadID, let p = currentProvider else { return }
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
        guard let page = current else {
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
        let raw = try? await page.callJavaScript(body, arguments: args, contentWorld: .page)
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
