import SwiftUI
import WebKit
import AppKit

/// AI 面板浮窗的**内容**：一个原生 SwiftUI `WebView`（+ 查找条与空态）。
///
/// **全原生**：macOS 26 的 WebKit for SwiftUI（`WebView` + `WebPage`）不需要 `NSViewRepresentable`
/// 包 `WKWebView`；进度是系统 `ProgressView`，空态是 `ContentUnavailableView`——一处自绘仿系统
/// 样式都没有。
///
/// 🔴 **工具栏不在这里**：2026-09-01 窗口层迁到 AppKit 之后，浮窗由
/// `AIPanelWindowController` 建，工具栏是它的 `NSToolbar`（SwiftUI 的 `.toolbar` 只作用于
/// SwiftUI 自己创建的窗口，装进 `NSHostingController` 对 AppKit 窗口不生效）。分组排法照旧。
///
/// **高度**（2026-08-25 用户报「toolbar 太大太高」后改）：窗口用系统的
/// `.windowToolbarStyle(.unifiedCompact(showsTitle: false))`（见 `UniReaderApp`），这里**不设
/// `.navigationSubtitle`** —— 副标题会把标题区撑成两行，是第一版偏高的主因。两处都用系统 API，
/// 没有自己压高度/自绘条。
///
/// ⚠️ `body` 刻意拆成 `shell` + 两层 `background`：修饰符链全挂一个表达式会超类型检查器时限
/// （与 `ContentView` 拆 `mainSplit`/`eventRoutes`、`toolbarContent` 抽出是同一个坑）。
struct AIPanelView: View {
    @StateObject private var panel = AIPanelModel.shared

    /// 窗口置顶。用 AppKit accessor 直接设 `NSWindow.level`——scene 级的 `.windowLevel()` 是否
    /// 对已开着的窗口即时生效没把握，而「按了没反应」正是最难查的那类静默失效。
    @AppStorage("aiPanelFloating") private var floating = false

    /// 本窗口是不是 key。⌘F 走的是与阅读区同一条通知路由（App 级菜单命令 → 通知 → key 窗口认领），
    /// 所以面板也得知道自己是不是当前那一个。
    @State private var isKey = false
    @State private var findOpen = false
    @State private var findText = ""
    @FocusState private var findFocused: Bool


    /// 本视图就是 `.window` 这个宿主，它有**自己那一份** `WebPage`（见 `AIPanelModel` 的宿主说明）。
    private let host = AIHost.window
    /// 🔴 **body 里直接从模型查，不用 `@State` 缓存**（重建后 `@State` 归 nil 会闪一帧占位）；
    /// 创建只在 `onAppear`/`onChange` 里做。
    private var box: AIPageBox? { panel.existingPage(for: host) }

    var body: some View {
        shell
            .onReceive(NotificationCenter.default.publisher(for: .readerFind)) { _ in
                guard isKey else { return }     // ⌘F 是 App 级菜单命令，只有 key 窗口该响应
                findOpen = true
                findFocused = true
            }
            .onAppear {
                AIPanelDock.shared.setEnabled(panel.docked)
                panel.setActiveHost(host)
                _ = panel.page(for: host)
            }
            .onDisappear { panel.releaseHost(host) }
            .onChange(of: panel.currentID) { _, _ in _ = panel.page(for: host) }
            .background(WindowAccessor(onKeyChange: { key in
                isKey = key
                if key { panel.setActiveHost(host) }   // 前台切回浮窗 → 模型级操作作用到它这一份页面
            }, onWindow: { AIPanelDock.shared.setPanel($0) }))
            .background(WindowLevelAccessor(floating: floating))
    }

    /// 🔴 工具栏、窗口标题、「清登录数据」的确认框都搬到了 `AIPanelWindowController`：
    /// SwiftUI 的 `.toolbar` 只作用于 SwiftUI 自己创建的窗口，装进 `NSHostingController` 之后
    /// 对 AppKit 窗口不生效（2026-09-01 窗口层迁移）。这里只剩内容。
    private var shell: some View {
        content
    }

    // MARK: - 内容

    private var content: some View {
        VStack(spacing: 0) {
            contextBar
            findBar
            pageArea
        }
    }

