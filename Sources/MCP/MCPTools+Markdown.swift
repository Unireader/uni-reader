import Foundation

/// Markdown 笔记的读写工具（2026-09-24 细化，`MCP-PLAN.md §19`）：
/// - `list_markdown_notes`：拿 `note_ref`；
/// - `read_markdown`：按行分页（带行号）/ 行内搜索 / 标题大纲，任何一篇都能读，不必开着；
/// - `edit_markdown`：code agent 式局部修改（原文精确匹配替换、按行号插入），不用重吐整篇；
/// - `update_markdown`：整篇替换（带 revision 乐观锁），只留给「真要重写全文」的场合。
/// 纯逻辑在 `MCPMarkdownText`，碰 App 状态的在 `MCPFacade`（写入同一条路：原子写文件 + 推回所有编辑器）。
extension MCPTools {
    /// 三个工具共用的「哪一篇」参数。
    static var markdownTargetProperties: [String: MCPObject] {
        ["note_ref": MCPSchema.string("Which note: note_ref from list_markdown_notes / get_state (also accepts the note's name). Omit for the active note in the key window (including a note mini-window)."),
         "window_id": MCPSchema.string("Without note_ref: use this window's active tab. With note_ref: resolve it in this window's workspace."),
         "workspace": MCPSchema.string("Workspace .unrd path, only when the note lives in a workspace other than the key window's.")]
    }

    static func listMarkdownNotes() -> MCPTool {
        MCPTool(
            name: "list_markdown_notes",
            title: "List Markdown notes",
            description: "List the workspace's Markdown notes (built-in Notes folder and referenced external folders) with their note_ref, for read_markdown / edit_markdown.",
            inputSchema: MCPSchema.object([
                "workspace": MCPSchema.string("Workspace .unrd path. Default: the key window's workspace."),
                "source": MCPSchema.string("Only this note source (id or name, see sources in the result)"),
                "folder": MCPSchema.string("Only notes under this folder, relative to the source root, e.g. \"数学/微积分\""),
                "query": MCPSchema.string("Only notes whose title or path contains this text (case-insensitive)"),
                "limit": MCPSchema.integer("Maximum notes to return (default 200)", min: 1, max: 2000),
            ]),
            outputSchema: MCPSchema.object([
                "workspace": workspaceDTOSchema,
                "sources": MCPSchema.array(of: MCPSchema.object([
                    "id": MCPSchema.string("source id (prefix of note_ref)"), "name": MCPSchema.string("display name"),
                    "kind": MCPSchema.enumeration(["workspace", "reference"], "workspace-owned or referenced external folder")])),
                "notes": MCPSchema.array(of: MCPSchema.object([
                    "ref": MCPSchema.string("note_ref"), "title": MCPSchema.string("note title"),
                    "source": MCPSchema.string("source name"),
                    "source_kind": MCPSchema.enumeration(["workspace", "reference", "unknown"], "source kind"),
                    "relative_path": MCPSchema.string("path relative to the source root"),
                    "link": MCPSchema.string("unireader:// link that activates this note"),
                    "is_active_tab": MCPSchema.boolean("shown as the active tab of some reader window")])),
                "total": MCPSchema.integer("notes matching the filters"),
                "truncated": MCPSchema.boolean("more notes matched than were returned"),
            ]),
            tier: .read
        ) { _, args in
            let ws = try args.string("workspace"), source = try args.string("source")
            let folder = try args.string("folder"), query = try args.string("query")
            let limit = min(2000, max(1, try args.int("limit") ?? 200))
            let r = try await MainActor.run {
                try MCPFacade.shared.markdownNotes(workspacePath: ws, source: source, folder: folder, query: query, limit: limit)
            }
            let notes = (r["notes"] as? [MCPObject]) ?? []
            var lines = ["\(r["total"] ?? 0) Markdown note(s)" + ((r["truncated"] as? Bool) == true ? ", showing \(notes.count)" : "") + ":"]
            for n in notes {
                let active = (n["is_active_tab"] as? Bool) == true ? " · active tab" : ""
                lines.append("- \(n["title"] ?? "") — \(n["source"] ?? "")/\(n["relative_path"] ?? "") · note_ref \(n["ref"] ?? "")\(active)")
            }
            return MCPToolResult(text: lines.joined(separator: "\n"), structured: r)
        }
    }

