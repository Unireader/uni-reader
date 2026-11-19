import AppKit
import Network

/// 「在浏览器中打开」用的本机静态服务（`docs/WEB-DOC-PLAN.md §3.2`）：**只听 127.0.0.1**，端口由系统给，
/// 第一次用到时才起，App 退出就没了。地址 `http://127.0.0.1:<端口>/<口令>/<网页 id>/<路径>`：
/// - 口令每次启动随机生成，别的程序猜不到路径就读不到工作区里的东西；
/// - html 响应里塞进 `window.unireader`（经 `fetch` 到同一份网页下的 `__unireader__/api`），与内嵌显示读写同一份数据；
/// - 支持 Range（浏览器放视频必须）；大文件分块发，不整份读进内存。
/// 每个请求处理完就关连接（`Connection: close`），简单可靠，静态课件用不着长连接。
@MainActor
final class WebDocLocalServer {
    static let shared = WebDocLocalServer()

    private var listener: NWListener?
    private var port: UInt16 = 0
    private let token = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    /// 网页 id（小写）→ 它所在的工作区。打开过的才登记（工作区关了弱引用自然失效）。
    private var docs: [String: WeakWorkspace] = [:]
    private let queue = DispatchQueue(label: "unireader.web-local", qos: .userInitiated)
    private var readyWaiters: [(Result<UInt16, Error>) -> Void] = []

    private struct WeakWorkspace { weak var ws: WorkspaceManager? }