    /// 页内查找。WebKit for SwiftUI 没给 `findNavigator`，`WKWebView.find` 又够不着（我们持有的是
    /// `WebPage`），所以走注入侧的 `window.find()`——WebKit 一直支持，够用。
    /// Enter 下一个、⇧Enter 上一个、Esc 关掉；⌘G / ⇧⌘G 同款（挂在本窗口的按钮上，不外泄成 App 级）。
    @ViewBuilder
    private var findBar: some View {
        if findOpen {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(L("Find on Page"), text: $findText)
                    .textFieldStyle(.plain)
                    .focused($findFocused)
                    .onSubmit { runFind(backwards: NSEvent.modifierFlags.contains(.shift)) }
                Button { runFind(backwards: true) } label: { Image(systemName: "chevron.up") }
                    .buttonStyle(.plain)
                    .keyboardShortcut("g", modifiers: [.command, .shift])
                    .help(L("Previous Match"))
                Button { runFind(backwards: false) } label: { Image(systemName: "chevron.down") }
                    .buttonStyle(.plain)
                    .keyboardShortcut("g", modifiers: .command)
                    .help(L("Next Match"))
                Button { closeFind() } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tertiary)
            }
            .font(.callout)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.bar)
            .onExitCommand { closeFind() }
            Divider()
        }
    }

    private func runFind(backwards: Bool) {
        guard !findText.isEmpty, let box = panel.current else { return }
        let js = "return window.find(q, false, back, true, false, true, false);"
        Task { await box.callJS(js, arguments: ["q": findText, "back": backwards]) }
    }

    private func closeFind() {
        findOpen = false
        findFocused = false
    }

    @ViewBuilder
    private var pageArea: some View {
        if panel.mode == .inline {
            // 🔴 内置模式下网页归内置面板渲染——同一个 WebPage 不能被两个 WebView 同时挂着。
            // 窗口这会儿多半正在关，画个占位是为了「关之前那一帧」不去抢那个 page。
            ContentUnavailableView(L("Shown Inside the Window"), systemImage: "sidebar.trailing",
                                   description: Text(L("The AI panel is docked inside the reading window.")))
        } else if let box {
            AIWebArea(panel: panel, box: box, host: host)
        } else {
            ContentUnavailableView(L("No AI Platform"),
                                   systemImage: "bubble.left.and.bubble.right",
                                   description: Text(L("Pick a platform from the toolbar to get started.")))
        }
    }

    /// 绑定上下文条：这次对话是为哪本书哪一页开的。**只在有绑定时出现**——没绑定时面板就是个纯浏览器，
    /// 不该白占一行（工具栏已经因为太高改过一轮）。
    @ViewBuilder
    private var contextBar: some View {
        if let ctx = panel.bindContext {
            HStack(spacing: 6) {
                Image(systemName: "book").foregroundStyle(.secondary)
                Text(ctx.docTitle).lineLimit(1)
                Text(String(format: L("p.%d"), ctx.page + 1)).foregroundStyle(.secondary)
                bindStateMark
                Spacer(minLength: 4)
                Button { panel.unbind() } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tertiary)
                    .help(L("Unbind"))
            }
            .font(.caption)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.bar)
            Divider()
        }
    }

    /// 绑定状态：还没发第一条消息时没有会话 URL（各家都是发出去才 replaceState 出唯一链接），
    /// 所以这里会先显示「等待第一条消息」，发完自动变成已绑定。
    @ViewBuilder
    private var bindStateMark: some View {
        if let f = panel.flash {
            // 一闪而过的确认（「已加到笔记」）暂时顶掉常驻状态标记，几秒后自己让位回去。
            Label(f, systemImage: "checkmark.circle").foregroundStyle(.secondary)
        } else if let t = panel.boundThread {
            if t.state == .suspect {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .help(L("This conversation may no longer exist."))
            } else {
                Image(systemName: "link")
                    .foregroundStyle(.secondary)
                    .help(L("Bound to this conversation"))
            }
        } else {
            Text(L("waiting for first message")).foregroundStyle(.tertiary)
        }
    }

    // MARK: - 工具栏
}
