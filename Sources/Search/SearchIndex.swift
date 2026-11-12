import Foundation
import CryptoKit

/// 全工作区搜索的索引（`SEARCH-PLAN.md`，用户 2026-11-12「把搜索这块整体都强化下」）。
///
/// - **放哪**：`~/Library/Application Support/UniReader/SearchIndex/<workspace_id>.sqlite`，单独一个库。
///   🔴 不进 `library.sqlite`：那个库每次备份 / 建镜像都整库 `VACUUM INTO`，同步也按白名单走表；索引是**派生数据**，
///   随时能重建，没必要跟着备份、同步，也不该变成三端（Mac / 安卓 / 服务器）的表结构契约。删了它只是下次搜索重建。
/// - **索引什么**：PDF 每页文字（OCR 优先、没 OCR 的页用 PDF 自带文字，与 `read_pages` 同一套）、Markdown 笔记（按标题 / 段落切块，带起始行号）、
///   批注（文字笔记的原文 + 正文、高亮原文、书签名、图片笔记说明）、习题（题干 / 选项 / 答案 / 解析 / 笔记 / 标签）、Agent 上下文。
/// - **怎么查**：块的文字归一化（`SearchText.normalize`：去空白、小写、全角变半角）后进 FTS5 trigram 索引；
///   三个字及以上的词走索引，一两个字的词退回 `LIKE`（trigram 至少要三个字）。候选在 Swift 里按 `SearchText.score` 排。
/// - **何时更新**：每次搜索前增量对一遍（每个来源有一个「指纹」：PDF = 当前版本 hash + OCR 引擎 + OCR 缓存戳，笔记 = 文件修改时间 + 大小，
///   批注 / 习题 / 上下文 = 条数 + 最新修改时间），只重建变了的。第一次建整库可能要一阵子：搜索最多等 `budget` 秒，
///   没建完就先用已有的结果并如实报告，后台接着建。
actor SearchIndex {

    // MARK: - 实例（一个工作区一个）

    private static let lock = NSLock()
    nonisolated(unsafe) private static var instances: [String: SearchIndex] = [:]

    static func shared(workspaceID: String) throws -> SearchIndex {
        lock.lock(); defer { lock.unlock() }
        if let i = instances[workspaceID] { return i }
        let i = try SearchIndex(workspaceID: workspaceID)
        instances[workspaceID] = i
        return i
    }

    /// 测试用：spike 把索引放进临时目录，别写进真的 Application Support。
    nonisolated(unsafe) static var testRoot: URL?

    static var root: URL {
        let url = testRoot ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("UniReader/SearchIndex", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// 表结构版本：改了切块 / 归一化规则就加一，旧库整个丢掉重建。
    static let schemaVersion = "3"

    let db: SQLiteDB
    let path: URL

    private init(workspaceID: String) throws {
        let safe = workspaceID.replacingOccurrences(of: "/", with: "_")
        path = Self.root.appendingPathComponent(safe + ".sqlite")
        db = try SQLiteDB(path: path.path)
        let v = (try? db.query("SELECT value FROM meta WHERE key='schema'"))?.first?["value"] as? String
        if v != Self.schemaVersion {
            try db.exec("""
            DROP TRIGGER IF EXISTS chunk_ai; DROP TRIGGER IF EXISTS chunk_ad; DROP TABLE IF EXISTS chunk_fts; DROP TABLE IF EXISTS chunk; DROP TABLE IF EXISTS source; DROP TABLE IF EXISTS meta;
            DROP TABLE IF EXISTS vec;
            """)
        }
        try db.exec("""
        CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS source(key TEXT PRIMARY KEY, stamp TEXT NOT NULL, title TEXT NOT NULL DEFAULT '');
        CREATE TABLE IF NOT EXISTS chunk(
            id INTEGER PRIMARY KEY AUTOINCREMENT, source TEXT NOT NULL, kind TEXT NOT NULL, owner TEXT NOT NULL,
            sub TEXT NOT NULL DEFAULT '', page INTEGER, line INTEGER, title TEXT NOT NULL, heading TEXT NOT NULL DEFAULT '',
            body TEXT NOT NULL, norm TEXT NOT NULL, title_norm TEXT NOT NULL DEFAULT '');
        CREATE INDEX IF NOT EXISTS chunk_source ON chunk(source);
        CREATE VIRTUAL TABLE IF NOT EXISTS chunk_fts USING fts5(norm, content='chunk', content_rowid='id', tokenize='trigram');
        CREATE TRIGGER IF NOT EXISTS chunk_ai AFTER INSERT ON chunk BEGIN
            INSERT INTO chunk_fts(rowid, norm) VALUES (new.id, new.norm); END;
        CREATE TRIGGER IF NOT EXISTS chunk_ad AFTER DELETE ON chunk BEGIN
            INSERT INTO chunk_fts(chunk_fts, rowid, norm) VALUES ('delete', old.id, old.norm); END;
        CREATE TABLE IF NOT EXISTS vec(chunk_id INTEGER PRIMARY KEY, model TEXT NOT NULL, v BLOB NOT NULL);
        INSERT OR REPLACE INTO meta(key, value) VALUES ('schema', '\(Self.schemaVersion)');
        """)
    }

    // MARK: - 来源

    /// 一个要索引的来源：`key` 唯一（`pdf:<文档 id>` / `md:<note key>` / `ann:<文档 id>` / `ex:all` / `ctx:all`），
    /// `stamp` 变了才重建；`load` 在建的时候才调（读 OCR、读文件这些慢活都在它里面）。
    struct Source: Sendable {
        let key: String
        let title: String
        /// 指纹（在索引自己的线程上算：可能要查库 / 看文件，别占主线程）。
        let stamp: @Sendable () -> String
        let load: @Sendable () async -> [Chunk]
    }

    struct Chunk: Sendable {
        var kind: String          // pdf / markdown / annotation / exercise / context
        var owner: String         // 文档 id / note key / 习题 id / 上下文 id
        var sub: String = ""      // 批注 id；批注种类放在 heading 里
        var page: Int? = nil      // 0 起
        var line: Int? = nil      // 1 起
        var title: String
        var heading: String = ""
        var body: String
    }

    struct Progress: Sendable {
        var total = 0
        var done = 0
        var building = false
        var lastError: String?
    }

    private(set) var progress = Progress()
    private var running: Task<Void, Never>?
    private var pendingSources: [Source]?

    /// 把索引对到给定的来源清单：删掉清单里没有的、重建指纹变了的。正在建就排队（只留最新一份清单）。
    /// 返回在 `budget` 秒内有没有建完（没建完后台接着建）。
    func refresh(_ sources: [Source], budget: TimeInterval, embedder: EmbeddingProvider? = nil) async -> Bool {
        pendingSources = sources
        self.embedder = embedder
        if embedder == nil { embedding?.cancel() }   // 设置里关掉了语义搜索：正在算的向量停下
        if running == nil { startNext() }
        guard let task = running else { return true }
        let finished = await withTaskGroup(of: Bool.self) { group -> Bool in
            group.addTask { await task.value; return true }
            group.addTask { try? await Task.sleep(nanoseconds: UInt64(max(0, budget) * 1e9)); return false }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        return finished && running == nil
    }

    private func startNext() {
        guard let sources = pendingSources else { running = nil; return }
        pendingSources = nil
        running = Task { [weak self] in
            await self?.sync(sources)
            await self?.finishRun()
        }
    }

    private func finishRun() {
        running = nil
        if pendingSources != nil { startNext() } else {
            progress.building = false
            startEmbedding()
        }
    }

    // MARK: - 向量（语义搜索，`SEARCH-PLAN.md §5`）

    private var embedder: EmbeddingProvider?
    private var embedding: Task<Void, Never>?
    struct EmbedProgress: Sendable { var done = 0; var total = 0; var running = false; var lastError: String? }
    private(set) var embedProgress = EmbedProgress()
    /// 内存里的向量（按模型分）：ids 与 flat（ids.count × dim 个 Int8）一一对应。向量一变就作废重读。
    private var vecCache: [String: (ids: [Int64], dim: Int, flat: [Int8])]?

    private static func owns(_ e: EmbeddingProvider) -> (sql: String, param: SQLiteDB.Value) {
        e.modelID == "system" ? ("model LIKE ?", .text("system-%")) : ("model = ?", .text(e.modelID))
    }

    /// 本机模型一次只看约 256 个字，再长截掉；接口那种给到 1500 字。
    private static func embedInput(_ body: String, system: Bool) -> String {
        String(body.prefix(system ? 250 : 1500))
    }

    private func startEmbedding() {
        guard let e = embedder, embedding == nil else { return }
        embedding = Task { [weak self] in
            await self?.embedAll(e)
            await self?.embeddingDone()
        }
    }

    private func embeddingDone() {
        embedding = nil
        embedProgress.running = false
    }

    private func embedAll(_ e: EmbeddingProvider) async {
        let own = Self.owns(e)
        // 换了模型：别的模型算的向量全部作废
        try? db.run("DELETE FROM vec WHERE NOT (\(own.sql))", [own.param])
        try? db.run("DELETE FROM vec WHERE chunk_id NOT IN (SELECT id FROM chunk)")
        let total = ((try? db.query("SELECT COUNT(*) AS n FROM chunk"))?.first?["n"] as? Int64).map(Int.init) ?? 0
        var done = ((try? db.query("SELECT COUNT(*) AS n FROM vec"))?.first?["n"] as? Int64).map(Int.init) ?? 0
        embedProgress = EmbedProgress(done: done, total: total, running: true, lastError: nil)
        let system = e.modelID == "system"
        let batch = system ? 16 : 32
        while !Task.isCancelled {
            let rows = (try? db.query("SELECT id, body FROM chunk WHERE id NOT IN (SELECT chunk_id FROM vec) ORDER BY id LIMIT \(batch)")) ?? []
            guard !rows.isEmpty else { break }
            let ids = rows.compactMap { $0["id"] as? Int64 }
            let texts = rows.map { Self.embedInput($0["body"] as? String ?? "", system: system) }
            do {
                let vs = try await e.embed(texts)
                try db.transaction {
                    for (id, v) in zip(ids, vs) {
                        try db.run("INSERT OR REPLACE INTO vec(chunk_id, model, v) VALUES (?,?,?)",
                                   [.int(id), .text(v.model), .blob(VectorMath.quantize(v.vector))])
                    }
                }
                done += ids.count
                embedProgress.done = done
                vecCache = nil
            } catch {
                embedProgress.lastError = error.localizedDescription
                break   // 接口出错（没网 / 密钥不对）：停下，下次搜索再接着算
            }
        }
    }

    private func loadVectors() -> [String: (ids: [Int64], dim: Int, flat: [Int8])] {
        if let vecCache { return vecCache }
        var out: [String: (ids: [Int64], dim: Int, flat: [Int8])] = [:]
        let rows = (try? db.query("SELECT chunk_id, model, v FROM vec")) ?? []
        for r in rows {
            guard let id = r["chunk_id"] as? Int64, let m = r["model"] as? String, let d = r["v"] as? Data else { continue }
            var e = out[m] ?? ([], d.count, [])
            guard d.count == e.dim else { continue }
            e.ids.append(id)
            d.withUnsafeBytes { e.flat.append(contentsOf: $0.bindMemory(to: Int8.self)) }
            out[m] = e
        }
        vecCache = out
        return out
    }

    /// 语义搜索：查询向量与每块的向量比（同一模型才比），取最像的 `k` 块，再按筛选条件过一遍。
    func semantic(_ query: [(model: String, vector: [Float])], filter: Filter, limit: Int, k: Int = 300) -> [Hit] {
        let all = loadVectors()
        var scored: [(Int64, Double)] = []
        for (model, qv) in query {
            guard let e = all[model], e.dim == qv.count, e.dim > 0 else { continue }
            let q = qv.map { Int8(max(-127, min(127, ($0 * 127).rounded()))) }
            e.flat.withUnsafeBufferPointer { buf in
                for (i, id) in e.ids.enumerated() {
                    let row = UnsafeBufferPointer(rebasing: buf[(i * e.dim)..<((i + 1) * e.dim)])
                    scored.append((id, Double(VectorMath.dot(q, row)) / (127 * 127)))
                }
            }
        }
        scored.sort { $0.1 > $1.1 }
        var best: [Int64: Double] = [:]
        for (id, s) in scored.prefix(k * 2) where best[id] == nil { best[id] = s }
        let ids = Array(best.keys)
        guard !ids.isEmpty else { return [] }
        let rows = fetch(ids: ids, filter: filter)
        var hits = rows.map { r -> Hit in var h = r.hit; h.score = best[h.chunkID] ?? 0; return h }
        hits.sort { $0.score > $1.score }
        return Self.dedupe(hits, limit: limit)
    }

    var vectorCount: Int { ((try? db.query("SELECT COUNT(*) AS n FROM vec"))?.first?["n"] as? Int64).map(Int.init) ?? 0 }

    /// 两路结果合并（倒数排名融合，k = 60）：两边都靠前的最靠前，只在一边出现的也留着。
    static func fuse(keyword: [Hit], semantic: [Hit], limit: Int) -> [Hit] {
        func key(_ h: Hit) -> String {
            switch h.kind {
            case "pdf": return "pdf|\(h.owner)|\(h.page ?? -1)"
            case "annotation": return "ann|\(h.sub)"
            case "exercise", "context": return "\(h.kind)|\(h.owner)"
            default: return "\(h.kind)|\(h.owner)|\(h.line ?? -1)"
            }
        }
        var score: [String: Double] = [:], pick: [String: Hit] = [:]
        for (i, h) in keyword.enumerated() { let k = key(h); score[k, default: 0] += 1 / (60 + Double(i + 1)); pick[k] = pick[k] ?? h }
        for (i, h) in semantic.enumerated() { let k = key(h); score[k, default: 0] += 1 / (60 + Double(i + 1)); pick[k] = pick[k] ?? h }
        return score.sorted { $0.value > $1.value }.prefix(limit).compactMap { kv in
            pick[kv.key].map { var h = $0; h.score = kv.value; return h }
        }
    }

    private func sync(_ sources: [Source]) async {
        let have = Dictionary(((try? db.query("SELECT key, stamp FROM source")) ?? []).compactMap { r -> (String, String)? in
            guard let k = r["key"] as? String, let s = r["stamp"] as? String else { return nil }
            return (k, s)
        }, uniquingKeysWith: { a, _ in a })
        let wanted = Set(sources.map(\.key))
        for k in have.keys where !wanted.contains(k) { remove(source: k) }
        let todo = sources.map { ($0, $0.stamp()) }.filter { have[$0.0.key] != $0.1 }
        progress = Progress(total: todo.count, done: 0, building: !todo.isEmpty, lastError: nil)
        for (s, stamp) in todo {
            let chunks = await s.load()
            write(s, stamp: stamp, chunks)
            progress.done += 1
        }
    }

    private func remove(source key: String) {
        try? db.run("DELETE FROM vec WHERE chunk_id IN (SELECT id FROM chunk WHERE source=?)", [.text(key)])
        try? db.run("DELETE FROM chunk WHERE source=?", [.text(key)])
        try? db.run("DELETE FROM source WHERE key=?", [.text(key)])
    }

    private func write(_ s: Source, stamp: String, _ chunks: [Chunk]) {
        do {
            try db.transaction {
                try db.run("DELETE FROM vec WHERE chunk_id IN (SELECT id FROM chunk WHERE source=?)", [.text(s.key)])
                try db.run("DELETE FROM chunk WHERE source=?", [.text(s.key)])
                for c in chunks {
                    let norm = SearchText.normalize(c.body)
                    guard !norm.isEmpty else { continue }
                    try db.run("""
                    INSERT INTO chunk(source, kind, owner, sub, page, line, title, heading, body, norm, title_norm)
                    VALUES (?,?,?,?,?,?,?,?,?,?,?)
                    """, [.text(s.key), .text(c.kind), .text(c.owner), .text(c.sub),
                          c.page.map { .int(Int64($0)) } ?? .null, c.line.map { .int(Int64($0)) } ?? .null,
                          .text(c.title), .text(c.heading), .text(c.body), .text(norm),
                          .text(SearchText.normalize(c.title + " " + c.heading))])
                }
                try db.run("INSERT OR REPLACE INTO source(key, stamp, title) VALUES (?,?,?)", [.text(s.key), .text(stamp), .text(s.title)])
            }
        } catch {
            progress.lastError = "\(s.title): \(error)"
        }
    }

    /// 整个丢掉（设置里「重建搜索索引」、或表坏了）。下次搜索从头建。
    func reset() {
        embedding?.cancel()
        vecCache = nil
        try? db.exec("DELETE FROM vec; DELETE FROM chunk; DELETE FROM source;")
        try? db.exec("INSERT INTO chunk_fts(chunk_fts) VALUES ('rebuild');")
    }

    var stats: (sources: Int, chunks: Int) {
        let s = (try? db.query("SELECT COUNT(*) AS n FROM source"))?.first?["n"] as? Int64 ?? 0
        let c = (try? db.query("SELECT COUNT(*) AS n FROM chunk"))?.first?["n"] as? Int64 ?? 0
        return (Int(s), Int(c))
    }

    // MARK: - 查

    struct Filter: Sendable {
        var kinds: Set<String> = []          // 空 = 全部
        var owners: Set<String> = []         // 文档 id（pdf / annotation / exercise 的所属文档）；空 = 不限
        var notePrefix: String? = nil        // markdown：note key 前缀（`<源 id>:<目录>/`）
    }

    struct Hit: Sendable {
        var chunkID: Int64
        var kind: String
        var owner: String
        var sub: String
        var page: Int?
        var line: Int?
        var title: String
        var heading: String
        var body: String
        var score: Double
        var docID: String?       // 批注 / 习题所属文档（owner 不是文档 id 的那些）
    }

    /// 关键词搜索。`all` = 所有词都要出现；没有结果且不止一个词时自动退回「任一词」（`relaxed` = true）。
    func keyword(_ query: String, filter: Filter, limit: Int, candidateCap: Int = 4000) -> (hits: [Hit], terms: [String], relaxed: Bool, candidates: Int) {
        let terms = SearchText.terms(query)
        guard !terms.isEmpty else { return ([], [], false, 0) }
        var rows = candidates(terms: terms, all: true, filter: filter, cap: candidateCap)
        var relaxed = false
        if rows.isEmpty, terms.count > 1 {
            rows = candidates(terms: terms, all: false, filter: filter, cap: candidateCap)
            relaxed = true
        }
        // 每个词都要真的出现（正文或标题）：短词那路查的是正文、标题各一遍，这里统一核实一次
        if !relaxed {
            rows = rows.filter { r in terms.allSatisfy { r.norm.contains($0) || r.titleNorm.contains($0) } }
        }
        var df: [String: Int] = [:]
        for r in rows { for t in terms where r.norm.contains(t) { df[t, default: 0] += 1 } }
        var hits = rows.map { r -> Hit in
            var h = r.hit
            h.score = SearchText.score(norm: r.norm, titleNorm: r.titleNorm, terms: terms, df: df, n: rows.count)
            return h
        }.filter { $0.score > 0 }
        hits.sort { $0.score > $1.score }
        return (Self.dedupe(hits, limit: limit), terms, relaxed, rows.count)
    }

    /// PDF 同一页、笔记同一段只留分最高的一块（块是为了语义检索切小的，结果按页 / 段给人看）。
    static func dedupe(_ hits: [Hit], limit: Int) -> [Hit] {
        var seen = Set<String>(), out: [Hit] = []
        for h in hits {
            let key: String
            switch h.kind {
            case "pdf": key = "pdf|\(h.owner)|\(h.page ?? -1)"
            case "annotation": key = "ann|\(h.sub)"
            case "exercise": key = "ex|\(h.owner)"
            case "context": key = "ctx|\(h.owner)"
            default: key = "\(h.kind)|\(h.owner)|\(h.line ?? -1)"
            }
            guard seen.insert(key).inserted else { continue }
            out.append(h)
            if out.count >= limit { break }
        }
        return out
    }

    private struct Row { var hit: Hit; var norm: String; var titleNorm: String }

    private func fetch(ids: [Int64], filter: Filter) -> [Row] {
        var out: [Row] = []
        for part in stride(from: 0, to: ids.count, by: 500).map({ Array(ids[$0..<min($0 + 500, ids.count)]) }) {
            var clauses = ["c.id IN (" + part.map(String.init).joined(separator: ",") + ")"]
            var params: [SQLiteDB.Value] = []
            Self.addFilter(filter, to: &clauses, &params)
            let sql = "SELECT c.id, c.kind, c.owner, c.sub, c.page, c.line, c.title, c.heading, c.body, c.norm, c.title_norm FROM chunk c WHERE "
                + clauses.joined(separator: " AND ")
            out += ((try? db.query(sql, params)) ?? []).map(Self.row)
        }
        return out
    }

    private static func addFilter(_ filter: Filter, to clauses: inout [String], _ params: inout [SQLiteDB.Value]) {
        if !filter.kinds.isEmpty {
            clauses.append("c.kind IN (" + filter.kinds.map { _ in "?" }.joined(separator: ",") + ")")
            params += filter.kinds.sorted().map { .text($0) }
        }
        if !filter.owners.isEmpty {
            // 限定文档：PDF 页与批注的 owner 是文档 id；习题的 owner 是题 id，所属文档记在 sub（`doc:<id>`）。笔记 / 上下文不属于文档，筛掉
            let marks = filter.owners.map { _ in "?" }.joined(separator: ",")
            clauses.append("(c.owner IN (\(marks)) OR c.sub IN (\(marks)))")
            params += filter.owners.sorted().map { .text($0) } + filter.owners.sorted().map { .text("doc:" + $0) }
        }
        if let p = filter.notePrefix, !p.isEmpty {
            clauses.append("(c.kind <> 'markdown' OR substr(c.owner, 1, ?) = ?)")
            params += [.int(Int64(p.count)), .text(p)]
        }
    }

    private static func row(_ r: [String: Any]) -> Row {
        let sub = r["sub"] as? String ?? ""
        let kind = r["kind"] as? String ?? ""
        return Row(hit: Hit(chunkID: r["id"] as? Int64 ?? 0, kind: kind, owner: r["owner"] as? String ?? "",
                            sub: sub, page: (r["page"] as? Int64).map(Int.init), line: (r["line"] as? Int64).map(Int.init),
                            title: r["title"] as? String ?? "", heading: r["heading"] as? String ?? "",
                            body: r["body"] as? String ?? "", score: 0,
                            docID: kind == "exercise" && sub.hasPrefix("doc:") ? String(sub.dropFirst(4)) : nil),
                   norm: r["norm"] as? String ?? "", titleNorm: r["title_norm"] as? String ?? "")
    }

    private func candidates(terms: [String], all: Bool, filter: Filter, cap: Int) -> [Row] {
        var clauses: [String] = [], params: [SQLiteDB.Value] = []
        let long = terms.filter { $0.count >= 3 }, short = terms.filter { $0.count < 3 }
        func ftsQuote(_ t: String) -> String { "\"" + t.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        func likeEscape(_ t: String) -> String {
            t.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_")
        }
        var termClauses: [String] = []
        if !long.isEmpty {
            termClauses.append("c.id IN (SELECT rowid FROM chunk_fts WHERE chunk_fts MATCH ?)")
            params.append(.text(long.map(ftsQuote).joined(separator: all ? " AND " : " OR ")))
        }
        for t in short {
            termClauses.append("(c.norm LIKE ? ESCAPE '\\' OR c.title_norm LIKE ? ESCAPE '\\')")
            params += [.text("%\(likeEscape(t))%"), .text("%\(likeEscape(t))%")]
        }
        clauses.append("(" + termClauses.joined(separator: all ? " AND " : " OR ") + ")")
        Self.addFilter(filter, to: &clauses, &params)
        let sql = "SELECT c.id, c.kind, c.owner, c.sub, c.page, c.line, c.title, c.heading, c.body, c.norm, c.title_norm FROM chunk c WHERE "
            + clauses.joined(separator: " AND ") + " LIMIT \(cap)"
        return ((try? db.query(sql, params)) ?? []).map(Self.row)
    }
}
