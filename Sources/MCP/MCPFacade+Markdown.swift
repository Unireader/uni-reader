import AppKit

/// Markdown 笔记的结构类操作（`MARKDOWN-NOTES-PLAN.md §15–16`）：改名 / 挪目录 / 换源、挪整个目录、删除、打开、查链接。
/// 正文读写（read / edit / update / create）还在 `MCPFacade.swift`。
///
/// 动了笔记位置的三件事都在这里按同一个顺序做：开着的编辑器先存盘 → 留一份改之前的 `[[…]]` 索引 → 动文件、重扫 →
/// 开着的标签 / 小窗 / 编辑器跟过去（`ReaderWindowController.noteMoved`）。哪些链接因此断了，交给 `MCPNoteScan` 在主线程外读正文认。
extension MCPFacade {

    /// 认断链要用的东西：改之前 / 之后两份索引、动了哪些笔记、全部笔记文件。读正文放到主线程外（红线：主线程只拼 DTO）。
    struct NoteScanInput {
        let before: NoteIndex
        let after: NoteIndex
        let moved: [NoteRef: NoteRef?]
        let files: [(ref: NoteRef, url: URL)]
    }

    /// 源的 id 或名字（不分大小写）→ 源。
    func noteSource(_ ws: WorkspaceManager, named source: String) throws -> NoteRoot {
        guard let s = ws.noteSources.first(where: { $0.id == source })
                ?? ws.noteSources.first(where: { $0.name.caseInsensitiveCompare(source) == .orderedSame }) else {
            throw MCPToolError("note source '\(source)' not found; sources: "
                               + ws.noteSources.map { "\($0.name) (\($0.id))" }.joined(separator: ", "))
        }
        return s
    }

    private func allNoteFiles(_ ws: WorkspaceManager) -> [(ref: NoteRef, url: URL)] {
        ws.allNotes.compactMap { n in ws.noteURL(n.ref).map { (n.ref, $0) } }
    }

    /// 开着这几篇的编辑器先存盘；同一篇在几个编辑器里各有不同的未存输入 → 拒绝（不知道该留哪份）。
    private func flushBeforeMoving(_ ws: WorkspaceManager, _ refs: [NoteRef], verb: String) throws {
        for r in refs where liveMarkdown(ws, r).conflict {
            throw MCPToolError("“\(r.title)” is open in several editors with different unsaved edits; ask the user to resolve them before \(verb)")
        }
        for r in refs { MarkdownDocView.flushEditors(showing: r, in: ws) }
    }

    // MARK: - rename_markdown

    /// `rename_markdown`：改名 / 挪目录 / 换源（`MARKDOWN-NOTES-PLAN.md §15`）。`title` / `folder` / `source` 为 nil = 不变。
    func renameMarkdown(noteRef: String?, windowId: String?, workspacePath: String?,
                        title: String?, folder: String?, source: String?) throws -> (json: MCPObject, scan: NoteScanInput?) {
        let (ws, ref) = try markdownTarget(noteRef: noteRef, windowId: windowId, workspacePath: workspacePath)
        let toSource = try source.map { try noteSource(ws, named: $0).id }
        try flushBeforeMoving(ws, [ref], verb: "renaming")
        let before = ws.wiki.snapshot()
        let new: NoteRef
        do { new = try ws.moveNote(ref, title: title, folder: folder, toSource: toSource) }
        catch let e as WorkspaceManager.NoteAgentError { throw MCPToolError(e.message) }
        let changed = new != ref
        if changed { ReaderWindowController.noteMoved(from: ref, to: new, in: ws) }
        var o = markdownWriteResult(ws, new, liveMarkdown(ws, new).text ?? "")
        o["source"] = ws.noteSource(id: new.sourceID)?.name ?? new.sourceID
        o["relative_path"] = new.relPath
        o["old_ref"] = ref.key
        o["old_title"] = ref.title
        o["old_source"] = ws.noteSource(id: ref.sourceID)?.name ?? ref.sourceID
        o["old_relative_path"] = ref.relPath
        o["changed"] = changed
        let scan = changed ? NoteScanInput(before: before, after: ws.wiki.snapshot(), moved: [ref: new], files: allNoteFiles(ws)) : nil
        return (o, scan)
    }

