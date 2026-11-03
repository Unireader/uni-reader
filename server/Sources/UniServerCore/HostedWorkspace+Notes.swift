import Foundation

/// 服务器工作区里的笔记文件：`Notes/` 下的 Markdown 正文与附件，按文件整份同步（方案 `SERVER-MODE-PLAN.md §4.4 / §13.12`）。
///
/// 文件就放在工作区文件夹的 `Notes/` 里（Obsidian 打开它仍是一个正常的库；首次上传也是这么放的）。
/// 服务器私有的只有一张表 `srv_note`（每个文件最后一次改动的修订号 / 内容哈希 / 是否已删除）与 `meta.srv_note_head`
/// （最大修订号）——和 `srv_rev` 一样放在同一个库里、导出快照时去掉。修订号**每个文件一个、互不相同**。
///
/// 🔴 红线⑪ 删除先归档再删：被覆盖的旧版本、被删的文件都先放进 `trash/<工作区>/notes/<日期>/…`（保留 90 天）。
/// 🔴 红线⑨ 正文一个字不改：服务器只整份收、整份发；冲突时由客户端另存副本，服务器不合并。
extension HostedWorkspace {

    public enum NoteWrite: Equatable, Sendable {
        /// 收下了 / 删掉了，`rev` 是新修订号。
        case applied
        /// 服务器已经是这样（内容相同 / 早就没了），什么也没做。
        case unchanged
        /// 服务器上这个文件在设备上次同步之后又变过：不收。`rev` 是服务器现在的修订号。
        case stale
    }

    static let metaNoteHead = "srv_note_head"

    static let noteDDL = """
    CREATE TABLE IF NOT EXISTS srv_note (
      path TEXT PRIMARY KEY,
      rev INTEGER NOT NULL,
      sha256 TEXT NOT NULL DEFAULT '',
      size INTEGER NOT NULL DEFAULT 0,
      mtime REAL NOT NULL DEFAULT 0,
      deleted INTEGER NOT NULL DEFAULT 0
    ) WITHOUT ROWID;
    """

    struct NoteRow {
        var rev: UInt64
        var sha256: String
        var size: Int64
        var mtime: Double
        var deleted: Bool
    }

    // MARK: - 查

    /// 全部文件（含墓碑）的现状，JSON（`SyncNotes.ListResponse`）。
    public func noteList() throws -> Data {
        lock.lock(); defer { lock.unlock() }
        try checkOpen()
        return try store.withMirrorDB { db in
            try reconcileNotes(db)
            let rows = try db.query("SELECT path,rev,sha256,size,deleted FROM srv_note ORDER BY rev")
            let files = rows.compactMap { r -> SyncNotes.Entry? in
                guard let p = r["path"] as? String, let rev = r["rev"] as? Int64 else { return nil }
                return SyncNotes.Entry(path: p, rev: UInt64(rev), sha256: r["sha256"] as? String ?? "",
                                       size: r["size"] as? Int64 ?? 0, deleted: (r["deleted"] as? Int64 ?? 0) != 0)
            }
            return try JSONEncoder().encode(SyncNotes.ListResponse(head: Self.noteHead(db), files: files))
        }
    }

    /// 某个文件在服务器上的现状：有（未删除）→ 文件位置 + 修订号；没有 / 已删除 = nil。
    public func noteFile(path: String) throws -> (url: URL, rev: UInt64)? {
        guard SyncNotes.isSyncablePath(path) else { throw ServerError.badRequest("不接受这个路径：\(path)") }
        lock.lock(); defer { lock.unlock() }
        try checkOpen()
        return try store.withMirrorDB { db in
            try reconcileNotesOnce(db)
            guard let row = Self.noteRow(db, path), !row.deleted,
                  let url = Self.resolveInside(folder, path), FileManager.default.fileExists(atPath: url.path) else { return nil }
            return (url, row.rev)
        }
    }

    // MARK: - 写

