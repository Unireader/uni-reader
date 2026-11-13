// 离屏验证 2026-11-13 工具调用展开后的显示（用户截图：整屏等宽字、行号贴着正文、末尾一大段重复的 JSON）。
// 编的是**真代码**：`Sources/Agent/AgentToolText.swift`（去掉 Kimi 拼的 `<mcp-result-extras>`、JSON 排成多行）、
// `Sources/Window/AI/AgentToolOutputView.swift`（浅底块、行号一栏、长输出先显示开头）、`AgentDisclosureView`。
// 依赖已编好的包模块（先按 AGENTS.md 编一次 Debug 包）。运行：
//
//   D=build/dev/Build/Products/Debug; AD=$(cd $D && pwd); O=/tmp/agent-tool-output; mkdir -p $O && cp -R $D/Highlighter_Highlighter.bundle $D/SwiftMath_SwiftMath.bundle $O/ \
//   && cp spike/agent-tool-output-test.swift $O/main.swift && swiftc -O -I $D -F $D -framework GrapherEmbed -framework GrapherKit -framework GrapherRender \
//      -Xlinker -rpath -Xlinker $AD $D/MarkdownEngine.o $D/MarkdownEngineLatex.o $D/SwiftMath.o $D/Highlighter.o \
//      Sources/Support/L.swift Sources/Markdown/MarkdownNoteEditor.swift Sources/Markdown/LatexCompat.swift Sources/Markdown/GrapherBlocks.swift \
//      Sources/Markdown/TableEditMenu.swift Sources/Window/AI/AgentMarkdownView.swift Sources/Window/AI/AgentMarkdownBlocksView.swift \
//      Sources/Window/AI/AgentRowView.swift Sources/Window/AI/AgentToolOutputView.swift Sources/Agent/AgentToolText.swift \
//      $O/main.swift -o $O/t && $O/t $O
//
// 盯这几件事：
//  1. `AgentToolText.clean`：有正文时去掉 `<mcp-result-extras>`（含没收尾的）；只有那段时把里面的 JSON 排成多行；
//     整段 JSON 排成多行；不完整的 / 普通文字原样；
//  2. 预览：超过 12 行或 1500 字只显示开头、有「显示全部」按钮；点开全部、再点收起；短的没有按钮；
//  3. `  36\t正文` 这种行：正文从行号栏右边两格开始，折行的接续行也从那里开始（原来贴着行号）；
//  4. 放进折叠块：流式更新就地换文字（`update(plain:)` 吃下），高度跟着变；
// 另出样张 $O/tool-light.png、$O/tool-dark.png，肉眼对一遍。
import AppKit
import MarkdownEngine
import SwiftUI

// MARK: - 桩（与本题无关的类型）

final class WorkspaceWikiIndex: WikiLinkResolver, EmbeddedImageProvider, @unchecked Sendable {
    func resolve(displayName: String, range: NSRange) -> WikiLinkResolution? { nil }
    func image(for reference: EmbeddedImageRequest) -> NSImage? { nil }
    func fingerprint() -> AnyHashable { 0 }
}

final class NoteLinkCompleter {
    var pending: InlineReplacementRequest?
    var wikiActive = false
    func selectionChanged(_ state: InlineSelectionState?) {}
    func caretRectChanged(_ r: CGRect) {}
    func key(_ k: InlinePreviewKey) -> Bool { false }
}

enum NoteBubble {
    static let editorFontSizeKey = "spike.editorFontSize"
    static let defaultEditorFont: CGFloat = 13
}

final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void
    init(_ title: String, action handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }
    required init(coder: NSCoder) { fatalError() }
    @objc private func fire() { handler() }
}

// MARK: - 断言

let outDir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/tmp/agent-tool-output")
setvbuf(stdout, nil, _IONBF, 0)
var failures = 0
var checks = 0
func check(_ ok: Bool, _ what: String) {
    checks += 1
    if !ok { failures += 1; print("  ✗ \(what)") }
}

// MARK: - 样本（照用户截图）

