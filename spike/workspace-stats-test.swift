// 工作区统计（MCP `workspace_stats`，`MCP-PLAN.md §38`）回归测试：`StatsStore` 各块的数（空库 / 各表都有行 /
// 只数一篇文档 / 按本地日分天的边界、夏令时那天、不同写法的时间戳 / 同一刻两次作答不重复计），`MCPStats` 的入参校验，
// 以及结构化结果**逐键对着 outputSchema 校验**（Kimi 严格校验，多一个没声明的键整次调用作废）。运行：
//   mkdir -p /tmp/wst && cp spike/workspace-stats-test.swift /tmp/wst/main.swift && \
//     swiftc Sources/Store/*.swift Sources/MCP/MCPModels.swift Sources/MCP/MCPStats.swift /tmp/wst/main.swift \
//       -o /tmp/wst/wst && /tmp/wst/wst
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
func throwsInvalid(_ msg: String, _ body: () throws -> Void) {
    do { try body(); fail += 1; print("  ❌ \(msg)（没报错）") }
    catch is MCPInvalidParams { pass += 1; print("  ✅ \(msg)") }
    catch { fail += 1; print("  ❌ \(msg)（报的不是 MCPInvalidParams：\(error)）") }
}

// MARK: - schema 校验（JSON Schema 子集：object / array / string / integer / boolean / anyOf / enum）

func validate(_ v: Any, _ s: MCPObject, _ path: String) -> [String] {
    if let any = s["anyOf"] as? [MCPObject] {
        return any.contains { validate(v, $0, path).isEmpty } ? [] : ["\(path): 不符合 anyOf"]
    }
    switch s["type"] as? String {
    case "object":
        guard let o = v as? MCPObject else { return ["\(path): 应是 object，得到 \(type(of: v))"] }
        let props = s["properties"] as? [String: MCPObject] ?? [:]
        var errs: [String] = []
        for (k, x) in o {
            guard let ps = props[k] else { errs.append("\(path).\(k): schema 没声明"); continue }
            errs += validate(x, ps, "\(path).\(k)")
        }
        for r in s["required"] as? [String] ?? [] where o[r] == nil { errs.append("\(path).\(r): 缺 required") }
        return errs
    case "array":
        guard let a = v as? [Any] else { return ["\(path): 应是 array，得到 \(type(of: v))"] }
        let item = s["items"] as? MCPObject ?? [:]
        return a.enumerated().flatMap { validate($1, item, "\(path)[\($0)]") }
    case "string":
        guard let str = v as? String else { return ["\(path): 应是 string，得到 \(type(of: v))"] }
        if let e = s["enum"] as? [String], !e.contains(str) { return ["\(path): \(str) 不在 enum 里"] }
        return []
    case "integer":
        return (v is Int && !(v is Bool)) ? [] : ["\(path): 应是 integer，得到 \(type(of: v))"]
    case "boolean":
        return v is Bool ? [] : ["\(path): 应是 boolean，得到 \(type(of: v))"]
    default:
        return ["\(path): schema 缺 type"]
    }
}

func schemaOK(_ o: MCPObject, _ msg: String) {
    let errs = validate(o, MCPStats.outputSchema, "$")
    check(errs.isEmpty && JSONSerialization.isValidJSONObject(o), msg + (errs.isEmpty ? "" : "：\n      " + errs.joined(separator: "\n      ")))
}

/// schema 里每个对象都是 additionalProperties:false、每个属性都带 type/anyOf（写漏了 Kimi 也会拒）。
func schemaWellFormed(_ s: MCPObject, _ path: String) -> [String] {
    var errs: [String] = []
    if s["type"] == nil && s["anyOf"] == nil { errs.append("\(path): 缺 type") }
    if s["type"] as? String == "object" {
        if s["additionalProperties"] as? Bool != false { errs.append("\(path): 没写 additionalProperties:false") }
        for (k, p) in s["properties"] as? [String: MCPObject] ?? [:] { errs += schemaWellFormed(p, "\(path).\(k)") }
    }
    if let item = s["items"] as? MCPObject { errs += schemaWellFormed(item, "\(path)[]") }
    return errs
}

// MARK: - 本地日

let sh = TimeZone(identifier: "Asia/Shanghai")!
let ny = TimeZone(identifier: "America/New_York")!
let isoF = ISO8601DateFormatter()
func epoch(_ s: String) -> Int64 { Int64(isoF.date(from: s)!.timeIntervalSince1970) }

