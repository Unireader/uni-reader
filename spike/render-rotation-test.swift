// 运行时探针：确定 PDFPage 手动 CGContext 渲染（全页 + 子矩形贴片）在 rotation=0/90/180/270 下的正确变换。
// 基准：page.thumbnail（项目内 PageRenderer 注释确认其“已处理旋转”）。
// 运行：swiftc spike/render-rotation-test.swift -o /tmp/rot-test && /tmp/rot-test
//
// 结论直接决定 Sources/App/PageBitmap.swift 的实现（候选 A：自己加旋转变换；候选 B：page.draw 自带旋转）。

import AppKit
import PDFKit

// ---- 合成 PDF：400x300，四角色块（PDF 坐标，原点左下）----
// 左下=红, 右下=绿, 左上=蓝, 右上=黄, 中间白。
func makePDF() -> PDFDocument {
    let data = NSMutableData()
    var mediaBox = CGRect(x: 0, y: 0, width: 400, height: 300)
    let consumer = CGDataConsumer(data: data as CFMutableData)!
    let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, nil)!
    ctx.beginPDFPage(nil)
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    ctx.fill(mediaBox)
    let s: CGFloat = 100
    func fill(_ r: CGRect, _ c: CGColor) { ctx.setFillColor(c); ctx.fill(r) }
    fill(CGRect(x: 0, y: 0, width: s, height: s), CGColor(red: 1, green: 0, blue: 0, alpha: 1))          // 左下 红
    fill(CGRect(x: 400 - s, y: 0, width: s, height: s), CGColor(red: 0, green: 1, blue: 0, alpha: 1))    // 右下 绿
    fill(CGRect(x: 0, y: 300 - s, width: s, height: s), CGColor(red: 0, green: 0, blue: 1, alpha: 1))    // 左上 蓝
    fill(CGRect(x: 400 - s, y: 300 - s, width: s, height: s), CGColor(red: 1, green: 1, blue: 0, alpha: 1)) // 右上 黄
    ctx.endPDFPage()
    ctx.closePDF()
    return PDFDocument(data: data as Data)!
}

// ---- 像素采样 ----
func pixels(_ img: CGImage) -> (w: Int, h: Int, at: (Int, Int) -> (UInt8, UInt8, UInt8)) {
    let w = img.width, h = img.height
    var buf = [UInt8](repeating: 0, count: w * h * 4)
    let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
    let copy = buf
    return (w, h, { x, y in
        let i = (y * w + x) * 4   // y=0 是位图顶行
        return (copy[i], copy[i + 1], copy[i + 2])
    })
}
func colorName(_ p: (UInt8, UInt8, UInt8)) -> String {
    let (r, g, b) = p
    func hi(_ v: UInt8) -> Bool { v > 180 }
    func lo(_ v: UInt8) -> Bool { v < 80 }
    if hi(r) && lo(g) && lo(b) { return "红" }
    if lo(r) && hi(g) && lo(b) { return "绿" }
    if lo(r) && lo(g) && hi(b) { return "蓝" }
    if hi(r) && hi(g) && lo(b) { return "黄" }
    if hi(r) && hi(g) && hi(b) { return "白" }
    return "?(\(r),\(g),\(b))"
}
/// 取图四角色（内缩 12%，避开边界）：返回 [左上, 右上, 左下, 右下]（位图视觉方位）
func corners(_ img: CGImage) -> [String] {
    let (w, h, at) = pixels(img)
    let dx = Int(Double(w) * 0.12), dy = Int(Double(h) * 0.12)
    return [colorName(at(dx, dy)), colorName(at(w - dx, dy)), colorName(at(dx, h - dy)), colorName(at(w - dx, h - dy))]
}

// ---- 候选实现 ----
/// 显示尺寸候选：bounds(mediaBox) 按 rotation 换边
func displaySizeSwapped(_ page: PDFPage) -> CGSize {
    let b = page.bounds(for: .mediaBox)
    let rot = ((page.rotation % 360) + 360) % 360
    return rot % 180 == 0 ? b.size : CGSize(width: b.height, height: b.width)
}

/// 候选 A：自己加旋转变换 + page.draw
func renderA(_ page: PDFPage, pixelWidth: Int) -> CGImage? {
    let disp = displaySizeSwapped(page)
    let scale = CGFloat(pixelWidth) / disp.width
    let pw = pixelWidth, ph = Int((disp.height * scale).rounded())
    guard let ctx = CGContext(data: nil, width: pw, height: ph, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: pw, height: ph))
    ctx.interpolationQuality = .high
    ctx.scaleBy(x: scale, y: scale)
    let b = page.bounds(for: .mediaBox)
    let rot = ((page.rotation % 360) + 360) % 360
    switch rot {
    case 90:  ctx.translateBy(x: 0, y: disp.height); ctx.rotate(by: -.pi / 2)
    case 180: ctx.translateBy(x: disp.width, y: disp.height); ctx.rotate(by: .pi)
    case 270: ctx.translateBy(x: disp.width, y: 0); ctx.rotate(by: .pi / 2)
    default: break
    }
    ctx.translateBy(x: -b.minX, y: -b.minY)
    page.draw(with: .mediaBox, to: ctx)
    return ctx.makeImage()
}

