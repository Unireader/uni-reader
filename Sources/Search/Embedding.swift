import Foundation

/// 语义搜索用的向量模型（`SEARCH-PLAN.md §5`）。两种，设置 › Agent › 搜索里选：
///
/// - **本机**（`LocalEmbedding`，`LocalEmbedding.swift`）：Qwen3-Embedding-0.6B，MLX 在 App 里跑，模型在设置里点下载（1.2 GB）。离线、不花钱，
///   真实书库上首位命中是关键词的将近两倍（§5.3）。原来的系统自带模型（`NLContextualEmbedding`）2026-11-14 去掉了：只比随机好一倍、远不如关键词。
/// - **OpenAI 兼容接口**（`OpenAIEmbedding`）：`POST <地址>/embeddings`，如 SiliconFlow 的 `BAAI/bge-m3`、本机 Ollama。
///   🔴 代价是**笔记、PDF 文字会发给那个服务**，设置里写明。
protocol EmbeddingProvider: Sendable {
    /// 写进 `vec.model` 的身份：换了模型，旧向量全部作废重算。
    var modelID: String { get }
    /// 同一批文字（正文）的向量（单位长度），返回 `(模型身份, 向量)`，按输入顺序。
    func embed(_ texts: [String]) async throws -> [(model: String, vector: [Float])]
    /// 查询的向量（本机模型查询要带任务说明，与正文用法不同）。
    func embedQuery(_ text: String) async throws -> [(model: String, vector: [Float])]
}

enum EmbeddingError: LocalizedError {
    case unavailable(String), http(String)
    var errorDescription: String? {
        switch self {
        case .unavailable(let m): return m
        case .http(let m): return m
        }
    }
}

// MARK: - OpenAI 兼容接口

struct OpenAIEmbedding: EmbeddingProvider {
    let baseURL: String
    let model: String
    let apiKey: String

    var modelID: String { "openai|\(baseURL)|\(model)" }

    func embed(_ texts: [String]) async throws -> [(model: String, vector: [Float])] {
        guard !texts.isEmpty else { return [] }
        var base = baseURL.trimmingCharacters(in: .whitespaces)
        while base.hasSuffix("/") { base.removeLast() }
        guard let url = URL(string: base + "/embeddings") else { throw EmbeddingError.http("bad embeddings address: \(baseURL)") }
        var req = URLRequest(url: url, timeoutInterval: 60)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !apiKey.isEmpty { req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        req.httpBody = try JSONSerialization.data(withJSONObject: ["model": model, "input": texts])
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else {
            let msg = String(data: data.prefix(300), encoding: .utf8) ?? ""
            throw EmbeddingError.http("embeddings service answered HTTP \(code): \(msg)")
        }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = obj["data"] as? [[String: Any]] else {
            throw EmbeddingError.http("embeddings service gave an unexpected answer")
        }
        var out = [[Float]](repeating: [], count: texts.count)
        for (k, it) in items.enumerated() {
            let i = (it["index"] as? Int) ?? k
            guard out.indices.contains(i), let v = it["embedding"] as? [NSNumber] else { continue }
            out[i] = VectorMath.unit(v.map { $0.floatValue })
        }
        guard !out.contains(where: { $0.isEmpty }) else { throw EmbeddingError.http("embeddings service skipped some texts") }
        return out.map { (modelID, $0) }
    }

    func embedQuery(_ text: String) async throws -> [(model: String, vector: [Float])] { try await embed([text]) }
}

// MARK: - 向量运算

enum VectorMath {
    static func unit(_ v: [Float]) -> [Float] {
        var s: Float = 0
        for x in v { s += x * x }
        let n = s.squareRoot()
        return n > 0 ? v.map { $0 / n } : v
    }

    /// 存盘：单位向量量化成 Int8（×127），一维一个字节——向量占的地方是 Float32 的四分之一，排序几乎不受影响。
    static func quantize(_ v: [Float]) -> Data {
        Data(v.map { UInt8(bitPattern: Int8(max(-127, min(127, ($0 * 127).rounded())))) })
    }

    /// 点积（两边都是量化过的单位向量 → 余弦 × 127²）。
    static func dot(_ a: [Int8], _ b: UnsafeBufferPointer<Int8>) -> Int32 {
        var s: Int32 = 0
        for i in 0..<min(a.count, b.count) { s &+= Int32(a[i]) * Int32(b[i]) }
        return s
    }
}
