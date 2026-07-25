import Foundation

/// UDP 接收端重排（纯逻辑，与网络 I/O 解耦；契约见 `PROTOCOL.md §6`）。
///
/// 每个 session 一个实例，两个独立 seq 空间：
/// - **UNREL**（scroll/hover）：最新胜，`seq > lastUnrel` 才放行，旧/重复丢弃。
/// - **REL**（ink/erase/probe）：有序不丢。乱序进 `relBuf` 并报缺口（供 NACK）；
///   缺口卡死超 `stallMs` 由 `flushStale` 放弃丢失帧、跳到缓冲最小学号继续（接受小段豁口）。
///
/// 仅依赖 Foundation，`spike/udp-reorder-test.swift` 可单文件 swiftc 编译。
struct UDPReorder {
    /// 下一个待交付的 REL seq（从 1）。
    private(set) var relExpected: UInt32 = 1
    /// REL 重排缓冲：seq → 帧本体。
    private(set) var relBuf: [UInt32: Data] = [:]
    /// 已放行的最大 UNREL seq。
    private(set) var lastUnrel: UInt32 = 0
    /// 上次 REL 交付推进时刻。
    private(set) var lastAdvance = Date()
    /// 当前缺口首次出现的时刻（flushStale 的卡死判据；无缺口为 nil）。
    /// 不能用 lastAdvance 判卡死：上一笔交付后静置任何 >stallMs 的空档，
    /// 新缺口一出现就会被立即跳过，NACK 重传根本来不及跑。
    private(set) var gapSince: Date?
    /// 缺口卡死多久后放弃跳过（毫秒）。
    var stallMs: Double = 200

    init(stallMs: Double = 200, now: Date = Date()) {
        self.stallMs = stallMs
        self.lastAdvance = now
    }

    /// 收 REL 包：返回（要按序交付的 body 列表, 缺口 seq 列表——供 NACK）。
    mutating func reliable(_ seq: UInt32, _ body: Data, now: Date = Date()) -> (deliver: [Data], nack: [UInt32]) {
        if seq < relExpected { return ([], []) }            // 重复（含曾跳过又迟到的）
        if seq == relExpected {
            var out = [body]
            relExpected += 1
            while let b = relBuf.removeValue(forKey: relExpected) { out.append(b); relExpected += 1 }
            lastAdvance = now
            gapSince = nil                                  // 交付推进 → 当前无缺口
            return (out, [])
        }
        // seq > relExpected：入缓冲（重复乱序包保留先到者），报缺口
        if gapSince == nil { gapSince = now }               // 新缺口开始计时
        let firstSeen = relBuf[seq] == nil
        if firstSeen { relBuf[seq] = body }
        let missing = (relExpected..<seq).filter { relBuf[$0] == nil }
        return ([], missing)
    }

    /// 收 UNREL 包：最新胜。返回 body；旧/重复返回 nil（丢弃）。
    mutating func unreliable(_ seq: UInt32, _ body: Data) -> Data? {
        if seq <= lastUnrel { return nil }
        lastUnrel = seq
        return body
    }

    /// 定时器驱动：缺口持续超 stallMs 且缓冲非空 → 放弃丢失帧，跳到缓冲最小学号排空交付。
    mutating func flushStale(now: Date = Date()) -> [Data] {
        guard !relBuf.isEmpty, let since = gapSince,
              now.timeIntervalSince(since) * 1000 > stallMs,
              let minSeq = relBuf.keys.min() else { return [] }
        relExpected = minSeq
        var out = [Data]()
        while let b = relBuf.removeValue(forKey: relExpected) { out.append(b); relExpected += 1 }
        lastAdvance = now
        gapSince = nil
        return out
    }
}
