import SwiftUI
import PDFKit
import AppKit   // 仅 NSEvent 修饰键读取（事件管道）；阅读区无 AppKit 视图（红线）

/// 一个可选中的最小单位：OCR 一行裁剪出的字符片段，或 PDF 原生页 `selectionsByLine()` 的一行。
/// rect+text 成对存放，是框选能做「再框一遍就取消」的关键——旧版只留 `rects`+拼好的整段 `text`，
/// 松开局部选区时没法知道该从整段文本里删哪一截；按行/片段配对存好，删哪项就精确少哪项文本。
struct BoxSelectItem: Equatable {
    var rect: CGRect
    var text: String
}

/// 框选文字（起手时按住 ⌘ 触发，见 `ReaderSurface+Selection.dragSelectGesture`）：拖出矩形，
/// **框到哪些字就选哪些字**——原生页用 PDFKit 自带的 `PDFPage.selection(for:)`（按矩形取字符级
/// 选区），天然比「起点→终点」的流式选择（`ReaderSurface+Selection.flowSelectChanged`，默认不按
/// ⌘ 时走这条）简单，不用再管阅读顺序/跨栏排序；OCR 页按矩形跟每一行的横向重叠区间裁字符（复用
/// `OCRTextSelect.charOffset`/`clip`，与 `ocrGroupSelection` 裁首末行同一套字符定位），同样是
/// 字符级，只是不用管分组/阅读顺序——「更简单」的取舍落在算法（不用再判断分组归属），不是落在
/// 选择粒度（用户 2026-09-18 纠正）。
///
/// **⌘+拖永远是叠加**（用户 2026-09-18 二次修正——「附加才符合逻辑」）；再框一遍已选中的部分是
/// **合并**（保留、只新增没框过的部分）还是**反选**（重叠部分互相取消，同 Finder 图标视图 ⌘+拖
/// 橡皮筋的惯例）由设置 → 阅读 →「框选重复区域」决定（`boxSelectOverlapMerge`，默认合并，用户四改
/// 拍板：默认求稳，反选留给想要的人开）。**这一判定对任何来源的既有选区都生效**（用户三次反馈：先
/// 流式选择、再框选，流式选择选出来的那段没被框选处理——第一版留了个「floor」豁免既有选区不参与
/// 判定，这里去掉，统一成一套）：
///  · `scratch.boxSelectPages`——框选内部的逐页命中（`[BoxSelectItem]`，rect+text 成对，因此知道
///    「删哪一项就精确少哪一段文本」），跨多次拖拽持续累加，是合并/反选真正作用的对象。
///  · 每次新拖拽起手都拿 `composeBoxSelection()` 现算一遍跟当前 `selection` 对比：一致就说明这段
///    时间没人插手，继续在 `boxSelectPages` 上累加；不一致（比如中途做了一次流式选择，或点别处清了
///    选区）就把当前 `selection`（不管它从哪来的）整个 `decompose` 成 `boxSelectPages`——逐条既有
///    矩形反查回 `pageBoxHits`（拿它自己当 box 再查一遍，复用同一套字符级裁剪，流式选择裁过的半行
///    一样能精确复原文字），从此这份选区里的每一项都能被框选统一处理，不用去每个清选区的地方另外
///    通知框选，自己在起手那一刻自愈。
///  · 拖拽进行中，每一帧都从**本次拖拽起手时冻结的快照** `scratch.boxSelectStrokeBase` 重新算
///    合并/反选（而不是在上一帧结果上累加），跟 Finder 的橡皮筋一样——矩形拖小了会把预览里的取消/
///    新增都退回去，不会因为拖拽路径中途扫过又缩回去就留下脏状态。
extension ReaderSurface {

    // MARK: 手势（挂在 `dragSelectGesture`，⌘ 起手的分支，见 `ReaderSurface+Selection`）

    func boxSelectChanged(_ v: DragGesture.Value) {
        if boxSelectDrag == nil {
            // 起点在图钉 / 笔记卡片上：让位，boxSelectDrag 保持 nil → 整段框选不启动
            if draggablePinHit(v.startLocation) != nil || cardHit(v.startLocation) != nil { return }
            if composeBoxSelection() != selection {
                scratch.boxSelectPages = selection.map(decomposeIntoBoxSelectItems) ?? [:]
            }
            scratch.boxSelectStrokeBase = scratch.boxSelectPages
            boxSelectDrag = (v.startLocation, v.startLocation)
        }
        guard var drag = boxSelectDrag else { return }
        drag.current = v.location
        boxSelectDrag = drag
        applyBoxDrag(start: drag.start, current: drag.current)
    }

    func boxSelectEnded() {
        boxSelectDrag = nil
        scratch.boxSelectStrokeBase = [:]
    }

    // MARK: toggle 合并（内容坐标算矩形 → 逐页求交 → 与本次拖拽起手快照逐项 toggle）

