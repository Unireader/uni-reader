import AppKit
import Combine

/// 画布悬浮「笔架」（AppKit 版，替代 SwiftUI `PenRackView`）：收藏笔插槽（点当前笔 = 实时改颜色 / 粗细 / 类型）
/// + 加笔 + 橡皮 / 翻页 + 本机笔 / 框选 / 截图 + 图层。
///
/// 作用域：笔、平板模式、本机指针工具都是设备级全局状态（`AppModel`）；图层是当前文档自己的（`DocSession`）。
/// 位置 / 收起态走全局偏好（旧键名 `penToolbar*` 不动），多窗口一致。
///
/// **收起 = 只有一排内容、只有一条裁剪边界**：整排格子往左推，把「当前在用的那一格」顶到取景窗最左，
/// 取景窗收成一格宽——格子本身从头到尾不重建、不淡化（SwiftUI 版反复试出来的做法，两态互换会闪）。
///
/// 位置：存胶囊**左上缘**占视口宽高的比例；没拖过时横向居中现算。整个胶囊夹在阅读区里，上沿不进工具栏、
/// 下沿不压标签栏。拖动从任何地方起手都行（含按钮上：挪过 6pt 才算拖，否则是点击）。
@MainActor
final class PenRackNSView: NSView {
    let app: AppModel
    private(set) var session: DocSession

    private enum K {
        static let fx = "penToolbarFracX", fy = "penToolbarFracY"
        static let moved = "penToolbarMoved"
        static let collapsed = "penToolbarCollapsed"
    }
    private static let keepW: CGFloat = 28
    private static let gap: CGFloat = 10
    private static let height: CGFloat = 44
    private static let edgeMargin: CGFloat = 6

    private let shell = NSVisualEffectView()
    private let grip = NSImageView()
    private let window_ = NSView()          // 取景窗（唯一的裁剪边界）
    private let row = FlippedView()          // 整排格子
    private let toggle = RackChevronCell()
    private var penCells: [RackPenCell] = []
    private let addCell = RackIconCell(symbol: "plus.circle.fill", width: 26)
    private let divider = RackDividerCell()
    private let eraserCell = RackIconCell(symbol: "eraser")
    private let pageCell = RackIconCell(symbol: "hand.draw")
    private let inkCell = RackIconCell(symbol: "cursorarrow.motionlines")
    private let lassoCell = RackIconCell(symbol: "lasso")
    private let snipCell = RackIconCell(symbol: "rectangle.dashed.badge.record")
    private let layersCell = RackIconCell(symbol: "square.3.layers.3d")

    private var collapsed = UserDefaults.standard.bool(forKey: K.collapsed)
    private var shift: CGFloat = 0
    private var fullW: CGFloat = 0
    /// 阅读区（胶囊能待的范围）与上下让位量，由窗格给。
    private var viewport: NSRect = .zero
    private var topInset: CGFloat = 0
    private var bottomInset: CGFloat = 0
    private var popover: NSPopover?
    private var bag = Set<AnyCancellable>()
    private var sessionBag = Set<AnyCancellable>()
    private var observers: [NSObjectProtocol] = []
    private var dragStart: (mouse: NSPoint, origin: NSPoint)?

    override var isFlipped: Bool { true }

