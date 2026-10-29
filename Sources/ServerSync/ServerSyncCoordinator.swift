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

    // MARK: - 从服务器打开

    /// 本机已有这个服务器工作区的缓存就直接用它；没有就下载快照建一份。返回缓存文件夹（调用方再 `route` 过去）。
    func openFromServer(_ a: ServerAccount, _ ws: ServerClient.WorkspaceInfo,
                        progress: @escaping (String) -> Void) async throws -> URL {
        if let existing = await Task.detached(operation: { ServerSyncIO.findCache(workspaceId: ws.id) }).value {
            return existing
        }
        guard let client = ServerAccounts.shared.client(a) else { throw ServerSyncError.noAccount }
        let dir = ServerSyncIO.cachesRoot.appendingPathComponent(ServerSyncIO.hostFolderName(a.url), isDirectory: true)
        let name = ws.name.isEmpty ? L("Workspace") : ws.name
        let labels: [ServerSyncIO.Step: String] = [.library: L("Downloading the library…"),
                                                   .preparing: L("Preparing the local copy…"),
                                                   .images: L("Downloading images…")]
        let url = a.url, sid = a.serverId
        return try await Task.detached(priority: .userInitiated) {
            try await ServerSyncIO.createCache(in: dir, name: name, serverURL: url, serverId: sid,
                                               client: client, wid: ws.id) { step in
                let text = labels[step] ?? ""
                Task { @MainActor in progress(text) }
            }
        }.value
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
    case noAccount, notOnServer, notOpen, alreadyOnServer, hasOfflineCopy

    var errorDescription: String? {
        switch self {
        case .noAccount: return L("This Mac isn’t connected to that server. Connect it in Settings › Servers.")
        case .notOnServer: return L("The server doesn’t have this PDF either.")
        case .notOpen: return L("The workspace isn’t open.")
        case .alreadyOnServer: return L("This workspace is already on a server.")
        case .hasOfflineCopy: return L("This workspace has an offline copy. Sync it back and delete it before uploading.")
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
