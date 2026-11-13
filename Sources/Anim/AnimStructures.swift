import Foundation

// A2 的几种结构（`ANIM-BLOCK-PLAN.md §3.2`）：链表、树、图、指针、二维表的状态与动作。只依赖 Foundation。
// 节点都有稳定 id：改指向、插入、旋转时画面按 id 配对，节点滑到新位置。

struct AnimListNode: Equatable {
    let id: Int
    var value: String
    var tone: AnimTone
    /// 指向哪个节点（id）；nil = 空。
    var next: Int?
}

struct AnimListState: Equatable {
    /// 画的顺序（从左到右）。指向关系另记在 `next`，可以和顺序不一致（反转链表时就是）。
    var nodes: [AnimListNode]

    func index(of id: Int) -> Int? { nodes.firstIndex { $0.id == id } }
}

struct AnimTreeNode: Equatable {
    let id: Int
    var value: String
    /// 值的身份：`swap` 交换值时它跟着值走，画面上是两个值互相飞过去。
    var valueID: Int
    var tone: AnimTone
    /// 孩子槽位：二叉树里 0 = 左、1 = 右；nil = 空位。
    var children: [Int?]
}

struct AnimTreeState: Equatable {
    var nodes: [Int: AnimTreeNode] = [:]
    var root: Int?

    /// 按值找节点（先序第一个）。
    func find(_ value: String) -> Int? {
        func walk(_ id: Int?) -> Int? {
            guard let id, let n = nodes[id] else { return nil }
            if n.value == value { return id }
            for c in n.children { if let hit = walk(c) { return hit } }
            return nil
        }
        return walk(root)
    }

    func parent(of id: Int) -> (parent: Int, slot: Int)? {
        for (pid, n) in nodes {
            if let slot = n.children.firstIndex(where: { $0 == id }) { return (pid, slot) }
        }
        return nil
    }

    func subtree(_ id: Int) -> [Int] {
        guard let n = nodes[id] else { return [] }
        return [id] + n.children.compactMap { $0 }.flatMap(subtree)
    }

    var depth: Int {
        func d(_ id: Int?) -> Int {
            guard let id, let n = nodes[id] else { return 0 }
            return 1 + (n.children.map(d).max() ?? 0)
        }
        return d(root)
    }

    mutating func setChild(_ parent: Int, slot: Int, _ child: Int?) {
        guard var p = nodes[parent] else { return }
        while p.children.count <= slot { p.children.append(nil) }
        p.children[slot] = child
        while p.children.last == .some(nil) { p.children.removeLast() }
        nodes[parent] = p
    }

    func child(_ id: Int, _ slot: Int) -> Int? {
        guard let n = nodes[id], slot < n.children.count else { return nil }
        return n.children[slot]
    }
}

struct AnimGraphNode: Equatable {
    var tone: AnimTone = .normal
    /// 节点下方的小字（`set G[A] = "d=3"`）。
    var label = ""
}

struct AnimGraphEdge: Equatable {
    let a: String
    let b: String
    let directed: Bool
    var weight: String?
    var tone: AnimTone = .normal

    func matches(_ key: String) -> Bool {
        if key.contains("->") {
            let p = key.components(separatedBy: "->").map { $0.trimmingCharacters(in: .whitespaces) }
            return p.count == 2 && p[0] == a && p[1] == b
        }
        let p = key.components(separatedBy: "-").map { $0.trimmingCharacters(in: .whitespaces) }
        guard p.count == 2 else { return false }
        return (p[0] == a && p[1] == b) || (!directed && p[0] == b && p[1] == a) || (directed && p[0] == a && p[1] == b)
            || (p[0] == b && p[1] == a)
    }
}

struct AnimGraphState: Equatable {
    var order: [String]
    var nodes: [String: AnimGraphNode]
    var edges: [AnimGraphEdge]
}

struct AnimGridState: Equatable {
    var values: [[String]]
    var tones: [[AnimTone]]
    let rowLabels: [String]
    let colLabels: [String]

    var rows: Int { values.count }
    var cols: Int { values.first?.count ?? 0 }
}

/// 竖式（草算纸）：按（行, 列）放单个字符，加横线、往下落的箭头、行尾注释。
struct AnimSheetCell: Equatable {
    var char: String
    var tone: AnimTone = .normal
}

