// 网页（静态 HTML 课件，`docs/WEB-DOC-PLAN.md`）回归测试：清单编解码 / 路径规则 / 按路径找文件 / Range /
// 导入文件夹 / `web_doc` + `web_kv` 的库读写 / 回收站回环 / 指纹表 / 脚本注入。运行：
//   cp spike/web-doc-test.swift /tmp/main.swift && \
//     swiftc Sources/Store/*.swift Sources/App/TrashModel.swift Sources/App/WebBridgeScript.swift /tmp/main.swift -o /tmp/wd && /tmp/wd
// （须命名为 main.swift 编译：swiftc 多文件时顶层代码只允许在 main.swift）

import Foundation

setvbuf(stdout, nil, _IONBF, 0)

var pass = 0, fail = 0
func check(_ cond: Bool, _ msg: String) {
    if cond { pass += 1; print("  ✅ \(msg)") } else { fail += 1; print("  ❌ \(msg)") }
}

let fm = FileManager.default
let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("web_doc_test_\(UInt64.random(in: 0..<1_000_000))")
try? fm.removeItem(at: tmp)
try! fm.createDirectory(at: tmp, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: tmp) }

print("① 路径规则")
check(WebAssets.isSafeRelative("index.html"), "普通文件名")
check(WebAssets.isSafeRelative("img/a b.png"), "带子目录与空格")
for bad in ["", "/etc/passwd", "../x", "a/../b", "a//b", "./a", "a\\b", "a/", "a\u{0}b"] {
    check(!WebAssets.isSafeRelative(bad), "拒绝 \(bad.debugDescription)")
}

print("② 清单编解码")
let h1 = String(repeating: "a", count: 64), h2 = String(repeating: "b", count: 64)
let e1 = WebAssets.Entry(p: "z.css", h: h1, n: 3), e2 = WebAssets.Entry(p: "index.html", h: h2, n: 10)
let json = WebAssets.encode([e1, e2])
check(json == WebAssets.encode([e2, e1]), "编码与输入顺序无关（按路径排序）")
check(json.hasPrefix("[{\"h\":"), "键序固定（sortedKeys）")
check(WebAssets.decode(json) == [e2, e1], "解码回环")
check(WebAssets.decode("{坏的") == [], "坏 JSON = 空")
check(WebAssets.decode("[{\"p\":\"../x\",\"h\":\"\(h1)\",\"n\":1},{\"p\":\"a\",\"h\":\"XYZ\",\"n\":1}]") == [], "不安全的路径 / 不是哈希的条目丢掉")
check(WebAssets.hashes(json) == [h1, h2], "清单里的哈希")

print("③ 按路径找文件 / 入口")
let map: [String: WebAssets.Entry] = [
    "index.html": e2, "z.css": e1,
    "ch1/index.html": WebAssets.Entry(p: "ch1/index.html", h: h1, n: 1),
]
check(WebAssets.resolve("/", in: map)?.p == "index.html", "根 = index.html")
check(WebAssets.resolve("/z.css", in: map)?.p == "z.css", "普通文件")
check(WebAssets.resolve("ch1/", in: map)?.p == "ch1/index.html", "子目录带斜杠")
check(WebAssets.resolve("ch1", in: map)?.p == "ch1/index.html", "子目录不带斜杠")
check(WebAssets.resolve("Z.css", in: map) == nil, "大小写敏感")
check(WebAssets.defaultEntry([e1, e2]) == "index.html", "入口优先 index.html")
check(WebAssets.defaultEntry([WebAssets.Entry(p: "b/x.html", h: h1, n: 1), WebAssets.Entry(p: "intro.htm", h: h1, n: 1)]) == "intro.htm",
      "没有 index 时挑最浅的 html")
check(WebAssets.mimeType(path: "a/B.JS").hasPrefix("text/javascript"), "类型按扩展名（不分大小写）")
check(WebAssets.mimeType(path: "x.unknown") == "application/octet-stream", "不认识的类型")

print("④ Range")
check(WebAssets.byteRange("bytes=0-99", size: 1000) == 0...99, "a-b")
check(WebAssets.byteRange("bytes=900-", size: 1000) == 900...999, "a-")
check(WebAssets.byteRange("bytes=-100", size: 1000) == 900...999, "-n")
check(WebAssets.byteRange("bytes=0-5000", size: 1000) == 0...999, "结尾越界截到文件尾")
check(WebAssets.byteRange("bytes=1000-", size: 1000) == nil, "起点越界")
check(WebAssets.byteRange("bytes=0-1,5-6", size: 1000) == nil, "多段不认")
check(WebAssets.byteRange(nil, size: 1000) == nil, "没有 Range")

