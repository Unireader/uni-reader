import SwiftUI

// MARK: - 环形选笔盘（Surface Dial 形制）

/// 长按呼出的环形选笔盘（页锚定于笔尖处，纯显示——扇区判定由 Mac 端按笔位算好塞进 `radial.highlight`）。
///
/// 形制参考 Microsoft Surface Dial 的 radial menu：**单层整圆**的甜甜圈楔形，扇区等分 360°、
/// 第 0 项中心在正上方（12 点）顺时针排列，中心 hub 回显当前指向项的名字。布局契约在 `RadialLayout`，
/// 平板端 `capture.html` 的 `drawRadial` 画的是同一个盘（同一组半径/角度常量）。
///
/// 选择只看角度、不看半径——半径分层要求精确控制笔离中心的距离，而那个距离随两端缩放漂移。
struct RadialMenuView: View {
    let radial: RadialState
    let pens: [PenPreset]
    let size: CGSize

    /// 通透度三档（越小越透）。盘是叠在页面内容上的，压暗只用来托住扇区形状，**不**用来堆对比度——
    /// 对比度由各图标自带的色片和文字阴影提供。调浓淡改这三个数即可（`capture.html` 有对应的一组）。
    private static let baseDim = 0.10    // 盘底
    private static let wedgeDim = 0.16   // 未选中扇区
    private static let hubDim = 0.22     // 中心 hub

    private var outerR: CGFloat { RadialLayout.outerRadius }
    private var innerR: CGFloat { RadialLayout.innerRadius }
    private var hubR: CGFloat { RadialLayout.hubRadius }
    private var iconR: CGFloat { (innerR + outerR) / 2 }   // 图标落位半径

    var body: some View {
        let items = RadialLayout.items(penCount: pens.count)
        let n = max(1, items.count)
        let side = (outerR + 14) * 2
        let c = CGPoint(x: side / 2, y: side / 2)
        ZStack {
            // 盘底：只有最薄一档材质 + 一层很淡的压暗——底下的页面内容要能透出来（压太狠就成了实心灰盘）。
            // 对比度不靠盘底堆，靠扇区环带 + 各图标自带的色片，见 `icon`。
            Circle()
                .fill(.ultraThinMaterial)
                .overlay(Circle().fill(.black.opacity(Self.baseDim)))
                .overlay(Circle().strokeBorder(.white.opacity(0.22), lineWidth: 1))
                .frame(width: outerR * 2, height: outerR * 2)
                .shadow(color: .black.opacity(0.3), radius: 16, y: 4)

            // 扇区楔形：未选中只有一层极淡的底，选中整块上色（Surface Dial 的选中反馈就是整个扇区亮起）。
            // 楔形路径用的是「盘坐标系」（原点 = 盘左上、中心 = side/2），故显式给满 side×side，
            // 免得 ZStack 把 Shape 布局成别的尺寸导致圆心偏。
            ForEach(0..<n, id: \.self) { i in
                let on = radial.highlight == i
                let wedge = wedgePath(i, of: n, center: c)
                ZStack {
                    wedge.fill(on ? tint(items[i]).opacity(0.92) : Color.black.opacity(Self.wedgeDim))
                    if on { wedge.stroke(.white.opacity(0.65), lineWidth: 1.5) }
                }
                .frame(width: side, height: side)
            }

            // 扇区图标。
            ForEach(0..<n, id: \.self) { i in
                icon(items[i], highlighted: radial.highlight == i)
                    .position(pointAt(angleOf(i, of: n), radius: iconR, center: c))
            }

            // 中心 hub：取消区 + 当前指向项回显。
            hub(items: items)
                .position(c)
        }
        .frame(width: side, height: side)
        .position(x: radial.cx * size.width, y: radial.cy * size.height)
        .allowsHitTesting(false)
        .transaction { $0.animation = nil }
    }

    // MARK: 几何

    /// 第 i 个扇区的中心角（度，0 = 正上方、顺时针）。
    private func angleOf(_ i: Int, of n: Int) -> Double { Double(i) * 360.0 / Double(n) }

    /// 「0=正上方顺时针」的角度 → 该半径上的点。SwiftUI 的 0° 在 3 点方向，故减 90°。
    private func pointAt(_ deg: Double, radius: CGFloat, center c: CGPoint) -> CGPoint {
        let rad = (deg - 90) * .pi / 180
        return CGPoint(x: c.x + radius * CGFloat(cos(rad)), y: c.y + radius * CGFloat(sin(rad)))
    }

