import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// 图片本体的**文件层**（`IMAGE-NOTE-PLAN.md §2.1`）：`<工作区>/Images/<sha256>.<ext>`。
///
/// 只认 Foundation + ImageIO，不碰库、不碰 UI —— `LibraryStore` 管行，这里管字节，
/// `spike/image-store-test.swift` 把两者拼起来测。所有写入都是「先 `.part` 再原子改名」
/// （同 `MirrorBuilder.copyAtomically`）：中途拔盘只会留一个 `.part`，不会留一张只写了一半、
/// 看着像好的图。
enum ImageAssets {

    /// 存进工作区的形态：格式已归一、尺寸已限制、hash 已算。
    struct Prepared: Equatable {
        var data: Data
        var sha256: String
        var ext: String
        var width: Int
        var height: Int
    }

    /// 原字节直接存的四种（网页/安卓也都认）。其它能解的格式一律转 PNG。
    static let passthroughExts: Set<String> = ["png", "jpg", "gif", "webp"]
    /// 长边上限（像素）：笔记里不需要原图级分辨率，一张 20MB 的照片塞进笔记只会拖慢一切。
    static let maxLongEdge = 4096

    static let folderName = "Images"

    static func folder(in workspace: URL) -> URL {
        workspace.appendingPathComponent(folderName, isDirectory: true)
    }
    static func url(in workspace: URL, sha256: String, ext: String) -> URL {
        folder(in: workspace).appendingPathComponent("\(sha256).\(ext)")
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - 归一化

    /// 把任意能解的图片字节整理成可入库的形态：
    ///  · png/jpg/gif/webp 且长边不超限 → **原字节原样**（不重编码；hash 就是原文件的 hash）；
    ///  · 其它格式（HEIC/TIFF/BMP…）或超限 → 重采样/转码成 PNG。
    /// 解不出来（不是图）→ nil。
    static func prepare(_ data: Data) -> Prepared? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(src) > 0 else { return nil }
        let ext = fileExtension(of: src)
        let (w, h) = pixelSize(src)
        guard w > 0, h > 0 else { return nil }
        if let ext, passthroughExts.contains(ext), max(w, h) <= maxLongEdge {
            return Prepared(data: data, sha256: sha256(data), ext: ext, width: w, height: h)
        }
        // 需要转码/缩小：让 ImageIO 直接出一张不超限的缩略（比先整张解出来再缩省内存）
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,      // 带上 EXIF 方向，别存一张躺着的照片
            kCGImageSourceThumbnailMaxPixelSize: maxLongEdge,
            kCGImageSourceShouldCache: false,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary),
              let png = encodePNG(cg) else { return nil }
        return Prepared(data: png, sha256: sha256(png), ext: "png", width: cg.width, height: cg.height)
    }

    /// PDF 节选那条路拿到的是现成的 `CGImage`，直接编 PNG。
    static func prepare(_ image: CGImage) -> Prepared? {
        guard let png = encodePNG(image) else { return nil }
        return Prepared(data: png, sha256: sha256(png), ext: "png", width: image.width, height: image.height)
    }

    static func encodePNG(_ image: CGImage) -> Data? {
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }

    /// 只解尺寸（读 properties，不解像素；带 EXIF 方向的照片按旋转后的宽高报）。
    static func pixelSize(_ src: CGImageSource) -> (Int, Int) {
        guard let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { return (0, 0) }
        let w = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
        let h = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
        let orient = (props[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        return orient >= 5 ? (h, w) : (w, h)     // 5~8 = 转了 90°，宽高对调
    }

    /// ImageIO 认出的格式 → 我们的扩展名（不在四种里的返回 nil = 需要转 PNG）。
    static func fileExtension(of src: CGImageSource) -> String? {
        guard let uti = CGImageSourceGetType(src) as String?, let t = UTType(uti) else { return nil }
        if t.conforms(to: .png) { return "png" }
        if t.conforms(to: .jpeg) { return "jpg" }
        if t.conforms(to: .gif) { return "gif" }
        if t.conforms(to: .webP) { return "webp" }
        return nil
    }

    // MARK: - 文件读写

    /// 落盘（幂等：同 sha 已在就不重写）。返回最终路径。
    @discardableResult
    static func write(_ p: Prepared, in workspace: URL) throws -> URL {
        let fm = FileManager.default
        let dst = url(in: workspace, sha256: p.sha256, ext: p.ext)
        if fm.fileExists(atPath: dst.path) { return dst }
        try fm.createDirectory(at: folder(in: workspace), withIntermediateDirectories: true)
        let tmp = folder(in: workspace).appendingPathComponent(".\(dst.lastPathComponent).part")
        try? fm.removeItem(at: tmp)
        try p.data.write(to: tmp, options: .atomic)
        try? fm.removeItem(at: dst)
        try fm.moveItem(at: tmp, to: dst)
        return dst
    }

    /// 把另一处的同名文件拷过来（离线镜像双向补齐用），同样 `.part` 原子写、幂等。
    static func copy(from: URL, to workspace: URL, sha256: String, ext: String) throws {
        let fm = FileManager.default
        let dst = url(in: workspace, sha256: sha256, ext: ext)
        if fm.fileExists(atPath: dst.path) { return }
        try fm.createDirectory(at: folder(in: workspace), withIntermediateDirectories: true)
        let tmp = folder(in: workspace).appendingPathComponent(".\(dst.lastPathComponent).part")
        try? fm.removeItem(at: tmp)
        try fm.copyItem(at: from, to: tmp)
        try? fm.removeItem(at: dst)
        try fm.moveItem(at: tmp, to: dst)
    }

    static func exists(in workspace: URL, sha256: String, ext: String) -> Bool {
        FileManager.default.fileExists(atPath: url(in: workspace, sha256: sha256, ext: ext).path)
    }

    /// 删文件（不在了也算成功——清理是幂等的）。
    static func remove(in workspace: URL, sha256: String, ext: String) {
        try? FileManager.default.removeItem(at: url(in: workspace, sha256: sha256, ext: ext))
    }

    /// 从盘上解一张图（原分辨率）。`maxPixel` 非 nil = 只要一张不超过该长边的缩略（气泡/列表用，省内存）。
    static func load(_ url: URL, maxPixel: Int? = nil) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        if let maxPixel {
            let opts: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixel,
                kCGImageSourceShouldCache: false,
            ]
            return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
        }
        return CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCache: false] as CFDictionary)
    }
}
