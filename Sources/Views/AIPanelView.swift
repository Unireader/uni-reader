import SwiftUI
import WebKit
import AppKit

/// AI 面板浮窗的内容：一条系统工具栏 + 一个原生 SwiftUI `WebView`。
///
/// **全原生**：macOS 26 的 WebKit for SwiftUI（`WebView` + `WebPage`）不需要 `NSViewRepresentable`
/// 包 `WKWebView`。工具栏是系统 `.toolbar`，进度是系统 `ProgressView`，空态是
/// `ContentUnavailableView`——一处自绘仿系统样式都没有。
///
/// 工具栏分组按 Tahoe 的合并规则排（见 `AGENTS.md`）：**连续的纯图标 Button 才会并成一枚玻璃胶囊**，
/// 所以「后退/前进/刷新」三枚挨着（= 浏览器手感的那一枚胶囊），带文字的平台菜单单独一组，
/// 两组之间插 `ToolbarSpacer` 才不会被粘进同一枚胶囊。
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

    @State private var clearTarget: AIProvider?
    @State private var showClear = false

    /// 本窗口是不是 key。⌘F 走的是与阅读区同一条通知路由（App 级菜单命令 → 通知 → key 窗口认领），
    /// 所以面板也得知道自己是不是当前那一个。
    @State private var isKey = false
    @State private var findOpen = false
    @State private var findText = ""
    @FocusState private var findFocused: Bool

    @Environment(\.dismissWindow) private var dismissWindow

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
            .onChange(of: panel.mode) { _, m in
                if m == .inline { dismissWindow(id: AIPanelModel.windowID) }
            }
            .background(WindowAccessor(onKeyChange: { key in
                isKey = key
                if key { panel.setActiveHost(host) }   // 前台切回浮窗 → 模型级操作作用到它这一份页面
            }, onWindow: { AIPanelDock.shared.setPanel($0) }))
            .background(WindowLevelAccessor(floating: floating))
            .background(WindowLifecycle { AIPanelModel.shared.releaseHost(.window) })
    }

    private var shell: some View {
        content
            .toolbar { toolbarContent }
            // 只留 title（供「窗口」菜单认它），**不设 subtitle**——subtitle 会把标题区撑成两行，
            // 是这个浮窗第一版「太高」的主因之一。页面标题在紧凑工具栏里没地方放，也不必放。
            .navigationTitle(panel.currentProvider?.name ?? L("AI"))
            .confirmationDialog(L("Clear login data for this platform?"), isPresented: $showClear) {
                Button(L("Clear"), role: .destructive) {
                    guard let p = clearTarget else { return }
                    Task { await panel.clearData(for: p) }
                }
                Button(L("Cancel"), role: .cancel) {}
            } message: {
                Text(clearMessage)
            }
    }

    private var clearMessage: String {
        String(format: L("Cookies and local data for %@ will be removed. You will need to sign in again."),
               clearTarget?.name ?? "")
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

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        navGroup
        // 只有一家平台时整个切换器都不摆——一枚永远只有一个选项的菜单在紧凑工具栏里是纯占地方。
        // 用户经外部配置加了第二家，它会自己回来。
        if panel.providers.count > 1 {
            ToolbarSpacer()
            platformItem
        }
        ToolbarSpacer()
        actionGroup
    }

    /// 第一枚胶囊：纯图标、连续三枚 → Tahoe 合并成一组分段控件。
    private var navGroup: some ToolbarContent {
        ToolbarItemGroup {
            // 快捷键挂在按钮上 = **窗口级**，不会外泄成 App 级菜单命令（那样阅读区也会被它们劫走）。
            Button { panel.goBack() } label: { Image(systemName: "chevron.left") }
                .help(L("Back"))
                .keyboardShortcut("[", modifiers: .command)
                .disabled(!panel.canGoBack)
            Button { panel.goForward() } label: { Image(systemName: "chevron.right") }
                .help(L("Forward"))
                .keyboardShortcut("]", modifiers: .command)
                .disabled(!panel.canGoForward)
            Button(action: reloadOrStop) { Image(systemName: isLoading ? "xmark" : "arrow.clockwise") }
                .help(isLoading ? L("Stop") : L("Reload"))
                .keyboardShortcut("r", modifiers: .command)
                .disabled(panel.current == nil)
        }
    }

    /// 平台切换：带文字，必须单独一组（掺进上面那组会把整枚胶囊打散成独立圆钮）。
    private var platformItem: some ToolbarContent {
        ToolbarItem {
            Menu {
                Picker(L("Platform"), selection: platformBinding) {
                    ForEach(panel.providers) { p in
                        Label(p.name, systemImage: p.icon).tag(p.id)
                    }
                }
                .pickerStyle(.inline)
                if let note = panel.currentProvider?.note {
                    Divider()
                    Text(L(note))   // 菜单里的裸 Text = 系统渲染的说明行（不可点）
                }
            } label: {
                Label(panel.currentProvider?.name ?? L("Platform"),
                      systemImage: panel.currentProvider?.icon ?? "bubble.left.and.bubble.right")
            }
            .help(L("Switch AI Platform"))
        }
    }

    /// 第二枚胶囊：同样是连续的纯图标。
    private var actionGroup: some ToolbarContent {
        ToolbarItemGroup {
            Button { panel.goHome() } label: { Image(systemName: "house") }
                .help(L("New Chat"))
                .disabled(panel.current == nil)
            Button { floating.toggle() } label: { Image(systemName: floating ? "pin.fill" : "pin") }
                .help(L("Keep Panel on Top"))
            Menu { moreMenu } label: { Image(systemName: "ellipsis") }
                .help(L("More"))
        }
    }

    @ViewBuilder
    private var moreMenu: some View {
        Button(L("Open in Browser"), action: openInBrowser)
            .disabled(panel.currentURL == nil)
        Button(L("Copy Link"), action: copyLink)
            .disabled(panel.currentURL == nil)
        Divider()
        Button(L("Clear Login Data…"), role: .destructive) {
            clearTarget = panel.currentProvider
            showClear = clearTarget != nil
        }
        .disabled(panel.currentProvider == nil)
        Divider()
        Toggle(L("Dock to Reading Window"), isOn: Binding(get: { panel.docked },
                                                          set: { panel.setDocked($0) }))
            .help(L("Sit at the right edge of the reading window and follow it. Off while that window is maximized."))
        Button(L("Show Inside the Window")) { panel.setMode(.inline) }
        Divider()
        Section(panel.usingExternalConfig ? L("Platforms: External Config") : L("Platforms: Built-in")) {
            Button(L("Reveal Config File…"), action: revealConfig)
            Button(L("Reload Config")) { panel.reloadConfig() }
        }
    }

    // MARK: - 动作

    private var isLoading: Bool { panel.current?.isLoading == true }

    private var platformBinding: Binding<String> {
        Binding(get: { panel.currentID }, set: { panel.select($0) })
    }

    private func reloadOrStop() {
        if isLoading { panel.stop() } else { panel.reload() }
    }

    private func openInBrowser() {
        guard let url = panel.currentURL else { return }
        NSWorkspace.shared.open(url)
    }

    private func copyLink() {
        guard let url = panel.currentURL else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
    }

    /// 配置文件不存在时先把内置表导出成模板再定位——直接 reveal 一个不存在的路径什么都不会发生。
    private func revealConfig() {
        let url = panel.exportBuiltinConfig()
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}

/// 「打开 AI 面板」菜单项。抽成独立 `View` 是因为 `openWindow` 是 environment action，
/// `.commands { }` 的闭包里拿不到（同 `OpenRecentMenu` 的理由）。
struct AIPanelMenu: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        // 内置模式下 ⌘⇧A 是展开/收起那块侧面板，而不是凭空开一扇窗（那扇窗此刻不该存在）。
        Button(L("AI Panel")) {
            if AIPanelModel.shared.mode == .inline { AIPanelModel.shared.toggleInlineActive() }
            else { openWindow(id: AIPanelModel.windowID) }
        }
        .keyboardShortcut("a", modifiers: [.command, .shift])
    }
}
