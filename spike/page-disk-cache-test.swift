// Mac 阅读区磁盘页图缓存的两条纪律测试（2026-09-02 加）。运行：
//   cp spike/page-disk-cache-test.swift /tmp/main.swift && \
//   swiftc -O Sources/App/PageBitmap.swift Sources/App/PageRenderEngine.swift \
//          Sources/Server/PageDiskCache.swift Sources/Server/PageRenderer.swift \
//          /tmp/main.swift -o /tmp/pdc && /tmp/pdc [某个.pdf]
// （`PadLog` 住在 `UniReaderApp.swift` 里、带整个 app 一起走，所以本文件末尾给了个桩。）
// （须命名为 main.swift：swiftc 多文件时顶层代码只允许在 main.swift）
//
// 覆盖：
//  ① 键的亮/夜换算（磁盘只存亮色那一版，读回来当场反色）；贴片键一律不落盘；
//  ② 🔴 `PageBitmap.decode` 必须把图**重绘进自己的 mmap 缓冲**——直接用 ImageIO 那张的话，
//     像素归 CoreGraphics 管、释放不还给系统，且不进 `liveImages` 的账（2026-08-29 内存排查的病根）。
//     判据就是「解出来的图要计进 liveImages，释放后要退回去」。

import Foundation
import CoreGraphics
import PDFKit

var pass = 0, fail = 0
func check(_ cond: Bool, _ msg: String) {
    if cond { pass += 1; print("  ✅ \(msg)") } else { fail += 1; print("  ❌ \(msg)") }
}

// ① 键换算
let base0 = PageRenderEngine.baseKey(doc: "abc123", page: 7, pixelWidth: 1600, night: false)
let base1 = PageRenderEngine.baseKey(doc: "abc123", page: 7, pixelWidth: 1600, night: true)
check(base0.hasSuffix("#n0") && base1.hasSuffix("#n1"), "baseKey 带夜间标志")
check(PageRenderEngine.flippedNightKey(base0) == base1, "异色同参键互换")
check(PageRenderEngine.lightKey(base1) == base0, "夜间键 → 亮色键（磁盘只按它存）")
check(PageRenderEngine.lightKey(base0) == base0, "亮色键取自身")
let tile = PageRenderEngine.tileKey(doc: "abc123", page: 7,
                                    normRect: CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4),
                                    scale: 2, night: false)
check(PageRenderEngine.isTileKey(tile) && !PageRenderEngine.isTileKey(base0), "贴片键可判别（贴片不落盘）")

// ② decode 的内存归属
let pdfPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ""
if let doc = PDFDocument(url: URL(fileURLWithPath: pdfPath)), let page = doc.page(at: 0) {
    let before = PageBitmap.liveImages
    guard let rendered = PageBitmap.render(page: page, pixelWidth: 800) else {
        print("  ❌ 渲染失败"); exit(1)
    }
    check(PageBitmap.liveImages.count == before.count + 1, "渲染出的图计进 liveImages")

    guard let jpeg = PageRenderer.encode(rendered, format: .jpeg(quality: 0.85)) else {
        print("  ❌ 编码失败"); exit(1)
    }
    check(jpeg.count > 0 && jpeg.count < rendered.bytesPerRow * rendered.height / 4,
          "JPEG 比原始位图小一个量级（\(jpeg.count / 1024)KB ← \(rendered.bytesPerRow * rendered.height / 1024)KB）")

    do {
        let mid = PageBitmap.liveImages.count
        guard let back = PageBitmap.decode(jpeg) else { print("  ❌ 解码失败"); exit(1) }
        check(back.width == rendered.width && back.height == rendered.height, "解回来尺寸一致")
        check(back.bitsPerPixel == 32 && back.bytesPerRow % 64 == 0,
              "解回来仍是 BGRX / 行宽 64 对齐（与渲染出的图同一格式，才能混在一个缓存里）")
        check(PageBitmap.liveImages.count == mid + 1,
              "🔴 解码出的图计进 liveImages（= 走的是我们自己的 mmap 缓冲，不是 ImageIO 那张）")
    }
    // 作用域结束 → CGImage 释放 → provider 回调 munmap + noteFree
    check(PageBitmap.liveImages.count == before.count + 1, "解码图释放后退出 liveImages")
} else {
    print("  （没给 PDF 路径或打不开，跳过 decode 那组）")
}

print("\n结果：\(pass) 通过，\(fail) 失败")
exit(fail == 0 ? 0 : 1)

/// `PadLog` 的桩：真身在 `UniReaderApp.swift`（带整个 app 一起走，spike 里编不进来）。
/// 只要签名对得上即可——本测试不看日志。
enum PadLog {
    static func log(_ s: @autoclosure () -> String) {}
    static func ms(_ t: Double) -> String { String(format: "%.1fms", t * 1000) }
}
