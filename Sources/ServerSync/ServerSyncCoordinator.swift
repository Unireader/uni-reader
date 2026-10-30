import Foundation
import AppKit

/// 服务器工作区的同步调度（方案 `SERVER-MODE-PLAN.md §4.3` 的 S2 档）。IO 在 `ServerSyncIO`，这里管时机、状态与界面要的数据。
///
/// | 时机 | 做什么 | 用哪条连接 |
/// |---|---|---|
/// | 打开前（`prepareToOpen`） | 完整一轮：推 + 拉 + 补图片，限时，超时就取消、照常开本机缓存 | 临时连接（此刻还没有 `WorkspaceManager`） |
/// | 开着时（每 60 秒 / App 切到后台 / 手动） | **只推不拉**：不往开着的文档里写（那是 S4 的事）；顺带后台下载小 PDF | 窗口那条连接，基线写在主线程、不开事务 |
/// | 关掉后（`workspaceClosed`） | 完整一轮 | 临时连接（窗口那条已经关了） |
///
/// 🔴 同一工作区一次只跑一轮（`busy`）。打开时**先取消**关闭后那一轮再开窗：那一轮用的是临时连接，与新开的窗口
/// 同时写库就违反「同一路径同一实例」红线（`WorkspaceRegistry`）。取消是安全的——推上去而基线没记的下一轮再推，
/// 拉下来还没应用的修订号没记、下一轮重拉（`SyncClient.roundAsync`）。
@MainActor
final class ServerSyncCoordinator: ObservableObject {
    static let shared = ServerSyncCoordinator()

    enum Status: Equatable {
        case synced(Date)
        case syncing
        /// 连不上服务器：照常用本机缓存。
        case offline(String)
        case failed(String)
        /// 本机没有这台服务器的令牌（没连过、或在设置里断开了）。
        case noAccount
    }

    @Published private(set) var status: [String: Status] = [:]

    func status(of folder: URL?) -> Status? { folder.flatMap { status[WorkspaceRegistry.key($0)] } }

    /// 「大 PDF」的界限：小于它的打开工作区后在后台自动下载，大的等点开再下（方案 §4.1，默认 50MB）。
    /// 键与设置页 `ServerSettingsView.largePDFMB` 同一把，默认值也一致。
    nonisolated static var largePDFBytes: Int64 {
        Int64(max(1, UserDefaults.standard.object(forKey: "serverLargePDFMB") as? Int ?? 50)) * 1_048_576
    }

    /// 是不是服务器工作区（见 `ServerSyncIO.serverURL`）。
    nonisolated static func serverURL(of folder: URL) -> String? { ServerSyncIO.serverURL(of: folder) }

    /// 连这个工作区要用的客户端 + 工作区 id。没有令牌 = nil。
    private func endpoint(for folder: URL) -> (client: ServerClient, wid: String)? {
        guard let link = ServerSyncIO.serverLink(of: folder),
              let account = ServerAccounts.shared.account(serverId: link.serverId, url: link.url),
              let client = ServerAccounts.shared.client(account),
              let wid = LibraryStore.peekIdentity(folder: folder)?.id else { return nil }
        return (client, wid)
    }

    // MARK: - 打开前 / 关闭后（没有活连接的时候）

    private var busy: [String: (token: UUID, task: Task<Void, Never>)] = [:]

    /// 打开服务器工作区之前：取消还在跑的上一轮，再同步一轮，最多等 [timeout] 秒。
    func prepareToOpen(_ folder: URL, timeout: TimeInterval) async {
        let k = WorkspaceRegistry.key(folder)
        // 启动页「下载到本机」还在下 PDF：停掉（开着时由会话自己预取，两边别同时写同一份文件）
        if let wid = LibraryStore.peekIdentity(folder: folder)?.id { await stopWorkspacePDFs(wid) }
        if let running = busy[k] {
            running.task.cancel()
            await running.task.value
        }
        guard let ep = endpoint(for: folder) else {
            if ServerSyncIO.serverURL(of: folder) != nil { status[k] = .noAccount }
            return
        }
        let task = startClosedRound(folder, ep)
        let timer = Task {
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            task.cancel()
        }
        await task.value
        timer.cancel()
    }

