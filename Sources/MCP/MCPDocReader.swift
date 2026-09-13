import Foundation
import PDFKit

/// 离主线程读 PDF（方案 §5.1 `MCPDocReader` / §5.3 第 1 条）：
/// 🔴 `session.pdf` 只许主线程碰，所以这里**按路径另开一份 `PDFDocument`**，LRU 缓存 4 份，
/// 全部工作在自己的串行队列 `mcp.doc` 上。它只读文件、不持有会话，文档/工作区关闭时不必同步清。
final class MCPDocReader {
    static let shared = MCPDocReader()

    private let queue = DispatchQueue(label: "tech.xvanturing.unireader.mcp.doc", qos: .userInitiated)

    private struct Entry { let doc: PDFDocument; var lastUsed: CFAbsoluteTime }
    private var docs: [String: Entry] = [:]          // path → 文档（只在 queue 上碰）
    private let maxDocs = 4

    /// OCR 文本层缓存：内容 hash → (各页行, 水印指纹)。读一本书的全部 OCR 页要几 MB，别每次调用都读。
    private struct OCRBook { let pages: [Int: [TextRun]]; let profile: OCRWatermark.Profile; var lastUsed: CFAbsoluteTime }
    private var ocrBooks: [String: OCRBook] = [:]
    private let maxOCRBooks = 2

    /// 判「这一页有没有原生文本」的门槛（与 `NativePDFTextProvider.isLikelyScanned` 同一条）。
    static let nativeMinChars = 8

    // MARK: - 队列

