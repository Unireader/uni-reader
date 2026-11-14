import Foundation

// 套件第二批（2026-11-14，`ANIM-BLOCK-PLAN.md §12`）：408 四门课常考的推演题。
// 操作系统：页面置换 page、磁盘调度 disk；组成原理：Cache 映射 cache、进制转换 base；数据结构：KMP kmp、散列 hash、堆 heap、折半查找 bsearch；
// 网络：TCP 拥塞控制 tcp。规矩同 `AnimKits.swift`：结果由算法算出来，每一步说明讲「为什么」；生成的文字与安卓 `AnimKits2.kt` 逐字相同（跨端向量）。

extension AnimKits {
    static let names2 = ["page", "disk", "cache", "base", "kmp", "hash", "heap", "bsearch", "tcp"]

    static func generate2(_ name: String, _ a: inout Args, _ L: Words) throws -> Kit? {
        switch name {
        case "page": return try pageKit(&a, L)
        case "disk": return try diskKit(&a, L)
        case "cache": return try cacheKit(&a, L)
        case "base": return try baseKit(&a, L)
        case "kmp": return try kmpKit(&a, L)
        case "hash": return try hashKit(&a, L)
        case "heap": return try heapKit(&a, L)
        case "bsearch": return try bsearchKit(&a, L)
        case "tcp": return try tcpKit(&a, L)
        default: return nil
        }
    }

    // MARK: - 公用

