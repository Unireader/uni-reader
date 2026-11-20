import AppKit
import MarkdownEngine

// Agent 面板 / 习题正文的「按块显示」（2026-11-12，用户看了 Xcode 的 AI 输出后定的方案）。
//
// 引擎的只读接口（fork 加的 `MarkdownDisplayRenderer`）用笔记同一套解析把 Markdown 切成几段：
// 连着的段落 / 标题 / 列表合成一段文字，引用、代码、块公式、表格、分隔线各自一段。这里每段一个视图，
// 竖着按 frame 摆（不用约束）：
//  · 文字段用 TextKit 1 的 `NSTextView`（只读、可选中、链接可点）——改宽度只是这一段重新折行，
//    不再是整篇 TextKit 2 文档带隐藏源码重新上样式（同一篇回复离屏实测快 10 倍以上，见 `ACP-AGENT-PLAN.md`）；
//  · 代码块：着色（`AgentCodeHighlighter`）、不折行、横向滚动；```grapher 画成图；
//  · 块公式：`NoteLatexRenderer` 出图，居中，宽过版面就等比缩小；
//  · 表格：引擎画的表格图（与笔记同一样式，圆角），宽过版面就在圆角里横向滚动。
// 代价（用户接受）：选中文字只能在一段文字里，跨不过代码块 / 表格；右键「复制全文」拿整条的 Markdown。

/// 一段正文。`key` 是这段的种类 + 源码：流式更新时 key 没变的段原样留着，不重建。
@MainActor
protocol AgentBlockView: NSView {
    var key: String { get }
    /// 按这个宽度排好后的高度（同一宽度第二次调用应当很便宜）。
    func height(forWidth w: CGFloat) -> CGFloat
}

/// 段与段之间、点击菜单等共用的东西，由 `AgentMarkdownView` 提供。
@MainActor
final class AgentBlockContext {
    let fontSize: CGFloat
    let style: MarkdownDisplayStyle
    /// 整条的 Markdown（右键「复制全文」）。
    var fullText: () -> String = { "" }
    /// 点了正文里的链接：返回 true = 外面接手了（日程说明里的 `[[…]]`，`SCHEDULE-PLAN.md §4.3`）；
    /// 没设或返回 false 走默认（网址 / unireader:// 交给系统，`[[…]]` 不跳）。
    var openLink: ((Any) -> Bool)?
    /// 右键一段文字时多给的菜单项（习题的高亮，`EXERCISE-PLAN.md §32`）：哪一段、选中的范围、点在第几个字上（都是这一段里的位置）。
    var markMenu: ((AgentTextBlockView, NSRange, Int?) -> [NSMenuItem])?

    init(fontSize: CGFloat) {
        self.fontSize = fontSize
        style = MarkdownDisplayStyle(configuration: AgentMarkdown.configuration, font: .systemFont(ofSize: fontSize))
    }

    /// 点了正文里的链接（文字段与表格图里的链接共用）：外面接手的先给外面（`openLink`）；
    /// 普通网址 / unireader:// 交给系统打开；`[[…]]` 没有工作区上下文可解析，不跳。
    static func follow(_ link: Any, in context: AgentBlockContext?) {
        if let open = context?.openLink, open(link) { return }
        if MarkdownDisplayRenderer.wikiLinkTarget(link) != nil { return }
        if let url = (link as? URL) ?? (link as? String).flatMap(URL.init(string:)), url.scheme != nil {
            NSWorkspace.shared.open(url)
        }
    }

    /// 每段右键菜单底下都有的那一项。
    func copyAllItem() -> NSMenuItem {
        ClosureMenuItem(L("Copy All (Markdown)")) { [weak self] in
            guard let self else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(self.fullText(), forType: .string)
        }
    }
}

// MARK: - 文字段

