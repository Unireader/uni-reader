import SwiftUI
import SwiftData
import PDFKit
import AppKit
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.openWindow) private var openWindow
    @EnvironmentObject private var app: AppModel
    @Query(sort: \Document.lastOpenedAt, order: .reverse) private var documents: [Document]
    @Query(sort: \LibraryGroup.order) private var groups: [LibraryGroup]

    @StateObject private var session = DocSession()
    @State private var selectedDocument: Document?
    @State private var isHashing = false
    @State private var showServer = false
    @State private var isKeyWindow = false
    @State private var showNotes = false

    var body: some View {
        NavigationSplitView {
            SidebarView(documents: documents, groups: groups, selection: $selectedDocument)
                .navigationSplitViewColumnWidth(min: 200, ideal: 260)
        } detail: {
            // PDF 显示实现已按要求全部移除，待重建。
            // 文档加载（session.pdf）保留：模拟平板窗口 / 真平板仍可正常渲染。
            readerColumn
                .background(WindowAccessor { key in
                    isKeyWindow = key
                    if key { app.setActive(session) }
                })
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            openPDF()
                        } label: {
                            Label(L("Open PDF…"), systemImage: "plus")
                        }
                    }
                    ToolbarItem(placement: .automatic) {
                        Button {
                            openWindow(id: "simPad")
                        } label: {
                            Label(L("Simulated Tablet"), systemImage: "ipad")
                        }
                    }
                    ToolbarItem(placement: .automatic) {
                        Button {
                            showServer.toggle()
                        } label: {
                            Label(L("Tablet"), systemImage: "wifi")
                        }
                        .popover(isPresented: $showServer, arrowEdge: .bottom) {
                            ServerPanel(server: app.server)
                        }
                    }
                    ToolbarItem(placement: .automatic) {
                        Button {
                            showNotes.toggle()
                        } label: {
                            Label(L("Notes"), systemImage: "sidebar.trailing")
                        }
                    }
                }
        }
        .inspector(isPresented: $showNotes) {
            notesPlaceholder
                .inspectorColumnWidth(min: 220, ideal: 280, max: 360)
        }
        .onChange(of: selectedDocument) { _, doc in loadSelected(doc) }
        .onChange(of: session.currentPageIndex) { _, _ in app.sessionChanged(session) }
        .onChange(of: session.scrollAnchor) { _, _ in app.macScrolled(session) }
        .onAppear { app.register(session) }
        .onDisappear { app.unregister(session) }
        .onReceive(NotificationCenter.default.publisher(for: .openPDFRequested)) { _ in
            if isKeyWindow { openPDF() }
        }
    }

    @ViewBuilder
    private var readerColumn: some View {
        if session.pdf != nil {
            PDFKitView(
                session: session,
                scrollAnchor: session.scrollAnchor,
                inkTick: session.strokes.count &+ (session.liveStroke?.points.count ?? 0)
            )
            .overlay(alignment: .top) { if isHashing { indexingBadge } }
        } else {
            ContentUnavailableView(
                L("No Document"),
                systemImage: "doc.richtext",
                description: Text(L("Open a PDF to start reading."))
            )
            .overlay(alignment: .top) { if isHashing { indexingBadge } }
        }
    }

    private var notesPlaceholder: some View {
        // 预留：笔记/批注面板（M3 里程碑落地）。
        ContentUnavailableView(
            L("Notes"),
            systemImage: "note.text",
            description: Text(L("Notes will appear here."))
        )
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
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        ingest(url: url)
    }

    private func ingest(url: URL) {
        isHashing = true
        Task {
            let hash = await Task.detached(priority: .userInitiated) {
                (try? FileHasher.sha256(of: url)) ?? ""
            }.value
            let pageCount = PDFDocument(url: url)?.pageCount ?? 0
            register(hash: hash,
                     path: url.path,
                     title: url.deletingPathExtension().lastPathComponent,
                     pageCount: pageCount)
            isHashing = false
        }
    }

    /// 按 hash 去重入库：已存在则追加新路径，否则新建。
    private func register(hash: String, path: String, title: String, pageCount: Int) {
        guard !hash.isEmpty else { return }
        let descriptor = FetchDescriptor<Document>(
            predicate: #Predicate { $0.contentHash == hash }
        )
        let doc: Document
        if let existing = (try? context.fetch(descriptor))?.first {
            doc = existing
            doc.lastOpenedAt = .now
            if !doc.locations.contains(where: { $0.path == path }) {
                let loc = DocumentLocation(path: path)
                loc.document = doc
                context.insert(loc)
            }
        } else {
            doc = Document(contentHash: hash, title: title, pageCount: pageCount)
            context.insert(doc)
            let loc = DocumentLocation(path: path)
            loc.document = doc
            context.insert(loc)
        }
        try? context.save()
        selectedDocument = doc
    }

    // MARK: - 选中加载

    private func loadSelected(_ doc: Document?) {
        guard let doc else { session.pdf = nil; return }
        for loc in doc.locations where FileManager.default.fileExists(atPath: loc.path) {
            if let pdf = PDFDocument(url: URL(fileURLWithPath: loc.path)) {
                session.pdf = pdf
                session.currentPageIndex = 0
                session.title = doc.title
                session.contentHash = doc.contentHash
                doc.lastOpenedAt = .now
                try? context.save()
                app.setActive(session)
                app.sessionChanged(session)
                return
            }
        }
        session.pdf = nil   // 所有路径失效 → 后续里程碑：提示重定位
    }
}
