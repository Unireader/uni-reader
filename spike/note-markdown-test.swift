// 笔记正文 Markdown → 气泡用 AttributedString 的折算（`NoteMarkdown`）测试。运行：
//   cp spike/note-markdown-test.swift /tmp/main.swift && swiftc Sources/App/NoteMarkdown.swift /tmp/main.swift -o /tmp/nmt && /tmp/nmt
// （须命名为 main.swift：swiftc 多文件时顶层代码只允许在 main.swift）
import AppKit
import Foundation

var pass = 0, fail = 0
func check(_ c: Bool, _ m: String) { if c { pass += 1; print("  ✅ \(m)") } else { fail += 1; print("  ❌ \(m)") } }

/// 某一段文字在结果里带的行内样式（没有 = nil）。
func intent(of needle: String, in a: AttributedString) -> InlinePresentationIntent? {
    guard let r = a.range(of: needle) else { return nil }
    return a[r].runs.first?.inlinePresentationIntent
}

print("— 块级折算 —")
check(NoteMarkdown.foldBlocks("# 标题") == "**标题**", "一级标题 → 粗体行")
check(NoteMarkdown.foldBlocks("### 三级 ###") == "**三级**", "闭合井号也去掉")
check(NoteMarkdown.foldBlocks("- 一项") == "• 一项", "无序列表 → •")
check(NoteMarkdown.foldBlocks("  * 缩进项") == "  • 缩进项", "缩进保留")
check(NoteMarkdown.foldBlocks("- [ ] 待办") == "☐ 待办", "任务项未完成 → ☐")
check(NoteMarkdown.foldBlocks("- [x] 已做") == "☑ 已做", "任务项完成 → ☑")
check(NoteMarkdown.foldBlocks("> 引用一句") == "│ 引用一句", "引用 → │")
check(NoteMarkdown.foldBlocks("---") == "———", "水平线")
check(NoteMarkdown.foldBlocks("- - -") == "———", "空格分隔的水平线不被当成列表")
check(NoteMarkdown.foldBlocks("1. 第一") == "1. 第一", "有序列表原样")
check(NoteMarkdown.foldBlocks("```swift\nlet a = 1\n```\n后面") == "`let a = 1`\n后面", "围栏去掉、内容包成行内代码")
check(NoteMarkdown.foldBlocks("```\nsay `hi`\n```") == "say `hi`", "行里已有反引号的不再包")
check(NoteMarkdown.foldBlocks("正文\n\n空行保留") == "正文\n\n空行保留", "空行不丢")
check(NoteMarkdown.foldBlocks("a-b 不是列表") == "a-b 不是列表", "行中的连字符不动")

print("— 行内样式 —")
let a = NoteMarkdown.attributed("**粗** *斜* `码` ~~删~~ [链](https://x.y) 普通")
check(String(a.characters) == "粗 斜 码 删 链 普通", "记号都去掉了，文字齐全")
check(intent(of: "粗", in: a)?.contains(.stronglyEmphasized) == true, "粗体")
check(intent(of: "斜", in: a)?.contains(.emphasized) == true, "斜体")
check(intent(of: "码", in: a)?.contains(.code) == true, "行内代码")
check(intent(of: "删", in: a)?.contains(.strikethrough) == true, "删除线")
check(a.range(of: "链").map { a[$0].runs.first?.link != nil } == true, "链接带 URL")
check(intent(of: "普通", in: a) == nil, "普通文字无样式")

let h = NoteMarkdown.attributed("# 标题\n- 项")
check(String(h.characters) == "标题\n• 项", "块级折算后再解析：标题文字 + 列表点，换行保留")
check(intent(of: "标题", in: h)?.contains(.stronglyEmphasized) == true, "标题成了粗体")
check(NoteMarkdown.plain("**加粗** 和 `code`") == "加粗 和 code", "plain 只留文字")
check(NoteMarkdown.plain("") == "" && String(NoteMarkdown.attributed("").characters) == "", "空串不炸")
check(String(NoteMarkdown.attributed("2 * 3 * 4").characters) == "2 * 3 * 4", "孤立星号原样（不是强调）")

print("— 量高度用的 NSAttributedString —")
let font = NSFont.systemFont(ofSize: 12)
let ns = NoteMarkdown.nsAttributed("**粗体** 普通 `code`", font: font, lineSpacing: 3)
check(ns.string == "粗体 普通 code", "文字一致")
let boldFont = ns.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
check(boldFont.map { NSFontManager.shared.traits(of: $0).contains(.boldFontMask) } == true, "粗体段落成了粗体字体")
let plainFont = ns.attribute(.font, at: 3, effectiveRange: nil) as? NSFont
check(plainFont == font, "普通段是基础字体")
let codeFont = ns.attribute(.font, at: 6, effectiveRange: nil) as? NSFont
check(codeFont.map { $0.isFixedPitch } == true, "代码段是等宽字体")
let para = ns.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
check(para?.lineSpacing == 3, "行间距进了段落样式")


print("— 自然宽度（短文收窄用）—")
let f12 = NSFont.systemFont(ofSize: 12)
let wShort = NoteMarkdown.naturalWidth("短", font: f12)
let wLong = NoteMarkdown.naturalWidth("这一段是关键：先看定义再看例题。", font: f12)
check(wShort > 0 && wLong > wShort * 5, "字越多越宽（短 \(Int(wShort)) < 长 \(Int(wLong))）")
check(NoteMarkdown.naturalWidth("", font: f12) == 0 && NoteMarkdown.naturalWidth("\n\n", font: f12) == 0, "空文 / 只有空行 = 0")
check(NoteMarkdown.naturalWidth("a\n这一段是关键：先看定义再看例题。\nb", font: f12) == wLong, "取最宽那一行")
check(NoteMarkdown.naturalWidth("# 标题而已", font: f12) > NoteMarkdown.naturalWidth("标题而已", font: f12), "标题按放大后的粗体量，比同文正文宽")
check(NoteMarkdown.naturalWidth("- 一项", font: f12) > NoteMarkdown.naturalWidth("一项", font: f12) + 10, "列表项加上缩进")
check(NoteMarkdown.naturalWidth("- [ ] 一项", font: f12) > NoteMarkdown.naturalWidth("- 一项", font: f12), "任务项比普通列表项再宽一格（勾选框）")
check(NoteMarkdown.naturalWidth("> 引用", font: f12) > NoteMarkdown.naturalWidth("引用", font: f12), "引用加上竖条")
check(NoteMarkdown.naturalWidth("---\n短", font: f12) == wShort, "水平线不撑宽")
check(NoteMarkdown.naturalWidth("**短**", font: f12) >= wShort, "粗体不比常规窄")
print("\n\(pass) passed, \(fail) failed")
exit(fail == 0 ? 0 : 1)
