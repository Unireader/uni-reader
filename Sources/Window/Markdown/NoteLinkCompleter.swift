import AppKit
import Combine
import MarkdownEngine

/// 输入 `[[` 时的候选列表（`MARKDOWN-NOTES-PLAN.md §12`；2026-11-12 扩到书 / 书页 / 批注 / 笔记段落，`KNOWLEDGE-LINKS-PLAN.md §3`）。
/// 整页笔记、笔记小窗、批注编辑框、图片笔记说明框都用它。
///
/// 候选三层，按这个顺序排：
///  ① 名字对得上的：笔记、书（`[[书名]]`），以及**同一工作区开着的 PDF 正在看的那一页**（`[[书名#page=N]]`，边看书边记笔记最常用）；
///     打了 `书名#12` / `书名#page=12` 就给那本书的第 12 页；
///  ② 按正文搜出来的（两个字起，走全工作区搜索索引 `SearchIndex`，停手 0.15 秒再查）：书里的某页 → `[[书名#page=N]]`、
///     批注 → `[引文](unireader://…&note=…)`（批注没有名字，用 Markdown 链接，文字取它的前几个字）、笔记里的某一段 → `[[笔记名#标题]]`。
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
    /// 引擎写的「光标正在一条 `[[…]]` 里」：它**只在这个为真时**才把 ↑↓ / 回车 / Esc 交给 `key(_:)`。
    /// 🔴 必须给引擎一个能写的绑定（`isWikiLinkActive:`）——不给就是它的默认常量 false，写不进去，
    /// 方向键一直归编辑器挪光标（2026-11-12 用户报「不能用方向键选择」；`spike/note-link-complete-test.swift` §4）。
    /// 不发布：只给引擎在按键时读，变了不用重算视图。
    var wikiActive = false

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
    /// 候选 id → 选中后写进正文的那段（笔记以外的几种）。
    private var fragments: [String: String] = [:]
    /// 按正文搜到的候选（跟着已打的字变；查询在后台）。
    private var searchHits: [AgentMention] = []
    private var searchedQuery = ""
    private var searchTask: Task<Void, Never>?
    private var indexKicked = false

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
            searchHits = []
            searchedQuery = ""
            searchTask?.cancel()
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
        if candidates == nil { candidates = buildCandidates(ws) }
        let q = Self.query(from: selection.placeholder)
        var list = AgentMentionMatch.rank(candidates ?? [], query: q, limit: 30)
        list = pageCandidates(ws, placeholder: selection.placeholder) + list
        scheduleSearch(ws, query: q)
        let seen = Set(list.map(\.id))
        list += searchHits.filter { !seen.contains($0.id) }
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
                                           storageFragment: fragments[m.id] ?? Self.fragment(for: m.name), isImageEmbedMode: false)
    }

    // MARK: - 候选（`KNOWLEDGE-LINKS-PLAN.md §3`）

    /// 名字层：笔记（按最近打开排，引用源的笔记没有「上次打开」排在后面，不列自己）+ 书库里的书。
    private func buildCandidates(_ ws: WorkspaceManager) -> [AgentMention] {
        fragments = [:]
        let notes = ws.allNotes.filter { $0.ref.key != ownKey }
            .enumerated()
            .sorted {
                let a = $0.element.lastOpenedAt ?? .distantPast, b = $1.element.lastOpenedAt ?? .distantPast
                return a != b ? a > b : $0.offset < $1.offset
            }
            .compactMap { AgentMention.note($0.element, in: ws) }
        let books = ws.documents.sorted { ($0.lastOpenedAt ?? .distantPast) > ($1.lastOpenedAt ?? .distantPast) }.map { d -> AgentMention in
            let id = "book:" + d.id
            fragments[id] = KnowledgeLinks.wikiFragment(bookTitle: d.title, page: nil)
                ?? "[\(Self.linkText(d.title))](\(MCPFacade.shared.link(ws, doc: d.id)))"
            return AgentMention(kind: .pdf, id: id, name: d.title,
                                detail: d.group.isEmpty ? L("Whole book") : "\(L("Whole book")) · \(d.group)", uri: "", symbol: "book.closed")
        }
        return notes + books
    }

    /// 书页：同一工作区开着的 PDF 正在看的那一页（已打的字对得上书名才列）；打了 `书名#12` / `书名#page=12` 就给那一页。
    private func pageCandidates(_ ws: WorkspaceManager, placeholder: String) -> [AgentMention] {
        var inner = placeholder
        if inner.hasPrefix("[[") { inner.removeFirst(2) }
        if inner.hasSuffix("]]") { inner.removeLast(2) }
        let parts = inner.split(separator: "#", maxSplits: 1).map(String.init)
        let nameQ = parts.first?.trimmingCharacters(in: .whitespaces) ?? ""
        var out: [AgentMention] = []
        func add(_ d: LibDocument, page: Int, detail: String) {
            let id = "page:\(d.id):\(page)"
            guard !out.contains(where: { $0.id == id }) else { return }
            fragments[id] = KnowledgeLinks.wikiFragment(bookTitle: d.title, page: page)
                ?? "[\(Self.linkText(d.title)) p.\(page + 1)](\(MCPFacade.shared.link(ws, doc: d.id, page: page + 1)))"
            out.append(AgentMention(kind: .pdf, id: id, name: String(format: L("%@ · page %d"), d.title, page + 1),
                                    detail: detail, uri: "", symbol: "doc.text.magnifyingglass"))
        }
        func matches(_ title: String) -> Bool {
            nameQ.isEmpty || title.range(of: nameQ, options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]) != nil
        }
        // 写了页码：那本书的那一页
        if parts.count == 2 {
            var a = parts[1].trimmingCharacters(in: .whitespaces).lowercased()
            if a.hasPrefix("page=") { a.removeFirst(5) }
            if let n = Int(a), n > 0 {
                for d in ws.documents where matches(d.title) && n <= max(d.pageCount, 1) {
                    add(d, page: n - 1, detail: L("Page in this book"))
                    if out.count >= 5 { break }
                }
                return out
            }
        }
        // 开着的书正在看的页（key 窗口的活动标签排最前）
        for c in AppDelegate.shared?.readerWindowControllers ?? [] where c.workspace === ws {
            for t in c.tabs.tabs {
                guard let id = t.docID, let d = ws.document(id: id), matches(d.title) else { continue }
                add(d, page: t.session.currentPageIndex, detail: L("The page you are reading"))
            }
        }
        return out
    }

    /// 正文层：按已打的字搜全工作区（书页、批注、笔记段落），停手 0.15 秒再查，结果回来再刷新列表。
    private func scheduleSearch(_ ws: WorkspaceManager, query q: String) {
        guard q.count >= 2 else {
            if !searchHits.isEmpty { searchHits = [] }
            searchedQuery = q
            return
        }
        guard q != searchedQuery else { return }
        searchedQuery = q
        searchTask?.cancel()
        guard let id = SearchSources.indexID(ws), let index = try? SearchIndex.shared(workspaceID: id) else { return }
        if !indexKicked {
            // 索引在后台对一遍（不等）：刚改的笔记 / 新加的批注也能搜到
            indexKicked = true
            let sources = SearchSources.all(for: ws)
            Task { _ = await index.refresh(sources, budget: 0, embedder: SemanticSearchSettings.current()) }
        }
        searchTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled else { return }
            let r = await index.keyword(q, filter: .init(kinds: ["pdf", "annotation", "markdown"]), limit: 12)
            await MainActor.run {
                guard let self, !Task.isCancelled, self.searchedQuery == q else { return }
                self.searchHits = r.hits.compactMap { self.mention(for: $0, ws: ws, terms: r.terms) }
                self.refresh()
            }
        }
    }

    private func mention(for h: SearchIndex.Hit, ws: WorkspaceManager, terms: [String]) -> AgentMention? {
        let snippet = SearchText.snippet(h.body, terms: terms, radius: 24)
        switch h.kind {
        case "pdf":
            guard let d = ws.document(id: h.owner), let p = h.page else { return nil }
            let id = "page:\(d.id):\(p)"
            fragments[id] = KnowledgeLinks.wikiFragment(bookTitle: d.title, page: p)
                ?? "[\(Self.linkText(d.title)) p.\(p + 1)](\(MCPFacade.shared.link(ws, doc: d.id, page: p + 1)))"
            return AgentMention(kind: .pdf, id: id, name: String(format: L("%@ · page %d"), d.title, p + 1),
                                detail: snippet, uri: "", symbol: "doc.text.magnifyingglass")
        case "annotation":
            guard let d = ws.document(id: h.owner), let uuid = UUID(uuidString: h.sub) else { return nil }
            let id = "ann:" + h.sub
            let page = h.page.map { $0 + 1 }
            let text = Self.linkText(String(h.body.split(separator: "\n").first ?? "").trimmingCharacters(in: .whitespaces))
            let label = text.count > 24 ? String(text.prefix(24)) + "…" : (text.isEmpty ? L("Annotation") : text)
            fragments[id] = "[\(label)](\(MCPFacade.shared.link(ws, doc: d.id, page: page, note: uuid)))"
            let where_ = page.map { String(format: L("%@ · page %d"), d.title, $0) } ?? d.title
            return AgentMention(kind: .note, id: id, name: label, detail: where_, uri: "",
                                symbol: h.heading == "highlight" ? "highlighter" : (h.heading == "bookmark" ? "bookmark" : "note.text"))
        case "markdown":
            guard h.owner != ownKey, let ref = NoteRef(key: h.owner) else { return nil }
            let id = "sec:\(h.owner):\(h.line ?? 0)"
            let title = ref.title
            let heading = h.heading.trimmingCharacters(in: .whitespaces)
            let safeHeading = heading.isEmpty || heading.contains("[") || heading.contains("]") || heading.contains("|") || heading.contains("#")
            fragments[id] = safeHeading ? Self.fragment(for: title) : "[[\(title)#\(heading)]]"
            return AgentMention(kind: .note, id: id, name: safeHeading ? title : "\(title) › \(heading)", detail: snippet, uri: "",
                                symbol: "text.alignleft")
        default:
            return nil
        }
    }

    /// Markdown 链接文字里不能有方括号（会把链接截断）。
    private static func linkText(_ s: String) -> String {
        s.replacingOccurrences(of: "[", with: "(").replacingOccurrences(of: "]", with: ")").replacingOccurrences(of: "\n", with: " ")
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
