import AppKit
import Combine

/// 搜索结果浮窗（2026-10-19 用户要的）：PDF 搜索命中多、又散在全书各处时，光靠查找条上 / 下一个一处处翻太慢——
/// 这里按页分组列出每一处（页码 + 所在章节，每条带前后几个字），点哪条跳哪条；用上 / 下一个时列表跟着走。
///
/// 开关 / 摆位 / 尺寸存偏好（所有窗口同一份），列表数据跟当前标签的 `DocSession`。
/// 只在「当前是 PDF 且搜索框里有词」时出现（`active`）；用户关掉了、草稿纸盖着都不显示。
/// 外观同跳转历史浮窗（`FloatingCardView`）；材质底上的字一律 `labelColor`，层级差异用字号 / 字重表达（红线 4）。
@MainActor
final class SearchResultsCard: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private enum K {
        static let open = "searchPanelOpen"
        static let w = "searchPanelW", h = "searchPanelH"
        static let dx = "searchPanelDX", dy = "searchPanelDY"
        static let placed = "searchPanelPlaced"   // 用户摆过没有（没摆过就用「右上角」这个默认位）
    }
    static let defaultSize = CGSize(width: 300, height: 420)

    let card: FloatingCardView
    private(set) var session: DocSession?
    /// 用户开关（默认开）。关掉 = 只剩查找条上的计数与上 / 下一个。
    private(set) var isOpen: Bool
    /// 开关变了（查找条上那枚按钮要跟着换状态）。
    var onOpenChange: () -> Void = {}
    /// 当前内容有没有可列的搜索（PDF + 搜索框有词），由窗格每次刷新时给。
    var active = false { didSet { if oldValue != active { syncVisible() } } }
    /// 草稿纸开着时整个隐去（它盖满阅读区）。
    var suppressed = false { didSet { if oldValue != suppressed { syncVisible() } } }

    private var placed: Bool
    private let table = NSTableView()
    private let scroll = NSScrollView()
    private let emptyLabel = NSTextField(labelWithString: "")
    private let titleLabel = NSTextField(labelWithString: "")
    private let countLabel = NSTextField(labelWithString: "")
    private var sessionBag = Set<AnyCancellable>()
    private var lastContainer: CGSize = .zero

    /// 列表的一行：页标题（页码 + 章节 + 本页几处）或一处命中。
    private enum Row {
        case page(Int, count: Int, first: Int)   // 页（0 起）、本页命中数、本页第一处的下标
        case hit(Int)                            // `searchMatches` 下标
    }
    private var rows: [Row] = []
    private var rowOfMatch: [Int] = []           // 命中下标 → 行号
    private var matchCount = 0
    private var current: Int?

    override init() {
        let d = UserDefaults.standard
        let w = d.double(forKey: K.w), h = d.double(forKey: K.h)
        let size = (w >= JumpHistoryPanel.minSize.width && h >= JumpHistoryPanel.minSize.height)
            ? CGSize(width: w, height: h) : Self.defaultSize
        card = FloatingCardView(size: size, offset: CGSize(width: d.double(forKey: K.dx), height: d.double(forKey: K.dy)))
        isOpen = d.object(forKey: K.open) as? Bool ?? true
        placed = d.bool(forKey: K.placed)
        super.init()
        card.isHidden = true
        card.headerHeight = 30
        card.footerHeight = 24
        // 与跳转历史浮窗同一套夹取口径（offset 相对容器右下角，≤0 往左上）
        card.clampSize = { JumpHistoryPanel.clampSize($0, in: $1) }
        card.clampOffset = { JumpHistoryPanel.clampOffset($0, size: $1, in: $2) }
        card.onCommit = { [weak self] s, o in self?.persistGeometry(size: s, offset: o) }
        buildHeader()
        buildBody()
        buildFooter()
    }

    // MARK: 开关

    func toggle() { setOpen(!isOpen) }

    func setOpen(_ on: Bool) {
        guard on != isOpen else { return }
        isOpen = on
        UserDefaults.standard.set(on, forKey: K.open)
        syncVisible()
        onOpenChange()
    }

    // MARK: 搭界面

    private func buildHeader() {
        let icon = NSImageView(image: NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil) ?? NSImage())
        icon.symbolConfiguration = .init(pointSize: 11, weight: .regular)
        icon.contentTintColor = .labelColor
        titleLabel.font = .preferredFont(forTextStyle: .callout)
        titleLabel.textColor = .labelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let prev = CardIconButton("chevron.up", L("Previous Match")) { [weak self] in self?.session?.prevMatch() }
        let next = CardIconButton("chevron.down", L("Next Match")) { [weak self] in self?.session?.nextMatch() }
        let close = CardIconButton("xmark", L("Close")) { [weak self] in self?.setOpen(false) }
        prevButton = prev
        nextButton = next
        let stack = NSStackView(views: [icon, titleLabel, spacer, prev, next, close])
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 8)
        pin(stack, in: card.header)
    }
    private weak var prevButton: NSButton?
    private weak var nextButton: NSButton?

    private func buildBody() {
        let col = NSTableColumn(identifier: .init("hit"))
        table.addTableColumn(col)
        table.headerView = nil
        table.style = .plain
        table.backgroundColor = .clear
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.selectionHighlightStyle = .none
        // 点列表不抢阅读区的键盘焦点（方向键 / 空格翻页照常给阅读区）
        table.refusesFirstResponder = true
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(clicked)
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.contentInsets = NSEdgeInsets(top: 4, left: 0, bottom: 4, right: 0)
        pin(scroll, in: card.body)

        emptyLabel.font = .preferredFont(forTextStyle: .callout)
        emptyLabel.textColor = .labelColor
        emptyLabel.alignment = .center
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        card.body.addSubview(emptyLabel)
        NSLayoutConstraint.activate([
            emptyLabel.centerXAnchor.constraint(equalTo: card.body.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: card.body.centerYAnchor),
            emptyLabel.widthAnchor.constraint(lessThanOrEqualTo: card.body.widthAnchor, constant: -24),
        ])
    }

    private func buildFooter() {
        countLabel.font = .preferredFont(forTextStyle: .caption1)
        countLabel.textColor = .labelColor
        countLabel.lineBreakMode = .byTruncatingTail
        let stack = NSStackView(views: [countLabel])
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

    /// 换标签 = 换一份结果；窗不动。
    func bind(_ s: DocSession) {
        guard session !== s else { return }
        session = s
        sessionBag.removeAll()
        // `@Published` 在 willSet 发出：一律跳到下一拍再读会话（那时值已写好）
        s.$searchMatches.receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.reloadMatches() }.store(in: &sessionBag)
        s.$currentMatchIndex.receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.currentChanged() }.store(in: &sessionBag)
        s.$isSearching.receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateTexts() }.store(in: &sessionBag)
        reloadMatches()
    }

    func layout(in container: CGSize) {
        lastContainer = container
        guard !card.isHidden else { return }
        placeDefault(in: container)   // 用户没摆过：窗口变大变小都贴着右上角
        card.place(in: container)
    }

    private var shouldShow: Bool { isOpen && active && !suppressed }

    private func syncVisible() {
        let show = shouldShow
        guard show == card.isHidden else { return }
        if show {
            placeDefault(in: lastContainer)
            card.place(in: lastContainer)
            card.alphaValue = 0
            card.isHidden = false
            if let s = session, let i = s.currentMatchIndex, rowOfMatch.indices.contains(i) {
                table.scrollRowToVisible(rowOfMatch[i])
            }
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
                    guard let self, !self.shouldShow else { return }
                    self.card.isHidden = true
                }
            })
        }
    }

    /// 用户没摆过时的默认位：贴容器**右上角**（查找条在顶部正中，跳转历史默认左下、参考窗默认右下，都错开）。
    private func placeDefault(in container: CGSize) {
        guard !placed, container.height > 0 else { return }
        // offset 相对右下角：往上推到顶（夹取把它停在离顶边 2pt 处）
        let s = JumpHistoryPanel.clampSize(card.size, in: container)
        card.size = s
        card.offset = JumpHistoryPanel.clampOffset(CGSize(width: 0, height: -container.height), size: s, in: container)
    }

    private func persistGeometry(size: CGSize, offset: CGSize) {
        let d = UserDefaults.standard
        d.set(size.width, forKey: K.w); d.set(size.height, forKey: K.h)
        d.set(offset.width, forKey: K.dx); d.set(offset.height, forKey: K.dy)
        d.set(true, forKey: K.placed)
        placed = true
    }

    /// 命中列表整个换了（新一轮搜索 / 清空）：重新分组。表格是懒建行视图的，几万条也只建看得见的那些。
    private func reloadMatches() {
        let matches = session?.searchMatches ?? []
        rows.removeAll(keepingCapacity: true)
        rowOfMatch = Array(repeating: 0, count: matches.count)
        var i = 0
        while i < matches.count {
            let p = matches[i].page
            var j = i
            while j < matches.count, matches[j].page == p { j += 1 }
            rows.append(.page(p, count: j - i, first: i))
            for k in i..<j {
                rowOfMatch[k] = rows.count
                rows.append(.hit(k))
            }
            i = j
        }
        matchCount = matches.count
        current = session?.currentMatchIndex
        table.reloadData()
        if let c = current, rowOfMatch.indices.contains(c) { table.scrollRowToVisible(rowOfMatch[c]) }
        else if !rows.isEmpty { table.scrollRowToVisible(0) }
        updateTexts()
    }

    /// 只换了当前那一处（上 / 下一个、点列表）：重画新旧两行，新的滚进视野。
    private func currentChanged() {
        let new = session?.currentMatchIndex
        guard new != current else { return }
        var dirty = IndexSet()
        for k in [current, new].compactMap({ $0 }) where rowOfMatch.indices.contains(k) { dirty.insert(rowOfMatch[k]) }
        current = new
        dirty = dirty.filteredIndexSet { $0 < rows.count }
        if !dirty.isEmpty { table.reloadData(forRowIndexes: dirty, columnIndexes: IndexSet(integer: 0)) }
        if let c = new, rowOfMatch.indices.contains(c) {
            let r = rowOfMatch[c]
            // 一页的第一处：连同上面的页标题一起滚进来，不然看不出是哪一页
            if r > 0, case .page = rows[r - 1] { table.scrollRowToVisible(r - 1) }
            table.scrollRowToVisible(r)
        }
    }

    private func updateTexts() {
        guard let s = session else { return }
        let q = s.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        titleLabel.stringValue = q.isEmpty ? L("Search Results") : "\u{201C}\(q)\u{201D}"
        let pages = rows.reduce(0) { n, r in if case .page = r { return n + 1 }; return n }
        if s.isSearching {
            countLabel.stringValue = L("Searching…")
        } else if matchCount == 0 {
            countLabel.stringValue = ""
        } else {
            countLabel.stringValue = String(format: L("%d matches on %d pages"), matchCount, pages)
        }
        emptyLabel.stringValue = s.isSearching ? L("Searching…") : L("No matches")
        emptyLabel.isHidden = matchCount > 0
        scroll.isHidden = matchCount == 0
        prevButton?.isEnabled = matchCount > 0
        nextButton?.isEnabled = matchCount > 0
    }

    @objc private func clicked() {
        let r = table.clickedRow
        guard rows.indices.contains(r) else { return }
        switch rows[r] {
        case let .page(_, _, first): session?.selectMatch(first)
        case let .hit(k): session?.selectMatch(k)
        }
    }

    // MARK: 表格

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard rows.indices.contains(row) else { return 24 }
        if case .page = rows[row] { return 26 }
        return SearchHitRowView.height
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard rows.indices.contains(row), let s = session else { return nil }
        switch rows[row] {
        case let .page(p, count, _):
            let id = NSUserInterfaceItemIdentifier("searchPageRow")
            let v = (tableView.makeView(withIdentifier: id, owner: nil) as? SearchPageRowView) ?? {
                let r = SearchPageRowView()
                r.identifier = id
                return r
            }()
            v.set(page: p + 1, chapter: TOCEntry.chapterLabel(for: p, in: s.toc), count: count)
            return v
        case let .hit(k):
            let id = NSUserInterfaceItemIdentifier("searchHitRow")
            let v = (tableView.makeView(withIdentifier: id, owner: nil) as? SearchHitRowView) ?? {
                let r = SearchHitRowView()
                r.identifier = id
                return r
            }()
            guard s.searchMatches.indices.contains(k) else { return v }
            v.set(s.searchMatches[k], current: k == current)
            return v
        }
    }
}

