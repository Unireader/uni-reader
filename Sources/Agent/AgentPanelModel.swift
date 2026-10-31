import AppKit
import Combine
import Foundation

/// Agent 面板的 App 级模型（`ACP-AGENT-PLAN.md`）：总开关、Agent 进程池、对话表。
///
/// 面板本身只有一种形态（2026-09-19 用户定）：**阅读窗口 Inspector 的「Agent」页**，每扇阅读窗口各一段对话。
/// 从前的独立窗口、浮在阅读区右侧的内置面板都已删掉。
///
/// 进程：**一个工作目录一个**（`AgentConnection`），同目录下的对话共用。最后一段对话走了就关掉进程
/// （`releaseIdleConnections`），⌘Q 时同步杀光（`teardownAll`）——沿用「关闭 = 当场放掉」的纪律。
@MainActor
final class AgentPanelModel: ObservableObject {
    static let shared = AgentPanelModel()

    /// 「跟随 Agent」（本体在 UserDefaults，MCP 那边的网络队列直接读 `AgentFollow.enabled`）。
    @Published private(set) var follow = AgentFollow.enabled

    private var connections: [String: AgentConnection] = [:]
    /// 阅读窗口（`TabsModel.windowID`）→ 它 Inspector 里那段对话。
    private var chats: [UUID: AgentChat] = [:]
    /// 阅读窗口登记表（`windowID` → controller），取上下文与亮出 Agent 页用。
    private var readers: [UUID: WeakReader] = [:]
    private weak var lastKeyReader: ReaderWindowController?

    private struct WeakReader { weak var controller: ReaderWindowController? }

    private init() {
        enabled = UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true
        preloadAtLaunch = UserDefaults.standard.bool(forKey: Self.preloadKey)
    }

    // MARK: - 总开关

    private static let enabledKey = "agentEnabled"
    /// 设置 ›「通用」›「AI」里的开关。关掉 = 工具栏开关藏起来、菜单项灰掉、框选截图不再问要不要发给它、
    /// Inspector 没有「Agent」页。默认开。
    @Published private(set) var enabled = true

    func setEnabled(_ on: Bool) {
        guard on != enabled else { return }
        enabled = on
        UserDefaults.standard.set(on, forKey: Self.enabledKey)
        guard !on else { return }
        // 关掉就当场放掉：对话与 Agent 进程一并结束
        teardownAll()
    }

    // MARK: - 后台预加载

    private static let preloadKey = "agentPreloadAtLaunch"
    /// 设置 › Agent ›「启动时在后台加载」（用户 2026-10-07：「启动 app 自动加载 agent（后台），这样不用点开才加载了」）。
    /// 开着时阅读窗口一有工作区（启动时打开 / 之后换工作区）就替它建好对话：拉起进程、握手、建会话，
    /// 切到 Agent 页时已经连上。默认关：开着就是每个工作目录常驻一个 Agent 进程，哪怕从没打开过 Agent 页。
    @Published private(set) var preloadAtLaunch = false

    /// 打开后各阅读窗口经自己的订阅（`ReaderWindowController`）各自预加载；关掉不收已经建好的对话——
    /// 和打开过 Agent 页一样，关窗 / 换工作区 / 退出时才结束。
    func setPreloadAtLaunch(_ on: Bool) {
        guard on != preloadAtLaunch else { return }
        preloadAtLaunch = on
        UserDefaults.standard.set(on, forKey: Self.preloadKey)
    }

    /// 替这扇阅读窗口预先建好 Agent 对话（总开关与预加载都开着、窗口已开工作区时）。Inspector 的 Agent 页之后拿到的
    /// 是同一份（`chat(for:cwd:)` 按窗口 + 工作目录复用），视图进窗口时的 `start()` 见已有会话 / 正在连就什么都不做。
    func preloadChat(for c: ReaderWindowController) {
        guard enabled, preloadAtLaunch, let ctx = Self.context(of: c) else { return }
        readers[c.tabs.windowID] = WeakReader(controller: c)   // 对话的上下文 / `@` 候选按窗口登记表取
        agentLog("后台预加载 Agent · cwd=\(ctx.cwd.path)")
        chat(for: c.tabs.windowID, cwd: ctx.cwd).start()
    }

