import AppKit

/// 用户发的一句话：靠右，上面一排图片缩略图、下面一个气泡。
///
/// 气泡正文与 Agent 回复同一套 Markdown 引擎只读渲染（2026-10-05 用户要「输入的也展示为 Markdown」），
/// 字号同回复。气泡**按内容收窄**：引擎排版只会按给定宽度报高度、不会报「最窄要多宽」，
/// 所以宽度按原文估（`AgentMarkdown.fittingWidth`），有块级结构就撑到上限（条目宽 − 48）。
///
/// 🔴 「想要多宽」的两条约束（`fit` / `fill`）优先级压在 240：低于 `NSSplitView` 默认的保持优先级（250）
/// 和窗口保持尺寸（500），只在给定的宽度里挑，**绝不反过来把面板 / 窗口撑宽**。曾用 750 + 常数 10000 表示
/// 「撑满」，离屏验证里直接把窗口撑到 1 万多 pt。气泡也不放进 `NSStackView`：它的贴边约束会和这两条抢。
///
/// 气泡下面一行「上下文」（`ACP-AGENT-PLAN.md §18`，用户 2026-11-12）：随这条消息发给 Agent、气泡里看不见的东西
/// （`@` 引用、引用出处、交接摘要、用户在看什么），图标 + 名字，悬停看发给 Agent 的原话。没有就不占地方。
///
/// 单独成文件是为了离屏验证能直接编它（`spike/agent-user-bubble-test.swift`）。
@MainActor
final class AgentUserMessageView: NSView {
    let images: [AgentImage]
    let context: [AgentSentContext]
    /// 「上下文」那一行（没有上下文时为 nil）。
    private(set) var contextLabel: NSTextField?
    /// 那一行的宽：一行放得下就按文字宽（靠右收窄），放不下就到上限、折行（`layout` 里按可用宽度算）。
    private var contextWidth: NSLayoutConstraint?
    /// 正文（只有图片、没说话时为 nil）。
    let markdown: AgentMarkdownView?
    /// 气泡（离屏验证量它的宽度）。
    private(set) var bubble: NSView?
    /// 能估宽度时：正文宽 = 估出来的宽（超过上限就被上限压住、按上限折行）。
    private var fit: NSLayoutConstraint?
    /// 估不出来（块级结构）时：气泡左边贴到上限处 = 撑满。
    private var fill: NSLayoutConstraint?

    /// 气泡里正文离边框的距离（同改造前的纯文本气泡）。
    static let padX: CGFloat = 12
    static let padY: CGFloat = 7
    /// 气泡左边至少空出这么多（同改造前）。
    static let leftGap: CGFloat = 48
    private static let preference = NSLayoutConstraint.Priority(240)

