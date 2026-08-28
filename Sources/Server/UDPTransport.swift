import Foundation
import Network

/// UDP RT 上行接收（仅原生客户端；契约见 `PROTOCOL.md §6`）。
///
/// 一个 UDP 数据报 = `[传输头][帧本体]`；本类只管：解传输头 → 校验 session →
/// 按类别交给 per-session `UDPReorder` → 就绪帧本体经 `onFrame` 上抛（由 LANServer
/// 走与 WS 完全相同的路由）。可靠性由客户端自管（NACK 经 WS，见 LANServer）。
///
/// 全部状态在传入的 `queue` 上读写（与 LANServer 同一串行队列，免锁）。
final class UDPTransport {
    static let wireVersion: UInt8 = 0x01

    enum PType: UInt8 {
        case dataUnrel = 1, dataRel = 2, hello = 3, bye = 4
    }

    /// 就绪帧回调：(session, REL seq, 帧本体)。乱序重排后按序交付 / UNREL 最新胜放行。在 queue 上调用。
    ///
    /// `seq` 是这一帧**自己**的 REL 序号（UNREL 帧恒 0）。LANServer 拿它在主线程上记
    /// 「已应用到哪个序号」，`strokes` 广播的 `ackRel` 就是那个数——**不能**用本类的接收进度
    /// 代替，见 [ackRel] 的废弃说明。
    var onFrame: ((UInt32, UInt32, Data) -> Void)?
    /// REL 缺口回调：(session, 缺失 seq 列表)——LANServer 节流后经 WS 发 nack。在 queue 上调用。
    var onGap: ((UInt32, [UInt32]) -> Void)?

    private let queue: DispatchQueue
    private var listener: NWListener?
    private var flows: [NWConnection] = []
    /// 已登记 session → 重排状态（WS auth 成功/断开时由 LANServer 增删；未登记的一律丢弃，防注入）。
    private var sessions: [UInt32: UDPReorder] = [:]

    init(queue: DispatchQueue) {
        self.queue = queue
    }

    func start(port: UInt16) throws {
        let params = NWParameters.udp
        params.allowLocalEndpointReuse = true
        let listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
        listener.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
        listener.start(queue: queue)
        self.listener = listener
    }

    func stop() {
        listener?.cancel(); listener = nil
        for f in flows { f.cancel() }
        flows = []
        sessions = [:]
    }

    // MARK: - session 登记（LANServer 在 queue 上调用）

    func addSession(_ session: UInt32) {
        sessions[session] = UDPReorder()
    }

    func removeSession(_ session: UInt32) {
        sessions[session] = nil
    }

    /// 该 session 的 REL 流**已收到并交付**的最大 seq（`relExpected - 1`）；未登记/一包没收过则 0。
    ///
    /// ⚠️ **这不是 `strokes` 广播该带的 `ackRel`**（2026-08-28 修）。「已交付」发生在本队列上，
    /// 而帧的**效果**（落墨/擦除）是 `DispatchQueue.main.async` 到主线程上才应用的，快照也在主线程上建。
    /// 拿本值当 ackRel，就会出现「快照里还没有那一笔、ackRel 却已经盖过它」——客户端据此撤掉
    /// 自己的乐观笔迹，屏幕上刚写完的字就闪掉一下（回推越大、队列越堵，窗口越宽）。
    /// 真正的 ackRel 由 `LANServer.appliedRel` 在主线程上记账，见那里。本函数只留作诊断。
    func ackRel(session: UInt32) -> UInt32 {
        guard let r = sessions[session] else { return 0 }
        return r.relExpected > 1 ? r.relExpected - 1 : 0
    }

    /// 定时器驱动（LANServer ~30ms）：所有 session 的 REL 缺口超时兜底。
    /// 放弃丢失帧跳过的就绪 body 同样经 onFrame 上抛。
    func flushStale(now: Date = Date()) {
        for (session, var r) in sessions {
            let out = r.flushStale(now: now)
            sessions[session] = r
            if !out.isEmpty {
                NSLog("UDP session %u: flushStale 跳过缺口，补交 %u 帧", session, out.count)
                // 补交的这批是从跳到的 minSeq 起**连续**的（见 UDPReorder.flushStale），
                // 故末尾即 relExpected-1，倒推出每一帧自己的 seq
                var s = r.relExpected - UInt32(out.count)
                for body in out { onFrame?(session, s, body); s += 1 }
            }
        }
    }

    // MARK: - 接收

    private func accept(_ conn: NWConnection) {
        flows.append(conn)
        conn.stateUpdateHandler = { [weak self, weak conn] state in
            guard let self, let conn else { return }
            if case .failed = state { self.dropFlow(conn) }
            if case .cancelled = state { self.dropFlow(conn) }
        }
        conn.start(queue: queue)
        receive(conn)
    }

    private func dropFlow(_ conn: NWConnection) {
        flows.removeAll { $0 === conn }
        conn.cancel()
    }

    private func receive(_ conn: NWConnection) {
        conn.receiveMessage { [weak self, weak conn] data, _, _, error in
            guard let self, let conn else { return }
            if error != nil { self.dropFlow(conn); return }
            if let data, !data.isEmpty { self.handleDatagram(data) }
            self.receive(conn)
        }
    }

    /// 解传输头并分发。非法/未知 session 一律静默丢弃。
    private func handleDatagram(_ data: Data) {
        let b = [UInt8](data)
        guard b.count >= 6, b[0] == UDPTransport.wireVersion,
              let ptype = PType(rawValue: b[1]) else { return }
        let session = UInt32(b[2]) | (UInt32(b[3]) << 8) | (UInt32(b[4]) << 16) | (UInt32(b[5]) << 24)
        guard var reorder = sessions[session] else { return }   // 未登记 session：丢

        switch ptype {
        case .hello:
            NSLog("UDP HELLO session=%u（客户端 UDP 就绪）", session)
        case .bye:
            sessions[session] = UDPReorder()   // 重置重排状态，session 登记保留（WS 还活着）
        case .dataUnrel:
            guard b.count >= 10 else { return }
            let seq = Self.seq(b)
            if let body = reorder.unreliable(seq, data.subdata(in: 10..<b.count)) {
                sessions[session] = reorder
                onFrame?(session, 0, body)   // UNREL 不参与 ackRel 记账
            } else {
                sessions[session] = reorder
            }
        case .dataRel:
            guard b.count >= 10 else { return }
            let seq = Self.seq(b)
            // 交付批是从**调用前**的 relExpected 起连续的（见 UDPReorder.reliable），据此还原每帧的 seq
            let first = reorder.relExpected
            let result = reorder.reliable(seq, data.subdata(in: 10..<b.count))
            sessions[session] = reorder
            var s = first
            for body in result.deliver { onFrame?(session, s, body); s += 1 }
            if !result.nack.isEmpty { onGap?(session, result.nack) }
        }
    }

    private static func seq(_ b: [UInt8]) -> UInt32 {
        UInt32(b[6]) | (UInt32(b[7]) << 8) | (UInt32(b[8]) << 16) | (UInt32(b[9]) << 24)
    }
}
