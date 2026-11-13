import AppKit

/// 工具调用展开后的输出（`AgentItemViews.tool` 的折叠正文；2026-11-13 用户截图：展开后整屏是等宽字、和回复连成一片、
/// 行号贴着正文、末尾又是一大段重复的 JSON——那段在 `AgentToolText.clean` 里去掉）：
/// - 浅底圆角块（与代码块同底色），和 Agent 的回复分得开；等宽、照原样、自动折行、可选中；
/// - `cat -n` 式行号（`read_markdown`：`  36\t正文`）：行号一栏、正文对齐，折行的接续行也对齐正文
///   （原来制表位按默认 28pt 走，四位行号正好占满，正文贴着行号）；
/// - 长输出先只显示前 `previewLines` 行 / `previewChars` 字，底下「显示全部」，展开后「收起」。
///
/// 🔴 同 `AgentRowView`：**自己按 frame 摆、不进约束引擎**，对外只报固有高度（按当前宽度量出来的）。
@MainActor
final class AgentToolOutputView: NSView, AgentPlainTextBody {
    private(set) var text: String
    /// 展开了全部（否则只显示开头一段）。
    private(set) var showsAll = false
    private let fontSize: CGFloat
    private let storage = NSTextStorage()
    private let layoutManager = NSLayoutManager()
    private let container = NSTextContainer(size: NSSize(width: 100, height: CGFloat.greatestFiniteMagnitude))
    private let textView: AgentSelectableTextView
    private let toggle = NSButton(title: "", target: nil, action: nil)
    /// 文字按这个宽度量过的高度。
    private var measured: (width: CGFloat, height: CGFloat)?
    /// 上次报出去的高度（变了才通知外面重排）。
    private var reported: CGFloat = -1

    static let pad: CGFloat = 8
    static let previewLines = 12
    static let previewChars = 1500

