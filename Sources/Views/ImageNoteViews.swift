import AppKit
import SwiftUI

// MARK: - 图片笔记的几样视图（`IMAGE-NOTE-PLAN.md §5`）：页面气泡 / 编辑器 / 看大图

/// 图片气泡的尺寸口径：与文字气泡**同一份 `NoteBubble.Metrics`**（固定尺寸 / 跟页缩放两种口径都从那边来），
/// 这里只多两条自己的数：缩略图的高度上限、说明最多几行。
enum ImageBubble {
    /// 缩略图高度上限 = 气泡宽（太高的图裁到这个高度以内等比缩小，全图去看大图）。
    static let maxThumbHeightRatio: CGFloat = 1.0
    static let captionMaxLines = 3
    /// 缩略图与说明之间的间隙 ÷ 字号
    static let captionGapRatio: CGFloat = 0.35

    /// 气泡宽度下限 ÷ 最大宽：竖图把气泡收窄到贴着图，但别窄到说明文字一行放不下几个字（与设置的最小宽取大者）。
    static let minWidthRatio: CGFloat = 0.45
    /// 图不在时的占位高度 ÷ 字号（一小条就够，别按不存在的图占一大块）。
    static let missingHeightRatio: CGFloat = 3.5

    /// 气泡尺寸：横图撑满口径宽；**竖图**高到上限后按比例缩窄，气泡跟着**收窄贴着图**（不留两侧大片空白）；
    /// 说明文字在缩略图下面。`pixelSize` 是图的像素尺寸（先占位，不等解码）；`missing` = 图不在（占位一小条）；
    /// `captionH` = 引擎报回来的说明高度（nil = 还没排，按估计值）。
    /// 手动摆过的卡片（`NoteCard`）：`width` = 定死的宽（缩略图按它铺，不再收窄贴图）；`maxHeight` = 整张卡片的高度上限，
    /// 比内容矮时卡片就这么高、内容在卡片里滚（用户 2026-09-16：「高度不够时，内容滚动」）。
    /// 返回的 `contentH` = 内容全部露出要多高（视图据此决定滚不滚；拖动改大小也按它算，见 `NoteCardDrag`）。
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

/// 一条图片笔记展开后的气泡：缩略图 + 说明（有才画）。**没有铅笔**（压在图上很突兀，用户 2026-09-13）——
/// 点缩略图看原图，右键出「查看原图 / 编辑… / 删除」。位置规则同文字气泡（`NoteBubble.origin`；摆过按 `note.card`）。
/// 拖动 / 改大小与文字气泡同一套（`NoteCardInteraction`）；「点缩略图看原图」也由它认出单击后分派。
/// `onEdit`/`onView`/`onDelete` 为 nil = 悬停预览（一移开就收，够不着任何按钮，也就不挂菜单、不能拖）。
struct ImageBubbleView: View {
    let note: ImageNote
    let info: (url: URL, size: CGSize)?     // nil = 图不在（镜像没带 / 已清理）
    let metrics: NoteBubble.Metrics
    let pageSize: CGSize
    let pin: CGPoint
    let pinRadius: CGFloat
    /// 能不能拖动 / 改大小（另外还要是常驻气泡，见 `sticky`）。
    var interactive: Bool = false
    var onCard: (NoteCard?, NoteCardZone?) -> Void = { _, _ in }
    var onFrame: (CGRect?) -> Void = { _ in }
    let onEdit: (() -> Void)?
    let onView: (() -> Void)?
    let onDelete: (() -> Void)?

    @ObservedObject private var thumbs = ImageThumbCache.shared
    /// 引擎报回来的说明高度（同 `NoteBubbleView.bodyH`）。
    @State private var captionH: CGFloat?
    /// 拖动 / 改大小进行中的预览。
    @State private var live: NoteCard?
    /// 卡片里滚过的距离（内容比高度上限高时才滚得动）：单击看原图要按它换算缩略图此刻在哪。
    @State private var scrollY: CGFloat = 0

