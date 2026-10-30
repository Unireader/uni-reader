import XCTest
@testable import UniServerCore

/// 推送 / 拉取 / 冲突 / 级联 / 文件：用两台「设备」对着同一个服务器工作区交错改动，最后三方必须一致。
final class SyncTests: XCTestCase {

    // MARK: - 上传与快照

    func testInstallSeedsRevisionsAndSnapshotIsClean() throws {
        let f = try Fixture()
        let a = try f.makeDevice("mac")
        try Seed.addDoc(a, "D1", title: "高等数学")
        try Seed.addNote(a, "N1", doc: "D1", text: "极限", at: 1)
        try Seed.addNote(a, "N2", doc: "D1", text: "导数", at: 2)
        let hash = try Seed.addPDF(a, doc: "D1", bytes: "pdf-1")
        // 外部引用的 PDF（上传设备的本地路径）到了服务器上要被去掉
        try a.db { db in
            let vid = try db.query("SELECT id FROM variant").first!["id"] as! String
            try db.run("INSERT INTO location(id,variant_id,path,in_workspace) VALUES('L-ext',?,'/Users/x/a.pdf',0)", [.text(vid)])
            try db.run("INSERT INTO location(id,variant_id,path,in_workspace) VALUES('L-up',?,'../../../etc/hosts',1)", [.text(vid)])
            try db.run("""
            INSERT INTO ocr_page(content_hash,page,provider,payload,created_at) VALUES(?,0,'paddle',?,?)
            """, [.text(hash), .blob(Data("{}".utf8)), .text(Seed.t(0))])
            try db.run("INSERT INTO meta(key,value) VALUES('open_documents','[\"D1\"]')")
        }

        let ws = try f.upload(a)
        XCTAssertEqual(f.host.list().map(\.name), ["测试工作区"])
        // 每一行一个修订号：document 1 + note 2 + variant 1 + meta(workspace_name) 1 + ocr 1
        XCTAssertEqual(ws.head, 6)
        XCTAssertEqual(try f.serverState(ws), try a.specState())
        try ws.store.withMirrorDB { db in
            let locs = try db.query("SELECT id FROM location").compactMap { $0["id"] as? String }
            XCTAssertFalse(locs.contains("L-ext"), "外部引用的路径在服务器上无意义")
            XCTAssertFalse(locs.contains("L-up"), "落到工作区外的路径一律不认")
            XCTAssertEqual(locs.count, 1)
            XCTAssertTrue(try db.query("SELECT value FROM meta WHERE key='open_documents'").isEmpty)
        }
        XCTAssertNotNil(ws.pdfFile(contentHash: hash))

        let snap = f.root.appendingPathComponent("snap.sqlite")
        XCTAssertEqual(try ws.exportSnapshot(to: snap), 6)
        let db = try SQLiteDB(path: snap.path)
        defer { db.close() }
        XCTAssertTrue(try db.query("SELECT name FROM sqlite_master WHERE name='srv_rev'").isEmpty)
        XCTAssertTrue(try db.query("SELECT value FROM meta WHERE key='srv_head_rev'").isEmpty)
        XCTAssertEqual(try SyncRows.specState(db), try a.specState())

        XCTAssertThrowsError(try f.upload(a)) { XCTAssertEqual($0 as? ServerError, .alreadyHosted(ws.id)) }
    }

    /// 登记时 PDF 内容与 variant 的哈希对不上（传坏了 / 本地文件被原地改过）→ 这条 location 不认。
    func testInstallDropsFileWithWrongHash() throws {
        let f = try Fixture()
        let a = try f.makeDevice("mac")
        try Seed.addDoc(a, "D1", title: "书")
        let hash = try Seed.addPDF(a, doc: "D1", bytes: "原来的内容")
        let rel = try a.db { try $0.query("SELECT path FROM location").first?["path"] as? String }!
        try Data("被改过的内容".utf8).write(to: a.folder.appendingPathComponent(rel))
        let ws = try f.upload(a)
        XCTAssertNil(ws.pdfFile(contentHash: hash))
        try ws.store.withMirrorDB { XCTAssertTrue(try $0.query("SELECT id FROM location").isEmpty) }
        XCTAssertEqual(try f.serverState(ws), try a.specState(), "只是文件不认，行照常同步")
    }

