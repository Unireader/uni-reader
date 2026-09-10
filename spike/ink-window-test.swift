// 笔迹按页窗口装载/淘汰（`InkWindow` + `LibraryStore` 的按页/聚合 SQL）。运行：
//   cp spike/ink-window-test.swift /tmp/main.swift && swiftc Sources/Store/*.swift Sources/App/InkModel.swift Sources/App/InkLayerModel.swift Sources/App/InkWindow.swift Sources/App/NoteTypeModel.swift Sources/App/PenPreset.swift Sources/Support/L.swift /tmp/main.swift -o /tmp/iwt && /tmp/iwt
// （须命名为 main.swift：swiftc 多文件时顶层代码只允许在 main.swift）
// 覆盖：want/keep 夹取与滞回、缺页合并成段、淘汰集（保留区间 + 钉页）、合并的 z 序（库批 + 期间新画 + 重复 id）、
//       淘汰返回的 id 与对账集同步、fullyPersisted、按页区间读库的排序与整篇一致、按页汇总（笔数/最小 y/去重笔色）、
//       图层计数（含老行无 layerId）、删整层 SQL（含默认层的老行）、页边 x 范围。
import Foundation

var pass = 0, fail = 0
func check(_ c: Bool, _ m: String) { if c { pass += 1; print("  ✅ \(m)") } else { fail += 1; print("  ❌ \(m)") } }

let color = InkColor(r: 24, g: 90, b: 210, a: 0.95)
let red = InkColor(r: 200, g: 30, b: 30, a: 1)
func mk(_ page: Int, _ x: Double = 0.5, layer: UUID = InkLayer.defaultID, color c: InkColor = color) -> InkStroke {
    InkStroke(page: page, color: c, width: 4, points: [InkPoint(x, 0.3, 0.5), InkPoint(x + 0.1, 0.6, 0.5)], layerId: layer)
}

print("want / keep（夹进文档页数，keep > pad 形成滞回）")
check(InkWindow.want(realized: 10...12, pageCount: 100) == 6...16, "want = realized ± pad(4)")
check(InkWindow.keepRange(realized: 10...12, pageCount: 100) == 0...24, "keep = realized ± keep(12)，下界夹到 0")
check(InkWindow.want(realized: 98...99, pageCount: 100) == 94...99, "want 上界夹到 pageCount-1")
check(InkWindow.want(realized: 0...0, pageCount: 1) == 0...0, "单页文档")
check(InkWindow.keep > InkWindow.pad, "keep > pad")

print("missing（缺页合并成连续段，在途的不重复要）")
check(InkWindow.missing(want: 6...16, loaded: []) == [6...16], "全缺 → 一段")
check(InkWindow.missing(want: 6...16, loaded: [8, 9, 10]) == [6...7, 11...16], "中间已装 → 两段")
check(InkWindow.missing(want: 6...16, loaded: [6, 7], inFlight: [15, 16]) == [8...14], "两头已装/在途 → 中间一段")
check(InkWindow.missing(want: 6...16, loaded: Set(6...16)).isEmpty, "全装 → 空")

print("evictable（保留区间之外且没被钉住）")
check(InkWindow.evictable(loaded: [0, 5, 20, 30, 40], keep: 10...30, pinned: [40]) == [0, 5], "0/5 在区间外淘汰；40 被撤销栈钉住不淘汰；20/30 在区间内")

print("merge（库批 + 期间新画的：后画在上；重复 id 以内存版为准）")
do {
    let a = mk(3), b = mk(3), drawn = mk(5, 0.9), stale = mk(5, 0.1)
    var moved = stale; moved.points = [InkPoint(0.2, 0.2, 0.5)]        // 内存里已挪过的同 id 笔迹
    let existing = [a, drawn, moved]                                    // 3 页已装；5 页上有期间新画的 + 挪过的
    let fromDB = [mk(4), stale, mk(5, 0.5)]                             // 库批：4 页一笔、5 页两笔（含 stale 同 id）
    let (merged, added) = InkWindow.merge(existing: existing, loaded: fromDB, pages: [4, 5])
    check(added.map(\.id) == [fromDB[0].id, fromDB[2].id], "added = 库批里内存没有的两条（同 id 那条丢掉）")
    let ids = merged.map(\.id)
    check(ids == [a.id, fromDB[0].id, fromDB[2].id, drawn.id, moved.id], "顺序：别页原样 → 库批 → 本批页上期间新画的")
    check(merged.first { $0.id == stale.id }?.points == moved.points, "重复 id 以内存版（挪过的）为准")
    _ = b
    let (m2, add2) = InkWindow.merge(existing: [], loaded: [], pages: [7])
    check(m2.isEmpty && add2.isEmpty, "空对空")
}

