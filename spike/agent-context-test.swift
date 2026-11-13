// Agent 上下文（`ACP-AGENT-PLAN.md §12`，schema v23）回归测试：从回复里切标题 / 正文、库的读写、
// 老库升级补表、离线镜像指纹、回收站「归档 → 删 → 放回」。运行：
//   cp spike/agent-context-test.swift /tmp/main.swift && \
//     swiftc Sources/Store/*.swift Sources/App/TrashModel.swift Sources/Agent/AgentContextText.swift /tmp/main.swift \
//       -o /tmp/act && /tmp/act
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

// MARK: - 切标题与正文

print("— 从回复里取标题与正文")
do {
    let r = AgentContextText.parse("# 高数第二章复习\n\n## 目标\n把导数一节的错题过一遍。\n")
    eq(r.title, "高数第二章复习", "第一行 # 标题")
    eq(r.summary, "## 目标\n把导数一节的错题过一遍。", "正文 = 标题行之后（前后空白去掉，二级标题留着）")

    let p = AgentContextText.parse("好的，以下是交接摘要：\n\n# 习题导入进度\n已导入第 3~12 页。")
    eq(p.title, "习题导入进度", "标题行前面的客套话丢掉")
    eq(p.summary, "已导入第 3~12 页。", "正文不含客套话")

    let h2 = AgentContextText.parse("## 只有二级标题\n内容")
    eq(h2.title, "只有二级标题", "二级标题也算标题行")

    let none = AgentContextText.parse("\n\n第一行当标题\n第二行\n")
    eq(none.title, "第一行当标题", "没有标题行：第一行非空文字当标题")
    eq(none.summary, "第一行当标题\n第二行", "没有标题行：整段当正文")

    let tag = AgentContextText.parse("#标签不是标题\n正文")
    eq(tag.title, "标签不是标题", "「#」后面没空格不算标题行，退回第一行当标题（去掉 #）")
    eq(tag.summary, "#标签不是标题\n正文", "此时正文是整段")

    let empty = AgentContextText.parse("   \n")
    eq(empty.title, "", "空回复：标题空")
    eq(empty.summary, "", "空回复：正文空（调用方据此不存）")

    let onlyTitle = AgentContextText.parse("# 只有标题")
    eq(onlyTitle.summary, "", "只有标题行：正文空（调用方据此不存）")
}

print("— 标题规整")
eq(AgentContextText.cleanTitle("  ## **加粗的标题**  "), "加粗的标题", "去掉 #、首尾空白与包着的 **")
eq(AgentContextText.cleanTitle("两行\n标题"), "两行 标题", "换行并成一个空格")
let long = String(repeating: "长", count: 80)
let cleaned = AgentContextText.cleanTitle(long)
eq(cleaned.count, 60, "超过 60 字截断")
check(cleaned.hasSuffix("…"), "截断处加省略号")

print("— 带进新对话的那一块")
do {
    let d = ISO8601DateFormatter().date(from: "2026-11-02T08:00:00Z")!
    let t = AgentContextText.handoff(title: "高数复习", summary: "第一行\n第二行", agent: "Kimi", id: "ABC", date: d)
    check(t.contains("Saved context \"高数复习\" (context_id ABC)"), "带标题与 context_id")
    check(t.contains("written by Kimi on 2026-11-02"), "带 Agent 名与日期（yyyy-MM-dd）")
    check(t.hasSuffix("第一行\n第二行"), "摘要原样放在最后")
    let anon = AgentContextText.handoff(title: "x", summary: "y", agent: "", id: "1", date: d)
    check(anon.contains("written on 2026-11-02"), "没有 Agent 名时只写日期")
}

check(AgentContextText.saveInstruction.contains("\"# \""), "保存说明里要求第一行是 # 标题")

// MARK: - 库

let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("agent_context_test_\(UInt64.random(in: 0..<1_000_000))")
try? FileManager.default.removeItem(at: tmp)
try! FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: tmp) }

print("— 库的读写")
var store: LibraryStore! = try LibraryStore(workspaceFolder: tmp)
eq(LibraryStore.schemaVersion, 25, "schema 版本 25")
eq(store.meta("schema_version"), "25", "新库记下 25")
eq(try store.agentContexts().count, 0, "新库没有上下文")

let t0 = ISO8601DateFormatter().date(from: "2026-11-01T10:00:00Z")!
let t1 = ISO8601DateFormatter().date(from: "2026-11-02T10:00:00Z")!
let a = LibAgentContext(id: "AAAAAAAA-0000-0000-0000-000000000001", title: "较早的", summary: "摘要 A\n- 一\n- 二",
                        agent: "Kimi", sessionId: "s-1", createdAt: t0, updatedAt: t0)
let b = LibAgentContext(id: "BBBBBBBB-0000-0000-0000-000000000002", title: "较新的", summary: "摘要 B",
                        agent: "Claude Code", sessionId: "", createdAt: t1, updatedAt: t1)
