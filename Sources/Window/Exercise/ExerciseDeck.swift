import Foundation
import Combine

/// 一个习题标签练的那一组题 + 练到哪了（`EXERCISE-PLAN.md §4.2`）。练习 / 列表两个视图共用这一份。
///
/// 题目集合是**快照**：打开时按范围取一次，之后库里变了（Agent 补答案、错题本里移出一道）只**就地刷新**
/// 已在里面的题、把新进范围的题接在末尾——不会有题在练着练着突然从眼前消失。
///
/// 切标签时窗格会把整个视图拆掉、切回来再建（同 Markdown 笔记），练到第几题、这一轮答过什么不能跟着丢，
/// 所以这份按「工作区 + 范围」存在 `shared` 里，App 活着期间一直在。
///
/// 平板（模式2，`EXERCISE-PLAN.md §10.4`）开同一组题用的也是**这一份**：两边开着同一组时作答 / 第几题 / 筛选
/// 天然同步。每次变化发 `changed`——平板同步据它推给平板，平板发来的改动由开着这份的 Mac 标签据它重画。
@MainActor
final class ExerciseDeck {
    enum Mode: Int { case practice = 0, list = 1 }

    /// 谁改的：Mac 本机（练习页 / 列表）还是平板（`AppModel+Exercise`）。
    enum Origin { case mac, pad }
    /// 改了什么：只换了第几题（平板那边只发 `exIndex`），还是别的（重发整份 `exDeck`）。
    enum Change { case index, content }
    /// 这一份变了。Mac 本机的改动，标签视图自己已经画过了（订阅方按 `origin` 挑着处理）。
    static let changed = PassthroughSubject<(deck: ExerciseDeck, origin: Origin, change: Change), Never>()
    private var origin: Origin = .mac

    /// 以平板的名义改：`body` 里的每一次变化都标成 `.pad`。
    func asPad(_ body: () -> Void) {
        origin = .pad
        body()
        origin = .mac
    }

    private func notify(_ c: Change) { Self.changed.send((self, origin, c)) }

    /// 一道题显示的作答：写了什么、对不对（nil = 还没判：题目没答案没法判，或填空 / 主观题等自己判 / Agent 判）。
    /// 这一轮答的优先；这一轮没答、以前做过的，显示以前那次（用户 2026-10-11 定：做过的题直接显示上次结果）。
    struct Answer: Equatable {
        var response: ExerciseResponse
        var correct: Bool?
        /// nil = 这一轮答的；否则是以前的作答从哪来。
        var earlier: Exercise.Earlier? = nil
        /// 库里那一条（自己判 / 改判 / 让 Agent 批改要用它）。
        var attemptId: String? = nil
        /// 谁判的（`ExerciseJudge`）。
        var judgedBy: String = ""

        /// 选择题选中的键。
        var chosen: Set<String> { response.keys }
    }

    let scope: ExerciseScope
    private weak var workspace: WorkspaceManager?
    private(set) var items: [Exercise] = []
    private(set) var stats: [String: ExerciseAttemptStats] = [:]
    var mode: Mode = .practice
    var index = 0 { didSet { if index != oldValue { notify(.index) } } }
    private(set) var answers: [String: Answer] = [:]
    /// 填空 / 主观题还没交的输入（按题记）：翻到别的题再翻回来、切标签再切回来，写了一半的不丢。
    var drafts: [String: ExerciseResponse] = [:]
    /// 这一轮点过「再做一次」的题：以前的作答不再显示，等重新答。
    private var redoing: Set<String> = []
    /// 顶上的两个开关（「只看没做过」/「重做上次做错的」，至多开一个）。换了就按它重取一份快照（`setFilter`）。
    private(set) var filter: ExerciseFilter = .all
    /// 这一组（不管筛选）有哪些题：「重做上次做错的」要按全组数一数有几道（开关能不能点）。
    private var scopeItems: [Exercise] = []

    /// 这一组有没有「只看没做过」：错题本那一支没有（进了错题本的题一定做过，筛出来永远是空的）。
    /// 「重做上次做错的」哪一组都有——错题本里正好用它挑出还没做对的。
    var offersUnansweredFilter: Bool { !scope.isMistakes }

    /// 这一组里上一次做错的有几道（`Exercise.lastResultWrong`；按库里的统计，这一轮刚答的也算进去了）。
    var lastWrongCount: Int { scopeItems.filter { $0.lastResultWrong(stats[$0.id]) }.count }

    private static var decks: [String: ExerciseDeck] = [:]

