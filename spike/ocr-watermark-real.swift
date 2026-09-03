// OCRWatermark 真实数据回归：直接读某个工作区库里已缓存的 OCR 页，跑一遍水印判定并把
// **候选里没被判掉的**全列出来（那些必须全是正文——章标题、框图标签之类；出现水印碎片就是漏判）。
// 改 `OCRWatermark` 的阈值后拿它回归，别只信手造样本。运行：
//
//   cp spike/ocr-watermark-real.swift /tmp/main.swift && \
//     swiftc Sources/App/PageText.swift Sources/App/OCR.swift Sources/App/OCRWatermark.swift /tmp/main.swift \
//       -lsqlite3 -o /tmp/owmr && \
//     /tmp/owmr "/Volumes/SSD/2027考研/408/408学习区.unrd/UniReader/library.sqlite"
//
// 第二个参数可给页数上限，模拟「只识别了前 N 页」的冷启动：/tmp/owmr <db> 12
//
// ⚠️ 会打开用户工作区的库（只读 SELECT）。app 开着时读的是已提交的部分，结论不受影响。
import Foundation
import SQLite3

let args = CommandLine.arguments
guard args.count >= 2 else { print("用法: owmr <library.sqlite> [前N页]"); exit(2) }
let dbPath = args[1]
let limitPages = args.count >= 3 ? Int(args[2]) ?? 0 : 0

var db: OpaquePointer?
guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
    print("打不开库: \(dbPath)"); exit(1)
}
defer { sqlite3_close(db) }

func query(_ sql: String) -> [[Any?]] {
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
    defer { sqlite3_finalize(stmt) }
    var rows: [[Any?]] = []
    while sqlite3_step(stmt) == SQLITE_ROW {
        var row: [Any?] = []
        for i in 0..<sqlite3_column_count(stmt) {
            switch sqlite3_column_type(stmt, i) {
            case SQLITE_INTEGER: row.append(Int(sqlite3_column_int64(stmt, i)))
            case SQLITE_TEXT:    row.append(String(cString: sqlite3_column_text(stmt, i)))
            case SQLITE_BLOB:
                if let p = sqlite3_column_blob(stmt, i) {
                    row.append(Data(bytes: p, count: Int(sqlite3_column_bytes(stmt, i))))
                } else { row.append(Data()) }
            default: row.append(nil)
            }
        }
        rows.append(row)
    }
    return rows
}

let books = query("""
SELECT d.title, v.content_hash, v.page_count,
       (SELECT COUNT(*) FROM ocr_page o WHERE o.content_hash = v.content_hash)
FROM variant v JOIN document d ON d.id = v.document_id
""")

var anyOCR = false
for b in books {
    let title = b[0] as? String ?? "?"
    let hash = b[1] as? String ?? ""
    let cached = b[3] as? Int ?? 0
    guard cached > 0 else { continue }
    anyOCR = true

    var pages: [Int: [TextRun]] = [:]
    let dec = JSONDecoder()
    for r in query("SELECT page,payload FROM ocr_page WHERE content_hash='\(hash)' ORDER BY page") {
        guard let p = r[0] as? Int, let d = r[1] as? Data,
              let payload = try? dec.decode(OCRPagePayload.self, from: d) else { continue }
        if limitPages > 0 && pages.count >= limitPages && pages[p] == nil { continue }
        pages[p] = payload.runs
    }
    guard !pages.isEmpty else { continue }

    let profile = OCRWatermark.buildProfile(pages)
    var totalRuns = 0, cand = 0, hits = 0
    var kept: [(Int, TextRun, Double)] = []
    for (p, runs) in pages {
        totalRuns += runs.count
        let med = OCRWatermark.medianHeight(runs)
        let mask = OCRWatermark.mask(runs: runs, profile: profile)
        for (i, r) in runs.enumerated() where OCRWatermark.isCandidate(r, medianH: med) {
            cand += 1
            if mask[i] { hits += 1 } else { kept.append((p, r, med > 0 ? r.h / med : 0)) }
        }
    }
    print("""

    ▶ \(title)
      页 \(pages.count)（库里缓存 \(cached)）/ 行 \(totalRuns) / 候选 \(cand) / 判水印 \(hits) \
    / 阈值 \(OCRWatermark.threshold(sampledPages: profile.sampledPages)) 页
      候选里保留 \(kept.count) 条（应当全是正文）：
    """)
    for (p, r, ratio) in kept.sorted(by: { $0.0 < $1.0 }).prefix(40) {
        let wh = r.h > 0 ? r.w / r.h : 0
        print(String(format: "        p%-4d 高/中位=%5.2f  w/h=%5.2f  %@", p, ratio, wh, r.text))
    }
    if kept.count > 40 { print("        …（还有 \(kept.count - 40) 条）") }
}
if !anyOCR { print("这个库里没有任何已缓存的 OCR 页。") }
