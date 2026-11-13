import Foundation

// 笔记里 ```anim 分步演示块的文字 → 场景描述（方案 `ANIM-BLOCK-PLAN.md`）。
// 只依赖 Foundation：spike 直接编（`swift spike/anim-test.swift`）。写法全文在 `AnimText.reference`（MCP 原样给 Agent）。

/// 某一行的问题。行号从 1 起，按块里的文字算（不含围栏行）。
struct AnimDiagnostic: Equatable {
    let line: Int
    let message: String
}

/// 语义颜色状态：不写色值，由画的时候映射到系统动态色。
enum AnimTone: String, CaseIterable {
    case normal, active, done, wrong, muted, new
}

/// 动作的目标：`A`、`A[2]`、`A[1..3]`、消息的 `as=` 名字、变量名。
struct AnimTarget: Equatable {
    let name: String
    let lower: Int?
    let upper: Int?

    var isRange: Bool { lower != nil }
}

enum AnimElementKind: Equatable {
    case lanes([String])
    case seq(lower: Int, upper: Int, window: Int, modulo: Int?, lane: String?)
    case array([String])
    case stack([String])
    case queue([String])
    case variable(String)
    case text(String)
}

struct AnimElement: Equatable {
    let name: String
    let kind: AnimElementKind
    let line: Int
}

enum AnimLaneEventKind: String {
    case deliver, discard, buffer, note
}

enum AnimTimerOp: String {
    case start, stop, expire
}

enum AnimAction: Equatable {
    case mark(AnimTarget, AnimTone)
    case unmark(AnimTarget)
    case set(AnimTarget, String)
    case swap(AnimTarget, AnimTarget)
    case push(String, String)
    case pop(String)
    case enqueue(String, String)
    case dequeue(String)
    case say(String)
    case send(from: String, to: String, label: String, id: String?, lost: Bool, tone: AnimTone?, arriveNext: Bool)
    case slide(String, to: Int?, by: Int?)
    case timer(lane: String, label: String, op: AnimTimerOp)
    case laneEvent(lane: String, label: String, kind: AnimLaneEventKind, tone: AnimTone?)
}

struct AnimStepDecl: Equatable {
    let caption: String
    var actions: [(line: Int, action: AnimAction)]
    let line: Int

    static func == (a: AnimStepDecl, b: AnimStepDecl) -> Bool {
        a.caption == b.caption && a.line == b.line && a.actions.map(\.line) == b.actions.map(\.line)
            && a.actions.map(\.action) == b.actions.map(\.action)
    }
}

struct AnimSceneDecl: Equatable {
    var title: String?
    var elements: [AnimElement] = []
    /// 排版：每一行是几个元素名（`row` 声明的横排；其余一个元素一行），按声明顺序。
    var rows: [[String]] = []
    var steps: [AnimStepDecl] = []
}

struct AnimScript: Equatable {
    var title: String?
    var scenes: [AnimSceneDecl] = []
    var errors: [AnimDiagnostic] = []

    /// 步数（含第 0 步初始画面）：各场景里最多的那个。
    var stepCount: Int { (scenes.map(\.steps.count).max() ?? 0) + 1 }
}

enum AnimText {
    static let language = "anim"

    // MARK: - 解析

