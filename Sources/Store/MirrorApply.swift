import Foundation

/// **应用**三方合并的结果（方案 `OFFLINE-MIRROR-PLAN.md` §8.3 第 4~5 步）。
/// 算是 `MirrorDiff` 的事，这里只负责把算好的 `Plan` 落到两边的库和文件上。
///
/// 🔴 这是整个功能里**唯一会大批量改用户数据**的一段。四道保险：
/// ① 合并前先把源库整份备份出来（`VACUUM INTO`，留最近 3 份）；
/// ② 每一侧的行操作在**一个事务**里，中途出错整体回滚；
/// ③ 文件搬运在事务外、幂等、可重入 —— 拷一半再来一次结果一样；
/// ④ 基线**两侧都成功了才重算**。
///
/// ## 为什么"半途而废"是安全的
///
/// 两个库在两个文件上，跨库事务不存在，所以理论上会出现「源盘写了、镜像没写」。
/// 这在本方案里**能自愈**，不需要补偿逻辑：下一次跑 diff 时，那些已经落到源盘的行会变成
/// 「两端相对基线都改成了同一个样子」（`mineFp == theirsFp`）→ 判为无操作；没落的那些仍然
/// 照常被算出来。所以顺序是**先源盘后镜像**：源盘在可移动介质上，中途被拔的概率更高，
/// 让它先落地、失败也只是回滚到原样。
enum MirrorApply {

    struct Result {
        var sourceUpserts = 0, sourceDeletes = 0
        var mirrorUpserts = 0, mirrorDeletes = 0
        /// 因为父文档已经不在了而被丢弃的行（见 `livingDocuments`）。
        var orphansSkipped = 0
        var lastOpenedTouched = 0
        var filesCopiedToSource = 0
        var backup: URL?
    }

    // MARK: - 备份

    /// 合并前把源库整份备份到 `<源>/UniReader/backup/library-<时间戳>.sqlite`，保留最近 [keep] 份。
    ///
    /// 廉价保险：库通常几十 MB，而这一步保护的是用户全部的笔迹。
    /// **失败即中止整次合并** —— 没有备份就动手，是把"最坏情况"从"回滚"变成"没得救"。
    static func backupSource(_ store: LibraryStore, folder: URL, keep: Int = 3) throws -> URL {
        let dir = folder.appendingPathComponent("UniReader/backup", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stamp = ISO.string(.now).replacingOccurrences(of: ":", with: "-")
        let dst = dir.appendingPathComponent("library-\(stamp).sqlite")
        store.checkpointTruncate()
        try store.vacuumInto(dst.path)
        pruneBackups(dir, keep: keep)
        return dst
    }

    private static func pruneBackups(_ dir: URL, keep: Int) {
        let fm = FileManager.default
        let all = ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? [])
            .filter { $0.hasPrefix("library-") && $0.hasSuffix(".sqlite") }
            .sorted()                       // 名字里带 ISO 时间戳 → 字典序即时间序
        for old in all.dropLast(keep) {
            try? fm.removeItem(at: dir.appendingPathComponent(old))
        }
    }

    // MARK: - 写一侧

    /// 目标表实际有哪些列。**按目标库的列来写**，不按源行带来的键：两端 schema 版本可能差一格，
    /// 硬写会因"没有这一列"整批失败。
    private static func columns(_ db: SQLiteDB, _ table: String) -> [String] {
        ((try? db.query("PRAGMA table_info(\(table))")) ?? []).compactMap { $0["name"] as? String }
    }

    private static func bind(_ v: Any?) -> SQLiteDB.Value {
        switch v {
        case let s as String: return .text(s)
        case let n as Int64: return .int(n)
        case let n as Int: return .int(Int64(n))
        case let d as Double: return .double(d)
        case let b as Data: return .blob(b)
        default: return .null
        }
    }

