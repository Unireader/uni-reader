import CoreGraphics
import CoreImage
import PDFKit

/// PDF 页位图渲染原语。旋转语义由 `spike/render-rotation-test.swift`（9/9）钉死：
/// `page.draw(with:to:)` 自带旋转；显示尺寸 = mediaBox 在 90/270° 时换边；子矩形贴片只需平移。
/// 仅在 `PageRenderEngine` 的串行后台队列上调用。
enum PageBitmap {
    /// 页的显示尺寸（pt，已含旋转换边）。
    static func displaySize(_ page: PDFPage) -> CGSize {
        let b = page.bounds(for: .mediaBox)
        let rot = ((page.rotation % 360) + 360) % 360
        return rot % 180 == 0 ? b.size : CGSize(width: b.height, height: b.width)
    }

    /// 整页渲染（宽 pixelWidth 像素，白底）。
    static func render(page: PDFPage, pixelWidth: Int) -> CGImage? {
        let disp = displaySize(page)
        guard disp.width > 0, disp.height > 0, pixelWidth > 0 else { return nil }
        let scale = CGFloat(pixelWidth) / disp.width
        return draw(page: page,
                    pixelSize: CGSize(width: CGFloat(pixelWidth), height: (disp.height * scale).rounded()),
                    scale: scale,
                    subOrigin: .zero)
    }

    /// 子矩形贴片：`subRect` 为「页显示坐标、左上原点」的区域（pt）；`scale` = 像素/pt。
    static func renderTile(page: PDFPage, subRect: CGRect, scale: CGFloat) -> CGImage? {
        let disp = displaySize(page)
        guard subRect.width > 0, subRect.height > 0, scale > 0 else { return nil }
        return draw(page: page,
                    pixelSize: CGSize(width: (subRect.width * scale).rounded(),
                                      height: (subRect.height * scale).rounded()),
                    scale: scale,
                    subOrigin: CGPoint(x: subRect.minX, y: disp.height - subRect.maxY))  // 左上原点 → CG 底左原点
    }

    private static func draw(page: PDFPage, pixelSize: CGSize, scale: CGFloat, subOrigin: CGPoint) -> CGImage? {
        let pw = Int(pixelSize.width), ph = Int(pixelSize.height)
        guard pw > 0, ph > 0,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: pw, height: ph, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(origin: .zero, size: pixelSize))
        ctx.interpolationQuality = .high
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: -subOrigin.x, y: -subOrigin.y)
        let b = page.bounds(for: .mediaBox)
        ctx.translateBy(x: -b.minX, y: -b.minY)
        page.draw(with: .mediaBox, to: ctx)
        return ctx.makeImage()
    }

    /// 夜间反色：CIColorInvert + CIHueAdjust(π)（色相复原：白底变黑，彩色不变怪）。
    static func invert(_ image: CGImage, ci: CIContext) -> CGImage? {
        let src = CIImage(cgImage: image)
        guard let inv = CIFilter(name: "CIColorInvert") else { return nil }
        inv.setValue(src, forKey: kCIInputImageKey)
        guard let inverted = inv.outputImage else { return nil }
        guard let hue = CIFilter(name: "CIHueAdjust") else { return nil }
        hue.setValue(inverted, forKey: kCIInputImageKey)
        hue.setValue(Double.pi, forKey: kCIInputAngleKey)
        let out = hue.outputImage ?? inverted
        return ci.createCGImage(out, from: out.extent)
    }
}
