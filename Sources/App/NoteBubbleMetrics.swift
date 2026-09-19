import AppKit

// MARK: - 笔记展开气泡的尺寸口径（文字笔记 / 图片笔记共用；从原 SwiftUI `NoteBubbleView` / `ImageNoteViews` 搬出，数值未改）

/// 两种口径（用户 2026-09-13 定）：
///  · **固定尺寸**（默认）：宽 / 字号 / 内边距全是屏幕点，页面缩放时气泡纹丝不动，正文一律 12pt。
///  · **跟页缩放**（设置 → 阅读 →「笔记气泡跟随页面缩放」打开）：全部尺寸是**页宽的比例**，缩放页面时
///    气泡跟着一起缩——比例常数是**三端契约**：Mac `NoteBubble` / web `render.ts BUB` / 安卓 `NoteBubbleGeom`
///    各实现一份，改任一个必须同步另外两个。折行由各端自己的排版引擎做；**比例常数不许各写各的**。
enum NoteBubble {
    // 跟页缩放模式的比例（三端契约）
    static let widthRatio: CGFloat = 0.30      // 气泡宽 ÷ 页宽
    static let fontRatio: CGFloat = 0.017      // 正文字号 ÷ 页宽
    static let lineHeightRatio: CGFloat = 1.25 // 行高 ÷ 字号
    static let padRatio: CGFloat = 0.30        // 内边距 ÷ 字号
    static let radiusRatio: CGFloat = 0.4      // 圆角 ÷ 字号
    static let gapRatio: CGFloat = 0.25        // 图钉与气泡的间隙 ÷ 字号
    static let editRatio: CGFloat = 1.7        // 右上角编辑按钮的边长（= 热区）÷ 字号
    static let maxLines = 10                   // 超出即截断（全文去编辑器里看）

    // 固定尺寸模式（默认，Mac 本机；屏幕点）。编辑按钮、行距按「字号 ÷ 12」等比跟着走；宽度是自己的设置项；
    // 内边距 / 圆角 / 间隙不动（那几样是「边」，不该随字变粗）。
    static let fixedFont: CGFloat = 12
    static let fixedMinWidth: CGFloat = 120
    static let fixedMaxWidth: CGFloat = 280
    static let fixedLineHeightRatio: CGFloat = 1.25
    static let fixedPad: CGFloat = 5
    static let fixedRadius: CGFloat = 5
    static let fixedGap: CGFloat = 3
    static let fixedEdit: CGFloat = 20
    static let fixedMaxLines = 14
    /// 跟页缩放口径下宽度设置按哪个页宽折算：280 ÷ 0.30 ≈ 933pt（贴合宽度时两种口径一样宽，切换开关观感不跳）。
    static let refPageWidth: CGFloat = fixedMaxWidth / widthRatio

    /// 设置键：气泡要不要跟页缩放（默认关）。
    static let followsZoomKey = "noteBubbleFollowsZoom"
    /// 设置键：气泡正文字号（跟页缩放口径下按「÷ 12」当倍率乘到字号比例上）。
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

    /// 一只气泡的全部尺寸（页内像素 = 屏幕点）。两种口径算出来的都是这一个东西。
    struct Metrics: Equatable {
        var fs: CGFloat          // 正文字号
        var w: CGFloat           // 气泡最大宽
        var minW: CGFloat        // 气泡最小宽
        var pad: CGFloat         // 内边距
        var radius: CGFloat
        var gap: CGFloat         // 图钉与气泡的间隙
        var edit: CGFloat        // 右上角编辑按钮边长
        var lineSpacing: CGFloat // 行与行之间额外的空隙
        var maxLines: Int
        /// 手动摆过的卡片（`NoteCard`）存的数 × unit = 页内像素：固定口径 1，跟页缩放口径 = 页宽 ÷ 参考页宽。
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
        let k = max(0.5, fontSize / fixedFont)
        let lo = max(40, min(minWidth, maxWidth))
        let hi = max(lo, maxWidth)
        if followsZoom {
            let fs = max(1, pageWidth * fontRatio * k)
            let s = max(0.05, pageWidth / refPageWidth)
            return Metrics(fs: fs, w: max(1, hi * s), minW: max(1, lo * s), pad: fs * padRatio,
                           radius: fs * radiusRatio, gap: fs * gapRatio, edit: fs * editRatio,
                           lineSpacing: fs * (lineHeightRatio - 1), maxLines: maxLines, unit: s)
        }
        let fs = fixedFont * k
        return Metrics(fs: fs, w: hi, minW: lo, pad: fixedPad, radius: fixedRadius, gap: fixedGap,
                       edit: fixedEdit * k, lineSpacing: fs * (fixedLineHeightRatio - 1), maxLines: fixedMaxLines)
    }

    /// 文字气泡的宽：按内容最宽那一行（估计值，加 4% + 6pt 余量）在 `minW…w` 之间收窄。
    static func fitWidth(_ text: String, m: Metrics, hasEdit: Bool) -> CGFloat {
        let content = NoteMarkdown.naturalWidth(text, font: m.font) * 1.04 + 6
        let need = content + m.pad * 2 + (hasEdit ? m.edit : 0)
        return min(max(need.rounded(.up), m.minW), m.w)
    }