/// 只读可选中的文字（TextKit 1）。复制时公式图片换回 `$…$` 源码；`[[…]]` 点了不跳（没有可解析的工作区上下文）。
@MainActor
final class AgentSelectableTextView: NSTextView {
    var extraMenuItems: () -> [NSMenuItem] = { [] }
    /// 上一次右键点在第几个字上（nil = 没点在字上）。
    private(set) var menuCharIndex: Int?

    override func menu(for event: NSEvent) -> NSMenu? {
        let p = convert(event.locationInWindow, from: nil)
        if let lm = layoutManager, let tc = textContainer, let ts = textStorage, ts.length > 0 {
            var frac: CGFloat = 0
            let local = NSPoint(x: p.x - textContainerOrigin.x, y: p.y - textContainerOrigin.y)
            let i = lm.characterIndex(for: local, in: tc, fractionOfDistanceBetweenInsertionPoints: &frac)
            let glyphs = lm.glyphRange(forCharacterRange: NSRange(location: i, length: 1), actualCharacterRange: nil)
            let rect = lm.boundingRect(forGlyphRange: glyphs, in: tc)
            menuCharIndex = rect.contains(local) ? i : nil
        } else {
            menuCharIndex = nil
        }
        let menu = super.menu(for: event) ?? NSMenu()
        let items = extraMenuItems()
        if !items.isEmpty {
            menu.addItem(.separator())
            items.forEach(menu.addItem)
        }
        return menu
    }

    override func copy(_ sender: Any?) {
        let ranges = selectedRanges.map(\.rangeValue).filter { $0.length > 0 }
        guard let storage = textStorage, !ranges.isEmpty else { return super.copy(sender) }
        var out = ""
        for r in ranges {
            let piece = storage.attributedSubstring(from: r)
            var s = ""
            piece.enumerateAttributes(in: NSRange(location: 0, length: piece.length)) { attrs, run, _ in
                if let src = attrs[MarkdownDisplayRenderer.sourceAttribute] as? String {
                    s += src
                } else {
                    s += (piece.string as NSString).substring(with: run)
                }
            }
            out += (out.isEmpty ? "" : "\n") + s
        }
        // 段内换行是 U+2028（排版用），拷出去换回普通换行
        out = out.replacingOccurrences(of: "\u{2028}", with: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(out, forType: .string)
    }
}

@MainActor
final class AgentTextBlockView: NSView, AgentBlockView, NSTextViewDelegate {
    private(set) var key: String
    private let isQuote: Bool
    private let storage = NSTextStorage()
    private let layoutManager = NSLayoutManager()
    private let container = NSTextContainer(size: NSSize(width: 100, height: CGFloat.greatestFiniteMagnitude))
    let textView: AgentSelectableTextView
    /// 排出来的原样（加背景色前的）。
    private(set) var base = NSAttributedString()
    /// 眼下加着的背景色（这一段里的位置）。
    private var backgrounds: [(NSRange, NSColor)] = []
    private var measured: (width: CGFloat, height: CGFloat)?
    private weak var context: AgentBlockContext?
    /// Obsidian callout（`> [!type] 标题`）：竖条用类型色，整块铺一层类型色淡底，四周留白。
    private let callout: MarkdownDisplayCallout?
    /// 引用：左边一道竖条，正文右移。
    private var leftInset: CGFloat { isQuote ? 12 : 0 }
    /// callout 框里正文上下、右边的留白（普通引用为 0）。
    private var boxPad: CGFloat { callout != nil ? 6 : 0 }

