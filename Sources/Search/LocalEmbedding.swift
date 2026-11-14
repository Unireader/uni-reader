import CryptoKit
import Foundation
import MLX
import MLXEmbedders
import MLXLMCommon
import Tokenizers

/// 本机下载的嵌入模型（`SEARCH-PLAN.md §5.3 / §5.4`）：Qwen3-Embedding-0.6B 官方 bf16 权重，MLX 在 App 里直接跑。
/// 不打进 App 包，设置 › Agent › 搜索里点「下载」才下（1.2 GB），放 `~/Library/Application Support/UniReader/Models/`。
/// 只认钉死的那一版（提交号 + 每个文件的大小，权重与分词表另验 SHA-256），文件不全就当没装。
enum LocalEmbeddingModel {
    static let name = "Qwen3-Embedding-0.6B"
    static let repo = "Qwen/Qwen3-Embedding-0.6B"
    /// 2026-11-14 实测用的那一版。换版本 = 改这里 + 文件表，`modelID` 跟着变，旧向量自动作废重算。
    static let revision = "97b0c614be4d77ee51c0cef4e5f07c00f9eb65b3"

    struct File: Sendable { let path: String; let size: Int64; let sha256: String? }
    static let files: [File] = [
        File(path: "config.json", size: 727, sha256: nil),
        File(path: "1_Pooling/config.json", size: 313, sha256: nil),
        File(path: "tokenizer_config.json", size: 9706, sha256: nil),
        File(path: "vocab.json", size: 2_776_833, sha256: nil),
        File(path: "merges.txt", size: 1_671_853, sha256: nil),
        File(path: "tokenizer.json", size: 11_423_705, sha256: "def76fb086971c7867b829c23a26261e38d9d74e02139253b38aeb9df8b4b50a"),
        File(path: "model.safetensors", size: 1_191_586_416, sha256: "0437e45c94563b09e13cb7a64478fc406947a93cb34a7e05870fc8dcd48e23fd"),
    ]
    static var totalBytes: Int64 { files.reduce(0) { $0 + $1.size } }

    /// 下载地址：Hugging Face 本站，或国内能连上的镜像（用户的 Mac 连不上本站）。
    static let endpointKey = "searchModelEndpoint"
    static let endpoints = ["https://huggingface.co", "https://hf-mirror.com"]
    static var endpoint: String {
        let v = UserDefaults.standard.string(forKey: endpointKey) ?? ""
        return endpoints.contains(v) ? v : endpoints[0]
    }

    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support")
        return base.appendingPathComponent("UniReader/Models/\(name)", isDirectory: true)
    }

    /// 文件齐、大小对（SHA-256 只在下载完时验一次，验过才会留在这个目录里）。
    static var isInstalled: Bool {
        files.allSatisfy { f in
            let attrs = try? FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent(f.path).path)
            return (attrs?[.size] as? NSNumber)?.int64Value == f.size
        }
    }

    static func remove() throws {
        if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
    }
}

// MARK: - 下载

/// 设置页的下载按钮背后这一个。逐个文件下，断了能接着下（`.part` + HTTP Range），下完验大小与 SHA-256 再改名。
@MainActor
final class LocalModelDownloader: ObservableObject {
    static let shared = LocalModelDownloader()

    enum State: Equatable { case idle, downloading(done: Int64, total: Int64), verifying, failed(String) }
    @Published private(set) var state: State = .idle
    /// 装好 / 删掉都会变一下，设置页靠它重画「已下载」那行。
    @Published private(set) var installed = LocalEmbeddingModel.isInstalled

