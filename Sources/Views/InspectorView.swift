import SwiftUI

enum InspectorTab: Hashable { case info, contents, notes }

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

    private let tabs: [(tab: InspectorTab, icon: String)] = [
        (.info, "info.circle"),
        (.contents, "list.bullet.indent"),
        (.notes, "note.text"),
    ]

    var body: some View {
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
            TOCListView(entries: toc, onSelect: onSelectTOC)
        } else if let id = documentId, let doc = workspace.document(id: id) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if tab == .info {
                        infoBlock(doc)
                        filesBlock
                    } else {
                        inkBlock
                        textBlock
                        highlightBlock
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            ContentUnavailableView(L("No Document"), systemImage: "sidebar.right",
                                   description: Text(L("Select a document to see its info and notes.")))
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

    private var inkBlock: some View {
        let byPage = Dictionary(grouping: session.strokes, by: { $0.page })
        return block("\(L("Ink")) · \(session.strokes.count)") {
            if session.strokes.isEmpty {
                Text(L("No ink yet.")).foregroundStyle(.secondary).font(.callout)
            } else {
                ForEach(byPage.keys.sorted(), id: \.self) { page in
                    let strokes = byPage[page] ?? []
                    HStack(spacing: 6) {
                        Button {
                            onJumpTo(page, inkTopFrac(strokes))   // 点击 → 跳到该页笔迹处
                        } label: {
                            HStack(spacing: 6) {
                                Label(String(format: L("Page %d"), page + 1), systemImage: "pencil.tip").font(.callout)
                                Spacer()
                                ForEach(Array(strokes.prefix(6).enumerated()), id: \.offset) { _, s in
                                    Circle().fill(Color(nsColor: s.color.nsColor)).frame(width: 10, height: 10)
                                }
                                Text("\(strokes.count)").foregroundStyle(.secondary).font(.caption)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        Button {
                            deleteInk(page: page)                 // × → 删该页全部笔迹（内存移除→onChange 落库删行）
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

    /// 该页笔迹最靠上的归一化 y（0 顶 1 底），略上移一点作跳转目标。
    private func inkTopFrac(_ strokes: [InkStroke]) -> Double {
        let ys = strokes.flatMap { $0.points.map(\.y) }
        return max(0, (ys.min() ?? 0) - 0.05)
    }

    /// 删除某页全部手写笔迹：从内存移除 → ContentView 的 onChange 增量对账把对应 note 删库。
    private func deleteInk(page: Int) {
        session.strokes.removeAll { $0.page == page }
    }

    private var textBlock: some View {
        block("\(L("Text Notes")) · \(session.textNotes.count)") {
            if session.textNotes.isEmpty {
                Text(L("No text notes yet.")).foregroundStyle(.secondary).font(.callout)
            } else {
                ForEach(session.textNotes) { n in
                    HStack(alignment: .top, spacing: 6) {
                        Button {
                            onJumpTo(n.page, max(0, n.anchor.minY - 0.03))   // 跳到该批注所在页/位置
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Label(String(format: L("Page %d"), n.page + 1), systemImage: "text.quote")
                                    .font(.callout)
                                if !n.text.isEmpty {
                                    Text(n.text).font(.callout).lineLimit(2)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                if !n.quote.isEmpty {
                                    Text(n.quote).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

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

    /// 删除一条文字注解：从内存移除 → ContentView 的 onChange 增量对账把对应 note 删库。
    private func deleteTextNote(_ n: TextNote) {
        session.textNotes.removeAll { $0.id == n.id }
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
                                    Label(String(format: L("Page %d"), h.page + 1), systemImage: "highlighter")
                                        .font(.callout)
                                    if !h.quote.isEmpty {
                                        Text(h.quote).font(.caption).foregroundStyle(.secondary).lineLimit(2)
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
                }
            }
        }
    }

    /// 删除一条高亮：从内存移除 → ContentView 的 onChange 增量对账把对应 note 删库。
    private func deleteHighlight(_ h: Highlight) {
        session.highlights.removeAll { $0.id == h.id }
    }

    private func badge(_ text: String, _ color: Color) -> some View {
        Text(text).font(.caption2)
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