    /// 正文高度的**估计值**（TextKit 同步量）：真实高度要等引擎排完版报回来，第一帧先按这个占位。
    static func textHeight(_ text: String, width: CGFloat, m: Metrics, maxLines: Int? = nil) -> CGFloat {
        let attr = NoteMarkdown.nsAttributed(text, font: m.font, lineSpacing: m.lineSpacing)
        let box = attr.boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude),
                                    options: [.usesLineFragmentOrigin, .usesFontLeading])
        return min(max(m.lineHeight, box.height.rounded(.up)), m.height(lines: maxLines ?? m.maxLines))
    }

    // MARK: 手动摆过的卡片（`NoteCard`，Mac 本机；网页 / 安卓暂不认）

    /// 卡片最小尺寸（页内像素）：宽至少放得下几个字 + 编辑按钮，高至少一行。
    static func cardMinSize(_ m: Metrics) -> CGSize {
        CGSize(width: max(CGFloat(widthRange.lowerBound) * m.unit, m.edit + m.pad * 2 + m.fs * 3),
               height: m.lineHeight + m.pad * 2)
    }

    /// 摆过的卡片左上角：图钉中心 + 存的偏移，钳进页内。
    static func cardOrigin(_ card: NoteCard, w: CGFloat, h: CGFloat, m: Metrics, pin: CGPoint,
                           pageSize: CGSize) -> CGPoint {
        let x = pin.x + CGFloat(card.dx) * m.unit, y = pin.y + CGFloat(card.dy) * m.unit
        return CGPoint(x: min(max(x, 0), max(0, pageSize.width - w)),
                       y: min(max(y, 0), max(0, pageSize.height - h)))
    }

    /// 图钉禁区半边长：图钉半径 + 图钉与气泡的间隙。
    static func pinClearance(_ m: Metrics, pinRadius: CGFloat) -> CGFloat { pinRadius + m.gap }

    /// 卡片最终落位：算好的左上角若让卡片压住自己的图钉，整块挪开（用户 2026-09-16：「不允许渲染窗覆盖自己的图钉」）。
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

    /// 气泡左上角（页内像素）：贴在图钉**右侧**、顶边与图钉顶对齐；右侧放不下翻到**左侧**；最后整体钳进页内（三端同款）。
    static func origin(w: CGFloat, h: CGFloat, m: Metrics, pin: CGPoint, pinRadius: CGFloat,
                       pageSize: CGSize) -> CGPoint {
        var x = pin.x + pinRadius + m.gap
        if x + w > pageSize.width { x = pin.x - pinRadius - m.gap - w }
        let y = pin.y - pinRadius
        return CGPoint(x: min(max(x, 0), max(0, pageSize.width - w)),
                       y: min(max(y, 0), max(0, pageSize.height - h)))
    }
}

/// 图片气泡的尺寸口径：与文字气泡同一份 `NoteBubble.Metrics`，这里只多缩略图高度上限与说明行数。
enum ImageBubble {
    /// 缩略图高度上限 = 气泡宽（太高的图裁到这个高度以内等比缩小，全图去看大图）。
    static let maxThumbHeightRatio: CGFloat = 1.0
    static let captionMaxLines = 3
    /// 缩略图与说明之间的间隙 ÷ 字号
    static let captionGapRatio: CGFloat = 0.35
    /// 气泡宽度下限 ÷ 最大宽：竖图把气泡收窄到贴着图，但别窄到说明文字一行放不下几个字。
    static let minWidthRatio: CGFloat = 0.45
    /// 图不在时的占位高度 ÷ 字号。
    static let missingHeightRatio: CGFloat = 3.5

    /// 气泡尺寸：横图撑满口径宽；竖图高到上限后按比例缩窄，气泡跟着收窄贴着图；说明文字在缩略图下面。
    /// 手动摆过的卡片：`width` = 定死的宽；`maxHeight` = 整张卡片的高度上限，比内容矮时内容在卡片里滚。
    /// 返回的 `contentH` = 内容全部露出要多高。
    static func size(m: NoteBubble.Metrics, pixelSize: CGSize, caption: String, missing: Bool,
                     captionH: CGFloat? = nil, width: CGFloat? = nil, maxHeight: CGFloat? = nil)
        -> (w: CGFloat, h: CGFloat, thumb: CGSize, contentH: CGFloat) {
        let budget = width ?? m.w
        let fullW = max(1, budget - m.pad * 2)
        let thumb: CGSize
        if missing {
            thumb = CGSize(width: fullW, height: m.fs * missingHeightRatio)
        } else {
            let aspect = pixelSize.width > 0 ? pixelSize.height / pixelSize.width : 0.75
            let capH = budget * maxThumbHeightRatio
            let h = min(fullW * aspect, capH)
            thumb = CGSize(width: h >= capH ? max(1, capH / aspect) : fullW, height: h)
        }
        let w = width ?? min(m.w, max(thumb.width + m.pad * 2, max(m.minW, m.w * minWidthRatio)))
        let textW = max(1, w - m.pad * 2)
        var captionPart: CGFloat = 0
        if !caption.isEmpty {
            let est = NoteBubble.textHeight(caption, width: textW, m: m, maxLines: captionMaxLines)
            let ch = (captionH ?? 0) > 1 ? captionH! : est
            captionPart = m.fs * captionGapRatio + min(ch, m.height(lines: captionMaxLines))
        }
        let contentH = m.pad * 2 + thumb.height + captionPart
        guard let maxHeight, contentH > maxHeight else { return (w, contentH, thumb, contentH) }
        return (w, max(maxHeight, NoteBubble.cardMinSize(m).height), thumb, contentH)
    }
}
