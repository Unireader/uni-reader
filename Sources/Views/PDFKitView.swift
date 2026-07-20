import SwiftUI
import PDFKit
import AppKit
import QuartzCore
import CoreImage

/// 原生 PDFKit 阅读视图（复刻 Preview.app）：连续滚动 + 页阴影 + 自动铺适宽度，
/// 缩放/选择/翻页全用系统内置行为，**不自绘任何动态布局**。
///
/// 额外结线（不改变原生外观）：
/// - 叠加 `InkOverlayView` 渲染平板实时手写（事件穿透，不影响 PDF 交互）。
/// - 与 `DocSession.scrollAnchor` 双向同步：Mac 滚动 → 发锚点；收到 sim/pad 锚点 → 滚到同位置。
/// - Mac 翻页 → 回写 `session.currentPageIndex`（驱动推图给平板）。
struct PDFKitView: NSViewRepresentable {
    let session: DocSession
    let docKey: String                // 每次载入新 PDF 都变（值变才会触发 updateNSView，否则切文档不刷新）
    let scrollAnchor: ScrollAnchor?   // 存储属性：锚点变化才让 SwiftUI 认为视图值变了，从而调用 updateNSView
    let hover: HoverPoint?            // 平板笔悬停位置
    let nightMode: Bool               // 夜间模式：PDF 反转滤镜
    let interpEnabled: Bool           // 平板滚动跟随：true=时间戳插值 / false=纯低通（A/B）
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
        coord.interpEnabled = interpEnabled
        let pdfView = container.pdfView

        if pdfView.document !== session.pdf {
            pdfView.document = session.pdf
            coord.lastAppliedAnchorSeq = 0
            coord.resetSmoother()
            // 切文档后立刻同步布局：否则 PDFView 有时要手动滑一下才刷新，且切换时会闪一下空白。
            if session.pdf != nil {
                pdfView.layoutDocumentView()
                pdfView.needsDisplay = true
            }
        }

        container.overlay.strokes = session.strokes
        container.overlay.liveStroke = session.liveStroke
        container.overlay.hover = hover
        container.overlay.needsDisplay = true
        applyNight(pdfView)

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

