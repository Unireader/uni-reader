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

    /// 新建画板时的选项（`BOARD-NOTE-PLAN.md §9.4`）。`paged == nil` = 无限画布。
    struct BoardSpec {
        var paged: (size: CGSize, template: BoardTemplate, count: Int)?
        static let infinite = BoardSpec(paged: nil)
    }

    /// 新建一篇画板：无限画布（点阵白纸），或分页（N 页同尺寸同背景）。返回 nil = 工作区没开。
    @discardableResult
    func createBoard(title: String = "", spec: BoardSpec = .infinite) -> BoardNote? {
        guard let store else { return nil }
        let now = Date.now
        var b = BoardNote(title: title, createdAt: now, updatedAt: now, lastOpenedAt: now)
        if spec.paged != nil { b.pattern = .plain }   // 分页画板的底纹由每页的模板管，纸本身不画点阵
        do {
            try store.upsertBoard(b.row)
            if let p = spec.paged {
                for i in 0..<max(1, min(p.count, 500)) {
                    let page = BoardPage(sortKey: Double(i + 1), width: Double(p.size.width), height: Double(p.size.height),
                                         template: p.template, createdAt: now, updatedAt: now)
                    try store.upsertBoardPage(page.toRow(boardId: b.id.uuidString))
                }
            }
        } catch { lastError = "\(error)"; return nil }
        refreshBoards()
        return b
    }

    /// 一篇画板的页（按顺序；空 = 无限画布）。
    func boardPages(id: UUID) -> [BoardPage] {
        ((try? store?.boardPages(boardId: id.uuidString)) ?? []).compactMap(BoardPage.init(row:))
    }
    func saveBoardPage(boardId: UUID, _ p: BoardPage) {
        try? store?.upsertBoardPage(p.toRow(boardId: boardId.uuidString))
    }
    func deleteBoardPage(id: UUID) {
        try? store?.deleteBoardPage(id: id.uuidString)
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
    /// 分页画板：页内坐标 → 画布坐标按 `pages` 的布局换算（`BOARD-NOTE-PLAN.md §9.2`）。
    func boardContents(id: UUID, pages: [BoardPage] = []) -> (strokes: [InkStroke], images: [BoardImage]) {
        let items = (try? store?.boardItems(boardId: id.uuidString)) ?? []
        let layout = BoardLayout(pages: pages)
        var origins: [String: CGPoint] = [:]
        for (i, p) in pages.enumerated() { origins[p.id.uuidString] = layout.origin(i) }
        let origin: (String) -> CGPoint? = { origins[$0] }
        var strokes: [InkStroke] = [], images: [BoardImage] = []
        for it in items {
            if it.kind == InkStroke.boardItemKind {
                if let s = InkStroke(boardItem: it, padId: id, origin: origin) { strokes.append(s) }
            } else if let im = BoardImage(item: it, origin: origin) { images.append(im) }
        }
        return (strokes, images)
    }

    /// `page` 非 nil = 分页画板：存页内坐标。
    func saveBoardStroke(boardId: UUID, _ st: InkStroke, page: (id: UUID, origin: CGPoint)? = nil) {
        guard let item = st.toBoardItem(boardId: boardId.uuidString, createdAt: .now, page: page) else { return }
        try? store?.upsertBoardItem(item)
    }

    /// 存一张画板上的图，并对账它指向的那张图（撤销删除 = 引用回来，要当场脱离待删除）。
    func saveBoardImage(boardId: UUID, _ im: BoardImage, page: (id: UUID, origin: CGPoint)? = nil) {
        guard let store, let item = im.toItem(boardId: boardId.uuidString, page: page) else { return }
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
