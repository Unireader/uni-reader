import AppKit

extension Notification.Name {
    /// 让开着的网页标签跳到某一页（`object` = 工作区，userInfo `id` / `path`）。MCP `open_web_page` 发。
    static let webDocNavigate = Notification.Name("UniReader.webDocNavigate")
}

/// 批 9（2026-11-19）：网页（静态 HTML 课件，`WEB-DOC-PLAN.md §7.1`）。Agent 能列出、读文件、改文件、新建、打开给用户看，
/// 以及读写页面存的数据（`window.unireader`）。
/// 🔴 每个返回的键都要在 `outputSchema` 里声明（Kimi 严格校验，多一个键整次调用作废）。
extension MCPTools {

    static func registerWeb(into server: MCPServer) {
        let c = server.catalog
        c.register(listWebPagesTool())
        c.register(readWebPageTool())
        c.register(updateWebPageTool())
        c.register(createWebPageTool())
        c.register(openWebPageTool())
        c.register(readWebPageDataTool())
        c.register(writeWebPageDataTool())
    }

    private static let wsArg = MCPSchema.string("Workspace .unrd path; default = the workspace of the key reader window.")
    private static let webIdArg = MCPSchema.string("web page id (full, its first 8 characters, or the exact title)")

    private static var pageSchema: MCPObject {
        MCPSchema.object([
            "id": MCPSchema.string("web page id"),
            "title": MCPSchema.string("title"),
            "start_page": MCPSchema.string("path of the page opened first"),
            "files": MCPSchema.integer("number of files"),
            "bytes": MCPSchema.integer("total size in bytes"),
            "missing_files": MCPSchema.integer("files not downloaded to this Mac yet (sync)"),
            "updated_at": MCPSchema.string("ISO 8601"),
        ])
    }

    private static var fileWriteSchema: MCPObject {
        MCPSchema.object([
            "path": MCPSchema.string("relative path inside the web page, e.g. index.html or css/style.css"),
            "content": MCPSchema.string("the whole text of the file (UTF-8)"),
            "source_path": MCPSchema.string("instead of content: copy this local file (absolute path), e.g. an image"),
        ], required: ["path"])
    }

    static func listWebPagesTool() -> MCPTool {
        MCPTool(
            name: "list_web_pages",
            title: "List web pages",
            description: "List the web pages (网页) in a workspace: static HTML lessons (a folder of HTML, images, CSS, JS) the user imported, most recently opened first. Read their files with read_web_page, change them with update_web_page.",
            inputSchema: MCPSchema.object(["workspace": wsArg]),
            outputSchema: MCPSchema.object(["pages": MCPSchema.array(of: pageSchema)]),
            tier: .read
        ) { _, args in
            let wsPath = try args.string("workspace")
            let r = try await MainActor.run { try MCPFacade.shared.listWebPages(workspacePath: wsPath) }
            let list = r["pages"] as? [MCPObject] ?? []
            let text = list.isEmpty ? "No web pages in this workspace."
                : list.map { "- \($0["title"] ?? "") (id \($0["id"] ?? ""), \($0["files"] ?? 0) files, start \($0["start_page"] ?? ""))" }
                    .joined(separator: "\n")
            return MCPToolResult(text: text, structured: r)
        }
    }

    static func readWebPageTool() -> MCPTool {
        MCPTool(
            name: "read_web_page",
            title: "Read a web page's files",
            description: "Without path: list the files of a web page (path, size, type). With path: return that text file's content exactly (HTML, CSS, JS, JSON, SVG, Markdown…; binary files such as images are refused). Use the exact text as old_text for update_web_page edits.",
            inputSchema: MCPSchema.object([
                "workspace": wsArg,
                "web_id": webIdArg,
                "path": MCPSchema.string("file to read (relative path, as listed)"),
            ], required: ["web_id"]),
            outputSchema: MCPSchema.object([
                "id": MCPSchema.string("web page id"),
                "title": MCPSchema.string("title"),
                "start_page": MCPSchema.string("path of the page opened first"),
                "files": MCPSchema.array(of: MCPSchema.object([
                    "path": MCPSchema.string("relative path"),
                    "bytes": MCPSchema.integer("size"),
                    "type": MCPSchema.string("content type"),
                ]), "the files (only when path is not given)"),
                "path": MCPSchema.string("the file that was read"),
                "content": MCPSchema.string("the file's text"),
            ]),
            tier: .read
        ) { _, args in
            guard let id = try args.string("web_id") else { throw MCPInvalidParams("web_id is required") }
            let path = try args.string("path")
            let wsPath = try args.string("workspace")
            let r = try await MainActor.run { try MCPFacade.shared.readWebPage(id, path: path, workspacePath: wsPath) }
            if let content = r["content"] as? String { return MCPToolResult(text: content, structured: r) }
            let files = (r["files"] as? [MCPObject] ?? []).map { "- \($0["path"] ?? "") (\($0["bytes"] ?? 0) bytes)" }
            return MCPToolResult(text: "\(r["title"] ?? "") — start page \(r["start_page"] ?? "")\n" + files.joined(separator: "\n"),
                                 structured: r)
        }
    }

