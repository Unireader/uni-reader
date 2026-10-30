import Foundation

/// 服务器上的一个工作区（方案 `SERVER-MODE-PLAN.md §3 / §4`）。
///
/// 磁盘上就是一个标准 `.unrd`（同一套 schema，`LibraryStore` 建表 / 迁移），外加服务器私有的两样东西，
/// **放在同一个库里**（WAL 模式下跨 `ATTACH` 库的事务不是整体原子的，行改动和修订记录必须一起提交）：
/// - `srv_rev`：每一行最后一次改动的修订号、是否已删除、当前指纹；
/// - `meta.srv_head_rev`：当前最大修订号。
/// 导出给设备的快照里两者都去掉（`exportSnapshot`）。
///
/// 冲突规则**不另写**：推送时把「客户端基线 / 客户端现状 / 服务器现状」交给离线镜像那份 `MirrorDiff.compute`，
/// 写入用 `MirrorApply.write`（删插顺序、孤儿行与唯一键冲突的处理都在那里）。三方里的 `source` 一律指服务器。
///
/// 一个工作区的所有读写串在一把锁里（SQLite 单写者）。
public final class HostedWorkspace: @unchecked Sendable {

    public let id: String
    let folder: URL
    let store: LibraryStore
    let paths: ServerPaths
    let lock = NSLock()
    /// 已关掉（工作区被删除时，`WorkspaceHost.delete`）。之后还拿着这个实例的请求一律当「没有这个工作区」，
    /// 别往已经挪进回收站的文件夹里写东西（`storePDF` 会重新建出 `PDFs/`，列表里就多出一个空壳）。
    private var closed = false

    static let metaHead = "srv_head_rev"

    static let revDDL = """
    CREATE TABLE IF NOT EXISTS srv_rev (
      tbl TEXT NOT NULL,
      row_id TEXT NOT NULL,
      rev INTEGER NOT NULL,
      deleted INTEGER NOT NULL DEFAULT 0,
      fp TEXT NOT NULL DEFAULT '',
      PRIMARY KEY (tbl, row_id)
    ) WITHOUT ROWID;
    CREATE INDEX IF NOT EXISTS idx_srv_rev_rev ON srv_rev(rev);
    """

    /// 设备本地的 meta 键：上传时从服务器那份里去掉（服务器用不上，导出给别的设备更不该带过去）。
    static let deviceLocalMeta = ["open_documents", MirrorStore.metaMirrorOf, MirrorStore.metaMirrorId,
                                  MirrorStore.metaMirrorCreatedAt, MirrorStore.metaMirrorSourceHint,
                                  MirrorStore.metaMirrorLastSyncedAt, MirrorStore.metaCheckouts]

    /// 删了会经外键连带删掉子行的父表（`reconcileCascades` 要补记那些子行）。
    static let parentTables: Set<String> = ["document", "board_note", "exercise"]

    init(folder: URL, paths: ServerPaths) throws {
        self.folder = folder
        self.paths = paths
        store = try LibraryStore(workspaceFolder: folder)
        guard let id = store.workspaceId else {
            store.close()
            throw ServerError.notAWorkspace
        }
        self.id = id
        try store.withMirrorDB { try $0.exec(Self.revDDL) }
    }

    public func close() {
        lock.lock(); defer { lock.unlock() }
        closed = true
        store.close()
    }

    /// 在锁里调：工作区已经关掉（被删除）就当它不存在。
    func checkOpen() throws {
        if closed { throw ServerError.unknownWorkspace(id) }
    }

    public var name: String {
        lock.lock(); defer { lock.unlock() }
        return store.workspaceName
    }

    public var head: UInt64 {
        lock.lock(); defer { lock.unlock() }
        return store.withMirrorDB { Self.head($0) }
    }

    // MARK: - 登记上传的工作区

