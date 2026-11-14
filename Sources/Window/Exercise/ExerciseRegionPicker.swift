import AppKit

/// 「设置原题区域…」那张表（`EXERCISE-PLAN.md §25`，用户 2026-11-12：「练习题的 PDF 参考图，支持设置区间，这样不用显示完整一页」）。
///
/// 标准 `NSAlert`，附件区是这道题所在的**整页**（同「原题」那份渲染，开着扫描页对齐就是对齐后的页面），
/// 在上面拖出一个框：框外拖 = 重画，框内拖 = 挪动，拖边 / 角 = 改大小；点过页面后方向键逐点挪框，⌥ + 方向键改右边 / 下边。
/// 「保存」写进 `payload.region`（归一化 `[x, y, w, h]`、左上原点，与 Agent 导入时给的同一个字段）；
/// 「用整页」= 去掉框（nil），看原题时又显示整页。安卓两种模式看原题本来就按这个框裁，同步过去就跟着变。
///
/// **跨页的题**（§26，用户：「题目从第一页开始到第二页，图在第二页……就没办法裁剪实际参考图」）：上面「题目在」选几页，
/// 几页从上到下排在一个滚动区里，每页各框一块；后面几页的框存进 `payload.next_regions`。新接上的一页先放一个
/// 页顶的框（左右跟上一页的框对齐），多数时候只要往下拖底边。
///
/// **§30（用户 2026-11-14：「不支持只设置后面某一页」「不能自由缩放页面，精准控制」「框选区域有误差」）**：
/// 选了几页时每页标题行有「不显示这一页」（存 `payload.skip_pages`），可以只留后面某一页；滚动区能捏合 / 按钮缩放（1–8 倍），
/// 页图按 2400 像素宽出，放大了也看得清边；原题图不再四周留边（`ExerciseOriginal`），框到哪显示到哪。
@MainActor
enum ExerciseRegionPicker {

    /// 表里页图出多宽（像素）：放大到两三倍框边仍清楚。
    static let renderWidth = 2400

    /// 先渲起始页，渲出来再弹表（渲不出来 = 文件不在，说一声）。`done(nil, nil, nil)` = 用整页；取消不回调。
    static func present(on window: NSWindow, exercise e: Exercise, workspace ws: WorkspaceManager,
                        done: @escaping (_ region: [Double]?, _ next: [[Double]]?, _ skip: [Int]?) -> Void) {
        func missing() {
            let a = NSAlert()
            a.messageText = L("Can’t show the page of this question")
            a.informativeText = L("The PDF it comes from is not on this Mac.")
            a.beginSheetModal(for: window)
        }
        guard let docId = e.documentId, let page = e.page else { missing(); return }
        ExerciseOriginal.pageImage(documentId: docId, page: page, workspace: ws, pixelWidth: renderWidth) { [weak window, weak ws] img in
            guard let window, let ws, window.attachedSheet == nil else { return }
            guard let img else { missing(); return }
            let pageCount = ws.document(id: docId)?.pageCount ?? 0
            let maxPages = max(1, min(1 + ExerciseRegion.maxNextPages, pageCount - page))
            ExerciseRegionSheet(documentId: docId, firstPage: page, maxPages: maxPages, workspace: ws,
                                first: img, region: e.payload.region, next: e.payload.nextRegions,
                                skip: e.payload.skipPages, done: done)
                .show(on: window)
        }
    }
}

/// 一次「设置原题区域」的状态（表开着期间由 `beginSheetModal` 的回调持有）。
@MainActor
private final class ExerciseRegionSheet: NSObject {
    private let documentId: String
    /// 起始页，0 起。
    private let firstPage: Int
    /// 最多能选几页（起始页 + 后面至多 `ExerciseRegion.maxNextPages` 页，不越过最后一页）。
    private let maxPages: Int
    private weak var workspace: WorkspaceManager?
    private let done: ([Double]?, [[Double]]?, [Int]?) -> Void

    /// 每页的框（归一化）与页图，下标 0 = 起始页；长度 = `maxPages`。没显示出来的页的框也留着，页数改回来还在。
    private var boxes: [CGRect?]
    private var images: [NSImage?]
    /// 每页「不显示这一页」（§30）。
    private var skipped: [Bool]
    private var requested: Set<Int> = []
    /// 现在显示几页。
    private var shown: Int

