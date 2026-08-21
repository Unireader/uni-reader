import SwiftUI

/// 侧栏：当前工作区的文档列表 + 工作区切换/重命名。原生单列表，保持 sidebar 样式。
/// 文档可设一级分组（v11）：有分组时按分组分段（未分组在前），右键「Move to Group」移动，
/// 分组段头右键改名/删除（删除 = 文档回未分组）；文档行可**拖到段头**换分组（多选时整批移动）。
/// **多选**（⌘/⇧ 点）：`multiSel` 是 List 的选中集，仅当恰选一篇时同步给 `selection`（= 打开文档）；
/// 右键菜单按 macOS 惯例作用于「被点者在选中集内 → 整个选中集，否则仅被点者」。
/// 目录（TOC）不放这里——固定模式放右侧 Inspector 的「目录」分段页，避免破坏侧栏原生外观。
struct SidebarView: View {
    @EnvironmentObject private var workspace: WorkspaceManager
    /// 「最近工作区」是本机全局状态（不属于任何一个工作区），故来自 registry 而非 workspace。
    @ObservedObject private var registry = WorkspaceRegistry.shared
    @Binding var selection: String?
    @State private var multiSel: Set<String> = []
    var onChooseWorkspace: () -> Void
    var onCreateWorkspace: () -> Void
    var onOpenRecent: (URL) -> Void
    var onDropFiles: ([URL]) -> Void
    var onOpenPDF: () -> Void
    var onOpenInNewWindow: (String) -> Void

    @State private var renameShown = false
    @State private var nameField = ""
    @State private var mergePending: MergePair?
    // 分组（v11 一级分组）：新建/改名共用一个带输入框的 alert
    @State private var groupAction: GroupAction?
    @State private var groupNameField = ""

    private struct MergePair: Identifiable {
        let id = UUID()
        let source: LibDocument, target: LibDocument
    }

    private enum GroupAction: Identifiable {
        case new([String])    // documentIds：把这些文档移入新分组（多选批量）
        case rename(String)   // 旧分组名
        var id: String {
            switch self {
            case .new(let d): return "new-\(d.joined(separator: ","))"
            case .rename(let g): return "rename-\(g)"
            }
        }
    }

    private var groupAlertTitle: String {
        switch groupAction {
        case .new: return L("New Group")
        case .rename(let old): return String(format: L("Rename Group “%@”"), old)
        case nil: return ""
        }
    }

    private func commitGroup(_ action: GroupAction) {
        let name = groupNameField.trimmingCharacters(in: .whitespacesAndNewlines)
        switch action {
        case .new(let docIds):
            guard !name.isEmpty else { return }
            workspace.setGroup(ids: docIds, group: name)
        case .rename(let old):
            guard !name.isEmpty, name != old else { return }
            workspace.renameGroup(from: old, to: name)
        }
    }

    /// 右键/拖拽的作用对象：被操作者在选中集内 → 整个选中集；否则仅它自己（macOS 惯例）。
    private func targets(forId id: String) -> Set<String> {
        multiSel.contains(id) ? multiSel : [id]
    }

