import CoreGraphics
import CoreText
import Foundation

// 分步演示的布局：状态 + 画布宽 → 一帧里要画的物件（框、字、线、叉）。坐标是**翻转**的（原点左上、y 向下），单位点。
// 每个物件有稳定的 id：两步之间按 id 配对插值（`AnimPainter`）。高度与步无关（按所有步里最大的量），播放时块不变高。
// 只依赖 CoreGraphics / CoreText：spike 能直接编。

/// 颜色角色：画的时候按深浅色映射到系统动态色。
enum AnimRole: Equatable {
    case ink, secondary, grid, background
    case fill(AnimTone)
    case stroke(AnimTone)
    case text(AnimTone)
}

enum AnimAlign { case left, center, right }

enum AnimShape: Equatable {
    case box(CGRect, radius: CGFloat, fill: AnimRole?, stroke: AnimRole?, lineWidth: CGFloat, dashed: Bool)
    case text(String, frame: CGRect, size: CGFloat, bold: Bool, role: AnimRole, align: AnimAlign, backdrop: Bool)
    /// 折线；`progress` 0…1 = 画到全长的几成（消息在飞）；`arrow` 在画到的末端加箭头。
    case line([CGPoint], role: AnimRole, width: CGFloat, dashed: Bool, arrow: Bool, progress: CGFloat)
    case cross(CGPoint, size: CGFloat, role: AnimRole)
}

struct AnimItem: Equatable {
    let id: String
    var shape: AnimShape
    var alpha: CGFloat = 1
    /// 连着两个节点的边（树）：补间时端点按两个节点「此刻」的位置现算，边始终连在节点上（`AnimPainter`）。
    var link: AnimLink? = nil
}

/// 边的两端：两个圆形节点框的 id（端点在圆周上）。
struct AnimLink: Equatable {
    let from: String
    let to: String
}

struct AnimFrame {
    let size: CGSize
    let items: [AnimItem]
}

enum AnimMetrics {
    static let pad: CGFloat = 12
    static let body: CGFloat = 12
    static let small: CGFloat = 10
    static let titleSize: CGFloat = 13
    static let unit: CGFloat = 10          // 时序图：每个时间单位多少点
    static let sceneGap: CGFloat = 16
    static let rowGap: CGFloat = 12
    static let minSceneWidth: CGFloat = 300

    static func font(_ size: CGFloat, bold: Bool) -> CTFont {
        CTFontCreateUIFontForLanguage(bold ? .emphasizedSystem : .system, size, nil)
            ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
    }

    /// 文字在 `maxWidth` 内折行后的大小。
    static func measure(_ text: String, size: CGFloat, bold: Bool = false, maxWidth: CGFloat = .greatestFiniteMagnitude) -> CGSize {
        guard !text.isEmpty else { return .zero }
        let attr = NSAttributedString(string: text, attributes: [kCTFontAttributeName as NSAttributedString.Key: font(size, bold: bold)])
        let setter = CTFramesetterCreateWithAttributedString(attr)
        let fit = CTFramesetterSuggestFrameSizeWithConstraints(setter, CFRange(location: 0, length: 0), nil,
                                                                CGSize(width: maxWidth, height: .greatestFiniteMagnitude), nil)
        return CGSize(width: ceil(fit.width) + 1, height: ceil(fit.height))
    }
}

struct AnimLayout {
    let run: AnimRun
    let width: CGFloat
    private(set) var height: CGFloat = 0

    private struct SceneBox {
        var origin: CGPoint
        var width: CGFloat
        var titleHeight: CGFloat = 0
        var elements: [String: CGRect] = [:]
        var saysTop: CGFloat = 0
        var saysHeight: CGFloat = 0
        var captionTop: CGFloat = 0
        var captionHeight: CGFloat = 0
        var height: CGFloat = 0
        /// 时序图：竖线 x、时间轴起点 y、挂在竖线上的序号条的位置。
        var laneX: [String: CGFloat] = [:]
        var timelineTop: CGFloat = 0
        var attachedSeqs: [String: CGRect] = [:]
    }

