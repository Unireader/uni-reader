// 离线镜像 应用合并（`MirrorApply`）测试。方案 OFFLINE-MIRROR-PLAN.md §8.3。运行：
//   cp spike/mirror-apply-test.swift /tmp/main.swift && swiftc Sources/Store/*.swift /tmp/main.swift -o /tmp/mat && /tmp/mat
// （须命名为 main.swift：swiftc 多文件时顶层代码只允许在 main.swift）
//
// 这是唯一会大批量改用户数据的一段，所以重点验四件事：
//   ① 合并后两端**白名单表逐行一致**（这是"同步成功"的唯一硬定义）
//   ② 合并前必须有备份、且只留最近 3 份
//   ③ **半途而废能自愈**：只应用一侧，再跑一次 diff 只剩另一侧的活
//   ④ 外键孤儿（父文档被删、子行还要写）**不炸整次同步**，只丢那一行并报出来
import Foundation

var pass = 0, fail = 0
func check(_ c: Bool, _ m: String) { if c { pass += 1; print("  ✅ \(m)") } else { fail += 1; print("  ❌ \(m)") } }

let fm = FileManager.default
let root = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("mirror_apply_\(UInt64.random(in: 0..<1_000_000))")
try! fm.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: root) }

func resolver(_ ws: URL) -> (LibLocation) -> String? {
    { loc in (loc.inWorkspace || loc.isRelative) ? ws.appendingPathComponent(loc.path).path : loc.path }
}

/// 造一对「源工作区 + 它的镜像」。返回 (源目录, 源 store, 镜像目录, 镜像 store, 文档 id, 4 条笔迹 id)
func makePair(_ name: String, notes: Int = 4) -> (URL, LibraryStore, URL, LibraryStore, String, [String]) {
    let src = root.appendingPathComponent("\(name)-源.unrd")
    try! fm.createDirectory(at: src.appendingPathComponent("PDFs"), withIntermediateDirectories: true)
    let store = try! LibraryStore(workspaceFolder: src)
    try! store.setWorkspaceName(name)
    let rel = "PDFs/a.pdf"
    try! Data(repeating: 0x41, count: 512).write(to: src.appendingPathComponent(rel))
    let (doc, v) = try! store.findOrCreate(hash: "h-\(name)", title: "高等数学", pageCount: 100, path: rel)
    _ = try! store.addLocation(variantId: v.id, path: rel, inWorkspace: true)
    var ids: [String] = []
    for i in 0..<notes {
        let id = "\(name)-note-\(i)"
        ids.append(id)
        try! store.upsertNote(LibNote(id: id, documentId: doc.id, kind: 2, page: 86,
                                      anchor: CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4),
                                      payload: Data("{\"w\":\(i)}".utf8),
                                      createdAt: .now, updatedAt: ISO.date("2026-08-30T10:00:00.000Z")!))
    }
    let dst = root.appendingPathComponent("\(name)-镜像.unrd")
    _ = try! MirrorBuilder.create(source: src, store: store, destination: dst,
                                  plan: .init(documentsWithPDF: [doc.id]), resolve: resolver(src))
    let mirror = try! LibraryStore(workspaceFolder: dst)
    return (src, store, dst, mirror, doc.id, ids)
}

func planOf(_ mirror: LibraryStore, _ source: LibraryStore) -> MirrorDiff.Plan {
    MirrorDiff.compute(base: try! mirror.syncBase(),
                       mine: try! mirror.mirrorSnapshot(),
                       theirs: try! source.mirrorSnapshot(),
                       mineOCR: try! mirror.mirrorOCRKeys(),
                       theirsOCR: try! source.mirrorOCRKeys())
}

func ocrPage(_ hash: String, _ page: Int, _ text: String) -> OCRPage {
    OCRPage(contentHash: hash, page: page, provider: "paddle-http",
            payload: Data("{\"runs\":[{\"text\":\"\(text)\"}]}".utf8), lang: "ch", createdAt: .now)
}

/// 两端白名单表逐行一致 —— 「同步成功」的唯一硬定义
func identical(_ a: LibraryStore, _ b: LibraryStore) -> String? {
    let sa = try! a.mirrorSnapshot(), sb = try! b.mirrorSnapshot()
    for spec in MirrorFp.specs {
        let fa = MirrorFp.fingerprints(rows: Array((sa[spec.table] ?? [:]).values), spec: spec)
        let fb = MirrorFp.fingerprints(rows: Array((sb[spec.table] ?? [:]).values), spec: spec)
        if fa != fb {
            let only = Set(fa.keys).symmetricDifference(fb.keys)
            return "\(spec.table) 不一致（各自 \(fa.count)/\(fb.count) 行，只在一边的 \(only.count) 条）"
        }
    }
    return nil
}

