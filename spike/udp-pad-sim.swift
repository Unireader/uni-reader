// UDP 平板模拟器（真·局域网 UX/延迟实测）：单文件、零依赖，另一台 Mac 上直接跑：
//   swift spike/udp-pad-sim.swift --host <Mac的IP> --token <配对token>
// token 在 UniReader 配对面板/二维码 URL 里（http://<ip>:8770/?token=XXXX 的 XXXX）。
//
// 行为等价未来的安卓模式2 客户端（PROTOCOL.md §6）：
//   WS（ws://host:8771）auth → authOK 拿 session/udpPort → UDP 发一发 HELLO →
//   RT 流全走 UDP：scroll/hover = UNREL（最新胜），ink/erase = REL（重排+NACK 轻量重传，
//   本地环形缓冲 ringCap=512，收 WS nack 即重发）。pageTurn/ping 走 WS（控制/心跳）。
//
// 操作：鼠标拖动 = 手写（ ink ）；滚轮/双指 = 滚动（ scroll ）；移动 = hover；
//   E = 橡皮切换；P = 换笔（4 支预设）；←/→ = 翻页；Q = 退出。
// 状态栏：RTT（WS ping）/ REL 已发 / NACK 与重传次数——NACK>0 说明 UDP 真在丢包。
import Foundation
import Network
import AppKit

// MARK: - 参数

var argHost = "", argToken = ""
var argWSPort: UInt16 = 8771
var i = 1
while i < CommandLine.arguments.count {
    let a = CommandLine.arguments[i]
    if a == "--host", i + 1 < CommandLine.arguments.count { argHost = CommandLine.arguments[i + 1]; i += 1 }
    else if a == "--token", i + 1 < CommandLine.arguments.count { argToken = CommandLine.arguments[i + 1]; i += 1 }
    else if a == "--port", i + 1 < CommandLine.arguments.count { argWSPort = UInt16(CommandLine.arguments[i + 1]) ?? 8771; i += 1 }
    i += 1
}
if argHost.isEmpty || argToken.isEmpty {
    print("用法: swift spike/udp-pad-sim.swift --host <Mac的IP> --token <配对token> [--port 8771]")
    exit(2)
}

// MARK: - 迷你线格式（镜像 WireCodec.swift / wire.js 子集，全小端；改协议时同步）

struct BW {
    var d = Data()
    mutating func u8(_ v: UInt8) { d.append(v) }
    mutating func u16(_ v: Int) { d.append(UInt8(v & 0xff)); d.append(UInt8((v >> 8) & 0xff)) }
    mutating func u32(_ v: UInt32) {
        d.append(UInt8(v & 0xff)); d.append(UInt8((v >> 8) & 0xff))
        d.append(UInt8((v >> 16) & 0xff)); d.append(UInt8((v >> 24) & 0xff))
    }
    mutating func f32(_ v: Double) { u32(Float(v).bitPattern) }
    mutating func f64(_ v: Double) {
        let x = v.bitPattern
        for k in 0..<8 { d.append(UInt8((x >> (UInt64(k) * 8)) & 0xff)) }
    }
    mutating func str(_ s: String) { let b = Array(s.utf8); u16(b.count); d.append(contentsOf: b) }
}

struct BR {
    let d: [UInt8]; var n = 0
    init(_ data: Data) { d = [UInt8](data) }
    var left: Int { d.count - n }
    mutating func u8() -> UInt8 { let v = d[n]; n += 1; return v }
    mutating func u16() -> Int { let v = Int(d[n]) | (Int(d[n + 1]) << 8); n += 2; return v }
    mutating func u32() -> UInt32 {
        let v = UInt32(d[n]) | (UInt32(d[n + 1]) << 8) | (UInt32(d[n + 2]) << 16) | (UInt32(d[n + 3]) << 24)
        n += 4; return v
    }
    mutating func f32() -> Double { Double(Float(bitPattern: u32())) }
    mutating func f64() -> Double {
        var x: UInt64 = 0
        for k in 0..<8 { x |= UInt64(d[n + k]) << (UInt64(k) * 8) }
        n += 8; return Double(bitPattern: x)
    }
    mutating func str() -> String {
        let L = u16(); let s = String(decoding: d[n..<n + L], as: UTF8.self); n += L; return s
    }
}