    private let canvases: [ExerciseRegionCanvas]
    /// 选了几页时每页上面一行：「第 N 页」+「不显示这一页」。
    private let headers: [NSView]
    private let skipBoxes: [NSButton]
    private let doc = FlippedView()
    private let scroll = NSScrollView()
    private let popup = NSPopUpButton()
    private weak var saveButton: NSButton?

    /// 页图在表里的宽（点，放大倍率 1 时）、滚动区的高：按起始页整页塞得下算。
    private var pageWidth: CGFloat = 0
    private var viewportHeight: CGFloat = 0
    private static let headerHeight: CGFloat = 28
    private static let zoomRange: ClosedRange<CGFloat> = 1...8

    init(documentId: String, firstPage: Int, maxPages: Int, workspace: WorkspaceManager, first: NSImage,
         region: [Double]?, next: [[Double]]?, skip: [Int]?, done: @escaping ([Double]?, [[Double]]?, [Int]?) -> Void) {
        self.documentId = documentId
        self.firstPage = firstPage
        self.maxPages = maxPages
        self.workspace = workspace
        self.done = done
        func rect(_ r: [Double]) -> CGRect? { r.count == 4 ? CGRect(x: r[0], y: r[1], width: r[2], height: r[3]) : nil }
        var b = [CGRect?](repeating: nil, count: maxPages)
        b[0] = region.flatMap(rect)
        let nx = region == nil ? [] : (next ?? [])
        for (k, r) in nx.prefix(maxPages - 1).enumerated() { b[k + 1] = rect(r) }
        boxes = b
        images = [first] + [NSImage?](repeating: nil, count: maxPages - 1)
        shown = 1 + nx.prefix(maxPages - 1).count
        var sk = [Bool](repeating: false, count: maxPages)
        if region != nil { for k in skip ?? [] where sk.indices.contains(k) && k < shown { sk[k] = true } }
        skipped = sk
        canvases = (0..<maxPages).map { _ in ExerciseRegionCanvas(frame: .zero) }
        var hs: [NSView] = [], cbs: [NSButton] = []
        for i in 0..<maxPages {
            let h = FlippedView()
            let l = NSTextField(labelWithString: String(format: L("Page %d"), firstPage + i + 1))
            l.font = .systemFont(ofSize: 12, weight: .semibold)
            l.textColor = .labelColor
            l.sizeToFit()
            h.addSubview(l)
            let cb = NSButton(checkboxWithTitle: L("Don’t show this page"), target: nil, action: nil)
            cb.tag = i
            cb.state = sk[i] ? .on : .off
            cb.sizeToFit()
            h.addSubview(cb)
            hs.append(h)
            cbs.append(cb)
        }
        headers = hs
        skipBoxes = cbs
        super.init()
        for cb in skipBoxes { cb.target = self; cb.action = #selector(skipToggled(_:)) }
    }

    func show(on window: NSWindow) {
        // 起始页整页按比例塞进滚动区：宽不超过 640，高不超过 560（能放大，不必整页撑满；用户 11-14 嫌表太高）
        let maxW: CGFloat = 640
        let maxH = max(320, min(560, window.frame.height - 300))
        let size = images[0]?.size ?? NSSize(width: 600, height: 800)
        let scale = min(maxW / max(size.width, 1), maxH / max(size.height, 1))
        pageWidth = (size.width * scale).rounded()
        viewportHeight = (size.height * scale).rounded()

        for (i, c) in canvases.enumerated() {
            c.image = images[i]
            c.region = boxes[i]
            c.excluded = skipped[i]
            c.toolTip = L("Arrow keys move the box; Option + arrow keys resize it")
            c.onChange = { [weak self, weak c] in
                guard let self, let c else { return }
                self.boxes[i] = c.region
                self.updateSave()
            }
            doc.addSubview(c)
        }
        for h in headers { doc.addSubview(h) }

        // 传统滚动条占宽：滚动区比页宽多出这一截，页面不被盖住
        let scrollerW = NSScroller.preferredScrollerStyle == .legacy
            ? NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy) : 0
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.documentView = doc
        // 捏合 / 按钮缩放（§30）：滚动视图自带放大倍率，框的坐标照旧按页面归一化，倍率不进数据
        scroll.allowsMagnification = true
        scroll.minMagnification = Self.zoomRange.lowerBound
        scroll.maxMagnification = Self.zoomRange.upperBound
        NotificationCenter.default.addObserver(self, selector: #selector(magnified),
                                               name: NSScrollView.didEndLiveMagnifyNotification, object: scroll)

        let container = FlippedView()
        let scrollW = pageWidth + scrollerW
        // 顶上一行：左边页数选择（后面没有页时不出），右边缩放。按控件实际宽度排，排不下就把整张表放宽，不许重叠
        var rowH: CGFloat = 0
        var leftW: CGFloat = 0
        if maxPages > 1 {
            for n in 1...maxPages {
                popup.addItem(withTitle: n == 1 ? String(format: L("Page %d only"), firstPage + 1)
                                                : String(format: L("Pages %d–%d"), firstPage + 1, firstPage + n))
            }
            popup.selectItem(at: shown - 1)
            popup.target = self
            popup.action = #selector(pagesChanged)
            popup.sizeToFit()
            rowH = popup.frame.height
            leftW = popup.frame.width + 12
            container.addSubview(popup)
        }
        let zoomOut = zoomButton("minus.magnifyingglass", L("Zoom Out"), #selector(zoomOut))
        let zoomIn = zoomButton("plus.magnifyingglass", L("Zoom In"), #selector(zoomIn))
        let fit = NSButton(title: L("Fit Width"), target: self, action: #selector(zoomFit))
        fit.sizeToFit()
        let zoomViews: [NSView] = [zoomOut, zoomIn, fit]
        let zoomW = zoomViews.reduce(0) { $0 + $1.frame.width } + 4 * CGFloat(zoomViews.count - 1)
        let width = max(scrollW, leftW + zoomW)
        rowH = max(rowH, fit.frame.height, zoomIn.frame.height)
        popup.frame.origin = NSPoint(x: 0, y: ((rowH - popup.frame.height) / 2).rounded())
        var x = width - zoomW
        for v in zoomViews {
            v.frame.origin = NSPoint(x: x, y: ((rowH - v.frame.height) / 2).rounded())
            container.addSubview(v)
            x += v.frame.width + 4
        }
        let y = rowH + 10
        scroll.frame = NSRect(x: ((width - scrollW) / 2).rounded(), y: y, width: scrollW, height: viewportHeight)
        container.addSubview(scroll)
        container.frame = NSRect(x: 0, y: 0, width: width, height: y + viewportHeight)
        layoutPages()
        loadMissingImages()

        let a = NSAlert()
        a.messageText = L("Set Question Area")
        // 界面上只留一句（用户 11-14：「APP 里面严禁大段文字」）；方向键微调放在页面的悬停提示里
        a.informativeText = L("Drag a box around the question.")
        a.accessoryView = container
        let save = a.addButton(withTitle: L("Save"))
        a.addButton(withTitle: L("Cancel"))
        a.addButton(withTitle: L("Use Whole Page"))
        saveButton = save
        updateSave()
        a.beginSheetModal(for: window) { resp in
            NotificationCenter.default.removeObserver(self)
            self.finish(resp)
        }
        if shown > 1 { scrollToPage(shown - 1) }
    }

    private func zoomButton(_ symbol: String, _ label: String, _ action: Selector) -> NSButton {
        let b = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: label) ?? NSImage(),
                         target: self, action: action)
        b.toolTip = label
        b.sizeToFit()
        return b
    }

    private func finish(_ resp: NSApplication.ModalResponse) {
        switch resp {
        case .alertFirstButtonReturn:
            guard canSave else { return }
            // 不显示的页没框过 → 存整页当占位（数据上每页都得有一个合格的框；老版本不认 skip_pages 时也照样显示得出）
            let all = (0..<shown).map { boxes[$0] ?? CGRect(x: 0, y: 0, width: 1, height: 1) }
            func arr(_ r: CGRect) -> [Double] { [r.minX, r.minY, r.width, r.height] }
            let next = all.dropFirst().map(arr)
            let skip = shown > 1 ? (0..<shown).filter { skipped[$0] } : []
            done(arr(all[0]), next.isEmpty ? nil : Array(next), skip.isEmpty ? nil : skip)
        case .alertThirdButtonReturn:
            done(nil, nil, nil)
        default:
            break
        }
    }

    /// 至少留一页显示；显示的每一页都框好了才能存（只选一页时「不显示」不算数）。
    private var canSave: Bool {
        let on = (0..<shown).filter { shown == 1 || !skipped[$0] }
        return !on.isEmpty && on.allSatisfy { boxes[$0] != nil }
    }

    private func updateSave() {
        saveButton?.isEnabled = canSave
    }

    @objc private func skipToggled(_ sender: NSButton) {
        let i = sender.tag
        guard skipped.indices.contains(i) else { return }
        skipped[i] = sender.state == .on
        canvases[i].excluded = skipped[i]
        updateSave()
    }

    @objc private func pagesChanged() {
        let n = min(max(1, popup.indexOfSelectedItem + 1), maxPages)
        guard n != shown else { return }
        if n > shown {
            // 新接上的页先放一个页顶的框，左右跟上一页的框对齐：题目接着往下印，多数时候只要拖底边
            for i in shown..<n where boxes[i] == nil {
                let prev = boxes[i - 1] ?? CGRect(x: 0.05, y: 0, width: 0.9, height: 0)
                boxes[i] = CGRect(x: prev.minX, y: 0.03, width: prev.width, height: 0.3)
                canvases[i].region = boxes[i]
            }
        }
        let grew = n > shown
        shown = n
        layoutPages()
        loadMissingImages()
        updateSave()
        if grew { scrollToPage(n - 1) }
    }

    // MARK: 缩放

    @objc private func zoomIn() { setZoom(scroll.magnification * 1.5) }
    @objc private func zoomOut() { setZoom(scroll.magnification / 1.5) }
    @objc private func zoomFit() { setZoom(1) }

    /// 以可见区中心为准缩放（放大后还看着原来那块）。
    private func setZoom(_ m: CGFloat) {
        let clip = scroll.contentView
        let center = NSPoint(x: clip.bounds.midX, y: clip.bounds.midY)
        scroll.setMagnification(min(max(m, Self.zoomRange.lowerBound), Self.zoomRange.upperBound), centeredAt: center)
        magnified()
    }

    @objc private func magnified() {
        for c in canvases { c.needsDisplay = true; c.window?.invalidateCursorRects(for: c) }
    }

    // MARK: 摆放

    /// 从上到下摆显示的几页（选了几页时每页上面一行标题）；页高按各自页图的比例，还没渲出来的先按起始页的比例。
    private func layoutPages() {
        let firstAspect = aspect(images[0]) ?? (viewportHeight / max(pageWidth, 1))
        let withHeaders = shown > 1
        var y: CGFloat = 0
        for i in 0..<maxPages {
            let on = i < shown
            canvases[i].isHidden = !on
            headers[i].isHidden = !on || !withHeaders
            guard on else { continue }
            if withHeaders {
                let h = headers[i]
                h.frame = NSRect(x: 0, y: y, width: pageWidth, height: Self.headerHeight)
                if let l = h.subviews.first, let cb = h.subviews.last {
                    l.frame.origin = NSPoint(x: 0, y: ((Self.headerHeight - l.frame.height) / 2).rounded())
                    cb.frame.origin = NSPoint(x: pageWidth - cb.frame.width,
                                              y: ((Self.headerHeight - cb.frame.height) / 2).rounded())
                }
                y += Self.headerHeight
            }
            let h = (pageWidth * (aspect(images[i]) ?? firstAspect)).rounded()
            canvases[i].frame = NSRect(x: 0, y: y, width: pageWidth, height: h)
            canvases[i].window?.invalidateCursorRects(for: canvases[i])
            y += h + (i < shown - 1 ? 8 : 0)
        }
        doc.frame = NSRect(x: 0, y: 0, width: pageWidth, height: max(y, viewportHeight))
    }

    private func aspect(_ img: NSImage?) -> CGFloat? {
        guard let s = img?.size, s.width > 0, s.height > 0 else { return nil }
        return s.height / s.width
    }

    /// 让第 `i` 页的页顶落在滚动区上部，上一页的底也还看得到一截（接缝两边都在眼前）。
    private func scrollToPage(_ i: Int) {
        guard canvases.indices.contains(i) else { return }
        let visibleH = scroll.contentView.bounds.height
        let top = canvases[i].frame.minY - Self.headerHeight - visibleH * 0.3
        let maxY = max(0, doc.frame.height - visibleH)
        scroll.contentView.scroll(to: NSPoint(x: scroll.contentView.bounds.minX, y: min(max(0, top), maxY)))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    private func loadMissingImages() {
        guard let ws = workspace else { return }
        for i in 1..<max(1, shown) where images[i] == nil && !requested.contains(i) {
            requested.insert(i)
            ExerciseOriginal.pageImage(documentId: documentId, page: firstPage + i, workspace: ws,
                                       pixelWidth: ExerciseRegionPicker.renderWidth) { [weak self] img in
                guard let self, let img else { return }
                self.images[i] = img
                self.canvases[i].image = img
                self.canvases[i].needsDisplay = true
                self.layoutPages()
            }
        }
    }
}

/// 整页 + 一个可拖的框。坐标：`region` 归一化到页面（0…1，左上原点），视图是翻转坐标，换算只乘宽高。
/// 框外压暗、框线用系统强调色——这是在内容上画选区，不是仿系统控件。
/// 放在可缩放的滚动区里（§30）：框线、角块、可拖范围都按放大倍率折回，放大后在屏幕上一样粗细。
@MainActor
final class ExerciseRegionCanvas: NSView {
    var image: NSImage?
    /// 归一化的框；nil = 还没框。
    var region: CGRect? { didSet { needsDisplay = true } }
    /// 这一页不进原题图（§30）：整页压暗、不画框、不接鼠标。
    var excluded = false { didSet { needsDisplay = true; window?.invalidateCursorRects(for: self) } }
    var onChange: () -> Void = {}

    /// 滚动区的放大倍率（屏幕点 / 视图点）。
    private var zoom: CGFloat { max(enclosingScrollView?.magnification ?? 1, 0.01) }

    private enum Drag {
        /// 从这一点起画新框（归一化）。
        case new(CGPoint)
        /// 挪动：按下时的框 + 按下点。
        case move(CGRect, CGPoint)
        /// 改大小：按下时的框 + 拖的是哪几条边。
        case resize(CGRect, left: Bool, right: Bool, top: Bool, bottom: Bool)
    }
    private var drag: Drag?
    /// 太小的框（误点一下）不算数，退回按下前那个。
    private var before: CGRect?
    /// 边 / 角可拖的范围（屏幕点；视图里按倍率折回）。
    private var grab: CGFloat { 7 / zoom }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { !excluded }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func toNorm(_ p: CGPoint) -> CGPoint {
        CGPoint(x: min(1, max(0, p.x / max(bounds.width, 1))), y: min(1, max(0, p.y / max(bounds.height, 1))))
    }
    private func toView(_ r: CGRect) -> CGRect {
        CGRect(x: r.minX * bounds.width, y: r.minY * bounds.height, width: r.width * bounds.width, height: r.height * bounds.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        if let image {
            image.draw(in: bounds, from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: nil)
        } else {
            // 页图还在渲：先垫一块白底（页面本来就是白的），框照样能拖
            NSColor.white.setFill()
            bounds.fill()
        }
        let px = 1 / zoom
        NSColor.separatorColor.setStroke()
        let border = NSBezierPath(rect: bounds.insetBy(dx: px / 2, dy: px / 2))
        border.lineWidth = px
        border.stroke()
        if excluded {
            NSColor.black.withAlphaComponent(0.5).setFill()
            bounds.fill()
            return
        }
        guard let region else { return }
        let r = toView(region)
        // 框外压暗
        let dim = NSBezierPath(rect: bounds)
        dim.append(NSBezierPath(rect: r))
        dim.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(0.35).setFill()
        dim.fill()
        // 框线画在框**外侧**（贴着框边往外 1.5 屏幕点）：线里面就是要显示的内容，不压住框边上的字
        let line = NSBezierPath(rect: r.insetBy(dx: -0.75 * px, dy: -0.75 * px))
        line.lineWidth = 1.5 * px
        NSColor.controlAccentColor.setStroke()
        line.stroke()
        // 四角的小方块（拖它改大小）
        let hs = 4 * px
        for c in [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
                  CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.maxX, y: r.maxY)] {
            let h = NSBezierPath(rect: CGRect(x: c.x - hs, y: c.y - hs, width: 2 * hs, height: 2 * hs))
            NSColor.white.setFill()
            h.fill()
            NSColor.controlAccentColor.setStroke()
            h.lineWidth = 1.5 * px
            h.stroke()
        }
    }

    override func resetCursorRects() {
        guard !excluded else { return }
        addCursorRect(bounds, cursor: .crosshair)
        guard let region else { return }
        let r = toView(region)
        let g = grab
        addCursorRect(r.insetBy(dx: g, dy: g), cursor: .openHand)
        addCursorRect(CGRect(x: r.minX - g, y: r.minY + g, width: 2 * g, height: max(0, r.height - 2 * g)), cursor: .resizeLeftRight)
        addCursorRect(CGRect(x: r.maxX - g, y: r.minY + g, width: 2 * g, height: max(0, r.height - 2 * g)), cursor: .resizeLeftRight)
        addCursorRect(CGRect(x: r.minX + g, y: r.minY - g, width: max(0, r.width - 2 * g), height: 2 * g), cursor: .resizeUpDown)
        addCursorRect(CGRect(x: r.minX + g, y: r.maxY - g, width: max(0, r.width - 2 * g), height: 2 * g), cursor: .resizeUpDown)
    }

    override func mouseDown(with event: NSEvent) {
        guard !excluded else { return }
        window?.makeFirstResponder(self)
        let p = convert(event.locationInWindow, from: nil)
        before = region
        guard let region else { drag = .new(toNorm(p)); return }
        let r = toView(region)
        let g = grab
        let inX = p.x >= r.minX - g && p.x <= r.maxX + g
        let inY = p.y >= r.minY - g && p.y <= r.maxY + g
        let left = inY && abs(p.x - r.minX) <= g, right = inY && abs(p.x - r.maxX) <= g
        let top = inX && abs(p.y - r.minY) <= g, bottom = inX && abs(p.y - r.maxY) <= g
        if left || right || top || bottom {
            drag = .resize(region, left: left, right: right, top: top, bottom: bottom)
        } else if r.contains(p) {
            drag = .move(region, toNorm(p))
        } else {
            drag = .new(toNorm(p))
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard drag != nil else { return }
        // 放大后拖到滚动区边上：跟着滚
        autoscroll(with: event)
        let n = toNorm(convert(event.locationInWindow, from: nil))
        switch drag {
        case .new(let a)?:
            region = CGRect(x: min(a.x, n.x), y: min(a.y, n.y), width: abs(n.x - a.x), height: abs(n.y - a.y))
        case .move(let r, let a)?:
            let x = min(max(0, r.minX + n.x - a.x), 1 - r.width)
            let y = min(max(0, r.minY + n.y - a.y), 1 - r.height)
            region = CGRect(x: x, y: y, width: r.width, height: r.height)
        case .resize(let r, let l, let rt, let t, let b)?:
            var x0 = r.minX, x1 = r.maxX, y0 = r.minY, y1 = r.maxY
            if l { x0 = n.x }
            if rt { x1 = n.x }
            if t { y0 = n.y }
            if b { y1 = n.y }
            region = CGRect(x: min(x0, x1), y: min(y0, y1), width: abs(x1 - x0), height: abs(y1 - y0))
        case nil:
            break
        }
    }

    /// 方向键挪框：一次 1 个屏幕点（按当前倍率折回页面），Shift 10 倍；⌥ 改右边 / 下边（框的大小）。
    override func keyDown(with event: NSEvent) {
        guard !excluded, var r = region,
              let key = event.charactersIgnoringModifiers?.unicodeScalars.first.map({ Int($0.value) }) else {
            super.keyDown(with: event); return
        }
        let mult: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
        let dx = mult / (max(bounds.width, 1) * zoom), dy = mult / (max(bounds.height, 1) * zoom)
        var mx: CGFloat = 0, my: CGFloat = 0
        switch key {
        case NSLeftArrowFunctionKey: mx = -dx
        case NSRightArrowFunctionKey: mx = dx
        case NSUpArrowFunctionKey: my = -dy
        case NSDownArrowFunctionKey: my = dy
        default: super.keyDown(with: event); return
        }
        if event.modifierFlags.contains(.option) {
            r.size.width = min(max(0.01, r.width + mx), 1 - r.minX)
            r.size.height = min(max(0.01, r.height + my), 1 - r.minY)
        } else {
            r.origin.x = min(max(0, r.minX + mx), 1 - r.width)
            r.origin.y = min(max(0, r.minY + my), 1 - r.height)
        }
        region = r
        window?.invalidateCursorRects(for: self)
        onChange()
    }

    override func mouseUp(with event: NSEvent) {
        guard drag != nil else { return }
        defer { drag = nil; window?.invalidateCursorRects(for: self) }
        // 误点一下（框不到 1% 宽 / 高）不算：退回按下前的那个框
        if let r = region, r.width < 0.01 || r.height < 0.01 { region = before }
        onChange()
    }
}
