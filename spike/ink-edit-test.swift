// InkEdit 纯函数测试：rulerSnap（45° 吸附）/ splitStroke（局部擦除切段）/ translated（clamp 平移）。运行：
//   cp spike/ink-edit-test.swift /tmp/main.swift && swiftc Sources/Support/L.swift Sources/Store/LibraryModels.swift Sources/App/PenPreset.swift Sources/App/InkModel.swift Sources/App/TextNoteModel.swift Sources/App/InkEdit.swift /tmp/main.swift -o /tmp/iet && /tmp/iet
// （须命名为 main.swift：swiftc 多文件时顶层代码只允许在 main.swift；PenPreset.swift 提供 PenBrushType）
// 覆盖：split（全擦/擦中段分两段/擦端点截断/单点段/跨页不串/未命中原样）、
//       rulerSnap（0°/45°/90° 阈值内外、长度保持）、translated（笔迹/文字注解/rect：clamp 0...1、压感与 id 不变）。
import Foundation

var pass = 0, fail = 0
func check(_ c: Bool, _ m: String) { if c { pass += 1; print("  ✅ \(m)") } else { fail += 1; print("  ❌ \(m)") } }

func near(_ a: Double, _ b: Double, _ eps: Double = 1e-9) -> Bool { abs(a - b) < eps }
func ptNear(_ p: SIMD2<Double>, _ x: Double, _ y: Double, _ eps: Double = 1e-9) -> Bool { near(p.x, x, eps) && near(p.y, y, eps) }

let color = InkColor(r: 24, g: 90, b: 210, a: 0.95)

// ---- rulerSnap ----
print("rulerSnap（45° 倍数吸附，阈值 7°）")
let origin = SIMD2<Double>(0.2, 0.5)
// 恰在 0°：原样（贴合后位置不变）
check(ptNear(InkEdit.rulerSnap(start: origin, current: SIMD2(0.6, 0.5)), 0.6, 0.5), "0° 恰在线上 → 不动")
// 0° 阈值内（≈3°）：贴合水平，长度保持（0.3）
let in0 = InkEdit.rulerSnap(start: origin, current: SIMD2(origin.x + 0.3 * cos(3 * .pi / 180), origin.y + 0.3 * sin(3 * .pi / 180)))
check(ptNear(in0, origin.x + 0.3, origin.y), "0° 阈值内（3°）→ 贴合水平且长度保持")
// 0° 阈值外（20°）：原样返回
let out20 = SIMD2(origin.x + 0.3 * cos(20 * .pi / 180), origin.y + 0.3 * sin(20 * .pi / 180))
check(ptNear(InkEdit.rulerSnap(start: origin, current: out20), out20.x, out20.y), "0° 阈值外（20°）→ 原样返回")
// 45° 阈值内（42°）：贴合 45°，长度保持
let len45 = 0.4
let in45 = InkEdit.rulerSnap(start: origin, current: SIMD2(origin.x + len45 * cos(42 * .pi / 180), origin.y + len45 * sin(42 * .pi / 180)))
check(ptNear(in45, origin.x + len45 * cos(.pi / 4), origin.y + len45 * sin(.pi / 4)), "45° 阈值内（42°）→ 贴合 45° 且长度保持")
// 45° 阈值外（37°，差 8°）：原样返回
let out37 = SIMD2(origin.x + len45 * cos(37 * .pi / 180), origin.y + len45 * sin(37 * .pi / 180))
check(ptNear(InkEdit.rulerSnap(start: origin, current: out37), out37.x, out37.y), "45° 阈值外（37°）→ 原样返回")
// 90° 阈值内（87°）：贴合竖直（向下，y 增）
let len90 = 0.25
let in90 = InkEdit.rulerSnap(start: origin, current: SIMD2(origin.x + len90 * cos(87 * .pi / 180), origin.y + len90 * sin(87 * .pi / 180)))
check(ptNear(in90, origin.x, origin.y + len90), "90° 阈值内（87°）→ 贴合竖直且长度保持")
// 90° 阈值外（80°）：原样返回
let out80 = SIMD2(origin.x + len90 * cos(80 * .pi / 180), origin.y + len90 * sin(80 * .pi / 180))
check(ptNear(InkEdit.rulerSnap(start: origin, current: out80), out80.x, out80.y), "90° 阈值外（80°）→ 原样返回")
// 自定义阈值：thresholdDeg=10 时 8° 偏差也贴合
let custom = InkEdit.rulerSnap(start: origin, current: out37, thresholdDeg: 10)
check(ptNear(custom, origin.x + len45 * cos(.pi / 4), origin.y + len45 * sin(.pi / 4)), "thresholdDeg=10 → 37°(差8°) 贴合 45°")
// 起点即终点：不崩，原样返回
check(ptNear(InkEdit.rulerSnap(start: origin, current: origin), origin.x, origin.y), "起点即终点 → 原样返回（不崩）")

