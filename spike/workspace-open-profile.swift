// 工作区打开耗时剖析。回答「稍大的工作区打开为什么慢」——把 `DocTabModel.load()` 那一串
// 同步加载逐段计时，跑在**真实工作区的副本**上（绝不碰用户的库：`LibraryStore.init` 会跑 migrate）。
//
// 运行（顶层代码须在 main.swift，故先改名再编译）：
//   T=/tmp/wop && mkdir -p $T && cp spike/workspace-open-profile.swift $T/main.swift
//   # 库要用**副本**：LibraryStore.init 会跑 migrate，别在用户的库上量
//   mkdir -p $T/ws/UniReader && cp "<工作区>/UniReader/library.sqlite" $T/ws/UniReader/
//   swiftc -O Sources/Store/*.swift Sources/App/InkModel.swift Sources/App/PenPreset.swift \
//          Sources/App/InkLayerModel.swift Sources/App/NoteTypeModel.swift Sources/Support/L.swift \
//          $T/main.swift -o $T/wop
//   $T/wop $T/ws "<真实工作区目录（解相对 PDF 路径用）>"
//
// ⚠️ `-O` 很重要：Debug 构建的 JSON 解码慢一个量级，量出来的比例会失真。App 是 Release 跑的。

import Foundation
import PDFKit

func ms(_ t: CFAbsoluteTime) -> String { String(format: "%7.1f ms", t * 1000) }

@discardableResult
func time<T>(_ label: String, _ body: () throws -> T) rethrows -> T {
    let t0 = CFAbsoluteTimeGetCurrent()
    let r = try body()
    print("  \(ms(CFAbsoluteTimeGetCurrent() - t0))  \(label)")
    return r
}

let args = CommandLine.arguments
guard args.count >= 3 else {
    print("用法：wop <工作区副本目录> <真实工作区目录>")
    exit(2)
}
let copyFolder = URL(fileURLWithPath: args[1])
let realFolder = URL(fileURLWithPath: args[2])

print("=== 工作区打开耗时剖析 ===")
print("库副本：\(copyFolder.path)")

let tOpen = CFAbsoluteTimeGetCurrent()
let store = try LibraryStore(workspaceFolder: copyFolder)
print("  \(ms(CFAbsoluteTimeGetCurrent() - tOpen))  LibraryStore 打开 + migrate")

let docs = time("allDocuments()（WorkspaceManager.refresh）") { (try? store.allDocuments()) ?? [] }
print("  文档数：\(docs.count)")

// `refDocIndex()`：每篇查 locations + variant（syncWorkspaceSnapshot 每次换文档都跑）
time("refDocIndex 等价：每篇 locations + variant") {
    for d in docs {
        let locs = (try? store.locations(documentId: d.id)) ?? []
        if let l = locs.first { _ = try? store.variant(id: l.variantId) }
    }
}

print()
for d in docs {
    print("── \(d.title)（\(d.pageCount) 页）")

    // 1) 今天的 load()：inkStrokes / textNotes / highlights / aiThreads / scratchStrokes
    //    **五个都调 `notes(documentId:)`**（无 kind 过滤，全表 payload 都读回来），再在 Swift 里筛。
    var rows: [LibNote] = []
    let t1 = CFAbsoluteTimeGetCurrent()
    rows = (try? store.notes(documentId: d.id)) ?? []
    let one = CFAbsoluteTimeGetCurrent() - t1
    let bytes = rows.reduce(0) { $0 + $1.payload.count }
    print("  \(ms(one))  notes(documentId:) 一次 —— \(rows.count) 行 / \(bytes / 1024) KB payload")

    let t5 = CFAbsoluteTimeGetCurrent()
    for _ in 0..<4 { _ = (try? store.notes(documentId: d.id)) ?? [] }
    print("  \(ms(CFAbsoluteTimeGetCurrent() - t5 + one))  ×5（**旧** load()：五个 loader 各读一次全表）")

    // 现在的 load()：五个 loader 各查各的 kind（0 文字注解 / 1 AI 会话 / 2 页内笔迹 / 3 高亮 / 4 草稿纸笔迹）
    time("×5 窄查（**今天** load()：按 kind 各取各的）") {
        for k in [2, 0, 3, 1, 4] { _ = (try? store.notes(documentId: d.id, kind: k)) ?? [] }
    }

    // 2) 解码：kind=2 笔迹、kind=4 草稿纸笔迹
    let k2 = rows.filter { $0.kind == 2 }, k4 = rows.filter { $0.kind == 4 }
    time("解码 InkStroke kind=2（\(k2.count) 条）") { k2.compactMap { InkStroke(note: $0) } }
    time("解码 InkStroke kind=4（\(k4.count) 条）") { k4.compactMap { InkStroke(note: $0) } }

    // 3) 对比：按 kind 过滤的 SQL（本剖析要验证的优化方向）
    let db = try SQLiteDB(path: copyFolder.appendingPathComponent("UniReader/library.sqlite").path)
    time("对比 · SELECT … WHERE document_id=? AND kind=2") {
        _ = try? db.query("SELECT * FROM note WHERE document_id=? AND kind=2 ORDER BY page ASC, created_at ASC",
                          [.text(d.id)])
    }
    time("对比 · 只取 kind 计数（不读 payload）") {
        _ = try? db.query("SELECT kind, count(*) c FROM note WHERE document_id=? GROUP BY kind", [.text(d.id)])
    }
    db.close()

    // 4) 其余小项
    time("inkLayers + scratchPads + document(id:)") {
        _ = try? store.inkLayers(documentId: d.id)
        _ = try? store.scratchPads(documentId: d.id)
        _ = try? store.document(id: d.id)
    }

    // 5) PDF 打开 + 目录构建（用**真实**工作区解相对路径）
    let locs = ((try? store.locations(documentId: d.id)) ?? [])
    if let loc = locs.first {
        let p = loc.isRelative
            ? realFolder.appendingPathComponent(loc.path).standardizedFileURL.path
            : loc.path
        if FileManager.default.fileExists(atPath: p) {
            let pdf = time("PDFDocument(url:)") { PDFDocument(url: URL(fileURLWithPath: p)) }
            if let pdf {
                time("目录构建（outline 递归 + index(for:) + bounds）") {
                    var n = 0
                    func walk(_ o: PDFOutline) {
                        for i in 0..<o.numberOfChildren {
                            guard let c = o.child(at: i) else { continue }
                            n += 1
                            if let dest = c.destination, let page = dest.page {
                                let idx = pdf.index(for: page)
                                if idx >= 0, idx < pdf.pageCount { _ = page.bounds(for: .cropBox) }
                            }
                            walk(c)
                        }
                    }
                    if let root = pdf.outlineRoot { walk(root) }
                    print("        （\(n) 个目录项）")
                }
                // 页尺寸表：PageLayout(doc:) 要逐页问 bounds
                time("逐页 bounds（PageLayout 初始化，\(pdf.pageCount) 页）") {
                    var h = 0.0
                    for i in 0..<pdf.pageCount {
                        if let pg = pdf.page(at: i) { h += pg.bounds(for: .cropBox).height }
                    }
                    return h
                }
            }
        } else {
            print("  （PDF 不在：\(p)）")
        }
    }
    print()
}

store.close()
print("说明：以上是**单篇**的账。冷启动 `restoreTabs` 一口气恢复上次开着的那几篇，每篇都要走一遍。")
