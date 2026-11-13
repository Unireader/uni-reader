import CoreGraphics
import Foundation

// A2 结构的布局（`ANIM-BLOCK-PLAN.md §3.2`）：链表、树、图、二维表，以及指针。规矩同 `AnimLayout`：
// 高度与步无关（按所有步里最大的量），物件 id 稳定（节点按节点 id、树的值按值 id），坐标翻转。

/// 指针要指的位置：箭头尖 `point`，标签中心 `label`；同一处有几个指针时沿 `spread` 方向错开。
struct AnimAnchor {
    enum Spread { case horizontal, vertical }
    let point: CGPoint
    let label: CGPoint
    let spread: Spread
    /// 二维表：直接框住那一格。
    var cell: CGRect?
}

extension AnimPointerTarget: Hashable {
    func hash(into h: inout Hasher) {
        switch self {
        case .index(let e, let i): h.combine(0); h.combine(e); h.combine(i)
        case .node(let e, let id): h.combine(1); h.combine(e); h.combine(id)
        case .graphNode(let e, let n): h.combine(2); h.combine(e); h.combine(n)
        case .grid(let e, let r, let c): h.combine(3); h.combine(e); h.combine(r); h.combine(c)
        }
    }
}

extension AnimLayout {
    static let pointerBand: CGFloat = 26

    // 链表
    static let listNodeHeight: CGFloat = 30
    static let listArc: CGFloat = 22
    // 树
    static let treeLevel: CGFloat = 52
    // 图
    static let graphNode: CGFloat = 30

    /// 某元素在任一步被指针指过（要给它留指针那一条）。
    static func pointedElements(_ states: [AnimSceneState]) -> Set<String> {
        var out = Set<String>()
        for s in states { for case let t? in s.pointers.values { out.insert(t.element) } }
        return out
    }

    func structureHeight(_ e: AnimElement, width w: CGFloat, states: [AnimSceneState], nameH: CGFloat, pointed: Bool) -> CGFloat {
        let band = pointed ? Self.pointerBand : 0
        switch e.kind {
        case .list:
            return nameH + Self.listArc + Self.listNodeHeight + Self.listArc + band
        case .tree:
            let depth = max(states.map { $0.trees[e.name]?.depth ?? 0 }.max() ?? 0, 1)
            return nameH + CGFloat(depth - 1) * Self.treeLevel + Self.graphNode + 10
        case .graph:
            return nameH + graphCanvasHeight(e, width: w)
        case .sheet:
            let rows = max(states.map { $0.sheets[e.name]?.rowCount ?? 0 }.max() ?? 0, 1)
            return nameH + CGFloat(rows) * Self.sheetRow + 4
        case .grid(let values, let rows, let cols):
            let g = gridGeometry(width: w, rows: values.count, cols: values.first?.count ?? 0, rowLabels: !rows.isEmpty, colLabels: !cols.isEmpty)
            return nameH + g.colLabelH + CGFloat(values.count) * g.cell + 4 + band
        default:
            return 0
        }
    }

    // MARK: - 链表

