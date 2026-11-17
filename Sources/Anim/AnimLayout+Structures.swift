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
        case .tree(_, let dir):
            if dir.horizontal {
                let slots = max(states.compactMap { $0.trees[e.name] }.map { Self.treeSlots($0).count }.max() ?? 1, 1)
                return nameH + (pointed ? 14 : 0) + slots * Self.treeSlotH(pointed: pointed) + 4
            }
            let depth = max(states.map { $0.trees[e.name]?.depth ?? 0 }.max() ?? 0, 1)
            return nameH + CGFloat(depth - 1) * Self.treeLevel + Self.graphNode + 10
        case .graph:
            return nameH + graphCanvasHeight(e, width: w)
        case .sheet:
            let rows = max(states.map { $0.sheets[e.name]?.rowCount ?? 0 }.max() ?? 0, 1)
            return nameH + CGFloat(rows) * Self.sheetRow + 4
        case .bits:
            let g = bitsGeometry(e, width: w)
            return nameH + Self.bitsRuler + CGFloat(g.rows) * Self.bitsRow + 4
        case .packet:
            let levels = states.compactMap { $0.packets[e.name] }.map { Self.packetGroupLevels($0).values.max() ?? 0 }.max() ?? 0
            return nameH + Self.packetBar + Self.packetLen + CGFloat(levels) * Self.packetGroup + 4
        case .grid(let values, let rows, let cols):
            let g = gridGeometry(width: w, cols: values.first?.count ?? 0, rowLabels: rows, colLabels: !cols.isEmpty)
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

    struct TreeSlots {
        var slot: [Int: CGFloat] = [:]
        var level: [Int: Int] = [:]
        var count: CGFloat = 0
    }

    /// 每个节点排在第几格（沿「兄弟」方向）、第几层：二叉按中序排（左子树、自己、右子树），多叉的放在孩子中间。
    static func treeSlots(_ tree: AnimTreeState) -> TreeSlots {
        var out = TreeSlots()
        var counter: CGFloat = 0
        func place(_ nid: Int, _ depth: Int) {
            guard let n = tree.nodes[nid] else { return }
            out.level[nid] = depth
            if n.children.count <= 2 {
                if let l = n.children.first ?? nil { place(l, depth + 1) } else if n.children.count == 2 { counter += 0.5 }
                out.slot[nid] = counter
                counter += 1
                if n.children.count == 2 { if let r = n.children[1] { place(r, depth + 1) } else { counter += 0.5 } }
            } else {
                var xs: [CGFloat] = []
                for c in n.children {
                    if let c { place(c, depth + 1); xs.append(out.slot[c]!) } else { counter += 1 }
                }
                out.slot[nid] = xs.isEmpty ? counter : (xs.min()! + xs.max()!) / 2
                if xs.isEmpty { counter += 1 }
            }
        }
        if let root = tree.root { place(root, 0) }
        out.count = max(counter, 1)
        return out
    }

    /// 横着长的树：兄弟方向每格多高（被指针指过的留出节点上方的标签位置）。
    static func treeSlotH(pointed: Bool) -> CGFloat { pointed ? 50 : 40 }

    func treeItems(_ id: String, element e: AnimElement, rect: CGRect, state: AnimSceneState, tone: AnimTone, anchors: inout [AnimPointerTarget: AnimAnchor]) -> [AnimItem] {
        let name = e.name
        guard let tree = state.trees[name] else { return [] }
        let dir: AnimDirection = { if case .tree(_, let d) = e.kind { return d }; return .down }()
        var items: [AnimItem] = []
        let ts = Self.treeSlots(tree)
        let slots = ts.count
        let all = run.states.flatMap { $0 }.compactMap { $0.trees[name] }
        let depthMax = max(all.map(\.depth).max() ?? 1, 1)
        let pointed = Self.pointedElements(run.states.flatMap { $0 }).contains(name)
        // 左右各留 26 点：指针标签画在节点左边，最左的节点也放得下
        let area = rect.insetBy(dx: 26, dy: 0)
        let d: CGFloat
        let center: (Int) -> CGPoint
        if dir.horizontal {
            let slotH = Self.treeSlotH(pointed: pointed)
            let slotsMax = max(all.map { Self.treeSlots($0).count }.max() ?? 1, 1)
            d = min(Self.graphNode, slotH - 6)
            let levelW = depthMax > 1 ? min(110, (area.width - d) / CGFloat(depthMax - 1)) : 0
            let top = rect.minY + (pointed ? 14 : 0) + (slotsMax - slots) * slotH / 2
            center = { nid in
                let l = CGFloat(ts.level[nid]!)
                let x = dir == .right ? area.minX + d / 2 + l * levelW : area.maxX - d / 2 - l * levelW
                return CGPoint(x: x, y: top + (ts.slot[nid]! + 0.5) * slotH)
            }
        } else {
            let slotW = min(52, area.width / slots)
            d = min(Self.graphNode, slotW - 4)
            let left = area.minX + (area.width - slots * slotW) / 2
            center = { nid in
                let l = dir == .down ? ts.level[nid]! : depthMax - 1 - ts.level[nid]!
                return CGPoint(x: left + (ts.slot[nid]! + 0.5) * slotW, y: rect.minY + d / 2 + 2 + CGFloat(l) * Self.treeLevel)
            }
        }
        // 边先画（在节点底下）
        for (nid, n) in tree.nodes where ts.slot[nid] != nil {
            for c in n.children.compactMap({ $0 }) where ts.slot[c] != nil {
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
        for nid in tree.nodes.keys.sorted() where ts.slot[nid] != nil {
            let n = tree.nodes[nid]!
            let c = center(nid)
            let r = CGRect(x: c.x - d / 2, y: c.y - d / 2, width: d, height: d)
            let t = n.tone == .normal ? tone : n.tone
            items.append(AnimItem(id: "\(id).n\(nid)", shape: .box(r, radius: d / 2, fill: .fill(t), stroke: .stroke(t), lineWidth: 1.2, dashed: false)))
            items.append(AnimItem(id: "\(id).v\(n.valueID)", shape: .text(n.value, frame: r.insetBy(dx: -6, dy: 0), size: d < 26 ? AnimMetrics.small : AnimMetrics.body,
                                                                           bold: false, role: .text(t), align: .center, backdrop: false)))
            if dir.horizontal {
                // 横着长时左右两边都有边：指针标签放在节点上方
                anchors[.node(element: name, id: nid)] = AnimAnchor(point: CGPoint(x: c.x, y: r.minY - 1), label: CGPoint(x: c.x, y: r.minY - 14), spread: .horizontal)
            } else {
                anchors[.node(element: name, id: nid)] = AnimAnchor(point: CGPoint(x: r.minX - 1, y: c.y), label: CGPoint(x: r.minX - 18, y: c.y), spread: .vertical)
            }
        }
        if tree.root == nil {
            let r = CGRect(x: rect.midX - d / 2, y: rect.minY + 2, width: d, height: d)
            items.append(AnimItem(id: "\(id).empty", shape: .box(r, radius: d / 2, fill: nil, stroke: .grid, lineWidth: 1, dashed: true)))
        }
        return items
    }

    // MARK: - 图

    static let graphLayerGap: CGFloat = 72

    func graphCanvasHeight(_ e: AnimElement, width w: CGFloat) -> CGFloat {
        guard case .graph(let nodes, _, let layout, let dir, _) = e.kind else { return 0 }
        switch layout {
        case .circle:
            return nodes.count <= 2 ? 90 : min(max(w * 0.5, 180), 280)
        case .layers:
            let layers = Self.graphLayers(e)
            if dir.horizontal {
                return CGFloat(layers.map(\.count).max() ?? 1) * 64 + 30
            }
            return CGFloat(max(layers.count - 1, 0)) * Self.graphLayerGap + 70
        }
    }

    /// 分层排法的每一层（层里按顺序）：写了 `layers=` 就照它，否则从第一个节点广度优先、层里按声明顺序。
    static func graphLayers(_ e: AnimElement) -> [[String]] {
        guard case .graph(let nodes, _, _, _, let ranks) = e.kind else { return [] }
        if !ranks.isEmpty { return ranks }
        let level = graphLevels(e)
        var byLevel: [[String]] = Array(repeating: [], count: (level.values.max() ?? 0) + 1)
        for n in nodes { byLevel[level[n] ?? 0].append(n) }
        return byLevel.filter { !$0.isEmpty }
    }

    /// 节点框的半宽：名字放得进圆就是圆（半径 = graphNode / 2），放不下就拉成两头圆的长条（「控制器」「交换机 S1」）。
    static func graphHalfWidth(_ name: String) -> CGFloat {
        let r = graphNode / 2
        let w = AnimMetrics.measure(name, size: AnimMetrics.body, bold: true).width
        return w <= graphNode - 4 ? r : ceil(w / 2) + 7
    }

    /// 从框中心沿单位方向 (ux, uy) 走多远到框边：长条 = 中间一段直边 + 两头半圆；圆是它的特例。
    static func nodeExit(_ ux: CGFloat, _ uy: CGFloat, hw: CGFloat, hh: CGFloat) -> CGFloat {
        let a = max(hw - hh, 0)
        let ax = abs(ux), ay = abs(uy)
        if ay > 1e-6 {
            let t = hh / ay
            if t * ax <= a { return t }
        }
        return a * ax + sqrt(max(a * a * ax * ax - a * a + hh * hh, 0))
    }

    /// 按层排：从第一个节点出发广度优先（边当无向），够不着的接在后面。
    static func graphLevels(_ e: AnimElement) -> [String: Int] {
        guard case .graph(let nodes, let edges, _, _, _) = e.kind, let first = nodes.first else { return [:] }
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
        guard case .graph(let declared, let edges, let layout, let dir, _) = e.kind else { return [:] }
        let r = Self.graphNode / 2
        var out: [String: CGPoint] = [:]
        switch layout {
        case .circle:
            let nodes = Self.circleOrder(declared, edges)
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
            let layers = Self.graphLayers(e)
            let levels = layers.count
            if dir.horizontal {
                // 每层一列：right = 第一层在最左
                let side = (layers.flatMap { $0 }.map(Self.graphHalfWidth).max() ?? r) + 30
                let colW = (rect.width - 2 * side) / CGFloat(max(levels - 1, 1))
                for (l, members) in layers.enumerated() {
                    for (i, n) in members.enumerated() {
                        let lx = levels == 1 ? rect.midX : rect.minX + side + CGFloat(l) * colW
                        let x = dir == .right ? lx : rect.maxX - (lx - rect.minX)
                        let y = rect.minY + 24 + (rect.height - 30) * (CGFloat(i) + 0.5) / CGFloat(members.count)
                        out[n] = CGPoint(x: x.rounded(), y: y.rounded())
                    }
                }
            } else {
                // 每层一行：down = 第一层在最上
                for (l, members) in layers.enumerated() {
                    let row = dir == .down ? l : levels - 1 - l
                    for (i, n) in members.enumerated() {
                        let x = rect.minX + rect.width * (CGFloat(i) + 0.5) / CGFloat(members.count)
                        out[n] = CGPoint(x: x.rounded(), y: (rect.minY + 26 + CGFloat(row) * Self.graphLayerGap).rounded())
                    }
                }
            }
        }
        return out
    }

    func graphItems(_ id: String, element e: AnimElement, rect: CGRect, state: AnimSceneState, tone: AnimTone, anchors: inout [AnimPointerTarget: AnimAnchor]) -> [AnimItem] {
        guard let g = state.graphs[e.name] else { return [] }
        let pos = graphPositions(e, rect: rect)
        let r = Self.graphNode / 2
        var half: [String: CGFloat] = [:]
        for n in g.order { half[n] = Self.graphHalfWidth(n) }
        // 分层排法里同一层、中间隔着别的节点的边：往外弯，别从中间那些节点身上穿过去
        var layerOf: [String: (layer: Int, index: Int)] = [:]
        if case .graph(_, _, .layers, _, _) = e.kind {
            for (l, members) in Self.graphLayers(e).enumerated() { for (i, n) in members.enumerated() { layerOf[n] = (l, i) } }
        }
        var items: [AnimItem] = []
        for (k, edge) in g.edges.enumerated() {
            guard let a = pos[edge.a], let b = pos[edge.b] else { continue }
            // 两点之间来回各一条有向边：各自往旁边弯一点，不叠在一起
            let paired = edge.directed && g.edges.contains { $0.directed && $0.a == edge.b && $0.b == edge.a }
            let len = max(hypot(b.x - a.x, b.y - a.y), 1)
            let ux = (b.x - a.x) / len, uy = (b.y - a.y) / len
            let bend: CGFloat = paired ? 10 : 0
            let nx = -uy * bend, ny = ux * bend
            let ra = Self.nodeExit(ux, uy, hw: half[edge.a] ?? r, hh: r), rb = Self.nodeExit(ux, uy, hw: half[edge.b] ?? r, hh: r)
            var p0 = CGPoint(x: a.x + ux * ra + nx * 0.5, y: a.y + uy * ra + ny * 0.5)
            var p1 = CGPoint(x: b.x - ux * (rb + 1) + nx * 0.5, y: b.y - uy * (rb + 1) + ny * 0.5)
            var mid = CGPoint(x: (p0.x + p1.x) / 2 + nx, y: (p0.y + p1.y) / 2 + ny)
            var apex: CGPoint?
            if let la = layerOf[edge.a], let lb = layerOf[edge.b], la.layer == lb.layer, abs(la.index - lb.index) >= 2 {
                // 曲线顶点离连线 = 控制点偏移的一半：要越过中间节点（半径 + 留白）
                let lift = (la.index < lb.index ? -1 : 1) * 2 * (r + 12 + 6 * CGFloat(abs(la.index - lb.index) - 2))
                let c = CGPoint(x: (a.x + b.x) / 2 - uy * lift, y: (a.y + b.y) / 2 + ux * lift)
                func toward(_ from: CGPoint, _ hw: CGFloat, _ extra: CGFloat) -> CGPoint {
                    let l = max(hypot(c.x - from.x, c.y - from.y), 1)
                    let vx = (c.x - from.x) / l, vy = (c.y - from.y) / l
                    let d = Self.nodeExit(vx, vy, hw: hw, hh: r) + extra
                    return CGPoint(x: from.x + vx * d, y: from.y + vy * d)
                }
                p0 = toward(a, half[edge.a] ?? r, 0)
                p1 = toward(b, half[edge.b] ?? r, 1)
                mid = c
                apex = CGPoint(x: 0.25 * p0.x + 0.5 * c.x + 0.25 * p1.x, y: 0.25 * p0.y + 0.5 * c.y + 0.25 * p1.y)
            }
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
                let c = apex ?? CGPoint(x: (a.x + b.x) / 2 + nx * 1.6, y: (a.y + b.y) / 2 + ny * 1.6)
                items.append(AnimItem(id: "\(id).w\(k)", shape: .text(w, frame: CGRect(x: c.x - size.width / 2 - 3, y: c.y - size.height / 2 - 1, width: size.width + 6, height: size.height + 2),
                                                                       size: AnimMetrics.small, bold: false, role: t == .normal ? .secondary : .text(t), align: .center, backdrop: true)))
            }
        }
        for n in g.order {
            guard let c = pos[n], let node = g.nodes[n] else { continue }
            let hw = half[n] ?? r
            let box = CGRect(x: c.x - hw, y: c.y - r, width: 2 * hw, height: 2 * r)
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

    /// 行标题宽按最长的那个量（最多 80 点）：写死 28 时「模式串」「nextval」「cwnd」都被挤成两行。
    func gridGeometry(width w: CGFloat, cols: Int, rowLabels: [String], colLabels: Bool) -> GridGeometry {
        let rowLabelW: CGFloat = rowLabels.isEmpty ? 0 : min(80, (rowLabels.map { AnimMetrics.measure($0, size: AnimMetrics.small, bold: true).width }.max() ?? 0) + 8)
        let cell = min(40, max(11, floor((w - rowLabelW) / CGFloat(max(cols, 1)))))   // 窄屏放 20 列：最小 11（字号跟着变小）
        return GridGeometry(cell: cell, rowLabelW: rowLabelW, colLabelH: colLabels ? 16 : 0)
    }

    func gridItems(_ id: String, name: String, rect: CGRect, state: AnimSceneState, tone: AnimTone, anchors: inout [AnimPointerTarget: AnimAnchor]) -> [AnimItem] {
        guard let g = state.grids[name] else { return [] }
        let geo = gridGeometry(width: rect.width, cols: g.cols, rowLabels: g.rowLabels, colLabels: !g.colLabels.isEmpty)
        var items: [AnimItem] = []
        let x0 = rect.minX + geo.rowLabelW, y0 = rect.minY + geo.colLabelH
        let font = geo.cell < 16 ? AnimMetrics.small - 2 : geo.cell < 24 ? AnimMetrics.small : AnimMetrics.body
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
        // 窄的时候格子可以缩到 6（IP 地址的二进制一行 35 列，300 点宽也要放得下），字号跟着变小
        let cell = min(16, max(6, floor((w - labelW) / CGFloat(cols))))
        return (cell, cell >= 14 ? AnimMetrics.body + 1 : cell >= 9 ? AnimMetrics.small : AnimMetrics.small - 2)
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

    // MARK: - 首部格式图

    static let bitsRow: CGFloat = 34
    static let bitsRuler: CGFloat = 14

    struct BitsGeometry {
        let bw: CGFloat        // 每一位多宽
        let leftW: CGFloat     // 左边的字节偏移
        let rows: Int
        let width: Int
    }

    func bitsGeometry(_ e: AnimElement, width w: CGFloat) -> BitsGeometry {
        guard case .bits(let fields, let width) = e.kind else { return BitsGeometry(bw: 10, leftW: 0, rows: 1, width: 32) }
        let total = fields.map(\.bits).reduce(0, +)
        let rows = max((total + width - 1) / width, 1)
        let leftW: CGFloat = width % 8 == 0 ? 24 : 0
        let labels = run.states.flatMap { $0 }.compactMap { $0.bits[e.name] }.flatMap { $0.labels.values }
        let labelW = labels.map { AnimMetrics.measure($0, size: AnimMetrics.small).width + 10 }.max().map { min($0, w * 0.4) } ?? 0
        let bw = min(24, max(5, floor((w - leftW - labelW) / CGFloat(width))))
        return BitsGeometry(bw: bw, leftW: leftW, rows: rows, width: width)
    }

    /// 放得下的最大字号（都放不下就用最小的，折行）。
    static func fitSize(_ s: String, width: CGFloat, sizes: [CGFloat], bold: Bool = false) -> CGFloat {
        for size in sizes where AnimMetrics.measure(s, size: size, bold: bold).width <= width { return size }
        return sizes.last ?? AnimMetrics.small
    }

    /// 字段名：放得下就横排；1 位宽的控制位（URG、ACK……）放不下时像教材那样一个字母一行竖排。
    static func fieldName(_ name: String, width: CGFloat, height: CGFloat, sizes: [CGFloat]) -> (String, CGFloat) {
        let size = fitSize(name, width: width, sizes: sizes)
        if AnimMetrics.measure(name, size: size).width <= width { return (name, size) }
        let chars = name.map(String.init)
        if chars.count >= 2, chars.count <= 4, CGFloat(chars.count) * 10 <= height { return (chars.joined(separator: "\n"), 8) }
        return (name, size)
    }

    /// 一个字段占的框：跨整行的连成一个高框（128 位地址 = 4 行一个框），其余按行切段。
    static func bitFieldBoxes(offset: Int, bits: Int, width: Int) -> [(row: Int, col: Int, cols: Int, rows: Int)] {
        var out: [(Int, Int, Int, Int)] = []
        var o = offset, n = bits
        while n > 0 {
            let row = o / width, col = o % width
            if col == 0 && n >= width {
                let k = n / width
                out.append((row, 0, width, k))
                o += k * width; n -= k * width
                continue
            }
            let take = min(n, width - col)
            out.append((row, col, take, 1))
            o += take; n -= take
        }
        return out
    }

    func bitsItems(_ id: String, element e: AnimElement, rect: CGRect, state: AnimSceneState, tone: AnimTone) -> [AnimItem] {
        guard case .bits(let fields, let width) = e.kind, let b = state.bits[e.name] else { return [] }
        let g = bitsGeometry(e, width: rect.width)
        let bw = g.bw, rh = Self.bitsRow
        let x0 = rect.minX + g.leftW, y0 = rect.minY + Self.bitsRuler
        var items: [AnimItem] = []
        // 位号：0、末位、每 8 位（宽的时候每 4 位、每位）
        for k in 0..<width {
            let show = k == 0 || k == width - 1 || bw >= 20 || (bw >= 12 && k % 4 == 0) || (bw * 8 >= 30 ? k % 8 == 0 : k % 16 == 0)
            guard show, k == width - 1 || k == 0 || CGFloat(width - 1 - k) * bw >= 16 else { continue }
            items.append(AnimItem(id: "\(id).bit\(k)", shape: .text("\(k)", frame: CGRect(x: x0 + CGFloat(k) * bw - 8, y: rect.minY, width: bw + 16, height: 12),
                                                                     size: AnimMetrics.small - 1, bold: false, role: .secondary, align: .center, backdrop: false)))
        }
        if g.leftW > 0 {
            for row in 0..<g.rows {
                items.append(AnimItem(id: "\(id).off\(row)", shape: .text("\(row * width / 8)", frame: CGRect(x: rect.minX, y: y0 + CGFloat(row) * rh, width: g.leftW - 5, height: rh),
                                                                           size: AnimMetrics.small - 1, bold: false, role: .secondary, align: .right, backdrop: false)))
            }
        }
        var valued = Set<Int>()
        for st in run.states.flatMap({ $0 }) {
            if let v = st.bits[e.name]?.values { for (i, x) in v.enumerated() where !x.isEmpty { valued.insert(i) } }
        }
        var offset = 0
        for (i, f) in fields.enumerated() {
            let boxes = Self.bitFieldBoxes(offset: offset, bits: f.bits, width: width)
            offset += f.bits
            let t = b.tones[i] == .normal ? tone : b.tones[i]
            var main = CGRect.zero
            for (k, box) in boxes.enumerated() {
                let r = CGRect(x: x0 + CGFloat(box.col) * bw, y: y0 + CGFloat(box.row) * rh, width: CGFloat(box.cols) * bw, height: CGFloat(box.rows) * rh)
                if r.width * r.height > main.width * main.height { main = r }
                items.append(AnimItem(id: "\(id).f\(i).\(k)", shape: .box(r, radius: 0, fill: .fill(t), stroke: t == .normal ? .grid : .stroke(t),
                                                                          lineWidth: t == .normal ? 1 : 1.5, dashed: f.variable)))
            }
            let inner = main.width - 4
            let value = b.values[i]
            // 哪一步有值，就从第 0 步起按「名字在上、值在下」排：名字不跟着跳（否则补间时名字会闪一下）
            // 太窄（名字用最小字号也放不下）：有值时只显示值，没值时照旧竖排名字
            let narrow = AnimMetrics.measure(f.name, size: 8).width > inner
            let twoLine = valued.contains(i) && !narrow
            if narrow && !value.isEmpty {
                let size = Self.fitSize(value, width: inner, sizes: [AnimMetrics.body, AnimMetrics.small, 9, 8], bold: true)
                items.append(AnimItem(id: "\(id).fv\(i)", shape: .text(value, frame: main.insetBy(dx: 2, dy: 0), size: size, bold: true,
                                                                      role: .text(t), align: .center, backdrop: false)))
            } else if !twoLine {
                let (text, size) = Self.fieldName(f.name, width: inner, height: main.height, sizes: [AnimMetrics.body, AnimMetrics.small, 9, 8])
                items.append(AnimItem(id: "\(id).fn\(i)", shape: .text(text, frame: main.insetBy(dx: 2, dy: 0), size: size, bold: false,
                                                                      role: .text(t), align: .center, backdrop: false)))
            } else if value.isEmpty {
                let nameSize = Self.fitSize(f.name, width: inner, sizes: [AnimMetrics.small, 9, 8])
                items.append(AnimItem(id: "\(id).fn\(i)", shape: .text(f.name, frame: CGRect(x: main.minX + 2, y: main.midY - 15, width: inner, height: 14),
                                                                      size: nameSize, bold: false, role: .text(t), align: .center, backdrop: false)))
            } else {
                let nameSize = Self.fitSize(f.name, width: inner, sizes: [AnimMetrics.small, 9, 8])
                let valueSize = Self.fitSize(value, width: inner, sizes: [AnimMetrics.body, AnimMetrics.small, 9, 8], bold: true)
                items.append(AnimItem(id: "\(id).fn\(i)", shape: .text(f.name, frame: CGRect(x: main.minX + 2, y: main.midY - 15, width: inner, height: 14),
                                                                      size: nameSize, bold: false, role: .text(t), align: .center, backdrop: false)))
                items.append(AnimItem(id: "\(id).fv\(i)", shape: .text(value, frame: CGRect(x: main.minX + 2, y: main.midY - 1, width: inner, height: 15),
                                                                      size: valueSize, bold: true, role: .text(t), align: .center, backdrop: false)))
            }
        }
        let right = x0 + CGFloat(width) * bw + 8
        for (row, text) in b.labels where row < g.rows {
            items.append(AnimItem(id: "\(id).l\(row)", shape: .text(text, frame: CGRect(x: right, y: y0 + CGFloat(row) * rh, width: max(rect.maxX - right, 10), height: rh),
                                                                     size: AnimMetrics.small, bold: false, role: .secondary, align: .left, backdrop: false)))
        }
        return items
    }

    // MARK: - 分组（封装）图

    static let packetBar: CGFloat = 30
    static let packetLen: CGFloat = 14
    static let packetGroup: CGFloat = 22

    /// 括号排第几层（1 起，贴着长度那一行的是 1）：从短的排起，与已排的有重叠就往下一层。
    static func packetGroupLevels(_ p: AnimPacketState) -> [Int: Int] {
        var spans: [(id: Int, lo: Int, hi: Int)] = []
        for g in p.groups {
            guard let a = p.index(of: g.from), let b = p.index(of: g.to) else { continue }
            spans.append((g.id, min(a, b), max(a, b)))
        }
        spans.sort { ($0.hi - $0.lo, $0.id) < ($1.hi - $1.lo, $1.id) }
        var level: [Int: Int] = [:]
        for (k, s) in spans.enumerated() {
            var l = 1
            for o in spans[..<k] where o.lo <= s.hi && o.hi >= s.lo { l = max(l, level[o.id]! + 1) }
            level[s.id] = l
        }
        return level
    }

    /// 长度开头的数字（`1480`、`20 B` → 20）；没有数字 = 0。
    static func leadingNumber(_ s: String) -> Double {
        Double(String(s.trimmingCharacters(in: .whitespaces).prefix { $0.isNumber || $0 == "." })) ?? 0
    }

    /// 各段的宽：每段先给够名字的宽，余下的按长度的平方根分（20 字节的首部和 1000 字节的数据都看得见）。
    /// 比例尺按这个元素所有步里最长的那一帧定：封装时一条越加越长，而不是同一条宽度里越挤越窄。
    func packetWidths(_ name: String, segments: [AnimSegment], width w: CGFloat) -> [CGFloat] {
        func mins(_ segs: [AnimSegment]) -> [CGFloat] { segs.map { max(AnimMetrics.measure($0.name, size: AnimMetrics.small).width + 10, 28) } }
        func weight(_ seg: AnimSegment) -> CGFloat { CGFloat(Self.leadingNumber(seg.length).squareRoot()) }
        let all = run.states.flatMap { $0 }.compactMap { $0.packets[name]?.segments }
        var scale = CGFloat.greatestFiniteMagnitude
        for segs in all where !segs.isEmpty {
            let free = w - mins(segs).reduce(0, +)
            let total = segs.map(weight).reduce(0, +)
            if total > 0 { scale = min(scale, max(free, 0) / total) }
        }
        let m = mins(segments)
        let sumMin = m.reduce(0, +)
        if sumMin >= w { return m.map { $0 * w / sumMin } }
        if scale == .greatestFiniteMagnitude {
            // 都没写长度：平分
            let extra = (w - sumMin) / CGFloat(max(segments.count, 1))
            return m.map { $0 + extra }
        }
        return zip(m, segments).map { $0 + scale * weight($1) }
    }

    func packetItems(_ id: String, element e: AnimElement, rect: CGRect, state: AnimSceneState, tone: AnimTone) -> [AnimItem] {
        guard case .packet(_, let unit) = e.kind, let p = state.packets[e.name] else { return [] }
        var items: [AnimItem] = []
        let widths = packetWidths(e.name, segments: p.segments, width: rect.width)
        var frames: [Int: CGRect] = [:]
        var x = rect.minX
        let barTop = rect.minY
        for (k, seg) in p.segments.enumerated() {
            let r = CGRect(x: x, y: barTop, width: widths[k], height: Self.packetBar)
            frames[seg.id] = r
            x += widths[k]
            let t = seg.tone == .normal ? tone : seg.tone
            items.append(AnimItem(id: "\(id).s\(seg.id)", shape: .box(r, radius: 2, fill: .fill(t), stroke: t == .normal ? .grid : .stroke(t), lineWidth: t == .normal ? 1 : 1.5, dashed: false)))
            let size = Self.fitSize(seg.name, width: r.width - 4, sizes: [AnimMetrics.body, AnimMetrics.small, 9, 8])
            items.append(AnimItem(id: "\(id).sn\(seg.id)", shape: .text(seg.name, frame: r.insetBy(dx: 2, dy: 0), size: size, bold: false,
                                                                         role: .text(t), align: .center, backdrop: false)))
            if !seg.length.isEmpty {
                let text = unit.isEmpty ? seg.length : seg.length + " " + unit
                items.append(AnimItem(id: "\(id).sl\(seg.id)", shape: .text(text, frame: CGRect(x: r.minX - 6, y: r.maxY + 1, width: r.width + 12, height: Self.packetLen - 1),
                                                                             size: AnimMetrics.small - 1, bold: false, role: .secondary, align: .center, backdrop: false)))
            }
        }
        if p.segments.isEmpty {
            items.append(AnimItem(id: "\(id).empty", shape: .box(CGRect(x: rect.minX, y: barTop, width: 60, height: Self.packetBar), radius: 2,
                                                                 fill: nil, stroke: .grid, lineWidth: 1, dashed: true)))
        }
        let levels = Self.packetGroupLevels(p)
        for g in p.groups {
            guard let level = levels[g.id], let a = frames[g.from], let b = frames[g.to] else { continue }
            let x0 = min(a.minX, b.minX) + 2, x1 = max(a.maxX, b.maxX) - 2
            let y = barTop + Self.packetBar + Self.packetLen + CGFloat(level - 1) * Self.packetGroup + 2
            items.append(AnimItem(id: "\(id).g\(g.id)", shape: .line([CGPoint(x: x0, y: y), CGPoint(x: x0, y: y + 5), CGPoint(x: x1, y: y + 5), CGPoint(x: x1, y: y)],
                                                                      role: .secondary, width: 1, dashed: false, arrow: false, progress: 1)))
            let size = AnimMetrics.measure(g.label, size: AnimMetrics.small)
            let lw = min(size.width + 8, rect.width)
            // 标签可以比括号宽，但不出元素的左右边
            let lx = min(max((x0 + x1) / 2 - lw / 2, rect.minX), rect.maxX - lw)
            items.append(AnimItem(id: "\(id).gl\(g.id)", shape: .text(g.label, frame: CGRect(x: lx, y: y + 5, width: lw, height: 14),
                                                                       size: AnimMetrics.small, bold: false, role: .ink, align: .center, backdrop: true)))
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
