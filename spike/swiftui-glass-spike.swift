// SwiftUI 页图流可行性 spike：验证「SwiftUI 原生 ScrollView 承载页图」是否能在现有
// NavigationSplitView 架构下一次拿到——① 顶部工具栏 scroll-under 虚化、② 侧栏/Inspector 真内容延伸、
// ③ 双击标题栏是窗口行为(不抢内容)、④ 不崩侧栏。若成立 → Mac 阅读区从 PDFKit 换 SwiftUI ScrollView + 页图，
// 且**不用迁 AppKit**、保留现有 SwiftUI 主窗口架构。
//
// 运行：swiftc spike/swiftui-glass-spike.swift -o /tmp/sw-spike && /tmp/sw-spike
// 用 AppKit 引导启动(NSApplication + NSHostingController)以保证命令行能弹出前台窗口。

import SwiftUI
import AppKit

struct RootView: View {
    @State private var showInspector = true
    private let colors: [Color] = [.red, .orange, .yellow, .green, .blue, .purple, .pink, .teal]

    var body: some View {
        NavigationSplitView {
            List(0..<30, id: \.self) { i in Text("Sidebar \(i)") }
                .navigationSplitViewColumnWidth(min: 200, ideal: 240)
        } detail: {
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(0..<60, id: \.self) { i in
                        RoundedRectangle(cornerRadius: 10)
                            .fill(colors[i % colors.count])
                            .frame(height: 170)
                            .overlay(Text("\(i)").font(.system(size: 48, weight: .bold)).foregroundStyle(.white))
                    }
                }
                .padding()
            }
            // 让内容延伸到侧栏/工具栏玻璃后。PDFKit 在这一步会抢标题栏交互+崩侧栏；
            // 纯 SwiftUI ScrollView 理论上不会——正是这个 spike 要验证的。
            .ignoresSafeArea()
            .toolbar {
                ToolbarItemGroup {
                    Button { } label: { Image(systemName: "folder") }
                    Button { } label: { Image(systemName: "moon.fill") }
                    Button { showInspector.toggle() } label: { Image(systemName: "sidebar.right") }
                }
            }
        }
        .inspector(isPresented: $showInspector) {
            List(0..<15, id: \.self) { i in Text("Inspector \(i)") }
                .scrollContentBackground(.hidden)   // List 背景透明 → 露出 inspector 玻璃
                .inspectorColumnWidth(min: 240, ideal: 300)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    func applicationDidFinishLaunching(_ n: Notification) {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.title = "SwiftUI Glass Spike"
        window.contentViewController = NSHostingController(rootView: RootView())
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { true }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