    /// 在 `mcp.doc` 队列上拿到（或打开）文档再干活。文件打不开抛 `MCPToolError`。
    func withDocument<T>(path: String, _ body: @escaping (PDFDocument) throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { cont in
            queue.async {
                do {
                    let doc = try self.open(path)
                    cont.resume(returning: try body(doc))
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    private func open(_ path: String) throws -> PDFDocument {
        let now = CFAbsoluteTimeGetCurrent()
        if var e = docs[path] {
            e.lastUsed = now; docs[path] = e
            return e.doc
        }
        guard FileManager.default.fileExists(atPath: path) else {
            throw MCPToolError("file not found: \(path)")
        }
        guard let doc = PDFDocument(url: URL(fileURLWithPath: path)) else {
            throw MCPToolError("cannot open PDF: \(path)")
        }
        if docs.count >= maxDocs, let victim = docs.min(by: { $0.value.lastUsed < $1.value.lastUsed })?.key {
            docs.removeValue(forKey: victim)
        }
        docs[path] = Entry(doc: doc, lastUsed: now)
        return doc
    }

    // MARK: - 文本

    struct PageText {
        let index: Int          // 内部 0 起
        let label: String?      // 书自己印的页码（与序号不同才给）
        let native: String      // 原生文本（可能为空）
    }

    /// 若干页的原生文本（`PDFPage.string`）。
    func nativeTexts(path: String, pages: [Int]) async throws -> [PageText] {
        try await withDocument(path: path) { doc in
            pages.map { i in
                let page = doc.page(at: i)
                let text = page?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return PageText(index: i, label: Self.label(of: page, index: i), native: text)
            }
        }
    }

    /// 抽样：前 `count` 页里有几页有原生文本（`get_document.text`，让 Agent 知道这本能不能直接读字）。
    func nativeSample(path: String, count: Int) async throws -> (sampled: Int, withText: Int) {
        try await withDocument(path: path) { doc in
            let n = min(count, doc.pageCount)
            var withText = 0
            for i in 0..<n where (doc.page(at: i)?.string?.trimmingCharacters(in: .whitespacesAndNewlines).count ?? 0) >= Self.nativeMinChars {
                withText += 1
            }
            return (n, withText)
        }
    }

    struct Summary {
        let pageCount: Int
        let firstPageSize: CGSize
        let toc: [TOCEntry]
    }

    /// 页数、首页尺寸、目录树（`TOCEntry.build` 与阅读区同一份实现）。
    func summary(path: String, includeTOC: Bool) async throws -> Summary {
        try await withDocument(path: path) { doc in
            let size = doc.page(at: 0).map { PageBitmap.displaySize($0) } ?? .zero
            return Summary(pageCount: doc.pageCount, firstPageSize: size, toc: includeTOC ? TOCEntry.build(from: doc) : [])
        }
    }

    // MARK: - 搜索（批 2）

    struct Hit {
        let index: Int              // 内部 0 起
        let snippet: String
        let rects: [CGRect]         // 归一化行框（页局部）
        let source: String          // native / ocr
    }

    /// 原生文本搜索：`PDFDocument.findString`（与 ⌘F 同一条路），命中前后各扩 `context` 个字符做摘要。
    /// `pages` = nil 不限页。结果按页、页内位置排序；最多 `maxHits` 条。
    func searchNative(path: String, query: String, pages: Set<Int>?, context: Int, maxHits: Int) async throws -> [Hit] {
        try await withDocument(path: path) { doc in
            let sels = doc.findString(query, withOptions: [.caseInsensitive, .diacriticInsensitive])
            var out: [Hit] = []
            for sel in sels {
                guard let page = sel.pages.first else { continue }
                let idx = doc.index(for: page)
                guard idx >= 0, idx < doc.pageCount else { continue }
                if let pages, !pages.contains(idx) { continue }
                let rects = PageGeometry.normalizedLineRects(of: sel, in: doc)[idx] ?? []
                // 摘要：复制一份选区往两头扩，取字符串再把换行压平
                let wide = sel.copy() as! PDFSelection
                wide.extend(atStart: context)
                wide.extend(atEnd: context)
                let snippet = Self.flatten(wide.string ?? sel.string ?? "")
                out.append(Hit(index: idx, snippet: snippet, rects: rects, source: "native"))
                if out.count >= maxHits { break }
            }
            return out.sorted { a, b in
                a.index != b.index ? a.index < b.index : (a.rects.first?.minY ?? 0) < (b.rects.first?.minY ?? 0)
            }
        }
    }

    /// OCR 缓存里搜：逐行不区分大小写的包含匹配（与 `DocSession.searchOCR` 同法），摘要 = 命中那一行。
    func searchOCR(store: LibraryStore, contentHash: String, query: String, pages: Set<Int>?, maxHits: Int) async -> [Hit] {
        guard !contentHash.isEmpty else { return [] }
        return await withCheckedContinuation { cont in
            queue.async {
                let book = self.ocrBook(store: store, contentHash: contentHash)
                var out: [Hit] = []
                for idx in book.pages.keys.sorted() {
                    if let pages, !pages.contains(idx) { continue }
                    guard let runs = book.pages[idx] else { continue }
                    let mask = OCRWatermark.mask(runs: runs, profile: book.profile)
                    for (r, isWM) in zip(runs, mask) where !isWM {
                        guard r.text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil else { continue }
                        out.append(Hit(index: idx, snippet: Self.flatten(r.text), rects: [r.rect], source: "ocr"))
                        if out.count >= maxHits { cont.resume(returning: out); return }
                    }
                }
                cont.resume(returning: out)
            }
        }
    }

    /// 在某一页上找一段原文（批 3 `add_note` / `add_highlight` 的锚点）：先原生 `findString`，
    /// 没有再在 OCR 缓存的行里找（整行包含就算）。返回归一化行框；找不到 → nil，**不猜**。
    func locate(path: String, store: LibraryStore?, contentHash: String, index: Int, quote: String) async throws -> [CGRect]? {
        let native: [CGRect]? = try await withDocument(path: path) { doc in
            for sel in doc.findString(quote, withOptions: [.caseInsensitive, .diacriticInsensitive]) {
                guard let page = sel.pages.first, doc.index(for: page) == index else { continue }
                let rects = PageGeometry.normalizedLineRects(of: sel, in: doc)[index] ?? []
                if !rects.isEmpty { return rects }
            }
            return nil
        }
        if let native { return native }
        guard let store, !contentHash.isEmpty else { return nil }
        return await withCheckedContinuation { cont in
            queue.async {
                let book = self.ocrBook(store: store, contentHash: contentHash)
                guard let runs = book.pages[index] else { cont.resume(returning: nil); return }
                let mask = OCRWatermark.mask(runs: runs, profile: book.profile)
                let hits = zip(runs, mask).compactMap { run, wm -> CGRect? in
                    guard !wm, run.text.range(of: quote, options: [.caseInsensitive, .diacriticInsensitive]) != nil else { return nil }
                    return run.rect
                }
                cont.resume(returning: hits.isEmpty ? nil : hits)
            }
        }
    }

    /// 摘要用：换行/连续空白压成一个空格。
    static func flatten(_ s: String) -> String {
        s.split(whereSeparator: { $0.isNewline || $0 == " " || $0 == "\t" }).joined(separator: " ")
    }

    // MARK: - 页图（批 2）

    struct Rendered {
        let data: Data
        let width: Int
        let height: Int
        let mime: String
    }

    /// 渲一页（与平板 `/page.png` 同一条原语：`PageBitmap.render` + `PageRenderer.encode`）。
    func render(path: String, index: Int, pixelWidth: Int, format: PageRenderer.Format) async throws -> Rendered {
        try await withDocument(path: path) { doc in
            guard let page = doc.page(at: index) else { throw MCPToolError("page \(index + 1) not found") }
            let disp = PageBitmap.displaySize(page)
            guard disp.width > 0, disp.height > 0 else { throw MCPToolError("page \(index + 1) has no size") }
            let px = Int(min(CGFloat(pixelWidth), disp.width * 4).rounded())
            guard px > 0, let cg = PageBitmap.render(page: page, pixelWidth: px),
                  let data = PageRenderer.encode(cg, format: format) else {
                throw MCPToolError("cannot render page \(index + 1)")
            }
            return Rendered(data: data, width: cg.width, height: cg.height, mime: format.contentType)
        }
    }

    private static func label(of page: PDFPage?, index: Int) -> String? {
        guard let l = page?.label?.trimmingCharacters(in: .whitespaces), !l.isEmpty, l != String(index + 1) else { return nil }
        return l
    }

    // MARK: - OCR 缓存

    /// 某几页的 OCR 文本（库里 `ocr_page` 的缓存）：行按版面拼成段落，滤掉平铺水印
    /// （`OCRWatermark`，与阅读区 `ocrVisibleRuns` 同一条判据）。没缓存的页不在返回里。
    ///
    /// `LibraryStore` 一条语句一把锁，后台用主线程那条连接是既有做法（`DocSession.rebuildWatermarkProfile` 同款）。
    func ocrTexts(store: LibraryStore, contentHash: String, pages: [Int]) async -> [Int: String] {
        guard !contentHash.isEmpty else { return [:] }
        return await withCheckedContinuation { cont in
            queue.async {
                let book = self.ocrBook(store: store, contentHash: contentHash)
                var out: [Int: String] = [:]
                for i in pages {
                    guard let runs = book.pages[i], !runs.isEmpty else { continue }
                    let mask = OCRWatermark.mask(runs: runs, profile: book.profile)
                    let kept = zip(runs, mask).compactMap { $1 ? nil : $0 }
                    let text = Self.joinRuns(kept)
                    if !text.isEmpty { out[i] = text }
                }
                cont.resume(returning: out)
            }
        }
    }

    /// 库里这本书有几页 OCR 缓存（`get_document.text.ocr_cached_pages`）。
    func ocrPageCount(store: LibraryStore, contentHash: String) async -> Int {
        guard !contentHash.isEmpty else { return 0 }
        return await withCheckedContinuation { cont in
            queue.async {
                cont.resume(returning: (try? store.ocrPageCount(contentHash: contentHash, provider: PaddleOCR.providerID)) ?? 0)
            }
        }
    }

    private func ocrBook(store: LibraryStore, contentHash: String) -> OCRBook {
        let now = CFAbsoluteTimeGetCurrent()
        if var b = ocrBooks[contentHash] {
            b.lastUsed = now; ocrBooks[contentHash] = b
            return b
        }
        var pages: [Int: [TextRun]] = [:]
        if let raw = try? store.allOCRPayloads(contentHash: contentHash, provider: PaddleOCR.providerID) {
            let dec = JSONDecoder()
            for (page, data) in raw {
                if let payload = try? dec.decode(OCRPagePayload.self, from: data) { pages[page] = payload.runs }
            }
        }
        let book = OCRBook(pages: pages, profile: OCRWatermark.buildProfile(pages), lastUsed: now)
        if ocrBooks.count >= maxOCRBooks, let victim = ocrBooks.min(by: { $0.value.lastUsed < $1.value.lastUsed })?.key {
            ocrBooks.removeValue(forKey: victim)
        }
        ocrBooks[contentHash] = book
        return book
    }

    /// 把 OCR 行拼成可读文本：按 y 分行（垂直中心落在上一行高度的一半以内算同一行），行内按 x 排，
    /// 行内相邻块中文直接接、西文补空格（与 `String.flattenedQuote` 同一条判据），行间换行。
    static func joinRuns(_ runs: [TextRun]) -> String {
        let sorted = runs.sorted { $0.y != $1.y ? $0.y < $1.y : $0.x < $1.x }
        var lines: [[TextRun]] = []
        var lineCenter = 0.0, lineH = 0.0
        for r in sorted {
            let c = r.y + r.h / 2
            if let last = lines.last, !last.isEmpty, abs(c - lineCenter) <= max(lineH, r.h) * 0.5 {
                lines[lines.count - 1].append(r)
                lineH = max(lineH, r.h)
            } else {
                lines.append([r])
                lineCenter = c; lineH = r.h
            }
        }
        var out: [String] = []
        for line in lines {
            var s = ""
            for r in line.sorted(by: { $0.x < $1.x }) {
                let t = r.text.trimmingCharacters(in: .whitespaces)
                if t.isEmpty { continue }
                if let a = s.last, let b = t.first, !(a.isCJKLike && b.isCJKLike) { s += " " }
                s += t
            }
            if !s.isEmpty { out.append(s) }
        }
        return out.joined(separator: "\n")
    }
}