    init(key: String, text: NSAttributedString, quote: Bool, callout: MarkdownDisplayCallout? = nil,
         context: AgentBlockContext) {
        self.key = key
        isQuote = quote
        self.callout = callout
        storage.addLayoutManager(layoutManager)
        container.lineFragmentPadding = 0
        container.widthTracksTextView = false
        container.heightTracksTextView = false
        layoutManager.addTextContainer(container)
        textView = AgentSelectableTextView(frame: .zero, textContainer: container)
        super.init(frame: .zero)
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.isRichText = true
        textView.textContainerInset = .zero
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = false
        textView.linkTextAttributes = [.foregroundColor: NSColor.linkColor, .cursor: NSCursor.pointingHand]
        textView.delegate = self
        self.context = context
        base = text
        storage.setAttributedString(text)
        addSubview(textView)
        textView.extraMenuItems = { [weak self, weak context] in
            guard let self, let context else { return [] }
            let extra = context.markMenu?(self, self.textView.selectedRange(), self.textView.menuCharIndex) ?? []
            return extra + (extra.isEmpty ? [] : [.separator()]) + [context.copyAllItem()]
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) 不支持") }

    override var isFlipped: Bool { true }

    /// 第一段的段前距（标题有）。TextKit 不给文本开头那一段加段前距，由外面加进块间距（`AgentMarkdownView.relayout`）。
    var leadingSpacing: CGFloat {
        guard storage.length > 0 else { return 0 }
        return (storage.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)?.paragraphSpacingBefore ?? 0
    }

    /// 流式：最后一段文字长了，换内容不换视图（选区会丢，接受——还在出字的段一般不会去选）。
    func update(text: NSAttributedString, key: String) {
        self.key = key
        base = text
        backgrounds = []
        storage.setAttributedString(text)
        measured = nil
    }

    /// 换几处背景色（高亮）：不改字、不改排版，只重上一遍样式。和眼下一样就不动（免得把选区冲掉）。
    func setBackgrounds(_ list: [(NSRange, NSColor)]) {
        let valid = list.filter { $0.0.length > 0 && NSMaxRange($0.0) <= base.length }
        guard valid.count != backgrounds.count
                || zip(valid, backgrounds).contains(where: { $0.0 != $1.0 || $0.1 != $1.1 }) else { return }
        backgrounds = valid
        let m = NSMutableAttributedString(attributedString: base)
        for (r, c) in valid { m.addAttribute(.backgroundColor, value: c, range: r) }
        storage.setAttributedString(m)
    }

    func height(forWidth w: CGFloat) -> CGFloat {
        let tw = max(1, w - leftInset - boxPad)
        if let m = measured, abs(m.width - tw) < 0.25 { return m.height + boxPad * 2 }
        container.size = NSSize(width: tw, height: CGFloat.greatestFiniteMagnitude)
        layoutManager.ensureLayout(for: container)
        let h = ceil(layoutManager.usedRect(for: container).height)
        measured = (tw, h)
        return h + boxPad * 2
    }

    override func layout() {
        super.layout()
        _ = height(forWidth: bounds.width)   // 容器宽跟上视图宽（一般 `AgentMarkdownView` 已经量过，这里命中缓存）
        textView.frame = NSRect(x: leftInset, y: boxPad, width: max(1, bounds.width - leftInset - boxPad),
                                height: max(1, bounds.height - boxPad * 2))
    }

    override func draw(_ dirtyRect: NSRect) {
        guard isQuote else { return }
        if let callout {
            callout.color.withAlphaComponent(callout.tintAlpha).setFill()
            bounds.fill()
            callout.color.setFill()
            NSRect(x: 0, y: 0, width: 3, height: bounds.height).fill()
            return
        }
        NSColor.labelColor.withAlphaComponent(0.22).setFill()
        NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: 3, height: bounds.height), xRadius: 1.5, yRadius: 1.5).fill()
    }

    // 链接：见 `AgentBlockContext.follow`
    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        AgentBlockContext.follow(link, in: context)
        return true
    }
}

// MARK: - 横向滚动（代码块 / 宽表格）

