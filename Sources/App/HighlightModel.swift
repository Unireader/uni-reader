import CoreGraphics
import Foundation

/// 一条文字高亮（荧光笔）。与文字注解(kind=0)区分：高亮无正文、无图钉，只是给选中文字铺一层颜色。
///  · `anchor` = 选区行框归一化包围盒（0~1，页局部，左上原点）。
///  · `rects`  = 逐行归一化框（页局部），铺色用。
///  · `quote`  = 被高亮的原文（Inspector 列表展示 + 复制）。
///  · `color`  = 荧光色（存基色 a=1，渲染时统一降透明）。
/// 落 `note` 表 kind=3（挂逻辑文档，全版本共用；payload=JSON 跨平台可读）。
struct Highlight: Identifiable, Equatable {
    var id: UUID = UUID()
    var page: Int
    var anchor: CGRect
    var quote: String
    var rects: [CGRect]
    var color: InkColor
    var createdAt: Date = .now
    var updatedAt: Date = .now
}

extension Highlight {
    /// 高亮的笔记类型（对齐 `LibNote.kind`：0 text / 1 chat / 2 ink / 3 highlight）。
    static let noteKind = 3

    /// 预设荧光色（存基色，渲染统一 `fillOpacity`）。第一项为默认色。
    static let palette: [(name: String, color: InkColor)] = [
        ("Yellow", InkColor(r: 255, g: 214, b: 40, a: 1)),
        ("Green",  InkColor(r: 150, g: 220, b: 120, a: 1)),
        ("Blue",   InkColor(r: 120, g: 190, b: 255, a: 1)),
        ("Pink",   InkColor(r: 255, g: 150, b: 190, a: 1)),
    ]
    static let defaultColor = palette[0].color
    /// 铺色透明度（荧光笔观感，压在文字上仍可读）。
    static let fillOpacity: Double = 0.38
}

// MARK: - 持久化（note 表，kind=3）

/// 落库到 `note.payload` 的 JSON 形态（页/锚点走 note 列，这里只存其余字段）。
private struct HighlightPayload: Codable {
    var quote: String
    var rects: [[Double]]
    var color: InkColor
}

extension Highlight {
    func toNote(documentId: String) -> LibNote? {
        let payload = HighlightPayload(quote: quote,
                                       rects: rects.map { [$0.minX, $0.minY, $0.width, $0.height] },
                                       color: color)
        guard let data = try? JSONEncoder().encode(payload) else { return nil }
        return LibNote(id: id.uuidString, documentId: documentId, kind: Self.noteKind,
                       page: page, anchor: anchor, payload: data,
                       createdAt: createdAt, updatedAt: updatedAt)
    }

    init?(note: LibNote) {
        guard note.kind == Highlight.noteKind,
              let uuid = UUID(uuidString: note.id),
              let p = try? JSONDecoder().decode(HighlightPayload.self, from: note.payload)
        else { return nil }
        let rects: [CGRect] = p.rects.map { (a: [Double]) -> CGRect in
            let x: Double = a.count > 0 ? a[0] : 0
            let y: Double = a.count > 1 ? a[1] : 0
            let w: Double = a.count > 2 ? a[2] : 0
            let h: Double = a.count > 3 ? a[3] : 0
            return CGRect(x: x, y: y, width: w, height: h)
        }
        self.init(id: uuid, page: note.page, anchor: note.anchor, quote: p.quote,
                  rects: rects, color: p.color, createdAt: note.createdAt, updatedAt: note.updatedAt)
    }
}
