import XCTest
@testable import UniServerCore

/// 笔记文件同步（`Notes/` 与 `NotesMirror/`，方案 SERVER-MODE-PLAN §4.4 / §13.12）的服务器一侧。
final class NoteFilesTests: XCTestCase {

    private func tmpFile(_ fx: Fixture, _ text: String) throws -> URL {
        let url = fx.root.appendingPathComponent("up-\(UUID().uuidString)")
        try Data(text.utf8).write(to: url)
        return url
    }

    private func list(_ w: HostedWorkspace) throws -> [SyncNotes.Entry] {
        try JSONDecoder().decode(SyncNotes.ListResponse.self, from: try w.noteList()).files
    }

    private func hosted(_ fx: Fixture) throws -> HostedWorkspace { try fx.upload(try fx.makeDevice("a")) }

    func testPathRules() {
        XCTAssertTrue(SyncNotes.isSyncablePath("Notes/操作系统.md"))
        XCTAssertTrue(SyncNotes.isSyncablePath("Notes/数学/极限 (冲突 书房 2026-11-03 12-50).md"))
        XCTAssertTrue(SyncNotes.isSyncablePath("NotesMirror/abc/a/b.md"))
        XCTAssertFalse(SyncNotes.isSyncablePath("NotesMirror/abc"))              // 镜像要有源目录
        XCTAssertFalse(SyncNotes.isSyncablePath("Notes"))
        XCTAssertFalse(SyncNotes.isSyncablePath("PDFs/a.pdf"))
        XCTAssertFalse(SyncNotes.isSyncablePath("Notes/../library.sqlite"))
        XCTAssertFalse(SyncNotes.isSyncablePath("Notes/.obsidian/app.json"))
        XCTAssertFalse(SyncNotes.isSyncablePath("Notes/.trash/a.md"))
        XCTAssertFalse(SyncNotes.isSyncablePath("Notes/Trash/a.md"))
        XCTAssertFalse(SyncNotes.isSyncablePath("Notes/a.md.part"))
        XCTAssertFalse(SyncNotes.isSyncablePath("Notes//a.md"))
    }

    func testConflictName() {
        let d = Date(timeIntervalSince1970: 1_793_680_000)
        let a = SyncNotes.conflictPath(for: "Notes/数学/极限.md", device: "书房/Mac", date: d, taken: { _ in false })
        XCTAssertTrue(a.hasPrefix("Notes/数学/极限 (冲突 书房-Mac "), a)
        XCTAssertTrue(a.hasSuffix(").md"), a)
        let b = SyncNotes.conflictPath(for: "Notes/数学/极限.md", device: "书房/Mac", date: d, taken: { $0 == a })
        XCTAssertNotEqual(a, b)
        XCTAssertTrue(b.hasSuffix(" 2).md"), b)
        XCTAssertTrue(SyncNotes.conflictPath(for: "Notes/README", device: "x", date: d, taken: { _ in false }).hasSuffix(")"))
    }

    func testPutNewThenSameThenStaleThenApply() throws {
        let fx = try Fixture(); let w = try hosted(fx)
        let p = "Notes/操作系统.md"
        // 新文件
        var r = try w.putNote(path: p, base: 0, from: try tmpFile(fx, "v1"))
        XCTAssertEqual(r.result, .applied)
        let rev1 = r.rev
        XCTAssertEqual(try String(contentsOf: try XCTUnwrap(w.noteFile(path: p)).url, encoding: .utf8), "v1")
        // 同样内容再传：不动
        r = try w.putNote(path: p, base: 0, from: try tmpFile(fx, "v1"))
        XCTAssertEqual(r.result, .unchanged); XCTAssertEqual(r.rev, rev1)
        // 基线对不上：不收，服务器那份不变
        r = try w.putNote(path: p, base: rev1 + 99, from: try tmpFile(fx, "other"))
        XCTAssertEqual(r.result, .stale); XCTAssertEqual(r.rev, rev1)
        XCTAssertEqual(try String(contentsOf: try XCTUnwrap(w.noteFile(path: p)).url, encoding: .utf8), "v1")
        // 基线对：收下，修订号往前走；旧版本进了回收站
        r = try w.putNote(path: p, base: rev1, from: try tmpFile(fx, "v2"))
        XCTAssertEqual(r.result, .applied); XCTAssertGreaterThan(r.rev, rev1)
        XCTAssertEqual(try XCTUnwrap(w.noteFile(path: p)).rev, r.rev)
        let trash = fx.paths.trashFolder(w.id).appendingPathComponent("notes")
        let archived = FileManager.default.enumerator(atPath: trash.path)?.allObjects as? [String] ?? []
        XCTAssertTrue(archived.contains { $0.hasSuffix("Notes/操作系统.md") }, "\(archived)")
    }

