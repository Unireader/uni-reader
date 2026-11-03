// App 侧的服务器客户端（`ServerClient` + `ServerSyncIO`）对着**真服务器**的端到端测试。方案 SERVER-MODE-PLAN.md §13.3。
// 运行（会自己起一个临时服务器，端口 18790，跑完关掉、删临时目录）：
//   bash spike/server-client-test.sh
//
// ① 配对 ② 上传本地工作区（工作区外的 PDF 被收进去、图片、Notes/）③ 另一台设备建缓存、按需下载 PDF
// ④ 两边各改一处后各跑一轮完整同步（含 20MB 的 PDF 分块上传）⑤ 上传中断后续传 ⑥ 变回本地工作区
// ⑦ 服务器上改名、别的设备拉到 ⑧ 启动页「下载到本机」：建缓存的进度、按大小挑 PDF、只写文件 ⑨ 从服务器删除。
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
// 侧栏那一行的下载进度靠这个回调（`ServerClient.DownloadWatcher`）
final class Seen: @unchecked Sendable { let lock = NSLock(); var values: [Int64] = [] }
let seen = Seen()
let bigBack = root.appendingPathComponent("big-back.pdf")
try await client.downloadPDF(wid, hash: bigHash, to: bigBack) { n in seen.lock.withLock { seen.values.append(n) } }
let reported = seen.lock.withLock { seen.values }
check((try? Data(contentsOf: bigBack)) == big, "20MB 带进度下载，逐字节一致")
check(reported.last == Int64(big.count) && reported == reported.sorted(),
      "进度回调单调递增、最后一次 = 文件大小（共 \(reported.count) 次）")
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
direct.connectionProxyDictionary = [:]      // 同 ServerClient：连服务器不走系统代理
let (_, r1) = try await URLSession(configuration: direct).upload(for: req, from: part.prefix(3 * 1024 * 1024))
check((r1 as? HTTPURLResponse)?.statusCode == 202, "先传 3MB 就断：202")
check(try await client.pdfSize(wid, hash: partHash) == nil, "服务器上还没有完整的")
try await client.uploadPDF(wid, hash: partHash, file: partFile)
check(try await client.pdfSize(wid, hash: partHash) == Int64(part.count), "续传补齐")
let back = root.appendingPathComponent("back.pdf")
try await client.downloadPDF(wid, hash: partHash, to: back)
check((try? Data(contentsOf: back)) == part, "下载回来逐字节一致")

// ============================================================
print("⑥ 变回本地工作区（A 是就地变成缓存的原件）")
let rowsBefore = try specState(a)
do {
    let s = try LibraryStore(workspaceFolder: a); defer { s.close() }
    try s.withMirrorDB { try SyncClient.detach($0) }
}
check(ServerSyncIO.serverLink(of: a) == nil, "库里不再记服务器（App 当它是本地工作区）")
check(ServerSyncIO.findCache(workspaceId: wid, root: root)?.resolvingSymlinksInPath().path == b.resolvingSymlinksInPath().path,
      "「从服务器打开」不再把 A 当缓存，只认 B")
check(try specState(a) == rowsBefore, "资料一行不少")
check(try await client.workspaces().contains { $0.id == wid }, "服务器上那份还在")

// ============================================================
print("⑦ 服务器上改名，别的设备同步时拿到")
let renamed = try await client.renameWorkspace(wid, name: "  改过名的工作区 ")
check(renamed.name == "改过名的工作区", "改名回来的是新名字（去掉首尾空白）")
check(try await client.workspaces().first { $0.id == wid }?.name == "改过名的工作区", "列表里是新名字")
try await ServerSyncIO.closedRound(folder: b, client: client, wid: wid)
check(LibraryStore.peekIdentity(folder: b)?.name == "改过名的工作区", "B 同步一轮拿到新名字")
do {
    _ = try await client.renameWorkspace(wid, name: "   ")
    check(false, "空名字应该被拒")
} catch let e as ServerClient.Failure {
    check(e.status == 400 && !e.isUnsupportedRoute, "空名字 → 400，不当成「服务器太旧」")
}