let numberedBody = """
  36\t- 只有 4 种电平的码元只能区分 4 种情况，即 2 比特（00/01/10/11），装不下 4 比特
  37\t
  38\t**一句话：能表示的状态数每翻一倍，每个码元就多装 1 比特信息。**
  39\t
  40\t## 例题
  41\t
  42\t> 某信道的波特率为 1000 Baud，若令其数据传输速率达到 4 kb/s，则一个信号码元所取的有效离散值个数为（ ）
  43\t
  44\t计算：
  45\t
  46\t- 每码元比特数 = $4000 \\div 1000 = 4$ 比特
  47\t- $n = 2^4 = 16$
  48\t
  49\t**答案：16 种离散值。**
"""
let extras = """
<mcp-result-extras>
{"structuredContent":{"characters":1129,"end_line":56,"file_missing":false,"line_count":56,"link":"unireader://open?ws=%2FUsers%2Fxvan","text":"# 波特率\\n\\n> 来源：2027计算机网络","title":"波特率与比特率"}}
</mcp-result-extras>
"""

// MARK: 1. 清理

func testClean() {
    let cleaned = AgentToolText.clean(numberedBody + "\n" + extras)
    check(cleaned == numberedBody, "正文 + extras → 只剩正文")
    check(cleaned.hasPrefix("  36\t"), "第一行行号前的空格留着（和下面的行号对齐）")
    let open = numberedBody + "\n<mcp-result-extras>\n{\"structuredContent\":{\"text\":\"截断在这"
    check(AgentToolText.clean(open) == numberedBody, "extras 没收尾（被截断）→ 去到末尾")
    check(AgentToolText.clean("正文\n" + extras + "\n  后面还有") == "正文\n  后面还有", "extras 后面还有字 → 接上（开头空格留着）")
    let only = AgentToolText.clean(extras)
    check(only.hasPrefix("{\n") && only.contains("\"title\" : \"波特率与比特率\"") && !only.contains("structuredContent"),
          "只有 extras → 拆掉 structuredContent 那层、排成多行：\(only.prefix(80))")
    check(only.contains("unireader://open?ws=%2FUsers%2Fxvan"), "斜杠不转义")
    let json = AgentToolText.clean("{\"b\":1,\"a\":[1,2]}")
    check(json == "{\n  \"a\" : [\n    1,\n    2\n  ],\n  \"b\" : 1\n}", "整段 JSON → 多行、键按字母序：\(json)")
    check(AgentToolText.clean("{\"a\": 1, \"b\": ") == "{\"a\": 1, \"b\": ", "不完整的 JSON 原样（流式推参数）")
    check(AgentToolText.clean("已加入回收站") == "已加入回收站", "普通文字原样")
    check(AgentToolText.clean("<mcp-result-extras>不是 JSON</mcp-result-extras>") == "不是 JSON", "extras 里不是 JSON → 原样去掉标签")
    let big = "[" + Array(repeating: "1", count: 5000).joined(separator: ",") + "]"
    check(AgentToolText.clean(big) == big, "太长的不解析")
}

// MARK: 2. 预览

@MainActor
func host(_ v: NSView, width: CGFloat) -> NSView {
    let c = NSView(frame: NSRect(x: 0, y: 0, width: width + 20, height: 2000))
    v.translatesAutoresizingMaskIntoConstraints = false
    c.addSubview(v)
    NSLayoutConstraint.activate([
        v.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 10),
        v.topAnchor.constraint(equalTo: c.topAnchor, constant: 10),
        v.widthAnchor.constraint(equalToConstant: width),
    ])
    c.layoutSubtreeIfNeeded()
    c.layoutSubtreeIfNeeded()
    return c
}