    init(text: String, fontSize: CGFloat = NSFont.smallSystemFontSize) {
        self.text = text
        self.fontSize = fontSize
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
        textView.isRichText = false
        textView.textContainerInset = .zero
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = false
        textView.extraMenuItems = { [weak self] in
            guard let self else { return [] }
            let all = self.text
            return [ClosureMenuItem(L("Copy Output")) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(all, forType: .string)
            }]
        }
        addSubview(textView)
        toggle.isBordered = false
        toggle.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        toggle.contentTintColor = .linkColor   // 红线④：无边框按钮必须显式给颜色，系统默认画得极淡
        toggle.target = self
        toggle.action = #selector(toggled)
        addSubview(toggle)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.cornerCurve = .continuous
        apply()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) 不支持") }

    override var isFlipped: Bool { true }

    /// 流式：输出又长了（选区会丢，接受）。
    func update(text: String) {
        guard text != self.text else { return }
        self.text = text
        apply()
    }

    /// 底下那个按钮显示着（输出比预览长）。
    var hasToggle: Bool { !toggle.isHidden }
    /// 现在显示出来的文字。
    var shownText: String { storage.string }

    private func apply() {
        let p = Self.preview(text)
        let shown = showsAll || !p.cut ? text : p.text
        storage.setAttributedString(Self.attributed(shown, fontSize: fontSize))
        measured = nil
        toggle.isHidden = !p.cut
        if p.cut {
            toggle.title = showsAll ? L("Show Less")
                : p.lines > Self.previewLines ? String(format: L("Show All %d Lines"), p.lines) : L("Show All")
        }
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    @objc private func toggled() {
        showsAll.toggle()
        apply()
    }

    // MARK: 尺寸与摆放

    private func textHeight(forWidth w: CGFloat) -> CGFloat {
        let tw = max(1, w - 2 * Self.pad)
        if let m = measured, abs(m.width - tw) < 0.25 { return m.height }
        container.size = NSSize(width: tw, height: CGFloat.greatestFiniteMagnitude)
        layoutManager.ensureLayout(for: container)
        let h = ceil(layoutManager.usedRect(for: container).height)
        measured = (tw, h)
        return h
    }

    private var toggleHeight: CGFloat { toggle.isHidden ? 0 : ceil(toggle.intrinsicContentSize.height) }

    /// 按宽度 `w` 的总高度。
    func height(forWidth w: CGFloat) -> CGFloat {
        let t = textHeight(forWidth: w)
        return Self.pad + t + (toggle.isHidden ? Self.pad : 4 + toggleHeight + 4)
    }

    /// 还没摆过（不知道宽度）时先按一行一行估：差一点没关系，第一次摆好就报准的。
    override var intrinsicContentSize: NSSize {
        let h: CGFloat
        if bounds.width > 1 {
            h = height(forWidth: bounds.width)
        } else {
            let line = ceil(NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular).boundingRectForFont.height)
            let lines = max(1, storage.string.split(separator: "\n", omittingEmptySubsequences: false).count)
            h = Self.pad * 2 + CGFloat(lines) * line + (toggle.isHidden ? 0 : 4 + toggleHeight)
        }
        return NSSize(width: NSView.noIntrinsicMetric, height: h)
    }

    override func layout() {
        super.layout()
        let t = textHeight(forWidth: bounds.width)
        textView.frame = NSRect(x: Self.pad, y: Self.pad, width: max(1, bounds.width - 2 * Self.pad), height: t)
        if !toggle.isHidden {
            let s = toggle.intrinsicContentSize
            toggle.frame = NSRect(x: Self.pad, y: Self.pad + t + 4, width: ceil(s.width), height: ceil(s.height))
        }
        let h = height(forWidth: bounds.width)
        if abs(h - reported) > 0.5 {
            reported = h
            invalidateIntrinsicContentSize()
        }
    }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.backgroundColor = AgentCodeHighlighter.shared.backgroundColor().cgColor
    }

    // MARK: 纯函数（`spike/agent-tool-output-test.swift`）

    /// 开头一段：前 `previewLines` 行、最多 `previewChars` 字。`cut` = 比全文短；`lines` = 全文行数。
    static func preview(_ s: String) -> (text: String, cut: Bool, lines: Int) {
        let lines = s.split(separator: "\n", omittingEmptySubsequences: false)
        var out = lines.prefix(previewLines).joined(separator: "\n")
        var cutInLine = false
        if out.count > previewChars {
            out = String(out.prefix(previewChars))
            cutInLine = true
        }
        let cut = out.count < s.count
        if cut, cutInLine { out += "…" }
        return (out, cut, lines.count)
    }

    /// `  36\t正文` 这种行开头的行号那一栏有几个字符（行号前的空格算在内）；不是就 nil。
    static func numberColumn(_ line: Substring) -> Int? {
        var n = 0, digits = 0
        for c in line {
            if c == "\t" { return digits > 0 ? n : nil }
            if c == " ", digits == 0 { n += 1; continue }
            guard c.isASCII, c.isNumber else { return nil }
            digits += 1
            n += 1
            if n > 10 { return nil }
        }
        return nil
    }

    /// 等宽、照原样；带行号的行：行号后的制表位放在行号栏右边两格，折行接续行与正文对齐。
    static func attributed(_ s: String, fontSize: CGFloat) -> NSAttributedString {
        let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        let ch = ("0" as NSString).size(withAttributes: [.font: font]).width
        let base = NSMutableParagraphStyle()
        base.tabStops = []
        base.defaultTabInterval = ch * 4
        base.lineBreakMode = .byWordWrapping
        let out = NSMutableAttributedString(string: s, attributes: [
            .font: font, .foregroundColor: NSColor.labelColor, .paragraphStyle: base,
        ])
        var styles: [Int: NSParagraphStyle] = [:]
        var loc = 0
        for line in s.split(separator: "\n", omittingEmptySubsequences: false) {
            let len = (String(line) as NSString).length
            if let col = numberColumn(line) {
                let style = styles[col] ?? {
                    let p = base.mutableCopy() as! NSMutableParagraphStyle
                    let x = ceil(ch * CGFloat(col + 2))
                    p.tabStops = [NSTextTab(textAlignment: .left, location: x)]
                    p.headIndent = x
                    styles[col] = p
                    return p
                }()
                out.addAttribute(.paragraphStyle, value: style, range: NSRange(location: loc, length: len))
            }
            loc += len + 1
        }
        return out
    }
}
