import Foundation

/// MCP `workspace_stats` 的纯函数部分（`MCP-PLAN.md §38`）：入参校验、出参 schema、把 `StatsStore.Report` 拼成
/// 结构化结果和给人看的摘要。工具本身与主线程那段在 `MCPTools+Stats.swift`。
/// **只依赖 Foundation**（+ `Sources/Store/`、`MCPModels.swift`）——`spike/workspace-stats-test.swift` 直接编它，
/// 逐键对着 `outputSchema` 校验返回：Kimi 严格校验，多一个没声明的键整次调用作废。
enum MCPStats {

    /// 一个 Markdown 笔记源数出来的篇数（App 层从 `WorkspaceManager.noteTrees` 数，见 `MCPFacade.workspaceStats`）。
    struct MarkdownSource {
        var name: String
        var kind: String        // workspace / reference
        var notes: Int
    }

    static let defaultLimit = 20
    static let maxLimit = 200
    /// 不给 from 时的范围：含今天在内的最近 7 天。
    static let defaultDays = 7

    // MARK: - 入参

    /// `sections`：不给 / 空数组 = 全部。
    static func sections(_ raw: Any?) throws -> Set<StatsStore.Section> {
        guard let raw, !(raw is NSNull) else { return Set(StatsStore.Section.allCases) }
        guard let list = raw as? [Any] else { throw MCPInvalidParams("sections must be an array of section names") }
        var out = Set<StatsStore.Section>()
        for v in list {
            guard let s = v as? String, let sec = StatsStore.Section(rawValue: s.trimmingCharacters(in: .whitespaces).lowercased()) else {
                throw MCPInvalidParams("unknown section \(v); use \(StatsStore.Section.allCases.map(\.rawValue).joined(separator: ", "))")
            }
            out.insert(sec)
        }
        return out.isEmpty ? Set(StatsStore.Section.allCases) : out
    }

    /// 按天细分的范围。只给 from → 到今天；只给 to → 往前 7 天；都不给 → 含今天的最近 7 天。
    static func range(from: String?, to: String?, today: String, in tz: TimeZone) throws -> (from: String, to: String) {
        func check(_ s: String, _ name: String) throws -> String {
            let t = s.trimmingCharacters(in: .whitespaces)
            guard StatsStore.noon(t, in: tz) != nil else { throw MCPInvalidParams("\(name) must be a date like 2026-11-13") }
            return t
        }
        let f0 = try from.flatMap { $0.isEmpty ? nil : try check($0, "from") }
        let t0 = try to.flatMap { $0.isEmpty ? nil : try check($0, "to") }
        let end = t0 ?? (f0.map { max($0, today) } ?? today)
        guard let start = f0 ?? StatsStore.shift(end, by: -(defaultDays - 1), in: tz) else {
            throw MCPInvalidParams("could not work out the date range")
        }
        guard start <= end else { throw MCPInvalidParams("from (\(start)) is after to (\(end))") }
        guard StatsStore.days(from: start, to: end, in: tz) != nil else {
            throw MCPInvalidParams("the range may span at most \(StatsStore.maxRangeDays) days")
        }
        return (start, end)
    }

    // MARK: - 出参 schema

    private static func int(_ d: String) -> MCPObject { MCPSchema.integer(d) }

    private static var documentGroupSchema: MCPObject {
        MCPSchema.object([
            "document_id": MCPSchema.string("document id"),
            "title": MCPSchema.string("document title"),
            "total": int("exercises"),
            "answered": int("exercises answered at least once"),
            "in_mistakes": int("exercises in the mistakes book"),
            "starred": int("starred exercises"),
        ])
    }