    func testDeleteArchivesAndTombstones() throws {
        let fx = try Fixture(); let w = try hosted(fx)
        let p = "Notes/a/b.md"
        let rev = try w.putNote(path: p, base: 0, from: try tmpFile(fx, "hello")).rev
        XCTAssertEqual(try w.deleteNote(path: p, base: rev + 5).result, .stale)       // 基线不对不删
        XCTAssertNotNil(try w.noteFile(path: p))
        let d = try w.deleteNote(path: p, base: rev)
        XCTAssertEqual(d.result, .applied); XCTAssertGreaterThan(d.rev, rev)
        XCTAssertNil(try w.noteFile(path: p))
        let e = try XCTUnwrap(list(w).first { $0.path == p })
        XCTAssertTrue(e.deleted); XCTAssertEqual(e.rev, d.rev)                        // 墓碑留着，别的设备凭它知道该删
        XCTAssertEqual(try w.deleteNote(path: p, base: d.rev).result, .unchanged)     // 重复删：无事发生
        // 被删的文件在回收站里
        let trash = fx.paths.trashFolder(w.id).appendingPathComponent("notes")
        let archived = FileManager.default.enumerator(atPath: trash.path)?.allObjects as? [String] ?? []
        XCTAssertTrue(archived.contains { $0.hasSuffix("Notes/a/b.md") }, "\(archived)")
        // 删掉之后同一路径可以重新建（base 随便）
        let again = try w.putNote(path: p, base: 0, from: try tmpFile(fx, "back"))
        XCTAssertEqual(again.result, .applied); XCTAssertGreaterThan(again.rev, d.rev)
    }

    /// 同一路径连续覆盖、再删除：归档在同一秒里撞名也不能出错（曾经 500）。
    func testRepeatedArchiveNeverCollides() throws {
        let fx = try Fixture(); let w = try hosted(fx)
        let p = "Notes/操作系统.md"
        var rev = try w.putNote(path: p, base: 0, from: try tmpFile(fx, "v1")).rev
        for i in 2...5 { rev = try w.putNote(path: p, base: rev, from: try tmpFile(fx, "v\(i)")).rev }
        XCTAssertEqual(try w.deleteNote(path: p, base: rev).result, .applied)
        let trash = fx.paths.trashFolder(w.id).appendingPathComponent("notes")
        let archived = (FileManager.default.enumerator(atPath: trash.path)?.allObjects as? [String] ?? [])
            .filter { $0.hasSuffix(".md") }
        XCTAssertEqual(archived.count, 5, "\(archived)")       // 被覆盖的 v1~v4 + 被删的 v5，一份不少
        let bodies = Set(try archived.map { try String(contentsOf: trash.appendingPathComponent($0), encoding: .utf8) })
        XCTAssertEqual(bodies, ["v1", "v2", "v3", "v4", "v5"])
    }

    func testRevisionsAreUniquePerFile() throws {
        let fx = try Fixture(); let w = try hosted(fx)
        var revs: [UInt64] = []
        for i in 0..<5 { revs.append(try w.putNote(path: "Notes/n\(i).md", base: 0, from: try tmpFile(fx, "x\(i)")).rev) }
        XCTAssertEqual(Set(revs).count, 5)
        XCTAssertEqual(try list(w).count, 5)
    }