    private var scenes: [SceneBox] = []
    private var titleHeight: CGFloat = 0
    /// 并排时：各场景时序图里挂在一条竖线上最多几条序号条，都按它留高度，各场景的时间轴从同一高度开始（上下排时不需要）。
    private var seqRowsAcrossScenes = 0

    init(run: AnimRun, width: CGFloat) {
        self.run = run
        self.width = width
        compute()
    }

    // MARK: - 几何（与步无关）

    private mutating func compute() {
        let pad = AnimMetrics.pad
        let sceneCount = run.script.scenes.count
        let willSideBySide = sceneCount >= 2
            && (width - 2 * pad - CGFloat(sceneCount - 1) * AnimMetrics.sceneGap) / CGFloat(sceneCount) >= AnimMetrics.minSceneWidth
        for scene in run.script.scenes where willSideBySide {
            var perLane: [String: Int] = [:]
            for el in scene.elements {
                if case .seq(_, _, _, _, let lane?) = el.kind { perLane[lane, default: 0] += 1 }
            }
            seqRowsAcrossScenes = max(seqRowsAcrossScenes, perLane.values.max() ?? 0)
        }
        var y = pad
        if let title = run.script.title, !title.isEmpty {
            titleHeight = AnimMetrics.measure(title, size: AnimMetrics.titleSize, bold: true, maxWidth: width - 2 * pad).height
            y += titleHeight + 8
        }
        let count = run.script.scenes.count
        let inner = width - 2 * pad
        let sideBySide = count >= 2 && (inner - CGFloat(count - 1) * AnimMetrics.sceneGap) / CGFloat(count) >= AnimMetrics.minSceneWidth
        let sceneWidth = sideBySide ? floor((inner - CGFloat(count - 1) * AnimMetrics.sceneGap) / CGFloat(count)) : inner

        for i in 0..<count {
            let x = sideBySide ? pad + CGFloat(i) * (sceneWidth + AnimMetrics.sceneGap) : pad
            let box = measureScene(i, origin: CGPoint(x: x, y: y), width: sceneWidth, index: i)
            if !sideBySide { y += box.height + AnimMetrics.sceneGap }
            scenes.append(box)
        }
        if sideBySide {
            // 并排时各场景的提示、说明对齐到同一高度
            let saysTop = scenes.map(\.saysTop).max() ?? 0
            let captionTop = scenes.map { saysTop + ($0.saysHeight > 0 ? $0.saysHeight + 4 : 0) }.max() ?? 0
            for i in scenes.indices {
                scenes[i].saysTop = saysTop
                scenes[i].captionTop = captionTop
            }
            let rowHeight = scenes.map { $0.captionTop + $0.captionHeight - $0.origin.y }.max() ?? 0
            y += rowHeight + AnimMetrics.sceneGap
        }
        height = ceil(y - AnimMetrics.sceneGap + pad)
    }

