import CoreGraphics
import PDFKit

/// 页面文本层的统一「货币」：一段文本 + 归一化包围盒（0~1，左上原点，与 `PageLayout`/`InkStroke` 同约定）。
/// **文字选择 / 搜索 / 复制 都只消费它**，不关心文本来自原生 PDF 还是 OCR。
/// 与页图正交叠加：`PageStreamView` 的 `PageCell` 里页图之上叠一层文本/选择层，坐标全走 `PageLayout` 换算。
struct TextRun: Equatable, Codable {
    var text: String
    var x: Double, y: Double, w: Double, h: Double   // 归一化 0~1，左上原点
    /// 行内**字符边界**：行框内比例 0~1，单调不减，`count == text.count + 1`，首 0 末 1。
    /// 来源是 OCR 的单字框（PP-OCRv6 `returnWordBox`，见 `OCRTextSelect.boundsFromWordBoxes`）。
    /// `nil` = 这一行没有实测字位（老缓存/原生文本层），选择回落 `OCRTextSelect` 的等宽权重近似。
    /// 可选字段，老 payload 缺这个键即解成 nil，无需迁移。
    var chars: [Double]?
    var rect: CGRect { CGRect(x: x, y: y, width: w, height: h) }

    init(text: String, x: Double, y: Double, w: Double, h: Double, chars: [Double]? = nil) {
        self.text = text; self.x = x; self.y = y; self.w = w; self.h = h; self.chars = chars
    }
}

/// 一页的文本层 + 来源。
struct PageTextLayer: Equatable {
    enum Source: Equatable { case native; case ocr(provider: String) }
    var page: Int
    var runs: [TextRun]
    var source: Source
}

/// 页面文本提供者：给某页返回文本层（异步——原生秒回，OCR 可能要查缓存/真跑）。
/// 选择/搜索/OCR 都通过它拿数据；具体实现（原生 / OCR）在各自里程碑补。
protocol PageTextProvider {
    func textLayer(forPage index: Int) async -> PageTextLayer?
}

/// 原生 PDF 文本层（数字版 PDF，`PDFPage` 免费拿字符/词框）。
/// **骨架：提取实现留到「文字搜索/选择」里程碑**。
/// 计划：`page.selection(for: page.bounds)` 逐行/逐词取 `bounds(for:)`，用 mediaBox 归一化成 0~1 左上原点。
struct NativePDFTextProvider: PageTextProvider {
    let doc: PDFDocument

    func textLayer(forPage index: Int) async -> PageTextLayer? {
        // TODO(文字搜索/选择里程碑): 从 PDFPage 提取字符/词框 → 归一化 TextRun。
        //   空/稀疏 → 判为扫描页（见 isLikelyScanned）→ 交给 OCR 路径。
        nil
    }

    /// 该页是否几乎没有原生文本（≈ 扫描页，应走 OCR）。
    static func isLikelyScanned(_ page: PDFPage) -> Bool {
        (page.string?.trimmingCharacters(in: .whitespacesAndNewlines).count ?? 0) < 8
    }
}