/// 只横向滚。🔴 竖向滚动一律交给外面的对话记录：一次触控板手势按第一下有位移的方向定给谁，
/// 从头到尾不换（同引擎 `0.15.0-xvan.2` 宽表格的做法）；鼠标滚轮每一格单独判断。
@MainActor
final class AgentHScrollView: NSScrollView {
    private var routesToParent: Bool?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        hasHorizontalScroller = true
        hasVerticalScroller = false
        autohidesScrollers = true
        scrollerStyle = .overlay
        drawsBackground = false
        borderType = .noBorder
        verticalScrollElasticity = .none
        horizontalScrollElasticity = .allowed
        usesPredominantAxisScrolling = true
        automaticallyAdjustsContentInsets = false
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) 不支持") }

    override func scrollWheel(with e: NSEvent) {
        let gesture = !e.phase.isEmpty || !e.momentumPhase.isEmpty
        if gesture {
            if e.phase.contains(.began) || e.phase.contains(.mayBegin) { routesToParent = nil }
            if routesToParent == nil, e.scrollingDeltaX != 0 || e.scrollingDeltaY != 0 {
                routesToParent = abs(e.scrollingDeltaY) >= abs(e.scrollingDeltaX)
            }
        }
        let toParent = gesture ? (routesToParent ?? true) : abs(e.scrollingDeltaY) >= abs(e.scrollingDeltaX)
        let documentFits = (documentView?.frame.width ?? 0) <= contentView.bounds.width + 0.5
        if toParent || documentFits {
            nextResponder?.scrollWheel(with: e)
        } else {
            super.scrollWheel(with: e)
        }
        // 惯性走完 / 手势取消：下一次重新判断（手指抬起后的惯性事件仍按这次的方向走）
        if e.momentumPhase.contains(.ended) || e.momentumPhase.contains(.cancelled) || e.phase.contains(.cancelled) {
            routesToParent = nil
        }
    }
}

/// 画一张图（表格 / 公式 / grapher），按自己的 bounds 画满。
/// 表格图里的链接（设了 `openLink` 时，2026-11-20）：链接上是手形指针，点了交给 `openLink`——
/// 位置由引擎记在表格图上（`MarkdownDisplayRenderer.tableLinks` / `tableLink(in:at:)`），同笔记里的表格。
@MainActor
final class AgentPictureView: NSView {
    var image: NSImage? {
        didSet {
            needsDisplay = true
            if openLink != nil { window?.invalidateCursorRects(for: self) }
        }
    }
    /// 设了 = 这张是表格图，里面的链接能点（网址原样，`[[…]]` 是 `MarkdownDisplayRenderer.wikiLinkScheme` 网址）。
    var openLink: ((URL) -> Void)?
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        image?.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }

    /// 视图里图片画在多大比例上（表格图按原尺寸画，一般是 1）。
    private var scale: CGSize? {
        guard let image, image.size.width > 0, image.size.height > 0 else { return nil }
        return CGSize(width: bounds.width / image.size.width, height: bounds.height / image.size.height)
    }

    override func resetCursorRects() {
        guard openLink != nil, let image, let k = scale else { return }
        for link in MarkdownDisplayRenderer.tableLinks(in: image) {
            let r = link.rect
            addCursorRect(NSRect(x: r.minX * k.width, y: r.minY * k.height,
                                 width: r.width * k.width, height: r.height * k.height), cursor: .pointingHand)
        }
    }

    /// 点在链接的字上：松开时还在同一个链接上才打开（拖走不算，同按钮）。别处照旧往上传。
    override func mouseDown(with event: NSEvent) {
        guard openLink != nil, event.clickCount == 1, let window,
              let url = link(atWindowPoint: event.locationInWindow) else {
            super.mouseDown(with: event)
            return
        }
        var release: NSPoint?
        while let e = window.nextEvent(matching: [.leftMouseUp, .leftMouseDragged], until: .distantFuture,
                                       inMode: .eventTracking, dequeue: true) {
            if e.type == .leftMouseUp { release = e.locationInWindow; break }
        }
        finishPress(on: url, releasedAt: release ?? window.mouseLocationOutsideOfEventStream)
    }

    /// 一次从链接上按下的点击松开了：还在同一个链接上就打开。返回打开了没有。
    @discardableResult
    func finishPress(on url: URL, releasedAt windowPoint: NSPoint) -> Bool {
        guard let open = openLink, link(atWindowPoint: windowPoint) == url else { return false }
        open(url)
        return true
    }

    /// 窗口坐标上的那一点是不是落在表格图的某个链接上（离屏测试也用）。
    func link(atWindowPoint windowPoint: NSPoint) -> URL? {
        guard let image, let k = scale, k.width > 0, k.height > 0 else { return nil }
        let p = convert(windowPoint, from: nil)
        return MarkdownDisplayRenderer.tableLink(in: image, at: CGPoint(x: p.x / k.width, y: p.y / k.height))
    }
}