    /// 这个工作区、这个范围的那一份（没有就建）。拿到时顺手刷新一遍（`reload: false` = 不刷，平板同步每次推送前取它用）。
    static func shared(scope: ExerciseScope, workspace: WorkspaceManager, reload: Bool = true) -> ExerciseDeck {
        let key = (workspace.folder?.path ?? "") + "|" + scope.key
        if let d = decks[key], d.workspace === workspace {
            if reload { d.reload() }
            return d
        }
        let d = ExerciseDeck(scope: scope, workspace: workspace)
        decks[key] = d
        return d
    }

    /// 这一份属于哪个工作区（平板同步按它认「是不是平板开着的那组」）。
    var owner: WorkspaceManager? { workspace }

    private init(scope: ExerciseScope, workspace: WorkspaceManager) {
        self.scope = scope
        self.workspace = workspace
        stats = workspace.exerciseAttemptStats()
        scopeItems = workspace.exercises(in: scope)
        items = scopeItems.filter(passes)
    }

    var current: Exercise? { items.indices.contains(index) ? items[index] : nil }

    private func passes(_ e: Exercise) -> Bool { filter.includes(e, stats: stats[e.id]) }

    /// 换筛选：按新条件重取一份快照，尽量停在原来那道题上。这一轮答过什么不丢。
    /// 换成「重做上次做错的」= 开始重做一轮（`startLastWrongRound`）。
    func setFilter(_ f: ExerciseFilter) {
        guard f != filter, f != .unanswered || offersUnansweredFilter, workspace != nil else { return }
        filter = f
        if f == .lastWrong { startLastWrongRound(); return }
        let curId = current?.id
        resnapshot()
        index = curId.flatMap { id in items.firstIndex { $0.id == id } } ?? 0
        notify(.content)
    }

    /// 重做上次做错的（用户 2026-10-27 要的）：按**此刻**的统计重挑一遍上次做错的题，这一轮在它们上答过的清掉，
    /// 从第一道练起。以前的作答在这个开关下一律不显示（`answer(for:)`），所以挑出来的都等着重新作答。
    /// 这一轮答对的照旧留在眼前（不会突然消失），下次再挑就不在了——「做对一次就不用再做」。
    /// 开着这个开关时点「全部重做」也走这里（再挑一遍），而不是把这一轮答对的也拉回来重做。
    func startLastWrongRound() {
        guard filter == .lastWrong, workspace != nil else { return }
        resnapshot()
        for e in items { answers[e.id] = nil }
        index = 0
        notify(.content)
    }

    /// 按现在的筛选重取统计和快照。
    private func resnapshot() {
        guard let ws = workspace else { return }
        stats = ws.exerciseAttemptStats()
        scopeItems = ws.exercises(in: scope)
        items = scopeItems.filter(passes)
    }

