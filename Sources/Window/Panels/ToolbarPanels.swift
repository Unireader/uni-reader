import AppKit
import Combine

// 阅读窗口工具栏那几枚按钮弹出的面板（AppKit 版，替代 SwiftUI `ToolbarPopovers` / `ServerPanel`）：
// 目录、文字识别（OCR）、平板手写服务。由 `ReaderWindowController` 用 `NSPopover` 锚到工具栏按钮上弹。
// 面板内容会变高变矮（开关、连接列表），尺寸经 `preferredContentSize` 交给弹出框跟着变。

/// 纵向排版的小面板基类：一列控件，定宽，高度按内容；内容一变就重算 `preferredContentSize`。
class StackPanelController: NSViewController {
    let stack = NSStackView()
    let width: CGFloat
    let inset: CGFloat

    init(width: CGFloat, inset: CGFloat = 14) {
        self.width = width
        self.inset = inset
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) 不支持") }

    override func loadView() {
        let v = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 100))
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: inset, left: inset, bottom: inset, right: inset)
        stack.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(stack)
        // 底边只给次高优先级：当 sheet 用时窗口按内容定高；当弹出框用时尺寸归弹出框，不和它顶
        let bottom = stack.bottomAnchor.constraint(equalTo: v.bottomAnchor)
        bottom.priority = .defaultHigh
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: v.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: v.trailingAnchor),
            stack.topAnchor.constraint(equalTo: v.topAnchor),
            stack.widthAnchor.constraint(equalToConstant: width),
            bottom,
        ])
        view = v
    }

    /// 内容变了：按新内容算高度（弹出框会跟着变）。
    func resize() {
        view.layoutSubtreeIfNeeded()
        let h = stack.fittingSize.height
        let s = NSSize(width: width, height: h)
        if preferredContentSize != s { preferredContentSize = s }
        // 当 sheet 用时窗口跟着内容变高变矮（弹出框自己会跟 `preferredContentSize`）
        if let w = view.window, w.sheetParent != nil, w.contentLayoutRect.size != s { w.setContentSize(s) }
    }

    // 控件小工具

    func headline(_ s: String) -> NSTextField {
        let t = NSTextField(labelWithString: s)
        t.font = .preferredFont(forTextStyle: .headline)
        return t
    }

    func caption(_ s: String, color: NSColor = .secondaryLabelColor) -> NSTextField {
        let t = NSTextField(wrappingLabelWithString: s)
        t.font = .preferredFont(forTextStyle: .caption1)
        t.textColor = color
        t.preferredMaxLayoutWidth = width - inset * 2
        t.isSelectable = false
        return t
    }

    func separator() -> NSBox {
        let b = NSBox()
        b.boxType = .separator
        b.translatesAutoresizingMaskIntoConstraints = false
        b.widthAnchor.constraint(equalToConstant: width - inset * 2).isActive = true
        return b
    }

    /// 横排一行（左右撑满）。
    func row(_ views: [NSView], spacing: CGFloat = 8) -> NSStackView {
        let r = NSStackView(views: views)
        r.orientation = .horizontal
        r.spacing = spacing
        r.translatesAutoresizingMaskIntoConstraints = false
        r.widthAnchor.constraint(equalToConstant: width - inset * 2).isActive = true
        return r
    }

    func spacer() -> NSView {
        let v = NSView()
        v.setContentHuggingPriority(.init(1), for: .horizontal)
        return v
    }
}

// MARK: - 目录（一次性：点条目跳转并关闭；书签一并列出，改名 / 删除仍走 Inspector）

final class TOCPanelController: NSViewController {
    let tabs: TabsModel
    var onPicked: () -> Void = {}
    private let toc = TOCOutlineView(frame: NSRect(x: 0, y: 40, width: 320, height: 420))

    init(tabs: TabsModel) {
        self.tabs = tabs
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) 不支持") }

    override func loadView() {
        let root = FlippedView(frame: NSRect(x: 0, y: 0, width: 320, height: 460))
        let title = NSTextField(labelWithString: L("Contents"))
        title.font = .preferredFont(forTextStyle: .headline)
        title.frame = NSRect(x: 12, y: 10, width: 296, height: 20)
        toc.autoresizingMask = [.width, .height]
        let s = tabs.active.session
        toc.update(entries: s.toc, bookmarks: s.bookmarks, currentPage: s.currentPageIndex)
        toc.onSelect = { [weak self] e in
            guard let self, let page = e.pageIndex else { return }   // 坏书签：跳不过去
            self.tabs.active.session.jump(page: page, frac: e.frac, kind: .toc, label: e.label)
            self.onPicked()
        }
        toc.onSelectBookmark = { [weak self] b in
            guard let self else { return }
            self.tabs.active.session.jump(page: b.page, frac: b.frac, kind: .toc, label: b.title)
            self.onPicked()
        }
        root.addSubview(title)
        root.addSubview(toc)
        view = root
        preferredContentSize = root.frame.size
    }
}

