// 自建目录（note kind=7）与回顾点（note kind=8）回归测试（`TOC-REVIEW-PLAN.md`）：目录树还原、排序、从 PDF 目录复制、
// 默认层级、两种 payload 的存取往返、库的跨文档读取与整批替换、回收站归档的计数（计数对不上会拒绝删除）。运行：
//   cp spike/toc-review-test.swift /tmp/main.swift && \
//     swiftc Sources/Store/*.swift Sources/App/CustomTOC.swift Sources/App/ReviewMark.swift /tmp/main.swift -o /tmp/trt && /tmp/trt
// （须命名为 main.swift 编译：swiftc 多文件时顶层代码只允许在 main.swift）
// `TOCEntry.swift` 牵连 PDFKit 渲染那一串，这里放一份字段相同的替身（CustomTOC 只用到这几个字段）。
import Foundation

struct TOCEntry: Identifiable {
    var id = UUID()
    let label: String
    let pageIndex: Int?
    let frac: Double
    var children: [TOCEntry]
}

setvbuf(stdout, nil, _IONBF, 0)
var pass = 0, fail = 0
func check(_ cond: Bool, _ msg: String) {
    if cond { pass += 1; print("  ✅ \(msg)") } else { fail += 1; print("  ❌ \(msg)") }
}
func eq<T: Equatable>(_ a: T, _ b: T, _ msg: String) {
    if a == b { pass += 1; print("  ✅ \(msg)") } else { fail += 1; print("  ❌ \(msg)\n      得到: \(a)\n      期望: \(b)") }
}
func shape(_ es: [TOCEntry]) -> String {
    es.map { e in e.children.isEmpty ? e.label : "\(e.label)(\(shape(e.children)))" }.joined(separator: ",")
}

print("— 目录树还原")
do {
    let items = [
        CustomTOCItem(page: 0, frac: 0, level: 0, title: "第一章", seq: 0),
        CustomTOCItem(page: 0, frac: 0, level: 1, title: "1.1", seq: 1),     // 同页同位置：靠 seq 排在章后
        CustomTOCItem(page: 3, frac: 0.5, level: 1, title: "1.2", seq: 2),
        CustomTOCItem(page: 9, frac: 0, level: 0, title: "第二章", seq: 3),
        CustomTOCItem(page: 9, frac: 0.2, level: 2, title: "2.0.1", seq: 4), // 跳级：照样挂在前一项下
        CustomTOCItem(page: 12, frac: 0, level: 1, title: "2.1", seq: 5),
    ]
    eq(shape(CustomTOCItem.entries(items.shuffled())), "第一章(1.1,1.2),第二章(2.0.1,2.1)", "乱序输入也按 页→位置→seq 还原成树")
    let e = CustomTOCItem.entries(items)
    eq(e[0].id, items[0].id, "目录项 id = 条目 id（界面靠它认出自建的哪一项）")
    eq(e[0].children[1].pageIndex, 3, "页号带过去")
    eq(e[0].children[1].frac, 0.5, "页内位置带过去")
    eq(CustomTOCItem.entries([]).count, 0, "空 → 空")
}

print("— 从 PDF 目录复制 / 默认层级")
do {
    let pdf = [TOCEntry(label: "A", pageIndex: 0, frac: 0.1, children: [
                    TOCEntry(label: "A1", pageIndex: nil, frac: 0, children: []),   // 坏书签：跳过
                    TOCEntry(label: "", pageIndex: 2, frac: 0, children: [
                        TOCEntry(label: "deep", pageIndex: 3, frac: 0, children: [])])]),
               TOCEntry(label: "B", pageIndex: 5, frac: 0, children: [])]
    let c = CustomTOCItem.copy(from: pdf)
    eq(c.map(\.title), ["A", "—", "deep", "B"], "坏书签跳过、空名字补「—」")
    eq(c.map(\.level), [0, 1, 2, 0], "层级 = 深度")
    eq(c.map(\.seq), [0, 1, 2, 3], "seq 按先后")
    eq(shape(CustomTOCItem.entries(c)), "A(—(deep)),B", "复制出来再还原，形状不变")
    eq(CustomTOCItem.defaultLevel(page: 4, frac: 0, in: c), 2, "新加一项：与前面最近那项同级")
    eq(CustomTOCItem.defaultLevel(page: 0, frac: 0, in: c), 0, "最前面：第一级")
    eq(CustomTOCItem.defaultLevel(page: 9, frac: 0, in: []), 0, "没有条目：第一级")
}

