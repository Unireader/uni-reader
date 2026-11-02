import XCTest
@testable import UniServerCore

/// PDF 被原地改了内容（如加目录）、在 Mac 上「关联为新版本」之后：旧版本那一行要删掉，删除经服务器带给别的设备，
/// 网页阅读器与别的设备于是拿新文件（2026-11-02 用户报「加了目录没上传 / 没更新」）。
/// 被测的是 `Sources/Store/LibraryStore.swift` 里 `copyContentCaches` / `deleteVariantIfUnused` /
/// `dropSupersededVariants`（App 与服务器共用的 Store 层）；`WorkspaceManager.rekeyLocation` 的步骤在 `relink` 里照做一遍。
final class VariantSupersedeTests: XCTestCase {

    // MARK: - 造数据

    private func variants(_ d: Fixture.Device, doc: String) throws -> [String] {
        try d.db { db in
            try db.query("SELECT content_hash FROM variant WHERE document_id=? ORDER BY added_at", [.text(doc)])
                .compactMap { $0["content_hash"] as? String }
        }
    }

    private func variantId(_ d: Fixture.Device, hash: String) throws -> String? {
        try d.store.variant(hash: hash)?.id
    }

    private func count(_ d: Fixture.Device, _ sql: String, _ p: [SQLiteDB.Value] = []) throws -> Int {
        try d.db { db in Int(try db.query(sql, p).first?["n"] as? Int64 ?? -1) }
    }

    /// 这份文件在本机的路径（工作区相对）。
    private func path(_ d: Fixture.Device, hash: String) throws -> String? {
        try d.db { db in
            try db.query("""
            SELECT l.path FROM location l JOIN variant v ON v.id=l.variant_id WHERE v.content_hash=? LIMIT 1
            """, [.text(hash)]).first?["path"] as? String
        }
    }

    /// 按内容哈希记的三样，各造一行。
    private func seedCaches(_ d: Fixture.Device, hash: String) throws {
        try d.db { db in
            try db.run("INSERT INTO ocr_page(content_hash,page,provider,payload,created_at) VALUES(?,0,'paddle',?,?)",
                       [.text(hash), .blob(Data("{\"p\":0}".utf8)), .text(Seed.t(1))])
            try db.run("INSERT INTO ocr_page(content_hash,page,provider,payload,created_at) VALUES(?,1,'paddle',?,?)",
                       [.text(hash), .blob(Data("{\"p\":1}".utf8)), .text(Seed.t(1))])
            try db.run("""
            INSERT INTO page_align(content_hash,enabled,page_count,payload,created_at,updated_at) VALUES(?,1,10,?,?,?)
            """, [.text(hash), .blob(Data("{\"v\":1}".utf8)), .text(Seed.t(2)), .text(Seed.t(2))])
            try db.run("INSERT INTO page_geom(content_hash,page_count,heights,created_at) VALUES(?,10,?,?)",
                       [.text(hash), .blob(Data("[1]".utf8)), .text(Seed.t(2))])
        }
    }

    /// 把 [rel] 那份文件原地换成 [bytes]，返回新哈希。
    private func overwrite(_ d: Fixture.Device, rel: String, bytes: String) throws -> String {
        let data = Data(bytes.utf8)
        try data.write(to: d.folder.appendingPathComponent(rel))
        return ServerCrypto.sha256Hex(data)
    }

    /// 2026-11-02 之后的「关联为新版本」（`WorkspaceManager.rekeyLocation` 的步骤）。[dropOld] = false 就是之前的老做法：只挪路径。
    private func relink(_ d: Fixture.Device, doc: String, oldHash: String, newHash: String, pages: Int = 10,
                        dropOld: Bool = true) throws {
        let s = d.store
        let old = try XCTUnwrap(s.variant(hash: oldHash))
        let locs = try s.locations(variantId: old.id)
        let first = try XCTUnwrap(locs.first)
        for l in locs { try s.removeLocation(id: l.id) }
        let nv = try s.addVariant(documentId: doc, hash: newHash, pageCount: pages, path: first.path,
                                  inWorkspace: first.inWorkspace, isRelative: first.isRelative)
        XCTAssertEqual(nv.documentId, doc)
        guard dropOld else { return }
        if old.pageCount == pages { try s.copyContentCaches(from: oldHash, to: newHash) }
        XCTAssertTrue(try s.deleteVariantIfUnused(id: old.id))
        try s.setPageCount(documentId: doc, pageCount: pages)
    }