    func setFollow(_ on: Bool) {
        follow = on
        UserDefaults.standard.set(on, forKey: AgentFollow.key)
    }

    /// 菜单 / 快捷键：当前 key 阅读窗口的 Inspector 切到 Agent 页（已经在显示就收起）。
    func toggle() {
        guard enabled else { return }
        lastKeyReader?.toggleAgentTab()
    }

    // MARK: - 阅读窗口

    /// 阅读窗口成了 key（`ReaderWindowController.windowDidBecomeKey`）。
    func noteKeyReader(_ c: ReaderWindowController) {
        readers[c.tabs.windowID] = WeakReader(controller: c)
        lastKeyReader = c
    }

    /// 阅读窗口关了：它的对话一并结束。
    func readerClosed(_ windowID: UUID) {
        readers.removeValue(forKey: windowID)
        if let chat = chats.removeValue(forKey: windowID) { chat.teardown() }
        releaseIdleConnections()
    }

    func context(for window: UUID) -> AgentReaderContext? {
        readers[window]?.controller.flatMap(Self.context(of:))
    }

    static func context(of c: ReaderWindowController) -> AgentReaderContext? {
        guard let folder = c.workspace.folder else { return nil }
        let tab = c.tabs.active
        let s = tab.session
        let markdown: AgentReaderContext.MarkdownNote? = tab.noteRef.map { ref in
            let source = c.workspace.noteSource(id: ref.sourceID)
            var link = DeepLink()
            link.workspacePath = folder.path
            link.workspaceId = c.workspace.store?.workspaceId
            link.markdownId = ref.key
            return AgentReaderContext.MarkdownNote(
                ref: ref.key,
                title: ref.title,
                sourceName: source?.name ?? ref.sourceID,
                sourceKind: source?.kind.rawValue ?? "unknown",
                relativePath: ref.relPath,
                link: link.absoluteString)
        }
        return AgentReaderContext(workspaceName: c.workspace.name, workspaceFolder: folder,
                                  windowId: c.windowId, tabId: tab.id, documentId: tab.docID,
                                  docTitle: s.title, page: s.currentPageIndex,
                                  pageCount: s.pdf?.pageCount ?? 0, markdown: markdown)
    }

    // MARK: - 对话

    /// 某扇阅读窗口在某工作目录下的对话。窗口换了工作区（工作目录变了）→ 换一份新的，旧的结束。
    func chat(for window: UUID, cwd: URL) -> AgentChat {
        if let c = chats[window], c.cwd == cwd { return c }
        chats[window]?.teardown()
        let c = AgentChat(cwd: cwd)
        c.contextProvider = { [weak self] in self?.context(for: window) }
        c.mentionProvider = { [weak self] in
            self?.readers[window]?.controller.map { Self.mentions(in: $0.workspace) } ?? []
        }
        chats[window] = c
        return c
    }

    /// 输入框 `@` 的候选：书库里的 PDF + 全部源里的 Markdown 笔记，混在一起按最近打开排
    /// （引用源的笔记没有「上次打开」，排在最后）。
    /// PDF 要逐篇查一次库 + stat 文件，所以只在弹出候选时取一次（不是每敲一个字取一次）。
    static func mentions(in ws: WorkspaceManager) -> [AgentMention] {
        var out: [(Date, AgentMention)] = []
        for d in ws.documents { out.append((d.lastOpenedAt, .pdf(d, in: ws))) }
        for n in ws.allNotes {
            guard let m = AgentMention.note(n, in: ws) else { continue }
            out.append((n.lastOpenedAt ?? .distantPast, m))
        }
        // 稳定排序：同一时间（多为「没打开过」）保持原来的先后
        return out.enumerated()
            .sorted { $0.element.0 != $1.element.0 ? $0.element.0 > $1.element.0 : $0.offset < $1.offset }
            .map(\.element.1)
    }

    /// 这扇阅读窗口能不能把东西发给 Agent（已开工作区 = 有工作目录）。框选截图松手时据此决定菜单里有没有 Agent 那一项。
    func canAttach(from window: UUID) -> Bool { enabled && context(for: window) != nil }

