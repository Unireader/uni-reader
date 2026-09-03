import SwiftUI

/// 侧栏：当前工作区的文档列表 + 工作区切换/重命名。原生单列表，保持 sidebar 样式。
/// 文档可设一级分组（v11）：有分组时按分组分段（未分组在前），右键「Move to Group」移动，
/// 分组段头右键改名/删除（删除 = 文档回未分组）；文档行可**拖到段头**换分组（多选时整批移动）。
/// **手动排序**（2026-09-03）：右键「上移 / 下移」，**只在同一分组段内**换位（多选时整批一起动）。
/// 落库写 `document.sort_order`（见 `WorkspaceManager.reorderDocuments`）；没排过的书 `sort_order=0`
/// 仍排在最前，于是「新加的书出现在顶上」这条老观感不变。
/// 🔴 **拖拽排序做过三版、全部撤销，勿再尝试**（用户 2026-09-03 明确否决：「你没这个能力做好这个
/// 功能」）。三版分别是：命中行整行铺色（「UI 不好看」——那在 Finder 里是「放进这个容器」的意思）、
/// 行间插入线（「交互太垃圾」）、实时让位（观感一路修到「拖起即离列 + 让位动画防抖」仍不达标）。
/// 记下踩到的坑，将来真要再做时**从这里起步、别重走**：
///  · 起手只能用 `.draggable`——`List(selection:)` 里 `.onDrag` 对**未选中**的行根本不触发；
///  · 但 `.draggable` 没有「拖起」回调，「拖的是谁」只能在 drop 侧从 item provider 异步读回；
///  · 被拖那行不能在拖拽图像拍好之前隐藏，否则跟着鼠标的那张图是空的；
///  · 拖拽图像不继承侧栏外观（深色下语义色被解析成黑字），要给 `preview` 显式配色；
///  · 行/段头的 drop 不能拿 `hasItemsConforming(to: [.text])` 当门——`public.file-url` conform 到
///    `public.text`，会把「从 Finder 拖 PDF 进书库」整条吃掉；
///  · SwiftUI 没有 dragEnd 回调，拖到列表外松手要靠别的信号兜底收场。
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
    /// 跑的期间又来了请求（比如插盘）→ 记一笔，跑完补一轮。**不能直接丢**，见 `refreshNotice`
    @State private var noticePending = false

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
        /// 我是副本，源盘插回来了。`Int?` = 有多少项要同步，**nil 表示还在算**
        /// ——找到盘只要几毫秒，算完要跑一次完整三方 diff（两个库整个快照 + 逐行指纹，
        /// 盘还在 USB 上）。把「源盘已连接」压到算完才说，用户实测「插上去半天没反应」。
        case sourceBack(URL, Int?)
        case unsynced(URL, Int)     // 我是源盘，副本里有 N 项要**推回源盘**，等人工确认
    }

    @ViewBuilder
    private func noticeRow(_ n: Notice) -> some View {
        switch n {
        case .sourceBack(let src, let count):
            Button {
                // 没东西可同步就别开面板了，直接切回去 —— 那才是用户插盘时想做的事
                if count == 0 { switchBack(to: src) }
                else { syncTarget = SyncTarget(side: .fromMirror, switchTo: src) }
            } label: {
                Label {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(L("Source drive is connected"))
                        // nil = 还在算。先把「盘回来了」说出去，别让用户对着空气等
                        switch count {
                        case .none:
                            Text(L("Checking what needs syncing…"))
                                .font(.caption).foregroundStyle(.secondary)
                        case .some(0):
                            Text(L("Both sides match · switch back")).font(.caption).foregroundStyle(.secondary)
                        case .some(let n):
                            Text(String(format: L("%d items to sync · tap to review"), n))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                } icon: {
                    Image(systemName: "eject")
                }
            }
            .disabled(count == nil)
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
        // 🔴 在跑就**记一笔待办**，不能直接丢：插盘通知正好撞上上一轮时，丢掉就等于
        //    「插了盘再也不提示」（用户 2026-09-01 实测的一半原因）。
        guard !noticeBusy else { noticePending = true; return }
        guard let folder = workspace.folder else { notice = nil; return }
        if workspace.isMirror {
            guard let id = workspace.mirrorSourceId else { notice = nil; return }
            noticeBusy = true
            let recents = registry.recents.map { URL(fileURLWithPath: $0.sourcePath) }
            DispatchQueue.global(qos: .utility).async {
                // ① 找盘只要几毫秒 —— 先把「盘回来了」说出去
                let src = WorkspaceManager.findMirrorSource(id: id, recents: recents)
                DispatchQueue.main.async { notice = src.map { .sourceBack($0, nil) } }
                guard let src else { DispatchQueue.main.async { finishNotice() }; return }
                // ② 再慢慢算「有多少要同步」：完整三方 diff，两个库整个快照 + 逐行指纹，
                //    盘还在 USB 上，几十秒都可能。算完把那行小字换掉。
                let n = (try? workspace.mirrorDryRun(sourceFolder: src))?.plan.changes.count ?? 0
                DispatchQueue.main.async { notice = .sourceBack(src, n); finishNotice() }
            }
        } else if let p = registry.mirrorPath(forSource: folder, id: workspace.workspaceId) {
            noticeBusy = true
            let mirror = URL(fileURLWithPath: p)
            DispatchQueue.global(qos: .utility).async {
                // 该静默推的推掉，返回还剩多少要人工确认（副本→源盘那个方向）
                let pending = workspace.autoPushToMirror(mirrorFolder: mirror) ?? 0
                DispatchQueue.main.async {
                    notice = pending > 0 ? .unsynced(mirror, pending) : nil
                    finishNotice()
                }
            }
        } else {
            notice = nil
        }
    }

    /// 一轮跑完：期间来过请求就再跑一轮（合并成一次，不排队）。
    private func finishNotice() {
        noticeBusy = false
        if noticePending { noticePending = false; refreshNotice() }
    }

    /// 切回源盘：**先开源盘那扇窗，再关副本这扇**。
    /// 次序不能反 —— 开窗要经 key 窗口的 `ContentView` 路由，先关就可能把唯一的订阅者关掉
    /// （2026-07-29 那笔老账，弹盘那条路径同理）。
    private func switchBack(to src: URL) {
        onOpenRecent(src)
        registry.requestActivation(forWorkspace: src)
        if let mirror = workspace.folder { registry.evacuate(mirror) }
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
        // 🔴 侧栏样式要**显式声明**：迁移前它在 `NavigationSplitView` 的 sidebar 位置上，
        // SwiftUI 自动套 `.sidebar` 外观；装进 `NSHostingController` 之后没人替它决定，
        // 会退回普通 List（不透明底、方角选中行）——2026-09-01 用户报的「侧边栏不沉浸了」。
        // `scrollContentBackground(.hidden)` 是另一半：List 自己那层不透明底会把
        // `NSSplitViewItem` 的侧栏材质整个挡住。
        sheetsAndAlerts(mainList
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden))
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
            syncSelection(id)
        }
        // 🔴 **首帧也要同步一次**：`onChange` 只认「变化」，而 2026-09-01 窗口层迁到 AppKit 后
        // `restoreTabs()` 是在 `ReaderWindowController.init` 里跑的（**视图创建之前**），
        // 首帧 `selection` 就已经是最终值 → 那条 onChange 永远不触发，表现是
        // 「PDF 开着，侧栏里却没有一行是选中的」。迁移前它在 `onAppear` 之后跑，靠 nil→X 那一次
        // 变化把选中集带起来，是**碰巧**成立的。
        .onAppear { syncSelection(selection) }
        .dropDestination(for: URL.self) { urls, _ in onDropFiles(urls); return true }
        .navigationTitle(L("Library"))
        // 🔴 这里原先是一条 SwiftUI `.toolbar { }`（加书 + 工作区菜单）。2026-09-01 窗口层迁到
        // AppKit 之后**它整块失效**——SwiftUI 的 toolbar 只作用于它自己创建的窗口，装进
        // `NSHostingController` 对 AppKit 窗口无效（与 AI 浮窗同一个坑）。那两枚现在由
        // `ReaderWindowController` 的 `NSToolbar` 提供，落在侧栏那一侧。
        //
        // 需要弹 sheet/alert 的几项（重命名 / 离线副本 / 同步）没法在窗口层做——开关是下面这些
        // `@State`。菜单点了发通知，这里接住、翻自己的状态，sheet 照旧由 `sheetsAndAlerts` 弹。
        .onReceive(NotificationCenter.default.publisher(for: .workspaceRenameRequested)) { _ in
            nameField = workspace.name
            renameShown = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .workspaceMakeMirrorRequested)) { _ in
            makeMirrorShown = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .workspaceDropMirrorRequested)) { _ in
            dropMirrorShown = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .workspaceSyncToSourceRequested)) { _ in
            syncTarget = SyncTarget(side: .fromMirror, switchTo: nil)
        }
    }

    /// 侧栏挂着的全部面板/弹窗，外加离线副本提示条的重算时机（见 `mainList` 的注释）。
    /// 打开的文档 → List 的选中集。两处调用（首帧 + 之后每次变化），保持一份实现。
    private func syncSelection(_ id: String?) {
        let s: Set<String> = id.map { [$0] } ?? []
        if s != multiSel { multiSel = s }
    }

    private func sheetsAndAlerts<V: View>(_ base: V) -> some View {
        base
        .sheet(isPresented: $makeMirrorShown, onDismiss: refreshNotice) { MakeMirrorSheet() }
        .sheet(item: $syncTarget, onDismiss: refreshNotice) { t in
            // 「同步并切回」：同步成功后开源盘那扇窗，并**把副本这扇关掉**
            // （只开不关的话屏幕上会留着一扇已经没意义的旧窗，用户 2026-09-01 实测提的）
            MirrorSyncSheet(side: t.side, onSynced: t.switchTo.map { src in { _ in switchBack(to: src) } })
        }
        .onAppear(perform: refreshNotice)
        .onChange(of: workspace.folder) { _, _ in refreshNotice() }
        // 加书/删书当场就推过去；不然「静默同步」得等下次开窗口才发生，用户拔了盘才发现没跟上
        .onChange(of: workspace.documents.count) { _, _ in refreshNotice() }
        // 切走的时候再顺一遍：笔迹这类改动不会动 documents.count，
        // 而「切走」正是个天然的收尾时机（也是用户接下来最可能去拔盘的时刻）
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.willResignActiveNotification)) { _ in refreshNotice() }
        // 源盘插回来了 → 当场重算，不用等用户切窗口才发现「哦原来能同步了」
        .onReceive(NotificationCenter.default.publisher(for: .volumeDidMount)) { _ in refreshNotice() }
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

    // MARK: - 手动排序（右键上移/下移）

    /// 排序**只在同一分组段内**进行（列表就是按分组分段显示的，跨段移动没有意义）。
    /// 多选时整批一起动、保持彼此相对顺序：与这批相邻的那一项跨过整批到另一头去。
    private func canMove(_ ids: Set<String>, up: Bool) -> Bool {
        guard let g = sameGroup(ids) else { return false }
        let section = workspace.documents.filter { $0.group == g }
        let idxs = section.indices.filter { ids.contains(section[$0].id) }
        guard let first = idxs.first, let last = idxs.last else { return false }
        return up ? first > 0 : last < section.count - 1
    }

    private func moveSelection(_ ids: Set<String>, up: Bool) {
        guard let g = sameGroup(ids) else { return }
        var section = workspace.documents.filter { $0.group == g }
        let idxs = section.indices.filter { ids.contains(section[$0].id) }
        guard let first = idxs.first, let last = idxs.last else { return }
        if up {
            guard first > 0 else { return }
            let neighbor = section.remove(at: first - 1)   // 移走它之后，last 就是「整批之后」那一位
            section.insert(neighbor, at: last)
        } else {
            guard last < section.count - 1 else { return }
            let neighbor = section.remove(at: last + 1)
            section.insert(neighbor, at: first)
        }
        // 段内新顺序填回全局：**只动这一段占的那些位置**，别的分组一位不挪。
        var all = workspace.documents
        var it = section.makeIterator()
        for i in all.indices where all[i].group == g {
            if let d = it.next() { all[i] = d }
        }
        workspace.reorderDocuments(all.map(\.id))
    }

    /// 这批文档是否同属一个分组（是则返回分组名；混着来就不给排——跨段移动没有意义）。
    private func sameGroup(_ ids: Set<String>) -> String? {
        let groups = Set(ids.compactMap { workspace.document(id: $0)?.group })
        return groups.count == 1 ? groups.first : nil
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
        // 手动排序：同一分组段内上移/下移（多选时整批）。边界上或跨分组混选时禁用，
        // **不隐藏**——菜单项忽隐忽现比灰着更难用。
        Button { moveSelection(targets, up: true) } label: {
            Label(L("Move Up"), systemImage: "arrow.up")
        }
        .disabled(!canMove(targets, up: true))
        Button { moveSelection(targets, up: false) } label: {
            Label(L("Move Down"), systemImage: "arrow.down")
        }
        .disabled(!canMove(targets, up: false))
        Divider()
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
