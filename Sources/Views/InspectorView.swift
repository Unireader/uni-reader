import SwiftUI

enum InspectorTab: Hashable { case info, thumbnails, contents, notes }

/// 「笔记」页的**二级分区**（2026-09-02 用户：文字/高亮/笔迹/草稿纸/AI 全堆一页「太多了看不过来」）。
/// 一次只显示一类，各自带自己的计数与空态；选中项记在 `@AppStorage` 里，换文档/重开都还在原处。
enum NotesSection: String, CaseIterable, Identifiable {
    case text, highlight, image, bookmark, ink, scratch, ai

    var id: String { rawValue }

    /// 二级分区栏是**图标分段**（面板窄，七个字标签排不下）。文字标签仍给辅助功能与块标题用。
    var icon: String {
        switch self {
        case .text: return "note.text"
        case .highlight: return "highlighter"
        case .image: return "photo"
        case .bookmark: return "bookmark"
        case .ink: return "scribble"
        case .scratch: return "square.and.pencil"
        case .ai: return "bubble.left.and.bubble.right"
        }
    }

    var title: String {
        switch self {
        case .text: return L("Text Notes")
        case .highlight: return L("Highlights")
        case .image: return L("Image Notes")
        case .bookmark: return L("Bookmarks")
        case .ink: return L("Ink")
        case .scratch: return L("Scratchpads")
        case .ai: return L("AI Chats")
        }
    }
}

/// 右侧 inspector（仿 Xcode）：顶部**图标分段**切「信息 / 目录 / 笔记」，默认就在这里，无固定/取消操作。
/// **无横线分割**——信息/笔记页用 ScrollView + 区块（小标题 + 行），文件项用淡色圆角卡片区隔，目录页用无分隔列表。
struct InspectorView: View {
    @EnvironmentObject private var workspace: WorkspaceManager
    @ObservedObject var session: DocSession
    let documentId: String?
    var toc: [TOCEntry]
    @Binding var tab: InspectorTab
    var onSelectTOC: (TOCEntry) -> Void
    var onJumpTo: (Int, Double) -> Void   // 跳到 (页, 页内比例)：Inspector 笔迹项点击用


    @State private var variants: [LibVariant] = []
    @State private var locations: [LibLocation] = []
    /// 笔迹区块的折叠态。**默认展开**——从前它与另外四类挤在同一页、条目又最多，只好默认折起来；
    /// 现在它自己一个分区，再折起来就是一页空白。
    @State private var inkExpanded = true
    /// 笔迹按页汇总（库里查的全篇，见 `inkBlock`）。
    @State private var inkSummaries: [InkPageSummary] = []
    /// 「笔记」页停在哪个二级分区（记住，换文档/重开都回到这里）。
    @AppStorage("inspectorNotesSection") private var notesSectionRaw = NotesSection.text.rawValue

    private let tabs: [(tab: InspectorTab, icon: String)] = [
        (.info, "info.circle"),
        (.thumbnails, "rectangle.grid.1x2"),
        (.contents, "list.bullet.indent"),
        (.notes, "note.text"),
    ]

    var body: some View {
        // 打开耗时账本：冷开「王道计组」首帧后主线程还连着忙 230ms（2026-09-10 日志 `首张页图 +118 → 下一拍 +351`），
        // 先把各块 body 的时刻记下来看是谁——检查器一页几百行注解/高亮是嫌疑之一。
        let _ = session.openTrace?.markOnce("检查器 body",
            "\(tab) 注解\(session.textNotes.count) 高亮\(session.highlights.count) AI\(session.aiThreads.count)")
        VStack(spacing: 0) {
            tabBar
            content
        }
        .task(id: documentId) { reload() }
    }

