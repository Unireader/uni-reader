import AppKit
import SwiftUI

// MARK: - 笔记展开气泡的尺寸口径（文字笔记 / 图片笔记共用）

/// 两种口径（用户 2026-09-13 定）：
///  · **固定尺寸**（默认）：宽/字号/内边距全是屏幕点，页面缩放时气泡纹丝不动，正文一律 12pt。
///  · **跟页缩放**（设置 → 阅读 →「笔记气泡跟随页面缩放」打开）：全部尺寸是**页宽的比例**，缩放页面时
///    气泡跟着一起缩——这是 2026-08-27 的原口径，比例常数仍是**三端契约**：
///    Mac `NoteBubble` / web `render.ts BUB` / 安卓 `NoteBubbleGeom` 各实现一份，改任一个必须同步另外两个。
///    折行由各端自己的排版引擎做，行末断点允许细微差异；**比例常数不许各写各的**。
///    （网页/安卓目前没有这个开关，恒跟页缩放。）
enum NoteBubble {
    // 跟页缩放模式的比例（三端契约）。2026-09-13 调小过一轮：字号 0.022→0.017、行高 1.35→1.25、
    // 内边距 0.55→0.30（用户：「字体太大显示不了几行、间隔也大、边太宽」）。
    static let widthRatio: CGFloat = 0.30      // 气泡宽 ÷ 页宽
    static let fontRatio: CGFloat = 0.017      // 正文字号 ÷ 页宽
    static let lineHeightRatio: CGFloat = 1.25 // 行高 ÷ 字号
    static let padRatio: CGFloat = 0.30        // 内边距 ÷ 字号
    static let radiusRatio: CGFloat = 0.4      // 圆角 ÷ 字号
    static let gapRatio: CGFloat = 0.25        // 图钉与气泡的间隙 ÷ 字号
    static let editRatio: CGFloat = 1.7        // 右上角编辑按钮的边长（= 热区）÷ 字号
    static let maxLines = 10                   // 超出即截断（全文去编辑器里看，别让一条笔记糊住半页）

    // 固定尺寸模式（默认，Mac 本机；屏幕点）。字号默认取系统 `.callout` 那档，设置里可改（`fontSizeKey`）；
    // 编辑按钮、行距按「字号 ÷ 12」等比跟着走；**宽度不跟字号**——它自己是设置项（最小/最大宽，
    // 短文按内容在两者之间收窄，见 `fitWidth`）；内边距/圆角/间隙不动（那几样是「边」，不该随字变粗）。
    static let fixedFont: CGFloat = 12
    static let fixedMinWidth: CGFloat = 120
    static let fixedMaxWidth: CGFloat = 280
    static let fixedLineHeightRatio: CGFloat = 1.25
    static let fixedPad: CGFloat = 5           // 「很窄的边」（用户）
    static let fixedRadius: CGFloat = 5
    static let fixedGap: CGFloat = 3
    static let fixedEdit: CGFloat = 20
    static let fixedMaxLines = 14
    /// 跟页缩放口径下宽度设置按哪个页宽折算：280 ÷ 0.30 ≈ 933pt（贴合宽度时两种口径一样宽，切换开关观感不跳）。
    static let refPageWidth: CGFloat = fixedMaxWidth / widthRatio

    /// 设置键：气泡要不要跟页缩放（默认关）。
    static let followsZoomKey = "noteBubbleFollowsZoom"
    /// 设置键：气泡正文字号（固定口径下就是这个数；跟页缩放口径下按「÷ 12」当倍率乘到字号比例上，
    /// 于是三端契约的比例常数本身不用动）。
    static let fontSizeKey = "noteBubbleFontSize"
    /// 设置键：气泡最小 / 最大宽度（pt；跟页缩放口径下按 `refPageWidth` 折算）。
    static let minWidthKey = "noteBubbleMinWidth"
    static let maxWidthKey = "noteBubbleMaxWidth"
    static let widthRange: ClosedRange<Int> = 80...800
    static let widthStep = 20
    /// 设置键：编辑框（`MarkdownNoteEditor`）正文字号。
    static let editorFontSizeKey = "noteEditorFontSize"
    static let defaultEditorFont: CGFloat = 13
    /// 设置里可选的字号档（气泡与编辑框共用一张表）。
    static let fontSizeChoices: [Int] = [10, 11, 12, 13, 14, 15, 16, 18, 20, 22, 24]

