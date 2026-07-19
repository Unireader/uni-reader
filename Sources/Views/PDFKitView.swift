import SwiftUI
import PDFKit
import AppKit
import QuartzCore

/// 原生 PDFKit 阅读视图（复刻 Preview.app）：连续滚动 + 页阴影 + 自动铺适宽度，
/// 缩放/选择/翻页全用系统内置行为，**不自绘任何动态布局**。
///
/// 额外结线（不改变原生外观）：
/// - 叠加 `InkOverlayView` 渲染平板实时手写（事件穿透，不影响 PDF 交互）。
/// - 与 `DocSession.scrollAnchor` 双向同步：Mac 滚动 → 发锚点；收到 sim/pad 锚点 → 滚到同位置。
/// - Mac 翻页 → 回写 `session.currentPageIndex`（驱动推图给平板）。
struct PDFKitView: NSViewRepresentable {
    let session: DocSession
    let scrollAnchor: ScrollAnchor?   // 存储属性：锚点变化才让 SwiftUI 认为视图值变了，从而调用 updateNSView
    let hover: HoverPoint?            // 平板笔悬停位置
    let inkTick: Int                  // 笔迹变化触发重绘

    func makeCoordinator() -> Coordinator { Coordinator(session: session) }

    func makeNSView(context: Context) -> PDFContainerView {
        let container = PDFContainerView()
        configure(container.pdfView)
        context.coordinator.attach(pdfView: container.pdfView)
        return container
    }

    func updateNSView(_ container: PDFContainerView, context: Context) {
        let coord = context.coordinator
        coord.session = session
        let pdfView = container.pdfView

        if pdfView.document !== session.pdf {
            pdfView.document = session.pdf
            coord.lastAppliedAnchorSeq = 0
            coord.resetSmoother()
        }

        container.overlay.strokes = session.strokes
        container.overlay.liveStroke = session.liveStroke
        container.overlay.hover = hover
        container.overlay.needsDisplay = true

        if let a = scrollAnchor, a.origin != "mac", a.seq > coord.lastAppliedAnchorSeq {
            coord.lastAppliedAnchorSeq = a.seq
            coord.applyIncomingAnchor(a)
        }
    }

