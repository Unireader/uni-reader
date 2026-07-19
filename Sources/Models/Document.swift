import Foundation
import SwiftData

/// 一个逻辑文档，以内容 hash 唯一标识。
/// 同一文件的多个物理路径记录在 `locations`，文件移动/复制后笔记不丢。
@Model
final class Document {
    /// 文件内容 SHA-256（分块计算），文档唯一键。
    @Attribute(.unique) var contentHash: String
    var title: String
    var pageCount: Int
    var addedAt: Date
    var lastOpenedAt: Date

    @Relationship(deleteRule: .cascade, inverse: \DocumentLocation.document)
    var locations: [DocumentLocation]

    @Relationship(deleteRule: .cascade, inverse: \Note.document)
    var notes: [Note]

    /// 所属分组（可空；nil = 仅在「最近」列表）。
    @Relationship(deleteRule: .nullify, inverse: \LibraryGroup.documents)
    var group: LibraryGroup?

    init(contentHash: String, title: String, pageCount: Int,
         addedAt: Date = .now, lastOpenedAt: Date = .now) {
        self.contentHash = contentHash
        self.title = title
        self.pageCount = pageCount
        self.addedAt = addedAt
        self.lastOpenedAt = lastOpenedAt
        self.locations = []
        self.notes = []
    }
}
