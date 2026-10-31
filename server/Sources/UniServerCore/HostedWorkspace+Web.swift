import Foundation

/// 网页阅读器用的只读查询（方案 `WEB-READER-PLAN.md §3`）。
extension HostedWorkspace {

    /// 书目里的一本书。
    public struct DocumentInfo: Equatable, Sendable {
        public let id: String
        public let title: String
        public let group: String
        public let pageCount: Int
        /// 阅读进度（页从 0 起 + 页内比例），各设备经同步共用的那份。
        public let readPage: Int
        public let readFrac: Double
        /// 打开时用的那份 PDF：按添加先后，**第一个服务器上有文件的版本**（口径同 App 的 `ServerSyncCoordinator.fetchDocument`）。
        /// 一个都没有 = nil（PDF 还没传上来）。
        public let contentHash: String?
        public let pdfBytes: Int64?
    }

    /// 全部书，顺序同 App 的书目（`LibraryStore.allDocuments`）。
    public func documents() throws -> [DocumentInfo] {
        lock.lock(); defer { lock.unlock() }
        try checkOpen()
        return try store.withMirrorDB { db in
            var variants: [String: [(hash: String, pages: Int)]] = [:]
            for r in try db.query("SELECT document_id, content_hash, page_count FROM variant ORDER BY added_at ASC") {
                guard let doc = r["document_id"] as? String, let hash = r["content_hash"] as? String else { continue }
                variants[doc, default: []].append((hash, Int(r["page_count"] as? Int64 ?? 0)))
            }
            return try db.query("""
            SELECT id, title, group_name, page_count, read_page, read_frac FROM document
            ORDER BY sort_order ASC, last_opened_at DESC
            """).compactMap { r -> DocumentInfo? in
                guard let id = r["id"] as? String else { return nil }
                var pages = Int(r["page_count"] as? Int64 ?? 0)
                var hash: String?, bytes: Int64?
                for v in variants[id] ?? [] {
                    guard let url = pdfFileLocked(db, contentHash: v.hash) else { continue }
                    hash = v.hash
                    bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
                    if v.pages > 0 { pages = v.pages }
                    break
                }
                return DocumentInfo(id: id, title: r["title"] as? String ?? "", group: r["group_name"] as? String ?? "",
                                    pageCount: pages, readPage: Int(r["read_page"] as? Int64 ?? 0),
                                    readFrac: r["read_frac"] as? Double ?? 0, contentHash: hash, pdfBytes: bytes)
            }
        }
    }
}

// MARK: - W2：页面上的标记（方案 `WEB-READER-PLAN.md §3 / §4`）

extension HostedWorkspace {

    /// 一个笔迹图层（`ink_layer` 表）。
    public struct InkLayerInfo: Equatable, Sendable {
        public let id: String
        public let name: String
        public let colorKey: String
        public let sortOrder: Int
        public let visible: Bool
    }

    /// 打开一本书时要的几样：图层、笔记类型、扫描页对齐。
    public struct DocumentView: Equatable, Sendable {
        public let layers: [InkLayerInfo]
        /// 工作区的笔记类型，`meta.note_types` 原样（JSON 数组文本；没有 = nil）。
        public let noteTypes: String?
        /// 扫描页对齐参数，`page_align.payload` 原样（JSON 文本，`SCAN-ALIGN-PLAN.md §3`）；没开 / 没测过 = nil。
        public let align: String?
    }

    /// [contentHash] = 打开的那份 PDF（对齐参数按内容哈希记）。书不在 → `unknownDocument`。
    public func documentView(documentId: String, contentHash: String?) throws -> DocumentView {
        lock.lock(); defer { lock.unlock() }
        try checkOpen()
        return try store.withMirrorDB { db in
            guard try !db.query("SELECT 1 FROM document WHERE id=?", [.text(documentId)]).isEmpty else {
                throw ServerError.unknownDocument(documentId)
            }
            let layers = try db.query("""
            SELECT id, name, color_key, sort_order, visible FROM ink_layer WHERE document_id=? ORDER BY sort_order ASC, created_at ASC
            """, [.text(documentId)]) { r in
                InkLayerInfo(id: r.text(0), name: r.text(1), colorKey: r.text(2), sortOrder: Int(r.int64(3)), visible: r.int64(4) != 0)
            }
            let types = try db.query("SELECT value FROM meta WHERE key='note_types'").first?["value"] as? String
            var align: String?
            if let h = contentHash {
                align = try db.query("SELECT payload FROM page_align WHERE content_hash=? AND enabled=1", [.text(h)]) { r in
                    String(decoding: r.blob(0), as: UTF8.self)
                }.first
            }
            return DocumentView(layers: layers, noteTypes: types, align: align)
        }
    }

