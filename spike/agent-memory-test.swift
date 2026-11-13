// Agent 记忆与对话记录（`ACP-AGENT-PLAN.md §21–22`，schema v25）回归测试：带进新对话的那一块（条数多时只带最近的、
// 气泡下面认得出）、库的读写、对话概况、离线镜像指纹、回收站「归档 → 删 → 放回」、manifest、老库升级补表。运行：
//   cp spike/agent-memory-test.swift /tmp/main.swift && \
//     swiftc Sources/Store/*.swift Sources/App/TrashModel.swift Sources/Agent/AgentMemoryText.swift \
//       Sources/Agent/AgentSentContext.swift Sources/Agent/AgentMention.swift /tmp/main.swift -o /tmp/amt && /tmp/amt
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

let iso = ISO8601DateFormatter()
let t0 = iso.date(from: "2026-11-12T10:00:00Z")!
let t1 = iso.date(from: "2026-11-13T10:00:00Z")!

// MARK: - 纯逻辑

print("— 名字")
eq(AgentMemoryText.title("第一行\n第二行"), "第一行", "记忆名 = 第一行")
eq(AgentMemoryText.title(String(repeating: "长", count: 50)).count, 41, "超过 40 字截断 + …")
eq(AgentMemoryText.conversationTitle("  QAM-16\n每个码元几比特？ "), "QAM-16 每个码元几比特？", "对话名 = 第一句话压成一行")
eq(AgentMemoryText.conversationTitle(""), "Conversation", "空的第一句话")

print("— 带进新对话的那一块")
do {
    let items = [
        AgentMemoryText.Item(id: "AAAAAAAA-1111", content: "用户在复习计算机网络\n偏好先给结论", agent: "Kimi", updatedAt: t1),
        AgentMemoryText.Item(id: "BBBBBBBB-2222", content: "公式用 $…$", agent: "", updatedAt: t0),
    ]
    let b = AgentMemoryText.block(items)
    check(b.hasPrefix(AgentSentContext.Marker.memory + " (2 of 2)"), "首行：Marker + 条数")
    check(b.contains("- [memory_id AAAAAAAA] 用户在复习计算机网络\n  偏好先给结论 (Kimi, 2026-11-13)"), "多行记忆缩进、带 Agent 与日期")
    check(b.contains("- [memory_id BBBBBBBB] 公式用 $…$ (2026-11-12)"), "没有 Agent 名只写日期")
    check(b.contains("save_memory") && b.contains("delete_memory") && b.contains("read_conversation"), "带上怎么记、怎么查")
    let parsed = AgentSentContext.parse(hidden: b)
    eq(parsed.count, 1, "气泡下面认出一项")
    eq(parsed.first?.kind, .memories, "种类 = 工作区记忆")
    eq(parsed.first?.page, 2, "条数 = 2")

    let none = AgentMemoryText.block([])
    check(none.hasPrefix(AgentSentContext.Marker.memory + " (0 of 0)") && none.contains("save_memory"), "没有记忆也带说明")
    eq(AgentSentContext.parse(hidden: none).count, 0, "一条都没带：气泡下面不显示")

    // 超过预算：只带最近的那些，并说明一共几条
    let many = (0..<40).map { i in
        AgentMemoryText.Item(id: String(format: "%08d-0000", i), content: String(repeating: "记", count: 300), agent: "Kimi",
                             updatedAt: t1.addingTimeInterval(Double(-i)))
    }
    let mb = AgentMemoryText.block(many)
    let shown = mb.components(separatedBy: "[memory_id ").count - 1
    check(shown > 0 && shown < 40, "超过 \(AgentMemoryText.budget) 字只带一部分：带了 \(shown) 条")
    check(mb.hasPrefix(AgentSentContext.Marker.memory + " (\(shown) of 40)"), "首行写明带了几条、一共几条")
    check(mb.contains("list_memories"), "告诉 Agent 去 list_memories 看全部")
    check(mb.contains("[memory_id 00000000]") && !mb.contains("[memory_id 00000039]"), "带的是最近改过的")

    // 一条特别长：至少带它这一条
    let huge = [AgentMemoryText.Item(id: "CCCCCCCC", content: String(repeating: "长", count: 7000), agent: "", updatedAt: t1)]
    check(AgentMemoryText.block(huge).contains("[memory_id CCCCCCCC]"), "只有一条且超长：照样带上")

    // 和交接摘要一起：记忆排在前面，两项都认得出
    let handoff = AgentSentContext.Marker.handoff + " to this message.\n" + AgentSentContext.Marker.savedTitle + "复习\" (context_id X):\n正文"
    let both = AgentSentContext.parse(hidden: b + "\n" + handoff)
    eq(both.map(\.kind), [.memories, .handoff], "记忆 + 交接摘要：两项都在")
}

