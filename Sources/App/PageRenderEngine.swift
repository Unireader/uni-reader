import Foundation
import CoreGraphics
import CoreImage
import PDFKit

/// 页图渲染引擎：单串行后台队列 + 限容 NSCache。主线程零渲染（硬指标 1/2）。
/// `setWanted` 声明「当前还需要的键」，过期请求在出队时直接丢弃（快滚/连续缩放不做无用功）。
/// 完成回调在主线程，调用方负责校验后**原位替换**图（零闪烁纪律 2）。
final class PageRenderEngine {
    static let shared = PageRenderEngine()

    struct Request {
        var key: String
        var page: PDFPage
        var pixelWidth: Int?          // 整页渲染
        var tileRect: CGRect?         // 贴片：页显示坐标（pt，左上原点）
        var tileScale: CGFloat = 1    // 贴片：像素/pt
        var night: Bool
    }

    private final class Box {
        let image: CGImage
        init(_ i: CGImage) { image = i }
    }

    private let cache = NSCache<NSString, Box>()
    private let queue = DispatchQueue(label: "com.xvan.unireader.pagerender", qos: .userInitiated)
    private let lock = NSLock()
    private var inFlight = Set<String>()
    private var wantedByClient: [String: Set<String>] = [:]   // 多窗口各自声明，互不覆盖
    private var ci: CIContext?        // 仅渲染队列使用，懒建

    private init() {
        cache.totalCostLimit = 400 << 20   // ~400MB（按解码字节计费，LRU）
    }

    static func baseKey(doc: String, page: Int, pixelWidth: Int, night: Bool) -> String {
        "\(doc)#\(page)#w\(pixelWidth)#n\(night ? 1 : 0)"
    }

    static func tileKey(doc: String, page: Int, normRect: CGRect, scale: CGFloat, night: Bool) -> String {
        String(format: "%@#%d#t%.3f_%.3f_%.3f_%.3f#s%.2f#n%d",
               doc, page, normRect.minX, normRect.minY, normRect.width, normRect.height,
               scale, night ? 1 : 0)
    }

    func cached(_ key: String) -> CGImage? { cache.object(forKey: key as NSString)?.image }

    /// 声明某窗口当前需要的键集合（该窗口旧集合作废；出队时任何窗口都不要的请求直接丢弃）。
    /// 窗口关闭/换文档时传空集合清理。
    func setWanted(_ keys: Set<String>, client: String) {
        lock.lock()
        if keys.isEmpty { wantedByClient.removeValue(forKey: client) } else { wantedByClient[client] = keys }
        lock.unlock()
    }

    private func isWanted(_ key: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return wantedByClient.values.contains { $0.contains(key) }
    }

    /// 入队渲染。缓存命中/重复在途都不会重复渲染。
    func request(_ r: Request, completion: @escaping (String, CGImage) -> Void) {
        if let hit = cached(r.key) {
            completion(r.key, hit)
            return
        }
        lock.lock()
        if inFlight.contains(r.key) { lock.unlock(); return }
        inFlight.insert(r.key)
        lock.unlock()

        queue.async { [self] in
            defer { lock.lock(); inFlight.remove(r.key); lock.unlock() }
            guard isWanted(r.key) else { return }
            if let hit = cached(r.key) {
                DispatchQueue.main.async { completion(r.key, hit) }
                return
            }
            var img: CGImage?
            if let rect = r.tileRect {
                img = PageBitmap.renderTile(page: r.page, subRect: rect, scale: r.tileScale)
            } else if let pw = r.pixelWidth {
                img = PageBitmap.render(page: r.page, pixelWidth: pw)
            }
            guard var out = img else { return }
            if r.night {
                if ci == nil { ci = CIContext() }
                if let inv = PageBitmap.invert(out, ci: ci!) { out = inv }
            }
            cache.setObject(Box(out), forKey: r.key as NSString, cost: out.bytesPerRow * out.height)
            let final = out
            DispatchQueue.main.async { completion(r.key, final) }
        }
    }
}