    /// 把上传完整的工作区（`uploads/` 下的一个文件夹）登记成服务器工作区，挪进 `workspaces/<id>.unrd`。
    ///
    /// 只有库和文件全部到齐才调这里（方案 §5 第 3 步）：传一半不会出现残缺的服务器工作区。
    static func install(uploaded src: URL, paths: ServerPaths) throws -> HostedWorkspace {
        let lib = src.appendingPathComponent("UniReader/library.sqlite")
        guard FileManager.default.fileExists(atPath: lib.path) else { throw ServerError.notAWorkspace }
        // 先看版本再迁移：比服务器新的库，迁移代码不认识它的新列，打开它只会糟蹋它
        let peek = try SQLiteDB(path: lib.path)
        let raw = (try? peek.query("SELECT value FROM meta WHERE key='schema_version'"))?.first?["value"] as? String
        peek.close()
        guard let version = raw.flatMap({ Int($0) }) else { throw ServerError.notAWorkspace }
        guard version <= LibraryStore.schemaVersion else {
            throw ServerError.workspaceSchemaTooNew(workspace: version, server: LibraryStore.schemaVersion)
        }

        let store = try LibraryStore(workspaceFolder: src)
        let id: String
        do {
            id = try store.ensureWorkspaceId()
            guard !FileManager.default.fileExists(atPath: paths.workspaceFolder(id).path) else {
                throw ServerError.alreadyHosted(id)
            }
            try store.withMirrorDB { db in
                try db.exec(revDDL)
                try db.transaction {
                    for k in deviceLocalMeta { try db.run("DELETE FROM meta WHERE key=?", [.text(k)]) }
                    try db.exec("DROP TABLE IF EXISTS sync_base")
                    try normalizeLocations(db, folder: src)
                    try seedRevisions(db, folder: src)
                }
            }
            store.checkpointTruncate()
            store.close()
        } catch {
            store.close()
            throw error
        }
        try FileManager.default.createDirectory(at: paths.workspaces, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: src, to: paths.workspaceFolder(id))
        return try HostedWorkspace(folder: paths.workspaceFolder(id), paths: paths)
    }

    /// 服务器只认工作区里的文件（`in_workspace=1`、路径落在工作区内、文件在、**内容哈希对得上**）。
    /// 外部引用的路径是上传那台设备的本地事实，在服务器上毫无意义（离线镜像 §4：`location` 不同步）；
    /// 哈希对不上的（传坏了，或本地文件被原地改过）也不认——它不是这个 variant 的内容，留着只会把错的文件发给别的设备。
    /// 同一个文件只算一次哈希。返回去掉的条数。
    @discardableResult
    static func normalizeLocations(_ db: SQLiteDB, folder: URL) throws -> Int {
        var dropped = try db.query("SELECT COUNT(*) FROM location WHERE in_workspace=0", row: { Int($0.int64(0)) }).first ?? 0
        try db.run("DELETE FROM location WHERE in_workspace=0")
        var hashOf: [String: String] = [:]
        for row in try db.query("""
        SELECT l.id, l.path, v.content_hash FROM location l JOIN variant v ON v.id=l.variant_id
        """) {
            guard let lid = row["id"] as? String else { continue }
            var ok = false
            if let p = row["path"] as? String, let url = resolveInside(folder, p),
               FileManager.default.fileExists(atPath: url.path), let want = row["content_hash"] as? String {
                if hashOf[url.path] == nil { hashOf[url.path] = (try? ServerCrypto.sha256Hex(fileAt: url)) ?? "" }
                ok = hashOf[url.path] == want
            }
            if !ok {
                try db.run("DELETE FROM location WHERE id=?", [.text(lid)])
                dropped += 1
            }
        }
        return dropped
    }

    /// 给已有的每一行一个修订号（父表在前，同一表内按 id 排），head = 行数。
    /// 每行的修订号都不同：拉取按修订号分页，同号的行会在页边上漏掉。
    static func seedRevisions(_ db: SQLiteDB, folder: URL) throws {
        try db.run("DELETE FROM srv_rev")
        var rev: UInt64 = 0
        func put(_ table: String, _ rowId: String, _ fp: String) throws {
            rev += 1
            try db.run("INSERT INTO srv_rev(tbl,row_id,rev,deleted,fp) VALUES(?,?,?,0,?)",
                       [.text(table), .text(rowId), .int(Int64(rev)), .text(fp)])
        }
        for spec in MirrorFp.specs {
            for (rowId, fp) in try MirrorStore.fingerprints(db, spec).sorted(by: { $0.key < $1.key }) {
                try put(spec.table, rowId, fp)
            }
        }
        let channels = try SyncRows.channelState(db, folder: folder)
        for table in [SyncRows.ocrTable, SyncRows.imageTable, SyncRows.alignTable] {
            for (rowId, fp) in (channels[table] ?? [:]).sorted(by: { $0.key < $1.key }) { try put(table, rowId, fp) }
        }
        try setHead(db, rev)
    }

    // MARK: - 推送