    // 配色：纸白底 + 发丝描边 + 深灰正文，**无投影/无渐变**（红线：不做拟物）。
    // 三端同值；夜间模式下平板只反转页图那一层，气泡照旧是浅底深字，可读。
    static let fill = Color(red: 1, green: 0.992, blue: 0.949).opacity(0.97)
    static let stroke = Color.black.opacity(0.18)
    static let ink = Color(red: 0.12, green: 0.12, blue: 0.13)
    static let editGlyph = Color.black.opacity(0.6)

    /// 一只气泡的全部尺寸（页内像素 = 屏幕点）。两种口径算出来的都是这一个东西，视图不必知道是哪种。
    struct Metrics: Equatable {
        var fs: CGFloat          // 正文字号
        var w: CGFloat           // 气泡**最大**宽（横图撑到这个宽；文字按内容在 minW…w 之间收窄，见 `fitWidth`）
        var minW: CGFloat        // 气泡最小宽
        var pad: CGFloat         // 内边距
        var radius: CGFloat
        var gap: CGFloat         // 图钉与气泡的间隙
        var edit: CGFloat        // 右上角编辑按钮边长
        var lineSpacing: CGFloat // 行与行之间额外的空隙（SwiftUI `lineSpacing` 的语义）
        var maxLines: Int
        /// 手动摆过的卡片（`NoteCard`）存的数 × unit = 页内像素：固定口径 1，跟页缩放口径 = 页宽 ÷ 参考页宽
        /// （与宽度设置同一个折算，切换口径时卡片与页面的相对大小不跳）。
        var unit: CGFloat = 1

        var font: NSFont { NSFont.systemFont(ofSize: fs) }
        /// 一行的高度（字体自带的行高，不含 lineSpacing）。
        var lineHeight: CGFloat {
            let f = font
            return (f.ascender - f.descender + f.leading).rounded(.up)
        }
        /// n 行正文占多高（含行间空隙）。
        func height(lines n: Int) -> CGFloat {
            guard n > 0 else { return 0 }
            return CGFloat(n) * lineHeight + CGFloat(n - 1) * lineSpacing
        }
    }

    /// `fontSize` / `minWidth` / `maxWidth` = 设置里的三个数（缺省 12 / 120 / 280）。
    static func metrics(pageWidth: CGFloat, followsZoom: Bool, fontSize: CGFloat = fixedFont,
                        minWidth: CGFloat = fixedMinWidth, maxWidth: CGFloat = fixedMaxWidth) -> Metrics {
        let k = max(0.5, fontSize / fixedFont)       // 相对默认字号的倍率（只作用在字号相关的量上）
        let lo = max(40, min(minWidth, maxWidth))
        let hi = max(lo, maxWidth)
        if followsZoom {
            let fs = max(1, pageWidth * fontRatio * k)
            let s = max(0.05, pageWidth / refPageWidth)   // 宽度设置按参考页宽折算，随页缩放
            return Metrics(fs: fs, w: max(1, hi * s), minW: max(1, lo * s), pad: fs * padRatio,
                           radius: fs * radiusRatio, gap: fs * gapRatio, edit: fs * editRatio,
                           lineSpacing: fs * (lineHeightRatio - 1), maxLines: maxLines, unit: s)
        }
        let fs = fixedFont * k
        return Metrics(fs: fs, w: hi, minW: lo, pad: fixedPad, radius: fixedRadius, gap: fixedGap,
                       edit: fixedEdit * k, lineSpacing: fs * (fixedLineHeightRatio - 1), maxLines: fixedMaxLines)
    }

