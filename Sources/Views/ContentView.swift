import SwiftUI
import PDFKit
import AppKit
import UniformTypeIdentifiers

struct ContentView: View {
    let launchDocId: String?   // 该窗口启动时要打开的文档（nil = 主/⌘N 窗口）

    @Environment(\.openWindow) private var openWindow
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var workspace: WorkspaceManager

    /// 本窗口的标签页集合（`MAC-TABS-PLAN.md`）。每个标签一个 `DocTabModel`，它自己管加载 /
    /// 增量对账落库 / 进度存取 / 工作区登记，**不依赖视图生命周期**（后台标签也照样落库）。
    ///
    /// ⚠️ 依赖由 `RootView` 显式传进来、而不是从环境里取：`@StateObject` 的初值只在首次挂载时
    /// 求值一次，而 `@EnvironmentObject` 在 `init` 里还拿不到——传参是让它一开始就握有非可选
    /// 依赖的唯一办法，否则只能退化成「先建空壳再 attach」，凭空多出一个「尚未 attach」的中间态。
    @StateObject private var tabs: TabsModel

    init(launchDocId: String?, app: AppModel, workspace: WorkspaceManager) {
        self.launchDocId = launchDocId
        _tabs = StateObject(wrappedValue: TabsModel(app: app, workspace: workspace))
    }

    /// 当前显示的标签。`TabsModel` 保证 `tabs` 永远至少有一个，故这里非可选——
    /// 于是本视图从「单标签」改过来时，除了这一行几乎不用动。
    private var tab: DocTabModel { tabs.active }

    /// 当前标签的会话（阅读区 / Inspector / 工具栏都读它）。
    private var session: DocSession { tab.session }

    /// 侧栏选中 ↔ 当前标签的文档。写入走 `tabs.open`：**已开着就切过去，没开就新建标签**
    /// （用户 2026-08-29 定「同一个工作区打开都是走新的 tab」）。
    private var selectionBinding: Binding<String?> {
        Binding(get: { tab.docID }, set: { tabs.open($0) })
    }

    /// ⌘W：**关当前标签**，只剩一个标签时才关窗口（同 Safari / Xcode）。
    private func closeTabOrWindow() {
        if tabs.canCloseTab { tabs.close(tabs.activeID) }
        else { WorkspaceRegistry.shared.window(for: session.id)?.performClose(nil) }
    }

    /// 🔴 **⌘W 必须用事件监视器抢，光挂菜单快捷键抢不过**（2026-08-29 真机实测：按下去关掉的是
    /// 整扇窗口）。AppKit 自带的「文件 › 关闭」也占着 ⌘W，谁拿到键取决于菜单顺序，赌不得。
    /// 本地 keyDown 监视器跑在**菜单等价键判定之前**，所以这里能可靠地截住。
    ///
    /// 每扇窗口各装一个：事件是全 app 广播的，故先核对「本窗口是不是 key window」再认领；
    /// 不是就原样放行（设置窗、AI 浮窗按下 ⌘W 仍是系统的关窗语义）。
    /// 只剩一个标签时也放行——让系统照常关窗，省得自己再走一遍 performClose。
    private func installCloseTabHotkey() {
        guard closeTabMonitor.value == nil else { return }
        // ⚠️ 先把对象取出来再捕获：逃逸闭包捕获的是 View 的**值拷贝**，从那份拷贝上读
        // `@StateObject` 包装器属于「未安装在视图上」的访问，语义没有保证。
        let model = tabs
        closeTabMonitor.value = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { ev in
            guard ev.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                  ev.charactersIgnoringModifiers == "w",
                  model.canCloseTab,
                  WorkspaceRegistry.shared.window(for: model.active.session.id)?.isKeyWindow == true
            else { return ev }
            model.close(model.activeID)
            return nil   // 吃掉，别让「文件 › 关闭」再把整扇窗关了
        }
    }

    /// 监视器句柄。装在**引用类型**里而不是 `@State`：`onDisappear` 的闭包捕获的是 View 的值拷贝，
    /// 用 `@State` 存的话摘除时可能读到 nil，监视器就永远留在 app 里了。
    private final class MonitorBox { var value: Any? }

