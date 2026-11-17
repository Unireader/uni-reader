import Foundation

// 套件第五批（2026-11-17，`ANIM-BLOCK-PLAN.md §15`）：IP 地址分类与 CIDR。
// `ipclass`：A~E 五类地址的格式（`bits`）；`ipaddr`：一个地址 → 二进制、类别、掩码、按位与求网络地址、广播地址、可用主机数（竖式 `sheet`）；
// `supernet`：路由聚合（逐位比共同前缀）；`subnet`：借位划分子网（按个数或按主机数）；`lpm`：路由表最长前缀匹配。
// 规矩同 `AnimKits.swift`：结果由算法算出来；生成的文字与安卓 `AnimKits5.kt` 逐字相同（跨端向量）。
// 竖式的列：第 p 位（0 起）在第 p + p / 8 列，每 8 位后一列是点，一个地址占 35 列。

extension AnimKits {
    static let names5 = ["ipclass", "ipaddr", "supernet", "subnet", "lpm"]

    static func generate5(_ name: String, _ a: inout Args, _ L: Words) throws -> Kit? {
        switch name {
        case "ipclass": return try ipclassKit(&a, L)
        case "ipaddr": return try ipaddrKit(&a, L)
        case "supernet": return try supernetKit(&a, L)
        case "subnet": return try subnetKit(&a, L)
        case "lpm": return try lpmKit(&a, L)
        default: return nil
        }
    }

    private static func s5(_ caption: String, _ actions: [String]) -> [String] {
        ["step " + caption.replacingOccurrences(of: "#", with: "＃")] + actions.map { "  " + $0 }
    }

    // MARK: - 公用

    static func parseIPv4(_ s: String) throws -> Int {
        let parts = s.trimmingCharacters(in: .whitespaces).components(separatedBy: ".")
        guard parts.count == 4 else { throw AnimParseError("“\(s)” is not an IPv4 address like 192.168.1.10") }
        var v = 0
        for p in parts {
            guard !p.isEmpty, p.count <= 3, p.allSatisfy({ $0.isASCII && $0.isNumber }), let b = Int(p), b <= 255 else {
                throw AnimParseError("“\(s)” is not an IPv4 address like 192.168.1.10")
            }
            v = v * 256 + b
        }
        return v
    }

    /// `a.b.c.d` 或 `a.b.c.d/n`。
    static func parseCIDR(_ s: String) throws -> (addr: Int, len: Int?) {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard let slash = t.firstIndex(of: "/") else { return (try parseIPv4(t), nil) }
        let lenText = String(t[t.index(after: slash)...])
        guard let n = Int(lenText), (0...32).contains(n), lenText.allSatisfy({ $0.isASCII && $0.isNumber }) else {
            throw AnimParseError("“\(s)”: the prefix length after / is 0…32")
        }
        return (try parseIPv4(String(t[..<slash])), n)
    }

    static func ipMask(_ n: Int) -> Int { n == 0 ? 0 : (0xFFFF_FFFF << (32 - n)) & 0xFFFF_FFFF }

    static func ipText(_ v: Int) -> String { [24, 16, 8, 0].map { String((v >> $0) & 255) }.joined(separator: ".") }

    /// 掩码 → 前缀长度（必须是连续的 1）。
    static func maskLength(_ m: Int) throws -> Int {
        for n in 0...32 where ipMask(n) == m { return n }
        throw AnimParseError("\(ipText(m)) is not a valid mask (the 1s must be contiguous from the left)")
    }

    /// 35 列的二进制写法（每 8 位一个点）；第 upTo 位起写空格（竖式里空格 = 那一格不写）。
    static func ipBinary(_ v: Int, upTo: Int = 32) -> String {
        var out = ""
        for c in 0..<35 {
            if c % 9 == 8 {
                out += (c / 9 + 1) * 8 < upTo ? "." : " "
            } else {
                let p = c - c / 9
                out += p < upTo ? String((v >> (31 - p)) & 1) : " "
            }
        }
        while out.hasSuffix(" ") { out.removeLast() }
        return out
    }

    static func ipCol(_ p: Int) -> Int { p + p / 8 }

