import XCTest
@testable import UniServerCore

/// 变更通知（长轮询）：任何改动都叫醒在等的设备，且不丢通知。
final class WatchTests: XCTestCase {

    private func hosted(_ fx: Fixture) throws -> HostedWorkspace { try fx.upload(try fx.makeDevice("a")) }

    private func tmp(_ fx: Fixture, _ s: String) throws -> URL {
        let u = fx.root.appendingPathComponent("w-\(UUID().uuidString)")
        try Data(s.utf8).write(to: u)
        return u
    }

    func testReturnsImmediatelyWhenAlreadyDifferent() async throws {
        let fx = try Fixture(); let w = try hosted(fx)
        let s = w.changeState
        let t0 = Date()
        let r = await w.waitForChange(rows: s.rows &+ 1, notes: s.notes, timeout: 5)
        XCTAssertEqual(r, s)
        XCTAssertLessThan(Date().timeIntervalSince(t0), 1)
    }

    func testTimesOutWhenNothingChanges() async throws {
        let fx = try Fixture(); let w = try hosted(fx)
        let s = w.changeState
        let t0 = Date()
        let r = await w.waitForChange(rows: s.rows, notes: s.notes, timeout: 0.3)
        XCTAssertEqual(r, s)
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(t0), 0.25)
    }

    func testNoteWriteWakesWaiter() async throws {
        let fx = try Fixture(); let w = try hosted(fx)
        let s = w.changeState
        let file = try tmp(fx, "hello")
        async let waited = w.waitForChange(rows: s.rows, notes: s.notes, timeout: 10)
        try await Task.sleep(nanoseconds: 200_000_000)       // 让等待先挂上
        let t0 = Date()
        _ = try w.putNote(path: "Notes/a.md", base: 0, from: file)
        let r = await waited
        XCTAssertGreaterThan(r.notes, s.notes)
        XCTAssertEqual(r.rows, s.rows)
        XCTAssertLessThan(Date().timeIntervalSince(t0), 2, "应该立刻醒，不是等到超时")
    }

    func testPushAndRenameWakeWaiter() async throws {
        let fx = try Fixture()
        let dev = try fx.makeDevice("a")
        let w = try fx.upload(dev)
        let s = w.changeState
        async let waited = w.waitForChange(rows: s.rows, notes: s.notes, timeout: 10)
        try await Task.sleep(nanoseconds: 200_000_000)
        _ = try w.rename(to: "改名了")
        let r = await waited
        XCTAssertGreaterThan(r.rows, s.rows)
        XCTAssertEqual(r, w.changeState)
        XCTAssertEqual(w.head, r.rows)
    }

    /// 通知不能丢：改动发生在「读到状态」和「挂上等待」之间也要立刻醒。
    func testNoLostWakeup() async throws {
        let fx = try Fixture(); let w = try hosted(fx)
        var revs: UInt64 = 0
        for i in 0..<20 {
            let s = w.changeState
            let file = try tmp(fx, "v\(i)")
            let path = "Notes/n\(i).md"
            let task = Task { await w.waitForChange(rows: s.rows, notes: s.notes, timeout: 5) }
            _ = try w.putNote(path: path, base: 0, from: file)       // 与上面那一行几乎同时
            let r = await task.value
            revs = r.notes
            XCTAssertGreaterThan(r.notes, s.notes, "第 \(i) 轮没被叫醒")
        }
        XCTAssertEqual(revs, 20)
    }

    func testCancellationEndsWaitEarly() async throws {
        let fx = try Fixture(); let w = try hosted(fx)
        let s = w.changeState
        let t0 = Date()
        let task = Task { await w.waitForChange(rows: s.rows, notes: s.notes, timeout: 30) }
        try await Task.sleep(nanoseconds: 200_000_000)
        task.cancel()
        _ = await task.value
        XCTAssertLessThan(Date().timeIntervalSince(t0), 3)
    }
}
