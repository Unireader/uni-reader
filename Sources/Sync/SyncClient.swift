import Foundation

/// 客户端这一侧的同步算法（方案 `SERVER-MODE-PLAN.md §4.2`）：找本地改动、处理推送结果、应用拉下来的行。
///
/// 只碰一个工作区库（`SQLiteDB`）和它的文件夹。网络、文件上传下载、界面、打开着的文档（§6）都不在这里。
/// 基线沿用离线镜像那张 `sync_base`（客户端私有，不进跨端 schema），通道表也记在里面：
/// OCR / 图片的基线指纹恒为空串（= 服务器已经有了），扫描页对齐 = `updated_at`。
///
/// 冲突规则不另写：应用拉下来的行时同样交给 `MirrorDiff.compute`（`source` = 服务器，`mirror` = 本机）。
///
/// 🔴 基线**按行**更新：只有某一行本地与服务器一致了（或冲突规则判本机赢、等着推上去），才改这一行的基线。
/// 本机没写成的行（父行不在被跳过）基线不动——否则下一轮会把「本机没有」误判成「本机删了」，推一条删除上去。
enum SyncClient {

    /// 上次拉到的修订号（客户端私有的 meta 键，不在同步白名单里）。
    static let metaPulledRev = "srv_pulled_rev"

    struct Key: Hashable { var table: String; var rowId: String }

    // MARK: - 基线

    /// 把基线设成「此刻与服务器一致」：建缓存之后、上传完成之后各调一次。
    static func resetBase(_ db: SQLiteDB, folder: URL, pulledRev: UInt64) throws {
        try db.exec(MirrorStore.syncBaseDDL)
        let spec = try SyncRows.specState(db)
        let channels = try SyncRows.channelState(db, folder: folder)
        try db.transaction {
            try db.run("DELETE FROM sync_base")
            for (table, fps) in spec.merging(channels, uniquingKeysWith: { a, _ in a }) {
                for (rowId, fp) in fps {
                    try db.run("INSERT INTO sync_base(tbl,row_id,fp) VALUES(?,?,?)",
                               [.text(table), .text(rowId), .text(fp)])
                }
            }
            try setPulledRev(db, pulledRev)
        }
    }

    static func pulledRev(_ db: SQLiteDB) -> UInt64 {
        ((try? db.query("SELECT value FROM meta WHERE key=?", [.text(metaPulledRev)]))?.first?["value"] as? String)
            .flatMap { UInt64($0) } ?? 0
    }

    static func setPulledRev(_ db: SQLiteDB, _ v: UInt64) throws {
        try db.run("INSERT INTO meta(key,value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",
                   [.text(metaPulledRev), .text(String(v))])
    }

    static func setBase(_ db: SQLiteDB, _ k: Key, _ fp: String?) throws {
        if let fp {
            try db.run("""
            INSERT INTO sync_base(tbl,row_id,fp) VALUES(?,?,?) ON CONFLICT(tbl,row_id) DO UPDATE SET fp=excluded.fp
            """, [.text(k.table), .text(k.rowId), .text(fp)])
        } else {
            try db.run("DELETE FROM sync_base WHERE tbl=? AND row_id=?", [.text(k.table), .text(k.rowId)])
        }
    }

    // MARK: - 本地改动