    /// 页面上的一条标记：文字笔记（kind 0）、笔迹（2）、高亮（3）。
    public struct PageMark: Equatable, Sendable {
        public let id: String
        public let kind: Int
        public let page: Int
        /// 归一化包围盒 `[x, y, w, h]`（页内 0~1，左上原点）。
        public let anchor: [Double]
        /// `note.payload` 原样（JSON 文本）；笔迹行的 JSON 点已摘掉（`"points":[]`），点在 [points]。
        public let payload: String
        /// 笔迹的点集，一律是 `InkPointsBlob` 格式（`BINARY-INK-PLAN.md §2`）；非笔迹 = nil。
        public let points: Data?
        /// 原样的时间字符串：网页改 / 删这一行时带回 [updatedAt]，服务器据此判断「看到的还是不是最新的」（W3）。
        public let createdAt: String
        public let updatedAt: String
    }

    public static let pageMarkKinds = [0, 2, 3]

    /// 页 [from]...[to]（从 0 起）上的标记。顺序 = 页、创建时刻（与 App 读笔迹同序，后画的盖住先画的）。
    /// [kinds] 只能是 0 / 2 / 3 里的（网页「笔记」列表只要文字笔记：`[0]`）。
    public func pageMarks(documentId: String, from: Int, to: Int, kinds: [Int] = pageMarkKinds) throws -> [PageMark] {
        let kinds = kinds.filter(Self.pageMarkKinds.contains)
        lock.lock(); defer { lock.unlock() }
        try checkOpen()
        guard from <= to else { return [] }
        return try store.withMirrorDB { db in
            guard try !db.query("SELECT 1 FROM document WHERE id=?", [.text(documentId)]).isEmpty else {
                throw ServerError.unknownDocument(documentId)
            }
            return try db.query("""
            SELECT id, kind, page, anchor_x, anchor_y, anchor_w, anchor_h, payload, points, points_at IS updated_at,
                   created_at, updated_at FROM note
            WHERE document_id=? AND kind IN (\(kinds.map(String.init).joined(separator: ","))) AND page BETWEEN ? AND ?
            ORDER BY page ASC, created_at ASC
            """, [.text(documentId), .int(Int64(from)), .int(Int64(to))]) { r -> PageMark? in
                let kind = Int(r.int64(1))
                var payload = r.blob(7)
                var points: Data?
                if kind == 2 {
                    let blob = r.blob(8)
                    guard let ink = Self.inkPoints(payload: payload, blob: blob.isEmpty ? nil : blob, blobValid: r.int64(9) != 0)
                    else { return nil }
                    payload = ink.payload
                    points = ink.points
                }
                return PageMark(id: r.text(0), kind: kind, page: Int(r.int64(2)),
                                anchor: [r.double(3), r.double(4), r.double(5), r.double(6)],
                                payload: String(decoding: payload, as: UTF8.self), points: points,
                                createdAt: r.text(10), updatedAt: r.text(11))
            }.compactMap { $0 }
        }
    }

