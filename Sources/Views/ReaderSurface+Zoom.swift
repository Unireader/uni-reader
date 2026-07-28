import SwiftUI
import PDFKit
import QuartzCore
import AppKit

extension ReaderSurface {
    // MARK: 缩放（硬指标 3/4：锚定捏合点，不跳位、不闪烁）

    func clampZoom(_ z: CGFloat) -> CGFloat { min(max(z, zoomMin), zoomMax) }

    /// 锚点计算用的「当前」内容偏移：优先用刚提交、尚未被 `verifyPendingTarget` 确认的
    /// `scratch.pendingTarget`，否则退回 `scratch.geo` 上次汇报值。
    /// ⚠️ **不能一律信 `scratch.geo`**：`onScrollGeometryChange` 汇报是异步的，比 `scrollTo`
    /// 慢半拍到几帧；两次缩放命令紧挨着触发时（连点工具栏按钮 / 命令刚落地又捏合），后一次会读到
    /// 「新 zoom 配旧 offset」的错配快照，算出的锚点内容坐标是错的——目标偏移仍会被 `clampOffset`
    /// 夹进合法范围，不会报错，却会稳稳当当地跳到文档里不相关的一段（未渲染区域先呈现空白纸，
    /// 表现为「PDF 页面消失」；再缩一次因起点又变了，落点继续偏、越点越乱）。
    var anchorOffset: CGPoint {
        scratch.pendingTarget ?? CGPoint(x: scratch.geo.offsetX, y: scratch.geo.offsetY)
    }

    /// 目标偏移夹取（用给定显示页宽下的内容尺寸）。
    func clampOffset(_ o: CGPoint, pageWidth pw: CGFloat) -> CGPoint {
        guard let layout else { return o }
        let g = scratch.geo
        let cw = max(fitAvail, pw)                      // 与 contentW 同源
        let ch = layout.totalHeight * pw / PageLayout.refWidth
        // 水平有效视口 = fitAvail（= 未遮宽 − 占位竖滚动条 = 真实 clip 视口；ScrollGeometry 的 insets/containerW 不可用作视口）
        let minX: CGFloat = 0
        let maxX = max(0, cw - fitAvail)
        let minY = -g.insetTop
        let maxY = max(minY, ch - g.containerH + g.insetBottom)
        return CGPoint(x: min(max(o.x, minX), maxX), y: min(max(o.y, minY), maxY))
    }

    var magnify: some Gesture {
        MagnifyGesture()
            .onChanged { v in pinchChanged(v) }
            .onEnded { _ in pinchEnded() }
    }

    func pinchChanged(_ v: MagnifyGesture.Value) {
        guard layout != nil, scratch.didInitialGeo else { return }
        if scratch.pinch == nil {
            follower.reset()                                   // 用户接管
            cancelZoomAnim()                                   // 捏合接管：停掉进行中的按钮/⌘ 缩放动画
            let o = anchorOffset
            // 手势现挂在 ScrollView 容器 → startLocation 为容器/视口坐标 P（屏幕不动点，与 ⌘wheel/anchorP 同约定）；
            // 内容锚点 c = 偏移 + P。（旧实现挂 content 层取内容坐标，捏合页外空白无手势 → 不缩放。）
            let P = v.startLocation
            let c = CGPoint(x: o.x + P.x, y: o.y + P.y)
            scratch.pinch = PinchInfo(startZoom: zoom, viewportP: P, cCur: c)
            scratch.suppressEmitUntil = CACurrentMediaTime() + 0.3
        }
        guard var p = scratch.pinch else { return }
        let m = max(0.05, v.magnification)
        commitZoom(to: clampZoom(p.startZoom * m), pinch: &p)  // 逐帧真 commit（两方向统一）
        scratch.pinch = p
        scratch.suppressEmitUntil = CACurrentMediaTime() + 0.3
    }

    func pinchEnded() {
        guard scratch.pinch != nil else { return }
        scratch.pinch = nil
        scratch.suppressEmitUntil = CACurrentMediaTime() + 0.3
        scheduleSettleRender()
    }