// ---- splitStroke ----
print("splitStroke（局部擦除切段，擦除点 z 分量 = 页号）")
// 基准笔画：页 1，x = 0.1...0.9 共 9 点（y=0.5）
let basePts: [SIMD3<Double>] = (1...9).map { SIMD3(Double($0) * 0.1, 0.5, 0.5) }
let base = InkStroke(page: 1, color: color, width: 8.5, type: .fountain, points: basePts)

// 1) 全擦：一个半径盖满全笔画的擦除点 → 空
let allGone = InkEdit.splitStroke(base, erasePts: [SIMD3(0.5, 0.5, 1)], r: 0.5)
check(allGone.isEmpty, "全命中 → 返回空（整笔消除）")

// 2) 擦中段：只命中 x=0.5 一点 → 分两段，各 4 点，新 id，字段保留
let mid = InkEdit.splitStroke(base, erasePts: [SIMD3(0.5, 0.5, 1)], r: 0.06)
check(mid.count == 2, "擦中段 → 两段")
check(mid[0].points.count == 4 && mid[1].points.count == 4, "两段各 4 点")
check(near(mid[0].points.first!.x, 0.1) && near(mid[0].points.last!.x, 0.4)
      && near(mid[1].points.first!.x, 0.6) && near(mid[1].points.last!.x, 0.9), "两段端点正确（0.1-0.4 / 0.6-0.9）")
check(mid[0].id != base.id && mid[1].id != base.id && mid[0].id != mid[1].id, "切段全部换新 UUID")
check(mid.allSatisfy { $0.page == 1 && $0.color == color && $0.width == 8.5 && $0.type == .fountain }, "切段保留 page/color/width/type")

// 3) 擦端点：命中 x=0.1 → 截断为一段（0.2-0.9，8 点）
let head = InkEdit.splitStroke(base, erasePts: [SIMD3(0.1, 0.5, 1)], r: 0.06)
check(head.count == 1 && head[0].points.count == 8 && near(head[0].points.first!.x, 0.2), "擦端点 → 截断为一段 8 点")
let tail = InkEdit.splitStroke(base, erasePts: [SIMD3(0.9, 0.5, 1)], r: 0.06)
check(tail.count == 1 && tail[0].points.count == 8 && near(tail[0].points.last!.x, 0.8), "擦尾点 → 截断为一段 8 点")

// 4) 单点段：两端擦除只剩 x=0.5 一个孤立点 → 保留为单点（圆点）笔划
let single = InkEdit.splitStroke(base, erasePts: [SIMD3(0.25, 0.5, 1), SIMD3(0.75, 0.5, 1)], r: 0.16)
check(single.count == 1 && single[0].points.count == 1 && near(single[0].points[0].x, 0.5), "孤立单点段保留为圆点笔划")

