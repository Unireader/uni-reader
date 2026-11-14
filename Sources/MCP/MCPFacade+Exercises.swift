import Foundation

/// 习题（`EXERCISE-PLAN.md §3`）的 MCP 门面：导入 / 列出 / 改 / 删。
///
/// 习题不进 `DocSession`（阅读区不画它），所以**没有「文档开没开」两条写路径**：一律经
/// `WorkspaceManager+Exercise` 写库，写完它自己通知侧栏和开着的习题标签。
extension MCPFacade {

    /// `update_exercises` 的一条：只有给了的字段才改（nil = 不动）。`answer` / `explanation` 给空串 = 清掉。
    struct ExercisePatch {
        var id: String
        var type: String?
        var number: String?
        var section: String?
        var stem: String?
        var options: [(key: String?, text: String?)]?
        var answer: String?
        var answerSource: String?
        var explanation: String?
        /// 原题框（`[]` = 去掉框，看原题回到整页；`EXERCISE-PLAN.md §25`）。
        var region: [Double]?
        var figure: Bool?
        /// 章节路径（`[]` = 清掉）。
        var chapter: [String]?
        /// 书上的作答（"" = 撤掉）。选择题是选项字母，主观题是转写的文字。
        var userAnswer: String?
        /// 填空题的空（整组替换）。
        var blanks: [(answer: String?, accept: [String])]? = nil
        /// 填空题书上的作答（全空 = 撤掉）。
        var userBlanks: [String]? = nil
        /// 题目笔记（整段替换，"" = 删掉；v22，`EXERCISE-PLAN.md §12`）。用户状态，只在用户要求时写。
        var note: String? = nil
        /// 收藏 / 取消收藏（`EXERCISE-PLAN.md §15`）。用户状态，只在用户要求时改。错题本不开放给 Agent（拍板 ③：只能用户手动移出）。
        var starred: Bool? = nil
        /// 题目标签（v24）：整组替换，`[]` = 清掉。nil = 不动。
        var tags: [String]? = nil
        /// 跨页的题后面几页的框（整组替换，`[]` = 不跨页了；`EXERCISE-PLAN.md §26`）。nil = 不动；去掉 `region` 时一并去掉。
        var nextRegions: [[Double]]? = nil
        /// 不进原题图的页（偏移，整组替换，`[]` = 每页都显示；§30）。nil = 不动（改了 `next_regions` 时只留还在范围里的）。
        var skipPages: [Int]? = nil
    }

    /// `grade_exercise_attempts` 的一条。
    struct ExerciseGrade {
        var attemptId: String
        var correct: Bool
        var feedback: String?
    }

    // MARK: - 导入

    /// 一批题写进一篇文档。`items[i]` 是第 i 道题：已校验好的 draft（页码已换成 0 起），或退回的原因。
    func importExercises(_ t: WriteTarget, items: [Result<ExerciseDraft, ExerciseImport.Rejected>],
                         client: String) throws -> MCPObject {
        var drafts: [ExerciseDraft] = []
        var owner: [Int] = []          // drafts[k] 来自第几道输入
        for (i, r) in items.enumerated() { if case .success(let d) = r { drafts.append(d); owner.append(i) } }
        let writes = drafts.isEmpty ? [] : try t.ws.importExercises(documentId: t.id, drafts, source: client)
        var results: [MCPObject] = items.enumerated().map { i, r in
            var o: MCPObject = ["index": i]
            if case .failure(let why) = r { o["status"] = "rejected"; o["reason"] = why.reason }
            return o
        }
        for (k, w) in writes.enumerated() {
            results[owner[k]]["id"] = w.id
            results[owner[k]]["status"] = w.created ? "created" : "updated"
            let d = drafts[k]
            if !d.number.isEmpty { results[owner[k]]["number"] = d.number }
            if let p = d.page { results[owner[k]]["page"] = PageNo.external(p) }
        }
        return ["document_id": t.id, "title": t.title,
                "created": writes.filter(\.created).count, "updated": writes.filter { !$0.created }.count,
                "rejected": items.count - drafts.count, "results": results]
    }