    /// 这扇窗的 Agent 页在跟谁说话（设置里换了 Agent、还没点「新对话」时仍是旧的那个）。
    func agentName(for window: UUID) -> String { chats[window]?.agentName ?? AgentConfig.displayName }

    /// 框选截图投给 Agent（`ReaderView+Snip`）：这扇窗的 Inspector 切到 Agent 页，图片挂到那段对话的输入框上，
    /// 等用户写一句话一起发。返回 false = 发不了（没开工作区，或 Agent 已声明不收图片）。
    @discardableResult
    func attach(_ image: AgentImage, from window: UUID) -> Bool {
        guard enabled, let ctx = context(for: window) else { return false }
        // 与 Inspector 视图拿的是同一份（`chat(for:cwd:)` 按窗口 + 工作目录复用）；视图还没出来也先建好，图片不丢
        let chat = chat(for: window, cwd: ctx.cwd)
        guard chat.acceptsImages != false else { return false }
        chat.addAttachment(image)
        readers[window]?.controller?.showAgentTab()
        return true
    }

    /// 侧栏「在 Agent 中引用」（`ACP-AGENT-PLAN.md §11`）：这扇窗的 Agent 输入框在光标处插进这几样的 `@名字`，
    /// 发送时照 `@` 选的一样附上；面板亮出来、光标留在输入框。返回 false = 发不了（Agent 关着 / 没开工作区）。
    @discardableResult
    func reference(_ mentions: [AgentMention], from window: UUID) -> Bool {
        guard enabled, !mentions.isEmpty, let ctx = context(for: window) else { return false }
        chat(for: window, cwd: ctx.cwd).requestMentions(mentions)
        readers[window]?.controller?.showAgentTab()
        return true
    }

    /// 往这扇窗的 Agent 输入框里放一句话（输入框里已有字就接在后面），图片挂上，`note` 进下一次发送的隐藏上下文块；
    /// 面板亮出来，等用户点发送（习题「让 Agent 批改」，`EXERCISE-PLAN.md §11.4`）。Agent 不收图片时只放文字。
    /// 返回 false = 发不了（Agent 关着 / 没开工作区）。
    @discardableResult
    func prepare(text: String, note: String?, images: [AgentImage], from window: UUID) -> Bool {
        guard enabled, let ctx = context(for: window) else { return false }
        let chat = chat(for: window, cwd: ctx.cwd)
        if chat.acceptsImages != false { for img in images { chat.addAttachment(img) } }
        if let note { chat.addContextNote(note) }
        chat.requestDraft(text)
        readers[window]?.controller?.showAgentTab()
        return true
    }

    // MARK: - 进程池

    /// 按设置里现在选的 Agent 取（或起）这个工作目录的进程。池子的键带上启动配置：换了 Agent 时新旧进程各占一格，
    /// 还在旧进程上聊的对话不受影响，旧进程没人用了照常由 `releaseIdleConnections` 关掉。
    func connection(for cwd: URL) -> AgentConnection {
        let launch = AgentConfig.current
        let key = ([cwd.standardizedFileURL.path, launch.command] + launch.arguments).joined(separator: "\u{1}")
        if let c = connections[key], !c.isDead { return c }
        let c = AgentConnection(cwd: cwd, launch: launch)
        c.onExit = { [weak self, weak c] in
            guard let self, let c, self.connections[key] === c else { return }
            self.connections.removeValue(forKey: key)
        }
        connections[key] = c
        return c
    }

    /// 没有对话在用的进程关掉（关对话、换会话、关窗之后调）。
    func releaseIdleConnections() {
        for (key, c) in connections where !c.hasChats {
            connections.removeValue(forKey: key)
            agentLog("关闭空闲 Agent \(c.launch.command) · cwd=\(c.cwd.path)")
            Task { await c.terminate() }
        }
    }

    /// ⌘Q：同步杀掉所有 Agent 进程组（退出等不起异步收尾）。
    func teardownAll() {
        // 先杀进程再收对话：对话收尾会走 `releaseIdleConnections`，那条路是异步关、退出时等不到
        for c in connections.values { c.killNow() }
        connections.removeAll()
        for c in chats.values { c.teardown() }
        chats.removeAll()
    }
}
