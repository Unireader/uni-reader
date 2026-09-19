import AppKit
import Combine
import PDFKit

/// 草稿纸覆盖层（AppKit 版，替代 SwiftUI `ScratchPadOverlay`）：盖在阅读区之上的一张**无限白纸**。
///
/// 交互沿用通用无限画布那套：
///  · 拖动 = 平移；`pointerTool == .ink` 时 = 落墨 / 擦除（与阅读区本机落墨同一个开关）；
///    `.lasso` 时 = 框选移动 / 缩放纸上笔迹（与页内框选同一套规则，坐标是画布点、不夹到 0…1）
///  · 捏合 / ⌘滚轮 = 以指针为锚缩放；普通滚轮 / 双指滑 = 平移（滚轮绝不穿透到下面的 PDF）
///  · 「回中」回到画布原点；「适应内容」装下全部笔迹；右下 minimap 点 / 拖即跳
///  · 软边界 `ScratchBounds`：可视区限制在「内容包围盒 ± 1.5 屏」内，不会一路滑出去找不回来
///
/// 视口是本端私有状态（不落库不上线）；改名 / 纸样 / 页面底图开关只改 `session.scratchPads`，落库与广播由会话那边对账。
@MainActor
final class ScratchPadNSView: NSView {
    let app: AppModel
    let session: DocSession
    let padID: UUID
    let docKey: String
    /// 玻璃工具栏的高度：那一条铺回阅读区底色（白纸压在玻璃工具栏底下，深色外观的白图标就看不见了）。
    var topInset: CGFloat = 0 { didSet { if oldValue != topInset { needsLayout = true } } }

    private var vp = ScratchViewport()
    private var didPlace = false
    private var showMinimap = true
    private var cursor: CGPoint?

    private let grid = ScratchGridCALayer()
    private let pageLayer = ScratchPageCALayer()
    private let inkLayer = ScratchInkCALayer()
    private let liveLayer = ScratchInkCALayer()
    private let lassoLayer = ScratchLassoCALayer()
    private let eraserRing = QuietShapeLayer()
    private let topBand = NSView()
    private let hint = NSStackView()
    private let hintTitle = NSTextField(labelWithString: L("Blank scratchpad"))
    private let hintBody = NSTextField(wrappingLabelWithString: "")
    private let bar = ScratchToolbarView()
    private let minimap = ScratchMinimapView()

    private var pageImage: CGImage?
    private var pageImageWidth = 0

    // 手势
    private enum Drag { case pan(start: CGPoint, mouse: CGPoint), ink, lasso(LassoDragMode) }
    private var drag: Drag?
    private var dragStartView: CGPoint = .zero
    // 框选（瞬态，bounds 记画布坐标）
    private var lassoPath: [CGPoint]?
    private var lassoSel: (ids: Set<UUID>, bounds: CGRect)?
    private var lassoGhost: CGSize = .zero
    private var lassoScale: (sx: CGFloat, sy: CGFloat, handle: LassoHandle)?

    private var bag = Set<AnyCancellable>()
    private var observers: [NSObjectProtocol] = []
    private var keyMonitor: Any?
    private var trackingArea: NSTrackingArea?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    init(app: AppModel, session: DocSession, padID: UUID, docKey: String) {
        self.app = app
        self.session = session
        self.padID = padID
        self.docKey = docKey
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        for l in [grid, pageLayer, inkLayer, liveLayer, lassoLayer] as [CALayer] { layer?.addSublayer(l) }
        eraserRing.fillColor = nil
        eraserRing.lineWidth = 1.5
        layer?.addSublayer(eraserRing)
        topBand.wantsLayer = true
        hintTitle.font = .preferredFont(forTextStyle: .title3)
        hintBody.font = .preferredFont(forTextStyle: .callout)
        hintBody.alignment = .center
        hint.orientation = .vertical
        hint.spacing = 6
        hint.addArrangedSubview(hintTitle)
        hint.addArrangedSubview(hintBody)
        for v in [hint, topBand, bar, minimap] as [NSView] { addSubview(v) }
        buildToolbar()
        minimap.onJump = { [weak self] center in
            guard let self else { return }
            self.vp.origin = CGPoint(x: center.x - self.bounds.width / (2 * self.vp.zoom),
                                     y: center.y - self.bounds.height / (2 * self.vp.zoom))
            self.clampViewport()
            self.viewportChanged()
        }
        installObservers()
        refreshAll()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) 不支持") }

    deinit {
        for o in observers { NotificationCenter.default.removeObserver(o) }
    }

    // MARK: 状态

    private var pad: ScratchPad? { session.scratchPads.first { $0.id == padID } }
    private var padIndex: Int { session.scratchPads.firstIndex { $0.id == padID } ?? 0 }
    private var strokes: [InkStroke] { session.strokes(pad: padID) }
    private var isErasing: Bool { app.pointerTool == .ink && app.padMode == "erase" }
    private var eraserCanvasRadius: Double { app.eraserRadius * ScratchPad.eraserRefWidth }
    /// 这张纸是不是该认领菜单 / 键盘发来的动作：本窗口在前台，且开着的正是这张。
    private var claims: Bool { window?.isKeyWindow == true && session.openPadID == padID }
    private var gridInk: NSColor { (pad?.inkIsDark ?? true) ? .black : .white }
    private var voidColor: NSColor {
        UserDefaults.standard.bool(forKey: "nightMode") ? NSColor(white: 0.06, alpha: 1) : .windowBackgroundColor
    }

    private var pageAspect: Double {
        guard let p = pad, let page = session.pdf?.page(at: p.anchorPage) else { return 1.4142 }
        let s = PageBitmap.displaySize(page, align: session.pageAlign(p.anchorPage))
        return s.width > 0 ? Double(s.height / s.width) : 1.4142
    }
    private var pageCanvasRect: CGRect { pad?.pageRect(aspect: pageAspect) ?? .zero }
    private var showsPage: Bool {
        guard let p = pad else { return false }
        return p.showPage && session.pdf?.page(at: p.anchorPage) != nil
    }
    private var contentBounds: CGRect? { ScratchBounds.contentBounds(strokes, page: showsPage ? pageCanvasRect : nil) }
    private var hasContent: Bool { !strokes.isEmpty || showsPage }

