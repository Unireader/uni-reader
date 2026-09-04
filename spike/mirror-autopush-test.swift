// 源 → 副本**自动静默推送**的门槛（用户 2026-09-01 拍板：源→副本自动，副本→源人工确认）。运行：
//   cp spike/mirror-autopush-test.swift /tmp/main.swift && swiftc Sources/Store/*.swift /tmp/main.swift -o /tmp/apt && /tmp/apt
//
// 用户要的完整流程：
//   拔盘 → 用副本、改副本 → 插回来 → **副本→源盘合一次（要确认）** → 从此两边一致
//   → 之后在源盘上改 → 每次都是「纯粹推给副本、零冲突」→ **静默推过去** → 再拔盘 → 又是副本
//
// 🔴 本用例的重点不是"能推过去"，是**门槛为什么必须是「整份 plan 都是推给副本」**：
//    `MirrorApply` 收尾会 `rebuildSyncBase()`，而基线是按**副本当前状态**重算的。
//    只应用一半就重算 = 把没应用那半的证据抹掉。④ 段把这条演出来。
import Foundation

var pass = 0, fail = 0
func check(_ c: Bool, _ m: String) { if c { pass += 1; print("  ✅ \(m)") } else { fail += 1; print("  ❌ \(m)") } }

let fm = FileManager.default
let root = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("mirror_autopush_\(UInt64.random(in: 0..<1_000_000))")
try! fm.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: root) }

func resolver(_ ws: URL) -> (LibLocation) -> String? {
    { loc in (loc.inWorkspace || loc.isRelative) ? ws.appendingPathComponent(loc.path).path : loc.path }
}

let src = root.appendingPathComponent("源.unrd")
try! fm.createDirectory(at: src.appendingPathComponent("PDFs"), withIntermediateDirectories: true)
let S = try! LibraryStore(workspaceFolder: src)
try! S.setWorkspaceName("源")
let rel = "PDFs/a.pdf"
try! Data(repeating: 0x41, count: 512).write(to: src.appendingPathComponent(rel))
let (doc, v0) = try! S.findOrCreate(hash: "h0", title: "高等数学", pageCount: 100, path: rel)
_ = try! S.addLocation(variantId: v0.id, path: rel, inWorkspace: true)

func mkNote(_ id: String, _ w: Int, _ ts: String) -> LibNote {
    LibNote(id: id, documentId: doc.id, kind: 2, page: 86,
            anchor: CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4),
            payload: Data("{\"w\":\(w)}".utf8),
            createdAt: .now, updatedAt: ISO.date(ts)!)
}
try! S.upsertNote(mkNote("base1", 1, "2026-08-30T10:00:00.000Z"))

let dst = root.appendingPathComponent("副本.unrd")
_ = try! MirrorBuilder.create(source: src, store: S, destination: dst,
                              plan: .init(documentsWithPDF: [doc.id]), resolve: resolver(src))
let M = try! LibraryStore(workspaceFolder: dst)

/// 干跑：base/mine 永远取**副本**那一侧（角色对调也不变，见 `mirrorDryRunFromSource`）
func planNow() -> MirrorDiff.Plan {
    MirrorDiff.compute(base: try! M.syncBase(), mine: try! M.mirrorSnapshot(), theirs: try! S.mirrorSnapshot(),
                       mineOCR: try! M.mirrorOCRKeys(), theirsOCR: try! S.mirrorOCRKeys())
}
@discardableResult
func applyNow(_ p: MirrorDiff.Plan) -> MirrorApply.Result {
    try! MirrorApply.apply(plan: p, mirrorFolder: dst, mirrorStore: M,
                           sourceFolder: src, sourceStore: S,
                           resolveMirror: resolver(dst), resolveSource: resolver(src))
}
func identical() -> String? {
    let a = try! M.mirrorSnapshot(), b = try! S.mirrorSnapshot()
    for spec in MirrorFp.specs {
        let fa = MirrorFp.fingerprints(rows: Array((a[spec.table] ?? [:]).values), spec: spec)
        let fb = MirrorFp.fingerprints(rows: Array((b[spec.table] ?? [:]).values), spec: spec)
        if fa != fb { return "\(spec.table)（各自 \(fa.count)/\(fb.count) 行）" }
    }
    return nil
}
func noteIds(_ st: LibraryStore) -> Set<String> {
    Set((try! st.notes(documentId: doc.id)).map(\.id))
}

print("① 刚建好：没什么可推的")
check(!planNow().isCleanPushToMirror, "空 plan 不算「可自动推送」（否则每次开窗口都白跑一趟合并）")

print("② 稳态：只有源盘动了 → 放行，静默推过去")
try! S.upsertNote(mkNote("s1", 7, "2026-09-01T09:00:00.000Z"))
try! S.upsertNote(mkNote("s2", 8, "2026-09-01T09:01:00.000Z"))
var p = planNow()
check(p.isCleanPushToMirror, "全是「推给副本」且零冲突 → 放行")
check(p.pendingToSource == 0, "没有要人工确认的（\(p.pendingToSource)）")
applyNow(p)
check(identical() == nil, "推完两端一致：\(identical() ?? "是")")
check(noteIds(M).contains("s1") && noteIds(M).contains("s2"), "源盘新加的两条到了副本")

