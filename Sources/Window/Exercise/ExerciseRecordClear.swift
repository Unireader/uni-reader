import AppKit

/// 清除做题记录（`EXERCISE-PLAN.md §31`）：练习列表右键与侧栏习题行右键共用的那一步——先问、再归档后清。
///
/// 只清在 App 里（Mac / 平板 / 安卓模式1）做的作答，Agent 从 PDF 上识别导入的「书上的作答」留着；
/// 错题本按剩下的记录重算（用户 2026-11-15 定）。清之前整份进回收站，能恢复。
@MainActor
enum ExerciseRecordClear {
    /// 菜单项标题；这几道里一道都没做过 → nil（不放这一项）。
    static func menuTitle(ids: [String], workspace: WorkspaceManager) -> String? {
        let n = workspace.exercisesWithAttempts(ids: ids).count
        guard n > 0 else { return nil }
        return n == 1 ? L("Clear Practice Record…") : String(format: L("Clear Practice Records of %d Exercises…"), n)
    }

    /// 确认后清。`window` 为 nil 时用模态对话框。
    static func confirm(ids: [String], workspace: WorkspaceManager, on window: NSWindow?) {
        let todo = workspace.exercisesWithAttempts(ids: ids)
        guard !todo.isEmpty else { return }
        let a = NSAlert()
        a.messageText = todo.count == 1 ? L("Clear the practice record of this exercise?")
            : String(format: L("Clear the practice records of %d exercises?"), todo.count)
        a.informativeText = L("Every answer you gave is removed, and the Mistakes list is updated to match. Answers imported from the book stay. You can put the records back from Recently Deleted.")
        a.addButton(withTitle: L("Clear"))
        a.addButton(withTitle: L("Cancel"))
        let finish: (NSApplication.ModalResponse) -> Void = { resp in
            guard resp == .alertFirstButtonReturn else { return }
            guard workspace.clearExerciseAttempts(ids: todo) != nil else {
                let e = NSAlert()
                e.messageText = workspace.lastError ?? L("Could not clear the practice records.")
                if let window { e.beginSheetModal(for: window) } else { e.runModal() }
                return
            }
            ExerciseDeck.forgetAnswers(ids: todo, workspace: workspace)
        }
        if let window { a.beginSheetModal(for: window, completionHandler: finish) } else { finish(a.runModal()) }
    }
}
