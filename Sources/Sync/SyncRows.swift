import Foundation

/// 同步里「一行」的定位、读取、指纹与写入：服务器与客户端共用（方案 `SERVER-MODE-PLAN.md §4.1`）。
///
/// 两类表：
/// - **三方判定的表** = `MirrorFp.specs`（单列 TEXT 主键，冲突规则见 `MirrorDiff`）。
/// - **通道表** = `ocr_page` / `image` / `page_align`，与离线镜像同一套规则（`OFFLINE-MIRROR-PLAN.md §4.1 / §4.2`）：
///   OCR 与图片只补不删，扫描页对齐按 `updated_at` 取新。它们的「指纹」是：OCR / 图片恒为空串（有就行），
///   对齐 = `updated_at`。
///
/// 同 `SyncWire`：App 与服务器都编译本文件，只许依赖 Foundation 与 Store 层。
enum SyncRows {

    static let ocrTable = "ocr_page"
    static let imageTable = "image"
    static let alignTable = "page_align"
    static let channelTables: Set<String> = [ocrTable, imageTable, alignTable]

    static func isSynced(table: String) -> Bool { MirrorFp.spec(table) != nil || channelTables.contains(table) }

    // MARK: - OCR 的复合主键

    private static let sep: Character = "\u{1F}"

    /// `ocr_page` 是三列复合主键，同步里用一个串当行 id：`content_hash␟page␟provider`（0x1F 分隔）。
    static func ocrRowId(_ k: MirrorDiff.OCRKey) -> String { "\(k.contentHash)\(sep)\(k.page)\(sep)\(k.provider)" }

    static func ocrKey(rowId: String) -> MirrorDiff.OCRKey? {
        let parts = rowId.split(separator: sep, omittingEmptySubsequences: false)
        guard parts.count == 3, let page = Int(parts[1]) else { return nil }
        return MirrorDiff.OCRKey(contentHash: String(parts[0]), page: page, provider: String(parts[2]))
    }

    // MARK: - 读

    /// 读一行当前的内容；不在 = nil。`meta` 只认同步白名单里的键（其余键是本机状态，不同步）。
    static func fetch(_ db: SQLiteDB, table: String, rowId: String) throws -> [String: Any]? {
        if let spec = MirrorFp.spec(table) {
            if table == "meta", !MirrorFp.syncedMetaKeys.contains(rowId) { return nil }
            return try db.query("SELECT * FROM \(table) WHERE \(spec.key)=?", [.text(rowId)]).first
        }
        switch table {
        case ocrTable:
            guard let k = ocrKey(rowId: rowId) else { return nil }
            return try db.query("SELECT * FROM ocr_page WHERE content_hash=? AND page=? AND provider=?",
                                [.text(k.contentHash), .int(Int64(k.page)), .text(k.provider)]).first
        case imageTable:
            return try db.query("SELECT * FROM image WHERE sha256=?", [.text(rowId)]).first
        case alignTable:
            guard try hasTable(db, alignTable) else { return nil }
            return try db.query("SELECT * FROM page_align WHERE content_hash=?", [.text(rowId)]).first
        default:
            return nil
        }
    }

    /// 批量读一张三方判定表里的若干行：`row_id → 行`。
    static func fetch(_ db: SQLiteDB, spec: MirrorFp.TableSpec, ids: [String]) throws -> [String: [String: Any]] {
        var out: [String: [String: Any]] = [:]
        var wanted = ids
        if spec.table == "meta" { wanted = wanted.filter(MirrorFp.syncedMetaKeys.contains) }
        var i = 0
        while i < wanted.count {
            let chunk = Array(wanted[i..<min(i + 500, wanted.count)])
            let marks = Array(repeating: "?", count: chunk.count).joined(separator: ",")
            for row in try db.query("SELECT * FROM \(spec.table) WHERE \(spec.key) IN (\(marks))",
                                    chunk.map { .text($0) }) {
                guard case .text(let id) = MirrorFp.coerce(row[spec.key], as: .text) else { continue }
                out[id] = row
            }
            i += 500
        }
        return out
    }

