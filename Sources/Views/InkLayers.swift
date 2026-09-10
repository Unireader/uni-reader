import SwiftUI

// MARK: - 墨迹层（Equatable 拆层：静态笔迹 + 活体笔迹）

/// 静态笔迹层。`session` 是 `@ObservedObject`，hover/pressRing/radial/liveStroke 等高频 @Published
/// 更新会让整页 body 重算；墨迹 Canvas 不可比较 → 每帧整页笔迹重栅格化（笔多即卡）。
/// 拆成 Equatable 层后：笔迹集合没变就跳过 body、复用已栅格化的内容，只在落笔/擦除/缩放时才重绘。
struct InkStaticLayer: View, Equatable {
    let strokes: [InkStroke]
    let inkScale: CGFloat
    /// 画板模式的每侧页边宽度（像素）。Canvas 自己比页宽 `2×margin`，一条跨页边的笔画因此
    /// **整条画在同一层**（分成页内/页外两层会让跨界的那一笔被页图切成两段）。
    var margin: CGFloat = 0
    /// 快速描边（缩放进行中）：见 `inkDrawStroke` 的 `fast`。
    var fast: Bool = false
    /// 仅供 `ZoomProbe` 报"这一帧重绘了哪几页"（不参与 Equatable——它随页固定，本就不会变）。
    var pageIndex: Int = -1
    /// 文档键（`contentHash`），打开耗时账本按它找到进行中的那本（`OpenStats.trace(docKey:)`）。
    /// 同 `pageIndex`：不参与 Equatable。
    var docKey: String = ""

    static func == (l: Self, r: Self) -> Bool {
        // 先比标量再比点集：缩放中 `fast`/`inkScale` 必变，把 O(总点数) 的深比较短路掉。
        l.inkScale == r.inkScale && l.margin == r.margin && l.fast == r.fast && l.strokes == r.strokes
    }

    var body: some View {
        Canvas { ctx, sz in
            // 打开耗时账本：只在这份文档正有一本账在记时才计时（一次字典查找，其余时候零开销）。
            let trace = docKey.isEmpty ? nil : MainActor.assumeIsolated { OpenStats.trace(docKey: docKey) }
            let t0 = (ZoomProbe.enabled || trace != nil) ? CFAbsoluteTimeGetCurrent() : 0
            if fast {
                // 缩放中整层一次分组绘制（见 `inkDrawStrokesFast`）——逐笔调用是缩放期的主成本
                inkDrawStrokesFast(strokes, in: &ctx, size: sz, inkScale: inkScale, margin: margin)
            } else {
                for st in strokes {
                    inkDrawStroke(st, in: &ctx, size: sz, inkScale: inkScale, margin: margin)
                }
            }
            if t0 > 0 {
                let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000
                if ZoomProbe.enabled {
                    ZoomProbe.inkDraw(page: pageIndex, strokes: strokes.count, fast: fast, ms: ms)
                }
                if let trace {
                    MainActor.assumeIsolated { trace.noteInkDraw(page: pageIndex, strokes: strokes.count, ms: ms) }
                }
            }
        }
        .allowsHitTesting(false)
    }
}

/// 活体笔迹层（正在落墨的这一笔）：每帧只重画单笔，不再拖着整页静态笔迹重绘。
struct InkLiveLayer: View, Equatable {
    let live: InkStroke
    let inkScale: CGFloat
    var margin: CGFloat = 0
    var fast: Bool = false

    var body: some View {
        Canvas { ctx, sz in
            inkDrawStroke(live, in: &ctx, size: sz, inkScale: inkScale, margin: margin, fast: fast)
        }
        .allowsHitTesting(false)
    }
}

/// 四种笔型差异化渲染（与 capture.html 的 `drawStroke` 同参数/同算法，见 `PenBrushType`/`InkRender`；墨迹不随夜间反色）：
///  · ballpoint 干净压感线；· fountain 压感 + 起收锥度；· marker 恒宽·平头·multiply 叠加；· pencil 多道微波动叠加。
/// `margin` = 画板模式下 Canvas 比页面**每侧**多出的像素：页宽 = `size.width − 2×margin`，
/// 页的左边缘落在 x = margin，于是归一化 x 越界（页边笔迹）自然画到页外那片空白上。
func inkDrawStroke(_ st: InkStroke, in ctx: inout GraphicsContext, size: CGSize, inkScale: CGFloat,
                   margin: CGFloat = 0, fast: Bool = false) {
    // 页内笔迹：归一化点 × 页显示尺寸。x/y 各乘各的（页内归一化两轴尺度不同）。
    let pw = size.width - margin * 2
    inkDrawStroke(st, in: &ctx, inkScale: inkScale, fast: fast) {
        CGPoint(x: CGFloat($0.x) * pw + margin, y: CGFloat($0.y) * size.height)
    }
}

