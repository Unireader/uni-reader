// 全工作区搜索（`SEARCH-PLAN.md`）回归测试：归一化 / 切段 / 摘要 / 打分 + 索引的增量更新、两条查法、筛选、向量与合并排序。
// 运行：
//   mkdir -p /tmp/srch && cp spike/search-test.swift /tmp/srch/main.swift && swiftc -O Sources/Search/SearchText.swift \
//     Sources/Search/SearchIndex.swift Sources/Search/Embedding.swift Sources/Store/SQLite.swift \
//     /tmp/srch/main.swift -o /tmp/srch/t && /tmp/srch/t
// 索引写进临时目录（`SearchIndex.testRoot`），不碰真的 Application Support。

import Foundation

var pass = 0, fail = 0
func check(_ cond: Bool, _ msg: String) {
    if cond { pass += 1; print("  ✅ \(msg)") } else { fail += 1; print("  ❌ \(msg)") }
}

print("— 1) 归一化")
check(SearchText.normalize("矛盾的普\n遍性 ") == "矛盾的普遍性", "去掉换行与空格")
check(SearchText.normalize("ＡＢＣ　ｄｅｆ１２３") == "abcdef123", "全角变半角、小写")
check(SearchText.normalize("Matrix Rank") == "matrixrank", "西文去空格、小写")
check(SearchText.terms("  矛盾  \"普遍 性\" 矛盾 ") == ["矛盾", "普遍性"], "引号里的算一个词、去重（得到 \(SearchText.terms("  矛盾  \"普遍 性\" 矛盾 "))）")
check(SearchText.terms("“拉格朗日 中值”") == ["拉格朗日中值"], "中文引号也认")

print("— 2) 切段")
let long = String(repeating: "甲乙丙丁戊", count: 300)   // 1500 字、没换行
let cs = SearchText.chunks(long, maxChars: 500)
check(cs.count == 3 && cs.allSatisfy { $0.count <= 500 }, "超长无换行硬切成 3 块")
let paras = "第一段\n\n第二段\n\n第三段"
check(SearchText.chunks(paras, maxChars: 500) == ["第一段\n第二段\n第三段"], "小段合并")
let md = "---\ntags: [a]\n---\n# 极限\n定义……\n\n## 左极限\n内容\n```\n# 不是标题\n```\n尾巴"
let mc = SearchText.markdownChunks(md)
check(mc.map(\.line) == [1, 4, 7], "按标题切块、起始行号（得到 \(mc.map(\.line))）")
check(mc.map(\.heading) == ["", "极限", "左极限"], "所在标题（代码块里的 # 不算）")
check(mc.last?.text.contains("尾巴") == true, "代码块后面的文字仍在同一块")

print("— 3) 摘要")
let body = "第一章 唯物辩证法\n矛盾的普\n遍性是指矛盾存在于一切事物的发展过程中。"
let sn = SearchText.snippet(body, terms: ["矛盾的普遍性"], radius: 6)
check(sn.contains("[矛盾的普 遍性]"), "跨行命中也能标出来，换行变空格（得到 \(sn)）")
check(sn.hasPrefix("…") && sn.hasSuffix("…"), "前后截断有省略号")
check(SearchText.snippet("abc", terms: ["zz"]) == "abc", "没命中就给开头")

print("— 4) 打分")
let df = ["极限": 2, "函数": 1]
let a = SearchText.score(norm: "函数极限的定义函数", titleNorm: "", terms: ["极限", "函数"], df: df, n: 3)
let b = SearchText.score(norm: "极限的定义", titleNorm: "", terms: ["极限", "函数"], df: df, n: 3)
let c = SearchText.score(norm: "极限的定义", titleNorm: "函数", terms: ["极限", "函数"], df: df, n: 3)
check(a > b, "两个词都中 > 只中一个")
check(c > b, "标题里有也加分")

print("— 5) 索引：建、查、增量")
let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("search-spike-\(UUID().uuidString)")
SearchIndex.testRoot = tmp
let idx = try! SearchIndex.shared(workspaceID: "ws-test")

