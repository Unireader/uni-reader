import Foundation
import AppKit

/// 回收站的**执行层**（方案 `BACKUP-PLAN.md §2`）。
///
/// 存储层（`TrashStore`）只认识行，模型层（`Trash`）只认识文件；这里把两边接起来：
/// 删除前先归档、恢复时判断要不要并入、到期清理、以及「哪些图片被回收站护着」。
///
/// 🔴 **归档 → 删除，顺序不许反。** 先删再存，中间任何一步失败就等于数据已经没了，
/// 而这个功能存在的全部意义就是「那一下手滑还有救」。
///
/// 归档那两个入口做成 `Trash` 上的静态函数而不是 `WorkspaceManager` 的方法：图层面板
/// （`LayerManagerNSView`）手上只有 `DocSession`，拿不到 manager，而 `LibraryStore`
/// 自己知道 `workspaceFolder` —— 一份实现两边用，好过为了够得着而把 manager 传进笔架。
extension Trash {

    // MARK: - 归档（写快照 + manifest）

    /// 把一篇文档归档进回收站。成功返回条目目录。**调用方随后才可以删库行。**
    @discardableResult
    static func archiveDocument(store: LibraryStore, documentId: String, title: String) -> URL? {
        let workspace = store.workspaceFolder
        guard let dir = makeDir(in: workspace, title: title) else { return nil }
        do {
            let a = try store.archiveDocument(id: documentId,
                                              to: dir.appendingPathComponent(snapshotName).path)
            var m = Manifest()
            m.kind = .document
            m.title = title
            m.documentId = documentId
            m.documentTitle = title
            m.pageCount = a.pageCount
            m.counts = a.counts
            m.images = a.images
            m.contentHashes = a.contentHashes
            try encode(m).write(to: dir.appendingPathComponent(manifestName))
            wsLog("[TRASH] 已移入回收站：\(title)（\(m.counts.total) 条）")
            return dir
        } catch {
            try? FileManager.default.removeItem(at: dir)
            wsLog("[TRASH] ⚠️ 归档失败，删除已放弃：\(title) — \(error)")
            return nil
        }
    }

    /// 把一个笔迹图层连同它那些笔画归档。笔画本身由调用方随后照常删。
    @discardableResult
    static func archiveInkLayer(store: LibraryStore, documentId: String, documentTitle: String,
                                layerId: UUID, layerName: String, isDefaultLayer: Bool) -> URL? {
        let workspace = store.workspaceFolder
        guard let dir = makeDir(in: workspace, title: layerName) else { return nil }
        do {
            let a = try store.archiveInkLayer(documentId: documentId, layerId: layerId.uuidString,
                                              isDefaultLayer: isDefaultLayer,
                                              to: dir.appendingPathComponent(snapshotName).path)
            var m = Manifest()
            m.kind = .inkLayer
            m.title = layerName
            m.documentId = documentId
            m.documentTitle = documentTitle
            m.layerId = layerId.uuidString
            m.counts = a.counts
            m.images = a.images
            try encode(m).write(to: dir.appendingPathComponent(manifestName))
            wsLog("[TRASH] 图层已移入回收站：\(layerName)（《\(documentTitle)》\(a.counts.ink) 笔）")
            return dir
        } catch {
            try? FileManager.default.removeItem(at: dir)
            wsLog("[TRASH] ⚠️ 图层归档失败，删除已放弃：\(layerName) — \(error)")
            return nil
        }
    }

    /// 把一篇画板笔记归档（那一行 + 上面的笔迹与图）。**调用方随后才可以删库行。**
    @discardableResult
    static func archiveBoard(store: LibraryStore, boardId: UUID, title: String) -> URL? {
        let workspace = store.workspaceFolder
        guard let dir = makeDir(in: workspace, title: title) else { return nil }
        do {
            let a = try store.archiveBoard(id: boardId.uuidString, to: dir.appendingPathComponent(snapshotName).path)
            var m = Manifest()
            m.kind = .board
            m.title = title
            m.counts = a.counts
            m.images = a.images
            try encode(m).write(to: dir.appendingPathComponent(manifestName))
            wsLog("[TRASH] 画板已移入回收站：\(title)（\(m.counts.total) 条）")
            return dir
        } catch {
            try? FileManager.default.removeItem(at: dir)
            wsLog("[TRASH] ⚠️ 画板归档失败，删除已放弃：\(title) — \(error)")
            return nil
        }
    }

    /// 建一个空的条目目录（名字不撞）。
    private static func makeDir(in workspace: URL, title: String) -> URL? {
        let fm = FileManager.default
        let root = folder(in: workspace)
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        let existing = Set((try? fm.contentsOfDirectory(atPath: root.path)) ?? [])
        let dir = root.appendingPathComponent(directoryName(at: .now, title: title, existing: existing),
                                              isDirectory: true)
        do { try fm.createDirectory(at: dir, withIntermediateDirectories: false) } catch { return nil }
        return dir
    }
}

extension WorkspaceManager {

    // MARK: - 读

    var trashEntries: [Trash.Entry] {
        guard let folder else { return [] }
        return Trash.scan(in: folder)
    }