// ============================================================
print("① 双向合并：合并后两端逐行一致")
// ============================================================
var (src, store, dst, mirror, docId, ids) = makePair("A")

// 镜像侧：改 n0、删 n2、加一条新的
let newId = "A-note-new"
try! mirror.upsertNote(LibNote(id: ids[0], documentId: docId, kind: 2, page: 86,
                               anchor: CGRect(x: 0.5, y: 0.5, width: 0.1, height: 0.1),
                               payload: Data("{\"w\":99}".utf8),
                               createdAt: .now, updatedAt: ISO.date("2026-09-01T10:00:00.000Z")!))
try! mirror.deleteNote(id: ids[2])
try! mirror.upsertNote(LibNote(id: newId, documentId: docId, kind: 2, page: 87,
                               anchor: CGRect(x: 0.2, y: 0.2, width: 0.1, height: 0.1),
                               payload: Data("{\"w\":7}".utf8),
                               createdAt: .now, updatedAt: ISO.date("2026-09-01T10:00:00.000Z")!))
// 源盘侧：改 n3；两端都改 n1（源盘较新）
try! store.upsertNote(LibNote(id: ids[3], documentId: docId, kind: 2, page: 86,
                              anchor: CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4),
                              payload: Data("{\"w\":33}".utf8),
                              createdAt: .now, updatedAt: ISO.date("2026-09-01T09:00:00.000Z")!))
try! store.upsertNote(LibNote(id: ids[1], documentId: docId, kind: 2, page: 86,
                              anchor: CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4),
                              payload: Data("{\"w\":11}".utf8),
                              createdAt: .now, updatedAt: ISO.date("2026-09-02T09:00:00.000Z")!))
try! mirror.upsertNote(LibNote(id: ids[1], documentId: docId, kind: 2, page: 86,
                               anchor: CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4),
                               payload: Data("{\"w\":12}".utf8),
                               createdAt: .now, updatedAt: ISO.date("2026-09-01T08:00:00.000Z")!))
// 只改「上次打开」：不该产生任何 change，但要被 max 合并
try! store.updateLastOpened(documentId: docId, at: ISO.date("2026-09-05T00:00:00.000Z")!)

var plan = planOf(mirror, store)
check(plan.changes.count == 5 && plan.conflicts.count == 1, "干跑：5 条改动 1 条冲突")
check(plan.lastOpenedMerges[docId] != nil, "「上次打开」进了 lastOpenedMerges 而不是 changes")

var steps: [String] = []
var res = try! MirrorApply.apply(plan: plan, mirrorFolder: dst, mirrorStore: mirror,
                                 sourceFolder: src, sourceStore: store,
                                 resolveMirror: resolver(dst), resolveSource: resolver(src),
                                 progress: { s, _ in if steps.last != s { steps.append(s) } })
check(res.sourceUpserts == 2 && res.sourceDeletes == 1, "写入硬盘：2 插 1 删")
check(res.mirrorUpserts == 2 && res.mirrorDeletes == 0, "拉回本机：2 插 0 删")
check(res.orphansSkipped == 0, "没有孤儿")
check(steps.first == "正在备份硬盘上的资料库…" && steps.last == "完成",
      "🔴 第一步就是备份（没有备份就动手 = 把最坏情况从回滚变成没得救）")

check(identical(mirror, store) == nil, "🔴 合并后两端白名单表逐行一致：\(identical(mirror, store) ?? "是")")
check(planOf(mirror, store).isEmpty, "🔴 再跑一次干跑：无事可做（基线已重置）")

// 逐条抽查内容真的对
let mn = try! mirror.notes(documentId: docId).reduce(into: [String: Data]()) { $0[$1.id] = $1.payload }
let sn = try! store.notes(documentId: docId).reduce(into: [String: Data]()) { $0[$1.id] = $1.payload }
check(mn[ids[2]] == nil && sn[ids[2]] == nil, "镜像删掉的那条，两端都没了")
check(String(decoding: sn[ids[0]] ?? Data(), as: UTF8.self) == "{\"w\":99}", "镜像改的那条写进了源盘")
check(sn[newId] != nil && mn[newId] != nil, "镜像新增的那条两端都有")
check(String(decoding: mn[ids[3]] ?? Data(), as: UTF8.self) == "{\"w\":33}", "源盘改的那条拉进了镜像")
check(String(decoding: mn[ids[1]] ?? Data(), as: UTF8.self) == "{\"w\":11}", "冲突那条：两端都是较新的源盘版本")
check(String(decoding: sn[ids[1]] ?? Data(), as: UTF8.self) == "{\"w\":11}", "…源盘侧也是")
let lo = try! store.document(id: docId)?.lastOpenedAt
check(lo == ISO.date("2026-09-05T00:00:00.000Z"), "「上次打开」取了较晚的那个")
check(try! mirror.document(id: docId)?.lastOpenedAt == lo, "…两端一致")