    func listItems(_ id: String, name: String, rect: CGRect, state: AnimSceneState, tone: AnimTone, anchors: inout [AnimPointerTarget: AnimAnchor]) -> [AnimItem] {
        guard let list = state.lists[name] else { return [] }
        var items: [AnimItem] = []
        let capacity = max(run.states.flatMap { $0 }.map { $0.lists[name]?.nodes.count ?? 0 }.max() ?? 0, 1)
        // 节点宽 + 间隔（箭头），太挤就一起缩
        var nodeW: CGFloat = 44, gap: CGFloat = 30
        let need = CGFloat(capacity) * nodeW + CGFloat(capacity) * gap
        if need > rect.width {
            let k = rect.width / need
            nodeW = max(24, floor(nodeW * k)); gap = max(14, floor(gap * k))
        }
        let top = rect.minY + Self.listArc
        let h = Self.listNodeHeight
        var frames: [Int: CGRect] = [:]
        for (i, node) in list.nodes.enumerated() {
            frames[node.id] = CGRect(x: rect.minX + CGFloat(i) * (nodeW + gap), y: top, width: nodeW, height: h)
        }
        for (i, node) in list.nodes.enumerated() {
            let r = frames[node.id]!
            let t = node.tone == .normal ? tone : node.tone
            items.append(AnimItem(id: "\(id).n\(node.id)", shape: .box(r, radius: 5, fill: .fill(t), stroke: .stroke(t), lineWidth: 1, dashed: false)))
            items.append(AnimItem(id: "\(id).v\(node.id)", shape: .text(node.value, frame: r.insetBy(dx: 2, dy: 0), size: nodeW < 32 ? AnimMetrics.small : AnimMetrics.body,
                                                                         bold: false, role: .text(t), align: .center, backdrop: false)))
            anchors[.node(element: name, id: node.id)] = AnimAnchor(point: CGPoint(x: r.midX, y: r.maxY + Self.listArc - 2),
                                                                    label: CGPoint(x: r.midX, y: r.maxY + Self.listArc + Self.pointerBand / 2 + 2),
                                                                    spread: .horizontal)
            if let next = node.next, let to = frames[next], let j = list.index(of: next) {
                // id 带上指向谁：改指向时旧箭头淡出、新箭头长出来（直线硬插值成弧线会在中途缩成一团）
                items.append(AnimItem(id: "\(id).a\(node.id).\(next)", shape: .line(Self.listArrow(from: r, to: to, forward: j == i + 1), role: .stroke(.normal),
                                                                              width: 1.5, dashed: false, arrow: true, progress: 1)))
            } else {
                items.append(AnimItem(id: "\(id).null\(node.id)", shape: .text("∅", frame: CGRect(x: r.maxX + 4, y: r.minY, width: min(gap - 6, 18), height: h),
                                                                                 size: AnimMetrics.body, bold: false, role: .secondary, align: .left, backdrop: false)))
            }
        }
        if list.nodes.isEmpty {
            items.append(AnimItem(id: "\(id).emptynull", shape: .text("∅", frame: CGRect(x: rect.minX, y: top, width: 20, height: h),
                                                                     size: AnimMetrics.body, bold: false, role: .secondary, align: .left, backdrop: false)))
        }
        return items
    }

    /// 链表箭头：相邻往右是直线；其余走弧线（往右跳过的从上面绕，往回指的从下面绕）。一律 12 个点，换形状时也能插值。
    static func listArrow(from a: CGRect, to b: CGRect, forward: Bool) -> [CGPoint] {
        let n = 12
        if forward {
            let p0 = CGPoint(x: a.maxX, y: a.midY), p1 = CGPoint(x: b.minX - 1, y: b.midY)
            return (0..<n).map { k in let t = CGFloat(k) / CGFloat(n - 1); return CGPoint(x: p0.x + (p1.x - p0.x) * t, y: p0.y + (p1.y - p0.y) * t) }
        }
        let above = b.minX > a.minX
        let p0 = CGPoint(x: a.midX + (above ? 6 : -6), y: above ? a.minY : a.maxY)
        let p1 = CGPoint(x: b.midX + (above ? -6 : 6), y: above ? b.minY - 1 : b.maxY + 1)
        let lift: CGFloat = (above ? -1 : 1) * (listArc - 4)
        let c = CGPoint(x: (p0.x + p1.x) / 2, y: (above ? min(p0.y, p1.y) : max(p0.y, p1.y)) + lift * 2)
        if a == b {   // 指向自己：上面一个小圈
            let o = CGPoint(x: a.midX, y: a.minY)
            return (0..<n).map { k in
                let t = CGFloat(k) / CGFloat(n - 1) * 1.6 * .pi + 0.7 * .pi
                return CGPoint(x: o.x + 10 * cos(t), y: o.y - 9 + 9 * sin(t))
            }
        }
        return (0..<n).map { k in
            let t = CGFloat(k) / CGFloat(n - 1)
            let x = (1 - t) * (1 - t) * p0.x + 2 * (1 - t) * t * c.x + t * t * p1.x
            let y = (1 - t) * (1 - t) * p0.y + 2 * (1 - t) * t * c.y + t * t * p1.y
            return CGPoint(x: x, y: y)
        }
    }