    private func measureScene(_ sceneIndex: Int, origin: CGPoint, width w: CGFloat, index: Int) -> SceneBox {
        let index = sceneIndex
        let decl = run.script.scenes[index]
        let states = run.states[index]
        var box = SceneBox(origin: origin, width: w)
        var y = origin.y
        if let title = decl.title, !title.isEmpty, run.script.scenes.count > 1 || run.script.title == nil {
            box.titleHeight = AnimMetrics.measure(title, size: AnimMetrics.body, bold: true, maxWidth: w).height
            y += box.titleHeight + 6
        }
        let elements = Dictionary(decl.elements.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        for row in decl.rows {
            let n = CGFloat(row.count)
            let ew = floor((w - (n - 1) * AnimMetrics.rowGap) / n)
            var rowH: CGFloat = 0
            for (j, name) in row.enumerated() {
                guard let element = elements[name] else { continue }
                let h = elementHeight(element, width: ew, states: states, sceneIndex: index, decl: decl, box: &box, x: origin.x + CGFloat(j) * (ew + AnimMetrics.rowGap), y: y)
                box.elements[name] = CGRect(x: origin.x + CGFloat(j) * (ew + AnimMetrics.rowGap), y: y, width: ew, height: h)
                rowH = max(rowH, h)
            }
            y += rowH + AnimMetrics.rowGap
        }
        let saysLines = states.map(\.says.count).max() ?? 0
        box.saysTop = y
        if saysLines > 0 {
            let lineH = states.flatMap(\.says).map { AnimMetrics.measure($0, size: AnimMetrics.body, maxWidth: w - 16).height }.max() ?? 16
            box.saysHeight = CGFloat(saysLines) * (lineH + 8)
            y += box.saysHeight + 4
        }
        box.captionTop = y
        let captionH = states.map { AnimMetrics.measure($0.caption, size: AnimMetrics.body, maxWidth: w).height }.max() ?? 0
        box.captionHeight = max(captionH, run.stepCount > 1 ? 16 : 0)
        y += box.captionHeight
        box.height = y - origin.y
        return box
    }

    static let nameHeight: CGFloat = 14

    private func elementHeight(_ e: AnimElement, width w: CGFloat, states: [AnimSceneState], sceneIndex: Int, decl: AnimSceneDecl,
                               box: inout SceneBox, x: CGFloat, y: CGFloat) -> CGFloat {
        let nameH = e.name.hasPrefix("#") ? 0 : Self.nameHeight
        let pointed = Self.pointedElements(states).contains(e.name)
        let band = pointed ? Self.pointerBand : 0
        switch e.kind {
        case .array:
            let count = states.map { $0.cells[e.name]?.count ?? 0 }.max() ?? 0
            return nameH + Self.cellSize(width: w, count: count, max: 36) + 14 + band
        case .queue:
            let count = max(states.map { $0.cells[e.name]?.count ?? 0 }.max() ?? 0, 1)
            return nameH + Self.cellSize(width: w, count: count, max: 36) + 4 + band
        case .list, .tree, .graph, .grid, .sheet:
            return structureHeight(e, width: w, states: states, nameH: nameH, pointed: pointed)
        case .pointer:
            return 0
        case .stack:
            let count = max(states.map { $0.cells[e.name]?.count ?? 0 }.max() ?? 0, 1)
            return nameH + CGFloat(count) * 24 + 6
        case .variable:
            return 26
        case .text(let s):
            return AnimMetrics.measure(s, size: AnimMetrics.body, maxWidth: w).height
        case .seq(let lo, let hi, _, _, _):
            return nameH + Self.cellSize(width: w, count: hi - lo + 1, max: 30) + 18
        case .lanes(let names):
            let left = x, right = x + w
            let side: CGFloat = min(90, w * 0.22)
            for (i, lane) in names.enumerated() {
                let t = names.count == 1 ? 0.5 : CGFloat(i) / CGFloat(names.count - 1)
                box.laneX[lane] = (left + side + t * (right - left - 2 * side)).rounded()
            }
            var top = y + 18
            // 挂在竖线上的序号条：每条竖线下面一行一条
            var rows: [String: Int] = [:]
            var maxRows = 0
            let spacing = names.count > 1 ? (right - left - 2 * side) / CGFloat(names.count - 1) : w
            var placed: [(String, String, Int, Int)] = []
            for el in decl.elements {
                guard case .seq(let lo, let hi, _, _, let lane?) = el.kind else { continue }
                let r = rows[lane, default: 0]
                rows[lane] = r + 1
                maxRows = max(maxRows, r + 1)
                placed.append((el.name, lane, r, hi - lo + 1))
            }
            let seqRow: CGFloat = 12 + 22 + 10
            for (name, lane, r, count) in placed {
                let cell = Self.cellSize(width: min(spacing + side, w) - 8, count: count, max: 22)
                let sw = cell * CGFloat(count)
                let cx = box.laneX[lane] ?? x
                let sx = min(max(cx - sw / 2, left), right - sw)
                box.attachedSeqs[name] = CGRect(x: sx, y: top + CGFloat(r) * seqRow + 12, width: sw, height: cell)
            }
            top += CGFloat(max(maxRows, seqRowsAcrossScenes)) * seqRow + 4
            box.timelineTop = top
            let length = run.timelineLength.indices.contains(sceneIndex) ? run.timelineLength[sceneIndex] : 0
            return top - y + CGFloat(length) * AnimMetrics.unit + 8
        }
    }

    static func cellSize(width: CGFloat, count: Int, max m: CGFloat) -> CGFloat {
        guard count > 0 else { return m }
        return min(m, max(14, floor(width / CGFloat(count))))
    }

    // MARK: - 某一步的画面

    func frame(step: Int) -> AnimFrame {
        var items: [AnimItem] = []
        let pad = AnimMetrics.pad
        if let title = run.script.title, !title.isEmpty {
            items.append(AnimItem(id: "title", shape: .text(title, frame: CGRect(x: pad, y: pad, width: width - 2 * pad, height: titleHeight),
                                                              size: AnimMetrics.titleSize, bold: true, role: .ink, align: .left, backdrop: false)))
        }
        for (i, box) in scenes.enumerated() {
            items += sceneItems(i, box: box, state: run.state(scene: i, step: step))
        }
        return AnimFrame(size: CGSize(width: width, height: height), items: items)
    }

    private func sceneItems(_ index: Int, box: SceneBox, state: AnimSceneState) -> [AnimItem] {
        let decl = run.script.scenes[index]
        let p = "s\(index)."
        var items: [AnimItem] = []
        var anchors: [AnimPointerTarget: AnimAnchor] = [:]
        if box.titleHeight > 0, let title = decl.title {
            items.append(AnimItem(id: p + "title", shape: .text(title, frame: CGRect(x: box.origin.x, y: box.origin.y, width: box.width, height: box.titleHeight),
                                                                 size: AnimMetrics.body, bold: true, role: .ink, align: .left, backdrop: false)))
        }
        for element in decl.elements {
            if case .seq(_, _, _, _, let lane?) = element.kind {
                if let rect = box.attachedSeqs[element.name], lane.isEmpty == false {
                    items += seqItems(p + element.name, name: element.name, rect: rect, state: state, cellsOnly: false)
                }
                continue
            }
            guard let rect = box.elements[element.name] else { continue }
            let id = p + element.name
            let nameH = element.name.hasPrefix("#") ? 0 : Self.nameHeight
            let elementTone = state.elementTones[element.name] ?? .normal
            if nameH > 0, !isLanes(element) {
                let isVar: Bool = { if case .variable = element.kind { return true }; return false }()
                if !isVar {
                    items.append(AnimItem(id: id + ".name", shape: .text(element.name, frame: CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: nameH),
                                                                          size: AnimMetrics.small, bold: true, role: elementTone == .normal ? .secondary : .text(elementTone),
                                                                          align: .left, backdrop: false)))
                }
            }
            let body = CGRect(x: rect.minX, y: rect.minY + nameH, width: rect.width, height: rect.height - nameH)
            switch element.kind {
            case .array:
                items += cellRow(id, name: element.name, cells: state.cells[element.name] ?? [], rect: body, maxCell: 36, indexes: true, tone: elementTone, anchors: &anchors)
            case .queue:
                items += cellRow(id, name: element.name, cells: state.cells[element.name] ?? [], rect: body, maxCell: 36, indexes: false, tone: elementTone, anchors: &anchors)
            case .stack:
                items += stackItems(id, name: element.name, cells: state.cells[element.name] ?? [], rect: body, tone: elementTone, anchors: &anchors)
            case .list:
                items += listItems(id, name: element.name, rect: body, state: state, tone: elementTone, anchors: &anchors)
            case .tree:
                items += treeItems(id, name: element.name, rect: body, state: state, tone: elementTone, anchors: &anchors)
            case .graph:
                items += graphItems(id, element: element, rect: body, state: state, tone: elementTone, anchors: &anchors)
            case .grid:
                items += gridItems(id, name: element.name, rect: body, state: state, tone: elementTone, anchors: &anchors)
            case .sheet:
                items += sheetItems(id, name: element.name, rect: body, state: state, tone: elementTone)
            case .pointer:
                break
            case .variable:
                let v = state.vars[element.name] ?? AnimVar(value: "", tone: .normal)
                let text = "\(element.name) = \(v.value)"
                let size = AnimMetrics.measure(text, size: AnimMetrics.body)
                let wBox = min(rect.width, size.width + 16)
                let r = CGRect(x: rect.minX, y: rect.minY + 2, width: wBox, height: 22)
                items.append(AnimItem(id: id + ".box", shape: .box(r, radius: 5, fill: .fill(v.tone), stroke: .stroke(v.tone), lineWidth: 1, dashed: false)))
                items.append(AnimItem(id: id + ".v", shape: .text(text, frame: r.insetBy(dx: 6, dy: 0), size: AnimMetrics.body, bold: false,
                                                                   role: .text(v.tone), align: .center, backdrop: false)))
            case .text(let s):
                items.append(AnimItem(id: id, shape: .text(s, frame: rect, size: AnimMetrics.body, bold: false, role: .ink, align: .left, backdrop: false)))
            case .seq:
                items += seqItems(id, name: element.name, rect: CGRect(x: body.minX, y: body.minY + 3, width: body.width, height: body.height - 18),
                                  state: state, cellsOnly: true)
            case .lanes(let names):
                items += laneItems(p, names: names, rect: rect, box: box, state: state, sceneIndex: index)
            }
        }
        items += pointerItems(p, state: state, anchors: anchors)
        // 提示与说明
        for (i, say) in state.says.enumerated() {
            let h = (box.saysHeight / CGFloat(max(state.says.count, 1)))
            let r = CGRect(x: box.origin.x, y: box.saysTop + CGFloat(i) * h, width: box.width, height: h - 6)
            items.append(AnimItem(id: p + "say\(state.step).\(i)", shape: .box(r, radius: 6, fill: .fill(.active), stroke: nil, lineWidth: 0, dashed: false)))
            items.append(AnimItem(id: p + "sayt\(state.step).\(i)", shape: .text(say, frame: r.insetBy(dx: 8, dy: 3), size: AnimMetrics.body, bold: false,
                                                                                   role: .ink, align: .left, backdrop: false)))
        }
        if !state.caption.isEmpty {
            items.append(AnimItem(id: p + "caption", shape: .text(state.caption, frame: CGRect(x: box.origin.x, y: box.captionTop, width: box.width, height: box.captionHeight),
                                                                                 size: AnimMetrics.body, bold: false, role: .ink, align: .left, backdrop: false)))
        }
        return items
    }

