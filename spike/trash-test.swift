// 回收站（`BACKUP-PLAN.md §2`）回归测试：归档 → 删除 → 恢复 的库回环，含
// 「那份 PDF 又被重新导入过 → 并入现有那篇」这条分支，以及图层级条目。运行：
//   cp spike/trash-test.swift /tmp/main.swift && \
//     swiftc Sources/Store/*.swift Sources/App/TrashModel.swift /tmp/main.swift -o /tmp/tt && /tmp/tt
// （须命名为 main.swift 编译：swiftc 多文件时顶层代码只允许在 main.swift）
//
// 这一套要守住的是**「删掉的东西真能一条不少地回来」**——它是这个功能存在的全部理由，
// 所以每一项都数具体的行数/内容，不看「没报错」。

import Foundation

setvbuf(stdout, nil, _IONBF, 0)   // 崩在中途时前面的输出也要看得见

var pass = 0, fail = 0
func check(_ cond: Bool, _ msg: String) {
    if cond { pass += 1; print("  ✅ \(msg)") } else { fail += 1; print("  ❌ \(msg)") }
}
func eq(_ a: Int, _ b: Int, _ msg: String) {
    if a == b { pass += 1; print("  ✅ \(msg)") }
    else { fail += 1; print("  ❌ \(msg)\n      得到: \(a)\n      期望: \(b)") }
}

let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("trash_test_\(UInt64.random(in: 0..<1_000_000))")
try? FileManager.default.removeItem(at: tmp)
try! FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: tmp) }

let store = try LibraryStore(workspaceFolder: tmp)

// MARK: - 造一篇有东西的文档

let layerA = UUID().uuidString.uppercased()
let layerB = UUID().uuidString.uppercased()

@discardableResult
func makeDoc(title: String, hash: String) -> LibDocument {
    let r = try! store.findOrCreate(hash: hash, title: title, pageCount: 10,
                                    path: "PDFs/\(hash).pdf", isRelative: false)
    return r.document
}

func addNote(_ docId: String, kind: Int, page: Int, payload: String) {
    let n = LibNote(id: UUID().uuidString, documentId: docId, kind: kind, page: page,
                    anchor: CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4),
                    payload: Data(payload.utf8), createdAt: .now, updatedAt: .now)
    try! store.upsertNote(n)
}