    /// HTTP 层用的字节版本：请求体进、响应体出。
    public func push(body: Data, deviceName: String, now: Date = .now) throws -> Data {
        let req: SyncWire.PushRequest
        do { req = try SyncWire.decodePushRequest(body) } catch { throw ServerError.badRequest("\(error)") }
        return SyncWire.encode(try push(req, deviceName: deviceName, now: now))
    }

    func push(_ req: SyncWire.PushRequest, deviceName: String, now: Date = .now) throws -> SyncWire.PushResponse {
        guard req.schemaVersion == LibraryStore.schemaVersion else {
            throw ServerError.schemaMismatch(client: req.schemaVersion, server: LibraryStore.schemaVersion)
        }
        lock.lock(); defer { lock.unlock() }
        try checkOpen()
        return try store.withMirrorDB { db in try pushLocked(db, req, deviceName: deviceName, now: now) }
    }

    struct Key: Hashable { var table: String; var rowId: String }

    // swiftlint:disable:next function_body_length
    private func pushLocked(_ db: SQLiteDB, _ req: SyncWire.PushRequest,
                            deviceName: String, now: Date) throws -> SyncWire.PushResponse {
        // ① 整理：同一行推了两次以最后一次为准；不同步的表 / meta 里的本机键一律不收
        var order: [Key] = []
        var latest: [Key: SyncWire.RowChange] = [:]
        var outcomes: [Key: SyncWire.Outcome] = [:]
        for var c in req.changes {
            let k = Key(table: c.table, rowId: c.rowId)
            if latest[k] == nil, outcomes[k] == nil { order.append(k) }
            guard SyncRows.isSynced(table: c.table),
                  c.table != "meta" || MirrorFp.syncedMetaKeys.contains(c.rowId) else {
                outcomes[k] = .unchanged
                continue
            }
            // 行里的主键以 rowId 为准（防止一行里的 id 与它声称的不一致）
            if c.op == .upsert, var row = c.row, let spec = MirrorFp.spec(c.table) {
                row[spec.key] = .text(c.rowId)
                c.row = row
            }
            latest[k] = c
        }

        // ② 三方判定表：base = 客户端基线，mine = 客户端现状，theirs = 服务器现状
        let specKeys = order.filter { latest[$0] != nil && MirrorFp.spec($0.table) != nil }
        var base: MirrorDiff.Base = [:], mine: MirrorDiff.Snapshot = [:], theirs: MirrorDiff.Snapshot = [:]
        var idsByTable: [String: [String]] = [:]
        for k in specKeys {
            let c = latest[k]!
            idsByTable[k.table, default: []].append(k.rowId)
            if let b = c.baseFp { base[k.table, default: [:]][k.rowId] = b }
            if c.op == .upsert, let row = c.row { mine[k.table, default: [:]][k.rowId] = SyncWire.sqliteRow(row) }
        }
        for (table, ids) in idsByTable { theirs[table] = try SyncRows.fetch(db, spec: MirrorFp.spec(table)!, ids: ids) }
        let plan = MirrorDiff.compute(base: base, mine: mine, theirs: theirs)
        let toServer = plan.changes(to: .source)
        var planned: [Key: MirrorDiff.Change] = [:]
        for c in plan.changes { planned[Key(table: c.table, rowId: c.rowId)] = c }

        // ③ 先归档、再删除（红线⑪）：要删的行连同会被外键带走的子行，原样复制进回收站
        let deletes = toServer.filter { $0.op == .delete }
        if !deletes.isEmpty {
            try ServerTrash.archive(db, rows: deletes.map { ($0.table, $0.rowId) },
                                    folder: paths.trashFolder(id), device: deviceName, now: now)
        }

        // ④ 一个事务里写入 + 记修订号：前后指纹不同的行才记
        var head = Self.head(db)
        var after: [Key: [String: Any]] = [:]
        try db.transaction {
            var applied = MirrorApply.Result()
            try MirrorApply.write(db, toServer, result: &applied, side: .source)
            _ = try MirrorApply.writeLastOpened(db, plan.lastOpenedMerges)
            for k in specKeys {
                let before = SyncRows.fingerprint(table: k.table, row: theirs[k.table]?[k.rowId])
                let row = try SyncRows.fetch(db, table: k.table, rowId: k.rowId)
                after[k] = row
                let afterFp = SyncRows.fingerprint(table: k.table, row: row)
                if afterFp != before { try Self.bump(db, head: &head, table: k.table, rowId: k.rowId, fp: afterFp) }
            }
            if deletes.contains(where: { Self.parentTables.contains($0.table) }) {
                try Self.reconcileCascades(db, head: &head)
            }
            try Self.setHead(db, head)
        }

        var serverRowKeys: [Key] = []
        for k in specKeys {
            guard let c = planned[k] else { outcomes[k] = .unchanged; continue }
            if c.side == .mirror {
                outcomes[k] = .keptServer
                serverRowKeys.append(k)
                continue
            }
            let desired = c.op == .delete ? nil : SyncRows.fingerprint(table: k.table, row: c.row)
            outcomes[k] = SyncRows.fingerprint(table: k.table, row: after[k]) == desired
                ? .applied : Self.skipReason(db, table: k.table, row: c.row)
        }

        // ⑤ 通道表（OCR / 图片 / 扫描页对齐）：只补不删 / 按 updated_at 取新
        let channelKeys = order.filter { latest[$0] != nil && SyncRows.channelTables.contains($0.table) }
        if !channelKeys.isEmpty {
            try db.transaction {
                for k in channelKeys {
                    let (outcome, keptServer) = try pushChannel(db, latest[k]!, head: &head)
                    outcomes[k] = outcome
                    if keptServer { serverRowKeys.append(k) }
                }
                try Self.setHead(db, head)
            }
        }

        // ⑥ 新进来的 variant 若文件已经先传上来了，补上 location
        if toServer.contains(where: { $0.table == "variant" }) { try linkPDFFiles(db) }

        return SyncWire.PushResponse(
            head: head,
            results: order.map { k in
                SyncWire.RowResult(table: k.table, rowId: k.rowId, outcome: outcomes[k] ?? .unchanged,
                                   rev: Self.rev(db, k))
            },
            conflicts: plan.conflicts.map { c in
                SyncWire.Conflict(table: c.table, rowId: c.rowId,
                                  kind: { switch c.kind {
                                      case .bothModified: return .bothModified
                                      case .deleteVsEdit: return .deleteVsEdit
                                      case .bothAdded: return .bothAdded
                                  } }(),
                                  keptServer: c.kept == .source)
            },
            serverRows: try serverRowKeys.map { try Self.pulledRow(db, table: $0.table, rowId: $0.rowId, rev: Self.rev(db, $0)) })
    }

