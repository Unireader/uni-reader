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
    }

    static let pageMarkKinds = [0, 2, 3]

    /// 页 [from]...[to]（从 0 起）上的标记。顺序 = 页、创建时刻（与 App 读笔迹同序，后画的盖住先画的）。
    public func pageMarks(documentId: String, from: Int, to: Int) throws -> [PageMark] {
        lock.lock(); defer { lock.unlock() }
        try checkOpen()
        guard from <= to else { return [] }
        return try store.withMirrorDB { db in
            guard try !db.query("SELECT 1 FROM document WHERE id=?", [.text(documentId)]).isEmpty else {
                throw ServerError.unknownDocument(documentId)
            }
            return try db.query("""
            SELECT id, kind, page, anchor_x, anchor_y, anchor_w, anchor_h, payload, points, points_at IS updated_at FROM note
            WHERE document_id=? AND kind IN (0, 2, 3) AND page BETWEEN ? AND ? ORDER BY page ASC, created_at ASC
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
                                payload: String(decoding: payload, as: UTF8.self), points: points)
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
