import AppKit
import Foundation

/// 笔记正文是 **Markdown 源**（编辑器与页面气泡都用 `swift-markdown-engine` 画，见 `MarkdownNoteEditor` /
/// `MarkdownNoteReader`）。这里是**不经引擎**的两样轻量折算：
///  · `plain()`：去掉记号只留文字——Inspector 列表、图钉悬停提示这类只要一行字的地方；
///  · `nsAttributed()`：给气泡第一帧**估高度**用（引擎排完版才报真实高度，之前得先占个位），
///    行内样式落成字体特征（粗/斜/等宽），块级做近似（标题 → 粗体行、列表 → 「• 」、任务 → ☐/☑、引用 → 「│ 」、
///    围栏去掉、水平线 → 横线），与引擎的排版八九不离十。
///  `attributed()` 是这两样的中间产物（Foundation 的 `inlineOnly` 解析），视图不直接用它画了。
///
/// 纯函数，`spike/note-markdown-test.swift` 覆盖。
enum NoteMarkdown {

    /// 气泡用：折算块级语法 + 解析行内样式。解析失败（理论上不会）退回原文。
    static func attributed(_ source: String) -> AttributedString {
        let folded = foldBlocks(source)
        let opts = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: false,
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible)
        return (try? AttributedString(markdown: folded, options: opts)) ?? AttributedString(folded)
    }

    /// 列表 / 提示条用：去掉语法记号只留文字（标题记号、列表记号、强调记号、链接只留文字）。
    static func plain(_ source: String) -> String {
        String(attributed(source).characters)
    }

    /// 量高度用：与 `attributed` 同一份内容，但把行内样式落成 `NSFont` 特征（粗/斜/等宽），
    /// TextKit 量出来的才是 SwiftUI 画出来的那个高度（粗体略宽，差一个字就差一行）。
    static func nsAttributed(_ source: String, font: NSFont, lineSpacing: CGFloat) -> NSAttributedString {
        let a = attributed(source)
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byWordWrapping
        para.lineSpacing = lineSpacing
        let out = NSMutableAttributedString(string: String(a.characters),
                                            attributes: [.font: font, .paragraphStyle: para])
        for run in a.runs {
            guard let intent = run.inlinePresentationIntent else { continue }
            let range = NSRange(run.range, in: a)
            var f = font
            if intent.contains(.code) {
                f = NSFont.monospacedSystemFont(ofSize: font.pointSize * 0.9, weight: .regular)
            }
            var traits: NSFontTraitMask = []
            if intent.contains(.stronglyEmphasized) { traits.insert(.boldFontMask) }
            if intent.contains(.emphasized) { traits.insert(.italicFontMask) }
            if !traits.isEmpty { f = NSFontManager.shared.convert(f, toHaveTrait: traits) }
            out.addAttribute(.font, value: f, range: range)
            if intent.contains(.strikethrough) {
                out.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: range)
            }
        }
        return out
    }

    // MARK: - 自然宽度（短文按内容收窄用）

    /// 逐行**不折行**排出来的最宽那一行有多宽（含块级结构占的地方：标题放大、列表缩进、引用竖条）。
    /// 气泡拿它在设置的最小/最大宽度之间收窄——短笔记不再一律满宽。
    /// 这是估计值（真正排版的是引擎），调用方加点余量；估窄了顶多多折一行，不会溢出。
    ///  - `headingScales`：一到六级标题的字号倍率（与 `MarkdownNoteEditor.applyNoteTypography` 同一份）
    ///  - `listIndent`：列表每级缩进
    static func naturalWidth(_ source: String, font: NSFont,
                             headingScales: [CGFloat] = [1.4, 1.25, 1.12, 1.05, 1.0, 1.0],
                             listIndent: CGFloat = 16) -> CGFloat {
        var widest: CGFloat = 0
        var inFence = false
        for raw in source.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") { inFence.toggle(); continue }
            guard !trimmed.isEmpty else { continue }
            let ns = line as NSString
            let all = NSRange(location: 0, length: ns.length)
            var f = font
            var extra: CGFloat = 0
            var body = line
            if inFence {
                f = NSFont.monospacedSystemFont(ofSize: font.pointSize * 0.9, weight: .regular)
            } else if let m = heading.firstMatch(in: line, range: all) {
                let level = max(1, min(6, ns.substring(with: m.range(at: 0)).prefix { $0 == "#" || $0 == " " }
                                          .filter { $0 == "#" }.count))
                let scale = headingScales.indices.contains(level - 1) ? headingScales[level - 1] : 1
                f = NSFontManager.shared.convert(NSFont.systemFont(ofSize: font.pointSize * scale), toHaveTrait: .boldFontMask)
                body = ns.substring(with: m.range(at: 1))
            } else if let m = task.firstMatch(in: line, range: all) {
                extra = listIndent * CGFloat(1 + ns.substring(with: m.range(at: 1)).count / 2) + f.pointSize * 1.6   // 缩进 + 勾选框
                body = ns.substring(with: m.range(at: 3))
            } else if let m = bullet.firstMatch(in: line, range: all) {
                extra = listIndent * CGFloat(1 + ns.substring(with: m.range(at: 1)).count / 2)
                body = ns.substring(with: m.range(at: 2))
            } else if let m = quote.firstMatch(in: line, range: all) {
                extra = f.pointSize * 1.2   // 竖条 + 间隙
                body = ns.substring(with: m.range(at: 1))
            } else if rule.firstMatch(in: line, range: all) != nil {
                continue   // 水平线有多宽算多宽，不撑气泡
            }
            let w = nsAttributed(inFence ? "`\(body)`" : body, font: f, lineSpacing: 0).size().width
            widest = max(widest, w.rounded(.up) + extra)
        }
        return widest
    }

    // MARK: - 块级折算

    /// 逐行把块级记号换成能进 `inlineOnly` 解析的形态。围栏代码块里的行原样保留、外面包一对反引号
    /// （行里本来就有反引号的不包，宁可露出星号也别把整行吞成代码）。
    static func foldBlocks(_ source: String) -> String {
        var out: [String] = []
        var inFence = false
        for raw in source.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                inFence.toggle()
                continue
            }
            if inFence {
                out.append(line.contains("`") || line.isEmpty ? line : "`\(line)`")
                continue
            }
            out.append(foldLine(line))
        }
        return out.joined(separator: "\n")
    }

    private static let heading = try! NSRegularExpression(pattern: #"^\s{0,3}#{1,6}\s+(.*?)\s*#*\s*$"#)
    private static let task = try! NSRegularExpression(pattern: #"^(\s*)[-*+]\s+\[( |x|X)\]\s+(.*)$"#)
    private static let bullet = try! NSRegularExpression(pattern: #"^(\s*)[-*+]\s+(.*)$"#)
    private static let quote = try! NSRegularExpression(pattern: #"^\s{0,3}>\s?(.*)$"#)
    private static let rule = try! NSRegularExpression(pattern: #"^\s{0,3}([-*_])(\s*\1){2,}\s*$"#)

    private static func foldLine(_ line: String) -> String {
        let ns = line as NSString
        let all = NSRange(location: 0, length: ns.length)
        if let m = heading.firstMatch(in: line, range: all) {
            let t = ns.substring(with: m.range(at: 1))
            return t.isEmpty ? "" : "**\(t)**"
        }
        // 水平线要排在列表前面：`- - -` 也能匹配无序列表那条
        if rule.firstMatch(in: line, range: all) != nil {
            return "———"
        }
        if let m = task.firstMatch(in: line, range: all) {
            let done = ns.substring(with: m.range(at: 2)).lowercased() == "x"
            return ns.substring(with: m.range(at: 1)) + (done ? "☑ " : "☐ ") + ns.substring(with: m.range(at: 3))
        }
        if let m = bullet.firstMatch(in: line, range: all) {
            return ns.substring(with: m.range(at: 1)) + "• " + ns.substring(with: m.range(at: 2))
        }
        if let m = quote.firstMatch(in: line, range: all) {
            return "│ " + ns.substring(with: m.range(at: 1))
        }
        return line
    }
}
