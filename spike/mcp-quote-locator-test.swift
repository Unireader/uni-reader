// MCP 引文定位（OCR 行里按字符裁剪，`MCPQuoteLocator`）。运行：
//   cp spike/mcp-quote-locator-test.swift /tmp/main.swift && swiftc Sources/App/PageText.swift Sources/App/OCRTextSelect.swift Sources/MCP/MCPQuoteLocator.swift /tmp/main.swift -o /tmp/mcpq && /tmp/mcpq
// 覆盖：行内子串（框不再是整行、末端贴字）、行首/行末、跨两行（首行裁到行末、次行裁到引文末）、
//       空白/换行/大小写不影响命中、找不到 → nil、单字框优先于权重、乱序行按阅读顺序拼。
import Foundation

var pass = 0, fail = 0
func check(_ c: Bool, _ m: String) { if c { pass += 1; print("  ✅ \(m)") } else { fail += 1; print("  ❌ \(m)") } }
func near(_ a: Double, _ b: Double, _ eps: Double = 1e-6) -> Bool { abs(a - b) < eps }

// 两行等宽中文（权重路径：每字 1.0，所以字符边界就是等分）
let l1 = TextRun(text: "微积分基本定理", x: 0.1, y: 0.10, w: 0.7, h: 0.03)   // 7 字，每字宽 0.1
let l2 = TextRun(text: "是牛顿莱布尼茨", x: 0.1, y: 0.15, w: 0.7, h: 0.03)   // 7 字

print("行内子串")
if let r = MCPQuoteLocator.locate(quote: "基本定理", in: [l1, l2]) {
    check(r.count == 1, "一条框")
    check(near(r[0].minX, 0.1 + 0.3) && near(r[0].maxX, 0.8), "框从第 4 字起到行末（不是整行）：minX=\(r[0].minX) maxX=\(r[0].maxX)")
} else { check(false, "应命中") }
if let r = MCPQuoteLocator.locate(quote: "微积分", in: [l1, l2]) {
    check(near(r[0].minX, 0.1) && near(r[0].maxX, 0.4), "行首三字：maxX 贴在第 3 字后 = 0.4，不是行末 0.8")
} else { check(false, "应命中") }

print("跨行")
if let r = MCPQuoteLocator.locate(quote: "定理是牛顿", in: [l1, l2]) {
    check(r.count == 2, "两条框")
    check(near(r[0].minX, 0.6) && near(r[0].maxX, 0.8) && near(r[0].minY, 0.10), "首行：从「定」到行末")
    check(near(r[1].minX, 0.1) && near(r[1].maxX, 0.4) && near(r[1].minY, 0.15), "次行：行首到「顿」")
} else { check(false, "跨行应命中") }
check(MCPQuoteLocator.locate(quote: "定理\n是牛顿", in: [l1, l2])?.count == 2, "引文带换行照样命中")
check(MCPQuoteLocator.locate(quote: " 定理 是 牛顿 ", in: [l1, l2])?.count == 2, "引文带空格照样命中")

print("找不到")
check(MCPQuoteLocator.locate(quote: "不存在的话", in: [l1, l2]) == nil, "不存在 → nil")
check(MCPQuoteLocator.locate(quote: "", in: [l1, l2]) == nil, "空引文 → nil")
check(MCPQuoteLocator.locate(quote: "微积分基本定理是牛顿莱布尼茨多出来", in: [l1, l2]) == nil, "比全文还长 → nil")

print("西文与大小写")
let e1 = TextRun(text: "The quick brown fox", x: 0.1, y: 0.3, w: 0.6, h: 0.03)
if let r = MCPQuoteLocator.locate(quote: "QUICK BROWN", in: [e1]) {
    check(r.count == 1 && r[0].minX > 0.1 && r[0].maxX < 0.7, "不区分大小写，框在行内（\(r[0].minX)…\(r[0].maxX)）")
} else { check(false, "应命中") }

print("单字框优先")
let boxed = TextRun(text: "abcd", x: 0.0, y: 0.5, w: 1.0, h: 0.03, chars: [0, 0.1, 0.2, 0.6, 1.0])   // 真实字位不等分
if let r = MCPQuoteLocator.locate(quote: "c", in: [boxed]) {
    check(near(r[0].minX, 0.2) && near(r[0].maxX, 0.6), "用单字框裁：c 在 0.2…0.6")
} else { check(false, "应命中") }

print("乱序行按阅读顺序")
let a = TextRun(text: "第二行", x: 0.1, y: 0.20, w: 0.3, h: 0.03)
let b = TextRun(text: "第一行", x: 0.1, y: 0.10, w: 0.3, h: 0.03)
let c = TextRun(text: "右半", x: 0.5, y: 0.10, w: 0.2, h: 0.03)   // 与 b 同一行、靠右
if let r = MCPQuoteLocator.locate(quote: "行右半第二", in: [a, b, c]) {
    check(r.count == 3, "跨三段（第一行末字 + 右半 + 第二行前两字）")
    check(near(r[0].minY, 0.10) && near(r[1].minX, 0.5) && near(r[2].minY, 0.20), "顺序：第一行 → 右半 → 第二行")
} else { check(false, "乱序行应按阅读顺序命中") }

print("\n\(pass) 通过, \(fail) 失败")
exit(fail == 0 ? 0 : 1)
