import AppKit
import Combine
import SwiftUI

/// 浮窗当前显示哪一段对话（controller 决定，内容视图只管显示）。
@MainActor
final class AgentWindowState: ObservableObject {
    @Published var chat: AgentChat?
}

/// Agent 面板的**独立窗口形态**（全 App 一扇）。跟着最近那扇 key 阅读窗口的工作区走：
/// 切到另一个工作区的阅读窗口，这扇窗就换成那个工作区的对话（`AgentPanelModel.windowContext`）。
///
/// 操作在窗口自己的 `NSToolbar` 上（与咨询面板的 `AIPanelWindowController` 同一套做法：SwiftUI 的 `.toolbar`
/// 对 AppKit 建的窗口不生效）；窗口标题 = 会话标题，副标题 = 工作区。内容视图不再另画标题行。
@MainActor
final class AgentWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate, NSMenuDelegate {
    private static var shared: AgentWindowController?

    private let panel = AgentPanelModel.shared
    private let state = AgentWindowState()
    private var bag = Set<AnyCancellable>()
    private var chatBag = Set<AnyCancellable>()

    static func show() {
        if let c = shared, let w = c.window {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            AIPanelDock.agent.reapply()   // 隐藏时解除了子窗口关系，回来要重新贴边
            return
        }
        let c = AgentWindowController()
        shared = c
        c.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        AIPanelDock.agent.reapply()       // 贴到阅读窗口右侧、同高（`reapply` 要求窗口已可见）
        // 🔴 新建窗口（首次打开 / 关掉后再开）再补一次、放到下一拍：SwiftUI 内容的首次布局在
        // makeKeyAndOrderFront 之后才跑，会把窗口改回内容的理想尺寸，刚贴好的高度就没了
        // （2026-09-18 用户报「关闭后重新打开没有同步高度」；只是隐藏再显示不重建窗口，没这个问题）
        DispatchQueue.main.async { AIPanelDock.agent.reapply() }
    }

    /// 快捷键：显示 ⇄ 隐藏（隐藏只是撤下屏幕，对话原样留着）。
    /// 是吸附着的子窗口时先摘下来——子窗口跟着父窗口的显隐走，直接 orderOut 可能被父窗口再带回来。
    static func toggle() {
        if let c = shared, let w = c.window, w.isVisible {
            w.parent?.removeChildWindow(w)
            w.orderOut(nil)
        } else {
            show()
        }
    }

    static func closeIfOpen() {
        shared?.close()
        shared = nil
    }