    var body: some View {
        let m = metrics
        let c = live ?? note.card
        let sticky = onView != nil
        let px = info?.size ?? CGSize(width: 4, height: 3)
        let s = ImageBubble.size(m: m, pixelSize: px, caption: note.caption, missing: info == nil, captionH: captionH,
                                 width: c?.w == nil ? nil : NoteBubble.cardWidth(c, auto: m.w, m: m, pageSize: pageSize),
                                 maxHeight: c?.h.map { CGFloat($0) * m.unit })
        let o = NoteBubble.placed(
            c.map { NoteBubble.cardOrigin($0, w: s.w, h: s.h, m: m, pin: pin, pageSize: pageSize) }
                ?? NoteBubble.origin(w: s.w, h: s.h, m: m, pin: pin, pinRadius: pinRadius, pageSize: pageSize),
            w: s.w, h: s.h, m: m, pin: pin, pinRadius: pinRadius, pageSize: pageSize)
        let innerW = max(1, s.w - m.pad * 2)
        // 缩略图在卡片里占的那块（卡片内坐标，扣掉卡片里滚动过的距离）：单击落在这里才是「看原图」
        let thumbRect = CGRect(x: m.pad + (innerW - s.thumb.width) / 2, y: m.pad - scrollY,
                               width: s.thumb.width, height: s.thumb.height)

        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: m.radius)
                .fill(NoteBubble.fill)
                .overlay(RoundedRectangle(cornerRadius: m.radius).stroke(NoteBubble.stroke, lineWidth: 1))
                .allowsHitTesting(false)
            // 高度上限比内容矮时在卡片里滚（同文字卡片：滚动容器常驻，放得下时禁用，滚轮照常滚页面）
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: m.fs * ImageBubble.captionGapRatio) {
                    // 竖图比气泡内宽窄时居中摆（气泡已经收窄到下限，剩下那点空白左右平分）
                    thumb(s.thumb, m: m)
                        .frame(width: innerW, alignment: .center)
                    if !note.caption.isEmpty {
                        // 说明也是 Markdown 源，同一个引擎只读渲染；超 3 行裁掉
                        // 量理想高度再钳上限（同 `NoteBubbleView` 那条注释：别用 `.frame(maxHeight:)`）
                        let capH = m.height(lines: ImageBubble.captionMaxLines)
                        let est = NoteBubble.textHeight(note.caption, width: innerW, m: m,
                                                        maxLines: ImageBubble.captionMaxLines)
                        MarkdownNoteReader(text: note.caption, fontSize: m.fs, width: innerW,
                                           documentId: "\(note.id.uuidString)-caption")
                            .frame(width: innerW)
                            .fixedSize(horizontal: false, vertical: true)
                            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { captionH = $0 }
                            .frame(width: innerW, height: min((captionH ?? 0) > 1 ? captionH! : est, capH),
                                   alignment: .top)
                            .clipped()
                    }
                }
                .padding(m.pad)
            }
            .scrollDisabled(s.contentH <= s.h)
            .scrollIndicators(.never)   // 同文字卡片：不写 `.never` 可滚动时内容整体左移 8.5pt 越出卡片
            .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y } action: { _, y in scrollY = y }
            .frame(width: s.w, height: s.h, alignment: .topLeading)
            .clipShape(RoundedRectangle(cornerRadius: m.radius))   // 描边在外层，不裁
        }
        .frame(width: s.w, height: s.h, alignment: .topLeading)
        .modifier(NoteCardInteraction(enabled: interactive && sticky,
                                      frame: CGRect(x: o.x, y: o.y, width: s.w, height: s.h),
                                      contentHeight: s.contentH, card: note.card, metrics: m, pin: pin,
                                      pinRadius: pinRadius, pageSize: pageSize, live: $live,
                                      onCommit: { onCard($0, $1) },
                                      onClick: { p in if thumbRect.contains(p) { onView?() } },
                                      onFrame: onFrame))
        // 悬停预览不挂菜单：它一移开就收，挂了也是够不着的假入口
        .contextMenu {
            if sticky {
                if let onView { Button(L("View Full Size")) { onView() }.disabled(info == nil) }
                if let onEdit { Button(L("Edit…")) { onEdit() } }
                if interactive, note.card != nil {
                    Divider()
                    Button(L("Reset Card Size and Position")) { onCard(nil, nil) }
                }
                if let onDelete {
                    Divider()
                    Button(L("Delete Image Note"), role: .destructive) { onDelete() }
                }
            }
        }
        .offset(x: o.x, y: o.y)
    }

    @ViewBuilder private func thumb(_ box: CGSize, m: NoteBubble.Metrics) -> some View {
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let sticky = onView != nil   // 常驻气泡（点开的 / 始终展示的）才有「点击看原图」的提示
        ZStack {
            if let info, let cg = thumbs.image(url: info.url, maxPixel: Int((box.width * scale).rounded(.up))) {
                Image(decorative: cg, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
            } else {
                // 还没解出来 / 图不在：占位方块 + 图标（尺寸已按像素尺寸占好，解好了原地换图不跳版）
                RoundedRectangle(cornerRadius: m.radius * 0.6)
                    .fill(NoteBubble.stroke.opacity(0.35))
                Image(systemName: info == nil ? "photo.badge.exclamationmark" : "photo")
                    .font(.system(size: max(10, m.fs * 1.6)))
                    .foregroundStyle(NoteBubble.editGlyph)
            }
        }
        .frame(width: box.width, height: box.height)
        // 单击看原图 / 右键菜单都挪到整张卡片上了（`body` 里的 `NoteCardInteraction` / `.contextMenu`）：
        // 缩略图自己再挂点击手势，会跟卡片的拖动抢——按在图上就拖不动卡片。
        .help(info == nil ? L("Image file is missing (not in this copy, or already cleaned up).")
                          : (sticky ? L("Click to view full size") : ""))
    }
}