let brushCode: [String: UInt8] = ["ballpoint": 0, "fountain": 1, "marker": 2, "pencil": 3]

/// "rgba(24,90,210,0.95)" → (r,g,b,a)，同 WireCodec.parseColor 规则。
func parseColor(_ css: String) -> (UInt8, UInt8, UInt8, Float) {
    guard let open = css.firstIndex(of: "("), let close = css.firstIndex(of: ")"), open < close else { return (0, 0, 0, 1) }
    let p = css[css.index(after: open)..<close].split(separator: ",").map { Double($0.trimmingCharacters(in: .whitespaces)) ?? 0 }
    return (UInt8(clamping: Int(p.count > 0 ? p[0] : 0)), UInt8(clamping: Int(p.count > 1 ? p[1] : 0)),
            UInt8(clamping: Int(p.count > 2 ? p[2] : 0)), Float(p.count > 3 ? p[3] : 1))
}

// MARK: - 客户端状态

final class PadSim {
    // 网络
    var ws: NWConnection?
    var udp: NWConnection?
    var session: UInt32 = 0
    var udpPort: UInt16 = 8772
    var udpReady = false
    // REL 自管：seq + 重传环形缓冲（ringCap=512）
    var seqRel: UInt32 = 0
    var seqUnrel: UInt32 = 0
    var ring: [UInt32: Data] = [:]
    var ringOrder: [UInt32] = []
    // 文档状态（WS 下发的 page/layout）
    var currentPage = 0
    var pageCount = 0
    var aspect: [Double] = []           // 每页 h/w（layout），滚动步长用
    // 统计
    var sentRel = 0, sentUnrel = 0, nacks = 0, resends = 0
    var pingT: Double = 0, rtt: Double = -1
    // UI
    var eraseMode = false
    var penIndex = 0
    var onStatus: (() -> Void)?
}

let sim = PadSim()
let netQ = DispatchQueue(label: "udp-pad-sim.net")

let pens: [(color: String, w: Double, t: String)] = [
    ("rgba(24,90,210,0.95)", 4, "ballpoint"),
    ("rgba(20,20,20,1)", 6, "pencil"),
    ("rgba(220,40,40,0.9)", 2.5, "fountain"),
    ("rgba(255,214,40,0.35)", 22, "marker"),
]

// MARK: - 帧编码（帧本体，PROTOCOL.md §4）

func frameAuth() -> Data { var w = BW(); w.u8(0x01); w.str(argToken); return w.d }
func framePing(_ t: Double) -> Data { var w = BW(); w.u8(0x10); w.f64(t); return w.d }
func framePageTurn(_ dir: UInt8) -> Data { var w = BW(); w.u8(0x21); w.u8(dir); return w.d }

func frameScroll(page: Int, frac: Double, t: Double) -> Data {
    var w = BW(); w.u8(0x40); w.u32(UInt32(page)); w.f32(frac); w.f64(t); return w.d
}
func frameHover(page: Int, nx: Double, ny: Double) -> Data {
    var w = BW(); w.u8(0x41); w.u8(1); w.u32(UInt32(page)); w.f32(nx); w.f32(ny); return w.d
}
func frameHoverEnd() -> Data { var w = BW(); w.u8(0x41); w.u8(2); return w.d }

func penBytes(_ w: inout BW) {
    let p = pens[sim.penIndex]
    let (r, g, b, a) = parseColor(p.color)
    w.u8(r); w.u8(g); w.u8(b); w.f32(Double(a)); w.f32(p.w); w.u8(brushCode[p.t] ?? 0)
}
func frameInkBegin(page: Int, pt: (Double, Double, Double)) -> Data {
    var w = BW(); w.u8(0x42); w.u8(0); w.u32(UInt32(page)); penBytes(&w)
    w.u16(1); w.f32(pt.0); w.f32(pt.1); w.f32(pt.2); return w.d
}
func frameInkMove(_ pts: [(Double, Double, Double)]) -> Data {
    var w = BW(); w.u8(0x42); w.u8(1); w.u16(pts.count)
    for p in pts { w.f32(p.0); w.f32(p.1); w.f32(p.2) }
    return w.d
}
func frameInkEnd() -> Data { var w = BW(); w.u8(0x42); w.u8(2); return w.d }
func frameEraseMove(page: Int, pts: [(Double, Double)]) -> Data {
    var w = BW(); w.u8(0x43); w.u8(1); w.u32(UInt32(page)); w.u16(pts.count)
    for p in pts { w.f32(p.0); w.f32(p.1) }
    return w.d
}
func frameEraseEnd() -> Data { var w = BW(); w.u8(0x43); w.u8(2); return w.d }

