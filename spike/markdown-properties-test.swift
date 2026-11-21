// 运行：复制成 main.swift，与 Sources/App/MarkdownProperties.swift 一起 swiftc 编译执行
import Foundation
var fails = 0
func check(_ c: Bool, _ m: String) { if !c { fails += 1; print("FAIL", m) } }
let t = "---\ntitle: \"A: b\"\nprogress: 60%\ntags:\n  - x\n  - y\nurl: http://a\n---\n# 正文\n"
let e = MarkdownProperties.entries(in: t)
check(e.map(\.key) == ["title", "progress", "tags", "url"], "keys \(e.map(\.key))")
check(e[0].value == "A: b" && e[1].value == "60%" && e[2].value == "x, y" && !e[2].editable, "values")
let t2 = MarkdownProperties.setting("progress", to: "80%", in: t)
check(t2 == t.replacingOccurrences(of: "60%", with: "80%"), "replace one line only")
let t3 = MarkdownProperties.setting("status", to: "在读", in: t)
check(t3.contains("url: http://a\nstatus: 在读\n---\n# 正文"), "append before close")
let t4 = MarkdownProperties.setting("p", to: "1", in: "# 没有\n")
check(t4 == "---\np: 1\n---\n# 没有\n", "create")
check(MarkdownProperties.removing("tags", from: t) == "---\ntitle: \"A: b\"\nprogress: 60%\nurl: http://a\n---\n# 正文\n", "remove multi-line")
check(MarkdownProperties.setting("tags", to: "z", in: t) == t, "list not editable")
check(MarkdownProperties.setting("n", to: "a: b", in: t4).contains("n: \"a: b\""), "quote")
check(MarkdownProperties.entries(in: "# x\n---\na: 1\n---").isEmpty, "not at top")
print(fails == 0 ? "ALL PASS" : "\(fails) FAILED")
