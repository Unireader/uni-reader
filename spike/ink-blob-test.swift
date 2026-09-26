// 笔迹点集二进制（schema v18，`BINARY-INK-PLAN.md`）测试。运行：
//   cp spike/ink-blob-test.swift /tmp/main.swift && swiftc Sources/Store/*.swift Sources/App/InkModel.swift \
//     Sources/App/InkLayerModel.swift Sources/App/InkEdit.swift Sources/App/ScratchPadModel.swift Sources/App/BoardModel.swift \
//     Sources/App/NoteTypeModel.swift Sources/App/TextNoteModel.swift Sources/App/ImageNoteModel.swift \
//     Sources/App/PenPreset.swift Sources/App/TrashModel.swift Sources/Support/L.swift /tmp/main.swift -o /tmp/ibt && /tmp/ibt
// （须命名为 main.swift；在仓库根目录跑——要读 spike/ink-blob-vectors.txt）
//
// 覆盖：
//  ① 编解码与跨端向量（`spike/ink-blob-vectors.txt`，安卓 `InkPointsBlobTest` 读同一份）；坏数据解不出；
//  ② 新写的行：points + points_at == updated_at，落库的 payload 不带 JSON 点，读回走二进制、与写入逐位相同；
//  ③ 旧版 App 改过这一行（只改 payload 与 updated_at）→ 二进制过期，读 JSON（改过的那份）；
//  ④ 打开时整理：老行 / 旧版改过的 / 兼容模式留下的，一律转二进制并摘 JSON 点，updated_at 不动；可重入；
//  ⑥ 画板笔迹（分页，页内坐标）同一套规则。
import Foundation
import CoreGraphics

var pass = 0, fail = 0
func check(_ c: Bool, _ m: String) { if c { pass += 1; print("  ✅ \(m)") } else { fail += 1; print("  ❌ \(m)") } }

func hex(_ d: Data) -> String { d.map { String(format: "%02x", $0) }.joined() }
func bits(_ a: [InkPoint]) -> [UInt32] { a.flatMap { [$0.x.bitPattern, $0.y.bitPattern, $0.z.bitPattern] } }

print("① 编解码与跨端向量")
let vec = try! String(contentsOfFile: "spike/ink-blob-vectors.txt", encoding: .utf8)
var nVec = 0
for line in vec.split(separator: "\n") where !line.hasPrefix("#") {
    let parts = line.split(separator: "|", omittingEmptySubsequences: false)
    guard parts.count == 2 else { continue }
    let pts: [InkPoint] = parts[0].isEmpty ? [] : parts[0].split(separator: ";").map { p in
        let v = p.split(separator: ",").map { Float(String($0))! }
        return InkPoint(v[0], v[1], v[2])
    }
    let enc = InkPointsBlob.encode(pts)
    check(hex(enc) == String(parts[1]), "向量 \(nVec)：编码 = \(parts[1])")
    check(InkPointsBlob.decode(enc).map(bits) == bits(pts), "向量 \(nVec)：解码逐位相同")
    nVec += 1
}
check(nVec >= 4, "向量文件读到 \(nVec) 条")
check(InkPointsBlob.decode(Data()) == nil, "空 → nil")
check(InkPointsBlob.decode(Data([2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0])) == nil, "版本不认识 → nil")
check(InkPointsBlob.decode(Data([1, 0, 0])) == nil, "长度不对 → nil")

// ---- 库 ----
let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ink_blob_\(UInt64.random(in: 0..<1_000_000))")
try? FileManager.default.removeItem(at: tmp)
try! FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: tmp) }
var store = try! LibraryStore(workspaceFolder: tmp)
/// 第二条连接：模拟旧版 App / 直接看库
let raw = try! SQLiteDB(path: tmp.appendingPathComponent("UniReader/library.sqlite").path)
func row(_ table: String, _ id: String) -> [String: Any] {
    (try? raw.query("SELECT * FROM \(table) WHERE id=?", [.text(id)]))?.first ?? [:]
}
func jsonPointCount(_ payload: Data) -> Int {
    guard let o = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
          let a = o["points"] as? [Any] else { return -1 }
    return a.count
}
let noteSpec = MirrorFp.specs.first { $0.table == "note" }!
let docId = try! store.findOrCreate(hash: "h1", title: "Doc", pageCount: 40, path: "/tmp/a.pdf").0.id
let pts: [InkPoint] = [InkPoint(0.1, 0.2, 0.5), InkPoint(0.123456789, 0.987654321, 0.75), InkPoint(1.5, -0.25, 1)]

print("② 新写的行")
check(store.meta("schema_version") == "18", "schema_version = 18")
let s1 = InkStroke(page: 3, color: .defaultInk, width: 2.5, points: pts)
check(jsonPointCount(s1.toNote(documentId: docId)!.payload) == 3, "toNote 产出的 JSON 仍带点（剪贴板等别处要用）")
try! store.upsertNote(s1.toNote(documentId: docId)!)
var r = row("note", s1.id.uuidString)
check((r["points"] as? Data).flatMap(InkPointsBlob.decode).map(bits) == bits(pts), "points 列 = 二进制点集")
check((r["points_at"] as? String) == (r["updated_at"] as? String), "points_at == updated_at")
check(jsonPointCount(r["payload"] as! Data) == 0, "落库的 payload 里 JSON 点 = []（点只存二进制）")
let back = try! store.inkRows(documentId: docId, kind: 2).compactMap(InkStroke.init(row:))
check(back.count == 1 && bits(back[0].points) == bits(pts), "inkRows 读回逐位相同")
check(try! store.inkRows(documentId: docId, kind: 2)[0].pointsValid, "inkRows：二进制有效")
check(try! store.notes(documentId: docId).first.map { $0.pointsValid && $0.points != nil } == true, "notes(SELECT *)：二进制有效")

