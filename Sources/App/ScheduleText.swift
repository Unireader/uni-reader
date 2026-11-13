import Foundation

/// 日程的纯逻辑（`SCHEDULE-PLAN.md`）：日历日字符串、时间、月历格子、说明里的链接、随新对话带给 Agent 的那一行。
/// 纯 Foundation（`spike/schedule-test.swift` 直接编它；MCP 在主线程外也调）。
///
/// 日子一律是**本地日历日**的 `YYYY-MM-DD` 字符串（库里也这样存）：学习计划按「哪一天」排，跟时区无关，
/// 字符串直接比大小就是先后。
enum ScheduleDay {
    /// 公历、本地时区（用户的系统日历可能是农历 / 佛历，日程的日子一律按公历算）。
    static var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = .current
        c.firstWeekday = Calendar.current.firstWeekday
        return c
    }

    static func string(_ date: Date, calendar cal: Calendar = calendar) -> String {
        let c = cal.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    static func today(_ now: Date = Date()) -> String { string(now) }

    /// `YYYY-MM-DD` → 那天 0 点（本地）。格式不对、日期不存在（2 月 30 日）= nil。
    static func date(_ s: String, calendar cal: Calendar = calendar) -> Date? {
        let parts = s.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]) else { return nil }
        guard let date = cal.date(from: DateComponents(year: y, month: m, day: d)) else { return nil }
        // `date(from:)` 会把 2 月 30 日顺延成 3 月 2 日：转回来对不上就是不存在的日子
        return string(date, calendar: cal) == s ? date : nil
    }

    static func isValid(_ s: String) -> Bool { date(s) != nil }

    /// 往后（负数往前）挪几天。
    static func adding(_ days: Int, to s: String) -> String? {
        let cal = calendar
        guard let d = date(s, calendar: cal), let r = cal.date(byAdding: .day, value: days, to: d) else { return nil }
        return string(r, calendar: cal)
    }

    /// 从 `a` 到 `b` 差几天（b 在后为正）。
    static func days(from a: String, to b: String) -> Int? {
        let cal = calendar
        guard let x = date(a, calendar: cal), let y = date(b, calendar: cal) else { return nil }
        return cal.dateComponents([.day], from: x, to: y).day
    }

    /// 星期几：1 = 星期日 … 7 = 星期六（同 `Calendar` 的 weekday）。
    static func weekday(_ s: String) -> Int? {
        let cal = calendar
        return date(s, calendar: cal).map { cal.component(.weekday, from: $0) }
    }

    /// 某天所在的月（`YYYY-MM`）。
    static func month(of s: String) -> String { String(s.prefix(7)) }

    /// 月份往后挪几个月（`YYYY-MM`）。
    static func addingMonths(_ n: Int, to month: String) -> String? {
        let cal = calendar
        guard let first = date(month + "-01", calendar: cal),
              let r = cal.date(byAdding: .month, value: n, to: first) else { return nil }
        return String(string(r, calendar: cal).prefix(7))
    }

    /// 月历要摆的 42 天（6 周 × 7）：从这个月 1 号所在那一周的第一天起。`firstWeekday` 1 = 周日起、2 = 周一起。
    static func monthGrid(_ month: String, firstWeekday: Int) -> [String] {
        var cal = calendar
        cal.firstWeekday = firstWeekday
        guard let first = date(month + "-01", calendar: cal) else { return [] }
        let wd = cal.component(.weekday, from: first)
        let lead = (wd - firstWeekday + 7) % 7
        guard let start = cal.date(byAdding: .day, value: -lead, to: first) else { return [] }
        return (0..<42).compactMap { cal.date(byAdding: .day, value: $0, to: start) }.map { string($0, calendar: cal) }
    }

    /// 某天所在那一周的 7 天（`firstWeekday` 同上）。
    static func week(of s: String, firstWeekday: Int) -> [String] {
        guard let wd = weekday(s) else { return [] }
        let lead = (wd - firstWeekday + 7) % 7
        guard let start = adding(-lead, to: s) else { return [] }
        return (0..<7).compactMap { adding($0, to: start) }
    }
}

