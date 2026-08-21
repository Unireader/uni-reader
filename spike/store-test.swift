// LibraryStore DAO 回归测试。运行：
//   cp spike/store-test.swift /tmp/main.swift && swiftc Sources/Store/*.swift /tmp/main.swift -o /tmp/st && /tmp/st
// （须命名为 main.swift 编译：swiftc 多文件时顶层代码只允许在 main.swift）

import Foundation

// 用真实的 Sources/Store 三个文件一起编译，直接驱动 DAO 逻辑（findOrCreate 去重 / linkVariant 合并 / notes）。
var pass = 0, fail = 0
func check(_ cond: Bool, _ msg: String) {
    if cond { pass += 1; print("  ✅ \(msg)") } else { fail += 1; print("  ❌ \(msg)") }
}

let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ws_test_\(UInt64.random(in: 0..<1_000_000))")
try? FileManager.default.removeItem(at: tmp)
try! FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: tmp) }

let store = try LibraryStore(workspaceFolder: tmp)
try store.setWorkspaceName("Test WS")
check(store.workspaceName == "Test WS", "workspace name 写入/读回")

// 1) 新建
let (d1, v1) = try store.findOrCreate(hash: "h1", title: "DocA", pageCount: 10, path: "/tmp/a.pdf")
check(d1.title == "DocA" && v1.contentHash == "h1", "findOrCreate 新建 document+variant")

// 2) 同 hash 再来（不同路径）→ 复用 document，追加 location
let (d1b, v1b) = try store.findOrCreate(hash: "h1", title: "DocA", pageCount: 10, path: "/tmp/a-copy.pdf")
check(d1b.id == d1.id && v1b.id == v1.id, "同 hash 复用同一 document/variant（去重）")
check(try store.locations(variantId: v1.id).count == 2, "同 hash 不同路径 → variant 下 2 个 location")

// 3) 同 hash 同路径 → 不重复加 location
_ = try store.findOrCreate(hash: "h1", title: "DocA", pageCount: 10, path: "/tmp/a.pdf")
check(try store.locations(variantId: v1.id).count == 2, "同 hash 同路径 → location 不重复")

// 4) 不同 hash → 新 document
let (d2, v2) = try store.findOrCreate(hash: "h2", title: "DocB", pageCount: 12, path: "/tmp/b.pdf")
check(d2.id != d1.id, "不同 hash → 新 document")
check(try store.allDocuments().count == 2, "此时共 2 个 document")

// 5) linkVariant：把 h2 的 variant 并入 d1（多 hash 合并）→ d2 变空被删
check(try store.linkVariant(variantId: v2.id, toDocumentId: d1.id), "linkVariant 返回成功")
check(try store.allDocuments().count == 1, "合并后只剩 1 个 document")
check(try store.variants(documentId: d1.id).count == 2, "d1 现在有 2 个 variant（h1+h2）")
check(try store.locations(documentId: d1.id).count == 3, "d1 跨版本共 3 个 location（a,a-copy,b）")
check(try store.document(id: d2.id) == nil, "空的源 document 已删除")

// 6) 打开探测：h2 的 variant 仍能通过 d1 查到
check(try store.variant(hash: "h2")?.documentId == d1.id, "h2 variant 现归属 d1")

// 7) notes：upsert + 读取 + 更新
let now = Date()
var n = LibNote(id: UUID().uuidString, documentId: d1.id, kind: 2, page: 3,
                anchor: CGRect(x: 1, y: 2, width: 3, height: 4),
                payload: Data("{\"pts\":[[0.1,0.2,0.5]]}".utf8), createdAt: now, updatedAt: now)
try store.upsertNote(n)
check(try store.notes(documentId: d1.id).count == 1, "note 写入后可读")
check(try store.notes(documentId: d1.id, page: 3).count == 1, "按 page 过滤 note")
check(try store.notes(documentId: d1.id, page: 5).isEmpty, "别的 page 无 note")
n.page = 7; n.updatedAt = Date()
try store.upsertNote(n)   // 同 id → 更新
check(try store.notes(documentId: d1.id).count == 1, "同 id upsert 不新增")
check(try store.notes(documentId: d1.id, page: 7).count == 1, "note.page 已更新为 7")
let got = try store.notes(documentId: d1.id).first!
check(got.anchor == CGRect(x: 1, y: 2, width: 3, height: 4) && got.payload == Data("{\"pts\":[[0.1,0.2,0.5]]}".utf8),
      "note anchor/payload 往返一致")