    private func installObservers() {
        session.$scratchStrokes.receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.strokesChanged() }.store(in: &bag)
        session.$scratchLive.receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshLive() }.store(in: &bag)
        session.$scratchPads.receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.padChanged() }.store(in: &bag)
        app.$pointerTool.receive(on: DispatchQueue.main)
            .sink { [weak self] t in
                guard let self else { return }
                if t != .lasso { self.clearLassoSelection() }   // 切走框选工具即放弃选中
                self.refreshHint()
                self.window?.invalidateCursorRects(for: self)
                self.refreshEraserRing()
            }.store(in: &bag)
        app.$padMode.receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshEraserRing() }.store(in: &bag)
        let nc = NotificationCenter.default
        let routes: [(Notification.Name, (ScratchPadNSView) -> Void)] = [
            (.readerUndo, { $0.undoStep(redo: false) }),
            (.readerRedo, { $0.undoStep(redo: true) }),
            (.readerCopy, { $0.copyLassoSelection() }),
            (.readerCut, { $0.cutLassoSelection() }),
            (.readerPaste, { $0.pasteInk() }),
            (.readerDelete, { $0.deleteLassoSelection() }),
        ]
        for (name, act) in routes {
            observers.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.claims else { return }
                    act(self)
                }
            })
        }
        observers.append(nc.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.topBand.layer?.backgroundColor = self?.voidColor.cgColor }
        })
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            installKeyMonitor()
        } else {
            if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
            // 关纸 / 切纸后这张页图不再需要：撤掉本端的 wanted 声明
            PageRenderEngine.shared.setWanted([], client: pageClientID)
        }
    }

    /// Esc = 先清框选选中，没有选中就关纸；⌫ / ⌦ = 删掉框选选中的笔迹（没选中就放行）。
    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.claims, !self.bar.renaming,
                  !(NSApp.keyWindow?.firstResponder is NSText) else { return event }
            switch event.keyCode {
            case 53:
                if self.clearLassoSelection() { return nil }
                self.close()
                return nil
            case 51, 117:
                guard self.lassoSel != nil else { return event }
                self.deleteLassoSelection()
                return nil
            default:
                return event
            }
        }
    }

    // MARK: 刷新

    private func refreshAll() {
        padChanged()
        strokesChanged()
        refreshLive()
        topBand.layer?.backgroundColor = voidColor.cgColor
    }

    private func padChanged() {
        guard let p = pad else { return }
        layer?.backgroundColor = p.bg.nsColor.cgColor
        grid.pattern = p.pattern
        grid.ink = gridInk
        grid.setNeedsDisplay()
        bar.update(title: p.displayName(index: padIndex), showPage: p.showPage,
                   pageEnabled: session.pdf?.page(at: p.anchorPage) != nil, anchorPage: p.anchorPage,
                   showMinimap: showMinimap, hasContent: hasContent, zoom: vp.zoom)
        refreshPageImage()
        layoutPage()
        refreshHint()
        refreshMinimap()
    }

    private func strokesChanged() {
        inkLayer.strokes = strokes
        inkLayer.setNeedsDisplay()
        if let sel = lassoSel {   // 选中项可能已被擦除 / 撤销
            let alive = Set(strokes.map(\.id)).intersection(sel.ids)
            if alive.isEmpty { lassoSel = nil } else if alive.count != sel.ids.count { lassoSel = (alive, sel.bounds) }
        }
        refreshLasso()
        refreshHint()
        refreshMinimap()
        bar.setHasContent(hasContent)
    }

    private func refreshLive() {
        if let live = session.scratchLive, live.padId == padID { liveLayer.strokes = [live] } else { liveLayer.strokes = [] }
        liveLayer.setNeedsDisplay()
        refreshHint()
    }

    /// 空白纸的引导（有笔迹 / 垫着页面 / 正在写时不出）。
    private func refreshHint() {
        let show = strokes.isEmpty && !showsPage && session.scratchLive == nil
        hint.isHidden = !show
        guard show else { return }
        hintBody.stringValue = app.pointerTool == .ink
            ? L("Draw anywhere. Drag with the hand tool to pan, pinch to zoom.")
            : L("Pick the pen in the pen rack to write. Drag to pan, pinch to zoom.")
        let c = gridInk.withAlphaComponent(0.28)
        hintTitle.textColor = c
        hintBody.textColor = c
    }

    private func refreshMinimap() {
        let show = showMinimap && hasContent
        minimap.isHidden = !show
        guard show else { return }
        minimap.strokes = strokes
        minimap.viewport = vp
        minimap.viewSize = bounds.size
        minimap.pageRect = showsPage ? pageCanvasRect : nil
    }

    private func refreshEraserRing() {
        guard isErasing, app.eraserRing, let c = cursor else { eraserRing.isHidden = true; return }
        let r = eraserCanvasRadius * vp.zoom
        eraserRing.isHidden = false
        eraserRing.strokeColor = NSColor.controlAccentColor.cgColor
        eraserRing.path = CGPath(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2), transform: nil)
    }

    /// 视口一变：底纹 / 笔迹 / 页面 / 框选 / 圆环 / minimap / 缩放读数都跟上。
    private func viewportChanged() {
        grid.viewport = vp
        grid.setNeedsDisplay()
        inkLayer.viewport = vp
        inkLayer.setNeedsDisplay()
        liveLayer.viewport = vp
        liveLayer.setNeedsDisplay()
        layoutPage()
        refreshPageImage()
        refreshLasso()
        refreshEraserRing()
        refreshMinimap()
        bar.setZoom(vp.zoom)
    }

    // MARK: 布局

    override func layout() {
        super.layout()
        let b = bounds
        let old = grid.frame.size
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for l in [grid, inkLayer, liveLayer, lassoLayer, eraserRing] as [CALayer] { l.frame = b }
        CATransaction.commit()
        topBand.frame = NSRect(x: 0, y: 0, width: b.width, height: topInset)
        topBand.isHidden = topInset <= 0
        let bs = bar.fittingSize
        bar.frame = NSRect(x: (b.width - bs.width) / 2, y: topInset + 10, width: bs.width, height: bs.height)
        minimap.frame = NSRect(x: b.width - 14 - 176, y: b.height - 14 - 124, width: 176, height: 124)
        let hs = hint.fittingSize
        hint.frame = NSRect(x: (b.width - min(hs.width, b.width - 40)) / 2, y: (b.height - hs.height) / 2,
                            width: min(hs.width, b.width - 40), height: hs.height)
        if !didPlace, b.width > 1, b.height > 1 {
            // 打开 = 回到画布原点（「从该处显示」）
            didPlace = true
            vp = .centeredOnOrigin(viewport: b.size)
        } else if didPlace, old.width > 1, old.height > 1, old != b.size {
            // 窗口缩放：保持画布中心不动
            vp.origin.x += (old.width - b.width) / (2 * vp.zoom)
            vp.origin.y += (old.height - b.height) / (2 * vp.zoom)
            clampViewport()
        }
        viewportChanged()
    }

    private func layoutPage() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        guard showsPage else { pageLayer.isHidden = true; return }
        let r = pageCanvasRect, o = vp.origin, z = vp.zoom
        pageLayer.isHidden = false
        pageLayer.set(image: pageImage,
                      frame: CGRect(x: (r.minX - o.x) * z, y: (r.minY - o.y) * z, width: r.width * z, height: r.height * z),
                      ink: gridInk)
    }

    private func clampViewport() {
        vp = ScratchBounds.clamp(vp, content: contentBounds, viewport: bounds.size)
    }

    // MARK: 页面底图（走阅读区同一个渲染引擎；一律不反色；像素宽按缩放折进几档，跨档才重渲）

    private var pageClientID: String { "scratchpad-\(session.id)" }

    private func pageStepWidth() -> Int {
        let scale = Double(window?.backingScaleFactor ?? 2)
        let need = ScratchPad.pageRefWidth * Double(vp.zoom) * scale
        for w in [768, 1024, 1536, 2048, 3072] where Double(w) >= need { return w }
        return 3072
    }

    private func refreshPageImage() {
        guard let p = pad, p.showPage, let page = session.pdf?.page(at: p.anchorPage) else {
            pageImage = nil
            pageImageWidth = 0
            return
        }
        let w = pageStepWidth()
        guard w != pageImageWidth || pageImage == nil else { return }
        let key = PageRenderEngine.baseKey(doc: docKey, page: p.anchorPage, pixelWidth: w, night: false)
        PageRenderEngine.shared.setWanted([key], client: pageClientID)
        if let hit = PageRenderEngine.shared.cached(key) {
            pageImage = hit
            pageImageWidth = w
            layoutPage()
            return
        }
        PageRenderEngine.shared.request(.init(key: key, page: page, pixelWidth: w, night: false,
                                              align: session.pageAlign(p.anchorPage))) { [weak self] doneKey, img in
            guard let self, doneKey == key, self.session.openPadID == self.padID, self.pad?.showPage == true else { return }
            self.pageImage = img
            self.pageImageWidth = w
            self.layoutPage()
        }
    }

    // MARK: 工具条

    private func buildToolbar() {
        bar.onRename = { [weak self] t in self?.commitRename(t) }
        bar.onRecenter = { [weak self] in self?.animateViewport(to: .centeredOnOrigin(viewport: self?.bounds.size ?? .zero)) }
        bar.onFit = { [weak self] in
            guard let self else { return }
            self.animateViewport(to: ScratchBounds.fit(content: self.contentBounds, viewport: self.bounds.size))
        }
        bar.onToggleMinimap = { [weak self] in
            guard let self else { return }
            self.showMinimap.toggle()
            self.padChanged()
        }
        bar.onTogglePage = { [weak self] in self?.togglePage() }
        bar.onPaper = { [weak self] anchor in self?.showPaperPicker(from: anchor) }
        bar.onClose = { [weak self] in self?.close() }
    }

    private var viewportAnim: (from: ScratchViewport, to: ScratchViewport, start: CFTimeInterval)?
    private var animLink: CADisplayLink?

    /// 回中 / 适应内容：0.18s 缓出过渡（逐帧改视口，整层重画）。
    private func animateViewport(to target: ScratchViewport) {
        viewportAnim = (vp, target, CACurrentMediaTime())
        if animLink == nil {
            let link = displayLink(target: self, selector: #selector(animStep))
            link.add(to: .main, forMode: .common)
            animLink = link
        }
    }

    @objc private func animStep() {
        guard let a = viewportAnim else { animLink?.invalidate(); animLink = nil; return }
        let t = min(1, (CACurrentMediaTime() - a.start) / 0.18)
        let e = 1 - pow(1 - t, 3)
        vp = ScratchViewport(origin: CGPoint(x: a.from.origin.x + (a.to.origin.x - a.from.origin.x) * e,
                                             y: a.from.origin.y + (a.to.origin.y - a.from.origin.y) * e),
                             zoom: a.from.zoom + (a.to.zoom - a.from.zoom) * e)
        viewportChanged()
        if t >= 1 {
            viewportAnim = nil
            animLink?.invalidate()
            animLink = nil
        }
    }

    private func togglePage() {
        guard let i = session.scratchPads.firstIndex(where: { $0.id == padID }) else { return }
        session.scratchPads[i].showPage.toggle()
        session.scratchPads[i].updatedAt = .now
        pageImageWidth = 0
        clampViewport()
        viewportChanged()
    }

    private func commitRename(_ title: String) {
        guard let i = session.scratchPads.firstIndex(where: { $0.id == padID }) else { return }
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t != session.scratchPads[i].title else { return }
        session.scratchPads[i].title = t
        session.scratchPads[i].updatedAt = .now
    }

    /// 改纸样（底纹与底色各自可单独改；不变则不写，免得白白触发一次对账 + 广播）。
    private func setPaper(bg: InkColor? = nil, pattern: ScratchPattern? = nil) {
        guard let i = session.scratchPads.firstIndex(where: { $0.id == padID }) else { return }
        var p = session.scratchPads[i]
        if let bg { p.bg = bg }
        if let pattern { p.pattern = pattern }
        guard p.bg != session.scratchPads[i].bg || p.pattern != session.scratchPads[i].pattern else { return }
        p.updatedAt = .now
        session.scratchPads[i] = p
    }

    private var paperPopover: NSPopover?

    /// 纸样选择器：底纹（无 / 点阵 / 小格）× 底色（一组预设纸色）。
    private func showPaperPicker(from anchor: NSView) {
        guard let p = pad else { return }
        let root = PaperPickerView(bg: p.bg, pattern: p.pattern)
        root.onPattern = { [weak self] pat in self?.setPaper(pattern: pat) }
        root.onColor = { [weak self] c in self?.setPaper(bg: c) }
        let vc = NSViewController()
        vc.view = root
        let pop = NSPopover()
        pop.contentViewController = vc
        pop.behavior = .transient
        pop.contentSize = root.frame.size
        paperPopover = pop
        pop.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
        session.$scratchPads.receive(on: DispatchQueue.main)
            .sink { [weak self, weak root] _ in
                guard let root, let p = self?.pad else { return }
                root.update(bg: p.bg, pattern: p.pattern)
            }
            .store(in: &bag)
    }

    private func close() {
        app.scratchInkCancel(in: session)
        session.openPadID = nil
    }

    // MARK: 指针 / 光标

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = trackingArea { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .cursorUpdate,
                                                     .activeInActiveApp, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(t)
        trackingArea = t
    }

    override func mouseMoved(with event: NSEvent) {
        cursor = convert(event.locationInWindow, from: nil)
        refreshEraserRing()
    }
    override func mouseExited(with event: NSEvent) {
        cursor = nil
        refreshEraserRing()
    }

    /// 光标反馈：十字 = 会落墨，箭头 = 框选，手型 = 拖动即平移。
    override func cursorUpdate(with event: NSEvent) { currentCursor().set() }
    private func currentCursor() -> NSCursor {
        switch app.pointerTool {
        case .ink: return .crosshair
        case .lasso: return .arrow
        default:
            if case .pan = drag { return .closedHand }
            return .openHand
        }
    }

    // MARK: 滚轮 / 捏合

    override func scrollWheel(with event: NSEvent) {
        var dx = event.scrollingDeltaX, dy = event.scrollingDeltaY
        if !event.hasPreciseScrollingDeltas { dx *= 10; dy *= 10 }
        if event.modifierFlags.contains(.command) {
            guard dy != 0, event.momentumPhase == [] else { return }
            let factor = min(max(exp(-dy * 0.008), 0.5), 2)   // 手感旋钮同阅读区 ⌘滚轮
            let anchor = convert(event.locationInWindow, from: nil)
            vp = ScratchBounds.clamp(vp.zoomed(by: factor, anchorScreen: anchor), content: contentBounds, viewport: bounds.size)
            viewportChanged()
            return
        }
        guard dx != 0 || dy != 0 else { return }
        vp.origin = CGPoint(x: vp.origin.x - dx / vp.zoom, y: vp.origin.y - dy / vp.zoom)
        clampViewport()
        viewportChanged()
    }

    override func magnify(with event: NSEvent) {
        let anchor = convert(event.locationInWindow, from: nil)
        vp = ScratchBounds.clamp(vp.zoomed(by: 1 + event.magnification, anchorScreen: anchor),
                                 content: contentBounds, viewport: bounds.size)
        viewportChanged()
    }

    // MARK: 拖动（平移 / 落墨 / 框选）

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let p = convert(event.locationInWindow, from: nil)
        dragStartView = p
        cursor = p
        switch app.pointerTool {
        case .ink:
            drag = .ink
            let c = vp.toCanvas(p)
            let start = InkPoint(Double(c.x), Double(c.y), 0.5)
            if isErasing {
                app.scratchErase([start], in: session)
            } else {
                guard let pen = app.pens.indices.contains(app.padPenIndex) ? app.pens[app.padPenIndex] : app.pens.first
                else { drag = nil; return }
                app.scratchInkBegin(in: session, pad: padID, color: pen.color, width: pen.width, type: pen.type, points: [start])
            }
        case .lasso:
            drag = .lasso(lassoBeginMode(at: p))
        case .textSelect, .snip:
            // 框选截图在草稿纸上不适用（纸上没有 PDF 页可重渲），当平移处理
            drag = .pan(start: vp.origin, mouse: p)
            NSCursor.closedHand.set()
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        cursor = p
        switch drag {
        case .pan(let start, let mouse):
            vp.origin = CGPoint(x: start.x - (p.x - mouse.x) / vp.zoom, y: start.y - (p.y - mouse.y) / vp.zoom)
            clampViewport()
            viewportChanged()
        case .ink:
            let c = vp.toCanvas(p)
            let pt = InkPoint(Double(c.x), Double(c.y), 0.5)
            if isErasing {
                app.scratchErase([pt], in: session)
                refreshEraserRing()
            } else if event.modifierFlags.contains(.shift) {
                // ⇧ 尺子：整笔替换为「起点 → 45° 吸附终点」两点直线（画布等比 → aspect = 1）
                guard let live = session.scratchLive, let a = live.points.first else { return }
                let s = InkEdit.rulerSnap(start: SIMD2(a.dx, a.dy), current: SIMD2(pt.dx, pt.dy), aspect: 1)
                app.scratchInkLineTo(InkPoint(s.x, s.y, 0.5), in: session)
            } else {
                app.scratchInkAppend([pt], in: session)
            }
        case .lasso(let mode):
            lassoDragged(mode, to: p, shift: event.modifierFlags.contains(.shift))
        case nil:
            break
        }
    }

    override func mouseUp(with event: NSEvent) {
        let d = drag
        drag = nil
        switch d {
        case .ink:
            if !isErasing { app.scratchInkEnd(in: session) }   // 擦除每批即时生效，无需收尾
            session.scratchUndo.seal()                          // 抬笔 = 这一组擦除封口
        case .lasso(let mode):
            lassoEnded(mode)
        default:
            break
        }
        window?.invalidateCursorRects(for: self)
        currentCursor().set()
    }

    // MARK: 右键菜单（有选中集给四项；没有就只给「粘贴」）

    override func menu(for event: NSEvent) -> NSMenu? {
        cursor = convert(event.locationInWindow, from: nil)
        let m = NSMenu()
        let paste = ClosureMenuItem(L("Paste"), action: { [weak self] in self?.pasteInk() })
        if !InkClipboard.hasInk() { paste.action = nil }
        if lassoSel != nil {
            m.addItem(ClosureMenuItem(L("Cut"), action: { [weak self] in self?.cutLassoSelection() }))
            m.addItem(ClosureMenuItem(L("Copy"), action: { [weak self] in self?.copyLassoSelection() }))
            m.addItem(paste)
            m.addItem(ClosureMenuItem(L("Delete"), action: { [weak self] in self?.deleteLassoSelection() }))
        } else {
            m.addItem(paste)
        }
        return m
    }
}

