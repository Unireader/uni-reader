// App 侧的服务器客户端（`ServerClient` + `ServerSyncIO`）对着**真服务器**的端到端测试。方案 SERVER-MODE-PLAN.md §13.3。
// 运行（会自己起一个临时服务器，端口 18790，跑完关掉、删临时目录）：
//   bash spike/server-client-test.sh
//
// ① 配对 ② 上传本地工作区（工作区外的 PDF 被收进去、图片、Notes/）③ 另一台设备建缓存、按需下载 PDF
// ④ 两边各改一处后各跑一轮完整同步（含 20MB 的 PDF 分块上传）⑤ 上传中断后续传。
import Foundation

func L(_ s: String) -> String { s }   // App 的 `L()` 走 Bundle 本地化，spike 里原样返回

var pass = 0, fail = 0
func check(_ c: Bool, _ m: String) { if c { pass += 1; print("  ✅ \(m)") } else { fail += 1; print("  ❌ \(m)") } }

let env = ProcessInfo.processInfo.environment
guard let baseStr = env["SERVER_URL"], let base = URL(string: baseStr), let code = env["PAIRING_CODE"] else {
    print("要用 spike/server-client-test.sh 跑（它给 SERVER_URL / PAIRING_CODE）"); exit(2)
}
let fm = FileManager.default
let root = URL(fileURLWithPath: env["WORK_DIR"] ?? NSTemporaryDirectory()).appendingPathComponent("client-\(UUID().uuidString)")
try fm.createDirectory(at: root, withIntermediateDirectories: true)

func t(_ m: Int) -> String { String(format: "2026-10-29T11:%02d:00.000Z", m) }
func sha(_ d: Data) -> String { ImageAssets.sha256(d) }
func randomData(_ n: Int) -> Data { Data((0..<n).map { _ in UInt8.random(in: 0...255) }) }
func noteCount(_ folder: URL, id: String) throws -> Int {
    let s = try LibraryStore(workspaceFolder: folder); defer { s.close() }
    return try s.withMirrorDB { try $0.query("SELECT id FROM note WHERE id=?", [.text(id)]).count }
}
func specState(_ folder: URL) throws -> [String: [String: String]] {
    let s = try LibraryStore(workspaceFolder: folder); defer { s.close() }
    return try s.withMirrorDB { try SyncRows.specState($0) }
}

// ============================================================
print("⓪ 哪些地址不走系统代理")
for h in ["192.168.1.160", "10.0.0.2", "172.20.1.1", "100.95.183.82", "169.254.3.4", "127.0.0.1", "localhost",
          "nas", "nas.local", "fd7a:115c:a1e0::1d01:b756", "[fe80::1]", "::1"] {
    check(ServerClient.connectsDirectly(host: h), "\(h) 直连")
}
for h in ["example.com", "8.8.8.8", "172.32.0.1", "100.128.0.1", "192.169.0.1", "a.b.c.d", "2001:db8::1", ""] {
    check(!ServerClient.connectsDirectly(host: h), "\(h.isEmpty ? "（空）" : h) 跟随系统代理")
}

print("① 配对")
let paired = try await ServerClient.pair(baseURL: base, code: code, deviceName: "spike")
let client = ServerClient(baseURL: base, token: paired.token)
check(paired.schemaVersion == LibraryStore.schemaVersion, "数据版本一致（\(paired.schemaVersion)）")
do {
    _ = try await ServerClient.pair(baseURL: base, code: "WRONGWRONG", deviceName: "x")
    check(false, "错的配对码应该被拒")
} catch let e as ServerClient.Failure {
    check(e.status == 401 && !(e.errorDescription ?? "").isEmpty, "错的配对码 → 401，带服务器给的说明：\(e.errorDescription ?? "")")
}
check(try await client.info().deviceName == "spike", "令牌能用（info）")

