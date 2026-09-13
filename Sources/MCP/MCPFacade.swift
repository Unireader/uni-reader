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

    func state(mcp: MCPServer) -> MCPObject {
        let key = keyController
        let app = AppDelegate.shared?.appModel
        return ["app": ["version": MCPServer.appVersion,
                        "pid": Int(ProcessInfo.processInfo.processIdentifier),
                        "writes_enabled": MCPServer.allowWrites,
                        "bind": mcp.effectiveBind.rawValue] as MCPObject,
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
}
