import AppKit
import Combine
import MarkdownEngine

/// 整页 Markdown 笔记里输入 `[[` 时的候选列表（`MARKDOWN-NOTES-PLAN.md §12`）。
///
/// 引擎把该给的都给了：光标在一条正在打字的 `[[…]]` 里（`onInlineSelectionChange`）、那一处在哪（`onCaretRectChange`）、
/// ↑↓ / 回车 / Esc（`onInlinePreviewKey`）、把选中的写回去（`pendingInlineReplacement`）。这里只做三件事：
/// 按已经打的字从工作区的笔记里挑候选、摆出列表（与 Agent 输入框 `@` 的候选是同一块 `AgentMentionPopup`：
/// 不抢焦点的子窗口，系统菜单材质）、选中后把整条换成 `[[笔记名]]`。
///
/// 🔴 写回去的只有**用户此刻正在打的那一条**（红线 9：自动维护不改正文；这是用户自己的编辑）。写的是名字、不带 `|id`
/// （按名字解析，见 `WorkspaceWikiIndex`）。
///
/// 这个对象的身份在一份编辑区的一生里不变——引擎的回调只在建协调器时捕获一次（`PITFALLS.md` 那条 `LinkRelay` 的坑），
/// 所以回调闭包里只抓它、活状态都放在它身上。
@MainActor
final class NoteLinkCompleter: ObservableObject {
    /// 交给引擎的替换请求（`MarkdownDocEditor` 绑着它，引擎应用后清空）。
    @Published var pending: InlineReplacementRequest?

    private weak var workspace: WorkspaceManager?
    private let documentId: String
    /// 正在编辑的这一篇的 `NoteRef.key`（候选里不列自己）。改名后由 `MarkdownDocView.noteMoved` 换成新的。
    var ownKey: String
    /// 托管编辑区的视图：从它底下找引擎的滚动视图，把光标矩形换成屏幕坐标。
    weak var host: NSView?

    private let popup = AgentMentionPopup()
    private var selection: WikiLinkSelection?
    private var rect: CGRect?
    /// 这一条 `[[…]]` 上按过 Esc：光标离开它之前不再弹。
    private var dismissed = false
    /// 候选只在一次弹出期间取一遍（不是每敲一个字扫一遍工作区）。
    private var candidates: [AgentMention]?

    init(workspace: WorkspaceManager, documentId: String, ownKey: String) {
        self.workspace = workspace
        self.documentId = documentId
        self.ownKey = ownKey
        popup.onPick = { [weak self] in self?.pick($0) }
    }

    /// 引擎：光标进了 / 出了一条 `[[…]]`（只在**打字**时才报进入，点进一条现成的链接不报）。
    func selectionChanged(_ state: InlineSelectionState?) {
        guard let state, state.kind == .wikiLink else {
            selection = nil
            dismissed = false
            candidates = nil
            popup.hide()
            return
        }
        selection = state.selection
        refresh()
    }

    /// 引擎：那一处的位置变了（滚动视图可见区坐标，y 向下）。
    func caretRectChanged(_ r: CGRect) {
        rect = r
        refresh()
    }

    /// 引擎：列表开着时的 ↑ ↓ / 回车 / Esc。返回 true = 这一下归列表。
    func key(_ k: InlinePreviewKey) -> Bool {
        guard popup.isShown else { return false }
        switch k {
        case .moveUp: popup.move(-1)
        case .moveDown: popup.move(1)
        case .confirm, .confirmAndOpen:
            guard let m = popup.selectedItem else { return false }
            pick(m)
        case .cancel:
            dismissed = true
            popup.hide()
        }
        return true
    }

    /// 编辑区要拆了 / 切走了。
    func close() {
        selection = nil
        popup.hide()
    }

    /// `[[名字` 里已经打的那一段（竖线 / 井号后面的是别名与小节，不参与找笔记）。
    /// 引擎给的占位文字是**整条**（`[[ab]]`，括号是它自动配对补上的；`spike/note-link-complete-test.swift` 实测），先剥掉方括号。
    static func query(from placeholder: String) -> String {
        var q = placeholder
        if q.hasPrefix("[[") { q.removeFirst(2) }
        if q.hasSuffix("]]") { q.removeLast(2) }
        for sep in ["|", "#"] { if let i = q.range(of: sep) { q = String(q[..<i.lowerBound]) } }
        return q.trimmingCharacters(in: .whitespaces)
    }

    /// 选中一篇之后写进正文的那一段。
    static func fragment(for fileName: String) -> String {
        "[[" + MarkdownImport.dropExt(fileName) + "]]"
    }

    private func refresh() {
        guard !dismissed, let selection, let rect, let ws = workspace, let host, let window = host.window,
              let scroll = Self.editorScrollView(in: host) else { popup.hide(); return }
        if candidates == nil {
            // 按最近打开排（引用源的笔记没有「上次打开」，排在后面），不列自己
            candidates = ws.allNotes.filter { $0.ref.key != ownKey }
                .enumerated()
                .sorted {
                    let a = $0.element.lastOpenedAt ?? .distantPast, b = $1.element.lastOpenedAt ?? .distantPast
                    return a != b ? a > b : $0.offset < $1.offset
                }
                .compactMap { AgentMention.note($0.element, in: ws) }
        }
        let list = AgentMentionMatch.rank(candidates ?? [], query: Self.query(from: selection.placeholder), limit: 30)
        guard !list.isEmpty else { popup.hide(); return }
        // 引擎给的是「文档坐标 − 滚动偏移」；加回偏移 = 剪裁视图自己的坐标，再换到屏幕
        let clip = scroll.contentView
        let inClip = rect.offsetBy(dx: clip.bounds.origin.x, dy: clip.bounds.origin.y)
        let anchor = window.convertToScreen(clip.convert(inClip, to: nil))
        popup.show(list, anchor: anchor, parent: window, below: true)
    }

    private func pick(_ m: AgentMention) {
        guard let selection else { return }
        popup.hide()
        pending = InlineReplacementRequest(documentId: documentId, selection: selection,
                                           storageFragment: Self.fragment(for: m.name), isImageEmbedMode: false)
    }

    /// 引擎的编辑区是一个 `NSScrollView`（`NativeTextViewWrapper.NSViewType`），里面装着 `NSTextView`。
    private static func editorScrollView(in root: NSView) -> NSScrollView? {
        for v in root.subviews {
            if let s = v as? NSScrollView, Self.containsTextView(s) { return s }
            if let hit = editorScrollView(in: v) { return hit }
        }
        return nil
    }

    private static func containsTextView(_ v: NSView) -> Bool {
        v is NSTextView || v.subviews.contains { containsTextView($0) }
    }
}
