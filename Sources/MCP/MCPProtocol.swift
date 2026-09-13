import Foundation

/// MCP 协议层（方案 §4）：JSON-RPC 2.0 编解码、旧版（2025-03-26 ~ 2025-11-25）握手与会话、方法调度。
/// 只依赖 Foundation；**不碰网络**——`dispatch(...)` 是「(会话, 请求字节) → 应答」的纯逻辑，spike 直接喂 JSON 测。
///
/// 会话参数**可空**：新版协议（2026-07-28，`server/discover`，批 1c）没有会话，接上时只加方法、不改调度结构。
enum MCPVersions {
    /// 能应答的旧版版本号（差异对我们用到的方法没有影响，见方案 §4.1）。
    static let supported = ["2025-11-25", "2025-06-18", "2025-03-26"]
    static let latest = "2025-11-25"

    /// 协商：客户端要的我们有就用它的，否则给我们最新的（协议规定，客户端不接受就自己断开）。
    static func negotiate(_ requested: String?) -> String {
        if let requested, supported.contains(requested) { return requested }
        return latest
    }
}

/// JSON-RPC 错误码。
enum JSONRPCCode {
    static let parseError = -32700
    static let invalidRequest = -32600
    static let methodNotFound = -32601
    static let invalidParams = -32602
    static let internalError = -32603
    /// 旧版握手前就来别的请求（协议没给固定码，用服务端保留区）。
    static let notInitialized = -32002
}

/// 一个旧版会话（`Mcp-Session-Id`）。只在 `MCPSessionStore` 的 actor 里改。
struct MCPSession {
    let id: String
    var protocolVersion: String
    var clientName: String
    var clientVersion: String
    let createdAt: Date
    var lastSeen: Date

    /// 随机 32 字节十六进制；协议只要求可见 ASCII，十六进制最省事。
    static func makeID() -> String {
        (0..<32).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
    }
}

/// 会话表。`actor`：请求从网络队列来、面板从主线程读，两边都要碰它。
actor MCPSessionStore {
    private var sessions: [String: MCPSession] = [:]
    /// 多久没动静就清（方案 §4.2：30 分钟）。
    let maxIdle: TimeInterval

    init(maxIdle: TimeInterval = 30 * 60) { self.maxIdle = maxIdle }

    func create(protocolVersion: String, clientName: String, clientVersion: String) -> MCPSession {
        let s = MCPSession(id: MCPSession.makeID(), protocolVersion: protocolVersion,
                           clientName: clientName, clientVersion: clientVersion, createdAt: .now, lastSeen: .now)
        sessions[s.id] = s
        return s
    }

    /// 取会话并刷新「最近见到」。
    func touch(_ id: String) -> MCPSession? {
        guard var s = sessions[id] else { return nil }
        s.lastSeen = .now
        sessions[id] = s
        return s
    }

    func remove(_ id: String) { sessions.removeValue(forKey: id) }
    func removeAll() { sessions.removeAll() }

    func sweep(now: Date = .now) {
        sessions = sessions.filter { now.timeIntervalSince($0.value.lastSeen) < maxIdle }
    }

    var all: [MCPSession] { sessions.values.sorted { $0.createdAt < $1.createdAt } }
    var count: Int { sessions.count }
}

/// 服务器自述（`initialize` 应答里的 `serverInfo` + `instructions`）。
struct MCPServerInfo {
    var name: String
    var version: String
    /// 给模型看的使用说明（英文）。
    var instructions: String
}

/// 调度结果；HTTP 层据此定状态码与头。
enum MCPDispatchOutcome {
    /// 一个 JSON-RPC 应答对象（HTTP 200）。
    case response(MCPObject)
    /// 通知：没有 `id`，不应答（HTTP 202 空体）。
    case accepted
    /// `initialize` 成功：新会话 + 应答（HTTP 200 + `Mcp-Session-Id`）。
    case initialized(MCPSession, response: MCPObject)
}

struct MCPDispatcher {
    let catalog: MCPCatalog
    let info: MCPServerInfo
    let sessions: MCPSessionStore
    /// 每次调用时问一下写入开关（设置可能随时改）。
    let writesEnabled: () -> Bool

