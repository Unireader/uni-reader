import Foundation

/// 笔迹**按页窗口装载 + 淘汰**的纯函数（`INK-PAGING-PLAN.md §4`；`spike/ink-window-test.swift` 覆盖）。
///
/// `session.strokes` 不再是整篇，而是**已装载页**的集合：装载窗口 = 阅读区实化范围 ± `pad` 页，
/// 淘汰线 = 实化范围 ± `keep` 页（`keep > pad`，滞回），只在 settle 时变动（`DocTabModel.ensureInkWindow`）。
/// 内存于是与文档总笔数无关：一篇 2616 笔的文档从 ~10 MB 常驻降到几百 KB。
///
/// 这里只有集合运算与合并规则，不碰库也不碰会话；接线在 `DocTabModel`。
enum InkWindow {
    /// 实化范围两侧各多装几页。
    static let pad = 4
    /// 实化范围两侧各保留几页；再远的才淘汰。必须 > `pad`，否则来回滚一页就装一次卸一次。
    static let keep = 12

    /// 想要装载的页区间（夹进文档页数）。
    static func want(realized: ClosedRange<Int>, pageCount: Int, pad: Int = pad) -> ClosedRange<Int> {
        clamp(realized.lowerBound - pad ... realized.upperBound + pad, pageCount: pageCount)
    }

    /// 保留区间：落在外面且没被钉住的页才淘汰。
    static func keepRange(realized: ClosedRange<Int>, pageCount: Int, keep: Int = keep) -> ClosedRange<Int> {
        clamp(realized.lowerBound - keep ... realized.upperBound + keep, pageCount: pageCount)
    }

    private static func clamp(_ r: ClosedRange<Int>, pageCount: Int) -> ClosedRange<Int> {
        let hi = max(0, pageCount - 1)
        let lo = min(max(0, r.lowerBound), hi)
        return lo ... min(max(lo, r.upperBound), hi)
    }

    /// 缺页 = want − loaded − inFlight，合并成连续段（一段一条 `BETWEEN` 查询）。
    static func missing(want: ClosedRange<Int>, loaded: Set<Int>, inFlight: Set<Int> = []) -> [ClosedRange<Int>] {
        var out: [ClosedRange<Int>] = []
        var start: Int?
        for p in want {
            let have = loaded.contains(p) || inFlight.contains(p)
            if have {
                if let s = start { out.append(s ... p - 1); start = nil }
            } else if start == nil {
                start = p
            }
        }
        if let s = start { out.append(s ... want.upperBound) }
        return out
    }

    /// 淘汰集 = loaded − keep − pinned。
    static func evictable(loaded: Set<Int>, keep: ClosedRange<Int>, pinned: Set<Int>) -> Set<Int> {
        loaded.filter { !keep.contains($0) && !pinned.contains($0) }
    }

    /// 把一批刚从库里读出的页并进内存集。规则（沿用 `applyLoadedInk` 的正确性论证）：
    /// - `pages` 是这批覆盖的页；这些页上内存里**已有**的笔迹 = 装载期间新画的（或平板补发的），
    ///   它们比库批**晚**，要排在库批之后（后画的在上，z 序不乱）；
    /// - 库批里与内存重复的 id（新画→已落库→又被 SELECT 读回）以**内存版**为准、丢掉库里那份
    ///   ——内存是编辑真源，可能已经又被挪过；
    /// - 其余页原样不动。
    /// 返回并好的数组 + 真正新入账的那些（调用方据此更新 `persistedStrokes`）。
    static func merge(existing: [InkStroke], loaded: [InkStroke], pages: Set<Int>) -> (strokes: [InkStroke], added: [InkStroke]) {
        var existingIDs = Set<UUID>(); existingIDs.reserveCapacity(existing.count)
        var others: [InkStroke] = []; others.reserveCapacity(existing.count + loaded.count)
        var onPages: [InkStroke] = []
        for s in existing {
            existingIDs.insert(s.id)
            if pages.contains(s.page) { onPages.append(s) } else { others.append(s) }
        }
        let added = loaded.filter { !existingIDs.contains($0.id) }
        others.append(contentsOf: added)
        others.append(contentsOf: onPages)
        return (others, added)
    }

    /// 淘汰：把 `pages` 上的笔迹从数组里摘掉，返回摘掉的 id（调用方同步从 `persistedStrokes` 删，
    /// **同一同步块里**完成，否则紧随其后的对账会把它们当成「已擦除」去删库）。
    static func evict(from strokes: [InkStroke], pages: Set<Int>) -> (strokes: [InkStroke], removed: [UUID]) {
        var kept: [InkStroke] = []; kept.reserveCapacity(strokes.count)
        var removed: [UUID] = []
        for s in strokes {
            if pages.contains(s.page) { removed.append(s.id) } else { kept.append(s) }
        }
        return (kept, removed)
    }

    /// 一页能不能淘汰：页上每条笔迹都已按值落库（`persisted[id] == stroke`）。有未写差异就留着，下次再说。
    static func fullyPersisted(page: Int, strokes: [InkStroke], persisted: [UUID: InkStroke]) -> Bool {
        for s in strokes where s.page == page {
            guard let p = persisted[s.id], p == s else { return false }
        }
        return true
    }
}

/// 检查器「按页列表」用的全篇汇总（笔数 / 跳转落点 / 出现过的笔色）。笔迹按页窗口装载后内存里数不出全篇，
/// 只能问库（`LibraryStore.inkPageSummaries`，一条 GROUP BY）。
struct InkPageSummary: Identifiable, Equatable {
    var page: Int
    var count: Int
    var minY: Double
    var colors: [InkColor]
    var id: Int { page }

    /// `json_extract` 要解每行 payload：几千行几十毫秒，**放后台调**（`InspectorView` 的 `.task`）。
    static func load(store: LibraryStore?, documentId: String?) -> [InkPageSummary] {
        guard let store, let documentId, let rows = try? store.inkPageSummaries(documentId: documentId) else { return [] }
        return rows.map { r in
            let colors = (try? JSONDecoder().decode([InkColor].self, from: Data(r.colorsJSON.utf8))) ?? []
            return InkPageSummary(page: r.page, count: r.count, minY: r.minY, colors: colors)
        }
    }
}