print("evict / fullyPersisted")
do {
    let a = mk(3), b = mk(4), c = mk(5)
    let (kept, removed) = InkWindow.evict(from: [a, b, c], pages: [3, 5])
    check(kept.map(\.id) == [b.id] && Set(removed) == [a.id, c.id], "摘掉指定页，返回它们的 id")
    var persisted: [UUID: InkStroke] = [a.id: a, b.id: b]
    check(InkWindow.fullyPersisted(page: 3, strokes: [a, b, c], persisted: persisted), "页 3 全部按值落库 → 可淘汰")
    check(!InkWindow.fullyPersisted(page: 5, strokes: [a, b, c], persisted: persisted), "页 5 没落库 → 不可淘汰")
    var b2 = b; b2.width = 9; persisted[b.id] = b
    check(!InkWindow.fullyPersisted(page: 4, strokes: [a, b2, c], persisted: persisted), "同 id 内容变了 → 不可淘汰")
}

print("LibraryStore：按页区间读 / 按页汇总 / 图层计数 / 删整层 / x 范围")
let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ink_window_\(UInt64.random(in: 0..<1_000_000))")
try? FileManager.default.removeItem(at: tmp)
try! FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: tmp) }
let store = try LibraryStore(workspaceFolder: tmp)
let (doc, _) = try store.findOrCreate(hash: "h1", title: "Doc", pageCount: 50, path: "/tmp/a.pdf")
let layerB = UUID()
var all: [InkStroke] = []
for p in [2, 2, 5, 9, 9, 9, 20] { all.append(mk(p, Double(p) / 30, layer: p == 9 ? layerB : InkLayer.defaultID, color: p == 5 ? red : color)) }
all.append(mk(2, -0.4))            // 页 2 一笔越出左页边（画板模式）
all[1].points = [InkPoint(0.5, 0.05, 0.5), InkPoint(0.6, 0.9, 0.5)]   // 页 2 的最小 y = 0.05
for st in all { try store.upsertNote(st.toNote(documentId: doc.id)!) }
// 老行：payload 没有 layerId 键（升级前落库的），归默认图层
let legacy = LibNote(id: UUID().uuidString, documentId: doc.id, kind: 2, page: 5, anchor: .zero,
                     payload: Data(#"{"color":{"r":1,"g":2,"b":3,"a":1},"width":3,"points":[[0.1,0.1,0.5]]}"#.utf8),
                     createdAt: .now, updatedAt: .now)
try store.upsertNote(legacy)

let whole = InkStroke.decodeAll(try store.inkRows(documentId: doc.id, kind: 2))
let part = InkStroke.decodeAll(try store.inkRows(documentId: doc.id, kind: 2, pages: 2...9))
check(part.map(\.id) == whole.filter { (2...9).contains($0.page) }.map(\.id), "按页区间读 = 整篇读里那一截（顺序一致）")
let outside = try store.inkRows(documentId: doc.id, kind: 2, pages: 30...40)
check(part.count == 8 && outside.isEmpty, "区间外为空")

let sums = try store.inkPageSummaries(documentId: doc.id)
check(sums.map(\.page) == [2, 5, 9, 20], "按页汇总：页升序")
check(sums.map(\.count) == [3, 2, 3, 1], "各页笔数")
check(abs(sums[0].minY - 0.05) < 1e-6, "页 2 最小 y 取自 anchor_y 列")
let colors5 = (try? JSONDecoder().decode([InkColor].self, from: Data(sums[1].colorsJSON.utf8))) ?? []
check(Set(colors5.map { "\($0.r),\($0.g),\($0.b)" }) == ["200.0,30.0,30.0", "1.0,2.0,3.0"], "页 5 去重笔色：红 + 老行那种")

let lc = try store.inkLayerCounts(documentId: doc.id)
check(lc[layerB.uuidString.uppercased()] == 3, "图层 B 三笔（页 9）")
check(lc[InkLayer.defaultID.uuidString.uppercased()] == 5 && lc[""] == 1, "默认层 5 笔 + 老行（无 layerId 键）1 笔")

let ext = try store.inkXExtent(documentId: doc.id)
check(ext != nil && abs(ext!.minX - (-0.4)) < 1e-6 && ext!.maxX > 0.7, "x 范围：最小 -0.4（页边那一笔）")

let gone = try store.deleteInkStrokes(documentId: doc.id, layerId: layerB.uuidString.lowercased(), isDefaultLayer: false)
let left1 = try store.inkCount(documentId: doc.id)
check(gone == 3 && left1 == 6, "删图层 B：3 行没了（小写 id 也认）")
let gone2 = try store.deleteInkStrokes(documentId: doc.id, layerId: InkLayer.defaultID.uuidString, isDefaultLayer: true)
let left2 = try store.inkCount(documentId: doc.id)
check(gone2 == 6 && left2 == 0, "删默认层：连老行一起 6 行")

print("\n\(pass) passed, \(fail) failed")
exit(fail == 0 ? 0 : 1)
