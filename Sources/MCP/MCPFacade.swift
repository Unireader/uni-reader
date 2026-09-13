import AppKit
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

    private func tabDTO(_ tab: DocTabModel) -> MCPObject {
        let s = tab.session
        var o: MCPObject = ["session_id": tab.id.uuidString, "is_active": tab.isActive]
        if let d = tab.docID {
            o["document_id"] = d
            o["title"] = tab.tabTitle
            o["page"] = PageNo.external(s.currentPageIndex)
            o["page_count"] = s.pdf?.pageCount ?? 0
            o["zoom"] = Double(s.readZoom)
            o["canvas_mode"] = s.canvasMode
            o["file_missing"] = tab.missingDoc != nil
        } else {
            o["document_id"] = NSNull()
        }
        return o
    }

    private func windowDTO(_ c: ReaderWindowController, isKey: Bool) -> MCPObject {
        ["window_id": c.windowId.uuidString,
         "is_key": isKey,
         "workspace": workspaceDTO(c.workspace),
         "tabs": c.tabs.tabs.map { tabDTO($0) }]
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

    private func documentDTO(_ ws: WorkspaceManager, _ d: LibDocument) -> MCPObject {
        let f = fileInfo(ws, documentId: d.id)
        return ["id": d.id,
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
                        "bind": (mcp ?? app?.mcp)?.effectiveBind.rawValue ?? MCPServer.bind.rawValue] as MCPObject,
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
        } else if let showing = sessionsShowing(documentId).first,
                  let owner = controllers.first(where: { $0.tabs.owns(showing.id) }) {
            // 某个标签已经在显示它 → 切过去，不重开
            c = owner
            c.tabs.activate(showing.id)
            tab = showing
        } else if let owner = controllers(for: ws).first(where: { $0.window?.isKeyWindow == true }) ?? controllers(for: ws).first {
            c = owner
            tab = c.tabs.open(documentId)
        } else {
            guard let delegate = AppDelegate.shared else { throw MCPToolError("app is not ready") }
            c = try delegate.makeReaderWindow(workspacePath: ws.folder?.path, docId: documentId, activate: activate)
            tab = c.tabs.active
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
                "page": PageNo.external(tab.session.currentPageIndex)]
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
        return DocTarget(documentId: id, title: doc.title, path: p, contentHash: hash, store: ws.store,
                         session: tab?.session, currentPage: tab?.session.currentPageIndex, workspaceName: ws.name)
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
        guard let docId = tab.docID else {
            o["document_id"] = NSNull()
            return o
        }
        o["document_id"] = docId
        o["title"] = tab.tabTitle
        o["page"] = PageNo.external(s.scrollAnchor?.page ?? s.currentPageIndex)
        o["frac"] = s.scrollAnchor?.frac ?? 0
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
                "document_id": tab.docID ?? NSNull(), "page": page, "frac": f]
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

        var out: MCPObject = ["document_id": id, "title": doc.title]
        var lines: [String] = ["“\(doc.title)”"]

        if kinds.contains("note") {
            let notes = (s?.textNotes ?? ws.textNotes(documentId: id)).filter { inPages($0.page) }
                .sorted { $0.page != $1.page ? $0.page < $1.page : $0.anchor.minY < $1.anchor.minY }
            out["notes"] = notes.map { n -> MCPObject in
                var o: MCPObject = ["id": n.id.uuidString, "page": PageNo.external(n.page), "rect": Self.rectArray(n.anchor),
                                    "quote": n.quote, "text": n.text, "type": typeName(n.typeId), "display": n.display.rawValue,
                                    "created_at": MCPJSON.iso(n.createdAt), "updated_at": MCPJSON.iso(n.updatedAt)]
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
                 "quote": h.quote, "color": Self.hex(h.color), "created_at": MCPJSON.iso(h.createdAt)]
            }
            lines.append("Highlights (\(hs.count)):")
            lines += hs.map { "- p.\(PageNo.external($0.page)) [\($0.id.uuidString.prefix(8))] “\($0.quote.flattenedQuote.prefix(80))”" }
        }
        if kinds.contains("bookmark") {
            let bs = (s?.bookmarks ?? ws.bookmarks(documentId: id)).filter { inPages($0.page) }.sorted(by: Bookmark.before)
            out["bookmarks"] = bs.map { b -> MCPObject in
                ["id": b.id.uuidString, "page": PageNo.external(b.page), "frac": b.frac, "title": b.title,
                 "created_at": MCPJSON.iso(b.createdAt)]
            }
            lines.append("Bookmarks (\(bs.count)):")
            lines += bs.map { "- p.\(PageNo.external($0.page)) \($0.title)" }
        }
        if kinds.contains("image_note") {
            let ims = (s?.imageNotes ?? ws.imageNotes(documentId: id)).filter { inPages($0.page) }
                .sorted { $0.page != $1.page ? $0.page < $1.page : $0.anchor.minY < $1.anchor.minY }
            out["image_notes"] = ims.map { im -> MCPObject in
                var o: MCPObject = ["id": im.id.uuidString, "page": PageNo.external(im.page), "rect": Self.rectArray(im.anchor),
                                    "caption": im.caption, "image_sha256": im.image]
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
                 "title": t.title, "state": t.state == .ok ? "ok" : "suspect", "created_at": MCPJSON.iso(t.createdAt)]
            }
            lines.append("AI threads (\(ts.count)):")
            lines += ts.map { "- p.\(PageNo.external($0.page)) \($0.provider) \($0.title.isEmpty ? $0.url : $0.title)" }
        }
        if kinds.contains("scratch_pad") {
            let ps = (s?.scratchPads ?? ws.scratchPads(documentId: id)).filter { inPages($0.anchorPage) }.sorted { $0.anchorPage < $1.anchorPage }
            out["scratch_pads"] = ps.map { p -> MCPObject in
                ["id": p.id.uuidString, "page": PageNo.external(p.anchorPage), "title": p.title,
                 "anchor": [p.anchorX, p.anchorY]]
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

    // MARK: - 小工具

    static func rectArray(_ r: CGRect) -> [Double] {
        [Double(r.minX), Double(r.minY), Double(r.width), Double(r.height)]
    }

    static func hex(_ c: InkColor) -> String {
        String(format: "#%02X%02X%02X", Int(c.r.rounded()), Int(c.g.rounded()), Int(c.b.rounded()))
    }
}
