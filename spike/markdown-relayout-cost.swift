// 量 Markdown 引擎排版**占住主线程多久**（TextKit 2）。运行（先按 AGENTS.md 编一次 Debug，要用它的产物）：
//   P=build/dev/Build/Products/Debug; mkdir -p /tmp/md-cost && cp spike/markdown-relayout-cost.swift /tmp/md-cost/main.swift \
//     && swiftc -O -I $P /tmp/md-cost/main.swift $P/MarkdownEngine.o -o /tmp/md-cost/run \
//     && /tmp/md-cost/run <某篇.md> [宽度]
//
// 🔴 量的是**主线程 CPU 时间**（`CLOCK_THREAD_CPUTIME_ID`），不是墙上时间，也不靠「等高度报回来」——
// 高度不变（改一个字）时那个回调根本不来，等下去只会超时，看着像「慢了 60 秒」其实什么都没量到。
// CPU 时间不受 runloop 空转影响：差值就是这一下真的忙了多久，界面卡的就是这段。
//
// 四个场景：
//  ① 打开一篇（首次排版）
//  ② 整篇换掉正文 —— Agent 的 `update_markdown` 写完后 `MarkdownDocView.applySavedText` 干的事
//  ③ 打字 —— 往编辑器里一个字一个字敲（走 NSTextView，不是换 binding）
//  ④ 改宽度 —— 拖分隔条 / 拖窗口，正文要按新宽度重排

import AppKit
import MarkdownEngine
import SwiftUI

_ = NSApplication.shared

let args = Array(CommandLine.arguments.dropFirst())
guard let path = args.first, let text = try? String(contentsOfFile: path, encoding: .utf8) else {
    print("用法：run <某篇.md> [宽度，默认 700]")
    exit(2)
}
let width = Double(args.count > 1 ? args[1] : "") ?? 700

/// 本线程用掉的 CPU 时间。
func cpu() -> TimeInterval {
    var ts = timespec()
    clock_gettime(CLOCK_THREAD_CPUTIME_ID, &ts)
    return TimeInterval(ts.tv_sec) + TimeInterval(ts.tv_nsec) / 1e9
}

/// 跑一会儿 runloop，让排版真的发生（SwiftUI 的更新是下一拍的事）。
func spin(_ seconds: TimeInterval) {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end { RunLoop.main.run(mode: .default, before: end) }
}

/// 做一件事，报它占住主线程多久。
@discardableResult
func measure(_ label: String, settle: TimeInterval = 0.4, _ body: () -> Void) -> TimeInterval {
    spin(0.15)                       // 先把前一件事的尾巴跑完，别算到这次头上
    let c0 = cpu()
    body()
    spin(settle)
    let dt = cpu() - c0
    print(String(format: "  %-28@ %7.1f ms", label as NSString, dt * 1000))
    return dt
}

final class Box: ObservableObject {
    @Published var text: String
    init(_ t: String) { text = t }
}

struct Root: View {
    @ObservedObject var box: Box
    let width: CGFloat
    var body: some View {
        var c = MarkdownEditorConfiguration.default
        c.heightBehavior = .fitsContent
        c.scrollers = .hidden
        return NativeTextViewWrapper(text: $box.text, configuration: c, fontSize: NSFont.systemFontSize,
                                     documentId: "cost", isEditable: true)
            .frame(width: width)
            .fixedSize(horizontal: false, vertical: true)
    }
}

func findTextView(_ v: NSView) -> NSTextView? {
    if let t = v as? NSTextView { return t }
    for s in v.subviews { if let t = findTextView(s) { return t } }
    return nil
}

let box = Box(text)
let host = NSHostingView(rootView: Root(box: box, width: width))
host.sizingOptions = []
host.frame = NSRect(x: 0, y: 0, width: width, height: 800)
let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
window.contentView = host

let lines = text.split(separator: "\n", omittingEmptySubsequences: false).count
print("\(path)\n\(text.count) 字符 / \(lines) 行 / 宽 \(Int(width))pt\n")

print("① 打开一篇（首次排版）")
measure("首次排版") { host.layoutSubtreeIfNeeded() }

print("\n② 整篇换掉正文（Agent 写入走这条）")
var body = text
for i in 1...3 {
    body += "\n\n<!-- \(i) -->\n"
    measure("第 \(i) 次整篇替换") { box.text = body }
}

print("\n③ 打字（一次一个字，走编辑器）")
if let tv = findTextView(host) {
    tv.setSelectedRange(NSRange(location: (tv.string as NSString).length, length: 0))
    var each: [TimeInterval] = []
    for i in 0..<10 {
        each.append(measure("第 \(i + 1) 个字", settle: 0.12) { tv.insertText("字", replacementRange: tv.selectedRange()) })
    }
    let avg = each.reduce(0, +) / Double(each.count)
    print(String(format: "  —— 每字平均 %.1f ms，最坏 %.1f ms（60fps 的一帧是 16.7ms）", avg * 1000, (each.max() ?? 0) * 1000))
} else {
    print("  找不到编辑器视图，跳过")
}

print("\n④ 改宽度（拖分隔条 / 拖窗口）")
for w in [width * 0.7, width * 1.3, width] {
    measure("宽 \(Int(w))pt") {
        host.frame = NSRect(x: 0, y: 0, width: w, height: 800)
        host.rootView = Root(box: box, width: w)
        host.layoutSubtreeIfNeeded()
    }
}
