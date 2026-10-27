// 离屏验证 Agent 面板输入框上方的「排队中」（`Sources/Window/AI/AgentQueueView.swift`，编的是真代码，`ClosureButton` 换成桩）。运行：
//
//   O=/tmp/agent-queue-view; mkdir -p $O && cp spike/agent-queue-view-test.swift $O/main.swift && \
//   swiftc Sources/Support/L.swift Sources/Window/AI/AgentQueueView.swift $O/main.swift -o $O/t && $O/t $O
//
// 盯四件事：
//  1. 高度 = 上下边距 + 标题行 + 每条一行；每行的字、编辑、移除都在框里，字不压到按钮上，长的省略、多行只显示第一行；
//  2. 带图片的那条后面写「N 张图片」，悬停提示是整句原文；
//  3. 「编辑」「移除」点了回调带的是那一条的 id；内容没变 `update` 不重建行，变了旧行摘干净；
//  4. 样张（浅 / 深）：$O/queue-light.png、$O/queue-dark.png（最窄 276pt）。
import AppKit

final class ClosureButton: NSButton {
    private let handler: () -> Void
    init(action: @escaping () -> Void) {
        handler = action
        super.init(frame: .zero)
        target = self
        self.action = #selector(fire)
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func fire() { handler() }
}

_ = NSApplication.shared
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/tmp"
var pass = 0, fail = 0
func check(_ c: Bool, _ m: String) { if c { pass += 1; print("  ✅ \(m)") } else { fail += 1; print("  ❌ \(m)") } }

@MainActor func run() {
    let a = AgentQueueView.Item(id: UUID(), text: "把第 3 章的习题也导进来", images: 0)
    let b = AgentQueueView.Item(id: UUID(), text: "顺便看看这两张截图里的题号对不对，有问题的话先列出来，我再决定要不要改，这一句故意写长看省略\n第二行不显示", images: 2)
    let c = AgentQueueView.Item(id: UUID(), text: "/compact", images: 0)

    print("1–2. 摆位")
    let v = AgentQueueView()
    v.update([a, b, c])
    let h = v.preferredHeight
    check(h == 2 * 6 + 20 + 3 * 24, "高度 = 边距 + 标题 + 3 行（\(h)）")
    v.frame = NSRect(x: 0, y: 0, width: 276, height: h)
    v.layoutSubtreeIfNeeded()
    let texts = v.subviews.compactMap { $0 as? NSTextField }.filter { $0.toolTip != nil }
    let buttons = v.subviews.compactMap { $0 as? NSButton }
    check(texts.count == 3 && buttons.count == 6, "3 行字、6 个按钮")
    check(v.subviews.allSatisfy { v.bounds.contains($0.frame.insetBy(dx: 0.5, dy: 0.5)) }, "全部在框里")
    for t in texts {
        let row = buttons.filter { abs($0.frame.midY - t.frame.midY) < 2 }
        check(row.count == 2 && row.allSatisfy { $0.frame.minX >= t.frame.maxX + 5 }, "「\(t.stringValue.prefix(8))…」不压按钮，同一行两个按钮")
    }
    let long = texts.first { $0.toolTip == b.text }!
    check(!long.stringValue.contains("第二行"), "多行只显示第一行")
    check(long.stringValue.hasPrefix("2 images · "), "带图写张数，放在前面（\(long.stringValue.prefix(12))）")
    check(long.intrinsicContentSize.width > long.frame.width, "太长：放不下、按尾部省略")
    check(long.toolTip == b.text, "悬停提示是整句原文")

    print("3. 回调与更新")
    var edited: UUID?, removed: UUID?
    v.onEdit = { edited = $0 }
    v.onRemove = { removed = $0 }
    let rowB = buttons.filter { abs($0.frame.midY - long.frame.midY) < 2 }.sorted { $0.frame.minX < $1.frame.minX }
    rowB[0].performClick(nil)
    rowB[1].performClick(nil)
    check(edited == b.id, "编辑：回调带第二条的 id")
    check(removed == b.id, "移除：回调带第二条的 id")
    let before = v.subviews.map(ObjectIdentifier.init)
    v.update([a, b, c])
    check(v.subviews.map(ObjectIdentifier.init) == before, "内容没变：不重建")
    v.update([a, c])
    check(v.subviews.compactMap { $0 as? NSButton }.count == 4 && v.preferredHeight == 2 * 6 + 20 + 2 * 24, "少了一条：旧行摘干净、高度跟着变")
    v.update([])
    check(v.preferredHeight == 0, "空了高度为 0")

    print("4. 样张")
    for (name, ap) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: h + 24))
        let win = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        win.appearance = NSAppearance(named: ap)
        win.contentView = host
        host.wantsLayer = true
        NSAppearance(named: ap)!.performAsCurrentDrawingAppearance { host.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor }
        let q = AgentQueueView()
        q.update([a, b, c])
        q.frame = NSRect(x: 12, y: 12, width: 276, height: q.preferredHeight)
        host.addSubview(q)
        host.layoutSubtreeIfNeeded()
        host.display()
        let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
        NSAppearance(named: ap)!.performAsCurrentDrawingAppearance { host.cacheDisplay(in: host.bounds, to: rep) }
        try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(out)/queue-\(name).png"))
    }
    print("  样张：\(out)/queue-light.png、\(out)/queue-dark.png")
}
MainActor.assumeIsolated { run() }

print("\n通过 \(pass)，失败 \(fail)")
exit(fail == 0 ? 0 : 1)
