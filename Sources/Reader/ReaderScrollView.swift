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
