// 夜间反色（`PageBitmap.invert`）改走「Core Image 直接渲进 mmap 缓冲」后的字节级验证：
//   ① 方向没翻（CI 坐标系 y 向上，渲进位图要是第一行落在底部就整页倒过来）；
//   ② 通道没串（BGRX 字节序：B,G,R,X）；
//   ③ 反色 + 色相 π 的语义没变（白→黑、红→红）；
//   ④ 出图进了 `liveImages` 的账，释放后归零。
// 运行：swiftc spike/night-invert-test.swift Sources/App/PageBitmap.swift -o /tmp/night-invert-test && /tmp/night-invert-test

import Foundation
import CoreGraphics
import CoreImage
import PDFKit

nonisolated(unsafe) var pass = 0
nonisolated(unsafe) var fail = 0
func check(_ name: String, _ ok: Bool, _ detail: String = "") {
    if ok { pass += 1; print("  ✓ \(name)") }
    else { fail += 1; print("  ✗ \(name) \(detail)") }
}

func px(_ img: CGImage, _ x: Int, _ y: Int) -> (b: Int, g: Int, r: Int) {
    let data = img.dataProvider!.data! as Data
    let o = y * img.bytesPerRow + x * 4
    return (Int(data[o]), Int(data[o + 1]), Int(data[o + 2]))
}
func near(_ p: (b: Int, g: Int, r: Int), _ b: Int, _ g: Int, _ r: Int) -> Bool {
    abs(p.b - b) <= 3 && abs(p.g - g) <= 3 && abs(p.r - r) <= 3
}

/// 老路径：同样的滤镜链 + `createCGImage`，再画进 BGRX 上下文（与新路径同格式，便于逐字节比）。
func referenceInvert(_ image: CGImage, w: Int, h: Int) -> CGImage {
    let ci = CIContext()
    let inv = CIFilter(name: "CIColorInvert")!
    inv.setValue(CIImage(cgImage: image), forKey: kCIInputImageKey)
    let hue = CIFilter(name: "CIHueAdjust")!
    hue.setValue(inv.outputImage!, forKey: kCIInputImageKey)
    hue.setValue(Double.pi, forKey: kCIInputAngleKey)
    let out = hue.outputImage!
    let cg = ci.createCGImage(out, from: out.extent)!
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                        bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
    ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
    return ctx.makeImage()!
}

@main
struct NightInvertTest {
static func main() {
// 输入：64×32，左上 1/4 纯红，其余纯白（普通 CG 位图即可，invert 不挑来源）。
let w = 64, h = 32
let space = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                    bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
ctx.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
ctx.fill(CGRect(x: 0, y: h / 2, width: w / 2, height: h / 2))   // CG 坐标 y 向上：这是左上象限
let src = ctx.makeImage()!

print("输入自检")
check("输入左上是红 (BGRX)", near(px(src, 2, 2), 0, 0, 255), "\(px(src, 2, 2))")
check("输入右下是白", near(px(src, w - 3, h - 3), 255, 255, 255), "\(px(src, w - 3, h - 3))")

print("反色")
let before = PageBitmap.liveImages
var out: CGImage? = PageBitmap.invert(src, ci: CIContext())
check("出图", out != nil)
if let out {
    check("尺寸一致", out.width == w && out.height == h, "\(out.width)x\(out.height)")
    check("行宽 64 字节对齐", out.bytesPerRow % 64 == 0, "\(out.bytesPerRow)")
    check("bitmapInfo 是 BGRX(noneSkipFirst+little)",
          out.alphaInfo == .noneSkipFirst && out.bitmapInfo.contains(.byteOrder32Little))
    let tl = px(out, 2, 2), tr = px(out, w - 3, 2), bl = px(out, 2, h - 3), br = px(out, w - 3, h - 3)
    // 参照：老路径 `createCGImage` 出的图（画进同格式 BGRX 上下文再读），新路径像素必须与它一致。
    // CIHueAdjust 不是严格的 HSV 色相旋转，红→反色→π 回来是偏粉的红（≈200,200,255），两条路都如此。
    let ref = referenceInvert(src, w: w, h: h)
    let rtl = px(ref, 2, 2)
    check("左上：与老路径逐通道一致（±3）", near(tl, rtl.b, rtl.g, rtl.r), "new \(tl) ref \(rtl)")
    check("左上：仍是红系（R 高、方向没翻、通道没串）", tl.r >= 250 && tl.b < 230 && tl.g < 230, "\(tl)")
    check("右上：白 → 黑", near(tr, 0, 0, 0), "\(tr)")
    check("左下：白 → 黑（若这里是红 = 上下翻了）", near(bl, 0, 0, 0), "\(bl)")
    check("右下：白 → 黑", near(br, 0, 0, 0), "\(br)")
    let mid = PageBitmap.liveImages
    check("进了 liveImages 的账（+1 张）", mid.count == before.count + 1, "\(before.count) → \(mid.count)")
    let expectBytes = out.bytesPerRow * out.height
    check("记账字节 = bytesPerRow×height", mid.bytes - before.bytes == expectBytes)
}
out = nil
let after = PageBitmap.liveImages
check("释放后账归零", after.count == before.count && after.bytes == before.bytes, "\(after)")

print("\n\(pass) 通过 / \(fail) 失败")
exit(fail == 0 ? 0 : 1)
}
}
