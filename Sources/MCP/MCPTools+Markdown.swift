import CryptoKit
import Foundation

/// Markdown 笔记的读写工具（2026-09-24 细化，`MCP-PLAN.md §19`）：
/// - `list_markdown_notes`：拿 `note_ref`；
/// - `read_markdown`：按行分页（带行号）/ 行内搜索 / 标题大纲，任何一篇都能读，不必开着；
/// - `edit_markdown`：code agent 式局部修改（原文精确匹配替换、按行号插入），不用重吐整篇；
/// - `update_markdown`：整篇替换（带 revision 乐观锁），只留给「真要重写全文」的场合；
/// - `create_markdown`：新建一篇（2026-11-12，`MARKDOWN-NOTES-PLAN.md §14`；此前 Agent 只能绕过 App 直接写文件）；
/// - `rename_markdown`：改名 / 挪目录（2026-11-12，`§15`）：只动这一个文件，断掉的 `[[…]]` 列出来、不改。
/// 纯逻辑在 `MCPMarkdownText`，碰 App 状态的在 `MCPFacade`（写入同一条路：原子写文件 + 推回所有编辑器）。
extension MCPTools {
    /// 笔记里公式怎么写（英文，给模型看）。MCP `instructions`、写笔记工具的正文字段、Agent 面板上下文共用这一段。
    /// 别把公式包进加粗 / 斜体：用户 2026-10-07「不要出现加粗和公式一起用」。
    /// 后半句列的是 SwiftMath 不认、`LatexCompat` 也没换的写法（用户同日定：近似显示不做，让 Agent 别用）；
    /// 名单来自 `spike/latex-look.swift` 普查，`LatexCompat` 新增替换时从这里删掉对应的。
    static let mathWriting = "Math in notes: $…$ inline, all on one line; $$…$$ on lines of their own for a block; \\(…\\) and \\[…\\] are NOT rendered. Never put a formula inside bold or italic (no **…$x$…**): emphasize the words around it and leave the formula outside the ** or *. The renderer cannot draw \\boxed, \\overset, \\underset, \\stackrel, \\xrightarrow, \\overbrace, \\underbrace, \\mathop, \\limits, \\because, \\therefore, or the cases, array, align, gather and split environments — a formula using any of them shows as raw source. For a piecewise definition write \\left\\{\\begin{aligned} … \\end{aligned}\\right. and for multi-line equations use aligned."

    /// 笔记里怎么放函数图形（英文，给模型看）。格式本身由 Grapher NG 的 MCP 说明（`get_text_reference` / `render_text`），
    /// 这里只讲放在哪、怎么写进去。方案见 `GRAPHER-BLOCK-PLAN.md`；MCP `instructions` 与 Agent 面板上下文共用。
    static let graphWriting = "Graphs in Markdown notes (not in PDF text notes): a fenced block whose language is grapher, a few lines of text with one layer per line, draws a function graph the reader can rotate and tune with sliders. Write it with edit_markdown like any other text. If a grapher-ng MCP server is connected, read its get_text_reference first and check the block with render_text before writing it (it reports errors by line); otherwise keep to simple lines such as `surface: sin(x)*cos(y)`. Leave an existing grapher block's view: and param lines alone unless asked: the reader saves them by hand."

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
            description: "List the workspace's Markdown notes — separate .md files in the built-in Notes folder and referenced external folders, each opened in its own tab — with their note_ref, for read_markdown / edit_markdown. Text notes pinned on PDF pages are a different kind: see list_annotations.",
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
            "new_text": MCPSchema.string("Replacement text (empty string deletes old_text), or the lines to insert with insert_line. \(mathWriting)"),
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

