// 无头探针：legacy（占空间）滚动条下 SwiftUI ScrollGeometry 的精确语义。
// 修「关侧栏后水平滚动条常驻」bug 的依据（用户环境：鼠标接入 → 系统默认 legacy 滚动条）。
// 运行：swiftc -parse-as-library spike/legacy-scroller-probe.swift -o /tmp/scroller-probe \
//       && /tmp/scroller-probe -AppleShowScrollBars Always && /tmp/scroller-probe -AppleShowScrollBars WhenScrolling
//
//  Q1  内容竖向超长（有垂直滚动条）时，containerSize.width 是否已扣除滚动条宽（≈15/16pt）？
//  Q2  水平可滚域判定：contentW 多宽会产生水平滚动范围（scrollTo(x:大数) 后 offsetX>0 即有范围=会出横条）？
//      contentW == containerW 时应为 0（这正是 fit 宽应取的值）。
//  Q3  无垂直滚动条（内容矮）时 containerSize.width 是否回到全宽？

import SwiftUI
import AppKit

struct Snap: Equatable {
    var x: CGFloat, y: CGFloat, cw: CGFloat, ch: CGFloat, kw: CGFloat, kh: CGFloat
}

nonisolated(unsafe) var latest = Snap(x: 0, y: 0, cw: 0, ch: 0, kw: 0, kh: 0)

struct ProbeRoot: View {
    @State var pos = ScrollPosition()
    @State var contentW: CGFloat = 500
    @State var contentH: CGFloat = 4000

    var body: some View {
        ScrollView([.vertical, .horizontal]) {
            Color.blue.frame(width: contentW, height: contentH)
        }
        .scrollPosition($pos)
        .onScrollGeometryChange(for: Snap.self) { g in
            Snap(x: g.contentOffset.x, y: g.contentOffset.y,
                 cw: g.contentSize.width, ch: g.contentSize.height,
                 kw: g.containerSize.width, kh: g.containerSize.height)
        } action: { _, new in latest = new }
        .onReceive(NotificationCenter.default.publisher(for: .init("cmd"))) { note in
            guard let cmd = note.object as? [String: CGFloat] else { return }
            var t = Transaction(); t.animation = nil
            withTransaction(t) {
                if let w = cmd["w"] { contentW = w }
                if let h = cmd["h"] { contentH = h }
                if let x = cmd["x"] { pos.scrollTo(point: CGPoint(x: x, y: latest.y < 0 ? 0 : latest.y)) }
            }
        }
    }
}

@main
struct ScrollerProbe {
    static func main() {
        let style = UserDefaults.standard.string(forKey: "AppleShowScrollBars") ?? "系统默认"
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let host = NSHostingView(rootView: ProbeRoot())
        host.frame = NSRect(x: 0, y: 0, width: 500, height: 400)
        window.contentView = host
        window.orderBack(nil)

        func pump(_ s: Double) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }
        func send(_ d: [String: CGFloat]) { NotificationCenter.default.post(name: .init("cmd"), object: d); pump(0.4) }

        pump(0.5)
        print("模式=\(style)  scroller 系统偏好=\(NSScroller.preferredScrollerStyle == .legacy ? "legacy" : "overlay")")
        print("Q1  内容 500x4000（竖向超长）: container=\(latest.kw)x\(latest.kh)  → 全宽 500，扣除量=\(500 - latest.kw)")

        send(["x": 9999])
        print("Q2a contentW=500 scrollTo(x:9999) → offsetX=\(latest.x)（>0 = 有水平滚动范围 = 会出横条）")

        send(["w": latest.kw, "x": 0]); send(["x": 9999])
        print("Q2b contentW=containerW(\(latest.cw)) scrollTo(x:9999) → offsetX=\(latest.x)（应=0：fit 取 containerW 即无横条）")

        send(["w": 500, "h": 300, "x": 0])
        print("Q3  内容 500x300（无竖条）: container=\(latest.kw)x\(latest.kh)")
        exit(0)
    }
}
