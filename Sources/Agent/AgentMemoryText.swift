import Foundation

/// Agent 记忆与对话记录的纯逻辑（`ACP-AGENT-PLAN.md §21–22`）：记忆的标题、随每段新对话第一句话带上的「工作区记忆」块、
/// 对话的标题。纯 Foundation（`spike/agent-memory-test.swift` 直接编它；搜索索引在自己的线程上也调它）。
enum AgentMemoryText {
    struct Item: Equatable {
        var id: String
        var content: String
        var agent: String
        var updatedAt: Date
    }

    /// 带上的记忆最多占多少字（超过就只带最近改过的那些，告诉 Agent 一共几条、去哪看全部）。
    static let budget = 6000

    /// 一条记忆的名字（回收站条目、搜索结果）：第一行，最多 40 字。
    static func title(_ content: String) -> String {
        let line = content.split(separator: "\n", maxSplits: 1).first.map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        return line.count > 40 ? String(line.prefix(40)) + "…" : line
    }

    /// 一段对话的名字：用户的第一句话，压成一行，最多 40 字。
    static func conversationTitle(_ firstUserText: String) -> String {
        let flat = firstUserText.split(whereSeparator: \.isNewline).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        if flat.isEmpty { return "Conversation" }
        return flat.count > 40 ? String(flat.prefix(40)) + "…" : flat
    }

    /// 随每段新对话第一句话带上的说明 + 记忆（`items` 最近改过的在前）。放进隐藏上下文块，回放时剔掉；
    /// 第一行以 `AgentSentContext.Marker.memory` 开头，气泡下面那行「上下文」据此显示「工作区记忆 N 条」。
    /// 没有记忆也带上说明：Agent 得知道能记。
    static func block(_ items: [Item], now: Date = Date()) -> String {
        var shown: [Item] = []
        var used = 0
        for m in items {
            let cost = m.content.count + 40
            if !shown.isEmpty, used + cost > budget { break }
            shown.append(m)
            used += cost
        }
        var lines = [AgentSentContext.Marker.memory + " (\(shown.count) of \(items.count)): long-term memories (Agent 记忆) that agents saved in this workspace for later conversations. Use them as background; don't repeat them back to the user."]
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withFullDate]
        for m in shown {
            let body = m.content.replacingOccurrences(of: "\n", with: "\n  ")
            let by = m.agent.isEmpty ? "" : "\(m.agent), "
            lines.append("- [memory_id \(m.id.prefix(8))] \(body) (\(by)\(f.string(from: m.updatedAt)))")
        }
        if shown.count < items.count {
            lines.append("Only the \(shown.count) most recently updated are listed; list_memories (with query) has all \(items.count).")
        }
        lines.append(instructions)
        return lines.joined(separator: "\n")
    }

    /// 怎么记、怎么查（也写进 MCP 的 instructions，不是每个 Agent 都读那个）。
    static let instructions = "When you learn something worth keeping for later conversations in this workspace — the user's preferences and goals, what they are studying and how far they got, conventions they want followed — save it with save_memory: one short fact per memory, in the user's language, no secrets. Update an outdated memory with save_memory id, and delete a wrong one with delete_memory. Earlier conversations in this workspace are saved too: to recall what was discussed, use search with kinds conversation, then read_conversation."
}
