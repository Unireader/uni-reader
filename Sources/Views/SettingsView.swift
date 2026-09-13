import AppKit
import SwiftUI

/// 设置窗的标签页；顺序即标题栏里的顺序。图标/文案放这里，窗口壳（`SettingsTabController`）直接取用。
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
}

/// 标准设置页（⌘,）的**一页**内容：持久化到 UserDefaults，全窗口共享。
/// 例外：API key 这类密钥存 Keychain（见 `PaddleOCR.apiKey()`），不落 UserDefaults 明文。
///
/// 标签条不在这里：分页由 AppKit 的 `NSTabViewController`（`.toolbar` 样式）管，标签住在标题栏里，
/// 与系统各 app 的设置窗同款（见 `SettingsTabController`）。之前用 SwiftUI `TabView`：装进普通
/// `NSWindow` 后它把标签条画在标题栏**下面**、自带一层更浅的底色和分隔线，两条灰叠着像错位。
/// 尺寸也由窗口管（初始大小 / 最小值 / 可缩放 / 记住用户拖过的大小），这里不定 frame。
struct SettingsView: View {
    let tab: SettingsTab

    @EnvironmentObject private var app: AppModel

    @AppStorage("autoNightMode") private var autoNightMode = false
    @AppStorage("scrollInterp") private var scrollInterp = true      // true=时间戳插值 / false=纯低通
    @AppStorage("autoStartServer") private var autoStartServer = false
    @AppStorage("ocrEngine") private var ocrEngine = "off"          // "off" | "paddle"
    @State private var ocrPaddleKey = ""   // Paddle API key：存 Keychain（不进 UserDefaults），见 PaddleOCR.apiKey()
    /// 页图缓存上限（MB，= 真实占用；引擎按「一张图三份」计费，见 `PageRenderEngine.copiesPerImage`）。
    /// ⚠️ 默认值与 `ContentView` 启动时那句 `?? 256` **必须一致**，改一处要改两处。
    @AppStorage("renderCacheMB") private var renderCacheMB = 256
    /// 笔记气泡跟不跟页缩放（默认关 = 固定尺寸；阅读区 `ReaderSurface` 读同一个键）。
    @AppStorage(NoteBubble.followsZoomKey) private var bubbleFollowsZoom = false
    /// 气泡正文字号 / 编辑框字号（阅读区与 `MarkdownNoteEditor` 各读自己那个键）。
    @AppStorage(NoteBubble.fontSizeKey) private var bubbleFontSize = Int(NoteBubble.fixedFont)
    @AppStorage(NoteBubble.editorFontSizeKey) private var editorFontSize = Int(NoteBubble.defaultEditorFont)
    @AppStorage(NoteBubble.minWidthKey) private var bubbleMinWidth = Int(NoteBubble.fixedMinWidth)
    @AppStorage(NoteBubble.maxWidthKey) private var bubbleMaxWidth = Int(NoteBubble.fixedMaxWidth)

    var body: some View {
        switch tab {
        case .general: generalTab
        case .tablet: tabletTab
        case .reading: readingTab
        case .shortcuts: ShortcutsSettings()
        case .agent: MCPSettingsView(mcp: app.mcp)
        case .diagnostics: diagnosticsTab
        }
    }

