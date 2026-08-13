import SwiftUI
import AppKit

/// 工作区打开链路的诊断日志（`[WS-OPEN]` 前缀）。**文件通道默认关闭**——只在日志文件已存在时才追加：
/// ```
/// touch ~/Library/Logs/UniReader-ws.log    # 开启
/// rm    ~/Library/Logs/UniReader-ws.log    # 关闭
/// ```
/// 为什么要自建通道而不用系统日志：双击启动的 app 不挂在 Xcode 控制台下（`print` 看不到），
/// 而 unified logging（`log show`/`log stream`）在这台机器上**抓不到本 app 的任何输出**
/// （2026-07-29 实测：按进程过滤零条记录，连系统框架的日志都没有）。这条链路又横跨
/// LaunchServices → AppDelegate → 通知/冷启动缓冲 → RootView → ContentView，任一环静默断掉都只
/// 表现为「双击没反应」，已为此改错三轮——留个随时可开、平时零开销的观察窗口。答案往往是
/// **日志里该有却没有的那一行**。
let wsLogURL = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Logs/UniReader-ws.log")

func wsLog(_ msg: String) {
    NSLog("[WS-OPEN] %@", msg)   // Xcode 里跑时直接可见
    guard let h = try? FileHandle(forWritingTo: wsLogURL) else { return }   // 文件不存在 = 通道关闭
    defer { try? h.close() }
    let line = "\(Date.now.formatted(date: .omitted, time: .standard)) [\(ProcessInfo.processInfo.processIdentifier)] \(msg)\n"
    guard let data = line.data(using: .utf8) else { return }
    _ = try? h.seekToEnd()
    try? h.write(contentsOf: data)
}

/// 平板页图链路的耗时日志（`[PAD]` 前缀）。开关口径同 [wsLog]——**文件在不在就是开关**：
/// ```
/// touch ~/Library/Logs/UniReader-pad.log    # 开启
/// rm    ~/Library/Logs/UniReader-pad.log    # 关闭
/// ```
/// 为什么单开一支而不并进 `wsLog`：这条是**每张页图都写一行**的高频通道，混进工作区打开链路的
/// 日志里会把那份冲没；而且它量的就是渲染延迟本身，所以：
/// - **不发 `NSLog`**（unified logging 在这台机器上抓不到，还白付一次格式化）；
/// - **写盘甩到独立队列**——`LANServer` 那条服务 queue 是串行的，日志 I/O 落在上面等于把
///   被测对象也算进读数里；
/// - 关着的时候只剩一次「每秒最多一遍」的 `fileExists`，热路径上零开销。
enum PadLog {
    static let url = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Logs/UniReader-pad.log")

    private static let queue = DispatchQueue(label: "com.xvan.UniReader.padlog", qos: .utility)
    private static var handle: FileHandle?      // 只在 queue 上碰
    private static var checkedAt: CFAbsoluteTime = 0   // 以下两个只在 LANServer 服务 queue 上碰
    private static var isOn = false

    /// 每张页图都会问一遍，故探盘节流到 1s 一次（开关是给人用的，秒级生效足够）。
    private static var enabled: Bool {
        let now = CFAbsoluteTimeGetCurrent()
        if now - checkedAt > 1 {
            checkedAt = now
            let on = FileManager.default.fileExists(atPath: url.path)
            if on != isOn {
                isOn = on
                queue.async { handle = nil }   // 关掉/被 rm 过 → 下次写重新开句柄
            }
        }
        return isOn
    }

    static func log(_ msg: @autoclosure () -> String) {
        guard enabled else { return }
        let line = "\(Date.now.formatted(date: .omitted, time: .standard)) [PAD] \(msg())\n"
        queue.async {
            if handle == nil {
                handle = try? FileHandle(forWritingTo: url)
                _ = try? handle?.seekToEnd()
            }
            guard let h = handle, let d = line.data(using: .utf8) else { return }
            try? h.write(contentsOf: d)
        }
    }

    /// 秒 → 毫秒的统一格式（日志里的数都是 `12.3ms` 这个样子）
    static func ms(_ seconds: CFAbsoluteTime) -> String { String(format: "%.1fms", seconds * 1000) }
}

