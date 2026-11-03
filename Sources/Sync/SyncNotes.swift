import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// `Notes/` 里文件的同步（Markdown 正文 + 附件）——App 与服务器共用的那一半
/// （方案 `SERVER-MODE-PLAN.md §4.4 / §13.12`，线格式 `PROTOCOL.md §9.5`）。
///
/// 与库里的行不同，笔记是**文件**，按文件整份同步：每个文件在服务器上有一个修订号（每个文件一个、互不相同），
/// 推送带「我上次同步时看到的修订号」（基线），对不上就不收（`stale`），由客户端另存冲突副本。
/// 🔴 正文一个字不改（红线⑨）：冲突时两份都留，谁也不覆盖谁的字节。
///
/// 只许 Foundation + Crypto：服务器在 Linux 上也编它。
enum SyncNotes {

    static let folderName = "Notes"
    static let prefix = "Notes/"
    /// 引用的外部笔记目录在服务器上的镜像（`MARKDOWN-NOTES-PLAN.md §11`）：`NotesMirror/<源 id>/…`。
    /// 与内建的 `Notes/` 分开放，免得混在一起；传输规则完全一样，只是「谁是真源」不同（在客户端判断）。
    static let mirrorFolderName = "NotesMirror"
    static let mirrorPrefix = "NotesMirror/"
    /// 同步的两个根目录。
    static let roots = [folderName, mirrorFolderName]

    static func mirrorPrefix(source id: String) -> String { "\(mirrorPrefix)\(id)/" }
    static func isMirrorPath(_ p: String) -> Bool { p.hasPrefix(mirrorPrefix) }
    /// 单个文件的上限：再大的（几乎只会是误放进来的视频 / 安装包）不同步，也不当成「被删了」。
    static let maxFileBytes: Int64 = 100 * 1024 * 1024

    // MARK: - 线格式（JSON）

    /// 服务器上一个文件的现状。`deleted` = 墓碑（文件被删了，修订号照样往前走，别的设备凭它知道该删）。
    struct Entry: Codable, Equatable, Sendable {
        var path: String        // 工作区内相对路径，如 `Notes/数学/极限.md`
        var rev: UInt64
        var sha256: String      // 墓碑为空串
        var size: Int64
        var deleted: Bool
    }

    struct ListResponse: Codable, Equatable, Sendable {
        var head: UInt64
        var files: [Entry]
    }

    /// 响应头：这个文件现在的修订号（`PUT` / `DELETE` 的所有结果都带，包括 409）。
    static let revHeader = "X-UniReader-Rev"

    // MARK: - 路径

    /// 能同步的路径：`Notes/…` 或 `NotesMirror/<源 id>/…` 下的普通文件，任何一级名字都不以 `.` 开头（`.obsidian`、`.trash`、`.DS_Store`），
    /// 也不叫 `trash`（Mac 的笔记扫描 `MarkdownImport.walk` 同样跳过它），不以 `.part` 结尾（写到一半的临时文件）。
    static func isSyncablePath(_ p: String) -> Bool {
        let mirror = isMirrorPath(p)
        guard mirror || p.hasPrefix(prefix), !p.hasSuffix(".part"), !p.contains("\0") else { return false }
        let comps = p.split(separator: "/", omittingEmptySubsequences: false)
        return comps.count >= (mirror ? 3 : 2)
            && comps.allSatisfy { !$0.isEmpty && !$0.hasPrefix(".") && $0.lowercased() != "trash" }
    }

    /// 线上的路径一律 NFC（Mac 上的文件名可能是分解形式，Linux 上两种形式是两个文件）。
    static func normalize(_ p: String) -> String { p.precomposedStringWithCanonicalMapping }

    // MARK: - 扫描

    struct Item: Equatable {
        var rel: String         // `Notes/…`（或 `NotesMirror/<id>/…`），NFC
        var size: Int64
        var mtime: Double       // 修改时间（自 1970 的秒）
    }

    /// [dir] 目录下全部能同步的文件，路径带上 [relPrefix]（**不读内容**，只列名字 + 大小 + 修改时间）。
    /// 工作区的 `Notes/` 是 `scan(dir: <工作区>/Notes, relPrefix: "Notes/")`；引用的外部目录是 `relPrefix: "NotesMirror/<id>/"`。
    /// 符号链接不跟（别把目录外的东西带进来）。目录不存在 = 空。
    static func scan(dir root: URL, relPrefix: String) -> [Item] {
        let fm = FileManager.default
        guard let walker = fm.enumerator(atPath: root.path) else { return [] }
        var out: [Item] = []
        while let sub = walker.nextObject() as? String {
            let rel = relPrefix + normalize(sub)
            guard let attrs = try? fm.attributesOfItem(atPath: root.appendingPathComponent(sub).path) else { continue }
            let type = attrs[.type] as? FileAttributeType
            if type == .typeDirectory {
                // 隐藏目录与 trash 整个不进
                let name = (sub as NSString).lastPathComponent
                if name.hasPrefix(".") || name.lowercased() == "trash" { walker.skipDescendants() }
                continue
            }
            guard type == .typeRegular, isSyncablePath(rel) else { continue }
            out.append(Item(rel: rel,
                            size: (attrs[.size] as? NSNumber)?.int64Value ?? 0,
                            mtime: (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0))
        }
        return out.sorted { $0.rel < $1.rel }
    }

    /// 工作区里两个根（`Notes/` 与 `NotesMirror/`）下的全部文件（服务器对账用）。
    static func scan(folder: URL) -> [Item] {
        roots.flatMap { name in
            scan(dir: folder.appendingPathComponent(name, isDirectory: true), relPrefix: name + "/")
        }
    }

    static func sha256Hex(fileAt url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - 冲突副本

    /// `Notes/数学/极限.md` → `Notes/数学/极限 (冲突 书房 2026-11-03 12-50).md`（扩展名保留；重名往后加 ` 2`、` 3`）。
    /// 名字格式沿用方案 §4.4：`<原名> (冲突 <设备名> <日期>).md`，日期用 `-` 不用 `:`（文件名里不能有）。
    static func conflictPath(for rel: String, device: String, date: Date, taken: (String) -> Bool) -> String {
        let ns = rel as NSString
        let dir = ns.deletingLastPathComponent
        let file = ns.lastPathComponent as NSString
        let ext = file.pathExtension
        let stem = file.deletingPathExtension
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH-mm"
        let dev = safeDevice(device)
        var n = 1
        while true {
            let tag = "冲突 \(dev) \(f.string(from: date))" + (n > 1 ? " \(n)" : "")
            let name = "\(stem) (\(tag))" + (ext.isEmpty ? "" : ".\(ext)")
            let candidate = dir.isEmpty ? name : dir + "/" + name
            if !taken(candidate) { return candidate }
            n += 1
        }
    }

    static func safeDevice(_ s: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:?*\"<>|()").union(.controlCharacters)
        let t = s.components(separatedBy: bad).joined(separator: "-").trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? "设备" : t
    }
}
