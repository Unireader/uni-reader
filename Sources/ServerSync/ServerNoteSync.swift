import Foundation

/// 服务器同步里**笔记文件**的那一半（方案 `SERVER-MODE-PLAN.md §4.4 / §13.12`，线格式 `PROTOCOL.md §9.5`）。
///
/// 与库里的行不同，`Notes/` 下的 Markdown 正文和附件是文件，按文件整份同步：服务器给每个文件一个修订号，
/// 本机在 `UniReader/note-sync.json` 里记「上次同步时这个文件的（修订号, 内容哈希, 大小, 修改时间）」当基线。
/// 三方判定（本机现状 L / 基线 B / 服务器现状 S）见 `syncBuiltIn`。
///
/// 🔴 红线⑨ 正文一个字不改：两边都改过的文件，服务器那份留在原路径，本机那份另存成
/// `<原名> (冲突 <设备名> <日期>).md`（`SyncNotes.conflictPath`）并上传——两份字节都在，由用户自己处理。
/// 🔴 红线⑪ 先归档再删：别的设备删了的文件，本机挪进 `Notes/.trash/<时间>/`（隐藏目录，侧栏与同步都不看它）；
/// 服务器那边被覆盖 / 被删的旧版本进它的回收站。
///
/// 另外这里还做**引用笔记目录的服务器镜像**（`MARKDOWN-NOTES-PLAN.md §11`）：
/// 本机有这个目录 → 把它整个传上去（本机文件为准）；本机没有 → 从服务器拉一份只读副本到 `NotesMirror/<源 id>/`。
///
/// 只依赖 Foundation + `Sources/Sync` + `ServerClient`，spike 能直接编（`spike/server-client-test.swift`）。
enum ServerNoteSync {

    // MARK: - 类型

    /// 基线：上次同步时这个文件的样子。`size` + `mtime` 没变就认为内容没变，省得每轮都把所有文件重新算一遍哈希。
    struct Base: Codable, Equatable {
        var rev: UInt64
        var sha: String
        var size: Int64
        var mtime: Double
    }

    struct Report: Equatable {
        var pushed = 0              // 上传了几个文件
        var pulled = 0              // 下载了几个
        var removedLocal = 0        // 别的设备删了，本机挪进了 .trash
        var removedRemote = 0       // 本机删了，服务器上也删了
        var skipped = 0             // 服务器上又变过，这轮没动，留给下一轮
        var conflicts: [String] = []    // 另存的冲突副本（相对路径）
        var failed: [String] = []       // 单个文件出错（读写、路径不对、太大）：「路径：原因」
        var mirrorPushed = 0        // 引用目录镜像：上传 / 下载 / 本机多出来的清掉
        var mirrorPulled = 0
        var mirrorRemoved = 0

        /// 这一轮对文件有没有任何改动。
        var touched: Bool {
            pushed + pulled + removedLocal + removedRemote + mirrorPushed + mirrorPulled + mirrorRemoved > 0
                || !conflicts.isEmpty
        }
        var summary: String {
            "上传 \(pushed) 下载 \(pulled) 本机清走 \(removedLocal) 服务器删 \(removedRemote) 留待下轮 \(skipped) "
                + "冲突 \(conflicts.count) 失败 \(failed.count) · 镜像 上传 \(mirrorPushed) 下载 \(mirrorPulled) 清理 \(mirrorRemoved)"
        }
    }

    enum Mode {
        /// 完整一轮：先问服务器现状，推 + 拉 + 冲突副本 + 引用目录镜像。**只在没有窗口开着这个工作区时跑**（要改本机文件）。
        case full
        /// 开着工作区时：只推。不问服务器、不改本机已有的文件；服务器上又变过的留给下一次完整一轮。
        case pushOnly
    }

    /// `note_sources` 里的一个引用目录。
    struct ReferenceSource: Equatable {
        var id: String
        var paths: [String]
    }

