import CoreGraphics
import CoreImage
import PDFKit

/// PDF 页位图渲染原语（纯 CoreGraphics，不碰 AppKit → 任意线程可用）。
/// 旋转语义由 `spike/render-rotation-test.swift`（9/9）钉死：
/// `page.draw(with:to:)` 自带旋转；显示尺寸 = mediaBox 在 90/270° 时换边；子矩形贴片只需平移。
///
/// ⚠️ `page.draw(with:box,to:)` 内部**已经**把 box 的原点对齐到当前 CTM 原点——调用方不需要、也不能再手动
/// `translateBy(-b.minX,-b.minY)`。旧代码这么写过，因为绝大多数 PDF 的 MediaBox 原点是 (0,0)，这行平移
/// 恰好等于平移 0，从未暴露；真正 CropBox 原点非零（例如跨页扫描图靠 CropBox 切一半）时会叠加成双重平移，
/// 把整页内容顶到画布外（实测：CropBox.minX≈550 时输出纯白）。
///
/// ⚠️ 本原语线程安全，**但 `PDFPage`/`PDFDocument` 不是**：同一个 `PDFDocument` 实例只允许被
/// 一条队列渲染。现有三条管线各自持有独立文档实例或独占队列——Mac 阅读区走
/// `PageRenderEngine` 的串行队列（`session.pdf`）、平板页图走 `LANServer` 服务 queue
/// （`AppModel.padRenderPDF`，另开的实例，见 `setPadRender`）、OCR 走 `DocSession.ocrRenderQueue`。
/// 新增调用方前先确认它拿的是哪份文档实例，别再把 `session.pdf` 交给第四条队列。
enum PageBitmap {
    /// 该页实际显示用的 box：优先 CropBox，退化（未定义/零尺寸）时退回 MediaBox。
    /// 渲染、选区坐标归一化、TOC 跳转、平板页面宽高必须用同一个 box，否则互相错位。
    static func effectiveBox(_ page: PDFPage) -> PDFDisplayBox {
        let crop = page.bounds(for: .cropBox)
        return (crop.width > 0 && crop.height > 0) ? .cropBox : .mediaBox
    }

    /// 页的显示尺寸（pt，已含旋转换边）。
    static func displaySize(_ page: PDFPage) -> CGSize {
        let b = page.bounds(for: effectiveBox(page))
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
        page.draw(with: effectiveBox(page), to: ctx)
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
