import CoreGraphics
import Foundation
import PDFKit

/// ⌘F 全文搜索（T2）。两层文字合起来搜，覆盖整本书：
///
///  · **OCR 层**（本文档开着 OCR 时）：库里这本书**全部**已识别页——不是阅读区懒加载进内存的那几页
///    （2026-10-19 用户报「搜索没有全文去搜」：原先开了 OCR 就只搜 `ocrRuns`，而它只装着最近翻过的页）。
///    一页的可见行（已滤水印）按 OCR 的阅读顺序接成一串、去空白、折大小写后找，所以**跨行断开的词**
///    （「操作系」+「统」）也找得到；一行里出现几次就是几处。框按命中的字符裁（`OCRTextSelect.clip`）。
///  · **PDF 自带文字层**：PDFKit `findString`（跨行 / 跨页都行），每个命中取按行拆开的行框，与文字选择同一套
///    rotation-aware 归一化（`PageGeometry.normalizedLineRects`）。**已有 OCR 命中的页不再报原生命中**
///    （扫描书的隐形文字层和 OCR 是同一段字，报两遍就重了；与 MCP `search_text` 同一条规则）。
///
/// 一切都在 `queue` 这条串行队列上跑：`Corpus` 自己开一份 `PDFDocument`（`PDFDocument` 不能并发用，
/// 阅读区出图那份在渲染队列上）；OCR 全书从库里读一次、解好、建好索引后留在 `Corpus` 里，接着打字不重读。
/// `Corpus` 由 `DocSession` 在搜索框清空 / 换文档时丢掉（内存与文件句柄只在搜索期间占着）。
enum TextSearch {
    static let queue = DispatchQueue(label: "tech.xvanturing.unireader.search", qos: .userInitiated)

    /// 列表摘要里命中前后各带多少个字。
    static let snippetBefore = 16
    static let snippetAfter = 40

