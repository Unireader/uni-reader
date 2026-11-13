import Foundation

/// 批 7（2026-11-13）：Agent 记忆与对话记录（`ACP-AGENT-PLAN.md §21–22`）。
/// 记忆：Agent 自己记下的长期备忘，App 里每段新对话的第一句话自动带上；这里能列、存、改、删（删先进回收站）。
/// 对话记录：App 的 Agent 面板每一轮正常答完记一行；这里能列出最近的对话、读某一段（全文查找走 `search` 的 conversation）。
/// 🔴 每个返回的键都要在 `outputSchema` 里声明（Kimi 严格校验，多一个键整次调用作废）。
extension MCPTools {

    static func registerBatch7(into server: MCPServer) {
        let c = server.catalog
        c.register(listMemoriesTool())
        c.register(saveMemoryTool())
        c.register(deleteMemoryTool())
        c.register(listConversationsTool())
        c.register(readConversationTool())
    }

    private static let workspaceArg = MCPSchema.string("Workspace .unrd path; default = the workspace of the key reader window.")

    private static var memoryItemSchema: MCPObject {
        MCPSchema.object([
            "id": MCPSchema.string("memory id"),
            "content": MCPSchema.string("the memory (Markdown)"),
            "agent": MCPSchema.string("the agent that saved it (may be empty)"),
            "created_at": MCPSchema.string("ISO 8601"),
            "updated_at": MCPSchema.string("ISO 8601"),
        ])
    }

    static func listMemoriesTool() -> MCPTool {
        MCPTool(
            name: "list_memories",
            title: "List workspace memories",
            description: "List the long-term memories (Agent 记忆) saved in a workspace, most recently updated first: short facts agents saved for later conversations — the user's preferences and goals, what they are studying and how far they got, conventions. In UniReader's Agent panel they are attached to the first message of every new conversation; other agents can read them here. query keeps only memories containing all of its words; for meaning-based search use search with kinds memory.",
            inputSchema: MCPSchema.object([
                "workspace": workspaceArg,
                "query": MCPSchema.string("only memories containing all of these words (case-insensitive)"),
            ]),
            outputSchema: MCPSchema.object([
                "memories": MCPSchema.array(of: memoryItemSchema),
                "total": MCPSchema.integer("how many memories the workspace has"),
            ]),
            tier: .read
        ) { _, args in
            let wsPath = try args.string("workspace")
            let query = try args.string("query")
            let r = try await MainActor.run { try MCPFacade.shared.listMemories(query: query, workspacePath: wsPath) }
            let list = r["memories"] as? [MCPObject] ?? []
            let text = list.isEmpty
                ? (query == nil ? "No memories are saved in this workspace." : "No memory matches.")
                : list.map { "- [\(($0["id"] as? String ?? "").prefix(8))] \($0["content"] ?? "")" }.joined(separator: "\n")
            return MCPToolResult(text: text, structured: r)
        }
    }

