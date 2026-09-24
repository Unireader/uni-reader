// MCP Markdown 笔记的读 / 局部改纯逻辑（`MCPMarkdownText`）。运行：
//   mkdir -p build/spike && cp spike/mcp-markdown-text-test.swift build/spike/main.swift && swiftc Sources/MCP/MCPMarkdownText.swift build/spike/main.swift -o build/spike/mcpmd && build/spike/mcpmd
// 覆盖：分行口径（结尾换行不多算）、分页（offset/limit/字数上限）、大纲（跳代码块与 frontmatter）、搜索、
//       替换（唯一 / 多处报行号 / replace_all / 找不到的两种提示）、插入（开头 / 中间 / 末尾有无结尾换行 / 空文）、
//       多条依次生效且整批原子、改动行号（最终正文坐标、相邻合并）、核对片段。
import Foundation

var pass = 0, fail = 0
func check(_ c: Bool, _ m: String) { if c { pass += 1; print("  ✅ \(m)") } else { fail += 1; print("  ❌ \(m)") } }
typealias T = MCPMarkdownText

func applyErr(_ edits: [T.Edit], _ text: String) -> T.EditError? {
    do { _ = try T.apply(edits, to: text); return nil } catch let e as T.EditError { return e } catch { return nil }
}

print("分行")
check(T.lineCount("") == 0, "空串 0 行")
check(T.lineCount("a") == 1, "无结尾换行 1 行")
check(T.lineCount("a\nb\n") == 2, "结尾换行不多算")
check(T.lineCount("a\n\n") == 2, "末尾空行算一行")
check(T.line(atUTF16: 0, in: "a\nb") == 1 && T.line(atUTF16: 2, in: "a\nb") == 2, "偏移 → 行号")

print("分页")
let doc = (1...10).map { "line \($0)" }.joined(separator: "\n") + "\n"
var p = T.page(doc, offset: 3, limit: 4, maxChars: 10_000)
check(p.startLine == 3 && p.endLine == 6 && p.totalLines == 10 && p.truncated, "3…6 共 10 行，后面还有")
check(p.text == "line 3\nline 4\nline 5\nline 6", "原文片段逐字")
check(p.numbered.hasPrefix("   3\tline 3"), "行号前缀 cat -n 式：\(p.numbered.prefix(12))")
p = T.page(doc, offset: 9, limit: 100, maxChars: 10_000)
check(p.endLine == 10 && !p.truncated, "读到结尾不标截断")
p = T.page(doc, offset: 1, limit: 100, maxChars: 15)
check(p.startLine == 1 && p.endLine == 2 && p.truncated, "字数上限截在整行：\(p.endLine)")
p = T.page(doc, offset: 1, limit: 100, maxChars: 1)
check(p.endLine == 1, "上限再小也至少给一行")
p = T.page(doc, offset: 11, limit: 5, maxChars: 100)
check(p.startLine == 0 && p.text.isEmpty && p.totalLines == 10, "越界 → 空")

print("大纲")
let md = """
---
title: x
# 不是标题
---
# 一
正文 #tag
## 二 ##
```
# 代码里
```
    # 缩进代码
####### 七个不算
#没空格不算
### 三
"""
let o = T.outline(md)
check(o.map(\.title) == ["一", "二", "三"], "只认真标题：\(o.map(\.title))")
check(o.map(\.line) == [5, 7, 14] && o.map(\.level) == [1, 2, 3], "行号与级别：\(o.map(\.line))")

print("搜索")
let s = T.search("Alpha\nbeta\nALPHA beta\n", query: "alpha", caseSensitive: false, limit: 1)
check(s.total == 2 && s.hits == [T.SearchHit(line: 1, text: "Alpha")], "不分大小写 2 处、只回 limit 条")
check(T.search("Alpha\nALPHA", query: "alpha", caseSensitive: true, limit: 9).total == 0, "区分大小写")

