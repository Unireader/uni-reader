// 离屏验证习题 v22 的题目笔记那一块 `ExerciseNoteView`（`EXERCISE-PLAN.md §12.1`）。编的是**真代码**，只把 Markdown 引擎
// 用不到的几个类型换成桩（同 `spike/exercise-free-answer-test.swift`）。依赖已编好的包模块（先按 AGENTS.md 编一次 Debug 包）。运行：
//
//   D=build/dev/Build/Products/Debug; O=/tmp/ex-note; mkdir -p $O && cp -R $D/Highlighter_Highlighter.bundle $D/SwiftMath_SwiftMath.bundle $O/ \
//   && cp spike/exercise-note-test.swift $O/main.swift && swiftc -I $D $D/MarkdownEngine.o $D/MarkdownEngineLatex.o $D/SwiftMath.o $D/Highlighter.o \
//      Sources/Support/L.swift Sources/Markdown/MarkdownNoteEditor.swift Sources/Markdown/LatexCompat.swift Sources/Window/AI/AgentMarkdownView.swift \
//      Sources/Window/AI/AgentRowView.swift Sources/Agent/AgentMarkdownBlocks.swift Sources/Markdown/TableEditMenu.swift \
//      Sources/Window/Exercise/ExerciseNoteView.swift \
//      $O/main.swift -o $O/t && $O/t $O
//
// 盯的事：
//  1. 三种样子：没写过只有「添加笔记」；写过 = 标题 + 渲染的笔记 +「编辑笔记」；编辑 = 标题 + 输入框 +「完成」；
//  2. 边写边存：打字后不立刻存，停手 0.8 秒存一次；同一段话不重复存；
//  3. 收起时存：「完成」/ Esc / 换题（`show` 换了 id）/ 离开窗口（切标签拆视图）/ 失去焦点都先存下，存的是**原来那道题**的 id；
//  4. 正在写时库里的笔记变了（自己刚存的回推、Agent 改了）不动输入框里的字；
//  5. 排版：看得见的子视图从上到下不重叠，`height(forWidth:)` 与 `layout()` 一致。
// 另出样张：$O/look-note-light.png（写过的笔记）、$O/look-note-editing-dark.png（编辑中）。
// ⚠️ 离屏截图画不出引擎排的公式图（位置留出来了、图是空的），解析那块同样如此；公式要在真 App 里看。

import AppKit
import MarkdownEngine

// MARK: - 桩（同 exercise-free-answer-test.swift）

struct AgentImage: Equatable { var data = Data() }

final class WorkspaceWikiIndex: WikiLinkResolver, EmbeddedImageProvider, @unchecked Sendable {
    func resolve(displayName: String, range: NSRange) -> WikiLinkResolution? { nil }
    func image(for reference: EmbeddedImageRequest) -> NSImage? { nil }
    func fingerprint() -> AnyHashable { 0 }
}

enum NoteBubble {
    static let editorFontSizeKey = "spike.editorFontSize"
    static let defaultEditorFont: CGFloat = 13
}

/// 同 `Markdown/GrapherBlocks.swift`（那个文件牵出 Grapher 三个模块）：笔记里不出现 ```grapher 块，画不出来就行。
struct GrapherFencedRenderer: FencedBlockRenderer {
    let containerWidth: CGFloat
    var languages: Set<String> { [] }
    func render(_ request: FencedBlockRequest, theme: MarkdownEditorTheme) -> FencedBlockRendering? { nil }
    func fingerprint() -> AnyHashable { 0 }
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

setvbuf(stdout, nil, _IONBF, 0)
let outDir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/tmp/ex-note")
var failures = 0, checks = 0
func check(_ ok: Bool, _ what: String) {
    checks += 1
    if ok { print("  ✅ \(what)") } else { failures += 1; print("  ❌ \(what)") }
}

@MainActor
func pump(_ seconds: TimeInterval = 0.3) {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
}

final class FlippedRoot: NSView { override var isFlipped: Bool { true } }

@MainActor
func host(_ v: NSView, width: CGFloat, height: CGFloat, dark: Bool = false) -> NSWindow {
    let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height), styleMask: [.borderless],
                     backing: .buffered, defer: false)
    w.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    let root = FlippedRoot(frame: NSRect(x: 0, y: 0, width: width, height: height))
    w.contentView = root
    root.addSubview(v)
    return w
}

