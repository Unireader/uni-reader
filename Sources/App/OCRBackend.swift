import Foundation

/// 设置里选中的那个 OCR 引擎。`UserDefaults` 里 `ocrEngine` 那一个字符串（键见 `PaddleOCR.engineKey`）
/// 归到这里，各处只问 `OCRBackend.current`，不再自己比 `"paddle"` 字面量。
///
/// 加一个引擎 = 这里加一个 case（`providerID` + `config` 两个分支）+ 设置页 Picker 加一行。
/// 两个后端的**识别结果不一样**，所以各有各的缓存标识（`ocr_page.provider`）：换引擎 = 旧的缓存读不着、
/// 按需重跑一遍，这是要的语义而不是 bug（旧行仍留在表里，只占点空间）。
enum OCRBackend: String, CaseIterable, Identifiable {
    case off
    /// Paddle 云 API（PP-OCRv6，要 API key）。
    case paddle
    /// 本机 OCR 服务（PP-OCRv6 / MLX，独立进程，免 key。仓库 github.com/xVanTuring/ocr-services）。
    case local

    var id: String { rawValue }

    /// 当前选择；没写过、或值不认识，都算「关闭」。
    static var current: OCRBackend {
        OCRBackend(rawValue: UserDefaults.standard.string(forKey: PaddleOCR.engineKey) ?? "") ?? .off
    }

    /// 缓存键（`ocr_page.provider`）。「关闭」也照云端的标识读——库里已有的结果照样能用，只是不再跑新的。
    var providerID: String {
        switch self {
        case .off, .paddle: return PaddleOCR.providerID
        case .local:        return LocalOCR.providerID
        }
    }

    /// 配好了能用的后端参数；nil = 引擎关着，或缺必要参数（云端没 key、本机地址填坏）。
    var config: PaddleOCR.Config? {
        switch self {
        case .off:    return nil
        case .paddle:
            let key = PaddleOCR.apiKey()
            return key.isEmpty ? nil : PaddleOCR.cloudConfig(apiKey: key)
        case .local:  return LocalOCR.config()
        }
    }

    /// 「OCR 能用了吗」。每页识别开始时取一次 `config` 一路带着走（识别与缓存标识出自同一个引擎），
    /// 中途改设置不会把一页的结果记到另一个引擎名下。
    var isReady: Bool { config != nil }
}
