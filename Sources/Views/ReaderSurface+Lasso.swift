import SwiftUI
import PDFKit
import AppKit   // 仅 NSEvent 监视器（事件管道）；阅读区无 AppKit 视图（红线）

/// 框选移动（pointerTool == .lasso，仅页内）：
///  · 拖空白 → 画虚线矩形框选（容器/视口坐标 overlay）；松手命中同页笔迹（任一点在框内）
///    + 同页文字注解（anchor 与框相交），选中集存瞬态 `lassoSelection`。
///  · 拖选中高亮框内 → 移动：拖动中只动 ghost 预览框（瞬态 `lassoGhostOffset`，不改数据）；
///    松手一次性提交（笔迹 `InkEdit.translated` / 注解 anchor+rects 同平移，页内 clamp），
///    ContentView 值快照对账自动落库，恰是 padSession 时显式广播镜像到平板。
///  · 点空白（单击）/ Esc / 切走工具 → 清除选中。
extension ReaderSurface {

    // MARK: 手势（拖空白=框选 / 拖选中框内=移动，起点一次性判定）

    /// 框选手势：仅 `pointerTool == .lasso` 生效（与拖选/本机落墨互斥门控，同挂 ScrollView 容器）。
    var lassoGesture: some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .local)
            .onChanged { v in
                guard app.pointerTool == .lasso, scratch.pinch == nil else { return }
                if scratch.lassoDragMode == nil {
                    // 起点落在选中高亮框（含 8pt 抓手余量）内 → 移动；否则重新框选
                    var mode = LassoDragMode.select
                    if let sel = lassoSelection, let hl = lassoContentRect(sel) {
                        let g = scratch.geo
                        let startContent = CGPoint(x: g.offsetX + v.startLocation.x,
                                                   y: g.offsetY + v.startLocation.y)
                        if hl.insetBy(dx: -8, dy: -8).contains(startContent) { mode = .move }
                    }
                    scratch.lassoDragMode = mode
                    if mode == .select { lassoSelection = nil }   // 起新框选即放弃旧选中
                }
                switch scratch.lassoDragMode {
                case .select:
                    lassoRect = CGRect(x: min(v.startLocation.x, v.location.x),
                                       y: min(v.startLocation.y, v.location.y),
                                       width: abs(v.location.x - v.startLocation.x),
                                       height: abs(v.location.y - v.startLocation.y))
                case .move:
                    lassoGhostOffset = v.translation   // ghost 预览：只动框，不改数据
                case nil:
                    break
                }
            }
            .onEnded { v in
                let mode = scratch.lassoDragMode
                scratch.lassoDragMode = nil
                lassoRect = nil
                let ghost = lassoGhostOffset
                lassoGhostOffset = .zero
                guard app.pointerTool == .lasso, let mode else { return }
                switch mode {
                case .select: finishLassoSelect(from: v.startLocation, to: v.location)
                case .move: commitLassoMove(translation: ghost)
                }
            }
    }

    // MARK: 框选命中（锚定起点所在页，仅页内；跨页拖拽的终点 clamp 到该页边缘）

    func finishLassoSelect(from start: CGPoint, to end: CGPoint) {
        guard let a = containerPointToPageNorm(start) else { return }
        let f = containerPointToPageNorm(end)
        // 横向页与页同 pageX/pageW，nx 通用；纵向跨页则贴 anchor 页边缘（仅页内，不跨页选）
        let fx = f?.nx ?? a.nx
        let fy: CGFloat = f.map { $0.page == a.page ? $0.ny : ($0.page > a.page ? 1 : 0) } ?? a.ny
        let r = CGRect(x: min(a.nx, fx), y: min(a.ny, fy),
                       width: abs(fx - a.nx), height: abs(fy - a.ny))
        guard r.width > 0, r.height > 0 else { return }

        var strokeIDs = Set<UUID>()
        var noteIDs = Set<UUID>()
        var bbox = CGRect.null
        for st in session.strokes where st.page == a.page {
            if st.points.contains(where: { r.contains(CGPoint(x: $0.x, y: $0.y)) }) {
                strokeIDs.insert(st.id)
                bbox = bbox.union(strokeBounds(st))
            }
        }
        for n in session.textNotes where n.page == a.page {
            // anchor 与框相交（零尺寸点注解按锚点是否落框内判）
            if r.intersects(n.anchor) || r.contains(CGPoint(x: n.anchor.midX, y: n.anchor.midY)) {
                noteIDs.insert(n.id)
                bbox = bbox.union(n.anchor)
            }
        }
        guard !strokeIDs.isEmpty || !noteIDs.isEmpty else { return }
        lassoSelection = LassoSelection(page: a.page, strokeIDs: strokeIDs, noteIDs: noteIDs, bounds: bbox)
    }

    /// 笔迹点集的页内归一化包围盒。
    func strokeBounds(_ st: InkStroke) -> CGRect {
        var lo = SIMD2<Double>(1, 1), hi = SIMD2<Double>(0, 0)
        for p in st.points {
            lo = SIMD2(min(lo.x, p.x), min(lo.y, p.y))
            hi = SIMD2(max(hi.x, p.x), max(hi.y, p.y))
        }
        return CGRect(x: lo.x, y: lo.y, width: hi.x - lo.x, height: hi.y - lo.y)
    }

    // MARK: 移动提交（松手一次性平移，页内 clamp）

    func commitLassoMove(translation t: CGSize) {
        guard let sel = lassoSelection, let layout,
              layout.heights.indices.contains(sel.page), pageW > 0 else { return }
        let pageHDisp = layout.heights[sel.page] * max(0.0001, dispScale)
        let dx = Double(t.width / pageW), dy = Double(t.height / pageHDisp)
        guard dx != 0 || dy != 0 else { return }
        var changed = false
        for i in session.strokes.indices
        where session.strokes[i].page == sel.page && sel.strokeIDs.contains(session.strokes[i].id) {
            session.strokes[i] = InkEdit.translated(session.strokes[i], dx: dx, dy: dy)
            changed = true
        }
        for i in session.textNotes.indices
        where session.textNotes[i].page == sel.page && sel.noteIDs.contains(session.textNotes[i].id) {
            session.textNotes[i] = InkEdit.translated(session.textNotes[i], dx: dx, dy: dy)
            changed = true
        }
        guard changed else { lassoSelection = nil; return }   // 选中项已被擦除/删除
        var s = sel
        s.bounds = InkEdit.translatedRect(sel.bounds, dx: dx, dy: dy)
        lassoSelection = s
        // 镜像平板：仅当本窗口恰是 padSession（同 inkEnd 语义；否则 broadcast 的是 padSession 的旧数据）
        if session.id == app.padSession?.id { app.broadcastStrokes(); app.broadcastNotes() }
    }

    func clearLassoSelection() {
        lassoSelection = nil
        lassoGhostOffset = .zero
        if scratch.lassoDragMode == .move { scratch.lassoDragMode = nil }
    }

    // MARK: 渲染（纯功能 overlay：虚线框/高亮框，非仿系统控件）

    /// 选中集包围盒（页内归一化）→ 内容坐标 rect（画进 contentBody 的 ZStack，随内容滚动/缩放）。
    func lassoContentRect(_ sel: LassoSelection) -> CGRect? {
        guard let layout, layout.heights.indices.contains(sel.page), pageW > 0 else { return nil }
        let ds = max(0.0001, dispScale)
        let pageHDisp = layout.heights[sel.page] * ds
        return CGRect(x: pageX + sel.bounds.minX * pageW,
                      y: layout.offsets[sel.page] * ds + sel.bounds.minY * pageHDisp,
                      width: sel.bounds.width * pageW,
                      height: sel.bounds.height * pageHDisp)
    }

    /// 选中项高亮框（内容坐标，置于页元胞之上）+ 移动 ghost（瞬态 offset，数据未动）。
    /// 外扩 6pt + 最小尺寸：零尺寸点注解/极薄笔迹也有可见可抓的框。
    @ViewBuilder var lassoHighlight: some View {
        if let sel = lassoSelection, let hl = lassoContentRect(sel) {
            let box = hl.insetBy(dx: -6, dy: -6)
            let w = max(box.width, 16), h = max(box.height, 16)
            RoundedRectangle(cornerRadius: 4)
                .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
                .frame(width: w, height: h)
                .offset(x: box.midX - w / 2 + lassoGhostOffset.width,
                        y: box.midY - h / 2 + lassoGhostOffset.height)
                .allowsHitTesting(false)
        }
    }

    /// 进行中的框选虚线矩形（视口坐标 overlay，挂 ScrollView；与 DragGesture .local 同空间）。
    @ViewBuilder var lassoDragOverlay: some View {
        if let r = lassoRect {
            Rectangle()
                .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                .background(Color.accentColor.opacity(0.06))
                .frame(width: r.width, height: r.height)
                .position(x: r.midX, y: r.midY)
                .allowsHitTesting(false)
        }
    }

    // MARK: Esc 清除选中（NSEvent 本地监视器，同 copyMonitor：纯 ScrollView 容器拿不到焦点链）

    /// 只在「本窗口激活 + 确有选中集 + 焦点不在文本编辑」时消费 Esc；其余原样放行（不影响系统 Esc 语义）。
    func installLassoEscMonitor() {
        guard scratch.lassoEscMonitor == nil else { return }
        scratch.lassoEscMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard scratch.isActiveWindow, event.keyCode == 53, lassoSelection != nil,
                  !(NSApp.keyWindow?.firstResponder is NSText) else { return event }
            clearLassoSelection()
            return nil
        }
    }

    func removeLassoEscMonitor() {
        if let m = scratch.lassoEscMonitor {
            NSEvent.removeMonitor(m)
            scratch.lassoEscMonitor = nil
        }
    }
}
