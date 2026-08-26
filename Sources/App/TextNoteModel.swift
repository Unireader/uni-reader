import CoreGraphics
import Foundation

/// 一条文字注解（便签）。锚定到某页的一段选区：
///  · `anchor` = 选区行框的归一化包围盒（0~1，页局部，左上原点）——与手写笔迹同约定，渲染高亮/图钉直接用。
///  · `rects`  = 逐行归一化框（页局部），用于在页面上精确高亮被注解的文字（feat 2）。
///  · `quote`  = 被选中的原文（可能跨页；注解锚到选区起始页，原文完整保留）。
///  · `text`   = 用户写的批注内容。
/// 落 `note` 表 kind=0（挂逻辑文档，全版本共用；payload=JSON 跨平台可读）。
/// 一条笔记的来源。目前只有一种：从 AI 面板里选中一段回答回填过来的。
///
/// 有了它，笔记能**点回原对话**，也能筛出「哪些笔记是 AI 来的」。
/// 旧 payload 没有这个键 → nil，**零迁移**（与 `type_id` 完全同一个先例）。
struct NoteSource: Equatable {
    static let aiKind = "ai"

    var kind: String            // 目前恒为 "ai"，留着是为了将来还有别的来源
    var provider: String        // AIProvider.id
    var url: String             // 那次对话的唯一链接
    var threadId: UUID?         // 对应的 AIThread（note kind=1）；解绑过就可能为 nil
    var at: Date

    var isAI: Bool { kind == Self.aiKind }
}

struct TextNote: Identifiable, Equatable {
    var id: UUID = UUID()
    var page: Int
    var anchor: CGRect          // 归一化包围盒 0~1（页局部，左上原点）
    var quote: String           // 选中的原文
    var text: String            // 用户批注
    var rects: [CGRect]         // 选区逐行归一化框（页局部）——渲染精确高亮用
    var color: InkColor?        // 预留：高亮色（高亮形态复用）
    var typeId: UUID? = nil     // 笔记类型（工作区 NoteType.id）；nil/未知 = 通用
    var source: NoteSource? = nil   // 来源（AI 回填）；nil = 用户自己写的
    var createdAt: Date = .now
    var updatedAt: Date = .now
}

// MARK: - 持久化（note 表，kind=0）

/// 落库到 `note.payload` 的 JSON 形态（页/锚点走 note 列，这里只存其余字段）。
/// rects 用显式 `[x, y, w, h]` 数组，保证 Windows/Android 端易读。
private struct TextNotePayload: Codable {
    var quote: String
    var text: String
    var rects: [[Double]]
    var color: InkColor?
    var typeId: String?     // JSON 键 type_id；旧 payload 无此键 → nil（通用），零迁移
    var source: Src?        // JSON 键 source；旧 payload 无此键 → nil，同样零迁移

    struct Src: Codable {
        var kind: String
        var provider: String
        var url: String
        var threadId: String?
        var at: String      // ISO-8601，跨平台可读（同 AIThread 的 contexts）

        enum CodingKeys: String, CodingKey {
            case kind, provider, url, at
            case threadId = "thread_id"
        }
    }

    enum CodingKeys: String, CodingKey {
        case quote, text, rects, color, source
        case typeId = "type_id"
    }
}

extension TextNote {
    /// 文字注解的笔记类型（对齐 `LibNote.kind`：0 text / 1 chat / 2 ink）。
    static let noteKind = 0

    /// 序列化为一条 text 笔记（挂逻辑文档，全版本共用）。
    func toNote(documentId: String) -> LibNote? {
        let payload = TextNotePayload(quote: quote, text: text,
                                      rects: rects.map { [$0.minX, $0.minY, $0.width, $0.height] },
                                      color: color, typeId: typeId?.uuidString,
                                      source: source.map {
                                          TextNotePayload.Src(kind: $0.kind, provider: $0.provider,
                                                              url: $0.url,
                                                              threadId: $0.threadId?.uuidString,
                                                              at: ISO.string($0.at))
                                      })
        guard let data = try? JSONEncoder().encode(payload) else { return nil }
        return LibNote(id: id.uuidString, documentId: documentId, kind: Self.noteKind,
                       page: page, anchor: anchor, payload: data,
                       createdAt: createdAt, updatedAt: updatedAt)
    }

    /// 从一条 text 笔记复原（id/page/anchor 取 note 列，其余取 payload）。类型不符或损坏返回 nil。
    init?(note: LibNote) {
        guard note.kind == TextNote.noteKind,
              let uuid = UUID(uuidString: note.id),
              let p = try? JSONDecoder().decode(TextNotePayload.self, from: note.payload)
        else { return nil }
        let rects: [CGRect] = p.rects.map { (a: [Double]) -> CGRect in
            let x: Double = a.count > 0 ? a[0] : 0
            let y: Double = a.count > 1 ? a[1] : 0
            let w: Double = a.count > 2 ? a[2] : 0
            let h: Double = a.count > 3 ? a[3] : 0
            return CGRect(x: x, y: y, width: w, height: h)
        }
        let src = p.source.map {
            NoteSource(kind: $0.kind, provider: $0.provider, url: $0.url,
                       threadId: $0.threadId.flatMap { UUID(uuidString: $0) },
                       at: ISO.date($0.at) ?? note.createdAt)
        }
        self.init(id: uuid, page: note.page, anchor: note.anchor, quote: p.quote, text: p.text,
                  rects: rects, color: p.color, typeId: p.typeId.flatMap { UUID(uuidString: $0) },
                  source: src, createdAt: note.createdAt, updatedAt: note.updatedAt)
    }
}
