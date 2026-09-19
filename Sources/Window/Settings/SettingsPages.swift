import AppKit
import Combine

/// 设置窗的标签页；顺序即标题栏里的顺序。
enum SettingsTab: CaseIterable {
    case general, tablet, reading, shortcuts, agent, diagnostics

    var title: String {
        switch self {
        case .general: return L("General")
        case .tablet: return L("Tablet")
        case .reading: return L("Reading")
        case .shortcuts: return L("Shortcuts")
        case .agent: return L("Agent")
        case .diagnostics: return L("Diagnostics")
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gear"
        case .tablet: return "ipad"
        case .reading: return "book"
        case .shortcuts: return "keyboard"
        case .agent: return "terminal"
        case .diagnostics: return "stopwatch"
        }
    }

    @MainActor
    func makePage(app: AppModel) -> SettingsPage {
        switch self {
        case .general: return GeneralSettingsPage()
        case .tablet: return TabletSettingsPage(app: app)
        case .reading: return ReadingSettingsPage()
        case .shortcuts: return ShortcutsSettingsPage()
        case .agent: return MCPSettingsPage(mcp: app.mcp)
        case .diagnostics: return DiagnosticsSettingsPage()
        }
    }
}

private var defaults: UserDefaults { .standard }

// MARK: - 通用：外观 / 更新 / AI 开关 / 工具栏指路 / 图片笔记

final class GeneralSettingsPage: SettingsPage {
    private let updater = UpdaterService.shared
    private var bag = Set<AnyCancellable>()
    private var updates: FormSection!
    private var ai: FormSection!
    private var images: FormSection!

    override func build() {
        let appearance = section(L("Appearance"), footer: L("When on, Night Mode follows the system appearance automatically."))
        appearance.row(nil, FormCheckbox(L("Auto Night Mode (follow system Dark Mode)"), on: defaults.bool(forKey: "autoNightMode")) {
            defaults.set($0, forKey: "autoNightMode")
        })

        updates = section(L("Updates"), footer: L("Updates are signed with EdDSA, downloaded over HTTPS, and installed by Sparkle's helper."))
        updates.dynamic { [weak self] s in self?.buildUpdates(s) }
        updater.objectWillChange.receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updates.rebuild() }.store(in: &bag)

        // 两种 AI 各自一个总开关（用户 2026-09-19）
        ai = section(L("AI"), footer: L("Turning one off hides its toolbar button and menu item, and ⌥-drag screenshots are no longer offered to it. Open panels and running agents are closed."))
        ai.dynamic { s in
            s.row(nil, FormCheckbox(L("Agent Panel"), on: AgentPanelModel.shared.enabled) { AgentPanelModel.shared.setEnabled($0) })
            s.row(nil, FormCheckbox(L("Web AI Panel"), on: AIPanelModel.shared.enabled) { AIPanelModel.shared.setEnabled($0) })
        }
        AgentPanelModel.shared.objectWillChange.merge(with: AIPanelModel.shared.objectWillChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.ai.rebuild() }.store(in: &bag)

        // 工具栏的显隐 / 排序走系统那套（自定义工具栏），这里只留一句指路
        let toolbar = section(L("Toolbar"))
        toolbar.full(FormSection.caption(L("Right-click the toolbar in a reading window and choose “Customize Toolbar…” to add, remove or rearrange buttons.")))

