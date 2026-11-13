// 日程（`SCHEDULE-PLAN.md`，schema v26）回归测试：日子 / 时间的换算、月历 42 格、说明里的链接、随新对话带的那一行、
// 库的读写与排序、过期 / 没排日期 / 计划进度、id 前缀、离线镜像指纹与表结构一致、回收站「归档 → 删 → 放回」、
// manifest、老库升级补表。运行：
//   O=/tmp/schedule-test; mkdir -p $O && cp spike/schedule-test.swift $O/main.swift && \
//     swiftc Sources/Store/*.swift Sources/App/TrashModel.swift Sources/App/ScheduleText.swift $O/main.swift -o $O/t && $O/t
// （须命名为 main.swift 编译：swiftc 多文件时顶层代码只允许在 main.swift）
import Foundation

setvbuf(stdout, nil, _IONBF, 0)

var pass = 0, fail = 0
func check(_ cond: Bool, _ msg: String) {
    if cond { pass += 1; print("  ✅ \(msg)") } else { fail += 1; print("  ❌ \(msg)") }
}
func eq<T: Equatable>(_ a: T, _ b: T, _ msg: String) {
    if a == b { pass += 1; print("  ✅ \(msg)") }
    else { fail += 1; print("  ❌ \(msg)\n      得到: \(a)\n      期望: \(b)") }
}

// MARK: - 日子与时间

print("— 日子")
check(ScheduleDay.isValid("2026-11-14"), "合法日子")
check(!ScheduleDay.isValid("2026-02-30"), "2 月 30 日不存在")
check(!ScheduleDay.isValid("2026-11-4") && !ScheduleDay.isValid("2026/11/14") && !ScheduleDay.isValid(""), "格式不对")
check(ScheduleDay.isValid("2028-02-29") && !ScheduleDay.isValid("2027-02-29"), "闰年")
eq(ScheduleDay.adding(1, to: "2026-12-31"), "2027-01-01", "跨年加一天")
eq(ScheduleDay.adding(-1, to: "2026-03-01"), "2026-02-28", "往前一天到 2 月底")
eq(ScheduleDay.days(from: "2026-11-13", to: "2026-11-20"), 7, "差 7 天")
eq(ScheduleDay.days(from: "2026-11-20", to: "2026-11-13"), -7, "反过来 -7")
eq(ScheduleDay.weekday("2026-11-13"), 6, "2026-11-13 是星期五（weekday 6）")
eq(ScheduleDay.addingMonths(1, to: "2026-12"), "2027-01", "下个月跨年")
eq(ScheduleDay.addingMonths(-1, to: "2026-01"), "2025-12", "上个月跨年")
eq(ScheduleDay.string(ScheduleDay.date("2026-11-14")!), "2026-11-14", "字符串 ↔ 日期回环")

print("— 月历 42 格")
do {
    let mon = ScheduleDay.monthGrid("2026-11", firstWeekday: 2)
    eq(mon.count, 42, "42 天")
    eq(mon.first, "2026-10-26", "周一起：11 月 1 日是周日，第一格是 10-26（周一）")
    check(mon.contains("2026-11-30"), "整个月都在里面")
    let sun = ScheduleDay.monthGrid("2026-11", firstWeekday: 1)
    eq(sun.first, "2026-11-01", "周日起：第一格就是 11-01")
    eq(sun.last, "2026-12-12", "最后一格")
    eq(Set(mon).count, 42, "没有重复的日子")
    let feb = ScheduleDay.monthGrid("2027-02", firstWeekday: 2)
    eq(feb.first, "2027-02-01", "2027-02-01 是周一：从它起")
    eq(ScheduleDay.week(of: "2026-11-13", firstWeekday: 2), ["2026-11-09", "2026-11-10", "2026-11-11", "2026-11-12",
                                                           "2026-11-13", "2026-11-14", "2026-11-15"], "所在那一周")
}