// MARK: - 框选（画布坐标、无 0…1 夹取；缩放线宽 ×√(sx·sy) 夹 0.5…40，与页内 `InkEdit.scaled` 同语义）

extension ScratchPadNSView {
    private func strokeBounds(_ st: InkStroke) -> CGRect {
        var lo = SIMD2<Double>(.infinity, .infinity), hi = SIMD2<Double>(-.infinity, -.infinity)
        for p in st.points {
            lo = SIMD2(min(lo.x, p.dx), min(lo.y, p.dy))
            hi = SIMD2(max(hi.x, p.dx), max(hi.y, p.dy))
        }
        return CGRect(x: lo.x, y: lo.y, width: hi.x - lo.x, height: hi.y - lo.y)
    }

    /// 选中集显示框（视图坐标）：画布包围盒映到视口，外扩 6pt、最小 16pt（极薄笔迹也有得抓）。
    private func displayBox(_ b: CGRect) -> CGRect {
        let z = vp.zoom
        let r = CGRect(x: (b.minX - vp.origin.x) * z, y: (b.minY - vp.origin.y) * z, width: b.width * z, height: b.height * z)
        let box = r.insetBy(dx: -6, dy: -6)
        let w = max(box.width, 16), h = max(box.height, 16)
        return CGRect(x: box.midX - w / 2, y: box.midY - h / 2, width: w, height: h)
    }

