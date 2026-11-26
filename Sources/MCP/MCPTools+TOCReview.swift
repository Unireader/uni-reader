import Foundation

/// 自建目录（`set_toc`）与回顾点（`list_reviews` / `add_reviews` / `update_reviews` / `delete_reviews`）。
/// 方案 `TOC-REVIEW-PLAN.md §4`。读目录仍走 `get_document`（有自建目录时默认返回它，`toc_source` 说明是哪份）。
extension MCPTools {

    static func registerTOCReview(into server: MCPServer) {
        let c = server.catalog
        c.register(setTOC())
        c.register(listReviews())
        c.register(addReviews())
        c.register(updateReviews())
        c.register(deleteReviews())
    }

    static let maxTOCEntries = 2000
    static let maxReviewItems = 200

    // MARK: set_toc

    static func setTOC() -> MCPTool {
        let entry = MCPSchema.object([
            "title": MCPSchema.string("Entry title as it should appear in the contents"),
            "page": MCPSchema.integer("Page where the entry starts, 1-based", min: 1),
            "y": MCPSchema.number("Where on that page it starts: 0 = top … 1 = bottom (default 0)"),
            "level": MCPSchema.integer("1 = top level (chapter), 2 = section, … up to \(CustomTOCItem.maxLevel + 1)", min: 1, max: CustomTOCItem.maxLevel + 1),
        ], required: ["title", "page"])
        return MCPTool(
            name: "set_toc",
            title: "Set the custom table of contents",
            description: "Write a table of contents for a PDF without changing the PDF file: it is stored in the workspace as the document's custom contents, shown in UniReader's Contents page in place of the PDF's own outline (the user can switch back), and returned by get_document. Use it when a PDF has no outline (typical for scans) or a poor one: read the contents pages or chapter headings first (read_pages / search_text / render_page), then send the whole list in reading order. Each call replaces the whole custom contents; the previous one goes to Recently Deleted. An empty list removes the custom contents. Page numbers are the PDF's page numbers (1-based), not the numbers printed on the pages — check the offset first.",
            inputSchema: MCPSchema.object(writeTargetProperties.merging([
                "entries": MCPSchema.array(of: entry, "All entries in reading order (at most \(maxTOCEntries)); [] clears the custom contents"),
            ]) { a, _ in a }, required: ["entries"]),
            outputSchema: MCPSchema.object([
                "document_id": MCPSchema.string("document"),
                "count": MCPSchema.integer("entries written"),
                "replaced": MCPSchema.integer("entries in the previous custom contents (moved to Recently Deleted)"),
            ]),
            tier: .write
        ) { _, args in
            guard let list = args.raw["entries"] as? [MCPObject] else { throw MCPInvalidParams("entries must be an array of objects") }
            guard list.count <= maxTOCEntries else { throw MCPInvalidParams("at most \(maxTOCEntries) entries per call") }
            var raw: [(title: String, page: Int, y: Double, level: Int)] = []
            for (i, o) in list.enumerated() {
                let a = MCPArgs(o)
                let at = "entries[\(i)]: "
                let title = (try a.string("title") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !title.isEmpty else { throw MCPInvalidParams("\(at)title must not be empty") }
                guard let page = try a.int("page"), page >= 1 else { throw MCPInvalidParams("\(at)page must be ≥ 1") }
                let y = (o["y"] as? NSNumber)?.doubleValue ?? 0
                guard y >= 0, y <= 1 else { throw MCPInvalidParams("\(at)y must be between 0 and 1") }
                let level = try a.int("level") ?? 1
                guard level >= 1, level <= CustomTOCItem.maxLevel + 1 else {
                    throw MCPInvalidParams("\(at)level must be 1…\(CustomTOCItem.maxLevel + 1)")
                }
                raw.append((title, page, y, level))
            }
            let docId = try args.string("document_id"), wsPath = try args.string("workspace")
            let r = try await MainActor.run {
                let t = try MCPFacade.shared.writeTarget(documentId: docId, workspacePath: wsPath)
                return try MCPFacade.shared.setTOC(t, entries: raw)
            }
            let n = r["count"] as? Int ?? 0
            return MCPToolResult(text: n == 0 ? "Custom contents removed; the PDF's own outline is shown again."
                                              : "Custom contents written: \(n) entries.", structured: r)
        }
    }

    // MARK: 回顾点

    static var reviewDTOSchema: MCPObject {
        MCPSchema.object([
            "id": MCPSchema.string("review point id"),
            "document_id": MCPSchema.string("document"), "document_title": MCPSchema.string("document title"),
            "page": MCPSchema.integer("1-based"), "y": MCPSchema.number("0 = top … 1 = bottom of the page"),
            "tag": MCPSchema.string("tag (several review points can share one)"),
            "remark": MCPSchema.string("the user's remark"),
            "period": MCPSchema.integer("review period number: the point is due in this period"),
            "reviews": MCPSchema.integer("times reviewed so far"),
            "last_reviewed_at": MCPSchema.nullable(MCPSchema.string("ISO 8601")),
            "link": MCPSchema.string("unireader:// link to the spot"),
        ])
    }

    static func listReviews() -> MCPTool {
        MCPTool(
            name: "list_reviews",
            title: "List review points",
            description: "List the user's review points (回顾点): spots in PDFs marked for periodic review, each with a tag, an optional remark and a period number n (\"look at it again in review period n\"; no dates). Several points usually share a tag. Filter by document, tag and period. Sorted by period, then document and page.",
            inputSchema: MCPSchema.object([
                "workspace": MCPSchema.string("Workspace .unrd path. Omit for the key window's workspace."),
                "document_id": MCPSchema.string("Only this document"),
                "tag": MCPSchema.string("Only this tag (exact)"),
                "period": MCPSchema.integer("Only this period", min: 1),
                "max_period": MCPSchema.integer("Only periods up to this one (what is due by then)", min: 1),
            ]),
            outputSchema: MCPSchema.object([
                "count": MCPSchema.integer("points returned"),
                "tags": MCPSchema.array(of: MCPSchema.string("tag"), "all tags used in the workspace"),
                "reviews": MCPSchema.array(of: reviewDTOSchema),
            ]),
            tier: .read
        ) { _, args in
            let wsPath = try args.string("workspace"), docId = try args.string("document_id"), tag = try args.string("tag")
            let period = try args.int("period"), maxPeriod = try args.int("max_period")
            let r = try await MainActor.run {
                try MCPFacade.shared.listReviews(workspacePath: wsPath, documentId: docId, tag: tag, period: period, maxPeriod: maxPeriod)
            }
            return MCPToolResult(text: r.text, structured: r.object)
        }
    }

    static func addReviews() -> MCPTool {
        let item = MCPSchema.object([
            "page": MCPSchema.integer("Page, 1-based", min: 1),
            "y": MCPSchema.number("Position on the page, 0 = top … 1 = bottom (default 0)"),
            "tag": MCPSchema.string("Tag (required)"),
            "remark": MCPSchema.string("Remark (optional)"),
            "period": MCPSchema.integer("Review period number, default 1", min: 1),
        ], required: ["page", "tag"])
        return MCPTool(
            name: "add_reviews",
            title: "Add review points",
            description: "Add review points to one PDF: each marks a spot to look at again in review period n, with a tag (several points can share it) and an optional remark. Add them only when the user asks.",
            inputSchema: MCPSchema.object(writeTargetProperties.merging([
                "items": MCPSchema.array(of: item, "Points to add (at most \(maxReviewItems))"),
            ]) { a, _ in a }, required: ["items"]),
            outputSchema: MCPSchema.object([
                "count": MCPSchema.integer("points added"),
                "reviews": MCPSchema.array(of: reviewDTOSchema),
            ]),
            tier: .write
        ) { _, args in
            guard let list = args.raw["items"] as? [MCPObject], !list.isEmpty else { throw MCPInvalidParams("items must be a non-empty array of objects") }
            guard list.count <= maxReviewItems else { throw MCPInvalidParams("at most \(maxReviewItems) items per call") }
            var items: [(page: Int, y: Double, tag: String, remark: String, period: Int)] = []
            for (i, o) in list.enumerated() {
                let a = MCPArgs(o)
                let at = "items[\(i)]: "
                guard let page = try a.int("page"), page >= 1 else { throw MCPInvalidParams("\(at)page must be ≥ 1") }
                let y = (o["y"] as? NSNumber)?.doubleValue ?? 0
                guard y >= 0, y <= 1 else { throw MCPInvalidParams("\(at)y must be between 0 and 1") }
                let tag = ReviewMark.cleanTag(try a.string("tag") ?? "")
                guard !tag.isEmpty else { throw MCPInvalidParams("\(at)tag must not be empty") }
                let period = try a.int("period") ?? 1
                guard period >= 1 else { throw MCPInvalidParams("\(at)period must be ≥ 1") }
                items.append((page, y, tag, (try a.string("remark") ?? "").trimmingCharacters(in: .whitespacesAndNewlines), period))
            }
            let docId = try args.string("document_id"), wsPath = try args.string("workspace")
            let r = try await MainActor.run {
                let t = try MCPFacade.shared.writeTarget(documentId: docId, workspacePath: wsPath)
                return try MCPFacade.shared.addReviews(t, items: items)
            }
            return MCPToolResult(text: "Added \(r["count"] ?? 0) review point(s).", structured: r)
        }
    }

    static func updateReviews() -> MCPTool {
        let item = MCPSchema.object([
            "id": MCPSchema.string("Review point id from list_reviews (full id or its 8-character prefix)"),
            "tag": MCPSchema.string("New tag"),
            "remark": MCPSchema.string("New remark (\"\" clears it)"),
            "period": MCPSchema.integer("Set the period number", min: 1),
            "advance": MCPSchema.integer("Mark it reviewed and move it this many periods later (counts one review)", min: 1),
        ], required: ["id"])
        return MCPTool(
            name: "update_reviews",
            title: "Change review points",
            description: "Change review points in place: tag, remark, period, or mark one as reviewed with advance (period += advance, review count + 1). All changes in one call apply together; if any id is unknown, nothing is changed. Change them only when the user asks.",
            inputSchema: MCPSchema.object([
                "workspace": MCPSchema.string("Workspace .unrd path. Omit for the key window's workspace."),
                "updates": MCPSchema.array(of: item, "Changes (at most \(maxReviewItems)); fields left out stay as they are"),
            ], required: ["updates"]),
            outputSchema: MCPSchema.object([
                "count": MCPSchema.integer("points changed"),
                "reviews": MCPSchema.array(of: reviewDTOSchema),
            ]),
            tier: .write
        ) { _, args in
            guard let list = args.raw["updates"] as? [MCPObject], !list.isEmpty else { throw MCPInvalidParams("updates must be a non-empty array of objects") }
            guard list.count <= maxReviewItems else { throw MCPInvalidParams("at most \(maxReviewItems) updates per call") }
            var ups: [MCPFacade.ReviewUpdate] = []
            for (i, o) in list.enumerated() {
                let a = MCPArgs(o)
                let at = "updates[\(i)]: "
                var u = MCPFacade.ReviewUpdate(id: try a.requiredString("id"))
                if let t = try a.string("tag") {
                    u.tag = ReviewMark.cleanTag(t)
                    guard u.tag?.isEmpty == false else { throw MCPInvalidParams("\(at)tag must not be empty") }
                }
                u.remark = try a.string("remark")
                if let p = try a.int("period") { guard p >= 1 else { throw MCPInvalidParams("\(at)period must be ≥ 1") }; u.period = p }
                if let k = try a.int("advance") { guard k >= 1 else { throw MCPInvalidParams("\(at)advance must be ≥ 1") }; u.advance = k }
                ups.append(u)
            }
            let wsPath = try args.string("workspace")
            let r = try await MainActor.run { try MCPFacade.shared.updateReviews(workspacePath: wsPath, updates: ups) }
            return MCPToolResult(text: "Changed \(r["count"] ?? 0) review point(s).", structured: r)
        }
    }

    static func deleteReviews() -> MCPTool {
        MCPTool(
            name: "delete_reviews",
            title: "Delete review points",
            description: "Delete review points by id (from list_reviews; full id or 8-character prefix). They go to UniReader's Recently Deleted, one item per document, and can be put back. If any id is not found, nothing is deleted. Delete only when the user asks.",
            inputSchema: MCPSchema.object([
                "workspace": MCPSchema.string("Workspace .unrd path. Omit for the key window's workspace."),
                "ids": MCPSchema.array(of: MCPSchema.string("review point id"), "At most \(maxReviewItems)"),
            ], required: ["ids"]),
            outputSchema: MCPSchema.object(["count": MCPSchema.integer("points deleted")]),
            tier: .delete
        ) { _, args in
            guard let ids = args.raw["ids"] as? [String], !ids.isEmpty else { throw MCPInvalidParams("ids must be a non-empty array of strings") }
            guard ids.count <= maxReviewItems else { throw MCPInvalidParams("at most \(maxReviewItems) ids per call") }
            let wsPath = try args.string("workspace")
            let r = try await MainActor.run { try MCPFacade.shared.deleteReviews(workspacePath: wsPath, ids: ids) }
            return MCPToolResult(text: "Deleted \(r["count"] ?? 0) review point(s) (moved to Recently Deleted).", structured: r)
        }
    }
}

// MARK: - Facade（主线程）

extension MCPFacade {

