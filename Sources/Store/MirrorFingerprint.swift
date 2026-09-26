import Foundation
import CryptoKit

/// 离线镜像三方合并的**行指纹**（方案见 `OFFLINE-MIRROR-PLAN.md` §3）。
///
/// 用途：镜像库里的 `sync_base(tbl,row_id,fp)` 记下「建镜像那一刻」每行的样子；合并时重算一遍
/// 就能判出新增 / 删除 / 修改，**不需要墓碑表、不需要改任何写路径、不需要动 schema 契约**。
///
/// 🔴 **跨端契约：与安卓 `local/store/MirrorFp.kt` 必须字节一致**，改一边必须同步另一边，
/// 并让 `spike/mirror-fp-test.swift` 与安卓 `MirrorFpTest` 跑同一组向量（同 `wire-cross-test` 的既有纪律）。
/// 两端算出的 fp 差一个 bit，整张表就会被误判成「全都改过」——干跑预览里刷出几万条，等于这功能废了。
///
/// ## 编码
///
/// 每列按 `enc()` 编码，列间以 `0x1F` 分隔，整串 SHA-256，取**前 16 个 hex 字符**。
/// ```
/// enc(NULL)    = 0x00
/// enc(INTEGER) = 0x01 + 十进制 ASCII（含负号）
/// enc(REAL)    = 0x02 + IEEE754 双精度 8 字节【小端】原始字节
/// enc(TEXT)    = 0x03 + UTF-8 原文
/// enc(BLOB)    = 0x04 + 原字节
/// ```
/// - **REAL 走原始字节而不是十进制文本**：`%.17g` 这类格式化在两端的实现不保证逐字符一致，
///   而 fp 差一个字符就是全表误判。位模式是 IEEE754 定死的，没有解释空间。
/// - **首字节是类型标签，不是「非空」标志**：只用一个 `0x01` 的话，NULL 撞空 TEXT、
///   空 TEXT 撞空 BLOB、`int 1` 撞 `text "1"`。这些撞法**眼下都碰不着**（同一列的声明类型固定，
///   见 `coerce`），但那是"因为别处不会那么用"的侥幸；带上类型标签编码就是单射的，
///   一整类「这样安不安全」的推理直接不用做，代价是零。
/// - 值按**列的声明类型**强制归一（见 `coerce`），不看它在库里实际存成了什么存储类：
///   同一个 `read_zoom=1`，一端绑 `Double` 存成 REAL、另一端绑 `Int` 存成 INTEGER，
///   不归一就是「明明没改却判成改了」。
enum MirrorFp {

    // MARK: - 表规格

    enum ColType { case int, real, text, blob }

    struct Column {
        let name: String
        let type: ColType
        init(_ name: String, _ type: ColType) { self.name = name; self.type = type }
    }

    /// 一张参与同步的表：主键列 + 参与指纹的列（**顺序即契约**）+ 冲突时按哪一列判新旧。
    struct TableSpec {
        let table: String
        let key: String
        let columns: [Column]
        /// 两端都改了同一行时，按这一列的 ISO-8601 时间戳取新的（方案 §6）。
        /// nil = 这张表没有时间戳列，冲突一律**保留源盘那份**并报告。
        ///
        /// 放在表规格里而不是另起一张映射表：这一列就在上面 `columns` 里躺着，
        /// 分开写迟早出现「加了 updated_at 却忘了登记 LWW」。
        let lww: String?

        init(table: String, key: String, columns: [Column], lww: String? = nil) {
            self.table = table; self.key = key; self.columns = columns; self.lww = lww
        }
    }