    private func ghostPoint(_ p: CGPoint, in box: CGRect) -> CGPoint {
        if let gs = lassoScale {
            let a = gs.handle.opposite.point(in: box)
            return CGPoint(x: a.x + (p.x - a.x) * gs.sx, y: a.y + (p.y - a.y) * gs.sy)
        }
        return CGPoint(x: p.x + lassoGhost.width, y: p.y + lassoGhost.height)
    }

    /// 起点一次性判定：手柄（10pt）= 缩放；框内（含 8pt 余量）= 移动；否则 = 重新框选（顺带清掉旧选中）。
    fileprivate func lassoBeginMode(at p: CGPoint) -> LassoDragMode {
        if let sel = lassoSel {
            let box = displayBox(sel.bounds)
            if let h = LassoHandle.allCases.first(where: { let q = $0.point(in: box); return hypot(p.x - q.x, p.y - q.y) <= 10 }) {
                return .scale(h)
            }
            if box.insetBy(dx: -8, dy: -8).contains(p) { return .move }
        }
        lassoSel = nil
        lassoPath = [p]
        refreshLasso()
        return .select
    }

    fileprivate func lassoDragged(_ mode: LassoDragMode, to p: CGPoint, shift: Bool) {
        switch mode {
        case .select:
            if let last = lassoPath?.last, hypot(p.x - last.x, p.y - last.y) >= 3 { lassoPath?.append(p) }
        case .move:
            lassoGhost = CGSize(width: p.x - dragStartView.x, height: p.y - dragStartView.y)
        case .scale(let handle):
            updateScaleGhost(handle: handle, to: p, shift: shift)
        }
        refreshLasso()
    }

