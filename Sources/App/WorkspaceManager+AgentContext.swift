import Foundation

extension Notification.Name {
    /// 某个工作区的 Agent 上下文变了（存 / 改 / 删；object = 那个工作区）。管理窗口据此重读。
    static let agentContextsDidChange = Notification.Name("UniReader.agentContextsDidChange")
}

/// Agent 上下文的执行层（`ACP-AGENT-PLAN.md §12`）：`agent_context` 表的读写。
/// 写入只有三个口：Agent 面板「保存上下文」（Agent 写完摘要那一轮）、管理窗口改标题 / 摘要、MCP `save_agent_context`。
/// 删除一律先进回收站（红线⑪）。同步不用另做：这张表在 `MirrorFp.specs` 里，离线副本 / 服务器照常带上。
extension WorkspaceManager {

    /// 全部上下文，最近改过的在前。
    var agentContexts: [LibAgentContext] { (try? store?.agentContexts()) ?? [] }

    func agentContext(id: String) -> LibAgentContext? { try? store?.agentContext(id: id) }

    /// 存一份新的。返回存下的那份（写不进去 = nil，原因在 `lastError`）。
    @discardableResult
    func addAgentContext(title: String, summary: String, agent: String, sessionId: String) -> LibAgentContext? {
        guard let store else { return nil }
        let now = Date()
        var t = AgentContextText.cleanTitle(title)
        if t.isEmpty { t = String(format: L("Context %@"), now.formatted(date: .abbreviated, time: .shortened)) }
        let c = LibAgentContext(id: UUID().uuidString, title: t,
                                summary: summary.trimmingCharacters(in: .whitespacesAndNewlines),
                                agent: agent, sessionId: sessionId, createdAt: now, updatedAt: now)
        do { try store.upsertAgentContext(c) } catch { lastError = "\(error)"; return nil }
        agentContextsChanged()
        return c
    }

    /// 改标题 / 摘要（管理窗口、MCP 带 id 的 `save_agent_context`）。没变就不写（免得 `updated_at` 白变、同步白传）。
    @discardableResult
    func updateAgentContext(id: String, title: String? = nil, summary: String? = nil) -> LibAgentContext? {
        guard let store, var c = agentContext(id: id) else { return nil }
        let t = title.map(AgentContextText.cleanTitle) ?? c.title
        let s = summary.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } ?? c.summary
        guard t != c.title || s != c.summary else { return c }
        c.title = t
        c.summary = s
        c.updatedAt = .now
        do { try store.upsertAgentContext(c) } catch { lastError = "\(error)"; return nil }
        agentContextsChanged()
        return c
    }

    /// 删几份：**先归档进回收站，成功了才删**（红线⑪）。归档失败 = 一份都不删，返回 false。
    @discardableResult
    func trashAgentContexts(ids: [String]) -> Bool {
        guard let store else { return false }
        let rows = ids.compactMap(agentContext(id:))
        guard !rows.isEmpty else { return true }
        let title = rows.count == 1 ? rows[0].title : String(format: L("%d Agent contexts"), rows.count)
        guard Trash.archiveAgentContexts(store: store, ids: rows.map(\.id), title: title) != nil else {
            lastError = String(format: L("Could not archive “%@”, so nothing was deleted."), title)
            return false
        }
        do { try store.deleteAgentContexts(ids: rows.map(\.id)) } catch { lastError = "\(error)"; return false }
        agentContextsChanged()
        return true
    }

    func agentContextsChanged() {
        NotificationCenter.default.post(name: .agentContextsDidChange, object: self)
    }
}
