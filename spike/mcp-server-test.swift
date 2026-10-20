// MCP 监听/HTTP/口令链路（`MCPServer` 在进程内起真服务，URLSession 打回环）。运行：
//   cp spike/mcp-server-test.swift /tmp/main.swift && swiftc -parse-as-library Sources/MCP/MCPModels.swift Sources/MCP/MCPHTTP.swift Sources/MCP/MCPCatalog.swift Sources/MCP/MCPProtocol.swift Sources/MCP/MCPServer.swift Sources/Support/Keychain.swift Sources/Support/L.swift Sources/Server/NetInfo.swift /tmp/main.swift -o /tmp/mcpst && /tmp/mcpst -mcpPort 18773 -mcpBind loopback
// （端口/监听地址走 `-key value` 参数域，不写任何 plist；口令走 `tokenProvider` 注入，不碰 Keychain）
// 覆盖：/health、握手拿 Mcp-Session-Id、带会话调工具、不认识的会话照常服务（不回 404）、GET 405、DELETE 会话、
//       外站 Origin 403、不支持的协议版本头 400、口令 401/200、重启后旧会话照常可用且客户端名还在、
//       所有接口模式无口令回落回环、端口被占时监听失败后自己重开。
import Foundation

var pass = 0, fail = 0
func check(_ c: Bool, _ m: String) { if c { pass += 1; print("  ✅ \(m)") } else { fail += 1; print("  ❌ \(m)") } }

/// `MCPServer.instructions` 引用了这两段（真身在 `MCPTools+Markdown.swift`，连着整个 App 编不进 spike）。
enum MCPTools {
    static let mathWriting = ""
    static let graphWriting = ""
}

struct Reply { let status: Int; let headers: [String: String]; let body: MCPObject; let raw: String }

func post(_ url: String, _ obj: Any, headers: [String: String] = [:], method: String = "POST") async -> Reply {
    var req = URLRequest(url: URL(string: url)!)
    req.httpMethod = method
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
    if method == "POST" { req.httpBody = MCPJSON.data(obj) }
    do {
        let (data, resp) = try await URLSession.shared.data(for: req)
        let h = resp as! HTTPURLResponse
        var hs: [String: String] = [:]
        for (k, v) in h.allHeaderFields { hs[String(describing: k).lowercased()] = String(describing: v) }
        return Reply(status: h.statusCode, headers: hs, body: (MCPJSON.parse(data) as? MCPObject) ?? [:], raw: String(decoding: data, as: UTF8.self))
    } catch {
        return Reply(status: -1, headers: [:], body: [:], raw: "\(error)")
    }
}

func rpc(_ method: String, id: Any = 1, params: MCPObject = [:]) -> MCPObject {
    ["jsonrpc": "2.0", "id": id, "method": method, "params": params]
}

/// 改参数域（`-mcpPort/-mcpBind` 那一层）：易失，只在本进程，什么都不落盘。
func setArgs(port: UInt16, bind: String) {
    UserDefaults.standard.setVolatileDomain([MCPServer.portKey: Int(port), MCPServer.bindKey: bind],
                                            forName: UserDefaults.argumentDomain)
}

func waitReady(_ base: String) async -> Bool {
    for _ in 0..<50 {
        if await post(base + "/health", [:], method: "GET").status == 200 { return true }
        try? await Task.sleep(nanoseconds: 50_000_000)
    }
    return false
}

