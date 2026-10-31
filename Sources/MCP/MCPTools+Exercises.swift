import Foundation

/// 批 4：习题（`EXERCISE-PLAN.md §3`）。`import_exercises` 的输入结构就是「固定的导入标准」，
/// 写给 Agent 的操作说明在 `skills/unireader-exercise-import/SKILL.md`。
/// 🔴 每个返回的键都要在 `outputSchema` 里声明（Kimi 严格校验，多一个键整次调用作废）。
extension MCPTools {

    static let maxImportExercises = 50

    /// 一道题在输出里的样子（`list_exercises` / `update_exercises` 共用）。
    static var exerciseOutputSchema: MCPObject {
        MCPSchema.object([
            "id": MCPSchema.string("exercise id"),
            "document_id": MCPSchema.string("source document"),
            "page": MCPSchema.integer("source page, 1-based"),
            "link": MCPSchema.string("unireader:// link to the source page"),
            "type": MCPSchema.enumeration(["single", "multiple", "fill", "subjective"],
                                          "single / multiple choice, fill in the blank, or subjective (free answer)"),
            "number": MCPSchema.string("question number as printed (may be empty)"),
            "section": MCPSchema.string("chapter / test name (may be empty)"),
            "stem": MCPSchema.string("question text (Markdown + $math$)"),
            "options": MCPSchema.array(of: MCPSchema.object([
                "key": MCPSchema.string("A–H"), "text": MCPSchema.string("option text")])),
            "answer": MCPSchema.string("choice: correct option letters, e.g. \"B\" or \"AC\"; subjective: the reference answer; fill: empty (see blanks); empty = no answer yet"),
            "blanks": MCPSchema.array(of: blankOutputSchema, "fill questions: the blanks in order, each with its reference answer"),
            "answer_source": MCPSchema.enumeration(["book", "agent"], "printed in the document, or worked out by an agent"),
            "explanation": MCPSchema.string("explanation"),
            "region": MCPSchema.array(of: MCPSchema.number("0…1"), "[x, y, w, h] of the question on its page"),
            "has_figure": MCPSchema.boolean("the question relies on a figure or table"),
            "chapter": MCPSchema.array(of: MCPSchema.string("level"), "chapter path, top level first (from the table of contents, or the user's own grouping); empty = none"),
            "user_answer": MCPSchema.string("what the user wrote in the document: option letters (choice) or the transcribed text (subjective)"),
            "user_blanks": MCPSchema.array(of: MCPSchema.string("one blank"), "fill questions: what the user wrote in the document, one string per blank"),
            "user_answer_correct": MCPSchema.boolean("whether that marked answer is right (absent when it is not judged yet)"),
            "starred": MCPSchema.boolean("starred by the user"),
            "in_mistakes": MCPSchema.boolean("in the user's mistake list"),
            "note": MCPSchema.string("the user's own note on this question (Markdown + $math$); absent when there is none"),
            "attempts": MCPSchema.integer("times practiced"),
            "correct": MCPSchema.integer("times answered correctly"),
            "ungraded": MCPSchema.integer("attempts not judged yet (fill / subjective answers waiting for the user or an agent to grade; list them with list_exercise_attempts)"),
        ])
    }

    static var blankOutputSchema: MCPObject {
        MCPSchema.object([
            "answer": MCPSchema.string("reference answer for this blank (empty = not known yet)"),
            "accept": MCPSchema.array(of: MCPSchema.string("form"), "other forms that also count as right"),
        ])
    }

    /// `blanks` 数组 `[{answer, accept}]` → 元组（类型不对就是 `MCPInvalidParams`）。
    private static func blanksArg(_ v: Any?, at path: String) throws -> [(answer: String?, accept: [String])]? {
        guard let v, !(v is NSNull) else { return nil }
        let bad = MCPInvalidParams("\(path).blanks must be an array of {answer, accept}, one per blank")
        guard let list = v as? [Any] else { throw bad }
        return try list.map { o in
            guard let d = o as? [String: Any] else { throw bad }
            let answer = try stringField(d, "answer", at: "\(path).blanks[]")
            var accept: [String] = []
            if let a = d["accept"], !(a is NSNull) {
                guard let arr = a as? [Any], arr.allSatisfy({ $0 is String }) else {
                    throw MCPInvalidParams("\(path).blanks[].accept must be an array of strings")
                }
                accept = arr.compactMap { $0 as? String }
            }
            return (answer: answer, accept: accept)
        }
    }

    private static func stringsArg(_ v: Any?, _ name: String, at path: String) throws -> [String]? {
        guard let v, !(v is NSNull) else { return nil }
        guard let a = v as? [Any], a.allSatisfy({ $0 is String }) else {
            throw MCPInvalidParams("\(path).\(name) must be an array of strings")
        }
        return a.compactMap { $0 as? String }
    }