/// 页标题行：「第 12 页」+ 所在章节（可截断）+ 本页几处。
private final class SearchPageRowView: NSTableCellView {
    private let page = NSTextField(labelWithString: "")
    private let chapter = NSTextField(labelWithString: "")
    private let count = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        let size = NSFont.preferredFont(forTextStyle: .caption1).pointSize
        page.font = .systemFont(ofSize: size, weight: .semibold)
        chapter.font = .systemFont(ofSize: size)
        count.font = .monospacedDigitSystemFont(ofSize: size, weight: .regular)
        for f in [page, chapter, count] { f.textColor = .labelColor }
        page.setContentHuggingPriority(.required, for: .horizontal)
        page.setContentCompressionResistancePriority(.required, for: .horizontal)
        chapter.lineBreakMode = .byTruncatingTail
        chapter.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        count.setContentHuggingPriority(.required, for: .horizontal)
        count.setContentCompressionResistancePriority(.required, for: .horizontal)
        for v in [page, chapter, count] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            page.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            page.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            chapter.leadingAnchor.constraint(equalTo: page.trailingAnchor, constant: 6),
            chapter.firstBaselineAnchor.constraint(equalTo: page.firstBaselineAnchor),
            count.leadingAnchor.constraint(greaterThanOrEqualTo: chapter.trailingAnchor, constant: 6),
            count.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            count.firstBaselineAnchor.constraint(equalTo: page.firstBaselineAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) 不支持") }