final class Counter: @unchecked Sendable { var n = 0; let lock = NSLock(); func bump() { lock.lock(); n += 1; lock.unlock() } }
let loads = Counter()
func pdfSource(_ id: String, stamp: String, pages: [String]) -> SearchIndex.Source {
    .init(key: "pdf:\(id)", title: "书\(id)", stamp: { stamp }, load: {
        loads.bump()
        return pages.enumerated().flatMap { i, t in SearchText.chunks(t).map { SearchIndex.Chunk(kind: "pdf", owner: id, page: i, title: "书\(id)", body: $0) } }
    })
}
let noteSrc = SearchIndex.Source(key: "md:ws:数学/极限.md", title: "极限", stamp: { "1" }, load: {
    SearchText.markdownChunks("# 极限\n函数极限的 ε-δ 定义\n\n## 例题\n求 lim sin x / x").map {
        SearchIndex.Chunk(kind: "markdown", owner: "ws:数学/极限.md", line: $0.line, title: "极限", heading: $0.heading, body: $0.text)
    }
})
let vaultNote = SearchIndex.Source(key: "md:vault:政治/矛盾.md", title: "矛盾", stamp: { "1" }, load: {
    [SearchIndex.Chunk(kind: "markdown", owner: "vault:政治/矛盾.md", line: 1, title: "矛盾", body: "矛盾的特殊性：具体问题具体分析")]
})
let annSrc = SearchIndex.Source(key: "ann:D1", title: "书D1", stamp: { "1" }, load: {
    [SearchIndex.Chunk(kind: "annotation", owner: "D1", sub: "AAAA-1", page: 0, title: "书D1", heading: "highlight", body: "普遍性寓于特殊性之中")]
})
let exSrc = SearchIndex.Source(key: "ex:all", title: "ex", stamp: { "1" }, load: {
    [SearchIndex.Chunk(kind: "exercise", owner: "E1", sub: "doc:D2", page: 3, title: "书D2 · 5", body: "下列关于矛盾普遍性的说法正确的是\nA. 矛盾无处不在")]
})
func run<T>(_ f: @escaping () async -> T) -> T {
    let s = DispatchSemaphore(value: 0); var out: T!
    Task { out = await f(); s.signal() }
    s.wait(); return out
}
let d1 = pdfSource("D1", stamp: "a", pages: ["第一章 唯物辩证法\n矛盾的普\n遍性是指矛盾存在于一切事物的发展过程中", "实践是检验真理的唯一标准"])
let d2 = pdfSource("D2", stamp: "a", pages: ["拉格朗日中值定理：存在一点使导数等于斜率", "Matrix rank equals the column rank"])
var sources = [d1, d2, noteSrc, vaultNote, annSrc, exSrc]
check(run { await idx.refresh(sources, budget: 30) }, "第一次建完")
check(loads.n == 2, "两本书各读一次")
func kw(_ q: String, _ f: SearchIndex.Filter = .init(), limit: Int = 20) -> (hits: [SearchIndex.Hit], terms: [String], relaxed: Bool, candidates: Int) {
    run { await idx.keyword(q, filter: f, limit: limit) }
}
var r = kw("矛盾的普遍性")
check(r.hits.first?.kind == "pdf" && r.hits.first?.owner == "D1" && r.hits.first?.page == 0, "跨行的整句搜得中（三字以上走全文索引）")
r = kw("中值")
check(r.hits.map(\.owner) == ["D2"], "两个字的词走 LIKE（得到 \(r.hits.map(\.owner))）")
r = kw("rank MATRIX")
check(r.hits.first?.owner == "D2" && r.hits.first?.page == 1 && !r.relaxed, "西文多词、不分大小写")
r = kw("矛盾 斜率")
check(r.relaxed && Set(r.hits.map(\.owner)).isSuperset(of: ["D1", "D2"]), "没有同时含两个词的 → 退回任一词")
r = kw("普遍性")
check(Set(r.hits.map(\.kind)) == ["pdf", "annotation", "exercise"], "PDF / 批注 / 习题都搜到（得到 \(Set(r.hits.map(\.kind)))）")
r = kw("普遍性", .init(kinds: ["annotation"]))
check(r.hits.count == 1 && r.hits[0].sub == "AAAA-1", "按种类筛")
r = kw("普遍性", .init(owners: ["D2"]))
check(r.hits.map(\.kind) == ["exercise"] && r.hits[0].docID == "D2", "按文档筛：习题按所属文档认（得到 \(r.hits.map(\.kind))）")
r = kw("矛盾", .init(kinds: ["markdown"], notePrefix: "vault:"))
check(r.hits.map(\.owner) == ["vault:政治/矛盾.md"], "按笔记来源筛")
r = kw("lim sin")
check(r.hits.first?.kind == "markdown" && r.hits.first?.line == 4 && r.hits.first?.heading == "例题", "笔记命中带行号与标题")
r = kw("矛盾")
let pages = r.hits.filter { $0.kind == "pdf" }.map { "\($0.owner)#\($0.page ?? -1)" }
check(Set(pages).count == pages.count, "同一页只留一条")

