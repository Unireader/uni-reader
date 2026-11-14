import AppKit

/// 盖在练习页上的**眼前这道题的草稿纸**（`EXERCISE-PLAN.md §29`）。就是草稿纸那块画布（`ScratchPadNSView`，画板模式），
/// 笔、橡皮、框选、撤销、纸样都照草稿纸 / 画板的用法，笔从窗格的笔架上选。一道题一张，换题就换一张；
/// 会话由 `ExerciseScratchHost` 按题共用——平板模式2 开着同一道题时写的是同一张，两边实时看得见。
@MainActor
final class ExerciseScratchPane: NSView {
    private let app: AppModel
    private weak var workspace: WorkspaceManager?
    private(set) var host: ExerciseScratchHost?
    private var padView: ScratchPadNSView?
    /// 浮在纸上的题目卡片（题干 + 选项；能拖、点标题收成一行）。
    private let card = ExerciseQuestionCard()
    /// 换了一张纸（换题 / 收起）：窗格据此把笔架绑到新会话上。
    var onSessionChange: () -> Void = {}
    /// 纸上的关闭键 / Esc（练习页把它收起来）。
    var onClose: () -> Void = {}

    var session: DocSession? { host?.session }

    init(app: AppModel, workspace: WorkspaceManager) {
        self.app = app
        self.workspace = workspace
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        card.onChange = { [weak self] in self?.needsLayout = true }
        addSubview(card)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) 不支持") }

    override var isFlipped: Bool { true }

    /// 显示这道题的草稿纸（nil = 没有题 / 收起：放掉）。同一道题再调只改名字和卡片。
    func show(_ e: Exercise?, title: String) {
        let exerciseId = e?.id
        needsLayout = true
        if let e { card.set(e, label: e.number.isEmpty ? title : String(format: L("No. %@"), e.number)) }
        if host?.exerciseId == exerciseId {
            padView?.fixedTitle = title
            return
        }
        padView?.removeFromSuperview()
        padView = nil
        let old = host
        host = nil
        if let id = exerciseId, let ws = workspace,
           let h = ExerciseScratchHost.acquire(exerciseId: id, workspace: ws, app: app) {
            host = h
            let v = ScratchPadNSView(app: app, session: h.session, padID: h.padID, docKey: BoardNote.rowPrefix + h.padID.uuidString)
            v.workspace = ws
            v.fixedTitle = title
            v.onRequestClose = { [weak self] in self?.onClose() }
            v.frame = bounds
            v.autoresizingMask = [.width, .height]
            addSubview(v, positioned: .below, relativeTo: card)
            padView = v
        }
        old?.release()
        onSessionChange()
    }

    /// 标签拆掉 / 收起前调：放掉手上那张（平板若还开着同一道题，会话留给它）。
    func detach() { show(nil, title: "") }

    override func layout() {
        super.layout()
        padView?.frame = bounds
        card.isHidden = host == nil
        card.place(in: bounds)
    }
}

/// 草稿纸上浮着的题目（`EXERCISE-PLAN.md §29`，用户 2026-11-14：「草稿纸全屏了有办法把题目也显示吗」）。
/// 系统材质底（`NSVisualEffectView`），文字一律 `labelColor`（红线 4）。拖标题那一行挪位置，点一下收成一行 / 展开；
/// 位置（占纸的比例）和收没收记在本机。正文太长时卡片最高占纸的 45%，里面滚。
@MainActor
final class ExerciseQuestionCard: NSView {
    var onChange: () -> Void = {}

    private let material = NSVisualEffectView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let chevron = NSImageView()
    private let scroll = NSScrollView()
    private let body = AgentMarkdownView(text: "", fontSize: 14, documentId: "exercise-scratch-card")
    private var shownText = ""

