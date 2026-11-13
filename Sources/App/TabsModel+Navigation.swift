import Foundation

/// 窗口里的「一处」：哪个标签里的什么内容，PDF 再加上页内位置。工具栏「返回」/ ⌘[ ⌘] 用（`NavHistory`）。
struct NavPlace {
    enum Target: Equatable {
        case document(String)
        case markdown(NoteRef)
        case board(UUID)
        case exercises(ExerciseScope)
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

@MainActor
extension TabsModel {

    /// 某个标签眼下这一处；空标签没有。
    func place(of tab: DocTabModel) -> NavPlace? {
        if let id = tab.docID {
            return NavPlace(target: .document(id), tabID: tab.id,
                            mark: tab.session.pdf != nil ? tab.session.currentMark : nil)
        }
        if let ref = tab.noteRef { return NavPlace(target: .markdown(ref), tabID: tab.id) }
        if let id = tab.boardID { return NavPlace(target: .board(id), tabID: tab.id) }
        if let scope = tab.exerciseScope { return NavPlace(target: .exercises(scope), tabID: tab.id) }
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
            case .markdown, .board:
                return false
            }
        }
    }

    /// 回到某处：标签还开着（内容没换）就切过去，否则按内容重新打开；PDF 再回到那一页的那个位置。不另记历史。
    private func visit(_ place: NavPlace) {
        isNavigatingHistory = true
        defer { isNavigatingHistory = false }
        let tab: DocTabModel
        if let open = tabs.first(where: { $0.id == place.tabID && self.place(of: $0)?.target == place.target }) {
            activate(open.id)
            tab = open
        } else {
            switch place.target {
            case .document(let id): tab = self.open(id)
            case .markdown(let ref): tab = openMarkdown(ref)
            case .board(let id): tab = openBoard(id)
            case .exercises(let scope): tab = openExercises(scope)
            }
        }
        if let mark = place.mark, tab.docID != nil { tab.session.revisit(mark) }
    }
}
