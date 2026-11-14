import Foundation

// 套件（A3，`ANIM-BLOCK-PLAN.md §3.6`）：一行 `kit 名字 参数…` 由引擎推演出整套步骤，结果按算法算出来、保证正确。
// 做法：解析前把 kit 行展开成普通的 anim 文字（`expand`），之后的执行 / 布局 / 绘制照旧；展开出来的行都记在 kit 那一行上（报错时行号指它）。
// 只依赖 Foundation。

enum AnimKits {
    static let names = ["stopwait", "gbn", "sr", "bubble", "selection", "insertion", "quick", "crc",
                        "preorder", "inorder", "postorder", "levelorder", "bfs", "dfs", "dijkstra"]

    struct Kit {
        var title: String
        var lines: [String]
    }

    /// 展开整块文字里的 kit 行。返回展开后的文字、展开后每一行对应原文第几行（1 起）、kit 本身的错误。
    static func expand(_ source: String) -> (text: String, lineMap: [Int], errors: [AnimDiagnostic]) {
        let lines = source.components(separatedBy: "\n")
        guard lines.contains(where: { isKitLine($0) }) else { return (source, Array(1...max(lines.count, 1)), []) }
        var out: [String] = [], map: [Int] = [], errors: [AnimDiagnostic] = []
        var hasTitle = false, inScene = false
        for (i, raw) in lines.enumerated() {
            let lineNo = i + 1
            let head = (try? AnimText.tokenize(raw))?.first?.lowercased()
            if head == "title" { hasTitle = true }
            if head == "scene" { inScene = true }
            guard head == "kit" else {
                out.append(raw); map.append(lineNo)
                continue
            }
            do {
                let kit = try generate(String(raw.trimmingCharacters(in: .whitespaces).dropFirst(3)))
                if !hasTitle && !inScene {
                    out.append("title " + kit.title); map.append(lineNo)
                    hasTitle = true
                }
                for l in kit.lines { out.append(l); map.append(lineNo) }
            } catch let e as AnimParseError {
                errors.append(AnimDiagnostic(line: lineNo, message: "kit: " + e.message))
            } catch {}
        }
        return (out.joined(separator: "\n"), map, errors)
    }

    private static func isKitLine(_ s: String) -> Bool {
        s.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("kit ")
    }

    // MARK: - 参数

    struct Args {
        var values: [String: String] = [:]
        var used = Set<String>()

        mutating func string(_ k: String) -> String? { used.insert(k); return values[k] }

        mutating func int(_ k: String, default d: Int, _ range: ClosedRange<Int>) throws -> Int {
            guard let s = string(k) else { return d }
            guard let v = Int(s), range.contains(v) else { throw AnimParseError("\(k)= takes a whole number in \(range.lowerBound)…\(range.upperBound)") }
            return v
        }

        mutating func ints(_ k: String) throws -> Set<Int> {
            guard let s = string(k) else { return [] }
            var out = Set<Int>()
            for part in s.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).components(separatedBy: ",") where !part.trimmingCharacters(in: .whitespaces).isEmpty {
                guard let v = Int(part.trimmingCharacters(in: .whitespaces)) else { throw AnimParseError("\(k)= takes numbers like 2 or 2,5") }
                out.insert(v)
            }
            return out
        }