    /// 库里变了：已在快照里的就地换成新内容（被删的去掉），新进范围、过得了筛选的接在末尾。
    /// 移出错题本 / 取消收藏 / 刚做过（「只看没做过」开着）的题这一轮都还留着——不会在眼前突然消失。
    func reload() {
        guard let ws = workspace else { return }
        stats = ws.exerciseAttemptStats()
        let fresh = ws.exercises(in: scope)
        scopeItems = fresh
        let byId = Dictionary(fresh.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let curId = current?.id
        var next: [Exercise] = []
        for e in items {
            if let f = byId[e.id] { next.append(f) }
            else if let f = ws.exercise(id: e.id), scope.documentId == nil || f.documentId == scope.documentId {
                next.append(f)        // 只是出了范围（移出错题本 / 取消收藏 / 改了章节）：这一轮留着
            }                         // 否则是真删了
        }
        let have = Set(next.map(\.id))
        next += fresh.filter { !have.contains($0.id) && passes($0) }
        items = next
        if let curId, let i = items.firstIndex(where: { $0.id == curId }) { index = i }
        index = min(index, max(0, items.count - 1))
        refreshRoundVerdicts(ws)
        notify(.content)
    }

    /// 这一轮答过的题按库里的对错刷一遍：Agent 批改了 / 答案补上重判了，眼前这一轮的结果跟着变。
    private func refreshRoundVerdicts(_ ws: WorkspaceManager) {
        let ids = answers.values.compactMap(\.attemptId)
        guard !ids.isEmpty else { return }
        let rows = Dictionary(ws.exerciseAttempts(ids: ids).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for (k, a) in answers {
            guard let id = a.attemptId, let r = rows[id] else { continue }
            answers[k]?.correct = r.correct
            answers[k]?.judgedBy = r.judgedBy
        }
    }

    /// 这道题要显示的作答（nil = 还没答，等着作答）：这一轮答的，否则以前那次
    /// （选择题 `Exercise.earlierAnswer`，填空 / 主观题 `Exercise.earlierResponse`）。
    func answer(for e: Exercise) -> Answer? {
        if let a = answers[e.id] { return a }
        // 「重做上次做错的」：这一组都是要重做的题，以前那次不显示
        guard !redoing.contains(e.id), filter != .lastWrong else { return nil }
        if e.kind.isChoice {
            guard let p = e.earlierAnswer(stats[e.id]) else { return nil }
            return Answer(response: ExerciseResponse(keys: p.chosen), correct: p.correct, earlier: p.from)
        }
        guard let p = e.earlierResponse(stats[e.id]) else { return nil }
        return Answer(response: p.response, correct: p.correct, earlier: p.from, attemptId: p.attemptId, judgedBy: p.judgedBy)
    }

    /// 交卷（选择题）：见下面那个。平板只交选择题（`exAct` 0）。
    @discardableResult
    func submit(_ chosen: Set<String>, elapsedMs: Int, id: String? = nil) -> Answer? {
        submit(ExerciseResponse(keys: chosen), elapsedMs: elapsedMs, id: id)
    }

    /// 交卷：判题、记一次作答（答错进错题本由库那边同一个事务做）。`id` = 交哪一道（平板交的是它屏幕上那道，
    /// 不一定是这一份此刻的当前题）；nil = 当前题。不在这一组里的题、什么都没写的不收。
    /// 填空能程序判对的直接判（`Exercise.autoJudge`），其余的、主观题记成「还没判」等自己判或 Agent 判。
    @discardableResult
    func submit(_ r: ExerciseResponse, elapsedMs: Int, id: String? = nil) -> Answer? {
        let target = id.map { i in items.first { $0.id == i } } ?? current
        guard let e = target, !r.isEmpty(e.kind), let ws = workspace else { return nil }
        let correct = e.autoJudge(r)
        let aid = ws.recordExerciseAttempt(id: e.id, kind: e.kind, response: r, correct: correct, elapsedMs: elapsedMs)
        let a = Answer(response: r, correct: correct, attemptId: aid)
        answers[e.id] = a
        drafts[e.id] = nil
        var s = stats[e.id] ?? ExerciseAttemptStats()
        s.attempts += 1
        if correct == true { s.correct += 1 } else if correct == false { s.wrong += 1 } else { s.ungraded += 1 }
        s.lastCorrect = correct
        s.lastAnswer = r.answerString(e.kind)
        s.lastAt = .now
        s.lastId = aid
        s.lastPracticedCorrect = correct
        s.lastJudgedBy = ExerciseJudge.byProgram
        stats[e.id] = s
        notify(.content)
        return a
    }

    /// 自己判 / 改判（填空 / 主观题，`EXERCISE-PLAN.md §11.3`）：判的是这道题眼下显示的那次作答，后判的为准，判错进错题本。
    func judge(_ e: Exercise, correct: Bool) {
        guard let a = answer(for: e), let aid = a.attemptId, let ws = workspace else { return }
        guard ws.judgeExerciseAttempt(id: aid, correct: correct, by: ExerciseJudge.bySelf) else { return }
        if answers[e.id] != nil {
            answers[e.id]?.correct = correct
            answers[e.id]?.judgedBy = ExerciseJudge.bySelf
        }
        stats = ws.exerciseAttemptStats()   // 显示的是以前那次时，对错在统计里
        notify(.content)
    }

    /// 「再做一次」：这道题当作没答过重新来（这一轮的、以前的作答都先不显示），库里的记录不动。
    func retry() {
        guard let e = current else { return }
        redo([e.id])
    }

    /// 批量重做（用户 2026-10-11 要的：列表多选右键 / 顶栏「全部重做」）：同「再做一次」，一次几道。
    /// 重练错题 = 在错题本（或它底下某本书 / 某一章）里点「全部重做」。
    /// 只管这一轮（App 开着期间），退出重开后做过的题照旧显示上次结果。
    func redo(_ ids: [String]) {
        for id in ids {
            answers[id] = nil
            drafts[id] = nil
            redoing.insert(id)
        }
        notify(.content)
    }

    /// 这一组里有没有正显示着作答的题（「全部重做」能不能点）。
    var hasShownAnswers: Bool { items.contains { answer(for: $0) != nil } }

    func setStarred(_ e: Exercise, _ on: Bool) { workspace?.setExerciseStarred(id: e.id, on) }
    func setWrong(_ e: Exercise, _ on: Bool) { workspace?.setExerciseWrong(id: e.id, on) }
    /// 题目笔记（练习页「笔记」那一块）：空 = 删掉。
    func setNote(id: String, _ text: String) { workspace?.setExerciseNote(id: id, text) }

    /// 这一轮做了几道、对几道（顶栏那行字）。
    var sessionSummary: (done: Int, correct: Int) {
        (answers.count, answers.values.filter { $0.correct == true }.count)
    }
}