    // MARK: - 树

    func treeItems(_ id: String, name: String, rect: CGRect, state: AnimSceneState, tone: AnimTone, anchors: inout [AnimPointerTarget: AnimAnchor]) -> [AnimItem] {
        guard let tree = state.trees[name] else { return [] }
        var items: [AnimItem] = []
        // 横向位置：二叉按中序排（左子树、自己、右子树），多叉的放在孩子中间
        var slot: [Int: CGFloat] = [:], level: [Int: Int] = [:]
        var counter: CGFloat = 0
        func place(_ nid: Int, _ depth: Int) {
            guard let n = tree.nodes[nid] else { return }
            level[nid] = depth
            if n.children.count <= 2 {
                if let l = n.children.first ?? nil { place(l, depth + 1) } else if n.children.count == 2 { counter += 0.5 }
                slot[nid] = counter
                counter += 1
                if n.children.count == 2 { if let r = n.children[1] { place(r, depth + 1) } else { counter += 0.5 } }
            } else {
                var xs: [CGFloat] = []
                for c in n.children {
                    if let c { place(c, depth + 1); xs.append(slot[c]!) } else { counter += 1 }
                }
                slot[nid] = xs.isEmpty ? counter : (xs.min()! + xs.max()!) / 2
                if xs.isEmpty { counter += 1 }
            }
        }
        if let root = tree.root { place(root, 0) }
        let slots = max(counter, 1)
        // 左右各留 26 点：指针标签画在节点左边，最左的节点也放得下
        let area = rect.insetBy(dx: 26, dy: 0)
        let slotW = min(52, area.width / slots)
        let d = min(Self.graphNode, slotW - 4)
        let left = area.minX + (area.width - slots * slotW) / 2
        func center(_ nid: Int) -> CGPoint {
            CGPoint(x: left + (slot[nid]! + 0.5) * slotW, y: rect.minY + d / 2 + 2 + CGFloat(level[nid]!) * Self.treeLevel)
        }
        // 边先画（在节点底下）
        for (nid, n) in tree.nodes where slot[nid] != nil {
            for c in n.children.compactMap({ $0 }) where slot[c] != nil {
                let a = center(nid), b = center(c)
                let len = max(hypot(b.x - a.x, b.y - a.y), 1)
                let ux = (b.x - a.x) / len, uy = (b.y - a.y) / len
                let r = d / 2
                // id 按（父, 子）：换了父节点（旋转）就是旧边淡出、新边淡入，两条都连在移动中的节点上
                items.append(AnimItem(id: "\(id).e\(nid).\(c)", shape: .line([CGPoint(x: a.x + ux * r, y: a.y + uy * r), CGPoint(x: b.x - ux * r, y: b.y - uy * r)],
                                                                              role: .grid, width: 1.5, dashed: false, arrow: false, progress: 1),
                                      link: AnimLink(from: "\(id).n\(nid)", to: "\(id).n\(c)")))
            }
        }
        for nid in tree.nodes.keys.sorted() where slot[nid] != nil {
            let n = tree.nodes[nid]!
            let c = center(nid)
            let r = CGRect(x: c.x - d / 2, y: c.y - d / 2, width: d, height: d)
            let t = n.tone == .normal ? tone : n.tone
            items.append(AnimItem(id: "\(id).n\(nid)", shape: .box(r, radius: d / 2, fill: .fill(t), stroke: .stroke(t), lineWidth: 1.2, dashed: false)))
            items.append(AnimItem(id: "\(id).v\(n.valueID)", shape: .text(n.value, frame: r.insetBy(dx: -6, dy: 0), size: d < 26 ? AnimMetrics.small : AnimMetrics.body,
                                                                           bold: false, role: .text(t), align: .center, backdrop: false)))
            anchors[.node(element: name, id: nid)] = AnimAnchor(point: CGPoint(x: r.minX - 1, y: c.y), label: CGPoint(x: r.minX - 18, y: c.y), spread: .vertical)
        }
        if tree.root == nil {
            let r = CGRect(x: rect.midX - d / 2, y: rect.minY + 2, width: d, height: d)
            items.append(AnimItem(id: "\(id).empty", shape: .box(r, radius: d / 2, fill: nil, stroke: .grid, lineWidth: 1, dashed: true)))
        }
        return items
    }