    /// 一行笔迹的点从哪来，规则同 App（`BINARY-INK-PLAN.md §3`，Mac `InkStrokePayload.read`）：
    /// 二进制有效 → 用它；否则 JSON 里有点 → 用 JSON（编成二进制）；否则有二进制 → 用它；都没有 → 空点集。
    /// 返回摘掉 JSON 点的 payload + 二进制点集。payload 认不出 → nil（App 也当坏行跳过）。
    static func inkPoints(payload: Data, blob: Data?, blobValid: Bool) -> (payload: Data, points: Data)? {
        if blobValid, let blob, InkPointsBlob.decode(blob) != nil, let s = InkPayloadFast.stripPoints(payload) {
            return (s.rest, blob)
        }
        var rest: Data, pts: [SIMD3<Float>]
        if let fast = InkPayloadFast.splitPoints(payload) {
            (rest, pts) = (fast.rest, fast.points)
        } else {
            // 形态不认识：整段解（同 App 回落 `JSONDecoder` 那条），点照 App 的缺省补齐
            guard var obj = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else { return nil }
            let raw = obj["points"] as? [[Double]] ?? []
            pts = raw.map { SIMD3<Float>(Float($0.count > 0 ? $0[0] : 0), Float($0.count > 1 ? $0[1] : 0), Float($0.count > 2 ? $0[2] : 0.5)) }
            obj["points"] = [Any]()
            guard let d = try? JSONSerialization.data(withJSONObject: obj) else { return nil }
            rest = d
        }
        if pts.isEmpty, let blob, InkPointsBlob.decode(blob) != nil { return (rest, blob) }
        return (rest, InkPointsBlob.encode(pts))
    }
}

// MARK: - W3：网页写笔迹 / 文字笔记（方案 `WEB-READER-PLAN.md §3`）

extension HostedWorkspace {

    /// 网页要写的一行（`note` 表；只收文字笔记 kind 0 与页内笔迹 kind 2）。
    public struct WebNoteUpsert: Sendable {
        public var id: String
        public var kind: Int
        public var page: Int
        public var anchor: [Double]
        /// JSON 文本；笔迹的点不在这里（写库时摘成 `"points":[]`），在 [points]。
        public var payload: String
        /// 笔迹点集（`InkPointsBlob`）；文字笔记 = nil。
        public var points: Data?
        /// 网页看到的这一行的 `updated_at`（新建 = nil）。服务器上的已经不是它了 = 别的设备改过，这一行不写。
        public var baseUpdatedAt: String?
        /// 行不在服务器上时用的 `created_at`（撤销删除时恢复原来的叠放顺序）；nil = 现在。
        public var createdAt: String?

        public init(id: String, kind: Int, page: Int, anchor: [Double], payload: String, points: Data?,
                    baseUpdatedAt: String?, createdAt: String?) {
            self.id = id; self.kind = kind; self.page = page; self.anchor = anchor; self.payload = payload
            self.points = points; self.baseUpdatedAt = baseUpdatedAt; self.createdAt = createdAt
        }
    }

    public struct WebNoteDelete: Sendable {
        public var id: String
        /// 网页看到的 `updated_at`；nil = 不核对。
        public var baseUpdatedAt: String?
        public init(id: String, baseUpdatedAt: String?) { self.id = id; self.baseUpdatedAt = baseUpdatedAt }
    }

    public enum WebEditOutcome: String, Sendable {
        /// 写上了（删除：删掉了，或本来就不在）
        case applied
        /// 网页看到的不是最新的（别的设备改过 / 删过）：没写，网页重新取
        case stale
        /// 没写成（推送判定没让写，比如书已经删了）：网页重新取
        case rejected
    }

    public struct WebEditResult: Sendable {
        public let head: UInt64
        /// 这一批写上的行的 `updated_at`（新建的 `created_at` 也是它）：网页记下来，下次改 / 删时带回核对。
        public let updatedAt: String
        public let results: [(id: String, outcome: WebEditOutcome)]
    }

