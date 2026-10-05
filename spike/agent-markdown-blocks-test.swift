// Agent 面板右键「复制表格 / 复制代码」认块的纯逻辑（`Sources/Agent/AgentMarkdownBlocks.swift`，只依赖 Foundation）。运行：
//   cp spike/agent-markdown-blocks-test.swift /tmp/main.swift && swiftc Sources/Agent/AgentMarkdownBlocks.swift /tmp/main.swift -o /tmp/ambt && /tmp/ambt
// 覆盖：规则与引擎 `BlockParser` 一致（行首 ``` 才算围栏、没收尾的不算、表格要紧跟分隔行、数据行连续）、
//       复制的内容（代码只取两行围栏之间、不含最后的换行；表格取整块）、点在块尾 / 块外 / 块之间、
//       围栏里的 `|` 行不当表格、CRLF、中文（UTF-16 下标）、语言名。
import Foundation

var pass = 0, fail = 0
func check(_ c: Bool, _ m: String) { if c { pass += 1; print("  ✅ \(m)") } else { fail += 1; print("  ❌ \(m)") } }

func at(_ text: String, _ needle: String, offset: Int = 0) -> AgentMarkdownBlock? {
    let r = (text as NSString).range(of: needle)
    precondition(r.location != NSNotFound, "样例里没有 \(needle)")
    return AgentMarkdownBlock.block(at: r.location + offset, in: text)
}
func content(_ text: String, _ b: AgentMarkdownBlock?) -> String? {
    b.map { (text as NSString).substring(with: $0.content) }
}

let doc = """
前面一段，包含 | 竖线 | 但不是表格。

```swift
let a = 1
let b = a | 2
```

| 中文 | 英文 |
|---|:---:|
| 桌前检查 | desk checking |
| 走查 | walkthrough |
后面紧跟的普通行

```
没写语言
```

```python
没有收尾的围栏
"""

print("代码块")
let swift = at(doc, "let a")
check(swift?.kind == .code(language: "swift"), "点在代码里 → 代码块，语言 swift")
check(content(doc, swift) == "let a = 1\nlet b = a | 2", "复制内容只取两行围栏之间、不含最后的换行")
check(at(doc, "```swift")?.kind == .code(language: "swift"), "点在开头围栏上也算这个代码块")
check(at(doc, "| 2\n```", offset: 4)?.kind == .code(language: "swift"), "点在收尾围栏上也算")
check(at(doc, "let b = a | 2")?.kind != .table, "围栏里的 | 行不当表格")
let plain = at(doc, "没写语言")
check(plain?.kind == .code(language: nil), "没写语言 → language nil")
check(content(doc, plain) == "没写语言", "没写语言的代码块内容")
check(at(doc, "没有收尾的围栏") == nil, "没收尾的围栏不算代码块（引擎当普通段落）")

print("表格")
let table = at(doc, "桌前检查")
check(table?.kind == .table, "点在表格里 → 表格")
let tableText = content(doc, table)
check(tableText == "| 中文 | 英文 |\n|---|:---:|\n| 桌前检查 | desk checking |\n| 走查 | walkthrough |",
      "复制内容 = 整张表（表头 + 分隔行 + 数据行），不带后面的普通行：\(tableText ?? "nil")")
check(at(doc, "| 中文")?.kind == .table, "点在表头的第一个字符上")
let tail = (doc as NSString).range(of: "walkthrough |")
check(AgentMarkdownBlock.block(at: NSMaxRange(tail), in: doc)?.kind == .table, "点在最后一行行末（块尾）也算")
check(AgentMarkdownBlock.block(at: NSMaxRange(tail) + 1, in: doc) == nil, "下一行行首不算")
check(at(doc, "后面紧跟的普通行") == nil, "表格后面的普通行不算")
check(at(doc, "前面一段") == nil, "带 | 的普通段落不算表格")
check(at(doc, "包含 | 竖线", offset: 3) == nil, "点在普通段落的 | 上也不算")

print("边界")
check(AgentMarkdownBlock.block(at: -1, in: doc) == nil, "负下标")
check(AgentMarkdownBlock.block(at: (doc as NSString).length + 1, in: doc) == nil, "越界下标")
check(AgentMarkdownBlock.block(at: 0, in: "") == nil, "空文本")
let noSep = "| a | b |\n| c | d |"
check(AgentMarkdownBlock.block(at: 2, in: noSep) == nil, "没有分隔行的不是表格")
let indented = "  ```swift\nx\n  ```"
check(AgentMarkdownBlock.block(at: 11, in: indented) == nil, "缩进的 ``` 不算围栏（同引擎：行首才算）")
let crlf = "```js\r\nlet x = 1\r\n```\r\n"
let crlfBlock = AgentMarkdownBlock.block(at: 8, in: crlf)
check(crlfBlock?.kind == .code(language: "js"), "CRLF 换行也认")
check(content(crlf, crlfBlock) == "let x = 1", "CRLF 下内容不带 \\r")
let empty = "```\n```"
check(content(empty, AgentMarkdownBlock.block(at: 1, in: empty)) == "", "空代码块内容为空")
let lang = "```  objective-c  extra\ncode\n```"
check(AgentMarkdownBlock.block(at: 26, in: lang)?.kind == .code(language: "objective-c"), "语言名取围栏后第一个词")
let twoTables = "| a | b |\n|---|---|\n| 1 | 2 |\n\n| c |\n|---|\n| 3 |"
check(content(twoTables, AgentMarkdownBlock.block(at: (twoTables as NSString).range(of: "| 3").location, in: twoTables))
      == "| c |\n|---|\n| 3 |", "两张表分得开")

print(fail == 0 ? "\n✅ 全部 \(pass) 项通过" : "\n❌ \(fail) 项失败（共 \(pass + fail)）")
exit(fail == 0 ? 0 : 1)
