import AppKit
import Combine
import SwiftUI

/// 设置窗（⌘,）：一扇普通窗口，**全 app 只有一扇**（再按 ⌘, 是把它调到前面）。
@MainActor
final class SettingsWindowController: NSWindowController {
    private static var shared: SettingsWindowController?
    private var bag = Set<AnyCancellable>()

    static func show() {
        if let c = shared, c.window != nil {
            c.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        guard let app = AppDelegate.shared?.appModel else { return }
        let c = SettingsWindowController(app: app)
        shared = c
        // 上次的大小/位置有记录就用它，没有（首次）才居中。
        if c.window?.setFrameUsingName(Self.frameName) != true { c.window?.center() }
        c.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private static let frameName = "SettingsWindow"

    init(app: AppModel) {
        let win = NSWindow(contentViewController: SettingsTabController(app: app))
        win.title = L("Settings")   // 选中标签后换成标签名（系统设置窗的惯例），见 `SettingsTabController`
        win.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        win.toolbarStyle = .preference   // 设置窗那种：标题一行、图标 + 文字的标签一行
        win.setContentSize(NSSize(width: 680, height: 560))
        win.contentMinSize = NSSize(width: 560, height: 440)
        win.setFrameAutosaveName(Self.frameName)
        win.isReleasedWhenClosed = false
        super.init(window: win)
        // ⌘W / ⇧⌘W 是 App 级菜单命令（广播 + key 窗口认领，见 `ReaderWindowController`/`RefWindowController`
        // 同款订阅）；设置窗没有标签，两个都是关它自己。
        for name in [Notification.Name.closeTabRequested, .closeWindowRequested] {
            NotificationCenter.default.publisher(for: name)
                .sink { [weak self] _ in
                    guard let self, self.window?.isKeyWindow == true else { return }
                    self.window?.performClose(nil)
                }
                .store(in: &bag)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) 不支持") }
}

/// 设置窗的分页壳：`NSTabViewController` 的 `.toolbar` 样式——标签（图标 + 文字）住在标题栏里，
/// 与系统各 app 的设置窗同款；每页内容是 SwiftUI 表单（`SettingsView(tab:)`，2026-09-19 用户定：设置页用 SwiftUI——
/// 简单表单正是它的长处，AppKit 的 `NSGridView` 版排出来变形）。
/// 分页壳不用 SwiftUI `TabView`：装进普通 `NSWindow` 后它把标签条画在标题栏**下面**、自带一层
/// 更浅的底色 + 分隔线，跟标题栏两种灰叠在一起像错位（2026-09-10 用户截图）。
@MainActor
final class SettingsTabController: NSTabViewController {
    init(app: AppModel) {
        super.init(nibName: nil, bundle: nil)
        tabStyle = .toolbar
        for t in SettingsTab.allCases {
            let page = NSHostingController(rootView: SettingsView(tab: t).environmentObject(app))
            // 不让 SwiftUI 内容的尺寸变成约束：初始大小 / 最小值 / 可缩放全由窗口管。默认的
            // `.standardBounds` 会把「理想尺寸」也做成约束——各页内容高矮不一，切一下标签窗口就跳一下。
            page.sizingOptions = []
            // 🔴 **必须给子控制器设 `title`**：`.toolbar` 样式下切标签后 AppKit 会（晚一拍、异步地）
            // 把窗口标题改成选中子控制器的 `title`——没设就显示成「Untitled」（2026-09-10 用户报）。
            page.title = t.title
            let item = NSTabViewItem(viewController: page)
            item.label = t.title
            item.image = NSImage(systemSymbolName: t.symbol, accessibilityDescription: t.title)
            addTabViewItem(item)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) 不支持") }

    /// 首次显示时 AppKit 不会主动同步标题（只在切标签时改），所以初始那一下要自己写；
    /// 之后切标签由 AppKit 按子控制器的 `title` 更新。
    override func viewWillAppear() {
        super.viewWillAppear()
        guard tabViewItems.indices.contains(selectedTabViewItemIndex) else { return }
        view.window?.title = tabViewItems[selectedTabViewItemIndex].label
    }
}

/// AI 面板浮窗（⇧⌘A 的「浮窗模式」，`AIPanelModel.mode == .window`）。**全局唯一**——
/// 迁移前用 `Window` scene 表达的正是这个语义（每家平台一个 WebPage 已经够用，还顺带绕开
/// 「一个 WKWebView 不能同时挂两个视图」）。
///
/// 🔴 **工具栏必须由这里建**：`AIPanelView` 原来那条 `.toolbar { }` 是 SwiftUI 的，装进
/// `NSHostingController` 之后对 AppKit 窗口不生效（SwiftUI 只管它自己创建的窗口）。
/// 内容（WebView、查找条、空态）仍全是 SwiftUI。
@MainActor
final class AIPanelWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate {
    private static var shared: AIPanelWindowController?

    private let panel = AIPanelModel.shared
    private var bag = Set<AnyCancellable>()

    /// 浮窗此刻在不在屏幕上（阅读窗口工具栏那枚开关的按下态）。
    static var isShown: Bool { shared?.window?.isVisible == true }

    static func show() {
        defer { NotificationCenter.default.post(name: .auxPanelVisibilityChanged, object: nil) }
        if let c = shared, let w = c.window {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            AIPanelDock.shared.reapply()   // 隐藏时解除了子窗口关系，回来要重新贴边
            return
        }
        guard let app = AppDelegate.shared?.appModel else { return }
        let c = AIPanelWindowController(app: app)
        shared = c
        c.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// ⌘⇧A（浮窗模式）：显示 ⇄ 隐藏（用户 2026-09-13「不关闭，暂时隐藏」）。
    /// 隐藏 = `orderOut`：窗口与内容都留着（网页、对话、滚动位置原样），不走 `windowWillClose` 那条释放路径；
    /// 是吸附着的子窗口时先摘下来——子窗口跟着父窗口的显隐走，直接 orderOut 可能被父窗口再带回来。
    static func toggle() {
        if let c = shared, let w = c.window, w.isVisible { c.hide() } else { show() }
    }

    private func hide() {
        guard let w = window else { return }
        w.parent?.removeChildWindow(w)
        w.orderOut(nil)
        NotificationCenter.default.post(name: .auxPanelVisibilityChanged, object: nil)
    }

    /// 切到内置模式时把这扇窗关掉（迁移前是 `AIPanelView` 里的 `dismissWindow`）。
    static func closeIfOpen() {
        shared?.close()
        shared = nil
    }

    init(app: AppModel) {
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 760),
                           styleMask: [.titled, .closable, .miniaturizable, .resizable],
                           backing: .buffered, defer: false)
        // 本窗口就是 `.window` 这个宿主，有自己那一份网页（见 `AIPanelModel` 的宿主说明）
        panel.setActiveHost(.window)
        _ = panel.page(for: .window)
        win.contentView = ConsultPanelNSView(host: .window, inline: false)
        win.contentMinSize = NSSize(width: 320, height: 360)
        win.title = L("AI")
        win.isReleasedWhenClosed = false
        win.isRestorable = false
        // 紧凑工具栏（系统标准样式）：默认的 expanded 在 Tahoe 上又高又占地方，一个聊天浮窗
        // 不该拿两行去放标题。`showsTitle: false` 连标题行一起省掉——当前是哪家平台，
        // 工具栏中间那枚平台菜单自己就写着。
        win.toolbarStyle = .unifiedCompact
        win.titleVisibility = .hidden
        super.init(window: win)

        let tb = NSToolbar(identifier: "ai-panel")
        tb.delegate = self
        tb.displayMode = .iconOnly
        win.toolbar = tb
        win.delegate = self

        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshPin() }
            .store(in: &bag)

        // 切到内置模式 → 这扇窗该消失（模型是唯一真源，别让两处各显示一份）。
        panel.$mode
            .receive(on: RunLoop.main)
            .sink { m in if m == .inline { AIPanelWindowController.closeIfOpen() } }
            .store(in: &bag)
        // 换了平台 → 本窗口这一份页面跟上
        panel.$currentID
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in _ = self?.panel.page(for: .window) }
            .store(in: &bag)

        AIPanelDock.shared.setPanel(win)
        AIPanelDock.shared.setEnabled(panel.docked)
        refreshPin()
    }

    /// 前台切回浮窗 → 模型级操作作用到它这一份页面。
    func windowDidBecomeKey(_ notification: Notification) { panel.setActiveHost(.window) }

    required init?(coder: NSCoder) { fatalError("init(coder:) 不支持") }

    func windowWillClose(_ notification: Notification) {
        panel.releaseHost(.window)
        Self.shared = nil
        NotificationCenter.default.post(name: .auxPanelVisibilityChanged, object: nil)
    }

    // MARK: 工具栏
    //
    // 分组沿用迁移前的排法：后退/前进/刷新三枚挨着（浏览器手感的那一枚胶囊）、带文字的平台菜单
    // 单独一组、动作三枚一组，组间插 `.space`（Tahoe 的合并规则见 `AGENTS.md`）。

    private enum ID {
        static let back = NSToolbarItem.Identifier("ai.back")
        static let forward = NSToolbarItem.Identifier("ai.forward")
        static let reload = NSToolbarItem.Identifier("ai.reload")
        static let platform = NSToolbarItem.Identifier("ai.platform")
        static let home = NSToolbarItem.Identifier("ai.home")
        static let pin = NSToolbarItem.Identifier("ai.pin")
        static let more = NSToolbarItem.Identifier("ai.more")
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [ID.back, ID.forward, ID.reload, .space, ID.platform, .space, ID.home, ID.pin, ID.more]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [ID.back, ID.forward, ID.reload, ID.platform, ID.home, ID.pin, ID.more, .space, .flexibleSpace]
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch id {
        case ID.back: return button(id, L("Back"), "chevron.left", #selector(goBack))
        case ID.forward: return button(id, L("Forward"), "chevron.right", #selector(goForward))
        case ID.reload: return button(id, L("Reload"), "arrow.clockwise", #selector(reloadOrStop))
        // 新对话与 Agent 面板统一用 square.and.pencil（同功能同图标，用户 2026-09-18）
        case ID.home: return button(id, L("New Chat"), "square.and.pencil", #selector(goHome))
        case ID.pin: return toggleButton(id, L("Keep Panel on Top"), "pin", #selector(togglePin))
        case ID.platform:
            let it = NSMenuToolbarItem(itemIdentifier: id)
            it.label = L("Platform")
            it.paletteLabel = L("Platform")
            it.toolTip = L("Switch AI Platform")
            it.image = Self.icon("bubble.left.and.bubble.right", L("Platform"))
            it.menu = platformMenu()
            return it
        case ID.more:
            let it = NSMenuToolbarItem(itemIdentifier: id)
            it.label = L("More")
            it.paletteLabel = L("More")
            it.image = Self.icon("ellipsis", L("More"))
            it.menu = moreMenu()
            return it
        default: return nil
        }
    }

    /// 🔴 **图标要显式定尺寸**：不给 symbol configuration 的话工具栏用默认大号，紧凑样式下图标
    /// 会顶到上下边缘、标题栏也跟着高（2026-09-01 用户两次实测）。
    /// **用 `scale` 而不是 `pointSize`**：pointSize 是死值（13pt 试过仍偏大），而 `.small`
    /// 让符号按系统给的上下文自己缩，紧凑工具栏里正好。
    private static func icon(_ symbol: String, _ label: String) -> NSImage? {
        NSImage(systemSymbolName: symbol, accessibilityDescription: label)?
            .withSymbolConfiguration(.init(scale: .small))
    }

    private func button(_ id: NSToolbarItem.Identifier, _ label: String,
                        _ symbol: String, _ sel: Selector) -> NSToolbarItem {
        let it = NSToolbarItem(itemIdentifier: id)
        it.label = label
        it.paletteLabel = label
        it.toolTip = label
        it.image = Self.icon(symbol, label)
        it.target = self
        it.action = sel
        it.isBordered = true
        return it
    }

    /// 置顶那枚是开关：用 `pushOnPushOff` 让系统画按下态——只换 `pin`/`pin.fill` 看不出来
    /// （2026-09-01 用户报）。带 view 的 item 拿不到 `validateToolbarItem`，状态由
    /// `refreshPin()` 推。
    private func toggleButton(_ id: NSToolbarItem.Identifier, _ label: String,
                              _ symbol: String, _ sel: Selector) -> NSToolbarItem {
        let it = NSToolbarItem(itemIdentifier: id)
        let btn = NSButton(frame: NSRect(x: 0, y: 0, width: 32, height: 24))
        btn.image = Self.icon(symbol, label)
        btn.imagePosition = .imageOnly
        btn.bezelStyle = .texturedRounded
        btn.setButtonType(.pushOnPushOff)
        btn.state = UserDefaults.standard.bool(forKey: "aiPanelFloating") ? .on : .off
        btn.target = self
        btn.action = sel
        it.view = btn
        it.label = label
        it.paletteLabel = label
        it.toolTip = label
        return it
    }

    private func refreshPin() {
        let on = UserDefaults.standard.bool(forKey: "aiPanelFloating")
        window?.level = on ? .floating : .normal
        for it in window?.toolbar?.items ?? [] where it.itemIdentifier == ID.pin {
            (it.view as? NSButton)?.state = on ? .on : .off
        }
    }

    /// 菜单内容按需重建（`NSMenuDelegate`），省得每次平台表变化都要手工同步。
    private func platformMenu() -> NSMenu {
        let m = NSMenu()
        m.delegate = self
        m.identifier = NSUserInterfaceItemIdentifier("platform")
        menuNeedsUpdate(m)   // 先填一次：空菜单点开什么都没有，看起来就是「按了没反应」
        return m
    }

    private func moreMenu() -> NSMenu {
        let m = NSMenu()
        m.delegate = self
        m.identifier = NSUserInterfaceItemIdentifier("more")
        menuNeedsUpdate(m)
        return m
    }

    /// 校验 + 顺带刷新图标（刷新/停止、置顶的图钉实心与否）——AppKit 每轮事件循环都会调它。
    func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        switch item.itemIdentifier {
        case ID.back: return panel.canGoBack
        case ID.forward: return panel.canGoForward
        case ID.reload:
            let loading = panel.current?.isLoading == true
            item.image = Self.icon(loading ? "xmark" : "arrow.clockwise", L("Reload"))
            item.toolTip = loading ? L("Stop") : L("Reload")
            return panel.current != nil
        case ID.home: return panel.current != nil
        case ID.platform:
            // 迁移前是「只有一家平台就整个不摆」，工具栏里做不到（default 清单是静态的）。
            // 那就别灰着——灰按钮比多一枚按钮更让人猜（2026-09-01 用户报「按下没有效果，
            // 不知道干啥的」）：菜单里至少列着当前平台，点开就知道它是干什么的。
            item.toolTip = String(format: L("Platform: %@"), panel.currentProvider?.name ?? L("AI"))
            return true
        default: return true
        }
    }

    // MARK: 动作

    @objc private func goBack() { panel.goBack() }
    @objc private func goForward() { panel.goForward() }
    @objc private func goHome() { panel.goHome() }

    @objc private func reloadOrStop() {
        if panel.current?.isLoading == true { panel.stop() } else { panel.reload() }
    }

    /// 置顶只翻偏好值；`refreshPin`（跟着 `UserDefaults` 变化）把 `NSWindow.level` 与按钮一起跟上。
    @objc private func togglePin() {
        let d = UserDefaults.standard
        d.set(!d.bool(forKey: "aiPanelFloating"), forKey: "aiPanelFloating")
    }

    @objc private func selectPlatform(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        panel.select(id)
    }

    @objc private func openInBrowser() {
        guard let url = panel.currentURL else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func copyLink() {
        guard let url = panel.currentURL else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
    }

    @objc private func selectMode(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        panel.setChatMode(id)
    }

    @objc private func toggleDock(_ sender: NSMenuItem) { panel.setDocked(!panel.docked) }
    @objc private func showInline() { panel.setMode(.inline) }
    @objc private func reloadConfig() { panel.reloadConfig() }

    @objc private func revealConfig() {
        // 配置文件不存在时先把内置表导出成模板再定位——直接 reveal 一个不存在的路径什么都不会发生。
        NSWorkspace.shared.activateFileViewerSelecting([panel.exportBuiltinConfig()])
    }

    /// 清登录数据：确认对话框从 SwiftUI 的 `confirmationDialog` 换成 `NSAlert`（这枚菜单项
    /// 现在住在 AppKit 工具栏里，弹 SwiftUI 对话框没有宿主视图）。
    @objc private func clearLoginData() {
        guard let p = panel.currentProvider, let win = window else { return }
        let a = NSAlert()
        a.messageText = L("Clear login data for this platform?")
        a.informativeText = String(format: L("Cookies and local data for %@ will be removed. You will need to sign in again."), p.name)
        a.addButton(withTitle: L("Clear"))
        a.addButton(withTitle: L("Cancel"))
        a.beginSheetModal(for: win) { resp in
            guard resp == .alertFirstButtonReturn else { return }
            Task { await AIPanelModel.shared.clearData(for: p) }
        }
    }
}

extension AIPanelWindowController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        switch menu.identifier?.rawValue {
        case "platform":
            for p in panel.providers {
                let it = NSMenuItem(title: p.name, action: #selector(selectPlatform(_:)), keyEquivalent: "")
                it.target = self
                it.representedObject = p.id
                it.state = (p.id == panel.currentID) ? .on : .off
                it.image = NSImage(systemSymbolName: p.icon, accessibilityDescription: nil)
                menu.addItem(it)
            }
            if let note = panel.currentProvider?.note {
                menu.addItem(.separator())
                menu.addItem(.sectionHeader(title: L(note)))
            }
        case "more":
            // 发送时用哪档模式（DeepSeek 的「快速 / 专家 / 识图」）。默认跟内容走：
            // 有图 → 识图、无图 → 专家（用户 2026-09-06 定）。**只在新对话页切得动**。
            if let modes = panel.currentProvider?.modes, !modes.isEmpty {
                menu.addItem(.sectionHeader(title: L("Mode for new chats")))
                let auto = add(menu, L("Follow Content"), #selector(selectMode(_:)))
                auto.representedObject = "auto"
                auto.state = panel.chatMode == "auto" ? .on : .off
                for m in modes {
                    let it = add(menu, m.name, #selector(selectMode(_:)))
                    it.representedObject = m.id
                    it.state = panel.chatMode == m.id ? .on : .off
                }
                menu.addItem(.separator())
            }
            add(menu, L("Open in Browser"), #selector(openInBrowser), enabled: panel.currentURL != nil)
            add(menu, L("Copy Link"), #selector(copyLink), enabled: panel.currentURL != nil)
            menu.addItem(.separator())
            add(menu, L("Clear Login Data…"), #selector(clearLoginData),
                enabled: panel.currentProvider != nil)
            menu.addItem(.separator())
            let dock = add(menu, L("Dock to Reading Window"), #selector(toggleDock(_:)))
            dock.state = panel.docked ? .on : .off
            dock.toolTip = L("Sit at the right edge of the reading window and follow it. Off while that window is maximized.")
            add(menu, L("Show Inside the Window"), #selector(showInline))
            menu.addItem(.separator())
            menu.addItem(.sectionHeader(title: panel.usingExternalConfig
                                        ? L("Platforms: External Config") : L("Platforms: Built-in")))
            add(menu, L("Reveal Config File…"), #selector(revealConfig))
            add(menu, L("Reload Config"), #selector(reloadConfig))
        default: break
        }
    }

    @discardableResult
    private func add(_ menu: NSMenu, _ title: String, _ sel: Selector, enabled: Bool = true) -> NSMenuItem {
        let it = NSMenuItem(title: title, action: sel, keyEquivalent: "")
        it.target = self
        it.isEnabled = enabled
        menu.addItem(it)
        return it
    }
}
