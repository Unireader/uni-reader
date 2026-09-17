// PageLayout 纯数学测试（编译真实源文件，非副本）。
// 运行：swiftc spike/page-layout-test.swift Sources/App/PageLayout.swift Sources/App/PageBitmap.swift Sources/App/ScanAlign.swift -o /tmp/layout-test && /tmp/layout-test
// （`PageBitmap` 的 `align` 参数类型在 `ScanAlign.swift`，2026-09-17 起要一起编）

import Foundation
import PDFKit

nonisolated(unsafe) var pass = 0
nonisolated(unsafe) var fail = 0
func check(_ name: String, _ ok: Bool, _ detail: String = "") {
    if ok { pass += 1; print("  ✓ \(name)") }
    else { fail += 1; print("  ✗ \(name) \(detail)") }
}

// 合成 4 页 PDF：400x300、200x800、400x300(rotation=90 → 显示 300x400)、500x500
func makeDoc() -> PDFDocument {
    let data = NSMutableData()
    let consumer = CGDataConsumer(data: data as CFMutableData)!
    var box1 = CGRect(x: 0, y: 0, width: 400, height: 300)
    let ctx = CGContext(consumer: consumer, mediaBox: &box1, nil)!
    for size in [CGSize(width: 400, height: 300), CGSize(width: 200, height: 800),
                 CGSize(width: 400, height: 300), CGSize(width: 500, height: 500)] {
        var media = CGRect(origin: .zero, size: size)
        let info = [kCGPDFContextMediaBox as String: NSData(bytes: &media, length: MemoryLayout<CGRect>.size)]
        ctx.beginPDFPage(info as CFDictionary)
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(media)
        ctx.endPDFPage()
    }
    ctx.closePDF()
    let doc = PDFDocument(data: data as Data)!
    doc.page(at: 2)!.rotation = 90
    return doc
}

@main
struct LayoutTest {
static func main() {
let doc = makeDoc()
let lay = PageLayout(doc: doc)
let R = PageLayout.refWidth, G = PageLayout.gap

print("== 布局 ==")
check("页数 4", lay.pageCount == 4)
// 高度：h = 显示高/显示宽 × R
let expH: [CGFloat] = [300.0/400*R, 800.0/200*R, 400.0/300*R, 500.0/500*R]
for i in 0..<4 {
    check("页\(i)高", abs(lay.heights[i] - expH[i]) < 0.01, "\(lay.heights[i]) vs \(expH[i])")
}
check("offset0=0", lay.offsets[0] == 0)
check("offset1", abs(lay.offsets[1] - (expH[0] + G)) < 0.01)
check("offset3", abs(lay.offsets[3] - (expH[0] + expH[1] + expH[2] + 3*G)) < 0.01)
check("totalHeight", abs(lay.totalHeight - (expH.reduce(0,+) + 3*G)) < 0.01)

print("== locate / docY 往返 ==")
for (p, f) in [(0, 0.0), (0, 0.5), (1, 0.25), (2, 0.999), (3, 0.0), (3, 1.0)] {
    let y = lay.docY(page: p, frac: f)
    let loc = lay.locate(docY: y)
    // frac=1.0 的页底恰好等于下一页判定边界前（页底属于本页）
    let ok = loc.page == p && abs(loc.frac - f) < 0.002
    check("往返 (\(p),\(f))", ok, "→ \(loc)")
}
print("== 边界 ==")
check("负 docY → (0,0)", lay.locate(docY: -100) == (0, 0))
check("超尾 → (3,1)", lay.locate(docY: lay.totalHeight + 500) == (3, 1.0))
let gapY = lay.offsets[0] + lay.heights[0] + G/2   // 页0与页1的间隙中
check("间隙 → 下一页 frac=0", lay.locate(docY: gapY) == (1, 0))
print("== 进度（跟随器输出）==")
check("progress 1.5 == docY(1,0.5)", abs(lay.docY(progress: 1.5) - lay.docY(page: 1, frac: 0.5)) < 0.001)
check("progress clamp 上界", abs(lay.docY(progress: 99) - lay.docY(page: 3, frac: 1)) < 0.2)
print("== pageRange ==")
check("首屏", lay.pageRange(fromDocY: 0, toDocY: expH[0] - 1) == 0...0)
check("跨页", lay.pageRange(fromDocY: expH[0] - 1, toDocY: lay.offsets[2] + 1) == 0...2)
check("全文档", lay.pageRange(fromDocY: -10, toDocY: lay.totalHeight + 10) == 0...3)

print("== 缩放 commit 锚定公式（纯代数不变量）==")
// 任意 c(内容点)、O(偏移)，P = c − O 屏幕不动点；commit 后 c' = c×r，O' = c'×… − P
// 不变量：c' − O' == P（锚点视口位置不变）
for (cx, cy, ox, oy, r) in [(500.0, 8000.0, 100.0, 7600.0, 1.7), (240.0, 120.0, -52.0, -52.0, 0.31)] {
    let P = (x: cx - ox, y: cy - oy)
    let c1 = (x: cx * r, y: cy * r)
    let O1 = (x: c1.x - P.x, y: c1.y - P.y)
    check("不变量 r=\(r)", abs((c1.x - O1.x) - P.x) < 1e-9 && abs((c1.y - O1.y) - P.y) < 1e-9)
}

print("\n结果：pass=\(pass) fail=\(fail)")
exit(fail == 0 ? 0 : 1)
}
}