/// 单实例守卫（新实例接管 / last-wins）：本次启动时若已有同一 App 在跑，
/// 优雅终止旧实例并接管——释放局域网服务端口（8770/8771），杜绝多份状态与端口冲突。
/// 选 last-wins 而非 first-wins：Xcode 每次 Run = 新进程，需保证看到的永远是最新构建，
/// 且旧进程即便未被及时回收也会被这里清掉。正式发布如需「第二次打开只激活已有窗口」再切 first-wins。
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// 是否正在退出（cmd+q / 被单实例守卫接管）。用于区分「退出关窗」vs「cmd+w 单独关窗」：
    /// 退出时**不修改**工作区「打开集」（下次启动原样恢复所有窗口）；cmd+w 才逐个移除。
    /// `applicationShouldTerminate` 在各窗口 `onDisappear` **之前**触发，故此标志对关窗回调可见。
    static var isTerminating = false

    /// 冷启动时被双击/拖入的 .unrd 路径（视图树尚未就绪、通知无人接收时兜底）。
    /// 由 `RootView.resolve` 消费——冷启动时**不能**在 onAppear 那一刻消费（那时事件还没投递到，
    /// 见 `RootView` 里的时序说明），得等 `didFinishLaunching` 那一轮。
    static var pendingWorkspacePath: String?

    /// Finder 双击 / 拖到 Dock 图标的 .unrd 工作区包（**现代入口**）。
    /// AppKit 只要 delegate 实现了这个方法就一律走它，下面那个 `openFile:` 版本便再也不会被调用
    /// （`openFile:`/`openFiles:` 都是 deprecated 的旧签名）。两个都留着并各自打点，日志即可判明
    /// 系统实际投递到了哪一条。
    func application(_ application: NSApplication, open urls: [URL]) {
        wsLog("application(open:) urls=\(urls.map(\.path))")
        guard let u = urls.first(where: { $0.pathExtension == WorkspaceManager.packageExtension }) else {
            wsLog("application(open:) 里没有 .\(WorkspaceManager.packageExtension) 包，忽略")
            return
        }
        Self.deliverWorkspace(u.path)
    }

    /// 同上的旧签名入口（保留兜底：万一某条路径/某个系统版本仍走它）。
    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        wsLog("application(openFile:) \(filename)")
        Self.deliverWorkspace(filename)
        return true
    }

    /// 统一投递：冷启动缓冲 + 发通知。两个入口共用，并做一次短时去重
    /// （同一路径 1s 内只投一次），免得将来两条都被调用时把工作区切两遍。
    static func deliverWorkspace(_ path: String) {
        let now = Date.now
        if let last = lastDelivered, last.path == path, now.timeIntervalSince(last.at) < 1 {
            wsLog("重复投递，忽略：\(path)")
            return
        }
        lastDelivered = (path, now)
        pendingWorkspacePath = path
        wsLog("投递 → 置 pendingWorkspacePath + 发通知：\(path)")
        NotificationCenter.default.post(name: .openWorkspaceRequested, object: path)
    }

    private static var lastDelivered: (path: String, at: Date)?

    /// 取出并清空冷启动缓冲的工作区路径（只消费一次，避免多窗口重复切换）。
    static func consumePendingWorkspace() -> String? {
        defer { pendingWorkspacePath = nil }
        return pendingWorkspacePath
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        guard let bundleId = Bundle.main.bundleIdentifier else { return }
        let me = NSRunningApplication.current
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId)
            .filter { $0.processIdentifier != me.processIdentifier && !$0.isTerminated }
        wsLog("willFinishLaunching：单实例守卫将终止 \(others.count) 个旧实例")
        for other in others { other.terminate() }   // 优雅退出：旧实例走正常关窗流程（存进度）并释放端口
    }

    /// 首个窗口该显示什么，要等到这里才能决定 —— 见 `ContentView.decideInitialContent`。
    /// AppKit 保证「双击文档启动」的 open 事件在本回调**之前**投递，故此刻 `pendingWorkspacePath`
    /// 必然已经就位（若确实是双击启动）。
    func applicationDidFinishLaunching(_ notification: Notification) {
        wsLog("didFinishLaunching：pendingWorkspacePath=\(Self.pendingWorkspacePath ?? "nil")")
        Self.didFinishLaunching = true
        NotificationCenter.default.post(name: .appDidFinishLaunching, object: nil)
    }

    /// 是否已过 `applicationDidFinishLaunching`（= 冷启动的 open 事件窗口已关闭）。
    static var didFinishLaunching = false

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Self.isTerminating = true
        return .terminateNow
    }

    /// 「重新打开」= 点 Dock 图标激活。有可见窗口时返回 false，没有时返回 true（让系统开一个）。
    /// ⚠️ 实测（2026-07-29）**这个回调根本没被调用**——SwiftUI 的 App 生命周期自己处理了重新打开，
    /// 不转发给 delegate。所以「app 激活时凭空多出一个空窗口」不是它造成的，别再往这儿查；
    /// 真正的兜底是 `RootView` body 里的 `isStrayWindow`（必须在 body 求值时判定，不能等 onAppear，
    /// 理由见那里）。保留本方法纯属防御。
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        !flag
    }

    /// Dock 图标右键菜单：最近打开的工作区。
    /// ⚠️ 这个方法**只在 app 运行时**被调用；app 未运行时 Dock 右键显示的是系统维护的
    /// 「最近使用的文稿」——那一份由 `NSDocumentController.noteNewRecentDocumentURL` 喂
    /// （见 `WorkspaceRegistry.rememberRecent`），点击后走 `application(_:open:)`。两者互补，
    /// 各管一半场景，所以两边都要接。
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let recents = WorkspaceRegistry.shared.recents
        guard !recents.isEmpty else { return nil }
        let menu = NSMenu()
        menu.addItem(.sectionHeader(title: L("Recent Workspaces")))
        for url in recents {
            let item = NSMenuItem(title: WorkspaceManager.defaultWorkspaceName(for: url),
                                  action: #selector(openWorkspaceFromDock(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = url.path
            item.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
            menu.addItem(item)
        }
        return menu
    }

    /// Dock 菜单点击 → 走与「双击 .unrd」完全相同的投递链路（已有窗口则激活，否则开新窗口）。
    @objc private func openWorkspaceFromDock(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        wsLog("Dock 菜单：打开最近工作区 \(path)")
        Self.deliverWorkspace(path)
    }
}