@MainActor
func testPreview() {
    let long = (1...30).map { "line \($0)" }.joined(separator: "\n")
    let p = AgentToolOutputView.preview(long)
    check(p.cut && p.lines == 30 && p.text.split(separator: "\n").count == 12 && !p.text.hasSuffix("…"), "30 行 → 前 12 行")
    let short = AgentToolOutputView.preview("a\nb")
    check(!short.cut && short.text == "a\nb", "短的不截")
    let wide = AgentToolOutputView.preview(String(repeating: "字", count: 3000))
    check(wide.cut && wide.text.count == 1501 && wide.text.hasSuffix("…"), "一行 3000 字 → 1500 字 + …")

    let v = AgentToolOutputView(text: long)
    _ = host(v, width: 320)
    check(v.hasToggle && v.shownText.split(separator: "\n").count == 12, "视图：长输出先显示 12 行、有按钮")
    let h1 = v.frame.height
    v.showsAllForTest()
    v.superview?.layoutSubtreeIfNeeded(); v.superview?.layoutSubtreeIfNeeded()
    let h2 = v.frame.height
    check(v.shownText == long && h2 > h1 * 2, "点「显示全部」→ 全文、变高（\(h1) → \(h2)）")
    v.showsAllForTest()
    v.superview?.layoutSubtreeIfNeeded(); v.superview?.layoutSubtreeIfNeeded()
    check(abs(v.frame.height - h1) < 0.5, "再点收起 → 高度回去")

    let s = AgentToolOutputView(text: "ok")
    _ = host(s, width: 320)
    check(!s.hasToggle, "短输出没有按钮")
    check(s.frame.height > 20 && s.frame.height < 34, "一行输出的高度合理：\(s.frame.height)")
}

// MARK: 3. 行号栏

@MainActor
func testNumbers() {
    check(AgentToolOutputView.numberColumn("  36\t- x") == 4, "  36⇥ → 4")
    check(AgentToolOutputView.numberColumn("12345\tx") == 5, "12345⇥ → 5")
    check(AgentToolOutputView.numberColumn("abc\tx") == nil, "字母不算")
    check(AgentToolOutputView.numberColumn("   \tx") == nil, "只有空格不算")
    check(AgentToolOutputView.numberColumn("12 34\tx") == nil, "中间有空格不算")
    check(AgentToolOutputView.numberColumn("--- Page 47 · ocr ---") == nil, "普通行不算")

    let v = AgentToolOutputView(text: numberedBody)
    v.showsAllForTest()
    _ = host(v, width: 300)
    guard let tv = v.subviews.compactMap({ $0 as? NSTextView }).first, let lm = tv.layoutManager, let ts = tv.textStorage else {
        check(false, "找不到文字视图"); return
    }
    let font = NSFont.monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
    let ch = ("0" as NSString).size(withAttributes: [.font: font]).width
    let expectX = ceil(ch * 6)
    let s = ts.string as NSString
    // 第一行「  36⇥- 只有…」：「-」的位置
    let dash = s.range(of: "- 只有").location
    let gx = lm.location(forGlyphAt: lm.glyphIndexForCharacter(at: dash)).x
    let frag = lm.lineFragmentRect(forGlyphAt: lm.glyphIndexForCharacter(at: dash), effectiveRange: nil)
    check(abs(frag.minX + gx - expectX) < 0.6, "正文从行号栏右边两格开始：x=\(frag.minX + gx)，应为 \(expectX)（行号宽 \(ch * 4)）")
    // 这一行在 300 宽里会折行：接续行的起点
    let wrapAt = s.range(of: "装不下").location
    let f2 = lm.lineFragmentUsedRect(forGlyphAt: lm.glyphIndexForCharacter(at: wrapAt), effectiveRange: nil)
    let f1 = lm.lineFragmentUsedRect(forGlyphAt: lm.glyphIndexForCharacter(at: dash), effectiveRange: nil)
    check(f2.minY > f1.minY, "长行折行了（测试前提）")
    check(abs(f2.minX - expectX) < 0.6, "折行的接续行与正文对齐：x=\(f2.minX)")
    // 不带行号的输出：制表位按 4 格
    let plain = AgentToolOutputView.attributed("a\tb", fontSize: NSFont.smallSystemFontSize)
    let ps = plain.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
    check(ps?.headIndent == 0 && abs((ps?.defaultTabInterval ?? 0) - ch * 4) < 0.01, "普通输出没有缩进、制表 4 格")
}

// MARK: 4. 放进折叠块

@MainActor
func findButton(_ v: NSView) -> NSButton? {
    for s in v.subviews {
        if let b = s as? NSButton, b.bezelStyle == .disclosure { return b }
        if let b = findButton(s) { return b }
    }
    return nil
}

