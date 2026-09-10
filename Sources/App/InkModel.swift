import Foundation
import AppKit

/// 笔色（0~255 + alpha）。解析平板发来的 "rgba(24,90,210,0.95)"。
/// Codable：落库 payload 用，编码为 {"r":,"g":,"b":,"a":}（跨平台可读）。
struct InkColor: Equatable, Codable {
    var r: Double, g: Double, b: Double, a: Double

    var nsColor: NSColor { NSColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: a) }

    static let defaultInk = InkColor(r: 24, g: 90, b: 210, a: 0.95)

    static func parse(_ s: String?) -> InkColor {
        guard let s = s, let open = s.firstIndex(of: "("), let close = s.firstIndex(of: ")") else {
            return .defaultInk
        }
        let parts = s[s.index(after: open)..<close]
            .split(separator: ",")
            .map { Double($0.trimmingCharacters(in: .whitespaces)) ?? 0 }
        guard parts.count >= 3 else { return .defaultInk }
        return InkColor(r: parts[0], g: parts[1], b: parts[2], a: parts.count >= 4 ? parts[3] : 1)
    }
}

/// 一条手写笔画。points 为归一化页面坐标（0~1，左上原点）+ 压感。
/// `id` 可指定：落库时用作 `note.id`，重开加载时按 `note.id` 复原，保证擦除能一一映射删除。
///
/// `padId` 非 nil 时这一笔**画在草稿纸上**（`ScratchPad.id`），此时：
///  · `points` 是**画布坐标**（逻辑点，可负无界），不是页内 0~1 归一化；
///  · `page` 无意义（落库固定 0），`layerId` 也不参与（草稿纸不分图层）；
///  · 落库走 `note` 表 kind=4 而非 kind=2。
/// 坐标系契约见 `ScratchPad`。除此之外与页内笔迹**完全同构**——擦除（`InkEdit.splitStroke`）、
/// 平移、四种笔型渲染全部原样复用，这正是当初把画布单位定成「逻辑点」的目的。
struct InkStroke: Identifiable, Equatable {
    var id: UUID = UUID()
    var page: Int
    var color: InkColor
    var width: Double
    var type: PenBrushType = .ballpoint
    var points: [SIMD3<Double>]   // x, y, pressure
    /// 所属图层（`InkLayer.id`）。旧数据/未指定 → `InkLayer.defaultID`。
    var layerId: UUID = InkLayer.defaultID
    /// 所属草稿纸（`ScratchPad.id`）；nil = 画在 PDF 页面上。
    var padId: UUID?
}

// MARK: - 持久化（note 表，kind=2）

/// 落库到 `note.payload` 的 JSON 形态（页/锚点走 note 列，这里只存其余字段）。
/// points 用显式 `[x, y, pressure]` 数组而非 SIMD，保证 Windows/Android 端易读。
private struct InkStrokePayload: Codable {
    var color: InkColor
    var width: Double
    var type: PenBrushType = .ballpoint
    var points: [[Double]]
    var layerId: UUID = InkLayer.defaultID
    /// 草稿纸笔迹才有（kind=4）；页内笔迹不写这个键。
    var padId: UUID?

    enum CodingKeys: String, CodingKey { case color, width, type, points, layerId, padId }

    init(color: InkColor, width: Double, type: PenBrushType, points: [[Double]], layerId: UUID, padId: UUID?) {
        self.color = color; self.width = width; self.type = type; self.points = points
        self.layerId = layerId; self.padId = padId
    }

    /// 旧笔迹（升级前落库的）payload 里没有 `type`/`layerId`/`padId` 键，同 `PenPreset` 一样手动兜底。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        color = try c.decode(InkColor.self, forKey: .color)
        width = try c.decode(Double.self, forKey: .width)
        type = try c.decodeIfPresent(PenBrushType.self, forKey: .type) ?? .ballpoint
        points = try c.decode([[Double]].self, forKey: .points)
        layerId = try c.decodeIfPresent(UUID.self, forKey: .layerId) ?? InkLayer.defaultID
        padId = try c.decodeIfPresent(UUID.self, forKey: .padId)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(color, forKey: .color)
        try c.encode(width, forKey: .width)
        try c.encode(type, forKey: .type)
        try c.encode(points, forKey: .points)
        try c.encode(layerId, forKey: .layerId)
        // 页内笔迹不写 padId（键不存在 = 不是草稿纸笔迹），保持既有 payload 逐字节不变。
        try c.encodeIfPresent(padId, forKey: .padId)
    }
}

