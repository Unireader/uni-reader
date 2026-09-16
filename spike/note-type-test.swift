// NoteType 模型 + 工作区 meta 持久化回归测试。运行：
//   cp spike/note-type-test.swift /tmp/main.swift && swiftc Sources/Store/*.swift Sources/App/NoteTypeModel.swift Sources/App/TextNoteModel.swift Sources/App/InkModel.swift Sources/App/InkLayerModel.swift Sources/App/PenPreset.swift Sources/Support/L.swift /tmp/main.swift -o /tmp/nt && /tmp/nt
// （须命名为 main.swift 编译：swiftc 多文件时顶层代码只允许在 main.swift）

import Foundation

var pass = 0, fail = 0
func check(_ cond: Bool, _ msg: String) {
    if cond { pass += 1; print("  ✅ \(msg)") } else { fail += 1; print("  ❌ \(msg)") }
}

// 1) NoteType JSON 回环 + snake_case 键
let t = NoteType(name: "错题", colorKey: "red", iconName: "exclamationmark.triangle")
let data = try! JSONEncoder().encode([t])
let json = String(data: data, encoding: .utf8)!
check(json.contains("\"color_key\"") && json.contains("\"icon_name\""), "JSON 键为 snake_case（color_key/icon_name）")
let back = try! JSONDecoder().decode([NoteType].self, from: data)
check(back == [t], "NoteType 数组编解码回环")

// 2) 色板/图标兜底
check(NoteType.paletteRGB("red").r == 255, "色板 red 命中")
check(NoteType.paletteRGB("nope") == NoteType.paletteRGB("gray"), "未知色 key → gray")
check(NoteType.icon("flame") == "flame", "候选图标命中")
check(NoteType.icon("not-a-symbol") == "note.text", "未知图标 → note.text")

// 3) 通用兜底
check(NoteType.general.id == NoteType.generalID, "通用 id 固定")
check(NoteType.resolve(nil, in: [t]).id == NoteType.generalID, "nil typeId → 通用")
check(NoteType.resolve(UUID(), in: [t]).id == NoteType.generalID, "未知 typeId → 通用")
check(NoteType.resolve(t.id, in: [t]) == t, "已知 typeId → 命中")

// 4) 工作区 meta 回环（模拟 WorkspaceManager.noteTypes/saveNoteTypes 的编解码）
let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ws_nt_\(UInt64.random(in: 0..<1_000_000))")
try? FileManager.default.removeItem(at: tmp)
try! FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: tmp) }
let store = try LibraryStore(workspaceFolder: tmp)
try store.setMeta("note_types", json)
let read = store.meta("note_types").flatMap { $0.data(using: .utf8) }
    .flatMap { try? JSONDecoder().decode([NoteType].self, from: $0) } ?? []
check(read == [t], "meta(note_types) 写入/读回")
check(store.meta("note_types") != nil, "meta 键存在")
let broken = "{oops".data(using: .utf8)!
check((try? JSONDecoder().decode([NoteType].self, from: broken)) == nil, "损坏 JSON → 解码 nil（上层回落空数组）")

// 5) TextNote payload：旧数据无 type_id → nil（通用）；新数据回环保留
let docId = "doc-1"
var note = TextNote(page: 2, anchor: CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.05),
                    quote: "原文", text: "批注", rects: [CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.05)])
let oldPayload = Data("{\"quote\":\"原文\",\"text\":\"批注\",\"rects\":[[0.1,0.2,0.3,0.05]]}".utf8)
let oldRow = LibNote(id: note.id.uuidString, documentId: docId, kind: TextNote.noteKind,
                     page: 2, anchor: note.anchor, payload: oldPayload,
                     createdAt: note.createdAt, updatedAt: note.updatedAt)
check(TextNote(note: oldRow)?.typeId == nil, "旧 payload（无 type_id）→ typeId nil")
note.typeId = t.id
let row = note.toNote(documentId: docId)!
check(String(data: row.payload, encoding: .utf8)!.contains("\"type_id\""), "payload 含 type_id 键")
check(TextNote(note: row)?.typeId == t.id, "typeId 编解码回环")