    static func createMarkdown() -> MCPTool {
        MCPTool(
            name: "create_markdown",
            title: "Create a Markdown note",
            description: "Create a new Markdown note — a separate .md file in the workspace's built-in Notes folder or in a referenced external folder (e.g. the user's Obsidian vault) — with an optional starting text. Use it instead of writing files yourself: the note shows up in UniReader's sidebar right away and nothing else is touched. The title becomes the file name (and the name [[wiki links]] use). Missing folders are created. If a note with that name already exists there, nothing is written and you get its note_ref: change it with edit_markdown / update_markdown instead. Create notes only when the user asks for them.",
            inputSchema: MCPSchema.object([
                "title": MCPSchema.string("Note title = file name, without .md (characters / \\ : * ? \" < > | # ^ [ ] become -)."),
                "text": MCPSchema.string("Starting Markdown body (optional; default empty). \(mathWriting)"),
                "source": MCPSchema.string("Note source id or name from list_markdown_notes sources. Default: the workspace's built-in Notes folder."),
                "folder": MCPSchema.string("Folder inside the source, relative to its root, e.g. \"101思想政治理论/思修\" (created if missing). Default: the source root."),
                "open": MCPSchema.boolean("Open the new note in a tab afterwards", default: false),
                "workspace": MCPSchema.string("Workspace .unrd path. Default: the key window's workspace."),
            ], required: ["title"]),
            outputSchema: MCPSchema.object([
                "ref": MCPSchema.string("note_ref of the new note"),
                "title": MCPSchema.string("note title"),
                "source": MCPSchema.string("source name"),
                "relative_path": MCPSchema.string("path relative to the source root"),
                "link": MCPSchema.string("unireader:// link that opens the note"),
                "revision": MCPSchema.string("revision of the text written (for update_markdown)"),
                "characters": MCPSchema.integer("character count"),
                "line_count": MCPSchema.integer("lines"),
                "opened": MCPSchema.boolean("the note was opened in a tab"),
            ]),
            tier: .write
        ) { ctx, args in
            let title = try args.requiredString("title")
            let text = try args.string("text") ?? ""
            let source = try args.string("source"), folder = try args.string("folder") ?? ""
            let ws = try args.string("workspace")
            // 打开是导航：「跟随 Agent」关着时照建不开（同 open_document 带 path 时导入照做）
            var open = try args.bool("open", default: false)
            var declined = false
            if open, ctx.fromInAppAgent, !AgentFollow.enabled { open = false; declined = true }
            let r = try await MainActor.run {
                try MCPFacade.shared.createMarkdown(title: title, text: text, source: source, folder: folder,
                                                    workspacePath: ws, open: open)
            }
            var line = "Created Markdown note “\(r["title"] ?? "")” at \(r["source"] ?? "")/\(r["relative_path"] ?? "") · note_ref \(r["ref"] ?? "") · \(r["line_count"] ?? 0) lines · revision \(r["revision"] ?? "")"
            if (r["opened"] as? Bool) == true { line += " · opened in a tab" }
            if declined { line += "\nNot opened: " + AgentFollow.declined }
            return MCPToolResult(text: line, structured: r)
        }
    }

    /// 断链清单最多列几篇（文字输出与结构化结果同一个上限）。
    static let brokenListMax = 50

    /// 断链清单的 schema（改名 / 挪目录 / 删除共用）。
    static var brokenLinkSchema: [String: MCPObject] {
        ["broken_link_notes": MCPSchema.integer("notes whose [[…]] links broke because of this"),
         "broken_links": MCPSchema.array(of: MCPSchema.object([
            "ref": MCPSchema.string("note_ref of the note containing the links"),
            "title": MCPSchema.string("its title"),
            "names": MCPSchema.array(of: MCPSchema.string("link target as written inside [[…]]")),
         ]), "notes whose links broke (at most \(brokenListMax))")]
    }

    /// 认完断链：写进结构化结果，返回给文字输出接的那几行。断链多时整段文字超过 `messageLimit` 不会抄进结构化结果
    /// （Claude Code 只看结构化），所以那句建议另放进 `message`。
    static func reportBroken(_ broken: [(ref: NoteRef, names: [String])], head: String, into o: inout MCPObject) -> String {
        let listed = broken.prefix(brokenListMax)
        o["broken_link_notes"] = broken.count
        o["broken_links"] = listed.map { ["ref": $0.ref.key, "title": $0.ref.title, "names": $0.names] as MCPObject }
        guard !broken.isEmpty else { return head + "\nNo [[…]] links broke." }
        let advice = "\(broken.count) note(s) link to it by a name that no longer resolves; those links were left as they are "
            + "(UniReader never rewrites note text by itself). Tell the user; fix them with edit_markdown only if the user asks"
        o[MCPToolResult.messageKey] = head + "\n" + advice + " (see broken_links)."
        var text = head + "\n" + advice + ":"
        for b in listed {
            text += "\n- “\(b.ref.title)” (note_ref \(b.ref.key)): " + b.names.map { "[[\($0)]]" }.joined(separator: ", ")
        }
        if broken.count > listed.count { text += "\n… and \(broken.count - listed.count) more" }
        return text
    }

