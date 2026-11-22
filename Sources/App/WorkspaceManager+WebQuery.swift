import Foundation

/// 网页里 `unireader.query(name, args)` 的查询部分（`docs/WEB-DOC-PLAN.md §5.1`）：**只读**，查工作区里的习题库与做题状态。
/// 走 `webKV` 的 `query` 操作（`key` = 查询名，`value` = 参数 JSON），三条传输（内嵌 / 本机浏览器 / 安卓）都不用改。
/// 🔴 返回的字段名 / 形状是跨端契约：安卓 `WebQuery.kt` 逐项照这里写；改了要两边一起改。
/// 页码对外 1 起。出错抛 `WebKVError`（文字给页面看，用英文）。
extension WorkspaceManager {

    static let webQueryMaxLimit = 200
    static let webQueryDefaultLimit = 50

    func webQuery(name: String, argsJSON: String?) throws -> String {
        var args: [String: Any] = [:]
        if let s = argsJSON, !s.isEmpty {
            guard let o = (try? JSONSerialization.jsonObject(with: Data(s.utf8))) as? [String: Any] else {
                throw WebKVError("The query arguments must be a JSON object.")
            }
            args = o
        }
        let out: Any
        switch name {
        case "documents": out = webQueryDocuments()
        case "exercises": out = try webQueryExercises(args)
        case "exercise": out = try webQueryExercise(args)
        case "exerciseStats": out = try webQueryStats(args)
        case "attempts": out = try webQueryAttempts(args)
        default: throw WebKVError("Unknown query: \(name)")
        }
        return String(decoding: try JSONSerialization.data(withJSONObject: out), as: UTF8.self)
    }

    /// 参数 `document` = 文档 id、id 的前 8 位或准确的标题。
    private func webQueryDocument(_ ref: String) throws -> LibDocument {
        let r = ref.trimmingCharacters(in: .whitespacesAndNewlines)
        if let d = documents.first(where: { $0.id.caseInsensitiveCompare(r) == .orderedSame }) { return d }
        let byPrefix = r.count >= 8 ? documents.filter { $0.id.lowercased().hasPrefix(r.lowercased()) } : []
        if byPrefix.count == 1 { return byPrefix[0] }
        let byTitle = documents.filter { $0.title == r }
        if byTitle.count == 1 { return byTitle[0] }
        throw WebKVError(byTitle.count > 1 || byPrefix.count > 1 ? "More than one document matches: \(r)" : "No such document: \(r)")
    }

    private func webQueryInt(_ a: [String: Any], _ k: String, _ def: Int, min lo: Int, max hi: Int) -> Int {
        guard let n = (a[k] as? NSNumber)?.intValue else { return def }
        return Swift.min(hi, Swift.max(lo, n))
    }

    private func webQueryDocuments() -> [String: Any] {
        let all = (try? store?.exercises()) ?? []
        var count: [String: Int] = [:]
        for e in all { if let d = e.documentId { count[d, default: 0] += 1 } }
        let loose = all.filter { $0.documentId == nil }.count
        return ["documents": documents.map { ["id": $0.id, "title": $0.title, "page_count": $0.pageCount,
                                              "exercise_count": count[$0.id] ?? 0] as [String: Any] },
                "ungrouped_exercise_count": loose, "groups": exerciseGroupNames]
    }

    /// 一道题的样子（`full` = 单题查询：带文章全文）。
    private func webExerciseJSON(_ e: Exercise, stats: ExerciseAttemptStats?, full: Bool) -> [String: Any] {
        var o: [String: Any] = [
            "id": e.id, "type": e.kind.wireName, "number": e.number, "section": e.section,
            "stem": e.payload.stem,
            "options": e.payload.options.map { ["key": $0.key, "text": $0.text] },
            "answer": e.kind.isChoice ? e.payload.answer.joined() : (e.referenceText ?? ""),
            "chapter": e.chapterInGroup, "tags": e.tags,
            "starred": e.starred, "in_mistakes": e.wrong,
            "attempts": stats?.attempts ?? 0, "correct": stats?.correct ?? 0, "wrong": stats?.wrong ?? 0,
            "ungraded": stats?.ungraded ?? 0,
            "last_correct": stats?.lastCorrect.map { $0 as Any } ?? NSNull(),
        ]
        if e.kind == .fill { o["blanks"] = e.payload.answer }
        if let d = e.documentId { o["document_id"] = d } else { o["group"] = e.group ?? "" }
        if let p = e.page { o["page"] = PageNo.external(p) }
        if let x = e.payload.explanation { o["explanation"] = x }
        if !e.note.isEmpty { o["note"] = e.note }
        if let p = e.payload.passage {
            var po: [String: Any] = ["id": p.id, "type": p.kind.rawValue]
            if let t = p.title { po["title"] = t }
            if full { po["text"] = p.text }
            o["passage"] = po
            if let b = e.payload.blank { o["blank"] = b }
        }
        return o
    }

