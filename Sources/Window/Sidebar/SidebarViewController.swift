import AppKit
import Combine

/// 侧栏（AppKit 版，替代 SwiftUI `SidebarView`，行为逐条同原版）：
///  · 当前工作区的文档列表，`NSOutlineView` 源列表样式；有分组时按分组分段（未分组在前）；
///  · 多选（⌘ / ⇧ 点）；恰选一篇时打开它（已开着就切过去，没开就新建标签）；
///  · 右键：在新窗口打开 / 上移下移（同一分组段内、多选整批）/ 移到分组 / 在 Finder 显示 / 移出或拷进工作区 /
///    关联为同一文档 / 删除；分组段头右键：改名 / 删除分组；
///  · **行级拖拽一概没有**（2026-09-03 用户否决三版拖拽排序，理由与踩坑记在 SwiftUI 版注释里）；
///    只接受从 Finder 拖 PDF 进来；
///  · 顶部一条离线副本提示（源盘插回 / 副本有东西没合回），只提示不打断。
@MainActor
final class SidebarViewController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate {
    let tabs: TabsModel
    let workspace: WorkspaceManager
    private let registry = WorkspaceRegistry.shared
    var onChooseWorkspace: () -> Void = {}
    var onCreateWorkspace: () -> Void = {}
    var onOpenRecent: (URL) -> Void = { _ in }
    var onDropFiles: ([URL]) -> Void = { _ in }
    var onOpenPDF: () -> Void = {}
    var onOpenInNewWindow: (String) -> Void = { _ in }

    private let outline = NSOutlineView()
    private let scroll = NSScrollView()
    private var roots: [SidebarNode] = []
    private var syncingSelection = false
    /// 笔记目录的展开状态（`"<源 id>:<目录相对路径>"`）。**默认全收起**，记住用户自己展开过的那些
    /// （2026-09-20 用户提：「展开不要默认，可以记忆之前的打开状态」）。
    /// 存 UserDefaults 按工作区分键——这是本机界面状态，不进库、不跟着离线镜像走。
    private var expandedFolders: Set<String> = []
    /// 正在按记忆恢复展开状态：这期间 AppKit 发回来的展开/收起通知不算数，别把记忆覆盖了。
    private var restoringExpansion = false
    private var bag = Set<AnyCancellable>()
    private var observers: [NSObjectProtocol] = []

    // 离线副本提示（逻辑同原版 `refreshNotice`：一次只跑一趟，期间来的请求记一笔跑完补；卷变了按纪元号丢结果）
    enum Notice { case sourceBack(URL, Int?), unsynced(URL, Int) }
    private var notice: Notice?
    private var noticeBusy = false
    private var noticePending = false
    private var noticeEpoch = 0

    init(tabs: TabsModel, workspace: WorkspaceManager) {
        self.tabs = tabs
        self.workspace = workspace
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) 不支持") }