    /// 空串当「没给」：有的客户端把没填的可选参数也发成 ""。
    private static func given(_ s: String?) -> String? { s.flatMap { $0.trimmed.isEmpty ? nil : $0 } }

    static func renameMarkdown() -> MCPTool {
        MCPTool(
            name: "rename_markdown",
            title: "Rename or move a Markdown note",
            description: "Rename a Markdown note, move it to another folder, move it to another note source (e.g. from the workspace's Notes folder into the user's Obsidian vault), or a mix. The title is the file name, so this renames the .md file; the text is not changed. Tabs and mini-windows showing the note follow it, and unsaved typing is saved first. [[wiki links]] in other notes that use the old name break: UniReader never rewrites note text by itself, so the result lists the notes whose links broke — tell the user, and fix those links with edit_markdown only if the user asks. Moving to another folder or source keeps the name, so [[name]] links keep working. Moving to another source copies the file there and then moves the original to the system Trash; attachments stay where they are. If a note with the new name already exists there, nothing is changed. Rename or move notes only when the user asks.",
            inputSchema: MCPSchema.object(markdownTargetProperties.merging([
                "title": MCPSchema.string("New title = new file name, without .md (characters / \\ : * ? \" < > | # ^ [ ] become -). Omit to keep the name."),
                "folder": MCPSchema.string("Move to this folder, relative to the source root, e.g. \"101思想政治理论/思修\" (created if missing); \"/\" = the source root. Omit to stay in the same folder."),
                "source": MCPSchema.string("Move to this note source (id or name from list_markdown_notes sources). Omit to stay in the same source."),
            ]) { a, _ in a }),
            outputSchema: MCPSchema.object([
                "ref": MCPSchema.string("note_ref after the rename (the old one no longer works)"),
                "title": MCPSchema.string("new title"),
                "source": MCPSchema.string("source name"),
                "relative_path": MCPSchema.string("new path relative to the source root"),
                "link": MCPSchema.string("unireader:// link that opens the note"),
                "revision": MCPSchema.string("revision of the note text (unchanged by the rename)"),
                "characters": MCPSchema.integer("character count"),
                "line_count": MCPSchema.integer("lines"),
                "old_ref": MCPSchema.string("note_ref before the rename"),
                "old_title": MCPSchema.string("title before the rename"),
                "old_source": MCPSchema.string("source name before the rename"),
                "old_relative_path": MCPSchema.string("path before the rename"),
                "changed": MCPSchema.boolean("false when the note already had this name, folder and source"),
            ].merging(brokenLinkSchema) { a, _ in a }),
            tier: .write
        ) { _, args in
            let noteRef = try args.string("note_ref"), windowId = try args.string("window_id"), ws = try args.string("workspace")
            // 源根要显式写 "/"，空串当没给（别因为客户端把没填的参数发成 "" 就把笔记挪到源根去）
            let title = given(try args.string("title")), folder = given(try args.string("folder")), source = given(try args.string("source"))
            guard title != nil || folder != nil || source != nil else {
                throw MCPInvalidParams("pass title (the new name), folder (where to move it), source (another note source), or a mix")
            }
            let r = try await MainActor.run {
                try MCPFacade.shared.renameMarkdown(noteRef: noteRef, windowId: windowId, workspacePath: ws,
                                                    title: title, folder: folder, source: source)
            }
            var o = r.json
            let place = "\(o["source"] ?? "")/\(o["relative_path"] ?? "")"
            guard let scan = r.scan else {
                return MCPToolResult(text: "“\(o["title"] ?? "")” already has this name and folder (\(place)); nothing changed · note_ref \(o["ref"] ?? "")",
                                     structured: o)
            }
            let from = scan.moved.keys.first!, to = (scan.moved[from] ?? nil) ?? from
            let verb = from.title == to.title ? "Moved" : (from.folder == to.folder && from.sourceID == to.sourceID ? "Renamed" : "Renamed and moved")
            let head = "\(verb) “\(from.title)” → \(place) · note_ref \(to.key) (the old note_ref no longer works)"
            let text = reportBroken(await MCPNoteScan.brokenLinks(scan), head: head, into: &o)
            return MCPToolResult(text: text, structured: o)
        }
    }