// 5) 跨页不串：擦除点在页 2，笔画在页 1 → 原样返回（同 id，对账零变化）
let cross = InkEdit.splitStroke(base, erasePts: [SIMD3(0.5, 0.5, 2)], r: 0.5)
check(cross.count == 1 && cross[0].id == base.id && cross[0] == base, "跨页擦除点不命中 → 原样返回（id 不变）")

// 6) 同页但未命中：距离 > r → 原样返回（同 id）
let miss = InkEdit.splitStroke(base, erasePts: [SIMD3(0.5, 0.9, 1)], r: 0.06)
check(miss.count == 1 && miss[0].id == base.id, "同页未命中 → 原样返回（id 不变）")

// ---- translated ----
print("translated（平移 + clamp 0...1）")
let mv = InkStroke(id: base.id, page: 1, color: color, width: 4, type: .ballpoint,
                   points: [SIMD3(0.05, 0.5, 0.3), SIMD3(0.95, 0.9, 0.8)])
let t1 = InkEdit.translated(mv, dx: 0.2, dy: -0.2)
check(near(t1.points[0].x, 0.25) && near(t1.points[0].y, 0.3), "正常平移 (0.05,0.5)+ (0.2,-0.2) → (0.25,0.3)")
check(near(t1.points[1].x, 1.0) && near(t1.points[1].y, 0.7), "x 越上界 clamp 到 1.0")
let t2 = InkEdit.translated(mv, dx: -0.2, dy: 0.2)
check(near(t2.points[0].x, 0.0), "x 越下界 clamp 到 0.0")
check(near(t2.points[1].y, 1.0), "y 越上界 clamp 到 1.0")
check(near(t1.points[0].z, 0.3) && near(t1.points[1].z, 0.8), "压感 z 不动")
check(t1.id == mv.id && t1.page == mv.page && t1.width == mv.width && t1.type == mv.type, "id/page/width/type 不变")

// ---- translated（TextNote：anchor + rects 一起平移，页内 clamp）----
print("translated（TextNote 平移 + clamp 0...1）")
let note = TextNote(id: UUID(), page: 2,
                    anchor: CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.1),
                    quote: "q", text: "t",
                    rects: [CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.04),
                            CGRect(x: 0.1, y: 0.26, width: 0.2, height: 0.04)])
let nt = InkEdit.translated(note, dx: 0.8, dy: -0.15)
check(near(nt.anchor.minX, 0.9) && near(nt.anchor.maxX, 1.0), "anchor x：0.1+0.8=0.9，maxX clamp 到 1.0（宽度收缩不越界）")
check(near(nt.anchor.minY, 0.05) && near(nt.anchor.maxY, 0.15), "anchor y：正常平移")
check(nt.rects.count == 2 && near(nt.rects[0].minY, 0.05) && near(nt.rects[1].maxX, 1.0), "每个 rect 连同平移并 clamp")
check(nt.id == note.id && nt.page == note.page && nt.quote == note.quote && nt.text == note.text, "id/page/quote/text 不动")
check(nt.updatedAt > note.updatedAt, "updatedAt bump（对账识别为变更）")
// 点注解：零尺寸 anchor 平移 + 下界 clamp
let pin = TextNote(id: UUID(), page: 0, anchor: CGRect(x: 0.05, y: 0.05, width: 0, height: 0), quote: "", text: "p", rects: [])
let pt0 = InkEdit.translated(pin, dx: -0.2, dy: 0.3)
check(near(pt0.anchor.minX, 0.0) && near(pt0.anchor.minY, 0.35) && pt0.anchor.width == 0, "点注解零尺寸 anchor 平移 + x clamp 到 0")
// translatedRect：双向 clamp
let rr = InkEdit.translatedRect(CGRect(x: 0.9, y: 0.05, width: 0.2, height: 0.1), dx: 0.2, dy: -0.1)
check(near(rr.minX, 1.0) && rr.width == 0 && near(rr.minY, 0.0), "rect 双向 clamp（贴角收缩为零宽）")

print("\n\(pass) passed, \(fail) failed")
exit(fail == 0 ? 0 : 1)
