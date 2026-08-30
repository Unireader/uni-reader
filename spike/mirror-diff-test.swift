// 离线镜像 三方合并（`MirrorDiff` + `MirrorReport`）测试。方案 OFFLINE-MIRROR-PLAN.md §3.1/§6。运行：
//   cp spike/mirror-diff-test.swift /tmp/main.swift && swiftc Sources/Store/*.swift /tmp/main.swift -o /tmp/mdt && /tmp/mdt
// （须命名为 main.swift：swiftc 多文件时顶层代码只允许在 main.swift）
//
// ① 用合成的 base/mine/theirs 把 §3.1 判定表**每一格**各造一条，逐格断言；
// ② 再用真库跑一遍端到端：建工作区 → 建镜像 → 两边各改一通 → 干跑，验证结论与报告。
//
// 🔴 这一层判错一格的后果不是"某个功能不好用"，是**静默丢笔迹**——所以每一格都要有用例，
//    包括"什么都不做"的那几格（漏判成"要删"和漏判成"不管"一样致命）。
import Foundation

var pass = 0, fail = 0
func check(_ c: Bool, _ m: String) { if c { pass += 1; print("  ✅ \(m)") } else { fail += 1; print("  ❌ \(m)") } }

let fm = FileManager.default
let root = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("mirror_diff_\(UInt64.random(in: 0..<1_000_000))")
try! fm.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: root) }

// ============================================================
// ① 判定表逐格（合成输入，纯函数）
// ============================================================

let noteSpec = MirrorFp.spec("note")!
let docSpec = MirrorFp.spec("document")!

/// 造一条 note 行。`w` 变了就等于 payload 变了 → fp 变。
func note(_ id: String, doc: String = "D1", page: Int = 0, w: Int = 1, updated: String) -> [String: Any] {
    ["id": id, "document_id": doc, "kind": Int64(2), "page": Int64(page),
     "anchor_x": 0.1, "anchor_y": 0.2, "anchor_w": 0.3, "anchor_h": 0.4,
     "payload": Data("{\"w\":\(w)}".utf8),
     "created_at": "2026-08-30T10:00:00.000Z", "updated_at": updated]
}
func fp(_ row: [String: Any]) -> String { MirrorFp.fingerprint(row: row, spec: noteSpec) }

/// 跑一格：给定 base/mine/theirs 三份 note 行，返回 plan。
func cell(base: [String: Any]?, mine: [String: Any]?, theirs: [String: Any]?) -> MirrorDiff.Plan {
    let id = "N"
    var b: MirrorDiff.Base = [:]
    if let base { b["note"] = [id: fp(base)] }
    var m: MirrorDiff.Snapshot = ["note": [:]]
    if let mine { m["note"] = [id: mine] }
    var t: MirrorDiff.Snapshot = ["note": [:]]
    if let theirs { t["note"] = [id: theirs] }
    return MirrorDiff.compute(base: b, mine: m, theirs: t)
}

let v1 = note("N", w: 1, updated: "2026-08-30T10:00:00.000Z")
let v2 = note("N", w: 2, updated: "2026-08-30T11:00:00.000Z")   // 较新
let v3 = note("N", w: 3, updated: "2026-08-30T10:30:00.000Z")   // 较旧

print("① §3.1 判定表逐格")

// 1. base 无 / mine 有 / theirs 无 → 镜像新增，写进源盘
var p = cell(base: nil, mine: v1, theirs: nil)
check(p.changes.count == 1 && p.changes[0].side == .source && p.changes[0].op == .upsert
        && p.changes[0].reason == .mirrorAdded, "镜像新增 → 写进源盘")

// 2. base 无 / mine 无 / theirs 有 → 源盘新增，拉进镜像
p = cell(base: nil, mine: nil, theirs: v1)
check(p.changes.count == 1 && p.changes[0].side == .mirror && p.changes[0].reason == .sourceAdded,
      "源盘新增 → 拉进镜像")

// 3. base 有 / mine 无 / theirs 未变 → 镜像删除，源盘也删
p = cell(base: v1, mine: nil, theirs: v1)
check(p.changes.count == 1 && p.changes[0].side == .source && p.changes[0].op == .delete
        && p.changes[0].reason == .mirrorDeleted, "🔴 镜像删除 → 源盘也删（有 base 作证据才敢删）")

// 4. base 有 / mine 未变 / theirs 无 → 源盘删除，镜像也删
p = cell(base: v1, mine: v1, theirs: nil)
check(p.changes.count == 1 && p.changes[0].side == .mirror && p.changes[0].op == .delete
        && p.changes[0].reason == .sourceDeleted, "源盘删除 → 镜像也删")

