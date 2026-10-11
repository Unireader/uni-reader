import Foundation

/// 一个习题标签练的那一组题 + 练到哪了（`EXERCISE-PLAN.md §4.2`）。练习 / 列表两个视图共用这一份。
///
/// 题目集合是**快照**：打开时按范围取一次，之后库里变了（Agent 补答案、错题本里移出一道）只**就地刷新**
/// 已在里面的题、把新进范围的题接在末尾——不会有题在练着练着突然从眼前消失。
///
/// 切标签时窗格会把整个视图拆掉、切回来再建（同 Markdown 笔记），练到第几题、这一轮答过什么不能跟着丢，
/// 所以这份按「工作区 + 范围」存在 `shared` 里，App 活着期间一直在。
@MainActor
final class ExerciseDeck {
    enum Mode: Int { case practice = 0, list = 1 }

    /// 一道题显示的作答：选了什么、对不对（nil = 题目没答案、没法判）。
    /// 这一轮答的优先；这一轮没答、以前做过的，显示以前那次（用户 2026-10-11 定：做过的题直接显示上次结果）。
    struct Answer: Equatable {
        var chosen: Set<String>
        var correct: Bool?
        /// nil = 这一轮答的；否则是以前的作答从哪来。
        var earlier: Exercise.Earlier? = nil
    }

    let scope: ExerciseScope
    private weak var workspace: WorkspaceManager?
    private(set) var items: [Exercise] = []
    private(set) var stats: [String: ExerciseAttemptStats] = [:]
    var mode: Mode = .practice
    var index = 0
    private(set) var answers: [String: Answer] = [:]
    /// 这一轮点过「再做一次」的题：以前的作答不再显示，等重新答。
    private var redoing: Set<String> = []
    /// 顶上的筛选（全部 / 没做过 / 错题 / 收藏）。换了就按它重取一份快照（`setFilter`）。
    private(set) var filter: ExerciseFilter = .all

    private static var decks: [String: ExerciseDeck] = [:]

    /// 这个工作区、这个范围的那一份（没有就建）。拿到时顺手刷新一遍。
    static func shared(scope: ExerciseScope, workspace: WorkspaceManager) -> ExerciseDeck {
        let key = (workspace.folder?.path ?? "") + "|" + scope.key
        if let d = decks[key], d.workspace === workspace {
            d.reload()
            return d
        }
        let d = ExerciseDeck(scope: scope, workspace: workspace)
        decks[key] = d
        return d
    }

    private init(scope: ExerciseScope, workspace: WorkspaceManager) {
        self.scope = scope
        self.workspace = workspace
        stats = workspace.exerciseAttemptStats()
        items = workspace.exercises(in: scope).filter(passes)
    }

    var current: Exercise? { items.indices.contains(index) ? items[index] : nil }

    private func passes(_ e: Exercise) -> Bool { filter.includes(e, attempts: stats[e.id]?.attempts ?? 0) }

    /// 换筛选：按新条件重取一份快照，尽量停在原来那道题上。这一轮答过什么不丢。
    func setFilter(_ f: ExerciseFilter) {
        guard f != filter, let ws = workspace else { return }
        filter = f
        let curId = current?.id
        stats = ws.exerciseAttemptStats()
        items = ws.exercises(in: scope).filter(passes)
        index = curId.flatMap { id in items.firstIndex { $0.id == id } } ?? 0
    }

    /// 库里变了：已在快照里的就地换成新内容（被删的去掉），新进范围、过得了筛选的接在末尾。
    /// 移出错题本 / 取消收藏 / 刚做过（「没做过」筛选下）的题这一轮都还留着——不会在眼前突然消失。
    func reload() {
        guard let ws = workspace else { return }
        stats = ws.exerciseAttemptStats()
        let fresh = ws.exercises(in: scope)
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
    }

    /// 这道题要显示的作答（nil = 还没答，等着作答）：这一轮答的，否则以前那次（`Exercise.earlierAnswer`）。
    func answer(for e: Exercise) -> Answer? {
        if let a = answers[e.id] { return a }
        guard !redoing.contains(e.id), let p = e.earlierAnswer(stats[e.id]) else { return nil }
        return Answer(chosen: p.chosen, correct: p.correct, earlier: p.from)
    }

    /// 交卷：判题、记一次作答（答错进错题本由库那边同一个事务做）。
    @discardableResult
    func submit(_ chosen: Set<String>, elapsedMs: Int) -> Answer? {
        guard let e = current, !chosen.isEmpty, let ws = workspace else { return nil }
        let a = Answer(chosen: chosen, correct: e.judge(chosen))
        answers[e.id] = a
        ws.recordExerciseAttempt(id: e.id, chosen: chosen, correct: a.correct, elapsedMs: elapsedMs)
        var s = stats[e.id] ?? ExerciseAttemptStats()
        s.attempts += 1
        if a.correct == true { s.correct += 1 } else if a.correct == false { s.wrong += 1 }
        s.lastCorrect = a.correct
        s.lastAnswer = Exercise.answerString(chosen)
        s.lastAt = .now
        stats[e.id] = s
        return a
    }

    /// 「再做一次」：这道题当作没答过重新来（这一轮的、以前的作答都先不显示），库里的记录不动。
    func retry() {
        guard let e = current else { return }
        redo([e.id])
    }

    /// 批量重做（用户 2026-10-11 要的：列表多选右键 / 顶栏「全部重做」）：同「再做一次」，一次几道。
    /// 只管这一轮（App 开着期间），退出重开后做过的题照旧显示上次结果。
    func redo(_ ids: [String]) {
        for id in ids {
            answers[id] = nil
            redoing.insert(id)
        }
    }

    /// 这一组里有没有正显示着作答的题（「全部重做」能不能点）。
    var hasShownAnswers: Bool { items.contains { answer(for: $0) != nil } }

    func setStarred(_ e: Exercise, _ on: Bool) { workspace?.setExerciseStarred(id: e.id, on) }
    func setWrong(_ e: Exercise, _ on: Bool) { workspace?.setExerciseWrong(id: e.id, on) }

    /// 这一轮做了几道、对几道（顶栏那行字）。
    var sessionSummary: (done: Int, correct: Int) {
        (answers.count, answers.values.filter { $0.correct == true }.count)
    }
}
