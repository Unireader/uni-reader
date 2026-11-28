import Foundation

/// ⌘P 快速打开的匹配（`QUICK-OPEN-PLAN.md §6`，2026-11-28 用户要的「支持一些模糊搜索」+ 搜单道题 / 目录）。
/// **只依赖 Foundation**——`spike/quick-open-match-test.swift` 直接编它。
///
/// 规则：
/// - 输入按空白拆成几段，**每段都要中**（顺序不限）：「1000题 基础2.7」= 「1000题」中 且「基础2.7」中。
/// - 一段先整段找；找不到再在「字 ↔ 数字」交界处拆开、每块都要中（「基础2.7」→「基础」「2.7」，「例2.7」→「例」「2.7」）。
/// - 以数字开头 / 结尾的块认**数字边界**：「2.7」不中「12.7」「2.71」，「100」不中「1000」。
/// - 名字含汉字时认拼音全拼 / 首字母（「gdsx」「gaodeng」中「高等数学」；多音字按最常见的读音）。
/// - 名字里按顺序出现各字（中间可跳）= 模糊命中，分最低；含数字的段不做模糊（不然「2.7」到处都中）。
/// - 不分大小写 / 变音符号 / 全半角。
enum QuickOpenMatch {

    /// 一条已经规整好的可搜内容（每次弹出时算一遍，打字时只比字符串）。
    struct Fields {
        /// 主名字（分最高，可前缀、可模糊）。
        var name: String
        /// 第二行（类别 + 在哪）。
        var detail: String
        /// 只认「含」的长内容：题干、章节路径、别名（分最低，不做模糊）。
        var keys: [String]
        /// 名字的拼音（全拼、首字母）；名字里没有汉字 = nil。
        var pinyin: (full: String, initials: String)?
        /// 名字允许模糊命中（单道题关掉：数量多、名字里带题干，模糊会把一大片都捞出来）。
        var fuzzy: Bool

        init(name: String, detail: String, keys: [String] = [], pinyin: Bool = false, fuzzy: Bool = true) {
            self.name = QuickOpenMatch.fold(name)
            self.detail = QuickOpenMatch.fold(detail)
            self.keys = keys.map(QuickOpenMatch.fold).filter { !$0.isEmpty }
            self.pinyin = pinyin ? QuickOpenMatch.pinyin(of: name) : nil
            self.fuzzy = fuzzy
        }
    }

    /// 输入里的一段（按空白拆开后的）。
    struct Piece {
        var whole: String
        /// 在「字 ↔ 数字」交界处拆开的块；只有一块时与 `whole` 相同。
        var parts: [String]
    }

    static func pieces(_ query: String) -> [Piece] {
        fold(query).split(whereSeparator: { $0.isWhitespace }).map { s in
            let w = String(s)
            return Piece(whole: w, parts: split(w))
        }
    }

    /// 按输入排序：每段都中才留下，分高的在前，同分保持原顺序；空输入 = 原顺序里 `browse` 为真的那些。
    static func rank<T>(_ items: [T], fields: [Fields], query: String, limit: Int,
                        browse: (T) -> Bool = { _ in true }) -> [T] {
        let ps = pieces(query)
        guard !ps.isEmpty else { return Array(items.lazy.filter(browse).prefix(limit)) }
        var scored: [(Int, Int)] = []
        for i in items.indices {
            if let s = score(fields[i], ps) { scored.append((s, i)) }
        }
        scored.sort { $0.0 != $1.0 ? $0.0 > $1.0 : $0.1 < $1.1 }
        return scored.prefix(limit).map { items[$0.1] }
    }

    /// 整条的分：每段的分相加；有一段不中 = nil。
    static func score(_ f: Fields, _ ps: [Piece]) -> Int? {
        var total = 0
        for p in ps {
            guard let s = pieceScore(f, p) else { return nil }
            total += s
        }
        return total
    }

