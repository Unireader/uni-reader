// 编辑撤销栈（`InkUndo.swift`）与笔迹剪贴板（`InkClipboard.swift`）的纯逻辑测试。运行：
//   cp spike/ink-undo-test.swift /tmp/main.swift && swiftc Sources/Support/L.swift Sources/Store/LibraryModels.swift Sources/Store/InkPointsBlob.swift Sources/Store/InkPayloadFast.swift Sources/App/PenPreset.swift Sources/App/InkModel.swift Sources/App/InkLayerModel.swift Sources/App/NoteTypeModel.swift Sources/App/TextNoteModel.swift Sources/App/ImageNoteModel.swift Sources/App/ScratchPadModel.swift Sources/App/BoardModel.swift Sources/App/InkUndo.swift Sources/App/InkClipboard.swift /tmp/main.swift -o /tmp/iut && /tmp/iut
// （须命名为 main.swift：swiftc 多文件时顶层代码只允许在 main.swift。`DocSession` 上那层薄封装在
//  `Sources/App/DocSession+InkUndo.swift`，不进这里——它只是 inkEdit{} 取前后快照再调 record。）
// 覆盖：diff/apply（新增/删除/改值/插回原位）、撤销-重做往返、擦除合并（同一次拖动并成一步）、
//       封口后另起一步、新动作作废重做链、栈上限、剪贴板往返（新 id / 文本兜底 / 旧 payload 缺键兜底 /
//       页 ⇄ 纸 两个坐标空间的换算）。
import AppKit
import Foundation

var pass = 0, fail = 0
func check(_ c: Bool, _ m: String) { if c { pass += 1; print("  ✅ \(m)") } else { fail += 1; print("  ❌ \(m)") } }

let color = InkColor(r: 24, g: 90, b: 210, a: 0.95)
func mkStroke(_ x: Double, page: Int = 0) -> InkStroke {
    InkStroke(page: page, color: color, width: 8, points: [SIMD3(x, 0.5, 0.5), SIMD3(x + 0.1, 0.5, 0.5)])
}
func mkNote(_ text: String, page: Int = 0) -> TextNote {
    TextNote(page: page, anchor: CGRect(x: 0.2, y: 0.3, width: 0, height: 0), quote: "", text: text, rects: [])
}

// ---- InkDelta ----
print("InkDelta.diff / apply")
do {
    let a = mkStroke(0.1), b = mkStroke(0.2), c = mkStroke(0.3)
    let before = [a, b, c]
    var moved = b; moved.points = [SIMD3(0.9, 0.9, 0.5)]
    let after = [a, moved]                       // b 改值、c 删掉
    let d = InkDelta.diff(before, after)
    check(d.count == 2, "只记受影响的两条（改值 + 删除），没碰过的不入账")
    check(d[b.id]?.before == b && d[b.id]?.after == moved, "改值：before/after 各一份")
    check(d[c.id]?.after == nil && d[c.id]?.index == 2, "删除：after 为 nil，且记住了原下标 2")

    var arr = after
    InkDelta.apply(d, to: &arr, undo: true)
    check(arr.count == 3, "撤销后条数复原")
    check(arr[1] == b, "改值被还原")
    check(arr[2] == c, "删掉的那条插回**原位**（下标 2），z 序不乱")

    InkDelta.apply(d, to: &arr, undo: false)
    check(arr.count == 2 && arr[1] == moved, "重做回到撤销前那一份")
}

// ---- 栈：撤销/重做往返 ----
print("InkUndoStack：撤销 / 重做")
do {
    let stack = InkUndoStack()
    check(!stack.canUndo && !stack.canRedo, "空栈：两头都不可用")
    let s1 = mkStroke(0.1)
    stack.recordAdded(label: "Draw", kind: .draw, strokes: [s1])
    check(stack.canUndo && stack.undoLabel == "Draw", "收笔记一步，菜单标题取得到动作名")

    var arr = [s1]
    guard let p = stack.pop(redo: false) else { fatalError("pop 不该为空") }
    InkDelta.apply(p.strokes, to: &arr, undo: true)
    check(arr.isEmpty, "撤销把这一笔拿掉了")
    check(!stack.canUndo && stack.canRedo && stack.redoLabel == "Draw", "弹出的那条进了重做栈")
    guard let r = stack.pop(redo: true) else { fatalError("redo 不该为空") }
    InkDelta.apply(r.strokes, to: &arr, undo: false)
    check(arr == [s1], "重做把这一笔放回来（值一致）")
    check(stack.canUndo && !stack.canRedo, "重做后又回到「可撤销」")
}

