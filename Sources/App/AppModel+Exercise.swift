import AppKit
import Combine

/// 平板此刻开着的那一组题（`exOpen` 记下的）。工作区是 `exOpen` 那一刻被跟随会话所属的那个。
struct PadExerciseSub {
    weak var workspace: WorkspaceManager?
    let scope: ExerciseScope
}

/// `/exercise.png` 渲一道题要的东西（主线程备好，服务 queue 上用；同 Mac 本机「看原题」那一块）。
struct ExerciseImageSource {
    let path: String
    /// 0 起。
    let page: Int
    let region: [Double]?
    let align: PageAlign?
}

/// 习题的平板同步（模式2，`EXERCISE-PLAN.md §10.4`，协议 `PROTOCOL.md §4.9`）。
///
/// 平板开一组题 = 用 Mac 上**同一份** `ExerciseDeck`（工作区 + 范围）：平板只显示 Mac 算好的结果、把操作发回来，
/// 所以两边开着同一组时作答 / 第几题 / 筛选天然同步；平板开的那组不必是 Mac 当前标签（用户 2026-10-11 定）。
///
/// `WorkspaceManager` / `ExerciseDeck` 都是 `@MainActor`，而 `AppModel` 不是——这里的入口都在主线程上，
/// 统一用 `MainActor.assumeIsolated` 进去（不在主线程的调用一律先跳回主线程）。
extension AppModel {

    // MARK: - 订阅（App 启动时接一次）

    @MainActor func startExerciseSync() {
        // 一组题变了（谁答的、谁翻的、重做、换筛选、库里刷新）→ 平板开着的正是它就推过去
        ExerciseDeck.changed
            .sink { [weak self] ev in
                MainActor.assumeIsolated { self?.exerciseDeckChanged(ev.deck, change: ev.change) }
            }
            .store(in: &exerciseSyncBag)
        // 某个工作区的习题内容变了（导入 / 收藏 / 进出错题本 / 删 / 删书）→ 抽屉分组、平板开着的那组都要重发
        NotificationCenter.default.publisher(for: .exercisesDidChange)
            .receive(on: RunLoop.main)   // 发在 `@Published` 的 didSet 里：跳一拍，别在别人改值的半路上重读
            .sink { [weak self] note in
                MainActor.assumeIsolated { self?.workspaceExercisesChanged(note.object as? WorkspaceManager) }
            }
            .store(in: &exerciseSyncBag)
    }

    /// 被跟随会话所属的工作区（`@MainActor` 实例，按路径从登记表里找）。
    @MainActor var padWorkspace: WorkspaceManager? {
        guard let folder = padSession?.workspaceFolder else { return nil }
        return WorkspaceRegistry.shared.openManager(at: folder)
    }

    // MARK: - 下行

