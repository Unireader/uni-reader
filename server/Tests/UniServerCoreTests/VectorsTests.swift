import Foundation
import XCTest
@testable import UniServerCore

/// 块向量库（`WorkspaceVectors`，`SEMANTIC-SYNC-PLAN.md §2`）：上传去重、增量拉、分页、维数校验、清理换 epoch、随工作区删除。
final class VectorsTests: XCTestCase {

    private let model = "local|Qwen3-Embedding-0.6B@97b0c614"

    private func h(_ n: UInt8) -> Data { Data(repeating: n, count: 32) }
    private func v(_ n: UInt8, dim: Int = 4) -> Data { Data(repeating: n, count: dim) }

    private func put(_ vs: WorkspaceVectors, _ ns: [UInt8], dim: Int = 4, model m: String? = nil) throws -> (added: Int, head: UInt64) {
        try vs.put(body: SyncWire.encode(SyncWire.VecPut(model: m ?? model, dim: dim,
                                                           entries: ns.map { .init(hash: h($0), v: v($0, dim: dim)) })))
    }

    private func page(_ vs: WorkspaceVectors, since: UInt64, epoch: String?, limit: Int = 2000) throws -> SyncWire.VecPage {
        try SyncWire.decodeVecPage(vs.pageBody(model: model, since: since, epoch: epoch, limit: limit))
    }

    func testPutMissingPageAndPrune() throws {
        let f = try Fixture()
        let ws = try f.upload(try f.makeDevice("A"))
        let vs = try f.host.vectors(ws.id)

        // 空库：照常回空页、给 epoch
        let empty = try page(vs, since: 0, epoch: nil)
        XCTAssertTrue(empty.entries.isEmpty)
        XCTAssertFalse(empty.epoch.isEmpty)

        // missing：全缺，重复的哈希只回一次
        var miss = try SyncWire.decodeVecMissing(vs.missing(body: SyncWire.encode(SyncWire.VecHashes(model: model, hashes: [h(1), h(2), h(1)]))))
        XCTAssertEqual(miss.total, 0)
        XCTAssertEqual(miss.hashes, [h(1), h(2)])

        // 上传：已有的跳过，rev 递增
        XCTAssertEqual(try put(vs, [1, 2]).added, 2)
        let again = try put(vs, [2, 3])
        XCTAssertEqual(again.added, 1)
        XCTAssertEqual(again.head, 3)
        miss = try SyncWire.decodeVecMissing(vs.missing(body: SyncWire.encode(SyncWire.VecHashes(model: model, hashes: [h(1), h(4)]))))
        XCTAssertEqual(miss.total, 3)
        XCTAssertEqual(miss.hashes, [h(4)])

        // 维数不同 → 拒；别的模型各算各的
        XCTAssertThrowsError(try put(vs, [9], dim: 8))
        XCTAssertEqual(try put(vs, [1], dim: 8, model: "other").added, 1)

        // 增量拉 + 分页
        let p1 = try page(vs, since: 0, epoch: empty.epoch, limit: 2)
        XCTAssertEqual(p1.entries.map(\.hash), [h(1), h(2)])
        XCTAssertTrue(p1.more)
        XCTAssertEqual(p1.dim, 4)
        XCTAssertEqual(p1.entries.first?.v, v(1))
        let p2 = try page(vs, since: p1.next, epoch: p1.epoch, limit: 2)
        XCTAssertEqual(p2.entries.map(\.hash), [h(3)])
        XCTAssertFalse(p2.more)
        let p3 = try page(vs, since: p2.next, epoch: p2.epoch)
        XCTAssertTrue(p3.entries.isEmpty)
        XCTAssertEqual(p3.next, p2.next, "没有新的：since 原样回去")

        // 清理：只留 1、3，换 epoch；拿旧 epoch 来拉 → 从头给
        let pr = try vs.prune(body: SyncWire.encode(SyncWire.VecHashes(model: model, hashes: [h(1), h(3)])))
        XCTAssertEqual(pr.removed, 1)
        XCTAssertNotEqual(pr.epoch, p2.epoch)
        let reset = try page(vs, since: p2.next, epoch: p2.epoch)
        XCTAssertEqual(reset.epoch, pr.epoch)
        XCTAssertEqual(Set(reset.entries.map(\.hash)), [h(1), h(3)])
        XCTAssertEqual(try vs.count(model: "other"), 1, "清理只动这个模型")

        // 坏请求体 → badRequest
        XCTAssertThrowsError(try vs.put(body: Data([1, 2, 3]))) { e in
            guard case ServerError.badRequest = e else { return XCTFail("应为 badRequest：\(e)") }
        }
    }

    func testVectorsGoAwayWithWorkspace() throws {
        let f = try Fixture()
        let ws = try f.upload(try f.makeDevice("A"))
        let id = ws.id
        _ = try put(try f.host.vectors(id), [1])
        let file = f.host.paths.vectorsDB(id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        try f.host.delete(id, device: "x")
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "工作区删了，向量库一起删")
        XCTAssertThrowsError(try f.host.vectors(id), "没有这个工作区")
        XCTAssertThrowsError(try f.host.vectors("../x"), "id 不是 UUID")
    }
}