    /// 选项数组 `[{key, text}]` → 元组（类型不对就是 `MCPInvalidParams`）。
    private static func optionsArg(_ v: Any?, at path: String) throws -> [(key: String?, text: String?)]? {
        guard let v, !(v is NSNull) else { return nil }
        guard let list = v as? [Any] else { throw MCPInvalidParams("\(path).options must be an array of {key, text}") }
        return try list.map { o in
            guard let d = o as? [String: Any] else { throw MCPInvalidParams("\(path).options must be an array of {key, text}") }
            return (key: d["key"] as? String, text: d["text"] as? String)
        }
    }

    private static func chapterArg(_ v: Any?, at path: String) throws -> [String]? {
        guard let v, !(v is NSNull) else { return nil }
        guard let a = v as? [Any], a.allSatisfy({ $0 is String }) else {
            throw MCPInvalidParams("\(path).chapter must be an array of strings (top level first)")
        }
        return a.compactMap { $0 as? String }
    }

    /// `import_exercises` 的 `chapters`（`EXERCISE-PLAN.md §14`）：`"toc"` / `"none"`；没给 = nil（按这本书现在的样子）。
    private static func chapterModeArg(_ v: Any?) throws -> ExerciseChapterMode? {
        guard let v, !(v is NSNull) else { return nil }
        guard let s = v as? String, let m = ExerciseChapterMode(rawValue: s) else {
            throw MCPInvalidParams("chapters must be \"toc\" or \"none\"")
        }
        return m
    }

    private static func regionArg(_ v: Any?, at path: String) throws -> [Double]? {
        guard let v, !(v is NSNull) else { return nil }
        guard let a = v as? [NSNumber] else { throw MCPInvalidParams("\(path).region must be [x, y, w, h]") }
        return a.map(\.doubleValue)
    }

    private static func stringField(_ d: [String: Any], _ k: String, at path: String) throws -> String? {
        guard let v = d[k], !(v is NSNull) else { return nil }
        guard let s = v as? String else { throw MCPInvalidParams("\(path).\(k) must be a string") }
        return s
    }

    private static func boolField(_ d: [String: Any], _ k: String, at path: String) throws -> Bool? {
        guard let v = d[k], !(v is NSNull) else { return nil }
        guard let n = v as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() else {
            throw MCPInvalidParams("\(path).\(k) must be a boolean")
        }
        return n.boolValue
    }