    /// 🔴 **列顺序是写死的，不许改成读 `PRAGMA table_info`。**
    /// 那个顺序对「全新建的 v12 库」和「v1 一路 ALTER 上来的 v12 库」**是不一样的**
    /// （`ADD COLUMN` 永远追加在末尾），拿它当契约 = 同一份数据在两台机器上算出两个 fp。
    /// 这里的顺序 = 全新库 `CREATE TABLE` 里的顺序（也就是安卓 `Schema.kt` 建出来的那个）。
    ///
    /// 表的取舍见 `OFFLINE-MIRROR-PLAN.md` §4：`location` 是设备本地事实**绝不同步**、
    /// `ocr_page` 纯 additive 走 `INSERT OR IGNORE` 不需要 base。
    static let specs: [TableSpec] = [
        TableSpec(table: "document", key: "id", columns: [
            Column("id", .text), Column("title", .text), Column("page_count", .int),
            Column("added_at", .text), Column("sort_order", .int),
            Column("read_page", .int), Column("read_frac", .real),
            Column("read_zoom", .real), Column("read_hfrac", .real),
            Column("group_name", .text), Column("canvas_mode", .int),
            // ⚠️ `last_opened_at` **刻意不在这里**（方案 §4）：进了指纹的话，「在镜像上翻开过这本书」
            // 就会把整行标记成「改过」，干跑预览里满屏都是无意义条目。合并时无条件取 max 即可。
        ],
        // 🔴 用 `last_opened_at` 当 LWW 依据（2026-09-01 实测后加）。这张表**没有** `updated_at`，
        // 原先 lww=nil ⇒ 落到「没有时间戳可比，保留硬盘那份」——于是**在离线副本上读到哪儿会被
        // 静默丢弃**，而方案 §13 拍板过「阅读进度跨镜像同步」。`last_opened_at` 是 NOT NULL、
        // 一定有值，而且语义正好：**谁最后打开过这本书，谁那份进度就是更近的那次阅读的结果**。
                  lww: "last_opened_at"),
        TableSpec(table: "variant", key: "id", columns: [
            Column("id", .text), Column("document_id", .text), Column("content_hash", .text),
            Column("page_count", .int), Column("added_at", .text),
        ]),
        TableSpec(table: "note", key: "id", columns: [
            Column("id", .text), Column("document_id", .text), Column("kind", .int), Column("page", .int),
            Column("anchor_x", .real), Column("anchor_y", .real),
            Column("anchor_w", .real), Column("anchor_h", .real),
            Column("payload", .blob), Column("created_at", .text), Column("updated_at", .text),
        ], lww: "updated_at"),
        TableSpec(table: "ink_layer", key: "id", columns: [
            Column("id", .text), Column("document_id", .text), Column("name", .text),
            Column("color_key", .text), Column("sort_order", .int), Column("visible", .int),
            Column("created_at", .text),
        ]),
        TableSpec(table: "scratch_pad", key: "id", columns: [
            Column("id", .text), Column("document_id", .text), Column("title", .text),
            Column("anchor_page", .int), Column("anchor_x", .real), Column("anchor_y", .real),
            Column("bg", .text), Column("pattern", .text), Column("show_page", .int),
            Column("created_at", .text), Column("updated_at", .text),
        ], lww: "updated_at"),
        // v15：Markdown 笔记的**元数据行**（`MARKDOWN-NOTES-PLAN.md §2.2`）。正文是 `Notes/` 下的文件，
        // 不在这张表里——它按 `Images/` 那条纯 additive 通道复制，两边同一篇都改过时**不合并正文**、
        // 按 `updated_at` 整份取新（欠账，方案 §7）。这里合并的只是标题 / 路径 / 分组 / 位次。
        TableSpec(table: "md_doc", key: "id", columns: [
            Column("id", .text), Column("title", .text), Column("rel_path", .text),
            Column("group_name", .text), Column("sort_order", .int),
            Column("created_at", .text), Column("updated_at", .text),
            // `last_opened_at` 同 `document`：刻意不进指纹（翻开过一次就满屏「改过」）。
        ], lww: "updated_at"),
        // v16：画板笔记（`BOARD-NOTE-PLAN.md §6`）。父表在前（`board_item.board_id` 指向它），两张都按
        // `updated_at` 取新；`board_item` 一条一行，两边各加的笔迹 / 图自然并起来。
        // `last_opened_at` 同 `document` / `md_doc`：刻意不进指纹。
        TableSpec(table: "board_note", key: "id", columns: [
            Column("id", .text), Column("title", .text), Column("bg", .text), Column("pattern", .text),
            Column("group_name", .text), Column("created_at", .text), Column("updated_at", .text),
        ], lww: "updated_at"),
        TableSpec(table: "board_item", key: "id", columns: [
            Column("id", .text), Column("board_id", .text), Column("kind", .int),
            Column("x", .real), Column("y", .real), Column("w", .real), Column("h", .real),
            Column("payload", .blob), Column("created_at", .text), Column("updated_at", .text),
        ], lww: "updated_at"),
        TableSpec(table: "meta", key: "key", columns: [
            Column("key", .text), Column("value", .text),
        ]),
    ]

    static func spec(_ table: String) -> TableSpec? { specs.first { $0.table == table } }

    /// `meta` 表里**参与同步**的键（方案 §4）。`meta` 是个杂物袋：既有工作区级配置（该同步），
    /// 也有本机状态与库自身属性（绝不能同步）。所以它跟别的表不一样，除了列规格还要一张键白名单。
    ///
    /// 刻意在外的：`schema_version`/`created_at`（库自身属性）、`open_documents`（本机开着哪几篇）、
    /// `workspace_id`/`mirror_*`/`offline_checkouts`（血缘元数据 —— 同步它们就是让两边互相
    /// 把对方的身份覆盖掉）。
    static let syncedMetaKeys: Set<String> = ["workspace_name", "note_types"]

    /// `document` 里纯粹表示「读到哪儿」的列。
    ///
    /// 两端各翻过同一本书，这几列就都会变 —— 那是**正常使用**，不是冲突。按 `last_opened_at`
    /// 取最近读过的那次即可，不该弹到用户面前让他裁决（2026-09-01 用户实测："几乎什么都没动"
    /// 却收到一条看不懂的冲突）。除这几列之外还有差异，才是真冲突。
    static let progressColumns: Set<String> = ["read_page", "read_frac", "read_zoom", "read_hfrac"]

