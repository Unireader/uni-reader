// 框选截图的几何测试（纯函数，不碰 PDFKit）。运行：
//   cp spike/page-snip-test.swift /tmp/main.swift && swiftc Sources/AI/PageSnip.swift /tmp/main.swift -o /tmp/pst && /tmp/pst
// （须命名为 main.swift：swiftc 多文件时顶层代码只允许在 main.swift）
//
// 覆盖三块：
//  ① `region(from:to:)` 规范化：往上拖 / 往左拖 / 反向跨页都要得到同一个区域；
//  ② `slices` 拆页：页内一条、跨两页两条、跨多页中间整页、贴边零高切片必须丢掉；
//  ③ `scale` 倍率：小区域不被拉爆、大区域不糊、长边按目标像素定（与当前缩放无关）。
import Foundation
import CoreGraphics

var pass = 0, fail = 0
func check(_ c: Bool, _ m: String) { if c { pass += 1; print("  ✅ \(m)") } else { fail += 1; print("  ❌ \(m)") } }
func near(_ a: Double, _ b: Double, _ eps: Double = 1e-9) -> Bool { abs(a - b) < eps }

// ────────────────────────────────────────────────────────────
print("① region 规范化")

let topLeft = (page: 4, nx: 0.2, ny: 0.3)
let botRight = (page: 4, nx: 0.7, ny: 0.8)

let down = PageSnip.region(from: topLeft, to: botRight)
let up = PageSnip.region(from: botRight, to: topLeft)
check(down == up, "顺拖与反拖得到同一个 Region")
check(down.startPage == 4 && down.endPage == 4, "页内框选：起止同页")
check(near(down.x0, 0.2) && near(down.x1, 0.7), "x 取 min/max")
check(near(down.y0, 0.3) && near(down.y1, 0.8), "y0 是上边、y1 是下边")

// 往左上拖（两轴都反向）
let leftUp = PageSnip.region(from: (page: 4, nx: 0.7, ny: 0.8), to: (page: 4, nx: 0.2, ny: 0.3))
check(leftUp == down, "左上方向拖同样规范化")

// 反向跨页：从第 6 页往回拖到第 4 页
let crossFwd = PageSnip.region(from: (page: 4, nx: 0.1, ny: 0.6), to: (page: 6, nx: 0.9, ny: 0.25))
let crossBack = PageSnip.region(from: (page: 6, nx: 0.9, ny: 0.25), to: (page: 4, nx: 0.1, ny: 0.6))
check(crossFwd == crossBack, "跨页反向拖规范化一致")
check(crossFwd.startPage == 4 && crossFwd.endPage == 6, "跨页：起止页按页号排")
check(near(crossFwd.y0, 0.6), "y0 取的是起始页那个端点的 ny")
check(near(crossFwd.y1, 0.25), "y1 取的是结束页那个端点的 ny")

// ────────────────────────────────────────────────────────────
print("② slices 拆页")

let one = PageSnip.slices(down)
check(one.count == 1, "页内框选 → 一条切片")
check(one[0].page == 4, "切片在第 4 页")
check(near(Double(one[0].rect.minY), 0.3) && near(Double(one[0].rect.height), 0.5), "切片高度 = y1 - y0")
check(near(Double(one[0].rect.minX), 0.2) && near(Double(one[0].rect.width), 0.5), "切片宽度 = x1 - x0")

let two = PageSnip.slices(PageSnip.region(from: (page: 1, nx: 0.1, ny: 0.7),
                                          to: (page: 2, nx: 0.9, ny: 0.4)))
check(two.count == 2, "跨两页 → 两条切片")
check(two[0].page == 1 && near(Double(two[0].rect.minY), 0.7) && near(Double(two[0].rect.maxY), 1.0),
      "首页切片：从 y0 一直到页底")
check(two[1].page == 2 && near(Double(two[1].rect.minY), 0.0) && near(Double(two[1].rect.maxY), 0.4),
      "末页切片：从页顶到 y1")
