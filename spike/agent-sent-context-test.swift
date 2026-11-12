// Agent 面板气泡下面那行「上下文」的认法（`Sources/Agent/AgentSentContext.swift`，`ACP-AGENT-PLAN.md §18`）。运行：
//   cp spike/agent-sent-context-test.swift /tmp/main.swift && swiftc Sources/Agent/AgentMention.swift \
//     Sources/Agent/AgentSentContext.swift Sources/Agent/AgentContextText.swift /tmp/main.swift -o /tmp/asct && /tmp/asct
// 隐藏块的样本照 `AgentReaderContext.promptText` / `ReaderView.quoteSelectionInAgent` / `ExercisePracticeView.askAgent` 的写法拼
// （它们连着 AppKit / ACP 库，编不进来；开头都用 `AgentSentContext.Marker`，所以这里也用它拼）。
import Foundation

var pass = 0, fail = 0
func check(_ c: Bool, _ m: String) { if c { pass += 1; print("  ✅ \(m)") } else { fail += 1; print("  ❌ \(m)") } }
typealias C = AgentSentContext
typealias M = AgentSentContext.Marker

print("— 「用户在看什么」那块")
let pdfBlock = """
The user is talking to you from the Agent panel of UniReader, a PDF and Markdown note reader. Reply in the user's language.
Workspace: 408. Its library lives in the package "408.unrd" inside your working directory.
\(M.document)"2027计算机网络_高清带书签版" (document_id 4810), page 22 of 380, reader tab session_id S, window_id W.
UniReader has two kinds of notes: …
"""
let a = C.parse(hidden: pdfBlock)
check(a.count == 1 && a[0].kind == .viewingDocument && a[0].name == "2027计算机网络_高清带书签版" && a[0].page == 22, "PDF：书名 + 第几页")
let mdBlock = "\(M.markdown)\"06. 法律建设\" (note_ref N1, source \"Vault\" [external], relative_path \"思修/06. 法律建设.md\"), reader tab session_id S."
let b = C.parse(hidden: mdBlock)
check(b.count == 1 && b[0].kind == .viewingNote && b[0].name == "06. 法律建设", "Markdown 笔记：标题")
let exBlock = "\(M.exercises) (习题), the group \"第二章 物理层\" in the practice view, question 3 of 20: exercise_id E1, a single question numbered 11 on page 22 of \"计网\" (document_id D); the user has not answered it yet."
let e = C.parse(hidden: exBlock)
check(e.count == 1 && e[0].kind == .viewingExercises && e[0].name == "第二章 物理层" && e[0].page == 3, "习题：哪一组 + 第几题")
check(C.parse(hidden: "No document is open in the reader right now.").isEmpty, "没打开文档：不显示")

print("— 随消息的说明（引用出处 / 批改 / 交接摘要 / 写摘要）")
let quote = "\(M.quote) \"高数讲义\" (document_id D2), page 12. Use the unireader MCP tools if you need more of the page."
let q = C.parse(hidden: quote)
check(q.count == 1 && q[0].kind == .quote && q[0].name == "高数讲义" && q[0].page == 12, "引用出处：书名 + 第几页")
let grade = "\(M.grading) exercise_id E1, attempt_id A1. Read the question …"
check(C.parse(hidden: grade).first?.kind == .grading, "批改请求")
let hand = AgentContextText.handoff(title: "计网第二章复习", summary: "# 计网\n- 已做到 2.3\n- 下一步 2.4", agent: "Kimi", id: "C1", date: Date())
let h = C.parse(hidden: "Attached image 1: snip of page 3\n" + quote + "\n" + hand)
check(h.count == 2 && h[0].kind == .quote && h[1].kind == .handoff && h[1].name == "计网第二章复习", "几样在一块：引用出处 + 交接摘要（图片说明不显示）")
check(h.last?.detail.contains("已做到 2.3") == true && h.last?.detail.contains("Saved context") == false, "交接摘要悬停看到的是摘要正文")
check(C.parse(hidden: AgentContextText.saveInstruction).map(\.kind) == [.saveRequest], "写交接摘要的说明（真文案，开头对得上 Marker.save）")
check(AgentContextText.saveInstruction.hasPrefix(M.save), "saveInstruction 开头 = Marker.save")
check(hand.hasPrefix(M.handoff) && hand.contains(M.savedTitle), "handoff 文案开头 = Marker.handoff，带 Marker.savedTitle")

print("— @ 引用：原样的 resource_link 与 Agent 转成的文字")
let r1 = C.reference(name: "计网.pdf", uri: "file:///Users/x/408.unrd/PDFs/ABC.pdf", mimeType: "application/pdf", description: "PDF in the UniReader library (document_id D).")
check(r1.kind == .reference(.pdf) && r1.name == "计网.pdf" && r1.detail.hasPrefix("PDF in"), "resource_link：mime 认出 PDF，悬停看说明")
check(C.reference(name: "x", uri: "unireader://open?ws=a&ex=E1", mimeType: nil, description: nil).kind == .reference(.exercise), "unireader 链接带 ex= → 一道题")
check(C.reference(name: "思修/", uri: "file:///a/思修/", mimeType: "inode/directory", description: nil).kind == .reference(.folder), "目录")
let tag = #"<resource_link uri="unireader://open?ws=%2FU&amp;doc=4810&amp;ex=E1" name="2027计算机网络 · Page 22 · No. 11" />"#
let t1 = C.references(echo: tag)
check(t1.count == 1 && t1[0].name == "2027计算机网络 · Page 22 · No. 11" && t1[0].kind == .reference(.exercise), "Kimi 标签：名字 + 认出一道题（&amp; 还原）")
check(C.references(echo: tag + "\n" + tag).count == 2, "几个标签都认出来")
let p1 = C.references(echo: "/Users/xvan/Library/Application Support/UniReader/Servers/x/101学习区.unrd/PDFs/d858.pdf")
check(p1.count == 1 && p1[0].name == "d858.pdf" && p1[0].kind == .reference(.pdf), "Kimi 路径：文件名 + 扩展名认出 PDF")
let m1 = C.references(echo: "[@06. 法律建设.md](file:///Users/xvan/Vault/06.%20%E6%B3%95.md)")
check(m1.count == 1 && m1[0].name == "06. 法律建设.md" && m1[0].kind == .reference(.note), "Claude Code：[@名字](file://…)")

print("— 去重")
let twice = C.merged([r1], [r1, q[0]])
check(twice.count == 2, "同一样只留一个，新的接在后面")

print("\n\(pass) 通过，\(fail) 失败")
exit(fail == 0 ? 0 : 1)
