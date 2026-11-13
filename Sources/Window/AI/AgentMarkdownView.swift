import AppKit
import Highlighter
import MarkdownEngine

/// Agent 面板里正文的 Markdown 渲染（`ACP-AGENT-PLAN.md` A3）。
///
/// 从前只做行内语法（`AttributedString(markdown:)` 的 `inlineOnlyPreservingWhitespace`）；后来（2026-09）改成
/// 引擎编辑器的只读模式托管进 `NSHostingView`；2026-11-12 起按段显示（`AgentMarkdownView`，纯 AppKit）：
/// 解析仍是引擎的（与笔记同一套），排版各段自己来。
@MainActor
enum AgentMarkdown {
    /// Agent 回复正文的字号（与改造前的纯文本一致）。
    static var bodyFontSize: CGFloat { NSFont.systemFontSize }
    /// 思考过程折叠起来的正文：比回复小一号（同改造前的 `.callout`）。
    static var thoughtFontSize: CGFloat { NSFont.preferredFont(forTextStyle: .callout).pointSize }

    /// 面板里的只读配置（按段显示只取其中的主题、标题 / 列表尺度、公式渲染器、扩展、代码着色、表格样式）。
    /// 标题 / 列表缩进的尺度与公式渲染器跟笔记共用一套（`applyNoteTypography`）；
    /// 主题用引擎默认的——`bodyText` 就是 `labelColor`，跟着系统外观走（气泡那套是钉死浅色的，不能拿来用）。
    /// 高亮两种（2026-10-05 用户要的「输出添加高亮支持」，两种都做）：`==文字==` 荧光笔底色（引擎自带扩展，
    /// 默认不开）+ 代码块按语言着色（`AgentCodeHighlighter`）。只开在 Agent 面板，笔记那边没动。
    static let configuration: MarkdownEditorConfiguration = {
        var c = MarkdownEditorConfiguration.default
        c.heightBehavior = .fitsContent
        c.overscroll = OverscrollPolicy(percent: 0, maxPoints: 0, minPoints: 0)
        c.scrollers = .hidden
        c.textInsets = TextInsets(horizontal: 0, vertical: 0)
        c.spellChecking = SpellCheckingPolicy(continuousSpellChecking: false, grammarChecking: false,
                                              automaticSpellingCorrection: false)
        MarkdownNoteEditor.applyNoteTypography(&c)
        c.extensions = [HighlightExtension()]
        c.services.syntaxHighlighter = AgentCodeHighlighter.shared
        return c
    }()

    /// 用户消息气泡按内容收窄时，正文要多宽（不含气泡内边距）；nil = 撑满气泡上限。
    ///
    /// 引擎是「原文就地加样式」的渲染：换行照原文、标记符号藏起来，所以**按原文逐行量宽**大致就是排出来的宽度——
    /// 藏掉的 `**` 之类让实际更窄，加粗略宽一点由余量兜。量不准的块级结构（标题字号更大、列表 / 引用有缩进、
    /// 代码块 / 表格 / 块公式 / 图片要整行宽）直接撑满。含行内代码或行内公式的行按等宽字体量（宁宽勿窄：
    /// 窄了会多折一行，宽了只是气泡右边多点空）。
    static func fittingWidth(of text: String, fontSize: CGFloat) -> CGFloat? {
        let body = NSFont.systemFont(ofSize: fontSize)
        let mono = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        var widest: CGFloat = 0
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let s = String(line)
            if s.range(of: blockLine, options: .regularExpression) != nil || s.contains("![") { return nil }
            let font = s.contains("`") || s.contains("$") ? mono : body
            widest = max(widest, (s as NSString).size(withAttributes: [.font: font]).width)
        }
        return ceil(widest) + 4
    }

    /// 块级结构的行首：缩进代码、标题、引用、列表、代码围栏、表格、块公式。
    private static let blockLine = #"^(\t| {4}| {0,3}(#{1,6}(\s|$)|>|[-*+]\s|\d{1,9}[.)]\s|```|~~~|\||\$\$))"#

    /// 右键「复制表格」：纯文本放表格的 Markdown 原文（贴进笔记 / Obsidian），HTML 放渲染好的表格
    /// （贴进 Numbers / Excel / Pages / Word 是一张真表格）。各 App 自己挑认得的那种。
    static func copyTable(_ markdown: String, to pb: NSPasteboard = .general) {
        let html = MarkdownHTMLRenderer.html(from: markdown, extensions: [HighlightExtension()])
        pb.clearContents()
        pb.declareTypes([.string, .html], owner: nil)
        pb.setString(markdown, forType: .string)
        // 不声明编码的 HTML 片段有的 App 按 Latin-1 读，中文成乱码
        pb.setString("<meta charset=\"utf-8\">" + html, forType: .html)
    }

    /// 右键「复制代码」：只要两行围栏之间的代码，不带 ``` 与语言名。
    static func copyCode(_ code: String, to pb: NSPasteboard = .general) {
        pb.clearContents()
        pb.setString(code, forType: .string)
    }
}

