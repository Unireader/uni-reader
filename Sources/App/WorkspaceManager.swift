import Foundation
import PDFKit
import AppKit

/// **一个实例 = 一个工作区**，持有它的 `LibraryStore`（跨平台 SQLite 单库）。
/// 工作区 = 一个可移动的 `.unrd` 包（UTI 声明见 `Sources/Info.plist`）；配置与笔记都存包内 `UniReader/library.sqlite`。
/// 旧无扩展名工作区首次打开时原地改名迁移为 `<工作区名>.unrd`（`migrateToPackageIfNeeded`）。
/// 主线程使用。
///
/// ⚠️ **实例一旦建好就绑定那个工作区，不再切换**（2026-07-29 改）：以前这是个 App 级单例、
/// 靠换 `folder` 来切工作区，于是双击另一个 `.unrd` 会把**所有**窗口一起换掉。现在多工作区
/// 并存靠「多个实例各绑一个窗口」，实例由 [`WorkspaceRegistry`] 按路径分配并保证同路径同实例
/// （同一个库开两个连接会丢笔记，理由见那里的注释）。「最近工作区/上次工作区」是本机全局状态，
/// 也搬去了 registry。
@MainActor
final class WorkspaceManager: ObservableObject {
    @Published private(set) var folder: URL?
    @Published private(set) var name: String = ""
    @Published private(set) var documents: [LibDocument] = []
    @Published var lastError: String?
    private(set) var restoreDocIds: [String] = []   // 「上次打开集」快照，供本工作区的多窗口恢复（restoreSession 读一次进本地）
    private var windowDocs: [UUID: String] = [:]     // 本工作区各窗口当前文档（sessionId → docId）——「打开集」的真相源
    private var openDocs: [String] = []              // 当前打开的文档集（= 本工作区所有窗口当前文档，去重保序）；持久化供下次恢复

    private(set) var store: LibraryStore?

    /// 打开一个工作区；文件夹是空的就在里面建库（首次启动引导、`createWorkspace` 都依赖这点）。
    /// ⚠️ 因此**不要拿用户随手选的路径直接调它**——那会把一个无关空文件夹静默变成新工作区，
    /// 用户以为「打开」了旧工作区、看到的却是空白库。用户侧入口先过 `validate(_:)`。
    /// 一律经 `WorkspaceRegistry.acquire` 创建，别自己 new（同路径必须同实例，见 registry 注释）。
    init(folder: URL) throws {
        try open(folder: folder)
    }