    static func parse(_ source: String) -> AnimScript {
        var script = AnimScript()
        var scene: AnimSceneDecl?
        var explicitScenes = false
        var textCounter = 0
        let lines = source.components(separatedBy: "\n")

        func error(_ line: Int, _ message: String) {
            script.errors.append(AnimDiagnostic(line: line, message: message))
        }

        func closeScene() {
            if let s = scene { script.scenes.append(s) }
            scene = nil
        }

        for (offset, raw) in lines.enumerated() {
            let lineNo = offset + 1
            let tokens: [String]
            do {
                tokens = try tokenize(raw)
            } catch let e as AnimParseError {
                error(lineNo, e.message)
                continue
            } catch {
                continue
            }
            guard let head = tokens.first else { continue }
            let keyword = head.lowercased()
            let rest = Array(tokens.dropFirst())

            switch keyword {
            case "title":
                let text = rest.joined(separator: " ")
                if scene == nil && script.scenes.isEmpty { script.title = text } else if scene?.title == nil { scene?.title = text }
                continue
            case "size":
                continue   // 旧草案里的宽高比：现在高度按内容算，接受但不用
            case "scene":
                if scene != nil, !explicitScenes, scene?.elements.isEmpty == false || scene?.steps.isEmpty == false {
                    error(lineNo, "`scene` must come before any element or step (or put everything inside scenes)")
                }
                if explicitScenes || scene != nil { closeScene() }
                explicitScenes = true
                scene = AnimSceneDecl(title: rest.isEmpty ? nil : rest.joined(separator: " "))
                continue
            default:
                break
            }

            if scene == nil { scene = AnimSceneDecl() }

            if keyword == "step" {
                scene!.steps.append(AnimStepDecl(caption: rest.joined(separator: " "), actions: [], line: lineNo))
                continue
            }

            if scene!.steps.isEmpty {
                // 声明区
                do {
                    if keyword == "row" {
                        try declareRow(rest, in: &scene!)
                    } else {
                        let element = try parseElement(keyword: keyword, rest: rest, line: lineNo, textCounter: &textCounter)
                        if scene!.elements.contains(where: { $0.name == element.name }) {
                            throw AnimParseError("“\(element.name)” is already declared")
                        }
                        if case .lanes = element.kind, scene!.elements.contains(where: { if case .lanes = $0.kind { return true }; return false }) {
                            throw AnimParseError("only one `lanes` per scene")
                        }
                        scene!.elements.append(element)
                        if case .seq(_, _, _, _, let lane?) = element.kind {
                            guard scene!.elements.contains(where: { if case .lanes(let names) = $0.kind { return names.contains(lane) }; return false }) else {
                                scene!.elements.removeLast()
                                throw AnimParseError("seq at=\(lane): no such lane (declare `lanes` first)")
                            }
                        } else {
                            scene!.rows.append([element.name])
                        }
                    }
                } catch let e as AnimParseError {
                    error(lineNo, e.message)
                } catch {}
            } else {
                do {
                    let action = try parseAction(keyword: keyword, rest: rest)
                    scene!.steps[scene!.steps.count - 1].actions.append((lineNo, action))
                } catch let e as AnimParseError {
                    error(lineNo, e.message)
                } catch {}
            }
        }
        closeScene()
        if script.scenes.isEmpty || script.scenes.allSatisfy({ $0.elements.isEmpty }) {
            script.errors.append(AnimDiagnostic(line: 1, message: "nothing to show: declare at least one element (lanes, seq, array, stack, queue, var, text)"))
        }
        return script
    }

    private static func declareRow(_ names: [String], in scene: inout AnimSceneDecl) throws {
        guard names.count >= 2 else { throw AnimParseError("`row` needs two or more element names") }
        for name in names {
            guard scene.rows.contains(where: { $0 == [name] }) else {
                throw AnimParseError("row: “\(name)” is not a declared element on its own row")
            }
        }
        let first = scene.rows.firstIndex { $0 == [names[0]] }!
        scene.rows.removeAll { $0.count == 1 && names.contains($0[0]) }
        scene.rows.insert(names, at: min(first, scene.rows.count))
    }

    // MARK: 元素

    private static func parseElement(keyword: String, rest: [String], line: Int, textCounter: inout Int) throws -> AnimElement {
        switch keyword {
        case "lanes":
            let names = rest.filter { $0 != "|" }
            guard names.count >= 2 else { throw AnimParseError("`lanes` needs two or more names") }
            guard Set(names).count == names.count else { throw AnimParseError("lane names must differ") }
            return AnimElement(name: "lanes", kind: .lanes(names), line: line)
        case "seq":
            guard rest.count >= 2 else { throw AnimParseError("usage: seq NAME 0..7 window=4 [mod=8] [at=LANE]") }
            let name = try checkedName(rest[0])
            guard let (lo, hi) = parseRange(rest[1]), hi >= lo else { throw AnimParseError("seq range must look like 0..7") }
            guard hi - lo < 64 else { throw AnimParseError("seq: at most 64 numbers") }
            let opts = try options(Array(rest.dropFirst(2)), allowed: ["window", "mod", "at"])
            guard let w = opts["window"].flatMap(Int.init), w >= 1 else { throw AnimParseError("seq needs window=N (N ≥ 1)") }
            var modulo: Int?
            if let m = opts["mod"] {
                guard let v = Int(m), v >= 2 else { throw AnimParseError("mod must be a number ≥ 2") }
                modulo = v
            }
            return AnimElement(name: name, kind: .seq(lower: lo, upper: hi, window: w, modulo: modulo, lane: opts["at"]), line: line)
        case "array", "stack", "queue":
            guard rest.count >= 1 else { throw AnimParseError("usage: \(keyword) NAME = [a, b, c]") }
            let name = try checkedName(rest[0])
            var values: [String] = []
            if rest.count > 1 {
                guard rest[1] == "=" else { throw AnimParseError("usage: \(keyword) NAME = [a, b, c]") }
                values = try parseList(Array(rest.dropFirst(2)).joined(separator: " "))
            }
            guard values.count <= 40 else { throw AnimParseError("\(keyword): at most 40 items") }
            let kind: AnimElementKind = keyword == "array" ? .array(values) : keyword == "stack" ? .stack(values) : .queue(values)
            return AnimElement(name: name, kind: kind, line: line)
        case "var":
            guard rest.count >= 3, rest[1] == "=" else { throw AnimParseError("usage: var NAME = VALUE") }
            return AnimElement(name: try checkedName(rest[0]), kind: .variable(rest.dropFirst(2).joined(separator: " ")), line: line)
        case "text":
            guard !rest.isEmpty else { throw AnimParseError("usage: text \"…\"") }
            textCounter += 1
            return AnimElement(name: "#text\(textCounter)", kind: .text(rest.joined(separator: " ")), line: line)
        default:
            throw AnimParseError("unknown element “\(keyword)” (lanes, seq, array, stack, queue, var, text, row; actions go after a `step` line)")
        }
    }

