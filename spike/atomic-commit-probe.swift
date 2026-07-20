// 无头探针：SwiftUI ScrollView 的两个决定性语义（决定 pinch commit / resize 锚定的实现姿势）。
// 运行：swiftc spike/atomic-commit-probe.swift -o /tmp/atomic-probe && /tmp/atomic-probe
//
//  Q1  ScrollPosition.scrollTo(y:) 的语义是否 = contentOffset.y 直接赋值（校准锚点换算原点）。
//  Q2  同一 transaction 里「内容尺寸 ×2 + scrollTo(补偿目标)」：几何回调序列中是否出现
//      (新尺寸, 旧偏移) 的中间态（= 非原子，会闪一帧）；还是直接一步到 (新尺寸, 新偏移)（= 原子）。
//  Q3  onScrollGeometryChange 是否也会为程序化 scrollTo 回调（锚点上报依赖它）。
//
// 离屏 NSWindow + NSHostingView + 泵 RunLoop；不上屏。

import SwiftUI
import AppKit

struct Snap: Equatable {
    var offsetY: CGFloat
    var contentH: CGFloat
    var insetTop: CGFloat
}

var events: [(String, Snap, Int)] = []
var phase = "boot"
// runloop 周期计数：同周期内的多次状态变化会合并进同一次 CA commit → 屏幕上是原子的。
var rlCycle = 0
let rlObserver = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, true, 0) { _, _ in
    rlCycle += 1
}

struct ProbeRoot: View {
    @State var pos = ScrollPosition()
    @State var scale: CGFloat = 1

    var body: some View {
        ScrollView([.vertical]) {
            VStack(spacing: 0) {
                ForEach(0..<20, id: \.self) { i in
                    Color(hue: Double(i) / 20, saturation: 0.5, brightness: 0.8)
                        .frame(width: 300 * scale, height: 200 * scale)
                }
            }
            .frame(width: 300 * scale, height: 4000 * scale, alignment: .topLeading)
        }
        .scrollPosition($pos)
        .onScrollGeometryChange(for: Snap.self) { g in
            Snap(offsetY: g.contentOffset.y, contentH: g.contentSize.height, insetTop: g.contentInsets.top)
        } action: { _, new in
            events.append((phase, new, rlCycle))
        }
        .onReceive(NotificationCenter.default.publisher(for: .init("cmd"))) { note in
            guard let cmd = note.object as? String else { return }
            var t = Transaction(); t.animation = nil
            switch cmd {
            case "scroll300":
                withTransaction(t) { pos.scrollTo(y: 300) }
            case "zoomCommit":
                // 模拟 pinch commit：尺寸 ×2 且偏移补偿到 2 倍（锚定顶部内容点）
                withTransaction(t) {
                    scale = 2
                    pos.scrollTo(y: 600)
                }
            default: break
            }
        }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
CFRunLoopAddObserver(CFRunLoopGetMain(), rlObserver, .commonModes)
let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 500),
                      styleMask: [.titled], backing: .buffered, defer: false)
let host = NSHostingView(rootView: ProbeRoot())
host.frame = NSRect(x: 0, y: 0, width: 300, height: 500)
window.contentView = host
// 不 orderFront —— 离屏。但需要让视图认为可显示以驱动布局。
window.orderBack(nil)

func pump(_ seconds: Double) {
    RunLoop.main.run(until: Date().addingTimeInterval(seconds))
}

pump(0.5)
print("== 初始事件 ==")
for e in events { print("  [\(e.0)] cycle=\(e.2) offsetY=\(e.1.offsetY) contentH=\(e.1.contentH) insetTop=\(e.1.insetTop)") }

events.removeAll(); phase = "scroll300"
NotificationCenter.default.post(name: .init("cmd"), object: "scroll300")
pump(0.5)
print("\n== Q1/Q3: scrollTo(y:300) 后事件 ==")
for e in events { print("  [\(e.0)] cycle=\(e.2) offsetY=\(e.1.offsetY) contentH=\(e.1.contentH)") }
if let last = events.last {
    print("  → scrollTo(y:300) 终态 offsetY=\(last.1.offsetY)（==300 则 scrollTo 语义就是 contentOffset）")
}

events.removeAll(); phase = "zoomCommit"
NotificationCenter.default.post(name: .init("cmd"), object: "zoomCommit")
pump(0.8)
print("\n== Q2: 同 transaction「尺寸×2 + scrollTo(600)」事件序列 ==")
for e in events { print("  [\(e.0)] cycle=\(e.2) offsetY=\(e.1.offsetY) contentH=\(e.1.contentH)") }
let inter = events.first { $0.1.contentH > 7900 && abs($0.1.offsetY - 300) < 1 }
let final_ = events.first { $0.1.contentH > 7900 && abs($0.1.offsetY - 600) < 1 }
print("  → (新尺寸,旧偏移)中间态: \(inter.map { "cycle=\($0.2)" } ?? "无")")
print("  → (新尺寸,新偏移)终态:   \(final_.map { "cycle=\($0.2)" } ?? "无")")
if let i = inter, let f = final_ {
    print("  → 结论: \(i.2 == f.2 ? "同一 runloop 周期 = 同一次 CA commit = 屏幕原子 ✓（无需补偿保持）" : "跨周期 = 中间态会上屏一帧 ✗（必须补偿保持）")")
}