    static var outputSchema: MCPObject {
        let kindCounts: [String: MCPObject] = [
            "text_notes": int("text notes pinned on pages"),
            "highlights": int("highlights"),
            "bookmarks": int("bookmarks"),
            "image_notes": int("image notes"),
            "ai_threads": int("AI conversations attached to pages"),
            "ink_strokes": int("handwriting strokes on pages (one per stroke)"),
            "scratch_ink_strokes": int("handwriting strokes on scratch pads"),
            "pages_with_ink": int("pages that have handwriting"),
        ]
        var docAnnotations = kindCounts
        docAnnotations["document_id"] = MCPSchema.string("document id")
        docAnnotations["title"] = MCPSchema.string("document title")
        var annotations = kindCounts
        annotations["scratch_pads"] = int("scratch pads")
        annotations["by_document"] = MCPSchema.array(of: MCPSchema.object(docAnnotations),
                                                     "documents with most annotations first (at most limit)")
        annotations["by_document_omitted"] = int("documents left out of by_document")

        return MCPSchema.object([
            "workspace": MCPSchema.string("workspace name"),
            "today": MCPSchema.string("today's local date, YYYY-MM-DD"),
            "from": MCPSchema.string("first day of the per-day breakdowns (local date)"),
            "to": MCPSchema.string("last day of the per-day breakdowns (local date, inclusive)"),
            "document": MCPSchema.object([
                "id": MCPSchema.string("document id"), "title": MCPSchema.string("document title"),
            ], description: "present when document_id was given: library, annotations, exercises and practice count only this document"),
            "library": MCPSchema.object([
                "documents": int("PDF documents"),
                "pages": int("pages in all"),
                "started": int("documents whose reading position has left the top of page 1"),
                "finished": int("documents read to the last page"),
                "not_started": int("documents not started"),
                "by_document": MCPSchema.array(of: MCPSchema.object([
                    "document_id": MCPSchema.string("document id"),
                    "title": MCPSchema.string("document title"),
                    "page_count": int("pages"),
                    "read_page": int("1-based page at the top of the screen when last read"),
                    "progress": int("percent of the book reached (0-100; 0 = not started)"),
                    "finished": MCPSchema.boolean("read to the last page"),
                    "last_opened_at": MCPSchema.string("ISO 8601"),
                ]), "most recently opened first (at most limit)"),
                "by_document_omitted": int("documents left out of by_document"),
            ]),
            "annotations": MCPSchema.object(annotations),
            "markdown": MCPSchema.object([
                "notes": int("Markdown notes in all sources"),
                "by_source": MCPSchema.array(of: MCPSchema.object([
                    "source": MCPSchema.string("note source name"),
                    "kind": MCPSchema.string("workspace (the built-in Notes folder) or reference (an external folder)"),
                    "notes": int("Markdown notes in this source"),
                ])),
            ]),
            "boards": MCPSchema.object([
                "boards": int("boards (handwritten whiteboards)"),
                "paged_boards": int("boards in paged mode"),
                "pages": int("pages of paged boards"),
                "ink_items": int("handwriting strokes on boards"),
                "image_items": int("images on boards"),
            ]),
            "exercises": MCPSchema.object([
                "total": int("exercises"),
                "by_type": MCPSchema.object([
                    "single": int("single choice"), "multiple": int("multiple choice"),
                    "fill": int("fill in the blanks"), "subjective": int("subjective / free answer"),
                    "other": int("types this version does not know"),
                ]),
                "starred": int("starred"),
                "in_mistakes": int("in the mistakes book (enters on a wrong answer, leaves only when the user removes it)"),
                "with_note": int("with a note written by the user"),
                "untagged": int("without tags"),
                "answered": int("answered at least once (practice or answers found on the book page)"),
                "never_answered": int("never answered"),
                "last_correct": int("last answer right"),
                "last_wrong": int("last answer wrong"),
                "last_ungraded": int("last answer not judged yet (no answer key, or waiting to be graded)"),
                "attempts": int("answers recorded in all"),
                "awaiting_grading": int("fill-in / subjective answers waiting to be graded (see list_exercise_attempts ungraded_only)"),
                "by_document": MCPSchema.array(of: documentGroupSchema, "documents with most exercises first (at most limit)"),
                "by_document_omitted": int("documents left out of by_document"),
                "by_chapter": MCPSchema.array(of: MCPSchema.object([
                    "document_id": MCPSchema.string("document id"),
                    "title": MCPSchema.string("document title"),
                    "chapter": MCPSchema.array(of: MCPSchema.string("level"), "chapter path, top level first; [] = no chapter"),
                    "total": int("exercises"),
                    "answered": int("answered at least once"),
                    "in_mistakes": int("in the mistakes book"),
                    "starred": int("starred"),
                ]), "per document and chapter, in book order (at most limit)"),
                "by_chapter_omitted": int("chapters left out of by_chapter"),
                "by_tag": MCPSchema.array(of: MCPSchema.object([
                    "tag": MCPSchema.string("tag"),
                    "total": int("exercises with this tag"),
                    "answered": int("answered at least once"),
                    "in_mistakes": int("in the mistakes book"),
                    "starred": int("starred"),
                ]), "most used tags first (at most limit)"),
                "by_tag_omitted": int("tags left out of by_tag"),
            ]),
            "practice": MCPSchema.object([
                "attempts": int("answers given in UniReader's practice view between from and to"),
                "correct": int("of them right"),
                "wrong": int("of them wrong"),
                "ungraded": int("of them not judged yet"),
                "exercises": int("distinct exercises practiced"),
                "elapsed_ms": int("time spent answering, milliseconds"),
                "active_days": int("days with at least one answer"),
                "by_day": MCPSchema.array(of: MCPSchema.object([
                    "day": MCPSchema.string("local date YYYY-MM-DD"),
                    "attempts": int("answers"), "correct": int("right"), "wrong": int("wrong"),
                    "ungraded": int("not judged yet"), "exercises": int("distinct exercises"),
                    "elapsed_ms": int("time spent, milliseconds"),
                ]), "days with answers only, oldest first"),
            ]),
            "agent": MCPSchema.object([
                "memories": int("saved memories (list_memories)"),
                "contexts": int("saved agent contexts (list_agent_contexts)"),
                "conversations": int("saved conversations of the Agent panel (list_conversations)"),
                "turns": int("turns in those conversations"),
            ]),
            "schedule": MCPSchema.object([
                "plans": int("schedule plans"),
                "items": int("schedule items in all"),
                "done": int("items done"),
                "open": int("items not done"),
                "overdue": int("open items whose day is before today"),
                "undated": int("open items without a day"),
                "today_items": int("items on today"),
                "today_done": int("of them done"),
                "by_plan": MCPSchema.array(of: MCPSchema.object([
                    "plan_id": MCPSchema.string("plan id"),
                    "title": MCPSchema.string("plan title"),
                    "items": int("items"), "done": int("done"), "overdue": int("overdue"),
                ]), "newest plans first (at most limit)"),
                "by_plan_omitted": int("plans left out of by_plan"),
                "by_day": MCPSchema.array(of: MCPSchema.object([
                    "day": MCPSchema.string("local date YYYY-MM-DD"),
                    "items": int("items on that day"),
                    "done": int("of them done"),
                    "completed": int("items marked done on that day, whatever day they were on"),
                ]), "days with items or completions only, oldest first"),
            ]),
        ])
    }