    /// 处理一条 HTTP 请求体。`session` = HTTP 层按 `Mcp-Session-Id` 查到的会话（没带/查不到 = nil）。
    func dispatch(body: Data, session: MCPSession?) async -> MCPDispatchOutcome {
        guard let parsed = MCPJSON.parse(body) else {
            return .response(Self.error(id: nil, code: JSONRPCCode.parseError, message: "parse error: body is not valid JSON"))
        }
        if parsed is [Any] {
            // 2025-06-18 起协议已去掉批量（方案 §4.2）
            return .response(Self.error(id: nil, code: JSONRPCCode.invalidRequest, message: "JSON-RPC batches are not supported"))
        }
        guard let obj = parsed as? MCPObject, obj["jsonrpc"] as? String == "2.0",
              let method = obj["method"] as? String else {
            return .response(Self.error(id: (parsed as? MCPObject)?["id"], code: JSONRPCCode.invalidRequest,
                                        message: "invalid request: need jsonrpc \"2.0\" and a method"))
        }
        let params = (obj["params"] as? MCPObject) ?? [:]
        let id = obj["id"]
        let isNotification = id == nil || id is NSNull

        if isNotification {
            // notifications/initialized、notifications/cancelled 等：收下、不处理（所有操作都有上限，见方案 §4.2）
            return .accepted
        }

        switch method {
        case "initialize":
            return await initialize(id: id!, params: params)
        case "ping":
            return .response(Self.result(id: id!, [:]))
        default:
            break
        }

        guard let session else {
            return .response(Self.error(id: id!, code: JSONRPCCode.notInitialized,
                                        message: "session not initialized; send initialize first"))
        }
        let ctx = MCPCallContext(clientName: session.clientName, clientVersion: session.clientVersion,
                                 writesEnabled: writesEnabled())

        switch method {
        case "tools/list":
            return .response(Self.result(id: id!, ["tools": catalog.listing()]))
        case "tools/call":
            guard let name = params["name"] as? String else {
                return .response(Self.error(id: id!, code: JSONRPCCode.invalidParams, message: "tools/call needs params.name"))
            }
            let args = (params["arguments"] as? MCPObject) ?? [:]
            do {
                let r = try await catalog.call(name: name, arguments: args, context: ctx)
                return .response(Self.result(id: id!, r))
            } catch let e as MCPInvalidParams {
                return .response(Self.error(id: id!, code: JSONRPCCode.invalidParams, message: e.message))
            } catch {
                return .response(Self.error(id: id!, code: JSONRPCCode.internalError, message: "\(error)"))
            }
        case "resources/list":
            return .response(Self.result(id: id!, ["resources": [MCPObject]()]))          // 批 2 再填
        case "resources/templates/list":
            return .response(Self.result(id: id!, ["resourceTemplates": [MCPObject]()]))
        case "prompts/list":
            return .response(Self.result(id: id!, ["prompts": [MCPObject]()]))
        default:
            return .response(Self.error(id: id!, code: JSONRPCCode.methodNotFound, message: "method not found: \(method)"))
        }
    }

    private func initialize(id: Any, params: MCPObject) async -> MCPDispatchOutcome {
        let requested = params["protocolVersion"] as? String
        let version = MCPVersions.negotiate(requested)
        let client = (params["clientInfo"] as? MCPObject) ?? [:]
        let session = await sessions.create(protocolVersion: version,
                                            clientName: (client["name"] as? String) ?? "unknown",
                                            clientVersion: (client["version"] as? String) ?? "")
        let result: MCPObject = [
            "protocolVersion": version,
            "capabilities": [
                "tools": ["listChanged": false],
                // 批 1 只声明 tools（方案 §4.2）；resources 到批 2 再打开
            ],
            "serverInfo": ["name": info.name, "version": info.version],
            "instructions": info.instructions,
        ]
        return .initialized(session, response: Self.result(id: id, result))
    }

    // MARK: - 应答拼装

    static func result(id: Any, _ result: MCPObject) -> MCPObject {
        ["jsonrpc": "2.0", "id": id, "result": result]
    }

    static func error(id: Any?, code: Int, message: String) -> MCPObject {
        ["jsonrpc": "2.0", "id": id ?? NSNull(), "error": ["code": code, "message": message]]
    }
}