enum ScheduleTime {
    /// 当天第几分钟 → `HH:mm`；不定时（< 0）= nil。
    static func string(_ minute: Int) -> String? {
        guard minute >= 0 else { return nil }
        let m = min(minute, 24 * 60 - 1)
        return String(format: "%02d:%02d", m / 60, m % 60)
    }

    /// `HH:mm`（也认 `H:mm`、`HHmm`）→ 当天第几分钟；格式不对 = nil。
    static func minutes(_ s: String) -> Int? {
        let t = s.trimmingCharacters(in: .whitespaces)
        let parts = t.split(separator: ":", omittingEmptySubsequences: false)
        var h: Int?, m: Int?
        if parts.count == 2 {
            h = Int(parts[0]); m = Int(parts[1])
            guard parts[1].count == 2 else { return nil }
        } else if parts.count == 1, t.count == 4, let v = Int(t) {
            h = v / 100; m = v % 100
        }
        guard let h, let m, (0..<24).contains(h), (0..<60).contains(m) else { return nil }
        return h * 60 + m
    }

    /// 时长的文字（「1 小时 30 分钟」这类由界面配；这里只给 Agent / 测试用的英文简写）。
    static func durationText(_ minutes: Int) -> String {
        guard minutes > 0 else { return "" }
        let h = minutes / 60, m = minutes % 60
        if h == 0 { return "\(m) min" }
        return m == 0 ? "\(h) h" : "\(h) h \(m) min"
    }
}

enum ScheduleText {
    /// 一件事的标题最长多少字（再长就该写进说明）。
    static let titleMax = 200
    /// 说明 / 结果最长多少字。
    static let detailMax = 4000

    /// 说明里写的 `[[…]]` 链接（原样，不含方括号；去重、保持先后）。日程页把它们列成按钮，点了打开那本书 / 那一页 / 那篇笔记。
    static func links(in detail: String) -> [String] {
        var out: [String] = []
        var rest = Substring(detail)
        while let open = rest.range(of: "[[") {
            let after = rest[open.upperBound...]
            guard let close = after.range(of: "]]") else { break }
            let inner = after[..<close.lowerBound].trimmingCharacters(in: .whitespaces)
            if !inner.isEmpty, !inner.contains("\n"), !out.contains(inner) { out.append(inner) }
            rest = after[close.upperBound...]
        }
        return out
    }

