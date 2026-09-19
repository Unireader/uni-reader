import AppKit
import QuartzCore

/// 缩放（硬指标 3/4：锚定，不跳位、不闪烁）。
///
/// 捏合完全交给 `NSScrollView` 自带的 `magnification`（锚点、惯性由系统做，Preview 同款）：
/// 缩放过程中图层只被整体拉伸（页图 / 笔迹都不重画），停下后 `settleRender` 按新倍率重渲、原位替换。
/// 这里只做系统不做的三件：⌘+滚轮（光标为锚）、命令式缩放动画（⌘± / 工具栏 / ⌘0 / 1:1）、缩放结束的收尾。
extension ReaderView {

    func clampZoom(_ z: CGFloat) -> CGFloat { min(max(z, zoomMin), zoomMax) }

    /// 缩放正在进行（捏合 / 命令动画）。期间凡是「马上要重来一遍」的周边工作都让路：
    /// 实化只扩不缩、不驱逐页图、不入队注定作废宽度的渲染、不排 settle。
    var isZooming: Bool { isLiveMagnifying || zoomAnim != nil }

    // MARK: 锚点换算

    /// 文档坐标点在 clip view 里的视图位置（点）。
    func viewPoint(ofDoc d: NSPoint) -> NSPoint {
        let b = clipView.bounds
        return NSPoint(x: (d.x - b.minX) * zoom, y: (d.y - b.minY) * zoom)
    }

    /// 未遮视口中心：(文档点, 视图点)。⌘± / ⌘0 / 1:1 的锚。
    var viewportCenterAnchor: (doc: NSPoint, view: NSPoint) {
        let ci = scrollView.contentInsets
        let f = clipView.frame.size
        let v = NSPoint(x: ci.left + (f.width - ci.left - ci.right) / 2,
                        y: ci.top + (f.height - ci.top - ci.bottom) / 2)
        let b = clipView.bounds
        return (NSPoint(x: b.minX + v.x / zoom, y: b.minY + v.y / zoom), v)
    }

    /// 单次原子缩放：倍率与滚动位置在同一个 CATransaction 里写（同一次上屏），文档点 `d` 停在视图点 `v`。
    func applyZoom(_ zRaw: CGFloat, anchorDoc d: NSPoint, anchorView v: NSPoint) {
        let z = clampZoom(zRaw)
        guard abs(z - zoom) > 0.00001 else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        scrollView.magnification = z
        scrollClip(to: NSPoint(x: d.x - v.x / z, y: d.y - v.y / z))
        CATransaction.commit()
        suppressEmitUntil = CACurrentMediaTime() + 0.3
    }

    // MARK: ⌘+滚轮

    func commandWheel(factor: CGFloat, docPoint p: NSPoint) -> Bool {
        guard didSetup, session.openPadID == nil, !isLiveMagnifying else { return false }
        follower.reset()
        cancelZoomAnim()
        applyZoom(zoom * factor, anchorDoc: p, anchorView: viewPoint(ofDoc: p))
        userZoomed = true
        scheduleSettle()
        return true
    }

    // MARK: 捏合（系统做，这里只接开始 / 结束）

    func liveMagnifyStarted() {
        guard didSetup else { return }
        isLiveMagnifying = true
        follower.reset()
        cancelZoomAnim()
        settleWork?.cancel(); settleWork = nil
    }

    func liveMagnifyEnded() {
        guard didSetup else { return }
        isLiveMagnifying = false
        userZoomed = true
        suppressEmitUntil = CACurrentMediaTime() + 0.3
        scheduleSettle()
    }

    // MARK: 命令式缩放

    func commandZoom(factor: CGFloat) {
        animateZoom(to: zoom * factor)
    }

    /// 1:1 实际大小（参考 Preview）：当前页 1 PDF pt = 1 屏幕 pt。
    func commandZoomActual() {
        guard didSetup, let pdf = session.pdf, pdf.pageCount > 0 else { return }
        let idx = min(max(0, session.currentPageIndex), pdf.pageCount - 1)
        guard let page = pdf.page(at: idx) else { return }
        let w = PageBitmap.displaySize(page, align: session.pageAlign(idx)).width
        guard w > 0, fitBasis > 0 else { return }
        animateZoom(to: w / fitBasis)
    }