// ---- 擦除合并 ----
print("擦除合并：同一次拖动 = 一步")
do {
    let stack = InkUndoStack()
    let a = mkStroke(0.1), b = mkStroke(0.3)
    let v0 = [a, b]
    let v1 = [b]              // 第一批擦掉 a
    let v2: [InkStroke] = []  // 第二批擦掉 b
    stack.recordAdded(label: "Draw", kind: .draw, strokes: [a])   // 先垫一步，验合并不会串到它头上
    stack.record(label: "Erase", kind: .erase, strokesBefore: v0, strokesAfter: v1)
    stack.record(label: "Erase", kind: .erase, strokesBefore: v1, strokesAfter: v2)
    check(stack.undos.count == 2, "两批擦除并成一条（连同前面那步 Draw 共两条）")
    var arr = v2
    InkDelta.apply(stack.pop(redo: false)!.strokes, to: &arr, undo: true)
    check(arr.count == 2 && Set(arr.map(\.id)) == Set(v0.map(\.id)), "一次撤销把整条拖动擦掉的都还回来")

    let stack2 = InkUndoStack()
    stack2.record(label: "Erase", kind: .erase, strokesBefore: v0, strokesAfter: v1)
    stack2.seal()   // 抬笔
    stack2.record(label: "Erase", kind: .erase, strokesBefore: v1, strokesAfter: v2)
    check(stack2.undos.count == 2, "封口（抬笔）之后的下一批擦除另起一步")
}

// ---- 无变化 / 新动作作废重做链 / 栈上限 ----
print("边界")
do {
    let stack = InkUndoStack()
    let v = [mkStroke(0.1)]
    stack.record(label: "Erase", kind: .erase, strokesBefore: v, strokesAfter: v)
    check(!stack.canUndo, "没擦到东西（前后一致）→ 不入栈")

    stack.recordAdded(label: "Draw", kind: .draw, strokes: [mkStroke(0.2)])
    _ = stack.pop(redo: false)
    check(stack.canRedo, "撤销后有得重做")
    stack.recordAdded(label: "Draw", kind: .draw, strokes: [mkStroke(0.3)])
    check(!stack.canRedo, "撤销之后又画了新东西 → 重做链作废（标准语义）")

    let deep = InkUndoStack()
    for i in 0..<150 { deep.recordAdded(label: "Draw", kind: .draw, strokes: [mkStroke(Double(i) / 200)]) }
    check(deep.undos.count == 100, "栈深封顶 100（最老的被挤掉）")

    // 注解也一并记账（框选选中集里两类都有）
    let n = mkNote("hi")
    let noteStack = InkUndoStack()
    noteStack.record(label: "Delete", kind: .delete, notesBefore: [n], notesAfter: [])
    var notes: [TextNote] = []
    InkDelta.apply(noteStack.pop(redo: false)!.notes, to: &notes, undo: true)
    check(notes == [n], "文字注解走同一套增量")
}