    /// 诊断：最近几次「打开 / 切标签」各花了多久、卡在哪一段（`OpenStats`，同一份也进 ws 日志）。
    private var diagnosticsTab: some View {
        Form {
            Section {
                // 每秒重算（同「渲染」区块的理由：设置窗不销毁，静态取值会一直是旧快照）。
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    let recs = OpenStats.records
                    // 复制按钮放在同一个每秒重算的闭包里，「没记录就置灰」才会跟着刷新。
                    LabeledContent {
                        Button(L("Copy")) { copyToPasteboard(timingsText(recs)) }
                            .disabled(recs.isEmpty)
                    } label: {
                        Text(L("All records as text (one line per open)"))
                    }
                    if recs.isEmpty {
                        Text(L("No document opened yet in this session."))
                    } else {
                        ForEach(recs) { r in openRecordRow(r) }
                    }
                }
            } header: {
                Text(L("Open timings (recent)"))
            } footer: {
                Text(L("Measured from the click until every visible page shows its image and ink. Phases are the synchronous load steps; marks are milestones since the click. The same summary lines go to ~/Library/Logs/UniReader-ws.log when that file exists."))
            }
        }
        .formStyle(.grouped)
    }

    /// 复制用的文本：每条记录一行，= 写进 ws 日志的那句摘要（`Record.summary`）前面加上开始时刻；最新在前。
    private func timingsText(_ recs: [OpenTrace.Record]) -> String {
        recs.map { "\($0.startedAt.formatted(date: .numeric, time: .standard)) \($0.summary)" }
            .joined(separator: "\n")
    }

    private func copyToPasteboard(_ s: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(s, forType: .string)
    }

    @ViewBuilder private func openRecordRow(_ r: OpenTrace.Record) -> some View {
        DisclosureGroup {
            LabeledContent(L("Outcome"), value: r.outcome)
            LabeledContent(L("Load"), value: "\(Int(r.loadMs.rounded())) ms")
            ForEach(Array(r.phases.enumerated()), id: \.offset) { _, p in
                LabeledContent {
                    Text("\(Int(p.ms.rounded())) ms" + (p.detail.isEmpty ? "" : " · \(p.detail)"))
                } label: {
                    Text("　" + p.name)
                }
            }
            ForEach(Array(r.marks.enumerated()), id: \.offset) { _, m in
                LabeledContent {
                    Text("+\(Int(m.atMs.rounded())) ms" + (m.detail.isEmpty ? "" : " · \(m.detail)"))
                } label: {
                    Text(m.name)
                }
            }
            LabeledContent(L("Pages"), value: r.imagesLine)
            LabeledContent(L("Ink"), value: r.inkLine)
        } label: {
            LabeledContent {
                Text("\(Int(r.totalMs.rounded())) ms")
            } label: {
                Text("\(r.startedAt.formatted(date: .omitted, time: .standard)) · \(r.title) · \(r.reason)")
                    .lineLimit(1)
            }
        }
    }

    /// 通用：外观（夜间模式自动化）+ 工具栏按钮显隐。
    private var generalTab: some View {
        Form {
            Section {
                Toggle(L("Auto Night Mode (follow system Dark Mode)"), isOn: $autoNightMode)
            } header: {
                Text(L("Appearance"))
            } footer: {
                Text(L("When on, Night Mode follows the system appearance automatically."))
            }

            // 工具栏的显隐/排序改走**系统那套**（`.toolbar(id: "reader")`，见 `ContentView.toolbarContent`），
            // 这里只留一句指路——设置页再放一份开关就是两套状态打架。
            Section {
                Text(L("Right-click the toolbar in a reading window and choose “Customize Toolbar…” to add, remove or rearrange buttons."))
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text(L("Toolbar"))
            }

            // 图片笔记的图片本体（`IMAGE-NOTE-PLAN.md §8`）：设置窗是 App 级的、图片是工作区级的，
            // 所以按**此刻开着的工作区**逐个列一行。每秒重算（同诊断页的理由：设置窗不销毁，静态取值会一直是旧数）。
            Section {
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    let managers = WorkspaceRegistry.shared.openManagers
                    if managers.isEmpty {
                        Text(L("No workspace is open.")).foregroundStyle(.secondary)
                    } else {
                        ForEach(managers, id: \.folder) { ws in imageStatsRow(ws) }
                    }
                }
            } header: {
                Text(L("Image Notes"))
            } footer: {
                Text(L("Images live inside the workspace package. An image whose notes are all deleted becomes pending; it is removed for good 30 days later (undo the deletion before then to keep it)."))
            }
        }
        .formStyle(.grouped)
    }

    /// 一个工作区的图片账：「图片 N 张 · 待删除 M 张 · 占用」+「立即清理」。
    @ViewBuilder private func imageStatsRow(_ ws: WorkspaceManager) -> some View {
        let s = ws.imageStats()
        LabeledContent {
            Button(L("Clean Up Now")) { _ = ws.purgeImagesNow() }
                .disabled(s.orphaned == 0)
        } label: {
            Text(ws.name)
            Text(String(format: L("%d images · %d pending deletion · %@"), s.total, s.orphaned,
                        ByteCountFormatter.string(fromByteCount: s.bytes, countStyle: .file)))
        }
    }

    /// 平板：滚动跟随算法 + 服务开机自启。
    private var tabletTab: some View {
        Form {
            Section {
                Picker(L("Delay handling"), selection: $scrollInterp) {
                    Text(L("Interpolation")).tag(true)
                    Text(L("Low-pass")).tag(false)
                }
            } header: {
                Text(L("Tablet Scroll Follow"))
            } footer: {
                Text(L("Interpolation tracks fast flings tighter; Low-pass is simpler and smoother on LAN."))
            }

            Section {
                Toggle(L("Start tablet service on launch"), isOn: $autoStartServer)
                    .onChange(of: autoStartServer) { _, on in
                        if on, !app.server.isRunning { app.server.start() }   // 打开即启，立即生效
                    }
            } header: {
                Text(L("Tablet Service"))
            }
        }
        .formStyle(.grouped)
    }

    /// 阅读：页图渲染缓存 + 文字识别（OCR）。
    private var readingTab: some View {
        Form {
            // 笔记气泡的尺寸口径（`NoteBubble`）：默认固定尺寸；打开 = 2026-08-27 那套「跟页缩放」（三端契约的比例）。
            // 字号两档分开设（用户 2026-09-13）：气泡是看的、编辑框是写的，想要的大小不一样。
            Section {
                Picker(L("Note bubble text size"), selection: $bubbleFontSize) {
                    ForEach(NoteBubble.fontSizeChoices, id: \.self) { Text("\($0) pt").tag($0) }
                }
                Picker(L("Note editor text size"), selection: $editorFontSize) {
                    ForEach(NoteBubble.fontSizeChoices, id: \.self) { Text("\($0) pt").tag($0) }
                }
                // 宽度：短文按内容收窄，落在最小…最大之间（用户 2026-09-13）。两个数互相钳住，最小永远不超过最大。
                Stepper(value: $bubbleMinWidth, in: NoteBubble.widthRange, step: NoteBubble.widthStep) {
                    LabeledContent(L("Note bubble min width"), value: "\(bubbleMinWidth) pt")
                }
                .onChange(of: bubbleMinWidth) { _, v in if bubbleMaxWidth < v { bubbleMaxWidth = v } }
                Stepper(value: $bubbleMaxWidth, in: NoteBubble.widthRange, step: NoteBubble.widthStep) {
                    LabeledContent(L("Note bubble max width"), value: "\(bubbleMaxWidth) pt")
                }
                .onChange(of: bubbleMaxWidth) { _, v in if bubbleMinWidth > v { bubbleMinWidth = v } }
                Toggle(L("Note bubbles follow page zoom"), isOn: $bubbleFollowsZoom)
            } header: {
                Text(L("Notes"))
            } footer: {
                Text(L("Text size and widths apply to expanded text and image notes on the page; a short note shrinks to its content between the min and max width. Editor size applies to the note editor. Follow page zoom off: bubbles keep a fixed size on screen; on: they scale with the page, like on the tablet."))
            }

            Section {
                Picker(L("Page render cache limit"), selection: $renderCacheMB) {
                    Text("128 MB").tag(128)
                    Text("256 MB").tag(256)
                    Text("512 MB").tag(512)
                    Text("1 GB").tag(1024)
                }
                .onChange(of: renderCacheMB) { _, mb in PageRenderEngine.shared.setCacheLimitMB(mb) }
                // 每秒重算：设置窗不销毁，静态取值会一直显示第一次打开时的快照（诊断时被这个骗过一次）。
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    memoryDiagRows(MemoryDiag.snapshot())
                }
                // 复制的是 `MemoryDiag.report()` 那份纯文本（同一份快照的多行版，排查时直接贴出来）。
                LabeledContent {
                    Button(L("Copy")) {
                        copyToPasteboard("\(Date.now.formatted(date: .numeric, time: .standard))\n" + MemoryDiag.report())
                    }
                } label: {
                    Text(L("Memory figures as text"))
                }
            } header: {
                Text(L("Rendering"))
            } footer: {
                Text(L("The limit covers all page bitmaps in memory: those shown in windows plus the cache; the cache yields room to what windows hold. Every bitmap also has a CoreAnimation copy of the same size, already counted here."))
            }

            Section {
                Picker(L("OCR Engine"), selection: $ocrEngine) {
                    Text(L("Off")).tag("off")
                    Text(L("Paddle OCR (API)")).tag("paddle")
                }
                if ocrEngine == "paddle" {
                    SecureField(L("Paddle API Key"), text: $ocrPaddleKey)
                        .textFieldStyle(.roundedBorder)
                        .onAppear { ocrPaddleKey = PaddleOCR.apiKey() }
                        .onChange(of: ocrPaddleKey) { _, v in PaddleOCR.setApiKey(v) }
                }
            } header: {
                Text(L("Text Recognition (OCR)"))
            } footer: {
                Text(L("For scanned or bad-text PDFs, use API OCR for accurate selectable/searchable text. The key is stored in this Mac's Keychain."))
            }
        }
        .formStyle(.grouped)
    }

    /// 真实内存台账（`MemoryDiag`）：进程总量 → 页位图（存活 / 缓存 / 各窗口持有）→ 堆。
    /// 每一行都是进程里量出来的数，不是估算；页位图的 CA 副本按 ×2 记（见 `PageRenderEngine.copiesPerImage`）。
    @ViewBuilder private func memoryDiagRows(_ s: MemoryDiag.Snapshot) -> some View {
        let mb = MemoryDiag.mb
        LabeledContent(L("App memory (Activity Monitor)"), value: mb(s.footprint))
        LabeledContent(L("Page bitmaps alive"),
                       value: "\(s.liveCount) · \(mb(s.liveBytes)) + CA \(mb(s.liveBytes)) = \(mb(s.bitmapFootprint))")
        LabeledContent(L("In cache"),
                       value: "\(s.cacheBaseCount)+\(s.cacheTileCount) · \(mb(s.cacheBaseBytes + s.cacheTileBytes))"
                       + " · \(L("room")) \(mb(s.cacheEffectiveBytes / PageRenderEngine.copiesPerImage))")
        LabeledContent(L("Held by windows"), value: "\(s.heldCount) · \(mb(s.heldBytes))")
        ForEach(Array(s.holdings.enumerated()), id: \.offset) { _, h in
            LabeledContent {
                Text(holdingValue(h))
            } label: {
                Text((h.active ? "● " : "○ ") + holdingLabel(h))
            }
        }
        LabeledContent(L("Heap (malloc)"),
                       value: "\(mb(s.mallocUsed)) · \(L("freed, not yet returned")) \(mb(s.mallocRetained))")
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
}

