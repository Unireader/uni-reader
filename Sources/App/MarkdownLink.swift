import Foundation

/// Obsidian 风格的 Markdown 链接：**只扫描，不改写**（`MARKDOWN-NOTES-PLAN.md §4.3` 改版）。
///
/// 🔴 **2026-09-20 用户定：文件里的 `[[…]]` 一个字都不许改**（原话「不要改 `[[]]` 现有的哪怕不兼容也不要改」）。
/// 第一批那套「导入时把 `[[名字]]` 补成 `[[名字|<id>]]`」整段删除，连带别名 / 锚点的降级、
/// 图片名的内容寻址改写也一并删掉。**导入 = 纯复制**。
///
/// 于是链接改成按**名字**解析（`NoteIndex`）。代价是 Obsidian 本来就有的代价：笔记改名 / 挪目录，
/// 指向它的链接就断——用户明确接受（「哪怕不兼容也不要改」）。
///
/// 好消息是引擎**不会自己往文件里加 id**：`WikiLinkService.makeStorageState` 只把文件里本来就有的
/// `|id` 原样写回去（那个 id 取自 `.wikiLinkID` 属性，而该属性是从**存储文本的竖线后缀**解析出来的，
/// 不是问 resolver 要的）。文件里是 `[[名字]]`，编辑存盘之后还是 `[[名字]]`；`resolve()` 只决定
/// 这个链接画成可点还是断链。
///
/// 只依赖 Foundation，`spike/markdown-link-test.swift` 直接编它。
enum MarkdownLink {

