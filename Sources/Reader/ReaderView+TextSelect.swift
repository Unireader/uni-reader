import AppKit
import PDFKit

/// 文字选择（逻辑同 SwiftUI 版 `ReaderSurface+Selection` / `+BoxSelect`，逐条移植）：
///  · 原生页走 PDFKit 原生选择引擎（`selection(from:at:to:at:)`，可视阅读顺序 / 跨页 / CJK 都交给它）；
///  · OCR 页走行级文本层，行内字符级定位（`OCRTextSelect`），同页按分组感知约束（所见即所选）；
///  · ⌘+拖 = 框选文字（永远叠加；再框到已选中的部分按设置合并或反选）；双击选词 / 行；⌘A 全选当前页。
extension ReaderView {

    // MARK: 基础

    /// 页内归一化点 → PDF 页空间点。
    func pageSpacePoint(_ n: (page: Int, nx: CGFloat, ny: CGFloat)) -> CGPoint? {
        guard let pdf = session.pdf, let pdfPage = pdf.page(at: n.page) else { return nil }
        let mb = pdfPage.bounds(for: PageBitmap.effectiveBox(pdfPage))
        return PageGeometry.pageSpacePoint(normX: n.nx, normY: n.ny, box: mb, rotation: pdfPage.rotation,
                                           align: session.pageAlign(n.page))
    }

    /// 该页可用的 OCR 行文本层（已剔除水印，下标与 `ocrGroups` 对齐）。
    func ocrRuns(page: Int) -> [TextRun]? { session.ocrVisibleRuns(page: page) }

    func setSelection(_ sel: PDFSelection?) {
        guard let pdf = session.pdf, let sel, sel.string?.isEmpty == false else {
            if selection != nil { selection = nil }
            return
        }
        let align = session.scanAlign
        selection = TextSelection(rects: PageGeometry.normalizedLineRects(of: sel, in: pdf, align: { align?.page($0) }),
                                  text: sel.string ?? "")
    }

    // MARK: 流式选择

    func flowSelect(anchor a: (page: Int, nx: CGFloat, ny: CGFloat), focusDoc p: CGPoint) {
        guard let f = pageNorm(atDoc: p) else { return }
        if ocrRuns(page: a.page) != nil {
            setOCRSelection(anchor: a, focus: f)
        } else if let pdf = session.pdf, let pa = pdf.page(at: a.page), let pf = pdf.page(at: f.page),
                  let ptA = pageSpacePoint(a), let ptF = pageSpacePoint(f) {
            setSelection(pdf.selection(from: pa, at: ptA, to: pf, at: ptF))
        }
    }

    func setOCRSelection(anchor a: (page: Int, nx: CGFloat, ny: CGFloat), focus f: (page: Int, nx: CGFloat, ny: CGFloat)) {
        guard let ai = ocrLineHit(page: a.page, nx: a.nx, ny: a.ny),
              let fi = ocrLineHit(page: f.page, nx: f.nx, ny: f.ny) else { return }
        selection = a.page == f.page
            ? ocrGroupSelection(page: a.page, ai: ai, fi: fi, ax: a.nx, fx: f.nx)
            : ocrLinearSelection(a: (a.page, ai, a.nx), f: (f.page, fi, f.nx))
    }

