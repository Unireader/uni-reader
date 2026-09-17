// 扫描页对齐（SCAN-ALIGN-PLAN.md）纯逻辑测试。运行：
//   cp spike/scan-align-test.swift /tmp/main.swift && swiftc -O Sources/App/ScanAlign.swift /tmp/main.swift -o /tmp/sat && /tmp/sat
// （须命名为 main.swift：swiftc 多文件时顶层代码只允许在 main.swift）
// 覆盖：
//   ① 变换：正逆互逆、y 向下公式 ≡ CoreGraphics 版（方案 §2.2 两组式子必须等价）、零参数 = 水平居中、
//      矩形包围盒、归一化互转；
//   ② payload：编码 → 解码逐位一致、戳 = SHA-256 前 8 位且稳定、格式版本 / 页数 / 非法值拒收、displayKey；
//   ③ 测量：合成「带歪斜 + 平移的文字页」测回角度与左右边缘；空白页；
//   ④ 定中心：两边可靠 / 只有一边 / 缩进行把左边缘带偏（用邻页纠正）/ 整页测不到用邻页值 / 全书都测不到。
//   ⑤ 安卓 Matrix 那组系数（方案 §2.2 末尾）与 y 向下公式一致。
import Foundation
import CoreGraphics

var pass = 0, fail = 0
func check(_ c: Bool, _ m: String) { if c { pass += 1; print("  ✅ \(m)") } else { fail += 1; print("  ❌ \(m)") } }
func near(_ a: Double, _ b: Double, _ eps: Double = 1e-6) -> Bool { abs(a - b) <= eps }
func near(_ a: CGPoint, _ b: CGPoint, _ eps: Double = 1e-6) -> Bool { near(Double(a.x), Double(b.x), eps) && near(Double(a.y), Double(b.y), eps) }

// MARK: ① 变换
print("① 每页变换")
let pa = PageAlign(rot: 0.9 * .pi / 180, dx: -7.25, dy: 1.5, sw: 504.7, sh: 707.75, w: 497.5)
do {
    let pts = [CGPoint(x: 0, y: 0), CGPoint(x: 504.7, y: 707.75), CGPoint(x: 123.4, y: 456.7), CGPoint(x: -30, y: 800)]
    check(pts.allSatisfy { near(pa.toRaw(pa.toAligned($0)), $0, 1e-9) }, "toRaw(toAligned(p)) == p")
    check(pts.allSatisfy { near(pa.toAligned(pa.toRaw($0)), $0, 1e-9) }, "toAligned(toRaw(q)) == q")
    // 页中心 → (W/2 + dx, sh/2 + dy)
    check(near(pa.toAligned(CGPoint(x: 504.7 / 2, y: 707.75 / 2)), CGPoint(x: 497.5 / 2 - 7.25, y: 707.75 / 2 + 1.5), 1e-9),
          "原始页中心落到 (W/2+dx, sh/2+dy)")
    // CG 版：原始 CG 点 (X, sh−y) 过 cgTransform = 对齐 CG 点 (q.x, sh−q.y)
    let t = pa.cgTransform
    let ok = pts.allSatisfy { p in
        let cg = CGPoint(x: p.x, y: CGFloat(pa.sh) - p.y).applying(t)
        let q = pa.toAligned(p)
        return near(cg, CGPoint(x: q.x, y: CGFloat(pa.sh) - q.y), 1e-9)
    }
    check(ok, "CoreGraphics 版 cgTransform ≡ y 向下公式")
    // 零参数：纯水平居中（页宽 504.7 放进 497.5 → 往左挪 3.6）
    let z = PageAlign(rot: 0, dx: 0, dy: 0, sw: 504.7, sh: 700, w: 497.5)
    check(near(z.toAligned(CGPoint(x: 10, y: 20)), CGPoint(x: 10 - 3.6, y: 20), 1e-9), "零参数 = 水平居中、不转")
    // 旋转方向：原图里「往右往下斜」的一行（斜率 tanθ）转正后 y 相同
    let a = pa.toAligned(CGPoint(x: 100, y: 300)), b = pa.toAligned(CGPoint(x: 400, y: 300 + 300 * tan(pa.rot)))
    check(near(Double(a.y), Double(b.y), 1e-9), "正 rot = 往右往下斜的行被转平")
    // 矩形包围盒
    let r = CGRect(x: 50, y: 60, width: 200, height: 30)
    let ar = pa.toAligned(rect: r)
    let cs = [CGPoint(x: 50, y: 60), CGPoint(x: 250, y: 60), CGPoint(x: 50, y: 90), CGPoint(x: 250, y: 90)].map(pa.toAligned)
    check(cs.allSatisfy { ar.insetBy(dx: -1e-9, dy: -1e-9).contains($0) } && near(Double(ar.minX), Double(cs.map(\.x).min()!), 1e-9),
          "toAligned(rect:) = 四角包围盒")
    // 归一化
    let n = pa.alignedNorm(fromRawNorm: CGRect(x: 0.5, y: 0.5, width: 0, height: 0))
    check(near(Double(n.minX), (497.5 / 2 - 7.25) / 497.5, 1e-9) && near(Double(n.minY), (707.75 / 2 + 1.5) / 707.75, 1e-9),
          "alignedNorm：原始页中心 → 对齐归一化")
    let back = pa.rawNorm(fromAlignedNorm: CGPoint(x: n.minX, y: n.minY))
    check(near(back, CGPoint(x: 0.5, y: 0.5), 1e-9), "rawNorm(alignedNorm(p)) == p")
    check(pa.alignedSize == CGSize(width: 497.5, height: 707.75), "对齐页尺寸 = (W, sh)")
}

