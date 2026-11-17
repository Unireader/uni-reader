import AppKit

/// 笔记改名 / 挪目录之后，**联动改**别的笔记里指向它的 `[[…]]`（用户 2026-11-17 定，推翻原红线 9 的「改名不改别人的正文」）。
///
/// 界面上的「重命名…」与 MCP `rename_markdown` / `move_markdown_folder` 都走这一份：动完文件、重扫索引之后调 `run`。
/// 只改链接的目标名那一段（`NoteIndex.relinked`），锚点、别名、正文别的字不动。删除不联动（没有新名字可写），照旧只报断链。
///
/// 读全部笔记放到主线程外；要改的那几篇回到主线程按**此刻的正文**（开着的编辑器里没存的输入算数）再算一遍、写盘、推回编辑器
/// ——同 MCP 写笔记的那条路（`MCPFacade.commitMarkdown`），编辑器稍后的自动保存不会把改动盖回去。
/// 跳过写不了的源：服务器镜像（只读）、不在这台电脑上的引用目录。
@MainActor
enum NoteRelink {
    /// 界面上改一篇笔记的名字（侧栏右键「重命名…」与编辑区顶上的标题共用这一份）：
    /// 开着它的编辑器先存盘 → 改文件名 → 各窗口里开着它的标签 / 小窗跟过去 → 别的笔记里指向旧名字的 `[[…]]` 联动改。
    /// 失败返回 nil，原因在 `workspace.lastError`。
    @discardableResult
    static func renameFromUI(_ ref: NoteRef, to name: String, in ws: WorkspaceManager) -> NoteRef? {
        // 开着它的编辑器先存盘（挪走之后旧路径上没文件，自动保存就不存了）
        MarkdownDocView.flushEditors(showing: ref, in: ws)
        let before = ws.wiki.snapshot()
        guard let newRef = ws.renameNote(ref, to: name) else { return nil }
        guard newRef != ref else { return newRef }
        // 所有窗口里开着它的标签 / 小窗都跟过去（原先只换了本窗口的标签，别的窗口那份和小窗会被关掉）
        ReaderWindowController.noteMoved(from: ref, to: newRef, in: ws)
        Task { @MainActor in _ = await run(ws, before: before, moved: [ref: newRef]) }
        return newRef
    }

    struct Report {
        /// 改了的笔记与每处改动（原样写法 → 新写法）。
        var notes: [(ref: NoteRef, changes: [(from: String, to: String)])] = []
        /// 按新名字也指不到它、没改的（按理不会有）。
        var unresolved: [(ref: NoteRef, names: [String])] = []
        /// 想改但没改成的：同一篇开在几个编辑器里、各有不同的未存输入，或写盘失败。
        var failed: [(ref: NoteRef, reason: String)] = []
        var linkCount: Int { notes.reduce(0) { $0 + $1.changes.count } }
    }

    /// `before`：动文件之前的索引快照（`ws.wiki.snapshot()`）；`moved`：旧位置 → 新位置。调用前文件已挪好、`refreshNotes()` 已做。
    static func run(_ ws: WorkspaceManager, before: NoteIndex, moved: [NoteRef: NoteRef]) async -> Report {
        var report = Report()
        let moved = moved.filter { $0.key != $0.value }
        guard !moved.isEmpty else { return report }
        let after = ws.wiki.snapshot()
        var writable: [String: Bool] = [:]
        func canWrite(_ id: String) -> Bool {
            if let b = writable[id] { return b }
            let b = (try? ws.agentWritableRoot(id, verb: "changed")) != nil
            writable[id] = b
            return b
        }
        let files = ws.allNotes.compactMap { n -> (ref: NoteRef, url: URL)? in
            guard canWrite(n.ref.sourceID), let u = ws.noteURL(n.ref) else { return nil }
            return (n.ref, u)
        }
        // ① 主线程外读盘、挑出可能要改的
        let onDisk: [NoteRef] = await Task.detached(priority: .userInitiated) {
            files.compactMap { f in
                guard let text = MarkdownImport.readText(f.url),
                      NoteIndex.relinked(text, before: before, after: after, moved: moved) != nil else { return nil }
                return f.ref
            }
        }.value
        // ② 开着、还有没存输入的那几篇也看一遍（盘上的旧版本里可能还没有这条链接）
        var seen = Set<NoteRef>()
        let candidates = (onDisk + MarkdownDocView.unsavedRefs(of: ws).filter { canWrite($0.sourceID) })
            .filter { seen.insert($0).inserted }
        for ref in candidates {
            let editors = MarkdownDocView.editors(showing: ref, in: ws)
            let texts = Set(editors.map(\.currentText))
            guard texts.count <= 1 else {
                report.failed.append((ref, "open in several editors with different unsaved edits"))
                continue
            }
            guard let current = texts.first ?? ws.noteBody(ref),
                  let r = NoteIndex.relinked(current, before: before, after: after, moved: moved) else { continue }
            if !r.unresolved.isEmpty { report.unresolved.append((ref, r.unresolved)) }
            guard !r.changes.isEmpty else { continue }
            guard ws.saveNoteBody(ref, text: r.text) else {
                report.failed.append((ref, ws.lastError ?? "could not save"))
                continue
            }
            for e in editors { e.applySavedText(r.text) }
            report.notes.append((ref, r.changes))
        }
        if !report.notes.isEmpty {
            ws.refreshNotes()   // 别名表按正文建，链接改了要重扫
            wsLog("[MD] 改名联动：\(report.notes.count) 篇里改了 \(report.linkCount) 处链接")
        }
        return report
    }
}
