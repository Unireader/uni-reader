// 用法：EmbedBench <SearchIndex/*.sqlite> <模型目录> <qwen3|bge> [--batch 16] [--max-tokens 1024] [--show]
// 块的向量缓存在 <模型目录>/../cache-<模型目录名>.bin，第二次运行直接读缓存、只算问题。
import Foundation
import MLX
import MLXEmbedders
import MLXLMCommon
import SQLite3
import Tokenizers

// MARK: 参数

let args = CommandLine.arguments
guard args.count >= 4, ["qwen3", "bge"].contains(args[3]) else {
    print("用法：EmbedBench <索引.sqlite> <模型目录> <qwen3|bge> [--batch 16] [--max-tokens 1024] [--show]"); exit(1)
}
func opt(_ name: String, _ def: Int) -> Int {
    if let i = args.firstIndex(of: name), i + 1 < args.count, let v = Int(args[i + 1]) { return v }
    return def
}
let indexPath = args[1]
let modelDir = URL(fileURLWithPath: args[2]).standardizedFileURL
let isQwen = args[3] == "qwen3"
let batchSize = opt("--batch", 16), maxTokens = opt("--max-tokens", 1024)
let show = args.contains("--show")
/// MLX 默认把用过的显存全留着复用（不设上限能涨到几十 GB）；--cache-mb 给上限，0 = 不留
let cacheMB = opt("--cache-mb", 512)
if cacheMB >= 0 { Memory.cacheLimit = cacheMB * 1_048_576 }
let cacheURL = modelDir.deletingLastPathComponent().appendingPathComponent("cache-\(modelDir.lastPathComponent)-\(maxTokens).bin")

// MARK: 内存（进程物理占用，含 Metal 缓冲）

func footprintMB() -> Double {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
    }
    return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : 0
}
var peakMB = 0.0
func notePeak() { peakMB = max(peakMB, footprintMB()) }

// MARK: 读块

struct Chunk { let id: Int64; let kind: String; let body: String; let norm: String }
var chunks: [Chunk] = []
do {
    var db: OpaquePointer?
    guard sqlite3_open_v2(indexPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { fatalError("打不开 \(indexPath)") }
    var st: OpaquePointer?
    sqlite3_prepare_v2(db, "SELECT id, kind, body, norm FROM chunk ORDER BY id", -1, &st, nil)
    while sqlite3_step(st) == SQLITE_ROW {
        chunks.append(Chunk(id: sqlite3_column_int64(st, 0), kind: String(cString: sqlite3_column_text(st, 1)),
                            body: String(cString: sqlite3_column_text(st, 2)), norm: String(cString: sqlite3_column_text(st, 3))))
    }
    sqlite3_finalize(st); sqlite3_close(db)
}
print("块数：\(chunks.count)　模型：\(modelDir.lastPathComponent)　batch \(batchSize)　每段最多 \(maxTokens) 个 token　MLX 缓存上限 \(cacheMB) MB")

// MARK: 分词器（swift-transformers → MLXLMCommon 协议，照 MLXHuggingFace 宏展开的写法）

struct TokenizerBridge: MLXLMCommon.Tokenizer {
    let upstream: any Tokenizers.Tokenizer
    func encode(text: String, addSpecialTokens: Bool) -> [Int] { upstream.encode(text: text, addSpecialTokens: addSpecialTokens) }
    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String { upstream.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens) }
    func convertTokenToId(_ token: String) -> Int? { upstream.convertTokenToId(token) }
    func convertIdToToken(_ id: Int) -> String? { upstream.convertIdToToken(id) }
    var bosToken: String? { upstream.bosToken }
    var eosToken: String? { upstream.eosToken }
    var unknownToken: String? { upstream.unknownToken }
    func applyChatTemplate(messages: [[String: any Sendable]], tools: [[String: any Sendable]]?,
                           additionalContext: [String: any Sendable]?) throws -> [Int] {
        throw MLXLMCommon.TokenizerError.missingChatTemplate
    }
}
struct BridgeLoader: MLXLMCommon.TokenizerLoader {
    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        TokenizerBridge(upstream: try await Tokenizers.AutoTokenizer.from(modelFolder: directory))
    }
}

// MARK: 模型