// MARK: - 库

let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("agent_memory_test_\(UInt64.random(in: 0..<1_000_000))")
try? FileManager.default.removeItem(at: tmp)
try! FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: tmp) }

print("— 记忆的读写")
var store: LibraryStore! = try LibraryStore(workspaceFolder: tmp)
eq(LibraryStore.schemaVersion, 26, "schema 版本 26")
eq(store.meta("schema_version"), "26", "新库记下 26")
eq(try store.agentMemories().count, 0, "新库没有记忆")
let a = LibAgentMemory(id: "AAAAAAAA-0000-0000-0000-000000000001", content: "较早的\n- 一", agent: "Kimi", createdAt: t0, updatedAt: t0)
let b = LibAgentMemory(id: "BBBBBBBB-0000-0000-0000-000000000002", content: "较新的 $x^2$", agent: "", createdAt: t1, updatedAt: t1)
try store.upsertAgentMemory(a)
try store.upsertAgentMemory(b)
eq(try store.agentMemories().map(\.id), [b.id, a.id], "按更新时间倒序")
eq(try store.agentMemory(id: a.id), a, "读回来逐字段相同")
var a2 = a
a2.content = "改过的"
a2.createdAt = t1
a2.updatedAt = t1.addingTimeInterval(60)
try store.upsertAgentMemory(a2)
let got = try store.agentMemory(id: a.id)!
eq(got.content, "改过的", "覆盖写改正文")
eq(got.createdAt, t0, "覆盖写不动 created_at")
eq(try store.agentMemories().first?.id, a.id, "改过的排到最前")

print("— 对话记录")
func turn(_ id: String, _ conv: String, _ at: Date, _ u: String, _ r: String, agent: String = "Kimi") -> LibAgentTurn {
    LibAgentTurn(id: id, conversationId: conv, agent: agent, sessionId: conv, userText: u, replyText: r, createdAt: at, updatedAt: at)
}
try store.insertAgentTurn(turn("T1", "C1", t0, "第一句", "回复一"))
try store.insertAgentTurn(turn("T2", "C1", t0.addingTimeInterval(30), "第二句", "回复二"))
try store.insertAgentTurn(turn("T3", "C2", t1, "另一段", "回复三", agent: "Claude Code"))
try store.insertAgentTurn(turn("T1", "C1", t0, "重复的 id", "不该写进去"))
eq(try store.agentTurns(conversationId: "C1").map(\.userText), ["第一句", "第二句"], "一段对话按时间先后；同 id 不重复写")
eq(try store.allAgentTurns().count, 3, "全部 3 轮")
let convs = try store.recentAgentConversations(limit: 10)
eq(convs.map(\.id), ["C2", "C1"], "对话概况：最近的在前")
eq(convs.last?.turns, 2, "C1 两轮")
eq(convs.last?.firstUserText, "第一句", "C1 第一句话")
eq(convs.first?.agent, "Claude Code", "C2 的 Agent")
eq(try store.recentAgentConversations(limit: 1).count, 1, "limit 生效")