    /// 自建目录树的 DTO（get_document 用；比 PDF 目录多 id / level / y）。
    func customTOCDTO(_ items: [CustomTOCItem]) -> [MCPObject] {
        let levels = Dictionary(items.map { ($0.id, $0.level) }, uniquingKeysWith: { a, _ in a })
        func dto(_ e: TOCEntry) -> MCPObject {
            ["id": e.id.uuidString, "title": e.label, "page": e.pageIndex.map { PageNo.external($0) } ?? NSNull(),
             "y": e.frac, "level": (levels[e.id] ?? 0) + 1, "children": e.children.map(dto)]
        }
        return CustomTOCItem.entries(items).map(dto)
    }

    /// 某篇文档的自建目录（没开工作区 / 不是库里的文档 = 空）。
    func customTOC(store: LibraryStore?, documentId: String?) -> [CustomTOCItem] {
        guard let store, let documentId,
              let ws = WorkspaceRegistry.shared.openManagers.first(where: { $0.store === store }) else { return [] }
        return ws.customTOC(documentId: documentId)
    }

    func setTOC(_ t: WriteTarget, entries: [(title: String, page: Int, y: Double, level: Int)]) throws -> MCPObject {
        var items: [CustomTOCItem] = []
        for (i, e) in entries.enumerated() {
            guard e.page <= t.pageCount else {
                throw MCPInvalidParams("entries[\(i)]: page \(e.page) is beyond the last page (\(t.pageCount)). Nothing was changed.")
            }
            items.append(CustomTOCItem(page: e.page - 1, frac: e.y, level: e.level - 1, title: e.title, seq: i))
        }
        let old = t.ws.customTOC(documentId: t.id).count
        do { try t.ws.replaceCustomTOC(documentId: t.id, items: items) }
        catch { throw MCPToolError("\(error.localizedDescription)") }
        // 开着这篇的标签：写了新的就切到自建目录看
        for tab in sessionsShowing(t.id) where !items.isEmpty { tab.session.tocShowsPDF = false }
        return ["document_id": t.id, "count": items.count, "replaced": old]
    }