@main
struct Main {
    static func main() async {
        let port = MCPServer.port
        let base = "http://127.0.0.1:\(port)"
        let server = MCPServer(sessions: MCPSessionStore(defaultsKey: nil))   // 会话表不写 plist
        var token: String? = nil
        server.tokenProvider = { token }
        server.catalog.register(MCPTool(name: "echo", title: "Echo", description: "echo", inputSchema: MCPSchema.object(["msg": MCPSchema.string("m")], required: ["msg"]), tier: .read) { _, a in
            MCPToolResult(text: "echo: \(try a.requiredString("msg"))")
        })

        print("启动（回环，无口令）")
        await MainActor.run { server.start() }
        check(await waitReady(base), "/health 可达 @ \(base)")
        check(await MainActor.run { server.isRunning && server.effectiveBind == .loopback && server.lastError == nil }, "isRunning / effectiveBind=loopback / 无错误")

        print("握手与会话")
        let ini = await post(base + "/mcp", rpc("initialize", params: ["protocolVersion": "2025-11-25", "capabilities": [:], "clientInfo": ["name": "spike", "version": "1"]]))
        let sid = ini.headers["mcp-session-id"] ?? ""
        check(ini.status == 200 && sid.count == 64, "initialize → 200 + Mcp-Session-Id（\(sid.prefix(8))…）")
        check(((ini.body["result"] as? MCPObject)?["protocolVersion"] as? String) == "2025-11-25", "协议版本协商")
        check(ini.headers["content-type"]?.hasPrefix("application/json") == true && ini.headers["connection"] == "close", "Content-Type json + Connection: close")

        let noted = await post(base + "/mcp", ["jsonrpc": "2.0", "method": "notifications/initialized"], headers: ["Mcp-Session-Id": sid])
        check(noted.status == 202 && noted.raw.isEmpty, "通知 → 202 空体")

        let list = await post(base + "/mcp", rpc("tools/list"), headers: ["Mcp-Session-Id": sid, "MCP-Protocol-Version": "2025-11-25"])
        check(list.status == 200 && (((list.body["result"] as? MCPObject)?["tools"] as? [MCPObject])?.count ?? 0) == 1, "带会话 tools/list → 1 个工具")
        let call = await post(base + "/mcp", rpc("tools/call", params: ["name": "echo", "arguments": ["msg": "hi"]]), headers: ["Mcp-Session-Id": sid])
        check((((call.body["result"] as? MCPObject)?["content"] as? [MCPObject])?.first?["text"] as? String) == "echo: hi", "带会话 tools/call")
        let noSession = await post(base + "/mcp", rpc("tools/list"))
        check(noSession.status == 200 && ((noSession.body["error"] as? MCPObject)?["code"] as? Int) == JSONRPCCode.notInitialized, "无会话头 → JSON-RPC -32002")
        let badSession = await post(base + "/mcp", rpc("tools/list"), headers: ["Mcp-Session-Id": "deadbeef"])
        check(badSession.status == 200 && (((badSession.body["result"] as? MCPObject)?["tools"] as? [MCPObject])?.count ?? 0) == 1,
              "不认识的会话 id → 照常服务，不回 404（Claude Code 收到 404 不会重新握手）")
        let badVer = await post(base + "/mcp", rpc("tools/list"), headers: ["Mcp-Session-Id": sid, "MCP-Protocol-Version": "1999-01-01"])
        check(badVer.status == 400, "不支持的 MCP-Protocol-Version 头 → 400")
        let get = await post(base + "/mcp", [:], method: "GET")
        check(get.status == 405, "GET /mcp → 405")
        let evil = await post(base + "/mcp", rpc("ping"), headers: ["Origin": "http://evil.example"])
        check(evil.status == 403, "外站 Origin → 403")
        let localOrigin = await post(base + "/mcp", rpc("ping"), headers: ["Origin": "http://localhost:5173"])
        check(localOrigin.status == 200, "localhost Origin 放行")
        let notFound = await post(base + "/nope", rpc("ping"))
        check(notFound.status == 404, "未知路径 → 404")
        let bad = await post(base + "/mcp", ["x": 1])
        check(bad.status == 200 && ((bad.body["error"] as? MCPObject)?["code"] as? Int) == JSONRPCCode.invalidRequest, "坏 JSON-RPC 对象 → 200 + -32600")

        let del = await post(base + "/mcp", [:], headers: ["Mcp-Session-Id": sid], method: "DELETE")
        check(del.status == 200, "DELETE 会话 → 200")
        let afterDel = await post(base + "/mcp", rpc("tools/list"), headers: ["Mcp-Session-Id": sid])
        check(afterDel.status == 200, "删掉后再用 → 照常服务（按 unknown 接纳）")
        let keep = await post(base + "/mcp", rpc("initialize", params: ["protocolVersion": "2025-11-25", "clientInfo": ["name": "keeper", "version": "1"]]))
        let keepSid = keep.headers["mcp-session-id"] ?? ""

        // 面板账
        try? await Task.sleep(nanoseconds: 100_000_000)
        let calls = await MainActor.run { server.recentCalls }
        check(calls.contains { $0.what == "echo" && $0.ok } && calls.contains { $0.what == "initialize" }, "最近调用记了 initialize 与 echo（\(calls.count) 条）")

        print("口令")
        token = "secret-token"
        await MainActor.run { server.restart() }
        check(await waitReady(base), "重启后 /health 仍可达（不校验口令）")
        let unauth = await post(base + "/mcp", rpc("ping"))
        check(unauth.status == 401, "无口令头 → 401")
        let wrong = await post(base + "/mcp", rpc("ping"), headers: ["Authorization": "Bearer nope"])
        check(wrong.status == 401, "错口令 → 401")
        let auth = await post(base + "/mcp", rpc("ping"), headers: ["Authorization": "Bearer secret-token"])
        check(auth.status == 200 && (auth.body["result"] as? MCPObject) != nil, "对口令 → 200")
        let ini2 = await post(base + "/mcp", rpc("initialize", params: ["protocolVersion": "2025-06-18"]), headers: ["Authorization": "Bearer secret-token"])
        check(ini2.status == 200 && (ini2.headers["mcp-session-id"] ?? "").count == 64, "带口令握手成功")
        let kept = await post(base + "/mcp", rpc("tools/call", params: ["name": "echo", "arguments": ["msg": "back"]]),
                              headers: ["Authorization": "Bearer secret-token", "Mcp-Session-Id": keepSid])
        check(kept.status == 200 && (((kept.body["result"] as? MCPObject)?["content"] as? [MCPObject])?.first?["text"] as? String) == "echo: back",
              "重启前拿的会话 id，重启后照常可用")
        try? await Task.sleep(nanoseconds: 200_000_000)
        let keptName = await MainActor.run { server.clients.contains { $0.name == "keeper" } }
        check(keptName, "重启后面板上客户端名还是 keeper，不是 unknown")

        print("所有接口模式无口令 → 回落回环")
        token = nil
        // 监听地址改在**参数域**里（命令行 -key value 那一层，易失、不落 plist）；`set(_:forKey:)` 写的是应用域，会被参数域盖住
        setArgs(port: port, bind: "all")
        await MainActor.run { server.restart() }
        check(await waitReady(base), "重启后可达")
        let fell = await MainActor.run { server.effectiveBind == .loopback && server.lastError != nil }
        check(fell, "effectiveBind=loopback，lastError 有说明")

        print("所有接口模式有口令 → 真的绑 0.0.0.0")
        token = "lan-token"
        setArgs(port: port, bind: "all")
        await MainActor.run { server.restart() }
        check(await waitReady(base), "重启后回环仍可达")
        let lanOK = await MainActor.run { server.effectiveBind == .all && server.lastError == nil }
        check(lanOK, "effectiveBind=all，无错误")
        // 本机每个 IP（Wi-Fi / 有线 / VPN …）都要能连、都要被 Origin 检查放行，不只是 en0 那一个
        let ips = await MainActor.run { NetWatch.shared.addresses.map(\.ip) }
        if ips.isEmpty { print("  （没有局域网地址，跳过经局域网地址访问的各项）") }
        for ip in ips {
            let viaLAN = await post("http://\(ip):\(port)/mcp", rpc("ping"), headers: ["Authorization": "Bearer lan-token"])
            check(viaLAN.status == 200, "经本机地址 \(ip) 可达")
            let lanOrigin = await post("http://\(ip):\(port)/mcp", rpc("ping"), headers: ["Authorization": "Bearer lan-token", "Origin": "http://\(ip):8080"])
            check(lanOrigin.status == 200, "Origin 为本机地址 \(ip) 放行")
        }
        let urls = await MainActor.run { server.endpointURLs }
        check(urls.count == max(1, ips.count), "面板地址列表每个本机地址一条（\(urls.count)）")
        setArgs(port: port, bind: "loopback")

        await MainActor.run { server.stop() }
        try? await Task.sleep(nanoseconds: 100_000_000)
        let downStatus = await post(base + "/health", [:], method: "GET").status
        check(downStatus == -1, "stop 后连接被拒")

        print("端口被占 → 监听失败后自己重开")
        // 另一个程序占住同一个回环端口。SO_REUSEADDR 只是为了越过刚停的服务留下的 TIME_WAIT，
        // 两个 socket 仍不能同时 listen 同一地址
        let blocker = socket(AF_INET, SOCK_STREAM, 0)
        var one: Int32 = 1
        setsockopt(blocker, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(blocker, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        } == 0 && listen(blocker, 1) == 0
        check(bound, "占住 127.0.0.1:\(port)")
        await MainActor.run { server.start() }
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        let failedNow = await MainActor.run { !server.isRunning && server.lastError != nil }
        check(failedNow, "端口被占：监听失败，lastError 有说明")
        close(blocker)
        var back = false
        for _ in 0..<100 where !back {   // 退避 1、2、4… 秒，最多等 10 秒
            back = await post(base + "/health", [:], method: "GET").status == 200
            if !back { try? await Task.sleep(nanoseconds: 100_000_000) }
        }
        check(back, "端口空出来后自己重开监听（没人点「启动」）")
        await MainActor.run { server.stop() }

        print("\n\(pass) 通过, \(fail) 失败")
        exit(fail == 0 ? 0 : 1)
    }
}
