import CoreGraphics
import Foundation

/// **自建目录**的一项（`TOC-REVIEW-PLAN.md §2`）：不改 PDF，目录存在工作区库里。
/// PDF 没有目录（扫描书最常见）时用户手动加，或让 Agent 读页面后经 MCP `set_toc` 整份写入。
///
/// 落 `note` 表 `kind=7`（挂逻辑文档，全版本共用），一项一行：页 / 页内位置走 note 的列，
/// payload 只放 `{title, level, seq}`。**表结构一个字没改**，于是同步、离线镜像、回收站、
/// 级联删除全部原样继承（同书签 `kind=5` 的先例）。旧版各端只按指定 kind 读 note 表，多出来的行看不见、也不碰。
///
/// 树形不另存父子关系：按「页 → 页内位置 → seq」排好后，`level`（0 = 第一级）就是先序拍平里的深度，
/// 用栈还原成树（`entries(_:)`）。
struct CustomTOCItem: Identifiable, Equatable {
    var id: UUID = UUID()
    /// 0 基页号。
    var page: Int
    /// 页内归一化纵向位置（0 = 页顶）。
    var frac: Double
    /// 层级：0 = 第一级，最多 `maxLevel`。
    var level: Int
    var title: String
    /// 同一位置上几项的先后（Agent 一次写一整份时 = 列表里的序号；手动加 = 当前最大值 + 1）。
    var seq: Int = 0
    var createdAt: Date = .now
    var updatedAt: Date = .now

    static let noteKind = 7
    static let maxLevel = 5

    /// 排序口径：页 → 页内位置 → seq → 建立时刻。
    static func before(_ a: CustomTOCItem, _ b: CustomTOCItem) -> Bool {
        if a.page != b.page { return a.page < b.page }
        if a.frac != b.frac { return a.frac < b.frac }
        if a.seq != b.seq { return a.seq < b.seq }
        return a.createdAt < b.createdAt
    }

    static func validTitle(_ s: String) -> Bool { !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

private struct CustomTOCPayload: Codable {
    var title: String
    var level: Int
    var seq: Int?
}

extension CustomTOCItem {
    func toNote(documentId: String) -> LibNote? {
        guard let data = try? JSONEncoder().encode(CustomTOCPayload(title: title, level: level, seq: seq)) else { return nil }
        return LibNote(id: id.uuidString, documentId: documentId, kind: Self.noteKind, page: page,
                       anchor: CGRect(x: 0, y: frac, width: 0, height: 0),
                       payload: data, createdAt: createdAt, updatedAt: updatedAt)
    }

    init?(note: LibNote) {
        guard note.kind == Self.noteKind, let uuid = UUID(uuidString: note.id),
              let p = try? JSONDecoder().decode(CustomTOCPayload.self, from: note.payload) else { return nil }
        self.init(id: uuid, page: note.page, frac: min(max(0, note.anchor.minY), 1),
                  level: min(max(0, p.level), Self.maxLevel), title: p.title, seq: p.seq ?? 0,
                  createdAt: note.createdAt, updatedAt: note.updatedAt)
    }

    /// 排好序的条目 → 目录树（`TOCEntry` 的 id 就用条目 id，界面据此认出「这是自建的哪一项」）。
    /// level 跳级（第一级后面直接跟第三级）照样挂在前一项下面，只是深一层。
    static func entries(_ items: [CustomTOCItem]) -> [TOCEntry] {
        final class Box { var e: TOCEntry; var kids: [Box] = []; init(_ e: TOCEntry) { self.e = e } }
        var roots: [Box] = []
        var stack: [(level: Int, box: Box)] = []
        for it in items.sorted(by: before) {
            let b = Box(TOCEntry(id: it.id, label: it.title, pageIndex: it.page, frac: it.frac, children: []))
            while let last = stack.last, last.level >= it.level { stack.removeLast() }
            if let parent = stack.last?.box { parent.kids.append(b) } else { roots.append(b) }
            stack.append((it.level, b))
        }
        func freeze(_ b: Box) -> TOCEntry { var e = b.e; e.children = b.kids.map(freeze); return e }
        return roots.map(freeze)
    }

    /// PDF 自带目录 → 一份可以改的自建目录（「从 PDF 目录复制」）。坏书签（没有页）跳过。
    static func copy(from toc: [TOCEntry]) -> [CustomTOCItem] {
        var out: [CustomTOCItem] = []
        func walk(_ list: [TOCEntry], _ depth: Int) {
            for e in list {
                if let p = e.pageIndex {
                    out.append(CustomTOCItem(page: p, frac: e.frac, level: min(depth, maxLevel),
                                             title: e.label.isEmpty ? "—" : e.label, seq: out.count))
                }
                walk(e.children, depth + 1)
            }
        }
        walk(toc, 0)
        return out
    }

    /// 在某个位置新加一项时默认的层级：与它前面最近的那一项同级（没有就第一级）。
    static func defaultLevel(page: Int, frac: Double, in items: [CustomTOCItem]) -> Int {
        items.sorted(by: before).last { $0.page < page || ($0.page == page && $0.frac <= frac) }?.level ?? 0
    }
}
