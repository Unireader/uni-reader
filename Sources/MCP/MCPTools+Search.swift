import Foundation

/// 全工作区搜索（MCP `search`，`SEARCH-PLAN.md`，2026-11-12）：一次查 PDF 每页文字、Markdown 笔记、批注、习题、Agent 上下文。
/// 关键词走 `SearchIndex.keyword`；设置里开了语义搜索就再走一路向量，两路按排名合并（`SearchIndex.fuse`）。
/// 单篇 PDF 里找位置（要高亮框）仍用 `search_text`。
extension MCPTools {
    static let searchKinds = ["pdf", "markdown", "annotation", "exercise", "context", "memory", "conversation"]

    static func searchTool() -> MCPTool {
        MCPTool(
            name: "search",
            title: "Search the whole workspace",
            description: "Search everything in a workspace at once: the text of every PDF page (OCR text where UniReader has it, otherwise the PDF's own text), Markdown notes, annotations (text notes, highlights, bookmarks, image-note captions), exercises, saved agent contexts, workspace memories and earlier Agent-panel conversations (kinds conversation: what the user and the agent said, without tool output). Matching ignores spaces, line breaks, case and full-width/half-width differences, so a phrase broken across lines in a scanned book still matches. Several words = all must appear (if nothing matches, any of them); put a phrase in quotes to keep it together. When semantic search is turned on in UniReader's settings, results that mean the same thing in other words are mixed in (mode hybrid). Results are ranked, one per PDF page / note section, with ids to follow up: read_pages or search_text (for highlight rectangles) for PDF pages, read_markdown with offset = line for notes, list_annotations, list_exercises, read_conversation (offset = turn) for conversations. The index is built in the background; the first search of a large library may return before it is complete (see index.complete) — search again a bit later for full results.",
            inputSchema: MCPSchema.object([
                "query": MCPSchema.string("Words or phrases to find. Chinese works without spaces; separate several keywords with spaces."),
                "kinds": MCPSchema.array(of: MCPSchema.enumeration(searchKinds, "content kind"), "Only these kinds (default: all)"),
                "document_ids": MCPSchema.array(of: MCPSchema.string("document id"), "Only these PDFs (their pages, annotations and exercises)"),
                "note_source": MCPSchema.string("Markdown notes: only this note source (id or name from list_markdown_notes)"),
                "note_folder": MCPSchema.string("Markdown notes: only notes under this folder (relative to the source root)"),
                "mode": MCPSchema.enumeration(["auto", "keyword", "semantic", "hybrid"], "auto = hybrid when semantic search is on and ready, otherwise keyword", default: "auto"),
                "limit": MCPSchema.integer("Max results (default 20, max 100)", min: 1, max: 100),
                "wait": MCPSchema.integer("Seconds to wait for the index to catch up before searching (default 20, max 120)", min: 0, max: 120),
                "workspace": MCPSchema.string("Workspace .unrd path. Default: the key window's workspace."),
            ], required: ["query"]),
            outputSchema: MCPSchema.object([
                "query": MCPSchema.string("the query"),
                "terms": MCPSchema.array(of: MCPSchema.string("normalized term"), "keywords as matched"),
                "mode": MCPSchema.enumeration(["keyword", "semantic", "hybrid"], "how results were found"),
                "relaxed": MCPSchema.boolean("no result had every word, so results with any of them are shown"),
                "hits": MCPSchema.array(of: MCPSchema.object([
                    "kind": MCPSchema.enumeration(searchKinds, "what it is"),
                    "title": MCPSchema.string("document / note / context title"),
                    "snippet": MCPSchema.string("text around the match, matched words in [brackets]"),
                    "score": MCPSchema.number("ranking score (only for ordering)"),
                    "document_id": MCPSchema.string("pdf / annotation / exercise: the document"),
                    "page": MCPSchema.integer("pdf / annotation / exercise: page, 1-based"),
                    "note_ref": MCPSchema.string("markdown: note_ref"),
                    "line": MCPSchema.integer("markdown: first line of the matching section, 1-based"),
                    "heading": MCPSchema.string("markdown: heading of that section"),
                    "annotation_id": MCPSchema.string("annotation: id"),
                    "annotation_kind": MCPSchema.enumeration(["note", "highlight", "bookmark", "image_note"], "annotation: kind"),
                    "exercise_id": MCPSchema.string("exercise: id"),
                    "chapter": MCPSchema.string("exercise: chapter / section"),
                    "context_id": MCPSchema.string("context: id for read_agent_context"),
                    "agent": MCPSchema.string("context / memory / conversation: the agent"),
                    "memory_id": MCPSchema.string("memory: id for save_memory / delete_memory"),
                    "conversation_id": MCPSchema.string("conversation: id for read_conversation"),
                    "turn": MCPSchema.integer("conversation: turn number, 1-based (offset for read_conversation)"),
                    "link": MCPSchema.string("unireader:// link that opens it"),
                ])),
                "index": MCPSchema.object([
                    "complete": MCPSchema.boolean("the index was up to date when searching"),
                    "pending": MCPSchema.integer("sources still being indexed"),
                    "chunks": MCPSchema.integer("text pieces in the index"),
                    "semantic": MCPSchema.object([
                        "enabled": MCPSchema.boolean("semantic search is on in settings"),
                        "embedded": MCPSchema.integer("pieces with a vector"),
                        "error": MCPSchema.nullable(MCPSchema.string("last error of the embeddings model")),
                    ]),
                ]),
            ]),
            tier: .read
        ) { _, args in
            let query = try args.requiredString("query")
            var kinds = Set<String>()
            if let list = args.raw["kinds"] as? [Any] {
                for v in list {
                    guard let k = v as? String, searchKinds.contains(k) else { throw MCPInvalidParams("kinds must be among \(searchKinds.joined(separator: ", "))") }
                    kinds.insert(k)
                }
            }
            var owners = Set<String>()
            if let list = args.raw["document_ids"] as? [Any] { for v in list { if let s = v as? String, !s.isEmpty { owners.insert(s) } } }
            let noteSource = try args.string("note_source"), noteFolderRaw = try args.string("note_folder") ?? ""
            let noteFolder = noteFolderRaw.split(separator: "/").map(String.init).filter { !$0.isEmpty }.joined(separator: "/")
            let modeArg = try args.string("mode") ?? "auto"
            guard ["auto", "keyword", "semantic", "hybrid"].contains(modeArg) else { throw MCPInvalidParams("mode must be auto, keyword, semantic or hybrid") }
            let limit = min(max(try args.int("limit") ?? 20, 1), 100)
            let wait = TimeInterval(min(max(try args.int("wait") ?? 20, 0), 120))
            let wsPath = try args.string("workspace")

            let prep = try await MainActor.run { () throws -> (SearchIndex, [SearchIndex.Source], String?) in
                let p = try MCPFacade.shared.searchPrepare(workspacePath: wsPath)
                var prefix: String?
                if let noteSource, !noteSource.isEmpty {
                    let src = try MCPFacade.shared.noteSource(p.ws, named: noteSource)
                    prefix = src.id + ":" + (noteFolder.isEmpty ? "" : noteFolder + "/")
                }
                return (p.index, p.sources, prefix)
            }
            let index = prep.0
            let embedder = SemanticSearchSettings.current()
            let complete = await index.refresh(prep.1, budget: wait, embedder: embedder)
            let filter = SearchIndex.Filter(kinds: kinds, owners: owners, notePrefix: prep.2)
            // 只给目录没给源：按目录在结果里再筛一遍（多取一些，筛完还够数）
            let folderOnly = prep.2 == nil && !noteFolder.isEmpty
            let want = folderOnly ? limit * 5 : limit

            let vectors = await index.vectorCount
            var mode = modeArg
            var notices: [String] = []
            if mode == "auto" { mode = (embedder != nil && vectors > 0) ? "hybrid" : "keyword" }
            if mode != "keyword", embedder == nil {
                notices.append("Semantic search is off (UniReader Settings › Agent › Semantic Search), so this was a keyword search.")
                mode = "keyword"
            }
            let kw = await index.keyword(query, filter: filter, limit: mode == "semantic" ? 0 : want * 3)
            var hits: [SearchIndex.Hit]
            if mode == "keyword" {
                hits = Array(kw.hits.prefix(want))
            } else {
                var sem: [SearchIndex.Hit] = []
                do {
                    let qv = try await embedder!.embedQuery(query)
                    sem = await index.semantic(qv, filter: filter, limit: want * 3)
                } catch {
                    notices.append("Semantic search failed (\(error.localizedDescription)); keyword results only.")
                }
                if vectors == 0 { notices.append("No text has been embedded for semantic search yet; it is being prepared in the background.") }
                hits = mode == "semantic" && !sem.isEmpty ? Array(sem.prefix(want)) : SearchIndex.fuse(keyword: kw.hits, semantic: sem, limit: want)
            }
            if folderOnly {
                hits = hits.filter { h in
                    h.kind != "markdown" || (NoteRef(key: h.owner)?.relPath.hasPrefix(noteFolder + "/") ?? false)
                }
            }
            hits = Array(hits.prefix(limit))

            let progress = await index.progress, ep = await index.embedProgress, stats = await index.stats
            let pending = complete ? 0 : max(0, progress.total - progress.done)
            if !complete {
                notices.append("The search index is still being built (\(progress.done) of \(progress.total) sources done); results may be incomplete — search again later for everything.")
            }
            let terms = kw.terms
            let dtos = try await MainActor.run { () throws -> [MCPObject] in
                let ws = try MCPFacade.shared.manager(workspacePath: wsPath)
                return hits.map { MCPFacade.shared.searchHitDTO(ws, $0, terms: terms) }
            }
            var o: MCPObject = ["query": query, "terms": terms, "mode": mode, "relaxed": kw.relaxed, "hits": dtos,
                                "index": ["complete": complete, "pending": pending, "chunks": stats.chunks,
                                          "semantic": ["enabled": embedder != nil, "embedded": vectors,
                                                       "error": ep.lastError.map { $0 as Any } ?? NSNull()] as MCPObject] as MCPObject]
            var lines: [String] = []
            for (i, d) in dtos.enumerated() {
                let kind = d["kind"] as? String ?? ""
                let title = d["title"] as? String ?? ""
                let snip = d["snippet"] as? String ?? ""
                let head: String
                switch kind {
                case "pdf": head = "[PDF] “\(title)” p.\(d["page"] ?? "") (document_id \(d["document_id"] ?? ""))"
                case "markdown":
                    let h = (d["heading"] as? String).map { " § \($0)" } ?? ""
                    head = "[Note] “\(title)” line \(d["line"] ?? "")\(h) (note_ref \(d["note_ref"] ?? ""))"
                case "annotation": head = "[\(d["annotation_kind"] ?? "annotation")] “\(title)” p.\(d["page"] ?? "") (id \((d["annotation_id"] as? String ?? "").prefix(8)))"
                case "exercise": head = "[Exercise] \(title.isEmpty ? "" : "“\(title)” ")(exercise_id \(d["exercise_id"] ?? ""))"
                case "memory": head = "[Memory] (memory_id \((d["memory_id"] as? String ?? "").prefix(8)))"
                case "conversation": head = "[Conversation] “\(title)” turn \(d["turn"] ?? "") (conversation_id \(d["conversation_id"] ?? ""))"
                default: head = "[Context] “\(title)” (context_id \(d["context_id"] ?? ""))"
                }
                lines.append("\(i + 1). \(head)\n   \(snip)")
            }
            var text = dtos.isEmpty ? "No results for “\(query)”." : "\(dtos.count) result(s) for “\(query)” (\(mode)\(kw.relaxed ? ", any word" : "")):\n" + lines.joined(separator: "\n")
            if !notices.isEmpty {
                text += "\n" + notices.joined(separator: "\n")
                o[MCPToolResult.messageKey] = notices.joined(separator: " ")
            }
            return MCPToolResult(text: text, structured: o)
        }
    }
}