    /// 文字气泡的宽：按内容最宽那一行（`NoteMarkdown.naturalWidth`，加 4% + 6pt 余量——那是估计值，
    /// 估窄了会多折一行）在 `minW…w` 之间收窄。短笔记从此不再一律满宽。
    static func fitWidth(_ text: String, m: Metrics, hasEdit: Bool) -> CGFloat {
        let content = NoteMarkdown.naturalWidth(text, font: m.font) * 1.04 + 6
        let need = content + m.pad * 2 + (hasEdit ? m.edit : 0)
        return min(max(need.rounded(.up), m.minW), m.w)
    }

    /// 正文高度的**估计值**（TextKit 同步量）：气泡正文由引擎只读渲染，真实高度要等它排完版报回来
    /// （`.fitsContent`），第一帧先按这个占位、把气泡钳进页内，下一帧对齐。量的是 Markdown 折算 + 字体特征
    /// 落实之后的那份（`NoteMarkdown.nsAttributed`），与引擎的排版八九不离十。
    /// 行间空隙（`paragraphStyle.lineSpacing`）也算进去。`maxLines` 缺省用口径里的；说明文字那种短的自己传。
    static func textHeight(_ text: String, width: CGFloat, m: Metrics, maxLines: Int? = nil) -> CGFloat {
        let attr = NoteMarkdown.nsAttributed(text, font: m.font, lineSpacing: m.lineSpacing)
        let box = attr.boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude),
                                    options: [.usesLineFragmentOrigin, .usesFontLeading])
        return min(max(m.lineHeight, box.height.rounded(.up)), m.height(lines: maxLines ?? m.maxLines))
    }

    // MARK: 手动摆过的卡片（`NoteCard`，Mac 本机；网页/安卓暂不认）

    /// 卡片最小尺寸（页内像素）：宽至少放得下几个字 + 编辑按钮，高至少一行。
    static func cardMinSize(_ m: Metrics) -> CGSize {
        CGSize(width: max(CGFloat(widthRange.lowerBound) * m.unit, m.edit + m.pad * 2 + m.fs * 3),
               height: m.lineHeight + m.pad * 2)
    }

    /// 摆过的卡片左上角：图钉中心 + 存的偏移，钳进页内（卡片画在本页元胞里，出了页就被下一页盖住）。
    static func cardOrigin(_ card: NoteCard, w: CGFloat, h: CGFloat, m: Metrics, pin: CGPoint,
                           pageSize: CGSize) -> CGPoint {
        let x = pin.x + CGFloat(card.dx) * m.unit, y = pin.y + CGFloat(card.dy) * m.unit
        return CGPoint(x: min(max(x, 0), max(0, pageSize.width - w)),
                       y: min(max(y, 0), max(0, pageSize.height - h)))
    }

    /// 图钉禁区半边长：图钉半径 + 图钉与气泡的间隙（自动规则贴在图钉旁边时正好留的就是这点空，见 `origin`）。
    static func pinClearance(_ m: Metrics, pinRadius: CGFloat) -> CGFloat { pinRadius + m.gap }

    /// 卡片最终落位：算好的左上角若让卡片压住自己的图钉，整块挪开（`NoteCardPin.pushOut`，用户 2026-09-16：
    /// 「不允许渲染窗覆盖自己的图钉」）。摆过的与自动的都过这一道——自动规则在页太窄、两边都放不下时钳进页内，也会压住图钉。
    static func placed(_ o: CGPoint, w: CGFloat, h: CGFloat, m: Metrics, pin: CGPoint, pinRadius: CGFloat,
                       pageSize: CGSize) -> CGPoint {
        NoteCardPin.pushOut(CGRect(origin: o, size: CGSize(width: w, height: h)),
                            keepOut: NoteCardPin.keepOut(pin: pin, clearance: pinClearance(m, pinRadius: pinRadius)),
                            page: pageSize).origin
    }

    /// 卡片宽：摆过宽用存的（不小于最小宽、不宽过页），否则用自动宽。
    static func cardWidth(_ card: NoteCard?, auto: CGFloat, m: Metrics, pageSize: CGSize) -> CGFloat {
        guard let w = card?.w else { return auto }
        return min(max(CGFloat(w) * m.unit, cardMinSize(m).width), max(cardMinSize(m).width, pageSize.width))
    }

    /// 气泡左上角（页内像素）：贴在图钉**右侧**、顶边与图钉顶对齐；右侧放不下翻到**左侧**；最后整体钳进页内。
    /// 文字气泡与图片气泡同一条规则（三端同款）。
    static func origin(w: CGFloat, h: CGFloat, m: Metrics, pin: CGPoint, pinRadius: CGFloat,
                       pageSize: CGSize) -> CGPoint {
        var x = pin.x + pinRadius + m.gap
        if x + w > pageSize.width { x = pin.x - pinRadius - m.gap - w }
        let y = pin.y - pinRadius
        return CGPoint(x: min(max(x, 0), max(0, pageSize.width - w)),
                       y: min(max(y, 0), max(0, pageSize.height - h)))
    }
}