// ============================================================
print("⑩ 笔记文件：两台设备双向同步（B 是 ③ 的缓存，再建一台 D）")
func readNote(_ folder: URL, _ rel: String) -> String? { try? String(contentsOf: folder.appendingPathComponent(rel), encoding: .utf8) }
func writeNote(_ folder: URL, _ rel: String, _ text: String) throws {
    let u = folder.appendingPathComponent(rel)
    try fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: u)
}
func notesList() async throws -> [String: SyncNotes.Entry] {
    Dictionary(try await client.listNotes(wid).files.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
}
func conflictCopies(_ folder: URL, of name: String) -> [String] {
    let dir = folder.appendingPathComponent("Notes/子目录")
    return ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.hasPrefix("\(name) (冲突 ") }.sorted()
}
func serverNoteText(_ path: String) async throws -> String {
    let tmp = root.appendingPathComponent("dl-\(UUID().uuidString)")
    defer { try? fm.removeItem(at: tmp) }
    _ = try await client.downloadNote(wid, path: path, to: tmp)
    return try String(contentsOf: tmp, encoding: .utf8)
}
var clientD = client
clientD.deviceName = "设备D"
let dDir = root.appendingPathComponent("D")
let d = try await ServerSyncIO.createCache(in: dDir, name: "D", serverURL: base.absoluteString, client: clientD, wid: wid) { _ in }
check(readNote(b, "Notes/子目录/a.md") == "# 笔记", "B 建缓存时拿到了首次上传带上去的笔记")
check(readNote(d, "Notes/子目录/a.md") == "# 笔记", "D 建缓存时也拿到了")

// 用户报的 bug：一台设备新建的笔记，别的设备要能拿到
try writeNote(b, "Notes/操作系统.md", "- 多线程模型\n\t- XXX")
try writeNote(b, "Notes/.obsidian/app.json", "{}")
try writeNote(b, "Notes/.DS_Store", "x")
try writeNote(b, "Notes/半截.md.part", "x")
var rep = try await ServerNoteSync.sync(folder: b, client: client, wid: wid, sources: [], mode: .pushOnly)
check(rep.pushed == 1, "开着时只推：B 新建的笔记传上去了（\(rep.summary)）")
var list = try await notesList()
check(list["Notes/操作系统.md"]?.deleted == false, "服务器清单里有它")
check(!list.keys.contains { $0.contains(".obsidian") || $0.contains(".DS_Store") || $0.hasSuffix(".part") }, "隐藏文件 / 临时文件不上传")
rep = try await ServerNoteSync.sync(folder: b, client: client, wid: wid, sources: [], mode: .pushOnly)
check(!rep.touched, "再推一次什么也不做（基线对上了）")
try await ServerSyncIO.closedRound(folder: d, client: clientD, wid: wid)
check(readNote(d, "Notes/操作系统.md") == "- 多线程模型\n\t- XXX", "D 完整一轮之后拿到了这篇笔记，逐字一致")

// 另一边改 → 这边拿到
try writeNote(d, "Notes/操作系统.md", "- 多线程模型\n\t- 用户级线程")
try await ServerSyncIO.closedRound(folder: d, client: clientD, wid: wid)
try await ServerSyncIO.closedRound(folder: b, client: client, wid: wid)
check(readNote(b, "Notes/操作系统.md") == "- 多线程模型\n\t- 用户级线程", "D 改的正文，B 同步后拿到")

// 两边都改 → 服务器先到的留在原路径，后到的另存冲突副本；两份字节都在，两台设备最后一致
try writeNote(b, "Notes/子目录/a.md", "B 的版本")
try writeNote(d, "Notes/子目录/a.md", "D 的版本")
try await ServerSyncIO.closedRound(folder: b, client: client, wid: wid)
let dRep = try await ServerSyncIO.closedRound(folder: d, client: clientD, wid: wid)
check(readNote(d, "Notes/子目录/a.md") == "B 的版本", "冲突：原路径是先到的 B 的版本")
let dCopies = conflictCopies(d, of: "a")
check(dCopies.count == 1 && readNote(d, "Notes/子目录/" + dCopies[0]) == "D 的版本", "冲突：D 的版本一字不改另存成 \(dCopies.first ?? "?")")
check(dCopies.first?.contains("设备D") == true, "副本名里带设备名")
check(dRep.conflicts.count == 1, "报告里列出了冲突副本")
try await ServerSyncIO.closedRound(folder: b, client: client, wid: wid)
check(conflictCopies(b, of: "a").count == 1 && readNote(b, "Notes/子目录/" + (conflictCopies(b, of: "a").first ?? "")) == "D 的版本",
      "B 也拿到了冲突副本，两台设备都有两份")
