import CoreGraphics
import Foundation

/// 一条图片笔记（`IMAGE-NOTE-PLAN.md`）。锚定到某页某处，正文是一张图：
///  · `anchor` = 归一化矩形（0~1，页局部，左上原点）。PDF 节选 = 框在起始页上的那块；导入 = 点锚（w=h=0）。
///  · `image`  = 图片本体的 sha256（`LibImage` / `Images/<sha>.<ext>`）。**这是图片唯一的引用形态**——
///               引用计数就是数有多少条笔记的这个字段等于某个 sha（`LibraryStore.imageRefCounts`）。
///  · `caption` = 说明文字（可空）。
///  · `display` = 页面上怎么展开（与文字笔记同一套三态）。
///  · `source`  = 从哪来的（纯展示 + Inspector 里「回到来源」）。
/// 落 `note` 表 kind=6（挂逻辑文档，全版本共用；payload=JSON 跨平台可读）。**不上线**（平板本轮不认识）。
struct ImageNote: Identifiable, Equatable {
    /// 来源。两种：从 PDF 页面框出来重渲的 / 外部文件导入的。
    enum Source: Equatable {
        /// `page` = 来源起始页；`rect` = 在该页的归一化矩形；`pages` = 跨了几页（1 = 页内）。
        case pdf(page: Int, rect: CGRect, pages: Int)
        /// `name` = 原文件名（纯展示；剪贴板来的为空串）。
        case file(name: String)
    }

    var id: UUID = UUID()
    var page: Int
    var anchor: CGRect
    var image: String           // sha256
    var caption: String = ""
    var display: NoteDisplay = .tap
    var source: Source
    var card: NoteCard? = nil   // 气泡卡片手动摆过的位置 / 大小（与文字笔记同一套，见 `NoteCard`）；nil = 自动规则
    var createdAt: Date = .now
    var updatedAt: Date = .now

    /// 一行来源描述（Inspector / 编辑器用）。
    var sourceLabel: String {
        switch source {
        case .pdf(let page, _, let pages):
            return pages > 1
                ? String(format: L("Clipped from p.%d–%d"), page + 1, page + pages)
                : String(format: L("Clipped from p.%d"), page + 1)
        case .file(let name):
            return name.isEmpty ? L("Pasted image") : name
        }
    }
}

// MARK: - 持久化（note 表，kind=6）

/// 落库到 `note.payload` 的 JSON 形态（页/锚点走 note 列，这里只存其余字段）。
/// 键名是跨端契约（`IMAGE-NOTE-PLAN.md §2.2`）：`image` / `caption` / `display` / `source{kind,page,rect,pages,name}` /
/// `card{dx,dy,w?,h?}`（2026-09-16 加，缺键 = 没摆过）。
private struct ImageNotePayload: Codable {
    var image: String
    var caption: String
    var display: String?
    var source: Src?
    var card: NoteCard?

    struct Src: Codable {
        var kind: String            // "pdf" / "file"
        var page: Int?
        var rect: [Double]?
        var pages: Int?
        var name: String?
    }
}

extension ImageNote {
    /// 图片笔记的笔记类型（对齐 `LibNote.kind`：0 text / 1 chat / 2 ink / 3 highlight / 4 scratch ink / 5 bookmark / 6 image）。
    /// 与 `LibraryStore.imageNoteKind` 是同一个数（那边算引用计数的 SQL 要用；这里写字面量是为了
    /// `spike/ink-undo-test.swift` 不必把整个 Store 层编进来）。
    static let noteKind = 6

    func toNote(documentId: String) -> LibNote? {
        let src: ImageNotePayload.Src
        switch source {
        case .pdf(let page, let rect, let pages):
            src = .init(kind: "pdf", page: page, rect: [rect.minX, rect.minY, rect.width, rect.height],
                        pages: pages, name: nil)
        case .file(let name):
            src = .init(kind: "file", page: nil, rect: nil, pages: nil, name: name)
        }
        let payload = ImageNotePayload(image: image, caption: caption, display: display.rawValue, source: src, card: card)
        guard let data = try? JSONEncoder().encode(payload) else { return nil }
        return LibNote(id: id.uuidString, documentId: documentId, kind: Self.noteKind,
                       page: page, anchor: anchor, payload: data,
                       createdAt: createdAt, updatedAt: updatedAt)
    }

    /// 从一条 kind=6 笔记复原。类型不符 / 损坏 / 没有 image 键 → nil（没有图的图片笔记不成立）。
    init?(note: LibNote) {
        guard note.kind == ImageNote.noteKind,
              let uuid = UUID(uuidString: note.id),
              let p = try? JSONDecoder().decode(ImageNotePayload.self, from: note.payload),
              !p.image.isEmpty
        else { return nil }
        let source: Source
        if let s = p.source, s.kind == "pdf" {
            let a = s.rect ?? []
            let rect = CGRect(x: a.count > 0 ? a[0] : 0, y: a.count > 1 ? a[1] : 0,
                              width: a.count > 2 ? a[2] : 0, height: a.count > 3 ? a[3] : 0)
            source = .pdf(page: s.page ?? note.page, rect: rect, pages: max(1, s.pages ?? 1))
        } else {
            source = .file(name: p.source?.name ?? "")
        }
        self.init(id: uuid, page: note.page, anchor: note.anchor, image: p.image, caption: p.caption,
                  display: p.display.flatMap { NoteDisplay(rawValue: $0) } ?? .tap,
                  source: source, card: p.card, createdAt: note.createdAt, updatedAt: note.updatedAt)
    }
}
