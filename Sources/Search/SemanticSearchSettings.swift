import Foundation

/// 语义搜索的设置（设置 › Agent › 搜索，`SEARCH-PLAN.md §7`）。单独一个文件：`Embedding.swift` 不碰 MLX，
/// `spike/search-test.swift` 直接编它。
enum SemanticSearchSettings {
    static let enabledKey = "searchSemanticEnabled"
    static let providerKey = "searchEmbeddingProvider"   // "local" / "openai"（老的 "system" 当 "local"）
    static let urlKey = "searchEmbeddingURL"
    static let modelKey = "searchEmbeddingModel"
    static let keychainAccount = "searchEmbeddingKey"
    static let defaultURL = "https://api.siliconflow.cn/v1"
    static let defaultModel = "BAAI/bge-m3"

    /// 本机模型常驻内存（不按闲置卸载）；默认关。
    static let keepModelLoadedKey = "searchModelKeepLoaded"
    /// 本机模型闲置多少分钟卸掉（常驻关着时用）；没设 = 2 分钟。
    static let modelIdleMinutesKey = "searchModelIdleMinutes"
    static let defaultIdleMinutes = 2
    static let idleMinuteChoices = [1, 2, 5, 10, 30, 60]

    static var enabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }
    static var keepModelLoaded: Bool { UserDefaults.standard.bool(forKey: keepModelLoadedKey) }
    static var modelIdleMinutes: Int {
        let m = UserDefaults.standard.integer(forKey: modelIdleMinutesKey)
        return m > 0 ? m : defaultIdleMinutes
    }
    static var providerName: String { UserDefaults.standard.string(forKey: providerKey) == "openai" ? "openai" : "local" }

    /// 开着却用不了的原因（本机模型还没下载）；能用 / 关着 = nil。MCP 回话与设置页说明用。
    static var unavailableReason: String? {
        guard enabled, providerName == "local", !LocalEmbeddingModel.isInstalled else { return nil }
        return "the search model has not been downloaded yet (UniReader Settings › Agent › Search)"
    }

    /// 当前设置对应的模型；关着 / 没配好（本机模型没下载）= nil。
    static func current() -> EmbeddingProvider? {
        guard enabled else { return nil }
        if providerName == "openai" {
            let d = UserDefaults.standard
            let url = (d.string(forKey: urlKey)?.trimmingCharacters(in: .whitespaces)).flatMap { $0.isEmpty ? nil : $0 } ?? defaultURL
            let model = (d.string(forKey: modelKey)?.trimmingCharacters(in: .whitespaces)).flatMap { $0.isEmpty ? nil : $0 } ?? defaultModel
            return OpenAIEmbedding(baseURL: url, model: model, apiKey: Keychain.read(keychainAccount) ?? "")
        }
        return LocalEmbeddingModel.isInstalled ? LocalEmbedding.shared : nil
    }
}
