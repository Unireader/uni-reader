import AppKit
import Combine
import Foundation

/// Agent 面板的两种形态（与咨询 AI 面板同一套说法，但各管各的，互不影响）。
enum AgentPanelMode: String {
    /// 独立窗口（全 App 一扇，跟着最近那扇阅读窗口的工作区走）。
    case window
    /// 内置：贴在每扇阅读窗口右侧，收起时是一枚气泡按钮。
    case inline
}

/// 谁在显示对话。每个宿主各有自己的对话，互不串。
enum AgentHost: Hashable {
    case window
    case inline(UUID)   // 阅读窗口的 `TabsModel.windowID`
}

/// Agent 面板的 App 级模型（`ACP-AGENT-PLAN.md`）：形态、各窗口展开状态、Agent 进程池、对话表。
///
/// 进程：**一个工作目录一个**（`AgentConnection`），同目录下的对话共用。最后一段对话走了就关掉进程
/// （`releaseIdleConnections`），⌘Q 时同步杀光（`teardownAll`）——沿用「关闭 = 当场放掉」的纪律。
@MainActor
final class AgentPanelModel: ObservableObject {
    static let shared = AgentPanelModel()

    private static let modeKey = "agentPanelMode"
    private static let inlineOpenKey = "agentInlineOpen"
    private static let inlineWidthKey = "agentInlineWidth"
    static let floatingKey = "agentPanelFloating"

    @Published private(set) var mode: AgentPanelMode = .window
    @Published private(set) var inlineOpenWindows: Set<UUID> = []
    @Published private(set) var inlineOpenDefault = false
    @Published private(set) var inlineWidth: Double = 420
    /// 「跟随 Agent」（本体在 UserDefaults，MCP 那边的网络队列直接读 `AgentFollow.enabled`）。
    @Published private(set) var follow = AgentFollow.enabled
    /// 独立窗口吸附到阅读窗口右侧、同高、跟着移动（`AIPanelDock.agent`）。默认开。
    @Published private(set) var docked = true
    private static let dockKey = "agentPanelDock"

    /// 浮窗当前服务的工作区（跟最近那扇 key 阅读窗口走）。
    @Published private(set) var windowContext: AgentReaderContext?

    private var connections: [String: AgentConnection] = [:]
    private var chats: [AgentHost: AgentChat] = [:]
    /// 阅读窗口登记表（`windowID` → controller），内置面板与浮窗取上下文用。
    private var readers: [UUID: WeakReader] = [:]
    private weak var lastKeyReader: ReaderWindowController?

    private struct WeakReader { weak var controller: ReaderWindowController? }

    private init() {
        let d = UserDefaults.standard
        mode = AgentPanelMode(rawValue: d.string(forKey: Self.modeKey) ?? "") ?? .window
        inlineOpenDefault = d.bool(forKey: Self.inlineOpenKey)
        let w = d.double(forKey: Self.inlineWidthKey)
        if w > 0 { inlineWidth = w }
        docked = d.object(forKey: Self.dockKey) as? Bool ?? true
        enabled = d.object(forKey: Self.enabledKey) as? Bool ?? true
    }

    // MARK: - 总开关

    private static let enabledKey = "agentEnabled"
    /// 设置 ›「通用」›「AI」里的开关（用户 2026-09-19：两种 AI 各自一个开关）。关掉 = 工具栏开关藏起来、
    /// 菜单项灰掉、框选截图不再问要不要发给它、内置侧栏不显示。默认开。
    @Published private(set) var enabled = true

    func setEnabled(_ on: Bool) {
        guard on != enabled else { return }
        enabled = on
        UserDefaults.standard.set(on, forKey: Self.enabledKey)
        guard !on else { return }
        // 关掉就当场放掉：浮窗关掉（它自己的对话随之结束），其余对话与 Agent 进程一并结束
        AgentWindowController.closeIfOpen()
        teardownAll()
    }

    func setDocked(_ on: Bool) {
        guard on != docked else { return }
        docked = on
        UserDefaults.standard.set(on, forKey: Self.dockKey)
        AIPanelDock.agent.setEnabled(on)
    }

    // MARK: - 形态

    func setMode(_ m: AgentPanelMode) {
        guard m != mode else { return }
        mode = m
        UserDefaults.standard.set(m.rawValue, forKey: Self.modeKey)
        if m == .inline {
            AgentWindowController.closeIfOpen()
            inlineOpenDefault = true
            UserDefaults.standard.set(true, forKey: Self.inlineOpenKey)
            if let id = lastKeyReader?.tabs.windowID { inlineOpenWindows.insert(id) }
        } else {
            AgentWindowController.show()
        }
    }

    func isInlineOpen(_ window: UUID) -> Bool { inlineOpenWindows.contains(window) }

