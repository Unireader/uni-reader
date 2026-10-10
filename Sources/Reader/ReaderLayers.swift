import AppKit
import QuartzCore

// MARK: - 零闪烁纪律：阅读区的图层一律没有隐式动画

/// 阅读区所有图层的基类：`action(forKey:)` 恒为 nil = **没有任何隐式动画**（换图、改 frame、改透明度都是瞬时的）。
/// 对应 SwiftUI 版的「零闪烁纪律 4：阅读区无隐式动画」（`PDF-VIEWER-REBUILD-PLAN.md` §3）。
/// 比每次包 `CATransaction.setDisableActions(true)` 更稳：哪条代码路径改了图层都不会漏。
class QuietLayer: CALayer {
    override func action(forKey event: String) -> CAAction? { nil }

    override init() {
        super.init()
        // 只按需重画（换数据 / 换清晰度时显式 setNeedsDisplay），bounds 变了只拉伸已有内容
        needsDisplayOnBoundsChange = false
    }
    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { fatalError("init(coder:) 不支持") }

    /// `draw(in:)` 里统一用「左上原点、y 向下」画（与 SwiftUI 版、页内归一化坐标一致）。
    /// 挂在 flipped 视图下的图层，Core Animation 已经给了 y 向下的上下文（`contentsAreFlipped()` 为真）；
    /// 万一不是（比如被挂到别处），这里补翻一次，保证两种情况画出来都一样。
    func yDown(_ ctx: CGContext) {
        guard !contentsAreFlipped() else { return }
        ctx.translateBy(x: 0, y: bounds.height)
        ctx.scaleBy(x: 1, y: -1)
    }
}

// MARK: - 笔迹层

/// 一页的笔迹（已落的一批，或正在写的那一笔）。在**文档坐标**里按 fit 页宽画——缩放由滚动视图整体放大，
/// 缩放过程中只拉伸这张位图、一笔都不重画（SwiftUI 版为此专门做过「位图快照」，这里是天然的）；
/// 缩放停下后 `contentsScale` 换成新倍率再画一次，由糊变清（用户认可的「先糊一点，然后再更新」）。
///
/// 画板模式：图层比页宽两侧各多 `margin`，页的左边缘落在 x = margin（跨页边的一笔整条画在同一层）。
final class PageInkLayer: QuietLayer {
    var strokes: [InkStroke] = []
    var margin: CGFloat = 0
    /// 缩放 / 平板拖动中的快速描边（整页分组绘制）。只有「正在写的那一笔」之外的场合才可能用到，
    /// 默认关：AppKit 版缩放时不重画，快速路径主要留给以后的实时路径。
    var fast = false
    /// 这层的内容该是哪个清晰度：已经画好的，或后台正在画的（`contentsScale` 要等图落位才换）。
    private(set) var targetScale: CGFloat = 1
    private var pending: Operation?

    /// 笔迹后台出图的队列（两路并行：一页最多约 64MB，别让好几页同时攥着）。
    private static let renderQueue: OperationQueue = {
        let q = OperationQueue()
        q.name = "PageInkLayer.render"
        q.maxConcurrentOperationCount = 2
        q.qualityOfService = .userInitiated
        return q
    }()

    override func draw(in ctx: CGContext) {
        guard !strokes.isEmpty else { return }
        yDown(ctx)
        Self.paint(strokes, in: ctx, size: bounds.size, margin: margin, fast: fast)
    }

    /// 当场重画（下一次提交时画）：落笔、擦除、换页这些要立刻看到的。
    func redraw(scale: CGFloat) {
        targetScale = scale
        if abs(contentsScale - scale) > 0.01 { contentsScale = scale }
        setNeedsDisplay()
    }

    /// 没有笔迹了：后台在画的作废，不留位图（别走 `setNeedsDisplay`，那会分配一整页的空白位图）。
    func clear(scale: CGFloat) {
        pending?.cancel()
        pending = nil
        targetScale = scale
        if abs(contentsScale - scale) > 0.01 { contentsScale = scale }
        contents = nil
    }

    /// 在后台按 `scale` 画好再换上，画好之前屏幕上留着原来那张（拉伸着，只替换不清空）。
    /// 为什么：缩放停下后每页都要按新倍率重画一遍，一页几百万像素、在主线程上画会卡住好几百毫秒
    /// （2026-10-07 采样实测，点一下放大 / 缩小就掉一串帧）。图回来时笔迹 / 尺寸 / 页边变了就扔掉。
    func redrawInBackground(scale: CGFloat) {
        pending?.cancel()
        targetScale = scale
        let strokes = self.strokes, size = bounds.size, margin = self.margin, fast = self.fast
        let op = BlockOperation()
        op.addExecutionBlock { [weak self, weak op] in
            guard let op, !op.isCancelled else { return }
            let img = Self.renderImage(strokes, size: size, margin: margin, scale: scale, fast: fast)
            DispatchQueue.main.async {
                guard let self, !op.isCancelled, self.pending === op else { return }
                self.pending = nil
                guard let img, self.strokes == strokes, self.bounds.size == size, self.margin == margin else { return }
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                self.contentsScale = scale
                self.contents = img
                CATransaction.commit()
            }
        }
        pending = op
        Self.renderQueue.addOperation(op)
    }

    /// 当场重画盖过还在后台画的那张（不然它晚到会把新内容换回旧的）。
    override func setNeedsDisplay() {
        pending?.cancel()
        pending = nil
        targetScale = contentsScale
        super.setNeedsDisplay()
    }