    // MARK: - 列出

    /// 列出习题。`allDocuments` = 整个工作区（此时 `documentId` 只用来找工作区）。`pages` 只在单篇时有意义。
    func listExercises(documentId: String?, workspacePath: String?, allDocuments: Bool, pages: String?,
                       filter: String, chapter: [String]? = nil, tag: String? = nil, exerciseIds: [String]? = nil,
                       offset: Int, limit: Int) throws -> MCPObject {
        // 按 id 取那几道（Agent 面板里引用了某一道题，`ACP-AGENT-PLAN.md §15`）：别的筛选一概不看
        if let ids = exerciseIds, !ids.isEmpty {
            let (w, found) = try resolveExercises(ids, workspacePath: workspacePath)
            let stats = w.exerciseAttemptStats()
            let slice = found.dropFirst(offset).prefix(limit)
            return ["workspace": w.name, "total": found.count, "offset": offset,
                    "exercises": slice.map { exerciseDTO(w, $0, stats: stats[$0.id]) }]
        }
        let ws: WorkspaceManager
        var scope: ExerciseScope
        var title = ""
        if allDocuments {
            ws = try manager(workspacePath: workspacePath)
            scope = .all
        } else {
            let t = try writeTarget(documentId: documentId, workspacePath: workspacePath)
            ws = t.ws
            scope = .document(t.id)
            title = t.title
        }
        var list = ws.exercises(in: scope)
        switch filter {
        case "mistakes": list = list.filter(\.wrong)
        case "starred": list = list.filter(\.starred)
        default: break
        }
        if let chapter {
            let path = ExerciseChapter.clean(chapter)
            list = list.filter { ExerciseScope.chapterContains(path, $0.chapter) }
        }
        if let tag, !tag.trimmingCharacters(in: .whitespaces).isEmpty {
            list = list.filter { ExerciseTag.has($0, tag.trimmingCharacters(in: .whitespaces)) }
        }
        if let pages, !allDocuments, case .document(let id) = scope {
            let count = ws.document(id: id)?.pageCount ?? 0
            let want = Set(try PageNo.parse(pages, pageCount: max(count, 1), limit: max(count, 1)))
            list = list.filter { $0.page.map(want.contains) ?? false }
        }
        let stats = ws.exerciseAttemptStats()
        let total = list.count
        let slice = list.dropFirst(offset).prefix(limit)
        var o: MCPObject = ["workspace": ws.name, "total": total, "offset": offset,
                            "exercises": slice.map { exerciseDTO(ws, $0, stats: stats[$0.id]) }]
        if case .document(let id) = scope { o["document_id"] = id; o["title"] = title }
        return o
    }

    func exerciseDTO(_ ws: WorkspaceManager, _ e: Exercise, stats: ExerciseAttemptStats?) -> MCPObject {
        var o: MCPObject = [
            "id": e.id, "type": e.kind.wireName, "number": e.number, "section": e.section,
            "stem": e.payload.stem,
            "options": e.payload.options.map { ["key": $0.key, "text": $0.text] as MCPObject },
            "answer": e.kind.isChoice ? e.payload.answer.joined() : (e.referenceText ?? ""),
            "has_figure": e.payload.figure,
            "starred": e.starred, "in_mistakes": e.wrong,
            "attempts": stats?.attempts ?? 0, "correct": stats?.correct ?? 0, "ungraded": stats?.ungraded ?? 0,
            "chapter": e.chapter,
        ]
        if e.kind == .fill {
            o["blanks"] = ExerciseImport.blankInputs(of: e).map { ["answer": $0.answer ?? "", "accept": $0.accept] as MCPObject }
        }
        if let m = stats?.markedAnswer {
            if e.kind == .fill { o["user_blanks"] = ExerciseResponse.decode(.fill, answer: m).blanks } else { o["user_answer"] = m }
            if let c = stats?.markedCorrect { o["user_answer_correct"] = c }
        }
        if let d = e.documentId { o["document_id"] = d }
        if let p = e.page {
            o["page"] = PageNo.external(p)
            o["link"] = link(ws, doc: e.documentId, page: PageNo.external(p))
            if let q = e.lastPage, q > p { o["last_page"] = PageNo.external(q) }
        }
        o["exercise_link"] = link(ws, exercise: e.id)
        if let s = e.payload.answerSource { o["answer_source"] = s }
        if let x = e.payload.explanation { o["explanation"] = x }
        if let r = e.payload.region {
            o["region"] = r
            if let n = e.payload.nextRegions { o["next_regions"] = n }
            if let k = e.payload.skipPages { o["skip_pages"] = k }
        }
        if !e.note.isEmpty { o["note"] = e.note }
        o["tags"] = e.tags
        return o
    }