@MainActor
func snapshot(_ v: NSView, _ name: String) {
    v.layoutSubtreeIfNeeded()
    guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
    v.cacheDisplay(in: v.bounds, to: rep)
    let img = NSImage(size: v.bounds.size)
    img.lockFocus()
    (v.appearance ?? NSAppearance(named: .aqua)!).performAsCurrentDrawingAppearance {
        NSColor.windowBackgroundColor.setFill()
        NSRect(origin: .zero, size: v.bounds.size).fill()
    }
    rep.draw(in: NSRect(origin: .zero, size: v.bounds.size), from: .zero, operation: .sourceOver, fraction: 1,
             respectFlipped: true, hints: nil)
    img.unlockFocus()
    guard let tiff = img.tiffRepresentation, let out = NSBitmapImageRep(data: tiff) else { return }
    try? out.representation(using: .png, properties: [:])?.write(to: outDir.appendingPathComponent(name))
}

@MainActor
func all(_ v: NSView) -> [NSView] { v.subviews + v.subviews.flatMap(all) }
@MainActor
func button(_ v: NSView, _ title: String) -> NSButton? {
    all(v).compactMap { $0 as? NSButton }.first { $0.title == title && !$0.isHidden }
}
/// 输入框（直接子视图里那个滚动视图的文本视图；渲染笔记的引擎里也有一个文本视图，别拿错）。
@MainActor
func textView(_ v: NSView) -> NSTextView? {
    v.subviews.compactMap { ($0 as? NSScrollView)?.documentView as? NSTextView }.first
}
@MainActor
func visibleTitle(_ v: NSView) -> Bool {
    v.subviews.contains { ($0 as? NSTextField)?.stringValue == "Notes" && !$0.isHidden }
}

/// 把整块排一遍：宽 560，高按 `height(forWidth:)`。
@MainActor
func relayout(_ v: ExerciseNoteView) {
    v.frame.size = NSSize(width: 560, height: v.height(forWidth: 560))
    v.needsLayout = true
    v.layoutSubtreeIfNeeded()
}

/// 看得见的直接子视图从上到下不重叠（同一行的按钮除外——这里一行只有一个）。
@MainActor
func noOverlap(_ v: NSView) -> Bool {
    let fs = v.subviews.filter { !$0.isHidden && $0.frame.height > 0 }
        .filter { ($0 as? NSTextField)?.textColor != .placeholderTextColor }   // 占位字本来就叠在输入框里
        .map(\.frame).sorted { $0.minY < $1.minY }
    for (a, b) in zip(fs, fs.dropFirst()) where b.minY < a.maxY - 0.5 { return false }
    return true
}

