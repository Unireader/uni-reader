import AppKit
import SwiftUI

/// 设置 › Agent：MCP 服务的开关 / 监听地址 / 端口 / 口令 / 客户端配置片段 / 最近调用（方案 §10）。
/// 系统标准控件，不自绘；material 底上的文字显式 `.primary`（红线）。
struct MCPSettingsView: View {
    @ObservedObject var mcp: MCPServer

    @AppStorage(MCPServer.autoStartKey) private var autoStart = false
    @AppStorage(MCPServer.bindKey) private var bindRaw = MCPServer.Bind.loopback.rawValue
    @AppStorage(MCPServer.portKey) private var port = MCPServer.defaultPort
    /// 写入开关（方案 §9.1）：关着时写入工具照常列出，调用时拦下并提示来这里开。
    @AppStorage(MCPServer.allowWritesKey) private var allowWrites = false
    /// 口令的界面镜像（本体在 Keychain，`MCPToken`）。
    @State private var token: String? = MCPToken.current()

    private var bind: MCPServer.Bind { MCPServer.Bind(rawValue: bindRaw) ?? .loopback }
    private var portValid: Bool { port >= 1024 && port <= 65535 }

    /// 按**当前设置**算出来的端点（服务没开也能给配置片段）。
    private var configuredURL: String {
        let host = bind == .all ? (NetInfo.wifiIPv4() ?? "127.0.0.1") : "127.0.0.1"
        return "http://\(host):\(portValid ? port : MCPServer.defaultPort)/mcp"
    }

    private var cliSnippet: String {
        var s = "claude mcp add --transport http unireader \(configuredURL)"
        if let token { s += " --header \"Authorization: Bearer \(token)\"" }
        return s
    }

    private var jsonSnippet: String {
        var server: MCPObject = ["type": "http", "url": configuredURL]
        if let token { server["headers"] = ["Authorization": "Bearer \(token)"] }
        return MCPJSON.string(["mcpServers": ["unireader": server]], pretty: true)
    }

    var body: some View {
        Form {
            serviceSection
            writesSection
            listenSection
            tokenSection
            configSection
            clientsSection
            callsSection
        }
        .formStyle(.grouped)
    }

    // MARK: - 写入

    private var writesSection: some View {
        Section {
            Toggle(L("Allow agents to write"), isOn: $allowWrites)
        } header: {
            Text(L("Writing"))
        } footer: {
            Text(L("Lets agents add bookmarks, text notes and highlights, import PDFs, create workspaces and start OCR. Notes written by an agent are marked with a terminal icon. Agents can never delete anything."))
        }
    }

    // MARK: - 服务

