import Foundation

extension Notification.Name {
    /// 某份网页存的数据被同步改了（`object` = 工作区）。开着的网页据此发 `unireader:change` 事件。
    static let webKVDidChangeRemotely = Notification.Name("UniReader.webKVDidChangeRemotely")
}

/// 网页（静态 HTML 课件，`docs/WEB-DOC-PLAN.md`）的执行层：导入 / 改名 / 删除 / 清理文件 + 页面存的数据（`web_kv`）。
/// 同步不用另做：两张表都在 `MirrorFp.specs` 里；文件按清单里的哈希补（`MirrorApply.fillWebFiles` / `ServerSyncIO`）。
extension WorkspaceManager {

    // MARK: - 列表

    func refreshWebDocs() {
        let list = (try? store?.webDocs()) ?? []
        if list != webDocs { webDocs = list }
    }

    func webDoc(id: String) -> LibWebDoc? { (try? store?.webDoc(id: id)) ?? nil }

    /// 这份网页的文件都在本机吗（同步刚拉到行、文件还没下完时为假）。
    func webDocFilesMissing(_ w: LibWebDoc) -> Int {
        guard let folder else { return 0 }
        return Set(w.entries.map(\.h)).filter { !WebAssets.exists(in: folder, sha256: $0) }.count
    }

    // MARK: - 导入

    enum WebImportFailure: Error, LocalizedError {
        case noWorkspace
        case assets(WebAssets.ImportError)
        case other(String)

        var errorDescription: String? {
            switch self {
            case .noWorkspace: return L("No workspace is open.")
            case .assets(.notAFolder): return L("Choose a folder.")
            case .assets(.empty): return L("The folder is empty.")
            case .assets(.noHTML): return L("There is no HTML file in this folder.")
            case .assets(.tooManyFiles): return String(format: L("The folder has more than %d files. Choose the folder of one web page."), WebAssets.maxFiles)
            case .assets(.tooLarge): return L("The folder is larger than 4 GB. Choose the folder of one web page.")
            case .other(let s): return s
            }
        }
    }

    /// 导入一个文件夹（或单个 html 文件：导入它所在的文件夹，入口就是它）为一份网页。
    /// `replacing` 非 nil = 重新导入到已有的那份（id 不变，页面存的数据留着）。哈希与复制在后台做。
    func importWebFolder(_ url: URL, replacing: String? = nil,
                         progress: @escaping @Sendable (Int, Int) -> Void = { _, _ in }) async throws -> LibWebDoc {
        guard let folder, store != nil else { throw WebImportFailure.noWorkspace }
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        let root = isDir.boolValue ? url : url.deletingLastPathComponent()
        let preferredEntry = isDir.boolValue ? nil : url.lastPathComponent
        let entries: [WebAssets.Entry]
        do {
            entries = try await Task.detached(priority: .userInitiated) {
                try WebAssets.importFolder(root, into: folder, progress: progress)
            }.value
        } catch let e as WebAssets.ImportError {
            throw WebImportFailure.assets(e)
        }
        guard let store else { throw WebImportFailure.noWorkspace }
        let paths = Set(entries.map(\.p))
        let entry = preferredEntry.flatMap { paths.contains($0) ? $0 : nil } ?? WebAssets.defaultEntry(entries) ?? "index.html"
        let now = Date.now
        var w: LibWebDoc
        if let id = replacing, let old = webDoc(id: id) {
            w = old
            w.manifest = WebAssets.encode(entries)
            w.entry = paths.contains(old.entry) && preferredEntry == nil ? old.entry : entry
        } else {
            w = LibWebDoc(id: UUID().uuidString, title: Self.webTitle(root: root, entry: entry),
                          entry: entry, manifest: WebAssets.encode(entries), bytes: 0, createdAt: now, updatedAt: now,
                          lastOpenedAt: now)
        }
        w.bytes = entries.reduce(0) { $0 + $1.n }
        w.updatedAt = now
        do { try store.upsertWebDoc(w) } catch { throw WebImportFailure.other("\(error)") }
        wsLog("[WEB] 导入网页「\(w.title)」：\(entries.count) 个文件，\(w.bytes) 字节，入口 \(w.entry)")
        refreshWebDocs()
        return w
    }

