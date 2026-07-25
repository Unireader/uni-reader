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
    @State private var showFind = false
    @State private var showOCR = false
    @FocusState private var findFieldFocused: Bool
    @AppStorage("ocrEngine") private var ocrEngine = "off"          // OCR 引擎（"off" | "paddle"），设置页写入
    @AppStorage("nightMode") private var nightMode = false
    @AppStorage("scrollInterp") private var scrollInterp = true   // 平板滚动跟随：true=时间戳插值 / false=纯低通（A/B 用）
    @AppStorage("autoNightMode") private var autoNightMode = false     // 夜间模式跟随系统深色外观
    @AppStorage("autoStartServer") private var autoStartServer = false // 启动即开平板服务
    @Environment(\.colorScheme) private var systemScheme

    var body: some View {
        NavigationSplitView {
            SidebarView(selection: $selectedDocID, onChooseWorkspace: chooseWorkspace,
                        onDropFiles: { ingest(urls: $0) }, onOpenPDF: openPDF,
                        onOpenInNewWindow: { openWindow(id: "docWindow", value: $0) })
                .navigationSplitViewColumnWidth(min: 200, ideal: 260)
        } detail: {
            // 文档加载（session.pdf）保留：真平板仍可正常渲染。
            readerColumn
                .dropDestination(for: URL.self) { urls, _ in ingest(urls: urls); return true }
                .background(WindowAccessor { key in
                    isKeyWindow = key
                    if key { app.setActive(session) }
                })
                .toolbar { toolbarContent }
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
            persistInk()   // 笔画完成/擦除时增量落库（liveStroke 变化不触发）
        }
        .onChange(of: session.textNotes) { _, _ in
            persistTextNotes()   // 文字注解新建/编辑/删除时增量落库
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
        .onDisappear {
            saveProgress(docId: selectedDocID)
            workspace.closeWindow(session.id)
            app.unregister(session)
        }
        .onReceive(NotificationCenter.default.publisher(for: .openPDFRequested)) { _ in
            if isKeyWindow { openPDF() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .readerFind)) { _ in
            if isKeyWindow { showFind = true }
        }
        .onChange(of: showFind) { _, on in
            if !on { session.clearSearch() }   // 关闭查找栏 = 清空高亮，下次重新打字
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

    /// 工具栏内容：缩放组（最左）+ 中间一组（目录 / 查找 / OCR / 夜间 / 跟随 A/B / 平板服务）+ Inspector。
    /// 抽出独立 ToolbarContent——内联进 body 会让 SwiftUI 类型检查器超时。
    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        // 缩放一组（最左，TOC 左侧；参考 Preview：缩小 | 1:1 实际大小 | 放大；经通知路由到本窗口阅读区，
        // 与 ⌘-/⌘= 菜单命令同一套 commit 路径）。ControlGroup 在 macOS 工具栏渲染成单一胶囊分段组。
        ToolbarItem(placement: .automatic) { zoomButtons }
        // 中间一组：目录 / 查找 / OCR / 夜间 / 跟随 A/B / 平板服务
        ToolbarItemGroup(placement: .automatic) {
            Button {
                showTOCPopover.toggle()
            } label: {
                Label(L("Contents"), systemImage: "list.bullet.indent")
            }
            .disabled(session.pdf == nil)
            .popover(isPresented: $showTOCPopover, arrowEdge: .bottom) { tocPopover }

            Button {
                showFind.toggle()
            } label: {
                Label(L("Find…"), systemImage: "magnifyingglass")
            }
            .disabled(session.pdf == nil)
            .popover(isPresented: $showFind, arrowEdge: .bottom) { findPopover }

            Button {
                showOCR.toggle()
            } label: {
                Label(L("Text Recognition (OCR)"), systemImage: "text.viewfinder")
            }
            .disabled(session.pdf == nil)
            .popover(isPresented: $showOCR, arrowEdge: .bottom) { ocrPopover }

            Button {
                nightMode.toggle()
            } label: {
                Label(L("Night Mode"), systemImage: nightMode ? "sun.max.fill" : "moon.fill")
            }
            Button {
                scrollInterp.toggle()
            } label: {
                Label(scrollInterp ? L("Follow: Interpolation") : L("Follow: Low-pass"),
                      systemImage: scrollInterp ? "waveform" : "line.diagonal")
            }
            .help(L("Tablet scroll-follow algorithm (A/B test)"))
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

    /// 工具栏缩放组：缩小 | 1:1 | 放大（无 PDF 时禁用）。用系统标准 `ControlGroup`（官方文档
    /// 推荐的工具栏分组 API；具体渲染样式交给系统，不自绘）。
    @ViewBuilder
    private var zoomButtons: some View {
        ControlGroup {
            Button {
                NotificationCenter.default.post(name: .readerZoomOut, object: nil)
            } label: {
                Image(systemName: "minus.magnifyingglass")
            }
            .help(L("Zoom Out"))
            Button {
                NotificationCenter.default.post(name: .readerZoomActual, object: nil)
            } label: {
                Text("1:1")
            }
            .help(L("Actual Size"))
            Button {
                NotificationCenter.default.post(name: .readerZoomIn, object: nil)
            } label: {
                Image(systemName: "plus.magnifyingglass")
            }
            .help(L("Zoom In"))
        } label: {
            Label(L("Zoom"), systemImage: "plus.magnifyingglass")   // 窗口过窄溢出收进 >> 时显示
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
            TOCListView(entries: toc) { e in
                jumpToTOC(e)
                showTOCPopover = false
            }
            .frame(width: 320, height: 420)
        }
    }

    /// ⌘F 查找栏：搜索框（防抖实时高亮+跳首个命中，类 Safari）+ 上/下一个 + 命中计数。
    private var findPopover: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                TextField(L("Find in Document"), text: $session.searchQuery)
                    .textFieldStyle(.roundedBorder)
                    .focused($findFieldFocused)
                    .onSubmit { session.nextMatch() }
                    .frame(width: 200)
                Button { session.prevMatch() } label: { Image(systemName: "chevron.up") }
                    .disabled(session.searchMatches.isEmpty)
                Button { session.nextMatch() } label: { Image(systemName: "chevron.down") }
                    .disabled(session.searchMatches.isEmpty)
            }
            if !findStatusText.isEmpty {
                Text(findStatusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(width: 260)
        .onAppear { findFieldFocused = true }
        .onChange(of: session.searchQuery) { _, _ in session.scheduleSearch() }
    }

    private var findStatusText: String {
        if session.isSearching { return L("Searching…") }
        guard !session.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "" }
        guard !session.searchMatches.isEmpty else { return L("No matches") }
        return String(format: L("%d of %d"), (session.currentMatchIndex ?? 0) + 1, session.searchMatches.count)
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

    /// 选择/新建工作区文件夹（已有或空文件夹皆可；数据与笔记都存这里）。
    private func chooseWorkspace() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = L("Choose")
        panel.message = L("Choose a folder as your workspace (data & notes live here).")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try workspace.open(folder: url) } catch { workspace.lastError = "\(error)" }
        // 选中交给 .onChange(workspace.folder) → restoreLastDoc（恢复新工作区上次文档）
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
            session.pdf = nil; missingDoc = nil; toc = []; clearInk(); clearTextNotes(); clearHighlights(); session.reloadOCRState(); return
        }
        guard let target = workspace.openTarget(documentId: id),
              let pdf = PDFDocument(url: URL(fileURLWithPath: target.path)) else {
            session.pdf = nil
            missingDoc = doc                       // 所有路径失效 → 显示重定位提示
            toc = []
            clearInk()
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
        session.persistedStrokeIDs = []
    }

    /// 恢复该文档已落库的手写笔迹到内存，并记录对账集（避免加载即被判为“新增”而重复落库）。
    private func loadInk(documentId id: String) {
        session.documentId = id
        session.liveStroke = nil
        let loaded = workspace.inkStrokes(documentId: id)
        session.persistedStrokeIDs = Set(loaded.map(\.id))
        session.strokes = loaded
    }

    /// 内存笔画 ↔ 库对账：当前有而未落库的 → upsert；曾落库而现已无的（擦除）→ delete。
    private func persistInk() {
        guard let id = session.documentId else { return }
        let currentIDs = Set(session.strokes.map(\.id))
        for st in session.strokes where !session.persistedStrokeIDs.contains(st.id) {
            workspace.saveInkStroke(documentId: id, st)
        }
        for gone in session.persistedStrokeIDs.subtracting(currentIDs) {
            workspace.deleteInkStroke(id: gone)
        }
        session.persistedStrokeIDs = currentIDs
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