    func set(page p: Int, chapter c: String, count n: Int) {
        page.stringValue = String(format: L("Page %d"), p)
        chapter.stringValue = c
        count.stringValue = "\(n)"
    }
}

/// 一处命中：最多两行摘要（第二行放不下末尾省略），命中那几个字加粗；当前这处铺一层强调色浅底。
/// 行高固定按两行算（几万行的列表不逐行量字）；只有一行的摘要垂直居中。
/// ⚠️ 折行标签的固有高度按 `preferredMaxLayoutWidth` 算，不给就按单行宽度算、被压成一行——在 `layout()` 里按实际宽度补上。
/// ⚠️ 折行方式必须是 `.byWordWrapping`：给 `.byTruncatingTail` 文字框就退成单行（2026-10-19 离屏样张实测）。
private final class SearchHitRowView: NSTableCellView {
    static let font = NSFont.preferredFont(forTextStyle: .callout)
    static let height: CGFloat = ceil(NSLayoutManager().defaultLineHeight(for: font)) * 2 + 12
    private static let inset: CGFloat = 6 + 8   // 底色离行边 6，字离底色 8
    private let text = NSTextField(wrappingLabelWithString: "")
    private let bg = NSView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        bg.wantsLayer = true
        bg.layer?.cornerRadius = 6
        text.maximumNumberOfLines = 2
        text.lineBreakMode = .byWordWrapping
        text.cell?.truncatesLastVisibleLine = true
        text.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        for v in [bg, text] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            bg.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            bg.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            bg.topAnchor.constraint(equalTo: topAnchor, constant: 1),
            bg.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -1),
            text.leadingAnchor.constraint(equalTo: bg.leadingAnchor, constant: 8),
            text.trailingAnchor.constraint(equalTo: bg.trailingAnchor, constant: -8),
            text.centerYAnchor.constraint(equalTo: bg.centerYAnchor),
            text.topAnchor.constraint(greaterThanOrEqualTo: bg.topAnchor, constant: 2),
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) 不支持") }

    override func layout() {
        let w = max(0, bounds.width - Self.inset * 2)
        if text.preferredMaxLayoutWidth != w { text.preferredMaxLayoutWidth = w }
        super.layout()
    }

    func set(_ m: TextMatch, current: Bool) {
        let font = Self.font
        let s = NSMutableAttributedString(string: m.snippet.isEmpty ? " " : m.snippet,
                                          attributes: [.font: font, .foregroundColor: NSColor.labelColor])
        if m.snippetHit.length > 0, NSMaxRange(m.snippetHit) <= s.length {
            s.addAttribute(.font, value: NSFont.systemFont(ofSize: font.pointSize, weight: .bold), range: m.snippetHit)
        }
        text.attributedStringValue = s
        bg.layer?.backgroundColor = current ? NSColor.controlAccentColor.withAlphaComponent(0.18).cgColor : nil
    }
}
