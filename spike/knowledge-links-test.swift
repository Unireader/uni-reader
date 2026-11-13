// 知识关联（`KNOWLEDGE-LINKS-PLAN.md`）回归测试：`[[书名#page=N]]` 解析、书 / 笔记 / 别名的优先次序、正文里的链接扫描与解析。
// 运行：
//   mkdir -p /tmp/kl && cp spike/knowledge-links-test.swift /tmp/kl/main.swift && swiftc Sources/Store/*.swift \
//     Sources/App/MarkdownLink.swift Sources/App/MarkdownImport.swift Sources/App/NoteTree.swift Sources/App/KnowledgeLinks.swift \
//     Sources/App/DeepLink.swift Sources/App/NoteTypeModel.swift Sources/App/TextNoteModel.swift Sources/App/InkModel.swift \
//     Sources/App/InkLayerModel.swift Sources/App/PenPreset.swift Sources/Support/L.swift /tmp/kl/main.swift -o /tmp/kl/t && /tmp/kl/t

import Foundation

var pass = 0, fail = 0
func check(_ cond: Bool, _ msg: String) {
    if cond { pass += 1; print("  ✅ \(msg)") } else { fail += 1; print("  ❌ \(msg)") }
}

print("— 1) #page= 锚点")
check(NoteIndex.pdfAnchor("马原#page=12") == ("马原", 12), "书名#page=12")
check(NoteIndex.pdfAnchor("马原.pdf#page=3&selection=1,2") == ("马原.pdf", 3), "带 .pdf 与后面的参数")
check(NoteIndex.pdfAnchor("马原#page=3|第三页") == ("马原", 3), "带别名")
check(NoteIndex.pdfAnchor("马原#page=3\\") == ("马原", 3), "表格里转义竖线留下的反斜杠")
check(NoteIndex.pdfAnchor("马原#第一章").page == nil && NoteIndex.pdfAnchor("马原#第一章").name == "马原", "别的锚点不是页")
check(NoteIndex.pdfAnchor("2027计算机网络_高清带书签版#p=71") == ("2027计算机网络_高清带书签版", 71), "简写 #p=71 也是页（Agent 这么写过）")
check(NoteIndex.pdfAnchor("马原#P=5|第五页") == ("马原", 5), "#P= 不分大小写、带别名")
check(NoteIndex.pdfAnchor("马原#page=0").page == nil, "page=0 不算")

print("— 2) 书 / 笔记 / 别名")
var idx = NoteIndex()
let noteA = NoteRef(sourceID: "ws", relPath: "政治/矛盾.md")
let sameName = NoteRef(sourceID: "ws", relPath: "书评/高等数学.md")
idx.add(note: NoteItem(ref: noteA))
idx.add(note: NoteItem(ref: sameName))
idx.setDocuments([(id: "D1", title: "马克思主义基本原理"), (id: "D2", title: "高等数学.pdf"), (id: "D3", title: "C#入门")])
check(idx.target(for: "矛盾") == .note(noteA), "笔记照旧")
check(idx.target(for: "马克思主义基本原理") == .document(id: "D1", page: nil), "书名 → 整本书")
check(idx.target(for: "马克思主义基本原理#page=12") == .document(id: "D1", page: 11), "书名#page=12 → 第 12 页（内部 0 起）")
check(idx.target(for: "马克思主义基本原理.pdf#page=2") == .document(id: "D1", page: 1), "带 .pdf 的写法")
check(idx.target(for: "高等数学") == .note(sameName), "同名时不带页码 → 笔记优先（老链接不受影响）")
check(idx.target(for: "高等数学#page=5") == .document(id: "D2", page: 4), "同名时带页码 → 书")
check(idx.target(for: "C#入门") == .document(id: "D3", page: nil), "书名里本来就有 #")
check(idx.target(for: "没有这本") == nil, "认不出 → nil")
idx.addAlias("第十二页", target: .document(id: "D1", page: 11))
check(idx.target(for: "第十二页") == .document(id: "D1", page: 11), "别名指向书页")
check(idx.note(for: "第十二页") == nil, "指向书页的别名不当成笔记")
var copy = NoteIndex(); copy.copyDocuments(from: idx)
check(copy.target(for: "马克思主义基本原理#page=1") == .document(id: "D1", page: 0), "书单能拷进新索引（重扫笔记时不丢）")

