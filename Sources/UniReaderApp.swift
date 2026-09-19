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

/// 启动分段计时，写 [wsLog] 那条通道（`touch ~/Library/Logs/UniReader-ws.log` 开）。
///
/// 冷启动「卡一下、第二次就不卡」的排查全指望它：先分清慢在**我们自己的主线程 IO**
/// （开库/读书库/加载 PDF——工作区常在移动硬盘上，首次没有 page cache）还是 **exec 之前**
/// （Gatekeeper 首次扫描新构建的二进制、dyld 冷绑定，与代码无关）。
/// 后者的判据：下面这些分段加起来很短，而人感觉卡了好几秒。
@discardableResult
func wsTime<T>(_ tag: String, _ body: () throws -> T) rethrows -> T {
    let t0 = CFAbsoluteTimeGetCurrent()
    defer { wsLog(String(format: "耗时 %@ %.0fms", tag, (CFAbsoluteTimeGetCurrent() - t0) * 1000)) }
    return try body()
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
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// 全局取用点（菜单动作、`ReaderPane` 里的「在新窗口打开」都要开窗）。
    /// 迁移前这些事走 SwiftUI 的 `openWindow` environment action，只有视图够得着；
    /// 现在窗口是我们建的，直接找 delegate 即可。
    static private(set) var shared: AppDelegate?

    /// App 级单例。迁移前是 `UniReaderApp` 的 `@StateObject`，现在归 delegate 持有，
    /// 由各窗口 `.environmentObject(app)` 注入 SwiftUI 内容树。
    let appModel = AppModel()

    /// 开着的阅读窗。**强引用在这里**——`NSWindowController` 不像 SwiftUI Scene 有人替我们管，
    /// 没人持有就会当场释放、窗口跟着消失。
    private var readerWindows: [ReaderWindowController] = []

    /// 只读视图，给 MCP 的 `get_state` / `open_document` 枚举窗口用（`MCPFacade`）。
    var readerWindowControllers: [ReaderWindowController] { readerWindows }

    /// 是否正在退出（cmd+q / 被单实例守卫接管）。用于区分「退出关窗」vs「cmd+w 单独关窗」：
    /// 退出时**不修改**工作区「打开集」（下次启动原样恢复所有窗口）；cmd+w 才逐个移除。
    /// `applicationShouldTerminate` 在各窗口 `onDisappear` **之前**触发，故此标志对关窗回调可见。
    static var isTerminating = false

    /// 冷启动时被双击/拖入的 .unrd 路径（视图树尚未就绪、通知无人接收时兜底）。
    /// 由 `RootView.resolve` 消费——冷启动时**不能**在 onAppear 那一刻消费（那时事件还没投递到，
    /// 见 `RootView` 里的时序说明），得等 `didFinishLaunching` 那一轮。
    static var pendingWorkspacePath: String?

    /// 冷启动时被 `unireader://` 链接拉起的那一下（同 `pendingWorkspacePath` 的理由：此刻窗口不该建，
    /// 连「链接写坏了」的弹框也得等到有窗口再弹）。存**原始 URL**、不存解析结果，解析放到消费那一刻。
    /// 由 `applicationDidFinishLaunching` 消费，**优先级低于** `.unrd` 双击——两者同时到（几乎不可能）以文件为准。
    static var pendingDeepLinkURL: URL?

    /// Finder 双击 / 拖到 Dock 图标的 .unrd 工作区包（**现代入口**），以及 `unireader://open?…` 链接
    /// （Obsidian 笔记 / Agent 写的清单 / 终端 `open` 都从这里进，见 `DeepLink`）。
    /// AppKit 只要 delegate 实现了这个方法就一律走它，下面那个 `openFile:` 版本便再也不会被调用
    /// （`openFile:`/`openFiles:` 都是 deprecated 的旧签名）。两个都留着并各自打点，日志即可判明
    /// 系统实际投递到了哪一条。
    func application(_ application: NSApplication, open urls: [URL]) {
        wsLog("application(open:) urls=\(urls.map(\.absoluteString))")
        if let u = urls.first(where: { $0.isFileURL && $0.pathExtension == WorkspaceManager.packageExtension }) {
            Self.deliverWorkspace(u.path)
            return
        }
        if let u = urls.first(where: { DeepLink.isDeepLink($0) }) {
            Self.deliverDeepLink(u)
            return
        }
        wsLog("application(open:) 里既没有 .\(WorkspaceManager.packageExtension) 包也没有 \(DeepLink.scheme):// 链接，忽略")
    }

    /// `unireader://` 链接的统一投递：热启动直接路由，冷启动缓冲到 `didFinishLaunching`。
    /// 解析失败（主机不对 / 页码写坏）弹框——链接是别处写的，静默吞掉用户就只看到「点了没反应」；
    /// 冷启动下先开默认窗口再弹，不然 App 起来了却一扇窗都没有。
    static func deliverDeepLink(_ url: URL) {
        guard didFinishLaunching, let me = shared else {
            pendingDeepLinkURL = url
            wsLog("链接 → 冷启动缓冲：\(url.absoluteString)")
            return
        }
        wsLog("链接 → 路由：\(url.absoluteString)")
        do {
            DeepLinkRouter.open(try DeepLink.parse(url))
        } catch {
            wsLog("链接解析失败：\(url.absoluteString) \(error)")
            if me.readerWindows.isEmpty { me.openReaderWindow(workspacePath: nil, docId: nil) }
            DeepLinkRouter.alert(url: url, error: error)
        }
    }

    /// 同上的旧签名入口（保留兜底：万一某条路径/某个系统版本仍走它）。
    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        wsLog("application(openFile:) \(filename)")
        Self.deliverWorkspace(filename)
        return true
    }

    /// 统一投递：冷启动缓冲 + 发通知。两个入口共用，并做一次短时去重
    /// （同一路径 1s 内只投一次），免得将来两条都被调用时把工作区切两遍。
    /// 统一投递：热启动**直接开窗**，冷启动才缓冲（那时 delegate 还没走完启动，窗口不该现在建）。
    ///
    /// 🔴 迁移前这里必须「置缓冲 + 发通知」，再由某个 `RootView` 抢着认领——因为窗口是 SwiftUI 建的，
    /// app 级代码够不着 `openWindow`。那套机制附带两个踩过的坑（只剩错误态窗口时请求被静默丢弃、
    /// 冷启动 `isKeyWindow` 全为假导致谁都不认领），现在一并作废：窗口由我们直接建。
    static func deliverWorkspace(_ path: String) {
        let now = Date.now
        if let last = lastDelivered, last.path == path, now.timeIntervalSince(last.at) < 1 {
            wsLog("重复投递，忽略：\(path)")
            return
        }
        lastDelivered = (path, now)
        guard didFinishLaunching, let me = shared else {
            pendingWorkspacePath = path
            wsLog("投递 → 冷启动缓冲：\(path)")
            return
        }
        wsLog("投递 → 直接路由：\(path)")
        me.routeWorkspace(URL(fileURLWithPath: path), strict: true)
    }

    private static var lastDelivered: (path: String, at: Date)?

    /// 取出并清空冷启动缓冲的工作区路径（只消费一次，避免多窗口重复切换）。
    static func consumePendingWorkspace() -> String? {
        defer { pendingWorkspacePath = nil }
        return pendingWorkspacePath
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        Self.shared = self
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
        // 进程创建到这一刻 = dyld 加载 + 静态初始化（Gatekeeper 扫描在进程创建之前，不计在内）。
        if let launched = NSRunningApplication.current.launchDate {
            wsLog(String(format: "耗时 进程启动→didFinishLaunching %.0fms",
                         Date().timeIntervalSince(launched) * 1000))
        }
        Self.didFinishLaunching = true
        MainMenu.install(app: appModel)
        // app 级初始化（迁移前挂在 ContentView.onAppear，那是「每开一扇窗跑一遍」的将就做法）。
        // ⚠️ 缓存上限的默认值与 `SettingsView.renderCacheMB` 的 `@AppStorage` 默认**必须一致**。
        PageRenderEngine.shared.setCacheLimitMB(
            UserDefaults.standard.object(forKey: "renderCacheMB") as? Int ?? 256)
        if UserDefaults.standard.bool(forKey: "autoStartServer") { appModel.server.start() }
        // MCP 服务：工具目录装配一次；「启动时开启」照平板服务的先例。
        MCPTools.registerAll(into: appModel.mcp)
        if UserDefaults.standard.bool(forKey: MCPServer.autoStartKey) { appModel.mcp.start() }
        // Sparkle：首次访问 `.shared` 触发 controller 启动，之后整个进程生命周期里都活着；
        // 是否自动检查/检查间隔由 Sparkle 自己按 defaults 排，这里不用手动触发一次检查。
        _ = UpdaterService.shared
        observeVolumes()
        NotificationCenter.default.post(name: .appDidFinishLaunching, object: nil)
        // 首个窗口：双击 .unrd 拉起就开那个工作区；`unireader://` 链接拉起就照链接开；否则开上次用的。
        if let p = Self.consumePendingWorkspace() {
            Self.pendingDeepLinkURL = nil
            routeWorkspace(URL(fileURLWithPath: p), strict: true)
        } else if let u = Self.pendingDeepLinkURL {
            Self.pendingDeepLinkURL = nil
            Self.deliverDeepLink(u)   // 此刻 didFinishLaunching 已置真，走的是直接路由那一支
        } else {
            openReaderWindow(workspacePath: nil, docId: nil)
        }
    }

    // MARK: - 开窗

    /// 开一扇阅读窗。`workspacePath` 为 nil = 用「上次使用的工作区」（首次启动会在默认位置建库，
    /// 所以这条路径**不严格校验**——严格是给「用户指着某个具体工作区说打开它」用的）。
    @discardableResult
    func openReaderWindow(workspacePath: String?, docId: String?) -> ReaderWindowController? {
        do {
            return try makeReaderWindow(workspacePath: workspacePath, docId: docId, activate: true)
        } catch {
            let a = NSAlert()
            a.messageText = L("Cannot Open Workspace")
            a.informativeText = error.localizedDescription
            a.addButton(withTitle: L("OK"))
            a.runModal()
            return nil
        }
    }

    /// `openReaderWindow` 的 `throws` 版本：失败把错误交给调用方，不弹框。MCP 那条路（`MCPFacade`）
    /// 要把错误文本回给 Agent，而不是弹一个没人点的 `NSAlert` 把服务卡住。
    /// `activate = false` 时不抢前台（Agent 只想在后台把窗口准备好）。
    @discardableResult
    func makeReaderWindow(workspacePath: String?, docId: String?, activate: Bool) throws -> ReaderWindowController {
        let folder: URL
        let strict: Bool
        if let p = workspacePath {
            folder = URL(fileURLWithPath: p); strict = true
        } else {
            folder = WorkspaceRegistry.shared.lastOrDefaultFolder(); strict = false
        }
        do {
            if strict { try WorkspaceManager.validate(folder) }
            let ws = try wsTime("开工作区(SQLite)") { try WorkspaceRegistry.shared.acquire(folder: folder) }
            let c = wsTime("建窗(含恢复标签/开 PDF)") {
                ReaderWindowController(app: appModel, workspace: ws, launchDocId: docId)
            }
            // 第二扇起往右下错开：所有窗口共用一个 autosave frame，不错开就精确叠在一起、
            // 看着像「只开了一扇」。
            if let prev = readerWindows.last?.window, let w = c.window {
                w.setFrameTopLeftPoint(NSPoint(x: prev.frame.minX + 26, y: prev.frame.maxY - 26))
            }
            readerWindows.append(c)
            wsTime("上屏(showWindow)") { c.showWindow(nil) }
            if activate { NSApp.activate(ignoringOtherApps: true) }
            wsLog("开窗：\(folder.lastPathComponent) doc=\(docId ?? "nil")")
            return c
        } catch {
            wsLog("开窗失败：\(error.localizedDescription)")
            throw error
        }
    }

    /// 让书库里的某篇文档显示出来（MCP `open_document` 与 `unireader://` 链接**共用这一条**，
    /// 别各写一份——两边的「找标签 / 挑窗口」规则一旦分叉，Agent 开的和链接开的就会落在不同窗口）：
    ///  · 某个标签已经在显示它（任一窗口）→ 切过去，不重开；
    ///  · 该工作区有窗口 → 在 key 的那扇（没有就第一扇）里开标签（`TabsModel.open` 的语义）；
    ///  · 该工作区没有窗口 → 新开一扇只装这篇的窗口。
    /// 返回窗口与标签；`activate` 只管新开窗口那一路要不要抢前台，已有窗口由调用方自己决定。
    func showDocument(_ documentId: String, in ws: WorkspaceManager, activate: Bool) throws -> (ReaderWindowController, DocTabModel) {
        if let (c, tab) = tabShowing(documentId) {
            c.tabs.activate(tab.id)
            return (c, tab)
        }
        let mine = readerWindows.filter { $0.workspace === ws }
        if let c = mine.first(where: { $0.window?.isKeyWindow == true }) ?? mine.first {
            return (c, c.tabs.open(documentId))
        }
        let c = try makeReaderWindow(workspacePath: ws.folder?.path, docId: documentId, activate: activate)
        return (c, c.tabs.active)
    }

    /// 哪扇窗的哪个标签正显示这篇（跨所有窗口；key 窗口优先）。
    func tabShowing(_ documentId: String) -> (ReaderWindowController, DocTabModel)? {
        let key = readerWindows.first { $0.window?.isKeyWindow == true }
        for c in [key].compactMap({ $0 }) + readerWindows.filter({ $0 !== key }) {
            if let t = c.tabs.tabs.first(where: { $0.docID == documentId }) { return (c, t) }
        }
        return nil
    }

    /// 双击 `.unrd` / Dock 菜单 / 侧栏入口共用的路由：校验 → 已有窗口就激活 → 否则开新窗口。
    func routeWorkspace(_ url: URL, strict: Bool) {
        do { try WorkspaceRegistry.shared.route(to: url, strict: strict) }
        catch {
            let a = NSAlert()
            a.messageText = L("Workspace Error")
            a.informativeText = error.localizedDescription
            a.addButton(withTitle: L("OK"))
            a.runModal()
        }
    }

    /// 窗口关掉了，放掉对 controller 的强引用。
    func forget(_ controller: ReaderWindowController) {
        readerWindows.removeAll { $0 === controller }
    }

    /// 关掉全部窗口不退出 app（macOS 惯例；也与迁移前 SwiftUI 的行为一致）。
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

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
                // 盘走了 → 还开着的**副本**窗口也得知道（它自己不在这个卷上，`handleUnmount`
                // 管不着它，见那个方法：它只处理"开在这个卷上的工作区"）。
                // 🔴 **两段分开发，不能合成一条**：`willUnmount` 那段只许撤提示条、一次 I/O 都不做
                //（此刻正是弹出的窗口期，多开一个 fd 就是 Finder 那句「磁盘正在使用中」），
                // 真正的重算只在 `didUnmount` 之后跑。
                let n: Notification.Name = name == NSWorkspace.willUnmountNotification
                    ? .volumeWillUnmount : .volumeDidUnmount
                NotificationCenter.default.post(
                    name: n, object: note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL)
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
                // 这扇窗是替用户开的，不能开在别人后面（弹出是在 Finder 里点的，此刻前台是它）
                registry.requestActivation(forWorkspace: URL(fileURLWithPath: mirror))
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
        // 🔴 **退出时必须自己把每扇窗结清**：AppKit 的 `terminate:` 不关窗，
        // `windowWillClose` 一扇都不发（详见 `ReaderWindowController.shutdown()` 的红线）。
        // 迁移前这条是 SwiftUI `onDisappear` 兜的，改 AppKit 窗口后断了 → ⌘Q 丢进度。
        // 在这里而不是 `applicationWillTerminate`：那条通知发出时 runloop 已在收尾，
        // 而结清里有写库，越早越稳；此刻 `isTerminating` 已置位，「打开集」照旧原样保留。
        let windows = readerWindows          // 结清里会 `forget(self)` 改这个数组，先取一份快照
        for c in windows { c.shutdown() }
        // Agent 子进程（`kimi acp` 等）连进程组同步杀掉，别留孤儿进程
        AgentPanelModel.shared.teardownAll()
        // 进度/打开集这类小写在后台队列里排着（`WorkspaceManager.bookkeeping`），进程退出前同步落地。
        WorkspaceRegistry.shared.flushAllBookkeeping()
        return .terminateNow
    }

    /// 「重新打开」= 点 Dock 图标激活。没有可见窗口时开一扇。
    ///
    /// 🔴 迁移前这个回调**根本不会被调用**（SwiftUI 的 App 生命周期自己处理了重新打开、不转发给
    /// delegate），当时「app 激活凭空多出一个空窗口」正是 SwiftUI 自己开的、只能识别后关掉。
    /// 现在窗口全归我们：这里返回 false（自己开，不劳系统），凭空多窗那件事从根上不存在了。
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { openReaderWindow(workspacePath: nil, docId: nil) }
        return false
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

