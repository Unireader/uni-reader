import Foundation
import Network

/// 局域网手写服务：
/// - HTTP 监听（httpPort）分发采集页与当前页 PNG。
/// - WebSocket 监听（wsPort，走系统 `NWProtocolWebSocket` 自动分帧）传实时消息。
/// - 平板连上后首条消息须为 `{"type":"auth","token":...}`，token 不符即断开。
/// 页面状态（当前页 PNG / 页码 / 版本）统一在 `queue` 上读写。
final class LANServer: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var clientCount = 0
    @Published private(set) var lastInbound = ""
    @Published private(set) var latencyMS: Int?
    /// 入站消息速率（条/秒，不含 ping/latency 心跳），用于延迟 stats。
    @Published private(set) var inboundRate = 0
    /// 平板请求翻页时置为目标页码，供 AppModel 观察并同步页码。
    @Published var requestedPageIndex: Int?
    /// 平板请求切换文档时置为目标会话 id（空串 = 跟随 Mac 激活窗口）。
    @Published var requestedDocID: String?

    let token = Pairing.makeToken()
    let httpPort: UInt16 = 8770
    let wsPort: UInt16 = 8771

    /// 收到平板已鉴权消息（如手写笔画）的回调，在主线程调用。
    var onMessage: (([String: Any]) -> Void)?
    /// 按页号渲染 PNG（方案 B：平板按需取任意页图）。在服务 queue 上调用，须自带缓存/线程安全。
    var pageProvider: ((Int) -> Data?)?
    /// 平板上报滚动锚点（页 + 页内归一化比例 + 发送端单调时钟 ms），在主线程调用。
    var onScroll: ((Int, Double, Double) -> Void)?

    private let queue = DispatchQueue(label: "com.xvan.UniReader.lan")
    private var httpListener: NWListener?
    private var wsListener: NWListener?
    private var clients: [NWConnection] = []
    private var inboundCount = 0            // 主线程累加
    private var statsTimer: Timer?

    // 页面状态（queue 上读写）
    private var pagePNG = Data()
    private var currentPageIndex = 0
    private var pageCount = 0
    private var pageW: Double = 0
    private var pageH: Double = 0
    private var version = 0

    var pageURL: String {
        let host = NetInfo.wifiIPv4() ?? "127.0.0.1"
        return "http://\(host):\(httpPort)/?token=\(token)"
    }

    // MARK: - 生命周期

    func start() {
        guard !isRunning else { return }
        do {
            try startHTTP()
            try startWS()
            setRunning(true)
            startStats()
        } catch {
            NSLog("LANServer 启动失败: \(error)")
            stop()
        }
    }

    func stop() {
        stopStats()
        httpListener?.cancel(); httpListener = nil
        wsListener?.cancel(); wsListener = nil
        queue.async {
            let toClose = self.clients
            self.clients = []
            for c in toClose { c.cancel() }
        }
        DispatchQueue.main.async {
            self.clientCount = 0
            self.isRunning = false
        }
    }

    // MARK: - 页面推送（由 ContentView 在主线程调用）

    /// 设置当前页图片并广播给所有平板。`png` 为该页渲染结果。
    func setPage(index: Int, count: Int, width: Double, height: Double, png: Data) {
        queue.async {
            self.currentPageIndex = index
            self.pageCount = count
            self.pageW = width
            self.pageH = height
            self.pagePNG = png
            self.version += 1
            let info = self.pageInfoDict()
            for c in self.clients { self.rawSend(info, to: c) }
        }
    }

    private func pageInfoDict() -> [String: Any] {
        ["type": "page", "v": version, "index": currentPageIndex,
         "count": pageCount, "w": pageW, "h": pageH]
    }

    // MARK: - HTTP

    private func startHTTP() throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        let listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: httpPort)!)
        listener.newConnectionHandler = { [weak self] conn in self?.serveHTTP(conn) }
        listener.start(queue: queue)
        httpListener = listener
    }

    private func serveHTTP(_ conn: NWConnection) {
        conn.start(queue: queue)
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, _, _ in
            guard let self = self, let data = data, !data.isEmpty,
                  let request = String(data: data, encoding: .utf8) else {
                conn.cancel(); return
            }
            let target = LANServer.requestTarget(request)
            let (status, contentType, body) = self.route(target)
            var head = "HTTP/1.1 \(status)\r\n"
            head += "Content-Type: \(contentType)\r\n"
            head += "Content-Length: \(body.count)\r\n"
            head += "Cache-Control: no-store\r\n"
            head += "Connection: close\r\n\r\n"
            var out = Data(head.utf8); out.append(body)
            conn.send(content: out, completion: .contentProcessed { _ in conn.cancel() })
        }
    }

    /// 在 queue 上调用（读 pagePNG / 调 pageProvider）。`target` 含 query。
    private func route(_ target: String) -> (String, String, Data) {
        let (path, query) = LANServer.splitQuery(target)
        switch path {
        case "/", "/index.html":
            let html = CapturePage.html(token: token, wsPort: wsPort)
            return ("200 OK", "text/html; charset=utf-8", Data(html.utf8))
        case "/page.png":
            // 方案 B：`?i=N` 按页号取图；无 i 时回退当前页（兼容旧采集页）。
            if let iStr = query["i"], let idx = Int(iStr) {
                if let png = pageProvider?(idx), !png.isEmpty {
                    return ("200 OK", "image/png", png)
                }
                return ("404 Not Found", "text/plain; charset=utf-8", Data("no page".utf8))
            }
            if pagePNG.isEmpty {
                return ("404 Not Found", "text/plain; charset=utf-8", Data("no page".utf8))
            }
            return ("200 OK", "image/png", pagePNG)
        case "/health":
            return ("200 OK", "text/plain; charset=utf-8", Data("ok".utf8))
        default:
            return ("404 Not Found", "text/plain; charset=utf-8", Data("not found".utf8))
        }
    }

    /// 取请求行的目标（含 query），例如 `/page.png?i=3&v=abc`。
    private static func requestTarget(_ request: String) -> String {
        guard let line = request.split(separator: "\r\n").first else { return "/" }
        let parts = line.split(separator: " ")
        guard parts.count >= 2 else { return "/" }
        return String(parts[1])
    }

    /// 拆分 path 与 query 键值。
    private static func splitQuery(_ target: String) -> (String, [String: String]) {
        guard let q = target.firstIndex(of: "?") else { return (target, [:]) }
        let path = String(target[..<q])
        var dict: [String: String] = [:]
        for pair in target[target.index(after: q)...].split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            if kv.count == 2 { dict[String(kv[0])] = String(kv[1]) }
        }
        return (path, dict)
    }

    // MARK: - WebSocket

    private func startWS() throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        let ws = NWProtocolWebSocket.Options()
        ws.autoReplyPing = true
        params.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
        let listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: wsPort)!)
        listener.newConnectionHandler = { [weak self] conn in self?.acceptWS(conn) }
        listener.start(queue: queue)
        wsListener = listener
    }

    private func acceptWS(_ conn: NWConnection) {
        conn.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.dropClient(conn)
            default: break
            }
        }
        conn.start(queue: queue)
        receiveWS(conn, authed: false)
    }

    private func receiveWS(_ conn: NWConnection, authed: Bool) {
        conn.receiveMessage { [weak self] data, context, _, error in
            guard let self = self else { return }
            if error != nil { self.dropClient(conn); return }
            if let meta = context?.protocolMetadata(definition: NWProtocolWebSocket.definition)
                as? NWProtocolWebSocket.Metadata, meta.opcode == .close {
                self.dropClient(conn); return
            }
            var nowAuthed = authed
            if let data = data, !data.isEmpty,
               let text = String(data: data, encoding: .utf8),
               let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                nowAuthed = self.handle(obj, text: text, conn: conn, authed: authed)
            }
            self.receiveWS(conn, authed: nowAuthed)
        }
    }

    /// 在 queue 上调用。
    private func handle(_ obj: [String: Any], text: String, conn: NWConnection, authed: Bool) -> Bool {
        let type = obj["type"] as? String ?? ""
        if !authed {
            if type == "auth", (obj["token"] as? String) == token {
                addClient(conn)
                send(["type": "authOK"], to: conn)
                rawSend(pageInfoDict(), to: conn)   // 立即告知当前页
                return true
            } else {
                send(["type": "authFail"], to: conn)
                conn.cancel()
                return false
            }
        }

        if type != "ping" && type != "latency" {
            DispatchQueue.main.async { self.inboundCount += 1 }   // stats：不计心跳
        }

        switch type {
        case "ping":
            rawSend(["type": "pong", "t": obj["t"] ?? 0], to: conn)
            return true
        case "latency":
            if let ms = obj["ms"] as? Double {
                DispatchQueue.main.async { self.latencyMS = Int(ms.rounded()) }
            }
            return true
        case "selectDoc":
            let id = obj["id"] as? String ?? ""
            DispatchQueue.main.async { self.requestedDocID = id }
            return true
        case "pageTurn":
            let dir = obj["dir"] as? String ?? ""
            let n = (dir == "prev") ? currentPageIndex - 1 : currentPageIndex + 1
            let clamped = max(0, min(n, max(0, pageCount - 1)))
            DispatchQueue.main.async { self.requestedPageIndex = clamped }
        case "scroll":
            // 方案 B：平板本地滚动 → 上报锚点（页 + 页内归一化比例）。
            let page = (obj["page"] as? NSNumber)?.intValue ?? currentPageIndex
            let frac = (obj["frac"] as? NSNumber)?.doubleValue ?? 0
            let t = (obj["t"] as? NSNumber)?.doubleValue ?? 0
            DispatchQueue.main.async { self.onScroll?(page, frac, t) }
            return true
        default:
            break
        }

        DispatchQueue.main.async {
            self.lastInbound = String(text.prefix(200))
            self.onMessage?(obj)
        }
        return true
    }

    // MARK: - 发送

    func broadcast(_ dict: [String: Any]) {
        queue.async { for c in self.clients { self.rawSend(dict, to: c) } }
    }

    private func send(_ dict: [String: Any], to conn: NWConnection) {
        rawSend(dict, to: conn)
    }

    private func rawSend(_ dict: [String: Any], to conn: NWConnection) {
        guard let data = try? JSONSerialization.data(withJSONObject: dict) else { return }
        let meta = NWProtocolWebSocket.Metadata(opcode: .text)
        let ctx = NWConnection.ContentContext(identifier: "send", metadata: [meta])
        conn.send(content: data, contentContext: ctx, isComplete: true, completion: .contentProcessed { _ in })
    }

    // MARK: - 客户端集合（统一在 queue 上改动）

    private func addClient(_ conn: NWConnection) {
        if !clients.contains(where: { $0 === conn }) {
            clients.append(conn)
            publishCount()
        }
    }

    private func dropClient(_ conn: NWConnection) {
        let before = clients.count
        clients.removeAll { $0 === conn }
        conn.cancel()
        if clients.count != before { publishCount() }
    }

    private func publishCount() {
        let n = clients.count
        DispatchQueue.main.async { self.clientCount = n }
    }

    private func setRunning(_ v: Bool) {
        DispatchQueue.main.async { self.isRunning = v }
    }

    // MARK: - 入站速率 stats（主线程 1s 采样）

    private func startStats() {
        DispatchQueue.main.async { [weak self] in
            self?.statsTimer?.invalidate()
            self?.statsTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                guard let self else { return }
                self.inboundRate = self.inboundCount
                self.inboundCount = 0
            }
        }
    }

    private func stopStats() {
        DispatchQueue.main.async { [weak self] in
            self?.statsTimer?.invalidate(); self?.statsTimer = nil
            self?.inboundRate = 0; self?.inboundCount = 0
        }
    }
}
