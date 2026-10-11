import CoreGraphics
import Foundation

/// `render_page` 的 `include_marks`（`EXERCISE-PLAN.md §2.4`，2026-10-11）：把用户在这一页上的**手写笔迹和高亮**
/// 叠画在页图上，让 Agent 看得到用户在书上的作答（圈的选项、写的答案、高亮的选项）。
///
/// 只画给 Agent 看，求的是「看得清」不是和阅读区逐像素一致：笔迹走同一份 `InkRenderCG`，
/// 线宽按常见的 fit 页宽（`ScratchPad.eraserRefWidth` = 800pt）折算；高亮按三种样式简单画。
/// 隐藏了的图层不画（用户藏起来的东西别拿给 Agent 看）。
struct MCPPageMarks {
    var strokes: [InkStroke] = []
    var highlights: [Highlight] = []

    var isEmpty: Bool { strokes.isEmpty && highlights.isEmpty }

    /// 叠画到页图上，返回新图。坐标：笔迹点与高亮框都是页内归一化（0~1、左上原点；开着扫描页对齐就是对齐后的页面，
    /// 与 `PageBitmap.render(align:)` 出的图同一套）。任意线程可调。
    func draw(over image: CGImage) -> CGImage? {
        let w = CGFloat(image.width), h = CGFloat(image.height)
        guard let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        // 下面一律左上原点、y 向下
        ctx.translateBy(x: 0, y: h)
        ctx.scaleBy(x: 1, y: -1)
        ctx.clip(to: CGRect(x: 0, y: 0, width: w, height: h))

        for hl in highlights {
            let c = CGColor(srgbRed: CGFloat(hl.color.r / 255), green: CGFloat(hl.color.g / 255),
                            blue: CGFloat(hl.color.b / 255), alpha: 1)
            let norm: [CGRect] = hl.rects.isEmpty ? [hl.anchor] : hl.rects
            var rects: [CGRect] = []
            for r in norm {
                rects.append(CGRect(x: r.minX * w, y: r.minY * h, width: r.width * w, height: r.height * h))
            }
            ctx.saveGState()
            switch hl.style {
            case .fill:
                ctx.setBlendMode(.multiply)
                ctx.setFillColor(c.copy(alpha: 0.45) ?? c)
                for r in rects { ctx.fill(r) }
            case .underline:
                ctx.setStrokeColor(c)
                ctx.setLineWidth(max(1.5, w * 0.002))
                for r in rects {
                    ctx.move(to: CGPoint(x: r.minX, y: r.maxY)); ctx.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
                }
                ctx.strokePath()
            case .box:
                ctx.setStrokeColor(c)
                ctx.setLineWidth(max(1.5, w * 0.002))
                for r in rects { ctx.stroke(r) }
            }
            ctx.restoreGState()
        }

        let inkScale = w / CGFloat(ScratchPad.eraserRefWidth)
        for st in strokes {
            InkRenderCG.drawStroke(st, in: ctx, inkScale: inkScale) {
                CGPoint(x: CGFloat($0.x) * w, y: CGFloat($0.y) * h)
            }
        }
        return ctx.makeImage()
    }
}

extension MCPFacade {
    /// 一页上用户的笔迹（只要可见图层）与高亮，从库里读。开着这篇的标签先把还没落库的结清，
    /// 免得「刚写的那一笔」Agent 看不到（同 `delete_annotations` 的做法）。
    func pageMarks(_ t: DocTarget, index: Int) -> MCPPageMarks {
        guard let id = t.documentId, let store = t.store else { return MCPPageMarks() }
        for tab in sessionsShowing(id) { tab.flushPersist() }
        let notes = (try? store.notes(documentId: id, page: index)) ?? []
        let ws = WorkspaceRegistry.shared.openManagers.first { $0.store === store }
        let hidden = Set((ws?.inkLayers(documentId: id) ?? []).filter { !$0.visible }.map(\.id))
        return MCPPageMarks(
            strokes: notes.filter { $0.kind == InkStroke.noteKind }.compactMap(InkStroke.init(note:))
                .filter { !hidden.contains($0.layerId) },
            highlights: notes.filter { $0.kind == Highlight.noteKind }.compactMap(Highlight.init(note:)))
    }
}
