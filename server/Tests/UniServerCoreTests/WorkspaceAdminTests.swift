import Foundation
import XCTest
@testable import UniServerCore

/// 整个工作区的管理：改名、删除（先归档）、找回、到期清理（App 启动页右键用，`SERVER-MODE-PLAN.md §13.9`）。
final class WorkspaceAdminTests: XCTestCase {

    /// 服务器上改名 → 记修订号 → 别的设备拉一轮就拿到新名字；本机也改过同一个名字时两边对得上、不算冲突。
    func testRenameIsPulledByDevices() throws {
        let f = try Fixture()
        let a = try f.makeDevice("A")
        let ws = try f.upload(a)
        let b = try f.cache(ws, as: "B")
        let before = ws.head

        let head = try ws.rename(to: "  改过的名字 ")
        XCTAssertEqual(head, before + 1, "改名记一个修订号")
        XCTAssertEqual(ws.name, "改过的名字", "名字去掉首尾空白")
        XCTAssertEqual(try ws.rename(to: "改过的名字"), head, "名字没变不记修订号")
        XCTAssertThrowsError(try ws.rename(to: "   "), "空名字拒绝")
        XCTAssertEqual(f.host.list().first?.name, "改过的名字", "列表里是新名字")

        try b.sync(ws)
        XCTAssertEqual(b.store.workspaceName, "改过的名字", "B 拉到新名字")

        // A 自己也改成同一个名字（启动页对本机已有副本的工作区走的是本机改名 + 推送），推上去不该冲突
        try a.store.setWorkspaceName("改过的名字")
        let report = try a.sync(ws)
        XCTAssertTrue(report.push.conflicts.isEmpty, "同一个名字两边一致，不算冲突")
        XCTAssertEqual(a.store.workspaceName, "改过的名字")
        XCTAssertEqual(try a.specState(), try f.serverState(ws))
    }

    /// 删除：整个文件夹连同备份挪进回收站，列表里没了，老的实例拒绝读写、也不会在原处留下空壳；
    /// 能找回（找回后数据原样、可以照常同步）；同一个 id 已经在服务器上时不许找回。
    func testDeleteArchivesThenRestore() throws {
        let f = try Fixture()
        let a = try f.makeDevice("A")
        try Seed.addDoc(a, "D1", title: "书")
        try Seed.addNote(a, "N1", doc: "D1", text: "笔记", at: 1)
        let pdf = Data("一份 PDF".utf8)
        let ws = try f.upload(a)
        try ws.backup(now: Date())
        let id = ws.id
        let rowsBefore = try f.serverState(ws)
        let fm = FileManager.default

        let d = try f.host.delete(id, device: "测试 Mac")
        XCTAssertTrue(f.host.list().isEmpty, "列表里没有它了")
        XCTAssertThrowsError(try f.host.workspace(id), "按 id 也打不开")
        XCTAssertFalse(fm.fileExists(atPath: f.paths.workspaceFolder(id).path), "原处的文件夹挪走了")
        XCTAssertTrue(fm.fileExists(atPath: d.folder.appendingPathComponent("workspace.unrd/UniReader/library.sqlite").path),
                      "整个工作区在回收站里")
        XCTAssertTrue(fm.fileExists(atPath: d.folder.appendingPathComponent("backups").path), "备份一起挪过去")
        XCTAssertFalse(fm.fileExists(atPath: f.paths.backupFolder(id).path))
        XCTAssertEqual(d.name, "测试工作区")
        XCTAssertEqual(f.host.deletedWorkspaces().map(\.id), [id])
        XCTAssertEqual(f.host.deletedWorkspaces().first?.device, "测试 Mac")

        // 删之前就拿到实例的请求：一律「没有这个工作区」，也不许往原处写文件
        XCTAssertThrowsError(try ws.pullRows(since: 0)) { XCTAssertEqual($0 as? ServerError, .unknownWorkspace(id)) }
        let tmp = f.root.appendingPathComponent("late.pdf")
        try pdf.write(to: tmp)
        XCTAssertThrowsError(try ws.storePDF(contentHash: ServerCrypto.sha256Hex(pdf), from: tmp))
        XCTAssertFalse(fm.fileExists(atPath: f.paths.workspaceFolder(id).path), "迟到的写入没有在原处建出空壳")
        XCTAssertThrowsError(try f.host.delete(id, device: "x"), "删过的再删一次：没有这个工作区")

        let back = try f.host.restoreDeleted(id)
        XCTAssertEqual(back.id, id)
        let again = try f.host.workspace(id)
        XCTAssertEqual(try f.serverState(again), rowsBefore, "找回来一行不少")
        XCTAssertTrue(fm.fileExists(atPath: f.paths.backupFolder(id).path), "备份也放回来了")
        XCTAssertTrue(f.host.deletedWorkspaces().isEmpty, "回收站里那份没了")
        XCTAssertEqual(f.host.list().map(\.id), [id])
        try Seed.addNote(a, "N2", doc: "D1", text: "找回之后写的", at: 2)
        try a.sync(again)
        XCTAssertEqual(try a.specState(), try f.serverState(again), "找回后照常同步")

        // 同一个 id 已经在服务器上时不许找回（删了之后又上传过一次的情形）
        try f.host.delete(id, device: "x")
        let fresh = f.paths.workspaceFolder(id)
        try fm.copyItem(at: f.host.deletedWorkspaces()[0].folder.appendingPathComponent("workspace.unrd"), to: fresh)
        XCTAssertThrowsError(try f.host.restoreDeleted(id)) { XCTAssertEqual($0 as? ServerError, .alreadyHosted(id)) }
    }

    /// 回收站里的被删工作区留 90 天，过了就清掉；没到的不动。
    func testPruneDeletedAfterKeepDays() throws {
        let f = try Fixture()
        let old = try f.upload(try f.makeDevice("Old"))
        let recent = try f.upload(try f.makeDevice("Recent"))
        let now = Date()
        try f.host.delete(old.id, device: "x", now: now.addingTimeInterval(-91 * 86_400))
        try f.host.delete(recent.id, device: "x", now: now.addingTimeInterval(-89 * 86_400))
        XCTAssertEqual(f.host.pruneDeleted(now: now), 1)
        XCTAssertEqual(f.host.deletedWorkspaces().map(\.id), [recent.id])
    }
}
