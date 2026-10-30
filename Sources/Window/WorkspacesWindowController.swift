import AppKit
import Combine
import UniformTypeIdentifiers

/// 启动页「工作区」：左边 App 图标与三个按钮，右边分段列表——「本机」一段是最近打开过的工作区，下面每台已连接的服务器一段
/// （2026-10-29 用户要求；视图在 `WorkspacesWelcomeView`，本文件只管数据与动作）。
///
/// 用户定的出现时机：启动时**照旧**直接开上次的工作区；这扇窗从「文件 › 工作区…」（⇧⌘O）打开；
/// 阅读窗口全关掉、或点 Dock 图标而没有阅读窗口时也出现。从这里打开一个工作区后它自己关掉。
/// 「始终可以唤出」（用户同日要求）：阅读窗口工具栏的工作区菜单第一项、Dock 右键菜单第一项也都是它。
@MainActor
final class WorkspacesWindowController: NSWindowController {
    private static var shared: WorkspacesWindowController?

    static func show() {
        if shared == nil || shared?.window == nil {
            let c = WorkspacesWindowController()
            shared = c
            c.window?.center()
        }
        (shared?.contentViewController as? WorkspacesViewController)?.reloadServers()
        shared?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    static func closeIfOpen() { shared?.window?.close() }

    private init() {
        let win = NSWindow(contentViewController: WorkspacesViewController())
        win.title = L("Workspaces")
        // 欢迎窗的样子：透明标题栏、不显示标题文字、固定大小、拖背景就能挪
        win.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
        win.titlebarAppearsTransparent = true
        win.titleVisibility = .hidden
        win.isMovableByWindowBackground = true
        win.setContentSize(WorkspacesWelcomeView.size)
        win.isReleasedWhenClosed = false
        super.init(window: win)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) 不支持") }
}

// MARK: - 数据与动作

@MainActor
final class WorkspacesViewController: NSViewController {

    private enum Row {
        case header(String)
        case local(RecentWorkspace)
        case remote(ServerAccount, ServerClient.WorkspaceInfo)
        case message(String)
    }

    private enum RemoteState {
        case loading
        case loaded([ServerClient.WorkspaceInfo], localCopies: [String: URL])
        case failed(String)
    }

    private var rows: [Row] = []
    private var remote: [String: RemoteState] = [:]   // 账号 id → 那台服务器的工作区
    private var loadToken = 0
    /// 正在下载（`ServerSyncCoordinator.workspaceDownloads` 上一次的键）：下完的那几个要重新找本机副本。
    private var downloading: Set<String> = []
    private var bag = Set<AnyCancellable>()
    private var welcome: WorkspacesWelcomeView!
    private var sync: ServerSyncCoordinator { .shared }