/// Agent 面板代码块的着色（highlight.js，经 HighlighterSwift 在 JavaScriptCore 里跑）。
///
/// 🔴 **只着围栏上写了、而且 highlight.js 认得的语言，绝不猜**：没写语言 / 不认识的语言让 highlight.js
/// 把全部语言挨个试一遍（`highlightAuto`），实测 60 行 0.35~0.6 秒、卡主线程——引擎自带的桥接层
/// （`MarkdownEngineCodeBlocks`）正是这么退的，所以不用它（`project.yml` 注释）。何况没标语言的多半是
/// 命令输出 / 路径 / 纯文字，猜出来的颜色反而乱。别名（sh / py / ts / yml / html …）highlight.js 自己认。
///
/// 开销：写了语言的约 0.35ms/行（一半 JS、一半转属性串），**每块只着一次**——引擎只把**闭合了的**围栏当代码块
/// （`BlockParser.fenceCloseIndex`），流式回复里还在长的那块是普通段落、不会来问；闭合那一刻整块着一次，
/// 之后每次重排都走缓存。
///
/// 颜色：GitHub 浅 / 深两套主题（选择器分组完全一致，对比度好）同一段代码各着一遍，合成**跟着外观变的动态颜色**，
/// 切深浅色时系统画字自己挑，不用让引擎重排——所以 `appearanceDidChangeNotification` 是 nil。
/// 底色（`codeBackground`）：🔴 **必须不透明**——引擎在代码块整行画一遍底色、字形底下又按 `.backgroundColor`
/// 画一遍，半透明会叠出一道道深色条；它也认这个颜色来判断哪几行是代码块（比 RGB）。
/// 浅色 0.96 灰、深色 0.08 近黑：在面板底上、在用户气泡（面板再叠一层灰）里都分得出来（离屏样张看过）。
/// 试过的两种都不行：`textBackgroundColor` 深色下和面板底几乎同色；纯白在 Tahoe 浅色的白面板上看不见。
final class AgentCodeHighlighter: SyntaxHighlighter, @unchecked Sendable {
    static let shared = AgentCodeHighlighter()

    /// 两份 highlight.js，各钉一套主题（初始化一份约 30ms，第一次着色时才建）。
    /// 引擎在主线程排版，只在主线程用。
    private lazy var light: Highlighter? = Self.make(theme: "github")
    private lazy var dark: Highlighter? = Self.make(theme: "github-dark")
    /// (语言, 代码) → 着好色的结果。
    private let cache = NSCache<NSString, NSAttributedString>()
    /// highlight.js 不认识的语言：下次直接跳过，连 JS 都不进。
    private var unknownLanguages: Set<String> = []
    /// (浅色, 深色) → 合成的动态颜色：一个主题就十几种颜色，别每个片段新建一个。
    private var dynamicColors: [String: NSColor] = [:]