    private func isLanes(_ e: AnimElement) -> Bool { if case .lanes = e.kind { return true }; return false }

    private func cellRow(_ id: String, name: String, cells: [AnimCell], rect: CGRect, maxCell: CGFloat, indexes: Bool, tone: AnimTone,
                         anchors: inout [AnimPointerTarget: AnimAnchor]) -> [AnimItem] {
        var items: [AnimItem] = []
        let capacity = max(Int(rect.width / 14), 1)
        let size = Self.cellSize(width: rect.width, count: min(max(cells.count, 1), capacity), max: maxCell)
        // 指针可以指 0…count（count = 末尾之后，如 i = n）
        let below = rect.minY + size + (indexes ? 13 : 1)
        for i in 0...cells.count {
            let x = rect.minX + CGFloat(i) * size + size / 2
            anchors[.index(element: name, i)] = AnimAnchor(point: CGPoint(x: x, y: below), label: CGPoint(x: x, y: below + Self.pointerBand / 2 + 2), spread: .horizontal)
        }
        for (i, cell) in cells.enumerated() {
            let r = CGRect(x: rect.minX + CGFloat(i) * size, y: rect.minY, width: size, height: size)
            let t = cell.tone == .normal ? tone : cell.tone
            items.append(AnimItem(id: "\(id).c\(cell.id)", shape: .box(r, radius: 3, fill: .fill(t), stroke: .stroke(t), lineWidth: 1, dashed: false)))
            items.append(AnimItem(id: "\(id).v\(cell.id)", shape: .text(cell.value, frame: r.insetBy(dx: 1, dy: 0), size: size < 22 ? AnimMetrics.small : AnimMetrics.body,
                                                                         bold: false, role: .text(t), align: .center, backdrop: false)))
            if indexes {
                items.append(AnimItem(id: "\(id).i\(i)", shape: .text("\(i)", frame: CGRect(x: r.minX, y: r.maxY + 1, width: size, height: 12),
                                                                       size: AnimMetrics.small - 1, bold: false, role: .secondary, align: .center, backdrop: false)))
            }
        }
        if cells.isEmpty {
            let r = CGRect(x: rect.minX, y: rect.minY, width: size, height: size)
            items.append(AnimItem(id: "\(id).empty", shape: .box(r, radius: 3, fill: nil, stroke: .grid, lineWidth: 1, dashed: true)))
        }
        return items
    }

