import Foundation

/// Agent 报上来的一条斜杠命令（ACP `available_commands_update`）。Kimi / Claude Code 建会话后推一次、技能变了再推；
/// 不推的 Agent 列表就空着——输入框里照样能打 `/命令`，只是面板不知道它有哪些。
struct AgentCommand: Equatable {
    var name: String
    var description: String
    /// 参数提示（如 Kimi `/compact` 的「<optional custom summarization instructions>」）。
    var hint: String?
}

/// 把一段选中的文字写成 Markdown 引用块（阅读区右键「在 Agent 中引用」放进输入框的那一段）。纯函数。
enum AgentQuote {
    /// 每行前面加 `> `（空行也加，免得引用块被断开）；首尾空白行去掉；末尾空一行，光标落在引用块下面接着写问题。
    static func markdown(_ text: String) -> String {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var trimmed = lines[...]
        while let f = trimmed.first, f.trimmingCharacters(in: .whitespaces).isEmpty { trimmed = trimmed.dropFirst() }
        while let l = trimmed.last, l.trimmingCharacters(in: .whitespaces).isEmpty { trimmed = trimmed.dropLast() }
        return trimmed.map { $0.isEmpty ? ">" : "> " + $0 }.joined(separator: "\n") + "\n\n"
    }
}

/// 斜杠命令的纯逻辑。纯 Foundation，spike `agent-usage-test.swift`。
enum AgentSlash {
    /// 这句话是不是斜杠命令。认法同三家 Agent（2026-10-26 读安装包源码：Kimi `parseSlashInput`、
    /// Qwen Code `isSlashCommand`、Claude Code 交给 SDK），都只看**第一块文字**：以 `/` 开头，
    /// `/` 后面到第一个空白是命令名、其余是参数；命令名是空的或里面还有 `/`（`/usr/bin/…` 这种路径）不算。
    static func parse(_ text: String) -> (name: String, args: String)? {
        guard text.hasPrefix("/") else { return nil }
        let body = text.dropFirst().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return nil }
        let name: String, args: String
        if let r = body.rangeOfCharacter(from: .whitespacesAndNewlines) {
            name = String(body[..<r.lowerBound])
            args = body[r.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            name = body
            args = ""
        }
        guard !name.contains("/") else { return nil }
        return (name, args)
    }

    /// 光标前是不是正在打一条斜杠命令的**名字**（输入框弹命令候选用，`ACP-AGENT-PLAN.md §14`）：整段话以 `/` 开头、
    /// 光标还在命令名里（`/` 到光标之间没有空白，也没有第二个 `/`——那是路径）。返回要整段替换的范围（从 `/` 到光标）与已经打的那几个字。
    static func activeQuery(in text: NSString, caret: Int) -> (range: NSRange, query: String)? {
        guard caret >= 1, caret <= text.length, text.length > 0, text.character(at: 0) == 0x2F else { return nil }
        let typed = text.substring(with: NSRange(location: 1, length: caret - 1))
        guard typed.rangeOfCharacter(from: .whitespacesAndNewlines) == nil, !typed.contains("/") else { return nil }
        return (NSRange(location: 0, length: caret), typed)
    }

    /// 按已经打的字给命令排序：名字以它开头的在前，其次名字里含的，再次说明里含的；都不中就不要。空 = 原顺序全给。不分大小写。
    static func rank(_ commands: [AgentCommand], query: String) -> [AgentCommand] {
        let q = query.lowercased()
        guard !q.isEmpty else { return commands }
        var tiers: [[AgentCommand]] = [[], [], []]
        for c in commands {
            let n = c.name.lowercased()
            if n.hasPrefix(q) { tiers[0].append(c) }
            else if n.contains(q) { tiers[1].append(c) }
            else if c.description.lowercased().contains(q) { tiers[2].append(c) }
        }
        return tiers.flatMap { $0 }
    }

    /// 压缩上下文的命令名：Kimi / Claude Code 叫 `compact`，Qwen Code 叫 `compress`。
    static let compactNames = ["compact", "compress"]

    /// 这个 Agent 压缩上下文用哪条命令（它报上来的命令里有才算）。没报 = nil，面板就不给「压缩上下文」那一项。
    static func compactCommand(in commands: [AgentCommand]) -> String? {
        compactNames.first { n in commands.contains { $0.name == n } }
    }
}
