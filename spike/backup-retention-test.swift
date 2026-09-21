// 备份的保留策略（`BACKUP-PLAN.md §3.3`）与文件命名（§3.1）回归测试。运行：
//   cp spike/backup-retention-test.swift /tmp/main.swift && \
//     swiftc Sources/App/BackupRetention.swift /tmp/main.swift -o /tmp/br && /tmp/br
// （须命名为 main.swift 编译：swiftc 多文件时顶层代码只允许在 main.swift）

import Foundation

var pass = 0, fail = 0
func check(_ cond: Bool, _ msg: String) {
    if cond { pass += 1; print("  ✅ \(msg)") } else { fail += 1; print("  ❌ \(msg)") }
}
func eq(_ a: Int, _ b: Int, _ msg: String) {
    if a == b { pass += 1; print("  ✅ \(msg)") }
    else { fail += 1; print("  ❌ \(msg)\n      得到: \(a)\n      期望: \(b)") }
}

// 固定日历，免得测试结果跟着跑测试的人所在时区/周首日变。
var cal = Calendar(identifier: .gregorian)
cal.timeZone = TimeZone(identifier: "Asia/Singapore")!
cal.firstWeekday = 2   // 周一

let now = cal.date(from: DateComponents(year: 2026, month: 9, day: 21, hour: 14, minute: 0))!
func ago(hours: Double) -> Date { now.addingTimeInterval(-hours * 3600) }
func ago(days: Double) -> Date { ago(hours: days * 24) }

print("\n— 1) 空输入 —")
let empty = BackupRetention.plan([], now: now, calendar: cal)
check(empty.keep.isEmpty && empty.drop.isEmpty, "没有备份就没有计划")

print("\n— 2) 最近 5 份全留（同一天里密集跑）—")
do {
    // 一天里每小时一份，共 12 份。最近 5 份按「最近」留，剩下 7 份同属一个自然日 →
    // 「每天一份」这条只能再留一份（而且那一份已经在最近 5 份里），所以剩下的全删。
    let dates = (0..<12).map { ago(hours: Double($0)) }
    let p = BackupRetention.plan(dates, now: now, calendar: cal)
    eq(p.keep.count, 5, "同一天 12 份 → 留 5 份")
    check(p.keep == [0, 1, 2, 3, 4], "留下的正是最新的那 5 份")
    eq(p.drop.count, 7, "其余 7 份稀释掉")
}

print("\n— 3) 每天一份 × 7 天 —")
do {
    // 连续 20 天，每天一份（都在当地时间 14:00）。
    // 最近 5 天被「最近 5 份」收走；「每天一份」覆盖 now 往前 7 天（含今天）→ 第 5、6 天再留 2 份；
    // 「每周一份」再补上更早的那几周。
    let dates = (0..<20).map { ago(days: Double($0)) }
    let p = BackupRetention.plan(dates, now: now, calendar: cal)
    check(p.keep.prefix(7) == [0, 1, 2, 3, 4, 5, 6], "最近 7 天一天一份，一份不少")
    check(p.keep.count < 20, "更早的被稀释（留的不是全部）")
    check(p.keep.count >= 8, "更早的几周各留一份（不是只剩 7 份）")
    // 20 天跨 4 个自然周：每周应当恰好留下一份（最新的那份），且总数可控
    check(p.keep.count <= 11, "总份数封顶在十来份，没有失控")
}

print("\n— 4) 每周一份 × 4 周 —")
do {
    // 每 7 天一份，共 10 份 = 横跨 10 周。
    let dates = (0..<10).map { ago(days: Double($0) * 7) }
    let p = BackupRetention.plan(dates, now: now, calendar: cal)
    check(p.keep.contains(0) && p.keep.contains(1) && p.keep.contains(2) && p.keep.contains(3),
          "最近 4 周各留一份")
    check(p.keep.contains(4), "第 5 份还在「最近 5 份」里")
    check(!p.keep.contains(9), "第 10 周那份已超出所有窗口，删掉")
    eq(p.keep.count, 5, "10 份 → 留 5 份")
}