// 7b) 阅读进度往返（含缩放倍率 + 横向比例，schema v5）
try store.updateProgress(documentId: d1.id, page: 5, frac: 0.375, zoom: 1.75, hfrac: 0.4)
let dp = try store.document(id: d1.id)!
check(dp.readPage == 5 && abs(dp.readFrac - 0.375) < 1e-9, "阅读进度写入/读回")
check(abs(dp.readZoom - 1.75) < 1e-9, "缩放倍率写入/读回")
check(abs(dp.readHFrac - 0.4) < 1e-9, "横向比例写入/读回")

// 7c) 工作区内 location（相对路径）增删
let wsLoc = try store.addLocation(variantId: v1.id, path: "PDFs/copy.pdf", inWorkspace: true)
check(try store.inWorkspaceLocations(documentId: d1.id).count == 1, "inWorkspace location 计入")
check(try store.inWorkspaceLocations(documentId: d1.id).first?.inWorkspace == true, "inWorkspace 标志正确")
try store.removeLocation(id: wsLoc.id)
check(try store.inWorkspaceLocations(documentId: d1.id).isEmpty, "removeLocation 后工作区副本清空")

// 7d) addVariant：给 d1 加第三版本 h3
_ = try store.addVariant(documentId: d1.id, hash: "h3", pageCount: 10, path: "/tmp/c.pdf")
check(try store.variant(hash: "h3")?.documentId == d1.id, "addVariant 归属 d1")
check(try store.variants(documentId: d1.id).count == 3, "d1 现有 3 个 variant")

// 7e) mergeDocument：新建 d3(带 note) 并入 d1 → d3 消失、其 note 归 d1
let (d3, _) = try store.findOrCreate(hash: "h9", title: "DocC", pageCount: 8, path: "/tmp/d.pdf")
try store.upsertNote(LibNote(id: UUID().uuidString, documentId: d3.id, kind: 0, page: 1,
                             anchor: .zero, payload: Data("x".utf8), createdAt: Date(), updatedAt: Date()))
check(try store.mergeDocument(sourceId: d3.id, intoTargetId: d1.id), "mergeDocument 成功")
check(try store.document(id: d3.id) == nil, "mergeDocument 后源文档删除")
check(try store.variant(hash: "h9")?.documentId == d1.id, "被并入的 variant 归 d1")
check(try store.notes(documentId: d1.id).contains { $0.page == 1 }, "被并入文档的 note 归 d1")

// 7f) 一级分组（schema v11）：设置 / 读回 / 整组改名 / 解散
try store.setGroup(documentId: d1.id, group: "数学")
check(try store.document(id: d1.id)?.group == "数学", "分组写入/读回")
let (d4, _) = try store.findOrCreate(hash: "h10", title: "DocD", pageCount: 6, path: "/tmp/e.pdf")
check(d4.group.isEmpty, "新文档默认未分组")
try store.setGroup(documentId: d4.id, group: "数学")
try store.renameGroup(from: "数学", to: "物理")
check(try store.document(id: d1.id)?.group == "物理" && store.document(id: d4.id)?.group == "物理", "整组改名")
try store.renameGroup(from: "物理", to: "")
check(try store.document(id: d1.id)?.group.isEmpty == true, "解散分组 → 未分组")
try store.deleteDocument(id: d4.id)

// 8) 级联删除：删 document → variant/location/note 全清
try store.deleteDocument(id: d1.id)
check(try store.allDocuments().isEmpty, "删 document 后无文档")
check(try store.variant(hash: "h1") == nil && store.variant(hash: "h2") == nil, "variant 级联删除")
check(try store.notes(documentId: d1.id).isEmpty, "note 级联删除")

print("\n结果：\(pass) 通过，\(fail) 失败")
exit(fail == 0 ? 0 : 1)