print("— 时间")
eq(ScheduleTime.string(570), "09:30", "570 分钟 = 09:30")
eq(ScheduleTime.string(-1), nil, "不定时")
eq(ScheduleTime.minutes("09:30"), 570, "09:30")
eq(ScheduleTime.minutes("9:05"), 545, "9:05")
eq(ScheduleTime.minutes("2359"), 1439, "2359")
eq(ScheduleTime.minutes("24:00"), nil, "24:00 不算")
eq(ScheduleTime.minutes("9:5"), nil, "分钟要两位")
eq(ScheduleTime.minutes("abc"), nil, "乱写")
eq(ScheduleTime.durationText(90), "1 h 30 min", "90 分钟")

print("— 说明里的链接")
eq(ScheduleText.links(in: "读 [[王道计算机网络#page=88]] 到 96 页，再看 [[滑动窗口笔记]]、[[王道计算机网络#page=88]]"),
   ["王道计算机网络#page=88", "滑动窗口笔记"], "去重、保持先后")
eq(ScheduleText.links(in: "没有链接 [[ ]] [[断开\n的]]"), [], "空的、跨行的不算")
eq(ScheduleText.links(in: "[[只开不关"), [], "没关上的不算")

print("— 说明拿去显示：[[…]] 换成看得懂的链接")
do {
    let page: (String, Int) -> String = { "\($0) · 第 \($1) 页" }
    eq(ScheduleText.linkLabel("2027计算机网络_高清带书签版#p=71", pageLabel: page), "2027计算机网络_高清带书签版 · 第 71 页", "#p= 简写也认页码")
    eq(ScheduleText.linkLabel("王道#page=88", pageLabel: page), "王道 · 第 88 页", "#page=")
    eq(ScheduleText.linkLabel("王道#page=88|滑动窗口", pageLabel: page), "滑动窗口", "有别名用别名")
    eq(ScheduleText.linkLabel("笔记名#小节", pageLabel: page), "笔记名", "笔记去掉 #小节")
    let md = ScheduleText.displayMarkdown("做 [[书_A#p=71]] 和 [[笔记]]\n`[[代码里]]`\n```\n[[块里]]\n```", scheme: "x-markdown-wiki",
                                          pageLabel: page)
    let lines = md.components(separatedBy: "\n")
    check(lines[0].hasPrefix("做 [书\\_A · 第 71 页](x-markdown-wiki:%E4%B9%A6_A%23p%3D71)"), "换成 Markdown 链接，标签里的 _ 转义、地址百分号编码：\(lines[0])")
    check(lines[0].hasSuffix("和 [笔记](x-markdown-wiki:%E7%AC%94%E8%AE%B0)"), "笔记链接")
    eq(lines[1], "`[[代码里]]`", "行内代码里的不动")
    eq(lines[3], "[[块里]]", "代码块里的不动")
    let enc = String(lines[0].split(separator: ":", maxSplits: 1)[1].prefix { $0 != ")" })
    eq(enc.removingPercentEncoding, "书_A#p=71", "地址解得回原样的那串")
    eq(ScheduleText.displayMarkdown("没有链接", scheme: "x", pageLabel: page), "没有链接", "没有链接原样")
}

// MARK: - 库

let iso = ISO8601DateFormatter()
let t0 = iso.date(from: "2026-11-13T02:00:00Z")!
let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("schedule_test_\(UInt64.random(in: 0..<1_000_000))")
try? FileManager.default.removeItem(at: tmp)
try! FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: tmp) }

func item(_ id: String, _ title: String, day: String, start: Int = -1, seq: Int = 1, plan: String = "",
          done: Date? = nil, at: Date = t0) -> LibScheduleItem {
    LibScheduleItem(id: id, planId: plan, title: title, detail: "", day: day, startMin: start, durationMin: 0, doneAt: done,
                    result: "", seq: seq, agent: "", createdAt: at, updatedAt: at)
}