    init(app: AppModel, session: DocSession) {
        self.app = app
        self.session = session
        super.init(frame: NSRect(x: 0, y: 0, width: 400, height: Self.height))
        let d = UserDefaults.standard
        // 老用户迁移：已有 fracX 存储值说明位置定过——视为拖过，不被「顶部居中」默认值拽走
        if d.object(forKey: K.moved) == nil, d.object(forKey: K.fx) != nil { d.set(true, forKey: K.moved) }

        wantsLayer = true
        shadow = {
            let s = NSShadow()
            s.shadowColor = NSColor.black.withAlphaComponent(0.3)
            s.shadowBlurRadius = 6
            s.shadowOffset = NSSize(width: 0, height: -2)
            return s
        }()
        shell.material = .popover
        shell.blendingMode = .withinWindow
        shell.state = .active
        shell.wantsLayer = true
        shell.layer?.masksToBounds = true
        shell.layer?.borderWidth = 0.5
        shell.layer?.borderColor = NSColor.white.withAlphaComponent(0.15).cgColor
        addSubview(shell)
        grip.image = NSImage(systemSymbolName: "line.3.horizontal", accessibilityDescription: nil)
        grip.symbolConfiguration = .init(pointSize: 10, weight: .regular)
        grip.contentTintColor = NSColor.labelColor.withAlphaComponent(0.55)
        shell.addSubview(grip)
        window_.wantsLayer = true
        window_.layer?.masksToBounds = true
        shell.addSubview(window_)
        window_.addSubview(row)
        shell.addSubview(toggle)

        for c in [addCell, divider, eraserCell, pageCell, inkCell, lassoCell, snipCell, layersCell] as [RackCell] {
            row.addSubview(c)
        }
        let all: [RackCell] = [toggle, addCell, eraserCell, pageCell, inkCell, lassoCell, snipCell, layersCell]
        for c in all { c.rack = self }
        addCell.tip = L("Add Pen")
        pageCell.tip = L("Page Turn")
        inkCell.tip = L("Local Pen")
        lassoCell.tip = L("Lasso Select")
        snipCell.tip = L("Snip to AI")
        layersCell.tip = L("Layers")
        eraserCell.tip = L("Eraser")
        addCell.onClick = { [weak self] in
            guard let self else { return }
            let i = self.app.addPen()
            self.syncFromModel()
            if self.penCells.indices.contains(i) { self.showPenEditor(i) }
        }
        eraserCell.onClick = { [weak self] in
            guard let self else { return }
            if self.app.padMode == "erase" { self.showEraserEditor() } else { self.app.setPadMode("erase") }
        }
        pageCell.onClick = { [weak self] in self?.app.setPadMode("page") }
        inkCell.onClick = { [weak self] in self?.togglePointer(.ink) }
        lassoCell.onClick = { [weak self] in self?.togglePointer(.lasso) }
        snipCell.onClick = { [weak self] in self?.togglePointer(.snip) }
        layersCell.onClick = { [weak self] in self?.showLayers() }
        toggle.onClick = { [weak self] in self?.setCollapsed(!(self?.collapsed ?? false)) }

        app.objectWillChange.receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.syncFromModel() }.store(in: &bag)
        observers.append(NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil,
                                                                queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.defaultsChanged() }
        })
        syncFromModel()
        applyLayout(animated: false)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) 不支持") }

    deinit { for o in observers { NotificationCenter.default.removeObserver(o) } }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        shell.layer?.borderColor = NSColor.white.withAlphaComponent(0.15).cgColor
    }

    func bind(_ s: DocSession) {
        guard s !== session else { return }
        session = s
        popover?.close()
    }

    private func togglePointer(_ t: PointerTool) {
        app.pointerTool = app.pointerTool == t ? .textSelect : t
    }

    // MARK: 同步模型

    private var lastSig: (pens: [PenPreset], mode: String, pen: Int, tool: PointerTool)?

    private func syncFromModel() {
        // `AppModel` 为很多不相干的事发变化；笔架看的这几样没变就不动（重排会打断收起动画）
        let sig = (app.pens, app.padMode, app.padPenIndex, app.pointerTool)
        if let l = lastSig, l.pens == sig.0, l.mode == sig.1, l.pen == sig.2, l.tool == sig.3 { return }
        lastSig = sig
        // 笔插槽数量对齐
        while penCells.count < app.pens.count {
            let c = RackPenCell()
            c.rack = self
            let idx = penCells.count
            c.onClick = { [weak self] in self?.penTapped(idx) }
            c.menuProvider = { [weak self] in self?.penMenu(idx) }
            row.addSubview(c)
            penCells.append(c)
        }
        while penCells.count > app.pens.count { penCells.removeLast().removeFromSuperview() }
        let mode = app.padMode
        for (i, c) in penCells.enumerated() {
            c.pen = app.pens[i]
            c.active = mode == "note" && app.padPenIndex == i
            c.tip = app.pens[i].name
        }
        eraserCell.active = mode == "erase"
        pageCell.active = mode == "page"
        inkCell.active = app.pointerTool == .ink
        lassoCell.active = app.pointerTool == .lasso
        snipCell.active = app.pointerTool == .snip
        toggle.tip = collapsed ? L("Expand Pen Toolbar") : L("Collapse")
        let oldKeep = keepX()
        layoutRow()
        // 已经收起时换了保留格（切笔 / 切工具）：推移量当场跟上
        if collapsed, abs(keepX() - shift) > 0.5 || abs(oldKeep - keepX()) > 0.5 {
            shift = keepX()
            applyLayout(animated: true)
        } else {
            applyLayout(animated: false)
        }
    }

    /// 另一扇窗口改了收起态：镜像过来（同样带动画）。
    private func defaultsChanged() {
        let v = UserDefaults.standard.bool(forKey: K.collapsed)
        if v != collapsed {
            if v { shift = keepX(); popover?.close() }
            collapsed = v
            applyLayout(animated: true)
        }
    }

    private func setCollapsed(_ v: Bool) {
        if v {
            popover?.close()   // 收起前先收掉挂在窗外按钮上的浮层
            shift = keepX()
        }
        collapsed = v
        UserDefaults.standard.set(v, forKey: K.collapsed)
        applyLayout(animated: true)
    }

    // MARK: 排版

    private var rowCells: [RackCell] {
        penCells as [RackCell] + [addCell, divider, eraserCell, pageCell, inkCell, lassoCell, snipCell, layersCell]
    }

    private func layoutRow() {
        var x: CGFloat = 0
        for c in rowCells {
            let w = c.cellWidth
            let h = c is RackDividerCell ? 20 : c.cellHeight
            c.frame = NSRect(x: x, y: (28 - h) / 2, width: w, height: h)
            x += w + Self.gap
        }
        fullW = max(0, x - Self.gap)
        row.frame.size = NSSize(width: fullW, height: 28)
    }

    /// 收起后保留哪一格：画笔模式 = 当前笔（越界兜底第一支）；橡皮 / 翻页 = 对应工具格。
    private func keepCell() -> RackCell? {
        switch app.padMode {
        case "note": return penCells.indices.contains(app.padPenIndex) ? penCells[app.padPenIndex] : penCells.first
        case "erase": return eraserCell
        case "page": return pageCell
        default: return nil
        }
    }
    private func keepX() -> CGFloat { keepCell()?.frame.minX ?? 0 }

    private func rackWidth(collapsed c: Bool) -> CGFloat {
        10 + 14 + Self.gap + (c ? Self.keepW : fullW) + 8 + 20 + 10
    }

    /// 摆胶囊（窗格布局时调）。
    /// 窗格每次布局都会调；范围没变就什么都不做（否则会打断正在进行的收起 / 展开动画）。
    func place(viewport: NSRect, topInset: CGFloat, bottomInset: CGFloat) {
        guard viewport != self.viewport || topInset != self.topInset || bottomInset != self.bottomInset else { return }
        self.viewport = viewport
        self.topInset = topInset
        self.bottomInset = bottomInset
        applyLayout(animated: false)
        reclampStored()
    }

    /// 夹取后的左上缘（窗格坐标）。没拖过：横向居中现算、纵向读 fracY。
    private func clampedOrigin(width w: CGFloat, drag: CGSize = .zero, base: NSPoint? = nil) -> NSPoint {
        let vw = viewport.width, vh = viewport.height
        guard vw > 0, vh > 0 else { return .zero }
        let d = UserDefaults.standard
        let moved = d.bool(forKey: K.moved)
        let fx = d.object(forKey: K.fx) as? Double ?? 0.03
        let fy = d.object(forKey: K.fy) as? Double ?? 0.02
        let baseX = base?.x ?? (moved ? fx * vw : (vw - w) / 2)
        let baseY = base?.y ?? fy * vh
        let maxX = max(Self.edgeMargin, vw - w - Self.edgeMargin)
        let minY = topInset + Self.edgeMargin
        let maxY = max(minY, vh - Self.height - Self.edgeMargin - bottomInset)
        return NSPoint(x: viewport.minX + min(max(baseX + drag.width, Self.edgeMargin), maxX),
                       y: viewport.minY + min(max(baseY + drag.height, minY), maxY))
    }

    /// 存储位置若已越界（窗口变小、旧版本留下的值）拉回可见区；没拖过时位置是现算的，没有要校的。
    private func reclampStored() {
        guard UserDefaults.standard.bool(forKey: K.moved), viewport.width > 0, viewport.height > 0 else { return }
        let p = clampedOrigin(width: frame.width)
        let fx = Double((p.x - viewport.minX) / viewport.width), fy = Double((p.y - viewport.minY) / viewport.height)
        let d = UserDefaults.standard
        if abs((d.object(forKey: K.fx) as? Double ?? 0) - fx) > 0.0001 { d.set(fx, forKey: K.fx) }
        if abs((d.object(forKey: K.fy) as? Double ?? 0) - fy) > 0.0001 { d.set(fy, forKey: K.fy) }
    }

    /// 收起 / 展开共用一条曲线：宽度、推移量、箭头旋转一起走；不带回弹（过冲会把当前那格先顶出左边界再弹回来）。
    private func applyLayout(animated: Bool) {
        let w = rackWidth(collapsed: collapsed)
        let origin = viewport.width > 0 ? clampedOrigin(width: w) : frame.origin
        let target = NSRect(x: origin.x, y: origin.y, width: w, height: Self.height)
        let windowW = collapsed ? Self.keepW : fullW
        let rowX = collapsed ? -shift : 0
        let toggleX = 10 + 14 + Self.gap + windowW + 8
        let rot: CGFloat = collapsed ? 180 : 0
        let hitAll = !collapsed
        let keep = keepCell()
        for c in rowCells { c.hitEnabled = hitAll || c === keep }
        let apply = {
            let s = animated ? self.animator() : self
            s.frame = target
            (animated ? self.shell.animator() : self.shell).frame = NSRect(origin: .zero, size: target.size)
            (animated ? self.window_.animator() : self.window_).frame = NSRect(x: 10 + 14 + Self.gap, y: 8, width: windowW, height: 28)
            (animated ? self.row.animator() : self.row).setFrameOrigin(NSPoint(x: rowX, y: 0))
            (animated ? self.toggle.animator() : self.toggle).frame = NSRect(x: toggleX, y: 8, width: 20, height: 28)
        }
        toggle.setRotation(rot, duration: animated ? 0.3 : 0)
        grip.frame = NSRect(x: 10, y: 8, width: 14, height: 28)
        shell.layer?.cornerRadius = Self.height / 2
        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.3
                ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.25, 0.1, 0.25, 1)
                apply()
            }
        } else {
            apply()
        }
    }

    // MARK: 拖动（起点落在格子上也行：挪过 6pt 才算拖，由格子转交过来）

    /// 起手点以按下那一刻为准（不是挪过阈值的那一刻），免得胶囊一下跳 6pt。
    fileprivate func beginDrag(from mouse: NSPoint) {
        dragStart = (mouse, frame.origin)
        popover?.close()
    }

    fileprivate func continueDrag(_ event: NSEvent) {
        guard let s = dragStart else { return }
        let p = event.locationInWindow
        let base = NSPoint(x: s.origin.x - viewport.minX, y: s.origin.y - viewport.minY)
        let o = clampedOrigin(width: frame.width, drag: CGSize(width: p.x - s.mouse.x, height: -(p.y - s.mouse.y)), base: base)
        setFrameOrigin(o)
    }

    /// 落点折算回 0~1 比例存盘；拖过即离开「默认顶部居中」。
    fileprivate func endDrag() {
        guard dragStart != nil, viewport.width > 0, viewport.height > 0 else { dragStart = nil; return }
        dragStart = nil
        let d = UserDefaults.standard
        d.set(Double((frame.minX - viewport.minX) / viewport.width), forKey: K.fx)
        d.set(Double((frame.minY - viewport.minY) / viewport.height), forKey: K.fy)
        d.set(true, forKey: K.moved)
    }

    private var bgDown: NSPoint?
    override func mouseDown(with event: NSEvent) { bgDown = event.locationInWindow }
    override func mouseDragged(with event: NSEvent) {
        if dragStart == nil, let d = bgDown, hypot(event.locationInWindow.x - d.x, event.locationInWindow.y - d.y) >= 6 {
            dragStart = (d, frame.origin)
            popover?.close()
        }
        continueDrag(event)
    }
    override func mouseUp(with event: NSEvent) {
        bgDown = nil
        endDrag()
    }

    // MARK: 笔插槽

    private func penTapped(_ i: Int) {
        guard app.pens.indices.contains(i) else { return }
        if app.padMode == "note", app.padPenIndex == i { showPenEditor(i) } else { app.applyPenSelection(index: i) }
    }

    private func penMenu(_ i: Int) -> NSMenu? {
        guard app.pens.indices.contains(i) else { return nil }
        let id = app.pens[i].id
        let m = NSMenu()
        let del = ClosureMenuItem(L("Delete"), action: { [weak self] in self?.app.removePen(id: id) })
        del.image = NSImage(systemSymbolName: "trash", accessibilityDescription: nil)
        if app.pens.count <= 1 { del.action = nil }
        m.addItem(del)
        return m
    }

    private func present(_ content: NSView, size: NSSize, from cell: NSView) {
        popover?.close()
        let vc = NSViewController()
        vc.view = content
        let p = NSPopover()
        p.contentViewController = vc
        p.behavior = .transient
        p.contentSize = size
        popover = p
        p.show(relativeTo: cell.bounds, of: cell, preferredEdge: .maxY)
    }

    private func showPenEditor(_ i: Int) {
        guard penCells.indices.contains(i) else { return }
        let v = PenEditorView(app: app, index: i)
        present(v, size: v.frame.size, from: penCells[i])
    }

    private func showEraserEditor() {
        let v = EraserEditorView(app: app)
        present(v, size: v.frame.size, from: eraserCell)
    }

    private func showLayers() {
        // 画板笔记不分图层（同草稿纸）；图层面板管的是 PDF 页内笔迹，在画板上打开只会是一张空表
        guard !session.isBoard else { NSSound.beep(); return }
        let v = LayerManagerNSView(session: session)
        v.onSizeChange = { [weak self] s in self?.popover?.contentSize = s }
        present(v, size: v.preferredSize, from: layersCell)
    }
}