    /// ⌘0：动画回 fit；到位后基准重定为当前实测可用宽、倍率归 1（屏幕页宽不变，零跳变）。
    func commandZoomFit() {
        guard didSetup, fitBasis > 0 else { return }
        let newBasis = fitAvail
        animateZoom(to: newBasis / fitBasis, fitAfter: newBasis)
    }

    /// 启动 / 续接一次缩放动画。已有动画在飞时只从当前倍率起一段新的匀速（连点不跳）。
    func animateZoom(to zRaw: CGFloat, fitAfter: CGFloat? = nil) {
        guard didSetup else { return }
        follower.reset()
        let z1 = clampZoom(zRaw)
        if var a = zoomAnim {
            a.from = zoom
            a.progress = 0
            a.target = z1
            a.fitAfter = fitAfter   // 新命令整个接管（含 nil），见 SwiftUI 版那条 ⌘0 途中按 1:1 的坑
            zoomAnim = a
            return
        }
        guard abs(z1 - zoom) > 0.0001 else {
            if let nb = fitAfter { rebase(fitBasis: nb) }
            return
        }
        let anchor = viewportCenterAnchor
        zoomAnim = ZoomAnimState(from: zoom, target: z1, lastT: CACurrentMediaTime(),
                                 anchorDoc: anchor.doc, anchorView: anchor.view, fitAfter: fitAfter)
        settleWork?.cancel(); settleWork = nil
        startFrameLink()
    }

    /// 动画帧（由 `frameTick` 驱动）：log 空间匀速推进（缩放是乘性量，每帧乘同一系数才是眼睛看到的匀速）。
    func stepZoomAnim() {
        guard var a = zoomAnim else { return }
        let now = CACurrentMediaTime()
        let dt = min(0.05, max(0, now - a.lastT))
        a.lastT = now
        a.progress = min(1, a.progress + CGFloat(dt / 0.18))
        if a.progress >= 1 {
            applyZoom(a.target, anchorDoc: a.anchorDoc, anchorView: a.anchorView)
            zoomAnim = nil
            if let nb = a.fitAfter { rebase(fitBasis: nb) } else { userZoomed = true }
            scheduleSettle()
            return
        }
        applyZoom(a.from * pow(a.target / a.from, a.progress), anchorDoc: a.anchorDoc, anchorView: a.anchorView)
        zoomAnim = a
    }

    func cancelZoomAnim() {
        zoomAnim = nil
    }

    /// 把 fit 基准换成 `nb`、倍率归 1——调用时屏幕页宽恰好等于 `nb`（⌘0 动画到位），所以画面不动。
    func rebase(fitBasis nb: CGFloat) {
        guard let layout = pageLayout else { return }
        let anchor = layout.locate(docY: topDocY)
        let hfrac = fitBasis > 0 ? max(0, clipView.bounds.minX) / fitBasis : 0
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fitBasis = nb
        layoutDocument()
        scrollView.magnification = 1
        scroll(toPage: anchor.page, frac: anchor.frac, hfrac: hfrac)
        CATransaction.commit()
        userZoomed = false
        suppressEmitUntil = CACurrentMediaTime() + 0.3
        scheduleSettle()
    }

    // MARK: 帧驱动（跟随 / 缩放动画）

    func startFrameLink() {
        guard frameLink == nil else { return }
        let l = displayLink(target: self, selector: #selector(frameTick(_:)))
        l.add(to: .main, forMode: .common)
        frameLink = l
    }

    func stopFrameLink() {
        frameLink?.invalidate()
        frameLink = nil
    }

    @objc func frameTick(_ link: CADisplayLink) {
        if follower.isActive { followStep() }
        if zoomAnim != nil { stepZoomAnim() }
        if isMatchPulsing { stepMatchPulse() }
        let pressing = pressRingAnimating
        if pressing { updateTabletOverlay() }
        if !follower.isActive, zoomAnim == nil, !isMatchPulsing, !pressing { stopFrameLink() }
    }
}
