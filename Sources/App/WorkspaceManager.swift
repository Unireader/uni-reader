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
    private(set) var restoreDocIds: [String] = []   // 启动时「上次打开集」快照，供多窗口恢复（restoreSession 读一次进本地）
    private var windowDocs: [UUID: String] = [:]     // 各窗口当前文档（sessionId → docId）——「打开集」的真相源
    private var openDocs: [String] = []              // 当前打开的文档集（= 所有窗口当前文档，去重保序）；持久化供下次恢复

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
        openDocs = store.openDocuments()         // 上次「打开集」（当前所有窗口的文档）
        restoreDocIds = openDocs                 // 启动快照：restoreSession 只读它一次进本地，之后随窗口重同步无碍
        windowDocs = [:]
        rememberRecent(folder)
        UserDefaults.standard.set(folder.path, forKey: lastKey)
        refresh()
        lastError = nil
    }

    /// 某窗口当前文档变化（nil = 该窗口清空选择）。把「打开集」重同步为「所有窗口当前文档」并持久化。
    /// 在一个窗口里切换文档 → 旧文档若不再被任何窗口显示，会随之退出「打开集」（不累积 → 不再「启动开一堆」）。
    func setWindowDoc(_ sessionId: UUID, _ docId: String?) {
        if let docId { windowDocs[sessionId] = docId } else { windowDocs.removeValue(forKey: sessionId) }
        syncOpenDocs(front: docId)
    }

    /// 窗口关闭。三种情形：
    ///  · **cmd+q 退出中**（`AppDelegate.isTerminating`）→ 不动「打开集」，下次启动原样恢复所有窗口；
    ///  · **关的是最后一个窗口** → 不动「打开集」，保留（下次仍恢复这最后一本）；
    ///  · 否则（**cmd+w 关掉多窗口之一**）→ 该文档若已无其它窗口在显示，就从「打开集」移除（逐个关 = 逐个移除）。
    func closeWindow(_ sessionId: UUID) {
        let closed = windowDocs[sessionId]
        windowDocs.removeValue(forKey: sessionId)
        if AppDelegate.isTerminating { return }
        if windowDocs.isEmpty { return }
        if let closed, !windowDocs.values.contains(closed) {
            openDocs.removeAll { $0 == closed }
            persistOpenDocs()
        }
    }

    /// 「打开集」= 所有窗口当前文档（去重、保序；`front` 置最前）。持久化供下次启动恢复。
    /// 启动恢复时也靠它把历史遗留的膨胀列表自动收敛到「真正开出来的窗口」（未恢复成窗口的旧条目在此被剔除）。
    private func syncOpenDocs(front: String?) {
        let live = Set(windowDocs.values)
        openDocs.removeAll { !live.contains($0) }                                       // 去掉已不在任何窗口显示的
        for d in windowDocs.values where !openDocs.contains(d) { openDocs.append(d) }   // 补新开的
        if let front, let i = openDocs.firstIndex(of: front) {                          // 刚打开/切到的置最前
            openDocs.remove(at: i); openDocs.insert(front, at: 0)
        }
        persistOpenDocs()
    }

    /// 从「打开集」剔除（删除/合并文档时——该文档已不该被恢复）。
    private func forgetOpen(_ docId: String) {
        guard openDocs.contains(docId) else { return }
        openDocs.removeAll { $0 == docId }
        persistOpenDocs()
    }

    private func persistOpenDocs() {
        restoreDocIds = openDocs
        try? store?.setOpenDocuments(openDocs)
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
        let stored = externalStorage(for: path)
        let res = try? store.findOrCreate(hash: hash, title: title, pageCount: pageCount, path: stored.path, isRelative: stored.isRelative)
        refresh()
        return res?.document
    }

    func delete(documentId: String) { try? store?.deleteDocument(id: documentId); forgetOpen(documentId); refresh() }
    func rename(documentId: String, title: String) { try? store?.rename(documentId: documentId, title: title); refresh() }
    func document(id: String) -> LibDocument? { documents.first { $0.id == id } }

    /// location 的实际绝对路径：工作区内副本 / 与工作区同盘的外部文件都存相对路径（随文件夹或整块
    /// 移动硬盘一起移动仍有效）；其余外部文件存绝对路径。
    func resolvedPath(_ loc: LibLocation) -> String {
        guard (loc.inWorkspace || loc.isRelative), let folder else { return loc.path }
        return folder.appendingPathComponent(loc.path).standardizedFileURL.path
    }

    /// 外部（非拷入工作区）文件入库前的路径归一化：与工作区文件夹同属一块**可移动卷**（移动硬盘等）
    /// 时改存相对路径——换电脑/换挂载点（如 `/Volumes/MyDrive` 变 `/Volumes/MyDrive 1`）仍能解析；
    /// 系统内置盘挂载点稳定，绝对路径已够可靠，故不处理（避免「只挪工作区文件夹不挪源文件」时反而失效）。
    private func externalStorage(for absolutePath: String) -> (path: String, isRelative: Bool) {
        guard let folder else { return (absolutePath, false) }
        let fileURL = URL(fileURLWithPath: absolutePath)
        guard Self.sharedRemovableVolume(folder, fileURL),
              let rel = Self.relativePath(from: folder, to: fileURL) else { return (absolutePath, false) }
        return (rel, true)
    }

    /// 两个路径是否同属一块可移动/外置卷（非系统内置盘）。
    private static func sharedRemovableVolume(_ a: URL, _ b: URL) -> Bool {
        guard let ra = try? a.resourceValues(forKeys: [.volumeURLKey, .volumeIsInternalKey]),
              let rb = try? b.resourceValues(forKeys: [.volumeURLKey]),
              let volA = ra.allValues[.volumeURLKey] as? URL,
              let volB = rb.allValues[.volumeURLKey] as? URL, volA == volB else { return false }
        return (ra.allValues[.volumeIsInternalKey] as? Bool) == false
    }

    /// 从 base（工作区文件夹）指向 target（外部文件）的相对路径，可含 `..`。两者须为绝对路径。
    private static func relativePath(from base: URL, to target: URL) -> String? {
        let baseComps = base.standardizedFileURL.pathComponents
        let targetComps = target.standardizedFileURL.pathComponents
        guard baseComps.first == "/", targetComps.first == "/" else { return nil }
        var shared = 0
        let n = min(baseComps.count, targetComps.count)
        while shared < n && baseComps[shared] == targetComps[shared] { shared += 1 }
        let combined = Array(repeating: "..", count: baseComps.count - shared) + targetComps[shared...]
        return combined.isEmpty ? nil : combined.joined(separator: "/")
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

    /// 保存进度（不 refresh，避免列表抖动；下次打开从 store 读最新）。含缩放倍率 + 横向比例。
    func saveProgress(documentId: String, page: Int, frac: Double, zoom: Double, hfrac: Double) {
        try? store?.updateProgress(documentId: documentId, page: page, frac: frac, zoom: zoom, hfrac: hfrac)
    }
    /// 读取最新进度（直接查库，绕过可能过时的 documents 缓存）。含缩放倍率 + 横向比例。
    func progress(documentId: String) -> (page: Int, frac: Double, zoom: Double, hfrac: Double) {
        if let d = try? store?.document(id: documentId) { return (d.readPage, d.readFrac, d.readZoom, d.readHFrac) }
        return (0, 0, 1, 0)
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
        let stored = externalStorage(for: path)
        if let v = try? store.variant(hash: hash) {
            _ = try? store.addLocation(variantId: v.id, path: stored.path, inWorkspace: false, isRelative: stored.isRelative)
        } else {
            _ = try? store.addVariant(documentId: documentId, hash: hash, pageCount: pageCount, path: stored.path, isRelative: stored.isRelative)
        }
        refresh()
    }

    /// 「关联为同一文档」：把 source 并入 target（多 hash 合并）。
    func mergeDocuments(sourceId: String, intoTargetId targetId: String) {
        _ = try? store?.mergeDocument(sourceId: sourceId, intoTargetId: targetId)
        forgetOpen(sourceId)   // 源文档并入 target 后离开「打开集」
        refresh()
    }

    /// 同路径内容变化（原地覆盖了 PDF）后的关联修正：把指向 absolutePath 的 location 记录从旧版本
    /// 摘除（**只删记录、不删物理文件**），再把该路径挂到实际内容 hash 对应的版本（已有版本加路径，
    /// 否则新建版本）。保留原 location 的 inWorkspace/相对路径标志——不修正的话，旧记录仍指旧 hash，
    /// 每次打开都会重复触发「内容已变化」提示。
    func rekeyLocation(documentId: String, absolutePath: String, newHash: String, pageCount: Int) {
        guard let store, !newHash.isEmpty else { return }
        let matches = ((try? store.locations(documentId: documentId)) ?? []).filter { resolvedPath($0) == absolutePath }
        guard let first = matches.first else { return }
        for l in matches { try? store.removeLocation(id: l.id) }
        if let v = try? store.variant(hash: newHash) {
            _ = try? store.addLocation(variantId: v.id, path: first.path,
                                       inWorkspace: first.inWorkspace, isRelative: first.isRelative)
        } else {
            _ = try? store.addVariant(documentId: documentId, hash: newHash, pageCount: pageCount,
                                      path: first.path, inWorkspace: first.inWorkspace, isRelative: first.isRelative)
        }
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

    // MARK: - 笔迹图层持久化（ink_layer 表，v7；挂逻辑文档，全版本共用）

    /// 读取某文档已落库的全部图层（按 sortOrder），用于重开恢复。
    func inkLayers(documentId: String) -> [InkLayer] {
        ((try? store?.inkLayers(documentId: documentId)) ?? []).map {
            InkLayer(id: UUID(uuidString: $0.id) ?? UUID(), name: $0.name, colorKey: $0.colorKey,
                     sortOrder: $0.sortOrder, visible: $0.visible)
        }
    }

    /// 落库/更新一个图层（新建/改名/改色/改可见性/重排序时调用）。
    func saveInkLayer(documentId: String, _ layer: InkLayer) {
        try? store?.upsertInkLayer(LibInkLayer(id: layer.id.uuidString, documentId: documentId,
                                                name: layer.name, colorKey: layer.colorKey,
                                                sortOrder: layer.sortOrder, visible: layer.visible,
                                                createdAt: .now))
    }

    /// 删除一个图层（连同其笔迹一起清除时，调用方需先自行删掉引用它的 strokes）。
    func deleteInkLayer(id: UUID) {
        try? store?.deleteInkLayer(id: id.uuidString)
    }

    // MARK: - 笔记类型持久化（工作区级，meta key=note_types，JSON 数组；通用不落库）

    /// 读取工作区自定义笔记类型（损坏/缺失 → 空数组；「通用」内置兜底不在其中）。
    func noteTypes() -> [NoteType] {
        guard let s = store?.meta("note_types"), let data = s.data(using: .utf8),
              let arr = try? JSONDecoder().decode([NoteType].self, from: data) else { return [] }
        return arr.filter { $0.id != NoteType.generalID }
    }

    /// 整体重写工作区自定义笔记类型（管理面板增删改后调用；自动剔除误混入的通用）。
    func saveNoteTypes(_ types: [NoteType]) {
        let filtered = types.filter { $0.id != NoteType.generalID }
        guard let data = try? JSONEncoder().encode(filtered),
              let s = String(data: data, encoding: .utf8) else { return }
        try? store?.setMeta("note_types", s)
    }

    // MARK: - 文字注解持久化（note kind=0；挂逻辑文档，全版本共用）

    /// 读取某文档已落库的全部文字注解（按页 / 页内位置序），用于重开恢复。
    func textNotes(documentId: String) -> [TextNote] {
        ((try? store?.notes(documentId: documentId)) ?? [])
            .compactMap { $0.kind == TextNote.noteKind ? TextNote(note: $0) : nil }
            .sorted { $0.page != $1.page ? $0.page < $1.page : $0.anchor.minY < $1.anchor.minY }
    }

    /// 落库/更新一条文字注解（新建或编辑时调用）。
    func saveTextNote(documentId: String, _ note: TextNote) {
        guard let store, let n = note.toNote(documentId: documentId) else { return }
        try? store.upsertNote(n)
    }

    /// 删除一条文字注解（note.id == TextNote.id）。
    func deleteTextNote(id: UUID) {
        try? store?.deleteNote(id: id.uuidString)
    }

    // MARK: - 文字高亮持久化（note kind=3；挂逻辑文档，全版本共用）

    /// 读取某文档已落库的全部高亮（按页 / 页内位置序），用于重开恢复。
    func highlights(documentId: String) -> [Highlight] {
        ((try? store?.notes(documentId: documentId)) ?? [])
            .compactMap { $0.kind == Highlight.noteKind ? Highlight(note: $0) : nil }
            .sorted { $0.page != $1.page ? $0.page < $1.page : $0.anchor.minY < $1.anchor.minY }
    }

    /// 落库/更新一条高亮（新建或改色时调用）。
    func saveHighlight(documentId: String, _ h: Highlight) {
        guard let store, let n = h.toNote(documentId: documentId) else { return }
        try? store.upsertNote(n)
    }

    /// 删除一条高亮（note.id == Highlight.id）。
    func deleteHighlight(id: UUID) {
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
