import Foundation

/// Markdown 笔记的「属性」= 文件开头的 YAML frontmatter（Obsidian 叫 Properties，Jekyll / Hugo 等同一写法）：
///
///     ---
///     progress: 60%
///     status: 在读
///     ---
///
/// 只认顶层 `键: 值`；值是列表 / 多行 / 嵌套的键只读显示、**不改写**（红线 9：不碰没被用户动的内容）。
/// 改一个键只替换那一行，别的字一个不动。不引 YAML 库（同 `MarkdownLink` 的 aliases）。只依赖 Foundation。
enum MarkdownProperties {
    struct Entry: Equatable {
        let key: String
        /// 显示用的值（标量去掉成对引号；多行 / 列表按行拼起来）。
        let value: String
        /// 只有「一行标量」可以在界面里改。
        let editable: Bool
        /// 在正文里占的行：`line ..< line + count`（0 起）。
        let line: Int
        let count: Int
    }

    /// 解析开头的 frontmatter；没有就返回空。
    static func entries(in text: String) -> [Entry] {
        let lines = text.components(separatedBy: "\n")
        guard let close = closingLine(lines) else { return [] }
        var out: [Entry] = []
        var i = 1
        while i < close {
            let raw = strip(lines[i])
            if let (k, v) = split(raw) {
                var j = i + 1
                var extra: [String] = []
                while j < close, isContinuation(strip(lines[j])) { var t = strip(lines[j]).trimmingCharacters(in: .whitespaces)
                    if t.hasPrefix("- ") { t = unquote(String(t.dropFirst(2)).trimmingCharacters(in: .whitespaces)) }   // 列表项去掉 `- `
                    extra.append(t); j += 1
                }
                if extra.isEmpty {
                    out.append(Entry(key: k, value: unquote(v), editable: !v.hasPrefix("|") && !v.hasPrefix(">"), line: i, count: 1))
                } else {
                    let joined = ([v].filter { !$0.isEmpty } + extra).joined(separator: ", ")
                    out.append(Entry(key: k, value: joined, editable: false, line: i, count: j - i))
                }
                i = j
            } else { i += 1 }
        }
        return out
    }

    /// 设一个键（已有就换那一行，没有就加在 frontmatter 末尾；整篇没有 frontmatter 就在最前面建一个）。
    /// 键已存在但不可编辑（列表 / 多行）时原样返回。
    static func setting(_ key: String, to value: String, in text: String) -> String {
        let key = key.trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty, !key.contains(":"), !key.contains("\n") else { return text }
        var lines = text.components(separatedBy: "\n")
        let eol = lines.first?.hasSuffix("\r") == true ? "\r" : ""
        let new = "\(key): \(encode(value))" + eol
        guard let close = closingLine(lines) else {
            return "---" + eol + "\n" + new + "\n---" + eol + "\n" + text
        }
        if let e = entries(in: text).first(where: { $0.key == key }) {
            guard e.editable else { return text }
            lines[e.line] = new
        } else {
            lines.insert(new, at: close)
        }
        return lines.joined(separator: "\n")
    }

    /// 删一个键（连它的续行）。
    static func removing(_ key: String, from text: String) -> String {
        guard let e = entries(in: text).first(where: { $0.key == key }) else { return text }
        var lines = text.components(separatedBy: "\n")
        lines.removeSubrange(e.line ..< e.line + e.count)
        return lines.joined(separator: "\n")
    }

    // MARK: 内部

    private static func strip(_ s: String) -> String { s.hasSuffix("\r") ? String(s.dropLast()) : s }

    /// 第一行必须是 `---`；返回收尾那行（`---` / `...`）的行号。
    private static func closingLine(_ lines: [String]) -> Int? {
        guard let f = lines.first, strip(f).trimmingCharacters(in: .whitespaces) == "---" else { return nil }
        for i in 1..<max(lines.count, 1) {
            let t = strip(lines[i]).trimmingCharacters(in: .whitespaces)
            if t == "---" || t == "..." { return i }
        }
        return nil
    }

    private static func split(_ line: String) -> (String, String)? {
        guard let f = line.first, f != " ", f != "\t", f != "#", f != "-" else { return nil }
        guard let r = line.range(of: ":") else { return nil }
        let k = line[..<r.lowerBound].trimmingCharacters(in: .whitespaces)
        guard !k.isEmpty else { return nil }
        let rest = line[r.upperBound...]
        guard rest.isEmpty || rest.first == " " || rest.first == "\t" else { return nil }   // `http://x` 之类不是键
        return (k, rest.trimmingCharacters(in: .whitespaces))
    }

    /// 缩进行、`- ` 列表项、空行（块标量里）都算上一个键的续行。
    private static func isContinuation(_ line: String) -> Bool {
        guard let f = line.first else { return false }
        return f == " " || f == "\t" || f == "-"
    }

    private static func unquote(_ v: String) -> String {
        guard v.count >= 2, let f = v.first, f == v.last, f == "\"" || f == "'" else { return v }
        let inner = String(v.dropFirst().dropLast())
        return f == "\"" ? inner.replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\\\", with: "\\")
                         : inner.replacingOccurrences(of: "''", with: "'")
    }

    /// 写回：会被 YAML 读错的值加双引号（`a: b`、` #`、开头是特殊符号、首尾空白）；`[a, b]` 这类行内列表原样。
    private static func encode(_ v: String) -> String {
        let t = v.trimmingCharacters(in: .newlines)
        if t.isEmpty { return "" }
        let special = "&*!|>'\"%@`#,"
        let needs = t.contains(": ") || t.contains(" #") || t.hasSuffix(":") || t != t.trimmingCharacters(in: .whitespaces)
            || (t.first.map { special.contains($0) } ?? false)
        guard needs else { return t }
        return "\"" + t.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