// MARK: - 格子

/// 笔架的一格：点击 = 动作；按下后挪过 6pt = 转交笔架去拖动整个胶囊。收起后取景窗外的格子不接鼠标。
class RackCell: NSView {
    weak var rack: PenRackNSView?
    var onClick: () -> Void = {}
    var menuProvider: (() -> NSMenu?)?
    var cellWidth: CGFloat { 28 }
    var cellHeight: CGFloat { 28 }
    var hitEnabled = true
    var tip: String = "" { didSet { toolTip = tip } }
    private var down: NSPoint?
    private var dragging = false

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { hitEnabled ? super.hitTest(point) : nil }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        down = event.locationInWindow
        dragging = false
    }
    override func mouseDragged(with event: NSEvent) {
        guard let d = down else { return }
        let p = event.locationInWindow
        if !dragging, hypot(p.x - d.x, p.y - d.y) >= 6 {
            dragging = true
            rack?.beginDrag(from: d)
        }
        if dragging { rack?.continueDrag(event) }
    }
    override func mouseUp(with event: NSEvent) {
        defer { down = nil; dragging = false }
        if dragging { rack?.endDrag(); return }
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick() }
    }
    override func menu(for event: NSEvent) -> NSMenu? { menuProvider?() }
}

/// 图标格：系统符号，激活时强调色（材质底上一律主色，别用次要色）。
final class RackIconCell: RackCell {
    private let icon = NSImageView()
    private let width: CGFloat
    var tint: NSColor = .labelColor { didSet { refresh() } }
    var symbolWeight: NSFont.Weight = .regular { didSet { refresh() } }
    var symbolSize: CGFloat = 15 { didSet { refresh() } }
    var active = false { didSet { if oldValue != active { refresh() } } }
    private let symbol: String