    private init() {
        cache.countLimit = 256
        cache.totalCostLimit = 2_000_000
    }

    private static func make(theme: String) -> Highlighter? {
        guard let h = Highlighter(), h.setTheme(theme) else { return nil }
        h.ignoreIllegals = true   // 示例代码常带 `...` 之类的占位，别因为一处不合语法整块不着色
        return h
    }

    private static let codeBackground = NSColor(name: nil) {
        NSColor(white: $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? 0.08 : 0.96, alpha: 1)
    }

    func codeFont(size: CGFloat) -> NSFont { .monospacedSystemFont(ofSize: size, weight: .regular) }
    func backgroundColor() -> NSColor { Self.codeBackground }
    var appearanceDidChangeNotification: Notification.Name? { nil }

    func highlight(code: String, language: String?) -> NSAttributedString? {
        guard let lang = language?.trimmingCharacters(in: .whitespaces).lowercased(), !lang.isEmpty,
              !unknownLanguages.contains(lang) else { return nil }
        let key = "\(lang)\n\(code)" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        guard let light, let dark else { return nil }
        guard let l = light.highlight(code, as: lang), let d = dark.highlight(code, as: lang) else {
            unknownLanguages.insert(lang)
            return nil
        }
        // 引擎按下标把颜色贴回代码块，长度对不上宁可不着色，别把颜色贴错位
        let n = (code as NSString).length
        guard l.length == n, d.length == n else { return nil }
        let out = NSMutableAttributedString(string: code)
        l.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: n)) { lv, lr, _ in
            // 两套主题分组一致，片段边界本该重合；不重合也照深色那边再切一刀
            d.enumerateAttribute(.foregroundColor, in: lr) { dv, dr, _ in
                guard let lc = lv as? NSColor, let dc = dv as? NSColor else { return }
                out.addAttribute(.foregroundColor, value: dynamicColor(light: lc, dark: dc), range: dr)
            }
        }
        cache.setObject(out, forKey: key, cost: n)
        return out
    }

    private func dynamicColor(light: NSColor, dark: NSColor) -> NSColor {
        let key = "\(light)|\(dark)"
        if let c = dynamicColors[key] { return c }
        let c = NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light }
        dynamicColors[key] = c
        return c
    }
}

/// 一段 Markdown 正文（Agent 的回复 / 思考过程 / 用户消息，习题的题干 / 选项 / 解析 / 笔记）。
/// 宽度由外面给，高度是各段排完加起来的。
///
/// 🔴 **按段显示，不再是一整个引擎编辑器**（2026-11-12，用户看了 Xcode 的 AI 输出定的；分段与各段视图见
/// `AgentMarkdownBlocksView.swift`）：引擎的只读接口 `MarkdownDisplayRenderer` 用笔记同一套解析把正文切成段，
/// 文字段用 TextKit 1 排，改宽度时各段只重新折行、按 frame 竖着摆。原来那种「引擎编辑器托管进 `NSHostingView`」
/// 每改一次宽度都要整篇 TextKit 2 重排（带隐藏源码、表格整张重画），拖侧栏时跟不上。
///
/// 仍保留的节流（排版便宜了，但对话记录里可能有几百条）：
///  · **流式就地更新**：同一条回复只调 `update(text:)`；源码没变的段原样留着，只重建变了的（通常是最后一段）。
///  · **文本按 80ms 并流**（`textInterval`）。
///  · **宽度：露在视口里的当场重排；视口外的停手再排；看不见的不排**（不在窗口 / 隐藏 / 折叠着的思考过程，露出来再补）。
@MainActor
final class AgentMarkdownView: NSView {
    /// 已经显示出来的文本。
    private(set) var text: String
    private let fontSize: CGFloat
    private let documentId: String
    private let context: AgentBlockContext
    private var blocks: [AgentBlockView] = []
    /// 各段已按这个宽度摆好（< 0：还没摆 / 要重摆）。
    private var laidOutWidth: CGFloat = -1
    private var built = false
    /// 各段加起来的高度。
    private var height: CGFloat = 0
    /// 高度变了：对话记录据此决定要不要继续贴着底。
    var onHeightChange: (() -> Void)?
    /// 点了正文里的链接，返回 true = 接手了（见 `AgentBlockContext.openLink`）。
    var openLink: ((Any) -> Bool)? {
        get { context.openLink }
        set { context.openLink = newValue }
    }

