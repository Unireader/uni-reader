import Foundation

/// 回收站的 SQLite 一侧（方案 `BACKUP-PLAN.md §2`）：把「要删掉的那些行」原样搬进一个独立的小库，
/// 以及把它们搬回来。
///
/// 🔴 **schema 一个字都不改**（仍是 v15）。删除对三端（Mac / 安卓模式1 / 离线镜像）来说和今天完全一样
/// ——硬删、照常传播；回收站纯粹是 Mac 端在删之前多存了一份快照文件。理由见方案 §2.1：`document`/`note`
/// 是跨端契约，往里加一个「已删除」状态列，等于要求安卓的 `Schema.kt`、`MirrorDiff` 的判定表、
/// 以及主库里每一处查询同步跟上，漏一处就是「已删的文档又冒出来」。
///
/// 本文件的定位同 `MirrorStore`：`LibraryStore` 那条「所有读写走 DAO」的约定在这里开一条**窄口子**，
/// 因为搬运要对**整张表**做按列通用的复制（列由 `PRAGMA table_info` 现取），给它写一套逐字段 DAO
/// 等于把这个文件抄进 `LibraryStore`。入口只有 `LibraryStore` 上那三个方法，别从别处拿连接。
enum TrashStore {

    // MARK: - 常量

    /// 文档级快照要搬的表，**顺序就是恢复时的写入顺序**——外键（`foreign_keys=ON`）要求
    /// 父行先就位：note / ink_layer / scratch_pad 都 `REFERENCES document(id)`，
    /// location 则 `REFERENCES variant(id)`。
    static let documentTables = ["document", "variant", "location", "ink_layer", "scratch_pad", "note"]
    /// 画板笔记条目（v16）要搬的表，同样父表在前（`board_item REFERENCES board_note(id)`）。
    static let boardTables = ["board_note", "board_page", "board_item"]

    /// 页内笔迹的 note.kind（与 `InkStroke.noteKind` 同值，这里不引 App 层的类型）。
    private static let inkKind = 2

    // MARK: - 统计（写进 manifest 的那几个数）

    struct Counts: Codable, Equatable {
        var ink = 0          // 页内笔迹 kind=2
        var text = 0         // 文字笔记 kind=0
        var highlight = 0    // 高亮 kind=3
        var bookmark = 0     // 书签 kind=5
        var image = 0        // 图片笔记 kind=6
        var aiThread = 0     // AI 会话绑定 kind=1
        var scratchInk = 0   // 草稿纸笔迹 kind=4
        var inkLayer = 0
        var scratchPad = 0
        /// 画板笔记上的笔迹 / 图（v16，`board_item` kind 1 / 2）。
        var boardInk = 0
        var boardImage = 0

        /// 「一共多少条会跟着一起没」——确认框里那个数。
        var total: Int { ink + text + highlight + bookmark + image + aiThread + scratchInk + boardInk + boardImage }