    static func updateWebPageTool() -> MCPTool {
        MCPTool(
            name: "update_web_page",
            title: "Change a web page's files",
            description: "Change files of an existing web page in one step: edits replace exact text inside a text file (old_text must occur exactly once — read the file first), files writes whole files (new paths are added, existing ones replaced; source_path copies a local file such as an image), delete removes files. Can also rename it (title) or change the start page. What the page stored with window.unireader is kept. Open tabs reload by themselves; the change syncs to the user's other devices.",
            inputSchema: MCPSchema.object([
                "workspace": wsArg,
                "web_id": webIdArg,
                "edits": MCPSchema.array(of: MCPSchema.object([
                    "path": MCPSchema.string("text file to edit"),
                    "old_text": MCPSchema.string("exact text to replace (must occur exactly once)"),
                    "new_text": MCPSchema.string("replacement (empty = delete old_text)"),
                ], required: ["path", "old_text", "new_text"]), "exact text replacements, applied in order"),
                "files": MCPSchema.array(of: fileWriteSchema, "whole files to write"),
                "delete": MCPSchema.array(of: MCPSchema.string("relative path"), "files to remove"),
                "title": MCPSchema.string("new title"),
                "start_page": MCPSchema.string("new start page (a path of this web page)"),
            ], required: ["web_id"]),
            outputSchema: MCPSchema.object([
                "id": MCPSchema.string("web page id"),
                "title": MCPSchema.string("title"),
                "start_page": MCPSchema.string("start page"),
                "files": MCPSchema.integer("number of files now"),
                "changed": MCPSchema.array(of: MCPSchema.string("path"), "files written or edited"),
                "deleted": MCPSchema.array(of: MCPSchema.string("path"), "files removed"),
            ]),
            tier: .write
        ) { _, args in
            guard let id = try args.string("web_id") else { throw MCPInvalidParams("web_id is required") }
            let wsPath = try args.string("workspace")
            let edits = try Self.webEdits(args.raw["edits"])
            let files = try Self.webFiles(args.raw["files"])
            let deletes = (args.raw["delete"] as? [Any])?.compactMap { $0 as? String } ?? []
            let title = try args.string("title")
            let entry = try args.string("start_page")
            let r = try await MainActor.run {
                try MCPFacade.shared.updateWebPage(id, edits: edits, files: files, deletes: deletes, title: title, entry: entry,
                                                   workspacePath: wsPath)
            }
            let changed = (r["changed"] as? [String] ?? []).count, deleted = (r["deleted"] as? [String] ?? []).count
            return MCPToolResult(text: "Updated “\(r["title"] ?? "")”: \(changed) file(s) written, \(deleted) removed.", structured: r)
        }
    }

