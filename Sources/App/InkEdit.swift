import Foundation

/// 笔迹编辑纯函数集（无 UI 依赖，spike 可测）。
/// 覆盖：尺子 45° 吸附（③）、局部擦除切段（②）、框选平移（④）、框选缩放（⑤）、自由框选多边形命中（⑥）。
///
/// ⚠️ `splitStroke` 与网页端 `web/src/lib/render.ts` 的切段实现是**同一算法两份实现**
/// （②接入时移植），改一边必须同步另一边，否则平板乐观擦除与 Mac 真源对不上——
/// 仿 `PenPreset.swift` ↔ `web/src/lib/shared.ts` 公式同步的既有惯例。
enum InkEdit {

    /// 尺子吸附：start→current 的角度距最近的 45° 倍数 ≤ thresholdDeg 时贴合到该倍数
    /// （保持 start→current 的长度不变），否则原样返回 current。起点即终点时返回 current。
    /// `aspect` = 页高/页宽（显示比例）：坐标是页内归一化的，x/y 尺度不同，直接在归一化空间量角度的话
    /// 「45°」在屏幕上是 atan(aspect)（A4 上约 54.7°）——先把 y 折算成与 x 同尺度再量角、贴合完再折回去，
    /// 吸附的才是**看上去**的 0/45/90°，长度也是看上去的长度。aspect=1 即退化回纯归一化空间。
    static func rulerSnap(start: SIMD2<Double>, current: SIMD2<Double>,
                          aspect: Double = 1, thresholdDeg: Double = 7) -> SIMD2<Double> {
        let a = aspect > 0 ? aspect : 1
        let d = SIMD2(current.x - start.x, (current.y - start.y) * a)
        let len = (d.x * d.x + d.y * d.y).squareRoot()
        guard len > 0 else { return current }
        let step = Double.pi / 4   // 45°
        let ang = atan2(d.y, d.x)
        let snapped = (ang / step).rounded() * step
        // ang ∈ [-π, π]，snapped 是最近的 45° 倍数，差值天然 ≤ 22.5°，无需折返处理
        guard abs(ang - snapped) <= thresholdDeg * .pi / 180 else { return current }
        return SIMD2(start.x + len * cos(snapped), start.y + len * sin(snapped) / a)
    }

    /// 局部擦除切段：剔除距任一擦除点 ≤ r 的点，连续未命中段各成一条新笔画
    /// （**新 UUID**，保留 page/color/width/type；单点段保留为圆点笔划；全部命中返回空）。
    /// - erasePts: (nx, ny, page)——z 分量是页号（擦除点无压感，z 槽位闲置）；
    ///   只命中与本笔画同页的擦除点，跨页天然不串。草稿纸笔迹的 `page` 恒为 0，调用方同样填 0。
    /// - 坐标系无关：只认「距离 ≤ r」，页内归一化与草稿纸画布坐标都能用，调用方保证 r 与点同单位。
    /// - 一个点都没命中时原样返回 `[s]`（id 不变），调用方替换后持久化对账为零变化。
    /// - 新 id 正好被 persistInk 值快照对账识别为「旧 id 删 + 新 id 增」。
    static func splitStroke(_ s: InkStroke, erasePts: [SIMD3<Double>], r: Double) -> [InkStroke] {
        let r2 = r * r
        func hit(_ p: SIMD3<Double>) -> Bool {
            for e in erasePts where Int(e.z) == s.page {
                let dx = p.x - e.x, dy = p.y - e.y
                if dx * dx + dy * dy <= r2 { return true }
            }
            return false
        }
        var out: [InkStroke] = []
        var seg: [SIMD3<Double>] = []
        var anyHit = false
        func flush() {
            guard !seg.isEmpty else { return }
            // ⚠️ `padId` 必须跟着走：漏了它，草稿纸上被局部擦过的笔迹会变成 padId=nil 的孤儿——
            // 界面上当场消失（按 padId 过滤取不到），却以 kind=2 的身份留在库里污染页内笔迹。
            out.append(InkStroke(page: s.page, color: s.color, width: s.width, type: s.type,
                                 points: seg, layerId: s.layerId, padId: s.padId))
            seg = []
        }
        for p in s.points {
            if hit(p) { anyHit = true; flush() } else { seg.append(p) }
        }
        flush()
        return anyHit ? out : [s]
    }

    /// 平移：点集 +(dx, dy)，x/y 各 clamp 到 0...1（压感不动，id 不变）。
    /// `xRange` 默认 `0...1` = 三端同款的「不出本页」；Mac 的画板模式（v12）传放宽后的页边区间
    /// （`CanvasMargin.xRange`），让页边笔迹能在页外平移。默认值不变 → web/安卓两份实现无需同步。
    static func translated(_ s: InkStroke, dx: Double, dy: Double,
                           xRange: ClosedRange<Double> = 0...1) -> InkStroke {
        var t = s
        t.points = s.points.map { p in
            SIMD3(min(xRange.upperBound, max(xRange.lowerBound, p.x + dx)),
                  min(1, max(0, p.y + dy)), p.z)
        }
        return t
    }

