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
    /// 要不要居中阅读栏。**必须在这份编辑器创建前就定死**：引擎把 `readingWidth` 换算成的
    /// `textContainer` 宽度只在 `makeNSView` 那一次生效，后续 `updateNSView` 不会再跟着改
    /// （`swift-markdown-engine` 的 `NativeTextViewWrapper` 明确设计成「wrap 宽度定了就不再变」）。
    /// 所以不能按运行时量出来的容器宽度动态切换（试过，无效——小窗仍按旧宽度排版，见下）：
    /// 笔记小窗（`MarkdownDocView(showsHeader: false)`）默认 460pt、可缩到 280pt，常年比 760pt 阅读栏窄，
    /// 干脆从一开始就不用这个模式，直接按视口宽度折行（同 `AgentMarkdownView` 窄面板的做法）；
    /// 标签页里的整页阅读保留居中阅读栏（2026-09-24 用户报「小窗没有 wrap，也没法滚动」，
    /// 第一版改法按测得宽度动态传 `readingWidth = nil` 没生效，才查到这条创建即定死的限制）。
    var usesReadingColumn: Bool = true
    /// 点了 `[[…]]`：参数是目标笔记 id（引擎从存储形态的竖线后面取出来的）。
    var onOpenNote: (String) -> Void = { _ in }
    /// 滚动位置的记忆（切标签会把整个编辑区拆掉重建，引擎自己记的偏移跟着没了，由上层存）。
    var onPersistScrollOffset: ((String, CGFloat) -> Void)?
    var restoreScrollOffset: ((String) -> CGFloat?)?

    @AppStorage(NoteBubble.editorFontSizeKey) private var fontSizeSetting = Int(NoteBubble.defaultEditorFont)
    private var fontSize: CGFloat { CGFloat(fontSizeSetting) + 2 }   // 整页阅读比批注小框再大一点

    @State private var boxWidth: CGFloat = 0
    private var containerWidth: CGFloat {
        guard boxWidth > 0 else { return 0 }
        guard usesReadingColumn else { return max(boxWidth - Self.inset * 2, 0) }
        return min(boxWidth, Self.readingWidth) - Self.inset * 2
    }

    /// 居中阅读栏宽度（引擎的 `readingWidth`）：整窗铺开的一行字太长，读不动。
    static let readingWidth: CGFloat = 760
    static let inset: CGFloat = 24

    static let configuration: MarkdownEditorConfiguration = {
        var c = MarkdownEditorConfiguration.default
        c.scrollers = .vertical
        c.textInsets = TextInsets(horizontal: inset, vertical: inset)
        c.services.latex = NoteLatexRenderer.shared
        return c
    }()

    private var configuration: MarkdownEditorConfiguration {
        var c = Self.configuration
        c.readingWidth = usesReadingColumn ? Self.readingWidth : nil
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
                                                      .font: NSFont.systemFont(ofSize: fontSize)]),
                                     onPersistScrollOffset: onPersistScrollOffset,
                                     restoreScrollOffset: restoreScrollOffset)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { boxWidth = $0 }
    }
}