    /// 工作区最后一扇窗关掉、连接关闭之后：停掉会话，完整同步一轮（不等它）。
    func workspaceClosed(_ folder: URL) {
        stopSession(folder)
        guard let ep = endpoint(for: folder) else { return }
        _ = startClosedRound(folder, ep, after: busy[WorkspaceRegistry.key(folder)]?.task)
    }

    private func startClosedRound(_ folder: URL, _ ep: (client: ServerClient, wid: String),
                                  after previous: Task<Void, Never>? = nil) -> Task<Void, Never> {
        let k = WorkspaceRegistry.key(folder)
        let token = UUID()
        status[k] = .syncing
        let task = Task.detached(priority: .userInitiated) { [weak self] in
            await previous?.value
            let result: Status
            do {
                try await ServerSyncIO.closedRound(folder: folder, client: ep.client, wid: ep.wid)
                result = .synced(Date())
            } catch {
                result = Self.classify(error)
            }
            await MainActor.run {
                guard let self else { return }
                self.status[k] = result
                if self.busy[k]?.token == token { self.busy[k] = nil }
            }
        }
        busy[k] = (token, task)
        return task
    }

    // MARK: - 开着时（只推不拉）

    private final class Session {
        weak var manager: WorkspaceManager?
        var timer: Timer?
        var pushing = false
        var prefetch: Task<Void, Never>?
    }

    private var sessions: [String: Session] = [:]
    private var observing = false

