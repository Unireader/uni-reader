import Foundation
import NaturalLanguage

/// 语义搜索用的向量模型（`SEARCH-PLAN.md §5`）。两种，设置 › Agent › 语义搜索里选：
///
/// - **本机**（`SystemEmbedding`）：系统自带的 `NLContextualEmbedding`（BERT 类，按字取向量再取平均），离线、不花钱。
///   中日韩一个模型、拉丁文字一个模型，各自的向量只和同一个模型的比。实测（2026-11-12，考研政治 / 数学 10 段 × 12 句换说法的问题）：
///   首位命中 4/12，只比纯关键词（2/12）好一点——**能用，但别指望**；所以默认关着，搜索一律关键词与语义合并排序，不单靠它。
/// - **OpenAI 兼容接口**（`OpenAIEmbedding`）：`POST <地址>/embeddings`，如 SiliconFlow 的 `BAAI/bge-m3`、本机 Ollama。
///   中文效果好得多；🔴 代价是**笔记、PDF 文字会发给那个服务**，设置里写明。
protocol EmbeddingProvider: Sendable {
    /// 写进 `vec.model` 的身份：换了模型，旧向量全部作废重算。
    var modelID: String { get }
    /// 同一批文字的向量（单位长度）。`forQuery` = 这是查询（有的模型查询与正文用法不同，这里两种都一样）。
    /// 返回 `(模型身份, 向量)`：本机那种中日韩 / 拉丁两个模型，一段文字用哪个由文字自己决定。
    func embed(_ texts: [String]) async throws -> [(model: String, vector: [Float])]
    /// 查询要用哪些模型各算一遍（本机那种两个都算，和各自模型的向量比）。
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

// MARK: - 设置

enum SemanticSearchSettings {
    static let enabledKey = "searchSemanticEnabled"
    static let providerKey = "searchEmbeddingProvider"   // "system" / "openai"
    static let urlKey = "searchEmbeddingURL"
    static let modelKey = "searchEmbeddingModel"
    static let keychainAccount = "searchEmbeddingKey"
    static let defaultURL = "https://api.siliconflow.cn/v1"
    static let defaultModel = "BAAI/bge-m3"

    static var enabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }
    static var providerName: String { UserDefaults.standard.string(forKey: providerKey) ?? "system" }

    /// 当前设置对应的模型；关着 / 没配好 = nil。
    static func current() -> EmbeddingProvider? {
        guard enabled else { return nil }
        if providerName == "openai" {
            let d = UserDefaults.standard
            let url = (d.string(forKey: urlKey)?.trimmingCharacters(in: .whitespaces)).flatMap { $0.isEmpty ? nil : $0 } ?? defaultURL
            let model = (d.string(forKey: modelKey)?.trimmingCharacters(in: .whitespaces)).flatMap { $0.isEmpty ? nil : $0 } ?? defaultModel
            return OpenAIEmbedding(baseURL: url, model: model, apiKey: Keychain.read(keychainAccount) ?? "")
        }
        return SystemEmbedding.shared
    }
}

// MARK: - 本机

/// 系统自带模型。`NLContextualEmbedding` 不保证线程安全：所有调用串在一个 actor 里。
actor SystemEmbedding: EmbeddingProvider {
    static let shared = SystemEmbedding()

    nonisolated var modelID: String { "system" }
    static let cjkID = "system-cjk", latinID = "system-latn"

    private var cjk: NLContextualEmbedding?
    private var latin: NLContextualEmbedding?

    private func model(_ id: String) throws -> NLContextualEmbedding {
        if id == Self.cjkID, let cjk { return cjk }
        if id == Self.latinID, let latin { return latin }
        guard let m = NLContextualEmbedding(language: id == Self.cjkID ? .simplifiedChinese : .english) else {
            throw EmbeddingError.unavailable("the on-device text model is not available on this Mac")
        }
        if !m.hasAvailableAssets {
            throw EmbeddingError.unavailable("the on-device text model has not been downloaded by macOS yet; try again later")
        }
        try m.load()
        if id == Self.cjkID { cjk = m } else { latin = m }
        return m
    }

    /// 一段文字用哪个模型：含中日韩文字的用中日韩那个。
    static func modelFor(_ text: String) -> String {
        text.unicodeScalars.contains { $0.value >= 0x2E80 && $0.value <= 0x9FFF || ($0.value >= 0xAC00 && $0.value <= 0xD7AF) }
            ? cjkID : latinID
    }

    private func vector(_ text: String, model id: String) throws -> [Float] {
        let m = try model(id)
        let lang: NLLanguage = id == Self.cjkID ? .simplifiedChinese : .english
        let r = try m.embeddingResult(for: text, language: lang)
        var sum = [Double](repeating: 0, count: m.dimension)
        var n = 0.0
        r.enumerateTokenVectors(in: text.startIndex..<text.endIndex) { v, _ in
            for i in 0..<min(v.count, sum.count) { sum[i] += v[i] }
            n += 1
            return true
        }
        return VectorMath.unit(sum.map { Float($0 / max(n, 1)) })
    }

    func embed(_ texts: [String]) async throws -> [(model: String, vector: [Float])] {
        try texts.map { t in
            let id = Self.modelFor(t)
            return (id, try vector(t, model: id))
        }
    }

    func embedQuery(_ text: String) async throws -> [(model: String, vector: [Float])] {
        var out: [(String, [Float])] = []
        for id in [Self.cjkID, Self.latinID] {
            if let v = try? vector(text, model: id) { out.append((id, v)) }
        }
        guard !out.isEmpty else { throw EmbeddingError.unavailable("the on-device text model could not embed the query") }
        return out
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
