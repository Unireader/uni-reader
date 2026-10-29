import Foundation

/// 连接服务器的同步线格式（方案 `SERVER-MODE-PLAN.md §3.3 / §4.2`）：push / pull 的 HTTP 请求体与响应体。
///
/// 🔴 **跨端契约**：服务器（`server/`）、Mac（S2）、安卓（S3）三处字节一致。落地客户端前写进 `PROTOCOL.md`
/// 新的一章并补跨端向量（同 `wire-cross-test` 的纪律）。本文件同时被 App 与服务器编译（服务器经符号链接
/// `server/Sources/UniServerCore/Sync`），所以**只许依赖 Foundation 与 Store 层**。
///
/// ## 原语（全部小端，同 `PROTOCOL.md §2`）
/// ```
/// u8 / u16 / u32 / u64      无符号整数
/// i64                       有符号整数（值里的 INTEGER）
/// f64                       IEEE754 双精度原始位（值里的 REAL，**不做任何规格化**，原样搬运）
/// str                       u16 字节数 + UTF-8（表名 / 行 id / 列名 / 指纹这类短串）
/// bytes                     u32 字节数 + 原字节（值里的 TEXT / BLOB）
/// value                     u8 标签（与 `MirrorFp` 同值：0 NULL / 1 INTEGER / 2 REAL / 3 TEXT / 4 BLOB）+ 内容
/// row                       u16 列数 + 每列（str 列名 + value），**列名按字典序**（同一行编出来的字节唯一）
/// ```
/// 每个消息以 `u8 版本`（= `SyncWire.version`）开头。
enum SyncWire {

    static let version: UInt8 = 1

    enum Op: UInt8 { case upsert = 0, delete = 1 }

    /// 客户端推上来的一行改动。
    struct RowChange: Equatable {
        var table: String
        var rowId: String
        var op: Op
        /// 这一行在客户端基线里的指纹（`sync_base`）。nil = 基线里没有（本机新增的行）。
        var baseFp: String?
        /// upsert 时的整行；delete 时为 nil。
        var row: [String: MirrorFp.Value]?
    }

    /// `u8 版本 · u32 schema 版本 · u32 条数 · 每条（str 表 · str 行 id · u8 op · u8 有无基线 [· str 基线指纹] [· row]）`
    struct PushRequest: Equatable {
        var schemaVersion: Int
        var changes: [RowChange]
    }

    /// 服务器怎么处理了推上来的某一行。
    enum Outcome: UInt8 {
        /// 写进服务器了（`rev` = 新修订号）。
        case applied = 0
        /// 服务器保留了自己那份（别的设备先改过，冲突规则判服务器赢）——客户端接着拉取就会拿到它。
        case keptServer = 1
        /// 父行（文档 / 画板 / 习题）在服务器上已经删了，这一行被丢弃（同离线镜像 `orphansSkipped`）。
        case skippedOrphan = 2
        /// 唯一键撞了（同一份 PDF 两边各自入库 / 同路径的 Markdown 笔记），被丢弃（同 `hashClashesSkipped`）。
        case skippedClash = 3
        /// 与服务器现状一致，什么都没做。
        case unchanged = 4
        /// 文件还没传上来（图片本体），这一行先不收；传完文件再推一次。
        case missingFile = 5
    }

    struct RowResult: Equatable {
        var table: String
        var rowId: String
        var outcome: Outcome
        /// 这一行在服务器上当前的修订号（0 = 服务器上没有这一行的记录）。
        var rev: UInt64
    }

    /// 冲突说明（给客户端的同步报告用；人话由客户端按 kind / keptServer 自己拼）。
    struct Conflict: Equatable {
        enum Kind: UInt8 { case bothModified = 0, deleteVsEdit = 1, bothAdded = 2 }
        var table: String
        var rowId: String
        var kind: Kind
        var keptServer: Bool
    }

    /// `u8 版本 · u64 head · u32 条数 · 每条（str 表 · str 行 id · u8 outcome · u64 rev）· u32 冲突数 · 每条（str · str · u8 kind · u8 keptServer）
    /// · u32 服务器版本数 · 每条（同 `PullResponse` 的一行）`
    struct PushResponse: Equatable {
        var head: UInt64
        var results: [RowResult]
        var conflicts: [Conflict]
        /// outcome = `keptServer` 的那些行在服务器上的现状（已删除也在内）。客户端按「拉下来的行」处理，
        /// 不必指望下一次拉取刚好覆盖到它（那一行的修订号可能早于客户端上次拉到的位置）。
        var serverRows: [PulledRow] = []
    }

    /// 拉下来的一行：当前内容，或「已删除」。
    struct PulledRow: Equatable {
        var table: String
        var rowId: String
        var rev: UInt64
        var deleted: Bool
        var row: [String: MirrorFp.Value]?
    }

    /// `u8 版本 · u64 head · u8 还有没有 · u32 条数 · 每条（str 表 · str 行 id · u64 rev · u8 已删除 [· row]）`
    struct PullResponse: Equatable {
        var head: UInt64
        var more: Bool
        var rows: [PulledRow]
    }

