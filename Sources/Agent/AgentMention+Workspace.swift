import Foundation

/// 由工作区里的东西造 `AgentMention`（`ACP-AGENT-PLAN.md §8`、§11）：输入框 `@` 的候选（PDF / 笔记）与
/// 侧栏「在 Agent 中引用」（侧栏每一种条目）都走这里，同一样东西两条路进来给 Agent 的是同一份说明。
///
/// 🔴 只给名字、位置和「用哪个 MCP 工具读」，不给内容（同 §8）。
@MainActor
extension AgentMention {

    /// 一篇 PDF：名字是文件名（本机找不到文件时用书名 + .pdf），位置是 file URL（没有文件时退成 `unireader://`）。
    static func pdf(_ d: LibDocument, in ws: WorkspaceManager) -> AgentMention {
        let path = ws.currentFilePath(documentId: d.id)
        var uri: String
        if let path {
            uri = URL(fileURLWithPath: path).absoluteString
        } else {
            var link = workspaceLink(ws)
            link.documentId = d.id
            uri = link.absoluteString
        }
        let file = path.map { ($0 as NSString).lastPathComponent } ?? d.title + ".pdf"
        return AgentMention(kind: .pdf, id: d.id, name: file, detail: file == d.title + ".pdf" ? "" : d.title, uri: uri)
    }

    /// 一篇 Markdown 笔记（文件在哪都不知道 → nil）。
    static func note(_ n: NoteItem, in ws: WorkspaceManager) -> AgentMention? {
        guard let url = ws.noteURL(n.ref) else { return nil }
        let src = ws.noteSource(id: n.ref.sourceID)?.name ?? ""
        let place = [src, n.ref.folder].filter { !$0.isEmpty }.joined(separator: " / ")
        return AgentMention(kind: .note, id: n.ref.key, name: url.lastPathComponent, detail: place, uri: url.absoluteString)
    }

    /// 笔记源里的一个目录；`path` 为空 = 整个源（侧栏段头）。
    static func folder(source: NoteRoot, path: String, in ws: WorkspaceManager) -> AgentMention {
        let name = path.isEmpty ? source.name : (path as NSString).lastPathComponent
        let url = ws.noteRootURL(source).map { path.isEmpty ? $0 : $0.appendingPathComponent(path) }
        let place = path.isEmpty ? "the top of the note source" : "folder \"\(path)\""
        let list = path.isEmpty ? "list_markdown_notes (source \"\(source.name)\")"
                                : "list_markdown_notes (source \"\(source.name)\", folder \"\(path)\")"
        return AgentMention(
            kind: .folder, id: source.id + "\u{1}" + path, name: name + "/",
            detail: path.isEmpty ? source.name : source.name + " / " + path,
            uri: url?.absoluteString ?? workspaceLink(ws).absoluteString,
            info: "A folder of Markdown notes in the UniReader workspace: note source \"\(source.name)\", \(place), "
                + "including its subfolders. List its notes with \(list) and read them with read_markdown.")
    }

    /// 一组 PDF（侧栏书库的段头：整个书库 / 未分组 / 某个分组）。`what` 是给 Agent 的那半句（它是哪一组）。
    static func documents(_ docs: [LibDocument], key: String, title: String, what: String,
                          in ws: WorkspaceManager) -> AgentMention {
        let shown = docs.prefix(40).map { "\"\($0.title)\" (document_id \($0.id))" }
        var list = shown.joined(separator: "; ")
        if docs.count > shown.count { list += "; and \(docs.count - shown.count) more (list_documents)" }
        return AgentMention(
            kind: .documents, id: key, name: title, detail: "", uri: workspaceLink(ws).absoluteString,
            info: "\(what) in the UniReader library, \(docs.count) PDF(s)" + (docs.isEmpty ? "." : ": \(list).")
                + " Read them through the unireader MCP tools.")
    }

