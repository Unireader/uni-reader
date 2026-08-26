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

    /// 自研 LRU 图缓存（按解码字节计费，硬上限）。相比 `NSCache`：**不做机会性驱逐**——
    /// 只在超过上限时按最久未用淘汰，保证「滚动回看 / 换文档回看」命中之前渲染、不被系统莫名清空重渲。
    private let cache = RenderImageCache(limitBytes: 400 << 20)   // 默认 ~400MB；由设置页覆盖
    private let queue = DispatchQueue(label: "com.xvan.unireader.pagerender", qos: .userInitiated)
    private let lock = NSLock()
    private var inFlight = Set<String>()
    private var wantedByClient: [String: Set<String>] = [:]   // 多窗口各自声明，互不覆盖
    private var ci: CIContext?        // 仅渲染队列使用，懒建

    private init() {}

    /// 设置缓存上限（MB）。设置页写入、启动时套用。下限 32MB 防误设过小反而频繁重渲。
    func setCacheLimitMB(_ mb: Int) { cache.totalCostLimit = max(32, mb) << 20 }
    /// 当前缓存已用（MB），供设置页/调试显示。
    var cacheUsageMB: Int { cache.currentCost >> 20 }

    static func baseKey(doc: String, page: Int, pixelWidth: Int, night: Bool) -> String {
        "\(doc)#\(page)#w\(pixelWidth)#n\(night ? 1 : 0)"
    }

    static func tileKey(doc: String, page: Int, normRect: CGRect, scale: CGFloat, night: Bool) -> String {
        String(format: "%@#%d#t%.3f_%.3f_%.3f_%.3f#s%.2f#n%d",
               doc, page, normRect.minX, normRect.minY, normRect.width, normRect.height,
               scale, night ? 1 : 0)
    }

    /// 异色同参键（`#n0`↔`#n1` 尾缀互换；base/tile 键都以它结尾）。
    /// 夜间反色是纯像素操作且自逆（CIColorInvert+CIHueAdjust 做两次即还原），
    /// 异色图在缓存时可直接反转得到本图，免去 PDF 重渲——夜间切换提速的关键快路。
    static func flippedNightKey(_ key: String) -> String {
        key.dropLast() + (key.hasSuffix("0") ? "1" : "0")
    }

    func cached(_ key: String) -> CGImage? { cache.object(forKey: key) }

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

    /// 外部已算好的图直接写入缓存（夜间切换「原地反转」的结果喂回：收尾 settle 直接命中，
    /// 不会对同一批图二次反转/重渲）。
    func seed(_ image: CGImage, forKey key: String) {
        cache.setObject(image, forKey: key, cost: image.bytesPerRow * image.height)
    }

    /// 入队渲染。缓存命中/重复在途都不会重复渲染。
    /// 在渲染队列上跑一次自定义栅格化，完成后回主线程（框选截图 `PageSnip.render` 用）。
    ///
    /// 🔴 **必须走这条队列**：阅读区的页图渲染就在它上面，而 `PDFDocument` 不能被并发使用。
    /// 直接在主线程渲一张截图看着「更简单」，但那就是拿同一份 PDF 跟后台渲染撞车。
    func renderOffMain<T>(_ work: @escaping () -> T, completion: @escaping (T) -> Void) {
        queue.async {
            let out = work()
            DispatchQueue.main.async { completion(out) }
        }
    }

    func request(_ r: Request, completion: @escaping (String, CGImage) -> Void) {
        if let hit = cached(r.key) {
            completion(r.key, hit)
            return
        }
        let enqueuedAt = CFAbsoluteTimeGetCurrent()
        lock.lock()
        if inFlight.contains(r.key) { lock.unlock(); return }
        inFlight.insert(r.key)
        lock.unlock()

        queue.async { [self] in
            defer { lock.lock(); inFlight.remove(r.key); lock.unlock() }
            // 出队丢弃只针对「滞留」请求：调用方惯例是先 request 后 setWanted（settleRender/
            // kickBaseRenders 都如此），主线程入队窗口内 wanted 还是旧集合——此刻严格检查会把
            // 新请求误判丢弃，完成回调永不触发、该页永久停在旧图（夜间切换「切不回来」的根因）。
            // 故入队 1s 内一律放行；滞留超 1s 且任何窗口都不再要的（快滚/连缩残留）才丢弃。
            guard CFAbsoluteTimeGetCurrent() - enqueuedAt < 1 || isWanted(r.key) else { return }
            if let hit = cached(r.key) {
                DispatchQueue.main.async { completion(r.key, hit) }
                return
            }
            var out: CGImage?
            // 夜间快路：异色同参图已在缓存 → 直接反转（纯像素、自逆），跳过 PDF 重渲——
            // 夜间切换从「整窗 + 预热页全部重渲 PDF」变「整窗反转缓存图」，毫秒级。
            if let src = cached(Self.flippedNightKey(r.key)) {
                if ci == nil { ci = CIContext() }
                out = PageBitmap.invert(src, ci: ci!)
            }
            if out == nil {
                if let rect = r.tileRect {
                    out = PageBitmap.renderTile(page: r.page, subRect: rect, scale: r.tileScale)
                } else if let pw = r.pixelWidth {
                    out = PageBitmap.render(page: r.page, pixelWidth: pw)
                }
                if r.night, let raw = out {
                    if ci == nil { ci = CIContext() }
                    if let inv = PageBitmap.invert(raw, ci: ci!) { out = inv }
                }
            }
            guard let out else { return }
            cache.setObject(out, forKey: r.key, cost: out.bytesPerRow * out.height)
            let final = out
            DispatchQueue.main.async { completion(r.key, final) }
        }
    }
}

