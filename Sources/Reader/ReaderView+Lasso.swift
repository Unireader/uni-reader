import AppKit
import QuartzCore

/// 笔迹框选（`pointerTool == .lasso`，仅页内；逻辑同 SwiftUI 版 `ReaderSurface+Lasso` / `+InkClip`）：
///  · 拖空白 = 自由路径框选（松手命中同页笔迹 + 文字注解）；
///  · 拖选中框内 = 移动（拖动中只动预览，松手一次性刚性平移，页内夹取）；
///  · 拖手柄 = 缩放（角 = 等比、⇧ 临时自由两轴；边中点 = 单轴；anchor = 对侧手柄）；
///  · 点空白 / Esc / 切走工具 = 放弃；⌘X / ⌘C / ⌘V / ⌫。
/// 选中框、手柄、光晕在覆盖层里按**屏幕点**画（与 SwiftUI 版显示坐标同一口径），路径点存文档坐标（不怕滚动）。
extension ReaderView {

    // MARK: 几何

    /// 选中集显示框（屏幕点）：内容包围盒外扩 6pt，最小 16pt（零尺寸点注解 / 极薄笔迹也抓得住）。
    func lassoDisplayBox(_ sel: LassoSelection) -> CGRect? {
        guard let layout = pageLayout, layout.heights.indices.contains(sel.page), fitBasis > 0 else { return nil }
        let hl = displayRect(page: sel.page, norm: sel.bounds)
        let box = hl.insetBy(dx: -6, dy: -6)
        let w = max(box.width, 16), h = max(box.height, 16)
        return CGRect(x: box.midX - w / 2, y: box.midY - h / 2, width: w, height: h)
    }

    func lassoHandleHit(at p: CGPoint, box: CGRect) -> LassoHandle? {
        LassoHandle.allCases.first { h in
            let q = h.point(in: box)
            return hypot(p.x - q.x, p.y - q.y) <= 10
        }
    }

    /// 点经预览变换后的位置（缩放 = 绕对侧手柄按轴缩放；否则平移）。
    func lassoGhostPoint(_ p: CGPoint, in box: CGRect) -> CGPoint {
        if let gs = lassoGhostScale {
            let a = gs.handle.opposite.point(in: box)
            return CGPoint(x: a.x + (p.x - a.x) * gs.sx, y: a.y + (p.y - a.y) * gs.sy)
        }
        return CGPoint(x: p.x + lassoGhostOffset.width, y: p.y + lassoGhostOffset.height)
    }

    /// 框选编辑（移动 / 缩放）的合法 x 区间：画板模式取硬上限（软边界提交后会自己长上来）。
    var lassoEditXRange: ClosedRange<Double> {
        CanvasMargin.xRange(margin: session.canvasMode ? CanvasMargin.limit : 0)
    }

    func lassoSelectionBounds(_ sel: LassoSelection, strokes: Bool = true, notes: Bool = true) -> CGRect {
        var box = CGRect.null
        if strokes {
            for st in session.strokes where st.page == sel.page && sel.strokeIDs.contains(st.id) {
                box = box.union(InkEdit.bounds([st]))
            }
        }
        if notes {
            for n in session.textNotes where n.page == sel.page && sel.noteIDs.contains(n.id) { box = box.union(n.anchor) }
        }
        return box
    }

    // MARK: 拖动

    func lassoDragged(mode: LassoDragMode, doc p: CGPoint, display d: CGPoint, startDisplay: CGPoint, shift: Bool) {
        switch mode {
        case .select:
            // 自由路径：≥3 个屏幕点才记一个（更密对多边形命中无益）
            if let last = lassoPath?.last {
                let q = displayPoint(ofDoc: last)
                if hypot(d.x - q.x, d.y - q.y) >= 3 { lassoPath?.append(p) }
            }
        case .move:
            lassoGhostOffset = CGSize(width: d.x - startDisplay.x, height: d.y - startDisplay.y)
        case .scale(let handle):
            updateLassoScaleGhost(handle: handle, current: d, shift: shift)
        }
        updateLassoOverlay()
    }