/// 一个窗口要显示什么：哪个工作区（nil = 由 `RootView` 现场决定，见那里）+ 可选的初始文档。
/// 作为 `WindowGroup` 的 value 传递，这样每个窗口都自带工作区归属，多工作区才能真正并存。
struct WindowTarget: Codable, Hashable {
    var workspacePath: String?
    var docId: String?
}

/// 「文件 → 最近打开」子菜单（列最近工作区 + 末尾清空，同 macOS `Open Recent` 与 Obsidian 的排法）。
///
/// 抽成独立 `View` 是必需的：`.commands { }` 的内容不在窗口的视图层级里，得由它**自己**持有
/// `@ObservedObject` 才能在 `recents` 变化后重建菜单项；把 `registry.recents` 直接写进
/// `commands` 闭包只会在启动那一刻求值一次，之后打开新工作区菜单也不更新。
///
/// 点击走 `AppDelegate.deliverWorkspace`——与 Dock 右键菜单、双击 `.unrd` 完全同一条投递链路
/// （已有窗口则激活，否则开新窗口），菜单栏是 App 级的，不该经由某个窗口的回调。
private struct OpenRecentMenu: View {
    @ObservedObject private var registry = WorkspaceRegistry.shared

    var body: some View {
        Menu(L("Open Recent")) {
            ForEach(registry.recents, id: \.self) { url in
                Button {
                    AppDelegate.deliverWorkspace(url.path)
                } label: {
                    Label(WorkspaceManager.defaultWorkspaceName(for: url), systemImage: "folder")
                }
            }
            if !registry.recents.isEmpty { Divider() }
            // 空列表时不隐藏而是灰掉：菜单能展开、用户看得见"确实空了"，与系统 Clear Menu 一致。
            Button(L("Clear Recent")) { registry.clearRecents() }
                .disabled(registry.recents.isEmpty)
        }
    }
}