    /// 角手柄等比（⇧ 放开两轴）、边中点单轴，夹 0.05…20。
    private func updateScaleGhost(handle: LassoHandle, to p: CGPoint, shift: Bool) {
        guard let sel = lassoSel else { return }
        let box = displayBox(sel.bounds)
        let anchor = handle.opposite.point(in: box), start = handle.point(in: box)
        let dX = start.x - anchor.x, dY = start.y - anchor.y
        var sx: CGFloat = 1, sy: CGFloat = 1
        switch handle {
        case .t, .b:
            guard abs(dY) > 1 else { return }
            sy = (p.y - anchor.y) / dY
        case .l, .r:
            guard abs(dX) > 1 else { return }
            sx = (p.x - anchor.x) / dX
        case .tl, .tr, .bl, .br:
            guard abs(dX) > 1, abs(dY) > 1 else { return }
            sx = (p.x - anchor.x) / dX
            sy = (p.y - anchor.y) / dY
            if !shift {
                let s = abs(sx - 1) >= abs(sy - 1) ? sx : sy
                sx = s; sy = s
            }
        }
        func cl(_ s: CGFloat) -> CGFloat { min(20, max(0.05, s)) }
        lassoScale = (cl(sx), cl(sy), handle)
    }

    /// 松手一次性提交（移动 / 缩放）或结算选中（框选）：数据在拖动全程不动。
    fileprivate func lassoEnded(_ mode: LassoDragMode) {
        let path = lassoPath, ghost = lassoGhost, gs = lassoScale
        lassoPath = nil
        lassoGhost = .zero
        lassoScale = nil
        switch mode {
        case .select: if let path { finishLassoSelect(path: path) }
        case .move: commitLassoMove(ghost)
        case .scale: if let gs { commitLassoScale(gs) }
        }
        refreshLasso()
    }

