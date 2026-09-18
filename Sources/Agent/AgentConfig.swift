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

    static var command: String {
        let s = UserDefaults.standard.string(forKey: commandKey)?.trimmingCharacters(in: .whitespaces) ?? ""
        return s.isEmpty ? defaultCommand : s
    }

    /// 参数按空白切开。不做引号解析——ACP Agent 的参数都是 `acp` / `--acp` 这类单词。
    static var arguments: [String] {
        let s = UserDefaults.standard.string(forKey: argumentsKey) ?? defaultArguments
        return s.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    /// 面板上显示的 Agent 名字：取命令的文件名（`kimi` → Kimi）。
    static var displayName: String {
        let base = (command as NSString).lastPathComponent
        return base.prefix(1).uppercased() + base.dropFirst()
    }

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
