import SwiftUI

// 草稿纸的三个画布层（网格 / 笔迹 / minimap）。从 `ScratchPadView.swift` 拆出来：
// 它们是纯绘制、不碰 AppModel/DocSession，独立成文件后 `spike/scratch-look.swift`
// 才能只编这几个文件就用 ImageRenderer 出样张自查（自绘图形交付前的既有纪律）。

// MARK: - 定位参照层（淡点阵 + 原点标记）

/// 无限画布的空间感知。一张纯白的纸在平移时**看不出自己在动**，缩放时也看不出缩了多少——
/// 这是它最初读起来「生硬」的另一半原因（另一半是那条横贯全宽的工具栏）。
/// 一层极淡的点阵就解决了：点跟着画布走，于是拖动/缩放都有了参照物。
///
/// 两条纪律：
///  · **淡到不抢戏**（0.10 不透明度左右）——它是参照物，不是内容，用户要的是「白底」；
///  · **屏幕间距自适应**：网格间距按画布坐标定死的话，缩到 0.2 倍就糊成一片、放到 8 倍就一屏一个点。
///    每次按 2 的幂折算回 [18, 72] 屏幕像素这个舒适区间，于是任何缩放级别下看上去密度都差不多。
///
/// 原点（= 这张纸创建时的位置、「回中」的落点）另画一个稍明显的十字，让「我在哪」有个答案。
struct ScratchGridLayer: View, Equatable {
    let viewport: ScratchViewport
    let ink: Color
    let pattern: ScratchPattern

    static func == (l: Self, r: Self) -> Bool {
        l.viewport == r.viewport && l.ink == r.ink && l.pattern == r.pattern
    }

    /// 画布坐标下的网格步长：从 24 起，按 2 的幂调到屏幕间距落进 [18, 72]。
    private var step: CGFloat {
        var s: CGFloat = 24
        let z = max(viewport.zoom, 0.0001)
        while s * z < 22 { s *= 2 }
        while s * z > 88 { s /= 2 }
        return s
    }