    /// 抽屉的「习题」一段（`exGroups`）：被跟随会话所在工作区的分组，规则同 Mac 侧栏（`ExerciseGroupNode.build`）。
    /// 随 `boards` 一起发（接入 / 换会话 / 换工作区），工作区的习题变了再发。
    func broadcastExerciseGroups() {
        guard server.hasClients else { return }
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.broadcastExerciseGroups() }
            return
        }
        MainActor.assumeIsolated {
            var list: [[String: Any]] = []
            if let ws = padWorkspace {
                let groups = ws.exerciseGroups()
                list = ExerciseGroupNode.flatten(groups).map {
                    ["key": $0.scope.key, "title": $0.title, "count": $0.count, "depth": $0.depth]
                }
            }
            server.broadcast(["type": "exGroups", "list": list])
        }
    }

    @MainActor private func padDeck() -> ExerciseDeck? {
        guard let sub = padExercise, let ws = sub.workspace else { return nil }
        return ExerciseDeck.shared(scope: sub.scope, workspace: ws, reload: false)
    }

    @MainActor private func exerciseDeckChanged(_ d: ExerciseDeck, change: ExerciseDeck.Change) {
        guard server.hasClients, let sub = padExercise, d.scope == sub.scope, d.owner === sub.workspace else { return }
        if change == .index && !exerciseDeckPushScheduled {
            // 只是翻了题：不重发整份（平板翻过来的，回声一条同样的位置也无害）
            server.broadcast(["type": "exIndex", "scope": d.scope.key, "index": d.index])
        } else {
            scheduleExerciseDeckPush()
        }
    }

    @MainActor private func workspaceExercisesChanged(_ ws: WorkspaceManager?) {
        guard server.hasClients, let ws else { return }
        if ws === padWorkspace { broadcastExerciseGroups() }
        guard let sub = padExercise, sub.workspace === ws else { return }
        if let id = sub.scope.documentId, ws.document(id: id) == nil {
            closePadExercises()   // 那本书删了：平板据空的 `exDeck` 关掉习题页
            return
        }
        padDeck()?.reload()   // → `changed(.content)` → 排一次推送
    }

    /// 平板开着的那组没法再开了（工作区关了 / 范围键不认识 / 那本书删了）：发一份空的，平板关掉自己的习题页。
    @MainActor private func closePadExercises() {
        padExercise = nil
        setExerciseImages([:])
        server.broadcast(["type": "exDeck", "scope": "", "title": "", "filter": 0, "index": 0, "done": 0, "right": 0,
                          "list": [[String: Any]]()])
    }

    @MainActor private func scheduleExerciseDeckPush() {
        guard !exerciseDeckPushScheduled else { return }
        exerciseDeckPushScheduled = true
        DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.pushExerciseDeck() } }
    }

    /// 平板开着那一组的全量（`exDeck`）：题目内容 + 该显示的作答（同 Mac 练习页 `ExerciseDeck.answer(for:)`）+ 统计。
    /// 顺手把有出处页的题登记给 `/exercise.png`。
    @MainActor private func pushExerciseDeck() {
        exerciseDeckPushScheduled = false
        guard server.hasClients, let sub = padExercise else { return }
        guard let ws = sub.workspace else { closePadExercises(); return }
        let d = ExerciseDeck.shared(scope: sub.scope, workspace: ws, reload: false)
        var list: [[String: Any]] = []
        list.reserveCapacity(d.items.count)
        var images: [String: ExerciseImageSource] = [:]
        // 同一本书只查一次文件位置与扫描页对齐
        var targets: [String: (path: String, align: ScanAlignTable?)?] = [:]
        func target(_ docId: String) -> (path: String, align: ScanAlignTable?)? {
            if let hit = targets[docId] { return hit }
            let t = ws.openTarget(documentId: docId).map { t in
                (t.path, ws.scanAlign(contentHash: t.hash, pageCount: ws.document(id: docId)?.pageCount ?? 0))
            }
            targets[docId] = t
            return t
        }
        func code(_ c: Bool?) -> Int { c == nil ? 0 : (c! ? 1 : 2) }
        for e in d.items {
            let stat = d.stats[e.id]
            // 填空 / 主观题平板本轮不能作答（`EXERCISE-PLAN.md §11.6`）：只发题干，作答与答案一概不发，平板显示「到 Mac 上作答」
            let choice = e.kind.isChoice
            let a = choice ? d.answer(for: e) : nil
            let hasOriginal = e.documentId != nil && e.page != nil
            var flags = 0
            if e.starred { flags |= 1 }
            if e.wrong { flags |= 2 }
            if e.payload.figure { flags |= 4 }
            if hasOriginal { flags |= 8 }
            if e.answerFromAgent { flags |= 16 }
            var shown = 0
            var lastAt = 0.0
            if let a {
                switch a.earlier {
                case nil: shown = 1
                case .practiced(let at)?: shown = 2; lastAt = (at?.timeIntervalSince1970 ?? 0) * 1000
                case .book?: shown = 3
                }
            }
            list.append([
                "id": e.id, "number": e.number, "page": e.page.map { $0 + 1 } ?? 0, "kind": e.kind.rawValue,
                "flags": flags, "chapter": ExerciseChapter.display(e.chapter), "section": e.section,
                "stem": e.payload.stem,
                "options": e.payload.options.map { ["key": $0.key, "text": $0.text] },
                "answer": choice ? e.payload.answer.joined() : "", "explanation": choice ? e.payload.explanation ?? "" : "",
                "shown": shown, "chosen": a.map { Exercise.answerString($0.chosen) } ?? "", "correct": code(a?.correct),
                "lastAt": lastAt, "tries": stat?.attempts ?? 0, "rights": stat?.correct ?? 0,
                "marked": choice ? stat?.markedAnswer ?? "" : "",
                "markedCorrect": !choice || stat?.markedAnswer == nil ? 0 : code(stat?.markedCorrect),
            ])
            if hasOriginal, let docId = e.documentId, let page = e.page, let t = target(docId) {
                images[e.id] = ExerciseImageSource(path: t.path, page: page, region: e.payload.region, align: t.align?.page(page))
            }
        }
        setExerciseImages(images)
        let s = d.sessionSummary
        server.broadcast(["type": "exDeck", "scope": sub.scope.key, "title": ws.exerciseScopeTitle(sub.scope),
                          "filter": d.filter.rawValue, "index": d.index, "done": s.done, "right": s.correct, "list": list,
                          "noFilter": d.offersUnansweredFilter ? 0 : 1])
    }

    // MARK: - 上行

    /// 平板发来的习题消息（`exOpen` / `exIndex` / `exAct`）。认得就处理并返回 true。
    func handleExerciseMessage(_ obj: [String: Any]) -> Bool {
        let type = obj["type"] as? String
        guard type == "exOpen" || type == "exIndex" || type == "exAct" else { return false }
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in _ = self?.handleExerciseMessage(obj) }
            return true
        }
        MainActor.assumeIsolated {
            switch type {
            case "exOpen": applyExOpen(obj)
            case "exIndex": applyExIndex(obj)
            default: applyExAct(obj)
            }
        }
        return true
    }

    /// 平板现在显示哪一组（空 = 不在习题上）。立刻回一份全量；开不了就回空的，平板据此关掉习题页。
    @MainActor private func applyExOpen(_ obj: [String: Any]) {
        let key = obj["scope"] as? String ?? ""
        guard !key.isEmpty else { padExercise = nil; setExerciseImages([:]); return }
        guard let scope = ExerciseScope(key: key), let ws = padWorkspace,
              scope.documentId.map({ ws.document(id: $0) != nil }) ?? true else {
            closePadExercises()
            return
        }
        padExercise = PadExerciseSub(workspace: ws, scope: scope)
        _ = ExerciseDeck.shared(scope: scope, workspace: ws)   // 同 Mac 标签打开时：取的时候刷一遍
        scheduleExerciseDeckPush()
    }

    /// 平板翻题：那一组的进度挪过去（Mac 开着同一组的标签跟着翻）。
    @MainActor private func applyExIndex(_ obj: [String: Any]) {
        guard let d = padDeck(), obj["scope"] as? String == d.scope.key,
              let i = (obj["index"] as? NSNumber)?.intValue, d.items.indices.contains(i) else { return }
        d.asPad { d.index = i }
    }

    /// 平板的操作（`PROTOCOL.md §4.9` 的 act 表）。做完由 `changed` / `exercisesDidChange` 推回全量。
    @MainActor private func applyExAct(_ obj: [String: Any]) {
        guard let d = padDeck(), let ws = padExercise?.workspace, obj["scope"] as? String == d.scope.key else { return }
        let act = (obj["act"] as? NSNumber)?.intValue ?? -1
        let id = obj["id"] as? String ?? ""
        let num = (obj["num"] as? NSNumber)?.intValue ?? 0
        let e = d.items.first { $0.id == id }
        switch act {
        case 0:   // 交卷
            // 填空 / 主观题平板不能交（本轮只在 Mac 上作答）
            guard e?.kind.isChoice == true, let keys = ExerciseImport.parseAnswer(obj["arg"] as? String ?? ""),
                  !keys.isEmpty else { return }
            d.asPad { _ = d.submit(Set(keys), elapsedMs: max(0, num), id: id) }
        case 1:   // 收藏 / 取消
            guard let e else { return }
            d.setStarred(e, num != 0)
        case 2:   // 移出错题本
            guard let e, e.wrong else { return }
            d.setWrong(e, false)
        case 3:   // 重做这几道，从第 num 题练起
            let ids = (obj["ids"] as? [String] ?? []).filter { i in d.items.contains { $0.id == i } }
            guard !ids.isEmpty else { return }
            d.asPad {
                d.redo(ids)
                d.index = min(max(0, num), max(0, d.items.count - 1))
            }
        case 4:   // 筛选（认 0 / 1 / 4；老平板发来的 2 错题 / 3 收藏已不用，丢掉。平板本轮还没有 4「重做上次做错的」）
            guard let f = ExerciseFilter(rawValue: num) else { return }
            d.asPad { d.setFilter(f) }
        case 5:   // 到 PDF 原页：Mac 打开那篇、跳过去，并把平板锁到那个标签
            guard let e, let tab = AppDelegate.shared?.showExerciseSource(e, in: ws) else { return }
            selectPadDoc(tab.session.id.uuidString)
        default:
            break
        }
    }
}

extension AppDelegate {
    /// 习题的「到 PDF 原页」：🔴 显示文档只走 `showDocument` 一份（开着就切过去，没开就开新标签），
    /// 再跳到题目所在那一页（有题目框就停在框的上沿）。Mac 练习页与平板（`exAct` 5）共用。拿不到 → nil（已响过一声）。
    @discardableResult
    func showExerciseSource(_ e: Exercise, in ws: WorkspaceManager) -> DocTabModel? {
        guard let docId = e.documentId, let page = e.page else { return nil }
        do {
            let (c, tab) = try showDocument(docId, in: ws, activate: true)
            let frac = e.payload.region.map { max(0, $0[1] - 0.02) } ?? 0
            tab.session.jump(page: page, frac: frac, kind: .list, label: L("Exercise"), origin: "exercise")
            c.window?.makeKeyAndOrderFront(nil)
            return tab
        } catch {
            wsLog("[EX] 到原页失败：\(error)")
            NSSound.beep()
            return nil
        }
    }
}
