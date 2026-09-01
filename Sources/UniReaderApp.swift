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

/// 平板链路的耗时日志（`[PAD]` 前缀）：页图渲染 + **每收一笔的主线程账**（对账/落库/广播）。
/// 开关口径同 [wsLog]——**文件在不在就是开关**：
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
    /// 以下两个由 [gate] 保护：调用方不止一条线程（`LANServer` 服务 queue 的页图账 +
    /// 主线程的收笔对账账），裸静态变量在这里就是数据竞争。
    private static var checkedAt: CFAbsoluteTime = 0
    private static var isOn = false
    private static let gate = NSLock()

    /// 每张页图 / 每次收笔都会问一遍，故探盘节流到 1s 一次（开关是给人用的，秒级生效足够）。
    private static var enabled: Bool {
        gate.lock(); defer { gate.unlock() }
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

/// 阅读区**每帧成本**探针（`[ZOOM]` 前缀）。开关口径同上两支——**文件在不在就是开关**：
/// ```
/// touch ~/Library/Logs/UniReader-zoom.log    # 开启
/// rm    ~/Library/Logs/UniReader-zoom.log    # 关闭
/// ```
/// 为什么要有它（2026-08-28 的教训）：缩放卡顿排查连着两轮靠 spike 外推方案、真机不灵——
/// spike 能量准"一个 Canvas 画多久"，量不准"SwiftUI 每帧到底重绘了哪几层、几次"。这支探针
/// 直接在真机上数：**每帧画了哪些页的墨迹、各多少笔、快速态有没有生效、各花多少毫秒**。
///
/// 高频路径（每帧、每次 Canvas 绘制）故：关着时只剩一次「每秒最多一遍」的 `fileExists`；
/// 开着时也不每次都写盘，按 250ms 窗口**聚合成一行**（逐次写盘的 I/O 会把被测对象本身拖慢）。
enum ZoomProbe {
    static let url = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Logs/UniReader-zoom.log")

    private static let queue = DispatchQueue(label: "com.xvan.UniReader.zoomprobe", qos: .utility)
    private static var handle: FileHandle?
    private static var checkedAt: CFAbsoluteTime = 0
    private static var isOn = false

    // 聚合窗口（只在主线程碰：帧与 Canvas 绘制都在主线程）
    private static var windowStart: CFAbsoluteTime = 0
    private static var frames = 0
    private static var draws = 0, fastDraws = 0
    private static var drawMs = 0.0
    private static var strokeCount = 0
    private static var pages: [Int: Int] = [:]      // 页号 → 本窗口内被重绘次数
    private static var realizedDesc = ""
    /// 本窗口内**最长的一次帧间隔**。平均帧率高不代表不卡——一帧卡 100ms 用户就明显感到一顿，
    /// 而它会被平均数吃掉（220ms 的按钮缩放动画里混一个长帧，均值仍是 200fps）。
    private static var maxGapMs = 0.0
    private static var lastFrameAt: CFAbsoluteTime = 0
    /// 最近一次 `mark`（缩放开始/settle）的时刻：用来量**首帧延迟**——"点下按钮到画面开始动"
    /// 这段空白是掉帧统计看不见的，但用户看得见。
    private static var markAt: CFAbsoluteTime = 0
    private static var framesSinceMark = 0
    /// 阻塞式重活的自计时（`settleRender` 等）：`名字 → 累计 ms`。
    private static var blocking: [String: Double] = [:]

    static var enabled: Bool {
        let now = CFAbsoluteTimeGetCurrent()
        if now - checkedAt > 1 {
            checkedAt = now
            let on = FileManager.default.fileExists(atPath: url.path)
            if on != isOn { isOn = on; queue.async { handle = nil } }
        }
        return isOn
    }

    /// 一次 contentBody 求值（= SwiftUI 认为阅读区内容要重算一次）。
    static func frame(realized: ClosedRange<Int>) {
        guard enabled else { return }
        let now = CFAbsoluteTimeGetCurrent()
        // 首帧延迟：mark（缩放开始）到画面真正动起来这段。用户感知的"点下去顿一下"就藏在这里。
        if markAt > 0 {
            write(String(format: "   ↳ 首帧延迟 %.0fms（mark 到第一帧）", (now - markAt) * 1000))
            markAt = 0
        }
        if lastFrameAt > 0 {
            let gap = (now - lastFrameAt) * 1000
            if gap < 400 {
                maxGapMs = max(maxGapMs, gap)   // >400ms 视为"没在动"，不是掉帧
                // 长帧单独记一行：均值会把它吃掉，但它才是用户看见的那一顿。
                if gap > 50 {
                    write(String(format: "   ⚠️ 长帧 %.0fms（本轮第 %d 帧，实化 %@）",
                                 gap, framesSinceMark + 1, realizedDesc as NSString))
                }
            }
        }
        lastFrameAt = now
        frames += 1
        framesSinceMark += 1
        realizedDesc = "\(realized.lowerBound)…\(realized.upperBound)(\(realized.count)页)"
        flushIfDue()
    }

    /// 主线程上的一段阻塞重活（`settleRender` 之类）。累计进当前窗口，flush 时一起报。
    static func blockingWork(_ name: String, ms: Double) {
        guard enabled else { return }
        blocking[name, default: 0] += ms
    }

    /// 给调用方包一段活并计时（关闭时零开销：直接执行）。
    static func measure<T>(_ name: String, _ work: () -> T) -> T {
        guard enabled else { return work() }
        let t0 = CFAbsoluteTimeGetCurrent()
        defer { blockingWork(name, ms: (CFAbsoluteTimeGetCurrent() - t0) * 1000) }
        return work()
    }

    /// 一次墨迹 Canvas 绘制。
    static func inkDraw(page: Int, strokes: Int, fast: Bool, ms: Double) {
        guard enabled else { return }
        draws += 1
        if fast { fastDraws += 1 }
        drawMs += ms
        strokeCount += strokes
        pages[page, default: 0] += 1
        flushIfDue()
    }

    /// 时间线标记（缩放开始 / settle 收尾等）。立即输出，且先把当前窗口结清。
    static func mark(_ msg: @autoclosure () -> String) {
        guard enabled else { return }
        flush(force: true)
        write("── \(msg())")
        markAt = CFAbsoluteTimeGetCurrent()
        framesSinceMark = 0
    }

    private static func flushIfDue() {
        let now = CFAbsoluteTimeGetCurrent()
        if windowStart == 0 { windowStart = now; return }
        if now - windowStart >= 0.25 { flush(force: true) }
    }

    private static func flush(force: Bool) {
        let now = CFAbsoluteTimeGetCurrent()
        guard force, windowStart > 0, frames > 0 || draws > 0 else {
            if windowStart == 0 { windowStart = now }
            return
        }
        let span = max(0.0001, now - windowStart)
        let fps = Double(frames) / span
        let perFrame = frames > 0 ? drawMs / Double(frames) : 0
        let top = pages.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .prefix(6).map { "p\($0.key)×\($0.value)" }.joined(separator: " ")
        let block = blocking.sorted { $0.value > $1.value }
            .map { String(format: "%@ %.0fms", $0.key, $0.value) }.joined(separator: " ")
        write(String(format: "%.0fms 窗口: 帧 %d (%.0f fps)  最长帧 %.0fms  墨迹绘制 %d 次(快速 %d) 共 %.0fms = %.1fms/帧  笔画合计 %d  实化 %@  重绘页 %@%@",
                     span * 1000, frames, fps, maxGapMs, draws, fastDraws, drawMs, perFrame,
                     strokeCount, realizedDesc as NSString, top.isEmpty ? "—" : top,
                     block.isEmpty ? "" : "  ⏱ \(block)"))
        windowStart = now
        frames = 0; draws = 0; fastDraws = 0; drawMs = 0; strokeCount = 0; maxGapMs = 0
        pages.removeAll(keepingCapacity: true); blocking.removeAll(keepingCapacity: true)
    }

    private static func write(_ msg: String) {
        let line = "\(Date.now.formatted(date: .omitted, time: .standard)) [ZOOM] \(msg)\n"
        queue.async {
            if handle == nil {
                handle = try? FileHandle(forWritingTo: url)
                _ = try? handle?.seekToEnd()
            }
            guard let h = handle, let d = line.data(using: .utf8) else { return }
            try? h.write(contentsOf: d)
        }
    }
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
        observeVolumes()
    }

    // MARK: - 硬盘弹出 / 插回

    /// 盯着卷的挂载与卸载。
    ///
    /// 🔴 **必须注册在 `NSWorkspace.shared.notificationCenter` 上**，不是默认中心
    /// ——AppKit 头文件原话：「All notifications in this header file must be registered on
    /// this notification center. If you register on other notification centers, you will not
    /// receive the notifications.」注册错地方是**静默收不到**，不报错。
    ///
    /// 三条都要接，各管一段：
    /// - `willUnmount`：用户按了弹出、系统真正卸载**之前**。这是唯一能让弹盘成功的窗口期
    ///   ——在这一下里把 fd 放掉，Finder 才不会报「磁盘正在使用中」。
    /// - `didUnmount`：已经卸载了。**硬拔**（不点弹出直接拔线）只会走这条，所以它不是冗余，
    ///   是另一半场景；重复执行是安全的（`evacuate` 幂等）。
    /// - `didMount`：盘插回来了 —— 让还开着的窗口重算一次提示条（不然得等用户切窗口才发现）。
    private func observeVolumes() {
        let nc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willUnmountNotification, NSWorkspace.didUnmountNotification] {
            nc.addObserver(forName: name, object: nil, queue: .main) { note in
                MainActor.assumeIsolated { Self.handleUnmount(note) }
            }
        }
        nc.addObserver(forName: NSWorkspace.didMountNotification, object: nil, queue: .main) { _ in
            // 提示条自己会在后台跑干跑；这里只是给个「该重算了」的信号
            NotificationCenter.default.post(name: .volumeDidMount, object: nil)
        }
    }

    /// 盘要走了：开着它上面工作区的窗口不能死卡在那儿。
    /// **有离线副本就切过去，没有就把那扇窗关掉。**
    ///
    /// 次序有讲究：**先把副本的窗口开出来，再关旧的**。副本走
    /// `deliverWorkspace` → 通知 → key 窗口的 `ContentView` 路由，而屏幕上一个
    /// `ContentView` 都没有时那个请求会被静默丢弃（2026-07-29 实测过的老账）——
    /// 先关旧窗就可能把唯一的订阅者关掉。
    @MainActor
    private static func handleUnmount(_ note: Notification) {
        guard let vol = note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL else { return }
        let registry = WorkspaceRegistry.shared
        let affected = registry.openWorkspaces(onVolume: vol)
        guard !affected.isEmpty else { return }
        wsLog("卷 \(vol.lastPathComponent) 要卸载，受影响的工作区：\(affected.count) 个")
        for folder in affected {
            if let mirror = registry.mirrorPath(forSource: folder, id: nil) {
                wsLog("→ 切到离线副本 \((mirror as NSString).lastPathComponent)")
                deliverWorkspace(mirror)
            } else {
                wsLog("→ 没有离线副本，关掉这扇窗")
            }
            registry.evacuate(folder)
        }
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
        for r in recents {
            let item = NSMenuItem(title: r.name,
                                  action: #selector(openWorkspaceFromDock(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = WorkspaceRegistry.resolveOrSource(r).path
            let offline = WorkspaceRegistry.opensOffline(r)
            item.image = NSImage(systemSymbolName: offline ? "externaldrive.badge.timemachine" : "folder",
                                 accessibilityDescription: nil)
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
            ForEach(registry.recents) { r in
                Button {
                    AppDelegate.deliverWorkspace(WorkspaceRegistry.resolveOrSource(r).path)
                } label: {
                    Label(r.name, systemImage: WorkspaceRegistry.opensOffline(r)
                          ? "externaldrive.badge.timemachine" : "folder")
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

        // AI 面板：**全局唯一浮窗**（不是每个阅读窗口一个）。⌘⇧A 打开，见 `AIPanelMenu`。
        // 用 `Window` 而不是 `WindowGroup` 就是要这个「只有一个」的语义——每家平台一个 WebPage
        // 已经够用，还顺带绕开「一个 WKWebView 不能同时挂两个视图」。
        // 状态恢复同样关掉：面板开不开由用户当次决定，系统替我们记反而碍事。
        Window(L("AI"), id: AIPanelModel.windowID) {
            AIPanelView()
        }
        .defaultSize(width: 480, height: 760)
        .defaultPosition(.trailing)
        // 紧凑工具栏（系统标准样式，不是自己压高度）：默认的 expanded 样式在 Tahoe 上又高又占地方，
        // 一个聊天浮窗不该拿两行去放标题。`showsTitle: false` 连标题行一起省掉——当前是哪家平台，
        // 工具栏中间那枚平台菜单自己就写着。
        .windowToolbarStyle(.unifiedCompact(showsTitle: false))
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
                Button(L("New Tab")) {
                    NotificationCenter.default.post(name: .newTabRequested, object: nil)
                }
                .keyboardShortcut("t", modifiers: .command)
                Divider()
                OpenRecentMenu()
            }
            // 标签页（`MAC-TABS-PLAN.md`）。⌘W 关的是**当前标签**，只剩一个标签时才关窗口
            // （同 Safari / Xcode）；⇧⌘W 直接关窗口。
            // ⚠️ 真机待验：AppKit 自带的「文件 › 关闭」也占着 ⌘W，两者谁拿到快捷键要看菜单顺序。
            // 若真机上 ⌘W 关掉的是整扇窗，改用一个 keyDown 本地监视器抢在菜单等价键之前处理。
            CommandGroup(after: .saveItem) {
                Divider()
                Button(L("Close Tab")) {
                    NotificationCenter.default.post(name: .closeTabRequested, object: nil)
                }
                .keyboardShortcut("w", modifiers: .command)
                Button(L("Close Window")) {
                    NotificationCenter.default.post(name: .closeWindowRequested, object: nil)
                }
                .keyboardShortcut("w", modifiers: [.command, .shift])
                Button(L("Next Tab")) {
                    NotificationCenter.default.post(name: .nextTabRequested, object: nil)
                }
                .keyboardShortcut(.tab, modifiers: .control)
                Button(L("Previous Tab")) {
                    NotificationCenter.default.post(name: .prevTabRequested, object: nil)
                }
                .keyboardShortcut(.tab, modifiers: [.control, .shift])
            }
            // 阅读区缩放（由 key 窗口的 PageStreamView 响应）。
            CommandGroup(after: .sidebar) {
                Divider()
                Button(L("Toggle Sidebar")) {
                    NotificationCenter.default.post(name: .toggleSidebar, object: nil)
                }
                .keyboardShortcut("b", modifiers: .command)
                Button(L("Toggle Inspector")) {
                    NotificationCenter.default.post(name: .toggleInspector, object: nil)
                }
                .keyboardShortcut("i", modifiers: .command)
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
                    // ⚠️ **先试响应链，没人接才回落到阅读区**（2026-08-26 改）。
                    // 原先的判据是 `firstResponder is NSText`，AI 面板里第一响应者是 WKWebView
                    // ——既不是 NSText，也没有哪个 ContentView 是 key 窗口，于是 ⌘C **一声不响什么都不做**。
                    // `sendAction` 的返回值就是「有没有响应者接住」：webview / 文本框都会接，
                    // 纯 SwiftUI 的阅读区不在响应链上必然返回 false，正好当分流开关。
                    if !NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil) {
                        NotificationCenter.default.post(name: .readerCopy, object: nil)
                    }
                }
                .keyboardShortcut("c")
                Button(L("Paste")) { NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil) }
                    .keyboardShortcut("v")
                Button(L("Delete")) { NSApp.sendAction(#selector(NSText.delete(_:)), to: nil, from: nil) }
                Button(L("Select All")) {
                    if !NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil) {
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
                Button(L("Canvas Mode")) {
                    NotificationCenter.default.post(name: .toggleCanvasMode, object: nil)
                }
                .keyboardShortcut("c", modifiers: [.command, .option])
            }
            // AI 菜单。⌥S 与阅读区的单键工具约定（e/1~9/n/b/v/l）同一族，只是菜单项要带修饰键。
            CommandMenu(L("AI")) {
                AIPanelMenu()
                Divider()
                Button(L("Snip to AI")) {
                    NotificationCenter.default.post(name: .toggleSnipTool, object: nil)
                }
                .keyboardShortcut("s", modifiers: .option)
            }
        }
    }
}

extension Notification.Name {
    static let openPDFRequested = Notification.Name("com.xvan.UniReader.openPDFRequested")
    static let openWorkspaceRequested = Notification.Name("com.xvan.UniReader.openWorkspaceRequested")
    /// 有卷挂上了 —— 可能就是那块源盘插回来了，提示条该重算一次
    static let volumeDidMount = Notification.Name("com.xvan.UniReader.volumeDidMount")
    static let appDidFinishLaunching = Notification.Name("com.xvan.UniReader.appDidFinishLaunching")
    static let newWindowRequested = Notification.Name("com.xvan.UniReader.newWindowRequested")
    static let newTabRequested = Notification.Name("com.xvan.UniReader.newTabRequested")
    static let closeTabRequested = Notification.Name("com.xvan.UniReader.closeTabRequested")
    static let closeWindowRequested = Notification.Name("com.xvan.UniReader.closeWindowRequested")
    static let nextTabRequested = Notification.Name("com.xvan.UniReader.nextTabRequested")
    static let prevTabRequested = Notification.Name("com.xvan.UniReader.prevTabRequested")
    static let readerFind = Notification.Name("com.xvan.UniReader.readerFind")
    static let toggleNightMode = Notification.Name("com.xvan.UniReader.toggleNightMode")
    static let toggleCanvasMode = Notification.Name("com.xvan.UniReader.toggleCanvasMode")
    static let toggleSidebar = Notification.Name("com.xvan.UniReader.toggleSidebar")
    static let toggleInspector = Notification.Name("com.xvan.UniReader.toggleInspector")
    static let toggleSnipTool = Notification.Name("com.xvan.UniReader.toggleSnipTool")
}