    var body: some View {
        List(selection: $multiSel) {
            if workspace.groups.isEmpty {
                Section(workspace.name.isEmpty ? L("Library") : workspace.name) {
                    ForEach(workspace.documents) { doc in row(doc) }
                }
            } else {
                let ungrouped = workspace.documents.filter { $0.group.isEmpty }
                if !ungrouped.isEmpty {
                    Section {
                        ForEach(ungrouped) { doc in row(doc) }
                    } header: {
                        groupHeader(L("Ungrouped"), group: "")
                    }
                }
                ForEach(workspace.groups, id: \.self) { g in
                    Section {
                        ForEach(workspace.documents.filter { $0.group == g }) { doc in row(doc) }
                    } header: {
                        groupHeader(g, group: g)
                    }
                }
            }
        }
        .onChange(of: multiSel) { _, s in
            // 多选 → 打开文档：仅恰选一篇时联动（多选期间不动当前打开的文档）
            if s.count == 1, let id = s.first, id != selection { selection = id }
        }
        .onChange(of: selection) { _, id in
            // 外部改打开文档（恢复会话/新窗口打开/删除回落）→ 选中集跟随
            let s: Set<String> = id.map { [$0] } ?? []
            if s != multiSel { multiSel = s }
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
                        Label(L("Open Workspace…"), systemImage: "folder")
                    }
                    Button(action: onCreateWorkspace) {
                        Label(L("New Workspace…"), systemImage: "folder.badge.plus")
                    }
                    Button { nameField = workspace.name; renameShown = true } label: {
                        Label(L("Rename Workspace…"), systemImage: "pencil")
                    }
                    if !registry.recents.isEmpty {
                        Divider()
                        // 侧栏只留「快速切过去」。移除/清空统一在「文件 → 最近打开 → 清空最近打开」
                        // （见 `OpenRecentMenu`）：这里原先还挂着一个「从最近列表移除」的三级嵌套
                        // 子菜单，既不是 macOS 的排法，也与菜单栏两处维护同一件事。
                        Section(L("Recent Workspaces")) {
                            ForEach(registry.recents, id: \.self) { url in
                                // 名字口径与菜单栏/Dock 菜单统一（原先的 deletingPathExtension
                                // 会把含点的文件夹名截断：「v1.2 notes」→「v1」）
                                Button(WorkspaceManager.defaultWorkspaceName(for: url)) { onOpenRecent(url) }
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
        .alert(Text(groupAlertTitle),
               isPresented: Binding(get: { groupAction != nil }, set: { if !$0 { groupAction = nil } }),
               presenting: groupAction) { action in
            TextField(L("Group Name"), text: $groupNameField)
            Button(L("OK")) { commitGroup(action) }
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
        .alert(L("Workspace Not Found"),
               isPresented: Binding(get: { registry.missingRecentName != nil },
                                    set: { if !$0 { registry.missingRecentName = nil } }),
               presenting: registry.missingRecentName
        ) { _ in
            Button(L("OK")) {}
        } message: { name in
            Text(String(format: L("“%@” could not be found. It has been removed from your recent workspaces."), name))
        }
    }

    private func row(_ doc: LibDocument) -> some View {
        Label(doc.title, systemImage: "doc.richtext")
            .tag(doc.id)
            .draggable(doc.id)   // 拖到分组段头换分组（多选时整批，见 moveDropped）
            .contextMenu { menu(for: doc) }
    }

    /// 分组段头：右键菜单 + 接受文档拖放（整行宽都是落点，不只是文字那一小段）。
    private func groupHeader(_ title: String, group: String) -> some View {
        Text(title)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .contextMenu { if !group.isEmpty { groupMenu(group) } }
            .dropDestination(for: String.self) { ids, _ in moveDropped(ids, to: group); return true }
    }

    /// 拖文档行到段头：被拖者在选中集内 → 整批移动；否则只动被拖那篇（Finder 同款语义）。
    private func moveDropped(_ ids: [String], to group: String) {
        workspace.setGroup(ids: Set(ids.flatMap { targets(forId: $0) }), group: group)
    }

    @ViewBuilder
    private func menu(for doc: LibDocument) -> some View {
        let targets = targets(forId: doc.id)   // 多选时 = 整个选中集
        if targets.count == 1 {
            Button { onOpenInNewWindow(doc.id) } label: {
                Label(L("Open in New Window"), systemImage: "macwindow.badge.plus")
            }
        }
        Menu {
            if targets.contains(where: { workspace.document(id: $0)?.group.isEmpty == false }) {
                Button { workspace.setGroup(ids: targets, group: "") } label: {
                    Label(L("No Group"), systemImage: "circle.dashed")
                }
            }
            ForEach(workspace.groups, id: \.self) { g in
                Button(g) { workspace.setGroup(ids: targets, group: g) }
            }
            Divider()
            Button { groupNameField = ""; groupAction = .new(Array(targets)) } label: {
                Label(L("New Group…"), systemImage: "plus")
            }
        } label: {
            Label(L("Move to Group"), systemImage: "folder")
        }
        if targets.count == 1 {
            if workspace.currentFilePath(documentId: doc.id) != nil {
                Button { workspace.revealInFinder(documentId: doc.id) } label: {
                    Label(L("Show in Finder"), systemImage: "folder")
                }
            }
            Button { workspace.revealWorkspaceInFinder() } label: {
                Label(L("Show Workspace in Finder"), systemImage: "folder.badge.gearshape")
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
        }

        Divider()
        Button(role: .destructive) {
            for id in targets { workspace.delete(documentId: id) }
            multiSel.subtract(targets)
        } label: {
            Label(L("Delete"), systemImage: "trash")
        }
    }

    /// 分组段头右键：改名 / 删除（删除只是把文档退回未分组，不动文档本身）。
    @ViewBuilder
    private func groupMenu(_ g: String) -> some View {
        Button { groupNameField = g; groupAction = .rename(g) } label: {
            Label(L("Rename Group…"), systemImage: "pencil")
        }
        Button(role: .destructive) { workspace.renameGroup(from: g, to: "") } label: {
            Label(L("Delete Group"), systemImage: "trash")
        }
    }
}
