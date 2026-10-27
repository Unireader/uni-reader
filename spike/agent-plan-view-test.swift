// 离屏验证 Agent 面板的**计划**条目（`Sources/Window/AI/AgentPlanView.swift`，编的是真代码，计划项类型换成桩）。运行：
//
//   O=/tmp/agent-plan-view; mkdir -p $O && cp spike/agent-plan-view-test.swift $O/main.swift && \
//   swiftc Sources/Support/L.swift Sources/Window/AI/AgentPlanView.swift $O/main.swift -o $O/t && $O/t $O
//
// 起因（2026-10-27 用户截图）：Kimi 推来二十来项的待办，原来 `NSBox` + `box.contentView = stack` 的写法 box 只有一行字高，
// 整片清单叠在上面的条目上。盯五件事：
//  1. 放进和对话记录同款的竖排 stack（间距 12、宽度约束 = stack 宽 − 28）后，计划的高度装得下全部内容：
//     标题与每一项都在框里，项与项上下不重叠，图标对齐第一行文字；
//  2. 不压上下两条：上一条的下沿 + 12 = 计划的上沿，计划的下沿 + 12 = 下一条的上沿；
//  3. 宽度从宽变窄：文字多折行、高度变高，并报一次 `onHeightChange`；
//  4. 就地更新：内容变了高度跟着变、报一次；内容没变什么都不动；
//  5. 没有含糊约束。另出浅 / 深两张样张（$O/plan-light.png、$O/plan-dark.png）。
import AppKit

enum PlanEntryStatus { case pending, inProgress, completed, cancelled }
struct AgentPlanEntry: Equatable {
    var text: String
    var status: PlanEntryStatus
}

_ = NSApplication.shared
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/tmp"

var pass = 0, fail = 0
func check(_ c: Bool, _ m: String) { if c { pass += 1; print("  ✅ \(m)") } else { fail += 1; print("  ❌ \(m)") } }

final class Flipped: NSStackView { override var isFlipped: Bool { true } }

let names = ["毛中特 综合测试一（p.41-47）", "毛中特 综合测试二（p.48-53）", "习概 综合测试一（p.55-60）", "习概 综合测试二（p.61-66）",
             "习概 综合测试三（p.67-73）", "习概 综合测试四（p.74-80）", "习概 综合测试五（p.81-86）", "史纲 综合测试一（p.88-92）",
             "史纲 综合测试二（p.93-98）", "史纲 综合测试三（p.99-104）", "史纲 综合测试四（p.105-110）", "史纲 综合测试五（p.111-116）",
             "思修 综合测试一（p.118-123）", "思修 综合测试二（p.124-128）", "思修 综合测试三（p.129-134）",
             "答案册每套开篇都有「答案速查」表格，用图像读表比 OCR 可靠得多：逐页 render_page 读表，再 update_exercises 补答案，这一项故意写长看折行"]
var entries = names.enumerated().map { i, n in
    AgentPlanEntry(text: n, status: i == 0 ? .completed : i == 1 ? .inProgress : i == 5 ? .cancelled : .pending)
}

func label(_ s: String) -> NSTextField {
    let t = NSTextField(labelWithString: s)
    t.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
    return t
}

/// 搭一个和对话记录同款的竖排 stack：上一条 + 计划 + 下一条。
@MainActor func build(width: CGFloat, appearance: NSAppearance.Name = .darkAqua) -> (NSWindow, NSView, NSView, AgentPlanView, NSView) {
    let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 900), styleMask: [.borderless], backing: .buffered, defer: false)
    win.appearance = NSAppearance(named: appearance)
    let container = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 900))
    win.contentView = container
    let stack = Flipped()
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 12
    stack.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
    stack.translatesAutoresizingMaskIntoConstraints = false
    container.addSubview(stack)
    NSLayoutConstraint.activate([
        stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
        stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        stack.topAnchor.constraint(equalTo: container.topAnchor),
    ])
    let above = label("get_document"), below = label("read_pages")
    let plan = AgentPlanView(entries: entries)
    for v in [above, plan, below] as [NSView] { stack.addArrangedSubview(v) }
    // 同 `refreshTranscript`：进了 stack 再激活宽度约束
    for v in [above, plan, below] as [NSView] {
        v.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28).isActive = true
    }
    return (win, stack, above, plan, below)
}

@MainActor func settle(_ v: NSView) { for _ in 0..<3 { v.layoutSubtreeIfNeeded() } }