    // MARK: - move_markdown_folder

    /// `move_markdown_folder`：给笔记目录改名 / 挪位置（`§16`）。`name` / `parent` 为 nil = 不变，`parent` 空串 = 源根。
    func moveMarkdownFolder(source: String?, folder: String, name: String?, parent: String?,
                            workspacePath: String?) throws -> (json: MCPObject, scan: NoteScanInput?) {
        let ws = try manager(workspacePath: workspacePath)
        let src: NoteRoot
        if let source, !source.isEmpty { src = try noteSource(ws, named: source) }
        else if let s = ws.noteSource(id: NoteRoot.workspaceID) { src = s }
        else { throw MCPToolError("this workspace has no Notes folder") }
        let prefix = folder.split(separator: "/").map(String.init).filter { !$0.isEmpty }.joined(separator: "/") + "/"
        let inside = ws.allNotes.filter { $0.ref.sourceID == src.id && $0.ref.relPath.hasPrefix(prefix) }.map(\.ref)
        try flushBeforeMoving(ws, inside, verb: "moving the folder")
        let before = ws.wiki.snapshot()
        let r: (folder: String, moves: [(from: NoteRef, to: NoteRef)])
        do { r = try ws.moveNoteFolder(sourceID: src.id, folder: folder, name: name, parent: parent) }
        catch let e as WorkspaceManager.NoteAgentError { throw MCPToolError(e.message) }
        for m in r.moves { ReaderWindowController.noteMoved(from: m.from, to: m.to, in: ws) }
        let old = String(prefix.dropLast())
        let o: MCPObject = ["source": src.name, "old_folder": old, "folder": r.folder, "changed": old != r.folder,
                            "notes_moved": r.moves.count,
                            "notes": r.moves.prefix(200).map { ["old_ref": $0.from.key, "ref": $0.to.key, "title": $0.to.title] as MCPObject }]
        guard !r.moves.isEmpty else { return (o, nil) }
        var moved: [NoteRef: NoteRef?] = [:]
        for m in r.moves { moved[m.from] = m.to }
        return (o, NoteScanInput(before: before, after: ws.wiki.snapshot(), moved: moved, files: allNoteFiles(ws)))
    }

    // MARK: - delete_markdown

    /// `delete_markdown`：把一篇移到系统废纸篓（`§16`，同界面上的「移到废纸篓…」）。先存盘，废纸篓里那份是最新的。
    func deleteMarkdown(noteRef: String?, windowId: String?, workspacePath: String?) throws -> (json: MCPObject, scan: NoteScanInput) {
        let (ws, ref) = try markdownTarget(noteRef: noteRef, windowId: windowId, workspacePath: workspacePath)
        try flushBeforeMoving(ws, [ref], verb: "deleting")
        let before = ws.wiki.snapshot()
        let source = ws.noteSource(id: ref.sourceID)
        let trashed: URL?
        do { trashed = try ws.trashNoteForAgent(ref) }
        catch let e as WorkspaceManager.NoteAgentError { throw MCPToolError(e.message) }
        // 开着它的标签 / 小窗下一拍自己关（`closeMarkdownIfGone` / `noteTreeChanged`），与界面删除一样
        let o: MCPObject = ["ref": ref.key, "title": ref.title, "source": source?.name ?? ref.sourceID,
                            "source_kind": source?.kind.rawValue ?? "unknown",
                            "relative_path": ref.relPath, "trash_path": trashed?.path ?? NSNull()]
        return (o, NoteScanInput(before: before, after: ws.wiki.snapshot(), moved: [ref: nil], files: allNoteFiles(ws)))
    }