    private var serviceSection: some View {
        Section {
            Toggle(L("Start MCP service on launch"), isOn: $autoStart)
                .onChange(of: autoStart) { _, on in
                    if on, !mcp.isRunning { mcp.start() }   // 打开即启，同平板服务
                }
            LabeledContent(L("Status")) {
                if mcp.isRunning {
                    Text(String(format: L("Running at %@"), mcp.endpointURL)).textSelection(.enabled)
                } else {
                    Text(L("Stopped"))
                }
            }
            HStack {
                Button(mcp.isRunning ? L("Stop") : L("Start")) {
                    if mcp.isRunning { mcp.stop() } else { mcp.start() }
                }
                if mcp.isRunning {
                    Button(L("Restart")) { mcp.restart() }
                }
            }
            if let err = mcp.lastError {
                Text(err).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            Text(L("Agent (MCP) Service"))
        } footer: {
            Text(L("Lets AI agents on this Mac (Claude Code, Codex, …) see what you are reading, open documents and read page text through the Model Context Protocol."))
        }
    }

    // MARK: - 监听

    private var listenSection: some View {
        Section {
            Picker(L("Listen on"), selection: $bindRaw) {
                Text(L("This Mac only (127.0.0.1)")).tag(MCPServer.Bind.loopback.rawValue)
                Text(L("All network interfaces")).tag(MCPServer.Bind.all.rawValue)
            }
            .onChange(of: bindRaw) { _, raw in
                // 🔴 所有接口模式必须有口令：切过去的那一刻没有就生成一个（方案 §4.6）
                if raw == MCPServer.Bind.all.rawValue, token == nil { token = MCPToken.regenerate() }
                restartIfRunning()
            }
            TextField(L("Port"), value: $port, format: .number.grouping(.never))
                .onSubmit { if portValid { restartIfRunning() } }
            if !portValid {
                Text(L("Port must be between 1024 and 65535.")).foregroundStyle(.red)
            } else {
                Text(L("Press Return to apply a port change.")).font(.callout)
            }
        } header: {
            Text(L("Network"))
        } footer: {
            if bind == .all {
                Text(L("Reachable from other machines on the local network over plain HTTP; the token travels in the clear, same as the tablet pairing code. A token is required in this mode. macOS may ask once whether to allow incoming connections."))
            } else {
                Text(L("Only programs running on this Mac can connect. A token is optional here."))
            }
        }
    }

    // MARK: - 口令

    private var tokenSection: some View {
        Section {
            if let token {
                LabeledContent(L("Token")) {
                    Text(token).font(.body.monospaced()).textSelection(.enabled)
                }
                HStack {
                    Button(L("Copy")) { copy(token) }
                    Button(L("Reset Token")) {
                        self.token = MCPToken.regenerate()
                        restartIfRunning()
                    }
                    Button(L("Remove Token")) {
                        MCPToken.remove()
                        self.token = nil
                        restartIfRunning()
                    }
                    .disabled(bind == .all)   // 所有接口模式下口令必有
                }
            } else {
                Text(L("No token set. Any program on this Mac can connect."))
                Button(L("Set Token")) {
                    token = MCPToken.regenerate()
                    restartIfRunning()
                }
            }
        } header: {
            Text(L("Token"))
        } footer: {
            Text(L("Clients must send it as “Authorization: Bearer <token>”. Changing or removing it restarts the service and disconnects current clients."))
        }
    }

    // MARK: - 客户端配置

    private var configSection: some View {
        Section {
            snippetRow(L("Claude Code"), cliSnippet)
            snippetRow(L("Generic JSON (mcpServers)"), jsonSnippet)
        } header: {
            Text(L("Client Configuration"))
        } footer: {
            Text(L("Other clients need the same URL (and the token header, if set); see their documentation for the exact syntax."))
        }
    }

    @ViewBuilder private func snippetRow(_ title: String, _ snippet: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                Spacer()
                Button(L("Copy")) { copy(snippet) }
            }
            Text(snippet)
                .font(.callout.monospaced())
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - 客户端 / 最近调用

    private var clientsSection: some View {
        Section {
            if mcp.clients.isEmpty {
                Text(L("No client connected.")).foregroundStyle(.primary)
            } else {
                ForEach(mcp.clients) { c in
                    LabeledContent(c.name.isEmpty ? "?" : c.name) {
                        Text("\(c.version) · MCP \(c.protocolVersion) · \(c.since.formatted(date: .omitted, time: .shortened))")
                    }
                }
            }
        } header: {
            Text(L("Connected Clients"))
        }
    }

    private var callsSection: some View {
        Section {
            if mcp.recentCalls.isEmpty {
                Text(L("No calls yet.")).foregroundStyle(.primary)
            } else {
                ForEach(mcp.recentCalls) { r in
                    LabeledContent {
                        Text(r.ok ? "\(r.ms) ms" : r.summary)
                            .foregroundStyle(r.ok ? Color.primary : Color.red)
                            .lineLimit(2)
                    } label: {
                        Text("\(r.at.formatted(date: .omitted, time: .standard)) · \(r.client) · \(r.what)")
                    }
                }
            }
        } header: {
            Text(L("Recent Calls"))
        }
    }

    // MARK: - 动作

    private func restartIfRunning() {
        if mcp.isRunning { mcp.restart() }
    }

    private func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }
}