print("— 本地日")
do {
    let d = StatsStore.days(from: "2026-11-13", to: "2026-11-13", in: sh)
    eq(d?.count, 1, "一天")
    eq(d?.first?.lo, epoch("2026-11-12T16:00:00Z"), "上海 11-13 从 UTC 11-12 16:00 起")
    eq(d?.first?.hi, epoch("2026-11-13T16:00:00Z"), "到 UTC 11-13 16:00 止（不含）")
    let fall = StatsStore.days(from: "2026-11-01", to: "2026-11-01", in: ny)?.first
    eq(fall.map { $0.hi - $0.lo }, 25 * 3600, "纽约 2026-11-01 夏令时结束：那天 25 小时")
    eq(fall?.lo, epoch("2026-11-01T04:00:00Z"), "纽约 11-01 起于 UTC 04:00")
    let spring = StatsStore.days(from: "2026-03-08", to: "2026-03-08", in: ny)?.first
    eq(spring.map { $0.hi - $0.lo }, 23 * 3600, "纽约 2026-03-08 夏令时开始：那天 23 小时")
    let span = StatsStore.days(from: "2026-10-31", to: "2026-11-02", in: ny) ?? []
    eq(span.map(\.day), ["2026-10-31", "2026-11-01", "2026-11-02"], "跨夏令时的范围逐日连续")
    check(zip(span, span.dropFirst()).allSatisfy { $0.hi == $1.lo }, "相邻两天首尾相接（不重不漏）")
    eq(StatsStore.days(from: "2026-02-28", to: "2026-03-01", in: sh)?.map(\.day), ["2026-02-28", "2026-03-01"], "跨月")
    check(StatsStore.days(from: "2026-02-30", to: "2026-03-01", in: sh) == nil, "2 月 30 日不存在 → nil")
    check(StatsStore.days(from: "2026-13-01", to: "2026-13-01", in: sh) == nil, "13 月 → nil")
    check(StatsStore.days(from: "20261113", to: "20261113", in: sh) == nil, "写法不对 → nil")
    check(StatsStore.days(from: "2026-11-14", to: "2026-11-13", in: sh) == nil, "from 晚于 to → nil")
    eq(StatsStore.days(from: "2025-11-13", to: "2026-11-14", in: sh)?.count, nil, "367 天 → nil")
    eq(StatsStore.days(from: "2025-11-14", to: "2026-11-14", in: sh)?.count, 366, "366 天可以")
    eq(StatsStore.days(from: "2025-11-15", to: "2026-11-14", in: sh)?.count, 365, "365 天可以")
    eq(StatsStore.days(from: "2024-01-01", to: "2024-12-31", in: sh)?.count, 366, "闰年整年 366 天可以")
    eq(StatsStore.shift("2026-03-01", by: -1, in: sh), "2026-02-28", "往前挪一天跨月")
    eq(StatsStore.dayString(isoF.date(from: "2026-11-12T16:00:00Z")!, in: sh), "2026-11-13", "UTC 16:00 在上海已是第二天")
    eq(StatsStore.dayString(isoF.date(from: "2026-11-12T16:00:00Z")!, in: ny), "2026-11-12", "在纽约还是当天")
}

