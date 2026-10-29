import Foundation
import Network
import Combine

/// 局域网里的 UniReader 服务器（Bonjour `_unireader-srv._tcp`，方案 `SERVER-MODE-PLAN.md §3.7`）。
/// 设置 ›「服务器」开着时才浏览（`start` / `stop`）。
///
/// `NWBrowser` 只给服务名和 TXT，不给地址：要地址就连一下、拿到对端地址马上断开（`resolve`）。
/// 只要 IPv4——拼出来的 `http://ip:port` 要能直接填进地址框，IPv6 链路本地地址带网卡后缀，填进去也用不了。
@MainActor
final class ServerDiscovery: ObservableObject {
    struct Found: Identifiable, Equatable {
        var id: String { name }          // 服务名在同一网络里唯一（重名 Bonjour 会自动加序号）
        let name: String
        let serverId: String?
        let version: String?
        let schema: Int?
        /// 解析出来的基础地址（`http://ip:port`）；还没解析出来 = nil。
        var address: String?
    }

    static let serviceType = "_unireader-srv._tcp"

    @Published private(set) var found: [Found] = []

    private var browser: NWBrowser?
    private var resolving: [String: NWConnection] = [:]

    func start() {
        guard browser == nil else { return }
        let b = NWBrowser(for: .bonjourWithTXTRecord(type: Self.serviceType, domain: nil), using: .tcp)
        b.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor in self?.update(results) }
        }
        b.start(queue: .main)
        browser = b
    }

    func stop() {
        browser?.cancel()
        browser = nil
        for c in resolving.values { c.cancel() }
        resolving = [:]
        found = []
    }

    private func update(_ results: Set<NWBrowser.Result>) {
        var next: [Found] = []
        for r in results {
            guard case .service(let name, _, _, _) = r.endpoint else { continue }
            var txt: [String: String] = [:]
            if case .bonjour(let record) = r.metadata { txt = record.dictionary }
            let old = found.first { $0.name == name }
            next.append(Found(name: name, serverId: txt["id"], version: txt["ver"],
                              schema: txt["schema"].flatMap { Int($0) }, address: old?.address))
            if old?.address == nil { resolve(name: name, endpoint: r.endpoint) }
        }
        found = next.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func resolve(name: String, endpoint: NWEndpoint) {
        guard resolving[name] == nil else { return }
        let params = NWParameters.tcp
        if let ip = params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options { ip.version = .v4 }
        let c = NWConnection(to: endpoint, using: params)
        resolving[name] = c
        c.stateUpdateHandler = { [weak self, weak c] state in
            switch state {
            case .ready:
                if case .hostPort(let host, let port)? = c?.currentPath?.remoteEndpoint {
                    let h: String
                    switch host {
                    case .ipv4(let a): h = "\(a)"
                    case .ipv6(let a): h = "[\(a)]"
                    case .name(let n, _): h = n
                    @unknown default: h = "\(host)"
                    }
                    let address = "http://\(h):\(port.rawValue)"
                    Task { @MainActor in self?.setAddress(name, address) }
                }
                c?.cancel()
            case .failed, .cancelled:
                Task { @MainActor in self?.resolving[name] = nil }
            default:
                break
            }
        }
        c.start(queue: .main)
    }

    private func setAddress(_ name: String, _ address: String) {
        guard let i = found.firstIndex(where: { $0.name == name }) else { return }
        found[i].address = address
    }
}
