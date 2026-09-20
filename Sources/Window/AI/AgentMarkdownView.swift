import AppKit
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
    static let configuration: MarkdownEditorConfiguration = {
        var c = MarkdownEditorConfiguration.default
        c.heightBehavior = .fitsContent
        c.overscroll = OverscrollPolicy(percent: 0, maxPoints: 0, minPoints: 0)
        c.scrollers = .hidden
        c.textInsets = TextInsets(horizontal: 0, vertical: 0)
        c.spellChecking = SpellCheckingPolicy(continuousSpellChecking: false, grammarChecking: false,
                                              automaticSpellingCorrection: false)
        MarkdownNoteEditor.applyNoteTypography(&c)
        return c
    }()
}

/// 托管进 `NSHostingView` 的那一层：排完版把真实高度报回给 AppKit（同 `BubbleMarkdownHost` 的做法）。
struct AgentMarkdownHost: View {
    let text: String
    let width: CGFloat
    let fontSize: CGFloat
    let documentId: String
    let onHeight: (CGFloat) -> Void

    var body: some View {
        NoteLatexRenderer.shared.registerBlocks(in: text)   // 块公式按块排版：须先于引擎排版登记
        return NativeTextViewWrapper(text: .constant(text),
                                     configuration: AgentMarkdown.configuration.fittingLatex(to: width),
                                     fontSize: fontSize,
                                     documentId: documentId,
                                     isEditable: false)
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
        let root = AgentMarkdownHost(text: text, width: max(hostWidth, 0), fontSize: fontSize,
                                     documentId: documentId) { [weak self] in self?.setHeight($0) }
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
}

/// 折叠块：一行表头 + 点开才看得见的正文（思考过程、工具输出共用）。
///
/// 原来是个构造函数，改成类是为了**思考过程也能就地更新**（它同样是流式来的，见 `AgentMarkdownView`），
/// 顺带把「展开着又来了新内容」时被折回去的毛病一起解决了。
@MainActor
final class AgentDisclosureView: NSView {
    private let toggle = NSButton()
    private let body: NSView
    /// 正文是 Markdown 渲染的那一种（思考过程）；工具输出是等宽纯文本，这里是 nil。
    let markdown: AgentMarkdownView?
    private let column = NSStackView()

    /// - Parameter header: 表头那一行（折叠箭头右边的东西）。
    /// - Parameter body: 展开后显示的正文。
    init(header: NSView, body: NSView, markdown: AgentMarkdownView? = nil) {
        self.body = body
        self.markdown = markdown
        super.init(frame: .zero)
        toggle.bezelStyle = .disclosure
        toggle.setButtonType(.pushOnPushOff)
        toggle.title = ""
        toggle.state = .off
        toggle.target = self
        toggle.action = #selector(toggled)
        body.isHidden = true

        let row = NSStackView(views: [toggle, header])
        row.spacing = 2
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 4
        column.addArrangedSubview(row)
        column.addArrangedSubview(body)
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        // 正文铺满整行宽（引擎要靠这个宽度排版；wrapping label 也靠它折行）。
        // 999 而不是 required：折叠起来时 stack 自己那套约束说了算，别为此吵起来。
        let bodyWidth = body.widthAnchor.constraint(equalTo: column.widthAnchor)
        bodyWidth.priority = .init(999)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: leadingAnchor),
            column.trailingAnchor.constraint(equalTo: trailingAnchor),
            column.topAnchor.constraint(equalTo: topAnchor),
            column.bottomAnchor.constraint(equalTo: bottomAnchor),
            bodyWidth,
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) 不支持") }

    @objc private func toggled() { body.isHidden = toggle.state != .on }

    /// 思考过程的新文本（流式）。
    func update(text: String) { markdown?.update(text: text) }

    /// 表头的图标 + 标题这一行（思考过程用）。
    static func headerRow(title: String, symbol: String) -> NSView {
        let l = NSTextField(labelWithString: title)
        l.font = .preferredFont(forTextStyle: .callout)
        let i = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage())
        let s = NSStackView(views: [i, l])
        s.spacing = 4
        return s
    }
}