    // MARK: 动作

    private static func parseAction(keyword: String, rest: [String]) throws -> AnimAction {
        switch keyword {
        case "mark":
            guard rest.count == 2 else { throw AnimParseError("usage: mark TARGET \(toneList)") }
            guard let tone = AnimTone(rawValue: rest[1].lowercased()) else { throw AnimParseError("unknown state “\(rest[1])”: \(toneList)") }
            return .mark(try parseTarget(rest[0]), tone)
        case "unmark":
            guard rest.count == 1 else { throw AnimParseError("usage: unmark TARGET") }
            return .unmark(try parseTarget(rest[0]))
        case "set":
            guard rest.count >= 3, rest[1] == "=" else { throw AnimParseError("usage: set TARGET = VALUE") }
            return .set(try parseTarget(rest[0]), rest.dropFirst(2).joined(separator: " "))
        case "swap":
            guard rest.count == 2 else { throw AnimParseError("usage: swap A[i] A[j]") }
            let a = try parseTarget(rest[0]), b = try parseTarget(rest[1])
            guard a.lower != nil, !a.isRangeSpan, b.lower != nil, !b.isRangeSpan else { throw AnimParseError("swap takes two single cells, like A[0] A[3]") }
            return .swap(a, b)
        case "push", "enqueue":
            guard rest.count >= 2 else { throw AnimParseError("usage: \(keyword) NAME VALUE") }
            let value = rest.dropFirst().joined(separator: " ")
            return keyword == "push" ? .push(rest[0], value) : .enqueue(rest[0], value)
        case "pop", "dequeue":
            guard rest.count == 1 else { throw AnimParseError("usage: \(keyword) NAME") }
            return keyword == "pop" ? .pop(rest[0]) : .dequeue(rest[0])
        case "say":
            guard !rest.isEmpty else { throw AnimParseError("usage: say \"…\"") }
            return .say(rest.joined(separator: " "))
        case "send":
            // send A -> B "label" [as=ID] [lost] [state=TONE] [arrive=next]
            guard rest.count >= 4, rest[1] == "->" else { throw AnimParseError("usage: send A -> B \"label\" [as=NAME] [lost] [state=…] [arrive=next]") }
            var lost = false
            var flags: [String] = []
            for word in rest.dropFirst(4) {
                if word.lowercased() == "lost" { lost = true } else { flags.append(word) }
            }
            let opts = try options(flags, allowed: ["as", "state", "arrive"])
            var tone: AnimTone?
            if let s = opts["state"] {
                guard let t = AnimTone(rawValue: s.lowercased()) else { throw AnimParseError("unknown state “\(s)”: \(toneList)") }
                tone = t
            }
            if let a = opts["arrive"], a != "next" { throw AnimParseError("arrive= only takes next") }
            if let id = opts["as"] { _ = try checkedName(id) }
            return .send(from: rest[0], to: rest[2], label: rest[3], id: opts["as"], lost: lost, tone: tone, arriveNext: opts["arrive"] == "next")
        case "slide":
            guard rest.count == 2 else { throw AnimParseError("usage: slide SEQ to=N | by=N") }
            let opts = try options([rest[1]], allowed: ["to", "by"])
            if let v = opts["to"] {
                guard let n = Int(v) else { throw AnimParseError("to= takes a number") }
                return .slide(rest[0], to: n, by: nil)
            }
            guard let v = opts["by"], let n = Int(v) else { throw AnimParseError("by= takes a number") }
            return .slide(rest[0], to: nil, by: n)
        case "timer":
            guard rest.count == 3, let op = AnimTimerOp(rawValue: rest[2].lowercased()) else {
                throw AnimParseError("usage: timer LANE \"T0\" start|stop|expire")
            }
            return .timer(lane: rest[0], label: rest[1], op: op)
        case "deliver", "discard", "buffer", "note":
            guard rest.count >= 2 else { throw AnimParseError("usage: \(keyword) LANE \"label\"" + (keyword == "note" ? " [state=…]" : "")) }
            var tone: AnimTone?
            if rest.count > 2 {
                let opts = try options(Array(rest.dropFirst(2)), allowed: ["state"])
                if let s = opts["state"] {
                    guard let t = AnimTone(rawValue: s.lowercased()) else { throw AnimParseError("unknown state “\(s)”: \(toneList)") }
                    tone = t
                }
            }
            return .laneEvent(lane: rest[0], label: rest[1], kind: AnimLaneEventKind(rawValue: keyword)!, tone: tone)
        default:
            throw AnimParseError("unknown action “\(keyword)” (mark, unmark, set, swap, push, pop, enqueue, dequeue, say, send, slide, timer, deliver, discard, buffer, note)")
        }
    }

