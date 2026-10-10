import AppKit
import Highlighter
import MarkdownEngine
import SwiftUI

/// Agent 面板里正文的 Markdown 渲染（`ACP-AGENT-PLAN.md` A3）。
///
/// 从前只做行内语法（`AttributedString(markdown:)` 的 `inlineOnlyPreservingWhitespace`）：标题、列表、
/// 代码块、表格、公式全是原样的源码。这里改成与笔记同一个引擎（`swift-markdown-engine`）的只读渲染。
///
/// 🔴 引擎只公开了 SwiftUI 包装，所以这里用 `NSHostingView` 托管——与笔记气泡正文 / 编辑弹窗 / 整篇编辑区
/// 同属「Markdown 引擎」这一条例外（根 `AGENTS.md`「SwiftUI 只用在两处」），其余界面仍是 AppKit。
@MainActor
enum AgentMarkdown {
    /// Agent 回复正文的字号（与改造前的纯文本一致）。
    static var bodyFontSize: CGFloat { NSFont.systemFontSize }
    /// 思考过程折叠起来的正文：比回复小一号（同改造前的 `.callout`）。
    static var thoughtFontSize: CGFloat { NSFont.preferredFont(forTextStyle: .callout).pointSize }

    /// 面板里的只读配置：高度由内容定（滚轮交给对话记录那个滚动视图）、不要自带滚动条与留白、
    /// 不做拼写检查（显示的是别人写的文字，画红波浪线没意义）。
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

/// 托管进 `NSHostingView` 的那一层：排完版把真实高度报回给 AppKit（同 `BubbleMarkdownHost` 的做法）。
struct AgentMarkdownHost: View {
    let text: String
    let width: CGFloat
    let fontSize: CGFloat
    let documentId: String
    let onHeight: (CGFloat) -> Void
    /// 右键菜单（`AgentMarkdownView.contextMenu`）。引擎每次 `updateNSView` 都会换上新的，不像 `onLinkClick` 只认第一次。
    let onContextMenu: (NSMenu, NSRange) -> NSMenu

    var body: some View {
        NoteLatexRenderer.shared.registerBlocks(in: text)   // 块公式按块排版：须先于引擎排版登记
        return NativeTextViewWrapper(text: .constant(text),
                                     configuration: AgentMarkdown.configuration.fittingLatex(to: width),
                                     fontSize: fontSize,
                                     documentId: documentId,
                                     isEditable: false,
                                     onBuildContextMenu: onContextMenu)
            .frame(width: width)
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { onHeight($0) }
            .frame(width: width, alignment: .topLeading)
    }
}

/// 一段 Markdown 正文（Agent 的回复 / 思考过程）。宽度由外面的约束给，高度是引擎排完版报回来的。
///
/// 🔴 **排版很贵，交给引擎的次数必须掐着来**——每排一次都是整篇重排（TextKit 2），下面三条缺一不可：
///  · **流式就地更新，不重建视图**：回复是一个碎片一个碎片来的。重建 = 每片都新建一棵 TextKit 2 的视图树，
///    长回复几百片下来必卡；所以对话记录那边认出是同一条时只调 `update(text:)`。
///  · **文本按 80ms 并流**（`textInterval`）：否则一条几千字的回复要被整篇排上几百遍。
///  · **宽度防抖 + 看不见不排**（2026-09-20 用户实测「拖侧边栏很卡，不管在不在 Agent 页」）：
///    `InspectorViewController.viewDidLayout` **每次布局都给 Agent 页及其子视图设 frame**，不管这页显不显示；
///    拖分隔条时逐帧改宽度，照排就是每帧把每条回复整篇重排一遍。所以宽度变化只在停手后排一次
///    （`widthInterval`），而且看不见时（不在窗口 / 自己或祖先隐藏 / 折叠着的思考过程）一次都不排，
///    露出来时再补（`viewDidUnhide` / `viewDidMoveToWindow`）。
@MainActor
final class AgentMarkdownView: NSView {
    /// 已经交给引擎的文本。
    private(set) var text: String
    private let fontSize: CGFloat
    private let documentId: String
    private var host: NSHostingView<AgentMarkdownHost>?
    /// 已经交给引擎的宽度。
    private var hostWidth: CGFloat = -1
    /// 引擎报回来的正文高度。
    private var height: CGFloat = 0
    /// 排完版高度变了：对话记录据此决定要不要继续贴着底。
    var onHeightChange: (() -> Void)?

