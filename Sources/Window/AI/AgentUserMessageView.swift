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
/// 单独成文件是为了离屏验证能直接编它（`spike/agent-user-bubble-test.swift`）。
@MainActor
final class AgentUserMessageView: NSView {
    let images: [AgentImage]
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

    init(text: String, images: [AgentImage], id: UUID) {
        self.images = images
        markdown = text.isEmpty ? nil
            : AgentMarkdownView(text: text, fontSize: AgentMarkdown.bodyFontSize, documentId: "user-\(id)")
        super.init(frame: .zero)
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
            if markdown == nil { row.bottomAnchor.constraint(equalTo: bottomAnchor).isActive = true }
        }
        guard let md = markdown else { return }
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
            bubble.bottomAnchor.constraint(equalTo: bottomAnchor),
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

    /// 能估就按估的宽，估不出来就撑满（两条只开一条）。
    private func refit(_ text: String) {
        let w = AgentMarkdown.fittingWidth(of: text, fontSize: AgentMarkdown.bodyFontSize)
        fit?.constant = w ?? 0
        fit?.isActive = w != nil
        fill?.isActive = w == nil
    }
}
