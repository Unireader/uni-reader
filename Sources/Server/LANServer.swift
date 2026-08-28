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

    /// 配对 token 的**主线程镜像**：只给面板用（二维码 / 地址栏 / 复制）。
    /// 鉴权那份是 [authToken]——两份同值，分开是因为读它们的线程不同（见 [resetToken]）。
    @Published private(set) var token: String

    /// 鉴权用的那份，**只在服务 queue 上读写**（HTTP 路由拼采集页、WS `auth` 比对）。
    private var authToken: String

    let httpPort: UInt16 = 8770
    let wsPort: UInt16 = 8771
    /// UDP 监听端口（仅原生客户端 RT 上行；浏览器永远 WS）。随 authOK 下发。
    let udpPort: UInt16 = 8772

    /// 收到平板已鉴权消息（如手写笔画）的回调，在主线程调用。
    var onMessage: (([String: Any]) -> Void)?
    /// 按页号渲染页图（方案 B：平板按需取任意页图）。在服务 queue 上调用，须自带缓存/线程安全。
    var pageProvider: ((PageImageRequest) -> Data?)?

    /// 一次页图请求（`/page.png` 的 query 解析结果）。
    struct PageImageRequest {
        let index: Int
        /// 目标像素宽度，**已归到 [pageWidthSteps] 的档位**（客户端也归一次，两边同一张阶梯）
        let width: Int
        let format: PageRenderer.Format
    }

    /// 页图宽度档位。
    ///
    /// ⚠️ **安卓端 `shared/PageWidths.kt` 有一份同样的阶梯**，改这里必须同步改那边——不一致的
    /// 表现是「客户端按 2160 存、服务端按 2880 渲」，两边缓存永远不命中。这不是线格式，
    /// 不涉及 `PROTOCOL.md` 的字节向量。服务端要再归一次：旧客户端/手敲 URL 不归档的话，
    /// 每个像素宽度都会在 `AppModel.pageCache` 里占一份，缓存直接被打散。
    static let pageWidthSteps = [480, 720, 1080, 1440, 2160, 2880]

    /// 不带 `w=` 时的宽度（浏览器采集页就不带）——保持旧行为，不改网页那侧的观感。
    static let defaultPageWidth = 1600

    static func snapPageWidth(_ w: Int) -> Int {
        pageWidthSteps.first { $0 >= max(1, w) } ?? pageWidthSteps[pageWidthSteps.count - 1]
    }
    /// 平板上报滚动锚点（页 + 页内归一化比例 + 发送端单调时钟 ms），在主线程调用。
    var onScroll: ((Int, Double, Double) -> Void)?

    private let queue = DispatchQueue(label: "com.xvan.UniReader.lan")
    /// 上一次 `/page.png` 处理完的时刻（只在 [queue] 上碰）。用于日志里那个「距上次页图请求结束」。
    private var lastPagePNGEnd: CFAbsoluteTime = 0
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

    init() {
        let t = Pairing.persistentToken()
        token = t
        authToken = t
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

    /// 换一张配对码（面板上的「重置配对码」）。**在主线程调用。**
    ///
    /// 旧码立即作废：连着的平板会被踢下线，安卓「历史设备」里那条也要重扫码才能再连
    /// ——这正是这颗按钮存在的意义（token 现在是持久的，不重置就永远是同一个）。
    ///
    /// 两处细节都踩过：
    /// - 鉴权用的 [authToken] 只在服务 queue 上碰，所以写它要 `queue.async`（排在 `stop()`
    ///   那个关连接的块后面，FIFO 保证新连接一定看到新码）；面板那份 [token] 在主线程写。
    /// - `stop()` 把 `isRunning` 置回 false 是 `DispatchQueue.main.async` 的，此刻仍是 true
    ///   → 紧接着调 `start()` 会被开头的 `guard !isRunning` 挡掉，服务就再也起不来。
    ///   所以重启也得排到主线程队列的后面去。
    func resetToken() {
        let fresh = Pairing.resetToken()
        let wasRunning = isRunning
        if wasRunning { stop() }
        queue.async { self.authToken = fresh }
        token = fresh
        if wasRunning { DispatchQueue.main.async { self.start() } }
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
            let t0 = CFAbsoluteTimeGetCurrent()
            let (status, contentType, body) = self.route(target)
            // 页图请求的耗时账（`PadLog`，默认关；开关见 UniReaderApp.swift）。
            // 「距上次结束」是关键的第二个数：本 queue 是**串行**的，页图渲染、WS 收发、广播全排在
            // 同一条上。这个数逼近 0 就说明请求是背靠背排队的——平板等的其实是队列，不是单页渲染。
            if target.hasPrefix("/page.png") {
                let t1 = CFAbsoluteTimeGetCurrent()
                PadLog.log("HTTP \(target) → \(status)，\(body.count / 1024)KB，"
                    + "占用服务队列 \(PadLog.ms(t1 - t0))（距上次页图请求结束 \(PadLog.ms(t0 - self.lastPagePNGEnd))）")
                self.lastPagePNGEnd = t1
            }
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
            let html = CapturePage.html(token: authToken, wsPort: wsPort)
            return ("200 OK", "text/html; charset=utf-8", Data(html.utf8))
        case "/wire.js":
            // 二进制线格式编解码器（采集页与 Mac 共用同一份，见 PROTOCOL.md）。无秘密，不校验 token。
            return ("200 OK", "application/javascript; charset=utf-8", LANServer.wireJS())
        case "/page.png":
            // 方案 B：`?i=N` 按页号取图；无 i 时回退当前页（兼容旧采集页）。
            // 两条都走 `pageProvider`（服务 queue 上跑、自带 NSCache）——兜底那条曾用主线程预渲染好的
            // `pagePNG`，代价是每次翻页阻塞主线程渲一张没人取的图（见 `AppModel.push` 注释），已删除。
            //
            // `w=` 目标像素宽度（不带 = 旧行为 1600，浏览器采集页就不带）；
            // `f=png` 要无损原样，`q=NN` 调 JPEG 质量；**默认 JPEG**——不是为省流量（省不了），
            // 是因为高分辨率下 PNG 编码要 130~260ms 且占的是本条串行队列，见 `PageRenderer.Format`。
            let idx = query["i"].flatMap(Int.init) ?? currentPageIndex
            // 只归一**客户端报上来的**宽度；不带 `w=` 的（浏览器采集页）原样走旧的 1600，
            // 免得顺手把网页那侧的观感/流量也改了。
            let width = query["w"].flatMap(Int.init).map(LANServer.snapPageWidth) ?? LANServer.defaultPageWidth
            // `q=` 是 JPEG 质量旋钮（1~100），只为对比/调参留的；不带就用默认档。
            let quality = query["q"].flatMap(Double.init).map { min(max($0, 1), 100) / 100 }
            let format: PageRenderer.Format =
                query["f"] == "png" ? .png : .jpeg(quality: quality ?? PageRenderer.defaultJPEGQuality)
            let req = PageImageRequest(index: idx, width: width, format: format)
            if let data = pageProvider?(req), !data.isEmpty {
                return ("200 OK", format.contentType, data)
            }
            return ("404 Not Found", "text/plain; charset=utf-8", Data("no page".utf8))
        case "/health":
            return ("200 OK", "text/plain; charset=utf-8", Data("ok".utf8))
        case "/info":
            // 这台 Mac 的名字，给安卓输入板的「历史设备」列表当标题用（那边手里只有一个 IP，
            // DHCP 换个地址就分不清刚才连的是谁）。**刻意不走线格式**：加一个字段就要三端同步 +
            // 重出字节向量（PROTOCOL.md 开头那条红线），而这只是一句展示用的文本。
            // 不校验 token——与 `/page.png`、`/health` 同级，机器名在同一局域网里本来就是公开的
            // （Bonjour/SMB 都在广播它）。
            return ("200 OK", "application/json; charset=utf-8", LANServer.infoJSON())
        default:
            return ("404 Not Found", "text/plain; charset=utf-8", Data("not found".utf8))
        }
    }

    /// `/info` 的机器名。两个都给，客户端优先用 `name`：
    /// - `name` = 「电脑名称」（系统设置里那个，如「xVan 的 MacBook Pro」）——人一眼能认；
    /// - `hostName` = 真主机名（如 `xvans-macbook-pro.local`）——某些环境下前者为空时的兜底。
    /// 用 `JSONSerialization` 而不是手拼字符串：机器名里带中文/引号是常态，手拼一定会漏转义。
    private static func infoJSON() -> Data {
        let dict: [String: Any] = [
            "name": Host.current().localizedName ?? "",
            "hostName": ProcessInfo.processInfo.hostName,
        ]
        return (try? JSONSerialization.data(withJSONObject: dict)) ?? Data("{}".utf8)
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
        udp.onFrame = { [weak self] session, relSeq, body in
            guard let self else { return }
            guard let conn = self.connBySession[session], let obj = WireCodec.decode(body) else {
                // 连接没了 / 帧解不出来：这一帧不会有任何效果，但 ackRel **必须照样推进**——
                // 卡住的话客户端会永远等一个不会到来的序号（乐观笔迹撤不掉、擦除后的快照全被丢弃）。
                if relSeq > 0 { DispatchQueue.main.async { self.noteApplied(session: session, seq: relSeq) } }
                return
            }
            let type = obj["type"] as? String ?? ""
            let text = "[udp] " + type
            _ = self.handle(obj, text: text, conn: conn, authed: true, relSeq: relSeq, session: session)
            // REL 流按契约只跑 ink/erase/probe（`PROTOCOL.md §3`），它们必定走到 handle 末尾那个
            // 主线程块、在那里记账。万一将来别的类型走了 REL 且被 handle 提前 return，这里补一次。
            if relSeq > 0, type != "ink", type != "erase", type != "probe" {
                DispatchQueue.main.async { self.noteApplied(session: session, seq: relSeq) }
            }
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
    ///
    /// `relSeq`/`session`：这一帧若来自 UDP 可靠流，就是它自己的 REL 序号 —— 末尾那个主线程块会在
    /// **应用它之前**把 `appliedRel` 推到这个数（见 [noteApplied]）。0 = WS 或 UNREL，不记账。
    private func handle(
        _ obj: [String: Any], text: String, conn: NWConnection, authed: Bool,
        relSeq: UInt32 = 0, session: UInt32 = 0,
    ) -> Bool {
        let type = obj["type"] as? String ?? ""
        if !authed {
            if type == "auth", (obj["token"] as? String) == authToken {
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
            // 顺序要紧：先推 appliedRel 再应用。两句之间主线程不会跑别的，而 onMessage 里同步触发的
            // `broadcastStrokes` 读到的就是「含这一帧」的值——正是这份快照的真实内容。
            if relSeq > 0 { self.noteApplied(session: session, seq: relSeq) }
            self.onMessage?(obj)
        }
        return true
    }

    // MARK: - ackRel 记账（`PROTOCOL.md §4.2`）

    /// session → **已在主线程上应用到**的最大 REL 序号。`strokes`/`scratchStrokes` 广播带的
    /// `ackRel` 就是它，且必须在**建快照的那一刻**（主线程）取值：
    ///
    /// 输入帧的接收在 `queue` 上、应用在主线程上，两者之间隔着一次 `DispatchQueue.main.async`；
    /// 广播的发送又是 `queue.async` 出去的。若像旧版那样在 `rawSend` 里现取
    /// `UDPTransport.ackRel`（接收进度），拿到的是「收到了多少」而不是「这份快照含了多少」——
    /// 回推越大、发送队列越堵，两者差得越多。客户端据此把还没回来的乐观笔迹当成「真源已有」撤掉，
    /// 屏幕上刚写完的字就闪一下（2026-08-28 用户报「上一个字的笔画依次闪烁」）。
    private var appliedRel: [UInt32: UInt32] = [:]
    private let ackLock = NSLock()

    /// 主线程上调用：把该 session 的已应用序号推到 seq（只增不减）。
    private func noteApplied(session: UInt32, seq: UInt32) {
        ackLock.lock(); defer { ackLock.unlock() }
        if seq > (appliedRel[session] ?? 0) { appliedRel[session] = seq }
    }

    private func appliedRelSnapshot() -> [UInt32: UInt32] {
        ackLock.lock(); defer { ackLock.unlock() }
        return appliedRel
    }

    private func forgetApplied(session: UInt32) {
        ackLock.lock(); defer { ackLock.unlock() }
        appliedRel[session] = nil
    }

    // MARK: - 发送

    func broadcast(_ dict: [String: Any]) {
        // ackRel 必须**在这里**（调用方线程 = 主线程，快照刚刚建好）取，不能等 queue.async 之后：
        // 那时又收进来的输入会被算进 ackRel，可这份快照里并没有它们。详见 [appliedRel]。
        let acks = appliedRelSnapshot()
        queue.async { for c in self.clients { self.rawSend(dict, to: c, acks: acks) } }
    }

    private func send(_ dict: [String: Any], to conn: NWConnection) {
        rawSend(dict, to: conn)
    }

    private func rawSend(_ dict: [String: Any], to conn: NWConnection, acks: [UInt32: UInt32] = [:]) {
        var dict = dict
        // `strokes` 的 ackRel 要按**收件人**填：每个客户端的 REL 流进度各不相同，所以只能在这里补，
        // 不能由 AppModel 在 broadcastStrokes 里填一个值发给所有人（见 PROTOCOL.md §4.2）。
        // 值本身来自 broadcast 在建快照那一刻取的 [appliedRel] 快照；直发（非广播）没有这个快照，
        // 填 0 = 「不适用」，客户端照单全收——新接入时它本来也没有待认领的乐观笔迹。
        if dict["type"] as? String == "strokes" || dict["type"] as? String == "scratchStrokes" {
            let s = sessionByConn[ObjectIdentifier(conn)]
            dict["ackRel"] = NSNumber(value: s.flatMap { acks[$0] } ?? 0)
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
            forgetApplied(session: session)   // 重连会分到新 session，旧记账留着只是泄漏
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
