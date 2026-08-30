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

    // MARK: - 建镜像

    /// 建镜像。**在后台线程调用**（拷 PDF 是 GB 级）。
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

    /// 干跑：算出「按下同步会发生什么」。**一个字都不写**（方案 §8.3 第 3 步）。
    ///
    /// 本工作区必须是镜像；`sourceFolder` 是找回来的源盘。在后台线程调用。
    func mirrorDryRun(sourceFolder: URL) throws -> (plan: MirrorDiff.Plan, titles: [String: String]) {
        guard let store, isMirror else { throw MirrorBuilder.Failure.sourceIsMirror }
        // 源库这里是**另一个工作区**的库，本进程未必开着它；用完即关的短连接即可。
        // （若它恰好也开着，那边有自己的实例——我们只读，不写，不违反「同一路径同一实例」。）
        let srcDB = try SQLiteDB(path: sourceFolder.appendingPathComponent("UniReader/library.sqlite").path)
        defer { srcDB.close() }
        let mine = try store.mirrorSnapshot()
        let theirs = try MirrorStore.snapshot(srcDB)
        // 基线走本工作区**已有的那个 store**，不另开连接：镜像库正被本窗口开着，
        // 为读一张表再开一条连接就是在自找「硬盘弹不出去」那类问题（§8「关掉工作区 = 当场放掉引用」）。
        let plan = MirrorDiff.compute(base: try store.syncBase(), mine: mine, theirs: theirs)
        return (plan, MirrorStore.titles(mine: mine, theirs: theirs))
    }
}
