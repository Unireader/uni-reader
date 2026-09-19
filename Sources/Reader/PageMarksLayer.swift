import AppKit
import QuartzCore

/// 一页的**标记层**（在页图之上、笔迹之下）：文字高亮、文字批注的标记、搜索命中、当前选区、OCR 调试块。
/// 画法与 SwiftUI 版 `PageCellView` 各层逐项一致（铺色 / 画线 / 画框三种画法、命中圆角 4pt、选区圆角 2pt……）。
///
/// 图层在**文档坐标**里（页宽 = fit 宽），滚动视图缩放时整体拉伸；那些「固定屏幕点」的量（外扩 1pt、线宽 1.5pt）
/// 用 `pt`（= 1 / 缩放倍率，一个屏幕点折成多少文档单位）换算，缩放停下后按新倍率重画一次。
final class PageMarksLayer: QuietLayer {
    struct Mark {
        var rects: [CGRect]          // 页内归一化行框
        var style: HighlightStyle
        var color: CGColor           // 基色（不含透明度）
        var fillOpacity: Double
    }

    var marks: [Mark] = []                  // 高亮 + 批注标记（批注画在高亮之上，顺序即层序）
    var matchRects: [CGRect] = []
    var activeMatchRects: [CGRect] = []
    /// 当前命中切换闪烁：0 = 刚切换（最亮最大）… 1 = 落定。
    var matchPulse: CGFloat = 1
    var selectionRects: [CGRect] = []
    var selectionColor: CGColor = NSColor.controlAccentColor.withAlphaComponent(0.35).cgColor
    /// OCR 调试上色（设置里的「显示识别块」）。
    var ocrBlocks: [TextRun] = []
    var ocrGroups: [Int] = []
    var ocrWatermarks: [TextRun] = []
    /// 一个屏幕点折成多少文档单位（= 1 / 缩放倍率）。
    var pt: CGFloat = 1

    var isEmpty: Bool {
        marks.isEmpty && matchRects.isEmpty && activeMatchRects.isEmpty && selectionRects.isEmpty
            && ocrBlocks.isEmpty && ocrWatermarks.isEmpty
    }

    override func draw(in ctx: CGContext) {
        guard !isEmpty else { return }
        yDown(ctx)
        let s = bounds.size
        func px(_ r: CGRect) -> CGRect {
            CGRect(x: r.minX * s.width, y: r.minY * s.height, width: r.width * s.width, height: r.height * s.height)
        }
        func fillRound(_ r: CGRect, radius: CGFloat, color: CGColor) {
            ctx.setFillColor(color)
            ctx.addPath(CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil))
            ctx.fillPath()
        }

        // OCR 调试：按黄金角旋转色相上色 + 序号（分组模式下同组同色）
        if !ocrBlocks.isEmpty {
            let grouped = !ocrGroups.isEmpty
            for (i, run) in ocrBlocks.enumerated() {
                let r = px(run.rect)
                let key = grouped ? (ocrGroups.indices.contains(i) ? ocrGroups[i] : i) : i
                let hue = (Double(key) * 0.61803398875).truncatingRemainder(dividingBy: 1)
                let c = NSColor(hue: hue, saturation: 0.8, brightness: 0.95, alpha: 1)
                let path = CGPath(roundedRect: r, cornerWidth: 2 * pt, cornerHeight: 2 * pt, transform: nil)
                ctx.setFillColor(c.withAlphaComponent(0.28).cgColor)
                ctx.addPath(path); ctx.fillPath()
                ctx.setStrokeColor(c.cgColor); ctx.setLineWidth(pt)
                ctx.addPath(path); ctx.strokePath()
                drawLabel("\(key)", at: CGPoint(x: r.minX + 2 * pt, y: r.minY + pt), color: c, in: ctx)
            }
        }
        if !ocrWatermarks.isEmpty {
            ctx.saveGState()
            ctx.setStrokeColor(NSColor.gray.withAlphaComponent(0.75).cgColor)
            ctx.setLineWidth(pt)
            ctx.setLineDash(phase: 0, lengths: [4 * pt, 3 * pt])
            for run in ocrWatermarks {
                ctx.addPath(CGPath(roundedRect: px(run.rect), cornerWidth: 2 * pt, cornerHeight: 2 * pt, transform: nil))
            }
            ctx.strokePath()
            ctx.restoreGState()
        }

