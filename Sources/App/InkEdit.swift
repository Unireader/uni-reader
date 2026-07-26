import Foundation

/// 笔迹编辑纯函数集（无 UI 依赖，spike 可测）。
/// 覆盖：尺子 45° 吸附（③）、局部擦除切段（②）、框选平移（④）。
///
/// ⚠️ `splitStroke` 与网页端 `web/src/lib/render.ts` 的切段实现是**同一算法两份实现**
/// （②接入时移植），改一边必须同步另一边，否则平板乐观擦除与 Mac 真源对不上——
/// 仿 `PenPreset.swift` ↔ `web/src/lib/shared.ts` 公式同步的既有惯例。
enum InkEdit {

    /// 尺子吸附：start→current 的角度距最近的 45° 倍数 ≤ thresholdDeg 时贴合到该倍数
    /// （保持 start→current 的长度不变），否则原样返回 current。起点即终点时返回 current。
    static func rulerSnap(start: SIMD2<Double>, current: SIMD2<Double>, thresholdDeg: Double = 7) -> SIMD2<Double> {
        let d = current - start
        let len = (d.x * d.x + d.y * d.y).squareRoot()
        guard len > 0 else { return current }
        let step = Double.pi / 4   // 45°
        let ang = atan2(d.y, d.x)
        let snapped = (ang / step).rounded() * step
        // ang ∈ [-π, π]，snapped 是最近的 45° 倍数，差值天然 ≤ 22.5°，无需折返处理
        guard abs(ang - snapped) <= thresholdDeg * .pi / 180 else { return current }
        return SIMD2(start.x + len * cos(snapped), start.y + len * sin(snapped))
    }

    /// 局部擦除切段：剔除距任一擦除点 ≤ r 的点，连续未命中段各成一条新笔画
    /// （**新 UUID**，保留 page/color/width/type；单点段保留为圆点笔划；全部命中返回空）。
    /// - erasePts: (nx, ny, page)——z 分量是页号（擦除点无压感，z 槽位闲置）；
    ///   只命中与本笔画同页的擦除点，跨页天然不串。
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
            out.append(InkStroke(page: s.page, color: s.color, width: s.width, type: s.type, points: seg))
            seg = []
        }
        for p in s.points {
            if hit(p) { anyHit = true; flush() } else { seg.append(p) }
        }
        flush()
        return anyHit ? out : [s]
    }

    /// 平移：点集 +(dx, dy)，x/y 各 clamp 到 0...1（压感不动，id 不变）。
    static func translated(_ s: InkStroke, dx: Double, dy: Double) -> InkStroke {
        var t = s
        t.points = s.points.map { p in
            SIMD3(min(1, max(0, p.x + dx)), min(1, max(0, p.y + dy)), p.z)
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
}
