// Mac ↔ 安卓经服务器互通的 Mac 这一半（方案 SERVER-MODE-PLAN.md S3 验收「Mac ↔ 安卓经服务器互通」）。
// 由 spike/android-server-e2e.sh 调，不单独跑：
//   seed           Mac 造一个工作区传上去（一本书 + 一条笔记 MAC-N1），打印它的 workspace id
//   verify <wid>   ① 安卓在 Mac 那个工作区里加的书签（payload 含「安卓加的」）拉下来了
//                  ② 安卓传上去的「安卓e2e」Mac 能建缓存：书签都在、图片在、PDF 下得下来且哈希对得上
// 环境变量 SERVER_URL / PAIRING_CODE / WORK_DIR 同 server-client-test。
import Foundation

func L(_ s: String) -> String { s }

var pass = 0, fail = 0
func check(_ c: Bool, _ m: String) { if c { pass += 1; print("  ✅ \(m)") } else { fail += 1; print("  ❌ \(m)") } }

let env = ProcessInfo.processInfo.environment
guard let base = env["SERVER_URL"].flatMap(URL.init(string:)), let code = env["PAIRING_CODE"] else { exit(2) }
let fm = FileManager.default
let root = URL(fileURLWithPath: env["WORK_DIR"] ?? NSTemporaryDirectory()).appendingPathComponent("interop-\(UUID().uuidString)")
try fm.createDirectory(at: root, withIntermediateDirectories: true)
let paired = try await ServerClient.pair(baseURL: base, code: code, deviceName: "Mac interop")
let client = ServerClient(baseURL: base, token: paired.token)
let t0 = "2026-10-29T12:00:00.000Z"

func payloads(_ folder: URL, doc: String) throws -> [String] {
    let s = try LibraryStore(workspaceFolder: folder); defer { s.close() }
    return try s.withMirrorDB { db in
        try db.query("SELECT payload FROM note WHERE document_id=?", [.text(doc)]).compactMap {
            ($0["payload"] as? Data).flatMap { String(data: $0, encoding: .utf8) } ?? ($0["payload"] as? String)
        }
    }
}

switch CommandLine.arguments.dropFirst().first {
case "seed":
    let m = root.appendingPathComponent("Mac.unrd")
    try fm.createDirectory(at: m.appendingPathComponent("PDFs"), withIntermediateDirectories: true)
    let pdf = Data("%PDF-1.4\n% mac interop\n".utf8) + Data(repeating: 0x2A, count: 200_000)
    try pdf.write(to: m.appendingPathComponent("PDFs/mac.pdf"))
    let store = try LibraryStore(workspaceFolder: m)
    try store.setWorkspaceName("Mac建的")
    _ = try store.ensureWorkspaceId()
    try store.withMirrorDB { db in
        try db.run("INSERT INTO document(id,title,page_count,added_at,last_opened_at) VALUES('MD1','Mac 的书',1,?,?)", [.text(t0), .text(t0)])
        try db.run("INSERT INTO variant(id,document_id,content_hash,page_count,added_at) VALUES('MV1','MD1',?,1,?)",
                   [.text(ImageAssets.sha256(pdf)), .text(t0)])
        try db.run("INSERT INTO location(id,variant_id,path,in_workspace) VALUES('ML1','MV1','PDFs/mac.pdf',1)")
        try db.run("""
        INSERT INTO note(id,document_id,kind,page,anchor_x,anchor_y,anchor_w,anchor_h,payload,created_at,updated_at)
        VALUES('MAC-N1','MD1',0,0,0.1,0.1,0,0,X'7B7D',?,?)
        """, [.text(t0), .text(t0)])
    }
    let plan = try ServerSyncIO.prepareUpload(store: store, folder: m, staging: root.appendingPathComponent("staging"))
    let ws = try await ServerSyncIO.upload(plan, client: client) { _, _, _ in }
    store.close()
    print("MAC_WORKSPACE=\(ws.id)")

case "verify":
    let macWid = CommandLine.arguments[2]
    print("① 安卓在 Mac 建的工作区里加的书签")
    let mc = try await ServerSyncIO.createCache(in: root.appendingPathComponent("c1"), name: "m", serverURL: base.absoluteString,
                                                client: client, wid: macWid) { _ in }
    let p1 = try payloads(mc, doc: "MD1")
    check(p1.contains { $0.contains("安卓加的") }, "Mac 拉到了安卓加的书签（MD1 共 \(p1.count) 条笔记）")

    print("② 安卓传上去的工作区，Mac 能建缓存")
    guard let aws = try await client.workspaces().first(where: { $0.name == "安卓e2e" }) else {
        check(false, "服务器上有「安卓e2e」"); break
    }
    let ac = try await ServerSyncIO.createCache(in: root.appendingPathComponent("c2"), name: "a", serverURL: base.absoluteString,
                                                client: client, wid: aws.id) { _ in }
    let s = try LibraryStore(workspaceFolder: ac)
    let docs = try s.withMirrorDB { try $0.query("SELECT id FROM document") }.compactMap { $0["id"] as? String }
    let hash = try s.withMirrorDB { try $0.query("SELECT content_hash FROM variant") }.first?["content_hash"] as? String
    let imgs = try s.withMirrorDB { try $0.query("SELECT sha256, ext FROM image") }
    s.close()
    check(docs.count == 1, "一本书")
    let p2 = try payloads(ac, doc: docs.first ?? "")
    for want in ["A 的书签", "B2", "开着时加的"] { check(p2.contains { $0.contains(want) }, "书签「\(want)」在") }
    check(!p2.contains { $0.contains("\"A2\"") }, "安卓上删掉的 A2 不在")
    if let im = imgs.first, let sha = im["sha256"] as? String, let ext = im["ext"] as? String {
        check(ImageAssets.exists(in: ac, sha256: sha, ext: ext), "图片补下来了")
    } else {
        check(false, "有图片行")
    }
    if let hash {
        let dst = root.appendingPathComponent("a.pdf")
        try await client.downloadPDF(aws.id, hash: hash, to: dst)
        check(ImageAssets.sha256(try Data(contentsOf: dst)) == hash, "PDF 下得下来，哈希对得上")
    }

default:
    print("用法：seed | verify <wid>"); exit(2)
}
try? fm.removeItem(at: root)
print("\n\(pass) 通过，\(fail) 失败")
exit(fail == 0 ? 0 : 1)
