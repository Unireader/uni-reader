// TextSearch（⌘F 全文搜索）测试：全书 OCR 缓存（不只内存里那几页）/ 跨行命中 / 一行多处 / 去空白折大小写 /
// 水印过滤 / OCR 与原生合并去重 / 摘要与命中位置 / 作废。运行：
//   cp spike/text-search-test.swift /tmp/main.swift && swiftc Sources/App/PageText.swift Sources/App/OCRWatermark.swift \
//     Sources/App/OCRTextSelect.swift Sources/App/TextSearch.swift /tmp/main.swift -o /tmp/tst && /tmp/tst
// （须命名为 main.swift：swiftc 多文件时顶层代码只允许在 main.swift）
// App 里的 `TextMatch` / `LibraryStore` / `PageGeometry` 等在下面用最小替身顶上（只留 TextSearch 碰到的那几个成员）。
import AppKit
import CoreText
import PDFKit

// ---- 替身 ----
struct TextMatch: Identifiable, Equatable {
    let id = UUID()
    var page: Int
    var rects: [CGRect]
    var frac: Double
    var snippet = ""
    var snippetHit = NSRange(location: 0, length: 0)
}
struct PageAlign {}
struct ScanAlignTable { func page(_ i: Int) -> PageAlign? { nil } }
struct OCRPagePayload: Codable { var w: Double; var h: Double; var runs: [TextRun] }
extension Character { var isCJKLike: Bool { (unicodeScalars.first?.value ?? 0) >= 0x2E80 } }
enum PageGeometry {
    static func normalizedLineRects(of selection: PDFSelection, in pdf: PDFDocument,
                                    align: (Int) -> PageAlign?) -> [Int: [CGRect]] {
        var out: [Int: [CGRect]] = [:]
        for page in selection.pages {
            let idx = pdf.index(for: page)
            let box = page.bounds(for: .mediaBox)
            for line in selection.selectionsByLine() where line.pages.contains(page) {
                let b = line.bounds(for: page)
                guard b.width > 0 else { continue }
                out[idx, default: []].append(CGRect(x: b.minX / box.width, y: 1 - b.maxY / box.height,
                                                    width: b.width / box.width, height: b.height / box.height))
            }
        }
        return out
    }
}
final class LibraryStore {
    var pages: [Int: [TextRun]] = [:]
    var reads = 0
    func allOCRPayloads(contentHash: String, provider: String) throws -> [Int: Data] {
        reads += 1
        return pages.mapValues { try! JSONEncoder().encode(OCRPagePayload(w: 1000, h: 1400, runs: $0)) }
    }
}

var pass = 0, fail = 0
func check(_ c: Bool, _ m: String) { if c { pass += 1; print("  ✅ \(m)") } else { fail += 1; print("  ❌ \(m)") } }
func run(_ t: String, y: Double, x: Double = 0.1, w: Double = 0.7) -> TextRun { TextRun(text: t, x: x, y: y, w: w, h: 0.014) }
func hitText(_ m: TextMatch) -> String { (m.snippet as NSString).substring(with: m.snippetHit) }

/// 造一份有文字层的 PDF：每页若干行（CoreText 画，PDFKit 认得出字）。
func makePDF(_ pages: [[String]]) -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("text-search-test-\(UUID().uuidString).pdf")
    var box = CGRect(x: 0, y: 0, width: 400, height: 560)
    let ctx = CGContext(url as CFURL, mediaBox: &box, nil)!
    let font = CTFontCreateWithName("PingFang SC" as CFString, 14, nil)
    for lines in pages {
        ctx.beginPDFPage(nil)
        for (i, l) in lines.enumerated() {
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: l, attributes: [.font: font]))
            ctx.textPosition = CGPoint(x: 30, y: 520 - CGFloat(i) * 24)
            CTLineDraw(line, ctx)
        }
        ctx.endPDFPage()
    }
    ctx.closePDF()
    return url
}

func search(_ corpus: TextSearch.Corpus, _ q: String, store: LibraryStore?, loaded: [Int: [TextRun]] = [:],
            ignoreWM: Bool = true) async -> [TextMatch] {
    let ocr = TextSearch.OCRInput(store: store, provider: "p", loaded: loaded, profile: OCRWatermark.Profile(),
                                  ignoreWatermark: ignoreWM)
    return await corpus.search(TextSearch.Request(query: q, align: nil, ocr: ocr), token: TextSearch.Token()) ?? []
}

// ---- 摘要拼接 ----
print("摘要拼接（collapse / assemble）")
check(TextSearch.collapse("操作系\n统") == "操作系统", "汉字之间的换行直接接上")
check(TextSearch.collapse("the\n  quick") == "the quick", "西文换行压成一个空格")
check(TextSearch.collapse("  前后空白  ") == "前后空白", "没有邻居的两头空白剪掉")
let (s1, r1) = TextSearch.assemble([("我们说 ", 0), ("操作\n系统", 0), (" 是", 0)], leadingCut: true, trailingCut: false)
check(s1 == "…我们说操作系统是", "原生三段：前后接缝按汉字规则，前面截断补省略号（实际 \(s1)）")
check((s1 as NSString).substring(with: r1) == "操作系统", "命中位置对得上（含省略号偏移）")
let (s2, r2) = TextSearch.assemble([("see the ", 0), ("Kernel", 0), (" docs", 0)], leadingCut: false, trailingCut: true)
check(s2 == "see the Kernel docs…" && (s2 as NSString).substring(with: r2) == "Kernel", "西文空格保留（实际 \(s2)）")