print("③ 旧版 App 改过")
// 旧版只认 payload：平移了 JSON 点、刷新 updated_at，新两列原样留着
let moved: [[Double]] = [[0.3, 0.4, 0.5]]
var obj = try! JSONSerialization.jsonObject(with: r["payload"] as! Data) as! [String: Any]
obj["points"] = moved
try! raw.run("UPDATE note SET payload=?, updated_at=? WHERE id=?",
             [.blob(try! JSONSerialization.data(withJSONObject: obj)), .text("2099-01-01T00:00:00Z"), .text(s1.id.uuidString)])
let back2 = try! store.inkRows(documentId: docId, kind: 2)
check(!back2[0].pointsValid, "二进制判为过期")
let st2 = InkStroke(row: back2[0])!
check(st2.points.count == 1 && st2.points[0] == InkPoint(0.3, 0.4, 0.5), "读的是旧版改过的 JSON 点")

print("④ 打开时整理（转二进制 + 摘 JSON 点，一行一次写好）")
// 老行（v17 写的：没有二进制，点在 JSON 里）
var legacy = InkStroke(page: 1, color: .defaultInk, width: 1, points: pts).toNote(documentId: docId)!
legacy.points = nil
try! store.upsertNote(legacy)
let up0 = row("note", legacy.id)["updated_at"] as! String
check(((row("note", legacy.id)["points"] as? Data) ?? Data()).isEmpty, "老行没有二进制")
check(jsonPointCount(row("note", legacy.id)["payload"] as! Data) == 3, "老行 JSON 点还在")
// 上一版开发包留下的「兼容模式」行：二进制有效、JSON 点也在
let s4 = InkStroke(page: 4, color: .defaultInk, width: 1, points: pts)
let n4 = s4.toNote(documentId: docId)!
try! raw.run("""
INSERT INTO note(id,document_id,kind,page,anchor_x,anchor_y,anchor_w,anchor_h,payload,created_at,updated_at,points,points_at)
VALUES(?,?,2,4,0,0,0,0,?,'2026-01-01T00:00:00Z','2026-01-01T00:00:00Z',?,'2026-01-01T00:00:00Z')
""", [.text(n4.id), .text(docId), .blob(n4.payload), .blob(n4.points!)])
let n = store.compactInkPoints()
check(n == 3, "整理了 3 行（老行 + ③ 被旧版改过的 + 兼容模式留下的），实际 \(n)")
let rl = row("note", legacy.id)
check((rl["points"] as? Data).flatMap(InkPointsBlob.decode).map(bits) == bits(pts), "老行的二进制 = 原 JSON 点")
check(jsonPointCount(rl["payload"] as! Data) == 0, "老行 JSON 点已摘")
check((rl["updated_at"] as! String) == up0 && (rl["points_at"] as? String) == up0, "updated_at 不动，points_at 等于它")
check(jsonPointCount(row("note", n4.id)["payload"] as! Data) == 0, "兼容模式留下的行：JSON 点已摘")
check((row("note", n4.id)["points"] as? Data) == n4.points, "兼容模式留下的行：二进制原样")
check(InkStroke(row: try! store.inkRows(documentId: docId, kind: 2).first { $0.id == s1.id.uuidString }!)!.points[0]
      == InkPoint(0.3, 0.4, 0.5), "③ 那行整理后读的是旧版改过的点")
check(try! store.inkRows(documentId: docId, kind: 2).allSatisfy { $0.pointsValid }, "整理后所有行二进制有效")
check(store.compactInkPoints() == 0, "再跑一次整理 0 行（可重入）")
let all = try! store.inkRows(documentId: docId, kind: 2).compactMap(InkStroke.init(row:))
check(all.count == 3 && all.filter { $0.id.uuidString != s1.id.uuidString }.allSatisfy { bits($0.points) == bits(pts) },
      "整理后读回完整")
_ = noteSpec

print("⑥ 画板笔迹（分页，页内坐标）")
let tmp2 = tmp.appendingPathComponent("ws2")
try! FileManager.default.createDirectory(at: tmp2, withIntermediateDirectories: true)
let store2 = try! LibraryStore(workspaceFolder: tmp2)
try! store2.upsertBoard(LibBoard(id: "B1", title: "", bg: "", pattern: "plain", groupName: "",
                                 createdAt: .now, updatedAt: .now, lastOpenedAt: nil))
let pageId = UUID()
let origin = CGPoint(x: -300, y: 866)
let bs = InkStroke(page: 0, color: .defaultInk, width: 3, points: [InkPoint(-250, 900, 0.5), InkPoint(-200, 950, 0.6)],
                   padId: UUID())
let item = bs.toBoardItem(boardId: "B1", createdAt: .now, page: (pageId, origin))!
check(item.points.flatMap(InkPointsBlob.decode).map { $0[0] } == InkPoint(50, 34, 0.5), "二进制存页内坐标")
try! store2.upsertBoardItem(item)
let items = try! store2.boardItems(boardId: "B1")
check(items.count == 1 && items[0].pointsValid, "board_item：二进制有效")
let bback = InkStroke(boardItem: items[0], padId: UUID(), origin: { $0 == pageId.uuidString ? origin : nil })
check(bback.map { bits($0.points) } == bits(bs.points), "读回按页原点还原成画布坐标，逐位相同")

print("\n\(pass) 通过，\(fail) 失败")
exit(fail == 0 ? 0 : 1)
