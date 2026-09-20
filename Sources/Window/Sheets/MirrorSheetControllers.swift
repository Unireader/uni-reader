import AppKit

// 离线镜像的两张面板（AppKit 版，替代 SwiftUI `MirrorSheets`；方案 `OFFLINE-MIRROR-PLAN.md` §8）：
// **建镜像** 与 **同步预览**。都是系统标准控件，没有自绘的仿系统样式。

// MARK: - 建镜像

/// 选内容 + 看估算 + 建。**位置不让用户挑**（理由见 `WorkspaceManager.mirrorsRoot`）：这里只把算好的落点摆出来，
/// 建完挂到这个工作区那条最近记录上，之后源盘不在时由打开链路自动选用——副本不占最近列表的一行。
@MainActor
final class MakeMirrorController: StackPanelController, NSTableViewDataSource, NSTableViewDelegate {
    let workspace: WorkspaceManager
    var onDismiss: () -> Void = {}

    /// 勾了「带 PDF」的书。默认全勾——想做的本来就是「整个搬走」，取消才是少数动作。
    private var withPDF: Set<String> = []
    private var estimate: MirrorBuilder.Estimate?
    /// 估算是异步的，连点勾选框时先发的那次可能后回来——只认最后一次
    private var estimateToken = 0
    private var destination: URL?
    /// 本机已经有的那份镜像。非 nil 就不给再建（见 `WorkspaceManager.existingMirror`）
    private var existing: URL?
    private var running = false
    private var done: MirrorBuilder.Result?
    private var errorText: String?

    private let table = NSTableView()
    private let estimateLabel = NSTextField(labelWithString: "")
    private let unresolvedLabel = NSTextField(labelWithString: "")
    private let existingBox = NSStackView()
    private var destLabel: NSTextField!
    private let progress = NSProgressIndicator()
    private let stepLabel = NSTextField(labelWithString: "")
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    private let doneBox = NSStackView()
    private var doneLabel: NSTextField!
    private var cancelButton: NSButton!
    private var createButton: NSButton!
    private var docs: [LibDocument] = []

    init(workspace: WorkspaceManager) {
        self.workspace = workspace
        super.init(width: 460, inset: 20)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) 不支持") }

    private var inner: CGFloat { width - inset * 2 }