    // MARK: - 用户在练习页上看到的（`get_current_view` / `open_exercises`，`EXERCISE-PLAN.md §27`）

    /// 习题标签此刻的样子：哪一组、练习还是列表、筛选、第几题，当前这道题（同 `list_exercises` 一道题的样子）
    /// 加上屏幕上显示的作答（`on_screen`，带 `attempt_id` 好直接批改），列表里选中了哪几道。
    func exerciseTabState(_ ws: WorkspaceManager, scope: ExerciseScope) -> MCPObject {
        let d = ExerciseDeck.shared(scope: scope, workspace: ws, reload: false)
        let s = d.sessionSummary
        var o: MCPObject = [
            "group": ws.exerciseScopeTitle(scope), "scope": Self.scopeDTO(scope),
            "view": d.mode == .list ? "list" : "practice", "filter": Self.filterName(d.filter),
            "count": d.items.count, "position": d.items.isEmpty ? 0 : d.index + 1,
            "done_this_round": s.done, "right_this_round": s.correct,
        ]
        if let t = d.tagFilter { o["tag"] = t }
        if let e = d.current {
            var c = exerciseDTO(ws, e, stats: d.stats[e.id])
            c["on_screen"] = Self.onScreen(d, e)
            o["current"] = c
        }
        if d.mode == .list { o["selected_ids"] = d.selectedIds }
        return o
    }

    /// 这道题屏幕上显示的作答：这一轮答的，或以前那次（同练习页）；还没交的草稿另外给。
    private static func onScreen(_ d: ExerciseDeck, _ e: Exercise) -> MCPObject {
        var o: MCPObject = ["answered": false]
        if let a = d.answer(for: e) {
            o["answered"] = true
            switch e.kind {
            case .single, .multiple: o["answer"] = Exercise.answerString(a.chosen)
            case .fill: o["blanks"] = a.response.blanks
            case .subjective: o["answer"] = a.response.text
            }
            if let c = a.correct { o["correct"] = c }
            switch a.earlier {
            case nil: o["from"] = "this_round"
            case .practiced?: o["from"] = "earlier_practice"
            case .book?: o["from"] = "book"
            }
            if let id = a.attemptId { o["attempt_id"] = id }
            if !a.judgedBy.isEmpty { o["judged_by"] = a.judgedBy }
        } else if let r = d.drafts[e.id] {
            switch e.kind {
            case .fill where r.blanks.contains(where: { !$0.isEmpty }): o["draft_blanks"] = r.blanks
            case .subjective where !r.text.isEmpty: o["draft"] = r.text
            default: break
            }
        }
        return o
    }

    static func filterName(_ f: ExerciseFilter) -> String {
        switch f {
        case .all: return "all"
        case .unanswered: return "not_done"
        case .lastWrong: return "last_wrong"
        }
    }

    static func scopeDTO(_ scope: ExerciseScope) -> MCPObject {
        var o: MCPObject = [:]
        switch scope {
        case .all, .document, .chapter: o["list"] = "all"
        case .wrong, .wrongDocument, .wrongChapter: o["list"] = "mistakes"
        case .starred, .starredDocument, .starredChapter: o["list"] = "starred"
        }
        if let d = scope.documentId { o["document_id"] = d }
        switch scope {
        case .chapter(_, let p), .wrongChapter(_, let p), .starredChapter(_, let p): o["chapter"] = p
        default: break
        }
        return o
    }

