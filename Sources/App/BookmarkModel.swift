import CoreGraphics
import Foundation

/// 一条**书签**（规格见 `REQUIREMENTS.md §1.9`）：挂在「某页某处」的、带名字的定位记录，
/// 只用来「回到这里」。它不是笔记——没有正文、不铺色、不参与框选/图层/擦除，也不改 PDF 原文。
///
/// 显示上它与 PDF 自带目录**合并在同一棵树**里（`TOCListView`）：按页号挂进所在的一级目录组，
/// 没组可挂就平铺在树顶。目录是书自带的、只读的；书签是自己加的、可增删改的。
///
/// 落 `note` 表 `kind=5`（挂逻辑文档，全版本共用）。**表结构一个字没改**，于是增量对账、
/// 级联删除、`mergeDocument` 迁移、离线镜像的行指纹全部原样继承——同草稿纸笔迹 `kind=4` 的先例。
struct Bookmark: Identifiable, Equatable {
    var id: UUID = UUID()
    /// 0 基页号。
    var page: Int
    /// 页内归一化纵向位置（0 = 页顶）。一页可多枚，靠它区分先后。
    var frac: Double
    /// 名字，**必填**（新建时空白即放弃创建，见 `REQUIREMENTS.md §1.9`）。
    var title: String
    var createdAt: Date = .now
    var updatedAt: Date = .now
}

extension Bookmark {
    /// 笔记类型（对齐 `LibNote.kind`：0 text / 1 chat / 2 ink / 3 highlight / 4 scratchInk / 5 bookmark）。
    static let noteKind = 5

    /// 排序口径（**三端一致**）：页 → 页内位置 → 建立时刻。最后那道是为了同页同位置时顺序稳定，
    /// 否则每次读库出来的先后可能不一样，「第 2 个书签」就不是同一个。
    static func before(_ a: Bookmark, _ b: Bookmark) -> Bool {
        if a.page != b.page { return a.page < b.page }
        if a.frac != b.frac { return a.frac < b.frac }
        return a.createdAt < b.createdAt
    }

    /// 名字是否可用（去掉首尾空白后非空）。新建/改名两处共用同一条判据。
    static func validTitle(_ s: String) -> Bool {
        !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// 「加书签 / 改名」的待输入状态（见 `DocSession.bookmarkDraft`）。
///
/// 名字**必填**（用户 2026-09-02 拍板），所以这个动作天然分两步：先记下落点，输入并确认了
/// 才真的落进 `session.bookmarks`；取消就什么都不留下。输入框**不预填**名字，只把
/// 「所在章节 · 第 N 页」放进 placeholder 当提示——预填等于替用户按了确定，与「必须输入」相悖。
struct BookmarkDraft: Identifiable, Equatable {
    var id = UUID()
    var page: Int
    var frac: Double
    /// placeholder 提示文案（章节名 / 页码），**不是**默认值。
    var hint: String = ""
    /// 非 nil = 改这一条的名字；nil = 新建。
    var editing: UUID?
    /// 改名时带上原名（输入框的初值只有改名这一路才有）。
    var currentTitle: String = ""
}

// MARK: - 持久化（note 表，kind=5）

/// 落库到 `note.payload` 的 JSON 形态（页/页内位置走 note 的列，这里只剩名字）。
private struct BookmarkPayload: Codable {
    var title: String
}

extension Bookmark {
    /// 锚点用**点锚**：`x` 恒 0（留给将来的「指到某一处」），`y` = 页内比例，宽高 0。
    /// 与文字注解的点注解同款，读回来时只认 `minY`。
    func toNote(documentId: String) -> LibNote? {
        guard let data = try? JSONEncoder().encode(BookmarkPayload(title: title)) else { return nil }
        return LibNote(id: id.uuidString, documentId: documentId, kind: Self.noteKind,
                       page: page,
                       anchor: CGRect(x: 0, y: frac, width: 0, height: 0),
                       payload: data, createdAt: createdAt, updatedAt: updatedAt)
    }

    init?(note: LibNote) {
        guard note.kind == Bookmark.noteKind,
              let uuid = UUID(uuidString: note.id),
              let p = try? JSONDecoder().decode(BookmarkPayload.self, from: note.payload)
        else { return nil }
        self.init(id: uuid, page: note.page, frac: note.anchor.minY, title: p.title,
                  createdAt: note.createdAt, updatedAt: note.updatedAt)
    }
}

// MARK: - 会话上的增删改

/// 三个动作都只改 `session.bookmarks`，落库交给 `DocTabModel` 的增量对账（同高亮/注解的惯例）。
/// **列表恒有序**：每次写完重排一次，`TOCListView` 的合并算法据此可以一趟扫完。
extension DocSession {
    /// 新建。名字为空白一律不落（「必填」这条判据只在这里守一次，UI 的禁用只是提前反馈）。
    @discardableResult
    func addBookmark(page: Int, frac: Double, title: String) -> Bookmark? {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        let b = Bookmark(page: page, frac: frac, title: t)
        bookmarks.append(b)
        bookmarks.sort(by: Bookmark.before)
        return b
    }

    func renameBookmark(id: UUID, to title: String) {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, let i = bookmarks.firstIndex(where: { $0.id == id }) else { return }
        bookmarks[i].title = t
        bookmarks[i].updatedAt = .now
    }

    func deleteBookmark(id: UUID) {
        bookmarks.removeAll { $0.id == id }
    }

    // MARK: 三个入口共用的「起草」

    /// 在指定落点加书签 → 弹命名框。右键「在此添加书签」走这条（落点 = 右键处）。
    func beginBookmark(page: Int, frac: Double) {
        bookmarkDraft = BookmarkDraft(page: page, frac: frac, hint: bookmarkHint(page: page))
    }

    /// 在**当前阅读位置**加书签 → 弹命名框。⌘D 与 Inspector 目录页的 `+` 走这条。
    /// 位置取 `currentMark`（滚动锚点，比 `currentPageIndex` 多一个页内比例，回来才回得准）。
    func beginBookmarkAtCurrent() {
        let m = currentMark
        beginBookmark(page: m.page, frac: m.frac)
    }

    /// 改名：初值是原名，落点不变。
    func beginBookmarkRename(_ b: Bookmark) {
        bookmarkDraft = BookmarkDraft(page: b.page, frac: b.frac, hint: bookmarkHint(page: b.page),
                                      editing: b.id, currentTitle: b.title)
    }

    /// 命名框上那行落点回显：「所在章节 · 第 N 页」（没有目录/没命中章节就只有页码）。
    /// 它是**提示**不是默认值——名字必填这条由 `BookmarkNameSheet` 的确定键守着。
    private func bookmarkHint(page: Int) -> String {
        let pageText = String(format: L("Page %d"), page + 1)
        let chapter = TOCEntry.chapterLabel(for: page, in: toc)
        return chapter.isEmpty ? pageText : "\(chapter) · \(pageText)"
    }

    /// 命名框确认：新建或改名（`BookmarkDraft.editing` 区分），完了清掉草稿。
    func commitBookmarkDraft(title: String) {
        guard let d = bookmarkDraft else { return }
        if let id = d.editing {
            renameBookmark(id: id, to: title)
        } else {
            addBookmark(page: d.page, frac: d.frac, title: title)
        }
        bookmarkDraft = nil
    }
}
