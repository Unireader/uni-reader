import Foundation

/// 开着服务器工作区时收到别的设备的改动（`SERVER-MODE-PLAN.md §6`，S4）——工作区这一层：让界面跟上已经写进库的行。
extension WorkspaceManager {

    /// 这个工作区开着的所有标签页（跨窗口）。
    var openTabs: [DocTabModel] {
        (AppDelegate.shared?.readerWindowControllers ?? []).filter { $0.workspace === self }.flatMap { $0.tabs.tabs }
    }

    /// 同步拉到了别的设备的行，已经 `applyPulled` 写进库之后调：列表按受影响的表刷新，开着的文档把自己那几类重新装载。
    /// 🔴 只刷新受影响的：`refreshNotes()` 要重扫笔记目录，不是每次都该跑。
    func applyRemoteRows(_ rows: [SyncWire.PulledRow]) {
        guard !rows.isEmpty else { return }
        let tables = Set(rows.map(\.table))
        if !tables.isDisjoint(with: ["document", "variant", "location"]) {
            reloadDocumentList()
        }
        if tables.contains("md_doc") || rows.contains(where: { $0.table == "meta" && $0.rowId == "note_sources" }) {
            refreshNotes()
        }
        if !tables.isDisjoint(with: ["board_note", "board_page", "board_item"]) { refreshBoards() }
        if !tables.isDisjoint(with: ["exercise", "exercise_attempt"]) { refreshExercises() }
        for tab in openTabs { tab.applyRemote(rows) }
    }

    /// 开着的编辑器里的内建笔记（`Notes/…` 路径）：服务器同步这一轮不碰它们。
    func openNoteSyncSkip() -> Set<String> {
        Set(MarkdownDocView.openRefs(of: self).filter { $0.sourceID == NoteRoot.workspaceID }
            .map { SyncNotes.prefix + SyncNotes.normalize($0.relPath) })
    }
}
