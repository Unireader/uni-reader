import AppKit

// 连接服务器的两张面板（方案 `SERVER-MODE-PLAN.md §2`）：**从服务器打开** 与 **上传到服务器**。
// 都是系统标准控件；文字一律显式 `labelColor`（红线④）。

// MARK: - 从服务器打开

/// 选一台服务器上的一个工作区：本机已有缓存就直接打开，没有就先下载库（PDF 用到再下）。
@MainActor
final class OpenFromServerController: StackPanelController, NSTableViewDataSource, NSTableViewDelegate {
    private var accounts: [ServerAccount] = []
    private var workspaces: [ServerClient.WorkspaceInfo] = []
    private var cached: Set<String> = []
    private var loadToken = 0
    private var running = false

    private let accountPopup = NSPopUpButton()
    private let table = NSTableView()
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let progress = NSProgressIndicator()
    private var openButton: NSButton!

    init() { super.init(width: 440, inset: 20) }
    required init?(coder: NSCoder) { fatalError("init(coder:) 不支持") }

    private var inner: CGFloat { width - inset * 2 }

    override func viewDidLoad() {
        super.viewDidLoad()
        stack.spacing = 12
        accounts = ServerAccounts.shared.all
        stack.addArrangedSubview(headline(L("Open from Server")))

        guard !accounts.isEmpty else {
            stack.addArrangedSubview(caption(L("This Mac isn’t connected to any server yet. Connect one in Settings › Servers first."),
                                             color: .labelColor))
            let settings = NSButton(title: L("Open Settings…"), target: self, action: #selector(openSettings))
            stack.addArrangedSubview(SheetKit.hrow([SheetKit.spacer(), SheetKit.cancelButton(self, #selector(close)), settings],
                                                   width: inner))
            view.setFrameSize(preferredContentSize)
            return
        }

        if accounts.count > 1 {
            for a in accounts { accountPopup.addItem(withTitle: a.url) }
            accountPopup.target = self
            accountPopup.action = #selector(accountChanged)
            stack.addArrangedSubview(accountPopup)
        } else {
            stack.addArrangedSubview(caption(accounts[0].url, color: .labelColor))
        }

        let col = NSTableColumn(identifier: .init("ws"))
        table.addTableColumn(col)
        table.headerView = nil
        table.rowHeight = 24
        table.dataSource = self
        table.delegate = self
        table.usesAlternatingRowBackgroundColors = true
        table.target = self
        table.doubleAction = #selector(open)
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        stack.addArrangedSubview(SheetKit.fixed(scroll, width: inner, height: 200))

        statusLabel.font = .preferredFont(forTextStyle: .callout)
        statusLabel.textColor = .labelColor
        statusLabel.preferredMaxLayoutWidth = inner
        stack.addArrangedSubview(statusLabel)
        progress.style = .spinning
        progress.controlSize = .small
        progress.isDisplayedWhenStopped = false

        openButton = SheetKit.primaryButton(L("Open"), self, #selector(open))
        stack.addArrangedSubview(SheetKit.hrow([progress, SheetKit.spacer(), SheetKit.cancelButton(self, #selector(close)), openButton],
                                               width: inner))
        load()
        view.setFrameSize(preferredContentSize)
    }

    private var account: ServerAccount? {
        accounts.indices.contains(accountPopup.indexOfSelectedItem) ? accounts[accountPopup.indexOfSelectedItem]
            : accounts.first
    }

    @objc private func accountChanged() { load() }

    private func load() {
        guard let a = account, let client = ServerAccounts.shared.client(a) else {
            setStatus(ServerSyncError.noAccount.localizedDescription)
            return
        }
        loadToken += 1
        let token = loadToken
        workspaces = []
        table.reloadData()
        setStatus(L("Loading…"))
        progress.startAnimation(nil)
        Task {
            do {
                let list = try await client.workspaces()
                let local = await Task.detached { Set(list.filter { ServerSyncIO.findCache(workspaceId: $0.id) != nil }.map(\.id)) }.value
                guard token == self.loadToken else { return }
                self.workspaces = list
                self.cached = local
                self.table.reloadData()
                if !list.isEmpty { self.table.selectRowIndexes([0], byExtendingSelection: false) }
                self.setStatus(list.isEmpty ? L("This server has no workspaces yet. Upload one from the workspace menu.") : "")
            } catch {
                guard token == self.loadToken else { return }
                self.setStatus(error.localizedDescription)
            }
            if token == self.loadToken { self.progress.stopAnimation(nil) }
            self.refreshButtons()
        }
    }

    @objc private func open() {
        guard !running, let a = account, workspaces.indices.contains(table.selectedRow) else { return }
        let ws = workspaces[table.selectedRow]
        running = true
        refreshButtons()
        progress.startAnimation(nil)
        Task {
            do {
                let folder = try await ServerSyncCoordinator.shared.openFromServer(a, ws) { [weak self] step in
                    self?.setStatus(step)
                }
                try WorkspaceRegistry.shared.route(to: folder, strict: true)
                self.dismiss(nil)
            } catch {
                self.setStatus(error.localizedDescription)
                self.running = false
                self.progress.stopAnimation(nil)
                self.refreshButtons()
            }
        }
    }

    @objc private func openSettings() {
        dismiss(nil)
        SettingsWindowController.show(tab: .servers)
    }

    @objc private func close() { dismiss(nil) }

    private func setStatus(_ s: String) {
        statusLabel.stringValue = s
        statusLabel.isHidden = s.isEmpty
        resize()
    }

    private func refreshButtons() {
        openButton?.isEnabled = !running && workspaces.indices.contains(table.selectedRow)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { workspaces.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let ws = workspaces[row]
        let name = NSTextField(labelWithString: ws.name.isEmpty ? L("Untitled Workspace") : ws.name)
        name.textColor = .labelColor
        name.lineBreakMode = .byTruncatingTail
        var views: [NSView] = [name, SheetKit.spacer()]
        if cached.contains(ws.id) {
            let mark = NSTextField(labelWithString: L("On this Mac"))
            mark.font = .preferredFont(forTextStyle: .callout)
            mark.textColor = .labelColor
            views.append(mark)
        }
        let row = NSStackView(views: views)
        row.edgeInsets = NSEdgeInsets(top: 0, left: 4, bottom: 0, right: 4)
        return row
    }

    func tableViewSelectionDidChange(_ notification: Notification) { refreshButtons() }
}

// MARK: - 上传到服务器

/// 把当前这个本地工作区传到服务器；传完它就是那个服务器工作区在本机的缓存（方案 §5）。
@MainActor
final class UploadToServerController: StackPanelController {
    let workspace: WorkspaceManager
    private var accounts: [ServerAccount] = []
    private var task: Task<Void, Never>?
    private var finished = false

    private let accountPopup = NSPopUpButton()
    private let progress = NSProgressIndicator()
    private let stepLabel = NSTextField(labelWithString: "")
    private let resultLabel = NSTextField(wrappingLabelWithString: "")
    private var cancelButton: NSButton!
    private var uploadButton: NSButton!

    init(workspace: WorkspaceManager) {
        self.workspace = workspace
        super.init(width: 440, inset: 20)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) 不支持") }

    private var inner: CGFloat { width - inset * 2 }

    override func viewDidLoad() {
        super.viewDidLoad()
        stack.spacing = 12
        accounts = ServerAccounts.shared.all
        stack.addArrangedSubview(headline(String(format: L("Upload “%@” to a Server"), workspace.name)))

        guard !accounts.isEmpty else {
            stack.addArrangedSubview(caption(L("This Mac isn’t connected to any server yet. Connect one in Settings › Servers first."),
                                             color: .labelColor))
            let settings = NSButton(title: L("Open Settings…"), target: self, action: #selector(openSettings))
            stack.addArrangedSubview(SheetKit.hrow([SheetKit.spacer(), SheetKit.cancelButton(self, #selector(close)), settings],
                                                   width: inner))
            view.setFrameSize(preferredContentSize)
            return
        }

        stack.addArrangedSubview(caption(L("The library, the PDFs and images it uses, and the notes in Notes/ are uploaded. PDFs referenced from outside the workspace are uploaded too. Afterwards this workspace stays where it is and becomes this Mac’s copy of the server workspace: it syncs when you open and close it."),
                                         color: .labelColor))
        if accounts.count > 1 {
            for a in accounts { accountPopup.addItem(withTitle: a.url) }
            stack.addArrangedSubview(accountPopup)
        } else {
            stack.addArrangedSubview(caption(String(format: L("Server: %@"), accounts[0].url), color: .labelColor))
        }

        stepLabel.font = .preferredFont(forTextStyle: .callout)
        stepLabel.textColor = .labelColor
        stack.addArrangedSubview(stepLabel)
        progress.isIndeterminate = false
        progress.minValue = 0
        progress.maxValue = 1
        stack.addArrangedSubview(SheetKit.fixed(progress, width: inner))
        resultLabel.font = .preferredFont(forTextStyle: .callout)
        resultLabel.textColor = .labelColor
        resultLabel.preferredMaxLayoutWidth = inner
        stack.addArrangedSubview(resultLabel)

        cancelButton = SheetKit.cancelButton(self, #selector(close))
        uploadButton = SheetKit.primaryButton(L("Upload"), self, #selector(upload))
        stack.addArrangedSubview(SheetKit.hrow([SheetKit.spacer(), cancelButton, uploadButton], width: inner))
        stepLabel.isHidden = true
        progress.isHidden = true
        resultLabel.isHidden = true
        view.setFrameSize(preferredContentSize)
    }

    @objc private func upload() {
        guard task == nil, !finished else { close(); return }
        let a = accounts.indices.contains(accountPopup.indexOfSelectedItem) ? accounts[accountPopup.indexOfSelectedItem]
            : accounts[0]
        uploadButton.isEnabled = false
        accountPopup.isEnabled = false
        stepLabel.isHidden = false
        progress.isHidden = false
        resultLabel.isHidden = true
        resize()
        task = Task {
            do {
                let (ws, missing) = try await ServerSyncCoordinator.shared.upload(workspace, to: a) { [weak self] step, fraction in
                    self?.stepLabel.stringValue = step
                    self?.progress.doubleValue = fraction
                }
                var text = String(format: L("Uploaded. “%@” is now on the server and this workspace syncs with it."), ws.name)
                if missing > 0 {
                    text += "\n" + String(format: L("%d books had no PDF on this Mac, so only their notes were uploaded."), missing)
                }
                self.finish(text, ok: true)
            } catch is CancellationError {
                self.finish(L("Upload cancelled."), ok: false)
            } catch {
                self.finish(error.localizedDescription, ok: false)
            }
        }
    }

    private func finish(_ text: String, ok: Bool) {
        task = nil
        finished = ok
        stepLabel.isHidden = true
        progress.isHidden = true
        resultLabel.stringValue = text
        resultLabel.textColor = ok ? .labelColor : .systemRed
        resultLabel.isHidden = false
        uploadButton.title = ok ? L("Done") : L("Upload")
        uploadButton.isEnabled = true
        accountPopup.isEnabled = !ok
        cancelButton.isHidden = ok
        resize()
    }

    @objc private func openSettings() {
        dismiss(nil)
        SettingsWindowController.show(tab: .servers)
    }

    @objc private func close() {
        task?.cancel()
        dismiss(nil)
    }
}
