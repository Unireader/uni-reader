#!/usr/bin/env swift
// 把「一个 PDF 页实为跨页拼接扫描图、靠 CropBox 裁出其中一半」的文档，重排成每页一个逻辑页的简单 PDF：
// 有 CropBox 收窄的页按 CropBox 栅格化重编码成新页（page size = 原裁剪区尺寸，rotation 直接烘焙进像素，
// 输出页 rotation = 0）；没有裁剪需求的页原样搬运（保留矢量/可选中文字，不做无谓的有损重新栅格化）。
//
// 用法：
//   swift tools/flatten-cropbox-pdf.swift <输入.pdf> <输出.pdf> [--dpi 100] [--quality 0.5]
//
// 背景见 memory unireader-cropbox-fix：这类 PDF 本身没问题（CropBox 是标准 PDF 特性），只是很多阅读器
// （包括修复前的 UniReader）不认 CropBox 才会显示错。这个工具是给「不想依赖阅读器支持 CropBox」时用的
// 预处理：跑一次以后，输出文件在任何 PDF 阅读器里都是正常单页。
//
// ⚠️ 体积不是自动变小的：实测原文件的 JPEG 编码本身就不差，默认参数只是不降分辨率/质量地把跨页裁一半，
// 反而会比原文件更大（每半页要单独存一份 JPEG 编码开销，抵消了裁掉一半像素省下的空间）。真想要更小的
// 文件，必须主动降 --dpi（对体积影响最大）——默认 100dpi/quality 0.5 是实测过、明显更小且阅读可用的取值；
// 想保清晰度就调大 --dpi，但要接受体积可能反而超过原文件。

import Foundation
import PDFKit
import AppKit
import ImageIO
import UniformTypeIdentifiers

func effectiveBox(_ page: PDFPage) -> PDFDisplayBox {
    let crop = page.bounds(for: .cropBox)
    return (crop.width > 0 && crop.height > 0) ? .cropBox : .mediaBox
}

/// 该 box 的显示尺寸（pt，已含 90/270° 换边）——与 PageBitmap.displaySize 同语义。
func displaySize(_ page: PDFPage, box: PDFDisplayBox) -> CGSize {
    let b = page.bounds(for: box)
    let rot = ((page.rotation % 360) + 360) % 360
    return rot % 180 == 0 ? b.size : CGSize(width: b.height, height: b.width)
}

/// 按 box 栅格化整页（旋转由 page.draw(with:to:) 内部处理，box 原点自动对齐，不需要手动 translate——
/// 这正是本项目 PageBitmap 那次踩过的坑，见 memory unireader-cropbox-fix）。
func rasterize(page: PDFPage, box: PDFDisplayBox, dpi: Double) -> CGImage? {
    let disp = displaySize(page, box: box)
    guard disp.width > 0, disp.height > 0 else { return nil }
    let scale = CGFloat(dpi / 72.0)
    let pw = max(1, Int((disp.width * scale).rounded()))
    let ph = max(1, Int((disp.height * scale).rounded()))
    guard let space = CGColorSpace(name: CGColorSpace.sRGB),
          let ctx = CGContext(data: nil, width: pw, height: ph, bitsPerComponent: 8, bytesPerRow: 0,
                              space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    ctx.fill(CGRect(origin: .zero, size: CGSize(width: pw, height: ph)))
    ctx.interpolationQuality = .high
    ctx.scaleBy(x: CGFloat(pw) / disp.width, y: CGFloat(ph) / disp.height)
    page.draw(with: box, to: ctx)
    return ctx.makeImage()
}

/// CGImage → JPEG Data（有损，比 PDFPage(image:) 默认的无损内嵌明显小，扫描件/照片内容用它划算）。
func jpegData(_ image: CGImage, quality: CGFloat) -> Data? {
    let data = NSMutableData()
    guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
    CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
    guard CGImageDestinationFinalize(dest) else { return nil }
    return data as Data
}

// MARK: - 参数解析

let args = CommandLine.arguments
guard args.count >= 3 else {
    print("""
    用法：swift flatten-cropbox-pdf.swift <输入.pdf> <输出.pdf> [--dpi 100] [--quality 0.5]
      --dpi      裁剪页重新栅格化的分辨率（默认 100，偏向体积更小；原图多为拍照/扫描件，实测 dpi 得降到
                 ~100 左右体积才会真的比原文件小——原文件的 JPEG 编码本来就不差，光是把跨页裁一半、
                 不降分辨率/质量的话反而会变大，因为每个裁出来的图都要单独存一份 JPEG 头/编码开销）
      --quality  JPEG 压缩质量 0~1（默认 0.5；对体积的影响比 --dpi 小，想保清晰度优先调高这个而不是 --dpi）
    """)
    exit(1)
}
let inputPath = args[1]
let outputPath = args[2]
var dpi = 100.0
var quality: CGFloat = 0.5
var i = 3
while i < args.count {
    switch args[i] {
    case "--dpi" where i + 1 < args.count:
        i += 1; dpi = Double(args[i]) ?? dpi
    case "--quality" where i + 1 < args.count:
        i += 1; quality = CGFloat(Double(args[i]) ?? Double(quality))
    default:
        break
    }
    i += 1
}

guard let srcDoc = PDFDocument(url: URL(fileURLWithPath: inputPath)) else {
    print("无法打开输入 PDF：\(inputPath)"); exit(1)
}

let outDoc = PDFDocument()
var flattenedCount = 0
let t0 = Date()

for idx in 0..<srcDoc.pageCount {
    guard let page = srcDoc.page(at: idx) else { continue }
    let media = page.bounds(for: .mediaBox)
    let box = effectiveBox(page)
    let needsCrop = box == .cropBox && page.bounds(for: .cropBox) != media

    if needsCrop {
        guard let cg = rasterize(page: page, box: box, dpi: dpi),
              let jpeg = jpegData(cg, quality: quality),
              let rep = NSBitmapImageRep(data: jpeg)
        else {
            print("警告：第 \(idx) 页栅格化失败，原样搬运"); outDoc.insert(page, at: outDoc.pageCount); continue
        }
        let img = NSImage(size: displaySize(page, box: box))
        img.addRepresentation(rep)
        guard let newPage = PDFPage(image: img) else {
            print("警告：第 \(idx) 页建页失败，原样搬运"); outDoc.insert(page, at: outDoc.pageCount); continue
        }
        outDoc.insert(newPage, at: outDoc.pageCount)
        flattenedCount += 1
    } else {
        outDoc.insert(page, at: outDoc.pageCount)
    }
    if (idx + 1) % 50 == 0 { print("已处理 \(idx + 1)/\(srcDoc.pageCount) 页…") }
}

guard outDoc.write(to: URL(fileURLWithPath: outputPath)) else {
    print("写出失败：\(outputPath)"); exit(1)
}

let srcSize = (try? FileManager.default.attributesOfItem(atPath: inputPath)[.size] as? Int) ?? nil ?? 0
let dstSize = (try? FileManager.default.attributesOfItem(atPath: outputPath)[.size] as? Int) ?? nil ?? 0
func mb(_ n: Int) -> String { String(format: "%.1f MB", Double(n) / 1_048_576) }
print("""
完成，用时 \(String(format: "%.1f", Date().timeIntervalSince(t0)))s
  \(srcDoc.pageCount) 页 → \(outDoc.pageCount) 页，其中 \(flattenedCount) 页做了裁剪重排（dpi=\(dpi), quality=\(quality)）
  体积：\(mb(srcSize)) → \(mb(dstSize))
""")