    override func viewDidLoad() {
        super.viewDidLoad()
        stack.spacing = 12
        docs = workspace.documents
        withPDF = Set(docs.map(\.id))
        destination = WorkspaceManager.plannedMirrorURL(name: workspace.name)

        stack.addArrangedSubview(headline(L("Offline Mirror")))
        stack.addArrangedSubview(callout(L("All books and notes come along. Only the PDFs you tick are copied — the rest stay readable as entries you can open once the drive is back.")))

        // 勾选是「带不带 PDF」这个属性，不是「选中了谁」：每行一个勾选框，不用表格的选中态
        let col = NSTableColumn(identifier: .init("doc"))
        table.addTableColumn(col)
        table.headerView = nil
        table.rowHeight = 24
        table.selectionHighlightStyle = .none
        table.dataSource = self
        table.delegate = self
        table.usesAlternatingRowBackgroundColors = true
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        stack.addArrangedSubview(SheetKit.fixed(scroll, width: inner, height: 220))

        estimateLabel.font = .monospacedDigitSystemFont(ofSize: NSFont.preferredFont(forTextStyle: .callout).pointSize, weight: .regular)
        stack.addArrangedSubview(estimateLabel)
        unresolvedLabel.font = .preferredFont(forTextStyle: .callout)
        unresolvedLabel.textColor = .systemOrange
        stack.addArrangedSubview(unresolvedLabel)

        existingBox.orientation = .vertical
        existingBox.alignment = .leading
        existingBox.spacing = 6
        let warn = label(L("This workspace already has an offline copy on this Mac."), symbol: "exclamationmark.triangle", color: .systemOrange)
        existingBox.addArrangedSubview(warn)
        existingBox.addArrangedSubview(callout(L("Sync that one back and delete it first if you want a fresh copy.")))
        let revealExisting = NSButton(title: L("Show in Finder"), target: self, action: #selector(revealExisting))
        revealExisting.controlSize = .small
        existingBox.addArrangedSubview(revealExisting)
        stack.addArrangedSubview(existingBox)

        destLabel = callout("")
        destLabel.maximumNumberOfLines = 2
        destLabel.lineBreakMode = .byTruncatingMiddle
        destLabel.isSelectable = true
        stack.addArrangedSubview(destLabel)

        progress.isIndeterminate = false
        progress.minValue = 0
        progress.maxValue = 1
        stepLabel.font = .preferredFont(forTextStyle: .callout)
        stack.addArrangedSubview(stepLabel)
        stack.addArrangedSubview(SheetKit.fixed(progress, width: inner))

        errorLabel.font = .preferredFont(forTextStyle: .callout)
        errorLabel.textColor = .systemRed
        errorLabel.preferredMaxLayoutWidth = inner
        stack.addArrangedSubview(errorLabel)

        doneBox.orientation = .vertical
        doneBox.alignment = .leading
        doneBox.spacing = 6
        doneLabel = label("", symbol: "checkmark.circle", color: .labelColor)
        doneBox.addArrangedSubview(doneLabel)
        doneBox.addArrangedSubview(callout(L("From now on, opening this workspace without the drive connected uses this copy automatically.")))
        let revealDone = NSButton(title: L("Show in Finder"), target: self, action: #selector(revealDone))
        revealDone.controlSize = .small
        doneBox.addArrangedSubview(revealDone)
        stack.addArrangedSubview(doneBox)

        cancelButton = SheetKit.cancelButton(self, #selector(close))
        createButton = NSButton(title: L("Create Mirror"), target: self, action: #selector(run))
        createButton.keyEquivalent = "\r"
        stack.addArrangedSubview(SheetKit.hrow([SheetKit.spacer(), cancelButton, createButton], width: inner))

        table.reloadData()
        refresh()
        recomputeEstimate()
        // 要逐个打开 Mirrors/ 下每份副本的库看血缘——本机盘，快，但没理由占着主线程
        let wid = workspace.workspaceId
        DispatchQueue.global(qos: .userInitiated).async {
            let found = wid.flatMap { WorkspaceManager.existingMirror(of: $0) }
            DispatchQueue.main.async { [weak self] in
                self?.existing = found
                self?.refresh()
            }
        }
        view.setFrameSize(preferredContentSize)
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        onDismiss()
    }

    private func label(_ s: String, symbol: String, color: NSColor) -> NSTextField {
        let t = NSTextField(wrappingLabelWithString: "")
        let a = NSMutableAttributedString()
        let att = NSTextAttachment()
        att.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        a.append(NSAttributedString(attachment: att))
        a.append(NSAttributedString(string: " " + s))
        a.addAttributes([.foregroundColor: color, .font: NSFont.preferredFont(forTextStyle: .callout)],
                        range: NSRange(location: 0, length: a.length))
        t.attributedStringValue = a
        t.preferredMaxLayoutWidth = inner
        return t
    }

    private func callout(_ s: String) -> NSTextField {
        let t = NSTextField(wrappingLabelWithString: s)
        t.font = .preferredFont(forTextStyle: .callout)
        t.textColor = .secondaryLabelColor
        t.preferredMaxLayoutWidth = inner
        return t
    }

    private func refresh() {
        if let e = estimate {
            estimateLabel.isHidden = false
            estimateLabel.stringValue = String(format: L("%d files · about %@"), e.files,
                                               ByteCountFormatter.string(fromByteCount: e.bytes, countStyle: .file))
            // 静默跳过的话用户会以为带上了，等硬盘不在手上时才发现打不开
            unresolvedLabel.isHidden = e.unresolved.isEmpty
            unresolvedLabel.stringValue = "⚠︎ " + String(format: L("%d ticked books have no file right now and will be skipped."), e.unresolved.count)
        } else {
            estimateLabel.isHidden = true
            unresolvedLabel.isHidden = true
        }
        existingBox.isHidden = existing == nil
        if existing == nil, let destination, done == nil {
            destLabel.isHidden = false
            destLabel.stringValue = String(format: L("Kept at %@"), (destination.path as NSString).abbreviatingWithTildeInPath)
        } else {
            destLabel.isHidden = true
        }
        stepLabel.isHidden = !running
        progress.isHidden = !running
        errorLabel.isHidden = errorText == nil
        errorLabel.stringValue = errorText.map { "✕ " + $0 } ?? ""
        doneBox.isHidden = done == nil
        if let d = done {
            let text = String(format: L("Mirror created: %d files, %d baseline rows."), d.copiedFiles, d.baseRows)
            doneLabel.attributedStringValue = label(text, symbol: "checkmark.circle", color: .labelColor).attributedStringValue
        }
        cancelButton.title = done == nil ? L("Cancel") : L("Done")
        createButton.isHidden = done != nil
        createButton.isEnabled = !running && existing == nil
        resize()
    }

    /// 估算要逐本 stat 文件，而源盘在 USB 上：放后台，用 token 丢弃过期结果。
    private func recomputeEstimate() {
        estimateToken += 1
        let token = estimateToken
        let ids = withPDF
        let ws = workspace
        DispatchQueue.global(qos: .userInitiated).async {
            let e = ws.mirrorEstimate(documentsWithPDF: ids)
            DispatchQueue.main.async { [weak self] in
                guard let self, token == self.estimateToken else { return }
                self.estimate = e
                self.refresh()
            }
        }
    }

    @objc private func run() {
        guard let url = destination else { return }
        running = true
        errorText = nil
        done = nil
        refresh()
        let ids = withPDF
        let ws = workspace
        // 拷 PDF 是 GB 级、慢卷上建库是秒级——主线程做必然转菊花
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let r = try ws.makeMirror(to: url, documentsWithPDF: ids) { s, f in
                    DispatchQueue.main.async { [weak self] in
                        self?.stepLabel.stringValue = s
                        self?.progress.doubleValue = f
                    }
                }
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.running = false
                    self.done = r
                    // 不进最近列表：副本挂到这个工作区那条记录上，由打开链路自动选用
                    if let folder = ws.folder {
                        WorkspaceRegistry.shared.setMirror(r.url.path, forSource: folder, id: ws.workspaceId)
                    }
                    self.refresh()
                }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    self?.running = false
                    self?.errorText = error.localizedDescription
                    self?.refresh()
                }
            }
        }
    }

