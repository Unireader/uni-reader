// 离屏验证 2026-10-10「Agent 记笔记时整窗卡住」的修复之一：对话记录条目拍平——`AgentRowView` 与 `AgentDisclosureView`
// 不再套 `NSStackView`，折叠块的正文折着时不进视图树（之二是 `AgentChatNSView.trimTop`，见 `agent-transcript-test.swift`）。
// 编的是**真代码**（`AgentRowView` / `AgentDisclosureView` / `AgentMarkdownView`），原来的 `NSStackView` 版在下面抄了一份当对照。
// 依赖已编好的包模块（先按 AGENTS.md 编一次 Debug 包）。运行：
//
//   D=build/dev/Build/Products/Debug; O=/tmp/agent-flat-row; mkdir -p $O && cp -R $D/Highlighter_Highlighter.bundle $D/SwiftMath_SwiftMath.bundle $O/ \
//   && cp spike/agent-flat-row-test.swift $O/main.swift && swiftc -O -I $D $D/MarkdownEngine.o $D/MarkdownEngineLatex.o $D/SwiftMath.o $D/Highlighter.o \
//      Sources/Support/L.swift Sources/Markdown/MarkdownNoteEditor.swift Sources/Markdown/LatexCompat.swift Sources/Window/AI/AgentMarkdownView.swift \
//      Sources/Window/AI/AgentRowView.swift Sources/Agent/AgentMarkdownBlocks.swift $O/main.swift -o $O/t && $O/t $O
//
// 盯四件事：
//  1. 拍平的行和原来横排 `NSStackView` 摆得一样：逐个子视图 frame 对得上；窄到放不下时工具名被截断、图标不动；
//  2. 折叠块：折着时正文不在视图树里、高度 = 表头一行；点开装上正文、铺满整行宽、接在表头下 4pt；收起摘掉、高度回去；
//     各状态高度与原版一致；没有含糊约束；
//  3. 思考过程折着时流式文本照收（攒着不排），点开装进窗口后排出来；
//  4. 性能：对话记录追加一条的耗时，原版 vs 拍平（40 条 / 200 条）——拍平必须明显更快。
// 另出样张 $O/rows-light.png、$O/rows-dark.png（每组上面原版、下面拍平），肉眼对一遍。
import AppKit
import MarkdownEngine
import SwiftUI

// MARK: - 桩（与本题无关的类型）

