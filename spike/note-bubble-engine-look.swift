// 引擎只读渲染的气泡（`MarkdownNoteReader` 在 `NoteBubbleView` / `ImageBubbleView` 里）的**样张自查**。
// `ImageRenderer` 画不出 AppKit 视图，所以这里开一扇不上屏的窗、用 `cacheDisplay` 截真实渲染。
// 依赖已编好的包模块（先 xcodebuild 一次，`build/dev/Build/Products/Debug/` 里有 `MarkdownEngine.swiftmodule` + `.o`）。运行：
//   cp spike/note-bubble-engine-look.swift /tmp/main.swift && swiftc -I build/dev/Build/Products/Debug build/dev/Build/Products/Debug/MarkdownEngine.o Sources/Support/L.swift Sources/App/NoteMarkdown.swift Sources/Views/NoteBubbleView.swift Sources/Views/MarkdownNoteEditor.swift /tmp/main.swift -o /tmp/nbe && /tmp/nbe
// 产物：/tmp/note-bubble-engine-look/*.png（可传一个目录当第 1 个参数）。
import AppKit
import SwiftUI

let outDir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/tmp/note-bubble-engine-look")
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

let short = "这一段是关键：先看定义再看例题。"
let long = """
## 洛必达法则
只对 **0/0** 与 **∞/∞** 两种未定式成立，别的形式要*先化过去*。
- 用之前先确认分母导数在去心邻域内不为零，否则结论无效
- 连续用两次以上时每一步都要重新验证条件——最常见的失分点
- [x] 极限存在不代表导数之比的极限存在，反向推不成立
> 两次之后还没化开，多半是方法选错了，试 `等价无穷小替换`

| 情形 | 做法 |
|---|---|
| 0/0 | 直接用 |
| ∞−∞ | 先通分 |
"""
let overflow = (1...30).map { "第 \($0) 行：超过上限的部分要被裁掉，不能把半页糊住。" }.joined(separator: "\n")

struct Page: View {
    let w: CGFloat
    let h: CGFloat
    let followsZoom: Bool
    var body: some View {
        let m = NoteBubble.metrics(pageWidth: w, followsZoom: followsZoom)
        let pins: [(x: CGFloat, y: CGFloat, text: String, edit: Bool)] = [
            (w * 0.16, h * 0.06, short, true),
            (w * 0.10, h * 0.22, long, true),
            (w * 0.88, h * 0.62, short, false),
            (w * 0.55, h * 0.30, overflow, true),
            (w * 0.20, h * 0.96, short, true),
        ]
        ZStack(alignment: .topLeading) {
            Color.white
            ForEach(Array(pins.enumerated()), id: \.offset) { i, p in
                let pin = CGPoint(x: min(max(p.x, 12), w - 12), y: min(max(p.y, 10), h - 10))
                Image(systemName: "note.text")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.black.opacity(0.75))
                    .padding(3)
                    .background(Color(red: 1, green: 0.80, blue: 0.15), in: Circle())
                    .overlay(Circle().stroke(.black.opacity(0.15), lineWidth: 0.5))
                    .position(pin)
                NoteBubbleView(text: p.text, documentId: "look-\(i)", metrics: m,
                               pageSize: CGSize(width: w, height: h),
                               pin: pin, pinRadius: 9, onEdit: p.edit ? {} : nil)
            }
        }
        .frame(width: w, height: h)
    }
}

@MainActor
func snap(_ name: String, w: CGFloat, h: CGFloat, followsZoom: Bool) {
    let host = NSHostingView(rootView: Page(w: w, h: h, followsZoom: followsZoom))
    host.frame = NSRect(x: 0, y: 0, width: w, height: h)
    let win = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    win.contentView = host
    win.appearance = NSAppearance(named: .darkAqua)   // 故意用深色外观：验气泡钉死浅色（不能变白字）
    win.orderFront(nil)
    // 引擎要几拍才排完（fitsContent 报高度 → SwiftUI 再布局）
    let deadline = Date().addingTimeInterval(1.5)
    while Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    host.layoutSubtreeIfNeeded()
    guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { print("✗ \(name)"); return }
    host.cacheDisplay(in: host.bounds, to: rep)
    guard let png = rep.representation(using: .png, properties: [:]) else { print("✗ \(name)"); return }
    let url = outDir.appendingPathComponent(name + ".png")
    try? png.write(to: url)
    print("✓ \(url.path)")
    win.orderOut(nil)
}

@MainActor
func run() {
    let app = NSApplication.shared
    app.setActivationPolicy(.prohibited)
    snap("engine-fixed-760", w: 760, h: 988, followsZoom: false)
    snap("engine-zoom-1200", w: 1200, h: 1560, followsZoom: true)
    print("\n逐张看：标题/列表/任务/引用/表格是不是引擎画的样子、超长的那条有没有被裁在行数上限、深色外观下字是不是仍是深色。")
}

MainActor.assumeIsolated { run() }