check(readNote(b, "Notes/子目录/a.md") == "B 的版本", "B 的原路径没动")

// 开着时（只推）遇到服务器上又变过的：不覆盖，留给下一次完整一轮
try writeNote(b, "Notes/操作系统.md", "B 又改")
try await ServerSyncIO.closedRound(folder: b, client: client, wid: wid)               // 先推上去
try writeNote(d, "Notes/操作系统.md", "D 也改")                                        // D 不知道
rep = try await ServerNoteSync.sync(folder: d, client: clientD, wid: wid, sources: [], mode: .pushOnly)
check(rep.skipped == 1 && rep.pushed == 0, "只推遇到服务器已变：不收、记下来（\(rep.summary)）")
check(readNote(d, "Notes/操作系统.md") == "D 也改", "本机文件没被动")
check(try await serverNoteText("Notes/操作系统.md") == "B 又改", "服务器上还是 B 的")
try await ServerSyncIO.closedRound(folder: d, client: clientD, wid: wid)               // 完整一轮收拾成冲突副本
check(readNote(d, "Notes/操作系统.md") == "B 又改", "完整一轮之后原路径是服务器的")
check(((try? fm.contentsOfDirectory(atPath: d.appendingPathComponent("Notes").path)) ?? []).contains {
    $0.hasPrefix("操作系统 (冲突 ") && readNote(d, "Notes/" + $0) == "D 也改"
}, "D 的内容留在冲突副本里")

// 删除：先归档再删；别的设备本机挪进 .trash，不是抹掉
try fm.removeItem(at: b.appendingPathComponent("Notes/操作系统.md"))
rep = try await ServerNoteSync.sync(folder: b, client: client, wid: wid, sources: [], mode: .pushOnly)
check(rep.removedRemote == 1, "B 删了，服务器上也删（\(rep.summary)）")
list = try await notesList()
check(list["Notes/操作系统.md"]?.deleted == true, "服务器留墓碑")
try await ServerSyncIO.closedRound(folder: d, client: clientD, wid: wid)
check(readNote(d, "Notes/操作系统.md") == nil, "D 同步后这篇没了")
let dTrash = (fm.enumerator(atPath: d.appendingPathComponent("Notes/.trash").path)?.allObjects as? [String]) ?? []
check(dTrash.contains { $0.hasSuffix("操作系统.md") }, "D 把它挪进了 Notes/.trash（\(dTrash.count) 项），没有抹掉")

// 改动优先于删除：一边删、另一边改过 → 留下改过的
try writeNote(d, "Notes/子目录/b.md", "原文")
try await ServerSyncIO.closedRound(folder: d, client: clientD, wid: wid)
try await ServerSyncIO.closedRound(folder: b, client: client, wid: wid)
try fm.removeItem(at: b.appendingPathComponent("Notes/子目录/b.md"))
try await ServerSyncIO.closedRound(folder: b, client: client, wid: wid)                 // 服务器记墓碑
try writeNote(d, "Notes/子目录/b.md", "D 改过")
try await ServerSyncIO.closedRound(folder: d, client: clientD, wid: wid)
check(readNote(d, "Notes/子目录/b.md") == "D 改过", "D 改过的没有被别处的删除带走")
try await ServerSyncIO.closedRound(folder: b, client: client, wid: wid)
check(readNote(b, "Notes/子目录/b.md") == "D 改过", "B 也拿回了改过的版本")

// 服务器上压根没记录（不是墓碑）绝不当成「被删了」
// （人为模拟：D 有基线，把服务器清单里这篇的墓碑换成没有——这里用一个新建、从没上传的路径代替：本机多出的永远只会被上传）
try writeNote(d, "Notes/只在D.md", "d only")
try await ServerSyncIO.closedRound(folder: d, client: clientD, wid: wid)
check(readNote(d, "Notes/只在D.md") == "d only", "只在本机的笔记不会被清掉")
check(try await notesList()["Notes/只在D.md"]?.deleted == false, "而是传上了服务器")

