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

    /// 就绪帧回调：(session, 帧本体)。乱序重排后按序交付 / UNREL 最新胜放行。在 queue 上调用。
    var onFrame: ((UInt32, Data) -> Void)?
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

    /// 该 session 的 REL 流**已连续处理到**的最大 seq（`relExpected - 1`）；未登记/一包没收过则 0。
    ///
    /// 随 `strokes` 广播回给客户端（`PROTOCOL.md §4.2` 的 `ackRel`），让它分得清收到的全量快照
    /// 含不含自己刚发出去的输入——擦除途中 Mac 每收一批点就广播一次，那一串中途快照都比客户端
    /// 本地的乐观状态旧，照单全收会把已擦掉的笔迹一份份恢复出来。
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
                for body in out { onFrame?(session, body) }
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
                onFrame?(session, body)
            } else {
                sessions[session] = reorder
            }
        case .dataRel:
            guard b.count >= 10 else { return }
            let seq = Self.seq(b)
            let result = reorder.reliable(seq, data.subdata(in: 10..<b.count))
            sessions[session] = reorder
            for body in result.deliver { onFrame?(session, body) }
            if !result.nack.isEmpty { onGap?(session, result.nack) }
        }
    }

    private static func seq(_ b: [UInt8]) -> UInt32 {
        UInt32(b[6]) | (UInt32(b[7]) << 8) | (UInt32(b[8]) << 16) | (UInt32(b[9]) << 24)
    }
}