    @objc private func close() { dismiss(self) }
    @objc private func revealExisting() { if let existing { NSWorkspace.shared.activateFileViewerSelecting([existing]) } }
    @objc private func revealDone() { if let u = done?.url { NSWorkspace.shared.activateFileViewerSelecting([u]) } }

    // 表格

    func numberOfRows(in tableView: NSTableView) -> Int { docs.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let d = docs[row]
        let check = NSButton(checkboxWithTitle: d.title, target: nil, action: nil)
        check.state = withPDF.contains(d.id) ? .on : .off
        check.lineBreakMode = .byTruncatingTail
        check.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        let id = d.id
        let acts = ButtonActions()
        acts.bind(check) { [weak self, weak check] in
            guard let self, let check else { return }
            if check.state == .on { self.withPDF.insert(id) } else { self.withPDF.remove(id) }
            self.recomputeEstimate()
        }
        objc_setAssociatedObject(check, &ButtonActions.key, acts, .OBJC_ASSOCIATION_RETAIN)
        var views: [NSView] = [check, SheetKit.spacer()]
        if !workspace.hasLocalFileCached(d.id) {
            let miss = NSTextField(labelWithString: L("file missing"))
            miss.font = .preferredFont(forTextStyle: .caption1)
            miss.textColor = .secondaryLabelColor
            views.append(miss)
        }
        let r = NSStackView(views: views)
        r.edgeInsets = NSEdgeInsets(top: 0, left: 4, bottom: 0, right: 6)
        return r
    }
}

