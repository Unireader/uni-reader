import AppKit
import Combine

/// 咨询 AI（网页）面板的内容（AppKit 版，替代 SwiftUI `AIPanelView` 与 `AIInlineLayer` 的面板部分）：
///  · 内置形态：标题行（平台图标 + 平台名 + 「文档名 · 页码」，按钮：模式 / 更多 / 新对话）+ 网页；
///  · 窗口形态：绑定状态条（文档 · 页 · 状态标记 · 解绑）+ 页内查找条（⌘F）+ 网页（操作在窗口工具栏上）。
/// 网页归 `AIPageBox` 自己持有（`AIWebShell` 只是挂载点，视图重建不会出事，见 `AIWebView.swift` 顶部那段）。
@MainActor
final class ConsultPanelNSView: NSView {
    let host: AIHost
    private let inline: Bool
    private let panel = AIPanelModel.shared

    private let header = InlinePanelHeaderView()
    private let headerLine = NSBox()
    private let contextBar = NSVisualEffectView()
    private let contextLabel = NSTextField(labelWithString: "")
    private let contextMark = NSImageView()
    private let findBar = NSVisualEffectView()
    private let findField = NSSearchField()
    private let shell = AIWebShell()
    private let progress = NSProgressIndicator()
    private let placeholder = PlaceholderView()
    private var bag = Set<AnyCancellable>()
    private var boxBag = Set<AnyCancellable>()
    private weak var boundBox: AIPageBox?
    private var findOpen = false
    private var queued = false