// ---- 剪贴板往返 ----
print("InkClipboard：写 → 读回")
do {
    // 用私有命名剪贴板，别动用户的系统剪贴板
    let pb = NSPasteboard(name: NSPasteboard.Name("tech.xvanturing.unireader.spike"))
    check(!InkClipboard.hasInk(in: pb), "起手是空的")
    var st = mkStroke(0.4, page: 7)
    st.width = 12.5
    st.type = .marker
    let note = mkNote("批注正文", page: 7)
    InkClipboard.write(strokes: [st], notes: [note], space: .page, aspect: 1.5, to: pb)
    check(InkClipboard.hasInk(in: pb), "写进去认得出来")
    check(pb.string(forType: .string) == "批注正文", "纯文本兜底：注解正文也放上了")

    guard let back = InkClipboard.read(from: pb) else { fatalError("读不回来") }
    check(back.strokes.count == 1 && back.notes.count == 1, "两类各回来一条")
    let rs = back.strokes[0]
    check(rs.id != st.id && back.notes[0].id != note.id, "**换新 id**（不然同篇文档里粘一次就把源覆盖了）")
    check(rs.points == st.points && rs.width == st.width && rs.type == st.type && rs.color == st.color,
          "点集/线宽/笔型/颜色逐字段还原")
    check(rs.page == st.page, "页号带着走（粘贴时由调用方改成目标页）")
    check(back.notes[0].text == note.text && back.notes[0].anchor == note.anchor, "注解正文与锚点还原")
    check(back.space == .page && abs(back.aspect - 1.5) < 1e-9, "坐标空间与源页纵横比带着走")

    // 草稿纸那边：画布点 + 无纵横比；padId 不进剪贴板（落到纸上还是页上由粘贴方定）
    var padStroke = mkStroke(120)
    padStroke.padId = UUID()
    InkClipboard.write(strokes: [padStroke], space: .canvas, to: pb)
    guard let padBack = InkClipboard.read(from: pb) else { fatalError("读不回来") }
    check(padBack.space == .canvas, "纸上复制的记成 canvas 空间")
    check(padBack.strokes[0].padId == nil, "padId 被抹掉（不然粘到页里就是看不见的孤儿）")
    check(padBack.strokes[0].points == padStroke.points, "画布坐标原样带回（不在剪贴板里折算）")
    pb.clearContents()
}

// ---- 页 ⇄ 纸 坐标换算 ----
print("InkClipboard.scaled：页内归一化 ⇄ 画布点")
do {
    let a = 1.5                                   // 页高/页宽
    let w = ScratchPad.pageRefWidth               // 三端契约：1 页宽 = 800 画布点
    var st = mkStroke(0.25)
    st.points = [SIMD3(0.25, 0.4, 0.5)]
    let onCanvas = InkClipboard.scaled([st], toCanvas: true, aspect: a)[0]
    // 点是 Float（`InkPoint`）：几百画布点这一档 Float 的分辨率约 3e-5，容差按 1e-3
    check(abs(onCanvas.points[0].dx - 0.25 * w) < 1e-3, "x 乘页宽基准")
    check(abs(onCanvas.points[0].dy - 0.4 * w * a) < 1e-3, "y 另乘纵横比（归一化 y 相对的是页高）")
    check(onCanvas.width == st.width, "线宽不换算（两边都是绝对显示点）")
    let backToPage = InkClipboard.scaled([onCanvas], toCanvas: false, aspect: a)[0]
    check(abs(backToPage.points[0].x - 0.25) < 1e-12 && abs(backToPage.points[0].y - 0.4) < 1e-12,
          "折回去等于原值（往返无损）")
    check(onCanvas.points[0].z == st.points[0].z, "压感不动")
}

// ---- 旧 payload（没有 space/aspect 键）----
print("旧 payload 兜底")
do {
    let pb = NSPasteboard(name: NSPasteboard.Name("tech.xvanturing.unireader.spike2"))
    // 手搓一份「上一版格式」的 JSON：只有 v + rows
    let st = mkStroke(0.3)
    guard let note = st.toNote(documentId: "clip"),
          let old = try? JSONSerialization.data(withJSONObject: [
              "v": 1,
              "rows": [["kind": note.kind, "page": note.page, "x": 0, "y": 0, "w": 0, "h": 0,
                        "payload": note.payload.base64EncodedString()]]
          ]) else { fatalError("造不出旧 payload") }
    pb.clearContents()
    pb.setData(old, forType: InkClipboard.pbType)
    let back = InkClipboard.read(from: pb)
    check(back != nil, "缺 space/aspect 键的旧内容仍能读回（否则 ⌘V 会静默无反应）")
    check(back?.space == .page, "缺键兜底成 page 空间")
    pb.clearContents()
}

print(fail == 0 ? "\n全部通过：\(pass)/\(pass)" : "\n失败 \(fail) 项（通过 \(pass)）")
exit(fail == 0 ? 0 : 1)