    // MARK: - 结构化结果

    static func object(workspace: String, today: String, from: String, to: String,
                       document: (id: String, title: String)?, report r: StatsStore.Report,
                       markdown: [MarkdownSource]?) -> MCPObject {
        var o: MCPObject = ["workspace": workspace, "today": today, "from": from, "to": to]
        if let document { o["document"] = ["id": document.id, "title": document.title] as MCPObject }
        if let l = r.library {
            o["library"] = [
                "documents": l.documents, "pages": l.pages, "started": l.started, "finished": l.finished,
                "not_started": l.notStarted,
                "by_document": l.byDocument.map { d -> MCPObject in
                    ["document_id": d.id, "title": d.title, "page_count": d.pageCount,
                     "read_page": PageNo.external(d.readPage), "progress": d.progress, "finished": d.finished,
                     "last_opened_at": d.lastOpenedAt]
                },
                "by_document_omitted": l.byDocumentOmitted,
            ] as MCPObject
        }
        if let a = r.annotations {
            var x = kindObject(a.counts, pagesWithInk: a.pagesWithInk)
            x["scratch_pads"] = a.scratchPads
            x["by_document"] = a.byDocument.map { d -> MCPObject in
                var row = kindObject(d.counts, pagesWithInk: d.pagesWithInk)
                row["document_id"] = d.id
                row["title"] = d.title
                return row
            }
            x["by_document_omitted"] = a.byDocumentOmitted
            o["annotations"] = x
        }
        if let markdown {
            o["markdown"] = ["notes": markdown.reduce(0) { $0 + $1.notes },
                             "by_source": markdown.map { ["source": $0.name, "kind": $0.kind, "notes": $0.notes] as MCPObject }]
                as MCPObject
        }
        if let b = r.boards {
            o["boards"] = ["boards": b.boards, "paged_boards": b.pagedBoards, "pages": b.pages,
                           "ink_items": b.inkItems, "image_items": b.imageItems] as MCPObject
        }
        if let e = r.exercises {
            func group(_ g: StatsStore.ExerciseGroup) -> MCPObject {
                ["total": g.total, "answered": g.answered, "in_mistakes": g.inMistakes, "starred": g.starred]
            }
            o["exercises"] = [
                "total": e.total,
                "by_type": ["single": e.single, "multiple": e.multiple, "fill": e.fill, "subjective": e.subjective,
                            "other": e.otherKinds] as MCPObject,
                "starred": e.starred, "in_mistakes": e.inMistakes, "with_note": e.withNote, "untagged": e.untagged,
                "answered": e.answered, "never_answered": e.neverAnswered,
                "last_correct": e.lastCorrect, "last_wrong": e.lastWrong, "last_ungraded": e.lastUngraded,
                "attempts": e.attempts, "awaiting_grading": e.awaitingGrading,
                "by_document": e.byDocument.map { g -> MCPObject in
                    group(g).merging(["document_id": g.documentId, "title": g.title]) { a, _ in a }
                },
                "by_document_omitted": e.byDocumentOmitted,
                "by_chapter": e.byChapter.map { g -> MCPObject in
                    group(g).merging(["document_id": g.documentId, "title": g.title, "chapter": g.chapter]) { a, _ in a }
                },
                "by_chapter_omitted": e.byChapterOmitted,
                "by_tag": e.byTag.map { g -> MCPObject in group(g).merging(["tag": g.tag]) { a, _ in a } },
                "by_tag_omitted": e.byTagOmitted,
            ] as MCPObject
        }
        if let p = r.practice {
            o["practice"] = [
                "attempts": p.attempts, "correct": p.correct, "wrong": p.wrong, "ungraded": p.ungraded,
                "exercises": p.exercises, "elapsed_ms": p.elapsedMs, "active_days": p.byDay.count,
                "by_day": p.byDay.map { d -> MCPObject in
                    ["day": d.day, "attempts": d.attempts, "correct": d.correct, "wrong": d.wrong,
                     "ungraded": d.ungraded, "exercises": d.exercises, "elapsed_ms": d.elapsedMs]
                },
            ] as MCPObject
        }
        if let g = r.agent {
            o["agent"] = ["memories": g.memories, "contexts": g.contexts, "conversations": g.conversations,
                          "turns": g.turns] as MCPObject
        }
        if let s = r.schedule {
            o["schedule"] = [
                "plans": s.plans, "items": s.items, "done": s.done, "open": s.open, "overdue": s.overdue,
                "undated": s.undated, "today_items": s.todayItems, "today_done": s.todayDone,
                "by_plan": s.byPlan.map { p -> MCPObject in
                    ["plan_id": p.id, "title": p.title, "items": p.items, "done": p.done, "overdue": p.overdue]
                },
                "by_plan_omitted": s.byPlanOmitted,
                "by_day": s.byDay.map { d -> MCPObject in
                    ["day": d.day, "items": d.items, "done": d.done, "completed": d.completed]
                },
            ] as MCPObject
        }
        return o
    }