    private static let posXKey = "exercise.scratch.card.x"
    private static let posYKey = "exercise.scratch.card.y"
    private static let collapsedKey = "exercise.scratch.card.collapsed"
    private var collapsed = UserDefaults.standard.bool(forKey: ExerciseQuestionCard.collapsedKey)
    private static let headerH: CGFloat = 34
    private static let pad: CGFloat = 12

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        shadow = {
            let s = NSShadow()
            s.shadowColor = NSColor.black.withAlphaComponent(0.25)
            s.shadowBlurRadius = 8
            s.shadowOffset = NSSize(width: 0, height: -2)
            return s
        }()
        material.material = .popover
        material.blendingMode = .withinWindow
        material.state = .active
        material.wantsLayer = true
        material.layer?.cornerRadius = 12
        material.layer?.masksToBounds = true
        addSubview(material)
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        chevron.contentTintColor = .labelColor
        chevron.symbolConfiguration = .init(pointSize: 12, weight: .semibold)
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = body
        body.onHeightChange = { [weak self] in self?.onChange() }
        for v in [titleLabel, chevron, scroll] as [NSView] { material.addSubview(v) }
        setAccessibilityRole(.group)
        setAccessibilityLabel(L("Question"))
        syncChevron()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) 不支持") }

    /// 换成这道题（题干 + 选项）。
    func set(_ e: Exercise, label: String) {
        titleLabel.stringValue = label
        var md = e.payload.stem
        for o in e.payload.options { md += "\n\n**\(o.key).** \(o.text)" }
        if md != shownText {
            shownText = md
            body.update(text: md)
            scroll.contentView.scroll(to: .zero)
            onChange()
        }
    }

    private func syncChevron() {
        chevron.image = NSImage(systemSymbolName: collapsed ? "chevron.down" : "chevron.up",
                                accessibilityDescription: collapsed ? L("Expand") : L("Collapse"))
        toolTip = collapsed ? L("Click the title to show the question. Drag it to move.") : L("Click the title to fold the question away. Drag it to move.")
    }

    /// 在纸上摆好（`area` = 纸的 bounds）：宽最多 560，按记住的位置放、夹在纸里。
    func place(in area: NSRect) {
        guard area.width > 40, area.height > 40 else { return }
        let w = min(560, area.width - 32)
        let inner = w - Self.pad * 2
        if abs(body.frame.width - inner) > 0.5 { body.frame.size.width = inner }
        let bodyH = collapsed ? 0 : min(body.intrinsicContentSize.height, area.height * 0.45)
        let h = Self.headerH + (collapsed ? 0 : bodyH + Self.pad)
        let d = UserDefaults.standard
        let fx = d.object(forKey: Self.posXKey) as? Double ?? 0.03
        let fy = d.object(forKey: Self.posYKey) as? Double ?? 0.14
        let x = min(max(8, area.width * fx), max(8, area.width - w - 8))
        let y = min(max(8, area.height * fy), max(8, area.height - h - 8))
        frame = NSRect(x: x, y: y, width: w, height: h)
        material.frame = bounds
        chevron.frame = NSRect(x: w - Self.pad - 16, y: (Self.headerH - 16) / 2, width: 16, height: 16)
        titleLabel.frame = NSRect(x: Self.pad, y: (Self.headerH - 17) / 2, width: max(0, w - Self.pad * 2 - 22), height: 17)
        scroll.isHidden = collapsed
        scroll.frame = NSRect(x: Self.pad, y: Self.headerH, width: inner, height: bodyH)
        body.frame.size.height = body.intrinsicContentSize.height
    }

    // MARK: 拖标题挪位置 / 点一下收起

    private var dragStart: NSPoint?
    private var originStart = NSPoint.zero
    private var dragged = false

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard p.y <= Self.headerH else { super.mouseDown(with: event); return }
        dragStart = superview?.convert(event.locationInWindow, from: nil)
        originStart = frame.origin
        dragged = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let s = dragStart, let sv = superview else { super.mouseDragged(with: event); return }
        let p = sv.convert(event.locationInWindow, from: nil)
        let dx = p.x - s.x, dy = p.y - s.y
        if !dragged, abs(dx) + abs(dy) < 3 { return }
        dragged = true
        let area = sv.bounds
        let x = min(max(8, originStart.x + dx), max(8, area.width - frame.width - 8))
        let y = min(max(8, originStart.y + dy), max(8, area.height - frame.height - 8))
        frame.origin = NSPoint(x: x, y: y)
    }

    override func mouseUp(with event: NSEvent) {
        guard dragStart != nil, let sv = superview else { super.mouseUp(with: event); return }
        dragStart = nil
        let d = UserDefaults.standard
        if dragged {
            d.set(Double(frame.minX / max(1, sv.bounds.width)), forKey: Self.posXKey)
            d.set(Double(frame.minY / max(1, sv.bounds.height)), forKey: Self.posYKey)
        } else {
            collapsed.toggle()
            d.set(collapsed, forKey: Self.collapsedKey)
            syncChevron()
        }
        onChange()
    }

    /// 卡片上点不到纸（别让笔 / 拖动穿过去）。
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, frame.contains(point) else { return nil }
        return super.hitTest(point) ?? self
    }
}