    /// `open_exercises`：哪一组（书 / 章 / 错题本 / 收藏，`list` + `documentId` + `chapter`）、停在哪一道、练习还是列表、筛选。
    /// 只给 `exerciseId` = 那道题所在的那本书。给的题不在那一组里 → 报错，不悄悄换一组。
    func openExercises(exerciseId: String?, documentId: String?, chapter: [String]?, list: String,
                       view: String?, filter: String?, tag: String?, workspacePath: String?, activate: Bool) throws -> MCPObject {
        var ws: WorkspaceManager
        var target: Exercise?
        if let id = exerciseId, !id.isEmpty {
            let (w, found) = try resolveExercises([id], workspacePath: workspacePath)
            ws = w
            target = found.first
        } else if let documentId, !documentId.isEmpty {
            ws = try writeTarget(documentId: documentId, workspacePath: workspacePath).ws
        } else {
            ws = try manager(workspacePath: workspacePath)
        }
        // 书：给了用给的；没给时，按书分的组（全部 / 某一章）跟着那道题走，错题本 / 收藏整本不限
        var doc = documentId.flatMap { $0.isEmpty ? nil : $0 }
        if doc == nil, list == "all" || chapter != nil { doc = target?.documentId }
        if let d = doc, ws.document(id: d) == nil {
            throw MCPToolError("document '\(d)' is not in workspace \(ws.name); call list_documents")
        }
        if chapter != nil, doc == nil { throw MCPInvalidParams("chapter needs document_id (or exercise_id of a question in that book)") }
        let path = chapter.map(ExerciseChapter.clean)
        let scope: ExerciseScope
        switch (list, doc, path) {
        case ("mistakes", nil, _): scope = .wrong
        case ("mistakes", let d?, nil): scope = .wrongDocument(d)
        case ("mistakes", let d?, let p?): scope = .wrongChapter(d, p)
        case ("starred", nil, _): scope = .starred
        case ("starred", let d?, nil): scope = .starredDocument(d)
        case ("starred", let d?, let p?): scope = .starredChapter(d, p)
        case (_, nil, _): scope = .all
        case (_, let d?, nil): scope = .document(d)
        case (_, let d?, let p?): scope = .chapter(d, p)
        }
        let title = ws.exerciseScopeTitle(scope)
        if let e = target, !scope.includes(e) {
            throw MCPToolError("exercise \(e.id.prefix(8)) is not in “\(title)”; leave list and chapter out to open it in its own book")
        }
        if target == nil, ws.exercises(in: scope).isEmpty {
            throw MCPToolError("“\(title)” has no exercises; call list_exercises")
        }
        let f: ExerciseFilter?
        switch filter {
        case nil: f = nil
        case "all"?: f = .all
        case "not_done"?:
            guard !scope.isMistakes else { throw MCPInvalidParams("filter not_done is not offered in the mistakes (every question there was done)") }
            f = .unanswered
        case "last_wrong"?: f = .lastWrong
        default: throw MCPInvalidParams("filter must be all, not_done or last_wrong")
        }
        let mode: ExerciseDeck.Mode? = view == "list" ? .list : view == "practice" ? .practice : (target != nil ? .practice : nil)
        guard let app = AppDelegate.shared else { throw MCPToolError("UniReader is still starting up") }
        let (c, tab, _) = try app.showExercises(scope, at: target?.id, mode: mode, filter: f, tag: tag, in: ws, activate: activate)
        var o = exerciseTabState(ws, scope: scope)
        o["window_id"] = c.windowId.uuidString
        o["session_id"] = tab.id.uuidString
        return o
    }

    /// `render_exercise`：这道题的原题图要渲哪几段（同练习页「原题」：有框按框、跨页的拼起来、没框整页）。
    func exerciseImageSource(_ id: String, workspacePath: String?) throws -> (MCPObject, ExerciseImageSource) {
        let (ws, found) = try resolveExercises([id], workspacePath: workspacePath)
        guard let e = found.first else { throw MCPToolError("exercise not found: \(id)") }
        guard e.documentId != nil, e.page != nil else {
            throw MCPToolError("exercise \(e.id.prefix(8)) has no source page in a PDF")
        }
        guard let src = ExerciseOriginal.source(for: e, workspace: ws) else {
            throw MCPToolError("the PDF of exercise \(e.id.prefix(8)) is not on this Mac")
        }
        let r: MCPObject = ["exercise_id": e.id, "pages": src.slices.map { PageNo.external($0.page) },
                            "cropped": e.payload.region != nil]
        return (r, src)
    }