// ============================================================
print("⑩b 引用目录的服务器镜像：本机有 → 传上去；本机没有 → 拉一份只读副本")
let vault = root.appendingPathComponent("外部笔记/vault")
try writeNote(vault.deletingLastPathComponent(), "vault/x.md", "# x")
try writeNote(vault.deletingLastPathComponent(), "vault/sub/y.md", "# y [[x]]")
try writeNote(vault.deletingLastPathComponent(), "vault/img.png", "png")
try writeNote(vault.deletingLastPathComponent(), "vault/.obsidian/cfg.json", "{}")
let srcJSON = "[{\"id\":\"SRC1\",\"kind\":\"reference\",\"name\":\"vault\",\"path\":\"\(vault.path)\",\"paths\":[\"\(vault.path)\"]}]"
for f in [b, d] {
    let st = try LibraryStore(workspaceFolder: f); defer { st.close() }
    try st.setMeta("note_sources", srcJSON)
}
try await ServerSyncIO.closedRound(folder: b, client: client, wid: wid)
list = try await notesList()
check(["x.md", "sub/y.md", "img.png"].allSatisfy { list["NotesMirror/SRC1/\($0)"]?.deleted == false }, "本机有这个目录：整个传上服务器的 NotesMirror/SRC1/（含附件）")
check(!list.keys.contains { $0.contains("NotesMirror/SRC1/.obsidian") }, "隐藏目录不传")
check(readNote(b, "NotesMirror/SRC1/x.md") == nil, "有本机目录的设备不会再往工作区里拉一份")

// D 这台「没有」这个目录：把外部目录挪开再让 D 同步（同一台机器上模拟另一台电脑）
let moved = root.appendingPathComponent("外部笔记/vault-moved")
try fm.moveItem(at: vault, to: moved)
try await ServerSyncIO.closedRound(folder: d, client: clientD, wid: wid)
check(readNote(d, "NotesMirror/SRC1/x.md") == "# x" && readNote(d, "NotesMirror/SRC1/sub/y.md") == "# y [[x]]"
      && readNote(d, "NotesMirror/SRC1/img.png") == "png", "本机没有这个目录：服务器镜像拉到了 NotesMirror/SRC1/，逐字一致")
check(ServerNoteSync.referenceSources(db: try SQLiteDB(path: d.appendingPathComponent("UniReader/library.sqlite").path)).first?.id == "SRC1",
      "从 note_sources 读得到引用目录")

// 目录回来了（本机有）：本机为准，不读镜像；改动、删除都传上去，镜像跟着变
try fm.moveItem(at: moved, to: vault)
try writeNote(vault.deletingLastPathComponent(), "vault/x.md", "# x 改")
try fm.removeItem(at: vault.appendingPathComponent("sub/y.md"))
try await ServerSyncIO.closedRound(folder: b, client: client, wid: wid)
list = try await notesList()
check(list["NotesMirror/SRC1/sub/y.md"]?.deleted == true, "本机删掉的文件，服务器镜像里也删")
// 镜像订阅者：把外部目录再挪走，让 D 当订阅者
try fm.moveItem(at: vault, to: moved)
try await ServerSyncIO.closedRound(folder: d, client: clientD, wid: wid)
check(readNote(d, "NotesMirror/SRC1/x.md") == "# x 改", "订阅的一方跟着更新")
check(readNote(d, "NotesMirror/SRC1/sub/y.md") == nil, "服务器上删掉的，订阅方的副本也清掉")

// 本机目录是空的（外置盘没挂上之类）：什么都不动，别把镜像删光
let emptyDir = root.appendingPathComponent("外部笔记/vault")
try fm.createDirectory(at: emptyDir, withIntermediateDirectories: true)
try await ServerSyncIO.closedRound(folder: b, client: client, wid: wid)
list = try await notesList()
check(list["NotesMirror/SRC1/x.md"]?.deleted == false && list["NotesMirror/SRC1/img.png"]?.deleted == false,
      "本机目录是空的 → 不把服务器上的镜像删光")
try? fm.removeItem(at: emptyDir)
try? fm.moveItem(at: moved, to: vault)

// ============================================================
print("⑩c 开着工作区（S4）：服务器通知 → 拉取，开着的笔记绕开")
let liveB = try LibraryStore(workspaceFolder: b)        // B 现在「开着」：窗口持有这条连接
let liveDB = liveB.withMirrorDB { $0 }
func decodePull(_ rev: UInt64) async throws -> SyncWire.PullResponse { try SyncWire.decodePullResponse(try await client.pull(wid, since: rev)) }

// 没有动静 → 超时回 changed:false
let idle0 = SyncClient.pulledRev(liveDB)
let idleNotes = try await client.listNotes(wid).head
let idleStart = Date()
let idle = try await client.waitForChange(wid, rows: try await decodePull(idle0).head, notes: idleNotes, timeout: 1)
check(!idle.changed && Date().timeIntervalSince(idleStart) >= 0.9, "没动静：wait 挂满超时、changed=false")