    /// 一个扇区的甜甜圈楔形（内缘 innerR、外缘 outerR，两侧各留 `gapDegrees` 分隔缝）。
    private func wedgePath(_ i: Int, of n: Int, center c: CGPoint) -> Path {
        let step = 360.0 / Double(n)
        let gap = min(RadialLayout.gapDegrees, step / 4)
        let a0 = angleOf(i, of: n) - step / 2 + gap - 90
        let a1 = angleOf(i, of: n) + step / 2 - gap - 90
        var p = Path()
        p.addArc(center: c, radius: outerR, startAngle: .degrees(a0), endAngle: .degrees(a1), clockwise: false)
        p.addArc(center: c, radius: innerR, startAngle: .degrees(a1), endAngle: .degrees(a0), clockwise: true)
        p.closeSubpath()
        return p
    }

    // MARK: 内容

    private func tint(_ item: RadialItem) -> Color {
        switch item {
        case .pen(let i): return pens.indices.contains(i) ? pens[i].color.swiftUIColor : .accentColor
        case .erase: return Color(red: 0.96, green: 0.55, blue: 0.20)
        case .page: return Color(red: 0.25, green: 0.72, blue: 0.70)
        }
    }

    @ViewBuilder private func icon(_ item: RadialItem, highlighted on: Bool) -> some View {
        switch item {
        case .pen(let i):
            if pens.indices.contains(i) {
                let pen = pens[i]
                // 笔：主体信息是颜色，故画成一枚笔色圆点，笔头类型的符号叠在里面。
                disc(fill: pen.color.swiftUIColor, symbol: pen.type.systemImage,
                     symbolColor: contrastText(pen.color), highlighted: on)
            }
        case .erase:
            disc(fill: tint(.erase), symbol: "eraser.fill", symbolColor: .white, highlighted: on)
        case .page:
            disc(fill: tint(.page), symbol: "hand.raised.fill", symbolColor: .white, highlighted: on)
        }
    }

    /// 扇区图标统一形制：一枚彩色圆片 + 符号。盘底透着页面内容，裸符号会被白页吞掉，故每个图标自带底片。
    @ViewBuilder private func disc(fill: Color, symbol: String, symbolColor: Color, highlighted on: Bool) -> some View {
        ZStack {
            Circle()
                .fill(fill)
                .overlay(Circle().strokeBorder(.white.opacity(on ? 0.9 : 0.55), lineWidth: on ? 2 : 1))
            Image(systemName: symbol)
                .font(.system(size: on ? 15 : 13, weight: .semibold))
                .foregroundStyle(symbolColor)
        }
        .frame(width: on ? 34 : 28, height: on ? 34 : 28)
        .shadow(color: .black.opacity(0.3), radius: on ? 5 : 3, y: 1)
    }

    /// 中心 hub：既是取消区，也是当前指向项的回显（Surface Dial 的中心也显示当前项名字）。
    @ViewBuilder private func hub(items: [RadialItem]) -> some View {
        let sel = items.indices.contains(radial.highlight) ? items[radial.highlight] : nil
        ZStack {
            Circle()
                .fill(.black.opacity(sel == nil ? Self.hubDim + 0.06 : Self.hubDim))
                .overlay(Circle().strokeBorder(.white.opacity(sel == nil ? 0.55 : 0.2), lineWidth: sel == nil ? 2 : 1))
            VStack(spacing: 2) {
                Text(hubTitle(sel))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(sel == nil ? 0.85 : 1))
                if let sub = hubSubtitle(sel) {
                    Text(sub)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .padding(.horizontal, 8)
            .shadow(color: .black.opacity(0.55), radius: 3, y: 1)   // hub 底变淡了，文字靠自身阴影保可读
        }
        .frame(width: hubR * 2, height: hubR * 2)
    }

    private func hubTitle(_ item: RadialItem?) -> String {
        switch item {
        case .none: return L("Cancel")
        case .pen(let i): return pens.indices.contains(i) ? pens[i].name : L("Pen")
        case .erase: return L("Eraser")
        case .page: return L("Page Turn")
        }
    }

    private func hubSubtitle(_ item: RadialItem?) -> String? {
        guard case .pen(let i) = item, pens.indices.contains(i) else { return nil }
        let p = pens[i]
        return "\(p.type.label) · \(Self.ptFormat(p.width))pt"
    }

    /// 粗细显示：整数不带小数点，小数最多两位（跟笔架里的收敛规则一致）。
    private static func ptFormat(_ w: Double) -> String {
        let r = (w * 100).rounded() / 100
        return r == r.rounded() ? String(Int(r)) : String(r)
    }

    private func contrastText(_ c: InkColor) -> Color {
        let lum = (0.299 * c.r + 0.587 * c.g + 0.114 * c.b) / 255
        return lum > 0.62 ? .black : .white
    }
}
