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

    /// 一张页图在进程里的**真实份数**（2026-08-29 vmmap 实测）。原本是 **3**：同一张图同时存在于
    /// 三个 zone，精确字节数互不相同（是三份真拷贝，不是同一批物理页被重复计账）——
    ///   `MALLOC_LARGE`(DefaultPurgeableMallocZone) 17,432,576 B  CGImage 像素缓冲
    ///   `CG raster data`                 (SM=COW)  17,383,424 B  CoreGraphics 栅格副本
    ///   `CoreAnimation`                  (SM=SHM)  17,498,112 B  与 WindowServer 共享的合成副本
    /// `PageBitmap.draw` 改成自持缓冲 + `CGDataProvider` 之后，中间那份**整类消失**（vmmap 里
    /// `CG raster data` 归零），只剩「我们自己的缓冲」+「正在显示的那几张的 CA 合成副本」。
    /// 实测同一时刻：存活位图 66MB ↔ CoreAnimation 68MB，故取 **2**。
    /// 改这个数前先复测：`vmmap <pid> | grep -E '^(CG raster data|CoreAnimation|MALLOC_LARGE)'`。
    private static let copiesPerImage = 2

    /// 一张图的真实内存代价（字节）。所有写缓存的地方一律走它，别再各写一遍 `bytesPerRow * height`。
    static func cost(of image: CGImage) -> Int { image.bytesPerRow * image.height * copiesPerImage }

    /// 自研 LRU 图缓存（按**真实**字节计费，硬上限）。相比 `NSCache`：**不做机会性驱逐**——
    /// 只在超过上限时按最久未用淘汰，保证「滚动回看 / 换文档回看」命中之前渲染、不被系统莫名清空重渲。
    /// （内核真报内存压力时另有 `installMemoryPressureHandler` 按比例收一次，与「机会性驱逐」是两回事。）
    private let cache = RenderImageCache(limitBytes: 192 << 20)
    /// 贴片**单独限额**：贴片是视口尺寸、单价常比整页基图还高，而复用率极低——`tileKey` 把归一化
    /// 矩形量化到 1/64，平移一格就是一个新键。跟基图共用一个池的话，放大后随便平移几下就能把基图
    /// 全挤光（表现为「放大平移一圈，回头每页都要重渲」）。
    private let tileCache = RenderImageCache(limitBytes: 64 << 20)
    private let queue = DispatchQueue(label: "com.xvan.unireader.pagerender", qos: .userInitiated)
    private let lock = NSLock()
    private var inFlight = Set<String>()
    private var wantedByClient: [String: Set<String>] = [:]   // 多窗口各自声明，互不覆盖
    private var ci: CIContext?        // 仅渲染队列使用，懒建
    private var pressureSource: DispatchSourceMemoryPressure?
    private let reliefQueue = DispatchQueue(label: "com.xvan.unireader.malloc-relief", qos: .utility)
    private var lastRelief: CFAbsoluteTime = 0   // `relieveMallocPressure` 的限流时刻（lock 保护）
    private var reliefWork: DispatchWorkItem?    // 同上，尾随那一次（lock 保护）

    private init() { installMemoryPressureHandler() }

    /// 设置缓存总上限（MB，= **真实**占用，已含三份系数）。基图 : 贴片 = 3 : 1。
    /// 设置页写入、启动时套用。下限 64MB 防误设过小反而频繁重渲。
    func setCacheLimitMB(_ mb: Int) {
        let total = max(64, mb) << 20
        let base = total * 3 / 4
        cache.totalCostLimit = base
        tileCache.totalCostLimit = total - base
    }
    /// 当前缓存已用（MB），供设置页/调试显示。
    var cacheUsageMB: Int { (cache.currentCost + tileCache.currentCost) >> 20 }

    /// 诊断串：缓存里各有几张 + 进程里总共活着几张页位图。
    /// 后者由 `PageBitmap` 数（缓冲是它自己 malloc/free 的，见 `PageBitmap.liveImages`）——
    /// **两者差得多 = 缓存之外还有人在持有**，那才是「缓存淘汰了内存也不降」的根因所在。
    var debugSummary: String {
        let live = PageBitmap.liveImages
        return "cache \(cache.count)+\(tileCache.count) / live \(live.count) (\(live.bytes >> 20) MB)"
    }

    /// 系统内存压力响应。
    /// ⚠️ 与本缓存「不做机会性驱逐」的设计**不冲突**：那条规矩针对的是 `NSCache` 那种没来由的清空
    /// （回看命中率飘忽），这里只在**内核真的报压力**时按固定比例收一次，且 `limit` 本身不动，
    /// 压力过去后照常回填。
    /// 把 malloc 攥着的大块还给系统。
    ///
    /// 🔴 **不催就等于没淘汰**（2026-08-29 实测定位，本轮内存排查的最后一环）：`PageBitmap` 自己数的
    /// 存活位图只剩 4 张 / 66MB（`CGDataProvider` 的 free 回调确实跑了），而同一时刻 `vmmap` 的
    /// `MALLOC_LARGE` 仍是 **632MB**。macOS 的 magazine malloc 把 free 掉的大块留在自己的 large
    /// cache 里等复用，不主动催就一直挂在进程 footprint 上——用户看到的「翻了几十页内存就上去了、
    /// 关了窗也不降」就是它。注意 `vmmap` 会把这些块照样列成「已分配」，光看它会得出「有人在持有」
    /// 的错误结论（我就被骗了一轮），**以 `PageBitmap.liveImages` 为准**。
    ///
    /// 限流 2s + 独立 utility 队列：这函数要遍历所有 zone 做 madvise/munmap，既不能每淘汰一张来一次，
    /// 也不该占着渲染队列。
    /// `force` = 跳过限流（关窗/换文档那种一次性大批清理，值得立刻还）。
    ///
    /// 限流之外**必须再排一次尾随**：限流会吞掉「最后那几次淘汰」，而渲染活动一停就再没人来催了
    /// ——实测缩放停下后存活位图只有 113MB、`MALLOC_LARGE` 却卡在 435MB 不降，就是这个缺口。
    func relieveMallocPressure(force: Bool = false) {
        let now = CFAbsoluteTimeGetCurrent()
        lock.lock()
        let doNow = force || now - lastRelief > 2
        if doNow { lastRelief = now }
        reliefWork?.cancel()
        let trailing = DispatchWorkItem { malloc_zone_pressure_relief(nil, 0) }
        reliefWork = trailing
        lock.unlock()
        if doNow { reliefQueue.async { malloc_zone_pressure_relief(nil, 0) } }
        reliefQueue.asyncAfter(deadline: .now() + 1.5, execute: trailing)
    }

    private func installMemoryPressureHandler() {
        let src = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: queue)
        src.setEventHandler { [weak self] in
            guard let self else { return }
            let critical = src.data.contains(.critical)
            cache.trim(toFraction: critical ? 0.25 : 0.5)
            tileCache.trim(toFraction: critical ? 0 : 0.5)   // 贴片重渲即可，压力大时整批丢
            relieveMallocPressure(force: true)   // 淘汰只是 free，还得催 malloc 还给系统
        }
        src.resume()
        pressureSource = src
    }

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

    /// 贴片键判别：`baseKey` 形如 `<doc>#<page>#w…`、`tileKey` 形如 `<doc>#<page>#t…`，
    /// 而 doc 是内容哈希（十六进制，不含 `#`）→ 键里出现 `#t` 只可能来自贴片标记。
    static func isTileKey(_ key: String) -> Bool { key.contains("#t") }

    private func store(_ key: String) -> RenderImageCache { Self.isTileKey(key) ? tileCache : cache }

    func cached(_ key: String) -> CGImage? { store(key).object(forKey: key) }

    /// 清掉某文档的全部缓存图（关窗 / 换文档）。**别的窗口还在看同一份文档时跳过**——
    /// 多窗口同文档是既有场景（`REQUIREMENTS.md §8.1`），一关就清会把还开着的那个窗口的图全抹掉。
    func purge(doc: String) {
        let prefix = doc + "#"
        lock.lock()
        let stillOpen = wantedByClient.values.contains { $0.contains { $0.hasPrefix(prefix) } }
        lock.unlock()
        guard !stillOpen else { return }
        cache.purge { $0.hasPrefix(prefix) }
        tileCache.purge { $0.hasPrefix(prefix) }
        relieveMallocPressure(force: true)
    }

    /// 清掉某文档某基图宽度的整套页图。缩放换宽度后旧宽度不会再被 `fallbackBase` 找到
    /// （它只查 `recentBaseWidths` 里那 4 个），留着就是纯死重：实测 ⌘+ ×5 内存单调涨 723MB、
    /// ⌘0 回 fit 只掉 24MB，就是这批图一档一套地堆着。
    /// **任何窗口当前仍声明要的键一律留着**，多窗口同文档不同缩放时互不误伤。
    func purgeBase(doc: String, pixelWidth: Int) {
        let prefix = doc + "#", needle = "#w\(pixelWidth)#n"
        lock.lock()
        let wanted = Set(wantedByClient.values.joined())
        lock.unlock()
        cache.purge { $0.hasPrefix(prefix) && $0.contains(needle) && !wanted.contains($0) }
        relieveMallocPressure(force: true)
    }

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
        store(key).setObject(image, forKey: key, cost: Self.cost(of: image))
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
            store(r.key).setObject(out, forKey: r.key, cost: Self.cost(of: out))
            // 刚才这次写入很可能顺带淘汰了旧图；淘汰只是 free，不催 malloc 不会还给系统（见该方法注释）。
            relieveMallocPressure()
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
    var count: Int { lock.lock(); defer { lock.unlock() }; return map.count }

    /// 按谓词批量删除。O(n)，只在换文档 / 换缩放档这类低频路径调用。
    func purge(where match: (String) -> Bool) {
        lock.lock(); defer { lock.unlock() }
        // 先收集再删：Dictionary 边遍历边改是未定义行为。
        let victims = map.values.filter { match($0.key) }
        for n in victims {
            removeNode(n)
            map[n.key] = nil
            totalCost -= n.cost
        }
    }

    /// 收缩到 `limit × f`。**不改 `limit`**——内存压力过去后照常回填（见
    /// `PageRenderEngine.installMemoryPressureHandler`）。
    func trim(toFraction f: Double) {
        lock.lock(); defer { lock.unlock() }
        let target = Int(Double(limit) * max(0, min(1, f)))
        while totalCost > target, let t = tail {
            removeNode(t)
            map[t.key] = nil
            totalCost -= t.cost
        }
    }

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
    /// 超上限即按最久未用淘汰。**至少留住最近用的那一张**（`t !== head`）：单张图自己就超过上限时
    /// （大窗口高倍缩放下一张贴片能到上百 MB）不留这一条的话，它会在写入后立刻自我淘汰、缓存恒空
    /// → 每次 settle 都重渲同一张图。
    private func trim() {
        while totalCost > limit, let t = tail, t !== head {
            removeNode(t)
            map[t.key] = nil
            totalCost -= t.cost
        }
    }
}