try store.upsertAgentContext(a)
try store.upsertAgentContext(b)
let all = try store.agentContexts()
eq(all.map(\.id), [b.id, a.id], "按更新时间倒序")
eq(try store.agentContext(id: a.id), a, "读回来逐字段相同（含多行 Markdown、中文）")

var a2 = a
a2.title = "改过标题"
a2.summary = "改过的摘要"
a2.createdAt = t1            // 覆盖写时 created_at 不该被改
a2.updatedAt = t1.addingTimeInterval(60)
try store.upsertAgentContext(a2)
let got = try store.agentContext(id: a.id)!
eq(got.title, "改过标题", "覆盖写改标题")
eq(got.summary, "改过的摘要", "覆盖写改摘要")
eq(got.createdAt, t0, "覆盖写不动 created_at")
eq(try store.agentContexts().first?.id, a.id, "改过的那份排到最前")

print("— 离线镜像指纹")
do {
    let spec = MirrorFp.spec("agent_context")
    check(spec != nil, "agent_context 在 MirrorFp.specs 里")
    eq(spec?.columns.map(\.name) ?? [], ["id", "title", "summary", "agent", "session_id", "created_at", "updated_at"],
       "列序 = CREATE TABLE 的顺序")
    eq(spec?.lww, "updated_at", "按 updated_at 取新")
    let order = MirrorFp.specs.map(\.table)
    check((order.firstIndex(of: "agent_context") ?? 0) > (order.firstIndex(of: "exercise_attempt") ?? 99)
          && (order.firstIndex(of: "agent_context") ?? 99) < (order.firstIndex(of: "meta") ?? 0),
          "排在 exercise_attempt 之后、meta 之前（与安卓 MirrorFp.kt 一致）")
    let snap = try store.mirrorSnapshot()
    eq(snap["agent_context"]?.count, 2, "镜像快照带上这张表的两行")
}

print("— 回收站：归档 → 删 → 放回")
do {
    let path = tmp.appendingPathComponent("snap.sqlite").path
    let archived = try store.archiveAgentContexts(ids: [a.id], to: path)
    eq(archived.counts.agentContext, 1, "归档数到 1 份")
    eq(archived.counts.total, 1, "total 算上它")
    let before = try store.agentContext(id: a.id)!
    try store.deleteAgentContexts(ids: [a.id])
    check(try store.agentContext(id: a.id) == nil, "删掉了")
    eq(try store.agentContexts().count, 1, "另一份还在")
    let n = try store.restoreTrash(snapshot: path, remapDocumentId: nil)
    eq(n, 1, "放回 1 行")
    eq(try store.agentContext(id: a.id), before, "放回来逐字段相同")
    // 再放一次：OR REPLACE，幂等
    _ = try store.restoreTrash(snapshot: path, remapDocumentId: nil)
    eq(try store.agentContexts().count, 2, "重复放回不多出行")
    let summary = try store.trashSummary(snapshot: path)
    eq(summary.counts.agentContext, 1, "从快照重建摘要也数得到")
}

print("— manifest：新种类与老条目")
do {
    var m = Trash.Manifest()
    m.kind = .agentContexts
    m.counts.agentContext = 2
    let back = try Trash.decode(Trash.encode(m))
    eq(back.kind, .agentContexts, "种类 agentContexts 编解码回环")
    eq(back.counts.agentContext, 2, "计数编解码回环")
    let json = String(data: try Trash.encode(m), encoding: .utf8) ?? ""
    check(json.contains("\"agentContexts\"") && json.contains("\"agentContext\" : 2"),
          "键名 = agentContexts / agentContext（与安卓一致）")
    let old = #"{"v":1,"kind":"exercises","deletedAt":"2026-10-01T00:00:00Z","title":"x","documentId":"","documentTitle":"","pageCount":0,"counts":{"exercise":3},"images":[],"contentHashes":[]}"#
    let oldM = try Trash.decode(Data(old.utf8))
    eq(oldM.counts.agentContext, 0, "老 manifest 没这个键 → 0")
}

print("— 老库升级补表")
do {
    let dir2 = tmp.appendingPathComponent("old", isDirectory: true)
    try FileManager.default.createDirectory(at: dir2, withIntermediateDirectories: true)
    var s2: LibraryStore! = try LibraryStore(workspaceFolder: dir2)
    try s2.withMirrorDB { db in
        try db.exec("DROP TABLE agent_context")
        try db.run("UPDATE meta SET value='22' WHERE key='schema_version'")
    }
    s2.close()
    s2 = nil
    let s3 = try LibraryStore(workspaceFolder: dir2)
    eq(s3.meta("schema_version"), "25", "v22 库打开后升到 25")
    eq(try s3.agentContexts().count, 0, "补建了 agent_context 表")
    s3.close()
}

store.close()
store = nil

print(fail == 0 ? "\n✅ 全部通过：\(pass) 通过 / 0 失败" : "\n❌ \(fail) 失败 / \(pass) 通过")
exit(fail == 0 ? 0 : 1)
