import AppKit
import MarkdownEngine
import SwiftUI

/// 整篇 Markdown 笔记的编辑区（`MARKDOWN-NOTES-PLAN.md §5` 第二批）。
///
/// 与 `MarkdownNoteEditor` 的区别只在**排版尺度**：那个是 PDF 批注用的小框（标题只比正文大一点、
/// 底部不留白、缩进收窄），这个是整页文档（引擎默认的标题层级、居中阅读栏、舒适的底部留白）。
/// 引擎、公式渲染器、`[[…]]` 服务都是同一套。
///
/// 允许 SwiftUI 的第三处——理由同前两处：引擎只公开了 SwiftUI 包装（`NativeTextViewWrapper`），
/// 由 `MarkdownDocView` 用 `NSHostingView` 托管。
struct MarkdownDocEditor: View {
    @Binding var text: String
    /// 引擎按它分撤销栈：一篇笔记一条，切走再切回来撤销历史还在。
    let documentId: String
    let wiki: WorkspaceWikiIndex?
    /// 点了 `[[…]]`：参数是目标笔记 id（引擎从存储形态的竖线后面取出来的）。
    var onOpenNote: (String) -> Void = { _ in }

    @AppStorage(NoteBubble.editorFontSizeKey) private var fontSizeSetting = Int(NoteBubble.defaultEditorFont)
    private var fontSize: CGFloat { CGFloat(fontSizeSetting) + 2 }   // 整页阅读比批注小框再大一点

    @State private var boxWidth: CGFloat = 0
    private var containerWidth: CGFloat {
        guard boxWidth > 0 else { return 0 }
        return min(boxWidth, Self.readingWidth) - Self.inset * 2
    }

    /// 居中阅读栏宽度（引擎的 `readingWidth`）：整窗铺开的一行字太长，读不动。
    static let readingWidth: CGFloat = 760
    static let inset: CGFloat = 24

    static let configuration: MarkdownEditorConfiguration = {
        var c = MarkdownEditorConfiguration.default
        c.readingWidth = readingWidth
        c.scrollers = .vertical
        c.textInsets = TextInsets(horizontal: inset, vertical: inset)
        c.services.latex = NoteLatexRenderer.shared
        return c
    }()

    private var configuration: MarkdownEditorConfiguration {
        var c = Self.configuration
        if let wiki { c.services.wikiLinks = wiki; c.services.images = wiki }
        return c
    }

    var body: some View {
        NoteLatexRenderer.shared.registerBlocks(in: text)   // 块公式按块排版（同气泡/批注框，见 `NoteLatexRenderer`）
        return NativeTextViewWrapper(text: $text,
                                     configuration: configuration.fittingLatex(to: containerWidth),
                                     fontSize: fontSize,
                                     documentId: documentId,
                                     onLinkClick: { onOpenNote($0) },
                                     placeholder: NSAttributedString(
                                         string: L("Write in Markdown. Type [[ to link another note."),
                                         attributes: [.foregroundColor: NSColor.placeholderTextColor,
                                                      .font: NSFont.systemFont(ofSize: fontSize)]))
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { boxWidth = $0 }
    }
}