    /// 同页 OCR 选区（分组感知）：纵向带内、锚点所在分组的行；首末行字符级裁剪；单行横拖走线性切片。
    func ocrGroupSelection(page: Int, ai: Int, fi: Int, ax: CGFloat, fx: CGFloat) -> TextSelection? {
        guard let runs = ocrRuns(page: page), runs.indices.contains(ai), runs.indices.contains(fi) else { return nil }
        let a = runs[ai].rect, f = runs[fi].rect
        let bandMin = min(a.minY, f.minY), bandMax = max(a.maxY, f.maxY)
        if bandMax - bandMin <= 1.8 * max(a.height, f.height) {
            return ocrLinearSelection(a: (page, ai, ax), f: (page, fi, fx))
        }
        let groups = session.ocrGroups(page: page)
        let ga = groups.indices.contains(ai) ? groups[ai] : -1
        var picked: [Int] = []
        for (i, r) in runs.enumerated() {
            guard groups.indices.contains(i), groups[i] == ga else { continue }
            if r.rect.midY >= bandMin, r.rect.midY <= bandMax { picked.append(i) }
        }
        if picked.isEmpty { picked = [ai] }
        picked.sort {
            let r0 = runs[$0].rect, r1 = runs[$1].rect
            return r0.midY != r1.midY ? r0.midY < r1.midY : r0.minX < r1.minX
        }
        let topIsAnchor = runs[ai].rect.midY <= runs[fi].rect.midY
        let (topIdx, topX) = topIsAnchor ? (ai, ax) : (fi, fx)
        let (botIdx, botX) = topIsAnchor ? (fi, fx) : (ai, ax)
        var items = picked.map { (idx: $0, run: runs[$0]) }
        if let i = items.firstIndex(where: { $0.idx == topIdx }) {
            let off = OCRTextSelect.charOffset(in: items[i].run, atNX: topX)
            if let c = OCRTextSelect.clip(run: items[i].run, from: off, to: items[i].run.text.count) { items[i].run = c }
            else { items.remove(at: i) }
        }
        if botIdx != topIdx, let i = items.lastIndex(where: { $0.idx == botIdx }) {
            let off = OCRTextSelect.charOffset(in: items[i].run, atNX: botX)
            if let c = OCRTextSelect.clip(run: items[i].run, from: 0, to: off) { items[i].run = c }
            else { items.remove(at: i) }
        }
        let text = items.map { $0.run.text }.joined(separator: "\n")
        return text.isEmpty ? nil : TextSelection(rects: [page: items.map { $0.run.rect }], text: text)
    }

    /// 线性切片选区（单行横拖 / 跨页）：阅读顺序切片，首行裁起点左侧、末行裁终点右侧。
    func ocrLinearSelection(a: (page: Int, idx: Int, nx: CGFloat), f: (page: Int, idx: Int, nx: CGFloat)) -> TextSelection? {
        if a.page == f.page, a.idx == f.idx {
            guard let runs = ocrRuns(page: a.page), runs.indices.contains(a.idx) else { return nil }
            let lo = OCRTextSelect.charOffset(in: runs[a.idx], atNX: Double(min(a.nx, f.nx)))
            let hi = OCRTextSelect.charOffset(in: runs[a.idx], atNX: Double(max(a.nx, f.nx)))
            guard let sub = OCRTextSelect.clip(run: runs[a.idx], from: lo, to: hi) else { return nil }
            return TextSelection(rects: [a.page: [sub.rect]], text: sub.text)
        }
        let aFirst = a.page < f.page || (a.page == f.page && a.idx <= f.idx)
        let (sp, si, sx) = aFirst ? a : f
        let (ep, ei, ex) = aFirst ? f : a
        var rects: [Int: [CGRect]] = [:]
        var parts: [String] = []
        for p in sp...ep {
            guard let runs = ocrRuns(page: p) else { continue }
            let lo = p == sp ? si : 0
            let hi = p == ep ? ei : runs.count - 1
            guard lo <= hi, lo >= 0, hi < runs.count else { continue }
            var slice = Array(runs[lo...hi])
            if p == sp {
                let off = OCRTextSelect.charOffset(in: slice[0], atNX: Double(sx))
                if let c = OCRTextSelect.clip(run: slice[0], from: off, to: slice[0].text.count) { slice[0] = c }
                else { slice.removeFirst() }
            }
            if p == ep, !slice.isEmpty {
                let li = slice.count - 1
                let off = OCRTextSelect.charOffset(in: slice[li], atNX: Double(ex))
                if let c = OCRTextSelect.clip(run: slice[li], from: 0, to: off) { slice[li] = c }
                else { slice.removeLast() }
            }
            guard !slice.isEmpty else { continue }
            rects[p] = slice.map(\.rect)
            parts.append(slice.map(\.text).joined(separator: "\n"))
        }
        let text = parts.joined(separator: "\n")
        return text.isEmpty ? nil : TextSelection(rects: rects, text: text)
    }

