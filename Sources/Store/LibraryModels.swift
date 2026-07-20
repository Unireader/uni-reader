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
/// `inWorkspace=true` 时 `path` 为**工作区相对路径**（如 `PDFs/xxx.pdf`），随文件夹移动仍有效；
/// 否则为绝对路径（外部文件）。
struct LibLocation: Identifiable, Equatable {
    var id: String              // UUID
    var variantId: String
    var path: String
    var isValid: Bool
    var lastValidatedAt: Date?
    var inWorkspace: Bool = false
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