        // 图片笔记的图片本体：按此刻开着的工作区逐个列一行，每秒重算
        images = section(L("Image Notes"), footer: L("Images live inside the workspace package. An image whose notes are all deleted becomes pending; it is removed for good 30 days later (undo the deletion before then to keep it)."))
        images.dynamic { s in
            let managers = WorkspaceRegistry.shared.openManagers
            if managers.isEmpty {
                s.full(FormSection.text(L("No workspace is open."), color: .secondaryLabelColor))
            }
            for ws in managers {
                let st = ws.imageStats()
                let clean = FormButton(L("Clean Up Now")) { _ = ws.purgeImagesNow() }
                clean.isEnabled = st.orphaned > 0
                s.row(ws.name, detail: String(format: L("%d images · %d pending deletion · %@"), st.total, st.orphaned,
                                              ByteCountFormatter.string(fromByteCount: st.bytes, countStyle: .file)), clean)
            }
        }
        everySecond { [weak self] in self?.images.rebuild() }
    }

    /// 频率选项（秒）。Sparkle 下限 1 小时，所以最小给到每小时。
    private static let intervals: [(String, TimeInterval)] = [(L("Hourly"), 3600), (L("Daily"), 86400), (L("Weekly"), 604800)]

    private func buildUpdates(_ s: FormSection) {
        s.row(nil, FormCheckbox(L("Automatically check for updates"), on: updater.autoCheck) { [weak self] in self?.updater.autoCheck = $0 })
        // 当前间隔吸附到最近的预设选项（非预设值会让下拉框显示空白）
        let cur = updater.checkInterval
        let snapped = Self.intervals.min { abs($0.1 - cur) < abs($1.1 - cur) }?.1 ?? 86400
        let freq = FormPopup(Self.intervals, selected: snapped) { [weak self] in self?.updater.setUpdateInterval($0) }
        freq.isEnabled = updater.autoCheck
        s.row(L("Check frequency"), freq)
        s.row(L("Current version"), FormSection.text("\(updater.currentVersion) (\(updater.currentBuild))"))
        s.row(L("Last checked"), FormSection.text(updater.lastChecked?.formatted(date: .abbreviated, time: .shortened) ?? L("Never")))
        let check = FormButton(L("Check Now")) { [weak self] in self?.updater.checkForUpdates() }
        check.isEnabled = updater.canCheck
        s.row(nil, check)
    }
}

// MARK: - 平板：滚动跟随算法 + 服务开机自启

final class TabletSettingsPage: SettingsPage {
    let app: AppModel
    init(app: AppModel) {
        self.app = app
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) 不支持") }

    override func build() {
        let follow = section(L("Tablet Scroll Follow"), footer: L("Interpolation tracks fast flings tighter; Low-pass is simpler and smoother on LAN."))
        let interp = defaults.object(forKey: "scrollInterp") as? Bool ?? true
        follow.row(L("Delay handling"), FormPopup([(L("Interpolation"), true), (L("Low-pass"), false)], selected: interp) {
            defaults.set($0, forKey: "scrollInterp")
        })
        let service = section(L("Tablet Service"))
        service.row(nil, FormCheckbox(L("Start tablet service on launch"), on: defaults.bool(forKey: "autoStartServer")) { [app] on in
            defaults.set(on, forKey: "autoStartServer")
            if on, !app.server.isRunning { app.server.start() }   // 打开即启，立即生效
        })
    }
}

// MARK: - 阅读：笔记气泡 / 搜索 / 文字选择 / 渲染缓存与内存台账 / OCR

final class ReadingSettingsPage: SettingsPage {
    private var memory: FormSection!
    private var ocr: FormSection!
    private var minStepper: NSStepper!
    private var maxStepper: NSStepper!
    private var minLabel: NSTextField!
    private var maxLabel: NSTextField!

