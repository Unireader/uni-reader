import SwiftUI
import AppKit   // 仅 NSEvent 监视器（事件管道）；阅读区/覆盖层无 AppKit 视图（红线）

/// 草稿纸覆盖层：盖在阅读区之上的一张**无限白纸**（纯 SwiftUI，同阅读区红线）。
///
/// 交互取通用无限画布的那套，不发明新手势：
///  · 拖动 = 平移；`pointerTool == .ink` 时 = 落墨/擦除（与阅读区本机落墨同一个开关）
///  · 双指捏合 / ⌘滚轮 = 以指针为锚缩放；普通滚轮/双指滑 = 平移
///  · 「回中」回到画布原点（= 创建这张纸时的位置，用户要的「从该处显示」）；「适应内容」装下全部笔迹
///  · 右下 minimap：全部笔迹缩略 + 当前视口框，点/拖即跳
///
/// 无限不等于能滚到无穷远：`ScratchBounds` 把可视区限制在「内容包围盒 ± 1.5 屏」内，
/// 空白纸就只能在原点附近晃——不会出现「一路滑出去再也找不回来」。
struct ScratchPadOverlay: View {
    @EnvironmentObject var app: AppModel
    @ObservedObject var session: DocSession
    let pad: ScratchPad
    let padIndex: Int
    /// 玻璃工具栏避让量（同阅读区 `indicatorTopInset`）。
    let topInset: CGFloat

    // 视口（本端私有，不落库不上线：三端各自独立缩放滚动）
    @State private var vp = ScratchViewport()
    @State private var didPlace = false
    @State private var viewSize: CGSize = .zero
    @State private var showMinimap = true

    // 手势暂存
    @State private var panStart: CGPoint?          // 平移起点的 origin 快照
    @State private var pinchStart: ScratchViewport?
    @State private var inking = false              // 本次拖拽是落墨（而非平移）
    @State private var cursor: CGPoint?            // 视图坐标（橡皮圆环 / ⌘滚轮锚点）
    @State private var wheelMonitor: Any?
    @State private var keyMonitor: Any?
    @State private var renaming = false
    @State private var draftTitle = ""

