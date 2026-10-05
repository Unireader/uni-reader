// 离屏验证 Agent 面板 2026-10-05 这一批：用户消息气泡改走 Markdown 引擎、代码块着色、`==高亮==`。
// 编的是**真代码**（`AgentUserMessageView` / `AgentMarkdownView` / `AgentCodeHighlighter`），只把图片缩略图、
// 工作区 wiki 索引这些跟本题无关的类型换成桩。依赖已编好的包模块（先按 AGENTS.md 编一次 Debug 包）。运行：
//
//   D=build/dev/Build/Products/Debug; O=/tmp/agent-user-bubble; mkdir -p $O && cp -R $D/Highlighter_Highlighter.bundle $D/SwiftMath_SwiftMath.bundle $O/ \
//   && cp spike/agent-user-bubble-test.swift $O/main.swift && swiftc -I $D $D/MarkdownEngine.o $D/MarkdownEngineLatex.o $D/SwiftMath.o $D/Highlighter.o \
//      Sources/Support/L.swift Sources/Markdown/MarkdownNoteEditor.swift Sources/Window/AI/AgentMarkdownView.swift \
//      Sources/Window/AI/AgentUserMessageView.swift Sources/Agent/AgentMarkdownBlocks.swift $O/main.swift -o $O/t && $O/t $O
//
// （两个资源包要和可执行文件放一起：包里的 `Bundle.module` 按可执行文件所在目录找。）
// 盯五件事：
//  1. 宽度估算：块级结构（标题 / 列表 / 引用 / 代码块 / 表格 / 块公式 / 图片）撑满，其余按原文量；
//  2. 气泡按内容收窄、靠右，长的折到上限（面板宽 − 48）；
//  3. 🔴 **估出来的宽度不能比排出来的窄**：按估的宽度排出来的高度 = 按上限宽度排出来的高度（没多折一行）；
//  4. 回放分片就地换文字（`update(text:)`）后宽度跟着变；
//  5. 着色器：没写语言 / 不认识的语言不着色（也不慢），别名认得，颜色深浅外观各一套，长度对得上，有缓存；
//  6. 右键：表格上出「复制表格」且不留错位选区、代码块上出「复制代码」、不重复加项、剪贴板内容对（用临时剪贴板）。
// 另出样张：$O/look-light.png、$O/look-dark.png（气泡、代码块底色与着色、荧光笔底色），
// $O/look-code-selected.png（整块选中有折行的代码块：折行行的底色不盖选区、围栏不露出来——要引擎 0.13.0-unireader.2）。
import AppKit
import MarkdownEngine
import SwiftUI

// MARK: - 桩（与本题无关的类型）

struct AgentImage: Equatable {
    var data = Data()
}

final class AgentImageThumbView: NSView {
    init(image: AgentImage, side: CGFloat) { super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError() }
}

final class WorkspaceWikiIndex: WikiLinkResolver, EmbeddedImageProvider, @unchecked Sendable {
    func resolve(displayName: String, range: NSRange) -> WikiLinkResolution? { nil }
    func image(for reference: EmbeddedImageRequest) -> NSImage? { nil }
    func fingerprint() -> AnyHashable { 0 }
}

/// 笔记编辑框读的设置项（`MarkdownNoteEditor`），这里用不到。
enum NoteBubble {
    static let editorFontSizeKey = "spike.editorFontSize"
    static let defaultEditorFont: CGFloat = 13
}

/// 同 `Reader/ReaderBubbleViews.swift` 那份（那个文件太大，不编进来）。
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

UserDefaults.standard.set(true, forKey: "NSConstraintBasedLayoutLogUnsatisfiable")
let outDir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/tmp/agent-user-bubble")
var failures = 0
var checks = 0
func check(_ ok: Bool, _ what: String) {
    checks += 1
    if !ok { failures += 1; print("  ✗ \(what)") }
}

@MainActor
func pump(_ seconds: TimeInterval = 0.6) {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
}

// MARK: 1. 宽度估算