    // MARK: - 改 / 删

    /// 按 id（完整或 8 位以上前缀）在工作区里认题。给了工作区就只在它里面找，否则在所有开着的工作区里找。
    private func resolveExercises(_ ids: [String], workspacePath: String?) throws -> (WorkspaceManager, [Exercise]) {
        let candidates: [WorkspaceManager] = (workspacePath?.isEmpty == false)
            ? [try manager(workspacePath: workspacePath)] : WorkspaceRegistry.shared.openManagers
        // 给的都是完整 id（平常都是）：按 id 逐道取，别为了认几道题把整个工作区的题全读出来解码一遍
        // （2026-11-10 采样：Agent 一道一道改题时，每次调用都在主线程上读全库）。有一道没取到再走下面的前缀匹配。
        let keys = ids.map { $0.trimmingCharacters(in: .whitespaces).uppercased() }
        if !keys.isEmpty, keys.allSatisfy({ UUID(uuidString: $0) != nil }) {
            for ws in candidates {
                let hits = keys.compactMap { ws.exercise(id: $0) }
                if hits.count == keys.count { return (ws, hits) }
            }
        }
        for ws in candidates {
            let all = ws.exercises(in: .all)
            var hits: [Exercise] = []
            for raw in ids {
                let key = raw.trimmingCharacters(in: .whitespaces).uppercased()
                let found = key.count >= 8 ? all.filter { $0.id.uppercased().hasPrefix(key) } : []
                if found.count == 1 { hits.append(found[0]) }
                else if found.count > 1 { throw MCPInvalidParams("id '\(raw)' is ambiguous; pass the full id") }
            }
            if hits.isEmpty { continue }
            guard hits.count == ids.count else {
                let missing = ids.filter { raw in !hits.contains { $0.id.uppercased().hasPrefix(raw.uppercased()) } }
                throw MCPToolError("exercise(s) not found: \(missing.joined(separator: ", ")); call list_exercises")
            }
            return (ws, hits)
        }
        throw MCPToolError("exercise(s) not found in any open workspace: \(ids.joined(separator: ", ")); call list_exercises")
    }