    static func pieceScore(_ f: Fields, _ p: Piece) -> Int? {
        if let s = tokenScore(f, p.whole) { return s }
        if p.parts.count > 1 {
            var sum = 0
            for t in p.parts {
                guard let s = tokenScore(f, t) else { sum = -1; break }
                sum += s
            }
            if sum >= 0 { return sum / p.parts.count - 5 }
        }
        // 模糊：名字里按顺序出现各字（含数字的段不做）
        guard f.fuzzy, !p.whole.contains(where: \.isNumber) else { return nil }
        if let gaps = subsequenceGaps(p.whole, in: f.name) { return max(4, 30 - gaps) }
        return nil
    }

    /// 一块（不再拆）的分：名字开头 100 > 名字含 80~ > 拼音 55~70 > 第二行含 50 > 长内容含 40。
    static func tokenScore(_ f: Fields, _ t: String) -> Int? {
        if let pos = find(t, in: f.name) { return pos == 0 ? 100 : 80 - min(pos, 20) }
        if let py = f.pinyin, t.allSatisfy({ $0.isASCII && $0.isLetter }) {
            if py.initials.hasPrefix(t) { return 70 }
            if py.full.hasPrefix(t) { return 65 }
            if t.count >= 2, py.initials.contains(t) { return 60 }
            if t.count >= 2, py.full.contains(t) { return 55 }
        }
        if find(t, in: f.detail) != nil { return 50 }
        for k in f.keys where find(t, in: k) != nil { return 40 }
        return nil
    }

    // MARK: - 字符串工具

    /// `t` 在 `s` 里第一次（满足数字边界的）出现的位置（按字算）；没有 = nil。
    /// 数字边界：`t` 以数字开头 → 前一个字不是数字、也不是紧跟在数字后的「.」；以数字结尾 → 后一个字不是数字、也不是「.数字」。
    static func find(_ t: String, in s: String) -> Int? {
        guard !t.isEmpty else { return nil }
        let headDigit = t.first!.isNumber, tailDigit = t.last!.isNumber
        var from = s.startIndex
        while let r = s.range(of: t, range: from..<s.endIndex) {
            var ok = true
            if headDigit, r.lowerBound > s.startIndex {
                let prev = s[s.index(before: r.lowerBound)]
                if prev.isNumber { ok = false }
                else if prev == ".", s.index(before: r.lowerBound) > s.startIndex,
                        s[s.index(r.lowerBound, offsetBy: -2)].isNumber { ok = false }
            }
            if ok, tailDigit, r.upperBound < s.endIndex {
                let next = s[r.upperBound]
                if next.isNumber { ok = false }
                else if next == ".", s.index(after: r.upperBound) < s.endIndex,
                        s[s.index(after: r.upperBound)].isNumber { ok = false }
            }
            if ok { return s.distance(from: s.startIndex, to: r.lowerBound) }
            from = s.index(after: r.lowerBound)
        }
        return nil
    }

    /// 在「数字 ↔ 别的字」交界处拆开（数字里的「.」算数字：「2.7」是一块）。
    static func split(_ s: String) -> [String] {
        let cs = Array(s)
        func isNum(_ i: Int) -> Bool {
            if cs[i].isNumber { return true }
            return cs[i] == "." && i > 0 && i + 1 < cs.count && cs[i - 1].isNumber && cs[i + 1].isNumber
        }
        var out: [String] = []
        var cur = ""
        var curNum: Bool?
        for i in cs.indices {
            let n = isNum(i)
            if let c = curNum, c != n { out.append(cur); cur = "" }
            cur.append(cs[i])
            curNum = n
        }
        if !cur.isEmpty { out.append(cur) }
        return out
    }

    /// `q` 的字是不是按顺序都出现在 `s` 里；是就返回中间跳过了几个字（越少越像）。
    static func subsequenceGaps(_ q: String, in s: String) -> Int? {
        var it = s.makeIterator()
        var gaps = 0
        var started = false
        for ch in q {
            var found = false
            while let c = it.next() {
                if c == ch { found = true; started = true; break }
                if started { gaps += 1 }
            }
            if !found { return nil }
        }
        return gaps
    }