    /// 原子缩放提交：布局（zoom）与偏移（scrollTo）同 runloop 写入 = 同一次 CA commit。
    func commitZoom(to z1raw: CGFloat, pinch p: inout PinchInfo) {
        let z0 = zoom
        let z1 = clampZoom(z1raw)
        guard abs(z1 - z0) > 0.0001 else { return }
        let r = z1 / z0
        let c1 = CGPoint(x: p.cCur.x * r, y: p.cCur.y * r)
        let target = clampOffset(CGPoint(x: c1.x - p.viewportP.x, y: c1.y - p.viewportP.y),
                                 pageWidth: basis * z1)
        var t = Transaction(); t.animation = nil
        withTransaction(t) {
            zoom = z1
            userZoomed = true
            pos.scrollTo(point: target)
        }
        p.cCur = c1
        scratch.pendingTarget = target
        scratch.pendingTries = 0
        scratch.suppressEmitUntil = CACurrentMediaTime() + 0.3
    }

    /// 以容器坐标 anchorP 为屏幕不动点做单次缩放 commit（⌘wheel 即时缩放；按钮/⌘ 命令走 animateZoom）。
    func zoomCommit(factor: CGFloat, anchorP P: CGPoint) {
        guard layout != nil, scratch.didInitialGeo else { return }
        follower.reset()
        cancelZoomAnim()   // 连续输入接管：停掉进行中的命令式动画，避免两路同时写 zoom
        let o = anchorOffset
        let c = CGPoint(x: o.x + P.x, y: o.y + P.y)
        var p = PinchInfo(startZoom: zoom, viewportP: P, cCur: c)
        commitZoom(to: clampZoom(zoom * factor), pinch: &p)
        scheduleSettleRender()
    }

    /// 未遮视口中心（容器坐标；⌘±/⌘0/1:1/缩放胶囊共用的锚点）。
    var viewportCenter: CGPoint {
        let g = scratch.geo
        return CGPoint(x: g.insetLeading + (g.containerW - g.insetLeading - g.insetTrailing) / 2,
                       y: g.insetTop + (g.containerH - g.insetTop - g.insetBottom) / 2)
    }

    /// ⌘+/⌘− / 工具栏缩放按钮：动画缩放到目标倍率，未遮视口中心为锚。
    func commandZoom(factor: CGFloat) {
        animateZoom(to: zoom * factor, anchorP: viewportCenter)
    }

    /// 1:1 实际大小（参考 Preview）：当前页 1 PDF pt = 1 屏幕 pt。未遮视口中心为锚。
    func commandZoomActual() {
        guard layout != nil, scratch.didInitialGeo, let pdf = session.pdf, pdf.pageCount > 0 else { return }
        let idx = min(max(0, session.currentPageIndex), pdf.pageCount - 1)
        guard let page = pdf.page(at: idx) else { return }
        let w = PageBitmap.displaySize(page).width
        guard w > 0, basis > 0 else { return }
        animateZoom(to: w / basis, anchorP: viewportCenter)
    }

    // MARK: 命令式缩放动画（逐帧插值；每帧 = pinch 同款原子 commit，平滑且零闪烁）

    var zoomAnimDuration: CFTimeInterval { 0.22 }   // 计算属性：扩展里不能放存储属性

    /// 启动一次缩放动画：锚点 P 不动，zoom 从当前值插值到 z1（smoothstep 缓动）。
    /// `fitAfter` 仅 ⌘0 用：动画到位后把 fitBasis 重定标、zoom 归 1（此时 pageW 恰好相等，零跳变）。
    func animateZoom(to z1raw: CGFloat, anchorP P: CGPoint, fitAfter: CGFloat? = nil) {
        guard layout != nil, scratch.didInitialGeo else { return }
        follower.reset()
        let z1 = clampZoom(z1raw)
        guard abs(z1 - zoom) > 0.0001 else {
            if let nb = fitAfter { fitBasis = nb; zoom = 1; userZoomed = false }   // 已在目标：仍刷新基准
            return
        }
        let o = anchorOffset
        scratch.zoomAnim = ZoomAnim(z0: zoom, z1: z1, anchorP: P,
                                    c0: CGPoint(x: o.x + P.x, y: o.y + P.y),
                                    start: CACurrentMediaTime(), fitAfter: fitAfter)
        zoomAnimOn = true
    }