    static func moveMarkdownFolder() -> MCPTool {
        MCPTool(
            name: "move_markdown_folder",
            title: "Rename or move a folder of Markdown notes",
            description: "Rename a folder of Markdown notes, or move it under another folder of the same note source. Everything inside (notes, attachments, subfolders) moves along unchanged. Tabs showing notes inside follow them. [[name]] links keep working because they resolve by name; links that spelled out the old folder path may break — the result lists them, and they are left unchanged (tell the user; fix with edit_markdown only if asked). Do this only when the user asks.",
            inputSchema: MCPSchema.object([
                "folder": MCPSchema.string("The folder to move, relative to the source root, e.g. \"101思想政治理论/思修\"."),
                "name": MCPSchema.string("New folder name. Omit to keep the name."),
                "parent": MCPSchema.string("Move it under this folder (relative to the source root, created if missing); \"/\" = the source root. Omit to keep the parent."),
                "source": MCPSchema.string("Note source id or name from list_markdown_notes sources. Default: the workspace's built-in Notes folder."),
                "workspace": MCPSchema.string("Workspace .unrd path. Default: the key window's workspace."),
            ], required: ["folder"]),
            outputSchema: MCPSchema.object([
                "source": MCPSchema.string("source name"),
                "old_folder": MCPSchema.string("folder path before"),
                "folder": MCPSchema.string("folder path after"),
                "changed": MCPSchema.boolean("false when nothing changed"),
                "notes_moved": MCPSchema.integer("notes inside the folder"),
                "notes": MCPSchema.array(of: MCPSchema.object([
                    "old_ref": MCPSchema.string("note_ref before"), "ref": MCPSchema.string("note_ref after"), "title": MCPSchema.string("title"),
                ]), "moved notes (at most 200)"),
            ].merging(brokenLinkSchema) { a, _ in a }),
            tier: .write
        ) { _, args in
            let folder = try args.requiredString("folder")
            let name = given(try args.string("name")), parent = given(try args.string("parent"))
            guard name != nil || parent != nil else { throw MCPInvalidParams("pass name (the new folder name), parent (where to move it), or both") }
            let source = try args.string("source"), ws = try args.string("workspace")
            let r = try await MainActor.run {
                try MCPFacade.shared.moveMarkdownFolder(source: source, folder: folder, name: name, parent: parent == "/" ? "" : parent,
                                                        workspacePath: ws)
            }
            var o = r.json
            guard let scan = r.scan else {
                let what = (o["changed"] as? Bool) == true ? "Moved the empty folder" : "Nothing changed for folder"
                return MCPToolResult(text: "\(what) \(o["source"] ?? "")/\(o["old_folder"] ?? "") → \(o["folder"] ?? "")", structured: o)
            }
            let head = "Moved folder \(o["source"] ?? "")/\(o["old_folder"] ?? "") → \(o["folder"] ?? "") · \(o["notes_moved"] ?? 0) note(s) inside, all with new note_refs"
            let text = reportBroken(await MCPNoteScan.brokenLinks(scan), head: head, into: &o)
            return MCPToolResult(text: text, structured: o)
        }
    }

    static func deleteMarkdown() -> MCPTool {
        MCPTool(
            name: "delete_markdown",
            title: "Delete a Markdown note",
            description: "Move a Markdown note to the system Trash (the user can put it back from the Trash in Finder). Unsaved typing is saved first, tabs showing it close. For a note in a referenced folder (e.g. the user's Obsidian vault) this trashes the user's own file. [[wiki links]] to it in other notes break and are left unchanged; the result lists them. Delete notes only when the user explicitly asks.",
            inputSchema: MCPSchema.object(markdownTargetProperties),
            outputSchema: MCPSchema.object([
                "ref": MCPSchema.string("note_ref of the deleted note"),
                "title": MCPSchema.string("its title"),
                "source": MCPSchema.string("source name"),
                "source_kind": MCPSchema.string("workspace or reference"),
                "relative_path": MCPSchema.string("path it had"),
                "trash_path": MCPSchema.nullable(MCPSchema.string("where it is in the Trash")),
            ].merging(brokenLinkSchema) { a, _ in a }),
            tier: .delete
        ) { _, args in
            let noteRef = try args.string("note_ref"), windowId = try args.string("window_id"), ws = try args.string("workspace")
            let r = try await MainActor.run {
                try MCPFacade.shared.deleteMarkdown(noteRef: noteRef, windowId: windowId, workspacePath: ws)
            }
            var o = r.json
            let head = "Moved “\(o["title"] ?? "")” (\(o["source"] ?? "")/\(o["relative_path"] ?? "")) to the Trash"
            let text = reportBroken(await MCPNoteScan.brokenLinks(r.scan), head: head, into: &o)
            return MCPToolResult(text: text, structured: o)
        }
    }

