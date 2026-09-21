import ACPModel
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// 发给 Agent 的「用户此刻在看什么」。每次发消息时现取（不缓存），变了才随消息带上。
struct AgentReaderContext: Equatable {
    struct MarkdownNote: Equatable {
        var ref: String
        var title: String
        var sourceName: String
        var sourceKind: String
        var relativePath: String
        var link: String
    }

    var workspaceName: String
    /// 工作区 `.unrd` 包本身（Agent 的工作目录是它的上一级）。
    var workspaceFolder: URL
    /// MCP 的 `window_id` / `session_id`（标签）——给 Agent 精确指定目标用。
    var windowId: UUID?
    var tabId: UUID?
    var documentId: String?
    var docTitle: String
    /// 0 起（发给 Agent 时换成 1 起，与 MCP 一致）。
    var page: Int
    var pageCount: Int
    /// 活动标签是整篇 Markdown 笔记时非 nil；与 `documentId` 互斥。
    var markdown: MarkdownNote?

    /// Agent 的工作目录 = 工作区包所在的目录（用户 2026-09-18 定）。
    var cwd: URL { workspaceFolder.deletingLastPathComponent() }

    /// 上下文块正文（英文：给模型看的；标签对见 `AgentTranscript.contextOpen`，回放时据此剔掉）。
    var promptText: String {
        let pkg = workspaceFolder.lastPathComponent
        var lines = [
            AgentTranscript.contextOpen,
            "The user is talking to you from the Agent panel of UniReader, a PDF and Markdown note reader. Reply in the user's language.",
            "Workspace: \(workspaceName). Its library lives in the package \"\(pkg)\" inside your working directory. Never read or modify files inside that .unrd package directly; use the unireader MCP tools for anything in the library (documents, pages, notes, highlights, bookmarks).",
        ]
        if let markdown {
            var s = "Current Markdown note: \"\(markdown.title)\" (note_ref \(markdown.ref), source \"\(markdown.sourceName)\" [\(markdown.sourceKind)], relative_path \"\(markdown.relativePath)\")"
            if let tabId { s += ", reader tab session_id \(tabId.uuidString)" }
            if let windowId { s += ", window_id \(windowId.uuidString)" }
            lines.append(s + ".")
            lines.append("Use the unireader get_current_view tool to read the note's current live text and revision. To modify it, use update_markdown with that revision; never edit the file directly.")
            lines.append("link \(markdown.link)")
        } else if let documentId {
            var s = "Current document: \"\(docTitle)\" (document_id \(documentId)), page \(page + 1) of \(pageCount)"
            if let tabId { s += ", reader tab session_id \(tabId.uuidString)" }
            if let windowId { s += ", window_id \(windowId.uuidString)" }
            lines.append(s + ".")
        } else {
            lines.append("No document is open in the reader right now.")
        }
        lines.append(AgentTranscript.contextClose)
        return lines.joined(separator: "\n")
    }
}

/// Agent 发来的一次权限请求，等用户在面板里点选项。
struct AgentPermissionAsk: Identifiable {
    struct Option: Identifiable { let id: String; let name: String; let kind: String }
    let id = UUID()
    let title: String
    let detail: String
    let options: [Option]
    fileprivate let resume: (RequestPermissionResponse) -> Void
}

/// 会话里可调的一项配置（模型、推理强度……Agent 给什么就列什么）。
struct AgentConfigItem: Identifiable {
    enum Kind {
        case select(current: String, options: [(value: String, name: String)])
        case toggle(Bool)
    }
    let id: String
    let name: String
    let kind: Kind
}

/// 一段 Agent 对话（一个宿主 × 一个工作目录一份）。**不落库**：历史由 Agent 自己按工作目录保存，
/// 面板要看旧对话时用 `session/list` 列、`session/load` 回放（用户 2026-09-18：「我们不保存具体数据」）。
@MainActor
final class AgentChat: ObservableObject {
    enum Phase: Equatable {
        case idle, connecting, loading, running
        case failed(String)
    }

    let cwd: URL
    /// 现取「用户在看什么」。宿主决定来源：内置面板 = 它所在的阅读窗口；浮窗 = 最近的 key 阅读窗口。
    var contextProvider: () -> AgentReaderContext? = { nil }

