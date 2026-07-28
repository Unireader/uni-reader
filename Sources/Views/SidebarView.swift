import SwiftUI

/// 侧栏：当前工作区的文档列表（工作区即分组）+ 工作区切换/重命名。原生单列表，保持 sidebar 样式。
/// 目录（TOC）不放这里——固定模式放右侧 Inspector 的「目录」分段页，避免破坏侧栏原生外观。
struct SidebarView: View {
    @EnvironmentObject private var workspace: WorkspaceManager
    @Binding var selection: String?
    var onChooseWorkspace: () -> Void
    var onDropFiles: ([URL]) -> Void
    var onOpenPDF: () -> Void
    var onOpenInNewWindow: (String) -> Void

    @State private var renameShown = false
    @State private var nameField = ""
    @State private var mergePending: MergePair?

    private struct MergePair: Identifiable {
        let id = UUID()
        let source: LibDocument, target: LibDocument
    }

    var body: some View {
        List(selection: $selection) {
            Section(workspace.name.isEmpty ? L("Library") : workspace.name) {
                ForEach(workspace.documents) { doc in row(doc) }
            }
        }
        .dropDestination(for: URL.self) { urls, _ in onDropFiles(urls); return true }
        .navigationTitle(L("Library"))
        .toolbar {
            ToolbarItemGroup {
                Button(action: onOpenPDF) {
                    Label(L("Open PDF…"), systemImage: "plus")
                }
                Menu {
                    Button(action: onChooseWorkspace) {
                        Label(L("Open Workspace…"), systemImage: "folder.badge.plus")
                    }
                    Button { nameField = workspace.name; renameShown = true } label: {
                        Label(L("Rename Workspace…"), systemImage: "pencil")
                    }
                    if !workspace.recents.isEmpty {
                        Divider()
                        Section(L("Recent Workspaces")) {
                            ForEach(workspace.recents, id: \.self) { url in
                                Button(url.deletingPathExtension().lastPathComponent) { try? workspace.open(folder: url) }
                            }
                            Divider()
                            Menu(L("Remove from Recents")) {
                                ForEach(workspace.recents, id: \.self) { url in
                                    Button(url.deletingPathExtension().lastPathComponent) { workspace.removeRecent(url) }
                                }
                            }
                        }
                    }
                } label: {
                    Label(workspace.name.isEmpty ? L("Workspace") : workspace.name, systemImage: "folder")
                }
            }
        }
        .alert(L("Rename Workspace"), isPresented: $renameShown) {
            TextField(L("Name"), text: $nameField)
            Button(L("OK")) { workspace.rename(nameField) }
            Button(L("Cancel"), role: .cancel) {}
        }
        .confirmationDialog(
            L("Link as Same Document"),
            isPresented: Binding(get: { mergePending != nil }, set: { if !$0 { mergePending = nil } }),
            presenting: mergePending
        ) { pair in
            Button(String(format: L("Merge into “%@”"), pair.target.title), role: .destructive) {
                workspace.mergeDocuments(sourceId: pair.source.id, intoTargetId: pair.target.id)
                if selection == pair.source.id { selection = pair.target.id }
            }
            Button(L("Cancel"), role: .cancel) {}
        } message: { pair in
            Text(String(format: L("“%@” becomes another version of “%@”; their notes merge and it leaves the list."),
                        pair.source.title, pair.target.title))
        }
    }

    private func row(_ doc: LibDocument) -> some View {
        Label(doc.title, systemImage: "doc.richtext")
            .tag(doc.id)
            .contextMenu { menu(for: doc) }
    }

    @ViewBuilder
    private func menu(for doc: LibDocument) -> some View {
        Button { onOpenInNewWindow(doc.id) } label: {
            Label(L("Open in New Window"), systemImage: "macwindow.badge.plus")
        }
        if workspace.currentFilePath(documentId: doc.id) != nil {
            Button { workspace.revealInFinder(documentId: doc.id) } label: {
                Label(L("Show in Finder"), systemImage: "folder")
            }
        }
        Divider()
        if workspace.isInWorkspace(doc.id) {
            Button { workspace.removeFromWorkspace(documentId: doc.id) } label: {
                Label(L("Remove from Workspace"), systemImage: "folder.badge.minus")
            }
        } else {
            Button { workspace.copyToWorkspace(documentId: doc.id) } label: {
                Label(L("Copy into Workspace"), systemImage: "folder.badge.plus")
            }
        }

        let others = workspace.documents.filter { $0.id != doc.id }
        if !others.isEmpty {
            Menu {
                ForEach(others) { target in
                    Button(target.title) { mergePending = MergePair(source: doc, target: target) }
                }
            } label: {
                Label(L("Link as Same Document"), systemImage: "link")
            }
        }

        Divider()
        Button(role: .destructive) { workspace.delete(documentId: doc.id) } label: {
            Label(L("Delete"), systemImage: "trash")
        }
    }
}
