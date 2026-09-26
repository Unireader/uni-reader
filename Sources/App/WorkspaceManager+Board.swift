import Foundation

/// 画板笔记的执行层（`BOARD-NOTE-PLAN.md §3`）：`board_note` / `board_item` 两张表的读写 + 侧栏列表。
/// 运行时的增量对账在 `DocTabModel+Board`，这里只做「一行一行地存 / 删」。
extension WorkspaceManager {

    /// 重读画板列表（侧栏与平板 `boards` 广播用）。增删改名、改纸样之后调；落笔不调。
    func refreshBoards() {
        let list = ((try? store?.boards()) ?? []).map(BoardNote.init(row:))
        if list != boards { boards = list }
    }

    func board(id: UUID) -> BoardNote? {
        ((try? store?.board(id: id.uuidString)) ?? nil).map(BoardNote.init(row:))
    }

    /// 新建一篇空画板（点阵白纸）。返回 nil = 工作区没开。
    @discardableResult
    func createBoard(title: String = "") -> BoardNote? {
        guard let store else { return nil }
        let now = Date.now
        let b = BoardNote(title: title, createdAt: now, updatedAt: now, lastOpenedAt: now)
        do { try store.upsertBoard(b.row) } catch { lastError = "\(error)"; return nil }
        refreshBoards()
        return b
    }

    /// 存画板那一行（改名 / 改纸样）。
    func saveBoard(_ b: BoardNote) {
        try? store?.upsertBoard(b.row)
        refreshBoards()
    }

    func renameBoard(id: UUID, title: String) {
        guard var b = board(id: id) else { return }
        b.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        b.updatedAt = .now
        saveBoard(b)
    }

    /// 记「最近打开」（侧栏排序用；不改 `updated_at`）。
    func boardWasOpened(id: UUID) {
        try? store?.touchBoardOpened(id: id.uuidString)
        refreshBoards()
    }

    /// 读一篇画板上的全部东西。笔迹的 `padId` 填画板 id（会话里它就是那张永远开着的草稿纸）。
    func boardContents(id: UUID) -> (strokes: [InkStroke], images: [BoardImage]) {
        let items = (try? store?.boardItems(boardId: id.uuidString)) ?? []
        var strokes: [InkStroke] = [], images: [BoardImage] = []
        for it in items {
            if it.kind == InkStroke.boardItemKind, let s = InkStroke(boardItem: it, padId: id) { strokes.append(s) }
            else if let im = BoardImage(item: it) { images.append(im) }
        }
        return (strokes, images)
    }

    func saveBoardStroke(boardId: UUID, _ st: InkStroke) {
        guard let item = st.toBoardItem(boardId: boardId.uuidString, createdAt: .now) else { return }
        try? store?.upsertBoardItem(item)
    }

    /// 存一张画板上的图，并对账它指向的那张图（撤销删除 = 引用回来，要当场脱离待删除）。
    func saveBoardImage(boardId: UUID, _ im: BoardImage) {
        guard let store, let item = im.toItem(boardId: boardId.uuidString) else { return }
        try? store.upsertBoardItem(item)
        try? store.reconcileImageOrphans(only: [im.image])
    }

    func deleteBoardItem(id: UUID) {
        try? store?.deleteBoardItem(id: id.uuidString)
    }

    func deleteBoardImage(id: UUID, image sha: String) {
        guard let store else { return }
        try? store.deleteBoardItem(id: id.uuidString)
        try? store.reconcileImageOrphans(only: [sha])
    }
}