    @Published private(set) var items: [AgentItem] = []
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var sessionId: String?
    @Published private(set) var title: String?
    @Published private(set) var modes: [ModeInfo] = []
    @Published private(set) var currentMode: String?
    @Published private(set) var configs: [AgentConfigItem] = []
    @Published private(set) var permissions: [AgentPermissionAsk] = []
    @Published private(set) var history: [SessionInfo] = []
    /// 这段会话建立时 MCP 服务没开 → Agent 手上没有 unireader 工具。面板据此提示。
    @Published private(set) var missingMCP = false
    /// 输入框上待发的图片（框选截图投进来的），随下一句话一起发出去。换会话不清——和没发出去的草稿一样留着。
    @Published private(set) var attachments: [AgentImage] = []

    private var connection: AgentConnection?
    /// 上次随消息带过去的上下文。没变就不重复带（省 token，也免得对话里满是同一段）。
    private var lastContextSent: String?

    init(cwd: URL) { self.cwd = cwd }

    var isBusy: Bool { phase == .running || phase == .connecting || phase == .loading }

    // MARK: - 会话

    /// 面板出现时调：还没有会话就建一个（建会话才拿得到模式 / 模型列表）。
    func start() {
        guard sessionId == nil, phase == .idle || isFailed else { return }
        Task { await openNewSession() }
    }

    private var isFailed: Bool { if case .failed = phase { return true } else { return false } }

    /// 新对话：丢掉当前这段（Agent 那边照样留着，历史里还能找回来），重新建一个。
    func newChat() {
        // 眼前这段还一句没说：它就是新的，别再建一个（空会话 Agent 也会记着，多了历史里一堆空条目）
        if sessionId != nil, items.isEmpty, phase == .idle { return }
        if phase == .running, let id = sessionId, let c = connection { Task { await c.cancel(id) } }
        detach()
        items = []
        title = nil
        Task { await openNewSession() }
    }

    private func openNewSession() async {
        phase = .connecting
        do {
            let c = try connectionOrNew()
            let mcp = mcpServers()
            let r = try await c.newSession(mcp: mcp)
            attach(r.sessionId.value, to: c)
            missingMCP = mcp.isEmpty
            applyModes(r.modes)
            applyConfigs(r.configOptions)
            phase = .idle
            agentLog("新会话 \(r.sessionId.value)")
            refreshHistory()
        } catch {
            fail(error)
        }
    }

    /// 回放一段旧对话。Agent 先把整段历史用 `session/update` 推过来，再回响应。
    func load(_ info: SessionInfo) {
        guard info.sessionId.value != sessionId else { return }
        if phase == .running, let id = sessionId, let c = connection { Task { await c.cancel(id) } }
        detach()
        items = []
        title = info.title
        phase = .loading
        Task {
            do {
                let c = try connectionOrNew()
                attach(info.sessionId.value, to: c)   // 先登记：回放的通知会先于响应到
                let mcp = mcpServers()
                let r = try await c.loadSession(info.sessionId.value, mcp: mcp)
                missingMCP = mcp.isEmpty
                applyModes(r.modes)
                applyConfigs(r.configOptions)
                phase = .idle
            } catch {
                fail(error)
            }
        }
    }

