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

/// 笔迹点：x、y、压感（页内笔迹 0~1 归一化；草稿纸笔迹是画布逻辑点）。
///
/// 🔴 **是 `Float` 不是 `Double`**（2026-09-10 定，`INK-PAGING-PLAN.md §3`）：`SIMD3<Double>` stride 32
/// （8 B 纯填充），一篇 2616 笔 ≈ 26 万点就是 8 MB 常驻；平板上行线格式本来就是 f32（`PROTOCOL.md §2`），
/// Double 在内存里没多装任何信息，本机落笔归一化后 f32 的分辨率（~6e-8）也远超显示需要。
/// 约定：**存 Float、算 Double**——平移/缩放/包围盒这类变换在 Double 里算完再 `InkPoint(x, y, z)`
/// 存回；距离命中（擦除/框选）直接在 Float 里比，半径 `Float(r)` 转一次即可。
typealias InkPoint = SIMD3<Float>

extension SIMD3 where Scalar == Float {
    /// Double 算完存回 Float 的便利构造（变换代码里到处是 `Double` 中间量）。
    /// `@_disfavoredOverload`：三个参数都是字面量（`InkPoint(1, 0, 0.5)`）时两个 init 都能接，
    /// 标记后一律走标准的 Float 版，不报「ambiguous use」；传 Double 变量时只有这个能接，照常选中。
    @_disfavoredOverload
    @inline(__always) init(_ x: Double, _ y: Double, _ z: Double) {
        self.init(Float(x), Float(y), Float(z))
    }
    /// 「算 Double」那半边的取值：`p.dx` = `Double(p.x)`。
    @inline(__always) var dx: Double { Double(x) }
    @inline(__always) var dy: Double { Double(y) }
    @inline(__always) var dz: Double { Double(z) }
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
    var points: [InkPoint]   // x, y, pressure（Float，见 `InkPoint`）
    /// 所属图层（`InkLayer.id`）。旧数据/未指定 → `InkLayer.defaultID`。
    var layerId: UUID = InkLayer.defaultID
    /// 所属草稿纸（`ScratchPad.id`）；nil = 画在 PDF 页面上。
    var padId: UUID?
}

// MARK: - 持久化（note 表，kind=2）

/// 落库到 `note.payload` 的 JSON 形态（页/锚点走 note 列，这里只存其余字段）。
/// points 用显式 `[x, y, pressure]` 数组而非 SIMD，保证 Windows/Android 端易读。
/// 写的时候是 `[[Float]]`（JSON 写 Float 的最短十进制，payload 比 Double 的 17 位短一半）；
/// 读的时候按 `[[Double]]` 认（别的端 / 老数据写的是 Double），再 `Float(d)`——与
/// `InkPayloadFast` 走同一种转换，两条路解出的 Float 逐位相同。
private struct InkStrokePayload: Codable {
    var color: InkColor
    var width: Double
    var type: PenBrushType = .ballpoint
    var points: [[Float]]
    var layerId: UUID = InkLayer.defaultID
    /// 草稿纸笔迹才有（kind=4）；页内笔迹不写这个键。
    var padId: UUID?
    /// 分页画板上的笔迹才有（board_item kind=1，v17）：所属那一页的 id，此时 points 是**页内坐标**。
    var page: String?

    enum CodingKeys: String, CodingKey { case color, width, type, points, layerId, padId, page }

    init(color: InkColor, width: Double, type: PenBrushType, points: [[Float]], layerId: UUID, padId: UUID?,
         page: String? = nil) {
        self.color = color; self.width = width; self.type = type; self.points = points
        self.layerId = layerId; self.padId = padId; self.page = page
    }

