import AppKit
import CryptoKit
import Foundation

/// 🔴 全项目**唯一**碰 App 活状态的 MCP 入口（方案 §5.1 / §5.3 第 3 条）：把 `AppDelegate` 的窗口、
/// `TabsModel` 的标签、`DocSession`、`WorkspaceManager` / `WorkspaceRegistry` 拼成给 Agent 的 DTO。
/// 全部 `@MainActor`，工具从自己的队列 `await MainActor.run { … }` 进来；**这里只拼装、不遍历笔迹点、不读 PDF**。
@MainActor
final class MCPFacade {
    static let shared = MCPFacade()

    // MARK: - 窗口

    private var controllers: [ReaderWindowController] { AppDelegate.shared?.readerWindowControllers ?? [] }

    /// key 窗口；没有 key 的（App 不在前台）取最靠前那扇；一扇都没有 → nil。
    private var keyController: ReaderWindowController? {
        let all = controllers
        if let k = all.first(where: { $0.window?.isKeyWindow == true }) { return k }
        let order = NSApp.orderedWindows
        return all.min { a, b in
            (a.window.flatMap { order.firstIndex(of: $0) } ?? .max) < (b.window.flatMap { order.firstIndex(of: $0) } ?? .max)
        }
    }

    private func controller(windowId: String) throws -> ReaderWindowController {
        guard let c = controllers.first(where: { $0.windowId.uuidString == windowId }) else {
            throw MCPToolError("window '\(windowId)' not found; call get_state for current window ids")
        }
        return c
    }

    private func controllers(for ws: WorkspaceManager) -> [ReaderWindowController] {
        controllers.filter { $0.workspace === ws }
    }

    /// 目标工作区：给了路径就要它（必须已开着，方案 §7.4 红线）；没给 = key 窗口的那个。
    private func manager(workspacePath: String?) throws -> WorkspaceManager {
        if let p = workspacePath, !p.isEmpty {
            let url = URL(fileURLWithPath: (p as NSString).expandingTildeInPath)
            guard let m = WorkspaceRegistry.shared.openManager(at: url) else {
                throw MCPToolError("workspace is not open: \(p); call open_workspace first")
            }
            return m
        }
        guard let c = keyController else {
            throw MCPToolError("no reader window is open; call open_workspace first")
        }
        return c.workspace
    }

    // MARK: - DTO

    private func workspaceDTO(_ ws: WorkspaceManager) -> MCPObject {
        ["id": ws.store?.meta("workspace_id") ?? "",
         "name": ws.name,
         "path": ws.folder?.path ?? "",
         "is_mirror": ws.isMirror]
    }

    private func markdownDTO(_ ws: WorkspaceManager, _ ref: NoteRef, includeText: Bool) -> MCPObject {
        let source = ws.noteSource(id: ref.sourceID)
        let fileExists = ws.noteURL(ref).map { FileManager.default.fileExists(atPath: $0.path) } ?? false
        var o: MCPObject = ["ref": ref.key,
                            "title": ref.title,
                            "source": source?.name ?? ref.sourceID,
                            "source_kind": source?.kind.rawValue ?? "unknown",
                            "relative_path": ref.relPath,
                            "link": link(ws, markdown: ref.key),
                            "file_missing": !fileExists]
        if includeText {
            let text = liveMarkdown(ws, ref).text ?? ""
            o["text"] = text
            o["revision"] = Self.markdownRevision(text)
            o["line_count"] = MCPMarkdownText.lineCount(text)
        }
        return o
    }