    static func readMarkdown() -> MCPTool {
        MCPTool(
            name: "read_markdown",
            title: "Read a Markdown note",
            description: "Read a Markdown note's current text (the live editor text when it is open, including edits not autosaved yet). Default: lines with line-number prefixes (\"   12<TAB>text\"), paged by offset/limit. With search: only the lines containing that text. With outline: the heading list with line numbers. For long notes, read the outline or search first, then read just the lines you need. The line-number prefix is not part of the note — never copy it into edit_markdown.",
            inputSchema: MCPSchema.object(markdownTargetProperties.merging([
                "offset": MCPSchema.integer("First line to return, 1-based (default 1)", min: 1),
                "limit": MCPSchema.integer("Maximum lines to return (default 400, at most 2000; output is also capped at about \(MCPFacade.markdownReadMaxChars) characters)", min: 1, max: 2000),
                "search": MCPSchema.string("Return only the lines that contain this text, with their line numbers (case-insensitive unless case_sensitive)"),
                "case_sensitive": MCPSchema.boolean("For search: match case exactly (default false)", default: false),
                "outline": MCPSchema.boolean("Return the heading outline (ATX # headings, code blocks skipped) instead of text (default false)", default: false),
            ]) { a, _ in a }),
            outputSchema: MCPSchema.object([
                "ref": MCPSchema.string("note_ref"), "title": MCPSchema.string("note title"),
                "source": MCPSchema.string("note source name"),
                "source_kind": MCPSchema.enumeration(["workspace", "reference", "unknown"], "workspace-owned or referenced external folder"),
                "relative_path": MCPSchema.string("path relative to the note source"),
                "link": MCPSchema.string("unireader:// link that activates this note"),
                "file_missing": MCPSchema.boolean("the Markdown file cannot be read from disk"),
                "revision": MCPSchema.string("SHA-256 of the whole current text; optional expected_revision for edit_markdown, required for update_markdown"),
                "line_count": MCPSchema.integer("lines in the whole note"),
                "characters": MCPSchema.integer("characters in the whole note"),
                "open_in_editor": MCPSchema.boolean("the note is open in an editor right now"),
                "unsaved_edits": MCPSchema.boolean("the editor holds edits that are not on disk yet (they are included here)"),
                "mode": MCPSchema.enumeration(["lines", "search", "outline"], "what was returned"),
                "start_line": MCPSchema.integer("lines mode: first returned line, 1-based (0 when nothing was returned)"),
                "end_line": MCPSchema.integer("lines mode: last returned line"),
                "truncated": MCPSchema.boolean("lines mode: more lines follow"),
                "next_offset": MCPSchema.nullable(MCPSchema.integer("lines mode: offset for the next call, or null at the end")),
                "text": MCPSchema.string("lines mode: the returned lines exactly as in the note, without line numbers"),
                "match_count": MCPSchema.integer("search mode: matching lines in total"),
                "matches": MCPSchema.array(of: MCPSchema.object(["line": MCPSchema.integer("1-based"), "text": MCPSchema.string("whole line")])),
                "headings": MCPSchema.array(of: MCPSchema.object(["line": MCPSchema.integer("1-based"),
                                                                  "level": MCPSchema.integer("1…6"), "title": MCPSchema.string("heading text")])),
            ]),
            tier: .read
        ) { _, args in
            let noteRef = try args.string("note_ref"), windowId = try args.string("window_id"), ws = try args.string("workspace")
            let mode: MCPFacade.MarkdownReadMode
            if try args.bool("outline", default: false) {
                mode = .outline
            } else if let q = try args.string("search"), !q.isEmpty {
                mode = .search(query: q, caseSensitive: try args.bool("case_sensitive", default: false))
            } else {
                mode = .lines(offset: max(1, try args.int("offset") ?? 1), limit: min(2000, max(1, try args.int("limit") ?? 400)))
            }
            let r = try await MainActor.run {
                try MCPFacade.shared.readMarkdown(noteRef: noteRef, windowId: windowId, workspacePath: ws, mode: mode)
            }
            return MCPToolResult(text: r.text, structured: r.json)
        }
    }