print("② 记账")
check(mirror.meta(MirrorStore.metaMirrorLastSyncedAt) != nil, "镜像记下了同步时间")
let co = MirrorStore.decodeCheckouts(store.meta(MirrorStore.metaCheckouts)).first
check(co?.lastSyncedAt != nil, "源盘的借出记录更新了 lastSyncedAt")

print("③ 备份")
let backupDir = src.appendingPathComponent("UniReader/backup")
check(res.backup != nil && fm.fileExists(atPath: res.backup!.path), "备份文件在：\(res.backup?.lastPathComponent ?? "-")")
// 备份是**合并前**的样子：那条被删的笔迹应当还在里面
let bdb = try! SQLiteDB(path: res.backup!.path)
let stillThere = try! bdb.query("SELECT id FROM note WHERE id=?", [.text(ids[2])])
check(stillThere.count == 1, "🔴 备份是合并**前**的样子（被删那条还在里面，救得回来）")
bdb.close()
// 只留最近 3 份
for _ in 0..<4 { _ = try! MirrorApply.backupSource(store, folder: src) }
let backups = (try! fm.contentsOfDirectory(atPath: backupDir.path)).filter { $0.hasSuffix(".sqlite") }
check(backups.count == 3, "只留最近 3 份（现 \(backups.count) 份）")

// ============================================================
print("④ 半途而废能自愈（只应用一侧，再跑一次只剩另一侧的活）")
// ============================================================
let (src2, store2, dst2, mirror2, doc2, ids2) = makePair("B")
try! mirror2.upsertNote(LibNote(id: ids2[0], documentId: doc2, kind: 2, page: 1,
                                anchor: .zero, payload: Data("{\"w\":98}".utf8),
                                createdAt: .now, updatedAt: ISO.date("2026-09-01T10:00:00.000Z")!))
try! store2.upsertNote(LibNote(id: ids2[1], documentId: doc2, kind: 2, page: 1,
                               anchor: .zero, payload: Data("{\"w\":97}".utf8),
                               createdAt: .now, updatedAt: ISO.date("2026-09-01T10:00:00.000Z")!))
let plan2 = planOf(mirror2, store2)
check(plan2.changes.count == 2, "两侧各一条改动")

// 只把源盘那一侧写下去（模拟「写完源盘就被拔盘/崩了」，基线**没有**重算）
var half = MirrorApply.Result()
try! store2.withMirrorDB { db in
    try db.transaction { try MirrorApply.write(db, plan2.changes(to: .source), result: &half, side: .source) }
}
let after = planOf(mirror2, store2)
check(after.changes.count == 1 && after.changes[0].side == .mirror,
      "🔴 再跑一次只剩镜像那一侧的活（已落到源盘的那条被判成『两端改成一样了』→ 无操作）")
check(after.changes[0].rowId == ids2[1], "剩下的正是源盘那条改动")
// 补完剩下的，仍然收敛
_ = try! MirrorApply.apply(plan: after, mirrorFolder: dst2, mirrorStore: mirror2,
                           sourceFolder: src2, sourceStore: store2,
                           resolveMirror: resolver(dst2), resolveSource: resolver(src2))
check(identical(mirror2, store2) == nil, "🔴 补完之后两端仍然逐行一致（半途而废不需要补偿逻辑）")

// ============================================================
print("⑤ 外键孤儿：父文档被删，子行不炸整次同步")
// ============================================================
let (src3, store3, dst3, mirror3, doc3, ids3) = makePair("C")
// 源盘上把整本书删了；镜像上同时给它写了新笔迹
try! store3.deleteDocument(id: doc3)
try! mirror3.upsertNote(LibNote(id: "C-orphan", documentId: doc3, kind: 2, page: 1,
                                anchor: .zero, payload: Data("{\"w\":1}".utf8),
                                createdAt: .now, updatedAt: ISO.date("2026-09-01T10:00:00.000Z")!))
let plan3 = planOf(mirror3, store3)
check(plan3.changes.contains { $0.rowId == "C-orphan" && $0.side == .source },
      "干跑里确实有一条「把新笔迹推给源盘」")
