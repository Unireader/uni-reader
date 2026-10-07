import Combine
import Darwin
import Foundation
import Network
import SystemConfiguration

enum NetInfo {
    /// 一个本机 IPv4 地址 + 它所在的网卡。
    struct Address: Equatable, Hashable {
        let ip: String
        /// BSD 名（en0 / en7 / utun4 …）
        let interface: String
        /// 给人看的网卡名（系统设置里那个：Wi-Fi / 以太网 / 雷雳网桥…；VPN 隧道系统没给名字，记作 VPN）
        let label: String
    }

    /// 本机**全部**在用的 IPv4 地址（不含回环）。平板服务与 MCP 在所有网卡上监听，哪个地址都能连进来，
    /// 只取 en0/en1 一个会漏掉有线网卡、USB 网卡、VPN（如 Tailscale）上的地址。
    /// 排序 = 系统的优先顺序（系统设置 › 网络的服务顺序，当前默认出口那张排第一），第一个就是默认给出去的地址；
    /// 系统顺序里没有的（VPN 隧道等）排在后面，自分配地址（169.254.*，没拿到 DHCP）垫底。
    static func ipv4Addresses() -> [Address] {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return [] }
        defer { freeifaddrs(ifaddr) }

        let names = displayNames()
        let pref = preferenceOrder()
        var out: [Address] = []
        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let p = ptr {
            defer { ptr = p.pointee.ifa_next }
            let flags = Int32(p.pointee.ifa_flags)
            guard (flags & (IFF_UP | IFF_RUNNING)) == (IFF_UP | IFF_RUNNING), flags & IFF_LOOPBACK == 0,
                  let addr = p.pointee.ifa_addr,
                  addr.pointee.sa_family == UInt8(AF_INET) else { continue }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(addr, socklen_t(addr.pointee.sa_len),
                              &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let ip = String(cString: host)
            let name = String(cString: p.pointee.ifa_name)
            guard !out.contains(where: { $0.ip == ip }) else { continue }
            out.append(Address(ip: ip, interface: name, label: names[name] ?? fallbackLabel(name)))
        }
        func key(_ a: Address) -> (Int, Int, String, String) {
            let p = pref[a.interface] ?? 1000
            return (a.ip.hasPrefix("169.254.") ? p + 10_000 : p, fallbackRank(a.interface), a.interface, a.ip)
        }
        return out.sorted { key($0) < key($1) }
    }

    /// 系统的网络优先顺序（BSD 名 → 名次，越小越优先）：当前默认出口那张网卡（`PrimaryInterface`）排 0，
    /// 其余按系统设置 › 网络的「服务顺序」排。VPN 隧道当了默认出口也不算——平板在局域网里，二维码给隧道地址连不上。
    private static func preferenceOrder() -> [String: Int] {
        guard let store = SCDynamicStoreCreate(nil, "UniReader.NetInfo" as CFString, nil, nil) else { return [:] }
        func dict(_ key: String) -> [String: Any]? { SCDynamicStoreCopyValue(store, key as CFString) as? [String: Any] }
        var m: [String: Int] = [:]
        let order = dict("Setup:/Network/Global/IPv4")?["ServiceOrder"] as? [String] ?? []
        for (i, sid) in order.enumerated() {
            if let dev = dict("Setup:/Network/Service/\(sid)/Interface")?["DeviceName"] as? String, m[dev] == nil {
                m[dev] = i + 1
            }
        }
        if let primary = dict("State:/Network/Global/IPv4")?["PrimaryInterface"] as? String, !isTunnel(primary) {
            m[primary] = 0
        }
        return m
    }

    /// 系统顺序取不到 / 并列时的兜底：en0 → en1 → 其它 en* → 网桥 → 其它（VPN 等）。
    private static func fallbackRank(_ n: String) -> Int {
        if n == "en0" { return 0 }
        if n == "en1" { return 1 }
        if n.hasPrefix("en") { return 2 }
        if n.hasPrefix("bridge") { return 3 }
        return 4
    }

    private static func isTunnel(_ bsd: String) -> Bool {
        ["utun", "ipsec", "ppp"].contains(where: bsd.hasPrefix)
    }

    /// BSD 名 → 系统设置里的网卡名（本地化过的）。
    private static func displayNames() -> [String: String] {
        guard let all = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] else { return [:] }
        var m: [String: String] = [:]
        for i in all {
            if let bsd = SCNetworkInterfaceGetBSDName(i) as String?,
               let name = SCNetworkInterfaceGetLocalizedDisplayName(i) as String? { m[bsd] = name }
        }
        return m
    }

    private static func fallbackLabel(_ bsd: String) -> String {
        isTunnel(bsd) ? L("VPN") : bsd
    }
}

/// 本机地址的监视器：网络一变（换 Wi-Fi、插拔网线、开关 VPN）就重扫一遍全部 IPv4。
/// 平板服务面板的地址 / 二维码、MCP 的地址列表与来源检查都跟着它。**只在主线程读写。**
final class NetWatch: ObservableObject {
    static let shared = NetWatch()

    @Published private(set) var addresses: [NetInfo.Address] = NetInfo.ipv4Addresses()

    private let monitor = NWPathMonitor()

    private init() {
        monitor.pathUpdateHandler = { [weak self] _ in
            DispatchQueue.main.async { self?.rescanSoon() }
        }
        monitor.start(queue: DispatchQueue(label: "tech.xvanturing.unireader.netwatch"))
    }

    /// 网络变化的通知到了，地址未必已经配好（DHCP 要一会儿）：当下扫一次，1s、3s 后各补一次。
    private func rescanSoon() {
        rescan()
        for delay in [1.0, 3.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.rescan() }
        }
    }

    func rescan() {
        let now = NetInfo.ipv4Addresses()
        if now != addresses { addresses = now }
    }

    /// 给别人用的那个地址：[preferred] 还在就用它，否则排第一的（系统优先的那张网卡）；一个都没有 = 127.0.0.1。
    func host(preferring preferred: String? = nil) -> String {
        if let preferred, addresses.contains(where: { $0.ip == preferred }) { return preferred }
        return addresses.first?.ip ?? "127.0.0.1"
    }
}