        // 高亮 / 批注标记：铺色 / 画线 / 画框
        for m in marks {
            switch m.style {
            case .fill:
                let c = m.color.copy(alpha: m.fillOpacity) ?? m.color
                for r in m.rects { fillRound(px(r).insetBy(dx: -pt, dy: -0.5 * pt), radius: 2 * pt, color: c) }
            case .underline:
                let c = m.color.copy(alpha: Highlight.strokeOpacity) ?? m.color
                ctx.setStrokeColor(c)
                ctx.setLineCap(.round)
                for r in m.rects {
                    let p = px(r)
                    let w = max(1.5 * pt, p.height * 0.07)
                    let y = p.maxY + w * 0.5
                    ctx.setLineWidth(w)
                    ctx.move(to: CGPoint(x: p.minX - pt, y: y))
                    ctx.addLine(to: CGPoint(x: p.maxX + pt, y: y))
                    ctx.strokePath()
                }
            case .box:
                let c = m.color.copy(alpha: Highlight.strokeOpacity) ?? m.color
                ctx.setStrokeColor(c)
                ctx.setLineWidth(1.5 * pt)
                for r in m.rects {
                    ctx.addPath(CGPath(roundedRect: px(r).insetBy(dx: -1.5 * pt, dy: -pt),
                                       cornerWidth: 2 * pt, cornerHeight: 2 * pt, transform: nil))
                    ctx.strokePath()
                }
            }
        }

        // 搜索命中：全部淡黄；当前命中橙色，切换瞬间更亮更大（纯色 + 尺寸变化，无阴影渐变）
        for r in matchRects {
            fillRound(px(r).insetBy(dx: -pt, dy: -0.5 * pt), radius: 4 * pt,
                      color: NSColor.systemYellow.withAlphaComponent(0.35).cgColor)
        }
        if !activeMatchRects.isEmpty {
            let ease = 1 - matchPulse
            let opacity = 0.55 + ease * 0.45
            let grow = ease * 3
            for r in activeMatchRects {
                let g = px(r).insetBy(dx: (-1 - grow) * pt, dy: (-0.5 - grow * 0.4) * pt)
                fillRound(g, radius: (4 + grow * 0.5) * pt, color: NSColor.systemOrange.withAlphaComponent(opacity).cgColor)
            }
        }
        for r in selectionRects {
            fillRound(px(r).insetBy(dx: -pt, dy: -0.5 * pt), radius: 2 * pt, color: selectionColor)
        }
    }

    private func drawLabel(_ s: String, at p: CGPoint, color: NSColor, in ctx: CGContext) {
        let attr = NSAttributedString(string: s, attributes: [
            .font: NSFont.boldSystemFont(ofSize: 9 * pt),
            .foregroundColor: color,
        ])
        let line = CTLineCreateWithAttributedString(attr)
        ctx.saveGState()
        // 文字要正着画：上下文是 y 向下的，局部再翻回来
        ctx.textMatrix = .identity
        ctx.translateBy(x: p.x, y: p.y + 9 * pt)
        ctx.scaleBy(x: 1, y: -1)
        ctx.textPosition = .zero
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }
}

extension NoteType {
    /// 类型色（AppKit）。SwiftUI 那份 `uiColor` 在第 8 步随 SwiftUI 视图一起删。
    var nsColor: NSColor {
        let c = NoteType.paletteRGB(colorKey)
        return NSColor(srgbRed: c.r / 255, green: c.g / 255, blue: c.b / 255, alpha: 1)
    }
}

/// 页面标记的配色常量（与 SwiftUI 版 `PageCellView` 同值）。
enum ReaderMarkColors {
    /// 通用笔记的标记基色（暖黄）与铺色透明度。
    static let noteBase = NSColor(srgbRed: 1, green: 0.82, blue: 0.15, alpha: 1)
    static let noteFillOpacity: Double = 0.32
    static let noteMarker = NSColor(srgbRed: 1, green: 0.80, blue: 0.15, alpha: 1)
    static let scratchMarker = NSColor(srgbRed: 0.62, green: 0.83, blue: 0.98, alpha: 1)
    static let imageMarker = NSColor(srgbRed: 0.64, green: 0.88, blue: 0.80, alpha: 1)
    /// 书签缎带红（用户 2026-09-02 实测「橘色没反应过来」后改的通用红）。
    static let bookmarkMarker = NSColor(srgbRed: 0.84, green: 0.23, blue: 0.24, alpha: 1)
}