// MARK: - 快捷键页

/// 设置 › 快捷键：每个可改动作一行，点按钮进入录制，按下一组键就记下（`Shortcuts`）。
/// 基础命令（新建/打开/关闭/撤销/剪贴板/查找/退出…）与数字键选笔固定，不在这一页。
struct ShortcutsSettings: View {
    @ObservedObject private var store = Shortcuts.shared

    var body: some View {
        Form {
            ForEach(Array(ShortcutAction.Section.allCases.enumerated()), id: \.offset) { i, section in
                Section {
                    ForEach(section.actions) { ShortcutRow(action: $0, store: store) }
                } header: {
                    Text(section.title)
                } footer: {
                    if section == .readerKeys {
                        Text(L("Reader keys work while reading; they are ignored while typing in a text field or the AI panel. Keys 1–9 pick a pen and are fixed."))
                    }
                }
            }
            Section {
                LabeledContent {
                    Button(L("Reset All Shortcuts")) { store.resetAll() }
                        .disabled(store.overrides.isEmpty)
                } label: {
                    Text(L("Defaults"))
                }
            } footer: {
                Text(L("Click a shortcut to change it, then press the new keys. Esc cancels; Delete removes the shortcut. Basic commands (New, Open, Close, Undo, Copy, Paste, Find, Quit…) are fixed."))
            }
        }
        .formStyle(.grouped)
    }
}