    static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }

    // MARK: - 拼音

    nonisolated(unsafe) private static var syllables: [Character: String] = [:]
    private static let lock = NSLock()

    /// 名字的拼音：汉字换成不带声调的全拼，别的字照抄（已规整）。没有汉字 = nil。
    static func pinyin(of name: String) -> (full: String, initials: String)? {
        guard name.unicodeScalars.contains(where: isHan) else { return nil }
        var full = "", initials = ""
        lock.lock(); defer { lock.unlock() }
        for ch in name {
            if ch.unicodeScalars.count == 1, isHan(ch.unicodeScalars.first!) {
                let py: String
                if let c = syllables[ch] { py = c } else {
                    py = (String(ch).applyingTransform(.mandarinToLatin, reverse: false) ?? "")
                        .applyingTransform(.stripDiacritics, reverse: false)?
                        .lowercased().filter { $0.isASCII && $0.isLetter } ?? ""
                    syllables[ch] = py
                }
                full += py
                if let f = py.first { initials.append(f) }
            } else if !ch.isWhitespace {
                let f = fold(String(ch))
                full += f
                initials += f
            }
        }
        return (full, initials)
    }

    private static func isHan(_ u: Unicode.Scalar) -> Bool {
        (0x4E00...0x9FFF).contains(u.value) || (0x3400...0x4DBF).contains(u.value) || (0x20000...0x2A6DF).contains(u.value)
    }

    // MARK: - 习题别名

    /// 章节名开头的序号：「第2章 极限」「第二章」→ "2"，「2.3 导数」→ "2.3"，「Chapter 4」→ "4"；没有 = nil。
    static func ordinal(of chapter: String) -> String? {
        let s = fold(chapter).trimmingCharacters(in: .whitespaces)
        let ns = s as NSString
        if let m = ordinalCN.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) {
            let raw = ns.substring(with: m.range(at: 1))
            if let n = Int(raw) { return String(n) }
            return chineseNumber(raw).map(String.init)
        }
        if let m = ordinalNum.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) {
            return ns.substring(with: m.range(at: 1))
        }
        return nil
    }
    private static let ordinalCN = try! NSRegularExpression(pattern: #"^第\s*([0-9一二三四五六七八九十百零〇两]+)\s*[章节篇部讲单元回课]"#)
    private static let ordinalNum = try! NSRegularExpression(pattern: #"^(?:chapter|chap\.?|ch\.?|§|lesson|unit)?\s*([0-9]+(?:\.[0-9]+)*)(?![0-9])"#)

    /// 「十二」→ 12、「二十」→ 20、「一百零五」→ 105（99 以上的够用就行）。
    static func chineseNumber(_ s: String) -> Int? {
        let digit: [Character: Int] = ["零": 0, "〇": 0, "一": 1, "二": 2, "两": 2, "三": 3, "四": 4, "五": 5,
                                       "六": 6, "七": 7, "八": 8, "九": 9]
        var total = 0, cur = 0
        for ch in s {
            if let d = digit[ch] { cur = d }
            else if ch == "十" { total += (cur == 0 ? 1 : cur) * 10; cur = 0 }
            else if ch == "百" { total += (cur == 0 ? 1 : cur) * 100; cur = 0 }
            else { return nil }
        }
        total += cur
        return total > 0 ? total : nil
    }

    /// 一道题额外能被搜到的写法：题号是纯数字时，接在最深一级带序号的章节后面（第2章的第 7 题 →「2.7」）。
    static func exerciseAliases(number: String, chapter: [String]) -> [String] {
        let n = number.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty, n.allSatisfy(\.isNumber) else { return [] }
        guard let ord = chapter.reversed().lazy.compactMap(ordinal(of:)).first else { return [] }
        return ["\(ord).\(n)"]
    }
}