extension InkStroke {
    /// 手写笔迹的笔记类型（对齐 `LibNote.kind`：0 text / 1 chat / 2 ink / 3 highlight / 4 草稿纸笔迹）。
    static let noteKind = 2
    /// 草稿纸上的笔迹（v8）。与 kind=2 分开是为了让「读某文档的页内笔迹」这条最热的路径
    /// 一个 `kind ==` 就筛干净，不必每条都去 payload 里翻有没有 `padId`。
    static let scratchNoteKind = 4

    /// 归一化点的包围盒（0~1 页面坐标），作 `note` 的 anchor；空笔画为 .zero。
    var normalizedBounds: CGRect {
        guard let first = points.first else { return .zero }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for p in points {
            minX = Swift.min(minX, p.x); maxX = Swift.max(maxX, p.x)
            minY = Swift.min(minY, p.y); maxY = Swift.max(maxY, p.y)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// 序列化为一条 ink 笔记（挂逻辑文档，全版本共用）。空笔画返回 nil（不落库）。
    /// 草稿纸笔迹（`padId != nil`）落 kind=4，`page` 固定 0（画布不属于任何一页），
    /// `anchor` 是**画布坐标**包围盒（可负，只作检索/调试用，没有页内语义）。
    func toNote(documentId: String, now: Date = .now) -> LibNote? {
        guard !points.isEmpty else { return nil }
        let payload = InkStrokePayload(color: color, width: width, type: type,
                                       points: points.map { [$0.x, $0.y, $0.z] }, layerId: layerId,
                                       padId: padId)
        guard let data = try? JSONEncoder().encode(payload) else { return nil }
        let scratch = padId != nil
        return LibNote(id: id.uuidString, documentId: documentId,
                       kind: scratch ? Self.scratchNoteKind : Self.noteKind,
                       page: scratch ? 0 : page, anchor: normalizedBounds, payload: data,
                       createdAt: now, updatedAt: now)
    }

    /// 从一条 ink 笔记复原（id/page 取 note 列，其余取 payload）。类型不符或损坏返回 nil。
    /// kind=2（页内）与 kind=4（草稿纸）都接：草稿纸笔迹的 `padId` 在 payload 里，
    /// 缺 `padId` 的 kind=4 行是坏数据（无处可归的孤儿笔迹），当损坏丢弃。
    init?(note: LibNote) {
        self.init(id: note.id, kind: note.kind, page: note.page, payload: note.payload)
    }

    /// 同上，吃窄查询的行（`LibraryStore.inkRows`）——开文档走这条，整行 `LibNote` 那条留给零星读。
    init?(row: LibInkRow) {
        self.init(id: row.id, kind: row.kind, page: row.page, payload: row.payload)
    }

    /// 两个入口共用的解码本体：一条笔迹真正要用的就这四样。
    private init?(id: String, kind: Int, page: Int, payload data: Data) {
        guard kind == InkStroke.noteKind || kind == InkStroke.scratchNoteKind,
              let uuid = UUID(uuidString: id) else { return nil }
        // 快路：points 用字节扫描（`InkPayloadFast`），其余字段照旧 JSONDecoder——开文档时的
        // 「笔迹」段从半秒降到几十毫秒。形态不认识时回落到整段 JSONDecoder，结果逐位相同。
        let payload: InkStrokePayload
        let pts: [SIMD3<Double>]
        if let fast = InkPayloadFast.splitPoints(data),
           let p = try? JSONDecoder().decode(InkStrokePayload.self, from: fast.rest) {
            payload = p
            pts = fast.points
        } else {
            guard let p = try? JSONDecoder().decode(InkStrokePayload.self, from: data) else { return nil }
            payload = p
            pts = p.points.map { p in
                let x: Double = p.count > 0 ? p[0] : 0
                let y: Double = p.count > 1 ? p[1] : 0
                let z: Double = p.count > 2 ? p[2] : 0.5
                return SIMD3<Double>(x, y, z)
            }
        }
        if kind == InkStroke.scratchNoteKind && payload.padId == nil { return nil }
        self.init(id: uuid, page: page, color: payload.color, width: payload.width, type: payload.type,
                  points: pts, layerId: payload.layerId, padId: payload.padId)
    }
}

extension InkStroke {
    /// 一批笔迹行 → 笔迹，**多核并行**、保持原顺序（顺序 = 落库序 = 绘制叠放序）。
    /// 开文档时在后台线程调（`DocTabModel.loadInk`）；行数少就直接顺序解，不值得起线程。
    static func decodeAll(_ rows: [LibInkRow]) -> [InkStroke] {
        let n = rows.count
        let cores = max(1, ProcessInfo.processInfo.activeProcessorCount)
        let chunks = min(cores, max(1, n / 64))
        guard chunks > 1 else { return rows.compactMap(InkStroke.init(row:)) }
        var parts = [[InkStroke]](repeating: [], count: chunks)
        let size = (n + chunks - 1) / chunks
        parts.withUnsafeMutableBufferPointer { buf in
            DispatchQueue.concurrentPerform(iterations: chunks) { k in
                let lo = k * size, hi = min(n, lo + size)
                guard lo < hi else { return }
                buf[k] = rows[lo..<hi].compactMap(InkStroke.init(row:))   // 各写各的槽，不共享
            }
        }
        return parts.flatMap { $0 }
    }
}

// MARK: - points 快速解析

/// 笔迹 payload 的 `points` 快速解析（2026-09-10 打开耗时账本量出来的：一篇 2616 笔的文档
/// 「笔迹」段 506ms，几乎全在 `JSONDecoder` 解 `[[Double]]`——Codable 逐元素走一遍容器协议，
/// 一个数要 1~2µs，二十几万个点就是半秒）。
///
/// 做法：在原始字节里找到 `"points"` 那个数组的起止，用 `strtod`（正确舍入；小数点形态启动时自检）
/// 直接扫数字进 `SIMD3<Double>`；其余字段（color/width/type/layerId/padId，加起来百来字节）
/// 把数组换成 `[]` 后照旧交给 `JSONDecoder`。**语义不变**：解出来的 Double 与 `JSONDecoder`
/// 逐位相同（`spike/ink-payload-fast-test.swift` 逐点比对），任何看不懂的形态返回 nil、
/// 调用方回落到原路径。
///
/// 不改 payload 格式：`[x, y, pressure]` 显式数组是三端共用的落库契约（安卓/Windows 要能读）。
enum InkPayloadFast {
    /// 返回 (去掉 points 的 payload, 点数组)；形态不认识时 nil。
    static func splitPoints(_ data: Data) -> (rest: Data, points: [SIMD3<Double>])? {
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
        var pts: [SIMD3<Double>] = []
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
            pts.append(SIMD3<Double>(v.count > 0 ? v[0] : 0, v.count > 1 ? v[1] : 0, v.count > 2 ? v[2] : 0.5))
            skipWS()
            guard i < n else { return nil }
            if b[i] == UInt8(ascii: ",") { i += 1; continue }
            guard b[i] == UInt8(ascii: "]") else { return nil }
        }
        let arrEnd = i   // 指向外层 `]`
        var rest = Data(capacity: n - (arrEnd - arrStart) + 2)
        rest.append(data[0..<arrStart])
        rest.append(contentsOf: [UInt8(ascii: "["), UInt8(ascii: "]")])
        rest.append(data[(arrEnd + 1)..<n])
        return (rest, pts)
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