    var body: some View {
        Canvas { ctx, size in
            guard pattern != .plain else { return }   // 纯色纸：连原点十字都不画
            let z = viewport.zoom, o = viewport.origin, st = step
            // 点的大小/浓度：初版（1.6px 上限 / 0.10）在真机上「基本看不出来」——点阵间距本来就
             // 有 22~88px，点再细就没了。放大到 3px 上限 + 0.18 浓度，仍远淡于笔迹。
             // ⚠️ 这两个数与 web `scratch.ts drawPattern` 是同一套，改一边必须同步另一边。
            let dot = max(1.5, min(3, z * 1.8))
            // 视口覆盖的画布范围 → 对齐到网格
            let x0 = (o.x / st).rounded(.down) * st, y0 = (o.y / st).rounded(.down) * st
            let cols = Int(size.width / (st * z)) + 2, rows = Int(size.height / (st * z)) + 2
            guard cols > 0, rows > 0, cols * rows <= 20_000 else { return }   // 极端缩放下的安全阀
            if pattern == .grid {
                // 小格：横竖各一组细线。线比点更「有格子感」，但也更容易抢戏，故比点阵再淡一档。
                var lines = Path()
                for i in 0...cols {
                    let x = (x0 + CGFloat(i) * st - o.x) * z
                    lines.move(to: CGPoint(x: x, y: 0)); lines.addLine(to: CGPoint(x: x, y: size.height))
                }
                for j in 0...rows {
                    let y = (y0 + CGFloat(j) * st - o.y) * z
                    lines.move(to: CGPoint(x: 0, y: y)); lines.addLine(to: CGPoint(x: size.width, y: y))
                }
                ctx.stroke(lines, with: .color(ink.opacity(0.085)), lineWidth: 1)
            } else {
                var path = Path()
                for i in 0...cols {
                    for j in 0...rows {
                        let cx = x0 + CGFloat(i) * st, cy = y0 + CGFloat(j) * st
                        let p = CGPoint(x: (cx - o.x) * z, y: (cy - o.y) * z)
                        // 用方点不用圆点：1~1.6px 上两者肉眼无差，但 `addRect` 比 `addEllipse` 便宜得多
                        // ——这层每帧平移都要重画，大屏上一屏上万个点，圆点的代价是白花的。
                        path.addRect(CGRect(x: p.x - dot / 2, y: p.y - dot / 2, width: dot, height: dot))
                    }
                }
                ctx.fill(path, with: .color(ink.opacity(0.18)))
            }

            // 原点十字（画布 0,0）：稍明显一点，是「回中」的落点也是这张纸的锚。
            let og = CGPoint(x: -o.x * z, y: -o.y * z)
            if og.x > -40, og.x < size.width + 40, og.y > -40, og.y < size.height + 40 {
                var cross = Path()
                cross.move(to: CGPoint(x: og.x - 9, y: og.y)); cross.addLine(to: CGPoint(x: og.x + 9, y: og.y))
                cross.move(to: CGPoint(x: og.x, y: og.y - 9)); cross.addLine(to: CGPoint(x: og.x, y: og.y + 9))
                ctx.stroke(cross, with: .color(ink.opacity(0.16)), lineWidth: 1)
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - 页面底图层（v10）

/// 把这张纸**锚定的那一页**垫在纸上当参照（开关 = `ScratchPad.showPage`）。
///
/// 几何是**三端契约**（`PROTOCOL.md §4.4` / `ScratchPad.pageRect`）：页宽恒 800 画布点、
/// 锚点落在画布原点。位置对不上的表现是「同一张纸，Mac 上写在公式旁边、平板上写到页边空白处」。
///
/// 两条纪律：
///  · **页图之上还有笔迹**（本层在 `ScratchInkLayer` 之前挂），页图只是参照物，永远不该盖住墨；
///  · **不跟夜间反色**（草稿纸整体不反色的既有规则）——本层的图一律按 `night: false` 取。
///
/// 图还没渲出来时先铺一块白 + 描边占位（同阅读区「白纸占位、只替换」的零闪烁纪律），
/// 免得开了开关却什么都没有、让人以为开关坏了。描边是必需的：白页压白纸看不出页边在哪。
struct ScratchPageLayer: View, Equatable {
    let image: CGImage?
    /// 页面在**画布坐标**下的矩形（由 `ScratchPad.pageRect(aspect:)` 算，别在这里另算一套）。
    let rect: CGRect
    let viewport: ScratchViewport
    /// 页边描边色：与底纹同一个「由纸色明度推」的墨色（不跟系统深浅外观走）。
    let ink: Color

    static func == (l: Self, r: Self) -> Bool {
        l.image === r.image && l.rect == r.rect && l.viewport == r.viewport && l.ink == r.ink
    }

    var body: some View {
        Canvas { ctx, _ in
            let o = viewport.origin, z = viewport.zoom
            let r = CGRect(x: (rect.minX - o.x) * z, y: (rect.minY - o.y) * z,
                           width: rect.width * z, height: rect.height * z)
            guard r.width > 0.5, r.height > 0.5 else { return }
            ctx.fill(Path(r), with: .color(.white))          // 占位/纸色打底，页图是不透明的
            if let image {
                ctx.draw(Image(decorative: image, scale: 1, orientation: .up), in: r)
            }
            ctx.stroke(Path(r), with: .color(ink.opacity(0.3)), lineWidth: 1)
        }
        .allowsHitTesting(false)
    }
}

// MARK: - 笔迹层（Equatable，同 `InkStaticLayer` 的拆层理由）

struct ScratchInkLayer: View, Equatable {
    let strokes: [InkStroke]
    let viewport: ScratchViewport

    static func == (l: Self, r: Self) -> Bool { l.strokes == r.strokes && l.viewport == r.viewport }

    var body: some View {
        Canvas { ctx, _ in
            let o = viewport.origin, z = viewport.zoom
            for st in strokes {
                // 线宽同样乘 zoom（`inkScale`）→ 与页内笔迹「放大即变粗」的语义一致。
                inkDrawStroke(st, in: &ctx, inkScale: z) {
                    CGPoint(x: (CGFloat($0.x) - o.x) * z, y: (CGFloat($0.y) - o.y) * z)
                }
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - minimap

/// 右下角缩略图：把「全部笔迹包围盒 ∪ 当前视口」等比装进小窗，画笔迹骨架 + 当前视口框。
/// 点或拖窗内任意处 → 视口中心跳到对应画布位置（`onJump` 给画布坐标）。
struct ScratchMinimap: View {
    let strokes: [InkStroke]
    let viewport: ScratchViewport
    let viewSize: CGSize
    /// 页面底图的画布矩形（这张纸开着页面底图才非 nil）：它也算内容，缩略图里画一个淡框。
    var pageRect: CGRect? = nil
    let onJump: (CGPoint) -> Void

    /// minimap 覆盖的画布范围 = 内容 ∪ 视口，再留一点边。两者都空时给一块围绕原点的默认区。
    private var world: CGRect {
        let vis = viewport.visibleRect(viewport: viewSize)
        var r = ScratchBounds.contentBounds(strokes, page: pageRect).map { $0.union(vis) } ?? vis
        if r.width < 1 || r.height < 1 { r = CGRect(x: -400, y: -300, width: 800, height: 600) }
        return r.insetBy(dx: -r.width * 0.08, dy: -r.height * 0.08)
    }

    /// 画布 → 小窗的等比映射（含居中偏移）。`s <= 0` 表示小窗还没量到尺寸。
    private struct Fit {
        let world: CGRect, s: CGFloat, ox: CGFloat, oy: CGFloat
        func map(_ x: Double, _ y: Double) -> CGPoint {
            CGPoint(x: ox + (CGFloat(x) - world.minX) * s, y: oy + (CGFloat(y) - world.minY) * s)
        }
        func unmap(_ p: CGPoint) -> CGPoint {
            CGPoint(x: world.minX + (p.x - ox) / s, y: world.minY + (p.y - oy) / s)
        }
    }

    /// 面板内边距：缩略内容与视口框都不许贴到圆角边框上。
    /// （样张自查发现的：不留边时视口框右下角正好压在描边上，读起来像「被裁掉了」。）
    private static let inset: CGFloat = 9

    private func fit(in box: CGSize) -> Fit {
        let w = world
        let iw = max(1, box.width - Self.inset * 2), ih = max(1, box.height - Self.inset * 2)
        let s = min(iw / max(w.width, 1), ih / max(w.height, 1))
        return Fit(world: w, s: s,
                   ox: Self.inset + (iw - w.width * s) / 2,
                   oy: Self.inset + (ih - w.height * s) / 2)
    }

    var body: some View {
        GeometryReader { geo in
            let f = fit(in: geo.size)
            let vis = viewport.visibleRect(viewport: viewSize)
            let tl = f.map(Double(vis.minX), Double(vis.minY))
            ZStack(alignment: .topLeading) {
                Canvas { ctx, _ in
                    // 页面底图：只画一个淡框（缩略图里塞进整页图既贵又看不清，框足以说明「页在这儿」）
                    if let pr = pageRect {
                        let tl = f.map(Double(pr.minX), Double(pr.minY))
                        let box = CGRect(x: tl.x, y: tl.y, width: pr.width * f.s, height: pr.height * f.s)
                        ctx.fill(Path(box), with: .color(Color.primary.opacity(0.06)))
                        ctx.stroke(Path(box), with: .color(Color.primary.opacity(0.3)), lineWidth: 0.75)
                    }
                    // 骨架线即可（minimap 不必还原笔型/压感，1px 折线最省也最清楚）
                    for st in strokes where st.points.count > 1 {
                        var path = Path()
                        path.move(to: f.map(st.points[0].dx, st.points[0].dy))
                        for p in st.points.dropFirst() { path.addLine(to: f.map(p.dx, p.dy)) }
                        ctx.stroke(path, with: .color(Color.primary.opacity(0.62)),
                                   style: StrokeStyle(lineWidth: 1, lineCap: .round, lineJoin: .round))
                    }
                }
                // 当前视口框：淡填充 + 细描边。纯 1.5pt 实线在 176pt 的小面板里太抢戏
                // （样张里它比笔迹本身还显眼，而笔迹才是内容）。
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(Color.accentColor.opacity(0.06))
                    .overlay(RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .stroke(Color.accentColor.opacity(0.85), lineWidth: 1))
                    .frame(width: max(6, vis.width * f.s), height: max(6, vis.height * f.s))
                    .offset(x: tl.x, y: tl.y)
                    .allowsHitTesting(false)
            }
            // 内容超出面板时给个干净的圆角收边，而不是硬生生截在直角上。
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .local)
                    .onChanged { v in
                        guard f.s > 0 else { return }
                        onJump(f.unmap(v.location))
                    }
            )
        }
        // 与工具条同一套浮层语言（`.regularMaterial` + 0.5 描边 + 轻投影），不再是直角深色块。
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .stroke(.white.opacity(0.15), lineWidth: 0.5))
        .shadow(radius: 6, y: 2)
    }
}


// MARK: - 纸样小样（选择器里的缩略预览）

/// 一小块「这张纸长什么样」：底色 + 底纹。**故意不复用 `ScratchGridLayer`**——那个的网格步长
/// 是按视口缩放自适应的，塞进 52×38 的小格子里会算出一屏一个点，看不出区别。这里用固定步长。
struct PaperSwatch: View {
    let bg: InkColor
    let pattern: ScratchPattern

    var body: some View {
        let paper = Color(red: bg.r / 255, green: bg.g / 255, blue: bg.b / 255, opacity: bg.a)
        let lum = (0.299 * bg.r + 0.587 * bg.g + 0.114 * bg.b) / 255
        let ink: Color = lum > 0.5 ? .black : .white
        RoundedRectangle(cornerRadius: 5, style: .continuous)
            .fill(paper)
            .overlay {
                Canvas { ctx, size in
                    let st: CGFloat = 7
                    switch pattern {
                    case .plain:
                        break
                    case .dots:
                        var p = Path()
                        var y: CGFloat = st / 2
                        while y < size.height { var x: CGFloat = st / 2
                            while x < size.width { p.addRect(CGRect(x: x, y: y, width: 1.2, height: 1.2)); x += st }
                            y += st }
                        ctx.fill(p, with: .color(ink.opacity(0.32)))
                    case .grid:
                        var p = Path()
                        var x: CGFloat = st / 2
                        while x < size.width { p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: size.height)); x += st }
                        var y: CGFloat = st / 2
                        while y < size.height { p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: size.width, y: y)); y += st }
                        ctx.stroke(p, with: .color(ink.opacity(0.26)), lineWidth: 0.7)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous)
                .stroke(Color.primary.opacity(0.22), lineWidth: 0.5))
    }
}
