import SwiftUI

/// 书签缎带：贴页右缘的一面小旗，右端切一个 V 口（真书里夹出来的那条丝带的样子）。
/// 扁平纯色 + 0.5 描边，无渐变/高光/投影（红线）。形状本身就是"这是书签"的信号，
/// 于是与另外两种**圆形**图钉（文字注解 / 草稿纸）一眼分得开——不必靠颜色去记。
struct BookmarkRibbon: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        let notch: CGFloat = 5
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX - notch, y: r.midY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX, y: r.maxY))
        p.closeSubpath()
        return p
    }
}

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
    var noteTypes: [NoteType] = []         // 工作区笔记类型：图钉/高亮配色（通用保持既有黄色样式）
    var ocrBlocks: [TextRun] = []          // 调试/demo：OCR 识别块（逐块上色 + 序号），空=不显示
    var ocrGroups: [Int] = []              // 调试上色：非空=按分组同色(与 ocrBlocks 同序的分组 id) / 空=每块独立色
    var radial: RadialState? = nil         // 环形选笔盘（非空且属本页时在笔尖处画环）
    var pens: [PenPreset] = []             // 环形盘要显示的收藏笔列表
    var pressRing: PressRing? = nil        // 长按进度环（非空且属本页时在笔尖处画填充进度）
    var hoverD: CGFloat = 10               // 平板笔尖光标直径（erase 模式+圆环开 = 橡皮直径 2×eraserRadius×页宽）
    var onOpenNote: (TextNote) -> Void = { _ in }
    var expandedNotes: Set<UUID> = []      // 点开着的 tap 模式笔记（瞬态、不落库；见 NoteDisplay）
    var hoverNote: UUID? = nil             // 指针正悬在哪枚图钉上（hover 模式的展开条件）
    var onToggleNote: (TextNote) -> Void = { _ in }        // 点图钉：tap 模式展开/收起气泡
    var onHoverNote: (UUID, Bool) -> Void = { _, _ in }    // 图钉悬停进出（hover 模式用）
    var noteDrag: (id: UUID, off: CGSize)? = nil   // 点注解拖拽 ghost（非空且 id 匹配时该图钉按 off 挪显示位）
    var scratchPins: [(id: UUID, nx: Double, ny: Double, name: String)] = []   // 本页的草稿纸图钉（点开那张纸）
    var onOpenScratchPad: (UUID) -> Void = { _ in }
    var bookmarks: [Bookmark] = []                         // 本页的书签（页右缘小旗标，点开改名/删除）
    var onRenameBookmark: (Bookmark) -> Void = { _ in }
    var onDeleteBookmark: (Bookmark) -> Void = { _ in }
    /// 画板模式（v12）的每侧页边宽度（像素，0 = 关）。纸面与墨迹层按它向两侧铺开，
    /// 其余各层（页图/高亮/选择/图钉/光标）一律还是页内坐标——页边只是「同一页的横向延伸」。
    var inkMargin: CGFloat = 0
    /// 缩放进行中：墨迹走快速描边路径（见 `inkDrawStroke` 的 `fast`）。几何不变、只是接缝合成方式变，
    /// 收尾 `settleRender` 换回高质量重画一次。
    var inkFast: Bool = false
    /// 页号（仅 `ZoomProbe` 报"这一帧重绘了哪几页"用）。
    var pageIndex: Int = -1
    /// 缩放期间的墨迹位图快照（非 nil 即用它顶替墨迹 Canvas）。见 `ReaderSurface.makeInkSnapshots`。
    var inkSnapshot: CGImage? = nil

    /// 哪一枚书签旗标正开着 popover（瞬态，不落库）。
    @State private var openBookmark: UUID?

    var body: some View {
        ZStack(alignment: .topLeading) {
            // 纪律 1：未出图 = 一张白纸，永不闪灰/黑。画板模式下这张纸连同页边一起铺
            //（内层 frame 比页宽 2×margin，外层 frame 钳回页尺寸 → 居中溢出，不撑大 ZStack）。
            wide { paper }
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    // 缩放中降到 .medium：此刻显示的本来就是**旧宽度基图被拉伸**的糊图（新宽度的图
                    // 要等 settle 后才渲），再为它做高质量重采样纯属白付——一张 2800px 基图的 high
                    // 插值每帧每页要几毫秒，视口两页就吃掉大半个帧预算。settle 后自动换回 .high。
                    // 🔴 **不能用 `.low`**：最近邻式采样在缩小的文字页上会产生密集噪点，而页面尺寸
                    // 每帧微变、噪点图案跟着变 —— 看起来就是**整页在闪**（2026-08-29 用户报的"闪烁"，
                    // 我上一轮为省这几毫秒改的 `.low` 就是祸首）。`.medium` 是双线性，无噪点、也不贵。
                    .interpolation(inkFast ? .medium : .high)
                    .frame(width: size.width, height: size.height)
            }
            if let tile {
                Image(decorative: tile.image, scale: 1)
                    .resizable()
                    .interpolation(inkFast ? .medium : .high)
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
            // 文字注解荧光高亮（持久层，居搜索/选择高亮之下）：通用铺暖黄，自定义类型铺类型色。
            if !notes.isEmpty {
                Canvas { ctx, sz in
                    for n in notes {
                        let col = n.typeId == nil ? Self.noteHighlight
                            : NoteType.resolve(n.typeId, in: noteTypes).uiColor.opacity(0.32)
                        for r in n.rects { fillNorm(r, in: &ctx, size: sz, color: col) }
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
            if let inkSnapshot {
                // 缩放进行中：显示起手时渲好的墨迹位图，只做纹理拉伸——一笔都不重画，所以不会闪。
                // 拉伸会糊（用户拍板接受），settle 后 `inkSnaps` 清空即换回下面的矢量 Canvas。
                wide {
                    Image(decorative: inkSnapshot, scale: 1)
                        .resizable()
                        .interpolation(.medium)
                        .allowsHitTesting(false)
                }
            } else if !strokes.isEmpty {
                wide { InkStaticLayer(strokes: strokes, inkScale: inkScale, margin: inkMargin,
                                      fast: inkFast, pageIndex: pageIndex) }
            }
            if let live {
                wide { InkLiveLayer(live: live, inkScale: inkScale, margin: inkMargin, fast: inkFast) }
            }
            // 批注图钉（可点）：`tap` 模式点开/收起页面上的气泡，`hover`/`always` 模式点开编辑器
            // （那两种模式正文已经看得见，图钉的点击留给「改」）。空正文的选区注解没有可展开的东西，
            // 一律直接进编辑器。悬停在 hover 模式下展开气泡，其余模式仍是系统 tooltip。
            // 通用保持既有样式（note.text + 黄底）；自定义类型用类型图标 + 类型色底。
            // 点注解拖拽由容器手势（ReaderSurface.notePinDragGesture）驱动：原位 Button 不动只变淡，
            // 另画不响应命中的 ghost 跟手——若 Button 本体跟手，松手时光标仍在 Button 内会误触发开编辑器。
            ForEach(notes) { n in
                let typed = n.typeId != nil
                let t = NoteType.resolve(n.typeId, in: noteTypes)
                let pos = markerPos(n, size: size)
                let dragging = noteDrag?.id == n.id
                Button { expandable(n) ? onToggleNote(n) : onOpenNote(n) } label: {
                    notePin(typed: typed, t: t)
                }
                .buttonStyle(.plain)
                .help(n.display == .hover && !n.text.isEmpty ? "" : (n.text.isEmpty ? n.quote : n.text))
                .opacity(dragging ? 0.3 : 1)
                .position(pos)
                .onHover { onHoverNote(n.id, $0) }
                if dragging, let off = noteDrag?.off {
                    notePin(typed: typed, t: t)
                        .allowsHitTesting(false)
                        .position(x: pos.x + off.width, y: pos.y + off.height)
                }
            }
            // 展开的笔记气泡（压在图钉之上、光标/选笔盘之下）：每条笔记按自己的 `display` 决定显不显。
            // 拖拽中的那条不画——气泡跟不跟手都是错的（跟手＝一大块跟着晃，不跟＝指着旧位置）。
            ForEach(notes) { n in
                if bubbleVisible(n), noteDrag?.id != n.id {
                    NoteBubbleView(text: n.text, pageSize: size, pin: markerPos(n, size: size),
                                   pinRadius: Self.pinRadius,
                                   onEdit: n.display == .hover ? nil : { onOpenNote(n) })
                }
            }
            // 草稿纸图钉：标记「这张纸是在页面的哪儿建的」，点开对应草稿纸。与批注图钉同款钳制/样式约束
            // （扁平圆底 + SF Symbol，无渐变高光），只是换个图标与配色以便一眼分得清。
            ForEach(scratchPins, id: \.id) { pin in
                Button { onOpenScratchPad(pin.id) } label: {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.black.opacity(0.75))
                        .padding(3)
                        .background(Self.scratchMarker, in: Circle())
                        .overlay(Circle().stroke(.black.opacity(0.15), lineWidth: 0.5))
                }
                .buttonStyle(.plain)
                .help(pin.name)
                .position(x: min(max(pin.nx * size.width, 12), size.width - 12),
                          y: min(max(pin.ny * size.height, 10), size.height - 10))
            }
            // 书签旗标：贴**页右缘**、纵向落在书签自己的页内位置上（一页可多枚，所以不是页角）。
            // 与两种图钉同一套形制（扁平圆底 + SF Symbol + 0.5 描边，无渐变高光），只换图标与配色。
            // 点它出菜单：书签点开没有内容可展示（跳转从目录去），页面上这一枚的用处是
            // 「一眼看出这一处标过」+ 就地改名/取消。
            // 🔴 **别用 `Menu`**：它是 AppKit 托管控件，`spike/bookmark-flag-look.swift` 出的样张里
            // 同样的位置 Button 画得出来、Menu 只剩一个「不支持」的黄框。这里换成
            // Button + 原生 popover —— 与两种图钉同一种控件，渲染路径也就同一条。
            ForEach(bookmarks) { b in
                Button { openBookmark = (openBookmark == b.id ? nil : b.id) } label: {
                    BookmarkRibbon()
                        .fill(Self.bookmarkMarker)
                        .overlay(BookmarkRibbon().stroke(.black.opacity(0.18), lineWidth: 0.5))
                        .frame(width: Self.ribbonW, height: Self.ribbonH)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(b.title)
                .popover(isPresented: Binding(get: { openBookmark == b.id },
                                              set: { if !$0 { openBookmark = nil } }),
                         arrowEdge: .trailing) {
                    VStack(alignment: .leading, spacing: 8) {
                        // 红线：popover 是 material 底，文字一律显式 .primary，层级差异只用字号表达
                        Text(b.title).font(.callout.weight(.medium)).foregroundStyle(.primary).lineLimit(2)
                        Text(String(format: L("Page %d"), b.page + 1))
                            .font(.caption).foregroundStyle(.primary)
                        Divider()
                        Button(L("Rename…")) { openBookmark = nil; onRenameBookmark(b) }
                        Button(L("Delete"), role: .destructive) { openBookmark = nil; onDeleteBookmark(b) }
                    }
                    .padding(12)
                    .frame(minWidth: 160, alignment: .leading)
                }
                .position(x: size.width - Self.ribbonW / 2,
                          y: min(max(b.frac * size.height, Self.ribbonH), size.height - Self.ribbonH))
            }
            // 平板笔尖光标（页锚定，纯位置指示）：压在墨迹/图钉之上、随页滚动。仅显示、不挡点击。
            // erase 模式且尺寸圆环开时直径 = 橡皮直径（hoverD 由调用方按 eraserRadius × 页宽换算传入）。
            if let hover {
                Circle()
                    .stroke(Color.accentColor, lineWidth: 2)
                    .frame(width: hoverD, height: hoverD)
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

    /// 画板模式下「铺到页边」的那两层（纸面、墨迹）：内层 frame 比页宽 `2×inkMargin`，
    /// 外层再把**布局尺寸**钳回页尺寸——SwiftUI 的 frame 只定布局不裁剪，内层于是居中溢出、
    /// 左右各露出 `inkMargin`，同时 ZStack 的尺寸半点不变（其余各层的页内坐标一律不受影响）。
    /// `inkMargin == 0` 时两层 frame 同尺寸 = 与画板模式之前逐像素同渲染。
    @ViewBuilder
    private func wide<V: View>(@ViewBuilder _ content: () -> V) -> some View {
        if inkMargin > 0 {
            content()
                .frame(width: size.width + inkMargin * 2, height: size.height)
                .frame(width: size.width, height: size.height)
        } else {
            // 画板模式关着时两层 frame 完全相同 = 纯冗余，而 Canvas 每多套一层就多被测/画一遍
            // （真机实测：一次 body 求值里同一页墨迹被画 1.6~2 次）。这里直接给原样。
            content().frame(width: size.width, height: size.height)
        }
    }

    private static let noteHighlight = Color(red: 1, green: 0.82, blue: 0.15).opacity(0.32)
    private static let noteMarker = Color(red: 1, green: 0.80, blue: 0.15)
    private static let scratchMarker = Color(red: 0.62, green: 0.83, blue: 0.98)
    /// 书签缎带的红与尺寸。**红色是书签的通用色**——2026-09-02 第一版用的暖橘，用户实测
    /// 「颜色还是橘色的说实话没有反应过来」；配上缎带这个形状，与两种圆图钉也就一眼分得开了
    /// （样张 `spike/bookmark-flag-look.swift`）。
    private static let bookmarkMarker = Color(red: 0.84, green: 0.23, blue: 0.24)
    private static let ribbonW: CGFloat = 26
    private static let ribbonH: CGFloat = 15

    /// 图钉半径（`notePin` 的实际外圆：11pt 图标 + 3pt 内边距），气泡避让用。
    static let pinRadius: CGFloat = 9

    /// 点图钉是「展开/收起」还是「进编辑器」：只有 tap 模式且有正文才是前者。
    private func expandable(_ n: TextNote) -> Bool { n.display == .tap && !n.text.isEmpty }

    /// 这条笔记此刻要不要画气泡（空正文没有可展开的东西，任何模式都不画）。
    private func bubbleVisible(_ n: TextNote) -> Bool {
        guard !n.text.isEmpty else { return false }
        switch n.display {
        case .always: return true
        case .tap: return expandedNotes.contains(n.id)
        case .hover: return hoverNote == n.id
        }
    }

    /// 图钉落位：选区注解落在末端右侧（不遮文字起点）；点注解（无行框）落在锚点处。钳制在页内。
    private func markerPos(_ n: TextNote, size: CGSize) -> CGPoint {
        let x = n.rects.isEmpty ? n.anchor.minX * size.width : n.anchor.maxX * size.width + 9
        let y = n.rects.isEmpty ? n.anchor.minY * size.height : n.anchor.minY * size.height + 7
        return CGPoint(x: min(max(x, 12), size.width - 12),
                       y: min(max(y, 10), size.height - 10))
    }

    /// 图钉外观（原位 Button 与拖拽 ghost 共用）。
    private func notePin(typed: Bool, t: NoteType) -> some View {
        Image(systemName: typed ? t.icon : "note.text")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.black.opacity(0.75))
            .padding(3)
            .background(typed ? t.uiColor : Self.noteMarker, in: Circle())
            .overlay(Circle().stroke(.black.opacity(0.15), lineWidth: 0.5))
    }

    /// 归一化矩形（0~1，左上原点）→ 页内像素矩形并填充（文字选择/搜索命中高亮共用）。
    private func fillNorm(_ r: CGRect, in ctx: inout GraphicsContext, size: CGSize, color: Color) {
        let px = CGRect(x: r.minX * size.width, y: r.minY * size.height,
                        width: r.width * size.width, height: r.height * size.height)
        ctx.fill(Path(roundedRect: px.insetBy(dx: -1, dy: -0.5), cornerRadius: 2), with: .color(color))
    }
}
