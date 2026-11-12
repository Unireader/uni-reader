import AppKit

/// 「设置原题区域…」那张表（`EXERCISE-PLAN.md §25`，用户 2026-11-12：「练习题的 PDF 参考图，支持设置区间，这样不用显示完整一页」）。
///
/// 标准 `NSAlert`，附件区是这道题所在的**整页**（同「原题」那份渲染，开着扫描页对齐就是对齐后的页面），
/// 在上面拖出一个框：框外拖 = 重画，框内拖 = 挪动，拖边 / 角 = 改大小。
/// 「保存」写进 `payload.region`（归一化 `[x, y, w, h]`、左上原点，与 Agent 导入时给的同一个字段）；
/// 「用整页」= 去掉框（nil），看原题时又显示整页。安卓两种模式看原题本来就按这个框裁，同步过去就跟着变。
@MainActor
enum ExerciseRegionPicker {

    /// 先渲整页，渲出来再弹表（渲不出来 = 文件不在，说一声）。`done(nil)` = 用整页；取消不回调。
    static func present(on window: NSWindow, exercise e: Exercise, workspace ws: WorkspaceManager,
                        done: @escaping ([Double]?) -> Void) {
        ExerciseOriginal.image(for: e, workspace: ws, pixelWidth: 1600, wholePage: true) { [weak window] img in
            guard let window, window.attachedSheet == nil else { return }
            guard let img else {
                let a = NSAlert()
                a.messageText = L("Can’t show the page of this question")
                a.informativeText = L("The PDF it comes from is not on this Mac.")
                a.beginSheetModal(for: window)
                return
            }
            show(on: window, image: img, region: e.payload.region, done: done)
        }
    }

    private static func show(on window: NSWindow, image: NSImage, region: [Double]?, done: @escaping ([Double]?) -> Void) {
        // 整页按比例塞进附件区：宽不超过 560，高不超过窗口能放下的（太矮的窗口也至少 320）
        let maxW: CGFloat = 560
        let maxH = max(320, min(760, window.frame.height - 240))
        let size = image.size
        let scale = min(maxW / max(size.width, 1), maxH / max(size.height, 1))
        let canvas = ExerciseRegionCanvas(frame: NSRect(x: 0, y: 0, width: (size.width * scale).rounded(),
                                                        height: (size.height * scale).rounded()))
        canvas.image = image
        if let r = region, r.count == 4 { canvas.region = CGRect(x: r[0], y: r[1], width: r[2], height: r[3]) }

        let a = NSAlert()
        a.messageText = L("Set Question Area")
        a.informativeText = L("Drag a box around the question. Drag inside the box to move it, drag its edges or corners to resize. Original then shows only this part of the page.")
        a.accessoryView = canvas
        let save = a.addButton(withTitle: L("Save"))
        a.addButton(withTitle: L("Cancel"))
        a.addButton(withTitle: L("Use Whole Page"))
        save.isEnabled = canvas.region != nil
        canvas.onChange = { [weak save, weak canvas] in save?.isEnabled = canvas?.region != nil }
        a.beginSheetModal(for: window) { resp in
            switch resp {
            case .alertFirstButtonReturn:
                guard let r = canvas.region else { return }
                done([r.minX, r.minY, r.width, r.height])
            case .alertThirdButtonReturn:
                done(nil)
            default:
                break
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
        image?.draw(in: bounds, from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: nil)
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
