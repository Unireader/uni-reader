import Foundation
import SwiftData

/// 文档的一个物理存储位置。一个 `Document` 可有多个（移动、复制产生）。
@Model
final class DocumentLocation {
    var path: String
    /// 安全书签数据，用于文件移动后重定位（非沙盒下亦有用）。
    var bookmark: Data?
    var isValid: Bool
    var lastValidatedAt: Date?

    var document: Document?

    init(path: String, bookmark: Data? = nil) {
        self.path = path
        self.bookmark = bookmark
        self.isValid = true
        self.lastValidatedAt = nil
    }
}
