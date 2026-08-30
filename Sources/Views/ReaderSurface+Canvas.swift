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
        let oldMargin = canvasMargin   // 打点用：下面 canvasMarginState 一写就取不到旧值了
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
        // 镜像平板：Mac 是页边宽度的唯一真源（PROTOCOL.md `canvas`）。仅当本窗口恰是 padSession
        // 才广播——同 broadcastStrokes 的门控，否则推的是别的窗口的布局。
        session.canvasMarginLive = newEffective
        let isPad = session.id == app.padSession?.id
        // 打点（同 `applyLassoMove` 那条，touch ~/Library/Logs/UniReader-pad.log 开）：平板那侧
        // 是按**它自己那份**页边宽度 clamp 着画的，这条没广播出去就等于「数据对了、平板画出来
        // 还是挤在页边上」。看两处：→ 后面那个数有没有涨、pad 是不是 true。
        PadLog.log("页边档位 \(String(format: "%.2f", oldMargin)) → \(String(format: "%.2f", newEffective))"
                   + "（recenter=\(recenter) pad=\(isPad)）")
        if isPad { app.broadcastCanvas() }
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

    /// **平板**正在写的那一笔也要能撑开页边（本机落墨在 `localInkDragGesture` 里已经做了）：
    /// 不然平板往页边写时，Mac 这边要等抬笔（`strokes` 变化）才跳档，中途那段被裁着看不见。
    /// 只看最后一个点——每帧扫全笔没必要，笔尖越界了就够判。
    func growCanvasForLive() {
        guard session.canvasMode, let p = session.liveStroke?.points.last else { return }
        growCanvasMargin(towardX: p.x)
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
