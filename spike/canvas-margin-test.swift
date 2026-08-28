// CanvasMargin 纯函数测试（画板模式 v12 的页边软边界）+ InkEdit 的 xRange 放宽。运行：
//   cp spike/canvas-margin-test.swift /tmp/main.swift && swiftc Sources/Support/L.swift Sources/Store/LibraryModels.swift Sources/App/PenPreset.swift Sources/App/InkModel.swift Sources/App/InkLayerModel.swift Sources/App/NoteTypeModel.swift Sources/App/TextNoteModel.swift Sources/App/InkEdit.swift Sources/App/CanvasMargin.swift /tmp/main.swift -o /tmp/cmt && /tmp/cmt
// （须命名为 main.swift：swiftc 多文件时顶层代码只允许在 main.swift）
// 覆盖：overflow（页内为 0 / 左越界 / 右越界 / 取两侧最大 / 空集）、
//       margin（起步一档、按档跳、恰在档位边界、上限夹取）、
//       xRange（关画板 = 0...1，开画板对称放宽）、
//       InkEdit.translated/scaled 的 xRange 默认值不变（三端契约）与放宽后可出页。
import Foundation

var pass = 0, fail = 0
func check(_ c: Bool, _ m: String) { if c { pass += 1; print("  ✅ \(m)") } else { fail += 1; print("  ❌ \(m)") } }
func near(_ a: Double, _ b: Double, _ eps: Double = 1e-9) -> Bool { abs(a - b) < eps }

let color = InkColor(r: 24, g: 90, b: 210, a: 0.95)
func stroke(_ pts: [(Double, Double)], page: Int = 0) -> InkStroke {
    InkStroke(page: page, color: color, width: 3, points: pts.map { SIMD3($0.0, $0.1, 0.5) })
}

// ---- overflow ----
print("overflow（笔迹的最大横向越界量）")
check(near(CanvasMargin.overflow([]), 0), "空集 → 0")
check(near(CanvasMargin.overflow([stroke([(0.1, 0.2), (0.9, 0.8)])]), 0), "全在页内 → 0")
check(near(CanvasMargin.overflow([stroke([(-0.4, 0.2), (0.5, 0.5)])]), 0.4), "左越界 → 取 −minX")
check(near(CanvasMargin.overflow([stroke([(0.5, 0.2), (1.7, 0.5)])]), 0.7), "右越界 → 取 maxX−1")
check(near(CanvasMargin.overflow([stroke([(-0.2, 0.1)]), stroke([(1.9, 0.1)])]), 0.9), "两侧都有 → 取更大的一侧")
check(near(CanvasMargin.overflow(stroke([(2.5, 0.1)])), 1.5), "单笔重载（落笔中每帧算这一笔）")
check(near(CanvasMargin.overflow(nil), 0), "单笔重载 nil → 0")

// ---- margin（档位化） ----
print("margin（越界量 → 每侧页边宽度，step=\(CanvasMargin.step) slack=\(CanvasMargin.slack)）")
check(near(CanvasMargin.margin(overflow: 0), 0.5), "没写出去过 → 起步一档 0.5")
check(near(CanvasMargin.margin(overflow: 0.1), 0.5), "越界 0.1（+slack=0.45 未满一档）→ 仍 0.5")
check(near(CanvasMargin.margin(overflow: 0.2), 1.0), "越界 0.2（+slack=0.55 过一档）→ 跳到 1.0")
check(near(CanvasMargin.margin(overflow: 0.15), 0.5), "越界 0.15（+slack=0.5 恰在档位上）→ 不多跳一档")
check(near(CanvasMargin.margin(overflow: 1.2), 2.0), "越界 1.2（+slack=1.55）→ 2.0")
check(near(CanvasMargin.margin(overflow: 100), CanvasMargin.limit), "坏数据（越界 100）→ 夹到上限 \(CanvasMargin.limit)")
check(near(CanvasMargin.margin(overflow: -5), 0.5), "负越界量（不该出现）→ 按 0 处理")
var mono = true
var last = 0.0
for i in 0...40 {
    let m = CanvasMargin.margin(overflow: Double(i) * 0.1)
    if m < last { mono = false }
    last = m
}
check(mono, "越界量越大页边越宽（单调不减）")

// ---- xRange ----
print("xRange（笔迹落点的合法 x 区间）")
check(CanvasMargin.xRange(margin: 0) == 0...1, "画板关 → 0...1（与画板模式之前同行为）")
let r = CanvasMargin.xRange(margin: 0.5)
check(near(r.lowerBound, -0.5) && near(r.upperBound, 1.5), "画板开 0.5 → −0.5...1.5（左右对称）")

// ---- InkEdit 的 xRange（默认值必须与三端契约一致） ----
print("InkEdit.translated / scaled 的 xRange")
let s = stroke([(0.9, 0.5), (0.95, 0.6)])
let tDefault = InkEdit.translated(s, dx: 0.5, dy: 0)
check(near(tDefault.points[0].x, 1) && near(tDefault.points[1].x, 1),
      "默认 xRange=0...1：平移出页仍 clamp 到页边（web/安卓两份实现不用同步）")
let tWide = InkEdit.translated(s, dx: 0.5, dy: 0, xRange: -1...2)
check(near(tWide.points[0].x, 1.4) && near(tWide.points[1].x, 1.45), "放宽后可平移到页外")
let tWideY = InkEdit.translated(s, dx: 0, dy: 0.8, xRange: -1...2)
check(near(tWideY.points[0].y, 1) && near(tWideY.points[1].y, 1), "y 永远 clamp 0...1（页边只横向延伸）")
check(tWide.id == s.id && near(tWide.points[0].z, 0.5), "平移不动 id 与压感")

let sc = InkEdit.scaled(stroke([(0.5, 0.5), (1.0, 0.6)]), anchor: SIMD2(0.5, 0.5), sx: 3, sy: 1)
check(near(sc.points[1].x, 1), "默认 xRange：缩放出页仍 clamp 到页边")
let scWide = InkEdit.scaled(stroke([(0.5, 0.5), (1.0, 0.6)]), anchor: SIMD2(0.5, 0.5), sx: 3, sy: 1,
                            xRange: -2...3)
check(near(scWide.points[1].x, 2.0), "放宽后可缩放到页外（0.5 + 0.5×3 = 2.0）")
check(near(scWide.points[0].x, 0.5), "anchor 点不动")

print("\n\(pass) passed, \(fail) failed")
exit(fail == 0 ? 0 : 1)
