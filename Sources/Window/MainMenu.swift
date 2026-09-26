import AppKit

/// 主菜单（代码构建）。原先是 SwiftUI 的 `.commands { }`，迁移后由这里全权负责
/// （方案 `APPKIT-WINDOW-PLAN.md` §3）。
///
/// **动作仍走 `NotificationCenter` 广播 + key 窗口认领**——与迁移前完全同一套路由，
/// 内容视图那些 `onReceive` 一行不用改。等 M3 再逐条改成第一响应者链（那时 ⌘W 之类
/// 才谈得上「抢快捷键」这个老问题彻底消失）。
@MainActor
enum MainMenu {

    static func install(app: AppModel) {
        MenuActions.shared.app = app
        let main = NSMenu()
        main.addItem(appMenu())
        main.addItem(fileMenu())
        main.addItem(editMenu())
        main.addItem(viewMenu())
        main.addItem(aiMenu())
        main.addItem(windowMenu())
        NSApp.mainMenu = main
        applyShortcuts()
        if shortcutsObserver == nil {
            shortcutsObserver = NotificationCenter.default.addObserver(
                forName: .shortcutsChanged, object: nil, queue: .main
            ) { _ in MainActor.assumeIsolated { applyShortcuts() } }
        }
    }

    // MARK: 可改的快捷键

    /// 可改快捷键的菜单项，按动作登记；设置页改了就地重设 key equivalent，菜单不重建。
    private static var bound: [ShortcutAction: NSMenuItem] = [:]
    private static var shortcutsObserver: Any?

    /// 把映射表里的当前值写到各菜单项上（用户清掉的 → 没有快捷键）。
    static func applyShortcuts() {
        for (action, it) in bound {
            if let c = Shortcuts.shared.combo(for: action) {
                it.keyEquivalent = c.menuKeyEquivalent
                it.keyEquivalentModifierMask = c.mods
            } else {
                it.keyEquivalent = ""
                it.keyEquivalentModifierMask = []
            }
        }
    }

    // MARK: 构件

