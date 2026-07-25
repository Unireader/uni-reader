import SwiftUI

// MARK: - 页元胞（白纸底 + 基图 + 贴片 + 墨迹 + hover）

struct PageCellView: View {
    let size: CGSize
    let image: CGImage?
    let tile: PageTile?
    let paper: Color
    let strokes: [InkStroke]
    let live: InkStroke?
    let hover: HoverPoint?
    let inkScale: CGFloat   // = zoom：墨迹线宽随页缩放（fit 时与采集端观感一致）
    var selectionRects: [CGRect] = []      // 文字选择高亮（T1），归一化 0~1 左上原点
    var matchRects: [CGRect] = []          // 搜索命中高亮，归一化 0~1 左上原点（T2，全部命中，淡黄）
    var activeMatchRects: [CGRect] = []    // 当前命中（同上坐标，橙色强调）
    var highlights: [Highlight] = []       // 本页文字高亮（kind=3）：按各自颜色铺色，最底层
    var notes: [TextNote] = []             // 本页文字注解（kind=0）：荧光高亮 + 可点图钉
    var ocrBlocks: [TextRun] = []          // 调试/demo：OCR 识别块（逐块上色 + 序号），空=不显示
    var ocrGroups: [Int] = []              // 调试上色：非空=按分组同色(与 ocrBlocks 同序的分组 id) / 空=每块独立色
    var radial: RadialState? = nil         // 环形选笔盘（非空且属本页时在笔尖处画环）
    var pens: [PenPreset] = []             // 环形盘要显示的收藏笔列表
    var pressRing: PressRing? = nil        // 长按进度环（非空且属本页时在笔尖处画填充进度）
    var onOpenNote: (TextNote) -> Void = { _ in }