    /// 合并之后目标库里**还活着**的文档 id：现有的 ∪ 本批要插的 − 本批要删的。
    ///
    /// 拿它过滤 `note`/`ink_layer`/`scratch_pad`/`variant` 的 upsert。不过滤的话会撞外键：
    /// 「源盘上把这本书删了、同时我在镜像上给它写了新笔迹」——那条笔迹推到源盘时父文档已经没了，
    /// **整个事务回滚，整次同步失败**。宁可丢掉那一行并报出来，也不要让用户面对一个
    /// 「点了没反应、也不知道为什么」的同步。
    static func livingDocuments(_ db: SQLiteDB, changes: [MirrorDiff.Change]) -> Set<String> {
        var live = Set(((try? db.query("SELECT id FROM document")) ?? []).compactMap { $0["id"] as? String })
        for c in changes where c.table == "document" {
            if c.op == .upsert { live.insert(c.rowId) } else { live.remove(c.rowId) }
        }
        return live
    }

    /// 把一批改动写进一个库（**调用方负责包事务**）。
    @discardableResult
    static func write(_ db: SQLiteDB, _ changes: [MirrorDiff.Change],
                      result: inout Result, side: MirrorDiff.Side) throws -> Int {
        let live = livingDocuments(db, changes: changes)
        let order = MirrorFp.specs.map(\.table)

        // ① 先删，后插。反过来会撞 `variant.content_hash` 的 UNIQUE：
        //    「删掉旧版本、换一份同内容的进来」在同一批里就是先插会重、先删才对。
        for table in order.reversed() {
            guard let spec = MirrorFp.spec(table) else { continue }
            for c in changes where c.table == table && c.op == .delete {
                try db.run("DELETE FROM \(table) WHERE \(spec.key)=?", [.text(c.rowId)])
                if side == .source { result.sourceDeletes += 1 } else { result.mirrorDeletes += 1 }
            }
        }
        // ② 插：按表依赖序（document 在前，其余都指向它）
        for table in order {
            guard let spec = MirrorFp.spec(table) else { continue }
            let cols = columns(db, table)
            for c in changes where c.table == table && c.op == .upsert {
                guard let row = c.row else { continue }
                if table != "document", table != "meta", let doc = row["document_id"] as? String,
                   !live.contains(doc) {
                    result.orphansSkipped += 1
                    continue
                }
                let use = cols.filter { row.index(forKey: $0) != nil }
                guard !use.isEmpty else { continue }
                let ph = use.map { _ in "?" }.joined(separator: ",")
                let sets = use.filter { $0 != spec.key }
                    .map { "\($0)=excluded.\($0)" }.joined(separator: ",")
                let sql = "INSERT INTO \(table)(\(use.joined(separator: ","))) VALUES(\(ph)) "
                    + "ON CONFLICT(\(spec.key)) DO UPDATE SET \(sets.isEmpty ? "\(spec.key)=excluded.\(spec.key)" : sets)"
                try db.run(sql, use.map { bind(row[$0]) })
                if side == .source { result.sourceUpserts += 1 } else { result.mirrorUpserts += 1 }
            }
        }
        return changes.count
    }

    /// `document.last_opened_at`：不进指纹，两端一律取较晚的那个（方案 §4）。
    static func writeLastOpened(_ db: SQLiteDB, _ merges: [String: String]) throws -> Int {
        var n = 0
        for (id, iso) in merges.sorted(by: { $0.key < $1.key }) {
            try db.run("UPDATE document SET last_opened_at=? WHERE id=? AND last_opened_at<?",
                       [.text(iso), .text(id), .text(iso)])
            n += 1
        }
        return n
    }

    // MARK: - 文件补齐

    /// 镜像上新加的书要把 PDF 拷回源盘（方案 §7 的那一条幂等规则）。
    ///
    /// **不走 diff**：`location` 是设备本地事实、不参与同步，所以这一步是「合并完之后扫一遍、
    /// 缺什么补什么」。幂等、可重入 —— 拷一半断电再来一次结果一样。
    static func fillFilesToSource(mirrorFolder: URL, mirrorStore: LibraryStore,
                                  sourceFolder: URL, sourceStore: LibraryStore,
                                  resolveMirror: (LibLocation) -> String?,
                                  resolveSource: (LibLocation) -> String?) throws -> Int {
        let fm = FileManager.default
        var copied = 0
        for doc in try sourceStore.allDocuments() {
            for v in try sourceStore.variants(documentId: doc.id) {
                // 源盘已经有能打开的文件 → 不用管
                let srcLocs = try sourceStore.locations(variantId: v.id)
                if srcLocs.contains(where: { resolveSource($0).map(fm.fileExists(atPath:)) ?? false }) { continue }
                // 镜像上有吗？（同一个 variant id —— 合并之后两边的 variant 表已经一致）
                guard let hit = try mirrorStore.locations(variantId: v.id).first(where: {
                    $0.inWorkspace && (resolveMirror($0).map(fm.fileExists(atPath:)) ?? false)
                }), let from = resolveMirror(hit) else { continue }
                let rel = "PDFs/\(UUID().uuidString).pdf"
                let to = sourceFolder.appendingPathComponent(rel)
                try fm.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
                let tmp = to.deletingLastPathComponent().appendingPathComponent(".\(to.lastPathComponent).part")
                try? fm.removeItem(at: tmp)
                try fm.copyItem(at: URL(fileURLWithPath: from), to: tmp)
                try? fm.removeItem(at: to)
                try fm.moveItem(at: tmp, to: to)
                _ = try sourceStore.addLocation(variantId: v.id, path: rel, inWorkspace: true)
                copied += 1
            }
        }
        return copied
    }