// MARK: - UDP 发送（传输头见 PROTOCOL.md §6）

func udpSend(_ data: Data) {
    sim.udp?.send(content: data, completion: .contentProcessed { _ in })
}

/// ptype: 1=DATA_UNREL 2=DATA_REL 3=HELLO 4=BYE
func datagram(_ ptype: UInt8, seq: UInt32? = nil, body: Data = Data()) -> Data {
    var w = BW()
    w.u8(0x01); w.u8(ptype); w.u32(sim.session)
    if let seq { w.u32(seq) }
    w.d.append(body)
    return w.d
}

func sendRel(_ body: Data) {
    guard sim.udpReady else { return }
    sim.seqRel &+= 1
    let dg = datagram(2, seq: sim.seqRel, body: body)
    sim.ring[sim.seqRel] = dg
    sim.ringOrder.append(sim.seqRel)
    if sim.ringOrder.count > 512 {                 // ringCap=512：满则淘汰最旧
        sim.ring[sim.ringOrder.removeFirst()] = nil
    }
    udpSend(dg)
    sim.sentRel += 1
    sim.onStatus.map { cb in DispatchQueue.main.async { cb() } }
}

func sendUnrel(_ body: Data) {
    guard sim.udpReady else { return }
    sim.seqUnrel &+= 1
    udpSend(datagram(1, seq: sim.seqUnrel, body: body))
    sim.sentUnrel += 1
}

// MARK: - WS 收发

func wsSend(_ data: Data) {
    guard let ws = sim.ws else { return }
    let meta = NWProtocolWebSocket.Metadata(opcode: .binary)
    ws.send(content: data, contentContext: .init(identifier: "s", metadata: [meta]),
            isComplete: true, completion: .contentProcessed { _ in })
}

func wsReceive(_ conn: NWConnection) {
    conn.receiveMessage { data, ctx, _, error in
        if error != nil { print("WS 断开: \(error!)"); return }
        if let meta = ctx?.protocolMetadata(definition: NWProtocolWebSocket.definition)
            as? NWProtocolWebSocket.Metadata, meta.opcode == .close { print("WS close"); return }
        if let data, !data.isEmpty { handleWS(data) }
        wsReceive(conn)
    }
}

func handleWS(_ data: Data) {
    var r = BR(data)
    let op = r.u8()
    switch op {
    case 0x02:                                  // authOK: [u32 session][u16 udpPort]
        sim.session = r.u32()
        sim.udpPort = UInt16(r.u16())
        print("authOK session=\(sim.session) udpPort=\(sim.udpPort)")
        startUDP()
    case 0x11:                                  // pong
        let t = r.f64()
        sim.rtt = Date().timeIntervalSince1970 * 1000 - t
        DispatchQueue.main.async { sim.onStatus?() }
    case 0x30:                                  // page: v/index/count/w/h
        _ = r.u32()
        sim.currentPage = Int(r.u32())
        sim.pageCount = Int(r.u32())
    case 0x31:                                  // layout: docId/v/count/count×(w,h)
        _ = r.str(); _ = r.str()
        let c = Int(r.u32())
        var a: [Double] = []
        for _ in 0..<c { let w = r.f32(), h = r.f32(); a.append(w > 0 ? h / w : 1.4) }
        sim.aspect = a
        sim.pageCount = c
    case 0x50:                                  // nack: [u16 n][n×u32 seq] → 环形缓冲重发
        let n = r.u16()
        var hit = 0
        for _ in 0..<n {
            let seq = r.u32()
            if let dg = sim.ring[seq] { udpSend(dg); hit += 1 }
        }
        sim.nacks += n
        sim.resends += hit
        DispatchQueue.main.async { sim.onStatus?() }
    default: break                              // page.png/docs/pens/strokes 等：模拟器不消费
    }
}