    /// 旧笔迹（升级前落库的）payload 里没有 `type`/`layerId`/`padId` 键，同 `PenPreset` 一样手动兜底。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        color = try c.decode(InkColor.self, forKey: .color)
        width = try c.decode(Double.self, forKey: .width)
        type = try c.decodeIfPresent(PenBrushType.self, forKey: .type) ?? .ballpoint
        points = try c.decode([[Double]].self, forKey: .points).map { $0.map(Float.init) }
        layerId = try c.decodeIfPresent(UUID.self, forKey: .layerId) ?? InkLayer.defaultID
        padId = try c.decodeIfPresent(UUID.self, forKey: .padId)
        page = try c.decodeIfPresent(String.self, forKey: .page)
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
        try c.encodeIfPresent(page, forKey: .page)   // 只有分页画板的笔迹写，别的 payload 逐字节不变
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
        return CGRect(x: CGFloat(minX), y: CGFloat(minY), width: CGFloat(maxX - minX), height: CGFloat(maxY - minY))
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
        // JSON 点照旧写（兼容模式）；已清理时由 `LibraryStore.upsertNote` 摘掉。二进制总是写（v18）。
        return LibNote(id: id.uuidString, documentId: documentId,
                       kind: scratch ? Self.scratchNoteKind : Self.noteKind,
                       page: scratch ? 0 : page, anchor: normalizedBounds, payload: data,
                       createdAt: now, updatedAt: now, points: InkPointsBlob.encode(points))
    }

    /// 从一条 ink 笔记复原（id/page 取 note 列，其余取 payload）。类型不符或损坏返回 nil。
    /// kind=2（页内）与 kind=4（草稿纸）都接：草稿纸笔迹的 `padId` 在 payload 里，
    /// 缺 `padId` 的 kind=4 行是坏数据（无处可归的孤儿笔迹），当损坏丢弃。
    init?(note: LibNote) {
        self.init(id: note.id, kind: note.kind, page: note.page, payload: note.payload,
                  blob: note.points, blobValid: note.pointsValid)
    }

    /// 同上，吃窄查询的行（`LibraryStore.inkRows`）——开文档走这条，整行 `LibNote` 那条留给零星读。
    init?(row: LibInkRow) {
        self.init(id: row.id, kind: row.kind, page: row.page, payload: row.payload,
                  blob: row.points, blobValid: row.pointsValid)
    }

    /// 两个入口共用的解码本体。
    private init?(id: String, kind: Int, page: Int, payload data: Data, blob: Data?, blobValid: Bool) {
        guard kind == InkStroke.noteKind || kind == InkStroke.scratchNoteKind,
              let uuid = UUID(uuidString: id),
              let (payload, pts) = InkStrokePayload.read(data, blob: blob, blobValid: blobValid) else { return nil }
        if kind == InkStroke.scratchNoteKind && payload.padId == nil { return nil }
        self.init(id: uuid, page: page, color: payload.color, width: payload.width, type: payload.type,
                  points: pts, layerId: payload.layerId, padId: payload.padId)
    }
}

extension InkStroke {
    /// 只读 payload 里的 **JSON 点**（v18 迁移用：把它编成二进制补进 `points` 列）。解不出 → nil。
    static func jsonPoints(payload data: Data) -> [InkPoint]? {
        if let fast = InkPayloadFast.splitPoints(data) { return fast.points }
        guard let p = try? JSONDecoder().decode(InkStrokePayload.self, from: data) else { return nil }
        return p.points.map { InkPoint($0.count > 0 ? $0[0] : 0, $0.count > 1 ? $0[1] : 0, $0.count > 2 ? $0[2] : 0.5) }
    }
}

extension InkStrokePayload {
    /// 一行笔迹的 payload + 点集，按 `BINARY-INK-PLAN.md §3` 决定点从哪来（安卓 `InkPayload.readStroke` 同一份规则）：
    ///  1. 二进制有效（`points_at == updated_at`）→ 用二进制，JSON 里的点不解（只摘掉、解其余小字段）；
    ///  2. 否则 JSON 里有点 → 用 JSON（旧版 App 写的 / 改过的 / 还没迁移的）；
    ///  3. 否则有二进制 → 用二进制（已清理兼容数据：JSON 点是空的）；
    ///  4. 都没有 → 空点集（调用方照旧处理）。
    /// JSON 那条仍走 `InkPayloadFast` 快路，形态不认识回落整段 `JSONDecoder`，结果逐位相同。
    fileprivate static func read(_ data: Data, blob: Data?, blobValid: Bool) -> (InkStrokePayload, [InkPoint])? {
        if blobValid, let blob, let bp = InkPointsBlob.decode(blob),
           let s = InkPayloadFast.stripPoints(data),
           let p = try? JSONDecoder().decode(InkStrokePayload.self, from: s.rest) {
            return (p, bp)
        }
        let payload: InkStrokePayload
        var pts: [InkPoint]
        if let fast = InkPayloadFast.splitPoints(data),
           let p = try? JSONDecoder().decode(InkStrokePayload.self, from: fast.rest) {
            payload = p
            pts = fast.points
        } else {
            guard let p = try? JSONDecoder().decode(InkStrokePayload.self, from: data) else { return nil }
            payload = p
            pts = p.points.map { p in
                let x: Float = p.count > 0 ? p[0] : 0
                let y: Float = p.count > 1 ? p[1] : 0
                let z: Float = p.count > 2 ? p[2] : 0.5
                return InkPoint(x, y, z)
            }
        }
        if pts.isEmpty, let blob, let bp = InkPointsBlob.decode(blob) { pts = bp }
        return (payload, pts)
    }
}

