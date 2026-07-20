import Foundation
import PDFKit
import AppKit

/// App 级单例：持有「当前工作区」及其 `LibraryStore`（跨平台 SQLite 单库）。
/// 工作区 = 一个可移动文件夹；配置与笔记都存文件夹里的 `UniReader/library.sqlite`。
/// 最近工作区列表存**本机** UserDefaults（不进文件夹）。主线程使用。
@MainActor
final class WorkspaceManager: ObservableObject {
    @Published private(set) var folder: URL?
    @Published private(set) var name: String = ""
    @Published private(set) var documents: [LibDocument] = []
    @Published private(set) var recents: [URL] = []
    @Published var lastError: String?
    private(set) var restoreDocIds: [String] = []   // 工作区打开时读到的待恢复文档集（多窗口会话）
    private var windowDocs: [UUID: String] = [:]     // 各窗口当前文档（活集，持久化到 meta）

    private(set) var store: LibraryStore?

    private let recentsKey = "recentWorkspaces"
    private let lastKey = "lastWorkspacePath"

    init() {
        loadRecents()
        let last = UserDefaults.standard.string(forKey: lastKey).map { URL(fileURLWithPath: $0) }
        do {
            try open(folder: (last.flatMap { isDir($0) ? $0 : nil }) ?? Self.defaultFolder())
        } catch {
            lastError = "\(error)"
        }
    }

    /// 首次无工作区时的默认：应用支持目录下的 DefaultWorkspace。
    static func defaultFolder() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("UniReader", isDirectory: true)
            .appendingPathComponent("DefaultWorkspace", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    /// 打开（或在空文件夹里新建）一个工作区。
    func open(folder: URL) throws {
        let store = try LibraryStore(workspaceFolder: folder)
        if store.workspaceName.isEmpty { try? store.setWorkspaceName(folder.lastPathComponent) }
        self.store = store
        self.folder = folder
        self.name = store.workspaceName
        restoreDocIds = store.openDocuments()   // 读取上次打开的文档集，供多窗口恢复
        windowDocs = [:]
        rememberRecent(folder)
        UserDefaults.standard.set(folder.path, forKey: lastKey)
        refresh()
        lastError = nil
    }

    /// 某窗口的当前文档变化（nil = 清空）。更新活集并持久化到工作区 meta。
    func setWindowDoc(_ sessionId: UUID, _ docId: String?) {
        if let docId { windowDocs[sessionId] = docId } else { windowDocs.removeValue(forKey: sessionId) }
        persistOpenSet()
    }
    /// 窗口关闭 → 从活集移除。**app 退出时不收缩**（保留打开集供下次恢复）。
    func closeWindow(_ sessionId: UUID) {
        if AppDelegate.isTerminating { return }
        if windowDocs.removeValue(forKey: sessionId) != nil { persistOpenSet() }
    }
    private func persistOpenSet() {
        var seen = Set<String>(), ordered: [String] = []
        for v in windowDocs.values where seen.insert(v).inserted { ordered.append(v) }
        try? store?.setOpenDocuments(ordered)
    }

    func rename(_ newName: String) {
        try? store?.setWorkspaceName(newName)
        name = store?.workspaceName ?? newName
    }

    func refresh() { documents = (try? store?.allDocuments()) ?? [] }

    // MARK: - 文档

    /// 导入一个 PDF（已算好 hash）。按 hash 找到或新建逻辑文档；返回它。
    @discardableResult
    func ingest(path: String, hash: String, title: String, pageCount: Int) -> LibDocument? {
        guard let store, !hash.isEmpty else { return nil }
        let res = try? store.findOrCreate(hash: hash, title: title, pageCount: pageCount, path: path)
        refresh()
        return res?.document
    }

    func delete(documentId: String) { try? store?.deleteDocument(id: documentId); refresh() }
    func rename(documentId: String, title: String) { try? store?.rename(documentId: documentId, title: title); refresh() }
    func document(id: String) -> LibDocument? { documents.first { $0.id == id } }

    /// location 的实际绝对路径：工作区内的存相对路径（随文件夹移动仍有效），外部的存绝对路径。
    func resolvedPath(_ loc: LibLocation) -> String {
        guard loc.inWorkspace, let folder else { return loc.path }
        return folder.appendingPathComponent(loc.path).path
    }

    /// 打开某逻辑文档：跨其所有版本探测第一个仍存在的物理文件（**优先工作区内副本**），
    /// 返回 (绝对路径, 该版本 hash)。全部失效 → nil（上层提示重定位）。
    func openTarget(documentId: String) -> (path: String, hash: String)? {
        guard let store else { return nil }
        var locs = (try? store.locations(documentId: documentId)) ?? []
        locs.sort { $0.inWorkspace && !$1.inWorkspace }   // 工作区副本优先
        for l in locs {
            let abs = resolvedPath(l)
            if FileManager.default.fileExists(atPath: abs) {
                try? store.setLocationValidity(id: l.id, isValid: true)
                try? store.updateLastOpened(documentId: documentId)
                let hash = (try? store.variant(id: l.variantId))?.contentHash ?? ""
                return (abs, hash)
            }
            try? store.setLocationValidity(id: l.id, isValid: false)
        }
        return nil
    }

    // MARK: - 阅读进度

    /// 保存进度（不 refresh，避免列表抖动；下次打开从 store 读最新）。
    func saveProgress(documentId: String, page: Int, frac: Double) {
        try? store?.updateProgress(documentId: documentId, page: page, frac: frac)
    }
    /// 读取最新进度（直接查库，绕过可能过时的 documents 缓存）。
    func progress(documentId: String) -> (page: Int, frac: Double) {
        if let d = try? store?.document(id: documentId) { return (d.readPage, d.readFrac) }
        return (0, 0)
    }

    // MARK: - 复制进/移出工作区

    func isInWorkspace(_ documentId: String) -> Bool {
        guard let store else { return false }
        return !((try? store.inWorkspaceLocations(documentId: documentId)) ?? []).isEmpty
    }

    /// 把该文档当前可用的文件复制进工作区 `PDFs/`，加一条工作区内 location（相对路径）。
    func copyToWorkspace(documentId: String) {
        guard let store, let folder,
              let target = openTarget(documentId: documentId),
              let v = try? store.variant(hash: target.hash) else { return }
        if isInWorkspace(documentId) { return }
        let pdfDir = folder.appendingPathComponent("PDFs", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: pdfDir, withIntermediateDirectories: true)
            let rel = "PDFs/\(UUID().uuidString).pdf"
            try FileManager.default.copyItem(at: URL(fileURLWithPath: target.path),
                                             to: folder.appendingPathComponent(rel))
            try store.addLocation(variantId: v.id, path: rel, inWorkspace: true)
            refresh()
        } catch { lastError = "\(error)" }
    }

