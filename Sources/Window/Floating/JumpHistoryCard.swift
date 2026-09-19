import AppKit
import Combine

/// 跳转历史浮窗（AppKit 版，替代 SwiftUI `JumpHistoryView`）：浮在阅读区上的一条轨迹列表，点哪条去哪儿。
///
/// 摆位 / 尺寸 / 开关在 `panel`（窗口级），列表数据在 `session.jumps`（文档级）——切标签时窗不动、内容换。
@MainActor
final class JumpHistoryCard: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    let panel: JumpHistoryPanel
    let card: FloatingCardView
    private(set) var session: DocSession?

    private let table = NSTableView()
    private let scroll = NSScrollView()
    private let empty = NSStackView()
    private let countLabel = NSTextField(labelWithString: "")
    private let clearButton = NSButton()
    private var marks: [JumpMark] = []
    private var currentID: UUID?
    private var sessionBag = Set<AnyCancellable>()
    private var bag = Set<AnyCancellable>()
    private var lastContainer: CGSize = .zero

    init(panel: JumpHistoryPanel) {
        self.panel = panel
        card = FloatingCardView(size: panel.size, offset: panel.offset)
        super.init()
        card.isHidden = true
        card.headerHeight = 30
        card.footerHeight = 24
        card.clampSize = { JumpHistoryPanel.clampSize($0, in: $1) }
        card.clampOffset = { JumpHistoryPanel.clampOffset($0, size: $1, in: $2) }
        card.onCommit = { [weak panel] s, o in
            guard let panel else { return }
            panel.size = s
            panel.offset = o
            panel.persistGeometry()
        }
        buildHeader()
        buildBody()
        buildFooter()
        panel.$isOpen.receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.syncOpen() }.store(in: &bag)
    }

    // MARK: 搭界面

    private func buildHeader() {
        let icon = NSImageView(image: NSImage(systemSymbolName: "clock.arrow.circlepath", accessibilityDescription: nil) ?? NSImage())
        icon.symbolConfiguration = .init(pointSize: 11, weight: .regular)
        icon.contentTintColor = .labelColor
        let title = NSTextField(labelWithString: L("Jump History"))
        title.font = .preferredFont(forTextStyle: .callout)
        title.textColor = .labelColor
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let back = CardIconButton("chevron.left", L("Back to Previous Position")) { [weak self] in self?.session?.jumpBack() }
        let fwd = CardIconButton("chevron.right", L("Forward to Next Position")) { [weak self] in self?.session?.jumpForward() }
        let close = CardIconButton("xmark", L("Close")) { [weak self] in self?.panel.close() }
        backButton = back
        forwardButton = fwd
        let stack = NSStackView(views: [icon, title, spacer, back, fwd, close])
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 8)
        pin(stack, in: card.header)
    }
    private weak var backButton: NSButton?
    private weak var forwardButton: NSButton?

    private func buildBody() {
        let col = NSTableColumn(identifier: .init("jump"))
        table.addTableColumn(col)
        table.headerView = nil
        table.style = .plain
        table.backgroundColor = .clear
        table.rowHeight = 26
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.selectionHighlightStyle = .none
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(clicked)
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.contentInsets = NSEdgeInsets(top: 6, left: 0, bottom: 6, right: 0)
        pin(scroll, in: card.body)

        let icon = NSImageView(image: NSImage(systemSymbolName: "arrow.trianglehead.turn.up.right.diamond", accessibilityDescription: nil) ?? NSImage())
        icon.symbolConfiguration = .init(textStyle: .title2)
        icon.contentTintColor = .tertiaryLabelColor
        let t1 = NSTextField(labelWithString: L("No jumps yet"))
        t1.font = .preferredFont(forTextStyle: .callout)
        t1.textColor = .secondaryLabelColor
        let t2 = NSTextField(wrappingLabelWithString: L("Contents, search and list jumps show up here."))
        t2.font = .preferredFont(forTextStyle: .caption1)
        t2.textColor = .tertiaryLabelColor
        t2.alignment = .center
        for v in [icon, t1, t2] as [NSView] { empty.addArrangedSubview(v) }
        empty.orientation = .vertical
        empty.spacing = 6
        empty.edgeInsets = NSEdgeInsets(top: 0, left: 16, bottom: 0, right: 16)
        empty.translatesAutoresizingMaskIntoConstraints = false
        card.body.addSubview(empty)
        NSLayoutConstraint.activate([
            empty.centerXAnchor.constraint(equalTo: card.body.centerXAnchor),
            empty.centerYAnchor.constraint(equalTo: card.body.centerYAnchor),
            empty.widthAnchor.constraint(lessThanOrEqualTo: card.body.widthAnchor),
        ])
    }

    private func buildFooter() {
        countLabel.font = .preferredFont(forTextStyle: .caption1)
        countLabel.textColor = .secondaryLabelColor
        clearButton.title = L("Clear History")
        clearButton.isBordered = false
        clearButton.font = .preferredFont(forTextStyle: .caption1)
        clearButton.contentTintColor = .secondaryLabelColor
        clearButton.target = self
        clearButton.action = #selector(clearHistory)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let stack = NSStackView(views: [countLabel, spacer, clearButton])
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 10)
        pin(stack, in: card.footer)
    }

    private func pin(_ v: NSView, in parent: NSView) {
        v.translatesAutoresizingMaskIntoConstraints = false
        parent.addSubview(v)
        NSLayoutConstraint.activate([
            v.leadingAnchor.constraint(equalTo: parent.leadingAnchor),
            v.trailingAnchor.constraint(equalTo: parent.trailingAnchor),
            v.topAnchor.constraint(equalTo: parent.topAnchor),
            v.bottomAnchor.constraint(equalTo: parent.bottomAnchor),
        ])
    }

    // MARK: 状态

    /// 换标签 = 换一份历史；窗不动。
    func bind(_ s: DocSession) {
        guard session !== s else { return }
        session = s
        sessionBag.removeAll()
        s.$jumps.receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.reload() }.store(in: &sessionBag)
        reload()
    }

    /// 草稿纸开着时整个隐去（它盖满阅读区）。
    var suppressed = false { didSet { if oldValue != suppressed { syncOpen() } } }

    func layout(in container: CGSize) {
        lastContainer = container
        if !card.isHidden { card.place(in: container) }
    }

    private func syncOpen() {
        let show = panel.isOpen && !suppressed
        guard show == card.isHidden else { return }
        if show {
            panel.placeDefault(in: lastContainer)
            card.size = panel.size
            card.offset = panel.offset
            card.place(in: lastContainer)
            card.alphaValue = 0
            card.isHidden = false
            reload()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.16
                card.animator().alphaValue = 1
            }
        } else {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.16
                card.animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, !(self.panel.isOpen && !self.suppressed) else { return }
                    self.card.isHidden = true
                }
            })
        }
    }

    private func reload() {
        guard let s = session else { return }
        let j = s.jumps
        let newMarks = j.marks
        let newCurrent = j.current?.id
        let changed = newMarks != marks || newCurrent != currentID
        marks = newMarks
        currentID = newCurrent
        backButton?.isEnabled = j.canGoBack
        forwardButton?.isEnabled = j.canGoForward
        countLabel.stringValue = String(format: L("%d marks"), marks.count)
        clearButton.isEnabled = !marks.isEmpty
        empty.isHidden = !marks.isEmpty
        scroll.isHidden = marks.isEmpty
        guard changed else { return }
        table.reloadData()
        // 当前这条滚进视野（后退 / 前进时列表跟着走）
        if let id = currentID, let row = marks.firstIndex(where: { $0.id == id }) {
            table.scrollRowToVisible(row)
        }
    }

    @objc private func clicked() {
        let r = table.clickedRow
        guard marks.indices.contains(r) else { return }
        session?.jumpToMark(id: marks[r].id)
    }

    @objc private func clearHistory() { session?.clearJumps() }

    // MARK: 表格

    func numberOfRows(in tableView: NSTableView) -> Int { marks.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("jumpRow")
        let v = (tableView.makeView(withIdentifier: id, owner: nil) as? JumpRowView) ?? {
            let r = JumpRowView()
            r.identifier = id
            return r
        }()
        let m = marks[row]
        v.set(symbol: m.kind.symbol, title: m.displayTitle(toc: session?.toc ?? []), page: m.page + 1,
              current: m.id == currentID)
        return v
    }
}