    private func stackItems(_ id: String, name: String, cells: [AnimCell], rect: CGRect, tone: AnimTone,
                            anchors: inout [AnimPointerTarget: AnimAnchor]) -> [AnimItem] {
        var items: [AnimItem] = []
        let w = min(rect.width, 90), h: CGFloat = 24
        let bottom = rect.maxY - 3
        // 容器：左右两条边 + 底
        let x0 = rect.minX, x1 = rect.minX + w + 6
        items.append(AnimItem(id: "\(id).frame", shape: .line([CGPoint(x: x0, y: rect.minY), CGPoint(x: x0, y: bottom + 3), CGPoint(x: x1, y: bottom + 3), CGPoint(x: x1, y: rect.minY)],
                                                                role: .grid, width: 1.5, dashed: false, arrow: false, progress: 1)))
        for (i, cell) in cells.enumerated() {
            let r = CGRect(x: x0 + 3, y: bottom - CGFloat(i + 1) * h, width: w, height: h - 2)
            // 栈的指针在右边，标签朝左指过来（用竖排错开；标签在格子右侧外面）
            anchors[.index(element: name, i)] = AnimAnchor(point: CGPoint(x: x1 + 2, y: r.midY), label: CGPoint(x: x1 + 26, y: r.midY), spread: .vertical)
            let t = cell.tone == .normal ? tone : cell.tone
            items.append(AnimItem(id: "\(id).c\(cell.id)", shape: .box(r, radius: 3, fill: .fill(t), stroke: .stroke(t), lineWidth: 1, dashed: false)))
            items.append(AnimItem(id: "\(id).v\(cell.id)", shape: .text(cell.value, frame: r, size: AnimMetrics.body, bold: false, role: .text(t), align: .center, backdrop: false)))
        }
        return items
    }

