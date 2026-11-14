import AppKit
import Combine

/// Inspector「Agent」页的外壳：顶上一条标签（一段并行对话一格 + 新建 / 关闭），下面是眼前这段对话的 `AgentChatNSView`。
///
/// 并行 = 同一扇窗口里同时开几段对话，各自连一个 Agent（可以是不同的 Agent），后台的那几段照常收流式回复、
/// 等批准——对话本身住在 `AgentPanelModel`，这里只是换着看。
///
/// 🔴 **看过的对话视图留着、藏起来，切回去不重建**（2026-11-10 用户：「多 tab 切换会重新绘制布局导致有一些卡顿」）：
/// 原来每切一次就把眼前的 `AgentChatNSView` 扔掉、给另一段新建一个，整段对话记录的条目视图和 Markdown 正文
/// 都要重新建、重新排版。现在每段对话一个视图（第一次切到时才建），换着显示；藏着的那几个不摆位、不刷新
/// （`AgentChatNSView.layout` / `refresh` 自己看 `isHiddenOrHasHiddenAncestor`），切回来补一次，所以后台的对话照旧不占排版。
/// 标签上的小图标：回答中 / 等你批准 / 出错；一眼看出哪段在等你。
/// 🔴 系统控件（`NSSegmentedControl` + 按钮），不自绘。分段控件的格子里放不下关闭按钮，所以关闭 / 重命名放在
/// 标签的右键菜单里（2026-11-14 用户要「关闭按钮放在 tab 上」，选了右键菜单这条）；顶上的「✕」照旧关眼前这段。
@MainActor
final class AgentChatsView: NSView {
    private let windowID: UUID
    let cwd: URL
    var workspaceName: String { didSet { for v in chatViews.values { v.workspaceName = workspaceName } } }
    /// 眼前这段对话的视图。
    private(set) var chatView: AgentChatNSView?
    /// 每段对话一个视图（按对话 id；第一次切到才建，对话关了才扔）。
    private var chatViews: [UUID: AgentChatNSView] = [:]

    private let strip = NSVisualEffectView()
    private let stripLine = NSBox()
    private let segments = ChatSegments()
    private let addButton = NSButton()
    private let closeButton = NSButton()
    private var bag = Set<AnyCancellable>()
    private var chatBag = Set<AnyCancellable>()
    private var stripKey = ""
    private var refreshQueued = false

    private static let stripHeight: CGFloat = 34