struct AnimSheetRule: Equatable {
    let row: Int
    let from: Int
    let to: Int
    let above: Bool
}

struct AnimSheetArrow: Equatable {
    let col: Int
    let fromRow: Int
    let toRow: Int
}

struct AnimSheetState: Equatable {
    var cells: [Int: [Int: AnimSheetCell]] = [:]     // 行 → 列 → 字
    var rules: [AnimSheetRule] = []
    var arrows: [AnimSheetArrow] = []
    var labels: [Int: String] = [:]

    /// 用到的行数 / 列数（含横线、箭头、注释占的行）。
    var rowCount: Int {
        max((cells.keys.max() ?? -1), (rules.map(\.row).max() ?? -1), (arrows.map(\.toRow).max() ?? -1), (labels.keys.max() ?? -1)) + 1
    }
    var colCount: Int {
        max((cells.values.compactMap { $0.keys.max() }.max() ?? -1), (rules.map(\.to).max() ?? -1), (arrows.map(\.col).max() ?? -1)) + 1
    }
}

/// 指针指着什么。
enum AnimPointerTarget: Equatable {
    case index(element: String, Int)          // 数组 / 栈 / 队列的下标
    case node(element: String, id: Int)       // 链表 / 树的节点
    case graphNode(element: String, String)
    case grid(element: String, row: Int, col: Int)

    var element: String {
        switch self {
        case .index(let e, _), .node(let e, _), .graphNode(let e, _), .grid(let e, _, _): return e
        }
    }
}

extension AnimEngine {

    static func initialStructure(_ element: AnimElement, into state: inout AnimSceneState, newID: () -> Int) {
        switch element.kind {
        case .list(let values):
            var nodes = values.map { AnimListNode(id: newID(), value: $0, tone: .normal, next: nil) }
            for i in nodes.indices.dropLast() { nodes[i].next = nodes[i + 1].id }
            state.lists[element.name] = AnimListState(nodes: nodes)
        case .tree(let decl):
            var tree = AnimTreeState()
            func build(_ d: AnimTreeDecl?) -> Int? {
                guard case .node(let value, let children)? = d else { return nil }
                let id = newID()
                let kids = children.map(build)
                tree.nodes[id] = AnimTreeNode(id: id, value: value, valueID: newID(), tone: .normal, children: kids)
                return id
            }
            tree.root = build(decl)
            state.trees[element.name] = tree
        case .graph(let nodes, let edges, _):
            state.graphs[element.name] = AnimGraphState(order: nodes, nodes: Dictionary(uniqueKeysWithValues: nodes.map { ($0, AnimGraphNode()) }),
                                                        edges: edges.map { AnimGraphEdge(a: $0.a, b: $0.b, directed: $0.directed, weight: $0.weight) })
        case .grid(let values, let rows, let cols):
            state.grids[element.name] = AnimGridState(values: values, tones: values.map { $0.map { _ in .normal } }, rowLabels: rows, colLabels: cols)
        case .sheet:
            state.sheets[element.name] = AnimSheetState()
        default:
            break
        }
    }

    /// 声明里的指针目标：在初始状态上解析（目标元素要先声明）。
    static func initialPointer(_ element: AnimElement, into state: inout AnimSceneState, kinds: [String: AnimElementKind], errors: inout [AnimDiagnostic]) {
        guard case .pointer(let target) = element.kind else { return }
        state.pointers[element.name] = .some(nil)
        guard let target else { return }
        do {
            state.pointers[element.name] = try resolvePointer(target, state, kinds: kinds)
        } catch let e as AnimParseError {
            errors.append(AnimDiagnostic(line: element.line, message: e.message))
        } catch {}
    }