print("— 离线镜像指纹")
do {
    eq(MirrorFp.spec("agent_memory")?.columns.map(\.name) ?? [], ["id", "content", "agent", "created_at", "updated_at"],
       "agent_memory 列序 = CREATE TABLE 的顺序")
    eq(MirrorFp.spec("agent_turn")?.columns.map(\.name) ?? [],
       ["id", "conversation_id", "agent", "session_id", "user_text", "reply_text", "created_at", "updated_at"],
       "agent_turn 列序 = CREATE TABLE 的顺序")
    let order = MirrorFp.specs.map(\.table)
    check(order.firstIndex(of: "agent_context")! < order.firstIndex(of: "agent_memory")!
          && order.firstIndex(of: "agent_memory")! < order.firstIndex(of: "agent_turn")!
          && order.firstIndex(of: "agent_turn")! < order.firstIndex(of: "meta")!,
          "排在 agent_context 之后、meta 之前（与安卓 MirrorFp.kt 一致）")
    let snap = try store.mirrorSnapshot()
    eq(snap["agent_memory"]?.count, 2, "镜像快照带上两条记忆")
    eq(snap["agent_turn"]?.count, 3, "镜像快照带上三轮对话")
}

print("— 回收站：归档 → 删 → 放回")
do {
    let path = tmp.appendingPathComponent("snap.sqlite").path
    let archived = try store.archiveAgentMemories(ids: [a.id], to: path)
    eq(archived.counts.agentMemory, 1, "归档数到 1 条")
    eq(archived.counts.total, 1, "total 算上它")
    let before = try store.agentMemory(id: a.id)!
    try store.deleteAgentMemories(ids: [a.id])
    check(try store.agentMemory(id: a.id) == nil, "删掉了")
    eq(try store.agentMemories().count, 1, "另一条还在")
    eq(try store.restoreTrash(snapshot: path, remapDocumentId: nil), 1, "放回 1 行")
    eq(try store.agentMemory(id: a.id), before, "放回来逐字段相同")
    _ = try store.restoreTrash(snapshot: path, remapDocumentId: nil)
    eq(try store.agentMemories().count, 2, "重复放回不多出行")
    eq(try store.trashSummary(snapshot: path).counts.agentMemory, 1, "从快照重建摘要也数得到")
}

print("— manifest：新种类与老条目")
do {
    var m = Trash.Manifest()
    m.kind = .agentMemories
    m.counts.agentMemory = 3
    let back = try Trash.decode(Trash.encode(m))
    eq(back.kind, .agentMemories, "种类 agentMemories 编解码回环")
    eq(back.counts.agentMemory, 3, "计数编解码回环")
    let json = String(data: try Trash.encode(m), encoding: .utf8) ?? ""
    check(json.contains("\"agentMemories\"") && json.contains("\"agentMemory\" : 3"), "键名 = agentMemories / agentMemory（与安卓一致）")
    let old = #"{"v":1,"kind":"agentContexts","deletedAt":"2026-11-02T00:00:00Z","title":"x","documentId":"","documentTitle":"","pageCount":0,"counts":{"agentContext":1},"images":[],"contentHashes":[]}"#
    eq(try Trash.decode(Data(old.utf8)).counts.agentMemory, 0, "老 manifest 没这个键 → 0")
}

print("— 老库升级补表")
do {
    let dir2 = tmp.appendingPathComponent("old", isDirectory: true)
    try FileManager.default.createDirectory(at: dir2, withIntermediateDirectories: true)
    var s2: LibraryStore! = try LibraryStore(workspaceFolder: dir2)
    try s2.withMirrorDB { db in
        try db.exec("DROP TABLE agent_memory")
        try db.exec("DROP TABLE agent_turn")
        try db.run("UPDATE meta SET value='24' WHERE key='schema_version'")
    }
    s2.close()
    s2 = nil
    let s3 = try LibraryStore(workspaceFolder: dir2)
    eq(s3.meta("schema_version"), "26", "v24 库打开后升到 26")
    eq(try s3.agentMemories().count, 0, "补建了 agent_memory 表")
    eq(try s3.recentAgentConversations(limit: 5).count, 0, "补建了 agent_turn 表")
    s3.close()
}

store.close()
store = nil

print(fail == 0 ? "\n✅ 全部通过：\(pass) 通过 / 0 失败" : "\n❌ \(fail) 失败 / \(pass) 通过")
exit(fail == 0 ? 0 : 1)
