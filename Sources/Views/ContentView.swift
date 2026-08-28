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
    /// AI 面板（App 级单例）。这里只**读**它的落库请求 —— 面板不碰库，见 `applyAIThreadUpsert`。
    @ObservedObject private var aiPanel = AIPanelModel.shared
    @State private var selectedDocID: String?
    @State private var missingDoc: LibDocument?      // 选中但所有路径失效 → 显示重定位提示
    @State private var lastProgressSave = Date.distantPast
    @State private var progressSaveTask: Task<Void, Never>?   // 节流窗内被丢变化的尾随补存
    // 目录（`session.toc`）挂在会话上而不是本视图 @State：平板的 `toc` 广播由 App 级的 AppModel 发，
    // 它只够得着 DocSession。两处显示同一份，不再各建各的。
    @State private var showTOCPopover = false        // 一次性目录弹窗（选完即关，快速跳转）
    @State private var inspectorTab: InspectorTab = .info   // Inspector 当前分段（信息/目录/笔记）
    @State private var isHashing = false
    @State private var showServer = false
    @State private var isKeyWindow = false
    @State private var showNotes = false
    @State private var columnVisibility: NavigationSplitViewVisibility = .all   // ⌘B 切侧栏
    @State private var searchIsActive = false   // 标准 .searchable 搜索字段的展开态（⌘F 激活）
    @State private var hashMismatch: HashMismatch?   // 同路径内容被替换（hash 与入库版本不符）待确认
    @State private var didChooseInitialDoc = false   // 本窗口的初始文档已定（防重复恢复）

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
        eventRoutes(aiRoutes(scratchRoutes(canvasRoutes(mainSplit))))
    }

    /// 平板请求切画板模式（`canvas` 上行）。**同 `scratchRoutes`/`aiRoutes` 的理由单独包一层**：
    /// 直接挂进 `mainSplit` 那条链当场把类型检查器顶爆（2026-08-28 实测，同款）。
    /// 与工具栏按钮走同一条 `setCanvasMode`（改 session + 逐文档落库），权威值随后由阅读区的
    /// onChange → `applyCanvasMargin` → `broadcastCanvas` 广播回平板。
    private func canvasRoutes<V: View>(_ base: V) -> some View {
        base.onChange(of: app.padCanvasRequest) { _, req in
            guard let req, req.sessionID == session.id else { return }
            app.padCanvasRequest = nil
            setCanvasMode(req.on)
        }
    }

    /// AI 会话绑定的落库路由。**同 `scratchRoutes` 的理由单独包一层**——这两条 `onChange` 直接挂进
    /// `mainSplit` 当场把类型检查器顶爆（2026-08-25 实测 `unable to type-check in reasonable time`）。
    private func aiRoutes<V: View>(_ base: V) -> some View {
        base
            .onChange(of: session.aiThreads) { _, _ in
                persistAIThreads()   // 新建/改标题/改失效状态/解绑时增量落库
            }
            .onChange(of: aiPanel.threadUpsert) { _, req in
                applyAIThreadUpsert(req)   // 面板捕到会话 URL → 只有发起绑定的那个窗口认领落库
            }
            .onChange(of: aiPanel.noteRequest) { _, req in
                applyAINoteRequest(req)    // 面板里选中一段回答 → 回填成本窗口的文字笔记
            }
    }

    /// 草稿纸的落库/广播路由。**必须单独包一层**，不能挂进 `mainSplit`——那个表达式的修饰符已经到顶，
    /// 再加三个 `onChange` 当场把 SwiftUI 类型检查器顶爆（实测 `unable to type-check in reasonable time`）。
    /// 同 `eventRoutes` 的既有分层理由。
    private func scratchRoutes<V: View>(_ base: V) -> some View {
        base
        .onChange(of: session.scratchPads) { _, _ in
            persistScratchPads()       // 草稿纸新建/改名/删除时增量落库
            app.broadcastScratchPads() // 列表变了 → 平板的草稿纸列表跟着变
        }
        .onChange(of: session.scratchStrokes) { _, _ in
            persistScratchStrokes()    // 草稿纸上落笔/擦除时增量落库（scratchLive 变化不触发）
            app.broadcastScratchStrokes()
        }
        .onChange(of: session.openPadID) { _, _ in
            // 打开/关闭草稿纸 = 平板跟着切过去（笔迹共享、视图各自独立）；同时把纸上的笔迹推过去。
            app.broadcastScratchPads()
            app.broadcastScratchStrokes()
        }
    }

    /// 主分栏视图（侧栏 + 阅读区 + 工具栏/inspector + 状态联动）。窗口事件路由挂 `eventRoutes`——
    /// 全部修饰符挂一个表达式上会让类型检查器超时（已踩过，见 toolbarContent 的同款注释）。
    private var mainSplit: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(selection: $selectedDocID, onChooseWorkspace: chooseWorkspace,
                        onCreateWorkspace: createNewWorkspace,
                        onOpenRecent: openRecentWorkspace,
                        onDropFiles: { ingest(urls: $0) }, onOpenPDF: openPDF,
                        onOpenInNewWindow: { docId in
                            // 新窗口必须带上**本窗口的**工作区，否则它会去开「上次使用的工作区」。
                            openWindow(value: WindowTarget(workspacePath: workspace.folder?.standardizedFileURL.path,
                                                           docId: docId))
                        })
                .navigationSplitViewColumnWidth(min: 200, ideal: 260)
        } detail: {
            detailColumn
        }
        .inspector(isPresented: $showNotes) {
            InspectorView(session: session, documentId: selectedDocID,
                          toc: session.toc, tab: $inspectorTab, onSelectTOC: jumpToTOC,
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
            // 换文档 = 标题/书库 open 标记/目录都变；平板发起的 openDoc 也在这里收尾（锁到新窗口）。
            // 挂在这里而不是 loadSelected 内部：那个函数有三条早退路径（无文档/路径失效/正常），
            // 出口逐个补一遍迟早漏掉一条。
            app.sessionDocumentChanged(session)
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
            // 必须在 register 之前：AppModel 要靠会话捎带的工作区快照才知道该把哪个书库广播给平板。
            syncWorkspaceSnapshot()
            app.register(session)
            // 页图缓存上限：启动套用存储值（设置页改动即时生效，这里覆盖引擎默认 400MB）。
            PageRenderEngine.shared.setCacheLimitMB(UserDefaults.standard.object(forKey: "renderCacheMB") as? Int ?? 512)
            if autoStartServer, !app.server.isRunning { app.server.start() }   // 平板服务开机自启
            if autoNightMode { nightMode = (systemScheme == .dark) }           // 夜间模式跟随系统
            WorkspaceRegistry.shared.noteWindow(session.id, path: workspace.folder?.path)
            if let id = launchDocId {
                didChooseInitialDoc = true
                selectedDocID = id                      // 「在新窗口打开」指定文档
            } else {
                decideInitialContent(from: "onAppear")
            }
        }
        .onChange(of: systemScheme) { _, s in if autoNightMode { nightMode = (s == .dark) } }
        .onChange(of: autoNightMode) { _, on in if on { nightMode = (systemScheme == .dark) } }
        .onChange(of: workspace.documents) { _, docs in
            // 选中文档被删除/合并掉后从列表消失（如「删除」）→ 清选中，阅读区回到空态。
            if let id = selectedDocID, !docs.contains(where: { $0.id == id }) {
                selectedDocID = nil
            }
            syncWorkspaceSnapshot()
            app.broadcastLibrary()   // 入库/删除/改名 → 平板的书库列表跟着变
        }
        .onChange(of: workspace.name) { _, _ in
            syncWorkspaceSnapshot()
            app.broadcastLibrary()   // 工作区改名 → 平板书库面板的标题
        }
        // 平板请求打开工作区里尚未打开的文档 → 由平板当前跟随的那个窗口开新窗口（其余窗口忽略，
        // 否则每个窗口都会开一个）。
        .onChange(of: app.padOpenDocRequest) { _, req in
            guard let req, req.sessionID == session.id else { return }
            app.padOpenDocRequest = nil
            openWindow(value: WindowTarget(workspacePath: req.workspacePath, docId: req.docId))
        }
        .onChange(of: workspace.folder) { _, f in
            // 工作区归属定死后 folder 只会因「工作区改名 → 联动改包名」而变；选中文档不受影响，
            // 只需把窗口↔工作区的登记跟到新路径（供「双击已打开的工作区 → 激活那个窗口」）。
            WorkspaceRegistry.shared.noteWindow(session.id, path: f?.path)
            syncWorkspaceSnapshot()
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
            .background(WindowAccessor(onKeyChange: { key in
                isKeyWindow = key
                if key {
                    app.setActive(session)
                    // AI 浮窗吸附：贴到刚激活的这扇窗口上（换窗口就跟过去）。
                    AIPanelDock.shared.setHost(WorkspaceRegistry.shared.window(for: session.id))
                    // 内置模式下每扇窗口都显示自己的面板 → **哪扇是 key，模型级操作就作用在哪扇**
                    // （绑定捕获 / 投递 / 导航按钮都读 `activeHost` 那一份页面）。
                    if AIPanelModel.shared.mode == .inline {
                        AIPanelModel.shared.setActiveHost(.inline(session.id))
                    }
                }
            }, onWindow: { win in
                WorkspaceRegistry.shared.noteWindowObject(session.id, window: win)
            }))
            .toolbar { toolbarContent }
    }

    /// 窗口级事件路由：关窗保存 / 菜单通知（⌘O 打开、⌘F 查找、⌥⌘N 夜间）/ 搜索收起清空 / 文件变化提示。
    private func eventRoutes<V: View>(_ base: V) -> some View {
        base
        .onDisappear {
            // 尾随补存必须在这里掐掉：它最长还能在关窗后 0.7s 写库，而那时本窗口已向 registry 放手，
            // 同路径若立刻被重新打开就会出现「旧实例还在写、新实例已在读」的重叠（红线，见 WorkspaceRegistry）。
            // 关窗本身紧接着就同步存一次，不会丢进度。
            progressSaveTask?.cancel()
            progressSaveTask = nil
            saveProgress(docId: selectedDocID)
            // 本窗口的内置 AI 面板那一份页面到这里才该放——**只在窗口真的没了时放**，
            // 切到别的窗口/收成气泡都不算（那会清掉正在进行的对话状态）。
            AIPanelModel.shared.releaseHost(.inline(session.id))
            AIPanelModel.shared.forgetInline(session.id)
            workspace.closeWindow(session.id)
            // ⚠️ 次序有讲究：写库那两步（进度 / 打开集）必须**先**做完，`noteWindow(nil)` 才可以把
            // 「本工作区已无窗口」这件事告诉 registry —— 它据此关掉库连接（`maybeTeardown`）。
            WorkspaceRegistry.shared.noteWindow(session.id, path: nil)
            app.unregister(session)
            session.teardown()   // 放掉本窗口持有的 PDF / 库引用（不然移动硬盘弹不出去）
        }
        .onReceive(NotificationCenter.default.publisher(for: .openPDFRequested)) { _ in
            if isKeyWindow { openPDF() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .newWindowRequested)) { _ in
            // ⌘N：在**当前窗口的**工作区里开一个新窗口（不是「上次使用的工作区」）。
            guard isKeyWindow, let p = workspace.folder?.standardizedFileURL.path else { return }
            openWindow(value: WindowTarget(workspacePath: p, docId: nil))
        }
        // 双击 .unrd / Dock 菜单的路由不在这里 —— 那是 app 级的事，挂在 `RootView`
        // （错误态窗口没有 ContentView，挂这里会在「只剩错误窗」时把请求静默丢掉）。
        .onReceive(NotificationCenter.default.publisher(for: .readerFind)) { _ in
            if isKeyWindow { searchIsActive = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: .toggleNightMode)) { _ in
            if isKeyWindow { nightMode.toggle() }   // ⌥⌘N：与工具栏月亮按钮同一 @AppStorage 状态
        }
        .onReceive(NotificationCenter.default.publisher(for: .toggleCanvasMode)) { _ in
            if isKeyWindow { toggleCanvasMode() }   // ⌥⌘C：与工具栏画板按钮同一路径（逐文档落库）
        }
        .onReceive(NotificationCenter.default.publisher(for: .toggleSidebar)) { _ in
            if isKeyWindow {                    // ⌘B：侧栏 ⇄ 仅阅读区
                columnVisibility = columnVisibility == .detailOnly ? .all : .detailOnly
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .toggleInspector)) { _ in
            if isKeyWindow { showNotes.toggle() }   // ⌘I：与工具栏 inspector 按钮同一状态
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

    /// 阅读列 = 阅读区内容 + 内置 AI 面板覆盖层。
    ///
    /// 🔴 **AI 面板必须挂在这一层**，理由有两条，缺一不可：
    ///  ① **身份要稳定**。它不能落在 `readerContent` 那个 `if` 分支里，也不能落在
    ///     `PageStreamView` 内部 `.id(docKey)` 的下游 —— 换文档时那些都会**整体重建**，
    ///     新的内置层向模型要页面拿到的还是同一个 `WebPage`，而旧的 `WebView` 尚未拆干净，
    ///     于是 `_WebKit_SwiftUI.makeViewProvider` 当场 trap（2026-08-26「开着 webview 切换书」秒崩）。
    ///     **「每宿主一份页面」只保证不同宿主不撞，挡不住同一宿主被重建。**
    ///  ② **要挡住阅读区的手势**。阅读区那四个拖拽手势挂在 `ScrollView` 容器上，用 `.overlay`
    ///     加在**同一个视图**上的覆盖层挡不住它们（草稿纸就是为此才要在每个 gesture 里写
    ///     `openPadID == nil`）。挂在这一层是普通遮挡关系，一行门控都不用加。
    ///
    /// 挂在 `readerColumn` 而不是更外层的 `mainSplit`：这样它只盖阅读区，不会盖住 Inspector。
    private var readerColumn: some View {
        readerContent
            .overlay { AIInlineLayer(session: session) }
    }

    @ViewBuilder
    private var readerContent: some View {
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
                toggleCanvasMode()
            } label: {
                Label(L("Canvas Mode"),
                      systemImage: session.canvasMode ? "arrow.left.and.right.square.fill"
                                                      : "arrow.left.and.right.square")
            }
            .disabled(session.pdf == nil)
            .help(L("Write in the blank space beside the page"))
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
            TOCListView(entries: session.toc, currentPage: session.currentPageIndex) { e in
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
        guard let page = e.pageIndex else { return }   // 坏书签（无目标页）：不跳转，别把它当第 1 页
        session.currentPageIndex = page
        session.emitAnchor(page: page, frac: e.frac, origin: "toc")
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
        routeToWorkspace(url, strict: true)
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
        // 先把包建出来（建好即是真实工作区），再按常规路径开一个窗口显示它。
        // 目标已经是工作区会在这里报错而非覆盖——不能因为面板弹过「替换」就删掉一整库笔记。
        do { try WorkspaceManager.createWorkspace(at: url) } catch {
            workspaceActionError = error.localizedDescription
            return
        }
        routeToWorkspace(url, strict: true)
    }

    /// 打开「最近工作区」列表中的一项：文件夹已不存在（被删/移走）或已不再是真实工作区
    /// （如内部 library.sqlite 被误删）→ 提示 + 自动从列表移除；否则照常开窗口。
    private func openRecentWorkspace(_ url: URL) {
        do {
            try WorkspaceManager.validate(url)
        } catch {
            WorkspaceRegistry.shared.removeRecent(url)
            WorkspaceRegistry.shared.missingRecentName = WorkspaceManager.defaultWorkspaceName(for: url)
            return
        }
        routeToWorkspace(url, strict: false)   // 刚验过，不必再验一遍
    }

    /// 侧栏入口（打开/新建/最近）走与双击 `.unrd` **同一条路由**（`WorkspaceRegistry.route`）：
    /// 校验 → 已有窗口就激活 → 否则开新窗口。失败在本窗口提示，不静默建空库。
    private func routeToWorkspace(_ url: URL, strict: Bool) {
        do {
            try WorkspaceRegistry.shared.route(to: url, strict: strict, openWindow: openWindow)
        } catch {
            workspaceActionError = error.localizedDescription
        }
    }

    /// 决定本窗口的初始文档。**工作区归属已由 `RootView` 定好**（本窗口的 `workspace` 就是它），
    /// 这里只管在这个工作区里选文档：`launchDocId` 指定了就用它，否则恢复该工作区的「上次打开集」。
    private func decideInitialContent(from source: String) {
        guard !didChooseInitialDoc else { return }
        didChooseInitialDoc = true
        guard let folder = workspace.folder else { return }
        // 「恢复整组文档」每个工作区只做一次（见 claimRestore）：⌘N 开的新窗口、以及被 restore
        // 开出来的那些窗口，都该止步于此，否则会连锁开窗。
        guard WorkspaceRegistry.shared.claimRestore(folder) else {
            wsLog("decideInitialContent(\(source))：本工作区已恢复过，留空窗口")
            return
        }
        wsLog("decideInitialContent(\(source))：工作区 \(folder.lastPathComponent) → restoreSession")
        restoreSession()
    }

    /// 恢复本工作区上次打开的整组文档：本窗口开第一个，其余各开一个新窗口（同一工作区）。
    private func restoreSession() {
        let docs = workspace.restoreDocIds.filter { workspace.document(id: $0) != nil }
        wsLog("restoreSession：打开集 \(workspace.restoreDocIds.count) 条，库里仍存在 \(docs.count) 条 → 本窗口开 \(docs.first ?? "（无）")")
        selectedDocID = docs.first
        guard let wsPath = workspace.folder?.standardizedFileURL.path else { return }
        // 只自动重开有限几个最近文档为独立窗口，避免「最近打开」较长时一次弹出过多窗口；
        // 其余仍在侧栏，一键可开。窗口都带上本工作区路径 —— 否则新窗口会去开「上次工作区」。
        for other in docs.dropFirst().prefix(4) {
            openWindow(value: WindowTarget(workspacePath: wsPath, docId: other))
        }
    }

    // MARK: - 选中加载

    /// 把本窗口工作区的名字/路径/书库拷进会话，供 `AppModel.broadcastLibrary`（App 级、够不着
    /// 窗口级的 `@MainActor WorkspaceManager`）与 `openPadDoc` 判定「这个文档是不是同工作区里已开着的」。
    private func syncWorkspaceSnapshot() {
        session.workspaceName = workspace.name
        session.workspaceFolder = workspace.folder
        session.libraryDocs = workspace.documents
    }

    private func loadSelected(_ id: String?) {
        session.clearSearch()   // 换文档：旧文档的查找命中/高亮不应带过去
        // 换文档 → 本窗口发起的那条 AI 绑定上下文作废，否则面板的上下文条会一直显示上一本书。
        aiPanel.noteDocumentChanged(sessionID: session.id, documentId: id)
        session.store = workspace.store   // OCR 缓存读写用（仅主线程）
        session.restoreZoom = 1; session.readZoom = 1   // 默认 fit-width；成功路径按库覆盖
        session.restoreHFrac = 0; session.readHFrac = 0
        session.canvasMode = false                      // 画板模式逐文档记，同上按库覆盖
        guard let id, let doc = workspace.document(id: id) else {
            session.pdf = nil; missingDoc = nil; session.toc = []; session.title = ""
            clearInk(); clearInkLayers(); clearTextNotes(); clearHighlights(); clearScratch()
            clearAIThreads()
            session.reloadOCRState(); return
        }
        guard let target = workspace.openTarget(documentId: id),
              let pdf = PDFDocument(url: URL(fileURLWithPath: target.path)) else {
            session.pdf = nil
            session.title = ""
            missingDoc = doc                       // 所有路径失效 → 显示重定位提示
            session.toc = []
            clearInk()
            clearInkLayers()
            clearTextNotes()
            clearHighlights()
            clearScratch()
            clearAIThreads()
            return
        }
        missingDoc = nil
        session.pdf = pdf
        session.toc = TOCEntry.build(from: pdf)
        session.title = doc.title
        session.contentHash = target.hash
        session.reloadOCRState()                   // 换文档重置 OCR；该内容已有缓存则自动启用
        loadInk(documentId: id)                    // 恢复该文档已落库的手写笔迹
        loadInkLayers(documentId: id)               // 恢复该文档的图层注册表（含自愈补建）
        session.noteTypes = workspace.noteTypes()   // 工作区笔记类型（通用内置兜底，不在列）
        session.noteTypeFilter = .all               // 筛选仅内存，开文档复位
        loadTextNotes(documentId: id)              // 恢复该文档已落库的文字注解
        loadHighlights(documentId: id)             // 恢复该文档已落库的高亮
        loadAIThreads(documentId: id)              // 恢复该文档已落库的 AI 会话绑定
        loadScratch(documentId: id)                // 恢复该文档的草稿纸与纸上笔迹（默认不打开任何一张）
        // 恢复阅读进度：缩放倍率 + 定页 + 精确滚到页内比例（restore 锚点，阅读区(PageStreamView)会跟随）。
        let p = workspace.progress(documentId: id)
        session.restoreZoom = CGFloat(p.zoom)      // 首帧定基准后由 PageStreamView 套用
        session.readZoom = CGFloat(p.zoom)
        session.restoreHFrac = CGFloat(p.hfrac)    // 横向滚动比例（缩放态/画板模式才非 0）
        session.readHFrac = p.hfrac
        session.canvasMode = p.canvas              // 画板模式（v12）
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

    // MARK: - 画板模式（v12）

    /// 切画板模式（工具栏按钮 / ⌥⌘C）。
    private func toggleCanvasMode() { setCanvasMode(!session.canvasMode) }

    /// 设画板模式：改 session（阅读区 onChange 里做布局补偿 + 广播给平板）+ 立即落库（逐文档记，
    /// 不走阅读进度那套节流——它不像滚动位置那样每帧都变）。没开文档时空转。
    /// 本机按钮与**平板上行**（`padCanvasRequest`）共用这一条，别在两处各写一遍落库。
    private func setCanvasMode(_ on: Bool) {
        guard session.pdf != nil, let id = selectedDocID, session.canvasMode != on else { return }
        session.canvasMode = on
        workspace.setCanvasMode(documentId: id, on: on)
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
        let t0 = CFAbsoluteTimeGetCurrent()
        let current = session.strokes
        let currentIDs = Set(current.map(\.id))
        var upserts = 0, deletes = 0
        for st in current where session.persistedStrokes[st.id] != st {
            workspace.saveInkStroke(documentId: id, st)
            upserts += 1
        }
        for goneID in session.persistedStrokes.keys where !currentIDs.contains(goneID) {
            workspace.deleteInkStroke(id: goneID)
            deletes += 1
        }
        session.persistedStrokes = Dictionary(uniqueKeysWithValues: current.map { ($0.id, $0) })
        // 每收一笔主线程要花的账（`PadLog`，默认关；开关见 UniReaderApp.swift）。
        // 三段各自的量纲不同，要分开看：
        // - **派发**＝ `strokes` 变了到这里开跑，含 SwiftUI 对整个 `[InkStroke]` 数组做的相等性比较；
        // - **对账**＝ 本函数自身：逐条整值比较（比的是全部点）+ 重建整张 id→笔迹 快照；
        // 后两段都是 O(笔迹数 × 点数)、每收一笔跑一遍，写久了的文档就是它们在吃主线程。
        if session.lastInkEndAt > 0 {
            let dispatch = t0 - session.lastInkEndAt
            let reconcile = CFAbsoluteTimeGetCurrent() - t0
            // 字符串（含那个数点数的 reduce）在 PadLog 的 @autoclosure 里，关着的时候一行都不跑
            PadLog.log("收笔对账 \(current.count)条/\(current.reduce(0) { $0 + $1.points.count })点："
                + "派发 \(PadLog.ms(dispatch))，对账 \(PadLog.ms(reconcile))（写 \(upserts) 删 \(deletes)）")
            session.lastInkEndAt = 0   // 只量收笔那一次；擦除/框选也会进来，别混进同一条读数
        }
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

    // MARK: - AI 会话绑定持久化（note kind=1）

    /// 清空内存 AI 会话与对账集（对账集先于列表赋值，同 loadTextNotes 防切档误删）。
    private func clearAIThreads() {
        session.persistedAIThreads = [:]
        session.aiThreads = []
    }

    private func loadAIThreads(documentId id: String) {
        let loaded = workspace.aiThreads(documentId: id)
        session.persistedAIThreads = Dictionary(uniqueKeysWithValues: loaded.map { ($0.id, $0) })
        session.aiThreads = loaded
    }

    private func persistAIThreads() {
        guard let id = session.documentId else { return }
        let current = session.aiThreads
        let currentIDs = Set(current.map(\.id))
        for t in current where session.persistedAIThreads[t.id] != t {
            workspace.saveAIThread(documentId: id, t)
        }
        for goneID in session.persistedAIThreads.keys where !currentIDs.contains(goneID) {
            workspace.deleteAIThread(id: goneID)
        }
        session.persistedAIThreads = Dictionary(uniqueKeysWithValues: current.map { ($0.id, $0) })
    }

    /// 应用 AI 面板发来的落库请求。
    ///
    /// **为什么要绕这一圈**：面板是 App 级单例（一个浮窗服务所有窗口），而 `LibraryStore` 是窗口级
    /// 且同一个库只许一个连接（`REQUIREMENTS.md §8.1` 红线）。面板不碰库，只发请求，由**发起这次
    /// 绑定的那个窗口**认领落库——认领条件是 `sessionID` + `documentId` 双对（同 `padOpenDocRequest`
    /// 带 sessionID 的理由：不带的话每个窗口都会执行一遍）。
    /// 写进 `session.aiThreads` 之后，上面的 `.onChange` 增量对账会把它写库，不在这里直接写。
    private func applyAIThreadUpsert(_ req: AIThreadUpsert?) {
        guard let req, req.sessionID == session.id, req.documentId == session.documentId else { return }
        if let i = session.aiThreads.firstIndex(where: { $0.id == req.thread.id }) {
            session.aiThreads[i] = req.thread
        } else {
            session.aiThreads.append(req.thread)
        }
        aiPanel.consumeUpsert()
    }

    /// 认领 AI 面板发来的建笔记请求（S5）。认领条件与 `applyAIThreadUpsert` 一样是
    /// **sessionID + documentId 双对**；写进 `session.textNotes` 之后，既有的 `.onChange`
    /// 增量对账会把它落库，不在这里直接写库。
    private func applyAINoteRequest(_ req: AINoteRequest?) {
        guard let req, req.sessionID == session.id, req.documentId == session.documentId else { return }
        session.textNotes.append(req.note)
        aiPanel.consumeNoteRequest()
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

    // MARK: - 草稿纸持久化（scratch_pad 表 + note kind=4，v8）

    /// 加载文档时清空内存草稿纸/纸上笔迹与两份对账集（无文档 / 路径失效时用）。
    /// ⚠️ 与 `clearInk` 同一条纪律：对账集必须**先于**列表赋值，否则 `.onChange` 会拿旧文档的
    /// 快照对账新（空）列表，把上一篇的草稿纸整个从库里删掉。
    private func clearScratch() {
        session.openPadID = nil
        session.scratchLive = nil
        session.persistedScratchPads = [:]
        session.persistedScratchStrokes = [:]
        session.scratchPads = []
        session.scratchStrokes = []
    }

    /// 恢复该文档已落库的草稿纸与纸上笔迹。**默认一张都不打开**——草稿纸是覆盖层，
    /// 开着文档就弹一张纸盖住正文不是用户要的语义（要看哪张走图钉/侧栏列表）。
    private func loadScratch(documentId id: String) {
        session.openPadID = nil
        session.scratchLive = nil
        let pads = workspace.scratchPads(documentId: id)
        let strokes = workspace.scratchStrokes(documentId: id)
        session.persistedScratchPads = Dictionary(uniqueKeysWithValues: pads.map { ($0.id, $0) })
        session.persistedScratchStrokes = Dictionary(uniqueKeysWithValues: strokes.map { ($0.id, $0) })
        session.scratchPads = pads
        session.scratchStrokes = strokes
    }

    /// 内存草稿纸 ↔ 库对账：新增/改名/改底色 upsert；已删除的 delete（纸上笔迹由下面那个函数
    /// 一并对账掉——删纸时调用方要同时把它的笔迹从 `scratchStrokes` 里摘掉）。
    private func persistScratchPads() {
        guard let id = session.documentId else { return }
        let current = session.scratchPads
        let currentIDs = Set(current.map(\.id))
        for p in current where session.persistedScratchPads[p.id] != p {
            workspace.saveScratchPad(documentId: id, p)
        }
        for goneID in session.persistedScratchPads.keys where !currentIDs.contains(goneID) {
            workspace.deleteScratchPad(id: goneID)
        }
        session.persistedScratchPads = Dictionary(uniqueKeysWithValues: current.map { ($0.id, $0) })
    }

    /// 内存草稿纸笔迹 ↔ 库对账（与 `persistInk` 同套路，只是走 kind=4）。
    private func persistScratchStrokes() {
        guard let id = session.documentId else { return }
        let current = session.scratchStrokes
        let currentIDs = Set(current.map(\.id))
        for st in current where session.persistedScratchStrokes[st.id] != st {
            workspace.saveInkStroke(documentId: id, st)
        }
        for goneID in session.persistedScratchStrokes.keys where !currentIDs.contains(goneID) {
            workspace.deleteInkStroke(id: goneID)
        }
        session.persistedScratchStrokes = Dictionary(uniqueKeysWithValues: current.map { ($0.id, $0) })
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
