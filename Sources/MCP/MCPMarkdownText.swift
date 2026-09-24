import Foundation

/// Markdown 笔记给 Agent 读 / 局部改的纯逻辑（`read_markdown` / `edit_markdown`，只依赖 Foundation；
/// spike `mcp-markdown-text-test.swift`）。
///
/// 为什么要局部改（2026-09-24）：原来只有 `update_markdown` 交整篇新正文，17K 字的笔记改一句也要模型
/// 把全文重吐一遍（TODO 里那次 68 秒全花在吐字上）。这里照 code agent 的做法：按**原文精确匹配**替换片段、
/// 或按行号插入；读取按行分页、带行号，另给标题大纲与行内搜索，让 Agent 先找到位置再只读那一段。
///
/// 口径：
/// - **行号 1 起**，按 `\n` 分行；结尾那个换行不算多出一行（`"a\nb\n"` 是 2 行）。`\r` 留在行内，原样返回。
/// - 匹配是**逐码元精确**（`.literal`），不做任何空白 / 大小写 / Unicode 归一——改错位置比报错代价大得多；
///   匹配不上时才用「忽略空白」再找一遍，只拿来写提示，**绝不据此改写**。
enum MCPMarkdownText {

    // MARK: - 行

    /// 分行（去掉结尾换行造成的那个空行）。空串 = 0 行。
    static func lines(_ text: String) -> [Substring] {
        guard !text.isEmpty else { return [] }
        var out = text.split(separator: "\n", omittingEmptySubsequences: false)
        if text.hasSuffix("\n") { out.removeLast() }
        return out
    }

    static func lineCount(_ text: String) -> Int { lines(text).count }

    /// 某个 UTF-16 偏移落在第几行（1 起）。
    static func line(atUTF16 offset: Int, in text: String) -> Int {
        let ns = text as NSString
        let end = min(max(0, offset), ns.length)
        var n = 1, i = 0
        while i < end {
            let r = ns.range(of: "\n", options: .literal, range: NSRange(location: i, length: end - i))
            guard r.location != NSNotFound else { break }
            n += 1
            i = r.location + 1
        }
        return n
    }

    /// 一行在展示里的最大字符数：再长就截断并标出来（Agent 要改那一行时用 `search` 或 `edit_markdown` 的原文片段）。
    static let maxLineDisplay = 4000

    /// `cat -n` 式带行号的一段：`行号\t正文`。
    static func numbered(_ lines: ArraySlice<Substring>, firstLine: Int) -> String {
        let width = max(4, String(firstLine + lines.count).count)
        var out: [String] = []
        out.reserveCapacity(lines.count)
        for (k, l) in lines.enumerated() {
            let n = String(firstLine + k)
            let pad = String(repeating: " ", count: max(0, width - n.count))
            var body = String(l)
            if body.count > maxLineDisplay {
                body = String(body.prefix(maxLineDisplay)) + " … [line truncated, \(l.count) characters]"
            }
            out.append("\(pad)\(n)\t\(body)")
        }
        return out.joined(separator: "\n")
    }

    struct Page {
        var text: String        // 原文片段（不带行号），逐字等于文件里那几行
        var numbered: String    // 带行号的同一段，给模型读
        var startLine: Int      // 1 起；没有内容时为 0
        var endLine: Int        // 含
        var totalLines: Int
        var truncated: Bool     // 后面还有没给的行
    }

    /// 从 `offset`（1 起）读 `limit` 行，另受 `maxChars` 限制（至少给一行）。
    static func page(_ text: String, offset: Int, limit: Int, maxChars: Int) -> Page {
        let all = lines(text)
        guard !all.isEmpty, offset <= all.count else {
            return Page(text: "", numbered: "", startLine: 0, endLine: 0, totalLines: all.count, truncated: false)
        }
        let start = max(1, offset)
        var end = min(all.count, start + max(1, limit) - 1)
        var chars = 0
        for n in start...end {
            chars += all[n - 1].count + 1
            if chars > maxChars, n > start { end = n - 1; break }
        }
        let slice = all[(start - 1)..<end]
        return Page(text: slice.joined(separator: "\n"),
                    numbered: numbered(slice, firstLine: start),
                    startLine: start, endLine: end, totalLines: all.count,
                    truncated: end < all.count)
    }