    // MARK: - 图

    func graphCanvasHeight(_ e: AnimElement, width w: CGFloat) -> CGFloat {
        guard case .graph(let nodes, _, let layout) = e.kind else { return 0 }
        switch layout {
        case .circle:
            return nodes.count <= 2 ? 90 : min(max(w * 0.5, 180), 280)
        case .layers:
            let levels = Self.graphLevels(e)
            let widest = levels.values.reduce(into: [Int: Int]()) { $0[$1, default: 0] += 1 }.values.max() ?? 1
            return CGFloat(widest) * 64 + 30
        }
    }

    /// 按层排：从第一个节点出发广度优先（边当无向），够不着的接在后面。
    static func graphLevels(_ e: AnimElement) -> [String: Int] {
        guard case .graph(let nodes, let edges, _) = e.kind, let first = nodes.first else { return [:] }
        var level: [String: Int] = [first: 0]
        var queue = [first]
        var maxLevel = 0
        func visit() {
            while !queue.isEmpty {
                let n = queue.removeFirst()
                for edge in edges {
                    let other = edge.a == n ? edge.b : edge.b == n ? edge.a : nil
                    if let other, level[other] == nil {
                        level[other] = level[n]! + 1
                        maxLevel = max(maxLevel, level[other]!)
                        queue.append(other)
                    }
                }
            }
        }
        visit()
        for n in nodes where level[n] == nil {
            maxLevel += 1
            level[n] = maxLevel
            queue = [n]
            visit()
        }
        return level
    }

    /// 环形排列的顺序：≤ 8 个节点时在所有顺序里挑边交叉最少的（第一个节点固定在顶上；同样少时取声明顺序在前的），否则按声明顺序。
    /// 每帧都要用，结果缓存。
    static func circleOrder(_ nodes: [String], _ edges: [AnimGraphEdgeDecl]) -> [String] {
        guard nodes.count >= 4, nodes.count <= 8, edges.count >= 2 else { return nodes }
        let key = nodes.joined(separator: ",") + "|" + edges.map { "\($0.a)-\($0.b)" }.joined(separator: ",")
        circleLock.lock()
        if let hit = circleCache[key] { circleLock.unlock(); return hit }
        circleLock.unlock()
        let index = Dictionary(uniqueKeysWithValues: nodes.enumerated().map { ($1, $0) })
        let pairs = edges.compactMap { e -> (Int, Int)? in
            guard let a = index[e.a], let b = index[e.b] else { return nil }
            return (a, b)
        }
        func crossings(_ pos: [Int]) -> Int {
            var n = 0
            for i in 0..<pairs.count {
                let (a, b) = (pos[pairs[i].0], pos[pairs[i].1])
                let lo = min(a, b), hi = max(a, b)
                for j in (i + 1)..<pairs.count {
                    let (c, d) = (pos[pairs[j].0], pos[pairs[j].1])
                    if c == a || c == b || d == a || d == b { continue }
                    if (c > lo && c < hi) != (d > lo && d < hi) { n += 1 }
                }
            }
            return n
        }
        var best = Array(0..<nodes.count), bestScore = crossings(best)
        var rest = Array(1..<nodes.count)
        // 枚举其余节点的全排列（Heap 算法）
        func permute(_ k: Int) {
            if bestScore == 0 { return }
            if k == 1 {
                let order = [0] + rest
                var pos = Array(repeating: 0, count: nodes.count)
                for (p, n) in order.enumerated() { pos[n] = p }
                let score = crossings(pos)
                if score < bestScore { bestScore = score; best = order }
                return
            }
            for i in 0..<k {
                permute(k - 1)
                if k % 2 == 0 { rest.swapAt(i, k - 1) } else { rest.swapAt(0, k - 1) }
            }
        }
        permute(rest.count)
        let result = best.map { nodes[$0] }
        circleLock.lock()
        if circleCache.count > 64 { circleCache.removeAll() }
        circleCache[key] = result
        circleLock.unlock()
        return result
    }