    /// 当前 vs 基线：三方判定表的增删改，加上通道表里服务器还没有的（或对齐参数变了的）。
    /// 通道表本地删掉的不推（删除不传播）。
    static func localChanges(_ db: SQLiteDB, folder: URL) throws -> [SyncWire.RowChange] {
        let base = try MirrorStore.syncBase(db)
        var out: [SyncWire.RowChange] = []
        for spec in MirrorFp.specs {
            let cur = try MirrorStore.fingerprints(db, spec)
            let b = base[spec.table] ?? [:]
            let changed = Set(cur.keys).union(b.keys).filter { cur[$0] != b[$0] }.sorted()
            guard !changed.isEmpty else { continue }
            let rows = try SyncRows.fetch(db, spec: spec, ids: changed.filter { cur[$0] != nil })
            for id in changed {
                if let row = rows[id] {
                    out.append(SyncWire.RowChange(table: spec.table, rowId: id, op: .upsert, baseFp: b[id],
                                                  row: SyncWire.row(fromSQLite: row)))
                } else {
                    out.append(SyncWire.RowChange(table: spec.table, rowId: id, op: .delete, baseFp: b[id], row: nil))
                }
            }
        }
        let channels = try SyncRows.channelState(db, folder: folder)
        for table in [SyncRows.ocrTable, SyncRows.imageTable, SyncRows.alignTable] {
            for (id, fp) in (channels[table] ?? [:]).sorted(by: { $0.key < $1.key }) where base[table]?[id] != fp {
                guard let row = try SyncRows.fetch(db, table: table, rowId: id) else { continue }
                out.append(SyncWire.RowChange(table: table, rowId: id, op: .upsert, baseFp: base[table]?[id],
                                              row: SyncWire.row(fromSQLite: row)))
            }
        }
        return out
    }

    // MARK: - 推送结果

    /// 服务器收下的（或本来就一致的）行：基线改成**推上去的样子**（不是本地此刻的样子——推送期间本地可能又改了，
    /// 那样下一轮会照常再推）。服务器保留自己那份的，按拉下来的行处理（`response.serverRows`）。
    @discardableResult
    static func applyPushResponse(_ db: SQLiteDB, folder: URL, pushed: [SyncWire.RowChange],
                                  response: SyncWire.PushResponse) throws -> PullReport {
        var byKey: [Key: SyncWire.RowChange] = [:]
        for c in pushed { byKey[Key(table: c.table, rowId: c.rowId)] = c }
        try db.transaction {
            for r in response.results {
                let k = Key(table: r.table, rowId: r.rowId)
                guard let c = byKey[k], SyncRows.isSynced(table: c.table) else { continue }
                switch r.outcome {
                case .applied, .unchanged:
                    let fp = c.op == .delete ? nil
                        : SyncRows.fingerprint(table: c.table, row: c.row.map(SyncWire.sqliteRow))
                    try setBase(db, k, fp)
                case .keptServer, .skippedOrphan, .skippedClash, .missingFile:
                    break
                }
            }
        }
        return try applyPulled(db, folder: folder, rows: response.serverRows)
    }

    // MARK: - 拉下来的行

    struct PullReport: Equatable {
        /// 本机有没推上去的改动、服务器又改了同一行：按冲突规则处理掉的条数。
        var conflicts = 0
        /// 父行不在、没写成的行（基线没动，下一轮再说）。
        var skipped = 0
    }

