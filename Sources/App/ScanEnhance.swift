import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

/// 扫描页增强（2026-09-23 加）：**只在出图时处理，不改 PDF**。给扫描件去底色 / 阴影 / 杂色、让字更黑更清楚。
///
/// 滤镜链（原型与参数取舍见当天会话：先出 A/B/C/D 四版对比，用户嫌「上一版有颗粒感」后定下 C/D 这套）：
/// 1. 降噪——先把 JPEG 压缩噪点压掉，不然后面几步会把它们放大成颗粒；
/// 2. 估纸色——邻域取最亮（抹掉字）再模糊，得到「这页纸本来的颜色」，阴影 / 蓝条 / 发黄都算在里面；
/// 3. 原图 ÷ 纸色——纸面统一成白，墨迹对比不变；
/// 4. 软色阶——色调曲线只把接近白的推成白、暗部适度压深，中间灰保留（**硬切色阶就是颗粒感的来源**）；
/// 5. 轻锐化（可关）、去色（可选，纯黑白书用）；
/// 6. 「精细处理」开着时以上全部在 2 倍分辨率上做，再缩回目标尺寸（缩小顺带把字边磨平）。
///
/// 所有半径都按**页面 pt** 定，再乘「像素/pt」换算——同一套参数在 fit 基图与高倍贴片上效果一致。
/// 贴片四周要多渲一圈 `marginPt`（纸色估计要看邻域），处理完再裁回，否则贴片接缝处发灰。
///
/// 开关**按文档（内容哈希）记在本机**（`UserDefaults`，不进库、不同步平板）；参数全局一份，设置 ›「阅读」里调。
/// 本版只作用于阅读区（`ReaderView`）；参考窗、缩略图、草稿纸、平板、MCP / OCR 出图一律仍是原图。
struct ScanEnhanceParams: Equatable {
    var denoise: Double      // 0…1
    var whitePoint: Double   // 0.80…0.98：亮度高于它的一律推成纯白
    var inkDarken: Double    // 0…1：暗部加深的程度
    var sharpen: Double      // 0…1
    var grayscale: Bool
    var supersample: Bool

    static let defaults = ScanEnhanceParams(denoise: 0.5, whitePoint: 0.92, inkDarken: 0.7,
                                            sharpen: 0.4, grayscale: false, supersample: true)

    /// UserDefaults 键（设置页 `@AppStorage` 与这里同名）。
    enum Key {
        static let denoise = "scanEnhance.denoise"
        static let whitePoint = "scanEnhance.whitePoint"
        static let inkDarken = "scanEnhance.inkDarken"
        static let sharpen = "scanEnhance.sharpen"
        static let grayscale = "scanEnhance.grayscale"
        static let supersample = "scanEnhance.supersample"
        static let docs = "scanEnhance.docs"   // [contentHash]
    }

    static var current: ScanEnhanceParams {
        let d = UserDefaults.standard
        func num(_ k: String, _ def: Double) -> Double { d.object(forKey: k) == nil ? def : d.double(forKey: k) }
        func flag(_ k: String, _ def: Bool) -> Bool { d.object(forKey: k) == nil ? def : d.bool(forKey: k) }
        let z = defaults
        return ScanEnhanceParams(denoise: num(Key.denoise, z.denoise),
                                 whitePoint: num(Key.whitePoint, z.whitePoint),
                                 inkDarken: num(Key.inkDarken, z.inkDarken),
                                 sharpen: num(Key.sharpen, z.sharpen),
                                 grayscale: flag(Key.grayscale, z.grayscale),
                                 supersample: flag(Key.supersample, z.supersample))
    }

    /// 页图缓存键里的那一段（参数一变键就变，磁盘缓存同理）。只含十六进制字符——
    /// `PageRenderEngine.isTileKey` 靠 `#t` 认贴片，这里不能出现 `t`。
    var signature: String {
        func q(_ v: Double) -> Int { Int((v * 100).rounded()) }
        let s = "\(q(denoise)),\(q(whitePoint)),\(q(inkDarken)),\(q(sharpen)),\(grayscale),\(supersample)"
        var h: UInt32 = 2166136261   // FNV-1a
        for b in s.utf8 { h = (h ^ UInt32(b)) &* 16777619 }
        return String(h, radix: 16)
    }

