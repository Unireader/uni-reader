import AppKit

/// 「设置原题区域…」那张表（`EXERCISE-PLAN.md §25`，用户 2026-11-12：「练习题的 PDF 参考图，支持设置区间，这样不用显示完整一页」）。
///
/// 标准 `NSAlert`，附件区是这道题所在的**整页**（同「原题」那份渲染，开着扫描页对齐就是对齐后的页面），
/// 在上面拖出一个框：框外拖 = 重画，框内拖 = 挪动，拖边 / 角 = 改大小。
/// 「保存」写进 `payload.region`（归一化 `[x, y, w, h]`、左上原点，与 Agent 导入时给的同一个字段）；
/// 「用整页」= 去掉框（nil），看原题时又显示整页。安卓两种模式看原题本来就按这个框裁，同步过去就跟着变。
///
/// **跨页的题**（§26，用户：「题目从第一页开始到第二页，图在第二页……就没办法裁剪实际参考图」）：上面「题目在」选几页，
/// 几页从上到下排在一个滚动区里，每页各框一块；后面几页的框存进 `payload.next_regions`。新接上的一页先放一个
/// 页顶的框（左右跟上一页的框对齐），多数时候只要往下拖底边。
@MainActor
enum ExerciseRegionPicker {

    /// 先渲起始页，渲出来再弹表（渲不出来 = 文件不在，说一声）。`done(nil, nil)` = 用整页；取消不回调。
    static func present(on window: NSWindow, exercise e: Exercise, workspace ws: WorkspaceManager,
                        done: @escaping (_ region: [Double]?, _ next: [[Double]]?) -> Void) {
        func missing() {
            let a = NSAlert()
            a.messageText = L("Can’t show the page of this question")
            a.informativeText = L("The PDF it comes from is not on this Mac.")
            a.beginSheetModal(for: window)
        }
        guard let docId = e.documentId, let page = e.page else { missing(); return }
        ExerciseOriginal.pageImage(documentId: docId, page: page, workspace: ws, pixelWidth: 1600) { [weak window, weak ws] img in
            guard let window, let ws, window.attachedSheet == nil else { return }
            guard let img else { missing(); return }
            let pageCount = ws.document(id: docId)?.pageCount ?? 0
            let maxPages = max(1, min(1 + ExerciseRegion.maxNextPages, pageCount - page))
            ExerciseRegionSheet(documentId: docId, firstPage: page, maxPages: maxPages, workspace: ws,
                                first: img, region: e.payload.region, next: e.payload.nextRegions, done: done)
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
    private let done: ([Double]?, [[Double]]?) -> Void

    /// 每页的框（归一化）与页图，下标 0 = 起始页；长度 = `maxPages`。没显示出来的页的框也留着，页数改回来还在。
    private var boxes: [CGRect?]
    private var images: [NSImage?]
    private var requested: Set<Int> = []
    /// 现在显示几页。
    private var shown: Int

    private let canvases: [ExerciseRegionCanvas]
    /// 第 2 页起每页上面那一行「第 N 页」。
    private let pageLabels: [NSTextField]
    private let doc = FlippedView()
    private let scroll = NSScrollView()
    private let popup = NSPopUpButton()
    private weak var saveButton: NSButton?

    /// 页图在表里的宽（点）、滚动区的高：按起始页整页塞得下算（同改之前那张表的大小）。
    private var pageWidth: CGFloat = 0
    private var viewportHeight: CGFloat = 0
    private static let labelHeight: CGFloat = 26

    init(documentId: String, firstPage: Int, maxPages: Int, workspace: WorkspaceManager, first: NSImage,
         region: [Double]?, next: [[Double]]?, done: @escaping ([Double]?, [[Double]]?) -> Void) {
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
        canvases = (0..<maxPages).map { _ in ExerciseRegionCanvas(frame: .zero) }
        pageLabels = (0..<maxPages).map { i in
            let l = NSTextField(labelWithString: String(format: L("Page %d"), firstPage + i + 1))
            l.font = .systemFont(ofSize: 11, weight: .medium)
            l.textColor = .labelColor
            l.alignment = .center
            return l
        }
        super.init()
    }

    func show(on window: NSWindow) {
        // 起始页整页按比例塞进滚动区：宽不超过 560，高不超过窗口能放下的（太矮的窗口也至少 320）
        let maxW: CGFloat = 560
        let maxH = max(320, min(760, window.frame.height - 260))
        let size = images[0]?.size ?? NSSize(width: 600, height: 800)
        let scale = min(maxW / max(size.width, 1), maxH / max(size.height, 1))
        pageWidth = (size.width * scale).rounded()
        viewportHeight = (size.height * scale).rounded()

        for (i, c) in canvases.enumerated() {
            c.image = images[i]
            c.region = boxes[i]
            c.onChange = { [weak self, weak c] in
                guard let self, let c else { return }
                self.boxes[i] = c.region
                self.updateSave()
            }
            doc.addSubview(c)
        }
        for l in pageLabels { doc.addSubview(l) }

        // 传统滚动条占宽：滚动区比页宽多出这一截，页面不被盖住
        let scrollerW = NSScroller.preferredScrollerStyle == .legacy
            ? NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy) : 0
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.documentView = doc

        let container = FlippedView()
        var y: CGFloat = 0
        let width = pageWidth + scrollerW
        if maxPages > 1 {
            let label = NSTextField(labelWithString: L("Question is on:"))
            label.textColor = .labelColor
            label.sizeToFit()
            for n in 1...maxPages {
                popup.addItem(withTitle: n == 1 ? String(format: L("Page %d only"), firstPage + 1)
                                                : String(format: L("Pages %d–%d"), firstPage + 1, firstPage + n))
            }
            popup.selectItem(at: shown - 1)
            popup.target = self
            popup.action = #selector(pagesChanged)
            popup.sizeToFit()
            let rowH = max(label.frame.height, popup.frame.height)
            label.frame.origin = NSPoint(x: 0, y: ((rowH - label.frame.height) / 2).rounded())
            popup.frame.origin = NSPoint(x: label.frame.maxX + 6, y: ((rowH - popup.frame.height) / 2).rounded())
            container.addSubview(label)
            container.addSubview(popup)
            y = rowH + 10
        }
        scroll.frame = NSRect(x: 0, y: y, width: width, height: viewportHeight)
        container.addSubview(scroll)
        container.frame = NSRect(x: 0, y: 0, width: width, height: y + viewportHeight)
        layoutPages()
        loadMissingImages()

        let a = NSAlert()
        a.messageText = L("Set Question Area")
        a.informativeText = maxPages > 1
            ? L("Drag a box around the question. Drag inside the box to move it, drag its edges or corners to resize. Original then shows only this part of the page.")
              + "\n" + L("If the question runs onto the next page (say its figure is there), choose the pages above and box the part on each page; Original shows the parts one above the other.")
            : L("Drag a box around the question. Drag inside the box to move it, drag its edges or corners to resize. Original then shows only this part of the page.")
        a.accessoryView = container
        let save = a.addButton(withTitle: L("Save"))
        a.addButton(withTitle: L("Cancel"))
        a.addButton(withTitle: L("Use Whole Page"))
        saveButton = save
        updateSave()
        a.beginSheetModal(for: window) { resp in self.finish(resp) }
        if shown > 1 { scrollToPage(shown - 1) }
    }

    private func finish(_ resp: NSApplication.ModalResponse) {
        switch resp {
        case .alertFirstButtonReturn:
            let picked = boxes.prefix(shown).compactMap { $0 }
            guard picked.count == shown, let first = picked.first else { return }
            func arr(_ r: CGRect) -> [Double] { [r.minX, r.minY, r.width, r.height] }
            let next = picked.dropFirst().map(arr)
            done(arr(first), next.isEmpty ? nil : Array(next))
        case .alertThirdButtonReturn:
            done(nil, nil)
        default:
            break
        }
    }

    /// 显示的每一页都框好了才能存。
    private func updateSave() {
        saveButton?.isEnabled = boxes.prefix(shown).allSatisfy { $0 != nil }
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

    /// 从上到下摆显示的几页（第 2 页起上面一行页码）；页高按各自页图的比例，还没渲出来的先按起始页的比例。
    private func layoutPages() {
        let firstAspect = aspect(images[0]) ?? (viewportHeight / max(pageWidth, 1))
        var y: CGFloat = 0
        for i in 0..<maxPages {
            let on = i < shown
            canvases[i].isHidden = !on
            pageLabels[i].isHidden = !on || i == 0
            guard on else { continue }
            if i > 0 {
                pageLabels[i].frame = NSRect(x: 0, y: y + 6, width: pageWidth, height: Self.labelHeight - 8)
                y += Self.labelHeight
            }
            let h = (pageWidth * (aspect(images[i]) ?? firstAspect)).rounded()
            canvases[i].frame = NSRect(x: 0, y: y, width: pageWidth, height: h)
            canvases[i].window?.invalidateCursorRects(for: canvases[i])
            y += h
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
        let top = canvases[i].frame.minY - Self.labelHeight - viewportHeight * 0.3
        let maxY = max(0, doc.frame.height - viewportHeight)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: min(max(0, top), maxY)))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    private func loadMissingImages() {
        guard let ws = workspace else { return }
        for i in 1..<max(1, shown) where images[i] == nil && !requested.contains(i) {
            requested.insert(i)
            ExerciseOriginal.pageImage(documentId: documentId, page: firstPage + i, workspace: ws, pixelWidth: 1600) { [weak self] img in
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
@MainActor
final class ExerciseRegionCanvas: NSView {
    var image: NSImage?
    /// 归一化的框；nil = 还没框。
    var region: CGRect? { didSet { needsDisplay = true } }
    var onChange: () -> Void = {}

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
    private static let grab: CGFloat = 7

    override var isFlipped: Bool { true }
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
        NSColor.separatorColor.setStroke()
        NSBezierPath(rect: bounds.insetBy(dx: 0.5, dy: 0.5)).stroke()
        guard let region else { return }
        let r = toView(region)
        // 框外压暗
        let dim = NSBezierPath(rect: bounds)
        dim.append(NSBezierPath(rect: r))
        dim.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(0.35).setFill()
        dim.fill()
        let line = NSBezierPath(rect: r.insetBy(dx: 1, dy: 1))
        line.lineWidth = 2
        NSColor.controlAccentColor.setStroke()
        line.stroke()
        // 四角的小方块（拖它改大小）
        for c in [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
                  CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.maxX, y: r.maxY)] {
            let h = NSBezierPath(rect: CGRect(x: c.x - 4, y: c.y - 4, width: 8, height: 8))
            NSColor.white.setFill()
            h.fill()
            NSColor.controlAccentColor.setStroke()
            h.lineWidth = 1.5
            h.stroke()
        }
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
        guard let region else { return }
        let r = toView(region)
        let g = Self.grab
        addCursorRect(r.insetBy(dx: g, dy: g), cursor: .openHand)
        addCursorRect(CGRect(x: r.minX - g, y: r.minY + g, width: 2 * g, height: max(0, r.height - 2 * g)), cursor: .resizeLeftRight)
        addCursorRect(CGRect(x: r.maxX - g, y: r.minY + g, width: 2 * g, height: max(0, r.height - 2 * g)), cursor: .resizeLeftRight)
        addCursorRect(CGRect(x: r.minX + g, y: r.minY - g, width: max(0, r.width - 2 * g), height: 2 * g), cursor: .resizeUpDown)
        addCursorRect(CGRect(x: r.minX + g, y: r.maxY - g, width: max(0, r.width - 2 * g), height: 2 * g), cursor: .resizeUpDown)
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        before = region
        guard let region else { drag = .new(toNorm(p)); return }
        let r = toView(region)
        let g = Self.grab
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

    override func mouseUp(with event: NSEvent) {
        defer { drag = nil; window?.invalidateCursorRects(for: self) }
        // 误点一下（框不到 1% 宽 / 高）不算：退回按下前的那个框
        if let r = region, r.width < 0.01 || r.height < 0.01 { region = before }
        onChange()
    }
}