// MARK: - 卡片的拖动 / 改大小 / 单击（文字笔记与图片笔记的气泡共用，2026-09-16）

extension NoteCardZone {
    /// 指针样子：边与角用系统的改大小箭头，其余地方是张开的手（拖动中握拳）。
    func pointerStyle(dragging: Bool) -> PointerStyle {
        switch self {
        case .move: return dragging ? .grabActive : .grabIdle
        case .top: return .frameResize(position: .top)
        case .bottom: return .frameResize(position: .bottom)
        case .leading: return .frameResize(position: .leading)
        case .trailing: return .frameResize(position: .trailing)
        case .topLeading: return .frameResize(position: .topLeading)
        case .topTrailing: return .frameResize(position: .topTrailing)
        case .bottomLeading: return .frameResize(position: .bottomLeading)
        case .bottomTrailing: return .frameResize(position: .bottomTrailing)
        }
    }
}

/// 卡片里的滚动**到头了也不许漏给页面**（用户 2026-09-16：「滚动区域即使到头了，也不滚动页面，避免意外滚动」）。
///
/// SwiftUI 的滚动容器没有「不向外传」的开关，嵌套时滚到头、或惯性余量都可能接着滚外面的阅读区。所以在阅读区的滚轮监视器里拦：
/// 指针下是**可滚动的卡片**、而卡片已经在这个方向上到头了，就把事件吞掉（返回 nil）。没到头照常放行，卡片自己滚。
/// 到没到头直接读卡片底下那个 AppKit 滚动视图的当前位置（同步、准确；SwiftUI 的滚动几何回调要晚一拍）。
enum NoteCardWheel {
    /// - Parameters:
    ///   - window: 事件所在窗口（正常就是 `event.window`；离屏验证时从 CGEvent 造的事件没有 window，由调用方给）。
    ///   - overCard: 指针此刻是否在某张卡片上（阅读区用 `cardHit` 判，避免把别处嵌套的滚动视图当成卡片）。
    static func shouldSwallow(_ e: NSEvent, in window: NSWindow?, overCard: Bool) -> Bool {
        let dx = e.scrollingDeltaX, dy = e.scrollingDeltaY
        guard overCard, dx != 0 || dy != 0,   // 触控板手势的开始 / 结束帧没有位移：放行，别打断滚动视图自己的手势跟踪
              let root = window?.contentView,
              let sv = nearestScrollView(root.hitTest(e.locationInWindow)),   // hitTest 要父视图坐标 = 窗口坐标
              sv.enclosingScrollView != nil,   // 嵌在阅读区里的那一层才是卡片的；阅读区自己那层外面没有滚动视图
              let doc = sv.documentView else { return false }
        let maxY = doc.frame.height - sv.contentView.bounds.height
        guard maxY > 0.5 else { return false }   // 放得下（禁用滚动）：不拦，滚轮照常滚页面
        let top = doc.isFlipped ? sv.contentView.bounds.minY : maxY - sv.contentView.bounds.minY   // 距顶端滚了多少
        if dy > 0 { return top <= 0.5 }            // 往上滚，已在顶
        if dy < 0 { return top >= maxY - 0.5 }     // 往下滚，已在底
        return true                                 // 纯横向：卡片不横滚，也别让页面横着动
    }

