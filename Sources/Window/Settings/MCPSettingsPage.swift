import AppKit
import Combine

/// 设置 › Agent：MCP 服务的开关 / 监听地址 / 端口 / 口令 / 客户端配置片段 / 已连客户端 / 最近调用（`MCP-PLAN.md §10`），
/// 以及 Agent 面板启动哪条命令（`ACP-AGENT-PLAN.md`）。
final class MCPSettingsPage: SettingsPage, NSTextFieldDelegate {
    let mcp: MCPServer
    private var bag = Set<AnyCancellable>()
    private var token: String? = MCPToken.current()
    private var service: FormSection!
    private var agent: FormSection!
    private var network: FormSection!
    private var tokenSection: FormSection!
    private var config: FormSection!
    private var clients: FormSection!
    private var calls: FormSection!
    private let commandField = NSTextField()
    private let argsField = NSTextField()
    private let portField = NSTextField()
    private let portHint = FormSection.text("")
    private var resolvedLabel: NSTextField!
    private var resolveTask: Task<Void, Never>?

    init(mcp: MCPServer) {
        self.mcp = mcp
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) 不支持") }

    private var d: UserDefaults { .standard }
    private var bind: MCPServer.Bind { MCPServer.Bind(rawValue: d.string(forKey: MCPServer.bindKey) ?? "") ?? .loopback }
    private var port: Int { d.object(forKey: MCPServer.portKey) as? Int ?? MCPServer.defaultPort }
    private func portValid(_ p: Int) -> Bool { p >= 1024 && p <= 65535 }

    /// 按当前设置算出来的端点（服务没开也能给配置片段）。
    private var configuredURL: String {
        let host = bind == .all ? (NetInfo.wifiIPv4() ?? "127.0.0.1") : "127.0.0.1"
        return "http://\(host):\(portValid(port) ? port : MCPServer.defaultPort)/mcp"
    }

