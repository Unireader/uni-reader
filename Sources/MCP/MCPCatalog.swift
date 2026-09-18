import Foundation

/// 工具注册表（方案 §5.1 `MCPCatalog`）：名字 → 说明 / 入参 schema / 出参 schema / 分级 / 处理函数。
/// 只依赖 Foundation；具体工具在 `MCPTools+*.swift` 里注册。

/// 一次调用的上下文：谁在调（`initialize` 的 `clientInfo`，写入来源标记要用）+ 写入开关此刻的状态。
struct MCPCallContext {
    var clientName: String
    var clientVersion: String
    var writesEnabled: Bool
    /// 这次调用来自 App 内置的 Agent 面板（它启动的 Agent 在请求头里带 `AgentFollow.header`）。
    /// 只用来**收紧**（「跟随 Agent」关着时不动阅读区），不授予任何额外权限——所以谁伪造这个头都占不到便宜。
    var fromInAppAgent = false

    static let anonymous = MCPCallContext(clientName: "unknown", clientVersion: "", writesEnabled: false)
}

/// 「跟随 Agent」开关（`ACP-AGENT-PLAN.md`）：App 内置 Agent 调 `goto` / `open_document` 时，
/// 阅读区跟不跟着跳。默认开。放在这里（只依赖 Foundation）是因为网络队列上的工具要读它。
enum AgentFollow {
    static let key = "agentFollow"
    /// App 内置 Agent 连 MCP 时带的请求头（值无意义，有就算）。
    static let header = "x-unireader-agent"

    static var enabled: Bool { UserDefaults.standard.object(forKey: key) as? Bool ?? true }

    /// 开关关着时导航类工具给 Agent 的回话：说清楚没动、为什么，免得它以为跳过去了。
    static let declined = "Follow Agent is turned off in UniReader, so the user's view was not moved. Tell the user which page or document you mean instead of navigating."
}

/// 工具分级（方案 §1 / §6.5）：读取 / 导航（改界面不改数据）/ 写入（受设置里的开关管）。
enum MCPToolTier {
    case read, navigate, write

    /// 协议 `annotations`：客户端据此决定要不要向用户确认。批 3 不提供删除，`destructiveHint` 恒 false。
    var annotations: MCPObject {
        switch self {
        case .read:     return ["readOnlyHint": true, "openWorldHint": false]
        case .navigate: return ["readOnlyHint": false, "destructiveHint": false, "idempotentHint": true, "openWorldHint": false]
        case .write:    return ["readOnlyHint": false, "destructiveHint": false, "idempotentHint": false, "openWorldHint": false]
        }
    }
}

/// 工具返回：`text` 给模型读，`structured` 给程序用，两份并存（方案 §6.4）；`image` 是页图那类。
struct MCPToolResult {
    var text: String
    var structured: MCPObject? = nil
    var image: (data: Data, mime: String)? = nil
    var isError = false

    static func failure(_ message: String) -> MCPToolResult {
        MCPToolResult(text: message, isError: true)
    }

    /// `tools/call` 的 `result` 对象。
    func json() -> MCPObject {
        var content: [MCPObject] = []
        if let image {
            content.append(["type": "image", "data": image.data.base64EncodedString(), "mimeType": image.mime])
        }
        if !text.isEmpty || content.isEmpty {
            content.append(["type": "text", "text": text])
        }
        var out: MCPObject = ["content": content, "isError": isError]
        if let structured, !isError { out["structuredContent"] = structured }
        return out
    }
}

typealias MCPToolHandler = (MCPCallContext, MCPArgs) async throws -> MCPToolResult

struct MCPTool {
    var name: String
    var title: String
    var description: String
    var inputSchema: MCPObject
    var outputSchema: MCPObject? = nil
    var tier: MCPToolTier
    var handler: MCPToolHandler

    /// `tools/list` 里的一项。
    func listing() -> MCPObject {
        var o: MCPObject = ["name": name, "title": title, "description": description,
                            "inputSchema": inputSchema, "annotations": tier.annotations]
        if let outputSchema { o["outputSchema"] = outputSchema }
        return o
    }
}

/// `resources/read` 的一项内容：文本或二进制（base64 由这里编）。
struct MCPResourceContent {
    var uri: String
    var mimeType: String
    var text: String? = nil
    var blob: Data? = nil

    func json() -> MCPObject {
        var o: MCPObject = ["uri": uri, "mimeType": mimeType]
        if let text { o["text"] = text }
        if let blob { o["blob"] = blob.base64EncodedString() }
        return o
    }
}

/// 资源提供者（方案 §8，批 2）：列表 / 模板 / 按 URI 读。内容与同名工具完全一致，不另起一套读法。
struct MCPResourceProvider {
    /// `resources/list`：此刻能列出来的具体资源（开着的文档等）。
    var list: () async -> [MCPObject]
    /// `resources/templates/list`：URI 模板（静态）。
    var templates: [MCPObject]
    /// `resources/read`：认不出的 URI 抛 `MCPResourceNotFound`。
    var read: (String) async throws -> MCPResourceContent
}

/// `resources/read` 找不到 URI（协议错误码 -32002）。
struct MCPResourceNotFound: Error {
    let uri: String
}

final class MCPCatalog {
    private(set) var tools: [MCPTool] = []
    private var byName: [String: MCPTool] = [:]
    /// 批 2 装上；nil = `initialize` 不声明 resources 能力，`resources/*` 应答空列表。
    var resources: MCPResourceProvider?

    func register(_ tool: MCPTool) {
        precondition(byName[tool.name] == nil, "MCP 工具重名：\(tool.name)")
        tools.append(tool)
        byName[tool.name] = tool
    }

    func tool(named name: String) -> MCPTool? { byName[name] }

    func listing() -> [MCPObject] { tools.map { $0.listing() } }

    /// 执行一个工具。两层错误分开（方案 §4.4）：
    /// - 工具不存在 / 参数不合法 → 抛 `MCPInvalidParams`（调度器映射成 -32602）；
    /// - 执行失败（`MCPToolError` 或任何别的错误）→ `isError: true` 的正常应答，模型读了自己纠正。
    func call(name: String, arguments: MCPObject, context: MCPCallContext) async throws -> MCPObject {
        guard let tool = byName[name] else {
            throw MCPInvalidParams("unknown tool '\(name)'")
        }
        try Self.checkRequired(tool.inputSchema, arguments)
        if tool.tier == .write, !context.writesEnabled {
            return MCPToolResult.failure("writes are disabled in UniReader › Settings › Agent; ask the user to enable them").json()
        }
        do {
            return try await tool.handler(context, MCPArgs(arguments)).json()
        } catch let e as MCPInvalidParams {
            throw e
        } catch let e as MCPToolError {
            return MCPToolResult.failure(e.message).json()
        } catch {
            return MCPToolResult.failure("\(tool.name) failed: \(error.localizedDescription)").json()
        }
    }

    /// 只查 `required` 列表——类型由各工具的 `MCPArgs` 读取器逐个判（错了同样是 -32602）。
    private static func checkRequired(_ schema: MCPObject, _ args: MCPObject) throws {
        guard let required = schema["required"] as? [String] else { return }
        for key in required where args[key] == nil || args[key] is NSNull {
            throw MCPInvalidParams("argument '\(key)' is required")
        }
    }
}