    /// 还没显示的新文本（攒着，到点 / 露出来再一起排）。
    private var pendingText: String?
    private var lastApply = Date.distantPast
    private var timer: Timer?
    private var widthTimer: Timer?
    /// 文本并流的间隔（最多这么频繁地重排一次）。
    private static let textInterval: TimeInterval = 0.08
    /// 视口外的正文：宽度防抖，停手才排。
    private static let widthInterval: TimeInterval = 0.15

    /// 现在排版有没有意义。
    private var isVisible: Bool { window != nil && !isHiddenOrHasHiddenAncestor }
    /// 露在对话记录的视口里（滚出去的条目 `visibleRect` 是空的）。
    private var isOnScreen: Bool { isVisible && !visibleRect.isEmpty }

    init(text: String, fontSize: CGFloat, documentId: String) {
        self.text = text
        self.fontSize = fontSize
        self.documentId = documentId
        context = AgentBlockContext(fontSize: fontSize)
        super.init(frame: .zero)
        context.fullText = { [weak self] in self?.pendingText ?? self?.text ?? "" }
        clipsToBounds = true
        lastApply = Date()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) 不支持") }

    deinit {
        timer?.invalidate()
        widthTimer?.invalidate()
    }

    override var isFlipped: Bool { true }

    /// 第一帧还没排时先占一行，免得条目塌成 0 高。
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: built ? height : (fontSize * 1.5).rounded())
    }

    /// 流式来的新文本（同一条回复越来越长）。
    func update(text: String) {
        guard text != (pendingText ?? self.text) else { return }
        pendingText = text
        guard isVisible else { return }          // 看不见：攒着，露出来再排
        if Date().timeIntervalSince(lastApply) >= Self.textInterval {
            applyPending()
        } else {
            armText()
        }
    }

    override func layout() {
        super.layout()
        guard isVisible else { return }
        if !built || pendingText != nil, timer == nil { applyPending() }
        let w = bounds.width
        if abs(w - laidOutWidth) <= 0.25 { return }
        if isOnScreen || laidOutWidth < 0 {
            relayout(width: w)
        } else {
            armWidth()   // 视口外：停手再排（旧宽度的摆放先留着，反正看不见）
        }
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        needsLayout = true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        needsLayout = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        // 公式图片与表格图的颜色是出图时定的：整条重建
        guard built else { return }
        blocks.forEach { $0.removeFromSuperview() }
        blocks = []
        built = false
        pendingText = pendingText ?? text
        needsLayout = true
    }

    /// 尺寸已经定下来了（拖分隔条松手），立刻排，别再等防抖。
    func flushNow() {
        guard isVisible else { return }
        if pendingText != nil || !built { applyPending() }
        if abs(bounds.width - laidOutWidth) > 0.25 { relayout(width: bounds.width) }
    }

    private func armText() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: Self.textInterval, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.timer = nil
                guard self.isVisible else { return }
                self.applyPending()
                self.relayout(width: self.bounds.width)
            }
        }
        timer = t
        // .common：面板正在滚动时这只表也得照常走，否则流式回复会停在半截
        RunLoop.main.add(t, forMode: .common)
    }

    private func armWidth() {
        widthTimer?.invalidate()
        let t = Timer(timeInterval: Self.widthInterval, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.widthTimer = nil
                if self.isVisible { self.relayout(width: self.bounds.width) }
            }
        }
        widthTimer = t
        RunLoop.main.add(t, forMode: .common)
    }

    /// 把攒下的文本切段，源码没变的段原样留着。
    private func applyPending() {
        timer?.invalidate()
        timer = nil
        if let t = pendingText { text = t }
        pendingText = nil
        lastApply = Date()
        built = true
        NoteLatexRenderer.shared.registerBlocks(in: text)   // 块公式按块排版：须先于出图登记（见 `NoteLatexRenderer`）
        let ns = text as NSString
        let segments = MarkdownDisplayRenderer.segments(for: text, style: context.style)
        var next: [AgentBlockView] = []
        next.reserveCapacity(segments.count)
        for (i, seg) in segments.enumerated() {
            let key = Self.key(seg, ns)
            if i < blocks.count, blocks[i].key == key { next.append(blocks[i]); continue }
            if i < blocks.count, let old = blocks[i] as? AgentTextBlockView, case .text(let s, _) = seg,
               old.key.hasPrefix("t|") {
                old.update(text: s, key: key)   // 流式：最后一段文字长了，换内容不换视图
                next.append(old)
                continue
            }
            next.append(makeBlock(seg, key: key))
        }
        let keep = Set(next.map { ObjectIdentifier($0) })
        for b in blocks where !keep.contains(ObjectIdentifier(b)) { b.removeFromSuperview() }
        for b in next where b.superview !== self { addSubview(b) }
        blocks = next
        laidOutWidth = -1
        needsLayout = true
    }

    private static func key(_ seg: MarkdownDisplaySegment, _ ns: NSString) -> String {
        let r = seg.range
        let src = NSMaxRange(r) <= ns.length ? ns.substring(with: r) : ""
        switch seg {
        case .text: return "t|" + src
        case .quote: return "q|" + src
        case .code: return "c|" + src
        case .math: return "m|" + src
        case .table: return "b|" + src
        case .rule: return "r|"
        case .image: return "i|" + src
        }
    }

    private func makeBlock(_ seg: MarkdownDisplaySegment, key: String) -> AgentBlockView {
        let ctx = context
        switch seg {
        case .text(let s, _):
            return AgentTextBlockView(key: key, text: s, quote: false, context: ctx)
        case .quote(let s, _):
            return AgentTextBlockView(key: key, text: s, quote: true, context: ctx)
        case .code(let language, let code, _):
            if language?.lowercased() == GrapherFencedRenderer.language {
                return AgentImageBlockView(key: key, centered: true, scrolls: false,
                                           menuItems: { [weak ctx] in
                                               [ClosureMenuItem(L("Copy Code")) { AgentMarkdown.copyCode(code) }]
                                                   + (ctx.map { [NSMenuItem.separator(), $0.copyAllItem()] } ?? [])
                                           }) { [weak self] w in
                    Self.grapherImage(code, width: w, dark: self?.isDark ?? false)
                }
            }
            if language?.lowercased() == AnimFencedRenderer.language {
                // 分步演示块：面板里只读，显示第 0 步的静态图（播放在笔记编辑区里）
                return AgentImageBlockView(key: key, centered: true, scrolls: false,
                                           menuItems: { [weak ctx] in
                                               [ClosureMenuItem(L("Copy Code")) { AgentMarkdown.copyCode(code) }]
                                                   + (ctx.map { [NSMenuItem.separator(), $0.copyAllItem()] } ?? [])
                                           }) { [weak self] w in
                    Self.animImage(code, width: w, dark: self?.isDark ?? false)
                }
            }
            return AgentCodeBlockView(key: key, language: language, code: code, context: ctx)
        case .math(let latex, _):
            let size = fontSize
            return AgentImageBlockView(key: key, centered: true, scrolls: false,
                                       menuItems: { [weak ctx] in ctx.map { [$0.copyAllItem()] } ?? [] }) { _ in
                NoteLatexRenderer.shared.render(latex: latex, fontSize: size,
                                                theme: AgentMarkdown.configuration.theme)?.image
            }
        case .table(let source, _):
            return AgentImageBlockView(key: key, centered: false, scrolls: true,
                                       clipRadius: ctx.style.configuration.tableAppearance.cornerRadius,
                                       menuItems: { [weak ctx] in
                                           [ClosureMenuItem(L("Copy Table")) { AgentMarkdown.copyTable(source) }]
                                               + (ctx.map { [NSMenuItem.separator(), $0.copyAllItem()] } ?? [])
                                       }) { [weak self] w in
                guard let self else { return nil }
                return MarkdownDisplayRenderer.tableImage(source: source, style: ctx.style, availableWidth: w,
                                                          appearance: self.effectiveAppearance)
            }
        case .rule:
            return AgentRuleBlockView(key: key)
        case .image(let url, let alt, _):
            // 正文里的图片：面板里一直不显示图片本身（原来的引擎配置也不给图），显示成可点的链接
            let s = NSAttributedString(string: alt.isEmpty ? url : alt, attributes: [
                .font: NSFont.systemFont(ofSize: fontSize), .foregroundColor: NSColor.linkColor,
                .link: URL(string: url) as Any,
            ])
            return AgentTextBlockView(key: key, text: s, quote: false, context: ctx)
        }
    }

    private var isDark: Bool { effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }

    private static func grapherImage(_ code: String, width: CGFloat, dark: Bool) -> NSImage? {
        let w = min(max(width, GrapherFencedRenderer.minBlockWidth), GrapherFencedRenderer.maxBlockWidth).rounded(.down)
        guard let picture = GrapherImageCache.shared.picture(text: code, width: w, dark: dark) else { return nil }
        return NSImage(cgImage: picture.image, size: CGSize(width: w, height: picture.height))
    }

    private static func animImage(_ code: String, width: CGFloat, dark: Bool) -> NSImage? {
        let w = AnimBlockMetrics.clampedWidth(width)
        guard let picture = AnimImageCache.shared.picture(text: code, width: w, dark: dark, controls: false) else { return nil }
        return NSImage(cgImage: picture.image, size: CGSize(width: w, height: picture.height))
    }

    /// 各段按宽度 `w` 量高、竖着摆。
    private func relayout(width w: CGFloat) {
        widthTimer?.invalidate()
        widthTimer = nil
        laidOutWidth = w
        let gap = (fontSize * 0.7).rounded()
        var y: CGFloat = 0
        for (i, b) in blocks.enumerated() {
            // 以标题开头的文字段：标题的段前距加在块间距上（开头不在最顶上时）
            if i > 0, let t = b as? AgentTextBlockView { y += t.leadingSpacing }
            let h = b.height(forWidth: w)
            b.frame = NSRect(x: 0, y: y, width: w, height: h)
            y += h + (i == blocks.count - 1 ? 0 : gap)
        }
        let newHeight = ceil(y)
        if abs(newHeight - height) > 0.5 {
            height = newHeight
            invalidateIntrinsicContentSize()
            onHeightChange?()
        }
    }
}