    // MARK: - open_markdown

    func openMarkdown(noteRef: String, workspacePath: String?, activate: Bool) throws -> MCPObject {
        let (ws, ref) = try markdownTarget(noteRef: noteRef, windowId: nil, workspacePath: workspacePath)
        guard let delegate = AppDelegate.shared else { throw MCPToolError("app is not ready") }
        let (c, tab) = try delegate.showMarkdown(ref, in: ws, activate: activate)
        if activate {
            NSApp.activate(ignoringOtherApps: true)
            c.window?.makeKeyAndOrderFront(nil)
        }
        return ["ref": ref.key, "title": ref.title, "session_id": tab.id.uuidString,
                "window_id": c.windowId.uuidString, "link": link(ws, markdown: ref.key)]
    }

    // MARK: - add_markdown_image

    /// `add_markdown_image` 第一步（`MARKDOWN-NOTES-PLAN.md §16`）：认笔记、看它所在的源写得进去（不是服务器镜像、在这台电脑上）。
    /// 图片放在**笔记所在源根下的 `attachments/`**（一处，不在每个目录里各冒一个），正文写 `![[文件名]]`——
    /// 按文件名全库找（`NoteIndex.file(for:)` 的第二步，同 Obsidian「尽量短的路径」），所以文件名带内容哈希、不会重名。
    func markdownImageTarget(noteRef: String?, windowId: String?, workspacePath: String?) throws -> (WorkspaceManager, NoteRef, URL) {
        let (ws, ref) = try markdownTarget(noteRef: noteRef, windowId: windowId, workspacePath: workspacePath)
        let root: URL
        do { root = try ws.agentWritableRoot(ref.sourceID, verb: "changed").1 }
        catch let e as WorkspaceManager.NoteAgentError { throw MCPToolError(e.message) }
        return (ws, ref, root.appendingPathComponent("attachments", isDirectory: true))
    }

    /// 第二步：图写进 `attachments/`（同名同内容就复用）、重扫让 `![[…]]` 认得它，再在正文里插一行（同 `edit_markdown` 的插入，
    /// 推回开着的编辑器）。`afterLine` nil = 末尾。
    func insertMarkdownImage(_ ws: WorkspaceManager, _ ref: NoteRef, dir: URL, fileName: String, data: Data,
                             afterLine: Int?, caption: String?, displayWidth: Int?) throws -> MCPObject {
        let (current, editors) = try markdownForWrite(ws, ref, expectedRevision: nil)
        let url = dir.appendingPathComponent(fileName)
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            do {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
                try data.write(to: url, options: .atomic)
            } catch { throw MCPToolError("could not save the image: \(error.localizedDescription)") }
            ws.refreshNotes()   // 附件进 `[[…]]` 索引（`addFile`），编辑器里的 `![[…]]` 才找得到它
        }
        var lines = ["![[\(fileName)\(displayWidth.map { "|\($0)" } ?? "")]]"]
        if let caption, !caption.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { lines.append(caption) }
        let total = MCPMarkdownText.lineCount(current)
        let at = min(max(afterLine ?? total, 0), total)
        let result: MCPMarkdownText.EditResult
        do { result = try MCPMarkdownText.apply([.insert(afterLine: at, text: lines.joined(separator: "\n"))], to: current) }
        catch let e as MCPMarkdownText.EditError { throw MCPToolError("\(e.message). The image was saved but not inserted.") }
        try commitMarkdown(ws, ref, old: current, new: result.text, editors: editors)
        var o = markdownWriteResult(ws, ref, result.text)
        o["image_file"] = url.path
        o["embed"] = lines[0]
        o["inserted_after_line"] = at
        o["changed_lines"] = result.changedLines.map { [$0.lowerBound, $0.upperBound] }
        return o
    }

    // MARK: - markdown_links

    /// `markdown_links` 要的东西：给了笔记 → 它此刻的正文（含没存的输入）；全部笔记文件与当前索引。
    struct LinkScanInput {
        let target: NoteRef?
        let targetText: String?
        let index: NoteIndex
        let files: [(ref: NoteRef, url: URL)]
        let sourceNames: [String: String]
    }

    func markdownLinksInput(noteRef: String?, windowId: String?, workspacePath: String?, wholeWorkspace: Bool) throws -> LinkScanInput {
        if wholeWorkspace {
            let ws = try manager(workspacePath: workspacePath)
            return LinkScanInput(target: nil, targetText: nil, index: ws.wiki.snapshot(), files: allNoteFiles(ws),
                                 sourceNames: Dictionary(ws.noteSources.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a }))
        }
        let (ws, ref) = try markdownTarget(noteRef: noteRef, windowId: windowId, workspacePath: workspacePath)
        guard let text = liveMarkdown(ws, ref).text else {
            throw MCPToolError("the Markdown file for “\(ref.title)” cannot be read; it may have been moved or deleted")
        }
        return LinkScanInput(target: ref, targetText: text, index: ws.wiki.snapshot(), files: allNoteFiles(ws),
                             sourceNames: Dictionary(ws.noteSources.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a }))
    }
}

