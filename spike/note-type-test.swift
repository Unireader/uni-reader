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

// 8) NoteCard（2026-09-16：卡片手动摆位 / 改大小）：payload 回环、旧数据零迁移、拖动几何
check(TextNote(note: oldRow)?.card == nil, "旧 payload（无 card）→ nil（自动规则）")
note.card = NoteCard(dx: 12, dy: -7.5, w: 300, h: nil)
let carded = note.toNote(documentId: docId)!
check(TextNote(note: carded)?.card == NoteCard(dx: 12, dy: -7.5, w: 300, h: nil), "card 编解码回环（h 缺省）")
check(String(data: carded.payload, encoding: .utf8)!.contains("\"card\":{"), "payload 含 card 键")
note.card = nil

let page = CGSize(width: 600, height: 800)
let pin = CGPoint(x: 100, y: 100)
let f0 = CGRect(x: 112, y: 91, width: 280, height: 120)   // 按下时卡片的样子
let minS = CGSize(width: 80, height: 22)
func drag(_ z: NoteCardZone, _ t: CGSize, content: CGFloat = 500, card: NoteCard? = nil, unit: CGFloat = 1) -> NoteCard {
    NoteCardDrag(zone: z, frame: f0, contentHeight: content, card: card)
        .card(translation: t, unit: unit, pin: pin, minSize: minS, page: page)
}
var r = drag(.move, CGSize(width: 50, height: 30))
check(r == NoteCard(dx: 62, dy: 21, w: nil, h: nil), "移动：只动位置，宽高保持自动（nil）")
r = drag(.move, CGSize(width: -1000, height: 5000))
check(r.dx == -100 && r.dy == Double(800 - 120 - 100), "移动：钳在页内（左边到 0、下边贴页底）")
r = drag(.trailing, CGSize(width: 40, height: 99))
check(r.w == 320 && r.h == nil && r.dx == 12 && r.dy == -9, "拖右边：只改宽，位置钉住在原处")
r = drag(.leading, CGSize(width: 30, height: 0))
check(r.w == 250 && r.dx == 42, "拖左边：右边不动，左边跟手")
r = drag(.leading, CGSize(width: 500, height: 0))
check(r.w == 80 && r.dx == Double(392 - 80 - 100), "拖左边过头：钳到最小宽，右边仍不动")
r = drag(.bottom, CGSize(width: 0, height: 60))
check(r.h == 180 && r.w == nil, "拖下边：高度上限 = 可见高 + 位移")
r = drag(.top, CGSize(width: 0, height: 20), content: 500)
check(r.h == 100 && r.dy == Double(91 + 20 - 100), "拖上边：下边不动，上限变小")
r = drag(.top, CGSize(width: 0, height: -200), content: 150)
check(r.h == 211 && r.dy == Double(211 - 150 - 100), "拖上边超过内容高：上限照记，可见高收到内容高、下边仍不动")
r = drag(.bottomTrailing, CGSize(width: 10, height: 10), card: NoteCard(dx: 0, dy: 0, w: 999, h: 999))
check(r.w == 290 && r.h == 130, "拖右下角：宽高一起改（覆盖旧值）")
r = drag(.trailing, CGSize(width: 20, height: 0), card: NoteCard(dx: 1, dy: 2, w: nil, h: 555))
check(r.h == 555, "只拖右边：原来存的高度上限保留")
r = drag(.trailing, CGSize(width: 20, height: 0), unit: 2)
check(r.w == 150 && r.dx == 6, "跟页缩放口径：存的数 = 像素 ÷ unit")
// 图钉禁区（用户 2026-09-16：卡片不许盖住自己的图钉）。pin (100,100)、禁区半边 12 → (88…112, 88…112)
let k = NoteCardPin.keepOut(pin: pin, clearance: 12)
check(!NoteCardPin.overlaps(CGRect(x: 112, y: 90, width: 50, height: 50), k), "只贴着禁区右边：不算压住")
let pushed = NoteCardPin.pushOut(CGRect(x: 95, y: 80, width: 100, height: 60), keepOut: k, page: page)
check(pushed == CGRect(x: 112, y: 80, width: 100, height: 60), "压住一点点：挪到最近的一侧（右边，挪 17）→ \(pushed)")
let pushedUp = NoteCardPin.pushOut(CGRect(x: 20, y: 60, width: 300, height: 40), keepOut: k, page: page)
check(pushedUp.minY == 48 && pushedUp.minX == 20,
      "宽卡片横跨图钉（左边放不下）：往上挪 12 比往下 52、往右 92 都近 → \(pushedUp)")
let edgePage = CGSize(width: 130, height: 800)   // 页很窄：图钉右边放不下
let pushedLeft = NoteCardPin.pushOut(CGRect(x: 30, y: 95, width: 50, height: 30), keepOut: k, page: edgePage)
check(!NoteCardPin.overlaps(pushedLeft, k), "右边放不下（钳进页内还压着）的候选不选 → \(pushedLeft)")
r = drag(.move, CGSize(width: -60, height: 0))   // f0 从 x=112 往左拖 60：压进禁区
let movedRect = CGRect(x: pin.x + CGFloat(r.dx), y: pin.y + CGFloat(r.dy), width: f0.width, height: f0.height)
check(movedRect.minX == 52 && NoteCardPin.overlaps(movedRect, k), "不带禁区参数：纯移动，不管图钉（x=\(movedRect.minX)）")
let rPin = NoteCardDrag(zone: .move, frame: f0, contentHeight: 500, card: nil)
    .card(translation: CGSize(width: -60, height: 0), unit: 1, pin: pin, minSize: minS, page: page, pinClearance: 12)
let rPinRect = CGRect(x: pin.x + CGFloat(rPin.dx), y: pin.y + CGFloat(rPin.dy), width: f0.width, height: f0.height)
check(!NoteCardPin.overlaps(rPinRect, k), "移动压进图钉：整块挪开 → \(rPinRect)")
let rEdge = NoteCardDrag(zone: .leading, frame: f0, contentHeight: 500, card: nil)
    .card(translation: CGSize(width: -60, height: 0), unit: 1, pin: pin, minSize: minS, page: page, pinClearance: 12)
check(rEdge.dx == 12 && rEdge.w == Double(f0.width), "左边往左拉进图钉：停在禁区右边上（宽不变）→ dx=\(rEdge.dx) w=\(rEdge.w ?? -1)")
check(NoteCardZone.at(CGPoint(x: 2, y: 2), size: f0.size) == .topLeading
      && NoteCardZone.at(CGPoint(x: 279, y: 60), size: f0.size) == .trailing
      && NoteCardZone.at(CGPoint(x: 140, y: 118), size: f0.size) == .bottom
      && NoteCardZone.at(CGPoint(x: 140, y: 60), size: f0.size) == .move, "按下位置 → 分区（角 / 边 / 中间）")

print("\n通过 \(pass)，失败 \(fail)")
if fail > 0 { exit(1) }