    /// 会话某个属性的双向绑定。`session` 现在是计算属性、没有 `$session` 投影，
    /// 而 `.searchable`/`Toggle`/`Picker` 要的是 `Binding`。
    /// （会话的变更由 `DocTabModel` 转发过来，所以读到的永远是最新值。）
    private func bind<V>(_ keyPath: ReferenceWritableKeyPath<DocSession, V>) -> Binding<V> {
        Binding(get: { session[keyPath: keyPath] }, set: { session[keyPath: keyPath] = $0 })
    }
    // 目录（`session.toc`）挂在会话上而不是本视图 @State：平板的 `toc` 广播由 App 级的 AppModel 发，
    // 它只够得着 DocSession。两处显示同一份，不再各建各的。
    @State private var closeTabMonitor = MonitorBox()   // ⌘W 事件监视器（见 installCloseTabHotkey）
    @State private var showTOCPopover = false        // 一次性目录弹窗（选完即关，快速跳转）
    @State private var inspectorTab: InspectorTab = .info   // Inspector 当前分段（信息/目录/笔记）
    @State private var showServer = false
    @State private var isKeyWindow = false
    @State private var showNotes = false
    @State private var columnVisibility: NavigationSplitViewVisibility = .all   // ⌘B 切侧栏
    @State private var searchIsActive = false   // 标准 .searchable 搜索字段的展开态（⌘F 激活）
    @State private var didChooseInitialDoc = false   // 本窗口的初始文档已定（防重复恢复）
    @State private var workspaceActionError: String?   // 打开/新建工作区失败（如选中非真实工作区文件夹）待提示
    @State private var showOCR = false
    @AppStorage("ocrEngine") private var ocrEngine = "off"          // OCR 引擎（"off" | "paddle"），设置页写入
    @AppStorage("nightMode") private var nightMode = false
    @AppStorage("scrollInterp") private var scrollInterp = true   // 平板滚动跟随：true=时间戳插值 / false=纯低通（A/B 用）
    @AppStorage("autoNightMode") private var autoNightMode = false     // 夜间模式跟随系统深色外观
    @AppStorage("autoStartServer") private var autoStartServer = false // 启动即开平板服务
    @AppStorage("showTOCButton") private var showTOCButton = true    // 工具栏「目录」按钮（设置页可关）
    @AppStorage("showOCRButton") private var showOCRButton = true    // 工具栏「文字识别」按钮（设置页可关）
    @AppStorage(TabBarStyle.key) private var tabBarStyleRaw = TabBarStyle.floating.rawValue
    /// 阅读区底部要给标签栏让出的高度（笔架夹取 + 滚动条避让都用它；只有一个标签时为 0）。
    private var tabBarInset: CGFloat {
        TabBarMetrics.inset(style: TabBarStyle(rawValue: tabBarStyleRaw) ?? .floating,
                            tabCount: tabs.tabs.count)
    }
    @Environment(\.colorScheme) private var systemScheme

    var body: some View {
        eventRoutes(mainSplit)
    }