// 5. base 有 / mine 变了 / theirs 未变 → 镜像修改，写进源盘
p = cell(base: v1, mine: v2, theirs: v1)
check(p.changes.count == 1 && p.changes[0].side == .source && p.changes[0].reason == .mirrorModified,
      "镜像修改 → 写进源盘")

// 6. base 有 / mine 未变 / theirs 变了 → 源盘修改，拉进镜像
p = cell(base: v1, mine: v1, theirs: v2)
check(p.changes.count == 1 && p.changes[0].side == .mirror && p.changes[0].reason == .sourceModified,
      "源盘修改 → 拉进镜像")

// 7. base 有 / 两端都改成不同的 → 冲突，按 updated_at 取新的
p = cell(base: v1, mine: v3, theirs: v2)   // theirs 11:00 比 mine 10:30 新
check(p.conflicts.count == 1 && p.conflicts[0].kind == .bothModified && p.conflicts[0].kept == .source,
      "两端都改 → 冲突，源盘那份较新 → 保留源盘")
check(p.changes.count == 1 && p.changes[0].side == .mirror && p.changes[0].reason == .conflictNewer,
      "…且把源盘那份拉进镜像")
p = cell(base: v1, mine: v2, theirs: v3)   // 反过来
check(p.conflicts.first?.kept == .mirror && p.changes.first?.side == .source,
      "两端都改 → 镜像那份较新 → 保留镜像并写进源盘")

// 8. base 有 / mine 无 / theirs 变了 → 删 vs 改，**保留改**
p = cell(base: v1, mine: nil, theirs: v2)
check(p.conflicts.count == 1 && p.conflicts[0].kind == .deleteVsEdit && p.conflicts[0].kept == .source,
      "🔴 本机删了、硬盘上改了 → 保留改（不丢用户数据优先）")
check(p.changes.count == 1 && p.changes[0].side == .mirror && p.changes[0].op == .upsert
        && p.changes[0].reason == .conflictKeptEdit, "…把它拉回镜像而不是在源盘删掉")

// 9. 反向：base 有 / mine 变了 / theirs 无
p = cell(base: v1, mine: v2, theirs: nil)
check(p.conflicts.first?.kept == .mirror && p.changes.first?.side == .source
        && p.changes.first?.op == .upsert, "🔴 硬盘上删了、本机改了 → 保留改，写回源盘")

// 10~13. 什么都不该做的几格（漏判成"要删"和漏判成"不管"一样致命）
check(cell(base: v1, mine: v1, theirs: v1).changes.isEmpty, "两边都没动 → 无操作")
check(cell(base: v1, mine: nil, theirs: nil).changes.isEmpty, "两边都删了 → 无操作")
check(cell(base: nil, mine: nil, theirs: nil).changes.isEmpty, "三方都没有 → 无操作")
check(cell(base: v1, mine: v2, theirs: v2).changes.isEmpty, "两边改成一样了 → 无操作（不是冲突）")
check(cell(base: nil, mine: v1, theirs: v1).changes.isEmpty, "两边各自新增了一模一样的行 → 无操作")

// 14. bothAdded 且不同（`meta` 这种固定键才可能）
p = cell(base: nil, mine: v3, theirs: v2)
check(p.conflicts.first?.kind == .bothAdded, "两端各自新建同 id 但内容不同 → bothAdded 冲突")

print("② 没有时间戳列的表：冲突保留源盘并报告")
func doc(_ id: String, title: String, lastOpened: String = "2026-08-30T10:00:00.000Z") -> [String: Any] {
    ["id": id, "title": title, "page_count": Int64(10), "added_at": "2026-08-30T09:00:00.000Z",
     "last_opened_at": lastOpened, "sort_order": Int64(0), "read_page": Int64(0), "read_frac": 0.0,
     "read_zoom": 1.0, "read_hfrac": 0.0, "group_name": "", "canvas_mode": Int64(0)]
}
let dBase = doc("D1", title: "原名")
let dMine = doc("D1", title: "本机改的名")
let dTheirs = doc("D1", title: "硬盘改的名")
p = MirrorDiff.compute(base: ["document": ["D1": MirrorFp.fingerprint(row: dBase, spec: docSpec)]],
                       mine: ["document": ["D1": dMine]], theirs: ["document": ["D1": dTheirs]])
check(p.conflicts.count == 1 && p.conflicts[0].kept == .source
        && p.changes.first?.reason == .conflictKeptSource,
      "document 没有 updated_at → 冲突保留源盘（可冲突字段只有标题/分组/进度这类低价值项）")
