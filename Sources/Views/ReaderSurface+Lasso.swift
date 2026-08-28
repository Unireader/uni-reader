import SwiftUI
import PDFKit
import AppKit   // 仅 NSEvent 监视器（事件管道）；阅读区无 AppKit 视图（红线）

/// 框选（pointerTool == .lasso，仅页内）：
///  · 拖空白 → 自由路径框选（视口坐标虚线 overlay，≥3pt 抽稀）；松手把路径围成的不规则多边形
///    命中同页笔迹（任一点落多边形内，`InkEdit.pointInPolygon`）+ 同页文字注解（anchor 中心落多边形内），
///    选中集存瞬态 `lassoSelection`。
///  · 选中笔迹画 accent 色光晕边缘（`lassoStrokeHalo`，所见即所选）+ 联合包围盒高亮框（含缩放手柄）。
///  · 拖选中高亮框内 → 移动：拖动中只动 ghost 预览（框/手柄/光晕随瞬态 `lassoGhostOffset`，不改数据）；
///    松手一次性提交（笔迹 `InkEdit.translated` / 注解 anchor+rects 同平移，页内 clamp），
///    ContentView 值快照对账自动落库，恰是 padSession 时显式广播镜像到平板。
///  · 拖手柄 → 缩放：**角手柄 = 等比**（⇧ 临时自由两轴）、**边中点手柄 = 单轴**，anchor = 对侧手柄；
///    拖动中框/手柄/光晕按瞬态 `lassoGhostScale` 预览；松手一次性提交
///    （`InkEdit.scaled`：点集绕 anchor 按轴缩放 + clamp，线宽 ×√(sx·sy)），落库/镜像同上。
///  · 点空白（单击）/ Esc / 切走工具 → 清除选中。
extension ReaderSurface {

    // MARK: 手势（拖空白=自由框选 / 拖选中框内=移动 / 拖手柄=缩放，起点一次性判定）

