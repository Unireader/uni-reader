import ACPModel
import SwiftUI

/// Agent 面板的内容（`ACP-AGENT-PLAN.md`）：对话记录 + 权限请求 + 输入框，内置形态再加一条标题行。
///
/// - **独立窗口**不要标题行（`showsHeader: false`）：操作全在窗口的 `NSToolbar` 上（`AgentWindowController`），
///   与咨询面板的浮窗同一套做法。
/// - **内置形态**是阅读窗口里的浮层，挂不了窗口工具栏：标题行的按钮用系统 `ControlGroup` 分组。
///
/// 🔴 系统标准控件，不自绘仿系统样式；内置形态铺在 material 上，文字一律显式 `.primary`、
/// 按钮不用 `.borderless` / `.plain`（红线：material 底上会被画得几乎看不见）。
struct AgentChatView<Trailing: View>: View {
    @ObservedObject var chat: AgentChat
    let workspaceName: String
    var showsHeader = true
    @ViewBuilder var trailing: () -> Trailing

    @ObservedObject private var panel = AgentPanelModel.shared
    @State private var draft = ""
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            if showsHeader {
                header
                Divider()
            }
            banner
            transcript
            permissionCards
            composer
        }
        .onAppear {
            chat.start()
            inputFocused = true
        }
    }

    // MARK: - 标题行（仅内置形态）

    private var header: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(chat.title ?? AgentConfig.displayName)
                    .font(.headline)
                    .lineLimit(1).truncationMode(.tail)
                Text(workspaceName)
                    .font(.caption)
                    .lineLimit(1).truncationMode(.middle)
            }
            .foregroundStyle(.primary)
            .layoutPriority(1)
            Spacer(minLength: 4)
            ControlGroup {
                AgentHistoryMenu(chat: chat)
                AgentOptionsMenu(chat: chat)
                Button { chat.newChat() } label: {
                    Label(L("New Chat"), systemImage: "square.and.pencil")
                }
                .help(L("New Chat"))
            }
            .fixedSize()
            trailing()
        }
        .labelStyle(.iconOnly)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - 状态条

    @ViewBuilder
    private var banner: some View {
        if chat.missingMCP {
            bannerRow("exclamationmark.triangle", L("The MCP service is off, so the agent cannot see the reader.")) {
                Button(L("Start and Reconnect")) {
                    AppDelegate.shared?.appModel.mcp.start()
                    chat.newChat()
                }
            }
        }
        switch chat.phase {
        case .connecting:
            bannerRow(nil, String(format: L("Starting %@…"), AgentConfig.displayName)) { EmptyView() }
        case .loading:
            bannerRow(nil, L("Loading chat…")) { EmptyView() }
        case .failed(let msg):
            bannerRow("exclamationmark.triangle", msg) {
                Button(L("Retry")) { chat.newChat() }
            }
        default:
            EmptyView()
        }
    }

    private func bannerRow<B: View>(_ icon: String?, _ text: String, @ViewBuilder button: () -> B) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                if let icon { Image(systemName: icon) } else { ProgressView().controlSize(.small) }
                Text(text).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                button().controlSize(.small)
            }
            .font(.callout)
            .foregroundStyle(.primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.bar)
            Divider()
        }
    }

    // MARK: - 对话记录

    @ViewBuilder
    private var transcript: some View {
        if chat.items.isEmpty, chat.phase == .idle, chat.sessionId != nil {
            ContentUnavailableView {
                Label(String(format: L("Ask %@"), AgentConfig.displayName), systemImage: "sparkles")
            } description: {
                Text(L("It can read the document you are looking at, find pages, and add notes, highlights and bookmarks."))
            }
            .foregroundStyle(.primary)
            .frame(maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(chat.items) { item in
                        AgentItemRow(item: item)
                    }
                    if chat.phase == .running, chat.permissions.isEmpty {
                        ProgressView().controlSize(.small).padding(.vertical, 2)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            .defaultScrollAnchor(.bottom, for: .sizeChanges)
            .frame(maxHeight: .infinity)
        }
    }

    // MARK: - 权限请求

    @ViewBuilder
    private var permissionCards: some View {
        if !chat.permissions.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(chat.permissions) { ask in
                    GroupBox {
                        VStack(alignment: .leading, spacing: 8) {
                            if !ask.detail.isEmpty {
                                Text(ask.detail)
                                    .font(.caption.monospaced())
                                    .lineLimit(5)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            HStack(spacing: 6) {
                                Spacer(minLength: 0)
                                ForEach(ask.options.reversed()) { o in
                                    if o.kind == "allow_once" {
                                        // 不挂回车默认键：输入框里打字按回车不该顺手批掉一次权限
                                        Button(o.name) { chat.answer(ask, optionId: o.id) }
                                            .buttonStyle(.borderedProminent)
                                    } else {
                                        Button(o.name) { chat.answer(ask, optionId: o.id) }
                                    }
                                }
                            }
                        }
                        .padding(4)
                    } label: {
                        Label(String(format: L("Allow “%@”?"), ask.title), systemImage: "hand.raised")
                            .font(.callout.weight(.semibold))
                    }
                    .foregroundStyle(.primary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
        }
    }

    // MARK: - 输入

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField(String(format: L("Ask %@…"), AgentConfig.displayName), text: $draft, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...8)
                .focused($inputFocused)
                .onSubmit(send)
                .disabled(chat.sessionId == nil)
            if chat.phase == .running {
                Button(action: chat.cancel) {
                    Label(L("Stop"), systemImage: "stop.fill")
                }
                .keyboardShortcut(".", modifiers: .command)
                .help(L("Stop"))
            } else {
                Button(action: send) {
                    Label(L("Send"), systemImage: "arrow.up")
                }
                .disabled(!canSend)
                .help(L("Send"))
            }
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.circle)
        .padding(.horizontal, 12)
        .padding(.top, 4)
        .padding(.bottom, 12)
    }

    private var canSend: Bool {
        chat.phase == .idle && chat.sessionId != nil
            && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func send() {
        guard canSend else { return }
        chat.send(draft)
        draft = ""
    }
}

// MARK: - 内置形态标题行的两个菜单（独立窗口用 NSToolbar 上的 NSMenu，见 AgentWindowController）

/// 历史对话：列表由 `AgentChat` 在建会话、每轮回复结束时自己刷新（`session/list`，按工作目录过滤）。
struct AgentHistoryMenu: View {
    @ObservedObject var chat: AgentChat

    var body: some View {
        Menu {
            if chat.history.isEmpty {
                Text(L("No earlier chats"))
            }
            ForEach(chat.history.prefix(30), id: \.sessionId.value) { s in
                Toggle(AgentChat.sessionLabel(s), isOn: Binding(
                    get: { s.sessionId.value == chat.sessionId },
                    set: { _ in chat.load(s) }))
            }
        } label: {
            Label(L("Earlier Chats"), systemImage: "clock.arrow.circlepath")
        }
        .help(L("Earlier Chats"))
    }
}

/// 模式 / 模型等配置 / 跟随 Agent / 切换形态。
struct AgentOptionsMenu: View {
    @ObservedObject var chat: AgentChat
    @ObservedObject private var panel = AgentPanelModel.shared

    var body: some View {
        Menu {
            if !chat.modes.isEmpty {
                Picker(L("Mode"), selection: Binding(get: { chat.currentMode ?? "" }, set: { chat.setMode($0) })) {
                    ForEach(chat.modes, id: \.id) { m in Text(m.name).tag(m.id) }
                }
                .pickerStyle(.inline)
            }
            ForEach(chat.configs) { item in
                switch item.kind {
                case .select(let current, let options):
                    Picker(item.name, selection: Binding(get: { current }, set: { chat.setConfig(item.id, value: $0) })) {
                        ForEach(options, id: \.value) { o in Text(o.name).tag(o.value) }
                    }
                    .pickerStyle(.menu)
                case .toggle(let on):
                    Toggle(item.name, isOn: Binding(get: { on }, set: { chat.setConfig(item.id, flag: $0) }))
                }
            }
            Divider()
            Toggle(L("Follow Agent"), isOn: Binding(get: { panel.follow }, set: { panel.setFollow($0) }))
            Divider()
            if panel.mode == .inline {
                Button(L("Open as Separate Window")) { panel.setMode(.window) }
            } else {
                Button(L("Show Inside Reading Window")) { panel.setMode(.inline) }
            }
        } label: {
            Label(L("Agent Options"), systemImage: "slider.horizontal.3")
        }
        .help(L("Agent Options"))
    }
}

/// 一条对话记录。
private struct AgentItemRow: View {
    let item: AgentItem

    var body: some View {
        switch item.kind {
        case .user(let s):
            HStack {
                Spacer(minLength: 48)
                Text(s)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        case .agent(let s):
            Text(Self.markdown(s))
                .textSelection(.enabled)
                .lineSpacing(2)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .thought(let s):
            DisclosureGroup {
                Text(s).font(.callout).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } label: {
                Label(L("Thinking"), systemImage: "brain").font(.callout)
            }
        case .tool(let call):
            toolRow(call)
        case .plan(let entries):
            GroupBox {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(entries.enumerated()), id: \.offset) { _, e in
                        Label(e.text, systemImage: Self.planIcon(e.status))
                            .font(.callout)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } label: {
                Label(L("Plan"), systemImage: "list.bullet").font(.callout.weight(.semibold))
            }
        case .notice(let s, let isError):
            Label(s, systemImage: isError ? "exclamationmark.triangle" : "info.circle")
                .font(.callout)
                .foregroundStyle(isError ? AnyShapeStyle(.red) : AnyShapeStyle(.primary))
        }
    }

    @ViewBuilder
    private func toolRow(_ call: AgentToolCall) -> some View {
        let label = HStack(spacing: 6) {
            toolStatus(call.status)
            Text(call.title).font(.callout.monospaced()).lineLimit(1).truncationMode(.middle)
        }
        if call.output.isEmpty {
            label
        } else {
            DisclosureGroup {
                Text(call.output.count > 4000 ? String(call.output.prefix(4000)) + "…" : call.output)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } label: { label }
        }
    }

    @ViewBuilder
    private func toolStatus(_ s: ToolStatus?) -> some View {
        switch s {
        case .inProgress, .pending, .none: ProgressView().controlSize(.mini)
        case .completed: Image(systemName: "checkmark.circle").foregroundStyle(.green)
        case .failed: Image(systemName: "xmark.circle").foregroundStyle(.red)
        }
    }

    private static func planIcon(_ s: PlanEntryStatus) -> String {
        switch s {
        case .pending: return "circle"
        case .inProgress: return "circle.lefthalf.filled"
        case .completed: return "checkmark.circle"
        case .cancelled: return "xmark.circle"
        }
    }

    /// 行内 Markdown（粗体 / 代码 / 链接），保留换行。块级语法（标题、列表）原样显示（`ACP-AGENT-PLAN.md` A3 待做）。
    static func markdown(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(s)
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
