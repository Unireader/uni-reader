import Foundation

/// Markdown 笔记的标题目录：只认标准 `#`（ATX）标题，一到六级。
///
/// 只读扫描、不改正文（红线 9）。规则：
///  · 行首最多 3 个空格，`#` 后必须跟空白（`#tag` 不算标题）；末尾的 `#` 闭合符去掉；
///  · 围栏代码块（``` / ~~~）里的 `#` 不算；
///  · 开头的 frontmatter（`---` … `---`）里的不算。
/// 只依赖 Foundation。
struct MarkdownHeading: Equatable {
    let level: Int
    let title: String
    /// 在正文里是第几行（0 起）。
    let line: Int
}

enum MarkdownOutline {
    static func headings(in text: String) -> [MarkdownHeading] {
        var out: [MarkdownHeading] = []
        var fence: (char: Character, count: Int)?
        var lineNo = -1
        var inFrontmatter = false
        for sub in text.split(separator: "\n", omittingEmptySubsequences: false) {
            lineNo += 1
            let line = sub.hasSuffix("\r") ? sub.dropLast() : sub
            if lineNo == 0, line.trimmingCharacters(in: .whitespaces) == "---" { inFrontmatter = true; continue }
            if inFrontmatter {
                let t = line.trimmingCharacters(in: .whitespaces)
                if t == "---" || t == "..." { inFrontmatter = false }
                continue
            }
            let body = line.drop(while: { $0 == " " })
            let indent = line.count - body.count
            if let f = fence {
                if indent <= 3, let c = body.first, c == f.char {
                    let n = body.prefix(while: { $0 == c }).count
                    if n >= f.count, body.dropFirst(n).allSatisfy({ $0 == " " }) { fence = nil }
                }
                continue
            }
            if indent <= 3, let c = body.first, c == "`" || c == "~" {
                let n = body.prefix(while: { $0 == c }).count
                if n >= 3 { fence = (c, n); continue }
            }
            guard indent <= 3, body.first == "#" else { continue }
            let hashes = body.prefix(while: { $0 == "#" }).count
            guard (1...6).contains(hashes) else { continue }
            let rest = body.dropFirst(hashes)
            guard rest.isEmpty || rest.first == " " || rest.first == "\t" else { continue }
            var title = rest.trimmingCharacters(in: .whitespaces)
            // 闭合符：末尾那串 `#` 前面是空白（或整个标题就是 `#`）才去掉
            if let r = title.range(of: #"(^|\s)#+$"#, options: .regularExpression) {
                title = String(title[..<r.lowerBound]).trimmingCharacters(in: .whitespaces)
            }
            out.append(MarkdownHeading(level: hashes, title: title, line: lineNo))
        }
        return out
    }
}

/// 目录树节点（按级别嵌套：级别跳着写也行，如 `#` 后面直接 `###`）。
final class MarkdownOutlineNode: NSObject {
    let heading: MarkdownHeading
    /// 在 `headings(in:)` 结果里的序号——点了跳转时按它对回编辑区里的第几个标题。
    let ordinal: Int
    weak var parent: MarkdownOutlineNode?
    var children: [MarkdownOutlineNode] = []
    init(_ h: MarkdownHeading, ordinal: Int) { heading = h; self.ordinal = ordinal }

    static func tree(from headings: [MarkdownHeading]) -> [MarkdownOutlineNode] {
        var roots: [MarkdownOutlineNode] = []
        var stack: [MarkdownOutlineNode] = []
        for (i, h) in headings.enumerated() {
            let n = MarkdownOutlineNode(h, ordinal: i)
            while let last = stack.last, last.heading.level >= h.level { stack.removeLast() }
            if let p = stack.last { n.parent = p; p.children.append(n) } else { roots.append(n) }
            stack.append(n)
        }
        return roots
    }
}