    private func reviewWorkspace(_ path: String?) throws -> WorkspaceManager {
        if let path, !path.isEmpty { return try manager(workspacePath: path) }
        if let k = keyController { return k.workspace }
        if let m = WorkspaceRegistry.shared.openManagers.first { return m }
        throw MCPToolError("no workspace is open; call open_workspace first")
    }

    private func reviewDTO(_ ws: WorkspaceManager, _ m: ReviewMark) -> MCPObject {
        ["id": m.id.uuidString, "document_id": m.documentId, "document_title": ws.document(id: m.documentId)?.title ?? "",
         "page": PageNo.external(m.page), "y": m.frac, "tag": m.tag, "remark": m.remark, "period": m.period,
         "reviews": m.reviews, "last_reviewed_at": m.lastReviewedAt.map { ISO.string($0) } ?? NSNull(),
         "link": link(ws, doc: m.documentId, page: PageNo.external(m.page), frac: m.frac)]
    }

    func listReviews(workspacePath: String?, documentId: String?, tag: String?, period: Int?, maxPeriod: Int?) throws -> (object: MCPObject, text: String) {
        let ws = try reviewWorkspace(workspacePath)
        var all = ws.allReviewMarks()
        let tags = Array(Set(all.map(\.tag))).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        if let documentId, !documentId.isEmpty {
            guard ws.document(id: documentId) != nil else { throw MCPToolError("document '\(documentId)' not found in workspace '\(ws.name)'") }
            all = all.filter { $0.documentId == documentId }
        }
        if let tag { all = all.filter { $0.tag == tag } }
        if let period { all = all.filter { $0.period == period } }
        if let maxPeriod { all = all.filter { $0.period <= maxPeriod } }
        let titles = Dictionary(ws.documents.map { ($0.id, $0.title) }, uniquingKeysWith: { a, _ in a })
        all.sort { a, b in
            if a.period != b.period { return a.period < b.period }
            if a.documentId != b.documentId { return (titles[a.documentId] ?? "") < (titles[b.documentId] ?? "") }
            return ReviewMark.before(a, b)
        }
        var lines = ["\(all.count) review point(s)" + (tags.isEmpty ? "" : " · tags: \(tags.joined(separator: ", "))")]
        for m in all {
            var l = "- [\(m.id.uuidString.prefix(8))] period \(m.period) · \(m.tag) · “\(titles[m.documentId] ?? "")” p.\(PageNo.external(m.page))"
            if m.reviews > 0 { l += " · reviewed \(m.reviews)×" }
            if !m.remark.isEmpty { l += " — \(m.remark.flattenedQuote.prefix(120))" }
            lines.append(l)
        }
        return (["count": all.count, "tags": tags, "reviews": all.map { reviewDTO(ws, $0) }], lines.joined(separator: "\n"))
    }

