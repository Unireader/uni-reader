import Foundation

/// 统计（2026-11-13，`MCP-PLAN.md §38`）：`workspace_stats` 一次给出工作区里各种数量——书库与阅读进度、批注按种类、
/// Markdown 笔记、画板、习题（按题型 / 文档 / 章节 / 标签、错题本、收藏、做没做过、最近一次对错、待判）、
/// 每天的练习、Agent 记忆 / 上下文 / 对话、日程进度。数在 SQL 里数（`StatsStore`），不读正文，
/// Agent 不必为了数个数把整份清单读一遍。入参校验、schema、拼结果在 `MCPStats`（只依赖 Foundation，spike 直接编）。
/// 🔴 每个返回的键都要在 `outputSchema` 里声明（Kimi 严格校验，多一个键整次调用作废）。
extension MCPTools {

    static func registerStats(into server: MCPServer) {
        server.catalog.register(workspaceStatsTool())
    }

    static func workspaceStatsTool() -> MCPTool {
        MCPTool(
            name: "workspace_stats",
            title: "Count things in a workspace",
            description: "Counts for a workspace in one cheap call, computed in the database without reading any content: documents and reading progress (started / finished, per document), annotations by kind (text notes, highlights, bookmarks, image notes, ink strokes, pages with ink), Markdown notes, boards, exercises (by type, document, chapter and tag; starred, in the mistakes book, answered or never answered, last answer right / wrong, answers waiting to be graded), practice per day (answers, right / wrong, distinct exercises, time spent), agent memories / contexts / conversations, and the schedule (done / open / overdue / undated, today, per plan, per day). Use it whenever you need a number or an overview — how many, how far, how much this week — instead of paging through list_exercises, list_annotations, list_exercise_attempts, list_conversations or similar just to count; fetch the actual items with those tools afterwards only if you need them. sections picks which parts to return (default all); document_id restricts library, annotations, exercises and practice to one document (markdown, boards, agent and schedule are always workspace-wide); from / to (local dates) set the range of the per-day lists, default the last 7 days including today. Breakdown lists are capped at limit rows and say how many were left out.",
            inputSchema: MCPSchema.object([
                "workspace": MCPSchema.string("Workspace .unrd path; default = the workspace of the key reader window (or of document_id)."),
                "sections": MCPSchema.array(of: MCPSchema.enumeration(StatsStore.Section.allCases.map(\.rawValue), "section"),
                                            "Only these parts (default: all)"),
                "document_id": MCPSchema.string("Only this library document (from list_documents) for library, annotations, exercises and practice"),
                "from": MCPSchema.string("First day of the per-day lists, local date YYYY-MM-DD (default: 6 days before to)"),
                "to": MCPSchema.string("Last day of the per-day lists, inclusive, YYYY-MM-DD (default: today); at most \(StatsStore.maxRangeDays) days in all"),
                "limit": MCPSchema.integer("Max rows in each breakdown list (by_document, by_chapter, by_tag, by_plan); default \(MCPStats.defaultLimit)",
                                           min: 1, max: MCPStats.maxLimit),
            ]),
            outputSchema: MCPStats.outputSchema,
            tier: .read
        ) { _, args in
            let wsPath = try args.string("workspace")
            let docId = try args.string("document_id")
            let sections = try MCPStats.sections(args.raw["sections"])
            let limit = min(MCPStats.maxLimit, max(1, try args.int("limit") ?? MCPStats.defaultLimit))
            let tz = TimeZone.current
            let today = StatsStore.dayString(Date(), in: tz)
            let range = try MCPStats.range(from: try args.string("from"), to: try args.string("to"), today: today, in: tz)
            let r = try await MainActor.run {
                try MCPFacade.shared.workspaceStats(sections: sections, documentId: docId, range: range, today: today,
                                                    timeZone: tz, limit: limit, workspacePath: wsPath)
            }
            return MCPToolResult(text: r.text, structured: r.object)
        }
    }
}

// MARK: - 执行（主线程）

extension MCPFacade {

    func workspaceStats(sections: Set<StatsStore.Section>, documentId: String?, range: (from: String, to: String),
                        today: String, timeZone: TimeZone, limit: Int,
                        workspacePath: String?) throws -> (object: MCPObject, text: String) {
        let ws: WorkspaceManager
        var document: (id: String, title: String)?
        if let id = documentId?.trimmingCharacters(in: .whitespaces), !id.isEmpty {
            // 找文档所在的工作区：同 `writeTarget`（给了 workspace 就要它，否则 key 窗口那个，再否则开着的哪个有它）
            if let p = workspacePath, !p.isEmpty { ws = try manager(workspacePath: p) }
            else if let key = keyController, key.workspace.document(id: id) != nil { ws = key.workspace }
            else if let m = WorkspaceRegistry.shared.openManagers.first(where: { $0.document(id: id) != nil }) { ws = m }
            else { throw MCPToolError("document '\(id)' not found in any open workspace; call list_documents") }
            guard let doc = ws.document(id: id) else {
                throw MCPToolError("document '\(id)' not found in workspace '\(ws.name)'; call list_documents")
            }
            document = (doc.id, doc.title)
        } else {
            ws = try manager(workspacePath: workspacePath)
        }
        guard let store = ws.store else { throw MCPToolError("the library of workspace '\(ws.name)' is not open") }
        let report = try store.stats(StatsStore.Query(sections: sections, documentId: document?.id,
                                                      from: range.from, to: range.to, today: today,
                                                      timeZone: timeZone, limit: limit))
        // Markdown 笔记的正文在磁盘上，清单以 `noteTrees`（扫描结果）为准，不数 `md_doc`（库里不一定每篇都有一行）
        let markdown: [MCPStats.MarkdownSource]? = sections.contains(.markdown)
            ? ws.noteTrees.map { MCPStats.MarkdownSource(name: $0.source.name, kind: $0.source.kind.rawValue,
                                                        notes: $0.root.allNotes.count) }
            : nil
        let object = MCPStats.object(workspace: ws.name, today: today, from: range.from, to: range.to,
                                     document: document, report: report, markdown: markdown)
        let text = MCPStats.text(workspace: ws.name, today: today, from: range.from, to: range.to,
                                 document: document, report: report, markdown: markdown)
        return (object, text)
    }
}
