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
            description: "Add a text note (annotation) to a page. Anchor it to a passage by giving `quote` (the exact text on that page; it is located and the note pins to it), or to an area with `rect`, or to the top of the page with neither. Notes written this way are marked as coming from an agent.",
            inputSchema: MCPSchema.object(writeTargetProperties.merging([
                "page": MCPSchema.integer("Page, 1-based", min: 1),
                "text": MCPSchema.string("The note body (Markdown is rendered in the bubble). Math: $…$ inline, $$…$$ on its own line for a block; \\(…\\) and \\[…\\] are NOT rendered. Required unless quote is given."),
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
                guard let found = try await MCPDocReader.shared.locate(path: path, store: t.ws.store, contentHash: t.contentHash, index: idx, quote: quote) else {
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
            description: "Highlight a passage on a page. `quote` must be the exact text on that page (copy it from read_pages); it is located with the same engine as ⌘F, so line breaks inside the passage are fine. `style` picks how it is drawn: fill (highlighter, default), underline, or box (outline only). Fails, rather than guessing, when the text is not found.",
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
            guard let rects = try await MCPDocReader.shared.locate(path: path, store: t.ws.store, contentHash: t.contentHash, index: idx, quote: quote) else {
                throw MCPToolError("quote not found on page \(page); use read_pages to copy the exact text")
            }
            let r = try await MainActor.run {
                try MCPFacade.shared.addHighlight(t, page: page, quote: quote, rects: rects, color: color, colorName: colorArg, style: style)
            }
            return MCPToolResult(text: "Highlighted “\(quote.prefix(60))\(quote.count > 60 ? "…" : "")” on page \(page) · id \(r["id"] ?? "")", structured: r)
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