/// 候选 B：不加旋转变换，直接 page.draw（若 draw 自带旋转则此版正确）
func renderB(_ page: PDFPage, pixelWidth: Int) -> CGImage? {
    let disp = displaySizeSwapped(page)
    let scale = CGFloat(pixelWidth) / disp.width
    let pw = pixelWidth, ph = Int((disp.height * scale).rounded())
    guard let ctx = CGContext(data: nil, width: pw, height: ph, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: pw, height: ph))
    ctx.scaleBy(x: scale, y: scale)
    let b = page.bounds(for: .mediaBox)
    ctx.translateBy(x: -b.minX, y: -b.minY)
    page.draw(with: .mediaBox, to: ctx)
    return ctx.makeImage()
}

/// 子矩形版（B 路线）：subRect 为「显示坐标、左上原点」的页内区域，按 scale 出像素。
/// page.draw 自带旋转（B 已验证），只需在其前加子矩形平移。
func renderTileB(_ page: PDFPage, subRect: CGRect, scale: CGFloat) -> CGImage? {
    let disp = displaySizeSwapped(page)
    let pw = Int((subRect.width * scale).rounded()), ph = Int((subRect.height * scale).rounded())
    guard pw > 0, ph > 0,
          let ctx = CGContext(data: nil, width: pw, height: ph, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: pw, height: ph))
    ctx.interpolationQuality = .high
    ctx.scaleBy(x: scale, y: scale)
    // 顶左原点 subRect → 底左原点平移：位图底左对应显示坐标 (subRect.minX, subRect.maxY)
    ctx.translateBy(x: -subRect.minX, y: -(disp.height - subRect.maxY))
    let b = page.bounds(for: .mediaBox)
    ctx.translateBy(x: -b.minX, y: -b.minY)
    page.draw(with: .mediaBox, to: ctx)
    return ctx.makeImage()
}

// ---- 跑 ----
var pass = 0, fail = 0
for rot in [0, 90, 180, 270] {
    let doc = makePDF()
    let page = doc.page(at: 0)!
    page.rotation = rot
    let b = page.bounds(for: .mediaBox)
    let disp = displaySizeSwapped(page)

    // 基准：thumbnail 按候选显示尺寸取图
    let thumbScale = 200.0 / disp.width
    let thumbSize = CGSize(width: 200, height: (disp.height * thumbScale).rounded())
    let thumb = page.thumbnail(of: thumbSize, for: .mediaBox)
    guard let thumbCG = thumb.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
        print("rot=\(rot) thumbnail 取 CGImage 失败"); fail += 1; continue
    }
    let expect = corners(thumbCG)
    let ta = renderA(page, pixelWidth: 200).map(corners)
    let tb = renderB(page, pixelWidth: 200).map(corners)
    print("rot=\(rot) bounds(mediaBox)=\(Int(b.width))x\(Int(b.height)) thumb像素=\(thumbCG.width)x\(thumbCG.height)")
    print("  基准四角[左上,右上,左下,右下]=\(expect)  A=\(ta ?? [])  B=\(tb ?? [])")
    if ta == expect { print("  → A 与基准一致"); pass += 1 } else { print("  → A 不一致"); }
    if tb == expect { print("  → B 与基准一致") } else { print("  → B 不一致") }

    if tb == expect { pass += 1 } else { fail += 1 }

    // 贴片：左上 1/4 区域左上角色 = 基准左上色；右下 1/4 区域右下角色 = 基准右下色。
    let halfTL = CGRect(x: 0, y: 0, width: disp.width / 2, height: disp.height / 2)
    let halfBR = CGRect(x: disp.width / 2, y: disp.height / 2, width: disp.width / 2, height: disp.height / 2)
    if let t1 = renderTileB(page, subRect: halfTL, scale: 1),
       let t2 = renderTileB(page, subRect: halfBR, scale: 1) {
        let c1 = corners(t1), c2 = corners(t2)
        let ok = c1[0] == expect[0] && c2[3] == expect[3]
        print("  贴片 左上1/4角=\(c1[0])(期望\(expect[0])) 右下1/4角=\(c2[3])(期望\(expect[3])) \(ok ? "✓" : "✗")")
        if ok { pass += 1 } else { fail += 1 }
    } else { print("  贴片渲染失败 ✗"); fail += 1 }
}
print("\n结果：pass=\(pass) fail=\(fail)（结论：PageBitmap 用 B 路线——draw 自带旋转 + displaySize 换边 + 贴片平移）")