    override func build() {
        service = section(L("Agent (MCP) Service"), footer: L("Lets AI agents on this Mac (Claude Code, Codex, …) see what you are reading, open documents and read page text through the Model Context Protocol."))
        service.dynamic { [weak self] s in self?.buildService(s) }

        agent = section(L("Agent Panel"), footer: L("The Agent panel talks to a local agent over the Agent Client Protocol (ACP) and hands it this MCP service automatically. Install and sign in to the agent in Terminal yourself (for Kimi: “kimi login”). Changes apply to new chats."))
        commandField.stringValue = d.string(forKey: AgentConfig.commandKey) ?? ""
        commandField.placeholderString = AgentConfig.defaultCommand
        argsField.stringValue = d.string(forKey: AgentConfig.argumentsKey) ?? AgentConfig.defaultArguments
        argsField.placeholderString = AgentConfig.defaultArguments
        for f in [commandField, argsField] {
            f.delegate = self
            f.widthAnchor.constraint(equalToConstant: FormMetrics.controlWidth).isActive = true
        }
        resolvedLabel = FormSection.text("", selectable: true)
        agent.row(L("Command"), commandField)
        agent.row(L("Arguments"), argsField)
        agent.row(L("Resolved"), resolvedLabel)
        resolveCommand()

        let writes = section(L("Writing"), footer: L("Lets agents add bookmarks, text notes and highlights, import PDFs, create workspaces and start OCR. Notes written by an agent are marked with a terminal icon. Agents can never delete anything."))
        writes.row(nil, FormCheckbox(L("Allow agents to write"), on: d.bool(forKey: MCPServer.allowWritesKey)) { [weak self] in
            self?.d.set($0, forKey: MCPServer.allowWritesKey)
        })

        network = section(L("Network"))
        portField.stringValue = String(port)
        portField.delegate = self
        portField.widthAnchor.constraint(equalToConstant: 90).isActive = true
        network.dynamic { [weak self] s in self?.buildNetwork(s) }

        tokenSection = section(L("Token"), footer: L("Clients must send it as “Authorization: Bearer <token>”. Changing or removing it restarts the service and disconnects current clients."))
        tokenSection.dynamic { [weak self] s in self?.buildToken(s) }

        config = section(L("Client Configuration"), footer: L("Other clients need the same URL (and the token header, if set); see their documentation for the exact syntax."))
        config.dynamic { [weak self] s in self?.buildConfig(s) }

        clients = section(L("Connected Clients"))
        clients.dynamic { [weak self] s in self?.buildClients(s) }
        calls = section(L("Recent Calls"))
        calls.dynamic { [weak self] s in self?.buildCalls(s) }

        mcp.objectWillChange.receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.service.rebuild()
                self?.clients.rebuild()
                self?.calls.rebuild()
            }.store(in: &bag)
    }

    // MARK: 服务

    private func buildService(_ s: FormSection) {
        s.row(nil, FormCheckbox(L("Start MCP service on launch"), on: d.bool(forKey: MCPServer.autoStartKey)) { [weak self] on in
            guard let self else { return }
            self.d.set(on, forKey: MCPServer.autoStartKey)
            if on, !self.mcp.isRunning { self.mcp.start() }   // 打开即启，同平板服务
        })
        s.row(L("Status"), FormSection.text(mcp.isRunning ? String(format: L("Running at %@"), mcp.endpointURL) : L("Stopped"),
                                            selectable: true))
        var buttons: [NSView] = [FormButton(mcp.isRunning ? L("Stop") : L("Start")) { [weak self] in
            guard let self else { return }
            if self.mcp.isRunning { self.mcp.stop() } else { self.mcp.start() }
        }]
        if mcp.isRunning { buttons.append(FormButton(L("Restart")) { [weak self] in self?.mcp.restart() }) }
        s.row(nil, FormSection.hstack(buttons))
        if let err = mcp.lastError { s.row(nil, FormSection.text(err, color: .systemRed)) }
    }

    // MARK: 监听

    private func buildNetwork(_ s: FormSection) {
        s.row(L("Listen on"), FormPopup([(L("This Mac only (127.0.0.1)"), MCPServer.Bind.loopback.rawValue),
                                         (L("All network interfaces"), MCPServer.Bind.all.rawValue)],
                                        selected: bind.rawValue) { [weak self] raw in
            guard let self else { return }
            self.d.set(raw, forKey: MCPServer.bindKey)
            // 所有接口模式必须有口令：切过去的那一刻没有就生成一个（方案 §4.6）
            if raw == MCPServer.Bind.all.rawValue, self.token == nil { self.token = MCPToken.regenerate() }
            self.restartIfRunning()
            self.network.rebuild()
            self.tokenSection.rebuild()
            self.config.rebuild()
        })
        s.row(L("Port"), portField)
        s.row(nil, portHint)
        refreshPortHint()
        s.setFooter(bind == .all
            ? L("Reachable from other machines on the local network over plain HTTP; the token travels in the clear, same as the tablet pairing code. A token is required in this mode. macOS may ask once whether to allow incoming connections.")
            : L("Only programs running on this Mac can connect. A token is optional here."))
    }

    // MARK: 口令

    private func buildToken(_ s: FormSection) {
        if let token {
            s.row(L("Token"), FormSection.text(token, selectable: true, mono: true))
            let remove = FormButton(L("Remove Token")) { [weak self] in
                MCPToken.remove()
                self?.token = nil
                self?.tokenChanged()
            }
            remove.isEnabled = bind != .all   // 所有接口模式下口令必有
            s.row(nil, FormSection.hstack([
                FormButton(L("Copy")) { copyToPasteboard(token) },
                FormButton(L("Reset Token")) { [weak self] in
                    self?.token = MCPToken.regenerate()
                    self?.tokenChanged()
                },
                remove,
            ]))
        } else {
            s.full(FormSection.text(L("No token set. Any program on this Mac can connect.")))
            s.row(nil, FormButton(L("Set Token")) { [weak self] in
                self?.token = MCPToken.regenerate()
                self?.tokenChanged()
            })
        }
    }

    private func tokenChanged() {
        restartIfRunning()
        tokenSection.rebuild()
        config.rebuild()
    }

    // MARK: 客户端配置

    private func buildConfig(_ s: FormSection) {
        var cli = "claude mcp add --transport http unireader \(configuredURL)"
        if let token { cli += " --header \"Authorization: Bearer \(token)\"" }
        var server: MCPObject = ["type": "http", "url": configuredURL]
        if let token { server["headers"] = ["Authorization": "Bearer \(token)"] }
        let json = MCPJSON.string(["mcpServers": ["unireader": server]], pretty: true)
        for (title, snippet) in [(L("Claude Code"), cli), (L("Generic JSON (mcpServers)"), json)] {
            let head = FormSection.hstack([NSTextField(labelWithString: title), NSView(), FormButton(L("Copy")) { copyToPasteboard(snippet) }])
            head.translatesAutoresizingMaskIntoConstraints = false
            head.widthAnchor.constraint(equalToConstant: FormMetrics.columnWidth).isActive = true
            s.full(head)
            let code = NSTextField(wrappingLabelWithString: snippet)
            code.isSelectable = true
            code.font = .monospacedSystemFont(ofSize: NSFont.preferredFont(forTextStyle: .callout).pointSize, weight: .regular)
            code.preferredMaxLayoutWidth = FormMetrics.columnWidth
            s.full(code)
        }
    }

    // MARK: 已连客户端 / 最近调用

    private func buildClients(_ s: FormSection) {
        if mcp.clients.isEmpty {
            s.full(FormSection.text(L("No client connected.")))
        }
        for c in mcp.clients {
            s.row(c.name.isEmpty ? "?" : c.name,
                  FormSection.text("\(c.version) · MCP \(c.protocolVersion) · \(c.since.formatted(date: .omitted, time: .shortened))"))
        }
    }

    private func buildCalls(_ s: FormSection) {
        if mcp.recentCalls.isEmpty {
            s.full(FormSection.text(L("No calls yet.")))
        }
        for r in mcp.recentCalls {
            let v = FormSection.text(r.ok ? "\(r.ms) ms" : r.summary, color: r.ok ? .labelColor : .systemRed)
            v.maximumNumberOfLines = 2
            s.row("\(r.at.formatted(date: .omitted, time: .standard)) · \(r.client) · \(r.what)", v)
        }
    }

    // MARK: 输入框

    func controlTextDidChange(_ obj: Notification) {
        guard let f = obj.object as? NSTextField else { return }
        if f === commandField {
            d.set(f.stringValue, forKey: AgentConfig.commandKey)
            resolveCommand()
        } else if f === argsField {
            d.set(f.stringValue, forKey: AgentConfig.argumentsKey)
        } else if f === portField {
            refreshPortHint()
        }
    }

    private func refreshPortHint() {
        if portValid(Int(portField.stringValue) ?? -1) {
            portHint.stringValue = L("Press Return to apply a port change.")
            portHint.textColor = .secondaryLabelColor
        } else {
            portHint.stringValue = L("Port must be between 1024 and 65535.")
            portHint.textColor = .systemRed
        }
    }

    /// 端口：回车才生效（边输边重启服务不合适）。
    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        guard control === portField, sel == #selector(NSResponder.insertNewline(_:)) else { return false }
        commitPort()
        return true
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        if (obj.object as? NSTextField) === portField { commitPort() }
    }

    private func commitPort() {
        let p = Int(portField.stringValue) ?? -1
        if portValid(p), p != port {
            d.set(p, forKey: MCPServer.portKey)
            restartIfRunning()
            config.rebuild()
        }
        refreshPortHint()
    }

    /// 命令解析出来的绝对路径（按登录 shell 的 PATH 找）。
    private func resolveCommand() {
        resolveTask?.cancel()
        resolveTask = Task { [weak self] in
            let path = try? await AgentConfig.resolveExecutable(AgentConfig.command)
            guard !Task.isCancelled else { return }
            self?.resolvedLabel.stringValue = path ?? L("Not found")
        }
    }

    private func restartIfRunning() { if mcp.isRunning { mcp.restart() } }
}
