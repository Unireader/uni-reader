import CryptoKit
import Foundation

/// 一个工作区里要进搜索索引的东西（`SEARCH-PLAN.md §2`）。在主线程上只抄下清单（文档 id / 标题 / 文件位置 / 笔记文件），
/// 指纹和读内容都包进闭包，留给索引在自己的线程上做。
@MainActor
enum SearchSources {

    /// 这个工作区的索引身份：库里的 `workspace_id`（换路径、换盘都不变）；老库没有就按路径算一个。
    static func indexID(_ ws: WorkspaceManager) -> String? {
        if let id = ws.store?.workspaceId { return id }
        guard let p = ws.folder?.standardizedFileURL.path else { return nil }
        return "path-" + SHA256Hex.of(p).prefix(16)
    }

    /// `kinds` = 只要这几类来源（`pdf` / `ann` / `md` / `ex` / `ctx`）；nil = 全部。「关联」只要 `md` + `ann`。
    static func all(for ws: WorkspaceManager, kinds: Set<String>? = nil) -> [SearchIndex.Source] {
        guard let store = ws.store else { return [] }
        var out: [SearchIndex.Source] = []
        let provider = OCRBackend.current.providerID
        func want(_ k: String) -> Bool { kinds?.contains(k) ?? true }

        // PDF 每页文字 + 每本书的批注
        for d in ws.documents {
            let id = d.id, title = d.title
            if want("ann") {
                out.append(.init(key: "ann:\(id)", title: title, stamp: {
                    annotationStamp(store: store, documentId: id)
                }, loadAll: { annotationChunks(store: store, documentId: id, title: title) }))
            }
            guard want("pdf") else { continue }
            let f = MCPFacade.shared.fileInfo(ws, documentId: d.id)
            let pages = d.pageCount, hash = f.hash, path = f.exists ? f.path : nil
            out.append(.init(key: "pdf:\(id)", title: title, stamp: {
                let ocr = (try? store.ocrStamp(contentHash: hash, provider: provider)) ?? ""
                return "\(hash)|\(provider)|\(ocr)|\(path == nil ? 0 : 1)"
            }, load: { await pdfChunks(store: store, id: id, title: title, hash: hash, path: path, pageCount: pages) }))
        }

        // Markdown 笔记（内建 Notes/ 与引用目录）
        for n in ws.allNotes where want("md") {
            guard let url = ws.noteURL(n.ref) else { continue }
            let key = n.ref.key, title = n.title
            out.append(.init(key: "md:\(key)", title: title, stamp: {
                let a = try? FileManager.default.attributesOfItem(atPath: url.path)
                let t = (a?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
                return "\(t)|\((a?[.size] as? NSNumber)?.int64Value ?? -1)"
            }, loadAll: {
                guard let text = MarkdownImport.readText(url) else { return .init(chunks: []) }
                let chunks = SearchText.markdownChunks(text).map {
                    SearchIndex.Chunk(kind: "markdown", owner: key, line: $0.line, title: title, heading: $0.heading, body: $0.text)
                }
                // 笔记里的链接（`KNOWLEDGE-LINKS-PLAN.md §4`）：原样记，读的时候再解析
                let edges = KnowledgeLinks.occurrences(in: text).map {
                    SearchIndex.Edge(fromKind: "markdown", fromOwner: key, fromLine: $0.line,
                                     kind: $0.kind == .wiki ? "wiki" : "url", target: $0.target, raw: $0.raw, context: $0.context)
                }
                return .init(chunks: chunks, edges: edges)
            }))
        }

        // 习题、Agent 上下文：整个工作区各一个来源（条数 + 最新修改时间当指纹）
        let docTitles = Dictionary(ws.documents.map { ($0.id, $0.title) }, uniquingKeysWith: { a, _ in a })
        guard want("ex") || want("ctx") else { return out }
        if want("ex") { out.append(.init(key: "ex:all", title: "exercises", stamp: {
            let rows = (try? store.exercises()) ?? []
            return "\(rows.count)|\(rows.map(\.updatedAt).max()?.timeIntervalSince1970 ?? 0)"
        }, load: { exerciseChunks(store: store, docTitles: docTitles) })) }
        guard want("ctx") else { return out }
        out.append(.init(key: "ctx:all", title: "agent contexts", stamp: {
            let rows = (try? store.agentContexts()) ?? []
            return "\(rows.count)|\(rows.map(\.updatedAt).max()?.timeIntervalSince1970 ?? 0)"
        }, load: {
            ((try? store.agentContexts()) ?? []).flatMap { c in
                SearchText.chunks(c.title + "\n\n" + c.summary).map {
                    SearchIndex.Chunk(kind: "context", owner: c.id, title: c.title, heading: c.agent, body: $0)
                }
            }
        }))
        return out
    }

    // MARK: - 各类内容 → 块（都在索引的线程上跑）

    /// 每页：OCR 文字优先（滤过水印，与 `read_pages` 同一套），没 OCR 的页用 PDF 自带文字。
    nonisolated static func pdfChunks(store: LibraryStore, id: String, title: String, hash: String, path: String?,
                                      pageCount: Int) async -> [SearchIndex.Chunk] {
        guard pageCount > 0 else { return [] }
        let all = Array(0..<pageCount)
        var texts = await MCPDocReader.shared.ocrTexts(store: store, contentHash: hash, pages: all)
        let missing = all.filter { (texts[$0]?.count ?? 0) < 8 }
        // 没 OCR 的页取 PDF 自带文字。每 40 页一批：读 PDF 的队列与 `read_pages` / `render_page` 共用，别让建索引一口气占住几十秒
        if let path {
            for start in stride(from: 0, to: missing.count, by: 40) {
                let batch = Array(missing[start..<min(start + 40, missing.count)])
                guard let native = try? await MCPDocReader.shared.nativeTexts(path: path, pages: batch) else { break }
                for p in native where !p.native.isEmpty { texts[p.index] = p.native }
            }
        }
        var out: [SearchIndex.Chunk] = []
        for i in all {
            guard let t = texts[i] else { continue }
            for c in SearchText.chunks(t) {
                out.append(.init(kind: "pdf", owner: id, page: i, title: title, body: c))
            }
        }
        return out
    }

    private static let annotationKinds = [TextNote.noteKind, Highlight.noteKind, Bookmark.noteKind, ImageNote.noteKind]

    nonisolated static func annotationStamp(store: LibraryStore, documentId: String) -> String {
        var n = 0, latest = 0.0
        for k in annotationKinds {
            let rows = (try? store.notes(documentId: documentId, kind: k)) ?? []
            n += rows.count
            latest = max(latest, rows.map(\.updatedAt.timeIntervalSince1970).max() ?? 0)
        }
        return "\(n)|\(latest)"
    }

    nonisolated static func annotationChunks(store: LibraryStore, documentId: String, title: String) -> SearchIndex.Loaded {
        var out: [SearchIndex.Chunk] = []
        var edges: [SearchIndex.Edge] = []
        func add(_ id: UUID, _ kind: String, _ page: Int, _ body: String) {
            let b = body.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !b.isEmpty else { return }
            out.append(.init(kind: "annotation", owner: documentId, sub: id.uuidString, page: page, title: title, heading: kind, body: b))
        }
        /// 批注正文 / 图片说明里的链接（原文引用是 PDF 上的字，不看）
        func links(_ id: UUID, _ page: Int, _ text: String) {
            edges += KnowledgeLinks.occurrences(in: text).map {
                SearchIndex.Edge(fromKind: "annotation", fromOwner: documentId, fromSub: id.uuidString, fromPage: page,
                                 kind: $0.kind == .wiki ? "wiki" : "url", target: $0.target, raw: $0.raw, context: $0.context)
            }
        }
        for r in (try? store.notes(documentId: documentId, kind: TextNote.noteKind)) ?? [] {
            if let n = TextNote(note: r) {
                add(n.id, "note", n.page, [n.quote, n.text].filter { !$0.isEmpty }.joined(separator: "\n"))
                links(n.id, n.page, n.text)
            }
        }
        for r in (try? store.notes(documentId: documentId, kind: Highlight.noteKind)) ?? [] {
            if let h = Highlight(note: r) { add(h.id, "highlight", h.page, h.quote) }
        }
        for r in (try? store.notes(documentId: documentId, kind: Bookmark.noteKind)) ?? [] {
            if let b = Bookmark(note: r) { add(b.id, "bookmark", b.page, b.title) }
        }
        for r in (try? store.notes(documentId: documentId, kind: ImageNote.noteKind)) ?? [] {
            if let m = ImageNote(note: r) {
                add(m.id, "image_note", m.page, m.caption)
                links(m.id, m.page, m.caption)
            }
        }
        return .init(chunks: out, edges: edges)
    }

    nonisolated static func exerciseChunks(store: LibraryStore, docTitles: [String: String]) -> [SearchIndex.Chunk] {
        ((try? store.exercises()) ?? []).compactMap { row -> SearchIndex.Chunk? in
            guard let e = Exercise(row: row) else { return nil }
            var parts = [e.payload.stem]
            parts += e.payload.options.map { "\($0.key). \($0.text)" }
            if !e.payload.answer.isEmpty { parts.append("答案 Answer: " + e.payload.answer.joined(separator: ", ")) }
            if let x = e.payload.explanation, !x.isEmpty { parts.append(x) }
            if !e.note.isEmpty { parts.append(e.note) }
            if !e.tags.isEmpty { parts.append(e.tags.map { "#\($0)" }.joined(separator: " ")) }
            let docTitle = e.documentId.flatMap { docTitles[$0] } ?? ""
            let number = e.number.isEmpty ? "" : "\(e.number) "
            return .init(kind: "exercise", owner: e.id, sub: e.documentId.map { "doc:\($0)" } ?? "", page: e.page,
                         title: docTitle.isEmpty ? number.trimmingCharacters(in: .whitespaces) : "\(docTitle) · \(number)".trimmingCharacters(in: .whitespaces),
                         heading: (e.chapter + [e.section]).filter { !$0.isEmpty }.joined(separator: " › "),
                         body: parts.filter { !$0.isEmpty }.joined(separator: "\n"))
        }
    }
}

enum SHA256Hex {
    static func of(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

