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

// MARK: - 分页模式（v17，`BOARD-NOTE-PLAN.md §9`）

/// 分页画板的背景模板（**三端契约**，线上 u8：只许尾部追加，未知值按空白画）。几何见 `BoardTemplateGeometry`。
enum BoardTemplate: String, CaseIterable, Codable {
    case blank, lined, grid, dots, cornell, twoColumn

    var code: UInt8 { UInt8(Self.allCases.firstIndex(of: self) ?? 0) }
    init(code: Int) { self = code >= 0 && code < Self.allCases.count ? Self.allCases[code] : .blank }
    init(raw: String) { self = BoardTemplate(rawValue: raw) ?? .blank }

    var label: String {
        switch self {
        case .blank: return L("Blank")
        case .lined: return L("Lined")
        case .grid: return L("Square Grid")   // 不用草稿纸底纹那个「Grid」（中文译作「小格」），分页模板统一叫「方格」
        case .dots: return L("Dots")
        case .cornell: return L("Cornell")
        case .twoColumn: return L("Two Columns")
        }
    }
}

/// 分页画板的一页。尺寸整本统一（`BoardLayout.size` 取第一页的，改尺寸时每页一起改）。
struct BoardPage: Identifiable, Equatable {
    var id: UUID = UUID()
    var sortKey: Double
    var width: Double
    var height: Double
    var template: BoardTemplate = .blank
    var createdAt: Date = .now
    var updatedAt: Date = .now
}

/// 页面尺寸预设（画布点，竖版；横版宽高对调）。「当前屏幕」由调用方现取。
enum BoardPageSize: String, CaseIterable {
    case a4, a5, letter, screen

    var label: String {
        switch self {
        case .a4: return "A4"
        case .a5: return "A5"
        case .letter: return "Letter"
        case .screen: return L("Current Screen")
        }
    }
    /// 竖版尺寸；`screen` 需要调用方传进屏幕逻辑尺寸。
    func portrait(screen: CGSize) -> CGSize {
        switch self {
        case .a4: return CGSize(width: 595, height: 842)
        case .a5: return CGSize(width: 420, height: 595)
        case .letter: return CGSize(width: 612, height: 792)
        case .screen:
            let w = max(1, min(screen.width, screen.height)), h = max(1, max(screen.width, screen.height))
            return CGSize(width: w.rounded(), height: h.rounded())
        }
    }
}

/// 分页布局契约（`BOARD-NOTE-PLAN.md §9.2`，三端一致）：页竖排、水平居中于 x = 0，
/// 第 i 页 = `(-W/2, i × (H + gap), W, H)`。运行时 / 线上用画布坐标，落库是页内坐标。
struct BoardLayout: Equatable {
    static let gap: Double = 24
    var width: Double
    var height: Double
    var count: Int

    init(pages: [BoardPage]) {
        width = pages.first?.width ?? 595
        height = pages.first?.height ?? 842
        count = pages.count
    }
    init(width: Double, height: Double, count: Int) {
        self.width = width; self.height = height; self.count = count
    }

    var stride: Double { height + Self.gap }
    func origin(_ i: Int) -> CGPoint { CGPoint(x: -width / 2, y: Double(i) * stride) }
    func rect(_ i: Int) -> CGRect { CGRect(origin: origin(i), size: CGSize(width: width, height: height)) }
    /// 全部页的包围盒（没有页 → nil）。
    var bounds: CGRect? {
        count > 0 ? CGRect(x: -width / 2, y: 0, width: width, height: Double(count) * stride - Self.gap) : nil
    }
    /// 画布 y 落在哪一页：页间空隙归上面那页，首页之上 / 末页之下夹到首 / 末页。
    func index(forY y: Double) -> Int {
        guard count > 0 else { return 0 }
        return min(max(0, Int((y / stride).rounded(.down))), count - 1)
    }
}

/// 背景模板的几何（**三端契约**，`BOARD-NOTE-PLAN.md §9.3`）：全部是页内画布点、与页面大小无关的固定间距。
/// 渲染方只管把这些线段 / 点映到屏幕（线宽细 1、粗 1.5 画布点随缩放；颜色由纸色明度推，细 α0.14、粗 α0.30）。
enum BoardTemplateGeometry {
    typealias Seg = (CGPoint, CGPoint)
    struct Shape { var thin: [Seg] = []; var bold: [Seg] = []; var dots: [CGPoint] = [] }
    static let lineGap: Double = 28, gridStep: Double = 20, dotSize: Double = 2

