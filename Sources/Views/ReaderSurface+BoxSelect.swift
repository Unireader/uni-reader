import SwiftUI
import PDFKit
import AppKit   // 仅 NSEvent 修饰键读取（事件管道）；阅读区无 AppKit 视图（红线）

/// 框选文字（`textSelectBoxMode == true`，设置 → 阅读，默认开）：拖出矩形，**框到哪些字就选哪些字**——
/// 原生页用 PDFKit 自带的 `PDFPage.selection(for:)`（按矩形取字符级选区），天然比「起点→终点」的
/// 流式选择（`ReaderSurface+Selection.flowSelectChanged`）简单，不用再管阅读顺序/跨栏排序；
/// OCR 页按矩形跟每一行的横向重叠区间裁字符（复用 `OCRTextSelect.charOffset`/`clip`，与
/// `ocrGroupSelection` 裁首末行同一套字符定位），同样是字符级，只是不用管分组/阅读顺序——
/// 「更简单」的取舍落在算法（不用再判断分组归属），不是落在选择粒度（用户 2026-09-18 纠正）。
///
/// ⌘+拖 = **叠加**：起手时截一份当前选区存 `scratch.boxSelectBase`，这一框选出的内容在它基础上
/// 逐帧合并预览，松手即成多段不连续选区（同页也是——`TextSelection.rects` 本就是 `[Int: [CGRect]]`，
/// 一页多段天然支持）。不按 ⌘ 起手 = 每次拖都是全新选区（先清 base 与旧选区，同 Finder/Mail 的
/// 「普通拖=替换、⌘+拖=叠加」惯例，用户确认过的选择）。
extension ReaderSurface {

    // MARK: 手势（挂在 `dragSelectGesture`，`textSelectBoxMode` 分支，见 `ReaderSurface+Selection`）

    func boxSelectChanged(_ v: DragGesture.Value) {
        if boxSelectDrag == nil {
            // 起点在图钉 / 笔记卡片上：让位，boxSelectDrag 保持 nil → 整段框选不启动
            if draggablePinHit(v.startLocation) != nil || cardHit(v.startLocation) != nil { return }
            let additive = NSEvent.modifierFlags.contains(.command)
            boxSelectDrag = (v.startLocation, v.startLocation, additive)
            scratch.boxSelectBase = additive ? selection : nil
            if !additive { selection = nil }
        }
        guard var drag = boxSelectDrag else { return }
        drag.current = v.location
        boxSelectDrag = drag
        selection = mergeBoxSelection(base: scratch.boxSelectBase, start: drag.start, current: drag.current)
    }

    func boxSelectEnded() {
        boxSelectDrag = nil
        scratch.boxSelectBase = nil
    }

    // MARK: 命中与合并（内容坐标算矩形 → 逐页求交 → 逐页取选区 → 与 base 合并）

    /// 起点/当前点（容器 `.local` 坐标）→ 内容坐标矩形 → 逐页求交，取每页命中的行/字 → 与 `base`
    /// 合并成新的 `TextSelection`。取不到布局/页宽、矩形退化成一条线时原样返回 `base`（不清空已有选区）。
    private func mergeBoxSelection(base: TextSelection?, start: CGPoint, current: CGPoint) -> TextSelection? {
        guard let layout, pageW > 0 else { return base }
        let ds = max(0.0001, dispScale)
        let g = scratch.geo
        let p0 = CGPoint(x: g.offsetX + start.x, y: g.offsetY + start.y)
        let p1 = CGPoint(x: g.offsetX + current.x, y: g.offsetY + current.y)
        let boxMinX = min(p0.x, p1.x), boxMaxX = max(p0.x, p1.x)
        let boxMinY = min(p0.y, p1.y), boxMaxY = max(p0.y, p1.y)
        guard boxMaxX > boxMinX, boxMaxY > boxMinY else { return base }

        var rects = base?.rects ?? [:]
        var texts: [String] = base.map { [$0.text] } ?? []
        for page in layout.pageRange(fromDocY: boxMinY / ds, toDocY: boxMaxY / ds) {
            guard layout.offsets.indices.contains(page), layout.heights.indices.contains(page) else { continue }
            let pageTopDisp = layout.offsets[page] * ds
            let pageHDisp = layout.heights[page] * ds
            guard pageHDisp > 0 else { continue }
            let nx0 = min(max((boxMinX - pageX) / pageW, 0), 1)
            let nx1 = min(max((boxMaxX - pageX) / pageW, 0), 1)
            let ny0 = min(max((boxMinY - pageTopDisp) / pageHDisp, 0), 1)
            let ny1 = min(max((boxMaxY - pageTopDisp) / pageHDisp, 0), 1)
            guard nx1 > nx0, ny1 > ny0 else { continue }
            guard let seg = pageBoxSelection(page: page,
                                             box: CGRect(x: nx0, y: ny0, width: nx1 - nx0, height: ny1 - ny0))
            else { continue }
            rects[page, default: []].append(contentsOf: seg.rects)
            texts.append(seg.text)
        }
        let text = texts.filter { !$0.isEmpty }.joined(separator: "\n")
        return text.isEmpty ? base : TextSelection(rects: rects, text: text)
    }

