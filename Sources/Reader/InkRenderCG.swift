import CoreGraphics
import Foundation

/// 笔迹绘制的 **CoreGraphics 版**（AppKit 阅读区用，`APPKIT-REWRITE-PLAN.md` §3）。
///
/// 🔴 与 `InkLayers.swift` 里 SwiftUI `GraphicsContext` 版**同一套算法、同一组参数**，逐行对照移植：
/// 四种笔型（ballpoint / fountain 压感 + 锥度、marker 恒宽平头 multiply、pencil 三道波动叠加）、
/// 中点二次曲线平滑、补末段、`strokedPath` 攒轮廓一次 fill（半透明笔不在接缝处叠深）、缩放中的快速路径。
/// 这些都和采集页 `capture.html` 的 `drawStroke` 对齐（`InkRender` / `PenBrushType` 是唯一参数源）。
/// SwiftUI 版等 AppKit 重写完成（第 8 步）一起删掉；在那之前两份并存，**改算法必须两边同步**。
///
/// 坐标：调用方给映射 `map`（归一化页点 → 目标上下文里的点），上下文的 y 轴方向由调用方负责
/// （阅读区页层是 flipped 的，与 SwiftUI 一样左上原点）。
enum InkRenderCG {

    /// 一笔。`inkScale` = 线宽倍率（阅读区传 1：页层在文档坐标里按 fit 宽画，缩放由滚动视图整体放大；
    /// 草稿纸传它自己的 zoom）。`fast` = 缩放 / 拖动中的快速描边（见 SwiftUI 版的注释与实测数据）。
    static func drawStroke(_ st: InkStroke, in ctx: CGContext, inkScale: CGFloat,
                           fast: Bool = false, map: (InkPoint) -> CGPoint) {
        guard !st.points.isEmpty else { return }
        var raw = st.points
        var pts = raw.map(map)
        if fast, pts.count > 2 {
            let minStep: CGFloat = 1.5
            var keptRaw = [raw[0]], keptPts = [pts[0]]
            var last = pts[0]
            for i in 1..<(pts.count - 1) {
                let dx = abs(pts[i].x - last.x), dy = abs(pts[i].y - last.y)
                guard dx + dy >= minStep else { continue }
                keptRaw.append(raw[i]); keptPts.append(pts[i]); last = pts[i]
            }
            keptRaw.append(raw[raw.count - 1]); keptPts.append(pts[pts.count - 1])
            raw = keptRaw; pts = keptPts
        }
        let type = st.type, w = st.width
        func color(_ a: Double) -> CGColor {
            CGColor(srgbRed: st.color.r / 255, green: st.color.g / 255, blue: st.color.b / 255, alpha: a)
        }

        ctx.saveGState()
        defer { ctx.restoreGState() }

        if pts.count == 1 {
            let a = type == .pencil ? st.color.a * 0.6 : st.color.a
            let r = CGFloat(type.strokeWidth(pressure: raw[0].dz, base: w)) * inkScale / 2
            ctx.setFillColor(color(a))
            ctx.fillEllipse(in: CGRect(x: pts[0].x - r, y: pts[0].y - r, width: r * 2, height: r * 2))
            return
        }

        switch type {
        case .marker:
            let path = smoothPath(pts)
            ctx.setBlendMode(.multiply)
            ctx.setStrokeColor(color(st.color.a))
            ctx.setLineWidth(CGFloat(w) * inkScale)
            ctx.setLineCap(.square)
            ctx.setLineJoin(.round)
            ctx.addPath(path)
            ctx.strokePath()

        case .pencil:
            if fast {
                var zSum = 0.0
                for p in raw { zSum += p.dz }
                let lw = CGFloat(type.strokeWidth(pressure: zSum / Double(raw.count), base: w)) * inkScale
                ctx.setStrokeColor(color(st.color.a * 0.53))
                ctx.setLineWidth(max(0.7, lw))
                ctx.setLineCap(.round)
                ctx.setLineJoin(.round)
                ctx.addPath(smoothPath(pts))
                ctx.strokePath()
                return
            }
            for pass in PenBrushType.pencilPasses {
                let combined = CGMutablePath()
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
                        let seg = CGMutablePath()
                        seg.move(to: p0); seg.addLine(to: cur)
                        combined.addPath(seg.copy(strokingWithWidth: CGFloat(max(0.7, lw * pass.wScale)) * inkScale,
                                                  lineCap: .round, lineJoin: .round, miterLimit: 10))
                    }
                    prev = cur
                }
                ctx.setFillColor(color(st.color.a * pass.alpha))
                ctx.addPath(combined)
                ctx.fillPath(using: .winding)
            }