@MainActor
func testFittingWidth() {
    print("1. 宽度估算")
    let fs = AgentMarkdown.bodyFontSize
    for block in ["# 标题", "## Title", "- 一项", "* item", "+ item", "1. 第一", "12) twelve", "> 引用",
                  "```swift\nlet x = 1\n```", "| a | b |", "$$x^2$$", "看图 ![a](b.png)", "    缩进代码", "\t制表缩进",
                  "第一行\n- 第二行是列表"] {
        check(AgentMarkdown.fittingWidth(of: block, fontSize: fs) == nil, "块级结构应撑满：\(block.debugDescription)")
    }
    for plain in ["你好", "#话题不是标题", "-1 不是列表", "a **bold** b", "@论文.pdf 这篇讲了什么", "x == y 是比较"] {
        check(AgentMarkdown.fittingWidth(of: plain, fontSize: fs) != nil, "普通段落应按内容量：\(plain.debugDescription)")
    }
    let short = AgentMarkdown.fittingWidth(of: "你好", fontSize: fs) ?? 0
    check(short > 20 && short < 40, "「你好」约两个字宽（实得 \(short)）")
    let two = AgentMarkdown.fittingWidth(of: "短\n这一行比较长一些", fontSize: fs) ?? 0
    let longLine = AgentMarkdown.fittingWidth(of: "这一行比较长一些", fontSize: fs) ?? 0
    check(two == longLine, "多行取最宽那行（\(two) vs \(longLine)）")
    let plainW = AgentMarkdown.fittingWidth(of: "abc def ghi", fontSize: fs) ?? 0
    let codeW = AgentMarkdown.fittingWidth(of: "abc `def` ghi", fontSize: fs) ?? 0
    check(codeW > plainW, "含行内代码按等宽量、宁宽勿窄（\(codeW) > \(plainW)）")
}

// MARK: 2~4. 气泡布局

/// 一个对话记录的样子：竖排 stack，条目宽 = 面板宽 − 28（同 `AgentChatNSView.refreshTranscript`）。
@MainActor
final class Harness {
    let width: CGFloat
    let win: NSWindow
    let transcript = NSStackView()

    init(width: CGFloat, appearance: NSAppearance.Name) {
        self.width = width
        // 摆在屏幕外：不在用户屏幕上闪一下
        win = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: width, height: 1600),
                       styleMask: [.borderless], backing: .buffered, defer: false)
        win.appearance = NSAppearance(named: appearance)
        let root = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 1600))
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        win.contentView = root
        transcript.orientation = .vertical
        transcript.alignment = .leading
        transcript.spacing = 12
        transcript.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        transcript.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(transcript)
        NSLayoutConstraint.activate([
            transcript.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            transcript.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            transcript.topAnchor.constraint(equalTo: root.topAnchor),
        ])
        win.orderFront(nil)
    }

    /// 同 `refreshTranscript`：先进 stack，再激活宽度约束。
    func add(_ v: NSView) {
        transcript.addArrangedSubview(v)
        v.widthAnchor.constraint(equalTo: transcript.widthAnchor, constant: -28).isActive = true
    }

    func user(_ text: String) -> AgentUserMessageView {
        let v = AgentUserMessageView(text: text, images: [], id: UUID())
        add(v)
        return v
    }

    func snap(_ name: String) {
        guard let root = win.contentView else { return }
        root.layoutSubtreeIfNeeded()
        let h = transcript.fittingSize.height
        let r = NSRect(x: 0, y: root.bounds.height - h, width: width, height: h)
        guard let rep = root.bitmapImageRepForCachingDisplay(in: r) else { return }
        root.cacheDisplay(in: r, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return }
        let url = outDir.appendingPathComponent(name + ".png")
        try? png.write(to: url)
        print("  样张 \(url.path)")
    }
}