check(two.allSatisfy { near(Double($0.rect.minX), 0.1) && near(Double($0.rect.width), 0.8) },
      "各页共用同一组 x（fit-width 下各页显示宽相同）")

let three = PageSnip.slices(PageSnip.region(from: (page: 7, nx: 0, ny: 0.9),
                                            to: (page: 9, nx: 1, ny: 0.1)))
check(three.count == 3, "跨三页 → 三条切片")
check(near(Double(three[1].rect.minY), 0) && near(Double(three[1].rect.height), 1),
      "中间页是整页")

// 贴边：起点正好在页底 → 首页那条零高，必须丢掉而不是渲成 0 像素
let edge = PageSnip.slices(PageSnip.region(from: (page: 3, nx: 0.1, ny: 1.0),
                                           to: (page: 4, nx: 0.6, ny: 0.5)))
check(edge.count == 1 && edge[0].page == 4, "起点贴在页底 → 零高的首页切片被丢掉")

let edge2 = PageSnip.slices(PageSnip.region(from: (page: 3, nx: 0.1, ny: 0.5),
                                            to: (page: 4, nx: 0.6, ny: 0.0)))
check(edge2.count == 1 && edge2[0].page == 3, "终点贴在页顶 → 零高的末页切片被丢掉")

check(PageSnip.slices(PageSnip.region(from: (page: 2, nx: 0.4, ny: 0.4),
                                      to: (page: 2, nx: 0.4, ny: 0.9))).isEmpty,
      "零宽框选 → 无切片（竖着划一道不是截图）")
check(PageSnip.slices(PageSnip.Region(startPage: 5, endPage: 3, x0: 0, x1: 1, y0: 0, y1: 1)).isEmpty,
      "起止页倒挂 → 无切片（防御）")

// 越界的归一化值（理论上 containerPointToPageNorm 已 clamp，这里再兜一层）
let clamped = PageSnip.slices(PageSnip.Region(startPage: 0, endPage: 0, x0: -0.3, x1: 1.8, y0: -0.2, y1: 1.5))
check(clamped.count == 1, "越界值仍出一条切片")
check(near(Double(clamped[0].rect.minX), 0) && near(Double(clamped[0].rect.maxX), 1)
      && near(Double(clamped[0].rect.minY), 0) && near(Double(clamped[0].rect.maxY), 1),
      "越界值被 clamp 回 0~1")

// ────────────────────────────────────────────────────────────
print("③ scale 倍率")

// A4 竖版约 595×842pt。整页：长边 842 → 2000/842 ≈ 2.38
let full = PageSnip.scale(ptWidth: 595, ptHeight: 842)
check(near(full, 2000.0 / 842.0, 1e-6), "整页按长边定倍率")
check(full * 842 <= PageSnip.maxLongEdge + 0.5, "整页输出长边不超过上限")

// 一个小公式块 120×60pt：2000/120 = 16.7，必须被 maxScale 夹住
let tiny = PageSnip.scale(ptWidth: 120, ptHeight: 60)
check(near(tiny, PageSnip.maxScale), "小区域被 maxScale 夹住（别拉成马赛克）")

// 跨五页的长条：总高 4210pt，2000/4210 ≈ 0.475，必须被 minScale 托住
let tall = PageSnip.scale(ptWidth: 595, ptHeight: 4210)
check(near(tall, PageSnip.minScale), "超长跨页被 minScale 托住（宁可超上限也不糊）")

check(PageSnip.scale(ptWidth: 0, ptHeight: 0) == PageSnip.minScale, "零尺寸退回 minScale，不炸")

// ④ 误拖闸
print("④ 误拖闸")
check(!PageSnip.isMeaningful(CGSize(width: 3, height: 40)), "细长一道不算截图")
check(!PageSnip.isMeaningful(CGSize(width: 40, height: 2)), "扁扁一道不算截图")
check(PageSnip.isMeaningful(CGSize(width: 20, height: 20)), "够大的框才算")
check(PageSnip.isMeaningful(CGSize(width: -60, height: -40)), "反向拖（负 size）同样算")

print("\n\(pass) 通过，\(fail) 失败")
if fail > 0 { exit(1) }
