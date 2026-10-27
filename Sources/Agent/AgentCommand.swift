import Foundation

/// Agent 报上来的一条斜杠命令（ACP `available_commands_update`）。Kimi / Claude Code 建会话后推一次、技能变了再推；
/// 不推的 Agent 列表就空着——输入框里照样能打 `/命令`，只是面板不知道它有哪些。
struct AgentCommand: Equatable {
    var name: String
    var description: String
    /// 参数提示（如 Kimi `/compact` 的「<optional custom summarization instructions>」）。
    var hint: String?
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

    /// 压缩上下文的命令名：Kimi / Claude Code 叫 `compact`，Qwen Code 叫 `compress`。
    static let compactNames = ["compact", "compress"]

    /// 这个 Agent 压缩上下文用哪条命令（它报上来的命令里有才算）。没报 = nil，面板就不给「压缩上下文」那一项。
    static func compactCommand(in commands: [AgentCommand]) -> String? {
        compactNames.first { n in commands.contains { $0.name == n } }
    }
}