    private static func kindObject(_ c: StatsStore.KindCounts, pagesWithInk: Int) -> MCPObject {
        ["text_notes": c.text, "highlights": c.highlights, "bookmarks": c.bookmarks, "image_notes": c.images,
         "ai_threads": c.aiThreads, "ink_strokes": c.ink, "scratch_ink_strokes": c.scratchInk,
         "pages_with_ink": pagesWithInk]
    }

    // MARK: - 给人看的摘要

    static func text(workspace: String, today: String, from: String, to: String,
                     document: (id: String, title: String)?, report r: StatsStore.Report,
                     markdown: [MarkdownSource]?) -> String {
        var lines = ["Workspace “\(workspace)” — counts as of \(today)"
                     + (document.map { "; library, annotations, exercises and practice for “\($0.title)” only" } ?? "")]
        func more(_ n: Int, _ what: String) { if n > 0 { lines.append("  (\(n) more \(what) not listed)") } }
        if let l = r.library {
            lines.append("Library: \(l.documents) document(s), \(l.pages) pages; \(l.started) started, \(l.finished) finished, \(l.notStarted) not started.")
            for d in l.byDocument {
                let pos = d.started ? "p.\(PageNo.external(d.readPage))/\(d.pageCount) (\(d.progress)%\(d.finished ? ", finished" : ""))"
                                    : "not started (\(d.pageCount) pages)"
                lines.append("  - \(d.title): \(pos)")
            }
            more(l.byDocumentOmitted, "documents")
        }
        if let a = r.annotations {
            lines.append("Annotations: \(kindText(a.counts, pagesWithInk: a.pagesWithInk)); \(a.scratchPads) scratch pad(s).")
            for d in a.byDocument { lines.append("  - \(d.title): \(kindText(d.counts, pagesWithInk: d.pagesWithInk))") }
            more(a.byDocumentOmitted, "documents")
        }
        if let markdown {
            let total = markdown.reduce(0) { $0 + $1.notes }
            let parts = markdown.map { "\($0.name) \($0.notes)" }.joined(separator: ", ")
            lines.append("Markdown notes: \(total)" + (markdown.count > 1 ? " (\(parts))." : "."))
        }
        if let b = r.boards {
            lines.append("Boards: \(b.boards) (\(b.pagedBoards) paged, \(b.pages) pages); \(b.inkItems) ink strokes, \(b.imageItems) images.")
        }
        if let e = r.exercises {
            lines.append("Exercises: \(e.total) (single \(e.single), multiple \(e.multiple), fill \(e.fill), subjective \(e.subjective)"
                         + (e.otherKinds > 0 ? ", other \(e.otherKinds)" : "") + "); "
                         + "answered \(e.answered), never answered \(e.neverAnswered); "
                         + "last answer right \(e.lastCorrect) / wrong \(e.lastWrong) / not judged \(e.lastUngraded); "
                         + "\(e.inMistakes) in mistakes, \(e.starred) starred, \(e.withNote) with notes; "
                         + "\(e.attempts) attempt(s), \(e.awaitingGrading) waiting to be graded.")
            func g(_ x: StatsStore.ExerciseGroup) -> String {
                "\(x.total) (answered \(x.answered), mistakes \(x.inMistakes), starred \(x.starred))"
            }
            if !e.byDocument.isEmpty {
                lines.append("  By document:")
                for x in e.byDocument { lines.append("  - \(x.title): \(g(x))") }
                more(e.byDocumentOmitted, "documents")
            }
            if !e.byChapter.isEmpty {
                lines.append("  By chapter:")
                for x in e.byChapter {
                    let ch = x.chapter.isEmpty ? "(no chapter)" : x.chapter.joined(separator: " › ")
                    lines.append("  - \(x.title) · \(ch): \(g(x))")
                }
                more(e.byChapterOmitted, "chapters")
            }
            if !e.byTag.isEmpty {
                lines.append("  By tag (\(e.untagged) untagged):")
                for x in e.byTag { lines.append("  - \(x.tag): \(g(x))") }
                more(e.byTagOmitted, "tags")
            }
        }
        if let p = r.practice {
            lines.append("Practice \(from) – \(to): \(p.attempts) answer(s) on \(p.exercises) exercise(s), "
                         + "\(p.correct) right, \(p.wrong) wrong, \(p.ungraded) not judged, \(duration(p.elapsedMs)), "
                         + "\(p.byDay.count) active day(s).")
            for d in p.byDay {
                lines.append("  - \(d.day): \(d.attempts) answer(s) on \(d.exercises), \(d.correct) right, \(d.wrong) wrong"
                             + (d.ungraded > 0 ? ", \(d.ungraded) not judged" : "") + ", \(duration(d.elapsedMs))")
            }
        }
        if let g = r.agent {
            lines.append("Agent: \(g.memories) memories, \(g.contexts) saved contexts, \(g.conversations) conversations (\(g.turns) turns).")
        }
        if let s = r.schedule {
            lines.append("Schedule: \(s.plans) plan(s); \(s.items) item(s): \(s.done) done, \(s.open) open "
                         + "(\(s.overdue) overdue, \(s.undated) undated); today \(s.todayDone)/\(s.todayItems) done.")
            for p in s.byPlan {
                lines.append("  - \(p.title.isEmpty ? "(untitled plan)" : p.title): \(p.done)/\(p.items) done"
                             + (p.overdue > 0 ? ", \(p.overdue) overdue" : ""))
            }
            more(s.byPlanOmitted, "plans")
            if !s.byDay.isEmpty {
                lines.append("  By day \(from) – \(to):")
                for d in s.byDay {
                    lines.append("  - \(d.day): \(d.done)/\(d.items) done" + (d.completed > 0 ? ", \(d.completed) completed that day" : ""))
                }
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func kindText(_ c: StatsStore.KindCounts, pagesWithInk: Int) -> String {
        "\(c.text) text notes, \(c.highlights) highlights, \(c.bookmarks) bookmarks, \(c.images) image notes, "
            + "\(c.aiThreads) AI threads, \(c.ink) ink strokes on \(pagesWithInk) page(s), \(c.scratchInk) scratch-pad strokes"
    }

    /// 「1 h 25 min」/「3 min」/「40 s」。
    static func duration(_ ms: Int) -> String {
        let s = max(0, ms) / 1000
        if s < 60 { return "\(s) s" }
        let m = s / 60
        return m < 60 ? "\(m) min" : "\(m / 60) h \(m % 60) min"
    }
}
