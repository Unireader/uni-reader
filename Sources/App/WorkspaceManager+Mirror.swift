import Foundation

/// 离线镜像在**窗口层**的入口（方案 `OFFLINE-MIRROR-PLAN.md`）。
///
/// 存储层（`MirrorBuilder`/`MirrorDiff`/`MirrorReport`）一概不认识 UI，也不认识
/// 「路径怎么解析」；这一层负责把它们接到当前这个工作区上：给出解析器、跑在后台线程、
/// 把结果变成界面能直接显示的东西。
extension WorkspaceManager {

    // MARK: - 我是不是一份镜像

    /// 本工作区是不是离线镜像。
    var isMirror: Bool { store?.meta(MirrorStore.metaMirrorOf) != nil }

    /// 源工作区的 `workspace_id`（**认源盘的唯一判据**）。
    var mirrorSourceId: String? { store?.meta(MirrorStore.metaMirrorOf) }

    /// 「上次见到源盘时它在哪」。只用来说一句人话，**不作判据**。
    var mirrorSourceHint: String { store?.meta(MirrorStore.metaMirrorSourceHint) ?? "" }

    var mirrorLastSyncedAt: String? { store?.meta(MirrorStore.metaMirrorLastSyncedAt) }

    /// 本工作区被借出了几份（源盘侧看）。**是信息不是锁**：只用来显示一行提示。
    var checkouts: [MirrorStore.Checkout] {
        MirrorStore.decodeCheckouts(store?.meta(MirrorStore.metaCheckouts))
    }

    /// 这篇文档在**本机**有没有可打开的文件。
    /// 镜像里没带 PDF 的书就是这一条为假 —— 元数据与笔记都在，只是打不开正文。
    func hasLocalFile(_ documentId: String) -> Bool { currentFilePath(documentId: documentId) != nil }

    // MARK: - 位置解析器（存储层要的那个闭包）

    /// 与 `resolvedPath` 同口径：工作区内/同卷相对 → 拼工作区目录；否则是绝对路径。
    func mirrorResolver() -> (LibLocation) -> String? {
        let base = folder
        return { loc in
            guard let base else { return nil }
            return (loc.inWorkspace || loc.isRelative)
                ? base.appendingPathComponent(loc.path).path
                : loc.path
        }
    }

    // MARK: - 镜像放哪（不让用户挑）

