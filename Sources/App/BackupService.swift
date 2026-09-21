import Foundation
import AppKit

/// 工作区资料库的定时备份（方案 `BACKUP-PLAN.md §3`）。
///
/// **只备份 `library.sqlite`**：笔迹、文字笔记、高亮、书签、草稿纸、OCR 缓存、对齐参数全都在里面，
/// 一份库就是全部心血；PDF 几十 GB 且 App 从不修改它，`Images/` 与 `Notes/` 是普通文件。
/// 要整份留档有现成的「离线镜像」。
///
/// 快照走 `checkpointTruncate()` + `VACUUM INTO`（理由见 `LibraryStore` 那两个方法的注释：
/// 一个读事务里生成、天生一致、顺带压缩、不必停写；`cp` 那三个文件不是原子的）。
/// 写入是「临时名 → `rename`」：半截文件不能被当成一份有效备份。
final class BackupService {
    static let shared = BackupService()
    private init() {}

    // MARK: - 设置（本机，跨工作区共用）

    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: "backupEnabled") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "backupEnabled"); reschedule() }
    }

    /// 定时间隔，小时。界面上给 1 / 6 / 12 / 24。
    static var intervalHours: Int {
        get { UserDefaults.standard.object(forKey: "backupIntervalHours") as? Int ?? 6 }
        set { UserDefaults.standard.set(max(1, newValue), forKey: "backupIntervalHours"); reschedule() }
    }

    /// 设置变了 → 按新设置重建定时器（设置页可能在任何线程改，统一推回主线程）。
    private static func reschedule() {
        DispatchQueue.main.async { MainActor.assumeIsolated { shared.restartTimer() } }
    }

    /// 节流：距最近一份备份不足这么久就跳过。手动「立即备份」不受它限制。
    /// 拿备份文件**自己的时间戳**判断，不另存状态——少一处能和现实不一致的记录。
    static let throttle: TimeInterval = 30 * 60

    // MARK: - 文件（命名与解析在 `BackupFile`，那是能离屏测的纯文件）

    static func folder(in workspace: URL) -> URL { BackupFile.folder(in: workspace) }

    struct Item: Identifiable, Equatable {
        var id: String { url.lastPathComponent }
        var url: URL
        var date: Date
        var bytes: Int64
        /// 还原前自动留的那一份。**永不参与保留策略的稀释**——它是「还原按错了」的唯一退路。
        var isRestorePoint: Bool
    }

    /// 列出备份，**最近的排最前**。命名对不上的文件一律忽略（用户自己放进去的东西不碰、也不删）。
    static func items(in workspace: URL) -> [Item] {
        let fm = FileManager.default
        let dir = folder(in: workspace)
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return [] }
        var out: [Item] = []
        for n in names {
            guard let parsed = BackupFile.parse(n) else { continue }
            let url = dir.appendingPathComponent(n)
            let bytes = ((try? fm.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0
            out.append(Item(url: url, date: parsed.date, bytes: bytes, isRestorePoint: parsed.isRestorePoint))
        }
        return out.sorted { $0.date > $1.date }
    }

    // MARK: - 跑一次

    enum Outcome {
        case done(URL)
        case skippedThrottled    // 距上次不足 30 分钟
        case skippedDisabled
        case failed(Error)
    }

    /// 给一个工作区做一份快照。**在后台线程调**（慢卷上是秒级）。
    /// `force` = 手动「立即备份」，跳过节流与总开关。
    @discardableResult
    func run(folder: URL, store: LibraryStore, force: Bool, now: Date = .now) -> Outcome {
        if !force {
            guard Self.enabled else { return .skippedDisabled }
            if let last = Self.items(in: folder).first(where: { !$0.isRestorePoint }),
               now.timeIntervalSince(last.date) < Self.throttle { return .skippedThrottled }
        }
        let fm = FileManager.default
        let dir = Self.folder(in: folder)
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let target = dir.appendingPathComponent(BackupFile.name(at: now))
            guard !fm.fileExists(atPath: target.path) else { return .skippedThrottled }   // 同一秒里来过了
            let tmp = dir.appendingPathComponent(".\(UUID().uuidString).tmp")
            store.checkpointTruncate()
            try store.vacuumInto(tmp.path)
            try fm.moveItem(at: tmp, to: target)
            wsLog("[BACKUP] \(folder.lastPathComponent) → \(target.lastPathComponent)")
            prune(in: folder, now: now)
            return .done(target)
        } catch {
            wsLog("[BACKUP] ⚠️ 备份失败 \(folder.lastPathComponent)：\(error)")
            return .failed(error)
        }
    }

    /// 按保留策略删多余的（还原点不参与）。
    func prune(in workspace: URL, now: Date = .now) {
        let all = Self.items(in: workspace).filter { !$0.isRestorePoint }
        let plan = BackupRetention.plan(all.map(\.date), now: now)
        for i in plan.drop {
            try? FileManager.default.removeItem(at: all[i].url)
            wsLog("[BACKUP] 稀释掉 \(all[i].url.lastPathComponent)")
        }
    }

    // MARK: - 调度

    private var timer: Timer?
    /// 打开工作区后那一次的延迟（别和开窗抢那几秒）。
    private let openDelay: TimeInterval = 8

    /// 打开工作区时排一次（`WorkspaceManager.open` 末尾调）。顺带把定时器拉起来。
    @MainActor
    func scheduleOpenBackup(for manager: WorkspaceManager) {
        restartTimer()
        guard Self.enabled else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + openDelay) { [weak manager] in
            guard let manager else { return }
            self.runInBackground(manager, force: false)
        }
    }

    /// 定时器：按当前设置重建。设置变了也走这里。
    @MainActor
    func restartTimer() {
        timer?.invalidate()
        timer = nil
        guard Self.enabled else { return }
        let t = Timer(timeInterval: Double(Self.intervalHours) * 3600, repeats: true) { [weak self] _ in
            DispatchQueue.main.async { self?.tick() }
        }
        t.tolerance = 300   // 五分钟游移：这事一秒都不急，别把系统从空闲里叫醒
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    @MainActor
    private func tick() {
        for m in WorkspaceRegistry.shared.openManagers { runInBackground(m, force: false) }
    }

    /// 退出前同步跑一次（`applicationShouldTerminate`）。节流照旧生效，
    /// 所以频繁开关 app 不会每次都写一份几十 MB。
    @MainActor
    func backupBeforeQuit() {
        guard Self.enabled else { return }
        for m in WorkspaceRegistry.shared.openManagers {
            guard let folder = m.folder, let store = m.store else { continue }
            _ = run(folder: folder, store: store, force: false)
        }
    }

    /// 后台跑一个工作区。`store` / `folder` 在主线程取，之后只碰它们两个
    /// （`SQLiteDB` 按语句加锁，与主线程的读写互不干扰——同 `MirrorBuilder` 的用法）。
    @MainActor
    func runInBackground(_ manager: WorkspaceManager, force: Bool, done: ((Outcome) -> Void)? = nil) {
        guard let folder = manager.folder, let store = manager.store else {
            done?(.skippedDisabled)
            return
        }
        DispatchQueue.global(qos: .utility).async {
            let out = self.run(folder: folder, store: store, force: force)
            if let done { DispatchQueue.main.async { done(out) } }
        }
    }

    // MARK: - 还原

    enum RestoreError: LocalizedError {
        case noWorkspace
        case missing

        var errorDescription: String? {
            switch self {
            case .noWorkspace: return L("This workspace is not open.")
            case .missing: return L("That backup file is gone.")
            }
        }
    }

    /// 还原：先留还原点 → 关连接 → 换文件 → 退出 App（方案 §3.4）。
    ///
    /// 🔴 **退出而不是原地重开**：库连接、打开的标签页、笔迹的按页窗口、笔架、草稿纸、Agent 面板
    /// 全挂在「当前这个 store 实例」上，原地换库等于要求每一处都正确地丢弃并重建状态。
    /// 这个功能一年用不上一次，用退出换一条不会出错的路。
    @MainActor
    func restore(_ item: Item, into manager: WorkspaceManager) throws {
        guard let folder = manager.folder, let store = manager.store else { throw RestoreError.noWorkspace }
        let fm = FileManager.default
        guard fm.fileExists(atPath: item.url.path) else { throw RestoreError.missing }

        // ① 还原点（当前这份库），永不被稀释
        let dir = Self.folder(in: folder)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let point = dir.appendingPathComponent(BackupFile.name(at: .now, restorePoint: true))
        store.checkpointTruncate()
        if !fm.fileExists(atPath: point.path) { try store.vacuumInto(point.path) }

        // ② 关连接（之后这个 manager 的所有写都退化成 no-op）
        let dbURL = store.fileURL
        manager.teardown()

        // ③ 换文件。`-wal` / `-shm` 必须一起删：留着的话 SQLite 会拿旧 WAL 去「恢复」新库。
        for side in ["", "-wal", "-shm"] {
            try? fm.removeItem(atPath: dbURL.path + side)
        }
        try fm.copyItem(at: item.url, to: dbURL)
        wsLog("[BACKUP] 已还原 \(folder.lastPathComponent) ← \(item.url.lastPathComponent)，还原点 \(point.lastPathComponent)")

        // ④ 退出
        NSApp.terminate(nil)
    }
}