// MARK: - 文字识别（OCR）

/// 开关「用 OCR 文本」+ 进度 + 手动「识别全部页」+ 水印块 / 调试上色；未配置 OCR 时引导去设置。
final class OCRPanelController: StackPanelController {
    let tabs: TabsModel
    private var bag = Set<AnyCancellable>()
    private var sessionBag = Set<AnyCancellable>()
    private var queued = false

    private let setupHint = NSStackView()
    private let main = NSStackView()
    private let useOCR = NSButton(checkboxWithTitle: L("Use OCR text for this document"), target: nil, action: nil)
    private var status: NSTextField!
    private let spinner = NSProgressIndicator()
    private let recognizeAll = NSButton(title: L("Recognize all pages"), target: nil, action: nil)
    private let watermark = NSButton(checkboxWithTitle: L("Ignore tiled watermark blocks"), target: nil, action: nil)
    private let debugBlocks = NSButton(checkboxWithTitle: L("Show recognition blocks (debug)"), target: nil, action: nil)
    private let grouping = NSSegmentedControl(labels: [L("Per block"), L("Selectable groups")], trackingMode: .selectOne,
                                              target: nil, action: nil)
    private var errorLabel: NSTextField!

    init(tabs: TabsModel) {
        self.tabs = tabs
        super.init(width: 280)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) 不支持") }

    private var session: DocSession { tabs.active.session }

    override func viewDidLoad() {
        super.viewDidLoad()
        stack.addArrangedSubview(headline(L("Text Recognition (OCR)")))

        setupHint.orientation = .vertical
        setupHint.alignment = .leading
        setupHint.spacing = 10
        setupHint.addArrangedSubview(caption(L("Enable API OCR in Settings (⌘,) and paste your key first.")))
        let open = NSButton(title: L("Open Settings…"), target: self, action: #selector(openSettings))
        setupHint.addArrangedSubview(open)
        stack.addArrangedSubview(setupHint)

        main.orientation = .vertical
        main.alignment = .leading
        main.spacing = 10
        useOCR.target = self
        useOCR.action = #selector(toggleUse)
        status = caption("")
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isIndeterminate = true
        recognizeAll.target = self
        recognizeAll.action = #selector(runAll)
        watermark.target = self
        watermark.action = #selector(toggleWatermark)
        debugBlocks.target = self
        debugBlocks.action = #selector(toggleDebug)
        grouping.target = self
        grouping.action = #selector(groupingChanged)
        errorLabel = caption("", color: .systemRed)
        for v in [useOCR, status, spinner, recognizeAll, separator(), watermark,
                  caption(L("Scanned books often carry a tiled diagonal watermark; OCR turns it into big blocks that break text selection. Detected by geometry and cross-page repetition, not by wording.")),
                  separator(), debugBlocks,
                  caption(L("Colors each recognized text block to inspect layout/selection accuracy; ignored watermark blocks show as grey dashed outlines.")),
                  grouping, errorLabel] as [NSView] {
            main.addArrangedSubview(v)
        }
        stack.addArrangedSubview(main)

        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.queueRefresh() }.store(in: &bag)
        tabs.objectWillChange.receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.bindSession() }.store(in: &bag)
        bindSession()
        refresh()   // 弹出之前就要量好尺寸
    }

    private weak var bound: DocSession?
    private func bindSession() {
        let s = session
        if bound !== s {
            bound = s
            sessionBag.removeAll()
            s.objectWillChange.receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.queueRefresh() }.store(in: &sessionBag)
        }
        queueRefresh()
    }

    private func queueRefresh() {
        guard !queued else { return }
        queued = true
        DispatchQueue.main.async { [weak self] in
            self?.queued = false
            self?.refresh()
        }
    }

    private func refresh() {
        let s = session
        let ready = (UserDefaults.standard.string(forKey: "ocrEngine") ?? "off") == "paddle"
        setupHint.isHidden = ready
        main.isHidden = !ready
        if ready {
            useOCR.state = s.ocrEnabled ? .on : .off
            let done = s.ocrDoneCount, total = s.ocrTotalPages
            if s.ocrRunning {
                status.stringValue = String(format: L("Recognizing… %d/%d pages, %d queued"), done, total, s.ocrPendingCount)
            } else if done == 0 {
                status.stringValue = L("Not recognized yet.")
            } else {
                status.stringValue = String(format: L("%d of %d pages recognized"), done, total)
            }
            spinner.isHidden = !s.ocrRunning
            if s.ocrRunning { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
            recognizeAll.isEnabled = s.pdf != nil
            watermark.state = s.ocrIgnoreWatermark ? .on : .off
            debugBlocks.state = s.showOCRBlocks ? .on : .off
            grouping.isHidden = !s.showOCRBlocks
            grouping.selectedSegment = s.ocrBlockGrouped ? 1 : 0
            errorLabel.stringValue = s.ocrLastError ?? ""
            errorLabel.isHidden = s.ocrLastError == nil
        }
        resize()
    }

    @objc private func openSettings() { SettingsWindowController.show() }
    @objc private func toggleUse() { session.setOCREnabled(useOCR.state == .on) }
    @objc private func runAll() { session.ocrAllPages() }
    @objc private func toggleWatermark() { session.ocrIgnoreWatermark = watermark.state == .on }
    @objc private func toggleDebug() { session.showOCRBlocks = debugBlocks.state == .on }
    @objc private func groupingChanged() { session.ocrBlockGrouped = grouping.selectedSegment == 1 }
}