/// 读全部笔记正文认链接（主线程外跑；只用值类型与纯函数）。
enum MCPNoteScan {
    /// 断掉的 `[[…]]`：哪篇、哪几个写法（按笔记顺序）。
    static func brokenLinks(_ s: MCPFacade.NoteScanInput) async -> [(ref: NoteRef, names: [String])] {
        await Task.detached(priority: .userInitiated) {
            s.files.compactMap { f in
                guard let text = MarkdownImport.readText(f.url) else { return nil }
                let names = NoteIndex.linksBroken(in: text, before: s.before, after: s.after, moved: s.moved)
                return names.isEmpty ? nil : (f.ref, names)
            }
        }.value
    }

    struct Occurrence {
        let note: NoteRef
        let line: Int
        let raw: String
        let target: String
        /// 指到的笔记（书 / 书页时为 nil，看 `pointsTo`）。
        let resolved: NoteRef?
        /// 指到哪（笔记、书或书页，`KNOWLEDGE-LINKS-PLAN.md`）；nil = 断了。
        let pointsTo: LinkTarget?
    }

    /// 某篇链出去的（每一处）、链到它的（每一处，含自己链自己）；不给笔记 = 全库解析不到的那些。
    static func links(_ s: MCPFacade.LinkScanInput) async -> (outgoing: [Occurrence], incoming: [Occurrence], broken: [Occurrence]) {
        await Task.detached(priority: .userInitiated) {
            func occ(_ ref: NoteRef, _ text: String) -> [Occurrence] {
                MarkdownLink.wikiOccurrences(text).map {
                    // 括号里的整串（含 `#page=`）交给 `target(for:)`：`[[书名#page=12]]` 指到书页，不算断
                    var inner = $0.raw
                    if inner.hasPrefix("!") { inner.removeFirst() }
                    inner = String(inner.dropFirst(2).dropLast(2))
                    let t = s.index.target(for: inner)
                    var note: NoteRef? = nil
                    if case .note(let r)? = t { note = r }
                    return Occurrence(note: ref, line: $0.line, raw: $0.raw, target: $0.target, resolved: note, pointsTo: t)
                }
            }
            var outgoing: [Occurrence] = [], incoming: [Occurrence] = [], broken: [Occurrence] = []
            if let t = s.target, let text = s.targetText { outgoing = occ(t, text) }
            for f in s.files {
                let text: String?
                if f.ref == s.target { text = s.targetText } else { text = MarkdownImport.readText(f.url) }
                guard let text else { continue }
                for o in occ(f.ref, text) {
                    if let t = s.target { if o.resolved == t { incoming.append(o) } }
                    else if o.pointsTo == nil { broken.append(o) }
                }
            }
            return (outgoing, incoming, broken)
        }.value
    }
}