// ---- OCR：全书缓存 + 跨行 + 一行多处 ----
print("OCR 层")
let store = LibraryStore()
store.pages[0] = [run("操作系", y: 0.10), run("统是计算机系统中最基本的系统软件", y: 0.12)]
store.pages[1] = [run("The CPU executes instructions; cpu time", y: 0.20)]
store.pages[2] = [run("操 作 系统 概论", y: 0.30)]
for p in 3..<40 { store.pages[p] = [run("无关正文第\(p)页", y: 0.5)] }
store.pages[300] = [run("第 300 页也有操作系统", y: 0.40)]   // 远处的页（阅读区从没加载过）
let emptyPDF = makePDF([["blank"]])
let corpus = TextSearch.Corpus(pdf: PDFDocument(url: emptyPDF)!, contentHash: "h")
var m = await search(corpus, "操作系统", store: store, loaded: [0: store.pages[0]!])
check(m.map(\.page) == [0, 2, 300], "库里全书都搜到（含内存里没有的第 2、300 页），实际 \(m.map(\.page))")
if let a = m.first {
    check(a.rects.count == 2, "跨行断开的「操作系|统」命中，框分两行")
    check(hitText(a) == "操作系统", "摘要里命中段 = 操作系统（实际 \(hitText(a))）")
    check(a.snippet.hasPrefix("操作系统是计算机"), "摘要从页首开始、带后文（实际 \(a.snippet)）")
}
if let p2 = m.first(where: { $0.page == 2 }) {
    check(hitText(p2) == "操作系统", "OCR 在汉字间插的空格不影响命中，摘要里也去掉（实际 \(hitText(p2))）")
}
m = await search(corpus, "系统", store: store)
check(m.filter { $0.page == 0 }.count == 3, "一行里多处都算（第 0 页 3 处，实际 \(m.filter { $0.page == 0 }.count)）")
m = await search(corpus, "cpu", store: store)
check(m.filter { $0.page == 1 }.count == 2, "折大小写：CPU / cpu 都命中")
check(store.reads == 1, "全书 OCR 只读一次库（实际 \(store.reads) 次）")

// 内存里有、库里没有的页（刚识别完）也要搜
m = await search(corpus, "新识别", store: store, loaded: [500: [run("刚刚新识别的一页", y: 0.1)]])
check(m.map(\.page) == [500], "内存里新识别、库里还没有的页也搜到")

// ---- 水印 ----
print("水印过滤")
let wmCorpus = TextSearch.Corpus(pdf: PDFDocument(url: emptyPDF)!, contentHash: "w")
let wmStore = LibraryStore()
// 正文行要占多数（水印判定相对页内行高中位数）
wmStore.pages[0] = (0..<8).map { run($0 == 0 ? "正文王道一行" : "正文第\($0)行", y: 0.1 + Double($0) * 0.03) } + [
                    TextRun(text: "王道计算机", x: 0.1, y: 0.4, w: 0.11, h: 0.10),
                    TextRun(text: "王道计算", x: 0.5, y: 0.4, w: 0.11, h: 0.10),
                    TextRun(text: "道计算机", x: 0.3, y: 0.7, w: 0.11, h: 0.10)]
m = await search(wmCorpus, "王道", store: wmStore)
check(m.count == 1, "滤掉水印块后只剩正文那处（实际 \(m.count)）")
m = await search(wmCorpus, "王道", store: wmStore, ignoreWM: false)
check(m.count == 3, "关掉水印过滤 → 水印块也命中（实际 \(m.count)）")

// ---- 原生文字层 + 合并 ----
print("PDF 自带文字层 + 与 OCR 合并")
let pdfURL = makePDF([["Kernel mode and user mode", "the kernel schedules"],
                      ["nothing here"],
                      ["A KERNEL panic"]])
let nCorpus = TextSearch.Corpus(pdf: PDFDocument(url: pdfURL)!, contentHash: "n")
m = await search(nCorpus, "kernel", store: nil)
check(m.map(\.page) == [0, 0, 2], "没开 OCR 只搜原生：第 0 页两处 + 第 2 页一处（实际 \(m.map(\.page))）")
check(m.allSatisfy { hitText($0).lowercased() == "kernel" }, "原生摘要里命中段 = 命中词（实际 \(m.map(hitText))）")
check(m.first?.snippet.contains("mode") == true, "原生摘要带后文（实际 \(m.first?.snippet ?? "")）")
let ocrForPage0 = LibraryStore()
ocrForPage0.pages[0] = [run("Kernel mode and user mode", y: 0.05)]
m = await search(nCorpus, "kernel", store: ocrForPage0)
check(m.map(\.page) == [0, 2], "第 0 页有 OCR 命中就不再报原生的；第 2 页没 OCR 照报原生（实际 \(m.map(\.page))）")

// ---- 作废 ----
print("作废")
let t = TextSearch.Token()
t.cancel()
let r = await nCorpus.search(TextSearch.Request(query: "kernel", align: nil, ocr: nil), token: t)
check(r == nil, "作废的搜索不出结果")

try? FileManager.default.removeItem(at: emptyPDF)
try? FileManager.default.removeItem(at: pdfURL)
print("\n\(pass) passed, \(fail) failed")
exit(fail == 0 ? 0 : 1)