    private func finishLassoSelect(path: [CGPoint]) {
        guard path.count >= 3 else { return }
        let poly = path.map { p -> SIMD2<Double> in let c = vp.toCanvas(p); return SIMD2(Double(c.x), Double(c.y)) }
        var ids = Set<UUID>()
        var bbox = CGRect.null
        for st in strokes where st.points.contains(where: { InkEdit.pointInPolygon(SIMD2($0.dx, $0.dy), polygon: poly) }) {
            ids.insert(st.id)
            bbox = bbox.union(strokeBounds(st))
        }
        guard !ids.isEmpty else { return }
        lassoSel = (ids, bbox)
    }

    private func shifted(_ s: InkStroke, dx: Double, dy: Double) -> InkStroke {
        var t = s
        t.points = s.points.map { InkPoint($0.dx + dx, $0.dy + dy, $0.dz) }
        return t
    }

    private func scaled(_ s: InkStroke, anchor a: SIMD2<Double>, sx: Double, sy: Double) -> InkStroke {
        var t = s
        t.points = s.points.map { InkPoint(a.x + ($0.dx - a.x) * sx, a.y + ($0.dy - a.y) * sy, $0.dz) }
        t.width = min(40, max(0.5, s.width * (sx * sy).squareRoot()))
        return t
    }

    private func commitLassoMove(_ t: CGSize) {
        guard let sel = lassoSel else { return }
        let dx = Double(t.width / vp.zoom), dy = Double(t.height / vp.zoom)
        guard dx != 0 || dy != 0 else { return }
        var changed = false
        session.scratchEdit("Move", kind: .move) {
            for i in session.scratchStrokes.indices where sel.ids.contains(session.scratchStrokes[i].id) {
                session.scratchStrokes[i] = shifted(session.scratchStrokes[i], dx: dx, dy: dy)
                changed = true
            }
        }
        lassoSel = changed ? (sel.ids, sel.bounds.offsetBy(dx: dx, dy: dy)) : nil
    }

    private func commitLassoScale(_ gs: (sx: CGFloat, sy: CGFloat, handle: LassoHandle)) {
        guard let sel = lassoSel else { return }
        let sx = Double(gs.sx), sy = Double(gs.sy)
        guard sx != 1 || sy != 1 else { return }
        let ac = vp.toCanvas(gs.handle.opposite.point(in: displayBox(sel.bounds)))
        let a = SIMD2(Double(ac.x), Double(ac.y))
        var changed = false
        session.scratchEdit("Resize", kind: .scale) {
            for i in session.scratchStrokes.indices where sel.ids.contains(session.scratchStrokes[i].id) {
                session.scratchStrokes[i] = scaled(session.scratchStrokes[i], anchor: a, sx: sx, sy: sy)
                changed = true
            }
        }
        guard changed else { lassoSel = nil; return }
        let b = sel.bounds
        let x1 = a.x + (Double(b.minX) - a.x) * sx, x2 = a.x + (Double(b.maxX) - a.x) * sx
        let y1 = a.y + (Double(b.minY) - a.y) * sy, y2 = a.y + (Double(b.maxY) - a.y) * sy
        lassoSel = (sel.ids, CGRect(x: min(x1, x2), y: min(y1, y2), width: abs(x2 - x1), height: abs(y2 - y1)))
    }

    // MARK: 剪切 / 复制 / 粘贴 / 删除 / 撤销（与阅读区共用 `InkClipboard`，跨空间由它折算坐标）

    @discardableResult
    func copyLassoSelection() -> Bool {
        guard let sel = lassoSel else { return false }
        let picked = strokes.filter { sel.ids.contains($0.id) }
        guard !picked.isEmpty else { return false }
        InkClipboard.write(strokes: picked, space: .canvas)
        return true
    }

    func cutLassoSelection() {
        guard copyLassoSelection() else { return }
        deleteLassoSelection()
    }

    /// 粘贴到纸上：落点 = 指针处（没有指针就落视口正中）；从页里抄来的先按源页纵横比折成画布点。粘完即选中 + 切到框选。
    func pasteInk() {
        guard let clip = InkClipboard.read(), !clip.strokes.isEmpty else { return }
        let src = clip.space == .page ? InkClipboard.scaled(clip.strokes, toCanvas: true, aspect: clip.aspect) : clip.strokes
        var box = CGRect.null
        for st in src { box = box.union(strokeBounds(st)) }
        guard !box.isNull else { return }
        let target = vp.toCanvas(cursor ?? CGPoint(x: bounds.midX, y: bounds.midY))
        let dx = Double(target.x - box.midX), dy = Double(target.y - box.midY)
        var ids = Set<UUID>()
        var placed = CGRect.null
        session.scratchEdit("Paste", kind: .paste) {
            for st0 in src {
                var st = shifted(st0, dx: dx, dy: dy)
                st.padId = padID
                st.page = 0
                session.scratchStrokes.append(st)
                ids.insert(st.id)
                placed = placed.union(strokeBounds(st))
            }
        }
        guard !ids.isEmpty else { return }
        app.pointerTool = .lasso
        lassoSel = (ids, placed)
        refreshLasso()
    }