    func addReviews(_ t: WriteTarget, items: [(page: Int, y: Double, tag: String, remark: String, period: Int)]) throws -> MCPObject {
        var marks: [ReviewMark] = []
        for (i, it) in items.enumerated() {
            guard it.page <= t.pageCount else {
                throw MCPInvalidParams("items[\(i)]: page \(it.page) is beyond the last page (\(t.pageCount)). Nothing was added.")
            }
            marks.append(ReviewMark(documentId: t.id, page: it.page - 1, frac: it.y, tag: it.tag,
                                    remark: it.remark, period: it.period))
        }
        t.ws.saveReviewMarks(marks)
        return ["count": marks.count, "reviews": marks.map { reviewDTO(t.ws, $0) }]
    }

    struct ReviewUpdate {
        var id: String
        var tag: String?
        var remark: String?
        var period: Int?
        var advance: Int?
    }

    /// id（全长或 8 位前缀）→ 回顾点，与输入一一对应；找不到 / 有歧义就整批报错。
    private func resolveReviews(_ ws: WorkspaceManager, _ raw: [String], verb: String) throws -> [ReviewMark] {
        let all = ws.allReviewMarks()
        var out: [ReviewMark] = [], missing: [String] = [], ambiguous: [String] = []
        for r in raw {
            let key = r.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            let hits = key.count >= 8 ? all.filter { $0.id.uuidString.hasPrefix(key) } : []
            if hits.isEmpty { missing.append(r) }
            else if hits.count > 1 { ambiguous.append(r) }
            else { out.append(hits[0]) }
        }
        if !missing.isEmpty { throw MCPToolError("review points not found: \(missing.joined(separator: ", ")). Take ids from list_reviews. Nothing was \(verb).") }
        if !ambiguous.isEmpty { throw MCPToolError("these id prefixes match more than one review point: \(ambiguous.joined(separator: ", ")); pass the full ids. Nothing was \(verb).") }
        return out
    }