    static func resolvePointer(_ t: AnimTarget, _ state: AnimSceneState, kinds: [String: AnimElementKind]) throws -> AnimPointerTarget {
        guard let kind = kinds[t.name] else { throw AnimParseError("no element “\(t.name)” to point at") }
        guard let key = t.key else { throw AnimParseError("point at one cell or node, like \(t.name)[0]") }
        switch kind {
        case .array, .stack, .queue:
            guard let i = t.lower, t.lower == t.upper else { throw AnimParseError("point at one index, like \(t.name)[2]") }
            let count = state.cells[t.name]?.count ?? 0
            guard i >= 0, i <= count else { throw AnimParseError("\(t.name) has \(count) item(s): index \(i) is out of range") }
            return .index(element: t.name, i)
        case .list:
            guard let i = t.lower, t.lower == t.upper, let list = state.lists[t.name] else { throw AnimParseError("point at one node, like \(t.name)[0]") }
            guard i >= 0, i < list.nodes.count else { throw AnimParseError("\(t.name) has \(list.nodes.count) node(s): \(i) is out of range") }
            return .node(element: t.name, id: list.nodes[i].id)
        case .tree:
            guard let id = state.trees[t.name]?.find(key) else { throw AnimParseError("\(t.name) has no node \(key)") }
            return .node(element: t.name, id: id)
        case .graph:
            guard state.graphs[t.name]?.nodes[key] != nil else { throw AnimParseError("\(t.name) has no node \(key)") }
            return .graphNode(element: t.name, key)
        case .grid:
            guard let r = t.gridRange, r.rows.count == 1, r.cols.count == 1, let g = state.grids[t.name] else { throw AnimParseError("point at one cell, like \(t.name)[1,2]") }
            guard r.rows.lowerBound >= 0, r.rows.lowerBound < g.rows, r.cols.lowerBound >= 0, r.cols.lowerBound < g.cols else { throw AnimParseError("\(t.name) is \(g.rows)x\(g.cols): cell out of range") }
            return .grid(element: t.name, row: r.rows.lowerBound, col: r.cols.lowerBound)
        default:
            throw AnimParseError("a pointer can point at an array, stack, queue, list, tree, graph or grid")
        }
    }