    var body: some View {
        ZStack(alignment: .topLeading) {
            paper                                        // 纪律 1：未出图 = 一张白纸，永不闪灰/黑
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: size.width, height: size.height)
            }
            if let tile {
                Image(decorative: tile.image, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: tile.normRect.width * size.width,
                           height: tile.normRect.height * size.height)
                    .offset(x: tile.normRect.minX * size.width,
                            y: tile.normRect.minY * size.height)
            }
            // 调试/demo：OCR 识别块可视化——按黄金角旋转色相上色 + 序号。
            //  · 每块独立：色相按行序（看清每一行框）；
            //  · 可选分组：色相按列/块分组 id（同一可选块同色，量化切分是否合理）。
            if !ocrBlocks.isEmpty {
                Canvas { ctx, sz in
                    let grouped = !ocrGroups.isEmpty
                    for (i, run) in ocrBlocks.enumerated() {
                        let px = CGRect(x: run.x * sz.width, y: run.y * sz.height,
                                        width: run.w * sz.width, height: run.h * sz.height)
                        let key = grouped ? (ocrGroups.indices.contains(i) ? ocrGroups[i] : i) : i
                        let hue = (Double(key) * 0.61803398875).truncatingRemainder(dividingBy: 1)
                        let c = Color(hue: hue, saturation: 0.8, brightness: 0.95)
                        let path = Path(roundedRect: px, cornerRadius: 2)
                        ctx.fill(path, with: .color(c.opacity(0.28)))
                        ctx.stroke(path, with: .color(c), lineWidth: 1)
                        ctx.draw(Text("\(key)").font(.system(size: 9, weight: .bold)).foregroundColor(c),
                                 at: CGPoint(x: px.minX + 2, y: px.minY + 1), anchor: .topLeading)
                    }
                }
                .allowsHitTesting(false)
            }
            // 文字高亮（kind=3，最底层）：每条按自己的颜色铺在选中文字上。
            if !highlights.isEmpty {
                Canvas { ctx, sz in
                    for h in highlights {
                        let col = Color(nsColor: h.color.nsColor).opacity(Highlight.fillOpacity)
                        for r in h.rects { fillNorm(r, in: &ctx, size: sz, color: col) }
                    }
                }
                .allowsHitTesting(false)
            }
            // 文字注解荧光高亮（持久层，居搜索/选择高亮之下）：被注解的文字铺一层暖黄。
            if !notes.isEmpty {
                Canvas { ctx, sz in
                    for n in notes {
                        for r in n.rects { fillNorm(r, in: &ctx, size: sz, color: Self.noteHighlight) }
                    }
                }
                .allowsHitTesting(false)
            }
            if !matchRects.isEmpty || !activeMatchRects.isEmpty {
                Canvas { ctx, sz in
                    for r in matchRects { fillNorm(r, in: &ctx, size: sz, color: .yellow.opacity(0.35)) }
                    for r in activeMatchRects { fillNorm(r, in: &ctx, size: sz, color: .orange.opacity(0.55)) }
                }
                .allowsHitTesting(false)
            }
            if !selectionRects.isEmpty {
                Canvas { ctx, sz in
                    for r in selectionRects { fillNorm(r, in: &ctx, size: sz, color: .accentColor.opacity(0.35)) }
                }
                .allowsHitTesting(false)
            }
            if !strokes.isEmpty {
                InkStaticLayer(strokes: strokes, inkScale: inkScale)
            }
            if let live {
                InkLiveLayer(live: live, inkScale: inkScale)
            }
            // 批注图钉（可点）：点开编辑器查看/编辑。悬停显示批注/原文预览。
            ForEach(notes) { n in
                Button { onOpenNote(n) } label: {
                    Image(systemName: "note.text")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.black.opacity(0.75))
                        .padding(3)
                        .background(Self.noteMarker, in: Circle())
                        .overlay(Circle().stroke(.black.opacity(0.15), lineWidth: 0.5))
                }
                .buttonStyle(.plain)
                .help(n.text.isEmpty ? n.quote : n.text)
                .position(markerPos(n, size: size))
            }
            // 平板笔尖光标（页锚定，纯位置指示）：压在墨迹/图钉之上、随页滚动。仅显示、不挡点击。
            if let hover {
                Circle()
                    .stroke(Color.accentColor, lineWidth: 2)
                    .frame(width: 10, height: 10)
                    .position(x: hover.nx * size.width, y: hover.ny * size.height)
                    .allowsHitTesting(false)
            }
            // 长按进度环（笔尖处）：300ms 起显示、1s 填满，随后 fireLongPress 展开成 radial。
            if let pressRing {
                TimelineView(.animation) { tl in
                    let p = min(1, max(0, (tl.date.timeIntervalSince(pressRing.start) - 0.3) / 0.7))
                    ZStack {
                        Circle().stroke(.white.opacity(0.25), lineWidth: 3)                    // 轨道
                        Circle().trim(from: 0, to: p)                                          // 填充进度
                            .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                    }
                    .frame(width: 30, height: 30)
                    .opacity(p > 0.001 ? 1 : 0)
                    .position(x: pressRing.nx * size.width, y: pressRing.ny * size.height)
                }
                .allowsHitTesting(false)
            }
            // 环形选笔盘（长按呼出，最顶层、页锚定于笔尖处）。
            if let radial {
                RadialMenuView(radial: radial, pens: pens, size: size)
            }
        }
        .frame(width: size.width, height: size.height)
    }

    private static let noteHighlight = Color(red: 1, green: 0.82, blue: 0.15).opacity(0.32)
    private static let noteMarker = Color(red: 1, green: 0.80, blue: 0.15)

    /// 图钉落位：选区注解落在末端右侧（不遮文字起点）；点注解（无行框）落在锚点处。钳制在页内。
    private func markerPos(_ n: TextNote, size: CGSize) -> CGPoint {
        let x = n.rects.isEmpty ? n.anchor.minX * size.width : n.anchor.maxX * size.width + 9
        let y = n.rects.isEmpty ? n.anchor.minY * size.height : n.anchor.minY * size.height + 7
        return CGPoint(x: min(max(x, 12), size.width - 12),
                       y: min(max(y, 10), size.height - 10))
    }

    /// 归一化矩形（0~1，左上原点）→ 页内像素矩形并填充（文字选择/搜索命中高亮共用）。
    private func fillNorm(_ r: CGRect, in ctx: inout GraphicsContext, size: CGSize, color: Color) {
        let px = CGRect(x: r.minX * size.width, y: r.minY * size.height,
                        width: r.width * size.width, height: r.height * size.height)
        ctx.fill(Path(roundedRect: px.insetBy(dx: -1, dy: -0.5), cornerRadius: 2), with: .color(color))
    }
}