print("— 计划与事项的读写")
var store: LibraryStore! = try LibraryStore(workspaceFolder: tmp)
eq(LibraryStore.schemaVersion, 26, "schema 版本 26")
eq(store.meta("schema_version"), "26", "新库记下 26")
eq(try store.schedulePlans().count, 0, "新库没有计划")
let plan = LibSchedulePlan(id: "PPPPPPPP-0000-4000-8000-000000000001", title: "第三章复习", goal: "两周过完", agent: "Kimi",
                           createdAt: t0, updatedAt: t0)
try store.upsertSchedulePlan(plan)
eq(try store.schedulePlan(id: plan.id), plan, "计划读回来逐字段相同")
var plan2 = plan
plan2.title = "第三章复习（改）"
plan2.createdAt = t0.addingTimeInterval(999)
plan2.updatedAt = t0.addingTimeInterval(60)
try store.upsertSchedulePlan(plan2)
eq(try store.schedulePlan(id: plan.id)?.title, "第三章复习（改）", "覆盖写改名字")
eq(try store.schedulePlan(id: plan.id)?.createdAt, t0, "覆盖写不动 created_at")

let a = item("AAAAAAAA-0000-4000-8000-000000000001", "不定时的一件", day: "2026-11-14", seq: 2, plan: plan.id)
let b = item("BBBBBBBB-0000-4000-8000-000000000002", "九点半", day: "2026-11-14", start: 570, plan: plan.id)
let c = item("CCCCCCCC-0000-4000-8000-000000000003", "八点", day: "2026-11-14", start: 480)
let d = item("DDDDDDDD-0000-4000-8000-000000000004", "更早不定时", day: "2026-11-14", seq: 1, plan: plan.id)
let e = item("EEEEEEEE-0000-4000-8000-000000000005", "过期没做", day: "2026-11-10", plan: plan.id)
let f = item("FFFFFFFF-0000-4000-8000-000000000006", "过期但做完了", day: "2026-11-11", done: t0)
let g = item("99999999-0000-4000-8000-000000000007", "没排日期", day: "")
try store.upsertScheduleItems([a, b, c, d, e, f, g])
eq(try store.scheduleItem(id: b.id), b, "事项读回来逐字段相同")
eq(try store.scheduleItem(id: f.id)?.doneAt, t0, "做完的时间读回来")
eq(try store.scheduleItems(from: "2026-11-14", to: "2026-11-14").map(\.title), ["更早不定时", "不定时的一件", "八点", "九点半"],
   "同一天：不定时的在前（按 seq），再按开始时间")
eq(ScheduleText.sorted([b, a, c, d]).map(\.title), ["更早不定时", "不定时的一件", "八点", "九点半"], "内存里排序同库里")
eq(try store.scheduleItems(from: "2026-11-01", to: "2026-11-30").count, 6, "范围内 6 件（没排日期的不算）")
eq(try store.scheduleItems(from: "2026-11-01", to: "2026-11-30", planId: plan.id).count, 4, "只要这份计划的")
eq(try store.overdueScheduleItems(before: "2026-11-13").map(\.title), ["过期没做"], "过期没做完：做完的不算")
eq(try store.undatedScheduleItems().map(\.title), ["没排日期"], "没排日期的")
eq(try store.scheduleItems(planId: plan.id).map(\.title), ["过期没做", "更早不定时", "不定时的一件", "九点半"], "一份计划的全部")
eq(try store.nextScheduleSeq(day: "2026-11-14"), 3, "这天下一个 seq")
eq(try store.nextScheduleSeq(day: "2030-01-01"), 1, "空的一天从 1 起")
let counts = try store.schedulePlanCounts()
check(counts[plan.id]?.total == 4 && counts[plan.id]?.done == 0, "计划进度 0/4")
check(counts[""]?.total == 3 && counts[""]?.done == 1, "不属于计划的 1/3")
eq(try store.scheduleItems(idPrefix: "cccccccc").map(\.id), [c.id], "id 前缀不分大小写")
eq(try store.scheduleItems(idPrefix: "C_C").count, 0, "前缀里的 _ 按原字符认，不当通配")