    override func build() {
        // 笔记气泡的尺寸口径：默认固定尺寸；打开 = 「跟页缩放」。字号两档分开设（气泡是看的、编辑框是写的）
        let notes = section(L("Notes"), footer: L("Text size and widths apply to expanded text and image notes on the page; a short note shrinks to its content between the min and max width. Editor size applies to the note editor. Follow page zoom off: bubbles keep a fixed size on screen; on: they scale with the page, like on the tablet."))
        let sizes = NoteBubble.fontSizeChoices.map { ("\($0) pt", $0) }
        let bubbleFont = defaults.object(forKey: NoteBubble.fontSizeKey) as? Int ?? Int(NoteBubble.fixedFont)
        notes.row(L("Note bubble text size"), FormPopup(sizes, selected: bubbleFont) { defaults.set($0, forKey: NoteBubble.fontSizeKey) })
        let editorFont = defaults.object(forKey: NoteBubble.editorFontSizeKey) as? Int ?? Int(NoteBubble.defaultEditorFont)
        notes.row(L("Note editor text size"), FormPopup(sizes, selected: editorFont) { defaults.set($0, forKey: NoteBubble.editorFontSizeKey) })
        // 宽度：两个数互相钳住，最小永远不超过最大
        (minStepper, minLabel) = widthStepper(key: NoteBubble.minWidthKey, fallback: Int(NoteBubble.fixedMinWidth))
        (maxStepper, maxLabel) = widthStepper(key: NoteBubble.maxWidthKey, fallback: Int(NoteBubble.fixedMaxWidth))
        notes.row(L("Note bubble min width"), FormSection.hstack([minLabel, minStepper]))
        notes.row(L("Note bubble max width"), FormSection.hstack([maxLabel, maxStepper]))
        notes.row(nil, FormCheckbox(L("Note bubbles follow page zoom"), on: defaults.bool(forKey: NoteBubble.followsZoomKey)) {
            defaults.set($0, forKey: NoteBubble.followsZoomKey)
        })

        let search = section(L("Search"), footer: L("When switching between search matches, briefly flash the current match to help you spot it. Off: the match is highlighted directly with no animation."))
        search.row(nil, FormCheckbox(L("Flash active search match"), on: defaults.object(forKey: "matchPulseEnabled") as? Bool ?? true) {
            defaults.set($0, forKey: "matchPulseEnabled")
        })

        let selection = section(L("Text Selection"), footer: L("When ⌘-dragging a new box over text you already selected: Merge keeps the existing selection and only adds the new part. Invert deselects the overlapping part instead, like ⌘-dragging a fresh rubber band in Finder's icon view."))
        let merge = defaults.object(forKey: "boxSelectOverlapMerge") as? Bool ?? true
        selection.row(L("Overlapping box selection"), FormPopup([(L("Merge"), true), (L("Invert"), false)], selected: merge) {
            defaults.set($0, forKey: "boxSelectOverlapMerge")
        })

        // ⚠️ 默认值 256 与启动时那句 `?? 256` 必须一致
        let rendering = section(L("Rendering"), footer: L("The limit covers all page bitmaps in memory: those shown in windows plus the cache; the cache yields room to what windows hold. Every bitmap also has a CoreAnimation copy of the same size, already counted here."))
        let cacheMB = defaults.object(forKey: "renderCacheMB") as? Int ?? 256
        rendering.row(L("Page render cache limit"), FormPopup([("128 MB", 128), ("256 MB", 256), ("512 MB", 512), ("1 GB", 1024)],
                                                              selected: cacheMB) { mb in
            defaults.set(mb, forKey: "renderCacheMB")
            PageRenderEngine.shared.setCacheLimitMB(mb)
        })
        memory = section(nil)
        memory.dynamic { [weak self] s in self?.buildMemory(s) }
        everySecond { [weak self] in self?.memory.rebuild() }

        ocr = section(L("Text Recognition (OCR)"), footer: L("For scanned or bad-text PDFs, use API OCR for accurate selectable/searchable text. The key is stored in this Mac's Keychain."))
        ocr.dynamic { [weak self] s in self?.buildOCR(s) }
    }

    private func widthStepper(key: String, fallback: Int) -> (NSStepper, NSTextField) {
        let v = defaults.object(forKey: key) as? Int ?? fallback
        let st = NSStepper()
        st.minValue = Double(NoteBubble.widthRange.lowerBound)
        st.maxValue = Double(NoteBubble.widthRange.upperBound)
        st.increment = Double(NoteBubble.widthStep)
        st.integerValue = v
        st.target = self
        st.action = #selector(widthChanged(_:))
        let l = NSTextField(labelWithString: "\(v) pt")
        l.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        return (st, l)
    }