// MARK: - 平板手写服务

/// 启停、二维码配对、地址（可复制）、换配对码、已连设备（逐个断开）、延迟 / 入站速率 / 最近消息。
final class ServerPanelController: StackPanelController {
    let server: LANServer
    private var bag = Set<AnyCancellable>()
    private var queued = false

    private let startStop = NSButton(title: "", target: nil, action: nil)
    private let dot = NSView()
    private let stateLabel = NSTextField(labelWithString: "")
    private let running = NSStackView()
    private let qr = NSImageView()
    private let url = NSTextField(wrappingLabelWithString: "")
    private let copy = NSButton()
    private let connected = NSTextField(labelWithString: "")
    private let latency = NSTextField(labelWithString: "")
    private let clients = NSStackView()
    private let inbound = NSTextField(labelWithString: "")
    private var lastTitle: NSTextField!
    private let lastBody = NSTextField(wrappingLabelWithString: "")
    private var shownURL = ""
    private var shownClients: [ClientInfo] = []

    init(server: LANServer) {
        self.server = server
        super.init(width: 300, inset: 18)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) 不支持") }

    override func viewDidLoad() {
        super.viewDidLoad()
        stack.spacing = 14
        startStop.bezelStyle = .push
        startStop.target = self
        startStop.action = #selector(toggleServer)
        stack.addArrangedSubview(row([headline(L("Tablet Handwriting")), spacer(), startStop]))

        dot.wantsLayer = true
        dot.layer?.cornerRadius = 5
        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.widthAnchor.constraint(equalToConstant: 10).isActive = true
        dot.heightAnchor.constraint(equalToConstant: 10).isActive = true
        stateLabel.textColor = .secondaryLabelColor
        stack.addArrangedSubview(row([dot, stateLabel, spacer()]))

        running.orientation = .vertical
        running.alignment = .centerX
        running.spacing = 10
        qr.imageScaling = .scaleProportionallyUpOrDown
        qr.wantsLayer = true
        qr.layer?.backgroundColor = NSColor.white.cgColor
        qr.layer?.cornerRadius = 8
        qr.layer?.masksToBounds = true
        qr.layer?.magnificationFilter = .nearest
        qr.translatesAutoresizingMaskIntoConstraints = false
        qr.widthAnchor.constraint(equalToConstant: 180).isActive = true
        qr.heightAnchor.constraint(equalToConstant: 180).isActive = true
        running.addArrangedSubview(qr)
        let hint = caption(L("Open this URL in Firefox on your tablet:"))
        running.addArrangedSubview(row([hint, spacer()]))
        url.font = .monospacedSystemFont(ofSize: NSFont.preferredFont(forTextStyle: .footnote).pointSize, weight: .regular)
        url.isSelectable = true
        url.preferredMaxLayoutWidth = width - inset * 2 - 30
        copy.isBordered = false
        copy.imagePosition = .imageOnly
        copy.toolTip = L("Copy URL")
        copy.target = self
        copy.action = #selector(copyURL)
        setCopyIcon(copied: false)
        let urlRow = row([url, spacer(), copy], spacing: 6)
        urlRow.alignment = .top
        running.addArrangedSubview(urlRow)
        let reset = NSButton(title: L("Reset pairing code"), target: self, action: #selector(resetToken))
        reset.isBordered = false
        reset.font = .preferredFont(forTextStyle: .caption1)
        reset.contentTintColor = .controlAccentColor
        reset.toolTip = L("Old code stops working immediately; paired tablets must scan again.")
        running.addArrangedSubview(row([reset, spacer()]))
        running.addArrangedSubview(separator())
        let foot = NSFont.preferredFont(forTextStyle: .footnote)
        connected.font = foot
        latency.font = foot
        latency.textColor = .secondaryLabelColor
        running.addArrangedSubview(row([connected, spacer(), latency]))
        clients.orientation = .vertical
        clients.spacing = 4
        running.addArrangedSubview(clients)
        inbound.font = foot
        inbound.textColor = .secondaryLabelColor
        running.addArrangedSubview(row([inbound, spacer()]))
        lastTitle = caption(L("Last message:"))
        running.addArrangedSubview(row([lastTitle, spacer()]))
        lastBody.font = .monospacedSystemFont(ofSize: NSFont.preferredFont(forTextStyle: .caption1).pointSize, weight: .regular)
        lastBody.maximumNumberOfLines = 3
        lastBody.lineBreakMode = .byTruncatingTail
        lastBody.preferredMaxLayoutWidth = width - inset * 2
        running.addArrangedSubview(row([lastBody, spacer()]))
        stack.addArrangedSubview(running)

        server.objectWillChange.receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.queueRefresh() }.store(in: &bag)
        refresh()
    }