// MARK: - 画板笔记（board_item kind=1，v16）

extension InkStroke {
    /// 画板笔记上笔迹条目的 kind（`board_item.kind`；2 = 图片，见 `BoardImage.itemKind`）。
    static let boardItemKind = 1

    /// 序列化为画板笔记的一条笔迹。payload 与草稿纸 kind=4 **同一份 JSON**，只是不写 `padId`
    /// （归属在 `board_item.board_id` 列上，`BOARD-NOTE-PLAN.md §2.2`）。空笔画返回 nil。
    /// `page` 非 nil = 分页画板：写页 id，点换成**页内坐标**（减去该页在画布上的左上角，`BOARD-NOTE-PLAN.md §9.1`）。
    func toBoardItem(boardId: String, createdAt: Date, now: Date = .now,
                     page: (id: UUID, origin: CGPoint)? = nil) -> LibBoardItem? {
        guard !points.isEmpty else { return nil }
        var s = self
        if let page {
            let ox = Double(page.origin.x), oy = Double(page.origin.y)
            s.points = points.map { InkPoint($0.dx - ox, $0.dy - oy, $0.dz) }
        }
        let payload = InkStrokePayload(color: color, width: width, type: type,
                                       points: s.points.map { [$0.x, $0.y, $0.z] }, layerId: layerId,
                                       padId: nil, page: page?.id.uuidString)
        guard let data = try? JSONEncoder().encode(payload) else { return nil }
        // 二进制与 JSON 点同一个坐标系（分页画板 = 页内坐标）
        return LibBoardItem(id: id.uuidString, boardId: boardId, kind: Self.boardItemKind,
                            rect: s.normalizedBounds, payload: data, createdAt: createdAt, updatedAt: now,
                            points: InkPointsBlob.encode(s.points))
    }

    /// 从一条画板笔迹复原。`padId` = 这篇画板在会话里扮演的那张「永远开着的草稿纸」的 id
    /// （= 画板笔记 id），于是草稿纸那整条链路（渲染 / 擦除 / 撤销 / 平板下行）原样可用。
    /// `origin` = 分页画板上「页 id → 该页在画布上的左上角」；payload 带 `page` 而那页不在（孤儿）→ nil。
    init?(boardItem it: LibBoardItem, padId: UUID, origin: (String) -> CGPoint? = { _ in nil }) {
        guard it.kind == Self.boardItemKind, let uuid = UUID(uuidString: it.id),
              let (p, raw) = InkStrokePayload.read(it.payload, blob: it.points, blobValid: it.pointsValid)
        else { return nil }
        var ox = 0.0, oy = 0.0
        if let pg = p.page {
            guard let o = origin(pg.uppercased()) else { return nil }
            ox = Double(o.x); oy = Double(o.y)
        }
        let pts = ox == 0 && oy == 0 ? raw : raw.map { InkPoint($0.dx + ox, $0.dy + oy, $0.dz) }
        self.init(id: uuid, page: 0, color: p.color, width: p.width, type: p.type,
                  points: pts, layerId: p.layerId, padId: padId)
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

// `InkPayloadFast`（points 的字节级快读 / 摘除）住在 `Sources/Store/InkPayloadFast.swift`：
// 存储层的迁移与清理也要用它，而存储层不依赖 App 层。