// MARK: - 代码块

@MainActor
final class AgentCodeBlockView: NSView, AgentBlockView {
    let key: String
    private let code: String
    private let scroll = AgentHScrollView()
    private let textView: NSTextView
    private let storage = NSTextStorage()
    private let layoutManager = NSLayoutManager()
    private let container = NSTextContainer(size: NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude))
    private weak var context: AgentBlockContext?
    private static let pad: CGFloat = 8
    private var contentSize: NSSize = .zero

    init(key: String, language: String?, code: String, context: AgentBlockContext) {
        self.key = key
        self.code = code
        self.context = context
        storage.addLayoutManager(layoutManager)
        container.lineFragmentPadding = 0
        container.widthTracksTextView = false
        layoutManager.addTextContainer(container)
        textView = NSTextView(frame: .zero, textContainer: container)
        super.init(frame: .zero)
        let font = AgentCodeHighlighter.shared.codeFont(size: (context.fontSize * 0.92).rounded())
        let colored = AgentCodeHighlighter.shared.highlight(code: code, language: language)
        let text = NSMutableAttributedString(attributedString: colored ?? NSAttributedString(string: code))
        let all = NSRange(location: 0, length: text.length)
        text.addAttribute(.font, value: font, range: all)
        if colored == nil { text.addAttribute(.foregroundColor, value: NSColor.labelColor, range: all) }
        let p = NSMutableParagraphStyle()
        p.lineSpacing = 1
        text.addAttribute(.paragraphStyle, value: p, range: all)
        storage.setAttributedString(text)
        layoutManager.ensureLayout(for: container)
        let used = layoutManager.usedRect(for: container)
        contentSize = NSSize(width: ceil(used.width), height: ceil(used.height))

        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: Self.pad, height: Self.pad)
        textView.isHorizontallyResizable = true
        textView.isVerticallyResizable = false
        textView.frame = NSRect(x: 0, y: 0, width: contentSize.width + 2 * Self.pad, height: contentSize.height + 2 * Self.pad)
        scroll.documentView = textView
        addSubview(scroll)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) 不支持") }

    override var isFlipped: Bool { true }

    func height(forWidth w: CGFloat) -> CGFloat { contentSize.height + 2 * Self.pad }

    override func layout() {
        super.layout()
        scroll.frame = bounds
        var f = textView.frame
        f.size.width = max(bounds.width, contentSize.width + 2 * Self.pad)
        textView.frame = f
    }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.backgroundColor = AgentCodeHighlighter.shared.backgroundColor().cgColor
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        let code = self.code
        menu.addItem(ClosureMenuItem(L("Copy Code")) { AgentMarkdown.copyCode(code) })
        if let context { menu.addItem(.separator()); menu.addItem(context.copyAllItem()) }
        return menu
    }
}

// MARK: - 图（块公式 / grapher / 表格）

/// 一张按宽度出图的块：`render(宽度)` 给图；比宽度窄的照原样画（公式居中、表格靠左），
/// 比宽度宽的：`scrolls` 为真就横向滚（表格），否则等比缩小到正好放下（公式 / grapher）。
@MainActor
final class AgentImageBlockView: NSView, AgentBlockView {
    let key: String
    private let render: (CGFloat) -> NSImage?
    private let centered: Bool
    private let scrolls: Bool
    /// 横向滚动时露出来那一截的圆角（表格的圆角样式）。
    private let clipRadius: CGFloat
    private let menuItems: () -> [NSMenuItem]
    private let picture = AgentPictureView()
    private var scroll: AgentHScrollView?
    private var current: (width: CGFloat, image: NSImage?)?