    func deleteLassoSelection() {
        guard let sel = lassoSel else { return }
        session.scratchEdit("Delete", kind: .delete) {
            session.scratchStrokes.removeAll { sel.ids.contains($0.id) }
        }
        clearLassoSelection()
    }

    func undoStep(redo: Bool) {
        clearLassoSelection()
        app.undoScratch(in: session, redo: redo)
    }

    @discardableResult
    func clearLassoSelection() -> Bool {
        let had = lassoSel != nil || lassoPath != nil
        lassoSel = nil
        lassoPath = nil
        lassoGhost = .zero
        lassoScale = nil
        refreshLasso()
        return had
    }

    /// 选中光晕（随 ghost 变换 = 预览即提交结果）+ 高亮框 / 手柄 + 进行中的虚线路径。
    fileprivate func refreshLasso() {
        if let sel = lassoSel {
            let box = displayBox(sel.bounds)
            let z = vp.zoom, o = vp.origin
            lassoLayer.halo = strokes.filter { sel.ids.contains($0.id) }.map { st in
                let pts = st.points.map { ghostPoint(CGPoint(x: (CGFloat($0.x) - o.x) * z, y: (CGFloat($0.y) - o.y) * z), in: box) }
                let w = st.points.count == 1
                    ? CGFloat(st.type.strokeWidth(pressure: st.points[0].dz, base: st.width)) * z + 5
                    : CGFloat(st.width) * z + 5
                return (pts, w)
            }
            let pts = LassoHandle.allCases.map { ghostPoint($0.point(in: box), in: box) }
            let lo = pts.reduce(pts[0]) { CGPoint(x: min($0.x, $1.x), y: min($0.y, $1.y)) }
            let hi = pts.reduce(pts[0]) { CGPoint(x: max($0.x, $1.x), y: max($0.y, $1.y)) }
            lassoLayer.box = CGRect(x: lo.x, y: lo.y, width: hi.x - lo.x, height: hi.y - lo.y)
            lassoLayer.handles = pts
        } else {
            lassoLayer.halo = []
            lassoLayer.box = nil
            lassoLayer.handles = []
        }
        lassoLayer.path = lassoPath ?? []
        lassoLayer.setNeedsDisplay()
    }
}

// MARK: - 工具条（浮在纸上的胶囊：名字（点击改名）| 回中 · 适应内容 · minimap · 页面底图 · 纸样 · 缩放读数 | 关闭）

final class ScratchToolbarView: NSView, NSTextFieldDelegate {
    var onRename: (String) -> Void = { _ in }
    var onRecenter: () -> Void = {}
    var onFit: () -> Void = {}
    var onToggleMinimap: () -> Void = {}
    var onTogglePage: () -> Void = {}
    var onPaper: (NSView) -> Void = { _ in }
    var onClose: () -> Void = {}
    private(set) var renaming = false

    private let capsule = CapsuleMaterialView()
    private let stack = NSStackView()
    private let titleButton = NSButton()
    private let titleField = NSTextField()
    private var recenter: NSButton!
    private var fit: NSButton!
    private var minimapBtn: NSButton!
    private var pageBtn: NSButton!
    private var paperBtn: NSButton!
    private let zoomLabel = NSTextField(labelWithString: "")
    private let actions = ButtonActions()

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        shadow = {
            let s = NSShadow()
            s.shadowColor = NSColor.black.withAlphaComponent(0.3)
            s.shadowBlurRadius = 6
            s.shadowOffset = NSSize(width: 0, height: -2)
            return s
        }()
        addSubview(capsule)
        titleButton.isBordered = false
        titleButton.image = NSImage(systemSymbolName: "square.and.pencil", accessibilityDescription: nil)
        titleButton.imagePosition = .imageLeading
        titleButton.contentTintColor = .labelColor
        titleButton.toolTip = L("Click to rename")
        titleButton.lineBreakMode = .byTruncatingTail
        actions.bind(titleButton) { [weak self] in self?.beginRename() }
        titleField.placeholderString = L("Name")
        titleField.isBordered = false
        titleField.drawsBackground = false
        titleField.focusRingType = .none
        titleField.delegate = self
        titleField.isHidden = true
        titleField.widthAnchor.constraint(equalToConstant: 150).isActive = true
        recenter = icon("scope", L("Recenter")) { [weak self] in self?.onRecenter() }
        fit = icon("arrow.up.left.and.arrow.down.right", L("Fit Content")) { [weak self] in self?.onFit() }
        minimapBtn = icon("map", L("Minimap")) { [weak self] in self?.onToggleMinimap() }
        pageBtn = icon("doc.text", "") { [weak self] in self?.onTogglePage() }
        paperBtn = icon("paintpalette", L("Paper")) { [weak self] in
            guard let self else { return }
            self.onPaper(self.paperBtn)
        }
        zoomLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        zoomLabel.textColor = .labelColor   // 读数不是装饰：材质底上别用次要色
        let close = icon("xmark", L("Close Scratchpad (Esc)")) { [weak self] in self?.onClose() }
        for v in [titleButton, titleField, divider(), recenter, fit, minimapBtn, pageBtn, paperBtn, zoomLabel, divider(), close] as [NSView] {
            stack.addArrangedSubview(v)
        }
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 7, left: 12, bottom: 7, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        capsule.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: capsule.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: capsule.trailingAnchor),
            stack.topAnchor.constraint(equalTo: capsule.topAnchor),
            stack.bottomAnchor.constraint(equalTo: capsule.bottomAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) 不支持") }

    override var fittingSize: NSSize { stack.fittingSize }

    override func layout() {
        super.layout()
        capsule.frame = bounds
    }

    private func divider() -> NSView {
        let b = NSBox()
        b.boxType = .separator
        b.translatesAutoresizingMaskIntoConstraints = false
        b.widthAnchor.constraint(equalToConstant: 1).isActive = true
        b.heightAnchor.constraint(equalToConstant: 14).isActive = true
        return b
    }

    /// 胶囊里的一枚图标按钮：无边框 + 显式主色（材质底上 `.borderless` 会把图标画得极淡），24×24 命中区。
    private func icon(_ symbol: String, _ tip: String, _ action: @escaping () -> Void) -> NSButton {
        let b = NSButton()
        b.isBordered = false
        b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .medium))
        b.imagePosition = .imageOnly
        b.contentTintColor = .labelColor
        b.toolTip = tip
        b.translatesAutoresizingMaskIntoConstraints = false
        b.widthAnchor.constraint(equalToConstant: 24).isActive = true
        b.heightAnchor.constraint(equalToConstant: 24).isActive = true
        actions.bind(b, action)
        return b
    }

    func update(title: String, showPage: Bool, pageEnabled: Bool, anchorPage: Int,
                showMinimap: Bool, hasContent: Bool, zoom: CGFloat) {
        if !renaming, titleButton.title != title {
            titleButton.title = title
            needsLayoutInSuperview()
        }
        minimapBtn.contentTintColor = showMinimap ? .controlAccentColor : .labelColor
        pageBtn.contentTintColor = showPage ? .controlAccentColor : .labelColor
        pageBtn.toolTip = String(format: L("Show Page %d"), anchorPage + 1)
        pageBtn.isEnabled = pageEnabled
        setHasContent(hasContent)
        setZoom(zoom)
    }

    func setHasContent(_ v: Bool) { fit.isEnabled = v }

    /// 缩放读数只在不是 100% 时出现（常驻一个「100%」是纯噪音）。
    func setZoom(_ z: CGFloat) {
        let hide = abs(z - 1) <= 0.005
        let text = String(format: "%.0f%%", z * 100)
        if zoomLabel.isHidden != hide || zoomLabel.stringValue != text {
            zoomLabel.isHidden = hide
            zoomLabel.stringValue = text
            needsLayoutInSuperview()
        }
    }

    private func needsLayoutInSuperview() { superview?.needsLayout = true }

    private func beginRename() {
        renaming = true
        titleField.stringValue = titleButton.title
        titleButton.isHidden = true
        titleField.isHidden = false
        window?.makeFirstResponder(titleField)
        needsLayoutInSuperview()
    }

    private func endRename(commit: Bool) {
        guard renaming else { return }
        renaming = false
        if commit { onRename(titleField.stringValue) }
        titleField.isHidden = true
        titleButton.isHidden = false
        needsLayoutInSuperview()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        if sel == #selector(NSResponder.insertNewline(_:)) { endRename(commit: true); return true }
        if sel == #selector(NSResponder.cancelOperation(_:)) { endRename(commit: false); return true }
        return false
    }

    func controlTextDidEndEditing(_ obj: Notification) { endRename(commit: true) }
}