    private var task: Task<Void, Never>?

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            await self?.run()
            self?.task = nil
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        state = .idle
    }

    func delete() {
        cancel()
        Task { await LocalEmbedding.shared.unload() }
        do { try LocalEmbeddingModel.remove(); state = .idle } catch { state = .failed(error.localizedDescription) }
        installed = LocalEmbeddingModel.isInstalled
    }

    /// 用户自己把文件放进模型目录（别处下好的、搬过来的）后点「检查文件」：大小 + SHA-256 都对才算装好，不用再下载。
    func checkFolder() {
        guard task == nil else { return }
        task = Task { [weak self] in
            await self?.verifyExisting()
            self?.task = nil
        }
    }

    private func verifyExisting() async {
        let dir = LocalEmbeddingModel.directory
        state = .verifying
        let missing = LocalEmbeddingModel.files.filter { Self.size(dir.appendingPathComponent($0.path)) != $0.size }.map(\.path)
        guard missing.isEmpty else {
            installed = false
            state = .failed(String(format: L("These files are missing or have the wrong size: %@"), missing.joined(separator: ", ")))
            return
        }
        for f in LocalEmbeddingModel.files {
            guard let want = f.sha256 else { continue }
            let url = dir.appendingPathComponent(f.path)
            let got = try? await Task.detached { try Self.sha256(url) }.value
            guard got == want else {
                installed = false
                state = .failed(String(format: L("%@ does not match the expected checksum"), f.path))
                return
            }
        }
        state = .idle
        installed = true
        await MCPFacade.warmUpSearchIndexes()
    }

    /// 设置页出现时对一下磁盘（用户可能在 App 外面把文件放进去或删掉了）。只看大小，不算校验和。
    func refreshInstalled() {
        if task == nil { installed = LocalEmbeddingModel.isInstalled }
    }

    private func run() async {
        let dir = LocalEmbeddingModel.directory
        let total = LocalEmbeddingModel.totalBytes
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            var before: Int64 = 0
            for f in LocalEmbeddingModel.files {
                let dest = dir.appendingPathComponent(f.path)
                if Self.size(dest) == f.size { before += f.size; continue }
                try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                let part = dest.appendingPathExtension("part")
                let url = URL(string: "\(LocalEmbeddingModel.endpoint)/\(LocalEmbeddingModel.repo)/resolve/\(LocalEmbeddingModel.revision)/\(f.path)")!
                let base = before
                state = .downloading(done: base + max(0, Self.size(part)), total: total)
                try await RangeDownload.fetch(url, to: part, expected: f.size) { [weak self] got in
                    Task { @MainActor in
                        // 只增不减：这些更新各自排队上主线程，不保证按顺序到
                        if case .downloading(let done, _) = self?.state, base + got > done {
                            self?.state = .downloading(done: base + got, total: total)
                        }
                    }
                }
                try Task.checkCancellation()
                guard Self.size(part) == f.size else { throw EmbeddingError.http("\(f.path): size does not match") }
                if let want = f.sha256 {
                    state = .verifying
                    let got = try await Task.detached { try Self.sha256(part) }.value
                    guard got == want else {
                        try? FileManager.default.removeItem(at: part)
                        throw EmbeddingError.http("\(f.path): checksum does not match, please download again")
                    }
                }
                if FileManager.default.fileExists(atPath: dest.path) { try FileManager.default.removeItem(at: dest) }
                try FileManager.default.moveItem(at: part, to: dest)
                before += f.size
            }
            state = .idle
            installed = LocalEmbeddingModel.isInstalled
            await MCPFacade.warmUpSearchIndexes()   // 装好就在后台把向量算起来
        } catch is CancellationError {
            state = .idle
        } catch {
            if Task.isCancelled { state = .idle } else { state = .failed(error.localizedDescription) }
        }
    }

    nonisolated private static func size(_ url: URL) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? -1
    }

    nonisolated private static func sha256(_ url: URL) throws -> String {
        let h = try FileHandle(forReadingFrom: url)
        defer { try? h.close() }
        var hasher = SHA256()
        while let d = try h.read(upToCount: 8 << 20), !d.isEmpty { hasher.update(data: d) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// 一个文件的下载：`.part` 已有多少就从那里接着要（服务器回 206 才接，回 200 就从头写）。
private final class RangeDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private var handle: FileHandle?
    private var got: Int64 = 0
    private var lastReport = Date.distantPast
    private let progress: @Sendable (Int64) -> Void
    private var cont: CheckedContinuation<Void, Error>?
    private let part: URL
    private let offset: Int64

    private init(part: URL, offset: Int64, progress: @escaping @Sendable (Int64) -> Void) {
        self.part = part; self.offset = offset; self.progress = progress
    }

    static func fetch(_ url: URL, to part: URL, expected: Int64, progress: @escaping @Sendable (Int64) -> Void) async throws {
        var offset = ((try? FileManager.default.attributesOfItem(atPath: part.path))?[.size] as? NSNumber)?.int64Value ?? 0
        if offset >= expected { offset = 0; try? FileManager.default.removeItem(at: part) }
        let d = RangeDownload(part: part, offset: offset, progress: progress)
        let session = URLSession(configuration: .default, delegate: d, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        var req = URLRequest(url: url, timeoutInterval: 60)
        if offset > 0 { req.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range") }
        let t = session.dataTask(with: req)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                d.cont = c
                t.resume()
            }
        } onCancel: { t.cancel() }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 || code == 206 else {
            finish(EmbeddingError.http("download answered HTTP \(code)"))
            completionHandler(.cancel); return
        }
        do {
            if code == 200 || offset == 0 {
                FileManager.default.createFile(atPath: part.path, contents: nil)   // 从头写
                got = 0
            } else {
                got = offset
            }
            let h = try FileHandle(forWritingTo: part)
            if code == 200 { try h.truncate(atOffset: 0) } else { try h.seekToEnd() }
            handle = h
            completionHandler(.allow)
        } catch {
            finish(error); completionHandler(.cancel)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        do { try handle?.write(contentsOf: data) } catch { finish(error); dataTask.cancel(); return }
        got += Int64(data.count)
        // 每 0.2 秒最多报一次：每块数据都报的话界面一秒刷几百次，进度条与文字会闪
        let now = Date()
        if now.timeIntervalSince(lastReport) >= 0.2 { lastReport = now; progress(got) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let e = error as? URLError, e.code == .cancelled { finish(CancellationError()) } else { finish(error) }
    }

    private func finish(_ error: Error?) {
        try? handle?.close(); handle = nil
        guard let c = cont else { return }
        cont = nil
        if let error { c.resume(throwing: error) } else { c.resume() }
    }
}

// MARK: - 推理

/// 本机模型（`EmbeddingProvider`）。所有调用串在这个 actor 里；模型用到时才加载，闲置一段时间卸掉（省 1.2 GB 内存）；
/// 闲置分钟数与「常驻内存」在设置 › Agent › 搜索（`SemanticSearchSettings`）。
actor LocalEmbedding: EmbeddingProvider {
    static let shared = LocalEmbedding()

    nonisolated var modelID: String { "local|\(LocalEmbeddingModel.name)@\(LocalEmbeddingModel.revision.prefix(8))" }

    /// 一次喂给模型的段数、每段最多几个 token（块一般不到 600 个 token）。
    private static let batch = 16, maxTokens = 1024
    /// Qwen3-Embedding 的查询要带任务说明（模型自带 config_sentence_transformers.json 里的那句），正文不带。
    private static let queryPrefix = "Instruct: Given a web search query, retrieve relevant passages that answer the query\nQuery:"

    private var container: EmbedderModelContainer?
    private var idleUnload: Task<Void, Never>?

    private func model() async throws -> EmbedderModelContainer {
        if let container { return container }
        guard LocalEmbeddingModel.isInstalled else {
            throw EmbeddingError.unavailable("the search model has not been downloaded (UniReader Settings › Agent › Search)")
        }
        // 🔴 MLX 默认把用过的显存全留着复用：不设上限，算一遍书库能涨到 27 GB（§5.3）
        Memory.cacheLimit = 512 << 20
        let c = try await EmbedderModelFactory.shared.loadContainer(from: LocalEmbeddingModel.directory, using: TokenizerLoaderBridge())
        container = c
        return c
    }

    /// 正在算的调用数：算着的时候不卸（actor 在 await 处可重入，别的调用的计时器可能到点）。
    private var busy = 0

    var isLoaded: Bool { container != nil }

    func unload() {
        idleUnload?.cancel()
        idleUnload = nil
        container = nil
        Memory.clearCache()
    }

    /// 重新按设置排闲置卸载：常驻开着 / 没加载 / 正在算 → 不排；否则闲置满设定分钟数卸掉。
    /// 每次算完调一次；设置页改了「常驻」或分钟数也调（`settingsChanged`）。
    private func touch() {
        idleUnload?.cancel()
        idleUnload = nil
        guard container != nil, busy == 0, !SemanticSearchSettings.keepModelLoaded else { return }
        let seconds = SemanticSearchSettings.modelIdleMinutes * 60
        idleUnload = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            await self?.idleExpired()
        }
    }

    private func idleExpired() {
        guard busy == 0, !SemanticSearchSettings.keepModelLoaded else { return }
        unload()
    }

    /// 设置页改了常驻 / 闲置分钟数：按新设置重排计时（关掉常驻 = 从现在起闲置计时）。
    func settingsChanged() { touch() }

    private func begin() async throws -> EmbedderModelContainer {
        busy += 1
        idleUnload?.cancel()
        idleUnload = nil
        do { return try await model() } catch { end(); throw error }
    }

    private func end() {
        busy -= 1
        touch()
    }

    func embed(_ texts: [String]) async throws -> [(model: String, vector: [Float])] {
        guard !texts.isEmpty else { return [] }
        let c = try await begin()
        defer { end() }
        // 按长度排好再分批，补齐浪费最少；算完按原顺序放回
        let order = texts.indices.sorted { texts[$0].count < texts[$1].count }
        var out = [[Float]](repeating: [], count: texts.count)
        for start in stride(from: 0, to: order.count, by: Self.batch) {
            try Task.checkCancellation()
            let idx = Array(order[start..<min(start + Self.batch, order.count)])
            let vs = await Self.run(c, idx.map { texts[$0] })
            for (k, i) in idx.enumerated() { out[i] = vs[k] }
        }
        let id = modelID
        return out.map { (id, $0) }
    }

    func embedQuery(_ text: String) async throws -> [(model: String, vector: [Float])] {
        let c = try await begin()
        defer { end() }
        return [(modelID, (await Self.run(c, [Self.queryPrefix + text]))[0])]
    }

    /// 一批 → 单位向量：末尾必须是 `<|endoftext|>`、取最后一个 token；右侧补齐，掩码按真实长度给。
    private static func run(_ c: EmbedderModelContainer, _ texts: [String]) async -> [[Float]] {
        let maxTokens = Self.maxTokens
        return await c.perform { ctx in
            let tok = ctx.tokenizer
            let eos = tok.convertTokenToId("<|endoftext|>") ?? 151643
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
                flat += s.map { Int32($0) } + Array(repeating: Int32(eos), count: L - s.count)
                mask += Array(repeating: 1, count: s.count) + Array(repeating: 0, count: L - s.count)
            }
            let ids = MLXArray(flat, [B, L]), m = MLXArray(mask, [B, L])
            let out = ctx.model(ids, positionIds: nil, tokenTypeIds: nil, attentionMask: m)
            let pooled = Pooling(strategy: .last)(out, mask: m, normalize: true, applyLayerNorm: false)
            pooled.eval()
            return (0..<B).map { pooled[$0].asArray(Float.self) }
        }
    }
}

/// swift-transformers 的分词器接到 MLXLMCommon 的协议上（照 mlx-swift-lm `MLXHuggingFace` 宏展开的写法；不用那个宏是为了不带 swift-huggingface 下载器）。
private struct TokenizerLoaderBridge: MLXLMCommon.TokenizerLoader {
    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        Bridge(upstream: try await Tokenizers.AutoTokenizer.from(modelFolder: directory))
    }

    struct Bridge: MLXLMCommon.Tokenizer {
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
}
