import SwiftUI
import PDFKit
import AppKit

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
        }

        container.overlay.strokes = session.strokes
        container.overlay.liveStroke = session.liveStroke
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

        /// 应用来自 sim/平板的锚点：滚到该(页, 比例)。程序化滚动，短暂抑制回发防回环。
        func applyIncomingAnchor(_ a: ScrollAnchor) {
            guard let pdfView, let doc = pdfView.document, let page = doc.page(at: a.page) else { return }
            let b = page.bounds(for: .mediaBox)
            let y = b.maxY - CGFloat(a.frac) * b.height
            suppressEmit = true
            pdfView.go(to: PDFDestination(page: page, at: CGPoint(x: b.minX, y: y)))
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.suppressEmit = false
            }
        }

        private static func firstScrollView(in view: NSView) -> NSScrollView? {
            for sub in view.subviews {
                if let sv = sub as? NSScrollView { return sv }
                if let found = firstScrollView(in: sub) { return found }
            }
            return nil
        }

        deinit { NotificationCenter.default.removeObserver(self) }
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