/// 按某个宽度排一段正文，返回引擎报回来的高度（拿来比「有没有多折一行」）。
@MainActor
func renderedHeight(_ text: String, width: CGFloat, in h: Harness) -> CGFloat {
    let md = AgentMarkdownView(text: text, fontSize: AgentMarkdown.bodyFontSize, documentId: "probe-\(UUID())")
    md.translatesAutoresizingMaskIntoConstraints = false
    h.transcript.addArrangedSubview(md)
    md.widthAnchor.constraint(equalToConstant: width).isActive = true
    pump(0.5)
    let height = md.intrinsicContentSize.height
    md.removeFromSuperview()
    return height
}

@MainActor
func testBubbles() {
    print("2~4. 气泡布局")
    let panel: CGFloat = 360
    let h = Harness(width: panel, appearance: .aqua)
    let item = panel - 28
    let cap = item - 48            // 气泡宽上限
    let bodyCap = cap - 2 * AgentUserMessageView.padX

    let short = h.user("你好")
    let long = h.user(String(repeating: "这是一段很长的话，用来确认超过上限时按上限折行。", count: 4))
    let list = h.user("- 第一项\n- 第二项")
    // 「估的宽度不能比排的窄」：各种行内样式都试一遍
    let samples = [
        "先看第 **12** 页的定义，再对照例题",
        "@高等数学.pdf 第三章讲的是什么",
        "把 `fittingWidth` 和 `layout()` 都看一下",
        "公式 $\\int_0^1 x^2 dx$ 怎么算",
        "==重点== 和 *斜体* 混着",
        "Short\nA bit longer line here\nmid",
        "English sentence with **bold words** and a [link](https://example.com).",
    ]
    let sampleViews = samples.map { h.user($0) }
    pump(1.2)

    // 🔴 气泡只在给定宽度里挑，绝不反过来把面板 / 窗口撑宽（曾用 750 + 常数 10000，窗口被撑到 1 万多 pt）
    check(abs(h.win.frame.width - panel) < 0.5, "窗口没被撑宽（\(h.win.frame.width)）")
    for v in [short, long, list] + sampleViews {
        check(abs(v.frame.width - item) < 0.5, "条目宽 = 面板宽 − 28（\(v.frame.width)）")
        check(v.markdown != nil && v.bubble != nil, "有正文就有气泡")
        check(!(v.bubble?.hasAmbiguousLayout ?? true), "气泡布局不含糊")
        check(!(v.markdown?.hasAmbiguousLayout ?? true), "正文布局不含糊")
    }
    let shortW = short.bubble?.frame.width ?? 0
    check(shortW > 30 && shortW < 80, "「你好」气泡收窄（实得 \(shortW)）")
    if let b = short.bubble, let sv = b.superview {
        check(abs(b.frame.maxX - sv.bounds.maxX) < 0.5, "气泡靠右（maxX \(b.frame.maxX) / \(sv.bounds.maxX)）")
    }
    let longW = long.bubble?.frame.width ?? 0
    check(abs(longW - cap) < 0.5, "长消息气泡到上限 \(cap)（实得 \(longW)）")
    let listW = list.bubble?.frame.width ?? 0
    check(abs(listW - cap) < 0.5, "块级结构撑到上限 \(cap)（实得 \(listW)）")
    let lineH = short.markdown?.intrinsicContentSize.height ?? 0
    check(lineH > 10 && lineH < 30, "一行高（实得 \(lineH)）")
    check(abs((short.bubble?.frame.height ?? 0) - lineH - 2 * AgentUserMessageView.padY) < 0.5, "气泡高 = 正文高 + 上下内边距")
    check((long.markdown?.intrinsicContentSize.height ?? 0) > lineH * 2.5, "长消息折成多行")

    for (s, v) in zip(samples, sampleViews) {
        let est = v.markdown?.frame.width ?? 0
        let atEst = v.markdown?.intrinsicContentSize.height ?? 0
        let atCap = renderedHeight(s, width: bodyCap, in: h)
        check(abs(atEst - atCap) < 0.5, "按估的宽 \(est) 排 = 按上限 \(bodyCap) 排，没多折行：\(s.debugDescription)（\(atEst) vs \(atCap)）")
        check(est < bodyCap || AgentMarkdown.fittingWidth(of: s, fontSize: AgentMarkdown.bodyFontSize) ?? .infinity >= bodyCap,
              "短的确实收窄了：\(s.debugDescription)（\(est)）")
    }

    // 4. 回放分片：同一句话又来了一截，就地换文字、宽度跟着变
    let before = short.bubble?.frame.width ?? 0
    check(short.update(text: "你好，再补一句比较长的话"), "有正文的就地更新")
    pump(0.6)
    let after = short.bubble?.frame.width ?? 0
    check(after > before + 40, "更新后气泡变宽（\(before) → \(after)）")
    let imageOnly = AgentUserMessageView(text: "", images: [AgentImage()], id: UUID())
    check(imageOnly.markdown == nil && imageOnly.bubble == nil, "只有图片：没有气泡")
    check(!imageOnly.update(text: "后来的文字"), "只有图片的那条不能就地补文字（交给重建）")
}

