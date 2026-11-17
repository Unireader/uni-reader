import Foundation

// 套件第四批（2026-11-17，`ANIM-BLOCK-PLAN.md §14`）：计算机网络的首部与分组。
// `header`：IPv4 / IPv6 / TCP / UDP 首部格式逐字段讲（`bits` 元素）；给了 `hex=` 就逐字段从字节里取值、换算，IPv4 再验算首部检验和。
// `encap`：应用数据 → 运输层 → 网络层 → 链路层 → 物理层逐层封装，再逐层拆封（`packet` 元素，括号标出每层的数据单元）。
// `frag`：IP 分片：每片最多放多少数据、片偏移、MF / DF（`packet` + 表格）。
// 规矩同 `AnimKits.swift`：结果由算法算出来；生成的文字与安卓 `AnimKits4.kt` 逐字相同（跨端向量）。

extension AnimKits {
    static let names4 = ["header", "encap", "frag"]

    static func generate4(_ name: String, _ a: inout Args, _ L: Words) throws -> Kit? {
        switch name {
        case "header": return try headerKit(&a, L)
        case "encap": return try encapKit(&a, L)
        case "frag": return try fragKit(&a, L)
        default: return nil
        }
    }

    private static func s4(_ caption: String, _ actions: [String]) -> [String] {
        ["step " + caption.replacingOccurrences(of: "#", with: "＃")] + actions.map { "  " + $0 }
    }

    // MARK: - 公用

    /// 两位大写十六进制。
    static func hex2(_ b: Int) -> String {
        let s = String(b, radix: 16).uppercased()
        return s.count < 2 ? "0" + s : s
    }

    /// `0x` + 大写十六进制，左补 0 到 digits 位。
    static func hexN(_ v: Int, _ digits: Int) -> String {
        let s = String(v, radix: 16).uppercased()
        return "0x" + String(repeating: "0", count: max(digits - s.count, 0)) + s
    }

    /// `45 00 00 3c`、`4500003C`、`45:00:00:3c`、`0x45 0x00`：去掉空白、逗号、冒号、短横与 0x 前缀后按两位一字节。
    static func parseHex(_ s: String) throws -> [Int] {
        var t = s.replacingOccurrences(of: "0x", with: "").replacingOccurrences(of: "0X", with: "")
        t = String(t.filter { !$0.isWhitespace && $0 != "," && $0 != ":" && $0 != "-" })
        guard !t.isEmpty, t.count % 2 == 0, t.allSatisfy({ $0.isHexDigit && $0.isASCII }) else {
            throw AnimParseError("hex= takes bytes in hexadecimal, like \"45 00 00 3c\" (two digits per byte)")
        }
        var out: [Int] = []
        var i = t.startIndex
        while i < t.endIndex {
            let j = t.index(i, offsetBy: 2)
            out.append(Int(t[i..<j], radix: 16)!)
            i = j
        }
        return out
    }

    /// 从字节串里取第 offset 位起的 count 位（大端，count ≤ 32）。
    static func bitValue(_ bytes: [Int], _ offset: Int, _ count: Int) -> Int {
        var v = 0
        for k in 0..<count {
            let bit = offset + k
            v = (v << 1) | ((bytes[bit / 8] >> (7 - bit % 8)) & 1)
        }
        return v
    }

    static func dotted(_ bytes: [Int], _ at: Int) -> String {
        (0..<4).map { String(bytes[at + $0]) }.joined(separator: ".")
    }

    /// IPv6 地址的标准写法（RFC 5952）：每组去掉前导 0、小写；最长的一段（≥ 2 组）连续全 0 组写成 `::`，一样长取最前面的。
    static func ipv6Text(_ bytes: [Int], _ at: Int) -> String {
        let groups = (0..<8).map { (bytes[at + 2 * $0] << 8) | bytes[at + 2 * $0 + 1] }
        var bestStart = -1, bestLen = 0, k = 0
        while k < 8 {
            if groups[k] == 0 {
                var e = k
                while e < 8 && groups[e] == 0 { e += 1 }
                if e - k > bestLen && e - k >= 2 { bestStart = k; bestLen = e - k }
                k = e
            } else {
                k += 1
            }
        }
        let text = groups.map { String($0, radix: 16) }
        if bestStart < 0 { return text.joined(separator: ":") }
        let head = text[..<bestStart].joined(separator: ":"), tail = text[(bestStart + bestLen)...].joined(separator: ":")
        return head + "::" + tail
    }

    /// 首部检验和验算：按 16 位相加、进位回卷到最低位。
    static func onesSum(_ bytes: [Int], _ count: Int) -> Int {
        var sum = 0
        var i = 0
        while i < count {
            sum += (bytes[i] << 8) | (i + 1 < count ? bytes[i + 1] : 0)
            sum = (sum & 0xFFFF) + (sum >> 16)
            i += 2
        }
        return sum
    }

    static func portName(_ p: Int, _ L: Words) -> String? {
        switch p {
        case 20: return L.t("FTP 数据", "FTP data")
        case 21: return "FTP"
        case 22: return "SSH"
        case 23: return "TELNET"
        case 25: return "SMTP"
        case 53: return "DNS"
        case 67: return L.t("DHCP 服务器", "DHCP server")
        case 68: return L.t("DHCP 客户", "DHCP client")
        case 69: return "TFTP"
        case 80: return "HTTP"
        case 110: return "POP3"
        case 143: return "IMAP"
        case 161: return "SNMP"
        case 443: return "HTTPS"
        default: return nil
        }
    }

    static func protocolName(_ p: Int) -> String? {
        switch p {
        case 0: return "Hop-by-Hop"
        case 1: return "ICMP"
        case 2: return "IGMP"
        case 6: return "TCP"
        case 17: return "UDP"
        case 41: return "IPv6"
        case 43: return "Routing"
        case 44: return "Fragment"
        case 50: return "ESP"
        case 58: return "ICMPv6"
        case 59: return "No Next Header"
        case 60: return "Destination Options"
        case 89: return "OSPF"
        default: return nil
        }
    }

    // MARK: - 首部格式

    private struct HField {
        let zh: String
        let en: String
        let bits: Int
        var variable = false
        let dz: String
        let de: String
    }