    /// 动画帧：插值 zoom，锚点内容坐标等比缩放后减回 P 得目标偏移，布局+scrollTo 同事务提交。
    func zoomAnimStep() {
        guard let a = scratch.zoomAnim else { zoomAnimOn = false; return }
        let raw = (CACurrentMediaTime() - a.start) / zoomAnimDuration
        if raw >= 1 {
            zoomAnimFrame(z: a.z1, a)
            scratch.zoomAnim = nil
            zoomAnimOn = false
            if let nb = a.fitAfter { fitBasis = nb; zoom = 1; userZoomed = false }
            scheduleSettleRender()
            return
        }
        let t = raw * raw * (3 - 2 * raw)   // smoothstep 缓动（起止速度为 0）
        zoomAnimFrame(z: a.z0 + (a.z1 - a.z0) * t, a)
    }

    func zoomAnimFrame(z: CGFloat, _ a: ZoomAnim) {
        let r = z / a.z0
        let c1 = CGPoint(x: a.c0.x * r, y: a.c0.y * r)
        let target = clampOffset(CGPoint(x: c1.x - a.anchorP.x, y: c1.y - a.anchorP.y),
                                 pageWidth: basis * z)
        var t = Transaction(); t.animation = nil
        withTransaction(t) {
            zoom = z
            userZoomed = true
            pos.scrollTo(point: target)
        }
        scratch.pendingTarget = target
        scratch.pendingTries = 0
        scratch.suppressEmitUntil = CACurrentMediaTime() + 0.3
    }

    /// 取消进行中的缩放动画（pinch / ⌘wheel 等连续输入接管时调用）。
    func cancelZoomAnim() {
        scratch.zoomAnim = nil
        zoomAnimOn = false
    }

    // MARK: ⌘+滚轮缩放（光标为锚；系统缩放同向：自然滚动下两指上滑/滚轮向上 = 放大）
    // SwiftUI 无滚轮 API → NSEvent 本地监视器（纯事件管道，无 AppKit 视图）。
    // 只在「⌘按住 + 光标在本阅读区内 + 非动量惯性 + 无进行中 pinch」时消费事件，其余原样放行。

    func installWheelMonitor() {
        guard scratch.wheelMonitor == nil else { return }
        scratch.wheelMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            guard event.modifierFlags.contains(.command),
                  event.momentumPhase == [],
                  let p = scratch.cursorP,
                  layout != nil, scratch.didInitialGeo, scratch.pinch == nil else { return event }
            var delta = event.scrollingDeltaY
            if !event.hasPreciseScrollingDeltas { delta *= 10 }   // 有级滚轮（行单位）放大到像素量级
            guard delta != 0 else { return nil }
            let factor = min(max(exp(-delta * 0.008), 0.5), 2)    // 手感旋钮：0.008；负号=系统缩放方向约定
            zoomCommit(factor: factor, anchorP: p)
            return nil   // 消费：⌘滚轮不再触发滚动
        }
    }

    func removeWheelMonitor() {
        if let m = scratch.wheelMonitor {
            NSEvent.removeMonitor(m)
            scratch.wheelMonitor = nil
        }
    }

    /// ⌘0：动画回 fit-width；到位后基准重定标到当前实测可用宽（fitAfter，pageW 不变零跳变）。
    func commandZoomFit() {
        guard layout != nil, scratch.didInitialGeo else { return }
        let newBasis = fitAvail
        animateZoom(to: newBasis / basis, anchorP: viewportCenter, fitAfter: newBasis)
    }

}