    enum DecodeError: Error, Equatable {
        case truncated, badVersion(UInt8), badTag(UInt8), badOp(UInt8), badOutcome(UInt8), badUTF8, trailingBytes
    }

    // MARK: - 与 SQLite 行互转

    /// `SQLiteDB.query` 取出的值（String / Int64 / Double / Data / NSNull）→ 线上的值。
    /// **按实际存储类搬运，不按列的声明类型归一**：服务器写回去的字节要和客户端库里的一模一样。
    static func value(fromSQLite raw: Any?) -> MirrorFp.Value {
        switch raw {
        case let s as String: return .text(s)
        case let n as Int64: return .int(n)
        case let n as Int: return .int(Int64(n))
        case let d as Double: return .real(d)
        case let b as Data: return .blob(b)
        default: return .null
        }
    }

    static func row(fromSQLite raw: [String: Any]) -> [String: MirrorFp.Value] {
        raw.mapValues { value(fromSQLite: $0) }
    }

    /// 线上的一行 → `MirrorDiff` / `MirrorApply` 认的形态（同 `SQLiteDB.query` 的输出）。
    static func sqliteRow(_ row: [String: MirrorFp.Value]) -> [String: Any] {
        row.mapValues { v -> Any in
            switch v {
            case .null: return NSNull()
            case .int(let n): return n
            case .real(let d): return d
            case .text(let s): return s
            case .blob(let b): return b
            }
        }
    }

    // MARK: - 编码

    static func encode(_ m: PushRequest) -> Data {
        var w = Writer()
        w.u8(version)
        w.u32(UInt32(clamping: m.schemaVersion))
        w.u32(UInt32(m.changes.count))
        for c in m.changes {
            w.str(c.table); w.str(c.rowId); w.u8(c.op.rawValue)
            if let b = c.baseFp { w.u8(1); w.str(b) } else { w.u8(0) }
            if c.op == .upsert { w.row(c.row ?? [:]) }
        }
        return w.data
    }

    static func encode(_ m: PushResponse) -> Data {
        var w = Writer()
        w.u8(version)
        w.u64(m.head)
        w.u32(UInt32(m.results.count))
        for r in m.results {
            w.str(r.table); w.str(r.rowId); w.u8(r.outcome.rawValue); w.u64(r.rev)
        }
        w.u32(UInt32(m.conflicts.count))
        for c in m.conflicts {
            w.str(c.table); w.str(c.rowId); w.u8(c.kind.rawValue); w.u8(c.keptServer ? 1 : 0)
        }
        w.pulledRows(m.serverRows)
        return w.data
    }

    static func encode(_ m: PullResponse) -> Data {
        var w = Writer()
        w.u8(version)
        w.u64(m.head)
        w.u8(m.more ? 1 : 0)
        w.pulledRows(m.rows)
        return w.data
    }

    // MARK: - 解码

    static func decodePushRequest(_ data: Data) throws -> PushRequest {
        var r = Reader(data)
        try r.expectVersion()
        let schema = Int(try r.u32())
        let n = try r.u32()
        var changes: [RowChange] = []
        changes.reserveCapacity(Int(min(n, 100_000)))
        for _ in 0..<n {
            let table = try r.str(), rowId = try r.str()
            let rawOp = try r.u8()
            guard let op = Op(rawValue: rawOp) else { throw DecodeError.badOp(rawOp) }
            let base: String? = try r.u8() == 1 ? try r.str() : nil
            let row = op == .upsert ? try r.row() : nil
            changes.append(RowChange(table: table, rowId: rowId, op: op, baseFp: base, row: row))
        }
        try r.expectEnd()
        return PushRequest(schemaVersion: schema, changes: changes)
    }

    static func decodePushResponse(_ data: Data) throws -> PushResponse {
        var r = Reader(data)
        try r.expectVersion()
        let head = try r.u64()
        var results: [RowResult] = []
        for _ in 0..<(try r.u32()) {
            let table = try r.str(), rowId = try r.str()
            let raw = try r.u8()
            guard let outcome = Outcome(rawValue: raw) else { throw DecodeError.badOutcome(raw) }
            results.append(RowResult(table: table, rowId: rowId, outcome: outcome, rev: try r.u64()))
        }
        var conflicts: [Conflict] = []
        for _ in 0..<(try r.u32()) {
            let table = try r.str(), rowId = try r.str()
            let raw = try r.u8()
            guard let kind = Conflict.Kind(rawValue: raw) else { throw DecodeError.badOutcome(raw) }
            conflicts.append(Conflict(table: table, rowId: rowId, kind: kind, keptServer: try r.u8() == 1))
        }
        let serverRows = try r.pulledRows()
        try r.expectEnd()
        return PushResponse(head: head, results: results, conflicts: conflicts, serverRows: serverRows)
    }

    static func decodePullResponse(_ data: Data) throws -> PullResponse {
        var r = Reader(data)
        try r.expectVersion()
        let head = try r.u64()
        let more = try r.u8() == 1
        let rows = try r.pulledRows()
        try r.expectEnd()
        return PullResponse(head: head, more: more, rows: rows)
    }