print("⑤ 导入文件夹")
let src = tmp.appendingPathComponent("course")
let ws = tmp.appendingPathComponent("ws.unrd")
try! fm.createDirectory(at: src.appendingPathComponent("img"), withIntermediateDirectories: true)
try! fm.createDirectory(at: src.appendingPathComponent(".git"), withIntermediateDirectories: true)
try! Data("<html><head><title>课件</title></head><body>hi</body></html>".utf8).write(to: src.appendingPathComponent("index.html"))
try! Data("body{}".utf8).write(to: src.appendingPathComponent("style.css"))
try! Data("body{}".utf8).write(to: src.appendingPathComponent("img/same.css"))   // 同内容另一个路径
try! Data(repeating: 7, count: 3000).write(to: src.appendingPathComponent("img/a.png"))
try! Data("x".utf8).write(to: src.appendingPathComponent(".DS_Store"))
try! Data("x".utf8).write(to: src.appendingPathComponent(".git/HEAD"))
let entries = try! WebAssets.importFolder(src, into: ws)
check(Set(entries.map(\.p)) == ["index.html", "style.css", "img/same.css", "img/a.png"], "隐藏文件 / .git 不进清单")
check(WebAssets.storedHashes(in: ws).count == 3, "同内容的两个文件只存一份")
let png = entries.first { $0.p == "img/a.png" }!
check(png.n == 3000 && WebAssets.exists(in: ws, sha256: png.h), "文件进了 Web/<sha>")
check((try? WebAssets.sha256Hex(fileAt: WebAssets.url(in: ws, sha256: png.h))) == png.h, "文件名就是内容哈希")
check((try? WebAssets.read(WebAssets.url(in: ws, sha256: png.h), range: 10...19))?.count == 10, "按段读")
do {
    let empty = tmp.appendingPathComponent("empty"); try fm.createDirectory(at: empty, withIntermediateDirectories: true)
    _ = try WebAssets.importFolder(empty, into: ws)
    check(false, "空文件夹应报错")
} catch let e as WebAssets.ImportError { check(e == .empty, "空文件夹报 .empty") } catch { check(false, "错误类型不对") }
do {
    let noHTML = tmp.appendingPathComponent("nohtml"); try fm.createDirectory(at: noHTML, withIntermediateDirectories: true)
    try Data("a".utf8).write(to: noHTML.appendingPathComponent("a.txt"))
    _ = try WebAssets.importFolder(noHTML, into: ws)
    check(false, "没有 html 应报错")
} catch let e as WebAssets.ImportError { check(e == .noHTML, "没有 html 报 .noHTML") } catch { check(false, "错误类型不对") }

let wroteSha = try! WebAssets.write(Data("<p>agent</p>".utf8), to: ws)
check(WebAssets.exists(in: ws, sha256: wroteSha) && (try? WebAssets.sha256Hex(fileAt: WebAssets.url(in: ws, sha256: wroteSha))) == wroteSha,
      "内存里的字节按内容哈希落盘（Agent 写文件那条路）")
check((try? WebAssets.write(Data("<p>agent</p>".utf8), to: ws)) == wroteSha, "同样的字节再写一次：同一个哈希、不重复存")
try? fm.removeItem(at: WebAssets.url(in: ws, sha256: wroteSha))

print("⑥ 库：web_doc / web_kv")
let store = try! LibraryStore(workspaceFolder: ws)
let now = Date(timeIntervalSince1970: 1_800_000_000)
let doc = LibWebDoc(id: UUID().uuidString, title: "课件", entry: "index.html", manifest: WebAssets.encode(entries),
                    bytes: entries.reduce(0) { $0 + $1.n }, createdAt: now, updatedAt: now, lastOpenedAt: now)
