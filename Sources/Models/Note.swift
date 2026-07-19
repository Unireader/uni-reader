import Foundation
import CoreGraphics
import SwiftData

/// 三种笔记形态的统一存储：文字注解 / 会话笔记 / 手写笔画。
/// 通过 `document(hash) + page + anchorRect`（PDF 页面坐标）锚定，绝不改动 PDF 原文。
enum NoteKind: Int, Codable {
    case text = 0   // 文字注解
    case chat = 1   // 会话笔记（预留 AI 对话）
    case ink  = 2   // 手写笔画
}

@Model
final class Note {
    var kindRaw: Int
    var page: Int

    // 锚点：PDF 页面坐标系下的矩形（点选可为零宽高的一个点）。
    var anchorX: Double
    var anchorY: Double
    var anchorW: Double
    var anchorH: Double

    /// 各类型内容的序列化：文本 / 消息数组 / 笔画点列。
    var payload: Data
    var createdAt: Date
    var updatedAt: Date

    var document: Document?

    var kind: NoteKind {
        get { NoteKind(rawValue: kindRaw) ?? .text }
        set { kindRaw = newValue.rawValue }
    }

    var anchorRect: CGRect {
        get { CGRect(x: anchorX, y: anchorY, width: anchorW, height: anchorH) }
        set {
            anchorX = newValue.origin.x; anchorY = newValue.origin.y
            anchorW = newValue.size.width; anchorH = newValue.size.height
        }
    }

    init(kind: NoteKind, page: Int, anchorRect: CGRect, payload: Data = Data(),
         createdAt: Date = .now, updatedAt: Date = .now) {
        self.kindRaw = kind.rawValue
        self.page = page
        self.anchorX = anchorRect.origin.x
        self.anchorY = anchorRect.origin.y
        self.anchorW = anchorRect.size.width
        self.anchorH = anchorRect.size.height
        self.payload = payload
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
