import Foundation

/// Agent 上下文（`ACP-AGENT-PLAN.md §12`）里的几段文字：让 Agent 写交接摘要的说明、从回复里取标题与正文、
/// 带进新对话时给 Agent 看的那一块。纯 Foundation（`spike/agent-context-test.swift` 直接编它）。
enum AgentContextText {

    /// 「保存上下文」那一轮发给 Agent 的说明（英文：给模型看的；放进隐藏上下文块，回放时剔掉）。
    /// 🔴 要求第一行是 `# 标题`：存的时候按它切标题与正文（`parse`）。
    static let saveInstruction = """
    The user wants to save this conversation as a handoff context: a summary that another AI agent — possibly a different \
    product, starting from an empty conversation — will read to continue the same work. Write that summary now.
    - Write it in the user's language, as Markdown.
    - The very first line must be "# " followed by a short title for this work (at most 30 characters).
    - Then cover, briefly but concretely: the goal; what has been done and decided so far; the key facts the next agent \
    needs (document titles with document_id, note_ref, page numbers, exercise ids, file names, numbers, formulas); \
    the current state; open questions and next steps; preferences or instructions the user gave.
    - Write only from this conversation. Do not call tools, and do not change anything.
    - Reply with the summary only — nothing before the title line and nothing after the summary.
    """

    /// 存下的标题：去掉开头的 `#`、多余空白与换行，最长 60 个字（多了截断加省略号）。
    static func cleanTitle(_ raw: String) -> String {
        var t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while t.hasPrefix("#") { t.removeFirst() }
        t = t.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
        // 标题里常见的强调记号（**…**）去掉，列表里显示更干净
        if t.hasPrefix("**"), t.hasSuffix("**"), t.count > 4 { t = String(t.dropFirst(2).dropLast(2)) }
        if t.count > 60 { t = String(t.prefix(59)) + "…" }
        return t
    }

    /// 从 Agent 的回复里取标题与正文：第一个 Markdown 标题行（`# …`）就是标题，它后面的全部是正文
    /// （标题行前面的客套话丢掉）；没有标题行 = 第一行非空文字当标题、整段当正文。
    static func parse(_ reply: String) -> (title: String, summary: String) {
        let lines = reply.components(separatedBy: "\n")
        if let i = lines.firstIndex(where: isHeading) {
            let body = lines[(i + 1)...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            return (cleanTitle(lines[i]), body)
        }
        let first = lines.first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? ""
        return (cleanTitle(first), reply.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func isHeading(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        let hashes = t.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes) else { return false }
        let rest = t.dropFirst(hashes)
        return rest.first == " " && !rest.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// 带进新对话时给 Agent 看的那一块（英文说明 + 原样的摘要；外面由调用方包上隐藏上下文块的标签对）。
    /// `date` 用 ISO 日期（yyyy-MM-dd），给模型看，不本地化。
    static func handoff(title: String, summary: String, agent: String, id: String, date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        var by = agent.isEmpty ? "" : " by \(agent)"
        by += " on \(f.string(from: date))"
        return """
        The user attached a saved context (a handoff summary of an earlier conversation, written\(by)) so that you can \
        continue that work. Treat it as background you already know; you do not need to repeat it back. \
        If it mentions documents, notes or exercises, use the unireader MCP tools to look at them when needed.
        Saved context "\(title)" (context_id \(id)):
        \(summary)
        """
    }
}