    // MARK: - 入口

    /// 同步这个工作区的全部笔记文件。同一个工作区同一时刻只跑一个（后来的排队）。
    /// 网络 / 认证 / 服务器错误往外抛（整轮放弃）；单个文件的问题记进 `Report.failed`、不影响别的文件。
    @discardableResult
    static func sync(folder: URL, client: ServerClient, wid: String,
                     sources: [ReferenceSource], mode: Mode) async throws -> Report {
        let key = folder.standardizedFileURL.path
        await Gate.shared.acquire(key)
        defer { Task { await Gate.shared.release(key) } }

        let ctx = Context(folder: folder, client: client, wid: wid)
        ctx.base = loadBase(folder)
        defer { saveBase(ctx.base, folder: folder) }      // 取消 / 出错也要把已经做完的记下来

        var server: [String: SyncNotes.Entry]?
        if mode == .full {
            let list = try await client.listNotes(wid)
            server = Dictionary(list.files.map { ($0.path, $0) }, uniquingKeysWith: { $0.rev >= $1.rev ? $0 : $1 })
        }
        try await syncBuiltIn(ctx, server: server)
        if let server {
            for src in sources where isSafeSourceID(src.id) {
                try await syncMirror(ctx, src, server: server)
            }
        }
        return ctx.report
    }

    // MARK: - 内建 `Notes/`（双向）

    /// 判定表（L = 本机现状，B = 基线，S = 服务器现状；`S活` = 服务器上有且没删）：
    ///
    /// | S活 | L | B | 做什么 |
    /// |---|---|---|---|
    /// | 有 | 有，与 S 相同 | — | 记基线（两边已经一致，如首次上传之后）|
    /// | 有 | 有，与 S 不同 | 无 | **冲突**（两边各自新建了同名文件）|
    /// | 有 | 有，与 B 相同 | 有 | 本机没动 → **下载** |
    /// | 有 | 有，与 B 不同 | S.rev == B.rev | 只有本机改了 → **上传**（base = B.rev）|
    /// | 有 | 有，与 B 不同 | S.rev != B.rev | 两边都改了 → **冲突** |
    /// | 有 | 无 | 有，S.rev == B.rev | 本机删了 → **删服务器的**（base = B.rev）|
    /// | 有 | 无 | 无，或 S.rev != B.rev | **下载**（新文件；或本机删了但别处又改过——改动优先于删除）|
    /// | 无 / 墓碑 | 有 | 有，与 B 相同，且是墓碑 | 别的设备删了 → 本机挪进 `.trash` |
    /// | 无 / 墓碑 | 有 | 其余 | **上传**（本机新建；或本机改过而别处删了——改动优先于删除）|
    /// | 无 / 墓碑 | 无 | — | 清掉基线 |
    ///
    /// 「服务器上压根没记录」（不是墓碑）绝不当成「被删了」：服务器数据被还原过的话，设备不能跟着把自己的笔记删光。
    private static func syncBuiltIn(_ ctx: Context, server: [String: SyncNotes.Entry]?) async throws {
        let tree = Tree(prefix: SyncNotes.prefix, root: ctx.folder.appendingPathComponent(SyncNotes.folderName, isDirectory: true))
        var locals: [String: SyncNotes.Item] = [:]
        var oversize = Set<String>()
        for it in SyncNotes.scan(dir: tree.root, relPrefix: tree.prefix) {
            if it.size > SyncNotes.maxFileBytes { oversize.insert(it.rel) } else { locals[it.rel] = it }
        }
        var paths = Set(locals.keys)
        paths.formUnion(ctx.base.keys.filter { $0.hasPrefix(tree.prefix) })
        if let server { paths.formUnion(server.keys.filter { $0.hasPrefix(tree.prefix) }) }
        paths.subtract(oversize)        // 太大的不同步，也不能因为「没扫到」当成被删了

        for path in paths.sorted() {
            try Task.checkCancellation()
            do {
                try await syncOne(ctx, tree, path, local: locals[path], server: server)
            } catch {
                try ctx.absorb(error, path)
            }
        }
    }

