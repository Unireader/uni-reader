import Foundation

/// MCP `links`（`KNOWLEDGE-LINKS-PLAN.md §6`）的主线程那一半：认「看的是谁」、算它此刻链出去的（实时正文），给端点拼 DTO。
extension MCPFacade {

    struct LinksFocus {
        let ws: WorkspaceManager
        /// nil = 整个工作区（`all`）。
        let focus: LinkTarget?
        /// 这个对象自己链出去的（用实时正文 / 当前批注算）。
        let outgoing: [KnowledgeGraph.Link]
        /// 页模式：这一页上的批注 id（指到它们的也算「指到这一页」）。
        let pageAnnotations: Set<String>
    }

    func linksFocus(noteRef: String?, documentId: String?, page: Int?, annotationId: String?, all: Bool,
                    workspacePath: String?) throws -> LinksFocus {
        if all {
            let ws = try manager(workspacePath: workspacePath)
            return LinksFocus(ws: ws, focus: nil, outgoing: [], pageAnnotations: [])
        }
        if let noteRef, !noteRef.isEmpty {
            let (ws, ref) = try markdownTarget(noteRef: noteRef, windowId: nil, workspacePath: workspacePath)
            let text = liveMarkdown(ws, ref).text ?? ""
            return LinksFocus(ws: ws, focus: .note(ref),
                              outgoing: KnowledgeGraph.outgoing(text: text, from: .note(ref), KnowledgeGraph.context(ws)),
                              pageAnnotations: [])
        }
        guard documentId != nil || annotationId != nil || keyController?.tabs.active.docID != nil else {
            // 什么都没给：key 窗口里那篇笔记
            let (ws, ref) = try markdownTarget(noteRef: nil, windowId: nil, workspacePath: workspacePath)
            let text = liveMarkdown(ws, ref).text ?? ""
            return LinksFocus(ws: ws, focus: .note(ref),
                              outgoing: KnowledgeGraph.outgoing(text: text, from: .note(ref), KnowledgeGraph.context(ws)),
                              pageAnnotations: [])
        }
        let t = try writeTarget(documentId: documentId, workspacePath: workspacePath)
        let ws = t.ws, d = t.id
        let ctx = KnowledgeGraph.context(ws)
        // 批注：开着用标签里的（真源），没开读库
        let notes = t.session?.textNotes ?? ws.textNotes(documentId: d)
        let images = t.session?.imageNotes ?? ws.imageNotes(documentId: d)
        let highlights = t.session?.highlights ?? ws.highlights(documentId: d)
        let bookmarks = t.session?.bookmarks ?? ws.bookmarks(documentId: d)
        func out(_ filter: (Int, UUID) -> Bool) -> [KnowledgeGraph.Link] {
            notes.filter { filter($0.page, $0.id) }.flatMap {
                KnowledgeGraph.outgoing(text: $0.text, from: .annotation(documentId: d, id: $0.id.uuidString, page: $0.page), line: 1, ctx)
            } + images.filter { filter($0.page, $0.id) }.flatMap {
                KnowledgeGraph.outgoing(text: $0.caption, from: .annotation(documentId: d, id: $0.id.uuidString, page: $0.page), line: 1, ctx)
            }
        }
        if let annotationId, !annotationId.isEmpty {
            let key = annotationId.trimmingCharacters(in: .whitespaces).uppercased()
            let pages: [(UUID, Int)] = notes.map { ($0.id, $0.page) } + images.map { ($0.id, $0.page) }
                + highlights.map { ($0.id, $0.page) } + bookmarks.map { ($0.id, $0.page) }
            let hits = key.count >= 8 ? pages.filter { $0.0.uuidString.hasPrefix(key) } : []
            guard hits.count == 1 else {
                throw MCPToolError(hits.isEmpty ? "annotation '\(annotationId)' not found in “\(t.title)”; take ids from list_annotations"
                                                : "annotation id prefix '\(annotationId)' matches several; pass the full id")
            }
            let (id, pg) = hits[0]
            return LinksFocus(ws: ws, focus: .annotation(documentId: d, id: id.uuidString, page: pg),
                              outgoing: out { $1 == id }, pageAnnotations: [])
        }
        if let page {
            let p = try PageNo.index(page, pageCount: t.pageCount)
            var ids = Set<String>()
            for (i, pg) in notes.map({ ($0.id, $0.page) }) + images.map({ ($0.id, $0.page) })
                + highlights.map({ ($0.id, $0.page) }) + bookmarks.map({ ($0.id, $0.page) }) where pg == p { ids.insert(i.uuidString) }
            return LinksFocus(ws: ws, focus: .document(id: d, page: p), outgoing: out { pg, _ in pg == p }, pageAnnotations: ids)
        }
        return LinksFocus(ws: ws, focus: .document(id: d, page: nil), outgoing: out { _, _ in true }, pageAnnotations: [])
    }

    /// 一端（笔记 / 书 / 书页 / 批注）→ DTO。
    func linkEndDTO(_ ws: WorkspaceManager, _ t: LinkTarget?) -> MCPObject {
        guard let t else { return ["kind": "broken"] }
        switch t {
        case .note(let ref):
            return ["kind": "note", "note_ref": ref.key, "title": ws.note(ref: ref)?.title ?? ref.title,
                    "exists": ws.note(ref: ref) != nil, "link": link(ws, markdown: ref.key)]
        case .document(let d, let p):
            var o: MCPObject = ["kind": p == nil ? "document" : "page", "document_id": d,
                                "title": ws.document(id: d)?.title ?? d, "exists": ws.document(id: d) != nil,
                                "link": link(ws, doc: d, page: p.map(PageNo.external))]
            if let p { o["page"] = PageNo.external(p) }
            return o
        case .annotation(let d, let a, let p):
            var o: MCPObject = ["kind": "annotation", "document_id": d, "annotation_id": a,
                                "title": ws.document(id: d)?.title ?? d, "exists": ws.document(id: d) != nil,
                                "link": link(ws, doc: d, page: p.map(PageNo.external), note: UUID(uuidString: a))]
            if let p { o["page"] = PageNo.external(p) }
            return o
        }
    }

    func linkDTO(_ ws: WorkspaceManager, _ l: KnowledgeGraph.Link) -> MCPObject {
        var o: MCPObject = ["from": linkEndDTO(ws, l.from), "to": linkEndDTO(ws, l.to), "text": l.raw, "context": l.context]
        if let line = l.line, case .note = l.from { o["line"] = line }
        return o
    }

    /// 端点的一句话描述（文字输出用）。
    func linkEndText(_ ws: WorkspaceManager, _ t: LinkTarget?) -> String {
        guard let t else { return "(broken)" }
        switch t {
        case .note(let ref): return "note “\(ws.note(ref: ref)?.title ?? ref.title)” (\(ref.key))"
        case .document(let d, let p):
            let title = ws.document(id: d)?.title ?? d
            return p.map { "“\(title)” p.\(PageNo.external($0)) (document_id \(d))" } ?? "book “\(title)” (document_id \(d))"
        case .annotation(let d, let a, let p):
            let title = ws.document(id: d)?.title ?? d
            return "annotation \(a.prefix(8)) in “\(title)”" + (p.map { " p.\(PageNo.external($0))" } ?? "")
        }
    }
}
