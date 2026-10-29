import Foundation
import Combine

/// 连过的服务器（本机全局，方案 `SERVER-MODE-PLAN.md §2`）。
///
/// 列表存 UserDefaults；**设备令牌存 Keychain**（与 API key 同一处，`Keychain`），不落明文 plist。
/// 一般就一台；数据结构允许多台。断开 = 只删令牌与这一条，本机缓存不动。
struct ServerAccount: Codable, Identifiable, Hashable {
    var id: String
    /// 基础地址（`ServerClient.normalize` 过的，形如 `http://192.168.1.5:8790`）。
    var url: String
    var deviceId: String
    var deviceName: String
    /// 服务器的稳定身份与名字（配对时服务器给的；局域网发现靠它认出「换了 IP 的同一台」）。老记录没有 = nil。
    var serverId: String?
    var serverName: String?
}

@MainActor
final class ServerAccounts: ObservableObject {
    static let shared = ServerAccounts()

    @Published private(set) var all: [ServerAccount] = []

    private let key = "serverAccounts"

    private init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let list = try? JSONDecoder().decode([ServerAccount].self, from: data) { all = list }
    }

    enum Failure: LocalizedError {
        case versionMismatch(server: Int, app: Int)
        case alreadyAdded

        var errorDescription: String? {
            switch self {
            case .versionMismatch(let s, let a):
                return a < s ? String(format: L("The server uses data version %d; this app is on %d. Update the app first."), s, a)
                             : String(format: L("The server uses data version %d; this app is on %d. Update the server first."), s, a)
            case .alreadyAdded: return L("This server is already connected.")
            }
        }
    }

    /// 用配对码连一台服务器：换到令牌、存好。
    func add(address: String, code: String, deviceName: String) async throws -> ServerAccount {
        guard let base = ServerClient.normalize(address) else { throw ServerClient.Failure.badAddress }
        guard account(forURL: base.absoluteString) == nil else { throw Failure.alreadyAdded }
        let paired = try await ServerClient.pair(baseURL: base, code: code.trimmingCharacters(in: .whitespaces),
                                                 deviceName: deviceName)
        guard paired.schemaVersion == LibraryStore.schemaVersion else {
            throw Failure.versionMismatch(server: paired.schemaVersion, app: LibraryStore.schemaVersion)
        }
        if let sid = paired.serverId, account(forServerId: sid) != nil { throw Failure.alreadyAdded }
        let a = ServerAccount(id: UUID().uuidString, url: base.absoluteString,
                              deviceId: paired.deviceId, deviceName: deviceName,
                              serverId: paired.serverId, serverName: paired.serverName)
        Keychain.write(Self.tokenKey(a.id), paired.token)
        all.append(a)
        save()
        return a
    }

    func remove(_ id: String) {
        Keychain.delete(Self.tokenKey(id))
        all.removeAll { $0.id == id }
        save()
    }

    /// 按地址找（工作区里记的是地址，见 `SyncClient.metaServerURL`）。
    func account(forURL url: String) -> ServerAccount? {
        let want = ServerClient.normalize(url)?.absoluteString ?? url
        return all.first { $0.url == want }
    }

    func account(forServerId sid: String) -> ServerAccount? { all.first { $0.serverId == sid } }

    /// 先按服务器身份找，找不到再按地址（老记录 / 老缓存没有身份）。
    func account(serverId: String?, url: String?) -> ServerAccount? {
        if let sid = serverId, let a = account(forServerId: sid) { return a }
        return url.flatMap { account(forURL: $0) }
    }

    /// 服务器换了地址（局域网发现里看到同一台出现在新地址上，用户点了「更新地址」）。
    func updateURL(_ id: String, to raw: String) {
        guard let base = ServerClient.normalize(raw), let i = all.firstIndex(where: { $0.id == id }) else { return }
        all[i].url = base.absoluteString
        save()
    }

    func client(_ a: ServerAccount) -> ServerClient? {
        guard let base = URL(string: a.url), let token = Keychain.read(Self.tokenKey(a.id)) else { return nil }
        return ServerClient(baseURL: base, token: token)
    }

    func client(forURL url: String) -> ServerClient? { account(forURL: url).flatMap(client) }

    /// 老记录（配对时服务器还不给身份）补上服务器身份与名字：问一次 `/v1/info`，连不上就算了，下次再补。
    func fillMissingIdentities() async {
        for a in all where a.serverId == nil {
            guard let c = client(a), let info = try? await c.info(), let sid = info.serverId,
                  let i = all.firstIndex(where: { $0.id == a.id }) else { continue }
            all[i].serverId = sid
            all[i].serverName = info.serverName
            save()
        }
    }

    private static func tokenKey(_ id: String) -> String { "server-token-\(id)" }

    private func save() {
        if let data = try? JSONEncoder().encode(all) { UserDefaults.standard.set(data, forKey: key) }
    }
}
