// MCP 协议层（`Sources/MCP/` 里不依赖 App 的四个文件）。运行：
//   cp spike/mcp-protocol-test.swift /tmp/main.swift && swiftc -parse-as-library -DSPIKE Sources/MCP/MCPModels.swift Sources/MCP/MCPHTTP.swift Sources/MCP/MCPCatalog.swift Sources/MCP/MCPProtocol.swift /tmp/main.swift -o /tmp/mcpt && /tmp/mcpt
// （main.swift 里用 @main 入口跑 async，所以要 -parse-as-library）
// 覆盖：HTTP 解析（头体分次到达 / Content-Length 不足 / 超限 / chunked / Origin / Bearer）、
//       页码换算（1 起 ↔ 0 起、范围写法、越界文案、上限）、入参读取器的类型判定、
//       JSON-RPC 调度（握手版本协商 / 通知 202 / 未握手拒绝 / tools/list schema / tools/call 两层错误 / 写入开关拦截 / 未知方法）。
import Foundation

var pass = 0, fail = 0
func check(_ c: Bool, _ m: String) { if c { pass += 1; print("  ✅ \(m)") } else { fail += 1; print("  ❌ \(m)") } }

func obj(_ data: Data) -> MCPObject { (MCPJSON.parse(data) as? MCPObject) ?? [:] }