    /// 「变回本地工作区」：服务器的记录（地址 / 身份 / 修订号 / 基线）全部去掉，资料一行不少。
    func testDetachMakesItLocalAgain() throws {
        let f = try Fixture()
        let a = try f.makeDevice("mac")
        try Seed.addDoc(a, "D1", title: "书")
        try Seed.addNote(a, "N1", doc: "D1", text: "笔记", at: 1)
        let ws = try f.upload(a)
        try a.store.setMeta(SyncClient.metaServerURL, "http://127.0.0.1:8790")
        try a.store.setMeta(SyncClient.metaServerID, "SERVER-ID")
        let before = try a.specState()

        try a.db { try SyncClient.detach($0) }
        for k in [SyncClient.metaServerURL, SyncClient.metaServerID, SyncClient.metaPulledRev] {
            XCTAssertNil(a.store.meta(k), "\(k) 应该去掉")
        }
        try a.db { db in
            XCTAssertTrue(try db.query("SELECT name FROM sqlite_master WHERE name='sync_base'").isEmpty)
            XCTAssertEqual(SyncClient.pulledRev(db), 0)
        }
        XCTAssertEqual(try a.specState(), before, "资料不动")
        XCTAssertEqual(try f.serverState(ws), before, "服务器上那份不动")
        XCTAssertNoThrow(try a.db { try SyncClient.detach($0) }, "再来一次也不出错")
    }

    // MARK: - 两台设备交错改动

    func testTwoDevicesConverge() throws {
        let f = try Fixture()
        let mac = try f.makeDevice("mac")
        try Seed.addDoc(mac, "D1", title: "高等数学")
        for (i, id) in ["X", "Y", "Z"].enumerated() { try Seed.addNote(mac, id, doc: "D1", text: id, at: i) }
        let ws = try f.upload(mac)
        let pad = try f.cache(ws, as: "pad")
        XCTAssertEqual(try pad.specState(), try mac.specState())

        // Mac：加 N1、改 X（10 分）、删 Y
        try Seed.addNote(mac, "N1", doc: "D1", text: "mac 新加", at: 5)
        try Seed.editNote(mac, "X", text: "mac 改的", at: 10)
        try Seed.deleteRow(mac, "note", "Y")
        let r1 = try mac.sync(ws)
        XCTAssertEqual(r1.pushed, 3)
        XCTAssertTrue(r1.push.results.allSatisfy { $0.outcome == .applied })

        // 平板（还没拉过）：也改 X 但更早（8 分）、改 Z、加 N2
        try Seed.editNote(pad, "X", text: "pad 改的", at: 8)
        try Seed.editNote(pad, "Z", text: "pad 改 Z", at: 9)
        try Seed.addNote(pad, "N2", doc: "D1", text: "pad 新加", at: 9)
        let r2 = try pad.sync(ws)
        let outcome = Dictionary(uniqueKeysWithValues: r2.push.results.map { ($0.rowId, $0.outcome) })
        XCTAssertEqual(outcome["X"], .keptServer, "两边都改 X：Mac 那份更新（10 分 > 8 分），服务器保留")
        XCTAssertEqual(outcome["Z"], .applied)
        XCTAssertEqual(outcome["N2"], .applied)
        XCTAssertEqual(r2.push.conflicts.count, 1)
        XCTAssertEqual(try Seed.noteText(pad, "X"), "mac 改的", "服务器保留的那份随推送响应回到平板")
        XCTAssertNil(try Seed.noteText(pad, "Y"), "Mac 删的 Y 拉下来也删了")
        XCTAssertEqual(try Seed.noteText(pad, "N1"), "mac 新加")

        try mac.sync(ws)
        XCTAssertEqual(try Seed.noteText(mac, "N2"), "pad 新加")
        XCTAssertEqual(try Seed.noteText(mac, "Z"), "pad 改 Z")

        let server = try f.serverState(ws)
        XCTAssertEqual(try mac.specState(), server)
        XCTAssertEqual(try pad.specState(), server)

        // 再来一轮什么都不该发生
        let quiet = try mac.sync(ws)
        XCTAssertEqual(quiet.pushed, 0)
        XCTAssertEqual(try pad.sync(ws).pushed, 0)
        XCTAssertEqual(try mac.specState(), try f.serverState(ws))
    }