    override func loadView() {
        outline.style = .sourceList
        outline.headerView = nil
        outline.allowsMultipleSelection = true
        outline.floatsGroupRows = false
        outline.rowSizeStyle = .default
        outline.backgroundColor = .clear
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("main"))
        outline.addTableColumn(col)
        outline.outlineTableColumn = col
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.action = #selector(rowClicked)
        let menu = NSMenu()
        menu.delegate = self
        outline.menu = menu
        outline.registerForDraggedTypes([.fileURL])
        outline.setDraggingSourceOperationMask([], forLocal: true)
        scroll.documentView = outline
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        view = scroll
        installObservers()
        reload()
        refreshNotice()
    }

    // MARK: 订阅

    private func installObservers() {
        loadExpanded()
        workspace.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.reload() }
            .store(in: &bag)
        registry.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.checkMissingRecent() }
            .store(in: &bag)
        tabs.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.syncSelectionFromTabs() }
            .store(in: &bag)
        workspace.$folder
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshNotice() }
            .store(in: &bag)
        workspace.$documents
            .map(\.count)
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshNotice() }   // 加书 / 删书当场推过去
            .store(in: &bag)
        let nc = NotificationCenter.default
        func on(_ name: Notification.Name, _ f: @escaping (SidebarViewController, Notification) -> Void) {
            observers.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] n in
                MainActor.assumeIsolated { if let self { f(self, n) } }
            })
        }
        // 菜单（工具栏里的工作区菜单）发来的：只认本窗口（key 窗口）
        on(.workspaceRenameRequested) { c, _ in if c.isKeyWindow { c.renameWorkspace() } }
        on(.workspaceMakeMirrorRequested) { c, _ in if c.isKeyWindow { c.presentMakeMirror() } }
        on(.workspaceDropMirrorRequested) { c, _ in if c.isKeyWindow { c.confirmDropMirror() } }
        on(.workspaceSyncToSourceRequested) { c, _ in if c.isKeyWindow { c.presentSync(.fromMirror, switchTo: nil) } }
        on(NSApplication.willResignActiveNotification) { c, _ in c.refreshNotice() }   // 切走 = 天然的收尾时机
        on(.volumeDidMount) { c, _ in
            c.refreshNotice()
            c.workspace.refreshLocalFileFlags()   // 盘回来了，灰着的书恢复可打开
        }
        on(.volumeWillUnmount) { c, n in c.volumeWentAway(n.object as? URL, settled: false) }
        on(.volumeDidUnmount) { c, n in
            c.volumeWentAway(n.object as? URL, settled: true)
            c.workspace.refreshLocalFileFlags()
        }
    }

    private var isKeyWindow: Bool { view.window?.isKeyWindow == true }

    deinit { for o in observers { NotificationCenter.default.removeObserver(o) } }

    // MARK: 展开状态（记忆）

    private var expandedKey: String? {
        workspace.folder.map { "noteFolders:" + $0.standardizedFileURL.path }
    }
    private func loadExpanded() {
        guard let k = expandedKey else { return }
        expandedFolders = Set(UserDefaults.standard.stringArray(forKey: k) ?? [])
    }
    private func saveExpanded() {
        guard let k = expandedKey else { return }
        UserDefaults.standard.set(Array(expandedFolders).sorted(), forKey: k)
    }
    private static func folderKey(_ source: NoteRoot, _ folder: NoteFolder) -> String {
        "\(source.id):\(folder.path)"
    }

    /// 按记忆把该展开的目录展开（递归；父目录没展开时子目录也没法展开，所以自顶向下走）。
    private func restoreExpansion(_ nodes: [SidebarNode]) {
        for node in nodes {
            if case .noteFolder(let src, let folder) = node.kind,
               expandedFolders.contains(Self.folderKey(src, folder)) {
                outline.expandItem(node)
            }
            restoreExpansion(node.children)
        }
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        guard !restoringExpansion,
              let node = notification.userInfo?["NSObject"] as? SidebarNode,
              case .noteFolder(let src, let folder) = node.kind else { return }
        expandedFolders.insert(Self.folderKey(src, folder))
        saveExpanded()
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        guard !restoringExpansion,
              let node = notification.userInfo?["NSObject"] as? SidebarNode,
              case .noteFolder(let src, let folder) = node.kind else { return }
        expandedFolders.remove(Self.folderKey(src, folder))
        saveExpanded()
    }

    // MARK: 数据

    private func reload() {
        var r: [SidebarNode] = []
        if let notice { r.append(SidebarNode(kind: .notice(notice))) }
        let docs = workspace.documents
        if workspace.groups.isEmpty {
            let sec = SidebarNode(kind: .section(group: nil, title: workspace.name.isEmpty ? L("Library") : workspace.name))
            sec.children = docs.map { SidebarNode(kind: .doc($0)) }
            r.append(sec)
        } else {
            let ungrouped = docs.filter { $0.group.isEmpty }
            if !ungrouped.isEmpty {
                let sec = SidebarNode(kind: .section(group: "", title: L("Ungrouped")))
                sec.children = ungrouped.map { SidebarNode(kind: .doc($0)) }
                r.append(sec)
            }
            for g in workspace.groups {
                let sec = SidebarNode(kind: .section(group: g, title: g))
                sec.children = docs.filter { $0.group == g }.map { SidebarNode(kind: .doc($0)) }
                r.append(sec)
            }
        }
        // Markdown 笔记（v15）：**每个源一段**（内建 `Notes/` + 引用进来的外部目录），
        // 段里按**真实目录层级**递归展开（2026-09-20 用户要求多级目录）。
        for section in workspace.noteTrees where section.root.hasAnything || section.source.kind == .reference {
            let sec = SidebarNode(kind: .noteSection(source: section.source, folder: section.root))
            sec.children = Self.noteChildren(section.source, section.root)
            r.append(sec)
        }
        let keep = selectedRowIDs()
        roots = r
        syncingSelection = true
        outline.reloadData()
        restoringExpansion = true
        for n in roots where n.isSection { outline.expandItem(n) }   // 段头恒展开（同书库那边的老规矩）
        restoreExpansion(roots)                                      // 子目录按上次的状态，默认收起
        restoringExpansion = false
        select(ids: keep.isEmpty ? Set([tabs.active.rowID].compactMap { $0 }) : keep)
        syncingSelection = false
    }

    /// 一层目录底下的节点：子目录在前、笔记在后（顺序由 `NoteFolder` 排好）。
    private static func noteChildren(_ source: NoteRoot, _ folder: NoteFolder) -> [SidebarNode] {
        var out: [SidebarNode] = []
        for sub in folder.folders {
            let node = SidebarNode(kind: .noteFolder(source: source, folder: sub))
            node.children = noteChildren(source, sub)
            out.append(node)
        }
        out += folder.notes.map { SidebarNode(kind: .md($0)) }
        return out
    }

    /// 选中的 **PDF** id（右键作用对象 / 拖拽排序 / 改分组都只认 PDF）。
    private func selectedDocIDs() -> Set<String> {
        Set(outline.selectedRowIndexes.compactMap { (outline.item(atRow: $0) as? SidebarNode)?.docID })
    }
    /// 选中的所有条目（PDF + md 笔记，用 `rowID` 区分）。
    private func selectedRowIDs() -> Set<String> {
        Set(outline.selectedRowIndexes.compactMap { (outline.item(atRow: $0) as? SidebarNode)?.rowID })
    }

    private func select(ids: Set<String>) {
        var rows = IndexSet()
        for row in 0..<outline.numberOfRows {
            if let id = (outline.item(atRow: row) as? SidebarNode)?.rowID, ids.contains(id) { rows.insert(row) }
        }
        outline.selectRowIndexes(rows, byExtendingSelection: false)
    }

    /// 打开的文档 → 选中（外部改了打开文档：恢复会话 / 新窗口打开 / 删除回落）。
    private func syncSelectionFromTabs() {
        guard !syncingSelection else { return }
        let want = Set([tabs.active.rowID].compactMap { $0 })
        guard selectedRowIDs() != want else { return }
        syncingSelection = true
        select(ids: want)
        syncingSelection = false
    }

    // MARK: NSOutlineViewDataSource

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        (item as? SidebarNode)?.children.count ?? roots.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        (item as? SidebarNode)?.children[index] ?? roots[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        // 🔴 段头**与笔记子目录**都要能展开。只写 `isSection` 的话，笔记的多级目录
        // 永远展不开（`expandItem` 变成空操作），侧栏上就只看得到几个文件夹、看不到笔记。
        (item as? SidebarNode)?.isExpandable == true
    }

    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
        (item as? SidebarNode)?.isSection == true
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        (item as? SidebarNode)?.rowID != nil
    }

    /// 段头不要那个展开小三角（它们恒展开，同书库那边的老规矩）；**笔记子目录要有**，
    /// 否则用户没法收起层级很深的目录。
    func outlineView(_ outlineView: NSOutlineView, shouldShowOutlineCellForItem item: Any) -> Bool {
        if case .noteFolder = (item as? SidebarNode)?.kind { return true }
        return false
    }

    // MARK: 行视图

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let n = item as? SidebarNode else { return nil }
        switch n.kind {
        case .section(_, let title):
            let cell = NSTableCellView()
            let t = NSTextField(labelWithString: title)
            t.font = .preferredFont(forTextStyle: .subheadline)
            t.textColor = .secondaryLabelColor
            t.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(t)
            cell.textField = t
            NSLayoutConstraint.activate([
                t.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                t.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor),
                t.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            return cell
        case .doc(let doc):
            // 镜像里没带 PDF 的书：灰一档 + 换个图标，不隐藏（隐藏了用户会以为笔记也没了）
            let local = workspace.hasLocalFileCached(doc.id)
            return iconCell(symbol: local ? "doc.richtext" : "doc.badge.ellipsis", title: doc.title,
                            subtitle: nil, dim: !local,
                            tip: local ? nil : L("Not available offline — reconnect the source drive to read it."))
        case .md(let note):
            // 文件被手动删了 / 引用的盘没挂上 → 灰一档 + 换图标（同 PDF 那条规矩）
            let here = workspace.noteURL(note.ref).map { FileManager.default.fileExists(atPath: $0.path) } ?? false
            return iconCell(symbol: here ? "text.document" : "doc.badge.ellipsis", title: note.title,
                            subtitle: nil, dim: !here,
                            tip: here ? note.ref.relPath : L("The note file is missing."))
        case .noteFolder(_, let folder):
            return iconCell(symbol: "folder", title: folder.name, subtitle: nil, dim: false, tip: folder.path)
        case .noteSection(let source, let folder):
            // 段头：内建源就叫「笔记」，引用源多一枚链接图标 + 完整路径当提示
            let cell = NSTableCellView()
            let t = NSTextField(labelWithString: source.kind == .reference
                                ? "\(source.name) \u{2197}" : source.name)
            t.font = .preferredFont(forTextStyle: .subheadline)
            t.textColor = .secondaryLabelColor
            t.lineBreakMode = .byTruncatingTail
            t.toolTip = source.kind == .reference
                ? String(format: L("Referenced folder · %d notes · %@"), folder.noteCount, source.path)
                : String(format: L("%d notes in this workspace"), folder.noteCount)
            t.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(t)
            cell.textField = t
            NSLayoutConstraint.activate([
                t.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                t.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor),
                t.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            return cell
        case .notice(let notice):
            switch notice {
            case .sourceBack(_, let count):
                let sub: String
                switch count {
                case .none: sub = L("Checking what needs syncing…")
                case .some(0): sub = L("Both sides match · switch back")
                case .some(let k): sub = String(format: L("%d items to sync · tap to review"), k)
                }
                return iconCell(symbol: "eject", title: L("Source drive is connected"), subtitle: sub, dim: count == nil, tip: nil)
            case .unsynced(_, let count):
                return iconCell(symbol: "externaldrive.badge.timemachine",
                                title: String(format: L("%d items written offline"), count),
                                subtitle: L("Review and sync them back"), dim: false, tip: nil)
            }
        }
    }

    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        if case .notice = (item as? SidebarNode)?.kind { return 40 }
        return outlineView.rowHeight
    }

    private func iconCell(symbol: String, title: String, subtitle: String?, dim: Bool, tip: String?) -> NSView {
        let cell = NSTableCellView()
        let img = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage())
        img.contentTintColor = dim ? .secondaryLabelColor : nil
        let t = NSTextField(labelWithString: title)
        t.lineBreakMode = .byTruncatingTail
        t.textColor = dim ? .secondaryLabelColor : .labelColor
        cell.imageView = img
        cell.textField = t
        cell.toolTip = tip
        let texts: NSView
        if let subtitle {
            let s = NSTextField(labelWithString: subtitle)
            s.font = .preferredFont(forTextStyle: .caption1)
            s.textColor = .secondaryLabelColor
            s.lineBreakMode = .byTruncatingTail
            let v = NSStackView(views: [t, s])
            v.orientation = .vertical
            v.alignment = .leading
            v.spacing = 1
            texts = v
        } else {
            texts = t
        }
        let stack = NSStackView(views: [img, texts])
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -2),
            stack.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            img.widthAnchor.constraint(equalToConstant: 16),
        ])
        return cell
    }

    // MARK: 选中 / 点击

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !syncingSelection else { return }
        // 多选期间不动当前打开的文档；恰选一篇才联动
        let ids = selectedRowIDs()
        guard ids.count == 1, let id = ids.first, id != tabs.active.rowID else { return }
        syncingSelection = true
        if id.hasPrefix("md:"), let ref = NoteRef(key: String(id.dropFirst(3))) {
            tabs.openMarkdown(ref)
        } else if !id.hasPrefix("md:") {
            _ = tabs.open(id)
        }
        syncingSelection = false
    }

    @objc private func rowClicked() {
        guard let n = outline.item(atRow: outline.clickedRow) as? SidebarNode, case .notice(let notice) = n.kind else { return }
        switch notice {
        case .sourceBack(let src, let count):
            guard let count else { return }
            // 没东西可同步就别开面板了，直接切回去（那才是插盘时想做的事）
            if count == 0 { switchBack(to: src) } else { presentSync(.fromMirror, switchTo: src) }
        case .unsynced(let mirror, _):
            presentSync(.fromSource(mirror: mirror), switchTo: nil)
        }
    }

    // MARK: 拖进来（只收 Finder 里的 PDF；行级拖拽一概没有）

    func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo, proposedItem item: Any?,
                     proposedChildIndex index: Int) -> NSDragOperation {
        outlineView.setDropItem(nil, dropChildIndex: NSOutlineViewDropOnItemIndex)
        return .copy
    }

    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
        let urls = (info.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                       options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        guard !urls.isEmpty else { return false }
        onDropFiles(urls)
        return true
    }

    // MARK: 右键菜单

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let n = outline.item(atRow: outline.clickedRow) as? SidebarNode else { return }
        switch n.kind {
        case .section(let group?, _) where !group.isEmpty:
            menu.addItem(ClosureMenuItem(L("Rename Group…")) { [weak self] in self?.promptGroup(rename: group) })
            menu.addItem(ClosureMenuItem(L("Delete Group")) { [weak self] in self?.workspace.renameGroup(from: group, to: "") })
        case .doc(let doc):
            buildDocMenu(menu, doc: doc)
        case .md(let note):
            buildNoteMenu(menu, note: note)
        case .noteSection(let source, _):
            buildNoteSectionMenu(menu, source: source)
        case .noteFolder(let source, let folder):
            menu.addItem(ClosureMenuItem(L("New Note Here")) { [weak self] in
                guard let self, let ref = self.workspace.createNote(title: L("Untitled Note"),
                                                                    in: source.id, folder: folder.path) else { return }
                self.tabs.openMarkdown(ref)
            })
            menu.addItem(ClosureMenuItem(L("Show in Finder")) { [weak self] in
                guard let root = self?.workspace.noteRootURL(source) else { return }
                NSWorkspace.shared.activateFileViewerSelecting([root.appendingPathComponent(folder.path)])
            })
        default:
            break
        }
    }

    /// md 笔记的右键菜单。没有「分组 / 排序 / 关联为同一文档」那一排——那些是 PDF 书库的事。
    private func buildNoteMenu(_ m: NSMenu, note: NoteItem) {
        let external = workspace.noteSource(id: note.ref.sourceID)?.kind == .reference
        m.addItem(ClosureMenuItem(L("Rename…")) { [weak self] in
            self?.textPrompt(title: L("Rename Note"), placeholder: L("Note name"), initial: note.title) { name in
                guard let self, let newRef = self.workspace.renameNote(note.ref, to: name) else {
                    if let e = self?.workspace.lastError { self?.presentNoteError(e) }
                    return
                }
                // 🔴 改名 = 改文件名，指向它的 `[[旧名字]]` 会断链（我们不改别人的正文，红线）
                for t in self.tabs.tabs where t.noteRef == note.ref { t.openMarkdown(newRef) }
            }
        })
        m.addItem(ClosureMenuItem(L("Show in Finder")) { [weak self] in
            guard let url = self?.workspace.noteURL(note.ref) else { return }
            NSWorkspace.shared.activateFileViewerSelecting([url])
        })
        m.addItem(.separator())
        m.addItem(ClosureMenuItem(L("Move to Trash…")) { [weak self] in
            guard let self else { return }
            let a = NSAlert()
            a.messageText = String(format: L("Move “%@” to the Trash?"), note.title)
            a.informativeText = external
                ? String(format: L("This file lives in a referenced folder outside the workspace:\n%@"),
                         self.workspace.noteURL(note.ref)?.path ?? note.ref.relPath)
                : L("Links pointing at it will show as broken.")
            a.addButton(withTitle: L("Move to Trash"))
            a.addButton(withTitle: L("Cancel"))
            guard a.runModal() == .alertFirstButtonReturn else { return }
            self.workspace.deleteNote(note.ref)
            for t in self.tabs.tabs { t.closeMarkdownIfGone() }
        })
    }

    /// 笔记段头的右键菜单：新建、在访达里显示；引用源还能改名 / 取消引用。
    private func buildNoteSectionMenu(_ m: NSMenu, source: NoteRoot) {
        m.addItem(ClosureMenuItem(L("New Note Here")) { [weak self] in
            guard let self, let ref = self.workspace.createNote(title: L("Untitled Note"), in: source.id) else { return }
            self.tabs.openMarkdown(ref)
        })
        m.addItem(ClosureMenuItem(L("Show in Finder")) { [weak self] in
            guard let url = self?.workspace.noteRootURL(source) else { return }
            NSWorkspace.shared.activateFileViewerSelecting([url])
        })
        guard source.kind == .reference else { return }
        m.addItem(.separator())
        m.addItem(ClosureMenuItem(L("Rename…")) { [weak self] in
            self?.textPrompt(title: L("Rename Folder"), placeholder: L("Display name"), initial: source.name) { name in
                self?.workspace.renameReferencedNotesFolder(id: source.id, name: name)
            }
        })
        m.addItem(ClosureMenuItem(L("Remove Reference")) { [weak self] in
            guard let self else { return }
            let a = NSAlert()
            a.messageText = String(format: L("Stop showing “%@”?"), source.name)
            a.informativeText = String(format: L("The folder itself is not touched:\n%@"), source.path)
            a.addButton(withTitle: L("Remove"))
            a.addButton(withTitle: L("Cancel"))
            guard a.runModal() == .alertFirstButtonReturn else { return }
            self.workspace.removeReferencedNotesFolder(id: source.id)
            for t in self.tabs.tabs { t.closeMarkdownIfGone() }
        })
    }

    private func presentNoteError(_ text: String) {
        let a = NSAlert()
        a.messageText = L("Could not complete that")
        a.informativeText = text
        a.addButton(withTitle: L("OK"))
        a.runModal()
    }

    /// 右键的作用对象：被点者在选中集内 → 整个选中集；否则仅被点者（macOS 惯例）。
    private func targets(for id: String) -> Set<String> {
        let sel = selectedDocIDs()
        return sel.contains(id) ? sel : [id]
    }

    private func buildDocMenu(_ m: NSMenu, doc: LibDocument) {
        let targets = targets(for: doc.id)
        m.autoenablesItems = false
        if targets.count == 1 {
            m.addItem(item(L("Open in New Window"), "macwindow.badge.plus") { [weak self] in self?.onOpenInNewWindow(doc.id) })
        }
        // 边界上 / 跨分组混选时灰掉而不是隐藏（忽隐忽现比灰着更难用）
        let up = item(L("Move Up"), "arrow.up") { [weak self] in self?.moveSelection(targets, up: true) }
        up.isEnabled = canMove(targets, up: true)
        let down = item(L("Move Down"), "arrow.down") { [weak self] in self?.moveSelection(targets, up: false) }
        down.isEnabled = canMove(targets, up: false)
        m.addItem(up)
        m.addItem(down)
        m.addItem(.separator())
        let groupMenu = NSMenu()
        if targets.contains(where: { workspace.document(id: $0)?.group.isEmpty == false }) {
            groupMenu.addItem(item(L("No Group"), "circle.dashed") { [weak self] in self?.workspace.setGroup(ids: targets, group: "") })
        }
        for g in workspace.groups {
            groupMenu.addItem(ClosureMenuItem(g) { [weak self] in self?.workspace.setGroup(ids: targets, group: g) })
        }
        groupMenu.addItem(.separator())
        groupMenu.addItem(item(L("New Group…"), "plus") { [weak self] in self?.promptGroup(newFor: Array(targets)) })
        let groupParent = item(L("Move to Group"), "folder") {}
        groupParent.submenu = groupMenu
        m.addItem(groupParent)
        if targets.count == 1 {
            if workspace.currentFilePath(documentId: doc.id) != nil {
                m.addItem(item(L("Show in Finder"), "folder") { [weak self] in self?.workspace.revealInFinder(documentId: doc.id) })
            }
            m.addItem(item(L("Show Workspace in Finder"), "folder.badge.gearshape") { [weak self] in
                self?.workspace.revealWorkspaceInFinder()
            })
            m.addItem(.separator())
            if workspace.isInWorkspace(doc.id) {
                m.addItem(item(L("Remove from Workspace"), "folder.badge.minus") { [weak self] in
                    self?.workspace.removeFromWorkspace(documentId: doc.id)
                })
            } else {
                m.addItem(item(L("Copy into Workspace"), "folder.badge.plus") { [weak self] in
                    self?.workspace.copyToWorkspace(documentId: doc.id)
                })
            }
            let others = workspace.documents.filter { $0.id != doc.id }
            if !others.isEmpty {
                let sub = NSMenu()
                for target in others {
                    sub.addItem(ClosureMenuItem(target.title) { [weak self] in self?.confirmMerge(source: doc, target: target) })
                }
                let link = item(L("Link as Same Document"), "link") {}
                link.submenu = sub
                m.addItem(link)
            }
        }
        m.addItem(.separator())
        m.addItem(item(L("Delete"), "trash") { [weak self] in
            guard let self else { return }
            for id in targets { self.workspace.delete(documentId: id) }
        })
    }

    private func item(_ title: String, _ symbol: String, _ action: @escaping () -> Void) -> NSMenuItem {
        let i = ClosureMenuItem(title, action: action)
        i.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        return i
    }

    // MARK: 手动排序（同一分组段内上移 / 下移，多选整批）

    private func sameGroup(_ ids: Set<String>) -> String? {
        let groups = Set(ids.compactMap { workspace.document(id: $0)?.group })
        return groups.count == 1 ? groups.first : nil
    }

    private func canMove(_ ids: Set<String>, up: Bool) -> Bool {
        guard let g = sameGroup(ids) else { return false }
        let section = workspace.documents.filter { $0.group == g }
        let idxs = section.indices.filter { ids.contains(section[$0].id) }
        guard let first = idxs.first, let last = idxs.last else { return false }
        return up ? first > 0 : last < section.count - 1
    }

    private func moveSelection(_ ids: Set<String>, up: Bool) {
        guard let g = sameGroup(ids) else { return }
        var section = workspace.documents.filter { $0.group == g }
        let idxs = section.indices.filter { ids.contains(section[$0].id) }
        guard let first = idxs.first, let last = idxs.last else { return }
        if up {
            guard first > 0 else { return }
            let neighbor = section.remove(at: first - 1)
            section.insert(neighbor, at: last)
        } else {
            guard last < section.count - 1 else { return }
            let neighbor = section.remove(at: last + 1)
            section.insert(neighbor, at: first)
        }
        var all = workspace.documents
        var it = section.makeIterator()
        for i in all.indices where all[i].group == g {
            if let d = it.next() { all[i] = d }
        }
        workspace.reorderDocuments(all.map(\.id))
    }

    // MARK: 弹窗

    private func textPrompt(title: String, placeholder: String, initial: String, done: @escaping (String) -> Void) {
        guard let win = view.window else { return }
        let a = NSAlert()
        a.messageText = title
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = placeholder
        field.stringValue = initial
        a.accessoryView = field
        a.addButton(withTitle: L("OK"))
        a.addButton(withTitle: L("Cancel"))
        a.window.initialFirstResponder = field
        a.beginSheetModal(for: win) { resp in
            if resp == .alertFirstButtonReturn { done(field.stringValue) }
        }
    }

    private func renameWorkspace() {
        textPrompt(title: L("Rename Workspace"), placeholder: L("Name"), initial: workspace.name) { [weak self] name in
            self?.workspace.rename(name)
        }
    }

    private func promptGroup(newFor ids: [String]) {
        textPrompt(title: L("New Group"), placeholder: L("Group Name"), initial: "") { [weak self] raw in
            let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return }
            self?.workspace.setGroup(ids: ids, group: name)
        }
    }

    private func promptGroup(rename old: String) {
        textPrompt(title: String(format: L("Rename Group “%@”"), old), placeholder: L("Group Name"), initial: old) { [weak self] raw in
            let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, name != old else { return }
            self?.workspace.renameGroup(from: old, to: name)
        }
    }

    private func confirmMerge(source: LibDocument, target: LibDocument) {
        guard let win = view.window else { return }
        let a = NSAlert()
        a.messageText = L("Link as Same Document")
        a.informativeText = String(format: L("“%@” becomes another version of “%@”; their notes merge and it leaves the list."),
                                   source.title, target.title)
        let ok = a.addButton(withTitle: String(format: L("Merge into “%@”"), target.title))
        ok.hasDestructiveAction = true
        a.addButton(withTitle: L("Cancel"))
        a.beginSheetModal(for: win) { [weak self] resp in
            guard let self, resp == .alertFirstButtonReturn else { return }
            self.workspace.mergeDocuments(sourceId: source.id, intoTargetId: target.id)
            if self.tabs.active.docID == source.id { _ = self.tabs.open(target.id) }
        }
    }

    /// 删的是 GB 级数据、还可能带着没同步回来的笔迹 —— 必须确认一次，且把后果说清楚。
    private func confirmDropMirror() {
        guard let win = view.window else { return }
        let a = NSAlert()
        a.messageText = L("Delete the offline copy?")
        a.informativeText = L("Anything written offline that hasn’t been synced back goes with it. To keep those, open the offline copy first and sync to the source.")
        let del = a.addButton(withTitle: L("Delete"))
        del.hasDestructiveAction = true
        a.addButton(withTitle: L("Cancel"))
        a.beginSheetModal(for: win) { [weak self] resp in
            if resp == .alertFirstButtonReturn { self?.dropMirror() }
        }
    }

    private func dropMirror() {
        guard let folder = workspace.folder,
              let p = registry.mirrorPath(forSource: folder, id: workspace.workspaceId) else { return }
        let url = URL(fileURLWithPath: p)
        workspace.forgetMirror(at: url)
        registry.setMirror(nil, forSource: folder, id: workspace.workspaceId)
        notice = nil
        reload()
        // 几 GB 的 removeItem 放后台；记录已摘干净，界面立刻就对
        DispatchQueue.global(qos: .utility).async { try? FileManager.default.removeItem(at: url) }
    }

    private func checkMissingRecent() {
        guard let name = registry.missingRecentName, isKeyWindow, let win = view.window else { return }
        registry.missingRecentName = nil
        let a = NSAlert()
        a.messageText = L("Workspace Not Found")
        a.informativeText = String(format: L("“%@” could not be found. It has been removed from your recent workspaces."), name)
        a.addButton(withTitle: L("OK"))
        a.beginSheetModal(for: win)
    }

    // 离线副本的两张面板：以 sheet 弹出，关掉时重算提示
    private func presentMakeMirror() {
        let vc = MakeMirrorController(workspace: workspace)
        vc.onDismiss = { [weak self] in self?.refreshNotice() }
        presentAsSheet(vc)
    }

    private func presentSync(_ side: MirrorSyncController.Side, switchTo: URL?) {
        let vc = MirrorSyncController(workspace: workspace, side: side,
                                      onSynced: switchTo.map { src in { [weak self] _ in self?.switchBack(to: src) } })
        vc.onDismiss = { [weak self] in self?.refreshNotice() }
        presentAsSheet(vc)
    }

    // MARK: 离线副本提示（逻辑同原版）

    private func refreshNotice() {
        guard !noticeBusy else { noticePending = true; return }
        guard let folder = workspace.folder else { setNotice(nil); return }
        let epoch = noticeEpoch
        let ws = workspace
        if workspace.isMirror {
            guard let id = workspace.mirrorSourceId else { setNotice(nil); return }
            noticeBusy = true
            let recents = registry.recents.map { URL(fileURLWithPath: $0.sourcePath) }
            DispatchQueue.global(qos: .utility).async { [weak self] in
                let src = WorkspaceManager.findMirrorSource(id: id, recents: recents)
                DispatchQueue.main.async {
                    guard let self else { return }
                    if epoch == self.noticeEpoch { self.setNotice(src.map { .sourceBack($0, nil) }) }
                }
                guard let src else { DispatchQueue.main.async { self?.finishNotice() }; return }
                let n = (try? ws.mirrorDryRun(sourceFolder: src))?.plan.changes.count ?? 0
                DispatchQueue.main.async {
                    guard let self else { return }
                    if epoch == self.noticeEpoch { self.setNotice(.sourceBack(src, n)) }
                    self.finishNotice()
                }
            }
        } else if let p = registry.mirrorPath(forSource: folder, id: workspace.workspaceId) {
            noticeBusy = true
            let mirror = URL(fileURLWithPath: p)
            DispatchQueue.global(qos: .utility).async { [weak self] in
                let pending = ws.autoPushToMirror(mirrorFolder: mirror) ?? 0
                DispatchQueue.main.async {
                    guard let self else { return }
                    if epoch == self.noticeEpoch { self.setNotice(pending > 0 ? .unsynced(mirror, pending) : nil) }
                    self.finishNotice()
                }
            }
        } else {
            setNotice(nil)
        }
    }

    private func setNotice(_ n: Notice?) {
        notice = n
        reload()
    }

    private func finishNotice() {
        noticeBusy = false
        if noticePending { noticePending = false; refreshNotice() }
    }

    private func volumeWentAway(_ vol: URL?, settled: Bool) {
        noticeEpoch += 1
        if noticeOn(vol) { setNotice(nil) }
        if settled { refreshNotice() }
    }

    private func noticeOn(_ vol: URL?) -> Bool {
        let target: URL?
        switch notice {
        case .sourceBack(let src, _): target = src
        case .unsynced(let mirror, _): target = mirror
        case .none: return false
        }
        guard let vol, let target else { return true }
        let prefix = vol.standardizedFileURL.path
        return target.standardizedFileURL.path == prefix || target.standardizedFileURL.path.hasPrefix(prefix + "/")
    }

    /// 切回源盘：先开源盘那扇窗，再关副本这扇（次序不能反）。
    private func switchBack(to src: URL) {
        onOpenRecent(src)
        registry.requestActivation(forWorkspace: src)
        if let mirror = workspace.folder { registry.evacuate(mirror) }
    }
}

