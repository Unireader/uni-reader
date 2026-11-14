import CoreGraphics
import Foundation

/// 批 3：`add_bookmark` / `add_note` / `add_highlight`（方案 §7.13 / §9）。
/// 三个都是 `.write`——写入开关关着时 `MCPCatalog.call` 在这之前就拦了。
extension MCPTools {
    /// 归一化矩形参数 `[x, y, w, h]`（0…1，左上原点）。
    static func rectArg(_ args: MCPArgs, _ key: String) throws -> CGRect? {
        guard let v = args.raw[key], !(v is NSNull) else { return nil }
        guard let a = v as? [NSNumber], a.count == 4 else { throw MCPInvalidParams("argument '\(key)' must be [x, y, w, h] with values 0…1") }
        let d = a.map(\.doubleValue)
        guard d.allSatisfy({ $0 >= 0 && $0 <= 1 }), d[2] > 0, d[3] > 0 else {
            throw MCPInvalidParams("argument '\(key)' must be [x, y, w, h] with values 0…1 and positive size")
        }
        return CGRect(x: d[0], y: d[1], width: d[2], height: d[3])
    }

    static var writeTargetProperties: [String: MCPObject] {
        ["document_id": MCPSchema.string("Library document id. Omit for the document in the key window."),
         "workspace": MCPSchema.string("Workspace .unrd path, only when the id is ambiguous across open workspaces.")]
    }

    static func addBookmark() -> MCPTool {
        MCPTool(
            name: "add_bookmark",
            title: "Add a bookmark",
            description: "Add a named bookmark at a page (and optionally a position inside it). Bookmarks appear in the outline next to the PDF's own entries.",
            inputSchema: MCPSchema.object(writeTargetProperties.merging([
                "page": MCPSchema.integer("Page, 1-based", min: 1),
                "frac": MCPSchema.number("Position inside the page, 0 = top … 1 = bottom (default 0)"),
                "title": MCPSchema.string("Bookmark name (required, not empty)"),
            ]) { a, _ in a }, required: ["page", "title"]),
            outputSchema: MCPSchema.object([
                "id": MCPSchema.string("bookmark id"), "document_id": MCPSchema.string("document"),
                "page": MCPSchema.integer("1-based"), "frac": MCPSchema.number("0…1"), "title": MCPSchema.string("name"),
                "via": MCPSchema.enumeration(["session", "library"], "written through the open tab or straight into the library"),
            ]),
            tier: .write
        ) { _, args in
            let page = try args.int("page") ?? 1
            let frac = (args.raw["frac"] as? NSNumber)?.doubleValue ?? 0
            let title = try args.requiredString("title")
            let docId = try args.string("document_id"), wsPath = try args.string("workspace")
            let r = try await MainActor.run {
                let t = try MCPFacade.shared.writeTarget(documentId: docId, workspacePath: wsPath)
                return try MCPFacade.shared.addBookmark(t, page: page, frac: frac, title: title)
            }
            return MCPToolResult(text: "Added bookmark “\(title)” at page \(page) · id \(r["id"] ?? "")", structured: r)
        }
    }

