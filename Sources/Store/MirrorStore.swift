import Foundation

/// 离线镜像的**记账层**：`sync_base` 基线表、血缘 meta、借出记录的编解码。
/// 方案见 `OFFLINE-MIRROR-PLAN.md` §3/§5；建镜像的文件级流程在 `MirrorBuilder`。
///
/// 🔴 **跨端契约**：表结构、meta 键名、借出记录的 JSON 形态都写在同一个工作区的库里，
/// Mac 与安卓 `local/mirror/MirrorStore.kt` 必须一致，改一边同步另一边。
///
/// 这一层只认 `SQLiteDB`、不认 `LibraryStore`：
/// - **镜像库**是刚 `VACUUM INTO` 出来的新文件，全 app 没有第二个人持有它 → 自建短连接最省事；
/// - **源库**可能正被某个窗口开着，那边一律走它自己的 `LibraryStore` 实例
///   （§8.1「同一工作区路径必须共享同一个实例」红线），所以本层不去打开源库。
enum MirrorStore {

    // MARK: - meta 键（镜像库侧）

    /// 源工作区的 `workspace_id`。**镜像认源盘的唯一判据**——名字会改、路径必变。
    static let metaMirrorOf = "mirror_of"
    /// 本镜像的 UUID。源库的借出记录靠它对上号（一个源可以有多份镜像）。
    static let metaMirrorId = "mirror_id"
    static let metaMirrorCreatedAt = "mirror_created_at"
    /// 「上次见到源盘时它在哪」。**只用来给一句人话提示**（"把那块 XXX 盘插上"），
    /// 绝不作为判据——判据永远是 `mirror_of`。
    static let metaMirrorSourceHint = "mirror_source_hint"
    static let metaMirrorLastSyncedAt = "mirror_last_synced_at"

    // MARK: - meta 键（源库侧）

    /// 借出记录 JSON 数组。**它是信息不是锁**（方案 §5.2）：打开一个有记录的工作区
    /// 只显示一行「有 N 份离线镜像」，不阻塞任何操作。
    static let metaCheckouts = "offline_checkouts"

    /// 一条借出记录。字段名即 JSON 键，**两端逐字一致**。
    struct Checkout: Codable, Equatable {
        var mirrorId: String
        var deviceId: String
        var deviceName: String
        var takenAt: String              // ISO-8601
        var lastSyncedAt: String?        // 从未同步过 = nil
        var noteCount: Int               // 建镜像那一刻的笔记条数，纯展示用

        enum CodingKeys: String, CodingKey {
            case mirrorId = "mirror_id"
            case deviceId = "device_id"
            case deviceName = "device_name"
            case takenAt = "taken_at"
            case lastSyncedAt = "last_synced_at"
            case noteCount = "note_count"
        }
    }

    /// 解析借出记录。**坏 JSON 按空处理**：这是展示用的元数据，不该让一条脏记录挡住开工作区。
    static func decodeCheckouts(_ json: String?) -> [Checkout] {
        guard let json, let data = json.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([Checkout].self, from: data)) ?? []
    }

    static func encodeCheckouts(_ list: [Checkout]) -> String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]   // 稳定字节：同样的内容不该因键序抖动而看着像改过
        guard let data = try? enc.encode(list) else { return "[]" }
        return String(decoding: data, as: UTF8.self)
    }

    /// 追加/替换一条借出记录（同 `mirrorId` 覆盖）。
    static func upsertCheckout(_ list: [Checkout], _ c: Checkout) -> [Checkout] {
        var out = list.filter { $0.mirrorId != c.mirrorId }
        out.append(c)
        return out
    }

    // MARK: - 本机身份

    private static let deviceIdKey = "mirrorDeviceId"

    /// 本机的稳定 id（**不进工作区**，存本机 UserDefaults）。
    /// 只用来在借出记录里区分「哪台设备借走的」，不需要真硬件 ID。
    static var deviceId: String {
        if let s = UserDefaults.standard.string(forKey: deviceIdKey), !s.isEmpty { return s }
        let s = UUID().uuidString
        UserDefaults.standard.set(s, forKey: deviceIdKey)
        return s
    }

    static var deviceName: String {
        Host.current().localizedName ?? ProcessInfo.processInfo.hostName
    }

    // MARK: - sync_base（只在镜像库里存在）

    /// 基线表：建镜像那一刻每行的指纹。合并时重算一遍就能判出新增/删除/修改（方案 §3.1）。
    ///
    /// **源库永远不认识这张表**——它只是镜像的私有记账，不进跨端 schema 契约、不占 schema 版本号。
    /// `WITHOUT ROWID`：整张表就是 (tbl,row_id) → fp 的映射，省掉一份多余的 rowid 索引。
    static let syncBaseDDL = """
    CREATE TABLE IF NOT EXISTS sync_base (
      tbl TEXT NOT NULL,
      row_id TEXT NOT NULL,
      fp TEXT NOT NULL,
      PRIMARY KEY (tbl, row_id)
    ) WITHOUT ROWID;
    """

    /// 重算并覆盖整张基线表，返回记下的行数。
    ///
    /// **整表重算而不是增量维护**：这正是指纹方案胜过 oplog 的地方——不依赖「从建镜像起每次写都被
    /// 记上」这个连续性假设，任何时候重跑一遍都得到正确的基线（方案 §3.2）。
    @discardableResult
    static func rebuildSyncBase(_ db: SQLiteDB) throws -> Int {
        try db.exec(syncBaseDDL)
        var rows = 0
        try db.transaction {
            try db.run("DELETE FROM sync_base")
            for spec in MirrorFp.specs {
                for (rowId, fp) in try fingerprints(db, spec) {
                    try db.run("INSERT INTO sync_base(tbl,row_id,fp) VALUES(?,?,?)",
                               [.text(spec.table), .text(rowId), .text(fp)])
                    rows += 1
                }
            }
        }
        return rows
    }

    /// 一张表当前的 `row_id → fp`。`meta` 只取同步白名单里的键（方案 §4）——
    /// `schema_version`/`open_documents`/`mirror_*` 这些进了基线，同步时就会互相覆盖对方的本机状态。
    static func fingerprints(_ db: SQLiteDB, _ spec: MirrorFp.TableSpec) throws -> [String: String] {
        var rows = try db.query("SELECT * FROM \(spec.table)")
        if spec.table == "meta" {
            rows = rows.filter { row in
                guard let k = row["key"] as? String else { return false }
                return MirrorFp.syncedMetaKeys.contains(k)
            }
        }
        return MirrorFp.fingerprints(rows: rows, spec: spec)
    }

    /// 读回基线：`表名 → (row_id → fp)`。表不存在（不是镜像）时返回空。
    static func syncBase(_ db: SQLiteDB) throws -> [String: [String: String]] {
        guard hasSyncBase(db) else { return [:] }
        var out: [String: [String: String]] = [:]
        for row in try db.query("SELECT tbl,row_id,fp FROM sync_base") {
            guard let t = row["tbl"] as? String,
                  let id = row["row_id"] as? String,
                  let fp = row["fp"] as? String else { continue }
            out[t, default: [:]][id] = fp
        }
        return out
    }

    static func hasSyncBase(_ db: SQLiteDB) -> Bool {
        let r = (try? db.query("SELECT name FROM sqlite_master WHERE type='table' AND name='sync_base'")) ?? []
        return !r.isEmpty
    }
}