        func checkUnused(_ allowed: [String]) throws {
            for k in values.keys where !used.contains(k) && k != "lang" {
                throw AnimParseError("unknown option “\(k)=” (allowed: \(allowed.joined(separator: ", ")))")
            }
        }
    }

    /// `名字 k=v k=[…] k=(…) k="…"`：值可以带括号（里面有空格也行）或双引号。
    static func parseArgs(_ s: String) throws -> (String, Args) {
        var chars = Array(s.trimmingCharacters(in: .whitespaces))
        // 去掉引号外的注释
        var inQuote = false
        for (i, c) in chars.enumerated() {
            if c == "\"" { inQuote.toggle() }
            if c == "#" && !inQuote { chars = Array(chars[..<i]); break }
        }
        var i = 0
        func skipSpace() { while i < chars.count, chars[i].isWhitespace { i += 1 } }
        func word() -> String {
            var w = ""
            while i < chars.count, !chars[i].isWhitespace, chars[i] != "=" { w.append(chars[i]); i += 1 }
            return w
        }
        skipSpace()
        let name = word().lowercased()
        guard !name.isEmpty else { throw AnimParseError("usage: kit NAME options… (\((names + names2).joined(separator: ", ")))") }
        var args = Args()
        while true {
            skipSpace()
            guard i < chars.count else { break }
            let key = word().lowercased()
            guard i < chars.count, chars[i] == "=", !key.isEmpty else { throw AnimParseError("options look like key=value (got “\(key)”)") }
            i += 1
            var value = ""
            if i < chars.count, chars[i] == "\"" {
                i += 1
                while i < chars.count, chars[i] != "\"" { value.append(chars[i]); i += 1 }
                guard i < chars.count else { throw AnimParseError("unclosed quote") }
                i += 1
            } else if i < chars.count, chars[i] == "[" || chars[i] == "(" {
                let open = chars[i], close: Character = open == "[" ? "]" : ")"
                var depth = 0
                while i < chars.count {
                    let c = chars[i]
                    value.append(c)
                    i += 1
                    if c == open { depth += 1 }
                    if c == close { depth -= 1; if depth == 0 { break } }
                }
                guard depth == 0 else { throw AnimParseError("unbalanced \(open) in \(key)=") }
            } else {
                while i < chars.count, !chars[i].isWhitespace { value.append(chars[i]); i += 1 }
            }
            args.values[key] = value
        }
        return (name, args)
    }

    static func generate(_ text: String) throws -> Kit {
        var (name, args) = try parseArgs(text)
        let zh: Bool
        switch args.values["lang"]?.lowercased() {
        case "zh"?: zh = true
        case "en"?: zh = false
        case nil: zh = Locale.preferredLanguages.first?.hasPrefix("zh") ?? false
        case let other?: throw AnimParseError("lang= takes zh or en, not \(other)")
        }
        let L = Words(zh: zh)
        switch name {
        case "stopwait", "gbn", "sr": return try protocolKit(name, &args, L)
        case "bubble", "selection", "insertion", "quick": return try sortKit(name, &args, L)
        case "crc": return try crcKit(&args, L)
        case "preorder", "inorder", "postorder", "levelorder": return try traverseKit(name, &args, L)
        case "bfs", "dfs": return try searchKit(name, &args, L)
        case "dijkstra": return try dijkstraKit(&args, L)
        default:
            if let kit = try generate2(name, &args, L) { return kit }
            throw AnimParseError("unknown kit “\(name)” (\((names + names2).joined(separator: ", ")))")
        }
    }

    // MARK: - 文字

    /// 套件生成的说明文字：中英两份。
    struct Words {
        let zh: Bool
        func t(_ z: String, _ e: String) -> String { zh ? z : e }
        var sep: String { zh ? "；" : "; " }
        var listSep: String { zh ? "、" : ", " }

        /// 连号写成 2~5，否则 2、4、7。
        func list(_ xs: [Int], _ label: (Int) -> String = { "\($0)" }) -> String {
            guard xs.count > 2, zip(xs, xs.dropFirst()).allSatisfy({ $1 == $0 + 1 }) else { return xs.map(label).joined(separator: listSep) }
            return label(xs.first!) + "~" + label(xs.last!)
        }
    }

    static func q(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\"", with: "'") + "\"" }

    private static func step(_ caption: String, _ actions: [String]) -> [String] {
        ["step " + caption.replacingOccurrences(of: "#", with: "＃")] + actions.map { "  " + $0 }
    }

    // MARK: - 可靠传输：停等 / 回退 N 步 / 选择重传

    /// 按「轮」推演：每轮先是发送方（收 ACK、滑窗口、超时重发、发新帧），再是接收方（收帧、交付 / 丢弃 / 缓存、回 ACK）。
    /// 一帧发出后 `timeout` 轮还没被确认就超时。`lose` 里的帧第一次发送丢失，`loseack` 里的 ACK 第一次丢失（重传的都不丢）。
    private static func protocolKit(_ kind: String, _ a: inout Args, _ L: Words) throws -> Kit {
        let n = try a.int("frames", default: kind == "stopwait" ? 3 : 6, 1...12)
        let w = kind == "stopwait" ? 1 : try a.int("window", default: 4, 1...8)
        var mod: Int?
        if a.values["mod"] != nil { mod = try a.int("mod", default: 8, 2...16) }
        if let m = mod {
            if kind == "gbn", w > m - 1 { throw AnimParseError("go-back-N needs window ≤ mod − 1 (\(m - 1))") }
            if kind == "sr", w > m / 2 { throw AnimParseError("selective repeat needs window ≤ mod / 2 (\(m / 2))") }
            if kind == "stopwait", m < 2 { throw AnimParseError("mod must be at least 2") }
        }
        var lose = try a.ints("lose"), loseAck = try a.ints("loseack")
        let timeout = try a.int("timeout", default: kind == "stopwait" ? 1 : 2, 1...4)
        try a.checkUnused(["frames", "window", "lose", "loseack", "timeout", "mod", "lang"])
        for f in lose.union(loseAck) where f >= n { throw AnimParseError("frame \(f) does not exist (frames=\(n): 0…\(n - 1))") }

        let S = L.t("发送方", "Sender"), R = L.t("接收方", "Receiver")
        let expectedName = L.t("期望", "expected")
        func lbl(_ f: Int) -> String { String(mod.map { f % $0 } ?? f) }
        let modOpt = mod.map { " mod=\($0)" } ?? ""

        var lines = ["lanes \(S) \(R)", "seq SW 0..\(n - 1) window=\(w) at=\(S)\(modOpt)"]
        if kind == "sr" { lines.append("seq RW 0..\(n - 1) window=\(w) at=\(R)\(modOpt)") } else { lines.append("var \(expectedName) = 0") }

        var base = 0, next = 0, round = 0
        var sentRound: [Int: Int] = [:]
        var ackedSR = Set<Int>()
        var expected = 0, rcvBase = 0
        var received = Set<Int>()
        var inflight: [(f: Int, lost: Bool)] = []
        var acksInflight: [(n: Int, lost: Bool)] = []
        var running = Set<String>()
        var gbnTimer: String?

        while round < 40 {
            // —— 发送方 ——
            var acts: [String] = [], caps: [String] = []
            let oldBase = base
            let got = acksInflight.filter { !$0.lost }.map(\.n)
            for ackN in got {
                if kind == "sr" {
                    ackedSR.insert(ackN)
                    if running.remove("T\(ackN)") != nil { acts.append("timer \(S) \(q("T" + lbl(ackN))) stop") }
                } else {
                    base = max(base, ackN + 1)
                }
            }
            if kind == "sr" {
                for f in got { acts.append("mark SW[\(f)] done") }
                while ackedSR.contains(base) { base += 1 }
            }
            acksInflight.removeAll()
            if !got.isEmpty { caps.append(L.t("收到 ", "got ") + got.map { "ACK " + lbl($0) }.joined(separator: L.listSep)) }
            if base != oldBase {
                if kind != "sr" { acts.append("mark SW[\(oldBase)..\(base - 1)] done") }
                if kind == "stopwait", running.remove("T\(oldBase)") != nil { acts.append("timer \(S) \(q("T" + lbl(oldBase))) stop") }
                if kind == "gbn", let t = gbnTimer {
                    acts.append("timer \(S) \(q(t)) stop")
                    running.remove(t)
                    gbnTimer = nil
                    // 还有没确认的帧：计时器从新的窗口起点重新计
                    if base < next {
                        let nt = "T" + lbl(base)
                        acts.append("timer \(S) \(q(nt)) start")
                        running.insert(nt)
                        gbnTimer = nt
                    }
                }
                if base < n {
                    acts.append("slide SW to=\(base)")
                    caps.append(L.t("窗口滑到 ", "window slides to ") + (w == 1 ? lbl(base) : lbl(base) + "~" + lbl(min(base + w, n) - 1)))
                } else {
                    caps.append(L.t("全部帧已确认", "every frame is acknowledged"))
                }
            }
            // 超时
            let overdue = (base..<next).filter { !(kind == "sr" && ackedSR.contains($0)) && (sentRound[$0].map { $0 + timeout <= round } ?? false) }
            var toSend: [Int] = []
            if !overdue.isEmpty {
                if kind == "gbn" {
                    let t = gbnTimer ?? "T" + lbl(base)
                    acts.append("timer \(S) \(q(t)) expire")
                    running.remove(t)
                    gbnTimer = nil
                    toSend = Array(base..<next)
                    acts.append("mark SW[\(base)..\(next - 1)] active")
                    caps.append(L.t("帧 \(lbl(overdue[0])) 超时：从 \(lbl(base)) 起全部重发", "frame \(lbl(overdue[0])) times out: resend everything from \(lbl(base))"))
                } else {
                    for f in overdue {
                        acts.append("timer \(S) \(q("T" + lbl(f))) expire")
                        running.remove("T\(f)")
                        acts.append("mark SW[\(f)] active")
                    }
                    toSend = overdue
                    caps.append(L.t("帧 \(L.list(overdue, lbl)) 超时，只重发它", "frame \(L.list(overdue, lbl)) times out: resend only that")
                                + (overdue.count > 1 ? L.t("们", "") : ""))
                }
            }
            var fresh: [Int] = []
            while next < base + w && next < n {
                fresh.append(next)
                next += 1
            }
            if !fresh.isEmpty { caps.append(L.t("发出 ", "send ") + L.list(fresh, lbl)) }
            for f in toSend + fresh {
                let lost = lose.remove(f) != nil
                acts.append("send \(S) -> \(R) \(q(lbl(f)))" + (lost ? " lost" : ""))
                sentRound[f] = round
                inflight.append((f, lost))
                if kind == "gbn" {
                    if gbnTimer == nil {
                        let t = "T" + lbl(base)
                        acts.append("timer \(S) \(q(t)) start")
                        running.insert(t)
                        gbnTimer = t
                    }
                } else {
                    acts.append("timer \(S) \(q("T" + lbl(f))) start")
                    running.insert("T\(f)")
                }
            }
            if !acts.isEmpty { lines += step(caps.joined(separator: L.sep), acts) }

            // —— 接收方 ——
            var racts: [String] = [], rcaps: [String] = []
            var acks: [Int] = []
            var delivered: [Int] = [], discarded: [Int] = [], buffered: [Int] = [], duplicate: [Int] = []
            for (f, lost) in inflight where !lost {
                if kind == "sr" {
                    if f >= rcvBase && f < rcvBase + w {
                        if !received.contains(f) {
                            received.insert(f)
                            if f != rcvBase {
                                racts.append("buffer \(R) \(q(lbl(f)))")
                                racts.append("mark RW[\(f)] active")
                                buffered.append(f)
                            }
                        } else {
                            duplicate.append(f)
                            racts.append("note \(R) \(q(L.t("重复 ", "dup ") + lbl(f))) state=muted")
                        }
                        var run: [Int] = []
                        while received.contains(rcvBase) { run.append(rcvBase); rcvBase += 1 }
                        if !run.isEmpty {
                            racts.append("deliver \(R) \(q(run.map(lbl).joined(separator: " ")))")
                            racts.append("unmark RW[\(run.first!)..\(run.last!)]")
                            if rcvBase < n { racts.append("slide RW to=\(rcvBase)") }
                            delivered += run
                        }
                    } else if f < rcvBase {
                        duplicate.append(f)
                        racts.append("note \(R) \(q(L.t("重复 ", "dup ") + lbl(f))) state=muted")
                    }
                    acks.append(f)
                } else {
                    if f == expected {
                        racts.append("deliver \(R) \(q(lbl(f)))")
                        delivered.append(f)
                        expected += 1
                        acks.append(f)
                    } else {
                        racts.append("discard \(R) \(q(lbl(f)))")
                        if f < expected { duplicate.append(f) } else { discarded.append(f) }
                        if expected > 0 { acks.append(expected - 1) }
                    }
                }
            }
            if kind != "sr", !delivered.isEmpty { racts.append("set \(expectedName) = \(lbl(expected))") }
            inflight.removeAll()
            for ackN in acks {
                let lost = loseAck.remove(ackN) != nil
                racts.append("send \(R) -> \(S) \(q("ACK " + lbl(ackN)))" + (lost ? " lost" : ""))
                acksInflight.append((ackN, lost))
            }
            if !delivered.isEmpty { rcaps.append(L.t("交付 ", "deliver ") + L.list(delivered, lbl)) }
            if !buffered.isEmpty { rcaps.append(L.t("缓存 ", "buffer ") + L.list(buffered, lbl)) }
            if !discarded.isEmpty { rcaps.append(L.t("\(L.list(discarded, lbl)) 失序，丢弃", "\(L.list(discarded, lbl)) out of order, discarded")) }
            if !duplicate.isEmpty { rcaps.append(L.t("\(L.list(duplicate, lbl)) 是重复帧", "\(L.list(duplicate, lbl)) is a duplicate")) }
            if !acks.isEmpty {
                rcaps.append(L.t("回 ", "reply ") + acks.map { "ACK " + lbl($0) }.joined(separator: L.listSep)
                             + (kind == "gbn" && Set(acks).count < acks.count ? L.t("（重复确认）", " (duplicate ACKs)") : ""))
            }
            if !racts.isEmpty { lines += step(L.t("接收方：", "Receiver: ") + rcaps.joined(separator: L.sep), racts) }

            round += 1
            if base >= n && acksInflight.isEmpty && inflight.isEmpty { break }
        }
        guard base >= n else { throw AnimParseError("did not finish in 40 rounds") }
        let title: String
        switch kind {
        case "stopwait": title = L.t("停等协议", "Stop-and-wait")
        case "gbn": title = L.t("回退 N 步（窗口 \(w)）", "Go-back-N (window \(w))")
        default: title = L.t("选择重传（窗口 \(w)）", "Selective repeat (window \(w))")
        }
        return Kit(title: title, lines: lines)
    }

    // MARK: - 排序

    private static func sortKit(_ kind: String, _ a: inout Args, _ L: Words) throws -> Kit {
        guard let raw = a.string("a") else { throw AnimParseError("usage: kit \(kind) A=[5, 1, 4, 2]") }
        try a.checkUnused(["A", "lang"])
        var v = try AnimText.parseList(raw)
        guard v.count >= 2, v.count <= 8 else { throw AnimParseError("sort 2 to 8 values") }
        let numeric = v.allSatisfy { Double($0) != nil }
        func gt(_ x: String, _ y: String) -> Bool { numeric ? Double(x)! > Double(y)! : x > y }
        let n = v.count
        var lines = ["array A = [\(v.joined(separator: ", "))]"]
        func swapIn(_ i: Int, _ j: Int) { v.swapAt(i, j) }
        let title: String

        switch kind {
        case "bubble":
            title = L.t("冒泡排序", "Bubble sort")
            lines.append("pointer j -> A[0]")
            var p = 0
            while p < n - 1 {
                var swapped = false
                for j in 0..<(n - 1 - p) {
                    var acts = j > 0 ? ["unmark A[\(j - 1)]"] : []
                    acts += ["mark A[\(j)..\(j + 1)] active", "move j -> A[\(j)]"]
                    let cap: String
                    if gt(v[j], v[j + 1]) {
                        cap = L.t("\(v[j]) > \(v[j + 1])，交换", "\(v[j]) > \(v[j + 1]): swap")
                        acts.append("swap A[\(j)] A[\(j + 1)]")
                        swapIn(j, j + 1)
                        swapped = true
                    } else {
                        cap = L.t("\(v[j]) ≤ \(v[j + 1])，不动", "\(v[j]) ≤ \(v[j + 1]): keep")
                    }
                    if j == n - 2 - p {
                        acts += ["unmark A[\(j)]", "mark A[\(j + 1)] done"]
                        lines += step(L.t("第 \(p + 1) 趟：", "Pass \(p + 1): ") + cap + L.sep + L.t("\(v[j + 1]) 到达最终位置", "\(v[j + 1]) is in place"), acts)
                    } else {
                        lines += step(L.t("第 \(p + 1) 趟：", "Pass \(p + 1): ") + cap, acts)
                    }
                }
                p += 1
                if !swapped {
                    lines += step(L.t("这一趟没有交换，已经有序", "No swaps in this pass: sorted"), ["mark A done", "move j -> null"])
                    break
                }
            }
            if p == n - 1 { lines += step(L.t("排序完成", "Sorted"), ["mark A done", "move j -> null"]) }

        case "selection":
            title = L.t("简单选择排序", "Selection sort")
            lines += ["pointer i -> A[0]", "pointer j", "pointer min -> A[0]"]
            for i in 0..<(n - 1) {
                var m = i
                lines += step(L.t("第 \(i + 1) 轮：从 A[\(i)] 起找最小值，先记 min = \(v[i])", "Round \(i + 1): find the minimum from A[\(i)]; min = \(v[i]) so far"),
                              ["move i -> A[\(i)]", "move min -> A[\(i)]", "mark A[\(i)] active"])
                for j in (i + 1)..<n {
                    var acts = ["move j -> A[\(j)]"]
                    let cap: String
                    if gt(v[m], v[j]) {
                        cap = L.t("\(v[j]) < \(v[m])，min 指向它", "\(v[j]) < \(v[m]): it becomes min")
                        acts += ["unmark A[\(m)]", "mark A[\(j)] active", "move min -> A[\(j)]"]
                        m = j
                    } else {
                        cap = L.t("\(v[j]) ≥ \(v[m])，min 不变", "\(v[j]) ≥ \(v[m]): min stays")
                    }
                    lines += step(cap, acts)
                }
                var acts = ["move j -> null", "unmark A[\(m)]"]
                if m != i { acts.append("swap A[\(i)] A[\(m)]"); swapIn(i, m) }
                acts += ["mark A[\(i)] done"]
                lines += step(m != i ? L.t("交换 A[\(i)] 和 A[\(m)]，\(v[i]) 就位", "swap A[\(i)] and A[\(m)]: \(v[i]) is in place")
                                     : L.t("最小值就在 A[\(i)]，不用交换", "the minimum is already at A[\(i)]"), acts)
            }
            lines += step(L.t("排序完成", "Sorted"), ["mark A done", "move i -> null", "move min -> null"])

        case "insertion":
            title = L.t("直接插入排序", "Insertion sort")
            lines += ["pointer key"]
            for i in 1..<n {
                let key = v[i]
                lines += step(L.t("取出 A[\(i)] = \(key)，往前找位置", "take A[\(i)] = \(key) and look for its place"),
                              ["move key -> A[\(i)]", "mark A[\(i)] active"])
                var j = i - 1
                while j >= 0 && gt(v[j], key) {
                    lines += step(L.t("\(v[j]) > \(key)，\(v[j]) 后移", "\(v[j]) > \(key): shift \(v[j]) right"),
                                  ["swap A[\(j)] A[\(j + 1)]", "move key -> A[\(j)]"])
                    swapIn(j, j + 1)
                    j -= 1
                }
                lines += step(j >= 0 ? L.t("\(v[j]) ≤ \(key)，\(key) 插在这里；前 \(i + 1) 个有序", "\(v[j]) ≤ \(key): \(key) goes here; the first \(i + 1) are sorted")
                                     : L.t("到头了，\(key) 放在最前；前 \(i + 1) 个有序", "reached the front: \(key) goes first; the first \(i + 1) are sorted"),
                              ["unmark A[\(j + 1)]"])
            }
            lines += step(L.t("排序完成", "Sorted"), ["mark A done", "move key -> null"])

        default:   // quick（Lomuto 划分：枢轴取最后一个）
            title = L.t("快速排序（枢轴取末尾）", "Quicksort (last element as pivot)")
            lines += ["pointer i", "pointer j"]
            var stack = [(0, n - 1)]
            while let (lo, hi) = stack.popLast() {
                if lo >= hi {
                    if lo == hi { lines += step(L.t("A[\(lo)] 只有一个元素，已就位", "A[\(lo)] alone: in place"), ["mark A[\(lo)] done"]) }
                    continue
                }
                let pivot = v[hi]
                var i = lo - 1
                lines += step(L.t("划分 A[\(lo)..\(hi)]，枢轴 = \(pivot)", "partition A[\(lo)..\(hi)] around pivot \(pivot)"),
                              ["mark A[\(hi)] active", "move i -> null", "move j -> A[\(lo)]"])
                for j in lo..<hi {
                    var acts = ["move j -> A[\(j)]"]
                    let cap: String
                    if gt(pivot, v[j]) {
                        i += 1
                        acts.append("move i -> A[\(i)]")
                        if i != j { acts.append("swap A[\(i)] A[\(j)]"); swapIn(i, j) }
                        cap = L.t("\(v[i]) < \(pivot)：i 前进\(i != j ? "，交换 A[\(i)] 和 A[\(j)]" : "")", "\(v[i]) < \(pivot): advance i\(i != j ? ", swap A[\(i)] and A[\(j)]" : "")")
                    } else {
                        cap = L.t("\(v[j]) ≥ \(pivot)：跳过", "\(v[j]) ≥ \(pivot): skip")
                    }
                    lines += step(cap, acts)
                }
                let p = i + 1
                var acts = ["move j -> null", "move i -> null"]
                if p != hi { acts.append("swap A[\(p)] A[\(hi)]"); swapIn(p, hi) }
                acts.append("mark A[\(p)] done")
                lines += step(L.t("枢轴 \(pivot) 放到 A[\(p)]，左边都比它小、右边都不小", "pivot \(pivot) goes to A[\(p)]: smaller on the left, the rest on the right"), acts)
                stack.append((p + 1, hi))
                stack.append((lo, p - 1))
            }
            lines += step(L.t("排序完成", "Sorted"), ["mark A done"])
        }
        return Kit(title: title, lines: lines)
    }

    // MARK: - CRC（竖式模 2 除，排法同教材）

    /// 左边是除数、`)`、被除数（上方一条横线），商写在最上一行、对齐窗口的最后一位；
    /// 每一步写两行：减数（首位 1 写除数、首位 0 写全 0）+ 横线、异或结果，下一位用虚线箭头从被除数那行落下来。
    private static func crcKit(_ a: inout Args, _ L: Words) throws -> Kit {
        guard let data = a.string("data"), let gen = a.string("gen") else { throw AnimParseError("usage: kit crc data=101001 gen=1101") }
        try a.checkUnused(["data", "gen", "lang"])
        guard !data.isEmpty, data.allSatisfy({ $0 == "0" || $0 == "1" }), data.count <= 16 else { throw AnimParseError("data= is 1 to 16 bits of 0 / 1") }
        guard gen.count >= 2, gen.count <= 8, gen.allSatisfy({ $0 == "0" || $0 == "1" }), gen.first == "1" else {
            throw AnimParseError("gen= is 2 to 8 bits starting with 1 (the generator polynomial)")
        }
        let n = data.count, r = gen.count - 1
        let g = gen.map { $0 == "1" ? 1 : 0 }
        var m = data.map { $0 == "1" ? 1 : 0 } + Array(repeating: 0, count: r)
        let S = L.t("竖式", "work")
        let d0 = r + 2                                  // 被除数从第几列起
        let zeros = String(repeating: "0", count: r)
        func bits(_ xs: ArraySlice<Int>) -> String { xs.map(String.init).joined() }
        var lines = [
            "sheet \(S)",
            "write \(S)[1,0] \(q(gen))",
            "write \(S)[1,\(r + 1)] \")\"",
            "write \(S)[1,\(d0)] \(q(data + zeros))",
            "rule \(S)[1,\(d0)..\(d0 + n + r - 1)] above",
            "mark \(S)[1,\(d0 + n)..\(d0 + n + r - 1)] new",
            "label \(S)[0] \(q(L.t("← 商 Q", "← quotient Q")))",
            "label \(S)[1] \(q(L.t("← 被除数：M 后补 \(r) 个 0", "← dividend: M followed by \(r) zeros")))",
            "text \(q(L.t("除数 \(gen) 写在左边，从被除数最高位起，每次对齐除数做一次模 2 减（异或）", "Divisor \(gen) on the left; from the leftmost bit, align it and subtract modulo 2 (XOR) each time")))",
        ]
        // 讲原理的两步：r 从哪来、为什么补 r 个 0
        let poly = polynomial(gen)
        lines += step(L.t("G = \(gen) 对应多项式 \(poly)，最高次幂是 \(r)，所以 r = \(r)：校验码 R 有 \(r) 位（= G 的位数 \(gen.count) − 1）",
                          "G = \(gen) is the polynomial \(poly); its highest power is \(r), so r = \(r): the check bits R are \(r) bits (= \(gen.count) bits of G − 1)"),
                      ["mark \(S)[1,0..\(r)] active",
                       "say " + q(L.t("从左到右每一位对应 x 的 \(r) 次、\(r - 1) 次……0 次，是 1 的位就有这一项", "From left to right the bits stand for the powers \(r), \(r - 1), …, 0 of x; a 1 means that term is present"))])
        let twoR = "2" + String(String(r).map { Self.superscript[$0]! })
        lines += step(L.t("在 M = \(data) 后补 r = \(r) 个 0（相当于 M × \(twoR)），得到被除数 \(data + zeros)", "append r = \(r) zeros to M = \(data) (that is M × \(twoR)): the dividend is \(data + zeros)"),
                      ["unmark \(S)[1,0..\(r)]", "mark \(S)[1,\(d0 + n)..\(d0 + n + r - 1)] active",
                       "say " + q(L.t("补出来的 \(r) 位留给余数：最后把余数填进这 \(r) 位，整个帧就能被 G 整除", "The \(r) new bits are room for the remainder: filling them with it makes the whole frame divisible by G"))])
        var prevWindow: (row: Int, col: Int)?
        var firstStep = true
        for k in 0..<n {
            let windowRow = k == 0 ? 1 : 1 + 2 * k
            let col = d0 + k
            let window = bits(m[k...(k + r)])
            let qbit = m[k]
            var acts: [String] = []
            if firstStep {
                acts.append("unmark \(S)[1,\(d0 + n)..\(d0 + n + r - 1)]")
                firstStep = false
            } else if let p = prevWindow {
                acts.append("unmark \(S)[\(p.row),\(p.col)..\(p.col + r)]")
            }
            acts.append("mark \(S)[\(windowRow),\(col)..\(col + r)] active")
            acts.append("write \(S)[0,\(col + r)] \(q(String(qbit)))")
            acts.append("write \(S)[\(2 + 2 * k),\(col)] \(q(qbit == 1 ? gen : "0" + zeros))")
            acts.append("rule \(S)[\(2 + 2 * k),\(col)..\(col + r)]")
            let sub = qbit == 1 ? g : Array(repeating: 0, count: r + 1)
            let before = Array(m[k...(k + r)])
            if qbit == 1 { for i in 0...r { m[k + i] ^= g[i] } }
            let after = bits(m[k...(k + r)])
            acts.append("write \(S)[\(3 + 2 * k),\(col + 1)] \(q(String(after.dropFirst())))")
            // 逐位异或：每个数字是怎么来的
            let perBit = zip(before, sub).map { "\($0)⊕\($1)=\($0 ^ $1)" }.joined(separator: "  ")
            acts.append("say " + q(L.t("逐位异或（相同得 0、不同得 1）：", "bit by bit (same → 0, different → 1): ") + perBit
                                   + L.t("。首位一定变成 0，所以去掉它，只留后 \(r) 位", ". The leading bit always becomes 0, so drop it and keep the last \(r)")))
            var cap = qbit == 1
                ? L.t("取 \(r + 1) 位 \(window)，首位是 1，够除：商上 1，减（异或）\(gen)，得 \(after)",
                      "take \(r + 1) bits \(window): leading 1, so G fits: quotient bit 1, subtract (XOR) \(gen) → \(after)")
                : L.t("取 \(r + 1) 位 \(window)，首位是 0，不够除：商上 0，减（异或）\("0" + zeros)，不变",
                      "take \(r + 1) bits \(window): leading 0, so G does not fit: quotient bit 0, XOR \("0" + zeros) changes nothing")
            if k < n - 1 {
                let down = m[k + r + 1]
                acts.append("arrow \(S)[1..\(3 + 2 * k),\(col + r + 1)]")
                acts.append("write \(S)[\(3 + 2 * k),\(col + r + 1)] \(q(String(down)))")
                cap += L.t("；落下被除数的下一位 \(down)，凑够 \(r + 1) 位", "; bring down the next dividend bit \(down) to make \(r + 1) bits again")
            }
            lines += step(L.t("第 \(k + 1) 次：", "Step \(k + 1): ") + cap, acts)
            prevWindow = (windowRow, col)
        }
        let rem = bits(m[n...])
        let remRow = 3 + 2 * (n - 1)
        lines += step(L.t("被除数的每一位都用完了，最后剩下的 \(r) 位就是余数 R = \(rem)（不足 \(r) 位也要补齐）；把它接在 M 后面，发送 \(data)\(rem)",
                          "every dividend bit is used: the last \(r) bits are the remainder R = \(rem) (always keep \(r) bits); append it to M and send \(data)\(rem)"),
                      ["unmark \(S)[\(prevWindow!.row),\(prevWindow!.col)..\(prevWindow!.col + r)]",
                       "mark \(S)[\(remRow),\(d0 + n)..\(d0 + n + r - 1)] done",
                       "label \(S)[\(remRow)] \(q(L.t("← 余数 R，作为 FCS", "← remainder R, the FCS")))",
                       "say " + q(L.t("接收方用收到的整个帧除以 \(gen)，余数为 0 就认为没有出错", "The receiver divides the whole frame by \(gen); remainder 0 means no error detected"))])
        return Kit(title: L.t("CRC 循环冗余检验", "CRC") + "：\(data) / \(gen)", lines: lines)
    }

    static let superscript: [Character: Character] = ["0": "⁰", "1": "¹", "2": "²", "3": "³", "4": "⁴", "5": "⁵", "6": "⁶", "7": "⁷", "8": "⁸", "9": "⁹"]

    /// 1101 → x³ + x² + 1。
    static func polynomial(_ gen: String) -> String {
        let sup = superscript
        let terms = gen.enumerated().compactMap { i, c -> String? in
            guard c == "1" else { return nil }
            let p = gen.count - 1 - i
            return p == 0 ? "1" : p == 1 ? "x" : "x" + String(String(p).map { sup[$0]! })
        }
        return terms.joined(separator: " + ")
    }

    // MARK: - 树的遍历

    private static func traverseKit(_ kind: String, _ a: inout Args, _ L: Words) throws -> Kit {
        guard let raw = a.string("t") else { throw AnimParseError("usage: kit \(kind) T=(8 (3 1 6) (10 _ 14))") }
        try a.checkUnused(["T", "lang"])
        guard let tree = try AnimText.parseTree(raw) else { throw AnimParseError("the tree is empty") }
        var values: [String] = []
        func collect(_ d: AnimTreeDecl?) {
            guard case .node(let v, let c)? = d else { return }
            values.append(v); c.forEach(collect)
        }
        collect(tree)
        guard Set(values).count == values.count else { throw AnimParseError("node values must be different (nodes are found by value)") }
        var order: [String] = []
        func visit(_ d: AnimTreeDecl?) throws {
            guard case .node(let v, let c)? = d else { return }
            switch kind {
            case "preorder": order.append(v); for x in c { try visit(x) }
            case "postorder": for x in c { try visit(x) }; order.append(v)
            default:
                guard c.count <= 2 else { throw AnimParseError("in-order needs a binary tree") }
                try visit(c.first ?? nil); order.append(v); try visit(c.count > 1 ? c[1] : nil)
            }
        }
        if kind == "levelorder" {
            var queue: [AnimTreeDecl] = [tree]
            while !queue.isEmpty {
                guard case .node(let v, let c) = queue.removeFirst() else { continue }
                order.append(v)
                queue += c.compactMap { $0 }
            }
        } else {
            try visit(tree)
        }
        let out = L.t("序列", "output")
        var lines = ["tree T = \(raw)", "queue \(out) = []", "pointer p"]
        let rule: String
        switch kind {
        case "preorder": rule = L.t("先序：根、左、右", "pre-order: root, left, right")
        case "inorder": rule = L.t("中序：左、根、右", "in-order: left, root, right")
        case "postorder": rule = L.t("后序：左、右、根", "post-order: left, right, root")
        default: rule = L.t("层序：一层一层从左到右", "level order: level by level, left to right")
        }
        var prev: String?
        for (k, v) in order.enumerated() {
            var acts = ["move p -> T[\(v)]", "mark T[\(v)] active", "enqueue \(out) \(v)"]
            if let p = prev { acts.insert("mark T[\(p)] done", at: 0) }
            lines += step(k == 0 ? rule + L.sep + L.t("访问 \(v)", "visit \(v)") : L.t("访问 \(v)", "visit \(v)"), acts)
            prev = v
        }
        lines += step(L.t("遍历结束：", "Done: ") + order.joined(separator: " "), ["mark T[\(prev!)] done", "move p -> null"])
        let title: String
        switch kind {
        case "preorder": title = L.t("先序遍历", "Pre-order traversal")
        case "inorder": title = L.t("中序遍历", "In-order traversal")
        case "postorder": title = L.t("后序遍历", "Post-order traversal")
        default: title = L.t("层序遍历", "Level-order traversal")
        }
        return Kit(title: title, lines: lines)
    }

    // MARK: - 图：BFS / DFS / Dijkstra

    private static func graphArg(_ a: inout Args, kind: String) throws -> (spec: String, nodes: [String], edges: [AnimGraphEdgeDecl], from: String) {
        guard let spec = a.string("g") else { throw AnimParseError("usage: kit \(kind) G=\"A-B, A-C, B-D\" from=A") }
        let (nodes, edges) = try AnimText.parseGraph(spec)
        guard nodes.count <= 16 else { throw AnimParseError("graph: at most 16 nodes") }
        let from = a.string("from") ?? nodes[0]
        guard nodes.contains(from) else { throw AnimParseError("from=\(from): no such node") }
        return (spec, nodes, edges, from)
    }

    /// 邻居：按边的声明顺序；无向边两头都算，有向边只算出边。
    private static func neighbors(_ u: String, _ edges: [AnimGraphEdgeDecl]) -> [(v: String, key: String, w: String?)] {
        edges.compactMap { e in
            if e.a == u { return (e.b, e.directed ? "\(e.a)->\(e.b)" : "\(e.a)-\(e.b)", e.weight) }
            if e.b == u && !e.directed { return (e.a, "\(e.a)-\(e.b)", e.weight) }
            return nil
        }
    }

    private static func searchKit(_ kind: String, _ a: inout Args, _ L: Words) throws -> Kit {
        let g = try graphArg(&a, kind: kind)
        try a.checkUnused(["G", "from", "lang"])
        let out = L.t("访问序列", "order")
        var lines = ["graph G = \(g.spec)", "queue \(out) = []"]
        if kind == "bfs" {
            lines.append("queue Q = []")
            var seen: Set<String> = [g.from], queue = [g.from], order: [String] = []
            lines += step(L.t("从 \(g.from) 出发：\(g.from) 入队", "start at \(g.from): enqueue it"), ["mark G[\(g.from)] active", "enqueue Q \(g.from)"])
            while !queue.isEmpty {
                let u = queue.removeFirst()
                order.append(u)
                var acts = ["dequeue Q", "mark G[\(u)] done", "enqueue \(out) \(u)"]
                var added: [String] = []
                for (v, key, _) in neighbors(u, g.edges) where !seen.contains(v) {
                    seen.insert(v); queue.append(v); added.append(v)
                    acts += ["mark G[\(key)] active", "mark G[\(v)] active", "enqueue Q \(v)"]
                }
                lines += step(L.t("\(u) 出队并访问", "dequeue and visit \(u)") + L.sep
                              + (added.isEmpty ? L.t("没有新的邻居", "no new neighbors") : L.t("邻居 \(added.joined(separator: L.listSep)) 入队", "enqueue neighbors \(added.joined(separator: L.listSep))")), acts)
            }
            lines += step(L.t("队列空了，遍历结束：", "queue empty, done: ") + order.joined(separator: " "), [])
            return Kit(title: L.t("广度优先搜索（从 \(g.from) 出发）", "Breadth-first search from \(g.from)"), lines: lines)
        }
        lines.append("stack S = []")
        var visited = Set<String>(), order: [String] = []
        func dfs(_ u: String, via key: String?) {
            visited.insert(u)
            order.append(u)
            var acts = ["push S \(u)", "mark G[\(u)] active", "enqueue \(out) \(u)"]
            if let key { acts.insert("mark G[\(key)] active", at: 0) }
            lines += step(L.t("访问 \(u)", "visit \(u)"), acts)
            for (v, k, _) in neighbors(u, g.edges) where !visited.contains(v) { dfs(v, via: k) }
            lines += step(L.t("\(u) 的邻居都访问过了，回退", "all neighbors of \(u) visited: back up"), ["pop S", "mark G[\(u)] done"])
        }
        dfs(g.from, via: nil)
        lines += step(L.t("遍历结束：", "done: ") + order.joined(separator: " "), [])
        return Kit(title: L.t("深度优先搜索（从 \(g.from) 出发）", "Depth-first search from \(g.from)"), lines: lines)
    }

    private static func dijkstraKit(_ a: inout Args, _ L: Words) throws -> Kit {
        let g = try graphArg(&a, kind: "dijkstra")
        try a.checkUnused(["G", "from", "lang"])
        for e in g.edges {
            guard let w = e.weight, let x = Double(w), x >= 0 else { throw AnimParseError("every edge needs a weight ≥ 0, like A-B:4 (\(e.a)-\(e.b))") }
        }
        func fmt(_ x: Double) -> String { x == x.rounded() ? String(Int(x)) : String(x) }
        var dist: [String: Double] = [g.from: 0], prev: [String: String] = [:], done = Set<String>()
        var lines = ["graph G = \(g.spec)"]
        var acts = g.nodes.map { "set G[\($0)] = " + q($0 == g.from ? "0" : "∞") }
        acts.append("mark G[\(g.from)] active")
        lines += step(L.t("起点 \(g.from) 的距离为 0，其余为 ∞", "distance 0 at \(g.from), ∞ elsewhere"), acts)
        while true {
            guard let u = g.nodes.filter({ !done.contains($0) && dist[$0] != nil }).min(by: { dist[$0]! < dist[$1]! }) else { break }
            done.insert(u)
            var sel = ["mark G[\(u)] done"]
            if let pk = prev[u] { sel.append("mark G[\(pk)] done") }
            lines += step(L.t("未确定的点里 \(u) 最近（\(fmt(dist[u]!))），确定它", "\(u) is the closest unfinished node (\(fmt(dist[u]!))): finalize it"), sel)
            var relax: [String] = [], caps: [String] = []
            for (v, key, w) in neighbors(u, g.edges) where !done.contains(v) {
                let nd = dist[u]! + Double(w!)!
                if dist[v] == nil || nd < dist[v]! {
                    if let old = prev[v] { relax.append("unmark G[\(old)]") }
                    caps.append("\(v)：\(dist[v].map(fmt) ?? "∞") → \(fmt(nd))")
                    dist[v] = nd
                    prev[v] = key
                    relax += ["mark G[\(key)] active", "set G[\(v)] = " + q(fmt(nd)), "mark G[\(v)] active"]
                }
            }
            if !relax.isEmpty {
                lines += step(L.t("经 \(u) 更新：", "relax through \(u): ") + caps.joined(separator: L.listSep), relax)
            }
        }
        let unreachable = g.nodes.filter { dist[$0] == nil }
        lines += step(L.t("全部确定。", "all finalized. ") + (unreachable.isEmpty ? "" : L.t("\(unreachable.joined(separator: L.listSep)) 不可达", "unreachable: \(unreachable.joined(separator: ", "))")),
                      [])
        return Kit(title: L.t("Dijkstra 最短路径（从 \(g.from) 出发）", "Dijkstra shortest paths from \(g.from)"), lines: lines)
    }
}