/// 线程安全 LRU 图缓存（双向链表 + 字典，O(1) 命中/淘汰）。按解码字节计费，超上限按最久未用淘汰。
/// 与 NSCache 的差别：**只按容量淘汰，不随系统内存压力机会性清空** → 回看命中率稳定。
private final class RenderImageCache {
    private final class Node {
        let key: String
        var image: CGImage
        var cost: Int
        var prev: Node?
        var next: Node?
        init(_ key: String, _ image: CGImage, _ cost: Int) { self.key = key; self.image = image; self.cost = cost }
    }

    private var map: [String: Node] = [:]
    private var head: Node?          // 最近使用
    private var tail: Node?          // 最久未用
    private var totalCost = 0
    private var limit: Int
    private let lock = NSLock()

    init(limitBytes: Int) { limit = max(1, limitBytes) }

    var totalCostLimit: Int {
        get { lock.lock(); defer { lock.unlock() }; return limit }
        set { lock.lock(); limit = max(1, newValue); trim(); lock.unlock() }
    }
    var currentCost: Int { lock.lock(); defer { lock.unlock() }; return totalCost }

    func object(forKey key: String) -> CGImage? {
        lock.lock(); defer { lock.unlock() }
        guard let n = map[key] else { return nil }
        moveToHead(n)
        return n.image
    }

    func setObject(_ image: CGImage, forKey key: String, cost: Int) {
        lock.lock(); defer { lock.unlock() }
        let c = max(0, cost)
        if let n = map[key] {
            totalCost += c - n.cost
            n.image = image
            n.cost = c
            moveToHead(n)
        } else {
            let n = Node(key, image, c)
            map[key] = n
            addToHead(n)
            totalCost += c
        }
        trim()
    }

    // 以下链表操作均在锁内调用。
    private func addToHead(_ n: Node) {
        n.prev = nil; n.next = head
        head?.prev = n
        head = n
        if tail == nil { tail = n }
    }
    private func removeNode(_ n: Node) {
        n.prev?.next = n.next
        n.next?.prev = n.prev
        if head === n { head = n.next }
        if tail === n { tail = n.prev }
        n.prev = nil; n.next = nil
    }
    private func moveToHead(_ n: Node) {
        guard head !== n else { return }
        removeNode(n)
        addToHead(n)
    }
    private func trim() {
        while totalCost > limit, let t = tail {
            removeNode(t)
            map[t.key] = nil
            totalCost -= t.cost
        }
    }
}