    /// 这几种结构上的动作。返回 false = 不归这里管（交给通用的处理）。
    static func applyStructure(_ action: AnimAction, _ state: inout AnimSceneState, kinds: [String: AnimElementKind],
                               newID: () -> Int, fail: (String) -> Void) -> Bool {
        func kind(_ name: String) -> AnimElementKind? { kinds[name] }
        func isStructure(_ name: String) -> Bool {
            switch kinds[name] {
            case .list?, .tree?, .graph?, .grid?, .pointer?, .sheet?: return true
            default: return false
            }
        }
        do {
            switch action {
            case .mark(let t, let tone):
                guard isStructure(t.name) else { return false }
                try paint(t, &state, kinds: kinds) { _ in tone }
            case .unmark(let t):
                guard isStructure(t.name) else { return false }
                try paint(t, &state, kinds: kinds) { _ in .normal }
            case .set(let t, let value):
                guard isStructure(t.name) else { return false }
                try setValue(t, value, &state, kinds: kinds)
            case .swap(let a, let b):
                guard isStructure(a.name) else { return false }
                try swapValues(a, b, &state, kinds: kinds)
            case .insertAt(let name, let index, let value):
                guard case .list? = kind(name), var list = state.lists[name] else { throw AnimParseError("insert NAME INDEX VALUE is for lists; “\(name)” is not a list") }
                guard index >= 0, index <= list.nodes.count else { throw AnimParseError("\(name) has \(list.nodes.count) node(s): insert index \(index) is out of range (0…\(list.nodes.count))") }
                guard list.nodes.count < 16 else { throw AnimParseError("list: at most 16 nodes") }
                let id = newID()
                var node = AnimListNode(id: id, value: value, tone: .new, next: index < list.nodes.count ? list.nodes[index].id : nil)
                if index > 0 {
                    node.next = list.nodes[index - 1].next
                    list.nodes[index - 1].next = id
                }
                list.nodes.insert(node, at: index)
                state.lists[name] = list
            case .insertTree(let name, let value, let parentKey, let side):
                guard case .tree? = kind(name), var tree = state.trees[name] else { throw AnimParseError("“\(name)” is not a tree") }
                guard tree.nodes.count < 40 else { throw AnimParseError("tree: at most 40 nodes") }
                let id = newID()
                let node = AnimTreeNode(id: id, value: value, valueID: newID(), tone: .new, children: [])
                if let parentKey {
                    guard let p = tree.find(parentKey) else { throw AnimParseError("\(name) has no node \(parentKey)") }
                    let slot: Int
                    if let side {
                        slot = side == .left ? 0 : 1
                        guard tree.child(p, slot) == nil else { throw AnimParseError("\(parentKey) already has a \(side.rawValue) child") }
                    } else {
                        slot = tree.nodes[p]!.children.count
                    }
                    tree.nodes[id] = node
                    tree.setChild(p, slot: slot, id)
                } else {
                    guard tree.root == nil else { throw AnimParseError("\(name) already has a root: use insert \(name) \(value) under PARENT [left|right]") }
                    tree.nodes[id] = node
                    tree.root = id
                }
                state.trees[name] = tree
            case .remove(let name, let key):
                switch kind(name) {
                case .list?:
                    guard var list = state.lists[name], let i = Int(key) else { throw AnimParseError("remove LIST INDEX: the index is a number") }
                    guard i >= 0, i < list.nodes.count else { throw AnimParseError("\(name) has \(list.nodes.count) node(s): \(i) is out of range") }
                    let gone = list.nodes.remove(at: i)
                    for j in list.nodes.indices where list.nodes[j].next == gone.id { list.nodes[j].next = gone.next }
                    state.lists[name] = list
                    dropPointers(to: [gone.id], in: name, &state)
                case .tree?:
                    guard var tree = state.trees[name], let id = tree.find(key) else { throw AnimParseError("\(name) has no node \(key)") }
                    let gone = tree.subtree(id)
                    if let (p, slot) = tree.parent(of: id) { tree.setChild(p, slot: slot, nil) } else { tree.root = nil }
                    for g in gone { tree.nodes[g] = nil }
                    state.trees[name] = tree
                    dropPointers(to: gone, in: name, &state)
                default:
                    return false
                }
            case .link(let from, let to):
                guard case .list? = kind(from.name), var list = state.lists[from.name] else { throw AnimParseError("link is for lists; “\(from.name)” is not a list") }
                guard let i = from.lower, from.lower == from.upper, i >= 0, i < list.nodes.count else { throw AnimParseError("link: \(from.text) is not a node of \(from.name)") }
                if let to {
                    guard to.name == from.name else { throw AnimParseError("link within one list: \(from.name)[…] -> \(from.name)[…]") }
                    guard let j = to.lower, to.lower == to.upper, j >= 0, j < list.nodes.count else { throw AnimParseError("link: \(to.text) is not a node of \(to.name)") }
                    list.nodes[i].next = list.nodes[j].id
                } else {
                    list.nodes[i].next = nil
                }
                state.lists[from.name] = list
            case .rotate(let name, let key, let side):
                guard case .tree? = kind(name), var tree = state.trees[name] else { throw AnimParseError("“\(name)” is not a tree") }
                guard let x = tree.find(key) else { throw AnimParseError("\(name) has no node \(key)") }
                // 左旋：右孩子 y 上来，y 的左子树挂到 x 的右边；右旋对称
                let up = side == .left ? 1 : 0, across = 1 - up
                guard let y = tree.child(x, up) else { throw AnimParseError("rotate \(side.rawValue) at \(key) needs a \(up == 1 ? "right" : "left") child") }
                let parent = tree.parent(of: x)
                tree.setChild(x, slot: up, tree.child(y, across))
                tree.setChild(y, slot: across, x)
                if let (p, slot) = parent { tree.setChild(p, slot: slot, y) } else { tree.root = y }
                state.trees[name] = tree
            case .move(let name, let target):
                guard case .pointer? = kind(name) else { return false }
                state.pointers[name] = .some(try target.map { try resolvePointer($0, state, kinds: kinds) })
            case .write(let t, let text):
                var sheet = try sheetOf(t, state, kinds)
                guard let r = t.gridRange, r.rows.count == 1, r.cols.count == 1 else { throw AnimParseError("write starts at one cell, like \(t.name)[2,5]") }
                let (row, col) = (r.rows.lowerBound, r.cols.lowerBound)
                guard row >= 0, col >= 0, row < 40, col + text.count <= 60 else { throw AnimParseError("sheet: at most 40 rows and 60 columns") }
                for (k, ch) in text.enumerated() where ch != " " {
                    sheet.cells[row, default: [:]][col + k] = AnimSheetCell(char: String(ch), tone: sheet.cells[row]?[col + k]?.tone ?? .normal)
                }
                state.sheets[t.name] = sheet
            case .rule(let t, let above):
                var sheet = try sheetOf(t, state, kinds)
                guard let r = t.gridRange, r.rows.count == 1, r.cols.lowerBound >= 0, r.rows.lowerBound >= 0 else { throw AnimParseError("rule takes one row and a column range, like \(t.name)[2,5..8]") }
                sheet.rules.append(AnimSheetRule(row: r.rows.lowerBound, from: r.cols.lowerBound, to: r.cols.upperBound, above: above))
                state.sheets[t.name] = sheet
            case .arrow(let t):
                var sheet = try sheetOf(t, state, kinds)
                guard let r = t.gridRange, r.cols.count == 1, r.rows.count >= 2, r.rows.lowerBound >= 0 else { throw AnimParseError("arrow takes a row range and one column, like \(t.name)[1..3,9]") }
                sheet.arrows.append(AnimSheetArrow(col: r.cols.lowerBound, fromRow: r.rows.lowerBound, toRow: r.rows.upperBound))
                state.sheets[t.name] = sheet
            case .label(let t, let text):
                var sheet = try sheetOf(t, state, kinds)
                guard let row = t.lower, t.lower == t.upper, row >= 0, row < 40 else { throw AnimParseError("label takes one row, like \(t.name)[3]") }
                sheet.labels[row] = text
                state.sheets[t.name] = sheet
            default:
                return false
            }
        } catch let e as AnimParseError {
            fail(e.message)
        } catch {}
        return true
    }

