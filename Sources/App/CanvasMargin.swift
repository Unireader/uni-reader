import Foundation

/// 画板模式（v12）的**页边软边界**（纯数学、无副作用，`spike/canvas-margin-test.swift` 覆盖）。
///
/// ## 为什么不引入新坐标系
///
/// 页边笔迹仍是**页内笔迹**（`note` kind=2、归属那一页、`InkStroke.page` 照旧），只是归一化 `x`
/// 越出 `0...1` —— 单位还是「页宽的倍数」，`x = -0.5` 就是页左边缘再往左半个页宽。于是
/// 落库 schema、`PROTOCOL.md` 的线格式（f32 归一化点）、Inspector 的分页统计、擦除/框选/图层
/// 全都不用动，旧数据也天然还在 `0...1` 里。
///
/// ## 「无限」是怎么来的
///
/// 阅读区是页流 + `ScrollView`（不是草稿纸那种自绘视口），内容宽必须是个有限值。所以照搬草稿纸
/// `ScratchBounds` 的**软边界**思路，只做横向：每侧宽度按 `step` 取档，笔迹写到离当前边界不足
/// `slack` 就往外跳一档 —— 写不到头，而内容宽始终有限。档位化（而非连续跟随笔尖）是为了
/// 少动布局：每跳一档才改一次内容宽，配一次 `scrollTo` 补偿（同 runloop = 同一次 CA commit），
/// 页面在屏幕上纹丝不动。连续生长则会让页面在笔下逐帧平移。
///
/// 边界是**整篇文档统一**的（不是逐页）：内容宽只有一个，逐页各算会让横向滚动区随翻页跳变。
enum CanvasMargin {
    /// 生长档位（页宽的倍数）。也是画板模式的起步宽度：每侧半个页宽。
    static let step: Double = 0.5
    /// 触发生长的余量（页宽的倍数）：笔迹离边界不足这么多就跳一档。
    static let slack: Double = 0.35
    /// 每侧上限（页宽的倍数）。纯粹防坏数据（某条笔迹的 x 是天文数字）把滚动区推到天边。
    static let limit: Double = 8

    /// 一批笔迹的最大**横向越界量**（0 = 全在页内）：`max(-minX, maxX - 1)`。
    /// 页内笔迹与页边笔迹在同一个数组里，不必分开——没越界的笔迹对 max 没有贡献。
    static func overflow(_ strokes: [InkStroke]) -> Double {
        var o: Double = 0
        for st in strokes {
            for p in st.points {
                if p.x < 0 { o = Swift.max(o, -p.x) }
                else if p.x > 1 { o = Swift.max(o, p.x - 1) }
            }
        }
        return o
    }

    /// 单笔的越界量（落笔中每帧算这一笔，点数少）。
    static func overflow(_ stroke: InkStroke?) -> Double {
        guard let stroke else { return 0 }
        return overflow([stroke])
    }

    /// 越界量 → 每侧页边宽度（页宽的倍数），档位化并夹在 `step...limit`。
    /// 全在页内（`o == 0`）也给一档 `step`：画板一开就得有地方下笔。
    static func margin(overflow o: Double) -> Double {
        let need = Swift.max(0, o) + slack
        let stepped = (need / step).rounded(.up) * step
        return Swift.min(limit, Swift.max(step, stepped))
    }

    /// 笔迹落点的合法 x 区间（页边可写范围）。画板关 = `0...1`（页内，与画板模式前逐字节同行为）。
    static func xRange(margin m: Double) -> ClosedRange<Double> {
        m > 0 ? (-m)...(1 + m) : 0...1
    }
}