MainActor.assumeIsolated {
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.accessory)
    try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

    var saves: [(String, String)] = []
    var ended = 0
    let v = ExerciseNoteView()
    v.onSave = { saves.append(($0, $1)) }
    v.onEndEditing = { ended += 1 }
    let win = host(v, width: 600, height: 700)

    print("— 三种样子")
    v.show(note: "", exerciseId: "e1")
    relayout(v)
    check(button(v, "Add a Note") != nil && !visibleTitle(v) && textView(v)?.enclosingScrollView?.isHidden == true,
          "没写过：只有「添加笔记」，没有标题、没有输入框")
    check(abs(v.height(forWidth: 560) - (button(v, "Add a Note")?.frame.height ?? 0)) < 1, "没写过：高度就是那一个按钮")
    v.show(note: "**易错**：$f'(x)=2x$\n\n- 链式法则", exerciseId: "e1")
    pump(1.5)   // 公式是引擎异步排的
    relayout(v)
    pump(0.5)
    check(visibleTitle(v) && button(v, "Edit Note") != nil && button(v, "Add a Note") == nil, "写过：标题 +「编辑笔记」")
    check(v.height(forWidth: 560) > 60, "写过：渲染的笔记占了高度（\(Int(v.height(forWidth: 560)))）")
    check(noOverlap(v), "写过：子视图不重叠")
    snapshot(v, "look-note-light.png")

    print("— 编辑与边写边存")
    button(v, "Edit Note")?.performClick(nil)
    relayout(v)
    let tv = textView(v)
    check(v.isEditing && tv?.enclosingScrollView?.isHidden == false && button(v, "Done") != nil, "点「编辑笔记」→ 输入框 +「完成」")
    check(tv?.string == "**易错**：$f'(x)=2x$\n\n- 链式法则", "输入框里是原来的笔记")
    check(win.firstResponder === tv, "输入框拿到焦点")
    check(button(v, "Edit Note") == nil && visibleTitle(v) && noOverlap(v), "编辑中：没有「编辑笔记」，标题还在，不重叠")
    tv?.setSelectedRange(NSRange(location: (tv!.string as NSString).length, length: 0))
    tv?.insertText("\n- 别漏负号", replacementRange: tv!.selectedRange())
    check(saves.isEmpty, "刚打完字不立刻存")
    pump(1.2)
    check(saves.count == 1 && saves.last?.0 == "e1" && saves.last?.1.hasSuffix("- 别漏负号") == true, "停手 0.8 秒存一次（e1）")
    pump(1.0)
    check(saves.count == 1, "没再改就不再存")
    v.show(note: "库里回推的", exerciseId: "e1")
    check(tv?.string.hasSuffix("- 别漏负号") == true && v.isEditing, "正在写时库里变了：输入框里的字不动")

    print("— 收起时存")
    tv?.insertText("！", replacementRange: tv!.selectedRange())
    button(v, "Done")?.performClick(nil)
    relayout(v)
    check(saves.count == 2 && saves.last?.1.hasSuffix("别漏负号！") == true && !v.isEditing && ended == 1,
          "「完成」→ 立刻存下、收起、通知练习页拿回焦点")
    check(button(v, "Edit Note") != nil && tv?.enclosingScrollView?.isHidden == true, "收起后回到「编辑笔记」")
    pump(1.2)
    check(saves.count == 2, "收起后不会再迟到地存一次")

    button(v, "Edit Note")?.performClick(nil)
    _ = tv?.delegate?.textView?(tv!, doCommandBy: #selector(NSResponder.cancelOperation(_:)))
    check(!v.isEditing && saves.count == 2 && ended == 2, "Esc 收起；没改过不存")

    button(v, "Edit Note")?.performClick(nil)
    tv?.insertText(" 换题前写的", replacementRange: tv!.selectedRange())
    v.show(note: "", exerciseId: "e2")
    relayout(v)
    check(saves.count == 3 && saves.last?.0 == "e1" && saves.last?.1.hasSuffix("换题前写的") == true,
          "写着就换题：先按**原来那道题**存下")
    check(!v.isEditing && v.exerciseId == "e2" && button(v, "Add a Note") != nil, "换到没笔记的 e2：只有「添加笔记」")

    button(v, "Add a Note")?.performClick(nil)
    check(v.isEditing && tv?.string == "", "e2 添加笔记：空输入框")
    tv?.insertText("   ", replacementRange: tv!.selectedRange())
    v.commit()
    check(saves.count == 3, "只写了空白 = 和原来（空）一样，不存")

    button(v, "Add a Note")?.performClick(nil)
    tv?.insertText("e2 的笔记", replacementRange: tv!.selectedRange())
    win.makeFirstResponder(win.contentView)
    check(saves.count == 4 && saves.last! == ("e2", "e2 的笔记") && v.isEditing, "点到别处（输入框失去焦点）→ 先存下，输入框照旧开着")
    tv?.insertText("，切标签前", replacementRange: NSRange(location: (tv!.string as NSString).length, length: 0))
    v.removeFromSuperview()
    check(saves.count == 5 && saves.last! == ("e2", "e2 的笔记，切标签前") && !v.isEditing, "离开窗口（切走标签拆视图）→ 先存下、收起")

    print("— 排版 / 样张")
    let d = ExerciseNoteView()
    let dw = host(d, width: 600, height: 400, dark: true)
    d.appearance = NSAppearance(named: .darkAqua)   // 样张按视图自己的外观铺底色（窗口的外观它读不到）
    d.show(note: "旧笔记", exerciseId: "e3")
    button(d, "Edit Note")?.performClick(nil)
    textView(d)?.string = "第一行\n第二行 $\\frac{1}{2}$\n第三行\n第四行\n第五行\n第六行\n第七行"
    textView(d)?.didChangeText()
    pump(0.3)
    relayout(d)
    check(noOverlap(d), "编辑中（深色、七行）：子视图不重叠")
    let sv = textView(d)?.enclosingScrollView
    check((sv?.frame.height ?? 0) > 96 && (sv?.frame.height ?? 0) <= 320, "输入框随内容长高（\(Int(sv?.frame.height ?? 0))，96~320）")
    let bottom = d.subviews.filter { !$0.isHidden }.map(\.frame.maxY).max() ?? 0
    check(abs(bottom - d.height(forWidth: 560)) < 1, "`height(forWidth:)` = 最下面那个子视图的下沿")
    snapshot(d, "look-note-editing-dark.png")
    d.commit()
    _ = dw
}

print("\n\(checks - failures) 通过，\(failures) 失败（样张在 \(outDir.path)）")
exit(failures == 0 ? 0 : 1)
