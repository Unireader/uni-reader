import SwiftUI
import PDFKit
import AppKit
import UniformTypeIdentifiers

struct ContentView: View {
    var launchDocId: String? = nil   // 该窗口启动时要打开的文档（nil = 主/⌘N 窗口）

    @Environment(\.openWindow) private var openWindow
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var workspace: WorkspaceManager

    @StateObject private var session = DocSession()
    @State private var selectedDocID: String?
    @State private var missingDoc: LibDocument?      // 选中但所有路径失效 → 显示重定位提示
    @State private var lastProgressSave = Date.distantPast
    @State private var progressSaveTask: Task<Void, Never>?   // 节流窗内被丢变化的尾随补存
    @State private var toc: [TOCEntry] = []          // 当前 PDF 目录
    @State private var showTOCPopover = false        // 一次性目录弹窗（选完即关，快速跳转）
    @State private var inspectorTab: InspectorTab = .info   // Inspector 当前分段（信息/目录/笔记）
    @State private var isHashing = false
    @State private var showServer = false
    @State private var isKeyWindow = false
    @State private var showNotes = false
    @State private var searchIsActive = false   // 标准 .searchable 搜索字段的展开态（⌘F 激活）
    @State private var hashMismatch: HashMismatch?   // 同路径内容被替换（hash 与入库版本不符）待确认

    /// 「同路径换内容」待确认：文件存在但 hash 与入库版本不符（用户原地覆盖了 PDF）。
    private struct HashMismatch: Identifiable {
        let docId: String; let path: String; let newHash: String
        var id: String { docId }
    }
    @State private var workspaceActionError: String?   // 打开/新建工作区失败（如选中非真实工作区文件夹）待提示
    @State private var showOCR = false
    @AppStorage("ocrEngine") private var ocrEngine = "off"          // OCR 引擎（"off" | "paddle"），设置页写入
    @AppStorage("nightMode") private var nightMode = false
    @AppStorage("scrollInterp") private var scrollInterp = true   // 平板滚动跟随：true=时间戳插值 / false=纯低通（A/B 用）
    @AppStorage("autoNightMode") private var autoNightMode = false     // 夜间模式跟随系统深色外观
    @AppStorage("autoStartServer") private var autoStartServer = false // 启动即开平板服务
    @AppStorage("showTOCButton") private var showTOCButton = true    // 工具栏「目录」按钮（设置页可关）
    @AppStorage("showOCRButton") private var showOCRButton = true    // 工具栏「文字识别」按钮（设置页可关）
    @Environment(\.colorScheme) private var systemScheme

    var body: some View {
        eventRoutes(mainSplit)
    }