    /// 序号条：一排号 + 窗口框。`cellsOnly` = 独立的序号条（rect 是给它的整块，号按宽排）；否则 rect 就是号那一排。
    private func seqItems(_ id: String, name: String, rect: CGRect, state: AnimSceneState, cellsOnly: Bool) -> [AnimItem] {
        guard let seq = state.seqs[name] else { return [] }
        var items: [AnimItem] = []
        let count = seq.upper - seq.lower + 1
        let size = cellsOnly ? Self.cellSize(width: rect.width, count: count, max: 30) : rect.height
        let top = rect.minY
        let elementTone = state.elementTones[name] ?? .normal
        if !cellsOnly {
            items.append(AnimItem(id: id + ".name", shape: .text(name, frame: CGRect(x: rect.minX, y: rect.minY - 13, width: max(rect.width, 80), height: 12),
                                                                  size: AnimMetrics.small - 1, bold: true, role: elementTone == .normal ? .secondary : .text(elementTone),
                                                                  align: .left, backdrop: false)))
        }
        for n in seq.lower...seq.upper {
            let i = n - seq.lower
            let r = CGRect(x: rect.minX + CGFloat(i) * size, y: top, width: size, height: size)
            let inWindow = n >= seq.start && n < seq.start + seq.window
            let t = seq.tones[n] ?? (inWindow ? .normal : .muted)
            items.append(AnimItem(id: "\(id).c\(n)", shape: .box(r, radius: 2, fill: .fill(t), stroke: .grid, lineWidth: 0.75, dashed: false)))
            items.append(AnimItem(id: "\(id).v\(n)", shape: .text(seq.label(n), frame: r, size: size < 20 ? AnimMetrics.small - 1 : AnimMetrics.small,
                                                                   bold: inWindow, role: .text(t), align: .center, backdrop: false)))
        }
        let first = max(seq.start, seq.lower), last = min(seq.start + seq.window - 1, seq.upper)
        if first <= last {
            let wr = CGRect(x: rect.minX + CGFloat(first - seq.lower) * size - 2, y: top - 2,
                            width: CGFloat(last - first + 1) * size + 4, height: size + 4)
            items.append(AnimItem(id: "\(id).window", shape: .box(wr, radius: 4, fill: nil, stroke: .stroke(.active), lineWidth: 2, dashed: false)))
        }
        return items
    }