    // MARK: - 主流程

    /// 应用一次合并。**在后台线程调用。**
    ///
    /// - Parameters:
    ///   - plan: `MirrorDiff.compute` 的产物（就是干跑给用户看的那一份，不重算 —— 重算就
    ///     意味着"用户看到的"和"实际做的"可能不是同一件事）。
    static func apply(plan: MirrorDiff.Plan,
                      mirrorFolder: URL, mirrorStore: LibraryStore,
                      sourceFolder: URL, sourceStore: LibraryStore,
                      resolveMirror: (LibLocation) -> String?,
                      resolveSource: (LibLocation) -> String?,
                      progress: ((String, Double) -> Void)? = nil) throws -> Result {
        var r = Result()

        // ① 备份。失败即中止 —— 没有备份就动手是把"最坏情况"从回滚变成没得救。
        progress?("正在备份硬盘上的资料库…", 0.05)
        r.backup = try backupSource(sourceStore, folder: sourceFolder)

        // ② 源盘侧（先做：它在可移动介质上，中途被拔的概率更高，失败也只是回滚到原样）
        progress?("正在写入硬盘…", 0.25)
        let toSource = plan.changes(to: .source)
        try sourceStore.withMirrorDB { db in
            try db.transaction {
                try write(db, toSource, result: &r, side: .source)
                r.lastOpenedTouched += try writeLastOpened(db, plan.lastOpenedMerges)
            }
        }

        // ③ 镜像侧
        progress?("正在写入本机…", 0.55)
        let toMirror = plan.changes(to: .mirror)
        try mirrorStore.withMirrorDB { db in
            try db.transaction {
                try write(db, toMirror, result: &r, side: .mirror)
                _ = try writeLastOpened(db, plan.lastOpenedMerges)
            }
        }

        // ④ 文件补齐（事务外，幂等可重入）
        progress?("正在补齐文件…", 0.75)
        r.filesCopiedToSource = try fillFilesToSource(
            mirrorFolder: mirrorFolder, mirrorStore: mirrorStore,
            sourceFolder: sourceFolder, sourceStore: sourceStore,
            resolveMirror: resolveMirror, resolveSource: resolveSource)

        // ⑤ 两侧都成功了才重算基线 —— 这一步之前任何失败都靠"下次再跑一遍"自愈（见类型注释）
        progress?("正在重置基线…", 0.9)
        try mirrorStore.rebuildSyncBase()

        // ⑥ 记账：镜像记同步时间，源盘的借出记录更新 lastSyncedAt
        let now = ISO.string(.now)
        try mirrorStore.setMeta(MirrorStore.metaMirrorLastSyncedAt, now)
        if let mirrorId = mirrorStore.meta(MirrorStore.metaMirrorId) {
            let list = MirrorStore.decodeCheckouts(sourceStore.meta(MirrorStore.metaCheckouts))
            if var c = list.first(where: { $0.mirrorId == mirrorId }) {
                c.lastSyncedAt = now
                c.noteCount = sourceStore.noteCount()
                try sourceStore.setMeta(MirrorStore.metaCheckouts,
                                        MirrorStore.encodeCheckouts(MirrorStore.upsertCheckout(list, c)))
            }
        }
        progress?("完成", 1)
        return r
    }
}
