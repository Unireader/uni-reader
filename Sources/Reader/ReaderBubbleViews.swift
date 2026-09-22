import AppKit
import Combine
import SwiftUI

// MARK: - 气泡正文：Markdown 引擎只读渲染（方案 §5 风险 3：唯一保留的 SwiftUI，只包这一块正文）

/// 把引擎的只读正文包一层，只为把**排好版的真实高度**报回来（第一帧先用 `NoteBubble.textHeight` 的估计值占位）。
struct BubbleMarkdownHost: View {
    let text: String
    let fontSize: CGFloat
    let width: CGFloat
    let documentId: String
    /// 本工作区的 `[[…]]` 服务（`MARKDOWN-NOTES-PLAN.md §3`）：气泡里的 wiki 链接要显示成**当前标题**，
    /// 没有它就会露出 `[[名字|<uuid>]]` 这个存储形态。由 `ReaderView+Overlay` 建气泡时塞进来。
    var wiki: WorkspaceWikiIndex?
    let onHeight: (CGFloat) -> Void

    var body: some View {
        MarkdownNoteReader(text: text, fontSize: fontSize, width: width, documentId: documentId, wiki: wiki)
            .frame(width: width)
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { onHeight($0) }
            .frame(width: width, alignment: .topLeading)
    }
}

/// 气泡里的正文容器：内容比高度上限高时在卡片里滚；**放得下时不接滚轮**，交给页面（用户 2026-09-16）。
/// 可滚时滚到头也不漏给页面（`NSScrollView` 本来就不往外传）。
final class BubbleScrollView: NSScrollView {
    var scrollable = false
    override func scrollWheel(with event: NSEvent) {
        // 🔴 放不下时**不能**给 `nextResponder`：它就是把滚轮转进来的那张卡片（本视图的父视图），
        // 两个 `scrollWheel` 会互相调用到栈溢出（2026-09-22 崩溃：滚一个内容放得下的文字笔记气泡必崩）。
        // 要交给页面就直接跳过卡片，往卡片的下一个响应者去。
        if scrollable { super.scrollWheel(with: event) } else { superview?.nextResponder?.scrollWheel(with: event) }
    }
}

/// flipped 的正文底板（滚动视图的 documentView）。
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

// MARK: - 卡片：拖动 / 改大小 / 单击（文字气泡与图片气泡共用，数学在 `NoteCardDrag`）

/// 一张展开的笔记卡片。全部尺寸是**屏幕点**（页的显示尺寸），摆在覆盖层里；页面滚动 / 缩放时由阅读区重新摆放。
///
/// 手势：按下的位置决定做什么（`NoteCardZone`：四边四角改大小，其余移动）；位移 ≤ 2pt 算单击。
/// 拖动中只改 `live`（预览）并重排自己，松手一次性 `onCommit`。移动 / 改大小都不许盖住自己的图钉（`NoteCardPin`）。
/// **正文不吃鼠标**：卡片把命中全部收归自己（按在正文上拖 = 移动卡片，用户 2026-09-16），滚轮转交正文容器。
class ReaderCardView: NSView {
    // 排版输入（每次 `update` 给，拖动中也用它们算预览）
    var metrics = NoteBubble.metrics(pageWidth: 1000, followsZoom: false)
    /// 页在覆盖层里的矩形（屏幕点）。
    var pageRect: CGRect = .zero
    /// 图钉中心（页内屏幕点）。
    var pin: CGPoint = .zero
    var card: NoteCard?
    /// 拖动进行中的预览卡片。
    var live: NoteCard?
    var interactive = false { didSet { if oldValue != interactive { window?.invalidateCursorRects(for: self) } } }
    /// 卡片此刻在页内的矩形（屏幕点，`layoutCard` 算出）。
    private(set) var frameInPage: CGRect = .zero
    /// 内容全部露出要多高（含内边距）。
    var contentHeight: CGFloat = 0

    var onCommit: ((NoteCard, NoteCardZone) -> Void)?
    var onReset: (() -> Void)?

    private var drag: NoteCardDrag?
    private var downWindow: NSPoint?
    private var moved = false

