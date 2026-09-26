import Foundation

/// 画板笔记标签（`BOARD-NOTE-PLAN.md §3.1~3.2`）：装载 / 离开 / 增量对账落库。
///
/// 会话里的样子：`session.pdf == nil`、`session.board = 这篇`、`scratchPads = [board.asPad]`、
/// `openPadID = board.id`。草稿纸那条链路（`AppModel+Scratch`、`scratchUndo`、`ScratchPadNSView`、
/// 平板 `scratchpads`/`scratchStrokes`）原样工作；`persistScratchPads/Strokes` 看到 `isBoard` 就转到这里。
extension DocTabModel {

    /// 在本标签里打开一篇画板（侧栏点选 / 新建 / 平板 `boardOpen`）。已经开着它 → 空操作。
    func openBoard(_ id: UUID) {
        guard session.board?.id != id || staged else { return }
        if docID != nil || noteRef != nil || boardID != nil { select(nil) }   // 先把上一篇（PDF / md / 画板）结清
        guard let b = workspace.board(id: id) else { return }
        staged = false
        loadBoard(b)
        workspace.boardWasOpened(id: id)
    }

    /// 冷启动恢复画板标签：只记身份，切过去时再装（同 `stage(_:)` 的懒装载）。
    func stageBoard(_ id: UUID) {
        guard docID == nil, noteRef == nil, boardID != id else { return }
        boardID = id
        staged = true
        session.title = workspace.boards.first { $0.id == id }?.displayName ?? ""
    }

    /// `realize()` 转过来：真正装载一个被 stage 过的画板。
    func realizeBoard(_ id: UUID) {
        staged = false
        guard let b = workspace.board(id: id) else { boardID = nil; session.title = ""; return }
        loadBoard(b)
    }

    private func loadBoard(_ b: BoardNote) {
        let pages = workspace.boardPages(id: b.id)
        let (strokes, images) = workspace.boardContents(id: b.id, pages: pages)
        session.persistedBoardPages = Dictionary(uniqueKeysWithValues: pages.map { ($0.id, $0) })
        session.boardPages = pages
        session.scratchUndo.reset()
        session.inkUndo.reset()
        session.store = workspace.store
        // 🔴 对账快照先于数组赋值（同 `clearScratch` 的纪律）：否则订阅拿旧快照对账新数组，会把
        // 刚读出来的东西当成「新增」再写一遍，或把上一篇的东西当成「已删」删库。
        session.persistedBoard = b
        session.persistedScratchPads = [b.id: b.asPad]
        session.persistedScratchStrokes = Dictionary(uniqueKeysWithValues: strokes.map { ($0.id, $0) })
        session.persistedBoardImages = Dictionary(uniqueKeysWithValues: images.map { ($0.id, $0) })
        session.board = b
        session.title = b.displayName
        session.scratchLive = nil
        session.scratchPads = [b.asPad]
        session.scratchStrokes = strokes
        session.boardImages = images
        session.openPadID = b.id
        boardID = b.id
        if isActive { app.setActive(session) }
        app.sessionChanged(session)
        app.sessionDocumentChanged(session)   // 标题 / 平板 `boards.kind` 都变了
    }

    /// 离开画板（换成 PDF / md / 空标签，或关标签前）：先同步结清落库，再清状态。不是画板 → 空操作。
    func leaveBoard() {
        guard boardID != nil else { return }
        if session.isBoard {
            persistBoardRow(); persistBoardPages(); persistBoardStrokes(); persistBoardImages()
        }
        boardID = nil
        staged = false
        session.persistedBoard = nil
        session.board = nil
        session.persistedBoardPages = [:]
        session.boardPages = []
        session.persistedBoardImages = [:]
        session.boardImages = []
        clearScratch()
        session.scratchUndo.reset()
    }

    /// 这篇画板被删了（侧栏删除 / 镜像合并掉了）→ 标签退回空态。
    func closeBoardIfGone() {
        guard let bid = boardID, workspace.board(id: bid) == nil else { return }
        // 已经不在库里了：别再落库（对账会把它当新增写回去），直接清状态。
        session.persistedBoard = nil
        session.board = nil
        session.persistedBoardPages = [:]
        session.boardPages = []
        boardID = nil
        staged = false
        session.persistedBoardImages = [:]
        session.boardImages = []
        clearScratch()
        session.scratchUndo.reset()
        session.title = ""
        app.sessionDocumentChanged(session)
    }

    // MARK: - 增量对账落库

    /// 画板那一行：草稿纸那边改了名字 / 纸样 → 写回 `board_note`。
    func persistBoardRow() {
        guard var b = session.board, let pad = session.scratchPads.first(where: { $0.id == b.id }) else { return }
        b.absorb(pad)
        guard b != session.persistedBoard else { return }
        session.board = b
        session.title = b.displayName
        workspace.saveBoard(b)
        session.persistedBoard = b
    }

    /// 画板笔迹 ↔ `board_item` kind=1（同 `persistScratchStrokes` 的套路）。
    func persistBoardStrokes() {
        guard let bid = session.board?.id else { return }
        let current = session.scratchStrokes
        let currentIDs = Set(current.map(\.id))
        for st in current where session.persistedScratchStrokes[st.id] != st {
            // 分页画板：按第一个点归页、存页内坐标（`BOARD-NOTE-PLAN.md §9.1`）
            workspace.saveBoardStroke(boardId: bid, st, page: session.boardPageRef(index: session.boardPageIndex(of: st)))
        }
        for goneID in session.persistedScratchStrokes.keys where !currentIDs.contains(goneID) {
            workspace.deleteBoardItem(id: goneID)
        }
        session.persistedScratchStrokes = Dictionary(uniqueKeysWithValues: current.map { ($0.id, $0) })
    }

    /// 分页画板的页 ↔ `board_page`（v17）。删掉的页：它上面的条目在页操作里已经从数组摘掉，由另外两个对账删行。
    func persistBoardPages() {
        guard let bid = session.board?.id else { return }
        let current = session.boardPages
        let currentIDs = Set(current.map(\.id))
        for p in current where session.persistedBoardPages[p.id] != p {
            workspace.saveBoardPage(boardId: bid, p)
        }
        for goneID in session.persistedBoardPages.keys where !currentIDs.contains(goneID) {
            workspace.deleteBoardPage(id: goneID)
        }
        session.persistedBoardPages = Dictionary(uniqueKeysWithValues: current.map { ($0.id, $0) })
    }

    /// 画板图片 ↔ `board_item` kind=2；删的那张要对账图片引用（最后一处引用没了 → 进待删除）。
    func persistBoardImages() {
        guard let bid = session.board?.id else { return }
        let current = session.boardImages
        let currentIDs = Set(current.map(\.id))
        for im in current where session.persistedBoardImages[im.id] != im {
            workspace.saveBoardImage(boardId: bid, im, page: session.boardPageRef(index: session.boardPageIndex(of: im)))
        }
        for (goneID, old) in session.persistedBoardImages where !currentIDs.contains(goneID) {
            workspace.deleteBoardImage(id: goneID, image: old.image)
        }
        session.persistedBoardImages = Dictionary(uniqueKeysWithValues: current.map { ($0.id, $0) })
    }
}