    /// 通道表的一行。返回（结果，是否要把服务器那份带回去）。
    private func pushChannel(_ db: SQLiteDB, _ c: SyncWire.RowChange,
                             head: inout UInt64) throws -> (SyncWire.Outcome, Bool) {
        // 通道表的删除不传播（一边清了缓存，另一边还留着；离线镜像 §4.1）
        guard c.op == .upsert, let wire = c.row else { return (.unchanged, false) }
        let row = SyncWire.sqliteRow(wire)
        guard SyncRows.channelRowId(table: c.table, row: row) == c.rowId else { return (.unchanged, false) }
        switch c.table {
        case SyncRows.ocrTable:
            guard try SyncRows.writeChannelRow(db, table: c.table, row: row, mode: .ignoreIfPresent) else {
                return (.unchanged, false)
            }
            try Self.bump(db, head: &head, table: c.table, rowId: c.rowId, fp: "")
            return (.applied, false)
        case SyncRows.imageTable:
            if try SyncRows.fetch(db, table: c.table, rowId: c.rowId) != nil { return (.unchanged, false) }
            guard let ext = row["ext"] as? String, ImageAssets.exists(in: folder, sha256: c.rowId, ext: ext) else {
                return (.missingFile, false)
            }
            try SyncRows.writeChannelRow(db, table: c.table, row: row, mode: .ignoreIfPresent)
            try Self.bump(db, head: &head, table: c.table, rowId: c.rowId, fp: "")
            return (.applied, false)
        case SyncRows.alignTable:
            let mineStamp = row["updated_at"] as? String ?? ""
            let cur = try SyncRows.fetch(db, table: c.table, rowId: c.rowId)?["updated_at"] as? String
            if let cur, cur == mineStamp { return (.unchanged, false) }
            if let cur, cur > mineStamp { return (.keptServer, true) }
            guard try SyncRows.writeChannelRow(db, table: c.table, row: row, mode: .replace) else {
                return (.unchanged, false)
            }
            try Self.bump(db, head: &head, table: c.table, rowId: c.rowId, fp: mineStamp)
            return (.applied, false)
        default:
            return (.unchanged, false)
        }
    }