    init(symbol: String, width: CGFloat = 28) {
        self.symbol = symbol
        self.width = width
        super.init(frame: .zero)
        icon.imageScaling = .scaleNone
        addSubview(icon)
        refresh()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) 不支持") }

    override var cellWidth: CGFloat { width }
    override var cellHeight: CGFloat { width == 26 ? 26 : 28 }

    private func refresh() {
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
        icon.symbolConfiguration = .init(pointSize: symbolSize, weight: symbolWeight)
        icon.contentTintColor = active ? .controlAccentColor : tint
    }

    override func layout() {
        super.layout()
        icon.frame = bounds
    }
}

/// 收 / 展箭头：**始终是同一个 chevron，靠旋转 180° 换向**（换成另一个符号的话，中途画面上会有两个箭头）。
/// 箭头画在自己管的一个图层上，旋转走 Core Animation——视图本身的 frame 照常摆，不和旋转打架。
final class RackChevronCell: RackCell {
    private let chevron = CALayer()
    private var angle: CGFloat = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        chevron.contentsGravity = .center
        layer?.addSublayer(chevron)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) 不支持") }

    override var cellWidth: CGFloat { 20 }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        chevron.bounds = CGRect(origin: .zero, size: bounds.size)
        chevron.position = CGPoint(x: bounds.midX, y: bounds.midY)
        CATransaction.commit()
        redrawImage()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        redrawImage()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        redrawImage()
    }

    private func redrawImage() {
        var tint = NSColor.labelColor.withAlphaComponent(0.7)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            tint = (NSColor.labelColor.usingColorSpace(.sRGB) ?? .labelColor).withAlphaComponent(0.7)
        }
        guard let img = NSImage(systemSymbolName: "chevron.left", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold).applying(.init(paletteColors: [tint]))) else { return }
        let scale = window?.backingScaleFactor ?? 2
        var rect = NSRect(origin: .zero, size: img.size)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        chevron.contentsScale = scale
        chevron.contents = img.cgImage(forProposedRect: &rect, context: nil, hints: [.ctm: AffineTransform(scale: scale)])
        CATransaction.commit()
    }

    func setRotation(_ degrees: CGFloat, duration: CFTimeInterval) {
        let target = degrees * .pi / 180
        guard target != angle else { return }
        let from = angle
        angle = target
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        chevron.setAffineTransform(CGAffineTransform(rotationAngle: target))
        CATransaction.commit()
        guard duration > 0 else { return }
        let a = CABasicAnimation(keyPath: "transform.rotation.z")
        a.fromValue = from
        a.toValue = target
        a.duration = duration
        a.timingFunction = CAMediaTimingFunction(controlPoints: 0.25, 0.1, 0.25, 1)
        chevron.add(a, forKey: "rotate")
    }
}