print("— payload 往返")
do {
    let it = CustomTOCItem(page: 7, frac: 0.25, level: 3, title: "3.2.1 极限", seq: 42)
    let back = it.toNote(documentId: "D").flatMap(CustomTOCItem.init(note:))
    eq(back?.title, "3.2.1 极限", "目录项名字")
    eq(back?.level, 3, "层级")
    eq(back?.seq, 42, "seq")
    eq(back?.frac, 0.25, "页内位置走 anchor_y")
    check(it.toNote(documentId: "D").flatMap(ReviewMark.init(note:)) == nil, "kind 不对不认（目录项不会被当成回顾点）")

    var m = ReviewMark(documentId: "D", page: 2, frac: 0.6, tag: "极限", remark: "洛必达的条件", period: 2)
    let mb = m.toNote(documentId: "D").flatMap(ReviewMark.init(note:))
    eq(mb?.tag, "极限", "标签")
    eq(mb?.remark, "洛必达的条件", "备注")
    eq(mb?.period, 2, "期号")
    eq(mb?.reviews, 0, "还没看过")
    check(mb?.lastReviewedAt == nil, "没有最后一次")
    m.advance(by: 3)
    eq(m.period, 5, "看完后推 3 期：2 → 5")
    eq(m.reviews, 1, "回顾次数 +1")
    let mb2 = m.toNote(documentId: "D").flatMap(ReviewMark.init(note:))
    check(mb2?.lastReviewedAt != nil, "最后一次回顾时间存下来了")
    m.advance(by: 0)
    eq(m.period, 6, "步长至少 1")
    // 别的端写进来缺字段的 payload
    let raw = LibNote(id: UUID().uuidString, documentId: "D", kind: 8, page: 0, anchor: .zero,
                      payload: Data(#"{"tag":"t","remark":"","period":0}"#.utf8), createdAt: Date(), updatedAt: Date())
    eq(ReviewMark(note: raw)?.period, 1, "期号 < 1 读成 1")
    eq(ReviewMark(note: raw)?.reviews, 0, "缺 reviews 读成 0")
    let f = ReviewFilter(wholeWorkspace: true, tag: "极限", period: 6)
    check(f.matches(m), "筛选：标签 + 期号都对上")
    check(!ReviewFilter(tag: "别的").matches(m), "筛选：标签不对")
}

print("— 库：跨文档读 / 整批替换 / 回收站计数")
do {
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("toc-review-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmp) }
    let store = try LibraryStore(workspaceFolder: tmp)
    let (a, _) = try store.findOrCreate(hash: "ha", title: "A", pageCount: 20, path: "/tmp/a.pdf")
    let (b, _) = try store.findOrCreate(hash: "hb", title: "B", pageCount: 20, path: "/tmp/b.pdf")

    let toc = (0..<5).map { CustomTOCItem(page: $0 * 2, frac: 0, level: $0 % 2, title: "t\($0)", seq: $0) }
    try store.replaceNotes(deleteIds: [], upserts: toc.compactMap { $0.toNote(documentId: a.id) })
    eq(try store.notes(documentId: a.id, kind: CustomTOCItem.noteKind).count, 5, "写入 5 个目录项")
    let toc2 = [CustomTOCItem(page: 1, frac: 0, level: 0, title: "new", seq: 0)]
    try store.replaceNotes(deleteIds: toc.map(\.id.uuidString), upserts: toc2.compactMap { $0.toNote(documentId: a.id) })
    eq(try store.notes(documentId: a.id, kind: CustomTOCItem.noteKind).compactMap(CustomTOCItem.init(note:)).map(\.title), ["new"],
       "整批替换：旧的删掉、新的写进")

    let ra = ReviewMark(documentId: a.id, page: 1, frac: 0, tag: "x", period: 1)
    let rb = ReviewMark(documentId: b.id, page: 3, frac: 0, tag: "y", period: 2)
    try store.replaceNotes(deleteIds: [], upserts: [ra, rb].compactMap { $0.toNote(documentId: $0.documentId) })
    let all = try store.notes(kind: ReviewMark.noteKind).compactMap(ReviewMark.init(note:))
    eq(Set(all.map(\.documentId)), Set([a.id, b.id]), "notes(kind:) 跨文档读到两篇的回顾点")
    eq(all.first { $0.id == rb.id }?.documentId, b.id, "documentId 从行里带出来")
    eq(try store.notes(documentId: a.id, kind: 0).count, 0, "别的 kind 读不到它们")

    let p1 = tmp.appendingPathComponent("t1.sqlite").path
    let ar = try store.archiveNotes(documentId: a.id, ids: [ra.id.uuidString, toc2[0].id.uuidString], to: p1)
    eq(ar.counts.review, 1, "归档：回顾点数到 1")
    eq(ar.counts.tocEntry, 1, "归档：目录项数到 1")
    eq(ar.counts.total, 2, "total 算上两种（对不上时 `Trash.archiveNotes` 会拒绝删除）")
    let enc = try JSONEncoder().encode(ar.counts)
    let dec = try JSONDecoder().decode(TrashStore.Counts.self, from: enc)
    eq(dec, ar.counts, "manifest 计数编解码往返")
    let old = try JSONDecoder().decode(TrashStore.Counts.self, from: Data(#"{"bookmark":2}"#.utf8))
    eq(old.review + old.tocEntry, 0, "老 manifest 没有这两个键 → 0")
}

print("\n\(pass) 通过，\(fail) 失败")
exit(fail == 0 ? 0 : 1)
