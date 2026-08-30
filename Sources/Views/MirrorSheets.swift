import SwiftUI

/// 离线镜像的两张面板：**建镜像** 与 **同步预览**（方案 `OFFLINE-MIRROR-PLAN.md` §8）。
///
/// 都是系统标准控件堆出来的（`Form`/`List`/`ProgressView`），没有自绘的仿系统样式 —— 那是红线。

// MARK: - 建镜像

/// 选内容 + 选位置 + 看估算 + 建。
struct MakeMirrorSheet: View {
    @EnvironmentObject var workspace: WorkspaceManager
    @Environment(\.dismiss) private var dismiss

    /// 勾了「带 PDF」的书。默认全勾 —— 想做的本来就是「整个搬走」，取消才是少数动作。
    @State private var withPDF: Set<String> = []
    @State private var estimate: MirrorBuilder.Estimate?
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
                        if !workspace.hasLocalFile(doc.id) {
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
            }

            HStack {
                Spacer()
                Button(L("Cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(L("Create Mirror…")) { chooseDestinationAndRun() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(running)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear {
            withPDF = Set(workspace.documents.map(\.id))
            recomputeEstimate()
        }
    }

    private func recomputeEstimate() { estimate = workspace.mirrorEstimate(documentsWithPDF: withPDF) }

    private func chooseDestinationAndRun() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.folder]
        panel.nameFieldStringValue = "\(workspace.name).\(WorkspaceManager.packageExtension)"
        panel.prompt = L("Create")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        running = true; error = nil; done = nil
        let ids = withPDF
        // 拷 PDF 是 GB 级、慢卷上建库是秒级 —— 主线程做必然转菊花
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let r = try workspace.makeMirror(to: url, documentsWithPDF: ids) { s, f in
                    DispatchQueue.main.async { step = s; fraction = f }
                }
                DispatchQueue.main.async { running = false; done = r }
            } catch {
                DispatchQueue.main.async { running = false; self.error = error.localizedDescription }
            }
        }
    }
}

// MARK: - 同步预览

/// 干跑：**只算不写**。按下同步会发生什么，在这里一次说清。
/// （真正应用合并是 M5；本面板刻意不提供那个按钮，免得给出"点了就会同步"的错觉。）
struct MirrorSyncSheet: View {
    @EnvironmentObject var workspace: WorkspaceManager
    @EnvironmentObject var registry: WorkspaceRegistry
    @Environment(\.dismiss) private var dismiss

    @State private var searching = true
    @State private var sourceURL: URL?
    @State private var lines: [MirrorReport.Line] = []
    @State private var headline = ""
    @State private var error: String?

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
                Text(L("Nothing has been written. Applying a merge isn’t available yet."))
                    .font(.callout).foregroundStyle(.secondary)
            }

            if let error {
                Label(error, systemImage: "xmark.octagon").foregroundStyle(.red).font(.callout)
            }

            HStack {
                Spacer()
                Button(L("Done")) { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 480)
        .onAppear(perform: run)
    }

    private func run() {
        guard let id = workspace.mirrorSourceId else { searching = false; return }
        let recents = registry.recents
        DispatchQueue.global(qos: .userInitiated).async {
            let found = WorkspaceManager.findMirrorSource(id: id, recents: recents)
            guard let found else {
                DispatchQueue.main.async { searching = false }
                return
            }
            do {
                let (plan, titles) = try workspace.mirrorDryRun(sourceFolder: found)
                let ls = MirrorReport.summary(plan, titles: titles)
                let hl = MirrorReport.headline(plan)
                DispatchQueue.main.async {
                    sourceURL = found; lines = ls; headline = hl; searching = false
                }
            } catch {
                DispatchQueue.main.async { searching = false; self.error = error.localizedDescription }
            }
        }
    }
}