@main
struct UniReaderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var app = AppModel()

    var body: some Scene {
        // 主窗口组：⌘N 开新窗口；带 value 时 = 在指定工作区（可选指定文档）开一个窗口。
        // ⚠️ 工作区**不再**是 App 级单例——每个窗口经 RootView 从 WorkspaceRegistry 领一个实例
        // （同路径共享，见 WorkspaceRegistry 注释）。以前共用一个 manager，双击另一个 .unrd
        // 会把所有窗口一起换掉。
        // ⚠️ **app 每次被激活，SwiftUI 都会凭空开一个 value 为 nil 的窗口**（双击 .unrd 必然激活
        // app，于是一次双击变两个窗口）。2026-07-29 逐一排除：不是 `applicationShouldHandleReopen`
        // （压根没被调用，SwiftUI 自己处理了重新打开）、不是 `NSDocumentController`
        // （`applicationShouldOpenUntitledFile` 也没被调用）、去掉 `defaultValue` 同样拦不住。
        // 唯一可靠的处理是在 `RootView` 的 body 里认出这种窗口并关掉它（`isStrayWindow`，
        // 必须在 body 求值时判定——等到 onAppear 窗口已上屏，关掉就是用户看到的「闪一下」）。
        // 不给 `defaultValue` 只是顺带简化：这样 target 天然是 optional，"没人指定工作区"表达得更直白。
        WindowGroup(for: WindowTarget.self) { $target in
            RootView(target: target)
                .environmentObject(app)
        }
        // 关掉系统的窗口状态恢复：本 app 自己就管着「上次开了哪些文档」（每个工作区的打开集 →
        // restoreSession），系统再恢复一遍是重复的。
        // ⚠️ 注意这**不是**多余空窗口的解药：实测那些窗口 `isRestorable=false`、identifier 形如
        // `SwiftUI.PresentedWindowContent<…>-AppWindow-N`，是 SwiftUI 自己开的，与状态恢复无关。
        .restorationBehavior(.disabled)

        // 标准设置窗口（⌘,）：夜间模式自动化 / 平板滚动跟随算法 / 平板服务自启。
        Settings {
            SettingsView()
                .environmentObject(app)
        }
        .commands {
            // 接管整个「新建」组：系统默认的 ⌘N 开出来的窗口不带工作区（value 为 nil），
            // 会去开「上次使用的工作区」而不是当前这个，也让下面 RootView 的自毁兜底没法区分
            // 「用户主动 ⌘N」和「系统凭空塞的空窗口」。自己发通知给 key 窗口，由它带着**本窗口的**
            // 工作区去开新窗口。
            CommandGroup(replacing: .newItem) {
                Button(L("New Window")) {
                    NotificationCenter.default.post(name: .newWindowRequested, object: nil)
                }
                .keyboardShortcut("n", modifiers: .command)
                Button(L("Open PDF…")) {
                    NotificationCenter.default.post(name: .openPDFRequested, object: nil)
                }
                .keyboardShortcut("o", modifiers: .command)
                Divider()
                OpenRecentMenu()
            }
            // 阅读区缩放（由 key 窗口的 PageStreamView 响应）。
            CommandGroup(after: .sidebar) {
                Divider()
                Button(L("Zoom In")) {
                    NotificationCenter.default.post(name: .readerZoomIn, object: nil)
                }
                .keyboardShortcut("=", modifiers: .command)
                Button(L("Zoom Out")) {
                    NotificationCenter.default.post(name: .readerZoomOut, object: nil)
                }
                .keyboardShortcut("-", modifiers: .command)
                Button(L("Zoom to Fit Width")) {
                    NotificationCenter.default.post(name: .readerZoomFit, object: nil)
                }
                .keyboardShortcut("0", modifiers: .command)
                Divider()
            }
            // ⌘F 查找（由 key 窗口的 ContentView 响应，弹查找栏；同一套 notification 路由已被
            // 缩放命令验证可靠，见上）。
            CommandGroup(after: .textEditing) {
                Divider()
                Button(L("Find…")) {
                    NotificationCenter.default.post(name: .readerFind, object: nil)
                }
                .keyboardShortcut("f", modifiers: .command)
            }
            // Edit 菜单剪切板组整体接管（replacing: .pasteboard）：阅读区是纯 SwiftUI 不在响应链上，
            // 系统 Copy/Select All 永远灰色。重建 5 项——文本框焦点（查找/笔记编辑器）时转发响应链，
            // 否则发通知路由到 key 窗口阅读区（PageStreamView 接收，与缩放命令同款）。
            // 只读 PDF 不支持 Cut/Paste/Delete 改文档，它们只服务文本框。
            CommandGroup(replacing: .pasteboard) {
                Button(L("Cut")) { NSApp.sendAction(#selector(NSText.cut(_:)), to: nil, from: nil) }
                    .keyboardShortcut("x")
                Button(L("Copy")) {
                    if NSApp.keyWindow?.firstResponder is NSText {
                        NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil)
                    } else {
                        NotificationCenter.default.post(name: .readerCopy, object: nil)
                    }
                }
                .keyboardShortcut("c")
                Button(L("Paste")) { NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil) }
                    .keyboardShortcut("v")
                Button(L("Delete")) { NSApp.sendAction(#selector(NSText.delete(_:)), to: nil, from: nil) }
                Button(L("Select All")) {
                    if NSApp.keyWindow?.firstResponder is NSText {
                        NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
                    } else {
                        NotificationCenter.default.post(name: .readerSelectAll, object: nil)
                    }
                }
                .keyboardShortcut("a")
            }
            // 笔架/模式快捷键（设备级全局状态，直接调 AppModel——与画布笔架、平板环形盘
            // 同一套 apply 路径，广播到平板的分支天然生效）。
            CommandGroup(after: .sidebar) {
                Divider()
                Button(String(format: L("Pen Slot %d"), 1)) { if app.pens.count > 0 { app.applyPenSelection(index: 0) } }
                    .keyboardShortcut("1", modifiers: .option)
                Button(String(format: L("Pen Slot %d"), 2)) { if app.pens.count > 1 { app.applyPenSelection(index: 1) } }
                    .keyboardShortcut("2", modifiers: .option)
                Button(String(format: L("Pen Slot %d"), 3)) { if app.pens.count > 2 { app.applyPenSelection(index: 2) } }
                    .keyboardShortcut("3", modifiers: .option)
                Button(String(format: L("Pen Slot %d"), 4)) { if app.pens.count > 3 { app.applyPenSelection(index: 3) } }
                    .keyboardShortcut("4", modifiers: .option)
                Button(L("Eraser")) { app.setPadMode("erase") }
                    .keyboardShortcut("e", modifiers: .option)
                Button(L("Page Turn")) { app.setPadMode("page") }
                    .keyboardShortcut("v", modifiers: .option)
                Button(L("Write")) { app.setPadMode("note") }
                    .keyboardShortcut("b", modifiers: .option)
                Divider()
                Button(L("Night Mode")) {
                    NotificationCenter.default.post(name: .toggleNightMode, object: nil)
                }
                .keyboardShortcut("n", modifiers: [.command, .option])
            }
        }
    }
}

extension Notification.Name {
    static let openPDFRequested = Notification.Name("com.xvan.UniReader.openPDFRequested")
    static let openWorkspaceRequested = Notification.Name("com.xvan.UniReader.openWorkspaceRequested")
    static let appDidFinishLaunching = Notification.Name("com.xvan.UniReader.appDidFinishLaunching")
    static let newWindowRequested = Notification.Name("com.xvan.UniReader.newWindowRequested")
    static let readerFind = Notification.Name("com.xvan.UniReader.readerFind")
    static let toggleNightMode = Notification.Name("com.xvan.UniReader.toggleNightMode")
}