    private static func syncOne(_ ctx: Context, _ tree: Tree, _ path: String, local item: SyncNotes.Item?,
                                server: [String: SyncNotes.Entry]?) async throws {
        let url = tree.url(path)
        let B = ctx.base[path]
        let lsha = try item.map { try ctx.sha(of: url, item: $0, cached: B) }

        // 开着工作区：只推。不问服务器，所以不知道别处的改动——对不上的一律留给下一次完整一轮。
        guard let server else {
            if let item, let lsha {
                if let B, B.sha == lsha { return }
                try await ctx.push(tree, path, base: B?.rev ?? 0, item: item, sha: lsha)
            } else if let B {
                try await ctx.remove(path, base: B.rev)
            }
            return
        }

        let S = server[path]
        let alive = (S?.deleted == false) ? S : nil
        if let alive {
            if let item, let lsha {
                if lsha == alive.sha256 { ctx.record(path, rev: alive.rev, sha: lsha, item: item); return }
                guard let B else { try await ctx.conflict(tree, path, server: alive, taken: server); return }
                if lsha == B.sha {
                    try await ctx.pull(tree, path, alive)
                } else if alive.rev == B.rev {
                    try await ctx.push(tree, path, base: B.rev, item: item, sha: lsha)
                } else {
                    try await ctx.conflict(tree, path, server: alive, taken: server)
                }
            } else if let B, alive.rev == B.rev {
                try await ctx.remove(path, base: B.rev)
            } else {
                try await ctx.pull(tree, path, alive)
            }
        } else if let item, let lsha {
            if let B, B.sha == lsha, S?.deleted == true {
                try ctx.trashLocal(tree, path)
                ctx.base[path] = nil
                ctx.report.removedLocal += 1
            } else {
                try await ctx.push(tree, path, base: 0, item: item, sha: lsha)
            }
        } else {
            ctx.base[path] = nil
        }
    }

    // MARK: - 引用目录镜像（`MARKDOWN-NOTES-PLAN.md §11`）

    private static func syncMirror(_ ctx: Context, _ src: ReferenceSource, server: [String: SyncNotes.Entry]) async throws {
        let prefix = SyncNotes.mirrorPrefix(source: src.id)
        if let dir = src.paths.first(where: isDirectory) {
            try await publishMirror(ctx, Tree(prefix: prefix, root: URL(fileURLWithPath: dir, isDirectory: true)), server: server)
        } else {
            let root = ctx.folder.appendingPathComponent("\(SyncNotes.mirrorFolderName)/\(src.id)", isDirectory: true)
            try await subscribeMirror(ctx, Tree(prefix: prefix, root: root), server: server)
        }
    }

    /// 本机有这个目录：本机文件为准，整个传上去（服务器上多出来的删掉）。base 一律取服务器现在的修订号，不吵冲突。
    /// 🔴 本机一个文件都没扫到时什么都不动：外置盘没挂上、目录被清空，都不该把服务器上的镜像删光。
    private static func publishMirror(_ ctx: Context, _ tree: Tree, server: [String: SyncNotes.Entry]) async throws {
        var locals: [String: SyncNotes.Item] = [:]
        var oversize = Set<String>()
        for it in SyncNotes.scan(dir: tree.root, relPrefix: tree.prefix) {
            if it.size > SyncNotes.maxFileBytes { oversize.insert(it.rel) } else { locals[it.rel] = it }
        }
        guard !locals.isEmpty else { return }
        for path in locals.keys.sorted() {
            try Task.checkCancellation()
            guard let item = locals[path] else { continue }
            do {
                let url = tree.url(path)
                let sha = try ctx.sha(of: url, item: item, cached: ctx.base[path])
                let S = server[path]
                if let S, !S.deleted, S.sha256 == sha {
                    ctx.record(path, rev: S.rev, sha: sha, item: item)
                    continue
                }
                let before = ctx.report.pushed
                try await ctx.push(tree, path, base: (S?.deleted == false) ? S!.rev : 0, item: item, sha: sha)
                ctx.report.mirrorPushed += ctx.report.pushed - before
                ctx.report.pushed = before
            } catch {
                try ctx.absorb(error, path)
            }
        }
        for (path, S) in server.sorted(by: { $0.key < $1.key })
        where path.hasPrefix(tree.prefix) && !S.deleted && locals[path] == nil && !oversize.contains(path) {
            try Task.checkCancellation()
            do {
                let before = ctx.report.removedRemote
                try await ctx.remove(path, base: S.rev)
                ctx.report.mirrorRemoved += ctx.report.removedRemote - before
                ctx.report.removedRemote = before
            } catch {
                try ctx.absorb(error, path)
            }
        }
    }