    /// OCR 行命中：先比行（y）、同高度内再比列（x）。
    func ocrLineHit(page: Int, nx: CGFloat, ny: CGFloat) -> Int? {
        guard let runs = ocrRuns(page: page) else { return nil }
        var best: Int?
        var bestD = CGFloat.greatestFiniteMagnitude
        for (i, r) in runs.enumerated() {
            let dy = abs((r.y + r.h / 2) - ny)
            let dx = (nx >= r.x && nx <= r.x + r.w) ? 0 : min(abs(nx - r.x), abs(nx - (r.x + r.w)))
            let d = dy * 1000 + dx
            if d < bestD { bestD = d; best = i }
        }
        return best
    }

    // MARK: 双击 / 全选

    func selectWord(atDoc p: CGPoint) {
        guard let n = pageNorm(atDoc: p) else { return }
        if let runs = ocrRuns(page: n.page), let i = ocrLineHit(page: n.page, nx: n.nx, ny: n.ny) {
            let r = runs[i]
            selection = r.text.isEmpty ? nil : TextSelection(rects: [n.page: [r.rect]], text: r.text)
        } else if let pdf = session.pdf, let page = pdf.page(at: n.page), let pt = pageSpacePoint(n) {
            setSelection(page.selectionForWord(at: pt))
        }
    }

    func selectAllText() {
        guard let pdf = session.pdf, pdf.pageCount > 0 else { return }
        let page = min(max(session.currentPageIndex, 0), pdf.pageCount - 1)
        if let runs = ocrRuns(page: page) {
            let text = runs.map(\.text).joined(separator: "\n")
            selection = text.isEmpty ? nil : TextSelection(rects: [page: runs.map(\.rect)], text: text)
        } else if let pdfPage = pdf.page(at: page) {
            setSelection(pdfPage.selection(for: pdfPage.bounds(for: PageBitmap.effectiveBox(pdfPage))))
        }
    }