    /// 应用拉下来的行。🔴 一次拉取的**全部页攒齐了再调**：父行和子行可能分在不同页（父行后来又改过，
    /// 修订号比子行大），分批写会把子行当孤儿丢掉。
    @discardableResult
    static func applyPulled(_ db: SQLiteDB, folder: URL, rows: [SyncWire.PulledRow]) throws -> PullReport {
        guard !rows.isEmpty else { return PullReport() }
        var latest: [Key: SyncWire.PulledRow] = [:]
        for r in rows {
            let k = Key(table: r.table, rowId: r.rowId)
            if latest[k].map({ $0.rev <= r.rev }) ?? true { latest[k] = r }
        }
        let base = try MirrorStore.syncBase(db)

        // 三方判定表：base = 本机基线，mine = 本机现状，theirs = 服务器
        var b: MirrorDiff.Base = [:], mine: MirrorDiff.Snapshot = [:], theirs: MirrorDiff.Snapshot = [:]
        var idsByTable: [String: [String]] = [:]
        for (k, r) in latest where MirrorFp.spec(k.table) != nil {
            if k.table == "meta", !MirrorFp.syncedMetaKeys.contains(k.rowId) { continue }
            idsByTable[k.table, default: []].append(k.rowId)
            if let fp = base[k.table]?[k.rowId] { b[k.table, default: [:]][k.rowId] = fp }
            if !r.deleted, let row = r.row { theirs[k.table, default: [:]][k.rowId] = SyncWire.sqliteRow(row) }
        }
        for (table, ids) in idsByTable { mine[table] = try SyncRows.fetch(db, spec: MirrorFp.spec(table)!, ids: ids) }
        let plan = MirrorDiff.compute(base: b, mine: mine, theirs: theirs)
        let localWins = Set(plan.changes(to: .source).map { Key(table: $0.table, rowId: $0.rowId) })

        var report = PullReport(conflicts: plan.conflicts.count)
        try db.transaction {
            var applied = MirrorApply.Result()
            try MirrorApply.write(db, plan.changes(to: .mirror), result: &applied, side: .mirror)
            _ = try MirrorApply.writeLastOpened(db, plan.lastOpenedMerges)
            for (table, ids) in idsByTable {
                for id in ids {
                    let k = Key(table: table, rowId: id)
                    let r = latest[k]!
                    let serverFp = r.deleted ? nil : SyncRows.fingerprint(table: table, row: r.row.map(SyncWire.sqliteRow))
                    let localFp = SyncRows.fingerprint(table: table, row: try SyncRows.fetch(db, table: table, rowId: id))
                    if localFp == serverFp || localWins.contains(k) {
                        try setBase(db, k, serverFp)
                    } else {
                        report.skipped += 1
                    }
                }
            }
            // 通道表
            for (k, r) in latest where SyncRows.channelTables.contains(k.table) {
                guard !r.deleted, let wire = r.row else { continue }   // 通道表的删除不传播
                let row = SyncWire.sqliteRow(wire)
                switch k.table {
                case SyncRows.alignTable:
                    let server = row["updated_at"] as? String ?? ""
                    let local = try SyncRows.fetch(db, table: k.table, rowId: k.rowId)?["updated_at"] as? String
                    if local == nil || server > local! {
                        try SyncRows.writeChannelRow(db, table: k.table, row: row, mode: .replace)
                    }
                    try setBase(db, k, server)   // 本机更新的话基线 ≠ 本机，下一轮推上去
                default:
                    try SyncRows.writeChannelRow(db, table: k.table, row: row, mode: .ignoreIfPresent)
                    try setBase(db, k, "")
                }
            }
        }
        return report
    }

    // MARK: - 一轮

    struct RoundReport: Equatable {
        var pushed = 0
        var pulled = 0
        var push = SyncWire.PushResponse(head: 0, results: [], conflicts: [])
        var pull = PullReport()
    }

    /// 一轮同步：推本地改动 → 拉服务器的改动（全部页攒齐）→ 应用 → 记下拉到的修订号。
    /// 传输由调用方给（HTTP / 测试里直接调服务器）。
    static func round(_ db: SQLiteDB, folder: URL, schemaVersion: Int = LibraryStore.schemaVersion,
                      push: (SyncWire.PushRequest) throws -> SyncWire.PushResponse,
                      pull: (UInt64) throws -> SyncWire.PullResponse) throws -> RoundReport {
        var rep = RoundReport()
        let changes = try localChanges(db, folder: folder)
        if !changes.isEmpty {
            let resp = try push(SyncWire.PushRequest(schemaVersion: schemaVersion, changes: changes))
            try applyPushResponse(db, folder: folder, pushed: changes, response: resp)
            rep.pushed = changes.count
            rep.push = resp
        }
        var since = pulledRev(db)
        var acc: [SyncWire.PulledRow] = []
        while true {
            let page = try pull(since)
            acc += page.rows
            if page.more, let last = page.rows.last { since = last.rev } else { since = max(since, page.head); break }
        }
        rep.pull = try applyPulled(db, folder: folder, rows: acc)
        rep.pulled = acc.count
        try setPulledRev(db, since)
        return rep
    }
}