    static func createWebPageTool() -> MCPTool {
        MCPTool(
            name: "create_web_page",
            title: "Create a web page",
            description: "Create a new web page (a static HTML lesson) in the workspace: either give its files (text content, or source_path to copy local files such as images), or folder = a local folder to import as it is (HTML, images, CSS, JS). Relative links between the files work as on a web server. In the page, window.unireader (get/set/remove/keys/getAll/clear, all returning Promises; values are JSON) stores data in the workspace that syncs across the user's devices — e.g. progress or answers; check `if (window.unireader)` before using it.",
            inputSchema: MCPSchema.object([
                "workspace": wsArg,
                "title": MCPSchema.string("title (default: the start page's <title>, or the folder name)"),
                "files": MCPSchema.array(of: fileWriteSchema, "the files"),
                "folder": MCPSchema.string("instead of files: absolute path of a local folder to import"),
                "start_page": MCPSchema.string("page opened first (default index.html)"),
                "open": MCPSchema.boolean("also show it to the user", default: false),
            ]),
            outputSchema: MCPSchema.object([
                "id": MCPSchema.string("web page id"),
                "title": MCPSchema.string("title"),
                "start_page": MCPSchema.string("start page"),
                "files": MCPSchema.integer("number of files"),
            ]),
            tier: .write
        ) { _, args in
            let wsPath = try args.string("workspace")
            let title = try args.string("title")
            let entry = try args.string("start_page")
            let open = try args.bool("open", default: false)
            var r: MCPObject
            if let folder = try args.string("folder"), !folder.isEmpty {
                let ws = try await MainActor.run { try MCPFacade.shared.manager(workspacePath: wsPath) }
                let url = URL(fileURLWithPath: (folder as NSString).expandingTildeInPath)
                let doc = try await ws.importWebFolder(url)
                r = try await MainActor.run {
                    if let title, !title.isEmpty { ws.renameWebDoc(id: doc.id, title: title) }
                    if let entry { ws.setWebDocEntry(id: doc.id, entry: entry) }
                    return MCPFacade.webPageSummary(ws.webDoc(id: doc.id) ?? doc)
                }
            } else {
                let files = try Self.webFiles(args.raw["files"])
                guard !files.isEmpty else { throw MCPInvalidParams("give files or folder") }
                r = try await MainActor.run {
                    try MCPFacade.shared.createWebPage(title: title ?? "", files: files, entry: entry, workspacePath: wsPath)
                }
            }
            if open, let id = r["id"] as? String {
                _ = try await MainActor.run { try MCPFacade.shared.openWebPage(id, path: nil, workspacePath: wsPath) }
            }
            return MCPToolResult(text: "Created the web page “\(r["title"] ?? "")” (id \(r["id"] ?? ""), \(r["files"] ?? 0) files).",
                                 structured: r)
        }
    }

    static func openWebPageTool() -> MCPTool {
        MCPTool(
            name: "open_web_page",
            title: "Show a web page",
            description: "Show a web page to the user in a UniReader tab, optionally at one of its pages (path).",
            inputSchema: MCPSchema.object([
                "workspace": wsArg,
                "web_id": webIdArg,
                "path": MCPSchema.string("page to show (relative path; default = where the user left it, or the start page)"),
            ], required: ["web_id"]),
            outputSchema: MCPSchema.object([
                "id": MCPSchema.string("web page id"),
                "title": MCPSchema.string("title"),
            ]),
            tier: .navigate
        ) { _, args in
            guard let id = try args.string("web_id") else { throw MCPInvalidParams("web_id is required") }
            let path = try args.string("path")
            let wsPath = try args.string("workspace")
            let r = try await MainActor.run { try MCPFacade.shared.openWebPage(id, path: path, workspacePath: wsPath) }
            return MCPToolResult(text: "Showing “\(r["title"] ?? "")”.", structured: r)
        }
    }

    static func readWebPageDataTool() -> MCPTool {
        MCPTool(
            name: "read_web_page_data",
            title: "Read what a web page stored",
            description: "Read the data a web page stored with window.unireader (its key/value store in the workspace, e.g. the user's progress or answers in a lesson). Values are JSON.",
            inputSchema: MCPSchema.object([
                "workspace": wsArg,
                "web_id": webIdArg,
                "keys": MCPSchema.array(of: MCPSchema.string("key"), "only these keys (default: all)"),
            ], required: ["web_id"]),
            outputSchema: MCPSchema.object([
                "id": MCPSchema.string("web page id"),
                "data": ["type": "object", "description": "key → stored JSON value"] as MCPObject,
            ]),
            tier: .read
        ) { _, args in
            guard let id = try args.string("web_id") else { throw MCPInvalidParams("web_id is required") }
            let keys = (args.raw["keys"] as? [Any])?.compactMap { $0 as? String }
            let wsPath = try args.string("workspace")
            let r = try await MainActor.run { try MCPFacade.shared.readWebPageData(id, keys: keys, workspacePath: wsPath) }
            return MCPToolResult(text: MCPJSON.string(r["data"] ?? [:], pretty: true), structured: r)
        }
    }