    /// 单页内框选命中（页内归一化矩形 `box`，与容器坐标同尺度换算而来）：
    ///  · OCR 页——矩形纵向命中到的每一行，按矩形与该行的**横向重叠区间**裁字符（`OCRTextSelect.charOffset`
    ///    定位偏移、`clip` 切子行框，与 `ocrGroupSelection` 裁首末行同一套逻辑），字符级、不整行选；
    ///  · 原生页——`PDFPage.selection(for:)`，矩形四角各自转 PDF 页空间点再取包围盒（**rotation/scan-align
    ///    是 90° 整数倍时精确**——轴对齐矩形绕 90° 倍数转完还是轴对齐矩形；scan-align 的小角度校正会让
    ///    包围盒略微外扩，边缘偶尔多选一点点字符，不是错误只是没有逐字裁到严丝合缝）。
    private func pageBoxSelection(page: Int, box: CGRect) -> (rects: [CGRect], text: String)? {
        if let runs = ocrRuns(page: page) {
            var items: [TextRun] = []
            for r in runs where r.rect.intersects(box) {
                let loX = max(box.minX, r.rect.minX), hiX = min(box.maxX, r.rect.maxX)
                guard hiX > loX else { continue }
                let lo = OCRTextSelect.charOffset(in: r, atNX: Double(loX))
                let hi = OCRTextSelect.charOffset(in: r, atNX: Double(hiX))
                if let c = OCRTextSelect.clip(run: r, from: lo, to: hi) { items.append(c) }
            }
            guard !items.isEmpty else { return nil }
            return (items.map(\.rect), items.map(\.text).joined(separator: "\n"))
        }
        guard let pdf = session.pdf, let pdfPage = pdf.page(at: page) else { return nil }
        let mb = pdfPage.bounds(for: PageBitmap.effectiveBox(pdfPage))
        guard mb.width > 0, mb.height > 0 else { return nil }
        let align = session.pageAlign(page)
        let corners: [(CGFloat, CGFloat)] = [(box.minX, box.minY), (box.maxX, box.minY),
                                             (box.minX, box.maxY), (box.maxX, box.maxY)]
        let pts = corners.map {
            PageGeometry.pageSpacePoint(normX: $0.0, normY: $0.1, box: mb, rotation: pdfPage.rotation, align: align)
        }
        let xs = pts.map(\.x), ys = pts.map(\.y)
        let pdfRect = CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
        guard let sel = pdfPage.selection(for: pdfRect), sel.string?.isEmpty == false else { return nil }
        let lineRects = PageGeometry.normalizedLineRects(of: sel, in: pdf, align: { session.pageAlign($0) })[page] ?? []
        guard !lineRects.isEmpty else { return nil }
        return (lineRects, sel.string ?? "")
    }

    // MARK: 进行中的虚线矩形 overlay（视口坐标，挂 ScrollView；与 DragGesture .local 同空间，画法同 `lassoDragOverlay`）

    @ViewBuilder var boxSelectDragOverlay: some View {
        if let d = boxSelectDrag {
            let r = CGRect(x: min(d.start.x, d.current.x), y: min(d.start.y, d.current.y),
                           width: abs(d.current.x - d.start.x), height: abs(d.current.y - d.start.y))
            ZStack {
                Rectangle().fill(Color.accentColor.opacity(0.08))
                Rectangle().stroke(Color.accentColor, style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
            }
            .frame(width: r.width, height: r.height)
            .position(x: r.midX, y: r.midY)
            .allowsHitTesting(false)
        }
    }
}