    /// 夜间模式：给 PDFView 图层挂 Core Image 反转滤镜（反亮度 + 复原色相）；上层墨迹覆盖层不受影响。
    private func applyNight(_ v: PDFView) {
        v.wantsLayer = true
        v.layerUsesCoreImageFilters = true
        guard nightMode else { v.layer?.filters = nil; return }
        var filters: [CIFilter] = []
        if let inv = CIFilter(name: "CIColorInvert") { filters.append(inv) }
        if let hue = CIFilter(name: "CIHueAdjust") { hue.setValue(Double.pi, forKey: "inputAngle"); filters.append(hue) }
        v.layer?.filters = filters
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject {
        var session: DocSession
        weak var pdfView: PDFView?
        var lastAppliedAnchorSeq = 0
        private var suppressEmit = false
        // 平滑跟随。两种模式共用一个 displayLink，每帧算出目标位再轻低通逼近，**绝不外推**：
        //  · 本地(sim / mac 回声，无发送端时间戳)：纯临界阻尼低通逼近最新锚点。
        //  · 平板(pad，带发送端时间戳)：时间戳插值缓冲——按“发送端戳”把样本落到本地时间轴，
        //    渲染时落后 interpDelay 做线性插值。运动时序取自发送端戳而非到达时刻，故对 WiFi
        //    成批/抖动免疫；越过末样本则保持(不外推) → 永不过冲。
        //  （旧“速度外推”版实测过冲 3 页撞顶、方向反转 13 次，见 spike/scroll-follow-sim.swift）
        private var displayLink: CADisplayLink?
        private var smCurrent = 0.0, smTarget = 0.0   // 全局进度 = page + frac；smCurrent = 实际应用位
        private var lastAnchorAt: CFTimeInterval = 0
        private var lastStepAt: CFTimeInterval = 0
        // 时间戳插值状态（仅平板路径）
        private struct TSample { var t: Double; var pos: Double }   // t: 本地时钟(s)；pos: page+frac
        private var buf: [TSample] = []
        private var clockOffset = 0.0        // 本地接收(s) − 发送端戳(s)，取最小延迟估真实时钟差
        private var haveOffset = false
        private var useInterp = false
        var interpEnabled = true             // 顶栏 A/B 开关：关则平板路径也走纯低通
        private let interpDelay = 0.08       // 渲染落后 80ms 吸收抖动/成批（越大越稳、越滞后）

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

        /// 应用来自 sim/平板的锚点。**只跟随、不预测**。
        /// 有发送端时间戳 → 入插值缓冲；无 → 更新低通目标。由 displayLink 每帧逼近。
        func applyIncomingAnchor(_ a: ScrollAnchor) {
            guard let pdfView, let doc = pdfView.document, doc.pageCount > 0 else { return }
            let newTarget = Double(a.page) + a.frac
            let now = CACurrentMediaTime()
            lastAnchorAt = now
            suppressEmit = true

            if a.senderT > 0 && interpEnabled {                  // 平板 + 开关开：时间戳插值
                useInterp = true
                let ts = a.senderT / 1000.0                      // 发送端戳(s)
                let raw = now - ts                               // = 真实时钟差 + 网络延迟
                if !haveOffset { clockOffset = raw; haveOffset = true }
                else if raw < clockOffset { clockOffset = raw }  // 最小延迟包最接近真实差 → 快速贴近
                else { clockOffset += (raw - clockOffset) * 0.02 } // 缓慢上漂，吸收时钟漂移
                appendSample(TSample(t: ts + clockOffset, pos: newTarget))
            } else {                                             // 本地：纯低通
                useInterp = false
                smTarget = newTarget
            }
            if displayLink == nil {
                smCurrent = newTarget                            // 首帧对齐，避免大跳
                startDisplayLink()
            }
        }

        /// 插入一个已换算到本地时间轴的样本（一般有序；个别乱序则排序），并修剪过老样本。
        private func appendSample(_ s: TSample) {
            if let last = buf.last, s.t < last.t - 1.0 { return }   // 太老的迟到包丢弃
            buf.append(s)
            if buf.count >= 2 && buf[buf.count - 1].t < buf[buf.count - 2].t {
                buf.sort { $0.t < $1.t }
            }
            let cutoff = s.t - 1.5
            while buf.count > 2 && buf.first!.t < cutoff { buf.removeFirst() }
        }

        /// 在本地时间轴 t 处对缓冲线性插值；早于首样本→首样本；**晚于末样本→保持末样本(不外推)**。
        private func sampleAt(_ t: Double) -> Double {
            guard let first = buf.first, let last = buf.last else { return smCurrent }
            if t <= first.t { return first.pos }
            if t >= last.t { return last.pos }                   // 关键：不外推 → 不过冲
            for i in 1..<buf.count where buf[i].t >= t {
                let a = buf[i - 1], b = buf[i]
                let span = b.t - a.t
                let u = span > 1e-6 ? (t - a.t) / span : 0
                return a.pos + (b.pos - a.pos) * u
            }
            return last.pos
        }

        /// 文档切换/断开时复位平滑器。
        func resetSmoother() {
            stopDisplayLink()
            smCurrent = 0; smTarget = 0; lastAnchorAt = 0
            buf.removeAll(); useInterp = false; haveOffset = false; clockOffset = 0
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

        /// 每屏幕帧：算出目标位（插值 or 低通目标），再轻低通逼近。输出恒为凸组合、绝不外推，
        /// 只要位置流单调（正常滚动即是）就绝不过冲、绝不反向 → 从根上消除闪回/撤回。
        @objc private func stepFrame() {
            guard let pdfView, let doc = pdfView.document, doc.pageCount > 0 else { stopDisplayLink(); return }
            let now = CACurrentMediaTime()
            var frameDt = now - lastStepAt; lastStepAt = now
            if frameDt <= 0 || frameDt > 0.1 { frameDt = 1.0 / 120.0 }

            let target: Double
            let catchup: Double
            if useInterp {
                target = sampleAt(now - interpDelay)             // 落后 interpDelay 的插值位（不外推）
                catchup = min(1.0, 60.0 * frameDt)               // 快低通(~15ms)只为平掉迟到包/重锚台阶
            } else {
                target = smTarget
                catchup = min(1.0, 22.0 * frameDt)               // 本地低通（时间常数 ~45ms）
            }
            smCurrent += (target - smCurrent) * catchup

            let maxPos = Double(doc.pageCount - 1) + 0.9999
            smCurrent = min(max(0, smCurrent), maxPos)
            applyPos(smCurrent, doc: doc, pdfView: pdfView)

            // 收敛且久无新锚点 → 精确对齐并停 displayLink，随后解除抑制。
            let finalTarget = useInterp ? (buf.last?.pos ?? smCurrent) : smTarget
            let stale = now - lastAnchorAt
            if abs(finalTarget - smCurrent) < 0.0005, stale > 0.2 {
                smCurrent = min(max(0, finalTarget), maxPos)
                applyPos(smCurrent, doc: doc, pdfView: pdfView)
                stopDisplayLink()
                buf.removeAll()
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
