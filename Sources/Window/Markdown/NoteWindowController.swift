import AppKit
import Combine

/// Markdown 笔记小窗（用户 2026-09-24「方便编辑笔记，类似参考窗口那样」）：一扇独立的小窗口，里面就是
/// 整篇笔记的编辑区（`MarkdownDocView`，不带它自己那行标题——窗口标题栏已经写着了）。
///
/// - **按笔记绑定**：一扇小窗对应一篇笔记，同一扇阅读窗里同一篇最多一扇（再开 = 把那扇提到前面，
///   由 `ReaderWindowController.openNoteWindow` 保证）；不同小窗开不同笔记，可以同时开好几扇。
/// - **可以换**：工具栏的笔记菜单手动选一篇（同参考窗的选书菜单）；正文里点 `[[…]]` 也是在这扇小窗里换过去。
///   要换去的那篇已经开在另一扇小窗里时，不换，改为把那扇提到前面（绑定不重复）。
/// - **阅读窗的子窗口**（同参考窗独立窗口，`RefWindowController`）：恒在阅读窗之上、跟着它走、随它最小化；
///   关阅读窗时一起关。开着没有不记（冷启动不自动弹），位置 / 大小按笔记记（frame autosave）。
/// - 保存与标签页里的编辑区完全一样（停手 0.8 秒 / 离开窗口 / 退出）；同一篇同时开在标签页和小窗里，
///   一边存了另一边跟着换（`.markdownNoteSavedInApp`）。
@MainActor
final class NoteWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate, NSMenuDelegate {
    private(set) var ref: NoteRef
    private let workspace: WorkspaceManager
    private var editor: MarkdownDocView
    private var bag = Set<AnyCancellable>()

    /// 要换到某篇：返回 true = 可以在这扇里换；false = 调用方已另行处理（那篇开在别的小窗里，已提到前面）。
    var canSwitch: (NoteRef) -> Bool = { _ in true }
    /// 「在标签页中打开」。
    var onOpenInTab: (NoteRef) -> Void = { _ in }
    /// 窗口关了（交给持有者从登记表里摘掉）。
    var onClose: (NoteWindowController) -> Void = { _ in }

    static let defaultSize = NSSize(width: 460, height: 560)

