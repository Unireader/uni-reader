import SwiftUI
import AppKit

/// 笔头类型：真正不同的笔触渲染效果（不只是换个颜色/名字）。公式细节见 `PageStreamView.drawStroke`
/// 与 `capture.html` 的 `strokeWidthFor`（两边必须保持一致，否则 pad 本地实时反馈跟 Mac 同步后画面对不上）。
enum PenBrushType: String, Codable, CaseIterable {
    case ballpoint   // 圆珠笔：默认，压感响应适中（= 原来唯一的行为）
    case fountain    // 钢笔：压感响应更夸张，细笔画更细、重压更粗
    case marker      // 马克笔/荧光笔：忽略压感，恒定笔宽
    case pencil      // 铅笔：压感响应弱、略透明、边缘轻微抖动纹理

    var label: String {
        switch self {
        case .ballpoint: return L("Ballpoint")
        case .fountain: return L("Fountain Pen")
        case .marker: return L("Marker")
        case .pencil: return L("Pencil")
        }
    }

    var systemImage: String {
        switch self {
        case .ballpoint: return "pencil.tip"
        case .fountain: return "pencil.and.scribble"
        case .marker: return "highlighter"
        case .pencil: return "pencil"
        }
    }

    /// 笔宽公式（`p`=压感 0~1，`w`=预设粗细）。marker 恒定不吃压感；fountain 压感响应更夸张；
    /// pencil 响应弱一些。`PageStreamView.drawStroke` 用；capture.html 的 `strokeWidthFor` 是同一套公式的 JS 版。
    func strokeWidth(pressure p: Double, base w: Double) -> Double {
        switch self {
        case .ballpoint: return 0.6 + p * w
        case .fountain: return 0.3 + pow(p, 1.6) * w * 1.3   // 压感对比更大 → 书法般粗细变化
        case .marker: return w
        case .pencil: return 0.5 + p * w * 0.85
        }
    }

    /// 已弃用：各笔型透明观感现由渲染器按类型显式处理（马克=低 alpha + multiply 叠加、铅笔=多道半透明叠加）。
    /// 保留返回 1 兼容旧调用点（capture.html 的 live 反馈仍读它）。
    var opacityMultiplier: Double { 1 }

    /// 钢笔起收笔锥度（0~1 乘线宽）：`i/n` 为点在笔画中的归一化位置，两端渐细、中段为 1；非钢笔恒 1。
    func fountainTaper(index i: Int, count n: Int) -> Double {
        guard self == .fountain, n > 1 else { return 1 }
        let t = Double(i) / Double(n - 1), edge = 0.16
        let a = min(t, 1 - t) / edge
        return a >= 1 ? 1 : (a * a * (3 - 2 * a)) * 0.82 + 0.18
    }

    /// 铅笔「多道微波动叠加」参数：每道 (垂向波幅×线宽, 该道 alpha, 线宽比例, 相位)。
    /// 首道波幅 0 作居中核心，其余低频垂向波动——连续笔画不会串珠，层叠出中间深、边缘散的石墨纤维感。
    static let pencilPasses: [(amp: Double, alpha: Double, wScale: Double, phase: Double)] = [
        (0.0, 0.34, 0.55, 0.0), (0.34, 0.16, 0.45, 2.3), (0.34, 0.16, 0.45, 4.6)
    ]
}

/// 笔触差异化的**共享数学**——Mac 阅读区（SwiftUI GraphicsContext）与 SimPad（CGContext）各写一份画法，
/// 但线宽/锥度/铅笔多道/抖动/垂线这些参数与算法唯一出处在这里 + `PenBrushType`。
/// capture.html 有一份等价 JS 版（真平板本地反馈），改这里要同步那边。
enum InkRender {
    /// GLSL 风 hash → [-1,1]，种子用**归一化**坐标（缩放无关；铅笔纹理重绘不抖）。
    static func jitter(_ x: Double, _ y: Double) -> Double {
        let v = sin(x * 12.9898 + y * 78.233) * 43758.5453
        return (v - v.rounded(.down)) * 2 - 1
    }
    /// 点 i 处的路径垂线单位向量（用前后邻点估切线）。
    static func perp(_ pts: [CGPoint], _ i: Int) -> (CGFloat, CGFloat) {
        let a = pts[max(0, i - 1)], b = pts[min(pts.count - 1, i + 1)]
        let dx = b.x - a.x, dy = b.y - a.y
        let len = max(0.0001, (dx * dx + dy * dy).squareRoot())
        return (-dy / len, dx / len)
    }
}

/// 一支收藏笔：名字 + 颜色（含透明度）+ 粗细 + 笔头类型。
/// 画布悬浮工具条（`PenToolbar.swift`）实时增删改，非固定系统设置；采集页（平板）PageDown 仍能在列表里
/// 循环、但列表内容由 Mac 推送同步（见 `AppModel.broadcastPens`），不再是启动时注入后就固定不变。
/// 橡皮是独立「擦除」模式，不进笔列表。
struct PenPreset: Identifiable, Equatable, Codable {
    var id: UUID = UUID()
    var name: String
    var color: InkColor
    var width: Double
    var type: PenBrushType = .ballpoint

    enum CodingKeys: String, CodingKey { case id, name, color, width, type }

    init(id: UUID = UUID(), name: String, color: InkColor, width: Double, type: PenBrushType = .ballpoint) {
        self.id = id; self.name = name; self.color = color; self.width = width; self.type = type
    }

    /// 手写解码：旧数据（升级前存的 JSON）没有 `type` 键，合成的 Decodable 对缺失 key 不会补默认值、
    /// 会直接 decode 失败——必须显式 `decodeIfPresent` 兜底成 `.ballpoint`。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        color = try c.decode(InkColor.self, forKey: .color)
        width = try c.decode(Double.self, forKey: .width)
        type = try c.decodeIfPresent(PenBrushType.self, forKey: .type) ?? .ballpoint
    }
}

/// 笔预设的持久化（本机 UserDefaults · JSON）。设置页编辑、采集页/SimPad 消费。
enum PenPresets {
    static let key = "penPresets"

    static let defaults: [PenPreset] = [
        PenPreset(name: "蓝", color: InkColor(r: 24, g: 90, b: 210, a: 0.95), width: 8, type: .ballpoint),
        PenPreset(name: "红", color: InkColor(r: 220, g: 40, b: 40, a: 0.95), width: 9, type: .fountain),
        PenPreset(name: "黑", color: InkColor(r: 20, g: 20, b: 20, a: 0.95), width: 10, type: .pencil),
        PenPreset(name: "荧光", color: InkColor(r: 255, g: 214, b: 40, a: 0.40), width: 22, type: .marker),
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

    /// 注入采集页的 JSON：`[{name, color(css rgba), w, t}]`（与 capture.html 的 PENS 结构一致）。
    /// 只作启动兜底（首次 WS 消息到达前 pad 至少有支笔能画）；之后由 `AppModel.broadcastPens` 的 `"pens"`
    /// 消息接管，作为运行时唯一同步源。
    static func captureJSON() -> String {
        let items = load().map { p in
            "{\"name\":\(jsonString(p.name)),\"color\":\"\(p.color.cssRGBA)\",\"w\":\(p.width),\"t\":\"\(p.type.rawValue)\"}"
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