    /// 新导入的网页叫什么：入口页的 `<title>`，没有就用文件夹名。
    private static func webTitle(root: URL, entry: String) -> String {
        let fallback = root.lastPathComponent
        guard let data = try? Data(contentsOf: root.appendingPathComponent(entry), options: .mappedIfSafe) else { return fallback }
        let head = String(decoding: data.prefix(64 * 1024), as: UTF8.self)
        guard let open = head.range(of: "<title", options: .caseInsensitive),
              let gt = head[open.upperBound...].firstIndex(of: ">"),
              let close = head.range(of: "</title>", options: .caseInsensitive, range: gt..<head.endIndex) else { return fallback }
        let raw = head[head.index(after: gt)..<close.lowerBound]
        let t = raw.replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">").replacingOccurrences(of: "&quot;", with: "\"")
            .components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
        return t.isEmpty ? fallback : String(t.prefix(120))
    }

    // MARK: - 改

    func renameWebDoc(id: String, title: String) {
        guard let store, var w = webDoc(id: id) else { return }
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, t != w.title else { return }
        w.title = t
        w.updatedAt = .now
        try? store.upsertWebDoc(w)
        refreshWebDocs()
    }

    /// 改入口页（清单里得有这个路径）。
    func setWebDocEntry(id: String, entry: String) {
        guard let store, var w = webDoc(id: id), w.entries.contains(where: { $0.p == entry }), w.entry != entry else { return }
        w.entry = entry
        w.updatedAt = .now
        try? store.upsertWebDoc(w)
        refreshWebDocs()
    }

    /// 记「最近打开」（不改 `updated_at`）。
    func webDocWasOpened(id: String) {
        try? store?.touchWebDocOpened(id: id)
        refreshWebDocs()
    }

    /// 删除：**先归档进回收站、成功了才删**（红线⑪）。文件留在 `Web/`，回收站条目护着它们（`trashHeldWebFiles`）。
    @discardableResult
    func trashWebDoc(id: String) -> Bool {
        guard let store, let w = webDoc(id: id) else { return false }
        guard Trash.archiveWebDoc(store: store, webId: id, title: w.title) != nil else {
            lastError = String(format: L("Could not archive “%@”, so nothing was deleted."), w.title)
            return false
        }
        do { try store.deleteWebDoc(id: id) } catch { lastError = "\(error)"; return false }
        refreshWebDocs()
        return true
    }

    /// 清掉没人用的网页文件：库里的网页与回收站条目都不用、且一天前就在的（刚导入的还没进清单）。
    func purgeWebFiles() {
        guard let store, let folder else { return }
        guard let live = try? store.webFileHashes() else { return }
        let n = WebAssets.purge(in: folder, keep: live.union(trashHeldWebFiles), olderThan: Date().addingTimeInterval(-86_400))
        if n > 0 { wsLog("[WEB] 清理了 \(n) 个没人用的网页文件") }
    }

    // MARK: - 按文件改（Agent 经 MCP，`WEB-DOC-PLAN.md §7.1`）

    /// 一次改动：写这些文件（相对路径 → 字节，有就覆盖、没有就新建）、删这些路径，可选改名 / 换首页。
    /// 文件先落进 `Web/`，最后换清单、改 `updated_at`（同步按它认「改过」）——中途失败清单不动。
    struct WebDocChange {
        var writes: [String: Data] = [:]
        var deletes: [String] = []
        var title: String?
        var entry: String?
    }

    /// 改一份已有的网页。返回改完的那份。
    @discardableResult
    func changeWebDoc(id: String, _ change: WebDocChange) throws -> LibWebDoc {
        guard let store, let folder else { throw WebImportFailure.noWorkspace }
        guard var w = webDoc(id: id) else { throw WebImportFailure.other("No web page with id \(id).") }
        var map: [String: WebAssets.Entry] = [:]
        for e in w.entries { map[e.p] = e }
        for p in change.deletes {
            guard map.removeValue(forKey: p) != nil else { throw WebImportFailure.other("No file at \(p) in this web page.") }
        }
        for (p, data) in change.writes {
            guard WebAssets.isSafeRelative(p) else { throw WebImportFailure.other("Bad path: \(p)") }
            let sha = try WebAssets.write(data, to: folder)
            map[p] = WebAssets.Entry(p: p, h: sha, n: Int64(data.count))
        }
        guard !map.isEmpty else { throw WebImportFailure.other("A web page needs at least one file.") }
        if let t = change.title?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty { w.title = t }
        if let e = change.entry {
            guard map[e] != nil else { throw WebImportFailure.other("The start page \(e) is not a file of this web page.") }
            w.entry = e
        } else if map[w.entry] == nil {
            w.entry = WebAssets.defaultEntry(Array(map.values)) ?? map.keys.sorted()[0]
        }
        let entries = Array(map.values)
        w.manifest = WebAssets.encode(entries)
        w.bytes = entries.reduce(0) { $0 + $1.n }
        w.updatedAt = .now
        try store.upsertWebDoc(w)
        refreshWebDocs()
        return w
    }

    /// 新建一份网页（文件全在内存里给：Agent 现写的课件）。
    func createWebDoc(title: String, files: [String: Data], entry: String?) throws -> LibWebDoc {
        guard let store, let folder else { throw WebImportFailure.noWorkspace }
        guard !files.isEmpty else { throw WebImportFailure.other("A web page needs at least one file.") }
        var entries: [WebAssets.Entry] = []
        for (p, data) in files {
            guard WebAssets.isSafeRelative(p) else { throw WebImportFailure.other("Bad path: \(p)") }
            entries.append(WebAssets.Entry(p: p, h: try WebAssets.write(data, to: folder), n: Int64(data.count)))
        }
        let paths = Set(entries.map(\.p))
        if let entry, !paths.contains(entry) { throw WebImportFailure.other("The start page \(entry) is not one of the files.") }
        let now = Date.now
        let w = LibWebDoc(id: UUID().uuidString, title: title.isEmpty ? L("Web Page") : title,
                          entry: entry ?? WebAssets.defaultEntry(entries) ?? entries.map(\.p).sorted()[0],
                          manifest: WebAssets.encode(entries), bytes: entries.reduce(0) { $0 + $1.n },
                          createdAt: now, updatedAt: now, lastOpenedAt: now)
        try store.upsertWebDoc(w)
        refreshWebDocs()
        return w
    }

    /// 读一份网页里某个文件的字节（没有 / 还没同步下来 = nil）。
    func webFileData(_ w: LibWebDoc, path: String) -> Data? {
        guard let folder, let e = w.entries.first(where: { $0.p == path }) else { return nil }
        return try? Data(contentsOf: WebAssets.url(in: folder, sha256: e.h))
    }

    // MARK: - 页面存的数据（`window.unireader`，`WEB-DOC-PLAN.md §5`）

    /// 一份网页最多存多少：键数 / 单个值 / 总字节。值都是 JSON 文本。
    static let webKVMaxKeys = 2000
    static let webKVMaxValueBytes = 1 << 20
    static let webKVMaxTotalBytes = 8 << 20
    static let webKVMaxKeyBytes = 512

    /// 页面发来的一次读写。`op`：get / set / remove / keys / getAll / clear。
    /// 返回给页面的 JSON 文本；出错抛 `WebKVError`（文字给页面看，用英文）。
    func webKV(webId: String, op: String, key: String?, value: String?) throws -> String {
        guard let store, webDoc(id: webId) != nil else { throw WebKVError("This web page is not in the workspace.") }
        func needKey() throws -> String {
            guard let k = key, !k.isEmpty else { throw WebKVError("A key is required.") }
            guard k.utf8.count <= Self.webKVMaxKeyBytes else { throw WebKVError("The key is too long.") }
            return k
        }
        switch op {
        case "get":
            return try store.webKVValue(webId: webId, key: needKey()) ?? "null"
        case "set":
            let k = try needKey()
            let v = value ?? "null"
            guard v.utf8.count <= Self.webKVMaxValueBytes else { throw WebKVError("The value is larger than 1 MB.") }
            guard (try? JSONSerialization.jsonObject(with: Data(v.utf8), options: .fragmentsAllowed)) != nil else {
                throw WebKVError("The value is not JSON.")
            }
            let use = try store.webKVUsage(webId: webId)
            let old = try store.webKVValue(webId: webId, key: k)
            if old == nil, use.count >= Self.webKVMaxKeys { throw WebKVError("Too many keys (at most \(Self.webKVMaxKeys)).") }
            let grow = v.utf8.count + (old == nil ? k.utf8.count : -(old?.utf8.count ?? 0))
            if use.bytes + grow > Self.webKVMaxTotalBytes { throw WebKVError("This page has stored more than 8 MB.") }
            try store.setWebKV(webId: webId, key: k, value: v)
            return "true"
        case "remove":
            try store.removeWebKV(webId: webId, key: needKey())
            return "true"
        case "keys":
            let keys = try store.webKV(webId: webId).map(\.key)
            return String(decoding: try JSONSerialization.data(withJSONObject: keys), as: UTF8.self)
        case "getAll":
            // 值本来就是 JSON 文本，直接拼成一个对象（键用 JSONSerialization 转义）
            let parts = try store.webKV(webId: webId).map { kv -> String in
                let k = String(decoding: try JSONSerialization.data(withJSONObject: kv.key, options: .fragmentsAllowed), as: UTF8.self)
                return k + ":" + kv.value
            }
            return "{" + parts.joined(separator: ",") + "}"
        case "clear":
            try store.clearWebKV(webId: webId)
            return "true"
        default:
            throw WebKVError("Unknown operation: \(op)")
        }
    }

    struct WebKVError: Error, LocalizedError {
        let message: String
        init(_ m: String) { message = m }
        var errorDescription: String? { message }
    }

    /// 同步拉到了别处改的 `web_kv` 行。
    func webKVChangedRemotely() {
        NotificationCenter.default.post(name: .webKVDidChangeRemotely, object: self)
    }
}