    init(windowID: UUID, cwd: URL, workspaceName: String) {
        self.windowID = windowID
        self.cwd = cwd
        self.workspaceName = workspaceName
        super.init(frame: .zero)
        strip.material = .headerView
        strip.blendingMode = .withinWindow
        stripLine.boxType = .separator
        segments.segmentStyle = .automatic
        segments.trackingMode = .selectOne
        segments.target = self
        segments.action = #selector(segmentPicked)
        segments.menuProvider = { [weak self] i in self?.tabMenu(at: i) }
        configure(addButton, symbol: "plus", tip: L("New Parallel Chat"), action: #selector(addPressed))
        configure(closeButton, symbol: "xmark", tip: L("Close This Chat"), action: #selector(closePressed))
        for v in [strip, stripLine, segments, addButton, closeButton] as [NSView] { addSubview(v) }

        AgentPanelModel.shared.$chatListRevision
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.listChanged() }
            .store(in: &bag)
        listChanged()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) 不支持") }

    private func configure(_ b: NSButton, symbol: String, tip: String, action: Selector) {
        b.bezelStyle = .toolbar
        b.isBordered = true
        b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
        b.contentTintColor = .labelColor
        b.imagePosition = .imageOnly
        b.toolTip = tip
        b.target = self
        b.action = action
    }

    private var chats: [AgentChat] { AgentPanelModel.shared.chats(for: windowID, cwd: cwd) }

    // MARK: - 刷新

    /// 对话列表或选中的变了：换眼前的视图，重画标签条，重新订阅各段对话的状态。
    private func listChanged() {
        let list = chats
        let active = AgentPanelModel.shared.chat(for: windowID, cwd: cwd)
        // 关掉的对话：视图跟着扔
        let alive = Set(list.map(\.id))
        for (id, v) in chatViews where !alive.contains(id) {
            v.removeFromSuperview()
            chatViews.removeValue(forKey: id)
        }
        if chatView?.chat !== active {
            let v: AgentChatNSView
            if let kept = chatViews[active.id], kept.chat === active {
                v = kept
            } else {
                chatViews[active.id]?.removeFromSuperview()
                v = AgentChatNSView(chat: active, workspaceName: workspaceName, showsHeader: true)
                v.isHidden = true
                chatViews[active.id] = v
                addSubview(v)
            }
            // 先按眼前的尺寸摆好再露出来：藏着的时候面板可能改过大小
            v.frame = chatFrame
            chatView?.isHidden = true
            chatView = v
            v.isHidden = false
            needsLayout = true
        }
        chatBag.removeAll()
        for c in list {
            c.objectWillChange
                .receive(on: RunLoop.main)
                .sink { [weak self] _ in self?.queueStripRefresh() }
                .store(in: &chatBag)
        }
        refreshStrip()
    }

    /// 流式回复每个碎片都会触发：合并到下一拍，标签没变就什么都不做（`refreshStrip` 比的是标签内容）。
    private func queueStripRefresh() {
        guard !refreshQueued else { return }
        refreshQueued = true
        DispatchQueue.main.async { [weak self] in
            self?.refreshQueued = false
            self?.refreshStrip()
        }
    }

    private struct Tab { var label: String; var symbol: String?; var tip: String }

    private func status(_ c: AgentChat) -> (symbol: String?, tip: String) {
        if !c.permissions.isEmpty { return ("exclamationmark.bubble", L("Waiting for your approval")) }
        if case .failed = c.phase { return ("exclamationmark.triangle", L("Failed")) }
        if c.isBusy { return ("ellipsis.bubble", L("Working")) }
        return (nil, "")
    }

    private func tabs() -> [Tab] {
        let list = chats
        var seen: [String: Int] = [:]
        return list.map { c in
            let base = Self.shortTitle(c)
            seen[base, default: 0] += 1
            let s = status(c)
            let label = seen[base]! > 1 ? "\(base) \(seen[base]!)" : base
            return Tab(label: label, symbol: s.symbol, tip: [c.agentName, s.tip].filter { !$0.isEmpty }.joined(separator: " · "))
        }
    }

    private static func shortTitle(_ c: AgentChat) -> String {
        let t = (c.displayTitle ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return c.agentName }
        return t.count > 10 ? String(t.prefix(10)) + "…" : t
    }

    private func refreshStrip() {
        let list = chats
        let t = tabs()
        let activeID = AgentPanelModel.shared.activeChatID(for: windowID)
        let key = t.map { "\($0.label)|\($0.symbol ?? "")" }.joined(separator: "\u{1}") + "#\(activeID?.uuidString ?? "")"
        guard key != stripKey else { return }
        let countChanged = segments.segmentCount != t.count
        stripKey = key
        segments.segmentCount = t.count
        for (i, tab) in t.enumerated() {
            segments.setLabel(tab.label, forSegment: i)
            segments.setImage(tab.symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }, forSegment: i)
            segments.setToolTip(tab.tip, forSegment: i)
            segments.setWidth(0, forSegment: i)
        }
        if let activeID, let i = list.firstIndex(where: { $0.id == activeID }) { segments.selectedSegment = i }
        closeButton.isHidden = list.count < 2
        addButton.isEnabled = list.count < AgentPanelModel.maxParallel
        if countChanged { needsLayout = true }
    }

    // MARK: - 操作

    @objc private func segmentPicked() {
        let list = chats
        let i = segments.selectedSegment
        guard list.indices.contains(i) else { return }
        AgentPanelModel.shared.selectChat(list[i].id, in: windowID)
    }

    @objc private func closePressed() {
        guard let id = AgentPanelModel.shared.activeChatID(for: windowID) else { return }
        AgentPanelModel.shared.closeChat(id, in: windowID)
    }

    /// 某一格标签的右键菜单：重命名… / 关闭（只剩一段时关不了，同「✕」）。
    private func tabMenu(at i: Int) -> NSMenu? {
        let list = chats
        guard list.indices.contains(i) else { return nil }
        let chat = list[i]
        let m = NSMenu()
        m.addItem(ClosureMenuItem(L("Rename Chat…")) { [weak self] in self?.promptRename(chat) })
        let close = ClosureMenuItem(L("Close Chat")) { [weak self] in
            guard let self else { return }
            AgentPanelModel.shared.closeChat(chat.id, in: self.windowID)
        }
        if list.count < 2 {
            close.isEnabled = false
            m.autoenablesItems = false
        }
        m.addItem(close)
        return m
    }