/// 分隔线格（1pt 宽、20 高）。
final class RackDividerCell: RackCell {
    private let line = NSBox()
    override init(frame: NSRect) {
        super.init(frame: frame)
        line.boxType = .separator
        addSubview(line)
        hitEnabled = false
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) 不支持") }
    override var cellWidth: CGFloat { 1 }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func layout() {
        super.layout()
        line.frame = bounds
    }
}

/// 笔尖格：白底垫真彩（半透明墨也显真色）+ 笔型字形（按亮度选黑 / 白）+ 描边（选中 = 强调色 2.5pt，画在内侧）。
final class RackPenCell: RackCell {
    var pen: PenPreset? { didSet { if oldValue != pen { needsDisplay = true } } }
    var active = false { didSet { if oldValue != active { needsDisplay = true } } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) 不支持") }

    override func draw(_ dirtyRect: NSRect) {
        guard let pen else { return }
        let r = bounds
        NSColor.white.setFill()
        NSBezierPath(ovalIn: r).fill()
        pen.color.nsColor.setFill()
        NSBezierPath(ovalIn: r).fill()
        let c = pen.color
        let lum = (0.299 * c.r + 0.587 * c.g + 0.114 * c.b) / 255
        let fg: NSColor = lum > 0.62 ? .black : .white
        if let img = NSImage(systemSymbolName: pen.type.systemImage, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .bold).applying(.init(paletteColors: [fg]))) {
            let s = img.size
            img.draw(in: NSRect(x: r.midX - s.width / 2, y: r.midY - s.height / 2, width: s.width, height: s.height),
                     from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
        let lw: CGFloat = active ? 2.5 : 1
        let ring = NSBezierPath(ovalIn: r.insetBy(dx: lw / 2, dy: lw / 2))
        ring.lineWidth = lw
        (active ? NSColor.controlAccentColor : NSColor.white.withAlphaComponent(0.55)).setStroke()
        ring.stroke()
    }
}

// MARK: - 笔 / 橡皮 调整面板（改动实时写回 AppModel，didSet 自动落盘 + 广播给平板，没有「保存」按钮）

final class PenEditorView: NSView {
    override var isFlipped: Bool { true }
    private let app: AppModel
    private let index: Int
    private let well = NSColorWell()
    private let slider = NSSlider(value: 8, minValue: 2, maxValue: 40, target: nil, action: nil)
    private let value = NSTextField(labelWithString: "")
    private let types = NSSegmentedControl()
    private let typeLabel = NSTextField(labelWithString: "")

