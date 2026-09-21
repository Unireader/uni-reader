import ACPModel
import AppKit
import Combine
import UniformTypeIdentifiers

/// Agent 面板的内容（AppKit 版，替代 SwiftUI `AgentChatView`，行为逐项同原版，`ACP-AGENT-PLAN.md`）：
/// 状态条 + 对话记录 + 权限请求 + 输入区；内置形态顶上多一条标题行（独立窗口的操作在窗口工具栏上）。
/// 🔴 系统控件、不自绘仿系统样式；玻璃 / 材质底上的文字一律 `labelColor`。
@MainActor
final class AgentChatNSView: NSView {
    let chat: AgentChat
    private let showsHeader: Bool
    var workspaceName: String { didSet { refreshHeader() } }
    /// 内置形态标题行右边的额外按钮（目前没有；留口子）。
    private let header = InlinePanelHeaderView()
    private let headerLine = NSBox()
    private let banners = NSStackView()
    private let transcriptScroll = NSScrollView()
    private let transcript = FlippedStackView()
    private let empty = NSStackView()
    private let permissions = NSStackView()
    private let composer: AgentComposerView
    private var itemViews: [UUID: (kind: AgentItem.Kind, view: NSView)] = [:]
    private var order: [UUID] = []
    private var spinner = NSProgressIndicator()
    private var bag = Set<AnyCancellable>()
    private var queued = false
    private var started = false
    /// 对话记录此刻是不是贴着底（用户自己往上翻过就不是了）。正文高度是 Markdown 排完版才报回来的，
    /// 那时再按几何去判断已经晚了，所以滚动时就记下来。
    private var stickBottom = true
    private var bottomQueued = false

