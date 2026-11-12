import Foundation

/// 全工作区搜索的纯文本部分（`SEARCH-PLAN.md`）：归一化、切段、摘要、打分。只依赖 Foundation，
/// `spike/search-text-test.swift` 直接编它。
///
/// **归一化**（建索引与查询同一套）：兼容分解（全角 → 半角，`ﬁ` → `fi`）、小写、**去掉全部空白**。
/// 去空白是为 OCR 文字：一句中文常被换行 / 版面空格切开（「矛盾的普\n遍性」），去掉之后整句照样搜得中；
/// 西文词连在一起（`matrixrank`）不影响按子串找。代价：搜不了「空格本身」，没人这么搜。
enum SearchText {

    /// 归一化后的字符串（建索引、查询都用它）。
    static func normalize(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.utf8.count)
        for c in s { appendFolded(c, to: &out) }
        return out
    }

    /// 同上，另给每个归一化字符对应原文第几个字符（`Character` 下标），摘要要从命中位置回到原文。
    static func normalizeWithMap(_ s: String) -> (norm: [Character], map: [Int]) {
        var norm: [Character] = [], map: [Int] = []
        for (i, c) in s.enumerated() {
            var piece = ""
            appendFolded(c, to: &piece)
            for x in piece { norm.append(x); map.append(i) }
        }
        return (norm, map)
    }

    private static func appendFolded(_ c: Character, to out: inout String) {
        if c.isWhitespace || c == "\u{200B}" || c == "\u{FEFF}" { return }
        if c.isASCII {
            if let a = c.asciiValue, a >= 65, a <= 90 { out.append(Character(UnicodeScalar(a + 32))) } else { out.append(c) }
            return
        }
        for x in String(c).precomposedStringWithCompatibilityMapping.lowercased() where !x.isWhitespace { out.append(x) }
    }

    /// 查询 → 词：空白分开，`"…"` 括起来的算一个词（归一化后本来也不含空白，括号只是让人能写带空格的短语），
    /// 归一化、去空、去重，按出现顺序。
    static func terms(_ query: String) -> [String] {
        var raw: [String] = []
        var cur = "", inQuote = false
        for c in query {
            if c == "\"" || c == "“" || c == "”" {
                if inQuote { raw.append(cur); cur = "" } else if !cur.isEmpty { raw.append(cur); cur = "" }
                inQuote.toggle()
            } else if c.isWhitespace && !inQuote {
                if !cur.isEmpty { raw.append(cur); cur = "" }
            } else {
                cur.append(c)
            }
        }
        if !cur.isEmpty { raw.append(cur) }
        var seen = Set<String>(), out: [String] = []
        for r in raw {
            let n = normalize(r)
            if !n.isEmpty, seen.insert(n).inserted { out.append(n) }
        }
        return out
    }

    // MARK: - 切段

    /// 一段正文（PDF 一页、批注、题目……）切成不超过 `maxChars` 个字符的块：先按空行分段、段太长再按行、
    /// 行还太长就硬切；相邻小段合并到接近上限。返回每块的文字（原样，不归一化）。
    /// 块不宜大：语义检索的本机模型一次只看约 256 个字（`SEARCH-PLAN.md §5`）。
    static func chunks(_ text: String, maxChars: Int = 500) -> [String] {
        let paras = text.components(separatedBy: "\n\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        var pieces: [String] = []
        for p in paras {
            if p.count <= maxChars { pieces.append(p); continue }
            for line in p.split(separator: "\n", omittingEmptySubsequences: true) {
                var l = Substring(line)
                while l.count > maxChars {
                    pieces.append(String(l.prefix(maxChars)))
                    l = l.dropFirst(maxChars)
                }
                if !l.isEmpty { pieces.append(String(l)) }
            }
        }
        var out: [String] = [], cur = ""
        for p in pieces {
            if cur.isEmpty { cur = p }
            else if cur.count + 1 + p.count <= maxChars { cur += "\n" + p }
            else { out.append(cur); cur = p }
        }
        if !cur.isEmpty { out.append(cur) }
        return out
    }

    /// Markdown 正文切块：每块记**起始行号**（1 起）与所在标题，Agent 拿去 `read_markdown offset=`。
    /// 标题行开新块；块内超过 `maxChars` 也开新块（在行边界上）。frontmatter 当普通文字（里面的 tags / aliases 也值得搜）。
    static func markdownChunks(_ text: String, maxChars: Int = 500) -> [(line: Int, heading: String, text: String)] {
        var out: [(Int, String, String)] = []
        var start = 1, heading = "", cur: [Substring] = [], size = 0
        func flush() {
            let body = cur.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !body.isEmpty { out.append((start, heading, body)) }
            cur = []; size = 0
        }
        var inFence = false
        for (i, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("```") || t.hasPrefix("~~~") { inFence.toggle() }
            let isHeading = !inFence && t.hasPrefix("#") && t.drop(while: { $0 == "#" }).first == " "
            if isHeading || (size + line.count > maxChars && !cur.isEmpty) {
                flush()
                start = i + 1
                if isHeading { heading = String(t.drop(while: { $0 == "#" })).trimmingCharacters(in: .whitespaces) }
            }
            if cur.isEmpty { start = i + 1 }
            var l = line
            while l.count > maxChars {            // 单行超长（整段没换行的长文）：硬切
                cur.append(l.prefix(maxChars)); flush(); start = i + 1
                l = l.dropFirst(maxChars)
            }
            cur.append(l); size += l.count + 1
        }
        flush()
        return out
    }

    // MARK: - 摘要与打分

    /// 命中处前后各 `radius` 个字的摘要（原文，换行压成空格），命中的词用 `[` `]` 括起来；没找到就取开头。
    static func snippet(_ body: String, terms: [String], radius: Int = 60) -> String {
        let chars = Array(body)
        let (norm, map) = normalizeWithMap(body)
        var hit: (start: Int, end: Int)?   // 原文字符下标，含首不含尾
        for t in terms.sorted(by: { $0.count > $1.count }) {
            if let r = firstRange(of: Array(t), in: norm) {
                let s = map[r.lowerBound], e = map[r.upperBound - 1] + 1
                if hit == nil || s < hit!.start { hit = (s, e) }
            }
        }
        func clean(_ s: ArraySlice<Character>) -> String {
            String(s).replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
        }
        guard let hit else {
            let head = chars.prefix(radius * 2)
            return clean(head) + (chars.count > head.count ? "…" : "")
        }
        let a = max(0, hit.start - radius), b = min(chars.count, hit.end + radius)
        return (a > 0 ? "…" : "") + clean(chars[a..<hit.start]) + "[" + clean(chars[hit.start..<hit.end]) + "]"
            + clean(chars[hit.end..<b]) + (b < chars.count ? "…" : "")
    }

    static func firstRange(of needle: [Character], in hay: [Character]) -> Range<Int>? {
        guard !needle.isEmpty, needle.count <= hay.count else { return nil }
        let first = needle[0]
        var i = 0
        while i <= hay.count - needle.count {
            if hay[i] == first {
                var ok = true
                for j in 1..<needle.count where hay[i + j] != needle[j] { ok = false; break }
                if ok { return i..<(i + needle.count) }
            }
            i += 1
        }
        return nil
    }

    /// 一个词在归一化文本里出现几次（不重叠）。
    static func count(_ term: String, in norm: String) -> Int {
        guard !term.isEmpty else { return 0 }
        var n = 0
        var range = norm.startIndex..<norm.endIndex
        while let r = norm.range(of: term, range: range) {
            n += 1
            range = r.upperBound..<norm.endIndex
        }
        return n
    }

    /// 打分（越大越靠前）：每个词按「出现次数取对数 × 稀有度」累加，标题里出现再加；命中的词越全越好；
    /// 块越长略微压一点（长页面天然词多）。`df[t]` = 候选里含这个词的块数，`n` = 候选总数。
    static func score(norm: String, titleNorm: String, terms: [String], df: [String: Int], n: Int) -> Double {
        var s = 0.0, matched = 0
        for t in terms {
            let tf = count(t, in: norm)
            let inTitle = titleNorm.contains(t)
            guard tf > 0 || inTitle else { continue }
            matched += 1
            let idf = log(1 + Double(n + 1) / Double((df[t] ?? 0) + 1))
            s += (tf > 0 ? (1 + log(Double(tf))) : 0) * idf
            if inTitle { s += 0.8 * idf }
        }
        guard matched > 0 else { return 0 }
        let coverage = Double(matched) / Double(max(terms.count, 1))
        let lengthNorm = 1 + 0.15 * log(1 + Double(norm.count) / 300)
        return s * coverage * coverage / lengthNorm
    }
}
