import Foundation

/// 随一条用户消息发给 Agent、却不在气泡正文里的东西（`ACP-AGENT-PLAN.md §18`，用户 2026-11-12：
/// 「加一个显示，这样知道这个会话加载了什么上下文」）：`@` 引用、引用文字的出处、批改请求、带进来的交接摘要、
/// 「用户在看什么」。显示在气泡下面一行（`AgentUserMessageView`）。
///
/// 发送时（`AgentChat.dispatch`）和回放时（`AgentTranscript.apply`）都从**发出去的原文**认（同一个 `parse`），两边显示一致。
/// 原文是英文、给模型看的；认的依据是下面 `Marker` 里那几个开头——**写这些说明的地方都用这里的常量**，改一处两边跟着变。
/// 纯 Foundation（`spike/agent-sent-context-test.swift` 直接编它）。
struct AgentSentContext: Equatable {
    enum Kind: Equatable {
        /// `@` 引用：引用的是什么（发送时知道；回放时按 mime / 链接 / 扩展名猜，猜不出 = nil）。
        case reference(AgentMention.Kind?)
        /// 用户在看的 PDF（`name` = 书名，`page` = 第几页，1 起）。
        case viewingDocument
        /// 用户在看的 Markdown 笔记（`name` = 标题）。
        case viewingNote
        /// 用户在练的那组题（`name` = 哪一组，`page` = 第几题）。
        case viewingExercises
        /// 引用的文字出自哪本书哪一页（阅读区选中文字「在 Agent 中引用」）。
        case quote
        /// 「让 Agent 批改」附的说明。
        case grading
        /// 带进来的交接摘要（`name` = 标题）。
        case handoff
        /// 「保存上下文」那一轮让 Agent 写摘要的说明。
        case saveRequest
        /// 每段新对话第一句话带上的工作区记忆（`page` = 带了几条，`ACP-AGENT-PLAN.md §21`）。
        case memories
    }

    var kind: Kind
    var name: String = ""
    var page: Int? = nil
    /// 悬停时给人看的：发给 Agent 的原话（链接 / 说明），太长截断（`detailLimit`）。
    var detail: String = ""

    static let detailLimit = 400

    /// 写这些说明的地方共用的开头（`AgentReaderContext.promptText`、`ReaderView.quoteSelectionInAgent`、
    /// `ExercisePracticeView.askAgent`、`AgentContextText`）。只往后加，别改已有的——旧对话回放靠它们认。
    enum Marker {
        static let document = "Current document: "
        static let markdown = "Current Markdown note: "
        static let exercises = "Current tab: Exercises"
        static let quote = "The quoted text above was selected by the user in the PDF"
        static let grading = "The user wants you to grade their answer."
        static let handoff = "The user attached a saved context"
        static let savedTitle = "Saved context \""
        static let save = "The user wants to save this conversation as a handoff context"
        static let memory = "Workspace memories"
        static let schedule = "Current tab: Schedule"
    }

    // MARK: - 隐藏上下文块

