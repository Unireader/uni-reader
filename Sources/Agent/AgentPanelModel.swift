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
        for d in ws.documents {
            let path = ws.currentFilePath(documentId: d.id)
            var uri: String
            if let path {
                uri = URL(fileURLWithPath: path).absoluteString
            } else {
                var link = DeepLink()
                link.workspacePath = ws.folder?.path
                link.workspaceId = ws.store?.workspaceId
                link.documentId = d.id
                uri = link.absoluteString
            }
            let file = path.map { ($0 as NSString).lastPathComponent } ?? d.title + ".pdf"
            out.append((d.lastOpenedAt, AgentMention(kind: .pdf, id: d.id, name: file,
                                                     detail: file == d.title + ".pdf" ? "" : d.title, uri: uri)))
        }
        for n in ws.allNotes {
            guard let url = ws.noteURL(n.ref) else { continue }
            let src = ws.noteSource(id: n.ref.sourceID)?.name ?? ""
            let place = [src, n.ref.folder].filter { !$0.isEmpty }.joined(separator: " / ")
            out.append((n.lastOpenedAt ?? .distantPast,
                        AgentMention(kind: .note, id: n.ref.key, name: url.lastPathComponent,
                                     detail: place, uri: url.absoluteString)))
        }
        // 稳定排序：同一时间（多为「没打开过」）保持原来的先后
        return out.enumerated()
            .sorted { $0.element.0 != $1.element.0 ? $0.element.0 > $1.element.0 : $0.offset < $1.offset }
            .map(\.element.1)
    }

    /// 这扇阅读窗口能不能把东西发给 Agent（已开工作区 = 有工作目录）。框选截图松手时据此决定菜单里有没有 Agent 那一项。
    func canAttach(from window: UUID) -> Bool { enabled && context(for: window) != nil }

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

    // MARK: - 进程池

    func connection(for cwd: URL) -> AgentConnection {
        let key = cwd.standardizedFileURL.path
        if let c = connections[key], !c.isDead { return c }
        let c = AgentConnection(cwd: cwd)
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
            agentLog("关闭空闲 Agent · cwd=\(key)")
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
