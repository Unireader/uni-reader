import AppKit
import PDFKit

enum PageRenderer {
    /// 把 PDF 页渲染为 PNG（按宽度缩放，`thumbnail` 已处理旋转），供平板显示。
    static func png(page: PDFPage, maxWidth: CGFloat) -> Data? {
        let bounds = page.bounds(for: .mediaBox)
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let scale = min(maxWidth / bounds.width, 4)
        let size = CGSize(width: (bounds.width * scale).rounded(),
                          height: (bounds.height * scale).rounded())
        let image = page.thumbnail(of: size, for: .mediaBox)
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}
