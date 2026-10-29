import Foundation

/// 服务器的回收站：设备推来的删除，**先把要删的行原样复制出来，再删**（红线⑪，方案 `SERVER-MODE-PLAN.md §3.5`）。
///
/// 按天一个小库：`trash/<workspace_id>/<yyyy-MM-dd>.sqlite`，每张表与主库同列，另加两列
/// `srv_archived_at`（归档时间）/ `srv_device`（哪台设备删的）。同一行被归档多次就有多份（不设主键），
/// 找回时取最新的那份。整篇文档 / 画板 / 习题被删时，会被外键连带删掉的子行一并归档。
///
/// 与 Mac 回收站（`TrashStore`，一次删除一个快照库 + manifest）的区别：服务器上的删除来自同步，
/// 擦一笔就是一次删除，一次一个文件会堆出成千上万个小文件，所以按天合并。
enum ServerTrash {

    /// 父表 → 会被外键连带删掉的子表（列名是外键列）。
    static let children: [String: [(table: String, fk: String)]] = [
        "document": [("variant", "document_id"), ("ink_layer", "document_id"), ("scratch_pad", "document_id"),
                     ("note", "document_id"), ("exercise", "document_id")],
        "exercise": [("exercise_attempt", "exercise_id")],
        "board_note": [("board_page", "board_id"), ("board_item", "board_id")],
    ]

    static func dayFile(in folder: URL, now: Date) -> URL {
        folder.appendingPathComponent("\(ISO.string(now).prefix(10)).sqlite")
    }

    /// 把 [rows]（连同级联子行）复制进当天的回收站库。**必须在删除的事务之前调**：
    /// `ATTACH` 不能在事务里做；而且顺序就是「先归档、再删除」。
    static func archive(_ db: SQLiteDB, rows: [(table: String, id: String)],
                        folder: URL, device: String, now: Date) throws {
        guard !rows.isEmpty else { return }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        // 收集：表 → 要归档的 id（含级联子行）
        var targets: [String: Set<String>] = [:]
        func add(_ table: String, _ ids: [String]) throws {
            let fresh = Set(ids).subtracting(targets[table] ?? [])
            guard !fresh.isEmpty, MirrorFp.spec(table) != nil else { return }
            targets[table, default: []].formUnion(fresh)
            for (child, fk) in children[table] ?? [] {
                guard let cs = MirrorFp.spec(child) else { continue }
                var childIds: [String] = []
                for chunk in chunks(Array(fresh)) {
                    childIds += try db.query("SELECT \(cs.key) FROM \(child) WHERE \(fk) IN (\(marks(chunk.count)))",
                                             chunk.map { .text($0) }, row: { $0.text(0) })
                }
                try add(child, childIds)
            }
        }
        var byTable: [String: [String]] = [:]
        for (t, id) in rows { byTable[t, default: []].append(id) }
        for (t, ids) in byTable { try add(t, ids) }

        let file = dayFile(in: folder, now: now)
        let schema = "srvtrash"
        try db.run("ATTACH DATABASE ? AS \(schema)", [.text(file.path)])
        defer { try? db.run("DETACH DATABASE \(schema)") }
        let stamp = ISO.string(now)
        for (table, ids) in targets.sorted(by: { $0.key < $1.key }) {
            guard let spec = MirrorFp.spec(table) else { continue }
            let cols = try ensureTable(db, schema: schema, table: table)
            let list = cols.joined(separator: ",")
            for chunk in chunks(Array(ids).sorted()) {
                try db.run("""
                INSERT INTO \(schema).\(table)(\(list),srv_archived_at,srv_device)
                SELECT \(list),?,? FROM main.\(table) WHERE \(spec.key) IN (\(marks(chunk.count)))
                """, [.text(stamp), .text(device)] + chunk.map { .text($0) })
            }
        }
    }

    /// 回收站里这张表不在就照主库的列建；在但缺列（主库升级过）就补列。返回主库的列名。
    private static func ensureTable(_ db: SQLiteDB, schema: String, table: String) throws -> [String] {
        let mainCols = try db.query("PRAGMA main.table_info(\(table))").compactMap { $0["name"] as? String }
        let exists = !(try db.query("SELECT name FROM \(schema).sqlite_master WHERE type='table' AND name=?",
                                    [.text(table)]).isEmpty)
        if !exists {
            try db.exec("""
            CREATE TABLE \(schema).\(table) AS SELECT *, '' AS srv_archived_at, '' AS srv_device FROM main.\(table) WHERE 0
            """)
        } else {
            let have = Set(try db.query("PRAGMA \(schema).table_info(\(table))").compactMap { $0["name"] as? String })
            for c in mainCols where !have.contains(c) {
                try db.exec("ALTER TABLE \(schema).\(table) ADD COLUMN \(c)")
            }
        }
        return mainCols
    }

    /// 删掉 [keepDays] 天以前的回收站库。
    static func prune(folder: URL, keepDays: Int = 90, now: Date = .now) {
        let fm = FileManager.default
        let cutoff = String(ISO.string(now.addingTimeInterval(-Double(keepDays) * 86_400)).prefix(10))
        for name in (try? fm.contentsOfDirectory(atPath: folder.path)) ?? [] where name.hasSuffix(".sqlite") {
            let day = String(name.prefix(10))
            if day.count == 10, day < cutoff { try? fm.removeItem(at: folder.appendingPathComponent(name)) }
        }
    }

    private static func chunks(_ ids: [String], size: Int = 500) -> [[String]] {
        stride(from: 0, to: ids.count, by: size).map { Array(ids[$0..<min($0 + size, ids.count)]) }
    }

    private static func marks(_ n: Int) -> String { Array(repeating: "?", count: n).joined(separator: ",") }
}
