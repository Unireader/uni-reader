import Foundation
import SwiftData

/// 用户自定义分组（文库里的「文件夹」）。文档可拖拽归入。
@Model
final class LibraryGroup {
    var name: String
    var order: Int
    var createdAt: Date

    var documents: [Document]

    init(name: String, order: Int = 0, createdAt: Date = .now) {
        self.name = name
        self.order = order
        self.createdAt = createdAt
        self.documents = []
    }
}
