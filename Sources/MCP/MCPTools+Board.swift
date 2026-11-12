import Foundation

/// 画板笔记的工具（`BOARD-NOTE-PLAN.md §10`，2026-11-12）：`list_boards` / `render_board` / `open_board`。只读 + 导航。
extension MCPTools {

    static func listBoards() -> MCPTool {
        MCPTool(
            name: "list_boards",
            title: "List boards",
            description: "Boards (画板笔记) in a workspace: handwritten whiteboards, either one infinite canvas or a stack of pages. Each has a board_id for render_board (to look at the handwriting) and open_board.",
            inputSchema: MCPSchema.object([
                "workspace": MCPSchema.string("Workspace .unrd path. Default: the key window's workspace."),
            ]),
            outputSchema: MCPSchema.object([
                "workspace": workspaceDTOSchema,
                "boards": MCPSchema.array(of: MCPSchema.object([
                    "board_id": MCPSchema.string("id"), "title": MCPSchema.string("title"), "group": MCPSchema.string("sidebar group, \"\" = none"),
                    "mode": MCPSchema.enumeration(["infinite", "paged"], "one infinite canvas or pages"),
                    "page_count": MCPSchema.integer("pages (0 for infinite)"),
                    "items": MCPSchema.integer("strokes and images on it"),
                    "updated_at": MCPSchema.nullable(MCPSchema.string("ISO 8601")),
                    "last_opened_at": MCPSchema.nullable(MCPSchema.string("ISO 8601")),
                    "is_open": MCPSchema.boolean("open in a tab now"),
                ])),
            ]),
            tier: .read
        ) { _, args in
            let ws = try args.string("workspace")
            let r = try await MainActor.run { try MCPFacade.shared.boardsList(workspacePath: ws) }
            let rows = (r["boards"] as? [MCPObject]) ?? []
            let lines = rows.map { b -> String in
                let mode = (b["mode"] as? String) == "paged" ? "\(b["page_count"] ?? 0) page(s)" : "infinite"
                return "- “\(b["title"] ?? "")” [\((b["board_id"] as? String ?? "").prefix(8))] · \(mode) · \(b["items"] ?? 0) item(s)"
                    + ((b["is_open"] as? Bool) == true ? " · open" : "")
            }
            return MCPToolResult(text: rows.isEmpty ? "No boards in this workspace." : (["\(rows.count) board(s):"] + lines).joined(separator: "\n"),
                                 structured: r)
        }
    }

    static func renderBoard() -> MCPTool {
        MCPTool(
            name: "render_board",
            title: "Render a board image",
            description: "Render a board (画板笔记) as an image so a vision-capable model can read the user's handwriting and drawings: one page of a paged board, or the whole drawn area of an infinite board. Strokes not saved yet are saved first. Read-only.",
            inputSchema: MCPSchema.object([
                "board_id": MCPSchema.string("Board id from list_boards (full id or its 8-character prefix). Omit for the board open in the key window."),
                "page": MCPSchema.integer("Paged boards: page, 1-based (default 1). Infinite boards: omit.", min: 1),
                "width": MCPSchema.integer("Pixel width (default 1400, max 2400); very tall infinite boards are scaled down to stay under 16 megapixels", min: 240, max: 2400),
                "format": MCPSchema.enumeration(["jpeg", "png"], "image format", default: "jpeg"),
                "workspace": MCPSchema.string("Workspace .unrd path. Default: the open workspace that has this board."),
            ]),
            outputSchema: MCPSchema.object([
                "board_id": MCPSchema.string("id"), "title": MCPSchema.string("title"),
                "page": MCPSchema.nullable(MCPSchema.integer("page rendered, 1-based (null for infinite boards)")),
                "page_count": MCPSchema.integer("pages (0 for infinite)"),
                "strokes": MCPSchema.integer("strokes drawn in the image"),
                "width": MCPSchema.integer("pixels"), "height": MCPSchema.integer("pixels"),
                "mime": MCPSchema.string("image/jpeg or image/png"), "bytes": MCPSchema.integer("encoded size"),
            ]),
            tier: .read
        ) { _, args in
            let raw = try args.string("board_id"), page = try args.int("page"), ws = try args.string("workspace")
            let width = min(max(try args.int("width") ?? 1400, 240), 2400)
            let fmt = try args.string("format") ?? "jpeg"
            guard fmt == "jpeg" || fmt == "png" else { throw MCPInvalidParams("format must be jpeg or png") }
            let format: PageRenderer.Format = fmt == "png" ? .png : .jpeg(quality: PageRenderer.defaultJPEGQuality)
            let r = try await MainActor.run { try MCPFacade.shared.boardRenderInput(raw, page: page, workspacePath: ws) }
            let input = r.input
            guard let img = await Task.detached(priority: .userInitiated, operation: {
                MCPBoardRender.render(input, pixelWidth: width, format: format)
            }).value else { throw MCPToolError("cannot render the board") }
            let o: MCPObject = ["board_id": r.board.id.uuidString, "title": r.board.displayName,
                                "page": r.page.map { $0 as Any } ?? NSNull(), "page_count": r.pageCount,
                                "strokes": input.strokes.count, "width": img.width, "height": img.height,
                                "mime": format.contentType, "bytes": img.data.count]
            let which = r.page.map { "page \($0) of \(r.pageCount)" } ?? "whole board"
            return MCPToolResult(text: "Board “\(r.board.displayName)” · \(which) · \(input.strokes.count) stroke(s) · \(img.width)×\(img.height) \(fmt)",
                                 structured: o, image: (img.data, format.contentType))
        }
    }

    static func openBoard() -> MCPTool {
        MCPTool(
            name: "open_board",
            title: "Open a board",
            description: "Show a board (画板笔记) in a tab: switches to it if a tab already shows it, otherwise opens one in a window of its workspace.",
            inputSchema: MCPSchema.object([
                "board_id": MCPSchema.string("Board id from list_boards (full id or its 8-character prefix)."),
                "activate": MCPSchema.boolean("Bring UniReader to the front", default: true),
                "workspace": MCPSchema.string("Workspace .unrd path. Default: the open workspace that has this board."),
            ], required: ["board_id"]),
            outputSchema: MCPSchema.object([
                "board_id": MCPSchema.string("id"), "title": MCPSchema.string("title"),
                "session_id": MCPSchema.string("tab id"), "window_id": MCPSchema.string("window id"),
            ]),
            tier: .navigate
        ) { ctx, args in
            let raw = try args.requiredString("board_id"), ws = try args.string("workspace")
            let activate = try args.bool("activate", default: true)
            if ctx.fromInAppAgent, !AgentFollow.enabled { return MCPToolResult(text: AgentFollow.declined) }
            let o = try await MainActor.run { try MCPFacade.shared.openBoard(raw, workspacePath: ws, activate: activate) }
            return MCPToolResult(text: "Opened board “\(o["title"] ?? "")”", structured: o)
        }
    }
}