    /// 引用的笔记目录列表（`meta.note_sources`，2026-10-29 起同步）：两台电脑各给同一个目录加了自己的路径，
    /// 经服务器后两边都是合并后的那份（路径取并集），不报冲突，再来一轮什么都不发生。
    func testNoteSourcesMergePathsAcrossDevices() throws {
        func sources(_ paths: [String]) -> String {
            let o: [String: Any] = ["id": "R1", "kind": "reference", "name": "vault", "path": paths[0], "paths": paths]
            return String(data: try! JSONSerialization.data(withJSONObject: [o], options: [.sortedKeys]), encoding: .utf8)!
        }
        func paths(_ d: Fixture.Device) -> [String] {
            let v = d.store.meta("note_sources") ?? "[]"
            let list = (try? JSONSerialization.jsonObject(with: Data(v.utf8))) as? [[String: Any]]
            return list?.first?["paths"] as? [String] ?? []
        }
        let f = try Fixture()
        let mac = try f.makeDevice("mac")
        try mac.store.setMeta("note_sources", sources(["/Users/a/vault"]))
        let ws = try f.upload(mac)
        let other = try f.cache(ws, as: "other")
        XCTAssertEqual(paths(other), ["/Users/a/vault"], "快照带着源列表")

        try mac.store.setMeta("note_sources", sources(["/Users/a/vault", "/Volumes/SSD/vault"]))
        try mac.sync(ws)
        try other.store.setMeta("note_sources", sources(["/Users/b/vault", "/Users/a/vault"]))   // 还没拉过 mac 那次
        let r = try other.sync(ws)
        XCTAssertTrue(r.push.conflicts.isEmpty, "按目录合并路径，不算冲突")
        try mac.sync(ws)

        let want = Set(["/Users/a/vault", "/Volumes/SSD/vault", "/Users/b/vault"])
        XCTAssertEqual(Set(paths(mac)), want)
        XCTAssertEqual(Set(paths(other)), want)
        XCTAssertEqual(try mac.specState(), try f.serverState(ws))
        XCTAssertEqual(try other.specState(), try f.serverState(ws))
        XCTAssertEqual(try mac.sync(ws).pushed, 0)
        XCTAssertEqual(try other.sync(ws).pushed, 0)
    }

    /// 拉取前本机又有没推上去的改动、而且比服务器那份新：本机赢，下一轮推上去（不能被拉取覆盖掉）。
    func testLocalPendingEditWinsWhenNewer() throws {
        let f = try Fixture()
        let mac = try f.makeDevice("mac")
        try Seed.addDoc(mac, "D1", title: "书")
        try Seed.addNote(mac, "X", doc: "D1", text: "原文", at: 0)
        let ws = try f.upload(mac)
        let pad = try f.cache(ws, as: "pad")

        try Seed.editNote(mac, "X", text: "mac", at: 5)
        try mac.sync(ws)
        // 平板只拉不推地模拟「拉取时本机有更新的改动」：直接调 applyPulled
        try Seed.editNote(pad, "X", text: "pad 更新", at: 20)
        let page = try ws.pullRows(since: pad.db { SyncClient.pulledRev($0) })
        let rep = try pad.db { try SyncClient.applyPulled($0, folder: pad.folder, rows: page.rows) }
        XCTAssertEqual(rep.conflicts, 1)
        XCTAssertEqual(try Seed.noteText(pad, "X"), "pad 更新", "本机更新，留着")
        try pad.db { try SyncClient.setPulledRev($0, page.head) }

        try pad.sync(ws)
        try mac.sync(ws)
        XCTAssertEqual(try Seed.noteText(mac, "X"), "pad 更新")
        XCTAssertEqual(try mac.specState(), try f.serverState(ws))
        XCTAssertEqual(try pad.specState(), try f.serverState(ws))
    }