    static func addMarkdownImage() -> MCPTool {
        MCPTool(
            name: "add_markdown_image",
            title: "Put a PDF page (or part of it) into a Markdown note",
            description: "Render a PDF page — or just a region of it, such as a figure, table or formula — and embed it in a Markdown note as an image. The image file goes into the attachments folder of the note's source and the note gets a line ![[file]] (plus an optional caption line) after insert_line or at the end; open editors update and the user's unsaved typing is kept. Use region with the same [x, y, w, h] page coordinates as annotations and search hits; check the crop with render_page first if unsure. Add images only when the user asks.",
            inputSchema: MCPSchema.object(markdownTargetProperties.merging([
                "document_id": MCPSchema.string("PDF to take the image from (library document id). Omit for the document in the key window's active PDF tab."),
                "page": MCPSchema.integer("Page, 1-based", min: 1),
                "region": MCPSchema.array(of: MCPSchema.number("0…1"), "Only this part of the page, [x, y, w, h] normalized with the top-left origin. Omit for the whole page."),
                "width": MCPSchema.integer("Pixel width of the saved image (default 1200, max 2160)", min: 200, max: 2160),
                "format": MCPSchema.enumeration(["jpeg", "png"], "image format (png is sharper for text and formulas, jpeg is smaller)", default: "png"),
                "include_marks": MCPSchema.boolean("Also draw the user's handwriting and highlights", default: false),
                "insert_line": MCPSchema.integer("Insert after this line (0 = at the top). Default: at the end.", min: 0),
                "caption": MCPSchema.string("Optional line put right under the image, e.g. a source like 《书名》p.12 or a unireader:// link."),
                "display_width": MCPSchema.integer("Optional display width in points written into the embed (![[file|400]])", min: 50),
            ]) { a, _ in a }, required: ["page"]),
            outputSchema: MCPSchema.object([
                "ref": MCPSchema.string("note_ref"), "title": MCPSchema.string("note title"),
                "link": MCPSchema.string("unireader:// link to the note"),
                "revision": MCPSchema.string("revision after the insert"),
                "characters": MCPSchema.integer("characters"), "line_count": MCPSchema.integer("lines"),
                "image_file": MCPSchema.string("absolute path of the saved image"),
                "embed": MCPSchema.string("the line inserted"),
                "inserted_after_line": MCPSchema.integer("0 = top"),
                "changed_lines": MCPSchema.array(of: MCPSchema.array(of: MCPSchema.integer("1-based")), "lines added"),
                "image_width": MCPSchema.integer("pixels"), "image_height": MCPSchema.integer("pixels"),
                "source_link": MCPSchema.string("unireader:// link to the PDF page the image came from"),
            ]),
            tier: .write
        ) { _, args in
            let noteRef = try args.string("note_ref"), windowId = try args.string("window_id"), ws = try args.string("workspace")
            let docId = try args.string("document_id")
            let page = try args.int("page") ?? 1
            let region = try regionArg(args)
            let width = min(max(try args.int("width") ?? 1200, 200), 2160)
            let fmt = try args.string("format") ?? "png"
            guard fmt == "jpeg" || fmt == "png" else { throw MCPInvalidParams("format must be jpeg or png") }
            let format: PageRenderer.Format = fmt == "png" ? .png : .jpeg(quality: PageRenderer.defaultJPEGQuality)
            let withMarks = try args.bool("include_marks", default: false)
            let after = try args.int("insert_line"), caption = try args.string("caption"), shown = try args.int("display_width")
            let (note, doc) = try await MainActor.run {
                let note = try MCPFacade.shared.markdownImageTarget(noteRef: noteRef, windowId: windowId, workspacePath: ws)
                let doc = try MCPFacade.shared.resolveTarget(documentId: docId, path: nil, workspacePath: nil)
                return (note, doc)
            }
            let reader = MCPDocReader.shared
            let pageCount = try await reader.withDocument(path: doc.path) { $0.pageCount }
            let idx = try PageNo.index(page, pageCount: pageCount)
            let marks = withMarks ? await MainActor.run { MCPFacade.shared.pageMarks(doc, index: idx) } : nil
            let img = try await reader.render(path: doc.path, index: idx, pixelWidth: width, format: format,
                                              align: doc.align, marks: marks, region: region)
            let hash = SHA256.hash(data: img.data).map { String(format: "%02x", $0) }.joined().prefix(8)
            let base = MarkdownImport.safeFileName(String(doc.title.prefix(40)))
            let fileName = "\(base)-p\(page)-\(hash).\(fmt == "png" ? "png" : "jpg")"
            var o = try await MainActor.run {
                try MCPFacade.shared.insertMarkdownImage(note.0, note.1, dir: note.2, fileName: fileName, data: img.data,
                                                         afterLine: after, caption: caption, displayWidth: shown)
            }
            o["image_width"] = img.width
            o["image_height"] = img.height
            if let id = doc.documentId {
                o["source_link"] = await MainActor.run { MCPFacade.shared.link(note.0, doc: id, page: page) }
            }
            return MCPToolResult(text: "Added \(o["embed"] ?? "") (\(img.width)×\(img.height), page \(page) of “\(doc.title)”) to “\(o["title"] ?? "")” after line \(o["inserted_after_line"] ?? 0) · revision \(o["revision"] ?? "")",
                                 structured: o)
        }
    }