// 修订号已经不一样 → 立刻回
let t1 = Date()
let already = try await client.waitForChange(wid, rows: 0, notes: 0, timeout: 20)
check(already.changed && Date().timeIntervalSince(t1) < 2, "已经不一样：wait 立刻回")

// B 挂着等；D 加一条笔记并同步 → B 被叫醒
let headNow = try await decodePull(0).head
let waitStart = Date()
async let woke = client.waitForChange(wid, rows: headNow, notes: idleNotes, timeout: 20)
try await Task.sleep(nanoseconds: 400_000_000)
do {
    let sd = try LibraryStore(workspaceFolder: d); defer { sd.close() }
    try sd.withMirrorDB { db in
        try db.run("""
        INSERT INTO note(id,document_id,kind,page,anchor_x,anchor_y,anchor_w,anchor_h,payload,created_at,updated_at)
        VALUES('N-LIVE','D1',0,0,0,0,0,0,X'7B7D',?,?)
        """, [.text(t(20)), .text(t(20))])
    }
}
try await ServerSyncIO.closedRound(folder: d, client: clientD, wid: wid)
let ch = try await woke
check(ch.changed && ch.rows > headNow && Date().timeIntervalSince(waitStart) < 5, "挂着的 wait 被别的设备的推送叫醒（\(Int(Date().timeIntervalSince(waitStart) * 1000))ms 内）")

// 开着时拉：攒齐页 → 应用到窗口那条连接 → 记修订号；开着的库里出现新行，基线对上（再拉一次没有新东西）
let since0 = SyncClient.pulledRev(liveDB)
let fetched = try await SyncClient.fetchPulled(since: since0, pull: decodePull)
check(fetched.rows.contains { $0.table == "note" && $0.rowId == "N-LIVE" }, "拉到了 D 新加的那条笔记")
_ = try SyncClient.applyPulled(liveDB, folder: b, rows: fetched.rows)
try SyncClient.setPulledRev(liveDB, fetched.head)
check(try liveDB.query("SELECT id FROM note WHERE id='N-LIVE'").count == 1, "开着的库里有了它（没关窗口、没重开）")
check(SyncClient.pulledRev(liveDB) == fetched.head, "拉到的修订号记下了")
check(try SyncClient.localChanges(liveDB, folder: b).isEmpty, "写进来的行基线对上了：不会被当成本机改动推回去")
let again = try await SyncClient.fetchPulled(since: SyncClient.pulledRev(liveDB), pull: decodePull)
check(again.rows.isEmpty && again.head == fetched.head, "再拉一次没有新东西")

// 开着时的笔记文件：编辑器里开着的那篇绕开，其余的照拉
try writeNote(d, "Notes/live.md", "D 写的")
try writeNote(d, "Notes/开着的.md", "D 的新版本")
try await ServerSyncIO.closedRound(folder: d, client: clientD, wid: wid)
try writeNote(b, "Notes/开着的.md", "B 编辑区里还没存的旧字")      // 模拟：B 的编辑器开着这篇
let liveRep = try await ServerNoteSync.sync(folder: b, client: client, wid: wid, sources: [], mode: .full, skip: ["Notes/开着的.md"])
check(readNote(b, "Notes/live.md") == "D 写的", "开着时拉：没开着的笔记拉下来了（\(liveRep.summary)）")
check(readNote(b, "Notes/开着的.md") == "B 编辑区里还没存的旧字", "编辑器里开着的那篇这轮没碰")
check(liveRep.conflicts.isEmpty, "也没有为它造冲突副本")
liveB.close()
try await ServerSyncIO.closedRound(folder: b, client: client, wid: wid)        // 关掉后的完整一轮才处理它
check(((try? fm.contentsOfDirectory(atPath: b.appendingPathComponent("Notes").path)) ?? []).contains { $0.hasPrefix("开着的 (冲突 ") },
      "关掉之后那一轮：两边都改过 → 冲突副本，字一个没丢")

// ============================================================
print("⑧ 启动页「下载到本机」：建缓存（带进度）→ 按大小挑 PDF → 只写文件")
final class Fractions: @unchecked Sendable { let lock = NSLock(); var values: [Double?] = [] }
let fr = Fractions()
let cDir = root.appendingPathComponent("C")
let c = try await ServerSyncIO.createCache(in: cDir, name: "C", serverURL: base.absoluteString, client: client, wid: wid,
                                           progress: { _ in }, fraction: { f in fr.lock.withLock { fr.values.append(f) } })
