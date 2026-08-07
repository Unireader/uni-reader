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
    // 页内笔迹：归一化点 × 页显示尺寸。x/y 各乘各的（页内归一化两轴尺度不同）。
    inkDrawStroke(st, in: &ctx, inkScale: inkScale) {
        CGPoint(x: $0.x * size.width, y: $0.y * size.height)
    }
}

/// 同上，但坐标映射由调用方给。草稿纸走这条：画布坐标是**等比**的逻辑点，
/// 映射 = `(p − 视口原点) × zoom`，`inkScale` 同样传 zoom → 线宽随缩放走，与页内语义一致。
/// 拆出来的唯一目的是让四种笔型的渲染算法**一份实现两处用**，别再抄一遍（抄一遍就会分叉）。
func inkDrawStroke(_ st: InkStroke, in ctx: inout GraphicsContext, inkScale: CGFloat,
                   map: (SIMD3<Double>) -> CGPoint) {
    guard !st.points.isEmpty else { return }
    let pts = st.points.map(map)
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
        // 圆头各自半透明合成、越叠越黑（黑点瑕疵的根因）。改法：每段照旧转成描边轮廓——
        // `strokedPath` 是 Core Graphics 自己的 stroke→fill 几何，圆头/圆角天然正确，不必自己算法向量、
        // 急转弯处也不会像手搓垂线偏移那样豁口/出刺——攒进同一条 Path，这一道结束时只 fill() 一次，
        // 共享端点的重叠只是同一次填充里的自重叠，不再重复合成。
        //
        // 波动相位按「累计弧长」推进，不按点序号：运笔几乎都是收笔前减速，同一采样率下减速处点更密，
        // 若按点序号走，稠密处波形在屏幕上就被压缩成快速抖动的锯齿（越到笔画尾部越密集越尖），
        // 参考图里五条粗细不同的笔画无一例外尾部全炸开就是这个根因。按弧长走，波动频率只取决于
        // 画了多远的物理距离，与运笔快慢/采样疏密无关，笔画全程波形疏密一致。
        for pass in PenBrushType.pencilPasses {
            let col = color(st.color.a * pass.alpha)
            var combined = Path()
            var prev: CGPoint?
            var dist: Double = 0
            for i in 0..<pts.count {
                if i > 0 {
                    let dx = Double(pts[i].x - pts[i - 1].x), dy = Double(pts[i].y - pts[i - 1].y)
                    dist += (dx * dx + dy * dy).squareRoot()
                }
                let lw = type.strokeWidth(pressure: st.points[i].z, base: w)
                let (nx, ny) = InkRender.perp(pts, i)
                let rnd = InkRender.jitter(st.points[i].x, st.points[i].y + pass.phase)
                let wobW = min(lw, PenBrushType.pencilWobbleRefWidth)
                let wob = (sin(dist * PenBrushType.pencilWobbleFreq + pass.phase) * pass.amp
                           + rnd * pass.amp * 0.7) * wobW * Double(inkScale)
                let cur = CGPoint(x: pts[i].x + nx * CGFloat(wob), y: pts[i].y + ny * CGFloat(wob))
                if let p0 = prev {
                    var seg = Path(); seg.move(to: p0); seg.addLine(to: cur)
                    let style = StrokeStyle(lineWidth: CGFloat(max(0.7, lw * pass.wScale)) * inkScale,
                                             lineCap: .round, lineJoin: .round)
                    combined.addPath(seg.strokedPath(style))
                }
                prev = cur
            }
            ctx.fill(combined, with: .color(col))
        }

    default:   // ballpoint / fountain
        // 曾经也是逐段（按中点平滑链）单独 stroke()：alpha=1 的默认预设看不出来，但 ColorPicker
        // 支持调透明度（PenRack.swift），调低了一样会在每个中点出现跟铅笔同款的深色叠色点。
        // 改法同铅笔：每段的 stroke 照旧转成 `strokedPath` 轮廓，攒进一条 Path，收尾一次 fill()。
        let n = pts.count
        var combined = Path()
        var lastMid = pts[0], lastPt = pts[0]
        for i in 1..<pts.count {
            let mid = CGPoint(x: (lastPt.x + pts[i].x) / 2, y: (lastPt.y + pts[i].y) / 2)
            let lw = CGFloat(type.strokeWidth(pressure: st.points[i].z, base: w)
                             * type.fountainTaper(index: i, count: n)) * inkScale
            var p = Path(); p.move(to: lastMid); p.addQuadCurve(to: mid, control: lastPt)
            combined.addPath(p.strokedPath(StrokeStyle(lineWidth: lw, lineCap: .round, lineJoin: .round)))
            lastMid = mid; lastPt = pts[i]
        }
        // 补末段：上面每步只画到「相邻两点的中点」，末点从来没被连上——长笔画差这半段看不出来，
        // 两点直线（尺子）就是整整少画一半（线尾追不上笔尖）。补一段 lastMid → 末点才落到笔尖。
        let tailW = type.strokeWidth(pressure: st.points[n - 1].z, base: w)
        let lw = CGFloat(tailW * type.fountainTaper(index: n - 1, count: n)) * inkScale
        var tail = Path(); tail.move(to: lastMid); tail.addLine(to: lastPt)
        combined.addPath(tail.strokedPath(StrokeStyle(lineWidth: lw, lineCap: .round, lineJoin: .round)))
        ctx.fill(combined, with: .color(color(st.color.a)))
    }
}