    /// 重命名一段对话：只改标签与标题行显示的名字；清空 = 回到 Agent 给的标题。
    private func promptRename(_ chat: AgentChat) {
        guard let win = window else { return }
        let a = NSAlert()
        a.messageText = L("Rename Chat")
        a.informativeText = L("Leave it empty to use the title the agent gives.")
        let ok = a.addButton(withTitle: L("Rename"))
        a.addButton(withTitle: L("Cancel"))
        let field = NSTextField(string: chat.displayTitle ?? "")
        field.frame = NSRect(x: 0, y: 0, width: 240, height: 24)
        field.placeholderString = chat.title ?? chat.agentName
        // 回车 = 按「重命名」（不接这一下回车会被输入框吃掉）
        field.target = ok
        field.action = #selector(NSButton.performClick(_:))
        a.accessoryView = field
        a.window.initialFirstResponder = field
        a.beginSheetModal(for: win) { resp in
            guard resp == .alertFirstButtonReturn else { return }
            let t = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            chat.customName = t.isEmpty ? nil : t
        }
        DispatchQueue.main.async { field.currentEditor()?.selectAll(nil) }
    }

    /// 新建并行对话：弹出可选的 Agent（预设 + 设置里自填的那个）。
    @objc private func addPressed() {
        let menu = NSMenu()
        for l in Self.choices() {
            let it = NSMenuItem(title: l.displayName, action: #selector(menuPicked(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = LaunchBox(l)
            menu.addItem(it)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: addButton.bounds.height + 4), in: addButton)
    }

    private final class LaunchBox: NSObject {
        let launch: AgentConfig.Launch
        init(_ l: AgentConfig.Launch) { launch = l }
    }

    @objc private func menuPicked(_ sender: NSMenuItem) {
        guard let box = sender.representedObject as? LaunchBox else { return }
        if AgentPanelModel.shared.addChat(in: windowID, cwd: cwd, launch: box.launch) == nil { NSSound.beep() }
    }

    /// 可选的 Agent：三个预设；设置里自填的命令不在预设里时也列出来。显示名取命令名（Kimi / Qwen / Claude-agent-acp）。
    private static func choices() -> [AgentConfig.Launch] {
        var out = AgentConfig.Preset.allCases.map {
            AgentConfig.Launch(command: $0.command, arguments: $0.arguments.split(whereSeparator: \.isWhitespace).map(String.init))
        }
        let cur = AgentConfig.current
        if !out.contains(cur) { out.insert(cur, at: 0) }
        return out
    }

    // MARK: - 排版

    override func layout() {
        super.layout()
        let b = bounds
        let h = Self.stripHeight
        strip.frame = NSRect(x: 0, y: 0, width: b.width, height: h)
        stripLine.frame = NSRect(x: 0, y: h, width: b.width, height: 1)
        let pad: CGFloat = 10
        var right = b.width - pad
        for btn in [addButton, closeButton] where !btn.isHidden {
            btn.sizeToFit()
            let w = max(28, btn.frame.width)
            btn.frame = NSRect(x: right - w, y: (h - 24) / 2, width: w, height: 24)
            right = btn.frame.minX - 6
        }
        let sh = segments.intrinsicContentSize.height
        segments.frame = NSRect(x: pad, y: (h - sh) / 2, width: max(60, right - pad - 2), height: sh)
        segments.segmentDistribution = .fillEqually
        chatView?.frame = chatFrame
    }

    /// 对话视图占的那一块（标签条下面）。
    private var chatFrame: NSRect {
        let h = Self.stripHeight
        return NSRect(x: 0, y: h + 1, width: bounds.width, height: max(0, bounds.height - h - 1))
    }

    override var isFlipped: Bool { true }
}

/// 标签条用的分段控件：右键哪一格就给哪一格的菜单（系统 `NSSegmentedControl` 本身不区分点在哪一格）。
/// 各格等宽（`segmentDistribution = .fillEqually`），按横坐标折算格号。
@MainActor
final class ChatSegments: NSSegmentedControl {
    var menuProvider: ((Int) -> NSMenu?)?

    override func menu(for event: NSEvent) -> NSMenu? {
        guard segmentCount > 0, bounds.width > 0 else { return nil }
        let x = convert(event.locationInWindow, from: nil).x
        let i = min(segmentCount - 1, max(0, Int(x / (bounds.width / CGFloat(segmentCount)))))
        return menuProvider?(i)
    }
}
