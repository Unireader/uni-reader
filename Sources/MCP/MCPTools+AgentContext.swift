import Foundation

/// 批 5：Agent 上下文（`ACP-AGENT-PLAN.md §12`）。工作区里存下的「一段 Agent 对话的交接摘要」，
/// 任何 Agent（App 里的 Kimi / Claude Code / Qwen，或终端里的外部 Agent）都能列出来、读、存。
/// 🔴 每个返回的键都要在 `outputSchema` 里声明（Kimi 严格校验，多一个键整次调用作废）。
extension MCPTools {

    static func registerBatch5(into server: MCPServer) {
        let c = server.catalog
        c.register(listAgentContextsTool())
        c.register(readAgentContextTool())
        c.register(saveAgentContextTool())
    }

    private static var contextItemSchema: MCPObject {
        MCPSchema.object([
            "id": MCPSchema.string("context id"),
            "title": MCPSchema.string("title"),
            "agent": MCPSchema.string("the agent that wrote it (may be empty)"),
            "created_at": MCPSchema.string("ISO 8601"),
            "updated_at": MCPSchema.string("ISO 8601"),
            "length": MCPSchema.integer("length of the summary in characters"),
        ])
    }

    static func listAgentContextsTool() -> MCPTool {
        MCPTool(
            name: "list_agent_contexts",
            title: "List saved agent contexts",
            description: "List the agent contexts saved in a workspace, most recently updated first. An agent context (Agent 上下文) is a handoff summary of an earlier conversation with some agent, saved so that any agent can continue that work. Read one with read_agent_context.",
            inputSchema: MCPSchema.object([
                "workspace": MCPSchema.string("Workspace .unrd path; default = the workspace of the key reader window."),
            ]),
            outputSchema: MCPSchema.object([
                "contexts": MCPSchema.array(of: contextItemSchema),
                "total": MCPSchema.integer("how many are saved"),
            ]),
            tier: .read
        ) { _, args in
            let wsPath = try args.string("workspace")
            let r = try await MainActor.run { try MCPFacade.shared.listAgentContexts(workspacePath: wsPath) }
            let n = r["total"] as? Int ?? 0
            return MCPToolResult(text: n == 0 ? "No agent contexts are saved in this workspace." : "\(n) agent context(s).",
                                 structured: r)
        }
    }

    static func readAgentContextTool() -> MCPTool {
        MCPTool(
            name: "read_agent_context",
            title: "Read a saved agent context",
            description: "Read one saved agent context: its title and the full handoff summary (Markdown). Use it as background to continue the work it describes.",
            inputSchema: MCPSchema.object([
                "workspace": MCPSchema.string("Workspace .unrd path; default = the workspace of the key reader window."),
                "id": MCPSchema.string("context id from list_agent_contexts (full, or its first 8 characters)"),
            ], required: ["id"]),
            outputSchema: MCPSchema.object([
                "id": MCPSchema.string("context id"),
                "title": MCPSchema.string("title"),
                "agent": MCPSchema.string("the agent that wrote it (may be empty)"),
                "created_at": MCPSchema.string("ISO 8601"),
                "updated_at": MCPSchema.string("ISO 8601"),
                "summary": MCPSchema.string("the handoff summary (Markdown)"),
            ]),
            tier: .read
        ) { _, args in
            guard let id = try args.string("id"), !id.isEmpty else { throw MCPInvalidParams("id is required") }
            let wsPath = try args.string("workspace")
            let r = try await MainActor.run { try MCPFacade.shared.readAgentContext(id: id, workspacePath: wsPath) }
            return MCPToolResult(text: "# \(r["title"] ?? "")\n\n\(r["summary"] ?? "")", structured: r)
        }
    }