/// 列表里的方形缩略图（Inspector 行）：等比缩进 `side` 见方的框里，图不在就画个带感叹号的占位。
struct ImageNoteThumb: View {
    let info: (url: URL, size: CGSize)?
    let side: CGFloat

    @ObservedObject private var thumbs = ImageThumbCache.shared

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4).fill(.quaternary.opacity(0.6))
            if let info, let cg = thumbs.image(url: info.url, maxPixel: Int(side * 2)) {
                Image(decorative: cg, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            } else {
                Image(systemName: info == nil ? "photo.badge.exclamationmark" : "photo")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: side, height: side)
    }
}

// MARK: - 编辑器

/// 图片笔记编辑器：缩略图 + 来源一行 + 说明 + 展开方式；删除入口在左下。走标准 `.sheet`，⌘回车保存、Esc 取消。
struct ImageNoteEditorSheet: View {
    let note: ImageNote
    let info: (url: URL, size: CGSize)?
    let onSave: (String, NoteDisplay) -> Void
    let onDelete: () -> Void
    let onView: () -> Void
    let onCancel: () -> Void

    @State private var caption: String
    @State private var display: NoteDisplay
    @ObservedObject private var thumbs = ImageThumbCache.shared

    init(note: ImageNote, info: (url: URL, size: CGSize)?,
         onSave: @escaping (String, NoteDisplay) -> Void, onDelete: @escaping () -> Void,
         onView: @escaping () -> Void, onCancel: @escaping () -> Void) {
        self.note = note
        self.info = info
        self.onSave = onSave
        self.onDelete = onDelete
        self.onView = onView
        self.onCancel = onCancel
        _caption = State(initialValue: note.caption)
        _display = State(initialValue: note.display)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(L("Image Note")).font(.headline)
                Spacer()
                Text(note.sourceLabel).font(.callout).foregroundStyle(.secondary).lineLimit(1)
            }

            preview
                .frame(maxWidth: .infinity)
                .frame(height: 220)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))

            MarkdownNoteEditor(text: $caption, documentId: note.id.uuidString, placeholder: L("Caption… (Markdown)"))
                .frame(width: 380, height: 100)

            HStack(spacing: 8) {
                Text(L("Show note")).font(.callout).foregroundStyle(.secondary)
                Picker(L("Show note"), selection: $display) {
                    Text(L("On tap")).tag(NoteDisplay.tap)
                    Text(L("On hover")).tag(NoteDisplay.hover)
                    Text(L("Always")).tag(NoteDisplay.always)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            HStack {
                Button(L("Delete"), role: .destructive) { onDelete() }
                Button(L("View Full Size")) { onView() }.disabled(info == nil)
                Spacer()
                Button(L("Cancel")) { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button(L("Save")) { onSave(caption, display) }
                    .keyboardShortcut(.return, modifiers: .command)   // ⌘↩ 保存（编辑框里回车是换行）
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
        .frame(width: 420)
    }

    @ViewBuilder private var preview: some View {
        if let info, let cg = thumbs.image(url: info.url, maxPixel: 1024) {
            Image(decorative: cg, scale: 1)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .padding(6)
        } else {
            Image(systemName: info == nil ? "photo.badge.exclamationmark" : "photo")
                .font(.largeTitle).foregroundStyle(.secondary)
        }
    }
}

// MARK: - 看大图

/// 原图等比铺满显示（窗口大小 = 屏幕的 70%，图小于窗口时按原像素显示不放大）。
struct ImageViewerSheet: View {
    let note: ImageNote
    let url: URL
    let onClose: () -> Void

    @State private var image: CGImage?

    var body: some View {
        let screen = NSScreen.main?.visibleFrame.size ?? CGSize(width: 1200, height: 800)
        VStack(spacing: 10) {
            HStack {
                Text(note.caption.isEmpty ? note.sourceLabel : note.caption)
                    .font(.headline).lineLimit(1)
                Spacer()
                if let image {
                    Text("\(image.width) × \(image.height)").font(.callout).foregroundStyle(.secondary)
                }
            }
            ZStack {
                if let image {
                    let scale = NSScreen.main?.backingScaleFactor ?? 2
                    Image(decorative: image, scale: scale)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        // 小图按原像素显示（÷ scale 得点），不拉大；大图受 fit 约束缩到窗内
                        .frame(maxWidth: CGFloat(image.width) / scale, maxHeight: CGFloat(image.height) / scale)
                } else {
                    ProgressView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            HStack {
                Button(L("Copy Image")) { copy() }.disabled(image == nil)
                Button(L("Show in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                Spacer()
                Button(L("Close")) { onClose() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(16)
        .frame(width: screen.width * 0.7, height: screen.height * 0.7)
        .task { image = await Task.detached { ImageAssets.load(url) }.value }
    }

    private func copy() {
        guard let image else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        let rep = NSBitmapImageRep(cgImage: image)
        if let data = rep.representation(using: .png, properties: [:]) {
            pb.setData(data, forType: .png)
        }
    }
}
