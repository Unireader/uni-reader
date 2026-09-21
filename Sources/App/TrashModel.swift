import Foundation

/// 回收站的**纯 Foundation** 一侧（方案 `BACKUP-PLAN.md §2`）：条目的身份、manifest 的编解码、
/// 目录扫描、到期判定、目录名生成。不碰 SQLite、不碰 UI，可离屏测（`spike/trash-test.swift`）。
///
/// 一条条目 = `<工作区>/UniReader/Trash/<目录名>/` 下的两个文件：
/// `snapshot.sqlite`（被删的那些行，见 `TrashStore`）+ `manifest.json`（下面这个结构）。
enum Trash {

    /// 回收站在工作区里的位置。
    static let dirName = "Trash"
    static let manifestName = "manifest.json"
    static let snapshotName = "snapshot.sqlite"

    static func folder(in workspace: URL) -> URL {
        workspace.appendingPathComponent("UniReader/\(dirName)", isDirectory: true)
    }

    // MARK: - 条目

    enum Kind: String, Codable {
        case document   // 整篇文档
        case inkLayer   // 一个笔迹图层
    }

    /// `manifest.json` 的内容。**新增字段一律给默认值**：老条目的 manifest 少字段也要读得出来，
    /// 读不出来的条目在界面上就是「凭空消失的一条回收站记录」——那正是这个功能要防的事。
    struct Manifest: Codable, Equatable {
        var v = 1
        var kind: Kind = .document
        var deletedAt: Date = .now
        /// 条目显示名（文档级 = 文档标题；图层级 = 图层名）。
        var title = ""
        var documentId = ""
        /// 所属文档的标题（图层级条目要显示「《高等数学》的图层 2」）。
        var documentTitle = ""
        var layerId: String?
        var pageCount = 0
        var counts = TrashStore.Counts()
        /// 引用到的图片本体 sha256 —— 清理图片时要护住它们（方案 §2.6）。
        var images: [String] = []
        /// 各版本的 PDF 内容 hash —— 恢复时认「这份 PDF 是不是又被导入过」（方案 §2.5）。
        var contentHashes: [String] = []
    }

    /// 扫描出来的一条（manifest + 落盘信息）。
    struct Entry: Identifiable, Equatable {
        /// 条目目录名，**就是它的身份**（同一时刻不会有两条同名，见 `directoryName`）。
        var id: String
        var url: URL
        var manifest: Manifest
        /// 整个条目目录占多少字节（主要是 snapshot.sqlite）。
        var bytes: Int64

        var snapshotURL: URL { url.appendingPathComponent(snapshotName) }
        var deletedAt: Date { manifest.deletedAt }
    }

    // MARK: - 编解码

    private static func coder() -> (JSONEncoder, JSONDecoder) {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return (e, d)
    }

    /// 时间戳**写进去之前就抹到整秒**。manifest 是给人看的 JSON（ISO8601，没有小数位），
    /// 不抹的话「存进去的」和「读回来的」差几百毫秒，编解码回环就不相等了 ——
    /// 这种对不上的地方不留着，将来拿它当键或去重时才不会出事。
    static func encode(_ m: Manifest) throws -> Data {
        var m = m
        m.deletedAt = Date(timeIntervalSince1970: m.deletedAt.timeIntervalSince1970.rounded(.down))
        return try coder().0.encode(m)
    }
    static func decode(_ data: Data) throws -> Manifest { try coder().1.decode(Manifest.self, from: data) }

    // MARK: - 目录名

    /// `2026-09-21T14-03-11_高等数学`。可读是为了在 Finder 里认得出来；
    /// **程序一律读 manifest，不解析目录名**（标题里什么字符都可能有）。
    /// 已存在就加 `-2`、`-3`…（同一秒删两篇是常事：侧栏多选删除就是）。
    static func directoryName(at date: Date, title: String, existing: Set<String>) -> String {
        let stamp = stampFormatter.string(from: date)
        let safe = sanitize(title)
        let base = safe.isEmpty ? stamp : "\(stamp)_\(safe)"
        guard existing.contains(base) else { return base }
        var n = 2
        while existing.contains("\(base)-\(n)") { n += 1 }
        return "\(base)-\(n)"
    }

    /// 文件名净化：路径分隔符与前导点去掉，压到 40 个字符以内（HFS+ 的 255 字节上限对中文只有 85 字）。
    static func sanitize(_ title: String) -> String {
        var s = title
        for bad in ["/", ":", "\\", "\0", "\n", "\r"] { s = s.replacingOccurrences(of: bad, with: "-") }
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasPrefix(".") { s.removeFirst() }
        return String(s.prefix(40))
    }

    private static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd'T'HH-mm-ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    // MARK: - 扫描

    /// 扫出全部条目，**最近删的排最前**。
    ///
    /// 读不出 manifest 的目录：不静默跳过，按「未知条目」列出来（`title` 用目录名），
    /// 用户至少看得见它占着地方、能手动清掉。只有连 `snapshot.sqlite` 都没有的才算废目录、忽略。
    static func scan(in workspace: URL) -> [Entry] {
        let fm = FileManager.default
        let root = folder(in: workspace)
        guard let names = try? fm.contentsOfDirectory(atPath: root.path) else { return [] }
        var out: [Entry] = []
        for name in names where !name.hasPrefix(".") {
            let dir = root.appendingPathComponent(name, isDirectory: true)
            guard fm.fileExists(atPath: dir.appendingPathComponent(snapshotName).path) else { continue }
            let manifest: Manifest
            if let data = try? Data(contentsOf: dir.appendingPathComponent(manifestName)),
               let m = try? decode(data) {
                manifest = m
            } else {
                var m = Manifest()
                m.title = name
                m.deletedAt = (try? fm.attributesOfItem(atPath: dir.path))?[.creationDate] as? Date ?? .distantPast
                manifest = m
            }
            out.append(Entry(id: name, url: dir, manifest: manifest, bytes: directorySize(dir)))
        }
        return out.sorted { $0.deletedAt > $1.deletedAt }
    }

    static func directorySize(_ dir: URL) -> Int64 {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return 0 }
        return names.reduce(0) { sum, n in
            let a = try? fm.attributesOfItem(atPath: dir.appendingPathComponent(n).path)
            return sum + ((a?[.size] as? NSNumber)?.int64Value ?? 0)
        }
    }

    // MARK: - 到期

    /// 保留期。`nil` = 永不自动清除。
    enum Retention: Int, CaseIterable {
        case days30 = 30, days90 = 90, forever = 0

        var days: Int? { self == .forever ? nil : rawValue }
    }

    /// 到期该清掉的那些条目（纯函数，便于离屏测）。`forever` 一条都不返回。
    static func expired(_ entries: [Entry], retention: Retention, now: Date = .now) -> [Entry] {
        guard let days = retention.days else { return [] }
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
        return entries.filter { $0.deletedAt < cutoff }
    }
}