    /// 一张画板。MCP 还没有读画板的工具，只给名字。
    static func board(_ b: BoardNote, in ws: WorkspaceManager) -> AgentMention {
        AgentMention(
            kind: .board, id: b.id.uuidString, name: b.displayName, detail: "", uri: workspaceLink(ws).absoluteString,
            info: "A board (a handwriting canvas) named \"\(b.displayName)\" in the UniReader workspace (board id \(b.id.uuidString)). "
                + "Its handwriting can't be read through the unireader MCP tools yet — only its name is known; "
                + "ask the user if you need what is on it.")
    }

    /// 全部画板（侧栏「画板」段头）。
    static func boards(_ bs: [BoardNote], title: String, in ws: WorkspaceManager) -> AgentMention {
        let names = bs.map { "\"\($0.displayName)\"" }.joined(separator: ", ")
        return AgentMention(
            kind: .boards, id: "boards", name: title, detail: "", uri: workspaceLink(ws).absoluteString,
            info: "All boards (handwriting canvases) in the UniReader workspace, \(bs.count)" + (bs.isEmpty ? "." : ": \(names).")
                + " Their handwriting can't be read through the unireader MCP tools yet — only their names are known.")
    }

    /// 习题的一组（侧栏「习题」那一段的任一行，或段头 = 全部）：名字用标签页标题那种全称（「高数 · 第一章」）。
    static func exercises(_ scope: ExerciseScope, count: Int?, in ws: WorkspaceManager) -> AgentMention {
        let title = ws.exerciseScopeTitle(scope)
        func book(_ id: String) -> String { "\"\(ws.document(id: id)?.title ?? id)\" (document_id \(id))" }
        func chapter(_ path: [String]) -> String {
            let json = (try? JSONSerialization.data(withJSONObject: path)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
            return path.isEmpty ? "the questions with no chapter (chapter [])" : "chapter \(json) and its sub-sections"
        }
        func args(_ id: String?, _ path: [String]?, _ filter: String?) -> String {
            var a: [String] = []
            if let id { a.append("document_id \(id)") } else { a.append("all_documents true") }
            if let path {
                let json = (try? JSONSerialization.data(withJSONObject: path)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
                a.append("chapter \(json)")
            }
            if let filter { a.append("filter \(filter)") }
            return "list_exercises (" + a.joined(separator: ", ") + ")"
        }
        let what: String, how: String
        switch scope {
        case .all: what = "all exercises in the workspace"; how = args(nil, nil, nil)
        case .wrong: what = "the user's mistake list (错题本)"; how = args(nil, nil, "mistakes")
        case .starred: what = "the user's starred exercises (收藏)"; how = args(nil, nil, "starred")
        case .document(let id): what = "the exercises of \(book(id))"; how = args(id, nil, nil)
        case .chapter(let id, let p): what = "the exercises of \(book(id)) in \(chapter(p))"; how = args(id, p, nil)
        case .wrongDocument(let id): what = "the mistakes (错题本) of \(book(id))"; how = args(id, nil, "mistakes")
        case .wrongChapter(let id, let p): what = "the mistakes (错题本) of \(book(id)) in \(chapter(p))"; how = args(id, p, "mistakes")
        case .starredDocument(let id): what = "the starred exercises (收藏) of \(book(id))"; how = args(id, nil, "starred")
        case .starredChapter(let id, let p): what = "the starred exercises (收藏) of \(book(id)) in \(chapter(p))"; how = args(id, p, "starred")
        }
        let n = count.map { ", \($0) question(s)" } ?? ""
        return AgentMention(
            kind: .exercises, id: scope.rowID, name: title, detail: "", uri: workspaceLink(ws).absoluteString,
            info: "A set of exercises (习题) in UniReader: \(what)\(n). List them with \(how).")
    }

    /// 工作区本身的 `unireader://` 链接（没有文件位置可给时的 uri）。
    private static func workspaceLink(_ ws: WorkspaceManager) -> DeepLink {
        var link = DeepLink()
        link.workspacePath = ws.folder?.path
        link.workspaceId = ws.store?.workspaceId
        return link
    }
}