    // MARK: - 删除整篇文档 vs 另一台在上面改

    func testDeleteDocumentCascadesAndArchives() throws {
        let f = try Fixture()
        let mac = try f.makeDevice("mac")
        try Seed.addDoc(mac, "D1", title: "要删的书")
        try Seed.addDoc(mac, "D2", title: "留着的书")
        try Seed.addNote(mac, "A", doc: "D1", text: "a", at: 0)
        try Seed.addNote(mac, "B", doc: "D1", text: "b", at: 0)
        try Seed.addNote(mac, "C", doc: "D2", text: "c", at: 0)
        let ws = try f.upload(mac)
        let pad = try f.cache(ws, as: "pad")

        // 平板先在 D1 上加了一条 S 并同步了；Mac 还没拉过，不知道 S
        try Seed.addNote(pad, "S", doc: "D1", text: "平板先写的", at: 3)
        try pad.sync(ws)
        let headBeforeDelete = ws.head

        // Mac 删整篇 D1（本机外键连带删掉 A、B；服务器上还会连带删掉 Mac 不知道的 S）
        try Seed.deleteRow(mac, "document", "D1")
        let r1 = try mac.sync(ws)
        XCTAssertEqual(r1.push.results.first { $0.rowId == "D1" }?.outcome, .applied)

        // 回收站：D1、它的两条笔记，还有服务器上连带删掉的 S，都先归档了
        let trash = ServerTrash.dayFile(in: f.paths.trashFolder(ws.id), now: .now)
        let t = try SQLiteDB(path: trash.path)
        XCTAssertEqual(try t.query("SELECT id FROM document").compactMap { $0["id"] as? String }, ["D1"])
        XCTAssertEqual(Set(try t.query("SELECT id FROM note").compactMap { $0["id"] as? String }), ["A", "B", "S"])
        XCTAssertEqual(try t.query("SELECT srv_device FROM note").first?["srv_device"] as? String, "mac")
        t.close()

        // 服务器上连带删掉的 S 也记了新修订号（否则别的设备不知道它没了）
        let pulled = try ws.pullRows(since: headBeforeDelete, limit: 100).rows
        XCTAssertTrue(pulled.contains { $0.rowId == "S" && $0.deleted })
        XCTAssertTrue(pulled.contains { $0.rowId == "A" && $0.deleted })

        // 平板在 D1 上又加了一条、改了 A：父文档在服务器上没了 → 孤儿，丢弃
        try Seed.addNote(pad, "P", doc: "D1", text: "pad 写在要删的书上", at: 30)
        try Seed.editNote(pad, "A", text: "pad 改 a", at: 30)
        let r2 = try pad.sync(ws)
        let outcome = Dictionary(uniqueKeysWithValues: r2.push.results.map { ($0.rowId, $0.outcome) })
        XCTAssertEqual(outcome["P"], .skippedOrphan)
        XCTAssertEqual(outcome["A"], .skippedOrphan, "一删一改本该保留改，但父文档已经没了，只能丢弃")
        XCTAssertNil(try Seed.noteText(pad, "P"), "拉到 D1 的删除后，本机外键连带删掉")
        XCTAssertNil(try Seed.noteText(pad, "S"))

        try mac.sync(ws)
        let server = try f.serverState(ws)
        XCTAssertEqual(try mac.specState(), server)
        XCTAssertEqual(try pad.specState(), server)
        XCTAssertEqual(Array((server["note"] ?? [:]).keys), ["C"])
        XCTAssertEqual(try pad.sync(ws).pushed, 0, "孤儿行不会每轮反复推")
    }

    // MARK: - 分页：子行先于父行到

