import AppKit
import OSLog
import UniformTypeIdentifiers

/// 帮助 › 导出排查日志…（发布版也有，2026-11-14 用户定：平时用的就是发布版，出了问题当场导出、交回来）。
///
/// 存成一个文本文件，三段：
/// 1. 版本与环境：App 版本 / 构建号、macOS、机型、内存、本次运行了多久。
/// 2. App 自己最近一小时的日志：本进程里没有子系统名的（`NSLog` 写的）与本 App 子系统的，各级都要。
/// 3. 最近一小时系统框架在本进程里报的错误（error / fault 两级），比如 Core Animation、网络的报错。
///
/// 只读本进程（`OSLogStore(scope: .currentProcessIdentifier)`，不要额外权限）；App 重开过就只剩这次运行的。
/// 2026-11-13 排查表格空白时的第一版还带引擎的表格现场与表格日志（`TableTraceExport`），那个接口只在引擎排查分支上有，
/// 发布版引擎没有，故拿掉；引擎修好发版后要再加，接在第 1 段后面。
@MainActor
enum DiagnosticLogExport {
    /// 往回看多久。
    static let window: TimeInterval = 60 * 60

    static func run() {
        let taken = Date()
        let panel = NSSavePanel()
        panel.title = L("Export Diagnostic Log…")
        panel.nameFieldStringValue = "UniReader-diagnostic-\(fileStamp(taken)).txt"
        panel.allowedContentTypes = [.plainText]
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let header = Self.header(taken: taken)
        let bundleID = Bundle.main.bundleIdentifier ?? ""
        Task.detached(priority: .userInitiated) {
            let (own, system) = Self.logs(since: taken.addingTimeInterval(-window), bundleID: bundleID)
            let text = [
                header,
                "==== 2. App 自己最近一小时的日志（旧 → 新）\n" + own,
                "==== 3. 最近一小时系统框架报的错误（旧 → 新）\n" + system,
            ].joined(separator: "\n\n") + "\n"
            do {
                try text.write(to: url, atomically: true, encoding: .utf8)
                await MainActor.run { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            } catch {
                await MainActor.run {
                    let alert = NSAlert(error: error)
                    alert.messageText = L("Could not save the diagnostic log.")
                    alert.runModal()
                }
            }
        }
    }

    private static func header(taken: Date) -> String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        let process = ProcessInfo.processInfo
        let uptime = Int(taken.timeIntervalSince(launchTime))
        return """
        UniReader 排查日志
        ==== 1. 版本与环境
        导出时间：\(ISO8601DateFormatter().string(from: taken))
        App：\(version) (\(build))\(isDebugBuild ? "  Debug 包" : "")
        macOS：\(process.operatingSystemVersionString)  机型：\(hardwareModel())  内存：\(process.physicalMemory / 1_073_741_824) GB
        本次运行：\(uptime / 3600) 小时 \(uptime % 3600 / 60) 分
        """
    }

    /// 进程启动时刻（第一次用到时取，近似；只用来算「本次运行了多久」）。
    private static let launchTime: Date = {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return Date() }
        let t = info.kp_proc.p_starttime
        return Date(timeIntervalSince1970: TimeInterval(t.tv_sec) + TimeInterval(t.tv_usec) / 1_000_000)
    }()

    private static var isDebugBuild: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }

    private static func hardwareModel() -> String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        guard size > 0 else { return "?" }
        var buf = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &buf, &size, nil, 0)
        return String(cString: buf)
    }

    private static func fileStamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: date)
    }

    /// 本进程自 `since` 起的日志：App 自己的（各级）与系统框架的 error / fault，各最多 3000 条（只留最新的）。
    nonisolated private static func logs(since: Date, bundleID: String) -> (own: String, system: String) {
        do {
            let store = try OSLogStore(scope: .currentProcessIdentifier)
            let entries = try store.getEntries(at: store.position(date: since))
            let clock = DateFormatter()
            clock.locale = Locale(identifier: "en_US_POSIX")
            clock.dateFormat = "HH:mm:ss.SSS"
            var own: [String] = [], system: [String] = []
            for case let entry as OSLogEntryLog in entries {
                let mine = entry.subsystem.isEmpty || (!bundleID.isEmpty && entry.subsystem.hasPrefix(bundleID))
                let level: String
                switch entry.level {
                case .debug: level = "debug"
                case .info: level = "info"
                case .notice: level = "notice"
                case .error: level = "ERROR"
                case .fault: level = "FAULT"
                default: level = "-"
                }
                if mine {
                    own.append("\(clock.string(from: entry.date)) \(level) \(entry.composedMessage)")
                } else if entry.level == .error || entry.level == .fault {
                    system.append("\(clock.string(from: entry.date)) \(level) [\(entry.subsystem)/\(entry.category)] \(entry.composedMessage)")
                }
            }
            return (own.isEmpty ? "（没有）" : own.suffix(3000).joined(separator: "\n"),
                    system.isEmpty ? "（没有）" : system.suffix(3000).joined(separator: "\n"))
        } catch {
            let message = "读系统日志失败：\(error)"
            return (message, message)
        }
    }
}