    static func openMarkdown() -> MCPTool {
        MCPTool(
            name: "open_markdown",
            title: "Open a Markdown note",
            description: "Show an existing Markdown note in a tab (switches to it if a tab already shows it, otherwise opens one in a window of its workspace). Use it to bring the user to a note you are talking about.",
            inputSchema: MCPSchema.object([
                "note_ref": MCPSchema.string("note_ref from list_markdown_notes / search (also accepts the note's name)."),
                "workspace": MCPSchema.string("Workspace .unrd path, only when the note lives in a workspace other than the key window's."),
                "activate": MCPSchema.boolean("Bring UniReader to the front", default: true),
            ], required: ["note_ref"]),
            outputSchema: MCPSchema.object([
                "ref": MCPSchema.string("note_ref"), "title": MCPSchema.string("title"),
                "session_id": MCPSchema.string("tab id"), "window_id": MCPSchema.string("window id"),
                "link": MCPSchema.string("unireader:// link"),
            ]),
            tier: .navigate
        ) { ctx, args in
            let noteRef = try args.requiredString("note_ref"), ws = try args.string("workspace")
            let activate = try args.bool("activate", default: true)
            if ctx.fromInAppAgent, !AgentFollow.enabled { return MCPToolResult(text: AgentFollow.declined) }
            let o = try await MainActor.run { try MCPFacade.shared.openMarkdown(noteRef: noteRef, workspacePath: ws, activate: activate) }
            return MCPToolResult(text: "Opened “\(o["title"] ?? "")” · note_ref \(o["ref"] ?? "")", structured: o)
        }
    }

