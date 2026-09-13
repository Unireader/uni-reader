import CoreGraphics
import Foundation

/// 在 OCR 行里定位一段引文，给出**按字符裁剪**的行框（批 3 `add_note` / `add_highlight` 的锚点）。
/// 纯函数，只依赖 `TextRun` + `OCRTextSelect`（spike `mcp-quote-locator-test.swift`）。
///
/// 为什么不能直接用整行的框（2026-09-13 用户报「Agent 建的笔记图钉跑到很右边」）：
/// 手动在 OCR 页选字时行框是按选中字符范围裁的（`OCRTextSelect.clip`），图钉落在选区**末端右侧**；
/// 整行框的末端就是行末，与手动操作对不上。
///
/// 匹配口径：把行按阅读顺序（y 再 x）拼起来，**去掉全部空白**后不区分大小写找引文——
/// Agent 手里的引文来自 `read_pages`（行间 `\n`、西文行内空格）或它自己抄的，空白怎么写都不该影响命中。
enum MCPQuoteLocator {
    /// 引文在这些行里的位置：首行/末行按字符裁剪，中间行整行。找不到 → nil（**不猜**）。
    static func locate(quote: String, in runs: [TextRun]) -> [CGRect]? {
        let ordered = readingOrder(runs)
        // 扁平化：去空白、折叠大小写；记每个扁平字符来自（第几行，行内第几个字符）
        var flat: [Character] = []
        var origin: [(run: Int, char: Int)] = []
        for (ri, run) in ordered.enumerated() {
            for (ci, c) in run.text.enumerated() where !c.isWhitespace {
                flat.append(fold(c))
                origin.append((ri, ci))
            }
        }
        let needle = quote.filter { !$0.isWhitespace }.map(fold)
        guard !needle.isEmpty, needle.count <= flat.count, let start = find(needle, in: flat) else { return nil }
        let end = start + needle.count - 1   // 含
        let first = origin[start], last = origin[end]
        var out: [CGRect] = []
        for ri in first.run...last.run {
            let run = ordered[ri]
            let lo = ri == first.run ? first.char : 0
            let hi = ri == last.run ? last.char + 1 : run.text.count
            if let clipped = OCRTextSelect.clip(run: run, from: lo, to: hi) { out.append(clipped.rect) }
        }
        return out.isEmpty ? nil : out
    }

    /// 阅读顺序：按行分（垂直中心落在上一行高度一半以内算同一行），行内按 x。与 `MCPDocReader.joinRuns` 同一条分行判据。
    static func readingOrder(_ runs: [TextRun]) -> [TextRun] {
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
        return lines.flatMap { $0.sorted { $0.x < $1.x } }
    }

    /// 折叠大小写（只在结果仍是单个字符时才用小写形式，免得 `İ` 这类变成两个字符把下标对错）。
    private static func fold(_ c: Character) -> Character {
        let l = String(c).lowercased()
        return l.count == 1 ? Character(l) : c
    }

    /// 朴素子串查找（行文本量小，够用）。
    private static func find(_ needle: [Character], in hay: [Character]) -> Int? {
        guard needle.count <= hay.count else { return nil }
        outer: for s in 0...(hay.count - needle.count) {
            for i in 0..<needle.count where hay[s + i] != needle[i] { continue outer }
            return s
        }
        return nil
    }
}