    /// 贴片四周多渲的一圈（pt）= 纸色估计的影响范围（取最亮半径 + 3 倍模糊半径）。
    static let marginPt: CGFloat = ScanEnhance.maxRadiusPt + 3 * ScanEnhance.blurRadiusPt
}

enum ScanEnhance {
    static let maxRadiusPt: CGFloat = 3     // 邻域取最亮：要比笔画宽，字才抹得干净
    static let blurRadiusPt: CGFloat = 6

    // MARK: 按文档开关（本机）

    static func isOn(_ contentHash: String) -> Bool {
        guard !contentHash.isEmpty else { return false }
        return (UserDefaults.standard.stringArray(forKey: ScanEnhanceParams.Key.docs) ?? []).contains(contentHash)
    }

    static func toggle(_ contentHash: String) {
        guard !contentHash.isEmpty else { return }
        let d = UserDefaults.standard
        var list = d.stringArray(forKey: ScanEnhanceParams.Key.docs) ?? []
        if let i = list.firstIndex(of: contentHash) { list.remove(at: i) } else { list.append(contentHash) }
        d.set(list, forKey: ScanEnhanceParams.Key.docs)
    }

    /// 这篇当前该用的参数（没开 = nil）。
    static func params(for contentHash: String) -> ScanEnhanceParams? {
        isOn(contentHash) ? .current : nil
    }

    // MARK: 滤镜链

    /// 对一张 CIImage 做增强。`pxPerPt` = 这张图的像素/pt（半径换算用）。输出 extent 与输入相同。
    static func apply(_ src: CIImage, pxPerPt: CGFloat, _ p: ScanEnhanceParams) -> CIImage {
        let ext = src.extent
        var img = src
        if p.denoise > 0.001 {
            let nr = CIFilter.noiseReduction()
            nr.inputImage = img
            nr.noiseLevel = Float(0.06 * p.denoise)
            nr.sharpness = 0.2
            img = nr.outputImage?.cropped(to: ext) ?? img
        }
        // 纸色：邻域取最亮 → 模糊。clampedToExtent 让页边的估计不被画布外的透明拉暗。
        let mx = CIFilter.morphologyMaximum()
        mx.inputImage = img.clampedToExtent()
        mx.radius = Float(max(1, maxRadiusPt * pxPerPt))
        let bl = CIFilter.gaussianBlur()
        bl.inputImage = mx.outputImage
        bl.radius = Float(max(1, blurRadiusPt * pxPerPt))
        if let bg = bl.outputImage?.cropped(to: ext) {
            // divideBlendMode：结果 = background ÷ input，这里 background 是原图、input 是纸色
            let div = CIFilter.divideBlendMode()
            div.inputImage = bg
            div.backgroundImage = img
            if let out = div.outputImage { img = out.cropped(to: ext) }
        }
        let cl = CIFilter.colorClamp()
        cl.inputImage = img
        img = cl.outputImage ?? img
        // 软色阶（五点曲线）：d = 暗部加深，w = 白点
        let d = CGFloat(max(0, min(1, p.inkDarken)))
        let w = CGFloat(max(0.8, min(0.98, p.whitePoint)))
        let tc = CIFilter.toneCurve()
        tc.inputImage = img
        tc.point0 = CGPoint(x: 0, y: 0)
        tc.point1 = CGPoint(x: 0.3, y: 0.3 - 0.18 * d)
        tc.point2 = CGPoint(x: 0.6, y: 0.6 - 0.1 * d)
        tc.point3 = CGPoint(x: w - 0.07, y: 0.97)
        tc.point4 = CGPoint(x: w, y: 1)
        img = tc.outputImage?.cropped(to: ext) ?? img
        if p.sharpen > 0.001 {
            let us = CIFilter.unsharpMask()
            us.inputImage = img
            us.radius = Float(max(0.5, 1 * pxPerPt))
            us.intensity = Float(0.9 * p.sharpen)
            img = us.outputImage?.cropped(to: ext) ?? img
        }
        if p.grayscale {
            let cc = CIFilter.colorControls()
            cc.inputImage = img
            cc.saturation = 0
            img = cc.outputImage ?? img
        }
        return img
    }
}