extension Notification.Name {
    /// 咨询 AI / Agent 的独立窗口显示、隐藏或关闭了（阅读窗口工具栏两枚开关据此刷按下态）。
    static let auxPanelVisibilityChanged = Notification.Name("com.xvan.UniReader.auxPanelVisibilityChanged")
    static let openPDFRequested = Notification.Name("com.xvan.UniReader.openPDFRequested")
    static let openWorkspaceRequested = Notification.Name("com.xvan.UniReader.openWorkspaceRequested")
    /// 有卷挂上了 —— 可能就是那块源盘插回来了，提示条该重算一次
    static let volumeDidMount = Notification.Name("com.xvan.UniReader.volumeDidMount")
    /// 某个卷**就要**卸载（点了弹出）。`object` = 卷的 URL。
    /// 收到它只许做**不碰盘**的事（撤掉指向那个卷的提示条）——此刻多开一个 fd 就是弹不出去。
    static let volumeWillUnmount = Notification.Name("com.xvan.UniReader.volumeWillUnmount")
    /// 某个卷**已经**卸载（点弹出之后 / 硬拔）。`object` = 卷的 URL。这时候才可以重算。
    static let volumeDidUnmount = Notification.Name("com.xvan.UniReader.volumeDidUnmount")
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
    /// 扫描页对齐开关（`SCAN-ALIGN-PLAN.md`），key 窗口的活动标签认领。
    static let toggleScanAlign = Notification.Name("com.xvan.UniReader.toggleScanAlign")
    static let toggleSidebar = Notification.Name("com.xvan.UniReader.toggleSidebar")
    static let toggleInspector = Notification.Name("com.xvan.UniReader.toggleInspector")
    static let toggleSnipTool = Notification.Name("com.xvan.UniReader.toggleSnipTool")
    /// 工作区菜单里那几项**要弹 SwiftUI sheet/alert** 的动作。菜单本身在 AppKit 工具栏里
    /// （`ReaderWindowController`），而 sheet 的开关是 `SidebarView` 自己的 `@State`——
    /// 用通知把这一下转过去，比把那堆状态外露给窗口层干净。
    static let workspaceRenameRequested = Notification.Name("com.xvan.UniReader.workspaceRename")
    static let workspaceMakeMirrorRequested = Notification.Name("com.xvan.UniReader.workspaceMakeMirror")
    static let workspaceDropMirrorRequested = Notification.Name("com.xvan.UniReader.workspaceDropMirror")
    static let workspaceSyncToSourceRequested = Notification.Name("com.xvan.UniReader.workspaceSyncToSource")
    /// 跳转历史：后退 / 前进 / 开关浮窗（由 key 窗口的 `ContentView` 响应）
    static let jumpBackRequested = Notification.Name("com.xvan.UniReader.jumpBackRequested")
    static let jumpForwardRequested = Notification.Name("com.xvan.UniReader.jumpForwardRequested")
    static let toggleJumpHistory = Notification.Name("com.xvan.UniReader.toggleJumpHistory")
    /// 书签：在当前阅读位置加一枚（⌘D，由 key 窗口的 `ReaderPane` 响应）
    static let addBookmarkRequested = Notification.Name("com.xvan.UniReader.addBookmarkRequested")
    /// 参考窗开关（视图菜单；key 窗口认领——阅读窗开合自己那份，独立形态的参考窗是 key 时关自己）
    static let toggleRefWindow = Notification.Name("com.xvan.UniReader.toggleRefWindow")
}