// MARK: - 连接

func startWS() {
    let params = NWParameters.tcp
    let wso = NWProtocolWebSocket.Options()
    params.defaultProtocolStack.applicationProtocols.insert(wso, at: 0)
    let conn = NWConnection(host: NWEndpoint.Host(argHost),
                            port: NWEndpoint.Port(rawValue: argWSPort)!, using: params)
    sim.ws = conn
    conn.stateUpdateHandler = { state in
        switch state {
        case .ready:
            print("WS 已连接 \(argHost):\(argWSPort)，auth…")
            wsSend(frameAuth())
            // WS 心跳基线（对照 UDP 手感；RTT 只代表 TCP 路径）
            Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
                sim.pingT = Date().timeIntervalSince1970 * 1000
                wsSend(framePing(sim.pingT))
            }
        case .preparing: print("WS 连接中…（超过几秒没动静 → 查「本地网络」权限/防火墙）")
        case .waiting(let e): print("WS waiting: \(e)")
        case .failed(let e): print("WS 失败: \(e)")
        case .cancelled: print("WS cancelled")
        default: break
        }
    }
    conn.start(queue: netQ)
    wsReceive(conn)
}

func startUDP() {
    let conn = NWConnection(host: NWEndpoint.Host(argHost),
                            port: NWEndpoint.Port(rawValue: sim.udpPort)!, using: .udp)
    sim.udp = conn
    conn.stateUpdateHandler = { state in
        switch state {
        case .ready:
            sim.udpReady = true
            udpSend(datagram(3))                // HELLO 一发（不保活，评审定案）
            print("UDP 就绪 → \(argHost):\(sim.udpPort)（HELLO 已发）")
            DispatchQueue.main.async { sim.onStatus?() }
        case .waiting(let e): print("UDP waiting: \(e)")
        case .failed(let e): print("UDP 失败: \(e)")
        default: break
        }
    }
    conn.start(queue: netQ)
}

// MARK: - 交互视图（鼠标当笔）

var pendingInk: [(Double, Double, Double)] = []
var pendingErase: [(Double, Double)] = []
var drawing = false
var scrollFrac: Double = 0                    // 本地虚拟锚点（page = sim.currentPage 视角）
var scrollPage = 0

func flushInkBatch() {
    if !pendingInk.isEmpty {
        let pts = pendingInk; pendingInk = []
        sendRel(frameInkMove(pts))
    }
    if !pendingErase.isEmpty {
        let pts = pendingErase; pendingErase = []
        sendRel(frameEraseMove(page: sim.currentPage, pts: pts))
    }
}