    /// 主分栏视图（侧栏 + 阅读区 + 工具栏/inspector + 状态联动）。窗口事件路由挂 `eventRoutes`——
    /// 全部修饰符挂一个表达式上会让类型检查器超时（已踩过，见 toolbarContent 的同款注释）。
    private var mainSplit: some View {
        NavigationSplitView {
            SidebarView(selection: $selectedDocID, onChooseWorkspace: chooseWorkspace,
                        onCreateWorkspace: createNewWorkspace,
                        onDropFiles: { ingest(urls: $0) }, onOpenPDF: openPDF,
                        onOpenInNewWindow: { openWindow(id: "docWindow", value: $0) })
                .navigationSplitViewColumnWidth(min: 200, ideal: 260)
        } detail: {
            detailColumn
        }
        .inspector(isPresented: $showNotes) {
            InspectorView(session: session, documentId: selectedDocID,
                          toc: toc, tab: $inspectorTab, onSelectTOC: jumpToTOC,
                          onJumpTo: { page, frac in
                              session.currentPageIndex = page
                              session.emitAnchor(page: page, frac: frac, origin: "toc")
                          })
                .inspectorColumnWidth(min: 240, ideal: 300, max: 400)
        }
        .onChange(of: selectedDocID) { old, id in
            saveProgress(docId: old)            // 切走前先存旧文档进度
            loadSelected(id)
            workspace.setWindowDoc(session.id, id)   // 更新工作区打开文档集
        }
        .onChange(of: session.currentPageIndex) { _, _ in
            app.sessionChanged(session)
            saveProgress(docId: selectedDocID)   // 翻页即存，避免只靠节流/关窗丢进度
        }
        .onChange(of: session.scrollAnchor) { _, a in
            app.macScrolled(session)
            saveProgressThrottled(a)
        }
        .onChange(of: session.readZoom) { _, _ in
            saveProgressThrottled(session.scrollAnchor)   // 缩放变化也存（含 restore 后手动缩放）
        }
        .onChange(of: session.strokes) { _, _ in
            persistInk()   // 笔画完成/擦除/框选移动时增量落库（liveStroke 变化不触发）
        }
        .onChange(of: session.inkLayers) { _, _ in
            persistInkLayers()   // 新建/改名/改色/改可见性/重排序时增量落库
            app.broadcastLayers()
            // 可见性变化（或删除图层连带删笔迹）会改变 broadcastStrokes 的过滤结果，但笔迹本身
            // （session.strokes）没变、不会触发上面那个 onChange——必须在这里补发一次，否则平板
            // 画布上已经画出来的笔迹在切可见性后不会跟着增减，只有等下一笔画/擦除才会捎带刷新。
            app.broadcastStrokes()
        }
        .onChange(of: session.activeLayerID) { _, _ in
            app.broadcastLayers()   // 当前作画图层变化也同步给平板
        }
        .onChange(of: session.textNotes) { _, _ in
            persistTextNotes()   // 文字注解新建/编辑/删除时增量落库
            app.broadcastNotes() // 同步镜像给平板（圆形标记；非 padSession 时为空操作/重发同值）
        }
        .onChange(of: session.highlights) { _, _ in
            persistHighlights()  // 高亮新建/改色/删除时增量落库
        }
        .onAppear {
            app.register(session)
            // 页图缓存上限：启动套用存储值（设置页改动即时生效，这里覆盖引擎默认 400MB）。
            PageRenderEngine.shared.setCacheLimitMB(UserDefaults.standard.object(forKey: "renderCacheMB") as? Int ?? 512)
            if autoStartServer, !app.server.isRunning { app.server.start() }   // 平板服务开机自启
            if autoNightMode { nightMode = (systemScheme == .dark) }           // 夜间模式跟随系统
            if let id = launchDocId {
                selectedDocID = id                      // 「在新窗口打开」指定文档
            } else if let path = AppDelegate.consumePendingWorkspace() {
                // 冷启动双击 .unrd：视图就绪晚于 openFile 回调，从 AppDelegate 缓冲里补消费。
                // 优先于 restoreSession——否则会先把上一个工作区的整组文档开一遍窗口，
                // 再切工作区，途中闪一批不相关的窗口。
                app.didRestoreInitial = true
                openWorkspace(path: path)
            } else if !app.didRestoreInitial {
                app.didRestoreInitial = true
                restoreSession()                        // 首个窗口：恢复整组打开文档为多窗口
            }
        }
        .onChange(of: systemScheme) { _, s in if autoNightMode { nightMode = (s == .dark) } }
        .onChange(of: autoNightMode) { _, on in if on { nightMode = (systemScheme == .dark) } }
        .onChange(of: workspace.documents) { _, docs in
            // 选中文档被删除/合并掉后从列表消失（如「删除」）→ 清选中，阅读区回到空态。
            if let id = selectedDocID, !docs.contains(where: { $0.id == id }) {
                selectedDocID = nil
            }
        }
        .onChange(of: workspace.folder) { _, _ in
            // 切工作区：主动窗口切到新工作区一个打开文档；其他窗口丢弃失效选中（不额外开窗）。
            if isKeyWindow {
                selectedDocID = workspace.restoreDocIds.first { workspace.document(id: $0) != nil }
            } else if let id = selectedDocID, workspace.document(id: id) == nil {
                selectedDocID = nil
            }
        }
    }

    /// 阅读区列（detail）。**标题栏文本一律走 SwiftUI 原生的 navigationTitle/navigationSubtitle，
    /// 严禁再用 AppKit 直写 window.title/subtitle**：只要视图树里出现过 navigationTitle（侧栏就有一个），
    /// SwiftUI 便接管整条标题栏，会把自己算出的值（detail 列没声明标题时 = app 名「UniReader」、
    /// 没声明副标题时 = 空串）盖回去——2026-07-28 实测就是这么把副标题吃掉、并让主标题闪一下的。
    private var detailColumn: some View {
        // 文档加载（session.pdf）保留：真平板仍可正常渲染。
        readerColumn
            .dropDestination(for: URL.self) { urls, _ in ingest(urls: urls); return true }
            // 标准 macOS 搜索（参考 Preview/Safari）：工具栏搜索字段，取代旧的放大镜弹窗。
            // 边打字边搜（DocSession 内 250ms 防抖）、回车跳下一个命中；⌘F 菜单激活搜索字段。
            .searchable(text: $session.searchQuery, isPresented: $searchIsActive,
                        placement: .toolbar, prompt: L("Find in Document"))
            .onSubmit(of: .search) { session.nextMatch() }
            .onChange(of: session.searchQuery) { _, _ in session.scheduleSearch() }
            .overlay(alignment: .top) { findBanner }
            .navigationTitle(windowTitle)
            .navigationSubtitle(windowSubtitle)
            .background(WindowAccessor { key in
                isKeyWindow = key
                if key { app.setActive(session) }
            })
            .toolbar { toolbarContent }
    }

