import Foundation
import AppKit

/// 笔色（0~255 + alpha）。解析平板发来的 "rgba(24,90,210,0.95)"。
struct InkColor: Equatable {
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
struct InkStroke: Identifiable, Equatable {
    let id = UUID()
    var page: Int
    var color: InkColor
    var width: Double
    var points: [SIMD3<Double>]   // x, y, pressure
}
