import ACP
import ACPModel
import Foundation

/// 一个 ACP Agent 子进程（`ACP-AGENT-PLAN.md`）。**一个工作目录一个进程**，同目录下的几个对话
/// （浮窗那一份 + 各阅读窗口内置面板各一份）共用它，各自是 Agent 里的一个 session。
///
/// 工作目录 = 工作区 `.unrd` 包**所在的目录**（包的上一级，用户 2026-09-18 定），所以同一目录下的
/// 几个工作区也共用一个进程；Kimi 按工作目录记历史会话（`session/list` 带 `cwd` 过滤），
/// App 自己**一条会话数据都不存**。
///
/// 线程：本类在主线程；`Client` 是 swift-acp 的 actor，调用一律 `await`。
/// 通知（`session/update`）按 `sessionId` 分发给登记过的 `AgentChat`。
@MainActor
final class AgentConnection {
    let cwd: URL

    private let client = Client()
    private let delegate = AgentClientDelegate()
    private var starting: Task<InitializeResponse, Error>?
    private(set) var initResponse: InitializeResponse?
    /// 进程组 id：⌘Q 时要**同步**杀掉（退出时等不起 actor 上的 `terminate()`）。
    private var pgid: Int32?
    private var pump: Task<Void, Never>?
    private var chats: [String: WeakChat] = [:]
    private(set) var isDead = false
    /// 进程没了（崩溃 / 被杀 / 自己退出）。池子据此把它摘掉，下次用时重开。
    var onExit: (() -> Void)?

    private struct WeakChat { weak var chat: AgentChat? }

    init(cwd: URL) {
        self.cwd = cwd
        delegate.connection = self
    }

    // MARK: - 启动

    /// 懒启动：第一次用时拉起进程并握手，之后直接返回握手结果。并发调用共用同一次启动。
    func ready() async throws -> InitializeResponse {
        if let initResponse { return initResponse }
        if let starting { return try await starting.value }
        let t = Task { try await self.launch() }
        starting = t
        do {
            let r = try await t.value
            initResponse = r
            return r
        } catch {
            // 启动失败的这份作废（`terminate` 之后通知流已结束，不能复用）：池子摘掉，下次用时重开一份
            await client.terminate()
            if !isDead { isDead = true; onExit?() }
            throw error
        }
    }

    private func launch() async throws -> InitializeResponse {
        let exe = try await AgentConfig.resolveExecutable(AgentConfig.command)
        agentLog("启动 \(exe) \(AgentConfig.arguments.joined(separator: " ")) · cwd=\(cwd.path)")
        await client.setDelegate(delegate)
        try await client.launch(agentPath: exe, arguments: AgentConfig.arguments, workingDirectory: cwd.path)
        pgid = await client.processGroupIdentifier()
        startPump()
        let version = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0"
        let r = try await client.initialize(
            // 不声明 fs / terminal：我们不是编辑器，Agent 用它自己的文件与命令工具，权限请求照样发给我们
            capabilities: ClientCapabilities(fs: FileSystemCapabilities(readTextFile: false, writeTextFile: false),
                                             terminal: false),
            // 限定模块名：App 里另有一个 `ClientInfo`（平板客户端信息）
            clientInfo: ACPModel.ClientInfo(name: "UniReader", title: "UniReader", version: version),
            timeout: 60)
        agentLog("握手完成 proto=\(r.protocolVersion)")
        return r
    }

    /// 通知泵：进程退出时 swift-acp 会结束这条流 → 这里收尾。
    private func startPump() {
        pump = Task { [weak self, client] in
            let enc = JSONEncoder(), dec = JSONDecoder()
            for await n in await client.notifications {
                guard n.method == "session/update", let p = n.params,
                      let data = try? enc.encode(p),
                      let u = try? dec.decode(SessionUpdateNotification.self, from: data) else { continue }
                self?.chats[u.sessionId.value]?.chat?.apply(u.update)
            }
            self?.didExit()
        }
    }

    private func didExit() {
        guard !isDead else { return }
        isDead = true
        agentLog("Agent 进程已退出 · cwd=\(cwd.path)")
        for w in chats.values { w.chat?.agentDidExit() }
        chats.removeAll()
        onExit?()
    }

    // MARK: - 会话登记

    func register(_ chat: AgentChat, sessionId: String) { chats[sessionId] = WeakChat(chat: chat) }
    func unregister(sessionId: String) { chats.removeValue(forKey: sessionId) }
    var hasChats: Bool { chats.values.contains { $0.chat != nil } }

    fileprivate func chat(for sessionId: String) -> AgentChat? { chats[sessionId]?.chat }

    // MARK: - 请求（薄转发）

    func newSession(mcp: [MCPServerConfig]) async throws -> NewSessionResponse {
        _ = try await ready()
        return try await client.newSession(workingDirectory: cwd.path, mcpServers: mcp, timeout: 120)
    }

