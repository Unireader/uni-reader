import AppKit

/// 改已有的批注（MCP `update_annotations`，`MCP-PLAN.md §32`，用户 2026-11-12）：文字笔记的正文 / 颜色 / 画法 / 类型 / 展开方式、
/// 高亮的颜色 / 画法、书签的名字、图片笔记的说明。此前只能删了重建（id 和 `unireader://…&note=` 链接都跟着变）。
///
/// 写法同 `deleteAnnotations`（方案 §9.3 两条路）：开着这篇的**每个**标签先 `flushPersist()` 结清 → 以库为准认 id →
/// 有一条认不出 / 改不了就整批不动 → 开着的改每个标签里的数组（文字 / 图片笔记走 `inkEdit` 进撤销栈，同界面编辑）再落库；
/// 没开就直接写库（`save*` 是按 id 覆盖）。🔴 文档开着时绝不直接写库：标签里的数组是真源，稍后按差异落库会把库里的改动盖回去。
extension MCPFacade {

    /// 一条修改。字段为 nil = 不改。
    struct AnnotationUpdate {
        var id: String
        var text: String?
        var title: String?
        /// `.some(nil)` = 清掉显式颜色（文字笔记回到按类型配色）。
        var color: InkColor??
        var colorName: String?
        var style: HighlightStyle?
        /// `.some(nil)` = 改回通用类型。
        var typeName: String??
        var display: NoteDisplay?

        var touchedFields: [String] {
            var f: [String] = []
            if text != nil { f.append("text") }
            if title != nil { f.append("title") }
            if color != nil { f.append("color") }
            if style != nil { f.append("style") }
            if typeName != nil { f.append("type") }
            if display != nil { f.append("display") }
            return f
        }
    }