    static func saveAgentContextTool() -> MCPTool {
        MCPTool(
            name: "save_agent_context",
            title: "Save an agent context",
            description: "Save a handoff summary of the current conversation as an agent context in the workspace, so the user can continue this work later with any agent. Only when the user asks to save the context. Write the summary in the user's language as Markdown: the goal, what was done and decided, key facts the next agent needs (document titles with document_id, note_ref, page numbers, ids), the current state, open questions and next steps. Give id to replace the title / summary of an existing context instead of adding a new one.",
            inputSchema: MCPSchema.object([
                "workspace": MCPSchema.string("Workspace .unrd path; default = the workspace of the key reader window."),
                "title": MCPSchema.string("short title (at most 30 characters)"),
                "summary": MCPSchema.string("the handoff summary (Markdown), without the title"),
                "id": MCPSchema.string("existing context id to update (optional)"),
            ], required: ["title", "summary"]),
            outputSchema: MCPSchema.object([
                "id": MCPSchema.string("context id"),
                "title": MCPSchema.string("the title as saved"),
                "created": MCPSchema.boolean("true = a new context; false = an existing one was updated"),
            ]),
            tier: .write
        ) { ctx, args in
            guard let title = try args.string("title"), let summary = try args.string("summary"),
                  !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw MCPInvalidParams("title and a non-empty summary are required")
            }
            let id = try args.string("id")
            let wsPath = try args.string("workspace")
            let agent = ctx.clientName == MCPCallContext.anonymous.clientName ? "" : ctx.clientName
            let r = try await MainActor.run {
                try MCPFacade.shared.saveAgentContext(id: id, title: title, summary: summary, agent: agent,
                                                      workspacePath: wsPath)
            }
            let verb = (r["created"] as? Bool) == true ? "Saved" : "Updated"
            return MCPToolResult(text: "\(verb) the agent context “\(r["title"] ?? "")”.", structured: r)
        }
    }
}

// MARK: - 执行（主线程）

extension MCPFacade {

    func listAgentContexts(workspacePath: String?) throws -> MCPObject {
        let ws = try manager(workspacePath: workspacePath)
        let all = ws.agentContexts
        return ["contexts": all.map { c -> MCPObject in
                    ["id": c.id, "title": c.title, "agent": c.agent,
                     "created_at": ISO.string(c.createdAt), "updated_at": ISO.string(c.updatedAt),
                     "length": c.summary.count]
                },
                "total": all.count]
    }

    func readAgentContext(id: String, workspacePath: String?) throws -> MCPObject {
        let ws = try manager(workspacePath: workspacePath)
        let c = try resolveAgentContext(id, in: ws)
        return ["id": c.id, "title": c.title, "agent": c.agent,
                "created_at": ISO.string(c.createdAt), "updated_at": ISO.string(c.updatedAt),
                "summary": c.summary]
    }

    func saveAgentContext(id: String?, title: String, summary: String, agent: String,
                          workspacePath: String?) throws -> MCPObject {
        let ws = try manager(workspacePath: workspacePath)
        if let id, !id.isEmpty {
            let c = try resolveAgentContext(id, in: ws)
            guard let saved = ws.updateAgentContext(id: c.id, title: title, summary: summary) else {
                throw MCPToolError(ws.lastError ?? "could not save the agent context")
            }
            return ["id": saved.id, "title": saved.title, "created": false]
        }
        guard let saved = ws.addAgentContext(title: title, summary: summary, agent: agent, sessionId: "") else {
            throw MCPToolError(ws.lastError ?? "could not save the agent context")
        }
        return ["id": saved.id, "title": saved.title, "created": true]
    }

    /// 完整 id，或至少 8 个字符的前缀（唯一才算）。
    private func resolveAgentContext(_ id: String, in ws: WorkspaceManager) throws -> LibAgentContext {
        if let c = ws.agentContext(id: id) { return c }
        let key = id.uppercased()
        let hits = key.count >= 8 ? ws.agentContexts.filter { $0.id.uppercased().hasPrefix(key) } : []
        guard hits.count == 1 else {
            throw MCPToolError(hits.isEmpty ? "no agent context with id \(id); call list_agent_contexts"
                                            : "id \(id) matches several agent contexts; give the full id")
        }
        return hits[0]
    }
}