    /// 说明拿去显示前：每个 `[[…]]` 换成一个看得懂的 Markdown 链接——书页显示成「书名 · 第 N 页」（`pageLabel` 给文字），
    /// 带别名的显示别名，其余显示名字（去掉 `#小节`）；链接地址是 `scheme:` + 原样的 `[[…]]` 里那串（百分号编码），
    /// 点了由页面认（`MarkdownDisplayRenderer.wikiLinkTarget` 解得回来）。代码块、行内代码里的不动。只用于显示，不改库里的原文。
    static func displayMarkdown(_ detail: String, scheme: String, pageLabel: (String, Int) -> String) -> String {
        var out: [String] = []
        var inFence = false
        for line in detail.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("```") || t.hasPrefix("~~~") {
                inFence.toggle()
                out.append(line)
                continue
            }
            if inFence { out.append(line); continue }
            // 行内代码（反引号之间）不动：按反引号切开，只换偶数段
            let parts = line.components(separatedBy: "`")
            out.append(parts.enumerated().map { i, seg in i % 2 == 0 ? linkify(seg, scheme: scheme, pageLabel: pageLabel) : seg }
                .joined(separator: "`"))
        }
        return out.joined(separator: "\n")
    }

    private static func linkify(_ s: String, scheme: String, pageLabel: (String, Int) -> String) -> String {
        guard s.contains("[[") else { return s }
        var out = ""
        var rest = Substring(s)
        while let open = rest.range(of: "[[") {
            let after = rest[open.upperBound...]
            guard let close = after.range(of: "]]") else { break }
            let inner = String(after[..<close.lowerBound])
            out += rest[..<open.lowerBound]
            if inner.trimmingCharacters(in: .whitespaces).isEmpty {
                out += "[[" + inner + "]]"
            } else {
                var allowed = CharacterSet.alphanumerics
                allowed.insert(charactersIn: "-._~")
                let enc = inner.addingPercentEncoding(withAllowedCharacters: allowed) ?? inner
                out += "[" + escapeLabel(linkLabel(inner, pageLabel: pageLabel)) + "](" + scheme + ":" + enc + ")"
            }
            rest = after[close.upperBound...]
        }
        return out + rest
    }

    /// 一个 `[[…]]` 显示成什么：有别名用别名；书页（`#page=N` / `#p=N`）用 `pageLabel`；其余是名字（去掉 `#…`）。
    static func linkLabel(_ inner: String, pageLabel: (String, Int) -> String) -> String {
        let parts = inner.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
        if parts.count == 2 {
            let alias = parts[1].trimmingCharacters(in: .whitespaces)
            if !alias.isEmpty { return alias }
        }
        let head = String(parts[0])
        let name = (head.range(of: "#").map { String(head[..<$0.lowerBound]) } ?? head).trimmingCharacters(in: .whitespaces)
        if let r = head.range(of: "#page=", options: .caseInsensitive) ?? head.range(of: "#p=", options: .caseInsensitive),
           let page = Int(head[r.upperBound...].prefix { $0.isNumber }), page > 0 {
            return pageLabel(name, page)
        }
        return name.isEmpty ? head : name
    }

    private static func escapeLabel(_ s: String) -> String {
        var out = ""
        for c in s {
            if "\\[]*_`<>".contains(c) { out.append("\\") }
            out.append(c)
        }
        return out
    }

    /// 随每段新对话第一句话带上的日程一行（放进隐藏上下文块，和工作区记忆一起）：今天几件、做完几件、过期几件，
    /// 让 Agent 知道有日程、该用哪几个工具。今天没事、也没过期的、也没有计划就不带（返回 nil）。
    static func agentLine(today: String, todayItems: [LibScheduleItem], overdue: Int, plans: Int) -> String? {
        guard !todayItems.isEmpty || overdue > 0 || plans > 0 else { return nil }
        let done = todayItems.filter(\.isDone).count
        var s = Marker.schedule + " (日程) — today is \(today): \(todayItems.count) item(s), \(done) done"
        if overdue > 0 { s += "; \(overdue) overdue (earlier days, not done)" }
        if plans > 0 { s += "; \(plans) plan(s)" }
        s += ". "
        let shown = todayItems.prefix(8).map { m -> String in
            let t = ScheduleTime.string(m.startMin).map { "\($0) " } ?? ""
            return "\(m.isDone ? "[x]" : "[ ]") \(t)\(m.title)"
        }
        if !shown.isEmpty { s += "Today: " + shown.joined(separator: "; ") + ". " }
        s += "Use list_schedule to see it, add_schedule_items to plan, update_schedule_items to reschedule or mark done."
        return s
    }

    enum Marker {
        static let schedule = "Workspace schedule"
    }

    /// 排序：日子 → 不定时的在前、定了时间的按开始时间 → seq → 建的先后（同库里的 `ORDER BY`）。
    static func sorted(_ items: [LibScheduleItem]) -> [LibScheduleItem] {
        items.sorted { a, b in
            if a.day != b.day {
                if a.day.isEmpty != b.day.isEmpty { return !a.day.isEmpty }   // 没排日期的排最后
                return a.day < b.day
            }
            if a.startMin != b.startMin { return a.startMin < b.startMin }
            if a.seq != b.seq { return a.seq < b.seq }
            if a.createdAt != b.createdAt { return a.createdAt < b.createdAt }
            return a.id < b.id
        }
    }
}

/// 打开日程时要去的地方（`DocTabModel.openSchedule`）：哪一天、选中哪一件。都可以空。
struct ScheduleFocus: Equatable {
    var day: String?
    var itemId: String?

    /// 侧栏 / 标签组持久化里日程标签的键。
    static let rowID = "schedule"
}
