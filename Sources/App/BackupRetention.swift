import Foundation

/// 备份文件的命名（方案 `BACKUP-PLAN.md §3.1`）。
///
/// 和保留策略放在同一个**纯 Foundation** 文件里，为的是能离屏测
/// （`spike/backup-retention-test.swift`）：命名与解析对不上是典型的**静默失效**
/// ——备份照写，列表却永远是空的，而「空的」看起来和「还没备份过」一模一样。
enum BackupFile {
    static let dirName = "Backups"
    private static let prefix = "library-"
    private static let restoreSuffix = "-before-restore"
    private static let ext = "sqlite"

    static func folder(in workspace: URL) -> URL {
        workspace.appendingPathComponent("UniReader/\(dirName)", isDirectory: true)
    }

    /// `library-20260921-140311.sqlite` / `library-20260921-140311-before-restore.sqlite`
    static func name(at date: Date, restorePoint: Bool = false) -> String {
        "\(prefix)\(stamp.string(from: date))\(restorePoint ? restoreSuffix : "").\(ext)"
    }

    /// 认得出来才算一份备份。**认不出的文件一个都不碰**——用户自己放进去的东西不归我们管。
    static func parse(_ fileName: String) -> (date: Date, isRestorePoint: Bool)? {
        guard fileName.hasPrefix(prefix), fileName.hasSuffix(".\(ext)") else { return nil }
        var body = String(fileName.dropFirst(prefix.count).dropLast(ext.count + 1))
        var restorePoint = false
        if body.hasSuffix(restoreSuffix) {
            body = String(body.dropLast(restoreSuffix.count))
            restorePoint = true
        }
        // 🔴 长度自己卡死：`DateFormatter` 会**吃掉多余的部分**去认一个前缀，`library-.sqlite`
        // 这种空串它也给得出一个日期（实测）。时间戳恰好 15 个字符：`yyyyMMdd-HHmmss`。
        guard body.count == 15, let d = stamp.date(from: body) else { return nil }
        return (d, restorePoint)
    }

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
}

/// 备份的保留策略（方案 `BACKUP-PLAN.md §3.3`）：**纯函数，不碰文件系统**，
/// 离屏可测（`spike/backup-retention-test.swift`）。
///
/// 分级稀释而不是「只留最近 N 份」：连着折腾一下午就会把一周前的状态冲掉，
/// 而「一周前那份」恰恰是发现问题时最想要的。
///
/// ```
/// 最近 5 份   全留
/// 每天 1 份   留最近 7 天（每个自然日保留该日最新的一份）
/// 每周 1 份   留最近 4 周（每个自然周同上）
/// ```
enum BackupRetention {

    struct Policy: Equatable {
        var recent = 5
        var dailyDays = 7
        var weeklyWeeks = 4

        static let standard = Policy()
    }

    /// 下标按输入顺序给回，调用方自己拿去对应文件。
    struct Plan: Equatable {
        var keep: [Int] = []
        var drop: [Int] = []
    }

    /// 算出该留哪些、该删哪些。
    ///
    /// `now` 之后的时间戳（钟被调过、别的机器写进来的）**一律保留**：删掉一份看不懂的备份，
    /// 远比留着它糟糕。
    static func plan(_ dates: [Date], policy: Policy = .standard,
                     now: Date = .now, calendar: Calendar = .current) -> Plan {
        guard !dates.isEmpty else { return Plan() }
        let ordered = dates.indices.sorted { dates[$0] > dates[$1] }   // 新 → 旧
        var keep = Set<Int>()

        // ① 最近 N 份
        for i in ordered.prefix(max(0, policy.recent)) { keep.insert(i) }

        // ② 每天一份（该日最新的那份；`ordered` 是降序，所以每个桶第一次遇到的就是最新的）
        var takenDays = Set<Date>()
        let dayFloor = calendar.startOfDay(for: now).addingTimeInterval(-Double(max(0, policy.dailyDays) - 1) * 86_400)
        for i in ordered {
            let day = calendar.startOfDay(for: dates[i])
            guard day >= dayFloor || dates[i] > now else { continue }
            if takenDays.insert(day).inserted { keep.insert(i) }
        }

        // ③ 每周一份（自然周，跟随用户的日历设置——周一还是周日开头由系统说了算）
        var takenWeeks = Set<Date>()
        let thisWeek = calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? calendar.startOfDay(for: now)
        let weekFloor = calendar.date(byAdding: .weekOfYear, value: -(max(0, policy.weeklyWeeks) - 1),
                                      to: thisWeek) ?? thisWeek
        for i in ordered {
            guard let week = calendar.dateInterval(of: .weekOfYear, for: dates[i])?.start else { continue }
            guard week >= weekFloor || dates[i] > now else { continue }
            if takenWeeks.insert(week).inserted { keep.insert(i) }
        }

        // ④ 未来时间戳照单全收（见方法注释）
        for i in dates.indices where dates[i] > now { keep.insert(i) }

        return Plan(keep: dates.indices.filter { keep.contains($0) },
                    drop: dates.indices.filter { !keep.contains($0) })
    }
}