print("— 改：打勾、挪日子")
var b2 = b
b2.doneAt = t0.addingTimeInterval(3600)
b2.result = "滑动窗口还要再看"
b2.day = "2026-11-15"
b2.updatedAt = t0.addingTimeInterval(3600)
try store.upsertScheduleItems([b2])
let gotB = try store.scheduleItem(id: b.id)!
check(gotB.isDone && gotB.result == "滑动窗口还要再看" && gotB.day == "2026-11-15", "打勾 + 写结果 + 挪日子都写进去")
eq(gotB.createdAt, t0, "覆盖写不动 created_at")
eq(try store.schedulePlanCounts()[plan.id]?.done, 1, "计划进度 1/4")
var b3 = gotB
b3.doneAt = nil
try store.upsertScheduleItems([b3])
check(try store.scheduleItem(id: b.id)?.isDone == false, "取消打勾")

print("— 随新对话带的那一行")
do {
    let todayItems = [c, ScheduleText.sorted([a]).first!]
    let line = ScheduleText.agentLine(today: "2026-11-14", todayItems: todayItems, overdue: 1, plans: 1)!
    check(line.hasPrefix(ScheduleText.Marker.schedule), "以 Marker 开头")
    check(line.contains("2 item(s), 0 done") && line.contains("1 overdue") && line.contains("1 plan(s)"), "今天几件、过期几件、几份计划")
    check(line.contains("[ ] 08:00 八点") && line.contains("[ ] 不定时的一件"), "列出今天的事（带时间）")
    check(line.contains("list_schedule") && line.contains("add_schedule_items"), "说该用哪几个工具")
    eq(ScheduleText.agentLine(today: "2026-11-14", todayItems: [], overdue: 0, plans: 0), nil, "什么都没有就不带")
}

print("— 离线镜像指纹与表结构一致")
do {
    for t in ["schedule_plan", "schedule_item"] {
        let cols = try store.withMirrorDB { db in try db.query("PRAGMA table_info(\(t))").map { $0["name"] as? String ?? "" } }
        eq(MirrorFp.spec(t)?.columns.map(\.name) ?? [], cols, "\(t) 指纹列序 = 表的列序")
        eq(MirrorFp.spec(t)?.lww, "updated_at", "\(t) 按 updated_at 取新")
    }
    let order = MirrorFp.specs.map(\.table)
    check(order.firstIndex(of: "agent_turn")! < order.firstIndex(of: "schedule_plan")!
          && order.firstIndex(of: "schedule_plan")! < order.firstIndex(of: "schedule_item")!
          && order.firstIndex(of: "schedule_item")! < order.firstIndex(of: "meta")!,
          "排在 agent_turn 之后、meta 之前（与安卓 MirrorFp.kt 一致）")
    let snap = try store.mirrorSnapshot()
    eq(snap["schedule_plan"]?.count, 1, "镜像快照带上计划")
    eq(snap["schedule_item"]?.count, 7, "镜像快照带上 7 件事")
}