    private func updateLassoScaleGhost(handle: LassoHandle, current cur: CGPoint, shift: Bool) {
        guard let sel = lassoSelection, let box = lassoDisplayBox(sel) else { return }
        let anchor = handle.opposite.point(in: box), start = handle.point(in: box)
        let denomX = start.x - anchor.x, denomY = start.y - anchor.y
        var sx: CGFloat = 1, sy: CGFloat = 1
        switch handle {
        case .t, .b:
            guard abs(denomY) > 1 else { return }
            sy = (cur.y - anchor.y) / denomY
        case .l, .r:
            guard abs(denomX) > 1 else { return }
            sx = (cur.x - anchor.x) / denomX
        case .tl, .tr, .bl, .br:
            guard abs(denomX) > 1, abs(denomY) > 1 else { return }
            sx = (cur.x - anchor.x) / denomX
            sy = (cur.y - anchor.y) / denomY
            if !shift {   // 角默认等比：取变化幅度更大的一轴
                let s = abs(sx - 1) >= abs(sy - 1) ? sx : sy
                sx = s; sy = s
            }
        }
        func cl(_ s: CGFloat) -> CGFloat { min(20, max(0.05, s)) }
        lassoGhostScale = (cl(sx), cl(sy), handle)
    }

    func finishLassoDrag(mode: LassoDragMode) {
        let path = lassoPath
        lassoPath = nil
        let ghost = lassoGhostOffset
        lassoGhostOffset = .zero
        let gscale = lassoGhostScale
        lassoGhostScale = nil
        switch mode {
        case .select: if let path { finishLassoSelect(path: path) }
        case .move: commitLassoMove(translation: ghost)
        case .scale: if let gscale { commitLassoScale(scale: gscale) }
        }
        updateLassoOverlay()
    }

    // MARK: 命中

    /// 自由路径 → 不规则多边形（页内归一化），锚定起点所在页；跨页的点贴到该页上下边。
    private func finishLassoSelect(path: [CGPoint]) {
        guard path.count >= 3, let first = path.first,
              let anchorPage = pageNorm(atDoc: first, xRange: inkXRange)?.page else { return }
        var poly: [SIMD2<Double>] = []
        for p in path {
            guard let n = pageNorm(atDoc: p, xRange: inkXRange) else { continue }
            let ny = n.page == anchorPage ? n.ny : (n.page > anchorPage ? 1 : 0)
            poly.append(SIMD2(Double(n.nx), Double(ny)))
        }
        guard poly.count >= 3 else { return }
        var strokeIDs = Set<UUID>(), noteIDs = Set<UUID>()
        var bbox = CGRect.null
        let vis = session.visibleLayerIDs
        for st in session.strokes where st.page == anchorPage && vis.contains(st.layerId) {
            if st.points.contains(where: { InkEdit.pointInPolygon(SIMD2($0.dx, $0.dy), polygon: poly) }) {
                strokeIDs.insert(st.id)
                bbox = bbox.union(InkEdit.bounds([st]))
            }
        }
        for n in session.textNotes where n.page == anchorPage {
            if InkEdit.pointInPolygon(SIMD2(Double(n.anchor.midX), Double(n.anchor.midY)), polygon: poly) {
                noteIDs.insert(n.id)
                bbox = bbox.union(n.anchor)
            }
        }
        guard !strokeIDs.isEmpty || !noteIDs.isEmpty else { return }
        lassoSelection = LassoSelection(page: anchorPage, strokeIDs: strokeIDs, noteIDs: noteIDs, bounds: bbox)
    }

    // MARK: 提交

    private func commitLassoMove(translation t: CGSize) {
        guard let sel = lassoSelection, fitBasis > 0 else { return }
        let f = pageFrame(sel.page)
        let xr = lassoEditXRange
        let (dx, dy) = InkEdit.fitTranslation(
            dx: Double(t.width / (f.width * zoom)), dy: Double(t.height / (f.height * zoom)),
            inkBounds: lassoSelectionBounds(sel, notes: false), xRange: xr,
            noteBounds: lassoSelectionBounds(sel, strokes: false))
        guard dx != 0 || dy != 0 else { return }
        var changed = false
        session.inkEdit("Move", kind: .move) {
            for i in session.strokes.indices
            where session.strokes[i].page == sel.page && sel.strokeIDs.contains(session.strokes[i].id) {
                session.strokes[i] = InkEdit.translated(session.strokes[i], dx: dx, dy: dy, xRange: xr)
                changed = true
            }
            for i in session.textNotes.indices
            where session.textNotes[i].page == sel.page && sel.noteIDs.contains(session.textNotes[i].id) {
                session.textNotes[i] = InkEdit.translated(session.textNotes[i], dx: dx, dy: dy)
                changed = true
            }
        }
        guard changed else { lassoSelection = nil; return }
        var s = sel
        let box = lassoSelectionBounds(s)
        s.bounds = box.isNull ? InkEdit.translatedRect(sel.bounds, dx: dx, dy: dy) : box
        lassoSelection = s
        refreshCanvasMargin()
        if session.id == app.padSession?.id { app.broadcastStrokes(); app.broadcastNotes() }
    }