    nonisolated(unsafe) private static var circleCache: [String: [String]] = [:]
    private static let circleLock = NSLock()

    func graphPositions(_ e: AnimElement, rect: CGRect) -> [String: CGPoint] {
        guard case .graph(let declared, let edges, let layout) = e.kind else { return [:] }
        let nodes = layout == .circle ? Self.circleOrder(declared, edges) : declared
        let r = Self.graphNode / 2
        var out: [String: CGPoint] = [:]
        switch layout {
        case .circle:
            let cx = rect.midX, cy = rect.midY + 4
            if nodes.count == 1 { return [nodes[0]: CGPoint(x: cx, y: cy)] }
            if nodes.count == 2 {
                return [nodes[0]: CGPoint(x: cx - min(rect.width / 3, 120), y: cy), nodes[1]: CGPoint(x: cx + min(rect.width / 3, 120), y: cy)]
            }
            let rx = min(rect.width / 2 - r - 36, rect.height * 0.9), ry = rect.height / 2 - r - 18
            for (i, n) in nodes.enumerated() {
                let a = -CGFloat.pi / 2 + 2 * .pi * CGFloat(i) / CGFloat(nodes.count)
                out[n] = CGPoint(x: (cx + rx * cos(a)).rounded(), y: (cy + ry * sin(a)).rounded())
            }
        case .layers:
            let level = Self.graphLevels(e)
            let levels = (level.values.max() ?? 0) + 1
            var byLevel: [Int: [String]] = [:]
            for n in nodes { byLevel[level[n] ?? 0, default: []].append(n) }
            let colW = (rect.width - 2 * (r + 30)) / CGFloat(max(levels - 1, 1))
            for (l, members) in byLevel {
                for (i, n) in members.enumerated() {
                    let x = levels == 1 ? rect.midX : rect.minX + r + 30 + CGFloat(l) * colW
                    let y = rect.minY + 24 + (rect.height - 30) * (CGFloat(i) + 0.5) / CGFloat(members.count)
                    out[n] = CGPoint(x: x.rounded(), y: y.rounded())
                }
            }
        }
        return out
    }

