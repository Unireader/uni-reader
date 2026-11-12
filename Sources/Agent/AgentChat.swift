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

    /// 活动标签是习题（练习页）时：哪一组、第几题、答没答（`EXERCISE-PLAN.md §27`）。只带身份，题目内容 Agent 用
    /// `get_current_view` 读；翻到别的题 / 交了卷就和上次不一样，下一条消息重新带上。
    struct ExerciseTab: Equatable {
        var group: String
        var list: Bool
        var position: Int
        var count: Int
        var exerciseId: String?
        var number: String = ""
        var kind: String = ""
        /// 「12」或跨页的「12–13」（1 起）。
        var pages: String = ""
        var book: String = ""
        var documentId: String?
        var answered = false
        var selected = 0
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
    /// 活动标签是习题时非 nil（与上面两样互斥）。
    var exercise: ExerciseTab? = nil

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
            lines.append("Use the unireader read_markdown tool to read the note's current live text (outline / search / line ranges for long notes). To modify it, use edit_markdown with exact old_text copied from read_markdown; use update_markdown only to rewrite the whole note. Never edit the file directly.")
            lines.append("link \(markdown.link)")
            lines.append(Self.noteKinds + " The current tab is a Markdown note, so \"note\" (笔记) without a kind means a Markdown note, most likely this one.")
        } else if let ex = exercise {
            var s = "Current tab: Exercises (习题), the group \"\(ex.group)\" in the \(ex.list ? "list" : "practice") view"
            if let id = ex.exerciseId {
                s += ", question \(ex.position) of \(ex.count): exercise_id \(id), a \(ex.kind) question"
                if !ex.number.isEmpty { s += " numbered \(ex.number)" }
                if !ex.pages.isEmpty { s += " on page \(ex.pages)" }
                if let d = ex.documentId { s += " of \"\(ex.book)\" (document_id \(d))" }
                s += ex.answered ? "; an answer is showing for it" : "; the user has not answered it yet"
            } else {
                s += ", no question to show"
            }
            if ex.list, ex.selected > 0 { s += "; \(ex.selected) selected in the list" }
            if let tabId { s += ", reader tab session_id \(tabId.uuidString)" }
            if let windowId { s += ", window_id \(windowId.uuidString)" }
            lines.append(s + ".")
            lines.append("\"This question\" (这道题 / 这题) means that one. get_current_view gives it in full with the answer showing and its attempt_id (to grade it with grade_exercise_attempts); render_exercise shows it as printed (figures); open_exercises moves the user to another question or group.")
            lines.append(Self.noteKinds + " If the user says \"note\" (笔记) about this question, they probably mean its own note (update_exercises note); otherwise ask which one.")
        } else if let documentId {
            var s = "Current document: \"\(docTitle)\" (document_id \(documentId)), page \(page + 1) of \(pageCount)"
            if let tabId { s += ", reader tab session_id \(tabId.uuidString)" }
            if let windowId { s += ", window_id \(windowId.uuidString)" }
            lines.append(s + ".")
            lines.append(Self.noteKinds + " The current tab is a PDF, so \"note\" (笔记) without a kind means a text note on this document.")
        } else {
            lines.append("No document is open in the reader right now.")
            lines.append(Self.noteKinds + " If the user says \"note\" (笔记) without a kind, ask which one.")
        }
        lines.append(MCPTools.mathWriting)   // 同 `noteKinds`：MCP 说明里有，但不是每个 Agent 都读
        lines.append(MCPTools.graphWriting)
        lines.append(Self.exercises)
        lines.append(Self.contexts)
        lines.append(AgentTranscript.contextClose)
        return lines.joined(separator: "\n")
    }

    /// 两种笔记的区别（2026-10-05 用户：Agent 要分清文字笔记和 Markdown 笔记）。只说「笔记」时按当前标签页猜（用户定），
    /// 上面按标签页各接一句。MCP 的 `instructions` 里也写了一遍，但不是每个 Agent 都读它，这里再带上。
    /// 习题（`EXERCISE-PLAN.md §3.2`）：用户说「识别习题 / 把这几页的题导进来」时 Agent 该用哪几个工具。理由同上。
    private static let exercises = "Exercises (习题) are questions saved for the user to practice (练习 / 错题本 / 收藏): single / multiple choice, fill in the blank (type fill, one entry in blanks per blank) and subjective questions (type subjective — calculation, proof, short answer; answer = the reference answer). When the user says 习题册, 练习册 or 练习库 they mean these Exercises in UniReader (the 习题 part of the sidebar), not a file or a PDF. To recognize the exercises on some pages: look at each page with render_page (and read_pages for the text), transcribe every question exactly without rewording, and save them with import_exercises (page, number, stem, options or blanks, plus answer + answer_source only when the answer is printed or you are sure). The first time you import into a book (list_exercises shows no questions in it yet), ask the user how to group its questions into chapters: by the PDF's table of contents (chapters \"toc\"), their own way (printed headings, question groups, any number of levels: give each question its chapter path, top level first, and pass chapters \"none\"), or not at all (chapters \"none\"). Later imports follow the book's grouping: for table-of-contents or ungrouped books leave chapters out (a book whose chapters the user removed stays flat); for a book grouped the user's own way keep giving every question its chapter, reusing the existing level names. Regroup existing questions with update_exercises chapter when the user asks. If the user already answered on the page — usually by highlighting an option (list_annotations, kinds highlight) or by circling / writing (render_page with include_marks) — pass it as user_answer (user_blanks for fill). Fill in answers later from an answer key with list_exercises + update_exercises. To grade the user's fill-in or subjective answers: list_exercise_attempts (ungraded_only, or the exercise_ids you were given), render_exercise_answer for handwriting, compare with the reference answer, then grade_exercise_attempts with correct + short feedback in the user's language. Each exercise can also carry the user's own note (题目笔记, note in list_exercises — not a text note on the PDF); change it with update_exercises note only when the user asks. When the user asks to star (收藏 / 加星) or unstar questions, find them with list_exercises (filter starred lists the starred ones) and pass update_exercises starred true / false. Questions can carry free-form tags (tags in list_exercises, e.g. 真题 or 模拟): import_exercises tags adds tags (only when the user asks or the page itself says so, such as a section headed 历年真题), update_exercises tags replaces the whole set (send the existing tags plus the new one to add), and list_exercises tag lists one tag's questions. To see a question as printed (figures, tables, parts on the next page) use render_exercise. To take the user to questions — one question, a book, a chapter, the mistakes or starred ones, a tag, only the ones not done or a redo round of the ones wrong last time — use open_exercises; to give a clickable link instead, use exercise_link from list_exercises."

    /// Agent 上下文（`ACP-AGENT-PLAN.md §12`）：用户说「接着上次存的那个」时 Agent 该去哪找。理由同上。
    private static let contexts = "Agent contexts (Agent 上下文) are handoff summaries of earlier conversations, possibly with other agents, saved in this workspace. When the user asks to continue earlier work or mentions a saved context, find it with list_agent_contexts and read it with read_agent_context. The user saves one from the panel's Contexts menu; call save_agent_context only when the user asks you to."

    private static let noteKinds = "UniReader has two kinds of notes: a text note (批注 / 文字笔记) is pinned to a spot on a PDF page — the user makes one with right-click › Add Note Here, or by selecting text and adding a note (tools: add_note, list_annotations, delete_annotations); a Markdown note (Markdown 笔记) is a separate .md file opened in its own tab (tools: list_markdown_notes, read_markdown, edit_markdown)."
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

