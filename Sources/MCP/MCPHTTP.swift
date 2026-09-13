import Foundation

/// MCP 端点用的最小 HTTP/1.1：**字节 → 请求** 与 **应答 → 字节** 两个纯函数（方案 §4.2 / §11.2）。
/// 只依赖 Foundation，spike 直接喂字节测；监听/收发在 `MCPServer`。
///
/// 与 `LANServer` 那份「一次 receive 解一行」的差别：MCP 是 POST 带 JSON 体，头和体可能分几次到，
/// 必须按 `Content-Length` 读满再解。
enum MCPHTTP {
    /// 请求体上限（方案 §4.2）：一次 tools/call 的参数不可能到这个量级，超了就是有人乱发。
    static let maxBodyBytes = 4 * 1024 * 1024

    struct Request {
        var method: String
        var path: String
        var query: [String: String]
        /// 头名**已小写**。
        var headers: [String: String]
        var body: Data

        func header(_ name: String) -> String? { headers[name.lowercased()] }
    }

    enum ParseResult: Equatable {
        /// 还没收齐（头没到 `\r\n\r\n`，或体不够 Content-Length），继续收。
        case incomplete
        /// 收齐了一个完整请求；`consumed` = 它占了缓冲区前多少字节。
        case complete(Request, consumed: Int)
        /// 坏请求：给状态码与一句话，应答后关连接。
        case invalid(status: Int, message: String)

        static func == (a: ParseResult, b: ParseResult) -> Bool {
            switch (a, b) {
            case (.incomplete, .incomplete): return true
            case let (.complete(x, cx), .complete(y, cy)):
                return cx == cy && x.method == y.method && x.path == y.path && x.body == y.body && x.headers == y.headers
            case let (.invalid(s1, m1), .invalid(s2, m2)): return s1 == s2 && m1 == m2
            default: return false
            }
        }
    }

    private static let headerEnd = Data("\r\n\r\n".utf8)

    static func parse(_ buffer: Data) -> ParseResult {
        guard let r = buffer.range(of: headerEnd) else {
            // 头都还没齐；头部本身也不许无限长（64KB 足够）
            return buffer.count > 65_536 ? .invalid(status: 431, message: "request header too large") : .incomplete
        }
        let headEnd = r.upperBound
        guard let head = String(data: buffer[buffer.startIndex..<r.lowerBound], encoding: .utf8) else {
            return .invalid(status: 400, message: "request head is not UTF-8")
        }
        var lines = head.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return .invalid(status: 400, message: "empty request") }
        let requestLine = lines.removeFirst()
        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 2 else { return .invalid(status: 400, message: "bad request line") }
        let method = String(parts[0]).uppercased()
        let target = String(parts[1])

        var headers: [String: String] = [:]
        for line in lines where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }

        if let te = headers["transfer-encoding"], te.lowercased().contains("chunked") {
            return .invalid(status: 411, message: "chunked request bodies are not supported; send Content-Length")
        }
        var length = 0
        if let cl = headers["content-length"] {
            guard let n = Int(cl), n >= 0 else { return .invalid(status: 400, message: "bad Content-Length") }
            length = n
        }
        if length > maxBodyBytes { return .invalid(status: 413, message: "request body too large") }
        let bodyStart = headEnd
        let available = buffer.endIndex - bodyStart
        if available < length { return .incomplete }
        let body = Data(buffer[bodyStart..<(bodyStart + length)])

        let (path, query) = splitQuery(target)
        let req = Request(method: method, path: path, query: query, headers: headers, body: body)
        return .complete(req, consumed: (headEnd - buffer.startIndex) + length)
    }

    /// 拆 path 与 query（不做百分号解码：我们的 query 只有 ASCII 键值）。
    static func splitQuery(_ target: String) -> (String, [String: String]) {
        guard let q = target.firstIndex(of: "?") else { return (target, [:]) }
        let path = String(target[..<q])
        var dict: [String: String] = [:]
        for pair in target[target.index(after: q)...].split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            if kv.count == 2 { dict[String(kv[0])] = String(kv[1]) }
        }
        return (path, dict)
    }

    // MARK: - 应答

    struct Response {
        var status: Int
        var headers: [(String, String)] = []
        var body: Data = Data()

        static func json(_ status: Int, _ obj: Any, extra: [(String, String)] = []) -> Response {
            Response(status: status, headers: [("Content-Type", "application/json")] + extra, body: MCPJSON.data(obj))
        }
        static func text(_ status: Int, _ s: String) -> Response {
            Response(status: status, headers: [("Content-Type", "text/plain; charset=utf-8")], body: Data(s.utf8))
        }
        static func empty(_ status: Int, extra: [(String, String)] = []) -> Response {
            Response(status: status, headers: extra, body: Data())
        }
    }

    static func serialize(_ r: Response) -> Data {
        var head = "HTTP/1.1 \(r.status) \(reason(r.status))\r\n"
        for (k, v) in r.headers { head += "\(k): \(v)\r\n" }
        head += "Content-Length: \(r.body.count)\r\n"
        head += "Cache-Control: no-store\r\n"
        head += "Connection: close\r\n\r\n"
        var out = Data(head.utf8)
        out.append(r.body)
        return out
    }

    static func reason(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 202: return "Accepted"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 411: return "Length Required"
        case 413: return "Payload Too Large"
        case 431: return "Request Header Fields Too Large"
        case 500: return "Internal Server Error"
        default: return "Status"
        }
    }

    // MARK: - 安全校验（纯函数）

    /// `Origin` 校验（协议要求，防浏览器里的 DNS 重绑定）：没带 = 命令行客户端，放行；
    /// 带了就得是本机（localhost / 127.0.0.1 / ::1）或我们自己监听的地址之一。端口不看——
    /// 要挡的是别的站点，不是别的端口。
    static func originAllowed(_ origin: String?, localHosts: [String]) -> Bool {
        guard let origin, !origin.isEmpty else { return true }
        if origin == "null" { return false }   // 沙盒 iframe / file:// 页面
        guard let url = URL(string: origin), let host = url.host?.lowercased() else { return false }
        let allowed = Set(["localhost", "127.0.0.1", "::1"] + localHosts.map { $0.lowercased() })
        return allowed.contains(host)
    }

    /// `Authorization: Bearer xxx` 里的 xxx；没有/不是 Bearer → nil。
    static func bearer(_ headers: [String: String]) -> String? {
        guard let v = headers["authorization"] else { return nil }
        let parts = v.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard parts.count == 2, parts[0].lowercased() == "bearer" else { return nil }
        return String(parts[1]).trimmingCharacters(in: .whitespaces)
    }

    /// 口令比对用定长比较，别让长度/前缀差异反映在耗时上（本机场景意义不大，写对了不费事）。
    static func tokenMatches(_ presented: String?, expected: String?) -> Bool {
        guard let expected, !expected.isEmpty else { return true }   // 没设口令 = 不校验
        guard let presented else { return false }
        let a = Array(presented.utf8), b = Array(expected.utf8)
        var diff = a.count ^ b.count
        for i in 0..<min(a.count, b.count) { diff |= Int(a[i] ^ b[i]) }
        return diff == 0
    }
}
