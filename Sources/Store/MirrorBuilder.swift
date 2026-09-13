import Foundation

/// 建离线镜像：把一个工作区整份复制到本机（方案 `OFFLINE-MIRROR-PLAN.md` §8.1）。
///
/// **库全量、PDF 选择性**（§7）：平板/本机装不下一块几十 GB 的硬盘，但 `library.sqlite` 只有几十 MB。
/// 于是镜像里**所有书都看得见、所有笔记都在**，只是部分书没带 PDF，打开时提示「插回硬盘再看」。
/// 这条取舍还让 diff 完全不受「带没带文件」影响 —— 基线永远是整库的。
///
/// 本类只做文件与库的事，不碰 UI；源库一律经调用方传进来的 `LibraryStore` 实例
/// （§8.1 红线：同一工作区路径必须共享同一个实例，不许在这里另开一个连接）。
/// **在后台线程调用**：拷 PDF 是 GB 级、慢卷上建库是秒级。
enum MirrorBuilder {

    // MARK: - 计划与结果

    struct Plan {
        /// 要**带 PDF** 的文档 id。不在其中的书仍然进镜像（元数据、笔记齐全），只是打不开正文。
        var documentsWithPDF: Set<String>
        /// 建镜像时顺手记下的源盘位置，只为将来给一句「把那块盘插上」的人话提示（§5.3）。
        var sourceHint: String = ""
    }

    struct Estimate {
        var files: Int
        var bytes: Int64
        /// 勾了但当下解析不到文件的文档（源盘没插全、外部文件被挪走…）。**必须报出来**：
        /// 静默跳过的话用户会以为带上了，等硬盘不在手上时才发现打不开。
        var unresolved: [String]
    }

    struct Result {
        var url: URL
        var mirrorId: String
        var copiedFiles: Int
        var copiedBytes: Int64
        var internalized: Int      // 外部文件被拷进镜像 PDFs/ 的条数
        var baseRows: Int          // sync_base 记下的行数
        var unresolved: [String]
        var copiedImages: Int = 0  // 带过去的图片本体张数（`Images/`）
    }

    enum Failure: LocalizedError {
        case destinationExists(String)
        case sourceIsMirror
        case notEnoughSpace(need: Int64, free: Int64)

        var errorDescription: String? {
            switch self {
            case .destinationExists(let p): return "这个位置已经有「\(p)」了，换个名字"
            case .sourceIsMirror: return "这已经是一份离线镜像，不能再做镜像"
            case .notEnoughSpace(let need, let free):
                func mb(_ n: Int64) -> String { ByteCountFormatter.string(fromByteCount: n, countStyle: .file) }
                return "空间不够：需要 \(mb(need))，可用 \(mb(free))"
            }
        }
    }

    // MARK: - 估算

    /// 算这份计划要拷多少文件、多少字节。**拷之前必须先算**——内部存储写满会连累整个系统。
    static func estimate(source: URL, store: LibraryStore, plan: Plan,
                         resolve: (LibLocation) -> String?) -> Estimate {
        var files = 0, bytes: Int64 = 0
        var unresolved: [String] = []
        let fm = FileManager.default
        // 库本身（VACUUM INTO 后通常更小，按原大小算即多留一点余量）
        bytes += fileSize(fm, store.fileURL.path)
        // 图片本体全部带上（`IMAGE-NOTE-PLAN.md §7`：小文件、不做选择性）
        for im in imagesToCopy(store: store, folder: source) {
            files += 1
            bytes += Int64(im.bytes)
        }
        for docId in plan.documentsWithPDF.sorted() {
            guard let (path, _) = pickSource(store: store, documentId: docId, resolve: resolve) else {
                unresolved.append(docId)
                continue
            }
            files += 1
            bytes += fileSize(fm, path)
        }
        return Estimate(files: files, bytes: bytes, unresolved: unresolved)
    }

    // MARK: - 建镜像