/// 输入框上挂着的一份已存上下文（随下一句话带过去）。`id` 是挂上去这一次的，同一份挂两次也分得开。
struct AgentHandoff: Identifiable {
    let id = UUID()
    let context: LibAgentContext
}

/// 回答中按回车排上队的一句话（连同当时挂在输入框上的图片、`@` 的文件），这一轮答完依次发出去。
struct AgentQueuedMessage: Identifiable {
    let id = UUID()
    var text: String
    var mentions: [AgentMention]
    var images: [AgentImage]
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

/// 一段 Agent 对话（一个宿主 × 一个工作目录一份）。对话本身**不落库**：历史由 Agent 自己按工作目录保存，
/// 面板要看旧对话时用 `session/list` 列、`session/load` 回放（用户 2026-09-18：「我们不保存具体数据」）。
/// 例外是用户点「保存上下文」时 Agent 写的那份交接摘要（2026-11-02 用户要的「换 Agent 接着聊」，`ACP-AGENT-PLAN.md §12`）：
/// 存进工作区库，在任何 Agent 的对话里都能带上。
@MainActor
final class AgentChat: ObservableObject {
    enum Phase: Equatable {
        case idle, connecting, loading, running
        case failed(String)
    }

    let cwd: URL
    /// 现取「用户在看什么」。宿主决定来源：内置面板 = 它所在的阅读窗口；浮窗 = 最近的 key 阅读窗口。
    var contextProvider: () -> AgentReaderContext? = { nil }
    /// 输入框 `@` 的候选（这扇窗口工作区里的 PDF + Markdown 笔记，最近打开的在前）。弹出候选时取一次。
    var mentionProvider: () -> [AgentMention] = { [] }

