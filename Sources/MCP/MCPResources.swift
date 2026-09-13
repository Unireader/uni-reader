import Foundation

/// MCP 资源（方案 §8，批 2）：给支持资源的客户端一个「把某页当附件拖进上下文」的入口。
/// **内容与同名工具完全一致**——每条 URI 就是调一次对应的工具再取它的 `structuredContent` / 图片，不另起一套读法。
///
/// | URI | 等价工具 | mime |
/// |---|---|---|
/// | `unireader://state` | `get_state` | application/json |
/// | `unireader://doc/{document_id}` | `get_document` | application/json |
/// | `unireader://doc/{document_id}/toc` | `get_document` 的 `toc` | application/json |
/// | `unireader://doc/{document_id}/page/{page}` | `read_pages` 单页 | text/plain |
/// | `unireader://doc/{document_id}/page/{page}/image` | `render_page`（1080 宽 JPEG） | image/jpeg |
enum MCPResources {
    static let scheme = "unireader://"

    static func provider(catalog: MCPCatalog) -> MCPResourceProvider {
        MCPResourceProvider(
            list: { await list() },
            templates: templates,
            read: { uri in try await read(uri, catalog: catalog) })
    }

    static let templates: [MCPObject] = [
        ["uriTemplate": "unireader://state", "name": "UniReader state", "mimeType": "application/json",
         "description": "Open windows, workspaces, tabs and current pages (same as get_state)."],
        ["uriTemplate": "unireader://doc/{document_id}", "name": "Document overview", "mimeType": "application/json",
         "description": "Page count, text availability and outline (same as get_document)."],
        ["uriTemplate": "unireader://doc/{document_id}/toc", "name": "Document outline", "mimeType": "application/json",
         "description": "Outline tree with 1-based pages."],
        ["uriTemplate": "unireader://doc/{document_id}/page/{page}", "name": "Page text", "mimeType": "text/plain",
         "description": "Text of one page (PDF text, or cached OCR text for scanned pages)."],
        ["uriTemplate": "unireader://doc/{document_id}/page/{page}/image", "name": "Page image", "mimeType": "image/jpeg",
         "description": "The page rendered as a 1080px-wide JPEG."],
    ]

    /// `resources/list`：状态 + 此刻开着的每篇文档一条。
    private static func list() async -> [MCPObject] {
        var out: [MCPObject] = [["uri": "unireader://state", "name": "UniReader state", "mimeType": "application/json"]]
        let state = await MainActor.run { MCPFacade.shared.state(mcp: nil) }
        var seen = Set<String>()
        for w in (state["windows"] as? [MCPObject]) ?? [] {
            for t in (w["tabs"] as? [MCPObject]) ?? [] {
                guard let id = t["document_id"] as? String, !seen.contains(id) else { continue }
                seen.insert(id)
                let title = (t["title"] as? String) ?? id
                out.append(["uri": "unireader://doc/\(id)", "name": title, "mimeType": "application/json",
                            "description": "\(title) · \(t["page_count"] ?? 0) pages, currently open"])
            }
        }
        return out
    }

    private static func read(_ uri: String, catalog: MCPCatalog) async throws -> MCPResourceContent {
        guard uri.hasPrefix(scheme) else { throw MCPResourceNotFound(uri: uri) }
        let parts = uri.dropFirst(scheme.count).split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        // 资源读取不受写入开关影响（全是读取类工具），来源标成 resource 便于日志分辨
        let ctx = MCPCallContext(clientName: "resource", clientVersion: "", writesEnabled: false)

        func call(_ name: String, _ args: MCPObject) async throws -> MCPObject {
            let r = try await catalog.call(name: name, arguments: args, context: ctx)
            if r["isError"] as? Bool == true {
                let msg = ((r["content"] as? [MCPObject])?.first?["text"] as? String) ?? "failed"
                throw MCPToolError(msg)
            }
            return r
        }
        func structured(_ r: MCPObject) -> MCPObject { (r["structuredContent"] as? MCPObject) ?? [:] }

        // 数组字面量模式不支持 `let` 绑定，按段数与固定段手工匹配
        if parts == ["state"] {
            let r = try await call("get_state", [:])
            return MCPResourceContent(uri: uri, mimeType: "application/json", text: MCPJSON.string(structured(r), pretty: true))
        }
        guard parts.count >= 2, parts[0] == "doc", !parts[1].isEmpty else { throw MCPResourceNotFound(uri: uri) }
        let id = parts[1]
        switch parts.count {
        case 2:
            let r = try await call("get_document", ["document_id": id, "include_toc": true])
            return MCPResourceContent(uri: uri, mimeType: "application/json", text: MCPJSON.string(structured(r), pretty: true))
        case 3 where parts[2] == "toc":
            let r = try await call("get_document", ["document_id": id, "include_toc": true])
            return MCPResourceContent(uri: uri, mimeType: "application/json",
                                      text: MCPJSON.string(["toc": structured(r)["toc"] ?? []], pretty: true))
        case 4 where parts[2] == "page":
            guard let page = Int(parts[3]) else { throw MCPResourceNotFound(uri: uri) }
            let r = try await call("read_pages", ["document_id": id, "pages": page])
            let pages = (structured(r)["pages"] as? [MCPObject]) ?? []
            return MCPResourceContent(uri: uri, mimeType: "text/plain", text: (pages.first?["text"] as? String) ?? "")
        case 5 where parts[2] == "page" && parts[4] == "image":
            guard let page = Int(parts[3]) else { throw MCPResourceNotFound(uri: uri) }
            let r = try await call("render_page", ["document_id": id, "page": page, "width": 1080, "format": "jpeg"])
            guard let img = ((r["content"] as? [MCPObject]) ?? []).first(where: { $0["type"] as? String == "image" }),
                  let b64 = img["data"] as? String, let data = Data(base64Encoded: b64) else {
                throw MCPToolError("render failed")
            }
            return MCPResourceContent(uri: uri, mimeType: (img["mimeType"] as? String) ?? "image/jpeg", blob: data)
        default:
            throw MCPResourceNotFound(uri: uri)
        }
    }
}