@MainActor func checkLayout(_ tag: String, _ stack: NSView, _ above: NSView, _ plan: AgentPlanView, _ below: NSView) {
    settle(stack)
    let f = plan.frame
    check(f.height > 100, "\(tag)：计划有实际高度（\(Int(f.height))pt，不是一行字高）")
    let subs = plan.subviews.filter { !($0 is NSBox) }
    check(subs.allSatisfy { plan.bounds.contains($0.frame.insetBy(dx: 0.5, dy: 0.5)) }, "\(tag)：标题与每一项都在框里")
    let texts = subs.compactMap { $0 as? NSTextField }.sorted { $0.frame.minY < $1.frame.minY }
    var overlap = false
    for (a, b) in zip(texts, texts.dropFirst()) where a.frame.maxY > b.frame.minY + 0.5 { overlap = true }
    check(!overlap, "\(tag)：项与项上下不重叠（\(texts.count) 段文字）")
    let icons = subs.compactMap { $0 as? NSImageView }
    let firstLine = texts.dropFirst().first   // 第一段是标题
    check(icons.count == entries.count, "\(tag)：每项一个图标")
    if let t = firstLine, let i = icons.min(by: { $0.frame.minY < $1.frame.minY }) {
        check(i.frame.minY >= t.frame.minY - 0.5 && i.frame.maxY <= t.frame.minY + 22, "\(tag)：图标对齐第一行文字")
    }
    if plan.entries.count == names.count, let longText = texts.last {   // 更新后只剩前 6 项，没有长的那项
        check(longText.frame.height > 25, "\(tag)：长的那项折成多行（\(Int(longText.frame.height))pt）")
    }
    check(abs(above.frame.maxY + 12 - f.minY) < 0.5, "\(tag)：上一条下沿 + 12 = 计划上沿（\(above.frame.maxY) / \(f.minY)）")
    check(abs(f.maxY + 12 - below.frame.minY) < 0.5, "\(tag)：计划下沿 + 12 = 下一条上沿（\(f.maxY) / \(below.frame.minY)）")
    check(abs(f.width - (stack.frame.width - 28)) < 0.5, "\(tag)：宽度 = 对话记录宽 − 28")
}

@MainActor func run() {
    print("1–2. 放进对话记录同款 stack")
    let (win, stack, above, plan, below) = build(width: 420)
    checkLayout("宽 420", stack, above, plan, below)
    check(!(win.contentView?.hasAmbiguousLayout ?? true), "没有含糊约束")

    print("3. 变窄：多折行、变高、报高度变化")
    var fired = 0
    plan.onHeightChange = { fired += 1 }
    let h420 = plan.frame.height
    win.setContentSize(NSSize(width: 290, height: 900))
    win.contentView?.frame.size.width = 290
    checkLayout("宽 290", stack, above, plan, below)
    check(plan.frame.height > h420, "窄了更高（\(Int(h420)) → \(Int(plan.frame.height))）")
    check(fired >= 1, "报了高度变化（\(fired) 次）")

    print("4. 就地更新")
    fired = 0
    let h0 = plan.frame.height
    plan.update(entries)
    settle(stack)
    check(fired == 0 && plan.frame.height == h0, "内容没变：不报、高度不动")
    entries[2].status = .completed
    entries = Array(entries.prefix(6))
    plan.update(entries)
    settle(stack)
    check(fired == 1, "内容变了：报一次（\(fired)）")
    check(plan.frame.height < h0, "项少了高度变矮（\(Int(h0)) → \(Int(plan.frame.height))）")
    check(plan.subviews.filter { $0 is NSImageView }.count == 6, "旧的行摘干净了，只剩 6 个图标")
    checkLayout("更新后", stack, above, plan, below)

    print("5. 样张")
    entries = names.enumerated().map { i, n in
        AgentPlanEntry(text: n, status: i < 3 ? .completed : i == 3 ? .inProgress : i == 5 ? .cancelled : .pending)
    }
    for (name, ap) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
        let (w, s, _, _, _) = build(width: 340, appearance: ap)
        settle(s)
        let c = w.contentView!
        c.wantsLayer = true
        // 层的底色要在样张的外观下取（否则按系统当前外观解析，浅色样张会是深底）
        NSAppearance(named: ap)!.performAsCurrentDrawingAppearance { c.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor }
        let h = s.fittingSize.height
        c.frame.size.height = h
        w.setContentSize(NSSize(width: 340, height: h))
        settle(s)
        c.display()
        let rep = c.bitmapImageRepForCachingDisplay(in: c.bounds)!
        NSAppearance(named: ap)!.performAsCurrentDrawingAppearance { c.cacheDisplay(in: c.bounds, to: rep) }
        try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(out)/plan-\(name).png"))
    }
    print("  样张：\(out)/plan-light.png、\(out)/plan-dark.png")

}
MainActor.assumeIsolated { run() }

print("\n通过 \(pass)，失败 \(fail)")
exit(fail == 0 ? 0 : 1)
