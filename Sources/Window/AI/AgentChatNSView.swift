import ACPModel
import AppKit
import Combine
import UniformTypeIdentifiers

/// 对话记录滚动条的几何打点。**默认关**，同 `mcpLog` 的做法用文件开关：
/// ```
/// touch ~/Library/Logs/UniReader-agent-scroll.log    # 开启
/// rm    ~/Library/Logs/UniReader-agent-scroll.log    # 关闭
/// ```
/// 排「拖完分隔条竖滚动条不见了」这类问题用：每次对齐滚动位置记一行几何，
/// 看得出内容高 / 视口高 / 滚动条状态三者是不是对得上。
enum AgentScrollLog {
    static let url = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Logs/UniReader-agent-scroll.log")

    static func write(_ s: String) {
        guard let h = try? FileHandle(forWritingTo: url) else { return }   // 文件不在 = 没开
        defer { try? h.close() }
        _ = try? h.seekToEnd()
        try? h.write(contentsOf: Data("\(Date.now.formatted(date: .omitted, time: .standard)) \(s)\n".utf8))
    }
}

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
    /// 上次摆位时对话记录滚动视图的大小（尺寸变了要让滚动条重新判断，见 `layout`）。
    private var lastScrollSize: NSSize = .zero
    /// 上次按新尺寸摆过位的面板大小 / 那一刻的时间。连着变 = 正在拖，见 `layout`。
    private var lastLaidOutSize: NSSize = .zero
    private var lastSizeChange = Date.distantPast
    private var resizeTimer: Timer?
    /// 「值变了才重建」用的快照。流式回复每来一个碎片就走一次 `refresh()`，而标题行 / 提示条 /
    /// 权限卡片跟碎片全无关系——每次重建一遍纯属白费（同工具栏那条「值变了才写」的老规矩）。
    private var headerKey: String?
    private var bannerKey: String?
    private var permissionKey: [UUID] = []
    /// 权限卡片里要跟着面板宽度改的东西：会折行的文字（换行宽度）与按钮行（放不下就竖排）。
    private var permissionLabels: [NSTextField] = []
    private var permissionButtonRows: [(row: NSStackView, spacer: NSView)] = []
    /// `permissions` 是按 frame 摆的，取 `fittingSize` 前先用它把宽度定下来，否则卡片按文字一整行的宽度算高。
    private lazy var permissionsWidth = permissions.widthAnchor.constraint(equalToConstant: 0)

    init(chat: AgentChat, workspaceName: String, showsHeader: Bool) {
        self.chat = chat
        self.workspaceName = workspaceName
        self.showsHeader = showsHeader
        composer = AgentComposerView(chat: chat)
        super.init(frame: .zero)
        // 拖动期间面板停住不摆位（见 `layout`），内容还是旧宽度，别让它画到面板外面去
        clipsToBounds = true
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
        // 🔴 **尺寸连着变（拖分隔条 / 拖窗口）的整个过程里，这块面板停住不动**：不摆位、不重排正文、
        // 不动滚动条，停手后再一次性重来（`finishResize`）。用户 2026-09-21 定：
        // 「拖拽过程中不更新 UI，直到松手后再重新布局对话流」——逐帧跟着改宽度就是每帧把每条回复
        // 整篇重排一遍，中间态还会裁成半截。停住期间内容按旧宽度留着，所以要 `clipsToBounds`。
        if bounds.size != lastLaidOutSize {
            let now = Date()
            defer { lastSizeChange = now }
            if now.timeIntervalSince(lastSizeChange) < Self.resizeQuiet {
                armResizeEnd()
                return
            }
        }
        resizeTimer?.invalidate()
        resizeTimer = nil
        lastLaidOutSize = bounds.size
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
            fitPermissions(width: b.width - 24)
            let ph = permissions.fittingSize.height
            permissions.frame = NSRect(x: 12, y: bottom - 8 - ph, width: b.width - 24, height: ph)
            bottom = permissions.frame.minY
        }
        transcriptScroll.frame = NSRect(x: 0, y: y, width: b.width, height: max(0, bottom - y))
        // 🔴 面板尺寸变了（拖 Inspector 分隔条 / 改窗口大小）也得让滚动视图重新判断一次：
        // 内容高度不一定跟着变（正文没重排就没人报高度），而它自己不会重算——表现就是
        // 拖完滚动条不见了（AGENTS.md 里记着这条；2026-09-21 又踩一次）。
        if transcriptScroll.frame.size != lastScrollSize {
            lastScrollSize = transcriptScroll.frame.size
            keepBottom()
        }
        let es = empty.fittingSize
        empty.frame = NSRect(x: (b.width - es.width) / 2, y: y + (bottom - y - es.height) / 2, width: es.width, height: es.height)
    }

    /// 尺寸不再变多久算「停手」。比一帧长不少，又短到松手时看不出等待。
    private static let resizeQuiet: TimeInterval = 0.12

    private func armResizeEnd() {
        resizeTimer?.invalidate()
        let t = Timer(timeInterval: Self.resizeQuiet, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.resizeTimer = nil
                self?.finishResize()
            }
        }
        resizeTimer = t
        RunLoop.main.add(t, forMode: .common)   // .common：拖动期间这只表也得照常走
    }

    /// 停手了：按新尺寸摆好位 → 对话流立刻按新宽度重排 → 滚动条重新判断。
    private func finishResize() {
        lastSizeChange = .distantPast   // 让这一趟 `layout` 认得出「不是在拖」
        logGeometry("停手前")
        needsLayout = true
        layoutSubtreeIfNeeded()
        for (_, entry) in itemViews {
            (entry.view as? AgentMarkdownView)?.flushNow()
            (entry.view as? AgentDisclosureView)?.markdown?.flushNow()
        }
        syncScroll()
        keepBottom()   // 正文是排完版才异步报高度的，下一拍再对一次滚动条
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
        let key = "\(chat.title ?? "")\u{1}\(workspaceName)"
        guard key != headerKey else { return }
        headerKey = key
        header.configure(icon: "sparkles", title: chat.title ?? AgentConfig.displayName, subtitle: workspaceName, buttons: [
            .init(symbol: "clock.arrow.circlepath", tip: L("Earlier Chats"), menu: { [weak self] in self?.historyMenu() ?? NSMenu() }),
            .init(symbol: "ellipsis", tip: L("More"), menu: { AgentMenus.options() }),
            .init(symbol: "square.and.pencil", tip: L("New Chat"), action: { [weak self] in self?.chat.newChat() }),
        ])
    }

    func historyMenu() -> NSMenu { AgentMenus.history(chat) }

    private func refreshBanners() {
        let key = "\(chat.missingMCP)\u{1}\(chat.phase)"
        guard key != bannerKey else { return }
        bannerKey = key
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
    ///
    /// 🔴 **别每次刷新都把整排视图拆下来再装回去**（2026-09-21 用户实测「回答太多会卡顿」的根因）：
    /// `NSStackView` 每增删一个 arranged subview 都要重建一整串间距 / 对齐约束，回答越长这排视图越多，
    /// 而流式期间每个碎片都来一次——于是越说越卡。这里先算出这排视图**应该**是什么样，
    /// 再只动第一处不一样的位置往后那一段；最常见的情况（只是最后一条回复又长了一段）一动不动。
    private func refreshTranscript() {
        let isEmpty = chat.items.isEmpty && chat.phase == .idle && chat.sessionId != nil
        empty.isHidden = !isEmpty
        transcriptScroll.isHidden = isEmpty
        let ids = chat.items.map(\.id)
        // 条目只在末尾追加 = 同一段对话往下说；否则是换了一段（新对话 / 回放 / 清空）
        let appended = ids.count >= order.count && Array(ids.prefix(order.count)) == order
        if !appended {
            let keep = Set(ids)
            for (id, v) in itemViews where !keep.contains(id) { v.view.removeFromSuperview(); itemViews.removeValue(forKey: id) }
        }
        var views: [NSView] = []
        views.reserveCapacity(chat.items.count + 1)
        // 🔴 这一轮新建的条目视图。宽度约束**必须等它进了 stack 再激活**：约束两端要有共同祖先，
        // 刚 `make` 出来的视图还没有父视图，当场激活 = Auto Layout 抛异常、进程 abort
        // （2026-09-21 实测，一点历史对话就崩）。
        var fresh: [NSView] = []
        for item in chat.items {
            if let cur = itemViews[item.id], cur.kind == item.kind {
                views.append(cur.view)
            } else if let cur = itemViews[item.id], AgentItemViews.update(cur.view, to: item.kind) {
                // 流式：同一条回复 / 思考又长了一段，就地换文字，别重建视图（见 `AgentMarkdownView`）
                itemViews[item.id] = (item.kind, cur.view)
                views.append(cur.view)
            } else {
                itemViews[item.id]?.view.removeFromSuperview()
                let v = AgentItemViews.make(item)
                if let md = v as? AgentMarkdownView { md.onHeightChange = { [weak self] in self?.keepBottom() } }
                if let d = v as? AgentDisclosureView { d.markdown?.onHeightChange = { [weak self] in self?.keepBottom() } }
                itemViews[item.id] = (item.kind, v)
                views.append(v)
                fresh.append(v)
            }
        }
        if chat.phase == .running, chat.permissions.isEmpty {
            views.append(spinner)
            spinner.startAnimation(nil)
        } else {
            spinner.stopAnimation(nil)
        }
        let moved = applyTranscriptViews(views)
        // 进了 stack 才有共同祖先，这时才能激活（只在新建时加一次：重排时视图仍是子视图，约束还在）。
        // `superview` 那道判断是保险：没进去就跳过——宽度不对总好过整个 App 挂掉。
        for v in fresh where v.superview != nil {
            v.widthAnchor.constraint(equalTo: transcript.widthAnchor, constant: -28).isActive = true
        }
        order = ids
        // 🔴 **用户自己往上翻过就别再把他拽回底下**：原来只要条目数组变了就无条件滚到底，
        // 而回答期间新条目（工具调用 / 新一段回复）不断冒出来，表现就是「回答时根本滚不上去」
        // （2026-09-21 用户实测）。只有换了一段对话（回放 / 新对话）才强制回底。
        if !appended {
            DispatchQueue.main.async { [weak self] in self?.scrollToBottom() }
        } else if moved {
            keepBottom()   // 这排视图变了 = 内容高度会变，滚动条得重新判断（滚不滚由 `stickBottom` 定）
        }
    }

    /// 把这排视图摆成 `views`：从第一处不一样的位置往后重装，前面原样不动。
    /// - Returns: 真的动过（调用方据此决定要不要重新对齐滚动位置）。
    @discardableResult
    private func applyTranscriptViews(_ views: [NSView]) -> Bool {
        let current = transcript.arrangedSubviews
        var k = 0
        while k < current.count, k < views.count, current[k] === views[k] { k += 1 }
        guard k < current.count || k < views.count else { return false }
        let keep = Set(views.map(ObjectIdentifier.init))
        for v in current[k...] {
            transcript.removeArrangedSubview(v)
            // 不再要的（被替换掉的条目视图、停下来的转圈）才真的摘掉
            if !keep.contains(ObjectIdentifier(v)) { v.removeFromSuperview() }
        }
        for v in views[k...] { transcript.addArrangedSubview(v) }
        return true
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
        logGeometry(toBottom ? "回底" : "对齐")
    }

    /// 打一行几何（默认不开，见 `AgentScrollLog`）。
    private func logGeometry(_ tag: String) {
        let clip = transcriptScroll.contentView
        let content = transcript.frame.height, viewport = clip.bounds.height
        let scroller = transcriptScroll.verticalScroller
        AgentScrollLog.write("""
            \(tag) 面板\(Int(bounds.width))×\(Int(bounds.height)) 滚动视图\(Int(transcriptScroll.frame.width))×\
            \(Int(transcriptScroll.frame.height)) 视口\(Int(clip.bounds.width))×\(Int(viewport)) \
            内容高\(Int(content)) 该有竖条=\(content > viewport + 0.5) 竖条\
            \(scroller == nil ? "无" : (scroller!.isHidden ? "藏" : "显"))\
            宽\(Int(scroller?.frame.width ?? 0)) 位置\(Int(clip.bounds.origin.y)) \
            贴底=\(stickBottom) 条目\(transcript.arrangedSubviews.count)
            """)
    }

    private func scrollToBottom() { syncScroll(toBottom: true) }

    /// 权限请求卡片：标题（请求什么，会折行）+ 详情（等宽、最多 5 行）+ 选项按钮（「允许一次」是强调样式，
    /// 不挂回车，免得打字时顺手批掉）。
    ///
    /// 🔴 别再写 `box.contentView = stack`（2026-09-26 用户报「元素全挤在一行」）：那样 box 的内容视图走
    /// autoresizing，里面的约束传不到 box 的高度上，`fittingSize` 只算出标题那一行高，详情和按钮全叠在上面。
    /// 现在是内容视图用约束钉在 box 四边、stack 钉在内容视图里；标题也不用 box 自带的（只有一行、长路径被截断），
    /// 改成可折行的标签。离屏验证 `spike/agent-permission-card-test.swift`。
    private func refreshPermissions() {
        let ids = chat.permissions.map(\.id)
        guard ids != permissionKey else { return }
        permissionKey = ids
        for v in permissions.arrangedSubviews { permissions.removeArrangedSubview(v); v.removeFromSuperview() }
        permissionLabels = []
        permissionButtonRows = []
        permissionsWidth.isActive = !chat.permissions.isEmpty
        for ask in chat.permissions {
            let box = NSBox()
            box.titlePosition = .noTitle
            let title = NSTextField(wrappingLabelWithString: String(format: L("Allow “%@”?"), ask.title))
            title.font = .systemFont(ofSize: NSFont.preferredFont(forTextStyle: .callout).pointSize, weight: .semibold)
            title.textColor = .labelColor
            var rows: [NSView] = [title]
            var labels = [title]
            if !ask.detail.isEmpty {
                let d = NSTextField(wrappingLabelWithString: ask.detail)
                d.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
                d.maximumNumberOfLines = 5
                d.isSelectable = true
                d.textColor = .labelColor
                rows.append(d)
                labels.append(d)
            }
            let spacer = NSView()
            var buttons: [NSView] = [spacer]
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
            stack.translatesAutoresizingMaskIntoConstraints = false
            let content = NSView()
            content.addSubview(stack)
            box.contentView = content
            content.translatesAutoresizingMaskIntoConstraints = false   // 装进 box 之后再关，box 会重设它
            // 🔴 先进 stack 再激活约束（两端要有共同祖先，见 AGENTS.md「约束激活顺序」那条）
            permissions.addArrangedSubview(box)
            var cs: [NSLayoutConstraint] = [
                content.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 5),
                content.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -5),
                content.topAnchor.constraint(equalTo: box.topAnchor, constant: 5),
                content.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -5),
                stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 8),
                stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -8),
                stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 8),
                stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -8),
                box.widthAnchor.constraint(equalTo: permissions.widthAnchor),
                br.widthAnchor.constraint(equalTo: stack.widthAnchor),
            ]
            cs += labels.map { $0.widthAnchor.constraint(equalTo: stack.widthAnchor) }
            // 不许压扁：卡片高度不够时宁可整块变高，也不能让标题 / 详情被压成 0 高
            for l in labels { l.setContentCompressionResistancePriority(.required, for: .vertical) }
            NSLayoutConstraint.activate(cs)
            permissionLabels += labels
            permissionButtonRows.append((br, spacer))
        }
    }

    /// 按面板宽度定下权限卡片的折行宽度与按钮排法：按钮一行放得下就靠右横排，放不下就竖排、各占满一行
    /// （选项名是 Agent 给的，长短不定；Inspector 最窄 300pt 时卡片里只剩约 250pt）。
    private func fitPermissions(width: CGFloat) {
        // 先改 frame 宽再改约束：`permissions` 的 frame 也会折成约束，两者一先一后就是一次约束冲突
        permissions.frame.size.width = width
        permissionsWidth.constant = width
        let inner = width - 10 - 16   // box 内容边距 5×2 + stack 边距 8×2
        for l in permissionLabels where l.preferredMaxLayoutWidth != inner { l.preferredMaxLayoutWidth = inner }
        for (row, spacer) in permissionButtonRows {
            let buttons = row.arrangedSubviews.filter { $0 !== spacer }
            let need = buttons.reduce(0) { $0 + $1.fittingSize.width } + row.spacing * CGFloat(max(0, buttons.count - 1))
            let orientation: NSUserInterfaceLayoutOrientation = need <= inner ? .horizontal : .vertical
            guard row.orientation != orientation else { continue }
            row.orientation = orientation
            row.alignment = orientation == .vertical ? .width : .centerY
            spacer.isHidden = orientation == .vertical
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
            let row = NSStackView(views: images.map { AgentImageThumbView(image: $0, side: 56) })
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

/// 图片缩略图（输入框上待发的 / 对话里用户发过的）：**固定的圆角正方形，等比填满、裁掉多余**，
/// 不追求看清内容（2026-09-24 用户定：原先按宽高比显示，宽截图成了一长条，不好看）。
/// 看内容：**悬停**一会儿弹系统 popover 预览（同工具栏「目录」面板那种），移开就收；**单击**开固定窗口看原图
/// （`AgentImageViewer`）。
final class AgentImageThumbView: NSView {
    private let image: AgentImage
    private var hoverTimer: Timer?
    private var preview: NSPopover?

    /// 悬停多久才弹预览：鼠标只是划过去时不闪一下。
    private static let hoverDelay: TimeInterval = 0.35
    /// 预览里图片最长边（点）。
    private static let previewMax: CGFloat = 360

    init(image: AgentImage, side: CGFloat) {
        self.image = image
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor
        layer?.contentsGravity = .resizeAspectFill
        if let img = NSImage(data: image.data) { layer?.contents = img }
        widthAnchor.constraint(equalToConstant: side).isActive = true
        heightAnchor.constraint(equalToConstant: side).isActive = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) 不支持") }

    deinit { hoverTimer?.invalidate() }

    // MARK: 单击 = 固定窗口

    override func mouseDown(with event: NSEvent) {}   // 别让输入框那层把它当成「点空白处进输入态」
    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        closePreview()
        AgentImageViewer.shared.show(image, near: window)
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

    // MARK: 悬停 = popover 预览

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for t in trackingAreas { removeTrackingArea(t) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) {
        hoverTimer?.invalidate()
        hoverTimer = Timer.scheduledTimer(withTimeInterval: Self.hoverDelay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.showPreview() }
        }
    }

    override func mouseExited(with event: NSEvent) { closePreview() }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { closePreview() }
        super.viewWillMove(toWindow: newWindow)
    }

    private func showPreview() {
        guard window != nil, preview == nil, let img = NSImage(data: image.data) else { return }
        let scale = window?.backingScaleFactor ?? 2
        if let rep = img.representations.first, rep.pixelsWide > 0, rep.pixelsHigh > 0 {
            img.size = NSSize(width: CGFloat(rep.pixelsWide) / scale, height: CGFloat(rep.pixelsHigh) / scale)
        }
        let fit = min(1, Self.previewMax / max(img.size.width, img.size.height, 1))
        let size = NSSize(width: max(40, img.size.width * fit), height: max(40, img.size.height * fit))
        let view = NSImageView(frame: NSRect(origin: .zero, size: size))
        view.image = img
        view.imageScaling = .scaleProportionallyUpOrDown
        let vc = NSViewController()
        vc.view = view
        let p = NSPopover()
        p.contentViewController = vc
        p.contentSize = size
        // 自己管开合（移开就收），不交给 transient：那种要点一下别处才收
        p.behavior = .applicationDefined
        preview = p
        p.show(relativeTo: bounds, of: self, preferredEdge: .maxY)
    }

    private func closePreview() {
        hoverTimer?.invalidate()
        hoverTimer = nil
        preview?.close()
        preview = nil
    }
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
    /// 「值变了才重建」用的快照（同 `AgentChatNSView`）：两个下拉菜单动辄几十项，
    /// 而流式回复每个碎片都会叫一次 `refresh()`。
    private var attachmentKey: [UUID] = []
    private var modeKey: String?
    private var configKey: String?
    private var sendKey: String?
    /// `@` 提及（`ACP-AGENT-PLAN.md §8`）：候选浮窗、正在输入的那个 `@…` 的范围、
    /// 这次弹出时取的候选（一次弹出只取一次，打字只重新过滤）、按 Esc 关掉的是哪个 `@`（它不再自己弹出来）、
    /// 以及已经选进输入框的文件（发送时还留在正文里的才附上）。
    private let mentionPopup = AgentMentionPopup()
    private var mentionRange: NSRange?
    private var mentionCandidates: [AgentMention]?
    private var dismissedMentionAt: Int?
    private var pickedMentions: [AgentMention] = []

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
        textView.onKey = { [weak self] in self?.handleMentionKey($0) ?? false }
        mentionPopup.onPick = { [weak self] in self?.pickMention($0) }
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

    /// 待发图片缩略图的边长（正方形，2026-09-24 从 56 收小；悬停预览、单击看原图）。
    static let thumbHeight: CGFloat = 44

    var preferredHeight: CGFloat {
        10 + (chat.attachments.isEmpty ? 0 : Self.thumbHeight + 8) + textHeight + 8 + 26 + 8
    }

    // MARK: 刷新

    func refresh() {
        refreshAttachments()
        placeholder.isHidden = !textView.string.isEmpty
        textView.isEditable = chat.sessionId != nil
        attach.isEnabled = chat.sessionId != nil
        refreshModeMenu()
        refreshConfigMenu()
        refreshSendButton()
        needsLayout = true
    }

    /// 待发图片。缩略图只在这排图片真的变了时重建；显隐与占位文字每次都要落实
    /// （它俩管着输入框怎么摆位，漏一次空的图片条就白占一条缩略图的高度）。
    private func refreshAttachments() {
        defer {
            stripScroll.isHidden = chat.attachments.isEmpty
            let hint = chat.attachments.isEmpty ? String(format: L("Ask %@…"), AgentConfig.displayName)
                                                : L("Ask about the image…")
            if placeholder.stringValue != hint { placeholder.stringValue = hint }
        }
        let ids = chat.attachments.map(\.id)
        guard ids != attachmentKey else { return }
        attachmentKey = ids
        for v in strip.arrangedSubviews { strip.removeArrangedSubview(v); v.removeFromSuperview() }
        for img in chat.attachments {
            let thumb = AgentImageThumbView(image: img, side: Self.thumbHeight)
            let remove = ClosureButton { [weak self] in self?.chat.removeAttachment(img.id) }
            // 移除钮压在缩略图左上角：系统的 xmark.circle.fill，白叉 + 深色半透明圆底，
            // 白底的截图上也看得清（原先右上角那颗 mini 圆钮在白图上几乎看不见，2026-09-24 用户报）
            let symbol = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
                .applying(.init(paletteColors: [.white, NSColor.black.withAlphaComponent(0.6)]))
            remove.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: L("Remove"))?
                .withSymbolConfiguration(symbol)
            remove.imagePosition = .imageOnly
            remove.isBordered = false
            remove.toolTip = L("Remove")
            let holder = NSView()
            thumb.translatesAutoresizingMaskIntoConstraints = false
            remove.translatesAutoresizingMaskIntoConstraints = false
            holder.addSubview(thumb)
            holder.addSubview(remove)
            NSLayoutConstraint.activate([
                thumb.leadingAnchor.constraint(equalTo: holder.leadingAnchor),
                thumb.trailingAnchor.constraint(equalTo: holder.trailingAnchor),
                thumb.topAnchor.constraint(equalTo: holder.topAnchor),
                thumb.bottomAnchor.constraint(equalTo: holder.bottomAnchor),
                remove.leadingAnchor.constraint(equalTo: thumb.leadingAnchor, constant: 2),
                remove.topAnchor.constraint(equalTo: thumb.topAnchor, constant: 2),
                remove.widthAnchor.constraint(equalToConstant: 16),
                remove.heightAnchor.constraint(equalToConstant: 16),
            ])
            strip.addArrangedSubview(holder)
        }
    }

    /// 发送 / 停止。
    private func refreshSendButton() {
        let key = "\(chat.phase)\u{1}\(canSend)"
        guard key != sendKey else { return }
        sendKey = key
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
        let key = chat.modes.map(\.id).joined(separator: "\u{1}") + "\u{2}" + (chat.currentMode ?? "")
        guard key != modeKey else { return }
        modeKey = key
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
        let key = chat.configs.map { item in
            switch item.kind {
            case .select(let cur, let opts): return "\(item.id)=\(cur)/\(opts.count)"
            case .toggle(let on): return "\(item.id)=\(on)"
            }
        }.joined(separator: "\u{1}")
        guard key != configKey else { return }
        configKey = key
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
            stripScroll.frame = NSRect(x: 12, y: y, width: b.width - 24, height: Self.thumbHeight)
            strip.frame = NSRect(origin: .zero, size: strip.fittingSize)
            y += Self.thumbHeight + 8
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
        updateMention()
    }

    func textViewDidChangeSelection(_ notification: Notification) { updateMention() }

    func textDidEndEditing(_ notification: Notification) { closeMention() }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { closeMention() }   // 子窗口挂在旧窗口上，得先摘掉
        super.viewWillMove(toWindow: newWindow)
    }

    // MARK: @ 提及

    /// 光标前正在输入 `@…` 就弹出 / 刷新候选，否则收起。组字中（输入法还没上屏）先不动。
    private func updateMention() {
        guard !textView.hasMarkedText() else { return }
        let sel = textView.selectedRange()
        guard textView.isEditable, let win = textView.window, sel.length == 0,
              let hit = AgentMentionMatch.activeQuery(in: textView.string as NSString, caret: sel.location) else {
            closeMention()
            return
        }
        if dismissedMentionAt == hit.range.location { return }
        dismissedMentionAt = nil
        if mentionCandidates == nil || mentionRange?.location != hit.range.location {
            mentionCandidates = chat.mentionProvider()
        }
        mentionRange = hit.range
        let list = AgentMentionMatch.rank(mentionCandidates ?? [], query: hit.query)
        guard !list.isEmpty else { mentionPopup.hide(); return }
        let anchor = textView.firstRect(forCharacterRange: NSRange(location: hit.range.location, length: 0),
                                        actualRange: nil)
        mentionPopup.show(list, anchor: anchor, parent: win)
    }

    private func closeMention() {
        mentionPopup.hide()
        mentionRange = nil
        mentionCandidates = nil
        dismissedMentionAt = nil
    }

    /// 候选开着时，输入框把这几个键交给候选：↑↓（及 ⌃P / ⌃N）选、回车 / Tab 确认、Esc 关掉。
    private func handleMentionKey(_ event: NSEvent) -> Bool {
        guard mentionPopup.isShown else { return false }
        let ctrl = event.modifierFlags.contains(.control)
        let ch = event.charactersIgnoringModifiers ?? ""
        switch event.keyCode {
        case 125: mentionPopup.move(1); return true
        case 126: mentionPopup.move(-1); return true
        case 36, 76, 48:
            if let m = mentionPopup.selectedItem { pickMention(m) }
            return true
        case 53:
            let at = mentionRange?.location
            closeMention()
            dismissedMentionAt = at
            return true
        default:
            if ctrl, ch == "n" { mentionPopup.move(1); return true }
            if ctrl, ch == "p" { mentionPopup.move(-1); return true }
            return false
        }
    }

    /// 把 `@查询` 换成 `@文件名 `（走 `insertText`，能撤销），记下这个文件，发送时附上。
    private func pickMention(_ m: AgentMention) {
        guard let r = mentionRange, NSMaxRange(r) <= (textView.string as NSString).length else { closeMention(); return }
        closeMention()
        window?.makeFirstResponder(textView)
        textView.insertText(m.token + " ", replacementRange: r)
        pickedMentions.append(m)
    }

    private var canSend: Bool {
        chat.phase == .idle && chat.sessionId != nil && !textView.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    @objc private func sendTapped() {
        if chat.phase == .running { chat.cancel(); return }
        guard canSend else { return }
        let text = textView.string
        chat.send(text, mentions: AgentMention.stillReferenced(pickedMentions, in: text))
        pickedMentions = []
        closeMention()
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
    /// 先给宿主看一眼（`@` 候选开着时要截 ↑↓ / 回车 / Tab / Esc）；返回 true = 已处理。组字中不问。
    var onKey: (NSEvent) -> Bool = { _ in false }

    override func keyDown(with event: NSEvent) {
        if !hasMarkedText(), onKey(event) { return }
        let isReturn = event.keyCode == 36 || event.keyCode == 76
        if isReturn, !hasMarkedText(), event.modifierFlags.intersection([.shift, .option]).isEmpty {
            onSend()
            return
        }
        super.keyDown(with: event)
    }
}
