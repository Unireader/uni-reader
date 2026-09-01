// 一条 SQLite 连接被多个线程同时用 —— `SQLiteDB` 的锁是不是真的兜住了。运行：
//   cp spike/store-concurrency-test.swift /tmp/main.swift && swiftc Sources/Store/*.swift /tmp/main.swift -o /tmp/sct && /tmp/sct
//
// 🔴 这份用例是有来历的：2026-09-01 用户点「同步」直接崩，日志是主线程渲染侧栏右键菜单时
//    `EXC_BAD_ACCESS in sqlite3DbMallocRawNNTyped`（读地址 0x36），**堆栈里连第二个碰
//    SQLite 的线程都没有**。因为写坏它的那次早就跑完了：离线镜像功能一直在后台线程上用
//    主线程那条连接（建镜像/干跑/合并写入都是），连接自己的 lookaside 分配器被写坏，
//    然后在之后某次毫不相干的 prepare 上炸。
//
//    所以这里要压的不是"结果对不对"，是**在读写同时打满的情况下不许崩、不许丢**。
//    去掉 `SQLiteDB` 里的锁再跑这份用例，它应该崩或者数错 —— 那就是它存在的意义。
import Foundation

var pass = 0, fail = 0
func check(_ c: Bool, _ m: String) { if c { pass += 1; print("  ✅ \(m)") } else { fail += 1; print("  ❌ \(m)") } }

let fm = FileManager.default
let root = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("store_conc_\(UInt64.random(in: 0..<1_000_000))")
try! fm.createDirectory(at: root.appendingPathComponent("PDFs"), withIntermediateDirectories: true)
defer { try? fm.removeItem(at: root) }

let store = try! LibraryStore(workspaceFolder: root)
let rel = "PDFs/a.pdf"
try! Data(repeating: 0x41, count: 256).write(to: root.appendingPathComponent(rel))
let (doc, v0) = try! store.findOrCreate(hash: "h0", title: "并发测试", pageCount: 10, path: rel)
_ = try! store.addLocation(variantId: v0.id, path: rel, inWorkspace: true)

func mkNote(_ id: String, _ w: Int) -> LibNote {
    LibNote(id: id, documentId: doc.id, kind: 2, page: 1,
            anchor: CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4),
            payload: Data("{\"w\":\(w)}".utf8), createdAt: .now, updatedAt: .now)
}

print("① 一个写线程 + 三个读线程同时打满")
// 读的那几路刻意用**界面真正会走的那几个查询**：崩溃堆栈里就是 locations()（侧栏右键菜单
// 每一行都会调 currentFilePath）。写的那路模拟合并期间不停 upsert。
let writes = 400
let readers = 3
let readsEach = 400
var readErrors = [String]()
let errLock = NSLock()

let group = DispatchGroup()
DispatchQueue.global(qos: .userInitiated).async(group: group) {
    for i in 0..<writes {
        do { try store.upsertNote(mkNote("n\(i % 40)", i)) }
        catch { errLock.lock(); readErrors.append("写：\(error)"); errLock.unlock() }
    }
}
for r in 0..<readers {
    DispatchQueue.global(qos: .userInitiated).async(group: group) {
        for _ in 0..<readsEach {
            do {
                _ = try store.locations(documentId: doc.id)
                _ = try store.notes(documentId: doc.id)
                _ = try store.variants(documentId: doc.id)
                _ = try store.allDocuments()
            } catch {
                errLock.lock(); readErrors.append("读\(r)：\(error)"); errLock.unlock()
            }
        }
    }
}
let done = group.wait(timeout: .now() + 60)
check(done == .success, "1 写 + \(readers) 读 × \(readsEach) 轮，60s 内跑完（没死锁）")
check(readErrors.isEmpty, "全程没有一次读写报错（\(readErrors.prefix(3).joined(separator: " / "))）")
check((try! store.notes(documentId: doc.id)).count == 40, "写进去的 40 条一条不少")

print("② 事务与并发读同时进行")
// 合并（MirrorApply）就是「一个大事务写着，界面还在渲染」这个形状。
// 锁是**按语句**粒度的：读得到事务里未提交的中间态是认了的，但绝不许崩、不许死锁。
var txErr: String?
let g2 = DispatchGroup()
DispatchQueue.global(qos: .userInitiated).async(group: g2) {
    do {
        try store.withMirrorDB { db in
            try db.transaction {
                for i in 0..<200 {
                    try db.run("INSERT OR REPLACE INTO meta(key,value) VALUES(?,?)",
                               [.text("k\(i % 20)"), .text("v\(i)")])
                }
            }
        }
    } catch { txErr = "\(error)" }
}
for _ in 0..<readers {
    DispatchQueue.global(qos: .userInitiated).async(group: g2) {
        for _ in 0..<readsEach {
            _ = try? store.allDocuments()
            _ = store.meta("workspace_name")
        }
    }
}
check(g2.wait(timeout: .now() + 60) == .success, "事务 + 并发读，60s 内跑完（没死锁）")
check(txErr == nil, "事务没被并发读搅黄（\(txErr ?? "—")）")
check((try! store.withMirrorDB { try $0.query("SELECT COUNT(*) AS n FROM meta WHERE key LIKE 'k%'") })
        .first?["n"] as? Int64 == 20, "事务里那 20 个键都在")

print("③ 关连接与并发读撞车")
// `WorkspaceRegistry.maybeTeardown` 会在别的线程还在读的时候关连接。
// close() 也要拿锁，否则就是在别人跑语句的时候把句柄拆了 —— 那才是真·UAF。
let store2 = try! LibraryStore(workspaceFolder: root)
let g3 = DispatchGroup()
for _ in 0..<readers {
    DispatchQueue.global(qos: .userInitiated).async(group: g3) {
        for _ in 0..<readsEach { _ = try? store2.allDocuments() }   // 关了之后一律退化成空，不抛不崩
    }
}
DispatchQueue.global(qos: .userInitiated).async(group: g3) {
    Thread.sleep(forTimeInterval: 0.01)
    store2.close()
}
check(g3.wait(timeout: .now() + 60) == .success, "🔴 一边读一边 close，不崩不卡")

store.close()
print("\n通过 \(pass) / 失败 \(fail)")
exit(fail == 0 ? 0 : 1)
