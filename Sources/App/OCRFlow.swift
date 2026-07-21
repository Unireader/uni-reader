import CoreGraphics
import Foundation

/// OCR 行的「文字流」分析：把一页的行聚成列/块分组（同组 = 空间上连续、可作一段连续选择的块）。
/// 供调试可视化（同组同色）用，也是后续把选择做成「分组感知」的基础。
enum OCRFlow {
    /// 把一页 OCR 行按「竖直相邻 + 水平重叠」聚成列/块分组（并查集）。
    /// 返回与 `runs` 同序的分组 id 数组（同 id = 同一可选块），id 按出现顺序 0,1,2…。
    ///
    /// 规则（best-effort，尽量贴合正常排版）：
    ///  · 两行竖直相邻：上行底到下行顶的间隙 ∈ [-0.6, 1.2] × 行高中位数（允许轻微重叠、容一个正常行距）；
    ///  · 且水平重叠 ≥ 较窄者宽度的 35%（同列/同块）。
    /// 于是：单列连续段落 → 一组；多列 → 各列各一组；思维导图散节点 → 各节点自成组（间隙大不相连）。
    static func columnGroups(_ runs: [TextRun]) -> [Int] {
        let n = runs.count
        guard n > 0 else { return [] }

        var parent = Array(0..<n)
        func find(_ x: Int) -> Int {
            var r = x
            while parent[r] != r { parent[r] = parent[parent[r]]; r = parent[r] }
            return r
        }
        func union(_ a: Int, _ b: Int) {
            let ra = find(a), rb = find(b)
            if ra != rb { parent[ra] = rb }
        }

        let sortedH = runs.map { $0.h }.sorted()
        let lineH = max(0.0001, sortedH[sortedH.count / 2])   // 行高中位数
        let maxGap = 1.2 * lineH
        let minGap = -0.6 * lineH

        for i in 0..<n {
            let a = runs[i]
            for j in (i + 1)..<n {
                let b = runs[j]
                let (up, lo) = a.y <= b.y ? (a, b) : (b, a)
                let gap = lo.y - (up.y + up.h)
                guard gap <= maxGap, gap >= minGap else { continue }
                let ov = max(0, min(a.x + a.w, b.x + b.w) - max(a.x, b.x))
                let frac = ov / max(0.0001, min(a.w, b.w))
                if frac >= 0.35 { union(i, j) }
            }
        }

        var map: [Int: Int] = [:]
        var out = [Int](repeating: 0, count: n)
        var next = 0
        for i in 0..<n {
            let r = find(i)
            if map[r] == nil { map[r] = next; next += 1 }
            out[i] = map[r]!
        }
        return out
    }
}