// MARK: - 同步预览

/// 先干跑（**只算不写**）给用户看清「按下去会发生什么」，确认之后才应用。
/// **干跑与应用用的是同一份 Plan**，不重算——重算就意味着「用户看到的」和「实际做的」可能不是同一件事。
@MainActor
final class MirrorSyncController: StackPanelController, NSOutlineViewDataSource, NSOutlineViewDelegate {
    enum Side {
        case fromMirror                  // 我是副本，去找源盘
        case fromSource(mirror: URL)     // 我是源盘，副本在本机这个路径
    }

    let workspace: WorkspaceManager
    let side: Side
    /// 同步成功后回调「对面那份」的路径。副本侧的「同步并切回」靠它切窗口；菜单入口不传。
    let onSynced: ((URL) -> Void)?
    var onDismiss: () -> Void = {}

    private var searching = true
    private var sourceURL: URL?
    private var plan: MirrorDiff.Plan?
    private var lines: [MirrorReport.Line] = []
    private var headlineText = ""
    private var errorText: String?
    private var applying = false
    private var applied: MirrorApply.Result?

    private let searchRow = NSStackView()
    private let notConnected = NSStackView()
    private let summary = NSStackView()
    private let headlineLabel = NSTextField(labelWithString: "")
    private let outline = NSOutlineView()
    private var notWrittenLabel: NSTextField!
    private let progress = NSProgressIndicator()
    private let stepLabel = NSTextField(labelWithString: "")
    private let appliedBox = NSStackView()
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    private var syncButton: NSButton!

    init(workspace: WorkspaceManager, side: Side = .fromMirror, onSynced: ((URL) -> Void)? = nil) {
        self.workspace = workspace
        self.side = side
        self.onSynced = onSynced
        super.init(width: 480, inset: 20)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) 不支持") }

    private var inner: CGFloat { width - inset * 2 }