@MainActor
func testDisclosure() {
    let out = AgentToolOutputView(text: "第一段")
    let header = AgentRowView([NSTextField(labelWithString: "read_pages")], spacing: 6)
    let d = AgentDisclosureView(header: header, body: out)
    let c = host(d, width: 320)
    let closed = d.frame.height
    check(d.update(plain: "第一段\n第二段"), "折着：吃下流式更新")
    check(out.text == "第一段\n第二段", "折着：文字换了")
    findButton(d)?.performClick(nil)
    c.layoutSubtreeIfNeeded(); c.layoutSubtreeIfNeeded()
    let open = d.frame.height
    check(open > closed + 30, "展开后变高（\(closed) → \(open)）")
    check(abs(out.frame.width - 320) < 0.5, "输出块铺满整行宽")
    check(d.update(plain: (1...8).map { "第 \($0) 段" }.joined(separator: "\n")), "展开着：吃下更新")
    c.layoutSubtreeIfNeeded(); c.layoutSubtreeIfNeeded()
    check(d.frame.height > open + 50, "展开着更新：高度跟着变（\(open) → \(d.frame.height)）")
}

// MARK: 样张

@MainActor
func looks() {
    let readPages = """
    --- Page 47 · ocr ---
    第2章 物理层 35
    注意
    与PSK不同，DPSK（差分相移键控）是一种相对调相方式，它通过检测当前码元与前一个码元的载波相位差来传输数字信息。例如，用相位是否发生变化分别表示1和0。
    考点追踪 QAM调制阶数与码元比特数的关系（2009、2023）
    4）正交幅度调制（Quadrature Amplitude Modulation，QAM）。在载波频率相同的前提下，通过同时调制振幅和相位，形成复合信号。
    QAM基于正交载波，通常使用两路载波，分别对应正弦波和余弦波。
    0000 0100 1100 1000
    0001 0101 1101 1001
    0011 0111 1111 1011
    0010 0110 1110 1010
    (a) QAM-16 (b) QAM-64
    图 2.4 QAM-16 和 QAM-64 的星座图
    假设波特率为B，采用m个相位，每个相位有n种振幅，则该QAM的数据传输速率R为
    R = Blog2(m×n)（单位为 b/s）
    """ + "\n" + extras
    for (name, app) in [("light", NSAppearance(named: .aqua)!), ("dark", NSAppearance(named: .darkAqua)!)] {
        NSApp.appearance = app
        let c = NSView(frame: NSRect(x: 0, y: 0, width: 760, height: 360))
        c.appearance = app
        c.wantsLayer = true
        app.performAsCurrentDrawingAppearance { c.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor }
        var x: CGFloat = 10
        for (title, raw, all) in [("read_pages", readPages, false), ("read_markdown", numberedBody + "\n" + extras, true)] {
            let out = AgentToolOutputView(text: AgentToolText.clean(raw))
            if all { out.showsAllForTest() }
            let ok = NSImageView(image: NSImage(systemSymbolName: "checkmark.circle", accessibilityDescription: nil)!)
            ok.contentTintColor = .systemGreen
            let t = NSTextField(labelWithString: title)
            t.font = .monospacedSystemFont(ofSize: NSFont.preferredFont(forTextStyle: .callout).pointSize, weight: .regular)
            let d = AgentDisclosureView(header: AgentRowView([ok, t], spacing: 6), body: out)
            d.translatesAutoresizingMaskIntoConstraints = false
            c.addSubview(d)
            NSLayoutConstraint.activate([
                d.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: x),
                d.topAnchor.constraint(equalTo: c.topAnchor, constant: 10),
                d.widthAnchor.constraint(equalToConstant: 360),
            ])
            findButton(d)?.performClick(nil)
            x += 380
        }
        c.layoutSubtreeIfNeeded(); c.layoutSubtreeIfNeeded()
        guard let rep = c.bitmapImageRepForCachingDisplay(in: c.bounds) else { continue }
        c.cacheDisplay(in: c.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: outDir.appendingPathComponent("tool-\(name).png"))
    }
    NSApp.appearance = nil
}

extension AgentToolOutputView {
    /// 等同点一下底下的按钮。
    func showsAllForTest() {
        for case let b as NSButton in subviews where b.action != nil { b.performClick(nil); return }
    }
}

_ = NSApplication.shared
MainActor.assumeIsolated {
    testClean()
    testPreview()
    testNumbers()
    testDisclosure()
    looks()
}
print(failures == 0 ? "\n✅ \(checks) 项全过（样张在 \(outDir.path)）" : "\n❌ \(checks) 项里 \(failures) 项没过")
exit(failures == 0 ? 0 : 1)