    /// 收下一个文件的新内容（[tmp] 是已落盘的临时文件，成功 / 内容相同 / 不收，都会被处理掉）。
    /// [base] = 设备上次同步时看到的修订号（本机新增的文件传 0）。
    /// 规则：服务器上没有（或已删除）→ 直接收；有 → 内容相同算 `unchanged`，修订号 == base 才收，否则 `stale`。
    public func putNote(path: String, base: UInt64, from tmp: URL,
                        now: Date = .now) throws -> (result: NoteWrite, rev: UInt64) {
        guard SyncNotes.isSyncablePath(path), let dst = Self.resolveInside(folder, path) else {
            try? FileManager.default.removeItem(at: tmp)
            throw ServerError.badRequest("不接受这个路径：\(path)")
        }
        let sha = try SyncNotes.sha256Hex(fileAt: tmp)
        lock.lock(); defer { lock.unlock() }
        do { try checkOpen() } catch { try? FileManager.default.removeItem(at: tmp); throw error }
        let fm = FileManager.default
        return try store.withMirrorDB { db in
            try reconcileNotesOnce(db)
            if let row = Self.noteRow(db, path), !row.deleted {
                if row.sha256 == sha { try? fm.removeItem(at: tmp); return (.unchanged, row.rev) }
                if row.rev != base { try? fm.removeItem(at: tmp); return (.stale, row.rev) }
            }
            // 覆盖也是破坏性的：旧版本先放进回收站
            if fm.fileExists(atPath: dst.path) { try archiveNote(at: dst, path: path, move: false, now: now) }
            try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fm.fileExists(atPath: dst.path) { try fm.removeItem(at: dst) }
            try fm.moveItem(at: tmp, to: dst)
            let size = (try? fm.attributesOfItem(atPath: dst.path)[.size] as? NSNumber)?.int64Value ?? 0
            let rev = try Self.bumpNote(db, path: path, sha256: sha, size: size, mtime: Self.mtime(dst), deleted: false)
            publishChange(db)
            return (.applied, rev)
        }
    }

    /// 删一个文件：先挪进回收站，再记墓碑。[base] 对不上（别的设备改过）→ `stale`，不删。
    public func deleteNote(path: String, base: UInt64,
                           now: Date = .now) throws -> (result: NoteWrite, rev: UInt64) {
        guard SyncNotes.isSyncablePath(path), let dst = Self.resolveInside(folder, path) else {
            throw ServerError.badRequest("不接受这个路径：\(path)")
        }
        lock.lock(); defer { lock.unlock() }
        try checkOpen()
        return try store.withMirrorDB { db in
            try reconcileNotesOnce(db)
            guard let row = Self.noteRow(db, path), !row.deleted else { return (.unchanged, Self.noteRow(db, path)?.rev ?? 0) }
            if row.rev != base { return (.stale, row.rev) }
            if FileManager.default.fileExists(atPath: dst.path) { try archiveNote(at: dst, path: path, move: true, now: now) }
            let rev = try Self.bumpNote(db, path: path, sha256: "", size: 0, mtime: 0, deleted: true)
            publishChange(db)
            return (.applied, rev)
        }
    }

    // MARK: - 与磁盘对账

    /// 进程里第一次用笔记接口时对一次账（之后的改动都经过上面的 put / delete，表一直是对的）；
    /// `noteList` 每次都对——有人直接在服务器上动了 `Notes/` 里的文件，设备拉列表时就能看到。
    private func reconcileNotesOnce(_ db: SQLiteDB) throws {
        guard !notesReconciled else { return }
        try reconcileNotes(db)
    }

