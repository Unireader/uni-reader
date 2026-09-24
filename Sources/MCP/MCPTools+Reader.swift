import Foundation

/// 批 2：`get_current_view` / `goto` / `list_annotations`（方案 §7.10 ~ §7.12）。
extension MCPTools {
    /// `get_current_view` 的文字结果里 Markdown 正文最多给多少行。
    static let currentViewMarkdownLines = 300

    static func getCurrentView() -> MCPTool {
        MCPTool(
            name: "get_current_view",
            title: "What the user is looking at",
            description: "What the active tab in the key window (or a given window) is showing. For a PDF: position, zoom, chapter and selection. For a Markdown note: identity and current live editor text, including edits not autosaved yet.",
            inputSchema: MCPSchema.object([
                "window_id": MCPSchema.string("Window id from get_state. Default: the key window."),
            ]),
            outputSchema: MCPSchema.object([
                "window_id": MCPSchema.string("window id"), "session_id": MCPSchema.string("tab / session id"),
                "workspace": workspaceDTOSchema,
                "content_type": MCPSchema.enumeration(["empty", "pdf", "markdown"], "kind of content in the active tab"),
                "document_id": MCPSchema.nullable(MCPSchema.string("library document id; null for Markdown or an empty tab")), "title": MCPSchema.string("title"),
                "page": MCPSchema.integer("page at the top of the viewport, 1-based"), "frac": MCPSchema.number("position inside that page, 0 top … 1 bottom"),
                "link": MCPSchema.string("unireader:// link that reopens exactly this position"),
                "page_count": MCPSchema.integer("pages"), "zoom": MCPSchema.number("zoom relative to fit-width"),
                "canvas_mode": MCPSchema.boolean("canvas mode on"), "chapter": MCPSchema.string("outline entry the page falls in"),
                // 🔴 返回里有的键这里必须都有：schema 是 additionalProperties:false，Kimi 的 MCP 客户端严格校验，
                // 漏一个整个调用判失败（2026-09-18 漏了 file_missing，Claude Code 不校验所以一直没暴露）
                "file_missing": MCPSchema.boolean("the PDF file cannot be found on disk"),
                "selection": MCPSchema.object(["page": MCPSchema.integer("1-based"), "text": MCPSchema.string("selected text"),
                                               "rects": MCPSchema.array(of: MCPSchema.array(of: MCPSchema.number("0…1")))]),
                "markdown": markdownDTOSchema(includeText: true),
            ]),
            tier: .read
        ) { _, args in
            let windowId = try args.string("window_id")
            let v = try await MainActor.run { try MCPFacade.shared.currentView(windowId: windowId) }
            var lines: [String] = []
            if let note = v["markdown"] as? MCPObject {
                lines.append("Current Markdown note: “\(note["title"] ?? "")”")
                lines.append("source \(note["source"] ?? "") · path \(note["relative_path"] ?? "") · note_ref \(note["ref"] ?? "")")
                lines.append("session_id \(v["session_id"] ?? "") · window_id \(v["window_id"] ?? "")")
                if let link = note["link"] as? String { lines.append("link \(link)") }
                // 长笔记只给开头一段（结构化结果里仍是全文），其余让 Agent 用 read_markdown 按需读
                let text = (note["text"] as? String) ?? ""
                let total = (note["line_count"] as? Int) ?? 0
                if total > Self.currentViewMarkdownLines {
                    let head = MCPMarkdownText.lines(text).prefix(Self.currentViewMarkdownLines).joined(separator: "\n")
                    lines.append("revision \(note["revision"] ?? "") · \(total) lines; showing the first \(Self.currentViewMarkdownLines) — use read_markdown (outline / search / offset) for the rest, edit_markdown to change part of it")
                    lines.append("\n--- Markdown text (lines 1-\(Self.currentViewMarkdownLines) of \(total)) ---\n\(head)")
                } else {
                    lines.append("revision \(note["revision"] ?? "") · \(total) lines · use edit_markdown to change part of it")
                    lines.append("\n--- Markdown text ---\n\(text)")
                }
            } else if let title = v["title"] as? String {
                lines.append("“\(title)” — page \(v["page"] ?? 1)/\(v["page_count"] ?? 0) (\(String(format: "%.0f", ((v["frac"] as? Double) ?? 0) * 100))% down the page) · zoom \(String(format: "%.2f", (v["zoom"] as? Double) ?? 1))")
                if let ch = v["chapter"] as? String { lines.append("Chapter: \(ch)") }
                if let sel = v["selection"] as? MCPObject { lines.append("Selected on page \(sel["page"] ?? 0): “\(sel["text"] ?? "")”") }
                else { lines.append("No text selected.") }
                lines.append("document_id \(v["document_id"] ?? "") · session_id \(v["session_id"] ?? "") · window_id \(v["window_id"] ?? "")")
                if let link = v["link"] as? String { lines.append("link \(link)") }
            } else {
                lines.append("The window has an empty tab. window_id \(v["window_id"] ?? "")")
            }
            return MCPToolResult(text: lines.joined(separator: "\n"), structured: v)
        }
    }

