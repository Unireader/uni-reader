import SwiftUI
import AppKit
import PDFKit

/// 桌面「模拟平板」窗口：用 `PadRenderer` 连续渲染平板当前会话的文档，
/// 滚轮滚动、鼠标当笔落墨（走 `AppModel` 共用落墨 API，所以 Mac 主窗口也会同步显示）。
/// 用来在没有真平板时开发/测试方案 B 的滚动与坐标逻辑。
struct SimPadView: View {
    @EnvironmentObject private var app: AppModel

    var body: some View {
        if let s = app.padSession {
            SimPadBound(app: app, session: s)
        } else {
            VStack(spacing: 6) {
                Text(L("Simulated Tablet")).font(.headline)
                Text(L("Open a PDF and activate its window.")).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct SimPadBound: View {
    let app: AppModel
    @ObservedObject var session: DocSession

    var body: some View {
        if session.pdf != nil {
            SimPadRepresentable(app: app, session: session,
                                scrollAnchor: session.scrollAnchor,
                                tick: session.strokes.count &+ (session.liveStroke?.points.count ?? 0))
                .ignoresSafeArea()
        } else {
            Text(L("Open a PDF and activate its window.")).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct SimPadRepresentable: NSViewRepresentable {
    let app: AppModel
    let session: DocSession
    let scrollAnchor: ScrollAnchor?   // 存储属性：锚点变化才会让 SwiftUI 认为视图值变了，从而调用 updateNSView
    let tick: Int   // 使笔迹变化触发 updateNSView 重绘

    func makeNSView(context: Context) -> SimPadNSView {
        let v = SimPadNSView()
        v.app = app; v.session = session
        return v
    }
    func updateNSView(_ v: SimPadNSView, context: Context) {
        v.app = app; v.session = session
        if let a = scrollAnchor, a.origin != "sim", a.seq > v.lastAppliedAnchorSeq {
            v.lastAppliedAnchorSeq = a.seq
            v.applyIncomingAnchor(a)
        } else {
            v.needsDisplay = true
        }
    }
}

final class SimPadNSView: NSView {
    weak var app: AppModel?
    weak var session: DocSession?
    private var renderer: PadRenderer?
    private var topDocY: CGFloat = 0
    private var drawingPage: Int?
    var lastAppliedAnchorSeq = 0
    /// SimPad 用工具条当前选中的那支笔（改笔型/颜色即时生效，方便在没有真平板时试各种笔）。
    private var pen: PenPreset {
        let pens = app?.pens ?? []
        let idx = app?.padPenIndex ?? 0
        return pens.indices.contains(idx) ? pens[idx] : (pens.first ?? PenPreset(name: "", color: .defaultInk, width: 8))
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    private func ensureRenderer() {
        guard let pdf = session?.pdf else { renderer = nil; return }
        if renderer == nil || renderer?.doc !== pdf || renderer?.width != bounds.width {
            renderer = PadRenderer(doc: pdf, width: bounds.width)
            clampScroll()
        }
    }

    private func clampScroll() {
        guard let r = renderer else { topDocY = 0; return }
        topDocY = min(max(0, topDocY), r.maxScroll(viewportHeight: bounds.height))
    }

    override func draw(_ dirtyRect: NSRect) {
        ensureRenderer()
        guard let r = renderer, let ctx = NSGraphicsContext.current?.cgContext else {
            NSColor(white: 0.12, alpha: 1).setFill(); bounds.fill(); return
        }
        r.render(topDocY: topDocY, height: bounds.height).draw(in: bounds)

        guard let s = session else { return }
        ctx.setLineCap(.round); ctx.setLineJoin(.round)
        for st in s.strokes { drawStroke(st, r: r, ctx: ctx) }
        if let live = s.liveStroke { drawStroke(live, r: r, ctx: ctx) }
    }

    /// 四种笔型差异化渲染（与 Mac 阅读区 `PageStreamView.drawStroke` 同参数/同算法，见 `PenBrushType`/`InkRender`）。
    private func drawStroke(_ st: InkStroke, r: PadRenderer, ctx: CGContext) {
        guard !st.points.isEmpty else { return }
        let vps = st.points.map { r.point(page: st.page, nx: $0.x, ny: $0.y, topDocY: topDocY) }
        let type = st.type, w = st.width
        let cr = st.color.r / 255, cg = st.color.g / 255, cb = st.color.b / 255
        func stroke(_ a: Double) { ctx.setStrokeColor(red: cr, green: cg, blue: cb, alpha: a) }
        func fill(_ a: Double) { ctx.setFillColor(red: cr, green: cg, blue: cb, alpha: a) }
        ctx.setLineJoin(.round); ctx.setLineCap(.round)

        if vps.count == 1 {
            let a = type == .pencil ? st.color.a * 0.6 : st.color.a
            fill(a)
            let rad = CGFloat(type.strokeWidth(pressure: st.points[0].z, base: w)) / 2
            ctx.fillEllipse(in: CGRect(x: vps[0].x - rad, y: vps[0].y - rad, width: rad * 2, height: rad * 2))
            return
        }

        switch type {
        case .marker:
            ctx.saveGState()
            ctx.setBlendMode(.multiply); ctx.setLineCap(.square); ctx.setLineWidth(CGFloat(w)); stroke(st.color.a)
            ctx.beginPath(); ctx.move(to: vps[0]); var lastPt = vps[0]
            for i in 1..<vps.count {
                let mid = CGPoint(x: (lastPt.x + vps[i].x) / 2, y: (lastPt.y + vps[i].y) / 2)
                ctx.addQuadCurve(to: mid, control: lastPt); lastPt = vps[i]
            }
            ctx.strokePath(); ctx.restoreGState()

        case .pencil:
            for pass in PenBrushType.pencilPasses {
                stroke(st.color.a * pass.alpha)
                var prev: CGPoint?
                for i in 0..<vps.count {
                    let lw = type.strokeWidth(pressure: st.points[i].z, base: w)
                    let (nx, ny) = InkRender.perp(vps, i)
                    let rnd = InkRender.jitter(st.points[i].x, st.points[i].y + pass.phase)
                    let wob = (sin(Double(i) * 0.7 + pass.phase) * pass.amp + rnd * pass.amp * 0.7) * lw
                    let cur = CGPoint(x: vps[i].x + nx * CGFloat(wob), y: vps[i].y + ny * CGFloat(wob))
                    if let p0 = prev {
                        ctx.setLineWidth(CGFloat(max(0.7, lw * pass.wScale)))
                        ctx.beginPath(); ctx.move(to: p0); ctx.addLine(to: cur); ctx.strokePath()
                    }
                    prev = cur
                }
            }

        default:   // ballpoint / fountain
            stroke(st.color.a)
            let n = vps.count
            var lastMid = vps[0], lastPt = vps[0]
            for i in 1..<vps.count {
                let mid = CGPoint(x: (lastPt.x + vps[i].x) / 2, y: (lastPt.y + vps[i].y) / 2)
                ctx.setLineWidth(CGFloat(type.strokeWidth(pressure: st.points[i].z, base: w)
                                         * type.fountainTaper(index: i, count: n)))
                ctx.beginPath(); ctx.move(to: lastMid); ctx.addQuadCurve(to: mid, control: lastPt); ctx.strokePath()
                lastMid = mid; lastPt = vps[i]
            }
        }
    }

    override func scrollWheel(with event: NSEvent) {
        topDocY -= event.scrollingDeltaY
        clampScroll()
        needsDisplay = true
        emitAnchor()
    }

    /// 应用来自 Mac 的锚点：把视口顶部滚到该(页, 比例)。程序化滚动，不回发锚点。
    func applyIncomingAnchor(_ a: ScrollAnchor) {
        ensureRenderer()
        guard let r = renderer, a.page < r.pageOffsets.count else { return }
        topDocY = r.pageOffsets[a.page] + CGFloat(a.frac) * r.pageHeights[a.page]
        clampScroll()
        needsDisplay = true
    }

    /// 把当前视口顶部的位置作为锚点发出（供 Mac 主窗口跟随）。
    private func emitAnchor() {
        guard let r = renderer, let s = session else { return }
        let docY = topDocY
        for i in r.pageOffsets.indices where docY < r.pageOffsets[i] + r.pageHeights[i] {
            let f = (docY - r.pageOffsets[i]) / max(1, r.pageHeights[i])
            s.emitAnchor(page: i, frac: Double(f), origin: "sim")
            return
        }
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard let r = renderer, let loc = r.locate(x: p.x, yFromTop: p.y, topDocY: topDocY) else { return }
        drawingPage = loc.page
        app?.inkBegin(page: loc.page, color: pen.color, width: pen.width, type: pen.type,
                      points: [SIMD3(loc.nx, loc.ny, 0.5)])
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let page = drawingPage, let r = renderer else { return }
        let p = convert(event.locationInWindow, from: nil)
        // 仅在起始页范围内追加（跨页拖动先忽略）
        if let loc = r.locate(x: p.x, yFromTop: p.y, topDocY: topDocY), loc.page == page {
            app?.inkAppend([SIMD3(loc.nx, loc.ny, 0.5)])
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        app?.inkEnd()
        drawingPage = nil
        needsDisplay = true
    }
}