    static func shape(_ t: BoardTemplate, width w: Double, height h: Double) -> Shape {
        var s = Shape()
        func hLines(from y0: Double, to y1: Double, x0: Double, x1: Double) {
            var y = y0
            while y <= y1 + 0.001 { s.thin.append((CGPoint(x: x0, y: y), CGPoint(x: x1, y: y))); y += lineGap }
        }
        switch t {
        case .blank:
            break
        case .lined:
            hLines(from: 72, to: h - 36, x0: 36, x1: w - 36)
        case .grid:
            var x = gridStep
            while x < w - 0.001 { s.thin.append((CGPoint(x: x, y: 0), CGPoint(x: x, y: h))); x += gridStep }
            var y = gridStep
            while y < h - 0.001 { s.thin.append((CGPoint(x: 0, y: y), CGPoint(x: w, y: y))); y += gridStep }
        case .dots:
            var y = gridStep
            while y < h - 0.001 {
                var x = gridStep
                while x < w - 0.001 { s.dots.append(CGPoint(x: x, y: y)); x += gridStep }
                y += gridStep
            }
        case .cornell:
            let y1 = (h * 0.12).rounded(), y2 = (h * 0.80).rounded(), cx = (w * 0.30).rounded()
            s.bold.append((CGPoint(x: 0, y: y1), CGPoint(x: w, y: y1)))
            s.bold.append((CGPoint(x: 0, y: y2), CGPoint(x: w, y: y2)))
            s.bold.append((CGPoint(x: cx, y: y1), CGPoint(x: cx, y: y2)))
            hLines(from: y1 + lineGap, to: y2 - 8, x0: 0, x1: w)
        case .twoColumn:
            let mid = (w / 2).rounded()
            s.bold.append((CGPoint(x: mid, y: 48), CGPoint(x: mid, y: h - 48)))
            hLines(from: 72, to: h - 36, x0: 36, x1: mid - 12)
            hLines(from: 72, to: h - 36, x0: mid + 12, x1: w - 36)
        }
        return s
    }
}

extension BoardPage {
    init?(row: LibBoardPage) {
        guard let id = UUID(uuidString: row.id) else { return nil }
        self.init(id: id, sortKey: row.sortKey, width: row.width, height: row.height,
                  template: BoardTemplate(raw: row.template), createdAt: row.createdAt, updatedAt: row.updatedAt)
    }
    func toRow(boardId: String) -> LibBoardPage {
        LibBoardPage(id: id.uuidString, boardId: boardId, sortKey: sortKey, width: width, height: height,
                     template: template.rawValue, createdAt: createdAt, updatedAt: updatedAt)
    }
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
    /// 分页画板（v17）：所属页 id，此时 x/y/w/h 是页内坐标。
    var page: String?
    struct Src: Codable {
        var kind: String         // 目前只有 "file"
        var name: String?
    }
}

extension BoardImage {
    /// `page` 非 nil = 分页画板：写页 id，矩形换成页内坐标（`BOARD-NOTE-PLAN.md §9.1`）。
    func toItem(boardId: String, page: (id: UUID, origin: CGPoint)? = nil) -> LibBoardItem? {
        let p = BoardImagePayload(image: image, caption: caption, source: .init(kind: "file", name: sourceName),
                                  page: page?.id.uuidString)
        guard let data = try? JSONEncoder().encode(p) else { return nil }
        let r = page.map { rect.offsetBy(dx: -$0.origin.x, dy: -$0.origin.y) } ?? rect
        return LibBoardItem(id: id.uuidString, boardId: boardId, kind: Self.itemKind, rect: r,
                            payload: data, createdAt: createdAt, updatedAt: updatedAt)
    }

    /// `origin` = 分页画板上「页 id → 该页左上角」；带 `page` 而那页不在（孤儿）→ nil。
    init?(item: LibBoardItem, origin: (String) -> CGPoint? = { _ in nil }) {
        guard item.kind == Self.itemKind, let uuid = UUID(uuidString: item.id),
              let p = try? JSONDecoder().decode(BoardImagePayload.self, from: item.payload),
              !p.image.isEmpty else { return nil }
        var r = item.rect
        if let pg = p.page {
            guard let o = origin(pg.uppercased()) else { return nil }
            r = r.offsetBy(dx: o.x, dy: o.y)
        }
        self.init(id: uuid, image: p.image, rect: r, caption: p.caption ?? "",
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
