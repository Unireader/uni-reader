import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// 网页（静态 HTML 课件，`docs/WEB-DOC-PLAN.md`）的**文件层**：`<工作区>/Web/<sha256>`，一个文件一份，按内容寻址。
///
/// 一份网页 = `web_doc` 表一行 + 一张**清单**（`manifest` 列，相对路径 → 内容哈希），文件本体在 `Web/` 里：
/// - 同一个文件（同一张图、同一份 js 库）在几份网页里只存一份；重新导入改过的课件只多存改了的那几个文件。
/// - 同步只按哈希补文件（离线镜像拷、服务器传），与图片 `Images/` 同一个思路；清单本身随行同步。
/// - 文件名不带扩展名：类型按清单里的路径定（`mimeType(path:)`），同一份字节挂在两个扩展名下也只存一份。
///
/// 只认 Foundation + 摘要库：服务器（Linux）经符号链接也编这个文件。所有写入都是「先 `.part` 再原子改名」，
/// 同 `ImageAssets`：中途断电只会留一个 `.part`，不会留一个只写了一半、哈希却对得上名字的文件。
enum WebAssets {

    static let folderName = "Web"

    static func folder(in workspace: URL) -> URL {
        workspace.appendingPathComponent(folderName, isDirectory: true)
    }

    static func url(in workspace: URL, sha256: String) -> URL {
        folder(in: workspace).appendingPathComponent(sha256)
    }

    static func exists(in workspace: URL, sha256: String) -> Bool {
        FileManager.default.fileExists(atPath: url(in: workspace, sha256: sha256).path)
    }

    static func isSHA256Hex(_ s: String) -> Bool {
        s.utf8.count == 64 && s.utf8.allSatisfy { (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }
    }

    // MARK: - 清单（跨端契约：JSON 数组，键名短、按路径排序）

    /// 清单里的一个文件。`p` = 课件文件夹里的相对路径（`/` 分隔、不以 `/` 开头、没有 `.` / `..` 段）；
    /// `h` = 内容 SHA-256（小写 hex）；`n` = 字节数。
    struct Entry: Codable, Equatable, Hashable {
        var p: String
        var h: String
        var n: Int64
    }

    /// 编码：按路径排序、键序固定（同样的内容同样的字节——清单进行指纹，抖一下就算「改过」）。
    static func encode(_ entries: [Entry]) -> String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let sorted = entries.sorted { $0.p < $1.p }
        guard let data = try? enc.encode(sorted) else { return "[]" }
        return String(decoding: data, as: UTF8.self)
    }

    /// 解码：坏 JSON / 不合规的条目丢掉（别让一条脏数据挡住整份课件，也别让 `../` 之类的路径混进来）。
    static func decode(_ json: String) -> [Entry] {
        guard let data = json.data(using: .utf8),
              let list = try? JSONDecoder().decode([Entry].self, from: data) else { return [] }
        return list.filter { isSafeRelative($0.p) && isSHA256Hex($0.h) }
    }

    /// 清单里全部文件的哈希。
    static func hashes(_ json: String) -> Set<String> { Set(decode(json).map(\.h)) }

