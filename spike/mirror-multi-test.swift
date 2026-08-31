// 离线镜像 **多镜像**（M6）测试：一个源盘 + 两份镜像 A/B 轮流同步。运行：
//   cp spike/mirror-multi-test.swift /tmp/main.swift && swiftc Sources/Store/*.swift /tmp/main.swift -o /tmp/mmt && /tmp/mmt
//
// 方案 §8.4 说"多镜像天然可用"——每份镜像有自己的基线、UUID 不重用。**这份用例是来验它的，
// 不是来复述它的**：真要成立，下面每一条都得过。
//   ① 二手传播：A 改的东西，B 同步时能拿到
//   ② **删除的二手传播**（最容易漏）：A 删的东西，B 同步时也要跟着删
//   ③ 跨镜像冲突：A、B 各改同一行，先后同步 → LWW 仍然对
//   ④ 借出记录两条各自记账，互不覆盖
//   ⑤ 同一份 PDF 在两份镜像上各自入库一次 → `variant.content_hash` 的 UNIQUE
import Foundation

var pass = 0, fail = 0
func check(_ c: Bool, _ m: String) { if c { pass += 1; print("  ✅ \(m)") } else { fail += 1; print("  ❌ \(m)") } }

let fm = FileManager.default
let root = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("mirror_multi_\(UInt64.random(in: 0..<1_000_000))")
try! fm.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: root) }

func resolver(_ ws: URL) -> (LibLocation) -> String? {
    { loc in (loc.inWorkspace || loc.isRelative) ? ws.appendingPathComponent(loc.path).path : loc.path }
}

// —— 源盘 ——
let src = root.appendingPathComponent("源.unrd")
try! fm.createDirectory(at: src.appendingPathComponent("PDFs"), withIntermediateDirectories: true)
let S = try! LibraryStore(workspaceFolder: src)
try! S.setWorkspaceName("源")
let relA = "PDFs/a.pdf"
try! Data(repeating: 0x41, count: 512).write(to: src.appendingPathComponent(relA))
let (doc, v0) = try! S.findOrCreate(hash: "h0", title: "高等数学", pageCount: 100, path: relA)
_ = try! S.addLocation(variantId: v0.id, path: relA, inWorkspace: true)

func mkNote(_ id: String, _ w: Int, _ ts: String) -> LibNote {
    LibNote(id: id, documentId: doc.id, kind: 2, page: 86,
            anchor: CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4),
            payload: Data("{\"w\":\(w)}".utf8),
            createdAt: .now, updatedAt: ISO.date(ts)!)
}
let ids = (0..<4).map { "n\($0)" }
for (i, id) in ids.enumerated() { try! S.upsertNote(mkNote(id, i, "2026-08-30T10:00:00.000Z")) }

// —— 两份镜像（同一时刻各建一份）——
let dirA = root.appendingPathComponent("A.unrd")
let dirB = root.appendingPathComponent("B.unrd")
let resA = try! MirrorBuilder.create(source: src, store: S, destination: dirA,
                                     plan: .init(documentsWithPDF: [doc.id]), resolve: resolver(src))
let resB = try! MirrorBuilder.create(source: src, store: S, destination: dirB,
                                     plan: .init(documentsWithPDF: [doc.id]), resolve: resolver(src))
let A = try! LibraryStore(workspaceFolder: dirA)
let B = try! LibraryStore(workspaceFolder: dirB)

func planFor(_ m: LibraryStore) -> MirrorDiff.Plan {
    MirrorDiff.compute(base: try! m.syncBase(), mine: try! m.mirrorSnapshot(), theirs: try! S.mirrorSnapshot())
}
@discardableResult
func sync(_ m: LibraryStore, _ dir: URL) -> MirrorApply.Result {
    try! MirrorApply.apply(plan: planFor(m), mirrorFolder: dir, mirrorStore: m,
                           sourceFolder: src, sourceStore: S,
                           resolveMirror: resolver(dir), resolveSource: resolver(src))
}
func identical(_ a: LibraryStore, _ b: LibraryStore) -> String? {
    let sa = try! a.mirrorSnapshot(), sb = try! b.mirrorSnapshot()
    for spec in MirrorFp.specs {
        let fa = MirrorFp.fingerprints(rows: Array((sa[spec.table] ?? [:]).values), spec: spec)
        let fb = MirrorFp.fingerprints(rows: Array((sb[spec.table] ?? [:]).values), spec: spec)
        if fa != fb { return "\(spec.table)（各自 \(fa.count)/\(fb.count) 行）" }
    }
    return nil
}
func payloads(_ st: LibraryStore) -> [String: String] {
    (try! st.notes(documentId: doc.id)).reduce(into: [:]) { $0[$1.id] = String(decoding: $1.payload, as: UTF8.self) }
}

print("① 建好两份：两条借出记录，互不覆盖")
let cos = MirrorStore.decodeCheckouts(S.meta(MirrorStore.metaCheckouts))
check(cos.count == 2, "源库记了 2 条借出（\(cos.count)）")
check(Set(cos.map(\.mirrorId)) == Set([resA.mirrorId, resB.mirrorId]), "两条各自对上自己的 mirrorId")
check(planFor(A).isEmpty && planFor(B).isEmpty, "刚建好，两份的干跑都是空")

print("② 二手传播：A 改的、加的、删的，B 同步时都要拿到")
try! A.upsertNote(mkNote(ids[0], 99, "2026-09-01T10:00:00.000Z"))   // 改
try! A.deleteNote(id: ids[2])                                       // 删 ← 最容易漏的那条
try! A.upsertNote(mkNote("newA", 7, "2026-09-01T10:00:00.000Z"))    // 加
sync(A, dirA)
check(identical(A, S) == nil, "A 同步完与源盘一致")