    private static func nearestScrollView(_ v: NSView?) -> NSScrollView? {
        var cur = v
        while let x = cur {
            if let sv = x as? NSScrollView { return sv }
            cur = x.superview
        }
        return nil
    }
}

/// 给一张卡片挂上拖动 / 改大小 / 单击。**卡片自己排版**（用 `live ?? 存着的卡片`），这里只管手势与指针样子。
///
///  · 手势坐标取页元胞的具名坐标系（`PageCellView.cardSpace`）：卡片拖动时自己在动，取卡片自己的坐标系位移会自激。
///  · 位移 ≤ 2pt 算单击（交给 `onClick`，卡片内坐标）；否则拖动中逐帧写 `live`，松手一次性 `onCommit`，同一拍清掉 `live`
///    （提交与清预览落在同一次刷新里，不会先弹回原位再跳过去）。
///  · 阅读区容器上挂的拖选 / 单击 / 双击选词 / 落墨 / 框选 / 图钉拖拽都是 simultaneous 手势，按下在卡片上它们照样会收到——
///    靠 `onFrame` 把卡片占的位置报给阅读区（`Scratch.cardFrames`），那边起手时 `cardHit` 命中就让位。
///    拖动中报的一直是**按下时**那块（见 `body` 里的注释），松手后补报。
///  · 移动 / 改大小都不许盖住自己的图钉（`NoteCardPin`，拖动数学里处理；画的时候 `NoteBubble.placed` 再兜一道）。
///  · `enabled == false`（悬停预览 / 非文字工具 / 草稿纸盖着）：不挂手势、不改指针，但位置照报（让位不看模式）。
struct NoteCardInteraction: ViewModifier {
    let enabled: Bool
    /// 此刻卡片在页上的样子（页内像素，已含拖动预览）。
    let frame: CGRect
    /// 内容全部露出要多高（含内边距；高度是上限，见 `NoteCard`）。
    let contentHeight: CGFloat
    /// 存着的卡片（不含预览）。
    let card: NoteCard?
    let metrics: NoteBubble.Metrics
    let pin: CGPoint
    let pinRadius: CGFloat
    let pageSize: CGSize
    @Binding var live: NoteCard?
    let onCommit: (NoteCard, NoteCardZone) -> Void
    let onClick: (CGPoint) -> Void
    let onFrame: (CGRect?) -> Void

    @State private var drag: NoteCardDrag?
    @State private var moved = false
    @State private var hoverZone: NoteCardZone = .move

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .onContinuousHover(coordinateSpace: .local) { phase in
                guard enabled, drag == nil, case .active(let p) = phase else { return }
                let z = NoteCardZone.at(p, size: frame.size)
                if z != hoverZone { hoverZone = z }   // 只在跨区时写：每次鼠标移动都写会带着正文引擎一起刷新
            }
            .pointerStyle(enabled ? (drag?.zone ?? hoverZone).pointerStyle(dragging: drag != nil) : nil)
            .gesture(dragGesture, including: enabled ? .all : .subviews)
            // 🔴 拖动中**不报**新位置，报的一直是按下时那块（松手后再补报一次）。容器的拖选等手势在「还没起手」时
            // 每个回调都拿按下点问 `cardHit`；报活位置的话，卡片跟着手走远了，按下点就落到卡片外面，
            // 拖选随即在底下起手（用户 2026-09-16 报「拖拽笔记的时候会触发文字选择」，合成事件复现过）。
            .onChange(of: frame, initial: true) { _, f in if drag == nil { onFrame(f) } }
            .onChange(of: drag == nil) { _, idle in if idle { onFrame(frame) } }
            .onDisappear { onFrame(nil) }
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(PageCellView.cardSpace))
            .onChanged { v in
                if drag == nil {
                    let local = CGPoint(x: v.startLocation.x - frame.minX, y: v.startLocation.y - frame.minY)
                    drag = NoteCardDrag(zone: NoteCardZone.at(local, size: frame.size), frame: frame,
                                        contentHeight: contentHeight, card: card)
                    moved = false
                }
                guard let d = drag else { return }
                if !moved, hypot(v.translation.width, v.translation.height) <= 2 { return }
                moved = true
                live = next(d, v.translation)
            }
            .onEnded { v in
                guard let d = drag else { return }
                drag = nil
                if moved {
                    onCommit(next(d, v.translation), d.zone)
                } else {
                    onClick(CGPoint(x: v.startLocation.x - d.frame.minX, y: v.startLocation.y - d.frame.minY))
                }
                live = nil
                moved = false
            }
    }

    private func next(_ d: NoteCardDrag, _ t: CGSize) -> NoteCard {
        d.card(translation: t, unit: metrics.unit, pin: pin, minSize: NoteBubble.cardMinSize(metrics), page: pageSize,
               pinClearance: NoteBubble.pinClearance(metrics, pinRadius: pinRadius))
    }
}