    /// `7,0,1` 或 `[7, 0, 1]`：逗号分隔的整数。
    static func intList(_ a: inout Args, _ k: String, usage: String) throws -> [Int] {
        guard let s = a.string(k) else { throw AnimParseError(usage) }
        var out: [Int] = []
        for part in s.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).components(separatedBy: ",") {
            let t = part.trimmingCharacters(in: .whitespaces)
            if t.isEmpty { continue }
            guard let v = Int(t) else { throw AnimParseError("\(k)= takes whole numbers like 7,0,1") }
            out.append(v)
        }
        guard !out.isEmpty else { throw AnimParseError(usage) }
        return out
    }

    static func choice(_ a: inout Args, _ k: String, _ options: [String], default d: String) throws -> String {
        guard let v = a.string(k)?.lowercased() else { return d }
        guard options.contains(v) else { throw AnimParseError("\(k)= takes \(options.joined(separator: " / "))") }
        return v
    }

    /// 两位小数、去掉多余的 0：27.5、3、0.33。
    static func num(_ x: Double) -> String {
        let r = (x * 100).rounded() / 100
        if r == r.rounded() { return String(Int(r)) }
        var s = String(format: "%.2f", r)
        while s.hasSuffix("0") { s.removeLast() }
        return s
    }

    private static func s(_ caption: String, _ actions: [String]) -> [String] {
        ["step " + caption.replacingOccurrences(of: "#", with: "＃")] + actions.map { "  " + $0 }
    }

    // MARK: - 页面置换（操作系统）

    /// 表格：列 = 访问序列，行 = 内存块 + 最后一行「缺页」（缺页打 √）。块的位置固定：新页调进被换出的那一块。
    private static func pageKit(_ a: inout Args, _ L: Words) throws -> Kit {
        let alg = try choice(&a, "alg", ["fifo", "lru", "opt", "clock"], default: "lru")
        let refs = try intList(&a, "refs", usage: "usage: kit page alg=lru refs=7,0,1,2,0,3 frames=3")
        let f = try a.int("frames", default: 3, 1...6)
        try a.checkUnused(["alg", "refs", "frames", "lang"])
        guard refs.count <= 20 else { throw AnimParseError("refs: at most 20 accesses") }
        let n = refs.count
        let rows = (1...f).map { L.t("块\($0)", "F\($0)") } + [L.t("缺页", "fault")]
        let order = L.t(alg == "lru" ? "使用次序(旧→新)" : "调入次序(旧→新)", alg == "lru" ? "use(old→new)" : "loaded(old→new)")
        let faultsName = L.t("缺页次数", "faults")
        var lines = ["grid P rows=[\(rows.joined(separator: ", "))] cols=[\(refs.map(String.init).joined(separator: ", "))] = \(f + 1)x\(n)",
                     "var \(faultsName) = 0"]
        if alg == "fifo" || alg == "lru" { lines.append("var \(order) = -") }
        if alg == "clock" {
            lines.append("pointer \(L.t("指针", "hand"))")
            lines.append("text " + q(L.t("格子里是「页号(访问位)」；指针指着下一次从哪一块开始找", "Cells show page(use bit); the hand marks where the next search starts")))
        }
        var frames: [Int?] = Array(repeating: nil, count: f)
        var use = Array(repeating: 0, count: f)        // CLOCK 访问位
        var loaded: [Int] = []                         // FIFO 调入次序 / LRU 使用次序（旧 → 新）
        var hand = 0
        var faults = 0
        let rule: String
        switch alg {
        case "fifo": rule = L.t("FIFO：换出最早调入的页", "FIFO: evict the page loaded earliest")
        case "lru": rule = L.t("LRU：换出最久没有使用的页", "LRU: evict the page unused for the longest time")
        case "opt": rule = L.t("OPT：换出以后最晚才用到（或不再用到）的页", "OPT: evict the page used farthest in the future (or never again)")
        default: rule = L.t("CLOCK：指针转着找访问位为 0 的页，路过的访问位 1 清成 0", "CLOCK: the hand looks for use bit 0, clearing 1s it passes")
        }
        func cell(_ i: Int) -> String {
            guard let p = frames[i] else { return "" }
            return alg == "clock" ? "\(p)(\(use[i]))" : "\(p)"
        }
        for (k, p) in refs.enumerated() {
            var acts: [String] = []
            if k > 0 { acts.append("unmark P[0..\(f),\(k - 1)]") }
            var cap = L.t("第 \(k + 1) 次访问 \(p)：", "access #\(k + 1), page \(p): ")
            if let slot = frames.firstIndex(where: { $0 == p }) {
                if alg == "lru" { loaded.removeAll { $0 == p }; loaded.append(p) }
                if alg == "clock" { use[slot] = 1 }
                cap += L.t("已在块\(slot + 1)，命中", "already in F\(slot + 1): hit")
                    + (alg == "lru" ? L.t("，它变成最近使用的", "; it becomes the most recent") : "")
                    + (alg == "clock" ? L.t("，访问位置 1", "; set its use bit") : "")
                for i in 0..<f where frames[i] != nil { acts.append("set P[\(i),\(k)] = \(cell(i))") }
                acts.append("mark P[\(slot),\(k)] done")
            } else {
                faults += 1
                let slot: Int
                if let free = frames.firstIndex(where: { $0 == nil }) {
                    slot = free
                    cap += L.t("不在内存，缺页；块\(free + 1)空着，直接调入", "not in memory: page fault; F\(free + 1) is free, load it")
                    if alg == "clock" { hand = (free + 1) % f }
                } else {
                    switch alg {
                    case "fifo", "lru":
                        let victim = loaded[0]
                        slot = frames.firstIndex(where: { $0 == victim })!
                        loaded.removeFirst()
                        cap += alg == "fifo"
                            ? L.t("不在内存，缺页；内存满，换出最早调入的 \(victim)", "not in memory: fault; memory full, evict \(victim), loaded earliest")
                            : L.t("不在内存，缺页；内存满，换出最久没用的 \(victim)", "not in memory: fault; memory full, evict \(victim), unused the longest")
                    case "opt":
                        var notes: [String] = []
                        var best = 0, bestNext = -1
                        for i in 0..<f {
                            let page = frames[i]!
                            let nextUse = refs[(k + 1)...].firstIndex(of: page)
                            let dist = nextUse ?? Int.max
                            notes.append(nextUse.map { L.t("\(page) 第 \($0 + 1) 次再用", "\(page) next at #\($0 + 1)") } ?? L.t("\(page) 不再用到", "\(page) never again"))
                            if dist > bestNext { bestNext = dist; best = i }
                        }
                        slot = best
                        cap += L.t("不在内存，缺页；往后看：", "not in memory: fault; looking ahead: ") + notes.joined(separator: L.listSep)
                            + L.t("，换出 \(frames[best]!)", "; evict \(frames[best]!)")
                    default:
                        var path: [String] = []
                        while use[hand] == 1 {
                            path.append(L.t("块\(hand + 1)访问位 1→0", "F\(hand + 1) use 1→0"))
                            use[hand] = 0
                            hand = (hand + 1) % f
                        }
                        slot = hand
                        path.append(L.t("块\(hand + 1)访问位 0，换出 \(frames[hand]!)", "F\(hand + 1) use 0: evict \(frames[hand]!)"))
                        hand = (hand + 1) % f
                        cap += L.t("不在内存，缺页；指针扫过：", "not in memory: fault; the hand sweeps: ") + path.joined(separator: L.listSep)
                    }
                }
                frames[slot] = p
                use[slot] = 1
                if alg == "fifo" || alg == "lru" { loaded.append(p) }
                for i in 0..<f where frames[i] != nil { acts.append("set P[\(i),\(k)] = \(cell(i))") }
                acts += ["mark P[\(slot),\(k)] active", "set P[\(f),\(k)] = √", "mark P[\(f),\(k)] wrong", "set \(faultsName) = \(faults)"]
            }
            if alg == "fifo" || alg == "lru" { acts.append("set \(order) = \(loaded.map(String.init).joined(separator: " "))") }
            if alg == "clock" { acts.append("move \(L.t("指针", "hand")) -> P[\(hand),\(k)]") }
            lines += s(k == 0 ? rule + L.sep + cap : cap, acts)
        }
        lines += s(L.t("共 \(n) 次访问，缺页 \(faults) 次，缺页率 \(faults)/\(n) = \(num(Double(faults) * 100 / Double(n)))%",
                       "\(n) accesses, \(faults) page faults: fault rate \(faults)/\(n) = \(num(Double(faults) * 100 / Double(n)))%"),
                   ["unmark P[0..\(f),\(n - 1)]"] + (alg == "clock" ? ["move \(L.t("指针", "hand")) -> null"] : []))
        let title: String
        switch alg {
        case "fifo": title = L.t("页面置换：FIFO（\(f) 个内存块）", "Page replacement: FIFO (\(f) frames)")
        case "lru": title = L.t("页面置换：LRU（\(f) 个内存块）", "Page replacement: LRU (\(f) frames)")
        case "opt": title = L.t("页面置换：OPT 最佳置换（\(f) 个内存块）", "Page replacement: OPT (\(f) frames)")
        default: title = L.t("页面置换：CLOCK 时钟（\(f) 个内存块）", "Page replacement: CLOCK (\(f) frames)")
        }
        return Kit(title: title, lines: lines)
    }

    // MARK: - 磁盘调度（操作系统）

    /// 磁道号排成一排（请求 + 起点，SCAN / C-SCAN 加上要走到的端点），磁头是指针；按算法依次访问，累计移动距离。
    private static func diskKit(_ a: inout Args, _ L: Words) throws -> Kit {
        let alg = try choice(&a, "alg", ["fcfs", "sstf", "scan", "cscan", "look", "clook"], default: "sstf")
        let start = try a.int("start", default: 100, 0...9999)
        let reqs = try intList(&a, "requests", usage: "usage: kit disk alg=sstf start=100 requests=55,58,39,18,90")
        let up = try choice(&a, "dir", ["up", "down"], default: "up") == "up"
        let maxTrack = try a.int("max", default: 199, 1...9999)
        try a.checkUnused(["alg", "start", "requests", "dir", "max", "lang"])
        guard reqs.count <= 16 else { throw AnimParseError("requests: at most 16") }
        guard reqs.allSatisfy({ $0 >= 0 && $0 <= maxTrack }), start <= maxTrack else { throw AnimParseError("tracks must be 0…\(maxTrack)") }
        // 访问次序（含端点：标记为端点的不算请求）
        var visits: [(track: Int, isEnd: Bool, why: String)] = []
        var pending = reqs
        var head = start
        let dirWord = up ? L.t("磁道号增大", "increasing") : L.t("磁道号减小", "decreasing")
        func take(_ t: Int) { if let i = pending.firstIndex(of: t) { pending.remove(at: i) } }
        switch alg {
        case "fcfs":
            for t in reqs { visits.append((t, false, L.t("按请求到达的先后", "in arrival order"))) }
        case "sstf":
            while !pending.isEmpty {
                let best = pending.min { (abs($0 - head), $0) < (abs($1 - head), $1) }!
                visits.append((best, false, L.t("离 \(head) 最近的是 \(best)", "\(best) is closest to \(head)")))
                take(best); head = best
            }
        default:
            let ahead = pending.filter { up ? $0 >= start : $0 <= start }.sorted { up ? $0 < $1 : $0 > $1 }
            let behind = pending.filter { up ? $0 < start : $0 > start }
            for t in ahead { visits.append((t, false, L.t("沿\(dirWord)方向继续", "keep moving \(up ? "up" : "down")"))) }
            let end = up ? maxTrack : 0, other = up ? 0 : maxTrack
            switch alg {
            case "scan":
                if visits.last?.track != end && (visits.isEmpty ? start : visits.last!.track) != end {
                    visits.append((end, true, L.t("SCAN 要走到这一头的尽头 \(end) 才掉头", "SCAN runs to the end, \(end), before turning")))
                }
                for t in behind.sorted(by: { up ? $0 > $1 : $0 < $1 }) { visits.append((t, false, L.t("掉头，沿反方向依次访问", "turn around and serve the rest"))) }
            case "look":
                for t in behind.sorted(by: { up ? $0 > $1 : $0 < $1 }) { visits.append((t, false, L.t("这一头没有请求了，LOOK 直接掉头", "no more requests this way: LOOK turns around"))) }
            case "cscan":
                if !behind.isEmpty {
                    if visits.last?.track != end { visits.append((end, true, L.t("C-SCAN 先走到尽头 \(end)", "C-SCAN runs to the end, \(end)"))) }
                    visits.append((other, true, L.t("立刻返回另一头 \(other)，返回途中不服务（这段移动也计入）", "jump back to \(other) without serving (counted in the distance)")))
                    for t in behind.sorted(by: { up ? $0 < $1 : $0 > $1 }) { visits.append((t, false, L.t("从头再沿\(dirWord)方向访问", "serve again moving \(up ? "up" : "down")"))) }
                }
            default:   // clook
                let rest = behind.sorted(by: { up ? $0 < $1 : $0 > $1 })
                for (i, t) in rest.enumerated() {
                    visits.append((t, false, i == 0 ? L.t("C-LOOK 直接跳到另一头最远的请求 \(t)（这段移动也计入）", "C-LOOK jumps to the farthest request, \(t) (counted)")
                                                    : L.t("沿\(dirWord)方向继续", "keep moving \(up ? "up" : "down")")))
                }
            }
        }
        let tracks = Array(Set(reqs + [start] + visits.map(\.track))).sorted()
        let name = L.t("磁道", "track")
        let headName = L.t("磁头", "head")
        let distName = L.t("移动距离", "distance")
        let seqName = L.t("访问序列", "order")
        var lines = ["array \(name) = [\(tracks.map(String.init).joined(separator: ", "))]",
                     "pointer \(headName) -> \(name)[\(tracks.firstIndex(of: start)!)]",
                     "var \(distName) = 0", "queue \(seqName) = []"]
        let rule: String
        switch alg {
        case "fcfs": rule = L.t("FCFS 先来先服务", "FCFS: first come, first served")
        case "sstf": rule = L.t("SSTF 最短寻找时间优先：每次去最近的请求", "SSTF: always the closest request")
        case "scan": rule = L.t("SCAN 电梯：沿\(dirWord)方向走到尽头再掉头", "SCAN: move \(up ? "up" : "down") to the end, then turn")
        case "look": rule = L.t("LOOK：沿\(dirWord)方向，到最远的请求就掉头", "LOOK: move \(up ? "up" : "down") to the last request, then turn")
        case "cscan": rule = L.t("C-SCAN 循环扫描：只沿\(dirWord)方向服务，到尽头后返回另一头", "C-SCAN: serve moving \(up ? "up" : "down") only, then jump back")
        default: rule = L.t("C-LOOK：只沿\(dirWord)方向服务，到最远的请求后跳回另一头最远的请求", "C-LOOK: serve one way, then jump to the farthest request")
        }
        lines += s(rule + L.sep + L.t("磁头在 \(start)", "the head is at \(start)"), ["mark \(name)[\(tracks.firstIndex(of: start)!)] muted"])
        var pos = start, total = 0
        var prevIndex: Int?
        for v in visits {
            let d = abs(v.track - pos)
            total += d
            let idx = tracks.firstIndex(of: v.track)!
            var acts: [String] = []
            if let p = prevIndex { acts.append("unmark \(name)[\(p)]") }
            acts += ["move \(headName) -> \(name)[\(idx)]", "set \(distName) = \(total)"]
            if v.isEnd {
                acts.append("mark \(name)[\(idx)] active")
                prevIndex = idx
            } else {
                acts += ["mark \(name)[\(idx)] done", "enqueue \(seqName) \(v.track)"]
                prevIndex = nil
            }
            lines += s(v.why + L.sep + L.t("\(pos) → \(v.track)，移动 \(d)，累计 \(total)", "\(pos) → \(v.track): move \(d), total \(total)"), acts)
            pos = v.track
        }
        lines += s(L.t("总移动 \(total) 个磁道，平均寻道长度 \(total)/\(reqs.count) = \(num(Double(total) / Double(reqs.count)))",
                       "total \(total) tracks; average seek length \(total)/\(reqs.count) = \(num(Double(total) / Double(reqs.count)))"),
                   prevIndex.map { ["unmark \(name)[\($0)]"] } ?? [])
        let title: String
        switch alg {
        case "fcfs": title = L.t("磁盘调度：FCFS（从 \(start) 开始）", "Disk scheduling: FCFS (from \(start))")
        case "sstf": title = L.t("磁盘调度：SSTF（从 \(start) 开始）", "Disk scheduling: SSTF (from \(start))")
        case "scan": title = L.t("磁盘调度：SCAN（从 \(start) 开始）", "Disk scheduling: SCAN (from \(start))")
        case "look": title = L.t("磁盘调度：LOOK（从 \(start) 开始）", "Disk scheduling: LOOK (from \(start))")
        case "cscan": title = L.t("磁盘调度：C-SCAN（从 \(start) 开始）", "Disk scheduling: C-SCAN (from \(start))")
        default: title = L.t("磁盘调度：C-LOOK（从 \(start) 开始）", "Disk scheduling: C-LOOK (from \(start))")
        }
        return Kit(title: title, lines: lines)
    }

    // MARK: - Cache 映射与替换（组成原理）

    /// 表格：每一行是 Cache 的一行，两列 = 标记、主存块号。块 b → 组号 b mod 组数，标记 b / 组数；组里找标记，命中 / 缺失，替换按 LRU 或 FIFO。
    private static func cacheKit(_ a: inout Args, _ L: Words) throws -> Kit {
        let map = try choice(&a, "map", ["direct", "full", "set"], default: "direct")
        let linesN = try a.int("lines", default: 4, 1...16)
        let ways = map == "set" ? try a.int("ways", default: 2, 1...16) : (map == "full" ? linesN : 1)
        let blocks = try intList(&a, "blocks", usage: "usage: kit cache map=direct lines=4 blocks=0,4,8,0")
        let rep = try choice(&a, "replace", ["lru", "fifo"], default: "lru")
        try a.checkUnused(["map", "lines", "ways", "blocks", "replace", "lang"])
        guard blocks.count <= 20 else { throw AnimParseError("blocks: at most 20 accesses") }
        guard linesN % ways == 0 else { throw AnimParseError("lines must be a multiple of ways") }
        guard blocks.allSatisfy({ $0 >= 0 }) else { throw AnimParseError("block numbers are ≥ 0") }
        let sets = linesN / ways
        let rowLabels = (0..<linesN).map { i -> String in
            switch map {
            case "set": return L.t("\(i / ways)组\(i % ways)路", "s\(i / ways)w\(i % ways)")
            default: return L.t("行\(i)", "L\(i)")
            }
        }
        let tagName = L.t("标记", "tag"), blockName = L.t("块", "block")
        let hitName = L.t("命中", "hits"), missName = L.t("缺失", "misses")
        var lines = ["grid C rows=[\(rowLabels.joined(separator: ", "))] cols=[\(tagName), \(blockName)] = \(linesN)x2",
                     "var \(hitName) = 0", "var \(missName) = 0"]
        var tags: [Int?] = Array(repeating: nil, count: linesN)
        var stamp = Array(repeating: 0, count: linesN)       // LRU：上次使用；FIFO：调入时刻
        var hits = 0, misses = 0
        let rule: String
        switch map {
        case "direct": rule = L.t("直接映射：块 b 只能放第 b mod \(linesN) 行，标记 = b / \(linesN)", "direct mapped: block b goes to line b mod \(linesN); tag = b / \(linesN)")
        case "full": rule = L.t("全相联：块可以放任意一行，标记就是块号", "fully associative: any line; the tag is the block number")
        default: rule = L.t("\(ways) 路组相联（\(sets) 组）：块 b 放第 b mod \(sets) 组的任意一路，标记 = b / \(sets)", "\(ways)-way set associative (\(sets) sets): block b goes to set b mod \(sets); tag = b / \(sets)")
        }
        var prevMarked: Int?
        for (k, b) in blocks.enumerated() {
            let set = b % sets, tag = b / sets
            let range = (set * ways)..<(set * ways + ways)
            var acts: [String] = []
            if let p = prevMarked { acts.append("unmark C[\(p),0..1]") }
            var cap = L.t("第 \(k + 1) 次访问块 \(b)：", "access #\(k + 1), block \(b): ")
            switch map {
            case "direct": cap += L.t("\(b) mod \(linesN) = \(set) → 行\(set)，标记 \(tag)", "\(b) mod \(linesN) = \(set) → line \(set), tag \(tag)")
            case "full": cap += L.t("标记 \(tag)，查所有行", "tag \(tag), check every line")
            default: cap += L.t("\(b) mod \(sets) = \(set) → 第 \(set) 组，标记 \(tag)", "\(b) mod \(sets) = \(set) → set \(set), tag \(tag)")
            }
            if let line = range.first(where: { tags[$0] == tag }) {
                hits += 1
                if rep == "lru" { stamp[line] = k + 1 }
                cap += L.t("；\(rowLabels[line]) 的标记相同，命中", "; \(rowLabels[line]) has the same tag: hit")
                acts += ["mark C[\(line),0..1] done", "set \(hitName) = \(hits)"]
                prevMarked = line
            } else {
                misses += 1
                let line: Int
                if let free = range.first(where: { tags[$0] == nil }) {
                    line = free
                    cap += L.t("；没有相同标记，缺失；\(rowLabels[free]) 空着，调入", "; no matching tag: miss; \(rowLabels[free]) is empty, load it")
                } else {
                    line = range.min { stamp[$0] < stamp[$1] }!
                    let old = tags[line]! * sets + set
                    cap += L.t("；没有相同标记，缺失；", "; no matching tag: miss; ")
                        + (rep == "lru" ? L.t("换出最久没用的块 \(old)（\(rowLabels[line])）", "evict block \(old), unused longest (\(rowLabels[line]))")
                                        : L.t("换出最早调入的块 \(old)（\(rowLabels[line])）", "evict block \(old), loaded earliest (\(rowLabels[line]))"))
                }
                tags[line] = tag
                stamp[line] = k + 1
                acts += ["set C[\(line),0] = \(tag)", "set C[\(line),1] = \(b)", "mark C[\(line),0..1] active", "set \(missName) = \(misses)"]
                prevMarked = line
            }
            lines += s(k == 0 ? rule + L.sep + cap : cap, acts)
        }
        let n = blocks.count
        lines += s(L.t("命中 \(hits) 次、缺失 \(misses) 次，命中率 \(hits)/\(n) = \(num(Double(hits) * 100 / Double(n)))%",
                       "\(hits) hits, \(misses) misses: hit rate \(hits)/\(n) = \(num(Double(hits) * 100 / Double(n)))%"),
                   prevMarked.map { ["unmark C[\($0),0..1]"] } ?? [])
        let kind: String
        switch map {
        case "direct": kind = L.t("直接映射", "direct mapped")
        case "full": kind = L.t("全相联", "fully associative")
        default: kind = L.t("\(ways) 路组相联", "\(ways)-way set associative")
        }
        return Kit(title: L.t("Cache：\(kind)，\(linesN) 行", "Cache: \(kind), \(linesN) lines") + (map == "direct" ? "" : L.t("，\(rep == "lru" ? "LRU" : "FIFO") 替换", ", \(rep.uppercased()) replacement")),
                   lines: lines)
    }

    // MARK: - 进制转换（组成原理）

    /// 除基取余：竖式短除，每行「基数 | 被除数」、行尾写余数；最后从下往上读余数。
    private static func baseKit(_ a: inout Args, _ L: Words) throws -> Kit {
        guard let raw = a.string("n"), let n = Int(raw), n >= 0, n <= 1_000_000_000 else { throw AnimParseError("usage: kit base n=156 to=2  (n: 0…1000000000)") }
        let base = try a.int("to", default: 2, 2...16)
        try a.checkUnused(["n", "to", "lang"])
        let digits = Array("0123456789ABCDEF")
        let S = L.t("竖式", "work")
        let bw = String(base).count
        let width = String(n).count
        let col0 = bw + 1
        let remCol = col0 + width + 1
        var lines = ["sheet \(S)", "write \(S)[0,0] \(q(String(base)))", "write \(S)[0,\(bw)] \"|\"",
                     "write \(S)[0,\(col0 + width - String(n).count)] \(q(String(n)))",
                     "label \(S)[0] \(q(L.t("← 右边一列是余数", "← the right column holds the remainders")))"]
        var cur = n, row = 0
        var rems: [Character] = []
        if n == 0 {
            lines += s(L.t("0 的任何进制写法都是 0", "0 is 0 in any base"), [])
        }
        while cur > 0 {
            let q2 = cur / base, r = cur % base
            rems.append(digits[r])
            var acts = ["mark \(S)[\(row),\(col0)..\(col0 + width - 1)] active", "write \(S)[\(row),\(remCol)] \(q(String(digits[r])))"]
            if row > 0 { acts.insert("unmark \(S)[\(row - 1),\(col0)..\(col0 + width - 1)]", at: 0) }
            if q2 > 0 {
                acts += ["write \(S)[\(row + 1),0] \(q(String(base)))", "write \(S)[\(row + 1),\(bw)] \"|\"",
                         "write \(S)[\(row + 1),\(col0 + width - String(q2).count)] \(q(String(q2)))"]
            } else {
                acts.append("write \(S)[\(row + 1),\(col0 + width - 1)] \"0\"")
            }
            acts.append("rule \(S)[\(row),\(col0)..\(col0 + width - 1)]")
            lines += s(L.t("\(cur) ÷ \(base) = \(q2) 余 \(digits[r])", "\(cur) ÷ \(base) = \(q2) remainder \(digits[r])")
                       + (q2 == 0 ? L.t("；商为 0，停止", "; the quotient is 0: stop") : ""), acts)
            cur = q2
            row += 1
        }
        let result = n == 0 ? "0" : String(rems.reversed())
        lines += s(L.t("余数从下往上读：(\(n))₁₀ = (\(result))\(subscriptDigits(base))", "read the remainders bottom to top: (\(n))₁₀ = (\(result))\(subscriptDigits(base))"),
                   row > 0 ? ["unmark \(S)[\(row - 1),\(col0)..\(col0 + width - 1)]", "mark \(S)[0..\(row - 1),\(remCol)] done"] : [])
        return Kit(title: L.t("进制转换：\(n) 转 \(base) 进制（除基取余）", "Base conversion: \(n) to base \(base)"), lines: lines)
    }

    static func subscriptDigits(_ n: Int) -> String {
        let sub: [Character: Character] = ["0": "₀", "1": "₁", "2": "₂", "3": "₃", "4": "₄", "5": "₅", "6": "₆", "7": "₇", "8": "₈", "9": "₉"]
        return String(String(n).map { sub[$0]! })
    }

    // MARK: - KMP 的 next / nextval（数据结构，下标从 1 开始）

    private static func kmpKit(_ a: inout Args, _ L: Words) throws -> Kit {
        guard let p = a.string("p"), !p.isEmpty, p.count <= 16, !p.contains(where: { $0.isWhitespace || "[]=\"#|,".contains($0) }) else {
            throw AnimParseError("usage: kit kmp P=ababaa  (1 to 16 characters, no spaces or commas)")
        }
        let withVal = try choice(&a, "nextval", ["yes", "no"], default: "yes") == "yes"
        try a.checkUnused(["P", "nextval", "lang"])
        let c = Array(p).map(String.init)
        let n = c.count
        let rowNames = [L.t("模式串", "P"), "next"] + (withVal ? ["nextval"] : [])
        var lines = ["grid K rows=[\(rowNames.joined(separator: ", "))] cols=[\((1...n).map(String.init).joined(separator: ", "))] = [[\(c.joined(separator: ", "))]\(String(repeating: ", [" + Array(repeating: "", count: n).joined(separator: ", ") + "]", count: rowNames.count - 1))]",
                     "pointer i -> K[0,0]", "pointer j"]
        var next = Array(repeating: 0, count: n + 1)
        lines += s(L.t("next[1] = 0（第一位就失配：模式串右移、主串指针后移）；i = 1，j = 0", "next[1] = 0 (a mismatch at the first character moves on); i = 1, j = 0"),
                   ["set K[1,0] = 0", "mark K[1,0] done"])
        var i = 1, j = 0
        while i < n {
            var acts: [String] = []
            if j == 0 || c[i - 1] == c[j - 1] {
                let why = j == 0 ? L.t("j = 0", "j = 0") : L.t("P[\(i)] = P[\(j)] = \(c[i - 1])", "P[\(i)] = P[\(j)] = \(c[i - 1])")
                i += 1; j += 1
                next[i] = j
                acts += ["move i -> K[0,\(i - 1)]", "move j -> K[0,\(j - 1)]", "set K[1,\(i - 1)] = \(j)", "mark K[1,\(i - 1)] done"]
                lines += s(why + L.t("：i、j 都后移，next[\(i)] = \(j)", ": move i and j on; next[\(i)] = \(j)"), acts)
            } else {
                let old = j
                j = next[j]
                acts.append(j == 0 ? "move j -> null" : "move j -> K[0,\(j - 1)]")
                lines += s(L.t("P[\(i)] = \(c[i - 1]) ≠ P[\(old)] = \(c[old - 1])：j 回退到 next[\(old)] = \(j)", "P[\(i)] = \(c[i - 1]) ≠ P[\(old)] = \(c[old - 1]): j falls back to next[\(old)] = \(j)"), acts)
            }
        }
        if withVal {
            var nextval = Array(repeating: 0, count: n + 1)
            lines += s(L.t("nextval：若 P[j] = P[next[j]]，失配后跳过去也必然失配，就继承 nextval[next[j]]；否则 nextval[j] = next[j]", "nextval: if P[j] = P[next[j]], that jump would fail again, so take nextval[next[j]]; else nextval[j] = next[j]"),
                       ["move i -> null", "move j -> null", "set K[2,0] = 0", "mark K[2,0] done"])
            for jj in 2...max(n, 2) where jj <= n {
                let k = next[jj]
                var acts = ["move j -> K[0,\(jj - 1)]"]
                let cap: String
                if k > 0 && c[jj - 1] == c[k - 1] {
                    nextval[jj] = nextval[k]
                    cap = L.t("P[\(jj)] = P[next[\(jj)]] = P[\(k)] = \(c[jj - 1])：nextval[\(jj)] = nextval[\(k)] = \(nextval[jj])",
                              "P[\(jj)] = P[\(k)] = \(c[jj - 1]): nextval[\(jj)] = nextval[\(k)] = \(nextval[jj])")
                } else {
                    nextval[jj] = k
                    cap = k == 0 ? L.t("next[\(jj)] = 0：nextval[\(jj)] = 0", "next[\(jj)] = 0: nextval[\(jj)] = 0")
                                 : L.t("P[\(jj)] = \(c[jj - 1]) ≠ P[\(k)] = \(c[k - 1])：nextval[\(jj)] = next[\(jj)] = \(k)", "P[\(jj)] = \(c[jj - 1]) ≠ P[\(k)] = \(c[k - 1]): nextval[\(jj)] = next[\(jj)] = \(k)")
                }
                acts += ["set K[2,\(jj - 1)] = \(nextval[jj])", "mark K[2,\(jj - 1)] done"]
                lines += s(cap, acts)
            }
            lines += s(L.t("完成：next = \((1...n).map { String(next[$0]) }.joined(separator: " "))；nextval = \((1...n).map { String(nextval[$0]) }.joined(separator: " "))",
                           "done: next = \((1...n).map { String(next[$0]) }.joined(separator: " ")); nextval = \((1...n).map { String(nextval[$0]) }.joined(separator: " "))"), ["move j -> null"])
        } else {
            lines += s(L.t("完成：next = \((1...n).map { String(next[$0]) }.joined(separator: " "))", "done: next = \((1...n).map { String(next[$0]) }.joined(separator: " "))"),
                       ["move i -> null", "move j -> null"])
        }
        return Kit(title: L.t("KMP：模式串 \(p) 的 next\(withVal ? " / nextval" : "") 数组", "KMP: next\(withVal ? " / nextval" : "") of \(p)"), lines: lines)
    }

    // MARK: - 散列表（数据结构）

    private static func hashKit(_ a: inout Args, _ L: Words) throws -> Kit {
        let keys = try intList(&a, "keys", usage: "usage: kit hash keys=19,14,23,1,68 size=13 [p=13] [probe=linear]")
        let m = try a.int("size", default: 13, 2...20)
        func isPrime(_ x: Int) -> Bool { x >= 2 && (2..<x).allSatisfy { x % $0 != 0 } }
        let p = try a.int("p", default: (2...m).last(where: isPrime) ?? m, 1...m)
        let probe = try choice(&a, "probe", ["linear", "quadratic"], default: "linear")
        try a.checkUnused(["keys", "size", "p", "probe", "lang"])
        guard keys.count <= m, keys.count <= 16 else { throw AnimParseError("keys: at most \(min(m, 16)) (the table has \(m) cells)") }
        guard keys.allSatisfy({ $0 >= 0 }) else { throw AnimParseError("keys are ≥ 0") }
        let keyRow = L.t("关键字", "key"), cmpRow = L.t("比较次数", "probes")
        var lines = ["grid H rows=[\(keyRow), \(cmpRow)] cols=[\((0..<m).map(String.init).joined(separator: ", "))] = 2x\(m)"]
        var table: [Int?] = Array(repeating: nil, count: m)
        var total = 0
        let rule = probe == "linear"
            ? L.t("H(key) = key mod \(p)；冲突就线性探测：依次看下一格（到表尾回到 0）", "H(key) = key mod \(p); on a collision probe linearly: the next cell, wrapping to 0")
            : L.t("H(key) = key mod \(p)；冲突就平方探测：依次加 1², -1², 2², -2²…（对 \(m) 取模）", "H(key) = key mod \(p); on a collision probe quadratically: +1², −1², +2², −2²… (mod \(m))")
        var prevMarks: [Int] = []
        for (k, key) in keys.enumerated() {
            let h = key % p
            var acts = prevMarks.map { "unmark H[0..1,\($0)]" }
            prevMarks = []
            var tried: [Int] = []
            var addr: Int?
            var step = 0
            let limit = probe == "linear" ? m : 2 * m
            while step < limit {
                let off: Int
                if probe == "linear" { off = step } else {
                    let i = (step + 1) / 2
                    off = step == 0 ? 0 : (step % 2 == 1 ? i * i : -i * i)
                }
                let cand = ((h + off) % m + m) % m
                tried.append(cand)
                if table[cand] == nil { addr = cand; break }
                step += 1
            }
            guard let at = addr else { throw AnimParseError("\(key) cannot be placed (\(probe) probing found no free cell)") }
            table[at] = key
            let probes = tried.count
            total += probes
            for c in tried.dropLast() { acts.append("mark H[0,\(c)] wrong"); prevMarks.append(c) }
            acts += ["set H[0,\(at)] = \(key)", "set H[1,\(at)] = \(probes)", "mark H[0..1,\(at)] active"]
            prevMarks.append(at)
            var cap = L.t("\(key) mod \(p) = \(h)", "\(key) mod \(p) = \(h)")
            if tried.count == 1 {
                cap += L.t("：第 \(h) 格空，放入（比较 1 次）", ": cell \(h) is free, put it there (1 probe)")
            } else {
                let collide = tried.dropLast().map { L.t("\($0) 被 \(table[$0]!) 占", "\($0) holds \(table[$0]!)") }.joined(separator: L.listSep)
                cap += L.t("：冲突（\(collide)），放进第 \(at) 格（比较 \(probes) 次）", ": collision (\(collide)); put it in cell \(at) (\(probes) probes)")
            }
            lines += s(k == 0 ? rule + L.sep + cap : cap, acts)
        }
        let n = keys.count
        lines += s(L.t("查找成功的平均查找长度 ASL = 比较次数之和 / 关键字个数 = \(total)/\(n) = \(num(Double(total) / Double(n)))",
                       "successful average search length ASL = total probes / keys = \(total)/\(n) = \(num(Double(total) / Double(n)))"),
                   prevMarks.map { "unmark H[0..1,\($0)]" })
        return Kit(title: L.t("散列表：除留余数法 mod \(p)，\(probe == "linear" ? "线性探测" : "平方探测")", "Hash table: mod \(p), \(probe) probing"), lines: lines)
    }

    // MARK: - 建堆 / 堆排序（数据结构）

    private static func heapKit(_ a: inout Args, _ L: Words) throws -> Kit {
        guard let raw = a.string("a") else { throw AnimParseError("usage: kit heap A=[53, 17, 78, 9, 45] [type=max] [sort=no]") }
        let isMax = try choice(&a, "type", ["max", "min"], default: "max") == "max"
        let sort = try choice(&a, "sort", ["yes", "no"], default: "no") == "yes"
        try a.checkUnused(["A", "type", "sort", "lang"])
        var v = try AnimText.parseList(raw)
        guard v.count >= 2, v.count <= 15 else { throw AnimParseError("heap: 2 to 15 values") }
        guard Set(v).count == v.count else { throw AnimParseError("values must be different (tree nodes are found by value)") }
        let numeric = v.allSatisfy { Double($0) != nil }
        func better(_ x: String, _ y: String) -> Bool {   // x 应该在 y 之上
            if numeric { return isMax ? Double(x)! > Double(y)! : Double(x)! < Double(y)! }
            return isMax ? x > y : x < y
        }
        let n = v.count
        func treeDecl(_ i: Int) -> String {   // 1 起
            let l = 2 * i, r = 2 * i + 1
            if l > n { return v[i - 1] }
            return "(\(v[i - 1]) \(treeDecl(l))\(r <= n ? " " + treeDecl(r) : ""))"
        }
        var lines = ["tree T = \(treeDecl(1))", "array A = [\(v.joined(separator: ", "))]"]
        let kind = isMax ? L.t("大根堆", "max-heap") : L.t("小根堆", "min-heap")
        var carry: [String] = []      // 上一步标的颜色，到下一步开头再取消（同一步里标了又取消，这一步的画面上就看不到）
        func emit(_ cap: String, _ acts: [String]) {
            lines += s(cap, carry + acts)
            carry = []
        }
        let bigger = isMax ? L.t("较大", "larger") : L.t("较小", "smaller")
        func sift(_ start: Int, _ size: Int, _ intro: String?) {
            var i = start
            var first = true
            while 2 * i <= size {
                var c = 2 * i
                if c + 1 <= size && better(v[c], v[c - 1]) { c += 1 }
                let x = v[i - 1], y = v[c - 1]
                var acts = ["mark T[\(x)] active", "mark A[\(i - 1)] active", "mark T[\(y)] active", "mark A[\(c - 1)] active"]
                let lead = first ? (intro.map { $0 + L.sep } ?? "") : ""
                first = false
                if better(y, x) {
                    acts += ["swap T[\(x)] T[\(y)]", "swap A[\(i - 1)] A[\(c - 1)]"]
                    v.swapAt(i - 1, c - 1)
                    emit(lead + L.t("A[\(i)] = \(x)，孩子里\(bigger)的是 \(y)：交换，继续往下比", "A[\(i)] = \(x); its \(bigger) child is \(y): swap and keep going down"), acts)
                    carry = ["unmark T[\(x)]", "unmark T[\(y)]", "unmark A[\(i - 1)]", "unmark A[\(c - 1)]"]
                    i = c
                } else {
                    emit(lead + L.t("A[\(i)] = \(x)，孩子里\(bigger)的是 \(y)：不用换，这棵子树已经是堆", "A[\(i)] = \(x); its \(bigger) child is \(y): no swap, this subtree is a heap"), acts)
                    carry = ["unmark T[\(x)]", "unmark T[\(y)]", "unmark A[\(i - 1)]", "unmark A[\(c - 1)]"]
                    return
                }
            }
            if first, let intro {
                emit(intro + L.sep + L.t("A[\(start)] 没有孩子，不用调整", "A[\(start)] has no children"), [])
            }
        }
        for i in stride(from: n / 2, through: 1, by: -1) {
            sift(i, n, i == n / 2 ? L.t("建\(kind)：从最后一个非叶结点 A[⌊\(n)/2⌋] = A[\(i)] 开始往前逐个向下调整", "build a \(kind): sift down from the last internal node A[⌊\(n)/2⌋] = A[\(i)] backwards")
                                  : L.t("调整 A[\(i)]", "sift down A[\(i)]"))
        }
        emit(L.t("建堆完成：A = \(v.joined(separator: " "))", "heap built: A = \(v.joined(separator: " "))"), [])
        if sort {
            for end in stride(from: n, through: 2, by: -1) {
                let top = v[0], last = v[end - 1]
                v.swapAt(0, end - 1)
                emit(L.t("堆顶 \(top) 与堆尾 A[\(end)] = \(last) 交换，\(top) 就位，移出堆", "swap the top \(top) with the last A[\(end)] = \(last); \(top) is in place"),
                           ["swap T[\(top)] T[\(last)]", "swap A[0] A[\(end - 1)]", "remove T \(top)", "mark A[\(end - 1)] done"])
                if end - 1 >= 2 { sift(1, end - 1, L.t("对新的堆顶向下调整", "sift the new top down")) }
            }
            emit(L.t("排序完成：A = \(v.joined(separator: " "))", "sorted: A = \(v.joined(separator: " "))"), ["mark A done"])
        }
        return Kit(title: L.t(sort ? "堆排序（\(kind)）" : "建\(kind)", sort ? "Heap sort (\(kind))" : "Build a \(kind)"), lines: lines)
    }

    // MARK: - 折半查找（数据结构）

    private static func bsearchKit(_ a: inout Args, _ L: Words) throws -> Kit {
        guard let raw = a.string("a"), let keyRaw = a.string("key") else { throw AnimParseError("usage: kit bsearch A=[7, 10, 13, 16, 19, 29] key=19") }
        try a.checkUnused(["A", "key", "lang"])
        let v = try AnimText.parseList(raw)
        guard v.count >= 1, v.count <= 20 else { throw AnimParseError("bsearch: 1 to 20 values") }
        let numeric = v.allSatisfy { Double($0) != nil } && Double(keyRaw) != nil
        func less(_ x: String, _ y: String) -> Bool { numeric ? Double(x)! < Double(y)! : x < y }
        for i in 1..<max(v.count, 1) where i < v.count { if less(v[i], v[i - 1]) { throw AnimParseError("A must be sorted ascending") } }
        var lines = ["array A = [\(v.joined(separator: ", "))]", "pointer low -> A[0]", "pointer high -> A[\(v.count - 1)]", "pointer mid",
                     "var \(L.t("比较次数", "comparisons")) = 0"]
        var low = 0, high = v.count - 1, count = 0
        let cmpName = L.t("比较次数", "comparisons")
        while low <= high {
            let mid = (low + high) / 2
            count += 1
            var acts = ["move mid -> A[\(mid)]", "mark A[\(mid)] active", "set \(cmpName) = \(count)"]
            let head = L.t("low = \(low)，high = \(high)，mid = ⌊(\(low)+\(high))/2⌋ = \(mid)：", "low = \(low), high = \(high), mid = ⌊(\(low)+\(high))/2⌋ = \(mid): ")
            if v[mid] == keyRaw || (numeric && Double(v[mid])! == Double(keyRaw)!) {
                acts += ["mark A[\(mid)] done"]
                lines += s(head + L.t("A[\(mid)] = \(v[mid]) 等于 \(keyRaw)，找到（比较 \(count) 次）", "A[\(mid)] = \(v[mid]) equals \(keyRaw): found (\(count) comparisons)"), acts)
                return Kit(title: L.t("折半查找 \(keyRaw)", "Binary search for \(keyRaw)"), lines: lines)
            }
            if less(v[mid], keyRaw) {
                acts += ["mark A[\(low)..\(mid)] muted", "move low -> A[\(mid + 1)]"]
                lines += s(head + L.t("A[\(mid)] = \(v[mid]) < \(keyRaw)，在右半边找：low = mid + 1 = \(mid + 1)", "A[\(mid)] = \(v[mid]) < \(keyRaw): search the right half, low = mid + 1 = \(mid + 1)"), acts)
                low = mid + 1
            } else {
                acts += ["mark A[\(mid)..\(high)] muted", mid - 1 >= 0 ? "move high -> A[\(mid - 1)]" : "move high -> null"]
                lines += s(head + L.t("A[\(mid)] = \(v[mid]) > \(keyRaw)，在左半边找：high = mid - 1 = \(mid - 1)", "A[\(mid)] = \(v[mid]) > \(keyRaw): search the left half, high = mid - 1 = \(mid - 1)"), acts)
                high = mid - 1
            }
        }
        lines += s(L.t("low = \(low) > high = \(high)：查找失败（比较 \(count) 次）", "low = \(low) > high = \(high): not found (\(count) comparisons)"), ["move mid -> null"])
        return Kit(title: L.t("折半查找 \(keyRaw)", "Binary search for \(keyRaw)"), lines: lines)
    }

    // MARK: - TCP 拥塞控制（计算机网络）

    /// 表格一行 cwnd，按轮次逐列填；颜色：蓝 = 慢开始，绿 = 拥塞避免，红 = 这一轮之后发生超时 / 3 个重复确认。
    private static func tcpKit(_ a: inout Args, _ L: Words) throws -> Kit {
        let ss0 = try a.int("ssthresh", default: 16, 1...128)
        var ss = ss0
        let rounds = try a.int("rounds", default: 16, 2...20)
        let timeouts = try a.ints("timeout"), dups = try a.ints("dup")
        try a.checkUnused(["ssthresh", "rounds", "timeout", "dup", "lang"])
        for r in timeouts.union(dups) where r < 1 || r >= rounds { throw AnimParseError("timeout= / dup= take round numbers 1…\(rounds - 1)") }
        guard timeouts.isDisjoint(with: dups) else { throw AnimParseError("a round can have either a timeout or 3 duplicate ACKs, not both") }
        let ssName = "ssthresh", cwndName = "cwnd"
        var lines = ["grid W rows=[cwnd] cols=[\((1...rounds).map(String.init).joined(separator: ", "))] = 1x\(rounds)",
                     "var \(ssName) = \(ss)", "var \(cwndName) = 1", "pointer \(L.t("当前", "now"))",
                     "text " + q(L.t("蓝：慢开始（每轮翻倍）　绿：拥塞避免（每轮加 1）　红：这一轮后出现超时或 3 个重复确认",
                                     "blue: slow start (doubles)   green: congestion avoidance (+1)   red: a timeout or 3 duplicate ACKs after this round"))]
        var cwnd = 1
        let now = L.t("当前", "now")
        for t in 1...rounds {
            let slow = cwnd < ss
            var acts = ["set W[0,\(t - 1)] = \(cwnd)", "move \(now) -> W[0,\(t - 1)]", "set \(cwndName) = \(cwnd)"]
            var cap = L.t("第 \(t) 轮：cwnd = \(cwnd)", "round \(t): cwnd = \(cwnd)")
            if timeouts.contains(t) {
                let newSS = max(cwnd / 2, 1)
                acts += ["mark W[0,\(t - 1)] wrong", "set \(ssName) = \(newSS)"]
                cap += L.t("；这一轮后超时：ssthresh = cwnd / 2 = \(newSS)，cwnd 回到 1，重新慢开始", "; then a timeout: ssthresh = cwnd / 2 = \(newSS), cwnd back to 1, slow start again")
                ss = newSS; cwnd = 1
            } else if dups.contains(t) {
                let newSS = max(cwnd / 2, 1)
                acts += ["mark W[0,\(t - 1)] wrong", "set \(ssName) = \(newSS)"]
                cap += L.t("；收到 3 个重复确认：快重传，ssthresh = cwnd / 2 = \(newSS)，快恢复令 cwnd = ssthresh = \(newSS)，进入拥塞避免",
                           "; 3 duplicate ACKs: fast retransmit, ssthresh = cwnd / 2 = \(newSS), fast recovery sets cwnd = \(newSS), congestion avoidance")
                ss = newSS; cwnd = newSS
            } else if slow {
                acts.append("mark W[0,\(t - 1)] active")
                let nxt = min(cwnd * 2, ss)
                cap += L.t("，小于 ssthresh = \(ss)，慢开始：下一轮翻倍", " < ssthresh = \(ss): slow start, double next round")
                    + (nxt < cwnd * 2 ? L.t("（但不超过 ssthresh，下一轮 = \(nxt)）", " (capped at ssthresh: \(nxt))") : "")
                cwnd = nxt
            } else {
                acts.append("mark W[0,\(t - 1)] done")
                cap += L.t("，不小于 ssthresh = \(ss)，拥塞避免：下一轮加 1", " ≥ ssthresh = \(ss): congestion avoidance, +1 next round")
                cwnd += 1
            }
            lines += s(cap, acts)
        }
        lines += s(L.t("共 \(rounds) 轮", "\(rounds) rounds"), ["move \(now) -> null"])
        return Kit(title: L.t("TCP 拥塞控制（初始 ssthresh = \(ss0)）", "TCP congestion control (initial ssthresh \(ss0))"), lines: lines)
    }
}