    /// 父行后来又改过（修订号比子行大）→ 拉取时子行在前一页、父行在后一页。必须攒齐再应用，否则子行被当孤儿丢掉，
    /// 而它的基线又被记成「已同步」，下一轮就会推一条删除上去把服务器上的也删了。
    func testPagedPullAppliesChildrenWithLaterParent() throws {
        let f = try Fixture()
        let mac = try f.makeDevice("mac")
        try Seed.addDoc(mac, "D0", title: "旧书")
        let ws = try f.upload(mac)
        let pad = try f.cache(ws, as: "pad")

        try Seed.addDoc(mac, "D1", title: "新书")
        try Seed.addNote(mac, "N", doc: "D1", text: "新书上的笔记", at: 1)
        try mac.sync(ws)
        try Seed.renameDoc(mac, "D1", title: "新书（改名）")
        try mac.sync(ws)

        let since = pad.db { SyncClient.pulledRev($0) }
        let firstPage = try ws.pullRows(since: since, limit: 1).rows
        XCTAssertEqual(firstPage.first?.rowId, "N", "子行确实在父行之前")

        try pad.sync(ws, pageSize: 1)
        XCTAssertEqual(try Seed.noteText(pad, "N"), "新书上的笔记")
        try pad.sync(ws, pageSize: 1)
        XCTAssertNotNil(try ws.store.withMirrorDB { try SyncRows.fetch($0, table: "note", rowId: "N") }, "服务器上的没被误删")
        XCTAssertEqual(try pad.specState(), try f.serverState(ws))
    }

    // MARK: - 通道表

    func testChannelsOCRAndAlign() throws {
        let f = try Fixture()
        let mac = try f.makeDevice("mac")
        try Seed.addDoc(mac, "D1", title: "扫描书")
        let hash = try Seed.addPDF(mac, doc: "D1", bytes: "scan")
        let ws = try f.upload(mac)
        let pad = try f.cache(ws, as: "pad")

        // Mac 跑了 OCR、开了对齐（10 分）；平板也开了对齐但更早（5 分）
        try mac.db { db in
            try db.run("INSERT INTO ocr_page(content_hash,page,provider,payload,created_at) VALUES(?,3,'paddle',?,?)",
                       [.text(hash), .blob(Data("{\"w\":1}".utf8)), .text(Seed.t(1))])
            try db.run("INSERT INTO page_align(content_hash,enabled,page_count,payload,created_at,updated_at) VALUES(?,1,10,?,?,?)",
                       [.text(hash), .blob(Data("{\"v\":1}".utf8)), .text(Seed.t(10)), .text(Seed.t(10))])
        }
        try pad.db { db in
            try db.run("INSERT INTO page_align(content_hash,enabled,page_count,payload,created_at,updated_at) VALUES(?,0,10,?,?,?)",
                       [.text(hash), .blob(Data("{\"v\":0}".utf8)), .text(Seed.t(5)), .text(Seed.t(5))])
        }
        try mac.sync(ws)
        let r = try pad.sync(ws)
        XCTAssertEqual(r.push.results.first { $0.table == "page_align" }?.outcome, .keptServer)
        try pad.db { db in
            XCTAssertEqual(try db.query("SELECT enabled FROM page_align").first?["enabled"] as? Int64, 1, "取较新的那份")
            XCTAssertEqual(try db.query("SELECT page FROM ocr_page").first?["page"] as? Int64, 3, "OCR 补过来了")
        }
        XCTAssertEqual(try pad.sync(ws).pushed, 0)
        XCTAssertEqual(try mac.sync(ws).pushed, 0)
    }

    // MARK: - 文件