check(p.conflicts[0].note.contains("没有时间戳"), "冲突说明讲清了为什么这么选（\(p.conflicts[0].note)）")

print("③ last_opened_at：不进指纹，但两端取较晚的")
let dA = doc("D1", title: "同名", lastOpened: "2026-08-30T10:00:00.000Z")
let dB = doc("D1", title: "同名", lastOpened: "2026-08-31T20:00:00.000Z")
p = MirrorDiff.compute(base: ["document": ["D1": MirrorFp.fingerprint(row: dA, spec: docSpec)]],
                       mine: ["document": ["D1": dA]], theirs: ["document": ["D1": dB]])
check(p.changes.isEmpty, "🔴 只有 last_opened_at 不同 → 一条 change 都不产生（否则预览里满屏无意义条目）")
check(p.lastOpenedMerges["D1"] == "2026-08-31T20:00:00.000Z", "…但 Plan 带出「取较晚的那个」交给 M5")
check(!p.isEmpty, "只有 lastOpenedMerges 时 Plan 不算空（否则这条会被当成『无事可做』跳过）")

print("④ 报告：一行 id 都不许出现")
let titles = ["D1": "高等数学"]
p = cell(base: nil, mine: note("N1", page: 86, w: 1, updated: "t"), theirs: nil)
var lines = MirrorReport.summary(p, titles: titles)
check(lines.contains { $0.text.contains("写入硬盘") && $0.text.contains("新增笔迹 1") },
      "摘要按「类别 + 增/删/改」聚合：\(lines.first?.text ?? "-")")
check(lines.first?.detail.first == "《高等数学》：笔迹 +1",
      "明细按书分组（用户是按书记事的，不是按表）：\(lines.first?.detail.first ?? "-")")
check(!lines.contains { $0.text.contains("N1") || $0.detail.contains { $0.contains("N1") } },
      "🔴 报告里没有行 id")
check(MirrorReport.noteKindName(2) == "笔迹" && MirrorReport.noteKindName(4) == "草稿纸笔迹"
        && MirrorReport.noteKindName(0) == "文字注解", "note.kind 翻成人话")
check(MirrorReport.headline(MirrorDiff.Plan()) == "两端一致", "空 plan 的一行式结论")

// 删除也要能说出是哪本书的什么（删除那条 row 是 nil）
p = cell(base: note("N1", page: 86, w: 1, updated: "t"), mine: nil, theirs: note("N1", page: 86, w: 1, updated: "t"))
lines = MirrorReport.summary(p, titles: titles)
check(lines.first?.detail.first == "《高等数学》：笔迹 −1",
      "🔴 删除也带得出标签（row 是 nil，靠 Change 上事先取下的 docId/kind）：\(lines.first?.detail.first ?? "-")")

// ============================================================
// ⑤ 真库端到端
// ============================================================
print("⑤ 真库端到端：建工作区 → 建镜像 → 两边各改一通 → 干跑")

let srcWS = root.appendingPathComponent("源.unrd")
try! fm.createDirectory(at: srcWS.appendingPathComponent("PDFs"), withIntermediateDirectories: true)
let store = try! LibraryStore(workspaceFolder: srcWS)
try! store.setWorkspaceName("源")
let relA = "PDFs/a.pdf"
try! Data(repeating: 0x41, count: 512).write(to: srcWS.appendingPathComponent(relA))
let (docA, varA) = try! store.findOrCreate(hash: "hA", title: "高等数学", pageCount: 100, path: relA)
_ = try! store.addLocation(variantId: varA.id, path: relA, inWorkspace: true)

/// 造 4 条笔迹：n1 两边都不动、n2 镜像删、n3 源盘改、n4 两端都改
var ids: [String] = []
for i in 0..<4 {
    let id = "0000000\(i)-0000-4000-8000-00000000000\(i)"
    ids.append(id)
    try! store.upsertNote(LibNote(id: id, documentId: docA.id, kind: 2, page: 86,
                                  anchor: CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4),
                                  payload: Data("{\"w\":\(i)}".utf8),
                                  createdAt: .now, updatedAt: .now))
}

let dstWS = root.appendingPathComponent("镜像.unrd")
let res = try! MirrorBuilder.create(source: srcWS, store: store, destination: dstWS,
                                    plan: .init(documentsWithPDF: [docA.id]),
                                    resolve: { loc in
                                        (loc.inWorkspace || loc.isRelative)
                                            ? srcWS.appendingPathComponent(loc.path).path : loc.path
                                    })