    /// 计划写进服务器却没写成的一行：父行不在 = 孤儿；否则是唯一键撞了（同 `MirrorApply.write` 的两种跳过）。
    private static func skipReason(_ db: SQLiteDB, table: String, row: [String: Any]?) -> SyncWire.Outcome {
        guard let row else { return .skippedOrphan }
        func missing(_ parent: String, _ column: String) -> Bool {
            guard table != parent, let pid = row[column] as? String else { return false }
            return ((try? SyncRows.fetch(db, table: parent, rowId: pid)) ?? nil) == nil
        }
        if missing("document", "document_id") || missing("board_note", "board_id")
            || missing("exercise", "exercise_id") { return .skippedOrphan }
        return .skippedClash
    }

    // MARK: - 拉取

    /// HTTP 层用的字节版本。
    public func pull(since: UInt64, limit: Int = 5000) throws -> Data {
        SyncWire.encode(try pullRows(since: since, limit: limit))
    }

    /// 修订号大于 `since` 的行，按修订号升序，最多 `limit` 条。
    /// 客户端：`more` 为真时用最后一行的 `rev` 接着拉，否则记下 `head`。
    /// 🔴 一次拉取的**全部页攒齐再应用**（父行和子行可能分在不同页，见 `SyncClient.applyPulled`）。
    func pullRows(since: UInt64, limit: Int = 5000) throws -> SyncWire.PullResponse {
        lock.lock(); defer { lock.unlock() }
        try checkOpen()
        return try store.withMirrorDB { db in
            let head = Self.head(db)
            let entries = try db.query("SELECT tbl,row_id,rev,deleted FROM srv_rev WHERE rev>? ORDER BY rev LIMIT ?",
                                       [.int(Int64(clamping: since)), .int(Int64(max(1, limit) + 1))])
            let more = entries.count > max(1, limit)
            var rows: [SyncWire.PulledRow] = []
            for e in entries.prefix(max(1, limit)) {
                guard let t = e["tbl"] as? String, let rid = e["row_id"] as? String,
                      let rev = e["rev"] as? Int64 else { continue }
                if (e["deleted"] as? Int64 ?? 0) != 0 {
                    rows.append(SyncWire.PulledRow(table: t, rowId: rid, rev: UInt64(rev), deleted: true, row: nil))
                } else {
                    rows.append(try Self.pulledRow(db, table: t, rowId: rid, rev: UInt64(rev)))
                }
            }
            return SyncWire.PullResponse(head: head, more: more, rows: rows)
        }
    }

    static func pulledRow(_ db: SQLiteDB, table: String, rowId: String, rev: UInt64) throws -> SyncWire.PulledRow {
        guard let row = try SyncRows.fetch(db, table: table, rowId: rowId) else {
            return SyncWire.PulledRow(table: table, rowId: rowId, rev: rev, deleted: true, row: nil)
        }
        return SyncWire.PulledRow(table: table, rowId: rowId, rev: rev, deleted: false,
                                  row: SyncWire.row(fromSQLite: row))
    }

    // MARK: - 改名

