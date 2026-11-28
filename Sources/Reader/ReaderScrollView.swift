import AppKit

/// 阅读区的 clip view：**内容比可见区窄时水平居中**（缩小到 fit 以下、或画板页边之外还有余量时）。
///
/// NSClipView 默认把窄内容贴左。居中必须在这里做（`constrainBoundsRect`），而不是改文档视图的宽度：
/// 捏合缩放过程中系统逐帧改放大倍率，文档宽跟着倍率变会和系统的锚点计算打架（松手那一下跳）。
///
/// 可见区要扣掉左右的 `contentInsets`（右侧 = 内置 AI 面板盖住的宽度）：居中是在面板左边那块里居中。
/// 🔴 **clip view 自己的 `contentInsets` 已经是文档坐标**（滚动视图设 443 点、倍率 0.25 时这里读到 1772，离屏实测），
/// 不要再除以倍率——曾经多除一次，缩小到 fit 以下时可用宽算成负数、居中永远不生效，页面贴在最左边（2026-09-19 用户报）。
final class ReaderClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var r = super.constrainBoundsRect(proposedBounds)
        guard let doc = documentView else { return r }
        let left = contentInsets.left, right = contentInsets.right
        let avail = r.width - left - right
        let docW = doc.frame.width
        if docW < avail {
            r.origin.x = doc.frame.minX - left - (avail - docW) / 2
        }
        return r
    }
}

/// 阅读区的滚动视图。缩放用系统自带的 `magnification`（捏合的锚点、惯性由系统做，与 Preview 同一套）；
/// 这里只补两件系统不做的：⌘+滚轮缩放（光标为锚），以及把这些事件交给 `ReaderView` 的钩子。
final class ReaderScrollView: NSScrollView {
    /// ⌘+滚轮：(倍率系数, 光标在文档坐标里的点)。返回 true = 已处理（吞掉，不再滚动）。
    var onCommandWheel: ((CGFloat, NSPoint) -> Bool)?
    /// 普通滚轮在交给系统之前先问一句（笔记卡片滚到头要吞掉等，第 2 步）。返回 true = 吞掉。
    var shouldSwallowWheel: ((NSEvent) -> Bool)?

    /// 图钉 / 笔记卡片的宿主（`ReaderOverlayView.floatHost`）：始终排在 clip view **正上方**、系统的工具栏边缘效果
    /// （`NSScrollPocket`，Tahoe 起是滚动视图的私有子视图）之下，卡片因此和页面一样在玻璃后面透出来、被模糊盖住。
    /// 不在 clip view 里放，是因为那里会跟着放大倍率一起缩放（卡片要屏幕上固定大小）。
    /// pocket 是滚动视图第一次布局时才补进来的（换滚动条等时还会再加子视图），而 NSScrollView 每加一个子视图
    /// 都按自己的规则重排一遍：认识的排好、不认识的（宿主）甩到最上面，压在 pocket 之上。
    /// 离屏实测 2026-11-28：在 `addSubview` / `didAddSubview` 里**当场**纠正会被它随后的重排盖掉，
    /// 所以排到主队列下一轮再纠正；纠正之后滚动 / 缩放 / tile / 改窗口大小都不会再动它。
    var floatHost: NSView? {
        didSet {
            oldValue?.removeFromSuperview()
            if let h = floatHost { addSubview(h) }
        }
    }
    private var floatHostCheckQueued = false

    override func didAddSubview(_ subview: NSView) {
        super.didAddSubview(subview)
        guard floatHost != nil, !floatHostCheckQueued else { return }
        floatHostCheckQueued = true
        DispatchQueue.main.async { [weak self] in
            self?.floatHostCheckQueued = false
            self?.keepFloatHostAboveClip()
        }
    }

    /// 宿主不在 clip view 正上方时，原地重排子视图数组（给 `subviews` 赋值是纯重排，不会把视图摘下再装回）。
    private func keepFloatHostAboveClip() {
        guard let h = floatHost, h.superview === self,
              let ci = subviews.firstIndex(where: { $0 === contentView }) else { return }
        if ci + 1 < subviews.count, subviews[ci + 1] === h { return }
        var list = subviews.filter { $0 !== h }
        let at = (list.firstIndex(where: { $0 === contentView }) ?? list.count - 1) + 1
        list.insert(h, at: at)
        subviews = list
    }

    override func scrollWheel(with event: NSEvent) {
        if event.modifierFlags.contains(.command), event.momentumPhase == [] {
            var delta = event.scrollingDeltaY
            if !event.hasPreciseScrollingDeltas { delta *= 10 }   // 有级滚轮（行单位）放大到像素量级
            if delta != 0, let doc = documentView {
                // 手感旋钮 0.008、系统缩放方向约定（负号）——与 SwiftUI 版同一组数
                let factor = min(max(exp(-delta * 0.008), 0.5), 2)
                let p = doc.convert(event.locationInWindow, from: nil)
                if onCommandWheel?(factor, p) == true { return }
            } else if delta == 0 {
                return
            }
        }
        if shouldSwallowWheel?(event) == true { return }
        super.scrollWheel(with: event)
    }
}

/// 放页面的文档视图：flipped（左上原点，与页内归一化坐标、PageLayout 的 docY 同向），layer-backed。
/// 页面内容全是 CALayer（`PageLayerGroup`），本视图不写 `draw(_:)`——滚动 / 缩放时 AppKit 不会逐帧重画它。
final class ReaderDocumentView: NSView {
    /// 鼠标与右键菜单全部交给阅读区处理（按指针工具分派，见 `ReaderView+Input`）。
    weak var host: ReaderView?

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override var wantsUpdateLayer: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) 不支持") }

    override func updateLayer() {}

    override func mouseDown(with event: NSEvent) { host?.readerMouseDown(event) }
    override func mouseDragged(with event: NSEvent) { host?.readerMouseDragged(event) }
    override func mouseUp(with event: NSEvent) { host?.readerMouseUp(event) }
    override func menu(for event: NSEvent) -> NSMenu? { host?.readerContextMenu(event) }
}