    /// 第 a 位到第 b 位（不含）的列范围，按字节切开（不含中间的点）。
    static func ipColRanges(_ a: Int, _ b: Int) -> [String] {
        var out: [String] = []
        var p = a
        while p < b {
            let end = min(b, (p / 8 + 1) * 8)
            out.append(end - 1 == p ? "\(ipCol(p))" : "\(ipCol(p))..\(ipCol(end - 1))")
            p = end
        }
        return out
    }

    static func sup(_ n: Int) -> String { String(String(n).map { superscript[$0]! }) }

    /// 类别：字母、前导位数。
    static func ipClass(_ v: Int) -> (String, Int) {
        let b = v >> 24
        if b < 128 { return ("A", 1) }
        if b < 192 { return ("B", 2) }
        if b < 224 { return ("C", 3) }
        if b < 240 { return ("D", 4) }
        return ("E", 4)
    }

    /// 私有 / 特殊地址的一句说明（没有就空）。
    static func ipSpecial(_ v: Int, _ L: Words) -> String {
        let b0 = v >> 24, b1 = (v >> 16) & 255
        if b0 == 10 || (b0 == 172 && (16...31).contains(b1)) || (b0 == 192 && b1 == 168) {
            return L.t("；这是私有地址（10.0.0.0/8、172.16.0.0/12、192.168.0.0/16），只在内部网络用，路由器不转发到因特网",
                       "; this is a private address (10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16): internal only, not routed on the Internet")
        }
        if b0 == 127 { return L.t("；127 开头是环回地址，用来测试本机", "; 127.x.x.x is loopback, for testing this host") }
        if v == 0 { return L.t("；0.0.0.0 表示「本网络上的本主机」", "; 0.0.0.0 means \"this host on this network\"") }
        if v == 0xFFFF_FFFF { return L.t("；255.255.255.255 是本网络上的广播", "; 255.255.255.255 is the broadcast on this network") }
        return ""
    }

    // MARK: - 五类地址

    private static func ipclassKit(_ a: inout Args, _ L: Words) throws -> Kit {
        try a.checkUnused(["lang"])
        let net = L.t("网络号", "network"), host = L.t("主机号", "host")
        let cls: [(String, String, String)] = [
            ("A", "0:1, \(net):7, \(host):24",
             L.t("A 类：第 1 位是 0，网络号 8 位（含这 1 位），主机号 24 位；第一个字节 1~126（0 和 127 另有用途），默认掩码 255.0.0.0；可指派网络 2⁷ − 2 = 126 个，每个网络最多 2²⁴ − 2 = 16777214 台主机",
                 "Class A: first bit 0, an 8-bit network number (that bit included), 24-bit host; first byte 1–126 (0 and 127 are special), default mask 255.0.0.0; 2⁷ − 2 = 126 networks of up to 2²⁴ − 2 = 16777214 hosts")),
            ("B", "10:2, \(net):14, \(host):16",
             L.t("B 类：前 2 位是 10，网络号 16 位，主机号 16 位；第一个字节 128~191，默认掩码 255.255.0.0；可指派网络 2¹⁴ − 1 = 16383 个（128.0 不指派），每个网络最多 2¹⁶ − 2 = 65534 台主机",
                 "Class B: first bits 10, 16-bit network, 16-bit host; first byte 128–191, default mask 255.255.0.0; 2¹⁴ − 1 = 16383 networks (128.0 unassigned) of up to 2¹⁶ − 2 = 65534 hosts")),
            ("C", "110:3, \(net):21, \(host):8",
             L.t("C 类：前 3 位是 110，网络号 24 位，主机号 8 位；第一个字节 192~223，默认掩码 255.255.255.0；可指派网络 2²¹ − 1 = 2097151 个（192.0.0 不指派），每个网络最多 2⁸ − 2 = 254 台主机",
                 "Class C: first bits 110, 24-bit network, 8-bit host; first byte 192–223, default mask 255.255.255.0; 2²¹ − 1 = 2097151 networks (192.0.0 unassigned) of up to 2⁸ − 2 = 254 hosts")),
            ("D", "1110:4, \(L.t("多播组地址", "multicast group")):28",
             L.t("D 类：前 4 位是 1110，第一个字节 224~239，是多播地址，不分网络号和主机号", "Class D: first bits 1110, first byte 224–239: multicast, no network / host split")),
            ("E", "1111:4, \(L.t("保留", "reserved")):28",
             L.t("E 类：前 4 位是 1111，第一个字节 240~255，保留今后使用", "Class E: first bits 1111, first byte 240–255: reserved for future use")),
        ]
        func name(_ c: String) -> String { L.t("\(c)类", "Class\(c)") }
        var lines = cls.map { "bits \(name($0.0)) = \($0.1)" }
        var prev: String?
        for (c, _, cap) in cls {
            var acts = prev.map { ["unmark \($0)"] } ?? []
            acts += ["mark \(name(c)) active", "mark \(name(c))[0] new"]
            lines += s5(cap, acts)
            prev = name(c)
        }
        lines += s5(L.t("特殊地址：主机号全 0 是网络地址、全 1 是广播地址，都不能分给主机；127.x.x.x 是环回地址；0.0.0.0 表示本网络上的本主机；255.255.255.255 是本网络广播。私有地址：10.0.0.0/8、172.16.0.0/12、192.168.0.0/16，路由器不转发到因特网",
                        "Special addresses: host part all 0 = the network address, all 1 = broadcast, neither goes to a host; 127.x.x.x is loopback; 0.0.0.0 is this host on this network; 255.255.255.255 broadcasts on this network. Private: 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, never routed on the Internet"),
                    ["unmark \(name("E"))"] + cls.map { "mark \(name($0.0))[0] active" })
        return Kit(title: L.t("IP 地址的五类（分类编址）", "The five classes of IPv4 addresses"), lines: lines)
    }