    static func markdownLinks() -> MCPTool {
        MCPTool(
            name: "markdown_links",
            title: "Links of a Markdown note",
            description: "Show how Markdown notes link to each other with [[wiki links]]. For one note: every [[link]] in it (with line number and the note it resolves to, or broken) and every place in other notes that links to it (backlinks, with line numbers, so you can edit them with edit_markdown). With broken_only and no note: every [[link]] in the workspace that does not resolve to any note. Read-only; image embeds are not listed.",
            inputSchema: MCPSchema.object(markdownTargetProperties.merging([
                "broken_only": MCPSchema.boolean("List every unresolved [[link]] across all notes instead of one note's links (note_ref is ignored)", default: false),
                "limit": MCPSchema.integer("Max entries per list (default 200)", min: 1),
            ]) { a, _ in a }),
            outputSchema: MCPSchema.object([
                "ref": MCPSchema.nullable(MCPSchema.string("the note (null with broken_only)")),
                "title": MCPSchema.nullable(MCPSchema.string("its title")),
                "outgoing": MCPSchema.array(of: occurrenceSchema, "[[links]] in the note, in order"),
                "backlinks": MCPSchema.array(of: occurrenceSchema, "places in notes that link to it"),
                "broken": MCPSchema.array(of: occurrenceSchema, "broken_only: unresolved links"),
                "outgoing_total": MCPSchema.integer("all outgoing links"), "backlinks_total": MCPSchema.integer("all backlinks"),
                "broken_total": MCPSchema.integer("all unresolved links"),
                "truncated": MCPSchema.boolean("a list was cut at limit"),
            ]),
            tier: .read
        ) { _, args in
            let noteRef = try args.string("note_ref"), windowId = try args.string("window_id"), ws = try args.string("workspace")
            let brokenOnly = try args.bool("broken_only", default: false)
            let limit = max(1, try args.int("limit") ?? 200)
            let input = try await MainActor.run {
                try MCPFacade.shared.markdownLinksInput(noteRef: noteRef, windowId: windowId, workspacePath: ws, wholeWorkspace: brokenOnly)
            }
            let r = await MCPNoteScan.links(input)
            func dto(_ o: MCPNoteScan.Occurrence) -> MCPObject {
                ["note_ref": o.note.key, "note_title": o.note.title, "line": o.line, "text": o.raw, "target": o.target,
                 "resolves_to": o.resolved.map { $0.key as Any } ?? NSNull(),
                 "resolved_title": o.resolved.map { $0.title as Any } ?? NSNull()]
            }
            func lines(_ list: [MCPNoteScan.Occurrence], showNote: Bool) -> String {
                list.prefix(limit).map { o in
                    let at = showNote ? "“\(o.note.title)” (\(o.note.key)) line \(o.line)" : "line \(o.line)"
                    let to = o.resolved.map { " → “\($0.title)” (\($0.key))" } ?? " → broken"
                    return "- \(at): \(o.raw)\(showNote && input.target != nil ? "" : to)"
                }.joined(separator: "\n")
            }
            var o: MCPObject = ["ref": input.target.map { $0.key as Any } ?? NSNull(),
                                "title": input.target.map { $0.title as Any } ?? NSNull(),
                                "outgoing": r.outgoing.prefix(limit).map(dto), "backlinks": r.incoming.prefix(limit).map(dto),
                                "broken": r.broken.prefix(limit).map(dto),
                                "outgoing_total": r.outgoing.count, "backlinks_total": r.incoming.count, "broken_total": r.broken.count]
            var text: String
            if let t = input.target {
                text = "“\(t.title)” (\(t.key)): \(r.outgoing.count) outgoing link(s), \(r.incoming.count) backlink(s)"
                if !r.outgoing.isEmpty { text += "\nOutgoing:\n" + lines(r.outgoing, showNote: false) }
                if !r.incoming.isEmpty { text += "\nBacklinks:\n" + lines(r.incoming, showNote: true) }
            } else {
                text = r.broken.isEmpty ? "No broken [[links]] in this workspace." : "\(r.broken.count) broken [[link]](s):\n" + lines(r.broken, showNote: true)
            }
            if max(r.outgoing.count, r.incoming.count, r.broken.count) > limit { text += "\n… lists cut at \(limit); raise limit to see more" }
            o["truncated"] = max(r.outgoing.count, r.incoming.count, r.broken.count) > limit
            return MCPToolResult(text: text, structured: o)
        }
    }

    private static var occurrenceSchema: MCPObject {
        MCPSchema.object([
            "note_ref": MCPSchema.string("note containing the link"), "note_title": MCPSchema.string("its title"),
            "line": MCPSchema.integer("1-based line"), "text": MCPSchema.string("the link as written, e.g. [[极限|定义]]"),
            "target": MCPSchema.string("target name inside the link"),
            "resolves_to": MCPSchema.nullable(MCPSchema.string("note_ref it resolves to, or null if broken")),
            "resolved_title": MCPSchema.nullable(MCPSchema.string("title of that note")),
        ])
    }

    static func updateMarkdown() -> MCPTool {
        MCPTool(
            name: "update_markdown",
            title: "Replace a whole Markdown note",
            description: "Replace the complete body of a Markdown note. Prefer edit_markdown for anything short of a full rewrite — it is much faster and cannot drop text by accident. Pass the revision from read_markdown (or get_current_view) as expected_revision; the update is refused if the note changed after you read it. Preserve all text that should remain, including existing [[wiki links]], aliases, anchors and embeds.",
            inputSchema: MCPSchema.object(markdownTargetProperties.merging([
                "expected_revision": MCPSchema.string("revision from read_markdown or get_current_view"),
                "text": MCPSchema.string("Complete new Markdown body. Existing content is not preserved automatically. \(mathWriting)"),
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