/// 一条文字笔记展开后的气泡。正文由引擎只读渲染（`MarkdownNoteReader`），高度由引擎报回来
/// （`.fitsContent` → `onGeometryChange`），第一帧先按 `NoteBubble.textHeight` 的估计占位、下一帧对齐。
/// 摆过（`card`）就按存的位置 / 宽 / 高度上限排；拖动 / 改大小见 `NoteCardInteraction`。
struct NoteBubbleView: View {
    let text: String
    /// 引擎按它分状态；气泡用 `<笔记 id>-bubble`，与编辑器里那份错开。
    let documentId: String
    let metrics: NoteBubble.Metrics
    let pageSize: CGSize
    let pin: CGPoint            // 图钉中心（页内像素）
    let pinRadius: CGFloat
    /// 手动摆过的位置 / 大小（nil = 自动规则）。
    var card: NoteCard? = nil
    /// 能不能拖动 / 改大小（常驻气泡 + 文字工具 + 草稿纸没盖着）。
    var interactive: Bool = false
    /// 松手提交；卡片为 nil = 恢复自动（右键菜单），此时 zone 也是 nil。
    var onCard: (NoteCard?, NoteCardZone?) -> Void = { _, _ in }
    /// 卡片此刻占页上哪块（nil = 收起了），阅读区容器手势据此让位。
    var onFrame: (CGRect?) -> Void = { _ in }
    /// 非 nil 才画右上角铅笔（tap/always 的「常驻气泡」有；hover 预览没有——
    /// 鼠标一旦离开图钉去够按钮，气泡就收了，那颗按钮是够不着的假入口）。
    let onEdit: (() -> Void)?

    /// 引擎排完版报回来的正文高度（**完整**高度，没钳过）。nil / 0 = 还没排（用估计值占位）。
    @State private var bodyH: CGFloat?
    /// 拖动 / 改大小进行中的预览（松手即清）。
    @State private var live: NoteCard?