    init(chat: AgentChat, workspaceName: String, showsHeader: Bool) {
        self.chat = chat
        self.workspaceName = workspaceName
        self.showsHeader = showsHeader
        composer = AgentComposerView(chat: chat)
        super.init(frame: .zero)
        headerLine.boxType = .separator
        banners.orientation = .vertical
        banners.spacing = 0
        transcript.orientation = .vertical
        transcript.alignment = .leading
        transcript.spacing = 12
        transcript.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        transcriptScroll.documentView = transcript
        transcriptScroll.drawsBackground = false
        transcriptScroll.hasVerticalScroller = true
        transcriptScroll.autohidesScrollers = true
        transcript.translatesAutoresizingMaskIntoConstraints = false
        transcript.widthAnchor.constraint(equalTo: transcriptScroll.contentView.widthAnchor).isActive = true
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        buildEmpty()
        permissions.orientation = .vertical
        permissions.alignment = .leading
        permissions.spacing = 8
        for v in [header, headerLine, banners, transcriptScroll, empty, permissions, composer] as [NSView] { addSubview(v) }
        header.isHidden = !showsHeader
        headerLine.isHidden = !showsHeader
        transcriptScroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.publisher(for: NSView.boundsDidChangeNotification,
                                             object: transcriptScroll.contentView)
            .sink { [weak self] _ in self?.noteScrolled() }
            .store(in: &bag)
        chat.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.queueRefresh() }
            .store(in: &bag)
        AgentPanelModel.shared.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.queueRefresh() }
            .store(in: &bag)
        refresh()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) 不支持") }

    override var isFlipped: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        needsLayout = true
        guard window != nil, !started else { return }
        started = true
        chat.start()
        composer.focus()
    }

    /// 从别的页切回来：藏着的时候没摆过位（见 `layout`），补一次。
    override func viewDidUnhide() {
        super.viewDidUnhide()
        needsLayout = true
    }

    private func buildEmpty() {
        let icon = NSImageView(image: NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil) ?? NSImage())
        icon.symbolConfiguration = .init(pointSize: 30, weight: .regular)
        icon.contentTintColor = .labelColor
        let t = NSTextField(labelWithString: String(format: L("Ask %@"), AgentConfig.displayName))
        t.font = .systemFont(ofSize: 17, weight: .bold)
        t.textColor = .labelColor
        let d = NSTextField(wrappingLabelWithString: L("It can read and edit the Markdown note you are looking at, find PDF pages, and add PDF notes, highlights and bookmarks."))
        d.alignment = .center
        d.textColor = .labelColor
        d.preferredMaxLayoutWidth = 260
        empty.orientation = .vertical
        empty.spacing = 8
        for v in [icon, t, d] { empty.addArrangedSubview(v) }
    }

    // MARK: 布局

    override func layout() {
        super.layout()
        // 🔴 看不见就不摆位：`InspectorViewController.viewDidLayout` 每次布局都会给 Agent 页及其子视图设 frame，
        // 不管这页显不显示——拖分隔条时逐帧来一遍。切回来时 `viewDidUnhide` 会补一次。
        guard window != nil, !isHiddenOrHasHiddenAncestor else { return }
        let b = bounds
        var y: CGFloat = 0
        if showsHeader {
            header.frame = NSRect(x: 0, y: 0, width: b.width, height: InlinePanelHeaderView.height)
            headerLine.frame = NSRect(x: 0, y: InlinePanelHeaderView.height, width: b.width, height: 1)
            y = InlinePanelHeaderView.height + 1
        }
        let bh = banners.fittingSize.height
        banners.frame = NSRect(x: 0, y: y, width: b.width, height: bh)
        y += bh
        let ch = composer.preferredHeight
        composer.frame = NSRect(x: 12, y: b.height - 12 - ch, width: b.width - 24, height: ch)
        var bottom = composer.frame.minY - 4
        if !permissions.arrangedSubviews.isEmpty {
            let ph = permissions.fittingSize.height
            permissions.frame = NSRect(x: 12, y: bottom - 8 - ph, width: b.width - 24, height: ph)
            bottom = permissions.frame.minY
        }
        transcriptScroll.frame = NSRect(x: 0, y: y, width: b.width, height: max(0, bottom - y))
        let es = empty.fittingSize
        empty.frame = NSRect(x: (b.width - es.width) / 2, y: y + (bottom - y - es.height) / 2, width: es.width, height: es.height)
    }

    // MARK: 刷新

    private func queueRefresh() {
        guard !queued else { return }
        queued = true
        DispatchQueue.main.async { [weak self] in
            self?.queued = false
            self?.refresh()
        }
    }

    private func refresh() {
        refreshHeader()
        refreshBanners()
        refreshTranscript()
        refreshPermissions()
        composer.refresh()
        needsLayout = true
    }

    private func refreshHeader() {
        guard showsHeader else { return }
        header.configure(icon: "sparkles", title: chat.title ?? AgentConfig.displayName, subtitle: workspaceName, buttons: [
            .init(symbol: "clock.arrow.circlepath", tip: L("Earlier Chats"), menu: { [weak self] in self?.historyMenu() ?? NSMenu() }),
            .init(symbol: "ellipsis", tip: L("More"), menu: { AgentMenus.options() }),
            .init(symbol: "square.and.pencil", tip: L("New Chat"), action: { [weak self] in self?.chat.newChat() }),
        ])
    }

    func historyMenu() -> NSMenu { AgentMenus.history(chat) }

    private func refreshBanners() {
        for v in banners.arrangedSubviews { banners.removeArrangedSubview(v); v.removeFromSuperview() }
        if chat.missingMCP {
            banners.addArrangedSubview(bannerRow("exclamationmark.triangle", L("The MCP service is off, so the agent cannot see the reader."),
                                                 button: L("Start and Reconnect")) { [weak self] in
                AppDelegate.shared?.appModel.mcp.start()
                self?.chat.newChat()
            })
        }
        switch chat.phase {
        case .connecting:
            banners.addArrangedSubview(bannerRow(nil, String(format: L("Starting %@…"), AgentConfig.displayName)))
        case .loading:
            banners.addArrangedSubview(bannerRow(nil, L("Loading chat…")))
        case .failed(let msg):
            banners.addArrangedSubview(bannerRow("exclamationmark.triangle", msg, button: L("Retry")) { [weak self] in self?.chat.newChat() })
        default:
            break
        }
        for v in banners.arrangedSubviews {
            v.widthAnchor.constraint(equalTo: banners.widthAnchor).isActive = true
        }
    }

    private func bannerRow(_ icon: String?, _ text: String, button: String? = nil, action: (() -> Void)? = nil) -> NSView {
        let bar = NSVisualEffectView()
        bar.material = .headerView
        bar.blendingMode = .withinWindow
        var views: [NSView] = []
        if let icon {
            let i = NSImageView(image: NSImage(systemSymbolName: icon, accessibilityDescription: nil) ?? NSImage())
            i.contentTintColor = .labelColor
            views.append(i)
        } else {
            let s = NSProgressIndicator()
            s.style = .spinning
            s.controlSize = .small
            s.startAnimation(nil)
            views.append(s)
        }
        let t = NSTextField(wrappingLabelWithString: text)
        t.font = .preferredFont(forTextStyle: .callout)
        t.textColor = .labelColor
        t.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        views.append(t)
        if let button {
            let b = ClosureButton { action?() }
            b.title = button
            b.bezelStyle = .push
            b.controlSize = .small
            views.append(b)
        }
        let row = NSStackView(views: views)
        row.spacing = 8
        row.edgeInsets = NSEdgeInsets(top: 6, left: 12, bottom: 6, right: 12)
        row.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(row)
        let line = NSBox()
        line.boxType = .separator
        line.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(line)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
            row.topAnchor.constraint(equalTo: bar.topAnchor),
            row.bottomAnchor.constraint(equalTo: line.topAnchor),
            line.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
            line.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
            line.bottomAnchor.constraint(equalTo: bar.bottomAnchor),
        ])
        return bar
    }

    /// 对话记录：按条目 id 增量更新（流式回复每个碎片只改最后一条，别整段重建）。
    private func refreshTranscript() {
        let isEmpty = chat.items.isEmpty && chat.phase == .idle && chat.sessionId != nil
        empty.isHidden = !isEmpty
        transcriptScroll.isHidden = isEmpty
        let nearBottom = stickBottom
        let ids = chat.items.map(\.id)
        let changedOrder = ids != order
        if changedOrder {
            // 条目有增删（新对话 / 回放）：移除不在的，按新顺序补
            let keep = Set(ids)
            for (id, v) in itemViews where !keep.contains(id) { v.view.removeFromSuperview(); itemViews.removeValue(forKey: id) }
        }
        for v in transcript.arrangedSubviews { transcript.removeArrangedSubview(v) }
        for item in chat.items {
            if let cur = itemViews[item.id], cur.kind == item.kind {
                transcript.addArrangedSubview(cur.view)
            } else if let cur = itemViews[item.id], AgentItemViews.update(cur.view, to: item.kind) {
                // 流式：同一条回复 / 思考又长了一段，就地换文字，别重建视图（见 `AgentMarkdownView`）
                itemViews[item.id] = (item.kind, cur.view)
                transcript.addArrangedSubview(cur.view)
            } else {
                itemViews[item.id]?.view.removeFromSuperview()
                let v = AgentItemViews.make(item)
                if let md = v as? AgentMarkdownView { md.onHeightChange = { [weak self] in self?.keepBottom() } }
                if let d = v as? AgentDisclosureView { d.markdown?.onHeightChange = { [weak self] in self?.keepBottom() } }
                itemViews[item.id] = (item.kind, v)
                transcript.addArrangedSubview(v)
                // 宽度约束只在新建时加一次（重排时视图仍是子视图，约束还在）
                v.widthAnchor.constraint(equalTo: transcript.widthAnchor, constant: -28).isActive = true
            }
        }
        order = ids
        if chat.phase == .running, chat.permissions.isEmpty {
            transcript.addArrangedSubview(spinner)
            spinner.startAnimation(nil)
        } else {
            spinner.stopAnimation(nil)
            spinner.removeFromSuperview()
        }
        if nearBottom || changedOrder {
            DispatchQueue.main.async { [weak self] in self?.scrollToBottom() }
        }
    }

    /// 滚动（或改窗口大小）之后记一下还在不在底上。
    private func noteScrolled() {
        let clip = transcriptScroll.contentView
        stickBottom = clip.bounds.maxY >= transcript.frame.height - 40
    }

    /// 正文排完版高度变了（Markdown 渲染是异步报回来的）：本来贴着底就继续贴着，没贴底的也得让滚动视图重算一遍。
    /// 推到下一拍再做：这个回调是在排版过程中来的，当场 `layoutSubtreeIfNeeded` 等于在布局里再布局一次。
    private func keepBottom() {
        guard !bottomQueued else { return }
        bottomQueued = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.bottomQueued = false
            self.syncScroll()
        }
    }

    /// 内容高度变了之后把滚动视图对齐：滚到该在的位置 + 重算滚动条。
    ///
    /// 🔴 **非重算不可**：正文高度是引擎排完版**异步**报回来的，那一刻滚动视图自己的 frame 没动，
    /// 它就不会重新 `tile`——竖滚动条停在上一次的判断上。表现是拖宽 Inspector（内容重排变矮）之后
    /// 滚动条整个消失，改一下窗口大小又回来（2026-09-20 用户实测）。
    private func syncScroll(toBottom: Bool = false) {
        transcript.layoutSubtreeIfNeeded()
        let clip = transcriptScroll.contentView
        let maxY = max(0, transcript.frame.height - clip.bounds.height)
        if toBottom || stickBottom {
            clip.scroll(to: NSPoint(x: 0, y: maxY))
        } else if clip.bounds.origin.y > maxY {
            clip.scroll(to: NSPoint(x: 0, y: maxY))   // 内容变矮了，原来的位置已经超出去
        }
        // 🔴 **别手动调 `tile()`**：它会把系统 overlay 滚动条的布局搅乱——knob 变成一小块方块卡在角上，
        // 竖的横的都一样（2026-09-20 实测）。要让滚动条重新判断，标记 `needsLayout`，
        // 由 AppKit 在自己的布局周期里去 tile。
        transcriptScroll.needsLayout = true
        transcriptScroll.reflectScrolledClipView(clip)
    }

    private func scrollToBottom() { syncScroll(toBottom: true) }

    /// 权限请求卡片：详情（等宽、最多 5 行）+ 选项按钮（「允许一次」是强调样式，不挂回车，免得打字时顺手批掉）。
    private func refreshPermissions() {
        for v in permissions.arrangedSubviews { permissions.removeArrangedSubview(v); v.removeFromSuperview() }
        for ask in chat.permissions {
            let box = NSBox()
            box.title = String(format: L("Allow “%@”?"), ask.title)
            box.titleFont = .systemFont(ofSize: NSFont.preferredFont(forTextStyle: .callout).pointSize, weight: .semibold)
            var rows: [NSView] = []
            if !ask.detail.isEmpty {
                let d = NSTextField(wrappingLabelWithString: ask.detail)
                d.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
                d.maximumNumberOfLines = 5
                d.isSelectable = true
                d.textColor = .labelColor
                rows.append(d)
            }
            var buttons: [NSView] = [NSView()]
            for o in ask.options.reversed() {
                let b = ClosureButton { [weak self] in self?.chat.answer(ask, optionId: o.id) }
                b.title = o.name
                b.bezelStyle = .push
                if o.kind == "allow_once" { b.bezelColor = .controlAccentColor }
                buttons.append(b)
            }
            let br = NSStackView(views: buttons)
            br.spacing = 6
            rows.append(br)
            let stack = NSStackView(views: rows)
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 8
            box.contentView = stack
            permissions.addArrangedSubview(box)
            box.widthAnchor.constraint(equalTo: permissions.widthAnchor).isActive = true
            br.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
    }
}