// ============================================================
print("② 上传本地工作区")
let a = root.appendingPathComponent("A.unrd")
try fm.createDirectory(at: a, withIntermediateDirectories: true)
var storeA = try LibraryStore(workspaceFolder: a)
try storeA.setWorkspaceName("客户端测试")
let wid = try storeA.ensureWorkspaceId()
let extDir = root.appendingPathComponent("外部")
try fm.createDirectory(at: extDir, withIntermediateDirectories: true)
let pdfA = Data("这是一份工作区外的 PDF".utf8)
let hashA = sha(pdfA)
try pdfA.write(to: extDir.appendingPathComponent("book.pdf"))
let img = Data("png bytes".utf8)
let imgSha = sha(img)
try fm.createDirectory(at: ImageAssets.folder(in: a), withIntermediateDirectories: true)
try img.write(to: ImageAssets.url(in: a, sha256: imgSha, ext: "png"))
try fm.createDirectory(at: a.appendingPathComponent("Notes/子目录"), withIntermediateDirectories: true)
try Data("# 笔记".utf8).write(to: a.appendingPathComponent("Notes/子目录/a.md"))
try storeA.withMirrorDB { db in
    try db.run("INSERT INTO document(id,title,page_count,added_at,last_opened_at) VALUES('D1','书',1,?,?)", [.text(t(0)), .text(t(0))])
    try db.run("INSERT INTO variant(id,document_id,content_hash,page_count,added_at) VALUES('V1','D1',?,1,?)", [.text(hashA), .text(t(0))])
    try db.run("INSERT INTO location(id,variant_id,path,in_workspace) VALUES('L1','V1',?,0)",
               [.text(extDir.appendingPathComponent("book.pdf").path)])
    try db.run("""
    INSERT INTO note(id,document_id,kind,page,anchor_x,anchor_y,anchor_w,anchor_h,payload,created_at,updated_at)
    VALUES('N1','D1',0,0,0,0,0,0,X'7B7D',?,?)
    """, [.text(t(1)), .text(t(1))])
    try db.run("INSERT INTO image(sha256,ext,width,height,bytes,created_at) VALUES(?,'png',1,1,9,?)", [.text(imgSha), .text(t(0))])
}
let plan = try ServerSyncIO.prepareUpload(store: storeA, folder: a, staging: root.appendingPathComponent("staging"))
let rels = plan.files.map(\.rel)
check(rels.contains { $0.hasPrefix("PDFs/") }, "工作区外的 PDF 收进上传清单（\(rels.first { $0.hasPrefix("PDFs/") } ?? "")）")
check(rels.contains("Images/\(imgSha).png"), "图片在清单里")
check(rels.contains("Notes/子目录/a.md"), "Notes/ 下的笔记在清单里")
check(plan.missingPDFs == 0, "没有找不到文件的书")
let ws = try await ServerSyncIO.upload(plan, client: client) { _, _, _ in }
check(ws.id == wid && ws.name == "客户端测试", "登记成功：\(ws.name)")
try storeA.setMeta(SyncClient.metaServerURL, base.absoluteString)
try storeA.withMirrorDB { try SyncClient.writeBase($0, plan.base, pulledRev: ws.head) }
check(try await client.workspaces().map(\.id) == [wid], "工作区列表里有它")
check(try await client.pdfSize(wid, hash: hashA) == Int64(pdfA.count), "PDF 传上去了")
check(try storeA.withMirrorDB { try SyncClient.localChanges($0, folder: a) }.isEmpty, "上传完本机与服务器一致（没有待推的改动）")
storeA.close()

// ============================================================
print("③ 另一台设备：建缓存、按需下载 PDF")
let bDir = root.appendingPathComponent("B")
let b = try await ServerSyncIO.createCache(in: bDir, name: ws.name, serverURL: base.absoluteString,
                                           client: client, wid: wid) { _ in }
check(ServerSyncIO.serverURL(of: b) == base.absoluteString, "缓存记着服务器地址")
check(try noteCount(b, id: "N1") == 1, "笔记在缓存里")
check(ImageAssets.exists(in: b, sha256: imgSha, ext: "png"), "图片补下来了")
check(ServerSyncIO.findCache(workspaceId: wid, root: root)?.resolvingSymlinksInPath().path == b.resolvingSymlinksInPath().path,
      "按 workspace_id 找得到缓存（根目录 / 主机 / 工作区.unrd）")