print("替换")
let base = "# 标题\n第一段 [[极限]]\n\n第二段\n第三段\n"
var r = try! T.apply([.replace(old: "第二段", new: "第二段（改）", all: false)], to: base)
check(r.text == "# 标题\n第一段 [[极限]]\n\n第二段（改）\n第三段\n", "唯一匹配直接换，别处一字不动")
check(r.changedLines == [4...4] && r.counts == [1], "改动在第 4 行：\(r.changedLines)")
var e = applyErr([.replace(old: "段", new: "节", all: false)], base)
check(e?.message.contains("matches 3 places (lines 2, 4, 5)") == true, "多处 → 报行号：\(e?.message ?? "nil")")
r = try! T.apply([.replace(old: "段", new: "节", all: true)], to: base)
check(r.text == "# 标题\n第一节 [[极限]]\n\n第二节\n第三节\n" && r.counts == [3], "replace_all 全换")
check(r.changedLines == [2...2, 4...5], "不相邻分开、相邻合并：\(r.changedLines)")
e = applyErr([.replace(old: "   4\t第二段", new: "x", all: false)], base)
check(e?.message.contains("line-number prefixes") == true, "抄了行号前缀 → 专门提示")
e = applyErr([.replace(old: "第一段  [[极限]]", new: "x", all: false)], base)
check(e?.message.contains("near line 2 if whitespace is ignored") == true, "空白不同 → 提示附近行：\(e?.message ?? "nil")")
e = applyErr([.replace(old: "不存在", new: "x", all: false)], base)
check(e?.message.contains("call read_markdown again") == true, "真找不到")
check(applyErr([.replace(old: "", new: "x", all: false)], base) != nil, "old_text 空 → 错")
check(applyErr([.replace(old: "第三段", new: "第三段", all: false)], base) != nil, "新旧相同 → 错")
r = try! T.apply([.replace(old: "第一段 [[极限]]\n\n", new: "", all: false)], to: base)
check(r.text == "# 标题\n第二段\n第三段\n" && r.changedLines == [2...2], "删除：记删除点那一行 \(r.changedLines)")
// 精确匹配不做 Unicode 归一：é 的两种写法不互认
check(applyErr([.replace(old: "e\u{301}", new: "x", all: false)], "caf\u{e9}") != nil, "逐码元匹配，不做归一")
// CRLF 原样
r = try! T.apply([.replace(old: "b\r\n", new: "B\r\n", all: false)], to: "a\r\nb\r\nc")
check(r.text == "a\r\nB\r\nc", "\\r\\n 原样保留")

print("插入")
check((try! T.apply([.insert(afterLine: 0, text: "新")], to: "a\nb\n")).text == "新\na\nb\n", "最前面，自动补行尾")
check((try! T.apply([.insert(afterLine: 1, text: "新\n")], to: "a\nb\n")).text == "a\n新\nb\n", "中间，已带换行不重复加")
check((try! T.apply([.insert(afterLine: 2, text: "新")], to: "a\nb\n")).text == "a\nb\n新\n", "末尾（原文有结尾换行）")
check((try! T.apply([.insert(afterLine: 2, text: "新")], to: "a\nb")).text == "a\nb\n新", "末尾（原文无结尾换行）先补换行")
check((try! T.apply([.insert(afterLine: 0, text: "新")], to: "")).text == "新", "空文")
r = try! T.apply([.insert(afterLine: 1, text: "x\ny")], to: "a\nb\n")
check(r.changedLines == [2...3], "插入两行 → 2…3：\(r.changedLines)")
check(applyErr([.insert(afterLine: 3, text: "x")], "a\nb\n")?.message.contains("out of range (0…2)") == true, "越界")

print("多条")
r = try! T.apply([.insert(afterLine: 0, text: "顶"),
                  .replace(old: "第三段", new: "第三段\n补一行", all: false),
                  .replace(old: "# 标题", new: "# 新标题", all: false)], to: base)
check(r.text == "顶\n# 新标题\n第一段 [[极限]]\n\n第二段\n第三段\n补一行\n", "依次生效")
check(r.changedLines == [1...2, 6...7], "行号是最终正文的坐标，相邻合并：\(r.changedLines)")
e = applyErr([.replace(old: "第二段", new: "X", all: false), .replace(old: "第二段", new: "Y", all: false)], base)
check(e?.index == 2, "第 2 条看到的是第 1 条改完的正文 → 找不到，整批失败")
check(applyErr([.replace(old: "a", new: "b", all: false), .replace(old: "b", new: "a", all: false)], "a") != nil,
      "改完等于没改 → 报错")

print("片段")
let big = (1...30).map { "L\($0)" }.joined(separator: "\n")
let snip = T.snippet(big, around: [5...5, 20...21], context: 2, maxLines: 100)
check(snip.contains("   3\tL3") && snip.contains("   7\tL7") && !snip.contains("\tL8\n"), "前后各 2 行")
check(snip.contains("\n…\n") && snip.contains("  23\tL23"), "两段之间用 … 隔开")
check(T.snippet(big, around: [1...30], context: 0, maxLines: 5).hasSuffix("…"), "超过上限截断")

print("\n通过 \(pass)，失败 \(fail)")
exit(fail == 0 ? 0 : 1)