    func testRejectsBadPaths() throws {
        let fx = try Fixture(); let w = try hosted(fx)
        for bad in ["Notes/../x.md", "library.sqlite", "Notes/.hidden.md", "PDFs/a.md"] {
            XCTAssertThrowsError(try w.putNote(path: bad, base: 0, from: try tmpFile(fx, "x")), bad)
            XCTAssertThrowsError(try w.noteFile(path: bad), bad)
        }
    }

    /// 首次上传时带上来的 `Notes/` 文件、直接放进服务器文件夹的文件，列表里都有；磁盘上没了的记墓碑。
    func testReconcilePicksUpFilesPlacedOnDisk() throws {
        let fx = try Fixture()
        let dev = try fx.makeDevice("a")
        let notes = dev.folder.appendingPathComponent("Notes/数学")
        try FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true)
        try Data("极限".utf8).write(to: notes.appendingPathComponent("极限.md"))
        try Data("x".utf8).write(to: dev.folder.appendingPathComponent("Notes/.DS_Store"))
        let up = try fx.host.newUploadFolder()
        dev.store.checkpointTruncate()
        try dev.store.vacuumInto(up.appendingPathComponent("UniReader/library.sqlite").path)
        try FileManager.default.copyItem(at: dev.folder.appendingPathComponent("Notes"), to: up.appendingPathComponent("Notes"))
        let w = try fx.host.install(uploaded: up)

        let first = try list(w)
        XCTAssertEqual(first.map(\.path), ["Notes/数学/极限.md"])                      // 隐藏文件不进
        XCTAssertFalse(first[0].deleted)
        XCTAssertEqual(first[0].size, Int64("极限".utf8.count))

        // 有人直接在服务器上改了文件 → 下次列表修订号涨；删了 → 墓碑
        let url = try XCTUnwrap(w.noteFile(path: "Notes/数学/极限.md")).url
        try Data("极限（改）".utf8).write(to: url)
        let second = try list(w)
        XCTAssertGreaterThan(second[0].rev, first[0].rev)
        try FileManager.default.removeItem(at: url)
        let third = try list(w)
        XCTAssertTrue(third[0].deleted)
    }

    /// `Notes/` 整个不在了不当成「全删了」。
    func testMissingNotesFolderIsNotMassDelete() throws {
        let fx = try Fixture(); let w = try hosted(fx)
        _ = try w.putNote(path: "Notes/a.md", base: 0, from: try tmpFile(fx, "a"))
        let folder = try XCTUnwrap(w.noteFile(path: "Notes/a.md")).url.deletingLastPathComponent()
        try FileManager.default.removeItem(at: folder)
        XCTAssertFalse(try list(w).first { $0.path == "Notes/a.md" }!.deleted)
    }

    func testMirrorNamespaceIsSeparate() throws {
        let fx = try Fixture(); let w = try hosted(fx)
        _ = try w.putNote(path: "Notes/a.md", base: 0, from: try tmpFile(fx, "built-in"))
        _ = try w.putNote(path: "NotesMirror/src1/a.md", base: 0, from: try tmpFile(fx, "mirror"))
        let l = try list(w)
        XCTAssertEqual(Set(l.map(\.path)), ["Notes/a.md", "NotesMirror/src1/a.md"])
        XCTAssertEqual(try String(contentsOf: try XCTUnwrap(w.noteFile(path: "NotesMirror/src1/a.md")).url, encoding: .utf8), "mirror")
        XCTAssertEqual(try String(contentsOf: try XCTUnwrap(w.noteFile(path: "Notes/a.md")).url, encoding: .utf8), "built-in")
    }

    /// 快照里不带服务器私有的笔记记录。
    func testSnapshotDropsPrivateNoteTable() throws {
        let fx = try Fixture(); let w = try hosted(fx)
        _ = try w.putNote(path: "Notes/a.md", base: 0, from: try tmpFile(fx, "a"))
        let dst = fx.root.appendingPathComponent("snap.sqlite")
        _ = try w.exportSnapshot(to: dst)
        let db = try SQLiteDB(path: dst.path); defer { db.close() }
        XCTAssertTrue(try db.query("SELECT name FROM sqlite_master WHERE name='srv_note'").isEmpty)
        XCTAssertTrue(try db.query("SELECT key FROM meta WHERE key='srv_note_head'").isEmpty)
    }
}