/// 折叠块里可以就地换文字的纯文本正文（工具输出 `AgentToolOutputView`）。
@MainActor
protocol AgentPlainTextBody: NSView {
    func update(text: String)
}

/// 折叠块：一行表头 + 点开才看得见的正文（思考过程、工具输出共用）。
///
/// 原来是个构造函数，改成类是为了**思考过程也能就地更新**（它同样是流式来的，见 `AgentMarkdownView`），
/// 顺带把「展开着又来了新内容」时被折回去的毛病一起解决了。
///
/// 🔴 **折着时整条在约束引擎里只占它自己一个视图**（2026-10-10，见 `AgentRowView`）：Agent 记笔记时对话记录里
/// 绝大多数是这种条目（每次工具调用、每段思考各一条），原来每条套三层 `NSStackView`，条目一多每来一条都要
/// 重新求解一大片约束，整窗卡住。现在表头那一行按 frame 摆、高度按固有尺寸报；正文（工具输出最长 4000 字、
/// 思考过程的 Markdown）点开才装上、用约束接在表头下面，收起就摘掉，它身上的约束跟着一起摘。
/// 思考过程折着时照旧攒着流式文本，装上时由 `AgentMarkdownView.viewDidMoveToWindow` 补排。
@MainActor
final class AgentDisclosureView: NSView {
    private let toggle: NSButton
    private let body: NSView
    /// 正文是 Markdown 渲染的那一种（思考过程）；工具输出是等宽纯文本，这里是 nil。
    let markdown: AgentMarkdownView?
    /// 折叠箭头 + 表头，按 frame 摆在顶上。
    private let row: AgentRowView
    private var expanded: Bool { body.superview === self }

