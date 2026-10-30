// 启动页「工作区」的离屏样张（`Sources/Window/WorkspacesWelcomeView.swift`）：假数据 + 中文文案，亮 / 暗各出一张 PNG 自查版式。
// 运行：
//   cp spike/workspaces-welcome-look.swift /tmp/main.swift && \
//   swiftc Sources/Window/WorkspacesWelcomeView.swift /tmp/main.swift -o /tmp/wwl && /tmp/wwl <输出目录>
// ⚠️ 侧栏材质（NSVisualEffectView）的模糊离屏画不出来，右栏背景在样张里是透明的；样张只看版式与文字。
import AppKit

let zh: [String: String] = [
    "New Workspace…": "新建工作区…", "Open Workspace…": "打开工作区…", "Connect to Server…": "连接服务器…",
]
func L(_ s: String) -> String { zh[s] ?? s }

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : NSTemporaryDirectory())
_ = NSApplication.shared
NSApp.setActivationPolicy(.accessory)

MainActor.assumeIsolated {
    let appIcon = NSWorkspace.shared.icon(forFile: "/System/Applications/Preview.app")
    let folder = NSWorkspace.shared.icon(forFile: NSHomeDirectory())
    func sym(_ n: String) -> NSImage {
        let i = NSImage(systemSymbolName: n, accessibilityDescription: nil)!.withSymbolConfiguration(.init(pointSize: 22, weight: .regular))!
        i.isTemplate = true
        return i
    }
    for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
        let v = WorkspacesWelcomeView(appName: "UniReader", version: "版本 0.3.13（54）", icon: appIcon)
        v.items = [
            .header("本机"),
            .entry(icon: folder, title: "101学习区", detail: "服务器工作区 · /Volumes/SSD/2027考研/101/101学习区.unrd"),
            .entry(icon: folder, title: "英语", detail: "~/Documents/英语.unrd"),
            .entry(icon: sym("externaldrive.badge.xmark"), title: "政治", detail: "现在打不开（它所在的盘没有接上）"),
            .header("xvan 的 MacBook Pro · 127.0.0.1:8790"),
            .entry(icon: sym("server.rack"), title: "101学习区", detail: "本机已有 · /Volumes/SSD/2027考研/101/101学习区.unrd"),
            .entry(icon: sym("server.rack"), title: "政治资料", detail: "还没有下载；打开时会先下载资料库"),
            .entry(icon: sym("server.rack"), title: "2027 数学全程（名字很长很长很长很长很长很长很长很长）",
                   detail: "正在下载 PDF（第 3 本，共 12 本）…", progress: .init(fraction: 0.42)),
            .entry(icon: sym("server.rack"), title: "英语真题", detail: "正在准备本机副本…", progress: .init(fraction: nil)),
            .header("书房的 Mac · 192.168.1.5:8790"),
            .message("连不上这台服务器：未能连接到服务器。"),
        ]
        let win = NSWindow(contentRect: NSRect(origin: .zero, size: WorkspacesWelcomeView.size),
                           styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        win.titlebarAppearsTransparent = true
        win.titleVisibility = .hidden
        win.appearance = NSAppearance(named: appearance)
        win.contentView = v
        v.layoutSubtreeIfNeeded()
        // 画整个窗口框（含窗口背景与红绿灯）：只画内容视图的话左栏没有背景，暗色下白字落在白底上
        let frameView = win.contentView!.superview!
        frameView.layoutSubtreeIfNeeded()
        let rep = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds)!
        frameView.cacheDisplay(in: frameView.bounds, to: rep)
        let file = out.appendingPathComponent("workspaces-welcome-\(name).png")
        try! rep.representation(using: .png, properties: [:])!.write(to: file)
        print(file.path)
    }
}