print("— 回收站：归档 → 删 → 放回")
do {
    // 整份计划（连同名下 4 件）+ 单独一件
    let path = tmp.appendingPathComponent("snap.sqlite").path
    let archived = try store.archiveSchedule(planIds: [plan.id], itemIds: [g.id], to: path)
    eq(archived.counts.schedulePlan, 1, "归档 1 份计划")
    eq(archived.counts.scheduleItem, 5, "归档 5 件（计划名下 4 件 + 单独 1 件）")
    eq(archived.counts.total, 6, "total 算上计划和事项")
    let before = try store.scheduleItems(planId: plan.id)
    try store.deleteSchedule(planIds: [plan.id], itemIds: [g.id])
    eq(try store.schedulePlans().count, 0, "计划删掉了")
    eq(try store.scheduleItems(planId: plan.id).count, 0, "名下的事项跟着删了")
    eq(try store.undatedScheduleItems().count, 0, "单独那件也删了")
    eq(try store.scheduleItems(from: "2026-11-01", to: "2026-11-30").map(\.title).sorted(), ["八点", "过期但做完了"].sorted(),
       "别的事项还在")
    eq(try store.restoreTrash(snapshot: path, remapDocumentId: nil), 6, "放回 6 行")
    eq(try store.scheduleItems(planId: plan.id), before, "放回来逐字段相同")
    eq(try store.schedulePlan(id: plan.id)?.title, "第三章复习（改）", "计划也放回来了")
    _ = try store.restoreTrash(snapshot: path, remapDocumentId: nil)
    eq(try store.scheduleItems(from: "2026-11-01", to: "2026-11-30").count, 6, "重复放回不多出行")
    eq(try store.trashSummary(snapshot: path).counts.scheduleItem, 5, "从快照重建摘要也数得到")

    // 只删几件（不带计划）
    let path2 = tmp.appendingPathComponent("snap2.sqlite").path
    let only = try store.archiveSchedule(planIds: [], itemIds: [a.id, c.id], to: path2)
    check(only.counts.schedulePlan == 0 && only.counts.scheduleItem == 2, "只归档两件，不带计划")
    try store.deleteSchedule(planIds: [], itemIds: [a.id, c.id])
    check(try store.scheduleItem(id: a.id) == nil && store.schedulePlan(id: plan.id) != nil, "删了两件，计划还在")
    _ = try store.restoreTrash(snapshot: path2, remapDocumentId: nil)
    check(try store.scheduleItem(id: a.id) != nil, "放回来")
}

print("— manifest：新种类与老条目")
do {
    var m = Trash.Manifest()
    m.kind = .schedule
    m.counts.schedulePlan = 1
    m.counts.scheduleItem = 4
    let back = try Trash.decode(Trash.encode(m))
    eq(back.kind, .schedule, "种类 schedule 编解码回环")
    check(back.counts.schedulePlan == 1 && back.counts.scheduleItem == 4, "计数编解码回环")
    let json = String(data: try Trash.encode(m), encoding: .utf8) ?? ""
    check(json.contains("\"schedule\"") && json.contains("\"schedulePlan\" : 1") && json.contains("\"scheduleItem\" : 4"),
          "键名 = schedule / schedulePlan / scheduleItem（与安卓一致）")
    let old = #"{"v":1,"kind":"agentMemories","deletedAt":"2026-11-02T00:00:00Z","title":"x","documentId":"","documentTitle":"","pageCount":0,"counts":{"agentMemory":1},"images":[],"contentHashes":[]}"#
    eq(try Trash.decode(Data(old.utf8)).counts.scheduleItem, 0, "老 manifest 没这个键 → 0")
}

print("— 老库升级补表")
do {
    let dir2 = tmp.appendingPathComponent("old", isDirectory: true)
    try FileManager.default.createDirectory(at: dir2, withIntermediateDirectories: true)
    var s2: LibraryStore! = try LibraryStore(workspaceFolder: dir2)
    try s2.withMirrorDB { db in
        try db.exec("DROP TABLE schedule_item")
        try db.exec("DROP TABLE schedule_plan")
        try db.run("UPDATE meta SET value='25' WHERE key='schema_version'")
    }
    s2.close()
    s2 = nil
    let s3 = try LibraryStore(workspaceFolder: dir2)
    eq(s3.meta("schema_version"), "26", "v25 库打开后升到 26")
    eq(try s3.schedulePlans().count, 0, "补建了 schedule_plan 表")
    eq(try s3.undatedScheduleItems().count, 0, "补建了 schedule_item 表")
    s3.close()
}

store.close()
store = nil

print(fail == 0 ? "\n✅ 全部通过：\(pass) 通过 / 0 失败" : "\n❌ \(fail) 失败 / \(pass) 通过")
exit(fail == 0 ? 0 : 1)