    @objc private func widthChanged(_ sender: NSStepper) {
        var lo = minStepper.integerValue, hi = maxStepper.integerValue
        if sender === minStepper, hi < lo { hi = lo }
        if sender === maxStepper, lo > hi { lo = hi }
        minStepper.integerValue = lo
        maxStepper.integerValue = hi
        minLabel.stringValue = "\(lo) pt"
        maxLabel.stringValue = "\(hi) pt"
        defaults.set(lo, forKey: NoteBubble.minWidthKey)
        defaults.set(hi, forKey: NoteBubble.maxWidthKey)
    }

    /// 真实内存台账（`MemoryDiag`）：进程总量 → 页位图（存活 / 缓存 / 各窗口持有）→ 堆。每一行都是量出来的数。
    private func buildMemory(_ s: FormSection) {
        let snap = MemoryDiag.snapshot()
        let mb = MemoryDiag.mb
        s.row(L("App memory (Activity Monitor)"), FormSection.text(mb(snap.footprint)))
        s.row(L("Page bitmaps alive"), FormSection.text("\(snap.liveCount) · \(mb(snap.bitmapFootprint))"))
        s.row(L("In cache"), FormSection.text("\(snap.cacheBaseCount)+\(snap.cacheTileCount) · \(mb(snap.cacheBaseBytes + snap.cacheTileBytes))"
                                            + " · \(L("room")) \(mb(snap.cacheEffectiveBytes / PageRenderEngine.copiesPerImage))"))
        s.row(L("Held by windows"), FormSection.text("\(snap.heldCount) · \(mb(snap.heldBytes))"))
        for h in snap.holdings {
            s.row((h.active ? "● " : "○ ") + holdingLabel(h), FormSection.text(holdingValue(h)))
        }
        s.row(L("Heap (malloc)"), FormSection.text("\(mb(snap.mallocUsed)) · \(L("freed, not yet returned")) \(mb(snap.mallocRetained))"))
        s.row(L("Memory figures as text"), FormButton(L("Copy")) {
            copyToPasteboard("\(Date.now.formatted(date: .numeric, time: .standard))\n" + MemoryDiag.report())
        })
    }

    private func holdingLabel(_ h: PageHolding) -> String {
        switch h.kind {
        case .reader: return h.label
        case .ref: return L("Reference window") + " · " + h.label
        case .thumbs: return L("Thumbnails") + " · " + h.label
        }
    }

    private func holdingValue(_ h: PageHolding) -> String {
        let mb = MemoryDiag.mb
        var parts: [String] = []
        if let r = h.realized { parts.append("p\(r.lowerBound + 1)–\(r.upperBound + 1)") }
        parts.append("\(h.imageCount) \(L("img")) \(mb(h.imageBytes))")
        if h.tileCount > 0 { parts.append("\(h.tileCount) \(L("tile")) \(mb(h.tileBytes))") }
        if h.snapCount > 0 { parts.append("\(h.snapCount) \(L("snap")) \(mb(h.snapBytes))") }
        return parts.joined(separator: " · ")
    }

    private func buildOCR(_ s: FormSection) {
        let engine = defaults.string(forKey: "ocrEngine") ?? "off"
        s.row(L("OCR Engine"), FormPopup([(L("Off"), "off"), (L("Paddle OCR (API)"), "paddle")], selected: engine) { [weak self] v in
            defaults.set(v, forKey: "ocrEngine")
            self?.ocr.rebuild()
        })
        if engine == "paddle" {
            let key = NSSecureTextField(string: PaddleOCR.apiKey())
            key.placeholderString = L("Paddle API Key")
            key.delegate = self
            key.widthAnchor.constraint(equalToConstant: FormMetrics.controlWidth).isActive = true
            s.row(L("Paddle API Key"), key)
        }
    }
}

