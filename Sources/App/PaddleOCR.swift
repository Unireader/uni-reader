import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// PP-OCRv6 异步 job 客户端（逐页图片提交）。两个后端共用这一套：
/// · **Paddle 云 API**（`cloudConfig(apiKey:)`，要 API key）
/// · **本机 OCR 服务**（`LocalOCR.config()`，免 key，接口与云端一致，见该仓库 `docs/API.md`）
///
/// 流程：`POST .../api/v2/ocr/jobs`(multipart 上传页图) → 轮询 `GET .../{jobId}` 到 `done` → 下 JSONL。
/// PP-OCRv6 的结果里逐行文本在 `result.ocrResults[].prunedResult.rec_texts`、行框在 `rec_boxes`
/// （输入图**像素坐标、左上原点**）——正好和页图（`PageBitmap.render` 出的显示朝向图，top-origin）同坐标系，
/// 直接按图宽高归一化成 `TextRun`（0~1 左上原点），无需 rotation 变换。
///
/// 提交时带 `returnWordBox: true`（**云端文档没列这个字段，2026-09-03 实测云端认**），结果多出
/// `text_word` + `text_word_boxes` 两列单字框——`TextRun.chars` 就是它换算来的，文字选择靠它才不切半个字。
/// 引擎选择存 UserDefaults（取值归 `OCRBackend`）；云端 API key 存 **Keychain**（本机密钥，不进工作区共享文件夹、不落 plist 明文）。
enum PaddleOCR {
    static let cloudJobURL = "https://paddleocr.aistudio-app.com/api/v2/ocr/jobs"
    static let model = "PP-OCRv6"
    /// ⚠️ 缓存键的一部分（`ocr_page.provider`）。**改了它 = 旧 OCR 缓存全部失效、按需重跑**。
    /// `-w` 这一版起 payload 里带单字框（`TextRun.chars`）；老缓存没有，靠 bump 让它重跑一遍，
    /// 免得同一本书一半行能精确选、一半行还在按权重猜（旧行还留在表里，不占逻辑、只占点空间）。
    static let providerID = "paddle-ppocrv6-w"

    /// UserDefaults 键（引擎选择；与 `SettingsView` / `OCRBackend` 共用）。
    static let engineKey = "ocrEngine"        // "off" | "paddle" | "local"
    /// API key 的 Keychain account；同时也是 UserDefaults 里的**旧**键（仅迁移用，见 `apiKey()`）。
    static let apiKeyKey = "ocrPaddleKey"

    /// 一个后端的全部差异。构造只有两处：`cloudConfig(apiKey:)`（云端）与 `LocalOCR.config()`
    /// （本机服务）；下面的请求代码只认这个结构，不再各自比引擎字符串。
    struct Config {
        /// 提交任务的 jobs 接口（两边路径相同，只差主机与端口）。
        var endpoint: URL
        /// 云端的 API key；本机服务不校验，空串 = 连 `Authorization` 头都不发。
        var apiKey: String
        /// 缓存键（`ocr_page.provider`）：两个引擎识别结果不同，各存各的。
        var providerID: String
        /// 随提交一起发的 `optionalPayload`（JSON 字符串）。
        var optionalPayload: String
        /// **单个请求**的超时（提交、查询、下载各自一次往返）。两个后端提交都只是入队，不等识别完。
        var requestTimeout: TimeInterval
        /// 轮询任务状态的间隔。本机识别一页几百毫秒，查得勤一点更跟手；云端排队慢，2.5 秒够了。
        var pollInterval: TimeInterval
        /// 等一个任务到 `done` 的**总**预算（`docs/API.md` §6.4：本机第一个任务含模型加载，要放宽）。
        var pollBudget: TimeInterval
        /// true = 结果地址取响应里的 `resultUrl.jsonUrl`（云端是**带签名的临时地址**，只能照它取）；
        /// false = 忽略响应里的地址，按固定路径 `.../{jobId}/result.jsonl` 从 `endpoint` 拼——
        /// 本机服务回的绝对地址是它自己监听的那个，用户改过 host/端口就指不回去。
        var followServerResultURL: Bool
        /// 连不上时补的一句办法（本机服务 = 怎么把它启动起来；云端留空）。
        var unreachableHint: String
    }

