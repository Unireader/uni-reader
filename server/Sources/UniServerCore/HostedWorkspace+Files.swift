import Foundation

/// 服务器工作区里的文件：PDF（按内容哈希）、图片本体、备份（方案 `SERVER-MODE-PLAN.md §3.3 / §3.5`）。
extension HostedWorkspace {

    // MARK: - PDF

    /// 这份 PDF 在服务器上的文件；没有 = nil。
    public func pdfFile(contentHash: String) -> URL? {
        guard ServerCrypto.isSHA256Hex(contentHash) else { return nil }
        lock.lock(); defer { lock.unlock() }
        return store.withMirrorDB { pdfFileLocked($0, contentHash: contentHash) }
    }

    private func pdfFileLocked(_ db: SQLiteDB, contentHash: String) -> URL? {
        let fm = FileManager.default
        let paths = ((try? db.query("""
        SELECT l.path FROM location l JOIN variant v ON v.id=l.variant_id
        WHERE v.content_hash=? AND l.in_workspace=1
        """, [.text(contentHash)])) ?? []).compactMap { $0["path"] as? String }
        for p in paths + [Self.pdfRelPath(contentHash)] {
            if let url = Self.resolveInside(folder, p), fm.fileExists(atPath: url.path) { return url }
        }
        return nil
    }

    static func pdfRelPath(_ contentHash: String) -> String { "PDFs/\(contentHash).pdf" }

    /// 收下一份上传的 PDF（[tmp] 是已经落盘的临时文件，成功后被挪走）：校验哈希 → 放进 `PDFs/<hash>.pdf`
    /// → 有对应的 variant 就补 location。服务器已有同一份内容就直接丢掉临时文件。
    public func storePDF(contentHash: String, from tmp: URL) throws {
        guard ServerCrypto.isSHA256Hex(contentHash) else { throw ServerError.badRequest("内容哈希格式不对") }
        guard try ServerCrypto.sha256Hex(fileAt: tmp) == contentHash else {
            try? FileManager.default.removeItem(at: tmp)
            throw ServerError.badContentHash
        }
        lock.lock(); defer { lock.unlock() }
        try store.withMirrorDB { db in
            let fm = FileManager.default
            if pdfFileLocked(db, contentHash: contentHash) != nil {
                try? fm.removeItem(at: tmp)
            } else {
                let dst = folder.appendingPathComponent(Self.pdfRelPath(contentHash))
                try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.moveItem(at: tmp, to: dst)
            }
            try linkPDFFiles(db)
        }
    }

    /// 没有可用 location 的 variant，若 `PDFs/<hash>.pdf` 已经在了就补一条（文件可能比 variant 那一行先到）。
    func linkPDFFiles(_ db: SQLiteDB) throws {
        let fm = FileManager.default
        let rows = try db.query("""
        SELECT v.id, v.content_hash FROM variant v
        WHERE NOT EXISTS (SELECT 1 FROM location l WHERE l.variant_id=v.id AND l.in_workspace=1)
        """)
        for r in rows {
            guard let vid = r["id"] as? String, let hash = r["content_hash"] as? String,
                  ServerCrypto.isSHA256Hex(hash) else { continue }
            let rel = Self.pdfRelPath(hash)
            guard fm.fileExists(atPath: folder.appendingPathComponent(rel).path) else { continue }
            _ = try store.addLocation(variantId: vid, path: rel, inWorkspace: true)
        }
    }

    // MARK: - 图片本体

    /// 图片文件（`Images/<sha256>.<ext>`）；没有 = nil。
    public func imageFile(sha256: String, ext: String) -> URL? {
        guard ServerCrypto.isSHA256Hex(sha256), Self.isSafeExt(ext) else { return nil }
        return ImageAssets.exists(in: folder, sha256: sha256, ext: ext)
            ? ImageAssets.url(in: folder, sha256: sha256, ext: ext) : nil
    }

    /// 收下一张上传的图片。行（`image` 表）随后经推送进来，那时要求文件已经在（`SyncWire.Outcome.missingFile`）。
    public func storeImage(sha256: String, ext: String, from tmp: URL) throws {
        guard ServerCrypto.isSHA256Hex(sha256), Self.isSafeExt(ext) else { throw ServerError.badRequest("图片名不对") }
        guard try ServerCrypto.sha256Hex(fileAt: tmp) == sha256 else {
            try? FileManager.default.removeItem(at: tmp)
            throw ServerError.badContentHash
        }
        lock.lock(); defer { lock.unlock() }
        let fm = FileManager.default
        let dst = ImageAssets.url(in: folder, sha256: sha256, ext: ext)
        if fm.fileExists(atPath: dst.path) { try? fm.removeItem(at: tmp); return }
        try fm.createDirectory(at: ImageAssets.folder(in: folder), withIntermediateDirectories: true)
        try fm.moveItem(at: tmp, to: dst)
    }

    static func isSafeExt(_ ext: String) -> Bool {
        (1...8).contains(ext.count) && ext.utf8.allSatisfy { (0x30...0x39).contains($0) || (0x61...0x7A).contains($0) }
    }

    // MARK: - 备份

    /// 分级定时备份：`VACUUM INTO backups/<id>/library-<时间>.sqlite`，再按 `BackupRetention` 清理旧的
    /// （与 Mac 的定时备份同一套保留策略，`BACKUP-PLAN.md §3`）。同一秒里已经备份过就不再做。
    @discardableResult
    public func backup(now: Date = .now) throws -> URL { try backup(now: now, policy: .standard) }

    @discardableResult
    func backup(now: Date, policy: BackupRetention.Policy) throws -> URL {
        lock.lock(); defer { lock.unlock() }
        let fm = FileManager.default
        let dir = paths.backupFolder(id)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let dst = dir.appendingPathComponent(BackupFile.name(at: now))
        if !fm.fileExists(atPath: dst.path) {
            store.checkpointTruncate()
            try store.vacuumInto(dst.path)
        }
        let files = ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).compactMap { name -> (String, Date)? in
            guard let p = BackupFile.parse(name), !p.isRestorePoint else { return nil }
            return (name, p.date)
        }
        let plan = BackupRetention.plan(files.map(\.1), policy: policy, now: now)
        for i in plan.drop { try? fm.removeItem(at: dir.appendingPathComponent(files[i].0)) }
        ServerTrash.prune(folder: paths.trashFolder(id), now: now)
        return dst
    }
}