// MARK: 5. 着色器

@MainActor
func testHighlighter() {
    print("5. 代码着色")
    let hl = AgentCodeHighlighter.shared
    let code = "func add(_ a: Int, _ b: Int) -> Int {\n    return a + b // 和\n}"
    check(hl.highlight(code: code, language: nil) == nil, "没写语言不着色")
    check(hl.highlight(code: code, language: "  ") == nil, "空语言不着色")
    var t = Date()
    let swift = hl.highlight(code: code, language: "swift")
    print("  首次（含建两份 highlight.js）\(Int(Date().timeIntervalSince(t) * 1000))ms")
    check(swift != nil, "swift 着色")
    if let swift {
        check(swift.string == code, "正文原样（\(swift.length) vs \((code as NSString).length)）")
        var resolved: [(NSColor, NSColor)] = []
        swift.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: swift.length)) { v, _, _ in
            guard let c = v as? NSColor else { return }
            var l = NSColor.black, d = NSColor.black
            NSAppearance(named: .aqua)?.performAsCurrentDrawingAppearance { l = c.usingColorSpace(.sRGB) ?? .black }
            NSAppearance(named: .darkAqua)?.performAsCurrentDrawingAppearance { d = c.usingColorSpace(.sRGB) ?? .black }
            resolved.append((l, d))
        }
        check(resolved.count >= 3, "有多种颜色片段（\(resolved.count)）")
        check(resolved.contains { $0.0 != $0.1 }, "深浅外观各取各的颜色")
        let lights = Set(resolved.map { $0.0.description })
        check(lights.count >= 3, "浅色下至少三种颜色（\(lights.count)）")
    }
    t = Date()
    let again = hl.highlight(code: code, language: "Swift ")
    check(again === swift, "同一段代码走缓存（语言名大小写 / 空格不影响）")
    check(Date().timeIntervalSince(t) < 0.005, "缓存命中够快")
    check(hl.highlight(code: "x = 1", language: "py") != nil, "别名 py 认得")
    check(hl.highlight(code: "echo hi", language: "sh") != nil, "别名 sh 认得")
    t = Date()
    let lines = (0..<60).map { "graph TD; A\($0)-->B\($0)" }.joined(separator: "\n")
    check(hl.highlight(code: lines, language: "mermaid") == nil, "不认识的语言不着色")
    let firstUnknown = Date().timeIntervalSince(t)
    check(firstUnknown < 0.05, "不认识的语言不猜（\(Int(firstUnknown * 1000))ms）")
    let big = (0..<60).map { "let v\($0) = compute(\($0)) * 2 // 第 \($0) 行" }.joined(separator: "\n")
    t = Date()
    _ = hl.highlight(code: big, language: "swift")
    print("  60 行 swift 首次着色 \(Int(Date().timeIntervalSince(t) * 1000))ms（Debug 链接的包）")
    check(hl.codeFont(size: 13).isFixedPitch, "代码字体等宽")
    var alpha: CGFloat = 0
    NSAppearance(named: .darkAqua)?.performAsCurrentDrawingAppearance {
        alpha = hl.backgroundColor().usingColorSpace(.sRGB)?.alphaComponent ?? 0
    }
    check(alpha == 1, "代码块底色不透明（引擎会叠画两遍）")
}