    /// 镜像的固定存放位置：`~/Library/Application Support/UniReader/Mirrors/`。
    ///
    /// **不弹保存面板让用户选位置**——「放哪」这件事没有一个「用户比我们更懂」的答案，反倒全是坑：
    /// 挑回源盘上就等于没离线；挑到 `~/Documents` 或桌面，一旦开着 iCloud「桌面与文稿」，
    /// 几 GB 的镜像会被整份上传，而且系统随时可能把它清成 dataless 占位文件——SQLite 和 PDF
    /// 当场打不开，而这份镜像正是「硬盘不在手上时唯一能读的那份」。应用支持目录不参与任何同步，
    /// 也与 `WorkspaceManager.defaultFolder()`（默认工作区）同一处根。
    ///
    /// 代价是它在 `~/Library` 下、Finder 里默认藏着。补偿两条：建完自动进「最近工作区」
    /// （侧栏一键切过去，用户根本不需要知道路径），面板上再给一个「在 Finder 中显示」。
    /// 这与安卓端 `MirrorBuilder.defaultParent()` 是同一条思路：位置由 App 定，用户只管内容。
    static var mirrorsRoot: URL {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("UniReader/Mirrors", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// 这个工作区的镜像该叫什么、落在哪。重名加序号——本机可能同时镜像着两块盘上的同名工作区。
    static func plannedMirrorURL(name: String) -> URL {
        let base = sanitizedPackageName(name, fallback: "Workspace")
        let root = mirrorsRoot
        let fm = FileManager.default
        for i in 1...99 {
            let leaf = i == 1 ? "\(base).\(packageExtension)" : "\(base) \(i).\(packageExtension)"
            let candidate = root.appendingPathComponent(leaf, isDirectory: true)
            if !fm.fileExists(atPath: candidate.path) { return candidate }
        }
        return root.appendingPathComponent("\(base) \(UUID().uuidString.prefix(8)).\(packageExtension)",
                                          isDirectory: true)
    }

    /// 本工作区的 id（没有就是还没参与过镜像）。**只读不生成**：建镜像时 `MirrorBuilder` 会补上。
    var workspaceId: String? { store?.workspaceId }

    /// 本机是否已经有这个工作区的镜像。**判据是 `workspace_id`，不是名字**（同 `findMirrorSource`）。
    ///
    /// 用来拦住「已经有一份了还闷头再建一份」：那等于把笔迹分散到两份镜像里，
    /// 而且两份都各自带着自己的基线，谁也说不清哪份是全的。
    static func existingMirror(of workspaceId: String) -> URL? {
        let fm = FileManager.default
        let kids = (try? fm.contentsOfDirectory(at: mirrorsRoot, includingPropertiesForKeys: nil,
                                                options: [.skipsHiddenFiles])) ?? []
        for url in kids where url.pathExtension == packageExtension {
            guard let db = try? SQLiteDB(path: url.appendingPathComponent("UniReader/library.sqlite").path)
            else { continue }
            defer { db.close() }
            let of = (try? db.query("SELECT value FROM meta WHERE key='\(MirrorStore.metaMirrorOf)'"))?
                .first?["value"] as? String
            if of == workspaceId { return url }
        }
        return nil
    }

    // MARK: - 建镜像

    /// 建镜像。**在后台线程调用**（拷 PDF 是 GB 级）。
    /// `destination` 由 [plannedMirrorURL] 算出、界面上先摆给用户看，不经保存面板挑选。
    func makeMirror(to destination: URL, documentsWithPDF: Set<String>,
                    progress: ((String, Double) -> Void)? = nil) throws -> MirrorBuilder.Result {
        guard let store, let folder else { throw MirrorBuilder.Failure.sourceIsMirror }
        let plan = MirrorBuilder.Plan(documentsWithPDF: documentsWithPDF,
                                      sourceHint: folder.path)
        return try MirrorBuilder.create(source: folder, store: store, destination: destination,
                                        plan: plan, resolve: mirrorResolver(), progress: progress)
    }

    /// 建镜像前的估算（要拷多少、有没有解析不到的）。
    func mirrorEstimate(documentsWithPDF: Set<String>) -> MirrorBuilder.Estimate? {
        guard let store, let folder else { return nil }
        return MirrorBuilder.estimate(source: folder, store: store,
                                      plan: .init(documentsWithPDF: documentsWithPDF),
                                      resolve: mirrorResolver())
    }

    /// 忘掉本机那份离线副本（「保留离线副本」开关关掉时走这里）：把源库上对应的那条借出记录抹掉。
    /// 借出记录**是信息不是锁**，但副本都没了还挂着「借出 1 份」，那句话就成了假话。
    ///
    /// 🔴 **文件删除刻意不在这里做**：那是几 GB 的 `removeItem`，放主线程会整个卡住；
    /// 而这个方法要动 `store`（单连接、非线程安全，只能在主线程碰）。两件事必须分开跑
    /// ——调用方在主线程调它，再把目录扔到后台队列去删。
    func forgetMirror(at mirror: URL) {
        guard let mirrorId = LibraryStore.peekIdentity(folder: mirror)?.mirrorId, let store else { return }
        let left = checkouts.filter { $0.mirrorId != mirrorId }
        try? store.setMeta(MirrorStore.metaCheckouts, MirrorStore.encodeCheckouts(left))
    }

    // MARK: - 找源盘

    /// 在候选目录里找出本镜像的源工作区。
    ///
    /// **判据是 `workspace_id`，不是路径也不是名字**：路径换台机器/换挂载点必变，名字会被改，
    /// 而且盘上可能同时躺着源和另一份同名镜像。
    /// 候选 = 最近工作区 + 已挂载卷根下一层的 `.unrd`（够用；深扫留给用户手指）。
    static func findMirrorSource(id: String, recents: [URL]) -> URL? {
        for url in candidateWorkspaces(recents: recents) {
            guard let db = try? SQLiteDB(path: url.appendingPathComponent("UniReader/library.sqlite").path)
            else { continue }
            defer { db.close() }
            let wid = (try? db.query("SELECT value FROM meta WHERE key='workspace_id'"))?
                .first?["value"] as? String
            // 镜像自己也带着 workspace_id，但它同时带 mirror_of —— 源盘不会有这一条
            let isMirror = ((try? db.query("SELECT value FROM meta WHERE key='\(MirrorStore.metaMirrorOf)'")) ?? [])
                .isEmpty == false
            if wid == id, !isMirror { return url }
        }
        return nil
    }

    private static func candidateWorkspaces(recents: [URL]) -> [URL] {
        var out = recents
        let fm = FileManager.default
        let vols = fm.mountedVolumeURLs(includingResourceValuesForKeys: nil,
                                        options: [.skipHiddenVolumes]) ?? []
        for vol in vols {
            let kids = (try? fm.contentsOfDirectory(at: vol, includingPropertiesForKeys: nil,
                                                    options: [.skipsHiddenFiles])) ?? []
            out += kids.filter { $0.pathExtension == WorkspaceManager.packageExtension }
        }
        // 去重，保持最近列表在前（最可能是那一个）
        var seen = Set<String>()
        return out.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    // MARK: - 干跑

    /// 干跑的产物：计划 + 报告要用的两张名字表。
    /// `titles` 是 `documentId → 书名`；`hashTitles` 是 `content_hash → 书名`，只有 OCR
    /// 那条明细用得上（`ocr_page` 按内容 hash 缓存，不知道自己属于哪篇文档）。
    struct DryRun {
        var plan: MirrorDiff.Plan
        var titles: [String: String]
        var hashTitles: [String: String]
    }

    /// 干跑：算出「按下同步会发生什么」。**一个字都不写**（方案 §8.3 第 3 步）。
    ///
    /// 本工作区必须是镜像；`sourceFolder` 是找回来的源盘。在后台线程调用。
    func mirrorDryRun(sourceFolder: URL) throws -> DryRun {
        guard let store, isMirror else { throw MirrorBuilder.Failure.sourceIsMirror }
        // 源库这里是**另一个工作区**的库，本进程未必开着它；用完即关的短连接即可。
        // （若它恰好也开着，那边有自己的实例——我们只读，不写，不违反「同一路径同一实例」。）
        let srcDB = try SQLiteDB(path: sourceFolder.appendingPathComponent("UniReader/library.sqlite").path)
        defer { srcDB.close() }
        let mine = try store.mirrorSnapshot()
        let theirs = try MirrorStore.snapshot(srcDB)
        // 基线走本工作区**已有的那个 store**，不另开连接：镜像库正被本窗口开着，
        // 为读一张表再开一条连接就是在自找「硬盘弹不出去」那类问题（§8「关掉工作区 = 当场放掉引用」）。
        let plan = MirrorDiff.compute(base: try store.syncBase(), mine: mine, theirs: theirs,
                                      mineOCR: try store.mirrorOCRKeys(),
                                      theirsOCR: try MirrorStore.ocrKeys(srcDB),
                                      mineImages: try store.mirrorImageKeys(),
                                      theirsImages: try MirrorStore.imageKeys(srcDB, folder: sourceFolder),
                                      mineAlign: try store.mirrorAlignStamps(),
                                      theirsAlign: try MirrorStore.alignStamps(srcDB))
        return DryRun(plan: plan,
                      titles: MirrorStore.titles(mine: mine, theirs: theirs),
                      hashTitles: MirrorStore.ocrTitles(mine: mine, theirs: theirs))
    }

    // MARK: - 从源盘这一侧发起（副本插回来之后的「收口」）

    /// 与 `mirrorDryRun` 是**同一件事、角色对调**：`base`/`mine` 永远取副本那一侧
    /// （`sync_base` 只存在于副本库里），只是这回副本的连接要现开。
    /// 因此 `Plan.side` 的语义不变，界面与 `MirrorApply` 都不必知道是谁发起的。
    ///
    /// 🔴 副本若**此刻正被别的窗口开着**，必须写它那条连接（同 `mirrorApply` 的理由）。
    func mirrorDryRunFromSource(mirrorFolder: URL) throws -> DryRun {
        guard let store, !isMirror else { throw MirrorBuilder.Failure.sourceIsMirror }
        let opened = WorkspaceRegistry.shared.openManager(at: mirrorFolder)
        let temp: LibraryStore? = opened == nil ? try LibraryStore(workspaceFolder: mirrorFolder) : nil
        defer { temp?.close() }
        guard let mirrorStore = opened?.store ?? temp else { throw MirrorBuilder.Failure.sourceIsMirror }
        let mine = try mirrorStore.mirrorSnapshot()
        let theirs = try store.mirrorSnapshot()
        let plan = MirrorDiff.compute(base: try mirrorStore.syncBase(), mine: mine, theirs: theirs,
                                      mineOCR: try mirrorStore.mirrorOCRKeys(),
                                      theirsOCR: try store.mirrorOCRKeys(),
                                      mineImages: try mirrorStore.mirrorImageKeys(),
                                      theirsImages: try store.mirrorImageKeys(),
                                      mineAlign: try mirrorStore.mirrorAlignStamps(),
                                      theirsAlign: try store.mirrorAlignStamps())
        return DryRun(plan: plan,
                      titles: MirrorStore.titles(mine: mine, theirs: theirs),
                      hashTitles: MirrorStore.ocrTitles(mine: mine, theirs: theirs))
    }

    /// 从源盘这一侧应用合并。同样是角色对调，**合并逻辑一份都不重写**。
    func mirrorApplyFromSource(mirrorFolder: URL, plan: MirrorDiff.Plan,
                               progress: ((String, Double) -> Void)? = nil) throws -> MirrorApply.Result {
        guard let store, let folder, !isMirror else { throw MirrorBuilder.Failure.sourceIsMirror }
        let opened = WorkspaceRegistry.shared.openManager(at: mirrorFolder)
        let temp: LibraryStore? = opened == nil ? try LibraryStore(workspaceFolder: mirrorFolder) : nil
        defer { temp?.close() }
        guard let mirrorStore = opened?.store ?? temp else { throw MirrorBuilder.Failure.sourceIsMirror }

        let mirrorResolve: (LibLocation) -> String? = { loc in
            (loc.inWorkspace || loc.isRelative)
                ? mirrorFolder.appendingPathComponent(loc.path).path : loc.path
        }
        let before = Self.progressSnapshot(store)   // 进度排查：合并会整行 upsert `document`，读到哪也在里面
        let r = try MirrorApply.apply(plan: plan,
                                      mirrorFolder: mirrorFolder, mirrorStore: mirrorStore,
                                      sourceFolder: folder, sourceStore: store,
                                      resolveMirror: mirrorResolve, resolveSource: mirrorResolver(),
                                      progress: progress)
        Self.logProgressChanges(before, store, side: "本工作区（源）")
        DispatchQueue.main.async {
            self.refresh()
            opened?.refresh()
            self.reconcileAndPurgeImages()      // 合并后图片的引用可能变了：对账 + 清缓存（`imageInfo`）
            opened?.reconcileAndPurgeImages()
        }
        return r
    }

    // MARK: - 源 → 副本：自动、静默

    /// 自动把源盘这边的改动推给本机副本（用户 2026-09-01 拍板：**源→副本自动静默，
    /// 副本→源必须人工确认**）。**在后台线程调用。**
    ///
    /// 只在整份 plan **全是「推给副本」且零冲突**时才动手，理由见 `MirrorDiff.Plan.isCleanPushToMirror`
    /// ——一句话：只应用一半会让收尾的基线重算抹掉另一半的证据，下一轮就变成静默删数据。
    ///
    /// 返回还剩多少条要人工确认（副本→源那个方向），给侧栏那条提示用；没有副本 → nil。
    @discardableResult
    func autoPushToMirror(mirrorFolder: URL) -> Int? {
        guard !isMirror else { return nil }
        guard let plan = (try? mirrorDryRunFromSource(mirrorFolder: mirrorFolder))?.plan else { return nil }
        guard plan.isCleanPushToMirror else { return plan.pendingToSource }
        // 静默：不弹进度、不弹结果。失败也不打扰用户——下次再跑一遍即可（合并本身可重入），
        // 真有东西没过去，副本那侧打开时的提示条会兜住。
        guard (try? mirrorApplyFromSource(mirrorFolder: mirrorFolder, plan: plan)) != nil else {
            return plan.pendingToSource
        }
        return 0
    }

    // MARK: - 应用合并

    /// 应用一次合并（M5）。**在后台线程调用。**
    ///
    /// 传进来的 `plan` 就是**干跑给用户看的那一份**，不在这里重算 —— 重算就意味着
    /// 「用户看到的」和「实际做的」可能不是同一件事，而这一步会大批量改用户数据。
    ///
    /// 🔴 源工作区若**此刻正被别的窗口开着**，必须写它那条连接（`WorkspaceRegistry.openManager`），
    /// 不能另开一条：两条活连接同时写同一个库正是 §8.1 红线要根除的。没开着才临时开一条、用完即关。
    func mirrorApply(sourceFolder: URL, plan: MirrorDiff.Plan,
                     progress: ((String, Double) -> Void)? = nil) throws -> MirrorApply.Result {
        guard let store, let folder, isMirror else { throw MirrorBuilder.Failure.sourceIsMirror }
        let opened = WorkspaceRegistry.shared.openManager(at: sourceFolder)
        let temp: LibraryStore? = opened == nil ? try LibraryStore(workspaceFolder: sourceFolder) : nil
        defer { temp?.close() }
        guard let sourceStore = opened?.store ?? temp else { throw MirrorBuilder.Failure.sourceIsMirror }

        let srcResolver: (LibLocation) -> String? = { loc in
            (loc.inWorkspace || loc.isRelative)
                ? sourceFolder.appendingPathComponent(loc.path).path : loc.path
        }
        let before = Self.progressSnapshot(store)   // 同上：这一侧是副本
        let r = try MirrorApply.apply(plan: plan,
                                      mirrorFolder: folder, mirrorStore: store,
                                      sourceFolder: sourceFolder, sourceStore: sourceStore,
                                      resolveMirror: mirrorResolver(), resolveSource: srcResolver,
                                      progress: progress)
        Self.logProgressChanges(before, store, side: "本工作区（副本）")
        DispatchQueue.main.async {
            self.refresh()
            opened?.refresh()
            self.reconcileAndPurgeImages()
            opened?.reconcileAndPurgeImages()
        }
        return r
    }

    // MARK: - 进度排查（`ProgressLog`，默认关）

    /// 合并前后各拍一次「每篇读到哪」。离线镜像的 `document` 行是**整行 upsert**（见 `MirrorApply.write`），
    /// 所以另一侧（安卓 / 另一台机器）读到的位置会连同笔记一起合并回来——「进度跑到不知道什么地方」
    /// 如果是这么来的，就只会在这里留下痕迹，其余所有打点都看不见。
    static func progressSnapshot(_ store: LibraryStore) -> [String: (Int, Double, String)] {
        guard ProgressLog.enabled, let docs = try? store.allDocuments() else { return [:] }
        var m: [String: (Int, Double, String)] = [:]
        for d in docs { m[d.id] = (d.readPage, d.readFrac, d.title) }
        return m
    }

    static func logProgressChanges(_ before: [String: (Int, Double, String)],
                                   _ store: LibraryStore, side: String) {
        guard ProgressLog.enabled, !before.isEmpty else { return }
        let after = progressSnapshot(store)
        for (id, now) in after {
            guard let was = before[id] else { continue }
            guard was.0 != now.0 || abs(was.1 - now.1) > 0.0005 else { continue }
            ProgressLog.log("镜像合并改写进度 \(side) "
                + "\(ProgressLog.pos(was.0, was.1)) → \(ProgressLog.pos(now.0, now.1)) "
                + ProgressLog.doc(id, now.2))
        }
    }
}