try! store.upsertWebDoc(doc)
check((try? store.webDoc(id: doc.id)) == doc, "存了读回来一样")
check((try? store.webDocs().count) == 1, "列表")
check((try? store.webFileHashes()) == Set(entries.map(\.h)), "清单里的全部哈希")
try! store.setWebKV(webId: doc.id, key: "progress", value: "{\"ch\":3}")
try! store.setWebKV(webId: doc.id, key: "done", value: "[1,2]")
check((try? store.webKVValue(webId: doc.id, key: "progress")) == "{\"ch\":3}", "读一个键")
check((try? store.webKV(webId: doc.id).map(\.key)) == ["done", "progress"], "按键排序列出")
let fpBefore = try! store.withMirrorDB { try MirrorStore.fingerprints($0, MirrorFp.spec("web_kv")!) }
try! store.setWebKV(webId: doc.id, key: "progress", value: "{\"ch\":3}", at: now.addingTimeInterval(99))
let fpAfter = try! store.withMirrorDB { try MirrorStore.fingerprints($0, MirrorFp.spec("web_kv")!) }
check(fpBefore == fpAfter, "值没变就不改 updated_at（同步不当成改动）")
try! store.removeWebKV(webId: doc.id, key: "done")
check((try? store.webKV(webId: doc.id).count) == 1, "删一个键")
check((try? store.webKVUsage(webId: doc.id).count) == 1, "用量统计")
check(MirrorFp.spec("web_doc")?.lww == "updated_at" && MirrorFp.spec("web_kv")?.lww == "updated_at", "两张表都进了同步、按 updated_at 取新")
check(!(MirrorFp.spec("web_doc")?.columns.contains { $0.name == "last_opened_at" } ?? true), "last_opened_at 不进指纹")

print("⑦ 回收站回环")
let snap = tmp.appendingPathComponent("snap.sqlite").path
let a = try! store.archiveWebDoc(id: doc.id, to: snap)
check(a.counts.webDoc == 1 && a.counts.total == 1, "归档数到一份网页")
check(Set(a.webFiles) == Set(entries.map(\.h)), "归档记下了要护住的文件")
try! store.deleteWebDoc(id: doc.id)
check((try? store.webDoc(id: doc.id)) == nil && (try? store.webKV(webId: doc.id).count) == 0, "删掉连同存的数据")
let restored = try! store.restoreTrash(snapshot: snap, remapDocumentId: nil)
check(restored == 2, "恢复写回两行（网页 + 一个键）")
check((try? store.webDoc(id: doc.id))?.manifest == doc.manifest, "清单原样回来")
check((try? store.webKVValue(webId: doc.id, key: "progress")) == "{\"ch\":3}", "存的数据也回来")
var m = Trash.Manifest(); m.kind = .webDoc; m.webFiles = a.webFiles
check((try? Trash.decode(Trash.encode(m)))?.webFiles == a.webFiles, "manifest 编解码带 webFiles")
let oldManifest = Data("{\"v\":1,\"kind\":\"board\",\"deletedAt\":\"2026-01-01T00:00:00Z\",\"title\":\"x\",\"documentId\":\"\",\"documentTitle\":\"\",\"pageCount\":0,\"counts\":{},\"images\":[],\"contentHashes\":[]}".utf8)
check((try? Trash.decode(oldManifest)) != nil, "老 manifest（没有 webFiles 键）照样读得出来")

print("⑧ 清理")
let orphan = Data("orphan".utf8)
let orphanSha = String(repeating: "c", count: 64)
try! orphan.write(to: WebAssets.url(in: ws, sha256: orphanSha))
check(WebAssets.purge(in: ws, keep: try! store.webFileHashes(), olderThan: Date().addingTimeInterval(-86_400)) == 0, "刚写的孤儿文件不删（一天内）")
check(WebAssets.purge(in: ws, keep: try! store.webFileHashes(), olderThan: .distantFuture) == 1, "到期的孤儿文件删掉")
check(WebAssets.storedHashes(in: ws) == Set(entries.map(\.h)), "还在用的一个不少")

print("⑨ 脚本注入")
let js = WebBridgeScript.source(webId: doc.id, title: "课</script>件", transport: .fetch(api: "/t/x/__unireader__/api"))
check(js.contains("fetch(") && js.contains("__unireader__"), "脚本里有 API 地址（斜杠按 JSON 转义）")
check(!js.contains("</script>"), "标题里的 </script> 被转义（不会提前结束 script 标签）")
let html = Data("<!doctype html><HTML><Head lang=\"zh\"><title>x</title></head><body></body></html>".utf8)
let injected = String(decoding: WebBridgeScript.inject("A()", into: html), as: UTF8.self)
check(injected.contains("<Head lang=\"zh\"><script>A()</script><title>"), "插在 <head> 开头（不分大小写、带属性）")
let bare = String(decoding: WebBridgeScript.inject("A()", into: Data("<p>hi</p>".utf8)), as: UTF8.self)
check(bare == "<script>A()</script><p>hi</p>", "没有 head 就放最前面")

store.close()
print(fail == 0 ? "\n✅ 全部通过：\(pass) 通过 / 0 失败" : "\n❌ \(fail) 失败 / \(pass) 通过")
exit(fail == 0 ? 0 : 1)
