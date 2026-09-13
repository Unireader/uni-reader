import Foundation

/// 批 1：`get_state` / `list_workspaces` / `open_workspace`（方案 §7.1 ~ §7.3）。
extension MCPTools {
    static func getState(_ server: MCPServer) -> MCPTool {
        MCPTool(
            name: "get_state",
            title: "Current UniReader state",
            description: "What the user has open right now: every reader window, its workspace and tabs (document, current page, zoom), which window is key, whether the tablet service is running. Call this first.",
            inputSchema: MCPSchema.object([:]),
            outputSchema: MCPSchema.object([
                "app": MCPSchema.object(["version": MCPSchema.string("UniReader version"), "pid": MCPSchema.integer("process id"),
                                         "writes_enabled": MCPSchema.boolean("write tools allowed in Settings"),
                                         "bind": MCPSchema.enumeration(["loopback", "all"], "where the MCP service listens")]),
                "key_window_id": MCPSchema.string("window id of the key window, or null"),
                "windows": MCPSchema.array(of: MCPSchema.object([
                    "window_id": MCPSchema.string("window id"), "is_key": MCPSchema.boolean("is the key window"),
                    "workspace": workspaceDTOSchema,
                    "tabs": MCPSchema.array(of: MCPSchema.object([
                        "session_id": MCPSchema.string("tab / session id"), "is_active": MCPSchema.boolean("the visible tab"),
                        "document_id": MCPSchema.string("library document id, null for an empty tab"),
                        "title": MCPSchema.string("document title"), "page": MCPSchema.integer("current page, 1-based"),
                        "page_count": MCPSchema.integer("pages"), "zoom": MCPSchema.number("zoom relative to fit-width"),
                        "canvas_mode": MCPSchema.boolean("canvas mode on"), "file_missing": MCPSchema.boolean("file could not be found")])),
                ])),
                "tablet": MCPSchema.object(["running": MCPSchema.boolean("tablet service on"), "clients": MCPSchema.integer("connected tablets")]),
            ]),
            tier: .read
        ) { _, _ in
            let state = await MainActor.run { MCPFacade.shared.state(mcp: server) }
            var lines: [String] = []
            let windows = (state["windows"] as? [MCPObject]) ?? []
            if windows.isEmpty {
                lines.append("No reader window is open. Use list_workspaces + open_workspace.")
            }
            for w in windows {
                let ws = (w["workspace"] as? MCPObject) ?? [:]
                let key = (w["is_key"] as? Bool) == true ? " (key window)" : ""
                lines.append("Window \(w["window_id"] ?? "")\(key) · workspace “\(ws["name"] ?? "")” at \(ws["path"] ?? "")")
                for t in (w["tabs"] as? [MCPObject]) ?? [] {
                    let active = (t["is_active"] as? Bool) == true ? "* " : "  "
                    lines.append("  \(active)\(describeTab(t)) · session_id \(t["session_id"] ?? "")")
                }
            }
            if let app = state["app"] as? MCPObject {
                lines.append("Writes enabled: \((app["writes_enabled"] as? Bool) == true ? "yes" : "no")")
            }
            return MCPToolResult(text: lines.joined(separator: "\n"), structured: state)
        }
    }

    static func listWorkspaces() -> MCPTool {
        MCPTool(
            name: "list_workspaces",
            title: "List workspaces",
            description: "Workspaces (.unrd packages) UniReader knows: the ones open now and the recent list. Nothing is scanned on disk.",
            inputSchema: MCPSchema.object([:]),
            outputSchema: MCPSchema.object([
                "workspaces": MCPSchema.array(of: MCPSchema.object([
                    "id": MCPSchema.string("workspace id"), "name": MCPSchema.string("name"), "path": MCPSchema.string(".unrd path"),
                    "is_open": MCPSchema.boolean("has a window"), "available": MCPSchema.boolean("folder is reachable (recent entries only)"),
                    "is_mirror": MCPSchema.boolean("offline mirror copy"), "mirror_path": MCPSchema.string("local mirror path, if any"),
                    "window_ids": MCPSchema.array(of: MCPSchema.string("window id"))])),
            ]),
            tier: .read
        ) { _, _ in
            let r = await MainActor.run { MCPFacade.shared.workspaces() }
            let list = (r["workspaces"] as? [MCPObject]) ?? []
            var lines = list.map { w -> String in
                let open = (w["is_open"] as? Bool) == true ? " · open" : ((w["available"] as? Bool) == false ? " · not reachable" : "")
                return "- \(w["name"] ?? "") · \(w["path"] ?? "")\(open)"
            }
            if lines.isEmpty { lines = ["No workspace known yet."] }
            return MCPToolResult(text: lines.joined(separator: "\n"), structured: r)
        }
    }

    static func openWorkspace() -> MCPTool {
        MCPTool(
            name: "open_workspace",
            title: "Open a workspace",
            description: "Open a workspace (.unrd package) in a reader window, or bring its existing window to front. Same as double-clicking the package in Finder.",
            inputSchema: MCPSchema.object([
                "path": MCPSchema.string("Absolute path of the .unrd workspace package"),
                "activate": MCPSchema.boolean("Bring UniReader and the window to front", default: true),
            ], required: ["path"]),
            outputSchema: MCPSchema.object([
                "workspace": workspaceDTOSchema, "window_id": MCPSchema.string("window showing it"),
                "was_open": MCPSchema.boolean("a window already existed"),
            ]),
            tier: .navigate
        ) { _, args in
            let path = try args.requiredString("path")
            let activate = try args.bool("activate", default: true)
            let r = try await MainActor.run { try MCPFacade.shared.openWorkspace(path: path, activate: activate) }
            let ws = (r["workspace"] as? MCPObject) ?? [:]
            let was = (r["was_open"] as? Bool) == true
            return MCPToolResult(text: "\(was ? "Activated" : "Opened") workspace “\(ws["name"] ?? "")” · window_id \(r["window_id"] ?? "")",
                                 structured: r)
        }
    }
}
