import XCTest
@testable import UniServerCore

final class SyncWireTests: XCTestCase {

    private let row: [String: MirrorFp.Value] = [
        "id": .text("N1"), "kind": .int(-7), "anchor_x": .real(0.125), "payload": .blob(Data([0, 1, 255])),
        "empty_blob": .blob(Data()), "quote": .text("中文 ✍️"), "nothing": .null,
    ]

    func testPushRequestRoundTrip() throws {
        let req = SyncWire.PushRequest(schemaVersion: 22, changes: [
            .init(table: "note", rowId: "N1", op: .upsert, baseFp: "0123456789abcdef", row: row),
            .init(table: "note", rowId: "N2", op: .delete, baseFp: "fedcba9876543210", row: nil),
            .init(table: "document", rowId: "D1", op: .upsert, baseFp: nil, row: ["id": .text("D1")]),
        ])
        XCTAssertEqual(try SyncWire.decodePushRequest(SyncWire.encode(req)), req)
    }

    func testPushResponseRoundTrip() throws {
        let resp = SyncWire.PushResponse(
            head: 1 << 40,
            results: [.init(table: "note", rowId: "N1", outcome: .applied, rev: 9),
                      .init(table: "image", rowId: "abc", outcome: .missingFile, rev: 0)],
            conflicts: [.init(table: "note", rowId: "N1", kind: .deleteVsEdit, keptServer: true)],
            serverRows: [.init(table: "note", rowId: "N3", rev: 7, deleted: false, row: row),
                         .init(table: "note", rowId: "N4", rev: 8, deleted: true, row: nil)])
        XCTAssertEqual(try SyncWire.decodePushResponse(SyncWire.encode(resp)), resp)
    }

    func testPullResponseRoundTrip() throws {
        let resp = SyncWire.PullResponse(head: 12, more: true, rows: [
            .init(table: "note", rowId: "N1", rev: 11, deleted: false, row: row),
            .init(table: "note", rowId: "N2", rev: 12, deleted: true, row: nil),
        ])
        XCTAssertEqual(try SyncWire.decodePullResponse(SyncWire.encode(resp)), resp)
    }

    /// REAL 原样搬运位模式：-0.0 不许被拍成 +0.0（服务器写回去的字节要和客户端一模一样）。
    func testRealBitsPreserved() throws {
        let req = SyncWire.PushRequest(schemaVersion: 1, changes: [
            .init(table: "t", rowId: "r", op: .upsert, baseFp: nil, row: ["z": .real(-0.0), "n": .real(.nan)]),
        ])
        let back = try SyncWire.decodePushRequest(SyncWire.encode(req)).changes[0].row!
        guard case .real(let z) = back["z"]!, case .real(let n) = back["n"]! else { return XCTFail() }
        XCTAssertEqual(z.bitPattern, (-0.0 as Double).bitPattern)
        XCTAssertEqual(n.bitPattern, Double.nan.bitPattern)
    }

    /// 同一行编出来的字节唯一（列按名字排序），跨端向量才有意义。
    func testRowEncodingIsDeterministic() {
        let a = SyncWire.PushRequest(schemaVersion: 1, changes: [.init(table: "t", rowId: "r", op: .upsert, baseFp: nil, row: row)])
        XCTAssertEqual(SyncWire.encode(a), SyncWire.encode(a))
        var w = SyncWire.Writer(); w.row(["b": .int(1), "a": .int(2)])
        var w2 = SyncWire.Writer(); w2.row(["a": .int(2), "b": .int(1)])
        XCTAssertEqual(w.data, w2.data)
    }

    func testMalformedInputThrows() {
        let ok = SyncWire.encode(SyncWire.PullResponse(head: 1, more: false, rows: [
            .init(table: "note", rowId: "N1", rev: 1, deleted: false, row: row)]))
        XCTAssertThrowsError(try SyncWire.decodePullResponse(ok.dropLast(3)))
        XCTAssertThrowsError(try SyncWire.decodePullResponse(ok + Data([0])))
        var bad = ok; bad[0] = 99
        XCTAssertThrowsError(try SyncWire.decodePullResponse(bad))
        XCTAssertThrowsError(try SyncWire.decodePushRequest(Data()))
    }
}