// MARK: - 菜单（内置标题行与独立窗口工具栏共用）

@MainActor
enum AgentMenus {
    /// 历史对话（按工作目录过滤；无标题的空会话不列）。
    static func history(_ chat: AgentChat) -> NSMenu {
        let m = NSMenu()
        if chat.history.isEmpty {
            let i = NSMenuItem(title: L("No earlier chats"), action: nil, keyEquivalent: "")
            i.isEnabled = false
            m.addItem(i)
        }
        for s in chat.history.prefix(30) {
            let i = ClosureMenuItem(AgentChat.sessionLabel(s)) { [weak chat] in chat?.load(s) }
            i.state = s.sessionId.value == chat.sessionId ? .on : .off
            m.addItem(i)
        }
        return m
    }

    /// 面板本身的设置：跟随 Agent。
    static func options() -> NSMenu {
        let panel = AgentPanelModel.shared
        let m = NSMenu()
        let follow = ClosureMenuItem(L("Follow Agent")) { panel.setFollow(!panel.follow) }
        follow.state = panel.follow ? .on : .off
        m.addItem(follow)
        return m
    }

    /// 模式（审批方式）：Kimi 的三档给本地化名字与说明，认不出的 id 用 Agent 给的名字。
    static func modeInfo(_ m: ModeInfo) -> (name: String, detail: String, icon: String) {
        switch m.id {
        case "default": return (L("Ask Every Time"), L("Tools run only after you approve them."), "hand.raised")
        case "plan": return (L("Plan Only"), L("Read-only: the agent plans but runs no tools."), "list.bullet.clipboard")
        case "auto": return (L("Approve for Me"), L("Safe operations are approved automatically."), "checkmark.shield")
        default: return (m.name, m.description ?? "", "slider.horizontal.3")
        }
    }
}