    private func callout(_ s: String, color: NSColor = .secondaryLabelColor) -> NSTextField {
        let t = NSTextField(wrappingLabelWithString: s)
        t.font = .preferredFont(forTextStyle: .callout)
        t.textColor = color
        t.preferredMaxLayoutWidth = inner
        return t
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        stack.spacing = 12
        stack.addArrangedSubview(headline(L("Sync Preview")))

        let spin = NSProgressIndicator()
        spin.style = .spinning
        spin.controlSize = .small
        spin.startAnimation(nil)
        searchRow.addArrangedSubview(spin)
        searchRow.addArrangedSubview(NSTextField(labelWithString: L("Looking for the source workspace…")))
        stack.addArrangedSubview(searchRow)

        notConnected.orientation = .vertical
        notConnected.alignment = .leading
        notConnected.spacing = 6
        notConnected.addArrangedSubview(NSTextField(labelWithString: "⚠︎ " + L("The source workspace isn’t connected.")))
        if !workspace.mirrorSourceHint.isEmpty {
            let hint = callout(String(format: L("Last seen at: %@"), workspace.mirrorSourceHint))
            hint.isSelectable = true
            notConnected.addArrangedSubview(hint)
        }
        stack.addArrangedSubview(notConnected)

        summary.orientation = .vertical
        summary.alignment = .leading
        summary.spacing = 12
        headlineLabel.font = .monospacedDigitSystemFont(ofSize: NSFont.preferredFont(forTextStyle: .callout).pointSize, weight: .regular)
        summary.addArrangedSubview(headlineLabel)
        let col = NSTableColumn(identifier: .init("line"))
        outline.addTableColumn(col)
        outline.outlineTableColumn = col
        outline.headerView = nil
        outline.dataSource = self
        outline.delegate = self
        outline.rowSizeStyle = .default
        outline.usesAutomaticRowHeights = true
        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        summary.addArrangedSubview(SheetKit.fixed(scroll, width: inner, height: 200))
        notWrittenLabel = callout(L("Nothing has been written yet."))
        summary.addArrangedSubview(notWrittenLabel)
        stepLabel.font = .preferredFont(forTextStyle: .callout)
        progress.isIndeterminate = false
        progress.minValue = 0
        progress.maxValue = 1
        summary.addArrangedSubview(stepLabel)
        summary.addArrangedSubview(SheetKit.fixed(progress, width: inner))
        appliedBox.orientation = .vertical
        appliedBox.alignment = .leading
        appliedBox.spacing = 6
        summary.addArrangedSubview(appliedBox)
        stack.addArrangedSubview(summary)

        errorLabel.font = .preferredFont(forTextStyle: .callout)
        errorLabel.textColor = .systemRed
        errorLabel.preferredMaxLayoutWidth = inner
        stack.addArrangedSubview(errorLabel)

        let done = NSButton(title: L("Done"), target: self, action: #selector(close))
        done.keyEquivalent = "\u{1b}"
        syncButton = NSButton(title: L("Sync…"), target: self, action: #selector(confirmSync))
        syncButton.keyEquivalent = "\r"
        stack.addArrangedSubview(SheetKit.hrow([SheetKit.spacer(), done, syncButton], width: inner))

        refresh()
        view.setFrameSize(preferredContentSize)
        start()
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        onDismiss()
    }

    private func refresh() {
        searchRow.isHidden = !searching
        notConnected.isHidden = searching || sourceURL != nil
        summary.isHidden = searching || sourceURL == nil
        headlineLabel.stringValue = headlineText
        notWrittenLabel.isHidden = applied != nil
        stepLabel.isHidden = !applying
        progress.isHidden = !applying
        for v in appliedBox.arrangedSubviews { v.removeFromSuperview() }
        if let a = applied {
            appliedBox.addArrangedSubview(callout("✓ " + String(format: L("Synced. Backup saved as %@"), a.backup?.lastPathComponent ?? "—"),
                                                  color: .labelColor))
            // 静默丢行是绝对不行的：哪怕只有一条，也要让用户知道，还要说清怎么办
            if a.orphansSkipped > 0 {
                appliedBox.addArrangedSubview(callout("⚠︎ " + String(format: L("%d rows were skipped: their document no longer exists."),
                                                                      a.orphansSkipped), color: .systemOrange))
            }
            if a.hashClashesSkipped > 0 {
                appliedBox.addArrangedSubview(callout("⚠︎ " + String(format: L("%d versions were skipped: the other side already has the same file. Use “Link as Same Document” to merge them."),
                                                                      a.hashClashesSkipped), color: .systemOrange))
            }
            if a.pathClashesSkipped > 0 {
                appliedBox.addArrangedSubview(callout("⚠︎ " + String(format: L("%d notes were skipped: the other side already has a note at the same path."),
                                                                      a.pathClashesSkipped), color: .systemOrange))
            }
        }
        appliedBox.isHidden = applied == nil
        errorLabel.isHidden = errorText == nil
        errorLabel.stringValue = errorText.map { "✕ " + $0 } ?? ""
        syncButton.isHidden = !(plan.map { !$0.isEmpty } ?? false) || applied != nil
        syncButton.isEnabled = !applying
        resize()
    }

    private func start() {
        switch side {
        case .fromSource(let mirror):
            sourceURL = mirror   // 副本就在本机，没有「找不找得到」这回事
            dryRun(mirror)
        case .fromMirror:
            guard let id = workspace.mirrorSourceId else { searching = false; refresh(); return }
            // 候选给的是源盘那份：副本自己不可能是自己的源
            let recents = WorkspaceRegistry.shared.recents.map { URL(fileURLWithPath: $0.sourcePath) }
            DispatchQueue.global(qos: .userInitiated).async {
                let found = WorkspaceManager.findMirrorSource(id: id, recents: recents)
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    guard let found else { self.searching = false; self.refresh(); return }
                    self.sourceURL = found
                    self.dryRun(found)
                }
            }
        }
    }

    private func dryRun(_ other: URL) {
        let ws = workspace, side = side
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let dry: WorkspaceManager.DryRun
                switch side {
                case .fromMirror: dry = try ws.mirrorDryRun(sourceFolder: other)
                case .fromSource: dry = try ws.mirrorDryRunFromSource(mirrorFolder: other)
                }
                let ls = MirrorReport.summary(dry.plan, titles: dry.titles, hashTitles: dry.hashTitles)
                let hl = MirrorReport.headline(dry.plan)
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.plan = dry.plan
                    self.lines = ls
                    self.headlineText = hl
                    self.searching = false
                    self.outline.reloadData()
                    self.refresh()
                }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    self?.searching = false
                    self?.errorText = error.localizedDescription
                    self?.refresh()
                }
            }
        }
    }

    /// 这一步会大批量改用户数据——不给「直接执行」的入口，必须再点一次。
    @objc private func confirmSync() {
        guard let win = view.window else { return }
        let a = NSAlert()
        a.messageText = L("Apply this merge?")
        a.informativeText = L("The source library is backed up first; the three most recent backups are kept.")
        a.addButton(withTitle: L("Sync")).hasDestructiveAction = true
        a.addButton(withTitle: L("Cancel"))
        a.beginSheetModal(for: win) { [weak self] resp in
            if resp == .alertFirstButtonReturn { self?.applyNow() }
        }
    }

    private func applyNow() {
        guard let other = sourceURL, let p = plan else { return }
        applying = true
        errorText = nil
        refresh()
        let ws = workspace, side = side
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let progress: (String, Double) -> Void = { s, f in
                    DispatchQueue.main.async { [weak self] in
                        self?.stepLabel.stringValue = s
                        self?.progress.doubleValue = f
                    }
                }
                let r: MirrorApply.Result
                switch side {
                case .fromMirror: r = try ws.mirrorApply(sourceFolder: other, plan: p, progress: progress)
                case .fromSource: r = try ws.mirrorApplyFromSource(mirrorFolder: other, plan: p, progress: progress)
                }
                // 合并完不再重算报告（2026-09-01 删）：屏幕上留着「刚才做了什么」更贴合用户此刻要确认的事
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.applying = false
                    self.applied = r
                    self.refresh()
                    // 「同步并切回」会关掉本窗口（连同它的 store）——先把面板收起来再交棒
                    if let cb = self.onSynced {
                        self.dismiss(self)
                        cb(other)
                    }
                }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    self?.applying = false
                    self?.errorText = error.localizedDescription
                    self?.refresh()
                }
            }
        }
    }

    @objc private func close() { dismiss(self) }

    // 报告：每条一行，有细节的可展开

    private final class LineItem {
        let text: String
        let detail: [String]
        init(_ t: String, _ d: [String]) { text = t; detail = d }
    }
    private var items: [LineItem] = []

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if item == nil {
            items = lines.map { LineItem($0.text, $0.detail) }
            return items.count
        }
        return (item as? LineItem)?.detail.count ?? 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if let li = item as? LineItem { return li.detail[index] as NSString }
        return items[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? LineItem).map { !$0.detail.isEmpty } ?? false
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        let t: NSTextField
        if let li = item as? LineItem {
            t = NSTextField(wrappingLabelWithString: li.text)
        } else {
            t = NSTextField(wrappingLabelWithString: (item as? String) ?? "")
            t.font = .preferredFont(forTextStyle: .callout)
        }
        t.preferredMaxLayoutWidth = inner - 40
        return t
    }
}