    /// 窗口级事件路由：关窗保存 / 菜单通知（⌘O 打开、⌘F 查找、⌥⌘N 夜间）/ 搜索收起清空 / 文件变化提示。
    private func eventRoutes<V: View>(_ base: V) -> some View {
        base
        .onDisappear {
            saveProgress(docId: selectedDocID)
            workspace.closeWindow(session.id)
            app.unregister(session)
        }
        .onReceive(NotificationCenter.default.publisher(for: .openPDFRequested)) { _ in
            if isKeyWindow { openPDF() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .openWorkspaceRequested)) { note in
            // Finder 双击 / 拖到 Dock 的 .unrd 包：key 窗口切换工作区（并清掉冷启动缓冲）。
            if isKeyWindow, let path = note.object as? String {
                AppDelegate.consumePendingWorkspace()
                openWorkspace(path: path)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .readerFind)) { _ in
            if isKeyWindow { searchIsActive = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: .toggleNightMode)) { _ in
            if isKeyWindow { nightMode.toggle() }   // ⌥⌘N：与工具栏月亮按钮同一 @AppStorage 状态
        }
        .onChange(of: searchIsActive) { _, on in
            if !on { session.clearSearch() }   // 收起搜索字段 = 清空高亮，下次重新打字
        }
        // 同路径内容被替换（原地覆盖了 PDF）→ 提示关联为新版本；不改库则本次按实际内容打开。
        // （actions/message 抽成独立方法——内联会让类型检查器超时。）
        .alert(L("File Changed"), isPresented: hashAlertPresented, presenting: hashMismatch,
               actions: hashAlertActions, message: hashAlertMessage)
        // 打开/新建工作区失败（选中的不是真实工作区包 / 创建失败等）——不静默开出空库。
        .alert(L("Workspace Error"),
               isPresented: Binding(get: { workspaceActionError != nil },
                                    set: { if !$0 { workspaceActionError = nil } })
        ) {
            Button(L("OK")) {}
        } message: {
            Text(workspaceActionError ?? "")
        }
    }

    @ViewBuilder
    private var readerColumn: some View {
        if session.pdf != nil {
            PageStreamView(session: session,
                           docKey: session.contentHash,
                           nightMode: nightMode,
                           interpEnabled: scrollInterp,
                           isActiveWindow: isKeyWindow)
                .overlay(alignment: .top) { if isHashing { indexingBadge } }
        } else if let doc = missingDoc {
            ContentUnavailableView {
                Label(L("File Not Found"), systemImage: "questionmark.folder")
            } description: {
                Text(String(format: L("All known paths for “%@” are unavailable. Re-link the file to continue."), doc.title))
            } actions: {
                Button(L("Re-link File…")) { relocate(doc) }
            }
        } else {
            ContentUnavailableView(
                L("No Document"),
                systemImage: "doc.richtext",
                description: Text(L("Open a PDF to start reading."))
            )
            .overlay(alignment: .top) { if isHashing { indexingBadge } }
        }
    }

