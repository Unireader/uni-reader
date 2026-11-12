import Foundation

/// 知识关联（`KNOWLEDGE-LINKS-PLAN.md`，用户 2026-11-12「让一个学科的知识串起来」）：Markdown 笔记、PDF 的页、批注之间的引用。
///
/// 🔴 **关系只从文字里认，不另存一张关系表**（用户 2026-11-12 拍板）：
///  · 笔记 / 批注正文里的 `[[笔记名]]`、`[[书名]]`、`[[书名#page=12]]`（Obsidian 链 PDF 的写法）；
///  · 正文里的 `unireader://open?…`（批注右键「拷贝链接」贴进来的，能指到某页、某条批注）；
///  · 批注本来就挂在某本书的某一页上（结构关系，不用写）。
/// 不改数据库结构，平板 / 服务器不用跟着改；要加一条关系就是在笔记或批注里写一个链接（红线 9：App 自己不改正文）。
///
/// 只依赖 Foundation（+ `DeepLink` / `MarkdownLink` / `NoteIndex`，都是纯的），`spike/knowledge-links-test.swift` 直接编它。

/// 一个链接指到哪。页码 0 起。
enum LinkTarget: Hashable {
    case note(NoteRef)
    /// `page` nil = 整本书。
    case document(id: String, page: Int?)
    /// `page` 只有链接里写了才有（「拷贝链接」拷批注时不带页）。
    case annotation(documentId: String, id: String, page: Int?)

    var documentID: String? {
        switch self {
        case .note: return nil
        case .document(let d, _), .annotation(let d, _, _): return d
        }
    }
}

enum KnowledgeLinks {

    /// 正文里的一处链接。
    struct Occurrence: Equatable {
        enum Kind: Equatable { case wiki, url }
        var kind: Kind
        /// wiki = `[[ ]]` 里面那一串（含 `#…` 与 `|别名`）；url = 整条 `unireader://…`。
        var target: String
        /// 原样写法（`[[极限|定义]]` / `[文字](unireader://…)` 里的那条链接）。
        var raw: String
        /// 第几行（1 起）。
        var line: Int
        /// 那一行的文字（去掉首尾空白，最长 160 字），给「关联」面板与 Agent 当上下文。
        var context: String
    }

    /// `unireader://` 链接（行内链接 `[文字](…)`、尖括号 `<…>`、光秃的都算）。
    static let urlRegex = try! NSRegularExpression(pattern: #"unireader://[^\s<>()\[\]"'`]+"#)

    /// 正文里的全部链接（按出现顺序）：`[[…]]`（图片嵌入不算）与 `unireader://…`。代码块 / 行内代码 / frontmatter 里的不算。
    static func occurrences(in text: String) -> [Occurrence] {
        let ns = text as NSString
        guard ns.length > 0, text.contains("[[") || text.contains("unireader://") else { return [] }
        let guarded = MarkdownLink.protectedRanges(text)
        var starts = [0]
        for (i, u) in text.utf16.enumerated() where u == 10 { starts.append(i + 1) }
        func lineIndex(_ loc: Int) -> Int {
            var lo = 0, hi = starts.count - 1
            while lo < hi { let mid = (lo + hi + 1) / 2; if starts[mid] <= loc { lo = mid } else { hi = mid - 1 } }
            return lo
        }
        func context(_ li: Int) -> String {
            let a = starts[li], b = li + 1 < starts.count ? starts[li + 1] : ns.length
            let s = ns.substring(with: NSRange(location: a, length: b - a)).trimmingCharacters(in: .whitespacesAndNewlines)
            return s.count > 160 ? String(s.prefix(160)) + "…" : s
        }
        var found: [(Int, Occurrence)] = []
        for m in MarkdownLink.wikiRegex.matches(in: text, range: ns.fullRange)
        where !guarded.contains(where: { NSIntersectionRange($0, m.range).length > 0 }) {
            let raw = ns.substring(with: m.range)
            let inner = ns.substring(with: m.range(at: 1))
            let parts = MarkdownLink.WikiParts(inner)
            if raw.hasPrefix("!"), let ext = parts.target.pathExtension, MarkdownLink.imageExts.contains(ext.lowercased()) { continue }
            guard !parts.target.isEmpty else { continue }
            let li = lineIndex(m.range.location)
            found.append((m.range.location, Occurrence(kind: .wiki, target: inner, raw: raw, line: li + 1, context: context(li))))
        }
        for m in urlRegex.matches(in: text, range: ns.fullRange)
        where !guarded.contains(where: { NSIntersectionRange($0, m.range).length > 0 }) {
            let url = ns.substring(with: m.range)
            let li = lineIndex(m.range.location)
            found.append((m.range.location, Occurrence(kind: .url, target: url, raw: url, line: li + 1, context: context(li))))
        }
        return found.sorted { $0.0 < $1.0 }.map(\.1)
    }

    /// 一处链接 → 指到哪。`noteKeys` = 工作区里全部笔记的 `NoteRef.key`（`unireader://…&md=` 给的可能是 key）；
    /// `rowIDs` = 内建笔记库行 UUID → note key（`&md=<uuid>` 那种）。认不出 = nil（断了，或者是别的工作区的）。
    static func resolve(_ o: Occurrence, index: NoteIndex, noteKeys: Set<String>, rowIDs: [String: String] = [:]) -> LinkTarget? {
        switch o.kind {
        case .wiki:
            return index.target(for: o.target)
        case .url:
            guard let url = URL(string: o.target), let link = try? DeepLink.parse(url) else { return nil }
            if let md = link.markdownId {
                if noteKeys.contains(md), let r = NoteRef(key: md) { return .note(r) }
                if let k = rowIDs[md], let r = NoteRef(key: k) { return .note(r) }
                return index.note(for: md).map { .note($0) }
            }
            guard let doc = link.documentId else { return nil }
            let page = link.page.map { $0 - 1 }
            if let n = link.noteId { return .annotation(documentId: doc, id: n.uuidString, page: page) }
            return .document(id: doc, page: page)
        }
    }

    /// `[[` 候选选中一本书 / 一页时写进正文的那段。书名里有 `[[ ]]` 认不了的字符（`[` `]` `|`）就写成 `unireader://` 链接，由调用方给。
    static func wikiFragment(bookTitle: String, page: Int?) -> String? {
        guard !bookTitle.contains("["), !bookTitle.contains("]"), !bookTitle.contains("|"), !bookTitle.isEmpty else { return nil }
        return "[[" + bookTitle + (page.map { "#page=\($0 + 1)" } ?? "") + "]]"
    }
}
