// 离线镜像的扫描页对齐通道（SCAN-ALIGN-PLAN.md §5）测试。运行：
//   cp spike/mirror-align-test.swift /tmp/main.swift && swiftc Sources/Store/*.swift /tmp/main.swift -o /tmp/mal && /tmp/mal
// （须命名为 main.swift：swiftc 多文件时顶层代码只允许在 main.swift）
// 覆盖：
//   ① alignPlan 纯函数：一侧缺 → 补过去；两侧 updated_at 不同 → 新的覆盖旧的；相同 → 不动；
//   ② Plan 标志：写入硬盘方向计入 pendingToSource、挡自动推送；只有拉回本机方向时可以自动推送；
//   ③ LibraryStore：page_align 行读写、开关、copyPageAlign 逐字搬（时间戳字符串不经 Date 往返）；
//   ④ fillAlign 应用后再算一次 plan 为空（幂等收敛）；
//   ⑤ alignStamps 对没有 page_align 表的库（安卓建的老库）返回空、不抛错；
//   ⑥ pageAnchoredNoteCount 只数挂在页面坐标上的那几类。
import Foundation

var pass = 0, fail = 0
func check(_ c: Bool, _ m: String) { if c { pass += 1; print("  ✅ \(m)") } else { fail += 1; print("  ❌ \(m)") } }

print("① alignPlan")
do {
    let p = MirrorDiff.alignPlan(mine: ["a": "2026-09-17T10:00:00.000Z", "b": "2026-09-17T10:00:00.000Z", "c": "2026-09-17T12:00:00.000Z"],
                                 theirs: ["b": "2026-09-17T11:00:00.000Z", "c": "2026-09-17T12:00:00.000Z", "d": "2026-09-01T00:00:00.000Z"])
    check(p.toSource == ["a"], "副本独有 → 写入硬盘")
    check(p.toMirror == ["b", "d"], "硬盘较新 / 硬盘独有 → 拉回本机")
    let q = MirrorDiff.alignPlan(mine: ["x": "2026-09-17T13:00:00.000Z"], theirs: ["x": "2026-09-17T12:59:59.999Z"])
    check(q.toSource == ["x"] && q.toMirror.isEmpty, "副本较新 → 写入硬盘")
}

print("② Plan 标志")
do {
    var p = MirrorDiff.Plan()
    p.alignToMirror = ["h1"]
    check(!p.isEmpty && p.isCleanPushToMirror && p.pendingToSource == 0, "只有拉回本机：可自动推送")
    p.alignToSource = ["h2"]
    check(!p.isCleanPushToMirror && p.pendingToSource == 1, "有写入硬盘：挡自动推送、计入待确认")
    var e = MirrorDiff.Plan()
    e.alignToSource = ["h3"]
    check(!e.isEmpty, "只有对齐改动也不算「两端一致」")
}

let root = FileManager.default.temporaryDirectory.appendingPathComponent("mirror-align-\(UUID().uuidString)")
func ws(_ name: String) -> LibraryStore {
    let u = root.appendingPathComponent(name)
    try! FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
    return try! LibraryStore(workspaceFolder: u)
}
defer { try? FileManager.default.removeItem(at: root) }