    let background = CALayer()

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        background.actions = ["bounds": NSNull(), "position": NSNull(), "frame": NSNull(), "contents": NSNull()]
        background.backgroundColor = NSColor(srgbRed: 1, green: 0.992, blue: 0.949, alpha: 0.97).cgColor
        background.borderColor = NSColor.black.withAlphaComponent(0.18).cgColor
        background.borderWidth = 1
        layer?.addSublayer(background)
        // 卡片永远是纸白底深字：外观钉死浅色（正文引擎跟着这个 appearance 走）
        appearance = NSAppearance(named: .aqua)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) 不支持") }

    /// 子类算好大小后调：定位（自动规则 / 摆过的卡片 / 推开图钉）并摆放自己。
    func placeCard(w: CGFloat, h: CGFloat) {
        let m = metrics
        let c = live ?? card
        let size = pageRect.size
        let o = NoteBubble.placed(
            c.map { NoteBubble.cardOrigin($0, w: w, h: h, m: m, pin: pin, pageSize: size) }
                ?? NoteBubble.origin(w: w, h: h, m: m, pin: pin, pinRadius: ReaderPinView.pinRadius, pageSize: size),
            w: w, h: h, m: m, pin: pin, pinRadius: ReaderPinView.pinRadius, pageSize: size)
        frameInPage = CGRect(x: o.x, y: o.y, width: w, height: h)
        let f = frameInPage.offsetBy(dx: pageRect.minX, dy: pageRect.minY)
        if frame != f { frame = f }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        background.frame = bounds
        background.cornerRadius = m.radius
        CATransaction.commit()
    }

    /// 子类按当前输入（含 `live`）重排自己。
    func relayout() {}

    // MARK: 命中：全部收归卡片（正文不吃鼠标）；子类可放行按钮

    override func hitTest(_ point: NSPoint) -> NSView? {
        let p = convert(point, from: superview)
        guard bounds.contains(p) else { return nil }
        if let b = passthroughButton(at: p) { return b }
        return self
    }

    /// 卡片上真的要接点击的小按钮（文字气泡右上角的铅笔）。
    func passthroughButton(at p: NSPoint) -> NSView? { nil }

    /// 滚轮交给正文容器（正文放不下时才由它滚，否则直接给页面）。
    /// 🔴 **别无条件转给容器**：容器放得下时又会把事件传回卡片，两边互相调用直到栈溢出（见 `BubbleScrollView`）。
    var contentScroll: BubbleScrollView? { nil }
    override func scrollWheel(with event: NSEvent) {
        if let s = contentScroll, s.scrollable { s.scrollWheel(with: event) } else { nextResponder?.scrollWheel(with: event) }
    }

    // MARK: 拖动 / 改大小

    override func mouseDown(with event: NSEvent) {
        downWindow = event.locationInWindow
        moved = false
        guard interactive else { drag = nil; return }
        let local = convert(event.locationInWindow, from: nil)
        drag = NoteCardDrag(zone: NoteCardZone.at(local, size: bounds.size), frame: frameInPage,
                            contentHeight: contentHeight, card: card)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let d = drag, let d0 = downWindow else { return }
        let t = CGSize(width: event.locationInWindow.x - d0.x, height: -(event.locationInWindow.y - d0.y))
        if !moved, hypot(t.width, t.height) <= 2 { return }
        moved = true
        live = next(d, t)
        relayout()
    }

    override func mouseUp(with event: NSEvent) {
        defer { drag = nil; downWindow = nil; moved = false }
        guard let d0 = downWindow else { return }
        if moved, let d = drag {
            let t = CGSize(width: event.locationInWindow.x - d0.x, height: -(event.locationInWindow.y - d0.y))
            let c = next(d, t)
            onCommit?(c, d.zone)
            // 提交与清预览同一拍：数据回来之前先按预览摆着，不会弹回原位再跳过去
            card = c
            live = nil
        } else {
            clicked(at: convert(event.locationInWindow, from: nil), event: event)
        }
    }

    /// 单击（卡片内坐标）。
    func clicked(at p: CGPoint, event: NSEvent) {}

    private func next(_ d: NoteCardDrag, _ t: CGSize) -> NoteCard {
        d.card(translation: t, unit: metrics.unit, pin: pin, minSize: NoteBubble.cardMinSize(metrics),
               page: pageRect.size, pinClearance: NoteBubble.pinClearance(metrics, pinRadius: ReaderPinView.pinRadius))
    }

    // MARK: 指针样子：边与角用改大小箭头，其余是张开的手

    override func resetCursorRects() {
        guard interactive else { return }
        let b = bounds, e = NoteCardZone.edge, c = NoteCardZone.corner
        addCursorRect(b.insetBy(dx: e, dy: e), cursor: .openHand)
        addCursorRect(NSRect(x: 0, y: c, width: e, height: max(0, b.height - 2 * c)),
                      cursor: .frameResize(position: .left, directions: .all))
        addCursorRect(NSRect(x: b.width - e, y: c, width: e, height: max(0, b.height - 2 * c)),
                      cursor: .frameResize(position: .right, directions: .all))
        addCursorRect(NSRect(x: c, y: 0, width: max(0, b.width - 2 * c), height: e),
                      cursor: .frameResize(position: .top, directions: .all))
        addCursorRect(NSRect(x: c, y: b.height - e, width: max(0, b.width - 2 * c), height: e),
                      cursor: .frameResize(position: .bottom, directions: .all))
        addCursorRect(NSRect(x: 0, y: 0, width: c, height: c), cursor: .frameResize(position: .topLeft, directions: .all))
        addCursorRect(NSRect(x: b.width - c, y: 0, width: c, height: c),
                      cursor: .frameResize(position: .topRight, directions: .all))
        addCursorRect(NSRect(x: 0, y: b.height - c, width: c, height: c),
                      cursor: .frameResize(position: .bottomLeft, directions: .all))
        addCursorRect(NSRect(x: b.width - c, y: b.height - c, width: c, height: c),
                      cursor: .frameResize(position: .bottomRight, directions: .all))
    }
}

