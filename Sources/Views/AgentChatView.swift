import ACPModel
import SwiftUI
import UniformTypeIdentifiers

/// Agent 面板的内容（`ACP-AGENT-PLAN.md`）：对话记录 + 权限请求 + 输入框，内置形态再加一条标题行。
///
/// - **独立窗口**不要标题行（`showsHeader: false`）：操作全在窗口的 `NSToolbar` 上（`AgentWindowController`），
///   与咨询面板的浮窗同一套做法。
/// - **内置形态**是阅读窗口里的浮层，挂不了窗口工具栏：标题行的按钮用系统 `ControlGroup` 分组。
///
/// 🔴 系统标准控件，不自绘仿系统样式；内置形态铺在 material 上，文字一律显式 `.primary`、
/// 按钮不用 `.borderless` / `.plain`（红线：material 底上会被画得几乎看不见）。
struct AgentChatView: View {
    @ObservedObject var chat: AgentChat
    let workspaceName: String
    var showsHeader = true

    @ObservedObject private var panel = AgentPanelModel.shared
    @State private var draft = ""
    @State private var pickingImages = false
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

    /// 与咨询 AI 内置面板共用 `InlinePanelHeader`（用户 2026-09-19：两边高度、图标样式统一）。
    private var header: some View {
        InlinePanelHeader(icon: "sparkles", title: chat.title ?? AgentConfig.displayName,
                          subtitle: workspaceName) {
            AgentHistoryMenu(chat: chat)
            AgentOptionsMenu(chat: chat)
            Button { chat.newChat() } label: {
                Label(L("New Chat"), systemImage: "square.and.pencil")
            }
            .help(L("New Chat"))
        }
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

    /// 输入区（用户 2026-09-18 参考其他 Agent 客户端定的布局）：一个圆角框，上面是多行输入，
    /// 下面一行左边「模式」（审批方式）、右边「模型」+ 发送。模式 / 模型从顶部挪到这里——它们是
    /// 「这一句话怎么发」的设置，挨着输入框；顶部只留面板本身的设置（跟随 / 吸附 / 形态）。
    /// 待发的图片（阅读区 ⌥ 拖截图 / 附件按钮 / 拖进来的图片文件）排在输入框上面一行，每张右上角可以去掉。
    /// 左下角是附件按钮，其后是「模式」。
    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !chat.attachments.isEmpty { attachmentStrip }
            input
            HStack(spacing: 6) {
                attachButton
                AgentModeMenu(chat: chat)
                Spacer(minLength: 4)
                AgentConfigMenu(chat: chat)
                sendButton
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .background(.background, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.separator)
        }
        // 点框里空白处也进输入态（整块看起来就是一个输入框）
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onTapGesture { inputFocused = true }
        // 图片文件直接拖到输入框上 = 附上（和附件按钮同一条路）
        .dropDestination(for: URL.self) { urls, _ in
            let images = urls.filter { UTType(filenameExtension: $0.pathExtension)?.conforms(to: .image) == true }
            guard !images.isEmpty else { return false }
            chat.attachFiles(images)
            return true
        }
        .padding(.horizontal, 12)
        .padding(.top, 4)
        .padding(.bottom, 12)
    }