/// 历史里的一行：类型图标 + 名字（可截断）+ 页码；当前这条用强调色 + 浅底。
private final class JumpRowView: NSTableCellView {
    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let page = NSTextField(labelWithString: "")
    private let bg = NSView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        bg.wantsLayer = true
        bg.layer?.cornerRadius = 6
        icon.symbolConfiguration = .init(pointSize: 11, weight: .regular)
        title.font = .preferredFont(forTextStyle: .callout)
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        page.font = .monospacedDigitSystemFont(ofSize: NSFont.preferredFont(forTextStyle: .caption1).pointSize, weight: .regular)
        page.setContentHuggingPriority(.required, for: .horizontal)
        for v in [bg, icon, title, page] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            bg.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            bg.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            bg.topAnchor.constraint(equalTo: topAnchor, constant: 1),
            bg.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -1),
            icon.leadingAnchor.constraint(equalTo: bg.leadingAnchor, constant: 6),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            title.centerYAnchor.constraint(equalTo: centerYAnchor),
            page.leadingAnchor.constraint(greaterThanOrEqualTo: title.trailingAnchor, constant: 6),
            page.trailingAnchor.constraint(equalTo: bg.trailingAnchor, constant: -6),
            page.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) 不支持") }

    func set(symbol: String, title t: String, page p: Int, current: Bool) {
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        title.stringValue = t
        page.stringValue = "\(p)"
        let tint: NSColor = current ? .controlAccentColor : .labelColor
        title.textColor = tint
        icon.contentTintColor = current ? .controlAccentColor : .secondaryLabelColor
        page.textColor = current ? .controlAccentColor : .secondaryLabelColor
        bg.layer?.backgroundColor = current ? NSColor.controlAccentColor.withAlphaComponent(0.16).cgColor : nil
    }
}