let fractions = fr.lock.withLock { fr.values }.compactMap { $0 }
check(fractions.contains(1), "资料库下载有字节进度、最后到 100%（\(fractions.count) 次）")
let small = try await ServerSyncIO.pendingPDFs(folder: c, client: client, wid: wid, maxBytes: 1_048_576)
check(small.map(\.documentId) == ["D1"] && small.first?.size == Int64(pdfA.count),
      "上限 1MB：只挑小书 D1，20MB 的大书留着用到再下")
check(small.first.map { !$0.rel.isEmpty && ServerSyncIO.isSafeRelative($0.rel) } == true, "落点是库里记的工作区内路径")
let libBefore = try Data(contentsOf: c.appendingPathComponent("UniReader/library.sqlite"))
final class Ticks: @unchecked Sendable { let lock = NSLock(); var values: [(Int64, Int64)] = [] }
let ticks = Ticks()
try await ServerSyncIO.downloadPDFs(small, folder: c, client: client, wid: wid) { _, _, got, total in
    ticks.lock.withLock { ticks.values.append((got, total)) }
}
check((try? Data(contentsOf: c.appendingPathComponent(small[0].rel))) == pdfA, "小书下到了它的路径，逐字节一致")
let seenTicks = ticks.lock.withLock { ticks.values }
check(seenTicks.last.map { $0.0 == $0.1 } == true && seenTicks.map(\.0) == seenTicks.map(\.0).sorted(),
      "PDF 进度单调、最后 = 总字节数")
check(try Data(contentsOf: c.appendingPathComponent("UniReader/library.sqlite")) == libBefore, "只写文件、库一个字节没动")
check(try await ServerSyncIO.pendingPDFs(folder: c, client: client, wid: wid, maxBytes: 1_048_576).isEmpty,
      "再看一遍：小书已在本机，不再要")
check(try await ServerSyncIO.pendingPDFs(folder: c, client: client, wid: wid, maxBytes: 100 * 1_048_576).map(\.documentId) == ["D2"],
      "上限放到 100MB：只剩大书 D2")
check(!ServerSyncIO.isSafeRelative("../x.pdf") && !ServerSyncIO.isSafeRelative("/etc/x") && !ServerSyncIO.isSafeRelative("PDFs/../../x"),
      "服务器给的路径不许跳出工作区")

// ============================================================
print("⑨ 从服务器删除")
try await client.deleteWorkspace(wid)
check(try await !client.workspaces().contains { $0.id == wid }, "列表里没有它了")
do {
    try await client.deleteWorkspace(wid)
    check(false, "删过的再删应该 404")
} catch let e as ServerClient.Failure {
    check(e.status == 404 && !e.isUnsupportedRoute, "再删一次：404 且带说明（不当成「服务器太旧」）")
}
do {
    try await ServerSyncIO.closedRound(folder: b, client: client, wid: wid)
    check(false, "删掉之后别的设备同步应该失败")
} catch let e as ServerClient.Failure {
    check(e.status == 404, "别的设备同步：404「\(e.errorDescription ?? "")」")
}
// 服务器没有的路由：不带说明的 404 / 405（App 据此提示「服务器程序太旧」）
var bogus = URLRequest(url: base.appendingPathComponent("v1/workspaces/\(wid)/no-such-route"))
bogus.httpMethod = "PATCH"
bogus.setValue("Bearer \(paired.token)", forHTTPHeaderField: "Authorization")
let (bogusBody, bogusResp) = try await URLSession(configuration: direct).data(for: bogus)
let bogusMsg = ((try? JSONSerialization.jsonObject(with: bogusBody)) as? [String: Any])
    .flatMap { $0["error"] as? [String: Any] }?["message"] as? String ?? ""
let bogusFailure = ServerClient.Failure.http((bogusResp as? HTTPURLResponse)?.statusCode ?? 0, bogusMsg)
check(bogusFailure.isUnsupportedRoute, "不存在的接口 → \((bogusResp as? HTTPURLResponse)?.statusCode ?? 0)、没有说明 → 认作「服务器太旧」")

try? fm.removeItem(at: root)
print("\n结果：\(pass) 过，\(fail) 不过")
exit(fail == 0 ? 0 : 1)
