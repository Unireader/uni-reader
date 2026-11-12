import AppKit

/// 画板笔记（`BOARD-NOTE-PLAN.md §10`，用户 2026-11-12）：列出、出图、打开。此前 Agent 完全看不到画板。
/// 只读 + 导航：不提供改画板内容的工具（笔迹以 App 为真源）。
extension MCPFacade {

    /// 画板 id（完整 UUID 或 `list_boards` 文字里那 8 位前缀）→ 它所在的工作区与画板。
    /// 工作区：显式给的 > key 窗口的 > 哪个开着的工作区有它。
    func boardTarget(_ raw: String?, workspacePath: String?) throws -> (WorkspaceManager, BoardNote) {
        let candidates: [WorkspaceManager]
        if let p = workspacePath, !p.isEmpty { candidates = [try manager(workspacePath: p)] }
        else { candidates = ([keyController?.workspace].compactMap { $0 } + WorkspaceRegistry.shared.openManagers) }
        guard let raw, !raw.isEmpty else {
            // 没给 = key 窗口正开着的那块
            guard let c = keyController, let id = c.tabs.active.boardID, let b = c.workspace.board(id: id) else {
                throw MCPToolError("no board is active in the key window; pass board_id (see list_boards)")
            }
            return (c.workspace, b)
        }
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        for ws in candidates {
            let hits = key.count >= 8 ? ws.boards.filter { $0.id.uuidString.hasPrefix(key) } : []
            if hits.count == 1 { return (ws, hits[0]) }
            if hits.count > 1 { throw MCPToolError("board id prefix '\(raw)' matches several boards; pass the full id") }
        }
        throw MCPToolError("board '\(raw)' not found; call list_boards")
    }

    func boardsList(workspacePath: String?) throws -> MCPObject {
        let ws = try manager(workspacePath: workspacePath)
        let counts = (try? ws.store?.boardItemCounts()) ?? [:]
        let open = Set(controllers(for: ws).flatMap { $0.tabs.tabs.compactMap(\.boardID) })
        let rows: [MCPObject] = ws.boards.map { b in
            let pages = ws.boardPages(id: b.id)
            return ["board_id": b.id.uuidString, "title": b.displayName, "group": b.groupName,
                    "mode": pages.isEmpty ? "infinite" : "paged", "page_count": pages.count,
                    "items": counts[b.id.uuidString] ?? 0,
                    "updated_at": MCPJSON.iso(b.updatedAt), "last_opened_at": b.lastOpenedAt.map { MCPJSON.iso($0) as Any } ?? NSNull(),
                    "is_open": open.contains(b.id)]
        }
        return ["workspace": workspaceDTO(ws), "boards": rows]
    }

    /// `render_board` 的主线程那一半：开着它的标签先落库（新画的那几笔可能还没进库），读出全部内容，查好图片文件在哪。
    func boardRenderInput(_ raw: String?, page: Int?, workspacePath: String?) throws
        -> (input: MCPBoardRender.Input, board: BoardNote, pageCount: Int, page: Int?) {
        let (ws, b) = try boardTarget(raw, workspacePath: workspacePath)
        for c in controllers(for: ws) { for t in c.tabs.tabs where t.boardID == b.id { t.flushPersist() } }
        let pages = ws.boardPages(id: b.id)
        let (strokes, images) = ws.boardContents(id: b.id, pages: pages)
        let imgs = images.map { ($0.rect, ws.imageInfo(sha256: $0.image)?.url) }
        if pages.isEmpty {
            if let page, page != 1 { throw MCPInvalidParams("“\(b.displayName)” is an infinite board without pages; omit page") }
            guard let box = ScratchBounds.contentBounds(strokes, images: images) else {
                throw MCPToolError("“\(b.displayName)” is empty: nothing has been drawn on it yet")
            }
            let widest = strokes.map { CGFloat($0.width) }.max() ?? 0
            let area = box.insetBy(dx: -(24 + widest), dy: -(24 + widest))
            return (MCPBoardRender.Input(paper: b.bg, area: area, template: nil, strokes: strokes, images: imgs), b, 0, nil)
        }
        let p = page ?? 1
        guard (1...pages.count).contains(p) else { throw MCPInvalidParams("page must be 1…\(pages.count)") }
        let layout = BoardLayout(pages: pages)
        let rect = layout.rect(p - 1)
        let shape = BoardTemplateGeometry.shape(pages[p - 1].template, width: Double(rect.width), height: Double(rect.height))
        // 起笔在这一页的笔画（同画布的归属规则），出界的部分照画、被页面边裁掉
        let mine = strokes.filter { st in st.points.first.map { layout.index(forY: Double($0.y)) == p - 1 } ?? false }
        return (MCPBoardRender.Input(paper: b.bg, area: rect, template: (shape, rect.origin), strokes: mine, images: imgs),
                b, pages.count, p)
    }

    func openBoard(_ raw: String, workspacePath: String?, activate: Bool) throws -> MCPObject {
        let (ws, b) = try boardTarget(raw, workspacePath: workspacePath)
        guard let delegate = AppDelegate.shared else { throw MCPToolError("app is not ready") }
        let (c, tab) = try delegate.showBoard(b.id, in: ws, activate: activate)
        if activate {
            NSApp.activate(ignoringOtherApps: true)
            c.window?.makeKeyAndOrderFront(nil)
        }
        return ["board_id": b.id.uuidString, "title": b.displayName, "session_id": tab.id.uuidString,
                "window_id": c.windowId.uuidString]
    }
}