    private func commitLassoScale(scale gs: (sx: CGFloat, sy: CGFloat, handle: LassoHandle)) {
        guard let sel = lassoSelection, let box = lassoDisplayBox(sel) else { return }
        let sx = Double(gs.sx), sy = Double(gs.sy)
        guard sx != 1 || sy != 1 else { return }
        // anchor（对侧手柄，屏幕点）→ 页内归一化（按轴线性缩放，两坐标系换算下 sx/sy 不变）
        let ac = docPoint(ofDisplay: gs.handle.opposite.point(in: box))
        let f = pageFrame(sel.page)
        let a = SIMD2(Double((ac.x - f.minX) / f.width), Double((ac.y - f.minY) / f.height))
        var changed = false
        session.inkEdit("Resize", kind: .scale) {
            for i in session.strokes.indices
            where session.strokes[i].page == sel.page && sel.strokeIDs.contains(session.strokes[i].id) {
                session.strokes[i] = InkEdit.scaled(session.strokes[i], anchor: a, sx: sx, sy: sy, xRange: lassoEditXRange)
                changed = true
            }
            for i in session.textNotes.indices
            where session.textNotes[i].page == sel.page && sel.noteIDs.contains(session.textNotes[i].id) {
                session.textNotes[i] = InkEdit.scaled(session.textNotes[i], anchor: a, sx: sx, sy: sy)
                changed = true
            }
        }
        guard changed else { lassoSelection = nil; return }
        var s = sel
        let nb = lassoSelectionBounds(s)
        s.bounds = nb.isNull ? InkEdit.scaledRect(sel.bounds, anchor: a, sx: sx, sy: sy) : nb
        lassoSelection = s
        refreshCanvasMargin()
        if session.id == app.padSession?.id { app.broadcastStrokes(); app.broadcastNotes() }
    }

    func clearLassoSelection() {
        if lassoSelection != nil { lassoSelection = nil }
        lassoPath = nil
        lassoGhostOffset = .zero
        lassoGhostScale = nil
        updateLassoOverlay()
    }

    // MARK: 覆盖层

    /// 进行中的自由路径（虚线闭合）+ 选中框 / 手柄 / 光晕（随移动 / 缩放预览变换）。
    func updateLassoOverlay() {
        guard didSetup else { return }
        if let path = lassoPath, path.count >= 2 {
            let p = CGMutablePath()
            p.addLines(between: path.map { displayPoint(ofDoc: $0) })
            p.closeSubpath()
            ReaderOverlayView.set(overlay.lassoPath, p)
        } else {
            ReaderOverlayView.set(overlay.lassoPath, nil)
        }
        guard let sel = lassoSelection, let box = lassoDisplayBox(sel) else {
            for l in [overlay.lassoBox, overlay.lassoHandles, overlay.lassoHalo] { ReaderOverlayView.set(l, nil) }
            return
        }
        let pts = LassoHandle.allCases.map { lassoGhostPoint($0.point(in: box), in: box) }
        let lo = pts.reduce(pts[0]) { CGPoint(x: min($0.x, $1.x), y: min($0.y, $1.y)) }
        let hi = pts.reduce(pts[0]) { CGPoint(x: max($0.x, $1.x), y: max($0.y, $1.y)) }
        ReaderOverlayView.set(overlay.lassoBox, CGPath(roundedRect: CGRect(x: lo.x, y: lo.y, width: hi.x - lo.x, height: hi.y - lo.y),
                                                       cornerWidth: 4, cornerHeight: 4, transform: nil))
        let handles = CGMutablePath()
        for p in pts { handles.addEllipse(in: CGRect(x: p.x - 4.5, y: p.y - 4.5, width: 9, height: 9)) }
        ReaderOverlayView.set(overlay.lassoHandles, handles)
        // 光晕：每笔描边轮廓（笔宽随缩放 + 5pt 余量）合成一块填充——重叠处不叠深
        let pr = displayPageRect(sel.page)
        let halo = CGMutablePath()
        for st in session.strokes where st.page == sel.page && sel.strokeIDs.contains(st.id) {
            let mapped = st.points.map {
                lassoGhostPoint(CGPoint(x: pr.minX + CGFloat($0.x) * pr.width, y: pr.minY + CGFloat($0.y) * pr.height), in: box)
            }
            if mapped.count == 1 {
                let r = CGFloat(st.type.strokeWidth(pressure: st.points[0].dz, base: st.width)) * pr.width / max(1, fitBasis) / 2 + 2.5
                halo.addEllipse(in: CGRect(x: mapped[0].x - r, y: mapped[0].y - r, width: r * 2, height: r * 2))
            } else {
                let line = CGMutablePath()
                line.addLines(between: mapped)
                halo.addPath(line.copy(strokingWithWidth: CGFloat(st.width) * pr.width / max(1, fitBasis) + 5,
                                       lineCap: .round, lineJoin: .round, miterLimit: 10))
            }
        }
        overlay.lassoHalo.fillColor = NSColor.controlAccentColor.withAlphaComponent(0.35).cgColor
        overlay.lassoHalo.strokeColor = nil
        ReaderOverlayView.set(overlay.lassoHalo, halo.isEmpty ? nil : halo)
    }

