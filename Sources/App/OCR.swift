import CoreGraphics
import Foundation

/// OCR 引擎抽象：给一页的位图，返回归一化文本框（喂给 `PageTextLayer`）。**可插拔**。
/// 结果由上层按 `(content_hash, page, provider)` 缓存进工作区 SQLite（`ocr_page` 表，跨平台、换机复用）。
///
/// 两类实现：
///  · `VisionOCRProvider`  系统 Vision，离线、免配置。
///  · `HTTPOCRProvider`    用户配置的远端 API（PaddleOCR 兼容 / 通用），具体请求响应契约后面再定。
protocol OCRProvider {
    /// 稳定标识，作缓存键的 `provider` 列（如 `"vision"` / `"paddle-http"`）。
    var id: String { get }
    /// 识别一页。`pageSize` = 原始页点尺寸（用于把引擎坐标归一化到 0~1）。
    func recognize(image: CGImage, pageSize: CGSize) async throws -> [TextRun]
}

/// 系统 OCR（Vision `VNRecognizeTextRequest`，离线、免配置）。**骨架：实现留到「OCR」里程碑**。
struct VisionOCRProvider: OCRProvider {
    var id: String { "vision" }
    func recognize(image: CGImage, pageSize: CGSize) async throws -> [TextRun] {
        // TODO(OCR 里程碑): VNRecognizeTextRequest → VNRecognizedTextObservation
        //   (Vision boundingBox 归一化 0~1、左下原点) → 翻 y 成左上原点 TextRun。
        []
    }
}

/// 用户可配置的 HTTP OCR（PaddleOCR 兼容 / 通用 API）。**骨架：请求/响应字段映射后面再定**。
struct HTTPOCRProvider: OCRProvider {
    let config: OCRRemoteConfig
    var id: String { config.id }
    func recognize(image: CGImage, pageSize: CGSize) async throws -> [TextRun] {
        // TODO(OCR 里程碑): 按 config 组请求(上传页图 PNG)、解析响应(框+文本)、归一化成 TextRun。
        []
    }
}

/// 远端 OCR 配置：存 **App 设置/UserDefaults（本机级、可含密钥）**，
/// **不进工作区共享文件夹**（避免密钥随文件夹外泄；OCR「结果」才进工作区库）。
struct OCRRemoteConfig: Equatable, Codable {
    var id: String            // 作缓存 provider 列（如 "paddle-http"）
    var endpoint: String      // API URL
    var apiKey: String?
    // 请求/响应字段映射待定（后面再看具体接口，不一定是 PaddleOCR）。
}

/// 当前使用哪种 OCR 引擎（占位；选择/接线留到「OCR」里程碑）。
enum OCRProviderKind: String, Codable, CaseIterable {
    case system   // VisionOCRProvider
    case remote   // HTTPOCRProvider(config)
}

/// 落进 `ocr_page.payload` 的 JSON 形态（跨平台契约）：原始页点尺寸 + 归一化文本框数组。
struct OCRPagePayload: Codable, Equatable {
    var w: Double            // 原始页点宽
    var h: Double            // 原始页点高
    var runs: [TextRun]      // 归一化 0~1，左上原点
}