// MARK: - 对话记录的各类条目

@MainActor
enum AgentItemViews {
    static func make(_ item: AgentItem) -> NSView {
        switch item.kind {
        case .user(let s, let images): return user(s, images)
        case .agent(let s): return agent(s, id: item.id)
        case .thought(let s): return thought(s, id: item.id)
        case .tool(let call): return tool(call)
        case .plan(let entries): return plan(entries)
        case .notice(let s, let isError): return notice(s, isError)
        }
    }

    /// 同一条条目又来了新内容（流式）：能就地更新就别重建视图。
    /// - Returns: 吃下了这次更新（调用方据此跳过重建）。
    static func update(_ view: NSView, to kind: AgentItem.Kind) -> Bool {
        switch kind {
        case .agent(let s):
            guard let v = view as? AgentMarkdownView else { return false }
            v.update(text: s)
            return true
        case .thought(let s):
            guard let v = view as? AgentDisclosureView, v.markdown != nil else { return false }
            v.update(text: s)
            return true
        default:
            return false
        }
    }

    private static func user(_ s: String, _ images: [AgentImage]) -> NSView {
        let col = NSStackView()
        col.orientation = .vertical
        col.alignment = .trailing
        col.spacing = 6
        if !images.isEmpty {
            let row = NSStackView(views: images.map { AgentImageThumbView(image: $0, height: 96) })
            row.spacing = 6
            col.addArrangedSubview(row)
        }
        if !s.isEmpty {
            let t = NSTextField(wrappingLabelWithString: s)
            t.isSelectable = true
            t.textColor = .labelColor
            let bubble = NSView()
            bubble.wantsLayer = true
            bubble.layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
            bubble.layer?.cornerRadius = 12
            bubble.layer?.cornerCurve = .continuous
            t.translatesAutoresizingMaskIntoConstraints = false
            bubble.addSubview(t)
            NSLayoutConstraint.activate([
                t.leadingAnchor.constraint(equalTo: bubble.leadingAnchor, constant: 12),
                t.trailingAnchor.constraint(equalTo: bubble.trailingAnchor, constant: -12),
                t.topAnchor.constraint(equalTo: bubble.topAnchor, constant: 7),
                t.bottomAnchor.constraint(equalTo: bubble.bottomAnchor, constant: -7),
            ])
            col.addArrangedSubview(bubble)
            bubble.widthAnchor.constraint(lessThanOrEqualTo: col.widthAnchor, constant: -48).isActive = true
        }
        return col
    }