    func setInlineOpen(_ open: Bool, for window: UUID) {
        if open { inlineOpenWindows.insert(window) } else { inlineOpenWindows.remove(window) }
        guard open != inlineOpenDefault else { return }
        inlineOpenDefault = open
        UserDefaults.standard.set(open, forKey: Self.inlineOpenKey)
    }

    func seedInlineOpen(_ window: UUID) {
        guard !inlineOpenWindows.contains(window), inlineOpenDefault else { return }
        inlineOpenWindows.insert(window)
    }

    func setInlineWidth(_ w: Double) {
        let clamped = min(max(w, 320), 900)
        guard abs(clamped - inlineWidth) > 0.5 else { return }
        inlineWidth = clamped
        UserDefaults.standard.set(clamped, forKey: Self.inlineWidthKey)
    }

    func setFollow(_ on: Bool) {
        follow = on
        UserDefaults.standard.set(on, forKey: AgentFollow.key)
    }

    /// 菜单 / 快捷键：内置模式切当前 key 窗口的侧栏，浮窗模式显示 ⇄ 隐藏。
    func toggle() {
        guard enabled else { return }
        if mode == .inline {
            guard let id = lastKeyReader?.tabs.windowID else { return }
            setInlineOpen(!isInlineOpen(id), for: id)
        } else {
            AgentWindowController.toggle()
        }
    }

    // MARK: - 阅读窗口

    /// 阅读窗口成了 key（`ReaderWindowController.windowDidBecomeKey`）。
    func noteKeyReader(_ c: ReaderWindowController) {
        readers[c.tabs.windowID] = WeakReader(controller: c)
        lastKeyReader = c
        refreshWindowContext()
    }

    /// 阅读窗口关了：它的内置对话一并结束。
    func readerClosed(_ windowID: UUID) {
        readers.removeValue(forKey: windowID)
        inlineOpenWindows.remove(windowID)
        if let chat = chats.removeValue(forKey: .inline(windowID)) { chat.teardown() }
        releaseIdleConnections()
    }

    /// 浮窗跟的工作区：窗口切换 / 标签切换 / 翻页之后由视图层调（只在真的变了时发布）。
    func refreshWindowContext() {
        let ctx = lastKeyReader.flatMap(Self.context(of:))
        if ctx != windowContext { windowContext = ctx }
    }

    func context(for host: AgentHost) -> AgentReaderContext? {
        switch host {
        case .window: return lastKeyReader.flatMap(Self.context(of:))
        case .inline(let id): return readers[id]?.controller.flatMap(Self.context(of:))
        }
    }

    static func context(of c: ReaderWindowController) -> AgentReaderContext? {
        guard let folder = c.workspace.folder else { return nil }
        let tab = c.tabs.active
        let s = tab.session
        return AgentReaderContext(workspaceName: c.workspace.name, workspaceFolder: folder,
                                  windowId: c.windowId, tabId: tab.id, documentId: tab.docID,
                                  docTitle: s.title, page: s.currentPageIndex,
                                  pageCount: s.pdf?.pageCount ?? 0)
    }

    // MARK: - 对话

    /// 某宿主在某工作目录下的对话。宿主换了工作目录（浮窗跟到另一个工作区）→ 换一份新的，旧的结束。
    func chat(for host: AgentHost, cwd: URL) -> AgentChat {
        if let c = chats[host], c.cwd == cwd { return c }
        chats[host]?.teardown()
        let c = AgentChat(cwd: cwd)
        c.contextProvider = { [weak self] in self?.context(for: host) }
        chats[host] = c
        return c
    }

    /// 这扇阅读窗口能不能把东西发给 Agent（已开工作区 = 有工作目录）。框选截图松手时据此决定菜单里有没有 Agent 那一项。
    func canAttach(from window: UUID) -> Bool { enabled && context(for: .inline(window)) != nil }

    /// 框选截图投给 Agent（`ReaderSurface+Snip`）：把这扇窗对应的面板亮出来（内置 = 展开本窗侧栏，
    /// 浮窗 = 显示），图片挂到那段对话的输入框上，等用户写一句话一起发。
    /// 返回 false = 发不了（没开工作区，或 Agent 已声明不收图片）。
    @discardableResult
    func attach(_ image: AgentImage, from window: UUID) -> Bool {
        guard enabled, let ctx = context(for: .inline(window)) else { return false }
        let host: AgentHost = mode == .inline ? .inline(window) : .window
        // 与面板视图拿的是同一份（`chat(for:cwd:)` 按宿主 + 工作目录复用）；视图还没出来也先建好，图片不丢
        let chat = chat(for: host, cwd: ctx.cwd)
        guard chat.acceptsImages != false else { return false }
        chat.addAttachment(image)
        if mode == .inline { setInlineOpen(true, for: window) } else { AgentWindowController.show() }
        return true
    }

    /// 浮窗关了（不是隐藏）：结束它的对话。
    func releaseHost(_ host: AgentHost) {
        chats.removeValue(forKey: host)?.teardown()
        releaseIdleConnections()
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