print("③ LibraryStore 读写")
let src = ws("src.unrd"), mir = ws("mir.unrd")
do {
    check(src.meta("schema_version") == String(LibraryStore.schemaVersion) && LibraryStore.schemaVersion >= 14, "schema ≥ v14")
    let payload = Data("{\"v\":1,\"w\":497.5,\"pages\":[[0.01,-3,0,500,700]]}".utf8)
    let t0 = Date(timeIntervalSince1970: 1_790_000_000)
    try! src.upsertPageAlign(PageAlignRow(contentHash: "H1", enabled: true, pageCount: 1, payload: payload,
                                          createdAt: t0, updatedAt: t0))
    let r = try! src.pageAlign(contentHash: "H1")
    check(r?.enabled == true && r?.payload == payload && r?.pageCount == 1, "upsert → 读回")
    check((try! src.enabledPageAligns()).map(\.contentHash) == ["H1"], "enabledPageAligns")
    try! src.setPageAlignEnabled(contentHash: "H1", on: false, at: t0.addingTimeInterval(60))
    check(try! src.pageAlign(contentHash: "H1")?.enabled == false, "关开关不删行")
    check((try! src.enabledPageAligns()).isEmpty, "关了就不在 enabled 列表里")
    check(try! src.pageAlign(contentHash: "nope") == nil, "没测过 → nil")

    // 手写一个「别的端写的」时间戳格式，验证逐字搬
    try! src.withMirrorDB { db in
        try db.run("UPDATE page_align SET updated_at=? WHERE content_hash=?", [.text("2026-09-17T08:00:00Z"), .text("H1")])
    }
    check(try! src.copyPageAlign(contentHash: "H1", to: mir), "copyPageAlign 成功")
    check((try! mir.mirrorAlignStamps())["H1"] == "2026-09-17T08:00:00Z", "时间戳字符串逐字搬过去")
    check(try! mir.pageAlign(contentHash: "H1")?.payload == payload, "payload 逐字节相同")
    check(try! src.copyPageAlign(contentHash: "missing", to: mir) == false, "没有这一行 → false")
}

print("④ fillAlign 收敛")
do {
    // 副本上打开（较新），硬盘上还有另一本
    try! mir.withMirrorDB { db in
        try db.run("UPDATE page_align SET enabled=1, updated_at=? WHERE content_hash=?", [.text("2026-09-17T09:00:00Z"), .text("H1")])
    }
    try! src.upsertPageAlign(PageAlignRow(contentHash: "H2", enabled: true, pageCount: 3, payload: Data("{}".utf8),
                                          createdAt: .now, updatedAt: .now))
    let p = MirrorDiff.alignPlan(mine: try! mir.mirrorAlignStamps(), theirs: try! src.mirrorAlignStamps())
    check(p.toSource == ["H1"] && p.toMirror == ["H2"], "副本较新 → 写入硬盘；硬盘独有 → 拉回本机")
    let a = try! MirrorApply.fillAlign(from: mir, to: src, keys: p.toSource)
    let b = try! MirrorApply.fillAlign(from: src, to: mir, keys: p.toMirror)
    check(a == 1 && b == 1, "两个方向各写一行")
    check(try! src.pageAlign(contentHash: "H1")?.enabled == true, "硬盘上 H1 的开关被副本那份覆盖")
    let again = MirrorDiff.alignPlan(mine: try! mir.mirrorAlignStamps(), theirs: try! src.mirrorAlignStamps())
    check(again.toSource.isEmpty && again.toMirror.isEmpty, "再算一次为空（幂等收敛）")
}

print("⑤ 没有 page_align 表的老库")
do {
    let dir = root.appendingPathComponent("old")
    try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let db = try! SQLiteDB(path: dir.appendingPathComponent("library.sqlite").path)
    try! db.exec("CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT);")
    check((try? MirrorStore.alignStamps(db)) == [:], "表不存在 → 空、不抛错")
    db.close()
}

print("⑥ pageAnchoredNoteCount")
do {
    let (doc, _) = try! src.findOrCreate(hash: "H9", title: "书", pageCount: 10, path: "/tmp/x.pdf")
    func note(_ kind: Int) -> LibNote {
        LibNote(id: UUID().uuidString, documentId: doc.id, kind: kind, page: 0, anchor: .zero,
                payload: Data("{}".utf8), createdAt: .now, updatedAt: .now)
    }
    for k in [0, 1, 2, 2, 3, 4, 5, 6] { try! src.upsertNote(note(k)) }
    check(try! src.pageAnchoredNoteCount(documentId: doc.id) == 6, "数 0/2/2/3/5/6，不数 AI 会话(1) 与草稿纸笔迹(4)")
}

print("\n\(pass) passed, \(fail) failed")
exit(fail == 0 ? 0 : 1)