    // MARK: 撤销 / 剪贴板（Edit 菜单与右键菜单共用）

    func performUndo(redo: Bool) {
        clearLassoSelection()   // 选中集指向的 id 可能整批被撤没了
        app.undoInk(in: session, redo: redo)
    }

    @discardableResult
    func copyLassoSelection() -> Bool {
        guard session.openPadID == nil, let sel = lassoSelection else { return false }
        let strokes = session.strokes.filter { $0.page == sel.page && sel.strokeIDs.contains($0.id) }
        let notes = session.textNotes.filter { $0.page == sel.page && sel.noteIDs.contains($0.id) }
        guard !strokes.isEmpty || !notes.isEmpty else { return false }
        InkClipboard.write(strokes: strokes, notes: notes, space: .page, aspect: pageAspect(page: sel.page))
        return true
    }

    @discardableResult
    func cutLassoSelection() -> Bool {
        guard copyLassoSelection() else { return false }
        deleteLassoSelection()
        return true
    }

    func deleteLassoSelection() {
        guard session.openPadID == nil, let sel = lassoSelection else { return }
        session.inkEdit("Delete", kind: .delete) {
            session.strokes.removeAll { $0.page == sel.page && sel.strokeIDs.contains($0.id) }
            session.textNotes.removeAll { $0.page == sel.page && sel.noteIDs.contains($0.id) }
        }
        clearLassoSelection()
        refreshCanvasMargin()
        if session.id == app.padSession?.id { app.broadcastStrokes(); app.broadcastNotes() }
    }

    /// 粘贴笔迹：落在指针所在页（以指针为中心）；指针不在页上就落当前页原位错开一点。
    /// 粘完即选中并切到框选工具，接着拖就能摆位置。摆放数学在 `InkPaste.place`（与平板那条路径共用）。
    func pasteInk() {
        guard session.openPadID == nil, session.pdf != nil, let clip = InkClipboard.read() else { return }
        var page = session.currentPageIndex
        var center: CGPoint?
        if let p = cursorDoc, let n = pageNorm(atDoc: p, xRange: lassoEditXRange) {
            page = n.page
            center = CGPoint(x: n.nx, y: n.ny)
        }
        let out = InkPaste.place(
            strokes: clip.strokes, notes: clip.notes, space: clip.space, sourceAspect: clip.aspect,
            page: page, center: center, targetAspect: pageAspect(page: page), xRange: lassoEditXRange,
            layers: Set(session.inkLayers.map(\.id)), fallbackLayer: session.activeLayerID ?? InkLayer.defaultID,
            types: Set(session.noteTypes.map(\.id)))
        guard !out.strokes.isEmpty || !out.notes.isEmpty else { return }
        session.inkEdit("Paste", kind: .paste) {
            session.strokes.append(contentsOf: out.strokes)
            session.textNotes.append(contentsOf: out.notes)
        }
        app.pointerTool = .lasso
        var sel = LassoSelection(page: page, strokeIDs: Set(out.strokes.map(\.id)), noteIDs: Set(out.notes.map(\.id)),
                                 bounds: InkEdit.bounds(out.strokes))
        let real = lassoSelectionBounds(sel)
        if !real.isNull { sel.bounds = real }
        lassoSelection = sel
        refreshCanvasMargin()
        if session.id == app.padSession?.id { app.broadcastStrokes(); app.broadcastNotes() }
    }
}