    static func saveMemoryTool() -> MCPTool {
        MCPTool(
            name: "save_memory",
            title: "Save a workspace memory",
            description: "Save one long-term memory in the workspace, for later conversations with any agent: a short fact worth keeping (the user's preferences and goals, what they are studying and how far they got, conventions they want followed). One fact per memory, in the user's language, at most a few sentences; never secrets. Give id to rewrite an existing memory (e.g. when it is outdated) instead of adding a near-duplicate — check list_memories first.",
            inputSchema: MCPSchema.object([
                "workspace": workspaceArg,
                "content": MCPSchema.string("the memory (Markdown, at most 2000 characters)"),
                "id": MCPSchema.string("existing memory id to rewrite (full, or its first 8 characters)"),
            ], required: ["content"]),
            outputSchema: MCPSchema.object([
                "id": MCPSchema.string("memory id"),
                "created": MCPSchema.boolean("true = a new memory; false = an existing one was rewritten"),
            ]),
            tier: .write
        ) { ctx, args in
            guard let content = try args.string("content"),
                  !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw MCPInvalidParams("content is required")
            }
            let id = try args.string("id")
            let wsPath = try args.string("workspace")
            let agent = ctx.clientName == MCPCallContext.anonymous.clientName ? "" : ctx.clientName
            let r = try await MainActor.run {
                try MCPFacade.shared.saveMemory(id: id, content: content, agent: agent, workspacePath: wsPath)
            }
            let verb = (r["created"] as? Bool) == true ? "Saved" : "Updated"
            return MCPToolResult(text: "\(verb) the memory (id \(r["id"] ?? "")).", structured: r)
        }
    }

    static func deleteMemoryTool() -> MCPTool {
        MCPTool(
            name: "delete_memory",
            title: "Delete workspace memories",
            description: "Delete memories that are wrong or no longer useful (they go to UniReader's Trash and can be restored there). Rewrite an outdated one with save_memory id instead of deleting and re-adding it.",
            inputSchema: MCPSchema.object([
                "workspace": workspaceArg,
                "ids": MCPSchema.array(of: MCPSchema.string("memory id (full, or its first 8 characters)"), "memories to delete"),
            ], required: ["ids"]),
            outputSchema: MCPSchema.object([
                "deleted": MCPSchema.integer("how many were moved to the Trash"),
            ]),
            tier: .delete
        ) { _, args in
            guard let list = args.raw["ids"] as? [Any], !list.isEmpty else { throw MCPInvalidParams("ids is required") }
            let ids = list.compactMap { $0 as? String }
            let wsPath = try args.string("workspace")
            let r = try await MainActor.run { try MCPFacade.shared.deleteMemories(ids: ids, workspacePath: wsPath) }
            return MCPToolResult(text: "Moved \(r["deleted"] ?? 0) memory(ies) to the Trash.", structured: r)
        }
    }

    static func listConversationsTool() -> MCPTool {
        MCPTool(
            name: "list_conversations",
            title: "List earlier agent conversations",
            description: "List earlier conversations held in UniReader's Agent panel in this workspace (each turn — the user's message and the agent's reply, without tool output — is saved when it finishes), most recent first. Read one with read_conversation; to find what was said about something, use search with kinds conversation.",
            inputSchema: MCPSchema.object([
                "workspace": workspaceArg,
                "limit": MCPSchema.integer("how many (default 20, max 100)", min: 1, max: 100),
            ]),
            outputSchema: MCPSchema.object([
                "conversations": MCPSchema.array(of: MCPSchema.object([
                    "id": MCPSchema.string("conversation id for read_conversation"),
                    "first_message": MCPSchema.string("the user's first message (shortened)"),
                    "agent": MCPSchema.string("the agent"),
                    "turns": MCPSchema.integer("how many turns"),
                    "started_at": MCPSchema.string("ISO 8601"),
                    "last_at": MCPSchema.string("ISO 8601, last turn"),
                ])),
            ]),
            tier: .read
        ) { _, args in
            let wsPath = try args.string("workspace")
            let limit = min(100, max(1, try args.int("limit") ?? 20))
            let r = try await MainActor.run { try MCPFacade.shared.listConversations(limit: limit, workspacePath: wsPath) }
            let list = r["conversations"] as? [MCPObject] ?? []
            let text = list.isEmpty ? "No conversations are saved in this workspace."
                : list.map { "- \($0["last_at"] ?? "") [\($0["agent"] ?? "")] \($0["first_message"] ?? "") (\($0["turns"] ?? 0) turns, id \($0["id"] ?? ""))" }
                    .joined(separator: "\n")
            return MCPToolResult(text: text, structured: r)
        }
    }

    static func readConversationTool() -> MCPTool {
        MCPTool(
            name: "read_conversation",
            title: "Read an earlier agent conversation",
            description: "Read the turns of an earlier conversation in UniReader's Agent panel: what the user said and what the agent replied (tool output and thinking are not saved). Long conversations come in pages: pass offset = next_offset to go on. A search hit of kind conversation gives the conversation id and its turn number (use it as offset).",
            inputSchema: MCPSchema.object([
                "workspace": workspaceArg,
                "id": MCPSchema.string("conversation id from list_conversations or search"),
                "offset": MCPSchema.integer("first turn to return, 1-based (default 1)", min: 1),
                "limit": MCPSchema.integer("max turns (default 20, max 100)", min: 1, max: 100),
            ], required: ["id"]),
            outputSchema: MCPSchema.object([
                "id": MCPSchema.string("conversation id"),
                "total_turns": MCPSchema.integer("turns in the conversation"),
                "turns": MCPSchema.array(of: MCPSchema.object([
                    "turn": MCPSchema.integer("1-based"),
                    "agent": MCPSchema.string("the agent"),
                    "user": MCPSchema.string("what the user said"),
                    "reply": MCPSchema.string("what the agent replied (Markdown)"),
                    "at": MCPSchema.string("ISO 8601"),
                ])),
                "next_offset": MCPSchema.nullable(MCPSchema.integer("offset for the next page; null at the end")),
            ]),
            tier: .read
        ) { _, args in
            guard let id = try args.string("id"), !id.isEmpty else { throw MCPInvalidParams("id is required") }
            let wsPath = try args.string("workspace")
            let offset = max(1, try args.int("offset") ?? 1)
            let limit = min(100, max(1, try args.int("limit") ?? 20))
            let r = try await MainActor.run {
                try MCPFacade.shared.readConversation(id: id, offset: offset, limit: limit, workspacePath: wsPath)
            }
            let turns = r["turns"] as? [MCPObject] ?? []
            var text = turns.map { "## Turn \($0["turn"] ?? "") — \($0["at"] ?? "")\n**User:** \($0["user"] ?? "")\n\n**\($0["agent"] ?? "Agent"):** \($0["reply"] ?? "")" }
                .joined(separator: "\n\n")
            if let next = r["next_offset"] as? Int { text += "\n\n(more: offset \(next))" }
            return MCPToolResult(text: text.isEmpty ? "No turns." : text, structured: r)
        }
    }
}

