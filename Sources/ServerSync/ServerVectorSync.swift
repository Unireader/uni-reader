import Foundation

/// 把搜索索引里本机模型算好的块向量传到服务器，给安卓搜索用（方案 `SEMANTIC-SYNC-PLAN.md §3`，线格式 `PROTOCOL.md §9.7`）。
///
/// 按内容寻址：每次先问服务器缺哪些（`missing`），只传缺的；不在本机记「传过哪些」——重传不会出错，省掉一张要维护的表。
/// 本机索引算齐了、而服务器上的条数比本机多出 30% 以上 → 让服务器清掉没人用的（`prune`）。
enum ServerVectorSync {

    struct Report: Equatable {
        /// 本机去重后的条数。
        var local = 0
        var uploaded = 0
        /// 传完之后服务器上这个模型的条数（清理前）。
        var serverTotal = 0
        var pruned = false
    }

    /// 每次问「缺哪些」最多带多少个哈希（20000 × 32 字节 = 640 KB）。
    static let askBatch = 20_000
    static let putBatch = 2_000
    /// 服务器条数超过本机的这个倍数才清理（偶尔多几条孤儿不值得让各设备重拉）。
    static let pruneRatio = 1.3

    /// 本机要传的一份（`SearchIndex.vectorExport` 给出；这里不引用 `SearchIndex`，端到端 spike 才能单独编这个文件）。
    struct Export {
        var model: String
        var dim: Int
        var entries: [SyncWire.VecEntry]
        /// 本机索引算齐了：只有这时才许让服务器清理孤儿。
        var complete: Bool
    }

    static func upload(_ client: ServerClient, workspace wid: String, export e: Export) async throws -> Report {
        var r = Report(local: e.entries.count)
        var missing: [Data] = [], total = 0
        for start in stride(from: 0, to: e.entries.count, by: askBatch) {
            let part = e.entries[start..<min(start + askBatch, e.entries.count)]
            let m = try await client.vectorsMissing(wid, .init(model: e.model, hashes: part.map(\.hash)))
            missing += m.hashes
            total = Int(m.total)
        }
        let byHash = Dictionary(e.entries.map { ($0.hash, $0) }, uniquingKeysWith: { a, _ in a })
        let send = missing.compactMap { byHash[$0] }
        for start in stride(from: 0, to: send.count, by: putBatch) {
            try Task.checkCancellation()
            let part = Array(send[start..<min(start + putBatch, send.count)])
            try await client.putVectors(wid, .init(model: e.model, dim: e.dim, entries: part))
            r.uploaded += part.count
        }
        r.serverTotal = total + r.uploaded
        if e.complete, !e.entries.isEmpty, Double(r.serverTotal) > Double(e.entries.count) * pruneRatio {
            try await client.pruneVectors(wid, .init(model: e.model, hashes: e.entries.map(\.hash)))
            r.pruned = true
        }
        return r
    }
}
