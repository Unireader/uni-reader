import AppKit
import MarkdownEngine
import SwiftUI

/// 笔记正文 / 图片说明的编辑框：`swift-markdown-engine` 的 `NativeTextViewWrapper`（TextKit 2 + AppKit，
/// 用户 2026-09-13 定：Perch 里用过、好用）。**只用在编辑器 sheet 里**——阅读区纯 SwiftUI 的红线不受影响，
/// 页面气泡由 `NoteMarkdown` 把同一份源折成 `Text` 画。
///
/// 存的就是 Markdown 源（`TextNote.text` / `ImageNote.caption` 照旧是 String），编辑器只是所见即所得地画它。
/// 一个 sheet 里一个编辑器，`documentId` 传笔记 id：引擎按它分撤销栈，换一条笔记不会撤到上一条的内容。
struct MarkdownNoteEditor: View {
    @Binding var text: String
    let documentId: String
    var placeholder: String = ""
    /// 正文字号：设置 → 阅读 →「编辑框字号」（默认 13；气泡默认 12，编辑时略大一点看得清）。
    @AppStorage(NoteBubble.editorFontSizeKey) private var fontSizeSetting = Int(NoteBubble.defaultEditorFont)
    private var fontSize: CGFloat { CGFloat(fontSizeSetting) }

    /// 引擎配置：小编辑框，不要「舒适的底部留白」（那是给整页长文档设计的，160pt 高的框里会空出一半），
    /// 只留竖滚动条；文字与边框之间留 6pt。
    static let configuration: MarkdownEditorConfiguration = {
        var c = MarkdownEditorConfiguration.default
        c.overscroll = OverscrollPolicy(percent: 0, maxPoints: 8, minPoints: 8)
        c.scrollers = .vertical
        c.textInsets = TextInsets(horizontal: 6, vertical: 6)
        Self.applyNoteTypography(&c)
        return c
    }()

    /// 笔记的排版尺度（编辑器与气泡共用）：引擎默认是给整页文档定的——一级标题 2 倍字号、列表每级缩进 27.5pt，
    /// 放进几行字的笔记里太夸张。标题只比正文大一点、缩进收到 16pt。
    static func applyNoteTypography(_ c: inout MarkdownEditorConfiguration) {
        c.headings.fontMultipliers = [1.4, 1.25, 1.12, 1.05, 1.0, 1.0]
        c.headings.topSpacingEm = [0.3, 0.25, 0.2, 0.15, 0.1, 0.1]
        c.lists.indentPerLevel = 16
    }

    var body: some View {
        NativeTextViewWrapper(text: $text,
                              configuration: Self.configuration,
                              fontSize: fontSize,
                              documentId: documentId,
                              placeholder: placeholder.isEmpty ? nil : NSAttributedString(
                                  string: placeholder,
                                  attributes: [.foregroundColor: NSColor.placeholderTextColor,
                                               .font: NSFont.systemFont(ofSize: fontSize)]))
            // 引擎自己不画底（drawsBackground = false），底色与边框按系统文本框的样子补上
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
            .onAppear { Self.focusEditor() }
    }

    /// 气泡里的正文（`MarkdownNoteReader`）用的固定浅色主题：气泡永远是纸白底（夜间也是），字色得钉死，
    /// 不能跟系统外观走——`.labelColor` 在深色外观下是白字，压在纸白上就没了。
    static let readerTheme: MarkdownEditorTheme = {
        var t = MarkdownEditorTheme.default
        t.bodyText = NSColor(red: 0.12, green: 0.12, blue: 0.13, alpha: 1)      // = NoteBubble.ink
        t.mutedText = NSColor(white: 0.42, alpha: 1)
        t.disabledText = NSColor(white: 0.6, alpha: 1)
        t.headingMarker = NSColor(white: 0.55, alpha: 1)
        t.strikethroughColor = t.bodyText
        t.link = NSColor.systemBlue
        t.incompleteLink = NSColor.systemBlue
        return t
    }()

    /// 打开编辑器就把光标放进去（原来 `TextEditor` 走 `@FocusState`；AppKit 视图得自己找第一响应者）。
    /// sheet 一出来它就是 key 窗口；在里面找那个可编辑的 `NSTextView`。延一拍：`onAppear` 时视图树还没挂到窗口上。
    static func focusEditor() {
        DispatchQueue.main.async {
            guard let window = NSApp.keyWindow, let root = window.contentView,
                  let tv = firstEditableTextView(in: root) else { return }
            window.makeFirstResponder(tv)
        }
    }

    private static func firstEditableTextView(in view: NSView) -> NSTextView? {
        if let tv = view as? NSTextView, tv.isEditable { return tv }
        for sub in view.subviews {
            if let hit = firstEditableTextView(in: sub) { return hit }
        }
        return nil
    }
}

// MARK: - 只读渲染（气泡里的正文）

/// 笔记正文 / 图片说明在**页面气泡**里的渲染：同一个引擎、`isEditable: false`（用户 2026-09-13 定：
/// 「气泡渲染最好也用这个，关闭编辑即可」——纯 SwiftUI `Text` 的近似渲染效果不好）。
///
/// 🔴 这是阅读区里**唯一的 AppKit 视图**（红线「阅读区纯 SwiftUI」的例外，用户拍板）。限定在气泡正文这一块；
/// 滚动/缩放面本身仍是 SwiftUI。几条要守住：
///  · `heightBehavior = .fitsContent`：高度由内容定、不内滚；引擎在这个模式下把滚轮事件交给下一响应者，
///    鼠标停在气泡上照样能滚阅读区；
///  · 外观钉死浅色（`.environment(\.colorScheme, .light)` → 引擎视图的 `NSAppearance` 跟着变）：气泡永远是纸白底；
///  · 字号跟页缩放那种口径下每帧都在变，引擎每次都要重排——按 0.5pt 取整，少触发几次。
struct MarkdownNoteReader: View {
    let text: String
    let fontSize: CGFloat
    /// 引擎按它分状态（撤销栈/待替换）；同一条笔记在编辑器里是笔记 id，气泡里用 `<id>-bubble` 错开。
    let documentId: String

    static let configuration: MarkdownEditorConfiguration = {
        var c = MarkdownEditorConfiguration.default
        c.theme = MarkdownNoteEditor.readerTheme
        c.heightBehavior = .fitsContent
        c.overscroll = OverscrollPolicy(percent: 0, maxPoints: 0, minPoints: 0)
        c.scrollers = .hidden
        c.textInsets = TextInsets(horizontal: 0, vertical: 0)
        c.spellChecking = SpellCheckingPolicy(continuousSpellChecking: false, grammarChecking: false,
                                              automaticSpellingCorrection: false)
        MarkdownNoteEditor.applyNoteTypography(&c)
        return c
    }()

    var body: some View {
        NativeTextViewWrapper(text: .constant(text),
                              configuration: Self.configuration,
                              fontSize: (fontSize * 2).rounded() / 2,
                              documentId: documentId,
                              isEditable: false,
                              onLinkClick: { link in
                                  if let url = URL(string: link) { NSWorkspace.shared.open(url) }
                              })
            .environment(\.colorScheme, .light)
    }
}