    /// 改几道题（整批先全部校验，有一道不合格就一道都不改——给模型的是「全对或全不动」）。
    func updateExercises(_ patches: [ExercisePatch], workspacePath: String?) throws -> MCPObject {
        let (ws, found) = try resolveExercises(patches.map(\.id), workspacePath: workspacePath)
        var next: [(exercise: Exercise, userMark: ExerciseResponse?)] = []
        for (p, e) in zip(patches, found) {
            var i = ExerciseImport.input(from: e)
            if let v = p.chapter { i.chapter = v }
            i.userAnswer = p.userAnswer
            i.userBlanks = p.userBlanks
            if let v = p.type {
                i.type = v   // 不认识的题型交给 validate 退回
                // 换了一类题（选择 ↔ 填空 ↔ 主观）：原来的选项 / 空 / 答案都不适用了，没另给的就丢掉。
                // 单选 ↔ 多选是同一类，答案字母照用。
                func family(_ k: ExerciseKind) -> Int { k.isChoice ? 0 : k.rawValue }
                if let k = ExerciseKind(wire: v), family(k) != family(e.kind) {
                    if p.options == nil { i.options = [] }
                    if p.blanks == nil { i.blanks = nil }
                    if p.answer == nil { i.answer = nil }
                    if p.answer == nil, p.blanks == nil { i.answerSource = nil }
                }
            }
            if let v = p.number { i.number = v }
            if let v = p.section { i.section = v }
            if let v = p.stem { i.stem = v }
            if let v = p.options { i.options = v }
            if let v = p.region {
                i.region = v.isEmpty ? nil : v   // [] = 去掉框（同 chapter / tags 的 [] 清空）
                if v.isEmpty, p.nextRegions == nil { i.nextRegions = nil }   // 起始页的框没了，后面几页的也不留
            }
            if let v = p.nextRegions { i.nextRegions = v.isEmpty ? nil : v }
            if let v = p.skipPages {
                i.skipPages = v.isEmpty ? nil : v
            } else if i.region == nil {
                i.skipPages = nil
            } else if p.nextRegions != nil {
                i.skipPages = ExerciseRegion.cleanSkip(i.skipPages, pages: 1 + (i.nextRegions?.count ?? 0))
            }
            if let v = p.figure { i.figure = v }
            if let v = p.explanation { i.explanation = v }
            if let b = p.blanks {
                i.blanks = b
                // 同 answer：换了空的答案就得重新说清来源
                i.answerSource = b.contains { !($0.answer ?? "").trimmingCharacters(in: .whitespaces).isEmpty } ? p.answerSource : nil
            }
            if let a = p.answer {
                i.answer = a
                // 换了答案就得重新说清来源：沿用旧的 `book` 会把 Agent 解出来的答案冒充成书上印的
                i.answerSource = a.trimmingCharacters(in: .whitespaces).isEmpty ? nil : p.answerSource
            } else if p.blanks == nil, let s = p.answerSource {
                i.answerSource = s
            }
            switch ExerciseImport.validate(i, seq: e.seq) {
            case .failure(let why):
                throw MCPInvalidParams("exercise \(e.id.prefix(8)): \(why.reason); nothing was changed")
            case .success(let d):
                if let pg = e.page, let c = e.documentId.flatMap({ ws.document(id: $0)?.pageCount }), c > 0,
                   ExerciseRegion.runsPastEnd(page: pg, next: d.payload.nextRegions, pageCount: c) {
                    throw MCPInvalidParams("exercise \(e.id.prefix(8)): next_regions runs past the last page (the document has \(c) pages); nothing was changed")
                }
                var n = e
                n.kind = d.kind; n.number = d.number; n.section = d.section; n.payload = d.payload
                n.chapter = d.chapter ?? e.chapter
                if let v = p.note { n.note = v.trimmingCharacters(in: .whitespacesAndNewlines) }
                if let v = p.starred { n.starred = v }
                if let v = p.tags { n.tags = ExerciseTag.clean(v) }
                next.append((n, d.userMark))
            }
        }
        for (e, u) in next { try ws.saveExercise(e, userMark: u) }
        let stats = ws.exerciseAttemptStats()
        return ["count": next.count, "exercises": next.map { exerciseDTO(ws, $0.exercise, stats: stats[$0.exercise.id]) }]
    }

    /// 删几道题：先归档进回收站，成功了才删（红线 11）。有一个 id 不对就一道都不删。
    func deleteExercises(_ ids: [String], workspacePath: String?) throws -> MCPObject {
        let (ws, found) = try resolveExercises(ids, workspacePath: workspacePath)
        guard ws.trashExercises(ids: found.map(\.id)) else {
            throw MCPToolError(ws.lastError ?? "could not move the exercises to Recently Deleted; nothing was deleted")
        }
        return ["count": found.count, "ids": found.map(\.id)]
    }

    // MARK: - 作答与批改（`EXERCISE-PLAN.md §11.4`）

