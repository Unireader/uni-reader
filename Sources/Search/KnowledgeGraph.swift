import Foundation

/// 知识关联的读取（`KNOWLEDGE-LINKS-PLAN.md §4`）：「关联」面板与 MCP `links` 共用。
///
/// 链接本身原样存在搜索索引的 `edge` 表里（笔记 / 批注重建时顺手记下）；这里先把**笔记与批注两类来源**对一遍账
/// （不碰 PDF 页文字，那要读整本书），再按**此刻**的笔记清单与书单解析成「从哪 → 到哪」——改了名、导入了新书都不用重建。
/// 正在编辑的那篇 / 正在看的那页，链出去的用**实时正文**算（没存盘的输入也算），别的从索引来。
enum KnowledgeGraph {

    struct Link: Hashable {
        /// 链接写在哪：`.note`（笔记）或 `.annotation`（批注，带它所在的页）。
        var from: LinkTarget
        /// 指到哪；nil = 解析不到（断了）。
        var to: LinkTarget?
        var line: Int?
        var raw: String
        var context: String
    }

    /// 解析要用的东西（在主线程抄下来，解析本身在哪都行）。
    struct Context: Sendable {
        var index: NoteIndex
        var noteKeys: Set<String>
        var rowIDs: [String: String]
    }

    @MainActor
    static func context(_ ws: WorkspaceManager) -> Context {
        var rows: [String: String] = [:]
        for n in ws.allNotes { if let r = n.rowID { rows[r] = n.ref.key } }
        return Context(index: ws.wiki.snapshot(), noteKeys: Set(ws.allNotes.map(\.ref.key)), rowIDs: rows)
    }

    static func resolve(_ o: KnowledgeLinks.Occurrence, _ ctx: Context) -> LinkTarget? {
        KnowledgeLinks.resolve(o, index: ctx.index, noteKeys: ctx.noteKeys, rowIDs: ctx.rowIDs)
    }

    /// 一段正文（实时的）链出去的。
    static func outgoing(text: String, from: LinkTarget, line offset: Int = 0, _ ctx: Context) -> [Link] {
        KnowledgeLinks.occurrences(in: text).map {
            Link(from: from, to: resolve($0, ctx), line: offset == 0 ? $0.line : nil, raw: $0.raw, context: $0.context)
        }
    }

    /// 索引里的全部链接（先把笔记与批注对一遍账，最多等 `wait` 秒），按当前清单解析。
    @MainActor
    static func load(_ ws: WorkspaceManager, wait: TimeInterval) async -> [Link] {
        guard let id = SearchSources.indexID(ws), let index = try? SearchIndex.shared(workspaceID: id) else { return [] }
        let sources = SearchSources.all(for: ws, kinds: ["md", "ann"])
        let ctx = context(ws)
        // 单独那一路：不排在全量建索引后面（`SearchIndex.refreshLinks` 的注释）
        let complete = await index.refreshLinks(sources, prefixes: ["md:", "ann:"], budget: wait)
        let edges = await index.allEdges()
        let links: [Link] = await Task.detached(priority: .userInitiated) {
            edges.compactMap { e -> Link? in
                let from: LinkTarget
                if e.fromKind == "markdown" {
                    guard let r = NoteRef(key: e.fromOwner) else { return nil }
                    from = .note(r)
                } else {
                    from = .annotation(documentId: e.fromOwner, id: e.fromSub, page: e.fromPage)
                }
                let o = KnowledgeLinks.Occurrence(kind: e.kind == "wiki" ? .wiki : .url, target: e.target, raw: e.raw,
                                                  line: e.fromLine ?? 0, context: e.context)
                return Link(from: from, to: resolve(o, ctx), line: e.fromLine, raw: e.raw, context: e.context)
            }
        }.value
        wsLog("[关联] 读链接：\(edges.count) 条，认出 \(links.filter { $0.to != nil }.count) 条，书单 \(ctx.index.documentTable.count) 本，对账\(complete ? "完成" : "未完（后台接着）")")
        return links
    }

    /// 指到「这一篇笔记」的（不算它自己链自己）。
    static func backlinks(_ links: [Link], note ref: NoteRef) -> [Link] {
        links.filter { $0.to == .note(ref) && $0.from != .note(ref) }
    }

    /// 指到「这本书的这一页」的：直接链这一页的，加上链到这一页上某条批注的（`annotationIDs` = 这一页上的批注）。
    static func toPage(_ links: [Link], documentId d: String, page p: Int, annotationIDs: Set<String>) -> [Link] {
        links.filter { l in
            switch l.to {
            case .document(d, p)?: return true
            case .annotation(d, let a, let pg)?: return annotationIDs.contains(a.uppercased()) || pg == p
            default: return false
            }
        }
    }

    /// 指到整本书的（`[[书名]]`，不带页）。
    static func toBook(_ links: [Link], documentId d: String) -> [Link] {
        links.filter { $0.to == .document(id: d, page: nil) }
    }

    /// 指到某条批注的。
    static func toAnnotation(_ links: [Link], id: String) -> [Link] {
        links.filter { if case .annotation(_, let a, _)? = $0.to { return a.uppercased() == id.uppercased() }; return false }
    }
}