    /// 文字注解平移（④ 框选移动）：anchor 与每个 rect 一起 +(dx, dy)，各角 clamp 到 0...1
    /// （点注解的零尺寸 anchor 同样平移；id/文本/引文不动，bump updatedAt 与编辑同惯例，
    /// 让 persistTextNotes 值快照识别为变更并 upsert）。
    static func translated(_ n: TextNote, dx: Double, dy: Double) -> TextNote {
        var t = n
        t.anchor = translatedRect(n.anchor, dx: dx, dy: dy)
        t.rects = n.rects.map { translatedRect($0, dx: dx, dy: dy) }
        t.updatedAt = .now
        return t
    }

    /// 归一化 rect 平移：min/max 角各 +(dx, dy) 并 clamp 到 0...1（贴页边时宽度收缩，不越界）。
    static func translatedRect(_ r: CGRect, dx: Double, dy: Double) -> CGRect {
        func cl(_ v: Double) -> Double { min(1, max(0, v)) }
        let x1 = cl(Double(r.minX) + dx), x2 = cl(Double(r.maxX) + dx)
        let y1 = cl(Double(r.minY) + dy), y2 = cl(Double(r.maxY) + dy)
        return CGRect(x: min(x1, x2), y: min(y1, y2), width: abs(x2 - x1), height: abs(y2 - y1))
    }

    /// 框选缩放（⑤）：点集绕 anchor 按轴缩放 `(p−a)×s+a`，x/y 各 clamp 到 0...1
    /// （压感不动，id 不变）。归一化坐标 x/y 两轴尺度不同，但按轴缩放是逐轴线性变换，
    /// 与「显示空间算 sx/sy 再回作用到归一化坐标」严格等价，无需 aspect 折算。
    /// 线宽按几何平均 `√(sx·sy)` 同步缩放（笔迹放大不变细、缩小不变粗），
    /// 宽度结果 clamp 到 0.5...40（防缩没/撑爆；s 本身由调用方 clamp 过）。
    /// `xRange` 同 `translated`：默认页内，Mac 画板模式传页边区间。
    static func scaled(_ s: InkStroke, anchor a: SIMD2<Double>, sx: Double, sy: Double,
                       xRange: ClosedRange<Double> = 0...1) -> InkStroke {
        func cl(_ v: Double) -> Double { min(1, max(0, v)) }
        func clx(_ v: Double) -> Double { min(xRange.upperBound, max(xRange.lowerBound, v)) }
        var t = s
        t.points = s.points.map { p in
            SIMD3(clx(a.x + (p.x - a.x) * sx), cl(a.y + (p.y - a.y) * sy), p.z)
        }
        t.width = min(40, max(0.5, s.width * (sx * sy).squareRoot()))
        return t
    }

    /// 文字注解缩放（⑤ 框选缩放）：anchor 与每个 rect 绕 anchor 点按轴缩放，各角 clamp 到 0...1
    /// （字号不缩——注解是文字不是图形；bump updatedAt 让 persistTextNotes 值快照识别为变更）。
    static func scaled(_ n: TextNote, anchor a: SIMD2<Double>, sx: Double, sy: Double) -> TextNote {
        var t = n
        t.anchor = scaledRect(n.anchor, anchor: a, sx: sx, sy: sy)
        t.rects = n.rects.map { scaledRect($0, anchor: a, sx: sx, sy: sy) }
        t.updatedAt = .now
        return t
    }

    /// 归一化 rect 缩放：min/max 角各绕 anchor 按轴缩放并 clamp 到 0...1。
    static func scaledRect(_ r: CGRect, anchor a: SIMD2<Double>, sx: Double, sy: Double) -> CGRect {
        func cl(_ v: Double) -> Double { min(1, max(0, v)) }
        let x1 = cl(a.x + (Double(r.minX) - a.x) * sx), x2 = cl(a.x + (Double(r.maxX) - a.x) * sx)
        let y1 = cl(a.y + (Double(r.minY) - a.y) * sy), y2 = cl(a.y + (Double(r.maxY) - a.y) * sy)
        return CGRect(x: min(x1, x2), y: min(y1, y2), width: abs(x2 - x1), height: abs(y2 - y1))
    }

    /// 点在不规则多边形内（⑥ 自由框选命中）：射线法（向右水平射线计奇偶交点）。
    /// 多边形无需闭合（首末点自动连边）；< 3 个点恒 false；恰在边界上的点判内（框线擦到也算选中，手感宽）。
    static func pointInPolygon(_ p: SIMD2<Double>, polygon poly: [SIMD2<Double>]) -> Bool {
        guard poly.count >= 3 else { return false }
        var inside = false
        var j = poly.count - 1
        for i in 0..<poly.count {
            let a = poly[i], b = poly[j]
            // 边界判定：p 落在线段 a-b 上（共线且在包围盒内，容差 1e-9）
            let cross = (p.x - a.x) * (b.y - a.y) - (p.y - a.y) * (b.x - a.x)
            if abs(cross) < 1e-9,
               p.x >= min(a.x, b.x) - 1e-9, p.x <= max(a.x, b.x) + 1e-9,
               p.y >= min(a.y, b.y) - 1e-9, p.y <= max(a.y, b.y) + 1e-9 { return true }
            // 射线法：边跨越 p.y 水平线时，比较交点 x 与 p.x
            if (a.y > p.y) != (b.y > p.y) {
                let xInt = a.x + (p.y - a.y) / (b.y - a.y) * (b.x - a.x)
                if p.x < xInt { inside.toggle() }
            }
            j = i
        }
        return inside
    }
}
