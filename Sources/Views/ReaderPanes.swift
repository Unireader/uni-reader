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

/// 阅读区段：页流 + 四层浮层（标签栏 / AI 内置面板 / 参考窗 / 跳转历史）+ 查找条。
///
/// 🔴 浮层全部挂在**这一层**（`readerColumn`），与迁移前完全一样的两条理由：身份要稳
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

    @State private var findActive = false
    @FocusState private var findFocused: Bool

    private var tab: DocTabModel { tabs.active }
    private var session: DocSession { tab.session }

    private var tabBarInset: CGFloat {
        TabBarMetrics.inset(style: TabBarStyle(rawValue: tabBarStyleRaw) ?? .floating,
                            tabCount: tabs.tabs.count)
    }

    private func bind<V>(_ keyPath: ReferenceWritableKeyPath<DocSession, V>) -> Binding<V> {
        Binding(get: { session[keyPath: keyPath] }, set: { session[keyPath: keyPath] = $0 })
    }

    var body: some View {
        readerColumn
            .dropDestination(for: URL.self) { urls, _ in onIngest(urls); return true }
            .overlay(alignment: .top) { findBar }
            .onChange(of: systemScheme) { _, s in if autoNightMode { nightMode = (s == .dark) } }
            .onChange(of: autoNightMode) { _, on in if on { nightMode = (systemScheme == .dark) } }
            .onChange(of: tabs.activeID) { _, _ in
                findActive = false          // 换标签 = 换一本书，查找条显示的是上一本的东西
                session.clearSearch()
            }
            .onChange(of: session.searchQuery) { _, _ in session.scheduleSearch() }
            .onReceive(NotificationCenter.default.publisher(for: .readerFind)) { _ in
                guard chrome.isKeyWindow else { return }
                findActive = true
                findFocused = true
            }
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
            .alert(L("File Changed"), isPresented: hashAlertPresented, presenting: tab.hashMismatch,
                   actions: hashAlertActions, message: hashAlertMessage)
    }

    private var readerColumn: some View {
        readerContent
            .overlay(alignment: .bottom) { tabBar }
            .overlay { AIInlineLayer(session: session) }
            .overlay { refWindowLayer }
            .overlay { jumpHistoryLayer }
    }

    @ViewBuilder
    private var readerContent: some View {
        if session.pdf != nil {
            PageStreamView(session: session,
                           docKey: session.contentHash,
                           nightMode: nightMode,
                           interpEnabled: scrollInterp,
                           isActiveWindow: chrome.isKeyWindow,
                           bottomInset: tabBarInset)
                .overlay(alignment: .top) { if tab.isHashing { indexingBadge } }
        } else if let doc = tab.missingDoc {
            ContentUnavailableView {
                Label(L("File Not Found"), systemImage: "questionmark.folder")
            } description: {
                Text(String(format: L("All known paths for “%@” are unavailable. Re-link the file to continue."), doc.title))
            } actions: {
                Button(L("Re-link File…")) { onRelocate(doc) }
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

    /// 底部标签栏。草稿纸开着时不显示——那是盖满阅读区的覆盖层，自带工具条与 minimap。
    @ViewBuilder
    private var tabBar: some View {
        if session.openPadID == nil {
            TabBarView(tabs: tabs, padSessionID: app.padSession?.id,
                       onOpenInNewWindow: { docId in
                           AppDelegate.shared?.openReaderWindow(
                               workspacePath: workspace.folder?.standardizedFileURL.path, docId: docId)
                       })
        }
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

    /// 查找条（⌘F）。
    ///
    /// 迁移前输入框是工具栏的 `.searchable`，而那是 SwiftUI 往 `window.toolbar` 里塞的东西之一
    /// ——正是这次要收回的。M0 先用浮在顶部的一条自带输入框顶上，M2 换成
    /// `NSSearchToolbarItem`（方案 §5）。
    @ViewBuilder
    private var findBar: some View {
        if findActive {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").imageScale(.small).foregroundStyle(.secondary)
                TextField(L("Find in Document"), text: bind(\.searchQuery))
                    .textFieldStyle(.plain)
                    .frame(width: 200)
                    .focused($findFocused)
                    .onSubmit { session.nextMatch() }
                Text(findStatusText)
                    .font(.caption).foregroundStyle(.secondary).fixedSize()
                Button { session.prevMatch() } label: {
                    Image(systemName: "chevron.up").frame(width: 22, height: 22).contentShape(Rectangle())
                }
                .disabled(session.searchMatches.isEmpty)
                Button { session.nextMatch() } label: {
                    Image(systemName: "chevron.down").frame(width: 22, height: 22).contentShape(Rectangle())
                }
                .disabled(session.searchMatches.isEmpty)
                Button {
                    findActive = false
                    session.clearSearch()
                } label: {
                    Image(systemName: "xmark").frame(width: 22, height: 22).contentShape(Rectangle())
                }
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
