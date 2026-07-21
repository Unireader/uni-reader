import Foundation
import CoreGraphics

/// 一个工作区的持久层：`<工作区>/UniReader/library.sqlite`（自有 schema，跨平台可读）。
/// 单一真相源；所有读写走这里。非线程安全，请在主线程使用。
final class LibraryStore {
    private let db: SQLiteDB
    let fileURL: URL
    static let schemaVersion = 5

    /// 打开/创建工作区库（文件夹须已存在）。会建表并跑迁移。
    init(workspaceFolder: URL) throws {
        let dir = workspaceFolder.appendingPathComponent("UniReader", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("library.sqlite")
        db = try SQLiteDB(path: fileURL.path)
        try migrate()
    }

    // MARK: - Schema / 迁移

    private func migrate() throws {
        let fresh = metaInt("schema_version") == nil
        // 建表（含最新列；已存在则不动）。
        try db.exec("""
        CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT);
        CREATE TABLE IF NOT EXISTS document (
          id TEXT PRIMARY KEY, title TEXT NOT NULL, page_count INTEGER NOT NULL,
          added_at TEXT NOT NULL, last_opened_at TEXT NOT NULL, sort_order INTEGER NOT NULL DEFAULT 0,
          read_page INTEGER NOT NULL DEFAULT 0, read_frac REAL NOT NULL DEFAULT 0,
          read_zoom REAL NOT NULL DEFAULT 1, read_hfrac REAL NOT NULL DEFAULT 0
        );
        CREATE TABLE IF NOT EXISTS variant (
          id TEXT PRIMARY KEY,
          document_id TEXT NOT NULL REFERENCES document(id) ON DELETE CASCADE,
          content_hash TEXT NOT NULL UNIQUE, page_count INTEGER NOT NULL, added_at TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_variant_document ON variant(document_id);
        CREATE TABLE IF NOT EXISTS location (
          id TEXT PRIMARY KEY,
          variant_id TEXT NOT NULL REFERENCES variant(id) ON DELETE CASCADE,
          path TEXT NOT NULL, is_valid INTEGER NOT NULL DEFAULT 1, last_validated_at TEXT,
          in_workspace INTEGER NOT NULL DEFAULT 0
        );
        CREATE INDEX IF NOT EXISTS idx_location_variant ON location(variant_id);
        CREATE TABLE IF NOT EXISTS note (
          id TEXT PRIMARY KEY,
          document_id TEXT NOT NULL REFERENCES document(id) ON DELETE CASCADE,
          kind INTEGER NOT NULL, page INTEGER NOT NULL,
          anchor_x REAL NOT NULL, anchor_y REAL NOT NULL, anchor_w REAL NOT NULL, anchor_h REAL NOT NULL,
          payload BLOB NOT NULL, created_at TEXT NOT NULL, updated_at TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_note_document_page ON note(document_id, page);
        -- v3：扫描页 OCR 结果缓存（跨平台契约）。按内容 hash（= variant 物理内容）+ 页 + 引擎 缓存，
        -- 随文件移动/换机复用；payload = JSON {w,h,runs:[{text,x,y,w,h}]}（归一化 0~1，左上原点）。
        CREATE TABLE IF NOT EXISTS ocr_page (
          content_hash TEXT NOT NULL, page INTEGER NOT NULL, provider TEXT NOT NULL,
          payload BLOB NOT NULL, lang TEXT, created_at TEXT NOT NULL,
          PRIMARY KEY (content_hash, page, provider)
        );
        """)
        // 已有库补列（幂等：列已存在则跳过）。v1 → v2 加入 阅读进度 + in_workspace。
        // v2 → v3 只新增 ocr_page 表（上面 CREATE TABLE IF NOT EXISTS 已覆盖，无需 ALTER）。
        try addColumnIfMissing("document", "read_page", "INTEGER NOT NULL DEFAULT 0")
        try addColumnIfMissing("document", "read_frac", "REAL NOT NULL DEFAULT 0")
        try addColumnIfMissing("location", "in_workspace", "INTEGER NOT NULL DEFAULT 0")
        // v3 → v4：记住上次缩放（相对 fit-width 的倍率，1=贴合宽度）。
        try addColumnIfMissing("document", "read_zoom", "REAL NOT NULL DEFAULT 1")
        // v4 → v5：记住上次横向滚动比例（offsetX / pageW，缩放态才非 0）。
        try addColumnIfMissing("document", "read_hfrac", "REAL NOT NULL DEFAULT 0")
        if fresh { try setMeta("created_at", ISO.string(.now)) }
        try setMeta("schema_version", String(Self.schemaVersion))
    }

    private func tableColumns(_ table: String) -> Set<String> {
        let rows = (try? db.query("PRAGMA table_info(\(table))")) ?? []
        return Set(rows.compactMap { $0["name"] as? String })
    }
    private func addColumnIfMissing(_ table: String, _ column: String, _ decl: String) throws {
        if !tableColumns(table).contains(column) {
            try db.exec("ALTER TABLE \(table) ADD COLUMN \(column) \(decl)")
        }
    }

    // MARK: - meta

    func meta(_ key: String) -> String? {
        (try? db.query("SELECT value FROM meta WHERE key=?", [.text(key)]))?.first?["value"] as? String
    }
    private func metaInt(_ key: String) -> Int? { meta(key).flatMap { Int($0) } }
    func setMeta(_ key: String, _ value: String) throws {
        try db.run("INSERT INTO meta(key,value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",
                   [.text(key), .text(value)])
    }
    var workspaceName: String {
        get { meta("workspace_name") ?? "" }
    }
    func setWorkspaceName(_ name: String) throws { try setMeta("workspace_name", name) }

    /// 工作区当前打开的文档集合（多窗口会话，存 meta·JSON，随文件夹移动而保留）。
    func openDocuments() -> [String] {
        guard let s = meta("open_documents"), let data = s.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [String] else { return [] }
        return arr
    }
    func setOpenDocuments(_ ids: [String]) throws {
        let data = (try? JSONSerialization.data(withJSONObject: ids)) ?? Data("[]".utf8)
        try setMeta("open_documents", String(data: data, encoding: .utf8) ?? "[]")
    }

    // MARK: - Document

    func allDocuments() throws -> [LibDocument] {
        try db.query("SELECT * FROM document ORDER BY sort_order ASC, last_opened_at DESC").map(Self.doc)
    }
    func document(id: String) throws -> LibDocument? {
        try db.query("SELECT * FROM document WHERE id=?", [.text(id)]).first.map(Self.doc)
    }
    func updateLastOpened(documentId: String, at date: Date = .now) throws {
        try db.run("UPDATE document SET last_opened_at=? WHERE id=?", [.text(ISO.string(date)), .text(documentId)])
    }
    /// 记录阅读进度（视口顶部所在页 + 页内比例 + 缩放倍率 + 横向滚动比例）。
    func updateProgress(documentId: String, page: Int, frac: Double, zoom: Double, hfrac: Double) throws {
        try db.run("UPDATE document SET read_page=?, read_frac=?, read_zoom=?, read_hfrac=? WHERE id=?",
                   [.int(Int64(page)), .double(min(max(0, frac), 1)), .double(zoom),
                    .double(min(max(0, hfrac), 1)), .text(documentId)])
    }
    func rename(documentId: String, title: String) throws {
        try db.run("UPDATE document SET title=? WHERE id=?", [.text(title), .text(documentId)])
    }
    func deleteDocument(id: String) throws {
        try db.run("DELETE FROM document WHERE id=?", [.text(id)])   // variant/location/note 级联删
    }

    // MARK: - Variant / Location

    func variant(hash: String) throws -> LibVariant? {
        try db.query("SELECT * FROM variant WHERE content_hash=?", [.text(hash)]).first.map(Self.variant)
    }
    func variant(id: String) throws -> LibVariant? {
        try db.query("SELECT * FROM variant WHERE id=?", [.text(id)]).first.map(Self.variant)
    }
    /// 给已有文档添加一个新版本（重定位到内容不同但用户认定为同一文档的文件时用）。
    @discardableResult
    func addVariant(documentId: String, hash: String, pageCount: Int, path: String, inWorkspace: Bool = false) throws -> LibVariant {
        let now = Date.now, varId = UUID().uuidString
        try db.transaction {
            try db.run("INSERT INTO variant(id,document_id,content_hash,page_count,added_at) VALUES(?,?,?,?,?)",
                       [.text(varId), .text(documentId), .text(hash), .int(Int64(pageCount)), .text(ISO.string(now))])
            try db.run("INSERT INTO location(id,variant_id,path,is_valid,last_validated_at,in_workspace) VALUES(?,?,?,1,?,?)",
                       [.text(UUID().uuidString), .text(varId), .text(path), .text(ISO.string(now)), .int(inWorkspace ? 1 : 0)])
        }
        return LibVariant(id: varId, documentId: documentId, contentHash: hash, pageCount: pageCount, addedAt: now)
    }
    func variants(documentId: String) throws -> [LibVariant] {
        try db.query("SELECT * FROM variant WHERE document_id=? ORDER BY added_at ASC", [.text(documentId)]).map(Self.variant)
    }
    func locations(variantId: String) throws -> [LibLocation] {
        try db.query("SELECT * FROM location WHERE variant_id=? ORDER BY is_valid DESC", [.text(variantId)]).map(Self.location)
    }
    /// 逻辑文档的全部路径（跨版本），有效优先。用于打开时探测可用路径。
    func locations(documentId: String) throws -> [LibLocation] {
        try db.query("""
        SELECT location.* FROM location
        JOIN variant ON location.variant_id = variant.id
        WHERE variant.document_id=? ORDER BY location.is_valid DESC
        """, [.text(documentId)]).map(Self.location)
    }
    func setLocationValidity(id: String, isValid: Bool, at date: Date = .now) throws {
        try db.run("UPDATE location SET is_valid=?, last_validated_at=? WHERE id=?",
                   [.int(isValid ? 1 : 0), .text(ISO.string(date)), .text(id)])
    }
    /// 逻辑文档下所有「已复制进工作区」的 location（path 为工作区相对路径）。
    func inWorkspaceLocations(documentId: String) throws -> [LibLocation] {
        try db.query("""
        SELECT location.* FROM location JOIN variant ON location.variant_id = variant.id
        WHERE variant.document_id=? AND location.in_workspace=1
        """, [.text(documentId)]).map(Self.location)
    }
    @discardableResult
    func addLocation(variantId: String, path: String, inWorkspace: Bool) throws -> LibLocation {
        let id = UUID().uuidString, now = Date.now
        try db.run("INSERT INTO location(id,variant_id,path,is_valid,last_validated_at,in_workspace) VALUES(?,?,?,1,?,?)",
                   [.text(id), .text(variantId), .text(path), .text(ISO.string(now)), .int(inWorkspace ? 1 : 0)])
        return LibLocation(id: id, variantId: variantId, path: path, isValid: true, lastValidatedAt: now, inWorkspace: inWorkspace)
    }
    func removeLocation(id: String) throws { try db.run("DELETE FROM location WHERE id=?", [.text(id)]) }

    // MARK: - 导入：按 hash + 路径「找到或创建」

    /// 打开一个 PDF 时调用（已算出 hash）。返回其逻辑文档与该版本。
    /// - hash 已知 → 复用其 document/variant，并确保 path 作为 location 存在。
    /// - hash 未知 → 新建 document + variant + location。
    @discardableResult
    func findOrCreate(hash: String, title: String, pageCount: Int, path: String) throws -> (document: LibDocument, variant: LibVariant) {
        if let v = try variant(hash: hash) {
            try ensureLocation(variantId: v.id, path: path)
            try updateLastOpened(documentId: v.documentId)
            let doc = try document(id: v.documentId) ?? { throw SQLiteError.step("variant 指向的 document 缺失") }()
            return (doc, v)
        }
        let now = Date.now
        let docId = UUID().uuidString, varId = UUID().uuidString
        try db.transaction {
            try db.run("INSERT INTO document(id,title,page_count,added_at,last_opened_at,sort_order) VALUES(?,?,?,?,?,0)",
                       [.text(docId), .text(title), .int(Int64(pageCount)), .text(ISO.string(now)), .text(ISO.string(now))])
            try db.run("INSERT INTO variant(id,document_id,content_hash,page_count,added_at) VALUES(?,?,?,?,?)",
                       [.text(varId), .text(docId), .text(hash), .int(Int64(pageCount)), .text(ISO.string(now))])
            try db.run("INSERT INTO location(id,variant_id,path,is_valid,last_validated_at) VALUES(?,?,?,1,?)",
                       [.text(UUID().uuidString), .text(varId), .text(path), .text(ISO.string(now))])
        }
        let doc = LibDocument(id: docId, title: title, pageCount: pageCount, addedAt: now, lastOpenedAt: now, sortOrder: 0)
        let v = LibVariant(id: varId, documentId: docId, contentHash: hash, pageCount: pageCount, addedAt: now)
        return (doc, v)
    }

    /// 确保某 variant 下存在该路径的 location（去重）。
    private func ensureLocation(variantId: String, path: String) throws {
        let exists = try db.query("SELECT id FROM location WHERE variant_id=? AND path=?",
                                  [.text(variantId), .text(path)]).first != nil
        if exists {
            try db.run("UPDATE location SET is_valid=1, last_validated_at=? WHERE variant_id=? AND path=?",
                       [.text(ISO.string(.now)), .text(variantId), .text(path)])
        } else {
            try db.run("INSERT INTO location(id,variant_id,path,is_valid,last_validated_at) VALUES(?,?,?,1,?)",
                       [.text(UUID().uuidString), .text(variantId), .text(path), .text(ISO.string(.now))])
        }
    }

    /// 「关联为同一文档」：把源 document 的**全部** variant 与 note 并入目标 document，再删源 document。
    /// 用于侧栏「关联到…」把 B 认定为 A 的另一版本。返回是否成功。
    @discardableResult
    func mergeDocument(sourceId: String, intoTargetId targetId: String) throws -> Bool {
        guard sourceId != targetId,
              try document(id: sourceId) != nil, try document(id: targetId) != nil else { return false }
        try db.transaction {
            try db.run("UPDATE variant SET document_id=? WHERE document_id=?", [.text(targetId), .text(sourceId)])
            try db.run("UPDATE note SET document_id=? WHERE document_id=?", [.text(targetId), .text(sourceId)])
            try db.run("DELETE FROM document WHERE id=?", [.text(sourceId)])
        }
        return true
    }

    /// 「关联为同一文档」：把某 variant 挪到目标 document 名下（多 hash 合并，笔记随目标 document 共用）。
    /// 若源 document 变空则删除。返回是否成功。
    @discardableResult
    func linkVariant(variantId: String, toDocumentId targetDocId: String) throws -> Bool {
        guard let v = try db.query("SELECT * FROM variant WHERE id=?", [.text(variantId)]).first.map(Self.variant),
              try document(id: targetDocId) != nil else { return false }
        let sourceDocId = v.documentId
        if sourceDocId == targetDocId { return true }
        try db.transaction {
            try db.run("UPDATE variant SET document_id=? WHERE id=?", [.text(targetDocId), .text(variantId)])
            let remaining = try db.query("SELECT COUNT(*) AS n FROM variant WHERE document_id=?", [.text(sourceDocId)]).first?["n"] as? Int64 ?? 0
            if remaining == 0 { try db.run("DELETE FROM document WHERE id=?", [.text(sourceDocId)]) }
        }
        return true
    }

    // MARK: - Note

    func notes(documentId: String) throws -> [LibNote] {
        try db.query("SELECT * FROM note WHERE document_id=? ORDER BY page ASC, created_at ASC", [.text(documentId)]).map(Self.note)
    }
    func notes(documentId: String, page: Int) throws -> [LibNote] {
        try db.query("SELECT * FROM note WHERE document_id=? AND page=? ORDER BY created_at ASC",
                     [.text(documentId), .int(Int64(page))]).map(Self.note)
    }
    func upsertNote(_ n: LibNote) throws {
        try db.run("""
        INSERT INTO note(id,document_id,kind,page,anchor_x,anchor_y,anchor_w,anchor_h,payload,created_at,updated_at)
        VALUES(?,?,?,?,?,?,?,?,?,?,?)
        ON CONFLICT(id) DO UPDATE SET kind=excluded.kind, page=excluded.page,
          anchor_x=excluded.anchor_x, anchor_y=excluded.anchor_y, anchor_w=excluded.anchor_w, anchor_h=excluded.anchor_h,
          payload=excluded.payload, updated_at=excluded.updated_at
        """, [.text(n.id), .text(n.documentId), .int(Int64(n.kind)), .int(Int64(n.page)),
              .double(n.anchor.origin.x), .double(n.anchor.origin.y), .double(n.anchor.size.width), .double(n.anchor.size.height),
              .blob(n.payload), .text(ISO.string(n.createdAt)), .text(ISO.string(n.updatedAt))])
    }
    func deleteNote(id: String) throws { try db.run("DELETE FROM note WHERE id=?", [.text(id)]) }

    // MARK: - OCR 缓存（ocr_page，v3）

    /// 取某内容(hash) 某页某引擎的 OCR 缓存（miss → nil，上层再真跑 OCR 并回填）。
    func ocrPage(contentHash: String, page: Int, provider: String) throws -> OCRPage? {
        try db.query("SELECT * FROM ocr_page WHERE content_hash=? AND page=? AND provider=?",
                     [.text(contentHash), .int(Int64(page)), .text(provider)]).first.map(Self.ocr)
    }
    /// 回填/更新一页的 OCR 结果。
    func upsertOCRPage(_ p: OCRPage) throws {
        try db.run("""
        INSERT INTO ocr_page(content_hash,page,provider,payload,lang,created_at) VALUES(?,?,?,?,?,?)
        ON CONFLICT(content_hash,page,provider) DO UPDATE SET
          payload=excluded.payload, lang=excluded.lang, created_at=excluded.created_at
        """, [.text(p.contentHash), .int(Int64(p.page)), .text(p.provider),
              .blob(p.payload), p.lang.map { .text($0) } ?? .null, .text(ISO.string(p.createdAt))])
    }
    /// 清除某内容(hash)的全部 OCR 缓存（hash 变化/重关联时用）。
    func deleteOCRPages(contentHash: String) throws {
        try db.run("DELETE FROM ocr_page WHERE content_hash=?", [.text(contentHash)])
    }
    /// 某内容(hash) 某引擎已缓存的 OCR 页数（>0 → 打开文档时自动启用 OCR 文本层，缓存直接复用）。
    func ocrPageCount(contentHash: String, provider: String) throws -> Int {
        let rows = try db.query("SELECT COUNT(*) AS c FROM ocr_page WHERE content_hash=? AND provider=?",
                                [.text(contentHash), .text(provider)])
        return Int((rows.first?["c"] as? Int64) ?? 0)
    }

    // MARK: - 行 → 模型

    private static func doc(_ r: [String: Any]) -> LibDocument {
        LibDocument(id: r["id"] as? String ?? "", title: r["title"] as? String ?? "",
                    pageCount: Int(r["page_count"] as? Int64 ?? 0),
                    addedAt: ISO.date(r["added_at"] as? String) ?? .now,
                    lastOpenedAt: ISO.date(r["last_opened_at"] as? String) ?? .now,
                    sortOrder: Int(r["sort_order"] as? Int64 ?? 0),
                    readPage: Int(r["read_page"] as? Int64 ?? 0),
                    readFrac: r["read_frac"] as? Double ?? 0,
                    readZoom: r["read_zoom"] as? Double ?? 1,
                    readHFrac: r["read_hfrac"] as? Double ?? 0)
    }
    private static func variant(_ r: [String: Any]) -> LibVariant {
        LibVariant(id: r["id"] as? String ?? "", documentId: r["document_id"] as? String ?? "",
                   contentHash: r["content_hash"] as? String ?? "",
                   pageCount: Int(r["page_count"] as? Int64 ?? 0),
                   addedAt: ISO.date(r["added_at"] as? String) ?? .now)
    }
    private static func location(_ r: [String: Any]) -> LibLocation {
        LibLocation(id: r["id"] as? String ?? "", variantId: r["variant_id"] as? String ?? "",
                    path: r["path"] as? String ?? "",
                    isValid: (r["is_valid"] as? Int64 ?? 0) != 0,
                    lastValidatedAt: ISO.date(r["last_validated_at"] as? String),
                    inWorkspace: (r["in_workspace"] as? Int64 ?? 0) != 0)
    }
    private static func note(_ r: [String: Any]) -> LibNote {
        LibNote(id: r["id"] as? String ?? "", documentId: r["document_id"] as? String ?? "",
                kind: Int(r["kind"] as? Int64 ?? 0), page: Int(r["page"] as? Int64 ?? 0),
                anchor: CGRect(x: r["anchor_x"] as? Double ?? 0, y: r["anchor_y"] as? Double ?? 0,
                               width: r["anchor_w"] as? Double ?? 0, height: r["anchor_h"] as? Double ?? 0),
                payload: r["payload"] as? Data ?? Data(),
                createdAt: ISO.date(r["created_at"] as? String) ?? .now,
                updatedAt: ISO.date(r["updated_at"] as? String) ?? .now)
    }
    private static func ocr(_ r: [String: Any]) -> OCRPage {
        OCRPage(contentHash: r["content_hash"] as? String ?? "",
                page: Int(r["page"] as? Int64 ?? 0),
                provider: r["provider"] as? String ?? "",
                payload: r["payload"] as? Data ?? Data(),
                lang: r["lang"] as? String,
                createdAt: ISO.date(r["created_at"] as? String) ?? .now)
    }
}