    func updateReviews(workspacePath: String?, updates: [ReviewUpdate]) throws -> MCPObject {
        let ws = try reviewWorkspace(workspacePath)
        let found = try resolveReviews(ws, updates.map(\.id), verb: "changed")
        var byId: [UUID: ReviewMark] = [:]
        var order: [UUID] = []
        for (u, m0) in zip(updates, found) {
            var m = byId[m0.id] ?? m0          // 同一条出现两次：在前一次改过的基础上接着改
            if let t = u.tag { m.tag = t }
            if let r = u.remark { m.remark = r.trimmingCharacters(in: .whitespacesAndNewlines) }
            if let p = u.period { m.period = p }
            if let k = u.advance { m.advance(by: k) }
            m.updatedAt = .now
            byId[m.id] = m
            if !order.contains(m.id) { order.append(m.id) }
        }
        let changed = order.compactMap { byId[$0] }
        ws.saveReviewMarks(changed)
        return ["count": changed.count, "reviews": changed.map { reviewDTO(ws, $0) }]
    }

    func deleteReviews(workspacePath: String?, ids: [String]) throws -> MCPObject {
        let ws = try reviewWorkspace(workspacePath)
        var seen = Set<UUID>()
        let picked = try resolveReviews(ws, ids, verb: "deleted").filter { seen.insert($0.id).inserted }
        let n = ws.deleteReviewMarks(picked)
        guard n == picked.count else {
            throw MCPToolError("only \(n) of \(picked.count) could be moved to Recently Deleted; the rest were not deleted")
        }
        return ["count": n]
    }
}
