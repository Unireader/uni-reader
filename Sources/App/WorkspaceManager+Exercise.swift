import Foundation
import PDFKit

extension ExerciseChapterNode {
    /// PDF **自带**的目录（不含用户书签——书签名字随手起，当章节会乱）。只读传进来的那份文档，
    /// 调用方负责它在哪条队列上用（`PageBitmap` 文件头的纪律）。
    static func toc(of doc: PDFDocument) -> [ExerciseChapterNode] {
        func conv(_ e: TOCEntry) -> ExerciseChapterNode {
            ExerciseChapterNode(label: e.label, page: e.pageIndex, children: e.children.map(conv))
        }
        return TOCEntry.build(from: doc, align: nil).map(conv)
    }
}

extension Notification.Name {
    /// 某个工作区的习题内容变了（`WorkspaceManager.exerciseRevision` 每次加一都发，object = 那个工作区）。
    static let exercisesDidChange = Notification.Name("UniReader.exercisesDidChange")
}

/// 习题的执行层（`EXERCISE-PLAN.md`）：`exercise` / `exercise_attempt` 两张表的读写 + 侧栏的数。
/// 习题不进 `DocSession`（阅读区不画它），所以只有这一条写路径——MCP 与练习界面都走这里。
extension WorkspaceManager {

    /// 重算侧栏的数。数变了也把 `exerciseRevision` 加一：删文档级联掉的题、回收站放回来的题
    /// 都只经过 `refresh()`，开着的习题标签靠它知道该重读了。
    func refreshExercises() {
        guard let c = try? store?.exerciseCounts() else {
            if exerciseSummary != ExerciseSummary() { exerciseSummary = ExerciseSummary(); exerciseRevision += 1 }
            return
        }
        var chapters: [String: [[String]: ExerciseChapterStat]] = [:]
        for row in (try? store?.exerciseChapterCounts()) ?? [] {
            chapters[row.documentId, default: [:]][row.chapter] = ExerciseChapterStat(count: row.count, firstPage: row.firstPage,
                                                                                      wrong: row.wrong, starred: row.starred)
        }
        let s = ExerciseSummary(total: c.total, wrong: c.wrong, starred: c.starred, byDocument: c.byDocument,
                                chapters: chapters)
        if s != exerciseSummary {
            exerciseSummary = s
            exerciseRevision += 1
        }
    }

    /// 内容变了（导入 / 改 / 删 / 收藏 / 进出错题本）：重算数并通知开着的习题标签。
    private func exercisesChanged() {
        let before = exerciseRevision
        refreshExercises()
        if exerciseRevision == before { exerciseRevision += 1 }
    }

    // MARK: - 读