    /// 一页笔迹画进上下文（左上原点、y 向下，单位 = 文档点）。`draw(in:)` 与后台出图共用这一份。
    private static func paint(_ strokes: [InkStroke], in ctx: CGContext, size: CGSize, margin: CGFloat, fast: Bool) {
        let pw = size.width - margin * 2, ph = size.height
        guard pw > 1, ph > 1 else { return }
        let map: (InkPoint) -> CGPoint = {
            CGPoint(x: CGFloat($0.x) * pw + margin, y: CGFloat($0.y) * ph)
        }
        // 线宽基准：fit 页宽下与采集端一致（SwiftUI 版 `inkScale = zoom`，页宽 = fitBasis × zoom；
        // 这里整层在 fit 宽下画、由滚动视图放大 zoom 倍，所以传 1）
        if fast {
            InkRenderCG.drawStrokesFast(strokes, in: ctx, inkScale: 1, map: map)
        } else {
            for st in strokes { InkRenderCG.drawStroke(st, in: ctx, inkScale: 1, map: map) }
        }
    }

    /// 后台出图：与 `draw(in:)` 同一份画法，位图 = 图层尺寸 × `scale`，sRGB（同窗口色彩空间，红线 5）。
    private static func renderImage(_ strokes: [InkStroke], size: CGSize, margin: CGFloat,
                                    scale: CGFloat, fast: Bool) -> CGImage? {
        let w = Int((size.width * scale).rounded(.up)), h = Int((size.height * scale).rounded(.up))
        guard !strokes.isEmpty, w > 0, h > 0,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                      | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: scale, y: -scale)
        paint(strokes, in: ctx, size: size, margin: margin, fast: fast)
        return ctx.makeImage()
    }
}

// MARK: - 一页

/// 一页的图层组（帧 = 页在文档坐标里的矩形，**不含**画板页边）。从下到上：
/// 纸（含页边）→ 整页基图 → 高倍清晰贴片 → 标记层（高亮 / 批注 / 搜索命中 / 选区，第 2 步）→ 笔迹 → 正在写的一笔。
/// 图钉 / 气泡要接鼠标，是 NSView，不在这里（第 2 步）。
final class PageLayerGroup: QuietLayer {
    let paper = QuietLayer()
    let image = QuietLayer()
    let tile = QuietLayer()
    /// 标记层：高亮 / 批注标记 / 搜索命中 / 选区（`PageMarksLayer`）。
    let marks = PageMarksLayer()
    let ink = PageInkLayer()
    let live = PageInkLayer()

    /// 这一组当前服务的页号（复用池里取出来时改）。
    var pageIndex = -1
    /// 挂着的贴片的归一化矩形（与贴片图同生死；判断「已是这块」用）。
    var tileNorm: CGRect?

    override init() {
        super.init()
        masksToBounds = false          // 画板页边的纸与笔迹要伸出页外
        for l in [paper, image, tile, marks, ink, live] { addSublayer(l) }
        image.contentsGravity = .resize
        tile.contentsGravity = .resize
        // 缩小时用三线性 + mipmap 避免密集文字页出现噪点（同 SwiftUI 版不许用 `.low` 那条教训）
        image.minificationFilter = .trilinear
        image.magnificationFilter = .linear
        tile.minificationFilter = .trilinear
        ink.contentsGravity = .resize
        live.contentsGravity = .resize
    }
    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { fatalError("init(coder:) 不支持") }

    /// 摆放：页矩形（文档坐标）+ 画板页边宽（文档坐标，每侧）。子层全部相对本组。
    func place(frame f: CGRect, margin: CGFloat) {
        frame = f
        let local = CGRect(origin: .zero, size: f.size)
        let wide = local.insetBy(dx: -margin, dy: 0)
        paper.frame = wide
        image.frame = local
        if marks.frame != local {
            marks.frame = local
            if !marks.isEmpty { marks.setNeedsDisplay() }
        }
        if ink.frame != wide || ink.margin != margin {
            ink.frame = wide
            ink.margin = margin
            // 复用池刚取出来的组笔迹是空的：别在这里要求当场画，内容交给随后的 `configureInkLayer`
            // （缩放中它走后台出图；这里一标记，下次提交照样当场画一遍）
            if !ink.strokes.isEmpty { ink.setNeedsDisplay() }
        }
        live.frame = wide
        live.margin = margin
        if let n = tileNorm { placeTile(n) }
    }

    func placeTile(_ n: CGRect) {
        let s = bounds.size
        tile.frame = CGRect(x: n.minX * s.width, y: n.minY * s.height,
                            width: n.width * s.width, height: n.height * s.height)
    }

    func setTile(_ norm: CGRect?, image img: CGImage?) {
        tileNorm = img == nil ? nil : norm
        tile.contents = img
        if let norm, img != nil { placeTile(norm) }
    }

    /// 回收进复用池前清干净（图不留引用，免得攥着页图不放）。
    func reset() {
        image.contents = nil
        setTile(nil, image: nil)
        ink.strokes = []
        ink.clear(scale: ink.contentsScale)   // 连同后台还在画的那张一起作废
        live.strokes = []
        live.contents = nil
        marks.contents = nil
        marks.marks = []
        marks.matchRects = []
        marks.activeMatchRects = []
        marks.selectionRects = []
        marks.ocrBlocks = []
        marks.ocrGroups = []
        marks.ocrWatermarks = []
        pageIndex = -1
    }
}

/// 形状图层同样不许有隐式动画（改 path / 位置都瞬时生效）。覆盖层上的框选路径、选中框、橡皮圈都用它。
final class QuietShapeLayer: CAShapeLayer {
    override func action(forKey event: String) -> CAAction? { nil }
}