    @Published private(set) var items: [AgentItem] = []
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var sessionId: String?
    @Published private(set) var title: String?
    @Published private(set) var modes: [ModeInfo] = []
    @Published private(set) var currentMode: String?
    @Published private(set) var configs: [AgentConfigItem] = []
    /// 上下文占用（Agent 推 `usage_update` 才有；不推的一直是 nil，面板上那块就不显示）。
    @Published private(set) var usage: AgentContextUsage?
    /// Agent 报上来的斜杠命令（`available_commands_update`；不推的 Agent 一直是空的）。
    @Published private(set) var commands: [AgentCommand] = []
    @Published private(set) var permissions: [AgentPermissionAsk] = []
    @Published private(set) var history: [SessionInfo] = []
    /// 这段会话建立时 MCP 服务没开 → Agent 手上没有 unireader 工具。面板据此提示。
    @Published private(set) var missingMCP = false
    /// 输入框上待发的图片（框选截图投进来的），随下一句话一起发出去。换会话不清——和没发出去的草稿一样留着。
    @Published private(set) var attachments: [AgentImage] = []
    /// 等输入框取走的一句话（`requestDraft`，习题「让 Agent 批改」放进来的）。输入框视图在刷新时取走、清掉。
    @Published var draftRequest: String?
    /// 随 `draftRequest` 一起交还输入框的 `@` 文件（排队的话退回输入框时带着，发送时照样附上）。
    var draftMentions: [AgentMention] = []
    /// 回答中排上队的话（用户 2026-10-27：「要有消息队列，不能必需打断才能发消息」）。这一轮正常答完就发下一条，
    /// 一轮一条、按先后；用户按了停止 / 出错 / 换会话就不发，全部退回输入框（连同图片），一句也不丢。
    @Published private(set) var queued: [AgentQueuedMessage] = []
    /// 下一次发送时放进隐藏上下文块的说明（英文，给 Agent 看：题目 / 作答的 id 等）。发出去就清。
    private(set) var contextNotes: [String] = []
    /// 挂在输入框上的已存上下文（「上下文」菜单里点的），随下一句话放进隐藏块带过去（`ACP-AGENT-PLAN.md §12`）。
    /// 同 `contextNotes`：真正发出那一刻才取走；斜杠命令不带，留着跟下一句话走。
    @Published private(set) var handoffs: [AgentHandoff] = []
    /// 这段对话属于哪个工作区（存上下文要写它的库）。宿主设。
    var workspaceProvider: () -> WorkspaceManager? = { nil }
    /// 正在等 Agent 写交接摘要的那一轮：哪段会话、那句请求在 `items` 里的位置（它后面的回复就是摘要）。
    private var pendingSave: (session: String, from: Int)?

    private var connection: AgentConnection?
    /// 上次随消息带过去的上下文。没变就不重复带（省 token，也免得对话里满是同一段）。
    private var lastContextSent: String?
    /// 上一轮回答什么时候结束的（收到 `session/prompt` 的应答）。认「轮次外推来的回复」用，见 `apply`。
    private var turnEndedAt: Date?

    /// 同一扇窗口里并行的几段对话靠它区分（`AgentPanelModel`）。
    let id = UUID()
    /// 这段对话钉死用哪个 Agent（并行对话新建时选的）。nil = 跟设置走（原来的行为：点「新对话」才换到设置里新选的）。
    let pinnedLaunch: AgentConfig.Launch?

    init(cwd: URL, launch: AgentConfig.Launch? = nil) {
        self.cwd = cwd
        pinnedLaunch = launch
    }

    var isBusy: Bool { phase == .running || phase == .connecting || phase == .loading }

