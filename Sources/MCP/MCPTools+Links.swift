import Foundation

/// MCP `links`（`KNOWLEDGE-LINKS-PLAN.md §6`）：笔记、书页、批注之间的关联——一个对象链到哪、被谁引用；或整个工作区的全部关联。
extension MCPTools {

    static func linksTool() -> MCPTool {
        let end = MCPSchema.object([
            "kind": MCPSchema.enumeration(["note", "document", "page", "annotation", "broken"], "what this end is"),
            "note_ref": MCPSchema.string("note: note_ref"),
            "document_id": MCPSchema.string("document / page / annotation: the PDF"),
            "page": MCPSchema.integer("page / annotation: page, 1-based (annotations only when known)"),
            "annotation_id": MCPSchema.string("annotation: id"),
            "title": MCPSchema.string("note title or book title"),
            "exists": MCPSchema.boolean("it is still in the workspace"),
            "link": MCPSchema.string("unireader:// link that opens it"),
        ])
        let item = MCPSchema.object([
            "from": end, "to": end,
            "text": MCPSchema.string("the link as written, e.g. [[马原#page=12]] or a unireader:// URL"),
            "context": MCPSchema.string("the line it is written in"),
            "line": MCPSchema.integer("from a note: line number, 1-based"),
        ])
        return MCPTool(
            name: "links",
            title: "Links between notes, book pages and annotations",
            description: "The knowledge links of a workspace (one workspace = one subject): which Markdown notes, PDF pages and annotations refer to each other. Links are whatever is written in note and annotation text — [[note name]], [[book title]], [[book title#page=12]] (a page of a PDF in the library) and unireader:// links (e.g. to one annotation); an annotation also belongs to its page. Give one thing to see what it links to (outgoing) and what links to it (incoming): note_ref for a note, document_id (+ page) for a book or one page — a page also counts links to the annotations on it — or annotation_id (+ document_id). Or set all to list every link in the workspace (to map a subject). To add a link, write it into a note with edit_markdown (only when the user asks); UniReader never adds links by itself.",
            inputSchema: MCPSchema.object([
                "note_ref": MCPSchema.string("A Markdown note (note_ref or name)."),
                "document_id": MCPSchema.string("A PDF; with page = one page; with annotation_id = that annotation's document. Default: the key window's PDF."),
                "page": MCPSchema.integer("Page of document_id, 1-based. Omit for the whole book.", min: 1),
                "annotation_id": MCPSchema.string("An annotation id from list_annotations (full or 8-character prefix)."),
                "all": MCPSchema.boolean("List every link in the workspace instead", default: false),
                "include_broken": MCPSchema.boolean("With all: also list links that do not resolve", default: false),
                "limit": MCPSchema.integer("Max links per list (default 200, max 1000)", min: 1, max: 1000),
                "workspace": MCPSchema.string("Workspace .unrd path. Default: the key window's workspace."),
            ]),
            outputSchema: MCPSchema.object([
                "focus": MCPSchema.nullable(end),
                "outgoing": MCPSchema.array(of: item, "links written in it (for a page or book: in its annotations)"),
                "incoming": MCPSchema.array(of: item, "links pointing to it"),
                "links": MCPSchema.array(of: item, "all: every link"),
                "outgoing_total": MCPSchema.integer("all outgoing"), "incoming_total": MCPSchema.integer("all incoming"),
                "links_total": MCPSchema.integer("all: every link"),
                "truncated": MCPSchema.boolean("a list was cut at limit"),
            ]),
            tier: .read
        ) { _, args in
            let noteRef = try args.string("note_ref"), docId = try args.string("document_id"), page = try args.int("page")
            let annId = try args.string("annotation_id"), all = try args.bool("all", default: false)
            let withBroken = try args.bool("include_broken", default: false)
            let limit = min(max(try args.int("limit") ?? 200, 1), 1000), ws = try args.string("workspace")
            let f = try await MainActor.run {
                try MCPFacade.shared.linksFocus(noteRef: noteRef, documentId: docId, page: page, annotationId: annId,
                                                all: all, workspacePath: ws)
            }
            let every = await KnowledgeGraph.load(f.ws, wait: 15)
            let incoming: [KnowledgeGraph.Link]
            switch f.focus {
            case .note(let ref)?: incoming = KnowledgeGraph.backlinks(every, note: ref)
            case .document(let d, let p?)?:
                incoming = KnowledgeGraph.toPage(every, documentId: d, page: p, annotationIDs: f.pageAnnotations)
                    .filter { if case .annotation(d, _, p) = $0.from { return false }; return true }
            case .document(let d, nil)?: incoming = every.filter { $0.to?.documentID == d && $0.from.documentID != d }
            case .annotation(_, let a, _)?: incoming = KnowledgeGraph.toAnnotation(every, id: a)
            case nil: incoming = []
            }
            let listAll = f.focus == nil ? every.filter { withBroken || $0.to != nil } : []
            return try await MainActor.run {
                let F = MCPFacade.shared
                var o: MCPObject = ["focus": f.focus.map { F.linkEndDTO(f.ws, $0) as Any } ?? NSNull(),
                                    "outgoing": f.outgoing.prefix(limit).map { F.linkDTO(f.ws, $0) },
                                    "incoming": incoming.prefix(limit).map { F.linkDTO(f.ws, $0) },
                                    "outgoing_total": f.outgoing.count, "incoming_total": incoming.count,
                                    "truncated": max(f.outgoing.count, incoming.count, listAll.count) > limit]
                var lines: [String] = []
                let show: @MainActor (KnowledgeGraph.Link) -> String = { l in
                    "- \(F.linkEndText(f.ws, l.from)) → \(F.linkEndText(f.ws, l.to)): \(l.raw)"
                }
                if f.focus == nil {
                    o["links"] = listAll.prefix(limit).map { F.linkDTO(f.ws, $0) }
                    o["links_total"] = listAll.count
                    lines.append("\(listAll.count) link(s) in this workspace:")
                    lines += listAll.prefix(limit).map(show)
                } else {
                    lines.append("Links of \(F.linkEndText(f.ws, f.focus)): \(f.outgoing.count) outgoing, \(incoming.count) incoming")
                    if !f.outgoing.isEmpty { lines.append("Outgoing:"); lines += f.outgoing.prefix(limit).map(show) }
                    if !incoming.isEmpty { lines.append("Incoming:"); lines += incoming.prefix(limit).map(show) }
                }
                return MCPToolResult(text: lines.joined(separator: "\n"), structured: o)
            }
        }
    }
}