    /// 在 [destination]（一个尚不存在的 `.unrd` 路径）建出镜像。
    ///
    /// 失败会**连整个新建的文件夹一起清掉**：留半个骨架在那儿，下次扫描会把它列出来、
    /// 点开又说「这里没有 library.sqlite」，比没建成难查得多（同 `Workspace.create` 的口径）。
    @discardableResult
    static func create(source: URL,
                       store: LibraryStore,
                       destination: URL,
                       plan: Plan,
                       resolve: (LibLocation) -> String?,
                       progress: ((String, Double) -> Void)? = nil) throws -> Result {
        let fm = FileManager.default
        guard store.meta(MirrorStore.metaMirrorOf) == nil else { throw Failure.sourceIsMirror }
        guard !fm.fileExists(atPath: destination.path) else {
            throw Failure.destinationExists(destination.lastPathComponent)
        }

        // 空间：拿目标卷的可用容量比，留 5% 余量
        let est = estimate(source: source, store: store, plan: plan, resolve: resolve)
        let need = Int64(Double(est.bytes) * 1.05)
        if let free = availableCapacity(destination.deletingLastPathComponent()), free < need {
            throw Failure.notEnoughSpace(need: need, free: free)
        }

        // 源库的 id 要在拷贝**之前**就位：镜像靠它认源盘，而它是从源库拷过去的
        let sourceId = try store.ensureWorkspaceId()
        let noteCount = store.noteCount()

        var created = false
        do {
            progress?("正在准备…", 0)
            try fm.createDirectory(at: destination.appendingPathComponent("UniReader", isDirectory: true),
                                   withIntermediateDirectories: true)
            created = true
            try fm.createDirectory(at: destination.appendingPathComponent("PDFs", isDirectory: true),
                                   withIntermediateDirectories: true)

            // ① 一致快照。先 checkpoint 把 -wal 收回主库，再 VACUUM INTO（见 LibraryStore 两个方法的注释）
            progress?("正在复制资料库…", 0.05)
            store.checkpointTruncate()
            let mirrorDBPath = destination.appendingPathComponent("UniReader/library.sqlite").path
            try store.vacuumInto(mirrorDBPath)

            // ② 镜像库自己的连接（新文件，全 app 没有第二个人持有它）
            let mdb = try SQLiteDB(path: mirrorDBPath)
            defer { mdb.close() }

            // ③ 拷 PDF + 内化外部文件
            var copied = 0, copiedBytes: Int64 = 0, internalized = 0
            let targets = plan.documentsWithPDF.sorted()
            for (i, docId) in targets.enumerated() {
                progress?("正在复制文件…", 0.1 + 0.8 * Double(i) / Double(max(targets.count, 1)))
                guard let (path, loc) = pickSource(store: store, documentId: docId, resolve: resolve) else { continue }
                // 工作区内的副本：**保持同一条相对路径**拷过去，镜像库里那行 location 原样就有效，
                // 一个字都不用改。外部文件才需要内化。
                let rel = loc.inWorkspace ? loc.path : "PDFs/\(UUID().uuidString).pdf"
                let dst = destination.appendingPathComponent(rel)
                try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
                try copyAtomically(from: path, to: dst)
                copied += 1
                copiedBytes += fileSize(fm, dst.path)
                if !loc.inWorkspace {
                    // 内化：在**镜像库**里补一条工作区内 location。原来那条外部路径的行留着不动——
                    // 它在镜像上解析不到只是灰一档，而 location 本就不参与同步（方案 §4），
                    // 删它既没收益又是破坏性操作。
                    try mdb.run("""
                    INSERT INTO location(id,variant_id,path,is_valid,last_validated_at,in_workspace,is_relative)
                    VALUES(?,?,?,1,?,1,0)
                    """, [.text(UUID().uuidString), .text(loc.variantId), .text(rel), .text(ISO.string(.now))])
                    internalized += 1
                }
            }

            // ③.5 图片本体：表已随 VACUUM 整份过去，文件按表里的行拷（`Images/` 里没有行指着的孤儿文件不拷）。
            // 已到期的待删除图不带（`imagesToCopy` 滤掉），镜像库里那几行留着也无妨——镜像打开时自己会清。
            progress?("正在复制图片…", 0.9)
            var copiedImages = 0
            for im in imagesToCopy(store: store, folder: source) {
                try ImageAssets.copy(from: ImageAssets.url(in: source, sha256: im.sha256, ext: im.ext),
                                     to: destination, sha256: im.sha256, ext: im.ext)
                copiedImages += 1
                copiedBytes += Int64(im.bytes)
            }

            // ④ 血缘 meta。**镜像必须换一个自己的 workspace_id**：VACUUM 出来的副本原样带着源库的 id，
            // 不换的话「扫一圈盘按 workspace_id 找源」会把镜像自己也认成源。
            progress?("正在写入基线…", 0.92)
            let mirrorId = UUID().uuidString
            for (k, v) in [
                ("workspace_id", UUID().uuidString),
                (MirrorStore.metaMirrorOf, sourceId),
                (MirrorStore.metaMirrorId, mirrorId),
                (MirrorStore.metaMirrorCreatedAt, ISO.string(.now)),
                (MirrorStore.metaMirrorSourceHint, plan.sourceHint),
            ] {
                try mdb.run("INSERT INTO meta(key,value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",
                            [.text(k), .text(v)])
            }
            // 「本机开着哪几篇」是源设备的状态，别让镜像一打开就复现源盘的会话
            try mdb.run("DELETE FROM meta WHERE key IN ('open_documents','offline_checkouts')")

            // ⑤ 基线。必须在上面所有写入**之后**——虽然 mirror_* 都不在同步白名单里，
            // 但顺序写反了就得靠"它恰好不影响"来解释，不如一律最后算。
            let baseRows = try MirrorStore.rebuildSyncBase(mdb)

            // ⑥ 源库记一笔借出（信息不是锁，§5.2）
            let list = MirrorStore.decodeCheckouts(store.meta(MirrorStore.metaCheckouts))
            let c = MirrorStore.Checkout(mirrorId: mirrorId,
                                         deviceId: MirrorStore.deviceId,
                                         deviceName: MirrorStore.deviceName,
                                         takenAt: ISO.string(.now),
                                         lastSyncedAt: nil,
                                         noteCount: noteCount)
            try store.setMeta(MirrorStore.metaCheckouts,
                              MirrorStore.encodeCheckouts(MirrorStore.upsertCheckout(list, c)))

            progress?("完成", 1)
            return Result(url: destination, mirrorId: mirrorId, copiedFiles: copied,
                          copiedBytes: copiedBytes, internalized: internalized,
                          baseRows: baseRows, unresolved: est.unresolved, copiedImages: copiedImages)
        } catch {
            if created { try? fm.removeItem(at: destination) }
            throw error
        }
    }