    func testPDFUploadedBeforeVariantGetsLinked() throws {
        let f = try Fixture()
        let mac = try f.makeDevice("mac")
        try Seed.addDoc(mac, "D1", title: "书")
        let ws = try f.upload(mac)

        let hash = try Seed.addPDF(mac, doc: "D1", bytes: "新加的 PDF")
        let tmp = f.root.appendingPathComponent("up.part")
        try Data("别的内容".utf8).write(to: tmp)
        XCTAssertThrowsError(try ws.storePDF(contentHash: hash, from: tmp)) { XCTAssertEqual($0 as? ServerError, .badContentHash) }
        try Data("新加的 PDF".utf8).write(to: tmp)
        try ws.storePDF(contentHash: hash, from: tmp)
        XCTAssertNotNil(ws.pdfFile(contentHash: hash), "文件先到")

        try mac.sync(ws)   // variant 行后到 → 补上 location
        try ws.store.withMirrorDB { db in
            XCTAssertEqual(try db.query("""
            SELECT l.path FROM location l JOIN variant v ON v.id=l.variant_id WHERE v.content_hash=?
            """, [.text(hash)]).first?["path"] as? String, "PDFs/\(hash).pdf")
        }
        XCTAssertNil(ws.pdfFile(contentHash: "../../etc/passwd"))
    }

    func testImageRowWaitsForFile() throws {
        let f = try Fixture()
        let mac = try f.makeDevice("mac")
        let ws = try f.upload(mac)
        let bytes = Data("png-bytes".utf8)
        let sha = ServerCrypto.sha256Hex(bytes)
        try FileManager.default.createDirectory(at: ImageAssets.folder(in: mac.folder), withIntermediateDirectories: true)
        try bytes.write(to: ImageAssets.url(in: mac.folder, sha256: sha, ext: "png"))
        try mac.db { try $0.run("INSERT INTO image(sha256,ext,width,height,bytes,created_at) VALUES(?,'png',1,1,9,?)",
                                [.text(sha), .text(Seed.t(0))]) }

        let r1 = try mac.sync(ws)
        XCTAssertEqual(r1.push.results.first?.outcome, .missingFile, "文件还没传，行先不收")
        let tmp = f.root.appendingPathComponent("img.part")
        try bytes.write(to: tmp)
        try ws.storeImage(sha256: sha, ext: "png", from: tmp)
        let r2 = try mac.sync(ws)
        XCTAssertEqual(r2.push.results.first?.outcome, .applied)
        XCTAssertNotNil(ws.imageFile(sha256: sha, ext: "png"))
        XCTAssertEqual(try mac.sync(ws).pushed, 0)
    }

    // MARK: - 版本 / 备份 / 路径

    func testSchemaMismatchRejected() throws {
        let f = try Fixture()
        let ws = try f.upload(try f.makeDevice("mac"))
        for v in [LibraryStore.schemaVersion - 1, LibraryStore.schemaVersion + 1] {
            XCTAssertThrowsError(try ws.push(SyncWire.PushRequest(schemaVersion: v, changes: []), deviceName: "x")) {
                XCTAssertEqual($0 as? ServerError, .schemaMismatch(client: v, server: LibraryStore.schemaVersion))
            }
        }
    }

    func testBackupKeepsRecentAndPrunes() throws {
        let f = try Fixture()
        let ws = try f.upload(try f.makeDevice("mac"))
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        for day in 0..<40 { try ws.backup(now: base.addingTimeInterval(Double(day) * 86_400)) }
        let names = try FileManager.default.contentsOfDirectory(atPath: f.paths.backupFolder(ws.id).path)
        XCTAssertLessThan(names.count, 20, "按日 / 按周稀释")
        XCTAssertGreaterThan(names.count, 5)
        let latest = f.paths.backupFolder(ws.id).appendingPathComponent(BackupFile.name(at: base.addingTimeInterval(39 * 86_400)))
        let db = try SQLiteDB(path: latest.path)
        XCTAssertNotNil(try db.query("SELECT value FROM meta WHERE key='workspace_name'").first)
        db.close()
    }

    func testResolveInsideRejectsEscapes() throws {
        let f = try Fixture()
        let folder = f.root.appendingPathComponent("w.unrd")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        XCTAssertNotNil(HostedWorkspace.resolveInside(folder, "PDFs/a.pdf"))
        XCTAssertNil(HostedWorkspace.resolveInside(folder, "../x.pdf"))
        XCTAssertNil(HostedWorkspace.resolveInside(folder, "PDFs/../../x.pdf"))
        XCTAssertThrowsError(try f.host.workspace("../../etc"))
    }
}