print("— 入参")
do {
    let r0 = try! MCPStats.range(from: nil, to: nil, today: "2026-11-13", in: sh)
    eq([r0.from, r0.to], ["2026-11-07", "2026-11-13"], "默认：含今天的最近 7 天")
    let r1 = try! MCPStats.range(from: "2026-11-01", to: nil, today: "2026-11-13", in: sh)
    eq([r1.from, r1.to], ["2026-11-01", "2026-11-13"], "只给 from：到今天")
    let r2 = try! MCPStats.range(from: nil, to: "2026-11-05", today: "2026-11-13", in: sh)
    eq([r2.from, r2.to], ["2026-10-30", "2026-11-05"], "只给 to：往前 7 天")
    let r3 = try! MCPStats.range(from: "2026-11-20", to: nil, today: "2026-11-13", in: sh)
    eq([r3.from, r3.to], ["2026-11-20", "2026-11-20"], "只给将来的 from：就那一天")
    let r4 = try! MCPStats.range(from: "", to: "", today: "2026-11-13", in: sh)
    eq([r4.from, r4.to], ["2026-11-07", "2026-11-13"], "空串当没给")
    throwsInvalid("from 写法不对报错") { _ = try MCPStats.range(from: "11/13", to: nil, today: "2026-11-13", in: sh) }
    throwsInvalid("from 晚于 to 报错") { _ = try MCPStats.range(from: "2026-11-14", to: "2026-11-13", today: "2026-11-13", in: sh) }
    throwsInvalid("超过 366 天报错") { _ = try MCPStats.range(from: "2020-01-01", to: "2026-11-13", today: "2026-11-13", in: sh) }
    eq(try! MCPStats.sections(nil).count, StatsStore.Section.allCases.count, "sections 不给 = 全部")
    eq(try! MCPStats.sections([] as [Any]).count, StatsStore.Section.allCases.count, "sections 空数组 = 全部")
    eq(try! MCPStats.sections(["exercises", " Practice "]), [.exercises, .practice], "sections 不分大小写、去空白")
    throwsInvalid("不认识的 section 报错") { _ = try MCPStats.sections(["bogus"]) }
    throwsInvalid("sections 不是数组报错") { _ = try MCPStats.sections("library") }
    check(!validate(["workspace": "x", "bogus": 1] as MCPObject, MCPStats.outputSchema, "$").isEmpty
          && !validate(["library": ["documents": 1, "extra": 2]] as MCPObject, MCPStats.outputSchema, "$").isEmpty,
          "校验器本身：顶层 / 嵌套多一个没声明的键都抓得出来")
    let errs = schemaWellFormed(MCPStats.outputSchema, "$")
    check(errs.isEmpty, "outputSchema 每层都 additionalProperties:false、都有 type" + (errs.isEmpty ? "" : "：\(errs)"))
}

// MARK: - 库

let base = ProcessInfo.processInfo.environment["STATS_TMP"] ?? NSTemporaryDirectory()
let tmp = URL(fileURLWithPath: base).appendingPathComponent("workspace_stats_test_\(UInt64.random(in: 0..<1_000_000))")
try? FileManager.default.removeItem(at: tmp)
try! FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: tmp) }

let store = try! LibraryStore(workspaceFolder: tmp)
let raw = try! SQLiteDB(path: store.fileURL.path)    // 测试直接写行（时间戳要精确控制写法）
func run(_ sql: String, _ args: [SQLiteDB.Value] = []) { try! raw.run(sql, args) }
let T = "2026-11-01T00:00:00.000Z"

func query(_ sections: Set<StatsStore.Section> = Set(StatsStore.Section.allCases), doc: String? = nil,
           from: String = "2026-11-11", to: String = "2026-11-13", limit: Int = 20) -> StatsStore.Report {
    try! store.stats(StatsStore.Query(sections: sections, documentId: doc, from: from, to: to, today: "2026-11-13",
                                      timeZone: sh, limit: limit))
}
func dto(_ r: StatsStore.Report, document: (id: String, title: String)? = nil,
         markdown: [MCPStats.MarkdownSource]? = nil) -> MCPObject {
    MCPStats.object(workspace: "测试", today: "2026-11-13", from: "2026-11-11", to: "2026-11-13",
                    document: document, report: r, markdown: markdown)
}

print("— 空工作区")
do {
    let r = query()
    eq(r.library, StatsStore.Library(), "书库全 0")
    eq(r.annotations, StatsStore.Annotations(), "批注全 0")
    eq(r.boards, StatsStore.Boards(), "画板全 0")
    eq(r.exercises, StatsStore.Exercises(), "习题全 0")
    eq(r.practice, StatsStore.Practice(), "练习全 0")
    eq(r.agent, StatsStore.Agent(), "Agent 全 0")
    eq(r.schedule, StatsStore.Schedule(), "日程全 0")
    schemaOK(dto(r, markdown: [MCPStats.MarkdownSource(name: "Notes", kind: "workspace", notes: 0)]), "空库的结构化结果符合 schema")
    let text = MCPStats.text(workspace: "测试", today: "2026-11-13", from: "2026-11-11", to: "2026-11-13",
                             document: nil, report: r, markdown: [])
    check(text.contains("Library: 0 document(s)") && text.contains("Schedule: 0 plan(s)"), "空库的摘要")
}

// MARK: 填数据

