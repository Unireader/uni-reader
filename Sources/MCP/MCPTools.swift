import Foundation

/// 工具目录的装配（方案 §7）。每个工具 = 一个 `MCPTool`（说明 / schema / 处理函数），处理函数很薄：
/// 活状态 `await MainActor.run { MCPFacade… }`，读 PDF 走 `MCPDocReader`，然后拼 `MCPToolResult`。
enum MCPTools {
    /// 批 1：读取类 + 打开工作区/文档两个导航动作。
    static func registerBatch1(into server: MCPServer) {
        let c = server.catalog
        c.register(getState(server))
        c.register(listWorkspaces())
        c.register(openWorkspace())
        c.register(listDocuments())
        c.register(openDocument())
        c.register(getDocument())
        c.register(readPages())
    }

    // MARK: - 共用的 schema 片段

    /// 读取类工具共用的目标参数（方案 §6.1：都可省略 = key 窗口的活动标签）。
    static var targetProperties: [String: MCPObject] {
        ["document_id": MCPSchema.string("Library document id (UUID) from list_documents / get_state. Omit to use the document in the key window."),
         "path": MCPSchema.string("Absolute path of a PDF file outside any workspace (read-only; nothing is imported). Use either document_id or path."),
         "workspace": MCPSchema.string("Workspace .unrd path, only needed when the same document_id exists in several open workspaces.")]
    }

    static var workspaceDTOSchema: MCPObject {
        MCPSchema.object(["id": MCPSchema.string("workspace id"), "name": MCPSchema.string("workspace name"),
                          "path": MCPSchema.string(".unrd path"), "is_mirror": MCPSchema.boolean("offline mirror copy")])
    }

    static var documentDTOSchema: MCPObject {
        MCPSchema.object([
            "id": MCPSchema.string("document id"), "title": MCPSchema.string("title"),
            "page_count": MCPSchema.integer("pages"), "group": MCPSchema.string("group name, empty = ungrouped"),
            "read_page": MCPSchema.integer("last reading position, 1-based"), "read_frac": MCPSchema.number("position inside that page, 0 top … 1 bottom"),
            "last_opened_at": MCPSchema.string("ISO-8601"), "added_at": MCPSchema.string("ISO-8601"),
            "file": MCPSchema.object(["path": MCPSchema.string("absolute path or null"), "exists": MCPSchema.boolean("file present"),
                                      "in_workspace": MCPSchema.boolean("copy lives inside the workspace package")]),
            "content_hash": MCPSchema.string("SHA-256 of the file"),
            "open_in": MCPSchema.array(of: MCPSchema.string("session id"), "tabs currently showing it"),
        ])
    }

    // MARK: - 共用的文本拼装

    static func describeTab(_ t: MCPObject) -> String {
        guard let doc = t["document_id"] as? String else { return "(empty tab)" }
        let title = (t["title"] as? String) ?? doc
        let page = (t["page"] as? Int) ?? 0
        let count = (t["page_count"] as? Int) ?? 0
        let missing = (t["file_missing"] as? Bool) == true ? " · FILE MISSING" : ""
        return "\(title) — page \(page)/\(count)\(missing) · document_id \(doc)"
    }

    static func describeDocument(_ d: MCPObject) -> String {
        let title = (d["title"] as? String) ?? "?"
        let id = (d["id"] as? String) ?? "?"
        let pages = (d["page_count"] as? Int) ?? 0
        let read = (d["read_page"] as? Int) ?? 1
        let group = (d["group"] as? String) ?? ""
        let exists = ((d["file"] as? MCPObject)?["exists"] as? Bool) ?? false
        let open = ((d["open_in"] as? [String]) ?? []).isEmpty ? "" : " · open"
        var s = "- \(title) · \(pages) pages · last at page \(read)\(open)"
        if !group.isEmpty { s += " · group “\(group)”" }
        if !exists { s += " · FILE MISSING" }
        s += " · id \(id)"
        return s
    }

    static func describeTOC(_ entries: [MCPObject], depth: Int = 0, into out: inout [String]) {
        for e in entries {
            let indent = String(repeating: "  ", count: depth)
            let title = (e["title"] as? String) ?? ""
            if let p = e["page"] as? Int { out.append("\(indent)- \(title) … p.\(p)") } else { out.append("\(indent)- \(title)") }
            if let kids = e["children"] as? [MCPObject], !kids.isEmpty { describeTOC(kids, depth: depth + 1, into: &out) }
        }
    }
}