// MARK: - 纸样选择器

final class PaperPickerView: NSView {
    var onPattern: (ScratchPattern) -> Void = { _ in }
    var onColor: (InkColor) -> Void = { _ in }
    private var patternSwatches: [(ScratchPattern, PaperSwatchView, NSTextField)] = []
    private var colorSwatches: [(InkColor, PaperSwatchView)] = []

    override var isFlipped: Bool { true }

    init(bg: InkColor, pattern: ScratchPattern) {
        let patterns = ScratchPattern.allCases, colors = ScratchPad.paperPalette
        let width = max(CGFloat(patterns.count) * 60, CGFloat(colors.count) * 34) + 20
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 170))
        let h1 = NSTextField(labelWithString: L("Pattern"))
        h1.font = .systemFont(ofSize: NSFont.preferredFont(forTextStyle: .subheadline).pointSize, weight: .semibold)
        h1.textColor = .secondaryLabelColor
        h1.frame = NSRect(x: 14, y: 14, width: width - 28, height: 18)
        addSubview(h1)
        for (i, pat) in patterns.enumerated() {
            let sw = PaperSwatchView(frame: NSRect(x: 14 + CGFloat(i) * 60, y: 38, width: 52, height: 38))
            let cap = NSTextField(labelWithString: pat.label)
            cap.font = .preferredFont(forTextStyle: .caption1)
            cap.alignment = .center
            cap.frame = NSRect(x: sw.frame.minX - 4, y: 81, width: 60, height: 16)
            addSubview(sw)
            addSubview(cap)
            patternSwatches.append((pat, sw, cap))
        }
        let h2 = NSTextField(labelWithString: L("Paper Color"))
        h2.font = h1.font
        h2.textColor = .secondaryLabelColor
        h2.frame = NSRect(x: 14, y: 106, width: width - 28, height: 18)
        addSubview(h2)
        for (i, item) in colors.enumerated() {
            let sw = PaperSwatchView(frame: NSRect(x: 14 + CGFloat(i) * 34, y: 130, width: 26, height: 26))
            sw.pattern = .plain
            sw.bg = item.color
            sw.toolTip = L(item.name)
            addSubview(sw)
            colorSwatches.append((item.color, sw))
        }
        update(bg: bg, pattern: pattern)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) 不支持") }

    func update(bg: InkColor, pattern: ScratchPattern) {
        for (pat, sw, cap) in patternSwatches {
            sw.bg = bg
            sw.pattern = pat
            sw.selected = pat == pattern
            cap.textColor = pat == pattern ? .controlAccentColor : .labelColor
        }
        for (c, sw) in colorSwatches { sw.selected = c == bg }
    }

    override func mouseUp(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let hit = patternSwatches.first(where: { $0.1.frame.insetBy(dx: -4, dy: -4).contains(p) }) { onPattern(hit.0); return }
        if let hit = colorSwatches.first(where: { $0.1.frame.insetBy(dx: -3, dy: -3).contains(p) }) { onColor(hit.0) }
    }
}