    private static func headerFields(_ proto: String) -> [HField] {
        switch proto {
        case "ipv6":
            return [
                HField(zh: "版本", en: "Version", bits: 4, dz: "版本（4 位）：IPv6 为 6", de: "Version (4 bits): 6 for IPv6"),
                HField(zh: "通信量类", en: "Traffic Class", bits: 8, dz: "通信量类（8 位）：区分数据报的类别或优先级，相当于 IPv4 的区分服务",
                       de: "Traffic Class (8 bits): class or priority, like the DS field of IPv4"),
                HField(zh: "流标号", en: "Flow Label", bits: 20, dz: "流标号（20 位）：同一个「流」（如一路实时音视频）的数据报标同一个流标号，路由器可以按流处理",
                       de: "Flow Label (20 bits): datagrams of one flow (say a live video stream) carry the same label so routers can treat them alike"),
                HField(zh: "有效载荷长度", en: "Payload Length", bits: 16, dz: "有效载荷长度（16 位）：基本首部后面的字节数（扩展首部 + 数据），不含 40 字节的基本首部，最大 65535",
                       de: "Payload Length (16 bits): bytes after the base header (extension headers + data), not counting the 40-byte base header; at most 65535"),
                HField(zh: "下一个首部", en: "Next Header", bits: 8, dz: "下一个首部（8 位）：没有扩展首部时相当于 IPv4 的协议字段（6 TCP、17 UDP、58 ICMPv6）；有扩展首部时指出第一个扩展首部的类型",
                       de: "Next Header (8 bits): with no extension header it is IPv4's Protocol (6 TCP, 17 UDP, 58 ICMPv6); otherwise the type of the first extension header"),
                HField(zh: "跳数限制", en: "Hop Limit", bits: 8, dz: "跳数限制（8 位）：相当于 IPv4 的 TTL，每经过一个路由器减 1，减到 0 就丢弃",
                       de: "Hop Limit (8 bits): IPv4's TTL; each router subtracts 1 and drops the datagram at 0"),
                HField(zh: "源地址", en: "Source Address", bits: 128, dz: "源地址（128 位）：发送方的 IPv6 地址", de: "Source Address (128 bits): the sender's IPv6 address"),
                HField(zh: "目的地址", en: "Destination Address", bits: 128, dz: "目的地址（128 位）：接收方的 IPv6 地址", de: "Destination Address (128 bits): the receiver's IPv6 address"),
            ]
        case "tcp":
            var f = [
                HField(zh: "源端口", en: "Source Port", bits: 16, dz: "源端口（16 位）：发送方的应用进程", de: "Source Port (16 bits): the sending process"),
                HField(zh: "目的端口", en: "Destination Port", bits: 16, dz: "目的端口（16 位）：交给接收方的哪个应用进程（80 HTTP、443 HTTPS、25 SMTP……）",
                       de: "Destination Port (16 bits): which process at the receiver gets the data (80 HTTP, 443 HTTPS, 25 SMTP …)"),
                HField(zh: "序号", en: "Sequence Number", bits: 32, dz: "序号（32 位）：TCP 给字节流的每个字节编号，这里是本报文段数据第一个字节的序号",
                       de: "Sequence Number (32 bits): TCP numbers every byte of the stream; this is the number of the first data byte in this segment"),
                HField(zh: "确认号", en: "Acknowledgment Number", bits: 32, dz: "确认号（32 位）：期望收到对方下一个报文段数据第一个字节的序号；确认号为 N 表示到 N − 1 为止都已正确收到（ACK = 1 时才有效）",
                       de: "Acknowledgment Number (32 bits): the next byte expected from the other side; N means everything up to N − 1 arrived (valid only when ACK = 1)"),
                HField(zh: "数据偏移", en: "Data Offset", bits: 4, dz: "数据偏移（4 位）：其实就是首部长度，单位 4 字节；最小 5（20 字节），最大 15（60 字节）",
                       de: "Data Offset (4 bits): the header length in 4-byte units; 5 (20 bytes) to 15 (60 bytes)"),
                HField(zh: "保留", en: "Reserved", bits: 6, dz: "保留（6 位）：留给以后用，目前为 0", de: "Reserved (6 bits): for future use, 0 for now"),
            ]
            for flag in ["URG", "ACK", "PSH", "RST", "SYN", "FIN"] { f.append(HField(zh: flag, en: flag, bits: 1, dz: "", de: "")) }
            f += [
                HField(zh: "窗口", en: "Window", bits: 16, dz: "窗口（16 位）：发送本报文段一方的接收窗口——从确认号算起，还允许对方发多少字节（流量控制）",
                       de: "Window (16 bits): the sender's receive window — how many bytes, counted from the acknowledgment number, the other side may still send (flow control)"),
                HField(zh: "检验和", en: "Checksum", bits: 16, dz: "检验和（16 位）：检验首部和数据，计算时在前面加 12 字节的伪首部",
                       de: "Checksum (16 bits): covers the header and the data, computed with a 12-byte pseudo header in front"),
                HField(zh: "紧急指针", en: "Urgent Pointer", bits: 16, dz: "紧急指针（16 位）：URG = 1 时才有意义，指出紧急数据有多少字节（紧急数据放在数据的最前面）",
                       de: "Urgent Pointer (16 bits): meaningful only when URG = 1; how many bytes of urgent data lead the data"),
            ]
            return f
        case "udp":
            return [
                HField(zh: "源端口", en: "Source Port", bits: 16, dz: "源端口（16 位）：需要对方回信时用，不需要时可以全 0", de: "Source Port (16 bits): for replies; may be all 0 when none is needed"),
                HField(zh: "目的端口", en: "Destination Port", bits: 16, dz: "目的端口（16 位）：交给接收方的哪个应用进程（53 DNS、67/68 DHCP、69 TFTP……）",
                       de: "Destination Port (16 bits): which process at the receiver gets the data (53 DNS, 67/68 DHCP, 69 TFTP …)"),
                HField(zh: "长度", en: "Length", bits: 16, dz: "长度（16 位）：整个用户数据报（首部 + 数据）的字节数，最小 8", de: "Length (16 bits): bytes in the whole datagram (header + data), at least 8"),
                HField(zh: "检验和", en: "Checksum", bits: 16, dz: "检验和（16 位）：检验首部和数据（前面加 12 字节伪首部）；不用时全 0",
                       de: "Checksum (16 bits): covers header and data (with a 12-byte pseudo header); all 0 when unused"),
            ]
        default:
            return [
                HField(zh: "版本", en: "Version", bits: 4, dz: "版本（4 位）：IP 的版本，IPv4 为 4", de: "Version (4 bits): the IP version, 4 for IPv4"),
                HField(zh: "首部长度", en: "IHL", bits: 4, dz: "首部长度（4 位）：单位是 4 字节；最小 5（20 字节，没有选项），最大 15（60 字节）",
                       de: "IHL, header length (4 bits): in 4-byte units; 5 (20 bytes, no options) to 15 (60 bytes)"),
                HField(zh: "区分服务", en: "DS", bits: 8, dz: "区分服务（8 位）：希望得到哪种服务（优先级等），一般不用", de: "Differentiated Services (8 bits): the kind of service wanted (priority …), seldom used"),
                HField(zh: "总长度", en: "Total Length", bits: 16, dz: "总长度（16 位）：首部 + 数据的总长，单位字节，最大 65535；在以太网上不能超过 MTU 1500，否则要分片",
                       de: "Total Length (16 bits): header + data in bytes, at most 65535; on Ethernet it must fit the 1500-byte MTU or be fragmented"),
                HField(zh: "标识", en: "Identification", bits: 16, dz: "标识（16 位）：每发一个数据报加 1；分片时各片标识相同，接收方据此把同一数据报的片重组起来",
                       de: "Identification (16 bits): a counter per datagram; all fragments of one datagram share it so the receiver can reassemble them"),
                HField(zh: "标志", en: "Flags", bits: 3, dz: "标志（3 位）：最高位保留；中间位 DF = 1 表示不许分片；最低位 MF = 1 表示后面还有分片",
                       de: "Flags (3 bits): the first is reserved; DF = 1 means do not fragment; MF = 1 means more fragments follow"),
                HField(zh: "片偏移", en: "Fragment Offset", bits: 13, dz: "片偏移（13 位）：本片数据在原数据报里从第几个字节开始，单位 8 字节——所以除最后一片外，每片的数据长度都是 8 的倍数",
                       de: "Fragment Offset (13 bits): where this fragment's data starts in the original datagram, in 8-byte units — so every fragment but the last carries a multiple of 8 bytes"),
                HField(zh: "生存时间", en: "TTL", bits: 8, dz: "生存时间 TTL（8 位）：每经过一个路由器减 1，减到 0 就丢弃，防止数据报在网络里无限兜圈子",
                       de: "Time to Live (8 bits): each router subtracts 1 and drops the datagram at 0, so it cannot loop forever"),
                HField(zh: "协议", en: "Protocol", bits: 8, dz: "协议（8 位）：数据部分交给哪个协议：1 ICMP、2 IGMP、6 TCP、17 UDP、89 OSPF",
                       de: "Protocol (8 bits): who gets the data: 1 ICMP, 2 IGMP, 6 TCP, 17 UDP, 89 OSPF"),
                HField(zh: "首部检验和", en: "Header Checksum", bits: 16, dz: "首部检验和（16 位）：只检验首部、不检验数据；每经过一个路由器都要重算（TTL 变了）",
                       de: "Header Checksum (16 bits): covers the header only, not the data; recomputed at every router (the TTL changes)"),
                HField(zh: "源地址", en: "Source Address", bits: 32, dz: "源地址（32 位）：发送方的 IP 地址", de: "Source Address (32 bits): the sender's IP address"),
                HField(zh: "目的地址", en: "Destination Address", bits: 32, dz: "目的地址（32 位）：接收方的 IP 地址", de: "Destination Address (32 bits): the receiver's IP address"),
            ]
        }
    }