final class WorkspaceWikiIndex: WikiLinkResolver, EmbeddedImageProvider, @unchecked Sendable {
    func resolve(displayName: String, range: NSRange) -> WikiLinkResolution? { nil }
    func image(for reference: EmbeddedImageRequest) -> NSImage? { nil }
    func fingerprint() -> AnyHashable { 0 }
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

// MARK: - 原版（2026-10-10 之前，对照用）

@MainActor
func oldRow(_ views: [NSView], spacing: CGFloat) -> NSView {
    let s = NSStackView(views: views)
    s.spacing = spacing
    return s
}

@MainActor
final class OldDisclosure: NSView {
    let toggle = NSButton()
    let body: NSView
    private let column = NSStackView()
    init(header: NSView, body: NSView) {
        self.body = body
        super.init(frame: .zero)
        toggle.bezelStyle = .disclosure
        toggle.setButtonType(.pushOnPushOff)
        toggle.title = ""
        toggle.state = .off
        toggle.target = self
        toggle.action = #selector(toggled)
        body.isHidden = true
        let row = NSStackView(views: [toggle, header])
        row.spacing = 2
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 4
        column.addArrangedSubview(row)
        column.addArrangedSubview(body)
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        let bodyWidth = body.widthAnchor.constraint(equalTo: column.widthAnchor)
        bodyWidth.priority = .init(999)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: leadingAnchor),
            column.trailingAnchor.constraint(equalTo: trailingAnchor),
            column.topAnchor.constraint(equalTo: topAnchor),
            column.bottomAnchor.constraint(equalTo: bottomAnchor),
            bodyWidth,
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func toggled() { body.isHidden = toggle.state != .on }
}

// MARK: - 断言

UserDefaults.standard.set(true, forKey: "NSConstraintBasedLayoutLogUnsatisfiable")
let outDir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/tmp/agent-flat-row")
setvbuf(stdout, nil, _IONBF, 0)
var failures = 0
var checks = 0
func check(_ ok: Bool, _ what: String) {
    checks += 1
    if !ok { failures += 1; print("  ✗ \(what)") }
}
func near(_ a: NSRect, _ b: NSRect) -> Bool {
    abs(a.minX - b.minX) < 0.5 && abs(a.minY - b.minY) < 0.5 && abs(a.width - b.width) < 0.5 && abs(a.height - b.height) < 0.5
}

@MainActor
func pump(_ seconds: TimeInterval = 0.4) {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
}

@MainActor
func ambiguous(_ v: NSView) -> Bool { v.hasAmbiguousLayout || v.subviews.contains(where: ambiguous) }

/// 同 `AgentItemViews.tool` 里的工具名标签。
@MainActor
func toolTitle(_ s: String) -> NSTextField {
    let t = NSTextField(labelWithString: s)
    t.font = .monospacedSystemFont(ofSize: NSFont.preferredFont(forTextStyle: .callout).pointSize, weight: .regular)
    t.lineBreakMode = .byTruncatingMiddle
    t.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    return t
}

@MainActor
func statusIcon(spinner: Bool) -> NSView {
    if spinner {
        let s = NSProgressIndicator()
        s.style = .spinning
        s.controlSize = .mini
        return s
    }
    let i = NSImageView(image: NSImage(systemSymbolName: "checkmark.circle", accessibilityDescription: nil)!)
    i.contentTintColor = .systemGreen
    return i
}

/// 工具输出（同 `AgentItemViews.tool`）。
@MainActor
func toolOutput() -> NSTextField {
    let text = NSTextField(wrappingLabelWithString: String(repeating: "{\"page\": 12, \"text\": \"……\"} ", count: 12))
    text.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
    text.isSelectable = true
    return text
}

/// 装进一个宽 `width` 的容器：左上贴住，右边不超出（同条目在对话记录里的处境）；`fill` = 宽度钉死（条目本身）。
@MainActor
func host(_ v: NSView, width: CGFloat, fill: Bool) -> NSView {
    let c = FlippedView(frame: NSRect(x: 0, y: 0, width: width, height: 400))
    v.translatesAutoresizingMaskIntoConstraints = false
    c.addSubview(v)
    NSLayoutConstraint.activate([
        v.leadingAnchor.constraint(equalTo: c.leadingAnchor),
        v.topAnchor.constraint(equalTo: c.topAnchor),
        fill ? v.widthAnchor.constraint(equalTo: c.widthAnchor) : v.trailingAnchor.constraint(lessThanOrEqualTo: c.trailingAnchor),
    ])
    c.layoutSubtreeIfNeeded()
    return c
}

final class FlippedView: NSView { override var isFlipped: Bool { true } }

@MainActor
func findButton(_ v: NSView) -> NSButton? {
    if let b = v as? NSButton, b.bezelStyle == .disclosure { return b }
    for s in v.subviews { if let b = findButton(s) { return b } }
    return nil
}

// MARK: 1. 行

@MainActor
func testRows() {
    print("1. 拍平的行 vs 横排 NSStackView")
    for (name, spinner) in [("完成图标", false), ("转圈", true)] {
        for width in [320.0, 120.0] {
            let title = "unireader.read_pages {\"document\": \"线性代数讲义\", \"pages\": [12, 13]}"
            let oldViews = [statusIcon(spinner: spinner), toolTitle(title)]
            let newViews = [statusIcon(spinner: spinner), toolTitle(title)]
            let old = oldRow(oldViews, spacing: 6), new = AgentRowView(newViews, spacing: 6)
            _ = host(old, width: width, fill: false)
            _ = host(new, width: width, fill: false)
            check(abs(old.frame.height - new.frame.height) < 0.5,
                  "\(name)·宽\(Int(width))：行高一致，原版 \(old.frame.height)、拍平 \(new.frame.height)")
            check(abs(old.frame.width - new.frame.width) < 0.5,
                  "\(name)·宽\(Int(width))：行宽一致，原版 \(old.frame.width)、拍平 \(new.frame.width)")
            for (a, b) in zip(oldViews, newViews) {
                check(near(a.frame, b.frame), "\(name)·宽\(Int(width))：\(type(of: a)) 摆位一致，原版 \(a.frame)、拍平 \(b.frame)")
            }
            check(!ambiguous(new), "\(name)·宽\(Int(width))：拍平的行没有含糊约束")
            if width < 200 {
                // 按对齐矩形比：标签的 frame 左右各比对齐矩形多 2pt（原版一样）
                let r = newViews[1].alignmentRect(forFrame: newViews[1].frame)
                check(r.maxX <= width + 0.5, "窄到放不下：工具名被截断在行内，实得右边 \(r.maxX)")
                check(newViews[0].frame.width > 5, "窄到放不下：图标不被压扁，实得宽 \(newViews[0].frame.width)")
            }
        }
    }
    // 思考过程的表头（图标 + 标题）
    let old = oldRow([NSImageView(image: NSImage(systemSymbolName: "brain", accessibilityDescription: nil)!),
                      NSTextField(labelWithString: "Thinking")], spacing: 4)
    let new = AgentDisclosureView.headerRow(title: "Thinking", symbol: "brain")
    ((old as! NSStackView).arrangedSubviews[1] as! NSTextField).font = .preferredFont(forTextStyle: .callout)
    _ = host(old, width: 320, fill: false)
    _ = host(new, width: 320, fill: false)
    check(near(NSRect(origin: .zero, size: old.frame.size), NSRect(origin: .zero, size: new.frame.size)),
          "思考过程表头尺寸一致，原版 \(old.frame.size)、拍平 \(new.frame.size)")
}

// MARK: 2. 折叠块

@MainActor
func testDisclosure() {
    print("2. 折叠块")
    for width in [320.0, 260.0] {
        let oldBody = toolOutput(), newBody = toolOutput()
        let old = OldDisclosure(header: oldRow([statusIcon(spinner: false), toolTitle("read_pages")], spacing: 6), body: oldBody)
        let new = AgentDisclosureView(header: AgentRowView([statusIcon(spinner: false), toolTitle("read_pages")], spacing: 6), body: newBody)
        let oc = host(old, width: width, fill: true), nc = host(new, width: width, fill: true)
        check(newBody.superview == nil, "宽\(Int(width))：折着时正文不在视图树里")
        check(abs(old.frame.height - new.frame.height) < 0.5, "宽\(Int(width))：折着的高度一致，原版 \(old.frame.height)、拍平 \(new.frame.height)")
        check(!ambiguous(new), "宽\(Int(width))：折着时没有含糊约束")
        let collapsed = new.frame.height

        old.toggle.performClick(nil)
        findButton(new)?.performClick(nil)
        oc.layoutSubtreeIfNeeded(); nc.layoutSubtreeIfNeeded()
        // 自动折行宽度要排过一遍才定下来，再排一次
        oc.needsLayout = true; nc.needsLayout = true
        oc.layoutSubtreeIfNeeded(); nc.layoutSubtreeIfNeeded()
        check(newBody.superview === new, "宽\(Int(width))：点开后正文装上")
        let bodyRect = newBody.alignmentRect(forFrame: newBody.frame)
        check(abs(bodyRect.width - width) < 0.5, "宽\(Int(width))：正文铺满整行宽（对齐矩形），实得 \(bodyRect.width)")
        check(near(oldBody.frame, newBody.frame) || abs(oldBody.frame.width - newBody.frame.width) < 0.5,
              "宽\(Int(width))：正文宽度与原版一致，原版 \(oldBody.frame)、拍平 \(newBody.frame)")
        check(newBody.frame.height > 40, "宽\(Int(width))：正文折成多行，实得高 \(newBody.frame.height)")
        check(abs(old.frame.height - new.frame.height) < 0.5, "宽\(Int(width))：展开的高度一致，原版 \(old.frame.height)、拍平 \(new.frame.height)")
        check(abs(newBody.frame.minY - (collapsed + 4)) < 0.5 || abs(newBody.frame.maxY - (new.frame.height - collapsed - 4)) < 0.5,
              "宽\(Int(width))：正文接在表头下 4pt，实得 \(newBody.frame)")
        check(!ambiguous(new), "宽\(Int(width))：展开时没有含糊约束")

        findButton(new)?.performClick(nil)
        nc.layoutSubtreeIfNeeded()
        check(newBody.superview == nil, "宽\(Int(width))：收起后正文摘掉")
        check(abs(new.frame.height - collapsed) < 0.5, "宽\(Int(width))：收起后高度回到一行，实得 \(new.frame.height)")
        findButton(new)?.performClick(nil)
        nc.layoutSubtreeIfNeeded()
        check(newBody.superview === new && abs(new.frame.height - old.frame.height) < 0.5, "宽\(Int(width))：再点开一次照样对")
    }
}

// MARK: 3. 思考过程折着时的流式文本

@MainActor
func testThought() {
    print("3. 思考过程折着时的流式文本")
    let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
    let md = AgentMarkdownView(text: "先", fontSize: 12, documentId: "thought-spike")
    let d = AgentDisclosureView(header: AgentDisclosureView.headerRow(title: "Thinking", symbol: "brain"), body: md, markdown: md)
    let c = FlippedView(frame: NSRect(x: 0, y: 0, width: 360, height: 400))
    win.contentView = c
    d.translatesAutoresizingMaskIntoConstraints = false
    c.addSubview(d)
    NSLayoutConstraint.activate([d.leadingAnchor.constraint(equalTo: c.leadingAnchor), d.topAnchor.constraint(equalTo: c.topAnchor),
                                 d.widthAnchor.constraint(equalTo: c.widthAnchor)])
    c.layoutSubtreeIfNeeded()
    let full = "先看第 12 页的定义，再对照第 13 页的例题。\n\n- 第一点\n- 第二点\n- 第三点"
    d.update(text: full)
    pump(0.2)
    check(md.window == nil, "折着时正文不在窗口里")
    check(md.text == "先", "折着时流式文本只攒着、不排版，实得 \(md.text.prefix(10))")
    findButton(d)?.performClick(nil)
    c.layoutSubtreeIfNeeded()
    pump(0.6)
    c.layoutSubtreeIfNeeded()
    check(md.window === win, "点开后正文进了窗口")
    check(md.text == full, "点开后攒着的文本排上了")
    check(md.frame.height > 40, "点开后正文排出了多行高度，实得 \(md.frame.height)")
    check(abs(md.frame.width - 360) < 0.5, "正文铺满整行宽，实得 \(md.frame.width)")
}

// MARK: 4. 性能

final class FlippedStack: NSStackView { override var isFlipped: Bool { true } }

@MainActor
func appendCost(n: Int, flat: Bool) -> Double {
    let make: (Int) -> NSView = { i in
        flat ? AgentDisclosureView(header: AgentRowView([statusIcon(spinner: false), toolTitle("read_pages \(i)")], spacing: 6), body: toolOutput())
             : OldDisclosure(header: oldRow([statusIcon(spinner: false), toolTitle("read_pages \(i)")], spacing: 6), body: toolOutput())
    }
    let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 800), styleMask: [.titled], backing: .buffered, defer: true)
    let scroll = NSScrollView(frame: win.contentView!.bounds)
    scroll.autoresizingMask = [.width, .height]
    win.contentView!.addSubview(scroll)
    // 同 `AgentChatNSView` 的对话记录
    let stack = FlippedStack()
    stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12
    stack.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
    scroll.documentView = stack
    stack.translatesAutoresizingMaskIntoConstraints = false
    stack.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor).isActive = true
    let spinner = NSProgressIndicator()
    func add(_ v: NSView) {
        stack.addArrangedSubview(v)
        v.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28).isActive = true
    }
    for i in 0..<n { add(make(i)) }
    stack.addArrangedSubview(spinner)
    win.contentView!.layoutSubtreeIfNeeded()
    if flat {
        let items = stack.arrangedSubviews.compactMap { $0 as? AgentDisclosureView }
        check(items.allSatisfy { abs($0.frame.height - $0.intrinsicContentSize.height) < 0.5 && $0.frame.height > 10 },
              "\(n) 条：放进对话记录 stack 里，折叠块高度就是表头一行（没被拉伸 / 压扁）")
        check(items.allSatisfy { abs($0.frame.width - (360 - 28)) < 0.5 }, "\(n) 条：折叠块宽度 = 对话记录宽 − 28")
        check(!items.contains(where: ambiguous), "\(n) 条：对话记录里的折叠块没有含糊约束")
    }
    let rounds = 10
    let t0 = Date()
    for r in 0..<rounds {
        // 同 `applyTranscriptViews`：转圈摘下、追加条目、再挂回
        stack.removeArrangedSubview(spinner)
        add(make(n + r))
        stack.addArrangedSubview(spinner)
        win.contentView!.layoutSubtreeIfNeeded()
    }
    return Date().timeIntervalSince(t0) * 1000 / Double(rounds)
}