    init() {
        let host = NSHostingController(rootView: AgentWindowRoot(state: state))
        // 只让 SwiftUI 管最小尺寸，不许它按内容理想尺寸改窗口大小——窗口大小归吸附（`AIPanelDock`）与用户拖动
        host.sizingOptions = [.minSize]
        let win = NSWindow(contentViewController: host)
        win.title = AgentConfig.displayName
        win.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        win.setContentSize(NSSize(width: 460, height: 720))
        win.isReleasedWhenClosed = false
        win.isRestorable = false
        // 紧凑工具栏：标题与按钮同一行（咨询面板 2026-08-25「toolbar 太大太高」之后定的规矩）
        win.toolbarStyle = .unifiedCompact
        win.setFrameAutosaveName("AgentPanel")
        super.init(window: win)

        let tb = NSToolbar(identifier: "agent-panel")
        tb.delegate = self
        tb.displayMode = .iconOnly
        win.toolbar = tb
        win.delegate = self

        // 吸附到阅读窗口右侧、同高、跟着移动（与咨询面板同一套 `AIPanelDock`，另一份实例）
        AIPanelDock.agent.setPanel(win)
        AIPanelDock.agent.setEnabled(panel.docked)

        // 跟着 key 阅读窗口换工作区 → 换对话
        panel.$windowContext
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.syncChat() }
            .store(in: &bag)
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshPin() }
            .store(in: &bag)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) 不支持") }

    func windowWillClose(_ notification: Notification) {
        panel.releaseHost(.window)
        Self.shared = nil
    }

    // MARK: - 对话

    private var chat: AgentChat? { state.chat }

    private func syncChat() {
        guard let cwd = panel.windowContext?.cwd else {
            state.chat = nil
            chatBag = []
            refreshTitle()
            return
        }
        let c = panel.chat(for: .window, cwd: cwd)
        if c !== state.chat {
            state.chat = c
            chatBag = []
            // 标题 / 忙闲变了 → 窗口标题与工具栏跟上（objectWillChange 在改之前发，下一拍再读）
            c.objectWillChange
                .sink { [weak self] in DispatchQueue.main.async { self?.refreshTitle() } }
                .store(in: &chatBag)
        }
        refreshTitle()
    }

    private func refreshTitle() {
        guard let win = window else { return }
        win.title = chat?.title ?? AgentConfig.displayName
        win.subtitle = panel.windowContext?.workspaceName ?? ""
        win.toolbar?.validateVisibleItems()
    }

    // MARK: - 工具栏
    //
    // 分组（Tahoe 的合并规则见 `AGENTS.md`：相邻的纯图标项会并成一枚胶囊，组间插 `.space` 才分开）：
    // [历史 · 新对话] [选项] [置顶]。

    private enum ID {
        static let history = NSToolbarItem.Identifier("agent.history")
        static let newChat = NSToolbarItem.Identifier("agent.new")
        static let options = NSToolbarItem.Identifier("agent.options")
        static let pin = NSToolbarItem.Identifier("agent.pin")
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, ID.history, ID.newChat, .space, ID.options, .space, ID.pin]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [ID.history, ID.newChat, ID.options, ID.pin, .space, .flexibleSpace]
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch id {
        case ID.newChat:
            let it = NSToolbarItem(itemIdentifier: id)
            it.label = L("New Chat")
            it.paletteLabel = L("New Chat")
            it.toolTip = L("New Chat")
            it.image = Self.icon("square.and.pencil", L("New Chat"))
            it.target = self
            it.action = #selector(newChat)
            it.isBordered = true
            return it
        case ID.history:
            return menuItem(id, L("Earlier Chats"), "clock.arrow.circlepath", menu: "history")
        case ID.options:
            return menuItem(id, L("Agent Options"), "slider.horizontal.3", menu: "options")
        case ID.pin:
            // 开关：`pushOnPushOff` 让系统画按下态（咨询面板 2026-09-01 的教训：只换实心图标看不出来）
            let it = NSToolbarItem(itemIdentifier: id)
            let btn = NSButton(frame: NSRect(x: 0, y: 0, width: 32, height: 24))
            btn.image = Self.icon("pin", L("Keep Panel on Top"))
            btn.imagePosition = .imageOnly
            btn.bezelStyle = .texturedRounded
            btn.setButtonType(.pushOnPushOff)
            btn.state = UserDefaults.standard.bool(forKey: AgentPanelModel.floatingKey) ? .on : .off
            btn.target = self
            btn.action = #selector(togglePin)
            it.view = btn
            it.label = L("Keep Panel on Top")
            it.paletteLabel = L("Keep Panel on Top")
            it.toolTip = L("Keep Panel on Top")
            return it
        default:
            return nil
        }
    }

    /// 图标显式缩一档：紧凑工具栏里默认大号会顶到上下边缘（咨询面板 2026-09-01 两次实测）。
    private static func icon(_ symbol: String, _ label: String) -> NSImage? {
        NSImage(systemSymbolName: symbol, accessibilityDescription: label)?
            .withSymbolConfiguration(.init(scale: .small))
    }

    private func menuItem(_ id: NSToolbarItem.Identifier, _ label: String, _ symbol: String, menu name: String) -> NSToolbarItem {
        let it = NSMenuToolbarItem(itemIdentifier: id)
        it.label = label
        it.paletteLabel = label
        it.toolTip = label
        it.image = Self.icon(symbol, label)
        let m = NSMenu()
        m.delegate = self
        m.identifier = NSUserInterfaceItemIdentifier(name)
        menuNeedsUpdate(m)   // 先填一次：空菜单点开什么都没有，看起来就是「按了没反应」
        it.menu = m
        return it
    }

    func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        switch item.itemIdentifier {
        // 正在连 / 正在回放时别再叠一个新会话上去
        case ID.newChat:
            guard let chat else { return false }
            return chat.phase != .connecting && chat.phase != .loading
        default: return chat != nil
        }
    }

    private func refreshPin() {
        let on = UserDefaults.standard.bool(forKey: AgentPanelModel.floatingKey)
        for it in window?.toolbar?.items ?? [] where it.itemIdentifier == ID.pin {
            (it.view as? NSButton)?.state = on ? .on : .off
        }
    }

    // MARK: - 菜单（每次打开时按当前对话重建）

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        switch menu.identifier?.rawValue {
        case "history": fillHistory(menu)
        case "options": fillOptions(menu)
        default: break
        }
    }

    private func fillHistory(_ m: NSMenu) {
        guard let chat else { return }
        if chat.history.isEmpty {
            let none = NSMenuItem(title: L("No earlier chats"), action: nil, keyEquivalent: "")
            none.isEnabled = false
            m.addItem(none)
        }
        for s in chat.history.prefix(30) {
            let it = NSMenuItem(title: AgentChat.sessionLabel(s), action: #selector(loadSession(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = s.sessionId.value
            it.state = s.sessionId.value == chat.sessionId ? .on : .off
            m.addItem(it)
        }
    }

    private func fillOptions(_ m: NSMenu) {
        guard let chat else { return }
        if !chat.modes.isEmpty {
            m.addItem(.sectionHeader(title: L("Mode")))
            for mode in chat.modes {
                let it = NSMenuItem(title: mode.name, action: #selector(selectMode(_:)), keyEquivalent: "")
                it.target = self
                it.representedObject = mode.id
                it.state = mode.id == chat.currentMode ? .on : .off
                it.toolTip = mode.description
                m.addItem(it)
            }
        }
        for item in chat.configs {
            switch item.kind {
            case .select(let current, let options):
                let sub = NSMenu()
                for o in options {
                    let it = NSMenuItem(title: o.name, action: #selector(selectConfig(_:)), keyEquivalent: "")
                    it.target = self
                    it.representedObject = [item.id, o.value]
                    it.state = o.value == current ? .on : .off
                    sub.addItem(it)
                }
                let parent = NSMenuItem(title: item.name, action: nil, keyEquivalent: "")
                parent.submenu = sub
                m.addItem(.separator())
                m.addItem(parent)
            case .toggle(let on):
                let it = NSMenuItem(title: item.name, action: #selector(toggleConfig(_:)), keyEquivalent: "")
                it.target = self
                it.representedObject = [item.id, on ? "0" : "1"]
                it.state = on ? .on : .off
                m.addItem(it)
            }
        }
        m.addItem(.separator())
        let follow = NSMenuItem(title: L("Follow Agent"), action: #selector(toggleFollow), keyEquivalent: "")
        follow.target = self
        follow.state = panel.follow ? .on : .off
        m.addItem(follow)
        m.addItem(.separator())
        let dock = NSMenuItem(title: L("Dock to Reading Window"), action: #selector(toggleDock), keyEquivalent: "")
        dock.target = self
        dock.state = panel.docked ? .on : .off
        m.addItem(dock)
        let inline = NSMenuItem(title: L("Show Inside Reading Window"), action: #selector(showInline), keyEquivalent: "")
        inline.target = self
        m.addItem(inline)
    }

    // MARK: - 动作

    @objc private func newChat() { chat?.newChat() }

    @objc private func loadSession(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, let chat,
              let s = chat.history.first(where: { $0.sessionId.value == id }) else { return }
        chat.load(s)
    }

    @objc private func selectMode(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        chat?.setMode(id)
    }

    @objc private func selectConfig(_ sender: NSMenuItem) {
        guard let pair = sender.representedObject as? [String], pair.count == 2 else { return }
        chat?.setConfig(pair[0], value: pair[1])
    }

    @objc private func toggleConfig(_ sender: NSMenuItem) {
        guard let pair = sender.representedObject as? [String], pair.count == 2 else { return }
        chat?.setConfig(pair[0], flag: pair[1] == "1")
    }

    @objc private func toggleFollow() { panel.setFollow(!panel.follow) }
    @objc private func toggleDock() { panel.setDocked(!panel.docked) }
    @objc private func showInline() { panel.setMode(.inline) }

    /// 置顶与内容层共用同一个 `@AppStorage` 键——那边的 `WindowLevelAccessor` 会把 `NSWindow.level` 跟上。
    @objc private func togglePin() {
        let d = UserDefaults.standard
        d.set(!d.bool(forKey: AgentPanelModel.floatingKey), forKey: AgentPanelModel.floatingKey)
    }
}

/// 独立窗口的内容：controller 选好对话，这里只管显示。
private struct AgentWindowRoot: View {
    @ObservedObject var state: AgentWindowState
    @ObservedObject private var panel = AgentPanelModel.shared
    @AppStorage(AgentPanelModel.floatingKey) private var floating = false

    var body: some View {
        Group {
            if let chat = state.chat, let ctx = panel.windowContext {
                AgentChatView(chat: chat, workspaceName: ctx.workspaceName, showsHeader: false) { EmptyView() }
                    .id(ObjectIdentifier(chat))   // 跟到另一个工作区 → 换一份对话，视图重建
            } else if panel.windowContext == nil {
                ContentUnavailableView(L("No Workspace"), systemImage: "folder",
                                       description: Text(L("Open a workspace to talk to the agent about it.")))
            } else {
                ProgressView()
            }
        }
        .frame(minWidth: 340, minHeight: 360)
        .background(WindowLevelAccessor(floating: floating))
    }
}