    func graphItems(_ id: String, element e: AnimElement, rect: CGRect, state: AnimSceneState, tone: AnimTone, anchors: inout [AnimPointerTarget: AnimAnchor]) -> [AnimItem] {
        guard let g = state.graphs[e.name] else { return [] }
        let pos = graphPositions(e, rect: rect)
        let r = Self.graphNode / 2
        var items: [AnimItem] = []
        for (k, edge) in g.edges.enumerated() {
            guard let a = pos[edge.a], let b = pos[edge.b] else { continue }
            // 两点之间来回各一条有向边：各自往旁边弯一点，不叠在一起
            let paired = edge.directed && g.edges.contains { $0.directed && $0.a == edge.b && $0.b == edge.a }
            let len = max(hypot(b.x - a.x, b.y - a.y), 1)
            let ux = (b.x - a.x) / len, uy = (b.y - a.y) / len
            let bend: CGFloat = paired ? 10 : 0
            let nx = -uy * bend, ny = ux * bend
            let p0 = CGPoint(x: a.x + ux * r + nx * 0.5, y: a.y + uy * r + ny * 0.5)
            let p1 = CGPoint(x: b.x - ux * (r + 1) + nx * 0.5, y: b.y - uy * (r + 1) + ny * 0.5)
            let mid = CGPoint(x: (p0.x + p1.x) / 2 + nx, y: (p0.y + p1.y) / 2 + ny)
            let pts = (0..<8).map { i -> CGPoint in
                let t = CGFloat(i) / 7
                return CGPoint(x: (1 - t) * (1 - t) * p0.x + 2 * (1 - t) * t * mid.x + t * t * p1.x,
                               y: (1 - t) * (1 - t) * p0.y + 2 * (1 - t) * t * mid.y + t * t * p1.y)
            }
            let t = edge.tone
            items.append(AnimItem(id: "\(id).e\(k)", shape: .line(pts, role: t == .normal ? .grid : .stroke(t), width: t == .normal ? 1.5 : 2.5,
                                                                   dashed: t == .muted, arrow: edge.directed, progress: 1)))
            if let w = edge.weight, !w.isEmpty {
                let size = AnimMetrics.measure(w, size: AnimMetrics.small)
                let c = CGPoint(x: (a.x + b.x) / 2 + nx * 1.6, y: (a.y + b.y) / 2 + ny * 1.6)
                items.append(AnimItem(id: "\(id).w\(k)", shape: .text(w, frame: CGRect(x: c.x - size.width / 2 - 3, y: c.y - size.height / 2 - 1, width: size.width + 6, height: size.height + 2),
                                                                       size: AnimMetrics.small, bold: false, role: t == .normal ? .secondary : .text(t), align: .center, backdrop: true)))
            }
        }
        for n in g.order {
            guard let c = pos[n], let node = g.nodes[n] else { continue }
            let box = CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)
            let t = node.tone == .normal ? tone : node.tone
            items.append(AnimItem(id: "\(id).n\(n)", shape: .box(box, radius: r, fill: .fill(t), stroke: .stroke(t), lineWidth: 1.2, dashed: false)))
            items.append(AnimItem(id: "\(id).t\(n)", shape: .text(n, frame: box.insetBy(dx: -4, dy: 0), size: AnimMetrics.body, bold: true, role: .text(t), align: .center, backdrop: false)))
            if !node.label.isEmpty {
                let size = AnimMetrics.measure(node.label, size: AnimMetrics.small)
                items.append(AnimItem(id: "\(id).l\(n)", shape: .text(node.label, frame: CGRect(x: c.x - size.width / 2 - 3, y: box.maxY + 2, width: size.width + 6, height: size.height + 1),
                                                                       size: AnimMetrics.small, bold: false, role: .text(t == .normal ? .active : t), align: .center, backdrop: true)))
            }
            anchors[.graphNode(element: e.name, n)] = AnimAnchor(point: CGPoint(x: c.x, y: box.minY - 1), label: CGPoint(x: c.x, y: box.minY - 16), spread: .horizontal)
        }
        return items
    }

    // MARK: - 二维表

    struct GridGeometry {
        let cell: CGFloat
        let rowLabelW: CGFloat
        let colLabelH: CGFloat
    }

    func gridGeometry(width w: CGFloat, rows: Int, cols: Int, rowLabels: Bool, colLabels: Bool) -> GridGeometry {
        let rowLabelW: CGFloat = rowLabels ? 28 : 0
        let cell = min(40, max(16, floor((w - rowLabelW) / CGFloat(max(cols, 1)))))
        return GridGeometry(cell: cell, rowLabelW: rowLabelW, colLabelH: colLabels ? 16 : 0)
    }

    func gridItems(_ id: String, name: String, rect: CGRect, state: AnimSceneState, tone: AnimTone, anchors: inout [AnimPointerTarget: AnimAnchor]) -> [AnimItem] {
        guard let g = state.grids[name] else { return [] }
        let geo = gridGeometry(width: rect.width, rows: g.rows, cols: g.cols, rowLabels: !g.rowLabels.isEmpty, colLabels: !g.colLabels.isEmpty)
        var items: [AnimItem] = []
        let x0 = rect.minX + geo.rowLabelW, y0 = rect.minY + geo.colLabelH
        let font = geo.cell < 24 ? AnimMetrics.small : AnimMetrics.body
        for (j, label) in g.colLabels.enumerated() {
            items.append(AnimItem(id: "\(id).cl\(j)", shape: .text(label, frame: CGRect(x: x0 + CGFloat(j) * geo.cell, y: rect.minY, width: geo.cell, height: 14),
                                                                    size: AnimMetrics.small, bold: true, role: .secondary, align: .center, backdrop: false)))
        }
        for (i, label) in g.rowLabels.enumerated() {
            items.append(AnimItem(id: "\(id).rl\(i)", shape: .text(label, frame: CGRect(x: rect.minX, y: y0 + CGFloat(i) * geo.cell, width: geo.rowLabelW - 4, height: geo.cell),
                                                                    size: AnimMetrics.small, bold: true, role: .secondary, align: .right, backdrop: false)))
        }
        for i in 0..<g.rows {
            for j in 0..<g.cols {
                let r = CGRect(x: x0 + CGFloat(j) * geo.cell, y: y0 + CGFloat(i) * geo.cell, width: geo.cell, height: geo.cell)
                let t = g.tones[i][j] == .normal ? tone : g.tones[i][j]
                items.append(AnimItem(id: "\(id).c\(i).\(j)", shape: .box(r, radius: 0, fill: .fill(t), stroke: .grid, lineWidth: 0.75, dashed: false)))
                if !g.values[i][j].isEmpty {
                    items.append(AnimItem(id: "\(id).v\(i).\(j)", shape: .text(g.values[i][j], frame: r.insetBy(dx: 1, dy: 0), size: font, bold: false,
                                                                                role: .text(t), align: .center, backdrop: false)))
                }
                anchors[.grid(element: name, row: i, col: j)] = AnimAnchor(point: CGPoint(x: r.midX, y: y0 + CGFloat(g.rows) * geo.cell + 1),
                                                                           label: CGPoint(x: r.midX, y: y0 + CGFloat(g.rows) * geo.cell + Self.pointerBand / 2 + 3),
                                                                           spread: .horizontal, cell: r)
            }
        }
        return items
    }

    // MARK: - 竖式

    static let sheetRow: CGFloat = 22

    /// 列宽：所有步里最宽的列数 + 最长的行尾注释都要放下；字号跟着列宽。
    func sheetGeometry(_ name: String, width w: CGFloat) -> (cell: CGFloat, font: CGFloat) {
        let all = run.states.flatMap { $0 }.compactMap { $0.sheets[name] }
        let cols = max(all.map(\.colCount).max() ?? 1, 1)
        let labelW = all.flatMap { $0.labels.values }.map { AnimMetrics.measure($0, size: AnimMetrics.small).width }.max().map { $0 + 12 } ?? 0
        let cell = min(16, max(9, floor((w - labelW) / CGFloat(cols))))
        return (cell, cell >= 14 ? AnimMetrics.body + 1 : AnimMetrics.small)
    }

    func sheetItems(_ id: String, name: String, rect: CGRect, state: AnimSceneState, tone: AnimTone) -> [AnimItem] {
        guard let sheet = state.sheets[name] else { return [] }
        let (cw, font) = sheetGeometry(name, width: rect.width)
        let rh = Self.sheetRow
        let x0 = rect.minX, y0 = rect.minY
        func cellRect(_ r: Int, _ c: Int) -> CGRect { CGRect(x: x0 + CGFloat(c) * cw, y: y0 + CGFloat(r) * rh, width: cw, height: rh) }
        var items: [AnimItem] = []
        for (r, row) in sheet.cells {
            for (c, cell) in row {
                let box = cellRect(r, c)
                let t = cell.tone == .normal ? tone : cell.tone
                if t != .normal {
                    items.append(AnimItem(id: "\(id).b\(r).\(c)", shape: .box(box.insetBy(dx: 0, dy: 2), radius: 2, fill: .fill(t), stroke: nil, lineWidth: 0, dashed: false)))
                }
                items.append(AnimItem(id: "\(id).c\(r).\(c)", shape: .text(cell.char, frame: box, size: font, bold: false,
                                                                           role: t == .normal ? .ink : .text(t), align: .center, backdrop: false)))
            }
        }
        for rule in sheet.rules {
            let y = rule.above ? y0 + CGFloat(rule.row) * rh + 1 : y0 + CGFloat(rule.row + 1) * rh - 1
            items.append(AnimItem(id: "\(id).r\(rule.row).\(rule.from).\(rule.to).\(rule.above)",
                                  shape: .line([CGPoint(x: x0 + CGFloat(rule.from) * cw, y: y), CGPoint(x: x0 + CGFloat(rule.to + 1) * cw, y: y)],
                                               role: .ink, width: 1, dashed: false, arrow: false, progress: 1)))
        }
        for a in sheet.arrows {
            let x = x0 + (CGFloat(a.col) + 0.5) * cw
            // 从起始行的字下面落到目标行的字上面
            items.append(AnimItem(id: "\(id).a\(a.fromRow).\(a.toRow).\(a.col)",
                                  shape: .line([CGPoint(x: x, y: y0 + CGFloat(a.fromRow + 1) * rh - 2), CGPoint(x: x, y: y0 + CGFloat(a.toRow) * rh + 3)],
                                               role: .secondary, width: 1, dashed: true, arrow: true, progress: 1)))
        }
        let right = x0 + CGFloat(max(sheet.colCount, run.states.flatMap { $0 }.compactMap { $0.sheets[name]?.colCount }.max() ?? 0)) * cw + 10
        for (r, text) in sheet.labels {
            items.append(AnimItem(id: "\(id).l\(r)", shape: .text(text, frame: CGRect(x: right, y: y0 + CGFloat(r) * rh, width: max(rect.maxX - right, 10), height: rh),
                                                                     size: AnimMetrics.small, bold: false, role: .secondary, align: .left, backdrop: false)))
        }
        return items
    }

    // MARK: - 指针

    func pointerItems(_ p: String, state: AnimSceneState, anchors: [AnimPointerTarget: AnimAnchor]) -> [AnimItem] {
        var groups: [AnimPointerTarget: [String]] = [:]
        for (name, target) in state.pointers {
            if let target, anchors[target] != nil { groups[target, default: []].append(name) }
        }
        var items: [AnimItem] = []
        for (target, names) in groups {
            let a = anchors[target]!
            let sorted = names.sorted()
            let sizes = sorted.map { AnimMetrics.measure($0, size: AnimMetrics.small, bold: true) }
            let total = a.spread == .horizontal ? sizes.map(\.width).reduce(0, +) + CGFloat(sorted.count - 1) * 6
                                                : sizes.map(\.height).reduce(0, +) + CGFloat(sorted.count - 1) * 2
            var cursor = (a.spread == .horizontal ? a.label.x : a.label.y) - total / 2
            for (k, name) in sorted.enumerated() {
                let size = sizes[k]
                let t = state.elementTones[name] ?? .active
                let center: CGPoint
                if a.spread == .horizontal {
                    center = CGPoint(x: cursor + size.width / 2, y: a.label.y)
                    cursor += size.width + 6
                } else if a.label.x < a.point.x {
                    // 标签在目标左边（树）：右缘对齐到 label.x + 8
                    center = CGPoint(x: a.label.x + 6 - size.width / 2, y: cursor + size.height / 2)
                    cursor += size.height + 2
                } else {
                    // 标签在目标右边（栈）：左缘对齐到 label.x - 8
                    center = CGPoint(x: a.label.x - 6 + size.width / 2, y: cursor + size.height / 2)
                    cursor += size.height + 2
                }
                let frame = CGRect(x: center.x - size.width / 2 - 2, y: center.y - size.height / 2, width: size.width + 4, height: size.height)
                items.append(AnimItem(id: "\(p)ptr.\(name)", shape: .text(name, frame: frame, size: AnimMetrics.small, bold: true, role: .text(t),
                                                                          align: .center, backdrop: true)))
                // 箭头：从标签边缘指到目标
                let from: CGPoint
                if a.spread == .horizontal {
                    from = CGPoint(x: center.x, y: a.label.y < a.point.y ? frame.maxY : frame.minY)
                } else {
                    from = CGPoint(x: a.label.x < a.point.x ? frame.maxX : frame.minX, y: center.y)
                }
                let tip = a.spread == .horizontal ? CGPoint(x: center.x, y: a.point.y) : a.point
                items.append(AnimItem(id: "\(p)ptra.\(name)", shape: .line([from, tip], role: .stroke(t), width: 1.5, dashed: false, arrow: true, progress: 1)))
                if let cell = a.cell, k == 0 {
                    items.append(AnimItem(id: "\(p)ptrc.\(name)", shape: .box(cell.insetBy(dx: 1, dy: 1), radius: 2, fill: nil, stroke: .stroke(t), lineWidth: 2, dashed: false)))
                }
            }
        }
        return items
    }
}