var t0 = Date()
let container = try await EmbedderModelFactory.shared.loadContainer(from: modelDir, using: BridgeLoader())
let loadSec = Date().timeIntervalSince(t0)
notePeak()
print(String(format: "加载 %.1f 秒，占用 %.0f MB", loadSec, footprintMB()))

/// 一批文字 → 单位向量。qwen3：末尾必须是 <|endoftext|>，取最后一个 token；bge：<s>…</s>，取第一个 token（CLS，不过 pooler）。
/// 右侧补齐，掩码按真实长度给。
func embed(_ texts: [String]) async -> [[Float]] {
    let isQwen = isQwen, maxTokens = maxTokens
    return await container.perform { ctx in
        let tok = ctx.tokenizer
        let eos = isQwen ? (tok.convertTokenToId("<|endoftext|>") ?? 151643) : 2
        let pad = isQwen ? eos : 1
        let seqs: [[Int]] = texts.map { t in
            var ids = tok.encode(text: t, addSpecialTokens: true)
            if ids.last == eos { ids.removeLast() }
            if ids.count > maxTokens - 1 { ids = Array(ids.prefix(maxTokens - 1)) }
            ids.append(eos)
            return ids
        }
        let L = seqs.map(\.count).max() ?? 1, B = seqs.count
        var flat = [Int32](), mask = [Int32]()
        flat.reserveCapacity(B * L); mask.reserveCapacity(B * L)
        for s in seqs {
            flat += s.map { Int32($0) } + Array(repeating: Int32(pad), count: L - s.count)
            mask += Array(repeating: 1, count: s.count) + Array(repeating: 0, count: L - s.count)
        }
        let ids = MLXArray(flat, [B, L])
        let m = MLXArray(mask, [B, L])
        // 试过 qwen3 不给掩码（因果 + 右侧补齐，真实 token 本来看不到补齐位）想走融合注意力：
        // 2026-11-14 实测 309 秒 vs 305 秒、结果一样，没快，照常给。
        let out = ctx.model(ids, positionIds: nil, tokenTypeIds: MLXArray.zeros(like: ids), attentionMask: m)
        let pooled = Pooling(strategy: isQwen ? .last : .first)(out, mask: m, normalize: true, applyLayerNorm: false)
        pooled.eval()
        return (0..<B).map { pooled[$0].asArray(Float.self) }
    }
}

// MARK: 块向量（有缓存读缓存）

