import AppKit
import PDFKit
import SwiftUI

// 三个 pane = `NSSplitViewController` 三段各自的 SwiftUI 内容（方案 `APPKIT-WINDOW-PLAN.md` §3）。
// 它们是原 `ContentView` 拆开来的：分栏、工具栏、标题栏、菜单认领那几件事已经归
// `ReaderWindowController`，这里只剩「画什么」。

/// 侧栏段。
struct SidebarPane: View {
    @ObservedObject var tabs: TabsModel
    var onChooseWorkspace: () -> Void
    var onCreateWorkspace: () -> Void
    var onOpenRecent: (URL) -> Void
    var onDropFiles: ([URL]) -> Void
    var onOpenPDF: () -> Void
    var onOpenInNewWindow: (String) -> Void

    /// 侧栏选中 ↔ 当前标签的文档。写入走 `tabs.open`：**已开着就切过去，没开就新建标签**。
    private var selection: Binding<String?> {
        Binding(get: { tabs.active.docID }, set: { _ = tabs.open($0) })
    }

    var body: some View {
        SidebarView(selection: selection,
                    onChooseWorkspace: onChooseWorkspace,
                    onCreateWorkspace: onCreateWorkspace,
                    onOpenRecent: onOpenRecent,
                    onDropFiles: onDropFiles,
                    onOpenPDF: onOpenPDF,
                    onOpenInNewWindow: onOpenInNewWindow)
    }
}

/// Inspector 段（信息 / 目录 / 笔记）。
struct InspectorPane: View {
    @ObservedObject var tabs: TabsModel
    @State private var tab: InspectorTab = .info

    private var session: DocSession { tabs.active.session }

    var body: some View {
        InspectorView(session: session, documentId: tabs.active.docID,
                      toc: session.toc, tab: $tab,
                      onSelectTOC: { e in
                          guard let page = e.pageIndex else { return }   // 坏书签：跳不过去
                          session.jump(page: page, frac: e.frac, kind: .toc, label: e.label)
                      },
                      onJumpTo: { page, frac in
                          session.jump(page: page, frac: frac, kind: .list)
                      })
    }
}

/// 阅读区段：页流 + 浮层（标签栏 / 两块 AI 面板的钩子 / 参考窗 / 跳转历史）+ 查找条，右侧并排两块内置 AI 面板。
///
/// 🔴 浮层全部挂在**这一层**（`readerArea`），与迁移前完全一样的两条理由：身份要稳
/// （不能落进 `PageStreamView` 内部 `.id(docKey)` 的下游），以及要挡得住阅读区那四个挂在
/// `ScrollView` 上的拖拽手势（`.overlay` 加在同一个视图上挡不住）。
struct ReaderPane: View {
    @ObservedObject var tabs: TabsModel
    @ObservedObject var chrome: WindowChrome
    @ObservedObject var refWindow: RefWindowModel
    @ObservedObject var jumpPanel: JumpHistoryPanel
    var onRelocate: (LibDocument) -> Void
    var onIngest: ([URL]) -> Void

    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var workspace: WorkspaceManager

    @AppStorage("nightMode") private var nightMode = false
    @AppStorage("autoNightMode") private var autoNightMode = false
    @AppStorage("scrollInterp") private var scrollInterp = true
    @AppStorage(TabBarStyle.key) private var tabBarStyleRaw = TabBarStyle.floating.rawValue
    @Environment(\.colorScheme) private var systemScheme

    private var tab: DocTabModel { tabs.active }
    private var session: DocSession { tab.session }

    private var tabBarInset: CGFloat {
        TabBarMetrics.inset(style: TabBarStyle(rawValue: tabBarStyleRaw) ?? .floating,
                            tabCount: tabs.tabs.count)
    }

