import Foundation

extension Notification.Name {
    /// 某个工作区的 Agent 记忆变了（存 / 改 / 删；object = 那个工作区）。管理窗口据此重读。
    static let agentMemoriesDidChange = Notification.Name("UniReader.agentMemoriesDidChange")
    /// 某个工作区记了一轮新的 Agent 对话（object = 那个工作区）。搜索索引据此对账。
    static let agentTurnsDidChange = Notification.Name("UniReader.agentTurnsDidChange")
}

/// Agent 记忆与对话记录的执行层（`ACP-AGENT-PLAN.md §21–22`）：`agent_memory`、`agent_turn` 两张表（v25）的读写。
/// 记忆的写入口：MCP `save_memory`（Agent 自己记）、管理窗口改正文；删除一律先进回收站（红线⑪）。
/// 对话记录只在 Agent 面板一轮正常答完时追加一行（`AgentChat`），没有删除入口。
/// 同步不用另做：两张表都在 `MirrorFp.specs` 里，离线副本 / 服务器照常带上。
extension WorkspaceManager {

    // MARK: 记忆

    /// 一条记忆最多多少字（再长就是笔记了，该写进 Markdown 笔记）。
    static let agentMemoryMaxLength = 2000

    /// 全部记忆，最近改过的在前。
    var agentMemories: [LibAgentMemory] { (try? store?.agentMemories()) ?? [] }

    func agentMemory(id: String) -> LibAgentMemory? { try? store?.agentMemory(id: id) }

    /// 记一条新的。返回存下的那条（写不进去 = nil，原因在 `lastError`）。
    @discardableResult
    func addAgentMemory(content: String, agent: String) -> LibAgentMemory? {
        guard let store else { return nil }
        let text = Self.cleanMemory(content)
        guard !text.isEmpty else { lastError = L("A memory can't be empty."); return nil }
        let now = Date()
        let m = LibAgentMemory(id: UUID().uuidString, content: text, agent: agent, createdAt: now, updatedAt: now)
        do { try store.upsertAgentMemory(m) } catch { lastError = "\(error)"; return nil }
        agentMemoriesChanged()
        return m
    }

    /// 改正文（管理窗口、MCP 带 id 的 `save_memory`）。没变就不写（免得 `updated_at` 白变、同步白传）。
    @discardableResult
    func updateAgentMemory(id: String, content: String) -> LibAgentMemory? {
        guard let store, var m = agentMemory(id: id) else { return nil }
        let text = Self.cleanMemory(content)
        guard !text.isEmpty else { lastError = L("A memory can't be empty."); return nil }
        guard text != m.content else { return m }
        m.content = text
        m.updatedAt = .now
        do { try store.upsertAgentMemory(m) } catch { lastError = "\(error)"; return nil }
        agentMemoriesChanged()
        return m
    }

    /// 删几条：**先归档进回收站，成功了才删**（红线⑪）。归档失败 = 一条都不删，返回 false。
    @discardableResult
    func trashAgentMemories(ids: [String]) -> Bool {
        guard let store else { return false }
        let rows = ids.compactMap(agentMemory(id:))
        guard !rows.isEmpty else { return true }
        let title = rows.count == 1 ? Self.memoryTitle(rows[0].content) : String(format: L("%d Agent memories"), rows.count)
        guard Trash.archiveAgentMemories(store: store, ids: rows.map(\.id), title: title) != nil else {
            lastError = String(format: L("Could not archive “%@”, so nothing was deleted."), title)
            return false
        }
        do { try store.deleteAgentMemories(ids: rows.map(\.id)) } catch { lastError = "\(error)"; return false }
        agentMemoriesChanged()
        return true
    }

    func agentMemoriesChanged() {
        NotificationCenter.default.post(name: .agentMemoriesDidChange, object: self)
    }

    static func cleanMemory(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.count > agentMemoryMaxLength ? String(t.prefix(agentMemoryMaxLength)) : t
    }

    /// 回收站条目 / 列表里一条记忆的名字：第一行，最多 40 字。
    static func memoryTitle(_ content: String) -> String {
        let line = content.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? ""
        return line.count > 40 ? String(line.prefix(40)) + "…" : line
    }

    // MARK: 对话记录

    /// 记一轮（Agent 面板一轮正常答完）。两边都空就不记。
    func recordAgentTurn(conversationId: String, agent: String, sessionId: String,
                         userText: String, replyText: String) {
        guard let store else { return }
        let u = userText.trimmingCharacters(in: .whitespacesAndNewlines)
        let r = replyText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !u.isEmpty || !r.isEmpty else { return }
        let now = Date()
        let t = LibAgentTurn(id: UUID().uuidString, conversationId: conversationId, agent: agent, sessionId: sessionId,
                             userText: u, replyText: r, createdAt: now, updatedAt: now)
        do { try store.insertAgentTurn(t) } catch { lastError = "\(error)"; return }
        NotificationCenter.default.post(name: .agentTurnsDidChange, object: self)
    }

    func agentTurns(conversationId: String) -> [LibAgentTurn] {
        (try? store?.agentTurns(conversationId: conversationId)) ?? []
    }

    func recentAgentConversations(limit: Int) -> [LibAgentConversation] {
        (try? store?.recentAgentConversations(limit: limit)) ?? []
    }
}
