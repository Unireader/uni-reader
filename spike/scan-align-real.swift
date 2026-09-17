// 扫描页对齐：拿真 PDF 跑一遍整篇测量 + 用 App 自己的出图原语（PageBitmap）出对比图。运行：
//   mkdir -p /tmp/sar && cp spike/scan-align-real.swift /tmp/sar/main.swift && \
//   swiftc -O Sources/App/ScanAlign.swift Sources/App/ScanAlignRunner.swift Sources/App/PageBitmap.swift /tmp/sar/main.swift -o /tmp/sar/run && \
//   /tmp/sar/run <pdf> <输出目录> [叠加起页 叠加止页]
// 输出：
//   - 终端：耗时、歪斜角分布、相邻页正文栏跳动（对齐前）、每页参数表前 40 行；
//   - overlay.png：叠加起止页之间的页叠在一起（左 = 现在按页宽铺满，右 = PageBitmap 按对齐参数出图）。
//     对齐得好 → 右边正文栏的左右边缘是清楚的一条线；没对齐 → 一片模糊。
// 只看图不下结论：对齐效果最终由用户在 App 里看。
import Foundation
import AppKit
import PDFKit

let args = CommandLine.arguments
guard args.count >= 3, let doc = PDFDocument(url: URL(fileURLWithPath: args[1])) else {
    print("用法：run <pdf> <输出目录> [叠加起页 叠加止页]"); exit(2)
}
let outDir = URL(fileURLWithPath: args[2])
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
let n = doc.pageCount

let t0 = Date()
var lastPrint = Date()
let ms = ScanAlignRunner.measure(url: URL(fileURLWithPath: args[1]), pageCount: n, isCancelled: { false }) { d in
    if Date().timeIntervalSince(lastPrint) > 1 { lastPrint = Date(); print("  测量 \(d)/\(n)") }
}!
let table = ScanAlignSolver.solve(ms)
print(String(format: "%d 页，测量 + 定中心 %.1fs，W=%.2f，戳 %@", n, Date().timeIntervalSince(t0), table.width, table.stamp))

let degs = table.pages.map { abs($0.rot) * 180 / .pi }.sorted()
func pct(_ a: [Double], _ p: Double) -> Double { a.isEmpty ? 0 : a[min(a.count - 1, Int(Double(a.count) * p))] }
print(String(format: "歪斜 |°|：中位 %.2f  p90 %.2f  最大 %.2f；≥0.5° 的页 %d", pct(degs, 0.5), pct(degs, 0.9), degs.last ?? 0,
             degs.filter { $0 >= 0.5 }.count))
// 对齐前「按页宽铺满到 W」时栏中心的显示位置 = (栏中心相对页中心 + sw/2) × W/sw；栏中心相对页中心 = −dx
let before = table.pages.map { (-$0.dx + $0.sw / 2) * table.width / $0.sw }
let jumps = zip(before, before.dropFirst()).map { abs($0 - $1) }.sorted()
print(String(format: "对齐前相邻页栏中心跳动：中位 %.1f  p90 %.1f  最大 %.1f pt", pct(jumps, 0.5), pct(jumps, 0.9), jumps.last ?? 0))
let withText = ms.filter { $0.textLines >= 3 }.count
let bothEdges = ms.filter { $0.left != nil && $0.right != nil }.count
print("有字的页 \(withText)，两边都测到 \(bothEdges)")
print("页  sw      sh      rot°    dx      行 左      右      支撑")
for (i, (p, m)) in zip(table.pages, ms).enumerated().prefix(40) {
    print(String(format: "%3d %7.2f %7.2f %7.3f %7.2f %3d %7@ %7@ %d/%d", i, p.sw, p.sh, p.rot * 180 / .pi, p.dx,
                 m.textLines, m.left.map { String(format: "%.1f", $0) } ?? "-",
                 m.right.map { String(format: "%.1f", $0) } ?? "-", m.supportL, m.supportR))
}

// 叠加对比图
let a = args.count >= 5 ? Int(args[3])! : min(30, n - 1)
let z = args.count >= 5 ? Int(args[4])! : min(a + 39, n - 1)
let pxW = 600
let outH = Int((table.pages[a...z].map(\.sh).max() ?? 720) / table.width * Double(pxW))
var accB = [Double](repeating: 0, count: pxW * outH), accA = accB
func accumulate(_ img: CGImage, into acc: inout [Double]) {
    var gray = [UInt8](repeating: 255, count: pxW * outH)
    gray.withUnsafeMutableBytes { raw in
        let ctx = CGContext(data: raw.baseAddress, width: pxW, height: outH, bitsPerComponent: 8, bytesPerRow: pxW,
                            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        ctx.setFillColor(gray: 1, alpha: 1); ctx.fill(CGRect(x: 0, y: 0, width: pxW, height: outH))
        let h = Int(Double(img.height) * Double(pxW) / Double(img.width))
        ctx.draw(img, in: CGRect(x: 0, y: outH - h, width: pxW, height: h))   // 顶端对齐
    }
    for i in 0..<acc.count { acc[i] += Double(gray[i]) }
}
let t1 = Date()
for i in a...z {
    guard let page = doc.page(at: i) else { continue }
    if let raw = PageBitmap.render(page: page, pixelWidth: pxW, align: nil) { accumulate(raw, into: &accB) }
    if let al = PageBitmap.render(page: page, pixelWidth: pxW, align: table.page(i)) { accumulate(al, into: &accA) }
}
let cnt = Double(z - a + 1)
let gap = 20, W = pxW * 2 + gap
var canvas = [UInt8](repeating: 90, count: W * outH)
for y in 0..<outH { for x in 0..<pxW {
    canvas[y * W + x] = UInt8(accB[y * pxW + x] / cnt)
    canvas[y * W + pxW + gap + x] = UInt8(accA[y * pxW + x] / cnt)
} }
let img = canvas.withUnsafeMutableBytes { raw in
    CGContext(data: raw.baseAddress, width: W, height: outH, bitsPerComponent: 8, bytesPerRow: W,
              space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!.makeImage()!
}
let url = outDir.appendingPathComponent("overlay-\(a)-\(z).png")
try! NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])!.write(to: url)
print(String(format: "叠加图 %@（第 %d~%d 页，出图 %.1fs）", url.path, a + 1, z + 1, Date().timeIntervalSince(t1)))
