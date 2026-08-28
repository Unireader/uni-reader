import SwiftUI

// MARK: - 画板模式：页边软边界的生长与补偿（v12）

extension ReaderSurface {
    /// 切换页边宽度。**布局（`contentW`）与偏移（`scrollTo`）同 runloop 写入 = 同一次 CA commit**
    /// （同 `commitZoom` 的原子提交纪律）。横向落点两种口径：
    ///  · `recenter: false`（默认，**落笔中跳档走这条**）＝零位移：内容变宽时页面在内容里右移 Δ/2，
    ///    视口跟着右移同样多，页面在屏幕上纹丝不动。写字时页面绝不能跳，故只能是这条。
    ///  · `recenter: true`（**开关切换走这条**）＝把 PDF 页面横向摆回视口正中。人可能正停在页边深处
    ///    或放大着看页面左半边，这时按零位移切开关会把页面留在屏幕外/贴边上。
    func applyCanvasMargin(_ newState: Double, recenter: Bool = false) {
        let clamped = min(max(newState, CanvasMargin.step), CanvasMargin.limit)
        let oldW = contentWidth(margin: canvasMargin)
        let newEffective = session.canvasMode ? clamped : 0
        let newW = contentWidth(margin: newEffective)
        let widthChanged = abs(newW - oldW) > 0.5
        guard recenter || widthChanged || abs(clamped - canvasMarginState) > 0.0001 else { return }
        var t = Transaction(); t.animation = nil
        withTransaction(t) {
            canvasMarginState = clamped
            guard recenter || widthChanged else { return }
            // 页面居中：新内容宽下的 pageX 再减去「视口比页面宽出来的那一半」（页比视口宽时该项为正，
            // 即居中到页面自己的中线）。零位移：旧偏移 + 内容宽增量的一半。
            let x = recenter ? (newW - pageW) / 2 + (pageW - fitAvail) / 2
                             : scratch.geo.offsetX + (newW - oldW) / 2
            let target = clampOffset(CGPoint(x: x, y: scratch.geo.offsetY),
                                     pageWidth: pageW, margin: newEffective)
            pos.scrollTo(point: target)
            scratch.pendingTarget = target
            scratch.pendingTries = 0
        }
    }

    /// 按当前笔迹重算页边宽度（笔画增删、框选移动/缩放提交、开画板、载入文档后各跑一次）。
    /// 擦掉远处的笔迹边界也会收回来——收缩同样走原子补偿，页面不动。
    func refreshCanvasMargin() {
        guard session.canvasMode else { return }
        applyCanvasMargin(CanvasMargin.margin(overflow: CanvasMargin.overflow(session.strokes)))
    }

    /// 落笔中的即时生长：这一笔写到离边界不足 `slack` 就往外跳一档，**只增不减**
    /// （笔还没抬就收边界 = 画到一半的线被裁）。`nx` 是页内归一化 x（画板模式下可越界）。
    func growCanvasMargin(towardX nx: Double) {
        guard session.canvasMode else { return }
        let over = nx < 0 ? -nx : (nx > 1 ? nx - 1 : 0)
        let want = CanvasMargin.margin(overflow: over)
        if want > canvasMarginState { applyCanvasMargin(want) }
    }

    /// 画板开关切换（`session.canvasMode` 的 onChange）：开 = 按现有笔迹定边界，关 = 收回页宽。
    /// 两个方向都**把 PDF 页面摆回视口正中**（用户 2026-08-28 要求）——切开关是个「换个看法」的动作，
    /// 落点该是页面本身，而不是切之前碰巧停在的那处页边空白。
    func canvasModeChanged(_ on: Bool) {
        applyCanvasMargin(on ? CanvasMargin.margin(overflow: CanvasMargin.overflow(session.strokes))
                             : canvasMarginState,
                          recenter: true)
    }
}
