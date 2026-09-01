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
    @State private var makeMirrorShown = false
    @State private var dropMirrorShown = false
    @State private var syncTarget: SyncTarget?
    @State private var notice: Notice?
    /// 一次只跑一遍：干跑要快照整库、逐行算指纹，重入等于白烧一遍 CPU 和 USB 带宽
    @State private var noticeBusy = false

    /// 同步面板要开成哪一侧；`switchTo` 非 nil = 同步成功后切到那个工作区（「同步并切回」）。
    private struct SyncTarget: Identifiable {
        let id = UUID()
        let side: MirrorSyncSheet.Side
        let switchTo: URL?
    }
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

    // MARK: - 离线副本的「自动收口」提示

    /// 侧栏顶部那一条。**只提示、不打断**（用户 2026-09-01 拍板）：正在写笔迹时被强行换库、
    /// 换窗口是最糟的体验，而且中途切换还要处理没落盘的那一笔。
    private enum Notice {
        case sourceBack(URL, Int)   // 我是副本，源盘插回来了，且确实有 N 项要同步
        case unsynced(URL, Int)     // 我是源盘，副本里有 N 项要**推回源盘**，等人工确认
    }

    @ViewBuilder
    private func noticeRow(_ n: Notice) -> some View {
        switch n {
        case .sourceBack(let src, let count):
            Button {
                // 同步完切回源盘那扇窗 —— 按钮上就是这么写的
                syncTarget = SyncTarget(side: .fromMirror, switchTo: src)
            } label: {
                Label {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(L("Source drive is connected"))
                        Text(String(format: L("%d items to sync · tap to review"), count))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "eject")
                }
            }
        case .unsynced(let mirror, let count):
            Button {
                syncTarget = SyncTarget(side: .fromSource(mirror: mirror), switchTo: nil)
            } label: {
                Label {
                    VStack(alignment: .leading, spacing: 1) {
                        // 只数**要推回源盘**的那些：反方向的已经自动过去了，不该算进来吓人
                        Text(String(format: L("%d items written offline"), count))
                        Text(L("Review and sync them back")).font(.caption).foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "externaldrive.badge.timemachine")
                }
            }
        }
    }

    /// 顺一遍副本这件事，**并在源盘侧顺手把该推的推过去**。全在后台跑，
    /// **算不出来就什么都不显示**——宁可不提示，也不要挂一条不确定的横幅。
    ///
    /// 用户 2026-09-01 定的完整流程（这段代码就是它的落点）：
    ///   拔盘 → 用副本、改副本 → 插回来 → **副本→源盘合一次（要确认）** → 从此两边一致
    ///   → 之后在源盘上改 → 每次都是「纯粹推给副本、零冲突」→ **静默推过去** → 再拔盘 → 又是副本。
    /// 所以源盘侧只有一种情况会弹提示：**第 2 步还没做**（副本上有东西没合回来）——
    /// 而那时候恰好也正是不该静默动手的时候，两者是同一件事的两面。
    private func refreshNotice() {
        guard !noticeBusy, let folder = workspace.folder else { return }
        if workspace.isMirror {
            guard let id = workspace.mirrorSourceId else { notice = nil; return }
            noticeBusy = true
            let recents = registry.recents.map { URL(fileURLWithPath: $0.sourcePath) }
            DispatchQueue.global(qos: .utility).async {
                // 盘插上了但两边本来就一致 → 不出提示。否则就是在没事找事
                let src = WorkspaceManager.findMirrorSource(id: id, recents: recents)
                let n = src.flatMap { try? workspace.mirrorDryRun(sourceFolder: $0) }?.plan.changes.count ?? 0
                DispatchQueue.main.async {
                    noticeBusy = false
                    notice = (src != nil && n > 0) ? .sourceBack(src!, n) : nil
                }
            }
        } else if let p = registry.mirrorPath(forSource: folder, id: workspace.workspaceId) {
            noticeBusy = true
            let mirror = URL(fileURLWithPath: p)
            DispatchQueue.global(qos: .utility).async {
                // 该静默推的推掉，返回还剩多少要人工确认（副本→源盘那个方向）
                let pending = workspace.autoPushToMirror(mirrorFolder: mirror) ?? 0
                DispatchQueue.main.async {
                    noticeBusy = false
                    notice = pending > 0 ? .unsynced(mirror, pending) : nil
                }
            }
        } else {
            notice = nil
        }
    }

    // MARK: - 离线副本（开关的三段：现在有没有 / 上次同步 / 删掉）

    /// 这个工作区当下**确实**有一份可用的离线副本（记录挂着、文件也还在）。
    private var keptOffline: Bool {
        guard let folder = workspace.folder else { return false }
        return registry.mirrorPath(forSource: folder, id: workspace.workspaceId) != nil
    }

    /// 借出记录就在源库自己的 meta 里，读它不额外开连接。
    private var lastSyncedLine: String {
        guard let at = workspace.checkouts.first?.lastSyncedAt, let d = ISO.date(at) else {
            return L("Never synced back")
        }
        return String(format: L("Last synced %@"), d.formatted(date: .abbreviated, time: .shortened))
    }

    private func dropMirror() {
        guard let folder = workspace.folder,
              let p = registry.mirrorPath(forSource: folder, id: workspace.workspaceId) else { return }
        let url = URL(fileURLWithPath: p)
        workspace.forgetMirror(at: url)                                   // 动 store，必须在主线程
        registry.setMirror(nil, forSource: folder, id: workspace.workspaceId)
        notice = nil
        // 几 GB 的 removeItem 放主线程会整个卡住。记录已经摘干净了，界面立刻就对；
        // 万一删到一半退出，剩下的目录不再被任何记录引用，下次建副本会另起一个名字。
        DispatchQueue.global(qos: .utility).async { try? FileManager.default.removeItem(at: url) }
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
        sheetsAndAlerts(mainList)
    }

    /// 列表 + 工具栏。面板/弹窗与提示条的重算时机挂在 `sheetsAndAlerts` ——
    /// **全挂一个表达式上会让类型检查器超时**（2026-09-01 给提示条加了几个 `onChange` 后当场触发，
    /// 同 `ContentView` 拆 `mainSplit` / `eventRoutes` 的理由）。
    private var mainList: some View {
        List(selection: $multiSel) {
            if let notice { noticeRow(notice) }
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
                    Divider()
                    // 镜像与源盘互斥：镜像不能再做镜像（`MirrorBuilder` 也会拦），
                    // 源盘也没有"同步回去"这回事 —— 两个入口只出现一个，不给用户做无效选择的机会。
                    if workspace.isMirror {
                        Button {
                            syncTarget = SyncTarget(side: .fromMirror, switchTo: nil)
                        } label: {
                            Label(L("Sync to Source…"), systemImage: "arrow.triangle.2.circlepath")
                        }
                    } else {
                        // 「保留离线副本」是**状态**不是动作：勾上 = 这个工作区我要能离线用，
                        // 之后由打开链路在源盘不在时自动选用它；取消 = 连副本一起删掉。
                        // 做成一次性的「制作镜像…」就退回「你自己拷了一份」，用户还得自己管它。
                        Toggle(isOn: Binding(
                            get: { keptOffline },
                            set: { on in if on { makeMirrorShown = true } else { dropMirrorShown = true } }
                        )) {
                            Label(L("Keep Offline Copy"), systemImage: "externaldrive.badge.timemachine")
                        }
                        if keptOffline {
                            Text(lastSyncedLine)
                        }
                    }
                    if !registry.recents.isEmpty {
                        Divider()
                        // 侧栏只留「快速切过去」。移除/清空统一在「文件 → 最近打开 → 清空最近打开」
                        // （见 `OpenRecentMenu`）：这里原先还挂着一个「从最近列表移除」的三级嵌套
                        // 子菜单，既不是 macOS 的排法，也与菜单栏两处维护同一件事。
                        Section(L("Recent Workspaces")) {
                            ForEach(registry.recents) { r in
                                // 点的是「工作区」，开哪一份副本由 registry 当场定（源盘不在就开本机那份）
                                Button {
                                    onOpenRecent(WorkspaceRegistry.resolveOrSource(r))
                                } label: {
                                    // 换图标就够了，不加字：一眼看出「点它现在是离线读」
                                    Label(r.name, systemImage: WorkspaceRegistry.opensOffline(r)
                                          ? "externaldrive.badge.timemachine" : "folder")
                                }
                            }
                        }
                    }
                } label: {
                    // 镜像换一个图标就够了：用户要的是"一眼认出这不是硬盘上那份"，
                    // 不是一段说明。真要看来历，菜单里「同步到源盘…」那条会讲。
                    Label(workspace.name.isEmpty ? L("Workspace") : workspace.name,
                          systemImage: workspace.isMirror ? "externaldrive.badge.timemachine" : "folder")
                }
            }
        }
    }

    /// 侧栏挂着的全部面板/弹窗，外加离线副本提示条的重算时机（见 `mainList` 的注释）。
    private func sheetsAndAlerts<V: View>(_ base: V) -> some View {
        base
        .sheet(isPresented: $makeMirrorShown, onDismiss: refreshNotice) { MakeMirrorSheet() }
        .sheet(item: $syncTarget, onDismiss: refreshNotice) { t in
            MirrorSyncSheet(side: t.side, onSynced: t.switchTo.map { src in { _ in onOpenRecent(src) } })
        }
        .onAppear(perform: refreshNotice)
        .onChange(of: workspace.folder) { _, _ in refreshNotice() }
        // 加书/删书当场就推过去；不然「静默同步」得等下次开窗口才发生，用户拔了盘才发现没跟上
        .onChange(of: workspace.documents.count) { _, _ in refreshNotice() }
        // 切走的时候再顺一遍：笔迹这类改动不会动 documents.count，
        // 而「切走」正是个天然的收尾时机（也是用户接下来最可能去拔盘的时刻）
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.willResignActiveNotification)) { _ in refreshNotice() }
        // 删的是 GB 级数据、还可能带着没同步回来的笔迹 —— 必须确认一次，且把后果说清楚
        .confirmationDialog(L("Delete the offline copy?"), isPresented: $dropMirrorShown) {
            Button(L("Delete"), role: .destructive) { dropMirror() }
            Button(L("Cancel"), role: .cancel) {}
        } message: {
            Text(L("Anything written offline that hasn’t been synced back goes with it. To keep those, open the offline copy first and sync to the source."))
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
        // 镜像里没带 PDF 的书：元数据与笔记都在，只是打不开正文 —— 灰一档 + 换个图标，
        // **不隐藏**（隐藏了用户会以为笔记也没了）。
        let local = workspace.hasLocalFile(doc.id)
        return Label(doc.title, systemImage: local ? "doc.richtext" : "doc.badge.ellipsis")
            .foregroundStyle(local ? .primary : .secondary)
            .help(local ? "" : L("Not available offline — reconnect the source drive to read it."))
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