    static func editMarkdown() -> MCPTool {
        // 单条修改的四个字段：顶层直接用（最常见的一处修改），也是 edits 数组每一项的形状
        let editFields: [String: MCPObject] = [
            "old_text": MCPSchema.string("Exact text to replace, copied from read_markdown without the line-number prefix. Must match exactly one place (include a few surrounding words or lines to make it unique) unless replace_all."),
            "new_text": MCPSchema.string("Replacement text (empty string deletes old_text), or the lines to insert with insert_line."),
            "replace_all": MCPSchema.boolean("Replace every occurrence of old_text (default false)", default: false),
            "insert_line": MCPSchema.integer("Instead of old_text: insert new_text as whole lines after this line (0 = at the very top, line_count = at the end)", min: 0),
        ]
        let editItem = MCPSchema.object(editFields, required: ["new_text"])
        return MCPTool(
            name: "edit_markdown",
            title: "Edit part of a Markdown note",
            description: "Change part of a Markdown note without resending the whole text, like a code editor's find-and-replace. Each edit either replaces old_text (exact match, including spaces and line breaks) with new_text, or inserts new_text after insert_line. Pass one edit via old_text/new_text/replace_all/insert_line, or several via edits; they apply in order (each sees the result of the previous one) and all-or-nothing. Works on the live editor text, so the user's unsaved typing is kept; call read_markdown first to copy old_text exactly. Only change what the user asked for: keep existing [[wiki links]], aliases, anchors and embeds as they are. The result shows the changed lines with context so you can check them.",
            inputSchema: MCPSchema.object(markdownTargetProperties.merging(editFields) { a, _ in a }.merging([
                "edits": MCPSchema.array(of: editItem, "Several edits applied in order, all-or-nothing. Use instead of the single-edit fields."),
                "expected_revision": MCPSchema.string("Optional revision from read_markdown: refuse if the note changed at all since then. Without it, the exact old_text match is the safety check."),
            ]) { a, _ in a }),
            outputSchema: MCPSchema.object([
                "ref": MCPSchema.string("edited note_ref"), "title": MCPSchema.string("note title"),
                "link": MCPSchema.string("unireader:// link that activates the note"),
                "revision": MCPSchema.string("revision after the edit"),
                "characters": MCPSchema.integer("characters after the edit"),
                "line_count": MCPSchema.integer("lines after the edit"),
                "replacements": MCPSchema.array(of: MCPSchema.integer("places changed by that edit"), "per edit, in order"),
                "changed_lines": MCPSchema.array(of: MCPSchema.array(of: MCPSchema.integer("1-based")), "[first, last] line ranges in the new text that were changed"),
            ]),
            tier: .write
        ) { _, args in
            let noteRef = try args.string("note_ref"), windowId = try args.string("window_id"), ws = try args.string("workspace")
            let revision = try args.string("expected_revision")
            var edits: [MCPMarkdownText.Edit] = []
            let single = ["old_text", "new_text", "replace_all", "insert_line"].contains { args.raw[$0] != nil && !(args.raw[$0] is NSNull) }
            if let list = args.raw["edits"], !(list is NSNull) {
                guard !single else { throw MCPInvalidParams("pass either edits or old_text/new_text/insert_line, not both") }
                guard let items = list as? [MCPObject], !items.isEmpty else {
                    throw MCPInvalidParams("argument 'edits' must be a non-empty array of objects")
                }
                for (i, item) in items.enumerated() { edits.append(try parseEdit(MCPArgs(item), label: "edits[\(i)]")) }
            } else {
                guard single else { throw MCPInvalidParams("pass old_text + new_text, insert_line + new_text, or edits") }
                edits.append(try parseEdit(args, label: "edit"))
            }
            let r = try await MainActor.run {
                try MCPFacade.shared.editMarkdown(noteRef: noteRef, windowId: windowId, workspacePath: ws,
                                                  expectedRevision: revision, edits: edits)
            }
            return MCPToolResult(text: r.text, structured: r.json)
        }
    }

    private static func parseEdit(_ a: MCPArgs, label: String) throws -> MCPMarkdownText.Edit {
        guard let new = try a.string("new_text") else { throw MCPInvalidParams("\(label): 'new_text' is required") }
        let old = try a.string("old_text")
        if let line = try a.int("insert_line") {
            guard old == nil else { throw MCPInvalidParams("\(label): use either old_text or insert_line, not both") }
            return .insert(afterLine: line, text: new)
        }
        guard let old else { throw MCPInvalidParams("\(label): 'old_text' or 'insert_line' is required") }
        return .replace(old: old, new: new, all: try a.bool("replace_all", default: false))
    }

    static func updateMarkdown() -> MCPTool {
        MCPTool(
            name: "update_markdown",
            title: "Replace a whole Markdown note",
            description: "Replace the complete body of a Markdown note. Prefer edit_markdown for anything short of a full rewrite — it is much faster and cannot drop text by accident. Pass the revision from read_markdown (or get_current_view) as expected_revision; the update is refused if the note changed after you read it. Preserve all text that should remain, including existing [[wiki links]], aliases, anchors and embeds.",
            inputSchema: MCPSchema.object(markdownTargetProperties.merging([
                "expected_revision": MCPSchema.string("revision from read_markdown or get_current_view"),
                "text": MCPSchema.string("Complete new Markdown body. Existing content is not preserved automatically."),
            ]) { a, _ in a }, required: ["expected_revision", "text"]),
            outputSchema: MCPSchema.object([
                "ref": MCPSchema.string("updated note_ref"),
                "title": MCPSchema.string("note title"),
                "link": MCPSchema.string("unireader:// link that activates the note"),
                "revision": MCPSchema.string("revision after the update"),
                "characters": MCPSchema.integer("character count after the update"),
                "line_count": MCPSchema.integer("lines after the update"),
            ]),
            tier: .write
        ) { _, args in
            let noteRef = try args.string("note_ref"), windowId = try args.string("window_id"), ws = try args.string("workspace")
            let revision = try args.requiredString("expected_revision")
            guard let text = try args.string("text") else { throw MCPInvalidParams("argument 'text' is required") }
            let result = try await MainActor.run {
                try MCPFacade.shared.updateMarkdown(noteRef: noteRef, windowId: windowId, workspacePath: ws,
                                                    expectedRevision: revision, text: text)
            }
            return MCPToolResult(
                text: "Updated Markdown note “\(result["title"] ?? "")” · \(result["line_count"] ?? 0) lines · \(result["characters"] ?? 0) characters · revision \(result["revision"] ?? "")",
                structured: result)
        }
    }
}
