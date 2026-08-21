import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// PaddleOCR 云 API 客户端（模型 **PP-OCRv6**，逐页图片提交）。
/// 异步 job：`POST /api/v2/ocr/jobs`(multipart 上传页图) → 轮询 `GET .../{jobId}` 到 `done` → 下 JSONL。
/// PP-OCRv6 的结果里逐行文本在 `result.ocrResults[].prunedResult.rec_texts`、行框在 `rec_boxes`
/// （输入图**像素坐标、左上原点**）——正好和页图（`PageBitmap.render` 出的显示朝向图，top-origin）同坐标系，
/// 直接按图宽高归一化成 `TextRun`（0~1 左上原点），无需 rotation 变换。
/// 引擎选择存 UserDefaults；API key 存 **Keychain**（本机密钥，不进工作区共享文件夹、不落 plist 明文）。
enum PaddleOCR {
    static let jobURL = "https://paddleocr.aistudio-app.com/api/v2/ocr/jobs"
    static let model = "PP-OCRv6"
    static let providerID = "paddle-ppocrv6"

    /// UserDefaults 键（引擎选择；与 `SettingsView` / `ContentView` 共用）。
    static let engineKey = "ocrEngine"        // "off" | "paddle"
    /// API key 的 Keychain account；同时也是 UserDefaults 里的**旧**键（仅迁移用，见 `apiKey()`）。
    static let apiKeyKey = "ocrPaddleKey"

    struct Config { var apiKey: String }

    enum OCRError: LocalizedError {
        case notConfigured, encodeFailed, http(Int), badResponse, jobFailed(String), timeout
        var errorDescription: String? {
            switch self {
            case .notConfigured: return "OCR 未配置（设置里选 Paddle 并填 key）"
            case .encodeFailed:  return "页图编码失败"
            case .http(let c):   return "HTTP \(c)"
            case .badResponse:   return "响应格式异常"
            case .jobFailed(let m): return "识别失败：\(m)"
            case .timeout:       return "识别超时"
            }
        }
    }

    /// 引擎=paddle 且 key 非空 → 返回配置，否则 nil（用于「是否已配置 OCR」判断）。
    static func configFromDefaults() -> Config? {
        let d = UserDefaults.standard
        guard d.string(forKey: engineKey) == "paddle" else { return nil }
        let key = apiKey()
        return key.isEmpty ? nil : Config(apiKey: key)
    }

    /// 读 API key：Keychain 为唯一下落；UserDefaults 里的旧明文一次性迁入 Keychain 并清除。
    static func apiKey() -> String {
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
        Keychain.write(apiKeyKey, key.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    // MARK: 识别一页

    /// 识别一页图片 → 逐行 `TextRun`（归一化，行框，按阅读顺序 y→x 排好序；空结果返回 []）。
    static func recognize(image: CGImage, config: Config) async throws -> [TextRun] {
        guard let png = pngData(image) else { throw OCRError.encodeFailed }
        let jobId = try await submit(png: png, config: config)
        let jsonlURL = try await poll(jobId: jobId, config: config)
        let (data, _) = try await URLSession.shared.data(from: jsonlURL)
        return parse(jsonl: data, imageSize: CGSize(width: image.width, height: image.height))
    }

    // MARK: HTTP

    private static func submit(png: Data, config: Config) async throws -> String {
        let boundary = "----unireader-\(UUID().uuidString)"
        var req = URLRequest(url: URL(string: jobURL)!)
        req.httpMethod = "POST"
        req.setValue("bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        // optionalPayload 作为一个 form 字段（JSON 字符串），与 SKILL 的 Local File Mode 一致。
        let optional = #"{"useDocOrientationClassify":false,"useDocUnwarping":false,"useTextlineOrientation":false}"#
        var body = Data()
        body.appendStr("--\(boundary)\r\nContent-Disposition: form-data; name=\"model\"\r\n\r\n\(model)\r\n")
        body.appendStr("--\(boundary)\r\nContent-Disposition: form-data; name=\"optionalPayload\"\r\n\r\n\(optional)\r\n")
        body.appendStr("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"page.png\"\r\nContent-Type: image/png\r\n\r\n")
        body.append(png)
        body.appendStr("\r\n--\(boundary)--\r\n")
        req.httpBody = body

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw OCRError.badResponse }
        guard http.statusCode == 200 else { throw OCRError.http(http.statusCode) }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let d = obj["data"] as? [String: Any],
              let jobId = (d["jobId"] as? String) ?? (d["jobId"] as? NSNumber).map({ $0.stringValue })
        else { throw OCRError.badResponse }
        return jobId
    }

    /// 轮询到 `done`（返回结果 JSONL 的预签名 URL）；`failed` 抛错；~最多 5 分钟超时。
    private static func poll(jobId: String, config: Config) async throws -> URL {
        var req = URLRequest(url: URL(string: "\(jobURL)/\(jobId)")!)
        req.setValue("bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        for _ in 0..<120 {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let d = obj["data"] as? [String: Any],
                  let state = d["state"] as? String
            else { throw OCRError.badResponse }
            switch state {
            case "done":
                guard let ru = d["resultUrl"] as? [String: Any],
                      let s = ru["jsonUrl"] as? String, let u = URL(string: s) else { throw OCRError.badResponse }
                return u
            case "failed":
                throw OCRError.jobFailed((d["errorMsg"] as? String) ?? "unknown")
            default:   // pending / running
                try await Task.sleep(nanoseconds: 2_500_000_000)
            }
        }
        throw OCRError.timeout
    }

    // MARK: 解析

    /// PP-OCRv6 JSONL → `[TextRun]`。逐行文本 `rec_texts` + 行框 `rec_boxes`（像素坐标，左上原点），
    /// 按 `prunedResult.width/height`（缺省用上传图尺寸）归一化。结果按 y→x 排好序（阅读顺序）。
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
                let w = (pr["width"] as? NSNumber)?.doubleValue ?? Double(imageSize.width)
                let h = (pr["height"] as? NSNumber)?.doubleValue ?? Double(imageSize.height)
                guard w > 0, h > 0 else { continue }
                for i in 0..<min(texts.count, boxes.count) {
                    let t = texts[i].trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !t.isEmpty, let bb = boundingBox(boxes[i]) else { continue }
                    let nx = bb.minX / w, ny = bb.minY / h, nw = bb.width / w, nh = bb.height / h
                    guard nw > 0, nh > 0 else { continue }
                    runs.append(TextRun(text: texts[i], x: nx, y: ny, w: nw, h: nh))
                }
            }
        }
        runs.sort { $0.y != $1.y ? $0.y < $1.y : $0.x < $1.x }   // 阅读顺序：上→下、左→右
        return runs
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