// MARK: ⑤ 安卓 Matrix 系数
print("⑤ 安卓 android.graphics.Matrix 系数（方案 §2.2）")
do {
    let c = cos(pa.rot), s = sin(pa.rot)
    let m = [c, s, pa.w / 2 + pa.dx - c * pa.sw / 2 - s * pa.sh / 2,
             -s, c, pa.sh / 2 + pa.dy + s * pa.sw / 2 - c * pa.sh / 2]
    let p = CGPoint(x: 321.5, y: 88.25)
    let x = m[0] * Double(p.x) + m[1] * Double(p.y) + m[2]
    let y = m[3] * Double(p.x) + m[4] * Double(p.y) + m[5]
    check(near(CGPoint(x: x, y: y), pa.toAligned(p), 1e-9), "setValues([c, s, tx, −s, c, ty, 0,0,1]) ≡ toAligned")
}

// MARK: ② payload
print("② payload 编解码")
do {
    let pages = [ScanAlignTable.Page(rot: 0.0123456789, dx: -9.25, dy: 0, sw: 506.9, sh: 720),
                 ScanAlignTable.Page(rot: -0.0063, dx: 0.75, dy: 0, sw: 489.6, sh: 706.7)]
    let t = ScanAlignTable(width: 497.5, pages: pages)
    let json = String(decoding: t.payload, as: UTF8.self)
    print("    payload = \(json)")
    check(json.hasPrefix("{\"v\":1,\"w\":497.5,\"pages\":[["), "格式：{\"v\":1,\"w\":…,\"pages\":[[…]]}")
    let d = ScanAlignTable.decode(t.payload, pageCount: 2)
    check(d != nil && d! == t && d!.pages == t.pages && d!.width == t.width, "decode(encode) 逐位一致")
    check(t.stamp.count == 8 && t.stamp.allSatisfy { "0123456789abcdef".contains($0) }, "戳 = 8 位小写十六进制")
    check(t.stamp == ScanAlignTable(width: 497.5, pages: pages).stamp, "同样的参数戳相同")
    check(t.stamp != ScanAlignTable(width: 497.5, pages: [pages[0], pages[0]]).stamp, "参数不同戳不同")
    check(near(t.pages[0].rot, 0.0123457, 1e-12), "rot 保留 7 位小数（写出去再读回的值）")
    check(ScanAlignTable.decode(t.payload, pageCount: 3) == nil, "页数对不上 → nil")
    check(ScanAlignTable.decode(Data("{\"v\":2,\"w\":497.5,\"pages\":[]}".utf8), pageCount: 0) == nil, "不认识的格式版本 → nil")
    check(ScanAlignTable.decode(Data("{\"v\":1,\"w\":0,\"pages\":[]}".utf8), pageCount: 0) == nil, "w ≤ 0 → nil")
    check(ScanAlignTable.decode(Data("{\"v\":1,\"w\":500,\"pages\":[[0,0,0,0,700]]}".utf8), pageCount: 1) == nil, "页宽 ≤ 0 → nil")
    check(ScanAlignTable.decode(Data("{\"v\":1,\"w\":500,\"pages\":[[0,0,0,500]]}".utf8), pageCount: 1) == nil, "少一列 → nil")
    let foreign = Data("{\"pages\":[[0.01,-3,0,500,700]],\"w\":500.0,\"v\":1}".utf8)   // 别的端写的：键序 / 数字格式不同
    let f = ScanAlignTable.decode(foreign, pageCount: 1)
    check(f != nil && f!.payload == foreign && f!.stamp == ScanAlignTable.stamp(of: foreign), "别的端写的 payload：戳按原字节算、不重编码")
    check(ScanAlignTable.displayKey(contentHash: "abc", table: nil) == "abc", "displayKey：未开 = 内容哈希")
    check(ScanAlignTable.displayKey(contentHash: "abc", table: t) == "abc~a" + t.stamp, "displayKey：开着 = 哈希~a戳")
    check(!ScanAlignTable.displayKey(contentHash: "abc", table: t).contains("#"), "displayKey 不含 #（页图缓存键的分隔符）")
    let h = t.heights(refWidth: 1000)
    check(near(h[0], 720 / 497.5 * 1000, 1e-9) && near(h[1], 706.7 / 497.5 * 1000, 1e-9), "heights：sh / W × 参考宽")
    check(t.page(1) == PageAlign(rot: -0.0063, dx: 0.75, dy: 0, sw: 489.6, sh: 706.7, w: 497.5) && t.page(2) == nil, "page(i)")
}

