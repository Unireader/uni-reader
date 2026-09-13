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

    // 固定尺寸模式（默认，Mac 本机；屏幕点）。字号取系统 `.callout` 那档。
    static let fixedFont: CGFloat = 12
    static let fixedWidth: CGFloat = 280
    static let fixedLineHeightRatio: CGFloat = 1.25
    static let fixedPad: CGFloat = 5           // 「很窄的边」（用户）
    static let fixedRadius: CGFloat = 5
    static let fixedGap: CGFloat = 3
    static let fixedEdit: CGFloat = 20
    static let fixedMaxLines = 14

    /// 设置键：气泡要不要跟页缩放（默认关）。
    static let followsZoomKey = "noteBubbleFollowsZoom"

    // 配色：纸白底 + 发丝描边 + 深灰正文，**无投影/无渐变**（红线：不做拟物）。
    // 三端同值；夜间模式下平板只反转页图那一层，气泡照旧是浅底深字，可读。
    static let fill = Color(red: 1, green: 0.992, blue: 0.949).opacity(0.97)
    static let stroke = Color.black.opacity(0.18)
    static let ink = Color(red: 0.12, green: 0.12, blue: 0.13)
    static let editGlyph = Color.black.opacity(0.6)

    /// 一只气泡的全部尺寸（页内像素 = 屏幕点）。两种口径算出来的都是这一个东西，视图不必知道是哪种。
    struct Metrics: Equatable {
        var fs: CGFloat          // 正文字号
        var w: CGFloat           // 气泡宽
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

    static func metrics(pageWidth: CGFloat, followsZoom: Bool) -> Metrics {
        if followsZoom {
            let fs = max(1, pageWidth * fontRatio)
            return Metrics(fs: fs, w: max(1, pageWidth * widthRatio), pad: fs * padRatio,
                           radius: fs * radiusRatio, gap: fs * gapRatio, edit: fs * editRatio,
                           lineSpacing: fs * (lineHeightRatio - 1), maxLines: maxLines)
        }
        return Metrics(fs: fixedFont, w: fixedWidth, pad: fixedPad, radius: fixedRadius, gap: fixedGap,
                       edit: fixedEdit, lineSpacing: fixedFont * (fixedLineHeightRatio - 1), maxLines: fixedMaxLines)
    }

    /// 正文排版高度（用于把气泡钳进页内；Mac 用 TextKit 同步量，不引入异步测量 = 不闪）。
    /// 🔴 量的时候**把行间空隙也算进去**（`paragraphStyle.lineSpacing`）——之前没算，多行正文画出来
    /// 比量出来的高，一条五行的笔记会从气泡底边溢出去。`maxLines` 缺省用口径里的；说明文字那种短的自己传。
    static func textHeight(_ text: String, width: CGFloat, m: Metrics, maxLines: Int? = nil) -> CGFloat {
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byWordWrapping
        para.lineSpacing = m.lineSpacing
        let attr = NSAttributedString(string: text, attributes: [.font: m.font, .paragraphStyle: para])
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

/// 一条文字笔记展开后的气泡。
struct NoteBubbleView: View {
    let text: String
    let metrics: NoteBubble.Metrics
    let pageSize: CGSize
    let pin: CGPoint            // 图钉中心（页内像素）
    let pinRadius: CGFloat
    /// 非 nil 才画右上角铅笔（tap/always 的「常驻气泡」有；hover 预览没有——
    /// 鼠标一旦离开图钉去够按钮，气泡就收了，那颗按钮是够不着的假入口）。
    let onEdit: (() -> Void)?

    var body: some View {
        let m = metrics
        let edit = onEdit == nil ? 0 : m.edit
        let textW = max(m.fs, m.w - m.pad * 2 - edit)
        let h = NoteBubble.textHeight(text, width: textW, m: m) + m.pad * 2
        let o = NoteBubble.origin(w: m.w, h: h, m: m, pin: pin, pinRadius: pinRadius, pageSize: pageSize)

        ZStack(alignment: .topLeading) {
            // 气泡本体不参与命中：它盖在页面上，吃掉命中就等于「这块地方选不了字、框选不到」。
            // 唯一可点的是右上角那枚铅笔。
            RoundedRectangle(cornerRadius: m.radius)
                .fill(NoteBubble.fill)
                .overlay(RoundedRectangle(cornerRadius: m.radius).stroke(NoteBubble.stroke, lineWidth: 1))
                .allowsHitTesting(false)
            Text(text)
                .font(.system(size: m.fs))
                .foregroundStyle(NoteBubble.ink)
                .lineSpacing(m.lineSpacing)
                .lineLimit(m.maxLines)
                .multilineTextAlignment(.leading)
                .frame(width: textW, alignment: .topLeading)
                .padding(.leading, m.pad)
                .padding(.top, m.pad)
                .allowsHitTesting(false)
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
                .offset(x: m.w - edit - m.pad * 0.4, y: m.pad * 0.4)
            }
        }
        .frame(width: m.w, height: h, alignment: .topLeading)
        .offset(x: o.x, y: o.y)
    }
}