let mdb = try! SQLiteDB(path: dstWS.appendingPathComponent("UniReader/library.sqlite").path)

// 刚建好：干跑必须为空。这是整个合并方案的地基，先验它。
var plan = try! MirrorStore.plan(mirror: mdb, source: store)
check(plan.isEmpty, "🔴 刚建好的镜像，干跑结论为空（\(MirrorReport.headline(plan))）")

// —— 镜像侧：删 n2、改 n0、加一条新的 ——
try! mdb.run("DELETE FROM note WHERE id=?", [.text(ids[2])])
try! mdb.run("UPDATE note SET payload=?, updated_at=? WHERE id=?",
             [.blob(Data("{\"w\":99}".utf8)), .text("2026-09-01T10:00:00.000Z"), .text(ids[0])])
let newId = UUID().uuidString
try! mdb.run("""
INSERT INTO note(id,document_id,kind,page,anchor_x,anchor_y,anchor_w,anchor_h,payload,created_at,updated_at)
VALUES(?,?,2,86,0.1,0.2,0.3,0.4,?,?,?)
""", [.text(newId), .text(docA.id), .blob(Data("{\"w\":7}".utf8)),
      .text("2026-09-01T10:00:00.000Z"), .text("2026-09-01T10:00:00.000Z")])

// —— 源盘侧：改 n3、两端都改 n1（源盘这份更新）——
try! store.upsertNote(LibNote(id: ids[3], documentId: docA.id, kind: 2, page: 86,
                              anchor: CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4),
                              payload: Data("{\"w\":33}".utf8),
                              createdAt: .now, updatedAt: ISO.date("2026-09-01T09:00:00.000Z")!))
try! store.upsertNote(LibNote(id: ids[1], documentId: docA.id, kind: 2, page: 86,
                              anchor: CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4),
                              payload: Data("{\"w\":11}".utf8),
                              createdAt: .now, updatedAt: ISO.date("2026-09-02T09:00:00.000Z")!))
try! mdb.run("UPDATE note SET payload=?, updated_at=? WHERE id=?",
             [.blob(Data("{\"w\":12}".utf8)), .text("2026-09-01T08:00:00.000Z"), .text(ids[1])])

plan = try! MirrorStore.plan(mirror: mdb, source: store)
func one(_ id: String) -> MirrorDiff.Change? { plan.changes.first { $0.rowId == id } }

check(one(ids[2])?.side == .source && one(ids[2])?.op == .delete, "镜像删的那条 → 源盘也删")
check(one(ids[0])?.side == .source && one(ids[0])?.reason == .mirrorModified, "镜像改的那条 → 写进源盘")
check(one(newId)?.side == .source && one(newId)?.reason == .mirrorAdded, "镜像新增的那条 → 写进源盘")
check(one(ids[3])?.side == .mirror && one(ids[3])?.reason == .sourceModified, "源盘改的那条 → 拉进镜像")
check(one(ids[1])?.side == .mirror && one(ids[1])?.reason == .conflictNewer,
      "两端都改的那条 → 源盘 09-02 比镜像 09-01 新 → 拉进镜像")
check(plan.conflicts.count == 1, "冲突恰好 1 条")
check(plan.changes.count == 5, "改动恰好 5 条（\(plan.changes.count)）")
check(plan.count(.source, .delete) == 1 && plan.count(.source, .upsert) == 2
        && plan.count(.mirror, .upsert) == 2, "四个方向的计数都对")

let snapM = try! MirrorStore.snapshot(mdb)
let snapS = try! store.mirrorSnapshot()
let allTitles = MirrorStore.titles(mine: snapM, theirs: snapS)
check(allTitles[docA.id] == "高等数学", "书名两侧合并（源盘新增的书只查一边会显示成『已删除的文档』）")
print("  —— 干跑报告 ——")
for l in MirrorReport.summary(plan, titles: allTitles) {
    print("  \(l.text)")
    for d in l.detail { print("      · \(d)") }
}
check(MirrorReport.headline(plan).contains("冲突 1"), "一行式结论带上冲突数：\(MirrorReport.headline(plan))")

print("⑥ 干跑真的一个字都没写")
let planAgain = try! MirrorStore.plan(mirror: mdb, source: store)
check(planAgain.changes.count == plan.changes.count, "连跑两次结论一致（干跑不改变任何状态）")
check(try! MirrorStore.syncBase(mdb)["note"]?.count == 4, "基线还是建镜像那一刻的 4 条，没被干跑动过")

mdb.close()
store.close()
print("\n通过 \(pass) / 失败 \(fail)")
exit(fail == 0 ? 0 : 1)
