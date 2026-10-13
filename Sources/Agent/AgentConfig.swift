import ACP
import Foundation

/// 内置 Agent 面板启动哪个 Agent（`ACP-AGENT-PLAN.md`）。
///
/// 首批只接 Kimi（`kimi acp`，用户 2026-09-18 定；Claude 的官方适配器要 Node，先不管）。
/// 这里只是「一条命令 + 参数」：将来换别家 ACP Agent 改设置就行，客户端一行不用动。
///
/// 🔴 **App 不装任何东西**：找不到命令就在面板里说清楚，让用户自己装（项目规矩：不代装依赖）。
enum AgentConfig {
    static let commandKey = "agentCommand"
    static let argumentsKey = "agentArguments"

    static let defaultCommand = "kimi"
    static let defaultArguments = "acp"

    /// 设置页的快捷选项：都是「命令 + 参数」，协议层与 Kimi 完全一致（Qwen Code 0.25.1 实测：
    /// 握手 / `session/new` 带 modes + configOptions / `session/list` 带标题 / 流式更新，客户端一行不用改）。
    enum Preset: String, CaseIterable {
        case kimi, qwen, claude
        var command: String {
            switch self { case .kimi: "kimi"; case .qwen: "qwen"; case .claude: "claude-agent-acp" }
        }
        var arguments: String {
            switch self { case .kimi: "acp"; case .qwen: "--acp"; case .claude: "" }
        }
        var title: String {
            switch self { case .kimi: "Kimi"; case .qwen: "Qwen Code"; case .claude: "Claude Code" }
        }
    }

    static func preset(command: String, arguments: String) -> Preset? {
        let c = command.trimmingCharacters(in: .whitespaces)
        let a = arguments.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return Preset.allCases.first { ($0.command == c || (c.isEmpty && $0 == .kimi)) && $0.arguments == a }
    }

    static var command: String {
        let s = UserDefaults.standard.string(forKey: commandKey)?.trimmingCharacters(in: .whitespaces) ?? ""
        return s.isEmpty ? defaultCommand : s
    }

    /// 参数按空白切开。不做引号解析——ACP Agent 的参数都是 `acp` / `--acp` 这类单词。
    static var arguments: [String] {
        let s = UserDefaults.standard.string(forKey: argumentsKey) ?? defaultArguments
        return s.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    /// 一次启动用的「命令 + 参数」。进程按它启动、池子按它认：设置里换了 Agent，正在跑的进程和设置对不上，
    /// 点「新对话」才换到按新设置起的进程上（用户 2026-10-13 定），还在旧进程上的对话照旧聊。
    struct Launch: Equatable {
        var command: String
        var arguments: [String]

        /// 面板上显示的 Agent 名字：取命令的文件名（`kimi` → Kimi）。
        var displayName: String {
            let base = (command as NSString).lastPathComponent
            return base.prefix(1).uppercased() + base.dropFirst()
        }
    }

    /// 设置里现在选的。
    static var current: Launch { Launch(command: command, arguments: arguments) }

    /// 设置里现在选的那个 Agent 的名字（还没连上时用；连上了以 `AgentChat.agentName` 为准）。
    static var displayName: String { current.displayName }

    enum ResolveError: LocalizedError {
        case notFound(String)
        var errorDescription: String? {
            switch self {
            case .notFound(let cmd):
                return String(format: L("Cannot find “%@”. Install it in Terminal first, or set its full path in Settings › Agent."), cmd)
            }
        }
    }

    /// 把命令解析成绝对路径。
    ///
    /// GUI App 从 Finder 启动时 PATH 只有系统那几个目录，找不到 `~/.kimi-code/bin/kimi` 这类
    /// 用户自装的命令——所以按**登录 shell 的 PATH** 找（swift-acp 的 `ShellEnvironment`，读一次缓存）。
    static func resolveExecutable(_ command: String) async throws -> String {
        let fm = FileManager.default
        if command.contains("/") {
            let path = (command as NSString).expandingTildeInPath
            guard fm.isExecutableFile(atPath: path) else { throw ResolveError.notFound(command) }
            return path
        }
        let env = await ShellEnvironment.loadUserShellEnvironmentAsync()
        let dirs = (env["PATH"] ?? ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":").map(String.init)
        for dir in dirs {
            let path = (dir as NSString).appendingPathComponent(command)
            if fm.isExecutableFile(atPath: path) { return path }
        }
        throw ResolveError.notFound(command)
    }
}