    /// 网页的一批改动：当成一次「基线 = 服务器现状」的推送交给 `pushLocked`——
    /// 删除先归档、修订号、外键带走的子行、三方判定全是推送那一份代码（方案 §3 🔴）。
    /// 格式不对（kind / id / 坐标 / payload / 点集）→ `badRequest`，整批不写。
    public func webEdits(documentId: String, upserts: [WebNoteUpsert], deletes: [WebNoteDelete],
                         deviceName: String, now: Date = .now) throws -> WebEditResult {
        for u in upserts { try Self.validate(u) }
        for d in deletes where UUID(uuidString: d.id) == nil { throw ServerError.badRequest("笔记 id 不是 UUID：\(d.id)") }
        lock.lock(); defer { lock.unlock() }
        try checkOpen()
        return try store.withMirrorDB { db in
            guard try !db.query("SELECT 1 FROM document WHERE id=?", [.text(documentId)]).isEmpty else {
                throw ServerError.unknownDocument(documentId)
            }
            let stamp = ISO.string(now)
            var changes: [SyncWire.RowChange] = []
            var outcomes: [String: WebEditOutcome] = [:]
            var order: [String] = []

            /// 服务器上这一行（只认这本书的文字笔记 / 页内笔迹，别的一律当「不能碰」）。
            func current(_ id: String) throws -> (row: [String: Any]?, ok: Bool) {
                guard let row = try SyncRows.fetch(db, table: "note", rowId: id) else { return (nil, true) }
                let kind = row["kind"] as? Int64 ?? -1
                return (row, row["document_id"] as? String == documentId && (kind == 0 || kind == 2))
            }

            for u in upserts {
                order.append(u.id)
                let (old, ok) = try current(u.id)
                guard ok else { outcomes[u.id] = .rejected; continue }
                if let old, old["updated_at"] as? String != u.baseUpdatedAt { outcomes[u.id] = .stale; continue }
                if old == nil, u.baseUpdatedAt != nil { outcomes[u.id] = .stale; continue }   // 看到过、现在没了 = 别人删了
                var payload = Data(u.payload.utf8)
                if u.kind == 2, let s = InkPayloadFast.stripPoints(payload) { payload = s.rest }
                let row: [String: Any] = [
                    "id": u.id, "document_id": documentId, "kind": Int64(u.kind), "page": Int64(u.page),
                    "anchor_x": u.anchor[0], "anchor_y": u.anchor[1], "anchor_w": u.anchor[2], "anchor_h": u.anchor[3],
                    "payload": payload,
                    "created_at": old?["created_at"] as? String ?? u.createdAt ?? stamp,
                    "updated_at": stamp,
                    "points": u.kind == 2 ? (u.points ?? Data()) as Any : NSNull(),
                    "points_at": u.kind == 2 ? stamp as Any : NSNull(),
                ]
                changes.append(SyncWire.RowChange(table: "note", rowId: u.id, op: .upsert,
                                                  baseFp: SyncRows.fingerprint(table: "note", row: old),
                                                  row: SyncWire.row(fromSQLite: row)))
            }
            for d in deletes {
                order.append(d.id)
                let (old, ok) = try current(d.id)
                guard let old else {
                    outcomes[d.id] = d.baseUpdatedAt == nil ? .applied : .stale
                    continue
                }
                guard ok else { outcomes[d.id] = .rejected; continue }
                if let b = d.baseUpdatedAt, old["updated_at"] as? String != b { outcomes[d.id] = .stale; continue }
                changes.append(SyncWire.RowChange(table: "note", rowId: d.id, op: .delete,
                                                  baseFp: SyncRows.fingerprint(table: "note", row: old), row: nil))
            }

            var head = Self.head(db)
            if !changes.isEmpty {
                let resp = try pushLocked(db, SyncWire.PushRequest(schemaVersion: LibraryStore.schemaVersion, changes: changes),
                                          deviceName: deviceName, now: now)
                head = resp.head
                for r in resp.results { outcomes[r.rowId] = r.outcome == .applied ? .applied : .rejected }
            }
            return WebEditResult(head: head, updatedAt: stamp, results: order.map { ($0, outcomes[$0] ?? .rejected) })
        }
    }

    static func validate(_ u: WebNoteUpsert) throws {
        guard UUID(uuidString: u.id) != nil else { throw ServerError.badRequest("笔记 id 不是 UUID：\(u.id)") }
        guard u.kind == 0 || u.kind == 2 else { throw ServerError.badRequest("网页只能写文字笔记和笔迹（kind \(u.kind)）") }
        guard u.page >= 0, u.anchor.count == 4, u.anchor.allSatisfy(\.isFinite) else {
            throw ServerError.badRequest("页码或位置不对（\(u.id)）")
        }
        guard (try? JSONSerialization.jsonObject(with: Data(u.payload.utf8))) is [String: Any] else {
            throw ServerError.badRequest("payload 不是 JSON 对象（\(u.id)）")
        }
        if u.kind == 2 {
            guard let pts = u.points.flatMap(InkPointsBlob.decode), !pts.isEmpty,
                  pts.allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }) else {
                throw ServerError.badRequest("笔迹没有点或点集格式不对（\(u.id)）")
            }
        } else if u.points != nil {
            throw ServerError.badRequest("文字笔记不带点集（\(u.id)）")
        }
    }
}