@MainActor
func testPerf() {
    print("4. 对话记录追加一条的耗时（工具调用条目）")
    for n in [40, 200] {
        let old = autoreleasepool { appendCost(n: n, flat: false) }
        let new = autoreleasepool { appendCost(n: n, flat: true) }
        print(String(format: "   %3d 条：原版 %.1fms，拍平 %.1fms（%.1f 倍）", n, old, new, old / max(new, 0.01)))
        check(new * 2 < old, "\(n) 条时拍平至少快一倍")
    }
}

// MARK: 样张

@MainActor
func looks() {
    for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
        NSApp.appearance = NSAppearance(named: appearance)
        let c = FlippedView(frame: NSRect(x: 0, y: 0, width: 340, height: 330))
        c.appearance = NSAppearance(named: appearance)
        c.wantsLayer = true
        // cgColor 按「当前绘制外观」取色，不看 NSApp.appearance：得在这套外观里取，否则浅色样张铺成深色底
        c.appearance?.performAsCurrentDrawingAppearance { c.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor }
        var y: CGFloat = 10
        func put(_ v: NSView, fill: Bool) {
            v.translatesAutoresizingMaskIntoConstraints = false
            c.addSubview(v)
            NSLayoutConstraint.activate([
                v.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 10),
                v.topAnchor.constraint(equalTo: c.topAnchor, constant: y),
                fill ? v.widthAnchor.constraint(equalToConstant: 320) : v.trailingAnchor.constraint(lessThanOrEqualTo: c.trailingAnchor, constant: -10),
            ])
            c.layoutSubtreeIfNeeded()
            y = v.frame.maxY + 8
        }
        let title = "unireader.read_pages {\"pages\": [12]}"
        put(oldRow([statusIcon(spinner: false), toolTitle(title)], spacing: 6), fill: false)
        put(AgentRowView([statusIcon(spinner: false), toolTitle(title)], spacing: 6), fill: false)
        y += 8
        put(OldDisclosure(header: oldRow([statusIcon(spinner: false), toolTitle(title)], spacing: 6), body: toolOutput()), fill: true)
        put(AgentDisclosureView(header: AgentRowView([statusIcon(spinner: false), toolTitle(title)], spacing: 6), body: toolOutput()), fill: true)
        y += 8
        let hOld = oldRow([NSImageView(image: NSImage(systemSymbolName: "brain", accessibilityDescription: nil)!),
                           NSTextField(labelWithString: "Thinking")], spacing: 4)
        ((hOld as! NSStackView).arrangedSubviews[1] as! NSTextField).font = .preferredFont(forTextStyle: .callout)
        put(OldDisclosure(header: hOld, body: toolOutput()), fill: true)
        put(AgentDisclosureView(header: AgentDisclosureView.headerRow(title: "Thinking", symbol: "brain"), body: toolOutput()), fill: true)
        y += 8
        let eo = OldDisclosure(header: oldRow([statusIcon(spinner: false), toolTitle(title)], spacing: 6), body: toolOutput())
        put(eo, fill: true); eo.toggle.performClick(nil)
        let en = AgentDisclosureView(header: AgentRowView([statusIcon(spinner: false), toolTitle(title)], spacing: 6), body: toolOutput())
        put(en, fill: true)
        c.needsLayout = true; c.layoutSubtreeIfNeeded()
        // 展开的两块要按展开后的高度重新排位：放到右边对照
        c.frame.size.width = 680
        findButton(en)?.performClick(nil)
        en.removeFromSuperview()
        en.translatesAutoresizingMaskIntoConstraints = false
        c.addSubview(en)
        NSLayoutConstraint.activate([en.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 350),
                                     en.topAnchor.constraint(equalTo: eo.topAnchor), en.widthAnchor.constraint(equalToConstant: 320)])
        c.frame.size.height = 600
        c.needsLayout = true; c.layoutSubtreeIfNeeded()
        c.needsLayout = true; c.layoutSubtreeIfNeeded()
        guard let rep = c.bitmapImageRepForCachingDisplay(in: c.bounds) else { continue }
        c.cacheDisplay(in: c.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: outDir.appendingPathComponent("rows-\(name).png"))
    }
    NSApp.appearance = nil
}

_ = NSApplication.shared
MainActor.assumeIsolated {
    testRows()
    testDisclosure()
    testThought()
    testPerf()
    looks()
}
print(failures == 0 ? "\n✅ \(checks) 项全过（样张在 \(outDir.path)）" : "\n❌ \(checks) 项里 \(failures) 项没过")
exit(failures == 0 ? 0 : 1)