    struct Failure: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// 在默认浏览器里打开某份网页（[path] = 网页里的相对路径，nil = 入口页）。
    func open(webId: String, workspace: WorkspaceManager, path: String?) throws {
        guard let w = workspace.webDoc(id: webId) else { throw Failure(message: L("This web page is no longer in the workspace.")) }
        docs[webId.lowercased()] = WeakWorkspace(ws: workspace)
        let rel = path.flatMap { $0.isEmpty ? nil : $0 } ?? w.entry
        try start { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let port):
                var c = URLComponents()
                c.scheme = "http"
                c.host = "127.0.0.1"
                c.port = Int(port)
                c.path = "/\(self.token)/\(webId.lowercased())/" + rel
                if let url = c.url { NSWorkspace.shared.open(url) }
            case .failure(let e):
                let a = NSAlert()
                a.messageText = L("Could not open the web page in the browser.")
                a.informativeText = e.localizedDescription
                a.runModal()
            }
        }
    }

    private func start(_ done: @escaping (Result<UInt16, Error>) -> Void) throws {
        if listener != nil, port != 0 { done(.success(port)); return }
        readyWaiters.append(done)
        guard listener == nil else { return }
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)
        params.allowLocalEndpointReuse = true
        let l = try NWListener(using: params)
        l.stateUpdateHandler = { [weak self] state in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.listenerState(state) }
            }
        }
        l.newConnectionHandler = { [weak self] conn in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.accept(conn) }
            }
        }
        listener = l
        l.start(queue: queue)
    }

    private func listenerState(_ state: NWListener.State) {
        switch state {
        case .ready:
            port = listener?.port?.rawValue ?? 0
            wsLog("[WEB] 本机网页服务已起：127.0.0.1:\(port)")
            let w = readyWaiters; readyWaiters = []
            for f in w { f(.success(port)) }
        case .failed(let e):
            wsLog("[WEB] ⚠️ 本机网页服务出错：\(e)")
            listener?.cancel()
            listener = nil
            port = 0
            let w = readyWaiters; readyWaiters = []
            for f in w { f(.failure(e)) }
        default:
            break
        }
    }

    // MARK: - 连接

    private func accept(_ conn: NWConnection) {
        conn.start(queue: queue)
        Self.readRequest(conn, buffer: Data()) { [weak self] req in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, let req else { conn.cancel(); return }
                    self.handle(req, on: conn)
                }
            }
        }
    }

    struct Request {
        var method: String
        var path: String          // 已百分号解码，不带查询串
        var headers: [String: String]   // 键小写
        var body: Data
    }

    /// 读到头结束（再按 Content-Length 读完正文）。头超过 64KB / 正文超过 2MB 当坏请求。
    nonisolated private static func readRequest(_ conn: NWConnection, buffer: Data, done: @escaping @Sendable (Request?) -> Void) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, isComplete, error in
            var buf = buffer
            if let data { buf.append(data) }
            if let end = buf.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: buf[buf.startIndex..<end.lowerBound], as: UTF8.self)
                var lines = head.components(separatedBy: "\r\n")
                let first = lines.removeFirst().split(separator: " ")
                guard first.count >= 2 else { done(nil); return }
                var headers: [String: String] = [:]
                for l in lines {
                    guard let c = l.firstIndex(of: ":") else { continue }
                    headers[l[..<c].trimmingCharacters(in: .whitespaces).lowercased()] = l[l.index(after: c)...].trimmingCharacters(in: .whitespaces)
                }
                let rawPath = String(first[1]).split(separator: "?", maxSplits: 1).first.map(String.init) ?? "/"
                let path = rawPath.removingPercentEncoding ?? rawPath
                let need = Int(headers["content-length"] ?? "0") ?? 0
                guard need <= 2 << 20 else { done(nil); return }
                let have = buf[end.upperBound...]
                if have.count >= need {
                    done(Request(method: String(first[0]), path: path, headers: headers, body: Data(have.prefix(need))))
                } else if isComplete || error != nil {
                    done(nil)
                } else {
                    readRequest(conn, buffer: buf, done: done)
                }
                return
            }
            if isComplete || error != nil || buf.count > 65_536 { done(nil); return }
            readRequest(conn, buffer: buf, done: done)
        }
    }

    private func handle(_ req: Request, on conn: NWConnection) {
        // /<口令>/<网页 id>/<路径>
        let parts = req.path.split(separator: "/", maxSplits: 3, omittingEmptySubsequences: false)
        guard parts.count >= 3, parts[0].isEmpty, parts[1] == token else {
            return send(conn, status: 404, headers: ["Content-Type": "text/plain; charset=utf-8"], body: Data("Not found".utf8))
        }
        let id = String(parts[2]).lowercased()
        guard parts.count == 4 else {
            // `/<口令>/<id>` 少了结尾的斜杠：跳到带斜杠的地址，相对路径才对
            return send(conn, status: 301, headers: ["Location": req.path + "/"], body: Data())
        }
        let rel = String(parts[3])
        guard let ws = docs[id]?.ws, let doc = ws.webDocs.first(where: { $0.id.lowercased() == id }), let folder = ws.folder else {
            return send(conn, status: 404, headers: ["Content-Type": "text/plain; charset=utf-8"],
                        body: Data("This web page is no longer in the workspace.".utf8))
        }
        let base = "/\(token)/\(id)/"
        if rel == WebBridgeScript.apiPath {
            guard req.method == "POST" else { return send(conn, status: 405, headers: [:], body: Data()) }
            return api(req, doc: doc, workspace: ws, on: conn)
        }
        guard req.method == "GET" || req.method == "HEAD" else { return send(conn, status: 405, headers: [:], body: Data()) }
        let files = WebDocFiles(doc: doc, folder: folder)
        let reply = files.reply(path: rel, rangeHeader: req.headers["range"])
        if reply.status == 404 || req.method == "HEAD" || reply.file == nil {
            return send(conn, status: reply.status, headers: reply.headers, body: req.method == "HEAD" ? Data() : (reply.body ?? Data()))
        }
        if reply.isHTML, reply.status == 200 {
            // html：塞进 `window.unireader`（文件不大，整份读）
            let html = (try? files.body(of: reply)) ?? Data()
            let script = WebBridgeScript.source(webId: doc.id, title: doc.title,
                                                transport: .fetch(api: base + WebBridgeScript.apiPath))
            let out = WebBridgeScript.inject(script, into: html)
            var h = reply.headers
            h["Content-Length"] = String(out.count)
            h["Accept-Ranges"] = nil
            return send(conn, status: 200, headers: h, body: out)
        }
        sendFile(conn, reply: reply)
    }

    private func api(_ req: Request, doc: LibWebDoc, workspace: WorkspaceManager, on conn: NWConnection) {
        // 只认本网页自己发来的（浏览器的同源请求 Origin 是这个服务自己；跨源的 JSON POST 会先发预检，这里不答，浏览器就不放行）
        if let origin = req.headers["origin"], origin != "http://127.0.0.1:\(port)" {
            return send(conn, status: 403, headers: [:], body: Data())
        }
        guard let obj = try? JSONSerialization.jsonObject(with: req.body) as? [String: Any], let op = obj["op"] as? String else {
            return send(conn, status: 400, headers: ["Content-Type": "text/plain; charset=utf-8"], body: Data("bad request".utf8))
        }
        do {
            let out = try workspace.webKV(webId: doc.id, op: op, key: obj["key"] as? String, value: obj["value"] as? String)
            send(conn, status: 200, headers: ["Content-Type": "application/json; charset=utf-8", "Cache-Control": "no-store"],
                 body: Data(out.utf8))
        } catch {
            send(conn, status: 400, headers: ["Content-Type": "text/plain; charset=utf-8"], body: Data(error.localizedDescription.utf8))
        }
    }

    // MARK: - 回

    nonisolated private static let reasons: [Int: String] = [200: "OK", 206: "Partial Content", 301: "Moved Permanently",
                                                 400: "Bad Request", 403: "Forbidden", 404: "Not Found",
                                                 405: "Method Not Allowed", 416: "Range Not Satisfiable"]

    nonisolated private static func head(status: Int, headers: [String: String], length: Int64?) -> Data {
        var h = headers
        if let length { h["Content-Length"] = String(length) }
        h["Connection"] = "close"
        h["X-Content-Type-Options"] = "nosniff"
        var s = "HTTP/1.1 \(status) \(reasons[status] ?? "OK")\r\n"
        for (k, v) in h.sorted(by: { $0.key < $1.key }) { s += "\(k): \(v)\r\n" }
        s += "\r\n"
        return Data(s.utf8)
    }

    private func send(_ conn: NWConnection, status: Int, headers: [String: String], body: Data) {
        var data = Self.head(status: status, headers: headers, length: headers["Content-Length"] == nil ? Int64(body.count) : nil)
        data.append(body)
        conn.send(content: data, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in conn.cancel() })
    }

    /// 文件按 1MB 一块发（发完一块再读下一块，内存里最多一块）。
    private func sendFile(_ conn: NWConnection, reply: WebDocFiles.Reply) {
        guard let url = reply.file, let range = reply.range, let fh = try? FileHandle(forReadingFrom: url) else {
            return send(conn, status: 404, headers: [:], body: Data())
        }
        let headData = Self.head(status: reply.status, headers: reply.headers, length: nil)
        conn.send(content: headData, completion: .contentProcessed { _ in })
        let handle = fh
        let end = range.upperBound + 1
        @Sendable func pump(_ at: Int64) {
            guard at < end else {
                try? handle.close()
                conn.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in conn.cancel() })
                return
            }
            let n = Int(min(Int64(1 << 20), end - at))
            let chunk: Data
            do {
                try handle.seek(toOffset: UInt64(at))
                chunk = try handle.read(upToCount: n) ?? Data()
            } catch {
                try? handle.close(); conn.cancel(); return
            }
            guard !chunk.isEmpty else { try? handle.close(); conn.cancel(); return }
            conn.send(content: chunk, completion: .contentProcessed { err in
                if err != nil { try? handle.close(); conn.cancel(); return }
                pump(at + Int64(chunk.count))
            })
        }
        queue.async { pump(range.lowerBound) }
    }
}