    init(ref: NoteRef, workspace: WorkspaceManager) {
        self.ref = ref
        self.workspace = workspace
        editor = MarkdownDocView(ref: ref, workspace: workspace, showsHeader: false)
        let win = NSWindow(contentRect: NSRect(origin: .zero, size: Self.defaultSize),
                           styleMask: [.titled, .closable, .miniaturizable, .resizable],
                           backing: .buffered, defer: false)
        win.toolbarStyle = .unifiedCompact
        win.titleVisibility = .visible
        win.contentMinSize = NSSize(width: 280, height: 200)
        win.isReleasedWhenClosed = false
        win.isRestorable = false
        win.tabbingMode = .disallowed
        win.collectionBehavior.insert(.fullScreenAuxiliary)   // 阅读窗全屏时也能进那个 space
        win.contentView = editor
        super.init(window: win)

        let tb = NSToolbar(identifier: "note-window")
        tb.delegate = self
        tb.displayMode = .iconOnly
        win.toolbar = tb
        win.delegate = self
        wireEditor()

        // 笔记改名 / 被删：标题跟着变；这篇没了就关掉（编辑区的自动保存已不会在旧路径上把它建回来）
        workspace.$noteTrees
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.noteTreeChanged() }
            .store(in: &bag)
        // ⌘W 是 App 级菜单命令（阅读窗只在自己是 key 时认领）；这扇是 key 时关它自己
        for name in [Notification.Name.closeTabRequested, .closeWindowRequested] {
            NotificationCenter.default.publisher(for: name)
                .sink { [weak self] _ in
                    guard let self, self.window?.isKeyWindow == true else { return }
                    self.window?.performClose(nil)
                }
                .store(in: &bag)
        }
        syncTitle()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) 不支持") }

    private var frameName: String { "NoteWindow-\(ref.key)" }

    // MARK: - 开合

    /// 上屏并挂到阅读窗底下当子窗口。首次（这篇没有位置记忆）落在阅读窗右侧内侧。
    func show(attachedTo host: NSWindow?) {
        guard let win = window else { return }
        if !win.isVisible, !win.setFrameUsingName(frameName) {
            let s = Self.defaultSize
            if let h = host?.frame {
                win.setFrame(NSRect(x: h.maxX - s.width - 32, y: h.maxY - s.height - 80,
                                    width: s.width, height: s.height), display: false)
            } else {
                win.center()
            }
        }
        win.setFrameAutosaveName(frameName)
        if let host, host.isVisible, win.parent !== host {
            win.parent?.removeChildWindow(win)
            host.addChildWindow(win, ordered: .above)
        }
        win.makeKeyAndOrderFront(nil)
    }

    /// 关阅读窗时由持有者调：先存再关。
    func dismiss() {
        editor.flush()
        guard let win = window else { return }
        win.parent?.removeChildWindow(win)
        if win.isVisible { win.close() }
    }

    func windowWillClose(_ notification: Notification) {
        editor.flush()
        if let win = window { win.parent?.removeChildWindow(win) }
        onClose(self)
    }

    // MARK: - 换笔记

    func switchTo(_ target: NoteRef) {
        guard target != ref, workspace.note(ref: target) != nil, canSwitch(target) else { return }
        editor.flush()
        ref = target
        let next = MarkdownDocView(ref: target, workspace: workspace, showsHeader: false)
        editor = next
        wireEditor()
        window?.contentView = next      // 旧的离开窗口时自己再补存一次（无改动则空操作）
        window?.setFrameAutosaveName(frameName)
        workspace.noteWasOpened(target)
        syncTitle()
    }

    private func wireEditor() {
        // 正文里点 `[[…]]`：就在这扇小窗里换过去
        editor.onOpenNote = { [weak self] target in
            guard let self, let item = self.workspace.note(key: target) else { return }
            self.switchTo(item.ref)
        }
    }

    private func noteTreeChanged() {
        guard workspace.note(ref: ref) != nil else {
            wsLog("[MD] 小窗那篇已不在（\(ref.key)），关窗")
            window?.close()
            return
        }
        syncTitle()
    }

    private func syncTitle() {
        guard let win = window else { return }
        win.title = ref.title
        let src = workspace.noteSource(id: ref.sourceID)?.name ?? ""
        let path = src.isEmpty ? ref.relPath : "\(src)/\(ref.relPath)"
        if win.subtitle != path { win.subtitle = path }
    }

    // MARK: - 工具栏：笔记菜单 · 在标签页中打开

    private enum ID {
        static let pick = NSToolbarItem.Identifier("note.pick")
        static let tab = NSToolbarItem.Identifier("note.tab")
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, ID.pick, .space, ID.tab]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [ID.pick, ID.tab, .space, .flexibleSpace]
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch id {
        case ID.pick:
            let it = NSMenuToolbarItem(itemIdentifier: id)
            it.label = L("Notes")
            it.paletteLabel = L("Notes")
            it.toolTip = L("Pick a note to edit here")
            it.image = Self.icon("doc.text", L("Notes"))
            let m = NSMenu()
            m.delegate = self
            menuNeedsUpdate(m)   // 先填一次：空菜单点开什么都没有，看起来就是「按了没反应」
            it.menu = m
            return it
        case ID.tab:
            let label = L("Open in Tab")
            let it = NSToolbarItem(itemIdentifier: id)
            it.label = label
            it.paletteLabel = label
            it.toolTip = label
            it.image = Self.icon("arrow.up.forward.app", label)
            it.target = self
            it.action = #selector(openInTab)
            it.isBordered = true
            return it
        default:
            return nil
        }
    }

    /// 图标显式定尺寸（`.small`）：紧凑工具栏里默认大号会顶到上下边缘（同 `RefWindowController`）。
    private static func icon(_ symbol: String, _ label: String) -> NSImage? {
        NSImage(systemSymbolName: symbol, accessibilityDescription: label)?
            .withSymbolConfiguration(.init(scale: .small))
    }

    @objc private func openInTab() {
        editor.flush()
        onOpenInTab(ref)
    }

    /// 笔记菜单按需重建：每个源一段（段名做标题），目录是子菜单，层级同侧栏。
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        for section in workspace.noteTrees where section.root.noteCount > 0 {
            if menu.numberOfItems > 0 { menu.addItem(.separator()) }
            menu.addItem(.sectionHeader(title: section.source.name))
            fill(menu, with: section.root)
        }
        if menu.numberOfItems == 0 {
            let empty = NSMenuItem(title: L("No Notes"), action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        }
    }

    private func fill(_ menu: NSMenu, with folder: NoteFolder) {
        for sub in folder.folders where sub.noteCount > 0 {   // 只有空目录的子树不列（点开是空菜单）
            let it = NSMenuItem(title: sub.name, action: nil, keyEquivalent: "")
            it.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
            let m = NSMenu()
            fill(m, with: sub)
            it.submenu = m
            menu.addItem(it)
        }
        for note in folder.notes {
            let r = note.ref
            let it = ClosureMenuItem(note.title) { [weak self] in self?.switchTo(r) }
            it.state = r == ref ? .on : .off
            menu.addItem(it)
        }
    }
}
