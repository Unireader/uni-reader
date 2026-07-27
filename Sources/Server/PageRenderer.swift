import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers

enum PageRenderer {
    /// 把 PDF 页渲染为 PNG（按宽度缩放，旋转由 `PageBitmap` 处理），供平板显示。
    ///
    /// ⚠️ **纯 CoreGraphics / ImageIO，严禁碰 AppKit**（2026-07-27 定）：本方法在 `LANServer` 的
    /// 服务 queue 上被调用（`pageProvider` → `AppModel.renderPage`），而旧实现走
    /// `page.thumbnail` → `NSImage` → `tiffRepresentation` → `NSBitmapImageRep(data:)`
    /// → `representation(using: .png)`，既是在后台线程用 AppKit，又要多一次 ~13MB 未压缩 TIFF
    /// 中转 + 一次全量重解码。改用与 Mac 阅读区同一条渲染原语 `PageBitmap.render`（CGContext）
    /// + `CGImageDestination` 直接编码 PNG。
    static func png(page: PDFPage, maxWidth: CGFloat) -> Data? {
        let disp = PageBitmap.displaySize(page)
        guard disp.width > 0, disp.height > 0 else { return nil }
        // 原语义保持：宽度上限 maxWidth，窄页最多放大 4 倍。
        let pixelWidth = Int(min(maxWidth, disp.width * 4).rounded())
        guard pixelWidth > 0, let cg = PageBitmap.render(page: page, pixelWidth: pixelWidth) else { return nil }
        return encodePNG(cg)
    }

    private static func encodePNG(_ image: CGImage) -> Data? {
        let buf = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            buf, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return buf as Data
    }
}