    static func importExercisesTool() -> MCPTool {
        let option = MCPSchema.object([
            "key": MCPSchema.string("Option letter as printed: A, B, C … (A–H)"),
            "text": MCPSchema.string("Option text exactly as printed (Markdown + $math$). May be empty only when has_figure is true and the options are pictures."),
        ], required: ["key", "text"])
        let blank = MCPSchema.object([
            "answer": MCPSchema.string("Reference answer for this blank (Markdown + $math$). Omit for every blank when the answers are not known yet."),
            "accept": MCPSchema.array(of: MCPSchema.string("form"), "Other forms that also count as right, e.g. [\"0.5\"] for $\\frac{1}{2}$ (optional)"),
        ])
        let item = MCPSchema.object([
            "page": MCPSchema.integer("Page the question is printed on, 1-based", min: 1),
            "number": MCPSchema.string("Question number exactly as printed (\"5\", \"例 3\"). Strongly recommended: re-importing the same number on the same page updates the question instead of adding a copy."),
            "section": MCPSchema.string("Chapter, exercise set or test name the question belongs to, as printed (optional)."),
            "type": MCPSchema.enumeration(["single", "multiple", "fill", "subjective"], "single / multiple choice; fill = fill in the blank (give blanks); subjective = calculation, proof, short answer or essay (free answer, the user marks it right or wrong against the reference answer). Omit for choice questions to infer from the answer (one letter = single)."),
            "stem": MCPSchema.string("The question text, transcribed exactly (no rewording). Keep the blanks of a fill question as printed (____ or （　）). \(mathWriting)"),
            "options": MCPSchema.array(of: option, "Choice questions only: 2–8 options in printed order. Leave out for fill and subjective questions."),
            "blanks": MCPSchema.array(of: blank, "Fill questions only: one entry per blank in reading order, e.g. [{\"answer\": \"2\"}, {\"answer\": \"$\\\\frac{1}{2}$\", \"accept\": [\"0.5\"]}]. Give an answer for every blank or for none ([{}, {}] when unknown)."),
            "answer": MCPSchema.string("Choice: correct option letters, e.g. \"B\" or \"AC\". Subjective: the reference answer / worked solution (Markdown + $math$). Not used for fill questions (use blanks). Omit when the answer is not known yet (fill it in later with update_exercises)."),
            "answer_source": MCPSchema.enumeration(["book", "agent"], "Required with an answer (or blanks with answers): \"book\" when the answer is printed in the document (after the question or in an answer key), \"agent\" when you worked it out yourself."),
            "explanation": MCPSchema.string("Explanation / solution (Markdown + $math$), from the document or your own (optional)."),
            "region": MCPSchema.array(of: MCPSchema.number("0…1"), "[x, y, w, h] box around the whole question on its page, normalized 0–1, top-left origin (as in render_page). Lets the user see the original question."),
            "has_figure": MCPSchema.boolean("True when the question depends on a figure, graph or table the text cannot carry; the original is then shown while practicing.", default: false),
            "chapter": MCPSchema.array(of: MCPSchema.string("level"), "Chapter path, top level first, any number of levels. When the book is grouped by the table of contents, omit it: UniReader looks up the page itself (unless the book is not grouped into chapters, see chapters); give it only when that would be wrong (e.g. exercises collected at the back of the book). When the user wants the questions grouped their own way — the headings printed on the pages, question groups such as [\"习题 2.3\", \"A 组\"], or however they say — give every question its full path (reuse the exact names of levels that already exist) and pass chapters \"none\". [] = no chapter."),
            "user_answer": MCPSchema.string("What the user already wrote for this question in the document. Choice: the option(s) marked — a highlight on an option (list_annotations) or a circled / written letter (render_page with include_marks) — e.g. \"B\". Subjective: their handwritten answer, transcribed. Saved as the user's earlier attempt; a choice answer is judged right away (a wrong one goes into the mistake list), a subjective one waits to be graded (grade_exercise_attempts). Omit when the user has not answered it."),
            "user_blanks": MCPSchema.array(of: MCPSchema.string("one blank"), "Fill questions only: what the user already wrote in the document, one string per blank (\"\" for a blank left empty)."),
        ], required: ["page", "stem"])
        return MCPTool(
            name: "import_exercises",
            title: "Import exercises",
            description: """
            Save exercises recognized in a PDF into the workspace so the user can practice them in UniReader \
            (练习 / 错题本 / 收藏 in the UI; the user may call this exercise library 习题册, 练习册 or 练习库): single / multiple choice, fill in the blank, and subjective questions \
            (calculation, proof, short answer — the user writes or hand-draws an answer and marks it against the reference \
            answer, or asks an agent to grade it). Look at the pages first (render_page for the image, read_pages for the text), \
            transcribe each question exactly, then call this with up to \(maxImportExercises) questions in reading order. \
            Each question is checked on its own: bad ones come back with a reason and the rest are saved. Importing the same \
            question again (same page + section + number, or the same text when there is no number) updates it and keeps \
            the user's stars, mistakes and practice history. \
            The first time you import into a book (list_exercises shows it has no questions yet), ask the user whether \
            to group its questions into chapters and pass the answer as chapters.
            """,
            inputSchema: MCPSchema.object(writeTargetProperties.merging([
                "exercises": MCPSchema.array(of: item, "Questions to save (1–\(maxImportExercises))"),
                "chapters": MCPSchema.enumeration(["toc", "none"], "How the questions that carry no chapter of their own are grouped in the sidebar. The first time you import into a book (it has no questions yet), ask the user how to group them: \"toc\" = by the PDF's table of contents (UniReader looks up each page); their own way = give each question a chapter and pass \"none\"; not at all = \"none\" (the book stays one flat list). Omit it on later imports of a book grouped by the table of contents or not grouped: the book keeps the way it is (a book the user took the chapters off stays flat). A question's own chapter always wins."),
            ]) { a, _ in a }, required: ["exercises"]),
            outputSchema: MCPSchema.object([
                "document_id": MCPSchema.string("document"), "title": MCPSchema.string("document title"),
                "created": MCPSchema.integer("new questions"), "updated": MCPSchema.integer("questions that already existed and were updated"),
                "rejected": MCPSchema.integer("questions not saved"),
                "results": MCPSchema.array(of: MCPSchema.object([
                    "index": MCPSchema.integer("position in the input, 0-based"),
                    "status": MCPSchema.enumeration(["created", "updated", "rejected"], "what happened"),
                    "id": MCPSchema.string("exercise id (not for rejected)"),
                    "number": MCPSchema.string("question number"),
                    "page": MCPSchema.integer("1-based"),
                    "reason": MCPSchema.string("why it was rejected"),
                ])),
            ]),
            tier: .write
        ) { ctx, args in
            guard let list = args.raw["exercises"] as? [Any], !list.isEmpty else {
                throw MCPInvalidParams("exercises must be a non-empty array")
            }
            guard list.count <= maxImportExercises else {
                throw MCPInvalidParams("at most \(maxImportExercises) exercises per call; split the rest into another call")
            }
            let docId = try args.string("document_id"), wsPath = try args.string("workspace")
            let mode = try chapterModeArg(args.raw["chapters"])
            let t = try await MainActor.run { try MCPFacade.shared.writeTarget(documentId: docId, workspacePath: wsPath) }
            var items: [Result<ExerciseDraft, ExerciseImport.Rejected>] = []
            for (i, raw) in list.enumerated() {
                let path = "exercises[\(i)]"
                guard let d = raw as? [String: Any] else { throw MCPInvalidParams("\(path) must be an object") }
                let page: Int
                do {
                    guard let p = try MCPArgs(d).int("page") else {
                        items.append(.failure("page is required")); continue
                    }
                    page = try PageNo.index(p, pageCount: t.pageCount)
                } catch let e as MCPToolError {
                    items.append(.failure(ExerciseImport.Rejected(stringLiteral: e.message))); continue
                }
                let input = ExerciseInput(
                    page: page, type: try stringField(d, "type", at: path),
                    number: try stringField(d, "number", at: path), section: try stringField(d, "section", at: path),
                    stem: try stringField(d, "stem", at: path),
                    options: try optionsArg(d["options"], at: path) ?? [],
                    answer: try stringField(d, "answer", at: path),
                    answerSource: try stringField(d, "answer_source", at: path),
                    explanation: try stringField(d, "explanation", at: path),
                    region: try regionArg(d["region"], at: path),
                    figure: try boolField(d, "has_figure", at: path),
                    chapter: try chapterArg(d["chapter"], at: path),
                    userAnswer: try stringField(d, "user_answer", at: path),
                    blanks: try blanksArg(d["blanks"], at: path),
                    userBlanks: try stringsArg(d["user_blanks"], "user_blanks", at: path))
                items.append(ExerciseImport.validate(input, seq: i))
            }
            // 章节没给的按页码从 PDF 自带目录里查（`EXERCISE-PLAN.md §2.3`）；文件不在 / 没目录 → 空。
            // 不分章节的书（用户移除过分级 / 第一次导入时选了不分）保持不分，除非这次明说 `chapters: "toc"`（§14）。
            var keptFlat = false
            if mode != .flat, let path = t.path,
               items.contains(where: { if case .success(let d) = $0 { d.chapter == nil } else { false } }) {
                let toc = (try? await MCPDocReader.shared.withDocument(path: path) { ExerciseChapterNode.toc(of: $0) }) ?? []
                if !toc.isEmpty {
                    let existing = await MainActor.run {
                        t.ws.exercises(in: .document(t.id)).map { (page: $0.page, chapter: $0.chapter) }
                    }
                    if ExerciseChapter.usesTOC(mode, existing: existing, toc: toc) {
                        items = items.map { r in
                            guard case .success(var d) = r, let p = d.page else { return r }
                            d.autoChapter = ExerciseChapter.path(page: p, in: toc)
                            return .success(d)
                        }
                    } else {
                        keptFlat = true
                    }
                }
            }
            let client = ctx.clientName
            let checked = items
            let r = try await MainActor.run { try MCPFacade.shared.importExercises(t, items: checked, client: client) }
            var lines = ["Saved exercises into “\(r["title"] ?? "")”: \(r["created"] ?? 0) new, \(r["updated"] ?? 0) updated, \(r["rejected"] ?? 0) rejected."]
            for o in (r["results"] as? [MCPObject]) ?? [] where o["status"] as? String == "rejected" {
                lines.append("- #\(o["index"] ?? "") rejected: \(o["reason"] ?? "")")
            }
            if keptFlat {
                lines.append("This book is not grouped into chapters (the user took them off or chose no chapters), so these questions got none. Pass chapters: \"toc\" only if the user now asks for chapters.")
            }
            return MCPToolResult(text: lines.joined(separator: "\n"), structured: r)
        }
    }

