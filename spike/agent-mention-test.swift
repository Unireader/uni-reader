// Agent 输入框 `@` 提及的纯逻辑（`Sources/Agent/AgentMention.swift`，只依赖 Foundation）。运行：
//   cp spike/agent-mention-test.swift /tmp/main.swift && swiftc Sources/Agent/AgentMention.swift /tmp/main.swift -o /tmp/amt && /tmp/amt
// 覆盖：「光标前正在输入的 @」的判定（行首 / 空白后 / 邮箱不算 / 中间有空白不算 / 中文）、
//       排序分档（开头 > 含 > 第二行含 > 模糊）、大小写与变音符号、空查询保持原顺序、条数上限、
//       发送时只附上正文里还留着的、按身份去重。
import Foundation

var pass = 0, fail = 0
func check(_ c: Bool, _ m: String) { if c { pass += 1; print("  ✅ \(m)") } else { fail += 1; print("  ❌ \(m)") } }
func q(_ s: String, _ caret: Int? = nil) -> String? {
    let ns = s as NSString
    return AgentMentionMatch.activeQuery(in: ns, caret: caret ?? ns.length)?.query
}
func m(_ name: String, _ detail: String = "", kind: AgentMention.Kind = .note, id: String? = nil) -> AgentMention {
    AgentMention(kind: kind, id: id ?? name, name: name, detail: detail, uri: "file:///x/\(name)")
}

print("认出正在输入的 @")
check(q("@") == "", "只打了 @ = 空查询")
check(q("@abc") == "abc", "行首 @abc")
check(q("看看 @极限") == "极限", "空白后的 @，中文查询")
check(q("第一行\n@note") == "note", "换行后的 @")
check(q("mail a@b.com") == nil, "邮箱里的 @ 不算")
check(q("@ab cd") == nil, "@ 与光标之间有空白 = 已经不在输入提及了")
check(q("@abc def", 4) == "abc", "光标在中间：只看光标前")
check(q("hello") == nil, "没有 @")
check(q("") == nil, "空串")
check(q("@a@b") == nil, "紧挨着的第二个 @ 前面不是空白，不算")
let r = AgentMentionMatch.activeQuery(in: "问 @lim" as NSString, caret: 6)
check(r?.range == NSRange(location: 2, length: 4), "范围从 @ 起到光标（整段替换用）")

print("排序")
let items = [m("Calculus Notes.md", "Notes / 数学"), m("limit.md", "Notes"), m("Linear Algebra.pdf", "线性代数", kind: .pdf),
             m("sublime.md", "Notes"), m("Élan.md", "Notes"), m("极限.md", "Notes / 数学")]
check(AgentMentionMatch.rank(items, query: "").map(\.name) == items.map(\.name), "空查询 = 原顺序")
check(AgentMentionMatch.rank(items, query: "li").first?.name == "limit.md", "开头命中排第一（短的在前）")
let li = AgentMentionMatch.rank(items, query: "li").map(\.name)
check(li.firstIndex(of: "Linear Algebra.pdf")! < li.firstIndex(of: "sublime.md")!, "开头命中 > 中间含")
check(AgentMentionMatch.rank(items, query: "LIM").first?.name == "limit.md", "不分大小写")
check(AgentMentionMatch.rank(items, query: "elan").first?.name == "Élan.md", "不分变音符号")
check(AgentMentionMatch.rank(items, query: "极限").first?.name == "极限.md", "中文名")
check(AgentMentionMatch.rank(items, query: "数学").map(\.name) == ["Calculus Notes.md", "极限.md"], "第二行（所在目录）也能搜到，同分保持原顺序")
check(AgentMentionMatch.rank(items, query: "线性").first?.name == "Linear Algebra.pdf", "PDF 按书名搜到")
check(AgentMentionMatch.rank(items, query: "cln").first?.name == "Calculus Notes.md", "模糊：按顺序出现各字")
check(AgentMentionMatch.rank(items, query: "zzz").isEmpty, "都不中 = 空（浮窗收起）")
let many = (0..<120).map { m("n\($0).md") }
check(AgentMentionMatch.rank(many, query: "").count == 50, "空查询最多 50 条")
check(AgentMentionMatch.rank(many, query: "n", limit: 8).count == 8, "limit 生效")
check(AgentMentionMatch.subsequenceGaps("ac", in: "abc") == 1, "模糊的间隔数")
check(AgentMentionMatch.subsequenceGaps("ca", in: "abc") == nil, "顺序不对不中")

print("发送时附哪些")
let a = m("a.md"), b = m("b b.md"), c = m("c.pdf", kind: .pdf)
let sent = AgentMention.stillReferenced([a, b, c, a], in: "看 @a.md 和 @b b.md 的区别")
check(sent.map(\.name) == ["a.md", "b b.md"], "删掉的不附、重复的去重、保持先后（名字带空格也行）")
check(AgentMention.stillReferenced([a], in: "没有提及").isEmpty, "正文里没了就不附")
let samePdf = m("x.pdf", kind: .pdf, id: "D1"), sameNote = m("x.pdf", kind: .note, id: "D1")
check(AgentMention.stillReferenced([samePdf, sameNote], in: "@x.pdf").count == 2, "种类不同的同 id 不算重复")
check(c.token == "@c.pdf" && c.mimeType == "application/pdf" && a.mimeType == "text/markdown", "token / mimeType")

print("\n\(pass) 通过，\(fail) 失败")
exit(fail == 0 ? 0 : 1)
