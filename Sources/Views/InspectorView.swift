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

    @State private var variants: [LibVariant] = []
    @State private var locations: [LibLocation] = []
    @State private var textNotes: [LibNote] = []

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
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(URL(fileURLWithPath: l.path).lastPathComponent).font(.callout).lineLimit(1)
                        if l.inWorkspace { badge(L("In Workspace"), .green) }
                        if !l.isValid { badge(L("Missing"), .orange) }
                        Spacer()
                        Text(String((hashByVar[l.variantId] ?? "").prefix(8)))
                            .font(.system(.caption2, design: .monospaced)).foregroundStyle(.secondary)
                    }
                    Text(workspace.resolvedPath(l))
                        .font(.caption2).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 7))
            }
        }
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
                        Label(String(format: L("Page %d"), page + 1), systemImage: "pencil.tip").font(.callout)
                        Spacer()
                        ForEach(Array(strokes.prefix(6).enumerated()), id: \.offset) { _, s in
                            Circle().fill(Color(nsColor: s.color.nsColor)).frame(width: 10, height: 10)
                        }
                        Text("\(strokes.count)").foregroundStyle(.secondary).font(.caption)
                    }
                }
            }
        }
    }

    private var textBlock: some View {
        block("\(L("Text Notes")) · \(textNotes.count)") {
            if textNotes.isEmpty {
                Text(L("No text notes yet.")).foregroundStyle(.secondary).font(.callout)
            } else {
                ForEach(textNotes) { n in
                    Label(String(format: L("Page %d"), n.page + 1), systemImage: "text.quote").font(.callout)
                }
            }
        }
    }

    private var highlightBlock: some View {
        block(L("Highlights")) {
            Text(L("Highlights aren’t supported yet.")).foregroundStyle(.secondary).font(.callout)
        }
    }

    private func badge(_ text: String, _ color: Color) -> some View {
        Text(text).font(.caption2)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(color.opacity(0.2), in: Capsule())
            .foregroundStyle(color)
    }

    private func reload() {
        guard let id = documentId else { variants = []; locations = []; textNotes = []; return }
        variants = workspace.variants(documentId: id)
        locations = workspace.locations(documentId: id)
        textNotes = workspace.notes(documentId: id).filter { $0.kind == 0 }
    }
}
