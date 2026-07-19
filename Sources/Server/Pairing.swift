import Foundation
import CoreImage
import CoreImage.CIFilterBuiltins
import AppKit

enum Pairing {
    /// 随机配对 token（128-bit），作为 WebSocket 准入校验。
    static func makeToken() -> String {
        (0..<16).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
    }

    /// 由配对 URL 生成二维码图片，供平板扫码打开采集页。
    static func qrImage(from string: String, scale: CGFloat = 10) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let rep = NSCIImageRep(ciImage: scaled)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}