// MARK: - 执行（主线程）

extension MCPFacade {

    func listMemories(query: String?, workspacePath: String?) throws -> MCPObject {
        let ws = try manager(workspacePath: workspacePath)
        let all = ws.agentMemories
        let words = (query ?? "").lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        let picked = words.isEmpty ? all : all.filter { m in
            let t = m.content.lowercased()
            return words.allSatisfy { t.contains($0) }
        }
        return ["memories": picked.map { m -> MCPObject in
                    ["id": m.id, "content": m.content, "agent": m.agent,
                     "created_at": ISO.string(m.createdAt), "updated_at": ISO.string(m.updatedAt)]
                },
                "total": all.count]
    }

    func saveMemory(id: String?, content: String, agent: String, workspacePath: String?) throws -> MCPObject {
        let ws = try manager(workspacePath: workspacePath)
        if let id, !id.isEmpty {
            let m = try resolveMemory(id, in: ws)
            guard let saved = ws.updateAgentMemory(id: m.id, content: content) else {
                throw MCPToolError(ws.lastError ?? "could not save the memory")
            }
            return ["id": saved.id, "created": false]
        }
        guard let saved = ws.addAgentMemory(content: content, agent: agent) else {
            throw MCPToolError(ws.lastError ?? "could not save the memory")
        }
        return ["id": saved.id, "created": true]
    }

    func deleteMemories(ids: [String], workspacePath: String?) throws -> MCPObject {
        let ws = try manager(workspacePath: workspacePath)
        let rows = try ids.map { try resolveMemory($0, in: ws) }
        guard ws.trashAgentMemories(ids: rows.map(\.id)) else {
            throw MCPToolError(ws.lastError ?? "could not delete the memories")
        }
        return ["deleted": rows.count]
    }

    func listConversations(limit: Int, workspacePath: String?) throws -> MCPObject {
        let ws = try manager(workspacePath: workspacePath)
        return ["conversations": ws.recentAgentConversations(limit: limit).map { c -> MCPObject in
            ["id": c.id, "first_message": AgentMemoryText.conversationTitle(c.firstUserText), "agent": c.agent,
             "turns": c.turns, "started_at": ISO.string(c.startedAt), "last_at": ISO.string(c.lastAt)]
        }]
    }

    func readConversation(id: String, offset: Int, limit: Int, workspacePath: String?) throws -> MCPObject {
        let ws = try manager(workspacePath: workspacePath)
        let all = ws.agentTurns(conversationId: id)
        guard !all.isEmpty else { throw MCPToolError("no conversation with id \(id); call list_conversations") }
        let start = min(offset - 1, all.count)
        let end = min(start + limit, all.count)
        let page = all[start..<end].enumerated().map { i, t -> MCPObject in
            ["turn": start + i + 1, "agent": t.agent, "user": t.userText, "reply": t.replyText, "at": ISO.string(t.createdAt)]
        }
        return ["id": id, "total_turns": all.count, "turns": page,
                "next_offset": end < all.count ? end + 1 as Any : NSNull()]
    }

    /// 完整 id，或至少 8 个字符的前缀（唯一才算）。
    private func resolveMemory(_ id: String, in ws: WorkspaceManager) throws -> LibAgentMemory {
        if let m = ws.agentMemory(id: id) { return m }
        let key = id.uppercased()
        let hits = key.count >= 8 ? ws.agentMemories.filter { $0.id.uppercased().hasPrefix(key) } : []
        guard hits.count == 1 else {
            throw MCPToolError(hits.isEmpty ? "no memory with id \(id); call list_memories"
                                            : "id \(id) matches several memories; give the full id")
        }
        return hits[0]
    }
}