    /// 从磁盘选图片附上（用户 2026-09-19：不只是 PDF 里的截图）。系统打开面板，可多选。
    private var attachButton: some View {
        Button { pickingImages = true } label: {
            Label(L("Attach Images…"), systemImage: "photo.badge.plus")
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .foregroundStyle(.primary)
        .disabled(chat.sessionId == nil)
        .help(L("Attach Images…"))
        .fileImporter(isPresented: $pickingImages, allowedContentTypes: [.image],
                      allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { chat.attachFiles(urls) }
        }
    }

    private var attachmentStrip: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(chat.attachments) { img in
                    AgentImageThumb(image: img, height: 56)
                        .overlay(alignment: .topTrailing) {
                            Button { chat.removeAttachment(img.id) } label: {
                                Label(L("Remove"), systemImage: "xmark")
                            }
                            .labelStyle(.iconOnly)
                            .buttonBorderShape(.circle)
                            .controlSize(.mini)
                            .offset(x: 6, y: -6)
                            .help(L("Remove"))
                        }
                }
            }
            .padding(.top, 6)
            .padding(.trailing, 6)
        }
        .scrollIndicators(.never)
    }

    /// 多行输入（用户 2026-09-18：「输入框默认高一些，支持换行，多行输入」）。
    ///
    /// 用系统多行编辑框 `TextEditor`（`TextField` 竖向模式回车就提交，换行不顺手）：
    /// **回车发送，⇧回车 / ⌥回车换行**（交给 NSTextView 自己插换行）。默认约三行高，随内容长高，
    /// 到上限后框内滚动——高度由底下一份隐藏的同字体 `Text` 撑出来。
    /// 🔴 输入法组字时的回车是「上屏」不是发送：有 marked text 就放行给输入法（中文用户，必须）。
    private var input: some View {
        ZStack(alignment: .topLeading) {
            Text(draft.isEmpty ? " " : draft + " ")   // 撑高度；末尾补空格，最后一行是空行时也算上
                .font(.body)
                .padding(.horizontal, 5)                 // 与 NSTextView 的 lineFragmentPadding 对齐
                .frame(maxWidth: .infinity, alignment: .leading)
                .hidden()
            TextEditor(text: $draft)
                .font(.body)
                .scrollContentBackground(.hidden)
                .focused($inputFocused)
                .disabled(chat.sessionId == nil)
                .onKeyPress(.return, phases: .down) { press in
                    if let tv = NSApp.keyWindow?.firstResponder as? NSTextView, tv.hasMarkedText() { return .ignored }
                    guard press.modifiers.isDisjoint(with: [.shift, .option]) else { return .ignored }
                    send()
                    return .handled
                }
            if draft.isEmpty {
                Text(chat.attachments.isEmpty ? String(format: L("Ask %@…"), AgentConfig.displayName)
                                              : L("Ask about the image…"))
                    .font(.body)
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 5)
                    .allowsHitTesting(false)
            }
        }
        .frame(minHeight: 56, maxHeight: 200)
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var sendButton: some View {
        Group {
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

/// 面板本身的设置：跟随 Agent / 切换形态（模式与模型在输入框那一行，见 `AgentModeMenu` / `AgentConfigMenu`）。
struct AgentOptionsMenu: View {
    @ObservedObject var chat: AgentChat
    @ObservedObject private var panel = AgentPanelModel.shared

    var body: some View {
        Menu {
            Toggle(L("Follow Agent"), isOn: Binding(get: { panel.follow }, set: { panel.setFollow($0) }))
            Divider()
            if panel.mode == .inline {
                Button(L("Open as Separate Window")) { panel.setMode(.window) }
            } else {
                Button(L("Show Inside Reading Window")) { panel.setMode(.inline) }
            }
        } label: {
            // 与咨询 AI 的「更多」同图标同名：两边这个菜单装的都是面板本身的设置（吸附 / 形态……）
            Label(L("More"), systemImage: "ellipsis")
        }
        .help(L("More"))
    }
}

// MARK: - 输入框那一行的两个菜单

/// 模式（审批方式）。Kimi 的三档按 id 给本地化的名字和说明；认不出的 id 用 Agent 自己给的名字。
struct AgentModeMenu: View {
    @ObservedObject var chat: AgentChat

    var body: some View {
        if !chat.modes.isEmpty {
            Menu {
                ForEach(chat.modes, id: \.id) { m in
                    let info = Self.info(m)
                    Toggle(isOn: Binding(get: { m.id == chat.currentMode }, set: { _ in chat.setMode(m.id) })) {
                        Text(info.name)
                        Text(info.detail)   // 菜单项第二行说明（macOS 14+ 菜单支持副标题）
                    }
                }
            } label: {
                let cur = chat.modes.first { $0.id == chat.currentMode }.map(Self.info)
                Label(cur?.name ?? L("Mode"), systemImage: cur?.icon ?? "hand.raised")
            }
            .menuStyle(.button)
            .buttonStyle(.borderless)
            .foregroundStyle(.primary)
            .fixedSize()
            .help(L("How the agent asks before running tools"))
        }
    }

    static func info(_ m: ModeInfo) -> (name: String, detail: String, icon: String) {
        switch m.id {
        case "default": return (L("Ask Every Time"), L("Tools run only after you approve them."), "hand.raised")
        case "plan": return (L("Plan Only"), L("Read-only: the agent plans but runs no tools."), "list.bullet.clipboard")
        case "auto": return (L("Approve for Me"), L("Safe operations are approved automatically."), "checkmark.shield")
        default: return (m.name, m.description ?? "", "slider.horizontal.3")
        }
    }
}

/// 模型等会话配置（Agent 给什么列什么）。按钮上显示当前模型名。
struct AgentConfigMenu: View {
    @ObservedObject var chat: AgentChat

    /// 按钮上显示的：「模型」那一项的当前值（认 id / 分类为 model 的，没有就取第一个下拉项）。
    private var title: String? {
        let selects = chat.configs.filter { if case .select = $0.kind { return true } else { return false } }
        let model = selects.first { $0.id == "model" } ?? selects.first
        guard let model, case .select(let current, let options) = model.kind else { return nil }
        return options.first { $0.value == current }?.name ?? current
    }

    var body: some View {
        if let title {
            Menu {
                ForEach(chat.configs) { item in
                    switch item.kind {
                    case .select(let current, let options):
                        Picker(item.name, selection: Binding(get: { current }, set: { chat.setConfig(item.id, value: $0) })) {
                            ForEach(options, id: \.value) { o in Text(o.name).tag(o.value) }
                        }
                        .pickerStyle(.inline)
                    case .toggle(let on):
                        Toggle(item.name, isOn: Binding(get: { on }, set: { chat.setConfig(item.id, flag: $0) }))
                    }
                }
            } label: {
                Text(title).lineLimit(1)
            }
            .menuStyle(.button)
            .buttonStyle(.borderless)
            .foregroundStyle(.primary)
            .fixedSize()
            .help(L("Model"))
        }
    }
}

/// 一条对话记录。
private struct AgentItemRow: View {
    let item: AgentItem

    var body: some View {
        switch item.kind {
        case .user(let s, let images):
            VStack(alignment: .trailing, spacing: 6) {
                if !images.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(images) { AgentImageThumb(image: $0, height: 96) }
                    }
                }
                if !s.isEmpty {
                    Text(s)
                        .textSelection(.enabled)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
            }
            .padding(.leading, 48)
            .frame(maxWidth: .infinity, alignment: .trailing)
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

/// 一张图片的缩略显示（输入框上的待发图片 / 对话里用户发过的图片）。按高度等比缩放，宽度封顶。
/// 解码放在 `.task` 里只做一次：流式回复时整段对话每个碎片都会重算行视图，别每次都解一遍 JPEG。
struct AgentImageThumb: View {
    let image: AgentImage
    let height: CGFloat
    @State private var decoded: NSImage?

    var body: some View {
        Group {
            if let decoded {
                Image(nsImage: decoded)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Color.clear.aspectRatio(1, contentMode: .fit)
            }
        }
        .frame(maxWidth: height * 3)
        .frame(height: height)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(.separator) }
        .help(image.caption ?? "")
        .task(id: image.id) { decoded = NSImage(data: image.data) }
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