let got = b.appendingPathComponent("PDFs/\(hashA).pdf")
try await client.downloadPDF(wid, hash: hashA, to: got)
check((try? Data(contentsOf: got)) == pdfA, "PDF 下载下来逐字节一致")

// ============================================================
print("④ 两边各改一处，各跑一轮完整同步")
storeA = try LibraryStore(workspaceFolder: a)
let big = randomData(20 * 1024 * 1024)
let bigHash = sha(big)
try fm.createDirectory(at: a.appendingPathComponent("PDFs"), withIntermediateDirectories: true)
try big.write(to: a.appendingPathComponent("PDFs/big.pdf"))
try storeA.withMirrorDB { db in
    try db.run("INSERT INTO document(id,title,page_count,added_at,last_opened_at) VALUES('D2','大书',1,?,?)", [.text(t(2)), .text(t(2))])
    try db.run("INSERT INTO variant(id,document_id,content_hash,page_count,added_at) VALUES('V2','D2',?,1,?)", [.text(bigHash), .text(t(2))])
    try db.run("INSERT INTO location(id,variant_id,path,in_workspace) VALUES('L2','V2','PDFs/big.pdf',1)")
    try db.run("""
    INSERT INTO note(id,document_id,kind,page,anchor_x,anchor_y,anchor_w,anchor_h,payload,created_at,updated_at)
    VALUES('N2','D2',0,0,0,0,0,0,X'7B7D',?,?)
    """, [.text(t(3)), .text(t(3))])
}
storeA.close()   // 完整一轮只在没有活连接时跑
try await ServerSyncIO.closedRound(folder: a, client: client, wid: wid)
check(try await client.pdfSize(wid, hash: bigHash) == Int64(big.count), "20MB 的 PDF 分块传上去了")
let storeB = try LibraryStore(workspaceFolder: b)
try storeB.withMirrorDB { db in
    try db.run("""
    INSERT INTO note(id,document_id,kind,page,anchor_x,anchor_y,anchor_w,anchor_h,payload,created_at,updated_at)
    VALUES('N3','D1',0,0,0,0,0,0,X'7B7D',?,?)
    """, [.text(t(4)), .text(t(4))])
}
storeB.close()
try await ServerSyncIO.closedRound(folder: b, client: client, wid: wid)
try await ServerSyncIO.closedRound(folder: a, client: client, wid: wid)
check(try noteCount(b, id: "N2") == 1, "B 拉到了 A 新加的笔记")
check(try noteCount(a, id: "N3") == 1, "A 拉到了 B 新加的笔记")
check(try specState(a) == specState(b), "两台设备的行一致")

// ============================================================
print("⑤ 上传中断后续传")
let part = randomData(12 * 1024 * 1024)
let partHash = sha(part)
let partFile = root.appendingPathComponent("part.pdf")
try part.write(to: partFile)
var req = URLRequest(url: base.appendingPathComponent("v1/workspaces/\(wid)/pdf/\(partHash)"))
req.httpMethod = "PUT"
req.setValue("Bearer \(paired.token)", forHTTPHeaderField: "Authorization")
req.setValue("0", forHTTPHeaderField: "Upload-Offset")
req.setValue(String(part.count), forHTTPHeaderField: "Upload-Length")
let direct = URLSessionConfiguration.default
direct.connectionProxyDictionary = [:]      // 同 ServerClient：局域网服务器不走系统代理
let (_, r1) = try await URLSession(configuration: direct).upload(for: req, from: part.prefix(3 * 1024 * 1024))
check((r1 as? HTTPURLResponse)?.statusCode == 202, "先传 3MB 就断：202")
check(try await client.pdfSize(wid, hash: partHash) == nil, "服务器上还没有完整的")
try await client.uploadPDF(wid, hash: partHash, file: partFile)
check(try await client.pdfSize(wid, hash: partHash) == Int64(part.count), "续传补齐")
let back = root.appendingPathComponent("back.pdf")
try await client.downloadPDF(wid, hash: partHash, to: back)
check((try? Data(contentsOf: back)) == part, "下载回来逐字节一致")

try? fm.removeItem(at: root)
print("\n结果：\(pass) 过，\(fail) 不过")
exit(fail == 0 ? 0 : 1)