    /// 框选手势：仅 `pointerTool == .lasso` 生效（与拖选/本机落墨互斥门控，同挂 ScrollView 容器）。
    var lassoGesture: some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .local)
            .onChanged { v in
                guard app.pointerTool == .lasso, scratch.pinch == nil,
                      session.openPadID == nil else { return }   // 草稿纸盖着时阅读区一概不响应
                guard !(snipModifierDown && scratch.lassoDragMode == nil) else { return }   // ⌥ 让位截图
                if scratch.lassoDragMode == nil {
                    let g = scratch.geo
                    let startContent = CGPoint(x: g.offsetX + v.startLocation.x,
                                               y: g.offsetY + v.startLocation.y)
                    var mode = LassoDragMode.select
                    if let sel = lassoSelection, let box = lassoDisplayBox(sel) {
                        // 手柄优先（10pt 命中半径）：拖手柄 = 缩放；框内（含 8pt 抓手余量）= 移动
                        if let handle = lassoHandleHit(at: startContent, box: box) {
                            mode = .scale(handle)
                        } else if box.insetBy(dx: -8, dy: -8).contains(startContent) {
                            mode = .move
                        }
                    }
                    scratch.lassoDragMode = mode
                    if mode == .select {   // 起新框选即放弃旧选中
                        lassoSelection = nil
                        lassoPath = [v.startLocation]
                    }
                }
                switch scratch.lassoDragMode {
                case .select:
                    // 自由路径：≥3pt 抽稀（更密的点对多边形命中无增益，白耗 O(点数×边数)）
                    if let last = lassoPath?.last,
                       hypot(v.location.x - last.x, v.location.y - last.y) >= 3 {
                        lassoPath?.append(v.location)
                    }
                case .move:
                    lassoGhostOffset = v.translation   // ghost 预览：只动框，不改数据
                case .scale(let handle):
                    updateLassoScaleGhost(handle: handle, drag: v)
                case nil:
                    break
                }
            }
            .onEnded { _ in
                let mode = scratch.lassoDragMode
                scratch.lassoDragMode = nil
                let path = lassoPath
                lassoPath = nil
                let ghost = lassoGhostOffset
                lassoGhostOffset = .zero
                let gscale = lassoGhostScale
                lassoGhostScale = nil
                guard app.pointerTool == .lasso, let mode else { return }
                switch mode {
                case .select:
                    if let path { finishLassoSelect(path: path) }
                case .move:
                    commitLassoMove(translation: ghost)
                case .scale:
                    if let gscale { commitLassoScale(scale: gscale) }
                }
            }
    }

    /// 手柄命中：P（内容坐标）距显示框某手柄（四角 + 四边中点）≤10pt 即返回该手柄。
    func lassoHandleHit(at P: CGPoint, box: CGRect) -> LassoHandle? {
        for h in LassoHandle.allCases {
            let p = h.point(in: box)
            if hypot(P.x - p.x, P.y - p.y) <= 10 { return h }
        }
        return nil
    }

    /// 缩放手柄拖动中：由被拖手柄当前位置与原「手柄→对侧手柄」向量算缩放比（显示空间；按轴线性变换，
    /// 与归一化坐标严格等价，无需 aspect 折算），clamp 0.05...20。
    /// 角手柄默认**等比**（取变化幅度更大的一轴，⇧ 临时放开两轴自由）；边中点手柄**单轴**（另一轴恒 1）。
    func updateLassoScaleGhost(handle: LassoHandle, drag v: DragGesture.Value) {
        guard let sel = lassoSelection, let box = lassoDisplayBox(sel) else { return }
        let anchor = handle.opposite.point(in: box)
        let start = handle.point(in: box)
        let g = scratch.geo
        let cur = CGPoint(x: g.offsetX + v.location.x, y: g.offsetY + v.location.y)
        let denomX = start.x - anchor.x, denomY = start.y - anchor.y
        var sx: CGFloat = 1, sy: CGFloat = 1
        switch handle {
        case .t, .b:   // 竖向单轴
            guard abs(denomY) > 1 else { return }
            sy = (cur.y - anchor.y) / denomY
        case .l, .r:   // 横向单轴
            guard abs(denomX) > 1 else { return }
            sx = (cur.x - anchor.x) / denomX
        case .tl, .tr, .bl, .br:
            guard abs(denomX) > 1, abs(denomY) > 1 else { return }   // 退化框（~0 宽/高）不给缩
            sx = (cur.x - anchor.x) / denomX
            sy = (cur.y - anchor.y) / denomY
            if !NSEvent.modifierFlags.contains(.shift) {   // 角默认等比：取变化幅度更大的一轴
                let s = abs(sx - 1) >= abs(sy - 1) ? sx : sy
                sx = s; sy = s
            }
        }
        func cl(_ s: CGFloat) -> CGFloat { min(20, max(0.05, s)) }
        lassoGhostScale = (cl(sx), cl(sy), handle)
    }

    // MARK: 框选命中（自由路径 → 不规则多边形；锚定起点所在页，仅页内；跨页点 clamp 到该页边缘）

    func finishLassoSelect(path: [CGPoint]) {
        guard path.count >= 3, let first = path.first,
              let anchorPage = containerPointToPageNorm(first, xRange: inkXRange)?.page else { return }
        // 逐点转页内归一化：横向页与页同 pageX/pageW，nx 通用；纵向跨页点贴 anchor 页边缘（仅页内，不跨页选）
        // 画板模式下 x 放宽到页边（否则框在页外的路径全被 clamp 成 x=1 的一条竖线，圈不中页边笔迹）
        var poly: [SIMD2<Double>] = []
        for p in path {
            guard let n = containerPointToPageNorm(p, xRange: inkXRange) else { continue }
            let ny = n.page == anchorPage ? n.ny : (n.page > anchorPage ? 1 : 0)
            poly.append(SIMD2(Double(n.nx), Double(ny)))
        }
        guard poly.count >= 3 else { return }

        var strokeIDs = Set<UUID>()
        var noteIDs = Set<UUID>()
        var bbox = CGRect.null
        let vis = session.visibleLayerIDs
        for st in session.strokes where st.page == anchorPage && vis.contains(st.layerId) {
            if st.points.contains(where: { InkEdit.pointInPolygon(SIMD2($0.x, $0.y), polygon: poly) }) {
                strokeIDs.insert(st.id)
                bbox = bbox.union(strokeBounds(st))
            }
        }
        for n in session.textNotes where n.page == anchorPage {
            // anchor 中心落多边形内（零尺寸点注解即锚点本身）
            if InkEdit.pointInPolygon(SIMD2(Double(n.anchor.midX), Double(n.anchor.midY)), polygon: poly) {
                noteIDs.insert(n.id)
                bbox = bbox.union(n.anchor)
            }
        }
        guard !strokeIDs.isEmpty || !noteIDs.isEmpty else { return }
        lassoSelection = LassoSelection(page: anchorPage, strokeIDs: strokeIDs, noteIDs: noteIDs, bounds: bbox)
    }

    /// 笔迹点集的页内归一化包围盒。
    /// 初值取**首个点**而非 (1,1)/(0,0)：画板模式下整条笔画可能全在页外（x 恒 >1 或恒 <0），
    /// 按页角起算会把包围盒硬撑到页边，选中框和缩放锚点全错位。
    func strokeBounds(_ st: InkStroke) -> CGRect {
        guard let f = st.points.first else { return .zero }
        var lo = SIMD2<Double>(f.x, f.y), hi = SIMD2<Double>(f.x, f.y)
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
            session.strokes[i] = InkEdit.translated(session.strokes[i], dx: dx, dy: dy, xRange: inkXRange)
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
        refreshCanvasMargin()   // 笔迹被挪到页边更远处：笔画数没变，软边界得自己跟上
        // 镜像平板：仅当本窗口恰是 padSession（同 inkEnd 语义；否则 broadcast 的是 padSession 的旧数据）
        if session.id == app.padSession?.id { app.broadcastStrokes(); app.broadcastNotes() }
    }

    // MARK: 缩放提交（松手一次性绕 anchor 按轴缩放，页内 clamp）

    func commitLassoScale(scale gs: (sx: CGFloat, sy: CGFloat, handle: LassoHandle)) {
        guard let sel = lassoSelection, let layout,
              layout.heights.indices.contains(sel.page), pageW > 0,
              let box = lassoDisplayBox(sel) else { return }
        let sx = Double(gs.sx), sy = Double(gs.sy)
        guard sx != 1 || sy != 1 else { return }
        // 内容坐标 anchor（被拖手柄的对侧手柄）→ 页内归一化（按轴线性缩放，两坐标系换算下 sx/sy 不变）
        let ac = gs.handle.opposite.point(in: box)
        let ds = max(0.0001, dispScale)
        let pageHDisp = layout.heights[sel.page] * ds
        let a = SIMD2(Double((ac.x - pageX) / pageW),
                      Double((ac.y - layout.offsets[sel.page] * ds) / pageHDisp))
        var changed = false
        for i in session.strokes.indices
        where session.strokes[i].page == sel.page && sel.strokeIDs.contains(session.strokes[i].id) {
            session.strokes[i] = InkEdit.scaled(session.strokes[i], anchor: a, sx: sx, sy: sy, xRange: inkXRange)
            changed = true
        }
        for i in session.textNotes.indices
        where session.textNotes[i].page == sel.page && sel.noteIDs.contains(session.textNotes[i].id) {
            session.textNotes[i] = InkEdit.scaled(session.textNotes[i], anchor: a, sx: sx, sy: sy)
            changed = true
        }
        guard changed else { lassoSelection = nil; return }   // 选中项已被擦除/删除
        var s = sel
        s.bounds = InkEdit.scaledRect(sel.bounds, anchor: a, sx: sx, sy: sy)
        lassoSelection = s
        refreshCanvasMargin()   // 同 commitLassoMove
        // 镜像平板：仅当本窗口恰是 padSession（同 commitLassoMove 语义）
        if session.id == app.padSession?.id { app.broadcastStrokes(); app.broadcastNotes() }
    }

    func clearLassoSelection() {
        lassoSelection = nil
        lassoPath = nil
        lassoGhostOffset = .zero
        lassoGhostScale = nil
        if scratch.lassoDragMode != nil { scratch.lassoDragMode = nil }
    }

    // MARK: 渲染（纯功能 overlay：虚线路径/高亮框/手柄/光晕，非仿系统控件）

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

    /// 选中集显示框（内容坐标）：内容包围盒外扩 6pt + 最小 16pt
    /// （零尺寸点注解/极薄笔迹也有可见可抓的框）。渲染/手柄命中/缩放数学共用这一份，别各算各的。
    func lassoDisplayBox(_ sel: LassoSelection) -> CGRect? {
        guard let hl = lassoContentRect(sel) else { return nil }
        let box = hl.insetBy(dx: -6, dy: -6)
        let w = max(box.width, 16), h = max(box.height, 16)
        return CGRect(x: box.midX - w / 2, y: box.midY - h / 2, width: w, height: h)
    }

    /// 点经 ghost 变换后的位置（scale = 绕对侧手柄 anchor 按轴缩放；否则 = move 平移；无 ghost = 原样）。
    func lassoGhostPoint(_ p: CGPoint, in box: CGRect) -> CGPoint {
        if let gs = lassoGhostScale {
            let a = gs.handle.opposite.point(in: box)
            return CGPoint(x: a.x + (p.x - a.x) * gs.sx, y: a.y + (p.y - a.y) * gs.sy)
        }
        return CGPoint(x: p.x + lassoGhostOffset.width, y: p.y + lassoGhostOffset.height)
    }

    /// 选中项高亮框 + 缩放手柄（四角等比 / 四边中点单轴；内容坐标，置于页元胞之上）+ 移动/缩放 ghost（瞬态，数据未动）。
    @ViewBuilder var lassoHighlight: some View {
        if let sel = lassoSelection, let box = lassoDisplayBox(sel) {
            let handles = LassoHandle.allCases
            let pts = handles.map { lassoGhostPoint($0.point(in: box), in: box) }
            let lo = pts.reduce(pts[0]) { CGPoint(x: min($0.x, $1.x), y: min($0.y, $1.y)) }
            let hi = pts.reduce(pts[0]) { CGPoint(x: max($0.x, $1.x), y: max($0.y, $1.y)) }
            Group {
                RoundedRectangle(cornerRadius: 4)
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                    .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
                    .frame(width: hi.x - lo.x, height: hi.y - lo.y)
                    .offset(x: lo.x, y: lo.y)
                ForEach(pts.indices, id: \.self) { i in
                    Circle()
                        .fill(Color.accentColor.opacity(0.25))
                        .overlay(Circle().stroke(Color.accentColor, lineWidth: 1.5))
                        .frame(width: 9, height: 9)
                        .position(pts[i])
                }
            }
            .allowsHitTesting(false)
        }
    }

    /// 选中笔迹的光晕边缘（内容坐标 Canvas）：accent 色半透明描边包住每一笔，所见即所选；
    /// move/scale ghost 期间随 ghost 变换走（预览即提交结果）。注解不加光晕（高亮框已覆盖）。
    @ViewBuilder var lassoStrokeHalo: some View {
        if let sel = lassoSelection, let layout,
           layout.heights.indices.contains(sel.page), pageW > 0 {
            let ds = max(0.0001, dispScale)
            let pageTop = layout.offsets[sel.page] * ds
            let pageH = layout.heights[sel.page] * ds
            let box = lassoDisplayBox(sel)
            let strokes = session.strokes.filter { $0.page == sel.page && sel.strokeIDs.contains($0.id) }
            Canvas { ctx, _ in
                for st in strokes {
                    func mapPt(_ p: SIMD3<Double>) -> CGPoint {
                        var pt = CGPoint(x: pageX + p.x * pageW, y: pageTop + p.y * pageH)
                        if let box { pt = lassoGhostPoint(pt, in: box) }
                        return pt
                    }
                    let haloW = CGFloat(st.width) * zoom + 5   // 笔宽随缩放，光晕余量恒定 5pt
                    if st.points.count == 1 {
                        let p0 = mapPt(st.points[0])
                        let r = CGFloat(st.type.strokeWidth(pressure: st.points[0].z, base: st.width)) * zoom / 2 + 2.5
                        ctx.fill(Path(ellipseIn: CGRect(x: p0.x - r, y: p0.y - r, width: r * 2, height: r * 2)),
                                 with: .color(.accentColor.opacity(0.35)))
                    } else {
                        var path = Path()
                        path.addLines(st.points.map(mapPt))
                        ctx.stroke(path, with: .color(.accentColor.opacity(0.35)),
                                   style: StrokeStyle(lineWidth: haloW, lineCap: .round, lineJoin: .round))
                    }
                }
            }
            .frame(width: contentW, height: contentH)
            .allowsHitTesting(false)
        }
    }

    /// 进行中的自由框选虚线路径（视口坐标 overlay，挂 ScrollView；与 DragGesture .local 同空间；
    /// 不随内容滚动——框选拖动中不滚动）。
    @ViewBuilder var lassoDragOverlay: some View {
        if let path = lassoPath, path.count >= 2 {
            ZStack {
                Path { p in p.addLines(path); p.closeSubpath() }
                    .fill(Color.accentColor.opacity(0.06))
                Path { p in p.addLines(path); p.closeSubpath() }
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
            }
            .allowsHitTesting(false)
        }
    }

    // MARK: Esc 清除选中（NSEvent 本地监视器：纯 ScrollView 容器拿不到焦点链）

    /// 只在「本窗口激活 + 确有选中集 + 焦点不在文本编辑」时消费 Esc；其余原样放行（不影响系统 Esc 语义）。
    func installLassoEscMonitor() {
        guard scratch.lassoEscMonitor == nil else { return }
        scratch.lassoEscMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard scratch.isActiveWindow, event.keyCode == 53, lassoSelection != nil,
                  !(NSApp.keyWindow?.firstResponder is NSText),
                  !aiWebInputHasFocus() else { return event }   // Esc 在内置面板里归网页（关弹窗等）
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