    private static func headerKit(_ a: inout Args, _ L: Words) throws -> Kit {
        let proto = try choice(&a, "proto", ["ipv4", "ipv6", "tcp", "udp"], default: "ipv4")
        let hexText = a.string("hex")
        try a.checkUnused(["proto", "hex", "lang"])
        var fields = headerFields(proto)
        let pname: String
        switch proto {
        case "ipv6": pname = "IPv6"
        case "tcp": pname = "TCP"
        case "udp": pname = "UDP"
        default: pname = "IPv4"
        }
        let H = L.t(pname + "首部", pname)
        let fixedBytes = proto == "ipv6" ? 40 : proto == "udp" ? 8 : 20
        var bytes: [Int] = []
        var headerBytes = fixedBytes
        if let hexText {
            bytes = try parseHex(hexText)
            guard bytes.count >= fixedBytes else {
                throw AnimParseError("hex= has \(bytes.count) byte(s); a\(proto == "ipv4" || proto == "ipv6" ? "n" : "") \(pname) header needs at least \(fixedBytes)")
            }
            if proto == "ipv4" || proto == "tcp" {
                let hl = proto == "ipv4" ? bytes[0] & 0x0F : bytes[12] >> 4
                guard hl >= 5 else { throw AnimParseError("the header length field is \(hl) (× 4 = \(hl * 4) bytes); it must be at least 5") }
                headerBytes = hl * 4
                guard bytes.count >= headerBytes else {
                    throw AnimParseError("the header length field says \(headerBytes) bytes but hex= has only \(bytes.count)")
                }
            }
            if proto == "ipv4" { guard bytes[0] >> 4 == 4 else { throw AnimParseError("the first 4 bits are \(bytes[0] >> 4), not 4: this is not an IPv4 header") } }
            if proto == "ipv6" { guard bytes[0] >> 4 == 6 else { throw AnimParseError("the first 4 bits are \(bytes[0] >> 4), not 6: this is not an IPv6 header") } }
        }
        let options = headerBytes - fixedBytes
        if proto == "ipv4" || proto == "tcp" {
            let ozh = proto == "ipv4"
                ? "可选字段（0~40 字节）：用于排错、测量、安全等，很少使用；长度不是 4 字节的整数倍时用填充补齐"
                : "选项（0~40 字节）：最大报文段长度 MSS、窗口扩大、时间戳、选择确认 SACK 等；不是 4 字节的整数倍时用填充补齐"
            let oen = proto == "ipv4"
                ? "Options (0–40 bytes): debugging, measurement, security …, rarely used; padded to a multiple of 4 bytes"
                : "Options (0–40 bytes): maximum segment size (MSS), window scale, timestamps, selective ACK …; padded to a multiple of 4 bytes"
            if hexText == nil {
                fields.append(HField(zh: proto == "ipv4" ? "可选字段（长度可变）" : "选项（长度可变）", en: "Options (variable)", bits: 24, variable: true, dz: ozh, de: oen))
                fields.append(HField(zh: "填充", en: "Padding", bits: 8, variable: true, dz: ozh, de: oen))
            } else if options > 0 {
                fields.append(HField(zh: proto == "ipv4" ? "可选字段" : "选项", en: "Options", bits: options * 8, dz: ozh, de: oen))
            }
        }
        var lines = ["bits \(H) = " + fields.map { (L.zh ? $0.zh : $0.en) + ":" + ($0.variable ? "*" : "") + String($0.bits) }.joined(separator: ", ")]
        if !bytes.isEmpty {
            for row in 0..<(headerBytes / 4) {
                lines.append("label \(H)[\(row)] " + q((0..<4).map { hex2(bytes[row * 4 + $0]) }.joined(separator: " ")))
            }
        }
        let flagStart = 6, flagEnd = 11   // TCP 六个控制位的字段下标
        var prev: [Int] = []
        // 连续的下标写成一个范围（`H[6..11]`）
        func ranges(_ idx: [Int]) -> [String] {
            var out: [String] = []
            var k = 0
            while k < idx.count {
                var e = k
                while e + 1 < idx.count && idx[e + 1] == idx[e] + 1 { e += 1 }
                out.append(e == k ? "\(idx[k])" : "\(idx[k])..\(idx[e])")
                k = e + 1
            }
            return out
        }
        func focus(_ idx: [Int]) -> [String] {
            var acts = ranges(prev.filter { !idx.contains($0) }).map { "unmark \(H)[\($0)]" }
            acts += ranges(idx).map { "mark \(H)[\($0)] active" }
            prev = idx
            return acts
        }
        if bytes.isEmpty {
            // 只讲格式：一个字段一步（TCP 六个控制位合一步，可选字段与填充合一步）
            var i = 0
            while i < fields.count {
                if proto == "tcp" && i == flagStart {
                    let cap = L.t("6 个控制位（各 1 位）：URG 紧急指针有效；ACK 确认号有效（连接建立后都是 1）；PSH 尽快交付；RST 连接出错，释放后重连；SYN 同步，建立连接（握手的前两次）；FIN 释放连接",
                                  "6 control bits (1 bit each): URG urgent pointer valid; ACK acknowledgment valid (1 after the connection is set up); PSH push to the application; RST reset the connection; SYN synchronize, open a connection; FIN finish, close it")
                    lines += s4(cap, focus(Array(flagStart...flagEnd)))
                    i = flagEnd + 1
                    continue
                }
                if fields[i].variable {
                    lines += s4(L.t(fields[i].dz, fields[i].de), focus(Array(i..<fields.count)))
                    break
                }
                lines += s4(L.t(fields[i].dz, fields[i].de), focus([i]))
                i += 1
            }
            let summary: String
            switch proto {
            case "ipv6":
                summary = L.t("基本首部固定 40 字节。和 IPv4 比：去掉了首部长度、标识 / 标志 / 片偏移（分片只在源点做，放进分片扩展首部）、首部检验和；选项改成扩展首部",
                              "The base header is always 40 bytes. Compared with IPv4: no header length, no identification / flags / fragment offset (only the source fragments, in a Fragment extension header), no header checksum; options became extension headers")
            case "udp":
                summary = L.t("UDP 首部只有 8 字节：无连接、尽最大努力交付、面向报文（应用交下来的报文不拆分、不合并）",
                              "The UDP header is only 8 bytes: connectionless, best-effort, message-oriented (each application message is sent as is)")
            case "tcp":
                summary = L.t("固定部分 20 字节（前 5 行）+ 选项 0~40 字节：TCP 首部 20~60 字节，长度看数据偏移",
                              "Fixed part 20 bytes (the first 5 rows) + options 0–40 bytes: a TCP header is 20–60 bytes; the data offset tells which")
            default:
                summary = L.t("固定部分 20 字节（前 5 行）+ 可选字段 0~40 字节：IP 首部 20~60 字节，长度看首部长度字段",
                              "Fixed part 20 bytes (the first 5 rows) + options 0–40 bytes: an IP header is 20–60 bytes; the IHL field tells which")
            }
            var acts = ranges(prev).map { "unmark \(H)[\($0)]" }
            let fixedCount = fields.filter { !$0.variable }.count
            acts.append("mark \(H)[0..\(fixedCount - 1)] done")
            lines += s4(summary, acts)
            return Kit(title: L.t("\(pname) 首部格式", "\(pname) header format"), lines: lines)
        }

        // 从字节里逐字段取值
        var offsets: [Int] = []
        var o = 0
        for f in fields { offsets.append(o); o += f.bits }
        func val(_ i: Int) -> Int { bitValue(bytes, offsets[i], fields[i].bits) }
        func bin(_ i: Int) -> String { binary(val(i), fields[i].bits) }
        func setv(_ i: Int, _ v: String) -> String { "set \(H)[\(i)] = " + q(v) }
        func port(_ p: Int) -> String { portName(p, L).map { L.t("\(p)（\($0)）", "\(p) (\($0))") } ?? String(p) }
        let rest = bytes.count - headerBytes
        var final = ""
        switch proto {
        case "ipv4":
            let ihl = val(1), total = val(3), flags = val(5), off = val(6), ttl = val(7), p = val(8), ck = val(9)
            let pn = protocolName(p)
            lines += s4(L.t("版本 = \(bin(0)) = \(val(0))：IPv4", "Version = \(bin(0)) = \(val(0)): IPv4"), focus([0]) + [setv(0, String(val(0)))])
            lines += s4(L.t("首部长度 = \(bin(1)) = \(ihl)，单位 4 字节：首部 \(ihl) × 4 = \(ihl * 4) 字节" + (ihl > 5 ? "，其中可选字段 \(options) 字节" : "，没有可选字段"),
                            "IHL = \(bin(1)) = \(ihl) in 4-byte units: the header is \(ihl) × 4 = \(ihl * 4) bytes" + (ihl > 5 ? ", \(options) of them options" : ", no options")),
                        focus([1]) + [setv(1, String(ihl))])
            lines += s4(L.t("区分服务 = \(hexN(val(2), 2))", "Differentiated Services = \(hexN(val(2), 2))"), focus([2]) + [setv(2, hexN(val(2), 2))])
            lines += s4(L.t("总长度 = \(hexN(total, 4)) = \(total) 字节：数据部分 \(total) − \(ihl * 4) = \(total - ihl * 4) 字节",
                            "Total Length = \(hexN(total, 4)) = \(total) bytes: the data is \(total) − \(ihl * 4) = \(total - ihl * 4) bytes"),
                        focus([3]) + [setv(3, String(total))])
            lines += s4(L.t("标识 = \(hexN(val(4), 4)) = \(val(4))", "Identification = \(hexN(val(4), 4)) = \(val(4))"), focus([4]) + [setv(4, String(val(4)))])
            let df = (flags >> 1) & 1, mf = flags & 1
            lines += s4(L.t("标志 = \(bin(5))：DF = \(df)（\(df == 1 ? "不许分片" : "允许分片")），MF = \(mf)（\(mf == 1 ? "后面还有分片" : "后面没有分片了")）",
                            "Flags = \(bin(5)): DF = \(df) (\(df == 1 ? "do not fragment" : "may fragment")), MF = \(mf) (\(mf == 1 ? "more fragments follow" : "no more fragments"))"),
                        focus([5]) + [setv(5, bin(5))])
            lines += s4(L.t("片偏移 = \(off)，单位 8 字节：本片数据从原数据报的第 \(off) × 8 = \(off * 8) 字节开始" + (off == 0 && mf == 0 ? "；MF = 0 且片偏移 = 0，说明没有分片" : ""),
                            "Fragment Offset = \(off) in 8-byte units: this data starts at byte \(off) × 8 = \(off * 8) of the original" + (off == 0 && mf == 0 ? "; MF = 0 and offset 0: not fragmented" : "")),
                        focus([6]) + [setv(6, String(off))])
            lines += s4(L.t("生存时间 = \(hexN(ttl, 2)) = \(ttl)：最多还能经过 \(ttl) 个路由器", "TTL = \(hexN(ttl, 2)) = \(ttl): at most \(ttl) more routers"), focus([7]) + [setv(7, String(ttl))])
            lines += s4(L.t("协议 = \(p)" + (pn.map { "：数据部分交给 \($0)" } ?? ""), "Protocol = \(p)" + (pn.map { ": the data goes to \($0)" } ?? "")),
                        focus([8]) + [setv(8, pn.map { "\(p) \($0)" } ?? String(p))])
            lines += s4(L.t("首部检验和 = \(hexN(ck, 4))", "Header Checksum = \(hexN(ck, 4))"), focus([9]) + [setv(9, hexN(ck, 4))])
            lines += s4(L.t("源地址 = \((12..<16).map { hex2(bytes[$0]) }.joined(separator: " ")) = \(dotted(bytes, 12))",
                            "Source Address = \((12..<16).map { hex2(bytes[$0]) }.joined(separator: " ")) = \(dotted(bytes, 12))"),
                        focus([10]) + [setv(10, dotted(bytes, 12))])
            lines += s4(L.t("目的地址 = \((16..<20).map { hex2(bytes[$0]) }.joined(separator: " ")) = \(dotted(bytes, 16))",
                            "Destination Address = \((16..<20).map { hex2(bytes[$0]) }.joined(separator: " ")) = \(dotted(bytes, 16))"),
                        focus([11]) + [setv(11, dotted(bytes, 16))])
            if options > 0 {
                lines += s4(L.t("可选字段 \(options) 字节", "Options: \(options) bytes"), focus([12]) + [setv(12, (20..<headerBytes).map { hex2(bytes[$0]) }.joined(separator: " "))])
            }
            let sum = onesSum(bytes, headerBytes)
            let ok = sum == 0xFFFF
            lines += s4(L.t("验算检验和：首部 \(headerBytes / 2) 个 16 位字相加（进位加回最低位）= \(hexN(sum, 4))，取反 = \(hexN(0xFFFF - sum, 4))" + (ok ? "，为 0：首部没有差错" : "，不为 0：首部有差错，丢弃"),
                            "Check: the \(headerBytes / 2) 16-bit words summed with end-around carry = \(hexN(sum, 4)), complemented = \(hexN(0xFFFF - sum, 4))" + (ok ? ": 0, the header is intact" : ": not 0, the header is corrupted and dropped")),
                        ranges(prev.filter { $0 != 9 }).map { "unmark \(H)[\($0)]" } + ["mark \(H)[9] \(ok ? "done" : "wrong")"])
            prev = []
            final = L.t("首部 \(ihl * 4) 字节 + 数据 \(total - ihl * 4) 字节 = 总长度 \(total) 字节", "Header \(ihl * 4) bytes + data \(total - ihl * 4) bytes = total length \(total) bytes")
                + (pn.map { L.t("，数据交给 \($0)", ", data for \($0)") } ?? "")
        case "ipv6":
            let tc = val(1), fl = val(2), plen = val(3), nh = val(4), hop = val(5)
            let nn = protocolName(nh)
            lines += s4(L.t("版本 = \(bin(0)) = 6：IPv6", "Version = \(bin(0)) = 6: IPv6"), focus([0]) + [setv(0, "6")])
            lines += s4(L.t("通信量类 = \(hexN(tc, 2))（跨了第 1、2 两个字节）", "Traffic Class = \(hexN(tc, 2)) (spans bytes 1 and 2)"), focus([1]) + [setv(1, hexN(tc, 2))])
            lines += s4(L.t("流标号 = \(hexN(fl, 5))" + (fl == 0 ? "：0 表示不属于任何流" : ""), "Flow Label = \(hexN(fl, 5))" + (fl == 0 ? ": 0 means no flow" : "")), focus([2]) + [setv(2, hexN(fl, 5))])
            lines += s4(L.t("有效载荷长度 = \(hexN(plen, 4)) = \(plen) 字节：整个数据报 40 + \(plen) = \(40 + plen) 字节",
                            "Payload Length = \(hexN(plen, 4)) = \(plen) bytes: the whole datagram is 40 + \(plen) = \(40 + plen) bytes"),
                        focus([3]) + [setv(3, String(plen))])
            lines += s4(L.t("下一个首部 = \(nh)" + (nn.map { "：\($0)" } ?? ""), "Next Header = \(nh)" + (nn.map { ": \($0)" } ?? "")),
                        focus([4]) + [setv(4, nn.map { "\(nh) \($0)" } ?? String(nh))])
            lines += s4(L.t("跳数限制 = \(hop)", "Hop Limit = \(hop)"), focus([5]) + [setv(5, String(hop))])
            lines += s4(L.t("源地址 = \(ipv6Text(bytes, 8))（每组去掉前导 0，最长的一串全 0 组写成 ::）",
                            "Source Address = \(ipv6Text(bytes, 8)) (leading zeros dropped, the longest run of zero groups written ::)"),
                        focus([6]) + [setv(6, ipv6Text(bytes, 8))])
            lines += s4(L.t("目的地址 = \(ipv6Text(bytes, 24))", "Destination Address = \(ipv6Text(bytes, 24))"), focus([7]) + [setv(7, ipv6Text(bytes, 24))])
            final = L.t("基本首部 40 字节 + 有效载荷 \(plen) 字节", "Base header 40 bytes + payload \(plen) bytes") + (nn.map { L.t("，下一个是 \($0)", ", next: \($0)") } ?? "")
        case "tcp":
            let sp = val(0), dp = val(1), seq = val(2), ack = val(3), doff = val(4), win = val(12), ck = val(13), urg = val(14)
            lines += s4(L.t("源端口 = \(hexN(sp, 4)) = \(port(sp))", "Source Port = \(hexN(sp, 4)) = \(port(sp))"), focus([0]) + [setv(0, String(sp))])
            lines += s4(L.t("目的端口 = \(hexN(dp, 4)) = \(port(dp))", "Destination Port = \(hexN(dp, 4)) = \(port(dp))"), focus([1]) + [setv(1, String(dp))])
            lines += s4(L.t("序号 = \(hexN(seq, 8)) = \(seq)：本报文段数据的第一个字节编号是 \(seq)",
                            "Sequence Number = \(hexN(seq, 8)) = \(seq): the first data byte here is byte \(seq)"),
                        focus([2]) + [setv(2, String(seq))])
            let ackOn = (bytes[13] >> 4) & 1 == 1
            lines += s4(L.t("确认号 = \(hexN(ack, 8)) = \(ack)" + (ackOn ? "：期望对方下一个字节是 \(ack)" : "（ACK = 0，确认号无效）"),
                            "Acknowledgment Number = \(hexN(ack, 8)) = \(ack)" + (ackOn ? ": expecting byte \(ack) next" : " (ACK = 0: not valid)")),
                        focus([3]) + [setv(3, String(ack))])
            lines += s4(L.t("数据偏移 = \(bin(4)) = \(doff)：首部 \(doff) × 4 = \(doff * 4) 字节", "Data Offset = \(bin(4)) = \(doff): the header is \(doff) × 4 = \(doff * 4) bytes"),
                        focus([4]) + [setv(4, String(doff))])
            lines += s4(L.t("保留 = \(bin(5))", "Reserved = \(bin(5))"), focus([5]) + [setv(5, bin(5))])
            let names = ["URG", "ACK", "PSH", "RST", "SYN", "FIN"]
            let on = (0..<6).filter { val(flagStart + $0) == 1 }.map { names[$0] }
            var meaning: [String] = []
            let has = { (n: String) in on.contains(n) }
            if has("SYN") && !has("ACK") { meaning.append(L.t("连接请求（第一次握手）", "connection request (first handshake)")) }
            if has("SYN") && has("ACK") { meaning.append(L.t("同意建立连接（第二次握手）", "connection accepted (second handshake)")) }
            if has("FIN") { meaning.append(L.t("数据发完了，请求释放连接", "done sending, asking to close")) }
            if has("RST") { meaning.append(L.t("连接出错，要重置", "resetting the connection")) }
            if has("URG") { meaning.append(L.t("有紧急数据", "urgent data present")) }
            let flagText = (on.isEmpty ? L.t("全为 0", "all 0") : on.map { "\($0) = 1" }.joined(separator: L.listSep)) + (meaning.isEmpty ? "" : L.t("：", ": ") + meaning.joined(separator: L.sep))
            lines += s4(L.t("控制位 \((flagStart...flagEnd).map { String(val($0)) }.joined())：", "Control bits \((flagStart...flagEnd).map { String(val($0)) }.joined()): ") + flagText,
                        focus(Array(flagStart...flagEnd)) + (flagStart...flagEnd).map { setv($0, String(val($0))) })
            lines += s4(L.t("窗口 = \(hexN(win, 4)) = \(win)：对方还可以发 \(win) 字节", "Window = \(hexN(win, 4)) = \(win): the other side may send \(win) more bytes"),
                        focus([12]) + [setv(12, String(win))])
            lines += s4(L.t("检验和 = \(hexN(ck, 4))（验算要加伪首部，这里只有 TCP 首部，不验算）", "Checksum = \(hexN(ck, 4)) (checking needs the pseudo header, not given here)"),
                        focus([13]) + [setv(13, hexN(ck, 4))])
            lines += s4(L.t("紧急指针 = \(urg)" + (has("URG") ? "：前 \(urg) 字节是紧急数据" : "（URG = 0，不用看）"), "Urgent Pointer = \(urg)" + (has("URG") ? ": the first \(urg) bytes are urgent" : " (URG = 0: ignored)")),
                        focus([14]) + [setv(14, String(urg))])
            if options > 0 {
                lines += s4(L.t("选项 \(options) 字节", "Options: \(options) bytes"), focus([15]) + [setv(15, (20..<headerBytes).map { hex2(bytes[$0]) }.joined(separator: " "))])
            }
            final = L.t("首部 \(doff * 4) 字节", "Header \(doff * 4) bytes") + (rest > 0 ? L.t("，后面 \(rest) 字节是数据", ", followed by \(rest) data bytes") : "")
        default:   // udp
            let sp = val(0), dp = val(1), len = val(2), ck = val(3)
            lines += s4(L.t("源端口 = \(hexN(sp, 4)) = \(port(sp))", "Source Port = \(hexN(sp, 4)) = \(port(sp))"), focus([0]) + [setv(0, String(sp))])
            lines += s4(L.t("目的端口 = \(hexN(dp, 4)) = \(port(dp))", "Destination Port = \(hexN(dp, 4)) = \(port(dp))"), focus([1]) + [setv(1, String(dp))])
            lines += s4(L.t("长度 = \(hexN(len, 4)) = \(len) 字节：数据 \(len) − 8 = \(len - 8) 字节", "Length = \(hexN(len, 4)) = \(len) bytes: \(len) − 8 = \(len - 8) data bytes"),
                        focus([2]) + [setv(2, String(len))])
            lines += s4(L.t("检验和 = \(hexN(ck, 4))" + (ck == 0 ? "：全 0，没有使用检验和" : ""), "Checksum = \(hexN(ck, 4))" + (ck == 0 ? ": all 0, not used" : "")),
                        focus([3]) + [setv(3, hexN(ck, 4))])
            final = L.t("首部 8 字节 + 数据 \(len - 8) 字节 = \(len) 字节", "Header 8 bytes + data \(len - 8) bytes = \(len) bytes")
        }
        if proto != "ipv4" && proto != "tcp" && rest > 0 { final += L.t("；hex 里后面 \(rest) 字节是数据", "; the remaining \(rest) bytes of hex= are data") }
        if proto == "ipv4" && rest > 0 { final += L.t("；hex 里后面 \(rest) 字节是数据部分", "; the remaining \(rest) bytes of hex= are the data") }
        var acts = ranges(prev).map { "unmark \(H)[\($0)]" }
        acts.append("mark \(H)[0..\(fields.count - 1)] done")
        if proto == "ipv4" && onesSum(bytes, headerBytes) != 0xFFFF { acts.append("mark \(H)[9] wrong") }
        lines += s4(final, acts)
        return Kit(title: L.t("解析 \(pname) 首部", "Decoding an \(pname) header"), lines: lines)
    }

