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
                       filter: String, chapter: [String]? = nil, offset: Int, limit: Int) throws -> MCPObject {
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
        }
        if let s = e.payload.answerSource { o["answer_source"] = s }
        if let x = e.payload.explanation { o["explanation"] = x }
        if let r = e.payload.region { o["region"] = r }
        return o
    }

    // MARK: - 改 / 删

    /// 按 id（完整或 8 位以上前缀）在工作区里认题。给了工作区就只在它里面找，否则在所有开着的工作区里找。
    private func resolveExercises(_ ids: [String], workspacePath: String?) throws -> (WorkspaceManager, [Exercise]) {
        let candidates: [WorkspaceManager] = (workspacePath?.isEmpty == false)
            ? [try manager(workspacePath: workspacePath)] : WorkspaceRegistry.shared.openManagers
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
            if let v = p.region { i.region = v }
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
                var n = e
                n.kind = d.kind; n.number = d.number; n.section = d.section; n.payload = d.payload
                n.chapter = d.chapter ?? e.chapter
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
            return exercises[a.exerciseId].map { attemptDTO(a, exercise: $0) }
        }
        return ["workspace": ws.name, "total": page.total, "offset": offset, "attempts": list]
    }

    func attemptDTO(_ a: LibExerciseAttempt, exercise e: Exercise) -> MCPObject {
        let r = ExerciseResponse.decode(e.kind, answer: a.answer, ink: a.ink)
        var o: MCPObject = [
            "id": a.id, "exercise_id": e.id, "number": e.number, "type": e.kind.wireName, "stem": e.payload.stem,
            "reference_answer": Self.referenceAnswerText(e),
            "source": a.source == LibExerciseAttempt.markSource ? "book" : "practice",
            "created_at": ISO.string(a.createdAt),
            "answer": e.kind == .fill ? r.blanks.joined(separator: " / ") : a.answer,
            "has_handwriting": !(r.ink?.isEmpty ?? true),
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

    /// 手写作答出图（白底黑字 PNG）。没有手写 → 报错。
    func renderExerciseAnswer(_ id: String, workspacePath: String?, width: Int) throws -> (MCPObject, Data) {
        let (_, found) = try resolveAttempts([id], workspacePath: workspacePath)
        let a = found[0]
        guard let ink = ExerciseInk.decode(a.ink), let png = ExerciseInkRender.png(ink, pixelWidth: width) else {
            throw MCPToolError("this answer has no handwriting; its text is in list_exercise_attempts")
        }
        let h = Int((Double(width) * ink.height / ink.width).rounded(.up))
        return (["attempt_id": a.id, "exercise_id": a.exerciseId, "width": width, "height": h], png)
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