    private func webQueryExercises(_ a: [String: Any]) throws -> [String: Any] {
        var scope = ExerciseScope.all
        if let ids = a["ids"] as? [String], !ids.isEmpty {
            let stats = exerciseAttemptStats()
            let found = ids.prefix(Self.webQueryMaxLimit).compactMap { exercise(id: $0) }
            return ["total": found.count, "offset": 0, "groups": exerciseGroupNames,
                    "exercises": found.map { webExerciseJSON($0, stats: stats[$0.id], full: false) }]
        }
        var chapter = (a["chapter"] as? [String]).map(ExerciseChapter.clean)
        if let g = a["group"] as? String {
            let g = g.trimmingCharacters(in: .whitespacesAndNewlines)
            scope = .chapter(ExerciseScope.looseId, g.isEmpty ? [] : [g] + (chapter ?? []))
            chapter = nil
        } else if let d = a["document"] as? String, !d.isEmpty {
            scope = .document(try webQueryDocument(d).id)
        }
        var list = exercises(in: scope)
        switch a["filter"] as? String ?? "all" {
        case "all": break
        case "mistakes": list = list.filter(\.wrong)
        case "starred": list = list.filter(\.starred)
        default: throw WebKVError("filter must be all, mistakes or starred.")
        }
        if let chapter { list = list.filter { ExerciseScope.chapterContains(chapter, $0.chapter) } }
        if let t = (a["tag"] as? String)?.trimmingCharacters(in: .whitespaces), !t.isEmpty {
            list = list.filter { ExerciseTag.has($0, t) }
        }
        let stats = exerciseAttemptStats()
        switch a["status"] as? String ?? "any" {   // 做题状态：没做过 / 做过 / 最近一次答对 / 最近一次答错
        case "any": break
        case "new": list = list.filter { (stats[$0.id]?.attempts ?? 0) == 0 }
        case "practiced": list = list.filter { (stats[$0.id]?.attempts ?? 0) > 0 }
        case "last_correct": list = list.filter { stats[$0.id]?.lastCorrect == true }
        case "last_wrong": list = list.filter { stats[$0.id]?.lastCorrect == false }
        default: throw WebKVError("status must be any, new, practiced, last_correct or last_wrong.")
        }
        let offset = webQueryInt(a, "offset", 0, min: 0, max: Int.max)
        let limit = webQueryInt(a, "limit", Self.webQueryDefaultLimit, min: 1, max: Self.webQueryMaxLimit)
        return ["total": list.count, "offset": offset, "groups": exerciseGroupNames,
                "exercises": list.dropFirst(offset).prefix(limit).map { webExerciseJSON($0, stats: stats[$0.id], full: false) }]
    }

    private func webQueryExercise(_ a: [String: Any]) throws -> Any {
        guard let id = a["id"] as? String, !id.isEmpty else { throw WebKVError("An exercise id is required.") }
        guard let e = exercise(id: id) else { return NSNull() }
        return webExerciseJSON(e, stats: exerciseAttemptStats()[e.id], full: true)
    }

    private func webQueryStats(_ a: [String: Any]) throws -> [String: Any] {
        var scope = ExerciseScope.all
        if let g = a["group"] as? String {
            let g = g.trimmingCharacters(in: .whitespacesAndNewlines)
            scope = .chapter(ExerciseScope.looseId, g.isEmpty ? [] : [g])
        } else if let d = a["document"] as? String, !d.isEmpty {
            scope = .document(try webQueryDocument(d).id)
        }
        let list = exercises(in: scope)
        let stats = exerciseAttemptStats()
        var practiced = 0, attempts = 0, correct = 0, wrong = 0, ungraded = 0
        for e in list {
            guard let s = stats[e.id], s.attempts > 0 else { continue }
            practiced += 1; attempts += s.attempts; correct += s.correct; wrong += s.wrong; ungraded += s.ungraded
        }
        return ["total": list.count, "practiced": practiced, "unpracticed": list.count - practiced,
                "mistakes": list.filter(\.wrong).count, "starred": list.filter(\.starred).count,
                "attempts": attempts, "correct": correct, "wrong": wrong, "ungraded": ungraded]
    }

    private func webQueryAttempts(_ a: [String: Any]) throws -> [String: Any] {
        let offset = webQueryInt(a, "offset", 0, min: 0, max: Int.max)
        let limit = webQueryInt(a, "limit", Self.webQueryDefaultLimit, min: 1, max: Self.webQueryMaxLimit)
        let ungraded = a["ungraded"] as? Bool ?? false
        var ids: [String]?
        if let one = a["exerciseId"] as? String, !one.isEmpty { ids = [one] }
        else if let many = a["exerciseIds"] as? [String] { ids = many }
        var docId: String?
        if ids == nil, let d = a["document"] as? String, !d.isEmpty { docId = try webQueryDocument(d).id }
        let page = exerciseAttemptPage(exerciseIds: ids, documentId: docId, ungradedOnly: ungraded, offset: offset, limit: limit)
        let list: [[String: Any]] = page.rows.map { r in
            var o: [String: Any] = [
                "id": r.id, "exercise_id": r.exerciseId, "answer": r.answer,
                "source": r.source == LibExerciseAttempt.markSource ? "book" : "practice",
                "created_at": ISO.string(r.createdAt), "elapsed_ms": r.elapsedMs,
                "correct": r.correct.map { $0 as Any } ?? NSNull(),
            ]
            if !r.feedback.isEmpty { o["feedback"] = r.feedback }
            return o
        }
        return ["total": page.total, "offset": offset, "attempts": list]
    }
}