    private func queueRefresh() {
        guard !queued else { return }
        queued = true
        DispatchQueue.main.async { [weak self] in
            self?.queued = false
            self?.refresh()
        }
    }

    private func refresh() {
        let on = server.isRunning
        startStop.title = on ? L("Stop") : L("Start")
        dot.layer?.backgroundColor = (on ? NSColor.systemGreen : NSColor.secondaryLabelColor).cgColor
        stateLabel.stringValue = on ? L("Server running") : L("Server stopped")
        running.isHidden = !on
        if on {
            if shownURL != server.pageURL {
                shownURL = server.pageURL
                url.stringValue = shownURL
                qr.image = Pairing.qrImage(from: shownURL)
            }
            connected.stringValue = String(format: L("Connected tablets: %d"), server.clientCount)
            latency.stringValue = server.latencyMS.map { String(format: L("Latency: %d ms"), $0) } ?? ""
            if server.clientList != shownClients {
                shownClients = server.clientList
                rebuildClients()
            }
            inbound.stringValue = String(format: L("Inbound: %d msg/s"), server.inboundRate)
            lastTitle.isHidden = server.lastInbound.isEmpty
            lastBody.superview?.isHidden = server.lastInbound.isEmpty
            lastBody.stringValue = server.lastInbound
        }
        resize()
    }

    /// 已连设备：每台一行（地址 + 「断开」），浅底圆角。
    private func rebuildClients() {
        for v in clients.arrangedSubviews { v.removeFromSuperview() }
        clients.isHidden = shownClients.isEmpty
        for c in shownClients {
            let icon = NSImageView(image: NSImage(systemSymbolName: "ipad", accessibilityDescription: nil) ?? NSImage())
            icon.contentTintColor = .secondaryLabelColor
            let addr = NSTextField(labelWithString: c.address)
            addr.font = .monospacedSystemFont(ofSize: NSFont.preferredFont(forTextStyle: .caption1).pointSize, weight: .regular)
            addr.lineBreakMode = .byTruncatingMiddle
            addr.setContentCompressionResistancePriority(.init(1), for: .horizontal)
            let kick = NSButton(title: L("Disconnect"), target: nil, action: nil)
            kick.isBordered = false
            kick.font = .preferredFont(forTextStyle: .caption1)
            kick.contentTintColor = .controlAccentColor
            let id = c.id
            let acts = ButtonActions()
            acts.bind(kick) { [weak self] in self?.server.kick(id) }
            objc_setAssociatedObject(kick, &ButtonActions.key, acts, .OBJC_ASSOCIATION_RETAIN)
            let r = row([icon, addr, spacer(), kick], spacing: 6)
            r.edgeInsets = NSEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)
            r.wantsLayer = true
            r.layer?.cornerRadius = 6
            r.layer?.backgroundColor = NSColor.quaternaryLabelColor.withAlphaComponent(0.25).cgColor
            clients.addArrangedSubview(r)
        }
    }

    private func setCopyIcon(copied: Bool) {
        copy.image = NSImage(systemSymbolName: copied ? "checkmark" : "doc.on.doc", accessibilityDescription: L("Copy URL"))
        copy.contentTintColor = copied ? .systemGreen : .secondaryLabelColor
    }

    @objc private func toggleServer() { if server.isRunning { server.stop() } else { server.start() } }
    @objc private func resetToken() { server.resetToken() }

    /// 复制地址：图标短暂变成 ✓。
    @objc private func copyURL() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(server.pageURL, forType: .string)
        setCopyIcon(copied: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in self?.setCopyIcon(copied: false) }
    }
}