    /// 一块隐藏上下文（`<unireader-context>` 与 `</unireader-context>` 之间）认出来的几样。认不出的不显示。
    static func parse(hidden block: String) -> [AgentSentContext] {
        var out: [AgentSentContext] = []
        let lines = block.components(separatedBy: "\n")
        for (i, raw) in lines.enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix(Marker.document) {
                let t = between(line, after: Marker.document + "\"", before: "\" (document_id") ?? quoted(line) ?? ""
                out.append(AgentSentContext(kind: .viewingDocument, name: t, page: number(in: line, after: "page "), detail: clip(line)))
            } else if line.hasPrefix(Marker.markdown) {
                let t = between(line, after: Marker.markdown + "\"", before: "\" (note_ref") ?? quoted(line) ?? ""
                out.append(AgentSentContext(kind: .viewingNote, name: t, detail: clip(line)))
            } else if line.hasPrefix(Marker.exercises) {
                let t = between(line, after: "the group \"", before: "\" in the") ?? quoted(line) ?? ""
                out.append(AgentSentContext(kind: .viewingExercises, name: t, page: number(in: line, after: "question "), detail: clip(line)))
            } else if line.hasPrefix(Marker.quote) {
                let t = between(line, after: Marker.quote + " \"", before: "\" (document_id") ?? quoted(line) ?? ""
                out.append(AgentSentContext(kind: .quote, name: t, page: number(in: line, after: ", page "), detail: clip(line)))
            } else if line.hasPrefix(Marker.memory) {
                // 记忆块：首行 `Workspace memories (N of T): …`，后面几行是记忆本身，不认（不 break：交接摘要可能跟在后面）。
                // 一条都没带（只有说明）就不显示
                if let n = number(in: line, after: "("), n > 0 {
                    out.append(AgentSentContext(kind: .memories, page: n, detail: clip(line)))
                }
            } else if line.hasPrefix(Marker.grading) {
                out.append(AgentSentContext(kind: .grading, detail: clip(line)))
            } else if line.hasPrefix(Marker.handoff) {
                // 交接摘要：标题在后面 `Saved context "…" (context_id …):` 那行，再往后整块都是摘要正文
                let rest = lines[(i + 1)...]
                let head = rest.first { $0.hasPrefix(Marker.savedTitle) }
                let title = head.flatMap { between($0, after: Marker.savedTitle, before: "\" (context_id") ?? quoted($0) } ?? ""
                let body = head.flatMap { h in rest.firstIndex(of: h).map { rest[($0 + 1)...].joined(separator: "\n") } } ?? ""
                out.append(AgentSentContext(kind: .handoff, name: title, detail: clip(body.trimmingCharacters(in: .whitespacesAndNewlines))))
                break
            } else if line.hasPrefix(Marker.save) {
                out.append(AgentSentContext(kind: .saveRequest, detail: clip(line)))
                break
            }
        }
        return out
    }

    // MARK: - `@` 引用

    /// 一个 `resource_link` 块（回放时 Agent 原样推回来的，或发送时我们自己的）。
    static func reference(name: String, uri: String, mimeType: String?, description: String?) -> AgentSentContext {
        AgentSentContext(kind: .reference(guessKind(uri: uri, mimeType: mimeType, name: name)), name: name,
                         detail: clip(description.flatMap { $0.isEmpty ? nil : $0 } ?? uri))
    }

    /// Agent 把 `resource_link` 转成的那块文字（`AgentMention.isLinkEcho` 认得的几种）还原成引用。
    static func references(echo text: String) -> [AgentSentContext] {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("<resource_link") {
            return matches(of: #"<resource_link\b([^>]*?)/?>"#, in: t).map { attrs in
                let name = attribute("name", in: attrs) ?? attribute("title", in: attrs) ?? ""
                let uri = attribute("uri", in: attrs) ?? ""
                return reference(name: name.isEmpty ? lastComponent(uri) : name, uri: uri,
                                 mimeType: attribute("mimeType", in: attrs) ?? attribute("mime_type", in: attrs),
                                 description: attribute("description", in: attrs))
            }
        }
        // `[@名字](file://…)`
        if t.hasPrefix("["), t.hasSuffix(")"), let r = t.range(of: "](", options: .backwards) {
            var name = String(t[t.index(after: t.startIndex)..<r.lowerBound])
            if name.hasPrefix("@") { name.removeFirst() }
            let uri = String(t[r.upperBound..<t.index(before: t.endIndex)])
            return [reference(name: name.isEmpty ? lastComponent(uri) : name, uri: uri, mimeType: nil, description: nil)]
        }
        // 光秃的路径 / 链接
        var p = t
        if p.hasPrefix("@") { p.removeFirst() }
        return [reference(name: lastComponent(p), uri: p, mimeType: nil, description: nil)]
    }

    /// 回放时猜引用的是什么：mime 最准，其次链接（`ex=` 一道题）、扩展名。
    static func guessKind(uri: String, mimeType: String?, name: String) -> AgentMention.Kind? {
        switch mimeType?.lowercased() {
        case "application/pdf"?: return .pdf
        case "text/markdown"?: return .note
        case "inode/directory"?: return .folder
        default: break
        }
        let u = uri.lowercased()
        if u.hasPrefix("unireader://") {
            if u.contains("ex=") { return .exercise }
            if u.contains("md=") { return .note }
            if u.contains("doc=") { return .pdf }
            return nil
        }
        for s in [u, name.lowercased()] {
            if s.hasSuffix(".pdf") { return .pdf }
            if s.hasSuffix(".md") || s.hasSuffix(".markdown") { return .note }
            if s.hasSuffix("/") { return .folder }
        }
        return nil
    }

    // MARK: - 小工具

    /// 去重（同一样东西发两次只显示一次），保持先后。
    static func merged(_ a: [AgentSentContext], _ b: [AgentSentContext]) -> [AgentSentContext] {
        var out = a
        for x in b where !out.contains(where: { $0.kind == x.kind && $0.name == x.name && $0.page == x.page }) { out.append(x) }
        return out
    }

    private static func clip(_ s: String) -> String {
        s.count > detailLimit ? String(s.prefix(detailLimit)) + "…" : s
    }

    private static func between(_ s: String, after a: String, before b: String) -> String? {
        guard let r1 = s.range(of: a), let r2 = s.range(of: b, range: r1.upperBound..<s.endIndex) else { return nil }
        return String(s[r1.upperBound..<r2.lowerBound])
    }

    /// 第一对双引号里的。
    private static func quoted(_ s: String) -> String? {
        guard let a = s.firstIndex(of: "\""), let b = s[s.index(after: a)...].firstIndex(of: "\"") else { return nil }
        return String(s[s.index(after: a)..<b])
    }

    /// `after` 后面紧跟的那个整数（`page 12 of 300` → 12）。
    private static func number(in s: String, after a: String) -> Int? {
        guard let r = s.range(of: a) else { return nil }
        let digits = s[r.upperBound...].prefix { $0.isASCII && $0.isNumber }
        return Int(digits)
    }

    private static func lastComponent(_ uri: String) -> String {
        var s = uri
        if s.lowercased().hasPrefix("file://"), let u = URL(string: s) { s = u.path }
        while s.hasSuffix("/") { s.removeLast() }
        let last = s.split(separator: "/").last.map(String.init) ?? s
        return last.removingPercentEncoding ?? last
    }

    private static func matches(of pattern: String, in s: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = s as NSString
        return re.matches(in: s, range: NSRange(location: 0, length: ns.length)).compactMap { m in
            m.numberOfRanges > 1 ? ns.substring(with: m.range(at: 1)) : nil
        }
    }

    /// `name="…"` 的值（XML 转义还原）。
    private static func attribute(_ key: String, in attrs: String) -> String? {
        guard let v = matches(of: "\\b\(key)=\"([^\"]*)\"", in: attrs).first else { return nil }
        return v.replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
    }
}