    /// 🔴 接鼠标时系统用**占位式**滚动条：水平条的槽固定在阅读区最底边。给它设
    /// `contentMargins(.bottom, for: .scrollIndicators)` 只会把条挪上去、槽留在原地——条浮在页面上、
    /// 最底下空一条深色槽（2026-09-17 用户报，独立复现程序量过 NSScroller / NSClipView 的 frame）。
    /// 所以占位式时滚动条不让位，改由标签栏整体抬高一条槽的高度。悬浮式滚动条不占槽，照旧让位。
    @State private var legacyScroller = NSScroller.preferredScrollerStyle == .legacy
    private var scrollerLift: CGFloat {
        legacyScroller && tabBarInset > 0
            ? NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy) : 0
    }

    private func bind<V>(_ keyPath: ReferenceWritableKeyPath<DocSession, V>) -> Binding<V> {
        Binding(get: { session[keyPath: keyPath] }, set: { session[keyPath: keyPath] = $0 })
    }

    var body: some View {
        let _ = session.openTrace?.markOnce("阅读区段 body")   // 打开耗时账本：各段 body 的先后（找首帧后主线程忙在哪）
        readerColumn
            .dropDestination(for: URL.self) { urls, _ in onIngest(urls); return true }
            .onChange(of: systemScheme) { _, s in if autoNightMode { nightMode = (s == .dark) } }
            .onChange(of: autoNightMode) { _, on in if on { nightMode = (systemScheme == .dark) } }
            .onChange(of: tabs.activeID) { _, _ in
                session.clearSearch()   // 换标签 = 换一本书，上一本的命中/高亮不该带过来
            }
            .onChange(of: session.searchQuery) { _, _ in session.scheduleSearch() }
            .onReceive(NotificationCenter.default.publisher(for: .toggleNightMode)) { _ in
                if chrome.isKeyWindow { nightMode.toggle() }
            }
            .onReceive(NotificationCenter.default.publisher(for: .toggleCanvasMode)) { _ in
                if chrome.isKeyWindow { tab.toggleCanvasMode() }
            }
            .onReceive(NotificationCenter.default.publisher(for: .jumpBackRequested)) { _ in
                if chrome.isKeyWindow { session.jumpBack() }
            }
            .onReceive(NotificationCenter.default.publisher(for: .jumpForwardRequested)) { _ in
                if chrome.isKeyWindow { session.jumpForward() }
            }
            .onReceive(NotificationCenter.default.publisher(for: .toggleJumpHistory)) { _ in
                if chrome.isKeyWindow { jumpPanel.toggle() }
            }
            .onReceive(NotificationCenter.default.publisher(for: .addBookmarkRequested)) { _ in
                if chrome.isKeyWindow, session.documentId != nil { session.beginBookmarkAtCurrent() }
            }
            // 书签命名框：三条入口（⌘D / 阅读区右键 / Inspector 目录页的 +）都只是把落点写进
            // `session.bookmarkDraft`，弹框统一挂在这一层——它们分属不同视图树，宿主放这儿才都够得着。
            .sheet(item: bind(\.bookmarkDraft)) { draft in
                BookmarkNameSheet(draft: draft,
                                  onSave: { session.commitBookmarkDraft(title: $0) },
                                  onCancel: { session.bookmarkDraft = nil })
            }
            .alert(L("File Changed"), isPresented: hashAlertPresented, presenting: tab.hashMismatch,
                   actions: hashAlertActions, message: hashAlertMessage)
    }

    /// 阅读区 + 两块内置面板**并排**（从左到右：阅读区 | Agent | 咨询 AI）。面板展开时把阅读区往左挤，
    /// 不再盖在 PDF 上（用户 2026-09-18）。面板收起时整个不存在，阅读区占满。滑入 / 滑出动画见 `InlinePanelsColumn`。
    /// 展开 / 收起走阅读窗口工具栏上的两枚开关；`readerArea` 覆盖层里的 `.lifecycle` 只挂钩子，不显示东西。
    private var readerColumn: some View {
        InlinePanelsColumn(windowID: tabs.windowID) {
            readerArea
        } panels: {
            AgentInlineLayer(windowID: tabs.windowID, workspaceFolder: workspace.folder,
                             workspaceName: workspace.name, part: .panel)
            AIInlineLayer(session: session, part: .panel)
        }
    }

    private var readerArea: some View {
        readerContent
            // 浮层一律给右侧的内置面板让位（阅读区外框铺满、面板盖在上面，见 `InlinePanelsColumn`）
            .overlay(alignment: .top) { findBanner.modifier(ReaderPanelInsetPadding()) }   // 内置面板开着时仍居中在 PDF 上方
            .overlay(alignment: .bottom) {
                tabBar.padding(.bottom, scrollerLift).modifier(ReaderPanelInsetPadding())
            }
            .onReceive(NotificationCenter.default.publisher(
                for: NSScroller.preferredScrollerStyleDidChangeNotification)) { _ in
                legacyScroller = NSScroller.preferredScrollerStyle == .legacy
            }
            .overlay { AIInlineLayer(session: session, part: .lifecycle) }
            .overlay {
                AgentInlineLayer(windowID: tabs.windowID, workspaceFolder: workspace.folder,
                                 workspaceName: workspace.name, part: .lifecycle)
            }
            .overlay { refWindowLayer.modifier(ReaderPanelInsetPadding()) }
            .overlay { jumpHistoryLayer.modifier(ReaderPanelInsetPadding()) }
            // 扫描页对齐（`SCAN-ALIGN-PLAN.md`）：挂在这里而不是 `body` 那条修饰符链上——那条早就到类型检查器的时限了
            .onReceive(NotificationCenter.default.publisher(for: .toggleScanAlign)) { _ in
                if chrome.isKeyWindow { tab.toggleScanAlign() }
            }
            .alert(L("Align Scanned Pages"), isPresented: scanAlignAlertPresented, presenting: tab.scanAlignConfirm,
                   actions: scanAlignAlertActions, message: scanAlignAlertMessage)
    }

    @ViewBuilder
    private var readerContent: some View {
        if session.pdf != nil {
            // docKey = 显示身份（`DocSession.displayKey`）：页图缓存键 + 阅读区 `.id`。扫描页对齐一切换键就变，
            // 阅读区整个按新页面重建，缓存也不会拿到另一种页面的旧图。
            PageStreamView(session: session,
                           docKey: session.displayKey,
                           nightMode: nightMode,
                           interpEnabled: scrollInterp,
                           isActiveWindow: chrome.isKeyWindow,
                           bottomInset: tabBarInset + scrollerLift,
                           indicatorBottomInset: legacyScroller ? 0 : tabBarInset,
                           onDropFiles: onIngest)   // 拖进阅读区的 PDF 仍入库；图片由阅读区自己收成图片笔记
                .overlay(alignment: .top) {
                    Group {
                        if tab.isHashing { indexingBadge }
                        else if let p = tab.scanAlignProgress { scanAlignBadge(p) }
                    }
                    .modifier(ReaderPanelInsetPadding())
                }
        } else if let doc = tab.missingDoc {
            ContentUnavailableView {
                Label(L("File Not Found"), systemImage: "questionmark.folder")
            } description: {
                Text(String(format: L("All known paths for “%@” are unavailable. Re-link the file to continue."), doc.title))
            } actions: {
                Button(L("Re-link File…")) { onRelocate(doc) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .modifier(ReaderPanelInsetPadding())
        } else {
            // 撑满阅读区：不撑的话 ContentUnavailableView 只有内容那么大，挂在它底边的标签栏
            // 就跑到屏幕中间、还被压成窄条（2026-09-17 用户截图）。
            ContentUnavailableView(
                L("No Document"),
                systemImage: "doc.richtext",
                description: Text(L("Open a PDF to start reading."))
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .top) { if tab.isHashing { indexingBadge } }
            .modifier(ReaderPanelInsetPadding())
        }
    }

    /// 底部标签栏。草稿纸开着时不显示——那是盖满阅读区的覆盖层，自带工具条与 minimap。
    private var tabBar: some View {
        ZStack(alignment: .bottom) {
            if session.openPadID == nil {
                TabBarView(tabs: tabs, padSessionID: app.padSession?.id,
                           onOpenInNewWindow: { docId in
                               AppDelegate.shared?.openReaderWindow(
                                   workspacePath: workspace.folder?.standardizedFileURL.path, docId: docId)
                           })
            }
            // ⌘T 时标签栏没显示（只有一个标签 / 草稿纸开着）→「+」不在，选文档弹窗改挂这个点上。
            Color.clear.frame(width: 1, height: 1)
                .padding(.bottom, TabBarMetrics.floatBottom)
                .allowsHitTesting(false)
                .popover(isPresented: pickerWithoutTabBar, arrowEdge: .bottom) {
                    DocPickerView.forTabs(tabs, workspace: workspace)
                }
        }
    }

    private var pickerWithoutTabBar: Binding<Bool> {
        Binding(get: { tabs.docPickerPresented && (tabs.tabs.count <= 1 || session.openPadID != nil) },
                set: { tabs.docPickerPresented = $0 })
    }

    @ViewBuilder
    private var refWindowLayer: some View {
        if session.openPadID == nil {
            RefWindowView(model: refWindow, workspace: workspace, nightMode: nightMode,
                          currentDocID: tab.docID,
                          onGotoMain: { page in session.jump(page: page, frac: 0, kind: .list) })
        }
    }

    @ViewBuilder
    private var jumpHistoryLayer: some View {
        if session.openPadID == nil {
            JumpHistoryView(panel: jumpPanel, session: session)
        }
    }

    /// 搜索状态条（Safari 式）：有搜索词时浮在阅读区顶部——命中计数 + 上/下一个。
    ///
    /// 输入框在工具栏（`NSSearchToolbarItem`，⌘F 让它进编辑态），这里只补「导航」这一层——
    /// 与迁移前 `.searchable` + findBanner 的分工完全一致。
    @ViewBuilder
    private var findBanner: some View {
        if !session.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            HStack(spacing: 8) {
                Text(findStatusText)
                    .font(.caption).foregroundStyle(.primary).fixedSize()
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

    private var indexingBadge: some View {
        Label(L("Indexing…"), systemImage: "clock")
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(.thinMaterial, in: Capsule())
            .padding(.top, 8)
    }

    /// 扫描页对齐测量中。文字显式 `.primary`（material 底上别用 `.secondary`，AGENTS.md 红线）。
    private func scanAlignBadge(_ p: DocTabModel.ScanAlignProgress) -> some View {
        Label(String(format: L("Aligning scanned pages… %d/%d"), p.done, p.total), systemImage: "text.alignleft")
            .foregroundStyle(.primary)
            .monospacedDigit()
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(.thinMaterial, in: Capsule())
            .padding(.top, 8)
    }

    // MARK: 扫描页对齐的确认弹窗

    private var scanAlignAlertPresented: Binding<Bool> {
        Binding(get: { tab.scanAlignConfirm != nil }, set: { if !$0 { tab.scanAlignConfirm = nil } })
    }

    @ViewBuilder
    private func scanAlignAlertActions(_ c: DocTabModel.ScanAlignConfirm) -> some View {
        Button(c.turnOn ? L("Align Pages") : L("Turn Off Alignment")) { tab.applyScanAlign(c) }
        Button(L("Cancel"), role: .cancel) { tab.scanAlignConfirm = nil }
    }

    private func scanAlignAlertMessage(_ c: DocTabModel.ScanAlignConfirm) -> Text {
        var parts: [String] = []
        if c.notes > 0 {
            parts.append(String(format: L("This document has %d annotations. They will not move with the pages and may end up out of place."), c.notes))
        }
        if c.ocrPages > 0 {
            parts.append(String(format: L("Text recognition results for %d pages will be cleared and need to be recognized again."), c.ocrPages))
        }
        if c.needsMeasure { parts.append(L("The whole document will be analyzed first, which may take a few seconds.")) }
        return Text(parts.joined(separator: "\n\n"))
    }

    // MARK: 「文件已变化」alert

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
}

/// 阅读区 + 两块内置面板的外壳：面板**滑入 / 滑出**（用户 2026-09-19）。
///
/// 🔴 **阅读区的外框始终铺满，面板开合不改它的尺寸**（2026-09-19 实测）：之前用 HStack 让阅读区变窄，
/// 只要滚动视图的外框被 SwiftUI 改了宽度（不是拖窗口那种系统调整），内容区上方的玻璃工具栏按钮就会
/// 被系统重新判断一次深浅，整几组变浅（录屏确认；拖窗口、开合 Inspector 都不会）。
/// 现在面板浮在右侧叠层里滑动；它盖住的宽度通过环境值 `readerPanelInset` 告诉阅读区，
/// 由阅读区自己按「全宽 − 这部分」适配页面（`PageStreamView`），外框不动。
struct InlinePanelsColumn<Reader: View, Panels: View>: View {
    let windowID: UUID
    @ViewBuilder var reader: Reader
    @ViewBuilder var panels: Panels

    @ObservedObject private var agent = AgentPanelModel.shared
    @ObservedObject private var consult = AIPanelModel.shared

    static var slide: Animation { .smooth(duration: 0.28) }

    private var agentOpen: Bool { agent.mode == .inline && agent.enabled && agent.isInlineOpen(windowID) }
    private var consultOpen: Bool { consult.mode == .inline && consult.enabled && consult.isInlineOpen(windowID) }
    /// 面板占掉的阅读区右侧宽度（= 开着的面板宽度之和）。开合时**一步到位、不带动画**：
    /// 阅读区自己会在宽度稳定 0.2s 后适配一次；叠在阅读区上的标签栏等由 `ReaderPanelInsetPadding` 带动画让位。
    private var inset: CGFloat {
        (agentOpen ? CGFloat(agent.inlineWidth) : 0) + (consultOpen ? CGFloat(consult.inlineWidth) : 0)
    }

    var body: some View {
        reader
            .environment(\.readerPanelInset, inset)
            .overlay(alignment: .trailing) {
                HStack(spacing: 0) { panels }
                    .animation(Self.slide, value: agentOpen)
                    .animation(Self.slide, value: consultOpen)
            }
            .clipped()   // 滑入前 / 滑出后面板在右边界外，别画到窗口别处
    }
}

extension EnvironmentValues {
    /// 内置 AI 面板盖住的阅读区右侧宽度（`InlinePanelsColumn` 给，阅读区与叠在它上面的浮层各自让位）。
    @Entry var readerPanelInset: CGFloat = 0
}

/// 阅读区上的浮层（查找条 / 标签栏 / 参考窗 / 跳转历史 / 空态）给右侧的内置面板让位，随面板滑动带动画。
struct ReaderPanelInsetPadding: ViewModifier {
    @Environment(\.readerPanelInset) private var inset

    func body(content: Content) -> some View {
        content
            .padding(.trailing, inset)
            .animation(InlinePanelsColumn<EmptyView, EmptyView>.slide, value: inset)
    }
}