// 书库：D1 读到一半、D2 读完、D3 没读、D4 只有一页且往下滚了一点（读过 + 读完）
for (id, title, pages, rp, rf, opened) in [
    ("D1", "高等数学", 100, 49, 0.3, "2026-11-13T01:00:00.000Z"),
    ("D2", "线性代数", 50, 49, 0.0, "2026-11-12T01:00:00.000Z"),
    ("D3", "概率论", 30, 0, 0.0, "2026-11-01T01:00:00.000Z"),
    ("D4", "单页", 1, 0, 0.5, "2026-11-11T01:00:00.000Z"),
] as [(String, String, Int, Int, Double, String)] {
    run("INSERT INTO document(id,title,page_count,added_at,last_opened_at,read_page,read_frac) VALUES(?,?,?,?,?,?,?)",
        [.text(id), .text(title), .int(Int64(pages)), .text(T), .text(opened), .int(Int64(rp)), .double(rf)])
}
var noteSeq = 0
func note(_ doc: String, _ kind: Int, page: Int = 0) {
    noteSeq += 1
    run("""
    INSERT INTO note(id,document_id,kind,page,anchor_x,anchor_y,anchor_w,anchor_h,payload,created_at,updated_at)
    VALUES(?,?,?,?,0,0,0,0,?,?,?)
    """, [.text("N\(noteSeq)"), .text(doc), .int(Int64(kind)), .int(Int64(page)), .blob(Data("{}".utf8)), .text(T), .text(T)])
}
for _ in 0..<3 { note("D1", 0) }
for _ in 0..<2 { note("D1", 3) }
note("D1", 5); note("D1", 6); note("D1", 1)
for p in [1, 1, 2, 3, 3] { note("D1", 2, page: p) }
for _ in 0..<4 { note("D1", 4) }
note("D2", 0)
note("D2", 2, page: 7); note("D2", 2, page: 7)
run("INSERT INTO scratch_pad(id,document_id,created_at,updated_at) VALUES('S1','D1',?,?)", [.text(T), .text(T)])

// 画板：B1 无限画布（3 笔 + 1 图），B2 分页（2 页、2 笔）
run("INSERT INTO board_note(id,title,created_at,updated_at) VALUES('B1','a',?,?),('B2','b',?,?)",
    [.text(T), .text(T), .text(T), .text(T)])
run("INSERT INTO board_page(id,board_id,sort_key,width,height,created_at,updated_at) VALUES('BP1','B2',1,1,1,?,?),('BP2','B2',2,1,1,?,?)",
    [.text(T), .text(T), .text(T), .text(T)])
var itemSeq = 0
func boardItem(_ board: String, _ kind: Int) {
    itemSeq += 1
    run("INSERT INTO board_item(id,board_id,kind,x,y,w,h,payload,created_at,updated_at) VALUES(?,?,?,0,0,1,1,?,?,?)",
        [.text("BI\(itemSeq)"), .text(board), .int(Int64(kind)), .blob(Data("{}".utf8)), .text(T), .text(T)])
}
for _ in 0..<3 { boardItem("B1", 1) }
boardItem("B1", 2)
for _ in 0..<2 { boardItem("B2", 1) }
// 题目草稿纸（`EXERCISE-PLAN.md §29`）：存成画板但不算画板，上面的笔迹也不算
run("INSERT INTO board_note(id,title,group_name,created_at,updated_at) VALUES('BX','', 'exercise',?,?)", [.text(T), .text(T)])
for _ in 0..<4 { boardItem("BX", 1) }