    /// 认得的图片扩展名（`![[…]]` 里出现它就按附件处理，不去当笔记解析）。
    static let imageExts: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic", "heif",
                                         "tif", "tiff", "bmp", "svg", "avif"]

    /// 正文里引用到的**笔记名**（`[[…]]` 的目标段，去掉锚点与别名），去重、按出现顺序。
    /// 保护区（代码块 / 行内代码 / frontmatter）里的不算；图片嵌入归 `imageReferences`。
    static func wikiReferences(_ text: String) -> [String] {
        let ns = text as NSString
        let guarded = protectedRanges(text)
        var seen = Set<String>()
        var out: [String] = []
        for m in wikiRegex.matches(in: text, range: ns.fullRange)
        where !guarded.contains(where: { NSIntersectionRange($0, m.range).length > 0 }) {
            let isEmbed = ns.substring(with: m.range).hasPrefix("!")
            let parts = WikiParts(ns.substring(with: m.range(at: 1)))
            if isEmbed, let ext = parts.target.pathExtension, imageExts.contains(ext.lowercased()) { continue }
            let k = parts.target
            guard !k.isEmpty, !seen.contains(k) else { continue }
            seen.insert(k)
            out.append(k)
        }
        return out
    }


    // MARK: - 语法零件

    /// `[[…]]` / `![[…]]`。内层不许含 `[`、`]` 与换行（与引擎的 `storagePattern` 同口径）。
    static let wikiRegex = try! NSRegularExpression(pattern: #"!?\[\[([^\[\]\r\n]*)\]\]"#)
    /// `[文字](目标)` / `![文字](目标)`。目标不含空白与右括号（带空格的目标要写成 `<…>`，这里不碰）。
    static let inlineLinkRegex = try! NSRegularExpression(pattern: #"!?\[([^\[\]\r\n]*)\]\(([^()\s]*)\)"#)

    /// `[[目标#锚点|别名]]` 拆成三段。竖线只认第一个，锚点只认目标段里的第一个 `#`。
    struct WikiParts: Equatable {
        var target: String
        var anchor: String?
        var afterPipe: String?

        init(_ inner: String) {
            var head = inner
            if let i = inner.firstIndex(of: "|") {
                head = String(inner[inner.startIndex..<i])
                afterPipe = String(inner[inner.index(after: i)...])
            }
            if let i = head.firstIndex(of: "#") {
                anchor = String(head[head.index(after: i)...]).replacingOccurrences(of: "^", with: "")
                head = String(head[head.startIndex..<i])
            }
            target = head.trimmed
        }
    }

    private static func hasScheme(_ s: String) -> Bool {
        guard let i = s.firstIndex(of: ":") else { return false }
        let scheme = s[s.startIndex..<i]
        return !scheme.isEmpty && scheme.allSatisfy { $0.isLetter || $0.isNumber || $0 == "+" || $0 == "-" || $0 == "." }
    }
    private static func splitAnchor(_ s: String) -> (String, String?) {
        guard let i = s.firstIndex(of: "#") else { return (s, nil) }
        return (String(s[s.startIndex..<i]), String(s[s.index(after: i)...]))
    }
    private static func dropExtension(_ s: String) -> String {
        guard let ext = s.pathExtension, !ext.isEmpty else { return s }
        return String(s.dropLast(ext.count + 1))
    }

    // MARK: - 保护区（🔴 这里面的东西一个字都不许改）

    /// frontmatter + 围栏代码块 + 行内代码 的字符区间（已按起点排序、互不重叠）。
    static func protectedRanges(_ text: String) -> [NSRange] {
        let ns = text as NSString
        var out: [NSRange] = []

        // ① frontmatter：**必须从第一行**的 `---` 开始，到下一个单独成行的 `---` / `...` 为止
        if let fm = frontmatterRange(ns) { out.append(fm) }

        // ② 围栏代码块：行首（最多 3 个空格缩进）连续 ≥3 个 ` 或 ~，到同种、不短于它的收尾栏为止；
        //    没有收尾栏就一直到文末（同 CommonMark）。
        var fenceStart: Int?           // 当前开着的代码块的起点
        var fenceChar: Character = "`"
        var fenceLen = 0
        ns.enumerateSubstrings(in: ns.fullRange, options: [.byLines]) { line, _, enclosing, _ in
            guard let line, let f = Self.fenceInfo(line) else { return }
            if let start = fenceStart {
                guard f.char == fenceChar, f.len >= fenceLen, f.info.isEmpty else { return }
                out.append(NSRange(location: start, length: NSMaxRange(enclosing) - start))
                fenceStart = nil
            } else {
                fenceStart = enclosing.location
                fenceChar = f.char
                fenceLen = f.len
            }
        }
        if let start = fenceStart { out.append(NSRange(location: start, length: ns.length - start)) }

        // ③ 行内代码：n 个反引号 … n 个反引号（同一段落内）。落在已保护区里的跳过。
        for r in inlineCodeRanges(ns) where !out.contains(where: { NSIntersectionRange($0, r).length > 0 }) {
            out.append(r)
        }

        return out.sorted { $0.location < $1.location }
    }

    private static func frontmatterRange(_ ns: NSString) -> NSRange? {
        guard ns.length >= 3 else { return nil }
        let first = ns.substring(to: min(4, ns.length))
        guard first.hasPrefix("---"), first.count == 3 || first[first.index(first.startIndex, offsetBy: 3)].isNewline
        else { return nil }
        var end: Int?
        var lineNo = 0
        ns.enumerateSubstrings(in: ns.fullRange, options: [.byLines]) { line, _, enclosing, stop in
            defer { lineNo += 1 }
            guard lineNo > 0 else { return }
            let t = (line ?? "").trimmed
            if t == "---" || t == "..." { end = NSMaxRange(enclosing); stop.pointee = true }
        }
        return end.map { NSRange(location: 0, length: $0) }
    }

    /// 这一行是不是围栏。返回（栏字符, 长度, 语言/信息串）。
    private static func fenceInfo(_ line: String) -> (char: Character, len: Int, info: String)? {
        var s = Substring(line)
        var indent = 0
        while let c = s.first, c == " ", indent < 3 { s = s.dropFirst(); indent += 1 }
        guard let c = s.first, c == "`" || c == "~" else { return nil }
        let len = s.prefix { $0 == c }.count
        guard len >= 3 else { return nil }
        let info = s.dropFirst(len).trimmed
        // ``` 行内代码里的反引号串不会带 info 且不在行首成栏——这里只认行首，够了
        if c == "`", info.contains("`") { return nil }
        return (c, len, info)
    }

    private static func inlineCodeRanges(_ ns: NSString) -> [NSRange] {
        var out: [NSRange] = []
        var i = 0
        let n = ns.length
        while i < n {
            guard ns.character(at: i) == 0x60 else { i += 1; continue }   // `
            var j = i
            while j < n, ns.character(at: j) == 0x60 { j += 1 }
            let openLen = j - i
            // 找同样长度的收尾串；中途遇到空行（段落结束）就放弃
            var k = j
            var closed = false
            while k < n {
                let ch = ns.character(at: k)
                if ch == 0x0A, k + 1 < n, ns.character(at: k + 1) == 0x0A { break }
                if ch == 0x60 {
                    var m = k
                    while m < n, ns.character(at: m) == 0x60 { m += 1 }
                    if m - k == openLen {
                        out.append(NSRange(location: i, length: m - i))
                        i = m
                        closed = true
                        break
                    }
                    k = m
                    continue
                }
                k += 1
            }
            if !closed { i = j }
        }
        return out
    }

    // MARK: - 扫描（导入时先问「这篇引了哪些附件」）

    /// 正文里引用到的图片附件名（`![[图.png]]` 与 `![](子目录/图.png)` 两种写法），去重、按出现顺序。
    /// 保护区里的不算。相对 URL 已做百分号解码；绝对 URL（http/file/…）不算附件。
    static func imageReferences(_ text: String) -> [String] {
        let ns = text as NSString
        let guarded = protectedRanges(text)
        func isGuarded(_ r: NSRange) -> Bool { guarded.contains { NSIntersectionRange($0, r).length > 0 } }
        var seen = Set<String>()
        var out: [String] = []
        func add(_ s: String) {
            let k = s.trimmed
            guard !k.isEmpty, !seen.contains(k) else { return }
            seen.insert(k); out.append(k)
        }
        for m in wikiRegex.matches(in: text, range: ns.fullRange) where !isGuarded(m.range) {
            guard ns.substring(with: m.range).hasPrefix("!") else { continue }
            let parts = WikiParts(ns.substring(with: m.range(at: 1)))
            if let ext = parts.target.pathExtension, imageExts.contains(ext.lowercased()) { add(parts.target) }
        }
        for m in inlineLinkRegex.matches(in: text, range: ns.fullRange) where !isGuarded(m.range) {
            guard ns.substring(with: m.range).hasPrefix("!") else { continue }
            let dest = ns.substring(with: m.range(at: 2))
            guard !dest.isEmpty, !hasScheme(dest) else { continue }
            let path = splitAnchor(dest).0
            let decoded = path.removingPercentEncoding ?? path
            if let ext = decoded.pathExtension, imageExts.contains(ext.lowercased()) { add(decoded) }
        }
        return out
    }

    // MARK: - frontmatter 的 aliases（进解析索引）

    /// frontmatter 里的 `aliases:` —— 行内数组 `[a, b]` 与 `- a` 列表两种写法都认。
    /// 不引 YAML 库：笔记的 frontmatter 就这么点东西，为它加个依赖不值。
    static func frontmatterAliases(_ text: String) -> [String] {
        let ns = text as NSString
        guard let fm = frontmatterRange(ns) else { return [] }
        var out: [String] = []
        var inList = false
        for raw in ns.substring(with: fm).components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line == "---" || line == "..." { continue }
            if inList {
                if line.hasPrefix("- ") {
                    out.append(unquote(String(line.dropFirst(2))))
                    continue
                }
                inList = false
            }
            guard let i = line.firstIndex(of: ":") else { continue }
            let key = line[line.startIndex..<i].trimmed.lowercased()
            guard key == "aliases" || key == "alias" else { continue }
            let value = line[line.index(after: i)...].trimmed
            if value.isEmpty { inList = true; continue }
            if value.hasPrefix("["), value.hasSuffix("]") {
                out += value.dropFirst().dropLast().components(separatedBy: ",")
                    .map { unquote($0.trimmed) }.filter { !$0.isEmpty }
            } else {
                out.append(unquote(value))
            }
        }
        return out.filter { !$0.isEmpty }
    }

    private static func unquote(_ s: String) -> String {
        let t = s.trimmed
        for q in ["\"", "'"] where t.count >= 2 && t.hasPrefix(q) && t.hasSuffix(q) {
            return String(t.dropFirst().dropLast())
        }
        return t
    }
}

// MARK: - 小工具

extension StringProtocol {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
    /// 末段 `.` 后面的东西（没有点、点在开头、点后面还有 `/` 都算没有扩展名）。
    var pathExtension: String? {
        guard let last = split(separator: "/").last, let dot = last.lastIndex(of: "."),
              dot != last.startIndex, last.index(after: dot) < last.endIndex else { return nil }
        return String(last[last.index(after: dot)...])
    }
}

extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}

extension NSString {
    var fullRange: NSRange { NSRange(location: 0, length: length) }
}
