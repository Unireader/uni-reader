import Foundation
import CoreGraphics
import Darwin

/// 进程真实内存的诊断汇总（设置页「渲染」区块显示；排查时也可以直接打印 `MemoryDiag.report()`）。
///
/// 2026-09-10 的教训：设置页只显示「缓存已用 366MB」，活动监视器却是 2.34GB——缓存那一行
/// **只是 LRU 里的那部分**，页位图还有另外两个持有者它没算：
///  1. **视图层**（各窗口阅读区的 `images`/`tiles`/`inkSnaps`、参考窗、缩略图栏）——LRU 淘汰只是
///     放掉缓存这一份引用，视图还攥着就不会释放；开几个窗口就是几套。
///  2. **CoreAnimation 合成副本**：`vmmap` 实测 49 张存活位图 ↔ 46 块 CoreAnimation 区域，
///     **字节数逐一相等**——CA 的副本跟着 `CGImage` 的生命周期走（曾显示过的图只要还活着副本就在），
///     不是「只有挂在屏幕上的才有」。所以每一张活着的页位图都是 ×2。
/// 加上夜间反色走 `CIContext.createCGImage` 出的图不进 `mmap` 也不进 `liveImages`（又 237MB 没入账），
/// 三笔一加就是 2.3GB。本文件把这三笔都摆到台面上；`PageHoldings` 顺带把视图持有量回报给
/// `PageRenderEngine`，让「缓存上限」变成**页位图总预算**（见 `setExternalHoldings`）。
enum MemoryDiag {
    /// 活动监视器「内存」列的同一口径（`phys_footprint`，含被压缩/换出的部分）。
    static func footprintBytes() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? Int(info.phys_footprint) : 0
    }

    /// malloc 堆：`used` = 真在用的字节；`retained` = 已 free 但分配器攥着没还给内核的
    /// （大块解码缓冲、碎片化的小块区）。后者照样算在活动监视器里，关掉全部文档后剩下的
    /// 几百 MB 主要就是它，不是谁还持有着对象。都不含 `mmap` 的页位图与 CA 副本。
    static func mallocStats() -> (used: Int, retained: Int) {
        let s = mstats()
        return (Int(s.bytes_used), Int(s.bytes_free))
    }

    static func mb(_ bytes: Int) -> String { "\(bytes >> 20) MB" }

    /// 一份完整的占用快照（各项都是真实字节；页位图与 CA 副本分开列）。
    struct Snapshot {
        var footprint: Int
        var liveCount: Int
        var liveBytes: Int          // 我们自己 mmap 的页位图（含缩略图、参考窗、夜间图）
        var cacheBaseCount: Int
        var cacheBaseBytes: Int     // 真实字节（已除去 copiesPerImage）
        var cacheTileCount: Int
        var cacheTileBytes: Int
        var cacheLimitBytes: Int    // 用户设的总上限（成本口径 = 已含 CA 副本）
        var cacheEffectiveBytes: Int // 扣掉视图持有量后缓存实际还能用的额度（成本口径）
        var holdings: [PageHolding]
        var mallocUsed: Int
        var mallocRetained: Int     // 已 free、分配器未归还（见 `mallocStats`）

        var heldBytes: Int { holdings.reduce(0) { $0 + $1.bytes } }
        var heldCount: Int { holdings.reduce(0) { $0 + $1.count } }
        /// 页位图这一项在活动监视器里的真实体积 ≈ 我们的缓冲 + CA 副本。
        var bitmapFootprint: Int { liveBytes * 2 }
    }

    static func snapshot() -> Snapshot {
        let live = PageBitmap.liveImages
        let c = PageRenderEngine.shared.cacheStats
        let m = mallocStats()
        return Snapshot(footprint: footprintBytes(),
                        liveCount: live.count, liveBytes: live.bytes,
                        cacheBaseCount: c.baseCount, cacheBaseBytes: c.baseBytes,
                        cacheTileCount: c.tileCount, cacheTileBytes: c.tileBytes,
                        cacheLimitBytes: c.limit, cacheEffectiveBytes: c.effectiveLimit,
                        holdings: PageHoldings.shared.snapshot,
                        mallocUsed: m.used, mallocRetained: m.retained)
    }

    /// 纯文本报告（多行），日志/终端排查用；设置页用 `Snapshot` 自己排版。
    static func report() -> String {
        let s = snapshot()
        var lines: [String] = []
        lines.append("footprint \(mb(s.footprint))")
        lines.append("page bitmaps alive \(s.liveCount) × \(mb(s.liveBytes)) (+CA copies ≈ \(mb(s.liveBytes)))")
        lines.append("  cache \(s.cacheBaseCount)+\(s.cacheTileCount) \(mb(s.cacheBaseBytes + s.cacheTileBytes))"
                     + " · limit \(mb(s.cacheLimitBytes)) effective \(mb(s.cacheEffectiveBytes))")
        lines.append("  held by views \(s.heldCount) \(mb(s.heldBytes))")
        for h in s.holdings { lines.append("    " + h.describe) }
        lines.append("malloc used \(mb(s.mallocUsed)) · freed but retained \(mb(s.mallocRetained))")
        return lines.joined(separator: "\n")
    }
}

