import Foundation

/// 一个服务器工作区的块向量（方案 `SEMANTIC-SYNC-PLAN.md §2`，线格式 `PROTOCOL.md §9.7`）。
///
/// 存在 `<数据目录>/vectors/<workspace_id>.sqlite`，**不在工作区包里**：派生数据（Mac 能重传），不进备份、快照、导出；
/// 工作区删除时整个文件删掉（不走回收站——红线⑪管的是用户数据）。
///
/// 按内容寻址：键 = (模型, SHA-256(块正文))，同一个键谁先传都一样，所以没有冲突处理；每条新的拿一个递增 `rev`，
/// 设备按 `rev > since` 增量拉。清理孤儿（`prune`）换一个新 `epoch`，设备见到 epoch 变了就清空重拉。
public final class WorkspaceVectors: @unchecked Sendable {

    /// 单次上传 / 拉取的上限（2000 × 1 KB ≈ 2 MB）。
    public static let maxBatch = 2000

    static let ddl = """
    CREATE TABLE IF NOT EXISTS vec(
      model TEXT NOT NULL, hash BLOB NOT NULL, v BLOB NOT NULL, rev INTEGER NOT NULL,
      PRIMARY KEY(model, hash)) WITHOUT ROWID;
    CREATE INDEX IF NOT EXISTS vec_rev ON vec(model, rev);
    CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value TEXT NOT NULL);
    """

    private let db: SQLiteDB
    private let lock = NSLock()
    private var closed = false

    init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        db = try SQLiteDB(path: url.path)
        try db.exec("PRAGMA journal_mode=WAL;")
        try db.exec(Self.ddl)
        if meta("epoch") == nil { try setMeta("epoch", ServerCrypto.randomHex(bytes: 8)) }
    }

    func close() {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return }
        closed = true
        db.close()
    }

    private func checkOpen() throws {
        if closed { throw ServerError.badRequest("工作区已删除") }
    }

    // MARK: - 元数据

    private func meta(_ key: String) -> String? {
        (try? db.query("SELECT value FROM meta WHERE key = ?", [.text(key)]))?.first?["value"] as? String
    }

    private func setMeta(_ key: String, _ value: String) throws {
        try db.run("INSERT OR REPLACE INTO meta(key, value) VALUES (?, ?)", [.text(key), .text(value)])
    }

    private var head: UInt64 { UInt64(meta("head") ?? "") ?? 0 }

    public var epoch: String {
        lock.lock(); defer { lock.unlock() }
        return meta("epoch") ?? ""
    }

    private func hashes(model: String) throws -> Set<Data> {
        Set(try db.query("SELECT hash FROM vec WHERE model = ?", [.text(model)]) { $0.blob(0) })
    }

    // MARK: - 接口

    /// 设备给一组哈希，回服务器没有的那些 + 这个模型的总条数。
    func missing(_ req: SyncWire.VecHashes) throws -> SyncWire.VecMissing {
        lock.lock(); defer { lock.unlock() }
        try checkOpen()
        let have = try hashes(model: req.model)
        var seen = Set<Data>()
        let miss = req.hashes.filter { !have.contains($0) && seen.insert($0).inserted }
        return SyncWire.VecMissing(total: UInt32(have.count), hashes: miss)
    }

    /// 收一批；已有的键跳过。维数与这个模型已有的不同 → 拒收（换了模型却没换标识）。
    func put(_ req: SyncWire.VecPut) throws -> (added: Int, head: UInt64) {
        guard !req.model.isEmpty, req.dim > 0 else { throw ServerError.badRequest("模型标识或维数为空") }
        guard req.entries.count <= Self.maxBatch else { throw ServerError.badRequest("一次最多 \(Self.maxBatch) 条") }
        lock.lock(); defer { lock.unlock() }
        try checkOpen()
        if let any = try db.query("SELECT length(v) AS n FROM vec WHERE model = ? LIMIT 1", [.text(req.model)]).first,
           let n = any["n"] as? Int64, Int(n) != req.dim {
            throw ServerError.badRequest("维数 \(req.dim) 与已有的 \(n) 不同")
        }
        var h = head, added = 0
        try db.transaction {
            for e in req.entries {
                let exists = try !db.query("SELECT 1 AS x FROM vec WHERE model = ? AND hash = ?",
                                           [.text(req.model), .blob(e.hash)]).isEmpty
                if exists { continue }
                h += 1; added += 1
                try db.run("INSERT INTO vec(model, hash, v, rev) VALUES (?, ?, ?, ?)",
                           [.text(req.model), .blob(e.hash), .blob(e.v), .int(Int64(h))])
            }
            if added > 0 { try setMeta("head", String(h)) }
        }
        return (added, h)
    }

    /// 增量拉：`rev > since`，按 rev 排。设备传来的 epoch 与服务器不同（或没传）→ 从头给。
    func page(model: String, since: UInt64, epoch: String?, limit: Int) throws -> SyncWire.VecPage {
        lock.lock(); defer { lock.unlock() }
        try checkOpen()
        let current = meta("epoch") ?? ""
        let from = epoch == current ? since : 0
        let n = min(max(limit, 1), Self.maxBatch)
        let rows = try db.query("SELECT hash, v, rev FROM vec WHERE model = ? AND rev > ? ORDER BY rev LIMIT ?",
                                [.text(model), .int(Int64(from)), .int(Int64(n + 1))]) { r in
            (SyncWire.VecEntry(hash: r.blob(0), v: r.blob(1)), UInt64(r.int64(2)))
        }
        let more = rows.count > n
        let page = rows.prefix(n)
        return SyncWire.VecPage(epoch: current, next: page.last?.1 ?? from, more: more,
                                dim: page.first?.0.v.count ?? 0, entries: page.map(\.0))
    }

    /// 只留这个模型仍在用的哈希，其余删掉，换新 epoch。
    func prune(_ req: SyncWire.VecHashes) throws -> (removed: Int, epoch: String) {
        lock.lock(); defer { lock.unlock() }
        try checkOpen()
        let keep = Set(req.hashes)
        let drop = try hashes(model: req.model).subtracting(keep)
        let epoch = ServerCrypto.randomHex(bytes: 8)
        try db.transaction {
            for h in drop { try db.run("DELETE FROM vec WHERE model = ? AND hash = ?", [.text(req.model), .blob(h)]) }
            try setMeta("epoch", epoch)
        }
        return (drop.count, epoch)
    }

    // MARK: - 字节进、字节出（HTTP 层用；解不开 → badRequest）

    private static func decode<T>(_ body: Data, _ f: (Data) throws -> T) throws -> T {
        do { return try f(body) } catch { throw ServerError.badRequest("请求体解不开：\(error)") }
    }

    public func missing(body: Data) throws -> Data {
        SyncWire.encode(try missing(Self.decode(body, SyncWire.decodeVecHashes)))
    }

    public func put(body: Data) throws -> (added: Int, head: UInt64) {
        try put(Self.decode(body, SyncWire.decodeVecPut))
    }

    public func pageBody(model: String, since: UInt64, epoch: String?, limit: Int) throws -> Data {
        SyncWire.encode(try page(model: model, since: since, epoch: epoch, limit: limit))
    }

    public func prune(body: Data) throws -> (removed: Int, epoch: String) {
        try prune(Self.decode(body, SyncWire.decodeVecHashes))
    }

    /// 这个模型现有多少条（测试 / 日志用）。
    public func count(model: String) throws -> Int {
        lock.lock(); defer { lock.unlock() }
        try checkOpen()
        return try hashes(model: model).count
    }
}
