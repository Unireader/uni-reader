import AppKit
import SwiftUI

// MARK: - 图片笔记的几样视图（`IMAGE-NOTE-PLAN.md §5`）：页面气泡 / 编辑器 / 看大图

/// 图片气泡的尺寸口径：与文字气泡（`NoteBubble`）**同一套比例常数**——宽、圆角、内边距、间隙都按页宽走，
/// 缩放页面时两种气泡看起来是一体的。这里只多两条自己的数：缩略图的高度上限、说明最多几行。
enum ImageBubble {
    /// 缩略图高度上限 = 气泡宽（太高的图裁到这个高度以内等比缩小，全图去看大图）。
    static let maxThumbHeightRatio: CGFloat = 1.0
    static let captionMaxLines = 3
    /// 缩略图与说明之间的间隙 ÷ 字号
    static let captionGapRatio: CGFloat = 0.45

    /// 气泡尺寸（宽恒 = 页宽比例；高由缩略图 + 说明算出）。`pixelSize` 是图的像素尺寸（先占位，不等解码）。
    static func size(pageWidth: CGFloat, pixelSize: CGSize, caption: String, hasEdit: Bool)
        -> (w: CGFloat, h: CGFloat, thumb: CGSize, fs: CGFloat, pad: CGFloat) {
        let fs = NoteBubble.font(pageWidth: pageWidth)
        let w = NoteBubble.width(pageWidth: pageWidth)
        let pad = fs * NoteBubble.padRatio
        let thumbW = max(1, w - pad * 2)
        let aspect = pixelSize.width > 0 ? pixelSize.height / pixelSize.width : 0.75
        let thumbH = min(thumbW * aspect, w * maxThumbHeightRatio)
        var h = pad + thumbH + pad
        if !caption.isEmpty {
            let textH = min(NoteBubble.textHeight(caption, width: thumbW, fontSize: fs),
                            fs * NoteBubble.lineHeightRatio * CGFloat(captionMaxLines))
            h += fs * captionGapRatio + textH
        }
        return (w, h, CGSize(width: thumbW, height: thumbH), fs, pad)
    }
}

/// 一条图片笔记展开后的气泡：缩略图 + 说明（有才画）+ 右上角铅笔（常驻气泡才有，同文字气泡的口径）。
/// 位置规则同 `NoteBubbleView`：图钉右侧优先 → 放不下翻左侧 → 整体钳进页内。
/// 双击缩略图看大图（只在常驻气泡上挂——悬浮预览一移开就收，够不着）。
struct ImageBubbleView: View {
    let note: ImageNote
    let info: (url: URL, size: CGSize)?     // nil = 图不在（镜像没带 / 已清理）
    let pageSize: CGSize
    let pin: CGPoint
    let pinRadius: CGFloat
    let onEdit: (() -> Void)?
    let onView: (() -> Void)?

    @ObservedObject private var thumbs = ImageThumbCache.shared

    var body: some View {
        let px = info?.size ?? CGSize(width: 4, height: 3)
        let m = ImageBubble.size(pageWidth: pageSize.width, pixelSize: px,
                                 caption: note.caption, hasEdit: onEdit != nil)
        let o = origin(w: m.w, h: m.h, fs: m.fs)
        let edit = onEdit == nil ? 0 : m.fs * NoteBubble.editRatio

        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: m.fs * NoteBubble.radiusRatio)
                .fill(NoteBubble.fill)
                .overlay(RoundedRectangle(cornerRadius: m.fs * NoteBubble.radiusRatio)
                    .stroke(NoteBubble.stroke, lineWidth: 1))
                .allowsHitTesting(false)
            VStack(alignment: .leading, spacing: m.fs * ImageBubble.captionGapRatio) {
                thumb(m.thumb, fs: m.fs)
                if !note.caption.isEmpty {
                    Text(note.caption)
                        .font(.system(size: m.fs))
                        .foregroundStyle(NoteBubble.ink)
                        .lineSpacing(m.fs * (NoteBubble.lineHeightRatio - 1))
                        .lineLimit(ImageBubble.captionMaxLines)
                        .multilineTextAlignment(.leading)
                        .frame(width: m.thumb.width, alignment: .topLeading)
                        .allowsHitTesting(false)
                }
            }
            .padding(m.pad)
            if let onEdit {
                Button(action: onEdit) {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: m.fs * 0.95, weight: .medium))
                        .foregroundStyle(NoteBubble.editGlyph)
                        .frame(width: edit, height: edit)
                        // 铅笔压在缩略图上，垫一层纸色圆底才看得见（扁平、无阴影）
                        .background(NoteBubble.fill, in: Circle())
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(L("Edit note"))
                .offset(x: m.w - edit - m.pad * 0.4, y: m.pad * 0.4)
            }
        }
        .frame(width: m.w, height: m.h, alignment: .topLeading)
        .offset(x: o.x, y: o.y)
    }

    @ViewBuilder private func thumb(_ box: CGSize, fs: CGFloat) -> some View {
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        ZStack {
            if let info, let cg = thumbs.image(url: info.url, maxPixel: Int((box.width * scale).rounded(.up))) {
                Image(decorative: cg, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
            } else {
                // 还没解出来 / 图不在：占位方块 + 图标（尺寸已按像素尺寸占好，解好了原地换图不跳版）
                RoundedRectangle(cornerRadius: fs * 0.3)
                    .fill(NoteBubble.stroke.opacity(0.35))
                Image(systemName: info == nil ? "photo.badge.exclamationmark" : "photo")
                    .font(.system(size: max(10, fs * 1.6)))
                    .foregroundStyle(NoteBubble.editGlyph)
            }
        }
        .frame(width: box.width, height: box.height)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { onView?() }
        .help(info == nil ? L("Image file is missing (not in this copy, or already cleaned up).") : "")
    }

    private func origin(w: CGFloat, h: CGFloat, fs: CGFloat) -> CGPoint {
        let gap = fs * NoteBubble.gapRatio
        var x = pin.x + pinRadius + gap
        if x + w > pageSize.width { x = pin.x - pinRadius - gap - w }
        let y = pin.y - pinRadius
        return CGPoint(x: min(max(x, 0), max(0, pageSize.width - w)),
                       y: min(max(y, 0), max(0, pageSize.height - h)))
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
    @FocusState private var editorFocused: Bool
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

            TextEditor(text: $caption)
                .font(.body)
                .frame(width: 380, height: 90)
                .focused($editorFocused)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))

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
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
        .frame(width: 420)
        .onAppear { editorFocused = true }
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
