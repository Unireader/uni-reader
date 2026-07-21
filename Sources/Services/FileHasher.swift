import Foundation
import CryptoKit

enum FileHasher {
    /// 分块读取计算 SHA-256，避免大文件占内存。请在后台队列调用。
    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        let chunkSize = 4 * 1024 * 1024   // 4 MB
        while true {
            let data = try handle.read(upToCount: chunkSize) ?? Data()
            if data.isEmpty { break }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - 缓存（`(path,size,mtime) → hash`，本机 UserDefaults）
    // 避免每次打开/入库都重算整文件 SHA-256（大文件很慢）。文件被改 → mtime 变 → 新键 → 自动重算。

    private static let cacheKey = "fileHashCache"
    private static let lock = NSLock()

    /// 带缓存的 SHA-256：`(path,size,mtime)` 命中直接返回，否则计算并缓存。后台队列调用。
    static func sha256Cached(of url: URL) throws -> String {
        let key = statKey(url)
        if let key, let hit = cachedHash(key) { return hit }
        let hash = try sha256(of: url)
        if let key { storeHash(key, hash) }
        return hash
    }

    /// `path#size#mtime`（取不到属性则返回 nil，退化为不缓存）。
    private static func statKey(_ url: URL) -> String? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        let size = (attrs[.size] as? Int) ?? -1
        let mtime = Int((attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? -1)
        return "\(url.path)#\(size)#\(mtime)"
    }

    private static func cachedHash(_ key: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return (UserDefaults.standard.dictionary(forKey: cacheKey) as? [String: String])?[key]
    }

    private static func storeHash(_ key: String, _ hash: String) {
        lock.lock(); defer { lock.unlock() }
        var dict = (UserDefaults.standard.dictionary(forKey: cacheKey) as? [String: String]) ?? [:]
        if dict.count > 2000 { dict = [:] }   // 容量保护（键含 mtime，改文件即换键、旧键自然作废）
        dict[key] = hash
        UserDefaults.standard.set(dict, forKey: cacheKey)
    }
}