    /// 本机没有这个目录：把服务器上的镜像拉到 `NotesMirror/<id>/`，只读（本机不会往里写，也不会往服务器推）。
    private static func subscribeMirror(_ ctx: Context, _ tree: Tree, server: [String: SyncNotes.Entry]) async throws {
        let fm = FileManager.default
        var seenAlive = Set<String>()
        for (path, S) in server.sorted(by: { $0.key < $1.key }) where path.hasPrefix(tree.prefix) {
            try Task.checkCancellation()
            do {
                let url = tree.url(path)
                if S.deleted {
                    if fm.fileExists(atPath: url.path) { try fm.removeItem(at: url); ctx.report.mirrorRemoved += 1 }
                    ctx.base[path] = nil
                    continue
                }
                seenAlive.insert(path)
                if let attrs = try? fm.attributesOfItem(atPath: url.path) {
                    let size = (attrs[.size] as? NSNumber)?.int64Value ?? -1
                    let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
                    if let B = ctx.base[path], B.rev == S.rev, B.size == size, B.mtime == mtime { continue }
                    if try SyncNotes.sha256Hex(fileAt: url) == S.sha256 {
                        ctx.base[path] = Base(rev: S.rev, sha: S.sha256, size: size, mtime: mtime)
                        continue
                    }
                }
                let before = ctx.report.pulled
                try await ctx.pull(tree, path, S)
                ctx.report.mirrorPulled += ctx.report.pulled - before
                ctx.report.pulled = before
            } catch {
                try ctx.absorb(error, path)
            }
        }
        // 以前拉下来、服务器上已经没有记录的：清掉（镜像文件是可再生的，不进 .trash）
        for path in ctx.base.keys where path.hasPrefix(tree.prefix) && server[path] == nil {
            try? fm.removeItem(at: tree.url(path))
            ctx.base[path] = nil
            ctx.report.mirrorRemoved += 1
        }
    }

    // MARK: - 一轮里共用的状态与动作

    private struct Tree {
        let prefix: String      // `Notes/` 或 `NotesMirror/<id>/`
        let root: URL           // 这棵树的本机根目录
        func url(_ rel: String) -> URL { root.appendingPathComponent(String(rel.dropFirst(prefix.count))) }
    }

    private final class Context {
        let folder: URL
        let client: ServerClient
        let wid: String
        var base: [String: Base] = [:]
        var report = Report()
        let fm = FileManager.default

        init(folder: URL, client: ServerClient, wid: String) {
            self.folder = folder; self.client = client; self.wid = wid
        }

        /// 内容哈希：基线里记着的（大小, 修改时间）没变就直接用基线的，不读文件。
        func sha(of url: URL, item: SyncNotes.Item, cached: Base?) throws -> String {
            if let c = cached, c.size == item.size, c.mtime == item.mtime { return c.sha }
            return try SyncNotes.sha256Hex(fileAt: url)
        }

