import Foundation

// 分步演示的状态：第 k 步的画面 = 初始状态依次执行第 1…k 步的动作（纯函数，`ANIM-BLOCK-PLAN.md §2`）。
// 时序图的时间用「单位」记（不是点）：布局时再乘上每单位多少点。只依赖 Foundation。

struct AnimCell: Equatable {
    /// 稳定身份：交换 / 改值时跟着格子走，补间动画按它配对。
    let id: Int
    var value: String
    var tone: AnimTone
}

struct AnimSeqState: Equatable {
    let lower: Int
    let upper: Int
    let modulo: Int?
    var window: Int
    var start: Int
    var tones: [Int: AnimTone] = [:]

    func label(_ n: Int) -> String { String(modulo.map { ((n % $0) + $0) % $0 } ?? n) }
}

struct AnimMessage: Equatable {
    let id: Int
    let name: String?
    let from: String
    let to: String
    let label: String
    let lost: Bool
    var tone: AnimTone
    /// 时间单位：发出 / 到达（丢失的是打叉处）。
    let start: Double
    let end: Double
    let step: Int
}

enum AnimMarkKind: Equatable {
    case deliver, discard, buffer, note
    case timerStart, timerStop, timerExpire
}

/// 竖线旁的一个标记（交付 / 丢弃 / 缓存 / 说明 / 计时器起止）。
struct AnimLaneMark: Equatable {
    let id: Int
    let lane: String
    let label: String
    let kind: AnimMarkKind
    let tone: AnimTone
    let time: Double
    let step: Int
}

/// 计时器：从启动到停止 / 超时，画成竖线外侧的一道竖条。
struct AnimTimer: Equatable {
    let id: Int
    let lane: String
    let label: String
    let start: Double
    var end: Double?
    var expired: Bool
}

struct AnimVar: Equatable {
    var value: String
    var tone: AnimTone
}

struct AnimSceneState: Equatable {
    var step = 0
    var caption = ""
    var cells: [String: [AnimCell]] = [:]
    var vars: [String: AnimVar] = [:]
    var seqs: [String: AnimSeqState] = [:]
    /// 整个元素的颜色（`mark A done` 不带下标）。
    var elementTones: [String: AnimTone] = [:]
    var lists: [String: AnimListState] = [:]
    var trees: [String: AnimTreeState] = [:]
    var graphs: [String: AnimGraphState] = [:]
    var grids: [String: AnimGridState] = [:]
    var sheets: [String: AnimSheetState] = [:]
    /// 指针 → 指着什么（nil = 不指向任何东西）。
    var pointers: [String: AnimPointerTarget?] = [:]
    var messages: [AnimMessage] = []
    var marks: [AnimLaneMark] = []
    var timers: [AnimTimer] = []
    /// 只在这一步出现的提示。
    var says: [String] = []
    /// 时序图「现在」到哪了（时间单位）：消息只画到这里，于是步与步之间插值就是消息在飞。
    var cursor: Double = 0
}

struct AnimRun {
    let script: AnimScript
    /// `states[场景][步]`；步数不够的场景停在最后一步。
    let states: [[AnimSceneState]]
    /// 每个场景时序图的总长（时间单位）；没有时序图是 0。
    let timelineLength: [Double]
    /// 解析错误 + 执行时发现的错误（按行号排、去重）。
    let errors: [AnimDiagnostic]

    var stepCount: Int { script.stepCount }

    func state(scene: Int, step: Int) -> AnimSceneState {
        let list = states[scene]
        return list[min(max(step, 0), list.count - 1)]
    }

    /// 某一步的说明（各场景里第一个非空的；对比时每个场景自己画自己的）。
    func caption(step: Int) -> String {
        for i in states.indices {
            let s = state(scene: i, step: step)
            if s.step == step, !s.caption.isEmpty { return s.caption }
        }
        return ""
    }
}

enum AnimEngine {
    /// 时序图的时间单位。
    static let travel: Double = 6      // 一条消息从发出到到达（斜一点才看得出先后）
    static let gap: Double = 1.6       // 同一条竖线上两件事之间（相邻两条消息的标签别挤在一起）
    static let slotPad: Double = 1     // 两步之间留白

    static func run(_ script: AnimScript) -> AnimRun {
        var errors = script.errors
        var states: [[AnimSceneState]] = []
        var lengths: [Double] = []
        for scene in script.scenes {
            let (list, length, errs) = runScene(scene)
            states.append(list)
            lengths.append(length)
            errors += errs
        }
        var seen = Set<String>()
        errors = errors.sorted { $0.line < $1.line }.filter { seen.insert("\($0.line)|\($0.message)").inserted }
        return AnimRun(script: script, states: states, timelineLength: lengths, errors: errors)
    }