    func refreshHistory() {
        Task {
            do {
                let c = try connectionOrNew()
                // 没标题 = 一句没说过的空会话（Kimi 拿第一句话起标题），不列
                history = try await c.listSessions()
                    .filter { !($0.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                    .sorted { ($0.updatedAt ?? "") > ($1.updatedAt ?? "") }
            } catch {
                agentLog("列历史失败：\(error)")
            }
        }
    }

    // MARK: - 发消息

    // MARK: - 图片附件

    /// Agent 收不收图片（握手时声明的 `promptCapabilities.image`）。还没握手 = nil（不知道）。
    var acceptsImages: Bool? {
        guard let r = connection?.initResponse else { return nil }
        return r.agentCapabilities.promptCapabilities?.image ?? false
    }

    func addAttachment(_ image: AgentImage) { attachments.append(image) }

    func removeAttachment(_ id: UUID) { attachments.removeAll { $0.id == id } }

    /// 用户从磁盘选的图片（附件按钮 / 拖到输入框上）：后台解码、压到长边 2000 像素再挂上。
    /// 读不了的文件（不是图片 / 已损坏）跳过并提示一句。
    func attachFiles(_ urls: [URL]) {
        if acceptsImages == false {
            items.append(AgentItem(kind: .notice(
                String(format: L("%@ does not accept images."), AgentConfig.displayName), isError: true)))
            return
        }
        Task {
            let loaded = await Task.detached(priority: .userInitiated) {
                urls.map { url in (url, AgentImageFile.load(url)) }
            }.value
            for (url, img) in loaded {
                if let img { attachments.append(img) }
                else {
                    items.append(AgentItem(kind: .notice(
                        String(format: L("Could not read “%@” as an image."), url.lastPathComponent), isError: true)))
                }
            }
        }
    }

    // MARK: - 发消息

    func send(_ raw: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let id = sessionId, let c = connection, phase == .idle else { return }
        // 握手说不收图：图片留在输入框上，这句话不发，提示一下（发出去 Agent 会整条报错）
        if !attachments.isEmpty, acceptsImages == false {
            items.append(AgentItem(kind: .notice(
                String(format: L("%@ does not accept images. Remove the image to send."), AgentConfig.displayName),
                isError: true)))
            return
        }
        let images = attachments
        attachments = []
        // 🔴 用户的话放**第一块**、上下文块跟在后面：Kimi 拿第一块文字给会话起标题（spike 实测），
        // 上下文在前的话历史列表里每条都叫「<unireader-context>」。图片夹在两者之间
        var blocks: [ContentBlock] = [.text(TextContent(text: text))]
        for img in images {
            blocks.append(.image(ImageContent(data: img.data.base64EncodedString(), mimeType: img.mimeType)))
        }
        // 图片的来源（哪本书哪一页）放进隐藏块：Agent 要用 MCP 去读那一页时用得上，回放时剔掉
        let notes = images.enumerated().compactMap { i, img in img.note.map { "Attached image \(i + 1): \($0)" } }
        if !notes.isEmpty {
            blocks.append(.text(TextContent(text: ([AgentTranscript.contextOpen] + notes + [AgentTranscript.contextClose])
                .joined(separator: "\n"))))
        }
        if let ctx = contextProvider() {
            let t = ctx.promptText
            if t != lastContextSent {
                blocks.append(.text(TextContent(text: t)))
                lastContextSent = t
            }
        }
        items.append(AgentItem(kind: .user(text, images: images)))
        phase = .running
        Task {
            do {
                let r = try await c.prompt(id, blocks)
                guard sessionId == id else { return }   // 中途换了会话：这条结果不属于眼前这段
                switch r.stopReason {
                case .cancelled: items.append(AgentItem(kind: .notice(L("Stopped."), isError: false)))
                case .maxTokens, .maxTurnRequests:
                    items.append(AgentItem(kind: .notice(L("The agent stopped because it hit its length limit."), isError: true)))
                case .refusal: items.append(AgentItem(kind: .notice(L("The agent declined to continue."), isError: true)))
                case .endTurn: break
                }
                phase = .idle
                refreshHistory()   // 标题 / 更新时间变了，历史菜单跟上
            } catch {
                guard sessionId == id else { return }
                items.append(AgentItem(kind: .notice(Self.describe(error), isError: true)))
                phase = connection == nil ? .failed(Self.describe(error)) : .idle
            }
        }
    }

    func cancel() {
        guard phase == .running, let id = sessionId, let c = connection else { return }
        // 还挂着的权限请求一并按取消回，否则 Agent 会一直等
        for p in permissions { p.resume(RequestPermissionResponse(outcome: PermissionOutcome(cancelled: true))) }
        permissions = []
        Task { await c.cancel(id) }
    }

    // MARK: - 模式与配置

    func setMode(_ mode: String) {
        guard let id = sessionId, let c = connection, mode != currentMode else { return }
        let old = currentMode
        currentMode = mode
        Task {
            do { try await c.setMode(id, mode: mode) } catch { currentMode = old; note(error) }
        }
    }

    func setConfig(_ config: String, value: String) {
        guard let id = sessionId, let c = connection else { return }
        Task {
            do { applyConfigs(try await c.setConfig(id, config: config, value: value)) } catch { note(error) }
        }
    }

    func setConfig(_ config: String, flag: Bool) {
        guard let id = sessionId, let c = connection else { return }
        Task {
            do { applyConfigs(try await c.setConfig(id, config: config, flag: flag)) } catch { note(error) }
        }
    }

    // MARK: - 权限

    /// Agent 要执行一个需要批准的工具：挂起，直到用户在面板里点了某个选项。
    func askPermission(_ req: RequestPermissionRequest) async -> RequestPermissionResponse {
        await withCheckedContinuation { cont in
            let tc = req.toolCall
            let ask = AgentPermissionAsk(
                title: AgentTranscript.prettyTitle(tc.title ?? tc.toolCallId),
                detail: Self.describeInput(tc.rawInput),
                options: req.options.map { .init(id: $0.optionId, name: $0.name, kind: $0.kind) },
                resume: { cont.resume(returning: $0) })
            permissions.append(ask)
        }
    }

    func answer(_ ask: AgentPermissionAsk, optionId: String?) {
        guard let i = permissions.firstIndex(where: { $0.id == ask.id }) else { return }
        permissions.remove(at: i)
        ask.resume(RequestPermissionResponse(outcome: optionId.map { PermissionOutcome(optionId: $0) }
                                             ?? PermissionOutcome(cancelled: true)))
    }

    // MARK: - Agent 推来的更新

    func apply(_ update: SessionUpdate) {
        switch update {
        case .currentModeUpdate(let m): currentMode = m
        case .configOptionUpdate(let opts): applyConfigs(opts)
        case .sessionInfoUpdate(let info):
            if let t = info.title {
                let clean = AgentTranscript.stripHidden(t).trimmingCharacters(in: .whitespacesAndNewlines)
                title = clean.isEmpty ? nil : clean
            }
        default: AgentTranscript.apply(update, to: &items)
        }
    }

    func agentDidExit() {
        for p in permissions { p.resume(RequestPermissionResponse(outcome: PermissionOutcome(cancelled: true))) }
        permissions = []
        connection = nil
        sessionId = nil
        lastContextSent = nil
        items.append(AgentItem(kind: .notice(L("The agent process exited. Start a new chat to reconnect."), isError: true)))
        phase = .failed(L("The agent process exited."))
    }

    /// 宿主消失（关窗 / 退出）：挂着的权限请求按取消回，从连接上摘下来；没人用的进程顺手关掉。
    func teardown() {
        if phase == .running, let id = sessionId, let c = connection { Task { await c.cancel(id) } }
        detach()
        connection = nil
        AgentPanelModel.shared.releaseIdleConnections()
    }

    // MARK: - 内部

    private func connectionOrNew() throws -> AgentConnection {
        if let connection, !connection.isDead { return connection }
        let c = AgentPanelModel.shared.connection(for: cwd)
        connection = c
        return c
    }

    private func attach(_ id: String, to c: AgentConnection) {
        sessionId = id
        lastContextSent = nil
        c.register(self, sessionId: id)
    }

    /// 从当前会话上摘下来（换会话 / 新对话 / 结束都走这里）。
    /// 🔴 **这里不关空闲进程**：新对话 / 回放是「摘下旧的 → 马上在同一个进程上建新的」，
    /// 摘下那一刻进程上正好一段对话都没有，在这里关就把马上要用的进程关了——新会话的请求写进
    /// 已关的管道，报「The file couldn't be saved」、接着「Agent 进程已退出」（2026-09-18 用户实测）。
    /// 关空闲进程只在宿主真的消失时做（`teardown`）。
    private func detach() {
        for p in permissions { p.resume(RequestPermissionResponse(outcome: PermissionOutcome(cancelled: true))) }
        permissions = []
        if let id = sessionId { connection?.unregister(sessionId: id) }
        sessionId = nil
        lastContextSent = nil
    }

    /// 我们自己的 MCP 服务：走回环地址，带口令（设了的话）和「内置 Agent」标记头。
    /// 服务没开就不给——Agent 照样能聊，只是看不到阅读器（面板上会提示去开）。
    private func mcpServers() -> [MCPServerConfig] {
        guard let mcp = AppDelegate.shared?.appModel.mcp, mcp.isRunning else { return [] }
        var headers = [HTTPHeader(name: AgentFollow.header, value: "1")]
        if let t = MCPToken.current() { headers.append(HTTPHeader(name: "Authorization", value: "Bearer \(t)")) }
        return [.http(HTTPServerConfig(name: "unireader", url: "http://127.0.0.1:\(mcp.listeningPort)/mcp",
                                       headers: headers))]
    }

    private func applyModes(_ m: ModesInfo?) {
        guard let m else { return }
        modes = m.availableModes
        currentMode = m.currentModeId
    }

    private func applyConfigs(_ opts: [SessionConfigOption]?) {
        guard let opts else { return }
        configs = opts.map { o in
            switch o.kind {
            case .select(let s):
                let all: [SessionConfigSelectOption]
                switch s.options {
                case .ungrouped(let list): all = list
                case .grouped(let groups): all = groups.flatMap(\.options)
                }
                return AgentConfigItem(id: o.id.value, name: o.name,
                                       kind: .select(current: s.currentValue.value,
                                                     options: all.map { ($0.value.value, $0.name) }))
            case .boolean(let b):
                return AgentConfigItem(id: o.id.value, name: o.name, kind: .toggle(b.currentValue))
            }
        }
    }

    private func fail(_ error: Error) {
        agentLog("失败：\(error)")
        phase = .failed(Self.describe(error))
    }

    private func note(_ error: Error) {
        items.append(AgentItem(kind: .notice(Self.describe(error), isError: true)))
    }

    /// 错误说成人话。ACP 规定未登录是 `auth_required`（-32000）：告诉用户去终端登录。
    static func describe(_ error: Error) -> String {
        if let e = error as? ClientError {
            switch e {
            case .agentError(let rpc):
                if rpc.code == -32000 {
                    return String(format: L("Not signed in. Run “%@ login” in Terminal, then start a new chat."), AgentConfig.command)
                }
                return rpc.message
            case .processNotRunning, .connectionClosed:
                return L("The agent process exited.")
            case .requestTimeout:
                return L("The agent did not respond in time.")
            default:
                return e.localizedDescription
            }
        }
        return error.localizedDescription
    }

    /// 历史菜单里一条会话的显示文字：标题 · 更新时间（内置面板的 SwiftUI 菜单与浮窗工具栏的 NSMenu 共用）。
    static func sessionLabel(_ s: SessionInfo) -> String {
        let t = AgentTranscript.stripHidden(s.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let title = t.isEmpty ? L("Untitled Chat") : String(t.prefix(40))
        guard let u = s.updatedAt, let d = ISO8601DateFormatter.agent.date(from: u) else { return title }
        return "\(title) · \(d.formatted(date: .abbreviated, time: .shortened))"
    }

    /// 工具入参给用户看一眼（截断），好判断批不批。
    private static func describeInput(_ raw: AnyCodable?) -> String {
        guard let raw, let data = try? JSONEncoder().encode(raw),
              var s = String(data: data, encoding: .utf8), s != "{}", s != "null" else { return "" }
        if s.count > 400 { s = String(s.prefix(400)) + "…" }
        return s
    }
}

/// 从磁盘读一张图片，转成发给 Agent 的样子（纯 ImageIO，可在任何线程调）。
///
/// 一律按 EXIF 方向摆正、长边压到 `PageSnip.maxLongEdge`（2000 像素）——手机照片原图动辄十几 MB，
/// 按 base64 塞进一条 JSON 消息既慢又没必要，模型那边也会再压。带透明的存 PNG（JPEG 会把透明画成黑底），
/// 其余存 JPEG。HEIC / TIFF 等格式也就此转成 Agent 一定认识的格式。
enum AgentImageFile {
    static func load(_ url: URL) -> AgentImage? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: Int(PageSnip.maxLongEdge),
              ] as CFDictionary)
        else { return nil }
        let alpha: Bool
        switch cg.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: alpha = false
        default: alpha = true
        }
        let type: UTType = alpha ? .png : .jpeg
        let out = NSMutableData()
        guard let dst = CGImageDestinationCreateWithData(out, type.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dst, cg, alpha ? nil : [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(dst) else { return nil }
        let name = url.lastPathComponent
        return AgentImage(data: out as Data, mimeType: type.preferredMIMEType ?? (alpha ? "image/png" : "image/jpeg"),
                          caption: name, note: "an image file the user attached (\"\(name)\").")
    }
}

extension ISO8601DateFormatter {
    /// Agent 给的 `updatedAt` 带毫秒（`2026-09-18T10:07:12.606Z`）。
    static let agent: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}