    // MARK: - 读写器

    struct Writer {
        private(set) var data = Data()

        mutating func u8(_ v: UInt8) { data.append(v) }
        mutating func u16(_ v: UInt16) { le(UInt64(v), 2) }
        mutating func u32(_ v: UInt32) { le(UInt64(v), 4) }
        mutating func u64(_ v: UInt64) { le(v, 8) }
        mutating func i64(_ v: Int64) { le(UInt64(bitPattern: v), 8) }
        mutating func f64(_ v: Double) { le(v.bitPattern, 8) }

        mutating func str(_ s: String) {
            let b = Data(s.utf8)
            precondition(b.count <= Int(UInt16.max), "SyncWire.str 超长：\(b.count) 字节")
            u16(UInt16(b.count)); data.append(b)
        }

        mutating func bytes(_ b: Data) { u32(UInt32(b.count)); data.append(b) }

        mutating func value(_ v: MirrorFp.Value) {
            switch v {
            case .null: u8(MirrorFp.tagNull)
            case .int(let n): u8(MirrorFp.tagInt); i64(n)
            case .real(let d): u8(MirrorFp.tagReal); f64(d)
            case .text(let s): u8(MirrorFp.tagText); bytes(Data(s.utf8))
            case .blob(let b): u8(MirrorFp.tagBlob); bytes(b)
            }
        }

        mutating func row(_ r: [String: MirrorFp.Value]) {
            u16(UInt16(r.count))
            for k in r.keys.sorted() { str(k); value(r[k]!) }
        }

        mutating func pulledRows(_ rows: [PulledRow]) {
            u32(UInt32(rows.count))
            for r in rows {
                str(r.table); str(r.rowId); u64(r.rev); u8(r.deleted ? 1 : 0)
                if !r.deleted { row(r.row ?? [:]) }
            }
        }

        private mutating func le(_ v: UInt64, _ n: Int) {
            for i in 0..<n { data.append(UInt8(truncatingIfNeeded: v >> (8 * UInt64(i)))) }
        }
    }

    struct Reader {
        private let bytes: [UInt8]
        private var pos = 0

        init(_ data: Data) { bytes = [UInt8](data) }

        mutating func expectVersion() throws {
            let v = try u8()
            guard v == SyncWire.version else { throw DecodeError.badVersion(v) }
        }

        func expectEnd() throws { if pos != bytes.count { throw DecodeError.trailingBytes } }

        mutating func u8() throws -> UInt8 {
            guard pos < bytes.count else { throw DecodeError.truncated }
            defer { pos += 1 }
            return bytes[pos]
        }
        mutating func u16() throws -> UInt16 { UInt16(try le(2)) }
        mutating func u32() throws -> UInt32 { UInt32(try le(4)) }
        mutating func u64() throws -> UInt64 { try le(8) }
        mutating func i64() throws -> Int64 { Int64(bitPattern: try le(8)) }
        mutating func f64() throws -> Double { Double(bitPattern: try le(8)) }

        mutating func str() throws -> String {
            let n = Int(try u16())
            return try utf8(take(n))
        }

        mutating func bytes32() throws -> Data { Data(try take(Int(try u32()))) }

        mutating func value() throws -> MirrorFp.Value {
            let tag = try u8()
            switch tag {
            case MirrorFp.tagNull: return .null
            case MirrorFp.tagInt: return .int(try i64())
            case MirrorFp.tagReal: return .real(try f64())
            case MirrorFp.tagText: return .text(try utf8(take(Int(try u32()))))
            case MirrorFp.tagBlob: return .blob(try bytes32())
            default: throw DecodeError.badTag(tag)
            }
        }

        mutating func row() throws -> [String: MirrorFp.Value] {
            var out: [String: MirrorFp.Value] = [:]
            for _ in 0..<(try u16()) {
                let k = try str()
                out[k] = try value()
            }
            return out
        }

        mutating func pulledRows() throws -> [PulledRow] {
            var rows: [PulledRow] = []
            for _ in 0..<(try u32()) {
                let table = try str(), rowId = try str()
                let rev = try u64()
                let deleted = try u8() == 1
                rows.append(PulledRow(table: table, rowId: rowId, rev: rev, deleted: deleted,
                                      row: deleted ? nil : try row()))
            }
            return rows
        }

        private mutating func take(_ n: Int) throws -> ArraySlice<UInt8> {
            guard n >= 0, pos + n <= bytes.count else { throw DecodeError.truncated }
            defer { pos += n }
            return bytes[pos..<(pos + n)]
        }

        private func utf8(_ s: ArraySlice<UInt8>) throws -> String {
            guard let str = String(bytes: s, encoding: .utf8) else { throw DecodeError.badUTF8 }
            return str
        }

        private mutating func le(_ n: Int) throws -> UInt64 {
            let s = try take(n)
            var v: UInt64 = 0
            for (i, b) in s.enumerated() { v |= UInt64(b) << (8 * UInt64(i)) }
            return v
        }
    }
}
