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

    var body: some View {
        shell
            .modifier(PageObservers(panel: panel))
            .onReceive(NotificationCenter.default.publisher(for: .readerFind)) { _ in
                guard isKey else { return }     // ⌘F 是 App 级菜单命令，只有 key 窗口该响应
                findOpen = true
                findFocused = true
            }
            .background(WindowAccessor(onKeyChange: { isKey = $0 }))
            .background(WindowLevelAccessor(floating: floating))
            .background(WindowLifecycle { AIPanelModel.shared.releaseIdle() })
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
        guard !findText.isEmpty, let page = panel.current else { return }
        let js = "return window.find(q, false, back, true, false, true, false);"
        Task { _ = try? await page.callJavaScript(js, arguments: ["q": findText, "back": backwards],
                                                  contentWorld: .page) }
    }

    private func closeFind() {
        findOpen = false
        findFocused = false
    }

    @ViewBuilder
    private var pageArea: some View {
        if let page = panel.current {
            webBody(page)
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

    /// 加载进度压在顶边：只在真的在加载时出现（常驻一条 0% 是纯噪音）。
    private func webBody(_ page: WebPage) -> some View {
        WebView(page)
            .webViewBackForwardNavigationGestures(.enabled)
            .webViewMagnificationGestures(.enabled)
            .webViewContextMenu { info in webMenu(info) }
            .overlay(alignment: .top) { progressBar(page) }
            .animation(.easeOut(duration: 0.15), value: page.isLoading)
    }

    /// webview 的右键菜单。
    ///
    /// ⚠️ 这条**取代**了系统默认的网页右键菜单，所以剪贴板三项要自己补回来——走
    /// `NSApp.sendAction` 转发给响应链（webview 就在链上），比自己实现靠谱。
    /// 「添加到文字笔记」是这个菜单存在的理由：`ActivatedElementInfo` 只带 linkURL，
    /// 选中文字得靠注入脚本推上来（`panel.pageSelection`）。
    @ViewBuilder
    private func webMenu(_ info: WebView.ActivatedElementInfo) -> some View {
        Button(L("Add to Text Notes")) { panel.requestNoteFromSelection() }
            .disabled(!panel.canMakeNote)
        Divider()
        Button(L("Cut")) { NSApp.sendAction(#selector(NSText.cut(_:)), to: nil, from: nil) }
        Button(L("Copy")) { NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil) }
        Button(L("Paste")) { NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil) }
        if let link = info.linkURL {
            Divider()
            Button(L("Open in Browser")) { NSWorkspace.shared.open(link) }
            Button(L("Copy Link")) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(link.absoluteString, forType: .string)
            }
        }
        Divider()
        Button(L("Reload")) { panel.reload() }
    }

    @ViewBuilder
    private func progressBar(_ page: WebPage) -> some View {
        if page.isLoading {
            ProgressView(value: page.estimatedProgress)
                .progressViewStyle(.linear)
                .transition(.opacity)
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

/// 页面状态观察器。`WebPage` 是 Observation 类型——**只有在 View 的 body 求值里读它才有跟踪**，
/// `AIPanelModel` 自己订阅不了，所以 URL/标题/加载状态的变化一律由视图这边转交给模型。
/// 抽成 `ViewModifier` 是为了不把三条 `onChange` 再堆进 `shell` 的修饰符链（那条链已经超过一次时限）。
private struct PageObservers: ViewModifier {
    @ObservedObject var panel: AIPanelModel

    func body(content: Content) -> some View {
        content
            .onChange(of: panel.current?.url) { _, _ in panel.syncFromPage() }
            .onChange(of: panel.current?.title) { _, _ in panel.syncFromPage() }
            .onChange(of: panel.current?.isLoading) { _, loading in
                if loading == false { panel.noteLoadSettled() }   // 加载停下来才谈得上「有没有被重定向」
            }
    }
}

/// 「打开 AI 面板」菜单项。抽成独立 `View` 是因为 `openWindow` 是 environment action，
/// `.commands { }` 的闭包里拿不到（同 `OpenRecentMenu` 的理由）。
struct AIPanelMenu: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button(L("AI Panel")) { openWindow(id: AIPanelModel.windowID) }
            .keyboardShortcut("a", modifiers: [.command, .shift])
    }
}