    /// 让 `srv_note` 与磁盘上的 `Notes/` 一致：新文件 / 内容变了的 → 记新修订号；表里有、磁盘上没了的 → 记墓碑。
    /// 首次上传的工作区、手动放进去的文件都靠它进表。内容哈希只在（大小, 修改时间）变了才重算。
    func reconcileNotes(_ db: SQLiteDB) throws {
        // `Notes/`（或 `NotesMirror/`）整个目录都不在（被人手动挪走了）不当成「全删了」：别让所有设备跟着把自己的笔记删光
        let existingRoots = Set(SyncNotes.roots.filter {
            FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path)
        }.map { $0 + "/" })
        func rootExists(_ path: String) -> Bool { existingRoots.contains { path.hasPrefix($0) } }
        var known: [String: NoteRow] = [:]
        for r in try db.query("SELECT path,rev,sha256,size,mtime,deleted FROM srv_note") {
            guard let p = r["path"] as? String, let rev = r["rev"] as? Int64 else { continue }
            known[p] = NoteRow(rev: UInt64(rev), sha256: r["sha256"] as? String ?? "", size: r["size"] as? Int64 ?? 0,
                               mtime: r["mtime"] as? Double ?? 0, deleted: (r["deleted"] as? Int64 ?? 0) != 0)
        }
        var seen = Set<String>()
        try db.transaction {
            for item in SyncNotes.scan(folder: folder) {
                seen.insert(item.rel)
                guard let url = Self.resolveInside(folder, item.rel) else { continue }
                if let row = known[item.rel], !row.deleted, row.size == item.size, row.mtime == item.mtime { continue }
                let sha = try SyncNotes.sha256Hex(fileAt: url)
                if let row = known[item.rel], !row.deleted, row.sha256 == sha {
                    // 内容没变，只是时间戳动了：更新时间戳，不涨修订号
                    try db.run("UPDATE srv_note SET size=?, mtime=? WHERE path=?",
                               [.int(item.size), .double(item.mtime), .text(item.rel)])
                } else {
                    _ = try Self.bumpNote(db, path: item.rel, sha256: sha, size: item.size, mtime: item.mtime, deleted: false)
                }
            }
            for (path, row) in known where rootExists(path) && !row.deleted && !seen.contains(path) {
                // 磁盘上已经没有了（没东西可归档）
                _ = try Self.bumpNote(db, path: path, sha256: "", size: 0, mtime: 0, deleted: true)
            }
        }
        notesReconciled = true
        publishChange(db)       // 有人直接动了服务器上的 Notes/ 文件时，对账出来的新修订号也要通知出去
    }

    // MARK: - 小工具

    static func noteHead(_ db: SQLiteDB) -> UInt64 {
        ((try? db.query("SELECT value FROM meta WHERE key=?", [.text(metaNoteHead)]))?.first?["value"] as? String)
            .flatMap { UInt64($0) } ?? 0
    }

    static func noteRow(_ db: SQLiteDB, _ path: String) -> NoteRow? {
        guard let r = (try? db.query("SELECT rev,sha256,size,mtime,deleted FROM srv_note WHERE path=?", [.text(path)]))?.first,
              let rev = r["rev"] as? Int64 else { return nil }
        return NoteRow(rev: UInt64(rev), sha256: r["sha256"] as? String ?? "", size: r["size"] as? Int64 ?? 0,
                       mtime: r["mtime"] as? Double ?? 0, deleted: (r["deleted"] as? Int64 ?? 0) != 0)
    }

    /// 记一次改动：修订号 +1（每个文件一个、互不相同），返回新修订号。
    @discardableResult
    static func bumpNote(_ db: SQLiteDB, path: String, sha256: String, size: Int64, mtime: Double,
                         deleted: Bool) throws -> UInt64 {
        let rev = noteHead(db) + 1
        try db.run("INSERT INTO meta(key,value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",
                   [.text(metaNoteHead), .text(String(rev))])
        try db.run("""
        INSERT INTO srv_note(path,rev,sha256,size,mtime,deleted) VALUES(?,?,?,?,?,?)
        ON CONFLICT(path) DO UPDATE SET rev=excluded.rev, sha256=excluded.sha256, size=excluded.size,
                                        mtime=excluded.mtime, deleted=excluded.deleted
        """, [.text(path), .int(Int64(rev)), .text(sha256), .int(size), .double(mtime), .int(deleted ? 1 : 0)])
        return rev
    }

    static func mtime(_ url: URL) -> Double {
        ((try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date)?.timeIntervalSince1970 ?? 0
    }

    /// 旧版本 / 被删的文件放进 `trash/<工作区>/notes/<日期>/<原路径>`（带 `Notes/` 或 `NotesMirror/<id>/` 前缀）；同名已有就加时间后缀。
    func archiveNote(at url: URL, path: String, move: Bool, now: Date) throws {
        let fm = FileManager.default
        let day = String(ISO.string(now).prefix(10))
        var dst = paths.trashFolder(id).appendingPathComponent("notes/\(day)/\(path)")
        // 同一天同一路径归档多次（连续覆盖再删）：名字后面加序号，永不撞名
        let ext = dst.pathExtension
        let stem = dst.deletingPathExtension().lastPathComponent
        var n = 1
        while fm.fileExists(atPath: dst.path) {
            n += 1
            let name = ext.isEmpty ? "\(stem) \(n)" : "\(stem) \(n).\(ext)"
            dst = dst.deletingLastPathComponent().appendingPathComponent(name)
        }
        try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
        if move { try fm.moveItem(at: url, to: dst) } else { try Self.copyBytes(from: url, to: dst) }
    }

    /// 只复制字节，不带属性。🔴 不能用 `FileManager.copyItem`：用户 NAS 的 `/storage` 是 mergerfs，
    /// 它要连带复制权限 / 扩展属性（同 `chmod` 报「Operation not supported」），在上面只会建出空目录、文件复制不出来
    /// ——覆盖已有笔记前的归档就失败，每次编辑都 500（2026-11-03 实测，macOS 上测不出来）。
    static func copyBytes(from src: URL, to dst: URL) throws {
        guard FileManager.default.createFile(atPath: dst.path, contents: nil) else {
            throw ServerError.badRequest("无法在回收站里创建 \(dst.lastPathComponent)")
        }
        let reader = try FileHandle(forReadingFrom: src)
        defer { try? reader.close() }
        let writer = try FileHandle(forWritingTo: dst)
        defer { try? writer.close() }
        while let chunk = try reader.read(upToCount: 1 << 20), !chunk.isEmpty { try writer.write(contentsOf: chunk) }
    }
}
