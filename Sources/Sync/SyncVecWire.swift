import Foundation

/// 块向量经服务器同步的线格式（方案 `SEMANTIC-SYNC-PLAN.md`，契约 `PROTOCOL.md §9.7`）。
///
/// 🔴 **跨端契约**：服务器、Mac、安卓（`android/…/local/server/SyncWire.kt`）字节一致；跨端向量追加在 `spike/sync-wire-vectors.txt` 末尾。
/// 与 `SyncWire.swift` 一样被 App 与服务器同时编译，只许依赖 Foundation。
///
/// 向量按**内容寻址**：键 = (模型标识, SHA-256(块正文 UTF-8))，值 = Int8 × 维数（单位向量 ×127 取整，同 Mac 索引 `vec.v`）。
/// ```
/// VecHashes   u8 版本 · str 模型 · u32 条数 · 每条 32 字节哈希               （missing / prune 的请求体）
/// VecMissing  u8 版本 · u32 服务器上这个模型的总条数 · u32 条数 · 每条 32 字节哈希 （missing 的响应体）
/// VecPut      u8 版本 · str 模型 · u16 维数 · u32 条数 · 每条（32 字节哈希 + 维数字节）（POST vectors 的请求体）
/// VecPage     u8 版本 · str epoch · u64 下一页的 since · u8 还有没有 · u16 维数 · u32 条数 · 每条（32 字节哈希 + 维数字节）（GET vectors 的响应体）
/// ```
extension SyncWire {

    static let vecHashSize = 32

    struct VecEntry: Equatable {
        /// 32 字节 SHA-256（块正文的 UTF-8）。
        var hash: Data
        /// Int8 × 维数，原样字节。
        var v: Data
    }

    struct VecHashes: Equatable {
        var model: String
        var hashes: [Data]
    }

    struct VecMissing: Equatable {
        var total: UInt32
        var hashes: [Data]
    }

    struct VecPut: Equatable {
        var model: String
        var dim: Int
        var entries: [VecEntry]
    }

    struct VecPage: Equatable {
        var epoch: String
        var next: UInt64
        var more: Bool
        var dim: Int
        var entries: [VecEntry]
    }

    // MARK: 编码

    static func encode(_ m: VecHashes) -> Data {
        var w = Writer(); w.u8(version); w.str(m.model)
        w.hashes(m.hashes)
        return w.data
    }

    static func encode(_ m: VecMissing) -> Data {
        var w = Writer(); w.u8(version); w.u32(m.total)
        w.hashes(m.hashes)
        return w.data
    }

    static func encode(_ m: VecPut) -> Data {
        var w = Writer(); w.u8(version); w.str(m.model)
        w.entries(m.entries, dim: m.dim)
        return w.data
    }

    static func encode(_ m: VecPage) -> Data {
        var w = Writer(); w.u8(version); w.str(m.epoch); w.u64(m.next); w.u8(m.more ? 1 : 0)
        w.entries(m.entries, dim: m.dim)
        return w.data
    }

    // MARK: 解码

    static func decodeVecHashes(_ data: Data) throws -> VecHashes {
        var r = Reader(data); try r.expectVersion()
        let m = VecHashes(model: try r.str(), hashes: try r.hashes())
        try r.expectEnd(); return m
    }

    static func decodeVecMissing(_ data: Data) throws -> VecMissing {
        var r = Reader(data); try r.expectVersion()
        let m = VecMissing(total: try r.u32(), hashes: try r.hashes())
        try r.expectEnd(); return m
    }

    static func decodeVecPut(_ data: Data) throws -> VecPut {
        var r = Reader(data); try r.expectVersion()
        let model = try r.str()
        let (dim, entries) = try r.entries()
        try r.expectEnd()
        return VecPut(model: model, dim: dim, entries: entries)
    }

    static func decodeVecPage(_ data: Data) throws -> VecPage {
        var r = Reader(data); try r.expectVersion()
        let epoch = try r.str(), next = try r.u64(), more = try r.u8() == 1
        let (dim, entries) = try r.entries()
        try r.expectEnd()
        return VecPage(epoch: epoch, next: next, more: more, dim: dim, entries: entries)
    }
}

extension SyncWire.Writer {
    fileprivate mutating func hashes(_ hs: [Data]) {
        u32(UInt32(hs.count))
        for h in hs { precondition(h.count == SyncWire.vecHashSize, "哈希必须 32 字节"); raw(h) }
    }
    fileprivate mutating func entries(_ es: [SyncWire.VecEntry], dim: Int) {
        u16(UInt16(dim)); u32(UInt32(es.count))
        for e in es {
            precondition(e.hash.count == SyncWire.vecHashSize && e.v.count == dim, "哈希 32 字节、向量 = 维数")
            raw(e.hash); raw(e.v)
        }
    }
}

extension SyncWire.Reader {
    fileprivate mutating func hashes() throws -> [Data] {
        let n = Int(try u32())
        var out: [Data] = []; out.reserveCapacity(min(n, 100_000))
        for _ in 0..<n { out.append(try fixed(SyncWire.vecHashSize)) }
        return out
    }
    fileprivate mutating func entries() throws -> (Int, [SyncWire.VecEntry]) {
        let dim = Int(try u16()), n = Int(try u32())
        var out: [SyncWire.VecEntry] = []; out.reserveCapacity(min(n, 100_000))
        for _ in 0..<n { out.append(.init(hash: try fixed(SyncWire.vecHashSize), v: try fixed(dim))) }
        return (dim, out)
    }
}
