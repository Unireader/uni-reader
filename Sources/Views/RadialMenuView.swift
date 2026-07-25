import SwiftUI

// MARK: - 环形选笔盘

/// 长按呼出的环形选笔盘（页锚定于笔尖处，纯显示——高亮由 Mac 端按笔位算好塞进 `radial.highlight`）。
/// 整圆两层（半径分层）：外环 = 小手（正上，扇区 0）/ 橡皮擦（正下，扇区 n-1）；
/// 内环 = 各支笔整圆均布（扇区 1..pens.count，0 号正上方起顺时针）。中心圆 = 取消区。
struct RadialMenuView: View {
    let radial: RadialState
    let pens: [PenPreset]
    let size: CGSize

    private let penR: CGFloat = 70     // 内环：笔
    private let toolR: CGFloat = 118   // 外环：小手/橡皮擦（与内环间距 ≥ 高亮图标直径，避免重叠）
    private let pad: CGFloat = 34

    var body: some View {
        let side = (toolR + pad) * 2
        let c = side / 2
        let n = max(2, pens.count + 2)
        ZStack {
            Circle().fill(.ultraThinMaterial)   // 毛玻璃底盘（系统最薄一档）
                .overlay(Circle().stroke(.white.opacity(0.25), lineWidth: 1))
                .frame(width: (toolR + pad - 10) * 2, height: (toolR + pad - 10) * 2)
            Circle().fill(.white.opacity(radial.highlight < 0 ? 0.14 : 0.05))
                .frame(width: 66, height: 66)   // 中心取消区（未指向任何扇区时高亮）
            ForEach(0..<n, id: \.self) { i in
                // 扇区中心角（从正上方起、顺时针）：小手正上、橡皮擦正下，笔整圆均布
                let isTool = (i == 0 || i == n - 1)
                let th = i == 0 ? 0.0 : (i == n - 1 ? Double.pi : 2 * Double.pi * Double(i - 1) / Double(max(1, pens.count)))
                let R: CGFloat = isTool ? toolR : penR
                Group {
                    if i == 0 { toolTip("hand.raised.fill", tint: .teal, highlighted: radial.highlight == 0) }
                    else if i == n - 1 { toolTip("eraser.fill", tint: .orange, highlighted: radial.highlight == n - 1) }
                    else { penTip(pens[i - 1], highlighted: radial.highlight == i) }
                }
                .position(x: c + R * CGFloat(sin(th)), y: c - R * CGFloat(cos(th)))
            }
        }
        .frame(width: side, height: side)
        .position(x: radial.cx * size.width, y: radial.cy * size.height)
        .allowsHitTesting(false)
        .transaction { $0.animation = nil }
    }

    @ViewBuilder private func penTip(_ pen: PenPreset, highlighted: Bool) -> some View {
        let d: CGFloat = highlighted ? 46 : 34
        ZStack {
            Circle().fill(.white)
            Circle().fill(pen.color.swiftUIColor)
            Image(systemName: pen.type.systemImage)
                .font(.system(size: highlighted ? 17 : 13, weight: .bold))
                .foregroundStyle(contrastText(pen.color))
        }
        .frame(width: d, height: d)
        .overlay(Circle().stroke(highlighted ? Color.accentColor : .white.opacity(0.55),
                                 lineWidth: highlighted ? 3 : 1))
        .shadow(color: .black.opacity(highlighted ? 0.35 : 0), radius: 4, y: 1)
    }

    /// 工具项（橡皮擦/小手）：白底 + 固定色图标，与彩色笔头区分。
    @ViewBuilder private func toolTip(_ systemName: String, tint: Color, highlighted: Bool) -> some View {
        let d: CGFloat = highlighted ? 46 : 34
        ZStack {
            Circle().fill(.white)
            Image(systemName: systemName)
                .font(.system(size: highlighted ? 18 : 14, weight: .bold))
                .foregroundStyle(tint)
        }
        .frame(width: d, height: d)
        .overlay(Circle().stroke(highlighted ? Color.accentColor : .white.opacity(0.55),
                                 lineWidth: highlighted ? 3 : 1))
        .shadow(color: .black.opacity(highlighted ? 0.35 : 0), radius: 4, y: 1)
    }

    private func contrastText(_ c: InkColor) -> Color {
        let lum = (0.299 * c.r + 0.587 * c.g + 0.114 * c.b) / 255
        return lum > 0.62 ? .black : .white
    }
}