    enum OCRError: LocalizedError {
        case notConfigured, encodeFailed, http(Int, String?), badResponse, jobFailed(String), timeout
        case unreachable(String, String)
        var errorDescription: String? {
            switch self {
            case .notConfigured: return "OCR 未配置（设置里选引擎；选云端还要填 key）"
            case .encodeFailed:  return "页图编码失败"
            case .http(let c, let detail):
                guard let detail, !detail.isEmpty else { return "HTTP \(c)" }
                return "HTTP \(c)：\(detail)"
            case .badResponse:   return "响应格式异常"
            case .jobFailed(let m): return "识别失败：\(m)"
            case .timeout:       return "识别超时"
            case .unreachable(let why, let hint):
                // 系统的失败原因常自带句号（还是英文的），去掉再接中文那句，免得出现「.。」。
                var reason = why.trimmingCharacters(in: .whitespacesAndNewlines)
                while let last = reason.last, last == "." || last == "。" { reason.removeLast() }
                return hint.isEmpty ? "连不上 OCR 服务：\(reason)" : "连不上 OCR 服务：\(reason)。\(hint)"
            }
        }
    }

    /// 云端那一套配置（本机服务的对应物见 `LocalOCR.config()`）。
    /// key 为空 = 没配好，调用方（`OCRBackend`）负责判。
    static func cloudConfig(apiKey: String) -> Config {
        Config(
            endpoint: URL(string: cloudJobURL)!,
            apiKey: apiKey,
            providerID: providerID,
            // optionalPayload 作为一个 form 字段（JSON 字符串），与 SKILL 的 Local File Mode 一致。
            optionalPayload: #"{"useDocOrientationClassify":false,"useDocUnwarping":false,"useTextlineOrientation":false,"returnWordBox":true}"#,
            requestTimeout: 60,
            pollInterval: 2.5,
            pollBudget: 300,
            followServerResultURL: true,
            unreachableHint: "")
    }

    /// API key 的内存副本。Keychain 是同步读、一次几十毫秒，而翻页 / 缩放每露出一页都要在主线程上问一次
    /// 「OCR 配好没有」（`OCRBackend.current.config`；2026-10-07 采样：缩放时一次 36ms，连着几次就掉帧）。
    /// key 只经 `setApiKey` 改，改时一起更新这份。
    private static let keyLock = NSLock()
    private static var cachedKey: String?

    /// 读 API key：Keychain 为唯一下落；UserDefaults 里的旧明文一次性迁入 Keychain 并清除。
    static func apiKey() -> String {
        keyLock.lock(); defer { keyLock.unlock() }
        if let k = cachedKey { return k }
        let k = loadApiKey()
        cachedKey = k
        return k
    }