    /// 起点/当前点（容器 `.local` 坐标）→ 内容坐标矩形 → 逐页求交，命中项与 `scratch.boxSelectStrokeBase`
    /// 逐项 toggle（重叠则视为「再选一遍」互相抵消，不重叠则新增），写回 `scratch.boxSelectPages` 后
    /// 合成新的 `selection`。矩形退化成一条线时不动 `boxSelectPages`。
    private func applyBoxDrag(start: CGPoint, current: CGPoint) {
        guard let layout, pageW > 0 else { return }
        let ds = max(0.0001, dispScale)
        let g = scratch.geo
        let p0 = CGPoint(x: g.offsetX + start.x, y: g.offsetY + start.y)
        let p1 = CGPoint(x: g.offsetX + current.x, y: g.offsetY + current.y)
        let boxMinX = min(p0.x, p1.x), boxMaxX = max(p0.x, p1.x)
        let boxMinY = min(p0.y, p1.y), boxMaxY = max(p0.y, p1.y)
        guard boxMaxX > boxMinX, boxMaxY > boxMinY else { return }

        var pages = scratch.boxSelectStrokeBase
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
            let box = CGRect(x: nx0, y: ny0, width: nx1 - nx0, height: ny1 - ny0)
            let hits = pageBoxHits(page: page, box: box)
            let existing = scratch.boxSelectStrokeBase[page] ?? []
            // 合并：existing 原样保留，只新增没框过的部分。反选：existing 里被再框到的那些互相抵消。
            let kept = boxSelectOverlapMerge ? existing : existing.filter { e in !hits.contains { $0.rect.intersects(e.rect) } }
            let added = hits.filter { h in !existing.contains { $0.rect.intersects(h.rect) } }
            let merged = kept + added
            pages[page] = merged.isEmpty ? nil : merged
        }
        scratch.boxSelectPages = pages
        selection = composeBoxSelection()
    }

    /// `scratch.boxSelectPages` 按页号排序拼 text（保证结果稳定可比）合成最终 `TextSelection`；空则 `nil`。
    private func composeBoxSelection() -> TextSelection? {
        var rects: [Int: [CGRect]] = [:]
        var texts: [String] = []
        for page in scratch.boxSelectPages.keys.sorted() {
            guard let items = scratch.boxSelectPages[page], !items.isEmpty else { continue }
            rects[page] = items.map(\.rect)
            texts.append(items.map(\.text).joined(separator: "\n"))
        }
        guard !rects.isEmpty else { return nil }
        return TextSelection(rects: rects, text: texts.joined(separator: "\n"))
    }

    /// 把任意一份既有选区（不管是流式选择、还是框选功能出现前遗留下来的）拆成逐条 `BoxSelectItem`：
    /// 每条既有矩形拿它自己当 `box` 反查一遍 `pageBoxHits`，复用框选本来就有的字符级裁剪逻辑——流式
    /// 选择裁过的半行同样精确（拿裁过的那个窄矩形反查回去，字符边界与当初选的分毫不差）。拆完之后
    /// 这份选区里的每一项都是框选自己的账，从此能被单独 toggle 掉。
    private func decomposeIntoBoxSelectItems(_ sel: TextSelection) -> [Int: [BoxSelectItem]] {
        var result: [Int: [BoxSelectItem]] = [:]
        for (page, rects) in sel.rects {
            var items: [BoxSelectItem] = []
            for r in rects { items.append(contentsOf: pageBoxHits(page: page, box: r)) }
            if !items.isEmpty { result[page] = items }
        }
        return result
    }

    /// 单页内与 `box`（页内归一化矩形）相交的可选中单位：
    ///  · OCR 页——矩形纵向命中到的每一行，按矩形与该行的**横向重叠区间**裁字符（`OCRTextSelect.charOffset`
    ///    定位偏移、`clip` 切子行框，与 `ocrGroupSelection` 裁首末行同一套逻辑），字符级、不整行选；
    ///  · 原生页——`PDFPage.selection(for:)` 取字符级选区后 `selectionsByLine()` 按行拆，每行自己的
    ///    `.string` 与行框配对（**rotation/scan-align 是 90° 整数倍时精确**——轴对齐矩形绕 90° 倍数转完
    ///    还是轴对齐矩形；scan-align 的小角度校正会让包围盒略微外扩，边缘偶尔多选一点点字符，不是错误
    ///    只是没有逐字裁到严丝合缝）。
    private func pageBoxHits(page: Int, box: CGRect) -> [BoxSelectItem] {
        if let runs = ocrRuns(page: page) {
            var items: [BoxSelectItem] = []
            for r in runs where r.rect.intersects(box) {
                let loX = max(box.minX, r.rect.minX), hiX = min(box.maxX, r.rect.maxX)
                guard hiX > loX else { continue }
                let lo = OCRTextSelect.charOffset(in: r, atNX: Double(loX))
                let hi = OCRTextSelect.charOffset(in: r, atNX: Double(hiX))
                if let c = OCRTextSelect.clip(run: r, from: lo, to: hi) {
                    items.append(BoxSelectItem(rect: c.rect, text: c.text))
                }
            }
            return items
        }
        guard let pdf = session.pdf, let pdfPage = pdf.page(at: page) else { return [] }
        let mb = pdfPage.bounds(for: PageBitmap.effectiveBox(pdfPage))
        guard mb.width > 0, mb.height > 0 else { return [] }
        let align = session.pageAlign(page)
        let corners: [(CGFloat, CGFloat)] = [(box.minX, box.minY), (box.maxX, box.minY),
                                             (box.minX, box.maxY), (box.maxX, box.maxY)]
        let pts = corners.map {
            PageGeometry.pageSpacePoint(normX: $0.0, normY: $0.1, box: mb, rotation: pdfPage.rotation, align: align)
        }
        let xs = pts.map(\.x), ys = pts.map(\.y)
        let pdfRect = CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
        guard let sel = pdfPage.selection(for: pdfRect), sel.string?.isEmpty == false else { return [] }
        var items: [BoxSelectItem] = []
        for line in sel.selectionsByLine() where line.pages.contains(pdfPage) {
            let b = line.bounds(for: pdfPage)
            guard b.width > 0, b.height > 0 else { continue }
            let rect = PageGeometry.normalizedRect(b, box: mb, rotation: pdfPage.rotation, align: align)
            items.append(BoxSelectItem(rect: rect, text: line.string ?? ""))
        }
        return items
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
