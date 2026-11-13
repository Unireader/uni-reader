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

    init(fontSize: CGFloat) {
        self.fontSize = fontSize
        style = MarkdownDisplayStyle(configuration: AgentMarkdown.configuration, font: .systemFont(ofSize: fontSize))
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

    override func menu(for event: NSEvent) -> NSMenu? {
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
    private var measured: (width: CGFloat, height: CGFloat)?
    /// 引用：左边一道竖条，正文右移。
    private var leftInset: CGFloat { isQuote ? 12 : 0 }

    init(key: String, text: NSAttributedString, quote: Bool, context: AgentBlockContext) {
        self.key = key
        isQuote = quote
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
        textView.extraMenuItems = { [weak context] in context.map { [$0.copyAllItem()] } ?? [] }
        storage.setAttributedString(text)
        addSubview(textView)
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
        storage.setAttributedString(text)
        measured = nil
    }

    func height(forWidth w: CGFloat) -> CGFloat {
        let tw = max(1, w - leftInset)
        if let m = measured, abs(m.width - tw) < 0.25 { return m.height }
        container.size = NSSize(width: tw, height: CGFloat.greatestFiniteMagnitude)
        layoutManager.ensureLayout(for: container)
        let h = ceil(layoutManager.usedRect(for: container).height)
        measured = (tw, h)
        return h
    }

    override func layout() {
        super.layout()
        _ = height(forWidth: bounds.width)   // 容器宽跟上视图宽（一般 `AgentMarkdownView` 已经量过，这里命中缓存）
        textView.frame = NSRect(x: leftInset, y: 0, width: max(1, bounds.width - leftInset), height: bounds.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard isQuote else { return }
        NSColor.labelColor.withAlphaComponent(0.22).setFill()
        NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: 3, height: bounds.height), xRadius: 1.5, yRadius: 1.5).fill()
    }

    // 链接：普通网址 / unireader:// 交给系统打开；`[[…]]` 没有工作区上下文可解析，不跳
    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        if MarkdownDisplayRenderer.wikiLinkTarget(link) != nil { return true }
        if let url = (link as? URL) ?? (link as? String).flatMap(URL.init(string:)), url.scheme != nil {
            NSWorkspace.shared.open(url)
            return true
        }
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
@MainActor
final class AgentPictureView: NSView {
    var image: NSImage? { didSet { needsDisplay = true } }
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        image?.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
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

    init(key: String, centered: Bool, scrolls: Bool, clipRadius: CGFloat = 0, menuItems: @escaping () -> [NSMenuItem],
         render: @escaping (CGFloat) -> NSImage?) {
        self.key = key
        self.clipRadius = clipRadius
        self.render = render
        self.centered = centered
        self.scrolls = scrolls
        self.menuItems = menuItems
        super.init(frame: .zero)
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
