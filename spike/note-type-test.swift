// NoteType 模型 + 工作区 meta 持久化回归测试。运行：
//   cp spike/note-type-test.swift /tmp/main.swift && swiftc Sources/Store/*.swift Sources/App/NoteTypeModel.swift Sources/App/TextNoteModel.swift Sources/App/InkModel.swift Sources/App/PenPreset.swift Sources/Support/L.swift /tmp/main.swift -o /tmp/nt && /tmp/nt
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

print("\n通过 \(pass)，失败 \(fail)")
if fail > 0 { exit(1) }
