import AppKit

/// 习题作答用的小画板（`EXERCISE-PLAN.md §11.2`）：白纸黑字，一支笔 + 整笔擦除的橡皮，撤销 / 清空 / 加高由外面的按钮调。
/// 笔迹存在逻辑坐标里（宽恒为 `ExerciseInk.canvasWidth`，`ExerciseInk` 的约定），界面按实际宽度等比缩放——
/// 窗口变宽变窄、换台机器看，字都在原来的位置。
///
/// 笔画少（一道题几十笔），每次动笔整张重画就够快，不像画板那样分块缓存（`ScratchInkTiles`）。
/// 鼠标 / 触控板没有压感，按 0.5 画；数位板（`tabletPoint`）用真实压感。
@MainActor
final class ExerciseInkPad: NSView {
    enum Tool { case pen, eraser }

    private(set) var ink = ExerciseInk()
    var tool: Tool = .pen
    /// 能不能写（交卷后只读）。
    var isEditable = true { didSet { window?.invalidateCursorRects(for: self) } }
    /// 笔迹变了（写了一笔 / 擦了 / 撤销 / 清空 / 加高）。
    var onChange: () -> Void = {}

    private var live: [[Float]] = []
    private var undoStack: [ExerciseInk] = []
    /// 这一下擦除有没有擦到东西（擦到了才压一次撤销）。
    private var erasedInGesture = false

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// 换一份笔迹（换题 / 显示交过的作答）：撤销记录清空。
    func load(_ ink: ExerciseInk?) {
        self.ink = ink ?? ExerciseInk()
        live = []
        undoStack = []
        needsDisplay = true
    }

    var canUndo: Bool { !undoStack.isEmpty }
    var canGrow: Bool { ink.height < ExerciseInk.maxHeight }

    func undo() {
        guard let last = undoStack.popLast() else { return }
        ink = last
        needsDisplay = true
        onChange()
    }

    func clear() {
        guard !ink.strokes.isEmpty else { return }
        pushUndo()
        ink.strokes = []
        needsDisplay = true
        onChange()
    }

    /// 加高一截（写不下了）。
    func grow() {
        guard canGrow else { return }
        pushUndo()
        ink.height = min(ExerciseInk.maxHeight, ink.height + 200)
        onChange()
    }

    /// 在这个宽度下画板有多高。
    func height(forWidth w: CGFloat) -> CGFloat { CGFloat(ink.height / ink.width) * w }

    private var scale: CGFloat { bounds.width / CGFloat(ink.width) }

    private func pushUndo() {
        undoStack.append(ink)
        if undoStack.count > 60 { undoStack.removeFirst() }
    }

    // MARK: - 画

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let paper = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
        NSColor.white.setFill()
        paper.fill()
        NSColor.separatorColor.setStroke()
        paper.lineWidth = 1
        paper.stroke()
        ctx.saveGState()
        paper.addClip()
        ExerciseInkRender.draw(ink.strokes, in: ctx, scale: scale)
        if !live.isEmpty {
            ExerciseInkRender.draw([ExerciseInk.Stroke(width: ExerciseInkRender.penWidth, points: live)], in: ctx, scale: scale)
        }
        ctx.restoreGState()
    }

    override func resetCursorRects() {
        if isEditable { addCursorRect(bounds, cursor: .crosshair) }
    }

    // MARK: - 输入

    private func logical(_ event: NSEvent) -> [Float] {
        let p = convert(event.locationInWindow, from: nil)
        let s = max(scale, 0.0001)
        let pressure: Float = event.subtype == .tabletPoint ? max(0.05, event.pressure) : 0.5
        return [Float(p.x / s), Float(p.y / s), pressure]
    }

    override func mouseDown(with event: NSEvent) {
        guard isEditable else { return }
        window?.makeFirstResponder(nil)   // 打字框里的光标收起来，免得写着写着还在那边输入
        let pt = logical(event)
        switch tool {
        case .pen:
            live = [pt]
            needsDisplay = true
        case .eraser:
            erasedInGesture = false
            erase(at: pt)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard isEditable else { return }
        let pt = logical(event)
        switch tool {
        case .pen:
            guard let last = live.last else { return }
            let dx = pt[0] - last[0], dy = pt[1] - last[1]
            guard dx * dx + dy * dy >= 0.16 else { return }   // 0.4 逻辑点以内的抖动不记
            live.append(pt)
            needsDisplay = true
        case .eraser:
            erase(at: pt)
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard isEditable, tool == .pen, !live.isEmpty else { return }
        pushUndo()
        ink.strokes.append(ExerciseInk.Stroke(width: ExerciseInkRender.penWidth, points: live.map(Self.rounded)))
        live = []
        needsDisplay = true
        onChange()
    }

    /// 整笔擦：橡皮圈（半径 8 逻辑点）碰到哪一笔就去掉哪一笔。
    private func erase(at p: [Float]) {
        let r: Float = 8
        let before = ink.strokes.count
        let hit = ink.strokes.filter { s in
            s.points.contains { q in
                let dx = q[0] - p[0], dy = q[1] - p[1]
                return dx * dx + dy * dy <= r * r
            }
        }
        guard !hit.isEmpty else { return }
        if !erasedInGesture { pushUndo(); erasedInGesture = true }
        ink.strokes.removeAll { hit.contains($0) }
        if ink.strokes.count != before {
            needsDisplay = true
            onChange()
        }
    }

    /// 存盘前把坐标收到 0.1 点、压感收到两位小数：JSON 短一半，肉眼看不出差别。
    private static func rounded(_ p: [Float]) -> [Float] {
        [(p[0] * 10).rounded() / 10, (p[1] * 10).rounded() / 10, (p[2] * 100).rounded() / 100]
    }
}

/// 手写作答怎么画：练习页的小画板与给 Agent 看的 PNG（MCP `render_exercise_answer`、「让 Agent 批改」）共用一份。
enum ExerciseInkRender {
    /// 笔宽（逻辑点）。圆珠笔压感 0.5 时实际约 1.9 点粗。
    static let penWidth: Double = 2.6
    static let color = InkColor(r: 28, g: 28, b: 30, a: 1)

    static func inkStroke(_ s: ExerciseInk.Stroke) -> InkStroke {
        InkStroke(page: 0, color: color, width: s.width, type: .ballpoint,
                  points: s.points.map { q in
                      InkPoint(q.count > 0 ? q[0] : 0, q.count > 1 ? q[1] : 0, q.count > 2 ? q[2] : 0.5)
                  })
    }

    /// 在 `ctx` 里画（y 向下的坐标；1 逻辑点 = `scale` 个单位）。
    static func draw(_ strokes: [ExerciseInk.Stroke], in ctx: CGContext, scale: CGFloat) {
        for s in strokes {
            InkRenderCG.drawStroke(inkStroke(s), in: ctx, inkScale: scale) { p in
                CGPoint(x: CGFloat(p.x) * scale, y: CGFloat(p.y) * scale)
            }
        }
    }

    /// 白底 PNG（`pixelWidth` 像素宽，高按画板比例）。没有笔画 → nil。
    static func png(_ ink: ExerciseInk, pixelWidth: Int) -> Data? {
        guard !ink.isEmpty, ink.width > 0 else { return nil }
        let scale = CGFloat(pixelWidth) / CGFloat(ink.width)
        let h = max(1, Int((CGFloat(ink.height) * scale).rounded(.up)))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: pixelWidth, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: pixelWidth, height: h))
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)
        draw(ink.strokes, in: ctx, scale: scale)
        guard let img = ctx.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])
    }
}
