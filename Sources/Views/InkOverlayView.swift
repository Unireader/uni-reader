import AppKit
import PDFKit

/// 叠加在 PDFView 之上的手写渲染层。笔画锚定在页面归一化坐标，
/// 通过 `pdfView.convert(_:from:)` 换算到视图坐标；随缩放/滚动重绘保持对齐。
/// 事件穿透（hitTest 返回 nil），不影响 PDF 交互。
final class InkOverlayView: NSView {
    weak var pdfView: PDFView?
    var strokes: [InkStroke] = []
    var liveStroke: InkStroke?
    var hover: HoverPoint?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var isOpaque: Bool { false }

    func bindObservers() {
        guard let pdfView = pdfView else { return }
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(redraw), name: .PDFViewScaleChanged, object: pdfView)
        nc.addObserver(self, selector: #selector(redraw), name: .PDFViewPageChanged, object: pdfView)
        if let scroll = firstScrollView(in: pdfView) {
            scroll.contentView.postsBoundsChangedNotifications = true
            nc.addObserver(self, selector: #selector(redraw),
                           name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        }
    }

    @objc private func redraw() { needsDisplay = true }

    private func firstScrollView(in view: NSView) -> NSScrollView? {
        for sub in view.subviews {
            if let sv = sub as? NSScrollView { return sv }
            if let found = firstScrollView(in: sub) { return found }
        }
        return nil
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let pdfView = pdfView, let doc = pdfView.document,
              let ctx = NSGraphicsContext.current?.cgContext else { return }
        // 只在「工具栏/标题栏下方」的内容区作画：否则滚到顶部的墨迹会从半透明工具栏透出，浮在标题栏上。
        // contentLayoutRect 已排除标题栏+工具栏；转到本视图坐标裁剪即可（无窗口时不裁，正常全绘）。
        if let win = window {
            let layout = convert(win.contentLayoutRect, from: win.contentView)
            ctx.clip(to: bounds.intersection(layout))
        }
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        let scale = pdfView.scaleFactor
        for st in strokes { drawStroke(st, doc: doc, pdfView: pdfView, ctx: ctx, scale: scale) }
        if let live = liveStroke { drawStroke(live, doc: doc, pdfView: pdfView, ctx: ctx, scale: scale) }
        drawHover(doc: doc, pdfView: pdfView, ctx: ctx)
    }

    /// 平板笔悬停指示：在页面归一化坐标处画笔尖圆环（随缩放/滚动对齐）。
    private func drawHover(doc: PDFDocument, pdfView: PDFView, ctx: CGContext) {
        guard let h = hover, let page = doc.page(at: h.page) else { return }
        let b = page.bounds(for: .mediaBox)
        let px = b.minX + CGFloat(h.nx) * b.width
        let py = b.minY + CGFloat(1 - h.ny) * b.height
        let v = pdfView.convert(CGPoint(x: px, y: py), from: page)
        let r: CGFloat = 9
        ctx.setStrokeColor(NSColor.systemBlue.withAlphaComponent(0.9).cgColor)
        ctx.setLineWidth(2)
        ctx.strokeEllipse(in: CGRect(x: v.x - r, y: v.y - r, width: r * 2, height: r * 2))
    }

    private func drawStroke(_ st: InkStroke, doc: PDFDocument, pdfView: PDFView,
                            ctx: CGContext, scale: CGFloat) {
        guard let page = doc.page(at: st.page), !st.points.isEmpty else { return }
        let b = page.bounds(for: .mediaBox)
        let w = st.width
        let vps: [CGPoint] = st.points.map { p in
            let px = b.minX + CGFloat(p.x) * b.width
            let py = b.minY + CGFloat(1 - p.y) * b.height
            return pdfView.convert(CGPoint(x: px, y: py), from: page)
        }
        func lineWidth(_ pressure: Double) -> CGFloat {
            max(0.5, CGFloat(0.6 + pressure * w) * scale)
        }
        st.color.nsColor.setStroke()
        st.color.nsColor.setFill()

        if vps.count == 1 {
            let r = lineWidth(st.points[0].z) / 2
            ctx.fillEllipse(in: CGRect(x: vps[0].x - r, y: vps[0].y - r, width: r * 2, height: r * 2))
            return
        }
        // 二次贝塞尔中点平滑（与采集页一致）：每段用 [上一中点 → 当前中点]、控制点取当前采样点。
        var lastMid = vps[0]
        var lastPt = vps[0]
        for i in 1..<vps.count {
            let mid = CGPoint(x: (lastPt.x + vps[i].x) / 2, y: (lastPt.y + vps[i].y) / 2)
            ctx.setLineWidth(lineWidth(st.points[i].z))
            ctx.beginPath()
            ctx.move(to: lastMid)
            ctx.addQuadCurve(to: mid, control: lastPt)
            ctx.strokePath()
            lastMid = mid; lastPt = vps[i]
        }
    }

    deinit { NotificationCenter.default.removeObserver(self) }
}