    // MARK: - 一个地址：网络地址、广播地址、主机数

    private static func ipaddrKit(_ a: inout Args, _ L: Words) throws -> Kit {
        let usage = "usage: kit ipaddr ip=192.168.1.10/24   (or ip=… mask=255.255.255.0, or just ip=… for its class)"
        guard let raw = a.string("ip") else { throw AnimParseError(usage) }
        let maskText = a.string("mask")
        try a.checkUnused(["ip", "mask", "lang"])
        let (addr, slash) = try parseCIDR(raw)
        var prefix = slash
        if let m = maskText {
            guard slash == nil else { throw AnimParseError("give /n or mask=, not both") }
            prefix = try maskLength(try parseIPv4(m))
        }
        let (cls, lead) = ipClass(addr)
        let classful = prefix == nil
        if classful {
            switch cls {
            case "A": prefix = 8
            case "B": prefix = 16
            case "C": prefix = 24
            default: break
            }
        }
        let S = L.t("计算", "work"), H = L.t("结构", "layout")
        let vN = L.t("网络地址", "network"), vB = L.t("广播地址", "broadcast"), vC = L.t("可用主机", "hosts")
        let net = L.t("网络号", "network"), host = L.t("主机号", "host"), pre = L.t("网络前缀", "prefix")
        var fields: String
        var netFields: [Int] = [], hostField = -1
        if classful {
            switch cls {
            case "A": fields = "0:1, \(net):7, \(host):24"; netFields = [0, 1]; hostField = 2
            case "B": fields = "10:2, \(net):14, \(host):16"; netFields = [0, 1]; hostField = 2
            case "C": fields = "110:3, \(net):21, \(host):8"; netFields = [0, 1]; hostField = 2
            case "D": fields = "1110:4, \(L.t("多播组地址", "multicast group")):28"
            default: fields = "1111:4, \(L.t("保留", "reserved")):28"
            }
        } else {
            let n = prefix!
            if n == 0 { fields = "\(host):32"; hostField = 0 } else if n == 32 { fields = "\(pre):32"; netFields = [0] } else {
                fields = "\(pre):\(n), \(host):\(32 - n)"; netFields = [0]; hostField = 1
            }
        }
        var lines = ["bits \(H) = \(fields)", "sheet \(S)"]
        if let _ = prefix { lines += ["var \(vN) = ?", "var \(vB) = ?", "var \(vC) = ?", "row \(vN) \(vB)"] }
        let bytes = [24, 16, 8, 0].map { (addr >> $0) & 255 }
        lines += s5(L.t("把 4 个字节都写成 8 位二进制：", "Write each of the 4 bytes as 8 bits: ") + bytes.map { "\($0) = \(binary($0, 8))" }.joined(separator: L.t("，", ", ")),
                    ["write \(S)[0,0] " + q(ipBinary(addr)), "label \(S)[0] " + q(L.t("IP 地址 ", "address ") + ipText(addr))])
        let leadBits = binary(addr >> (32 - lead), lead)
        let range: String
        switch cls {
        case "A": range = "0~127"
        case "B": range = "128~191"
        case "C": range = "192~223"
        case "D": range = "224~239"
        default: range = "240~255"
        }
        var cap = L.t("第一个字节 \(bytes[0]) = \(binary(bytes[0], 8))：前 \(lead) 位是 \(leadBits) → \(cls) 类（第一个字节 \(range)）",
                      "First byte \(bytes[0]) = \(binary(bytes[0], 8)): the leading bits \(leadBits) → class \(cls) (first byte \(range))")
        var acts = ["mark \(S)[0,0..\(lead - 1)] active", "mark \(H)[0] active"]
        if classful {
            switch cls {
            case "A", "B", "C":
                cap += L.t("，默认掩码 \(ipText(ipMask(prefix!)))：网络号 \(prefix!) 位、主机号 \(32 - prefix!) 位",
                           ", default mask \(ipText(ipMask(prefix!))): \(prefix!)-bit network, \(32 - prefix!)-bit host")
            case "D": cap += L.t("，是多播地址，不分网络号和主机号", ": a multicast address, no network / host split")
            default: cap += L.t("，保留今后使用", ": reserved for future use")
            }
        } else {
            cap += L.t("；但这里给了 /\(prefix!)（CIDR，无分类编址）：网络前缀按 /\(prefix!) 算，与类别无关",
                       "; but /\(prefix!) is given (CIDR, classless): the prefix decides, not the class")
        }
        guard let n = prefix else {
            lines += s5(cap + ipSpecial(addr, L), acts)
            return Kit(title: L.t("IP 地址 \(ipText(addr)) 的类别", "The class of \(ipText(addr))"), lines: lines)
        }
        lines += s5(cap, acts)
        let h = 32 - n, m = ipMask(n), netAddr = addr & m, bc = netAddr | (0xFFFF_FFFF ^ m)
        acts = ["unmark \(S)[0,0..\(lead - 1)]", "unmark \(H)[0]", "write \(S)[1,0] " + q(ipBinary(m)),
                "label \(S)[1] " + q(L.t("掩码 ", "mask ") + "\(ipText(m))（/\(n)）")]
        acts += ipColRanges(0, n).map { "mark \(S)[1,\($0)] active" }
        acts += netFields.map { "mark \(H)[\($0)] active" }
        lines += s5(L.t("/\(n)：前 \(n) 位是 1、后 \(h) 位是 0 → 子网掩码 \(ipText(m))", "/\(n): \(n) ones then \(h) zeros → mask \(ipText(m))"), acts)
        acts = ipColRanges(0, n).map { "unmark \(S)[1,\($0)]" }
        acts += ["rule \(S)[1,0..34]", "write \(S)[2,0] " + q(ipBinary(netAddr)), "label \(S)[2] " + q(L.t("网络地址 ", "network ") + ipText(netAddr)),
                 "set \(vN) = \(ipText(netAddr))/\(n)", "mark \(vN) active"]
        acts += ipColRanges(0, n).map { "mark \(S)[2,\($0)] active" }
        lines += s5(L.t("IP 地址与掩码逐位相与：前 \(n) 位照抄，后 \(h) 位全变成 0 → 网络地址 \(ipText(netAddr))",
                        "AND the address with the mask bit by bit: the first \(n) bits stay, the last \(h) become 0 → network \(ipText(netAddr))"), acts)
        acts = ["unmark \(vN)", "write \(S)[3,0] " + q(ipBinary(bc)), "label \(S)[3] " + q(L.t("广播地址 ", "broadcast ") + ipText(bc)),
                "set \(vB) = \(ipText(bc))", "mark \(vB) active"]
        acts += ipColRanges(n, 32).map { "mark \(S)[3,\($0)] done" }
        if hostField >= 0 { acts += netFields.map { "unmark \(H)[\($0)]" } + ["mark \(H)[\(hostField)] done"] }
        lines += s5(L.t("网络前缀不变，主机号 \(h) 位全写成 1 → 广播地址 \(ipText(bc))", "Keep the prefix, set all \(h) host bits to 1 → broadcast \(ipText(bc))"), acts)
        var hc: String
        var count: String
        switch h {
        case 0:
            count = "1"
            hc = L.t("/32：只有这一个地址（常用于指向一台主机的路由）", "/32: just this one address (a host route)")
        case 1:
            count = "2"
            hc = L.t("/31：只有 2 个地址，用在点对点链路上两端各一个", "/31: only 2 addresses, one for each end of a point-to-point link")
        default:
            let c = (1 << h) - 2
            count = String(c)
            hc = L.t("主机号 \(h) 位：2\(sup(h)) − 2 = \(c) 个可用地址（去掉全 0 的网络地址和全 1 的广播地址），\(ipText(netAddr + 1)) ~ \(ipText(bc - 1))",
                     "\(h) host bits: 2\(sup(h)) − 2 = \(c) usable addresses (minus the all-0 network and all-1 broadcast), \(ipText(netAddr + 1)) – \(ipText(bc - 1))")
            if addr == netAddr { hc += L.t("；\(ipText(addr)) 本身就是网络地址，不能分给主机", "; \(ipText(addr)) itself is the network address and cannot go to a host") }
            if addr == bc { hc += L.t("；\(ipText(addr)) 本身就是广播地址，不能分给主机", "; \(ipText(addr)) itself is the broadcast address and cannot go to a host") }
        }
        acts = ["unmark \(vB)", "set \(vC) = \(count)", "mark \(vC) done"]
        if hostField >= 0 { acts.append("set \(H)[\(hostField)] = " + q(L.t("\(count) 台", "\(count) hosts"))) }
        lines += s5(hc + ipSpecial(addr, L), acts)
        return Kit(title: L.t("\(ipText(addr))/\(n)：网络地址与广播地址", "\(ipText(addr))/\(n): network and broadcast"), lines: lines)
    }

