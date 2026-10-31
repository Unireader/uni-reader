import Foundation

/// 输入框里 `@` 引用的一样东西（`ACP-AGENT-PLAN.md §8`、§11）：`@` 候选是工作区书库里的 PDF 与任一源里的
/// Markdown 笔记；侧栏「在 Agent 中引用」还能引用笔记目录、一组 PDF、画板、习题的一组（§11）。
///
/// 🔴 **只给 Agent 名字和位置，不给内容**（用户 2026-09-24 定）：输入框里留 `@名字`，发送时附一个
/// ACP `resource_link` 块（名字 + URI + 库里的身份 + 怎么读），Agent 要读内容自己走 unireader MCP。
struct AgentMention: Equatable, Identifiable {
    enum Kind: Equatable {
        case pdf, note
        /// 笔记源里的一个目录（或整个源）。
        case folder
        /// 一组 PDF：整个书库 / 未分组 / 某个分组。
        case documents
        /// 一张画板 / 全部画板（MCP 还读不了画板上的笔迹，只给名字）。
        case board, boards
        /// 习题的一组（全部 / 错题本 / 收藏 / 某本书 / 某一章）。
        case exercises
    }

    var kind: Kind
    /// 库里的身份：PDF = document_id，笔记 = note_ref（`NoteRef.key`），其余几种是各自的键（只用来去重）。
    var id: String
    /// 插进输入框的名字（PDF / 笔记是文件名，带扩展名；目录以「/」结尾）。
    var name: String
    /// 候选列表第二行：PDF 是书名，笔记是「源 / 所在目录」。也参与匹配；发送时当 `resource_link` 的 title。
    var detail: String
    /// 位置：本机有文件 / 目录就是 file URL；否则退成 `unireader://` 链接。
    var uri: String
    /// PDF、笔记以外几种给 Agent 的说明（它是什么、里面有哪些、用哪个 MCP 工具读），构造时写好。
    var info: String = ""

    var token: String { "@" + name }

    /// 给 Agent 看的一句说明（放进 `resource_link` 的 description）：它是什么、怎么读。
    var agentDescription: String {
        switch kind {
        case .pdf: return "PDF in the UniReader library (document_id \(id)). Read it through the unireader MCP tools."
        case .note: return "Markdown note in the UniReader workspace (note_ref \(id)). Read it through the unireader MCP tools."
        default: return info
        }
    }

    var mimeType: String? {
        switch kind {
        case .pdf: return "application/pdf"
        case .note: return "text/markdown"
        case .folder: return "inode/directory"
        default: return nil
        }
    }

    /// 发送时真正要附上的那些：输入框里还留着 `@名字` 的（选完又删掉的不算），按身份去重、保持选中的先后。
    static func stillReferenced(_ picked: [AgentMention], in text: String) -> [AgentMention] {
        var seen = Set<String>()
        return picked.filter { text.contains($0.token) && seen.insert("\($0.kind)\u{1}\($0.id)").inserted }
    }
}

/// `@` 提及的纯逻辑：认出「光标前正在输入的那个 @」、按输入给候选排序。纯 Foundation，spike 直接编它。
enum AgentMentionMatch {
    /// 光标前是不是正在输入一个提及。规则同常见的聊天 / 编辑器：
    /// `@` 在行首或空白后面（`a@b` 这种邮箱不算），`@` 到光标之间没有空白。
    /// 返回 `@` 起到光标的范围（选中后整段替换）与 `@` 后面那串查询。
    static func activeQuery(in text: NSString, caret: Int) -> (range: NSRange, query: String)? {
        guard caret > 0, caret <= text.length else { return nil }
        var i = caret - 1
        let limit = max(0, caret - 80)
        while i >= limit {
            let c = text.character(at: i)
            if c == 0x40 {   // "@"
                if i > 0, let prev = UnicodeScalar(text.character(at: i - 1)),
                   !CharacterSet.whitespacesAndNewlines.contains(prev) { return nil }
                let r = NSRange(location: i, length: caret - i)
                return (r, text.substring(with: NSRange(location: i + 1, length: caret - i - 1)))
            }
            if let u = UnicodeScalar(c), CharacterSet.whitespacesAndNewlines.contains(u) { return nil }
            i -= 1
        }
        return nil
    }

    /// 按查询给候选打分排序，最多 `limit` 条。空查询 = 原顺序（调用方已按「最近打开」排好）。
    /// 分档：名字开头 > 名字里含 > 第二行里含 > 名字里按顺序出现各字（模糊）> 名字 + 第二行里模糊；都不中就不要。
    /// 比较时不分大小写、不分变音符号。
    static func rank(_ items: [AgentMention], query: String, limit: Int = 50) -> [AgentMention] {
        rank(items, query: query, limit: limit, name: \.name, detail: \.detail)
    }

    /// 同上，任意条目（⌘P 快速打开也用这一套，`QUICK-OPEN-PLAN.md`）：`name` 是主名字，`detail` 是第二行。
    static func rank<T>(_ items: [T], query: String, limit: Int = 50,
                        name: (T) -> String, detail: (T) -> String) -> [T] {
        let q = fold(query.trimmingCharacters(in: .whitespaces))
        guard !q.isEmpty else { return Array(items.prefix(limit)) }
        var scored: [(Int, Int, T)] = []
        for (n, m) in items.enumerated() {
            if let s = score(name: fold(name(m)), detail: fold(detail(m)), query: q) { scored.append((s, n, m)) }
        }
        scored.sort { $0.0 != $1.0 ? $0.0 > $1.0 : $0.1 < $1.1 }
        return scored.prefix(limit).map(\.2)
    }

    static func score(name: String, detail: String, query q: String) -> Int? {
        if name.hasPrefix(q) { return 4000 - name.count }
        if let r = name.range(of: q) { return 3000 - name.distance(from: name.startIndex, to: r.lowerBound) }
        if detail.contains(q) { return 2000 }
        if let gaps = subsequenceGaps(q, in: name) { return 1000 - min(gaps, 999) }
        if subsequenceGaps(q, in: name + " " + detail) != nil { return 100 }
        return nil
    }

    /// `q` 的字是不是按顺序都出现在 `s` 里；是就返回中间跳过了几个字（越少越像）。
    static func subsequenceGaps(_ q: String, in s: String) -> Int? {
        var it = s.makeIterator()
        var gaps = 0
        var started = false
        for ch in q {
            var found = false
            while let c = it.next() {
                if c == ch { found = true; started = true; break }
                if started { gaps += 1 }
            }
            if !found { return nil }
        }
        return gaps
    }

    static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }
}