    /// 工具栏内容：缩放组（最左）+ 中间一组（目录 / OCR / 夜间 / 平板服务）+ Inspector。
    /// 抽出独立 ToolbarContent——内联进 body 会让 SwiftUI 类型检查器超时。
    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        // 缩放一组（最左，参考 Preview：缩小 | 1:1 实际大小 | 放大；经通知路由到本窗口阅读区，
        // 与 ⌘-/⌘= 菜单命令同一套 commit 路径）。Tahoe 胶囊合并规则（2026-07-28 实测）：
        // 只有连续纯图标 Button 才被系统合并成单一胶囊——掺 Text label（如 "1:1"）整组散成
        // 独立圆钮，故 1:1 用 "1.magnifyingglass" 图标；ControlGroup 在工具栏里同样被拆散，不可用。
        ToolbarItemGroup(placement: .automatic) { zoomButtons }
        // Tahoe 会把相邻 item 合并进同一玻璃胶囊——插 spacer 强制缩放组与下面那组分成两个胶囊。
        ToolbarSpacer()
        // 中间一组：目录 / OCR / 夜间 / 平板服务（查找走标准 .searchable，见 readerColumn；
        // 目录/OCR 按钮可在设置里关掉）
        ToolbarItemGroup(placement: .automatic) {
            if showTOCButton {
                Button {
                    showTOCPopover.toggle()
                } label: {
                    Label(L("Contents"), systemImage: "list.bullet.indent")
                }
                .disabled(session.pdf == nil)
                .popover(isPresented: $showTOCPopover, arrowEdge: .bottom) { tocPopover }
            }

            if showOCRButton {
                Button {
                    showOCR.toggle()
                } label: {
                    Label(L("Text Recognition (OCR)"), systemImage: "text.viewfinder")
                }
                .disabled(session.pdf == nil)
                .popover(isPresented: $showOCR, arrowEdge: .bottom) { ocrPopover }
            }

            Button {
                nightMode.toggle()
            } label: {
                Label(L("Night Mode"), systemImage: nightMode ? "sun.max.fill" : "moon.fill")
            }
            Button {
                showServer.toggle()
            } label: {
                Label(L("Tablet"), systemImage: "wifi")
            }
            .popover(isPresented: $showServer, arrowEdge: .bottom) {
                ServerPanel(server: app.server)
            }
        }
        // 单独一组：切换 Inspector
        ToolbarItem(placement: .primaryAction) {
            Button {
                showNotes.toggle()
            } label: {
                Label(L("Inspector"), systemImage: "sidebar.right")
            }
        }
    }

    /// 工具栏缩放组：缩小 | 1:1 | 放大（无 PDF 时禁用）。纯 Button 交给外层 ToolbarItemGroup
    /// 渲染成单一胶囊分段组（Tahoe 下 ControlGroup 反而会被拆成独立圆钮，见 toolbarContent 注释）。
    @ViewBuilder
    private var zoomButtons: some View {
        Group {
            Button {
                NotificationCenter.default.post(name: .readerZoomOut, object: nil)
            } label: {
                Image(systemName: "minus.magnifyingglass")
            }
            .help(L("Zoom Out"))
            Button {
                NotificationCenter.default.post(name: .readerZoomActual, object: nil)
            } label: {
                Image(systemName: "1.magnifyingglass")
            }
            .help(L("Actual Size"))
            Button {
                NotificationCenter.default.post(name: .readerZoomIn, object: nil)
            } label: {
                Image(systemName: "plus.magnifyingglass")
            }
            .help(L("Zoom In"))
        }
        .disabled(session.pdf == nil)
    }

    // 一次性目录弹窗：无分割线，点条目跳转并关闭。持久目录见 Inspector 的「目录」页。
    private var tocPopover: some View {
        VStack(spacing: 0) {
            Text(L("Contents"))
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12).padding(.vertical, 10)
            TOCListView(entries: toc, currentPage: session.currentPageIndex) { e in
                jumpToTOC(e)
                showTOCPopover = false
            }
            .frame(width: 320, height: 420)
        }
    }

    /// 搜索状态条（Safari 式）：仅搜索激活且有输入时浮在阅读区顶部——命中计数 + 上/下一个。
    /// 输入本身在工具栏标准搜索字段（.searchable），这里只补「导航」这一层。
    @ViewBuilder
    private var findBanner: some View {
        if searchIsActive && !session.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            HStack(spacing: 8) {
                Text(findStatusText)
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize()
                Button { session.prevMatch() } label: {
                    Image(systemName: "chevron.up").frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .disabled(session.searchMatches.isEmpty)
                Button { session.nextMatch() } label: {
                    Image(systemName: "chevron.down").frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .disabled(session.searchMatches.isEmpty)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().stroke(.white.opacity(0.15), lineWidth: 0.5))
            .shadow(radius: 6, y: 2)
            .padding(.top, 8)
        }
    }

    private var findStatusText: String {
        if session.isSearching { return L("Searching…") }
        guard !session.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "" }
        guard !session.searchMatches.isEmpty else { return L("No matches") }
        return String(format: L("%d of %d"), (session.currentMatchIndex ?? 0) + 1, session.searchMatches.count)
    }

    /// 窗口标题：打开 PDF 显示文档名（过长由 macOS 标题栏自动「…」缩略）；无文档回退侧栏同款「书库」。
    private var windowTitle: String {
        session.title.isEmpty ? L("Library") : session.title
    }

    /// 窗口副标题：当前页/总页数（如 3/100），翻页随 session.currentPageIndex 联动；无文档置空。
    private var windowSubtitle: String {
        guard let pdf = session.pdf else { return "" }
        return "\(session.currentPageIndex + 1)/\(pdf.pageCount)"
    }

    /// OCR 面板：开关「用 OCR 文本」+ 进度 + 手动「识别全部页」。未配置 key 时引导去设置。
    private var ocrPopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L("Text Recognition (OCR)")).font(.headline)
            if ocrEngine != "paddle" {
                Text(L("Enable API OCR in Settings (⌘,) and paste your key first."))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button(L("Open Settings…")) {
                    NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                }
            } else {
                Toggle(L("Use OCR text for this document"),
                       isOn: Binding(get: { session.ocrEnabled }, set: { session.setOCREnabled($0) }))
                Text(ocrStatusText).font(.caption).foregroundStyle(.secondary)
                if session.ocrRunning { ProgressView().controlSize(.small) }
                Button(L("Recognize all pages")) { session.ocrAllPages() }
                    .disabled(session.pdf == nil)
                Divider()
                Toggle(L("Show recognition blocks (debug)"), isOn: $session.showOCRBlocks)
                Text(L("Colors each recognized text block to inspect layout/selection accuracy."))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if session.showOCRBlocks {
                    Picker("", selection: $session.ocrBlockGrouped) {
                        Text(L("Per block")).tag(false)
                        Text(L("Selectable groups")).tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                if let err = session.ocrLastError {
                    Text(err).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(14)
        .frame(width: 280, alignment: .leading)
    }

    private var ocrStatusText: String {
        let done = session.ocrDoneCount, total = session.ocrTotalPages
        if session.ocrRunning {
            return String(format: L("Recognizing… %d/%d pages, %d queued"),
                          done, total, session.ocrPendingCount)
        }
        if done == 0 { return L("Not recognized yet.") }
        return String(format: L("%d of %d pages recognized"), done, total)
    }

    /// 跳转到目录项（页 + 页内比例）。origin=toc → 阅读区(PageStreamView)跟随，同时推给平板。
    private func jumpToTOC(_ e: TOCEntry) {
        session.currentPageIndex = e.pageIndex
        session.emitAnchor(page: e.pageIndex, frac: e.frac, origin: "toc")
    }

    private var indexingBadge: some View {
        Label(L("Indexing…"), systemImage: "clock")
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(.thinMaterial, in: Capsule())
            .padding(.top, 8)
    }

    // MARK: - 打开与入库

    private func openPDF() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return }
        ingest(urls: panel.urls)
    }

    /// 导入一批 PDF（打开面板 / 拖拽都走这里）：逐个算 hash 入库，选中最后一个。
    func ingest(urls: [URL]) {
        let pdfs = urls.filter { $0.pathExtension.lowercased() == "pdf" }
        guard !pdfs.isEmpty else { return }
        isHashing = true
        Task {
            var lastId: String?
            for url in pdfs {
                let hash = await Task.detached(priority: .userInitiated) {
                    (try? FileHasher.sha256Cached(of: url)) ?? ""
                }.value
                let pageCount = PDFDocument(url: url)?.pageCount ?? 0
                if let doc = workspace.ingest(path: url.path, hash: hash,
                                              title: url.deletingPathExtension().lastPathComponent,
                                              pageCount: pageCount) {
                    lastId = doc.id
                }
            }
            isHashing = false
            if let lastId { selectedDocID = lastId }   // 触发 loadSelected
        }
    }

    /// 打开一个**已存在**的工作区包（`.unrd`）：只认真实工作区，不接受普通/空文件夹，也不允许
    /// 现场新建（那是 `createNewWorkspace()` 的职责）——避免误选到无关文件夹时被静默建成空库。
    private func chooseWorkspace() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.canCreateDirectories = false
        panel.treatsFilePackagesAsDirectories = false
        panel.allowedContentTypes = [UTType(exportedAs: "tech.xvanturing.unireader.workspace")]
        panel.allowsMultipleSelection = false
        panel.message = L("Choose an existing UniReader workspace (.unrd).")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try workspace.openExisting(folder: url) } catch { workspaceActionError = error.localizedDescription }
        // 选中交给 .onChange(workspace.folder) → restoreLastDoc（恢复新工作区上次文档）
    }

    /// 新建工作区：选位置+起名，创建全新 `.unrd` 包并切换过去（与「打开」严格分离的专用入口）。
    private func createNewWorkspace() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(exportedAs: "tech.xvanturing.unireader.workspace")]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = L("Untitled Workspace")
        panel.prompt = L("Create")
        panel.message = L("Choose a location and name for the new workspace.")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try workspace.createWorkspace(at: url) } catch { workspaceActionError = error.localizedDescription }
    }

    /// 打开 .unrd 工作区包（Finder 双击 / 拖到 Dock / 冷启动缓冲）：同样走严格校验——
    /// 万一目标不是真实工作区（如损坏或被误建的同名空文件夹），提示而非静默开出一个空库。
    private func openWorkspace(path: String) {
        do { try workspace.openExisting(folder: URL(fileURLWithPath: path)) } catch { workspaceActionError = error.localizedDescription }
    }

    /// 启动时恢复工作区上次打开的整组文档：本窗口开第一个，其余各开一个新窗口。
    private func restoreSession() {
        let docs = workspace.restoreDocIds.filter { workspace.document(id: $0) != nil }
        selectedDocID = docs.first
        // 只自动重开有限几个最近文档为独立窗口，避免「最近打开」较长时一次弹出过多窗口；
        // 其余仍在侧栏，一键可开。
        for other in docs.dropFirst().prefix(4) {
            openWindow(id: "docWindow", value: other)
        }
    }

    // MARK: - 选中加载

    private func loadSelected(_ id: String?) {
        session.clearSearch()   // 换文档：旧文档的查找命中/高亮不应带过去
        session.store = workspace.store   // OCR 缓存读写用（仅主线程）
        session.restoreZoom = 1; session.readZoom = 1   // 默认 fit-width；成功路径按库覆盖
        session.restoreHFrac = 0; session.readHFrac = 0
        guard let id, let doc = workspace.document(id: id) else {
            session.pdf = nil; missingDoc = nil; toc = []; session.title = ""
            clearInk(); clearInkLayers(); clearTextNotes(); clearHighlights(); session.reloadOCRState(); return
        }
        guard let target = workspace.openTarget(documentId: id),
              let pdf = PDFDocument(url: URL(fileURLWithPath: target.path)) else {
            session.pdf = nil
            session.title = ""
            missingDoc = doc                       // 所有路径失效 → 显示重定位提示
            toc = []
            clearInk()
            clearInkLayers()
            clearTextNotes()
            clearHighlights()
            return
        }
        missingDoc = nil
        session.pdf = pdf
        toc = TOCEntry.build(from: pdf)
        session.title = doc.title
        session.contentHash = target.hash
        session.reloadOCRState()                   // 换文档重置 OCR；该内容已有缓存则自动启用
        loadInk(documentId: id)                    // 恢复该文档已落库的手写笔迹
        loadInkLayers(documentId: id)               // 恢复该文档的图层注册表（含自愈补建）
        session.noteTypes = workspace.noteTypes()   // 工作区笔记类型（通用内置兜底，不在列）
        session.noteTypeFilter = .all               // 筛选仅内存，开文档复位
        loadTextNotes(documentId: id)              // 恢复该文档已落库的文字注解
        loadHighlights(documentId: id)             // 恢复该文档已落库的高亮
        // 恢复阅读进度：缩放倍率 + 定页 + 精确滚到页内比例（restore 锚点，阅读区(PageStreamView)会跟随）。
        let p = workspace.progress(documentId: id)
        session.restoreZoom = CGFloat(p.zoom)      // 首帧定基准后由 PageStreamView 套用
        session.readZoom = CGFloat(p.zoom)
        session.restoreHFrac = CGFloat(p.hfrac)    // 横向滚动比例（缩放态才非 0）
        session.readHFrac = p.hfrac
        let page = min(max(0, p.page), max(0, pdf.pageCount - 1))
        session.currentPageIndex = page
        lastProgressSave = .now                    // 避免恢复动作立刻又写一遍
        if page > 0 || p.frac > 0 {
            session.emitAnchor(page: page, frac: p.frac, origin: "restore")
        }
        app.setActive(session)
        app.sessionChanged(session)
        app.broadcastStrokes()   // 新文档的已存笔迹回传平板（平板本地不落库，靠 Mac 回显）
        verifyContentHash(documentId: id, openedPath: target.path, storedHash: target.hash)
    }

    /// 同路径内容校验：文件仍在但可能已被原地替换。后台重算 hash（FileHasher 缓存键含 mtime，
    /// 内容变必重算），与入库版本不符 → 弹窗请用户选「关联为新版本 / 仍打开」。
    private func verifyContentHash(documentId: String, openedPath: String, storedHash: String) {
        guard !storedHash.isEmpty else { return }
        Task.detached(priority: .utility) {
            guard let actual = try? FileHasher.sha256Cached(of: URL(fileURLWithPath: openedPath)),
                  !actual.isEmpty, actual != storedHash else { return }
            await MainActor.run {
                // 用户可能已切走文档：仍停留在该文档才提示
                guard self.selectedDocID == documentId else { return }
                self.hashMismatch = HashMismatch(docId: documentId, path: openedPath, newHash: actual)
            }
        }
    }

    // MARK: - 「文件已变化」alert（从 body 抽出，防类型检查器超时）

    private var hashAlertPresented: Binding<Bool> {
        Binding(get: { hashMismatch != nil }, set: { if !$0 { hashMismatch = nil } })
    }

    @ViewBuilder
    private func hashAlertActions(_ m: HashMismatch) -> some View {
        Button(L("Link as New Version")) {
            workspace.rekeyLocation(documentId: m.docId, absolutePath: m.path,
                                    newHash: m.newHash, pageCount: session.pdf?.pageCount ?? 0)
            session.contentHash = m.newHash   // OCR 缓存键跟实际内容走
            session.reloadOCRState()
        }
        Button(L("Open Anyway"), role: .cancel) {
            // 不改库：本次按实际内容打开，下次打开仍会提示
            session.contentHash = m.newHash
            session.reloadOCRState()
        }
    }

    private func hashAlertMessage(_ m: HashMismatch) -> Text {
        Text(String(format: L("The file “%@” was replaced on disk and no longer matches the version in your library. Link it as a new version of this document? (Notes are kept either way.)"),
                    (m.path as NSString).lastPathComponent))
    }

    // MARK: - 阅读进度

    private func saveProgressThrottled(_ a: ScrollAnchor?) {
        guard let id = selectedDocID else { return }
        let now = Date.now
        let elapsed = now.timeIntervalSince(lastProgressSave)
        if elapsed > 0.7 {
            lastProgressSave = now
            progressSaveTask?.cancel()
            progressSaveTask = nil
            workspace.saveProgress(documentId: id, page: a?.page ?? session.currentPageIndex,
                                   frac: a?.frac ?? 0, zoom: Double(session.readZoom), hfrac: session.readHFrac)
            return
        }
        // 尾随补存：节流窗内被丢的变化（缩放/滚动尾帧）延迟落库一次。Xcode 重跑(⌘R)是被 lldb
        // 直接杀进程，走不到 onDisappear 的兜底保存，没有尾随补存最后一次缩放就永久丢失。
        progressSaveTask?.cancel()
        progressSaveTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64((0.7 - elapsed) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            lastProgressSave = .now
            saveProgress(docId: selectedDocID)
        }
    }

    private func saveProgress(docId: String?) {
        guard let docId else { return }
        workspace.saveProgress(documentId: docId, page: session.scrollAnchor?.page ?? session.currentPageIndex,
                               frac: session.scrollAnchor?.frac ?? 0, zoom: Double(session.readZoom),
                               hfrac: session.readHFrac)
    }

    // MARK: - 手写笔迹持久化（note kind=2）

    /// 加载文档时清空内存笔迹与对账集（无文档 / 路径失效时用）。
    private func clearInk() {
        session.documentId = nil
        session.strokes = []
        session.liveStroke = nil
        session.persistedStrokes = [:]
    }

    /// 恢复该文档已落库的手写笔迹到内存，并记录对账集（避免加载即被判为“新增”而重复落库）。
    private func loadInk(documentId id: String) {
        session.documentId = id
        session.liveStroke = nil
        let loaded = workspace.inkStrokes(documentId: id)
        session.persistedStrokes = Dictionary(uniqueKeysWithValues: loaded.map { ($0.id, $0) })
        session.strokes = loaded
    }

    /// 内存笔画 ↔ 库对账：新增或内容变更的 → upsert；曾落库而现已无的（擦除）→ delete。
    /// 用值快照比较（仿 `persistTextNotes`）：同 id 内容变更（框选移动）也识别为“变更”并 upsert——
    /// 旧版只对账 id 集合，移动笔迹后 id 不变、内容变，会被漏写。
    private func persistInk() {
        guard let id = session.documentId else { return }
        let current = session.strokes
        let currentIDs = Set(current.map(\.id))
        for st in current where session.persistedStrokes[st.id] != st {
            workspace.saveInkStroke(documentId: id, st)
        }
        for goneID in session.persistedStrokes.keys where !currentIDs.contains(goneID) {
            workspace.deleteInkStroke(id: goneID)
        }
        session.persistedStrokes = Dictionary(uniqueKeysWithValues: current.map { ($0.id, $0) })
    }

    // MARK: - 笔迹图层持久化（ink_layer 表，v7）

    /// 加载文档时清空内存图层与对账集（无文档 / 路径失效时用）。
    private func clearInkLayers() {
        session.inkLayers = []
        session.persistedInkLayers = [:]
        session.activeLayerID = nil
    }

    /// 恢复该文档已落库的图层到内存（按 sortOrder）。**必须在 `loadInk` 之后调用**：
    /// 自愈逻辑要看 `session.strokes` 里实际出现过哪些 `layerId`。老文档（升级前落库、
    /// 尚无 `ink_layer` 行）或笔迹引用了缺失图层（如合并文档留下的孤儿层）时，
    /// 为每个缺失 id 各补建一条图层并立即落库——否则那些笔迹在图层面板里无处可归、
    /// 也无法被可见性开关命中，页面上会“凭空”多出/少掉一批笔迹。
    private func loadInkLayers(documentId id: String) {
        var loaded = workspace.inkLayers(documentId: id).sorted { $0.sortOrder < $1.sortOrder }
        let knownIDs = Set(loaded.map(\.id))
        var missing = Set(session.strokes.map(\.layerId)).subtracting(knownIDs)
        if loaded.isEmpty { missing.insert(InkLayer.defaultID) }   // 全新/老文档兜底建第一层
        if !missing.isEmpty {
            var nextOrder = (loaded.map(\.sortOrder).max() ?? -1) + 1
            for missingID in missing.sorted(by: { $0.uuidString < $1.uuidString }) {
                let name = String(format: L("Layer %d"), nextOrder + 1)
                let layer = InkLayer(id: missingID, name: name,
                                     colorKey: InkLayer.rotatingColorKey(existingCount: loaded.count),
                                     sortOrder: nextOrder, visible: true)
                loaded.append(layer)
                workspace.saveInkLayer(documentId: id, layer)
                nextOrder += 1
            }
            loaded.sort { $0.sortOrder < $1.sortOrder }
        }
        session.persistedInkLayers = Dictionary(uniqueKeysWithValues: loaded.map { ($0.id, $0) })
        session.inkLayers = loaded
        session.activeLayerID = loaded.first?.id
    }

    /// 内存图层 ↔ 库对账：新增/改名/改色/改可见性/重排序 → upsert；已删除的 → delete。
    private func persistInkLayers() {
        guard let id = session.documentId else { return }
        let current = session.inkLayers
        let currentIDs = Set(current.map(\.id))
        for l in current where session.persistedInkLayers[l.id] != l {
            workspace.saveInkLayer(documentId: id, l)
        }
        for goneID in session.persistedInkLayers.keys where !currentIDs.contains(goneID) {
            workspace.deleteInkLayer(id: goneID)
        }
        session.persistedInkLayers = Dictionary(uniqueKeysWithValues: current.map { ($0.id, $0) })
    }

    // MARK: - 文字注解持久化（note kind=0）

    /// 加载文档时清空内存文字注解与对账集（无文档 / 路径失效时用）。
    private func clearTextNotes() {
        session.persistedTextNotes = [:]
        session.textNotes = []
    }

    /// 恢复该文档已落库的文字注解到内存，并记录对账集（避免加载即被判为“新增”而重复落库）。
    /// ⚠️ 对账集必须**先于** `textNotes` 赋值（与 `loadInk` 同序）：`textNotes=` 会触发 `.onChange`→
    /// `persistTextNotes`，若此时快照仍是旧文档，会拿旧快照对账新列表 → 误删旧文档的注解行。
    private func loadTextNotes(documentId id: String) {
        let loaded = workspace.textNotes(documentId: id)
        session.persistedTextNotes = Dictionary(uniqueKeysWithValues: loaded.map { ($0.id, $0) })
        session.textNotes = loaded
    }

    /// 内存注解 ↔ 库对账：新增或内容变更的 → upsert；曾落库而现已无的（删除）→ delete。
    /// 用值快照比较，故编辑（改文本 / bump updatedAt）也会被识别为“变更”并 upsert。
    private func persistTextNotes() {
        guard let id = session.documentId else { return }
        let current = session.textNotes
        let currentIDs = Set(current.map(\.id))
        for n in current where session.persistedTextNotes[n.id] != n {
            workspace.saveTextNote(documentId: id, n)
        }
        for goneID in session.persistedTextNotes.keys where !currentIDs.contains(goneID) {
            workspace.deleteTextNote(id: goneID)
        }
        session.persistedTextNotes = Dictionary(uniqueKeysWithValues: current.map { ($0.id, $0) })
    }

    // MARK: - 文字高亮持久化（note kind=3）

    /// 清空内存高亮与对账集（对账集先于列表赋值，同 loadTextNotes 防切档误删）。
    private func clearHighlights() {
        session.persistedHighlights = [:]
        session.highlights = []
    }

    private func loadHighlights(documentId id: String) {
        let loaded = workspace.highlights(documentId: id)
        session.persistedHighlights = Dictionary(uniqueKeysWithValues: loaded.map { ($0.id, $0) })
        session.highlights = loaded
    }

    /// 内存高亮 ↔ 库对账：新增/改色 upsert；已无的 delete。用值快照比较，改色也识别为“变更”。
    private func persistHighlights() {
        guard let id = session.documentId else { return }
        let current = session.highlights
        let currentIDs = Set(current.map(\.id))
        for h in current where session.persistedHighlights[h.id] != h {
            workspace.saveHighlight(documentId: id, h)
        }
        for goneID in session.persistedHighlights.keys where !currentIDs.contains(goneID) {
            workspace.deleteHighlight(id: goneID)
        }
        session.persistedHighlights = Dictionary(uniqueKeysWithValues: current.map { ($0.id, $0) })
    }

    // MARK: - 重定位

    private func relocate(_ doc: LibDocument) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = String(format: L("Choose the file for “%@”."), doc.title)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        isHashing = true
        Task {
            let hash = await Task.detached(priority: .userInitiated) {
                (try? FileHasher.sha256Cached(of: url)) ?? ""
            }.value
            let pageCount = PDFDocument(url: url)?.pageCount ?? 0
            workspace.relocate(documentId: doc.id, path: url.path, hash: hash, pageCount: pageCount)
            isHashing = false
            loadSelected(doc.id)
        }
    }
}