    /// 一个范围里的题，按「文档 → 页 → 页内先后」排；文档之间按侧栏书库的顺序。
    func exercises(in scope: ExerciseScope) -> [Exercise] {
        guard let store else { return [] }
        if let id = scope.documentId {   // 一本书 / 书里的一章
            return ((try? store.exercises(documentId: id)) ?? []).compactMap(Exercise.init(row:)).filter(scope.includes)
        }
        let all = ((try? store.exercises()) ?? []).compactMap(Exercise.init(row:)).filter(scope.includes)
        let order = Dictionary(documents.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })
        return all.enumerated().sorted { a, b in
            let oa = a.element.documentId.flatMap { order[$0] } ?? Int.max
            let ob = b.element.documentId.flatMap { order[$0] } ?? Int.max
            return oa != ob ? oa < ob : a.offset < b.offset   // 同一篇里保持库里排好的「页 → 先后」
        }.map(\.element)
    }

    func exercise(id: String) -> Exercise? {
        ((try? store?.exercise(id: id)) ?? nil).flatMap(Exercise.init(row:))
    }

    func exerciseAttemptStats() -> [String: ExerciseAttemptStats] {
        (try? store?.exerciseAttemptStats()) ?? [:]
    }

    /// 侧栏 / 标签栏上这个范围叫什么。
    func exerciseScopeTitle(_ scope: ExerciseScope) -> String {
        switch scope {
        case .all: return L("All Exercises")
        case .wrong: return L("Mistakes")
        case .starred: return L("Starred")
        case .document(let id): return document(id: id)?.title ?? L("Exercises")
        case .chapter(let id, let path):
            let book = document(id: id)?.title ?? L("Exercises")
            return book + " · " + (path.last ?? L("No Chapter"))
        case .wrongDocument(let id):
            return L("Mistakes") + " · " + exerciseScopeTitle(.document(id))
        case .wrongChapter(let id, let path):
            return L("Mistakes") + " · " + exerciseScopeTitle(.chapter(id, path))
        case .starredDocument(let id):
            return L("Starred") + " · " + exerciseScopeTitle(.document(id))
        case .starredChapter(let id, let path):
            return L("Starred") + " · " + exerciseScopeTitle(.chapter(id, path))
        }
    }

    // MARK: - 写：导入 / 改（MCP）

    /// 一道题写进去的结果：库里的 id，以及是新建还是更新了已有的那道（去重命中）。
    struct ExerciseWrite {
        var id: String
        var created: Bool
    }

    /// 把一批已校验的题写进一篇文档（`EXERCISE-PLAN.md §2.1`：命中去重键 = 只覆盖内容，收藏 / 错题 / 作答不动）。
    /// 整批一个事务。同一批里重复的题也按同一规则并成一道（后一道覆盖前一道）。
    ///
    /// 页内先后（`seq`）：命中的题保留原来的位置；新题排在这一页已有的题后面，按这一批里给的顺序。
    /// 所以 Agent 把一页分两次导（先前半页、再后半页）顺序也是对的；`draft.seq` 只是这一批里的下标，不直接用。
    func importExercises(documentId: String, _ drafts: [ExerciseDraft], source: String) throws -> [ExerciseWrite] {
        guard let store else { throw NSError(domain: "UniReader", code: 1, userInfo: [NSLocalizedDescriptionKey: "workspace is closed"]) }
        var byPage: [Int?: [LibExercise]] = [:]
        var nextSeq: [Int?: Int] = [:]
        var rows: [LibExercise] = []
        var out: [ExerciseWrite] = []
        var rejudge: Set<String> = []          // 已有的题、这次答案变了 → 它的作答要重判
        var marks: [String: ExerciseResponse] = [:]    // 书上的作答（id → 作答；空 = 撤掉）
        let now = Date.now
        for d in drafts.sorted(by: { $0.seq < $1.seq }) {
            if byPage[d.page] == nil {
                let existing = try store.exercises(documentId: documentId, page: d.page)
                byPage[d.page] = existing
                nextSeq[d.page] = (existing.map(\.seq).max() ?? -1) + 1
            }
            let hit = ExerciseImport.match(d, in: byPage[d.page] ?? [])
            let seq: Int
            if let hit { seq = hit.seq } else { seq = nextSeq[d.page] ?? 0; nextSeq[d.page] = seq + 1 }
            // 章节：Agent 明确给了就用；没给时已有的题沿用原来的（可能是用户手动设的），新题按目录自动定
            let chapter = d.chapter ?? ((hit?.chapter.isEmpty == false) ? hit!.chapter : d.autoChapter)
            let row = LibExercise(id: hit?.id ?? UUID().uuidString, documentId: documentId, page: d.page, seq: seq,
                                  kind: d.kind.rawValue, number: d.number, section: d.section,
                                  payload: d.payload.data(), starred: hit?.starred ?? false, wrong: hit?.wrong ?? false,
                                  source: source, createdAt: hit?.createdAt ?? now, updatedAt: now, chapter: chapter)
            if let hit, let old = try? JSONDecoder().decode(ExercisePayload.self, from: hit.payload),
               old.answer != d.payload.answer || old.accept != d.payload.accept || hit.kind != d.kind.rawValue {
                rejudge.insert(hit.id)
            }
            if let u = d.userMark { marks[row.id] = u }
            if let i = rows.firstIndex(where: { $0.id == row.id }) {
                rows[i] = row   // 同一批里又出现了一次：后一道覆盖前一道
            } else {
                rows.append(row)
                byPage[d.page, default: []].removeAll { $0.id == row.id }
                byPage[d.page, default: []].append(row)
            }
            out.append(ExerciseWrite(id: row.id, created: hit == nil))
        }
        try store.upsertExercises(rows)
        let written = Dictionary(rows.compactMap { r in Exercise(row: r).map { (r.id, $0) } }, uniquingKeysWith: { _, b in b })
        for id in rejudge { if let e = written[id] { try rejudgeAttempts(e) } }
        try writeMarks(marks, exercises: written)
        exercisesChanged()
        return out
    }

    /// 改一道题的内容（`update_exercises`）。收藏 / 错题不经这里改。答案（或题型）变了 → 这道题的作答全部重判。
    /// `userMark` 非 nil = 同时改书上的作答（空 = 撤掉）。笔记（`e.note`）变了也一起写——`upsertExercise` 不碰它。
    func saveExercise(_ e: Exercise, userMark: ExerciseResponse? = nil) throws {
        guard let store else { return }
        let old = exercise(id: e.id)
        var e = e
        e.updatedAt = .now
        try store.upsertExercise(e.toRow())
        if let old, old.note != e.note { try store.setExerciseNote(id: e.id, e.note, at: e.updatedAt) }
        if let old, old.payload.answer != e.payload.answer || old.payload.accept != e.payload.accept || old.kind != e.kind {
            try rejudgeAttempts(e)
        }
        if let u = userMark { try writeMarks([e.id: u], exercises: [e.id: e]) }
        exercisesChanged()
    }

    /// 按这道题现在的答案把它的作答全部重判（答错的进错题本，对的不移出——只能手动出）。
    /// 自己判 / Agent 判过的不动（库那边按 `judged_by` 跳过）。
    private func rejudgeAttempts(_ e: Exercise) throws {
        try store?.rejudgeExerciseAttempts(exerciseId: e.id) { answer in
            e.autoJudge(ExerciseResponse.decode(e.kind, answer: answer))
        }
    }

    /// 书上的作答（`EXERCISE-PLAN.md §2.4`）：每道题至多一条（`source = mark`），重写会替换旧的；空 = 撤掉。
    /// 判错照常进错题本。时间记成写入那一刻（书上作答的真实时间无从知道）。
    /// 填空 / 主观题的书上作答是 Agent 转写的文字：填空能程序判对的判上，其余等自己判或 Agent 判（`grade_exercise_attempts`）。
    private func writeMarks(_ marks: [String: ExerciseResponse], exercises: [String: Exercise]) throws {
        guard let store, !marks.isEmpty else { return }
        var list: [LibExerciseAttempt] = []
        for (id, r) in marks {
            guard let e = exercises[id] else { continue }
            if r.isEmpty(e.kind) { try store.deleteMarkedAttempt(exerciseId: id); continue }
            list.append(LibExerciseAttempt(id: UUID().uuidString, exerciseId: id, answer: r.answerString(e.kind),
                                           correct: e.autoJudge(r), elapsedMs: 0, createdAt: .now,
                                           source: LibExerciseAttempt.markSource))
        }
        try store.recordMarkedAttempts(list)
    }

    /// 改几道题的章节（列表右键「设置章节…」）。
    func setExerciseChapter(ids: [String], _ path: [String]) {
        do { try store?.setExerciseChapter(ids: ids, ExerciseChapter.clean(path)) } catch { lastError = "\(error)"; return }
        exercisesChanged()
    }

    /// 几道题各按自己的页码从目录重新定章节（「按目录自动设置」/ 侧栏「按目录分章节」）。`toc` 是这些题那本书的目录。
    /// 同一章的一起写（一章一个事务）：整本书几百道题时不至于一道一次提交。
    func autoAssignExerciseChapters(ids: [String], toc: [ExerciseChapterNode]) {
        guard let store else { return }
        var byPath: [[String]: [String]] = [:]
        for id in ids {
            guard let e = exercise(id: id), let p = e.page else { continue }
            byPath[ExerciseChapter.path(page: p, in: toc), default: []].append(id)
        }
        do {
            for (path, group) in byPath { try store.setExerciseChapter(ids: group, path) }
        } catch { lastError = "\(error)"; return }
        exercisesChanged()
    }

    /// 移除一本书的章节分级（侧栏右键，`EXERCISE-PLAN.md §14`）：这本书的题全部改成不设章节。
    /// 只动章节这一列（连同 `updated_at`，同步按它取新）——题目、作答、收藏、错题本、笔记都不动。
    /// 之后往这本书导题也不再按目录自动分（`ExerciseChapter.bookIsFlat`）。
    func clearExerciseChapters(documentId: String) {
        let ids = exercises(in: .document(documentId)).filter { !$0.chapter.isEmpty }.map(\.id)
        guard !ids.isEmpty else { return }
        setExerciseChapter(ids: ids, [])
    }

    // MARK: - 写：练习界面

    func setExerciseStarred(id: String, _ on: Bool) {
        try? store?.setExerciseStarred(id: id, on)
        exercisesChanged()
    }

    /// 移出 / 放回错题本（拍板 ③：只有用户手动才会移出）。
    func setExerciseWrong(id: String, _ on: Bool) {
        try? store?.setExerciseWrong(id: id, on)
        exercisesChanged()
    }

    /// 题目笔记（练习页「笔记」那一块，`EXERCISE-PLAN.md §12.1`）：去掉首尾空白，空 = 删掉。和库里一样就不写
    /// （边写边存，停一下就存一次，没改的不该一遍遍刷新开着的标签）。
    func setExerciseNote(id: String, _ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let e = exercise(id: id), e.note != t else { return }
        do { try store?.setExerciseNote(id: id, t) } catch { lastError = "\(error)"; return }
        exercisesChanged()
    }

    /// 记一次作答，返回这一条的 id（写不进去 → nil）。答错时库里同一个事务把题放进错题本；这里再刷新侧栏的数。
    @discardableResult
    func recordExerciseAttempt(id: String, kind: ExerciseKind, response: ExerciseResponse, correct: Bool?,
                               elapsedMs: Int) -> String? {
        let ink = response.ink.flatMap { $0.isEmpty ? nil : $0.data() }
        let a = LibExerciseAttempt(id: UUID().uuidString, exerciseId: id, answer: response.answerString(kind),
                                   correct: correct, elapsedMs: max(0, elapsedMs), createdAt: .now, ink: ink)
        do { try store?.recordExerciseAttempt(a) } catch { lastError = "\(error)"; return nil }
        if correct == false { exercisesChanged() }
        return a.id
    }

    /// 判一次作答（`EXERCISE-PLAN.md §11.3`）：自己判（练习页「答对了 / 答错了」/「改判」）或 Agent 判（MCP
    /// `grade_exercise_attempts`）。后判的为准；判错进错题本。`feedback` nil = 评语不动。
    @discardableResult
    func judgeExerciseAttempt(id: String, correct: Bool, by: String, feedback: String? = nil) -> Bool {
        do {
            guard try store?.judgeExerciseAttempt(id: id, correct: correct, by: by, feedback: feedback) != nil else { return false }
        } catch { lastError = "\(error)"; return false }
        exercisesChanged()
        return true
    }

    func exerciseAttempt(id: String) -> LibExerciseAttempt? {
        (try? store?.exerciseAttempt(id: id)) ?? nil
    }

    func exerciseAttempts(ids: [String]) -> [LibExerciseAttempt] {
        (try? store?.exerciseAttempts(ids: ids)) ?? []
    }

    /// 作答一览（MCP `list_exercise_attempts` / 按 id 前缀认作答），见 `LibraryStore.exerciseAttemptPage`。
    func exerciseAttemptPage(exerciseIds: [String]? = nil, documentId: String? = nil, ungradedOnly: Bool = false,
                             prefix: String? = nil, offset: Int = 0, limit: Int = 50) -> (rows: [LibExerciseAttempt], total: Int) {
        (try? store?.exerciseAttemptPage(exerciseIds: exerciseIds, documentId: documentId, ungradedOnly: ungradedOnly,
                                         prefix: prefix, offset: offset, limit: limit)) ?? ([], 0)
    }

    /// 删几道题：**先归档，成功了才删**（红线 11）。归档失败 → 一道都不删，返回 false。
    @discardableResult
    func trashExercises(ids: [String]) -> Bool {
        guard let store, !ids.isEmpty else { return false }
        let first = exercise(id: ids[0])
        let docTitle = first?.documentId.flatMap { document(id: $0)?.title } ?? ""
        let title = ids.count == 1
            ? String(format: L("Exercise %@"), first?.number.isEmpty == false ? first!.number : String(ids[0].prefix(8)))
            : String(format: L("%d exercises"), ids.count)
        guard Trash.archiveExercises(store: store, ids: ids, documentTitle: docTitle, title: title) != nil else {
            lastError = String(format: L("Could not archive “%@”, so nothing was deleted."), title)
            return false
        }
        try? store.deleteExercises(ids: ids)
        exercisesChanged()
        return true
    }
}
