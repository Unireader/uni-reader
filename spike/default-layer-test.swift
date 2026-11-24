// 默认图层按文档区分（v29，2026-11-24，`REQUIREMENTS.md §8`）回归测试：
// 默认图层在库里的行 id = 所属文档 id，模型里照旧是 `00…01`。运行：
//   cp spike/default-layer-test.swift /tmp/main.swift && \
//     swiftc Sources/Store/*.swift /tmp/main.swift -o /tmp/dlt && /tmp/dlt
// （须命名为 main.swift 编译：swiftc 多文件时顶层代码只允许在 main.swift）
//
// 修之前的病：`ink_layer.id` 是全库主键，每篇文档的默认图层都叫 `00…01` → 只有一篇占着那一行，
// 别的文档「补建默认层」其实是改掉那篇的名字 / 颜色 / 可见性。

import Foundation

setvbuf(stdout, nil, _IONBF, 0)

var pass = 0, fail = 0
func check(_ cond: Bool, _ msg: String) {
    if cond { pass += 1; print("  ✅ \(msg)") } else { fail += 1; print("  ❌ \(msg)") }
}

let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("default_layer_test_\(UInt64.random(in: 0..<1_000_000))")
try! FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: tmp) }

let store = try! LibraryStore(workspaceFolder: tmp)
let a = try! store.findOrCreate(hash: "hash-a", title: "A", pageCount: 3, path: "PDFs/a.pdf", isRelative: false).document
let b = try! store.findOrCreate(hash: "hash-b", title: "B", pageCount: 3, path: "PDFs/b.pdf", isRelative: false).document
let def = LibraryStore.defaultInkLayerID

func layer(_ id: String, _ doc: String, _ name: String, visible: Bool = true) -> LibInkLayer {
    LibInkLayer(id: id, documentId: doc, name: name, colorKey: "red", sortOrder: 0, visible: visible, createdAt: .now)
}
func rows() -> [(id: String, doc: String, name: String)] {
    store.withMirrorDB { db in
        (try! db.query("SELECT id, document_id, name FROM ink_layer ORDER BY document_id")).map {
            ($0["id"] as! String, $0["document_id"] as! String, $0["name"] as! String)
        }
    }
}

print("\n— 1) 两篇各建默认层：各占一行，互不覆盖 —")
try! store.upsertInkLayer(layer(def, a.id, "A 的图层", visible: false))
try! store.upsertInkLayer(layer(def, b.id, "B 的图层"))
let r1 = rows()
check(r1.count == 2, "库里两行（修之前只有一行）")
check(r1.contains { $0.id == a.id && $0.doc == a.id && $0.name == "A 的图层" }, "A 的默认层行 id = A 的文档 id")
check(r1.contains { $0.id == b.id && $0.doc == b.id && $0.name == "B 的图层" }, "B 的默认层行 id = B 的文档 id")
let la = try! store.inkLayers(documentId: a.id)
check(la.count == 1 && la[0].id == def && la[0].name == "A 的图层" && la[0].visible == false, "读回来 id 仍是 00…01，A 的名字 / 可见性没被 B 改掉")

print("\n— 2) 改 / 删只动自己那篇 —")
try! store.upsertInkLayer(layer(def.lowercased(), b.id, "B 改名"))
check((try! store.inkLayers(documentId: b.id)).first?.name == "B 改名", "按小写 00…01 改也落在 B 自己那行")
check((try! store.inkLayers(documentId: a.id)).first?.name == "A 的图层", "A 不受影响")
try! store.deleteInkLayer(id: def, documentId: b.id)
check((try! store.inkLayers(documentId: b.id)).isEmpty, "删 B 的默认层")
check((try! store.inkLayers(documentId: a.id)).count == 1, "A 的还在")

print("\n— 3) 老库的默认层行（id = 00…01）打开时改成所属文档 id —")
store.withMirrorDB { db in
    try! db.run("DELETE FROM ink_layer")
    try! db.run("INSERT INTO ink_layer(id,document_id,name,color_key,sort_order,visible,created_at) VALUES(?,?,?,?,?,?,?)",
                [.text(def), .text(b.id), .text("老行"), .text("red"), .int(0), .int(1), .text("2026-08-11T00:00:00Z")])
}
check((try! store.normalizeDefaultInkLayers()) == 1, "改了一行")
let r3 = rows()
check(r3.count == 1 && r3[0].id == b.id && r3[0].name == "老行", "行 id 换成 B 的文档 id，内容不变")
check((try! store.inkLayers(documentId: b.id)).first?.id == def, "读回来仍是默认层")
check((try! store.normalizeDefaultInkLayers()) == 0, "再跑一次什么都不做")

print("\n— 4) 关联为同一文档：源的默认层并进目标 —")
try! store.upsertInkLayer(layer(def, a.id, "A 默认"))
let extra = UUID().uuidString
try! store.upsertInkLayer(layer(extra, b.id, "B 第二层"))
_ = try! store.mergeDocument(sourceId: b.id, intoTargetId: a.id)
let r4 = rows()
check(r4.count == 2, "目标已有默认层：源的默认层删掉，只剩 A 默认 + B 第二层")
check(r4.contains { $0.id == a.id && $0.name == "A 默认" }, "目标的默认层留着")
check(r4.contains { $0.id == extra && $0.doc == a.id }, "别的图层挪到目标名下")

let c = try! store.findOrCreate(hash: "hash-c", title: "C", pageCount: 3, path: "PDFs/c.pdf", isRelative: false).document
let d = try! store.findOrCreate(hash: "hash-d", title: "D", pageCount: 3, path: "PDFs/d.pdf", isRelative: false).document
try! store.upsertInkLayer(layer(def, c.id, "C 默认"))
_ = try! store.mergeDocument(sourceId: c.id, intoTargetId: d.id)
let ld = try! store.inkLayers(documentId: d.id)
check(ld.count == 1 && ld[0].id == def && ld[0].name == "C 默认", "目标没有默认层：源的默认层改成目标的")

print("\n结果：\(pass) 通过，\(fail) 失败")
exit(fail == 0 ? 0 : 1)