    /// 作废标记：新一轮搜索开始时把上一轮的置上——排在队列里还没跑的直接跳过，跑到一半的尽早收手。
    final class Token: @unchecked Sendable {
        private let lock = NSLock()
        private var flag = false
        var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return flag }
        func cancel() { lock.lock(); flag = true; lock.unlock() }
    }

    /// 一次搜索要的全部输入（主线程上取好快照再交给队列，之后只在队列上读）。
    struct Request: @unchecked Sendable {
        var query: String
        /// 扫描页对齐参数表（没开传 nil）：命中框要落在对齐后的页面上。
        var align: ScanAlignTable?
        /// nil = 不搜 OCR 层（本文档没开 OCR）。
        var ocr: OCRInput?
    }

    struct OCRInput {
        /// 读全书 OCR 缓存用；nil 时只搜 `loaded`。
        var store: LibraryStore?
        var provider: String
        /// 内存里已有的页（`DocSession.ocrRuns`）。刚识别完的页可能比 `Corpus` 读库那一刻新，以它补齐。
        var loaded: [Int: [TextRun]]
        var profile: OCRWatermark.Profile
        var ignoreWatermark: Bool
    }

    /// 一页 OCR 文字的搜索索引：可见行按阅读顺序接起来，去掉空白、折好大小写，逐个 unicode 标量记来源。
    private struct OCRPageIndex {
        var runs: [TextRun]
        var hay: [UInt32]
        var originRun: [Int32]    // 每个标量来自第几行
        var originChar: [Int32]   // ……行内第几个字符（`Character` 计，与 `TextRun.chars` 同口径）
    }

    // MARK: - 语料

    /// 一份文档的搜索语料。**只在 `queue` 上碰**（`DocSession` 只持有引用）。
    final class Corpus: @unchecked Sendable {
        let contentHash: String
        let pdfID: ObjectIdentifier
        private let url: URL?
        private var fallback: PDFDocument?
        private var doc: PDFDocument?
        private var pageText: [Int: NSString] = [:]
        private var dbPages: [Int: [TextRun]]?
        private var dbProvider = ""
        private var ocrIndex: [Int: OCRPageIndex] = [:]
        private var indexBasis: (profile: OCRWatermark.Profile, ignore: Bool)?

        /// `pdf` 只用来取文件地址（另开一份）；拿不到地址才退回共用它。
        init(pdf: PDFDocument, contentHash: String) {
            self.contentHash = contentHash
            pdfID = ObjectIdentifier(pdf)
            url = pdf.documentURL
            fallback = url == nil ? pdf : nil
        }

        /// 在队列上跑一次搜索；被作废返回 nil。
        func search(_ req: Request, token: Token) async -> [TextMatch]? {
            await withCheckedContinuation { cont in
                TextSearch.queue.async {
                    cont.resume(returning: token.isCancelled ? nil : self.run(req, token: token))
                }
            }
        }

        private func document() -> PDFDocument? {
            if let doc { return doc }
            doc = url.flatMap { PDFDocument(url: $0) } ?? fallback
            return doc
        }

        private func run(_ req: Request, token: Token) -> [TextMatch]? {
            var out: [TextMatch] = []
            if let ocr = req.ocr {
                guard let hits = searchOCR(req.query, ocr, token: token) else { return nil }
                out = hits
            }
            let ocrHitPages = Set(out.map(\.page))
            guard !token.isCancelled, let pdf = document() else { return token.isCancelled ? nil : out }
            guard let native = searchNative(req.query, in: pdf, align: req.align, token: token) else { return nil }
            out += native.filter { !ocrHitPages.contains($0.page) }
            return out.sorted { $0.page != $1.page ? $0.page < $1.page : $0.frac < $1.frac }
        }

        // MARK: OCR 层

        private func searchOCR(_ query: String, _ input: OCRInput, token: Token) -> [TextMatch]? {
            if let store = input.store, dbPages == nil || dbProvider != input.provider {
                dbPages = Self.loadOCR(store: store, contentHash: contentHash, provider: input.provider)
                dbProvider = input.provider
                ocrIndex = [:]
            }
            if indexBasis.map({ $0.profile != input.profile || $0.ignore != input.ignoreWatermark }) ?? true {
                ocrIndex = [:]
                indexBasis = (input.profile, input.ignoreWatermark)
            }
            var pages = dbPages ?? [:]
            for (p, runs) in input.loaded where pages[p] == nil { pages[p] = runs }

            let needle = TextSearch.foldedScalars(query)
            guard !needle.isEmpty else { return [] }
            var out: [TextMatch] = []
            for (page, runs) in pages {
                if token.isCancelled { return nil }
                let idx: OCRPageIndex
                if let c = ocrIndex[page] {
                    idx = c
                } else {
                    let visible: [TextRun]
                    if input.ignoreWatermark {
                        let m = OCRWatermark.mask(runs: runs, profile: input.profile)
                        visible = zip(runs, m).compactMap { $1 ? nil : $0 }
                    } else {
                        visible = runs
                    }
                    idx = TextSearch.buildIndex(visible)
                    ocrIndex[page] = idx
                }
                TextSearch.matches(needle, in: idx, page: page, into: &out)
            }
            return out
        }

        /// 读库 + 解 JSON（一本 340 页的书约 3MB），一份语料只读一次。
        private static func loadOCR(store: LibraryStore, contentHash: String, provider: String) -> [Int: [TextRun]] {
            guard !contentHash.isEmpty,
                  let raw = try? store.allOCRPayloads(contentHash: contentHash, provider: provider) else { return [:] }
            let dec = JSONDecoder()
            var pages: [Int: [TextRun]] = [:]
            for (page, data) in raw {
                if let payload = try? dec.decode(OCRPagePayload.self, from: data) { pages[page] = payload.runs }
            }
            return pages
        }

        // MARK: PDF 自带文字层

        private func searchNative(_ query: String, in pdf: PDFDocument, align: ScanAlignTable?, token: Token) -> [TextMatch]? {
            let selections = pdf.findString(query, withOptions: [.caseInsensitive, .diacriticInsensitive])
            var out: [TextMatch] = []
            for sel in selections {
                if token.isCancelled { return nil }
                let lines = PageGeometry.normalizedLineRects(of: sel, in: pdf, align: { align?.page($0) })
                guard !lines.isEmpty else { continue }
                let (snippet, hit) = nativeSnippet(sel, in: pdf)
                for (idx, rects) in lines {
                    out.append(TextMatch(page: idx, rects: rects, frac: Double(rects.map(\.minY).min() ?? 0),
                                         snippet: snippet, snippetHit: hit))
                }
            }
            return out
        }

        /// 摘要：命中在页文字里的位置往两头各取几个字（页文字一页只取一次）。取不到位置就只给命中本身。
        private func nativeSnippet(_ sel: PDFSelection, in pdf: PDFDocument) -> (String, NSRange) {
            let plain = TextSearch.collapse(sel.string ?? "")
            guard let page = sel.pages.first, sel.numberOfTextRanges(on: page) > 0 else {
                return (plain, NSRange(location: 0, length: (plain as NSString).length))
            }
            let idx = pdf.index(for: page)
            let text: NSString
            if let t = pageText[idx] { text = t } else { text = (page.string ?? "") as NSString; pageText[idx] = text }
            let r = sel.range(at: 0, on: page)
            guard r.location != NSNotFound, r.length > 0, NSMaxRange(r) <= text.length else {
                return (plain, NSRange(location: 0, length: (plain as NSString).length))
            }
            let lo = text.rangeOfComposedCharacterSequence(at: max(0, r.location - TextSearch.snippetBefore)).location
            let hiEnd = min(text.length, NSMaxRange(r) + TextSearch.snippetAfter)
            let hi = hiEnd == text.length ? hiEnd : text.rangeOfComposedCharacterSequence(at: hiEnd).location
            let pre = text.substring(with: NSRange(location: lo, length: r.location - lo))
            let mid = text.substring(with: r)
            let post = text.substring(with: NSRange(location: NSMaxRange(r), length: max(0, hi - NSMaxRange(r))))
            return TextSearch.assemble([(pre, 0), (mid, 0), (post, 0)], leadingCut: lo > 0, trailingCut: hi < text.length)
        }
    }

    // MARK: - OCR 索引与匹配（纯函数）

    private static func buildIndex(_ runs: [TextRun]) -> OCRPageIndex {
        var idx = OCRPageIndex(runs: runs, hay: [], originRun: [], originChar: [])
        for (ri, run) in runs.enumerated() {
            for (ci, c) in run.text.enumerated() where !c.isWhitespace {
                let n = appendFolded(c, to: &idx.hay)
                for _ in 0..<n {
                    idx.originRun.append(Int32(ri))
                    idx.originChar.append(Int32(ci))
                }
            }
        }
        return idx
    }

    /// 查询词 → 折好的标量（去空白，与索引同口径）。
    static func foldedScalars(_ s: String) -> [UInt32] {
        var out: [UInt32] = []
        for c in s where !c.isWhitespace { _ = appendFolded(c, to: &out) }
        return out
    }

    /// 折大小写后追加标量，返回追加了几个。与 `MCPQuoteLocator.fold` 同口径：小写后仍是单个字符才用小写形式；
    /// ASCII 与汉字这类不分大小写的字走快路（不建临时字符串——整本书几十万字，每次建一个就慢下来了）。
    private static func appendFolded(_ c: Character, to out: inout [UInt32]) -> Int {
        if let a = c.asciiValue {
            out.append(UInt32((65...90).contains(a) ? a + 32 : a))
            return 1
        }
        var n = 0
        if c.isCased {
            let l = c.lowercased()
            for u in (l.count == 1 ? l : String(c)).unicodeScalars { out.append(u.value); n += 1 }
        } else {
            for u in c.unicodeScalars { out.append(u.value); n += 1 }
        }
        return n
    }

    /// 一页里找全部（不重叠的）命中，转成 `TextMatch` 追加进 `out`。
    private static func matches(_ needle: [UInt32], in idx: OCRPageIndex, page: Int, into out: inout [TextMatch]) {
        let hay = idx.hay, m = needle.count
        guard m > 0, hay.count >= m else { return }
        let first = needle[0]
        var s = 0
        while s <= hay.count - m {
            guard hay[s] == first else { s += 1; continue }
            var ok = true
            for k in 1..<max(1, m) where hay[s + k] != needle[k] { ok = false; break }
            guard ok else { s += 1; continue }
            let e = s + m - 1
            let a = Int(idx.originRun[s]), i = Int(idx.originChar[s])
            let b = Int(idx.originRun[e]), j = Int(idx.originChar[e])
            var rects: [CGRect] = []
            for ri in a...b {
                let run = idx.runs[ri]
                let lo = ri == a ? i : 0
                let hi = ri == b ? j + 1 : run.text.count
                if let clipped = OCRTextSelect.clip(run: run, from: lo, to: hi) { rects.append(clipped.rect) }
            }
            if !rects.isEmpty {
                let (snippet, hit) = ocrSnippet(idx.runs, from: (a, i), to: (b, j))
                out.append(TextMatch(page: page, rects: rects, frac: Double(rects.map(\.minY).min() ?? 0),
                                     snippet: snippet, snippetHit: hit))
            }
            s = e + 1
        }
    }

    /// OCR 命中的摘要：从命中首字往前、末字往后沿着阅读顺序跨行各取几个字。
    private static func ocrSnippet(_ runs: [TextRun], from: (Int, Int), to: (Int, Int)) -> (String, NSRange) {
        var chars: [Int: [Character]] = [:]
        func cs(_ r: Int) -> [Character] {
            if let c = chars[r] { return c }
            let c = Array(runs[r].text)
            chars[r] = c
            return c
        }
        // 往前
        var pre: [(String, Int)] = []
        var need = snippetBefore, ri = from.0, ci = from.1
        while true {
            let take = min(need, ci)
            if take > 0 { pre.insert((String(cs(ri)[(ci - take)..<ci]), ri), at: 0) }
            need -= take
            ci -= take
            guard need > 0, ri > 0 else { break }
            ri -= 1
            ci = cs(ri).count
        }
        let leadingCut = ci > 0 || ri > 0
        // 命中本身
        var mid: [(String, Int)] = []
        for r in from.0...to.0 {
            let c = cs(r)
            let lo = r == from.0 ? from.1 : 0
            let hi = r == to.0 ? to.1 + 1 : c.count
            if lo < hi { mid.append((String(c[lo..<hi]), r)) }
        }
        // 往后
        var post: [(String, Int)] = []
        need = snippetAfter; ri = to.0; ci = to.1 + 1
        while true {
            let c = cs(ri)
            let take = min(need, max(0, c.count - ci))
            if take > 0 { post.append((String(c[ci..<(ci + take)]), ri)) }
            need -= take
            ci += take
            guard need > 0, ri < runs.count - 1 else { break }
            ri += 1
            ci = 0
        }
        let trailingCut = ci < cs(ri).count || ri < runs.count - 1
        return assemble(pre + mid.map { ($0.0, $0.1 | hitFlag) } + post, leadingCut: leadingCut, trailingCut: trailingCut)
    }

    /// 段标记：`assemble` 的段号或上它表示「这段是命中本身」（段号就是行号，远小于这个位）。
    private static let hitFlag = 1 << 40

    /// 把若干段拼成一行摘要：段内空白压成一个空格（两边都是汉字就直接接上）；换了行的接缝处同 `flattenedQuote`
    /// 的判据补空格。返回摘要与命中那段在其中的位置（UTF-16，给 `NSAttributedString` 用）。
    /// 原生摘要三段同属一行（段号都给 0），命中段由「第二段」认；OCR 摘要用 `hitFlag` 标。
    static func assemble(_ segs: [(String, Int)], leadingCut: Bool, trailingCut: Bool) -> (String, NSRange) {
        var out = ""
        var lo = -1, hi = -1
        var lastRun: Int?
        let flagged = segs.contains { $0.1 & hitFlag != 0 }
        for (k, seg) in segs.enumerated() {
            let isHit = flagged ? seg.1 & hitFlag != 0 : k == 1
            let run = seg.1 & ~hitFlag
            let after = segs[(k + 1)...].lazy.compactMap { $0.0.first(where: { !$0.isWhitespace }) }.first
            let text = collapse(seg.0, before: out.last, after: after)
            if let lr = lastRun, lr != run, let a = out.last, let b = text.first,
               !a.isWhitespace, !b.isWhitespace, !(a.isCJKLike && b.isCJKLike) {
                out += " "
            }
            if isHit, lo < 0 { lo = (out as NSString).length }
            out += text
            if isHit { hi = (out as NSString).length }
            if !text.isEmpty { lastRun = run }
        }
        if leadingCut, !out.isEmpty {
            out = "…" + out
            if lo >= 0 { lo += 1; hi += 1 }
        }
        if trailingCut, !out.isEmpty { out += "…" }
        let len = (out as NSString).length
        guard lo >= 0, hi >= lo, hi <= len else { return (out, NSRange(location: 0, length: 0)) }
        return (out, NSRange(location: lo, length: hi - lo))
    }

    /// 空白（含换行）压成一个空格；空白两边都是汉字就整段去掉（原文本来连排，换行处补空格反而多个洞）。
    /// `before` / `after` = 这段前后紧挨着的字（拼摘要时的邻段），段首 / 段尾的空白按它们判；没有邻居的那头直接剪掉。
    static func collapse(_ s: String, before: Character? = nil, after: Character? = nil) -> String {
        var out = ""
        var pending = false
        var prev = before
        for c in s {
            if c.isWhitespace { pending = true; continue }
            if pending, let p = prev, !p.isWhitespace, !(p.isCJKLike && c.isCJKLike) { out += " " }
            pending = false
            out.append(c)
            prev = c
        }
        if pending, let p = prev, let a = after, !p.isWhitespace, !(p.isCJKLike && a.isCJKLike) { out += " " }
        return out
    }
}