    static func addNote() -> MCPTool {
        MCPTool(
            name: "add_note",
            title: "Add a text note",
            description: "Add a text note to a PDF page: an annotation pinned to a spot on the page, the same thing the user makes with right-click › Add Note Here or by selecting text and adding a note (批注 / 文字笔记 in the UI). Not for Markdown notes, which are separate .md files — write those with edit_markdown. Anchor it to a passage by giving `quote` (the exact text on that page; it is located and the note pins to it), or to an area with `rect`, or to the top of the page with neither. Notes written this way are marked as coming from an agent.",
            inputSchema: MCPSchema.object(writeTargetProperties.merging([
                "page": MCPSchema.integer("Page, 1-based", min: 1),
                "text": MCPSchema.string("The note body (Markdown is rendered in the bubble). \(mathWriting) Required unless quote is given."),
                "quote": MCPSchema.string("Passage on that page to attach the note to (must exist on the page, case-insensitive)."),
                "rect": MCPSchema.array(of: MCPSchema.number("0…1"), "[x, y, w, h] normalized area on the page, top-left origin; used when there is no quote."),
                "type": MCPSchema.string("Note type name as shown in UniReader (must already exist). Omit for the generic type."),
                "display": MCPSchema.enumeration(["tap", "hover", "always"], "How the bubble opens on the page", default: "tap"),
            ]) { a, _ in a }, required: ["page"]),
            outputSchema: MCPSchema.object([
                "id": MCPSchema.string("note id"), "document_id": MCPSchema.string("document"), "page": MCPSchema.integer("1-based"),
                "rect": MCPSchema.array(of: MCPSchema.number("0…1"), "anchor [x, y, w, h]"), "type": MCPSchema.nullable(MCPSchema.string("type name or null")),
                "via": MCPSchema.enumeration(["session", "library"], "written through the open tab or straight into the library"),
            ]),
            tier: .write
        ) { ctx, args in
            let page = try args.int("page") ?? 1
            let text = try args.string("text") ?? ""
            let quote = (try args.string("quote") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let rect = try rectArg(args, "rect")
            let typeName = try args.string("type")
            let displayRaw = try args.string("display") ?? "tap"
            guard let display = NoteDisplay(rawValue: displayRaw) else { throw MCPInvalidParams("display must be tap, hover or always") }
            let docId = try args.string("document_id"), wsPath = try args.string("workspace")

            let t = try await MainActor.run { try MCPFacade.shared.writeTarget(documentId: docId, workspacePath: wsPath) }
            var rects: [CGRect]? = nil
            if !quote.isEmpty {
                guard let path = t.path else { throw MCPToolError("the document's file is missing, so the quote cannot be located; pass rect or omit quote") }
                let idx = try PageNo.index(page, pageCount: t.pageCount)
                guard let found = try await MCPDocReader.shared.locate(path: path, store: t.ws.store, contentHash: t.contentHash, index: idx, quote: quote, align: t.align) else {
                    throw MCPToolError("quote not found on page \(page); use read_pages to copy the exact text, or pass rect instead")
                }
                rects = found
            }
            let client = ctx.clientName
            let r = try await MainActor.run {
                try MCPFacade.shared.addNote(t, page: page, text: text, quote: quote, rects: rects, anchorRect: rect,
                                             typeName: typeName, display: display, client: client)
            }
            return MCPToolResult(text: "Added note on page \(page)\(quote.isEmpty ? "" : " at “\(quote.prefix(40))…”") · id \(r["id"] ?? "")", structured: r)
        }
    }

    static func addHighlight() -> MCPTool {
        let names = Highlight.palette.map(\.name)
        let styles = HighlightStyle.allCases.map(\.rawValue)
        return MCPTool(
            name: "add_highlight",
            title: "Highlight a passage",
            description: "Highlight a passage on a page. `quote` must be the exact text on that page (copy it from read_pages); it is located in UniReader's OCR text when the page has it (same boxes as a highlight the user makes by hand), otherwise in the PDF's own text like ⌘F, so line breaks inside the passage are fine. `style` picks how it is drawn: fill (highlighter, default), underline, box (outline only), or strike (a line through the middle of the text). Fails, rather than guessing, when the text is not found.",
            inputSchema: MCPSchema.object(writeTargetProperties.merging([
                "page": MCPSchema.integer("Page, 1-based", min: 1),
                "quote": MCPSchema.string("Exact passage to highlight"),
                "color": MCPSchema.string("Highlight color: one of \(names.joined(separator: ", ")) or #RRGGBB (default \(names[0]))"),
                "style": MCPSchema.enumeration(styles, "How to draw it (default fill)"),
            ]) { a, _ in a }, required: ["page", "quote"]),
            outputSchema: MCPSchema.object([
                "id": MCPSchema.string("highlight id"), "document_id": MCPSchema.string("document"), "page": MCPSchema.integer("1-based"),
                "rect": MCPSchema.array(of: MCPSchema.number("0…1"), "bounding box [x, y, w, h]"), "color": MCPSchema.string("color name or #RRGGBB"),
                "style": MCPSchema.enumeration(styles, "how it is drawn"),
                "via": MCPSchema.enumeration(["session", "library"], "written through the open tab or straight into the library"),
            ]),
            tier: .write
        ) { _, args in
            let page = try args.int("page") ?? 1
            let quote = try args.requiredString("quote").trimmingCharacters(in: .whitespacesAndNewlines)
            let colorArg = try args.string("color") ?? names[0]
            let color: InkColor
            if let item = Highlight.palette.first(where: { $0.name.caseInsensitiveCompare(colorArg) == .orderedSame }) {
                color = item.color
            } else if let c = Self.parseHex(colorArg) {
                color = c
            } else {
                throw MCPInvalidParams("color must be one of \(names.joined(separator: ", ")) or #RRGGBB")
            }
            let styleArg = try args.string("style") ?? HighlightStyle.fill.rawValue
            guard let style = HighlightStyle(rawValue: styleArg.lowercased()) else {
                throw MCPInvalidParams("style must be one of \(styles.joined(separator: ", "))")
            }
            let docId = try args.string("document_id"), wsPath = try args.string("workspace")
            let t = try await MainActor.run { try MCPFacade.shared.writeTarget(documentId: docId, workspacePath: wsPath) }
            guard let path = t.path else { throw MCPToolError("the document's file is missing, so the passage cannot be located") }
            let idx = try PageNo.index(page, pageCount: t.pageCount)
            guard let rects = try await MCPDocReader.shared.locate(path: path, store: t.ws.store, contentHash: t.contentHash, index: idx, quote: quote, align: t.align) else {
                throw MCPToolError("quote not found on page \(page); use read_pages to copy the exact text")
            }
            let r = try await MainActor.run {
                try MCPFacade.shared.addHighlight(t, page: page, quote: quote, rects: rects, color: color, colorName: colorArg, style: style)
            }
            return MCPToolResult(text: "Highlighted “\(quote.prefix(60))\(quote.count > 60 ? "…" : "")” on page \(page) · id \(r["id"] ?? "")", structured: r)
        }
    }

    /// 删批注（2026-10-03 用户要求加；方案 §21）。`.delete` 级：`destructiveHint: true`，同受写入开关管。
    static func deleteAnnotations() -> MCPTool {
        MCPTool(
            name: "delete_annotations",
            title: "Delete annotations",
            description: "Delete highlights, text notes, bookmarks or image notes from one document by id. Take the ids from list_annotations (the full id, or the 8-character prefix shown in its text output). Everything deleted in one call goes to UniReader's Recently Deleted as one item the user can put back; if any id is not found, nothing is deleted. Handwriting, documents and Markdown notes cannot be deleted with this tool.",
            inputSchema: MCPSchema.object(writeTargetProperties.merging([
                "ids": MCPSchema.array(of: MCPSchema.string("annotation id"), "Ids to delete (at most \(maxDeleteIds))"),
            ]) { a, _ in a }, required: ["ids"]),
            outputSchema: MCPSchema.object([
                "document_id": MCPSchema.string("document"), "count": MCPSchema.integer("how many were deleted"),
                "trash_item": MCPSchema.string("name of the Recently Deleted item they went into"),
                "deleted": MCPSchema.array(of: MCPSchema.object([
                    "id": MCPSchema.string("id"),
                    "kind": MCPSchema.enumeration(["note", "highlight", "bookmark", "image_note"], "what it was"),
                    "page": MCPSchema.integer("1-based"), "label": MCPSchema.string("quote, note text, bookmark title or caption")])),
                "via": MCPSchema.enumeration(["session", "library"], "removed from the open tab(s) or straight from the library"),
            ]),
            tier: .delete
        ) { _, args in
            guard let list = args.raw["ids"] as? [Any], !list.isEmpty else {
                throw MCPInvalidParams("ids must be a non-empty array of strings")
            }
            let ids = try list.map { v -> String in
                guard let s = v as? String else { throw MCPInvalidParams("ids must be strings") }
                return s
            }
            guard ids.count <= maxDeleteIds else { throw MCPInvalidParams("at most \(maxDeleteIds) ids per call") }
            let docId = try args.string("document_id"), wsPath = try args.string("workspace")
            let r = try await MainActor.run {
                let t = try MCPFacade.shared.writeTarget(documentId: docId, workspacePath: wsPath)
                return try MCPFacade.shared.deleteAnnotations(t, ids: ids)
            }
            let n = r["count"] as? Int ?? 0
            let lines = ((r["deleted"] as? [MCPObject]) ?? []).map {
                "- p.\($0["page"] ?? "") \($0["kind"] ?? "") [\(($0["id"] as? String ?? "").prefix(8))] \($0["label"] ?? "")"
            }
            return MCPToolResult(text: (["Deleted \(n) annotation(s); they are in Recently Deleted as “\(r["trash_item"] ?? "")”."] + lines)
                                    .joined(separator: "\n"), structured: r)
        }
    }

    static let maxDeleteIds = 200

    static func updateDocument() -> MCPTool {
        MCPTool(
            name: "update_document",
            title: "Rename a document or change its group",
            description: "Change how a PDF appears in the workspace library: its display title (the file on disk keeps its name), and/or its group (\"\" = no group; a new group name creates the group). Several documents can be moved to a group at once with document_ids. Do this only when the user asks.",
            inputSchema: MCPSchema.object([
                "document_id": MCPSchema.string("Library document id from list_documents."),
                "document_ids": MCPSchema.array(of: MCPSchema.string("document id"), "Several documents (group change only)."),
                "title": MCPSchema.string("New display title (one document only)."),
                "group": MCPSchema.string("Group to put the document(s) in; \"\" = no group."),
                "workspace": MCPSchema.string("Workspace .unrd path. Default: the open workspace that has these documents."),
            ]),
            outputSchema: MCPSchema.object([
                "workspace": workspaceDTOSchema,
                "documents": MCPSchema.array(of: documentDTOSchema, "the documents after the change"),
                "groups": MCPSchema.array(of: MCPSchema.string("group name"), "all groups in the workspace now"),
            ]),
            tier: .write
        ) { _, args in
            var ids: [String] = []
            if let one = try args.string("document_id"), !one.isEmpty { ids.append(one) }
            if let many = args.raw["document_ids"] as? [Any] {
                for v in many {
                    guard let s = v as? String else { throw MCPInvalidParams("document_ids must be strings") }
                    if !ids.contains(s) { ids.append(s) }
                }
            }
            let title = try args.string("title"), group = try args.string("group"), ws = try args.string("workspace")
            guard title != nil || group != nil else { throw MCPInvalidParams("pass title, group, or both") }
            let r = try await MainActor.run {
                try MCPFacade.shared.updateDocuments(ids: ids, title: title, group: group, workspacePath: ws)
            }
            let docs = (r["documents"] as? [MCPObject]) ?? []
            let lines = docs.map { d -> String in
                let g = (d["group"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "(no group)"
                return "- “\(d["title"] ?? "")” · group \(g) · \(d["document_id"] ?? d["id"] ?? "")"
            }
            return MCPToolResult(text: (["Updated \(docs.count) document(s):"] + lines).joined(separator: "\n"), structured: r)
        }
    }

    static func updateAnnotations() -> MCPTool {
        let names = Highlight.palette.map(\.name)
        let styles = HighlightStyle.allCases.map(\.rawValue)
        let item = MCPSchema.object([
            "id": MCPSchema.string("Annotation id from list_annotations (full id or its 8-character prefix)."),
            "text": MCPSchema.string("Text note: the new note text. Image note: the new caption."),
            "title": MCPSchema.string("Bookmark: the new title (must not be empty)."),
            "color": MCPSchema.string("Text note or highlight: \(names.joined(separator: ", ")) or #RRGGBB. For a text note, \"none\" goes back to the note type's color."),
            "style": MCPSchema.enumeration(styles, "Text note or highlight: how the selection is drawn"),
            "type": MCPSchema.nullable(MCPSchema.string("Text note: note type name as shown in UniReader (must already exist); \"\" or null = the generic type.")),
            "display": MCPSchema.enumeration(["tap", "hover", "always"], "Text note or image note: how the bubble opens on the page"),
        ], required: ["id"])
        return MCPTool(
            name: "update_annotations",
            title: "Change annotations",
            description: "Change existing annotations of one document in place, keeping their ids and links: a text note's text, color, style, type or display; a highlight's color or style; a bookmark's title; an image note's caption or display. Take ids from list_annotations. All changes in one call apply together; if any id is unknown or a field does not fit that kind, nothing is changed. Position, quote and handwriting cannot be changed (delete and re-add instead). Change annotations only when the user asks.",
            inputSchema: MCPSchema.object(writeTargetProperties.merging([
                "updates": MCPSchema.array(of: item, "Changes to apply (at most \(maxDeleteIds)); fields left out stay as they are"),
            ]) { a, _ in a }, required: ["updates"]),
            outputSchema: MCPSchema.object([
                "document_id": MCPSchema.string("document"), "count": MCPSchema.integer("annotations changed"),
                "updated": MCPSchema.array(of: MCPSchema.object([
                    "id": MCPSchema.string("id"),
                    "kind": MCPSchema.enumeration(["note", "highlight", "bookmark", "image_note"], "what it is"),
                    "page": MCPSchema.integer("1-based"),
                    "fields": MCPSchema.array(of: MCPSchema.string("field changed")),
                    "title": MCPSchema.string("bookmark: its title now"),
                    "link": MCPSchema.string("unireader:// link to it"),
                ])),
                "via": MCPSchema.enumeration(["session", "library"], "changed in the open tab(s) or straight in the library"),
            ]),
            tier: .write
        ) { _, args in
            guard let list = args.raw["updates"] as? [MCPObject], !list.isEmpty else {
                throw MCPInvalidParams("updates must be a non-empty array of objects")
            }
            guard list.count <= maxDeleteIds else { throw MCPInvalidParams("at most \(maxDeleteIds) updates per call") }
            var updates: [MCPFacade.AnnotationUpdate] = []
            for (i, raw) in list.enumerated() {
                let a = MCPArgs(raw)
                let at = list.count > 1 ? "updates[\(i)]: " : ""
                var u = MCPFacade.AnnotationUpdate(id: try a.requiredString("id"))
                u.text = try a.string("text")
                u.title = try a.string("title")
                if let c = try a.string("color") {
                    let v = c.trimmingCharacters(in: .whitespaces)
                    if v.isEmpty || v.lowercased() == "none" {
                        u.color = .some(nil)
                    } else if let p = Highlight.palette.first(where: { $0.name.caseInsensitiveCompare(v) == .orderedSame }) {
                        u.color = .some(p.color); u.colorName = p.name
                    } else if let hex = parseHex(v) {
                        u.color = .some(hex); u.colorName = v
                    } else {
                        throw MCPInvalidParams("\(at)color must be one of \(names.joined(separator: ", ")), #RRGGBB or none")
                    }
                }
                if let st = try a.string("style") {
                    guard let style = HighlightStyle(rawValue: st.lowercased()) else {
                        throw MCPInvalidParams("\(at)style must be one of \(styles.joined(separator: ", "))")
                    }
                    u.style = style
                }
                if raw.keys.contains("type") {
                    u.typeName = .some(raw["type"] is NSNull ? nil : try a.string("type"))
                }
                if let d = try a.string("display") {
                    guard let display = NoteDisplay(rawValue: d) else { throw MCPInvalidParams("\(at)display must be tap, hover or always") }
                    u.display = display
                }
                updates.append(u)
            }
            let docId = try args.string("document_id"), wsPath = try args.string("workspace")
            let r = try await MainActor.run {
                let t = try MCPFacade.shared.writeTarget(documentId: docId, workspacePath: wsPath)
                return try MCPFacade.shared.updateAnnotations(t, updates: updates)
            }
            let lines = ((r["updated"] as? [MCPObject]) ?? []).map {
                "- p.\($0["page"] ?? "") \($0["kind"] ?? "") [\(($0["id"] as? String ?? "").prefix(8))] " + (($0["fields"] as? [String]) ?? []).joined(separator: ", ")
            }
            return MCPToolResult(text: (["Changed \(r["count"] ?? 0) annotation(s); ids and links stay the same."] + lines).joined(separator: "\n"),
                                 structured: r)
        }
    }

    /// `#RRGGBB` → `InkColor`（a = 1）。
    static func parseHex(_ s: String) -> InkColor? {
        var hex = s.trimmingCharacters(in: .whitespaces)
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard hex.count == 6, let v = UInt32(hex, radix: 16) else { return nil }
        return InkColor(r: Double((v >> 16) & 0xFF), g: Double((v >> 8) & 0xFF), b: Double(v & 0xFF), a: 1)
    }
}