    /// 回放历史：Agent 先把整段对话用 `session/update` 推一遍再回响应，所以**调用前**要先 `register`。
    func loadSession(_ id: String, mcp: [MCPServerConfig]) async throws -> LoadSessionResponse {
        _ = try await ready()
        return try await client.loadSession(sessionId: SessionId(id), cwd: cwd.path, mcpServers: mcp)
    }

    func listSessions() async throws -> [SessionInfo] {
        let r = try await ready()
        guard r.agentCapabilities.sessionCapabilities?.list != nil else { return [] }
        var all: [SessionInfo] = []
        var cursor: String?
        repeat {
            let page = try await client.listSessions(cwd: cwd.path, cursor: cursor, timeout: 30)
            all += page.sessions
            cursor = page.nextCursor
        } while cursor != nil && all.count < 200
        return all
    }

    func prompt(_ id: String, _ blocks: [ContentBlock]) async throws -> SessionPromptResponse {
        try await client.sendPrompt(sessionId: SessionId(id), content: blocks)
    }

    func cancel(_ id: String) async {
        try? await client.cancelSession(sessionId: SessionId(id))
    }

    func setMode(_ id: String, mode: String) async throws {
        _ = try await client.setMode(sessionId: SessionId(id), modeId: mode)
    }

    func setConfig(_ id: String, config: String, value: String) async throws -> [SessionConfigOption] {
        try await client.setConfigOption(sessionId: SessionId(id), configId: SessionConfigId(config),
                                         value: SessionConfigValueId(value)).configOptions
    }

    func setConfig(_ id: String, config: String, flag: Bool) async throws -> [SessionConfigOption] {
        try await client.setConfigOption(sessionId: SessionId(id), configId: SessionConfigId(config),
                                         value: flag).configOptions
    }

    // MARK: - 结束

    func terminate() async {
        // 先标记作废：谁手上还攥着这份引用（`AgentChat.connection`），下次用时会看到 isDead 重开一份，
        // 而不是往正在关的进程里写
        isDead = true
        pump?.cancel()
        await client.terminate()
    }

    /// ⌘Q 用：同步把整个进程组发 SIGTERM（Agent 自己再拉的子进程也一并带走）。
    func killNow() {
        if let pgid, pgid > 0 { kill(-pgid, SIGTERM) }
    }

    // MARK: - Agent → 客户端的请求

    /// 权限请求交给对应的对话去问用户；找不到对话（已关）就按取消回。
    fileprivate func askPermission(_ req: RequestPermissionRequest) async -> RequestPermissionResponse {
        guard let chat = chat(for: req.sessionId.value) else {
            return RequestPermissionResponse(outcome: PermissionOutcome(cancelled: true))
        }
        return await chat.askPermission(req)
    }
}

/// swift-acp 要一个 delegate 接 Agent 反过来发的请求。我们只接权限请求；
/// 文件与终端没声明能力，Agent 不会发来，万一发了就报不支持。
final class AgentClientDelegate: ClientDelegate, @unchecked Sendable {
    weak var connection: AgentConnection?

    struct Unsupported: LocalizedError {
        var errorDescription: String? { "UniReader does not provide this capability" }
    }

    func handlePermissionRequest(request: RequestPermissionRequest) async throws -> RequestPermissionResponse {
        guard let c = connection else { return RequestPermissionResponse(outcome: PermissionOutcome(cancelled: true)) }
        return await c.askPermission(request)
    }

    func handleFileReadRequest(_ path: String, sessionId: String, line: Int?, limit: Int?) async throws -> ReadTextFileResponse { throw Unsupported() }
    func handleFileWriteRequest(_ path: String, content: String, sessionId: String) async throws -> WriteTextFileResponse { throw Unsupported() }
    func handleTerminalCreate(command: String, sessionId: String, args: [String]?, cwd: String?, env: [EnvVariable]?, outputByteLimit: Int?) async throws -> CreateTerminalResponse { throw Unsupported() }
    func handleTerminalOutput(terminalId: TerminalId, sessionId: String) async throws -> TerminalOutputResponse { throw Unsupported() }
    func handleTerminalWaitForExit(terminalId: TerminalId, sessionId: String) async throws -> WaitForExitResponse { throw Unsupported() }
    func handleTerminalKill(terminalId: TerminalId, sessionId: String) async throws -> KillTerminalResponse { throw Unsupported() }
    func handleTerminalRelease(terminalId: TerminalId, sessionId: String) async throws -> ReleaseTerminalResponse { throw Unsupported() }
}

/// 统一前缀，便于在 Console / 日志里筛（与 `mcpLog` 同款）。
func agentLog(_ s: String) {
    NSLog("[Agent] %@", s)
}