    init(text: String, images: [AgentImage], context: [AgentSentContext] = [], id: UUID) {
        self.images = images
        self.context = context
        markdown = text.isEmpty ? nil
            : AgentMarkdownView(text: text, fontSize: AgentMarkdown.bodyFontSize, documentId: "user-\(id)")
        super.init(frame: .zero)
        // 底下那一行「上下文」：有就由它贴底，气泡 / 图片排在它上面
        let ctxLabel = context.isEmpty ? nil : Self.makeContextLabel(context)
        if let ctxLabel {
            addSubview(ctxLabel)
            contextLabel = ctxLabel
            // 折行标签没有确定的「自然宽度」，宽度得明说；比必需低一档，窄窗口里让给左边那条
            let w = ctxLabel.widthAnchor.constraint(equalToConstant: 120)
            w.priority = NSLayoutConstraint.Priority(999)
            contextWidth = w
            NSLayoutConstraint.activate([
                ctxLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
                ctxLabel.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: Self.leftGap),
                ctxLabel.bottomAnchor.constraint(equalTo: bottomAnchor),
                w,
            ])
        }
        let bottom = ctxLabel?.topAnchor ?? bottomAnchor
        let bottomGap: CGFloat = ctxLabel == nil ? 0 : -4
        var top = topAnchor
        if !images.isEmpty {
            let row = NSStackView(views: images.map { AgentImageThumbView(image: $0, side: 56) })
            row.spacing = 6
            row.translatesAutoresizingMaskIntoConstraints = false
            addSubview(row)
            NSLayoutConstraint.activate([
                row.topAnchor.constraint(equalTo: topAnchor),
                row.trailingAnchor.constraint(equalTo: trailingAnchor),
                row.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor),
            ])
            top = row.bottomAnchor
            if markdown == nil { row.bottomAnchor.constraint(equalTo: bottom, constant: bottomGap).isActive = true }
        }
        guard let md = markdown else {
            if images.isEmpty { ctxLabel?.topAnchor.constraint(equalTo: topAnchor).isActive = true }
            return
        }
        let bubble = NSView()
        bubble.wantsLayer = true
        bubble.layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
        bubble.layer?.cornerRadius = 12
        bubble.layer?.cornerCurve = .continuous
        bubble.translatesAutoresizingMaskIntoConstraints = false
        md.translatesAutoresizingMaskIntoConstraints = false
        bubble.addSubview(md)
        addSubview(bubble)
        self.bubble = bubble
        let fit = md.widthAnchor.constraint(equalToConstant: 0)
        let fill = bubble.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.leftGap)
        fit.priority = Self.preference
        fill.priority = Self.preference
        self.fit = fit
        self.fill = fill
        NSLayoutConstraint.activate([
            md.leadingAnchor.constraint(equalTo: bubble.leadingAnchor, constant: Self.padX),
            md.trailingAnchor.constraint(equalTo: bubble.trailingAnchor, constant: -Self.padX),
            md.topAnchor.constraint(equalTo: bubble.topAnchor, constant: Self.padY),
            md.bottomAnchor.constraint(equalTo: bubble.bottomAnchor, constant: -Self.padY),
            bubble.topAnchor.constraint(equalTo: top, constant: images.isEmpty ? 0 : 6),
            bubble.bottomAnchor.constraint(equalTo: bottom, constant: bottomGap),
            bubble.trailingAnchor.constraint(equalTo: trailingAnchor),
            bubble.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: Self.leftGap),
        ])
        refit(text)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) 不支持") }

    /// 正文换了（回放时同一句话分片推回来）。
    /// - Returns: 就地换成了；原来没有正文（只有图片）的得重建，返回 false。
    func update(text: String) -> Bool {
        guard let markdown, !text.isEmpty else { return false }
        refit(text)
        markdown.update(text: text)
        return true
    }

    override func layout() {
        // 「上下文」那行：一行放得下就按文字宽，放不下到上限折行。折行标签的高度只认 `preferredMaxLayoutWidth`
        if let l = contextLabel, let wc = contextWidth, bounds.width > 0 {
            let cap = max(60, bounds.width - Self.leftGap)
            // 一行的宽（含文字框自己的内边距），多留 2pt：贴着量会因为舍入多折一行
            let natural = ceil(l.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: 100_000, height: 100_000)).width ?? cap) + 2
            let w = min(natural, cap)
            if abs(wc.constant - w) > 0.5 || abs(l.preferredMaxLayoutWidth - w) > 0.5 {
                wc.constant = w
                l.preferredMaxLayoutWidth = w
                l.invalidateIntrinsicContentSize()
            }
        }
        super.layout()
    }

    /// 「上下文：📄 书名.pdf  👁 正在看《…》第 12 页 …」：小一号、`labelColor`（红线 4：玻璃底上别用次要色），靠右折行。
    /// 🔴 横向抗压缩压到 200：一长串名字只能折行，绝不把面板 / 窗口撑宽（同气泡那两条 240 的约束）。
    private static func makeContextLabel(_ context: [AgentSentContext]) -> NSTextField {
        let font = NSFont.systemFont(ofSize: 11)
        let s = NSMutableAttributedString(string: L("Context:") + " ",
                                          attributes: [.font: NSFont.systemFont(ofSize: 11, weight: .medium),
                                                       .foregroundColor: NSColor.labelColor])
        // 图标显式上 `labelColor`（模板图在富文本里不一定跟着文字色走）
        let cfg = NSImage.SymbolConfiguration(pointSize: 10, weight: .regular)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.labelColor]))
        for (i, c) in context.enumerated() {
            if i > 0 { s.append(NSAttributedString(string: "   ", attributes: [.font: font])) }
            if let img = NSImage(systemSymbolName: symbol(c), accessibilityDescription: nil)?.withSymbolConfiguration(cfg) {
                let a = NSTextAttachment()
                a.image = img
                a.bounds = CGRect(x: 0, y: -1.5, width: img.size.width, height: img.size.height)
                s.append(NSAttributedString(attachment: a))
                s.append(NSAttributedString(string: "\u{202F}", attributes: [.font: font]))   // 窄的不断行空格：图标不和名字分开
            }
            // 一项里的空格换成不断行空格：折行只在两项之间（英文「Saved context “…”」别断成两截）
            let text = label(c).replacingOccurrences(of: " ", with: "\u{00A0}")
            s.append(NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.labelColor]))
        }
        let p = NSMutableParagraphStyle()
        p.alignment = .right
        p.lineBreakMode = .byWordWrapping
        s.addAttribute(.paragraphStyle, value: p, range: NSRange(location: 0, length: s.length))
        let l = NSTextField(wrappingLabelWithString: "")
        l.attributedStringValue = s
        l.isSelectable = false
        l.translatesAutoresizingMaskIntoConstraints = false
        l.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(200), for: .horizontal)
        l.setContentHuggingPriority(NSLayoutConstraint.Priority(200), for: .horizontal)
        l.setContentHuggingPriority(.required, for: .vertical)
        l.toolTip = context.map { c in c.detail.isEmpty ? label(c) : label(c) + "\n" + c.detail }.joined(separator: "\n\n")
        return l
    }

    /// 那一项显示成什么（人话，跟着界面语言）。
    static func label(_ c: AgentSentContext) -> String {
        let name = c.name.isEmpty ? L("Untitled") : c.name
        switch c.kind {
        case .reference: return name
        case .viewingDocument:
            return c.page.map { String(format: L("Viewing “%@”, page %d"), name, $0) } ?? String(format: L("Viewing “%@”"), name)
        case .viewingNote: return String(format: L("Viewing note “%@”"), name)
        case .viewingExercises:
            return c.page.map { String(format: L("Practicing “%@”, question %d"), name, $0) } ?? String(format: L("Practicing “%@”"), name)
        case .quote:
            return c.page.map { String(format: L("Quote from “%@”, page %d"), name, $0) } ?? String(format: L("Quote from “%@”"), name)
        case .grading: return L("Grading request")
        case .handoff: return String(format: L("Saved context “%@”"), name)
        case .saveRequest: return L("Summary instructions")
        case .memories: return String(format: L("Workspace memories (%d)"), c.page ?? 0)
        }
    }

    static func symbol(_ c: AgentSentContext) -> String {
        switch c.kind {
        case .reference(let k):
            switch k {
            case .pdf?: return "doc.text"
            case .note?: return "note.text"
            case .folder?: return "folder"
            case .documents?: return "books.vertical"
            case .board?, .boards?: return "scribble.variable"
            case .exercises?: return "checklist"
            case .exercise?: return "questionmark.square"
            case .command?, nil: return "link"
            }
        case .viewingDocument, .viewingNote, .viewingExercises: return "eye"
        case .quote: return "text.quote"
        case .grading: return "checkmark.seal"
        case .handoff: return "tray.full"
        case .saveRequest: return "square.and.pencil"
        case .memories: return "brain"
        }
    }

    /// 能估就按估的宽，估不出来就撑满（两条只开一条）。
    private func refit(_ text: String) {
        let w = AgentMarkdown.fittingWidth(of: text, fontSize: AgentMarkdown.bodyFontSize)
        fit?.constant = w ?? 0
        fit?.isActive = w != nil
        fill?.isActive = w == nil
    }
}
