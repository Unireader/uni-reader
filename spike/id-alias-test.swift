// 别端写的非规范 id（安卓 2026-10-29 之前的小写 UUID）回归测试：读进来之后，按大写 id 改 / 删要落在原来那一行上，
// 不多出一行、不删不掉；库里的 id 一个字不改。运行：
//   cp spike/id-alias-test.swift /tmp/main.swift && \
//     swiftc Sources/Store/*.swift /tmp/main.swift -o /tmp/ida && /tmp/ida
// （须命名为 main.swift 编译：swiftc 多文件时顶层代码只允许在 main.swift）

import Foundation
import CoreGraphics

setvbuf(stdout, nil, _IONBF, 0)

var pass = 0, fail = 0
func check(_ cond: Bool, _ msg: String) {
    if cond { pass += 1; print("  ✅ \(msg)") } else { fail += 1; print("  ❌ \(msg)") }
}

let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("id_alias_test_\(UInt64.random(in: 0..<1_000_000))")
try! FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: tmp) }

let store = try! LibraryStore(workspaceFolder: tmp)
let doc = try! store.findOrCreate(hash: "hash-x", title: "文档", pageCount: 3, path: "PDFs/x.pdf", isRelative: false).document

// 安卓老版本写的小写 id
let lower = UUID().uuidString.lowercased()
let upper = lower.uppercased()

print("\n— 1) note：读进来后按大写改 / 删 —")
try! store.upsertNote(LibNote(id: lower, documentId: doc.id, kind: 0, page: 0, anchor: .zero,
                              payload: Data(#"{"text":"旧"}"#.utf8), createdAt: .now, updatedAt: .now))
let read = try! store.notes(documentId: doc.id)
check(read.first?.id == lower, "库里原样是小写")
try! store.upsertNote(LibNote(id: upper, documentId: doc.id, kind: 0, page: 0, anchor: .zero,
                              payload: Data(#"{"text":"新"}"#.utf8), createdAt: .now, updatedAt: .now))
let after = try! store.notes(documentId: doc.id)
check(after.count == 1, "按大写 id 改：仍是一行（没多出一行）")
check(after.first?.id == lower, "id 没被改写")
check(String(data: after.first!.payload, encoding: .utf8)!.contains("新"), "内容改到了原来那一行")
try! store.deleteNote(id: upper)
check((try! store.notes(documentId: doc.id)).isEmpty, "按大写 id 删：删得掉")

print("\n— 2) 笔迹窄查（inkRows）也记得住 —")
let ink = UUID().uuidString.lowercased()
try! store.upsertNote(LibNote(id: ink, documentId: doc.id, kind: 2, page: 1, anchor: .zero,
                              payload: Data(#"{"points":[]}"#.utf8), createdAt: .now, updatedAt: .now))
_ = try! store.inkRows(documentId: doc.id, kind: 2)
try! store.deleteNote(id: ink.uppercased())
check((try! store.inkRows(documentId: doc.id, kind: 2)).isEmpty, "窄查读过之后按大写删得掉")

print("\n— 3) ink_layer / scratch_pad —")
let layer = UUID().uuidString.lowercased()
try! store.upsertInkLayer(LibInkLayer(id: layer, documentId: doc.id, name: "图层", colorKey: "red",
                                      sortOrder: 0, visible: true, createdAt: .now))
_ = try! store.inkLayers(documentId: doc.id)
try! store.upsertInkLayer(LibInkLayer(id: layer.uppercased(), documentId: doc.id, name: "改名", colorKey: "red",
                                      sortOrder: 0, visible: false, createdAt: .now))
let layers = try! store.inkLayers(documentId: doc.id)
check(layers.count == 1 && layers[0].name == "改名" && layers[0].id == layer, "图层按大写改：一行、改到了、id 不变")
try! store.deleteInkLayer(id: layer.uppercased())
check((try! store.inkLayers(documentId: doc.id)).isEmpty, "图层按大写删得掉")

let pad = UUID().uuidString.lowercased()
try! store.upsertScratchPad(LibScratchPad(id: pad, documentId: doc.id, title: "纸", anchorPage: 0, anchorX: 0.5, anchorY: 0.5,
                                          bg: "rgba(255,255,255,1.0)", pattern: "dots", showPage: false,
                                          createdAt: .now, updatedAt: .now))
_ = try! store.scratchPads(documentId: doc.id)
try! store.deleteScratchPad(id: pad.uppercased())
check((try! store.scratchPads(documentId: doc.id)).isEmpty, "草稿纸按大写删得掉")

print("\n— 4) 规范的大写 id 照旧 —")
let normal = UUID().uuidString
try! store.upsertNote(LibNote(id: normal, documentId: doc.id, kind: 0, page: 0, anchor: .zero,
                              payload: Data(#"{"text":"a"}"#.utf8), createdAt: .now, updatedAt: .now))
_ = try! store.notes(documentId: doc.id)
check(store.storedID(normal) == normal, "大写 id 不进别名表")
try! store.deleteNote(id: normal)
check((try! store.notes(documentId: doc.id)).isEmpty, "大写 id 照常删")

print("\n结果：\(pass) 通过，\(fail) 失败")
exit(fail == 0 ? 0 : 1)