let doc = makeDoc(title: "高等数学", hash: "hash-A")
for i in 0..<6 { addNote(doc.id, kind: 2, page: i, payload: #"{"layerId":"\#(layerA)","color":"k"}"#) }
for i in 0..<4 { addNote(doc.id, kind: 2, page: i, payload: #"{"layerId":"\#(layerB)","color":"k"}"#) }
addNote(doc.id, kind: 2, page: 9, payload: #"{"color":"k"}"#)          // 老行：没有 layerId
addNote(doc.id, kind: 0, page: 1, payload: #"{"text":"第一条笔记"}"#)
addNote(doc.id, kind: 3, page: 2, payload: #"{"rects":[]}"#)
addNote(doc.id, kind: 5, page: 3, payload: #"{"title":"书签"}"#)
addNote(doc.id, kind: 6, page: 4, payload: #"{"image":"sha-of-a-picture"}"#)
addNote(doc.id, kind: 4, page: 0, payload: #"{"padId":"p1"}"#)
try! store.upsertInkLayer(LibInkLayer(id: layerA, documentId: doc.id, name: "图层 1",
                                      colorKey: "red", sortOrder: 0, visible: true, createdAt: .now))
try! store.upsertInkLayer(LibInkLayer(id: layerB, documentId: doc.id, name: "图层 2",
                                      colorKey: "blue", sortOrder: 1, visible: true, createdAt: .now))
try! store.upsertScratchPad(LibScratchPad(id: "p1", documentId: doc.id, title: "草稿",
                                          anchorPage: 0, anchorX: 0.5, anchorY: 0.5,
                                          bg: "rgba(255,255,255,1.0)", pattern: "dots", showPage: false,
                                          createdAt: .now, updatedAt: .now))

// 另一篇不相干的书：归档/删除/恢复都不许碰它
let other = makeDoc(title: "线性代数", hash: "hash-B")
addNote(other.id, kind: 2, page: 0, payload: #"{"layerId":"\#(layerA)"}"#)

func noteCount(_ docId: String) -> Int {
    (try! store.noteKindCounts(documentId: docId)).values.reduce(0, +)
}

print("\n— 0) 造出来的样子 —")
eq(noteCount(doc.id), 16, "《高等数学》共 16 条（11 笔迹 + 笔记/高亮/书签/图片/草稿纸笔迹各 1）")
eq(noteCount(other.id), 1, "《线性代数》1 条")

// MARK: - 1) 文档级：归档

let snap = tmp.appendingPathComponent("doc-snapshot.sqlite").path
print("\n— 1) 归档一篇文档 —")
let archived = try store.archiveDocument(id: doc.id, to: snap)
check(FileManager.default.fileExists(atPath: snap), "快照库落地了")
eq(archived.counts.ink, 11, "数出 11 笔页内笔迹")
eq(archived.counts.text, 1, "数出 1 条文字笔记")
eq(archived.counts.highlight, 1, "数出 1 处高亮")
eq(archived.counts.bookmark, 1, "数出 1 枚书签")
eq(archived.counts.image, 1, "数出 1 条图片笔记")
eq(archived.counts.scratchInk, 1, "数出 1 笔草稿纸笔迹")
eq(archived.counts.inkLayer, 2, "数出 2 个图层")
eq(archived.counts.scratchPad, 1, "数出 1 张草稿纸")
eq(archived.counts.total, 16, "总数与库里一致")
check(archived.images == ["sha-of-a-picture"], "图片本体的 sha 记进了 manifest（清理时要护住它）")
check(archived.contentHashes == ["hash-A"], "内容 hash 记进了 manifest（恢复时认「是不是重新导入过」）")
eq(archived.pageCount, 10, "页数带上了")

print("\n— 1b) 同名快照不许覆盖 —")
do {
    _ = try store.archiveDocument(id: doc.id, to: snap)
    check(false, "目标已存在时应当报错")
} catch {
    check(true, "目标已存在 → 报错（SQLite 的 VACUUM/ATTACH 行为，正好挡住误覆盖）")
}

// MARK: - 2) 删除

print("\n— 2) 删库行 —")
try store.deleteDocument(id: doc.id)
check(try store.document(id: doc.id) == nil, "文档行没了")
eq(noteCount(doc.id), 0, "笔记连带级联删干净")
eq(try store.inkLayers(documentId: doc.id).count, 0, "图层也没了")
eq(try store.scratchPads(documentId: doc.id).count, 0, "草稿纸也没了")
eq(noteCount(other.id), 1, "另一篇书一条都没少")

// MARK: - 3) 恢复（情形 A：那篇书还不在库里）

print("\n— 3) 恢复：整份放回去 —")
check(try store.trashMergeTarget(snapshot: snap) == nil, "没有别的文档占着这个 content_hash → 不需要并入")
let restored = try store.restoreTrash(snapshot: snap, remapDocumentId: nil)
check(restored > 0, "搬回来 \(restored) 行")
let back = try store.document(id: doc.id)
check(back != nil, "文档行回来了")
check(back?.title == "高等数学", "标题原样")
check(back?.id == doc.id, "**id 原样** —— unireader:// 链接和 MCP 里记的 document_id 仍然有效")
eq(noteCount(doc.id), 16, "16 条笔记一条不少")
eq(try store.inkLayers(documentId: doc.id).count, 2, "2 个图层回来了")
eq(try store.scratchPads(documentId: doc.id).count, 1, "草稿纸回来了")
check(try store.variant(hash: "hash-A")?.documentId == doc.id, "variant 回来了且挂对了文档")
eq(try store.locations(variantId: store.variant(hash: "hash-A")!.id).count, 1, "location 回来了")
eq(noteCount(other.id), 1, "另一篇书仍然只有 1 条（恢复没有溢出）")

print("\n— 3b) 重复恢复是幂等的 —")
_ = try store.restoreTrash(snapshot: snap, remapDocumentId: nil)
eq(noteCount(doc.id), 16, "再恢复一次还是 16 条，没有翻倍")
eq(try store.inkLayers(documentId: doc.id).count, 2, "图层也没有翻倍")

// MARK: - 4) 恢复（情形 B：那份 PDF 又被重新导入过）

print("\n— 4) 恢复：并入现有那篇 —")
try store.deleteDocument(id: doc.id)
// 用户重新把同一个 PDF 拖进来：content_hash 一样，但这是**一篇新的** document 行
let reimported = makeDoc(title: "高等数学（重新导入）", hash: "hash-A")
check(reimported.id != doc.id, "重新导入得到的是另一个 document id")
addNote(reimported.id, kind: 0, page: 0, payload: #"{"text":"重新导入之后新写的"}"#)

let target = try store.trashMergeTarget(snapshot: snap)
check(target == reimported.id, "探路认出要并入哪一篇")
_ = try store.restoreTrash(snapshot: snap, remapDocumentId: target)
check(try store.document(id: doc.id) == nil, "**没有**把老的 document 行放回来（否则 content_hash 撞车）")
check(try store.document(id: reimported.id)?.title == "高等数学（重新导入）", "现有那篇的标题保留，没被快照覆盖")
eq(noteCount(reimported.id), 17, "16 条旧笔记并进来 + 重新导入后新写的那 1 条")
eq(try store.inkLayers(documentId: reimported.id).count, 2, "图层跟着并进来了")
eq(try store.scratchPads(documentId: reimported.id).count, 1, "草稿纸跟着并进来了")
check(try store.variant(hash: "hash-A")?.documentId == reimported.id, "variant 仍属于重新导入的那篇")

// MARK: - 5) 图层级条目

print("\n— 5) 图层级：归档 → 删 → 恢复 —")
let layerSnap = tmp.appendingPathComponent("layer-snapshot.sqlite").path
let la = try store.archiveInkLayer(documentId: reimported.id, layerId: layerA,
                                   isDefaultLayer: false, to: layerSnap)
eq(la.counts.ink, 6, "图层 1 上 6 笔")
eq(la.counts.inkLayer, 1, "带上图层自己那一行")
let inkBefore = try store.inkCount(documentId: reimported.id)
let deleted = try store.deleteInkStrokes(documentId: reimported.id, layerId: layerA, isDefaultLayer: false)
eq(deleted, 6, "删掉 6 笔")
try store.deleteInkLayer(id: layerA)
eq(try store.inkCount(documentId: reimported.id), inkBefore - 6, "库里确实少了 6 笔")
_ = try store.restoreTrash(snapshot: layerSnap, remapDocumentId: nil)
eq(try store.inkCount(documentId: reimported.id), inkBefore, "6 笔回来了")
eq(try store.inkLayers(documentId: reimported.id).count, 2, "图层行也回来了")

print("\n— 5b) 默认图层：没有 layerId 的老行一并算进去 —")
do {
    let defSnap = tmp.appendingPathComponent("default-layer.sqlite").path
    // 用「那一条没有 layerId 的老行」所属的默认层做归档：判定要和 deleteInkStrokes 完全一致
    let ghost = UUID().uuidString.uppercased()
    let a = try store.archiveInkLayer(documentId: reimported.id, layerId: ghost,
                                      isDefaultLayer: true, to: defSnap)
    eq(a.counts.ink, 1, "默认层归档收走那条没有 layerId 的老行")
    let n = try store.deleteInkStrokes(documentId: reimported.id, layerId: ghost, isDefaultLayer: true)
    eq(n, 1, "删除的判定与归档一致（删掉的正是存下来的那一条）")
    _ = try store.restoreTrash(snapshot: defSnap, remapDocumentId: nil)
    eq(try store.inkCount(documentId: reimported.id), inkBefore, "老行也回得来")
}

// MARK: - 6) 条目文件层（Trash 模型）

print("\n— 6) 条目目录名与 manifest —")
do {
    let d = Date(timeIntervalSince1970: 1_790_000_000)
    let n1 = Trash.directoryName(at: d, title: "高等数学", existing: [])
    check(n1.hasSuffix("_高等数学"), "目录名带可读标题：\(n1)")
    let n2 = Trash.directoryName(at: d, title: "高等数学", existing: [n1])
    check(n2 == n1 + "-2", "撞名加后缀（侧栏多选删除会在同一秒里删好几篇）")
    check(Trash.sanitize("a/b:c") == "a-b-c", "路径分隔符换掉")
    check(Trash.sanitize("  .hidden ") == "hidden", "去首尾空白与前导点")
    check(Trash.sanitize(String(repeating: "长", count: 100)).count == 40, "压到 40 字以内")

    var m = Trash.Manifest()
    m.kind = .inkLayer
    m.title = "图层 1"
    m.counts = la.counts
    m.images = ["x"]
    let round = try Trash.decode(Trash.encode(m))
    check(try round == Trash.decode(Trash.encode(round)), "manifest 编解码回环一致（时间戳抹到整秒后稳定）")
    check(round.counts == m.counts && round.images == m.images && round.kind == m.kind
          && round.title == m.title, "字段一个不少地回来")
    check(abs(round.deletedAt.timeIntervalSince(m.deletedAt)) < 1, "时间戳只差不到一秒（写的是 ISO8601 整秒）")
}

print("\n— 7) 到期判定 —")
do {
    let now = Date()
    func entry(daysAgo: Double) -> Trash.Entry {
        var m = Trash.Manifest()
        m.deletedAt = now.addingTimeInterval(-daysAgo * 86_400)
        return Trash.Entry(id: "\(daysAgo)", url: tmp, manifest: m, bytes: 0)
    }
    let es = [entry(daysAgo: 1), entry(daysAgo: 29), entry(daysAgo: 31), entry(daysAgo: 100)]
    eq(Trash.expired(es, retention: .days30, now: now).count, 2, "30 天：31 天前与 100 天前的到期")
    eq(Trash.expired(es, retention: .days90, now: now).count, 1, "90 天：只有 100 天前的到期")
    eq(Trash.expired(es, retention: .forever, now: now).count, 0, "永不保留期：一条都不清")
}

print("\n\(fail == 0 ? "✅ 全部通过" : "❌ 有失败")：\(pass) 通过 / \(fail) 失败\n")
exit(fail == 0 ? 0 : 1)