    /// 在跟谁说话：连着的进程按什么起的就是什么；还没连上 = 设置里现在选的。
    private var launch: AgentConfig.Launch { connection?.launch ?? pinnedLaunch ?? AgentConfig.current }
    var agentName: String { launch.displayName }

    // MARK: - 会话

    /// 面板出现时调：还没有会话就建一个（建会话才拿得到模式 / 模型列表）。
    func start() {
        guard sessionId == nil, phase == .idle || isFailed else { return }
        Task { await openNewSession() }
    }

    private var isFailed: Bool { if case .failed = phase { return true } else { return false } }

    /// 新对话：丢掉当前这段（Agent 那边照样留着，历史里还能找回来），重新建一个。
    /// 设置里换了 Agent（连着的进程不是按现在的设置起的）：新对话换到新 Agent 上——**只有这里换**，
    /// 正在聊的那段不打断（用户 2026-10-13 定）。
    func newChat() {
        let switching = pinnedLaunch == nil && (connection.map { $0.launch != AgentConfig.current } ?? false)
        // 眼前这段还一句没说：它就是新的，别再建一个（空会话 Agent 也会记着，多了历史里一堆空条目）
        if sessionId != nil, items.isEmpty, phase == .idle, !switching { return }
        if phase == .running, let id = sessionId, let c = connection { Task { await c.cancel(id) } }
        detach()
        items = []
        title = nil
        if switching {
            // 模式 / 模型 / 历史都是旧 Agent 的，连新的这几秒里别还挂着
            connection = nil
            modes = []
            currentMode = nil
            configs = []
            history = []
        }
        Task {
            await openNewSession()
            // 旧进程上没有对话了就关掉（`detach` 刻意不关，见那里；这时新会话已经建在新进程上）
            if switching { AgentPanelModel.shared.releaseIdleConnections() }
        }
    }