    /// Agent 的回复：Markdown 引擎只读渲染（标题 / 列表 / 代码块 / 表格 / 公式，`AgentMarkdownView`）。
    private static func agent(_ s: String, id: UUID) -> NSView {
        AgentMarkdownView(text: s, fontSize: AgentMarkdown.bodyFontSize, documentId: "agent-\(id)")
    }

    /// 思考过程：折叠起来，正文同样走 Markdown 渲染（小一号）。
    private static func thought(_ s: String, id: UUID) -> NSView {
        let md = AgentMarkdownView(text: s, fontSize: AgentMarkdown.thoughtFontSize, documentId: "thought-\(id)")
        return AgentDisclosureView(header: AgentDisclosureView.headerRow(title: L("Thinking"), symbol: "brain"),
                                   body: md, markdown: md)
    }

    private static func tool(_ call: AgentToolCall) -> NSView {
        let status: NSView
        switch call.status {
        case .inProgress, .pending, .none:
            let s = NSProgressIndicator()
            s.style = .spinning
            s.controlSize = .mini
            s.startAnimation(nil)
            status = s
        case .completed:
            let i = NSImageView(image: NSImage(systemSymbolName: "checkmark.circle", accessibilityDescription: nil) ?? NSImage())
            i.contentTintColor = .systemGreen
            status = i
        case .failed:
            let i = NSImageView(image: NSImage(systemSymbolName: "xmark.circle", accessibilityDescription: nil) ?? NSImage())
            i.contentTintColor = .systemRed
            status = i
        }
        let t = NSTextField(labelWithString: call.title)
        t.font = .monospacedSystemFont(ofSize: NSFont.preferredFont(forTextStyle: .callout).pointSize, weight: .regular)
        t.lineBreakMode = .byTruncatingMiddle
        t.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let label = NSStackView(views: [status, t])
        label.spacing = 6
        guard !call.output.isEmpty else { return label }
        let out = call.output.count > 4000 ? String(call.output.prefix(4000)) + "…" : call.output
        // 工具输出是 JSON / diff 这类原样的东西，不当 Markdown 渲染：等宽照原样显示
        let text = NSTextField(wrappingLabelWithString: out)
        text.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        text.isSelectable = true
        return AgentDisclosureView(header: label, body: text)
    }

    private static func plan(_ entries: [AgentPlanEntry]) -> NSView {
        let box = NSBox()
        box.title = L("Plan")
        let rows = entries.map { e -> NSView in
            let icon: String
            switch e.status {
            case .pending: icon = "circle"
            case .inProgress: icon = "circle.lefthalf.filled"
            case .completed: icon = "checkmark.circle"
            case .cancelled: icon = "xmark.circle"
            }
            let i = NSImageView(image: NSImage(systemSymbolName: icon, accessibilityDescription: nil) ?? NSImage())
            let l = NSTextField(wrappingLabelWithString: e.text)
            l.font = .preferredFont(forTextStyle: .callout)
            let s = NSStackView(views: [i, l])
            s.alignment = .top
            s.spacing = 6
            return s
        }
        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        box.contentView = stack
        return box
    }