// MARK: 6. 右键菜单

@MainActor
func firstTextView(_ v: NSView) -> NSTextView? {
    if let t = v as? NSTextView { return t }
    for s in v.subviews { if let t = firstTextView(s) { return t } }
    return nil
}

/// 合成一次右键：只调文本视图的 `menu(for:)`（真弹菜单会进模态跟踪、卡住）。右键落在表格图上时，
/// App 里事件也是从表格图一路传到文本视图手上的（离屏实测：图本身没有菜单）。
@MainActor
func rightClick(_ tv: NSTextView, at p: NSPoint) -> NSMenu? {
    let ev = NSEvent.mouseEvent(with: .rightMouseDown, location: tv.convert(p, to: nil), modifierFlags: [],
                                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: tv.window?.windowNumber ?? 0,
                                context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    return tv.menu(for: ev)
}

/// 某段文字在文本视图里的位置（第一个字的框中心）。
@MainActor
func point(of needle: String, in tv: NSTextView) -> NSPoint? {
    let r = (tv.string as NSString).range(of: needle)
    guard r.location != NSNotFound, let tlm = tv.textLayoutManager, let cs = tv.textContentStorage,
          let a = cs.location(cs.documentRange.location, offsetBy: r.location), let b = cs.location(a, offsetBy: 1),
          let tr = NSTextRange(location: a, end: b) else { return nil }
    tlm.ensureLayout(for: tr)
    var f = NSRect.zero
    tlm.enumerateTextSegments(in: tr, type: .standard, options: []) { _, rect, _, _ in f = rect; return false }
    return NSPoint(x: f.midX + tv.textContainerOrigin.x, y: f.midY + tv.textContainerOrigin.y)
}

@MainActor
func testContextMenu() {
    print("6. 右键菜单")
    let table = """
    | 中文 | 英文 | 备注一列写得很长很长很长很长很长很长很长很长很长很长很长很长 |
    |---|---|---|
    | 桌前检查 | desk checking | 一 |
    | 走查 | walkthrough | 二 |
    """
    let text = "段落一。\n\n```swift\nlet a = 1\n```\n\n\(table)\n\n尾巴。"
    let h = Harness(width: 520, appearance: .aqua)
    let md = AgentMarkdownView(text: text, fontSize: AgentMarkdown.bodyFontSize, documentId: "menu")
    h.add(md)
    pump(1.2)
    guard let tv = firstTextView(md) else { check(false, "找到引擎的文本视图"); return }
    let copyTable = "Copy Table", copyCode = "Copy Code"   // 离屏程序没有 App 的本地化表，L() 原样返回键

    // 宽表格：图在一层横向滚动视图里（引擎的 WideTableOverlay），右键点它的中间
    if let overlay = tv.subviews.first(where: { "\(type(of: $0))" == "WideTableOverlay" }) {
        let p = NSPoint(x: overlay.frame.midX, y: overlay.frame.midY)
        let menu = rightClick(tv, at: p)
        check(menu?.items.first?.title == copyTable, "右键表格：第一项是复制表格（\(menu?.items.first?.title ?? "nil")）")
        check(menu?.items.dropFirst().first?.isSeparatorItem == true, "复制表格下面一条分隔线")
        check(tv.selectedRange().length == 0, "右键表格后不留选区（原来会选中表格隐藏源码的一个字符，蓝框盖住半张表）")
        let again = rightClick(tv, at: p)
        check(again?.items.filter { $0.title == copyTable }.count == 1, "连着右键两次不会出现两个复制表格")
    } else {
        check(false, "样例表格应宽到出横向滚动层")
    }
    if let p = point(of: "let a", in: tv) {
        let menu = rightClick(tv, at: p)
        check(menu?.items.first?.title == copyCode, "右键代码块：第一项是复制代码（\(menu?.items.first?.title ?? "nil")）")
        check(menu?.items.contains { $0.title == copyTable } == false, "代码块上不出复制表格")
    } else {
        check(false, "找到代码块位置")
    }
    if let p = point(of: "尾巴", in: tv) {
        let menu = rightClick(tv, at: p)
        check(menu?.items.contains { $0.title == copyTable || $0.title == copyCode } == false, "普通段落上不加这两项")
    }

    // 写剪贴板：用临时剪贴板，别动用户的
    let pb = NSPasteboard(name: NSPasteboard.Name("spike-\(UUID().uuidString)"))
    AgentMarkdown.copyTable(table, to: pb)
    check(pb.string(forType: .string) == table, "复制表格：纯文本 = Markdown 原文")
    let html = pb.string(forType: .html) ?? ""
    check(html.contains("<table") && html.contains("桌前检查") && html.contains("charset"), "复制表格：HTML 是一张表（带 utf-8 声明）")
    AgentMarkdown.copyCode("let a = 1", to: pb)
    check(pb.string(forType: .string) == "let a = 1" && pb.string(forType: .html) == nil, "复制代码：只有纯文本代码")
    pb.releaseGlobally()
}

// MARK: 样张

@MainActor
func looks() {
    print("样张")
    let reply = """
    这是 Agent 的回复，==这句是荧光笔高亮==，后面是普通文字。

    ```swift
    // 注释
    func add(_ a: Int, _ b: Int) -> Int {
        return a + b
    }
    ```

    没写语言的代码块不着色：

    ```
    $ ls -la
    ```

    行内 `code` 也有底色。比较式 a == b 单独出现时不受影响。
    """
    for (name, ap) in [("look-light", NSAppearance.Name.aqua), ("look-dark", .darkAqua)] {
        // 在目标外观下建：图层底色（`cgColor`）是建的那一刻按当前外观取值的，不然两张都按系统外观画
        NSAppearance(named: ap)?.performAsCurrentDrawingAppearance {
            let h = Harness(width: 380, appearance: ap)
            _ = h.user("你好")
            _ = h.user("先看第 **12** 页，把 `fittingWidth` ==标出来==")
            _ = h.user("- 列表撑满\n- 第二项")
            _ = h.user("```python\nprint('hi')\n```")
            let md = AgentMarkdownView(text: reply, fontSize: AgentMarkdown.bodyFontSize, documentId: "look-\(name)")
            h.add(md)
            pump(1.5)
            h.snap(name)
        }
    }
    // 整块选中一个有折行的代码块（2026-10-05 用户截图的情形）：折行那两行的底色不许盖住选区，
    // 围栏 ``` 与语言名不许在选中时露出来。这两处修在引擎 fork（0.13.0-unireader.2）里，旧引擎下这张图是坏的。
    NSAppearance(named: .darkAqua)?.performAsCurrentDrawingAppearance {
        let code = "```fortran\n      CALL  SUB2(N, X)       ! 实参：第1个整型 N，第2个实型 X → 顺序/类型不匹配\n      DIMENSION  A(10,10), B(5)\n```"
        let h = Harness(width: 380, appearance: .darkAqua)
        let md = AgentMarkdownView(text: code, fontSize: AgentMarkdown.bodyFontSize, documentId: "look-code-selected")
        h.add(md)
        pump(1.2)
        if let tv = firstTextView(md) {
            tv.setSelectedRange(NSRange(location: 0, length: (tv.string as NSString).length))
            pump(0.4)
        }
        h.snap("look-code-selected")
    }
}

MainActor.assumeIsolated {
    NSApplication.shared.setActivationPolicy(.prohibited)
    try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
    testFittingWidth()
    testBubbles()
    testHighlighter()
    testContextMenu()
    looks()
    print(failures == 0 ? "✓ 全部 \(checks) 项通过" : "✗ \(failures) / \(checks) 项失败")
    exit(failures == 0 ? 0 : 1)
}