/// 快速态的屏幕点抽稀：相邻点在屏幕上不足 `minStep` 的并掉，首末点必留。
/// 一并返回全笔平均压感（快速态用恒宽，不逐点变宽）。
/// 缩小时收益极大——zoom 0.31 时真实笔迹的点数只剩 16%（用「408学习区」9.2 万个点实测）。
func thinnedScreenPoints(_ st: InkStroke, minStep: CGFloat = 1.5,
                         map: (InkPoint) -> CGPoint) -> (pts: [CGPoint], avgZ: Double) {
    var zSum = 0.0
    for p in st.points { zSum += p.dz }
    let avgZ = st.points.isEmpty ? 0.5 : zSum / Double(st.points.count)
    guard st.points.count > 2 else { return (st.points.map(map), avgZ) }
    var out = [map(st.points[0])]
    var last = out[0]
    for i in 1..<(st.points.count - 1) {
        let p = map(st.points[i])
        let dx = abs(p.x - last.x), dy = abs(p.y - last.y)
        guard dx + dy >= minStep else { continue }
        out.append(p); last = p
    }
    out.append(map(st.points[st.points.count - 1]))   // 末点必留（尺子那种两点直线全靠它）
    return (out, avgZ)
}

/// 缩放期间的**整层**快速绘制：按「颜色 + 量化线宽 + 是否 marker」把整页笔迹**分组**，
/// 每组合成一条 Path、只调一次 `ctx.stroke`。
///
/// 🔴 真机实测（2026-08-29）：一页 94 笔逐笔画要 2.5ms，而抽稀之后每笔只剩 5~10 段——
/// 钱几乎全花在 `GraphicsContext` 的**逐笔调用开销**上，不是路径本身。而这个工作区里
/// 88.8% 的笔迹是同一支笔（ballpoint + 同色同宽），分组后一页的 stroke 调用从 94 次降到个位数。
/// 代价：缩放**过程中**同组笔迹恒宽（没有压感起伏），且半透明笔的交叠处会略深（同一条 Path 自重叠
/// 只合成一次，反而比逐笔画更接近高质量版）。松手 `settleRender` 即换回逐笔高质量。
func inkDrawStrokesFast(_ strokes: [InkStroke], in ctx: inout GraphicsContext,
                        size: CGSize, inkScale: CGFloat, margin: CGFloat) {
    struct Key: Hashable {
        var r = 0.0, g = 0.0, b = 0.0, a = 0.0
        var lwHalf = 0          // 线宽 ×2 取整 = 0.5pt 粒度；缩放中这点差别看不出来
        var marker = false      // marker 要 multiply + 平头，单独成组
    }
    let pw = size.width - margin * 2
    var groups: [Key: Path] = [:]
    var dots: [(CGPoint, CGFloat, Key)] = []   // 单点笔迹（画圆点，数量极少）
    for st in strokes {
        guard !st.points.isEmpty else { continue }
        // 阈值 3pt（比单笔快速路径的 1.5pt 更狠）：这是**整页几百条笔迹**的场合，光栅化段数
        // 才是剩下的成本。缩放中画面在动，3pt 以内的折角肉眼分不出；松手即按原始点重画。
        let (pts, avgZ) = thinnedScreenPoints(st, minStep: 3) {
            CGPoint(x: CGFloat($0.x) * pw + margin, y: CGFloat($0.y) * size.height)
        }
        let isMarker = st.type == .marker
        // marker 恒宽；其余用全笔平均压感折算的恒宽；pencil 的三道叠加在快速态合成一道
        let lw = CGFloat(isMarker ? st.width : st.type.strokeWidth(pressure: avgZ, base: st.width)) * inkScale
        let alpha = st.type == .pencil ? st.color.a * 0.53 : st.color.a
        var key = Key(r: st.color.r, g: st.color.g, b: st.color.b, a: alpha,
                      lwHalf: Int((max(0.5, lw) * 2).rounded()), marker: isMarker)
        if pts.count == 1 {
            dots.append((pts[0], max(0.5, lw) / 2, key))
            continue
        }
        var path = Path(); path.move(to: pts[0])
        var last = pts[0]
        for i in 1..<pts.count {
            let mid = CGPoint(x: (last.x + pts[i].x) / 2, y: (last.y + pts[i].y) / 2)
            path.addQuadCurve(to: mid, control: last)
            last = pts[i]
        }
        path.addLine(to: last)   // 补末段（中点平滑链止于倒数两点的中点，末点从没连上）
        key.lwHalf = max(1, key.lwHalf)
        groups[key, default: Path()].addPath(path)
    }
    for (k, path) in groups {
        let col = Color(red: k.r / 255, green: k.g / 255, blue: k.b / 255, opacity: k.a)
        let style = StrokeStyle(lineWidth: CGFloat(k.lwHalf) / 2,
                                lineCap: k.marker ? .square : .round, lineJoin: .round)
        if k.marker {
            var m = ctx; m.blendMode = .multiply
            m.stroke(path, with: .color(col), style: style)
        } else {
            ctx.stroke(path, with: .color(col), style: style)
        }
    }
    for (p, r, k) in dots {
        let col = Color(red: k.r / 255, green: k.g / 255, blue: k.b / 255, opacity: k.a)
        ctx.fill(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)),
                 with: .color(col))
    }
}