    private static func notice(_ s: String, _ isError: Bool) -> NSView {
        let i = NSImageView(image: NSImage(systemSymbolName: isError ? "exclamationmark.triangle" : "info.circle",
                                           accessibilityDescription: nil) ?? NSImage())
        let t = NSTextField(wrappingLabelWithString: s)
        t.font = .preferredFont(forTextStyle: .callout)
        let color: NSColor = isError ? .systemRed : .labelColor
        i.contentTintColor = color
        t.textColor = color
        let row = NSStackView(views: [i, t])
        row.alignment = .top
        row.spacing = 6
        return row
    }
}

/// 一张图片的缩略显示（输入框上的待发图片 / 对话里用户发过的图片）：按高度等比、宽度封顶 3 倍高。
final class AgentImageThumbView: NSView {
    init(image: AgentImage, height: CGFloat) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor
        layer?.contentsGravity = .resizeAspect
        toolTip = image.caption
        var aspect: CGFloat = 1
        if let img = NSImage(data: image.data) {
            layer?.contents = img
            if img.size.height > 0 { aspect = img.size.width / img.size.height }
        }
        widthAnchor.constraint(equalToConstant: min(height * 3, height * aspect)).isActive = true
        heightAnchor.constraint(equalToConstant: height).isActive = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) 不支持") }
}

// MARK: - 输入区

/// 输入区：一个圆角框，上面是待发图片，中间多行输入，下面一行「附件 / 模式 …… 模型 / 发送」。
/// **回车发送，⇧回车 / ⌥回车换行**；🔴 输入法组字时的回车是上屏，不是发送（中文用户，必须）。
/// 默认约三行高，随内容长高，到上限后框内滚动。图片文件直接拖到框上也能附上。
@MainActor
final class AgentComposerView: NSView, NSTextViewDelegate {
    private let chat: AgentChat
    private let strip = NSStackView()
    private let stripScroll = NSScrollView()
    private let textScroll = NSScrollView()
    private let textView = ComposerTextView()
    private let placeholder = NSTextField(labelWithString: "")
    private let attach = NSButton()
    private let modeMenu = NSPopUpButton(frame: .zero, pullsDown: true)
    private let configMenu = NSPopUpButton(frame: .zero, pullsDown: true)
    private let send = NSButton()
    private var textHeight: CGFloat = 56

    init(chat: AgentChat) {
        self.chat = chat
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 14
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor
        layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
        strip.spacing = 8
        stripScroll.documentView = strip
        stripScroll.drawsBackground = false
        stripScroll.hasHorizontalScroller = false
        textView.isRichText = false
        textView.font = .systemFont(ofSize: NSFont.systemFontSize)
        textView.drawsBackground = false
        textView.delegate = self
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 5
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.onSend = { [weak self] in self?.sendTapped() }
        textScroll.documentView = textView
        textScroll.drawsBackground = false
        textScroll.hasVerticalScroller = true
        textScroll.autohidesScrollers = true
        placeholder.textColor = .tertiaryLabelColor
        attach.image = NSImage(systemSymbolName: "photo.badge.plus", accessibilityDescription: L("Attach Images…"))
        attach.imagePosition = .imageOnly
        attach.isBordered = false
        attach.contentTintColor = .labelColor
        attach.toolTip = L("Attach Images…")
        attach.target = self
        attach.action = #selector(attachTapped)
        for p in [modeMenu, configMenu] {
            p.isBordered = false
            p.font = .preferredFont(forTextStyle: .callout)
        }
        modeMenu.toolTip = L("How the agent asks before running tools")
        configMenu.toolTip = L("Model")
        send.bezelStyle = .circular
        send.imagePosition = .imageOnly
        send.target = self
        send.action = #selector(sendTapped)
        for v in [stripScroll, textScroll, placeholder, attach, modeMenu, configMenu, send] as [NSView] { addSubview(v) }
        registerForDraggedTypes([.fileURL])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) 不支持") }

    override var isFlipped: Bool { true }

    func focus() { window?.makeFirstResponder(textView) }

    var preferredHeight: CGFloat {
        10 + (chat.attachments.isEmpty ? 0 : 56 + 6 + 8) + textHeight + 8 + 26 + 8
    }

