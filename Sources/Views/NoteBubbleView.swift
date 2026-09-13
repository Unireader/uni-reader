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
                           lineSpacing: fs * (lineHeightRatio - 1), maxLines: maxLines)
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

/// 一条文字笔记展开后的气泡。正文由引擎只读渲染（`MarkdownNoteReader`），高度由引擎报回来
/// （`.fitsContent` → `onGeometryChange`），第一帧先按 `NoteBubble.textHeight` 的估计占位、下一帧对齐。
struct NoteBubbleView: View {
    let text: String
    /// 引擎按它分状态；气泡用 `<笔记 id>-bubble`，与编辑器里那份错开。
    let documentId: String
    let metrics: NoteBubble.Metrics
    let pageSize: CGSize
    let pin: CGPoint            // 图钉中心（页内像素）
    let pinRadius: CGFloat
    /// 非 nil 才画右上角铅笔（tap/always 的「常驻气泡」有；hover 预览没有——
    /// 鼠标一旦离开图钉去够按钮，气泡就收了，那颗按钮是够不着的假入口）。
    let onEdit: (() -> Void)?

    /// 引擎排完版报回来的正文高度（已按行数上限钳过）。nil / 0 = 还没排（用估计值占位）。
    @State private var bodyH: CGFloat?

    var body: some View {
        let m = metrics
        let edit = onEdit == nil ? 0 : m.edit
        let w = NoteBubble.fitWidth(text, m: m, hasEdit: onEdit != nil)   // 短文按内容收窄（设置的最小…最大之间）
        let textW = max(m.fs, w - m.pad * 2 - edit)
        let capH = m.height(lines: m.maxLines)
        let measured = (bodyH ?? 0) > 1 ? bodyH! : NoteBubble.textHeight(text, width: textW, m: m)
        let h = min(measured, capH) + m.pad * 2
        let o = NoteBubble.origin(w: w, h: h, m: m, pin: pin, pinRadius: pinRadius, pageSize: pageSize)

        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: m.radius)
                .fill(NoteBubble.fill)
                .overlay(RoundedRectangle(cornerRadius: m.radius).stroke(NoteBubble.stroke, lineWidth: 1))
                .allowsHitTesting(false)
            // 🔴 量的是引擎的**理想高度**（`fixedSize` 纵向 = 不接受外面的提议），外层再钳到行数上限并裁掉多余部分
            //（全文去编辑器看，不在气泡里滚）。别用 `.frame(maxHeight:)`：它会把外面提议的高度整个吃下来，
            // 量到的就是提议值 → 气泡每帧长一圈内边距，直到长到上限（样张里一行字的气泡长成了十四行那么高）。
            MarkdownNoteReader(text: text, fontSize: m.fs, documentId: documentId)
                .frame(width: textW)
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { bodyH = $0 }
                .frame(width: textW, height: min(measured, capH), alignment: .top)
                .clipped()
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
        .offset(x: o.x, y: o.y)
    }
}