// MARK: - 文字笔记气泡

/// 一条文字笔记展开后的气泡（排版规则同 SwiftUI 版 `NoteBubbleView`，数全从 `NoteBubble` 来）。
final class NoteBubbleNSView: ReaderCardView {
    /// 见 `BubbleMarkdownHost.wiki`。建视图时由阅读区设一次。
    var wiki: WorkspaceWikiIndex?
    private(set) var text = ""
    private var documentId = ""
    private var hasEdit = false
    var onEdit: (() -> Void)?
    var onCopyLink: (() -> Void)?
    /// 正文里的 `[[…]]` 被点中（参数 = 目标 md 笔记 id）。由阅读区接到标签上。
    var onOpenNote: ((String) -> Void)?

    private let scroll = BubbleScrollView()
    private let body = FlippedView()
    private var host: NSHostingView<BubbleMarkdownHost>?
    private let editButton = NSButton()
    /// 引擎排完版报回来的正文高度（完整高度，没钳过）。nil = 还没排。
    private var bodyH: CGFloat?
    private var hostKey = ""

    override init(frame: NSRect) {
        super.init(frame: frame)
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        scroll.hasHorizontalScroller = false
        scroll.documentView = body
        addSubview(scroll)
        editButton.isBordered = false
        editButton.imagePosition = .imageOnly
        editButton.contentTintColor = NSColor.black.withAlphaComponent(0.6)
        editButton.toolTip = L("Edit note")
        editButton.target = self
        editButton.action = #selector(editTapped)
        addSubview(editButton)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) 不支持") }

    @objc private func editTapped() { onEdit?() }

    override var contentScroll: BubbleScrollView? { scroll }

    override func passthroughButton(at p: NSPoint) -> NSView? {
        hasEdit && editButton.frame.contains(p) ? editButton : nil
    }

    func update(text: String, documentId: String, metrics m: NoteBubble.Metrics, pageRect: CGRect, pin: CGPoint,
                card: NoteCard?, interactive: Bool, hasEdit: Bool) {
        if self.text != text { bodyH = nil }
        self.text = text
        self.documentId = documentId
        self.metrics = m
        self.pageRect = pageRect
        self.pin = pin
        if live == nil { self.card = card }
        self.interactive = interactive
        self.hasEdit = hasEdit
        relayout()
    }