    override func loadView() {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = String(format: L("Version %@ (%@)"), info["CFBundleShortVersionString"] as? String ?? "",
                             info["CFBundleVersion"] as? String ?? "")
        let w = WorkspacesWelcomeView(appName: "UniReader", version: version,
                                      icon: NSApp.applicationIconImage ?? NSImage())
        w.onOpen = { [weak self] i in self?.open(i) }
        w.onNew = { if WorkspacePanels.createNew() { WorkspacesWindowController.closeIfOpen() } }
        w.onOpenExisting = { if WorkspacePanels.chooseExisting() { WorkspacesWindowController.closeIfOpen() } }
        w.onConnect = { SettingsWindowController.show(tab: .servers) }
        w.contextItems = { [weak self] i in self?.contextItems(i) ?? [] }
        welcome = w
        view = w

        // 最近列表 / 服务器账号一变就重排（打开过别的工作区、在设置里连了新服务器）
        WorkspaceRegistry.shared.$recents.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { self?.rebuild() }
        }.store(in: &bag)
        ServerAccounts.shared.$all.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { self?.reloadServers() }
        }.store(in: &bag)
        // 下载进度：只就地改那几行（@Published 在 willSet 发出，挪到下一拍再读新值）
        sync.$workspaceDownloads.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { self?.downloadsChanged() }
        }.store(in: &bag)
        rebuild()
    }

    /// 重新向每台服务器要一次工作区列表（窗口每次显示时调）。
    func reloadServers() {
        loadToken += 1
        let token = loadToken
        let accounts = ServerAccounts.shared.all
        remote = Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, RemoteState.loading) })
        rebuild()
        for a in accounts {
            guard let client = ServerAccounts.shared.client(a) else {
                remote[a.id] = .failed(ServerSyncError.noAccount.localizedDescription)
                continue
            }
            Task {
                let state: RemoteState
                do {
                    let list = try await client.workspaces()
                    state = .loaded(list, localCopies: await Self.findCopies(list.map(\.id)))
                } catch {
                    state = .failed(error.localizedDescription)
                }
                guard token == self.loadToken else { return }
                self.remote[a.id] = state
                self.rebuild()
            }
        }
    }

    /// 本机有没有这些工作区的副本：最近列表里同一个 id 能解析到的那份（主线程，只是几次 fileExists），
    /// 否则去缓存目录里找（要逐个打开库看身份，放后台）。
    private static func findCopies(_ ids: [String]) async -> [String: URL] {
        let recents = WorkspaceRegistry.shared.recents
        var copies: [String: URL] = [:]
        for id in ids {
            if let r = recents.first(where: { $0.id == id }), let u = WorkspaceRegistry.resolve(r) { copies[id] = u }
        }
        let rest = ids.filter { copies[$0] == nil }
        let found = await Task.detached { () -> [String: URL] in
            var out: [String: URL] = [:]
            for id in rest { if let u = ServerSyncIO.findCache(workspaceId: id) { out[id] = u } }
            return out
        }.value
        return copies.merging(found) { a, _ in a }
    }

    /// 只重找这几个工作区的本机副本（下载完 / 删掉之后），不重新问服务器。
    private func refreshCopies(_ ids: Set<String>) {
        Task {
            let found = await Self.findCopies(Array(ids))
            for (aid, state) in remote {
                guard case .loaded(let list, var copies) = state, list.contains(where: { ids.contains($0.id) }) else { continue }
                for id in ids { copies[id] = found[id] }
                remote[aid] = .loaded(list, localCopies: copies)
            }
            rebuild()
        }
    }

    private func rebuild() {
        var out: [Row] = [.header(L("This Mac"))]
        let recents = WorkspaceRegistry.shared.recents
        out += recents.isEmpty ? [.message(L("No workspaces opened yet."))] : recents.map { .local($0) }
        for a in ServerAccounts.shared.all {
            let host = URL(string: a.url).map { u in (u.host ?? a.url) + (u.port.map { ":\($0)" } ?? "") } ?? a.url
            out.append(.header(a.serverName.map { "\($0) · \(host)" } ?? host))
            switch remote[a.id] ?? .loading {
            case .loading: out.append(.message(L("Loading…")))
            case .failed(let msg): out.append(.message(String(format: L("Can’t reach this server: %@"), msg)))
            case .loaded(let list, _):
                out += list.isEmpty ? [.message(L("No workspaces on this server yet."))] : list.map { .remote(a, $0) }
            }
        }
        rows = out
        welcome.items = rows.map(item)
    }

    private func downloadsChanged() {
        let now = sync.workspaceDownloads
        for (i, r) in rows.enumerated() {
            if case .remote = r { welcome.update(i, item(r)) }
        }
        let finished = downloading.subtracting(now.keys)
        downloading = Set(now.keys)
        if !finished.isEmpty { refreshCopies(finished) }
    }

    private func item(_ r: Row) -> WorkspacesWelcomeView.Item {
        switch r {
        case .header(let t): return .header(t)
        case .message(let m): return .message(m)
        case .local(let w):
            guard let url = WorkspaceRegistry.resolve(w) else {
                return .entry(icon: Self.symbol("externaldrive.badge.xmark"), title: w.name,
                              detail: L("Not available (its drive isn’t connected)"))
            }
            var detail = Self.displayPath(url)
            if ServerSyncIO.serverURL(of: url) != nil { detail = L("Server workspace") + " · " + detail }
            else if WorkspaceRegistry.opensOffline(w) { detail = L("Offline copy") + " · " + detail }
            return .entry(icon: NSWorkspace.shared.icon(forFile: url.path), title: w.name, detail: detail)
        case .remote(let a, let ws):
            let title = ws.name.isEmpty ? L("Untitled Workspace") : ws.name
            if let d = sync.workspaceDownloads[ws.id] {
                return .entry(icon: Self.symbol("server.rack"), title: title, detail: d.step,
                              progress: .init(fraction: d.fraction))
            }
            let detail = localCopy(a, ws).map { String(format: L("On this Mac · %@"), Self.displayPath($0)) }
                ?? L("Not downloaded yet; opening downloads the library")
            return .entry(icon: Self.symbol("server.rack"), title: title, detail: detail)
        }
    }

    private static func symbol(_ name: String) -> NSImage {
        let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 22, weight: .regular)) ?? NSImage()
        img.isTemplate = true
        return img
    }

    /// 路径给人看：家目录缩成 `~`；本机缓存目录里的只说「本机缓存」（那串 `~/Library/…` 用户用不上）。
    private static func displayPath(_ url: URL) -> String {
        let p = url.standardizedFileURL.path
        if p.hasPrefix(ServerSyncIO.cachesRoot.standardizedFileURL.path) { return L("Local copy") }
        return (p as NSString).abbreviatingWithTildeInPath
    }

    private func localCopy(_ a: ServerAccount, _ ws: ServerClient.WorkspaceInfo) -> URL? {
        if case .loaded(_, let copies)? = remote[a.id] { return copies[ws.id] }
        return nil
    }

    // MARK: 右键

    /// 「本机」一段：在访达中显示 / 重命名 / 从列表中移除（只摘最近列表里这一条，工作区文件夹一个字节都不动）。
    /// 服务器那几段：下载到本机（或停止下载）/ 重命名 / 从服务器删除（确认两次）。
    private func contextItems(_ i: Int) -> [WorkspacesWelcomeView.ContextItem] {
        guard rows.indices.contains(i) else { return [] }
        switch rows[i] {
        case .local(let r):
            var out: [WorkspacesWelcomeView.ContextItem] = []
            if let url = WorkspaceRegistry.resolve(r) {
                out.append(.action(L("Show in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([url]) })
                out.append(.action(L("Rename…")) { [weak self] in self?.renameLocal(r, url) })
            }
            out.append(.separator)
            out.append(.action(L("Remove from List")) {
                WorkspaceRegistry.shared.removeRecent(URL(fileURLWithPath: r.sourcePath))
            })
            return out
        case .remote(let a, let ws):
            var out: [WorkspacesWelcomeView.ContextItem] = []
            if sync.workspaceDownloads[ws.id] != nil {
                out.append(.action(L("Stop Downloading")) { [weak self] in self?.sync.cancelWorkspaceDownload(ws.id) })
            } else if let copy = localCopy(a, ws) {
                if WorkspaceRegistry.shared.openManager(at: copy) == nil {
                    out.append(.action(L("Download Missing PDFs")) { [weak self] in self?.download(a, ws) })
                }
            } else {
                out.append(.action(L("Download to This Mac")) { [weak self] in self?.download(a, ws) })
            }
            out.append(.action(L("Rename…")) { [weak self] in self?.renameRemote(a, ws) })
            out.append(.separator)
            out.append(.action(L("Delete from Server…")) { [weak self] in self?.confirmDelete(a, ws) })
            return out
        case .header, .message:
            return []
        }
    }

    // MARK: 下载到本机

    /// 右键「下载到本机」：资料库 + 图片 + 不大的 PDF，进度显示在这一行（2026-10-30 用户要求）。
    private func download(_ a: ServerAccount, _ ws: ServerClient.WorkspaceInfo) {
        welcome.setStatus("", busy: false)
        Task {
            do {
                try await sync.downloadWorkspace(a, ws)
            } catch is CancellationError {
            } catch let e as URLError where e.code == .cancelled {
            } catch {
                welcome.setStatus(String(format: L("Couldn’t download “%@”: %@"), ws.name, error.localizedDescription),
                                  busy: false)
            }
        }
    }

    // MARK: 重命名

    private func renameLocal(_ r: RecentWorkspace, _ folder: URL) {
        promptName(current: r.name) { [weak self] name in
            Task {
                do {
                    let result = try await WorkspaceManager.renameClosed(folder, to: name)
                    // 服务器工作区：顺手让服务器也改（启动页下面那一段马上就是新名字）；连不上也没关系，同步会推上去
                    if ServerSyncIO.serverURL(of: result) != nil {
                        try? await ServerSyncCoordinator.shared.renameOnServer(folder: result, to: name)
                        self?.reloadServers()
                    }
                } catch {
                    self?.welcome.setStatus(error.localizedDescription, busy: false)
                }
            }
        }
    }

    /// 服务器上的工作区改名：让服务器改；本机有副本就把副本也改了（两边同一个名字，同步时不算冲突）。
    /// 服务器连不上 / 太旧而本机有副本时，只改副本，等同步带上去。
    private func renameRemote(_ a: ServerAccount, _ ws: ServerClient.WorkspaceInfo) {
        promptName(current: ws.name) { [weak self] name in
            guard let self else { return }
            let copy = self.localCopy(a, ws)
            Task {
                do {
                    do {
                        try await self.sync.renameOnServer(a, ws, to: name)
                    } catch where copy != nil {
                        // 只改本机副本，同步带上去
                    }
                    if let copy { _ = try await WorkspaceManager.renameClosed(copy, to: name) }
                    self.reloadServers()
                } catch {
                    self.welcome.setStatus(error.localizedDescription, busy: false)
                }
            }
        }
    }

    private func promptName(current: String, done: @escaping (String) -> Void) {
        guard let win = view.window else { return }
        let a = NSAlert()
        a.messageText = L("Rename Workspace")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = L("Name")
        field.stringValue = current
        a.accessoryView = field
        a.addButton(withTitle: L("Rename"))
        a.addButton(withTitle: L("Cancel"))
        a.window.initialFirstResponder = field
        a.beginSheetModal(for: win) { resp in
            let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard resp == .alertFirstButtonReturn, !name.isEmpty, name != current else { return }
            done(name)
        }
    }

    // MARK: 从服务器删除（确认两次）

    private func confirmDelete(_ a: ServerAccount, _ ws: ServerClient.WorkspaceInfo) {
        guard let win = view.window else { return }
        let name = ws.name.isEmpty ? L("Untitled Workspace") : ws.name
        let copy = localCopy(a, ws)
        if let copy, WorkspaceRegistry.shared.hasWindow(forWorkspace: copy)
            || WorkspaceRegistry.shared.openManager(at: copy) != nil {
            WorkspacePanels.alert(String(format: L("“%@” is open"), name),
                                  L("Close this workspace’s windows first, then delete it from the server."))
            return
        }
        var text = L("Its books, notes and handwriting are removed from the server, and no device can open it from the server any more. The server keeps it in its trash for 90 days; it can be restored there with “unireader-server restore”.")
        if let copy {
            text += "\n\n" + (ServerSyncCoordinator.isInCachesFolder(copy)
                ? L("The copy on this Mac will be moved to the Trash.")
                : String(format: L("The copy on this Mac (%@) becomes a local workspace and stays where it is."),
                         (copy.path as NSString).abbreviatingWithTildeInPath))
        }
        text += "\n\n" + L("Copies on other devices aren’t touched; they’ll report that the workspace is gone from the server.")
        let first = NSAlert()
        first.alertStyle = .warning
        first.messageText = String(format: L("Delete “%@” from the server?"), name)
        first.informativeText = text
        first.addButton(withTitle: L("Delete…")).hasDestructiveAction = true
        first.addButton(withTitle: L("Cancel"))
        first.beginSheetModal(for: win) { [weak self] resp in
            guard resp == .alertFirstButtonReturn else { return }
            // 第一个框收起之后再弹第二个（同一扇窗上不能叠两个 sheet）
            DispatchQueue.main.async { self?.confirmDeleteAgain(a, ws, name: name, copy: copy) }
        }
    }

    /// 第二次确认：默认按钮是「取消」，回车不会删。
    private func confirmDeleteAgain(_ a: ServerAccount, _ ws: ServerClient.WorkspaceInfo, name: String, copy: URL?) {
        guard let win = view.window else { return }
        let second = NSAlert()
        second.alertStyle = .critical
        second.messageText = String(format: L("Really delete “%@” from the server?"), name)
        second.informativeText = L("This takes effect right away for all your devices.")
        let delete = second.addButton(withTitle: L("Delete from Server"))
        delete.hasDestructiveAction = true
        delete.keyEquivalent = ""
        let cancel = second.addButton(withTitle: L("Cancel"))
        cancel.keyEquivalent = "\r"
        second.beginSheetModal(for: win) { [weak self] resp in
            guard resp == .alertFirstButtonReturn else { return }
            self?.delete(a, ws, name: name, copy: copy)
        }
    }

    private func delete(_ a: ServerAccount, _ ws: ServerClient.WorkspaceInfo, name: String, copy: URL?) {
        welcome.setStatus(String(format: L("Deleting “%@” from the server…"), name), busy: true)
        Task {
            do {
                let fate = try await sync.deleteFromServer(a, ws, localCopy: copy)
                var msg = String(format: L("Deleted “%@” from the server."), name)
                switch fate {
                case .none: break
                case .trashed: msg += " " + L("The copy on this Mac is in the Trash.")
                case .detached: msg += " " + L("The copy on this Mac is now a local workspace.")
                }
                welcome.setStatus(msg, busy: false)
            } catch {
                welcome.setStatus(String(format: L("Couldn’t delete “%@”: %@"), name, error.localizedDescription), busy: false)
            }
            reloadServers()
        }
    }

    // MARK: 打开

    private func open(_ i: Int) {
        guard rows.indices.contains(i) else { return }
        switch rows[i] {
        case .local(let r): openLocal(r)
        case .remote(let a, let ws): openRemote(a, ws)
        case .header, .message: break
        }
    }

    private func openLocal(_ r: RecentWorkspace) {
        let url = WorkspaceRegistry.resolveOrSource(r)
        do {
            try WorkspaceManager.validate(url)
        } catch {
            WorkspaceRegistry.shared.removeRecent(url)
            WorkspacePanels.alert(L("Workspace Not Found"),
                                  String(format: L("“%@” could not be found. It has been removed from your recent workspaces."), r.name))
            return
        }
        WorkspacePanels.route(url, strict: false)
        WorkspacesWindowController.closeIfOpen()
    }

    /// 正在点开的服务器工作区（双击两下别开两趟）。
    private var opening: Set<String> = []

    /// 本机已有副本就直接开它；没有就先下载资料库建本机缓存（PDF 用到再下），进度显示在这一行。
    /// 右键「下载到本机」正在下的，等它建好缓存就开（还在下的 PDF 由打开前的那一步停掉）。
    private func openRemote(_ a: ServerAccount, _ ws: ServerClient.WorkspaceInfo) {
        if let copy = localCopy(a, ws) {
            WorkspacePanels.route(copy, strict: true)
            WorkspacesWindowController.closeIfOpen()
            return
        }
        guard !opening.contains(ws.id) else { return }
        opening.insert(ws.id)
        welcome.setStatus("", busy: false)
        Task {
            defer { opening.remove(ws.id) }
            do {
                let folder = try await sync.openFromServer(a, ws)
                WorkspacePanels.route(folder, strict: true)
                WorkspacesWindowController.closeIfOpen()
            } catch is CancellationError {
            } catch let e as URLError where e.code == .cancelled {
            } catch {
                welcome.setStatus(error.localizedDescription, busy: false)
            }
        }
    }
}

// MARK: - 打开 / 新建工作区（阅读窗口的工作区菜单与启动页共用）

@MainActor
enum WorkspacePanels {
    static let workspaceType = UTType(exportedAs: "tech.xvanturing.unireader.workspace")

    /// 打开一个**已存在**的工作区包（`.unrd`）：只认真实工作区，不接受普通 / 空文件夹，也不允许现场新建。
    /// 返回用户是否选了一个工作区（并已开始打开）。
    @discardableResult
    static func chooseExisting() -> Bool {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.canCreateDirectories = false
        panel.treatsFilePackagesAsDirectories = false
        panel.allowedContentTypes = [workspaceType]
        panel.allowsMultipleSelection = false
        panel.message = L("Choose an existing UniReader workspace (.unrd).")
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        return route(url, strict: true)
    }

    /// 新建工作区：选位置 + 起名，创建全新 `.unrd` 包并开一扇窗。
    @discardableResult
    static func createNew() -> Bool {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [workspaceType]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = L("Untitled Workspace")
        panel.prompt = L("Create")
        panel.message = L("Choose a location and name for the new workspace.")
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        // 目标已经是工作区会在这里报错而非覆盖——不能因为面板弹过「替换」就删掉一整库笔记。
        do { try WorkspaceManager.createWorkspace(at: url) } catch {
            alert(L("Workspace Error"), error.localizedDescription)
            return false
        }
        return route(url, strict: true)
    }

    @discardableResult
    static func route(_ url: URL, strict: Bool) -> Bool {
        do {
            try WorkspaceRegistry.shared.route(to: url, strict: strict)
            return true
        } catch {
            alert(L("Workspace Error"), error.localizedDescription)
            return false
        }
    }

    static func alert(_ title: String, _ message: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = message
        a.addButton(withTitle: L("OK"))
        a.runModal()
    }
}
