import AppKit
import SwiftUI

// MARK: - 文字笔记展开气泡（页锚定，跟页缩放）

/// 🔴 **三端渲染契约**（2026-08-27）：气泡的全部尺寸都是**页宽的比例**——用户拍板「跟页缩放」，
/// 于是缩放页面时气泡跟着一起缩，页面版式看起来是一体的。
/// 这套数在 Mac `NoteBubbleView` / web `render.ts drawNoteBubbles` / 安卓 `PadOverlays.drawNoteBubble`
/// **各实现一份**，改任一个必须同步另外两个（同 `InkEdit.splitStroke` / 草稿纸底纹的先例）。
///
/// 折行由各端自己的排版引擎做（TextKit / canvas measureText / StaticLayout），行末断点会有细微差异，
/// 这是可接受的；**比例常数不许各写各的**。
enum NoteBubble {
    static let widthRatio: CGFloat = 0.30      // 气泡宽 ÷ 页宽
    static let fontRatio: CGFloat = 0.022      // 正文字号 ÷ 页宽
    static let lineHeightRatio: CGFloat = 1.35 // 行高 ÷ 字号
    static let padRatio: CGFloat = 0.55        // 内边距 ÷ 字号
    static let radiusRatio: CGFloat = 0.5      // 圆角 ÷ 字号
    static let gapRatio: CGFloat = 0.25        // 图钉与气泡的间隙 ÷ 字号
    static let editRatio: CGFloat = 1.7        // 右上角编辑按钮的边长（= 热区）÷ 字号
    static let maxLines = 10                   // 超出即截断（全文去编辑器里看，别让一条笔记糊住半页）

    // 配色：纸白底 + 发丝描边 + 深灰正文，**无投影/无渐变**（红线：不做拟物）。
    // 三端同值；夜间模式下平板只反转页图那一层，气泡照旧是浅底深字，可读。
    static let fill = Color(red: 1, green: 0.992, blue: 0.949).opacity(0.97)
    static let stroke = Color.black.opacity(0.18)
    static let ink = Color(red: 0.12, green: 0.12, blue: 0.13)
    static let editGlyph = Color.black.opacity(0.6)

    static func font(pageWidth: CGFloat) -> CGFloat { max(1, pageWidth * fontRatio) }
    static func width(pageWidth: CGFloat) -> CGFloat { max(1, pageWidth * widthRatio) }

    /// 正文排版高度（用于把气泡钳进页内；Mac 用 TextKit 同步量，不引入异步测量 = 不闪）。
    static func textHeight(_ text: String, width: CGFloat, fontSize: CGFloat) -> CGFloat {
        let f = NSFont.systemFont(ofSize: fontSize)
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byWordWrapping
        let attr = NSAttributedString(string: text, attributes: [.font: f, .paragraphStyle: para])
        let box = attr.boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude),
                                    options: [.usesLineFragmentOrigin, .usesFontLeading])
        let line = fontSize * lineHeightRatio
        return min(max(line, box.height.rounded(.up)), line * CGFloat(maxLines))
    }
}

/// 一条文字笔记展开后的气泡。位置规则（三端同款）：
/// 默认贴在图钉**右侧**、顶边与图钉顶对齐；右侧放不下就翻到**左侧**；最后整体钳进页内。
struct NoteBubbleView: View {
    let text: String
    let pageSize: CGSize
    let pin: CGPoint            // 图钉中心（页内像素）
    let pinRadius: CGFloat
    /// 非 nil 才画右上角铅笔（tap/always 的「常驻气泡」有；hover 预览没有——
    /// 鼠标一旦离开图钉去够按钮，气泡就收了，那颗按钮是够不着的假入口）。
    let onEdit: (() -> Void)?

    var body: some View {
        let fs = NoteBubble.font(pageWidth: pageSize.width)
        let w = NoteBubble.width(pageWidth: pageSize.width)
        let pad = fs * NoteBubble.padRatio
        let edit = onEdit == nil ? 0 : fs * NoteBubble.editRatio
        let textW = max(fs, w - pad * 2 - edit)
        let h = NoteBubble.textHeight(text, width: textW, fontSize: fs) + pad * 2
        let o = origin(w: w, h: h, fs: fs)

        ZStack(alignment: .topLeading) {
            // 气泡本体不参与命中：它盖在页面上，吃掉命中就等于「这块地方选不了字、框选不到」。
            // 唯一可点的是右上角那枚铅笔。
            RoundedRectangle(cornerRadius: fs * NoteBubble.radiusRatio)
                .fill(NoteBubble.fill)
                .overlay(RoundedRectangle(cornerRadius: fs * NoteBubble.radiusRatio)
                    .stroke(NoteBubble.stroke, lineWidth: 1))
                .allowsHitTesting(false)
            Text(text)
                .font(.system(size: fs))
                .foregroundStyle(NoteBubble.ink)
                .lineSpacing(fs * (NoteBubble.lineHeightRatio - 1))
                .lineLimit(NoteBubble.maxLines)
                .multilineTextAlignment(.leading)
                .frame(width: textW, alignment: .topLeading)
                .padding(.leading, pad)
                .padding(.top, pad)
                .allowsHitTesting(false)
            if let onEdit {
                Button(action: onEdit) {
                    Image(systemName: "pencil")
                        .font(.system(size: fs * 0.95, weight: .medium))
                        .foregroundStyle(NoteBubble.editGlyph)
                        .frame(width: edit, height: edit)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(L("Edit note"))
                .offset(x: w - edit - pad * 0.4, y: pad * 0.4)
            }
        }
        .frame(width: w, height: h, alignment: .topLeading)
        .offset(x: o.x, y: o.y)
    }

    /// 气泡左上角（页内像素）：右侧优先、放不下翻左侧，再整体钳进页内。
    private func origin(w: CGFloat, h: CGFloat, fs: CGFloat) -> CGPoint {
        let gap = fs * NoteBubble.gapRatio
        var x = pin.x + pinRadius + gap
        if x + w > pageSize.width { x = pin.x - pinRadius - gap - w }
        let y = pin.y - pinRadius
        return CGPoint(x: min(max(x, 0), max(0, pageSize.width - w)),
                       y: min(max(y, 0), max(0, pageSize.height - h)))
    }
}
