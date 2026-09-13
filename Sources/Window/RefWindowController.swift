import AppKit
import Combine
import SwiftUI

/// 参考窗的**独立窗口形态**（`RefWindowModel.mode == .window`；用户 2026-09-11
/// 「参考小窗支持独立小窗口（类似 AI 窗口那样）」）。
///
/// **一扇阅读窗一份**，归 `ReaderWindowController` 持有并按 model 的 `isOpen`/`mode` 开合——
/// 与 AI 浮窗「全 app 只有一扇」不同：参考窗的状态（开的哪本、滚到哪、独立的 `PDFDocument`）
/// 本来就是每扇阅读窗各一份，独立出来的窗口自然也跟着那扇窗走。
///
/// **做成阅读窗的子窗口**（`addChildWindow`，同 `AIPanelDock` 的做法，但**不贴边、不定位**，
/// 用户摆哪就是哪）：恒在阅读窗之上（点回正文它不会沉到后面去——对照习题/答案时正是这一点），
/// 拖阅读窗它跟着走，阅读窗最小化它一起收。代价是不能把它藏到阅读窗后面，要藏就关掉。
///
/// 🔴 **工具栏由这里建**：SwiftUI 的 `.toolbar` 只作用于 SwiftUI 自己创建的窗口，装进
/// `NSHostingController` 后对 AppKit 窗口不生效（`APPKIT-WINDOW-PLAN.md §5.1`）。
/// 内容（页流）仍是 SwiftUI（`RefDetachedContent`），与覆盖层形态共用同一份 `RefPageStream`。
@MainActor
final class RefWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate {
    private let model: RefWindowModel
    private let workspace: WorkspaceManager
    /// 当前标签在读的那本（「在主视图显示这一页」只在参考的正是它时可用）。
    private let currentDocID: () -> String?
    private let onGotoMain: (Int) -> Void
    private var bag = Set<AnyCancellable>()
    private var popover: NSPopover?
    /// 目录那枚是带 view 的（`NSPopover` 要锚在真实 view 上），拿不到 `validateToolbarItem`，
    /// 启禁由 `refresh()` 推。
    private var contentsButton: NSButton?
    /// 正由 `dismiss()` 主动关窗。`windowWillClose` 靠它分辨「程序关的」还是「用户点了红色关闭钮」。
    private var dismissing = false

    /// 全 app 共用一个 frame 记忆名：「上次摆在哪、多大」是本端偏好，不分哪扇阅读窗。
    private static let frameName = "RefWindow"