    /// Preview.app 风格：连续单页、幅优先自适应、页阴影、透明背景（露出窗口材质）。
    private func configure(_ pdfView: PDFView) {
        pdfView.displayMode = .singlePageContinuous
        pdfView.displayDirection = .vertical
        pdfView.displaysPageBreaks = true
        pdfView.pageShadowsEnabled = true
        pdfView.autoScales = true
        pdfView.backgroundColor = .clear
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject {
        var session: DocSession
        weak var pdfView: PDFView?
        var lastAppliedAnchorSeq = 0
        private var suppressEmit = false
        // 延迟补偿：按屏幕刷新率平滑跟随平板滚动锚点，过滤 WiFi 抖动。
        private var displayLink: CADisplayLink?
        private var smCurrent = 0.0, smTarget = 0.0, smVel = 0.0   // 全局进度 = page + frac
        private var lastAnchorAt: CFTimeInterval = 0
        private var lastStepAt: CFTimeInterval = 0

        init(session: DocSession) { self.session = session }

        func attach(pdfView: PDFView) {
            self.pdfView = pdfView
            let nc = NotificationCenter.default
            nc.addObserver(self, selector: #selector(pageChanged),
                           name: .PDFViewPageChanged, object: pdfView)
            if let scroll = Self.firstScrollView(in: pdfView) {
                scroll.contentView.postsBoundsChangedNotifications = true
                nc.addObserver(self, selector: #selector(scrolled),
                               name: NSView.boundsDidChangeNotification, object: scroll.contentView)
            }
        }

        /// Mac 翻页 → 回写当前页码（驱动 AppModel 推图给平板）。
        @objc private func pageChanged() {
            guard let pdfView, let doc = pdfView.document, let page = pdfView.currentPage else { return }
            let idx = doc.index(for: page)
            if session.currentPageIndex != idx { session.currentPageIndex = idx }
        }

        /// Mac 滚动 → 把视口顶部位置作为锚点发出（供 sim/平板跟随）。
        @objc private func scrolled() {
            guard !suppressEmit, let (page, frac) = currentAnchor() else { return }
            session.emitAnchor(page: page, frac: frac, origin: "mac")
        }

        /// 视口顶部 → (页, 页内归一化比例，0 顶 1 底)。
        private func currentAnchor() -> (page: Int, frac: Double)? {
            guard let pdfView, let doc = pdfView.document else { return nil }
            let top = CGPoint(x: pdfView.bounds.midX, y: pdfView.bounds.maxY - 4)
            guard let page = pdfView.page(for: top, nearest: true) else { return nil }
            let pp = pdfView.convert(top, to: page)
            let b = page.bounds(for: .mediaBox)
            let frac = Double((b.maxY - pp.y) / max(1, b.height))
            return (doc.index(for: page), min(max(0, frac), 1))
        }

        /// 应用来自 sim/平板的锚点：设为平滑目标 + 估速，由 displayLink 每帧逼近（延迟补偿）。
        func applyIncomingAnchor(_ a: ScrollAnchor) {
            guard let pdfView, let doc = pdfView.document, doc.pageCount > 0 else { return }
            let now = CACurrentMediaTime()
            let newTarget = Double(a.page) + a.frac
            let dt = now - lastAnchorAt
            if lastAnchorAt > 0, dt > 0, dt < 0.2 {
                let instVel = (newTarget - smTarget) / dt        // 进度/秒
                smVel = smVel * 0.4 + instVel * 0.6              // 平滑估速
            }
            smTarget = newTarget
            lastAnchorAt = now
            suppressEmit = true
            if displayLink == nil {
                smCurrent = newTarget                            // 首帧对齐，避免大跳
                startDisplayLink()
            }
        }

        /// 文档切换/断开时复位平滑器。
        func resetSmoother() {
            stopDisplayLink()
            smCurrent = 0; smTarget = 0; smVel = 0; lastAnchorAt = 0
        }

        private func startDisplayLink() {
            guard displayLink == nil, let pdfView else { return }
            lastStepAt = CACurrentMediaTime()
            let dl = pdfView.displayLink(target: self, selector: #selector(stepFrame))
            dl.add(to: .main, forMode: .common)
            displayLink = dl
        }

        private func stopDisplayLink() {
            displayLink?.invalidate(); displayLink = nil
        }

        /// 每屏幕帧：外推 + 向目标收敛。即便这帧没有新锚点也平滑移动，补偿 WiFi 抖动/停顿。
        @objc private func stepFrame() {
            guard let pdfView, let doc = pdfView.document, doc.pageCount > 0 else { stopDisplayLink(); return }
            let now = CACurrentMediaTime()
            var frameDt = now - lastStepAt; lastStepAt = now
            if frameDt <= 0 || frameDt > 0.1 { frameDt = 1.0 / 120.0 }

            let stale = now - lastAnchorAt
            if stale > 0.12 { smVel *= 0.85 }                    // 久无锚点 → 衰减外推，避免跑飞
            let predicted = smCurrent + smVel * frameDt
            let catchup = min(1.0, 18.0 * frameDt)               // 向目标收敛（时间常数 ~55ms）
            smCurrent = predicted + (smTarget - predicted) * catchup

            let maxPos = Double(doc.pageCount - 1) + 0.9999
            if smCurrent < 0 { smCurrent = 0; smVel = 0 }
            if smCurrent > maxPos { smCurrent = maxPos; smVel = 0 }

            applyPos(smCurrent, doc: doc, pdfView: pdfView)

            // 收敛且停顿 → 精确对齐并停 displayLink，随后解除抑制。
            if abs(smTarget - smCurrent) < 0.0005, abs(smVel) < 0.01, stale > 0.2 {
                applyPos(smTarget, doc: doc, pdfView: pdfView)
                stopDisplayLink()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in self?.suppressEmit = false }
            }
        }

        private func applyPos(_ pos: Double, doc: PDFDocument, pdfView: PDFView) {
            let idx = max(0, min(doc.pageCount - 1, Int(pos)))
            guard let page = doc.page(at: idx) else { return }
            let frac = pos - Double(idx)
            let b = page.bounds(for: .mediaBox)
            let y = b.maxY - CGFloat(frac) * b.height
            pdfView.go(to: PDFDestination(page: page, at: CGPoint(x: b.minX, y: y)))
        }

        private static func firstScrollView(in view: NSView) -> NSScrollView? {
            for sub in view.subviews {
                if let sv = sub as? NSScrollView { return sv }
                if let found = firstScrollView(in: sub) { return found }
            }
            return nil
        }

        deinit { NotificationCenter.default.removeObserver(self); displayLink?.invalidate() }
    }
}

/// 容器：`PDFView` 铺满 + `InkOverlayView` 叠加在上层（等大、事件穿透）。
/// 用 autoresizingMask 让子视图跟随，避免任何手写布局代码。
final class PDFContainerView: NSView {
    let pdfView = PDFView()
    let overlay = InkOverlayView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        pdfView.frame = bounds
        pdfView.autoresizingMask = [.width, .height]
        addSubview(pdfView)

        overlay.frame = bounds
        overlay.autoresizingMask = [.width, .height]
        overlay.pdfView = pdfView
        addSubview(overlay)
        overlay.bindObservers()
    }

    required init?(coder: NSCoder) { nil }
}
