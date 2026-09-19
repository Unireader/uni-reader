import AppKit
import QuartzCore

/// 画板模式：页边软边界的生长与补偿（v12，逻辑同 SwiftUI 版 `ReaderSurface+Canvas`）。
/// 文档宽 = 页宽 × (1 + 2 × 页边)，页在文档里右移页边那么多；改页边时同一次提交补一次横向滚动，
/// 页面在屏幕上纹丝不动（落笔中跳档）或摆回视口正中（开关切换）。
extension ReaderView {

    func applyCanvasMargin(_ newState: Double, recenter: Bool = false) {
        guard didSetup else { return }
        let clamped = min(max(newState, CanvasMargin.step), CanvasMargin.limit)
        let oldMarginDoc = marginDoc
        let newEffective = session.canvasMode ? clamped : 0
        let newMarginDoc = fitBasis * CGFloat(newEffective)
        let widthChanged = abs(newMarginDoc - oldMarginDoc) > 0.25
        guard recenter || widthChanged || abs(clamped - canvasMarginState) > 0.0001 else { return }
        let b = clipView.bounds
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        canvasMarginState = clamped
        if recenter || widthChanged {
            layoutDocument()
            let x: CGFloat
            if recenter {
                // 页面中线对齐视口中线（可见区扣掉右侧 AI 面板）
                let ci = scrollView.contentInsets
                let visW = (clipView.frame.width - ci.left - ci.right) / max(0.0001, zoom)
                x = newMarginDoc + fitBasis / 2 - visW / 2 - ci.left / max(0.0001, zoom)
            } else {
                x = b.minX + (newMarginDoc - oldMarginDoc)   // 零位移：页在文档里右移多少，视口跟着右移多少
            }
            scrollClip(to: NSPoint(x: x, y: b.minY))
        }
        CATransaction.commit()
        // 镜像平板：Mac 是页边宽度的唯一真源（PROTOCOL.md `canvas`），只在本窗口恰是 padSession 时广播
        session.canvasMarginLive = newEffective
        if session.id == app.padSession?.id { app.broadcastCanvas() }
    }

    /// 按当前笔迹重算页边（笔画增删、框选移动 / 缩放提交后）。首值来自库里全篇算的，只增不减。
    func refreshCanvasMargin() {
        guard session.canvasMode else { return }
        applyCanvasMargin(CanvasMargin.margin(overflow: session.inkOverflow()))
    }

    /// 落笔中的即时生长：写到离边界不足一档就往外跳，只增不减（笔还没抬就收边界 = 画到一半的线被裁）。
    func growCanvasMargin(towardX nx: Double) {
        guard session.canvasMode else { return }
        let over = nx < 0 ? -nx : (nx > 1 ? nx - 1 : 0)
        let want = CanvasMargin.margin(overflow: over)
        if want > canvasMarginState { applyCanvasMargin(want) }
    }

    /// 平板正在写的那一笔也要能撑开页边（只看最后一个点）。
    func growCanvasForLive() {
        guard session.canvasMode, let p = session.liveStroke?.points.last else { return }
        growCanvasMargin(towardX: p.dx)
    }

    /// 画板开关切换：开 = 按现有笔迹定边界，关 = 收回页宽；两个方向都把页面摆回视口正中（用户 2026-08-28）。
    func canvasModeChanged(_ on: Bool) {
        applyCanvasMargin(on ? CanvasMargin.margin(overflow: session.inkOverflow()) : canvasMarginState,
                          recenter: true)
    }
}
