import Foundation

/// 窗口里的「一处」：哪个标签里的什么内容，PDF 再加上页内位置。工具栏「返回」/ ⌘[ ⌘] 用（`NavHistory`）。
struct NavPlace {
    enum Target: Equatable {
        case document(String)
        case markdown(NoteRef)
        case board(UUID)
        case exercises(ExerciseScope)
        case schedule
        case web(String)
    }
    let target: Target
    /// 当时在哪个标签里：还开着就切回它，关了就按 `target` 重新打开。
    let tabID: UUID
    /// PDF 的页与页内比例（其余种类标签自己记得停在哪）。
    var mark: JumpMark?

    func samePlace(as other: NavPlace) -> Bool {
        guard target == other.target else { return false }
        switch (mark, other.mark) {
        case (nil, nil): return true
        case let (a?, b?): return a.samePlace(as: b)
        default: return false
        }
    }
}

/// 同一工作区全部标签（= 阅读窗口）共用的「返回 / 前进」历史（`NATIVE-TABS-PLAN.md §3`，挂在 `WorkspaceManager.tabNav`）。
@MainActor
final class TabNavGroup {
    var history = NavHistory<NavPlace>()
    /// 正在按历史回到某处（这一路上的切标签 / 跳页不记）。
    var isNavigating = false
    /// 眼下在最前面的标签：切到别的标签时，从它这里记下「离开的那一处」（关掉时清空，关掉的不进历史）。
    weak var front: TabsModel?
    /// 上一个成为 key 的标签（关掉时**不**清）：切到别的标签时，侧栏 / Inspector 照它摆
    /// （`ReaderWindowController.adoptChromeFromFrontTab`；关标签后系统选中相邻的那个，也要照刚关掉的这个摆）。
    weak var chromeSource: TabsModel?
    /// 刚关掉的最前面那个标签留下的窗口状态 + 当时同组的其余窗口（只给它们用，用一次就清）。
    var closedChrome: (snapshot: ReaderWindowController.ChromeSnapshot, siblings: Set<ObjectIdentifier>)?
}

@MainActor
extension TabsModel {

    /// 这个标签到了最前面（它那扇窗口成了 key，`ReaderWindowController.windowDidBecomeKey`）：
    /// 一个标签 = 一扇窗口之后，切标签不再经过 `activate` 的切换分支，「离开上一个标签」在这里记。
    func cameToFront() {
        let g = workspace.tabNav
        g.chromeSource = self
        guard g.front !== self else { return }
        if let prev = g.front { prev.noteLeaving() }   // 回放历史途中 `noteLeaving` 自己不记
        noteArrival()
        g.front = self
    }

    /// 某个标签眼下这一处；空标签没有。
    func place(of tab: DocTabModel) -> NavPlace? {
        if let id = tab.docID {
            return NavPlace(target: .document(id), tabID: tab.id,
                            mark: tab.session.pdf != nil ? tab.session.currentMark : nil)
        }
        if let ref = tab.noteRef { return NavPlace(target: .markdown(ref), tabID: tab.id) }
        if let id = tab.boardID { return NavPlace(target: .board(id), tabID: tab.id) }
        if let scope = tab.exerciseScope { return NavPlace(target: .exercises(scope), tabID: tab.id) }
        if tab.showsSchedule { return NavPlace(target: .schedule, tabID: tab.id) }
        if let id = tab.webDocID { return NavPlace(target: .web(id), tabID: tab.id) }
        return nil
    }

    /// 要离开眼下这一处了（切标签 / 在当前标签里换内容）：记进后退栈。返回 / 前进途中不记。
    func noteLeaving() {
        guard !isNavigatingHistory, let here = place(of: active) else { return }
        navHistory.record(leaving: here) { $0.samePlace(as: $1) }
    }

    /// 刚到一处：这一轮里紧跟着的跳页算同一步（点链接 = 切到那本书的标签 + 跳到那一页，只记一笔）。
    func noteArrival() {
        arrivingThisTurn = true
        DispatchQueue.main.async { [weak self] in self?.arrivingThisTurn = false }
    }

    /// 标签里的 PDF 要跳转了（目录 / 搜索 / 链接 / 书签……，`DocSession.jump`）：离开的位置也记进窗口的历史。
    func pdfWillJump(in tab: DocTabModel, leaving mark: JumpMark) {
        guard !isNavigatingHistory, !arrivingThisTurn, tab.id == activeID, let id = tab.docID else { return }
        navHistory.record(leaving: NavPlace(target: .document(id), tabID: tab.id, mark: mark)) { $0.samePlace(as: $1) }
    }

    /// 让标签里 PDF 的跳转通知到这里（每个新建的标签都接一次）。
    func adoptForNavigation(_ tab: DocTabModel) {
        tab.session.onWillJump = { [weak self, weak tab] mark in
            guard let self, let tab else { return }
            self.pdfWillJump(in: tab, leaving: mark)
        }
    }

    var canGoBack: Bool { navHistory.canGoBack }
    var canGoForward: Bool { navHistory.canGoForward }

    func goBack() {
        dropUnreachablePlaces()
        guard let target = navHistory.back(from: place(of: active)) else { return }
        visit(target)
    }

    func goForward() {
        dropUnreachablePlaces()
        guard let target = navHistory.forward(from: place(of: active)) else { return }
        visit(target)
    }

    /// 文档删了、笔记没了的那几处去不了，先拿掉（不然按一下返回什么也不发生）。
    private func dropUnreachablePlaces() {
        navHistory.remove { place in
            switch place.target {
            case .document(let id): return workspace.document(id: id) == nil
            case .exercises(let scope):
                if let id = scope.documentId { return workspace.document(id: id) == nil }
                return false
            case .web(let id): return workspace.webDoc(id: id) == nil
            case .markdown, .board, .schedule:
                return false
            }
        }
    }

    /// 回到某处：标签还开着（内容没换）就切过去，否则按内容重新打开；PDF 再回到那一页的那个位置。不另记历史。
    private func visit(_ place: NavPlace) {
        isNavigatingHistory = true
        defer { isNavigatingHistory = false }
        let tab: DocTabModel
        // 那个标签还开着（同组任一扇窗口、内容没换）→ 切过去
        if let peer = peers.first(where: { $0.active.id == place.tabID && self.place(of: $0.active)?.target == place.target }) {
            peer.focusWindow()
            workspace.tabNav.front = peer   // 回放途中切过去不记「离开」；直接把最前面的标签记成它
            tab = peer.active
        } else {
            switch place.target {
            case .document(let id): tab = self.open(id)
            case .markdown(let ref): tab = openMarkdown(ref)
            case .board(let id): tab = openBoard(id)
            case .exercises(let scope): tab = openExercises(scope)
            case .schedule: tab = openSchedule()
            case .web(let id): tab = openWebDoc(id)
            }
        }
        if let mark = place.mark, tab.docID != nil { tab.session.revisit(mark) }
    }
}
