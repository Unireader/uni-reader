import Foundation

/// 侧栏拖拽排序的纯逻辑（`SIDEBAR-DRAG-PLAN.md`）。纯 Foundation，spike 直接编。
enum SidebarOrder {
    /// 同一组里拖了几样、放到第 `index` 个位置之前（`index` 按拖之前那一组的下标，等于个数 = 放到最后）：
    /// 返回这一组的新顺序。拖动的那几样保持彼此原来的先后（多选整批一起挪）。
    static func move<ID: Hashable>(_ siblings: [ID], dragged: Set<ID>, to index: Int) -> [ID] {
        let cut = max(0, min(index, siblings.count))
        let before = siblings.prefix(cut).filter { !dragged.contains($0) }.count
        let moving = siblings.filter { dragged.contains($0) }
        var rest = siblings.filter { !dragged.contains($0) }
        rest.insert(contentsOf: moving, at: before)
        return rest
    }

    /// 一组在全局顺序里占着的那几个位置，按这一组的新顺序重新填（书库的一个分组、错题本底下的几本书，
    /// 都是全局顺序的一部分）。不属于这一组的原地不动；`group` 里有、`global` 里没有的忽略。
    static func fill<ID: Hashable>(_ global: [ID], group newOrder: [ID]) -> [ID] {
        let present = Set(global)
        let members = Set(newOrder)
        var it = newOrder.filter { present.contains($0) }.makeIterator()
        return global.map { members.contains($0) ? (it.next() ?? $0) : $0 }
    }

    /// 按存下的顺序排：存过的按存的先后；没存过的（新加的）排在最前、彼此保持传进来的先后
    /// （同书库「没排过的书在最前」，新东西出现在看得见的地方）。存的顺序里已经没有的 id 忽略。
    static func apply<T, ID: Hashable>(_ items: [T], order: [ID], id: (T) -> ID) -> [T] {
        guard !order.isEmpty else { return items }
        let rank = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        let keyed = items.enumerated().map { (i: $0.offset, item: $0.element, r: rank[id($0.element)]) }
        return keyed.sorted { a, b in
            switch (a.r, b.r) {
            case (nil, nil): return a.i < b.i
            case (nil, _): return true
            case (_, nil): return false
            case let (x?, y?): return x != y ? x < y : a.i < b.i
            }
        }.map(\.item)
    }
}