@main
struct Main {
    static func main() async {
        print("HTTP 解析")
        let head = "POST /mcp?x=1 HTTP/1.1\r\nHost: 127.0.0.1:8773\r\nContent-Type: application/json\r\nContent-Length: 13\r\n\r\n"
        let body = "{\"jsonrpc\":1}"
        let full = Data((head + body).utf8)
        if case let .complete(req, consumed) = MCPHTTP.parse(full) {
            check(req.method == "POST" && req.path == "/mcp" && req.query["x"] == "1", "请求行：方法/路径/query")
            check(req.header("Content-Type") == "application/json" && req.headers["host"] == "127.0.0.1:8773", "头名小写化、大小写无关取值")
            check(String(decoding: req.body, as: UTF8.self) == body && consumed == full.count, "体按 Content-Length 取，consumed = 全长")
        } else { check(false, "完整请求应解出 .complete") }
        check(MCPHTTP.parse(Data(head.utf8)) == .incomplete, "头到了、体没到 → incomplete")
        check(MCPHTTP.parse(Data((head + "{\"jsonrpc\"").utf8)) == .incomplete, "体只到一半 → incomplete")
        check(MCPHTTP.parse(Data("POST /mcp HTTP/1.1\r\nContent-Len".utf8)) == .incomplete, "头没收齐 → incomplete")
        let extra = Data((head + body + "GET /health HTTP/1.1\r\n\r\n").utf8)
        if case let .complete(_, consumed) = MCPHTTP.parse(extra) { check(consumed == full.count, "后面粘了下一个请求：consumed 只算第一个") }
        else { check(false, "粘包也应解出第一个") }
        if case let .invalid(status, _) = MCPHTTP.parse(Data("POST /mcp HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n".utf8)) {
            check(status == 411, "chunked → 411")
        } else { check(false, "chunked 应判 invalid") }
        if case let .invalid(status, _) = MCPHTTP.parse(Data("POST /mcp HTTP/1.1\r\nContent-Length: 99999999\r\n\r\n".utf8)) {
            check(status == 413, "Content-Length 超 4MB → 413")
        } else { check(false, "超限应判 invalid") }
        if case let .invalid(status, _) = MCPHTTP.parse(Data("junk\r\n\r\n".utf8)) { check(status == 400, "坏请求行 → 400") }
        else { check(false, "坏请求行应判 invalid") }
        let resp = MCPHTTP.serialize(.json(200, ["a": 1], extra: [("Mcp-Session-Id", "abc")]))
        let s = String(decoding: resp, as: UTF8.self)
        check(s.hasPrefix("HTTP/1.1 200 OK\r\n") && s.contains("Mcp-Session-Id: abc\r\n") && s.contains("Content-Length: 7\r\n") && s.hasSuffix("{\"a\":1}"), "应答序列化：状态行/自定义头/长度/体")

        print("Origin / Bearer")
        check(MCPHTTP.originAllowed(nil, localHosts: []), "无 Origin（命令行客户端）放行")
        check(MCPHTTP.originAllowed("http://localhost:3000", localHosts: []), "localhost 任意端口放行")
        check(MCPHTTP.originAllowed("http://127.0.0.1:8773", localHosts: []), "127.0.0.1 放行")
        check(!MCPHTTP.originAllowed("http://evil.example", localHosts: []), "外站拒绝")
        check(!MCPHTTP.originAllowed("null", localHosts: []), "Origin: null 拒绝")
        check(MCPHTTP.originAllowed("http://192.168.1.20:8773", localHosts: ["192.168.1.20"]), "所有接口模式：本机局域网地址放行")
        check(!MCPHTTP.originAllowed("http://192.168.1.21", localHosts: ["192.168.1.20"]), "所有接口模式：别的地址仍拒绝")
        check(MCPHTTP.bearer(["authorization": "Bearer  tok-1 "]) == "tok-1", "Bearer 取值去空白")
        check(MCPHTTP.bearer(["authorization": "Basic xyz"]) == nil, "非 Bearer → nil")
        check(MCPHTTP.tokenMatches(nil, expected: nil) && MCPHTTP.tokenMatches("x", expected: ""), "没设口令 = 不校验")
        check(MCPHTTP.tokenMatches("secret", expected: "secret") && !MCPHTTP.tokenMatches("secre", expected: "secret") && !MCPHTTP.tokenMatches(nil, expected: "secret"), "设了口令：相等才过，缺头不过")

        print("页码换算")
        check(PageNo.external(0) == 1, "0 → 1")
        check((try? PageNo.index(1, pageCount: 10)) == 0 && (try? PageNo.index(10, pageCount: 10)) == 9, "1 起 → 0 起，含末页")
        do { _ = try PageNo.index(11, pageCount: 10); check(false, "越界应抛") }
        catch let e as MCPToolError { check(e.message.contains("11") && e.message.contains("10 pages"), "越界文案带页数：\(e.message)") }
        catch { check(false, "越界应是 MCPToolError") }
        do { _ = try PageNo.index(0, pageCount: 10); check(false, "第 0 页应抛") } catch { check(true, "第 0 页拒绝") }
        check((try? PageNo.parse("1-3,9", pageCount: 20)) == [0, 1, 2, 8], "\"1-3,9\" → [0,1,2,8]")
        check((try? PageNo.parse(" 7 - 3 ", pageCount: 20)) == [2, 3, 4, 5, 6], "倒着写按升序、容忍空白")
        check((try? PageNo.parse("5,5,5", pageCount: 20)) == [4], "重复去重")
        do { _ = try PageNo.parse("1-41", pageCount: 100); check(false, "41 页应抛") }
        catch let e as MCPToolError { check(e.message.contains("40"), "超 40 页拒绝：\(e.message)") }
        catch { check(false, "超页数应是 MCPToolError") }
        do { _ = try PageNo.parse("a-b", pageCount: 20); check(false, "非数字应抛") }
        catch is MCPInvalidParams { check(true, "非数字 → MCPInvalidParams") }
        catch { check(false, "非数字应是 MCPInvalidParams") }
        do { _ = try PageNo.parse("", pageCount: 20); check(false, "空串应抛") } catch { check(true, "空串拒绝") }

        print("入参读取器")
        let a = MCPArgs(["s": "x", "n": 3, "b": true, "f": 2.5, "sn": "12", "pages": 7])
        check((try? a.string("s")) == "x" && (try? a.int("n")) == 3 && (try? a.bool("b", default: false)) == true, "基本类型")
        check((try? a.int("sn")) == 12, "字符串数字也当整数收")
        check((try? a.pages("pages")) == "7", "pages 给整数 → \"7\"")
        check((try? a.string("missing")) == nil && (try? a.bool("missing", default: true)) == true, "缺省")
        do { _ = try a.int("b"); check(false, "bool 当 int 应拒") } catch is MCPInvalidParams { check(true, "true 不当作整数") } catch { check(false, "类型错应是 MCPInvalidParams") }
        do { _ = try a.int("f"); check(false, "2.5 当 int 应拒") } catch is MCPInvalidParams { check(true, "2.5 不当作整数") } catch { check(false, "类型错应是 MCPInvalidParams") }
        do { _ = try a.requiredString("missing"); check(false, "必填缺失应拒") } catch is MCPInvalidParams { check(true, "必填缺失 → MCPInvalidParams") } catch { check(false, "应是 MCPInvalidParams") }

        print("JSON-RPC 调度")
        let catalog = MCPCatalog()
        catalog.register(MCPTool(name: "echo", title: "Echo", description: "echo back",
                                 inputSchema: MCPSchema.object(["msg": MCPSchema.string("text")], required: ["msg"]),
                                 tier: .read) { _, args in
            MCPToolResult(text: "echo: \(try args.requiredString("msg"))", structured: ["msg": try args.requiredString("msg")])
        })
        catalog.register(MCPTool(name: "boom", title: "Boom", description: "fails", inputSchema: MCPSchema.object([:]), tier: .read) { _, _ in
            throw MCPToolError("document not found")
        })
        catalog.register(MCPTool(name: "write_thing", title: "Write", description: "writes", inputSchema: MCPSchema.object([:]), tier: .write) { _, _ in
            MCPToolResult(text: "written")
        })
        var writes = false
        let store = MCPSessionStore(maxIdle: 60)
        let d = MCPDispatcher(catalog: catalog, info: MCPServerInfo(name: "UniReader", version: "0.0", instructions: "hi"),
                              sessions: store, writesEnabled: { writes })

        func rpc(_ method: String, id: Any? = 1, params: MCPObject = [:]) -> Data {
            var o: MCPObject = ["jsonrpc": "2.0", "method": method, "params": params]
            if let id { o["id"] = id }
            return MCPJSON.data(o)
        }

        // 握手
        var session: MCPSession?
        switch await d.dispatch(body: rpc("initialize", params: ["protocolVersion": "2025-06-18", "capabilities": [:],
                                                                    "clientInfo": ["name": "spike", "version": "1"]]), session: nil) {
        case let .initialized(s, response):
            session = s
            let r = response["result"] as? MCPObject
            check(r?["protocolVersion"] as? String == "2025-06-18", "客户端要的版本我们有 → 原样返回")
            check((r?["serverInfo"] as? MCPObject)?["name"] as? String == "UniReader" && r?["instructions"] as? String == "hi", "serverInfo / instructions")
            check(((r?["capabilities"] as? MCPObject)?["tools"] as? MCPObject) != nil, "声明 tools 能力")
            check(s.clientName == "spike" && s.id.count == 64, "会话记下 clientInfo，id 为 64 位十六进制")
        default: check(false, "initialize 应返回 .initialized")
        }
        if case let .initialized(_, response) = await d.dispatch(body: rpc("initialize", params: ["protocolVersion": "1999-01-01"]), session: nil) {
            check(((response["result"] as? MCPObject)?["protocolVersion"] as? String) == MCPVersions.latest, "不支持的版本 → 给我们最新的")
        } else { check(false, "第二次 initialize 也应成功") }
        check(await store.count == 2, "会话表两条")

        if case .accepted = await d.dispatch(body: rpc("notifications/initialized", id: nil), session: session) { check(true, "通知 → accepted") }
        else { check(false, "通知应 accepted") }
        if case .accepted = await d.dispatch(body: rpc("tools/call", id: nil, params: ["name": "echo"]), session: nil) { check(true, "无 id 的任何方法都按通知处理") }
        else { check(false, "无 id 应 accepted") }

        // 未握手
        if case let .response(r) = await d.dispatch(body: rpc("tools/list"), session: nil) {
            check((r["error"] as? MCPObject)?["code"] as? Int == JSONRPCCode.notInitialized, "无会话调 tools/list → -32002")
        } else { check(false, "应是 response") }
        if case let .response(r) = await d.dispatch(body: rpc("ping"), session: nil) {
            check((r["result"] as? MCPObject) != nil, "ping 不需要会话")
        } else { check(false, "ping 应有应答") }

        // 坏请求
        if case let .response(r) = await d.dispatch(body: Data("{not json".utf8), session: session) {
            check((r["error"] as? MCPObject)?["code"] as? Int == JSONRPCCode.parseError && r["id"] is NSNull, "非法 JSON → -32700，id null")
        } else { check(false, "坏 JSON 应有应答") }
        if case let .response(r) = await d.dispatch(body: Data("[{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"ping\"}]".utf8), session: session) {
            check((r["error"] as? MCPObject)?["code"] as? Int == JSONRPCCode.invalidRequest, "批量数组 → -32600")
        } else { check(false, "批量应有应答") }
        if case let .response(r) = await d.dispatch(body: Data("{\"id\":1,\"method\":\"ping\"}".utf8), session: session) {
            check((r["error"] as? MCPObject)?["code"] as? Int == JSONRPCCode.invalidRequest && r["id"] as? Int == 1, "缺 jsonrpc 字段 → -32600，回显 id")
        } else { check(false, "缺字段应有应答") }

        // tools/list
        if case let .response(r) = await d.dispatch(body: rpc("tools/list", id: "s-1"), session: session) {
            let tools = ((r["result"] as? MCPObject)?["tools"] as? [MCPObject]) ?? []
            check(tools.count == 3 && r["id"] as? String == "s-1", "列出 3 个工具，字符串 id 原样回")
            check(tools.allSatisfy { ($0["inputSchema"] as? MCPObject)?["type"] as? String == "object" }, "每个工具 inputSchema.type == object")
            let w = tools.first { $0["name"] as? String == "write_thing" }
            check((w?["annotations"] as? MCPObject)?["readOnlyHint"] as? Bool == false, "写入工具照常列出（D6），readOnlyHint=false")
            let e = tools.first { $0["name"] as? String == "echo" }
            check((e?["annotations"] as? MCPObject)?["readOnlyHint"] as? Bool == true, "读取工具 readOnlyHint=true")
        } else { check(false, "tools/list 应有应答") }

        // tools/call
        if case let .response(r) = await d.dispatch(body: rpc("tools/call", params: ["name": "echo", "arguments": ["msg": "hi"]]), session: session) {
            let res = r["result"] as? MCPObject
            let content = (res?["content"] as? [MCPObject])?.first
            check(content?["type"] as? String == "text" && content?["text"] as? String == "echo: hi", "content 文本")
            check((res?["structuredContent"] as? MCPObject)?["msg"] as? String == "hi" && res?["isError"] as? Bool == false, "structuredContent + isError=false")
        } else { check(false, "echo 应有应答") }
        if case let .response(r) = await d.dispatch(body: rpc("tools/call", params: ["name": "echo", "arguments": [:]]), session: session) {
            check((r["error"] as? MCPObject)?["code"] as? Int == JSONRPCCode.invalidParams, "缺必填参数 → -32602")
        } else { check(false, "缺参应有应答") }
        if case let .response(r) = await d.dispatch(body: rpc("tools/call", params: ["name": "echo", "arguments": ["msg": 5]]), session: session) {
            check((r["error"] as? MCPObject)?["code"] as? Int == JSONRPCCode.invalidParams, "参数类型错 → -32602")
        } else { check(false, "类型错应有应答") }
        if case let .response(r) = await d.dispatch(body: rpc("tools/call", params: ["name": "nope"]), session: session) {
            check((r["error"] as? MCPObject)?["code"] as? Int == JSONRPCCode.invalidParams, "未知工具 → -32602")
        } else { check(false, "未知工具应有应答") }
        if case let .response(r) = await d.dispatch(body: rpc("tools/call", params: ["name": "boom"]), session: session) {
            let res = r["result"] as? MCPObject
            check(res?["isError"] as? Bool == true && ((res?["content"] as? [MCPObject])?.first?["text"] as? String) == "document not found", "执行失败 → isError:true + 文案，不是 JSON-RPC error")
            check(res?["structuredContent"] == nil, "失败时不给 structuredContent")
        } else { check(false, "boom 应有应答") }
        if case let .response(r) = await d.dispatch(body: rpc("tools/call", params: ["name": "write_thing"]), session: session) {
            let res = r["result"] as? MCPObject
            check(res?["isError"] as? Bool == true && (((res?["content"] as? [MCPObject])?.first?["text"] as? String) ?? "").contains("Settings"), "写入开关关着：拦下并指路设置")
        } else { check(false, "写入应有应答") }
        writes = true
        if case let .response(r) = await d.dispatch(body: rpc("tools/call", params: ["name": "write_thing"]), session: session) {
            check(((r["result"] as? MCPObject)?["isError"] as? Bool) == false, "写入开关打开后放行")
        } else { check(false, "写入应有应答") }

        // 其它方法
        if case let .response(r) = await d.dispatch(body: rpc("resources/list"), session: session) {
            check((((r["result"] as? MCPObject)?["resources"]) as? [Any])?.isEmpty == true, "没装资源提供者：resources/list 给空列表")
        } else { check(false, "resources/list 应有应答") }
        if case let .response(r) = await d.dispatch(body: rpc("resources/read", params: ["uri": "x://y"]), session: session) {
            check((r["error"] as? MCPObject)?["code"] as? Int == JSONRPCCode.resourceNotFound, "没装资源提供者：resources/read → -32002")
        } else { check(false, "resources/read 应有应答") }

        print("资源（批 2）")
        catalog.resources = MCPResourceProvider(
            list: { [["uri": "test://a", "name": "A", "mimeType": "text/plain"]] },
            templates: [["uriTemplate": "test://{id}", "name": "T"]],
            read: { uri in
                if uri == "test://a" { return MCPResourceContent(uri: uri, mimeType: "text/plain", text: "hello") }
                if uri == "test://img" { return MCPResourceContent(uri: uri, mimeType: "image/png", blob: Data([1, 2, 3])) }
                throw MCPResourceNotFound(uri: uri)
            })
        if case let .initialized(_, response) = await d.dispatch(body: rpc("initialize", params: ["protocolVersion": "2025-11-25"]), session: nil) {
            let caps = (response["result"] as? MCPObject)?["capabilities"] as? MCPObject
            check((caps?["resources"] as? MCPObject) != nil, "装了资源提供者：initialize 声明 resources 能力")
        } else { check(false, "initialize 应成功") }
        if case let .response(r) = await d.dispatch(body: rpc("resources/list"), session: session) {
            let list = ((r["result"] as? MCPObject)?["resources"] as? [MCPObject]) ?? []
            check(list.count == 1 && list.first?["uri"] as? String == "test://a", "resources/list 列出提供者给的资源")
        } else { check(false, "resources/list 应有应答") }
        if case let .response(r) = await d.dispatch(body: rpc("resources/templates/list"), session: session) {
            let list = ((r["result"] as? MCPObject)?["resourceTemplates"] as? [MCPObject]) ?? []
            check(list.first?["uriTemplate"] as? String == "test://{id}", "resources/templates/list")
        } else { check(false, "templates 应有应答") }
        if case let .response(r) = await d.dispatch(body: rpc("resources/read", params: ["uri": "test://a"]), session: session) {
            let c = ((r["result"] as? MCPObject)?["contents"] as? [MCPObject])?.first
            check(c?["text"] as? String == "hello" && c?["mimeType"] as? String == "text/plain" && c?["uri"] as? String == "test://a", "resources/read 文本资源")
        } else { check(false, "read 应有应答") }
        if case let .response(r) = await d.dispatch(body: rpc("resources/read", params: ["uri": "test://img"]), session: session) {
            let c = ((r["result"] as? MCPObject)?["contents"] as? [MCPObject])?.first
            check(c?["blob"] as? String == Data([1, 2, 3]).base64EncodedString() && c?["text"] == nil, "resources/read 二进制资源走 blob(base64)")
        } else { check(false, "read 应有应答") }
        if case let .response(r) = await d.dispatch(body: rpc("resources/read", params: ["uri": "test://nope"]), session: session) {
            check((r["error"] as? MCPObject)?["code"] as? Int == JSONRPCCode.resourceNotFound, "未知 URI → -32002")
        } else { check(false, "read 应有应答") }
        if case let .response(r) = await d.dispatch(body: rpc("resources/read"), session: session) {
            check((r["error"] as? MCPObject)?["code"] as? Int == JSONRPCCode.invalidParams, "缺 uri → -32602")
        } else { check(false, "read 应有应答") }

        print("页码筛选（limit）")
        check((try? PageNo.parse("1-500", pageCount: 1000, limit: Int.max))?.count == 500, "limit=Int.max 时不受 40 页上限")
        if case let .response(r) = await d.dispatch(body: rpc("nope/method"), session: session) {
            check((r["error"] as? MCPObject)?["code"] as? Int == JSONRPCCode.methodNotFound, "未知方法 → -32601")
        } else { check(false, "未知方法应有应答") }

        // 会话过期
        await store.sweep(now: Date.now.addingTimeInterval(120))
        check(await store.count == 0, "超过 maxIdle 的会话被清")

        print("\n\(pass) 通过, \(fail) 失败")
        exit(fail == 0 ? 0 : 1)
    }
}