        init() {}
        /// 老条目的 manifest 没有新加的键：逐个 `decodeIfPresent`，缺了就是 0（读不出来的条目会凭空消失）。
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            func v(_ k: CodingKeys) -> Int { (try? c.decodeIfPresent(Int.self, forKey: k)) ?? 0 }
            ink = v(.ink); text = v(.text); highlight = v(.highlight); bookmark = v(.bookmark)
            image = v(.image); aiThread = v(.aiThread); scratchInk = v(.scratchInk)
            inkLayer = v(.inkLayer); scratchPad = v(.scratchPad)
            boardInk = v(.boardInk); boardImage = v(.boardImage)
        }
    }

    /// 归档的产物：写进 manifest 的那几样。
    struct Archived {
        var counts = Counts()
        /// 这些行引用到的图片本体（`Images/<sha256>`）。清理图片时要护住它们（方案 §2.6）。
        var images: [String] = []
        /// 这篇文档各版本的内容 hash —— 恢复时靠它认出「这份 PDF 是不是又被导入过」（方案 §2.5）。
        var contentHashes: [String] = []
        var pageCount = 0
    }

    // MARK: - 归档

    /// 把一篇文档的全部行搬进 [path] 处的新快照库（文件**必须尚不存在**）。
    ///
    /// 🔴 调用方必须「**先归档成功、再删除**」。反过来做，中间任何一步失败都等于数据已经没了。
    static func archiveDocument(_ db: SQLiteDB, documentId: String, to path: String) throws -> Archived {
        try withAttached(db, path: path) { t in
            try db.run("CREATE TABLE \(t).document AS SELECT * FROM main.document WHERE id=?", [.text(documentId)])
            try db.run("""
            CREATE TABLE \(t).variant AS SELECT * FROM main.variant WHERE document_id=?
            """, [.text(documentId)])
            try db.run("""
            CREATE TABLE \(t).location AS SELECT * FROM main.location
            WHERE variant_id IN (SELECT id FROM main.variant WHERE document_id=?)
            """, [.text(documentId)])
            try db.run("CREATE TABLE \(t).ink_layer AS SELECT * FROM main.ink_layer WHERE document_id=?",
                       [.text(documentId)])
            try db.run("CREATE TABLE \(t).scratch_pad AS SELECT * FROM main.scratch_pad WHERE document_id=?",
                       [.text(documentId)])
            try db.run("CREATE TABLE \(t).note AS SELECT * FROM main.note WHERE document_id=?",
                       [.text(documentId)])
            return try summarize(db, schema: t)
        }
    }

    /// 把一个笔迹图层连同它那些笔画搬进快照库。
    ///
    /// `isDefaultLayer` 时把 payload 里**没有** `layerId` 键的老行一并算进去 ——
    /// 与 `LibraryStore.deleteInkStrokes` 必须是同一套判定，否则「删掉的」和「存下来的」对不上。
    static func archiveInkLayer(_ db: SQLiteDB, documentId: String, layerId: String,
                                isDefaultLayer: Bool, to path: String) throws -> Archived {
        let cond = isDefaultLayer
            ? "(json_extract(payload, '$.layerId') = ? COLLATE NOCASE OR json_extract(payload, '$.layerId') IS NULL)"
            : "json_extract(payload, '$.layerId') = ? COLLATE NOCASE"
        return try withAttached(db, path: path) { t in
            try db.run("CREATE TABLE \(t).ink_layer AS SELECT * FROM main.ink_layer WHERE id=?", [.text(layerId)])
            try db.run("""
            CREATE TABLE \(t).note AS SELECT * FROM main.note
            WHERE document_id=? AND kind=? AND \(cond)
            """, [.text(documentId), .int(Int64(inkKind)), .text(layerId)])
            return try summarize(db, schema: t)
        }
    }

    /// 把一篇画板笔记（那一行 + 上面的全部条目）搬进快照库。
    static func archiveBoard(_ db: SQLiteDB, boardId: String, to path: String) throws -> Archived {
        try withAttached(db, path: path) { t in
            try db.run("CREATE TABLE \(t).board_note AS SELECT * FROM main.board_note WHERE id=?", [.text(boardId)])
            try db.run("CREATE TABLE \(t).board_page AS SELECT * FROM main.board_page WHERE board_id=?", [.text(boardId)])
            try db.run("CREATE TABLE \(t).board_item AS SELECT * FROM main.board_item WHERE board_id=?", [.text(boardId)])
            return try summarize(db, schema: t)
        }
    }

    // MARK: - 恢复

    /// 恢复前的探路：这份快照里的 PDF **是不是已经被重新导入过**（方案 §2.5 的情形 B）。
    ///
    /// 返回主库里占着同一个 `content_hash` 的那篇文档 id（并入目标）；没有就是 nil（照常整份放回）。
    /// 快照里没有 `variant` 表（图层级条目）时也返回 nil。
    static func mergeTarget(_ db: SQLiteDB, snapshot path: String) throws -> String? {
        try withAttached(db, path: path, create: false) { t in
            let tables = try tableNames(db, schema: t)
            guard tables.contains("variant"), tables.contains("document") else { return nil }
            let own = try db.query("SELECT id FROM \(t).document", row: { $0.text(0) }).first ?? ""
            let hashes = try db.query("SELECT content_hash FROM \(t).variant", row: { $0.text(0) })
            for h in hashes {
                let hit = try db.query("SELECT document_id FROM main.variant WHERE content_hash=?",
                                       [.text(h)], row: { $0.text(0) }).first
                if let hit, hit != own { return hit }
            }
            return nil
        }
    }

    /// 把快照写回主库。返回搬运的行数（= 快照里那几张表的行数之和；冲突被忽略的那几行也算在内，
    /// 这个数只给日志和「恢复了 N 条」的提示用，不做判定）。
    ///
    /// - `remapDocumentId` 非 nil = 方案 §2.5 的情形 B「并入现有那篇」：所有行的 `document_id`
    ///   改写成它，且 `document` / `variant` / `location` 三张表**整个跳过**
    ///   （现有那篇的标题、阅读进度、分组都保留；`variant.content_hash` 有 UNIQUE 约束，照搬必撞）。
    ///
    /// 冲突策略分两档，都不是洁癖：
    /// - `document` / `variant` 用 **OR IGNORE** —— 它们有 `ON DELETE CASCADE` 的子表，而
    ///   `INSERT OR REPLACE` 实际是「先 DELETE 再 INSERT」，一次 REPLACE 就会把刚放回去的
    ///   note / location 连根删掉。已经存在就保留现状。
    /// - `location` / `ink_layer` / `scratch_pad` / `note` 用 **OR REPLACE** —— 它们没有子表，
    ///   重复恢复是幂等的。
    @discardableResult
    static func restore(_ db: SQLiteDB, snapshot path: String, remapDocumentId: String?) throws -> Int {
        try withAttached(db, path: path, create: false) { t in
            let present = try tableNames(db, schema: t)
            var written = 0
            try db.transaction {
                for table in documentTables + boardTables where present.contains(table) {
                    if remapDocumentId != nil, ["document", "variant", "location"].contains(table) { continue }
                    let cols = try columnNames(db, schema: t, table: table)
                    guard !cols.isEmpty else { continue }
                    // board_note 同 document：有 CASCADE 子表（board_item），REPLACE 会把子行连根删掉
                    let conflict = ["document", "variant", "board_note"].contains(table) ? "OR IGNORE" : "OR REPLACE"
                    let select = cols.map { $0 == "document_id" && remapDocumentId != nil ? "?" : "\"\($0)\"" }
                    let names = cols.map { "\"\($0)\"" }.joined(separator: ",")
                    let params: [SQLiteDB.Value] = remapDocumentId.map { id in
                        cols.contains("document_id") ? [.text(id)] : []
                    } ?? []
                    try db.run("""
                    INSERT \(conflict) INTO main."\(table)"(\(names))
                    SELECT \(select.joined(separator: ",")) FROM \(t)."\(table)"
                    """, params)
                    written += try count(db, schema: t, table: table)
                }
            }
            return written
        }
    }

    // MARK: - 读快照（面板显示用；manifest 丢了也能重建摘要）

    /// 快照里的统计与引用。`mergeTarget` 之外唯一会去读快照内容的地方。
    static func summary(_ db: SQLiteDB, snapshot path: String) throws -> Archived {
        try withAttached(db, path: path, create: false) { t in try summarize(db, schema: t) }
    }

    // MARK: - 私有

    /// `ATTACH` → 干活 → `DETACH`。
    ///
    /// 归档失败时把那个**刚建出来的**半截文件清掉：留一个空壳在回收站里，界面会把它列成一条
    /// 「什么都没有」的条目，比没建成更难查。
    ///
    /// 🔴 **只清自己建的那一份**（`create` 且 ATTACH 之前它还不存在）。ATTACH 一个已有的库是成功的，
    /// 真正失败的是随后那句 `CREATE TABLE`（表已存在）——那时候把文件删掉，就是「归档失败」顺手
    /// 毁掉了一份已经存在的快照。这个类里但凡有一处会删已有的快照，它就不配叫回收站。
    private static func withAttached<T>(_ db: SQLiteDB, path: String, create: Bool = true,
                                        _ body: (String) throws -> T) throws -> T {
        let mine = create && !FileManager.default.fileExists(atPath: path)
        let schema = "trash_\(UInt32.random(in: 0...UInt32.max))"
        try db.run("ATTACH DATABASE ? AS \(schema)", [.text(path)])
        do {
            let out = try body(schema)
            try? db.run("DETACH DATABASE \(schema)")
            return out
        } catch {
            try? db.run("DETACH DATABASE \(schema)")
            if mine { try? FileManager.default.removeItem(atPath: path) }
            throw error
        }
    }

    private static func tableNames(_ db: SQLiteDB, schema: String) throws -> Set<String> {
        Set(try db.query("SELECT name FROM \(schema).sqlite_master WHERE type='table'", row: { $0.text(0) }))
    }

    private static func columnNames(_ db: SQLiteDB, schema: String, table: String) throws -> [String] {
        try db.query("PRAGMA \(schema).table_info(\"\(table)\")").compactMap { $0["name"] as? String }
    }

    private static func count(_ db: SQLiteDB, schema: String, table: String) throws -> Int {
        try db.query("SELECT COUNT(*) FROM \(schema).\"\(table)\"", row: { Int($0.int64(0)) }).first ?? 0
    }

    /// 数快照里有什么。表缺了就算 0（图层级条目只有 ink_layer + note）。
    private static func summarize(_ db: SQLiteDB, schema t: String) throws -> Archived {
        var out = Archived()
        let present = try tableNames(db, schema: t)
        if present.contains("note") {
            for (kind, n) in try db.query("SELECT kind, COUNT(*) FROM \(t).note GROUP BY kind",
                                          row: { r in (Int(r.int64(0)), Int(r.int64(1))) }) {
                switch kind {
                case 0: out.counts.text = n
                case 1: out.counts.aiThread = n
                case 2: out.counts.ink = n
                case 3: out.counts.highlight = n
                case 4: out.counts.scratchInk = n
                case 5: out.counts.bookmark = n
                case 6: out.counts.image = n
                default: break
                }
            }
            out.images = try db.query("""
            SELECT DISTINCT json_extract(payload, '$.image') FROM \(t).note WHERE kind=6
            """, row: { $0.text(0) }).filter { !$0.isEmpty }.sorted()
        }
        if present.contains("board_item") {
            for (kind, n) in try db.query("SELECT kind, COUNT(*) FROM \(t).board_item GROUP BY kind",
                                          row: { r in (Int(r.int64(0)), Int(r.int64(1))) }) {
                if kind == 1 { out.counts.boardInk = n } else if kind == 2 { out.counts.boardImage = n }
            }
            let imgs = try db.query("""
            SELECT DISTINCT json_extract(payload, '$.image') FROM \(t).board_item WHERE kind=2
            """, row: { $0.text(0) }).filter { !$0.isEmpty }
            out.images = Array(Set(out.images + imgs)).sorted()
        }
        if present.contains("ink_layer") { out.counts.inkLayer = try count(db, schema: t, table: "ink_layer") }
        if present.contains("scratch_pad") { out.counts.scratchPad = try count(db, schema: t, table: "scratch_pad") }
        if present.contains("variant") {
            out.contentHashes = try db.query("SELECT content_hash FROM \(t).variant", row: { $0.text(0) }).sorted()
        }
        if present.contains("document") {
            out.pageCount = try db.query("SELECT page_count FROM \(t).document",
                                         row: { Int($0.int64(0)) }).first ?? 0
        }
        return out
    }
}