print("— 3) 正文里的链接扫描")
let text = """
---
tags: [[不算]]
---
# 矛盾
见 [[马克思主义基本原理#page=12]] 与 [[矛盾|对立统一]]。
原文 [高亮](unireader://open?ws=%2Fa.unrd&doc=D1&page=3&note=11111111-2222-3333-4444-555555555555) 和 <unireader://open?doc=D2&page=7>
`[[代码里]]` ![[图.png]] ![[矛盾]]
```
unireader://open?doc=D9
```
"""
let occ = KnowledgeLinks.occurrences(in: text)
check(occ.map(\.kind) == [.wiki, .wiki, .url, .url, .wiki], "顺序：两个 wiki、两个链接、一个嵌入笔记（得到 \(occ.map(\.kind))）")
check(occ.map(\.line) == [5, 5, 6, 6, 7], "行号（得到 \(occ.map(\.line))）")
check(occ[0].target == "马克思主义基本原理#page=12" && occ[1].target == "矛盾|对立统一", "wiki 给括号里的整串（含锚点与别名）")
check(occ[2].target.hasSuffix("555555555555") && !occ[2].target.contains(")"), "行内链接不带右括号")
check(occ[3].target == "unireader://open?doc=D2&page=7", "尖括号链接不带尖括号")
check(occ[0].context.hasPrefix("见 [[马克思主义"), "上下文是那一行")
check(KnowledgeLinks.occurrences(in: "什么都没有").isEmpty, "没有链接")

print("— 4) 解析")
let keys: Set<String> = [noteA.key, sameName.key]
let r = occ.map { KnowledgeLinks.resolve($0, index: idx, noteKeys: keys) }
check(r[0] == .document(id: "D1", page: 11), "[[书#page=12]] → 那一页")
check(r[1] == .note(noteA), "[[笔记|别名]] → 笔记")
check(r[2] == .annotation(documentId: "D1", id: "11111111-2222-3333-4444-555555555555", page: 2), "拷贝的批注链接 → 那条批注")
check(r[3] == .document(id: "D2", page: 6), "页链接 → 那一页")
check(r[4] == .note(noteA), "![[笔记]] 嵌入也算链接")
let mdLink = KnowledgeLinks.Occurrence(kind: .url, target: "unireader://open?md=" + noteA.key.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!, raw: "", line: 1, context: "")
check(KnowledgeLinks.resolve(mdLink, index: idx, noteKeys: keys) == .note(noteA), "&md=<note key> → 笔记")
let rowLink = KnowledgeLinks.Occurrence(kind: .url, target: "unireader://open?md=ROW-1", raw: "", line: 1, context: "")
check(KnowledgeLinks.resolve(rowLink, index: idx, noteKeys: keys, rowIDs: ["ROW-1": noteA.key]) == .note(noteA), "&md=<库行 id> → 笔记")

print("— 5) 写进正文的那段")
check(KnowledgeLinks.wikiFragment(bookTitle: "马原", page: 11) == "[[马原#page=12]]", "书页")
check(KnowledgeLinks.wikiFragment(bookTitle: "马原", page: nil) == "[[马原]]", "整本书")
check(KnowledgeLinks.wikiFragment(bookTitle: "a[b]", page: 0) == nil, "书名有方括号 → 不写 [[ ]]")

print("\n\(fail == 0 ? "✅ 全部通过" : "❌ 有失败")：\(pass) 过 / \(fail) 败")
exit(fail == 0 ? 0 : 1)
