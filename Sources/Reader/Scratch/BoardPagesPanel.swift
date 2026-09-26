import AppKit
import Combine

/// 分页画板的「页面」面板（工具条那颗按钮弹出，`BOARD-NOTE-PLAN.md §9.4`）。底部分段切两页，默认「本页」：
///  · 本页：打开时视口中心所在那页——背景模板、在前 / 后插一页、删掉这一页；
///  · 所有页：整本页面大小（预设 × 横竖 + 宽 × 高手输）、页列表（系统表格，⌘ / ⇧ 多选，⌘A 全选，
///    双击跳过去）→ 给选中的页批量设背景、在后面插一页、删掉。
/// 全部走系统控件、Auto Layout 撑出尺寸（切页高度会变，经 `onResize` 让弹层跟着改）；
/// 数据只改 `DocSession`，落库与平板广播由会话那边对账。
final class BoardPagesPanel: NSView, NSTableViewDataSource, NSTableViewDelegate {
    var onDelete: (Set<Int>) -> Void = { _ in }
    var onJump: (Int) -> Void = { _ in }
    var onResize: (NSSize) -> Void = { _ in }

    private let session: DocSession
    /// 「本页」指的那页（插页后跟着那页走，删页 / 页数变少时夹到范围内）。
    private var page: Int
    private var bag = Set<AnyCancellable>()

    private let tabs = NSSegmentedControl(labels: [L("This Page"), L("All Pages")], trackingMode: .selectOne,
                                          target: nil, action: nil)
    private let pageView = NSStackView()
    private let allView = NSStackView()

    // 本页
    private let pageTitle = NSTextField(labelWithString: "")
    private let pageTemplate = NSPopUpButton(frame: .zero, pullsDown: false)

    // 所有页
    private let size = BoardPageSizeControl()
    private let table = NSTableView()
    private let bgPopup = NSPopUpButton(frame: .zero, pullsDown: true)

    private static let contentWidth: CGFloat = 300

    override var isFlipped: Bool { true }