_ = run { await idx.refresh(sources, budget: 30) }
check(loads.n == 2, "指纹没变：不重读")
sources[0] = pdfSource("D1", stamp: "b", pages: ["新内容：对立统一规律"])
_ = run { await idx.refresh(sources, budget: 30) }
check(loads.n == 3, "指纹变了：只重读那一本")
check(kw("矛盾的普遍性").hits.filter { $0.kind == "pdf" }.isEmpty && kw("对立统一").hits.first?.owner == "D1", "旧内容没了、新内容在")
sources.removeAll { $0.key == "pdf:D2" }
_ = run { await idx.refresh(sources, budget: 30) }
check(kw("中值").hits.isEmpty, "来源没了：它的块删掉")

print("— 5b) 链接（edge 表，KNOWLEDGE-LINKS-PLAN §4）与部分对账")
let linkNote = SearchIndex.Source(key: "md:ws:关联.md", title: "关联", stamp: { "1" }, loadAll: {
    .init(chunks: [SearchIndex.Chunk(kind: "markdown", owner: "ws:关联.md", line: 1, title: "关联", body: "见 [[书D1#page=2]]")],
          edges: [SearchIndex.Edge(fromKind: "markdown", fromOwner: "ws:关联.md", fromLine: 1, kind: "wiki",
                                   target: "书D1#page=2", raw: "[[书D1#page=2]]", context: "见 [[书D1#page=2]]")])
})
sources.append(linkNote)
_ = run { await idx.refresh(sources, budget: 30) }
var edges = run { await idx.allEdges() }
check(edges.count == 1 && edges[0].target == "书D1#page=2" && edges[0].fromLine == 1, "笔记里的链接记下来了")
// 部分对账：只给笔记与批注两类，PDF 那些来源不许被当成「没了」删掉
let onlyLinks = sources.filter { $0.key.hasPrefix("md:") || $0.key.hasPrefix("ann:") }
_ = run { await idx.refreshLinks(onlyLinks, prefixes: ["md:", "ann:"], budget: 30) }
check(!kw("对立统一").hits.isEmpty, "部分对账不删 PDF 来源")
sources.removeAll { $0.key == "md:ws:关联.md" }
_ = run { await idx.refreshLinks(sources, prefixes: ["md:"], budget: 30) }
edges = run { await idx.allEdges() }
check(edges.isEmpty, "笔记没了：它的链接一起删")

print("— 5c) 全量建索引正慢的时候，笔记 / 批注的链接照样马上更新（用户 2026-11-12 报「关联列表看不到」）")
let slowBook = SearchIndex.Source(key: "pdf:SLOW", title: "很慢的书", stamp: { "1" }, load: {
    try? await Task.sleep(nanoseconds: 4_000_000_000)   // 模拟几百页的书：读 OCR + 抽字要好一阵
    return [SearchIndex.Chunk(kind: "pdf", owner: "SLOW", page: 0, title: "很慢的书", body: "慢")]
})
let annNew = SearchIndex.Source(key: "ann:D1", title: "书D1", stamp: { "2" }, loadAll: {
    .init(chunks: [], edges: [SearchIndex.Edge(fromKind: "annotation", fromOwner: "D1", fromSub: "A-1", fromPage: 130,
                                               kind: "wiki", target: "书D2", raw: "[[书D2]]", context: "[[书D2]]")])
})
var withSlow = sources.filter { $0.key != "ann:D1" } + [slowBook, annNew]
let fullStarted = run { await idx.refresh(withSlow, budget: 0) }
check(!fullStarted, "全量那轮还在建（很慢的书）")
let t0 = Date()
let linksDone = run { await idx.refreshLinks(withSlow, prefixes: ["md:", "ann:"], budget: 2) }
check(linksDone && Date().timeIntervalSince(t0) < 1.5, "链接那一路不等全量、马上建完（\(String(format: "%.2f", Date().timeIntervalSince(t0))) 秒）")
check(run { await idx.allEdges() }.contains { $0.fromSub == "A-1" && $0.target == "书D2" }, "批注里新写的链接已经在了")
_ = run { await idx.refresh(withSlow, budget: 10) }
check(!kw("慢").hits.isEmpty, "全量那轮随后也建完了")
withSlow.removeAll { $0.key == "pdf:SLOW" }
sources = withSlow
_ = run { await idx.refresh(sources, budget: 10) }