/// 一个视图持有者（阅读区 / 参考窗 / 缩略图栏）此刻攥着的页位图。
struct PageHolding {
    enum Kind: String { case reader, ref, thumbs }
    var kind: Kind
    var label: String
    var active: Bool
    var realized: ClosedRange<Int>?
    var imageCount = 0, imageBytes = 0
    var tileCount = 0, tileBytes = 0
    var snapCount = 0, snapBytes = 0

    var count: Int { imageCount + tileCount + snapCount }
    var bytes: Int { imageBytes + tileBytes + snapBytes }

    /// 基图 / 贴片分开回报（缓存那边也是两个池、各自扣额度）。
    var baseBytes: Int { imageBytes + snapBytes }

    var describe: String {
        var s = "[\(kind.rawValue)\(active ? "*" : "")] \(label)"
        if let r = realized { s += " realized \(r.lowerBound + 1)…\(r.upperBound + 1)" }
        s += " · \(imageCount) img \(MemoryDiag.mb(imageBytes))"
        if tileCount > 0 { s += " · \(tileCount) tile \(MemoryDiag.mb(tileBytes))" }
        if snapCount > 0 { s += " · \(snapCount) snap \(MemoryDiag.mb(snapBytes))" }
        return s
    }

    static func bytes(of image: CGImage) -> Int { image.bytesPerRow * image.height }
}

/// 视图层持有量台账（键 = 持有者的 clientID，与渲染引擎的 wanted 隔离键同一个）。
///
/// 每个持有者在自己的 body 求值里回报一次（`ReaderSurface.contentBody` / `RefPageStream.content` /
/// `ThumbnailListView.keep`），视图消失时 `remove`。总量一变就转告 `PageRenderEngine`，
/// 缓存据此让出额度——「上限 512MB」从此约束的是**页位图总量**（视图挂载 + 缓存），不再只是缓存。
final class PageHoldings {
    static let shared = PageHoldings()

    private let lock = NSLock()
    private var table: [String: PageHolding] = [:]
    private var lastBase = -1, lastTile = -1

    func report(_ h: PageHolding, client: String) {
        lock.lock()
        table[client] = h
        let (b, t) = totalsLocked()
        let changed = b != lastBase || t != lastTile
        if changed { lastBase = b; lastTile = t }
        lock.unlock()
        if changed { PageRenderEngine.shared.setExternalHoldings(baseBytes: b, tileBytes: t) }
    }

    func remove(client: String) {
        lock.lock()
        guard table.removeValue(forKey: client) != nil else { lock.unlock(); return }
        let (b, t) = totalsLocked()
        lastBase = b; lastTile = t
        lock.unlock()
        PageRenderEngine.shared.setExternalHoldings(baseBytes: b, tileBytes: t)
    }

    var snapshot: [PageHolding] {
        lock.lock(); defer { lock.unlock() }
        return table.values.sorted { ($0.active ? 0 : 1, $0.kind.rawValue, $0.label) < ($1.active ? 0 : 1, $1.kind.rawValue, $1.label) }
    }

    private func totalsLocked() -> (base: Int, tile: Int) {
        var b = 0, t = 0
        for h in table.values { b += h.baseBytes; t += h.tileBytes }
        return (b, t)
    }
}