    /// 服务器工作区开起来了（`WorkspaceRegistry.acquire` 新建实例时调）：起定时推送，后台下载小 PDF。
    func workspaceOpened(_ m: WorkspaceManager) {
        guard let folder = m.folder, m.isServerWorkspace else { return }
        let k = WorkspaceRegistry.key(folder)
        guard sessions[k] == nil else { return }
        let s = Session()
        s.manager = m
        s.timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self, weak m] _ in
            Task { @MainActor in if let m { await self?.push(m) } }
        }
        sessions[k] = s
        s.prefetch = Task { [weak self, weak m] in if let m { await self?.prefetchSmallPDFs(m) } }
        if !observing {
            observing = true
            NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil,
                                                   queue: .main) { [weak self] _ in
                Task { @MainActor in self?.pushAll() }
            }
        }
    }

    private func stopSession(_ folder: URL) {
        guard let s = sessions.removeValue(forKey: WorkspaceRegistry.key(folder)) else { return }
        s.timer?.invalidate()
        s.prefetch?.cancel()
    }

    func pushAll() {
        for s in sessions.values { if let m = s.manager { Task { await push(m) } } }
    }

    /// 只推不拉：找本地改动（后台读）→ 先传新文件 → 推送 → **主线程**逐行记基线（不开事务，见 `SyncClient.recordPushed`）。
    func push(_ m: WorkspaceManager) async {
        guard let folder = m.folder, let store = m.store else { return }
        let k = WorkspaceRegistry.key(folder)
        guard let s = sessions[k], !s.pushing else { return }
        guard let ep = endpoint(for: folder) else { status[k] = .noAccount; return }
        s.pushing = true
        defer { s.pushing = false }
        let db = store.withMirrorDB { $0 }
        do {
            let changes = try await Task.detached(priority: .utility) {
                try SyncClient.localChanges(db, folder: folder)
            }.value
            guard !changes.isEmpty else {
                if status[k] != .syncing { status[k] = .synced(Date()) }
                return
            }
            status[k] = .syncing
            try await ServerSyncIO.uploadFiles(for: changes, db: db, folder: folder, client: ep.client, wid: ep.wid)
            let req = SyncWire.PushRequest(schemaVersion: LibraryStore.schemaVersion, changes: changes)
            let resp = try SyncWire.decodePushResponse(try await ep.client.push(ep.wid, body: SyncWire.encode(req)))
            // 推的时候窗口关了（关闭后那一轮会再推一次）、或变回了本地工作区（基线表已经删了）：不记
            guard m.store != nil, sessions[k] === s else { return }
            try SyncClient.recordPushed(db, pushed: changes, response: resp)
            status[k] = .synced(Date())
        } catch {
            if sessions[k] === s { status[k] = Self.classify(error) }
        }
    }

    // MARK: - PDF

    /// 正在下载的书：工作区键 → 文档 id → 进度（0~1）。侧栏那一行与阅读区占位页都看它（2026-10-29 用户要求「下载进度显示在条目上」）。
    @Published private(set) var downloads: [String: [String: Double]] = [:]
    /// 同一本只下一趟：侧栏右键、占位页按钮、后台预取可能撞上同一本，后来的等先来的那一趟。键 = 工作区键 + 文档 id。
    private var downloadTasks: [String: (token: UUID, task: Task<Bool, Error>)] = [:]

    func downloadProgress(_ m: WorkspaceManager, documentId: String) -> Double? {
        m.folder.flatMap { downloads[WorkspaceRegistry.key($0)]?[documentId] }
    }

    /// 本机没文件的书：服务器上有、而且不大的，后台下载下来。
    private func prefetchSmallPDFs(_ m: WorkspaceManager) async {
        guard let folder = m.folder, let ep = endpoint(for: folder) else { return }
        for doc in m.documents where !m.hasLocalFile(doc.id) {
            if Task.isCancelled || m.store == nil { return }
            _ = try? await fetchDocument(m, documentId: doc.id, folder: folder, ep: ep, maxBytes: Self.largePDFBytes)
        }
    }

    /// 用户点「从服务器下载」（侧栏右键 / 占位页按钮）：不管多大都下（第一个服务器上有的版本）。
    func downloadPDF(_ m: WorkspaceManager, documentId: String) async throws {
        guard let folder = m.folder else { return }
        guard let ep = endpoint(for: folder) else { throw ServerSyncError.noAccount }
        guard try await fetchDocument(m, documentId: documentId, folder: folder, ep: ep, maxBytes: nil) else {
            throw ServerSyncError.notOnServer
        }
    }

    /// 下一本书：第一个服务器上有的版本；给了 [maxBytes] 就只下不超过它的（后台预取）。返回下了没有。
    /// 用户点的那条（`maxBytes == nil`）一开始就记进 `downloads`，行上当场有反应；预取等真开始下了才记，免得大书闪一下。
    private func fetchDocument(_ m: WorkspaceManager, documentId: String, folder: URL,
                               ep: (client: ServerClient, wid: String), maxBytes: Int64?) async throws -> Bool {
        let k = WorkspaceRegistry.key(folder)
        let tk = k + "\n" + documentId
        if let running = downloadTasks[tk] {
            let done = try await running.task.value
            // 撞上的是后台预取、而它嫌太大没下：用户要的这趟自己再下
            if done || maxBytes != nil { return done }
        }
        let task = Task { @MainActor [weak self] () async throws -> Bool in
            for v in m.variants(documentId: documentId) {
                guard let size = try await ep.client.pdfSize(ep.wid, hash: v.contentHash) else { continue }
                if let maxBytes, size > maxBytes { return false }
                guard let self else { return false }
                self.setDownload(k, documentId, 0)
                try await self.fetchPDF(m, variant: v, folder: folder, ep: ep) { [weak self] got in
                    let f = size > 0 ? min(1, Double(got) / Double(size)) : 0
                    Task { @MainActor in self?.setDownload(k, documentId, f) }
                }
                return true
            }
            return false
        }
        let token = UUID()
        downloadTasks[tk] = (token, task)
        if maxBytes == nil { setDownload(k, documentId, 0) }
        defer {
            // 只收自己那一趟（等着它的人可能已经接着开了下一趟）
            if downloadTasks[tk]?.token == token {
                downloadTasks[tk] = nil
                setDownload(k, documentId, nil)
            }
        }
        return try await task.value
    }

    /// 进度只在整百分点变了才发（每次发都会让侧栏去找那一行）；完成 / 失败传 nil 清掉。
    private func setDownload(_ k: String, _ documentId: String, _ fraction: Double?) {
        guard let fraction else {
            guard downloads[k]?[documentId] != nil else { return }
            downloads[k]?[documentId] = nil
            if downloads[k]?.isEmpty == true { downloads[k] = nil }
            return
        }
        // 下完之后迟到的进度回调别把这一行又点亮
        guard downloadTasks[k + "\n" + documentId] != nil else { return }
        if let old = downloads[k]?[documentId], Int(old * 100) == Int(fraction * 100) { return }
        downloads[k, default: [:]][documentId] = fraction
    }

    /// 下载一份 PDF：有工作区内的 location 但文件不在 → 下到那个路径；否则下到 `PDFs/<hash>.pdf` 并补一条 location。
    /// 下完发 `.serverPDFDownloaded`，开着这本书（显示「还没有下载」）的标签据此重新载入。
    private func fetchPDF(_ m: WorkspaceManager, variant v: LibVariant, folder: URL,
                          ep: (client: ServerClient, wid: String),
                          progress: @escaping @Sendable (Int64) -> Void) async throws {
        let existing = m.locations(documentId: v.documentId).first { $0.variantId == v.id && $0.inWorkspace }
        let rel = existing?.path ?? "PDFs/\(v.contentHash).pdf"
        try await ep.client.downloadPDF(ep.wid, hash: v.contentHash, to: folder.appendingPathComponent(rel),
                                        progress: progress)
        guard let store = m.store else { return }
        if existing == nil { _ = try store.addLocation(variantId: v.id, path: rel, inWorkspace: true) }
        m.refreshLocalFileFlags()
        NotificationCenter.default.post(name: .serverPDFDownloaded, object: m, userInfo: ["documentId": v.documentId])
    }

    // MARK: - 从服务器打开 / 下载到本机（启动页）

    /// 启动页上一行服务器工作区的下载进度（2026-10-30 用户要求「启动页右键下载，下载进度显示在条目上」）。
    struct WorkspaceDownload: Equatable {
        /// 这一步在干什么（给人看）。
        var step: String
        /// 这一步的进度 0~1；nil = 还不知道总量。
        var fraction: Double?
    }

    /// 工作区 id → 下载进度。启动页那一行看它。
    @Published private(set) var workspaceDownloads: [String: WorkspaceDownload] = [:]
    /// 建本机缓存（资料库 + 图片）：同一个工作区只跑一趟，启动页点开、右键下载、「从服务器打开」面板撞上了等同一趟。
    private var cacheTasks: [String: Task<URL, Error>] = [:]
    /// 「下载到本机」的第二步（不大的 PDF）。打开这个工作区之前先停掉它（`prepareToOpen`）。
    private var pdfTasks: [String: (token: UUID, task: Task<Void, Error>)] = [:]

    /// 本机已有这个服务器工作区的缓存就直接用它；没有就下载快照建一份。返回缓存文件夹（调用方再 `route` 过去）。
    /// [progress] 只有发起这一趟的调用方收得到（撞上别人那一趟的只等结果）；进度同时记进 `workspaceDownloads`。
    func openFromServer(_ a: ServerAccount, _ ws: ServerClient.WorkspaceInfo,
                        progress: ((String) -> Void)? = nil) async throws -> URL {
        try await ensureCache(a, ws, keepProgress: false, progress: progress)
    }

    private func ensureCache(_ a: ServerAccount, _ ws: ServerClient.WorkspaceInfo, keepProgress: Bool,
                             progress: ((String) -> Void)? = nil) async throws -> URL {
        if let running = cacheTasks[ws.id] { return try await running.value }
        if let existing = await Task.detached(operation: { ServerSyncIO.findCache(workspaceId: ws.id) }).value {
            return existing
        }
        if let running = cacheTasks[ws.id] { return try await running.value }   // 上面等的时候别人先开了一趟
        guard let client = ServerAccounts.shared.client(a) else { throw ServerSyncError.noAccount }
        let dir = ServerSyncIO.cachesRoot.appendingPathComponent(ServerSyncIO.hostFolderName(a.url), isDirectory: true)
        let name = ws.name.isEmpty ? L("Workspace") : ws.name
        let labels: [ServerSyncIO.Step: String] = [.library: L("Downloading the library…"),
                                                   .preparing: L("Preparing the local copy…"),
                                                   .images: L("Downloading images…")]
        let url = a.url, sid = a.serverId, wid = ws.id
        setWorkspaceDownload(wid, labels[.library] ?? "", nil)
        let task = Task.detached(priority: .userInitiated) { [weak self] () async throws -> URL in
            try await ServerSyncIO.createCache(in: dir, name: name, serverURL: url, serverId: sid,
                                               client: client, wid: wid, progress: { step in
                let text = labels[step] ?? ""
                Task { @MainActor in
                    progress?(text)
                    self?.setWorkspaceDownload(wid, text, nil)
                }
            }, fraction: { f in
                Task { @MainActor in self?.updateWorkspaceFraction(wid, f) }
            })
        }
        cacheTasks[wid] = task
        defer { cacheTasks[wid] = nil }
        do {
            let folder = try await task.value
            if !keepProgress { clearWorkspaceDownload(wid) }   // 要接着下 PDF 的，这一行的进度别断
            return folder
        } catch {
            clearWorkspaceDownload(wid)
            throw error
        }
    }

    /// 启动页右键「下载到本机」：建本机缓存，再把不大的 PDF 也下下来（本机缓存的口径：大 PDF 用到再下，方案 §0）。
    /// 已经开着它就只建缓存——开着时会话自己会预取。返回缓存文件夹。
    @discardableResult
    func downloadWorkspace(_ a: ServerAccount, _ ws: ServerClient.WorkspaceInfo) async throws -> URL {
        let wid = ws.id
        let folder = try await ensureCache(a, ws, keepProgress: true)
        if let running = pdfTasks[wid] {   // 已经在下了：等那一趟
            _ = try? await running.task.value
            return folder
        }
        guard WorkspaceRegistry.shared.openManager(at: folder) == nil,
              let client = ServerAccounts.shared.client(a) else {
            clearWorkspaceDownload(wid)
            return folder
        }
        let checking = L("Checking which PDFs to download…")
        let format = L("Downloading PDFs (%d of %d)…")
        setWorkspaceDownload(wid, checking, nil)
        let token = UUID()
        let task = Task.detached(priority: .utility) { [weak self] in
            let list = try await ServerSyncIO.pendingPDFs(folder: folder, client: client, wid: wid,
                                                          maxBytes: Self.largePDFBytes)
            // 打开前那一步会停掉这一趟；万一打开刚好落在建好缓存与开始下 PDF 之间，每本开始前再看一眼
            let notOpen: @Sendable () async -> Bool = {
                await MainActor.run { WorkspaceRegistry.shared.openManager(at: folder) == nil }
            }
            try await ServerSyncIO.downloadPDFs(list, folder: folder, client: client, wid: wid,
                                                keepGoing: notOpen) { i, n, got, total in
                let f = total > 0 ? min(1, Double(got) / Double(total)) : nil
                Task { @MainActor in self?.setWorkspaceDownload(wid, String(format: format, i, n), f) }
            }
        }
        pdfTasks[wid] = (token, task)
        defer {
            if pdfTasks[wid]?.token == token {
                pdfTasks[wid] = nil
                clearWorkspaceDownload(wid)
            }
        }
        do {
            try await task.value
        } catch is CancellationError {
        } catch let e as URLError where e.code == .cancelled {
        }
        return folder
    }

    /// 右键「停止下载」：资料库那一步与 PDF 那一步都停。资料库没下完的不留半截（`createCache` 下在临时文件夹里）。
    func cancelWorkspaceDownload(_ wid: String) {
        cacheTasks[wid]?.cancel()
        pdfTasks[wid]?.task.cancel()
    }

    /// 停掉「下载到本机」还在下的 PDF（等它真停下来）。打开它之前、从服务器删除之前调。
    func stopWorkspacePDFs(_ wid: String) async {
        guard let running = pdfTasks[wid] else { return }
        running.task.cancel()
        _ = try? await running.task.value
    }

    private func setWorkspaceDownload(_ wid: String, _ step: String, _ fraction: Double?) {
        let new = WorkspaceDownload(step: step, fraction: fraction)
        // 整百分点或这一步变了才发（每次发启动页都要找那一行）
        if let old = workspaceDownloads[wid], old.step == step,
           old.fraction.map({ Int($0 * 100) }) == fraction.map({ Int($0 * 100) }) { return }
        workspaceDownloads[wid] = new
    }

    private func updateWorkspaceFraction(_ wid: String, _ fraction: Double?) {
        guard let cur = workspaceDownloads[wid] else { return }   // 下完之后迟到的进度别把这一行又点亮
        setWorkspaceDownload(wid, cur.step, fraction)
    }

    private func clearWorkspaceDownload(_ wid: String) {
        if workspaceDownloads[wid] != nil { workspaceDownloads[wid] = nil }
    }

    // MARK: - 改名 / 从服务器删除（启动页右键）

    /// 改服务器工作区的名字。本机有副本时调用方走本机改名（`WorkspaceRenamer`），改完由同步带上去；
    /// 这里只给**本机没有副本**的用：让服务器直接改（别的设备下次同步拿到新名字）。
    func renameOnServer(_ a: ServerAccount, _ ws: ServerClient.WorkspaceInfo, to name: String) async throws {
        guard let client = ServerAccounts.shared.client(a) else { throw ServerSyncError.noAccount }
        do {
            _ = try await client.renameWorkspace(ws.id, name: name)
        } catch let e as ServerClient.Failure where e.isUnsupportedRoute {
            throw ServerSyncError.serverTooOld
        }
    }

    /// 本机副本已经改了名的服务器工作区：顺手让服务器也改（启动页的服务器那一段马上就是新名字，不用等同步）。
    func renameOnServer(folder: URL, to name: String) async throws {
        guard let ep = endpoint(for: folder) else { throw ServerSyncError.noAccount }
        do {
            _ = try await ep.client.renameWorkspace(ep.wid, name: name)
        } catch let e as ServerClient.Failure where e.isUnsupportedRoute {
            throw ServerSyncError.serverTooOld
        }
    }

    /// 这台 Mac 上的副本在「从服务器删除」之后怎么处理的。
    enum LocalCopyFate: Equatable {
        case none
        /// App 缓存目录里的副本：移到了废纸篓（还能从废纸篓拿回来）。
        case trashed
        /// 就地变成缓存的原件（如移动硬盘上的）：变回了本地工作区，原地不动。
        case detached(URL)
    }

    /// 从服务器删除整个工作区（启动页右键、确认两次之后）。服务器那边先把它整个挪进回收站（90 天内能在服务器上找回）。
    /// 本机副本（[localCopy]）：App 缓存目录里的移到废纸篓；不在缓存目录里的（就地变成缓存的原件）变回本地工作区。
    /// 🔴 本机副本开着窗口时不许删（调用方先拦；这里再兜一道）。别的设备上的副本不动，它们之后同步会报「服务器上没有这个工作区」。
    func deleteFromServer(_ a: ServerAccount, _ ws: ServerClient.WorkspaceInfo,
                          localCopy: URL?) async throws -> LocalCopyFate {
        if let localCopy, WorkspaceRegistry.shared.openManager(at: localCopy) != nil
            || WorkspaceRegistry.shared.hasWindow(forWorkspace: localCopy) {
            throw ServerSyncError.workspaceOpen
        }
        guard let client = ServerAccounts.shared.client(a) else { throw ServerSyncError.noAccount }
        // 还在建本机缓存的：停掉并等它收尾，免得删完之后才冒出一份缓存
        if let building = cacheTasks[ws.id] {
            building.cancel()
            _ = try? await building.value
        }
        await stopWorkspacePDFs(ws.id)
        do {
            try await client.deleteWorkspace(ws.id)
        } catch let e as ServerClient.Failure where e.isUnsupportedRoute {
            throw ServerSyncError.serverTooOld
        } catch let e as ServerClient.Failure where e.status == 404 {
            // 别的设备已经删掉了：照常处理本机副本
        }
        guard let folder = localCopy else { return .none }
        let k = WorkspaceRegistry.key(folder)
        if let running = busy[k] {   // 关掉后那一轮还在跑：停掉再动文件夹
            running.task.cancel()
            await running.task.value
        }
        status[k] = nil
        if Self.isInCachesFolder(folder) {
            try FileManager.default.trashItem(at: folder, resultingItemURL: nil)
            WorkspaceRegistry.shared.removeRecent(folder)
            return .trashed
        }
        let store = try LibraryStore(workspaceFolder: folder)
        defer { store.close() }
        try store.withMirrorDB { try SyncClient.detach($0) }
        return .detached(folder)
    }

    // MARK: - 文件夹改名

    /// 工作区包改了名（`WorkspaceManager.rename` 联动包名）：按新路径重记各张表，否则开着时的推送找不到自己的会话。
    func folderMoved(from old: URL, to new: URL) {
        let ok = WorkspaceRegistry.key(old), nk = WorkspaceRegistry.key(new)
        guard ok != nk else { return }
        if let v = status.removeValue(forKey: ok) { status[nk] = v }
        if let v = busy.removeValue(forKey: ok) { busy[nk] = v }
        if let v = sessions.removeValue(forKey: ok) { sessions[nk] = v }
        if let v = downloads.removeValue(forKey: ok) { downloads[nk] = v }
        for (key, v) in downloadTasks where key.hasPrefix(ok + "\n") {
            downloadTasks[key] = nil
            downloadTasks[nk + key.dropFirst(ok.count)] = v
        }
    }

    /// 等这个工作区还在跑的那一轮（关掉后那一轮）跑完。没开着的工作区要用临时连接写库之前调。
    func waitForIdle(_ folder: URL) async {
        if let running = busy[WorkspaceRegistry.key(folder)] { await running.task.value }
    }

    /// 没开着的服务器工作区：用临时连接完整同步一轮（本机改了名字之后推上去）。
    func syncClosed(_ folder: URL) {
        guard let ep = endpoint(for: folder) else { return }
        _ = startClosedRound(folder, ep, after: busy[WorkspaceRegistry.key(folder)]?.task)
    }

    // MARK: - 上传本地工作区

    /// 把当前这个本地工作区传到服务器，成功后它就地变成这台服务器上那个工作区的本机缓存（方案 §5 第 4 步，内置盘的情形）。
    func upload(_ m: WorkspaceManager, to a: ServerAccount,
                progress: @escaping (String, Double) -> Void) async throws -> (ServerClient.WorkspaceInfo, missingPDFs: Int) {
        guard let store = m.store, let folder = m.folder else { throw ServerSyncError.notOpen }
        guard !m.isServerWorkspace else { throw ServerSyncError.alreadyOnServer }
        guard !m.isMirror, WorkspaceRegistry.shared.mirrorPath(forSource: folder, id: m.workspaceId) == nil else {
            throw ServerSyncError.hasOfflineCopy
        }
        guard let client = ServerAccounts.shared.client(a) else { throw ServerSyncError.noAccount }
        _ = try store.ensureWorkspaceId()
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("unireader-upload-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: staging) }

        progress(L("Preparing…"), 0)
        let plan = try await Task.detached(priority: .userInitiated) {
            try ServerSyncIO.prepareUpload(store: store, folder: folder, staging: staging)
        }.value
        let libraryLabel = L("Uploading the library…")
        let filesFormat = L("Uploading files (%d of %d)…")
        let ws = try await ServerSyncIO.upload(plan, client: client) { index, count, fraction in
            let text = index == 0 ? libraryLabel : String(format: filesFormat, index, count)
            Task { @MainActor in progress(text, fraction) }
        }
        // 记成服务器工作区：主线程写（这条连接窗口也在用）
        try store.setMeta(SyncClient.metaServerURL, a.url)
        if let sid = a.serverId { try store.setMeta(SyncClient.metaServerID, sid) }
        try store.withMirrorDB { try SyncClient.writeBase($0, plan.base, pulledRev: ws.head) }
        m.objectWillChange.send()
        status[WorkspaceRegistry.key(folder)] = .synced(Date())
        workspaceOpened(m)
        return (ws, plan.missingPDFs)
    }

    // MARK: - 变回本地工作区

    /// 停掉同步、去掉库里记的服务器（`SyncClient.detach`），它就是普通的本地工作区了。服务器上那份不动，不连服务器也能做。
    /// 只给不在缓存目录里的（就地变成缓存的原件，如移动硬盘上的）用：缓存目录里的变回本地也还藏在 App 的数据目录里。
    func detach(_ m: WorkspaceManager) async throws {
        guard let store = m.store, let folder = m.folder, m.isServerWorkspace else { throw ServerSyncError.notOpen }
        let k = WorkspaceRegistry.key(folder)
        stopSession(folder)
        if let running = busy[k] {
            running.task.cancel()
            await running.task.value
        }
        try store.withMirrorDB { try SyncClient.detach($0) }
        status[k] = nil
        m.objectWillChange.send()
    }

    /// 这个文件夹是不是 App 自己建的缓存（`cachesRoot` 下面）。
    nonisolated static func isInCachesFolder(_ folder: URL) -> Bool {
        folder.standardizedFileURL.path.hasPrefix(ServerSyncIO.cachesRoot.standardizedFileURL.path + "/")
    }

    // MARK: - 错误

    nonisolated static func classify(_ error: Error) -> Status {
        if error is CancellationError { return .offline(L("Timed out; using the local copy")) }
        if let e = error as? URLError {
            return e.code == .cancelled ? .offline(L("Timed out; using the local copy")) : .offline(e.localizedDescription)
        }
        if let e = error as? ServerSyncError, e == .noAccount { return .noAccount }
        return .failed(error.localizedDescription)
    }
}