/// 同上，但坐标映射由调用方给。草稿纸走这条：画布坐标是**等比**的逻辑点，
/// 映射 = `(p − 视口原点) × zoom`，`inkScale` 同样传 zoom → 线宽随缩放走，与页内语义一致。
/// 拆出来的唯一目的是让四种笔型的渲染算法**一份实现两处用**，别再抄一遍（抄一遍就会分叉）。
/// `fast` = **缩放进行中的快速描边**：逐段直接 `stroke()`，不走 `strokedPath()` 转轮廓再合并 fill。
/// 几何、压感、锥度、线宽全都不变，唯一差别是相邻段共享端点的圆头改回各自半透明合成（接缝略深）
/// ——静态显示时这点叠色是要躲的（见下方各分支注释），但缩放**过程中**没人看得出，而它值 4 倍帧率。
/// 实测（`spike/reader-zoom-probe.swift`，178 笔/15000 点一页 × 3 页，模拟一次真实捏合）：
///   现状 `strokedPath`+`fill` 27ms/页 → **33 fps**；本快速路径 6.3ms/页 → **99 fps**。
/// 由 `ReaderSurface.inkFastDraw` 门控，`settleRender` 收尾即换回高质量重画一次。
func inkDrawStroke(_ st: InkStroke, in ctx: inout GraphicsContext, inkScale: CGFloat,
                   fast: Bool = false,
                   map: (InkPoint) -> CGPoint) {
    guard !st.points.isEmpty else { return }
    // `raw` = 原始采样点（压感、以及 pencil 的 jitter 种子都取自它），`pts` = 映射到屏幕后的点。
    // 快速态（缩放中）按**屏幕距离**抽稀两者：相邻点在屏幕上不足 `minStep` 的一律并掉。
    // 🔴 这是缩小态的成本大头——zoom 0.3 时一笔的相邻采样点在屏幕上往往不到 1px，逐段构造路径
    // 纯属白烧；而缩小时视口里同时有 5~6 页要画（真机日志：一个 250ms 窗口里墨迹 46 次共 103ms
    // = 41% 主线程）。抽稀后段数常常只剩零头，且**越缩越省**（正好是越缩越卡的那一侧）。
    // 观感：缩放**过程中**看不出差别（点被并掉的地方本来就不足一个像素），松手 settle 即按原始点重画。
    var raw = st.points
    var pts = raw.map(map)
    if fast, pts.count > 2 {
        let minStep: CGFloat = 1.5
        var keptRaw = [raw[0]], keptPts = [pts[0]]
        var last = pts[0]
        for i in 1..<(pts.count - 1) {
            // 曼哈顿距离够用（只是个"看不看得见"的阈值），省一次 sqrt
            let dx = abs(pts[i].x - last.x), dy = abs(pts[i].y - last.y)
            guard dx + dy >= minStep else { continue }
            keptRaw.append(raw[i]); keptPts.append(pts[i]); last = pts[i]
        }
        // 末点必须保留：两点直线（尺子）抽掉末点就是整条线缩一截
        keptRaw.append(raw[raw.count - 1]); keptPts.append(pts[pts.count - 1])
        raw = keptRaw; pts = keptPts
    }
    let type = st.type, w = st.width
    func color(_ a: Double) -> Color {
        Color(red: st.color.r / 255, green: st.color.g / 255, blue: st.color.b / 255, opacity: a)
    }

    if pts.count == 1 {
        let a = type == .pencil ? st.color.a * 0.6 : st.color.a
        let r = CGFloat(type.strokeWidth(pressure: raw[0].dz, base: w)) * inkScale / 2
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
        // 缩放中：单道整条一次 stroke。三 pass × 逐段抖动是 3 倍成本，而画面在动的时候
        // 石墨颗粒感根本看不出来。alpha 取三 pass 叠加的等效值（1−∏(1−aᵢ) ≈ 0.53）。
        if fast {
            var path = Path(); path.move(to: pts[0])
            var last = pts[0]
            for i in 1..<pts.count {
                let mid = CGPoint(x: (last.x + pts[i].x) / 2, y: (last.y + pts[i].y) / 2)
                path.addQuadCurve(to: mid, control: last)
                last = pts[i]
            }
            path.addLine(to: last)
            var zSum = 0.0
            for p in raw { zSum += p.dz }
            let lw = CGFloat(type.strokeWidth(pressure: zSum / Double(raw.count), base: w)) * inkScale
            ctx.stroke(path, with: .color(color(st.color.a * 0.53)),
                       style: StrokeStyle(lineWidth: max(0.7, lw), lineCap: .round, lineJoin: .round))
            return
        }
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
                let lw = type.strokeWidth(pressure: raw[i].dz, base: w)
                let (nx, ny) = InkRender.perp(pts, i)
                let rnd = InkRender.jitter(raw[i].dx, raw[i].dy + pass.phase)
                let wobW = min(lw, PenBrushType.pencilWobbleRefWidth)
                let wob = (sin(dist * PenBrushType.pencilWobbleFreq + pass.phase) * pass.amp
                           + rnd * pass.amp * 0.7) * wobW * Double(inkScale)
                let cur = CGPoint(x: pts[i].x + nx * CGFloat(wob), y: pts[i].y + ny * CGFloat(wob))
                if let p0 = prev {
                    var seg = Path(); seg.move(to: p0); seg.addLine(to: cur)
                    let style = StrokeStyle(lineWidth: CGFloat(max(0.7, lw * pass.wScale)) * inkScale,
                                             lineCap: .round, lineJoin: .round)
                    combined.addPath(seg.strokedPath(style))   // fast 已在上面整条画完并 return
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
        let col = color(st.color.a)
        // 🔴 缩放中（fast）：**整条一次 stroke**，恒宽取全笔平均压感。
        // 真机实测（2026-08-29）：抽稀之后一页仍要 1.5~2.3ms，钱全花在**逐段的 API 调用**上
        // ——一页 100 笔 × 每笔约 5 段 = 500 次 `ctx.stroke()`；整条一次后降到 100 次。
        // 代价：缩放**过程中**笔画粗细均匀（没有压感起伏与起收锥度），松手 settle 立刻恢复。
        // 画面在动的时候没人看得出粗细起伏，但每帧 2 页 × 2ms 是实打实的 42% 主线程。
        if fast {
            var path = Path(); path.move(to: pts[0])
            var last = pts[0]
            for i in 1..<n {
                let mid = CGPoint(x: (last.x + pts[i].x) / 2, y: (last.y + pts[i].y) / 2)
                path.addQuadCurve(to: mid, control: last)
                last = pts[i]
            }
            path.addLine(to: last)   // 补末段，同下方高质量路径
            var zSum = 0.0
            for p in raw { zSum += p.dz }
            let lw = CGFloat(type.strokeWidth(pressure: zSum / Double(raw.count), base: w)) * inkScale
            ctx.stroke(path, with: .color(col),
                       style: StrokeStyle(lineWidth: lw, lineCap: .round, lineJoin: .round))
            return
        }
        var combined = Path()
        var lastMid = pts[0], lastPt = pts[0]
        for i in 1..<pts.count {
            let mid = CGPoint(x: (lastPt.x + pts[i].x) / 2, y: (lastPt.y + pts[i].y) / 2)
            let lw = CGFloat(type.strokeWidth(pressure: raw[i].dz, base: w)
                             * type.fountainTaper(index: i, count: n)) * inkScale
            var p = Path(); p.move(to: lastMid); p.addQuadCurve(to: mid, control: lastPt)
            let style = StrokeStyle(lineWidth: lw, lineCap: .round, lineJoin: .round)
            if fast { ctx.stroke(p, with: .color(col), style: style) }   // 缩放中：省掉转轮廓（见 fast 注释）
            else { combined.addPath(p.strokedPath(style)) }
            lastMid = mid; lastPt = pts[i]
        }
        // 补末段：上面每步只画到「相邻两点的中点」，末点从来没被连上——长笔画差这半段看不出来，
        // 两点直线（尺子）就是整整少画一半（线尾追不上笔尖）。补一段 lastMid → 末点才落到笔尖。
        let tailW = type.strokeWidth(pressure: raw[n - 1].dz, base: w)
        let lw = CGFloat(tailW * type.fountainTaper(index: n - 1, count: n)) * inkScale
        var tail = Path(); tail.move(to: lastMid); tail.addLine(to: lastPt)
        let tailStyle = StrokeStyle(lineWidth: lw, lineCap: .round, lineJoin: .round)
        if fast {
            ctx.stroke(tail, with: .color(col), style: tailStyle)
        } else {
            combined.addPath(tail.strokedPath(tailStyle))
            ctx.fill(combined, with: .color(col))
        }
    }
}