    /// 一行的指纹（行不在 = nil）。三方判定表 = `MirrorFp`；OCR / 图片 = 空串；扫描页对齐 = `updated_at`。
    static func fingerprint(table: String, row: [String: Any]?) -> String? {
        guard let row else { return nil }
        if let spec = MirrorFp.spec(table) { return MirrorFp.fingerprint(row: row, spec: spec) }
        if table == alignTable { return row["updated_at"] as? String ?? "" }
        return ""
    }

    /// 通道表当前的全部键 → 指纹：`表名 → (row_id → fp)`。
    /// 图片只算**真拿得出来**的（行在且文件在，见 `MirrorStore.imageKeys`）。
    static func channelState(_ db: SQLiteDB, folder: URL) throws -> [String: [String: String]] {
        var out: [String: [String: String]] = [:]
        out[ocrTable] = Dictionary(uniqueKeysWithValues: try MirrorStore.ocrKeys(db).map { (ocrRowId($0), "") })
        out[imageTable] = Dictionary(uniqueKeysWithValues: try MirrorStore.imageKeys(db, folder: folder).map { ($0, "") })
        out[alignTable] = try MirrorStore.alignStamps(db)
        return out
    }

    /// 三方判定表当前的全部行指纹：`表名 → (row_id → fp)`（`meta` 只取白名单键）。
    static func specState(_ db: SQLiteDB) throws -> [String: [String: String]] {
        var out: [String: [String: String]] = [:]
        for spec in MirrorFp.specs { out[spec.table] = try MirrorStore.fingerprints(db, spec) }
        return out
    }

    // MARK: - 写（通道表）

    enum WriteMode { case ignoreIfPresent, replace }

    /// 按**目标库实际有的列**写一行（同 `MirrorApply.write` 的口径：两端 schema 可能差一格）。
    /// 返回是否真的写进去了（`ignoreIfPresent` 时已存在 = false）。
    @discardableResult
    static func writeChannelRow(_ db: SQLiteDB, table: String, row: [String: Any], mode: WriteMode) throws -> Bool {
        guard channelTables.contains(table), try hasTable(db, table) else { return false }
        let cols = try db.query("PRAGMA table_info(\(table))").compactMap { $0["name"] as? String }
        let use = cols.filter { row.index(forKey: $0) != nil }
        guard !use.isEmpty else { return false }
        guard let rowId = channelRowId(table: table, row: row) else { return false }
        if mode == .ignoreIfPresent, try fetch(db, table: table, rowId: rowId) != nil { return false }
        let verb = mode == .replace ? "INSERT OR REPLACE" : "INSERT OR IGNORE"
        let ph = use.map { _ in "?" }.joined(separator: ",")
        try db.run("\(verb) INTO \(table)(\(use.joined(separator: ","))) VALUES(\(ph))", use.map { bind(row[$0]) })
        return true
    }

    /// 通道表一行的 row_id（与 `channelState` / `fetch` 同一口径）。
    static func channelRowId(table: String, row: [String: Any]) -> String? {
        switch table {
        case ocrTable:
            guard let h = row["content_hash"] as? String, let p = row["page"] as? Int64,
                  let pr = row["provider"] as? String else { return nil }
            return ocrRowId(MirrorDiff.OCRKey(contentHash: h, page: Int(p), provider: pr))
        case imageTable: return row["sha256"] as? String
        case alignTable: return row["content_hash"] as? String
        default: return nil
        }
    }

    static func bind(_ v: Any?) -> SQLiteDB.Value {
        switch v {
        case let s as String: return .text(s)
        case let n as Int64: return .int(n)
        case let n as Int: return .int(Int64(n))
        case let d as Double: return .double(d)
        case let b as Data: return .blob(b)
        default: return .null
        }
    }

    static func hasTable(_ db: SQLiteDB, _ name: String) throws -> Bool {
        !(try db.query("SELECT name FROM sqlite_master WHERE type='table' AND name=?", [.text(name)]).isEmpty)
    }
}
