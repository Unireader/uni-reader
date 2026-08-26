import CoreGraphics
import Foundation

/// 框选截图的**纯几何**部分：把阅读区里框出来的一块，折成「逐页 + 页内归一化矩形」的切片列表。
///
/// 刻意不碰 PDFKit —— 渲染在 `PageSnipRender.swift`，这样这一半能被
/// `spike/page-snip-test.swift` 单独编译测（同 `InkEdit` 拆纯函数的做法）。
enum PageSnip {
    /// 一次框选的归一化结果。
    ///
    /// **跨页允许**：截图是像素，不受笔迹那条「仅页内」的语义约束（对比 `ReaderSurface+Lasso`
    /// 把跨页点 clamp 回锚点页）。框住一段跨页的推导正是常见用法。
    ///
    /// x 方向所有页共用一组 `[x0, x1]`：阅读区是 fit-width 连续布局，各页显示宽度相同，
    /// 所以页内归一化 x 天然可跨页比较。
    struct Region: Equatable {
        var startPage: Int
        var endPage: Int
        var x0: Double
        var x1: Double
        var y0: Double      // 在 startPage 内的归一化 y（上边）
        var y1: Double      // 在 endPage 内的归一化 y（下边）
    }

    /// 一页上的一条切片：页号 + 页内归一化矩形（0~1，左上原点）。
    struct Slice: Equatable {
        var page: Int
        var rect: CGRect
    }

    /// 目标长边像素上限。各平台都会再压一道，发得更大只是白白慢（`AI-PLAN.md §4`）。
    static let maxLongEdge: Double = 2000
    /// 重渲倍率区间：小块区域别被拉到离谱倍数，大块也别糊。
    static let minScale: Double = 1.5
    static let maxScale: Double = 4
    /// 跨页切片之间的分隔（像素）。不留的话跨页处会被看成一段连续正文。
    static let gap = 8

    /// 两个框选端点 → 规范化 `Region`（往上拖 / 往左拖同样成立）。
    ///
    /// 端点由 `ReaderSurface.containerPointToPageNorm` 给出，它已经把 nx/ny clamp 到 0~1，
    /// 所以落在页间空隙或页两侧留白的点会贴到最近的页边——正是想要的「框到页边为止」。
    static func region(from a: (page: Int, nx: Double, ny: Double),
                       to b: (page: Int, nx: Double, ny: Double)) -> Region {
        let aFirst = (a.page, a.ny) <= (b.page, b.ny)
        let first = aFirst ? a : b
        let second = aFirst ? b : a
        return Region(startPage: first.page, endPage: second.page,
                      x0: min(a.nx, b.nx), x1: max(a.nx, b.nx),
                      y0: first.ny, y1: second.ny)
    }

    /// 拆成逐页切片：首页取 `y0 →（同页 ? y1 : 1）`，中间页整页，末页 `0 → y1`。
    ///
    /// 高度接近 0 的切片直接丢掉——正好停在页边界时会产生这种切片，渲出来 0 像素高，
    /// 却会白占一条分隔线。
    static func slices(_ r: Region) -> [Slice] {
        guard r.endPage >= r.startPage, r.startPage >= 0 else { return [] }
        let x0 = min(max(r.x0, 0), 1), x1 = min(max(r.x1, 0), 1)
        let w = x1 - x0
        guard w > 1e-6 else { return [] }
        var out: [Slice] = []
        for p in r.startPage...r.endPage {
            let top = (p == r.startPage) ? min(max(r.y0, 0), 1) : 0
            let bottom = (p == r.endPage) ? min(max(r.y1, 0), 1) : 1
            let h = bottom - top
            guard h > 1e-6 else { continue }
            out.append(Slice(page: p, rect: CGRect(x: x0, y: top, width: w, height: h)))
        }
        return out
    }

    /// 一次框选够不够大（太小多半是误拖，不该当成截图）。容器点单位。
    static func isMeaningful(_ size: CGSize) -> Bool {
        abs(size.width) >= 12 && abs(size.height) >= 12
    }

    /// 按「长边不超过 `maxLongEdge`」定重渲倍率，并夹在 `[minScale, maxScale]`。
    /// 这条是画质的关键：**屏幕上那份位图在缩小状态下本来就低分辨率**，必须按页重渲，
    /// 倍率也得按目标像素来定，不能沿用当前缩放。
    static func scale(ptWidth: Double, ptHeight: Double) -> Double {
        let longEdge = max(ptWidth, ptHeight)
        guard longEdge > 0 else { return minScale }
        return min(max(maxLongEdge / longEdge, minScale), maxScale)
    }
}