    override func relayout() {
        let m = metrics
        let c = live ?? card
        let edit = hasEdit ? m.edit : 0
        let w = NoteBubble.cardWidth(c, auto: NoteBubble.fitWidth(text, m: m, hasEdit: hasEdit), m: m, pageSize: pageRect.size)
        let textW = max(m.fs, w - m.pad * 2 - edit)
        let capH = c?.h.map { max(m.lineHeight, CGFloat($0) * m.unit - m.pad * 2) } ?? m.height(lines: m.maxLines)
        let measured = (bodyH ?? 0) > 1 ? bodyH! : NoteBubble.textHeight(text, width: textW, m: m, maxLines: 10_000)
        let visible = min(measured, capH)
        let h = visible + m.pad * 2
        contentHeight = measured + m.pad * 2
        placeCard(w: w, h: h)

        // 正文：引擎只读渲染（宽 / 字号 / 文字变了才重建）
        let key = "\(text)|\(textW)|\(m.fs)|\(documentId)"
        if key != hostKey {
            hostKey = key
            let root = BubbleMarkdownHost(text: text, fontSize: m.fs, width: textW,
                                          documentId: "\(documentId)-bubble", wiki: wiki) { [weak self] hgt in
                guard let self, abs((self.bodyH ?? 0) - hgt) > 0.5 else { return }
                self.bodyH = hgt
                self.relayout()
            }
            if let host { host.rootView = root } else {
                let h = NSHostingView(rootView: root)
                host = h
                body.addSubview(h)
            }
        }
        scroll.frame = NSRect(x: m.pad, y: m.pad, width: textW, height: visible)
        body.frame = NSRect(x: 0, y: 0, width: textW, height: max(measured, visible))
        host?.frame = NSRect(x: 0, y: 0, width: textW, height: max(measured, visible))
        scroll.scrollable = measured > capH + 0.5

        editButton.isHidden = !hasEdit
        if hasEdit {
            let cfg = NSImage.SymbolConfiguration(pointSize: m.fs * 0.95, weight: .medium)
            editButton.image = NSImage(systemSymbolName: "square.and.pencil", accessibilityDescription: L("Edit note"))?
                .withSymbolConfiguration(cfg)
            editButton.frame = NSRect(x: w - edit - m.pad * 0.4, y: m.pad * 0.4, width: edit, height: edit)
        }
        window?.invalidateCursorRects(for: self)
    }

    override func clicked(at p: CGPoint, event: NSEvent) {
        // 正文不吃鼠标：链接由卡片的单击去开。`[[…]]` 指的是本工作区的 md 笔记（v15）。
        NoteLinkClick.open(at: event, openNote: { [weak self] id in self?.onOpenNote?(id) })
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard interactive else { return nil }
        let menu = NSMenu()
        if hasEdit { menu.addItem(ClosureMenuItem(L("Edit…")) { [weak self] in self?.onEdit?() }) }
        let t = text
        menu.addItem(ClosureMenuItem(L("Copy Note Text")) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(t, forType: .string)
        })
        if let onCopyLink { menu.addItem(ClosureMenuItem(L("Copy Link"), action: onCopyLink)) }
        if card != nil {
            menu.addItem(.separator())
            menu.addItem(ClosureMenuItem(L("Reset Card Size and Position")) { [weak self] in self?.onReset?() })
        }
        return menu
    }
}

// MARK: - 图片笔记气泡

/// 图片笔记展开后的气泡：缩略图 + 说明（排版同 SwiftUI 版 `ImageBubbleView`，尺寸口径 `ImageBubble.size`）。
/// 没有铅笔；单击缩略图看原图；右键「查看原图 / 编辑… / 删除」。`onView == nil` = 悬停预览（不挂菜单、不能拖）。
final class ImageBubbleNSView: ReaderCardView {
    /// 见 `BubbleMarkdownHost.wiki`。
    var wiki: WorkspaceWikiIndex?
    private var note: ImageNote?
    private var info: (url: URL, size: CGSize)?
    var onEdit: (() -> Void)?
    var onView: (() -> Void)?
    var onDelete: (() -> Void)?

    private let scroll = BubbleScrollView()
    private let body = FlippedView()
    private let thumb = CALayer()
    private let placeholder = NSImageView()
    private var captionHost: NSHostingView<BubbleMarkdownHost>?
    private var captionH: CGFloat?
    private var captionKey = ""
    private var thumbRect: CGRect = .zero
    private var thumbSub: AnyCancellable?

