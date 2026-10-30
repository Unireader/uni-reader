import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import XCTest
@testable import UniServerCore
@testable import UniServerHTTP

/// HTTP 层：在进程里直接调路由（`.router`，不开端口）。
final class HTTPTests: XCTestCase {

    private var root: URL!
    private var host: WorkspaceHost!
    private var store: ServerStore!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("unireader-http-test-\(UUID().uuidString)", isDirectory: true)
        let paths = ServerPaths(root: root.appendingPathComponent("data", isDirectory: true))
        host = try WorkspaceHost(paths: paths)
        store = try ServerStore(paths: paths)
    }

    override func tearDown() {
        host.closeAll()
        store.close()
        try? FileManager.default.removeItem(at: root)
    }

    private func app() -> some ApplicationProtocol {
        UniServerApp.application(host: host, store: store, address: .hostname("127.0.0.1", port: 0))
    }

    private struct Paired: Decodable { let deviceId: String; let token: String; let schemaVersion: Int }
    private struct Upload: Decodable { let upload: String }
    private struct Workspace: Decodable { let id: String; let name: String; let head: UInt64 }
    private struct Workspaces: Decodable { let workspaces: [Workspace] }

    private static let json: HTTPFields = [.contentType: "application/json"]
    private static let offset = HTTPField.Name("Upload-Offset")!
    private static let length = HTTPField.Name("Upload-Length")!

    private func auth(_ token: String, _ extra: HTTPFields = [:]) -> HTTPFields {
        var h = extra
        h[.authorization] = "Bearer \(token)"
        return h
    }

    private func decode<T: Decodable>(_ type: T.Type, _ r: TestResponse) throws -> T {
        try JSONDecoder().decode(type, from: Data(r.body.readableBytesView))
    }

    private func pair(_ client: any TestClientProtocol) async throws -> String {
        let body = ByteBuffer(string: #"{"code":"\#(try store.pairingCode())","deviceName":"测试平板"}"#)
        return try await client.execute(uri: "/v1/pair", method: .post, headers: Self.json, body: body) { r in
            XCTAssertEqual(r.status, .ok)
            return try self.decode(Paired.self, r).token
        }
    }

    /// 续传一段：`Upload-Offset` / `Upload-Length` + 这段字节。
    private func put(_ client: any TestClientProtocol, _ uri: String, _ token: String,
                     _ data: Data, from: Int, to: Int, total: Int) async throws -> TestResponse {
        try await client.execute(uri: uri, method: .put,
                                 headers: auth(token, [Self.offset: String(from), Self.length: String(total)]),
                                 body: ByteBuffer(bytes: data[from..<to]))
    }

    // MARK: - 配对与令牌

    func testPairingAuthAndRateLimit() async throws {
        try await app().test(.router) { client in
            try await client.execute(uri: "/v1/workspaces", method: .get) { XCTAssertEqual($0.status, .unauthorized) }
            let token = try await self.pair(client)
            try await client.execute(uri: "/v1/workspaces", method: .get, headers: self.auth(token)) { r in
                XCTAssertEqual(r.status, .ok)
                XCTAssertEqual(try self.decode(Workspaces.self, r).workspaces.count, 0)
            }
            try await client.execute(uri: "/v1/info", method: .get, headers: self.auth(token)) { r in
                XCTAssertTrue(String(buffer: r.body).contains("测试平板"))
            }
            try await client.execute(uri: "/v1/workspaces", method: .get, headers: self.auth("x" + token)) {
                XCTAssertEqual($0.status, .unauthorized)
            }
            let bad = ByteBuffer(string: #"{"code":"WRONGWRONG","deviceName":"x"}"#)
            for _ in 0..<5 {
                try await client.execute(uri: "/v1/pair", method: .post, headers: Self.json, body: bad) {
                    XCTAssertEqual($0.status, .unauthorized)
                }
            }
            let good = ByteBuffer(string: #"{"code":"\#(try self.store.pairingCode())","deviceName":"x"}"#)
            try await client.execute(uri: "/v1/pair", method: .post, headers: Self.json, body: good) {
                XCTAssertEqual($0.status, .tooManyRequests, "试错太多，正确的配对码也先拒一分钟")
            }
        }
    }

    // MARK: - 上传 → 快照 → 推送 / 拉取

    func testUploadSnapshotPushPull() async throws {
        // 设备上的本地工作区：一本书、一条笔记、一份 PDF
        let local = root.appendingPathComponent("mac.unrd", isDirectory: true)
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        let lib = try LibraryStore(workspaceFolder: local)
        try lib.setWorkspaceName("HTTP 测试")
        try lib.ensureWorkspaceId()
        let pdf = Data("fake pdf bytes".utf8)
        let pdfHash = ServerCrypto.sha256Hex(pdf)
        try FileManager.default.createDirectory(at: local.appendingPathComponent("PDFs"), withIntermediateDirectories: true)
        try pdf.write(to: local.appendingPathComponent("PDFs/book.pdf"))
        try lib.withMirrorDB { db in
            try db.run("INSERT INTO document(id,title,page_count,added_at,last_opened_at) VALUES('D1','书',1,'t','t')")
            try db.run("INSERT INTO variant(id,document_id,content_hash,page_count,added_at) VALUES('V1','D1',?,1,'t')", [.text(pdfHash)])
            try db.run("INSERT INTO location(id,variant_id,path,in_workspace) VALUES('L1','V1','PDFs/book.pdf',1)")
            try db.run("""
            INSERT INTO note(id,document_id,kind,page,anchor_x,anchor_y,anchor_w,anchor_h,payload,created_at,updated_at)
            VALUES('N1','D1',0,0,0,0,0,0,X'7B7D','t','t')
            """)
        }
        lib.checkpointTruncate()
        let libCopy = root.appendingPathComponent("upload.sqlite")
        try lib.vacuumInto(libCopy.path)
        lib.close()
        let libData = try Data(contentsOf: libCopy)

        try await app().test(.router) { client in
            let token = try await self.pair(client)
            let up = try await client.execute(uri: "/v1/uploads", method: .post, headers: self.auth(token)) {
                try self.decode(Upload.self, $0).upload
            }
            let libURI = "/v1/uploads/\(up)/file?path=UniReader/library.sqlite"
            let half = libData.count / 2

            // 传一半 → 202；偏移不对 → 409（告诉客户端从哪接着传）；传完 → 201
            var r = try await self.put(client, libURI, token, libData, from: 0, to: half, total: libData.count)
            XCTAssertEqual(r.status, .accepted)
            XCTAssertEqual(r.headers[Self.offset], String(half))
            try await client.execute(uri: libURI, method: .head, headers: self.auth(token)) { r in
                XCTAssertEqual(r.status, .notFound)
                XCTAssertEqual(r.headers[Self.offset], String(half))
            }
            r = try await self.put(client, libURI, token, libData, from: 0, to: half, total: libData.count)
            XCTAssertEqual(r.status, .conflict)
            XCTAssertEqual(r.headers[Self.offset], String(half))
            r = try await self.put(client, libURI, token, libData, from: half, to: libData.count, total: libData.count)
            XCTAssertEqual(r.status, .created)

            r = try await self.put(client, "/v1/uploads/\(up)/file?path=PDFs/book.pdf", token, pdf,
                                   from: 0, to: pdf.count, total: pdf.count)
            XCTAssertEqual(r.status, .created)
            r = try await self.put(client, "/v1/uploads/\(up)/file?path=../escape.pdf", token, pdf,
                                   from: 0, to: pdf.count, total: pdf.count)
            XCTAssertEqual(r.status, .badRequest, "越出上传文件夹的路径不收")

            let ws = try await client.execute(uri: "/v1/uploads/\(up)/finish", method: .post, headers: self.auth(token)) {
                XCTAssertEqual($0.status, .ok)
                return try self.decode(Workspace.self, $0)
            }
            XCTAssertEqual(ws.name, "HTTP 测试")
            try await client.execute(uri: "/v1/workspaces", method: .get, headers: self.auth(token)) {
                XCTAssertEqual(try self.decode(Workspaces.self, $0).workspaces.map(\.id), [ws.id])
            }

            // 快照：建另一台设备的缓存
            let cache = self.root.appendingPathComponent("pad.unrd", isDirectory: true)
            try FileManager.default.createDirectory(at: cache.appendingPathComponent("UniReader"), withIntermediateDirectories: true)
            let rev = try await client.execute(uri: "/v1/workspaces/\(ws.id)/snapshot", method: .get,
                                               headers: self.auth(token)) { r -> UInt64 in
                XCTAssertEqual(r.status, .ok)
                try Data(r.body.readableBytesView).write(to: cache.appendingPathComponent("UniReader/library.sqlite"))
                return UInt64(r.headers[UniServerApp.revHeader] ?? "") ?? 0
            }
            XCTAssertEqual(rev, ws.head)
            let pad = try LibraryStore(workspaceFolder: cache)
            defer { pad.close() }
            try pad.withMirrorDB { db in
                XCTAssertEqual(try db.query("SELECT title FROM document").first?["title"] as? String, "书")
                try SyncClient.resetBase(db, folder: cache, pulledRev: rev)
                try db.run("""
                INSERT INTO note(id,document_id,kind,page,anchor_x,anchor_y,anchor_w,anchor_h,payload,created_at,updated_at)
                VALUES('N2','D1',0,0,0,0,0,0,X'7B7D','t2','t2')
                """)
            }

            // 推送（二进制）
            let changes = try pad.withMirrorDB { try SyncClient.localChanges($0, folder: cache) }
            XCTAssertEqual(changes.map(\.rowId), ["N2"])
            let pushBody = SyncWire.encode(SyncWire.PushRequest(schemaVersion: LibraryStore.schemaVersion, changes: changes))
            let resp = try await client.execute(uri: "/v1/workspaces/\(ws.id)/push", method: .post,
                                                headers: self.auth(token), body: ByteBuffer(bytes: pushBody)) { r in
                XCTAssertEqual(r.status, .ok)
                return try SyncWire.decodePushResponse(Data(r.body.readableBytesView))
            }
            XCTAssertEqual(resp.results.map(\.outcome), [.applied])
            _ = try pad.withMirrorDB { try SyncClient.applyPushResponse($0, folder: cache, pushed: changes, response: resp) }

            // 拉取（二进制）
            try await client.execute(uri: "/v1/workspaces/\(ws.id)/pull?since=\(rev)", method: .get,
                                     headers: self.auth(token)) { r in
                let pull = try SyncWire.decodePullResponse(Data(r.body.readableBytesView))
                XCTAssertEqual(pull.rows.map(\.rowId), ["N2"])
                XCTAssertEqual(pull.head, resp.head)
            }

            // 版本不一致 → 409
            let stale = SyncWire.encode(SyncWire.PushRequest(schemaVersion: LibraryStore.schemaVersion - 1, changes: []))
            try await client.execute(uri: "/v1/workspaces/\(ws.id)/push", method: .post,
                                     headers: self.auth(token), body: ByteBuffer(bytes: stale)) {
                XCTAssertEqual($0.status, .conflict)
            }
            // PDF 随上传带上去了
            try await client.execute(uri: "/v1/workspaces/\(ws.id)/pdf/\(pdfHash)", method: .head, headers: self.auth(token)) {
                XCTAssertEqual($0.status, .ok)
            }
        }
    }

    // MARK: - PDF：续传上传、Range 下载

    func testPDFResumableUploadAndRangeDownload() async throws {
        let dir = try host.newUploadFolder()
        let lib = try LibraryStore(workspaceFolder: dir)
        try lib.ensureWorkspaceId()
        lib.close()
        let ws = try host.install(uploaded: dir)
        let data = Data("0123456789".utf8)
        let hash = ServerCrypto.sha256Hex(data)
        let uri = "/v1/workspaces/\(ws.id)/pdf/\(hash)"

        try await app().test(.router) { client in
            let token = try await self.pair(client)
            try await client.execute(uri: uri, method: .head, headers: self.auth(token)) { r in
                XCTAssertEqual(r.status, .notFound)
                XCTAssertEqual(r.headers[Self.offset], "0")
            }
            var r = try await self.put(client, uri, token, data, from: 0, to: 4, total: 10)
            XCTAssertEqual(r.status, .accepted)
            try await client.execute(uri: uri, method: .head, headers: self.auth(token)) {
                XCTAssertEqual($0.headers[Self.offset], "4", "断了之后查得到传到哪了")
            }
            r = try await self.put(client, uri, token, data, from: 4, to: 10, total: 10)
            XCTAssertEqual(r.status, .created)
            r = try await self.put(client, uri, token, data, from: 0, to: 10, total: 10)
            XCTAssertEqual(r.status, .ok, "已经有了就不再收")

            try await client.execute(uri: uri, method: .get, headers: self.auth(token, [.range: "bytes=2-5"])) { r in
                XCTAssertEqual(r.status, .partialContent)
                XCTAssertEqual(String(buffer: r.body), "2345")
                XCTAssertEqual(r.headers[.contentRange], "bytes 2-5/10")
            }
            try await client.execute(uri: uri, method: .get, headers: self.auth(token)) {
                XCTAssertEqual(String(buffer: $0.body), "0123456789")
                // 网页里的 pdf.js 看这两个头决定改用分段下载（大书不必整本下完才显示）
                XCTAssertEqual($0.headers[.contentLength], "10")
                XCTAssertEqual($0.headers[.acceptRanges], "bytes")
            }

            // 内容和声明的哈希对不上 → 422，半截文件作废
            let other = ServerCrypto.sha256Hex(Data("别的".utf8))
            r = try await self.put(client, "/v1/workspaces/\(ws.id)/pdf/\(other)", token, data, from: 0, to: 10, total: 10)
            XCTAssertEqual(r.status, .unprocessableContent)
            try await client.execute(uri: "/v1/workspaces/\(ws.id)/pdf/\(other)", method: .head, headers: self.auth(token)) {
                XCTAssertEqual($0.headers[Self.offset], "0")
            }

            try await client.execute(uri: "/v1/workspaces/\(ws.id)/pdf/not-a-hash", method: .get, headers: self.auth(token)) {
                XCTAssertEqual($0.status, .badRequest)
            }
            try await client.execute(uri: "/v1/workspaces/\(UUID().uuidString)/pdf/\(hash)", method: .get,
                                     headers: self.auth(token)) {
                XCTAssertEqual($0.status, .notFound)
            }
            try await client.execute(uri: "/v1/workspaces/\(ws.id)/image/abc.png", method: .head, headers: self.auth(token)) {
                XCTAssertEqual($0.status, .badRequest)
            }
        }
    }

    // MARK: - 局域网发现与服务器身份

    func testDiscoveryTXTAndServerIdentity() async throws {
        XCTAssertEqual(DiscoveryAdvertiser.txtRecord([("v", "1"), ("id", "AB")]),
                       [3] + Array("v=1".utf8) + [5] + Array("id=AB".utf8), "RFC 6763：每项 1 字节长度 + key=value")
        XCTAssertEqual(DiscoveryAdvertiser.txtRecord([("k", String(repeating: "x", count: 300))]).count, 256, "超长截到 255")
        let id = try store.serverId()
        XCTAssertFalse(id.isEmpty)
        XCTAssertEqual(try store.serverId(), id, "服务器身份不变")
        let app = UniServerApp.application(host: host, store: store, name: "书房的 Mac", address: .hostname("127.0.0.1", port: 0))
        try await app.test(.router) { client in
            let body = ByteBuffer(string: #"{"code":"\#(try self.store.pairingCode())","deviceName":"平板"}"#)
            let token = try await client.execute(uri: "/v1/pair", method: .post, headers: Self.json, body: body) { r in
                XCTAssertTrue(String(buffer: r.body).contains(id), "配对响应带服务器身份")
                return try self.decode(Paired.self, r).token
            }
            try await client.execute(uri: "/v1/info", method: .get, headers: self.auth(token)) { r in
                let s = String(buffer: r.body)
                XCTAssertTrue(s.contains(id) && s.contains("书房的 Mac"), "info 带服务器身份与名字：\(s)")
            }
        }
    }

    /// 改名（PATCH）与删除（DELETE）：删除后列表里没了、再操作 404；回收站里有它。
    func testRenameAndDeleteWorkspace() async throws {
        let up = try host.newUploadFolder()
        let lib = try LibraryStore(workspaceFolder: up)
        try lib.setWorkspaceName("要删的")
        let id = try lib.ensureWorkspaceId()
        lib.checkpointTruncate()
        lib.close()
        try host.install(uploaded: up)

        try await app().test(.router) { client in
            let token = try await self.pair(client)
            let rename = ByteBuffer(string: #"{"name":"新名字"}"#)
            try await client.execute(uri: "/v1/workspaces/\(id)", method: .patch,
                                     headers: self.auth(token, Self.json), body: rename) { r in
                XCTAssertEqual(r.status, .ok)
                let w = try self.decode(Workspace.self, r)
                XCTAssertEqual(w.name, "新名字")
                XCTAssertGreaterThan(w.head, 0)
            }
            try await client.execute(uri: "/v1/workspaces/\(id)", method: .patch,
                                     headers: self.auth(token, Self.json), body: ByteBuffer(string: #"{"name":"  "}"#)) {
                XCTAssertEqual($0.status, .badRequest, "空名字拒绝")
            }
            try await client.execute(uri: "/v1/workspaces/\(id)", method: .delete) {
                XCTAssertEqual($0.status, .unauthorized, "删除也要令牌")
            }
            try await client.execute(uri: "/v1/workspaces/\(id)", method: .delete, headers: self.auth(token)) {
                XCTAssertEqual($0.status, .noContent)
            }
            try await client.execute(uri: "/v1/workspaces", method: .get, headers: self.auth(token)) { r in
                XCTAssertEqual(try self.decode(Workspaces.self, r).workspaces.count, 0)
            }
            try await client.execute(uri: "/v1/workspaces/\(id)", method: .delete, headers: self.auth(token)) {
                XCTAssertEqual($0.status, .notFound)
            }
            try await client.execute(uri: "/v1/workspaces/\(id)/pull?since=0", method: .get, headers: self.auth(token)) {
                XCTAssertEqual($0.status, .notFound)
            }
        }
        let deleted = host.deletedWorkspaces()
        XCTAssertEqual(deleted.map(\.id), [id])
        XCTAssertEqual(deleted.first?.name, "新名字")
        XCTAssertEqual(deleted.first?.device, "测试平板")
    }

    // MARK: - 网页阅读器

    /// 网页本身不要令牌（带内容安全策略）；只认网页目录里的普通文件；书目接口照旧要令牌。
    func testWebPageWithoutTokenAndDocuments() async throws {
        let webDir = root.appendingPathComponent("web", isDirectory: true)
        try FileManager.default.createDirectory(at: webDir.appendingPathComponent("assets"), withIntermediateDirectories: true)
        try Data("<!doctype html><title>UniReader</title>".utf8).write(to: webDir.appendingPathComponent("index.html"))
        try Data("console.log(1)".utf8).write(to: webDir.appendingPathComponent("assets/app-1.js"))
        try Data("secret".utf8).write(to: webDir.appendingPathComponent("assets/.env"))

        let dir = try host.newUploadFolder()
        let lib = try LibraryStore(workspaceFolder: dir)
        try lib.ensureWorkspaceId()
        let pdf = Data("fake pdf".utf8), hash = ServerCrypto.sha256Hex(pdf)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("PDFs"), withIntermediateDirectories: true)
        try pdf.write(to: dir.appendingPathComponent("PDFs/book.pdf"))
        try lib.withMirrorDB { db in
            try db.run("INSERT INTO document(id,title,page_count,added_at,last_opened_at) VALUES('D1','书',1,'t','t')")
            try db.run("INSERT INTO variant(id,document_id,content_hash,page_count,added_at) VALUES('V1','D1',?,1,'t')", [.text(hash)])
            try db.run("INSERT INTO location(id,variant_id,path,in_workspace) VALUES('L1','V1','PDFs/book.pdf',1)")
        }
        lib.close()
        let ws = try host.install(uploaded: dir)

        let app = UniServerApp.application(host: host, store: store, web: WebFiles(directory: webDir),
                                           address: .hostname("127.0.0.1", port: 0))
        try await app.test(.router) { client in
            try await client.execute(uri: "/", method: .get) { r in
                XCTAssertEqual(r.status, .ok)
                XCTAssertTrue(String(buffer: r.body).contains("UniReader"))
                XCTAssertEqual(r.headers[.contentType], "text/html; charset=utf-8")
                XCTAssertNotNil(r.headers[HTTPField.Name("Content-Security-Policy")!])
            }
            try await client.execute(uri: "/assets/app-1.js", method: .get) { r in
                XCTAssertEqual(r.status, .ok)
                XCTAssertEqual(r.headers[.contentType], "text/javascript; charset=utf-8")
            }
            for uri in ["/assets/.env", "/assets/nope.js", "/library.sqlite"] {
                try await client.execute(uri: uri, method: .get) { XCTAssertEqual($0.status, .notFound, uri) }
            }

            let docs = "/v1/workspaces/\(ws.id)/documents"
            try await client.execute(uri: docs, method: .get) { XCTAssertEqual($0.status, .unauthorized) }
            let token = try await self.pair(client)
            try await client.execute(uri: docs, method: .get, headers: self.auth(token)) { r in
                XCTAssertEqual(r.status, .ok)
                let body = String(buffer: r.body)
                XCTAssertTrue(body.contains(hash), body)
                XCTAssertTrue(body.contains(#""pageCount":1"#), body)
            }

            // W2：打开一本书 / 页上的标记 / 修订号
            let book = "/v1/workspaces/\(ws.id)/documents/D1"
            try await client.execute(uri: "\(book)/view?hash=\(hash)", method: .get) { XCTAssertEqual($0.status, .unauthorized) }
            try await client.execute(uri: "\(book)/view?hash=\(hash)", method: .get, headers: self.auth(token)) { r in
                XCTAssertEqual(r.status, .ok)
                XCTAssertTrue(String(buffer: r.body).contains(#""layers":[]"#), String(buffer: r.body))
            }
            try await client.execute(uri: "\(book)/view?hash=..%2F", method: .get, headers: self.auth(token)) {
                XCTAssertEqual($0.status, .badRequest)
            }
            try await client.execute(uri: "\(book)/marks?from=0&to=3", method: .get, headers: self.auth(token)) { r in
                XCTAssertEqual(r.status, .ok)
                XCTAssertEqual(String(buffer: r.body), #"{"marks":[]}"#)
            }
            for q in ["", "?from=2&to=1", "?from=-1&to=1", "?from=a&to=1"] {
                try await client.execute(uri: "\(book)/marks\(q)", method: .get, headers: self.auth(token)) {
                    XCTAssertEqual($0.status, .badRequest, q)
                }
            }
            try await client.execute(uri: "/v1/workspaces/\(ws.id)/documents/nope/marks?from=0&to=1", method: .get,
                                     headers: self.auth(token)) { XCTAssertEqual($0.status, .notFound) }
            try await client.execute(uri: "/v1/workspaces/\(ws.id)/head", method: .get, headers: self.auth(token)) { r in
                XCTAssertEqual(r.status, .ok)
                XCTAssertTrue(String(buffer: r.body).hasPrefix(#"{"head":"#), String(buffer: r.body))
            }

            // W3：写一条文字笔记，取回来（payload 原样、带 updatedAt）；坏请求整批 400
            let id = "44444444-4444-4444-4444-444444444444"
            let edit = #"{"upserts":[{"id":"\#(id)","kind":0,"page":0,"anchor":[0.5,0.5,0,0],"payload":"{\"quote\":\"\",\"text\":\"网页写的\",\"rects\":[]}"}],"deletes":[]}"#
            try await client.execute(uri: "\(book)/edits", method: .post, headers: Self.json, body: ByteBuffer(string: edit)) {
                XCTAssertEqual($0.status, .unauthorized)
            }
            try await client.execute(uri: "\(book)/edits", method: .post, headers: self.auth(token, Self.json),
                                     body: ByteBuffer(string: edit)) { r in
                XCTAssertEqual(r.status, .ok)
                struct Resp: Decodable { struct Item: Decodable { let id: String; let outcome: String }; let updatedAt: String; let results: [Item] }
                let resp = try self.decode(Resp.self, r)
                XCTAssertEqual(resp.results.map(\.id), [id])
                XCTAssertEqual(resp.results.map(\.outcome), ["applied"])
                XCTAssertFalse(resp.updatedAt.isEmpty)
            }
            try await client.execute(uri: "\(book)/marks?from=0&to=0", method: .get, headers: self.auth(token)) { r in
                let body = String(buffer: r.body)
                XCTAssertTrue(body.contains("网页写的") && body.contains(#""updatedAt":"#), body)
            }
            let badPoints = edit.replacingOccurrences(of: #""kind":0"#, with: #""kind":2,"points":"不是base64""#)
            for bad in [badPoints, #"{"upserts":[{"id":"x"}],"deletes":[]}"#,
                        edit.replacingOccurrences(of: id, with: "not-a-uuid")] {
                try await client.execute(uri: "\(book)/edits", method: .post, headers: self.auth(token, Self.json),
                                         body: ByteBuffer(string: bad)) { XCTAssertEqual($0.status, .badRequest, bad) }
            }
        }
    }

    func testParseRange() {
        XCTAssertEqual(UniServerApp.parseRange("bytes=0-0", size: 10), 0...0)
        XCTAssertEqual(UniServerApp.parseRange("bytes=5-", size: 10), 5...9)
        XCTAssertEqual(UniServerApp.parseRange("bytes=-3", size: 10), 7...9)
        XCTAssertEqual(UniServerApp.parseRange("bytes=8-100", size: 10), 8...9)
        XCTAssertNil(UniServerApp.parseRange("bytes=10-", size: 10))
        XCTAssertNil(UniServerApp.parseRange("bytes=1-2,4-5", size: 10))
        XCTAssertNil(UniServerApp.parseRange("items=1-2", size: 10))
    }
}
