// OCR 缓存 DAO 回归测试（schema v3 的 ocr_page 表）。运行：
//   cp spike/ocr-store-test.swift /tmp/main.swift && swiftc Sources/Store/*.swift /tmp/main.swift -o /tmp/ot && /tmp/ot
// （须命名为 main.swift：swiftc 多文件时顶层代码只允许在 main.swift）
//
// 用真实的 Sources/Store 三个文件驱动 DAO；临时目录建库、defer 清理，不碰任何外部工作区。

import Foundation

var pass = 0, fail = 0
func check(_ cond: Bool, _ msg: String) {
    if cond { pass += 1; print("  ✅ \(msg)") } else { fail += 1; print("  ❌ \(msg)") }
}

// 跨平台 payload 契约（与 App 里 OCRPagePayload / TextRun 字段一致：归一化 0~1 文本框）。
struct TRun: Codable, Equatable { var text: String; var x, y, w, h: Double }
struct TPayload: Codable, Equatable { var w: Double; var h: Double; var runs: [TRun] }

let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ocr_test_\(UInt64.random(in: 0..<1_000_000))")
try? FileManager.default.removeItem(at: tmp)
try! FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: tmp) }

let store = try LibraryStore(workspaceFolder: tmp)

// 0) 新库 schema_version == 3
check(store.meta("schema_version") == "3", "新库 schema_version = 3")

// 1) payload JSON 编码 → 落库 → 读回 → 解码，字段一致（跨平台契约）
let payload = TPayload(w: 595, h: 842, runs: [
    TRun(text: "Hello", x: 0.1, y: 0.2, w: 0.3, h: 0.05),
    TRun(text: "世界",   x: 0.1, y: 0.3, w: 0.2, h: 0.05),
])
let blob = try JSONEncoder().encode(payload)
try store.upsertOCRPage(OCRPage(contentHash: "hA", page: 3, provider: "vision", payload: blob, lang: "zh", createdAt: .now))
let got = try store.ocrPage(contentHash: "hA", page: 3, provider: "vision")
check(got != nil, "upsert 后能读回同 (hash,page,provider)")
check(got?.lang == "zh", "lang 列读回正确")
if let g = got, let decoded = try? JSONDecoder().decode(TPayload.self, from: g.payload) {
    check(decoded == payload, "payload JSON round-trip 无损（w/h/runs 全等）")
} else { check(false, "payload 解码失败") }

// 2) JSON 形态是干净的扁平 x/y/w/h（Windows/Android 易读）
let js = String(data: blob, encoding: .utf8) ?? ""
check(js.contains("\"text\"") && js.contains("\"x\"") && js.contains("\"runs\""), "payload 为扁平 {w,h,runs:[{text,x,y,w,h}]}")

// 3) 主键冲突 (hash,page,provider) → 覆盖而非新增
let blob2 = try JSONEncoder().encode(TPayload(w: 595, h: 842, runs: [TRun(text: "changed", x: 0, y: 0, w: 1, h: 1)]))
try store.upsertOCRPage(OCRPage(contentHash: "hA", page: 3, provider: "vision", payload: blob2, lang: nil, createdAt: .now))
let got2 = try store.ocrPage(contentHash: "hA", page: 3, provider: "vision")
check(got2?.payload == blob2, "同主键再 upsert → 覆盖 payload")
check(got2?.lang == nil, "lang 可写回 NULL（读回 nil）")

// 4) 不同 provider / 不同页 各自独立
check(try store.ocrPage(contentHash: "hA", page: 3, provider: "paddle-http") == nil, "不同 provider → 独立（未写则 miss）")
try store.upsertOCRPage(OCRPage(contentHash: "hA", page: 4, provider: "vision", payload: blob, lang: nil, createdAt: .now))
check(try store.ocrPage(contentHash: "hA", page: 4, provider: "vision") != nil, "不同页 → 独立行")

// 5) deleteOCRPages(hash) 只清该 hash
try store.upsertOCRPage(OCRPage(contentHash: "hB", page: 1, provider: "vision", payload: blob, lang: nil, createdAt: .now))
try store.deleteOCRPages(contentHash: "hA")
check(try store.ocrPage(contentHash: "hA", page: 3, provider: "vision") == nil, "deleteOCRPages 清掉 hA 全部页")
check(try store.ocrPage(contentHash: "hA", page: 4, provider: "vision") == nil, "deleteOCRPages 清掉 hA 全部页(2)")
check(try store.ocrPage(contentHash: "hB", page: 1, provider: "vision") != nil, "deleteOCRPages 不误删其他 hash")

// 6) miss → nil（上层据此决定真跑 OCR 再回填）
check(try store.ocrPage(contentHash: "nope", page: 0, provider: "vision") == nil, "未缓存 → nil")

// 7) 迁移幂等：把 schema_version 退回 2 再重开 → 迁移把它拉回 3，且 ocr 数据保留
try store.setMeta("schema_version", "2")
let store2 = try LibraryStore(workspaceFolder: tmp)
check(store2.meta("schema_version") == "3", "重开触发迁移 → schema_version 回到 3")
check(try store2.ocrPage(contentHash: "hB", page: 1, provider: "vision") != nil, "迁移不丢已有 OCR 缓存")

print("\n\(pass) passed, \(fail) failed")
exit(fail == 0 ? 0 : 1)
