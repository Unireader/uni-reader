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
    /// 某个工作区的「每组做过几道」变了（`WorkspaceManager.exerciseDone`，记作答时；object = 那个工作区）。
    static let exerciseDoneDidChange = Notification.Name("UniReader.exerciseDoneDidChange")
    /// 记了一次作答（含重复答已做过的题：别的通知都不发，但页面查到的「作答次数」变了；object = 那个工作区）。
    static let exerciseAttemptDidRecord = Notification.Name("UniReader.exerciseAttemptDidRecord")
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
        refreshExerciseDone()
    }

    /// 重算每组做过几道（侧栏「已做 / 共」）。只改 `exerciseDone`，不加 `exerciseRevision`（开着的习题标签不用重读）。
    func refreshExerciseDone() {
        var d = ExerciseDoneSummary()
        for row in (try? store?.exerciseDoneCounts()) ?? [] {
            d.chapters[row.documentId, default: [:]][row.chapter] = ExerciseDoneStat(done: row.done, starred: row.starred)
        }
        if d != exerciseDone { exerciseDone = d }
    }

    /// 别的设备改了习题 / 作答（服务器同步拉下来的行已经写进库）：同下面那条，重算数并通知开着的习题标签。
    func exercisesChangedRemotely() {
        exercisesChanged()
        refreshExerciseDone()
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
            return documentExercises(id, store: store).filter(scope.includes)
        }
        if scope.isLoose {   // 不关联 PDF 的题（§33）：一个分组 / 没分组的 / 全部
            return Exercise.looseOrdered(((try? store.looseExercises()) ?? []).compactMap(Exercise.init(row:)).filter(scope.includes))
        }
        let all = ((try? store.exercises()) ?? []).compactMap(Exercise.init(row:)).filter(scope.includes)
        let order = Dictionary(documents.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })
        let sorted = all.enumerated().sorted { a, b in
            let oa = a.element.documentId.flatMap { order[$0] } ?? Int.max
            let ob = b.element.documentId.flatMap { order[$0] } ?? Int.max
            return oa != ob ? oa < ob : a.offset < b.offset   // 同一篇里保持库里排好的「页 → 先后」
        }.map(\.element)
        // 不关联 PDF 的题排在各本书后面，自己那一段按分组排
        let books = sorted.filter { $0.documentId != nil }
        return books + Exercise.looseOrdered(sorted.filter { $0.documentId == nil })
    }

    /// 现有的习题分组（不关联 PDF 的题的章节路径第一级，§33），按名字排。从题目派生，不单独存——一个分组里没有题了它就不在了。
    var exerciseGroupNames: [String] {
        (exerciseSummary.chapters[ExerciseScope.looseId] ?? [:]).keys.compactMap(\.first)
            .reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    func exercise(id: String) -> Exercise? {
        ((try? store?.exercise(id: id)) ?? nil).flatMap(Exercise.init(row:))
    }

    /// 每道做过的题的作答统计。整张作答表跑 4 条汇总，网页一打开就连着查很多次（408 复习页），
    /// 所以库没被写过就直接用上次的结果（见 `storeChangeKey`）。
    func exerciseAttemptStats() -> [String: ExerciseAttemptStats] {
        guard let store else { return [:] }
        let key = storeChangeKey(store)
        if let key, let c = attemptStatsCache, c.key == key { return c.stats }
        guard let stats = try? store.exerciseAttemptStats() else { return [:] }   // 出错不缓存
        if let key { attemptStatsCache = (key, stats) }
        return stats
    }

    /// 一本书（或一份真题卷）的全部题。逐道解析题目内容很慢（网页每开一页要整本查十几份，采样里占主线程大头），
    /// 所以库没被写过就复用上次解析好的；库一被写就整个作废、按需重读。
    private func documentExercises(_ id: String, store: LibraryStore) -> [Exercise] {
        let key = storeChangeKey(store)
        if let key, let c = documentExercisesCache, c.key == key, let list = c.byDocument[id] { return list }
        guard let rows = try? store.exercises(documentId: id) else { return [] }   // 出错不缓存
        let list = rows.compactMap(Exercise.init(row:))
        if let key {
            var byDocument = documentExercisesCache?.key == key ? documentExercisesCache!.byDocument : [:]
            byDocument[id] = list
            documentExercisesCache = (key, byDocument)
        }
        return list
    }

    /// 判「库从上次到现在写没写过」：不靠通知（题目 / 作答有本机练习 / 同步 / MCP / 书上识别好几个入口，漏一个就是旧数），
    /// 用 SQLite 自己的两个数——这条连接累计改过的行数 + `PRAGMA data_version`（别的连接提交过就变）。
    /// 有写入就变（不管写的是哪张表），宁可多算、不会算旧。读不到 data_version 时返回 nil = 不缓存。
    private func storeChangeKey(_ store: LibraryStore) -> StoreChangeKey? {
        store.withMirrorDB { db in
            guard let v = (try? db.query("PRAGMA data_version", row: { $0.int64(0) }))?.first else { return nil }
            return StoreChangeKey(store: ObjectIdentifier(store), changes: db.totalChanges, dataVersion: v)
        }
    }

    /// 侧栏 / 标签栏上这个范围叫什么。
    func exerciseScopeTitle(_ scope: ExerciseScope) -> String {
        switch scope {
        case .all: return L("All Exercises")
        case .wrong: return L("Mistakes")
        case .starred: return L("Starred")
        case .document(ExerciseScope.looseId): return L("Exercises Without a PDF")
        case .chapter(ExerciseScope.looseId, let path):   // 分组（§33）：分组名；底下的小节 = 分组名 · 小节名
            guard let g = path.first else { return L("Ungrouped Exercises") }
            return path.count == 1 ? g : g + " · " + path[path.count - 1]
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
    ///
    /// `documentId` nil = 不关联 PDF 的题，写进分组 `group`（§33）：章节 = 分组名 + 这道题自己的小节；没有页码和原题框；
    /// 认「同一道」只在这个分组里比（别的分组里题号一样的不是同一道）。
    func importExercises(documentId: String?, group: String = "", _ drafts: [ExerciseDraft], source: String) throws -> [ExerciseWrite] {
        guard let store else { throw NSError(domain: "UniReader", code: 1, userInfo: [NSLocalizedDescriptionKey: "workspace is closed"]) }
        var drafts = drafts
        if documentId == nil {
            for i in drafts.indices {
                drafts[i].page = nil
                drafts[i].autoChapter = []
                drafts[i].payload = drafts[i].payload.detached()
            }
        }
        var byPage: [Int?: [LibExercise]] = [:]
        var nextSeq: [Int?: Int] = [:]
        var rows: [LibExercise] = []
        var out: [ExerciseWrite] = []
        var rejudge: Set<String> = []          // 已有的题、这次答案变了 → 它的作答要重判
        var marks: [String: ExerciseResponse] = [:]    // 书上的作答（id → 作答；空 = 撤掉）
        let now = Date.now
        for d in drafts.sorted(by: { $0.seq < $1.seq }) {
            if byPage[d.page] == nil {
                let existing = try documentId.map { try store.exercises(documentId: $0, page: d.page) }
                    ?? store.looseExercises().filter { ($0.chapter.first ?? "") == group }
                byPage[d.page] = existing
                nextSeq[d.page] = (existing.map(\.seq).max() ?? -1) + 1
            }
            let hit = ExerciseImport.match(d, in: byPage[d.page] ?? [])
            let seq: Int
            if let hit { seq = hit.seq } else { seq = nextSeq[d.page] ?? 0; nextSeq[d.page] = seq + 1 }
            // 章节：Agent 明确给了就用；没给时已有的题沿用原来的（可能是用户手动设的），新题按目录自动定
            var chapter = d.chapter ?? ((hit?.chapter.isEmpty == false) ? hit!.chapter : d.autoChapter)
            if documentId == nil {   // 分组名是章节路径的第一级；Agent 给的是分组里面的小节，已有的题沿用原来的小节
                chapter = Exercise.loosePath(group: group, sub: d.chapter ?? Array((hit?.chapter ?? []).dropFirst()))
            }
            let row = LibExercise(id: hit?.id ?? UUID().uuidString, documentId: documentId, page: d.page, seq: seq,
                                  kind: d.kind.rawValue, number: d.number, section: d.section,
                                  payload: d.payload.data(), starred: hit?.starred ?? false, wrong: hit?.wrong ?? false,
                                  source: source, createdAt: hit?.createdAt ?? now, updatedAt: now, chapter: chapter,
                                  note: hit?.note ?? "",
                                  tags: d.tags.map { ExerciseTag.merged(hit?.tags ?? [], $0) } ?? hit?.tags ?? [],
                                  marks: hit?.marks ?? "")
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
    /// `userMark` 非 nil = 同时改书上的作答（空 = 撤掉）。笔记（`e.note`）、收藏（`e.starred`）变了也一起写——`upsertExercise` 不碰这两样。
    func saveExercise(_ e: Exercise, userMark: ExerciseResponse? = nil) throws {
        guard let store else { return }
        let old = exercise(id: e.id)
        var e = e
        e.updatedAt = .now
        try store.upsertExercise(e.toRow())
        if let old, old.note != e.note { try store.setExerciseNote(id: e.id, e.note, at: e.updatedAt) }
        if let old, old.starred != e.starred { try store.setExerciseStarred(id: e.id, e.starred, at: e.updatedAt) }
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

    // MARK: - 写：不关联 PDF 的题（`EXERCISE-PLAN.md §33`）

    /// 解除几道题与 PDF 的关联：题目、作答、收藏、错题本、笔记、标签都留着，只是不再属于那本书——
    /// 进一个以书名命名的分组（原来的章节接在分组名后面）；页码、原题框去掉（没有 PDF 就没有原题图）。
    /// 已经不关联 PDF 的跳过。返回动了几道。
    @discardableResult
    func detachExercises(ids: [String]) -> Int {
        guard let store else { return 0 }
        var rows: [LibExercise] = []
        for id in ids {
            guard let old = exercise(id: id), let doc = old.documentId else { continue }
            let book = (document(id: doc)?.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            var e = old.detached(group: book.isEmpty ? L("Exercises") : book)
            e.updatedAt = .now
            rows.append(e.toRow())
        }
        guard !rows.isEmpty else { return 0 }
        do { try store.upsertExercises(rows) } catch { lastError = "\(error)"; return 0 }
        exercisesChanged()
        return rows.count
    }

    /// 一本书的题全部解除关联（删这本书之前调：删 PDF 不删题）。
    @discardableResult
    func detachExercises(documentId: String) -> Int {
        detachExercises(ids: exercises(in: .document(documentId)).map(\.id))
    }

    /// 把几道不关联 PDF 的题放进分组 `group`（空 = 拿出分组）：只换章节路径的第一级，里面的小节照旧。
    /// 关联着 PDF 的题跳过（先解除关联）。分组不存在 = 新建（分组就是个名字）。
    func setExerciseGroup(ids: [String], _ group: String) {
        guard let store else { return }
        let g = group.trimmingCharacters(in: .whitespacesAndNewlines)
        var byPath: [[String]: [String]] = [:]
        for id in ids {
            guard let e = exercise(id: id), e.documentId == nil else { continue }
            let path = Exercise.loosePath(group: g, sub: Array(e.chapter.dropFirst()))
            if path != e.chapter { byPath[path, default: []].append(id) }
        }
        guard !byPath.isEmpty else { return }
        do { for (path, list) in byPath { try store.setExerciseChapter(ids: list, path) } } catch { lastError = "\(error)"; return }
        exercisesChanged()
    }

    /// 分组改名（侧栏右键）：这个分组里的题章节路径第一级换成新名字。新名字已有 = 并进那个分组。空名字不改。
    func renameExerciseGroup(_ old: String, to new: String) {
        let n = new.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty, n != old else { return }
        setExerciseGroup(ids: exercises(in: .chapter(ExerciseScope.looseId, [old])).map(\.id), n)
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
    /// 一篇文档里同一篇文章（按文章 id 认）的题都换成这一份正文 / 标题 / 题型（`EXERCISE-PLAN.md §32`）：
    /// 每道题各带一份，Agent 改了正文、或重导时只带了其中几道，其余的不能还是旧的。内容一样的不写。
    /// `documentId` nil = 不关联 PDF 的题，只换分组 `group` 里的（文章按「分组 + 文章 id」认，§33）。
    func syncPassages(documentId: String?, group: String = "", _ passages: [ExercisePassage]) throws {
        guard let store, !passages.isEmpty else { return }
        let want = Dictionary(passages.map { ($0.id, $0) }, uniquingKeysWith: { _, b in b })
        var rows: [LibExercise] = []
        let pool = documentId.map { exercises(in: .document($0)) }
            ?? exercises(in: .chapter(ExerciseScope.looseId, group.isEmpty ? [] : [group]))
        for var e in pool {
            guard let old = e.payload.passage, let p = want[old.id], p != old else { continue }
            e.payload.passage = p
            if p.kind != .cloze { e.payload.blank = nil }
            e.updatedAt = .now
            rows.append(e.toRow())
        }
        guard !rows.isEmpty else { return }
        try store.upsertExercises(rows)
        exercisesChanged()
    }

    /// 题目上的高亮（练习页判完后划的，`EXERCISE-PLAN.md §32`）：整组替换，空 = 全部去掉。
    func setExerciseMarks(id: String, _ marks: [ExerciseMark]) {
        let list = ExerciseMark.clean(marks)
        guard let e = exercise(id: id), e.marks != list else { return }
        do { try store?.setExerciseMarks(id: id, ExerciseMark.encode(list)) } catch { lastError = "\(error)"; return }
        exercisesChanged()
    }

    func setExerciseNote(id: String, _ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let e = exercise(id: id), e.note != t else { return }
        do { try store?.setExerciseNote(id: id, t) } catch { lastError = "\(error)"; return }
        exercisesChanged()
    }

    /// 原题区域（`payload.region`，练习页 / 列表「设置原题区域…」，`EXERCISE-PLAN.md §25`）：题目在那一页上的框，
    /// 归一化 `[x, y, w, h]`、左上原点；nil = 看原题时显示整页。跨页的题 `next` 是后面每页一个框（§26），
    /// 没有起始页的框时一并去掉。不合格的框（越界 / 零宽高 / 越过最后一页）不写。
    /// `skip` = 不进原题图的页（偏移，0 = 起始页，§30）；不合格（越界 / 全跳过）就当没给。
    /// 走 `saveExercise`（整行写回、打 `updated_at`，同步按它取新），答案没变不会重判作答。
    func setExerciseRegion(id: String, _ region: [Double]?, next: [[Double]]? = nil, skip: [Int]? = nil) {
        guard var e = exercise(id: id) else { return }
        let r = region.map(ExerciseRegion.rounded)
        if let r, !ExerciseRegion.isValid(r) { return }
        let n = r == nil ? nil : next.map { $0.map(ExerciseRegion.rounded) }.flatMap { $0.isEmpty ? nil : $0 }
        if let n {
            guard n.count <= ExerciseRegion.maxNextPages, n.allSatisfy(ExerciseRegion.isValid) else { return }
            if let p = e.page, let c = e.documentId.flatMap({ document(id: $0)?.pageCount }), c > 0,
               ExerciseRegion.runsPastEnd(page: p, next: n, pageCount: c) { return }
        }
        let k = r == nil ? nil : ExerciseRegion.cleanSkip(skip, pages: 1 + (n?.count ?? 0))
        guard e.payload.region != r || e.payload.nextRegions != n || e.payload.skipPages != k else { return }
        e.payload.region = r
        e.payload.nextRegions = n
        e.payload.skipPages = k
        do { try saveExercise(e) } catch { lastError = "\(error)" }
    }

    /// 题目标签（v24）：整组替换。规整后和库里一样就不写。
    func setExerciseTags(id: String, _ tags: [String]) { setExerciseTags(ids: [id], tags, mode: .replace) }

    enum TagMode { case replace, add, remove }

    /// 几道题一起改标签（列表右键 / 练习页）：`replace` 整组换成 `tags`，`add` 并进去，`remove` 去掉这几个（不分大小写）。
    func setExerciseTags(ids: [String], _ tags: [String], mode: TagMode) {
        guard let store else { return }
        let new = ExerciseTag.clean(tags)
        var changes: [(id: String, tags: [String])] = []
        for id in ids {
            guard let e = exercise(id: id) else { continue }
            let next: [String]
            switch mode {
            case .replace: next = new
            case .add: next = ExerciseTag.merged(e.tags, new)
            case .remove:
                let drop = Set(new.map { $0.lowercased() })
                next = e.tags.filter { !drop.contains($0.lowercased()) }
            }
            if next != e.tags { changes.append((id, next)) }
        }
        guard !changes.isEmpty else { return }
        do { try store.setExercisesTags(changes) } catch { lastError = "\(error)"; return }
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
        if correct == false { exercisesChanged() } else { refreshExerciseDone() }
        NotificationCenter.default.post(name: .exerciseAttemptDidRecord, object: self)
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

    /// 这几道题里在 App 里做过的那几道（清除做题记录的菜单据它决定显不显示、显示几道）。
    func exercisesWithAttempts(ids: [String]) -> [String] {
        (try? store?.exercisesWithAttempts(ids: ids)) ?? []
    }

    /// 清除几道题的做题记录（`EXERCISE-PLAN.md §31`）：**先归档，成功了才删**（红线 11）。只清在 App 里做的作答，
    /// 书上的作答留着；错题本按剩下的记录重算。没做过的题跳过。返回清了几道（归档失败 → nil，一道都没动）。
    @discardableResult
    func clearExerciseAttempts(ids: [String]) -> Int? {
        guard let store else { return nil }
        let todo = exercisesWithAttempts(ids: ids)
        guard !todo.isEmpty else { return 0 }
        let first = exercise(id: todo[0])
        let docTitle = first?.documentId.flatMap { document(id: $0)?.title } ?? ""
        let title = todo.count == 1
            ? String(format: L("Practice Record · Exercise %@"),
                     first?.number.isEmpty == false ? first!.number : String(todo[0].prefix(8)))
            : String(format: L("Practice Records · %d exercises"), todo.count)
        guard Trash.archiveExerciseAttempts(store: store, ids: todo, documentTitle: docTitle, title: title) != nil else {
            lastError = String(format: L("Could not archive “%@”, so nothing was deleted."), title)
            return nil
        }
        do { try store.clearExerciseAttempts(ids: todo) } catch {
            lastError = error.localizedDescription
            return nil
        }
        exercisesChanged()
        return todo.count
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

/// `WorkspaceManager` 习题缓存的键：哪个库连接 + 它累计改过的行数 + `PRAGMA data_version`。
struct StoreChangeKey: Equatable {
    let store: ObjectIdentifier
    let changes: Int
    let dataVersion: Int64
}