    /// 主分栏视图（侧栏 + 阅读区 + 工具栏/inspector + 状态联动）。窗口事件路由挂 `eventRoutes`——
    /// 全部修饰符挂一个表达式上会让类型检查器超时（已踩过，见 toolbarContent 的同款注释）。
    private var mainSplit: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(selection: selectionBinding, onChooseWorkspace: chooseWorkspace,
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
            InspectorView(session: session, documentId: tab.docID,
                          toc: session.toc, tab: $inspectorTab, onSelectTOC: jumpToTOC,
                          onJumpTo: { page, frac in
                              session.currentPageIndex = page
                              session.emitAnchor(page: page, frac: frac, origin: "toc")
                          })
                .inspectorColumnWidth(min: 240, ideal: 300, max: 400)
        }
        // 这里原本还挂着「切文档 / 翻页 / 滚动 / 缩放 / 笔迹 / 图层 / 注解 / 高亮」八条落库 onChange，
        // 已整体搬进 `DocTabModel`（Combine 订阅，与标签可不可见无关）。
        .onAppear {
            // 页图缓存上限：启动套用存储值（设置页改动即时生效，这里覆盖引擎默认 256MB）。
            // ⚠️ 默认值与 `SettingsView.renderCacheMB` 的 `@AppStorage` 默认**必须一致**，改一处要改两处。
            PageRenderEngine.shared.setCacheLimitMB(UserDefaults.standard.object(forKey: "renderCacheMB") as? Int ?? 256)
            if autoStartServer, !app.server.isRunning { app.server.start() }   // 平板服务开机自启
            if autoNightMode { nightMode = (systemScheme == .dark) }           // 夜间模式跟随系统
            installCloseTabHotkey()
            // 会话注册 / 工作区快照 / 窗口↔工作区登记都在 `DocTabModel.init` 里做了（标签级的事）。
            if let id = launchDocId {
                didChooseInitialDoc = true
                tabs.open(id)                           // 「在新窗口打开」指定文档
            } else {
                decideInitialContent(from: "onAppear")
            }
        }
        .onChange(of: systemScheme) { _, s in if autoNightMode { nightMode = (s == .dark) } }
        .onChange(of: autoNightMode) { _, on in if on { nightMode = (systemScheme == .dark) } }
        .onChange(of: tabs.activeID) { _, _ in
            // 换标签 = 换一本书：查找条与两个弹窗都该收起来（它们显示的是上一本的东西）。
            searchIsActive = false
            showTOCPopover = false
            showOCR = false
        }
        .onChange(of: workspace.documents) { _, docs in
            // 文档被删除/合并掉后从库里消失 → 开着它的标签关掉（只剩一个标签时退回空态）。
            tabs.pruneMissing(docs)
            tabs.syncWorkspaceSnapshot()
            app.broadcastLibrary()   // 入库/删除/改名 → 平板的书库列表跟着变
        }
        .onChange(of: workspace.name) { _, _ in
            tabs.syncWorkspaceSnapshot()
            app.broadcastLibrary()   // 工作区改名 → 平板书库面板的标题
        }
        // 平板请求打开工作区里尚未打开的文档 → **在它跟随的那扇窗口里开新标签**
        // （用户 2026-08-29 拍板，推翻 2026-08-05「新开一个 Mac 窗口」的旧决定）。
        // 认领条件从「等于本窗口当前会话」放宽成「是本窗口的某个标签」——平板可以跟着后台标签。
        .onChange(of: app.padOpenDocRequest) { _, req in
            guard let req, tabs.owns(req.sessionID) else { return }
            app.padOpenDocRequest = nil
            tabs.open(req.docId)
        }
        .onChange(of: workspace.folder) { _, f in
            // 工作区归属定死后 folder 只会因「工作区改名 → 联动改包名」而变；选中文档不受影响，
            // 只需把窗口↔工作区的登记跟到新路径（供「双击已打开的工作区 → 激活那个窗口」）。
            tabs.noteWorkspacePath(f?.path)
            tabs.syncWorkspaceSnapshot()
        }
        // 标签页菜单命令（⌘T / ⌘W / ⇧⌘W / ⌃Tab / ⌃⇧Tab），由 key 窗口响应——
        // 与本 app 其余所有菜单命令同一套 notification 路由。
        .onReceive(NotificationCenter.default.publisher(for: .newTabRequested)) { _ in
            if isKeyWindow { tabs.newTab() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .closeTabRequested)) { _ in
            guard isKeyWindow else { return }
            closeTabOrWindow()
        }
        .onReceive(NotificationCenter.default.publisher(for: .closeWindowRequested)) { _ in
            if isKeyWindow { WorkspaceRegistry.shared.window(for: session.id)?.performClose(nil) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .nextTabRequested)) { _ in
            if isKeyWindow { tabs.activate(offset: 1) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .prevTabRequested)) { _ in
            if isKeyWindow { tabs.activate(offset: -1) }
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
            .searchable(text: bind(\.searchQuery), isPresented: $searchIsActive,
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
                    // 🔴 宿主按**窗口**分而不是按标签分（`session.windowID`）：按会话 id 分的话，
                    // 切标签就是换宿主，而「同一宿主被重建」会让 WebKit 当场 trap
                    // （2026-08-26「开着 webview 切换书」秒崩，见 `AIInlineLayer` 注释）。
                    if AIPanelModel.shared.mode == .inline {
                        AIPanelModel.shared.setActiveHost(.inline(session.windowID))
                    }
                }
            }, onWindow: { win in
                // 每个标签的会话都登记到同一扇 NSWindow —— 各处按会话 id 反查窗口的地方
                // （AI 浮窗吸附、「双击已打开的工作区 → 激活那扇窗」）才查得到。
                tabs.noteWindowObject(win)
            }))
            .toolbar { toolbarContent }
    }

    /// 窗口级事件路由：关窗保存 / 菜单通知（⌘O 打开、⌘F 查找、⌥⌘N 夜间）/ 搜索收起清空 / 文件变化提示。
    private func eventRoutes<V: View>(_ base: V) -> some View {
        base
        .onDisappear {
            // 本窗口的内置 AI 面板那一份页面到这里才该放——**只在窗口真的没了时放**，
            // 切到别的窗口/收成气泡都不算（那会清掉正在进行的对话状态）。
            if let m = closeTabMonitor.value { NSEvent.removeMonitor(m); closeTabMonitor.value = nil }
            AIPanelModel.shared.releaseHost(.inline(session.windowID))
            AIPanelModel.shared.forgetInline(session.windowID)
            // 每个标签各自结清：掐尾随补存 → 同步补落库 → 存进度 → 退出打开集 → 交还工作区登记 →
            // 注销会话 → 放掉 PDF/库引用。**次序有讲究，全在 `DocTabModel.close()` 里**（含红线注释）。
            // 🔴 必须**逐个**结清，漏掉后台标签就是「进度丢了 + 库连接关不掉 → 移动硬盘弹不出去」。
            tabs.closeWindow()
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
            if isKeyWindow { tab.toggleCanvasMode() }   // ⌥⌘C：与工具栏画板按钮同一路径（逐文档落库）
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
        .alert(L("File Changed"), isPresented: hashAlertPresented, presenting: tab.hashMismatch,
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
    ///
    /// **标签栏同挂这一层**，同样的两条理由（身份要稳、要挡得住阅读区手势）；排在 AI 面板**之前**，
    /// 于是面板展开时盖住标签栏右端而不是反过来。
    private var readerColumn: some View {
        readerContent
            .overlay(alignment: .bottom) { tabBar }
            .overlay { AIInlineLayer(session: session) }
    }

    /// 底部标签栏。草稿纸开着时不显示——那是盖满阅读区的覆盖层，自带工具条与 minimap，
    /// 再叠一条标签栏就是三层浮层打架。
    @ViewBuilder
    private var tabBar: some View {
        if session.openPadID == nil {
            TabBarView(tabs: tabs, padSessionID: app.padSession?.id,
                       onOpenInNewWindow: { docId in
                           openWindow(value: WindowTarget(
                               workspacePath: workspace.folder?.standardizedFileURL.path,
                               docId: docId))
                       })
        }
    }

    @ViewBuilder
    private var readerContent: some View {
        if session.pdf != nil {
            PageStreamView(session: session,
                           docKey: session.contentHash,
                           nightMode: nightMode,
                           interpEnabled: scrollInterp,
                           isActiveWindow: isKeyWindow,
                           bottomInset: tabBarInset)
                .overlay(alignment: .top) { if tab.isHashing { indexingBadge } }
        } else if let doc = tab.missingDoc {
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
            .overlay(alignment: .top) { if tab.isHashing { indexingBadge } }
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
                tab.toggleCanvasMode()
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
                Toggle(L("Show recognition blocks (debug)"), isOn: bind(\.showOCRBlocks))
                Text(L("Colors each recognized text block to inspect layout/selection accuracy."))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if session.showOCRBlocks {
                    Picker("", selection: bind(\.ocrBlockGrouped)) {
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
        tab.isHashing = true
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
            tab.isHashing = false
            if let lastId { tab.select(lastId) }   // 触发加载
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
        wsLog("decideInitialContent(\(source))：工作区 \(folder.lastPathComponent) → restoreTabs")
        tabs.restoreTabs()
    }

    // MARK: - 「文件已变化」alert（从 body 抽出，防类型检查器超时）

    private var hashAlertPresented: Binding<Bool> {
        Binding(get: { tab.hashMismatch != nil }, set: { if !$0 { tab.hashMismatch = nil } })
    }

    @ViewBuilder
    private func hashAlertActions(_ m: DocTabModel.HashMismatch) -> some View {
        Button(L("Link as New Version")) { tab.linkAsNewVersion(m) }
        Button(L("Open Anyway"), role: .cancel) { tab.openAnyway(m) }
    }

    private func hashAlertMessage(_ m: DocTabModel.HashMismatch) -> Text {
        Text(String(format: L("The file “%@” was replaced on disk and no longer matches the version in your library. Link it as a new version of this document? (Notes are kept either way.)"),
                    (m.path as NSString).lastPathComponent))
    }

    // MARK: - 重定位

    /// 选文件（面板留在视图层），改库 + 重载交给标签自己（`DocTabModel.relocate`）。
    private func relocate(_ doc: LibDocument) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = String(format: L("Choose the file for “%@”."), doc.title)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        tab.relocate(doc, url: url)
    }
}
