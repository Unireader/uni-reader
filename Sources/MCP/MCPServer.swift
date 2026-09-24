import Foundation
import Network

/// MCP 服务的日志通道（`[MCP]` 前缀），开关口径同 `wsLog`——**文件在不在就是开关**：
/// ```
/// touch ~/Library/Logs/UniReader-mcp.log    # 开启
/// rm    ~/Library/Logs/UniReader-mcp.log    # 关闭
/// ```
/// 每个请求一行：方法 / 工具名 / 耗时 / 结果。**不记工具返回的正文**（一页文本几千字，日志会被冲没）。
let mcpLogURL = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Logs/UniReader-mcp.log")

func mcpLog(_ msg: String) {
    NSLog("[MCP] %@", msg)
    guard let h = try? FileHandle(forWritingTo: mcpLogURL) else { return }
    defer { try? h.close() }
    let line = "\(Date.now.formatted(date: .omitted, time: .standard)) [\(ProcessInfo.processInfo.processIdentifier)] \(msg)\n"
    _ = try? h.seekToEnd()
    try? h.write(contentsOf: Data(line.utf8))
}

/// MCP 口令（方案 §4.6）。本体在 Keychain（同 API key 的做法，不落 UserDefaults 明文）。
enum MCPToken {
    private static let account = "mcpToken"

    static func current() -> String? {
        guard let t = Keychain.read(account), !t.isEmpty else { return nil }
        return t
    }

    /// 32 字节随机数，base64url（无 `+/=`，放进命令行/JSON 不用转义）。
    static func generate() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    @discardableResult
    static func regenerate() -> String {
        let t = generate()
        Keychain.write(account, t)
        return t
    }

    static func remove() { Keychain.delete(account) }
}

/// 面板上「最近调用」的一行。
struct MCPCallRecord: Identifiable {
    let id = UUID()
    let at: Date
    let client: String
    let what: String        // 方法名，tools/call 时是工具名
    let ms: Int
    let ok: Bool
    let summary: String     // 出错时的一句话；成功为空
}

/// 面板上「已连接客户端」的一行。
struct MCPClientRecord: Identifiable, Equatable {
    var id: String          // 会话 id
    var name: String
    var version: String
    var protocolVersion: String
    var since: Date
}

/// MCP 服务本体（方案 §3 / §4.2 / §5.2）：监听 → 最小 HTTP → 口令/Origin 校验 → 会话 → `MCPDispatcher`。
///
/// 与 `LANServer` 各自独立：**不共用端口，不共用队列**——平板取页图那条串行队列是热路径，
/// 一次 40 页文本抽取塞进去平板就卡半秒（方案 §5.3 第 2 条）。
final class MCPServer: ObservableObject {
    // MARK: 设置（`UserDefaults`；口令在 Keychain，见 `MCPToken`）

    static let autoStartKey = "mcpAutoStart"
    static let bindKey = "mcpBind"
    static let portKey = "mcpPort"
    /// 批 3 的写入开关；批 1 就把键定下来，`get_state` 报出去。
    static let allowWritesKey = "mcpAllowWrites"
    static let defaultPort = 8773

    /// 监听地址（决策 D5）：默认只绑本机回环；「所有网络接口」必须配口令。
    enum Bind: String, CaseIterable {
        case loopback, all
    }

    static var bind: Bind {
        Bind(rawValue: UserDefaults.standard.string(forKey: bindKey) ?? "") ?? .loopback
    }

    static var port: UInt16 {
        let v = UserDefaults.standard.integer(forKey: portKey)
        return (v >= 1024 && v <= 65535) ? UInt16(v) : UInt16(defaultPort)
    }

    static var allowWrites: Bool { UserDefaults.standard.bool(forKey: allowWritesKey) }

    // MARK: 面板状态（主线程）

    @Published private(set) var isRunning = false
    /// 实际生效的监听方式（所有接口模式没口令会回落到回环，见 `start()`）。
    @Published private(set) var effectiveBind: Bind = .loopback
    @Published private(set) var listeningPort: UInt16 = UInt16(defaultPort)
    @Published private(set) var lastError: String?
    @Published private(set) var recentCalls: [MCPCallRecord] = []
    @Published private(set) var clients: [MCPClientRecord] = []

    static let recentLimit = 50

    // MARK: 内部

    let catalog = MCPCatalog()
    let sessions = MCPSessionStore()
    private lazy var dispatcher = MCPDispatcher(
        catalog: catalog,
        info: MCPServerInfo(name: "UniReader", version: Self.appVersion, instructions: Self.instructions),
        sessions: sessions,
        writesEnabled: { MCPServer.allowWrites })

