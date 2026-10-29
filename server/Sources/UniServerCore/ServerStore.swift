import Foundation

/// 服务器自己的库 `server.sqlite`：配对码与设备令牌（方案 `SERVER-MODE-PLAN.md §3.4`）。
///
/// - 配对码在服务器首次启动时生成（打在控制台），可以重置；设备拿它换一个**随机令牌**。
/// - 库里**只存令牌的 SHA-256**：库文件泄露也拿不到能用的令牌。
/// - 每台设备一个令牌，可以逐台吊销。只有用户一个人用，不做账号体系。
public final class ServerStore: @unchecked Sendable {

    public struct Device: Equatable, Sendable {
        public var id: String
        public var name: String
        public var createdAt: String
        public var lastSeenAt: String?
        public var revoked: Bool
    }

    private let db: SQLiteDB

    public init(paths: ServerPaths) throws {
        try paths.createDirectories()
        db = try SQLiteDB(path: paths.serverDB.path)
        try db.exec("""
        CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT);
        CREATE TABLE IF NOT EXISTS device (
          id TEXT PRIMARY KEY,
          name TEXT NOT NULL,
          token_hash TEXT NOT NULL UNIQUE,
          created_at TEXT NOT NULL,
          last_seen_at TEXT,
          revoked_at TEXT
        );
        """)
    }

    public func close() { db.close() }

    // MARK: - 服务器身份

    /// 服务器的稳定身份（首次启动生成，之后不变）。局域网发现的 TXT 与 `/v1/info` 都带它：
    /// 服务器换了 IP，客户端靠它认出「还是那一台」（方案 §3.7）。
    public func serverId() throws -> String {
        if let id = meta("server_id"), !id.isEmpty { return id }
        let id = UUID().uuidString
        try setMeta("server_id", id)
        return id
    }

    // MARK: - 配对码

    /// 当前配对码；还没有就生成一个。
    public func pairingCode() throws -> String {
        if let c = meta("pairing_code"), !c.isEmpty { return c }
        return try resetPairingCode()
    }

    /// 换一个新配对码（旧的立即作废；已配对的设备不受影响）。
    @discardableResult
    public func resetPairingCode() throws -> String {
        let c = ServerCrypto.pairingCode()
        try setMeta("pairing_code", c)
        return c
    }

    // MARK: - 设备

    /// 用配对码换令牌。令牌只在这里返回这一次，库里只留哈希。
    public func pair(code: String, deviceName: String, now: Date = .now) throws -> (device: Device, token: String) {
        guard let expected = meta("pairing_code"), !expected.isEmpty,
              code.uppercased() == expected else { throw ServerError.badPairingCode }
        let name = deviceName.trimmingCharacters(in: .whitespacesAndNewlines)
        let token = ServerCrypto.randomHex(bytes: 32)
        let device = Device(id: UUID().uuidString, name: name.isEmpty ? "未命名设备" : name,
                            createdAt: ISO.string(now), lastSeenAt: nil, revoked: false)
        try db.run("INSERT INTO device(id,name,token_hash,created_at) VALUES(?,?,?,?)",
                   [.text(device.id), .text(device.name),
                    .text(ServerCrypto.sha256Hex(Data(token.utf8))), .text(device.createdAt)])
        return (device, token)
    }

    /// 认令牌。不认识 / 已吊销 = nil。顺带记「上次见到」（一分钟内不重复写）。
    public func authenticate(token: String, now: Date = .now) -> Device? {
        guard !token.isEmpty else { return nil }
        let hash = ServerCrypto.sha256Hex(Data(token.utf8))
        guard let row = (try? db.query("SELECT * FROM device WHERE token_hash=?", [.text(hash)]))?.first
        else { return nil }
        var d = Self.device(row)
        guard !d.revoked else { return nil }
        let nowISO = ISO.string(now)
        if d.lastSeenAt.flatMap(ISO.date).map({ now.timeIntervalSince($0) >= 60 }) ?? true {
            try? db.run("UPDATE device SET last_seen_at=? WHERE id=?", [.text(nowISO), .text(d.id)])
            d.lastSeenAt = nowISO
        }
        return d
    }

    public func devices() throws -> [Device] {
        try db.query("SELECT * FROM device ORDER BY created_at").map(Self.device)
    }

    public func revoke(deviceId: String, now: Date = .now) throws {
        try db.run("UPDATE device SET revoked_at=? WHERE id=? AND revoked_at IS NULL",
                   [.text(ISO.string(now)), .text(deviceId)])
    }

    // MARK: - 内部

    private static func device(_ r: [String: Any]) -> Device {
        Device(id: r["id"] as? String ?? "", name: r["name"] as? String ?? "",
               createdAt: r["created_at"] as? String ?? "", lastSeenAt: r["last_seen_at"] as? String,
               revoked: r["revoked_at"] is String)
    }

    private func meta(_ key: String) -> String? {
        (try? db.query("SELECT value FROM meta WHERE key=?", [.text(key)]))?.first?["value"] as? String
    }

    private func setMeta(_ key: String, _ value: String) throws {
        try db.run("INSERT INTO meta(key,value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",
                   [.text(key), .text(value)])
    }
}
