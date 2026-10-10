import AppKit

/// 对话记录条目里的一行小件（状态图标 + 工具名、折叠箭头 + 表头）：从左往右排、竖直居中、行高取最高那个；
/// 放不下时最后一个收窄（工具名按中间省略截断）。摆法对齐横排 `NSStackView` 的默认（`.centerY`、按对齐矩形算间距）。
///
/// 🔴 **自己按 frame 摆、不进约束引擎，对外只报固有尺寸**（2026-10-10 采样 + 离屏实测）：整个窗口共用一个约束引擎，
/// 对话记录里每个条目的约束都在里面，条目一多，每来一条新条目要重新求解的规模跟着涨。原来一条工具调用套三层
/// `NSStackView`，仿真 200 条时追加一条要 600ms 上下，Agent 记笔记时连着来就是整窗卡住；
/// 换成「拍平但仍用约束」只快了不到一倍，非得让行里的小件彻底不进引擎才行。离屏验证 `spike/agent-flat-row-test.swift`。
/// 只适合内容建好就不变的行（工具调用状态变了是整条重建的）；子视图换了内容要自己 `invalidateIntrinsicContentSize()`。
final class AgentRowView: NSView {
    private let views: [NSView]
    private let spacing: CGFloat

    init(_ views: [NSView], spacing: CGFloat) {
        self.views = views
        self.spacing = spacing
        super.init(frame: .zero)
        for v in views {
            v.translatesAutoresizingMaskIntoConstraints = true
            addSubview(v)
        }
        // 窄过内容时可以压（最后一个收窄截断），别反过来把外面撑宽
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) 不支持") }

    override var isFlipped: Bool { true }

    /// 子视图的对齐矩形尺寸（`intrinsicContentSize` 本来就按对齐矩形算；没有固有尺寸的那一维算 0）。
    private func size(_ v: NSView) -> NSSize {
        let s = v.intrinsicContentSize
        return NSSize(width: s.width == NSView.noIntrinsicMetric ? 0 : s.width,
                      height: s.height == NSView.noIntrinsicMetric ? 0 : s.height)
    }

    override var intrinsicContentSize: NSSize {
        let sizes = views.map(size)
        return NSSize(width: sizes.reduce(0) { $0 + $1.width } + spacing * CGFloat(max(0, views.count - 1)),
                      height: sizes.map(\.height).max() ?? 0)
    }

    /// 套在另一行里时 frame 是外面那行直接设的，不走约束：尺寸变了得自己要求重摆。
    override func setFrameSize(_ newSize: NSSize) {
        let changed = newSize != frame.size
        super.setFrameSize(newSize)
        if changed { needsLayout = true }
    }

    override func layout() {
        super.layout()
        var x: CGFloat = 0
        for (k, v) in views.enumerated() {
            let s = size(v)
            let w = k == views.count - 1 ? max(0, min(s.width, bounds.width - x)) : s.width
            v.frame = v.frame(forAlignmentRect: NSRect(x: x, y: (bounds.height - s.height) / 2, width: w, height: s.height))
            x += w + spacing
        }
    }
}