    init(app: AppModel, index: Int) {
        self.app = app
        self.index = index
        super.init(frame: NSRect(x: 0, y: 0, width: 260, height: 150))
        let pen = app.pens.indices.contains(index) ? app.pens[index] : PenPreset(name: "", color: InkColor(r: 0, g: 0, b: 0, a: 1), width: 8)
        let title = NSTextField(labelWithString: L("Pen"))
        title.font = .preferredFont(forTextStyle: .headline)
        title.frame = NSRect(x: 14, y: 14, width: 150, height: 22)
        well.colorWellStyle = .minimal
        well.supportsAlpha = true
        well.color = pen.color.nsColor
        well.frame = NSRect(x: 260 - 14 - 44, y: 12, width: 44, height: 26)
        well.target = self
        well.action = #selector(colorChanged)
        let wl = NSTextField(labelWithString: L("Width"))
        wl.frame = NSRect(x: 14, y: 52, width: 50, height: 20)
        slider.doubleValue = pen.width
        slider.isContinuous = true
        slider.target = self
        slider.action = #selector(widthChanged)
        slider.frame = NSRect(x: 66, y: 50, width: 150, height: 24)
        value.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        value.alignment = .right
        value.frame = NSRect(x: 220, y: 52, width: 26, height: 20)
        types.segmentCount = PenBrushType.allCases.count
        types.trackingMode = .selectOne
        for (i, t) in PenBrushType.allCases.enumerated() {
            types.setImage(NSImage(systemSymbolName: t.systemImage, accessibilityDescription: t.label), forSegment: i)
            types.setToolTip(t.label, forSegment: i)
            types.setWidth(52, forSegment: i)
        }
        types.selectedSegment = PenBrushType.allCases.firstIndex(of: pen.type) ?? 0
        types.target = self
        types.action = #selector(typeChanged)
        types.frame = NSRect(x: 14, y: 86, width: 232, height: 24)
        typeLabel.font = .preferredFont(forTextStyle: .caption1)
        typeLabel.textColor = .secondaryLabelColor
        typeLabel.alignment = .center
        typeLabel.frame = NSRect(x: 14, y: 116, width: 232, height: 16)
        for v in [title, well, wl, slider, value, types, typeLabel] as [NSView] { addSubview(v) }
        refreshLabels()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) 不支持") }

