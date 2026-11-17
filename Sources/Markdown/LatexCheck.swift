import AppKit
import MarkdownEngine

/// Agent 写进来的公式**能不能画出来**（用户 2026-11-17：给 Agent 加 LaTeX 约束，避免写出渲染不了的公式；不支持的命令以后按需要再加）。
///
/// MCP 写入类工具调完之后，把这次传进来的文字里的公式（`$$…$$`、`$…$`）逐条用显示时同一条路（`LatexCompat.rewrite` → SwiftMath）
/// 试排一次；排不出来的列给 Agent，让它当场改成支持的写法（`MCPCatalog.afterWrite`）。只报告、不拦：内容照常写进去。
///
/// 只查带反斜杠或花括号的（不认的命令、括号不配对才会失败）：`$5 和 $10` 这类价格误配成公式也不会被误报。
/// 代码块 / 行内代码 / frontmatter 里的不查（`MarkdownLink.protectedRanges`）。
/// 「排不出来」与显示时同一个判断（`NoteLatexRenderer` 返回 nil = 引擎原样显示源码）。
/// 线程：主线程（SwiftMath 桥读 `NSApp.keyWindow`，同 `NoteLatexRenderer`）。
@MainActor
enum LatexCheck {
    /// 试过能排的公式（避免同一条反复排）。超过上限整个清掉。
    private static var good = Set<String>()

    /// 这段文字里排不出来的公式（原样，按出现顺序、去重）。
    static func unrenderable(in text: String) -> [String] {
        guard text.contains("$") else { return [] }
        var out: [String] = []
        for f in formulas(in: text) where !out.contains(f) && !renders(f) { out.append(f) }
        return out
    }

    /// 公式里出现的、已知 SwiftMath 不认的命令 / 环境（给 Agent 的提示更具体）。名单同 `MCPTools.mathWriting`。
    static func knownUnsupported(in formula: String) -> [String] {
        unsupportedCommands.filter { formula.range(of: "\\\\" + $0 + "(?![A-Za-z])", options: .regularExpression) != nil }
            .map { "\\" + $0 }
        + unsupportedEnvironments.filter { formula.contains("\\begin{\($0)}") }.map { "\\begin{\($0)}" }
    }

    static let unsupportedCommands = ["boxed", "overset", "underset", "stackrel", "xrightarrow", "xleftarrow",
                                      "overbrace", "underbrace", "mathop", "limits", "because", "therefore"]
    static let unsupportedEnvironments = ["array", "align", "align*", "gather", "gather*", "split"]

    private static func renders(_ latex: String) -> Bool {
        if good.contains(latex) { return true }
        // 走显示时的同一个渲染器（含 `LatexCompat` 换写法与中文处理）。🔴 别另开一个 `SwiftMathBridge` 再 `clearCache()`：
        // 几个桥共用同一个磁盘缓存目录，清一次就把正文公式的缓存全抹了。这里排出来的图顺带进了缓存，用户打开时直接用。
        guard NoteLatexRenderer.shared.render(latex: latex, fontSize: 14, theme: .default) != nil else { return false }
        if good.count > 2000 { good.removeAll() }
        good.insert(latex)
        return true
    }

    /// 正文里的公式：`$$…$$`（可跨行）与同一行里的 `$…$`；`\$` 是字面美元符。
    static func formulas(in text: String) -> [String] {
        let ns = text as NSString
        let guarded = MarkdownLink.protectedRanges(text)
        let u = Array(text.utf16)
        let n = u.count
        let dollar: UInt16 = 0x24, backslash: UInt16 = 0x5C, newline: UInt16 = 0x0A
        func isGuarded(_ i: Int) -> Bool { guarded.contains { NSLocationInRange(i, $0) } }
        func escaped(_ i: Int) -> Bool { i > 0 && u[i - 1] == backslash }
        var out: [String] = []
        var i = 0
        while i < n {
            guard u[i] == dollar, !escaped(i), !isGuarded(i) else { i += 1; continue }
            if i + 1 < n, u[i + 1] == dollar {   // 块公式
                var j = i + 2
                while j + 1 < n, !(u[j] == dollar && u[j + 1] == dollar) { j += 1 }
                guard j + 1 < n else { break }
                out.append(ns.substring(with: NSRange(location: i + 2, length: j - i - 2)))
                i = j + 2
                continue
            }
            var j = i + 1   // 行内：同一行里下一个没转义的 `$`
            while j < n, u[j] != newline, !(u[j] == dollar && !escaped(j)) { j += 1 }
            guard j < n, u[j] == dollar else { i = j; continue }
            if j + 1 < n, u[j + 1] == dollar { i = j; continue }   // 撞上块公式的开头：这个 `$` 不成对
            out.append(ns.substring(with: NSRange(location: i + 1, length: j - i - 1)))
            i = j + 1
        }
        return out.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && ($0.contains("\\") || $0.contains("{")) }
    }

    /// 给 Agent 的提示（英文）；没有排不出来的返回 nil。`texts`：这次调用传进来的全部文字参数。
    static func notice(for texts: [String]) -> String? {
        var bad: [String] = []
        for t in texts { for f in unrenderable(in: t) where !bad.contains(f) { bad.append(f) } }
        guard !bad.isEmpty else { return nil }
        let shown = bad.prefix(10).map { f -> String in
            let known = knownUnsupported(in: f)
            let clip = f.count > 160 ? String(f.prefix(160)) + "…" : f
            return "- $\(clip)$" + (known.isEmpty ? "" : " (unsupported: \(known.joined(separator: ", ")))")
        }
        var s = "⚠️ \(bad.count) formula(s) you wrote cannot be drawn by UniReader's math renderer and will show as raw LaTeX source:\n"
            + shown.joined(separator: "\n")
        if bad.count > shown.count { s += "\n… and \(bad.count - shown.count) more" }
        s += "\nThe text was saved as written. Rewrite these formulas now with supported commands (see the math rules: "
            + "no \\boxed, \\overset, \\underset, \\stackrel, \\xrightarrow, \\overbrace, \\underbrace, \\mathop, \\limits, "
            + "\\because, \\therefore, or array / align / gather / split environments; check that braces match), "
            + "using the same tool that wrote them."
        return s
    }
}