// MARK: ③ 测量（合成页）
print("③ 像素测量（合成页）")
/// 合成一页：栏 [colL, colL+colW]，行高 10pt、行距 16pt，段首缩进 2 字，每 5 行一段、段末行短；
/// 整页绕页中心转 `deg`（正 = 往右往下斜）。字 = 9pt 方块、间隔 1pt。
func synthPage(sw: Double, sh: Double, colL: Double, colW: Double, deg: Double, top: Double = 60, lines: Int = 36,
               S: Double = 1.5) -> [UInt8] {
    let pw = Int(sw * S), ph = Int(sh * S)
    var buf = [UInt8](repeating: 255, count: pw * ph)
    buf.withUnsafeMutableBytes { raw in
        let ctx = CGContext(data: raw.baseAddress, width: pw, height: ph, bitsPerComponent: 8, bytesPerRow: pw,
                            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        // 切到「左上原点、y 向下、pt」：翻转 + 缩放
        ctx.translateBy(x: 0, y: CGFloat(ph)); ctx.scaleBy(x: CGFloat(S), y: CGFloat(-S))
        // y 向下坐标里绕页中心转 deg（正 = 顺时针 = 往右往下斜）
        ctx.translateBy(x: sw / 2, y: sh / 2); ctx.rotate(by: deg * .pi / 180); ctx.translateBy(x: -sw / 2, y: -sh / 2)
        ctx.setFillColor(gray: 0, alpha: 1)
        for i in 0..<lines {
            let y = top + Double(i) * 16
            let first = i % 5 == 0, last = i % 5 == 4
            var x = colL + (first ? 20 : 0)
            let end = last ? colL + colW * 0.45 : colL + colW
            while x + 9 <= end + 0.01 { ctx.fill(CGRect(x: x, y: y, width: 9, height: 10)); x += 10 }
        }
        // 页码（左上角小字，不该影响边缘）
        ctx.fill(CGRect(x: 30, y: 25, width: 12, height: 8))
    }
    return buf
}
func measureSynth(sw: Double, sh: Double, colL: Double, colW: Double, deg: Double, lines: Int = 36) -> ScanAlignDetector.Measure {
    let S = 1.5
    let buf = synthPage(sw: sw, sh: sh, colL: colL, colW: colW, deg: deg, lines: lines, S: S)
    return buf.withUnsafeBufferPointer {
        ScanAlignDetector.measure(gray: $0, width: Int(sw * S), height: Int(sh * S), pxPerPt: S,
                                  pageSize: CGSize(width: sw, height: sh))
    }
}
do {
    for (deg, colL) in [(0.0, 55.0), (0.8, 62.0), (-0.6, 44.0), (1.3, 50.0)] {
        let t0 = Date()
        let m = measureSynth(sw: 504, sh: 708, colL: colL, colW: 399, deg: deg)
        let ms = Date().timeIntervalSince(t0) * 1000
        let degOut = m.rot * 180 / .pi
        // 转正后的栏边缘 = 原栏边缘（绕页中心转回来就是原位置）；字块右端 = colL + 399 − 1（最后一格间隔）
        let lOK = m.left.map { abs($0 - colL) <= 1.5 } ?? false
        let rOK = m.right.map { abs($0 - (colL + 399)) <= 2.5 } ?? false
        check(abs(degOut - deg) <= 0.05 && lOK && rOK,
              String(format: "歪斜 %.1f° 栏左 %.0f → 测得 %.2f°、左 %@、右 %@（行 %d，支撑 %d/%d，%.0fms）",
                     deg, colL, degOut, m.left.map { String(format: "%.1f", $0) } ?? "nil",
                     m.right.map { String(format: "%.1f", $0) } ?? "nil", m.textLines, m.supportL, m.supportR, ms))
    }
    let blank = [UInt8](repeating: 255, count: 750 * 1060)
    let mb = blank.withUnsafeBufferPointer {
        ScanAlignDetector.measure(gray: $0, width: 750, height: 1060, pxPerPt: 1.5, pageSize: CGSize(width: 500, height: 706.7))
    }
    check(mb.rot == 0 && mb.left == nil && mb.right == nil && mb.textLines == 0, "空白页 → rot 0、无边缘")
    let few = measureSynth(sw: 504, sh: 708, colL: 55, colW: 399, deg: 0.9, lines: 2)
    check(few.rot == 0, "只有 2 行字 → 歪斜角不可信，记 0")
}

// MARK: ④ 定中心
print("④ 整篇定中心")
typealias M = ScanAlignDetector.Measure
func m(_ l: Double?, _ r: Double?, sl: Int = 12, sr: Int = 12, rot: Double = 0, sw: Double = 500) -> M {
    M(rot: rot, left: l, right: r, supportL: l == nil ? 0 : sl, supportR: r == nil ? 0 : sr, textLines: 20, sw: sw, sh: 700)
}
do {
    // 偶数页栏在 [60, 456]、奇数页 [48, 444]（栏宽 396），页宽 500
    var ms: [M] = []
    for i in 0..<20 { ms.append(i % 2 == 0 ? m(60, 456) : m(48, 444)) }
    ms[5] = m(nil, 444)                  // 只测到右边
    ms[7] = m(68, 444, sl: 14, sr: 5)    // 左边被缩进行带偏（宽 376 ≠ 396）→ 用右边
    ms[9] = m(nil, nil)                  // 插图页：什么都没测到 → 邻页值
    ms[11] = m(80, 420, sl: 4, sr: 4)    // 两边都在但都不对（与邻页差 >8pt）→ 邻页值
    ms[2] = m(60, 456, rot: 0.01)
    let t = ScanAlignSolver.solve(ms)
    check(near(t.width, 500), "目标页宽 = 页宽中位数")
    func center(_ i: Int) -> Double { Double(t.page(i)!.toAligned(CGPoint(x: 250, y: 350)).x) - 250 - (i % 2 == 0 ? 8 : -4) }
    // 偶数页栏中心 258 → 对齐后应在 250；页中心 250 → 250 − 8
    check(near(t.pages[0].dx, -8) && near(t.pages[1].dx, 4), "两边可靠：dx = −(栏中心 − 页中心)")
    check(near(t.pages[5].dx, 4), "只测到右边：按栏宽推中心")
    check(near(t.pages[7].dx, 4), "左边被缩进带偏：用右边")
    check(near(t.pages[9].dx, 4), "整页测不到：同奇偶邻页值")
    check(near(t.pages[11].dx, 4), "测到的与邻页差太多：邻页值")
    check(near(t.pages[2].rot, 0.01) && t.pages[3].rot == 0, "rot 原样带进参数表")
    _ = center
    // 不同页宽：栏中心对到 W/2
    var mixed: [M] = []
    for i in 0..<10 { mixed.append(m(i % 2 == 0 ? 60 : 48, i % 2 == 0 ? 456 : 444, sw: i == 4 ? 510 : 500)) }
    let tm = ScanAlignSolver.solve(mixed)
    let q = tm.page(4)!.toAligned(CGPoint(x: 258, y: 350))
    check(near(Double(q.x), tm.width / 2, 1e-9), "页宽不同的页：栏中心仍落到 W/2")
    // 全书都测不到 → 不平移（dx=0，页居中）
    let none = ScanAlignSolver.solve((0..<6).map { _ in m(nil, nil) })
    check(none.pages.allSatisfy { $0.dx == 0 && $0.rot == 0 }, "全书都测不到：dx=0、rot=0")
    check(ScanAlignSolver.solve([]).pages.isEmpty, "空文档")
}

print("\n\(pass) passed, \(fail) failed")
exit(fail == 0 ? 0 : 1)
