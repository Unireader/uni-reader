import SwiftUI
import AppKit   // 仅 NSEvent 监视器（事件管道）；阅读区/覆盖层无 AppKit 视图（红线）
import PDFKit   // 页面底图：取锚定页的显示尺寸 + 走 PageRenderEngine 出图

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
    /// 页图缓存键的文档维度（同阅读区 `ReaderSurface.docKey`）：页面底图与阅读区共用一个渲染引擎，
    /// 键不同源就会各渲各的、白白多一份大图。
    let docKey: String
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
    @State private var showPaper = false   // 纸样选择器（底色 × 底纹）
    // 页面底图（v10）：锚定那一页的页图 + 它是按多宽渲的（缩放跨档才重渲，见 pageStepWidth）
    @State private var pageImage: CGImage?
    @State private var pageImageWidth = 0

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
    private var gridInk: Color { pad.inkIsDark ? .black : .white }
    private var isErasing: Bool { app.pointerTool == .ink && app.padMode == "erase" }
    /// 橡皮在画布坐标下的半径（页宽归一化 → 画布点，三端同一个换算，见 `ScratchPad.eraserRefWidth`）。
    private var eraserCanvasRadius: Double { app.eraserRadius * ScratchPad.eraserRefWidth }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                bg
                ScratchGridLayer(viewport: vp, ink: gridInk, pattern: pad.pattern)   // 定位参照
                // 页面底图（在底纹之上、笔迹之下：它是参照物，墨永远在最上面）。
                // 没有这一页（文档换过/页码越界）就整层不挂——否则纸上会永远糊着一块空白占位。
                if showsPage {
                    ScratchPageLayer(image: pageImage, rect: pageCanvasRect, viewport: vp, ink: gridInk)
                }
                inkLayers
                emptyHint
                eraserRing
                gestureCatcher
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
            .onAppear { place(geo.size); refreshPageImage() }
            .onChange(of: vp.zoom) { _, _ in refreshPageImage() }   // 跨清晰度档才真的重渲
            .onChange(of: pad.showPage) { _, _ in refreshPageImage(); clampViewport() }
            .onChange(of: pad.anchorPage) { _, _ in pageImageWidth = 0; refreshPageImage() }
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
        .onDisappear {
            removeMonitors()
            // 关纸/切纸后这张页图不再需要：撤掉本端的 wanted 声明，别让渲染队列继续为它排队。
            PageRenderEngine.shared.setWanted([], client: pageClientID)
        }
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

    // MARK: 页面底图（v10）
    //
    // 「这张纸挂在哪一页」以前只有那枚图钉知道；开了这个开关，那一页就垫在纸下面当参照。
    // 几何全在 `ScratchPad.pageRect`（三端契约），本段只负责**把图取来**：
    //  · 走阅读区同一个 `PageRenderEngine`（同 docKey 键空间，命中即复用，不多渲一份）；
    //  · **一律 `night: false`**——草稿纸不反色（它是一张纸，不是 PDF 内容）；
    //  · 像素宽按缩放折进固定几档，缩放时不跨档就不重渲（否则捏合每一帧都在排队渲整页）。

    /// 锚定页的显示纵横比（页高/页宽，CropBox 优先 + rotation，与页内笔迹同一个口径）。
    private var pageAspect: Double {
        guard let page = session.pdf?.page(at: pad.anchorPage) else { return 1.4142 }
        let s = PageBitmap.displaySize(page)
        return s.width > 0 ? Double(s.height / s.width) : 1.4142
    }
    /// 页面底图在画布坐标下的矩形（契约见 `ScratchPad.pageRect`）。
    private var pageCanvasRect: CGRect { pad.pageRect(aspect: pageAspect) }
    /// 这张纸锚定的那一页还在不在（文档换过/页码越界时就没有了）。
    private var hasAnchorPage: Bool { session.pdf?.page(at: pad.anchorPage) != nil }
    /// 软边界 / 适应内容 / minimap 共用的「内容」：开着页面底图时它也算内容。
    private var contentBounds: CGRect? {
        ScratchBounds.contentBounds(strokes, page: showsPage ? pageCanvasRect : nil)
    }
    /// 这一刻纸上到底垫没垫页（开关开着 + 那一页确实存在）。
    private var showsPage: Bool { pad.showPage && hasAnchorPage }
    /// 有没有东西可看（空纸 + 没垫页 → minimap 与「适应内容」都无意义）。
    private var hasContent: Bool { !strokes.isEmpty || showsPage }

    /// 页图像素宽：按当前缩放折进固定几档（跨档才重渲，缓存也才有复用）。
    private func pageStepWidth() -> Int {
        let scale = Double(NSScreen.main?.backingScaleFactor ?? 2)
        let need = ScratchPad.pageRefWidth * Double(vp.zoom) * scale
        for w in [768, 1024, 1536, 2048, 3072] where Double(w) >= need { return w }
        return 3072
    }

    /// 按需取页图（缓存命中即同步换上；否则后台渲，回来再原位替换——同阅读区的零闪烁纪律）。
    private func refreshPageImage() {
        guard pad.showPage, let page = session.pdf?.page(at: pad.anchorPage) else {
            if pageImage != nil { pageImage = nil }
            pageImageWidth = 0
            return
        }
        let w = pageStepWidth()
        guard w != pageImageWidth || pageImage == nil else { return }
        let key = PageRenderEngine.baseKey(doc: docKey, page: pad.anchorPage, pixelWidth: w, night: false)
        PageRenderEngine.shared.setWanted([key], client: pageClientID)
        if let hit = PageRenderEngine.shared.cached(key) {
            pageImage = hit; pageImageWidth = w
            return
        }
        let padID = pad.id
        PageRenderEngine.shared.request(.init(key: key, page: page, pixelWidth: w, night: false)) { doneKey, img in
            // ⚠️ 逃逸闭包里的 `pad` 是落笔那一刻的**值拷贝**（同 `isFrontWindow` 记的那个坑）：
            // 图渲完可能已经关了开关/切了纸，判据一律从引用类型 `session` 现读。
            guard doneKey == key, session.openPadID == padID,
                  session.scratchPads.first(where: { $0.id == padID })?.showPage == true else { return }
            pageImage = img; pageImageWidth = w
        }
    }

    /// 页图请求在渲染引擎里的「客户端」名（与阅读区各自一份 wanted 集合，互不覆盖）。
    private var pageClientID: String { "scratchpad-\(session.id)" }

    /// 开/关页面底图。与改名/改纸样同一条路：只改真源，落库 + 广播由 ContentView 的 onChange 接手。
    private func togglePage() {
        guard let i = session.scratchPads.firstIndex(where: { $0.id == pad.id }) else { return }
        session.scratchPads[i].showPage.toggle()
        session.scratchPads[i].updatedAt = .now
    }

    /// 空白纸的引导：一张全白的纸不说话，用户不知道能干嘛。有笔迹后自动消失。
    /// 垫着页面时不出（那时纸上已经有东西看了，这行字只会压在页面上碍事）。
    @ViewBuilder private var emptyHint: some View {
        if strokes.isEmpty, !showsPage, session.scratchLive == nil {
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
                                         content: contentBounds, viewport: viewSize)
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
        vp = ScratchBounds.clamp(vp, content: contentBounds, viewport: viewSize)
    }

    private func recenter() {
        withAnimation(.easeOut(duration: 0.18)) { vp = .centeredOnOrigin(viewport: viewSize) }
    }

    private func fitContent() {
        let target = ScratchBounds.fit(content: contentBounds, viewport: viewSize)
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
                .disabled(!hasContent)
            padButton("map", L("Minimap"), tint: showMinimap ? .accentColor : .primary) {
                withAnimation(.easeOut(duration: 0.16)) { showMinimap.toggle() }
            }
            // 页面底图开关：把这张纸锚定的那一页垫在纸下面（跟着纸走、跨端同步，见 PROTOCOL.md §4.4）
            padButton("doc.text", String(format: L("Show Page %d"), pad.anchorPage + 1),
                      tint: pad.showPage ? .accentColor : .primary) { togglePage() }
                .disabled(session.pdf?.page(at: pad.anchorPage) == nil)
            padButton("paintpalette", L("Paper")) { showPaper.toggle() }
                .popover(isPresented: $showPaper, arrowEdge: .bottom) { paperPicker }
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
        .animation(.easeOut(duration: 0.16), value: hasContent)
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

    /// 纸样选择器：底纹（无/点阵/小格）× 底色（一组预设纸色）。改动写回 `session.scratchPads`，
    /// 由 ContentView 的对账落库 + 广播回平板——与改名走的是同一条路。
    private var paperPicker: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("Pattern")).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                ForEach(ScratchPattern.allCases, id: \.self) { pat in
                    Button { setPaper(pattern: pat) } label: {
                        VStack(spacing: 5) {
                            PaperSwatch(bg: pad.bg, pattern: pat)
                                .frame(width: 52, height: 38)
                            Text(pat.label).font(.caption)
                        }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(pad.pattern == pat ? Color.accentColor : Color.primary)
                }
            }
            Text(L("Paper Color")).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                ForEach(ScratchPad.paperPalette, id: \.key) { item in
                    Button { setPaper(bg: item.color) } label: {
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(Color(nsColor: item.color.nsColor))
                            .frame(width: 26, height: 26)
                            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .stroke(pad.bg == item.color ? Color.accentColor : Color.primary.opacity(0.25),
                                        lineWidth: pad.bg == item.color ? 2 : 0.5))
                    }
                    .buttonStyle(.plain)
                    .help(L(item.name))
                }
            }
        }
        .padding(14)
    }

    /// 改纸样（底纹与底色各自可单独改；不变则不写，免得白白 bump updatedAt 触发一次对账+广播）。
    private func setPaper(bg: InkColor? = nil, pattern: ScratchPattern? = nil) {
        guard let i = session.scratchPads.firstIndex(where: { $0.id == pad.id }) else { return }
        var p = session.scratchPads[i]
        if let bg { p.bg = bg }
        if let pattern { p.pattern = pattern }
        guard p.bg != session.scratchPads[i].bg || p.pattern != session.scratchPads[i].pattern else { return }
        p.updatedAt = .now
        session.scratchPads[i] = p
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
        if showMinimap, hasContent {   // 既没笔迹也没垫页 → 缩略图里什么都没有，只是块占地方的噪音
            ScratchMinimap(strokes: strokes, viewport: vp, viewSize: viewSize,
                           pageRect: showsPage ? pageCanvasRect : nil) { center in
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
                                             content: contentBounds, viewport: viewSize)
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
