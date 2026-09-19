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

    override func draw(in ctx: CGContext) {
        guard !strokes.isEmpty else { return }
        yDown(ctx)
        let pw = bounds.width - margin * 2, ph = bounds.height
        guard pw > 1, ph > 1 else { return }
        let map: (InkPoint) -> CGPoint = { [margin] in
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
}

// MARK: - 一页

/// 一页的图层组（帧 = 页在文档坐标里的矩形，**不含**画板页边）。从下到上：
/// 纸（含页边）→ 整页基图 → 高倍清晰贴片 → 标记层（高亮 / 批注 / 搜索命中 / 选区，第 2 步）→ 笔迹 → 正在写的一笔。
/// 图钉 / 气泡要接鼠标，是 NSView，不在这里（第 2 步）。
final class PageLayerGroup: QuietLayer {
    let paper = QuietLayer()
    let image = QuietLayer()
    let tile = QuietLayer()
    /// 标记层（第 2 步填内容）。先占好位置，层序就固定了。
    let marks = QuietLayer()
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
        marks.frame = local
        if ink.frame != wide || ink.margin != margin {
            ink.frame = wide
            ink.margin = margin
            ink.setNeedsDisplay()
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
        ink.contents = nil
        live.strokes = []
        live.contents = nil
        marks.contents = nil
        pageIndex = -1
    }
}
