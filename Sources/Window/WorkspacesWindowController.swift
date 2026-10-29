import AppKit
import Combine
import UniformTypeIdentifiers

/// 启动页「工作区」：左边 App 图标与三个按钮，右边分段列表——「本机」一段是最近打开过的工作区，下面每台已连接的服务器一段
/// （2026-10-29 用户要求；视图在 `WorkspacesWelcomeView`，本文件只管数据与动作）。
///
/// 用户定的出现时机：启动时**照旧**直接开上次的工作区；这扇窗从「文件 › 工作区…」（⇧⌘O）打开；
/// 阅读窗口全关掉、或点 Dock 图标而没有窗口时也出现。从这里打开一个工作区后它自己关掉。
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
    private var busy = false
    private var bag = Set<AnyCancellable>()
    private var welcome: WorkspacesWelcomeView!

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
        rebuild()
    }

    /// 重新向每台服务器要一次工作区列表（窗口每次显示时调）。
    func reloadServers() {
        loadToken += 1
        let token = loadToken
        let accounts = ServerAccounts.shared.all
        remote = Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, RemoteState.loading) })
        rebuild()
        let recents = WorkspaceRegistry.shared.recents
        for a in accounts {
            guard let client = ServerAccounts.shared.client(a) else {
                remote[a.id] = .failed(ServerSyncError.noAccount.localizedDescription)
                continue
            }
            Task {
                let state: RemoteState
                do {
                    let list = try await client.workspaces()
                    // 本机有没有这个工作区的副本：最近列表里同一个 id 能解析到的那份（主线程，只是几次 fileExists），
                    // 否则去缓存目录里找（要逐个打开库看身份，放后台）
                    var copies: [String: URL] = [:]
                    for ws in list {
                        if let r = recents.first(where: { $0.id == ws.id }), let u = WorkspaceRegistry.resolve(r) { copies[ws.id] = u }
                    }
                    let rest = list.map(\.id).filter { copies[$0] == nil }
                    let found = await Task.detached { () -> [String: URL] in
                        var out: [String: URL] = [:]
                        for id in rest { if let u = ServerSyncIO.findCache(workspaceId: id) { out[id] = u } }
                        return out
                    }.value
                    copies.merge(found) { a, _ in a }
                    state = .loaded(list, localCopies: copies)
                } catch {
                    state = .failed(error.localizedDescription)
                }
                guard token == self.loadToken else { return }
                self.remote[a.id] = state
                self.rebuild()
            }
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
            let detail = localCopy(a, ws).map { String(format: L("On this Mac · %@"), Self.displayPath($0)) }
                ?? L("Not downloaded yet; opening downloads the library")
            return .entry(icon: Self.symbol("server.rack"), title: ws.name.isEmpty ? L("Untitled Workspace") : ws.name,
                          detail: detail)
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

    // MARK: 动作

    /// 右键：只有「本机」一段的工作区有菜单（服务器那几段是服务器给的列表，本机没有「移除」可言）。
    /// 「从列表中移除」只摘最近列表里这一条，工作区文件夹一个字节都不动。
    private func contextItems(_ i: Int) -> [(title: String, action: () -> Void)] {
        guard rows.indices.contains(i), case .local(let r) = rows[i] else { return [] }
        var out: [(title: String, action: () -> Void)] = []
        if let url = WorkspaceRegistry.resolve(r) {
            out.append((L("Show in Finder"), { NSWorkspace.shared.activateFileViewerSelecting([url]) }))
        }
        out.append((L("Remove from List"), {
            WorkspaceRegistry.shared.removeRecent(URL(fileURLWithPath: r.sourcePath))
        }))
        return out
    }

    private func open(_ i: Int) {
        guard !busy, rows.indices.contains(i) else { return }
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

    /// 本机已有副本就直接开它；没有就先下载资料库建本机缓存（PDF 用到再下）。
    private func openRemote(_ a: ServerAccount, _ ws: ServerClient.WorkspaceInfo) {
        if let copy = localCopy(a, ws) {
            WorkspacePanels.route(copy, strict: true)
            WorkspacesWindowController.closeIfOpen()
            return
        }
        busy = true
        welcome.setStatus(L("Downloading the library…"), busy: true)
        Task {
            do {
                let folder = try await ServerSyncCoordinator.shared.openFromServer(a, ws) { [weak self] step in
                    self?.welcome.setStatus(step, busy: true)
                }
                self.welcome.setStatus("", busy: false)
                WorkspacePanels.route(folder, strict: true)
                WorkspacesWindowController.closeIfOpen()
            } catch {
                self.welcome.setStatus(error.localizedDescription, busy: false)
            }
            self.busy = false
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