let res3 = try! MirrorApply.apply(plan: plan3, mirrorFolder: dst3, mirrorStore: mirror3,
                                  sourceFolder: src3, sourceStore: store3,
                                  resolveMirror: resolver(dst3), resolveSource: resolver(src3))
check(res3.orphansSkipped >= 1,
      "🔴 父文档已不在 → 丢掉那行并计数（\(res3.orphansSkipped) 条），而不是让外键把整次同步炸掉")
check(identical(mirror3, store3) == nil, "孤儿丢掉之后两端仍然一致：\(identical(mirror3, store3) ?? "是")")

// ============================================================
print("⑥ 文件补齐：镜像上新加的书，PDF 拷回源盘")
// ============================================================
let (src4, store4, dst4, mirror4, _, _) = makePair("D")
// 在镜像里加一本源盘没有的书（拷进镜像的 PDFs/）
let relNew = "PDFs/new.pdf"
try! Data(repeating: 0x42, count: 777).write(to: dst4.appendingPathComponent(relNew))
let (docNew, varNew) = try! mirror4.findOrCreate(hash: "h-new", title: "新加的书", pageCount: 5, path: relNew)
_ = try! mirror4.addLocation(variantId: varNew.id, path: relNew, inWorkspace: true)
let plan4 = planOf(mirror4, store4)
check(plan4.changes.contains { $0.table == "document" && $0.rowId == docNew.id }, "新书的 document 行要推给源盘")
let res4 = try! MirrorApply.apply(plan: plan4, mirrorFolder: dst4, mirrorStore: mirror4,
                                  sourceFolder: src4, sourceStore: store4,
                                  resolveMirror: resolver(dst4), resolveSource: resolver(src4))
check(res4.filesCopiedToSource == 1, "拷了 1 个文件回源盘（\(res4.filesCopiedToSource)）")
let srcLocs = try! store4.locations(documentId: docNew.id)
check(srcLocs.contains { $0.inWorkspace && fm.fileExists(atPath: src4.appendingPathComponent($0.path).path) },
      "源盘上那本新书能解析到真实文件")
check(identical(mirror4, store4) == nil, "…且两端仍然一致")
// 幂等：再补一次不该多拷
let again = try! MirrorApply.fillFilesToSource(mirrorFolder: dst4, mirrorStore: mirror4,
                                               sourceFolder: src4, sourceStore: store4,
                                               resolveMirror: resolver(dst4), resolveSource: resolver(src4))
check(again == 0, "🔴 补齐是幂等的：再跑一次一个文件都不拷")

print("⑤ 备份撞名：连着备份两次不许中止整次合并")
// 时间戳只到毫秒，库小的时候两次备份就落在同一毫秒里 —— 这条以前是**随机挂**的：
// `VACUUM INTO` 遇到已存在的文件直接报 "output file already exists"，整次同步当场中止。
// 这里连做三次、不留间隔，把「撞名要自己绕开」钉死。
var madeBackups: [URL] = []
for _ in 0..<3 {
    guard let b = try? MirrorApply.backupSource(store4, folder: src4) else {
        check(false, "🔴 备份撞名把整次合并搞挂了")
        break
    }
    madeBackups.append(b)
}
check(madeBackups.count == 3, "连着备份 3 次都成功（\(madeBackups.count)）")
check(Set(madeBackups.map(\.lastPathComponent)).count == madeBackups.count, "三份备份各自一个文件名")
check(madeBackups.allSatisfy { fm.fileExists(atPath: $0.path) }, "三份都真的落盘了")
// keep=3：目录里恰好留最近 3 份，且字典序仍是时间序（序号排在时间戳之后）
let kept = ((try? fm.contentsOfDirectory(atPath: src4.appendingPathComponent("UniReader/backup").path)) ?? [])
    .filter { $0.hasPrefix("library-") }.sorted()
check(kept.count == 3, "只留最近 3 份（\(kept.count)）")

// ============================================================
print("⑦ OCR 缓存双向补齐（方案 §4：纯 additive，只补不删不覆盖）")
// ============================================================
let (src5, store5, dst5, mirror5, doc5, _) = makePair("E")
let hash5 = try! store5.variants(documentId: doc5)[0].contentHash
// 建镜像那一刻就有的一页（VACUUM INTO 已经带过去了）：两边都有 → 不该出现在计划里
try! store5.upsertOCRPage(ocrPage(hash5, 0, "建镜像前就识别过的第 1 页"))
_ = try! MirrorApply.fillOCR(from: store5, to: mirror5, keys: [.init(contentHash: hash5, page: 0, provider: "paddle-http")])
// 离线期间：镜像上识别了 1、2 页；源盘上识别了 3 页
try! mirror5.upsertOCRPage(ocrPage(hash5, 1, "在副本上识别的"))
try! mirror5.upsertOCRPage(ocrPage(hash5, 2, "在副本上识别的"))
try! store5.upsertOCRPage(ocrPage(hash5, 3, "在硬盘上识别的"))