    // MARK: - 大纲

    struct Heading: Equatable {
        var line: Int
        var level: Int
        var title: String
    }

    /// ATX 标题（`#`…`######`）；跳过围栏代码块（``` / ~~~）与 frontmatter 里的行。
    static func outline(_ text: String) -> [Heading] {
        var out: [Heading] = []
        var fence: String?
        let all = lines(text)
        var i = 0
        // frontmatter：第一行是 `---`，到下一行 `---` 为止
        if all.first.map({ $0.trimmingCharacters(in: .whitespaces) == "---" }) == true {
            i = 1
            while i < all.count, all[i].trimmingCharacters(in: .whitespaces) != "---" { i += 1 }
            i += 1
        }
        while i < all.count {
            let raw = String(all[i])
            let t = raw.trimmingCharacters(in: .whitespaces)
            defer { i += 1 }
            if let f = fence {
                if t.hasPrefix(f) { fence = nil }
                continue
            }
            if t.hasPrefix("```") { fence = "```"; continue }
            if t.hasPrefix("~~~") { fence = "~~~"; continue }
            // 缩进 4 格以上是代码，不是标题
            guard raw.prefix(while: { $0 == " " }).count < 4, t.hasPrefix("#") else { continue }
            let hashes = t.prefix(while: { $0 == "#" }).count
            guard hashes <= 6 else { continue }
            let rest = t.dropFirst(hashes)
            guard rest.isEmpty || rest.first == " " || rest.first == "\t" else { continue }
            var title = rest.trimmingCharacters(in: .whitespaces)
            // 结尾的收尾 `#`（`## 标题 ##`）
            if let r = title.range(of: #"\s+#+$"#, options: .regularExpression) { title.removeSubrange(r) }
            out.append(Heading(line: i + 1, level: hashes, title: title))
        }
        return out
    }

    // MARK: - 搜索

    struct SearchHit: Equatable {
        var line: Int
        var text: String
    }

    /// 行内搜索：哪几行含 `query`（不分大小写 + 不分变音符号，可选区分大小写）。
    static func search(_ text: String, query: String, caseSensitive: Bool, limit: Int) -> (hits: [SearchHit], total: Int) {
        guard !query.isEmpty else { return ([], 0) }
        let opts: String.CompareOptions = caseSensitive ? [] : [.caseInsensitive, .diacriticInsensitive]
        var hits: [SearchHit] = []
        var total = 0
        for (k, l) in lines(text).enumerated() where l.range(of: query, options: opts) != nil {
            total += 1
            if hits.count < limit { hits.append(SearchHit(line: k + 1, text: String(l))) }
        }
        return (hits, total)
    }

    // MARK: - 局部修改

    enum Edit: Equatable {
        /// 把 `old` 换成 `new`。`all == false` 时 `old` 必须**恰好出现一次**。
        case replace(old: String, new: String, all: Bool)
        /// 在第 `afterLine` 行后面插入（0 = 最前面；= 总行数 = 末尾）。`text` 当作整行插入。
        case insert(afterLine: Int, text: String)
    }

    struct EditError: Error, Equatable {
        var index: Int          // 第几条（1 起）
        var message: String
    }

    struct EditResult {
        var text: String
        /// 每条修改替换了几处（insert 恒 1）。
        var counts: [Int]
        /// 改动落在**最终正文**的哪些行（已合并、升序，1 起、含）。只删不增的地方记删除点所在那一行。
        var changedLines: [ClosedRange<Int>]
    }

    /// 依次应用（后一条看到的是前一条改完的正文）；任何一条失败整批不生效。
    static func apply(_ edits: [Edit], to original: String) throws -> EditResult {
        guard !edits.isEmpty else { throw EditError(index: 0, message: "edits is empty") }
        var text = original
        var counts: [Int] = []
        var regions: [NSRange] = []   // 最终正文里被改过的 UTF-16 区间

        /// 这次把 `old`（当时正文里的区间）换成了 `newLength` 长的新内容：已记的区间跟着平移 / 合并。
        func record(_ old: NSRange, newLength: Int) {
            let s = old.location, e = old.location + old.length
            let delta = newLength - old.length
            var merged = NSRange(location: s, length: newLength)
            var next: [NSRange] = []
            for r in regions {
                let rEnd = r.location + r.length
                if rEnd <= s {
                    next.append(r)                                                        // 在前面：不动
                } else if r.location >= e {
                    next.append(NSRange(location: r.location + delta, length: r.length))  // 在后面：整体平移
                } else {
                    // 交叠：前半段坐标不变、中间已被换掉、后半段平移，并成一段
                    let lo = min(r.location, s)
                    let hi = max(s + newLength, rEnd > e ? rEnd + delta : s + newLength)
                    merged = NSRange(location: lo, length: hi - lo)
                }
            }
            next.append(merged)
            regions = next
        }

        for (k, edit) in edits.enumerated() {
            let idx = k + 1
            let ns = text as NSString
            switch edit {
            case let .replace(old, new, all):
                guard !old.isEmpty else {
                    throw EditError(index: idx, message: "old_text is empty; use insert_line to add text")
                }
                guard old != new else {
                    throw EditError(index: idx, message: "old_text and new_text are identical")
                }
                let found = occurrences(of: old, in: ns)
                if found.isEmpty {
                    throw EditError(index: idx, message: notFoundMessage(old, in: text))
                }
                if found.count > 1, !all {
                    let where_ = found.prefix(10).map { String(line(atUTF16: $0.location, in: text)) }.joined(separator: ", ")
                    throw EditError(index: idx, message: "old_text matches \(found.count) places (lines \(where_)\(found.count > 10 ? ", …" : "")); include more surrounding text so it matches exactly one, or set replace_all")
                }
                let newLen = (new as NSString).length
                let m = NSMutableString(string: text)
                // 从后往前换，前面的偏移不受影响；记账时每一处都按「换完之后」的坐标记
                for r in found.reversed() { m.replaceCharacters(in: r, with: new) }
                var shift = 0
                for r in found {
                    record(NSRange(location: r.location + shift, length: r.length), newLength: newLen)
                    shift += newLen - r.length
                }
                text = m as String
                counts.append(found.count)

            case let .insert(afterLine, block):
                let all = lines(text)
                guard afterLine >= 0, afterLine <= all.count else {
                    throw EditError(index: idx, message: "insert_line \(afterLine) is out of range (0…\(all.count))")
                }
                guard !block.isEmpty else { throw EditError(index: idx, message: "new_text is empty") }
                // 插入点 = 第 afterLine+1 行的行首（UTF-16）
                var at = 0
                if afterLine > 0 {
                    for l in all.prefix(afterLine) { at += (String(l) as NSString).length + 1 }
                }
                var ins = block
                if at > ns.length {
                    // 末尾且原文没有结尾换行：先补一个换行再接着写，不给新内容硬加结尾换行
                    at = ns.length
                    ins = "\n" + block
                } else if !ins.hasSuffix("\n") && !text.isEmpty {
                    ins += "\n"   // 整行插入：后面还有内容，或原文以换行结尾（保持这个习惯）
                }
                let insLen = (ins as NSString).length
                text = ns.replacingCharacters(in: NSRange(location: at, length: 0), with: ins)
                record(NSRange(location: at, length: 0), newLength: insLen)
                counts.append(1)
            }
        }
        guard text != original else { throw EditError(index: 0, message: "the edits leave the note unchanged") }

        let finalLines = max(1, lineCount(text))
        var ranges: [ClosedRange<Int>] = []
        for r in regions.sorted(by: { $0.location < $1.location }) {
            let a = line(atUTF16: r.location, in: text)
            // 区间末尾若正好是换行，结束行按换行之前那一行算
            var endOff = r.location + max(0, r.length - 1)
            if r.length == 0 { endOff = r.location }
            let b = max(a, line(atUTF16: endOff, in: text))
            let range = min(a, finalLines)...min(b, finalLines)
            if let last = ranges.last, range.lowerBound <= last.upperBound + 1 {
                ranges[ranges.count - 1] = last.lowerBound...max(last.upperBound, range.upperBound)
            } else {
                ranges.append(range)
            }
        }
        return EditResult(text: text, counts: counts, changedLines: ranges)
    }

    /// 改完后给 Agent 核对用的片段：每处改动前后各带 `context` 行，带行号；相邻的并成一段。
    static func snippet(_ text: String, around ranges: [ClosedRange<Int>], context: Int, maxLines: Int) -> String {
        let all = lines(text)
        guard !all.isEmpty else { return "(the note is now empty)" }
        var blocks: [ClosedRange<Int>] = []
        for r in ranges {
            let a = max(1, r.lowerBound - context), b = min(all.count, r.upperBound + context)
            if let last = blocks.last, a <= last.upperBound + 1 {
                blocks[blocks.count - 1] = last.lowerBound...max(last.upperBound, b)
            } else {
                blocks.append(a...b)
            }
        }
        var out: [String] = []
        var budget = maxLines
        for b in blocks {
            guard budget > 0 else { out.append("…"); break }
            let end = min(b.upperBound, b.lowerBound + budget - 1)
            out.append(numbered(all[(b.lowerBound - 1)..<end], firstLine: b.lowerBound))
            if end < b.upperBound { out.append("…") }
            budget -= end - b.lowerBound + 1
        }
        return out.joined(separator: "\n…\n")
    }

    // MARK: - 私有

    private static func occurrences(of needle: String, in ns: NSString) -> [NSRange] {
        var out: [NSRange] = []
        var i = 0
        while i < ns.length {
            let r = ns.range(of: needle, options: .literal, range: NSRange(location: i, length: ns.length - i))
            guard r.location != NSNotFound else { break }
            out.append(r)
            i = r.location + max(1, r.length)
        }
        return out
    }

    /// 精确匹配失败时的提示。只诊断，不据此修改。
    private static func notFoundMessage(_ old: String, in text: String) -> String {
        var msg = "old_text was not found in the note"
        // 常见错误 ①：把 read_markdown 的行号前缀一起抄进来了
        let prefixed = old.split(separator: "\n", omittingEmptySubsequences: false)
        if !prefixed.isEmpty, prefixed.allSatisfy({ $0.isEmpty || $0.range(of: #"^\s*\d+\t"#, options: .regularExpression) != nil }) {
            return msg + "; it seems to include the line-number prefixes from read_markdown — copy only the text after the tab"
        }
        // 常见错误 ②：空白 / 换行不一样
        if let hit = whitespaceInsensitiveLine(old, in: text) {
            msg += "; a match exists near line \(hit) if whitespace is ignored — copy the exact text (spaces, tabs, line breaks) from read_markdown"
        } else {
            msg += "; the text may have changed — call read_markdown again"
        }
        return msg
    }

    private static func whitespaceInsensitiveLine(_ needle: String, in text: String) -> Int? {
        var flat: [Character] = []
        var lineOf: [Int] = []
        var n = 1
        for c in text {
            if c == "\n" { n += 1 }
            if c.isWhitespace { continue }
            flat.append(c)
            lineOf.append(n)
        }
        let target = Array(needle.filter { !$0.isWhitespace })
        guard !target.isEmpty, target.count <= flat.count else { return nil }
        var i = 0
        while i + target.count <= flat.count {
            if flat[i] == target[0], Array(flat[i..<(i + target.count)]) == target { return lineOf[i] }
            i += 1
        }
        return nil
    }
}
