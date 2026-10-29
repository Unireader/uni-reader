import Foundation
#if canImport(dnssd)
import dnssd
#endif

/// 局域网发现：用 Bonjour（DNS-SD）广播「这里有一台 UniReader 服务器」（方案 `SERVER-MODE-PLAN.md §3.7`）。
///
/// - 服务类型 `_unireader-srv._tcp`（与 App 自己的平板服务 `_unireader._tcp` 分开，`PROTOCOL.md §8`），端口 = HTTP 端口。
/// - 服务名 = 服务器名字（`--name`，默认本机名；重名由 Bonjour 自动加序号）。
/// - TXT：`v=1`（发现公告的版本）、`id=<server_id>`（服务器的稳定身份，客户端靠它认出「换了 IP 的同一台」）、
///   `ver=<服务器版本>`、`schema=<数据版本>`（客户端连之前就能提示版本对不上）。**不放配对码**。
///
/// macOS 上走系统自带的 `dnssd`（mDNSResponder）。
/// Linux 上交给系统的 avahi-daemon：起一个 `avahi-publish-service` 子进程（Debian 的 `avahi-utils` 包），
/// 它活着服务就在，它退出 avahi 就撤掉。不链 Avahi 的库，因为 Linux 版是静态编译的（`scripts/build-linux.sh`），
/// 静态二进制没法加载系统的动态库。
/// ⚠️ 子进程跟着服务器走靠的是正常退出（SIGTERM / SIGINT 时 `stop()`）；被 `kill -9` 的话它会留下来接着广播，
/// 所以长期跑请用 systemd（默认整组进程一起杀）。放在 Docker 里还要 host 网络，组播出不了桥接网络。
public final class DiscoveryAdvertiser: @unchecked Sendable {
    public static let serviceType = "_unireader-srv._tcp"

    #if canImport(dnssd)
    private var ref: DNSServiceRef?
    #elseif os(Linux)
    private var child: Process?

    /// `avahi-publish-service` 在哪（没装 avahi-utils 就是 nil）。
    static var avahiPublishService: URL? {
        ["/usr/bin", "/usr/local/bin", "/bin"].lazy
            .map { URL(fileURLWithPath: $0).appendingPathComponent("avahi-publish-service") }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }
    #endif

    public init() {}

    /// TXT 记录的字节：每项「1 字节长度 + key=value」（RFC 6763 §6）。值超过 255 字节的截断。
    public static func txtRecord(_ items: [(String, String)]) -> [UInt8] {
        var out: [UInt8] = []
        for (k, v) in items {
            let entry = Array("\(k)=\(v)".utf8.prefix(255))
            out.append(UInt8(entry.count))
            out += entry
        }
        return out
    }

    /// 开始广播。返回是否成功（失败只影响发现，服务本身照常跑）。
    @discardableResult
    public func start(name: String, port: Int, serverId: String, version: String, schema: Int) -> Bool {
        let items = [("v", "1"), ("id", serverId), ("ver", version), ("schema", String(schema))]
        let txt = Self.txtRecord(items)
        #if canImport(dnssd)
        stop()
        var r: DNSServiceRef?
        let err = txt.withUnsafeBufferPointer { p in
            DNSServiceRegister(&r, 0, 0, name, Self.serviceType, nil, nil, UInt16(port).bigEndian,
                               UInt16(p.count), p.baseAddress, nil, nil)
        }
        guard err == kDNSServiceErr_NoError, let r else { return false }
        ref = r
        return true
        #elseif os(Linux)
        _ = txt
        stop()
        guard let exe = Self.avahiPublishService else {
            print("  （没找到 avahi-publish-service：Debian / Ubuntu 上装 avahi-utils 后重启服务器）")
            return false
        }
        let p = Process()
        p.executableURL = exe
        // -f：avahi-daemon 暂时不在 / 中途重启时不退出，等它回来再登记。输出照常进服务器的日志。
        p.arguments = ["-f", name, Self.serviceType, String(port)] + items.map { "\($0.0)=\($0.1)" }
        p.terminationHandler = { proc in
            print("局域网发现：avahi-publish-service 退出了（状态 \(proc.terminationStatus)），客户端暂时发现不了这台服务器")
        }
        do { try p.run() } catch {
            print("  （启动 avahi-publish-service 失败：\(error)）")
            return false
        }
        // 参数不对之类会立刻退出：等半秒看它还在不在
        Thread.sleep(forTimeInterval: 0.5)
        guard p.isRunning else { return false }
        child = p
        return true
        #else
        _ = txt
        return false
        #endif
    }

    public func stop() {
        #if canImport(dnssd)
        if let r = ref { DNSServiceRefDeallocate(r) }
        ref = nil
        #elseif os(Linux)
        if let p = child {
            p.terminationHandler = nil      // 主动停的，不报「退出了」
            if p.isRunning { p.terminate() }
        }
        child = nil
        #endif
    }

    deinit { stop() }
}