    init(model: RefWindowModel, workspace: WorkspaceManager, app: AppModel,
         currentDocID: @escaping () -> String?, onGotoMain: @escaping (Int) -> Void) {
        self.model = model
        self.workspace = workspace
        self.currentDocID = currentDocID
        self.onGotoMain = onGotoMain

        let host = NSHostingController(rootView: RefDetachedContent(model: model)
            .environmentObject(app).environmentObject(workspace))
        // 窗口尺寸归 autosave 与用户拖动，内容只负责填满（`APPKIT-WINDOW-PLAN.md §5.1` 第一条）。
        host.sizingOptions = []
        let win = NSWindow(contentViewController: host)
        win.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        // 紧凑工具栏：标题（文档名 + 页码）与那几枚按钮共一行——小窗口不该拿两行去放标题。
        win.toolbarStyle = .unifiedCompact
        win.titleVisibility = .visible
        win.contentMinSize = RefWindowModel.minSize
        win.isReleasedWhenClosed = false
        win.isRestorable = false
        win.tabbingMode = .disallowed
        // 同阅读窗：后备存储 sRGB = 页图色彩空间，CA 才能直接引用页图缓冲（理由见 `ReaderWindowController`）。
        win.colorSpace = .sRGB
        // 阅读窗全屏时它得能进那个 space，否则一开小窗系统就切回桌面去显示它。
        win.collectionBehavior.insert(.fullScreenAuxiliary)
        win.setFrameAutosaveName(Self.frameName)
        super.init(window: win)

        let tb = NSToolbar(identifier: "ref-window")
        tb.delegate = self
        tb.displayMode = .iconOnly
        win.toolbar = tb
        win.delegate = self

        // 标题/页码/目录可用性跟着 model 走（它只在换书、翻页这类稀疏事件上发布，不是逐帧）。
        model.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &bag)
        // ⌘W / ⇧⌘W 是 App 级菜单命令（阅读窗只在自己是 key 时认领）；这扇窗是 key 时就关它自己。
        for name in [Notification.Name.closeTabRequested, .closeWindowRequested] {
            NotificationCenter.default.publisher(for: name)
                .sink { [weak self] _ in
                    guard let self, self.window?.isKeyWindow == true else { return }
                    self.window?.performClose(nil)
                }
                .store(in: &bag)
        }
        // 参考窗开关的快捷键：这扇窗是 key 时阅读窗认领不到（key 只有一扇），由这里关掉——
        // 只改 model，窗口本身由 `ReaderWindowController` 那条订阅收（同红色关闭钮的路）。
        NotificationCenter.default.publisher(for: .toggleRefWindow)
            .sink { [weak self] _ in
                guard let self, self.window?.isKeyWindow == true, self.model.isOpen else { return }
                self.model.close()
            }
            .store(in: &bag)
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) 不支持") }

    // MARK: - 开合

    /// 上屏并挂到阅读窗底下当子窗口。
    /// 首次（没有 frame 记忆）落在阅读窗**右下角内侧**、用覆盖层记着的尺寸——看起来就是覆盖层
    /// 原地「弹」出来的；之后按记忆。
    func show(attachedTo host: NSWindow?) {
        guard let win = window else { return }
        if !win.isVisible, !win.setFrameUsingName(Self.frameName) {
            let size = model.size
            if let h = host?.frame {
                win.setFrame(NSRect(x: h.maxX - size.width - 24, y: h.minY + 24,
                                    width: size.width, height: size.height), display: false)
            } else {
                win.setContentSize(size)
                win.center()
            }
        }
        if let host, host.isVisible, win.parent !== host {
            win.parent?.removeChildWindow(win)
            host.addChildWindow(win, ordered: .above)
        }
        win.makeKeyAndOrderFront(nil)
    }

    /// 关掉（由 `ReaderWindowController` 在 model 关闭 / 切回覆盖层 / 关阅读窗时调）。
    ///
    /// 🔴 先替页流交还认领：AppKit 直接销毁 hosting 视图，SwiftUI 的 `onDisappear` 来不来没保证，
    /// 不交的话滚轮监视器与 wanted 都会挂着（同 `DocSession.renderClients` 那笔账）。
    /// **只交独立窗口这一份**——切回覆盖层时覆盖层的页流多半已经登记进来了，不能一锅端。
    func dismiss() {
        model.releaseViews(host: .window)
        guard let win = window else { return }
        popover?.performClose(nil)
        win.parent?.removeChildWindow(win)
        dismissing = true
        if win.isVisible { win.close() }   // 用户已经点过红色关闭钮的话，别再发一次 willClose
    }

    /// 用户点了红色关闭钮 / ⌘W：等同覆盖层顶栏的 ✕——关小窗、放掉文件。
    ///
    /// 🔴 **由 `dismiss()` 关的不算**（`dismissing`）：切回覆盖层时 model 仍是开着的（只是形态变了），
    /// 这里若一律按「用户关窗」处理就会顺手 `model.close()`——覆盖层永远出不来、工具栏开关也跟着灭
    /// （用户 2026-09-11 报「点 Show Inside the Window 窗口消失、内部窗口没出现、按钮取消激活」）。
    func windowWillClose(_ notification: Notification) {
        if let win = window { win.parent?.removeChildWindow(win) }
        guard !dismissing, model.isOpen else { return }
        model.close()
    }

    // MARK: - 标题

    private func refresh() {
        guard let win = window else { return }
        win.title = model.title.isEmpty ? L("Reference") : model.title
        win.subtitle = model.pdf.map { "\(model.currentPage + 1) / \($0.pageCount)" } ?? ""
        contentsButton?.isEnabled = !model.toc.isEmpty
    }

    // MARK: - 工具栏
    //
    // 与覆盖层顶栏同一组动作，少了「折叠」「关闭」（系统标题栏自带），多了「改为窗口内置」。
    // 分组：选书/目录一枚胶囊，回到进度/主视图一枚，改回内置单独一枚（组间 `.space`，
    // Tahoe 的合并规则见 `AGENTS.md`）。

    private enum ID {
        static let pick = NSToolbarItem.Identifier("ref.pick")
        static let contents = NSToolbarItem.Identifier("ref.contents")
        static let progress = NSToolbarItem.Identifier("ref.progress")
        static let main = NSToolbarItem.Identifier("ref.main")
        static let inside = NSToolbarItem.Identifier("ref.inside")
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, ID.pick, ID.contents, .space, ID.progress, ID.main, .space, ID.inside]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [ID.pick, ID.contents, ID.progress, ID.main, ID.inside, .space, .flexibleSpace]
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch id {
        case ID.pick:
            let it = NSMenuToolbarItem(itemIdentifier: id)
            it.label = L("Reference")
            it.paletteLabel = L("Reference")
            it.toolTip = L("Pick a document to reference")
            it.image = Self.icon("book", L("Reference"))
            it.menu = pickMenu()
            return it
        case ID.contents:
            return popoverButton(id, L("Contents"), "list.bullet", #selector(showContents(_:)))
        case ID.progress:
            return button(id, L("Back to Progress"), "arrow.uturn.backward", #selector(rewind))
        case ID.main:
            return button(id, L("Show This Page in Main View"), "arrow.up.forward.app", #selector(gotoMain))
        case ID.inside:
            return button(id, L("Show Inside the Window"), "arrow.down.right.and.arrow.up.left",
                          #selector(showInside))
        default:
            return nil
        }
    }

    /// 图标显式定尺寸（`.small`）：紧凑工具栏里默认大号会顶到上下边缘（`AIPanelWindowController` 那笔账）。
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

    /// 要弹面板的那枚得自带一个 `NSButton` 当 view——`NSPopover` 必须锚在真实 view 上，
    /// 标准 `NSToolbarItem` 不把它内部那个按钮交出来（同 `ReaderWindowController.popoverButton`）。
    private func popoverButton(_ id: NSToolbarItem.Identifier, _ label: String,
                               _ symbol: String, _ sel: Selector) -> NSToolbarItem {
        let it = NSToolbarItem(itemIdentifier: id)
        let btn = NSButton(frame: NSRect(x: 0, y: 0, width: 32, height: 24))
        btn.image = Self.icon(symbol, label)
        btn.imagePosition = .imageOnly
        btn.bezelStyle = .texturedRounded
        btn.isBordered = true
        btn.target = self
        btn.action = sel
        btn.isEnabled = !model.toc.isEmpty
        it.view = btn
        it.label = label
        it.paletteLabel = label
        it.toolTip = label
        contentsButton = btn
        return it
    }

    func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        switch item.itemIdentifier {
        case ID.progress: return model.pdf != nil
        case ID.main: return model.docID != nil && model.docID == currentDocID()
        default: return true
        }
    }

    /// 选书菜单按需重建（`NSMenuDelegate`）：工作区文档表会变。
    private func pickMenu() -> NSMenu {
        let m = NSMenu()
        m.delegate = self
        menuNeedsUpdate(m)   // 先填一次：空菜单点开什么都没有，看起来就是「按了没反应」
        return m
    }

    // MARK: 动作

    @objc private func rewind() { model.rewindToProgress(workspace: workspace) }
    @objc private func gotoMain() { onGotoMain(model.currentPage) }
    /// 改回覆盖层：只改 model 的形态，本窗口由 `ReaderWindowController` 按它关掉。
    @objc private func showInside() { model.setMode(.overlay) }

    @objc private func pickDocument(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        model.load(documentId: id, workspace: workspace)
    }

    /// 目录弹窗：内容与覆盖层那份**同一个视图**（`RefTOCPopoverContent`）。
    /// 🔴 `preferredEdge: .maxY`——`NSToolbarItemViewer` 里那个按钮是翻转坐标系，maxY 才是视觉下边
    /// （`APPKIT-WINDOW-PLAN.md §5.1`）；`contentSize` 显式给死，尺寸不定的 popover 定位会跑偏。
    @objc private func showContents(_ sender: NSButton) {
        if let p = popover, p.isShown {
            p.performClose(nil)
            popover = nil
            return
        }
        let vc = NSHostingController(rootView: RefTOCPopoverContent(model: model, onPicked: { [weak self] in
            self?.popover?.performClose(nil)
        }))
        let p = NSPopover()
        p.contentViewController = vc
        p.behavior = .transient
        p.contentSize = vc.view.fittingSize
        popover = p
        p.show(relativeTo: sender.bounds, of: sender, preferredEdge: .maxY)
    }
}

extension RefWindowController: NSMenuDelegate {
    /// 列的是**当前工作区的全部文档**（不只已打开的那几篇），与覆盖层的选书菜单一致。
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        for d in workspace.documents {
            let it = NSMenuItem(title: d.title, action: #selector(pickDocument(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = d.id
            it.state = (d.id == model.docID) ? .on : .off
            menu.addItem(it)
        }
    }
}
