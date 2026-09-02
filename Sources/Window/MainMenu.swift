import AppKit
import SwiftUI

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
    private static func item(_ title: String, _ sel: Selector?, key: String = "",
                             mods: NSEvent.ModifierFlags = .command,
                             target: AnyObject? = nil, tag: Int = 0,
                             represented: Any? = nil) -> NSMenuItem {
        let it = NSMenuItem(title: title, action: sel, keyEquivalent: key)
        it.keyEquivalentModifierMask = mods
        it.target = target
        it.tag = tag
        it.representedObject = represented
        return it
    }

    /// 发通知的项——菜单里绝大多数都是这种。
    private static func post(_ title: String, _ name: Notification.Name,
                             key: String = "", mods: NSEvent.ModifierFlags = .command) -> NSMenuItem {
        item(title, #selector(MenuActions.postNotification(_:)), key: key, mods: mods,
             target: MenuActions.shared, represented: name.rawValue)
    }

    // MARK: 各菜单

    private static func appMenu() -> NSMenuItem {
        let (item0, m) = container("UniReader")
        m.addItem(item(L("About UniReader"), #selector(NSApplication.orderFrontStandardAboutPanel(_:))))
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
        // 最近打开：内容随 registry 变，交给 delegate 在展开前重建（见 `RecentMenuDelegate`）。
        let recent = NSMenuItem(title: L("Open Recent"), action: nil, keyEquivalent: "")
        let recentMenu = NSMenu(title: L("Open Recent"))
        recentMenu.delegate = MenuActions.shared.recentDelegate
        recent.submenu = recentMenu
        m.addItem(recent)
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
        m.addItem(post(L("Toggle Sidebar"), .toggleSidebar, key: "b"))
        m.addItem(post(L("Toggle Inspector"), .toggleInspector, key: "i"))
        m.addItem(.separator())
        m.addItem(post(L("Zoom In"), .readerZoomIn, key: "="))
        m.addItem(post(L("Zoom Out"), .readerZoomOut, key: "-"))
        m.addItem(post(L("Zoom to Fit Width"), .readerZoomFit, key: "0"))
        m.addItem(.separator())
        // 跳转历史（`JumpHistory`）：⌘[ / ⌘] 是浏览器/Xcode 的通用口径；
        // 浮窗开关用 ⌥⌘J —— ⌥⌘H 是系统的「隐藏其他」，抢不得。
        // 书签：⌘D 在**当前阅读位置**加一枚（落点更精确的那条入口是阅读区右键「在此添加书签」）。
        m.addItem(post(L("Add Bookmark"), .addBookmarkRequested, key: "d"))
        m.addItem(.separator())
        m.addItem(post(L("Back to Previous Position"), .jumpBackRequested, key: "["))
        m.addItem(post(L("Forward to Next Position"), .jumpForwardRequested, key: "]"))
        m.addItem(post(L("Jump History"), .toggleJumpHistory, key: "j", mods: [.command, .option]))
        m.addItem(.separator())
        m.addItem(item(L("Customize Toolbar…"), #selector(MenuActions.customizeToolbar(_:)),
                       key: "", mods: [], target: MenuActions.shared))
        m.addItem(.separator())
        // 笔架/模式（设备级全局状态，直接调 AppModel——与画布笔架、平板环形盘同一套 apply 路径）
        for i in 0..<4 {
            m.addItem(item(String(format: L("Pen Slot %d"), i + 1),
                           #selector(MenuActions.penSlot(_:)), key: "\(i + 1)", mods: .option,
                           target: MenuActions.shared, tag: i))
        }
        m.addItem(item(L("Eraser"), #selector(MenuActions.padMode(_:)), key: "e", mods: .option,
                       target: MenuActions.shared, represented: "erase"))
        m.addItem(item(L("Page Turn"), #selector(MenuActions.padMode(_:)), key: "v", mods: .option,
                       target: MenuActions.shared, represented: "page"))
        m.addItem(item(L("Write"), #selector(MenuActions.padMode(_:)), key: "b", mods: .option,
                       target: MenuActions.shared, represented: "note"))
        m.addItem(.separator())
        m.addItem(post(L("Night Mode"), .toggleNightMode, key: "n", mods: [.command, .option]))
        m.addItem(post(L("Canvas Mode"), .toggleCanvasMode, key: "c", mods: [.command, .option]))
        return item0
    }

    private static func aiMenu() -> NSMenuItem {
        let (item0, m) = container(L("AI"))
        m.addItem(item(L("AI Panel"), #selector(MenuActions.aiPanel(_:)), key: "a",
                       mods: [.command, .shift], target: MenuActions.shared))
        m.addItem(.separator())
        m.addItem(post(L("Snip to AI"), .toggleSnipTool, key: "s", mods: .option))
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
        if AIPanelModel.shared.mode == .inline { AIPanelModel.shared.toggleInlineActive() }
        else { AIPanelWindowController.show() }
    }

    // MARK: 剪贴板五项（先响应者链，没人接才给阅读区）

    @objc func cut(_ sender: Any?) { NSApp.sendAction(#selector(NSText.cut(_:)), to: nil, from: sender) }
    @objc func paste(_ sender: Any?) { NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: sender) }
    @objc func delete(_ sender: Any?) { NSApp.sendAction(#selector(NSText.delete(_:)), to: nil, from: sender) }

    @objc func copy(_ sender: Any?) {
        if !NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: sender) {
            NotificationCenter.default.post(name: .readerCopy, object: nil)
        }
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