        default:   // ballpoint / fountain
            let n = pts.count
            let col = color(st.color.a)
            if fast {
                var zSum = 0.0
                for p in raw { zSum += p.dz }
                let lw = CGFloat(type.strokeWidth(pressure: zSum / Double(raw.count), base: w)) * inkScale
                ctx.setStrokeColor(col)
                ctx.setLineWidth(lw)
                ctx.setLineCap(.round)
                ctx.setLineJoin(.round)
                ctx.addPath(smoothPath(pts))
                ctx.strokePath()
                return
            }
            let combined = CGMutablePath()
            var lastMid = pts[0], lastPt = pts[0]
            for i in 1..<n {
                let mid = CGPoint(x: (lastPt.x + pts[i].x) / 2, y: (lastPt.y + pts[i].y) / 2)
                let lw = CGFloat(type.strokeWidth(pressure: raw[i].dz, base: w)
                                 * type.fountainTaper(index: i, count: n)) * inkScale
                let p = CGMutablePath()
                p.move(to: lastMid); p.addQuadCurve(to: mid, control: lastPt)
                combined.addPath(p.copy(strokingWithWidth: lw, lineCap: .round, lineJoin: .round, miterLimit: 10))
                lastMid = mid; lastPt = pts[i]
            }
            // 补末段（同 SwiftUI 版：中点平滑链止于倒数两点的中点，末点从没连上）
            let tailW = type.strokeWidth(pressure: raw[n - 1].dz, base: w)
            let lw = CGFloat(tailW * type.fountainTaper(index: n - 1, count: n)) * inkScale
            let tail = CGMutablePath()
            tail.move(to: lastMid); tail.addLine(to: lastPt)
            combined.addPath(tail.copy(strokingWithWidth: lw, lineCap: .round, lineJoin: .round, miterLimit: 10))
            ctx.setFillColor(col)
            ctx.addPath(combined)
            ctx.fillPath(using: .winding)
        }
    }

    /// 整页快速绘制（缩放中）：按「颜色 + 量化线宽 + 是否 marker」分组，每组一条路径一次描边。
    /// 与 SwiftUI 版 `inkDrawStrokesFast` 同算法（抽稀阈值 3pt、恒宽取平均压感、pencil 合成一道）。
    static func drawStrokesFast(_ strokes: [InkStroke], in ctx: CGContext, inkScale: CGFloat,
                                map: (InkPoint) -> CGPoint) {
        struct Key: Hashable {
            var r = 0.0, g = 0.0, b = 0.0, a = 0.0
            var lwHalf = 0
            var marker = false
        }
        var groups: [Key: CGMutablePath] = [:]
        var dots: [(CGPoint, CGFloat, Key)] = []
        for st in strokes {
            guard !st.points.isEmpty else { continue }
            let (pts, avgZ) = thinnedScreenPoints(st, minStep: 3, map: map)
            let isMarker = st.type == .marker
            let lw = CGFloat(isMarker ? st.width : st.type.strokeWidth(pressure: avgZ, base: st.width)) * inkScale
            let alpha = st.type == .pencil ? st.color.a * 0.53 : st.color.a
            var key = Key(r: st.color.r, g: st.color.g, b: st.color.b, a: alpha,
                          lwHalf: Int((max(0.5, lw) * 2).rounded()), marker: isMarker)
            if pts.count == 1 {
                dots.append((pts[0], max(0.5, lw) / 2, key))
                continue
            }
            key.lwHalf = max(1, key.lwHalf)
            let path = groups[key] ?? CGMutablePath()
            path.addPath(smoothPath(pts))
            groups[key] = path
        }
        for (k, path) in groups {
            ctx.saveGState()
            ctx.setStrokeColor(CGColor(srgbRed: k.r / 255, green: k.g / 255, blue: k.b / 255, alpha: k.a))
            ctx.setLineWidth(CGFloat(k.lwHalf) / 2)
            ctx.setLineCap(k.marker ? .square : .round)
            ctx.setLineJoin(.round)
            if k.marker { ctx.setBlendMode(.multiply) }
            ctx.addPath(path)
            ctx.strokePath()
            ctx.restoreGState()
        }
        for (p, r, k) in dots {
            ctx.setFillColor(CGColor(srgbRed: k.r / 255, green: k.g / 255, blue: k.b / 255, alpha: k.a))
            ctx.fillEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2))
        }
    }

    /// 中点二次曲线平滑链 + 补末段（marker / 快速态共用）。
    static func smoothPath(_ pts: [CGPoint]) -> CGMutablePath {
        let path = CGMutablePath()
        guard let first = pts.first else { return path }
        path.move(to: first)
        var last = first
        for i in 1..<pts.count {
            let mid = CGPoint(x: (last.x + pts[i].x) / 2, y: (last.y + pts[i].y) / 2)
            path.addQuadCurve(to: mid, control: last)
            last = pts[i]
        }
        path.addLine(to: last)
        return path
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