    /// App 推送前先传新文件（`ServerSyncIO.uploadFiles`）；测试里直接交给服务器。
    private func uploadPDF(_ ws: HostedWorkspace, _ d: Fixture.Device, hash: String) throws {
        let rel = try XCTUnwrap(path(d, hash: hash))
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("up-\(UUID().uuidString)")
        try FileManager.default.copyItem(at: d.folder.appendingPathComponent(rel), to: tmp)
        try ws.storePDF(contentHash: hash, from: tmp)
    }

    /// 别的设备从服务器下了这份 PDF（`fetchPDF` 的口径：没有工作区内路径就下到 `PDFs/<哈希>.pdf` 并补一条 location）。
    private func download(_ d: Fixture.Device, ws: HostedWorkspace, hash: String) throws {
        let src = try XCTUnwrap(ws.pdfFile(contentHash: hash))
        let vid = try XCTUnwrap(variantId(d, hash: hash))
        let existing = try d.store.locations(variantId: vid).first { $0.inWorkspace }
        let rel = existing?.path ?? "PDFs/\(hash).pdf"
        let dst = d.folder.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: dst)
        try FileManager.default.copyItem(at: src, to: dst)
        if existing == nil { try d.store.addLocation(variantId: vid, path: rel, inWorkspace: true) }
    }

    // MARK: - Store 层

    func testCopyCachesAndDeleteGuards() throws {
        let f = try Fixture()
        let mac = try f.makeDevice("mac")
        try Seed.addDoc(mac, "D1", title: "书")
        let h1 = try Seed.addPDF(mac, doc: "D1", bytes: "v1")
        try seedCaches(mac, hash: h1)
        let v1 = try XCTUnwrap(variantId(mac, hash: h1))

        XCTAssertFalse(try mac.store.deleteVariantIfUnused(id: v1), "还有路径指向它：不删")
        try mac.db { try $0.run("DELETE FROM location") }
        XCTAssertFalse(try mac.store.deleteVariantIfUnused(id: v1), "文档唯一的版本：不删（至少留一个）")

        try mac.store.copyContentCaches(from: h1, to: "H2")
        XCTAssertEqual(try count(mac, "SELECT COUNT(*) AS n FROM ocr_page WHERE content_hash='H2'"), 2)
        XCTAssertEqual(try count(mac, "SELECT COUNT(*) AS n FROM page_align WHERE content_hash='H2' AND enabled=1"), 1)
        XCTAssertEqual(try count(mac, "SELECT COUNT(*) AS n FROM page_geom WHERE content_hash='H2'"), 1)
        XCTAssertEqual(try count(mac, "SELECT COUNT(*) AS n FROM ocr_page WHERE content_hash=?", [.text(h1)]), 2, "是抄一份，旧的留着")
        // 新哈希下已有的不覆盖
        try mac.db { try $0.run("UPDATE page_align SET enabled=0 WHERE content_hash='H2'") }
        try mac.store.copyContentCaches(from: h1, to: "H2")
        XCTAssertEqual(try count(mac, "SELECT COUNT(*) AS n FROM page_align WHERE content_hash='H2' AND enabled=0"), 1)
        XCTAssertEqual(try count(mac, "SELECT COUNT(*) AS n FROM ocr_page WHERE content_hash='H2'"), 2)

        XCTAssertTrue(try mac.store.locationExists(path: "PDFs/x.pdf") == false)
        try mac.store.addLocation(variantId: v1, path: "PDFs/x.pdf", inWorkspace: true)
        XCTAssertTrue(try mac.store.locationExists(path: "PDFs/x.pdf"))

        try mac.store.setPageCount(documentId: "D1", pageCount: 12)
        XCTAssertEqual(try mac.store.document(id: "D1")?.pageCount, 12)
    }

    /// 补救老数据的认法：旧版本本机没路径 + 同一篇有更晚、本机有路径的版本 + 页数相同（或新版本文件就叫 `PDFs/<旧哈希>.pdf`）。
    func testDropSupersededMatchesOnlyOldRelinks() throws {
        let f = try Fixture()
        let d = try f.makeDevice("pad")
        for i in 1...6 { try Seed.addDoc(d, "D\(i)", title: "书\(i)") }
        try d.db { db in
            func v(_ id: String, _ doc: String, _ hash: String, _ pages: Int, _ at: Int) throws {
                try db.run("INSERT INTO variant(id,document_id,content_hash,page_count,added_at) VALUES(?,?,?,?,?)",
                           [.text(id), .text(doc), .text(hash), .int(Int64(pages)), .text(Seed.t(at))])
            }
            func l(_ vid: String, _ path: String, _ inWs: Int = 1) throws {
                try db.run("INSERT INTO location(id,variant_id,path,in_workspace) VALUES(?,?,?,?)",
                           [.text(UUID().uuidString), .text(vid), .text(path), .int(Int64(inWs))])
            }
            // 老做法关联过：旧的没路径、新的更晚且页数一样
            try v("A1", "D1", "aaa", 10, 1); try v("A2", "D1", "bbb", 10, 2); try l("A2", "PDFs/x.pdf")
            // 没路径的那版**更晚**（别的设备加的新版、本机还没下载）：不是被取代
            try v("B1", "D2", "ccc", 10, 2); try v("B2", "D2", "ddd", 10, 1); try l("B2", "PDFs/ddd.pdf")
            // 页数变了，但新版本的文件就是按旧哈希下下来的那份：认
            try v("C1", "D3", "eee", 10, 1); try v("C2", "D3", "fff", 12, 2); try l("C2", "PDFs/eee.pdf")
            // 页数变了、文件名也对不上：不认
            try v("E1", "D4", "ggg", 10, 1); try v("E2", "D4", "hhh", 12, 2); try l("E2", "PDFs/zzz.pdf")
            // 旧的还有路径：不认
            try v("F1", "D5", "iii", 10, 1); try l("F1", "PDFs/iii.pdf"); try v("F2", "D5", "jjj", 10, 2); try l("F2", "PDFs/jjj.pdf")
            // 新的也没路径（两版都没下载）：不认
            try v("G1", "D6", "kkk", 10, 1); try v("G2", "D6", "lll", 10, 2)
        }
        try seedCaches(d, hash: "aaa")
        try seedCaches(d, hash: "eee")
        XCTAssertEqual(try d.store.dropSupersededVariants(), 2)
        XCTAssertEqual(try variants(d, doc: "D1"), ["bbb"])
        XCTAssertEqual(try variants(d, doc: "D2"), ["ddd", "ccc"])
        XCTAssertEqual(try variants(d, doc: "D3"), ["fff"])
        XCTAssertEqual(try variants(d, doc: "D4"), ["ggg", "hhh"])
        XCTAssertEqual(try variants(d, doc: "D5"), ["iii", "jjj"])
        XCTAssertEqual(try variants(d, doc: "D6"), ["kkk", "lll"])
        XCTAssertEqual(try count(d, "SELECT COUNT(*) AS n FROM ocr_page WHERE content_hash='bbb'"), 2, "页数一样，缓存跟过去")
        XCTAssertEqual(try count(d, "SELECT COUNT(*) AS n FROM ocr_page WHERE content_hash='fff'"), 0, "页数变了，不抄")
        XCTAssertEqual(try d.store.dropSupersededVariants(), 0, "再跑一次什么都不做")
    }

    // MARK: - 经服务器

    /// 新做法：Mac 关联为新版本 → 推送 → 服务器与网页只剩新版本 → 平板拉下来，旧版本连同本机路径一起没了，去下新文件。
    func testRelinkReachesOtherDevices() throws {
        let f = try Fixture()
        let mac = try f.makeDevice("mac")
        try Seed.addDoc(mac, "D1", title: "书")
        let h1 = try Seed.addPDF(mac, doc: "D1", bytes: "没有目录")
        try seedCaches(mac, hash: h1)
        let ws = try f.upload(mac)
        let pad = try f.cache(ws, as: "pad")
        try download(pad, ws: ws, hash: h1)
        XCTAssertEqual(try ws.documents().first?.contentHash, h1)

        let rel = try XCTUnwrap(path(mac, hash: h1))
        let h2 = try overwrite(mac, rel: rel, bytes: "加了目录")
        try relink(mac, doc: "D1", oldHash: h1, newHash: h2)
        try uploadPDF(ws, mac, hash: h2)
        let r = try mac.sync(ws)
        XCTAssertTrue(r.push.conflicts.isEmpty)
        XCTAssertEqual(try ws.documents().first?.contentHash, h2, "网页阅读器拿到的是新文件")
        XCTAssertNotNil(ws.pdfFile(contentHash: h2))

        try pad.sync(ws)
        XCTAssertEqual(try variants(pad, doc: "D1"), [h2])
        XCTAssertEqual(try count(pad, "SELECT COUNT(*) AS n FROM location"), 0, "旧版本的本机路径随它一起没了 → 这本算没下载")
        XCTAssertEqual(try count(pad, "SELECT COUNT(*) AS n FROM ocr_page WHERE content_hash=?", [.text(h2)]), 2,
                       "OCR 跟着新版本过来了")
        XCTAssertEqual(try count(pad, "SELECT COUNT(*) AS n FROM page_align WHERE content_hash=?", [.text(h2)]), 1)
        try download(pad, ws: ws, hash: h2)
        XCTAssertEqual(try path(pad, hash: h2), "PDFs/\(h2).pdf")

        XCTAssertEqual(try mac.specState(), try f.serverState(ws))
        XCTAssertEqual(try pad.specState(), try f.serverState(ws))
        XCTAssertEqual(try mac.sync(ws).pushed, 0)
        XCTAssertEqual(try pad.sync(ws).pushed, 0)
    }

    /// 用户实际碰上的：平板（或另一台 Mac）从服务器下了书、在那台上加了目录、按老做法关联为新版本（只挪路径）。
    /// 新版本已经传上去了，但旧版本还在 → 网页与别的设备拿旧的。新版 App 打开工作区时补救，推上去之后都换成新的。
    func testRepairOldRelinkAcrossDevices() throws {
        let f = try Fixture()
        let mac = try f.makeDevice("mac")
        try Seed.addDoc(mac, "D1", title: "书")
        let h1 = try Seed.addPDF(mac, doc: "D1", bytes: "没有目录")
        let ws = try f.upload(mac)
        let other = try f.cache(ws, as: "other")
        try download(other, ws: ws, hash: h1)

        let rel = try XCTUnwrap(path(other, hash: h1))
        let h2 = try overwrite(other, rel: rel, bytes: "加了目录")
        try relink(other, doc: "D1", oldHash: h1, newHash: h2, dropOld: false)
        try uploadPDF(ws, other, hash: h2)
        try other.sync(ws)
        try mac.sync(ws)
        XCTAssertEqual(try ws.documents().first?.contentHash, h1, "老做法：网页还是旧文件（这就是要修的）")
        XCTAssertEqual(try variants(mac, doc: "D1"), [h1, h2])

        XCTAssertEqual(try other.store.dropSupersededVariants(), 1)
        try other.sync(ws)
        XCTAssertEqual(try ws.documents().first?.contentHash, h2)
        try mac.sync(ws)
        XCTAssertEqual(try variants(mac, doc: "D1"), [h2])
        XCTAssertEqual(try count(mac, "SELECT COUNT(*) AS n FROM location"), 0, "Mac 上旧文件的路径没了 → 这本去下新版本")
        XCTAssertEqual(try mac.specState(), try f.serverState(ws))
        XCTAssertEqual(try other.specState(), try f.serverState(ws))
    }
}