    /// 新建工作区：在 `url` 处创建全新 `.unrd` 包（建目录 + 建库，建完即是「真实工作区」）。
    /// 与「打开」严格分离的专用入口。
    ///
    /// ⚠️ **目标若已经是一个真实工作区就拒绝**，哪怕保存面板已弹过系统「替换」确认：那句确认在用户
    /// 眼里是「替换一个文件」，实际却会连同笔记整库删掉；多窗口之后它还可能正被另一个窗口开着
    /// （SQLite 连接活着、目录被抽走 → 僵尸窗口）。已存在但不是工作区（同名普通文件/文件夹）才按
    /// 面板确认过的语义覆盖。
    ///
    /// 这里**不建 manager**：实例一律由 `WorkspaceRegistry.acquire` 在新窗口里分配（同路径同实例）。
    /// 临时 `LibraryStore` 只为把库建出来，出了作用域即关闭连接。
    static func createWorkspace(at url: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) {
            guard !hasLibrary(url) else { throw OpenError.alreadyAWorkspace }
            try fm.removeItem(at: url)
        }
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        _ = try LibraryStore(workspaceFolder: url)
    }

    /// 首次无工作区时的默认：应用支持目录下的 DefaultWorkspace.unrd（包）。
    static func defaultFolder() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("UniReader", isDirectory: true)
            .appendingPathComponent("DefaultWorkspace.\(packageExtension)", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    // MARK: - .unrd 包（工作区 = package，双击不展开、交给 App 打开）

    /// 包扩展名（UTI 声明见 Sources/Info.plist：tech.xvanturing.unireader.workspace）。
    static let packageExtension = "unrd"

    /// 打开前把旧式（无 .unrd 扩展名）工作区**原地改名**为 `<工作区名>.unrd`，返回实际要打开的 URL。
    /// 只动文件夹名、不动内容，旧数据零风险；工作区内的相对路径 location 不受影响。
    /// 迁移对象：含 `UniReader/library.sqlite` 的旧工作区、或用户新选的空文件夹；
    /// 其余非空文件夹（用户随手指的）不擅自改名，照常在其中建库（显示为普通文件夹）。
    private func migrateToPackageIfNeeded(_ folder: URL) -> URL {
        guard folder.pathExtension != Self.packageExtension else { return folder }
        let fm = FileManager.default
        let isWorkspace = fm.fileExists(atPath: folder.appendingPathComponent("UniReader/library.sqlite").path)
        let isEmpty = ((try? fm.contentsOfDirectory(atPath: folder.path)) ?? ["."]).isEmpty
        guard isWorkspace || isEmpty else { return folder }
        let name = Self.sanitizedPackageName(
            LibraryStore.peekWorkspaceName(folder: folder) ?? folder.lastPathComponent,
            fallback: folder.lastPathComponent)
        guard let target = Self.availablePackageURL(beside: folder, name: name) else { return folder }
        do {
            try fm.moveItem(at: folder, to: target)
            WorkspaceRegistry.shared.replaceRecent(old: folder, new: target)
            return target
        } catch {
            lastError = "\(error)"
            return folder
        }
    }

    /// 包名净化：路径分隔符（`/`、`:`）换 `-`，去首尾空白；空了用兜底。
    static func sanitizedPackageName(_ name: String, fallback: String) -> String {
        let s = name.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? fallback : s
    }

    /// 同级目录下不冲突的 `<name>.unrd` URL：冲突时依次回退「文件夹原名.unrd」、`<name>-2.unrd`…
    private static func availablePackageURL(beside folder: URL, name: String) -> URL? {
        let dir = folder.deletingLastPathComponent()
        let primary = "\(name).\(packageExtension)"
        let folderBased = "\(folder.lastPathComponent).\(packageExtension)"
        for c in folderBased == primary ? [primary] : [primary, folderBased] {
            let url = dir.appendingPathComponent(c)
            if !FileManager.default.fileExists(atPath: url.path) { return url }
        }
        for i in 2...99 {
            let url = dir.appendingPathComponent("\(name)-\(i).\(packageExtension)")
            if !FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return nil
    }

    /// 工作区默认显示名（建库后 workspace_name 为空时用）：包则去 .unrd 后缀。
    static func defaultWorkspaceName(for folder: URL) -> String {
        folder.pathExtension == packageExtension
            ? folder.deletingPathExtension().lastPathComponent
            : folder.lastPathComponent
    }

    /// 「打开工作区」严格校验失败原因（供 UI 提示；不静默建空库）。
    enum OpenError: LocalizedError {
        case notFound            // 路径不存在，或存在但不是文件夹
        case notAWorkspace       // 是文件夹，但不含 UniReader/library.sqlite——不是真实工作区
        case alreadyAWorkspace   // 「新建」的目标已经是一个真实工作区——不覆盖（会连笔记一起删）

        var errorDescription: String? {
            switch self {
            case .notFound: return L("The selected item does not exist.")
            case .notAWorkspace: return L("This folder is not a UniReader workspace (no UniReader/library.sqlite inside).")
            case .alreadyAWorkspace: return L("A workspace with this name already exists here. Open it instead, or choose another name.")
            }
        }
    }

    /// 该文件夹（原始路径，改名迁移前）是否已是真实工作区：含 `UniReader/library.sqlite`。
    static func hasLibrary(_ folder: URL) -> Bool {
        FileManager.default.fileExists(atPath: folder.appendingPathComponent("UniReader/library.sqlite").path)
    }

    /// 严格校验一个「打开工作区」目标：必须是**已存在的真实工作区**。
    /// 只查文件系统、**不建实例** —— 「打开」入口要在开窗口之前先验一遍，免得开出一个只会报错的空窗口；
    /// 用 `acquire` 来验则会白建一次 `LibraryStore`，且遇上旧式工作区原地改名后路径对不上还会漏释放。
    static func validate(_ folder: URL) throws {
        var d: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &d), d.boolValue else {
            throw OpenError.notFound
        }
        guard hasLibrary(folder) else { throw OpenError.notAWorkspace }
    }

    /// 真正打开（只在 `init` 里调用一次——实例与工作区一一绑定，见类型注释）。
    private func open(folder: URL) throws {
        let folder = migrateToPackageIfNeeded(folder)
        let store = try LibraryStore(workspaceFolder: folder)
        if store.workspaceName.isEmpty { try? store.setWorkspaceName(Self.defaultWorkspaceName(for: folder)) }
        self.store = store
        self.folder = folder
        self.name = store.workspaceName
        openDocs = store.openDocuments()         // 上次「打开集」（本工作区所有窗口的文档）
        restoreDocIds = openDocs                 // 启动快照：restoreSession 只读它一次进本地，之后随窗口重同步无碍
        windowDocs = [:]
        refresh()
        lastError = nil
    }

    /// **彻底放手这个工作区**：关掉 SQLite 连接并置空 `store`，之后所有读写自动退化成 no-op。
    /// 由 `WorkspaceRegistry.maybeTeardown` 在「本工作区已无窗口 + 关窗时的最后一次写库已落地」时调用。
    ///
    /// ⚠️ **不能只依赖 `deinit`**：实例的强引用在 `RootView` 的 `@State` 里，SwiftUI 关窗后何时释放
    /// 它没有保证；只要 `library.sqlite` 的 fd 还开着，工作区所在的**可移动硬盘就弹不出去**
    /// （用户 2026-08-05 报：必须退出整个 app 才能弹）。所以关闭必须是一个显式动作，而不是 ARC 的副产品。
    func teardown() {
        guard store != nil else { return }
        store?.close()
        store = nil
        wsLog("teardown：已关闭库连接 \(folder?.lastPathComponent ?? "?")")
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
        syncPackageName()
    }

    /// 保持「文件夹名 == 工作区名.unrd」不变式：工作区改名后联动原地改包名。
    /// SQLite 连接基于 fd，同目录 rename 不影响已打开的连接；改名失败不阻断（仅记 lastError）。
    private func syncPackageName() {
        guard let folder, folder.pathExtension == Self.packageExtension else { return }
        let current = folder.deletingPathExtension().lastPathComponent
        let target = Self.sanitizedPackageName(name, fallback: current)
        guard target != current, let url = Self.availablePackageURL(beside: folder, name: target) else { return }
        do {
            try FileManager.default.moveItem(at: folder, to: url)
            WorkspaceRegistry.shared.replaceRecent(old: folder, new: url)   // 连带更新池的键与「上次工作区」
            self.folder = url
        } catch { lastError = "\(error)" }
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

    // MARK: - 分组（v11：工作区内一级分组）

    /// 当前存在的分组名（按名字排序；未分组不在内）。从 documents 派生，不单独存。
    var groups: [String] {
        Array(Set(documents.map(\.group).filter { !$0.isEmpty })).sorted()
    }
    /// 移动文档到分组（空串 = 未分组）。
    func setGroup(documentId: String, group: String) {
        setGroup(ids: [documentId], group: group)
    }
    /// 批量移动（侧栏多选/拖拽）；一次 refresh。
    func setGroup(ids: some Collection<String>, group: String) {
        let g = group.trimmingCharacters(in: .whitespacesAndNewlines)
        for id in ids { try? store?.setGroup(documentId: id, group: g) }
        refresh()
    }
    /// 整组改名；空串 = 解散该组（文档回未分组）。
    func renameGroup(from: String, to: String) {
        let t = to.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !from.isEmpty, t != from else { return }
        try? store?.renameGroup(from: from, to: t)
        refresh()
    }

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

    /// 参考窗（`/page.png?d=` 与 `/docmeta?d=`）要的**纯查询**索引：库文档 id → 路径/哈希/标题/进度。
    ///
    /// 🔴 **不能用 `openTarget`**：那个会写库（`updateLastOpened` / `setLocationValidity`），
    /// 对整个书库批量调用等于每次同步都把「最近打开」全刷一遍。这里只读，文件在不在留给
    /// 渲染时 `PDFDocument(url:)` 失败去报 404。
    ///
    /// 调用方是主线程（`WorkspaceManager` 是 `@MainActor`，而服务 queue 够不着它）——
    /// 结果由 `DocSession` 捎带成快照，同 `libraryDocs` 的既有办法。
    func refDocIndex() -> [String: RefDocInfo] {
        guard let store else { return [:] }
        var out: [String: RefDocInfo] = [:]
        for d in documents {
            var locs = (try? store.locations(documentId: d.id)) ?? []
            locs.sort { $0.inWorkspace && !$1.inWorkspace }   // 工作区副本优先（同 openTarget）
            guard let loc = locs.first else { continue }
            let hash = (try? store.variant(id: loc.variantId))?.contentHash ?? ""
            out[d.id] = RefDocInfo(path: resolvedPath(loc), hash: hash, title: d.title,
                                   pageCount: d.pageCount, readPage: d.readPage, readFrac: d.readFrac)
        }
        return out
    }

    // MARK: - 阅读进度

    /// 保存进度（不 refresh，避免列表抖动；下次打开从 store 读最新）。含缩放倍率 + 横向比例。
    func saveProgress(documentId: String, page: Int, frac: Double, zoom: Double, hfrac: Double) {
        try? store?.updateProgress(documentId: documentId, page: page, frac: frac, zoom: zoom, hfrac: hfrac)
    }
    /// 读取最新进度（直接查库，绕过可能过时的 documents 缓存）。含缩放倍率 + 横向比例 + 画板模式。
    func progress(documentId: String) -> (page: Int, frac: Double, zoom: Double, hfrac: Double, canvas: Bool) {
        if let d = try? store?.document(id: documentId) {
            return (d.readPage, d.readFrac, d.readZoom, d.readHFrac, d.canvasMode)
        }
        return (0, 0, 1, 0, false)
    }

    /// 画板模式开关（v12，逐文档）。切换即时落库——它不像滚动位置那样每帧都变，没有节流的必要。
    func setCanvasMode(documentId: String, on: Bool) {
        try? store?.setCanvasMode(documentId: documentId, on: on)
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

    /// 在访达中打开当前工作区所在目录（选中 .unrd 包本身）。
    func revealWorkspaceInFinder() {
        guard let folder else { return }
        NSWorkspace.shared.activateFileViewerSelecting([folder])
    }

    func variants(documentId: String) -> [LibVariant] { (try? store?.variants(documentId: documentId)) ?? [] }
    func locations(documentId: String) -> [LibLocation] { (try? store?.locations(documentId: documentId)) ?? [] }
    func notes(documentId: String) -> [LibNote] { (try? store?.notes(documentId: documentId)) ?? [] }

    // MARK: - 手写笔迹持久化（note kind=2；挂逻辑文档，全版本共用）

    /// 读取某文档已落库的全部手写笔画（按页/时间序），用于重开恢复。
    func inkStrokes(documentId: String) -> [InkStroke] {
        ((try? store?.notes(documentId: documentId, kind: InkStroke.noteKind)) ?? [])
            .compactMap(InkStroke.init(note:))
    }

    /// 落库/更新一条手写笔画（笔画完成时调用）。空笔画自动跳过。
    func saveInkStroke(documentId: String, _ stroke: InkStroke) {
        guard let store, let note = stroke.toNote(documentId: documentId) else { return }
        try? store.upsertNote(note)
    }

    /// 删除一条手写笔画（擦除时调用；note.id == stroke.id）。草稿纸笔迹同走这里（同在 note 表）。
    func deleteInkStroke(id: UUID) {
        try? store?.deleteNote(id: id.uuidString)
    }

    // MARK: - 草稿纸持久化（scratch_pad 表 + note kind=4，v8；挂逻辑文档，全版本共用）

    /// 读取某文档的全部草稿纸（按创建序）。
    func scratchPads(documentId: String) -> [ScratchPad] {
        ((try? store?.scratchPads(documentId: documentId)) ?? []).map(ScratchPad.init(row:))
    }

    /// 落库/更新一张草稿纸（新建/改名/改底色）。
    func saveScratchPad(documentId: String, _ pad: ScratchPad) {
        try? store?.upsertScratchPad(pad.toRow(documentId: documentId))
    }

    /// 删除一张草稿纸（纸上的笔迹由调用方同时从 `scratchStrokes` 移除，走对账删除）。
    func deleteScratchPad(id: UUID) {
        try? store?.deleteScratchPad(id: id.uuidString)
    }

    /// 读取某文档全部草稿纸上的笔迹（含所有纸；点集是画布坐标）。用 `saveInkStroke`/`deleteInkStroke` 写。
    func scratchStrokes(documentId: String) -> [InkStroke] {
        ((try? store?.notes(documentId: documentId, kind: InkStroke.scratchNoteKind)) ?? [])
            .compactMap(InkStroke.init(note:))
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
        ((try? store?.notes(documentId: documentId, kind: TextNote.noteKind)) ?? [])
            .compactMap(TextNote.init(note:))
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
        ((try? store?.notes(documentId: documentId, kind: Highlight.noteKind)) ?? [])
            .compactMap(Highlight.init(note:))
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

    // MARK: - AI 会话绑定持久化（note kind=1；挂逻辑文档，全版本共用）

    /// 读取某文档已落库的全部 AI 会话绑定（按页 / 页内位置序），用于重开恢复。
    func aiThreads(documentId: String) -> [AIThread] {
        ((try? store?.notes(documentId: documentId, kind: AIThread.noteKind)) ?? [])
            .compactMap(AIThread.init(note:))
            .sorted { $0.page != $1.page ? $0.page < $1.page : $0.createdAt < $1.createdAt }
    }

    /// 落库/更新一条 AI 会话绑定。
    func saveAIThread(documentId: String, _ t: AIThread) {
        guard let store, let n = t.toNote(documentId: documentId) else { return }
        try? store.upsertNote(n)
    }

    /// 删除一条 AI 会话绑定（note.id == AIThread.id）。**只解绑，不动平台上那个对话。**
    func deleteAIThread(id: UUID) {
        try? store?.deleteNote(id: id.uuidString)
    }
}
