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
}