    /// `openLink`：表格图里的链接点了交给它（只有表格给）。
    init(key: String, centered: Bool, scrolls: Bool, clipRadius: CGFloat = 0, menuItems: @escaping () -> [NSMenuItem],
         openLink: ((URL) -> Void)? = nil, render: @escaping (CGFloat) -> NSImage?) {
        self.key = key
        self.clipRadius = clipRadius
        self.render = render
        self.centered = centered
        self.scrolls = scrolls
        self.menuItems = menuItems
        super.init(frame: .zero)
        picture.openLink = openLink
        addSubview(picture)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) 不支持") }

    override var isFlipped: Bool { true }

    private func image(forWidth w: CGFloat) -> NSImage? {
        if let c = current, abs(c.width - w) < 0.25 { return c.image }
        let img = render(w)
        current = (w, img)
        return img
    }

    /// 换了深浅色：图要重出。
    func invalidate() { current = nil; needsLayout = true }

    func height(forWidth w: CGFloat) -> CGFloat {
        guard let img = image(forWidth: w), img.size.width > 0 else { return 0 }
        if img.size.width <= w + 0.5 || scrolls { return ceil(img.size.height) }
        return ceil(img.size.height * w / img.size.width)
    }

    override func layout() {
        super.layout()
        let w = bounds.width
        guard let img = image(forWidth: w) else { picture.image = nil; return }
        picture.image = img
        let size = img.size
        if size.width <= w + 0.5 {
            dropScroll()
            let x = centered ? ((w - size.width) / 2).rounded() : 0
            picture.frame = NSRect(x: x, y: 0, width: size.width, height: size.height)
        } else if scrolls {
            let s = scroll ?? makeScroll()
            s.frame = bounds
            s.documentView?.frame = NSRect(origin: .zero, size: size)
            picture.frame = NSRect(origin: .zero, size: size)
            // 表格的圆角（`TableAppearance.rounded`）：露出来的那一截也是圆角
            let radius = clipRadius
            s.contentView.wantsLayer = true
            s.contentView.layer?.cornerRadius = radius
            s.contentView.layer?.cornerCurve = .continuous
            s.contentView.layer?.masksToBounds = radius > 0
        } else {
            dropScroll()
            let k = w / size.width
            picture.frame = NSRect(x: 0, y: 0, width: w, height: (size.height * k).rounded())
        }
    }

    private func makeScroll() -> AgentHScrollView {
        let s = AgentHScrollView()
        picture.removeFromSuperview()
        let doc = AgentFlippedDocView()
        doc.addSubview(picture)
        s.documentView = doc
        addSubview(s)
        scroll = s
        return s
    }

    private func dropScroll() {
        guard let s = scroll else { return }
        picture.removeFromSuperview()
        s.removeFromSuperview()
        scroll = nil
        addSubview(picture)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let items = menuItems()
        guard !items.isEmpty else { return nil }
        let menu = NSMenu()
        items.forEach(menu.addItem)
        return menu
    }
}

/// 横向滚动里装图的那一层（大小由 `AgentImageBlockView.layout` 设成图的大小）。
@MainActor
private final class AgentFlippedDocView: NSView {
    override var isFlipped: Bool { true }
}

// MARK: - 分隔线

@MainActor
final class AgentRuleBlockView: NSView, AgentBlockView {
    let key: String
    private let box = NSBox()
    init(key: String) {
        self.key = key
        super.init(frame: .zero)
        box.boxType = .separator
        addSubview(box)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) 不支持") }
    func height(forWidth w: CGFloat) -> CGFloat { 9 }
    override func layout() {
        super.layout()
        box.frame = NSRect(x: 0, y: 4, width: bounds.width, height: 1)
    }
}
