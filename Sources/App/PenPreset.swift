import SwiftUI
import AppKit

/// 一支预设笔：名字 + 颜色（含透明度，荧光笔就是半透明宽笔）+ 粗细。
/// 采集页（平板）用 PageDown 在预设间循环；SimPad 用第一支。橡皮是独立「擦除」模式，不进笔列表。
struct PenPreset: Identifiable, Equatable, Codable {
    var id: UUID = UUID()
    var name: String
    var color: InkColor
    var width: Double
}

/// 笔预设的持久化（本机 UserDefaults · JSON）。设置页编辑、采集页/SimPad 消费。
enum PenPresets {
    static let key = "penPresets"

    static let defaults: [PenPreset] = [
        PenPreset(name: "蓝", color: InkColor(r: 24, g: 90, b: 210, a: 0.95), width: 8),
        PenPreset(name: "红", color: InkColor(r: 220, g: 40, b: 40, a: 0.95), width: 9),
        PenPreset(name: "黑", color: InkColor(r: 20, g: 20, b: 20, a: 0.95), width: 14),
        PenPreset(name: "荧光", color: InkColor(r: 255, g: 214, b: 40, a: 0.40), width: 22),
    ]

    static func load() -> [PenPreset] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let arr = try? JSONDecoder().decode([PenPreset].self, from: data), !arr.isEmpty
        else { return defaults }
        return arr
    }

    static func save(_ presets: [PenPreset]) {
        guard let data = try? JSONEncoder().encode(presets) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    /// 注入采集页的 JSON：`[{name, color(css rgba), w}]`（与 capture.html 的 PENS 结构一致）。
    static func captureJSON() -> String {
        let items = load().map { p in
            "{\"name\":\(jsonString(p.name)),\"color\":\"\(p.color.cssRGBA)\",\"w\":\(p.width)}"
        }
        return "[" + items.joined(separator: ",") + "]"
    }

    private static func jsonString(_ s: String) -> String {
        guard let data = try? JSONEncoder().encode(s), let str = String(data: data, encoding: .utf8) else { return "\"\"" }
        return str
    }
}

extension InkColor {
    /// CSS `rgba(r,g,b,a)`（采集页/注入用）。
    var cssRGBA: String { "rgba(\(Int(r)),\(Int(g)),\(Int(b)),\(a))" }

    /// SwiftUI Color（设置页 ColorPicker 用；sRGB + 透明度）。
    var swiftUIColor: Color { Color(.sRGB, red: r / 255, green: g / 255, blue: b / 255, opacity: a) }

    /// 从 SwiftUI Color 取回（ColorPicker 回写用）。
    init(color: Color) {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? NSColor.black
        self.init(r: Double(ns.redComponent) * 255, g: Double(ns.greenComponent) * 255,
                  b: Double(ns.blueComponent) * 255, a: Double(ns.alphaComponent))
    }
}
