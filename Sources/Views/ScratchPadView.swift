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
    /// 阅读区的页间底色（`ReaderSurface.voidColor`）。用来在工具栏那条带子后面**顶掉纸色**：
    /// macOS 26 的工具栏是玻璃的，图标颜色跟外观走（深色外观 = 白图标），而草稿纸是**白纸**——
    /// 纸一路铺到工具栏底下就是白图标压白纸，整条工具栏当场看不见（用户 2026-08-07 报）。
    /// 铺回阅读区自己的底色，工具栏就拿回了它平时的背景。
    let voidColor: Color

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
    /// 网格/提示文字用的「墨色」。**不能直接用 `Color.primary`**——那跟随系统深浅外观，
    /// 而纸色是这张纸自己的属性（默认白，也可以是别的）：深色外观 + 白纸时 primary 是白的，
    /// 网格就整个消失了。改由纸色明度推：浅纸配深墨、深纸配浅墨。
    private var gridInk: Color {
        let lum = (0.299 * pad.bg.r + 0.587 * pad.bg.g + 0.114 * pad.bg.b) / 255
        return lum > 0.5 ? Color.black : Color.white
    }
    private var isErasing: Bool { app.pointerTool == .ink && app.padMode == "erase" }
    /// 橡皮在画布坐标下的半径（页宽归一化 → 画布点，三端同一个换算，见 `ScratchPad.eraserRefWidth`）。
    private var eraserCanvasRadius: Double { app.eraserRadius * ScratchPad.eraserRefWidth }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                bg
                ScratchGridLayer(viewport: vp, ink: gridInk)   // 定位参照：淡点阵 + 原点标记
                inkLayers
                emptyHint
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
        // 工具栏底衬（必须在 toolbar 之下、纸之上）：见 `voidColor` 的注释。
        .overlay(alignment: .top) {
            if topInset > 0 { voidColor.frame(height: topInset).allowsHitTesting(false) }
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

    /// 空白纸的引导：一张全白的纸不说话，用户不知道能干嘛。有笔迹后自动消失。
    @ViewBuilder private var emptyHint: some View {
        if strokes.isEmpty, session.scratchLive == nil {
            VStack(spacing: 6) {
                Text(L("Blank scratchpad"))
                    .font(.title3)
                Text(app.pointerTool == .ink
                     ? L("Draw anywhere. Drag with the hand tool to pan, pinch to zoom.")
                     : L("Pick the pen in the pen rack to write. Drag to pan, pinch to zoom."))
                    .font(.callout)
            }
            .foregroundStyle(gridInk.opacity(0.28))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .allowsHitTesting(false)
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
            // 光标反馈：手型 = 拖动即平移，十字 = 会落墨。没有这个，草稿纸上「拖一下会发生什么」
            // 全靠试——这是它最初读起来「生硬」的一大来源。
            // （`PointerStyle` 没有 `.crosshair`；`.rectSelection` 在 macOS 上渲染的正是十字光标）
            .pointerStyle(app.pointerTool == .ink ? .rectSelection
                                                  : (panStart == nil ? .grabIdle : .grabActive))
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

    // MARK: 工具条
    //
    // **悬浮胶囊，不是横贯全宽的工具栏**：最初那版是一条 `.bar` 横杠，把阅读区从上面一刀切开，
    // 观感最生硬的就是它。改成与 `PenRackView`/`findBanner` 完全同一套的浮层语言
    // （`.regularMaterial in Capsule()` + 0.5 描边 + 轻投影），于是它读起来是「浮在纸上的一个控件」，
    // 而不是「把界面劈成两半的一根梁」。

    private var toolbar: some View {
        HStack(spacing: 8) {
            if renaming {
                TextField(L("Name"), text: $draftTitle)
                    .textFieldStyle(.plain)
                    .frame(width: 150)
                    .onSubmit { commitRename() }
                    .onExitCommand { renaming = false }
            } else {
                Button {
                    draftTitle = pad.title; renaming = true
                } label: {
                    Label(pad.displayName(index: padIndex), systemImage: "square.and.pencil")
                        .labelStyle(.titleAndIcon)
                        .lineLimit(1)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.primary)
                .help(L("Click to rename"))
            }
            Divider().frame(height: 14)
            padButton("scope", L("Recenter")) { recenter() }
            padButton("arrow.up.left.and.arrow.down.right", L("Fit Content")) { fitContent() }
                .disabled(strokes.isEmpty)
            padButton("map", L("Minimap"), tint: showMinimap ? .accentColor : .primary) {
                withAnimation(.easeOut(duration: 0.16)) { showMinimap.toggle() }
            }
            // 缩放读数只在不是 100% 时出现：常驻一个「100%」是纯噪音。
            if abs(vp.zoom - 1) > 0.005 {
                // ⚠️ 不用 `.secondary`：在 material 底上它淡到读不出来（用户 2026-08-07 报）。
                // 这是**读数**不是装饰，与按钮同为 `.primary`。
                Text(String(format: "%.0f%%", vp.zoom * 100))
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                    .foregroundStyle(.primary)
                    .transition(.opacity)
            }
            Divider().frame(height: 14)
            padButton("xmark", L("Close Scratchpad (Esc)")) { close() }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().stroke(.white.opacity(0.15), lineWidth: 0.5))
        .shadow(radius: 6, y: 2)
        .padding(.top, topInset + 10)
        .animation(.easeOut(duration: 0.16), value: strokes.isEmpty)
    }

    /// 胶囊里的一枚图标按钮。
    /// ⚠️ **不能用 `.buttonStyle(.borderless)`**：它在 material 底上把图标画得极淡，
    /// 用户 2026-08-07 报「非激活的按钮看不清」就是这个——截图里只有显式染了强调色的那枚看得见。
    /// 一律 `.plain` + 显式 `.primary`（禁用态由系统自己压暗），并给足 24×24 的命中区。
    private func padButton(_ icon: String, _ help: String, tint: Color = .primary,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(tint)
        .help(help)
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
        if showMinimap, !strokes.isEmpty {   // 空纸的缩略图里什么都没有，只是块占地方的噪音
            ScratchMinimap(strokes: strokes, viewport: vp, viewSize: viewSize) { center in
                // 点/拖 minimap → 视口中心跳到那儿。
                vp.origin = CGPoint(x: center.x - viewSize.width / (2 * vp.zoom),
                                    y: center.y - viewSize.height / (2 * vp.zoom))
                clampViewport()
            }
            .frame(width: 176, height: 124)
            .padding(14)
            .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .bottomTrailing)))
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