    static func writeWebPageDataTool() -> MCPTool {
        MCPTool(
            name: "write_web_page_data",
            title: "Change what a web page stored",
            description: "Set or remove keys in a web page's window.unireader store (values are any JSON). An open page receives the event unireader:change. Only when the user asks (e.g. to reset progress).",
            inputSchema: MCPSchema.object([
                "workspace": wsArg,
                "web_id": webIdArg,
                "set": ["type": "object", "description": "key → JSON value to store"] as MCPObject,
                "remove": MCPSchema.array(of: MCPSchema.string("key"), "keys to remove"),
            ], required: ["web_id"]),
            outputSchema: MCPSchema.object([
                "set": MCPSchema.integer("keys written"),
                "removed": MCPSchema.integer("keys removed"),
            ]),
            tier: .write
        ) { _, args in
            guard let id = try args.string("web_id") else { throw MCPInvalidParams("web_id is required") }
            var set: [String: String] = [:]
            if let obj = args.raw["set"] as? [String: Any] {
                for (k, v) in obj {
                    let data = try JSONSerialization.data(withJSONObject: v, options: [.fragmentsAllowed, .sortedKeys])
                    set[k] = String(decoding: data, as: UTF8.self)
                }
            }
            let remove = (args.raw["remove"] as? [Any])?.compactMap { $0 as? String } ?? []
            let wsPath = try args.string("workspace")
            let r = try await MainActor.run {
                try MCPFacade.shared.writeWebPageData(id, set: set, remove: remove, workspacePath: wsPath)
            }
            return MCPToolResult(text: "Stored \(r["set"] ?? 0) key(s), removed \(r["removed"] ?? 0).", structured: r)
        }
    }

    // MARK: - 参数

    struct WebEdit { let path: String; let old: String; let new: String }
    struct WebFile { let path: String; let content: String?; let source: String? }

    static func webEdits(_ raw: Any?) throws -> [WebEdit] {
        guard let raw else { return [] }
        guard let list = raw as? [Any] else { throw MCPInvalidParams("edits must be an array") }
        return try list.enumerated().map { i, v in
            guard let d = v as? [String: Any], let p = d["path"] as? String, let o = d["old_text"] as? String,
                  let n = d["new_text"] as? String else {
                throw MCPInvalidParams("edits[\(i)] needs path, old_text and new_text")
            }
            guard !o.isEmpty else { throw MCPInvalidParams("edits[\(i)].old_text is empty") }
            return WebEdit(path: p, old: o, new: n)
        }
    }

    static func webFiles(_ raw: Any?) throws -> [WebFile] {
        guard let raw else { return [] }
        guard let list = raw as? [Any] else { throw MCPInvalidParams("files must be an array") }
        return try list.enumerated().map { i, v in
            guard let d = v as? [String: Any], let p = d["path"] as? String else { throw MCPInvalidParams("files[\(i)] needs path") }
            let c = d["content"] as? String, s = d["source_path"] as? String
            guard (c == nil) != (s == nil) else { throw MCPInvalidParams("files[\(i)] needs exactly one of content or source_path") }
            return WebFile(path: p, content: c, source: s)
        }
    }
}

// MARK: - 门面（`MCPFacade` 是唯一碰 App 活状态的地方）

@MainActor
extension MCPFacade {

    static func webPageSummary(_ w: LibWebDoc, missing: Int = 0) -> MCPObject {
        ["id": w.id, "title": w.title, "start_page": w.entry, "files": w.entries.count, "bytes": Int(w.bytes),
         "missing_files": missing, "updated_at": ISO.string(w.updatedAt)]
    }