    static func markdownRevision(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Markdown 笔记（read_markdown / edit_markdown / update_markdown）

    /// 要读写哪一篇：
    /// - 给了 `note_ref`（`NoteRef.key` / 库行 UUID / 笔记名字，同 `unireader://…&md=`）→ 就是它，**不必开着**；
    ///   工作区 = `workspace` > `window_id` 那扇 > key 编辑区所在 > key 阅读窗；
    /// - 没给 → `window_id` 那扇的活动标签；再没给 → key 窗口里的编辑区（含笔记小窗）；再不行 → key 阅读窗的活动标签。
    private func markdownTarget(noteRef: String?, windowId: String?, workspacePath: String?) throws -> (WorkspaceManager, NoteRef) {
        if let key = noteRef, !key.isEmpty {
            let ws: WorkspaceManager
            if let p = workspacePath, !p.isEmpty { ws = try manager(workspacePath: p) }
            else if let windowId { ws = try controller(windowId: windowId).workspace }
            else if let e = MarkdownDocView.keyEditor { ws = e.workspace }
            else { ws = try manager(workspacePath: nil) }
            if let hit = ws.note(key: key) { return (ws, hit.ref) }
            // 刚建、还没扫进清单的文件：按 key 直接认，前提是文件确实在
            if let r = NoteRef(key: key), let url = ws.noteURL(r), FileManager.default.fileExists(atPath: url.path) {
                return (ws, r)
            }
            throw MCPToolError("Markdown note '\(key)' not found in workspace “\(ws.name)”; call list_markdown_notes for valid note_ref values")
        }
        if let windowId {
            let c = try controller(windowId: windowId)
            guard let ref = c.tabs.active.noteRef else {
                throw MCPToolError("the active tab of window \(windowId) is not a Markdown note; pass note_ref (see list_markdown_notes)")
            }
            return (c.workspace, ref)
        }
        if let e = MarkdownDocView.keyEditor { return (e.workspace, e.ref) }
        guard let c = keyController else { throw MCPToolError("no reader window is open") }
        guard let ref = c.tabs.active.noteRef else {
            throw MCPToolError("no Markdown note is active; pass note_ref (see list_markdown_notes / get_state)")
        }
        return (c.workspace, ref)
    }

    /// 这篇此刻的正文：开在编辑器里就取编辑器里的（含还没走完 0.8 秒自动保存的输入），否则读文件。
    /// `conflict` = 同一篇开在好几个编辑器里、各自的未保存正文不一样（此时不许写）。
    private func liveMarkdown(_ ws: WorkspaceManager, _ ref: NoteRef) -> (text: String?, editors: [MarkdownDocView], conflict: Bool) {
        let editors = MarkdownDocView.editors(showing: ref, in: ws)
        let texts = editors.map(\.currentText)
        if let first = texts.first {
            // key 窗口里那份优先（用户正在打字的就是它）
            let key = editors.first { $0.window?.isKeyWindow == true }?.currentText ?? first
            return (key, editors, Set(texts).count > 1)
        }
        return (ws.noteBody(ref), [], false)
    }

    /// 写入前的共同检查：读得到、没有多份不一致的未保存正文、revision 对得上（给了的话）。
    private func markdownForWrite(_ ws: WorkspaceManager, _ ref: NoteRef, expectedRevision: String?) throws -> (String, [MarkdownDocView]) {
        let live = liveMarkdown(ws, ref)
        guard let current = live.text else {
            throw MCPToolError("the Markdown file cannot be read; it may have been moved or deleted")
        }
        guard !live.conflict else {
            throw MCPToolError("this note is open in several editors with different unsaved edits; ask the user to resolve them before writing")
        }
        if let expectedRevision, !expectedRevision.isEmpty, expectedRevision != Self.markdownRevision(current) {
            throw MCPToolError("the Markdown note changed after it was read; call read_markdown again, merge the user's latest text, and retry")
        }
        return (current, live.editors)
    }

    /// 原子写文件 + 推回所有正显示这篇的编辑器（防它们稍后的自动保存把 Agent 的改动盖回去）。
    private func commitMarkdown(_ ws: WorkspaceManager, _ ref: NoteRef, old: String, new: String,
                                editors: [MarkdownDocView]) throws {
        guard old == new || ws.saveNoteBody(ref, text: new) else {
            throw MCPToolError(ws.lastError ?? "failed to save the Markdown note")
        }
        for e in editors { e.applySavedText(new) }
    }

    private func markdownWriteResult(_ ws: WorkspaceManager, _ ref: NoteRef, _ text: String) -> MCPObject {
        ["ref": ref.key,
         "title": ref.title,
         "link": link(ws, markdown: ref.key),
         "revision": Self.markdownRevision(text),
         "characters": text.count,
         "line_count": MCPMarkdownText.lineCount(text)]
    }

    /// 笔记清单（给 `note_ref` 用）。`folder` 按源内相对路径前缀筛，`query` 按标题 / 路径子串筛。
    func markdownNotes(workspacePath: String?, source: String?, folder: String?, query: String?, limit: Int) throws -> MCPObject {
        let ws = try manager(workspacePath: workspacePath)
        let open = Set(controllers(for: ws).compactMap { $0.tabs.active.noteRef })
        var notes = ws.allNotes
        if let source, !source.isEmpty {
            notes = notes.filter { n in n.ref.sourceID == source || ws.noteSource(id: n.ref.sourceID)?.name == source }
        }
        if let folder, !folder.isEmpty {
            let f = folder.hasSuffix("/") ? folder : folder + "/"
            notes = notes.filter { $0.ref.relPath.hasPrefix(f) }
        }
        if let query, !query.isEmpty {
            notes = notes.filter {
                $0.title.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
                    || $0.ref.relPath.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
            }
        }
        let total = notes.count
        let rows: [MCPObject] = notes.prefix(limit).map { n in
            let src = ws.noteSource(id: n.ref.sourceID)
            return ["ref": n.ref.key, "title": n.title,
                    "source": src?.name ?? n.ref.sourceID,
                    "source_kind": src?.kind.rawValue ?? "unknown",
                    "relative_path": n.ref.relPath,
                    "link": link(ws, markdown: n.ref.key),
                    "is_active_tab": open.contains(n.ref)]
        }
        return ["workspace": workspaceDTO(ws),
                "sources": ws.noteSources.map { ["id": $0.id, "name": $0.name, "kind": $0.kind.rawValue] as MCPObject },
                "notes": rows, "total": total, "truncated": total > rows.count]
    }

    enum MarkdownReadMode {
        case lines(offset: Int, limit: Int)
        case search(query: String, caseSensitive: Bool)
        case outline
    }

    static let markdownReadMaxChars = 60_000
    static let markdownSearchMaxHits = 200

    /// `read_markdown`：按行分页（带行号）/ 行内搜索 / 标题大纲。
    func readMarkdown(noteRef: String?, windowId: String?, workspacePath: String?,
                      mode: MarkdownReadMode) throws -> (json: MCPObject, text: String) {
        let (ws, ref) = try markdownTarget(noteRef: noteRef, windowId: windowId, workspacePath: workspacePath)
        let live = liveMarkdown(ws, ref)
        guard let text = live.text else {
            throw MCPToolError("the Markdown file for “\(ref.title)” cannot be read; it may have been moved or deleted")
        }
        let total = MCPMarkdownText.lineCount(text)
        let unsaved = !live.editors.isEmpty && ws.noteBody(ref) != text
        var o = markdownDTO(ws, ref, includeText: false)
        o["revision"] = Self.markdownRevision(text)
        o["line_count"] = total
        o["characters"] = text.count
        o["open_in_editor"] = !live.editors.isEmpty
        o["unsaved_edits"] = unsaved
        var head = "“\(ref.title)” · note_ref \(ref.key) · \(total) lines · revision \(o["revision"] ?? "")"
        if unsaved { head += " · includes edits not autosaved yet" }
        var body: String
        switch mode {
        case let .lines(offset, limit):
            let p = MCPMarkdownText.page(text, offset: offset, limit: limit, maxChars: Self.markdownReadMaxChars)
            o["mode"] = "lines"
            o["start_line"] = p.startLine
            o["end_line"] = p.endLine
            o["truncated"] = p.truncated
            o["next_offset"] = p.truncated ? p.endLine + 1 : NSNull()
            o["text"] = p.text
            if total == 0 { body = "(the note is empty)" }
            else if p.startLine == 0 { body = "(offset \(offset) is past the end; the note has \(total) lines)" }
            else {
                body = "Lines \(p.startLine)-\(p.endLine) of \(total):\n\(p.numbered)"
                if p.truncated { body += "\n… more lines follow; call read_markdown with offset \(p.endLine + 1)" }
            }
        case let .search(query, caseSensitive):
            let r = MCPMarkdownText.search(text, query: query, caseSensitive: caseSensitive, limit: Self.markdownSearchMaxHits)
            o["mode"] = "search"
            o["match_count"] = r.total
            o["matches"] = r.hits.map { ["line": $0.line, "text": $0.text] as MCPObject }
            if r.hits.isEmpty { body = "No line contains “\(query)”." }
            else {
                body = "\(r.total) matching line(s) for “\(query)”:\n"
                    + r.hits.map { MCPMarkdownText.numbered([Substring($0.text)], firstLine: $0.line) }.joined(separator: "\n")
                if r.total > r.hits.count { body += "\n… \(r.total - r.hits.count) more; narrow the query" }
                body += "\nUse offset/limit around these line numbers to read context."
            }
        case .outline:
            let hs = MCPMarkdownText.outline(text)
            o["mode"] = "outline"
            o["headings"] = hs.map { ["line": $0.line, "level": $0.level, "title": $0.title] as MCPObject }
            body = hs.isEmpty ? "No headings."
                : "Headings (line: title):\n" + hs.map {
                    "\($0.line): \(String(repeating: "  ", count: $0.level - 1))\(String(repeating: "#", count: $0.level)) \($0.title)"
                }.joined(separator: "\n")
        }
        return (o, head + "\n\n" + body)
    }

    /// `edit_markdown`：按原文精确匹配替换 / 按行号插入，整批原子生效。
    func editMarkdown(noteRef: String?, windowId: String?, workspacePath: String?, expectedRevision: String?,
                      edits: [MCPMarkdownText.Edit]) throws -> (json: MCPObject, text: String) {
        let (ws, ref) = try markdownTarget(noteRef: noteRef, windowId: windowId, workspacePath: workspacePath)
        let (current, editors) = try markdownForWrite(ws, ref, expectedRevision: expectedRevision)
        let result: MCPMarkdownText.EditResult
        do { result = try MCPMarkdownText.apply(edits, to: current) }
        catch let e as MCPMarkdownText.EditError {
            let which = e.index > 0 && edits.count > 1 ? "edit #\(e.index): " : ""
            throw MCPToolError("\(which)\(e.message). No change was made.")
        }
        try commitMarkdown(ws, ref, old: current, new: result.text, editors: editors)
        var o = markdownWriteResult(ws, ref, result.text)
        o["replacements"] = result.counts
        o["changed_lines"] = result.changedLines.map { [$0.lowerBound, $0.upperBound] }
        let ranges = result.changedLines.map { $0.count == 1 ? "\($0.lowerBound)" : "\($0.lowerBound)-\($0.upperBound)" }
        let snippet = MCPMarkdownText.snippet(result.text, around: result.changedLines, context: 3, maxLines: 120)
        let text = "Edited “\(ref.title)” · \(edits.count) edit(s) · changed line(s) \(ranges.joined(separator: ", ")) · revision \(o["revision"] ?? "")\n\n\(snippet)"
        return (o, text)
    }

    /// `update_markdown`：整篇替换。revision 是乐观锁：用户在 Agent 读完后又敲了字，就拒绝覆盖。
    func updateMarkdown(noteRef: String?, windowId: String?, workspacePath: String?,
                        expectedRevision: String, text: String) throws -> MCPObject {
        let (ws, ref) = try markdownTarget(noteRef: noteRef, windowId: windowId, workspacePath: workspacePath)
        let (current, editors) = try markdownForWrite(ws, ref, expectedRevision: expectedRevision)
        try commitMarkdown(ws, ref, old: current, new: text, editors: editors)
        return markdownWriteResult(ws, ref, text)
    }

    private func tabDTO(_ c: ReaderWindowController, _ tab: DocTabModel) -> MCPObject {
        let s = tab.session
        var o: MCPObject = ["session_id": tab.id.uuidString, "is_active": tab.isActive]
        if let d = tab.docID {
            o["content_type"] = "pdf"
            o["document_id"] = d
            o["title"] = tab.tabTitle
            o["page"] = PageNo.external(s.currentPageIndex)
            o["page_count"] = s.pdf?.pageCount ?? 0
            o["zoom"] = Double(s.readZoom)
            o["canvas_mode"] = s.canvasMode
            o["file_missing"] = tab.missingDoc != nil
        } else if let ref = tab.noteRef {
            o["content_type"] = "markdown"
            o["document_id"] = NSNull()
            o["title"] = ref.title
            o["markdown"] = markdownDTO(c.workspace, ref, includeText: false)
        } else {
            o["content_type"] = "empty"
            o["document_id"] = NSNull()
        }
        return o
    }

    private func windowDTO(_ c: ReaderWindowController, isKey: Bool) -> MCPObject {
        ["window_id": c.windowId.uuidString,
         "is_key": isKey,
         "workspace": workspaceDTO(c.workspace),
         "tabs": c.tabs.tabs.map { tabDTO(c, $0) }]
    }

    /// 文档的文件下落（**只探测、不写库**——`openTarget` 会刷 lastOpened，这里不用它，同 `refDocIndex` 的理由）。
    private struct FileInfo { var path: String?; var exists: Bool; var inWorkspace: Bool; var hash: String }

    private func fileInfo(_ ws: WorkspaceManager, documentId: String) -> FileInfo {
        var locs = ws.locations(documentId: documentId)
        locs.sort { $0.inWorkspace && !$1.inWorkspace }
        for l in locs {
            let abs = ws.resolvedPath(l)
            if FileManager.default.fileExists(atPath: abs) {
                let hash = (try? ws.store?.variant(id: l.variantId))??.contentHash ?? ""
                return FileInfo(path: abs, exists: true, inWorkspace: l.inWorkspace, hash: hash)
            }
        }
        if let l = locs.first {
            let hash = (try? ws.store?.variant(id: l.variantId))??.contentHash ?? ""
            return FileInfo(path: ws.resolvedPath(l), exists: false, inWorkspace: l.inWorkspace, hash: hash)
        }
        return FileInfo(path: nil, exists: false, inWorkspace: false, hash: "")
    }

    /// 哪些标签正显示这篇（跨所有窗口）。
    private func sessionsShowing(_ documentId: String) -> [DocTabModel] {
        controllers.flatMap { $0.tabs.tabs }.filter { $0.docID == documentId }
    }

    /// 回到 App 里这个位置的 `unireader://` 链接（`DeepLink`）：Agent 写进 Obsidian / 清单里，点了就回来。
    /// 带 `ws` 路径 + `wsid`（有才带，盘换了挂载点靠它找回）；`page` 对外 1 起。
    func link(_ ws: WorkspaceManager, doc: String? = nil, page: Int? = nil, frac: Double? = nil,
              note: UUID? = nil, markdown: String? = nil) -> String {
        var l = DeepLink()
        l.workspacePath = ws.folder?.path
        l.workspaceId = ws.store?.workspaceId
        l.documentId = doc
        l.page = page
        l.frac = frac
        l.noteId = note
        l.markdownId = markdown
        return l.absoluteString
    }

    private func documentDTO(_ ws: WorkspaceManager, _ d: LibDocument) -> MCPObject {
        let f = fileInfo(ws, documentId: d.id)
        return ["id": d.id,
                "link": link(ws, doc: d.id),
                "title": d.title,
                "page_count": d.pageCount,
                "group": d.group,
                "read_page": PageNo.external(d.readPage),
                "read_frac": d.readFrac,
                "last_opened_at": MCPJSON.iso(d.lastOpenedAt),
                "added_at": MCPJSON.iso(d.addedAt),
                "file": ["path": f.path ?? NSNull(), "exists": f.exists, "in_workspace": f.inWorkspace] as MCPObject,
                "content_hash": f.hash,
                "open_in": sessionsShowing(d.id).map { $0.id.uuidString }]
    }

    // MARK: - get_state

    func state(mcp: MCPServer?) -> MCPObject {
        let key = keyController
        let app = AppDelegate.shared?.appModel
        return ["app": ["version": MCPServer.appVersion,
                        "pid": Int(ProcessInfo.processInfo.processIdentifier),
                        "writes_enabled": MCPServer.allowWrites,
                        "bind": (mcp ?? app?.mcp)?.effectiveBind.rawValue ?? MCPServer.bind.rawValue,
                        "deep_link": DeepLink.formatHint] as MCPObject,
                "key_window_id": key?.windowId.uuidString ?? NSNull(),
                "windows": controllers.map { windowDTO($0, isKey: $0 === key) },
                "tablet": ["running": app?.server.isRunning ?? false,
                           "clients": app?.server.clientCount ?? 0] as MCPObject]
    }

    // MARK: - list_workspaces

    func workspaces() -> MCPObject {
        let reg = WorkspaceRegistry.shared
        var seen = Set<String>()
        var out: [MCPObject] = []
        // 开着的排前面（含不在「最近」里的）
        for m in reg.openManagers {
            guard let folder = m.folder else { continue }
            seen.insert(WorkspaceRegistry.key(folder))
            out.append(["id": m.store?.meta("workspace_id") ?? "", "name": m.name, "path": folder.path,
                        "is_open": true, "is_mirror": m.isMirror,
                        "window_ids": controllers(for: m).map { $0.windowId.uuidString }])
        }
        for r in reg.recents {
            let url = WorkspaceRegistry.resolveOrSource(r)
            let k = WorkspaceRegistry.key(url)
            if seen.contains(k) { continue }
            seen.insert(k)
            var o: MCPObject = ["id": r.id, "name": r.name, "path": r.sourcePath, "is_open": false,
                                "available": FileManager.default.fileExists(atPath: url.path),
                                "window_ids": [String]()]
            if let mp = r.mirrorPath { o["mirror_path"] = mp }
            out.append(o)
        }
        return ["workspaces": out]
    }

    // MARK: - open_workspace

    func openWorkspace(path: String, activate: Bool) throws -> MCPObject {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
        do { try WorkspaceManager.validate(url) } catch {
            throw MCPToolError("not a UniReader workspace: \(path) (\(error.localizedDescription))")
        }
        let reg = WorkspaceRegistry.shared
        if let m = reg.openManager(at: url), let c = controllers(for: m).first {
            if activate { reg.activateWindow(forWorkspace: url) }
            return ["workspace": workspaceDTO(m), "window_id": c.windowId.uuidString, "was_open": true]
        }
        guard let delegate = AppDelegate.shared else { throw MCPToolError("app is not ready") }
        let c = try delegate.makeReaderWindow(workspacePath: url.path, docId: nil, activate: activate)
        return ["workspace": workspaceDTO(c.workspace), "window_id": c.windowId.uuidString, "was_open": false]
    }

    // MARK: - list_documents

    func documents(workspacePath: String?, group: String?) throws -> MCPObject {
        let ws = try manager(workspacePath: workspacePath)
        var docs = ws.documents
        if let group { docs = docs.filter { $0.group == group } }
        return ["workspace": workspaceDTO(ws),
                "groups": ws.groups,
                "documents": docs.map { documentDTO(ws, $0) }]
    }

    // MARK: - open_document

    func openDocument(documentId: String, workspacePath: String?, windowId: String?, page: Int?, activate: Bool) throws -> MCPObject {
        // 工作区：显式给的 > 指定窗口的 > 哪个开着的工作区有这篇 > key 窗口的
        var ws: WorkspaceManager
        if let windowId {
            ws = try controller(windowId: windowId).workspace
        } else if let workspacePath, !workspacePath.isEmpty {
            ws = try manager(workspacePath: workspacePath)
        } else if let key = keyController, key.workspace.document(id: documentId) != nil {
            ws = key.workspace
        } else if let m = WorkspaceRegistry.shared.openManagers.first(where: { $0.document(id: documentId) != nil }) {
            ws = m
        } else {
            ws = try manager(workspacePath: nil)
        }
        guard let doc = ws.document(id: documentId) else {
            throw MCPToolError("document '\(documentId)' not found in workspace '\(ws.name)'; call list_documents")
        }

        let c: ReaderWindowController
        let tab: DocTabModel
        if let windowId {
            c = try controller(windowId: windowId)
            tab = c.tabs.open(documentId)
        } else {
            // 「已在显示 → 切过去；该工作区有窗 → 开标签；没窗 → 新开一扇」与 `unireader://` 链接共用
            // `AppDelegate.showDocument`，别在这里另写一份。
            guard let delegate = AppDelegate.shared else { throw MCPToolError("app is not ready") }
            (c, tab) = try delegate.showDocument(documentId, in: ws, activate: activate)
        }
        if let page {
            let count = tab.session.pdf?.pageCount ?? doc.pageCount
            let idx = try PageNo.index(page, pageCount: count)
            tab.session.jump(page: idx, frac: 0, kind: .list, label: "Agent", origin: "mcp")
        }
        if activate {
            NSApp.activate(ignoringOtherApps: true)
            c.window?.makeKeyAndOrderFront(nil)
        }
        return ["session_id": tab.id.uuidString,
                "window_id": c.windowId.uuidString,
                "document": documentDTO(ws, doc),
                "page": PageNo.external(tab.session.currentPageIndex),
                "link": link(ws, doc: doc.id, page: PageNo.external(tab.session.currentPageIndex))]
    }

    // MARK: - 读取类工具的目标解析

    /// 一次读取的目标：文件在哪、内容 hash（查 OCR 缓存用）、开着的话是哪个会话。
    struct DocTarget {
        var documentId: String?
        var title: String
        var path: String
        var contentHash: String
        var store: LibraryStore?
        var session: DocSession?
        /// 该会话当前页（`read_pages` 不给 `pages` 时的默认页）。
        var currentPage: Int?
        var workspaceName: String?
        /// 扫描页对齐参数（`SCAN-ALIGN-PLAN.md`，没开 / 库外文件为 nil）：出图、首页尺寸、命中框都按对齐后的页面。
        var align: ScanAlignTable? = nil
    }

    /// `document_id` / `path` / 都不给（= key 窗口活动标签那篇）三种写法统一解析（方案 §6.1）。
    func resolveTarget(documentId: String?, path: String?, workspacePath: String?) throws -> DocTarget {
        if let path, !path.isEmpty {
            if documentId != nil { throw MCPInvalidParams("pass either document_id or path, not both") }
            let abs = (path as NSString).expandingTildeInPath
            guard FileManager.default.fileExists(atPath: abs) else { throw MCPToolError("file not found: \(path)") }
            return DocTarget(documentId: nil, title: (abs as NSString).lastPathComponent, path: abs, contentHash: "",
                             store: nil, session: nil, currentPage: nil, workspaceName: nil)
        }
        let ws: WorkspaceManager
        let id: String
        if let documentId, !documentId.isEmpty {
            id = documentId
            if let workspacePath, !workspacePath.isEmpty {
                ws = try manager(workspacePath: workspacePath)
            } else if let key = keyController, key.workspace.document(id: id) != nil {
                ws = key.workspace
            } else if let m = WorkspaceRegistry.shared.openManagers.first(where: { $0.document(id: id) != nil }) {
                ws = m
            } else {
                throw MCPToolError("document '\(id)' not found in any open workspace; call list_documents")
            }
        } else {
            guard let key = keyController else { throw MCPToolError("no reader window is open; pass document_id or path") }
            guard let d = key.tabs.active.docID else {
                throw MCPToolError("the key window has no document open; pass document_id or path")
            }
            ws = key.workspace
            id = d
        }
        guard let doc = ws.document(id: id) else {
            throw MCPToolError("document '\(id)' not found in workspace '\(ws.name)'")
        }
        let f = fileInfo(ws, documentId: id)
        guard let p = f.path, f.exists else {
            throw MCPToolError("document '\(doc.title)' has no readable file (\(f.path ?? "no path")); re-link it in UniReader")
        }
        let tab = sessionsShowing(id).first
        let hash = tab?.session.contentHash.isEmpty == false ? tab!.session.contentHash : f.hash
        let align = tab.map { $0.session.scanAlign } ?? ws.scanAlign(contentHash: hash, pageCount: doc.pageCount)
        return DocTarget(documentId: id, title: doc.title, path: p, contentHash: hash, store: ws.store,
                         session: tab?.session, currentPage: tab?.session.currentPageIndex, workspaceName: ws.name,
                         align: align)
    }

    /// `get_document` 用：库里那一行的 DTO（库外文件没有）。
    func documentDTO(documentId: String) -> MCPObject? {
        for m in WorkspaceRegistry.shared.openManagers {
            if let d = m.document(id: documentId) { return documentDTO(m, d) }
        }
        return nil
    }

    // MARK: - get_current_view（批 2）

    func currentView(windowId: String?) throws -> MCPObject {
        let c: ReaderWindowController
        if let windowId { c = try controller(windowId: windowId) }
        else {
            guard let k = keyController else { throw MCPToolError("no reader window is open") }
            c = k
        }
        let tab = c.tabs.active
        let s = tab.session
        var o: MCPObject = ["window_id": c.windowId.uuidString,
                            "session_id": tab.id.uuidString,
                            "workspace": workspaceDTO(c.workspace)]
        if let ref = tab.noteRef {
            o["content_type"] = "markdown"
            o["document_id"] = NSNull()
            o["title"] = ref.title
            o["link"] = link(c.workspace, markdown: ref.key)
            o["markdown"] = markdownDTO(c.workspace, ref, includeText: true)
            return o
        }
        guard let docId = tab.docID else {
            o["content_type"] = "empty"
            o["document_id"] = NSNull()
            return o
        }
        o["content_type"] = "pdf"
        o["document_id"] = docId
        o["title"] = tab.tabTitle
        let page = PageNo.external(s.scrollAnchor?.page ?? s.currentPageIndex)
        let frac = s.scrollAnchor?.frac ?? 0
        o["page"] = page
        o["frac"] = frac
        o["link"] = link(c.workspace, doc: docId, page: page, frac: frac)
        o["page_count"] = s.pdf?.pageCount ?? 0
        o["zoom"] = Double(s.readZoom)
        o["canvas_mode"] = s.canvasMode
        o["file_missing"] = tab.missingDoc != nil
        if let sel = s.currentSelection, !sel.text.isEmpty, let first = sel.rects.keys.min() {
            o["selection"] = ["page": PageNo.external(first),
                              "text": sel.text,
                              "rects": (sel.rects[first] ?? []).map(Self.rectArray)] as MCPObject
        }
        if !s.toc.isEmpty {
            let chapter = TOCEntry.chapterLabel(for: s.currentPageIndex, in: s.toc)
            if !chapter.isEmpty { o["chapter"] = chapter }
        }
        return o
    }

    // MARK: - goto（批 2，导航）

    /// 找目标会话：`session_id` > `document_id`（正显示它的标签，key 窗口优先）> `window_id`（活动标签）> key 窗口活动标签。
    private func targetTab(sessionId: String?, documentId: String?, windowId: String?) throws -> (ReaderWindowController, DocTabModel) {
        if let sessionId {
            guard let uuid = UUID(uuidString: sessionId),
                  let c = controllers.first(where: { $0.tabs.owns(uuid) }),
                  let t = c.tabs.tabs.first(where: { $0.id == uuid }) else {
                throw MCPToolError("session '\(sessionId)' not found; call get_state")
            }
            return (c, t)
        }
        if let documentId {
            let showing = sessionsShowing(documentId)
            guard !showing.isEmpty else {
                throw MCPToolError("document '\(documentId)' is not open in any tab; call open_document first")
            }
            let key = keyController
            let t = showing.first { key?.tabs.owns($0.id) == true } ?? showing[0]
            guard let c = controllers.first(where: { $0.tabs.owns(t.id) }) else { throw MCPToolError("window not found") }
            return (c, t)
        }
        let c: ReaderWindowController
        if let windowId { c = try controller(windowId: windowId) }
        else {
            guard let k = keyController else { throw MCPToolError("no reader window is open") }
            c = k
        }
        return (c, c.tabs.active)
    }

    func goto(page: Int, frac: Double, sessionId: String?, documentId: String?, windowId: String?, activate: Bool) throws -> MCPObject {
        let (c, tab) = try targetTab(sessionId: sessionId, documentId: documentId, windowId: windowId)
        guard let pdf = tab.session.pdf else {
            throw MCPToolError("that tab has no document loaded")
        }
        let idx = try PageNo.index(page, pageCount: pdf.pageCount)
        let f = min(max(frac, 0), 1)
        if !tab.isActive { c.tabs.activate(tab.id) }
        tab.session.jump(page: idx, frac: f, kind: .list, label: "Agent", origin: "mcp")
        if activate {
            NSApp.activate(ignoringOtherApps: true)
            c.window?.makeKeyAndOrderFront(nil)
        }
        return ["session_id": tab.id.uuidString, "window_id": c.windowId.uuidString,
                "document_id": tab.docID ?? NSNull(), "page": page, "frac": f,
                "link": link(c.workspace, doc: tab.docID, page: page, frac: f)]
    }

    // MARK: - list_annotations（批 2）

    /// 文档开着 → 读 `DocSession` 的数组（内存真源，含节流中未落库的改动）；没开 → 读库。
    func annotations(documentId: String?, workspacePath: String?, kinds: Set<String>, pages: Set<Int>?) throws -> (json: MCPObject, text: String) {
        // 不走 `resolveTarget`：批注不需要文件在——文件丢了的文档照样有笔记
        let id: String
        if let documentId, !documentId.isEmpty { id = documentId }
        else {
            guard let key = keyController else { throw MCPToolError("no reader window is open; pass document_id") }
            guard let d = key.tabs.active.docID else { throw MCPToolError("the key window has no document open; pass document_id") }
            id = d
        }
        let ws: WorkspaceManager
        if let p = workspacePath, !p.isEmpty { ws = try manager(workspacePath: p) }
        else if let key = keyController, key.workspace.document(id: id) != nil { ws = key.workspace }
        else if let m = WorkspaceRegistry.shared.openManagers.first(where: { $0.document(id: id) != nil }) { ws = m }
        else { throw MCPToolError("document '\(id)' not found in any open workspace; call list_documents") }
        guard let doc = ws.document(id: id) else { throw MCPToolError("document '\(id)' not found in workspace '\(ws.name)'") }
        let s = sessionsShowing(id).first?.session
        func inPages(_ p: Int) -> Bool { pages?.contains(p) ?? true }

        let types = s?.noteTypes ?? ws.noteTypes()
        func typeName(_ tid: UUID?) -> Any { tid.flatMap { t in types.first { $0.id == t }?.name } ?? NSNull() }

        var out: MCPObject = ["document_id": id, "title": doc.title, "link": link(ws, doc: id)]
        var lines: [String] = ["“\(doc.title)”"]

        if kinds.contains("note") {
            let notes = (s?.textNotes ?? ws.textNotes(documentId: id)).filter { inPages($0.page) }
                .sorted { $0.page != $1.page ? $0.page < $1.page : $0.anchor.minY < $1.anchor.minY }
            out["notes"] = notes.map { n -> MCPObject in
                var o: MCPObject = ["id": n.id.uuidString, "page": PageNo.external(n.page), "rect": Self.rectArray(n.anchor),
                                    "quote": n.quote, "text": n.text, "type": typeName(n.typeId), "display": n.display.rawValue,
                                    "style": n.style.rawValue,
                                    "created_at": MCPJSON.iso(n.createdAt), "updated_at": MCPJSON.iso(n.updatedAt),
                                    "link": link(ws, doc: id, note: n.id)]
                if let c = n.color { o["color"] = Self.hex(c) }   // 显式铺色才给；没设 = 按类型色
                if let src = n.source { o["source"] = ["kind": src.kind, "provider": src.provider, "url": src.url] as MCPObject }
                return o
            }
            lines.append("Notes (\(notes.count)):")
            lines += notes.map { "- p.\(PageNo.external($0.page)) [\($0.id.uuidString.prefix(8))] “\($0.quote.flattenedQuote.prefix(60))” → \($0.text.prefix(120))" }
        }
        if kinds.contains("highlight") {
            let hs = (s?.highlights ?? ws.highlights(documentId: id)).filter { inPages($0.page) }
                .sorted { $0.page != $1.page ? $0.page < $1.page : $0.anchor.minY < $1.anchor.minY }
            out["highlights"] = hs.map { h -> MCPObject in
                ["id": h.id.uuidString, "page": PageNo.external(h.page), "rect": Self.rectArray(h.anchor),
                 "quote": h.quote, "color": Self.hex(h.color), "style": h.style.rawValue,
                 "created_at": MCPJSON.iso(h.createdAt), "link": link(ws, doc: id, note: h.id)]
            }
            lines.append("Highlights (\(hs.count)):")
            lines += hs.map { "- p.\(PageNo.external($0.page)) [\($0.id.uuidString.prefix(8))] “\($0.quote.flattenedQuote.prefix(80))”" }
        }
        if kinds.contains("bookmark") {
            let bs = (s?.bookmarks ?? ws.bookmarks(documentId: id)).filter { inPages($0.page) }.sorted(by: Bookmark.before)
            out["bookmarks"] = bs.map { b -> MCPObject in
                ["id": b.id.uuidString, "page": PageNo.external(b.page), "frac": b.frac, "title": b.title,
                 "created_at": MCPJSON.iso(b.createdAt), "link": link(ws, doc: id, note: b.id)]
            }
            lines.append("Bookmarks (\(bs.count)):")
            lines += bs.map { "- p.\(PageNo.external($0.page)) \($0.title)" }
        }
        if kinds.contains("image_note") {
            let ims = (s?.imageNotes ?? ws.imageNotes(documentId: id)).filter { inPages($0.page) }
                .sorted { $0.page != $1.page ? $0.page < $1.page : $0.anchor.minY < $1.anchor.minY }
            out["image_notes"] = ims.map { im -> MCPObject in
                var o: MCPObject = ["id": im.id.uuidString, "page": PageNo.external(im.page), "rect": Self.rectArray(im.anchor),
                                    "caption": im.caption, "image_sha256": im.image, "link": link(ws, doc: id, note: im.id)]
                switch im.source {
                case let .pdf(page, rect, pages):
                    o["from"] = ["kind": "pdf", "page": PageNo.external(page), "rect": Self.rectArray(rect), "pages": pages] as MCPObject
                case let .file(name):
                    o["from"] = ["kind": "file", "name": name] as MCPObject
                }
                return o
            }
            lines.append("Image notes (\(ims.count)):")
            lines += ims.map { "- p.\(PageNo.external($0.page)) \($0.caption.isEmpty ? "(no caption)" : $0.caption.prefix(80))" }
        }
        if kinds.contains("ai_thread") {
            let ts = (s?.aiThreads ?? ws.aiThreads(documentId: id)).filter { inPages($0.page) }.sorted { $0.page < $1.page }
            out["ai_threads"] = ts.map { t -> MCPObject in
                ["id": t.id.uuidString, "page": PageNo.external(t.page), "provider": t.provider, "url": t.url,
                 "title": t.title, "state": t.state == .ok ? "ok" : "suspect", "created_at": MCPJSON.iso(t.createdAt),
                 "link": link(ws, doc: id, page: PageNo.external(t.page))]
            }
            lines.append("AI threads (\(ts.count)):")
            lines += ts.map { "- p.\(PageNo.external($0.page)) \($0.provider) \($0.title.isEmpty ? $0.url : $0.title)" }
        }
        if kinds.contains("scratch_pad") {
            let ps = (s?.scratchPads ?? ws.scratchPads(documentId: id)).filter { inPages($0.anchorPage) }.sorted { $0.anchorPage < $1.anchorPage }
            out["scratch_pads"] = ps.map { p -> MCPObject in
                ["id": p.id.uuidString, "page": PageNo.external(p.anchorPage), "title": p.title,
                 "anchor": [p.anchorX, p.anchorY], "link": link(ws, doc: id, page: PageNo.external(p.anchorPage), frac: p.anchorY)]
            }
            lines.append("Scratch pads (\(ps.count)):")
            lines += ps.map { "- p.\(PageNo.external($0.anchorPage)) \($0.title.isEmpty ? "(untitled)" : $0.title)" }
        }
        if kinds.contains("ink") {
            let sums = ((try? ws.store?.inkPageSummaries(documentId: id)) ?? []).filter { inPages($0.page) }.sorted { $0.page < $1.page }
            out["ink"] = ["pages": sums.map { ["page": PageNo.external($0.page), "count": $0.count] as MCPObject },
                          "total": sums.reduce(0) { $0 + $1.count }] as MCPObject
            lines.append("Ink: \(sums.reduce(0) { $0 + $1.count }) strokes on \(sums.count) pages" +
                         (sums.isEmpty ? "" : " (" + sums.prefix(30).map { "p.\(PageNo.external($0.page))×\($0.count)" }.joined(separator: ", ") + (sums.count > 30 ? ", …" : "") + ")"))
        }
        return (out, lines.joined(separator: "\n"))
    }

    // MARK: - 写入（批 3，方案 §9.3）

    /// 一次写入的目标：文档在哪个工作区、开没开（🔴 开着就只许改 `DocSession` 的数组——直接写库会被对账当成
    /// 「内存里没有的行」删掉；没开才走 `WorkspaceManager.save*`）。
    struct WriteTarget {
        var id: String
        var title: String
        var ws: WorkspaceManager
        var session: DocSession?
        var pageCount: Int
        /// 文件路径 + hash（找引文用；文件丢了也能写书签/笔记，所以是可选的）
        var path: String?
        var contentHash: String
        /// 扫描页对齐参数（没开为 nil）：找引文得到的行框要落在对齐后的页面上。
        var align: ScanAlignTable? = nil
    }

    func writeTarget(documentId: String?, workspacePath: String?) throws -> WriteTarget {
        let id: String
        if let documentId, !documentId.isEmpty { id = documentId }
        else {
            guard let key = keyController else { throw MCPToolError("no reader window is open; pass document_id") }
            guard let d = key.tabs.active.docID else { throw MCPToolError("the key window has no document open; pass document_id") }
            id = d
        }
        let ws: WorkspaceManager
        if let p = workspacePath, !p.isEmpty { ws = try manager(workspacePath: p) }
        else if let key = keyController, key.workspace.document(id: id) != nil { ws = key.workspace }
        else if let m = WorkspaceRegistry.shared.openManagers.first(where: { $0.document(id: id) != nil }) { ws = m }
        else { throw MCPToolError("document '\(id)' not found in any open workspace; call list_documents") }
        guard let doc = ws.document(id: id) else { throw MCPToolError("document '\(id)' not found in workspace '\(ws.name)'") }
        let session = sessionsShowing(id).first?.session
        let f = fileInfo(ws, documentId: id)
        let hash = session?.contentHash.isEmpty == false ? session!.contentHash : f.hash
        let pageCount = session?.pdf?.pageCount ?? doc.pageCount
        return WriteTarget(id: id, title: doc.title, ws: ws, session: session,
                           pageCount: pageCount,
                           path: f.exists ? f.path : nil, contentHash: hash,
                           align: session.map { $0.scanAlign } ?? ws.scanAlign(contentHash: hash, pageCount: pageCount))
    }

    func addBookmark(_ t: WriteTarget, page: Int, frac: Double, title: String) throws -> MCPObject {
        guard Bookmark.validTitle(title) else { throw MCPInvalidParams("title must not be empty") }
        let idx = try PageNo.index(page, pageCount: t.pageCount)
        let f = min(max(frac, 0), 1)
        let b: Bookmark
        if let s = t.session {
            guard let made = s.addBookmark(page: idx, frac: f, title: title) else { throw MCPToolError("could not add bookmark") }
            b = made
        } else {
            b = Bookmark(page: idx, frac: f, title: title.trimmingCharacters(in: .whitespacesAndNewlines))
            t.ws.saveBookmark(documentId: t.id, b)
        }
        return ["id": b.id.uuidString, "document_id": t.id, "page": page, "frac": f, "title": b.title,
                "via": t.session == nil ? "library" : "session"]
    }

    func addNote(_ t: WriteTarget, page: Int, text: String, quote: String, rects: [CGRect]?, anchorRect: CGRect?,
                 typeName: String?, display: NoteDisplay, client: String) throws -> MCPObject {
        let idx = try PageNo.index(page, pageCount: t.pageCount)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if quote.isEmpty, trimmed.isEmpty { throw MCPInvalidParams("a note without a quote needs text") }
        let types = t.session?.noteTypes ?? t.ws.noteTypes()
        var typeId: UUID? = nil
        if let typeName, !typeName.isEmpty {
            guard let ty = types.first(where: { $0.name.caseInsensitiveCompare(typeName) == .orderedSame }) else {
                let names = types.map(\.name).joined(separator: ", ")
                throw MCPToolError("note type '\(typeName)' does not exist; available: \(names.isEmpty ? "(none)" : names)")
            }
            typeId = ty.id
        }
        // 锚点：行框 → 行框包围盒；只给了矩形 → 它；都没有 → 页左上一条横条（方案 §7.13）
        let lineRects: [CGRect]
        let anchor: CGRect
        if let rects, !rects.isEmpty {
            lineRects = rects
            anchor = rects.reduce(CGRect.null) { $0.union($1) }
        } else if let anchorRect {
            lineRects = [anchorRect]
            anchor = anchorRect
        } else {
            anchor = CGRect(x: 0.05, y: 0.05, width: 0.9, height: 0.02)
            lineRects = []
        }
        let note = TextNote(page: idx, anchor: anchor, quote: quote, text: text, rects: lineRects, typeId: typeId,
                            source: NoteSource(kind: NoteSource.agentKind, provider: client, url: "", threadId: nil, at: .now),
                            display: display)
        if let s = t.session {
            s.inkEdit("Note", kind: .note) { s.textNotes.append(note) }   // 进撤销栈，同界面新建
        } else {
            t.ws.saveTextNote(documentId: t.id, note)
        }
        return ["id": note.id.uuidString, "document_id": t.id, "page": page, "rect": Self.rectArray(anchor),
                "type": typeId == nil ? NSNull() : (typeName ?? ""), "via": t.session == nil ? "library" : "session"]
    }

    func addHighlight(_ t: WriteTarget, page: Int, quote: String, rects: [CGRect], color: InkColor, colorName: String,
                      style: HighlightStyle) throws -> MCPObject {
        let idx = try PageNo.index(page, pageCount: t.pageCount)
        guard !rects.isEmpty else { throw MCPToolError("quote not found on page \(page)") }
        let bbox = rects.reduce(CGRect.null) { $0.union($1) }
        let h = Highlight(page: idx, anchor: bbox.isNull ? .zero : bbox, quote: quote, rects: rects, color: color, style: style)
        if let s = t.session { s.highlights.append(h) } else { t.ws.saveHighlight(documentId: t.id, h) }
        return ["id": h.id.uuidString, "document_id": t.id, "page": page, "rect": Self.rectArray(h.anchor),
                "color": colorName, "style": style.rawValue, "via": t.session == nil ? "library" : "session"]
    }

    /// 导入前的解析：目标工作区（显式路径 > key 窗口的）。
    func importWorkspace(workspacePath: String?) throws -> WorkspaceManager { try manager(workspacePath: workspacePath) }

    func afterImport(_ ws: WorkspaceManager, _ doc: LibDocument, group: String?) -> MCPObject {
        if let group, !group.isEmpty { ws.setGroup(documentId: doc.id, group: group) }
        let fresh = ws.document(id: doc.id) ?? doc
        return documentDTO(ws, fresh)
    }

    func createWorkspace(path: String, activate: Bool) throws -> MCPObject {
        var p = (path as NSString).expandingTildeInPath
        if (p as NSString).pathExtension.lowercased() != WorkspaceManager.packageExtension {
            p = (p as NSString).appendingPathExtension(WorkspaceManager.packageExtension) ?? p
        }
        let url = URL(fileURLWithPath: p).standardizedFileURL
        // 🔴 界面那条 `createWorkspace(at:)` 会覆盖「已存在但不是工作区」的路径（保存面板确认过「替换」）；
        // Agent 没有那句确认，已存在一律拒绝
        guard !FileManager.default.fileExists(atPath: url.path) else {
            throw MCPToolError("path already exists: \(url.path); pick a new path")
        }
        do { try WorkspaceManager.createWorkspace(at: url) } catch {
            throw MCPToolError("cannot create workspace: \(error.localizedDescription)")
        }
        guard let delegate = AppDelegate.shared else { throw MCPToolError("app is not ready") }
        let c = try delegate.makeReaderWindow(workspacePath: url.path, docId: nil, activate: activate)
        WorkspaceRegistry.shared.rememberRecent(url)
        return ["workspace": workspaceDTO(c.workspace), "window_id": c.windowId.uuidString]
    }

    func runOCR(documentId: String?, workspacePath: String?, pages: [Int]?) throws -> MCPObject {
        let t = try writeTarget(documentId: documentId, workspacePath: workspacePath)
        guard let s = t.session, s.pdf != nil else {
            throw MCPToolError("document must be open in a tab to run OCR; call open_document first")
        }
        guard PaddleOCR.configFromDefaults() != nil else {
            throw MCPToolError("no OCR engine is configured in UniReader › Settings › Reading")
        }
        let want = pages ?? Array(0..<s.ocrTotalPages)
        s.ocrEnabled = true
        s.enqueueOCR(want)
        return ["document_id": t.id, "requested": want.count, "pending": s.ocrPendingCount, "done": s.ocrDoneCount,
                "total": s.ocrTotalPages]
    }

    // MARK: - 小工具

    static func rectArray(_ r: CGRect) -> [Double] {
        [Double(r.minX), Double(r.minY), Double(r.width), Double(r.height)]
    }

    static func hex(_ c: InkColor) -> String {
        String(format: "#%02X%02X%02X", Int(c.r.rounded()), Int(c.g.rounded()), Int(c.b.rounded()))
    }
}