    private static func sheetOf(_ t: AnimTarget, _ state: AnimSceneState, _ kinds: [String: AnimElementKind]) throws -> AnimSheetState {
        guard case .sheet? = kinds[t.name], let sheet = state.sheets[t.name] else { throw AnimParseError("“\(t.name)” is not a sheet (declare: sheet \(t.name))") }
        return sheet
    }

    private static func dropPointers(to ids: [Int], in element: String, _ state: inout AnimSceneState) {
        for (name, target) in state.pointers {
            if case .node(let e, let id)? = target, e == element, ids.contains(id) { state.pointers[name] = .some(nil) }
        }
    }

    private static func paint(_ t: AnimTarget, _ state: inout AnimSceneState, kinds: [String: AnimElementKind], tone: (AnimTone) -> AnimTone) throws {
        guard let key = t.key else {
            state.elementTones[t.name] = tone(state.elementTones[t.name] ?? .normal)
            return
        }
        switch kinds[t.name] {
        case .list?:
            guard var list = state.lists[t.name], let lo = t.lower, let hi = t.upper else { throw AnimParseError("\(t.text): list nodes are numbered, like \(t.name)[0] or \(t.name)[1..2]") }
            guard lo >= 0, hi < list.nodes.count else { throw AnimParseError("\(t.name) has \(list.nodes.count) node(s): \(t.text) is out of range") }
            for i in lo...hi { list.nodes[i].tone = tone(list.nodes[i].tone) }
            state.lists[t.name] = list
        case .tree?:
            guard var tree = state.trees[t.name], let id = tree.find(key) else { throw AnimParseError("\(t.name) has no node \(key)") }
            tree.nodes[id]!.tone = tone(tree.nodes[id]!.tone)
            state.trees[t.name] = tree
        case .graph?:
            guard var g = state.graphs[t.name] else { return }
            if g.nodes[key] != nil {
                g.nodes[key]!.tone = tone(g.nodes[key]!.tone)
            } else if let i = g.edges.firstIndex(where: { $0.matches(key) }) {
                g.edges[i].tone = tone(g.edges[i].tone)
            } else {
                throw AnimParseError("\(t.name) has no node or edge \(key)")
            }
            state.graphs[t.name] = g
        case .sheet?:
            guard var sh = state.sheets[t.name], let r = t.gridRange else { throw AnimParseError("sheet cells look like \(t.name)[1,2] or \(t.name)[3,5..8]") }
            for i in r.rows { for j in r.cols where sh.cells[i]?[j] != nil { sh.cells[i]![j]!.tone = tone(sh.cells[i]![j]!.tone) } }
            state.sheets[t.name] = sh
        case .grid?:
            guard var g = state.grids[t.name], let r = t.gridRange else { throw AnimParseError("grid cells look like \(t.name)[1,2] or \(t.name)[0..2,1]") }
            guard r.rows.lowerBound >= 0, r.rows.upperBound < g.rows, r.cols.lowerBound >= 0, r.cols.upperBound < g.cols else {
                throw AnimParseError("\(t.name) is \(g.rows)x\(g.cols): \(t.text) is out of range")
            }
            for i in r.rows { for j in r.cols { g.tones[i][j] = tone(g.tones[i][j]) } }
            state.grids[t.name] = g
        default:
            throw AnimParseError("\(t.name) cannot be marked with an index")
        }
    }

