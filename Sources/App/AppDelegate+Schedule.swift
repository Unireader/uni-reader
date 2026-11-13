import AppKit

extension AppDelegate {
    /// 把日程显示出来（MCP `open_schedule`、菜单「日程」，`SCHEDULE-PLAN.md §4`）：这个工作区开着的窗口里挑一扇
    /// （key 的优先），没有就开一扇；在里面打开日程标签，带上要去的地方。规矩同 `showExercises`。
    @discardableResult
    func showSchedule(focus: ScheduleFocus?, in ws: WorkspaceManager, activate: Bool) throws -> (ReaderWindowController, DocTabModel) {
        let c: ReaderWindowController
        let mine = readerWindowControllers.filter { $0.workspace === ws }
        if let k = mine.first(where: { $0.window?.isKeyWindow == true }) ?? mine.first { c = k }
        else { c = try makeReaderWindow(workspacePath: ws.folder?.path, docId: nil, activate: activate) }
        let tab = c.tabs.openSchedule(focus: focus)
        if activate {
            NSApp.activate(ignoringOtherApps: true)
            c.window?.makeKeyAndOrderFront(nil)
        }
        return (c, tab)
    }
}
