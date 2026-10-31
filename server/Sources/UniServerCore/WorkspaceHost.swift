import Foundation

/// 服务器上全部工作区的入口：列表、按 id 打开、登记上传（方案 `SERVER-MODE-PLAN.md §3.1`）。
///
/// 「有哪些工作区」以磁盘为准：`workspaces/<id>.unrd` 在就是有。登记 = 从 `uploads/` 原子挪过去，
/// 所以不存在「登记了一半」的工作区，也不需要另一张目录表。
/// 同一个工作区全进程只开一个 `HostedWorkspace`（同 App 的「同一路径同一实例」红线）。
public final class WorkspaceHost: @unchecked Sendable {

    public struct Summary: Equatable, Sendable {
        public var id: String
        public var name: String
    }

    public let paths: ServerPaths
    private var opened: [String: HostedWorkspace] = [:]
    private let lock = NSLock()

    public init(paths: ServerPaths) throws {
        self.paths = paths
        try paths.createDirectories()
    }

    public func list() -> [Summary] {
        lock.lock(); defer { lock.unlock() }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: paths.workspaces.path)) ?? []
        return names.filter { $0.hasSuffix(".unrd") }.compactMap { file -> Summary? in
            let id = String(file.dropLast(5))
            // 没有库的文件夹不算（被删的工作区若有迟到的写入，也只会留下空壳）
            guard ServerCrypto.isUUID(id), FileManager.default.fileExists(
                atPath: paths.workspaceFolder(id).appendingPathComponent("UniReader/library.sqlite").path) else { return nil }
            let name = opened[id]?.store.workspaceName
                ?? LibraryStore.peekIdentity(folder: paths.workspaceFolder(id))?.name ?? ""
            return Summary(id: id, name: name)
        }.sorted { $0.name == $1.name ? $0.id < $1.id : $0.name < $1.name }
    }

    /// 按 id 取工作区（id 必须是 UUID——它会拼进路径，别让 `../` 之类的东西进来）。
    public func workspace(_ id: String) throws -> HostedWorkspace {
        guard ServerCrypto.isUUID(id) else { throw ServerError.unknownWorkspace(id) }
        lock.lock(); defer { lock.unlock() }
        if let w = opened[id] { return w }
        let folder = paths.workspaceFolder(id)
        guard FileManager.default.fileExists(atPath: folder.appendingPathComponent("UniReader/library.sqlite").path)
        else { throw ServerError.unknownWorkspace(id) }
        let w = try HostedWorkspace(folder: folder, paths: paths)
        opened[id] = w
        return w
    }

    /// 新建一个上传用的临时文件夹（`uploads/<随机>/`）。
    public func newUploadFolder() throws -> URL {
        let dir = paths.uploads.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("UniReader", isDirectory: true),
                                                withIntermediateDirectories: true)
        return dir
    }

    /// 把上传完整的文件夹登记成服务器工作区。
    @discardableResult
    public func install(uploaded folder: URL) throws -> HostedWorkspace {
        lock.lock(); defer { lock.unlock() }
        let w = try HostedWorkspace.install(uploaded: folder, paths: paths)
        opened[w.id] = w
        return w
    }

    public func closeAll() {
        lock.lock(); defer { lock.unlock() }
        for w in opened.values { w.close() }
        opened.removeAll()
    }

    // MARK: - 删除整个工作区（先归档再删，红线⑪）

    /// 回收站里的一个被删工作区。
    public struct Deleted: Equatable, Sendable {
        public var id: String
        public var name: String
        /// 删除时间（ISO 8601）。
        public var deletedAt: String
        /// 哪台设备删的。
        public var device: String
        /// `trash/<id>/deleted-<时间>/`：里面是 `workspace.unrd`（整个工作区原样）+ `backups/`（它的定时备份）+ `info.json`。
        public var folder: URL
    }

    /// 被删的工作区在回收站里留多少天（同 `ServerTrash.prune` 的行级回收站）。
    public static let deletedKeepDays = 90

    /// 从服务器删除整个工作区：关掉它，**整个文件夹原样挪进** `trash/<id>/deleted-<时间>/`（挪 = 归档，没有「删了一半」），
    /// 定时备份一起挪过去；快照缓存与续传中的半截文件直接删（都能重新生成）。90 天内可以用命令行 `restore` 找回。
    /// 已经拿着这个工作区的请求之后都会得到「没有这个工作区」（`HostedWorkspace.checkOpen`）。
    @discardableResult
    public func delete(_ id: String, device: String, now: Date = .now) throws -> Deleted {
        guard ServerCrypto.isUUID(id) else { throw ServerError.unknownWorkspace(id) }
        lock.lock(); defer { lock.unlock() }
        let fm = FileManager.default
        let folder = paths.workspaceFolder(id)
        guard fm.fileExists(atPath: folder.appendingPathComponent("UniReader/library.sqlite").path) else {
            throw ServerError.unknownWorkspace(id)
        }
        let name = opened[id]?.store.workspaceName ?? LibraryStore.peekIdentity(folder: folder)?.name ?? ""
        // 等它手上的读写做完再关（close 拿的是工作区自己那把锁）
        if let w = opened.removeValue(forKey: id) { w.close() }
        lastBackupHead[id] = nil

        let stamp = ISO.string(now)
        var dir = paths.trashFolder(id).appendingPathComponent(Self.deletedPrefix + Self.fileStamp(stamp), isDirectory: true)
        var n = 2
        while fm.fileExists(atPath: dir.path) {
            dir = paths.trashFolder(id).appendingPathComponent(Self.deletedPrefix + Self.fileStamp(stamp) + "-\(n)", isDirectory: true)
            n += 1
        }
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let info = ["id": id, "name": name, "deletedAt": stamp, "device": device]
        try JSONSerialization.data(withJSONObject: info, options: [.prettyPrinted, .sortedKeys])
            .write(to: dir.appendingPathComponent("info.json"))
        try fm.moveItem(at: folder, to: dir.appendingPathComponent("workspace.unrd", isDirectory: true))
        let backups = paths.backupFolder(id)
        if fm.fileExists(atPath: backups.path) {
            try? fm.moveItem(at: backups, to: dir.appendingPathComponent("backups", isDirectory: true))
        }
        try? fm.removeItem(at: paths.snapshotFolder(id))
        for name in (try? fm.contentsOfDirectory(atPath: paths.partials.path)) ?? [] where name.hasPrefix(id + "-") {
            try? fm.removeItem(at: paths.partials.appendingPathComponent(name))
        }
        return Deleted(id: id, name: name, deletedAt: stamp, device: device, folder: dir)
    }

    static let deletedPrefix = "deleted-"

    /// ISO 时间 → 文件名里用的样子（去掉冒号与毫秒）：`2026-10-30T07-12-33`。
    static func fileStamp(_ iso: String) -> String {
        String(iso.prefix(19)).replacingOccurrences(of: ":", with: "-")
    }

    /// 回收站里全部被删的工作区，新删的在前。
    public func deletedWorkspaces() -> [Deleted] {
        let fm = FileManager.default
        let trash = paths.root.appendingPathComponent("trash", isDirectory: true)
        var out: [Deleted] = []
        for id in (try? fm.contentsOfDirectory(atPath: trash.path)) ?? [] where ServerCrypto.isUUID(id) {
            let base = paths.trashFolder(id)
            for name in (try? fm.contentsOfDirectory(atPath: base.path)) ?? [] where name.hasPrefix(Self.deletedPrefix) {
                let dir = base.appendingPathComponent(name, isDirectory: true)
                guard fm.fileExists(atPath: dir.appendingPathComponent("workspace.unrd").path) else { continue }
                let info = (try? Data(contentsOf: dir.appendingPathComponent("info.json")))
                    .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: String] } ?? [:]
                out.append(Deleted(id: id, name: info["name"] ?? "", deletedAt: info["deletedAt"] ?? "",
                                   device: info["device"] ?? "", folder: dir))
            }
        }
        return out.sorted { $0.deletedAt > $1.deletedAt }
    }

    /// 把最近一次删掉的这个工作区放回来（命令行 `restore`）。服务器上已经有同一个工作区（又上传过一次）就拒绝。
    @discardableResult
    public func restoreDeleted(_ id: String) throws -> Deleted {
        guard let d = deletedWorkspaces().first(where: { $0.id == id }) else { throw ServerError.unknownWorkspace(id) }
        lock.lock(); defer { lock.unlock() }
        let fm = FileManager.default
        let folder = paths.workspaceFolder(id)
        guard !fm.fileExists(atPath: folder.path) else { throw ServerError.alreadyHosted(id) }
        try fm.createDirectory(at: paths.workspaces, withIntermediateDirectories: true)
        try fm.moveItem(at: d.folder.appendingPathComponent("workspace.unrd", isDirectory: true), to: folder)
        let backups = d.folder.appendingPathComponent("backups", isDirectory: true)
        if fm.fileExists(atPath: backups.path), !fm.fileExists(atPath: paths.backupFolder(id).path) {
            try? fm.moveItem(at: backups, to: paths.backupFolder(id))
        }
        try? fm.removeItem(at: d.folder)
        return d
    }

    /// 清掉回收站里删了超过 [keepDays] 天的工作区（每小时那一轮顺带调）。返回清了几个。
    @discardableResult
    public func pruneDeleted(keepDays: Int = deletedKeepDays, now: Date = .now) -> Int {
        let cutoff = ISO.string(now.addingTimeInterval(-Double(keepDays) * 86_400))
        var n = 0
        for d in deletedWorkspaces() where !d.deletedAt.isEmpty && d.deletedAt < cutoff {
            if (try? FileManager.default.removeItem(at: d.folder)) != nil { n += 1 }
        }
        return n
    }

    // MARK: - 上传会话（方案 §5：库和文件逐个传，全部到齐才登记）

    /// 开一个上传会话，返回它的 id（就是 `uploads/` 下那个文件夹的名字）。
    public func newUpload() throws -> String { try newUploadFolder().lastPathComponent }

    func uploadFolder(_ id: String) throws -> URL {
        let dir = paths.uploads.appendingPathComponent(id, isDirectory: true)
        guard ServerCrypto.isUUID(id), FileManager.default.fileExists(atPath: dir.path) else {
            throw ServerError.badRequest("没有这个上传会话（\(id)）")
        }
        return dir
    }

    /// 上传会话里某个文件的落点。只许 `UniReader/library.sqlite` 与 `PDFs/`、`Images/`、`Notes/` 下的普通文件
    /// （不许 `..`、隐藏文件、`.part` 结尾——`.part` 是传输中的半截文件自己用的名字）。
    public func uploadFileURL(upload id: String, path: String) throws -> URL {
        let dir = try uploadFolder(id)
        guard Self.isAcceptableUploadPath(path), let url = HostedWorkspace.resolveInside(dir, path) else {
            throw ServerError.badRequest("不接受这个路径：\(path)")
        }
        return url
    }

    static func isAcceptableUploadPath(_ p: String) -> Bool {
        if p == "UniReader/library.sqlite" { return true }
        let comps = p.split(separator: "/", omittingEmptySubsequences: false)
        guard comps.count >= 2, ["PDFs", "Images", "Notes"].contains(String(comps[0])),
              !p.hasSuffix(".part"), !p.contains("\0") else { return false }
        return comps.allSatisfy { !$0.isEmpty && !$0.hasPrefix(".") }
    }

    /// 上传齐了：登记成服务器工作区。失败时会话文件夹留着（补传后可以再点一次）。
    @discardableResult
    public func finishUpload(_ id: String) throws -> HostedWorkspace {
        let dir = try uploadFolder(id)
        // 没传完的半截文件不带进工作区
        if let walker = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil) {
            for case let url as URL in walker where url.pathExtension == "part" { try? FileManager.default.removeItem(at: url) }
        }
        return try install(uploaded: dir)
    }

    public func cancelUpload(_ id: String) {
        if let dir = try? uploadFolder(id) { try? FileManager.default.removeItem(at: dir) }
    }

    /// 断点续传中的半截文件（PDF / 图片本体）：`uploads/partials/<工作区>-<文件名>.part`。
    /// [name] 由调用方保证安全（内容哈希 + 扩展名）。
    public func partialFile(workspace: String, name: String) -> URL {
        paths.partials.appendingPathComponent("\(workspace)-\(name).part")
    }

    /// 清掉 [maxAge] 秒没动过的上传会话与半截文件（默认 7 天）。
    public func pruneUploads(maxAge: TimeInterval = 7 * 86_400, now: Date = .now) {
        let fm = FileManager.default
        for base in [paths.uploads, paths.partials] {
            for name in (try? fm.contentsOfDirectory(atPath: base.path)) ?? [] where name != "partials" {
                let url = base.appendingPathComponent(name)
                let mtime = (try? fm.attributesOfItem(atPath: url.path)[.modificationDate] as? Date) ?? now
                if now.timeIntervalSince(mtime) > maxAge { try? fm.removeItem(at: url) }
            }
        }
    }

    // MARK: - 定时备份

    private var lastBackupHead: [String: UInt64] = [:]

    /// 修订号比上次备份时变了的工作区各备份一次（启动后第一次调 = 每个都备份一次）。返回备份了几个。
    @discardableResult
    public func backupChanged(now: Date = .now) -> Int {
        var n = 0
        for s in list() {
            guard let w = try? workspace(s.id) else { continue }
            let head = w.head
            lock.lock(); let last = lastBackupHead[s.id]; lock.unlock()
            if last == head { continue }
            if (try? w.backup(now: now)) != nil {
                lock.lock(); lastBackupHead[s.id] = head; lock.unlock()
                n += 1
            }
        }
        return n
    }
}

/// 给 HTTP 层与命令行用的几个常量。
public enum ServerInfo {
    /// 服务器认的工作区数据版本（= App 的 `LibraryStore.schemaVersion`，同一份代码）。
    public static var schemaVersion: Int { LibraryStore.schemaVersion }
    public static let version = "0.2.0"

    /// 内容哈希（SHA-256 小写十六进制）。会拼进文件名，HTTP 层收到就先验。
    public static func isContentHash(_ s: String) -> Bool { ServerCrypto.isSHA256Hex(s) }
    /// 图片扩展名（1~8 位小写字母数字）。
    public static func isImageExt(_ s: String) -> Bool { HostedWorkspace.isSafeExt(s) }
}
