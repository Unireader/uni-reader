import Foundation

/// Agent 面板正文里的「大块」：右键点在哪一块上（`AgentMarkdownView` 的右键菜单据此加「复制表格 / 复制代码」）。
///
/// 🔴 认块的规则照抄引擎的 `BlockParser`（swift-markdown-engine），两边不一致就会「看着是表格、右键却不认」：
///  · 代码块：行首（不许缩进）是 ``` 开头，往下第一行同样 ``` 开头的是收尾；**没收尾的不算代码块**（引擎当普通段落）；
///  · 表格：去掉首尾空白后 `|` 开头 `|` 结尾、至少 3 个字符的一行，紧跟一行分隔行（首尾 `|`、中间只有 `- : |` 与空白），
///    再往下连续的 `|…|` 行都是它的数据行。
/// 其余块（标题 / 列表 / 引用……）不会以 ``` 或 `|` 开头，逐行往下走就够了，不必照搬它们的分组。
///
/// 纯 Foundation，spike `agent-markdown-blocks-test.swift` 直接编它。
struct AgentMarkdownBlock: Equatable {
    enum Kind: Equatable {
        /// 围栏上写的语言（没写为 nil）。
        case code(language: String?)
        case table
    }

    let kind: Kind
    /// 整块（代码块含两行围栏；表格含表头、分隔行与全部数据行），UTF-16，不含最后一行的换行。
    let range: NSRange
    /// 要复制的部分：代码块 = 两行围栏之间（不含最后的换行），表格 = 整块。
    let content: NSRange

    /// `index`（UTF-16，右键点中的字符位置）落在哪一块里；块尾那个位置（最后一行行末）也算。
    static func block(at index: Int, in text: String) -> AgentMarkdownBlock? {
        let ns = text as NSString
        guard index >= 0, index <= ns.length else { return nil }
        let lines = lineRanges(ns)
        func line(_ i: Int) -> String { ns.substring(with: lines[i].body) }

        var i = 0
        while i < lines.count {
            let s = line(i)
            if s.hasPrefix("```"), let end = (i + 1 ..< lines.count).first(where: { line($0).hasPrefix("```") }) {
                if let b = make(.code(language: language(of: s)), first: i, last: end, lines: lines), contains(b, index) {
                    return b
                }
                i = end + 1
            } else if isTableRow(s), i + 1 < lines.count, isTableSeparator(line(i + 1)) {
                var end = i + 1
                while end + 1 < lines.count, isTableRow(line(end + 1)) { end += 1 }
                if let b = make(.table, first: i, last: end, lines: lines), contains(b, index) { return b }
                i = end + 1
            } else {
                i += 1
            }
        }
        return nil
    }

    // MARK: - 内部

    private struct Line {
        /// 整行（含换行符）。
        let full: NSRange
        /// 去掉换行符的正文。
        let body: NSRange
    }

    private static func lineRanges(_ ns: NSString) -> [Line] {
        var out: [Line] = []
        var start = 0
        while start < ns.length {
            var lineStart = 0, lineEnd = 0, contentsEnd = 0
            ns.getLineStart(&lineStart, end: &lineEnd, contentsEnd: &contentsEnd, for: NSRange(location: start, length: 0))
            out.append(Line(full: NSRange(location: lineStart, length: lineEnd - lineStart),
                            body: NSRange(location: lineStart, length: contentsEnd - lineStart)))
            start = lineEnd
        }
        return out
    }

    private static func make(_ kind: Kind, first: Int, last: Int, lines: [Line]) -> AgentMarkdownBlock? {
        let start = lines[first].body.location
        let range = NSRange(location: start, length: NSMaxRange(lines[last].body) - start)
        switch kind {
        case .table:
            return AgentMarkdownBlock(kind: kind, range: range, content: range)
        case .code:
            // 两行围栏之间：从开头围栏的下一行起，到收尾围栏的上一行行末（不含它的换行）
            let from = NSMaxRange(lines[first].full)
            let to = last > first + 1 ? NSMaxRange(lines[last - 1].body) : from
            return AgentMarkdownBlock(kind: kind, range: range, content: NSRange(location: from, length: max(0, to - from)))
        }
    }

    private static func contains(_ b: AgentMarkdownBlock, _ index: Int) -> Bool {
        index >= b.range.location && index <= NSMaxRange(b.range)
    }

    private static func language(of fence: String) -> String? {
        let s = fence.dropFirst(3).trimmingCharacters(in: .whitespaces)
        let word = s.split(whereSeparator: { $0 == " " || $0 == "\t" }).first.map(String.init) ?? ""
        return word.isEmpty ? nil : word
    }

    /// 同引擎 `BlockParser.isTableRow`。
    private static func isTableRow(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.count >= 3 && t.hasPrefix("|") && t.hasSuffix("|")
    }

    /// 同引擎 `BlockParser.isTableSeparator`。
    private static func isTableSeparator(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count >= 3, t.hasPrefix("|"), t.hasSuffix("|") else { return false }
        let middle = t.dropFirst().dropLast()
        return !middle.isEmpty && middle.allSatisfy { $0 == "-" || $0 == ":" || $0 == "|" || $0 == " " || $0 == "\t" }
    }
}