    // MARK: 刷新

    func refresh() {
        // 待发图片
        for v in strip.arrangedSubviews { strip.removeArrangedSubview(v); v.removeFromSuperview() }
        for img in chat.attachments {
            let thumb = AgentImageThumbView(image: img, height: 56)
            let remove = ClosureButton { [weak self] in self?.chat.removeAttachment(img.id) }
            remove.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: L("Remove"))
            remove.bezelStyle = .circular
            remove.controlSize = .mini
            remove.toolTip = L("Remove")
            let holder = NSView()
            thumb.translatesAutoresizingMaskIntoConstraints = false
            remove.translatesAutoresizingMaskIntoConstraints = false
            holder.addSubview(thumb)
            holder.addSubview(remove)
            NSLayoutConstraint.activate([
                thumb.leadingAnchor.constraint(equalTo: holder.leadingAnchor),
                thumb.bottomAnchor.constraint(equalTo: holder.bottomAnchor),
                thumb.topAnchor.constraint(equalTo: holder.topAnchor, constant: 6),
                holder.trailingAnchor.constraint(equalTo: thumb.trailingAnchor, constant: 6),
                remove.centerXAnchor.constraint(equalTo: thumb.trailingAnchor),
                remove.centerYAnchor.constraint(equalTo: thumb.topAnchor),
            ])
            strip.addArrangedSubview(holder)
        }
        stripScroll.isHidden = chat.attachments.isEmpty
        placeholder.stringValue = chat.attachments.isEmpty ? String(format: L("Ask %@…"), AgentConfig.displayName)
                                                           : L("Ask about the image…")
        placeholder.isHidden = !textView.string.isEmpty
        textView.isEditable = chat.sessionId != nil
        attach.isEnabled = chat.sessionId != nil
        refreshModeMenu()
        refreshConfigMenu()
        if chat.phase == .running {
            send.image = NSImage(systemSymbolName: "stop.fill", accessibilityDescription: L("Stop"))
            send.toolTip = L("Stop")
            send.keyEquivalent = "."
            send.keyEquivalentModifierMask = .command
            send.isEnabled = true
        } else {
            send.image = NSImage(systemSymbolName: "arrow.up", accessibilityDescription: L("Send"))
            send.toolTip = L("Send")
            send.keyEquivalent = ""
            send.isEnabled = canSend
        }
        send.bezelColor = .controlAccentColor
        needsLayout = true
    }

    private func refreshModeMenu() {
        modeMenu.isHidden = chat.modes.isEmpty
        guard !chat.modes.isEmpty else { return }
        let menu = NSMenu()
        let cur = chat.modes.first { $0.id == chat.currentMode }.map(AgentMenus.modeInfo)
        let head = NSMenuItem(title: cur?.name ?? L("Mode"), action: nil, keyEquivalent: "")
        head.image = NSImage(systemSymbolName: cur?.icon ?? "hand.raised", accessibilityDescription: nil)
        menu.addItem(head)
        for m in chat.modes {
            let info = AgentMenus.modeInfo(m)
            let i = ClosureMenuItem(info.name) { [weak self] in self?.chat.setMode(m.id) }
            i.subtitle = info.detail
            i.state = m.id == chat.currentMode ? .on : .off
            menu.addItem(i)
        }
        modeMenu.menu = menu
    }

    private func refreshConfigMenu() {
        let selects = chat.configs.filter { if case .select = $0.kind { return true } else { return false } }
        let model = selects.first { $0.id == "model" } ?? selects.first
        guard let model, case .select(let current, let options) = model.kind else { configMenu.isHidden = true; return }
        configMenu.isHidden = false
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: options.first { $0.value == current }?.name ?? current, action: nil, keyEquivalent: ""))
        for item in chat.configs {
            switch item.kind {
            case .select(let cur, let opts):
                let header = NSMenuItem(title: item.name, action: nil, keyEquivalent: "")
                header.isEnabled = false
                menu.addItem(header)
                for o in opts {
                    let i = ClosureMenuItem(o.name) { [weak self] in self?.chat.setConfig(item.id, value: o.value) }
                    i.state = o.value == cur ? .on : .off
                    i.indentationLevel = 1
                    menu.addItem(i)
                }
            case .toggle(let on):
                let i = ClosureMenuItem(item.name) { [weak self] in self?.chat.setConfig(item.id, flag: !on) }
                i.state = on ? .on : .off
                menu.addItem(i)
            }
        }
        configMenu.menu = menu
    }

    // MARK: 布局

    override func layout() {
        super.layout()
        let b = bounds
        var y: CGFloat = 10
        if !stripScroll.isHidden {
            stripScroll.frame = NSRect(x: 12, y: y, width: b.width - 24, height: 62)
            strip.frame = NSRect(origin: .zero, size: strip.fittingSize)
            y += 62 + 8
        }
        textScroll.frame = NSRect(x: 12 - 5, y: y, width: b.width - 24 + 10, height: textHeight)
        placeholder.frame = NSRect(x: 12, y: y, width: b.width - 24, height: 18)
        let rowY = b.height - 8 - 26
        attach.frame = NSRect(x: 10, y: rowY, width: 26, height: 26)
        send.frame = NSRect(x: b.width - 12 - 28, y: rowY - 1, width: 28, height: 28)
        // 两个下拉菜单分「附图」与「发送」之间的宽度：放得下按原宽；放不下一起收窄（标题自动省略号截断），
        // 太窄就先让模式菜单让位——各按原宽摆会叠在一起（2026-09-19 用户报面板变窄后挤成一团）
        let left = attach.frame.maxX + 4, right = send.frame.minX - 6
        let avail = max(0, right - left)
        let gap: CGFloat = 4
        modeMenu.sizeToFit()
        configMenu.sizeToFit()
        let wantM = modeMenu.isHidden ? 0 : modeMenu.frame.width
        let wantC = configMenu.isHidden ? 0 : configMenu.frame.width
        var wM = wantM, wC = wantC
        if wantM + wantC + (wantM > 0 && wantC > 0 ? gap : 0) > avail {
            if wantM > 0, wantC > 0 {
                wC = min(wantC, max(avail * 0.55, avail - wantM - gap))
                wM = avail - gap - wC
                if wM < 48 { wM = 0; wC = min(wantC, avail) }   // 太窄：模式菜单先不显示
            } else {
                wM = min(wantM, avail)
                wC = min(wantC, avail)
            }
        }
        let modeShown = wM > 0
        modeMenu.alphaValue = modeShown ? 1 : 0
        modeMenu.frame = NSRect(x: left, y: rowY, width: modeShown ? wM : 0, height: 26)
        configMenu.frame = NSRect(x: right - wC, y: rowY, width: wC, height: 26)
    }

    // MARK: 输入

    func textDidChange(_ notification: Notification) {
        placeholder.isHidden = !textView.string.isEmpty
        send.isEnabled = chat.phase == .running || canSend
        // 随内容长高：约三行起步，最多 200，超出框内滚
        textView.layoutManager?.ensureLayout(for: textView.textContainer!)
        let used = textView.layoutManager?.usedRect(for: textView.textContainer!).height ?? 0
        let h = min(200, max(56, used + 4))
        if abs(h - textHeight) > 0.5 {
            textHeight = h
            superview?.needsLayout = true
        }
    }

    private var canSend: Bool {
        chat.phase == .idle && chat.sessionId != nil && !textView.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    @objc private func sendTapped() {
        if chat.phase == .running { chat.cancel(); return }
        guard canSend else { return }
        chat.send(textView.string)
        textView.string = ""
        textDidChange(Notification(name: NSText.didChangeNotification))
    }

    @objc private func attachTapped() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        let done: (NSApplication.ModalResponse) -> Void = { [weak self] r in
            if r == .OK { self?.chat.attachFiles(panel.urls) }
        }
        if let w = window { panel.beginSheetModal(for: w, completionHandler: done) } else { panel.begin(completionHandler: done) }
    }

    // 图片文件拖到框上 = 附上
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { imageURLs(sender).isEmpty ? [] : .copy }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = imageURLs(sender)
        guard !urls.isEmpty else { return false }
        chat.attachFiles(urls)
        return true
    }
    private func imageURLs(_ info: NSDraggingInfo) -> [URL] {
        let urls = (info.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                       options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        return urls.filter { UTType(filenameExtension: $0.pathExtension)?.conforms(to: .image) == true }
    }

    // 点框里空白处也进输入态
    override func mouseDown(with event: NSEvent) { focus() }
}

/// 输入框：回车发送；⇧ / ⌥ 回车换行；组字中（有 marked text）回车交给输入法上屏。
final class ComposerTextView: NSTextView {
    var onSend: () -> Void = {}

    override func keyDown(with event: NSEvent) {
        let isReturn = event.keyCode == 36 || event.keyCode == 76
        if isReturn, !hasMarkedText(), event.modifierFlags.intersection([.shift, .option]).isEmpty {
            onSend()
            return
        }
        super.keyDown(with: event)
    }
}