    private static let toneList = "normal, active, done, wrong, muted, new"

    // MARK: 词法

    /// 按空白切词；双引号里的是一个词（去掉引号）；引号外的 `#` 起是注释；`->` `=` `[` … `]` 的写法见各处。
    /// `A->B` 不加空格也行：引号外的 `->` 先补成独立的词。`key=value` 保持一个词。
    static func tokenize(_ line: String) throws -> [String] {
        var tokens: [String] = []
        var current = ""
        var inQuote = false
        var quoted = false
        var chars = Array(line)
        var i = 0
        func flush() {
            if !current.isEmpty || quoted { tokens.append(current) }
            current = ""
            quoted = false
        }
        while i < chars.count {
            let c = chars[i]
            if inQuote {
                if c == "\"" { inQuote = false } else { current.append(c) }
            } else if c == "\"" {
                inQuote = true
                quoted = true
            } else if c == "#" && current.isEmpty && !quoted {
                break
            } else if c.isWhitespace {
                flush()
            } else if c == "-" && i + 1 < chars.count && chars[i + 1] == ">" {
                flush()
                tokens.append("->")
                i += 1
            } else if c == "=" && current.isEmpty && !quoted {
                tokens.append("=")
            } else if c == "|" && current.isEmpty {
                tokens.append("|")
            } else {
                current.append(c)
            }
            i += 1
        }
        if inQuote { throw AnimParseError("unclosed quote") }
        flush()
        chars.removeAll()
        return tokens
    }

    private static func options(_ words: [String], allowed: Set<String>) throws -> [String: String] {
        var out: [String: String] = [:]
        for word in words {
            guard let eq = word.firstIndex(of: "="), eq != word.startIndex else { throw AnimParseError("unexpected “\(word)”") }
            let key = String(word[..<eq]).lowercased(), value = String(word[word.index(after: eq)...])
            guard allowed.contains(key) else { throw AnimParseError("unknown option “\(key)=” (allowed: \(allowed.sorted().joined(separator: ", ")))") }
            guard !value.isEmpty else { throw AnimParseError("\(key)= needs a value") }
            out[key] = value
        }
        return out
    }

    static func parseRange(_ s: String) -> (Int, Int)? {
        let parts = s.components(separatedBy: "..")
        if parts.count == 1, let v = Int(parts[0]) { return (v, v) }
        guard parts.count == 2, let a = Int(parts[0]), let b = Int(parts[1]) else { return nil }
        return (a, b)
    }

    static func parseTarget(_ s: String) throws -> AnimTarget {
        guard let open = s.firstIndex(of: "[") else { return AnimTarget(name: try checkedName(s), lower: nil, upper: nil) }
        guard s.hasSuffix("]"), open != s.startIndex else { throw AnimParseError("bad target “\(s)” (use A, A[2] or A[1..3])") }
        let name = String(s[..<open])
        let inner = String(s[s.index(after: open)..<s.index(before: s.endIndex)])
        guard let (lo, hi) = parseRange(inner), hi >= lo else { throw AnimParseError("bad index in “\(s)” (use A[2] or A[1..3])") }
        return AnimTarget(name: try checkedName(name), lower: lo, upper: hi)
    }

    /// `[a, b, "c d"]`：逗号分隔，项两边空白去掉；项里的双引号去掉。
    static func parseList(_ s: String) throws -> [String] {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard t.hasPrefix("["), t.hasSuffix("]") else { throw AnimParseError("a list looks like [a, b, c]") }
        let inner = t.dropFirst().dropLast().trimmingCharacters(in: .whitespaces)
        if inner.isEmpty { return [] }
        return inner.components(separatedBy: ",").map {
            $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        }
    }

    private static func checkedName(_ s: String) throws -> String {
        guard !s.isEmpty, !s.contains(where: { "[]=\"#|".contains($0) || $0.isWhitespace }), s != "->" else {
            throw AnimParseError("bad name “\(s)”")
        }
        return s
    }
}

private extension AnimTarget {
    var isRangeSpan: Bool { lower != upper }
}

struct AnimParseError: Error {
    let message: String
    init(_ message: String) { self.message = message }
}