    func copySelectionToPasteboard() {
        guard let text = selection?.text, !text.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    // MARK: 高亮命中

    /// 文字高亮命中（文档坐标）→ 命中的高亮与被点中的那一行。逐行框判定，上下各放宽 2 个屏幕点；
    /// 重叠取最后铺的那条（画在最上面）。
    func highlightHit(atDoc p: CGPoint) -> (highlight: Highlight, rect: CGRect)? {
        guard let n = pageNorm(atDoc: p) else { return nil }
        let f = pageFrame(n.page)
        guard f.width > 0, f.height > 0 else { return nil }
        let tx = 2 / (f.width * zoom), ty = 2 / (f.height * zoom)
        let q = CGPoint(x: n.nx, y: n.ny)
        for h in session.highlights.reversed() where h.page == n.page {
            if let r = h.rects.first(where: { $0.insetBy(dx: -tx, dy: -ty).contains(q) }) { return (h, r) }
        }
        return nil
    }

    // MARK: ⌘+拖框选文字（合并 / 反选）

    func applyBoxDrag(start: CGPoint, current: CGPoint) {
        guard let layout = pageLayout, fitBasis > 0 else { return }
        let minX = min(start.x, current.x), maxX = max(start.x, current.x)
        let minY = min(start.y, current.y), maxY = max(start.y, current.y)
        guard maxX > minX, maxY > minY else { return }
        let merge = UserDefaults.standard.object(forKey: "boxSelectOverlapMerge") as? Bool ?? true
        var pages = boxSelectStrokeBase
        for page in layout.pageRange(fromDocY: minY / ds, toDocY: maxY / ds) {
            let f = pageFrame(page)
            guard f.height > 0 else { continue }
            let nx0 = min(max((minX - f.minX) / f.width, 0), 1), nx1 = min(max((maxX - f.minX) / f.width, 0), 1)
            let ny0 = min(max((minY - f.minY) / f.height, 0), 1), ny1 = min(max((maxY - f.minY) / f.height, 0), 1)
            guard nx1 > nx0, ny1 > ny0 else { continue }
            let hits = pageBoxHits(page: page, box: CGRect(x: nx0, y: ny0, width: nx1 - nx0, height: ny1 - ny0))
            let existing = boxSelectStrokeBase[page] ?? []
            let kept = merge ? existing : existing.filter { e in !hits.contains { $0.rect.intersects(e.rect) } }
            let added = hits.filter { h in !existing.contains { $0.rect.intersects(h.rect) } }
            let merged = kept + added
            pages[page] = merged.isEmpty ? nil : merged
        }
        boxSelectPages = pages
        selection = composeBoxSelection()
    }

    func composeBoxSelection() -> TextSelection? {
        var rects: [Int: [CGRect]] = [:]
        var texts: [String] = []
        for page in boxSelectPages.keys.sorted() {
            guard let items = boxSelectPages[page], !items.isEmpty else { continue }
            rects[page] = items.map(\.rect)
            texts.append(items.map(\.text).joined(separator: "\n"))
        }
        guard !rects.isEmpty else { return nil }
        return TextSelection(rects: rects, text: texts.joined(separator: "\n"))
    }

    func decomposeIntoBoxSelectItems(_ sel: TextSelection) -> [Int: [BoxSelectItem]] {
        var result: [Int: [BoxSelectItem]] = [:]
        for (page, rects) in sel.rects {
            var items: [BoxSelectItem] = []
            for r in rects { items.append(contentsOf: pageBoxHits(page: page, box: r)) }
            if !items.isEmpty { result[page] = items }
        }
        return result
    }

    /// 单页内与 `box`（页内归一化）相交的可选中单位：OCR 页按行裁字符，原生页 `selection(for:)` 按行拆。
    func pageBoxHits(page: Int, box: CGRect) -> [BoxSelectItem] {
        if let runs = ocrRuns(page: page) {
            var items: [BoxSelectItem] = []
            for r in runs where r.rect.intersects(box) {
                let loX = max(box.minX, r.rect.minX), hiX = min(box.maxX, r.rect.maxX)
                guard hiX > loX else { continue }
                let lo = OCRTextSelect.charOffset(in: r, atNX: Double(loX))
                let hi = OCRTextSelect.charOffset(in: r, atNX: Double(hiX))
                if let c = OCRTextSelect.clip(run: r, from: lo, to: hi) { items.append(BoxSelectItem(rect: c.rect, text: c.text)) }
            }
            return items
        }
        guard let pdf = session.pdf, let pdfPage = pdf.page(at: page) else { return [] }
        let mb = pdfPage.bounds(for: PageBitmap.effectiveBox(pdfPage))
        guard mb.width > 0, mb.height > 0 else { return [] }
        let align = session.pageAlign(page)
        let corners: [(CGFloat, CGFloat)] = [(box.minX, box.minY), (box.maxX, box.minY), (box.minX, box.maxY), (box.maxX, box.maxY)]
        let pts = corners.map { PageGeometry.pageSpacePoint(normX: $0.0, normY: $0.1, box: mb, rotation: pdfPage.rotation, align: align) }
        let xs = pts.map(\.x), ys = pts.map(\.y)
        let pdfRect = CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
        guard let sel = pdfPage.selection(for: pdfRect), sel.string?.isEmpty == false else { return [] }
        var items: [BoxSelectItem] = []
        for line in sel.selectionsByLine() where line.pages.contains(pdfPage) {
            let b = line.bounds(for: pdfPage)
            guard b.width > 0, b.height > 0 else { continue }
            items.append(BoxSelectItem(rect: PageGeometry.normalizedRect(b, box: mb, rotation: pdfPage.rotation, align: align),
                                       text: line.string ?? ""))
        }
        return items
    }
}