    /// 还没交给引擎的输入（攒着，到点 / 露出来再一起排）。
    private var pendingText: String?
    private var pendingWidth: CGFloat?
    private var lastApply = Date.distantPast
    private var timer: Timer?
    /// 文本并流的间隔（最多这么频繁地重排一次）。
    private static let textInterval: TimeInterval = 0.08
    /// 宽度是防抖：拖分隔条的整个过程一次都不排，停手才排。
    private static let widthInterval: TimeInterval = 0.15

    /// 现在排版有没有意义。
    private var isVisible: Bool { window != nil && !isHiddenOrHasHiddenAncestor }

    init(text: String, fontSize: CGFloat, documentId: String) {
        self.text = text
        self.fontSize = fontSize
        self.documentId = documentId
        super.init(frame: .zero)
        // 拖窄的那一瞬间正文还是按旧宽度排的，别让它画到面板外面去
        clipsToBounds = true
        lastApply = Date()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) 不支持") }

    deinit { timer?.invalidate() }

    override var isFlipped: Bool { true }

    /// 高度是排出来的；第一帧还没排时先占一行，免得条目塌成 0 高。
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: max(height, (fontSize * 1.5).rounded()))
    }

    /// 流式来的新文本（同一条回复越来越长）。
    func update(text: String) {
        guard text != (pendingText ?? self.text) else { return }
        pendingText = text
        guard isVisible else { return }          // 看不见：攒着，露出来再排
        if Date().timeIntervalSince(lastApply) >= Self.textInterval {
            flush()
        } else {
            arm(Self.textInterval, restart: false)
        }
    }

    override func layout() {
        super.layout()
        host?.frame = bounds
        guard abs(bounds.width - (pendingWidth ?? hostWidth)) > 0.5 else { return }
        pendingWidth = bounds.width
        guard isVisible else { return }
        // 第一次得立刻排，不然面板要空着等防抖那几十毫秒
        if host == nil { flush() } else { arm(Self.widthInterval, restart: true) }
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        needsLayout = true      // 藏着的时候宽度可能变过，量一遍
        flushIfPending()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        needsLayout = true
        flushIfPending()
    }

    private func flushIfPending() {
        guard isVisible, pendingText != nil || pendingWidth != nil else { return }
        flush()
    }

    /// 尺寸已经定下来了（拖分隔条松手），立刻按新宽度排一次，别再等防抖那 150ms。
    func flushNow() { flushIfPending() }

    /// 到点（或该露面了）就把攒下的文本 / 宽度一起交给引擎，排一次。
    private func arm(_ interval: TimeInterval, restart: Bool) {
        if restart { timer?.invalidate(); timer = nil }
        guard timer == nil else { return }
        let t = Timer(timeInterval: interval, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.timer = nil
                self.flush()
            }
        }
        timer = t
        // .common：面板正在滚动时这只表也得照常走，否则流式回复会停在半截
        RunLoop.main.add(t, forMode: .common)
    }

    private func flush() {
        timer?.invalidate()
        timer = nil
        guard pendingText != nil || pendingWidth != nil else { return }
        if let t = pendingText { text = t }
        if let w = pendingWidth { hostWidth = w }
        pendingText = nil
        pendingWidth = nil
        lastApply = Date()
        rebuildRoot()
    }

    private func rebuildRoot() {
        let root = AgentMarkdownHost(text: text, width: max(hostWidth, 0), fontSize: fontSize, documentId: documentId,
                                     onHeight: { [weak self] in self?.setHeight($0) },
                                     onContextMenu: { [weak self] menu, sel in self?.contextMenu(menu, selection: sel) ?? menu })
        if let host {
            host.rootView = root
        } else {
            let h = NSHostingView(rootView: root)
            h.sizingOptions = []      // 高度我们自己按引擎报回来的值管，别让 hosting view 也插一手
            h.frame = bounds
            addSubview(h)
            host = h
        }
    }

    private func setHeight(_ h: CGFloat) {
        guard abs(height - h) > 0.5 else { return }
        height = h
        invalidateIntrinsicContentSize()
        needsLayout = true
        onHeightChange?()
    }

    // MARK: 右键菜单

    /// 我们加的菜单项（菜单若是被复用的同一个对象，下次先摘掉这些，别越加越多）。
    private static let menuItemID = NSUserInterfaceItemIdentifier("agent.markdown.copyBlock")

    /// 引擎在 `NSHostingView` 里建的那个文本视图（右键要用它换算点击位置、改选区）。
    private var textView: NSTextView? { host.flatMap(Self.firstTextView(in:)) }

    private static func firstTextView(in v: NSView) -> NSTextView? {
        if let t = v as? NSTextView { return t }
        for s in v.subviews { if let t = firstTextView(in: s) { return t } }
        return nil
    }

    /// 右键菜单（引擎把系统默认菜单 + 当前选区交给这里，`onBuildContextMenu`）：点在表格 / 代码块上时，
    /// 顶上加一项「复制表格」/「复制代码」（2026-10-05 用户要的）；系统原有的项不动。
    ///
    /// 🔴 表格是整张画成一张图的（宽的再套一层横向滚动），右键点在图上，事件一路传给底下的文本视图，
    /// 它按「点中的词」选中了表格隐藏源码里的一个字符——那个字符的框是一大块，蓝色选区就盖住了半张表
    /// （同日用户截图，离屏复现：选区 = 表格开头的 `|`）。所以点在表格上时把这种落在表格里的选区收成插入点；
    /// 用户先拖出来、跨出表格的选区不动。
    private func contextMenu(_ menu: NSMenu, selection: NSRange) -> NSMenu {
        for item in menu.items where item.identifier == Self.menuItemID { menu.removeItem(item) }
        let tv = textView
        let source = tv?.string ?? text
        // 点中的位置：按这次右键的坐标算（已有的选区可能是用户早先拖出来的，不在点击处）
        var index = selection.location
        if let tv, let ev = NSApp.currentEvent, ev.window === tv.window,
           ev.type == .rightMouseDown || ev.type == .leftMouseDown {
            index = tv.characterIndexForInsertion(at: tv.convert(ev.locationInWindow, from: nil))
        }
        guard let block = AgentMarkdownBlock.block(at: index, in: source) else { return menu }
        let content = (source as NSString).substring(with: block.content)
        let item: NSMenuItem
        switch block.kind {
        case .table:
            if let tv, selection.length > 0, selection.location >= block.range.location,
               NSMaxRange(selection) <= NSMaxRange(block.range) + 1 {
                tv.setSelectedRange(NSRange(location: block.range.location, length: 0))
            }
            item = ClosureMenuItem(L("Copy Table")) { AgentMarkdown.copyTable(content) }
        case .code:
            item = ClosureMenuItem(L("Copy Code")) { AgentMarkdown.copyCode(content) }
        }
        let separator = NSMenuItem.separator()
        item.identifier = Self.menuItemID
        separator.identifier = Self.menuItemID
        menu.insertItem(separator, at: 0)
        menu.insertItem(item, at: 0)
        return menu
    }
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

    /// 表头的图标 + 标题这一行（思考过程用）。
    static func headerRow(title: String, symbol: String) -> NSView {
        let l = NSTextField(labelWithString: title)
        l.font = .preferredFont(forTextStyle: .callout)
        let i = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage())
        return AgentRowView([i, l], spacing: 4)
    }
}