    private func refreshLabels() {
        guard app.pens.indices.contains(index) else { return }
        value.stringValue = "\(Int(app.pens[index].width))"
        typeLabel.stringValue = app.pens[index].type.label
    }

    @objc private func colorChanged() {
        guard app.pens.indices.contains(index) else { return }
        let ns = well.color.usingColorSpace(.sRGB) ?? .black
        app.pens[index].color = InkColor(r: Double(ns.redComponent) * 255, g: Double(ns.greenComponent) * 255,
                                         b: Double(ns.blueComponent) * 255, a: Double(ns.alphaComponent))
    }

    /// 粗细收敛到两位小数：裸滑块会产出超长小数，既落盘又广播到平板（采集页状态胶囊会直接显示它）。
    @objc private func widthChanged() {
        guard app.pens.indices.contains(index) else { return }
        app.pens[index].width = (slider.doubleValue * 100).rounded() / 100
        refreshLabels()
    }

    @objc private func typeChanged() {
        guard app.pens.indices.contains(index), PenBrushType.allCases.indices.contains(types.selectedSegment) else { return }
        app.pens[index].type = PenBrushType.allCases[types.selectedSegment]
        refreshLabels()
    }
}

final class EraserEditorView: NSView {
    override var isFlipped: Bool { true }
    private let app: AppModel
    private let modes = NSSegmentedControl()
    private let slider = NSSlider(value: 0.02, minValue: 0.005, maxValue: 0.06, target: nil, action: nil)
    private let value = NSTextField(labelWithString: "")
    private let ring = NSButton(checkboxWithTitle: L("Size Ring"), target: nil, action: nil)

