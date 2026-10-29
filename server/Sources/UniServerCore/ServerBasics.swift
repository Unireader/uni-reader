import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// 服务器数据目录的布局（方案 `SERVER-MODE-PLAN.md §3.1`）。
///
/// ```
/// <root>/
///   server.sqlite                    设备令牌（只存哈希）、配对码
///   workspaces/<workspace_id>.unrd/  标准工作区 + 服务器私有表
///   uploads/                         正在上传、还没登记的工作区与文件
///   trash/<workspace_id>/            删除先归档（按天一个小库）
///   backups/<workspace_id>/          分级定时备份
/// ```
public struct ServerPaths: Sendable {
    public let root: URL

    public init(root: URL) { self.root = root }

    var serverDB: URL { root.appendingPathComponent("server.sqlite") }
    var workspaces: URL { root.appendingPathComponent("workspaces", isDirectory: true) }
    var uploads: URL { root.appendingPathComponent("uploads", isDirectory: true) }

    func workspaceFolder(_ id: String) -> URL { workspaces.appendingPathComponent("\(id).unrd", isDirectory: true) }
    func trashFolder(_ id: String) -> URL { root.appendingPathComponent("trash/\(id)", isDirectory: true) }
    func backupFolder(_ id: String) -> URL { root.appendingPathComponent("backups/\(id)", isDirectory: true) }
    func snapshotFolder(_ id: String) -> URL { root.appendingPathComponent("snapshots/\(id)", isDirectory: true) }
    /// 断点续传中的半截文件（PDF / 图片本体）。
    var partials: URL { uploads.appendingPathComponent("partials", isDirectory: true) }

    func createDirectories() throws {
        for d in [root, workspaces, uploads] {
            try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        }
    }

    /// 默认数据目录：macOS 上在应用支持目录，Linux 上 `/var/lib/unireader`。
    public static var defaultRoot: URL {
        #if os(macOS)
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("UniReaderServer", isDirectory: true)
        #else
        return URL(fileURLWithPath: "/var/lib/unireader", isDirectory: true)
        #endif
    }
}

public enum ServerError: Error, Equatable, CustomStringConvertible {
    case badPairingCode
    case notAWorkspace
    /// 上传的工作区比服务器程序新（先升级服务器）。
    case workspaceSchemaTooNew(workspace: Int, server: Int)
    case alreadyHosted(String)
    case unknownWorkspace(String)
    /// 客户端与服务器的 schema 版本不同：低于服务器只能读，高于服务器要先升级服务器（方案 §3.6）。
    case schemaMismatch(client: Int, server: Int)
    case badContentHash
    case badRequest(String)

    public var description: String {
        switch self {
        case .badPairingCode: return "配对码不对"
        case .notAWorkspace: return "不是一个 UniReader 工作区"
        case .workspaceSchemaTooNew(let w, let s): return "工作区的数据版本（\(w)）比服务器（\(s)）新，请先升级服务器"
        case .alreadyHosted(let id): return "服务器上已经有这个工作区（\(id)）"
        case .unknownWorkspace(let id): return "服务器上没有这个工作区（\(id)）"
        case .schemaMismatch(let c, let s):
            return c < s ? "App 的数据版本（\(c)）比服务器（\(s)）旧，请先升级 App"
                         : "App 的数据版本（\(c)）比服务器（\(s)）新，请先升级服务器"
        case .badContentHash: return "文件内容与声明的哈希不一致"
        case .badRequest(let m): return "请求不对：\(m)"
        }
    }
}

/// 哈希与随机串。
enum ServerCrypto {
    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// 文件的 SHA-256（分块读，与 App 的 `FileHasher.sha256(of:)` 同一口径：整个文件、小写十六进制）。
    static func sha256Hex(fileAt url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 4 * 1024 * 1024), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func randomHex(bytes n: Int) -> String {
        var g = SystemRandomNumberGenerator()
        return (0..<n).map { _ in String(format: "%02x", UInt8.random(in: 0...255, using: &g)) }.joined()
    }

    /// 配对码：10 位，去掉了容易看错的字符（0/O、1/I/L）。约 50 位熵。
    static func pairingCode() -> String {
        let alphabet = Array("23456789ABCDEFGHJKMNPQRSTUVWXYZ")
        var g = SystemRandomNumberGenerator()
        return String((0..<10).map { _ in alphabet[Int.random(in: 0..<alphabet.count, using: &g)] })
    }

    static func isUUID(_ s: String) -> Bool { UUID(uuidString: s) != nil }

    static func isSHA256Hex(_ s: String) -> Bool {
        s.count == 64 && s.utf8.allSatisfy { (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }
    }
}
