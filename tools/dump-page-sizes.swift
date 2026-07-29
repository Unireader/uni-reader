#!/usr/bin/env swift
// 打印一个 PDF 每页的「显示尺寸（pt，已含旋转换边）+ 宽高比」，格式与安卓端
// `local/PdfSource.logPageSizes()` 的 logcat 行一致，用来做 ANDROID-STANDALONE-PLAN.md §9.1
// 那条硬验收：**两端逐页宽高比必须相等**。
//
// 口径与 `Sources/App/PageBitmap.swift` 的 `displaySize` 完全一致（CropBox 宽高都 >0 用 CropBox，
// 否则 MediaBox；再按 page.rotation 换边）——本脚本就是把它单独拎出来跑。
// 若两端不等，说明安卓那边取的 box 或旋转处理不同，归一化坐标会整体偏移/缩放，
// 表现为「Mac 上写的笔迹在平板上差一点点、说不清哪错了」。
//
// 用法：
//   swift tools/dump-page-sizes.swift <文件.pdf>
//   # 与安卓端比对：
//   adb logcat -d -s UniReader/Pdf | grep PAGESIZE | sed 's/.*PAGESIZE //' > /tmp/and.txt
//   swift tools/dump-page-sizes.swift a.pdf | grep PAGESIZE | sed 's/PAGESIZE //' > /tmp/mac.txt
//   diff /tmp/mac.txt /tmp/and.txt && echo "逐页一致"

import Foundation
import PDFKit

let args = CommandLine.arguments
guard args.count >= 2 else {
    FileHandle.standardError.write("用法：swift tools/dump-page-sizes.swift <文件.pdf>\n".data(using: .utf8)!)
    exit(2)
}
let url = URL(fileURLWithPath: args[1])
guard let doc = PDFDocument(url: url) else {
    FileHandle.standardError.write("打不开：\(url.path)\n".data(using: .utf8)!)
    exit(1)
}

func effectiveBox(_ page: PDFPage) -> PDFDisplayBox {
    let crop = page.bounds(for: .cropBox)
    return (crop.width > 0 && crop.height > 0) ? .cropBox : .mediaBox
}

func displaySize(_ page: PDFPage) -> CGSize {
    let b = page.bounds(for: effectiveBox(page))
    let rot = ((page.rotation % 360) + 360) % 360
    return rot % 180 == 0 ? b.size : CGSize(width: b.height, height: b.width)
}

print("# \(url.lastPathComponent) 共 \(doc.pageCount) 页")
for i in 0..<doc.pageCount {
    guard let p = doc.page(at: i) else { print("PAGESIZE \(i) 0.0000 0.0000 0.000000"); continue }
    let s = displaySize(p)
    let ratio = s.width > 0 ? s.height / s.width : 0
    print(String(format: "PAGESIZE %d %.4f %.4f %.6f", i, s.width, s.height, ratio))
}