print("②.5 只差 OCR 缓存 → 照样放行（两个方向都放）")
// OCR 缓存**刻意不参与**这道门槛：它是 `INSERT OR IGNORE` 的派生缓存，不覆盖也不删除任何东西，
// 更不进 `sync_base` —— ④ 段那条「半份应用会抹掉基线证据」的危险对它根本不成立。
// 挡住它的唯一效果是让「算过一次的页还要再花一次 API 的钱」。
func mkOCR(_ page: Int, _ text: String) -> OCRPage {
    OCRPage(contentHash: "h0", page: page, provider: "paddle-http",
            payload: Data("{\"t\":\"\(text)\"}".utf8), lang: "ch", createdAt: .now)
}
try! S.upsertOCRPage(mkOCR(1, "硬盘上识别的"))
try! M.upsertOCRPage(mkOCR(2, "副本上识别的"))
p = planNow()
check(p.changes.isEmpty, "没有任何行级改动，只差 OCR 缓存")
check(p.ocrToSource.count == 1 && p.ocrToMirror.count == 1, "两个方向各差一页")
check(p.isCleanPushToMirror, "🔴 只差 OCR 也放行 —— 它只增不改不删，没有可被静默抹掉的东西")
check(p.pendingToSource == 0,
      "OCR 不计进「要人工确认」的条数（\(p.pendingToSource)）—— 它不是用户产出，是可重算的缓存")
applyNow(p)
check(try! M.mirrorOCRKeys() == S.mirrorOCRKeys(), "推完两端 OCR 缓存一致")

print("③ 副本上有自己的改动 → 一律停手，交给人工")
try! M.upsertNote(mkNote("m1", 99, "2026-09-01T10:00:00.000Z"))   // 副本自己加的，待推回源盘
try! S.upsertNote(mkNote("s3", 9, "2026-09-01T10:01:00.000Z"))    // 同时源盘也加了一条
p = planNow()
check(!p.isCleanPushToMirror, "🔴 副本有自己的改动 → **不自动动手**（哪怕另一半是干净的推送）")
check(p.pendingToSource == 1, "报给用户「有 1 项要同步回源盘」（\(p.pendingToSource)）")

print("④ 门槛为什么不能放宽：只应用一半 + 重算基线 = 静默删数据")
// 这里**故意**做那件不该做的事：把 plan 里「推给副本」的那半挑出来单独应用。
// `MirrorApply` 收尾会按副本当前状态重算基线，于是副本上那条待推回源盘的 m1
// 就被写进了基线 —— 下一轮 diff：base 有、mine 有、theirs 没有 → 判成「源盘删了它」。
var half = p
half.changes = p.changes.filter { $0.side == .mirror }
half.conflicts = []
applyNow(half)
check(noteIds(M).contains("m1"), "半份应用之后 m1 还在副本上（还没出事）")
let after = planNow()
let willDeleteM1 = after.changes.contains { $0.rowId == "m1" && $0.op == .delete && $0.side == .mirror }
check(willDeleteM1,
      "🔴 **就是这个**：下一轮把 m1 判成「源盘删了」，要从副本上删掉 —— 用户在离线时写的东西"
      + "会被静默抹掉。所以 `isCleanPushToMirror` 要求整份 plan 干净，不是保守，是必需")
check(after.isCleanPushToMirror,
      "🔴 更要命的是：这一轮**看起来完全像一次干净的推送**（全是 .mirror 侧、零冲突），"
      + "门槛根本认不出基线已经被搞坏了 —— 所以真正的保护是「绝不半份应用」，"
      + "`isCleanPushToMirror` 只是不让我们走进这个状态，救不回已经走进去的")

print("⑤ 冲突在场 → 也停手")
// 重来一份干净的两端（④ 把状态搅乱了，这里另起一对）
let src2 = root.appendingPathComponent("源2.unrd")
try! fm.createDirectory(at: src2.appendingPathComponent("PDFs"), withIntermediateDirectories: true)
let S2 = try! LibraryStore(workspaceFolder: src2)
try! Data(repeating: 0x42, count: 256).write(to: src2.appendingPathComponent(rel))
let (doc2, v2) = try! S2.findOrCreate(hash: "h2", title: "线性代数", pageCount: 50, path: rel)
_ = try! S2.addLocation(variantId: v2.id, path: rel, inWorkspace: true)
func mkNote2(_ id: String, _ w: Int, _ ts: String) -> LibNote {
    LibNote(id: id, documentId: doc2.id, kind: 2, page: 3,
            anchor: CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4),
            payload: Data("{\"w\":\(w)}".utf8), createdAt: .now, updatedAt: ISO.date(ts)!)
}
try! S2.upsertNote(mkNote2("c1", 1, "2026-08-30T10:00:00.000Z"))
let dst2 = root.appendingPathComponent("副本2.unrd")
_ = try! MirrorBuilder.create(source: src2, store: S2, destination: dst2,
                              plan: .init(documentsWithPDF: [doc2.id]), resolve: resolver(src2))
let M2 = try! LibraryStore(workspaceFolder: dst2)
try! M2.upsertNote(mkNote2("c1", 5, "2026-09-01T08:00:00.000Z"))   // 两端改同一条
try! S2.upsertNote(mkNote2("c1", 6, "2026-09-01T09:00:00.000Z"))
let p2 = MirrorDiff.compute(base: try! M2.syncBase(), mine: try! M2.mirrorSnapshot(),
                            theirs: try! S2.mirrorSnapshot())
check(!p2.conflicts.isEmpty, "两端改同一条 → 有冲突")
check(!p2.isCleanPushToMirror, "🔴 有冲突就不自动动手 —— 冲突的裁决结果必须让用户看见")

for s in [S, M, S2, M2] { s.close() }
print("\n通过 \(pass) / 失败 \(fail)")
exit(fail == 0 ? 0 : 1)