print("— 6) 向量与合并排序")
/// 假模型：按字计数做向量（同字多 = 像），确定、离线。
struct FakeEmbedding: EmbeddingProvider {
    var modelID: String { "fake" }
    func vec(_ t: String) -> [Float] {
        var v = [Float](repeating: 0, count: 64)
        for s in t.unicodeScalars { v[Int(s.value % 64)] += 1 }
        return VectorMath.unit(v)
    }
    func embed(_ texts: [String]) async throws -> [(model: String, vector: [Float])] { texts.map { ("fake", vec($0)) } }
    func embedQuery(_ text: String) async throws -> [(model: String, vector: [Float])] { [("fake", vec(text))] }
}
let fake = FakeEmbedding()
_ = run { await idx.refresh(sources, budget: 30, embedder: fake) }
for _ in 0..<50 where run({ await idx.embedProgress.running }) { Thread.sleep(forTimeInterval: 0.1) }
let stats = run { await idx.stats }
check(run { await idx.vectorCount } == stats.chunks, "每块都有向量（\(stats.chunks) 块）")
let qv = run { try! await fake.embedQuery("对立统一规律") }
let sem = run { await idx.semantic(qv, filter: .init(), limit: 5) }
check(sem.first?.owner == "D1", "语义检索：最像的排第一")
let fused = SearchIndex.fuse(keyword: kw("对立统一").hits, semantic: sem, limit: 5)
check(fused.first?.owner == "D1" && Set(fused.map { "\($0.kind)|\($0.owner)|\($0.page ?? -1)|\($0.line ?? -1)" }).count == fused.count, "合并后不重复、两边都靠前的最靠前")
// 来源整批重建（习题改了一道）：正文没变的块留着向量，只有新正文要重算（不带模型刷新，看留下了几块）
let before = run { await idx.vectorCount }
if let i = sources.firstIndex(where: { $0.key == "ex:all" }) {
    sources[i] = SearchIndex.Source(key: "ex:all", title: "ex", stamp: { "2" }, load: {
        [SearchIndex.Chunk(kind: "exercise", owner: "E1", sub: "doc:D2", page: 3, title: "书D2 · 5", body: "下列关于矛盾普遍性的说法正确的是\nA. 矛盾无处不在"),
         SearchIndex.Chunk(kind: "exercise", owner: "E2", sub: "doc:D2", page: 4, title: "书D2 · 6", body: "新加的一道题")]
    })
}
_ = run { await idx.refresh(sources, budget: 10) }
check(run { await idx.vectorCount } == before, "重建来源后正文没变的块留着向量、新块没有（重建前 \(before)，后 \(run { await idx.vectorCount })）")
_ = run { await idx.refresh(sources, budget: 30, embedder: fake) }
for _ in 0..<50 where run({ await idx.embedProgress.running }) { Thread.sleep(forTimeInterval: 0.1) }
check(run { await idx.vectorCount } == before + 1, "接着只给新块算了向量")
// 关键词退回「任一词」时降权：只在关键词那边的排到只在向量那边的后面，两边都有的仍第一
func hit(_ o: String) -> SearchIndex.Hit {
    .init(chunkID: 0, kind: "exercise", owner: o, sub: "", page: nil, line: nil, title: "", heading: "", body: "", score: 0, docID: nil)
}
let kwOnly = [hit("A"), hit("B")], semOnly = [hit("C"), hit("A")]
check(SearchIndex.fuse(keyword: kwOnly, semantic: semOnly, limit: 3, keywordWeight: 0.5).map(\.owner) == ["A", "C", "B"],
      "关键词降权：两边都有的第一、只在向量那边的排在只在关键词那边的前面")
check(SearchIndex.fuse(keyword: kwOnly, semantic: semOnly, limit: 3).map(\.owner).first == "A", "不降权时两边都有的仍第一")

// 几个搜索同时来：都应等到建完、回「建完了」，不互相判成没建完
sources.append(SearchIndex.Source(key: "pdf:SLOW2", title: "慢书2", stamp: { "1" }, load: {
    Thread.sleep(forTimeInterval: 0.3); return [SearchIndex.Chunk(kind: "pdf", owner: "SLOW2", page: 0, title: "慢书2", body: "慢书二的内容")]
}))
let both = run { () -> [Bool] in
    async let a = idx.refresh(sources, budget: 10)
    async let b = idx.refresh(sources, budget: 10)
    async let c = idx.refresh(sources, budget: 10)
    return await [a, b, c]
}
check(both == [true, true, true], "三个同时来的刷新都回建完了（得到 \(both)）")

let row: [Int8] = [127, 0]
check(row.withUnsafeBufferPointer { VectorMath.dot([127, 0], $0) } == 127 * 127, "量化点积")

try? FileManager.default.removeItem(at: tmp)
print("\n\(fail == 0 ? "✅ 全部通过" : "❌ 有失败")：\(pass) 过 / \(fail) 败")
exit(fail == 0 ? 0 : 1)