    private var strokes: [InkStroke] { session.strokes(pad: pad.id) }
    /// 本窗口是不是当前活动窗口。**不能用传进来的 `isActiveWindow`**：那是 struct 的 `let`，
    /// 被 NSEvent 监视器的逃逸闭包按值捕获后就永远停在安装那一刻的值（同 `Scratch.isActiveWindow`
    /// 记的那个坑）。多窗口各开一张草稿纸时，后台窗口的监视器会把前台窗口的滚轮事件吃掉。
    /// `app` 是引用类型，读它才是实时的。
    private var isFrontWindow: Bool { app.activeSessionID == session.id }
    private var bg: Color {
        Color(red: pad.bg.r / 255, green: pad.bg.g / 255, blue: pad.bg.b / 255, opacity: pad.bg.a)
    }
    private var isErasing: Bool { app.pointerTool == .ink && app.padMode == "erase" }
    /// 橡皮在画布坐标下的半径（页宽归一化 → 画布点，三端同一个换算，见 `ScratchPad.eraserRefWidth`）。
    private var eraserCanvasRadius: Double { app.eraserRadius * ScratchPad.eraserRefWidth }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                bg
                inkLayers
                eraserRing
                gestureCatcher
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
            .onAppear { place(geo.size) }
            .onChange(of: geo.size) { old, new in
                viewSize = new
                // 窗口缩放：保持画布中心不动（否则每次拉窗口内容都往一边跑）。
                guard didPlace, old.width > 1, old.height > 1 else { return }
                vp.origin.x += (old.width - new.width) / (2 * vp.zoom)
                vp.origin.y += (old.height - new.height) / (2 * vp.zoom)
                clampViewport()
            }
        }
        .overlay(alignment: .top) { toolbar }
        .overlay(alignment: .bottomTrailing) { minimapPanel }
        .background(bg)   // GeometryReader 首帧 size 为 0 时不露出下面的 PDF
        .onAppear { installMonitors() }
        .onDisappear { removeMonitors() }
    }

    // MARK: 笔迹

    @ViewBuilder private var inkLayers: some View {
        // 拆 Equatable 静态层 / 活体层：理由同页内的 `InkStaticLayer`——`session` 上任一 @Published
        // 变动都会让本 body 重算，不拆的话每帧把整纸笔迹重栅格化。
        ScratchInkLayer(strokes: strokes, viewport: vp)
        if let live = session.scratchLive, live.padId == pad.id {
            ScratchInkLayer(strokes: [live], viewport: vp)
        }
    }

    @ViewBuilder private var eraserRing: some View {
        if isErasing, app.eraserRing, let c = cursor {
            Circle()
                .stroke(Color.accentColor, lineWidth: 1.5)
                .frame(width: eraserCanvasRadius * 2 * vp.zoom, height: eraserCanvasRadius * 2 * vp.zoom)
                .position(c)
                .allowsHitTesting(false)
        }
    }

    // MARK: 手势

    /// 透明的手势承载层。铺满整层 → 把阅读区的拖选/落墨/框选手势全挡在下面
    /// （「笔迹只能落在草稿纸上」＝ 草稿纸开着时下面那层一概不该收到指针事件）。
    private var gestureCatcher: some View {
        Color.clear
            .contentShape(Rectangle())
            .onContinuousHover(coordinateSpace: .local) { phase in
                switch phase {
                case .active(let p): cursor = p
                case .ended: cursor = nil
                }
            }
            .gesture(dragGesture)
            .simultaneousGesture(magnifyGesture)
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { v in
                if app.pointerTool == .ink {
                    inkDrag(v)
                } else {
                    if panStart == nil { panStart = vp.origin }
                    guard let s = panStart else { return }
                    vp.origin = CGPoint(x: s.x - v.translation.width / vp.zoom,
                                        y: s.y - v.translation.height / vp.zoom)
                    clampViewport()
                }
            }
            .onEnded { _ in
                panStart = nil
                if inking {
                    inking = false
                    if !isErasing { app.scratchInkEnd(in: session) }   // 擦除每批即时生效，无需收尾
                }
            }
    }

    private func inkDrag(_ v: DragGesture.Value) {
        let p = vp.toCanvas(v.location)
        let pt = SIMD3(Double(p.x), Double(p.y), 0.5)
        if !inking {
            inking = true
            let p0 = vp.toCanvas(v.startLocation)
            let start = SIMD3(Double(p0.x), Double(p0.y), 0.5)
            if isErasing {
                app.scratchErase([start], in: session)
            } else {
                guard let pen = app.pens.indices.contains(app.padPenIndex)
                        ? app.pens[app.padPenIndex] : app.pens.first else { return }
                app.scratchInkBegin(in: session, pad: pad.id, color: pen.color,
                                    width: pen.width, type: pen.type, points: [start])
            }
            return
        }
        if isErasing {
            app.scratchErase([pt], in: session)
        } else if NSEvent.modifierFlags.contains(.shift) {
            // ⇧ 尺子：整笔替换为「起点 → 45° 吸附终点」两点直线。画布是等比坐标系 → aspect=1
            // （页内那套要传页面纵横比，是因为页内归一化两轴尺度不同；这里没有这个问题）。
            guard let live = session.scratchLive, let a = live.points.first else { return }
            let snapped = InkEdit.rulerSnap(start: SIMD2(a.x, a.y), current: SIMD2(pt.x, pt.y), aspect: 1)
            app.scratchInkLineTo(SIMD3(snapped.x, snapped.y, 0.5), in: session)
        } else {
            app.scratchInkAppend([pt], in: session)
        }
    }

    private var magnifyGesture: some Gesture {
        MagnifyGesture(minimumScaleDelta: 0)
            .onChanged { v in
                let base = pinchStart ?? vp
                if pinchStart == nil { pinchStart = vp }
                let anchor = cursor ?? CGPoint(x: viewSize.width / 2, y: viewSize.height / 2)
                vp = ScratchBounds.clamp(base.zoomed(by: v.magnification, anchorScreen: anchor),
                                         content: ScratchBounds.contentBounds(strokes), viewport: viewSize)
            }
            .onEnded { _ in pinchStart = nil }
    }

    // MARK: 视口

    private func place(_ size: CGSize) {
        viewSize = size
        guard !didPlace, size.width > 1, size.height > 1 else { return }
        didPlace = true
        // 打开 = 回到画布原点（用户要的「从该处显示」）。要找已经写过的东西走「适应内容」/minimap。
        vp = .centeredOnOrigin(viewport: size)
    }

    private func clampViewport() {
        vp = ScratchBounds.clamp(vp, content: ScratchBounds.contentBounds(strokes), viewport: viewSize)
    }

    private func recenter() {
        withAnimation(.easeOut(duration: 0.18)) { vp = .centeredOnOrigin(viewport: viewSize) }
    }

    private func fitContent() {
        let target = ScratchBounds.fit(content: ScratchBounds.contentBounds(strokes), viewport: viewSize)
        withAnimation(.easeOut(duration: 0.18)) { vp = target }
    }

    // MARK: 工具条（扁平、原生；无渐变/高光/投影）

    private var toolbar: some View {
        HStack(spacing: 10) {
            Image(systemName: "square.and.pencil").foregroundStyle(.secondary)
            if renaming {
                TextField(L("Name"), text: $draftTitle)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 180)
                    .onSubmit { commitRename() }
            } else {
                Text(pad.displayName(index: padIndex))
                    .fontWeight(.medium)
                    .onTapGesture(count: 2) { draftTitle = pad.title; renaming = true }
                    .help(L("Double-click to rename"))
            }
            Text(String(format: L("%d strokes"), strokes.count))
                .font(.caption).foregroundStyle(.secondary)
            Divider().frame(height: 16)
            Button { recenter() } label: { Image(systemName: "scope") }
                .help(L("Recenter"))
            Button { fitContent() } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                .help(L("Fit Content"))
                .disabled(strokes.isEmpty)
            Button { showMinimap.toggle() } label: {
                Image(systemName: showMinimap ? "map.fill" : "map")
            }
            .help(L("Minimap"))
            Text(String(format: "%.0f%%", vp.zoom * 100))
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                .frame(width: 44, alignment: .trailing)
            Divider().frame(height: 16)
            Button { close() } label: { Image(systemName: "xmark") }
                .help(L("Close Scratchpad (Esc)"))
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
        .padding(.top, topInset)
    }

    private func commitRename() {
        renaming = false
        guard let i = session.scratchPads.firstIndex(where: { $0.id == pad.id }) else { return }
        let t = draftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t != session.scratchPads[i].title else { return }
        session.scratchPads[i].title = t
        session.scratchPads[i].updatedAt = .now
    }

    private func close() {
        app.scratchInkCancel(in: session)
        session.openPadID = nil
    }

    // MARK: minimap

    @ViewBuilder private var minimapPanel: some View {
        if showMinimap {
            ScratchMinimap(strokes: strokes, viewport: vp, viewSize: viewSize) { center in
                // 点/拖 minimap → 视口中心跳到那儿。
                vp.origin = CGPoint(x: center.x - viewSize.width / (2 * vp.zoom),
                                    y: center.y - viewSize.height / (2 * vp.zoom))
                clampViewport()
            }
            .frame(width: 180, height: 130)
            .padding(12)
        }
    }

    // MARK: 事件监视器（滚轮平移 / ⌘滚轮缩放 / Esc 关闭）

    private func installMonitors() {
        if wheelMonitor == nil {
            wheelMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
                guard isFrontWindow, session.openPadID == pad.id else { return event }
                var dx = event.scrollingDeltaX, dy = event.scrollingDeltaY
                if !event.hasPreciseScrollingDeltas { dx *= 10; dy *= 10 }
                if event.modifierFlags.contains(.command) {
                    guard dy != 0, event.momentumPhase == [] else { return nil }
                    let factor = min(max(exp(-dy * 0.008), 0.5), 2)   // 手感旋钮同阅读区 ⌘滚轮
                    let anchor = cursor ?? CGPoint(x: viewSize.width / 2, y: viewSize.height / 2)
                    vp = ScratchBounds.clamp(vp.zoomed(by: factor, anchorScreen: anchor),
                                             content: ScratchBounds.contentBounds(strokes), viewport: viewSize)
                    return nil
                }
                guard dx != 0 || dy != 0 else { return nil }
                vp.origin = CGPoint(x: vp.origin.x - dx / vp.zoom, y: vp.origin.y - dy / vp.zoom)
                clampViewport()
                return nil   // 消费：草稿纸开着时滚轮绝不能穿透去滚下面的 PDF
            }
        }
        if keyMonitor == nil {
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                guard isFrontWindow, session.openPadID == pad.id, !renaming else { return event }
                guard event.keyCode == 53 else { return event }   // Esc
                close()
                return nil
            }
        }
    }

    private func removeMonitors() {
        if let m = wheelMonitor { NSEvent.removeMonitor(m); wheelMonitor = nil }
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
    }
}