    /// 作答一览。`exerciseIds` 给了就只看这几道（`documentId` 只用来找工作区）；否则按 `documentId` 一篇，都不给 = 整个工作区。
    func listExerciseAttempts(exerciseIds: [String]?, documentId: String?, workspacePath: String?, ungradedOnly: Bool,
                              offset: Int, limit: Int) throws -> MCPObject {
        let ws: WorkspaceManager
        var page: (rows: [LibExerciseAttempt], total: Int)
        if let ids = exerciseIds, !ids.isEmpty {
            let (w, found) = try resolveExercises(ids, workspacePath: workspacePath)
            ws = w
            page = w.exerciseAttemptPage(exerciseIds: found.map(\.id), ungradedOnly: ungradedOnly, offset: offset, limit: limit)
        } else if documentId?.isEmpty == false {
            let t = try writeTarget(documentId: documentId, workspacePath: workspacePath)
            ws = t.ws
            page = t.ws.exerciseAttemptPage(documentId: t.id, ungradedOnly: ungradedOnly, offset: offset, limit: limit)
        } else {
            ws = try manager(workspacePath: workspacePath)
            page = ws.exerciseAttemptPage(ungradedOnly: ungradedOnly, offset: offset, limit: limit)
        }
        var exercises: [String: Exercise] = [:]
        let list: [MCPObject] = page.rows.compactMap { a in
            if exercises[a.exerciseId] == nil { exercises[a.exerciseId] = ws.exercise(id: a.exerciseId) }
            return exercises[a.exerciseId].map { attemptDTO(a, exercise: $0, workspace: ws) }
        }
        return ["workspace": ws.name, "total": page.total, "offset": offset, "attempts": list]
    }

    /// `workspace` 给了才看这道题的草稿纸（`EXERCISE-PLAN.md §29`）算不算手写。
    func attemptDTO(_ a: LibExerciseAttempt, exercise e: Exercise, workspace ws: WorkspaceManager? = nil) -> MCPObject {
        let r = ExerciseResponse.decode(e.kind, answer: a.answer, ink: a.ink)
        let scratch = ws.map { ExerciseScratchHost.hasContent(exerciseId: e.id, workspace: $0) } ?? false
        var o: MCPObject = [
            "id": a.id, "exercise_id": e.id, "number": e.number, "type": e.kind.wireName, "stem": e.payload.stem,
            "reference_answer": Self.referenceAnswerText(e),
            "source": a.source == LibExerciseAttempt.markSource ? "book" : "practice",
            "created_at": ISO.string(a.createdAt),
            "answer": e.kind == .fill ? r.blanks.joined(separator: " / ") : a.answer,
            "has_handwriting": scratch || !(r.ink?.isEmpty ?? true),
            "elapsed_ms": a.elapsedMs,
        ]
        if e.kind == .fill {
            o["blanks"] = r.blanks
            o["blank_matches"] = e.blankMatches(r.blanks)
        }
        if let d = e.documentId { o["document_id"] = d }
        if let p = e.page { o["page"] = PageNo.external(p) }
        if let s = e.payload.answerSource, e.hasAnswer { o["reference_source"] = s }
        if let x = e.payload.explanation { o["explanation"] = x }
        if let c = a.correct {
            o["correct"] = c
            switch a.judgedBy {
            case ExerciseJudge.bySelf: o["judged_by"] = "user"
            case ExerciseJudge.byAgent: o["judged_by"] = "agent"
            default: o["judged_by"] = "app"
            }
        }
        if !a.feedback.isEmpty { o["feedback"] = a.feedback }
        return o
    }

    /// 参考答案的一行文字（给 Agent 看）：选择题字母；填空「(1) 2 [also: 2.0]; (2) 4」；主观题正文。没有 → 空串。
    static func referenceAnswerText(_ e: Exercise) -> String {
        switch e.kind {
        case .single, .multiple: return e.payload.answer.joined()
        case .subjective: return e.referenceText ?? ""
        case .fill:
            guard e.hasAnswer else { return "" }
            return (0..<e.blankCount).map { i in
                let forms = e.acceptedForms(blank: i)
                let also = forms.count > 1 ? " [also: \(forms.dropFirst().joined(separator: ", "))]" : ""
                return "(\(i + 1)) \(forms.first ?? "")\(also)"
            }.joined(separator: "; ")
        }
    }