    private func openNewSession() async {
        phase = .connecting
        do {
            let c = try connectionOrNew()
            let mcp = mcpServers()
            let r = try await c.newSession(mcp: mcp)
            attach(r.sessionId.value, to: c)
            missingMCP = mcp.isEmpty
            // 新会话以它报上来的为准：没给模式 / 配置就不显示（进程死后重连到别家 Agent 时不留旧的那套）
            if r.modes == nil { modes = []; currentMode = nil }
            if r.configOptions == nil { configs = [] }
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
                let t0 = Date()
                let r = try await c.loadSession(info.sessionId.value, mcp: mcp)
                // Agent 推完整段历史用了多久（面板建视图的耗时另记，见 `AgentChatNSView.refreshTranscript`）
                agentLog(String(format: "回放完成 %d 条，%.1fs", items.count, Date().timeIntervalSince(t0)))
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

    /// 握手说不收图：提示一句（附件按钮 / 拖进来 / 粘贴共用）。
    private func refuseImages() -> Bool {
        guard acceptsImages == false else { return false }
        items.append(AgentItem(kind: .notice(String(format: L("%@ does not accept images."), agentName), isError: true)))
        return true
    }

    func addContextNote(_ note: String) { if !contextNotes.contains(note) { contextNotes.append(note) } }

    /// 往输入框里放一句话（视图取走；已有字就接在后面）。
    func requestDraft(_ text: String) { draftRequest = draftRequest.map { $0 + "\n\n" + text } ?? text }

    /// 等输入框插到光标处的 `@` 引用（侧栏「在 Agent 中引用」，`ACP-AGENT-PLAN.md §11`）。输入框视图刷新时取走、清掉。
    @Published var mentionRequest: [AgentMention] = []
    func requestMentions(_ ms: [AgentMention]) { mentionRequest += ms }

    func removeAttachment(_ id: UUID) { attachments.removeAll { $0.id == id } }

    /// 用户从磁盘选的图片（附件按钮 / 拖到输入框上）：后台解码、压到长边 2000 像素再挂上。
    /// 读不了的文件（不是图片 / 已损坏）跳过并提示一句。
    func attachFiles(_ urls: [URL]) {
        if refuseImages() { return }
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

    /// ⌘V 粘贴的位图（截图 / 从别的 App 复制的图）：同样后台摆正、压长边再挂上。
    func attachPasted(_ data: Data) {
        if refuseImages() { return }
        Task {
            let img = await Task.detached(priority: .userInitiated) { AgentImageFile.bitmap(data) }.value
            if let img { attachments.append(img) }
            else { items.append(AgentItem(kind: .notice(L("Could not read the pasted image."), isError: true))) }
        }
    }

    // MARK: - 发消息

    /// `mentions`：输入框里 `@` 选中的文件，各附一个 `resource_link`（只有名字和位置，不带内容）。
    /// 回答中调 = 排队（连同此刻挂在输入框上的图片），这一轮答完自动发（`queued`）。
    func send(_ raw: String, mentions: [AgentMention] = []) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, sessionId != nil, connection != nil, phase == .idle || phase == .running else { return }
        // 斜杠命令不带图片（见 `dispatch`）：图片留在输入框上
        let command = AgentSlash.parse(text) != nil
        // 握手说不收图：图片留在输入框上，这句话不发，提示一下（发出去 Agent 会整条报错）
        if !command, !attachments.isEmpty, acceptsImages == false {
            items.append(AgentItem(kind: .notice(
                String(format: L("%@ does not accept images. Remove the image to send."), agentName),
                isError: true)))
            return
        }
        let message = AgentQueuedMessage(text: text, mentions: command ? [] : mentions, images: command ? [] : attachments)
        if !command { attachments = [] }
        if phase == .running {
            queued.append(message)
            return
        }
        dispatch(message)
    }

    /// 排着的那条不要了（输入区「移除」）。
    func removeQueued(_ id: UUID) { queued.removeAll { $0.id == id } }

    /// 排着的那条退回输入框改（输入区「编辑」）：话接在输入框里已有的后面，图片挂回输入框。
    func editQueued(_ id: UUID) {
        guard let i = queued.firstIndex(where: { $0.id == id }) else { return }
        restore([queued.remove(at: i)])
    }

    /// 排着的全部退回输入框（停止 / 出错 / 换会话 / 进程退出）。
    private func restoreQueue() {
        guard !queued.isEmpty else { return }
        let all = queued
        queued = []
        restore(all)
    }

    private func restore(_ messages: [AgentQueuedMessage]) {
        requestDraft(messages.map(\.text).joined(separator: "\n\n"))
        draftMentions += messages.flatMap(\.mentions)
        attachments = messages.flatMap(\.images) + attachments
    }

    /// 这一轮正常答完：发排着的下一条。
    private func sendNextQueued() {
        guard phase == .idle, !queued.isEmpty, sessionId != nil, connection != nil else { return }
        dispatch(queued.removeFirst())
    }

    /// 真正发出去（空闲时）。
    private func dispatch(_ message: AgentQueuedMessage) {
        guard let id = sessionId, let c = connection, phase == .idle else { return }
        let text = message.text
        // 🔴 斜杠命令（`/compact` 之类）**只发这一块文字**：三家 Agent 都只拿第一块文字认命令，其余的块
        // 要么被扔掉（Kimi 执行内置命令只看命令名和参数——上下文块跟着丢了，`lastContextSent` 却记成已发，
        // 下一句话就不再带上下文），要么跟着进了命令（Claude Code 把每块文字都交给 SDK）。
        // 所以上下文块 / 图片 / `@` 文件都不带：图片和待发说明留着跟下一句话走，`lastContextSent` 不动。
        if let cmd = AgentSlash.parse(text) {
            // 压缩之后占用会大降，旧数字收起来，等 Agent 报新的（见 `AgentContextUsage`）
            if AgentSlash.compactNames.contains(cmd.name) { usage = nil }
            items.append(AgentItem(kind: .user(text, images: [])))
            run([.text(TextContent(text: text))], session: id, on: c)
            return
        }
        let mentions = message.mentions
        let images = message.images
        // 🔴 用户的话放**第一块**、上下文块跟在后面：Kimi 拿第一块文字给会话起标题（spike 实测），
        // 上下文在前的话历史列表里每条都叫「<unireader-context>」。图片夹在两者之间
        var blocks: [ContentBlock] = [.text(TextContent(text: text))]
        for m in mentions {
            blocks.append(.resourceLink(ResourceLinkContent(
                uri: m.uri, name: m.name, title: m.detail.isEmpty ? nil : m.detail,
                description: m.agentDescription, mimeType: m.mimeType)))
        }
        for img in images {
            blocks.append(.image(ImageContent(data: img.data.base64EncodedString(), mimeType: img.mimeType)))
        }
        // 图片的来源（哪本书哪一页）放进隐藏块：Agent 要用 MCP 去读那一页时用得上，回放时剔掉
        let carried = handoffs
        handoffs = []
        let notes = images.enumerated().compactMap { i, img in img.note.map { "Attached image \(i + 1): \($0)" } }
            + contextNotes
            + carried.map { h in
                AgentContextText.handoff(title: h.context.title, summary: h.context.summary, agent: h.context.agent,
                                         id: h.context.id, date: h.context.updatedAt)
            }
        contextNotes = []
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
        for h in carried {
            items.append(AgentItem(kind: .notice(String(format: L("Carried over the context “%@”."), h.context.title),
                                                 isError: false)))
        }
        run(blocks, session: id, on: c)
    }

    // MARK: - 上下文（`ACP-AGENT-PLAN.md §12`）

    /// 这段对话里说过话、眼下空闲、没在等上一份摘要：才能「保存上下文」。
    var canSaveContext: Bool {
        phase == .idle && sessionId != nil && connection != nil && pendingSave == nil && workspaceProvider() != nil
            && items.contains { if case .user = $0.kind { return true } else { return false } }
    }

    /// 保存上下文：请这个 Agent 把这段对话写成交接摘要（说明放隐藏块，对话里只看到一句请求），
    /// 这一轮正常答完就把回复存进工作区库（`finishSave`）。
    func saveContext() {
        guard canSaveContext, let id = sessionId, let c = connection else { return }
        let text = L("Please write a handoff summary of this chat so I can continue it with another agent.")
        pendingSave = (id, items.count)
        items.append(AgentItem(kind: .user(text, images: [])))
        let note = [AgentTranscript.contextOpen, AgentContextText.saveInstruction, AgentTranscript.contextClose]
            .joined(separator: "\n")
        run([.text(TextContent(text: text)), .text(TextContent(text: note))], session: id, on: c)
    }

    /// 那一轮答完：把请求之后 Agent 的回复（思考过程不算）拼起来，切出标题与正文存下。
    private func finishSave(session: String, from: Int) {
        guard from < items.count else { return }
        let reply = items[(from + 1)...].compactMap { item -> String? in
            if case .agent(let s) = item.kind { return s } else { return nil }
        }.joined(separator: "\n\n")
        let parsed = AgentContextText.parse(reply)
        guard !parsed.summary.isEmpty, let ws = workspaceProvider() else {
            items.append(AgentItem(kind: .notice(L("The agent wrote no summary, so no context was saved."), isError: true)))
            return
        }
        guard let saved = ws.addAgentContext(title: parsed.title, summary: parsed.summary, agent: agentName,
                                             sessionId: session) else {
            items.append(AgentItem(kind: .notice(L("Could not save the context."), isError: true)))
            return
        }
        items.append(AgentItem(kind: .notice(String(format: L("Saved as the context “%@”. In a new chat with any agent, attach it from the Contexts menu to carry on."), saved.title), isError: false)))
    }

    /// 把一份已存上下文挂到输入框上，随下一句话带过去（同一份已经挂着就不重复挂）。
    func attachContext(_ c: LibAgentContext) {
        guard !handoffs.contains(where: { $0.context.id == c.id }) else { return }
        handoffs.append(AgentHandoff(context: c))
    }

    func removeHandoff(_ id: UUID) { handoffs.removeAll { $0.id == id } }

    /// 压缩上下文（占用菜单里那一项）：发 Agent 自己报的那条命令，和用户在输入框里打 `/compact` 一样。
    func compact() {
        guard let name = compactCommand else { return }
        send("/" + name)
    }

    /// 这个 Agent 压缩上下文用哪条命令；它没报命令列表就是 nil（面板不给那一项）。
    var compactCommand: String? { AgentSlash.compactCommand(in: commands) }

    /// 发出去，等这一轮回答结束。
    private func run(_ blocks: [ContentBlock], session id: String, on c: AgentConnection) {
        phase = .running
        Task {
            do {
                let r = try await c.prompt(id, blocks)
                guard sessionId == id else { return }   // 中途换了会话：这条结果不属于眼前这段
                turnEndedAt = Date()
                if let p = pendingSave, p.session == id {
                    pendingSave = nil
                    if r.stopReason == .endTurn { finishSave(session: id, from: p.from) }
                    else { items.append(AgentItem(kind: .notice(L("No context was saved."), isError: false))) }
                }
                switch r.stopReason {
                case .cancelled:
                    items.append(AgentItem(kind: .notice(L("Stopped."), isError: false)))
                    restoreQueue()   // 用户按了停止：排着的不自动发，退回输入框
                case .maxTokens, .maxTurnRequests:
                    items.append(AgentItem(kind: .notice(L("The agent stopped because it hit its length limit."), isError: true)))
                case .refusal: items.append(AgentItem(kind: .notice(L("The agent declined to continue."), isError: true)))
                case .endTurn: break
                }
                phase = .idle
                refreshHistory()   // 标题 / 更新时间变了，历史菜单跟上
                sendNextQueued()   // 排着的下一条（停止时上面已经退回输入框，这里是空的）
            } catch {
                guard sessionId == id else { return }
                items.append(AgentItem(kind: .notice(describe(error), isError: true)))
                if pendingSave?.session == id { pendingSave = nil }
                phase = connection == nil ? .failed(describe(error)) : .idle
                restoreQueue()     // 出错了别接着往下发：退回输入框，用户自己决定
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
        case .usageUpdate(let u): usage = AgentContextUsage(used: u.used, size: u.size)
        case .availableCommandsUpdate(let list):
            commands = list.map { AgentCommand(name: $0.name, description: $0.description, hint: $0.input?.hint) }
        case .agentMessageChunk(let b) where phase == .idle && (turnEndedAt.map { Date().timeIntervalSince($0) > 0.5 } ?? false):
            // 这一轮早结束了还推来回复文字 = 轮次外的消息（Kimi 后台压缩上下文做完的回报，几秒后才来）：
            // 单起一条，别接在上一条回复后面，否则两段话首尾相连。刚结束那半秒不算：通知和应答走两条路到主线程，
            // 这一轮最后几片正文可能比应答晚到一点。单起之后清掉，同一条消息后面的碎片照常接上。
            turnEndedAt = nil
            guard let t = AgentTranscript.text(of: b)?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return }
            items.append(AgentItem(kind: .agent(t)))
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
        pendingSave = nil
        restoreQueue()
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
        let c = AgentPanelModel.shared.connection(for: cwd, launch: pinnedLaunch)
        connection = c
        return c
    }

    private func attach(_ id: String, to c: AgentConnection) {
        sessionId = id
        lastContextSent = nil
        turnEndedAt = nil
        usage = nil        // 占用是上一段会话的数字，换会话（新建 / 回放）都从零等 Agent 重新报
        commands = []      // 同上；Agent 建会话 / 回放后会再推一遍（登记前先到的那条由连接补交，见 `register`）
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
        pendingSave = nil   // 等着的那一轮属于这段：换会话就不存了
        restoreQueue()   // 排着的属于眼前这段：换会话不往新的那段里发，退回输入框（同没发出去的草稿）
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
        phase = .failed(describe(error))
    }

    private func note(_ error: Error) {
        items.append(AgentItem(kind: .notice(describe(error), isError: true)))
    }

    /// 错误说成人话。ACP 规定未登录是 `auth_required`（-32000）：告诉用户去终端登录（登录哪个看这段对话连的是谁）。
    private func describe(_ error: Error) -> String {
        if let e = error as? ClientError {
            switch e {
            case .agentError(let rpc):
                if rpc.code == -32000 {
                    return String(format: L("Not signed in. Run “%@ login” in Terminal, then start a new chat."), launch.command)
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
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return image(src, name: url.lastPathComponent,
                     note: "an image file the user attached (\"\(url.lastPathComponent)\").")
    }

    /// 剪贴板里的位图（⌘V 贴的截图 / 从预览复制的图）：走同一条摆正 + 压长边的路子转成 JPEG / PNG，
    /// 截图原生的 TIFF 是未压缩的，直接 base64 塞进消息能有几十 MB。
    static func bitmap(_ data: Data) -> AgentImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let name = L("Pasted Image")
        return image(src, name: name, note: "an image the user pasted from the clipboard.")
    }

    private static func image(_ src: CGImageSource, name: String, note: String) -> AgentImage? {
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [
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
        return AgentImage(data: out as Data, mimeType: type.preferredMIMEType ?? (alpha ? "image/png" : "image/jpeg"),
                          caption: name, note: note)
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