    /// 容器项（顶层每一项都是「一个带 submenu 的空 item」，AppKit 的规矩）。
    private static func container(_ title: String) -> (NSMenuItem, NSMenu) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let menu = NSMenu(title: title)
        item.submenu = menu
        return (item, menu)
    }

    /// 普通项。`sel` 为 nil = 灰项；`target` 为 nil 时走响应者链（系统动作就靠这个）。
    /// `key`/`mods` 是**固定**快捷键（基础命令）；可改的传 `shortcut:`，值由 `applyShortcuts` 按映射表填。
    private static func item(_ title: String, _ sel: Selector?, key: String = "",
                             mods: NSEvent.ModifierFlags = .command,
                             target: AnyObject? = nil, tag: Int = 0,
                             represented: Any? = nil, shortcut: ShortcutAction? = nil) -> NSMenuItem {
        let it = NSMenuItem(title: title, action: sel, keyEquivalent: key)
        it.keyEquivalentModifierMask = mods
        it.target = target
        it.tag = tag
        it.representedObject = represented
        if let shortcut { bound[shortcut] = it }
        return it
    }

    /// 发通知的项——菜单里绝大多数都是这种。
    private static func post(_ title: String, _ name: Notification.Name,
                             key: String = "", mods: NSEvent.ModifierFlags = .command,
                             shortcut: ShortcutAction? = nil) -> NSMenuItem {
        item(title, #selector(MenuActions.postNotification(_:)), key: key, mods: mods,
             target: MenuActions.shared, represented: name.rawValue, shortcut: shortcut)
    }

    // MARK: 各菜单

    private static func appMenu() -> NSMenuItem {
        let (item0, m) = container("UniReader")
        m.addItem(item(L("About UniReader"), #selector(NSApplication.orderFrontStandardAboutPanel(_:))))
        m.addItem(.separator())
        m.addItem(item(L("Check for Updates…"), #selector(MenuActions.checkForUpdates(_:)),
                       target: MenuActions.shared))
        m.addItem(.separator())
        m.addItem(item(L("Settings…"), #selector(MenuActions.openSettings(_:)), key: ",",
                       target: MenuActions.shared))
        m.addItem(.separator())
        let services = NSMenu(title: L("Services"))
        let servicesItem = NSMenuItem(title: L("Services"), action: nil, keyEquivalent: "")
        servicesItem.submenu = services
        NSApp.servicesMenu = services
        m.addItem(servicesItem)
        m.addItem(.separator())
        m.addItem(item(L("Hide UniReader"), #selector(NSApplication.hide(_:)), key: "h"))
        m.addItem(item(L("Hide Others"), #selector(NSApplication.hideOtherApplications(_:)),
                       key: "h", mods: [.command, .option]))
        m.addItem(item(L("Show All"), #selector(NSApplication.unhideAllApplications(_:))))
        m.addItem(.separator())
        m.addItem(item(L("Quit UniReader"), #selector(NSApplication.terminate(_:)), key: "q"))
        return item0
    }

    private static func fileMenu() -> NSMenuItem {
        let (item0, m) = container(L("File"))
        m.addItem(post(L("New Window"), .newWindowRequested, key: "n"))
        m.addItem(post(L("Open PDF…"), .openPDFRequested, key: "o"))
        m.addItem(post(L("New Tab"), .newTabRequested, key: "t"))
        m.addItem(.separator())
        m.addItem(post(L("New Markdown Note"), .newMarkdownNoteRequested, key: "n", mods: [.command, .shift]))
        m.addItem(post(L("New Board…"), .newBoardRequested, key: "n", mods: [.command, .control]))
        m.addItem(post(L("Import Notes Folder…"), .importMarkdownRequested))
        m.addItem(post(L("Reference Notes Folder…"), .referenceMarkdownRequested))
        m.addItem(.separator())
        // 最近打开：内容随 registry 变，交给 delegate 在展开前重建（见 `RecentMenuDelegate`）。
        let recent = NSMenuItem(title: L("Open Recent"), action: nil, keyEquivalent: "")
        let recentMenu = NSMenu(title: L("Open Recent"))
        recentMenu.delegate = MenuActions.shared.recentDelegate
        recent.submenu = recentMenu
        m.addItem(recent)
        m.addItem(.separator())
        // 兜底那两套（`BACKUP-PLAN.md`）：误删找回来、库回到某个时间点。
        m.addItem(post(L("Recently Deleted…"), .workspaceTrashRequested))
        m.addItem(post(L("Workspace Backups…"), .workspaceBackupsRequested))
        m.addItem(.separator())
        m.addItem(post(L("Close Tab"), .closeTabRequested, key: "w"))
        m.addItem(post(L("Close Window"), .closeWindowRequested, key: "w", mods: [.command, .shift]))
        m.addItem(post(L("Next Tab"), .nextTabRequested, key: "\t", mods: .control))
        m.addItem(post(L("Previous Tab"), .prevTabRequested, key: "\t", mods: [.control, .shift]))
        return item0
    }

    /// 剪贴板五项**不能只连响应者链**：阅读区是纯 SwiftUI、不在响应链上，系统的 Copy/Select All
    /// 永远是灰的。做法与迁移前一致——先 `sendAction` 试响应链（文本框、AI 面板的 WebView 都会接），
    /// 没人接才发通知给阅读区（`sendAction` 的返回值正好当分流开关，2026-08-26 那笔账）。
    private static func editMenu() -> NSMenuItem {
        let (item0, m) = container(L("Edit"))
        // 撤销/重做同样是「先响应者链、没人接才给阅读区」，只是判据反过来：焦点确实在文本框/网页里
        // 才让给系统（它们各有各的 undoManager），否则一律归阅读区的编辑撤销栈（`InkUndoStack`）。
        m.addItem(item(L("Undo"), #selector(MenuActions.undo(_:)), key: "z", target: MenuActions.shared))
        m.addItem(item(L("Redo"), #selector(MenuActions.redo(_:)), key: "z",
                       mods: [.command, .shift], target: MenuActions.shared))
        m.addItem(.separator())
        m.addItem(item(L("Cut"), #selector(MenuActions.cut(_:)), key: "x", target: MenuActions.shared))
        m.addItem(item(L("Copy"), #selector(MenuActions.copy(_:)), key: "c", target: MenuActions.shared))
        m.addItem(item(L("Paste"), #selector(MenuActions.paste(_:)), key: "v", target: MenuActions.shared))
        m.addItem(item(L("Delete"), #selector(MenuActions.delete(_:)), target: MenuActions.shared))
        m.addItem(item(L("Select All"), #selector(MenuActions.selectAll(_:)), key: "a",
                       target: MenuActions.shared))
        m.addItem(.separator())
        m.addItem(post(L("Find…"), .readerFind, key: "f"))
        return item0
    }

    private static func viewMenu() -> NSMenuItem {
        let (item0, m) = container(L("View"))
        // 这一整个菜单的快捷键都可改（默认值见 `ShortcutAction.defaultCombo`，设置 › 快捷键）。
        m.addItem(post(L("Toggle Sidebar"), .toggleSidebar, shortcut: .toggleSidebar))
        m.addItem(post(L("Toggle Inspector"), .toggleInspector, shortcut: .toggleInspector))
        // 参考窗开关：与工具栏那枚同一条路（key 窗口认领；独立窗口形态下它自己是 key 时由它关自己）。
        m.addItem(post(L("Reference Window"), .toggleRefWindow, shortcut: .refWindow))
        m.addItem(.separator())
        m.addItem(post(L("Zoom In"), .readerZoomIn, shortcut: .zoomIn))
        m.addItem(post(L("Zoom Out"), .readerZoomOut, shortcut: .zoomOut))
        m.addItem(post(L("Zoom to Fit Width"), .readerZoomFit, shortcut: .zoomFit))
        m.addItem(.separator())
        // 跳转历史（`JumpHistory`）：默认 ⌘[ / ⌘] 是浏览器/Xcode 的通用口径；
        // 浮窗开关默认 ⌥⌘J —— ⌥⌘H 是系统的「隐藏其他」，抢不得。
        // 书签：默认 ⌘D 在**当前阅读位置**加一枚（落点更精确的那条入口是阅读区右键「在此添加书签」）。
        m.addItem(post(L("Add Bookmark"), .addBookmarkRequested, shortcut: .addBookmark))
        m.addItem(.separator())
        m.addItem(post(L("Back to Previous Position"), .jumpBackRequested, shortcut: .jumpBack))
        m.addItem(post(L("Forward to Next Position"), .jumpForwardRequested, shortcut: .jumpForward))
        m.addItem(post(L("Jump History"), .toggleJumpHistory, shortcut: .jumpHistory))
        // 跳转到指定页：默认 ⌃G（用户 2026-09-21 指定）。⌘G 是系统的「查找下一个」口径，不占。
        m.addItem(post(L("Go to Page…"), .gotoPageRequested, shortcut: .gotoPage))
        m.addItem(.separator())
        m.addItem(item(L("Customize Toolbar…"), #selector(MenuActions.customizeToolbar(_:)),
                       key: "", mods: [], target: MenuActions.shared))
        m.addItem(.separator())
        // 笔架/模式（设备级全局状态，直接调 AppModel——与画布笔架、平板环形盘同一套 apply 路径）
        for i in 0..<4 {
            m.addItem(item(String(format: L("Pen Slot %d"), i + 1),
                           #selector(MenuActions.penSlot(_:)),
                           target: MenuActions.shared, tag: i, shortcut: .penSlot(i)))
        }
        m.addItem(item(L("Eraser"), #selector(MenuActions.padMode(_:)),
                       target: MenuActions.shared, represented: "erase", shortcut: .eraser))
        m.addItem(item(L("Page Turn"), #selector(MenuActions.padMode(_:)),
                       target: MenuActions.shared, represented: "page", shortcut: .pageTurn))
        m.addItem(item(L("Write"), #selector(MenuActions.padMode(_:)),
                       target: MenuActions.shared, represented: "note", shortcut: .write))
        m.addItem(.separator())
        m.addItem(post(L("Night Mode"), .toggleNightMode, shortcut: .nightMode))
        m.addItem(post(L("Canvas Mode"), .toggleCanvasMode, shortcut: .canvasMode))
        // 扫描页对齐（`SCAN-ALIGN-PLAN.md`）：按文件记、不常切，不配默认快捷键。勾选状态见 `validateMenuItem`。
        m.addItem(post(L("Align Scanned Pages"), .toggleScanAlign))
        // 扫描页增强（`ScanEnhance`）：按文档记在本机，参数在设置 ›「阅读」
        m.addItem(post(L("Enhance Scanned Pages"), .toggleScanEnhance))
        return item0
    }

    private static func aiMenu() -> NSMenuItem {
        let (item0, m) = container(L("AI"))
        if AIPanelModel.available {   // 网页 AI 停用期间不给入口（`AIPanelModel.available`）
            m.addItem(item(L("AI Panel"), #selector(MenuActions.aiPanel(_:)),
                           target: MenuActions.shared, shortcut: .aiPanel))
        }
        m.addItem(item(L("Agent Panel"), #selector(MenuActions.agentPanel(_:)),
                       target: MenuActions.shared, shortcut: .agentPanel))
        m.addItem(.separator())
        m.addItem(post(L("Snip to AI"), .toggleSnipTool, shortcut: .snipToAI))
        return item0
    }

    private static func windowMenu() -> NSMenuItem {
        let (item0, m) = container(L("Window"))
        m.addItem(item(L("Minimize"), #selector(NSWindow.performMiniaturize(_:)), key: "m"))
        m.addItem(item(L("Zoom"), #selector(NSWindow.performZoom(_:))))
        m.addItem(.separator())
        m.addItem(item(L("Bring All to Front"), #selector(NSApplication.arrangeInFront(_:))))
        NSApp.windowsMenu = m   // 系统会把窗口列表自动续在后面
        return item0
    }
}

/// 菜单动作的接收者（`@objc` selector 得挂在一个对象上）。
@MainActor
final class MenuActions: NSObject {
    static let shared = MenuActions()
    var app: AppModel!
    let recentDelegate = RecentMenuDelegate()

    @objc func postNotification(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String else { return }
        NotificationCenter.default.post(name: Notification.Name(raw), object: nil)
    }

    @objc func openSettings(_ sender: Any?) { SettingsWindowController.show() }

    @objc func checkForUpdates(_ sender: Any?) { UpdaterService.shared.checkForUpdates() }

    @objc func customizeToolbar(_ sender: Any?) {
        NSApp.keyWindow?.toolbar?.runCustomizationPalette(sender)
    }

    @objc func penSlot(_ sender: NSMenuItem) {
        guard app.pens.count > sender.tag else { return }
        app.applyPenSelection(index: sender.tag)
    }

    @objc func padMode(_ sender: NSMenuItem) {
        guard let mode = sender.representedObject as? String else { return }
        app.setPadMode(mode)
    }

    @objc func aiPanel(_ sender: Any?) {
        // 内置模式下 ⌘⇧A 是展开/收起那块侧面板，而不是凭空开一扇窗（那扇窗此刻不该存在）。
        // 浮窗模式下是**显示/隐藏**（用户 2026-09-13）：隐藏只是把窗口撤下屏幕，网页与对话都还在，再按就回来。
        guard AIPanelModel.shared.enabled else { return }
        if AIPanelModel.shared.mode == .inline { AIPanelModel.shared.toggleInlineActive() }
        else { AIPanelWindowController.toggle() }
    }

    /// Agent 面板（`ACP-AGENT-PLAN.md`）：当前 key 阅读窗口的 Inspector「Agent」页开 ⇄ 收。
    @objc func agentPanel(_ sender: Any?) { AgentPanelModel.shared.toggle() }

    // MARK: 剪贴板五项（先响应者链，没人接才给阅读区）
    //
    // 五项的对象在阅读区里都是**框选选中集**（笔迹 + 文字注解），见 `ReaderSurface+InkClip`；
    // ⌘C 例外，它先给选中集、没有选中集才退回「复制选中的文字」。

    @objc func cut(_ sender: Any?) { route(#selector(NSText.cut(_:)), to: .readerCut, sender: sender) }
    @objc func paste(_ sender: Any?) { route(#selector(NSText.paste(_:)), to: .readerPaste, sender: sender) }
    @objc func delete(_ sender: Any?) { route(#selector(NSText.delete(_:)), to: .readerDelete, sender: sender) }
    @objc func copy(_ sender: Any?) { route(#selector(NSText.copy(_:)), to: .readerCopy, sender: sender) }

    /// 先响应者链，没人接才把动作发给阅读区。
    /// 那行打点是给「⌘V 一点反应都没有」这种**静默失效**留的：第一眼要看的就是这次动作到底被谁吃了
    /// （默认关，`touch ~/Library/Logs/UniReader-pad.log` 开）。
    private func route(_ sel: Selector, to fallback: Notification.Name, sender: Any?) {
        let accepted = NSApp.sendAction(sel, to: nil, from: sender)
        PadLog.log("Edit 菜单 \(NSStringFromSelector(sel)) → \(accepted ? "响应者链" : "阅读区")")
        if !accepted { NotificationCenter.default.post(name: fallback, object: nil) }
    }

    // MARK: 撤销 / 重做

    /// 🔴 与上面五项**反着来**：先判焦点，而不是先 `sendAction`。
    /// `undo:` 会被响应者链上不少东西认领（文本框的字段编辑器、WKWebView），SwiftUI 还可能在窗口上
    /// 挂一个自己的 `UndoManager` —— 先发出去就等于把阅读区的撤销永远交出去了。焦点确实在能编辑
    /// 文本的地方才让给系统，其余一律路由给阅读区/草稿纸。
    @objc func undo(_ sender: Any?) { dispatchUndo(redo: false, sender: sender) }
    @objc func redo(_ sender: Any?) { dispatchUndo(redo: true, sender: sender) }

    private func dispatchUndo(redo: Bool, sender: Any?) {
        PadLog.log("Edit 菜单 \(redo ? "重做" : "撤销") → \(MenuActions.textEditingHasFocus ? "响应者链" : "阅读区")")
        if MenuActions.textEditingHasFocus {
            NSApp.sendAction(Selector(redo ? "redo:" : "undo:"), to: nil, from: sender)
            return
        }
        NotificationCenter.default.post(name: redo ? .readerRedo : .readerUndo, object: nil)
    }

    /// 焦点是不是落在「自己能撤销」的东西上：文本框的字段编辑器 / 内置 AI 面板的网页。
    static var textEditingHasFocus: Bool {
        NSApp.keyWindow?.firstResponder is NSText || aiWebInputHasFocus()
    }

    /// 当前 key 窗口那个标签的会话（撤销菜单项的可用性/标题要问它）。
    private var activeSession: DocSession? {
        app.sessions.first { $0.id == app.activeSessionID }
    }

    @objc func selectAll(_ sender: Any?) {
        if !NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: sender) {
            NotificationCenter.default.post(name: .readerSelectAll, object: nil)
        }
    }

    @objc func openRecentWorkspace(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        AppDelegate.deliverWorkspace(path)
    }

    @objc func clearRecents(_ sender: Any?) { WorkspaceRegistry.shared.clearRecents() }
}

/// 撤销/重做两项的可用性与标题（系统在菜单展开、以及按下快捷键前会调）。其余项一律放行。
/// 标题跟着栈顶那一步走（「撤销 移动」/「撤销 擦除」），与系统 App 的惯例一致。
extension MenuActions: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(undo(_:)): return validateUndoItem(menuItem, redo: false)
        case #selector(redo(_:)): return validateUndoItem(menuItem, redo: true)
        // 设置里关掉的 AI 功能：菜单项灰掉（快捷键随之失效）
        case #selector(aiPanel(_:)): return AIPanelModel.shared.enabled
        case #selector(agentPanel(_:)): return AgentPanelModel.shared.enabled
        case #selector(postNotification(_:))
            where menuItem.representedObject as? String == Notification.Name.toggleScanAlign.rawValue:
            // 勾 = 当前文档开着对齐；没开文档时灰掉
            let s = activeSession
            menuItem.state = s?.scanAlign != nil ? .on : .off
            return s?.pdf != nil
        case #selector(postNotification(_:))
            where menuItem.representedObject as? String == Notification.Name.toggleScanEnhance.rawValue:
            let s = activeSession
            menuItem.state = ScanEnhance.isOn(s?.contentHash ?? "") ? .on : .off
            return s?.pdf != nil && !(s?.contentHash.isEmpty ?? true)
        case #selector(postNotification(_:))
            where menuItem.representedObject as? String == Notification.Name.gotoPageRequested.rawValue:
            return activeSession?.pdf != nil   // 空标签 / Markdown 笔记没有「第几页」可言
        default: return true
        }
    }

    private func validateUndoItem(_ item: NSMenuItem, redo: Bool) -> Bool {
        let base = redo ? L("Redo") : L("Undo")
        // 焦点在文本框/网页里：标题回到中性的那两个字，可用性交给系统（它自己知道有没有得撤）。
        guard !MenuActions.textEditingHasFocus else { item.title = base; return true }
        let stack = activeSession?.activeUndo
        let label = redo ? stack?.redoLabel : stack?.undoLabel
        item.title = label.map { "\(base) \(L($0))" } ?? base
        return label != nil
    }
}

/// 「最近打开」子菜单：**展开前重建**。
///
/// 迁移前这里是个 SwiftUI `View`（`OpenRecentMenu`），得靠 `@ObservedObject` 才能在 recents
/// 变化后重建菜单项；AppKit 这边直接在 `menuNeedsUpdate` 里现算，反而简单——菜单只有被打开的
/// 那一刻才需要正确。
@MainActor
final class RecentMenuDelegate: NSObject, NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let registry = WorkspaceRegistry.shared
        for r in registry.recents {
            let it = NSMenuItem(title: r.name,
                                action: #selector(MenuActions.openRecentWorkspace(_:)), keyEquivalent: "")
            it.target = MenuActions.shared
            it.representedObject = WorkspaceRegistry.resolveOrSource(r).path
            it.image = NSImage(systemSymbolName: WorkspaceRegistry.opensOffline(r)
                               ? "externaldrive.badge.timemachine" : "folder",
                               accessibilityDescription: nil)
            menu.addItem(it)
        }
        if !registry.recents.isEmpty { menu.addItem(.separator()) }
        // 空列表时不隐藏而是灰掉：菜单能展开、用户看得见「确实空了」，与系统 Clear Menu 一致。
        let clear = NSMenuItem(title: L("Clear Recent"),
                               action: #selector(MenuActions.clearRecents(_:)), keyEquivalent: "")
        clear.target = MenuActions.shared
        clear.isEnabled = !registry.recents.isEmpty
        menu.addItem(clear)
    }
}
