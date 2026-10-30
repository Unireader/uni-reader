// 网页阅读器（`docs/WEB-READER-PLAN.md §4`）的跨端向量：用 **Mac 的代码**算笔宽 / 锥度 / 抖动 / 扫描页对齐，
// 写成 `spike/web-ink-vectors.txt`，网页的 node 测试（`server/web/test/inkmath.test.ts`）逐项比对。
// 运行（在仓库根目录）：
//   cp spike/web-ink-vectors.swift /tmp/main.swift && swiftc -O Sources/App/PenPreset.swift Sources/App/ScanAlign.swift \
//     /tmp/main.swift -o /tmp/wiv && /tmp/wiv > spike/web-ink-vectors.txt
// （须命名为 main.swift：swiftc 多文件时顶层代码只允许在 main.swift；`L` 与 `InkColor` 在下面补一份最小的）
import Foundation
import CoreGraphics

func L(_ key: String) -> String { key }
struct InkColor: Equatable, Codable { var r: Double, g: Double, b: Double, a: Double }

/// 浮点写成能原样读回的十进制（Swift 的 `description` 是最短可往返写法）。
func f(_ v: Double) -> String { "\(v)" }

print("# 网页阅读器跨端向量：由 spike/web-ink-vectors.swift 用 Mac 代码生成，别手改。")
print("# width|笔型|压感|粗细|笔宽    taper|笔型|i|n|锥度    jitter|x|y|值")
print("# align|rot,dx,dy,sw,sh,w|x,y|对齐后 x,y|再转回 x,y")

let types: [PenBrushType] = [.ballpoint, .fountain, .marker, .pencil]
for t in types {
    for p in [0.0, 0.13, 0.5, 0.77, 1.0] {
        for w in [1.0, 8.0, 22.0] {
            print("width|\(t.rawValue)|\(f(p))|\(f(w))|\(f(t.strokeWidth(pressure: p, base: w)))")
        }
    }
}
for t in [PenBrushType.fountain, .ballpoint] {
    for n in [1, 2, 3, 5, 40] {
        for i in Set([0, 1, n / 3, n / 2, n - 2, n - 1].filter { $0 >= 0 && $0 < n }).sorted() {
            print("taper|\(t.rawValue)|\(i)|\(n)|\(f(t.fountainTaper(index: i, count: n)))")
        }
    }
}
for (x, y) in [(0.0, 0.0), (0.1234, 0.5678), (0.9, 0.05 + 2.3), (0.5, 0.5 + 4.6), (0.731, 0.0042)] {
    print("jitter|\(f(x))|\(f(y))|\(f(InkRender.jitter(x, y)))")
}
let aligns = [
    PageAlign(rot: 0.9 * .pi / 180, dx: -7.25, dy: 1.5, sw: 504.7, sh: 707.75, w: 497.5),
    PageAlign(rot: -0.012, dx: 3, dy: 0, sw: 600, sh: 800, w: 610),
    PageAlign(rot: 0, dx: 0, dy: 0, sw: 500, sh: 700, w: 500),
]
for a in aligns {
    for (x, y) in [(0.0, 0.0), (a.sw, a.sh), (123.4, 456.7), (-30.0, 800.0)] {
        let q = a.toAligned(CGPoint(x: x, y: y))
        let r = a.toRaw(q)
        print("align|\(f(a.rot)),\(f(a.dx)),\(f(a.dy)),\(f(a.sw)),\(f(a.sh)),\(f(a.w))|\(f(x)),\(f(y))|"
              + "\(f(Double(q.x))),\(f(Double(q.y)))|\(f(Double(r.x))),\(f(Double(r.y)))")
    }
}