    /// 课件里的相对路径是否安全：非空、不以 `/` 开头、没有空段 / `.` / `..`、没有反斜杠与控制字符。
    static func isSafeRelative(_ p: String) -> Bool {
        guard !p.isEmpty, !p.hasPrefix("/"), !p.contains("\\") else { return false }
        if p.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) { return false }
        for seg in p.split(separator: "/", omittingEmptySubsequences: false) {
            if seg.isEmpty || seg == "." || seg == ".." { return false }
        }
        return true
    }

    // MARK: - 按路径找文件（App 内嵌显示与本机浏览器服务共用）

    /// 请求路径（已去掉开头的 `/`、已做百分号解码）→ 清单里的那一项。
    /// 空路径 / 以 `/` 结尾 = 目录，找它下面的 `index.html`（再找 `index.htm`）。大小写敏感（同网页服务器的老规矩）。
    static func resolve(_ path: String, in entries: [String: Entry]) -> Entry? {
        var p = path
        while p.hasPrefix("/") { p.removeFirst() }
        if p.isEmpty || p.hasSuffix("/") {
            return entries[p + "index.html"] ?? entries[p + "index.htm"]
        }
        if let e = entries[p] { return e }
        // `/chapter1` 指的是文件夹：同上找它的 index
        return entries[p + "/index.html"] ?? entries[p + "/index.htm"]
    }

    /// 入口页：根目录的 `index.html` / `index.htm`；没有就挑最浅、名字最靠前的那个 html。
    static func defaultEntry(_ entries: [Entry]) -> String? {
        let paths = Set(entries.map(\.p))
        for name in ["index.html", "index.htm", "Index.html", "INDEX.HTML"] where paths.contains(name) { return name }
        let htmls = entries.map(\.p).filter { isHTML($0) }
        return htmls.min { a, b in
            let da = a.split(separator: "/").count, db = b.split(separator: "/").count
            return da != db ? da < db : a.localizedStandardCompare(b) == .orderedAscending
        }
    }

    static func isHTML(_ path: String) -> Bool {
        let ext = (path as NSString).pathExtension.lowercased()
        return ext == "html" || ext == "htm" || ext == "xhtml"
    }

    // MARK: - 类型

    /// 按扩展名给 Content-Type（不认识的一律 `application/octet-stream`）。文本类带 `charset=utf-8`。
    static func mimeType(path: String) -> String {
        let ext = (path as NSString).pathExtension.lowercased()
        return mimeTypes[ext] ?? "application/octet-stream"
    }

    private static let mimeTypes: [String: String] = [
        "html": "text/html; charset=utf-8", "htm": "text/html; charset=utf-8", "xhtml": "application/xhtml+xml",
        "css": "text/css; charset=utf-8", "js": "text/javascript; charset=utf-8", "mjs": "text/javascript; charset=utf-8",
        "json": "application/json; charset=utf-8", "map": "application/json; charset=utf-8",
        "txt": "text/plain; charset=utf-8", "md": "text/plain; charset=utf-8", "csv": "text/csv; charset=utf-8",
        "xml": "application/xml", "svg": "image/svg+xml", "wasm": "application/wasm",
        "png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "gif": "image/gif", "webp": "image/webp",
        "avif": "image/avif", "ico": "image/x-icon", "bmp": "image/bmp",
        "woff": "font/woff", "woff2": "font/woff2", "ttf": "font/ttf", "otf": "font/otf", "eot": "application/vnd.ms-fontobject",
        "mp4": "video/mp4", "m4v": "video/mp4", "webm": "video/webm", "ogv": "video/ogg", "mov": "video/quicktime",
        "mp3": "audio/mpeg", "m4a": "audio/mp4", "aac": "audio/aac", "wav": "audio/wav", "ogg": "audio/ogg", "oga": "audio/ogg",
        "flac": "audio/flac", "vtt": "text/vtt; charset=utf-8", "pdf": "application/pdf", "zip": "application/zip",
    ]

    // MARK: - HTTP Range（内嵌显示与本机浏览器服务共用：浏览器放视频必须支持）

    /// `Range: bytes=a-b` / `bytes=a-` / `bytes=-n` → 闭区间。只认单段；不合法 / 越界 = nil（按整份回）。
    static func byteRange(_ header: String?, size: Int64) -> ClosedRange<Int64>? {
        guard let header, size > 0 else { return nil }
        let h = header.trimmingCharacters(in: .whitespaces)
        guard h.lowercased().hasPrefix("bytes=") else { return nil }
        let spec = h.dropFirst(6)
        guard !spec.contains(",") else { return nil }
        let parts = spec.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        let a = parts[0].trimmingCharacters(in: .whitespaces), b = parts[1].trimmingCharacters(in: .whitespaces)
        if a.isEmpty {
            guard let n = Int64(b), n > 0 else { return nil }
            return max(0, size - n)...(size - 1)
        }
        guard let start = Int64(a), start < size else { return nil }
        let end = b.isEmpty ? size - 1 : min(Int64(b) ?? -1, size - 1)
        guard end >= start else { return nil }
        return start...end
    }

    /// 读文件的一段（不整份读进内存：视频可能上百 MB）。
    static func read(_ url: URL, range: ClosedRange<Int64>) throws -> Data {
        let fh = try FileHandle(forReadingFrom: url)
        defer { try? fh.close() }
        try fh.seek(toOffset: UInt64(range.lowerBound))
        return try fh.read(upToCount: Int(range.upperBound - range.lowerBound + 1)) ?? Data()
    }

    // MARK: - 写

    /// 流式算一个文件的 SHA-256（小写 hex）。
    static func sha256Hex(fileAt url: URL) throws -> String {
        let fh = try FileHandle(forReadingFrom: url)
        defer { try? fh.close() }
        var hasher = SHA256()
        while let chunk = try fh.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// 把一个文件拷进 `Web/<sha>`（已在就不动）。`.part` 原子写，幂等。
    static func copy(from src: URL, to workspace: URL, sha256: String) throws {
        let fm = FileManager.default
        let dst = url(in: workspace, sha256: sha256)
        // 🔴 修改时间一律记成「现在」：清理按它判「是不是刚放进来的」（`purge`）。拷贝会保留源文件的旧时间，
        // 不改的话导入到一半（文件已拷、行还没写）时碰上一次清理，刚拷的文件就被当成孤儿删掉
        let touch = { (path: String) in try? fm.setAttributes([.modificationDate: Date()], ofItemAtPath: path) }
        if fm.fileExists(atPath: dst.path) { touch(dst.path); return }
        let dir = folder(in: workspace)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let tmp = dir.appendingPathComponent(".\(sha256).\(UUID().uuidString.prefix(8)).part")
        try? fm.removeItem(at: tmp)
        try fm.copyItem(at: src, to: tmp)
        touch(tmp.path)
        if fm.fileExists(atPath: dst.path) { try? fm.removeItem(at: tmp); touch(dst.path); return }   // 并发里别人先放好了
        try fm.moveItem(at: tmp, to: dst)
    }

    /// 一段内存里的字节存成 `Web/<sha>`（Agent 经 MCP 写文件用）。返回哈希。幂等，修改时间记成现在。
    @discardableResult
    static func write(_ data: Data, to workspace: URL) throws -> String {
        let fm = FileManager.default
        let sha = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let dst = url(in: workspace, sha256: sha)
        if fm.fileExists(atPath: dst.path) {
            try? fm.setAttributes([.modificationDate: Date()], ofItemAtPath: dst.path)
            return sha
        }
        let dir = folder(in: workspace)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let tmp = dir.appendingPathComponent(".\(sha).\(UUID().uuidString.prefix(8)).part")
        try data.write(to: tmp)
        if fm.fileExists(atPath: dst.path) { try? fm.removeItem(at: tmp); return sha }
        try fm.moveItem(at: tmp, to: dst)
        return sha
    }

    /// 导入时跳过的东西：隐藏文件 / 文件夹（`.git`、`.DS_Store`）、系统垃圾。
    static func isJunk(_ name: String) -> Bool {
        name.hasPrefix(".") || name == "Thumbs.db" || name == "desktop.ini" || name == "__MACOSX"
    }

    /// 导入上限：防止误选了整个下载目录（几万个文件 / 几十 GB 一股脑拷进工作区）。
    static let maxFiles = 20_000
    static let maxBytes: Int64 = 4 << 30

    enum ImportError: Error, Equatable {
        case notAFolder
        case empty
        case noHTML
        case tooManyFiles(Int)
        case tooLarge(Int64)
    }

    /// 扫描一个文件夹（不拷）：相对路径 → 本机文件、字节数。跳过隐藏文件、符号链接与 `isJunk`。
    static func scan(folder src: URL) throws -> [(rel: String, url: URL, size: Int64)] {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: src.path, isDirectory: &isDir), isDir.boolValue else { throw ImportError.notAFolder }
        let base = src.standardizedFileURL.resolvingSymlinksInPath()
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .isDirectoryKey]
        guard let en = fm.enumerator(at: base, includingPropertiesForKeys: keys, options: [.skipsPackageDescendants]) else {
            throw ImportError.notAFolder
        }
        var out: [(String, URL, Int64)] = []
        var total: Int64 = 0
        let basePath = base.path.hasSuffix("/") ? base.path : base.path + "/"
        while let item = en.nextObject() as? URL {
            let name = item.lastPathComponent
            let vals = try? item.resourceValues(forKeys: Set(keys))
            if isJunk(name) {
                if vals?.isDirectory == true { en.skipDescendants() }
                continue
            }
            if vals?.isSymbolicLink == true { continue }
            guard vals?.isRegularFile == true else { continue }
            let full = item.standardizedFileURL.path
            guard full.hasPrefix(basePath) else { continue }
            let rel = String(full.dropFirst(basePath.count))
            guard isSafeRelative(rel) else { continue }
            let size = Int64(vals?.fileSize ?? 0)
            out.append((rel, item, size))
            total += size
            if out.count > maxFiles { throw ImportError.tooManyFiles(out.count) }
            if total > maxBytes { throw ImportError.tooLarge(total) }
        }
        guard !out.isEmpty else { throw ImportError.empty }
        guard out.contains(where: { isHTML($0.0) }) else { throw ImportError.noHTML }
        return out
    }

    /// 导入整个文件夹：逐个算哈希、拷进 `Web/`，返回清单。[progress] 收到（第几个，共几个）。在后台线程调。
    static func importFolder(_ src: URL, into workspace: URL,
                             progress: ((Int, Int) -> Void)? = nil) throws -> [Entry] {
        let files = try scan(folder: src)
        var entries: [Entry] = []
        entries.reserveCapacity(files.count)
        for (i, f) in files.enumerated() {
            progress?(i, files.count)
            let sha = try sha256Hex(fileAt: f.url)
            try copy(from: f.url, to: workspace, sha256: sha)
            entries.append(Entry(p: f.rel, h: sha, n: f.size))
        }
        progress?(files.count, files.count)
        return entries
    }

    // MARK: - 清理

    /// `Web/` 里有哪些文件（只认 64 位 hex 的名字；`.part` 之类不算）。
    static func storedHashes(in workspace: URL) -> Set<String> {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder(in: workspace).path)) ?? []
        return Set(names.filter(isSHA256Hex))
    }

    /// 删掉没人用的文件：[keep] 以外、且最后修改早于 [olderThan] 的（刚导入一半的文件还没进清单，别把它删了）。
    /// 返回删了几个。顺手清掉一天前的 `.part` 残留。
    @discardableResult
    static func purge(in workspace: URL, keep: Set<String>, olderThan: Date) -> Int {
        let fm = FileManager.default
        let dir = folder(in: workspace)
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return 0 }
        var removed = 0
        for name in names {
            let isPart = name.hasPrefix(".") && name.hasSuffix(".part")
            guard isPart || (isSHA256Hex(name) && !keep.contains(name)) else { continue }
            let u = dir.appendingPathComponent(name)
            let mtime = (try? u.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            let cutoff = isPart ? Date().addingTimeInterval(-86_400) : olderThan
            guard mtime < cutoff else { continue }
            if (try? fm.removeItem(at: u)) != nil, !isPart { removed += 1 }
        }
        return removed
    }
}