    init(host: AIHost, inline: Bool) {
        self.host = host
        self.inline = inline
        super.init(frame: .zero)
        headerLine.boxType = .separator
        buildContextBar()
        buildFindBar()
        progress.style = .bar
        progress.isIndeterminate = false
        progress.minValue = 0
        progress.maxValue = 1
        progress.controlSize = .small
        for v in [header, headerLine, contextBar, findBar, shell, progress, placeholder] as [NSView] { addSubview(v) }
        header.isHidden = !inline
        headerLine.isHidden = !inline
        panel.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.queueRefresh() }
            .store(in: &bag)
        if !inline {
            NotificationCenter.default.publisher(for: .readerFind)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    guard let self, self.window?.isKeyWindow == true else { return }   // ⌘F 只有 key 窗口响应
                    self.findOpen = true
                    self.refresh()
                    self.window?.makeFirstResponder(self.findField)
                }
                .store(in: &bag)
        }
        refresh()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) 不支持") }

    override var isFlipped: Bool { true }

    private func buildContextBar() {
        contextBar.material = .headerView
        contextBar.blendingMode = .withinWindow
        let book = NSImageView(image: NSImage(systemSymbolName: "book", accessibilityDescription: nil) ?? NSImage())
        book.contentTintColor = .secondaryLabelColor
        contextLabel.font = .preferredFont(forTextStyle: .caption1)
        contextLabel.lineBreakMode = .byTruncatingMiddle
        contextLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let unbind = ClosureButton { [weak self] in self?.panel.unbind() }
        unbind.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: L("Unbind"))
        unbind.isBordered = false
        unbind.contentTintColor = .tertiaryLabelColor
        unbind.toolTip = L("Unbind")
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let row = NSStackView(views: [book, contextLabel, contextMark, spacer, unbind])
        row.spacing = 6
        row.edgeInsets = NSEdgeInsets(top: 5, left: 10, bottom: 5, right: 10)
        row.translatesAutoresizingMaskIntoConstraints = false
        contextBar.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: contextBar.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: contextBar.trailingAnchor),
            row.topAnchor.constraint(equalTo: contextBar.topAnchor),
            row.bottomAnchor.constraint(equalTo: contextBar.bottomAnchor),
        ])
    }

    private func buildFindBar() {
        findBar.material = .headerView
        findBar.blendingMode = .withinWindow
        findField.placeholderString = L("Find on Page")
        findField.target = self
        findField.action = #selector(findSubmitted)
        findField.sendsWholeSearchString = true
        let prev = ClosureButton { [weak self] in self?.runFind(backwards: true) }
        prev.image = NSImage(systemSymbolName: "chevron.up", accessibilityDescription: L("Previous Match"))
        prev.isBordered = false
        prev.toolTip = L("Previous Match")
        prev.keyEquivalent = "g"
        prev.keyEquivalentModifierMask = [.command, .shift]
        let next = ClosureButton { [weak self] in self?.runFind(backwards: false) }
        next.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: L("Next Match"))
        next.isBordered = false
        next.toolTip = L("Next Match")
        next.keyEquivalent = "g"
        next.keyEquivalentModifierMask = .command
        let close = ClosureButton { [weak self] in self?.findOpen = false; self?.refresh() }
        close.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: nil)
        close.isBordered = false
        close.contentTintColor = .tertiaryLabelColor
        close.keyEquivalent = "\u{1b}"
        let row = NSStackView(views: [findField, prev, next, close])
        row.spacing = 6
        row.edgeInsets = NSEdgeInsets(top: 4, left: 10, bottom: 4, right: 10)
        row.translatesAutoresizingMaskIntoConstraints = false
        findBar.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: findBar.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: findBar.trailingAnchor),
            row.topAnchor.constraint(equalTo: findBar.topAnchor),
            row.bottomAnchor.constraint(equalTo: findBar.bottomAnchor),
        ])
    }

    @objc private func findSubmitted() { runFind(backwards: NSEvent.modifierFlags.contains(.shift)) }

    private func runFind(backwards: Bool) {
        let q = findField.stringValue
        guard !q.isEmpty, let box = panel.current else { return }
        let js = "return window.find(q, false, back, true, false, true, false);"
        Task { await box.callJS(js, arguments: ["q": q, "back": backwards]) }
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

    /// 本面板现在该挂的那份网页（没有就建：内置面板只在展开时建、窗口形态出现即建）。
    func ensurePage() { _ = panel.page(for: host) }

    func refresh() {
        let box = panel.existingPage(for: host)
        // 窗口形态、而此刻是内置模式：网页归内置面板渲染（同一份页面不能两处挂），这里画个占位
        let yieldToInline = !inline && panel.mode == .inline
        if inline {
            let p = panel.currentProvider
            var buttons: [InlinePanelHeaderView.Button] = []
            if let modes = p?.modes, !modes.isEmpty {
                buttons.append(.init(symbol: "slider.horizontal.3", tip: L("Mode for new chats"), menu: { [weak self] in
                    self?.modeMenu(modes) ?? NSMenu()
                }))
            }
            buttons.append(.init(symbol: "ellipsis", tip: L("More"), menu: {
                let m = NSMenu()
                m.addItem(ClosureMenuItem(L("Open as Separate Window")) {
                    AIPanelModel.shared.setMode(.window)
                    AIPanelWindowController.show()
                })
                return m
            }))
            buttons.append(.init(symbol: "square.and.pencil", tip: L("New Chat"), action: { [weak self] in self?.panel.goHome() }))
            header.configure(icon: p?.icon ?? "bubble.left.and.text.bubble.right", title: p?.name ?? L("AI"),
                             subtitle: panel.bindContext.map { "\($0.docTitle) · \(String(format: L("p.%d"), $0.page + 1))" },
                             buttons: buttons)
        } else {
            refreshContextBar()
        }
        findBar.isHidden = inline || !findOpen
        if yieldToInline {
            shell.isHidden = true
            placeholder.isHidden = false
            placeholder.set(symbol: "sidebar.trailing", title: L("Shown Inside the Window"),
                            detail: L("The AI panel is docked inside the reading window."))
        } else if let box {
            placeholder.isHidden = true
            shell.isHidden = false
            if shell.box !== box { shell.box = box }
            bind(box)
        } else {
            shell.isHidden = true
            placeholder.isHidden = false
            placeholder.set(symbol: "bubble.left.and.bubble.right", title: L("No AI Platform"),
                            detail: L("Pick a platform from the toolbar to get started."))
        }
        progress.isHidden = shell.isHidden || !(box?.isLoading ?? false)
        progress.doubleValue = box?.progress ?? 0
        needsLayout = true
    }

    private func modeMenu(_ modes: [AIMode]) -> NSMenu {
        let m = NSMenu()
        let auto = ClosureMenuItem(L("Follow Content")) { AIPanelModel.shared.setChatMode("auto") }
        auto.state = panel.chatMode == "auto" ? .on : .off
        m.addItem(auto)
        m.addItem(.separator())
        for mode in modes {
            let i = ClosureMenuItem(mode.name) { AIPanelModel.shared.setChatMode(mode.id) }
            i.state = panel.chatMode == mode.id ? .on : .off
            m.addItem(i)
        }
        return m
    }

    /// 窗口形态的绑定状态条：文档 · 页 · 状态（刚加到笔记的一闪 / 会话可能已失效 / 已绑定 / 等第一条消息）。
    private func refreshContextBar() {
        guard let ctx = panel.bindContext else { contextBar.isHidden = true; return }
        contextBar.isHidden = false
        contextLabel.stringValue = "\(ctx.docTitle)  \(String(format: L("p.%d"), ctx.page + 1))"
        if let f = panel.flash {
            contextMark.image = NSImage(systemSymbolName: "checkmark.circle", accessibilityDescription: f)
            contextMark.contentTintColor = .secondaryLabelColor
            contextMark.toolTip = f
        } else if let t = panel.boundThread {
            let suspect = t.state == .suspect
            contextMark.image = NSImage(systemSymbolName: suspect ? "exclamationmark.triangle.fill" : "link", accessibilityDescription: nil)
            contextMark.contentTintColor = suspect ? .systemOrange : .secondaryLabelColor
            contextMark.toolTip = suspect ? L("This conversation may no longer exist.") : L("Bound to this conversation")
        } else {
            contextMark.image = nil
            contextMark.toolTip = L("waiting for first message")
        }
    }

    /// 页面的网址 / 标题 / 加载状态回传给模型（它据此落库绑定、判断会话失效）。
    private func bind(_ box: AIPageBox) {
        guard boundBox !== box else { return }
        boundBox = box
        boxBag.removeAll()
        let host = self.host
        box.$url.dropFirst().receive(on: DispatchQueue.main)
            .sink { _ in AIPanelModel.shared.syncFromPage(host) }.store(in: &boxBag)
        box.$title.dropFirst().receive(on: DispatchQueue.main)
            .sink { _ in AIPanelModel.shared.syncFromPage(host) }.store(in: &boxBag)
        box.$isLoading.dropFirst().removeDuplicates().receive(on: DispatchQueue.main)
            .sink { [weak self] loading in
                if !loading { AIPanelModel.shared.noteLoadSettled(host) }   // 停下来才谈得上「有没有被重定向」
                self?.queueRefresh()
            }.store(in: &boxBag)
        box.$progress.receive(on: DispatchQueue.main)
            .sink { [weak self] p in self?.progress.doubleValue = p }.store(in: &boxBag)
    }

    // MARK: 布局

    override func layout() {
        super.layout()
        let b = bounds
        var y: CGFloat = 0
        if inline {
            header.frame = NSRect(x: 0, y: 0, width: b.width, height: InlinePanelHeaderView.height)
            headerLine.frame = NSRect(x: 0, y: InlinePanelHeaderView.height, width: b.width, height: 1)
            y = InlinePanelHeaderView.height + 1
        } else {
            if !contextBar.isHidden {
                let h = contextBar.fittingSize.height
                contextBar.frame = NSRect(x: 0, y: y, width: b.width, height: h)
                y += h
            }
            if !findBar.isHidden {
                let h = findBar.fittingSize.height
                findBar.frame = NSRect(x: 0, y: y, width: b.width, height: h)
                y += h
            }
        }
        shell.frame = NSRect(x: 0, y: y, width: b.width, height: max(0, b.height - y))
        progress.frame = NSRect(x: 0, y: y, width: b.width, height: 4)
        placeholder.frame = shell.frame
    }
}