    static func listExercisesTool() -> MCPTool {
        MCPTool(
            name: "list_exercises",
            title: "List exercises",
            description: "List the exercises saved in UniReader for a document (or the whole workspace with all_documents), in practice order, with ids, question numbers, answers and the user's practice stats. Use it before update_exercises to match questions by number, e.g. when filling in answers from an answer key.",
            inputSchema: MCPSchema.object(writeTargetProperties.merging([
                "all_documents": MCPSchema.boolean("List every document in the workspace instead of one", default: false),
                "pages": MCPSchema.pageSpec,
                "filter": MCPSchema.enumeration(["all", "mistakes", "starred"], "Only the user's mistakes or starred ones", default: "all"),
                "chapter": MCPSchema.array(of: MCPSchema.string("level"), "Only this chapter and its sub-sections (path, top level first); [] = only questions with no chapter"),
                "offset": MCPSchema.integer("Skip this many (paging)", min: 0),
                "limit": MCPSchema.integer("At most this many (default 50)", min: 1, max: 200),
            ]) { a, _ in a }),
            outputSchema: MCPSchema.object([
                "workspace": MCPSchema.string("workspace name"),
                "document_id": MCPSchema.string("document (single-document listing)"),
                "title": MCPSchema.string("document title (single-document listing)"),
                "total": MCPSchema.integer("matching exercises in all"), "offset": MCPSchema.integer("offset used"),
                "exercises": MCPSchema.array(of: exerciseOutputSchema),
            ]),
            tier: .read
        ) { _, args in
            let docId = try args.string("document_id"), wsPath = try args.string("workspace")
            let all = try args.bool("all_documents", default: false)
            let pages = try args.pages("pages")
            let filter = try args.string("filter") ?? "all"
            guard ["all", "mistakes", "starred"].contains(filter) else { throw MCPInvalidParams("filter must be all, mistakes or starred") }
            let offset = max(0, try args.int("offset") ?? 0)
            let limit = min(200, max(1, try args.int("limit") ?? 50))
            let chapter = try chapterArg(args.raw["chapter"], at: "arguments")
            let r = try await MainActor.run {
                try MCPFacade.shared.listExercises(documentId: docId, workspacePath: wsPath, allDocuments: all,
                                                   pages: pages, filter: filter, chapter: chapter,
                                                   offset: offset, limit: limit)
            }
            let list = (r["exercises"] as? [MCPObject]) ?? []
            var lines = ["\(r["total"] ?? 0) exercise(s)\(r["title"].map { " in “\($0)”" } ?? ""); showing \(list.count) from \(offset)."]
            for e in list {
                var ans = (e["answer"] as? String).flatMap { $0.isEmpty ? nil : Exercise.collapse($0) } ?? ""
                if let b = e["blanks"] as? [MCPObject] {
                    ans = b.map { ($0["answer"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "?" }.joined(separator: " / ")
                }
                if ans.isEmpty { ans = "—" }
                let src = (e["answer_source"] as? String).map { " (\($0))" } ?? ""
                let stem = Exercise.collapse(e["stem"] as? String ?? "")
                let open = (e["ungraded"] as? Int ?? 0) > 0 ? " · \(e["ungraded"] ?? 0) ungraded" : ""
                lines.append("- [\((e["id"] as? String ?? "").prefix(8))] p.\(e["page"] ?? "?") #\(e["number"] ?? "") \(e["type"] ?? "") · answer \(ans.prefix(40))\(src)\(open) · \(stem.prefix(60))")
            }
            return MCPToolResult(text: lines.joined(separator: "\n"), structured: r)
        }
    }

    static func updateExercisesTool() -> MCPTool {
        let patch = MCPSchema.object([
            "id": MCPSchema.string("Exercise id from list_exercises (full id or its first 8 characters)"),
            "answer": MCPSchema.string("Choice: correct option letters (\"B\", \"AC\"). Subjective: the reference answer. Empty string clears it. Fill questions use blanks."),
            "blanks": MCPSchema.array(of: MCPSchema.object([
                "answer": MCPSchema.string("reference answer for this blank"),
                "accept": MCPSchema.array(of: MCPSchema.string("form"), "other forms that also count as right"),
            ]), "Fill questions: replaces all blanks (one entry per blank, answers for all or none)"),
            "answer_source": MCPSchema.enumeration(["book", "agent"], "Required whenever answer or blank answers are set: \"book\" if printed in the document, \"agent\" if you worked it out"),
            "explanation": MCPSchema.string("Explanation (Markdown + $math$); empty string clears it"),
            "type": MCPSchema.enumeration(["single", "multiple", "fill", "subjective"], "Question type. Changing to fill / subjective drops the options; changing to a choice type needs options."),
            "number": MCPSchema.string("Question number as printed"),
            "section": MCPSchema.string("Chapter / test name"),
            "stem": MCPSchema.string("Question text. \(mathWriting)"),
            "options": MCPSchema.array(of: MCPSchema.object([
                "key": MCPSchema.string("A–H"), "text": MCPSchema.string("option text")], required: ["key", "text"]),
                "Replaces all options"),
            "region": MCPSchema.array(of: MCPSchema.number("0…1"), "[x, y, w, h] on the question's page"),
            "has_figure": MCPSchema.boolean("The question depends on a figure or table"),
            "chapter": MCPSchema.array(of: MCPSchema.string("level"), "Chapter path, top level first, any number of levels (e.g. to regroup questions the way the user asks); [] clears it"),
            "user_answer": MCPSchema.string("What the user wrote in the document: option letters (\"B\") for choice, transcribed text for subjective; replaces the earlier one; empty string removes it"),
            "user_blanks": MCPSchema.array(of: MCPSchema.string("one blank"), "Fill questions: what the user wrote in the document, one string per blank; replaces the earlier one; all empty removes it"),
            "note": MCPSchema.string("The user's own note on this question, shown under the explanation once they have answered it. Replaces the whole note; empty string removes it. Write it only when the user asks you to. \(mathWriting)"),
            "starred": MCPSchema.boolean("Star (收藏) the question (true) or take the star off (false); starred questions are listed under 收藏 in the app. Change it only when the user asks you to."),
        ], required: ["id"])
        return MCPTool(
            name: "update_exercises",
            title: "Update exercises",
            description: "Change saved exercises by id — most often to fill in answers and explanations after finding the answer key, to set the chapter, to record the answer the user already wrote in the document (user_answer / user_blanks), or, when the user asks, to write their note on a question (note) or to star / unstar it (starred). Only the fields you pass change; the user's stars change only through starred, and their mistakes and practice history are kept. When the answer changes, the user's earlier attempts at that question are judged again where the app can judge them (a wrong one goes into the mistake list); attempts the user or an agent already graded keep their verdict. Every change is checked first; if any one is invalid, nothing is changed.",
            inputSchema: MCPSchema.object([
                "workspace": MCPSchema.string("Workspace .unrd path, only when the ids could be in several open workspaces."),
                "updates": MCPSchema.array(of: patch, "Changes, one per exercise (at most \(maxImportExercises))"),
            ], required: ["updates"]),
            outputSchema: MCPSchema.object([
                "count": MCPSchema.integer("exercises changed"),
                "exercises": MCPSchema.array(of: exerciseOutputSchema),
            ]),
            tier: .write
        ) { _, args in
            guard let list = args.raw["updates"] as? [Any], !list.isEmpty else {
                throw MCPInvalidParams("updates must be a non-empty array")
            }
            guard list.count <= maxImportExercises else { throw MCPInvalidParams("at most \(maxImportExercises) updates per call") }
            let patches = try list.enumerated().map { i, raw -> MCPFacade.ExercisePatch in
                let path = "updates[\(i)]"
                guard let d = raw as? [String: Any] else { throw MCPInvalidParams("\(path) must be an object") }
                guard let id = try stringField(d, "id", at: path), !id.isEmpty else { throw MCPInvalidParams("\(path).id is required") }
                return MCPFacade.ExercisePatch(
                    id: id, type: try stringField(d, "type", at: path), number: try stringField(d, "number", at: path),
                    section: try stringField(d, "section", at: path), stem: try stringField(d, "stem", at: path),
                    options: try optionsArg(d["options"], at: path), answer: try stringField(d, "answer", at: path),
                    answerSource: try stringField(d, "answer_source", at: path),
                    explanation: try stringField(d, "explanation", at: path),
                    region: try regionArg(d["region"], at: path), figure: try boolField(d, "has_figure", at: path),
                    chapter: try chapterArg(d["chapter"], at: path), userAnswer: try stringField(d, "user_answer", at: path),
                    blanks: try blanksArg(d["blanks"], at: path),
                    userBlanks: try stringsArg(d["user_blanks"], "user_blanks", at: path),
                    note: try stringField(d, "note", at: path), starred: try boolField(d, "starred", at: path))
            }
            let wsPath = try args.string("workspace")
            let r = try await MainActor.run { try MCPFacade.shared.updateExercises(patches, workspacePath: wsPath) }
            return MCPToolResult(text: "Updated \(r["count"] ?? 0) exercise(s).", structured: r)
        }
    }

    static func deleteExercisesTool() -> MCPTool {
        MCPTool(
            name: "delete_exercises",
            title: "Delete exercises",
            description: "Delete saved exercises by id, together with their practice history. They go to UniReader's Recently Deleted as one item the user can put back; if any id is not found, nothing is deleted.",
            inputSchema: MCPSchema.object([
                "workspace": MCPSchema.string("Workspace .unrd path, only when the ids could be in several open workspaces."),
                "ids": MCPSchema.array(of: MCPSchema.string("exercise id (full, or its first 8 characters)"), "Ids to delete (at most \(maxDeleteIds))"),
            ], required: ["ids"]),
            outputSchema: MCPSchema.object([
                "count": MCPSchema.integer("how many were deleted"),
                "ids": MCPSchema.array(of: MCPSchema.string("full id")),
            ]),
            tier: .delete
        ) { _, args in
            guard let list = args.raw["ids"] as? [Any], !list.isEmpty else { throw MCPInvalidParams("ids must be a non-empty array of strings") }
            let ids = try list.map { v -> String in
                guard let s = v as? String else { throw MCPInvalidParams("ids must be strings") }
                return s
            }
            guard ids.count <= maxDeleteIds else { throw MCPInvalidParams("at most \(maxDeleteIds) ids per call") }
            let wsPath = try args.string("workspace")
            let r = try await MainActor.run { try MCPFacade.shared.deleteExercises(ids, workspacePath: wsPath) }
            return MCPToolResult(text: "Deleted \(r["count"] ?? 0) exercise(s); they are in Recently Deleted.", structured: r)
        }
    }

    // MARK: - 作答与批改（`EXERCISE-PLAN.md §11.4`）

    static let maxGrades = 50

    /// 一次作答在输出里的样子（`list_exercise_attempts` / `grade_exercise_attempts` 共用）。
    static var attemptOutputSchema: MCPObject {
        MCPSchema.object([
            "id": MCPSchema.string("attempt id"),
            "exercise_id": MCPSchema.string("exercise id"),
            "document_id": MCPSchema.string("source document"),
            "page": MCPSchema.integer("source page, 1-based"),
            "number": MCPSchema.string("question number as printed"),
            "type": MCPSchema.enumeration(["single", "multiple", "fill", "subjective"], "question type"),
            "stem": MCPSchema.string("question text (Markdown + $math$)"),
            "reference_answer": MCPSchema.string("the reference answer: option letters, the blanks in order (other accepted forms in brackets), or the worked answer; empty = none yet"),
            "reference_source": MCPSchema.enumeration(["book", "agent"], "where the reference answer came from"),
            "explanation": MCPSchema.string("explanation saved with the question"),
            "source": MCPSchema.enumeration(["practice", "book"], "practiced in UniReader, or written in the document and imported"),
            "created_at": MCPSchema.string("when it was answered (ISO 8601)"),
            "answer": MCPSchema.string("what the user wrote: option letters (choice), the text (subjective), or the blanks joined with \" / \" (fill)"),
            "blanks": MCPSchema.array(of: MCPSchema.string("one blank"), "fill questions: what the user wrote in each blank"),
            "blank_matches": MCPSchema.array(of: MCPSchema.boolean("matches"), "fill questions: whether each blank matches the reference answer exactly (after ignoring spaces and full-width forms); a false one may still be an equivalent form"),
            "has_handwriting": MCPSchema.boolean("the user also wrote by hand; see it with render_exercise_answer"),
            "correct": MCPSchema.boolean("the verdict (absent = not graded yet)"),
            "judged_by": MCPSchema.enumeration(["app", "user", "agent"], "who gave the verdict: the app (choice / exactly matching blanks), the user, or an agent"),
            "feedback": MCPSchema.string("the agent's feedback (Markdown)"),
            "elapsed_ms": MCPSchema.integer("time spent, milliseconds"),
        ])
    }

    static func listExerciseAttemptsTool() -> MCPTool {
        MCPTool(
            name: "list_exercise_attempts",
            title: "List exercise answers",
            description: "List the user's answers to exercises, newest first — with the question, its reference answer and the verdict — so you can grade fill-in-the-blank and subjective answers (then save your verdict with grade_exercise_attempts). Narrow it with exercise_ids or document_id; ungraded_only lists only fill / subjective answers nobody has graded yet. Handwritten answers have has_handwriting: look at them with render_exercise_answer.",
            inputSchema: MCPSchema.object(writeTargetProperties.merging([
                "exercise_ids": MCPSchema.array(of: MCPSchema.string("exercise id (full, or its first 8 characters)"), "Only answers to these exercises"),
                "ungraded_only": MCPSchema.boolean("Only fill / subjective answers that are not graded yet", default: false),
                "offset": MCPSchema.integer("Skip this many (paging)", min: 0),
                "limit": MCPSchema.integer("At most this many (default 20)", min: 1, max: 100),
            ]) { a, _ in a }),
            outputSchema: MCPSchema.object([
                "workspace": MCPSchema.string("workspace name"),
                "total": MCPSchema.integer("matching answers in all"), "offset": MCPSchema.integer("offset used"),
                "attempts": MCPSchema.array(of: attemptOutputSchema),
            ]),
            tier: .read
        ) { _, args in
            let docId = try args.string("document_id"), wsPath = try args.string("workspace")
            let ids = try stringsArg(args.raw["exercise_ids"], "exercise_ids", at: "arguments")
            let open = try args.bool("ungraded_only", default: false)
            let offset = max(0, try args.int("offset") ?? 0)
            let limit = min(100, max(1, try args.int("limit") ?? 20))
            let r = try await MainActor.run {
                try MCPFacade.shared.listExerciseAttempts(exerciseIds: ids, documentId: docId, workspacePath: wsPath,
                                                          ungradedOnly: open, offset: offset, limit: limit)
            }
            let list = (r["attempts"] as? [MCPObject]) ?? []
            var lines = ["\(r["total"] ?? 0) answer(s); showing \(list.count) from \(offset)."]
            for a in list {
                let verdict = (a["correct"] as? Bool).map { $0 ? "right" : "wrong" } ?? "ungraded"
                let hand = a["has_handwriting"] as? Bool == true ? " + handwriting" : ""
                let ans = Exercise.collapse(a["answer"] as? String ?? "")
                lines.append("- [\((a["id"] as? String ?? "").prefix(8))] #\(a["number"] ?? "") \(a["type"] ?? "") · \(verdict) · \(ans.prefix(60))\(hand)")
            }
            return MCPToolResult(text: lines.joined(separator: "\n"), structured: r)
        }
    }

    static func renderExerciseAnswerTool() -> MCPTool {
        MCPTool(
            name: "render_exercise_answer",
            title: "Show a handwritten answer",
            description: "Render the user's handwritten answer (drawn on the small pad under a fill-in-the-blank or subjective question) as a PNG, black ink on white. Use it when list_exercise_attempts says has_handwriting.",
            inputSchema: MCPSchema.object([
                "workspace": MCPSchema.string("Workspace .unrd path, only when the id could be in several open workspaces."),
                "attempt_id": MCPSchema.string("Attempt id from list_exercise_attempts (full, or its first 8 characters)"),
                "width": MCPSchema.integer("Image width in pixels (default 1200)", min: 400, max: 2400),
            ], required: ["attempt_id"]),
            outputSchema: MCPSchema.object([
                "attempt_id": MCPSchema.string("full attempt id"),
                "exercise_id": MCPSchema.string("exercise id"),
                "width": MCPSchema.integer("pixels"), "height": MCPSchema.integer("pixels"),
            ]),
            tier: .read
        ) { _, args in
            guard let id = try args.string("attempt_id"), !id.isEmpty else { throw MCPInvalidParams("attempt_id is required") }
            let wsPath = try args.string("workspace")
            let width = min(2400, max(400, try args.int("width") ?? 1200))
            let (r, png) = try await MainActor.run {
                try MCPFacade.shared.renderExerciseAnswer(id, workspacePath: wsPath, width: width)
            }
            return MCPToolResult(text: "Handwritten answer \(String(describing: r["attempt_id"] ?? "")), \(r["width"] ?? 0)×\(r["height"] ?? 0) px.",
                                 structured: r, image: (png, "image/png"))
        }
    }

    static func gradeExerciseAttemptsTool() -> MCPTool {
        let grade = MCPSchema.object([
            "attempt_id": MCPSchema.string("Attempt id from list_exercise_attempts (full, or its first 8 characters)"),
            "correct": MCPSchema.boolean("Your verdict: true = right, false = wrong"),
            "feedback": MCPSchema.string("Short feedback for the user (Markdown + $math$): what is right, what is missing or wrong, how to fix it. Write it in the user's language. \(mathWriting)"),
        ], required: ["attempt_id", "correct"])
        return MCPTool(
            name: "grade_exercise_attempts",
            title: "Grade exercise answers",
            description: "Save your verdict (right / wrong) and feedback on the user's fill-in-the-blank or subjective answers, after comparing them with the reference answer (list_exercise_attempts, render_exercise_answer for handwriting). Your verdict replaces any earlier one, including the user's own; a wrong answer puts the question into the user's mistake list. When there is no reference answer, judge it yourself and say so in the feedback. Choice questions are judged by the app and cannot be graded here. Every grade is checked first; if any one is invalid, nothing is saved.",
            inputSchema: MCPSchema.object([
                "workspace": MCPSchema.string("Workspace .unrd path, only when the ids could be in several open workspaces."),
                "grades": MCPSchema.array(of: grade, "Verdicts, one per answer (at most \(maxGrades))"),
            ], required: ["grades"]),
            outputSchema: MCPSchema.object([
                "count": MCPSchema.integer("answers graded"),
                "attempts": MCPSchema.array(of: attemptOutputSchema),
            ]),
            tier: .write
        ) { _, args in
            guard let list = args.raw["grades"] as? [Any], !list.isEmpty else {
                throw MCPInvalidParams("grades must be a non-empty array")
            }
            guard list.count <= maxGrades else { throw MCPInvalidParams("at most \(maxGrades) grades per call") }
            let grades = try list.enumerated().map { i, raw -> MCPFacade.ExerciseGrade in
                let path = "grades[\(i)]"
                guard let d = raw as? [String: Any] else { throw MCPInvalidParams("\(path) must be an object") }
                guard let id = try stringField(d, "attempt_id", at: path), !id.isEmpty else {
                    throw MCPInvalidParams("\(path).attempt_id is required")
                }
                guard let c = try boolField(d, "correct", at: path) else { throw MCPInvalidParams("\(path).correct is required") }
                return MCPFacade.ExerciseGrade(attemptId: id, correct: c, feedback: try stringField(d, "feedback", at: path))
            }
            let wsPath = try args.string("workspace")
            let r = try await MainActor.run { try MCPFacade.shared.gradeExerciseAttempts(grades, workspacePath: wsPath) }
            return MCPToolResult(text: "Graded \(r["count"] ?? 0) answer(s).", structured: r)
        }
    }
}
