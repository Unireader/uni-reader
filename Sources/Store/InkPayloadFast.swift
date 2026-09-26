import Foundation

/// 笔迹 payload 的 `points` 快速解析（2026-09-10 打开耗时账本量出来的：一篇 2616 笔的文档
/// 「笔迹」段 506ms，几乎全在 `JSONDecoder` 解 `[[Double]]`——Codable 逐元素走一遍容器协议，
/// 一个数要 1~2µs，二十几万个点就是半秒）。
///
/// 做法：在原始字节里找到 `"points"` 那个数组的起止，数字按 Double 解（正确舍入）再 `Float(d)`
/// 存进点（`SIMD3<Float>` = App 层的 `InkPoint`）；其余字段（color/width/type/layerId/padId，加起来百来字节）
/// 把数组换成 `[]` 后照旧交给 `JSONDecoder`。**语义不变**：解出来的 Float 与「`JSONDecoder` 解
/// `[[Double]]` 再 `Float(d)`」逐位相同（`spike/ink-payload-fast-test.swift` 逐点比对），
/// 任何看不懂的形态返回 nil、调用方回落到原路径。
///
/// 住在存储层（不在 `InkModel.swift`）：v18 的迁移 / 清理兼容数据（`BINARY-INK-PLAN.md`）在存储层里也要用，
/// 而存储层不依赖 App 层（`spike/mirror-build-test.swift` 这类只编 `Sources/Store/*.swift`）。
enum InkPayloadFast {
    /// 返回 (去掉 points 的 payload, 点数组)；形态不认识时 nil。
    static func splitPoints(_ data: Data) -> (rest: Data, points: [SIMD3<Float>])? {
        // 结构用裸字节扫（`[UInt8]` 下标是最快的），数字交给 Swift 自己的 `Double(String)`
        // （正确舍入、locale 无关）。**别用 `strtod`**：2026-09-10 实测它在多线程下不伸缩
        // （300k 次：1 线程 10ms、8 线程 20ms），而 `Double(String)` 同样的活 8 线程 2ms——
        // `decodeAll` 的并行解码全靠这一点。也别用 String.Index 逐字符推进：一个 payload 十几 KB，
        // `index(after:)` 每步十几 ns，比裸字节慢四倍。
        let b = [UInt8](data)
        let n = b.count
        guard let keyAt = find(b, key: Array("\"points\"".utf8)) else { return nil }
        var i = keyAt + 8
        @inline(__always) func skipWS() {
            while i < n, b[i] == 0x20 || b[i] == 0x0A || b[i] == 0x0D || b[i] == 0x09 { i += 1 }
        }
        @inline(__always) func isNum(_ c: UInt8) -> Bool {
            (c >= 0x30 && c <= 0x39) || c == 0x2D || c == 0x2B || c == 0x2E || c == 0x65 || c == 0x45   // 0-9 - + . e E
        }
        skipWS()
        guard i < n, b[i] == UInt8(ascii: ":") else { return nil }
        i += 1
        skipWS()
        guard i < n, b[i] == UInt8(ascii: "[") else { return nil }
        let arrStart = i
        i += 1
        var pts: [SIMD3<Float>] = []
        pts.reserveCapacity(64)
        while true {
            skipWS()
            guard i < n else { return nil }
            if b[i] == UInt8(ascii: "]") { break }                  // 外层数组结束
            guard b[i] == UInt8(ascii: "[") else { return nil }      // 每个点必须是内层数组
            i += 1
            var v: [Double] = []   // 一个点最多三个数；多的忽略，少的按老规矩补
            while true {
                skipWS()
                guard i < n else { return nil }
                if b[i] == UInt8(ascii: "]") { i += 1; break }
                let start = i
                while i < n, isNum(b[i]) { i += 1 }
                guard i > start, let d = Double(String(decoding: b[start..<i], as: UTF8.self)) else { return nil }
                if v.count < 3 { v.append(d) }
                skipWS()
                guard i < n else { return nil }
                if b[i] == UInt8(ascii: ",") { i += 1; continue }
                guard b[i] == UInt8(ascii: "]") else { return nil }
            }
            pts.append(SIMD3<Float>(Float(v.count > 0 ? v[0] : 0), Float(v.count > 1 ? v[1] : 0),
                                    Float(v.count > 2 ? v[2] : 0.5)))
            skipWS()
            guard i < n else { return nil }
            if b[i] == UInt8(ascii: ",") { i += 1; continue }
            guard b[i] == UInt8(ascii: "]") else { return nil }
        }
        let arrEnd = i   // 指向外层 `]`
        var rest = Data(capacity: n - (arrEnd - arrStart) + 2)
        rest.append(contentsOf: b[0..<arrStart])   // 按字节数组下标切：`Data` 切片的下标不一定从 0 起
        rest.append(contentsOf: [UInt8(ascii: "["), UInt8(ascii: "]")])
        rest.append(contentsOf: b[(arrEnd + 1)..<n])
        return (rest, pts)
    }

    /// 把 `"points":[…]` 换成 `"points":[]`（只配方括号、不解数字，远比 [splitPoints] 便宜）。
    /// 返回 (换过的 payload, 原来的点集非空吗)；找不到 points 键或形态不对 → nil。
    /// 用在两处（`BINARY-INK-PLAN.md`）：二进制有效时读其余字段；已清理兼容数据时写库前摘掉 JSON 点。
    static func stripPoints(_ data: Data) -> (rest: Data, hadPoints: Bool)? {
        let b = [UInt8](data)
        let n = b.count
        guard let keyAt = find(b, key: Array("\"points\"".utf8)) else { return nil }
        var i = keyAt + 8
        while i < n, b[i] == 0x20 || b[i] == 0x0A || b[i] == 0x0D || b[i] == 0x09 { i += 1 }
        guard i < n, b[i] == UInt8(ascii: ":") else { return nil }
        i += 1
        while i < n, b[i] == 0x20 || b[i] == 0x0A || b[i] == 0x0D || b[i] == 0x09 { i += 1 }
        guard i < n, b[i] == UInt8(ascii: "[") else { return nil }
        let arrStart = i
        var depth = 0
        var hadPoints = false
        var arrEnd = -1
        while i < n {
            switch b[i] {
            case UInt8(ascii: "["): depth += 1; if depth == 2 { hadPoints = true }
            case UInt8(ascii: "]"): depth -= 1
            case UInt8(ascii: "\""), UInt8(ascii: "{"), UInt8(ascii: "}"): return nil   // 点集里不该有
            default: break
            }
            if depth == 0 { arrEnd = i; break }
            i += 1
        }
        guard arrEnd > arrStart else { return nil }
        var rest = Data(capacity: n - (arrEnd - arrStart) + 2)
        rest.append(contentsOf: b[0..<arrStart])
        rest.append(contentsOf: [UInt8(ascii: "["), UInt8(ascii: "]")])
        rest.append(contentsOf: b[(arrEnd + 1)..<n])
        return (rest, hadPoints)
    }

    /// 找键（含引号）第一次出现的位置。payload 里其它字符串值（笔型名、UUID）不可能含它。
    private static func find(_ b: [UInt8], key: [UInt8]) -> Int? {
        let n = b.count
        guard n >= key.count else { return nil }
        var i = 0
        let first = key[0]
        while i <= n - key.count {
            if b[i] == first {
                var j = 1
                while j < key.count, b[i + j] == key[j] { j += 1 }
                if j == key.count { return i }
            }
            i += 1
        }
        return nil
    }
}