    /// id 全串 / 前 8 位 / 标题 → 那份网页。
    func resolveWebPage(_ raw: String, in ws: WorkspaceManager) throws -> LibWebDoc {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let all = ws.webDocs
        if let w = all.first(where: { $0.id.caseInsensitiveCompare(key) == .orderedSame }) { return w }
        if key.count >= 8 {
            let hits = all.filter { $0.id.uppercased().hasPrefix(key.uppercased()) }
            if hits.count == 1 { return hits[0] }
        }
        let byTitle = all.filter { $0.title == key }
        if byTitle.count == 1 { return byTitle[0] }
        if byTitle.count > 1 { throw MCPToolError("Several web pages are titled “\(key)”; use the id (list_web_pages).") }
        throw MCPToolError("No web page matches “\(key)” (see list_web_pages).")
    }

    func listWebPages(workspacePath: String?) throws -> MCPObject {
        let ws = try manager(workspacePath: workspacePath)
        return ["pages": ws.webDocs.map { Self.webPageSummary($0, missing: ws.webDocFilesMissing($0)) }]
    }

    func readWebPage(_ raw: String, path: String?, workspacePath: String?) throws -> MCPObject {
        let ws = try manager(workspacePath: workspacePath)
        let w = try resolveWebPage(raw, in: ws)
        var o: MCPObject = ["id": w.id, "title": w.title, "start_page": w.entry]
        guard let path, !path.isEmpty else {
            o["files"] = w.entries.sorted { $0.p < $1.p }.map { e -> MCPObject in
                ["path": e.p, "bytes": Int(e.n), "type": WebAssets.mimeType(path: e.p)]
            }
            return o
        }
        guard w.entries.contains(where: { $0.p == path }) else { throw MCPToolError("No file at \(path) in this web page.") }
        guard let data = ws.webFileData(w, path: path) else {
            throw MCPToolError("\(path) has not been downloaded to this Mac yet.")
        }
        guard data.count <= 2 << 20 else { throw MCPToolError("\(path) is larger than 2 MB; it is not read as text.") }
        guard let text = String(data: data, encoding: .utf8), !data.contains(0) else {
            throw MCPToolError("\(path) is not a UTF-8 text file (\(WebAssets.mimeType(path: path))).")
        }
        o["path"] = path
        o["content"] = text
        return o
    }

    /// 把 Agent 给的文件变成字节（文字 = UTF-8；source_path = 读本机文件）。
    private func webFileBytes(_ files: [MCPTools.WebFile]) throws -> [String: Data] {
        var out: [String: Data] = [:]
        for f in files {
            guard WebAssets.isSafeRelative(f.path) else { throw MCPToolError("Bad path: \(f.path) (relative, no .. or leading /)") }
            if let c = f.content {
                out[f.path] = Data(c.utf8)
            } else if let s = f.source {
                let url = URL(fileURLWithPath: (s as NSString).expandingTildeInPath)
                guard let d = try? Data(contentsOf: url) else { throw MCPToolError("Cannot read \(s).") }
                guard d.count <= 512 << 20 else { throw MCPToolError("\(s) is larger than 512 MB.") }
                out[f.path] = d
            }
        }
        return out
    }

    func updateWebPage(_ raw: String, edits: [MCPTools.WebEdit], files: [MCPTools.WebFile], deletes: [String],
                       title: String?, entry: String?, workspacePath: String?) throws -> MCPObject {
        let ws = try manager(workspacePath: workspacePath)
        let w = try resolveWebPage(raw, in: ws)
        var change = WorkspaceManager.WebDocChange()
        change.writes = try webFileBytes(files)
        // 精确替换：基于（可能刚写的）当前内容，依次套用
        var texts: [String: String] = [:]
        for (i, e) in edits.enumerated() {
            var t: String
            if let cur = texts[e.path] {
                t = cur
            } else if let d = change.writes[e.path] ?? ws.webFileData(w, path: e.path) {
                guard let s = String(data: d, encoding: .utf8) else { throw MCPToolError("edits[\(i)]: \(e.path) is not UTF-8 text.") }
                t = s
            } else {
                throw MCPToolError("edits[\(i)]: no file at \(e.path) (or not downloaded yet).")
            }
            let n = t.components(separatedBy: e.old).count - 1
            guard n == 1 else {
                throw MCPToolError("edits[\(i)]: old_text occurs \(n) times in \(e.path); it must occur exactly once (read_web_page shows the exact text).")
            }
            t = t.replacingOccurrences(of: e.old, with: e.new)
            texts[e.path] = t
        }
        for (p, t) in texts { change.writes[p] = Data(t.utf8) }
        change.deletes = deletes
        change.title = title
        change.entry = entry
        guard !change.writes.isEmpty || !deletes.isEmpty || title != nil || entry != nil else {
            throw MCPInvalidParams("nothing to change: give edits, files, delete, title or start_page")
        }
        let saved: LibWebDoc
        do { saved = try ws.changeWebDoc(id: w.id, change) } catch { throw MCPToolError(error.localizedDescription) }
        return ["id": saved.id, "title": saved.title, "start_page": saved.entry, "files": saved.entries.count,
                "changed": change.writes.keys.sorted(), "deleted": deletes]
    }

