import Foundation
import Darwin

enum NetInfo {
    /// 取本机 Wi-Fi/以太网 IPv4 地址（en0 优先），用于生成平板可访问的 URL。
    static func wifiIPv4() -> String? {
        var address: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }

        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let p = ptr {
            defer { ptr = p.pointee.ifa_next }
            let flags = Int32(p.pointee.ifa_flags)
            guard (flags & (IFF_UP | IFF_RUNNING)) == (IFF_UP | IFF_RUNNING),
                  let addr = p.pointee.ifa_addr,
                  addr.pointee.sa_family == UInt8(AF_INET) else { continue }

            let name = String(cString: p.pointee.ifa_name)
            guard name == "en0" || name == "en1" else { continue }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(addr, socklen_t(addr.pointee.sa_len),
                           &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                let ip = String(cString: host)
                if name == "en0" { return ip }   // en0 优先，立即返回
                address = ip
            }
        }
        return address
    }
}