    /// - Parameter header: 表头那一行（折叠箭头右边的东西）。
    /// - Parameter body: 展开后显示的正文。
    init(header: NSView, body: NSView, markdown: AgentMarkdownView? = nil) {
        self.body = body
        self.markdown = markdown
        let toggle = NSButton()
        self.toggle = toggle
        row = AgentRowView([toggle, header], spacing: 2)
        super.init(frame: .zero)
        toggle.bezelStyle = .disclosure
        toggle.setButtonType(.pushOnPushOff)
        toggle.title = ""
        toggle.state = .off
        toggle.target = self
        toggle.action = #selector(toggled)
        body.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) 不支持") }

    override var isFlipped: Bool { true }

    /// 折着：高度就是表头一行。展开：高度由正文那几条约束定，这里不报。
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: expanded ? NSView.noIntrinsicMetric : row.intrinsicContentSize.height)
    }

    override func layout() {
        super.layout()
        let s = row.intrinsicContentSize
        row.frame = NSRect(x: 0, y: 0, width: min(s.width, bounds.width), height: s.height)
    }

    @objc private func toggled() {
        let open = toggle.state == .on
        guard open != expanded else { return }
        if open {
            addSubview(body)
            // 正文铺满整行宽（引擎要靠这个宽度排版；wrapping label 也靠它折行），接在表头下面 4pt
            NSLayoutConstraint.activate([
                body.topAnchor.constraint(equalTo: topAnchor, constant: row.intrinsicContentSize.height + 4),
                body.leadingAnchor.constraint(equalTo: leadingAnchor),
                body.trailingAnchor.constraint(equalTo: trailingAnchor),
                body.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
        } else {
            body.removeFromSuperview()   // 它身上那几条约束跟着摘掉
        }
        invalidateIntrinsicContentSize()
    }

    /// 思考过程的新文本（流式）。
    func update(text: String) { markdown?.update(text: text) }

    /// 工具输出的新文本（流式；正文是 `AgentToolOutputView` / 等宽纯文本标签的那一种）。折着时正文不在视图树里，只换文字、不排版。
    /// - Returns: 吃下了（正文不是这两种就不管，调用方整条重建）。
    func update(plain text: String) -> Bool {
        guard markdown == nil else { return false }
        if let out = body as? AgentPlainTextBody {
            out.update(text: text)
            return true
        }
        guard let label = body as? NSTextField else { return false }
        if label.stringValue != text { label.stringValue = text }
        return true
    }

    /// 表头的图标 + 标题这一行（思考过程用）。
    static func headerRow(title: String, symbol: String) -> NSView {
        let l = NSTextField(labelWithString: title)
        l.font = .preferredFont(forTextStyle: .callout)
        let i = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage())
        return AgentRowView([i, l], spacing: 4)
    }
}