    /// 回收站保留期（本机设置，跨工作区共用）。
    static var trashRetention: Trash.Retention {
        get {
            let raw = UserDefaults.standard.object(forKey: "trashRetentionDays") as? Int
            return raw.flatMap(Trash.Retention.init(rawValue:)) ?? .days30
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "trashRetentionDays") }
    }

    /// 正被回收站条目引用着的图片本体（方案 §2.6 的护身符）。
    ///
    /// 图片走「没人引用 → 打 `orphaned_at` → 30 天后真删」，而文档一删，它引用的图立刻变成孤儿
    /// 并开始计时。保留期若设成 90 天 / 永不，图片会先一步被清掉，再恢复就只剩一个空框。
    var trashHeldImages: Set<String> {
        Set(trashEntries.flatMap(\.manifest.images))
    }

    /// 删除确认框里那句「2616 笔笔迹、12 条笔记、30 处高亮」。一条 GROUP BY，不读 payload。
    /// 一条都没有 → 空串（调用方不显示这一行）。
    func deletionSummary(documentId: String) -> String {
        guard let store, let counts = try? store.noteKindCounts(documentId: documentId) else { return "" }
        var parts: [String] = []
        func add(_ kind: Int, _ fmt: String) {
            if let n = counts[kind], n > 0 { parts.append(String(format: L(fmt), n)) }
        }
        add(2, "%d stroke(s)")
        add(0, "%d note(s)")
        add(3, "%d highlight(s)")
        add(5, "%d bookmark(s)")
        add(6, "%d image note(s)")
        add(4, "%d scratch stroke(s)")
        guard !parts.isEmpty else { return "" }
        let title = document(id: documentId)?.title ?? ""
        return title.isEmpty ? parts.joined(separator: "、")
                             : String(format: L("“%@”: %@"), title, parts.joined(separator: "、"))
    }

    // MARK: - 写：删除（归档 → 真删）

    /// 侧栏「删除」走的那条路：**先归档，成功了才删**。归档失败 → 一行都不删，返回 false。
    @discardableResult
    func trashDocument(id: String) -> Bool {
        guard let store else { return false }
        let title = document(id: id)?.title ?? id
        guard Trash.archiveDocument(store: store, documentId: id, title: title) != nil else {
            lastError = String(format: L("Could not archive “%@”, so nothing was deleted."), title)
            return false
        }
        delete(documentId: id)
        return true
    }

    /// 删画板笔记：同样**先归档，成功了才删**（`board_item` 随外键级联删掉），再对账图片引用。
    @discardableResult
    func trashBoard(id: UUID) -> Bool {
        guard let store else { return false }
        let title = board(id: id)?.displayName ?? L("Untitled Board")
        guard Trash.archiveBoard(store: store, boardId: id, title: title) != nil else {
            lastError = String(format: L("Could not archive “%@”, so nothing was deleted."), title)
            return false
        }
        let shas = Set(boardContents(id: id, pages: boardPages(id: id)).images.map(\.image))
        try? store.deleteBoard(id: id.uuidString)
        if !shas.isEmpty { try? store.reconcileImageOrphans(only: shas) }
        refreshBoards()
        return true
    }

    // MARK: - 写：恢复

    /// 恢复前探路：这条条目恢复时会**并入**哪篇现有文档（方案 §2.5 情形 B）。
    /// nil = 照常整份放回去。
    func trashMergeTarget(_ entry: Trash.Entry) -> LibDocument? {
        guard let store, entry.manifest.kind == .document,
              let id = try? store.trashMergeTarget(snapshot: entry.snapshotURL.path) else { return nil }
        return document(id: id)
    }

    /// 恢复一条条目。成功后删掉条目目录并刷新。
    @discardableResult
    func restoreFromTrash(_ entry: Trash.Entry) -> Bool {
        guard let store else { return false }
        do {
            // 图层级条目的 document_id 在快照行里已经是对的，不需要改写；
            // 文档级条目才可能要并入（那份 PDF 被重新导入过）。
            let remap = entry.manifest.kind == .document
                ? try store.trashMergeTarget(snapshot: entry.snapshotURL.path)
                : nil
            let n = try store.restoreTrash(snapshot: entry.snapshotURL.path, remapDocumentId: remap)
            wsLog("[TRASH] 已恢复 \(entry.manifest.title)：\(n) 行\(remap.map { "（并入 \($0)）" } ?? "")")
        } catch {
            lastError = "\(error)"
            wsLog("[TRASH] ⚠️ 恢复失败：\(entry.manifest.title) — \(error)")
            return false
        }
        try? FileManager.default.removeItem(at: entry.url)
        refresh()
        reconcileAndPurgeImages()   // 图片的待删除标记要跟着摘掉
        return true
    }

    // MARK: - 写：彻底删除 / 清空 / 到期清理

    /// 彻底删除一条（不可撤销——回收站自己没有回收站）。
    @discardableResult
    func purgeTrash(_ entry: Trash.Entry) -> Bool {
        do { try FileManager.default.removeItem(at: entry.url) } catch { lastError = "\(error)"; return false }
        reconcileAndPurgeImages()   // 护身符没了，被它护着的图片回到正常计时
        return true
    }

    /// 清空回收站。返回清掉几条。
    @discardableResult
    func emptyTrash() -> Int {
        var n = 0
        for e in trashEntries where (try? FileManager.default.removeItem(at: e.url)) != nil { n += 1 }
        if n > 0 { reconcileAndPurgeImages() }
        return n
    }

    /// 到期自动清理（打开工作区时跑一次）。`forever` 什么都不做。
    @discardableResult
    func purgeExpiredTrash(now: Date = .now) -> Int {
        let gone = Trash.expired(trashEntries, retention: Self.trashRetention, now: now)
        var n = 0
        for e in gone where (try? FileManager.default.removeItem(at: e.url)) != nil { n += 1 }
        if n > 0 { wsLog("[TRASH] 清理到期条目 \(n) 条") }
        return n
    }
}