    // MARK: 时序图

    private func laneItems(_ p: String, names: [String], rect: CGRect, box: SceneBox, state: AnimSceneState, sceneIndex: Int) -> [AnimItem] {
        var items: [AnimItem] = []
        let top = box.timelineTop
        let bottom = rect.maxY - 4
        func y(_ t: Double) -> CGFloat { top + CGFloat(t) * AnimMetrics.unit }
        let leftmost = names.first, rightmost = names.last

        for lane in names {
            guard let x = box.laneX[lane] else { continue }
            let label = AnimMetrics.measure(lane, size: AnimMetrics.body, bold: true)
            items.append(AnimItem(id: p + "lane.\(lane).name", shape: .text(lane, frame: CGRect(x: x - label.width / 2 - 4, y: rect.minY, width: label.width + 8, height: 16),
                                                                            size: AnimMetrics.body, bold: true, role: .ink, align: .center, backdrop: false)))
            items.append(AnimItem(id: p + "lane.\(lane).line", shape: .line([CGPoint(x: x, y: top - 4), CGPoint(x: x, y: bottom)],
                                                                            role: .grid, width: 1.5, dashed: false, arrow: false, progress: 1)))
        }
        // 每一步开头一道淡横线 + 步号（只画到当前步）
        if state.step > 0 {
            let states = run.states[sceneIndex]
            for k in 1...min(state.step, states.count - 1) {
                let start = states[k - 1].cursor
                let yy = y(start)
                items.append(AnimItem(id: p + "slot\(k)", shape: .text("\(k)", frame: CGRect(x: rect.minX, y: yy - 1, width: 16, height: 12),
                                                                     size: AnimMetrics.small - 1, bold: true, role: .secondary, align: .left, backdrop: false)))
            }
        }

        let cursor = state.cursor
        // 计时器：竖线外侧的竖条
        for timer in state.timers {
            guard let x = box.laneX[timer.lane] else { continue }
            let outward: CGFloat = timer.lane == rightmost && timer.lane != leftmost ? 1 : -1
            let tx = x + outward * 6
            let end = min(timer.end ?? cursor, cursor)
            guard end >= timer.start else { continue }
            let span = max(end - timer.start, 0.01)
            items.append(AnimItem(id: p + "timer\(timer.id)", shape: .line([CGPoint(x: tx, y: y(timer.start)), CGPoint(x: tx, y: y(timer.start + span))],
                                                                            role: .stroke(timer.expired ? .wrong : .muted), width: 2, dashed: timer.end == nil,
                                                                            arrow: false, progress: 1)))
        }
        // 消息
        for m in state.messages {
            guard let x0 = box.laneX[m.from], let x1 = box.laneX[m.to] else { continue }
            let a = CGPoint(x: x0, y: y(m.start))
            let full = CGPoint(x: x1, y: y(m.start + (m.end - m.start) / (m.lost ? 0.55 : 1)))
            // 丢失：只画到 55% 的地方
            let b = m.lost ? CGPoint(x: a.x + (full.x - a.x) * 0.55, y: a.y + (full.y - a.y) * 0.55) : full
            let progress = CGFloat(min(max((cursor - m.start) / max(m.end - m.start, 0.01), 0), 1))
            let old = m.step < state.step
            let role: AnimRole = m.tone == .normal ? .ink : .stroke(m.tone)
            items.append(AnimItem(id: p + "msg\(m.id)", shape: .line([a, b], role: role, width: 1.5, dashed: m.lost, arrow: !m.lost, progress: progress),
                                  alpha: old ? 0.45 : 1))
            if progress > 0 {
                let size = AnimMetrics.measure(m.label, size: AnimMetrics.small)
                let along: CGFloat = 0.3
                let c = CGPoint(x: a.x + (b.x - a.x) * along, y: a.y + (b.y - a.y) * along)
                let r = CGRect(x: c.x - size.width / 2 - 2, y: c.y - size.height / 2 - 1, width: size.width + 4, height: size.height + 2)
                items.append(AnimItem(id: p + "msgl\(m.id)", shape: .text(m.label, frame: r, size: AnimMetrics.small, bold: false,
                                                                          role: m.tone == .normal ? .ink : .text(m.tone), align: .center, backdrop: true),
                                      alpha: old ? 0.55 : 1))
            }
            if m.lost && progress >= 1 {
                items.append(AnimItem(id: p + "msgx\(m.id)", shape: .cross(b, size: 5, role: .stroke(.wrong)), alpha: old ? 0.55 : 1))
            }
        }
        // 竖线旁的标记
        for mark in state.marks where mark.time <= cursor + 0.001 {
            guard let x = box.laneX[mark.lane] else { continue }
            let leftSide = mark.lane == leftmost && names.count > 1
            let glyph: String
            switch mark.kind {
            case .deliver: glyph = "✓ "
            case .discard: glyph = "✕ "
            case .buffer: glyph = "▣ "
            case .note: glyph = ""
            case .timerStart: glyph = "⏱ "
            case .timerStop: glyph = "■ "
            case .timerExpire: glyph = "⏰ "
            }
            let text = glyph + mark.label
            let size = AnimMetrics.measure(text, size: AnimMetrics.small)
            let yy = y(mark.time)
            let gapX: CGFloat = 12
            let r = leftSide
                ? CGRect(x: x - gapX - size.width, y: yy - size.height / 2, width: size.width, height: size.height)
                : CGRect(x: x + gapX, y: yy - size.height / 2, width: size.width, height: size.height)
            let old = mark.step < state.step
            items.append(AnimItem(id: p + "mark\(mark.id)", shape: .text(text, frame: r, size: AnimMetrics.small, bold: mark.kind == .timerExpire,
                                                                         role: mark.tone == .normal ? .ink : .text(mark.tone),
                                                                         align: leftSide ? .right : .left, backdrop: true),
                                  alpha: old ? 0.55 : 1))
            if mark.kind != .timerStart && mark.kind != .timerStop {
                items.append(AnimItem(id: p + "markd\(mark.id)", shape: .box(CGRect(x: x - 2.5, y: yy - 2.5, width: 5, height: 5), radius: 2.5,
                                                                             fill: .stroke(mark.tone), stroke: nil, lineWidth: 0, dashed: false),
                                      alpha: old ? 0.55 : 1))
            }
        }
        return items
    }
}