    private let queue = DispatchQueue(label: "tech.xvanturing.unireader.mcp.net")
    private var listener: NWListener?
    /// 口令从哪来（默认 Keychain）。spike 换成固定值，免得测试碰真 Keychain。
    var tokenProvider: () -> String? = { MCPToken.current() }
    /// 口令的服务队列副本（启动时读一次 Keychain；重置口令走 `restart()`）。只在 `queue` 上读。
    private var token: String?
    /// 所有接口模式下额外放行的 Origin 主机（本机局域网地址）。只在 `queue` 上读。
    private var localHosts: [String] = []

    static var appVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0"
    }

    /// 给模型看的说明（英文），随 `initialize` 下发。
    static let instructions = """
    UniReader is a PDF and Markdown note reader with per-workspace libraries. Pages are 1-based. \
    Call get_state first to learn which workspace and tab the user is looking at. \
    get_current_view returns the active PDF position or the active Markdown note's live text and revision. \
    For Markdown notes: list_markdown_notes gives note_ref values; read_markdown reads any note by line range \
    (with line numbers), by search, or as a heading outline; edit_markdown changes part of a note by exact \
    old_text replacement or line insertion — prefer it over update_markdown, which replaces the whole text. \
    Never edit files inside a .unrd package directly. \
    Most PDF tools default to the document in the key window when no target is given. \
    document_id is a stable UUID inside a workspace; file paths may change. \
    read_pages returns the PDF's own text, or cached OCR text for scanned pages (empty with a hint when neither exists).
    """

    /// 本机能访问到的端点（面板展示 + 配置片段）。
    var endpointURL: String {
        let host: String
        switch effectiveBind {
        case .loopback: host = "127.0.0.1"
        case .all: host = NetInfo.wifiIPv4() ?? "127.0.0.1"
        }
        return "http://\(host):\(listeningPort)/mcp"
    }

    // MARK: - 生命周期（主线程调用）

    func start() {
        guard !isRunning else { return }
        var bind = Self.bind
        let port = Self.port
        let tok = tokenProvider()
        if bind == .all, tok == nil {
            // 🔴 没口令绝不以 0.0.0.0 启动（用户 2026-09-13 定）：回落回环并留一句说明
            lastError = L("Listening on all interfaces requires a token; started on 127.0.0.1 only.")
            bind = .loopback
        } else {
            lastError = nil
        }
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        let listener: NWListener
        do {
            switch bind {
            case .loopback:
                params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
                listener = try NWListener(using: params)
            case .all:
                listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
            }
        } catch {
            lastError = String(format: L("Cannot listen on port %d: %@"), Int(port), error.localizedDescription)
            mcpLog("启动失败：\(error)")
            return
        }
        let hosts = bind == .all ? [NetInfo.wifiIPv4()].compactMap { $0 } : []
        queue.async {
            self.token = tok
            self.localHosts = hosts
        }
        listener.newConnectionHandler = { [weak self] conn in self?.serve(conn) }
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .failed(let e):
                mcpLog("监听失败：\(e)")
                DispatchQueue.main.async {
                    self.lastError = String(format: L("Cannot listen on port %d: %@"), Int(port), e.localizedDescription)
                    self.stop()
                }
            case .ready:
                mcpLog("监听就绪 \(bind.rawValue):\(port) 口令=\(tok == nil ? "无" : "有")")
            default: break
            }
        }
        listener.start(queue: queue)
        self.listener = listener
        effectiveBind = bind
        listeningPort = port
        isRunning = true
    }

    func stop() {
        listener?.cancel(); listener = nil
        Task { await sessions.removeAll() }
        clients = []
        isRunning = false
        mcpLog("已停止")
    }

    /// 改了监听地址/端口/口令后重启。`stop()` 是同步的，直接接 `start()` 即可
    /// （不像 `LANServer.resetToken` 那样要等主线程下一拍——这里 `isRunning` 在 `stop()` 里同步翻回去）。
    func restart() {
        let was = isRunning
        stop()
        if was { start() }
    }

    // MARK: - 连接

    private func serve(_ conn: NWConnection) {
        conn.start(queue: queue)
        receive(conn, buffer: Data())
    }

    /// 攒字节直到解出一个完整请求（头体可能分多次到）。一问一答后关连接（`Connection: close`）。
    private func receive(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { conn.cancel(); return }
            var buf = buffer
            if let data { buf.append(data) }
            if error != nil { conn.cancel(); return }
            switch MCPHTTP.parse(buf) {
            case .incomplete:
                if isComplete { conn.cancel() } else { self.receive(conn, buffer: buf) }
            case let .invalid(status, message):
                self.send(.text(status, message), on: conn)
            case let .complete(req, _):
                self.handle(req, on: conn)
            }
        }
    }

    private func send(_ r: MCPHTTP.Response, on conn: NWConnection) {
        conn.send(content: MCPHTTP.serialize(r), completion: .contentProcessed { _ in conn.cancel() })
    }

    /// 在 `queue` 上：路由 + 安全校验，然后交给调度器（async）。
    private func handle(_ req: MCPHTTP.Request, on conn: NWConnection) {
        switch req.path {
        case "/health":
            send(.text(200, "ok"), on: conn)
            return
        case "/mcp":
            break
        default:
            send(.text(404, "not found"), on: conn)
            return
        }
        guard MCPHTTP.originAllowed(req.header("origin"), localHosts: localHosts) else {
            send(.text(403, "origin not allowed"), on: conn)
            return
        }
        guard MCPHTTP.tokenMatches(MCPHTTP.bearer(req.headers), expected: token) else {
            send(.json(401, ["error": "missing or wrong bearer token; copy it from UniReader › Settings › Agent"]), on: conn)
            return
        }
        if let v = req.header("mcp-protocol-version"), !MCPVersions.supported.contains(v) {
            send(.json(400, ["error": "unsupported MCP-Protocol-Version \(v); supported: \(MCPVersions.supported.joined(separator: ", "))"]), on: conn)
            return
        }
        let sessionID = req.header("mcp-session-id")
        switch req.method {
        case "POST":
            break
        case "DELETE":
            if let sessionID { Task { await self.sessions.remove(sessionID); self.refreshClients() } }
            send(.empty(200), on: conn)
            return
        case "GET":
            // 不提供服务端推送流（方案 §4.2）
            send(.text(405, "GET is not supported; this server does not open server-to-client streams"), on: conn)
            return
        default:
            send(.text(405, "method not allowed"), on: conn)
            return
        }
        let t0 = CFAbsoluteTimeGetCurrent()
        Task { [dispatcher, sessions] in
            await sessions.sweep()
            var session: MCPSession?
            if let sessionID {
                session = await sessions.touch(sessionID)
                if session == nil {
                    // 会话不存在/已过期 → 404，客户端会重新握手（协议规定）
                    self.send(.json(404, ["error": "unknown or expired Mcp-Session-Id; send initialize again"]), on: conn)
                    return
                }
            }
            let outcome = await dispatcher.dispatch(body: req.body, session: session,
                                                    inAppAgent: req.header(AgentFollow.header) != nil)
            let ms = Int((CFAbsoluteTimeGetCurrent() - t0) * 1000)
            switch outcome {
            case .accepted:
                self.send(.empty(202), on: conn)
            case let .response(obj):
                self.record(req.body, obj, client: session?.clientName ?? "-", ms: ms)
                self.send(.json(200, obj), on: conn)
            case let .initialized(s, response):
                self.record(req.body, response, client: s.clientName, ms: ms)
                self.refreshClients()
                self.send(.json(200, response, extra: [("Mcp-Session-Id", s.id)]), on: conn)
            }
        }
    }

    // MARK: - 面板数据

    private func record(_ body: Data, _ response: MCPObject, client: String, ms: Int) {
        let req = (MCPJSON.parse(body) as? MCPObject) ?? [:]
        var what = (req["method"] as? String) ?? "?"
        if what == "tools/call", let name = (req["params"] as? MCPObject)?["name"] as? String { what = name }
        var ok = true
        var summary = ""
        if let err = response["error"] as? MCPObject {
            ok = false
            summary = (err["message"] as? String) ?? ""
        } else if let res = response["result"] as? MCPObject, res["isError"] as? Bool == true {
            ok = false
            summary = ((res["content"] as? [MCPObject])?.first?["text"] as? String) ?? ""
        }
        mcpLog("\(client) \(what) \(ms)ms \(ok ? "ok" : "失败：\(summary)")")
        let rec = MCPCallRecord(at: .now, client: client, what: what, ms: ms, ok: ok, summary: summary)
        DispatchQueue.main.async {
            self.recentCalls.insert(rec, at: 0)
            if self.recentCalls.count > Self.recentLimit { self.recentCalls.removeLast(self.recentCalls.count - Self.recentLimit) }
        }
    }

    private func refreshClients() {
        Task {
            let all = await sessions.all
            let list = all.map { MCPClientRecord(id: $0.id, name: $0.clientName, version: $0.clientVersion,
                                                 protocolVersion: $0.protocolVersion, since: $0.createdAt) }
            await MainActor.run { self.clients = list }
        }
    }
}
