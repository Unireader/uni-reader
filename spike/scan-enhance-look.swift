// 扫描页增强（`ScanEnhance`）样张 + 贴片一致性检查。直接编 App 里的真代码：
//   cp spike/scan-enhance-look.swift /tmp/main.swift && swiftc -O Sources/App/PageBitmap.swift \
//     Sources/App/ScanEnhance.swift Sources/App/ScanAlign.swift /tmp/main.swift -o /tmp/sel && /tmp/sel <pdf> <页号(1起)> <输出目录>
// （须命名为 main.swift：swiftc 多文件时顶层代码只允许在 main.swift）
// 输出：orig.png（原图）、enh.png（默认参数增强）、tile.png（中间一块贴片）；
// 并打印贴片与整页同位置的平均像素差（贴片外扩 marginPt 做得对的话应接近 0）。
import AppKit
import CoreImage
import PDFKit

let a = CommandLine.arguments
guard a.count >= 4, let doc = PDFDocument(url: URL(fileURLWithPath: a[1])),
      let page = doc.page(at: Int(a[2])! - 1) else { print("用法见文件头"); exit(1) }
let outDir = URL(fileURLWithPath: a[3])
let ci = CIContext()
func save(_ img: CGImage, _ name: String) {
    try! NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])!
        .write(to: outDir.appendingPathComponent(name))
}
let pw = 995
let p = ScanEnhanceParams.defaults
let orig = PageBitmap.render(page: page, pixelWidth: pw, align: nil)!
var t0 = Date()
let enh = PageBitmap.renderEnhanced(page: page, pixelWidth: pw, align: nil, params: p, ci: ci)!
print(String(format: "整页增强（首次，含预热） %.0f ms", Date().timeIntervalSince(t0) * 1000))
t0 = Date()
_ = PageBitmap.renderEnhanced(page: page, pixelWidth: pw, align: nil, params: p, ci: ci)!
print(String(format: "整页增强 %.0f ms  %dx%d（原图 %dx%d）", Date().timeIntervalSince(t0) * 1000,
             enh.width, enh.height, orig.width, orig.height))
save(orig, "orig.png"); save(enh, "enh.png")

// 贴片：页中间一块，同样的 px/pt
let disp = PageBitmap.displaySize(page, align: nil)
let scale = CGFloat(pw) / disp.width
// 起点落在整页的像素格上（否则下面逐像素比较本身就差半个像素，量出来的是比较方法的误差）
let sub = CGRect(x: 300 / scale, y: 560 / scale, width: 400 / scale, height: 280 / scale)
let tile = PageBitmap.renderTileEnhanced(page: page, subRect: sub, scale: scale, align: nil, params: p, ci: ci)!
save(tile, "tile.png")

func pixels(_ img: CGImage) -> [UInt8] {
    var buf = [UInt8](repeating: 0, count: img.width * img.height * 4)
    let ctx = CGContext(data: &buf, width: img.width, height: img.height, bitsPerComponent: 8,
                        bytesPerRow: img.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
    return buf
}
func meanDiff(tile: CGImage, full: CGImage) -> Double {
    let fp = pixels(full), tp = pixels(tile)
    let ox = Int((sub.minX * scale).rounded()), oy = Int((sub.minY * scale).rounded())   // 左上原点
    var diff = 0.0, n = 0
    for y in 0..<tile.height where oy + y < full.height {
        for x in 0..<tile.width where ox + x < full.width {
            for c in 0..<3 {
                diff += abs(Double(tp[(y * tile.width + x) * 4 + c]) - Double(fp[((oy + y) * full.width + ox + x) * 4 + c]))
                n += 1
            }
        }
    }
    return diff / Double(max(1, n))
}
// 基准：不增强的贴片 vs 不增强的整页。页高不是整数像素时整页图本身就有亚像素偏移，这部分差异原来就有。
let plainTile = PageBitmap.renderTile(page: page, subRect: sub, scale: scale, align: nil)!
print(String(format: "贴片 vs 整页同位置 平均差：增强 %.2f / 255，不增强（基准）%.2f / 255",
             meanDiff(tile: tile, full: enh), meanDiff(tile: plainTile, full: orig)))
