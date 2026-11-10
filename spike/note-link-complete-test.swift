// 离屏核对「输入 [[ 弹候选」依赖的引擎行为（`MARKDOWN-NOTES-PLAN.md §12`，App 侧 = `NoteLinkCompleter`）：
// 往引擎的编辑区里打 `[[ab`，看它是不是报「光标在一条正在打字的链接里」、给的占位文字与位置对不对；
// 再塞一个替换请求，看整条是不是换成了 `[[笔记名]]`；`==高亮==` 扩展开着时有没有背景。
// 只依赖已编好的引擎模块（先按 AGENTS.md 编一次 Debug 包）。运行：
//   D=build/dev/Build/Products/Debug; O=/tmp/nlc; mkdir -p $O && cp spike/note-link-complete-test.swift $O/main.swift \
//   && swiftc -I $D $D/MarkdownEngine.o $O/main.swift -o $O/t && $O/t
import AppKit
import MarkdownEngine
import SwiftUI

var pass = 0, fail = 0
func check(_ c: Bool, _ m: String) { if c { pass += 1; print("  ✅ \(m)") } else { fail += 1; print("  ❌ \(m)") } }
@MainActor func pump(_ s: TimeInterval = 0.15) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }

@MainActor final class Box: ObservableObject {
    @Published var text = "开头\n"
    @Published var pending: InlineReplacementRequest?
    var states: [InlineSelectionState?] = []
    var rects: [CGRect] = []
}

struct Root: View {
    @ObservedObject var box: Box
    var body: some View {
        var c = MarkdownEditorConfiguration.default
        c.extensions = [HighlightExtension()]
        return NativeTextViewWrapper(text: $box.text, pendingInlineReplacement: $box.pending, configuration: c,
                                     documentId: "doc",
                                     onCaretRectChange: { [box] in box.rects.append($0) },
                                     onInlineSelectionChange: { [box] in box.states.append($0) },
                                     onInlinePreviewKey: { _ in false })
    }
}

@MainActor func allSubviews(_ v: NSView) -> [NSView] { v.subviews + v.subviews.flatMap(allSubviews) }

MainActor.assumeIsolated {
    _ = NSApplication.shared
    let box = Box()
    let host = NSHostingView(rootView: Root(box: box))
    let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
    win.contentView = host
    win.makeKeyAndOrderFront(nil)
    pump(0.4)
    guard let tv = allSubviews(host).compactMap({ $0 as? NSTextView }).first else { check(false, "找到引擎的 NSTextView"); return }
    win.makeFirstResponder(tv)
    tv.setSelectedRange(NSRange(location: (tv.string as NSString).length, length: 0))
    print("1. 打 [[ab")
    // 引擎只在**键盘事件**里才当作「正在打字」（`NSApp.currentEvent` 是 keyDown），直接 insertText 不算——
    // 所以合成真的按键事件，经 App 的事件队列派发（这样 currentEvent 才是它）。
    func type(_ ch: String) {
        guard let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                       windowNumber: win.windowNumber, context: nil, characters: ch,
                                       charactersIgnoringModifiers: ch, isARepeat: false, keyCode: 0) else { return }
        NSApp.postEvent(e, atStart: false)
        let until = Date().addingTimeInterval(0.15)
        while let ev = NSApp.nextEvent(matching: .any, until: until, inMode: .default, dequeue: true) { NSApp.sendEvent(ev) }
    }
    for ch in ["[", "[", "a", "b"] { type(ch) }
    pump(0.3)
    print("   正文此刻：\(box.text.debugDescription)")
    let last = box.states.compactMap { $0 }.last
    check(last != nil, "报了「光标在一条正在打字的链接里」（共 \(box.states.count) 次回调）")
    check(last?.kind == .wikiLink, "是 [[…]] 不是 ![[…]]")
    // 占位文字是整条（引擎自动配对补了 `]]`）——App 侧 `NoteLinkCompleter.query` 据此剥方括号
    check(last?.selection.placeholder == "[[ab]]", "占位文字 = 整条 [[ab]]：\(last?.selection.placeholder ?? "nil")")
    if let r = last?.selection.displayRange {
        let token = (tv.string as NSString).substring(with: r)
        check(token.hasPrefix("[[ab"), "替换范围是整条（含方括号）：\(token.debugDescription)")
    }
    check(!box.rects.isEmpty && (box.rects.last?.width ?? 0) > 0, "给了位置：\(String(describing: box.rects.last))")
    print("2. 塞替换请求")
    if let sel = last?.selection {
        box.pending = InlineReplacementRequest(documentId: "doc", selection: sel, storageFragment: "[[极限的定义]]", isImageEmbedMode: false)
        pump(0.5)
        check(box.text.contains("[[极限的定义]]") && !box.text.contains("[[ab"), "整条换成了 [[极限的定义]]：\(box.text.debugDescription)")
        check(!box.text.contains("|"), "写进正文的没有 |id")
        check(box.pending == nil, "引擎应用后清掉了请求")
    }
    print("3. ==高亮==")
    tv.setSelectedRange(NSRange(location: (tv.string as NSString).length, length: 0))
    tv.insertText("\n==重点== 后面", replacementRange: tv.selectedRange())
    pump(0.4)
    let s = tv.string as NSString
    let at = s.range(of: "重点")
    var found = false
    if at.location != NSNotFound, let storage = tv.textStorage {
        storage.enumerateAttributes(in: at) { attrs, _, _ in
            if attrs.keys.contains(where: { $0.rawValue.lowercased().contains("background") }) { found = true }
        }
    }
    check(found, "「重点」两个字带上了高亮背景属性")
}
print("\n通过 \(pass)，失败 \(fail)")
exit(fail == 0 ? 0 : 1)
