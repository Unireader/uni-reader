import AppKit
import Foundation

/// 本机 OCR 服务（仓库 https://github.com/xVanTuring/ocr-services ，PP-OCRv6 跑在 MLX 上）的后端参数。
///
/// 它是独立进程，接口与 Paddle 云端**一致**（`POST /api/v2/ocr/jobs` 入队 → 轮询状态 → 下 JSONL，
/// 结果字段也一样），所以提交、轮询、解析都复用 `PaddleOCR` 那套客户端，这里只交代两处差别：
/// 地址与密钥、轮询节奏与等待预算。细则见该仓库的 `docs/API.md`。
enum LocalOCR {
    /// ⚠️ 缓存键的一部分（`ocr_page.provider`），**刻意与云端分开**：同一个模型跑在 MLX 上，
    /// 结果与云端不会逐字一致，两边共用一个标识会让缓存里的结果来源不明（`docs/API.md` §6.6）。
    static let providerID = "local-ppocrv6-w"

    /// 服务端仓库：安装、启动、接口说明都在那儿。设置页与 OCR 面板上都挂着可点的链接。
    static let repoURL = URL(string: "https://github.com/xVanTuring/ocr-services")!
    /// 链上显示的地址（不带 scheme，短一截、好认）。
    static let repoLabel = "github.com/xVanTuring/ocr-services"

    /// 服务地址（UserDefaults 键；空 = 用默认）。装服务时改过 `OCR_HOST` / `OCR_PORT` 就填这里。
    static let addressKey = "ocrLocalAddress"
    static let defaultAddress = "http://127.0.0.1:8766"

    /// 归一化用户填的地址：去空白、空则用默认、没写 scheme 补 `http://`、去掉末尾斜杠。
    static func normalizedAddress(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return defaultAddress }
        if !s.contains("://") { s = "http://" + s }
        while s.hasSuffix("/") { s = String(s.dropLast()) }
        return s
    }

    static var storedAddress: String {
        UserDefaults.standard.string(forKey: addressKey) ?? ""
    }

    /// 解析后的服务根地址；填坏了（没有 host、或不是 http/https）返回 nil。
    static var baseURL: URL? {
        guard let url = URL(string: normalizedAddress(storedAddress)),
              let host = url.host, !host.isEmpty,
              url.scheme == "http" || url.scheme == "https" else { return nil }
        return url
    }

    /// 打开服务仓库（页面上的「点跳过去」都走这一个口）。
    static func openRepo() { NSWorkspace.shared.open(repoURL) }

    // MARK: 后端参数

    /// 本机服务这一套 `PaddleOCR` 参数；地址填坏时返回 nil（= 引擎没配好）。
    static func config() -> PaddleOCR.Config? {
        guard let base = baseURL else { return nil }
        return PaddleOCR.Config(
            endpoint: base.appendingPathComponent("api/v2/ocr/jobs"),
            apiKey: "",                                   // 服务不校验，连 Authorization 都不发
            providerID: providerID,
            // 本机只认 returnWordBox，云端那些方向矫正键不发过去（发了也只是被忽略）。
            optionalPayload: #"{"returnWordBox":true}"#,
            requestTimeout: 30,                           // 提交只入队、查询只读状态，单次往返都很轻
            pollInterval: 0.5,                            // 本机一页几百毫秒，查勤一点更跟手
            pollBudget: 300,                              // 第一个任务含模型加载，总等待放宽（docs/API.md §6.4）
            followServerResultURL: false,
            unreachableHint: "先把它启动起来（安装与启动方法都在 \(repoLabel)）")
    }

    // MARK: 健康检查

    enum Health: Equatable {
        case badAddress            // 地址填坏了
        case offline               // 连不上（服务没启动 / 端口不对）
        case online(modelLoaded: Bool)
    }

    /// `GET /healthz`。这个检查本身**不触发**模型加载，只用来看服务起没起（`docs/API.md` §2.4）。
    static func checkHealth() async -> Health {
        guard let base = baseURL else { return .badAddress }
        var req = URLRequest(url: base.appendingPathComponent("healthz"))
        req.timeoutInterval = 10
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse, http.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return .offline }
        return .online(modelLoaded: (obj["loaded"] as? NSNumber)?.boolValue ?? false)
    }
}