    /// 改工作区的名字（App 启动页对着本机还没有副本的服务器工作区改名时用）。`meta.workspace_name` 是同步的 meta 键，
    /// 改了就记一个修订号，各设备下次拉取时拿到新名字（本机缓存的文件夹名不跟着变，用户看不到它）。返回当前修订号。
    @discardableResult
    public func rename(to newName: String) throws -> UInt64 {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw ServerError.badRequest("名字不能为空") }
        guard name.count <= 255 else { throw ServerError.badRequest("名字太长") }
        lock.lock(); defer { lock.unlock() }
        try checkOpen()
        return try store.withMirrorDB { db in
            var head = Self.head(db)
            let key = "workspace_name"
            try db.transaction {
                let before = SyncRows.fingerprint(table: "meta", row: try SyncRows.fetch(db, table: "meta", rowId: key))
                try db.run("INSERT INTO meta(key,value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",
                           [.text(key), .text(name)])
                let after = SyncRows.fingerprint(table: "meta", row: try SyncRows.fetch(db, table: "meta", rowId: key))
                guard after != before else { return }
                try Self.bump(db, head: &head, table: "meta", rowId: key, fp: after)
                try Self.setHead(db, head)
            }
            return head
        }
    }

    // MARK: - 快照

    /// 给新设备建缓存用的一致快照（不含服务器私有表），写到 [dst]（必须尚不存在）。返回快照对应的修订号。
    public func exportSnapshot(to dst: URL) throws -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        try checkOpen()
        let head = store.withMirrorDB { Self.head($0) }
        store.checkpointTruncate()
        try store.vacuumInto(dst.path)
        let copy = try SQLiteDB(path: dst.path)
        defer { copy.close() }
        try copy.exec("DROP TABLE IF EXISTS srv_rev")
        try copy.run("DELETE FROM meta WHERE key=?", [.text(Self.metaHead)])
        try copy.exec("PRAGMA journal_mode=DELETE")   // 交出去的是单个文件，不带 -wal / -shm
        return head
    }

    /// 给 HTTP 下载用的快照文件：`<数据目录>/snapshots/<id>/<修订号>.sqlite`。修订号没变就直接复用上一份，
    /// 不必每次都 `VACUUM INTO`。别的修订号的旧文件超过一小时才删（可能还有设备在下载它）。
    public func snapshotFile(now: Date = .now) throws -> (url: URL, rev: UInt64) {
        let fm = FileManager.default
        let dir = paths.snapshotFolder(id)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let current = head
        let existing = dir.appendingPathComponent("\(current).sqlite")
        if fm.fileExists(atPath: existing.path) { return (existing, current) }
        let tmp = dir.appendingPathComponent(".\(UUID().uuidString).part")
        let rev = try exportSnapshot(to: tmp)
        let dst = dir.appendingPathComponent("\(rev).sqlite")
        if fm.fileExists(atPath: dst.path) { try? fm.removeItem(at: tmp) } else { try fm.moveItem(at: tmp, to: dst) }
        for name in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] where name != dst.lastPathComponent {
            let url = dir.appendingPathComponent(name)
            let mtime = (try? fm.attributesOfItem(atPath: url.path)[.modificationDate] as? Date) ?? now
            if now.timeIntervalSince(mtime) > 3600 { try? fm.removeItem(at: url) }
        }
        return (dst, rev)
    }

    // MARK: - 修订号

    static func head(_ db: SQLiteDB) -> UInt64 {
        ((try? db.query("SELECT value FROM meta WHERE key=?", [.text(metaHead)]))?.first?["value"] as? String)
            .flatMap { UInt64($0) } ?? 0
    }

    static func setHead(_ db: SQLiteDB, _ v: UInt64) throws {
        try db.run("INSERT INTO meta(key,value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",
                   [.text(metaHead), .text(String(v))])
    }

    static func rev(_ db: SQLiteDB, _ k: Key) -> UInt64 {
        ((try? db.query("SELECT rev FROM srv_rev WHERE tbl=? AND row_id=?", [.text(k.table), .text(k.rowId)]))?
            .first?["rev"] as? Int64).map { UInt64($0) } ?? 0
    }

    /// 记一次改动：修订号 +1。`fp` 为 nil = 这一行没了。
    static func bump(_ db: SQLiteDB, head: inout UInt64, table: String, rowId: String, fp: String?) throws {
        head += 1
        try db.run("""
        INSERT INTO srv_rev(tbl,row_id,rev,deleted,fp) VALUES(?,?,?,?,?)
        ON CONFLICT(tbl,row_id) DO UPDATE SET rev=excluded.rev, deleted=excluded.deleted, fp=excluded.fp
        """, [.text(table), .text(rowId), .int(Int64(head)), .int(fp == nil ? 1 : 0), .text(fp ?? "")])
    }

    /// 父行被删时，外键（`ON DELETE CASCADE`）把子行一并删掉——这些子行没经过逐行比对，在这里补记成「已删除」，
    /// 否则别的设备永远不知道它们没了。
    static func reconcileCascades(_ db: SQLiteDB, head: inout UInt64) throws {
        for spec in MirrorFp.specs where spec.table != "meta" {
            let gone = try db.query("""
            SELECT r.row_id FROM srv_rev r WHERE r.tbl=? AND r.deleted=0
            AND NOT EXISTS (SELECT 1 FROM \(spec.table) t WHERE t.\(spec.key)=r.row_id)
            """, [.text(spec.table)], row: { $0.text(0) })
            for rowId in gone { try bump(db, head: &head, table: spec.table, rowId: rowId, fp: nil) }
        }
    }

    // MARK: - 路径

    /// 工作区内的相对路径 → 绝对路径；落到工作区外（`..`、符号链接）一律不认。
    static func resolveInside(_ folder: URL, _ rel: String) -> URL? {
        let base = folder.standardizedFileURL.resolvingSymlinksInPath().path
        let url = folder.appendingPathComponent(rel).standardizedFileURL.resolvingSymlinksInPath()
        return url.path.hasPrefix(base + "/") ? url : nil
    }
}