    /// 忽略掉某些列之后这一行的指纹，用来判断「两端的差异是不是只在那几列上」。
    static func fingerprint(row: [String: Any], spec: TableSpec, ignoring: Set<String>) -> String {
        fingerprint(spec.columns.filter { !ignoring.contains($0.name) }
            .map { coerce(row[$0.name], as: $0.type) })
    }

    // MARK: - 值与编码

    enum Value: Equatable {
        case null
        case int(Int64)
        case real(Double)
        case text(String)
        case blob(Data)
    }

    static let separator: UInt8 = 0x1F

    /// 类型标签（编码首字节）。**跨端契约，值不许改。**
    static let tagNull: UInt8 = 0x00
    static let tagInt: UInt8 = 0x01
    static let tagReal: UInt8 = 0x02
    static let tagText: UInt8 = 0x03
    static let tagBlob: UInt8 = 0x04

    static func enc(_ v: Value) -> Data {
        switch v {
        case .null:
            return Data([tagNull])
        case .int(let n):
            return Data([tagInt]) + Data(String(n).utf8)
        case .real(let d):
            return Data([tagReal]) + Data(le8(canonical(d)))
        case .text(let s):
            return Data([tagText]) + Data(s.utf8)
        case .blob(let b):
            return Data([tagBlob]) + b
        }
    }

    /// 规格化浮点：`-0.0` 归 `+0.0`、任何 NaN 归同一个位模式。
    /// 两端在这两处的位模式本来就不保证一致，而它们**语义上没有区别**——不归一就是无谓的全表误判。
    static func canonical(_ d: Double) -> Double {
        if d.isNaN { return Double(bitPattern: 0x7ff8_0000_0000_0000) }
        if d == 0 { return 0 }        // -0.0 == 0.0 为真，于是这一句把 -0.0 也拍平
        return d
    }

    static func le8(_ d: Double) -> [UInt8] {
        let bits = d.bitPattern
        return (0..<8).map { UInt8truncating(bits >> (8 * UInt64($0))) }
    }

    private static func UInt8truncating(_ x: UInt64) -> UInt8 { UInt8(x & 0xFF) }

    /// 一行的指纹：各列 `enc()` 以 `0x1F` 相连 → SHA-256 → 前 16 个 hex 字符。
    static func fingerprint(_ values: [Value]) -> String {
        var buf = Data()
        for (i, v) in values.enumerated() {
            if i > 0 { buf.append(separator) }
            buf.append(enc(v))
        }
        let digest = SHA256.hash(data: buf)
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - 从查询结果取值

    /// 把 `SQLiteDB.query` 返回的一行（列名 → `String`/`Int64`/`Double`/`Data`/`NSNull`）
    /// 按 spec 的**声明类型**归一成 `Value`。缺列按 NULL 处理（老库少一列时不炸）。
    static func coerce(_ raw: Any?, as type: ColType) -> Value {
        guard let raw, !(raw is NSNull) else { return .null }
        switch type {
        case .int:
            if let n = raw as? Int64 { return .int(n) }
            if let n = raw as? Int { return .int(Int64(n)) }
            if let d = raw as? Double { return .int(Int64(d)) }
            if let s = raw as? String { return .int(Int64(s) ?? 0) }
            if let b = raw as? Data { return .int(Int64(String(decoding: b, as: UTF8.self)) ?? 0) }
            return .null
        case .real:
            if let d = raw as? Double { return .real(d) }
            if let n = raw as? Int64 { return .real(Double(n)) }
            if let n = raw as? Int { return .real(Double(n)) }
            if let s = raw as? String { return .real(Double(s) ?? 0) }
            if let b = raw as? Data { return .real(Double(String(decoding: b, as: UTF8.self)) ?? 0) }
            return .null
        case .text:
            if let s = raw as? String { return .text(s) }
            if let n = raw as? Int64 { return .text(String(n)) }
            if let n = raw as? Int { return .text(String(n)) }
            if let d = raw as? Double { return .text(String(d)) }
            if let b = raw as? Data { return .text(String(decoding: b, as: UTF8.self)) }
            return .null
        case .blob:
            if let b = raw as? Data { return .blob(b) }
            if let s = raw as? String { return .blob(Data(s.utf8)) }
            return .null
        }
    }

    /// 一行（列名 → 值）按 spec 算指纹。
    static func fingerprint(row: [String: Any], spec: TableSpec) -> String {
        fingerprint(spec.columns.map { coerce(row[$0.name], as: $0.type) })
    }

    /// 整表：`row_id → fp`。`rows` 用 `SELECT * FROM <表>` 的结果即可（列多了不影响，按 spec 取）。
    static func fingerprints(rows: [[String: Any]], spec: TableSpec) -> [String: String] {
        var out: [String: String] = [:]
        out.reserveCapacity(rows.count)
        for row in rows {
            guard case .text(let id) = coerce(row[spec.key], as: .text) else { continue }
            out[id] = fingerprint(row: row, spec: spec)
        }
        return out
    }
}