let badRow = LibNote(id: note.id.uuidString, documentId: docId, kind: TextNote.noteKind,
                     page: 2, anchor: note.anchor,
                     payload: Data("{\"quote\":\"原文\",\"text\":\"批注\",\"rects\":[[0.1,0.2,0.3,0.05]],\"type_id\":\"not-a-uuid\"}".utf8),
                     createdAt: note.createdAt, updatedAt: note.updatedAt)
check(TextNote(note: badRow)?.typeId == nil, "损坏 type_id 字符串 → typeId nil（落通用）")

// 6) TextNote.display（展开方式）：旧 payload 无 display 键 → tap（零迁移）；三态回环；坏值落 tap
check(TextNote(note: oldRow)?.display == .tap, "旧 payload（无 display）→ tap")
for d in NoteDisplay.allCases {
    note.display = d
    let r = note.toNote(documentId: docId)!
    check(String(data: r.payload, encoding: .utf8)!.contains("\"display\""), "payload 含 display 键（\(d.rawValue)）")
    check(TextNote(note: r)?.display == d, "display 编解码回环（\(d.rawValue)）")
}
let badDisplay = LibNote(id: note.id.uuidString, documentId: docId, kind: TextNote.noteKind,
                         page: 2, anchor: note.anchor,
                         payload: Data("{\"quote\":\"\",\"text\":\"x\",\"rects\":[],\"display\":\"popover\"}".utf8),
                         createdAt: note.createdAt, updatedAt: note.updatedAt)
check(TextNote(note: badDisplay)?.display == .tap, "未知 display 值 → tap")
// 线上 u8 与 payload 串是同一套语义（三端按数值解码，只许尾部追加）
check(NoteDisplay.tap.wire == 0 && NoteDisplay.hover.wire == 1 && NoteDisplay.always.wire == 2,
      "display 线上编号 0/1/2")
check(NoteDisplay.fromWire(9) == .tap, "未知线上编号 → tap")

// 7) TextNote.style / color（2026-09-16：画法 + 显式铺色）：旧 payload 无 style 键 → fill、无 color → nil（零迁移）；
//    三种画法回环；坏值落 fill；显式颜色回环
check(TextNote(note: oldRow)?.style == .fill, "旧 payload（无 style）→ fill")
check(TextNote(note: oldRow)?.color == nil, "旧 payload（无 color）→ nil（按类型色）")
for s in HighlightStyle.allCases {
    note.style = s
    let r = note.toNote(documentId: docId)!
    check(String(data: r.payload, encoding: .utf8)!.contains("\"style\":\"\(s.rawValue)\""), "payload 含 style 键（\(s.rawValue)）")
    check(TextNote(note: r)?.style == s, "style 编解码回环（\(s.rawValue)）")
}
let badStyle = LibNote(id: note.id.uuidString, documentId: docId, kind: TextNote.noteKind,
                       page: 2, anchor: note.anchor,
                       payload: Data("{\"quote\":\"\",\"text\":\"x\",\"rects\":[],\"style\":\"wavy\"}".utf8),
                       createdAt: note.createdAt, updatedAt: note.updatedAt)
check(TextNote(note: badStyle)?.style == .fill, "未知 style 值 → fill")
note.color = InkColor(r: 120, g: 190, b: 255, a: 1)
let colored = note.toNote(documentId: docId)!
check(TextNote(note: colored)?.color == InkColor(r: 120, g: 190, b: 255, a: 1), "显式 color 编解码回环")
note.color = nil
check(!String(data: note.toNote(documentId: docId)!.payload, encoding: .utf8)!.contains("\"color\":{"),
      "color 为 nil 时 payload 不带 color 对象")

print("\n通过 \(pass)，失败 \(fail)")
if fail > 0 { exit(1) }