    override init(frame: NSRect) {
        super.init(frame: frame)
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        scroll.documentView = body
        body.wantsLayer = true
        thumb.contentsGravity = .resizeAspect
        thumb.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
        body.layer?.addSublayer(thumb)
        placeholder.contentTintColor = NSColor.black.withAlphaComponent(0.6)
        body.addSubview(placeholder)
        addSubview(scroll)
        // 缩略图后台解码好了会发通知，那时再换上
        thumbSub = ImageThumbCache.shared.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.relayout() }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) 不支持") }

    override var contentScroll: BubbleScrollView? { scroll }

    func update(note: ImageNote, info: (url: URL, size: CGSize)?, metrics m: NoteBubble.Metrics,
                pageRect: CGRect, pin: CGPoint, interactive: Bool) {
        if self.note?.caption != note.caption { captionH = nil }
        self.note = note
        self.info = info
        self.metrics = m
        self.pageRect = pageRect
        self.pin = pin
        if live == nil { self.card = note.card }
        self.interactive = interactive && onView != nil
        relayout()
    }

    override func relayout() {
        guard let note else { return }
        let m = metrics
        let c = live ?? card
        let px = info?.size ?? CGSize(width: 4, height: 3)
        let s = ImageBubble.size(m: m, pixelSize: px, caption: note.caption, missing: info == nil, captionH: captionH,
                                 width: c?.w == nil ? nil : NoteBubble.cardWidth(c, auto: m.w, m: m, pageSize: pageRect.size),
                                 maxHeight: c?.h.map { CGFloat($0) * m.unit })
        contentHeight = s.contentH
        placeCard(w: s.w, h: s.h)
        let innerW = max(1, s.w - m.pad * 2)

        scroll.frame = bounds
        body.frame = NSRect(x: 0, y: 0, width: s.w, height: max(s.contentH, s.h))
        scroll.scrollable = s.contentH > s.h + 0.5

        thumbRect = CGRect(x: m.pad + (innerW - s.thumb.width) / 2, y: m.pad, width: s.thumb.width, height: s.thumb.height)
        let scale = window?.backingScaleFactor ?? 2
        let img = info.flatMap { ImageThumbCache.shared.image(url: $0.url, maxPixel: Int((s.thumb.width * scale).rounded(.up))) }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        thumb.frame = thumbRect
        thumb.contents = img
        thumb.backgroundColor = img == nil ? NSColor.black.withAlphaComponent(0.18 * 0.35).cgColor : nil
        thumb.cornerRadius = img == nil ? m.radius * 0.6 : 0
        CATransaction.commit()
        placeholder.isHidden = img != nil
        if img == nil {
            let cfg = NSImage.SymbolConfiguration(pointSize: max(10, m.fs * 1.6), weight: .regular)
            placeholder.image = NSImage(systemSymbolName: info == nil ? "photo.badge.exclamationmark" : "photo",
                                        accessibilityDescription: nil)?.withSymbolConfiguration(cfg)
            placeholder.frame = thumbRect
        }
        toolTip = info == nil ? L("Image file is missing (not in this copy, or already cleaned up).")
                              : (onView != nil ? L("Click to view full size") : nil)

        // 说明：同一个引擎只读渲染，最多 3 行
        if note.caption.isEmpty {
            captionHost?.removeFromSuperview()
            captionHost = nil
            captionKey = ""
        } else {
            let capH = m.height(lines: ImageBubble.captionMaxLines)
            let est = NoteBubble.textHeight(note.caption, width: innerW, m: m, maxLines: ImageBubble.captionMaxLines)
            let h = min((captionH ?? 0) > 1 ? captionH! : est, capH)
            let key = "\(note.caption)|\(innerW)|\(m.fs)"
            if key != captionKey {
                captionKey = key
                let root = BubbleMarkdownHost(text: note.caption, fontSize: m.fs, width: innerW,
                                              documentId: "\(note.id.uuidString)-caption", wiki: wiki) { [weak self] hgt in
                    guard let self, abs((self.captionH ?? 0) - hgt) > 0.5 else { return }
                    self.captionH = hgt
                    self.relayout()
                }
                if let captionHost { captionHost.rootView = root } else {
                    let hv = NSHostingView(rootView: root)
                    captionHost = hv
                    body.addSubview(hv)
                }
            }
            captionHost?.frame = NSRect(x: m.pad, y: thumbRect.maxY + m.fs * ImageBubble.captionGapRatio,
                                        width: innerW, height: h)
            captionHost?.layer?.masksToBounds = true
        }
        window?.invalidateCursorRects(for: self)
    }

    override func clicked(at p: CGPoint, event: NSEvent) {
        let scrolled = scroll.contentView.bounds.minY
        if thumbRect.offsetBy(dx: 0, dy: -scrolled).contains(p) { onView?() }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard onView != nil else { return nil }
        let menu = NSMenu()
        let view = ClosureMenuItem(L("View Full Size")) { [weak self] in self?.onView?() }
        view.isEnabled = info != nil
        menu.addItem(view)
        if let onEdit { menu.addItem(ClosureMenuItem(L("Edit…"), action: onEdit)) }
        if interactive, card != nil {
            menu.addItem(.separator())
            menu.addItem(ClosureMenuItem(L("Reset Card Size and Position")) { [weak self] in self?.onReset?() })
        }
        if let onDelete {
            menu.addItem(.separator())
            menu.addItem(ClosureMenuItem(L("Delete Image Note"), action: onDelete))
        }
        return menu
    }
}

// MARK: - 带闭包的菜单项（阅读区右键菜单、卡片菜单共用）

final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, action handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }
    required init(coder: NSCoder) { fatalError("init(coder:) 不支持") }

    @objc private func fire() { handler() }
}