var dim = 0
var docVecs: [[Float]] = []
/// --stored：不自己算，直接用 App 存进索引库的向量（Int8 量化，`vec.model` 以 local| 开头），查询也照 App 量化——验证 App 里的结果
let stored = args.contains("--stored")
if stored {
    var db: OpaquePointer?
    sqlite3_open_v2(indexPath, &db, SQLITE_OPEN_READONLY, nil)
    var st: OpaquePointer?
    sqlite3_prepare_v2(db, "SELECT chunk_id, v FROM vec WHERE model LIKE 'local|%'", -1, &st, nil)
    var byID: [Int64: [Float]] = [:]
    while sqlite3_step(st) == SQLITE_ROW {
        let n = Int(sqlite3_column_bytes(st, 1))
        let p = sqlite3_column_blob(st, 1)!.assumingMemoryBound(to: Int8.self)
        byID[sqlite3_column_int64(st, 0)] = UnsafeBufferPointer(start: p, count: n).map { Float($0) / 127 }
    }
    sqlite3_finalize(st); sqlite3_close(db)
    dim = byID.first?.value.count ?? 0
    docVecs = chunks.map { byID[$0.id] ?? [Float](repeating: 0, count: dim) }
    print("用 App 存的向量：\(byID.count)/\(chunks.count) 块有向量")
}
if let data = try? Data(contentsOf: cacheURL), data.count > 8 {
    let n = data.withUnsafeBytes { Int($0.load(fromByteOffset: 0, as: Int32.self)) }
    dim = data.withUnsafeBytes { Int($0.load(fromByteOffset: 4, as: Int32.self)) }
    if n == chunks.count {
        data.withUnsafeBytes { raw in
            let f = raw.baseAddress!.advanced(by: 8).assumingMemoryBound(to: Float.self)
            docVecs = (0..<n).map { Array(UnsafeBufferPointer(start: f + $0 * dim, count: dim)) }
        }
        print("块向量读缓存：\(cacheURL.lastPathComponent)")
    }
}
if docVecs.isEmpty {
    // 按长度排序再分批，补齐的浪费最少；算完按原顺序放回
    let order = chunks.indices.sorted { chunks[$0].body.count < chunks[$1].body.count }
    var out = [[Float]](repeating: [], count: chunks.count)
    t0 = Date()
    var done = 0
    for start in stride(from: 0, to: order.count, by: batchSize) {
        let idx = Array(order[start..<min(start + batchSize, order.count)])
        let vs = await embed(idx.map { chunks[$0].body })
        for (k, i) in idx.enumerated() { out[i] = vs[k] }
        done += idx.count
        notePeak()
        if done % 512 < batchSize || done == order.count {
            let el = Date().timeIntervalSince(t0)
            print(String(format: "  %d/%d　%.0f 秒　%.1f 块/秒　占用 %.0f MB（MLX 在用 %.0f / 峰值 %.0f / 缓存 %.0f MB）", done, order.count, el, Double(done) / el, footprintMB(),
                         Double(Memory.activeMemory) / 1_048_576, Double(Memory.peakMemory) / 1_048_576, Double(Memory.cacheMemory) / 1_048_576))
        }
    }
    let el = Date().timeIntervalSince(t0)
    print(String(format: "块向量算完：%.0f 秒，平均 %.1f 块/秒，峰值占用 %.0f MB", el, Double(chunks.count) / el, peakMB))
    docVecs = out
    dim = out.first?.count ?? 0
    var data = Data()
    var n32 = Int32(chunks.count), d32 = Int32(dim)
    data.append(Data(bytes: &n32, count: 4)); data.append(Data(bytes: &d32, count: 4))
    for v in out { v.withUnsafeBufferPointer { data.append(Data(buffer: $0)) } }
    try? data.write(to: cacheURL)
}
print("向量维度：\(dim)")

// MARK: 评估（问题与判定照 spike/semantic-eval.swift）

/// Qwen3-Embedding 的查询要带任务说明（模型自带 config_sentence_transformers.json 里的那句），正文不带。
func queryText(_ q: String) -> String {
    isQwen ? "Instruct: Given a web search query, retrieve relevant passages that answer the query\nQuery:\(q)" : q
}

func run(_ name: String, _ set: [(String, [String])]) async {
    var hit = 0, top1 = 0, rr = 0.0, qTime = 0.0
    print("\n==== \(name)（\(set.count) 问）====")
    for (q, terms) in set {
        let rel = Set(chunks.indices.filter { i in terms.contains { chunks[i].norm.contains($0) } })
        let t = Date()
        var qv = (await embed([queryText(q)]))[0]
        if stored { qv = qv.map { max(-127, min(127, ($0 * 127).rounded())) / 127 } }
        qTime += Date().timeIntervalSince(t)
        let top = docVecs.indices.map { i -> (Int, Float) in
            var s: Float = 0; let v = docVecs[i]
            for d in 0..<dim { s += v[d] * qv[d] }
            return (i, s)
        }.sorted { $0.1 > $1.1 }.prefix(10).map(\.0)
        let r = top.firstIndex { rel.contains($0) }
        if r != nil { hit += 1 }; if r == 0 { top1 += 1 }
        rr += r.map { 1.0 / Double($0 + 1) } ?? 0
        print("\(r.map { "第\($0 + 1)" } ?? "  ✗ ")　\(q)")
        if show {
            for i in top.prefix(3) {
                print("      \(rel.contains(i) ? "✓" : "·") [\(chunks[i].kind)] \(chunks[i].body.replacingOccurrences(of: "\n", with: " ").prefix(60))")
            }
        }
    }
    print(String(format: "前10命中 %d/%d，首位 %d/%d，MRR@10 %.2f，每问编码 %.0f ms",
                 hit, set.count, top1, set.count, rr / Double(set.count), qTime / Double(set.count) * 1000))
}

await run("换说法", paraphrased)
await run("字面相同", literal)
notePeak()
print(String(format: "\n全程峰值占用 %.0f MB", peakMB))
