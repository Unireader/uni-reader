import AppKit
import QuartzCore

/// 坐标换算 + 标记层（高亮 / 批注标记 / 搜索命中 / 选区）的刷新。
///
/// 三套坐标：**文档坐标**（页宽 = fit 宽，`pageFrame`）、**页内归一化**（0~1 左上原点，数据全存这个）、
/// **屏幕点**（覆盖层坐标，`displayRect`）。鼠标事件先换成文档坐标再落到页内归一化；
/// 图钉 / 气泡 / 框选框这些「屏幕固定尺寸」的东西在屏幕点里算（与 SwiftUI 版「显示坐标」同一口径）。
extension ReaderView {

    // MARK: 坐标换算

    /// 文档坐标点 → (页, 页内归一化)。越界按页边夹（拖到页外 = 到页边）；`xRange` 在画板模式下放宽到页边。
    func pageNorm(atDoc p: CGPoint, xRange: ClosedRange<Double> = 0...1) -> (page: Int, nx: CGFloat, ny: CGFloat)? {
        guard let layout = pageLayout, fitBasis > 0 else { return nil }
        let page = layout.locate(docY: p.y / max(0.0001, ds)).page
        let f = pageFrame(page)
        guard f.width > 0, f.height > 0 else { return nil }
        let nx = min(max((p.x - f.minX) / f.width, CGFloat(xRange.lowerBound)), CGFloat(xRange.upperBound))
        let ny = min(max((p.y - f.minY) / f.height, 0), 1)
        return (page, nx, ny)
    }

    func docPoint(page: Int, nx: CGFloat, ny: CGFloat) -> CGPoint {
        let f = pageFrame(page)
        return CGPoint(x: f.minX + nx * f.width, y: f.minY + ny * f.height)
    }

    /// 窗口事件点 → 文档坐标。
    func docPoint(of event: NSEvent) -> CGPoint { docView.convert(event.locationInWindow, from: nil) }

    /// 文档坐标矩形 → 覆盖层（屏幕点）。滚动与缩放都已算进去。
    func displayRect(ofDoc r: CGRect) -> CGRect { overlay.convert(r, from: docView) }
    func displayPoint(ofDoc p: CGPoint) -> CGPoint { overlay.convert(p, from: docView) }
    func docPoint(ofDisplay p: CGPoint) -> CGPoint { docView.convert(p, from: overlay) }

    /// 某页在覆盖层里的矩形（屏幕点）。
    func displayPageRect(_ i: Int) -> CGRect { displayRect(ofDoc: pageFrame(i)) }

    /// 页的显示纵横比（页高 / 页宽）：⇧ 尺子按「看上去」的角度吸附要用它把 y 折成与 x 同尺度。
    func pageAspect(page: Int) -> Double {
        guard let layout = pageLayout, layout.heights.indices.contains(page), fitBasis > 0 else { return 1 }
        return Double(layout.heights[page] * ds / fitBasis)
    }

    /// 页内归一化矩形 → 屏幕点矩形。
    func displayRect(page: Int, norm r: CGRect) -> CGRect {
        let pr = displayPageRect(page)
        return CGRect(x: pr.minX + r.minX * pr.width, y: pr.minY + r.minY * pr.height,
                      width: r.width * pr.width, height: r.height * pr.height)
    }

    // MARK: 标记层

    /// 按会话数据重画已实化各页的标记层。数据量小（只看实化窗口里的页），整批重算就行。
    func refreshMarks() {
        guard didSetup, !groups.isEmpty else { return }
        let range = realized
        var highlights: [Int: [Highlight]] = [:]
        for h in session.highlights where range.contains(h.page) { highlights[h.page, default: []].append(h) }
        var notes: [Int: [TextNote]] = [:]
        for n in session.textNotes where range.contains(n.page) && !n.rects.isEmpty { notes[n.page, default: []].append(n) }
        var matches: [Int: [CGRect]] = [:]
        for m in session.searchMatches where range.contains(m.page) { matches[m.page, default: []].append(contentsOf: m.rects) }
        let active = session.currentMatchIndex.flatMap {
            session.searchMatches.indices.contains($0) ? session.searchMatches[$0] : nil
        }
        let types = session.noteTypes
        let showOCR = session.showOCRBlocks
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (i, g) in groups {
            let l = g.marks
            var marks: [PageMarksLayer.Mark] = []
            for h in highlights[i] ?? [] {
                marks.append(.init(rects: h.rects, style: h.style, color: h.color.nsColor.cgColor,
                                   fillOpacity: Highlight.fillOpacity))
            }
            for n in notes[i] ?? [] {
                let base = n.color?.nsColor
                    ?? (n.typeId == nil ? ReaderMarkColors.noteBase : NoteType.resolve(n.typeId, in: types).nsColor)
                marks.append(.init(rects: n.rects, style: n.style, color: base.cgColor,
                                   fillOpacity: ReaderMarkColors.noteFillOpacity))
            }
            l.marks = marks
            l.matchRects = matches[i] ?? []
            l.activeMatchRects = active?.page == i ? active?.rects ?? [] : []
            l.matchPulse = active?.page == i ? matchPulseT : 1
            l.selectionRects = selection?.rects[i] ?? []
            l.ocrBlocks = showOCR ? (session.ocrVisibleRuns(page: i) ?? []) : []
            l.ocrGroups = showOCR && session.ocrBlockGrouped ? session.ocrGroups(page: i) : []
            l.ocrWatermarks = showOCR ? session.ocrWatermarkRuns(page: i) : []
            l.pt = 1 / max(0.0001, zoom)
            let scale = inkContentsScale(for: l.bounds.size)
            if abs(l.contentsScale - scale) > 0.01 { l.contentsScale = scale }
            if l.isEmpty { l.contents = nil } else { l.setNeedsDisplay() }
        }
        CATransaction.commit()
    }

    /// 选区变了：镜像给 MCP，重画标记。
    func selectionChanged(from old: TextSelection?) {
        guard old != selection else { return }
        session.currentSelection = selection
        refreshMarks()
    }

    func clearSelection() { if selection != nil { selection = nil } }

    // MARK: 搜索命中闪烁（跟随落位后开始，0.45s 从最亮回落到常态）

    func beginMatchPulseAnimation() {
        matchPulseStart = CACurrentMediaTime()
        matchPulseT = 0
        refreshMarks()
        startFrameLink()
    }

    func stepMatchPulse() {
        let t = CGFloat(min(1, (CACurrentMediaTime() - matchPulseStart) / 0.45))
        matchPulseT = t
        guard let active = session.currentMatchIndex.flatMap({
            session.searchMatches.indices.contains($0) ? session.searchMatches[$0] : nil
        }), let g = groups[active.page] else { return }
        g.marks.matchPulse = t
        g.marks.setNeedsDisplay()
    }

    var isMatchPulsing: Bool { matchPulseT < 1 }
}