        func attrs(_ url: URL) -> (size: Int64, mtime: Double) {
            let a = (try? fm.attributesOfItem(atPath: url.path)) ?? [:]
            return ((a[.size] as? NSNumber)?.int64Value ?? 0, (a[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)
        }

        func record(_ path: String, rev: UInt64, sha: String, item: SyncNotes.Item) {
            base[path] = Base(rev: rev, sha: sha, size: item.size, mtime: item.mtime)
        }

        func tempURL(near url: URL) -> URL {
            url.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).part")
        }

        /// 临时文件换到 [url]（目录不在就建；已有文件原子替换）。
        func install(_ tmp: URL, at url: URL) throws {
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fm.fileExists(atPath: url.path) { _ = try fm.replaceItemAt(url, withItemAt: tmp) } else { try fm.moveItem(at: tmp, to: url) }
        }

        /// 从服务器取下来，换到本机。基线记成下载到的修订号 + 实际内容的哈希（取的过程中服务器又变了也对得上）。
        func pull(_ tree: Tree, _ path: String, _ entry: SyncNotes.Entry) async throws {
            let url = tree.url(path)
            let tmp = tempURL(near: url)
            defer { try? fm.removeItem(at: tmp) }
            let rev = try await client.downloadNote(wid, path: path, to: tmp)
            let sha = try SyncNotes.sha256Hex(fileAt: tmp)
            try install(tmp, at: url)
            let a = attrs(url)
            base[path] = Base(rev: rev, sha: sha, size: a.size, mtime: a.mtime)
            report.pulled += 1
        }

        /// 上传。服务器说「又变过」（stale）就不动，留给下一次完整一轮。
        func push(_ tree: Tree, _ path: String, base baseRev: UInt64, item: SyncNotes.Item, sha: String) async throws {
            let url = tree.url(path)
            switch try await client.putNote(wid, path: path, base: baseRev, file: url) {
            case .ok(let rev):
                record(path, rev: rev, sha: sha, item: item)
                report.pushed += 1
            case .stale:
                report.skipped += 1
            }
        }

        /// 本机删了 → 服务器上也删（旧版本在服务器的回收站里）。
        func remove(_ path: String, base baseRev: UInt64) async throws {
            switch try await client.deleteNote(wid, path: path, base: baseRev) {
            case .ok:
                base[path] = nil
                report.removedRemote += 1
            case .stale:
                report.skipped += 1
            }
        }

        /// 别的设备删了、本机没动：挪进 `<根>/.trash/<时间>/`（不是抹掉）。
        func trashLocal(_ tree: Tree, _ path: String) throws {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "yyyyMMdd-HHmmss"
            let rel = String(path.dropFirst(tree.prefix.count))
            let dst = tree.root.appendingPathComponent(".trash/\(f.string(from: Date()))/\(rel)")
            try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fm.fileExists(atPath: dst.path) { try fm.removeItem(at: dst) }
            try fm.moveItem(at: tree.url(path), to: dst)
        }

        /// 两边都改过：服务器那份换到原路径，本机那份另存成冲突副本并上传。两份字节都在。
        /// 顺序：先把服务器版本取到临时文件（取不到就什么都没动）→ 复制本机版本 → 换掉原路径 → 上传副本。
        func conflict(_ tree: Tree, _ path: String, server entry: SyncNotes.Entry,
                      taken: [String: SyncNotes.Entry]) async throws {
            let url = tree.url(path)
            let tmp = tempURL(near: url)
            defer { try? fm.removeItem(at: tmp) }
            let rev = try await client.downloadNote(wid, path: path, to: tmp)
            let sha = try SyncNotes.sha256Hex(fileAt: tmp)

            let copyPath = SyncNotes.conflictPath(for: path, device: client.deviceName, date: Date()) { cand in
                taken[cand] != nil || base[cand] != nil || fm.fileExists(atPath: tree.url(cand).path)
            }
            let copyURL = tree.url(copyPath)
            try fm.createDirectory(at: copyURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(at: url, to: copyURL)
            try install(tmp, at: url)
            let a = attrs(url)
            base[path] = Base(rev: rev, sha: sha, size: a.size, mtime: a.mtime)
            report.conflicts.append(copyPath)
            report.pulled += 1

            let ca = attrs(copyURL)
            let item = SyncNotes.Item(rel: copyPath, size: ca.size, mtime: ca.mtime)
            try await push(tree, copyPath, base: 0, item: item, sha: try SyncNotes.sha256Hex(fileAt: copyURL))
        }

        /// 单个文件的错误：网络 / 认证 / 服务器出错与取消往外抛（整轮放弃）；其余记下来，继续下一个。
        func absorb(_ error: Error, _ path: String) throws {
            if error is CancellationError || error is URLError { throw error }
            if let f = error as? ServerClient.Failure, case .http(let code, _) = f {
                if f.isUnsupportedRoute || code == 401 || code == 403 || code >= 500 { throw error }
            }
            report.failed.append("\(path)：\(error.localizedDescription)")
        }
    }

    /// 同一个工作区的笔记同步排队：开着时每分钟的推送、关掉后的完整一轮可能撞上。
    private actor Gate {
        static let shared = Gate()
        private var held = Set<String>()
        private var waiters: [String: [CheckedContinuation<Void, Never>]] = [:]

        func acquire(_ key: String) async {
            if !held.contains(key) { held.insert(key); return }
            await withCheckedContinuation { waiters[key, default: []].append($0) }
        }

        func release(_ key: String) {
            if var w = waiters[key], !w.isEmpty {
                let next = w.removeFirst()
                waiters[key] = w.isEmpty ? nil : w
                next.resume()
            } else {
                held.remove(key)
            }
        }
    }

    // MARK: - 基线文件

    static func baseFile(_ folder: URL) -> URL { folder.appendingPathComponent("UniReader/note-sync.json") }

    static func loadBase(_ folder: URL) -> [String: Base] {
        guard let data = try? Data(contentsOf: baseFile(folder)) else { return [:] }
        return (try? JSONDecoder().decode([String: Base].self, from: data)) ?? [:]
    }

    static func saveBase(_ base: [String: Base], folder: URL) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? enc.encode(base) else { return }
        try? data.write(to: baseFile(folder), options: .atomic)
    }