    /// 删除单个 location 记录（Inspector「文件」列表的 × 用）。若是工作区内副本，一并删物理文件。
    /// **调用方须保证该文档至少保留一个 location**（不在此强制，便于 UI 决定）。
    func deleteLocation(_ loc: LibLocation) {
        guard let store else { return }
        if loc.inWorkspace, let folder {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(loc.path))
        }
        try? store.removeLocation(id: loc.id)
        refresh()
    }

    /// 从工作区移出：删掉工作区内副本文件与对应 location（保留外部路径）。
    func removeFromWorkspace(documentId: String) {
        guard let store, let folder else { return }
        for l in (try? store.inWorkspaceLocations(documentId: documentId)) ?? [] {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(l.path))
            try? store.removeLocation(id: l.id)
        }
        refresh()
    }

    // MARK: - 重定位 / 合并

    /// 重新关联失效文档到用户新选的文件（已算好 hash）。hash 命中已有版本 → 加路径；否则 → 作为该文档新版本。
    func relocate(documentId: String, path: String, hash: String, pageCount: Int) {
        guard let store, !hash.isEmpty else { return }
        if let v = try? store.variant(hash: hash) {
            _ = try? store.addLocation(variantId: v.id, path: path, inWorkspace: false)
        } else {
            _ = try? store.addVariant(documentId: documentId, hash: hash, pageCount: pageCount, path: path)
        }
        refresh()
    }

    /// 「关联为同一文档」：把 source 并入 target（多 hash 合并）。
    func mergeDocuments(sourceId: String, intoTargetId targetId: String) {
        _ = try? store?.mergeDocument(sourceId: sourceId, intoTargetId: targetId)
        refresh()
    }

    // MARK: - 访达 / inspector 数据

    /// 当前可用文件的绝对路径（**只探测、不更新 lastOpened**，供 reveal / inspector 用）。
    func currentFilePath(documentId: String) -> String? {
        guard let store else { return nil }
        var locs = (try? store.locations(documentId: documentId)) ?? []
        locs.sort { $0.inWorkspace && !$1.inWorkspace }
        for l in locs {
            let abs = resolvedPath(l)
            if FileManager.default.fileExists(atPath: abs) { return abs }
        }
        return nil
    }

    /// 在访达中打开该文档正在使用的文件所在文件夹并选中它。
    func revealInFinder(documentId: String) {
        guard let p = currentFilePath(documentId: documentId) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p)])
    }

    func variants(documentId: String) -> [LibVariant] { (try? store?.variants(documentId: documentId)) ?? [] }
    func locations(documentId: String) -> [LibLocation] { (try? store?.locations(documentId: documentId)) ?? [] }
    func notes(documentId: String) -> [LibNote] { (try? store?.notes(documentId: documentId)) ?? [] }

    // MARK: - 手写笔迹持久化（note kind=2；挂逻辑文档，全版本共用）

    /// 读取某文档已落库的全部手写笔画（按页/时间序），用于重开恢复。
    func inkStrokes(documentId: String) -> [InkStroke] {
        ((try? store?.notes(documentId: documentId)) ?? [])
            .compactMap { $0.kind == InkStroke.noteKind ? InkStroke(note: $0) : nil }
    }

    /// 落库/更新一条手写笔画（笔画完成时调用）。空笔画自动跳过。
    func saveInkStroke(documentId: String, _ stroke: InkStroke) {
        guard let store, let note = stroke.toNote(documentId: documentId) else { return }
        try? store.upsertNote(note)
    }

    /// 删除一条手写笔画（擦除时调用；note.id == stroke.id）。
    func deleteInkStroke(id: UUID) {
        try? store?.deleteNote(id: id.uuidString)
    }

    // MARK: - 最近工作区

    private func loadRecents() {
        let arr = (UserDefaults.standard.array(forKey: recentsKey) as? [String]) ?? []
        recents = arr.map { URL(fileURLWithPath: $0) }
    }
    private func rememberRecent(_ url: URL) {
        var paths = recents.map(\.path).filter { $0 != url.path }
        paths.insert(url.path, at: 0)
        paths = Array(paths.prefix(10))
        UserDefaults.standard.set(paths, forKey: recentsKey)
        recents = paths.map { URL(fileURLWithPath: $0) }
    }
    private func isDir(_ url: URL) -> Bool {
        var d: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &d) && d.boolValue
    }
}