let plan5 = planOf(mirror5, store5)
check(plan5.ocrToSource.count == 2 && plan5.ocrToMirror.count == 1,
      "干跑算出「写入硬盘 2 页 / 拉回本机 1 页」（\(plan5.ocrToSource.count)/\(plan5.ocrToMirror.count)）")
check(plan5.changes.isEmpty, "🔴 OCR 缓存不走 Change 那条通道（它不进指纹、不进基线）")
check(!plan5.isEmpty, "只差 OCR 也算「有东西要同步」——否则界面会说「两端一致」然后什么都不干")
check(MirrorReport.headline(plan5).contains("识别结果 3 页"), "一行式结论说得出来：\(MirrorReport.headline(plan5))")
let ocrLines = MirrorReport.summary(plan5, titles: [doc5: "高等数学"], hashTitles: [hash5: "高等数学"])
check(ocrLines.contains { $0.text.contains("补齐文字识别结果") && $0.detail.contains { $0.contains("《高等数学》") } },
      "报告按书说人话：\(ocrLines.map(\.detail).flatMap { $0 })")

let res5 = try! MirrorApply.apply(plan: plan5, mirrorFolder: dst5, mirrorStore: mirror5,
                                  sourceFolder: src5, sourceStore: store5,
                                  resolveMirror: resolver(dst5), resolveSource: resolver(src5))
check(res5.ocrFilledToSource == 2 && res5.ocrFilledToMirror == 1,
      "真补了 2/1 页（\(res5.ocrFilledToSource)/\(res5.ocrFilledToMirror)）")
check(try! mirror5.mirrorOCRKeys() == store5.mirrorOCRKeys(), "🔴 合并后两端的 OCR 缓存键集合完全一致")
check(try! store5.ocrPageCount(contentHash: hash5, provider: "paddle-http") == 4,
      "源盘上这本书 4 页都有了 —— 「书本开启 OCR」是靠这个数 >0 推出来的")
check(planOf(mirror5, store5).ocrToSource.isEmpty && planOf(mirror5, store5).ocrToMirror.isEmpty,
      "再跑一次干跑没有剩活（收敛）")

// 内容真的搬过去了，而不是只搬了个键
let pulled = try! mirror5.ocrPage(contentHash: hash5, page: 3, provider: "paddle-http")
check(String(decoding: pulled?.payload ?? Data(), as: UTF8.self).contains("在硬盘上识别的"), "拉回来的是 payload 本身")

// **不覆盖**：两边同一页各自识别过（内容不同）→ 一个字都不许动
try! store5.upsertOCRPage(ocrPage(hash5, 9, "硬盘版"))
try! mirror5.upsertOCRPage(ocrPage(hash5, 9, "副本版"))
let plan5b = planOf(mirror5, store5)
check(plan5b.ocrToSource.isEmpty && plan5b.ocrToMirror.isEmpty, "同一个键两边都有 → 不产生任何补齐动作")
_ = try! MirrorApply.fillOCR(from: mirror5, to: store5, keys: [.init(contentHash: hash5, page: 9, provider: "paddle-http")])
let kept9 = try! store5.ocrPage(contentHash: hash5, page: 9, provider: "paddle-http")
check(String(decoding: kept9?.payload ?? Data(), as: UTF8.self).contains("硬盘版"),
      "🔴 `INSERT OR IGNORE`：硬写一次也覆盖不掉对面已有的那份")

// **删除不传播**（这是刻意的取舍：缓存删了就该由另一边补回来，重跑一次要真花 API 的钱）
try! mirror5.deleteOCRPages(contentHash: hash5)
let plan5c = planOf(mirror5, store5)
check(plan5c.ocrToSource.isEmpty && plan5c.ocrToMirror.count == 5,
      "副本上清空缓存 → 不是「让源盘也删」，而是「从源盘补回来 5 页」（\(plan5c.ocrToMirror.count)）")

for s in [store, mirror, store2, mirror2, store3, mirror3, store4, mirror4, store5, mirror5] { s.close() }
print("\n通过 \(pass) / 失败 \(fail)")
exit(fail == 0 ? 0 : 1)