    // MARK: - 引用目录

    /// 库里 `meta.note_sources`（`MARKDOWN-NOTES-PLAN.md §10`）里的引用目录。
    static func referenceSources(db: SQLiteDB) -> [ReferenceSource] {
        guard let json = (try? db.query("SELECT value FROM meta WHERE key='note_sources'"))?.first?["value"] as? String,
              let data = json.data(using: .utf8),
              let list = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return [] }
        return list.compactMap { d in
            guard d["kind"] as? String == "reference", let id = d["id"] as? String else { return nil }
            let paths = (d["paths"] as? [String]) ?? (d["path"] as? String).map { [$0] } ?? []
            return ReferenceSource(id: id, paths: paths.filter { !$0.isEmpty })
        }
    }

    /// 源 id 会拼进服务器上的路径：只许普通字符。
    static func isSafeSourceID(_ id: String) -> Bool {
        !id.isEmpty && !id.hasPrefix(".") && !id.contains("/") && !id.contains("\0")
    }

    private static func isDirectory(_ path: String) -> Bool {
        var dir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &dir) && dir.boolValue
    }

    /// 这个工作区里某个引用目录的服务器镜像放在哪（本机没有这个目录时 App 读这里）。
    static func mirrorFolder(workspace: URL, sourceID: String) -> URL {
        workspace.appendingPathComponent("\(SyncNotes.mirrorFolderName)/\(sourceID)", isDirectory: true)
    }
}
