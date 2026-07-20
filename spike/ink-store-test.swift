// 手写笔迹持久化 round-trip 测试（note kind=2，payload=JSON 序列化 InkStroke）。运行：
//   cp spike/ink-store-test.swift /tmp/main.swift && swiftc Sources/Store/*.swift Sources/App/InkModel.swift /tmp/main.swift -o /tmp/it && /tmp/it
// （须命名为 main.swift：swiftc 多文件时顶层代码只允许在 main.swift）
// 覆盖：InkStroke↔LibNote 映射、note 列语义(kind/page/anchor)、payload JSON 形态、擦除删除、
//       空笔画跳过、非 ink/损坏 payload 容错、多笔画增量对账。
import Foundation

var pass = 0, fail = 0
func check(_ c: Bool, _ m: String) { if c { pass += 1; print("  ✅ \(m)") } else { fail += 1; print("  ❌ \(m)") } }

let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ink_test_\(UInt64.random(in: 0..<1_000_000))")
try? FileManager.default.removeItem(at: tmp)
try! FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: tmp) }

let store = try LibraryStore(workspaceFolder: tmp)
let (doc, _) = try store.findOrCreate(hash: "h1", title: "Doc", pageCount: 20, path: "/tmp/a.pdf")

// 1) InkStroke → note → 落库 → 读回 → InkStroke，字段一致
let color = InkColor(r: 24, g: 90, b: 210, a: 0.95)
let pts: [SIMD3<Double>] = [SIMD3(0.1, 0.2, 0.5), SIMD3(0.3, 0.42, 0.8), SIMD3(0.55, 0.6, 0.3)]
let s1 = InkStroke(page: 3, color: color, width: 8.5, points: pts)
guard let note = s1.toNote(documentId: doc.id) else { fatalError("toNote nil") }
try store.upsertNote(note)

let loaded = (try store.notes(documentId: doc.id)).compactMap { $0.kind == InkStroke.noteKind ? InkStroke(note: $0) : nil }
check(loaded.count == 1, "读回 1 条 ink 笔画")
let r = loaded[0]
check(r.id == s1.id, "id 保持（note.id == stroke.id）")
check(r.page == 3, "page 保持")
check(r.width == 8.5, "width 保持")
check(r.color == color, "color 保持 (r/g/b/a)")
check(r.points.count == 3, "点数保持")
var ptsOK = true
for (a, b) in zip(r.points, pts) where abs(a.x-b.x) > 1e-9 || abs(a.y-b.y) > 1e-9 || abs(a.z-b.z) > 1e-9 { ptsOK = false }
check(ptsOK, "各点 x/y/pressure 精确 round-trip")
check(r == s1, "整体 InkStroke 相等")

// 2) note 列语义：kind=2、page 列、anchor=归一化包围盒
check(note.kind == 2, "kind == 2 (ink)")
check(note.page == 3, "note.page 列 = 笔画页")
check(abs(note.anchor.minX - 0.1) < 1e-9 && abs(note.anchor.minY - 0.2) < 1e-9
      && abs(note.anchor.width - 0.45) < 1e-9 && abs(note.anchor.height - 0.4) < 1e-9, "anchor = 点集归一化包围盒")

// 3) payload 是干净跨平台 JSON：{color:{r,g,b,a}, width, points:[[x,y,p]]}
let json = try JSONSerialization.jsonObject(with: note.payload) as! [String: Any]
check(Set(json.keys) == ["color", "width", "points"], "payload 顶层键 = color/width/points")
let jc = json["color"] as! [String: Any]
check(Set(jc.keys) == ["r", "g", "b", "a"], "color 键 = r/g/b/a")
let jp = json["points"] as! [[Double]]
check(jp.count == 3 && jp[0].count == 3, "points 为 [x,y,pressure] 数组")
check(abs(jp[1][1] - 0.42) < 1e-9, "points 值正确")

// 4) 擦除 → deleteNote(id) 生效
try store.deleteNote(id: s1.id.uuidString)
check((try store.notes(documentId: doc.id)).isEmpty, "deleteNote 后无 ink 笔画")

// 5) 空点笔画 → toNote 返回 nil（不落库）
check(InkStroke(page: 0, color: color, width: 5, points: []).toNote(documentId: doc.id) == nil, "空笔画 toNote == nil")

// 6) 类型不符（kind=0 文本 note）→ InkStroke(note:) == nil
let textNote = LibNote(id: UUID().uuidString, documentId: doc.id, kind: 0, page: 1,
                       anchor: .zero, payload: Data("{}".utf8), createdAt: .now, updatedAt: .now)
check(InkStroke(note: textNote) == nil, "非 ink 笔记 → InkStroke(note:) == nil")

// 7) 损坏 payload → nil，不崩
let bad = LibNote(id: UUID().uuidString, documentId: doc.id, kind: 2, page: 1,
                  anchor: .zero, payload: Data("not json".utf8), createdAt: .now, updatedAt: .now)
check(InkStroke(note: bad) == nil, "损坏 payload → nil（不崩）")

// 8) 多笔画增量对账（模拟 persistInk：新增 upsert / 擦除 delete）
let a = InkStroke(page: 0, color: color, width: 4, points: [SIMD3(0.1,0.1,0.5)])
let b = InkStroke(page: 0, color: color, width: 4, points: [SIMD3(0.2,0.2,0.5)])
let c = InkStroke(page: 1, color: color, width: 4, points: [SIMD3(0.3,0.3,0.5)])
for st in [a, b, c] { if let n = st.toNote(documentId: doc.id) { try store.upsertNote(n) } }
check((try store.notes(documentId: doc.id)).count == 3, "三笔全部落库")
try store.deleteNote(id: b.id.uuidString)  // 擦掉 b
let after = (try store.notes(documentId: doc.id)).compactMap { InkStroke(note: $0) }.map(\.id)
check(after.count == 2 && after.contains(a.id) && after.contains(c.id) && !after.contains(b.id), "擦除 b 后仅剩 a,c")

print("\n\(pass) passed, \(fail) failed")
exit(fail == 0 ? 0 : 1)