    static func goto() -> MCPTool {
        MCPTool(
            name: "goto",
            title: "Scroll to a page",
            description: "Scroll a reader tab to a page (and optionally a position inside it). Goes into the jump history so the user can jump back. Defaults to the key window's active tab; use session_id or document_id to target another tab.",
            inputSchema: MCPSchema.object([
                "page": MCPSchema.integer("Target page, 1-based", min: 1),
                "frac": MCPSchema.number("Position inside the page, 0 = top … 1 = bottom (default 0)"),
                "session_id": MCPSchema.string("Target tab (from get_state)"),
                "document_id": MCPSchema.string("Target the tab showing this document"),
                "window_id": MCPSchema.string("Target this window's active tab"),
                "activate": MCPSchema.boolean("Bring UniReader and the window to front (default false: don't steal focus from the terminal)", default: false),
            ], required: ["page"]),
            outputSchema: MCPSchema.object([
                "session_id": MCPSchema.string("tab"), "window_id": MCPSchema.string("window"),
                "document_id": MCPSchema.string("document"), "page": MCPSchema.integer("1-based"), "frac": MCPSchema.number("0…1"),
                "link": MCPSchema.string("unireader:// link to this position"),
            ]),
            tier: .navigate
        ) { ctx, args in
            if ctx.fromInAppAgent, !AgentFollow.enabled { return MCPToolResult(text: AgentFollow.declined, structured: [:]) }
            let page = try args.int("page") ?? 1
            let frac: Double
            if let f = args.raw["frac"] as? NSNumber { frac = f.doubleValue } else { frac = 0 }
            let sessionId = try args.string("session_id")
            let documentId = try args.string("document_id")
            let windowId = try args.string("window_id")
            let activate = try args.bool("activate", default: false)
            let r = try await MainActor.run {
                try MCPFacade.shared.goto(page: page, frac: frac, sessionId: sessionId, documentId: documentId, windowId: windowId, activate: activate)
            }
            return MCPToolResult(text: "Scrolled to page \(page) · session_id \(r["session_id"] ?? "")", structured: r)
        }
    }

    static let annotationKinds = ["note", "highlight", "bookmark", "image_note", "ai_thread", "scratch_pad", "ink"]