let planB = planFor(B)
check(planB.changes.allSatisfy { $0.side == .mirror }, "B 的活全是「拉回本机」（B 自己没动过）")
check(planB.changes.contains { $0.rowId == ids[2] && $0.op == .delete },
      "🔴 **删除的二手传播**：A 删的那条，B 也要跟着删")
sync(B, dirB)
check(identical(B, S) == nil, "B 同步完与源盘一致：\(identical(B, S) ?? "是")")
let pb = payloads(B)
check(pb[ids[0]] == "{\"w\":99}", "A 改的那条传到了 B")
check(pb["newA"] != nil, "A 加的那条传到了 B")
check(pb[ids[2]] == nil, "🔴 A 删的那条在 B 上也没了（二手传播）")
check(identical(A, B) == nil, "此刻 A、B、源盘三者一致")

print("③ 反向再来一轮：B 改的东西回到 A")
try! B.upsertNote(mkNote("newB", 5, "2026-09-02T10:00:00.000Z"))
try! B.upsertNote(mkNote(ids[3], 33, "2026-09-02T10:00:00.000Z"))
sync(B, dirB)
sync(A, dirA)
let pa = payloads(A)
check(pa["newB"] != nil && pa[ids[3]] == "{\"w\":33}", "B 的改动经源盘回到了 A")
check(identical(A, S) == nil && identical(B, S) == nil, "三者再次一致")

print("④ 跨镜像冲突：A、B 各改同一行，先后同步")
try! A.upsertNote(mkNote(ids[1], 111, "2026-09-03T08:00:00.000Z"))   // 较旧
try! B.upsertNote(mkNote(ids[1], 222, "2026-09-03T20:00:00.000Z"))   // 较新
sync(A, dirA)                                                        // A 先同步：源盘拿到 111
check(payloads(S)[ids[1]] == "{\"w\":111}", "A 先同步 → 源盘是 A 那份")
let planB2 = planFor(B)
check(planB2.conflicts.count == 1 && planB2.conflicts[0].kind == .bothModified,
      "B 再同步时判成「两端都改」——B 的基线还是老的，源盘那份对它就是「变过了」")
check(planB2.conflicts[0].kept == .mirror, "B 那份 09-03T20 更新 → 保留 B")
sync(B, dirB)
check(payloads(S)[ids[1]] == "{\"w\":222}", "🔴 跨镜像冲突按时间戳收敛到较新的那份")
check(identical(B, S) == nil, "B 与源盘一致")
sync(A, dirA)
check(payloads(A)[ids[1]] == "{\"w\":222}", "A 再同步一次也收敛到同一份")
check(identical(A, B) == nil, "三者最终一致")

print("⑤ 借出记录：两条各自记 lastSyncedAt")
let cos2 = MirrorStore.decodeCheckouts(S.meta(MirrorStore.metaCheckouts))
check(cos2.count == 2, "还是 2 条（没有互相覆盖）")
check(cos2.allSatisfy { $0.lastSyncedAt != nil }, "两条都记下了各自的同步时间")

print("⑥ 同一份 PDF 在两份镜像上各自入库一次（content_hash 是 UNIQUE）")
// 用户在 A 和 B 上分别把同一个文件加进来：内容 hash 相同、variant id 不同
for (m, dir, tag) in [(A, dirA, "A"), (B, dirB, "B")] {
    let rel = "PDFs/same-\(tag).pdf"
    try! Data(repeating: 0x5A, count: 321).write(to: dir.appendingPathComponent(rel))
    let (d, v) = try! m.findOrCreate(hash: "same-hash", title: "两边都加的书", pageCount: 3, path: rel)
    _ = try! m.addLocation(variantId: v.id, path: rel, inWorkspace: true)
    _ = d
}
sync(A, dirA)
check(identical(A, S) == nil, "A 先同步：新书进了源盘")
// B 那本的 variant id 与源盘上 A 那本**不同、hash 相同** —— 硬插就是 UNIQUE 失败、整次同步炸掉
let planB3 = planFor(B)
let r3 = try! MirrorApply.apply(plan: planB3, mirrorFolder: dirB, mirrorStore: B,
                                sourceFolder: src, sourceStore: S,
                                resolveMirror: resolver(dirB), resolveSource: resolver(src))
check(r3.hashClashesSkipped >= 1,
      "🔴 撞 content_hash 的 variant 被跳过并计数（\(r3.hashClashesSkipped) 条），"
      + "而不是让 UNIQUE 把整次同步炸掉")
let grouped = try! S.withMirrorDB {
    try $0.query("SELECT content_hash, COUNT(*) AS n FROM variant GROUP BY content_hash")
}
check(grouped.allSatisfy { (($0["n"] as? Int64) ?? 0) == 1 }, "源盘上每个 content_hash 仍然只有一行")
check(try! S.variants(documentId: doc.id).count == 1, "原来那本书的版本数没被搅乱")
// ⚠️ 这条**刻意**不收敛：下次干跑还会把它算成待写。「这两本是不是同一本书」是用户的语义判断，
//    书库里有现成的「关联为同一文档」，同步这一步不该替他决定。断言它**仍然待写**，
//    是为了把这个已知取舍钉死 —— 哪天有人"顺手修好"它，得先来改这条用例。
check(planFor(B).changes.contains { $0.table == "variant" },
      "已知取舍：重复内容那条仍然待写，不自动合并（书库里用「关联为同一文档」处理）")

for s in [A, B, S] { s.close() }
print("\n通过 \(pass) / 失败 \(fail)")
exit(fail == 0 ? 0 : 1)
