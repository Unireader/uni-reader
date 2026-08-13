import Foundation
import CoreImage
import CoreImage.CIFilterBuiltins
import AppKit

enum Pairing {
    /// 随机配对 token（128-bit），作为 WebSocket 准入校验。
    static func makeToken() -> String {
        (0..<16).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
    }

    private static let tokenKey = "pairingToken"

    /// **持久**配对 token：第一次要用时生成并写进 `UserDefaults`，之后每次启动都是同一个。
    ///
    /// 为什么要持久（2026-08-12 用户定）：安卓输入板的「历史设备」记着 host+token，Mac 每次重开
    /// 都换一个的话，点历史条目必然 authFail，那份名单就只剩「省了打 IP」这点用处。
    /// 泄露风险与原来同量级——这个 token 一直明晃晃地印在面板的二维码与地址栏里，
    /// 真要换用面板上的「重置配对码」（[resetToken]）。
    static func persistentToken() -> String {
        if let t = UserDefaults.standard.string(forKey: tokenKey), !t.isEmpty { return t }
        let t = makeToken()
        UserDefaults.standard.set(t, forKey: tokenKey)
        return t
    }

    /// 换一张配对码并持久化。旧码立即作废——已配对的平板（含它的「历史设备」条目）都要重扫。
    static func resetToken() -> String {
        let t = makeToken()
        UserDefaults.standard.set(t, forKey: tokenKey)
        return t
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