    static func run(_ source: String) -> AnimRun { run(AnimText.parse(source)) }

    private static func runScene(_ scene: AnimSceneDecl) -> ([AnimSceneState], Double, [AnimDiagnostic]) {
        var errors: [AnimDiagnostic] = []
        var nextID = 1
        func newID() -> Int { defer { nextID += 1 }; return nextID }

        var lanes: [String] = []
        var initial = AnimSceneState()
        for element in scene.elements {
            switch element.kind {
            case .lanes(let names): lanes = names
            case .seq(let lo, let hi, let w, let m, _):
                initial.seqs[element.name] = AnimSeqState(lower: lo, upper: hi, modulo: m, window: w, start: lo)
            case .array(let v), .stack(let v), .queue(let v):
                initial.cells[element.name] = v.map { AnimCell(id: newID(), value: $0, tone: .normal) }
            case .variable(let v):
                initial.vars[element.name] = AnimVar(value: v, tone: .normal)
            case .text, .pointer:
                break
            case .list, .tree, .graph, .grid, .sheet:
                initialStructure(element, into: &initial, newID: newID)
            }
        }
        let kinds = Dictionary(scene.elements.map { ($0.name, $0.kind) }, uniquingKeysWith: { a, _ in a })
        for element in scene.elements { initialPointer(element, into: &initial, kinds: kinds, errors: &errors) }
        // 写在第一个 step 之前的竖式内容：第 0 步就有
        for (line, action) in scene.setup.first?.actions ?? [] {
            let handled = applyStructure(action, &initial, kinds: kinds, newID: newID) { errors.append(AnimDiagnostic(line: line, message: $0)) }
            if !handled {
                errors.append(AnimDiagnostic(line: line, message: "before the first step only sheet / list / tree / graph / grid actions are allowed; put this inside a step"))
            }
        }

        var list = [initial]
        var state = initial
        var slotStart: Double = 0
        var pendingNext: [(index: Int, start: Double)] = []   // arrive=next 的消息：到达时间等下一步定

        for (k, step) in scene.steps.enumerated() {
            state.step = k + 1
            state.caption = step.caption
            state.says = []
            var clock: [String: Double] = [:]          // 本步里每条竖线「下一件事」的相对时间
            var arrival: [String: Double] = [:]        // 本步里已到达该竖线的最晚相对时间
            var lastAction: [String: Double] = [:]
            var extent: Double = 0

            // 上一步 arrive=next 的消息：在这一步开头之后一点到达
            for p in pendingNext {
                let m = state.messages[p.index]
                let end = max(slotStart + travel * 0.6, p.start + travel)
                state.messages[p.index] = AnimMessage(id: m.id, name: m.name, from: m.from, to: m.to, label: m.label, lost: m.lost,
                                                      tone: m.tone, start: m.start, end: end, step: m.step)
                if !m.lost { arrival[m.to] = max(arrival[m.to] ?? 0, end - slotStart) }
                extent = max(extent, end - slotStart)
            }
            pendingNext.removeAll()

            func now(_ lane: String) -> Double { max(clock[lane] ?? 0, arrival[lane] ?? 0) }
            func checkLane(_ lane: String, _ line: Int) -> Bool {
                if lanes.contains(lane) { return true }
                errors.append(AnimDiagnostic(line: line, message: lanes.isEmpty ? "no `lanes` declared in this scene" : "no lane “\(lane)” (lanes: \(lanes.joined(separator: ", ")))"))
                return false
            }

            for (line, action) in step.actions {
                func fail(_ message: String) { errors.append(AnimDiagnostic(line: line, message: message)) }
                if applyStructure(action, &state, kinds: kinds, newID: newID, fail: fail) { continue }
                switch action {
                case .say(let text):
                    state.says.append(text)

                case .send(let from, let to, let label, let name, let lost, let tone, let arriveNext):
                    guard checkLane(from, line), checkLane(to, line) else { continue }
                    guard from != to else { fail("send: from and to are the same lane"); continue }
                    if let name, state.messages.contains(where: { $0.name == name }) { fail("as=\(name) is already used"); continue }
                    let t = now(from)
                    let start = slotStart + t
                    let end = lost ? start + travel * 0.55 : start + travel
                    state.messages.append(AnimMessage(id: newID(), name: name, from: from, to: to, label: label, lost: lost,
                                                      tone: tone ?? (lost ? .wrong : .normal), start: start, end: end, step: k + 1))
                    if arriveNext && !lost {
                        pendingNext.append((state.messages.count - 1, start))
                    } else {
                        if !lost { arrival[to] = max(arrival[to] ?? 0, t + travel) }
                        extent = max(extent, end - slotStart)
                    }
                    lastAction[from] = t
                    clock[from] = t + gap
                    extent = max(extent, t + gap)

                case .laneEvent(let lane, let label, let kind, let tone):
                    guard checkLane(lane, line) else { continue }
                    let t = now(lane)
                    let markKind: AnimMarkKind
                    let defaultTone: AnimTone
                    switch kind {
                    case .deliver: markKind = .deliver; defaultTone = .done
                    case .discard: markKind = .discard; defaultTone = .wrong
                    case .buffer: markKind = .buffer; defaultTone = .new
                    case .note: markKind = .note; defaultTone = .normal
                    }
                    state.marks.append(AnimLaneMark(id: newID(), lane: lane, label: label, kind: markKind, tone: tone ?? defaultTone,
                                                    time: slotStart + t, step: k + 1))
                    lastAction[lane] = t
                    clock[lane] = t + gap
                    extent = max(extent, t + gap)

                case .timer(let lane, let label, let op):
                    guard checkLane(lane, line) else { continue }
                    switch op {
                    case .start:
                        let t = lastAction[lane] ?? now(lane)
                        state.timers.append(AnimTimer(id: newID(), lane: lane, label: label, start: slotStart + t, end: nil, expired: false))
                        state.marks.append(AnimLaneMark(id: newID(), lane: lane, label: label, kind: .timerStart, tone: .muted,
                                                        time: slotStart + t, step: k + 1))
                        extent = max(extent, t + gap)
                    case .stop, .expire:
                        guard let i = state.timers.lastIndex(where: { $0.lane == lane && $0.label == label && $0.end == nil }) else {
                            fail("timer \(label) on \(lane) is not running (start it first)")
                            continue
                        }
                        let t = now(lane)
                        state.timers[i].end = slotStart + t
                        state.timers[i].expired = op == .expire
                        state.marks.append(AnimLaneMark(id: newID(), lane: lane, label: label,
                                                        kind: op == .expire ? .timerExpire : .timerStop,
                                                        tone: op == .expire ? .wrong : .muted, time: slotStart + t, step: k + 1))
                        if op == .expire {
                            lastAction[lane] = t
                            clock[lane] = t + gap
                        }
                        extent = max(extent, t + gap)
                    }

                case .slide(let name, let to, let by):
                    guard var seq = state.seqs[name] else { fail("no seq “\(name)”"); continue }
                    let target = to ?? (seq.start + (by ?? 0))
                    guard target >= seq.lower, target <= seq.upper else { fail("slide: \(target) is outside \(seq.lower)..\(seq.upper)"); continue }
                    seq.start = target
                    state.seqs[name] = seq

                case .mark(let target, let tone):
                    apply(target, line: line, &state, kinds: kinds, fail: fail) { tones in tone }
                case .unmark(let target):
                    apply(target, line: line, &state, kinds: kinds, fail: fail) { _ in .normal }

                case .set(let target, let value):
                    if target.key == nil, state.vars[target.name] != nil {
                        state.vars[target.name]!.value = value
                    } else if var cells = state.cells[target.name], let lo = target.lower, let hi = target.upper {
                        guard lo >= 0, hi < cells.count else { fail("\(target.name) has \(cells.count) item(s), index \(hi) is out of range"); continue }
                        for i in lo...hi { cells[i].value = value }
                        state.cells[target.name] = cells
                    } else {
                        fail("set: “\(target.text)” is not a var or an array cell")
                    }

                case .swap(let a, let b):
                    guard a.name == b.name, var cells = state.cells[a.name], let i = a.lower, let j = b.lower else {
                        fail("swap: both cells must be in the same array")
                        continue
                    }
                    guard i >= 0, j >= 0, i < cells.count, j < cells.count else { fail("swap: index out of range (\(cells.count) items)"); continue }
                    cells.swapAt(i, j)
                    state.cells[a.name] = cells

                case .push(let name, let value), .enqueue(let name, let value):
                    guard state.cells[name] != nil else { fail("no stack / queue “\(name)”"); continue }
                    let isQueue: Bool
                    if case .enqueue = action { isQueue = true } else { isQueue = false }
                    if let kind = kinds[name] {
                        if isQueue, case .stack = kind { fail("\(name) is a stack: use push / pop"); continue }
                        if !isQueue, case .queue = kind { fail("\(name) is a queue: use enqueue / dequeue"); continue }
                    }
                    guard state.cells[name]!.count < 40 else { fail("\(name): at most 40 items"); continue }
                    state.cells[name]!.append(AnimCell(id: newID(), value: value, tone: .new))
                case .pop(let name), .dequeue(let name):
                    guard let cells = state.cells[name] else { fail("no stack / queue “\(name)”"); continue }
                    guard !cells.isEmpty else { fail("\(name) is empty"); continue }
                    if case .dequeue = action { state.cells[name]!.removeFirst() } else { state.cells[name]!.removeLast() }

                case .insertAt(let name, _, _), .insertTree(let name, _, _, _), .remove(let name, _), .rotate(let name, _, _), .move(let name, _):
                    fail(kinds[name] == nil ? "no element “\(name)”" : "\(name) does not support this action")
                case .link(let t, _):
                    fail(kinds[t.name] == nil ? "no element “\(t.name)”" : "link is for lists")
                case .write(let t, _), .rule(let t, _), .arrow(let t), .label(let t, _):
                    fail(kinds[t.name] == nil ? "no element “\(t.name)”" : "\(t.name) is not a sheet")
                }
            }
            // 新进栈 / 队的格子只在进来那一步是 new 色，下一步回到原色（除非显式 mark）
            let height = max(extent, lanes.isEmpty ? 0 : gap)
            slotStart += height + slotPad
            state.cursor = lanes.isEmpty ? 0 : slotStart
            list.append(state)
            for (name, cells) in state.cells {
                state.cells[name] = cells.map { var c = $0; if c.tone == .new { c.tone = .normal }; return c }
            }
            for (name, l) in state.lists {
                state.lists[name]!.nodes = l.nodes.map { var n = $0; if n.tone == .new { n.tone = .normal }; return n }
            }
            for (name, t) in state.trees {
                for (id, n) in t.nodes where n.tone == .new { state.trees[name]!.nodes[id]!.tone = .normal }
            }
        }
        // 最后一步里还挂着的 arrive=next：没有下一步了，就地到达
        for p in pendingNext {
            let m = list[list.count - 1].messages[p.index]
            let fixed = AnimMessage(id: m.id, name: m.name, from: m.from, to: m.to, label: m.label, lost: m.lost, tone: m.tone,
                                    start: m.start, end: m.start + travel, step: m.step)
            list[list.count - 1].messages[p.index] = fixed
            slotStart = max(slotStart, fixed.end + slotPad)
            list[list.count - 1].cursor = slotStart
        }
        return (list, lanes.isEmpty ? 0 : slotStart, errors)
    }