    init(app: AppModel) {
        self.app = app
        super.init(frame: NSRect(x: 0, y: 0, width: 260, height: 150))
        let title = NSTextField(labelWithString: L("Eraser"))
        title.font = .preferredFont(forTextStyle: .headline)
        title.frame = NSRect(x: 14, y: 14, width: 200, height: 22)
        modes.segmentCount = EraserMode.allCases.count
        modes.trackingMode = .selectOne
        for (i, m) in EraserMode.allCases.enumerated() {
            modes.setLabel(m.label, forSegment: i)
            modes.setWidth(114, forSegment: i)
        }
        modes.selectedSegment = EraserMode.allCases.firstIndex(of: app.eraserMode) ?? 0
        modes.target = self
        modes.action = #selector(modeChanged)
        modes.frame = NSRect(x: 14, y: 46, width: 232, height: 24)
        let wl = NSTextField(labelWithString: L("Width"))
        wl.frame = NSRect(x: 14, y: 84, width: 50, height: 20)
        slider.doubleValue = app.eraserRadius
        slider.isContinuous = true
        slider.target = self
        slider.action = #selector(radiusChanged)
        slider.frame = NSRect(x: 66, y: 82, width: 136, height: 24)
        value.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        value.alignment = .right
        value.frame = NSRect(x: 206, y: 84, width: 40, height: 20)
        ring.state = app.eraserRing ? .on : .off
        ring.target = self
        ring.action = #selector(ringChanged)
        ring.frame = NSRect(x: 14, y: 116, width: 232, height: 20)
        for v in [title, modes, wl, slider, value, ring] as [NSView] { addSubview(v) }
        refreshLabel()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) 不支持") }

    /// 读数 = 直径占页宽的百分比。
    private func refreshLabel() { value.stringValue = "\(Int((app.eraserRadius * 200).rounded()))%" }

    @objc private func modeChanged() {
        guard EraserMode.allCases.indices.contains(modes.selectedSegment) else { return }
        app.eraserMode = EraserMode.allCases[modes.selectedSegment]
    }
    @objc private func radiusChanged() {
        app.eraserRadius = (slider.doubleValue * 1000).rounded() / 1000
        refreshLabel()
    }
    @objc private func ringChanged() { app.eraserRing = ring.state == .on }
}