    private static func loadApiKey() -> String {
        if let k = Keychain.read(apiKeyKey)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !k.isEmpty { return k }
        let legacy = (UserDefaults.standard.string(forKey: apiKeyKey) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !legacy.isEmpty {
            Keychain.write(apiKeyKey, legacy)
            UserDefaults.standard.removeObject(forKey: apiKeyKey)
        }
        return legacy
    }

    /// 设置页写入（去首尾空白）；空串 = 从 Keychain 删除。
    static func setApiKey(_ key: String) {
        let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
        Keychain.write(apiKeyKey, k)
        keyLock.lock(); cachedKey = k; keyLock.unlock()
    }

    // MARK: 识别一页

    /// 识别一页图片 → 逐行 `TextRun`（归一化，行框，按阅读顺序 y→x 排好序；空结果返回 []）。
    static func recognize(image: CGImage, config: Config) async throws -> [TextRun] {
        guard let png = pngData(image) else { throw OCRError.encodeFailed }
        let jobId = try await submit(png: png, config: config)
        let jsonlURL = try await poll(jobId: jobId, config: config)
        let (data, _) = try await send(request(to: jsonlURL, config: config), config: config)
        return parse(jsonl: data, imageSize: CGSize(width: image.width, height: image.height))
    }

    // MARK: HTTP

    /// 组装一个请求：地址、超时、`Authorization`（本机服务不校验 key，空串就整个头都不发）。
    private static func request(to url: URL, config: Config) -> URLRequest {
        var req = URLRequest(url: url)
        req.timeoutInterval = config.requestTimeout
        if !config.apiKey.isEmpty { req.setValue("bearer \(config.apiKey)", forHTTPHeaderField: "Authorization") }
        return req
    }

    /// 发一个请求。「连不上」单独翻一句：本机服务最常见的失败就是进程没起来，
    /// 光丢一句系统文案用户没法照着办。
    private static func send(_ req: URLRequest, config: Config) async throws -> (Data, URLResponse) {
        do {
            return try await URLSession.shared.data(for: req)
        } catch let e as URLError {
            switch e.code {
            case .cannotConnectToHost, .cannotFindHost, .networkConnectionLost, .notConnectedToInternet:
                throw OCRError.unreachable(e.localizedDescription, config.unreachableHint)
            case .timedOut:
                throw OCRError.timeout
            default:
                throw e
            }
        }
    }

    private static func submit(png: Data, config: Config) async throws -> String {
        let boundary = "----unireader-\(UUID().uuidString)"
        var body = Data()
        body.appendStr("--\(boundary)\r\nContent-Disposition: form-data; name=\"model\"\r\n\r\n\(model)\r\n")
        body.appendStr("--\(boundary)\r\nContent-Disposition: form-data; name=\"optionalPayload\"\r\n\r\n\(config.optionalPayload)\r\n")
        body.appendStr("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"page.png\"\r\nContent-Type: image/png\r\n\r\n")
        body.append(png)
        body.appendStr("\r\n--\(boundary)--\r\n")

        // 排队满（本机 `OCR_MAX_PENDING`，默认 32）返回 503 + `Retry-After`，照它给的秒数等一会儿再投
        // （`docs/API.md` §4）。重试几次还不行才报错——那是真投不进去。
        for attempt in 0...3 {
            var req = request(to: config.endpoint, config: config)
            req.httpMethod = "POST"
            req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
            req.httpBody = body
            let (data, resp) = try await send(req, config: config)
            guard let http = resp as? HTTPURLResponse else { throw OCRError.badResponse }
            if http.statusCode == 503, attempt < 3 {
                try await Task.sleep(nanoseconds: UInt64(retryAfter(http) * 1_000_000_000))
                continue
            }
            guard http.statusCode == 200 else { throw OCRError.http(http.statusCode, errorDetail(data)) }
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let d = obj["data"] as? [String: Any],
                  let jobId = (d["jobId"] as? String) ?? (d["jobId"] as? NSNumber).map({ $0.stringValue })
            else { throw OCRError.badResponse }
            return jobId
        }
        throw OCRError.timeout
    }

    /// `Retry-After` 头（秒），没有或不像就按 5 秒；钳在 1~30 秒，别被一个怪值挂住整页。
    private static func retryAfter(_ http: HTTPURLResponse) -> Double {
        guard let v = http.value(forHTTPHeaderField: "Retry-After"), let s = Double(v) else { return 5 }
        return min(max(s, 1), 30)
    }

    /// 出错响应里的说明文字：两个后端都用 `{"detail": "…"}`（本机服务 `docs/API.md` §4）。
    private static func errorDetail(_ data: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let detail = obj["detail"] as? String else { return nil }
        return detail.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 轮询到 `done`，返回结果 JSONL 的地址；`failed` 抛错；总时长不超过 `config.pollBudget`。
    /// 两个后端都是**提交即入队**（识别在后台跑），所以这里要真等：`pending` / `running` 隔
    /// `pollInterval` 再查一次（`docs/API.md` §2.2）。本机第一个任务还包含模型加载，会等上几十秒。
    private static func poll(jobId: String, config: Config) async throws -> URL {
        let url = config.endpoint.appendingPathComponent(jobId)
        let req = request(to: url, config: config)
        let until = Date().addingTimeInterval(config.pollBudget)
        while Date() < until {
            let (data, resp) = try await send(req, config: config)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let d = obj["data"] as? [String: Any],
                  let state = d["state"] as? String
            else { throw OCRError.badResponse }
            switch state {
            case "done":
                guard config.followServerResultURL else {
                    // 不跟响应里的绝对地址（那是服务自己监听的那个，用户改过 host/端口就指不回去），
                    // 按固定路径拼：`docs/API.md` §2.3。
                    return url.appendingPathComponent("result.jsonl")
                }
                guard let ru = d["resultUrl"] as? [String: Any],
                      let s = ru["jsonUrl"] as? String, let u = URL(string: s) else { throw OCRError.badResponse }
                return u
            case "failed":
                throw OCRError.jobFailed((d["errorMsg"] as? String) ?? errorDetail(data) ?? "unknown")
            default:   // pending / running
                try await Task.sleep(nanoseconds: UInt64(config.pollInterval * 1_000_000_000))
            }
        }
        throw OCRError.timeout
    }

    // MARK: 解析

    /// PP-OCRv6 JSONL → `[TextRun]`。逐行文本 `rec_texts` + 行框 `rec_boxes`（像素坐标，左上原点），
    /// 按 `prunedResult.width/height`（缺省用上传图尺寸）归一化。结果按 y→x 排好序（阅读顺序）。
    ///
    /// 同时消化 `returnWordBox` 的产物：`text_word`（每行的字/词，拼起来 == `rec_texts[i]`）与
    /// `text_word_boxes`（同序的框），换成 `TextRun.chars`。这两列缺失或对不上都只是没有单字框，
    /// 不影响行本身——选择会回落权重近似。
    static func parse(jsonl: Data, imageSize: CGSize) -> [TextRun] {
        guard let text = String(data: jsonl, encoding: .utf8) else { return [] }
        var runs: [TextRun] = []
        for line in text.split(whereSeparator: \.isNewline) {
            guard let ld = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: ld) as? [String: Any],
                  let result = obj["result"] as? [String: Any],
                  let ocrResults = result["ocrResults"] as? [[String: Any]] else { continue }
            for page in ocrResults {
                guard let pr = page["prunedResult"] as? [String: Any] else { continue }
                let texts = (pr["rec_texts"] as? [String]) ?? []
                let boxes = (pr["rec_boxes"] as? [[Any]]) ?? []
                let words = (pr["text_word"] as? [[String]]) ?? []
                let wordBoxes = (pr["text_word_boxes"] as? [[[Any]]]) ?? []
                let w = (pr["width"] as? NSNumber)?.doubleValue ?? Double(imageSize.width)
                let h = (pr["height"] as? NSNumber)?.doubleValue ?? Double(imageSize.height)
                guard w > 0, h > 0 else { continue }
                for i in 0..<min(texts.count, boxes.count) {
                    let t = texts[i].trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !t.isEmpty, let bb = boundingBox(boxes[i]) else { continue }
                    let nx = bb.minX / w, ny = bb.minY / h, nw = bb.width / w, nh = bb.height / h
                    guard nw > 0, nh > 0 else { continue }
                    let cb = charBounds(line: i, text: texts[i], lineBox: bb,
                                        words: words, wordBoxes: wordBoxes)
                    runs.append(TextRun(text: texts[i], x: nx, y: ny, w: nw, h: nh, chars: cb))
                }
            }
        }
        runs.sort { $0.y != $1.y ? $0.y < $1.y : $0.x < $1.x }   // 阅读顺序：上→下、左→右
        return runs
    }

    /// 第 `line` 行的单字框 → 字符边界（`TextRun.chars` 的口径）。两列任一缺失/长度对不上就返回 nil。
    private static func charBounds(line: Int, text: String, lineBox: CGRect,
                                   words: [[String]], wordBoxes: [[[Any]]]) -> [Double]? {
        guard line < words.count, line < wordBoxes.count else { return nil }
        let raw = wordBoxes[line]
        let boxes = raw.compactMap { boundingBox($0) }
        guard boxes.count == raw.count else { return nil }   // 有框解析不出来就整行不要，别错位
        return OCRTextSelect.boundsFromWordBoxes(lineText: text, words: words[line],
                                                 boxes: boxes, lineBox: lineBox)
    }

    /// 一个框可能是 `[x1,y1,x2,y2]`（轴对齐）或多边形 `[[x,y],...]`——都归成轴对齐包围盒。
    private static func boundingBox(_ box: [Any]) -> CGRect? {
        let nums = box.compactMap { ($0 as? NSNumber)?.doubleValue }
        if nums.count == 4 {
            return CGRect(x: nums[0], y: nums[1], width: nums[2] - nums[0], height: nums[3] - nums[1])
        }
        var xs: [Double] = [], ys: [Double] = []
        for pt in box {
            guard let p = pt as? [Any], p.count >= 2,
                  let px = (p[0] as? NSNumber)?.doubleValue, let py = (p[1] as? NSNumber)?.doubleValue else { continue }
            xs.append(px); ys.append(py)
        }
        guard let minx = xs.min(), let maxx = xs.max(), let miny = ys.min(), let maxy = ys.max(),
              maxx > minx, maxy > miny else { return nil }
        return CGRect(x: minx, y: miny, width: maxx - minx, height: maxy - miny)
    }

    private static func pngData(_ image: CGImage) -> Data? {
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }
}

private extension Data {
    mutating func appendStr(_ s: String) { if let d = s.data(using: .utf8) { append(d) } }
}