    /// `mark` / `unmark` 作用到目标上：数组 / 栈 / 队列的格子、序号条的号、变量、消息（`as=` 名）、整个元素。
    private static func apply(_ target: AnimTarget, line: Int, _ state: inout AnimSceneState, kinds: [String: AnimElementKind],
                              fail: (String) -> Void, tone: (AnimTone) -> AnimTone) {
        let name = target.name
        if var cells = state.cells[name] {
            if target.key != nil, target.lower == nil { fail("\(target.text): indexes are numbers, like \(name)[2] or \(name)[1..3]"); return }
            if let lo = target.lower, let hi = target.upper {
                guard lo >= 0, hi < cells.count else { fail("\(name) has \(cells.count) item(s), index \(hi) is out of range"); return }
                for i in lo...hi { cells[i].tone = tone(cells[i].tone) }
                state.cells[name] = cells
            } else {
                state.elementTones[name] = tone(state.elementTones[name] ?? .normal)
            }
        } else if var seq = state.seqs[name] {
            if target.key != nil, target.lower == nil { fail("\(target.text): sequence numbers are numbers, like \(name)[2..5]"); return }
            if let lo = target.lower, let hi = target.upper {
                guard lo >= seq.lower, hi <= seq.upper else { fail("\(name) runs \(seq.lower)..\(seq.upper), \(lo)..\(hi) is outside"); return }
                for i in lo...hi { seq.tones[i] = tone(seq.tones[i] ?? .normal) }
                state.seqs[name] = seq
            } else {
                state.elementTones[name] = tone(state.elementTones[name] ?? .normal)
            }
        } else if state.vars[name] != nil {
            guard target.key == nil else { fail("\(name) is a var: no index"); return }
            state.vars[name]!.tone = tone(state.vars[name]!.tone)
        } else if let i = state.messages.lastIndex(where: { $0.name == name }) {
            let m = state.messages[i]
            state.messages[i] = AnimMessage(id: m.id, name: m.name, from: m.from, to: m.to, label: m.label, lost: m.lost,
                                            tone: tone(m.tone), start: m.start, end: m.end, step: m.step)
        } else if kinds[name] != nil {
            fail("\(name) cannot be marked")
        } else {
            fail("no element or message named “\(name)”")
        }
    }
}
