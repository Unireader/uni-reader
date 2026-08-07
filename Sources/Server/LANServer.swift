import Foundation
import Network

/// 一个已连接的平板客户端（供面板显示/踢除）。`id` 稳定于连接生命周期。
struct ClientInfo: Identifiable, Equatable {
    let id: UUID
    let address: String
}

/// 局域网手写服务：
/// - HTTP 监听（httpPort）分发采集页与当前页 PNG。
/// - WebSocket 监听（wsPort，走系统 `NWProtocolWebSocket` 自动分帧）传实时消息。
/// - 平板连上后首条消息须为 `{"type":"auth","token":...}`，token 不符即断开。
/// 页面状态（当前页 PNG / 页码 / 版本）统一在 `queue` 上读写。
final class LANServer: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var clientCount = 0
    /// 已连接的平板列表（地址 + 稳定 id），供面板显示与「踢除」。
    @Published private(set) var clientList: [ClientInfo] = []
    @Published private(set) var lastInbound = ""
    @Published private(set) var latencyMS: Int?
    /// 入站消息速率（条/秒，不含 ping/latency 心跳），用于延迟 stats。
    @Published private(set) var inboundRate = 0
    /// 平板请求翻页时置为目标页码，供 AppModel 观察并同步页码。
    @Published var requestedPageIndex: Int?
    /// 平板请求切换文档时置为目标会话 id（空串 = 跟随 Mac 激活窗口）。
    @Published var requestedDocID: String?
    /// 平板请求打开工作区里某个文档时置为**库文档 id**（≠ requestedDocID 的窗口会话 id，见 PROTOCOL.md §4.1）。
    @Published var requestedOpenDocID: String?
    /// 平板请求跳转到（页, 页内比例）——目录跳转带 frac，与只跳页的 `requestedPageIndex` 分开走，
    /// 因为后者只有页号、落点一律页顶。`@Published` 不做值去重，连点同一条目录项照样每次触发。
    @Published var requestedGoto: GotoTarget?

    struct GotoTarget { let page: Int; let frac: Double }

    let token = Pairing.makeToken()
    let httpPort: UInt16 = 8770
    let wsPort: UInt16 = 8771
    /// UDP 监听端口（仅原生客户端 RT 上行；浏览器永远 WS）。随 authOK 下发。
    let udpPort: UInt16 = 8772

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
    private var infoByConn: [ObjectIdentifier: ClientInfo] = [:]   // conn → 客户端信息（列表/踢除用）
    private var inboundCount = 0            // 主线程累加
    private var statsTimer: Timer?

    // UDP（queue 上读写；契约见 PROTOCOL.md §6）
    private var udp: UDPTransport?
    private var sessionByConn: [ObjectIdentifier: UInt32] = [:]  // WS conn → UDP 会话号
    private var connBySession: [UInt32: NWConnection] = [:]      // UDP 会话号 → WS conn（NACK 回路）
    private var pendingNacks: [UInt32: Set<UInt32>] = [:]        // session → 待 NACK 的 REL seq（节流汇总）
    private var maintenanceTimer: DispatchSourceTimer?           // ~30ms：flushStale + NACK 冲刷

    // 页面状态（queue 上读写）
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
            try startUDP()
            setRunning(true)
            startStats()
        } catch {
            NSLog("LANServer 启动失败: \(error)")
            stop()
        }
    }

    func stop() {
        stopStats()
        maintenanceTimer?.cancel(); maintenanceTimer = nil
        udp?.stop(); udp = nil
        sessionByConn = [:]
        connBySession = [:]
        pendingNacks = [:]
        httpListener?.cancel(); httpListener = nil
        wsListener?.cancel(); wsListener = nil
        queue.async {
            let toClose = self.clients
            self.clients = []
            self.infoByConn = [:]
            for c in toClose { c.cancel() }
        }
        DispatchQueue.main.async {
            self.clientCount = 0
            self.clientList = []
            self.isRunning = false
        }
    }

    // MARK: - 页面推送（由 ContentView 在主线程调用）

    /// 设置当前页元信息并广播给所有平板（**只有标量，页图由平板按 `/page.png?i=N` 自取**——
    /// 调用方不得在主线程为此渲染页图，理由见 `AppModel.push`）。
    func setPage(index: Int, count: Int, width: Double, height: Double) {
        queue.async {
            self.currentPageIndex = index
            self.pageCount = count
            self.pageW = width
            self.pageH = height
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
        case "/wire.js":
            // 二进制线格式编解码器（采集页与 Mac 共用同一份，见 PROTOCOL.md）。无秘密，不校验 token。
            return ("200 OK", "application/javascript; charset=utf-8", LANServer.wireJS())
        case "/page.png":
            // 方案 B：`?i=N` 按页号取图；无 i 时回退当前页（兼容旧采集页）。
            // 两条都走 `pageProvider`（服务 queue 上跑、自带 NSCache）——兜底那条曾用主线程预渲染好的
            // `pagePNG`，代价是每次翻页阻塞主线程渲一张没人取的图（见 `AppModel.push` 注释），已删除。
            let idx = query["i"].flatMap(Int.init) ?? currentPageIndex
            if let png = pageProvider?(idx), !png.isEmpty {
                return ("200 OK", "image/png", png)
            }
            return ("404 Not Found", "text/plain; charset=utf-8", Data("no page".utf8))
        case "/health":
            return ("200 OK", "text/plain; charset=utf-8", Data("ok".utf8))
        default:
            return ("404 Not Found", "text/plain; charset=utf-8", Data("not found".utf8))
        }
    }

    /// 采集页共用的二进制编解码器 JS（Resources/wire.js）。
    private static func wireJS() -> Data {
        if let url = Bundle.main.url(forResource: "wire", withExtension: "js"),
           let data = try? Data(contentsOf: url) { return data }
        return Data("/* wire.js 资源缺失 */".utf8)
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
        // 关 Nagle：低频控制消息不被攒 ~40ms（RT 流走 UDP 后 WS 只剩可靠通道，零成本正确设置）。
        (params.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options)?.noDelay = true
        let ws = NWProtocolWebSocket.Options()
        ws.autoReplyPing = true
        params.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
        let listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: wsPort)!)
        listener.newConnectionHandler = { [weak self] conn in self?.acceptWS(conn) }
        listener.start(queue: queue)
        wsListener = listener
    }

    // MARK: - UDP（仅原生客户端 RT 上行）

    private func startUDP() throws {
        let udp = UDPTransport(queue: queue)
        // 已排序就绪的 UDP 帧本体：WireCodec.decode 后走与 WS 完全相同的路由（handleInk/onScroll 零改动）。
        udp.onFrame = { [weak self] session, body in
            guard let self, let conn = self.connBySession[session],
                  let obj = WireCodec.decode(body) else { return }
            let text = "[udp] " + (obj["type"] as? String ?? "?")
            _ = self.handle(obj, text: text, conn: conn, authed: true)
        }
        // REL 缺口：汇总进 pendingNacks，由 maintenanceTimer 节流后经 WS 发 nack（NACK 绝不能丢，不走 UDP）。
        udp.onGap = { [weak self] session, seqs in
            self?.pendingNacks[session, default: []].formUnion(seqs)
        }
        try udp.start(port: udpPort)
        self.udp = udp

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .milliseconds(30), repeating: .milliseconds(30), leeway: .milliseconds(10))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.udp?.flushStale()                       // REL 缺口超时兜底（stallMs 后跳过）
            let pending = self.pendingNacks
            self.pendingNacks = [:]
            for (session, seqs) in pending {
                guard let conn = self.connBySession[session] else { continue }
                self.rawSend(["type": "nack", "seqs": seqs.sorted()], to: conn)
            }
        }
        timer.resume()
        maintenanceTimer = timer
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
            if let data = data, !data.isEmpty, let obj = WireCodec.decode(data) {
                let text = "[bin] " + (obj["type"] as? String ?? "?")
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
                // 生成 UDP 会话号并登记（session↔WS 连接映射；UDP 数据报凭它鉴权/路由）。
                var session = UInt32.random(in: 1...UInt32.max)
                while connBySession[session] != nil { session = UInt32.random(in: 1...UInt32.max) }
                sessionByConn[ObjectIdentifier(conn)] = session
                connBySession[session] = conn
                udp?.addSession(session)
                send(["type": "authOK", "session": session, "udpPort": udpPort], to: conn)
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
        case "gotoPage":
            let target = (obj["page"] as? NSNumber)?.intValue ?? currentPageIndex
            let clamped = max(0, min(target, max(0, pageCount - 1)))
            let frac = min(max(0, (obj["frac"] as? NSNumber)?.doubleValue ?? 0), 1)
            DispatchQueue.main.async { self.requestedGoto = GotoTarget(page: clamped, frac: frac) }
            return true
        case "openDoc":
            let id = obj["id"] as? String ?? ""
            guard !id.isEmpty else { return true }
            DispatchQueue.main.async { self.requestedOpenDocID = id }
            return true
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
        var dict = dict
        // `strokes` 的 ackRel 要按**收件人**填：每个客户端的 REL 流进度各不相同，所以只能在这里补，
        // 不能由 AppModel 在 broadcastStrokes 里填一个值发给所有人（见 PROTOCOL.md §4.2）。
        if dict["type"] as? String == "strokes" || dict["type"] as? String == "scratchStrokes" {
            let s = sessionByConn[ObjectIdentifier(conn)]
            dict["ackRel"] = NSNumber(value: s.flatMap { udp?.ackRel(session: $0) } ?? 0)
        }
        guard let data = WireCodec.encode(dict) else { return }
        let meta = NWProtocolWebSocket.Metadata(opcode: .binary)
        let ctx = NWConnection.ContentContext(identifier: "send", metadata: [meta])
        conn.send(content: data, contentContext: ctx, isComplete: true, completion: .contentProcessed { _ in })
    }

    // MARK: - 客户端集合（统一在 queue 上改动）

    private func addClient(_ conn: NWConnection) {
        if !clients.contains(where: { $0 === conn }) {
            clients.append(conn)
            infoByConn[ObjectIdentifier(conn)] = ClientInfo(id: UUID(), address: endpointString(conn))
            publishClients()
        }
    }

    private func dropClient(_ conn: NWConnection) {
        let before = clients.count
        clients.removeAll { $0 === conn }
        infoByConn[ObjectIdentifier(conn)] = nil
        // WS 断开 → 注销 UDP session（其后带该 session 的 UDP 一律丢弃）
        if let session = sessionByConn[ObjectIdentifier(conn)] {
            sessionByConn[ObjectIdentifier(conn)] = nil
            connBySession[session] = nil
            pendingNacks[session] = nil
            udp?.removeSession(session)
        }
        conn.cancel()
        if clients.count != before { publishClients() }
    }

    /// 踢除指定客户端（面板「断开」按钮）：取消其连接 → 状态回调走 dropClient。
    func kick(_ id: UUID) {
        queue.async {
            guard let conn = self.clients.first(where: { self.infoByConn[ObjectIdentifier($0)]?.id == id })
            else { return }
            self.dropClient(conn)
        }
    }

    private func publishClients() {
        let n = clients.count
        let list = clients.compactMap { infoByConn[ObjectIdentifier($0)] }
        DispatchQueue.main.async { self.clientCount = n; self.clientList = list }
    }

    /// 连接远端地址串（IP），供列表显示。
    private func endpointString(_ conn: NWConnection) -> String {
        if case let .hostPort(host, _) = conn.endpoint { return "\(host)" }
        return "\(conn.endpoint)"
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