    var body: some View {
        let m = metrics
        let c = live ?? card
        let edit = onEdit == nil ? 0 : m.edit
        // 宽：摆过宽用存的，否则短文按内容收窄（设置的最小…最大之间）
        let w = NoteBubble.cardWidth(c, auto: NoteBubble.fitWidth(text, m: m, hasEdit: onEdit != nil),
                                     m: m, pageSize: pageSize)
        let textW = max(m.fs, w - m.pad * 2 - edit)
        // 正文高度上限：摆过高用存的（那是整张卡片的高，减掉内边距），否则按行数上限
        let capH = c?.h.map { max(m.lineHeight, CGFloat($0) * m.unit - m.pad * 2) } ?? m.height(lines: m.maxLines)
        // 估计值不钳行数：超出上限的部分在卡片里滚，「内容一共多高」要用真的
        let measured = (bodyH ?? 0) > 1 ? bodyH! : NoteBubble.textHeight(text, width: textW, m: m, maxLines: 10_000)
        let h = min(measured, capH) + m.pad * 2
        let o = NoteBubble.placed(
            c.map { NoteBubble.cardOrigin($0, w: w, h: h, m: m, pin: pin, pageSize: pageSize) }
                ?? NoteBubble.origin(w: w, h: h, m: m, pin: pin, pinRadius: pinRadius, pageSize: pageSize),
            w: w, h: h, m: m, pin: pin, pinRadius: pinRadius, pageSize: pageSize)

        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: m.radius)
                .fill(NoteBubble.fill)
                .overlay(RoundedRectangle(cornerRadius: m.radius).stroke(NoteBubble.stroke, lineWidth: 1))
                .allowsHitTesting(false)
            // 🔴 量的是引擎的**理想高度**（`fixedSize` 纵向 = 不接受外面的提议），外层再钳到高度上限。
            // 别用 `.frame(maxHeight:)`：它会把外面提议的高度整个吃下来，量到的就是提议值 → 气泡每帧长一圈内边距，
            // 直到长到上限（样张里一行字的气泡长成了十四行那么高）。
            // 超出上限时**在卡片里滚**（用户 2026-09-16：「高度不够时，内容滚动」）；放得下时禁用滚动，滚轮照常滚页面。
            // 滚动容器常驻、只切换禁用：按「放不放得下」换两种容器的话，拖动改高度跨过那条线时正文引擎视图会被重建。
            // 正文不吃鼠标也不妨碍滚轮落到这个滚动容器上（离屏查过命中链：落在卡片自己的滚动视图里，不是外面的阅读区）。
            ScrollView(.vertical) {
                MarkdownNoteReader(text: text, fontSize: m.fs, width: textW, documentId: documentId)
                    .frame(width: textW)
                    .fixedSize(horizontal: false, vertical: true)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { bodyH = $0 }
            }
            .scrollDisabled(measured <= capH)
            // 🔴 必须 `.never`：macOS 上**可滚动**的 SwiftUI ScrollView 会给竖滚动条让位——底层滚动视图比给它的 frame
            // 宽 17pt、往左多出 8.5pt，内容贴着它的左边放，于是正文越出卡片左边界 8.5pt、右边被裁（用户 2026-09-16 报，
            // 离屏量过：系统是浮动滚动条也一样）。`.hidden` / `contentMargins` 都不管用，禁用滚动时不会（所以放得下的卡片没事）。
            .scrollIndicators(.never)
            .frame(width: textW, height: min(measured, capH), alignment: .top)
            .padding(.leading, m.pad)
            .padding(.top, m.pad)
            if let onEdit {
                // 图标 = `square.and.pencil`（macOS 惯用的「编辑」符号）。**别用裸 `pencil`**：
                // 它在这个尺寸下没有外框、读起来像掉在气泡角上的一道斜杠（2026-08-27 用户报「有点丑」，
                // 候选对比样张见 `spike/note-bubble-icon-look.swift`）。网页/安卓画的是同一个形状。
                Button(action: onEdit) {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: m.fs * 0.95, weight: .medium))
                        .foregroundStyle(NoteBubble.editGlyph)
                        .frame(width: edit, height: edit)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(L("Edit note"))
                .offset(x: w - edit - m.pad * 0.4, y: m.pad * 0.4)
            }
        }
        .frame(width: w, height: h, alignment: .topLeading)
        .modifier(NoteCardInteraction(enabled: interactive, frame: CGRect(x: o.x, y: o.y, width: w, height: h),
                                      contentHeight: measured + m.pad * 2, card: card, metrics: m, pin: pin,
                                      pinRadius: pinRadius, pageSize: pageSize, live: $live,
                                      onCommit: { onCard($0, $1) },
                                      onClick: { _ in NoteLinkClick.open(at: NSApp.currentEvent) },
                                      onFrame: onFrame))
        // 正文不能选字了（见 `MarkdownNoteReader`），右键给一个复制整条的入口；摆过的卡片能恢复自动位置与大小。
        .contextMenu {
            if interactive {
                if let onEdit { Button(L("Edit…")) { onEdit() } }
                Button(L("Copy Note Text")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
                if card != nil {
                    Divider()
                    Button(L("Reset Card Size and Position")) { onCard(nil, nil) }
                }
            }
        }
        .offset(x: o.x, y: o.y)
    }
}
