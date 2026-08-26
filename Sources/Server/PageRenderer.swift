import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers

enum PageRenderer {

    /// 页图编码格式。**默认 JPEG**（2026-08-13 实测定，语料＝扫描版考研书）。
    ///
    /// 换 JPEG **不是为了省流量——省不了多少**，是为了省**编码时间**。真实数字（同一页 @2160px）：
    ///
    /// | 编码 | 编码耗时 | 字节 |
    /// |---|---|---|
    /// | PNG 无损 | **259.5ms** | 686KB |
    /// | JPEG q70 | 20.9ms | 674KB |
    /// | JPEG q80 | 15.7ms | 736KB |
    /// | JPEG q90 | 16.7ms | 842KB |
    ///
    /// 两条要点，都反直觉：
    /// - **字节上 JPEG 只是打平甚至更差**（+7~11%）。扫描件的灰噪点是 JPEG 的最坏情况，而近似
    ///   双值的版面恰是 PNG 滤波+deflate 的最好情况。所以别指望靠换格式减流量。
    /// - **PNG 编码耗时随像素数暴涨**：1600px 时才 24~28ms（那时怎么测都觉得「服务端不是瓶颈」），
    ///   分档到 2160/2880 之后变成 130~260ms。而它占的是 `LANServer` 那条**串行** queue——
    ///   同一条队列还在跑笔迹 RT 与 WS 广播，一页压 260ms 就是压所有人。JPEG 稳定在 ~16ms。
    ///
    /// 所以这里的取舍是「多传 7% 字节，换回 240ms 的队列占用」。
    /// 质量档见 [defaultJPEGQuality]；要无损原样对比带 `?f=png`（`LANServer.route`）。
    enum Format {
        case jpeg(quality: CGFloat)
        case png

        var contentType: String {
            switch self {
            case .jpeg: return "image/jpeg"
            case .png: return "image/png"
            }
        }

        var utType: CFString {
            switch self {
            case .jpeg: return UTType.jpeg.identifier as CFString
            case .png: return UTType.png.identifier as CFString
            }
        }

        var name: String {
            switch self {
            case .jpeg(let q): return "JPEG q\(Int(q * 100))"
            case .png: return "PNG"
            }
        }
    }

    /// 默认 JPEG 质量。**觉得糊就只调这一个数**（往上调只是多几个百分点的字节，编码耗时几乎不变）。
    /// 0.85 是按扫描件语料选的保守档：再往下（q70）字节反而更接近 PNG，没必要冒画质的险。
    static let defaultJPEGQuality: CGFloat = 0.85

    /// 把 PDF 页渲染成图片（按宽度缩放，旋转由 `PageBitmap` 处理），供平板显示。
    ///
    /// [pixelWidth] 是**客户端报上来的目标宽度**（已归到 `LANServer` 的档位阶梯）；这里仍保留
    /// 原有的「窄页最多放大 4 倍」上限，免得一张名片大小的页被拉成 2880 宽。
    ///
    /// ⚠️ **纯 CoreGraphics / ImageIO，严禁碰 AppKit**（2026-07-27 定）：本方法在 `LANServer` 的
    /// 服务 queue 上被调用（`pageProvider` → `AppModel.renderPage`），而旧实现走
    /// `page.thumbnail` → `NSImage` → `tiffRepresentation` → `NSBitmapImageRep(data:)`
    /// → `representation(using: .png)`，既是在后台线程用 AppKit，又要多一次 ~13MB 未压缩 TIFF
    /// 中转 + 一次全量重解码。改用与 Mac 阅读区同一条渲染原语 `PageBitmap.render`（CGContext）
    /// + `CGImageDestination` 直接编码。
    static func image(page: PDFPage, pixelWidth: CGFloat, format: Format) -> Data? {
        let disp = PageBitmap.displaySize(page)
        guard disp.width > 0, disp.height > 0 else { return nil }
        let px = Int(min(pixelWidth, disp.width * 4).rounded())
        let t0 = CFAbsoluteTimeGetCurrent()
        guard px > 0, let cg = PageBitmap.render(page: page, pixelWidth: px) else { return nil }
        let t1 = CFAbsoluteTimeGetCurrent()
        let data = encode(cg, format: format)
        let t2 = CFAbsoluteTimeGetCurrent()
        // 拆开报：栅格化慢是 PDF 本身重（扫描件/大图/透明组），编码慢是像素多。两者的治法不一样。
        PadLog.log("  栅格 \(PadLog.ms(t1 - t0)) + \(format.name) 编码 \(PadLog.ms(t2 - t1))"
            + "，\(cg.width)×\(cg.height)px → \((data?.count ?? 0) / 1024)KB")
        return data
    }

    /// CGImage → 编码字节。**非 private**：框选截图（`PageSnipRender`）拼完页面切片后要走同一条
    /// 编码路径，别再复制一份 `CGImageDestination` 样板。
    static func encode(_ image: CGImage, format: Format) -> Data? {
        let buf = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            buf, format.utType, 1, nil) else { return nil }
        var opts: [CFString: Any] = [:]
        if case .jpeg(let q) = format { opts[kCGImageDestinationLossyCompressionQuality as CFString] = q }
        CGImageDestinationAddImage(dest, image, opts as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return buf as Data
    }
}