// MARK: - 笔迹层（Equatable，同 `InkStaticLayer` 的拆层理由）

struct ScratchInkLayer: View, Equatable {
    let strokes: [InkStroke]
    let viewport: ScratchViewport

    static func == (l: Self, r: Self) -> Bool { l.strokes == r.strokes && l.viewport == r.viewport }

    var body: some View {
        Canvas { ctx, _ in
            let o = viewport.origin, z = viewport.zoom
            for st in strokes {
                // 线宽同样乘 zoom（`inkScale`）→ 与页内笔迹「放大即变粗」的语义一致。
                inkDrawStroke(st, in: &ctx, inkScale: z) {
                    CGPoint(x: ($0.x - o.x) * z, y: ($0.y - o.y) * z)
                }
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - minimap

/// 右下角缩略图：把「全部笔迹包围盒 ∪ 当前视口」等比装进小窗，画笔迹骨架 + 当前视口框。
/// 点或拖窗内任意处 → 视口中心跳到对应画布位置（`onJump` 给画布坐标）。
struct ScratchMinimap: View {
    let strokes: [InkStroke]
    let viewport: ScratchViewport
    let viewSize: CGSize
    let onJump: (CGPoint) -> Void

    /// minimap 覆盖的画布范围 = 内容 ∪ 视口，再留一点边。两者都空时给一块围绕原点的默认区。
    private var world: CGRect {
        let vis = viewport.visibleRect(viewport: viewSize)
        var r = ScratchBounds.contentBounds(strokes).map { $0.union(vis) } ?? vis
        if r.width < 1 || r.height < 1 { r = CGRect(x: -400, y: -300, width: 800, height: 600) }
        return r.insetBy(dx: -r.width * 0.08, dy: -r.height * 0.08)
    }

    /// 画布 → 小窗的等比映射（含居中偏移）。`s <= 0` 表示小窗还没量到尺寸。
    private struct Fit {
        let world: CGRect, s: CGFloat, ox: CGFloat, oy: CGFloat
        func map(_ x: Double, _ y: Double) -> CGPoint {
            CGPoint(x: ox + (CGFloat(x) - world.minX) * s, y: oy + (CGFloat(y) - world.minY) * s)
        }
        func unmap(_ p: CGPoint) -> CGPoint {
            CGPoint(x: world.minX + (p.x - ox) / s, y: world.minY + (p.y - oy) / s)
        }
    }

    private func fit(in box: CGSize) -> Fit {
        let w = world
        let s = min(box.width / max(w.width, 1), box.height / max(w.height, 1))
        return Fit(world: w, s: s,
                   ox: (box.width - w.width * s) / 2, oy: (box.height - w.height * s) / 2)
    }

    var body: some View {
        GeometryReader { geo in
            let f = fit(in: geo.size)
            let vis = viewport.visibleRect(viewport: viewSize)
            let tl = f.map(Double(vis.minX), Double(vis.minY))
            ZStack(alignment: .topLeading) {
                Canvas { ctx, _ in
                    // 骨架线即可（minimap 不必还原笔型/压感，1px 折线最省也最清楚）
                    for st in strokes where st.points.count > 1 {
                        var path = Path()
                        path.move(to: f.map(st.points[0].x, st.points[0].y))
                        for p in st.points.dropFirst() { path.addLine(to: f.map(p.x, p.y)) }
                        ctx.stroke(path, with: .color(Color.primary.opacity(0.55)),
                                   style: StrokeStyle(lineWidth: 1, lineCap: .round, lineJoin: .round))
                    }
                }
                Rectangle()   // 当前视口框
                    .stroke(Color.accentColor, lineWidth: 1.5)
                    .frame(width: max(4, vis.width * f.s), height: max(4, vis.height * f.s))
                    .offset(x: tl.x, y: tl.y)
                    .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .local)
                    .onChanged { v in
                        guard f.s > 0 else { return }
                        onJump(f.unmap(v.location))
                    }
            )
        }
        .background(.bar)
        .overlay(Rectangle().stroke(Color.primary.opacity(0.15), lineWidth: 0.5))
    }
}