    init(session: DocSession, currentPage: Int) {
        self.session = session
        self.page = currentPage
        super.init(frame: .zero)
        build()
        session.$boardPages.receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.reload() }.store(in: &bag)
        reload()
        setFrameSize(fittingSize)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) 不支持") }

    private func header(_ s: String) -> NSTextField {
        let f = NSTextField(labelWithString: s)
        f.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        f.textColor = .labelColor
        return f
    }

    private func build() {
        // ---- 本页 ----
        pageTitle.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        pageTitle.textColor = .labelColor
        for t in BoardTemplate.allCases { pageTemplate.addItem(withTitle: t.label) }
        pageTemplate.target = self
        pageTemplate.action = #selector(pageTemplatePicked)
        let bgLabel = NSTextField(labelWithString: L("Background"))
        bgLabel.textColor = .labelColor
        let bgRow = NSStackView(views: [bgLabel, pageTemplate])
        bgRow.spacing = 8
        let before = NSButton(title: L("Insert Page Before"), target: self, action: #selector(insertBefore))
        let after = NSButton(title: L("Insert Page After"), target: self, action: #selector(insertAfter))
        let delOne = NSButton(title: L("Delete Page…"), target: self, action: #selector(deleteThis))
        let insRow = NSStackView(views: [before, after])
        insRow.spacing = 8
        pageView.setViews([pageTitle, bgRow, insRow, delOne], in: .top)
        pageView.orientation = .vertical
        pageView.alignment = .leading
        pageView.spacing = 10

        // ---- 所有页 ----
        size.onChange = { [weak self] s in
            self?.session.setBoardPageSize(width: Double(s.width), height: Double(s.height))
        }
        let col = NSTableColumn(identifier: .init("page"))
        table.addTableColumn(col)
        table.headerView = nil
        table.allowsMultipleSelection = true
        table.usesAlternatingRowBackgroundColors = true
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(jump)
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder

        bgPopup.addItem(withTitle: L("Background"))   // 下拉按钮的标题项
        for t in BoardTemplate.allCases {
            let item = NSMenuItem(title: t.label, action: #selector(setBackground(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = t.rawValue
            bgPopup.menu?.addItem(item)
        }
        let insert = NSButton(title: L("Insert Page"), target: self, action: #selector(insertPage))
        let delete = NSButton(title: L("Delete"), target: self, action: #selector(deletePages))
        let buttons = NSStackView(views: [bgPopup, insert, delete])
        buttons.spacing = 8
        let tip = NSTextField(wrappingLabelWithString: L("Select several pages with ⌘ or ⇧ to change them together."))
        tip.font = .preferredFont(forTextStyle: .caption1)
        tip.textColor = .labelColor

        allView.setViews([header(L("Page Size")), size.presetRow, size.sizeRow,
                          header(L("Page List")), scroll, buttons, tip], in: .top)
        allView.orientation = .vertical
        allView.alignment = .leading
        allView.spacing = 8
        allView.setCustomSpacing(14, after: size.sizeRow)

        // ---- 外框：内容 + 底部分段 ----
        tabs.target = self
        tabs.action = #selector(tabChanged)
        tabs.selectedSegment = 0
        let tabRow = NSStackView()
        tabRow.setViews([tabs], in: .center)

        let stack = NSStackView(views: [pageView, allView, tabRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        let w = Self.contentWidth
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            pageView.widthAnchor.constraint(equalToConstant: w),
            allView.widthAnchor.constraint(equalToConstant: w),
            tabRow.widthAnchor.constraint(equalToConstant: w),
            scroll.widthAnchor.constraint(equalToConstant: w),
            scroll.heightAnchor.constraint(equalToConstant: 200),
            tip.widthAnchor.constraint(equalToConstant: w),
        ])
        tabChanged()
    }

    private func reload() {
        let n = session.boardPages.count
        page = min(max(0, page), max(0, n - 1))
        pageTitle.stringValue = String(format: L("Page %d of %d"), page + 1, n)
        if session.boardPages.indices.contains(page) {
            pageTemplate.selectItem(at: Int(session.boardPages[page].template.code))
        }

        let keep = table.selectedRowIndexes
        table.reloadData()
        table.selectRowIndexes(IndexSet(keep.filter { $0 < n }), byExtendingSelection: false)
        let l = session.boardLayout
        size.size = CGSize(width: l.width, height: l.height)
    }

    @objc private func tabChanged() {
        let all = tabs.selectedSegment == 1
        pageView.isHidden = all
        allView.isHidden = !all
        let s = fittingSize
        setFrameSize(s)
        onResize(s)
    }

    // MARK: 表格

    func numberOfRows(in tableView: NSTableView) -> Int { session.boardPages.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard session.boardPages.indices.contains(row) else { return nil }
        let id = NSUserInterfaceItemIdentifier("cell")
        let cell = (tableView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView) ?? {
            let c = NSTableCellView()
            c.identifier = id
            let f = NSTextField(labelWithString: "")
            f.translatesAutoresizingMaskIntoConstraints = false
            c.addSubview(f)
            c.textField = f
            NSLayoutConstraint.activate([
                f.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 4),
                f.trailingAnchor.constraint(lessThanOrEqualTo: c.trailingAnchor, constant: -4),
                f.centerYAnchor.constraint(equalTo: c.centerYAnchor),
            ])
            return c
        }()
        cell.textField?.stringValue = String(format: L("Page %d"), row + 1) + " · " + session.boardPages[row].template.label
        return cell
    }

    // MARK: 本页动作

    @objc private func pageTemplatePicked() {
        let i = pageTemplate.indexOfSelectedItem
        guard BoardTemplate.allCases.indices.contains(i) else { return }
        session.setBoardTemplate(BoardTemplate.allCases[i], pages: [page])
    }

    @objc private func insertBefore() {
        page += 1   // 新页插在前面，「本页」跟着原来那页往后挪
        session.insertBoardPage(at: page - 1)
    }

    @objc private func insertAfter() { session.insertBoardPage(at: page + 1) }

    @objc private func deleteThis() { onDelete([page]) }

    // MARK: 所有页动作

    /// 选中的页；什么都没选 = 全部（批量设背景时最常见的意图）。
    private var targets: Set<Int> {
        let sel = Set(table.selectedRowIndexes)
        return sel.isEmpty ? Set(session.boardPages.indices) : sel
    }

    @objc private func setBackground(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String else { return }
        session.setBoardTemplate(BoardTemplate(raw: raw), pages: targets)
    }

    @objc private func insertPage() {
        let after = table.selectedRowIndexes.last ?? (session.boardPages.count - 1)
        session.insertBoardPage(at: after + 1)
    }

    @objc private func deletePages() {
        let sel = Set(table.selectedRowIndexes)
        guard !sel.isEmpty else { NSSound.beep(); return }
        onDelete(sel)
    }

    @objc private func jump() {
        let r = table.clickedRow
        if session.boardPages.indices.contains(r) { onJump(r) }
    }
}