    // MARK: - 逐层封装 / 拆封

    private static func encapKit(_ a: inout Args, _ L: Words) throws -> Kit {
        let transport = try choice(&a, "transport", ["tcp", "udp"], default: "tcp")
        let net = try choice(&a, "net", ["ipv4", "ipv6"], default: "ipv4")
        let mode = try choice(&a, "mode", ["both", "encap"], default: "both")
        let data = try a.int("data", default: 100, 1...65000)
        try a.checkUnused(["data", "transport", "net", "mode", "lang"])
        let tH = transport == "tcp" ? 20 : 8, nH = net == "ipv4" ? 20 : 40
        let T = transport == "tcp" ? "TCP" : "UDP", N = net == "ipv4" ? "IPv4" : "IPv6"
        let P = L.t("分组", "packet")
        let seg = transport == "tcp" ? L.t("TCP 报文段", "TCP segment") : L.t("UDP 用户数据报", "UDP datagram")
        let dgram = L.t("IP 数据报", "IP datagram")
        let ipLen = data + tH + nH
        let pad = max(46 - ipLen, 0)
        let frame = 14 + ipLen + pad + 4
        var lines = ["packet \(P) unit=B = " + L.t("应用数据", "data") + ":\(data)"]
        lines += s4(L.t("应用层：要发的数据（报文）\(data) 字节", "Application layer: \(data) bytes of data (a message)"), ["mark \(P)[0] done"])
        lines += s4(L.t("运输层：加上 \(tH) 字节的 \(T) 首部（源端口、目的端口……），成为\(seg)，共 \(data + tH) 字节",
                        "Transport layer: a \(tH)-byte \(T) header (source and destination ports …) makes a \(seg) of \(data + tH) bytes"),
                    ["insert \(P) 0 " + q(T + L.t("首部", " header") + ":\(tH)"), "group \(P)[0..1] " + q("\(seg) \(data + tH) B")])
        let protoField = net == "ipv4" ? L.t("协议字段", "Protocol") : L.t("下一个首部字段", "Next Header")
        lines += s4(L.t("网络层：加上 \(nH) 字节的 \(N) 首部（源 IP、目的 IP，\(protoField) = \(transport == "tcp" ? 6 : 17)），成为 IP 数据报，共 \(ipLen) 字节",
                        "Network layer: a \(nH)-byte \(N) header (source and destination IP, \(protoField) = \(transport == "tcp" ? 6 : 17)) makes an IP datagram of \(ipLen) bytes"),
                    ["insert \(P) 0 " + q(N + L.t("首部", " header") + ":\(nH)"), "group \(P)[0..2] " + q("\(dgram) \(ipLen) B")])
        var link = ["insert \(P) 0 " + q(L.t("以太网首部", "Ethernet header") + ":14")]
        var cap = L.t("数据链路层：加上 14 字节的首部（目的 MAC 6 + 源 MAC 6 + 类型 2，类型 \(net == "ipv4" ? "0x0800 = IPv4" : "0x86DD = IPv6")）和 4 字节的尾部 FCS，成为以太网帧",
                      "Link layer: a 14-byte header (destination MAC 6 + source MAC 6 + type 2, type \(net == "ipv4" ? "0x0800 = IPv4" : "0x86DD = IPv6")) and a 4-byte FCS trailer make an Ethernet frame")
        var last = 4
        if pad > 0 {
            link.append("insert \(P) 4 " + q(L.t("填充", "pad") + ":\(pad)"))
            last = 5
            cap += L.t("；数据部分只有 \(ipLen) 字节，不足 46 字节，补 \(pad) 字节填充，使帧长达到最短 64 字节", "; the payload is only \(ipLen) bytes, under 46, so \(pad) bytes of padding bring the frame to the 64-byte minimum")
        }
        link += ["insert \(P) \(last) " + q("FCS:4"), "group \(P)[0..\(last)] " + q(L.t("以太网帧", "Ethernet frame") + " \(frame) B")]
        cap += L.t("，共 \(frame) 字节", ", \(frame) bytes in all")
        if ipLen > 1500 { cap += L.t("。注意：IP 数据报 \(ipLen) 字节超过以太网 MTU 1500，实际要先分片（kit frag）", ". Note: the \(ipLen)-byte datagram exceeds Ethernet's 1500-byte MTU and would have to be fragmented first (kit frag)") }
        lines += s4(cap, link)
        lines += s4(L.t("物理层：前面再加 8 字节前同步码（7 字节前同步码 + 1 字节帧开始定界符），作为比特流发出去；它不算在帧长里",
                        "Physical layer: an 8-byte preamble (7 bytes + a 1-byte start frame delimiter) goes in front and the bits are sent; it does not count in the frame length"),
                    ["insert \(P) 0 " + q(L.t("前同步码", "preamble") + ":8"), "mark \(P)[0] muted"])
        if mode == "both" {
            lines += s4(L.t("接收方物理层：去掉前同步码，把帧交给数据链路层", "Receiver, physical layer: strip the preamble and pass the frame up"), ["remove \(P) 0"])
            var unlink = ["remove \(P) \(last)"]
            if pad > 0 { unlink.append("remove \(P) 4") }
            unlink.append("remove \(P) 0")
            lines += s4(L.t("数据链路层：用 FCS 检验，没有差错就去掉首部和尾部\(pad > 0 ? "（连同填充，靠 IP 首部里的长度知道哪些是填充）" : "")，按类型字段把数据交给 \(N)",
                            "Link layer: check the FCS, strip header and trailer\(pad > 0 ? " (and the padding — the IP length field tells where it starts)" : ""), hand the data to \(N) as the type field says"),
                        unlink)
            lines += s4(L.t("网络层：看目的地址是不是自己，去掉 \(N) 首部，按\(protoField)（\(transport == "tcp" ? 6 : 17)）交给 \(T)",
                            "Network layer: check the destination address, strip the \(N) header, hand the data to \(T) as \(protoField) (\(transport == "tcp" ? 6 : 17)) says"),
                        ["remove \(P) 0"])
            lines += s4(L.t("运输层：去掉 \(T) 首部，按目的端口交给应用进程", "Transport layer: strip the \(T) header and hand the data to the process on the destination port"),
                        ["remove \(P) 0"])
            lines += s4(L.t("应用层收到原来的 \(data) 字节：每层只看、只去掉自己那一层加的首部", "The application gets the original \(data) bytes: each layer reads and strips only its own header"),
                        ["mark \(P)[0] done"])
        }
        return Kit(title: L.t("逐层封装" + (mode == "both" ? "与拆封" : "") + "（\(T) / \(N) / 以太网）",
                              (mode == "both" ? "Encapsulation and decapsulation" : "Encapsulation") + " (\(T) / \(N) / Ethernet)"), lines: lines)
    }