// 习题：E6 是不认识的题型 2；E7 的标签不是合法 JSON（当没标签）；E5 / E6 的标签只差大小写（算一个）
func exercise(_ id: String, _ doc: String?, page: Int?, kind: Int, chapter: String = "", tags: String = "",
              starred: Bool = false, wrong: Bool = false, note: String = "") {
    run("""
    INSERT INTO exercise(id,document_id,page,seq,kind,payload,starred,wrong,created_at,updated_at,chapter,note,tags)
    VALUES(?,?,?,0,?,?,?,?,?,?,?,?,?)
    """, [.text(id), doc.map { .text($0) } ?? .null, page.map { .int(Int64($0)) } ?? .null, .int(Int64(kind)),
          .blob(Data("{}".utf8)), .int(starred ? 1 : 0), .int(wrong ? 1 : 0), .text(T), .text(T),
          .text(chapter), .text(note), .text(tags)])
}
exercise("E1", "D1", page: 10, kind: 0, chapter: #"["第一章","1.1"]"#, tags: #"["真题","2023"]"#, starred: true)
exercise("E2", "D1", page: 11, kind: 1, chapter: #"["第一章","1.1"]"#, tags: #"["真题"]"#, wrong: true)
exercise("E3", "D1", page: 20, kind: 3, chapter: #"["第二章"]"#, note: "笔记")
exercise("E4", "D1", page: 21, kind: 4, chapter: #"["第二章"]"#, tags: #"["模拟"]"#)
exercise("E5", "D2", page: 5, kind: 0, tags: #"["REAL"]"#)
exercise("E6", "D2", page: nil, kind: 2, tags: #"["real"]"#)
exercise("E7", "D2", page: 6, kind: 0, tags: "not json")

// 作答（上海时间 = UTC+8）。时间戳故意混几种写法：带毫秒的 Z、不带毫秒的 Z、+08:00。
func attempt(_ id: String, _ ex: String, _ correct: Bool?, _ at: String, ms: Int, source: String = "") {
    run("INSERT INTO exercise_attempt(id,exercise_id,answer,correct,elapsed_ms,created_at,source) VALUES(?,?,'',?,?,?,?)",
        [.text(id), .text(ex), correct.map { .int($0 ? 1 : 0) } ?? .null, .int(Int64(ms)), .text(at), .text(source)])
}
attempt("A1", "E1", false, "2026-11-10T15:59:59.999Z", ms: 1000)   // 本地 11-10 23:59:59.999（范围前一刻）
attempt("A2", "E1", true, "2026-11-10T16:00:00.000Z", ms: 2000)    // 本地 11-11 00:00（范围第一刻）
attempt("A3", "E2", false, "2026-11-11T03:00:00Z", ms: 3000)       // 不带毫秒
attempt("A4", "E3", nil, "2026-11-12T18:00:00+08:00", ms: 4000)    // 带时区偏移；填空题没判 → 待判
attempt("A5", "E4", nil, "2026-11-13T15:59:59.000Z", ms: 5000)     // 本地 11-13 23:59:59（范围最后一秒）；主观题没判
attempt("A6", "E4", true, "2026-11-13T01:00:00.000Z", ms: 0, source: "mark")   // 书上的作答：不算练习
attempt("A7", "E5", true, "2026-11-13T16:00:00.000Z", ms: 700)     // 本地 11-14 00:00（范围后一刻）
attempt("A8", "E1", true, "2026-11-12T02:00:00.000Z", ms: 800)
attempt("A9", "E1", false, "2026-11-12T02:00:00.000Z", ms: 900)    // 与 A8 同一刻：按 id 取 A9 为最近一次

// Agent
run("INSERT INTO agent_memory(id,content,created_at,updated_at) VALUES('M1','a',?,?),('M2','b',?,?)",
    [.text(T), .text(T), .text(T), .text(T)])
run("INSERT INTO agent_context(id,created_at,updated_at) VALUES('C1',?,?)", [.text(T), .text(T)])
for (id, conv) in [("T1", "c1"), ("T2", "c1"), ("T3", "c1"), ("T4", "c2")] {
    run("INSERT INTO agent_turn(id,conversation_id,created_at,updated_at) VALUES(?,?,?,?)",
        [.text(id), .text(conv), .text(T), .text(T)])
}

// 日程（今天 = 2026-11-13）
run("INSERT INTO schedule_plan(id,title,created_at,updated_at) VALUES('P1','第三章复习','2026-11-10T00:00:00.000Z',?),('P2','错题','2026-11-12T00:00:00.000Z',?)",
    [.text(T), .text(T)])
for (id, plan, day, doneAt) in [
    ("I1", "P1", "2026-11-11", "2026-11-11T12:00:00.000Z"),   // 本地 11-11 20:00 做完
    ("I2", "P1", "2026-11-12", ""),                           // 逾期
    ("I3", "P1", "2026-11-13", "2026-11-12T16:30:00.000Z"),   // 本地 11-13 00:30 做完
    ("I4", "P1", "2026-11-13", ""),                           // 今天、没做
    ("I5", "P2", "", ""),                                     // 没排日期、没做
    ("I6", "P2", "", "2026-11-10T15:00:00.000Z"),             // 没排日期、做完了（本地 11-10，范围外）
    ("I7", "", "2026-11-15", ""),                             // 将来的
    ("I8", "", "2026-11-12", "2026-11-13T17:00:00.000Z"),     // 本地 11-14 01:00 才做完（范围外）
] as [(String, String, String, String)] {
    run("INSERT INTO schedule_item(id,plan_id,title,day,done_at,created_at,updated_at) VALUES(?,?,'',?,?,?,?)",
        [.text(id), .text(plan), .text(day), .text(doneAt), .text(T), .text(T)])
}

print("— 书库")
do {
    let l = query([.library]).library!
    eq([l.documents, l.pages, l.started, l.finished, l.notStarted], [4, 181, 3, 2, 1], "篇数 / 页数 / 读过 / 读完 / 没读")
    eq(l.byDocument.map(\.id), ["D1", "D2", "D4", "D3"], "最近打开的在前")
    eq(l.byDocument.map(\.progress), [50, 100, 100, 0], "进度百分比（读到的页 / 总页数）")
    eq(l.byDocument.map(\.finished), [false, true, true, false], "读完")
    eq(l.byDocument.filter(\.started).count, l.started, "逐篇的「读过」与 SQL 同一口径")
    eq(l.byDocument.filter(\.finished).count, l.finished, "逐篇的「读完」与 SQL 同一口径")
    let capped = query([.library], limit: 2).library!
    eq(capped.byDocument.count, 2, "limit 2 只列两篇")
    eq(capped.byDocumentOmitted, 2, "说明还有两篇没列")
    let one = query([.library], doc: "D1").library!
    eq([one.documents, one.pages, one.started, one.finished], [1, 100, 1, 0], "只数 D1")
}

print("— 批注")
do {
    let a = query([.annotations]).annotations!
    let c = a.counts
    eq([c.text, c.highlights, c.bookmarks, c.images, c.aiThreads, c.ink, c.scratchInk], [4, 2, 1, 1, 1, 7, 4], "按种类")
    eq(a.pagesWithInk, 4, "有笔迹的页：D1 三页 + D2 一页")
    eq(a.scratchPads, 1, "草稿纸")
    eq(a.byDocument.map(\.id), ["D1", "D2"], "批注多的文档在前；没有批注的文档不列")
    eq(a.byDocument.first?.pagesWithInk, 3, "D1 有笔迹的页")
    eq(a.byDocument.first?.title, "高等数学", "带书名")
    let one = query([.annotations], doc: "D2").annotations!
    eq([one.counts.text, one.counts.ink, one.pagesWithInk, one.scratchPads, one.byDocument.count], [1, 2, 1, 0, 1], "只数 D2")
    let capped = query([.annotations], limit: 1).annotations!
    eq([capped.byDocument.count, capped.byDocumentOmitted], [1, 1], "limit 1：列一篇、说明还有一篇")
}

print("— 画板")
eq(query([.boards]).boards, StatsStore.Boards(boards: 2, pagedBoards: 1, pages: 2, inkItems: 5, imageItems: 1), "画板 / 分页 / 页 / 笔迹 / 图")

print("— 习题")
do {
    let e = query([.exercises]).exercises!
    eq([e.total, e.single, e.multiple, e.fill, e.subjective, e.otherKinds], [7, 3, 1, 1, 1, 1], "按题型（2 = 不认识的）")
    eq([e.starred, e.inMistakes, e.withNote, e.untagged], [1, 1, 1, 2], "收藏 / 错题本 / 有笔记 / 没标签（含坏 JSON）")
    eq([e.answered, e.neverAnswered], [5, 2], "做过 / 没做过（书上的作答也算做过）")
    eq([e.lastCorrect, e.lastWrong, e.lastUngraded], [1, 2, 2], "最近一次：对 / 错 / 没判（同一刻按 id，不重复计）")
    eq([e.attempts, e.awaitingGrading], [9, 2], "作答数 / 待判（只算填空、主观题）")
    eq(e.byDocument.map { [$0.documentId, $0.title] }, [["D1", "高等数学"], ["D2", "线性代数"]], "按文档：题多的在前")
    eq(e.byDocument.map { [$0.total, $0.answered, $0.inMistakes, $0.starred] }, [[4, 4, 1, 1], [3, 1, 0, 0]], "按文档的数")
    eq(e.byChapter.map(\.chapter), [[], ["第一章", "1.1"], ["第二章"]], "按章节：书名序，同书按最早那页")
    eq(e.byChapter.map { [$0.total, $0.answered, $0.inMistakes, $0.starred] }, [[3, 1, 0, 0], [2, 2, 1, 1], [2, 2, 0, 0]], "按章节的数")
    eq(e.byTag.map(\.tag), ["REAL", "真题", "2023", "模拟"], "按标签：题多的在前，大小写不同算一个")
    eq(e.byTag.map { [$0.total, $0.answered, $0.inMistakes, $0.starred] }, [[2, 1, 0, 0], [2, 2, 1, 1], [1, 1, 0, 1], [1, 1, 0, 0]], "按标签的数")
    eq([e.byDocumentOmitted, e.byChapterOmitted, e.byTagOmitted], [0, 0, 0], "没超 limit：都没省略")
    let capped = query([.exercises], limit: 2).exercises!
    eq([capped.byTag.count, capped.byTagOmitted, capped.byChapter.count, capped.byChapterOmitted], [2, 2, 2, 1], "limit 2：标签、章节都截断并说明")
    let d2 = query([.exercises], doc: "D2").exercises!
    eq([d2.total, d2.answered, d2.lastCorrect, d2.attempts, d2.awaitingGrading], [3, 1, 1, 1, 0], "只数 D2")
    eq(d2.byTag.map(\.tag), ["REAL"], "只数 D2 的标签")
    eq(d2.byChapter.map(\.chapter), [[]], "只数 D2 的章节")
}

print("— 练习（按本地日）")
do {
    let p = query([.practice]).practice!
    eq([p.attempts, p.correct, p.wrong, p.ungraded, p.exercises, p.elapsedMs], [6, 2, 2, 2, 4, 15700],
       "范围内：不含前一刻 / 后一刻 / 书上的作答")
    eq(p.byDay.map(\.day), ["2026-11-11", "2026-11-12", "2026-11-13"], "每天一行")
    eq(p.byDay.map { [$0.attempts, $0.correct, $0.wrong, $0.ungraded, $0.exercises, $0.elapsedMs] },
       [[2, 1, 1, 0, 2, 5000], [3, 1, 1, 1, 2, 5700], [1, 0, 0, 1, 1, 5000]], "每天的数（+08:00 写法归到本地那天）")
    let before = query([.practice], from: "2026-11-10", to: "2026-11-10").practice!
    eq([before.attempts, before.wrong], [1, 1], "11-10 只有 23:59:59.999 那一次")
    let after = query([.practice], from: "2026-11-14", to: "2026-11-14").practice!
    eq([after.attempts, after.correct], [1, 1], "11-14 00:00 那次归到 11-14")
    let gap = query([.practice], from: "2026-11-01", to: "2026-11-30").practice!
    eq(gap.byDay.count, 5, "没作答的天不列（11-10 / 11 / 12 / 13 / 14）")
    let d2 = query([.practice], doc: "D2").practice!
    eq([d2.attempts, d2.byDay.count], [0, 0], "只数 D2：范围内没练")
    let d2b = query([.practice], doc: "D2", from: "2026-11-14", to: "2026-11-14").practice!
    eq(d2b.byDay.map(\.day), ["2026-11-14"], "只数 D2：11-14 那次")
    // 换时区：纽约（UTC-5）的 11-10 = UTC 11-10 05:00 ~ 11-11 05:00，A3（UTC 11-11 03:00）也落在里面
    let nyr = try! store.stats(StatsStore.Query(sections: [.practice], from: "2026-11-10", to: "2026-11-10",
                                                today: "2026-11-13", timeZone: ny)).practice!
    eq(nyr.attempts, 3, "按纽约时间 11-10 有三次（A1、A2、A3）")
}

print("— Agent")
eq(query([.agent]).agent, StatsStore.Agent(memories: 2, contexts: 1, conversations: 2, turns: 4), "记忆 / 上下文 / 对话 / 轮")

print("— 日程")
do {
    let s = query([.schedule]).schedule!
    eq([s.plans, s.items, s.done, s.open, s.overdue, s.undated], [2, 8, 4, 4, 1, 1], "计划 / 事项 / 做完 / 没做 / 逾期 / 没排日期")
    eq([s.todayItems, s.todayDone], [2, 1], "今天")
    eq(s.byPlan.map(\.id), ["P2", "P1"], "按计划：新建的在前")
    eq(s.byPlan.map { [$0.items, $0.done, $0.overdue] }, [[2, 1, 0], [4, 2, 1]], "每份计划的数")
    eq(s.byDay.map(\.day), ["2026-11-11", "2026-11-12", "2026-11-13"], "范围内有事的天")
    eq(s.byDay.map { [$0.items, $0.done, $0.completed] }, [[1, 1, 1], [2, 1, 0], [2, 1, 1]],
       "排在那天 / 其中做完 / 那天做完（按 done_at 的本地日）")
    let capped = query([.schedule], limit: 1).schedule!
    eq([capped.byPlan.count, capped.byPlanOmitted], [1, 1], "limit 1：列一份计划、说明还有一份")
}

print("— 只要几块")
do {
    let r = query([.agent, .boards])
    check(r.library == nil && r.annotations == nil && r.exercises == nil && r.practice == nil && r.schedule == nil,
          "没要的块是 nil")
    let o = dto(r)
    eq(Set(o.keys), ["workspace", "today", "from", "to", "agent", "boards"], "结构化结果只带要的块")
}

print("— 结构化结果 / 摘要")
do {
    let r = query()
    let md = [MCPStats.MarkdownSource(name: "Notes", kind: "workspace", notes: 12),
              MCPStats.MarkdownSource(name: "Obsidian", kind: "reference", notes: 30)]
    let o = dto(r, markdown: md)
    schemaOK(o, "全部块的结构化结果符合 schema")
    schemaOK(dto(query(doc: "D1"), document: (id: "D1", title: "高等数学"), markdown: md), "带 document 的结果符合 schema")
    eq((o["markdown"] as? MCPObject)?["notes"] as? Int, 42, "Markdown 笔记合计")
    let lib = o["library"] as? MCPObject
    let first = (lib?["by_document"] as? [MCPObject])?.first
    eq(first?["read_page"] as? Int, 50, "read_page 对外 1 起")
    eq((o["exercises"] as? MCPObject)?["never_answered"] as? Int, 2, "never_answered")
    eq(((o["exercises"] as? MCPObject)?["by_type"] as? MCPObject)?["other"] as? Int, 1, "by_type.other")
    eq((o["practice"] as? MCPObject)?["active_days"] as? Int, 3, "active_days")
    let text = MCPStats.text(workspace: "测试", today: "2026-11-13", from: "2026-11-11", to: "2026-11-13",
                             document: nil, report: r, markdown: md)
    check(text.contains("Library: 4 document(s), 181 pages; 3 started, 2 finished"), "摘要：书库")
    check(text.contains("高等数学: p.50/100 (50%)"), "摘要：逐篇进度")
    check(text.contains("Markdown notes: 42 (Notes 12, Obsidian 30)."), "摘要：Markdown")
    check(text.contains("2 waiting to be graded"), "摘要：待判")
    check(text.contains("2026-11-12: 3 answer(s) on 2, 1 right, 1 wrong, 1 not judged, 5 s"), "摘要：每天的练习")
    check(text.contains("today 1/2 done"), "摘要：今天的日程")
    eq(MCPStats.duration(5_100_000), "1 h 25 min", "时长 1 h 25 min")
    eq(MCPStats.duration(59_999), "59 s", "时长 59 s")
}

print("— 量大时")
do {
    // 一年 2 万次作答，查整整 366 天的分天：要快（MATERIALIZED 让每行只解析一次时间戳）
    let base = isoF.date(from: "2025-11-14T00:00:00Z")!
    try! raw.transaction {
        for i in 0..<20_000 {
            let at = ISO.string(base.addingTimeInterval(Double(i) * 1577))   // 约一年铺开
            try raw.run("INSERT INTO exercise_attempt(id,exercise_id,answer,correct,elapsed_ms,created_at) VALUES(?,?,'',?,10,?)",
                        [.text(String(format: "Z%06d", i)), .text(["E1", "E2", "E5"][i % 3]), .int(Int64(i % 2)), .text(at)])
        }
    }
    let t0 = Date()
    let r = query([.practice, .exercises], from: "2025-11-14", to: "2026-11-13")
    let ms = Date().timeIntervalSince(t0) * 1000
    check(ms < 1500, String(format: "366 天分天 + 习题统计 %.0f ms", ms))
    let p = r.practice!
    eq(p.byDay.reduce(0) { $0 + $1.attempts }, p.attempts, "分天加起来 = 合计")
    check(p.attempts >= 19_900, "约两万次都数到了（\(p.attempts)）")
}

raw.close()
store.close()
print("\n\(pass) 通过，\(fail) 失败")
exit(fail == 0 ? 0 : 1)
