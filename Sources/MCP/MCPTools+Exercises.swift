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
            "type": MCPSchema.enumeration(["single", "multiple"], "single or multiple choice"),
            "number": MCPSchema.string("question number as printed (may be empty)"),
            "section": MCPSchema.string("chapter / test name (may be empty)"),
            "stem": MCPSchema.string("question text (Markdown + $math$)"),
            "options": MCPSchema.array(of: MCPSchema.object([
                "key": MCPSchema.string("A–H"), "text": MCPSchema.string("option text")])),
            "answer": MCPSchema.string("correct option letters, e.g. \"B\" or \"AC\"; empty = no answer yet"),
            "answer_source": MCPSchema.enumeration(["book", "agent"], "printed in the document, or worked out by an agent"),
            "explanation": MCPSchema.string("explanation"),
            "region": MCPSchema.array(of: MCPSchema.number("0…1"), "[x, y, w, h] of the question on its page"),
            "has_figure": MCPSchema.boolean("the question relies on a figure or table"),
            "chapter": MCPSchema.array(of: MCPSchema.string("level"), "chapter path in the table of contents, top level first; empty = none"),
            "user_answer": MCPSchema.string("what the user marked in the document (highlight / handwriting), e.g. \"B\""),
            "user_answer_correct": MCPSchema.boolean("whether that marked answer is right (absent when it cannot be judged yet)"),
            "starred": MCPSchema.boolean("starred by the user"),
            "in_mistakes": MCPSchema.boolean("in the user's mistake list"),
            "attempts": MCPSchema.integer("times practiced"),
            "correct": MCPSchema.integer("times answered correctly"),
        ])
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
        let item = MCPSchema.object([
            "page": MCPSchema.integer("Page the question is printed on, 1-based", min: 1),
            "number": MCPSchema.string("Question number exactly as printed (\"5\", \"例 3\"). Strongly recommended: re-importing the same number on the same page updates the question instead of adding a copy."),
            "section": MCPSchema.string("Chapter, exercise set or test name the question belongs to, as printed (optional)."),
            "type": MCPSchema.enumeration(["single", "multiple"], "Single or multiple choice. Omit to infer from the answer (one letter = single)."),
            "stem": MCPSchema.string("The question text, transcribed exactly (no rewording). \(mathWriting)"),
            "options": MCPSchema.array(of: option, "2–8 options in printed order"),
            "answer": MCPSchema.string("Correct option letters, e.g. \"B\" or \"AC\". Omit when the answer is not known yet (fill it in later with update_exercises)."),
            "answer_source": MCPSchema.enumeration(["book", "agent"], "Required with answer: \"book\" when the answer is printed in the document (after the question or in an answer key), \"agent\" when you worked it out yourself."),
            "explanation": MCPSchema.string("Explanation / solution (Markdown + $math$), from the document or your own (optional)."),
            "region": MCPSchema.array(of: MCPSchema.number("0…1"), "[x, y, w, h] box around the whole question on its page, normalized 0–1, top-left origin (as in render_page). Lets the user see the original question."),
            "has_figure": MCPSchema.boolean("True when the question depends on a figure, graph or table the text cannot carry; the original is then shown while practicing.", default: false),
            "chapter": MCPSchema.array(of: MCPSchema.string("level"), "Chapter path, top level first, using the titles in the PDF's table of contents (get_document). Omit it: UniReader looks up the page in the table of contents itself. Give it only when that would be wrong (e.g. exercises collected at the back of the book) or the PDF has no table of contents."),
            "user_answer": MCPSchema.string("The option(s) the user already marked for this question in the document — a highlight on an option (list_annotations) or a circled / written letter (render_page with include_marks) — e.g. \"B\". Saved as the user's earlier attempt and judged; a wrong one goes into the mistake list. Omit when the user has not answered it."),
        ], required: ["page", "stem", "options"])
        return MCPTool(
            name: "import_exercises",
            title: "Import exercises",
            description: """
            Save multiple-choice exercises recognized in a PDF into the workspace so the user can practice them in UniReader \
            (练习 / 错题本 / 收藏 in the UI). Look at the pages first (render_page for the image, read_pages for the text), \
            transcribe each question exactly, then call this with up to \(maxImportExercises) questions in reading order. \
            Each question is checked on its own: bad ones come back with a reason and the rest are saved. Importing the same \
            question again (same page + section + number, or the same text when there is no number) updates it and keeps \
            the user's stars, mistakes and practice history. Only single and multiple choice are supported for now.
            """,
            inputSchema: MCPSchema.object(writeTargetProperties.merging([
                "exercises": MCPSchema.array(of: item, "Questions to save (1–\(maxImportExercises))"),
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
                    userAnswer: try stringField(d, "user_answer", at: path))
                items.append(ExerciseImport.validate(input, seq: i))
            }
            // 章节没给的按页码从 PDF 自带目录里查（`EXERCISE-PLAN.md §2.3`）；文件不在 / 没目录 → 空
            if let path = t.path, items.contains(where: { if case .success(let d) = $0 { d.chapter == nil } else { false } }) {
                let toc = (try? await MCPDocReader.shared.withDocument(path: path) { ExerciseChapterNode.toc(of: $0) }) ?? []
                if !toc.isEmpty {
                    items = items.map { r in
                        guard case .success(var d) = r, let p = d.page else { return r }
                        d.autoChapter = ExerciseChapter.path(page: p, in: toc)
                        return .success(d)
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
                let ans = (e["answer"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "—"
                let src = (e["answer_source"] as? String).map { " (\($0))" } ?? ""
                let stem = Exercise.collapse(e["stem"] as? String ?? "")
                lines.append("- [\((e["id"] as? String ?? "").prefix(8))] p.\(e["page"] ?? "?") #\(e["number"] ?? "") \(e["type"] ?? "") · answer \(ans)\(src) · \(stem.prefix(60))")
            }
            return MCPToolResult(text: lines.joined(separator: "\n"), structured: r)
        }
    }

    static func updateExercisesTool() -> MCPTool {
        let patch = MCPSchema.object([
            "id": MCPSchema.string("Exercise id from list_exercises (full id or its first 8 characters)"),
            "answer": MCPSchema.string("Correct option letters (\"B\", \"AC\"); empty string clears it"),
            "answer_source": MCPSchema.enumeration(["book", "agent"], "Required whenever answer is set: \"book\" if printed in the document, \"agent\" if you worked it out"),
            "explanation": MCPSchema.string("Explanation (Markdown + $math$); empty string clears it"),
            "type": MCPSchema.enumeration(["single", "multiple"], "Question type"),
            "number": MCPSchema.string("Question number as printed"),
            "section": MCPSchema.string("Chapter / test name"),
            "stem": MCPSchema.string("Question text. \(mathWriting)"),
            "options": MCPSchema.array(of: MCPSchema.object([
                "key": MCPSchema.string("A–H"), "text": MCPSchema.string("option text")], required: ["key", "text"]),
                "Replaces all options"),
            "region": MCPSchema.array(of: MCPSchema.number("0…1"), "[x, y, w, h] on the question's page"),
            "has_figure": MCPSchema.boolean("The question depends on a figure or table"),
            "chapter": MCPSchema.array(of: MCPSchema.string("level"), "Chapter path, top level first; [] clears it"),
            "user_answer": MCPSchema.string("The option(s) the user marked in the document (\"B\"); replaces the earlier one; empty string removes it"),
        ], required: ["id"])
        return MCPTool(
            name: "update_exercises",
            title: "Update exercises",
            description: "Change saved exercises by id — most often to fill in answers and explanations after finding the answer key, to set the chapter, or to record the answer the user already marked in the document (user_answer). Only the fields you pass change; the user's stars, mistakes and practice history are kept. When the answer changes, the user's earlier attempts at that question are judged again (a wrong one goes into the mistake list). Every change is checked first; if any one is invalid, nothing is changed.",
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
                    chapter: try chapterArg(d["chapter"], at: path), userAnswer: try stringField(d, "user_answer", at: path))
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
}
