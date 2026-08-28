import Foundation
import CoreGraphics

/// 工作区数据模型（纯值类型，映射 `library.sqlite` 的表；跨平台可读）。
/// 与旧 SwiftData `@Model` 无关——工作区改用自有 schema 的 SQLite 单库。

/// 逻辑文档「一本书」。可含多个内容版本（variant），笔记全版本共用。
struct LibDocument: Identifiable, Equatable {
    var id: String              // UUID
    var title: String
    var pageCount: Int
    var addedAt: Date
    var lastOpenedAt: Date
    var sortOrder: Int
    var readPage: Int = 0       // 阅读进度：视口顶部所在页
    var readFrac: Double = 0    // 阅读进度：页内归一化比例（0 顶 1 底）
    var readZoom: Double = 1    // 上次缩放倍率（相对 fit-width，1=贴合宽度）
    var readHFrac: Double = 0   // 上次横向滚动比例（offsetX / pageW，缩放态才非 0）
    var group: String = ""      // 一级分组名（v11；空串 = 未分组）
    var canvasMode: Bool = false // 画板模式（v12）：页面两侧空白也可书写
}

/// 一个内容版本＝一个 content hash（加 TOC 等致 hash 变即新增一个 variant）。
struct LibVariant: Identifiable, Equatable {
    var id: String              // UUID
    var documentId: String
    var contentHash: String     // SHA-256
    var pageCount: Int
    var addedAt: Date
}

/// 一个物理路径（移动/复制产生多条）。非沙盒 + 跨平台 → 不存 macOS security-scoped bookmark。
/// `inWorkspace=true` 时 `path` 为**工作区相对路径**（如 `PDFs/xxx.pdf`），随文件夹移动仍有效。
/// `isRelative=true` 时 `path` 也是**相对工作区文件夹**的路径（可含 `..`）——外部文件但与工作区
/// 同属一块可移动卷（移动硬盘等）时使用，换机器/换挂载点仍可解析；否则为绝对路径。
struct LibLocation: Identifiable, Equatable {
    var id: String              // UUID
    var variantId: String
    var path: String
    var isValid: Bool
    var lastValidatedAt: Date?
    var inWorkspace: Bool = false
    var isRelative: Bool = false
}

/// 笔记（挂逻辑文档，全版本共用）。payload 为 JSON（跨平台可读）。
struct LibNote: Identifiable, Equatable {
    var id: String              // UUID
    var documentId: String
    var kind: Int               // 0 text / 1 chat / 2 ink
    var page: Int
    var anchor: CGRect          // PDF 页面坐标
    var payload: Data           // JSON
    var createdAt: Date
    var updatedAt: Date
}

/// 一个笔迹图层（`ink_layer` 表，v7）。挂逻辑文档；`colorKey` 复用 `NoteType.palette`。
struct LibInkLayer: Identifiable, Equatable {
    var id: String              // UUID
    var documentId: String
    var name: String
    var colorKey: String
    var sortOrder: Int
    var visible: Bool
    var createdAt: Date
}

/// 一张草稿纸（`scratch_pad` 表，v8）。挂逻辑文档，全版本共用（同 note/ink_layer）。
/// 锚点＝创建时所在页 + 页内归一化点（图钉位置）；`bg` 为 CSS `rgba(...)` 串（跨平台易读）。
/// 草稿纸上的笔迹在 `note` 表 kind=4，payload 里带 `padId` 指回这里，坐标是**画布坐标**
/// （逻辑点，可负无界，见 `ScratchPad` 的坐标系契约）。
struct LibScratchPad: Identifiable, Equatable {
    var id: String              // UUID
    var documentId: String
    var title: String
    var anchorPage: Int
    var anchorX: Double
    var anchorY: Double
    var bg: String
    /// 底纹 `ScratchPattern.rawValue`（"plain"/"dots"/"grid"，v9）。老行为空 → 解码兜底 dots。
    var pattern: String
    /// 页面底图（v10）：要不要把这张纸锚定的那一页垫在纸下面（几何契约见 `ScratchPad.pageRefWidth`）。
    /// v9 迁移过来的老纸补列即 0（关），新建的纸默认开——见 `ScratchPad.showPage`。
    var showPage: Bool
    var createdAt: Date
    var updatedAt: Date
}

/// 一页的 OCR 缓存（`ocr_page` 表，v3）。按内容 hash（= variant 物理内容）+ 页 + 引擎缓存，
/// 随文件移动/换机复用。`payload` = JSON `OCRPagePayload`（归一化 0~1 文本框，见 `OCR.swift`）。
struct OCRPage: Equatable {
    var contentHash: String     // SHA-256（对应 variant.content_hash）
    var page: Int
    var provider: String        // OCR 引擎标识（"vision" / "paddle-http" / …）
    var payload: Data           // JSON
    var lang: String?
    var createdAt: Date
}

/// ISO-8601（带小数秒）读写，供 SQLite TEXT 时间列使用；跨平台标准。
enum ISO {
    private static let fmt: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    static func string(_ d: Date) -> String { fmt.string(from: d) }
    static func date(_ s: String?) -> Date? { s.flatMap { fmt.date(from: $0) } }
}
