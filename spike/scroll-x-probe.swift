// 无头探针：双轴 ScrollView 的 x 轴 scrollTo 语义（修「放大后水平跳最左 + 闪烁」bug 的依据）。
// 运行：swiftc spike/scroll-x-probe.swift -o /tmp/x-probe && /tmp/x-probe
//
//  T1  同一 transaction 里 scrollTo(x:) + scrollTo(y:) 顺序两次调用：两轴都生效，还是后者覆盖前者？
//  T2  scrollTo(point:)：是否两轴一起生效？
//  T3  关键：同 transaction「内容尺寸×2 + scrollTo 到超出旧范围的点」——
//      目标会不会被按旧几何夹取（x 旧范围=0）？夹取后同周期内还能不能校正？
//  T4  已有双轴偏移时，仅 scrollTo(y:)：x 保持还是被重置？（跟随器/锚点路径依赖此语义）

import SwiftUI
import AppKit

struct Snap: Equatable {
    var x: CGFloat
    var y: CGFloat
    var cw: CGFloat
    var ch: CGFloat
}

nonisolated(unsafe) var events: [(String, Snap, Int)] = []
nonisolated(unsafe) var phase = "boot"
nonisolated(unsafe) var rlCycle = 0

struct ProbeRoot: View {
    @State var pos = ScrollPosition()
    @State var scale: CGFloat = 1

    var body: some View {
        ScrollView([.vertical, .horizontal]) {
            ZStack(alignment: .topLeading) {
                ForEach(0..<20, id: \.self) { i in
                    Color(hue: Double(i) / 20, saturation: 0.5, brightness: 0.8)
                        .frame(width: 500 * scale, height: 200 * scale)
                        .offset(y: CGFloat(i) * 200 * scale)
                }
            }
            .frame(width: 500 * scale, height: 4000 * scale, alignment: .topLeading)
        }
        .scrollPosition($pos)
        .onScrollGeometryChange(for: Snap.self) { g in
            Snap(x: g.contentOffset.x, y: g.contentOffset.y,
                 cw: g.contentSize.width, ch: g.contentSize.height)
        } action: { _, new in
            events.append((phase, new, rlCycle))
        }
        .onReceive(NotificationCenter.default.publisher(for: .init("cmd"))) { note in
            guard let cmd = note.object as? String else { return }
            var t = Transaction(); t.animation = nil
            switch cmd {
            case "seq-xy":                       // T1：顺序两次（不改尺寸，目标在范围内）
                withTransaction(t) { pos.scrollTo(x: 120); pos.scrollTo(y: 300) }
            case "point":                        // T2：point 一次
                withTransaction(t) { pos.scrollTo(point: CGPoint(x: 200, y: 500)) }
            case "zoom-commit-seq":              // T3a：尺寸×2 + 顺序两次，目标超旧范围（x 旧范围=0）
                withTransaction(t) { scale = 2; pos.scrollTo(x: 250); pos.scrollTo(y: 6200) }
            case "reset":
                withTransaction(t) { scale = 1; pos.scrollTo(x: 0); pos.scrollTo(y: 0) }
            case "zoom-commit-point":            // T3b：尺寸×2 + point，目标超旧范围
                withTransaction(t) { scale = 2; pos.scrollTo(point: CGPoint(x: 250, y: 6200)) }
            case "y-only":                       // T4：已有 x 偏移时仅动 y
                withTransaction(t) { pos.scrollTo(y: 700) }
            default: break
            }
        }
    }
}

@main
struct XProbe {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let obs = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, true, 0) { _, _ in
            rlCycle += 1
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), obs, .commonModes)

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let host = NSHostingView(rootView: ProbeRoot())
        host.frame = NSRect(x: 0, y: 0, width: 500, height: 400)
        window.contentView = host
        window.orderBack(nil)

        func pump(_ s: Double) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }
        func run(_ name: String, _ cmd: String, settle: Double = 0.5) {
            events.removeAll(); phase = name
            NotificationCenter.default.post(name: .init("cmd"), object: cmd)
            pump(settle)
            print("== \(name) ==")
            for e in events { print("  cycle=\(e.2) x=\(e.1.x) y=\(e.1.y) content=\(Int(e.1.cw))x\(Int(e.1.ch))") }
            if let last = events.last { print("  终态 x=\(last.1.x) y=\(last.1.y)") }
        }

        pump(0.5)
        run("T1 顺序 scrollTo(x:120)+scrollTo(y:300)（范围内）", "seq-xy")
        run("T2 scrollTo(point:(200,500))", "point")
        run("T3a 尺寸×2 + 顺序 x:250,y:6200（超旧范围）", "zoom-commit-seq")
        run("复位", "reset")
        run("T3b 尺寸×2 + point(250,6200)（超旧范围）", "zoom-commit-point")
        run("T4 已有 x=250 时仅 scrollTo(y:700)", "y-only")
        exit(0)
    }
}
