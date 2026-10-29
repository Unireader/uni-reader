import Foundation

/// 服务器同步里**纯 IO 的那一半**：一轮同步、上传准备、文件上传下载、本机缓存放哪。
///
/// 与 `ServerSyncCoordinator`（调度、状态、界面那一半，`@MainActor`、碰 `WorkspaceManager`）分开放，
/// 只依赖 Foundation + Store 层 + `Sources/Sync` + `ServerClient`：spike 能直接编它对着真服务器跑
/// （`spike/server-client-test.swift`）。这里的函数都在后台线程调。
enum ServerSyncIO {

    /// 本机缓存放这里（不让用户选，理由同离线副本 `WorkspaceManager.mirrorsRoot`）。
    static var cachesRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("UniReader/Servers", isDirectory: true)
    }

    /// 这个工作区连的哪台服务器（`meta.srv_url`）；不是服务器工作区 = nil。短连接只读一眼，不建 `LibraryStore`。
    static func serverURL(of folder: URL) -> String? { serverLink(of: folder)?.url }

    /// 这个工作区连的服务器：地址 + 身份（老缓存没有身份）。不是服务器工作区 = nil。
    static func serverLink(of folder: URL) -> (url: String, serverId: String?)? {
        let file = folder.appendingPathComponent("UniReader/library.sqlite")
        guard FileManager.default.fileExists(atPath: file.path), let db = try? SQLiteDB(path: file.path) else { return nil }
        defer { db.close() }
        func meta(_ k: String) -> String? {
            let v = (try? db.query("SELECT value FROM meta WHERE key=?", [.text(k)]))?.first?["value"] as? String
            return (v?.isEmpty ?? true) ? nil : v
        }
        guard let url = meta(SyncClient.metaServerURL) else { return nil }
        return (url, meta(SyncClient.metaServerID))
    }

    // MARK: - 一轮（临时连接）

    /// 完整一轮：推（先传新文件）→ 拉 → 应用 → 补缺的图片。🔴 只在**没有活连接**时调（打开前 / 关闭后）。
    static func closedRound(folder: URL, client: ServerClient, wid: String) async throws {
        let store = try LibraryStore(workspaceFolder: folder)
        defer { store.close() }
        let db = store.withMirrorDB { $0 }
        _ = try await SyncClient.roundAsync(
            db, folder: folder,
            beforePush: { changes in try await uploadFiles(for: changes, db: db, folder: folder, client: client, wid: wid) },
            push: { req in try SyncWire.decodePushResponse(try await client.push(wid, body: SyncWire.encode(req))) },
            pull: { since in try SyncWire.decodePullResponse(try await client.pull(wid, since: since)) })
        try await downloadMissingImages(db: db, folder: folder, client: client, wid: wid)
    }

    // MARK: - 文件

    /// 推送前先把新加的 PDF / 图片传上去：服务器收图片行要求文件已在（`missingFile`）；
    /// PDF 的 variant 行没有文件也收，但那样别的设备就下不到了。传失败就整轮放弃（行没推，下一轮再来）。
    static func uploadFiles(for changes: [SyncWire.RowChange], db: SQLiteDB, folder: URL,
                            client: ServerClient, wid: String) async throws {
        for c in changes where c.op == .upsert {
            switch c.table {
            case "variant":
                guard let hash = c.row?["content_hash"].flatMap(text),
                      let file = localPDF(db: db, folder: folder, variantId: c.rowId) else { continue }
                try await client.uploadPDF(wid, hash: hash, file: file)
            case SyncRows.imageTable:
                guard let ext = c.row?["ext"].flatMap(text), ImageAssets.exists(in: folder, sha256: c.rowId, ext: ext) else { continue }
                try await client.uploadImage(wid, sha: c.rowId, ext: ext, file: ImageAssets.url(in: folder, sha256: c.rowId, ext: ext))
            default:
                continue
            }
        }
    }

    private static func text(_ v: MirrorFp.Value) -> String? { if case .text(let s) = v { return s } else { return nil } }

    /// 这个 variant 在本机能打开的文件（工作区内的优先）。路径口径同 `WorkspaceManager.resolvedPath`。
    static func localPDF(db: SQLiteDB, folder: URL, variantId: String) -> URL? {
        let rows = (try? db.query("SELECT path, in_workspace, is_relative FROM location WHERE variant_id=? ORDER BY in_workspace DESC",
                                  [.text(variantId)])) ?? []
        for r in rows {
            guard let p = r["path"] as? String else { continue }
            let inside = (r["in_workspace"] as? Int64 ?? 0) != 0 || (r["is_relative"] as? Int64 ?? 0) != 0
            let url = inside ? folder.appendingPathComponent(p) : URL(fileURLWithPath: p)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return nil
    }

    /// 库里有行、本机没文件的图片：从服务器补下来（某一张取不到就跳过它）。
    static func downloadMissingImages(db: SQLiteDB, folder: URL, client: ServerClient, wid: String) async throws {
        for r in (try? db.query("SELECT sha256, ext FROM image")) ?? [] {
            try Task.checkCancellation()
            guard let sha = r["sha256"] as? String, let ext = r["ext"] as? String,
                  !ImageAssets.exists(in: folder, sha256: sha, ext: ext) else { continue }
            do {
                try await client.downloadImage(wid, sha: sha, ext: ext, to: ImageAssets.url(in: folder, sha256: sha, ext: ext))
            } catch let e as URLError where e.code == .cancelled {
                throw CancellationError()
            } catch {
                continue
            }
        }
    }

    // MARK: - 建本机缓存

    /// 下载快照建一份本机缓存，放在 [dir] 下（名字不撞）。返回缓存文件夹。
    static func createCache(in dir: URL, name: String, serverURL: String, serverId: String? = nil, client: ServerClient,
                            wid: String, progress: (Step) -> Void) async throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let tmp = dir.appendingPathComponent(".\(UUID().uuidString).download", isDirectory: true)
        defer { try? fm.removeItem(at: tmp) }
        progress(.library)
        let rev = try await client.downloadSnapshot(wid, to: tmp.appendingPathComponent("UniReader/library.sqlite"))
        progress(.preparing)
        do {
            let store = try LibraryStore(workspaceFolder: tmp)
            defer { store.close() }
            try store.setMeta(SyncClient.metaServerURL, serverURL)
            if let serverId { try store.setMeta(SyncClient.metaServerID, serverId) }
            try store.withMirrorDB { try SyncClient.resetBase($0, folder: tmp, pulledRev: rev) }
            store.checkpointTruncate()
        }
        let dst = uniqueFolder(in: dir, name: safeName(name))
        try fm.moveItem(at: tmp, to: dst)
        progress(.images)
        if let db = try? SQLiteDB(path: dst.appendingPathComponent("UniReader/library.sqlite").path) {
            try? await downloadMissingImages(db: db, folder: dst, client: client, wid: wid)
            db.close()
        }
        return dst
    }

    enum Step { case library, preparing, images }

    /// 在缓存目录里找某个工作区的本机缓存（按 `workspace_id`）。
    static func findCache(workspaceId: String, root: URL = cachesRoot) -> URL? {
        let fm = FileManager.default
        for host in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
            for ws in (try? fm.contentsOfDirectory(at: host, includingPropertiesForKeys: nil)) ?? []
            where ws.pathExtension == "unrd" {
                if LibraryStore.peekIdentity(folder: ws)?.id == workspaceId { return ws }
            }
        }
        return nil
    }

    /// 服务器地址 → 缓存目录下的子目录名（`主机-端口`）。
    static func hostFolderName(_ serverURL: String) -> String {
        guard let u = URL(string: serverURL), let host = u.host else { return "server" }
        return safeName(host + (u.port.map { "-\($0)" } ?? ""))
    }

    static func safeName(_ s: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:?*\"<>|").union(.controlCharacters)
        let cleaned = s.components(separatedBy: bad).joined(separator: "-").trimmingCharacters(in: .whitespaces)
        let noDot = cleaned.hasPrefix(".") ? "_" + cleaned.dropFirst() : Substring(cleaned)
        return noDot.isEmpty ? "Workspace" : String(noDot)
    }

    static func uniqueFolder(in dir: URL, name: String) -> URL {
        var url = dir.appendingPathComponent("\(name).unrd", isDirectory: true)
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = dir.appendingPathComponent("\(name) \(n).unrd", isDirectory: true)
            n += 1
        }
        return url
    }

    // MARK: - 上传本地工作区

    struct UploadFile { let rel: String; let src: URL; let size: Int64 }

    struct UploadPlan {
        let library: URL
        let files: [UploadFile]
        /// 对着上传出去的那份快照算的基线（方案 §5：上传期间本机又改的不在里面，下一轮才推）。
        let base: [String: [String: String]]
        /// 本机找不到文件的书（行照常上传，PDF 没有）。
        let missingPDFs: Int
    }

    /// 准备上传：`VACUUM INTO` 出快照；快照里每本书只留一条工作区内的 location（外部文件改成 `PDFs/<uuid>.pdf`，
    /// 上传时传原文件）；列出要传的 PDF、图片、`Notes/` 下的笔记；对着快照算基线。
    static func prepareUpload(store: LibraryStore, folder: URL, staging: URL) throws -> UploadPlan {
        let fm = FileManager.default
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        let lib = staging.appendingPathComponent("library.sqlite")
        store.checkpointTruncate()
        try store.vacuumInto(lib.path)
        let db = try SQLiteDB(path: lib.path)
        defer { db.close() }

        var files: [UploadFile] = []
        var used = Set<String>()
        var missing = 0
        for v in try db.query("SELECT id FROM variant") {
            guard let vid = v["id"] as? String else { continue }
            var chosen: (rel: String, src: URL)?
            for l in try db.query("SELECT path, in_workspace, is_relative FROM location WHERE variant_id=? ORDER BY in_workspace DESC",
                                  [.text(vid)]) {
                guard let p = l["path"] as? String else { continue }
                let inWs = (l["in_workspace"] as? Int64 ?? 0) != 0
                let rel = (l["is_relative"] as? Int64 ?? 0) != 0
                let abs = (inWs || rel) ? folder.appendingPathComponent(p) : URL(fileURLWithPath: p)
                guard fm.fileExists(atPath: abs.path) else { continue }
                chosen = (inWs && !used.contains(p) ? p : "PDFs/\(UUID().uuidString).pdf", abs)
                break
            }
            try db.run("DELETE FROM location WHERE variant_id=?", [.text(vid)])
            guard let c = chosen else { missing += 1; continue }
            try db.run("INSERT INTO location(id,variant_id,path,is_valid,in_workspace,is_relative) VALUES(?,?,?,1,1,0)",
                       [.text(UUID().uuidString), .text(vid), .text(c.rel)])
            used.insert(c.rel)
            files.append(UploadFile(rel: c.rel, src: c.src, size: size(c.src)))
        }
        for r in try db.query("SELECT sha256, ext FROM image") {
            guard let sha = r["sha256"] as? String, let ext = r["ext"] as? String,
                  ImageAssets.exists(in: folder, sha256: sha, ext: ext) else { continue }
            let src = ImageAssets.url(in: folder, sha256: sha, ext: ext)
            files.append(UploadFile(rel: "\(ImageAssets.folderName)/\(sha).\(ext)", src: src, size: size(src)))
        }
        let notes = folder.appendingPathComponent("Notes", isDirectory: true).standardizedFileURL
        if let walker = fm.enumerator(at: notes, includingPropertiesForKeys: [.isRegularFileKey],
                                      options: [.skipsHiddenFiles]) {
            for case let url as URL in walker {
                guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
                let rel = "Notes/" + url.standardizedFileURL.path.dropFirst(notes.path.count + 1)
                files.append(UploadFile(rel: rel, src: url, size: size(url)))
            }
        }
        let base = try SyncClient.computeBase(db, folder: folder)
        try db.exec("PRAGMA wal_checkpoint(TRUNCATE)")
        try db.exec("PRAGMA journal_mode=DELETE")   // 传出去的是单个文件
        return UploadPlan(library: lib, files: files, base: base, missingPDFs: missing)
    }

    /// 按准备好的清单上传，全部到齐后登记。失败时放弃这次上传会话（服务器那边 7 天后也会自己清）。
    static func upload(_ plan: UploadPlan, client: ServerClient,
                       progress: @escaping @Sendable (Int, Int, Double) -> Void) async throws -> ServerClient.WorkspaceInfo {
        let session = try await client.newUpload()
        do {
            let libSize = size(plan.library)
            let total = Double(max(1, libSize + plan.files.reduce(0) { $0 + $1.size }))
            let count = plan.files.count
            try await client.uploadFile(upload: session, path: "UniReader/library.sqlite", file: plan.library) { done, _ in
                progress(0, count, Double(done) / total)
            }
            var sent = libSize
            for (i, f) in plan.files.enumerated() {
                let base = sent
                try await client.uploadFile(upload: session, path: f.rel, file: f.src) { done, _ in
                    progress(i + 1, count, Double(base + done) / total)
                }
                sent += f.size
            }
            return try await client.finishUpload(session)
        } catch {
            await client.cancelUpload(session)
            throw error
        }
    }

    static func size(_ url: URL) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0
    }
}