final class PadView: NSView {
    override var acceptsFirstResponder: Bool { true }
    override func viewDidMoveToWindow() {
        let ta = NSTrackingArea(rect: bounds, options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect], owner: self)
        addTrackingArea(ta)
    }
    private func pt(_ e: NSEvent) -> (Double, Double, Double) {
        let l = convert(e.locationInWindow, from: nil)
        let nx = max(0, min(1, l.x / bounds.width))
        let ny = max(0, min(1, 1 - l.y / bounds.height))
        let p = e.pressure > 0 ? Double(e.pressure) : 0.5
        return (nx, ny, p)
    }
    override func mouseDown(with e: NSEvent) {
        drawing = true
        pendingInk = []; pendingErase = []
        if !sim.eraseMode { sendRel(frameInkBegin(page: sim.currentPage, pt: pt(e))) }
    }
    override func mouseDragged(with e: NSEvent) {
        let p = pt(e)
        if sim.eraseMode { pendingErase.append((p.0, p.1)) } else { pendingInk.append(p) }
    }
    override func mouseUp(with e: NSEvent) {
        drawing = false
        mouseDragged(with: e)
        flushInkBatch()
        sendRel(sim.eraseMode ? frameEraseEnd() : frameInkEnd())
    }
    override func mouseMoved(with e: NSEvent) {
        let p = pt(e)
        sendUnrel(frameHover(page: sim.currentPage, nx: p.0, ny: p.1))
    }
    override func mouseExited(with e: NSEvent) { sendUnrel(frameHoverEnd()) }
    override func scrollWheel(with e: NSEvent) {
        guard sim.pageCount > 0 else { return }
        if scrollPage != sim.currentPage { scrollPage = sim.currentPage; scrollFrac = 0 }
        // 统一成「自然滚动」方向：触控板双指上推=前进；鼠标滚轮上滚=回退。
        // 名义页高 600pt：滚轮像素 → 页内归一化位移。
        let dy = Double(e.scrollingDeltaY) * (e.isDirectionInvertedFromDevice ? 1 : -1)
        scrollFrac += dy / 600
        while scrollFrac >= 1, scrollPage < sim.pageCount - 1 { scrollFrac -= 1; scrollPage += 1 }
        while scrollFrac < 0, scrollPage > 0 { scrollFrac += 1; scrollPage -= 1 }
        scrollFrac = max(0, min(1, scrollFrac))
        sendUnrel(frameScroll(page: scrollPage, frac: scrollFrac,
                              t: Date().timeIntervalSince1970 * 1000))
    }
    override func keyDown(with e: NSEvent) {
        switch e.charactersIgnoringModifiers?.lowercased() {
        case "e":
            sim.eraseMode.toggle()
        case "p":
            sim.penIndex = (sim.penIndex + 1) % pens.count
            sim.eraseMode = false
        case "q":
            udpSend(datagram(4))               // BYE（可选优化）
            NSApp.terminate(nil)
        default:
            if e.keyCode == 123 { wsSend(framePageTurn(0)) }       // ← prev
            else if e.keyCode == 124 { wsSend(framePageTurn(1)) }  // → next
        }
        sim.onStatus?()
    }
    override func draw(_ r: NSRect) {
        NSColor.white.setFill(); r.fill()
        NSColor(white: 0.85, alpha: 1).setStroke()
        NSBezierPath(rect: bounds.insetBy(dx: 0.5, dy: 0.5)).stroke()
    }
}

// MARK: - 窗口 + 状态栏

final class SimApp: NSObject, NSApplicationDelegate {
    var statusField: NSTextField!
    func applicationDidFinishLaunching(_ n: Notification) {
        let win = NSWindow(contentRect: NSRect(x: 200, y: 120, width: 720, height: 960),
                           styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        win.title = "UDP Pad Sim → \(argHost)"
        let root = NSView(frame: win.contentView!.bounds)
        root.autoresizingMask = [.width, .height]
        win.contentView = root

        statusField = NSTextField(labelWithString: "连接中…")
        statusField.frame = NSRect(x: 10, y: root.bounds.height - 30, width: root.bounds.width - 20, height: 22)
        statusField.autoresizingMask = [.width, .minYMargin]
        statusField.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        root.addSubview(statusField)

        let pad = PadView(frame: root.bounds.insetBy(dx: 10, dy: 10).offsetBy(dx: 0, dy: 30))
        pad.autoresizingMask = [.width, .height]
        pad.wantsLayer = true
        pad.layer?.backgroundColor = NSColor.white.cgColor
        root.addSubview(pad)

        sim.onStatus = { [weak self] in
            guard let self else { return }
            let p = pens[sim.penIndex]
            self.statusField.stringValue = String(
                format: "%@  page %d/%d  rtt %.0fms  rel %d  unrel %d  nack %d  resend %d  [%@]",
                sim.udpReady ? "UDP✓" : "…", sim.currentPage + 1, sim.pageCount,
                sim.rtt, sim.sentRel, sim.sentUnrel, sim.nacks, sim.resends,
                sim.eraseMode ? "橡皮" : p.t)
        }
        // 8ms 合批刷点（≈125Hz，等价 capture.html 合批）
        Timer.scheduledTimer(withTimeInterval: 0.008, repeats: true) { _ in flushInkBatch() }

        win.makeKeyAndOrderFront(nil)
        win.makeFirstResponder(pad)
        NSApp.activate(ignoringOtherApps: true)
        sim.onStatus?()
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { true }
}

print("UDP Pad Sim：目标 \(argHost)（ws:\(argWSPort)）")
print("操作：拖动=手写 滚轮=滚动 E=橡皮 P=换笔 ←/→=翻页 Q=退出")
startWS()
let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = SimApp()
app.delegate = delegate
app.run()