/// 一行：动作名 + 当前键（点它录制）+ 改过才出现的「恢复默认」。
/// 录制用 NSEvent 本地监视器**吃掉**按下的键（返回 nil）——否则按 ⌘Q 这类组合键时菜单会先响应。
struct ShortcutRow: View {
    let action: ShortcutAction
    @ObservedObject var store: Shortcuts
    @State private var recording = false
    @State private var monitor: Any?
    @State private var problem: String?

    var body: some View {
        LabeledContent {
            HStack(spacing: 8) {
                if !store.isDefault(action) {
                    Button { store.reset(action) } label: { Image(systemName: "arrow.counterclockwise") }
                        .help(L("Reset to default"))
                }
                Button(recording ? L("Press keys…") : (store.combo(for: action)?.display ?? L("None"))) {
                    recording ? stop() : start()
                }
                .frame(minWidth: 96)
                .monospacedDigit()
            }
        } label: {
            Text(action.title)
            if let problem { Text(problem) }
        }
        .onDisappear { stop() }
    }

    private func start() {
        problem = nil
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            handle(e)
            return nil
        }
    }

    private func stop() {
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil
        recording = false
    }

    private func handle(_ e: NSEvent) {
        let mods = e.modifierFlags.intersection(KeyCombo.relevantMods)
        if e.keyCode == 53, mods.isEmpty { stop(); return }                        // Esc：取消
        if e.keyCode == 51, mods.isEmpty { store.set(nil, for: action); stop(); return }   // ⌫：清掉
        guard let c = KeyCombo(event: e) else { return }                          // 认不出的键：继续等
        if action.scope == .menu, !c.isMenuSafe {
            problem = L("Menu shortcuts need ⌘, ⌥ or ⌃ (or a function key).")
        } else if let who = store.conflict(c, for: action) {
            problem = String(format: L("Already used by “%@”."), who)
        } else {
            store.set(c, for: action)
        }
        stop()
    }
}