    static func listAnnotations() -> MCPTool {
        MCPTool(
            name: "list_annotations",
            title: "List notes, highlights and bookmarks",
            description: "Everything the user has added to a document: text notes (with the quoted passage and the note text), highlights, bookmarks, image notes, AI chat threads, scratch pads, and how many handwritten strokes are on each page (counts only). Every item carries a `link` (unireader://…) that opens UniReader at that exact spot — paste it into notes written elsewhere (Obsidian etc.). Defaults to the document in the key window.",
            inputSchema: MCPSchema.object([
                "document_id": MCPSchema.string("Library document id. Omit for the key window's document."),
                "workspace": MCPSchema.string("Workspace .unrd path, only when the id is ambiguous."),
                "kinds": MCPSchema.array(of: MCPSchema.enumeration(annotationKinds, "kind"), "Which kinds to include. Default: all."),
                "pages": ["anyOf": [["type": "integer"], ["type": "string"]], "description": "Limit to these pages, e.g. \"10-20\". Default: whole document."],
            ]),
            outputSchema: MCPSchema.object([
                "document_id": MCPSchema.string("document"), "title": MCPSchema.string("title"),
                "link": MCPSchema.string("unireader:// link that opens the document"),
                "notes": MCPSchema.array(of: MCPSchema.object([
                    "id": MCPSchema.string("note id"), "page": MCPSchema.integer("1-based"), "rect": MCPSchema.array(of: MCPSchema.number("0…1"), "[x, y, w, h]"),
                    "quote": MCPSchema.string("quoted passage"), "text": MCPSchema.string("the note"), "type": MCPSchema.nullable(MCPSchema.string("note type name or null")),
                    "display": MCPSchema.enumeration(["tap", "hover", "always"], "how the bubble opens"),
                    "style": MCPSchema.enumeration(["fill", "underline", "box"], "how the quoted passage is marked"),
                    "color": MCPSchema.string("#RRGGBB when the note has an explicit mark color; absent = the note type's color"),
                    "source": MCPSchema.object(["kind": MCPSchema.string("ai / agent"), "provider": MCPSchema.string("who wrote it"), "url": MCPSchema.string("link")]),
                    "link": MCPSchema.string("unireader:// link: opens the document at this note and expands its bubble"),
                    "created_at": MCPSchema.string("ISO-8601"), "updated_at": MCPSchema.string("ISO-8601")])),
                "highlights": MCPSchema.array(of: MCPSchema.object([
                    "id": MCPSchema.string("id"), "page": MCPSchema.integer("1-based"), "rect": MCPSchema.array(of: MCPSchema.number("0…1")),
                    "quote": MCPSchema.string("highlighted text"), "color": MCPSchema.string("#RRGGBB"),
                    "style": MCPSchema.enumeration(["fill", "underline", "box"], "how it is drawn"), "created_at": MCPSchema.string("ISO-8601"),
                    "link": MCPSchema.string("unireader:// link to this highlight")])),
                "bookmarks": MCPSchema.array(of: MCPSchema.object([
                    "id": MCPSchema.string("id"), "page": MCPSchema.integer("1-based"), "frac": MCPSchema.number("0…1"), "title": MCPSchema.string("name"),
                    "created_at": MCPSchema.string("ISO-8601"), "link": MCPSchema.string("unireader:// link to this bookmark")])),
                "image_notes": MCPSchema.array(of: MCPSchema.object([
                    "id": MCPSchema.string("id"), "page": MCPSchema.integer("1-based"), "rect": MCPSchema.array(of: MCPSchema.number("0…1")),
                    "caption": MCPSchema.string("caption"), "image_sha256": MCPSchema.string("image id; the file is <workspace>/Images/<sha256>.<ext>"), "from": ["type": "object"],
                    "link": MCPSchema.string("unireader:// link: opens the document at this image note and expands it")])),
                "ai_threads": MCPSchema.array(of: MCPSchema.object([
                    "id": MCPSchema.string("id"), "page": MCPSchema.integer("1-based"), "provider": MCPSchema.string("chatgpt / …"),
                    "url": MCPSchema.string("conversation link"), "title": MCPSchema.string("title"), "state": MCPSchema.enumeration(["ok", "suspect"], "link health"),
                    "created_at": MCPSchema.string("ISO-8601"),   // 返回里一直有，schema 漏了（Kimi 严格校验时报错）
                    "link": MCPSchema.string("unireader:// link to the page it is pinned on")])),
                "scratch_pads": MCPSchema.array(of: MCPSchema.object([
                    "id": MCPSchema.string("id"), "page": MCPSchema.integer("1-based"), "title": MCPSchema.string("title"),
                    "anchor": MCPSchema.array(of: MCPSchema.number("0…1"), "[x, y] pin position"),
                    "link": MCPSchema.string("unireader:// link to the page it is pinned on")])),
                "ink": MCPSchema.object(["pages": MCPSchema.array(of: MCPSchema.object(["page": MCPSchema.integer("1-based"), "count": MCPSchema.integer("strokes")])),
                                         "total": MCPSchema.integer("strokes in the document")]),
            ]),
            tier: .read
        ) { _, args in
            let documentId = try args.string("document_id")
            let wsPath = try args.string("workspace")
            var kinds = Set(annotationKinds)
            if let raw = args.raw["kinds"] {
                guard let list = raw as? [String] else { throw MCPInvalidParams("kinds must be an array of strings") }
                let bad = list.filter { !annotationKinds.contains($0) }
                if !bad.isEmpty { throw MCPInvalidParams("unknown kinds: \(bad.joined(separator: ", ")); valid: \(annotationKinds.joined(separator: ", "))") }
                kinds = Set(list)
            }
            var pageSet: Set<Int>? = nil
            if let spec = try args.pages("pages") {
                // 筛选不限页数；上限用 10 万页兜住乱写的范围
                pageSet = Set(try PageNo.parse(spec, pageCount: 100_000, limit: Int.max))
            }
            let (json, text) = try await MainActor.run {
                try MCPFacade.shared.annotations(documentId: documentId, workspacePath: wsPath, kinds: kinds, pages: pageSet)
            }
            return MCPToolResult(text: text, structured: json)
        }
    }
}