    // 仿 Xcode inspector 选择器：浅色轨道 + 选中段强调色圆角块，图标偏大。
    private var tabBar: some View {
        HStack(spacing: 3) {
            ForEach(tabs, id: \.tab) { seg in
                Button { tab = seg.tab } label: {
                    Image(systemName: seg.icon)
                        .font(.system(size: 15, weight: .semibold))
                        .frame(maxWidth: .infinity, minHeight: 28)
                        .foregroundStyle(tab == seg.tab ? Color.white : Color.secondary)
                        .background(tab == seg.tab ? Color.accentColor : Color.clear, in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(.quaternary.opacity(0.6), in: Capsule())
        .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 8)
    }

    @ViewBuilder
    private var content: some View {
        if tab == .contents {
            // 目录页 = PDF 目录 + 书签（合并成一棵树，规格 `REQUIREMENTS.md §1.9`）。
            VStack(spacing: 0) {
                HStack {
                    Spacer()
                    Button { session.beginBookmarkAtCurrent() } label: {
                        Label(L("Add Bookmark"), systemImage: "bookmark")
                            .font(.callout)
                            .foregroundStyle(.primary)   // 红线：别用 .secondary，系统会画得几乎看不见
                    }
                    .buttonStyle(.plain)
                    .help(L("Add Bookmark"))
                    .disabled(session.documentId == nil)
                }
                .padding(.horizontal, 12).padding(.bottom, 6)
                TOCListView(entries: toc, currentPage: session.currentPageIndex,
                            bookmarks: session.bookmarks,
                            onSelectBookmark: { b in
                                session.jump(page: b.page, frac: b.frac, kind: .toc, label: b.title)
                            },
                            onRenameBookmark: { session.beginBookmarkRename($0) },
                            onDeleteBookmark: { session.deleteBookmark(id: $0.id) },
                            onSelect: onSelectTOC)
            }
        } else if tab == .thumbnails {
            ThumbnailListView(pdf: session.pdf, documentId: session.contentHash,
                              currentPage: session.currentPageIndex) { page in
                onJumpTo(page, 0)
            }
            // 换文档/切标签 = 全新一份列表：它的 `images` 字典按页号存，不重建的话上一本书的
            // 缩略图（最多 48 张、连 CA 副本上百 MB）会留在字典里，还会先顶在新书的同页号格子上。
            .id(session.contentHash)
        } else if let id = documentId, let doc = workspace.document(id: id) {
            if tab == .info {
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        infoBlock(doc)
                        filesBlock
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                // 笔记页 = 二级分区栏 + 当前那一类。分区栏用**系统 segmented Picker**——
                // 红线：系统观感只能用系统标准 API，不自绘（顶上那条一级栏是既有的自绘胶囊，
                // 两级长得不一样反而正好分得清层级）。
                VStack(spacing: 0) {
                    notesSectionPicker
                    ScrollView {
                        notesSectionBody
                            .padding(16)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        } else {
            ContentUnavailableView(L("No Document"), systemImage: "sidebar.right",
                                   description: Text(L("Select a document to see its info and notes.")))
        }
    }

    // MARK: - 笔记页的二级分区

    private var notesSection: NotesSection { NotesSection(rawValue: notesSectionRaw) ?? .text }

    private var notesSectionPicker: some View {
        Picker("", selection: Binding(get: { notesSection },
                                      set: { notesSectionRaw = $0.rawValue })) {
            ForEach(NotesSection.allCases) { s in
                // 只画图标（面板窄，六个中文标签排不下），文字仍留给辅助功能与悬停提示
                Label(s.title, systemImage: s.icon).labelStyle(.iconOnly).tag(s)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .padding(.horizontal, 12).padding(.bottom, 8)
    }

    @ViewBuilder
    private var notesSectionBody: some View {
        switch notesSection {
        case .text: textBlock
        case .highlight: highlightBlock
        case .image: imageBlock
        case .bookmark: bookmarkBlock
        case .ink: inkBlock
        case .scratch: scratchBlock
        case .ai: aiBlock
        }
    }

    // MARK: - 信息页

    private func infoBlock(_ doc: LibDocument) -> some View {
        block(L("Document")) {
            infoRow(L("Title"), doc.title)
            infoRow(L("Pages"), "\(doc.pageCount)")
            let cur = min(session.currentPageIndex + 1, max(1, doc.pageCount))
            let pct = doc.pageCount > 0 ? Int((Double(cur) / Double(doc.pageCount) * 100).rounded()) : 0
            infoRow(L("Progress"), "\(cur) / \(doc.pageCount) · \(pct)%")
            infoRow(L("Added"), doc.addedAt.formatted(date: .abbreviated, time: .shortened))
            infoRow(L("Last Opened"), doc.lastOpenedAt.formatted(date: .abbreviated, time: .shortened))
        }
    }

    private func block<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            content()
        }
    }

    private func infoRow(_ k: String, _ v: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(k).foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(v).multilineTextAlignment(.trailing)
        }
        .font(.callout)
    }

    private var filesBlock: some View {
        let hashByVar = Dictionary(variants.map { ($0.id, $0.contentHash) }, uniquingKeysWith: { a, _ in a })
        return block("\(L("Files")) · \(locations.count)") {
            ForEach(locations) { l in
                HStack(alignment: .top, spacing: 6) {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(URL(fileURLWithPath: l.path).lastPathComponent).font(.callout).lineLimit(1)
                            if l.inWorkspace { badge(L("In Workspace"), .green) }
                            else if l.isRelative { badge(L("Same Drive"), .blue) }
                            if !l.isValid { badge(L("Missing"), .orange) }
                            Spacer()
                            Text(String((hashByVar[l.variantId] ?? "").prefix(8)))
                                .font(.system(.caption2, design: .monospaced)).foregroundStyle(.secondary)
                                .lineLimit(1).fixedSize()   // 同上：8 位哈希断不得，断了也会撑高整行
                        }
                        Text(workspace.resolvedPath(l))
                            .font(.caption2).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                    // × 删除该文件条目（至少保留一项 → 仅在多于一项时可删）。
                    if locations.count > 1 {
                        Button { deleteLocation(l) } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.body).foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                        .help(l.inWorkspace ? L("Delete this workspace copy") : L("Remove this file entry"))
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 7))
            }
        }
    }

    /// 删除一个文件条目（工作区内副本连文件一并删）。UI 已保证至少留一项。
    private func deleteLocation(_ l: LibLocation) {
        guard locations.count > 1 else { return }
        workspace.deleteLocation(l)
        reload()
    }

    /// 手写笔迹：默认折叠（系统 DisclosureGroup，不自绘），标题行保持与其他区块同款样式。
    /// 按页列表来自库里的全篇汇总（`InkPageSummary.load`）：笔迹按页窗口装载后（`InkWindow`）内存里只有
    /// 当前窗口那几页，从 `session.strokes` 分组就是只列一小截。`strokes` 每变一次（`inkRev`）后台重查一遍。
    private var inkBlock: some View {
        DisclosureGroup(isExpanded: $inkExpanded) {
            inkRows
                .padding(.top, 8)
        } label: {
            Text("\(L("Ink")) · \(inkSummaries.reduce(0) { $0 + $1.count })")
                .font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
        }
        .task(id: "\(documentId ?? "")#\(session.inkRev)") {
            // 每写一笔 `inkRev` 都 +1；先歇 0.3s——连着写字时前面那些请求会被新 id 取消掉，
            // 别让每一笔都去跑一遍全篇 GROUP BY（那条语句会把库锁住几十毫秒，主线程的落库要等它）。
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            let store = session.store, doc = documentId
            let loaded = await Task.detached(priority: .utility) { InkPageSummary.load(store: store, documentId: doc) }.value
            if !Task.isCancelled { inkSummaries = loaded }
        }
    }

    @ViewBuilder
    private var inkRows: some View {
        VStack(alignment: .leading, spacing: 8) {
            if inkSummaries.isEmpty {
                Text(L("No ink yet.")).foregroundStyle(.secondary).font(.callout)
            } else {
                ForEach(inkSummaries) { s in
                    HStack(spacing: 6) {
                        Button {
                            onJumpTo(s.page, max(0, s.minY - 0.05))   // 点击 → 跳到该页笔迹处（最靠上的一笔略上移一点）
                        } label: {
                            HStack(spacing: 6) {
                                Label(String(format: L("Page %d"), s.page + 1), systemImage: "pencil.tip").font(.callout)
                                Spacer()
                                ForEach(Array(s.colors.prefix(6).enumerated()), id: \.offset) { _, c in
                                    Circle().fill(Color(nsColor: c.nsColor)).frame(width: 10, height: 10)
                                }
                                Text("\(s.count)").foregroundStyle(.secondary).font(.caption)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        Button {
                            deleteInk(page: s.page)               // × → 删该页全部笔迹（内存移除→onChange 落库删行）
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.body).foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                        .help(L("Delete ink on this page"))
                    }
                }
            }
        }
    }

    // MARK: AI 会话绑定（note kind=1）

    /// AI 会话列表：打开会话 / 跳到锚点页 / 解绑。
    /// 新建走阅读区右键「用 … 讨论本页」——绑定总得先有个落点才谈得上锚定（同草稿纸）。
    private var aiBlock: some View {
        block("\(L("AI Chats")) · \(session.aiThreads.count)") {
            if session.aiThreads.isEmpty {
                Text(L("No AI chats yet. Right-click in the page to start one."))
                    .foregroundStyle(.secondary).font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(session.aiThreads) { t in aiRow(t) }
            }
        }
    }

    @ViewBuilder
    private func aiRow(_ t: AIThread) -> some View {
        HStack(spacing: 6) {
            Button { openAIThread(t) } label: {
                HStack(spacing: 6) {
                    Label(t.hasTitle ? t.title : L("Untitled chat"),
                          systemImage: t.state == .suspect ? "exclamationmark.bubble"
                                                           : "bubble.left.and.text.bubble.right")
                        .font(.callout).lineLimit(1)
                    Spacer()
                    Text(String(format: L("p.%d"), t.page + 1))
                        .foregroundStyle(.secondary).font(.caption)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(t.state == .suspect ? L("This conversation may no longer exist.") : t.url)

            Button {
                onJumpTo(t.page, Double(t.anchor.minY))
            } label: {
                Image(systemName: "scope").font(.caption).foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .help(L("Go to anchor"))

            Button {
                session.aiThreads.removeAll { $0.id == t.id }   // onChange 对账把这条 note 删库
            } label: {
                Image(systemName: "xmark.circle.fill").font(.body).foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .help(L("Unbind (the conversation itself stays on the platform)"))
        }
    }

    /// 打开一条已绑会话：开面板 → 载入那条 URL。绑定上下文照原记录重建，于是标题/失效状态的
    /// 后续更新仍会回到**本窗口**落库（`AIThreadUpsert` 认 sessionID + documentId 双对）。
    private func openAIThread(_ t: AIThread) {
        guard let docId = documentId else { return }
        AIPanelModel.shared.present(window: session.windowID)
        AIPanelModel.shared.openThread(t, in: AIBindContext(sessionID: session.id, documentId: docId,
                                                            docTitle: session.title,
                                                            page: t.page, anchor: t.anchor))
    }

    // MARK: 草稿纸（v8）

    /// 草稿纸列表：点开、跳到锚点、删除。新建走阅读区右键「在此新建草稿纸」（要有个落点才谈得上锚定）。
    private var scratchBlock: some View {
        block("\(L("Scratchpads")) · \(session.scratchPads.count)") {
            if session.scratchPads.isEmpty {
                Text(L("No scratchpads yet. Right-click in the page to add one."))
                    .foregroundStyle(.secondary).font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(Array(session.scratchPads.enumerated()), id: \.element.id) { i, pad in
                    scratchRow(index: i, pad: pad)
                }
            }
        }
    }

    @ViewBuilder
    private func scratchRow(index i: Int, pad: ScratchPad) -> some View {
        let count = session.scratchStrokes.count { $0.padId == pad.id }
        HStack(spacing: 6) {
            Button {
                session.openPadID = pad.id      // 打开覆盖层
            } label: {
                HStack(spacing: 6) {
                    Label(pad.displayName(index: i), systemImage: "square.and.pencil")
                        .font(.callout).lineLimit(1)
                    Spacer()
                    Text("\(count)").foregroundStyle(.secondary).font(.caption)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(String(format: L("Open · anchored on page %d"), pad.anchorPage + 1))

            Button {
                onJumpTo(pad.anchorPage, pad.anchorY)   // 跳到它挂着的那一页那一处（不打开纸）
            } label: {
                Image(systemName: "scope").font(.caption).foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .help(L("Go to anchor"))

            Button {
                deleteScratchPad(pad.id)
            } label: {
                Image(systemName: "xmark.circle.fill").font(.body).foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .help(L("Delete this scratchpad and its ink"))
        }
    }

    /// 删除一张草稿纸：纸与纸上的笔迹一起摘掉（两个数组各自的 onChange 对账会清库）。
    private func deleteScratchPad(_ id: UUID) {
        if session.openPadID == id { session.openPadID = nil; session.scratchLive = nil }
        session.scratchPads.removeAll { $0.id == id }
        session.scratchStrokes.removeAll { $0.padId == id }
    }

    /// 删除某页全部手写笔迹：从内存移除 → ContentView 的 onChange 增量对账把对应 note 删库。
    /// 那一页不在装载窗口里时先同步补读进来再删（`InkWindow`）——走内存这条路才可撤销。
    private func deleteInk(page: Int) {
        session.inkEnsureLoaded?(page)
        session.inkEdit("Delete", kind: .delete) { session.strokes.removeAll { $0.page == page } }
    }

    /// 当前筛选下的笔记列表：.all 全部 / .only(nil) 通用 / .only(id) 指定类型。
    private var filteredTextNotes: [TextNote] {
        session.textNotes.filter { n in
            switch session.noteTypeFilter {
            case .all: return true
            case .only(let id): return n.typeId == id
            }
        }
    }

    private var textBlock: some View {
        block("\(L("Text Notes")) · \(filteredTextNotes.count)") {
            if session.textNotes.isEmpty {
                Text(L("No text notes yet.")).foregroundStyle(.secondary).font(.callout)
            } else {
                noteTypeFilterMenu
                ForEach(filteredTextNotes) { n in
                    let t = NoteType.resolve(n.typeId, in: session.noteTypes)
                    HStack(alignment: .top, spacing: 6) {
                        Button {
                            onJumpTo(n.page, max(0, n.anchor.minY - 0.03))   // 跳到该批注所在页/位置
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 6) {
                                    Circle().fill(t.uiColor).frame(width: 8, height: 8)
                                    Label(String(format: L("Page %d"), n.page + 1), systemImage: t.icon)
                                        .font(.callout)
                                    if t.id != NoteType.generalID {
                                        Text(t.name).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                if !n.text.isEmpty {
                                    Text(NoteMarkdown.plain(n.text)).font(.callout).lineLimit(2)   // 列表里只要文字，不要 Markdown 记号
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                if !n.quote.isEmpty {
                                    Text(n.quote.flattenedQuote).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        if let src = n.source, src.isAI {
                            Button { openAISource(src) } label: {
                                Image(systemName: "bubble.left.and.text.bubble.right")
                                    .font(.caption).foregroundStyle(.tertiary)
                            }
                            .buttonStyle(.plain)
                            .help(L("Open the AI conversation this came from"))
                        } else if let src = n.source, src.isAgent {
                            // 外部 Agent 经 MCP 写的（没有可点回去的链接，只标来源）
                            Image(systemName: "terminal")
                                .font(.caption).foregroundStyle(.tertiary)
                                .help(String(format: L("Written by an agent (%@)"), src.provider))
                        }

                        Button {
                            deleteTextNote(n)   // × → 从内存移除 → ContentView onChange 对账删 note 行
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.body).foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                        .help(L("Delete this note"))
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 7))
                }
            }
        }
    }

    /// 从一条 AI 回填的笔记跳回它的出处对话。绑定记录还在就正常打开（连带上下文），
    /// 已被解绑就只按 URL 开一次、不重新建绑定。
    private func openAISource(_ src: NoteSource) {
        if let tid = src.threadId, let t = session.aiThreads.first(where: { $0.id == tid }) {
            openAIThread(t)
            return
        }
        AIPanelModel.shared.present(window: session.windowID)
        AIPanelModel.shared.openLoose(src.url, provider: src.provider)
    }

    /// 类型筛选菜单：全部 / 通用 / 各自定义类型。选中项显示在 label 上。
    private var noteTypeFilterMenu: some View {
        Menu {
            Button { session.noteTypeFilter = .all } label: {
                Label(L("All Types"), systemImage: "line.3.horizontal.decrease.circle")
            }
            Button { session.noteTypeFilter = .only(nil) } label: {
                Label(L("General"), systemImage: NoteType.general.iconName)
            }
            ForEach(session.noteTypes) { t in
                Button { session.noteTypeFilter = .only(t.id) } label: {
                    Label(t.name, systemImage: t.icon)
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "line.3.horizontal.decrease.circle")
                Text(filterLabel)
            }
            .font(.caption).foregroundStyle(.secondary)
        }
        .fixedSize()
    }

    private var filterLabel: String {
        switch session.noteTypeFilter {
        case .all: return L("All Types")
        case .only(let id):
            guard let id else { return L("General") }
            return session.noteTypes.first { $0.id == id }?.name ?? L("General")
        }
    }

    /// 删除一条文字注解：从内存移除 → ContentView 的 onChange 增量对账把对应 note 删库。
    private func deleteTextNote(_ n: TextNote) {
        session.inkEdit("Delete", kind: .delete) { session.textNotes.removeAll { $0.id == n.id } }
    }

    private var highlightBlock: some View {
        block("\(L("Highlights")) · \(session.highlights.count)") {
            if session.highlights.isEmpty {
                Text(L("No highlights yet.")).foregroundStyle(.secondary).font(.callout)
            } else {
                ForEach(session.highlights) { h in
                    HStack(alignment: .top, spacing: 6) {
                        Button {
                            onJumpTo(h.page, max(0, h.anchor.minY - 0.03))
                        } label: {
                            HStack(alignment: .top, spacing: 8) {
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(Color(nsColor: h.color.nsColor))
                                    .frame(width: 12, height: 12)
                                    .padding(.top, 2)
                                VStack(alignment: .leading, spacing: 2) {
                                    Label(String(format: L("Page %d"), h.page + 1), systemImage: h.style.iconName)
                                        .font(.callout)
                                    if !h.quote.isEmpty {
                                        Text(h.quote.flattenedQuote).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                }
                            }
                            .contentShape(Rectangle())
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)

                        Button {
                            deleteHighlight(h)   // × → 从内存移除 → ContentView onChange 对账删 note 行
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.body).foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                        .help(L("Delete this highlight"))
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 7))
                    // 右键：换色（调色板）/ 换画法 / 删除——与页面上高亮气泡里的几项对应
                    // （「添加笔记…」只在页面气泡里：编辑器挂在阅读区那一层，Inspector 没有开它的路）。
                    .contextMenu {
                        Menu(L("Highlight Color")) {
                            ForEach(Array(Highlight.palette.enumerated()), id: \.offset) { _, item in
                                Button(L(item.name)) { recolorHighlight(h, color: item.color) }
                            }
                        }
                        Menu(L("Mark")) {
                            ForEach(HighlightStyle.allCases, id: \.self) { s in
                                Button { restyleHighlight(h, style: s) } label: {
                                    if h.style == s { Label(s.title, systemImage: "checkmark") } else { Text(s.title) }
                                }
                            }
                        }
                        Button(L("Delete Highlight"), role: .destructive) { deleteHighlight(h) }
                    }
                }
            }
        }
    }

    /// 删除一条高亮：从内存移除 → ContentView 的 onChange 增量对账把对应 note 删库。
    private func deleteHighlight(_ h: Highlight) {
        session.highlights.removeAll { $0.id == h.id }
    }

    /// 给一条高亮换色：就地改 + bump updatedAt → 对账识别为变更并 upsert（与 `ReaderSurface.recolorHighlight` 同款）。
    private func recolorHighlight(_ h: Highlight, color: InkColor) {
        guard let i = session.highlights.firstIndex(where: { $0.id == h.id }),
              session.highlights[i].color != color else { return }
        session.highlights[i].color = color
        session.highlights[i].updatedAt = .now
    }

    /// 给一条高亮换画法（铺色/画线/画框）：同上落库路径（与 `ReaderSurface.restyleHighlight` 同款）。
    private func restyleHighlight(_ h: Highlight, style: HighlightStyle) {
        guard let i = session.highlights.firstIndex(where: { $0.id == h.id }),
              session.highlights[i].style != style else { return }
        session.highlights[i].style = style
        session.highlights[i].updatedAt = .now
    }

    // MARK: - 图片笔记（`IMAGE-NOTE-PLAN.md §6`）

    /// 图片笔记列表：缩略图 + 说明（没有就显示来源）+ 页码；点条目跳转，右键编辑/查看/删除。
    private var imageBlock: some View {
        block("\(L("Image Notes")) · \(session.imageNotes.count)") {
            if session.imageNotes.isEmpty {
                Text(L("No image notes yet. ⌥⇧-drag on a page to clip one, or drop an image file onto a page."))
                    .foregroundStyle(.secondary).font(.callout)
            } else {
                ForEach(session.imageNotes) { n in
                    HStack(alignment: .top, spacing: 6) {
                        Button {
                            onJumpTo(n.page, max(0, n.anchor.minY - 0.03))
                        } label: {
                            HStack(alignment: .top, spacing: 8) {
                                ImageNoteThumb(info: workspace.imageInfo(sha256: n.image), side: 48)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(n.caption.isEmpty ? n.sourceLabel : NoteMarkdown.plain(n.caption))
                                        .font(.callout).lineLimit(2)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    Text(n.caption.isEmpty
                                         ? String(format: L("Page %d"), n.page + 1)
                                         : "\(String(format: L("Page %d"), n.page + 1)) · \(n.sourceLabel)")
                                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                            .contentShape(Rectangle())
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)

                        Button { requestImageNote(.imageNoteEdit, n) } label: {
                            Image(systemName: "pencil").font(.body).foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help(L("Edit this image note"))

                        Button { deleteImageNote(n) } label: {
                            Image(systemName: "xmark.circle.fill").font(.body).foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                        .help(L("Delete this image note"))
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 7))
                    .contextMenu {
                        Button(L("Edit…")) { requestImageNote(.imageNoteEdit, n) }
                        Button(L("View Full Size")) { requestImageNote(.imageNoteView, n) }
                            .disabled(workspace.imageInfo(sha256: n.image) == nil)
                        Divider()
                        Button(L("Delete Image Note"), role: .destructive) { deleteImageNote(n) }
                    }
                }
            }
        }
    }

    /// 编辑器 / 看大图的 sheet 都挂在阅读区（`ReaderSurface+ImageNote.imageRoutes`），这边发通知请它弹。
    private func requestImageNote(_ name: Notification.Name, _ n: ImageNote) {
        NotificationCenter.default.post(name: name, object: ImageNoteRequest(sessionID: session.id, noteID: n.id))
    }

    /// 删一条图片笔记：从内存移除 → `DocTabModel` 对账删库并对账那张图的待删除状态。
    /// 走 `inkEdit` 记撤销（⌘Z 加回来 = 引用回来 = 图脱离待删除）。
    private func deleteImageNote(_ n: ImageNote) {
        session.inkEdit("Delete Image Note", kind: .delete) {
            session.imageNotes.removeAll { $0.id == n.id }
        }
    }

    // MARK: - 书签（`REQUIREMENTS.md §1.9`）

    /// 书签的**管理**页：目录页那棵树管「看和跳」，这里管「加、改名、删」。
    /// 列表是平铺的、按页序（`Bookmark.before`），不做分组——管理时要的是一眼看全，不是层级。
    private var bookmarkBlock: some View {
        block("\(L("Bookmarks")) · \(session.bookmarks.count)") {
            Button { session.beginBookmarkAtCurrent() } label: {
                Label(L("Add Bookmark"), systemImage: "bookmark")
                    .font(.callout)
                    .foregroundStyle(.primary)   // 红线：别用 .secondary，系统会画得几乎看不见
            }
            .buttonStyle(.plain)

            if session.bookmarks.isEmpty {
                Text(L("No bookmarks yet.")).foregroundStyle(.secondary).font(.callout)
            } else {
                ForEach(session.bookmarks) { b in
                    HStack(alignment: .top, spacing: 6) {
                        Button {
                            session.jump(page: b.page, frac: b.frac, kind: .toc, label: b.title)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Label(b.title, systemImage: "bookmark.fill")
                                    .font(.callout).lineLimit(1)
                                Text(String(format: L("Page %d"), b.page + 1))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            .contentShape(Rectangle())
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)

                        Button { session.beginBookmarkRename(b) } label: {
                            Image(systemName: "pencil").font(.body).foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help(L("Rename this bookmark"))

                        Button { session.deleteBookmark(id: b.id) } label: {
                            Image(systemName: "xmark.circle.fill").font(.body).foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                        .help(L("Delete this bookmark"))
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 7))
                }
            }
        }
    }

    /// 🔴 `lineLimit(1) + fixedSize()` 一个都不能少：面板窄下来时这行文字会换行，胶囊跟着变高、
    /// 把整条文件行撑起来（2026-09-01 用户报「Files 的标签挤得很高」，与参考窗顶栏那笔账同源）。
    /// `fixedSize` 让它拒绝被压缩，于是挤压落到**文件名**上——那一条本来就带 `lineLimit(1)`，
    /// 截断即可，正是该缩的那个。
    private func badge(_ text: String, _ color: Color) -> some View {
        Text(text).font(.caption2)
            .lineLimit(1).fixedSize()
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(color.opacity(0.2), in: Capsule())
            .foregroundStyle(color)
    }

    private func reload() {
        guard let id = documentId else { variants = []; locations = []; return }
        variants = workspace.variants(documentId: id)
        locations = workspace.locations(documentId: id)
    }
}