    // MARK: - IP 分片

    private static func fragKit(_ a: inout Args, _ L: Words) throws -> Kit {
        let usage = "usage: kit frag total=4000 mtu=1500 [header=20] [df=0|1]   (or data=3980 instead of total=)"
        let header = try a.int("header", default: 20, 20...60)
        guard header % 4 == 0 else { throw AnimParseError("header= is a multiple of 4 (20…60)") }
        let mtu = try a.int("mtu", default: 1500, 68...65535)
        let df = try a.int("df", default: 0, 0...1)
        let total: Int
        if a.values["total"] != nil {
            guard a.values["data"] == nil else { throw AnimParseError("give total= or data=, not both") }
            total = try a.int("total", default: 0, (header + 1)...65535)
        } else if a.values["data"] != nil {
            total = try a.int("data", default: 0, 1...(65535 - header)) + header
        } else {
            throw AnimParseError(usage)
        }
        let id = try a.int("id", default: -1, 0...65535)
        try a.checkUnused(["total", "data", "mtu", "header", "df", "id", "lang"])
        guard mtu >= header + 8 else { throw AnimParseError("mtu= must leave room for at least 8 data bytes after the \(header)-byte header") }
        let data = total - header
        let maxData = (mtu - header) / 8 * 8
        let count = data <= mtu - header ? 1 : (data + maxData - 1) / maxData
        if df == 0 && total > mtu && count > 8 { throw AnimParseError("that makes \(count) fragments; at most 8 (use a larger mtu=)") }
        let D = L.t("数据报", "datagram"), F = L.t("分片", "fragments")
        let hName = L.t("首部", "header"), dName = L.t("数据", "data")
        var lines = ["packet \(D) unit=B = \(hName):\(header), \(dName):\(data)"]
        let idText = id >= 0 ? L.t("，标识 \(id)", ", identification \(id)") : ""
        let title = L.t("IP 分片：总长度 \(total)，MTU \(mtu)", "IP fragmentation: total length \(total), MTU \(mtu)")
        if total <= mtu {
            lines += s4(L.t("总长度 \(total) ≤ MTU \(mtu)：不需要分片，原样发出（MF = 0，片偏移 = 0）", "Total length \(total) ≤ MTU \(mtu): no fragmentation needed (MF = 0, offset 0)"),
                        ["mark \(D) done"])
            return Kit(title: title, lines: lines)
        }
        if df == 1 {
            lines += s4(L.t("总长度 \(total) 超过 MTU \(mtu)，需要分片", "Total length \(total) exceeds the MTU \(mtu): it must be fragmented"), ["mark \(D)[1] active"])
            lines += s4(L.t("但 DF = 1，不许分片：路由器丢弃这个数据报，并向源点发 ICMP 差错报告（终点不可达：需要分片但 DF 置 1）",
                            "But DF = 1 forbids it: the router drops the datagram and sends the source an ICMP error (destination unreachable: fragmentation needed and DF set)"),
                        ["mark \(D) wrong"])
            return Kit(title: title, lines: lines)
        }
        let rows = (1...count).map { L.t("片\($0)", "F\($0)") }
        lines.append("grid \(F) rows=[\(rows.joined(separator: ", "))] cols=[\(L.t("总长度, 数据长度, MF, DF, 片偏移", "Total, Data, MF, DF, Offset"))] = \(count)x5")
        lines += s4(L.t("每片也要带 \(header) 字节首部，一片最多放 \(mtu) − \(header) = \(mtu - header) 字节数据；片偏移以 8 字节为单位，所以每片（最后一片除外）的数据长度要取 8 的倍数：⌊\(mtu - header) / 8⌋ × 8 = \(maxData)",
                        "Each fragment carries its own \(header)-byte header, leaving \(mtu) − \(header) = \(mtu - header) bytes for data; offsets count 8-byte units, so every fragment but the last carries a multiple of 8: ⌊\(mtu - header) / 8⌋ × 8 = \(maxData)"),
                    ["mark \(D)[1] active"])
        var start = 0
        for k in 0..<count {
            let n = min(maxData, data - start)
            let isLast = k == count - 1
            var acts: [String] = []
            let at = 2 * k   // 第 k 片的首部在第 2k 段，数据在 2k+1 段
            if k > 0 { acts += ["unmark \(F)[\(k - 1),0..4]"] }
            if isLast {
                acts += ["set \(D)[\(at + 1)] = " + q("\(dName):\(n)"), "unmark \(D)[\(at + 1)]"]
            } else {
                acts += ["set \(D)[\(at + 1)] = " + q("\(dName):\(n)"), "unmark \(D)[\(at + 1)]",
                         "insert \(D) \(at + 2) " + q("\(hName):\(header)"), "insert \(D) \(at + 3) " + q("\(dName):\(data - start - n)"), "mark \(D)[\(at + 3)] active"]
            }
            acts += ["group \(D)[\(at)..\(at + 1)] " + q(L.t("片\(k + 1)：字节 \(start)~\(start + n - 1)", "F\(k + 1): bytes \(start)–\(start + n - 1)")),
                     "set \(F)[\(k),0] = \(n + header)", "set \(F)[\(k),1] = \(n)", "set \(F)[\(k),2] = \(isLast ? 0 : 1)", "set \(F)[\(k),3] = 0", "set \(F)[\(k),4] = \(start / 8)",
                     "mark \(F)[\(k),0..4] active"]
            let cap = L.t("片\(k + 1)：数据第 \(start)~\(start + n - 1) 字节，共 \(n) 字节，总长度 \(n) + \(header) = \(n + header)；片偏移 = \(start) / 8 = \(start / 8)；MF = \(isLast ? "0（最后一片）" : "1（后面还有）")",
                          "F\(k + 1): data bytes \(start)–\(start + n - 1), \(n) bytes, total length \(n) + \(header) = \(n + header); offset = \(start) / 8 = \(start / 8); MF = \(isLast ? "0 (last)" : "1 (more follow)")")
            lines += s4(cap, acts)
            start += n
        }
        lines += s4(L.t("共 \(count) 片：各片的标识都与原数据报相同\(idText)，DF = 0；只有最后一片 MF = 0。终点按标识把片收齐、按片偏移排好，重组成原来的 \(total) 字节",
                        "\(count) fragments: all keep the original identification\(idText), DF = 0; only the last has MF = 0. The destination collects them by identification, orders them by offset and rebuilds the \(total) bytes"),
                    ["unmark \(F)[\(count - 1),0..4]", "mark \(F)[0..\(count - 1),4] done"])
        return Kit(title: title, lines: lines)
    }
}