    private static func setValue(_ t: AnimTarget, _ value: String, _ state: inout AnimSceneState, kinds: [String: AnimElementKind]) throws {
        guard let key = t.key else { throw AnimParseError("set needs a cell or node, like \(t.name)[0]") }
        switch kinds[t.name] {
        case .list?:
            guard var list = state.lists[t.name], let lo = t.lower, let hi = t.upper, lo >= 0, hi < list.nodes.count else { throw AnimParseError("\(t.text) is not a node of \(t.name)") }
            for i in lo...hi { list.nodes[i].value = value }
            state.lists[t.name] = list
        case .tree?:
            guard var tree = state.trees[t.name], let id = tree.find(key) else { throw AnimParseError("\(t.name) has no node \(key)") }
            tree.nodes[id]!.value = value
            state.trees[t.name] = tree
        case .graph?:
            guard var g = state.graphs[t.name] else { return }
            if g.nodes[key] != nil {
                g.nodes[key]!.label = value
            } else if let i = g.edges.firstIndex(where: { $0.matches(key) }) {
                g.edges[i].weight = value
            } else {
                throw AnimParseError("\(t.name) has no node or edge \(key)")
            }
            state.graphs[t.name] = g
        case .grid?:
            guard var g = state.grids[t.name], let r = t.gridRange,
                  r.rows.lowerBound >= 0, r.rows.upperBound < g.rows, r.cols.lowerBound >= 0, r.cols.upperBound < g.cols else {
                throw AnimParseError("\(t.text) is not a cell of \(t.name)")
            }
            for i in r.rows { for j in r.cols { g.values[i][j] = value } }
            state.grids[t.name] = g
        case .sheet?:
            guard var sh = state.sheets[t.name], let r = t.gridRange, r.rows.lowerBound >= 0, r.cols.lowerBound >= 0 else { throw AnimParseError("sheet cells look like \(t.name)[1,2]") }
            for (k, ch) in value.enumerated() where ch != " " {
                sh.cells[r.rows.lowerBound, default: [:]][r.cols.lowerBound + k] = AnimSheetCell(char: String(ch))
            }
            state.sheets[t.name] = sh
        default:
            throw AnimParseError("set: \(t.name) has no values")
        }
    }

    private static func swapValues(_ a: AnimTarget, _ b: AnimTarget, _ state: inout AnimSceneState, kinds: [String: AnimElementKind]) throws {
        switch kinds[a.name] {
        case .tree?:
            guard var tree = state.trees[a.name], let x = tree.find(a.key ?? ""), let y = tree.find(b.key ?? "") else {
                throw AnimParseError("\(a.name) has no node \(tree(a, b, state))")
            }
            let (v, vid) = (tree.nodes[x]!.value, tree.nodes[x]!.valueID)
            tree.nodes[x]!.value = tree.nodes[y]!.value
            tree.nodes[x]!.valueID = tree.nodes[y]!.valueID
            tree.nodes[y]!.value = v
            tree.nodes[y]!.valueID = vid
            state.trees[a.name] = tree
        case .list?:
            guard var list = state.lists[a.name], let i = a.lower, let j = b.lower, i >= 0, j >= 0, i < list.nodes.count, j < list.nodes.count else {
                throw AnimParseError("swap: index out of range")
            }
            let v = list.nodes[i].value
            list.nodes[i].value = list.nodes[j].value
            list.nodes[j].value = v
            state.lists[a.name] = list
        default:
            throw AnimParseError("swap works on arrays and trees (and list values)")
        }
    }

    private static func tree(_ a: AnimTarget, _ b: AnimTarget, _ state: AnimSceneState) -> String {
        let t = state.trees[a.name]
        return t?.find(a.key ?? "") == nil ? (a.key ?? "") : (b.key ?? "")
    }
}