extension ReadingSettingsPage: NSTextFieldDelegate {
    /// API key 存 Keychain（不进 UserDefaults），边输边存。
    func controlTextDidChange(_ obj: Notification) {
        guard let f = obj.object as? NSSecureTextField else { return }
        PaddleOCR.setApiKey(f.stringValue)
    }
}

// MARK: - 诊断：最近几次「打开 / 切标签」的耗时

final class DiagnosticsSettingsPage: SettingsPage {
    private var list: FormSection!
    private var expanded = Set<UUID>()
    private var shownIDs: [UUID] = []

    override func build() {
        list = section(L("Open timings (recent)"), footer: L("Measured from the click until every visible page shows its image and ink. Phases are the synchronous load steps; marks are milestones since the click. The same summary lines go to ~/Library/Logs/UniReader-ws.log when that file exists."))
        list.dynamic { [weak self] s in self?.buildList(s) }
        everySecond { [weak self] in
            guard let self else { return }
            let ids = OpenStats.records.map(\.id)
            if ids != self.shownIDs { self.list.rebuild() }   // 记录没变就不重排（免得打断展开 / 选字）
        }
    }

    private func buildList(_ s: FormSection) {
        let recs = OpenStats.records
        shownIDs = recs.map(\.id)
        let copy = FormButton(L("Copy")) {
            copyToPasteboard(recs.map { "\($0.startedAt.formatted(date: .numeric, time: .standard)) \($0.summary)" }
                .joined(separator: "\n"))
        }
        copy.isEnabled = !recs.isEmpty
        s.row(L("All records as text (one line per open)"), copy)
        if recs.isEmpty {
            s.full(FormSection.text(L("No document opened yet in this session."), color: .secondaryLabelColor))
            return
        }
        for r in recs {
            let open = expanded.contains(r.id)
            let head = NSButton(title: "\(r.startedAt.formatted(date: .omitted, time: .standard)) · \(r.title) · \(r.reason)",
                                target: nil, action: nil)
            head.setButtonType(.pushOnPushOff)
            head.bezelStyle = .disclosure
            head.imagePosition = .imageLeading
            head.isBordered = false
            head.state = open ? .on : .off
            head.lineBreakMode = .byTruncatingTail
            let id = r.id
            let acts = ButtonActions()
            acts.bind(head) { [weak self] in
                guard let self else { return }
                if self.expanded.contains(id) { self.expanded.remove(id) } else { self.expanded.insert(id) }
                self.list.rebuild()
            }
            objc_setAssociatedObject(head, &ButtonActions.key, acts, .OBJC_ASSOCIATION_RETAIN)
            let total = NSTextField(labelWithString: "\(Int(r.totalMs.rounded())) ms")
            total.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            head.setContentCompressionResistancePriority(.init(1), for: .horizontal)
            let row = FormSection.hstack([head, NSView(), total])
            row.translatesAutoresizingMaskIntoConstraints = false
            row.widthAnchor.constraint(equalToConstant: FormMetrics.columnWidth).isActive = true
            s.full(row)
            guard open else { continue }
            s.row(L("Outcome"), FormSection.text(r.outcome))
            s.row(L("Load"), FormSection.text("\(Int(r.loadMs.rounded())) ms"))
            for p in r.phases {
                s.row("　" + p.name, FormSection.text("\(Int(p.ms.rounded())) ms" + (p.detail.isEmpty ? "" : " · \(p.detail)")))
            }
            for m in r.marks {
                s.row(m.name, FormSection.text("+\(Int(m.atMs.rounded())) ms" + (m.detail.isEmpty ? "" : " · \(m.detail)")))
            }
            s.row(L("Pages"), FormSection.text(r.imagesLine))
            s.row(L("Ink"), FormSection.text(r.inkLine))
        }
    }
}