    /// 按 id（完整或 8 位以上前缀）认作答。给了工作区就只在它里面找，否则在所有开着的工作区里找。
    private func resolveAttempts(_ ids: [String], workspacePath: String?) throws -> (WorkspaceManager, [LibExerciseAttempt]) {
        let candidates: [WorkspaceManager] = (workspacePath?.isEmpty == false)
            ? [try manager(workspacePath: workspacePath)] : WorkspaceRegistry.shared.openManagers
        for ws in candidates {
            var hits: [LibExerciseAttempt] = []
            for raw in ids {
                let key = raw.trimmingCharacters(in: .whitespaces)
                guard key.count >= 8 else { continue }
                let found = ws.exerciseAttemptPage(prefix: key, limit: 2).rows
                if found.count == 1 { hits.append(found[0]) }
                else if found.count > 1 { throw MCPInvalidParams("attempt id '\(raw)' is ambiguous; pass the full id") }
            }
            if hits.isEmpty { continue }
            guard hits.count == ids.count else {
                let missing = ids.filter { raw in !hits.contains { $0.id.uppercased().hasPrefix(raw.trimmingCharacters(in: .whitespaces).uppercased()) } }
                throw MCPToolError("answer(s) not found: \(missing.joined(separator: ", ")); call list_exercise_attempts")
            }
            return (ws, hits)
        }
        throw MCPToolError("answer(s) not found in any open workspace: \(ids.joined(separator: ", ")); call list_exercise_attempts")
    }

    /// 手写作答出图：这道题的草稿纸（`EXERCISE-PLAN.md §29`，交卷前后写的都在上面）；没有草稿纸再看作答里的老手写（v21 小画板）。
    /// 都没有 → 报错。
    func renderExerciseAnswer(_ id: String, workspacePath: String?, width: Int) throws -> (MCPObject, Data) {
        let (ws, found) = try resolveAttempts([id], workspacePath: workspacePath)
        let a = found[0]
        if let r = ExerciseScratchHost.png(exerciseId: a.exerciseId, workspace: ws, pixelWidth: width) {
            return (["attempt_id": a.id, "exercise_id": a.exerciseId, "width": r.width, "height": r.height,
                     "from": "scratch_paper"], r.data)
        }
        guard let ink = ExerciseInk.decode(a.ink), let png = ExerciseInkRender.png(ink, pixelWidth: width) else {
            throw MCPToolError("this answer has no handwriting; its text is in list_exercise_attempts")
        }
        let h = Int((Double(width) * ink.height / ink.width).rounded(.up))
        return (["attempt_id": a.id, "exercise_id": a.exerciseId, "width": width, "height": h, "from": "answer"], png)
    }

    /// Agent 批改（整批先全部校验：有一条不对就一条都不写）。后判的为准，判错进错题本；
    /// 没给评语 = 清掉旧评语（新结论配旧评语会自相矛盾）。
    func gradeExerciseAttempts(_ grades: [ExerciseGrade], workspacePath: String?) throws -> MCPObject {
        let (ws, found) = try resolveAttempts(grades.map(\.attemptId), workspacePath: workspacePath)
        var exercises: [String: Exercise] = [:]
        for (g, a) in zip(grades, found) {
            guard let e = exercises[a.exerciseId] ?? ws.exercise(id: a.exerciseId) else {
                throw MCPToolError("the exercise of answer \(g.attemptId) is gone; nothing was saved")
            }
            exercises[e.id] = e
            guard !e.kind.isChoice else {
                throw MCPInvalidParams("answer \(a.id.prefix(8)) is to a \(e.kind.wireName)-choice question, which the app judges by itself; nothing was saved")
            }
        }
        for (g, a) in zip(grades, found) {
            let fb = (g.feedback ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard ws.judgeExerciseAttempt(id: a.id, correct: g.correct, by: ExerciseJudge.byAgent, feedback: fb) else {
                throw MCPToolError(ws.lastError ?? "could not save the grade for \(a.id.prefix(8))")
            }
        }
        let fresh = ws.exerciseAttempts(ids: found.map(\.id))
        let byId = Dictionary(fresh.map { ($0.id, $0) }, uniquingKeysWith: { x, _ in x })
        let out: [MCPObject] = found.compactMap { a in
            guard let r = byId[a.id], let e = exercises[a.exerciseId] else { return nil }
            return attemptDTO(r, exercise: e)
        }
        return ["count": found.count, "attempts": out]
    }
}