extension Notification.Name {
    /// 服务器工作区里一本书下载完了（object = `WorkspaceManager`，userInfo `documentId`）。
    static let serverPDFDownloaded = Notification.Name("com.xvan.UniReader.serverPDFDownloaded")
}

enum ServerSyncError: LocalizedError, Equatable {
    case noAccount, notOnServer, notOpen, alreadyOnServer, hasOfflineCopy, serverTooOld, workspaceOpen

    var errorDescription: String? {
        switch self {
        case .noAccount: return L("This Mac isn’t connected to that server. Connect it in Settings › Servers.")
        case .notOnServer: return L("The server doesn’t have this PDF either.")
        case .notOpen: return L("The workspace isn’t open.")
        case .alreadyOnServer: return L("This workspace is already on a server.")
        case .hasOfflineCopy: return L("This workspace has an offline copy. Sync it back and delete it before uploading.")
        case .serverTooOld: return L("The server program is too old for this. Update the server first.")
        case .workspaceOpen: return L("Close this workspace’s windows first.")
        }
    }
}

// MARK: - WorkspaceManager

extension WorkspaceManager {
    /// 连的哪台服务器（`meta.srv_url`）；本地工作区 = nil。
    var serverURL: String? {
        let v = store?.meta(SyncClient.metaServerURL)
        return (v?.isEmpty ?? true) ? nil : v
    }

    var isServerWorkspace: Bool { serverURL != nil }
}
