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
        guard note.kind == InkStroke.noteKind || note.kind == InkStroke.scratchNoteKind,
              let uuid = UUID(uuidString: note.id),
              let payload = try? JSONDecoder().decode(InkStrokePayload.self, from: note.payload)
        else { return nil }
        if note.kind == InkStroke.scratchNoteKind && payload.padId == nil { return nil }
        let pts: [SIMD3<Double>] = payload.points.map { p in
            let x: Double = p.count > 0 ? p[0] : 0
            let y: Double = p.count > 1 ? p[1] : 0
            let z: Double = p.count > 2 ? p[2] : 0.5
            return SIMD3<Double>(x, y, z)
        }
        self.init(id: uuid, page: note.page, color: payload.color, width: payload.width, type: payload.type,
                  points: pts, layerId: payload.layerId, padId: payload.padId)
    }
}