print("\n— 5) 一桶里留最新的那一份 —")
do {
    // 同一天两份（早 8 点 / 晚 20 点），加上足够多的近期备份把「最近 5 份」占满，
    // 这样那一天能不能留、留哪一份，就完全由「每天一份」说了算。
    let filler = (0..<5).map { ago(hours: Double($0)) }              // 0..4：占满「最近 5 份」
    let early = ago(days: 6).addingTimeInterval(-6 * 3600)           // 6 天前早 8 点
    let late = ago(days: 6)                                          // 6 天前 14 点（同一天，更新）
    let p = BackupRetention.plan(filler + [late, early], now: now, calendar: cal)
    check(p.keep.contains(5), "同一天里留下更新的那一份")
    check(!p.keep.contains(6), "同一天里更旧的那份被稀释")
}

print("\n— 6) 未来时间戳照单全收（钟被调过 / 别的机器写进来的）—")
do {
    // 先用 5 份近期备份占满「最近 5 份」，否则总共才两份时两份都在窗口里、什么都不会被删。
    let filler = (0..<5).map { ago(hours: Double($0)) }
    let future = now.addingTimeInterval(86_400 * 3)
    let old = ago(days: 400)
    let p = BackupRetention.plan(filler + [future, old], now: now, calendar: cal)
    check(p.keep.contains(5), "未来那份保留 —— 删掉一份看不懂的备份比留着它糟糕")
    check(p.drop.contains(6), "400 天前那份照常稀释")
}

print("\n— 7) 下标按输入顺序给回（调用方要拿去对文件）—")
do {
    // 故意乱序输入
    let dates = [ago(days: 30), now, ago(days: 1), ago(days: 200)]
    let p = BackupRetention.plan(dates, now: now, calendar: cal)
    check(p.keep.sorted() == p.keep, "keep 是升序下标")
    check(p.drop.sorted() == p.drop, "drop 是升序下标")
    check(Set(p.keep).union(p.drop).count == dates.count, "每一份都有归属，没有漏网的")
    check(Set(p.keep).intersection(p.drop).isEmpty, "没有一份既留又删")
    check(p.keep.contains(1) && p.keep.contains(2), "最近两份在 keep 里，下标对得上乱序输入")
}

print("\n— 8) 策略参数为 0 时不炸 —")
do {
    let dates = (0..<5).map { ago(days: Double($0)) }
    let p = BackupRetention.plan(dates, policy: .init(recent: 0, dailyDays: 0, weeklyWeeks: 0),
                                 now: now, calendar: cal)
    check(Set(p.keep).intersection(p.drop).isEmpty, "全 0 策略不会把同一份同时算进两边")
    eq(p.keep.count + p.drop.count, 5, "全 0 策略下每一份仍有归属")
}

print("\n— 9) 备份文件命名与解析（对不上 = 列表永远是空的，属于静默失效）—")
do {
    let d = cal.date(from: DateComponents(year: 2026, month: 9, day: 21, hour: 14, minute: 3, second: 11))!
    let n = BackupFile.name(at: d)
    check(n.hasPrefix("library-") && n.hasSuffix(".sqlite"), "命名成 \(n)")
    let p = BackupFile.parse(n)
    check(p != nil, "自己的命名自己认得出来")
    check(p.map { abs($0.date.timeIntervalSince(d)) < 1 } == true, "时间戳解析回来一致（秒级）")
    check(p?.isRestorePoint == false, "普通备份不是还原点")

    let r = BackupFile.name(at: d, restorePoint: true)
    check(r != n, "还原点有自己的名字：\(r)")
    check(BackupFile.parse(r)?.isRestorePoint == true, "还原点认得出来")
    check(BackupFile.parse(r).map { abs($0.date.timeIntervalSince(d)) < 1 } == true, "还原点的时间戳也对")

    // 认不出来的一律忽略：那些文件不归我们管，更不许删
    for bad in ["library.sqlite", "library-.sqlite", "library-20260921.sqlite",
                "library-20260921-140311.sqlite.bak", "note.txt", "",
                "library-9999aa-bbbbbb.sqlite", ".DS_Store"] {
        check(BackupFile.parse(bad) == nil, "忽略「\(bad)」")
    }
    check(BackupFile.folder(in: URL(fileURLWithPath: "/tmp/X.unrd")).path == "/tmp/X.unrd/UniReader/Backups",
          "备份目录在工作区包里面")
}

print("\n\(fail == 0 ? "✅ 全部通过" : "❌ 有失败")：\(pass) 通过 / \(fail) 失败\n")
exit(fail == 0 ? 0 : 1)
