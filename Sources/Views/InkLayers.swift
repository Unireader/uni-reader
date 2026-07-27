import SwiftUI

// MARK: - 墨迹层（Equatable 拆层：静态笔迹 + 活体笔迹）

/// 静态笔迹层。`session` 是 `@ObservedObject`，hover/pressRing/radial/liveStroke 等高频 @Published
/// 更新会让整页 body 重算；墨迹 Canvas 不可比较 → 每帧整页笔迹重栅格化（笔多即卡）。
/// 拆成 Equatable 层后：笔迹集合没变就跳过 body、复用已栅格化的内容，只在落笔/擦除/缩放时才重绘。
struct InkStaticLayer: View, Equatable {
    let strokes: [InkStroke]
    let inkScale: CGFloat

    static func == (l: Self, r: Self) -> Bool { l.strokes == r.strokes && l.inkScale == r.inkScale }

    var body: some View {
        Canvas { ctx, sz in
            for st in strokes { inkDrawStroke(st, in: &ctx, size: sz, inkScale: inkScale) }
        }
        .allowsHitTesting(false)
    }
}

/// 活体笔迹层（正在落墨的这一笔）：每帧只重画单笔，不再拖着整页静态笔迹重绘。
struct InkLiveLayer: View, Equatable {
    let live: InkStroke
    let inkScale: CGFloat

    var body: some View {
        Canvas { ctx, sz in
            inkDrawStroke(live, in: &ctx, size: sz, inkScale: inkScale)
        }
        .allowsHitTesting(false)
    }
}

/// 四种笔型差异化渲染（与 capture.html 的 `drawStroke` 同参数/同算法，见 `PenBrushType`/`InkRender`；墨迹不随夜间反色）：
///  · ballpoint 干净压感线；· fountain 压感 + 起收锥度；· marker 恒宽·平头·multiply 叠加；· pencil 多道微波动叠加。
func inkDrawStroke(_ st: InkStroke, in ctx: inout GraphicsContext, size: CGSize, inkScale: CGFloat) {
    guard !st.points.isEmpty else { return }
    let pts = st.points.map { CGPoint(x: $0.x * size.width, y: $0.y * size.height) }
    let type = st.type, w = st.width
    func color(_ a: Double) -> Color {
        Color(red: st.color.r / 255, green: st.color.g / 255, blue: st.color.b / 255, opacity: a)
    }

    if pts.count == 1 {
        let a = type == .pencil ? st.color.a * 0.6 : st.color.a
        let r = CGFloat(type.strokeWidth(pressure: st.points[0].z, base: w)) * inkScale / 2
        ctx.fill(Path(ellipseIn: CGRect(x: pts[0].x - r, y: pts[0].y - r, width: r * 2, height: r * 2)),
                 with: .color(color(a)))
        return
    }

    switch type {
    case .marker:
        // 恒宽 → 整条一次成 path，一次 multiply + 平头（逐段方头叠加会在接缝处出竖条）
        var path = Path(); path.move(to: pts[0]); var lastPt = pts[0]
        for i in 1..<pts.count {
            let mid = CGPoint(x: (lastPt.x + pts[i].x) / 2, y: (lastPt.y + pts[i].y) / 2)
            path.addQuadCurve(to: mid, control: lastPt); lastPt = pts[i]
        }
        path.addLine(to: lastPt)   // 补末段（同下方 default 分支：中点平滑链止于倒数两点的中点，末点从没连上）
        var m = ctx; m.blendMode = .multiply
        m.stroke(path, with: .color(color(st.color.a)),
                 style: StrokeStyle(lineWidth: CGFloat(w) * inkScale, lineCap: .square, lineJoin: .round))

    case .pencil:
        // 逐点变线宽（压感）没法像 marker 一样整条一次 stroke；但逐段分别 stroke() 会让相邻段共享端点的
        // 圆头各自半透明合成、越叠越黑（黑点瑕疵的根因）。改成拼一条可变宽度缎带、一次 fill() 画完整道。
        for pass in PenBrushType.pencilPasses {
            let col = color(st.color.a * pass.alpha)
            var center: [CGPoint] = []; var halfW: [CGFloat] = []
            for i in 0..<pts.count {
                let lw = type.strokeWidth(pressure: st.points[i].z, base: w)
                let (nx, ny) = InkRender.perp(pts, i)
                let rnd = InkRender.jitter(st.points[i].x, st.points[i].y + pass.phase)
                let wob = (sin(Double(i) * 0.7 + pass.phase) * pass.amp + rnd * pass.amp * 0.7) * lw * Double(inkScale)
                center.append(CGPoint(x: pts[i].x + nx * CGFloat(wob), y: pts[i].y + ny * CGFloat(wob)))
                halfW.append(CGFloat(max(0.7, lw * pass.wScale)) * inkScale / 2)
            }
            ctx.fill(InkRender.ribbon(center, halfWidths: halfW), with: .color(col))
        }

    default:   // ballpoint / fountain
        // 曾经也是逐段（按中点平滑链）单独 stroke()：alpha=1 的默认预设看不出来，但 ColorPicker
        // 支持调透明度（PenRack.swift），调低了一样会在每个中点出现跟铅笔同款的深色叠色点。
        // 改法同铅笔：把平滑链采样成一条中心线 + 逐点半宽，拼成缎带一次 fill()。
        let n = pts.count
        func lwAt(_ i: Int) -> CGFloat {
            CGFloat(type.strokeWidth(pressure: st.points[i].z, base: w)
                    * type.fountainTaper(index: i, count: n)) * inkScale
        }
        let curveSteps = 5
        var center: [CGPoint] = [pts[0]]
        var halfW: [CGFloat] = [lwAt(0) / 2]
        var lastMid = pts[0], lastPt = pts[0], lastW = lwAt(0)
        for i in 1..<n {
            let mid = CGPoint(x: (lastPt.x + pts[i].x) / 2, y: (lastPt.y + pts[i].y) / 2)
            let w1 = lwAt(i)
            for s in 1...curveSteps {
                let t = CGFloat(s) / CGFloat(curveSteps), u = 1 - t
                let a0 = u * u, a1 = 2 * u * t, a2 = t * t
                let x = a0 * lastMid.x + a1 * lastPt.x + a2 * mid.x
                let y = a0 * lastMid.y + a1 * lastPt.y + a2 * mid.y
                center.append(CGPoint(x: x, y: y))
                halfW.append((lastW * u + w1 * t) / 2)
            }
            lastMid = mid; lastPt = pts[i]; lastW = w1
        }
        // 补末段：中点平滑链止于倒数两点的中点，末点从没连上——长笔画差这半段看不出来，
        // 两点直线（尺子）就是整整少画一半（线尾追不上笔尖）。这里补一个点让缎带延到笔尖。
        center.append(pts[n - 1]); halfW.append(lwAt(n - 1) / 2)
        ctx.fill(InkRender.ribbon(center, halfWidths: halfW), with: .color(color(st.color.a)))
    }
}