    func updateAnnotations(_ t: WriteTarget, updates: [AnnotationUpdate]) throws -> MCPObject {
        guard !updates.isEmpty else { throw MCPInvalidParams("updates must not be empty") }
        let tabs = controllers.flatMap { $0.tabs.tabs }.filter { $0.docID == t.id && $0.workspace === t.ws }
        tabs.forEach { $0.flushPersist() }

        // 以库为准（刚 flush 过，开着时与标签里的一致）
        var notes = Dictionary(t.ws.textNotes(documentId: t.id).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var highlights = Dictionary(t.ws.highlights(documentId: t.id).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var bookmarks = Dictionary(t.ws.bookmarks(documentId: t.id).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var images = Dictionary(t.ws.imageNotes(documentId: t.id).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let allIDs = Array(notes.keys) + Array(highlights.keys) + Array(bookmarks.keys) + Array(images.keys)
        let types = t.session?.noteTypes ?? t.ws.noteTypes()

        var problems: [String] = []
        var changed: [(id: UUID, kind: String, page: Int, fields: [String])] = []
        let now = Date.now
        for (i, u) in updates.enumerated() {
            let label = updates.count > 1 ? "updates[\(i)] " : ""
            let key = u.id.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            let hits = key.count >= 8 ? allIDs.filter { $0.uuidString.hasPrefix(key) } : []
            guard hits.count == 1, let id = hits.first else {
                problems.append("\(label)id '\(u.id)' " + (hits.isEmpty ? "not found (take ids from list_annotations)" : "matches several annotations; pass the full id"))
                continue
            }
            guard !changed.contains(where: { $0.id == id }) else { problems.append("\(label)id '\(u.id)' appears twice"); continue }
            func reject(_ kind: String, _ allowed: [String]) -> Bool {
                let bad = u.touchedFields.filter { !allowed.contains($0) }
                if u.touchedFields.isEmpty { problems.append("\(label)nothing to change for \(kind) \(u.id)"); return true }
                if !bad.isEmpty {
                    problems.append("\(label)a \(kind) has no \(bad.joined(separator: "/")) (it can change \(allowed.joined(separator: ", ")))")
                    return true
                }
                return false
            }
            if var n = notes[id] {
                guard !reject("text note", ["text", "color", "style", "type", "display"]) else { continue }
                if let text = u.text {
                    if n.quote.isEmpty, text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        problems.append("\(label)a note without a quote needs text"); continue
                    }
                    n.text = text
                }
                if let c = u.color { n.color = c }
                if let s = u.style { n.style = s }
                if let d = u.display { n.display = d }
                if let tn = u.typeName {
                    if let name = tn, !name.isEmpty {
                        guard let ty = types.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
                            problems.append("\(label)note type '\(name)' does not exist; available: " + types.map(\.name).joined(separator: ", "))
                            continue
                        }
                        n.typeId = ty.id
                    } else {
                        n.typeId = nil
                    }
                }
                n.updatedAt = now
                notes[id] = n
                changed.append((id, "note", n.page, u.touchedFields))
            } else if var h = highlights[id] {
                guard !reject("highlight", ["color", "style"]) else { continue }
                if let c = u.color {
                    guard let c else { problems.append("\(label)a highlight needs a color; it cannot be cleared"); continue }
                    h.color = c
                }
                if let s = u.style { h.style = s }
                h.updatedAt = now
                highlights[id] = h
                changed.append((id, "highlight", h.page, u.touchedFields))
            } else if var b = bookmarks[id] {
                guard !reject("bookmark", ["title"]) else { continue }
                if let title = u.title {
                    guard Bookmark.validTitle(title) else { problems.append("\(label)a bookmark title must not be empty"); continue }
                    b.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                b.updatedAt = now
                bookmarks[id] = b
                changed.append((id, "bookmark", b.page, u.touchedFields))
            } else if var m = images[id] {
                // 图片笔记的「说明」就是它的文字（`text` 或 `title` 都认）
                guard !reject("image note", ["text", "title", "display"]) else { continue }
                if let c = u.text ?? u.title { m.caption = c }
                if let d = u.display { m.display = d }
                m.updatedAt = now
                images[id] = m
                changed.append((id, "image_note", m.page, u.touchedFields))
            }
        }
        if !problems.isEmpty {
            throw MCPToolError(problems.joined(separator: "; ") + ". Nothing was changed.")
        }

        let ids = Set(changed.map(\.id))
        if tabs.isEmpty {
            for c in changed {
                switch c.kind {
                case "note": if let n = notes[c.id] { t.ws.saveTextNote(documentId: t.id, n) }
                case "highlight": if let h = highlights[c.id] { t.ws.saveHighlight(documentId: t.id, h) }
                case "bookmark": if let b = bookmarks[c.id] { t.ws.saveBookmark(documentId: t.id, b) }
                default: if let m = images[c.id] { t.ws.saveImageNote(documentId: t.id, m) }
                }
            }
        } else {
            for tab in tabs {
                let s = tab.session
                if s.textNotes.contains(where: { ids.contains($0.id) }) || s.imageNotes.contains(where: { ids.contains($0.id) }) {
                    s.inkEdit("Note", kind: .note) {   // 同界面编辑笔记：进撤销栈
                        for i in s.textNotes.indices { if let n = notes[s.textNotes[i].id], ids.contains(n.id) { s.textNotes[i] = n } }
                        for i in s.imageNotes.indices { if let m = images[s.imageNotes[i].id], ids.contains(m.id) { s.imageNotes[i] = m } }
                    }
                }
                for i in s.highlights.indices { if let h = highlights[s.highlights[i].id], ids.contains(h.id) { s.highlights[i] = h } }
                for i in s.bookmarks.indices { if let b = bookmarks[s.bookmarks[i].id], ids.contains(b.id) { s.bookmarks[i] = b } }
                tab.flushPersist()   // 同步落库，应答时库里已经是新的
            }
        }
        return ["document_id": t.id, "count": changed.count,
                "updated": changed.map { c -> MCPObject in
                    var o: MCPObject = ["id": c.id.uuidString, "kind": c.kind, "page": PageNo.external(c.page), "fields": c.fields,
                                        "link": link(t.ws, doc: t.id, page: PageNo.external(c.page), note: c.id)]
                    if c.kind == "bookmark", let b = bookmarks[c.id] { o["title"] = b.title }
                    return o
                },
                "via": tabs.isEmpty ? "library" : "session"]
    }
}

// MARK: - update_document（改文档名 / 分组，`MCP-PLAN.md §32`）

extension MCPFacade {
    /// 改书库里文档的显示名（不改磁盘上的文件名，同侧栏「重命名…」）与分组（空串 = 未分组，同「移到分组」）。
    /// 2026-11-12 用户推翻方案 §7.13「不做改文档名」。
    func updateDocuments(ids: [String], title: String?, group: String?, workspacePath: String?) throws -> MCPObject {
        guard !ids.isEmpty else { throw MCPInvalidParams("pass document_id or document_ids") }
        let ws: WorkspaceManager
        if let p = workspacePath, !p.isEmpty { ws = try manager(workspacePath: p) }
        else if let key = keyController, ids.allSatisfy({ key.workspace.document(id: $0) != nil }) { ws = key.workspace }
        else if let m = WorkspaceRegistry.shared.openManagers.first(where: { m in ids.allSatisfy { m.document(id: $0) != nil } }) { ws = m }
        else { throw MCPToolError("documents not found in any open workspace: \(ids.joined(separator: ", ")); call list_documents") }
        let missing = ids.filter { ws.document(id: $0) == nil }
        guard missing.isEmpty else { throw MCPToolError("not in workspace “\(ws.name)”: \(missing.joined(separator: ", ")). Nothing was changed.") }
        var newTitle: String?
        if let title {
            let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { throw MCPInvalidParams("title must not be empty") }
            guard ids.count == 1 else { throw MCPInvalidParams("title renames one document; pass a single document_id") }
            newTitle = t
        }
        if let newTitle, ws.document(id: ids[0])?.title != newTitle { ws.rename(documentId: ids[0], title: newTitle) }
        if let group { ws.setGroup(ids: ids, group: group) }   // 里面会 trim；`refresh()` 后标签 / 窗口标题、平板书库跟着变
        return ["workspace": workspaceDTO(ws),
                "documents": ids.compactMap { ws.document(id: $0) }.map { documentDTO(ws, $0) },
                "groups": ws.groups]
    }
}