    // MARK: - 内部

    /// 要带进镜像的图片：表里有行、文件在、且不是已到期的待删除。
    static func imagesToCopy(store: LibraryStore, folder: URL, now: Date = .now) -> [LibImage] {
        let cutoff = now.addingTimeInterval(-LibraryStore.imagePurgeAfter)
        return ((try? store.images()) ?? []).filter { im in
            (im.orphanedAt.map { $0 >= cutoff } ?? true)
                && ImageAssets.exists(in: folder, sha256: im.sha256, ext: im.ext)
        }
    }

    /// 挑一条能打开的 location：**工作区内的优先**（那条随文件夹走、最稳），其次外部。
    static func pickSource(store: LibraryStore, documentId: String,
                           resolve: (LibLocation) -> String?) -> (path: String, loc: LibLocation)? {
        let locs = (try? store.locations(documentId: documentId)) ?? []
        for loc in locs.sorted(by: { $0.inWorkspace && !$1.inWorkspace }) {
            if let p = resolve(loc), FileManager.default.fileExists(atPath: p) { return (p, loc) }
        }
        return nil
    }

    /// 先写临时名再原子 rename。中途拔盘/断电只会留一个 `.part`，不会留一个**看着是好的、
    /// 其实只拷了一半**的 PDF —— 后者要等用户翻到那一页才发现。
    private static func copyAtomically(from: String, to: URL) throws {
        let fm = FileManager.default
        let tmp = to.deletingLastPathComponent()
            .appendingPathComponent(".\(to.lastPathComponent).part")
        try? fm.removeItem(at: tmp)
        try fm.copyItem(at: URL(fileURLWithPath: from), to: tmp)
        try? fm.removeItem(at: to)
        try fm.moveItem(at: tmp, to: to)
    }

    private static func fileSize(_ fm: FileManager, _ path: String) -> Int64 {
        ((try? fm.attributesOfItem(atPath: path))?[.size] as? NSNumber)?.int64Value ?? 0
    }

    private static func availableCapacity(_ dir: URL) -> Int64? {
        (try? dir.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage
    }
}
