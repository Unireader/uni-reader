import Foundation
import CoreGraphics

/// 画板笔记（`BOARD-NOTE-PLAN.md`）：工作区里一篇独立的无限白板，与 PDF、Markdown 笔记平级。
///
/// 运行时的做法：画板标签的 `DocSession` 没有 PDF，只有**一张永远开着的草稿纸**——
/// `scratchPads = [board.asPad]`、`openPadID = 画板 id`、笔迹的 `padId = 画板 id`。
/// 于是草稿纸的整条链路（本机落笔 / 擦除 / 框选 / 撤销 / 平板下行 `scratchpads`+`scratchStrokes` /
/// 平板上行 `ink`/`erase`）一行不改地复用；只有落库改写 `board_note` / `board_item`（`DocTabModel+Board`）。
///
/// 画布坐标系、笔宽、橡皮 ×800、网格步长与草稿纸是**同一份契约**（`PROTOCOL.md §4.4`）。
struct BoardNote: Identifiable, Equatable {
    var id: UUID = UUID()
    var title: String = ""
    var bg: InkColor = .paper
    var pattern: ScratchPattern = .dots
    var groupName: String = ""
    var createdAt: Date = .now
    var updatedAt: Date = .now
    var lastOpenedAt: Date?

    /// 侧栏选中键 / 标签持久化键的前缀（与 PDF 的 docID、Markdown 的 `md:` 区分开）。
    static let rowPrefix = "board:"

    /// 列表 / 标签上显示的名字（没起名 = 「未命名画板」）。
    var displayName: String { title.isEmpty ? L("Untitled Board") : title }

    /// 会话里扮演的那张草稿纸：没有锚点、没有页面底图（`showPage = false`），id 就是画板 id。
    var asPad: ScratchPad {
        ScratchPad(id: id, title: title, anchorPage: 0, anchorX: 0.5, anchorY: 0.5,
                   bg: bg, pattern: pattern, showPage: false, createdAt: createdAt, updatedAt: updatedAt)
    }

    /// 草稿纸那边改了名字 / 纸样 → 写回画板（其余字段不动）。
    mutating func absorb(_ pad: ScratchPad) {
        title = pad.title
        bg = pad.bg
        pattern = pad.pattern
        updatedAt = pad.updatedAt
    }
}

/// 画板上的一张图（`board_item` kind=2）。图片本体沿用图片笔记那套 `Images/<sha>.<ext>` + `image` 表。
/// `rect` = 画布坐标（逻辑点，左上原点）；层序在笔迹之下（笔迹永远能写在图上）。
struct BoardImage: Identifiable, Equatable {
    var id: UUID = UUID()
    var image: String            // sha256
    var rect: CGRect
    var caption: String = ""
    /// 原文件名（纯展示；剪贴板来的为空串）。
    var sourceName: String = ""
    var createdAt: Date = .now
    var updatedAt: Date = .now

    /// `board_item.kind`。与 `LibraryStore.boardImageKind` 是同一个数（那边算引用计数的 SQL 要用）。
    static let itemKind = 2
    /// 新加进来的图默认最长边（画布点）：大图不至于一贴进来就铺满好几屏。
    static let defaultMaxSide: CGFloat = 400
}

// MARK: - 持久化

extension BoardNote {
    init(row: LibBoard) {
        self.init(id: UUID(uuidString: row.id) ?? UUID(), title: row.title,
                  bg: InkColor.parse(row.bg), pattern: ScratchPattern(rawValue: row.pattern) ?? .dots,
                  groupName: row.groupName, createdAt: row.createdAt, updatedAt: row.updatedAt,
                  lastOpenedAt: row.lastOpenedAt)
    }

    var row: LibBoard {
        LibBoard(id: id.uuidString, title: title, bg: bg.cssRGBA, pattern: pattern.rawValue,
                 groupName: groupName, createdAt: createdAt, updatedAt: updatedAt, lastOpenedAt: lastOpenedAt)
    }
}

/// 图片条目 payload 的 JSON 形态（键名是跨端契约，`BOARD-NOTE-PLAN.md §2.3`）。
private struct BoardImagePayload: Codable {
    var image: String
    var caption: String?
    var source: Src?
    struct Src: Codable {
        var kind: String         // 目前只有 "file"
        var name: String?
    }
}

extension BoardImage {
    func toItem(boardId: String) -> LibBoardItem? {
        let p = BoardImagePayload(image: image, caption: caption, source: .init(kind: "file", name: sourceName))
        guard let data = try? JSONEncoder().encode(p) else { return nil }
        return LibBoardItem(id: id.uuidString, boardId: boardId, kind: Self.itemKind, rect: rect,
                            payload: data, createdAt: createdAt, updatedAt: updatedAt)
    }

    init?(item: LibBoardItem) {
        guard item.kind == Self.itemKind, let uuid = UUID(uuidString: item.id),
              let p = try? JSONDecoder().decode(BoardImagePayload.self, from: item.payload),
              !p.image.isEmpty else { return nil }
        self.init(id: uuid, image: p.image, rect: item.rect, caption: p.caption ?? "",
                  sourceName: p.source?.name ?? "", createdAt: item.createdAt, updatedAt: item.updatedAt)
    }

    /// 按图片像素尺寸定一个默认显示矩形：最长边不超过 `defaultMaxSide`，中心落在 `center`。
    static func placed(width: Int, height: Int, center: CGPoint) -> CGRect {
        let w = CGFloat(max(width, 1)), h = CGFloat(max(height, 1))
        let s = min(1, defaultMaxSide / max(w, h))
        let sz = CGSize(width: w * s, height: h * s)
        return CGRect(x: center.x - sz.width / 2, y: center.y - sz.height / 2, width: sz.width, height: sz.height)
    }
}

extension ScratchBounds {
    /// 画板的内容包围盒 = 笔迹 ∪ 图片（软边界 / 适应内容 / minimap 共用）。
    static func contentBounds(_ strokes: [InkStroke], images: [BoardImage]) -> CGRect? {
        var r = contentBounds(strokes)
        for im in images { r = r.map { $0.union(im.rect) } ?? im.rect }
        return r
    }
}
