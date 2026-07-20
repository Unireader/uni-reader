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
struct InkStroke: Identifiable, Equatable {
    var id: UUID = UUID()
    var page: Int
    var color: InkColor
    var width: Double
    var points: [SIMD3<Double>]   // x, y, pressure
}

// MARK: - 持久化（note 表，kind=2）

/// 落库到 `note.payload` 的 JSON 形态（页/锚点走 note 列，这里只存其余字段）。
/// points 用显式 `[x, y, pressure]` 数组而非 SIMD，保证 Windows/Android 端易读。
private struct InkStrokePayload: Codable {
    var color: InkColor
    var width: Double
    var points: [[Double]]
}

extension InkStroke {
    /// 手写笔迹的笔记类型（对齐 `LibNote.kind`：0 text / 1 chat / 2 ink）。
    static let noteKind = 2

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
    func toNote(documentId: String, now: Date = .now) -> LibNote? {
        guard !points.isEmpty else { return nil }
        let payload = InkStrokePayload(color: color, width: width,
                                       points: points.map { [$0.x, $0.y, $0.z] })
        guard let data = try? JSONEncoder().encode(payload) else { return nil }
        return LibNote(id: id.uuidString, documentId: documentId, kind: Self.noteKind,
                       page: page, anchor: normalizedBounds, payload: data,
                       createdAt: now, updatedAt: now)
    }

    /// 从一条 ink 笔记复原（id/page 取 note 列，其余取 payload）。类型不符或损坏返回 nil。
    init?(note: LibNote) {
        guard note.kind == InkStroke.noteKind,
              let uuid = UUID(uuidString: note.id),
              let payload = try? JSONDecoder().decode(InkStrokePayload.self, from: note.payload)
        else { return nil }
        let pts: [SIMD3<Double>] = payload.points.map { p in
            let x: Double = p.count > 0 ? p[0] : 0
            let y: Double = p.count > 1 ? p[1] : 0
            let z: Double = p.count > 2 ? p[2] : 0.5
            return SIMD3<Double>(x, y, z)
        }
        self.init(id: uuid, page: note.page, color: payload.color, width: payload.width, points: pts)
    }
}