    // MARK: - 路由聚合

    private static func cidrList(_ s: String, _ k: String, min: Int, max: Int) throws -> [(Int, Int)] {
        var out: [(Int, Int)] = []
        for part in s.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).components(separatedBy: ",") {
            let t = part.trimmingCharacters(in: .whitespaces)
            if t.isEmpty { continue }
            let (v, n) = try parseCIDR(t)
            guard let n else { throw AnimParseError("\(k)=: “\(t)” needs a prefix length, like \(t)/24") }
            guard v & ipMask(n) == v else { throw AnimParseError("\(k)=: \(t) is not a network address (host bits must be 0; did you mean \(ipText(v & ipMask(n)))/\(n)?)") }
            out.append((v, n))
        }
        guard out.count >= min, out.count <= max else { throw AnimParseError("\(k)= takes \(min)…\(max) networks like 172.18.129.0/24, 172.18.130.0/24") }
        return out
    }

    private static func supernetKit(_ a: inout Args, _ L: Words) throws -> Kit {
        guard let raw = a.string("nets") else { throw AnimParseError("usage: kit supernet nets=172.18.129.0/24,172.18.130.0/24,172.18.132.0/24") }
        try a.checkUnused(["nets", "lang"])
        let nets = try cidrList(raw, "nets", min: 2, max: 8)
        let S = L.t("聚合", "aggregate")
        let minN = nets.map(\.1).min()!
        var common = 0
        while common < minN, nets.allSatisfy({ ($0.0 >> (31 - common)) & 1 == (nets[0].0 >> (31 - common)) & 1 }) { common += 1 }
        var lines = ["sheet \(S)"]
        var acts: [String] = []
        for (i, (v, n)) in nets.enumerated() { acts += ["write \(S)[\(i),0] " + q(ipBinary(v)), "label \(S)[\(i)] " + q("\(ipText(v))/\(n)")] }
        lines += s5(L.t("把要聚合的 \(nets.count) 个网络写成二进制，上下对齐", "Write the \(nets.count) networks in binary, one under another"), acts)
        acts = []
        for i in nets.indices {
            acts += ipColRanges(0, common).map { "mark \(S)[\(i),\($0)] done" }
            if common < minN { acts.append("mark \(S)[\(i),\(ipCol(common))] wrong") }
        }
        lines += s5(common < minN
                    ? L.t("从左往右逐位比：前 \(common) 位都相同，第 \(common + 1) 位开始不同", "Compare bit by bit from the left: the first \(common) bits agree, bit \(common + 1) differs")
                    : L.t("从左往右逐位比：前 \(common) 位都相同，再往后就超出最短的网络前缀 /\(minN) 了", "Compare bit by bit from the left: the first \(common) bits agree, and the shortest prefix is /\(minN)"),
                    acts)
        let agg = nets[0].0 & ipMask(common)
        let r = nets.count
        // 原来几个网络合起来有多少个地址（重叠的只算一次）
        let spans = nets.map { ($0.0, $0.0 + (1 << (32 - $0.1))) }.sorted { $0.0 < $1.0 }
        var covered = 0, end = -1
        for (lo, hi) in spans {
            if lo >= end { covered += hi - lo; end = hi } else if hi > end { covered += hi - end; end = hi }
        }
        let size = 1 << (32 - common)
        var cap = L.t("共同前缀 \(common) 位、后面补 0 → 聚合成 \(ipText(agg))/\(common)（掩码 \(ipText(ipMask(common)))），路由表里一条代替 \(nets.count) 条",
                      "Keep the \(common) common bits and fill with 0 → \(ipText(agg))/\(common) (mask \(ipText(ipMask(common)))): one route instead of \(nets.count)")
        if size > covered {
            cap += L.t("；注意 /\(common) 共 \(size) 个地址，原来这几个网络合计 \(covered) 个，多包含了 \(size - covered) 个不在原网络里的地址",
                       "; note the /\(common) holds \(size) addresses but the networks only \(covered): \(size - covered) extra addresses are included")
        } else {
            cap += L.t("；正好覆盖原来这几个网络", "; it covers exactly these networks")
        }
        acts = ["rule \(S)[\(r - 1),0..34]", "write \(S)[\(r),0] " + q(ipBinary(agg)), "label \(S)[\(r)] " + q(L.t("聚合 ", "aggregate ") + "\(ipText(agg))/\(common)")]
        acts += ipColRanges(0, common).map { "mark \(S)[\(r),\($0)] active" }
        lines += s5(cap, acts)
        return Kit(title: L.t("路由聚合（构成超网）", "Route aggregation (supernetting)"), lines: lines)
    }

    // MARK: - 划分子网

    private static func subnetKit(_ a: inout Args, _ L: Words) throws -> Kit {
        let usage = "usage: kit subnet net=192.168.1.0/24 n=4   (or hosts=50 instead of n=)"
        guard let raw = a.string("net") else { throw AnimParseError(usage) }
        let (v, pOpt) = try parseCIDR(raw)
        guard let p = pOpt else { throw AnimParseError("net= needs a prefix length, like \(raw)/24") }
        guard v & ipMask(p) == v else { throw AnimParseError("net=: \(raw) is not a network address (host bits must be 0; did you mean \(ipText(v & ipMask(p)))/\(p)?)") }
        let hasN = a.values["n"] != nil, hasH = a.values["hosts"] != nil
        guard hasN != hasH else { throw AnimParseError(hasN ? "give n= or hosts=, not both" : usage) }
        var k: Int, h: Int
        var want = 0
        if hasN {
            want = try a.int("n", default: 2, 2...16)
            k = 0
            while (1 << k) < want { k += 1 }
            h = 32 - p - k
        } else {
            want = try a.int("hosts", default: 2, 1...16_777_214)
            h = 2
            while (1 << h) - 2 < want { h += 1 }
            k = 32 - p - h
        }
        try a.checkUnused(["net", "n", "hosts", "lang"])
        guard k >= 1, h >= 2 else { throw AnimParseError("/\(p) has only \(32 - p) host bits: not enough to split that way") }
        guard k <= 4 else { throw AnimParseError("that makes \(1 << k) subnets; at most 16") }
        let np = p + k, m = ipMask(np)
        let S = L.t("子网", "subnets"), H = L.t("结构", "layout")
        var lines = ["bits \(H) = \(L.t("网络前缀", "prefix")):\(p), \(L.t("子网号", "subnet")):\(k), \(L.t("主机号", "host")):\(h)", "sheet \(S)"]
        let cap0 = hasN
            ? L.t("要分 \(want) 个子网：2\(sup(k)) = \(1 << k) ≥ \(want)，从主机号借 \(k) 位当子网号",
                  "\(want) subnets needed: 2\(sup(k)) = \(1 << k) ≥ \(want), so borrow \(k) host bits for the subnet number")
            : L.t("每个子网要放 \(want) 台主机：2\(sup(h)) − 2 = \((1 << h) - 2) ≥ \(want)，主机号留 \(h) 位，剩下 \(k) 位当子网号 → 2\(sup(k)) = \(1 << k) 个子网",
                  "\(want) hosts per subnet: 2\(sup(h)) − 2 = \((1 << h) - 2) ≥ \(want), so keep \(h) host bits and use the other \(k) for the subnet → 2\(sup(k)) = \(1 << k) subnets")
        lines += s5(cap0 + L.t("；新前缀 /\(np)，掩码 \(ipText(m))，每个子网可用 2\(sup(h)) − 2 = \((1 << h) - 2) 个地址",
                               "; new prefix /\(np), mask \(ipText(m)), 2\(sup(h)) − 2 = \((1 << h) - 2) usable addresses each"),
                    ["mark \(H)[1] active", "set \(H)[1] = " + q(L.t("\(k) 位", "\(k) bits")), "set \(H)[2] = " + q(L.t("\(h) 位", "\(h) bits"))])
        for i in 0..<(1 << k) {
            let sn = v | (i << h), bc = sn | ((1 << h) - 1)
            var acts = ["write \(S)[\(i),0] " + q(ipBinary(sn)), "label \(S)[\(i)] " + q(L.t("子网\(i + 1) ", "subnet \(i + 1) ") + "\(ipText(sn))/\(np)")]
            acts += ipColRanges(p, np).map { "mark \(S)[\(i),\($0)] active" }
            if i > 0 { acts += ipColRanges(p, np).map { "mark \(S)[\(i - 1),\($0)] done" } }
            lines += s5(L.t("子网\(i + 1)：子网号 \(binary(i, k)) → 网络 \(ipText(sn))/\(np)，可用 \(ipText(sn + 1)) ~ \(ipText(bc - 1))，广播 \(ipText(bc))",
                            "Subnet \(i + 1): subnet bits \(binary(i, k)) → \(ipText(sn))/\(np), hosts \(ipText(sn + 1)) – \(ipText(bc - 1)), broadcast \(ipText(bc))"), acts)
        }
        var end = L.t("共 \(1 << k) 个子网，每个 \(1 << h) 个地址；按 CIDR，子网号全 0、全 1 的子网也能用（老教材按 RFC 950 不用这两个，那样只剩 \((1 << k) - 2) 个）",
                      "\(1 << k) subnets of \(1 << h) addresses; under CIDR the all-0 and all-1 subnets are usable too (older textbooks, following RFC 950, drop them, leaving \((1 << k) - 2))")
        if hasN && (1 << k) > want { end += L.t("；只要 \(want) 个，用前 \(want) 个即可", "; only \(want) are needed, use the first \(want)") }
        lines += s5(end, ipColRanges(p, np).map { "mark \(S)[\((1 << k) - 1),\($0)] done" } + ["unmark \(H)[1]"])
        return Kit(title: L.t("划分子网：\(ipText(v))/\(p)", "Subnetting \(ipText(v))/\(p)"), lines: lines)
    }

    // MARK: - 最长前缀匹配

    private static func lpmKit(_ a: inout Args, _ L: Words) throws -> Kit {
        let usage = "usage: kit lpm dst=192.168.1.37 routes=\"192.168.1.0/24 R1, 192.168.1.32/27 R2, 0.0.0.0/0 R3\""
        guard let d = a.string("dst"), let raw = a.string("routes") else { throw AnimParseError(usage) }
        try a.checkUnused(["dst", "routes", "lang"])
        let dst = try parseIPv4(d)
        var routes: [(v: Int, n: Int, hop: String)] = []
        for part in raw.components(separatedBy: ",") {
            let words = part.split(whereSeparator: { $0 == " " }).map(String.init)
            guard let first = words.first else { continue }
            let (v, nOpt) = try parseCIDR(first)
            guard let n = nOpt else { throw AnimParseError("routes=: “\(first)” needs a prefix length, like \(first)/24") }
            guard v & ipMask(n) == v else { throw AnimParseError("routes=: \(first) is not a network address (did you mean \(ipText(v & ipMask(n)))/\(n)?)") }
            routes.append((v, n, words.dropFirst().joined(separator: " ")))
        }
        guard (1...8).contains(routes.count) else { throw AnimParseError("routes= takes 1…8 entries like 192.168.1.0/24 R1") }
        let S = L.t("匹配", "match")
        var lines = ["sheet \(S)"]
        lines += s5(L.t("把目的地址 \(ipText(dst)) 写成二进制，下面逐条拿路由表的前缀来比", "Write the destination \(ipText(dst)) in binary and compare each route's prefix with it"),
                    ["write \(S)[0,0] " + q(ipBinary(dst)), "label \(S)[0] " + q(L.t("目的地址 ", "destination ") + ipText(dst)), "rule \(S)[0,0..34]"])
        var matched: [Int] = []
        for (i, r) in routes.enumerated() {
            let row = i + 1
            let hop = r.hop.isEmpty ? "" : " → \(r.hop)"
            var acts = ["label \(S)[\(row)] " + q("\(ipText(r.v))/\(r.n)\(hop)")]
            if r.n > 0 { acts.insert("write \(S)[\(row),0] " + q(ipBinary(r.v, upTo: r.n)), at: 0) }
            var diff = -1
            for p in 0..<r.n where ((dst >> (31 - p)) & 1) != ((r.v >> (31 - p)) & 1) { diff = p; break }
            let cap: String
            if diff < 0 {
                matched.append(i)
                acts += ipColRanges(0, r.n).map { "mark \(S)[\(row),\($0)] done" }
                cap = r.n == 0
                    ? L.t("默认路由 0.0.0.0/0：前缀 0 位，任何地址都匹配", "Default route 0.0.0.0/0: a 0-bit prefix matches everything")
                    : L.t("\(ipText(r.v))/\(r.n)：目的地址的前 \(r.n) 位与它完全相同 → 匹配", "\(ipText(r.v))/\(r.n): the first \(r.n) bits of the destination are the same → match")
            } else {
                acts += ipColRanges(0, diff).map { "mark \(S)[\(row),\($0)] done" }
                acts.append("mark \(S)[\(row),\(ipCol(diff))] wrong")
                if diff + 1 < r.n { acts += ipColRanges(diff + 1, r.n).map { "mark \(S)[\(row),\($0)] muted" } }
                cap = L.t("\(ipText(r.v))/\(r.n)：第 \(diff + 1) 位不同 → 不匹配", "\(ipText(r.v))/\(r.n): bit \(diff + 1) differs → no match")
            }
            lines += s5(cap, acts)
        }
        if let best = matched.max(by: { routes[$0].n < routes[$1].n }) {
            let r = routes[best]
            let list = matched.map { "/\(routes[$0].n)" }.joined(separator: L.listSep)
            var acts = ipColRanges(0, r.n).map { "mark \(S)[\(best + 1),\($0)] active" }
            acts.append("mark \(S)[0,0..34] active")
            lines += s5(L.t("匹配的有 \(list)，取前缀最长的 \(ipText(r.v))/\(r.n)", "Matches: \(list); the longest prefix wins: \(ipText(r.v))/\(r.n)")
                        + (r.hop.isEmpty ? "" : L.t(" → 下一跳 \(r.hop)", " → next hop \(r.hop)")), acts)
        } else {
            lines += s5(L.t("一条都不匹配（也没有默认路由）→ 丢弃，向源点发 ICMP 终点不可达", "Nothing matches (and there is no default route) → drop it and send the source an ICMP destination unreachable"),
                        ["mark \(S)[0,0..34] wrong"])
        }
        return Kit(title: L.t("最长前缀匹配：目的地址 \(ipText(dst))", "Longest prefix match for \(ipText(dst))"), lines: lines)
    }
}