/// 侧栏里的一个节点（`NSOutlineView` 要引用类型的 item）。
final class SidebarNode: NSObject {
    enum Kind {
        case notice(SidebarViewController.Notice)
        case section(group: String?, title: String)
        case doc(LibDocument)
        /// Markdown 笔记（v15，`MARKDOWN-NOTES-PLAN.md`）。与 PDF **并列列在侧栏**，
        /// 但身份是「源 + 源内相对路径」而不是库里的行——所以这里是单独一个 case，
        /// `docID` 仍然只给 PDF（`targets(for:)` / 拖拽排序 / 分组都只认 PDF）。
        case md(NoteItem)
        /// 笔记的**子目录**（多级，2026-09-20 用户要求）。不可选中，只能展开。
        case noteFolder(source: NoteRoot, folder: NoteFolder)
        /// 一个笔记源的段头（内建 `Notes/` 或引用进来的外部目录）。
        case noteSection(source: NoteRoot, folder: NoteFolder)
    }
    let kind: Kind
    var children: [SidebarNode] = []

    init(kind: Kind) { self.kind = kind }

    var isSection: Bool {
        switch kind {
        case .section, .noteSection: return true
        default: return false
        }
    }
    /// 展开后默认摊开的层（段头与子目录）。
    var isExpandable: Bool {
        switch kind {
        case .section, .noteSection, .noteFolder: return true
        default: return false
        }
    }
    var docID: String? { if case .doc(let d) = kind { return d.id } else { return nil } }
    var note: NoteItem? { if case .md(let n) = kind { return n } else { return nil } }
    /// 选中键（两类条目在同一张表里，得能区分）。与 `DocTabModel.rowID` 同口径。
    var rowID: String? { note.map { "md:" + $0.ref.key } ?? docID }
}