    func createWebPage(title: String, files: [MCPTools.WebFile], entry: String?, workspacePath: String?) throws -> MCPObject {
        let ws = try manager(workspacePath: workspacePath)
        let bytes = try webFileBytes(files)
        var name = title
        if name.isEmpty, let e = entry ?? WebAssets.defaultEntry(bytes.map { WebAssets.Entry(p: $0.key, h: "", n: 0) }),
           let d = bytes[e], let html = String(data: d.prefix(64 * 1024), encoding: .utf8),
           let a = html.range(of: "<title>", options: .caseInsensitive),
           let b = html.range(of: "</title>", options: .caseInsensitive, range: a.upperBound..<html.endIndex) {
            name = html[a.upperBound..<b.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        }
        do {
            let w = try ws.createWebDoc(title: name, files: bytes, entry: entry)
            return Self.webPageSummary(w)
        } catch {
            throw MCPToolError(error.localizedDescription)
        }
    }

    func openWebPage(_ raw: String, path: String?, workspacePath: String?) throws -> MCPObject {
        let ws = try manager(workspacePath: workspacePath)
        let w = try resolveWebPage(raw, in: ws)
        if let path, !path.isEmpty {
            guard WebAssets.resolve(path, in: Dictionary(uniqueKeysWithValues: w.entries.map { ($0.p, $0) })) != nil else {
                throw MCPToolError("No page at \(path) in this web page.")
            }
            WebDocView.rememberPath(webId: w.id, path: path)   // 还没开的标签按它开
        }
        guard let delegate = AppDelegate.shared else { throw MCPToolError("app is not ready") }
        let (c, _) = try delegate.showWebDoc(w.id, in: ws)
        NSApp.activate(ignoringOtherApps: true)
        c.window?.makeKeyAndOrderFront(nil)
        if let path, !path.isEmpty {   // 已经开着的标签：跳过去
            NotificationCenter.default.post(name: .webDocNavigate, object: ws, userInfo: ["id": w.id, "path": path])
        }
        return ["id": w.id, "title": w.title]
    }

    func readWebPageData(_ raw: String, keys: [String]?, workspacePath: String?) throws -> MCPObject {
        let ws = try manager(workspacePath: workspacePath)
        let w = try resolveWebPage(raw, in: ws)
        let all = (try? ws.store?.webKV(webId: w.id)) ?? []
        var data: MCPObject = [:]
        for kv in all where keys == nil || keys!.contains(kv.key) {
            data[kv.key] = (try? JSONSerialization.jsonObject(with: Data(kv.value.utf8), options: .fragmentsAllowed)) ?? NSNull()
        }
        return ["id": w.id, "data": data]
    }

    func writeWebPageData(_ raw: String, set: [String: String], remove: [String], workspacePath: String?) throws -> MCPObject {
        let ws = try manager(workspacePath: workspacePath)
        let w = try resolveWebPage(raw, in: ws)
        guard !set.isEmpty || !remove.isEmpty else { throw MCPInvalidParams("give set or remove") }
        do {
            for (k, v) in set.sorted(by: { $0.key < $1.key }) { _ = try ws.webKV(webId: w.id, op: "set", key: k, value: v) }
            for k in remove { _ = try ws.webKV(webId: w.id, op: "remove", key: k, value: nil) }
        } catch {
            throw MCPToolError(error.localizedDescription)
        }
        ws.webKVChangedRemotely()   // 开着的页面收到 unireader:change
        return ["set": set.count, "removed": remove.count]
    }
}
