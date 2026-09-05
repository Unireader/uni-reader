import SwiftUI

/// 离线镜像的两张面板：**建镜像** 与 **同步预览**（方案 `OFFLINE-MIRROR-PLAN.md` §8）。
///
/// 都是系统标准控件堆出来的（`Form`/`List`/`ProgressView`），没有自绘的仿系统样式 —— 那是红线。

// MARK: - 建镜像

/// 选内容 + 看估算 + 建。**位置不让用户挑**（理由见 `WorkspaceManager.mirrorsRoot`）：
/// 这里只把算好的落点摆出来，建完挂到这个工作区那条最近记录上，
/// 之后源盘不在时由打开链路自动选用 —— 副本**不占最近列表的一行**。
struct MakeMirrorSheet: View {
    @EnvironmentObject var workspace: WorkspaceManager
    @Environment(\.dismiss) private var dismiss

    /// 勾了「带 PDF」的书。默认全勾 —— 想做的本来就是「整个搬走」，取消才是少数动作。
    @State private var withPDF: Set<String> = []
    @State private var estimate: MirrorBuilder.Estimate?
    /// 估算是异步的，连点勾选框时先发的那次可能后回来 —— 只认最后一次（见 `recomputeEstimate`）
    @State private var estimateToken = 0
    /// 算好的落点（`onAppear` 定一次，全程就用它）
    @State private var destination: URL?
    /// 本机已经有的那份镜像。非 nil 就不给再建（见 `WorkspaceManager.existingMirror`）
    @State private var existing: URL?
    @State private var running = false
    @State private var step = ""
    @State private var fraction: Double = 0
    @State private var error: String?
    @State private var done: MirrorBuilder.Result?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("Offline Mirror"))
                .font(.headline)
            Text(L("All books and notes come along. Only the PDFs you tick are copied — the rest stay readable as entries you can open once the drive is back."))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            // 用 Toggle 而不是 List 的 selection：勾选是「带不带 PDF」这个属性，不是「选中了谁」
            List(workspace.documents, id: \.id) { doc in
                Toggle(isOn: Binding(
                    get: { withPDF.contains(doc.id) },
                    set: { on in
                        if on { withPDF.insert(doc.id) } else { withPDF.remove(doc.id) }
                        recomputeEstimate()
                    }
                )) {
                    HStack {
                        Text(doc.title)
                        Spacer()
                        if !workspace.hasLocalFileCached(doc.id) {   // 同上：body 里不查库
                            Text(L("file missing")).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .frame(minHeight: 200)

            if let e = estimate {
                Text(String(format: L("%d files · about %@"), e.files,
                            ByteCountFormatter.string(fromByteCount: e.bytes, countStyle: .file)))
                    .font(.callout)
                    .monospacedDigit()
                if !e.unresolved.isEmpty {
                    // 静默跳过的话用户会以为带上了，等硬盘不在手上时才发现打不开
                    Label(String(format: L("%d ticked books have no file right now and will be skipped."),
                                 e.unresolved.count),
                          systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
            }

            if let existing {
                // 已经有一份还闷头再建，等于把笔迹分散到两份镜像里，谁也说不清哪份是全的
                Label(L("This workspace already has an offline copy on this Mac."),
                      systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.orange)
                Text(L("Sync that one back and delete it first if you want a fresh copy."))
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button(L("Show in Finder")) { reveal(existing) }.controlSize(.small)
            } else if let destination, done == nil {
                // 位置是 App 定的，但不能是个黑箱：先把落点摆出来
                Text(String(format: L("Kept at %@"), tilde(destination)))
                    .font(.callout).foregroundStyle(.secondary)
                    .lineLimit(2).truncationMode(.middle).textSelection(.enabled)
            }

            if running {
                ProgressView(value: fraction) { Text(step) }
            }
            if let error {
                Label(error, systemImage: "xmark.octagon").foregroundStyle(.red).font(.callout)
            }
            if let done {
                Label(String(format: L("Mirror created: %d files, %d baseline rows."),
                             done.copiedFiles, done.baseRows),
                      systemImage: "checkmark.circle").font(.callout)
                // 这才是用户真正要知道的一句：以后不用管它
                Text(L("From now on, opening this workspace without the drive connected uses this copy automatically."))
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button(L("Show in Finder")) { reveal(done.url) }.controlSize(.small)
            }

            HStack {
                Spacer()
                Button(done == nil ? L("Cancel") : L("Done")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                if done == nil {
                    Button(L("Create Mirror")) { run() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(running || existing != nil)
                }
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear {
            withPDF = Set(workspace.documents.map(\.id))
            destination = WorkspaceManager.plannedMirrorURL(name: workspace.name)
            recomputeEstimate()
            // 要逐个打开 Mirrors/ 下每份副本的库看血缘 —— 本机盘，快，但没理由占着主线程
            let wid = workspace.workspaceId
            DispatchQueue.global(qos: .userInitiated).async {
                let found = wid.flatMap { WorkspaceManager.existingMirror(of: $0) }
                DispatchQueue.main.async { existing = found }
            }
        }
    }

    /// 🔴 **估算要逐本 stat 文件，而源盘在 USB 上** —— 放主线程做，光是打开面板就卡一下，
    /// 每点一个勾选框再卡一下（勾选会重算）。放后台，用 token 丢弃过期结果
    /// （连点几下时先发的那次可能后回来，不丢就会把旧数字盖上去）。
    private func recomputeEstimate() {
        estimateToken += 1
        let token = estimateToken
        let ids = withPDF
        DispatchQueue.global(qos: .userInitiated).async {
            let e = workspace.mirrorEstimate(documentsWithPDF: ids)
            DispatchQueue.main.async { if token == estimateToken { estimate = e } }
        }
    }

    private func tilde(_ url: URL) -> String { (url.path as NSString).abbreviatingWithTildeInPath }

    private func reveal(_ url: URL) { NSWorkspace.shared.activateFileViewerSelecting([url]) }

    private func run() {
        guard let url = destination else { return }
        running = true; error = nil; done = nil
        let ids = withPDF
        // 拷 PDF 是 GB 级、慢卷上建库是秒级 —— 主线程做必然转菊花
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let r = try workspace.makeMirror(to: url, documentsWithPDF: ids) { s, f in
                    DispatchQueue.main.async { step = s; fraction = f }
                }
                DispatchQueue.main.async {
                    running = false; done = r
                    // 🔴 **不进最近列表**：副本挂到这个工作区那条记录上，由打开链路自动选用。
                    // 让它自己占一行就退回「你自己拷了一份」——用户又得在两条里挑一条。
                    if let folder = workspace.folder {
                        WorkspaceRegistry.shared.setMirror(r.url.path, forSource: folder,
                                                           id: workspace.workspaceId)
                    }
                }
            } catch {
                DispatchQueue.main.async { running = false; self.error = error.localizedDescription }
            }
        }
    }
}

// MARK: - 同步预览

/// 先干跑（**只算不写**）给用户看清「按下去会发生什么」，确认之后才应用。
/// **干跑与应用用的是同一份 Plan**，不重算 —— 重算就意味着「用户看到的」和「实际做的」
/// 可能不是同一件事，而这一步会大批量改用户数据。
struct MirrorSyncSheet: View {
    /// 从哪一侧发起。两边算的是**同一份 plan**（`base`/`mine` 永远取副本那侧），
    /// 只是连接从哪来不同 —— 所以这张面板和 `MirrorApply` 都不必分两套。
    enum Side {
        case fromMirror                  // 我是副本，去找源盘
        case fromSource(mirror: URL)     // 我是源盘，副本在本机这个路径
    }

    var side: Side = .fromMirror
    /// 同步成功后回调「对面那份」的路径。副本侧的「同步并切回」靠它切窗口；菜单入口不传。
    var onSynced: ((URL) -> Void)?

    @EnvironmentObject var workspace: WorkspaceManager
    /// 🔴 **不能写 `@EnvironmentObject`**：全项目只注入了 `app` 与 `workspace`，
    /// 注册表从来没进过环境，写成 EnvironmentObject 就是打开这张面板必崩。
    /// 「最近工作区」本就是本机全局状态、不属于任何工作区，与 `SidebarView` 同款取单例。
    @ObservedObject private var registry = WorkspaceRegistry.shared
    @Environment(\.dismiss) private var dismiss

    @State private var searching = true
    @State private var sourceURL: URL?
    /// 干跑算出来的那一份，**应用时原样用它**（见类型注释）
    @State private var plan: MirrorDiff.Plan?
    @State private var lines: [MirrorReport.Line] = []
    @State private var headline = ""
    @State private var error: String?
    @State private var confirming = false
    @State private var applying = false
    @State private var step = ""
    @State private var fraction: Double = 0
    @State private var applied: MirrorApply.Result?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("Sync Preview")).font(.headline)

            if searching {
                HStack { ProgressView().controlSize(.small); Text(L("Looking for the source workspace…")) }
            } else if sourceURL == nil {
                // 判据是 workspace_id，提示里才用 hint —— 那个只是「上次见到它在哪」
                Label(L("The source workspace isn’t connected."), systemImage: "externaldrive.badge.questionmark")
                if !workspace.mirrorSourceHint.isEmpty {
                    Text(String(format: L("Last seen at: %@"), workspace.mirrorSourceHint))
                        .font(.callout).foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            } else {
                Text(headline).font(.callout).monospacedDigit()
                List {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        if line.detail.isEmpty {
                            Text(line.text)
                        } else {
                            DisclosureGroup(line.text) {
                                ForEach(line.detail, id: \.self) { Text($0).font(.callout) }
                            }
                        }
                    }
                }
                .frame(minHeight: 180)
                if applied == nil {
                    Text(L("Nothing has been written yet."))
                        .font(.callout).foregroundStyle(.secondary)
                }
                if applying { ProgressView(value: fraction) { Text(step) } }
                if let a = applied {
                    Label(String(format: L("Synced. Backup saved as %@"),
                                 a.backup?.lastPathComponent ?? "—"),
                          systemImage: "checkmark.circle").font(.callout)
                    // 静默丢行是绝对不行的：哪怕只有一条，也要让用户知道，还要说清怎么办
                    if a.orphansSkipped > 0 {
                        Label(String(format: L("%d rows were skipped: their document no longer exists."),
                                     a.orphansSkipped),
                              systemImage: "exclamationmark.triangle")
                            .font(.callout).foregroundStyle(.orange)
                    }
                    if a.hashClashesSkipped > 0 {
                        Label(String(format: L("%d versions were skipped: the other side already has the same file. Use “Link as Same Document” to merge them."),
                                     a.hashClashesSkipped),
                              systemImage: "exclamationmark.triangle")
                            .font(.callout).foregroundStyle(.orange)
                    }
                }
            }

            if let error {
                Label(error, systemImage: "xmark.octagon").foregroundStyle(.red).font(.callout)
            }

            HStack {
                Spacer()
                Button(L("Done")) { dismiss() }.keyboardShortcut(.cancelAction)
                if let p = plan, !p.isEmpty, applied == nil {
                    Button(L("Sync…")) { confirming = true }
                        .keyboardShortcut(.defaultAction)
                        .disabled(applying)
                }
            }
        }
        .padding(20)
        .frame(width: 480)
        .onAppear(perform: run)
        // 这一步会大批量改用户数据 —— 不给「直接执行」的入口，必须再点一次
        .confirmationDialog(L("Apply this merge?"), isPresented: $confirming) {
            Button(L("Sync"), role: .destructive) { applyNow() }
            Button(L("Cancel"), role: .cancel) {}
        } message: {
            Text(L("The source library is backed up first; the three most recent backups are kept."))
        }
    }

    private func run() {
        switch side {
        case .fromSource(let mirror):
            // 副本就在本机，没有「找不找得到」这回事
            sourceURL = mirror
            dryRun(mirror)
        case .fromMirror:
            guard let id = workspace.mirrorSourceId else { searching = false; return }
            // 候选给的是**源盘那份**：副本自己不可能是自己的源
            let recents = registry.recents.map { URL(fileURLWithPath: $0.sourcePath) }
            DispatchQueue.global(qos: .userInitiated).async {
                let found = WorkspaceManager.findMirrorSource(id: id, recents: recents)
                DispatchQueue.main.async {
                    guard let found else { searching = false; return }
                    sourceURL = found
                    dryRun(found)
                }
            }
        }
    }

    /// 算一次「按下同步会发生什么」。`other` = 对面那份的路径（副本侧是源盘，源盘侧是副本）。
    private func dryRun(_ other: URL) {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let dry = try computePlan(against: other)
                let ls = MirrorReport.summary(dry.plan, titles: dry.titles, hashTitles: dry.hashTitles)
                let hl = MirrorReport.headline(dry.plan)
                DispatchQueue.main.async {
                    plan = dry.plan; lines = ls; headline = hl; searching = false
                }
            } catch {
                DispatchQueue.main.async { searching = false; self.error = error.localizedDescription }
            }
        }
    }

    private func computePlan(against other: URL) throws -> WorkspaceManager.DryRun {
        switch side {
        case .fromMirror: return try workspace.mirrorDryRun(sourceFolder: other)
        case .fromSource: return try workspace.mirrorDryRunFromSource(mirrorFolder: other)
        }
    }

    private func applyNow() {
        guard let other = sourceURL, let p = plan else { return }
        applying = true; error = nil
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let progress: (String, Double) -> Void = { s, f in
                    DispatchQueue.main.async { step = s; fraction = f }
                }
                let r: MirrorApply.Result
                switch side {
                case .fromMirror:
                    r = try workspace.mirrorApply(sourceFolder: other, plan: p, progress: progress)
                case .fromSource:
                    r = try workspace.mirrorApplyFromSource(mirrorFolder: other, plan: p, progress: progress)
                }
                // 🔴 合并完**不再重算一遍报告**（2026-09-01 删）。它两种放法都出过事：
                // 放主线程（和 `applied = r` 同一个 main.async 块里）→ 块跑完之前 SwiftUI 一帧
                // 都渲染不出来，界面停在「进度条卡在半路 + 底下还写着『什么都没有写入』」；
                // 挪到后台 → 和主线程的 `refresh()`／侧栏渲染同时用同一条 SQLite 连接。
                // 而它本来就是多余的：合并成功即意味着两端一致，屏幕上留着「刚才做了什么」
                // 比留着一份「现在还剩什么」更贴合用户此刻要确认的事。
                DispatchQueue.main.async {
                    applying = false; applied = r
                    // 「同步并切回」会**关掉本窗口**（连同它的 store）—— 先把面板收起来再交棒，
                    // 别让一张挂在正在拆的窗口上的面板还引用着 workspace.store
                    if let onSynced { dismiss(); onSynced(other) }
                }
            } catch {
                DispatchQueue.main.async { applying = false; self.error = error.localizedDescription }
            }
        }
    }
}
