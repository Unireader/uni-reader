// 习题（`EXERCISE-PLAN.md`）回归测试：导入校验 / 规整、去重、库读写、错题本规则、作答统计、
// 删文档级联、回收站归档与恢复、「关联为同一文档」带走习题。运行：
//   cp spike/exercise-test.swift /tmp/main.swift && \
//     swiftc Sources/Store/*.swift Sources/App/Exercise.swift /tmp/main.swift -o /tmp/ex && /tmp/ex
// （须命名为 main.swift 编译：swiftc 多文件时顶层代码只允许在 main.swift）

import Foundation

setvbuf(stdout, nil, _IONBF, 0)
var pass = 0, fail = 0
func check(_ cond: Bool, _ msg: String) {
    if cond { pass += 1; print("  ✅ \(msg)") } else { fail += 1; print("  ❌ \(msg)") }
}

let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ex_test_\(UInt64.random(in: 0..<1_000_000))")
try? FileManager.default.removeItem(at: tmp)
try! FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: tmp) }

let store = try LibraryStore(workspaceFolder: tmp)

func doc(_ title: String, _ hash: String) -> LibDocument {
    try! store.findOrCreate(hash: hash, title: title, pageCount: 20, path: "PDFs/\(hash).pdf", isRelative: false).document
}
func input(_ stem: String?, _ opts: [(String?, String?)] = [("A", "甲"), ("B", "乙"), ("C", "丙"), ("D", "丁")],
           type: String? = nil, answer: String? = nil, src: String? = nil, number: String? = nil,
           section: String? = nil, page: Int? = 0, region: [Double]? = nil, figure: Bool? = nil) -> ExerciseInput {
    ExerciseInput(page: page, type: type, number: number, section: section, stem: stem,
                  options: opts.map { (key: $0.0, text: $0.1) }, answer: answer, answerSource: src,
                  explanation: nil, region: region, figure: figure)
}
func ok(_ i: ExerciseInput, seq: Int = 0) -> ExerciseDraft? {
    if case .success(let d) = ExerciseImport.validate(i, seq: seq) { return d }
    return nil
}
func reason(_ i: ExerciseInput) -> String? {
    if case .failure(let r) = ExerciseImport.validate(i, seq: 0) { return r.reason }
    return nil
}
func row(_ d: ExerciseDraft, doc: String, id: String = UUID().uuidString) -> LibExercise {
    LibExercise(id: id, documentId: doc, page: d.page, seq: d.seq, kind: d.kind.rawValue, number: d.number,
                section: d.section, payload: d.payload.data(), starred: false, wrong: false, source: "test",
                createdAt: .now, updatedAt: .now)
}

print("— 建表")
check(LibraryStore.schemaVersion == 20, "schema 版本 20")
check((try? store.exercises()) != nil, "exercise 表可查")

print("— 校验与规整")
let good = ok(input("设 $f(x)=x^2$，则 $f'(1)=$", answer: "c", src: "book", number: " 5 "))
check(good != nil, "合格单选题通过")
check(good?.kind == .single, "没写题型、答案 1 个 → 单选")
check(good?.payload.answer == ["C"], "答案小写规整成大写")
check(good?.payload.answerSource == "book", "答案来源保留")
check(good?.number == "5", "题号去首尾空白")
check(ok(input("多选", answer: "A, C", src: "agent"))?.kind == .multiple, "没写题型、答案 2 个 → 多选")
check(ok(input("多选", answer: "C、A", src: "agent"))?.payload.answer == ["A", "C"], "「C、A」→ [A, C]（排序）")
check(ok(input("键", [("(a)", "x"), ("B.", "y")]))?.payload.options.map(\.key) == ["A", "B"], "「(a)」「B.」规整成 A / B")
check(reason(input("   ")) == "stem is empty", "空题干退回")
check(reason(input("x", [("A", "1")]))?.contains("at least 2") == true, "只有 1 个选项退回")
check(reason(input("x", (0..<9).map { _ in ("A", "1") }))?.contains("at most 8") == true, "9 个选项退回")
check(reason(input("x", [("A", "1"), ("AB", "2")]))?.contains("invalid key") == true, "选项键不是单字母退回")
check(reason(input("x", [("A", "1"), ("a", "2")]))?.contains("duplicate") == true, "重复选项键退回")
check(reason(input("x", [("A", "1"), ("B", " ")]))?.contains("figure") == true, "选项没文字且没标 figure 退回")
check(ok(input("x", [("A", ""), ("B", "")], figure: true)) != nil, "选项是图（figure）时文字可以空")
check(reason(input("x", answer: "E", src: "book"))?.contains("not one of the options") == true, "答案不在选项里退回")
check(reason(input("x", answer: "1", src: "book"))?.contains("option letters") == true, "答案不是字母退回")
check(reason(input("x", type: "single", answer: "AB", src: "book"))?.contains("exactly one") == true, "单选给两个答案退回")
check(reason(input("x", answer: "A"))?.contains("answer_source") == true, "有答案没写来源退回")
check(reason(input("x", answer: "A", src: "guess"))?.contains("answer_source") == true, "答案来源写错退回")
check(ok(input("x")) != nil && ok(input("x"))?.payload.answer == [], "没有答案也能导入")
check(reason(input("x", type: "judge"))?.contains("type") == true, "不认识的题型退回")
check(reason(input("x", region: [0.1, 0.2, 0, 0.3]))?.contains("region") == true, "region 宽为 0 退回")
check(reason(input("x", region: [0.1, 0.2, 0.3]))?.contains("region") == true, "region 不是 4 个数退回")
check(reason(input("x", region: [0.1, 1.2, 0.3, 0.3]))?.contains("region") == true, "region 越出 0~1 退回")
check(ok(input("x", region: [0.1, 0.2, 0.8, 0.1]))?.payload.region == [0.1, 0.2, 0.8, 0.1], "合格 region 保留")

print("— payload 编解码")
let p = ExercisePayload(stem: "s", options: [ExerciseOption(key: "A", text: "a"), ExerciseOption(key: "B", text: "b")],
                        answer: ["B"], answerSource: "book", explanation: "因为", region: [0, 0, 1, 0.5], figure: true)
check((try? JSONDecoder().decode(ExercisePayload.self, from: p.data())) == p, "编解码回环一致")
let json = String(data: p.data(), encoding: .utf8) ?? ""
check(json.contains("\"answer_source\""), "键是 snake_case")
let old = try! JSONDecoder().decode(ExercisePayload.self, from: Data(#"{"stem":"s","options":[{"key":"A","text":"a"}]}"#.utf8))
check(old.answer == [] && old.figure == false && old.region == nil, "缺键的老 payload 按默认值读出")
check(!String(data: ExercisePayload(stem: "s", options: []).data(), encoding: .utf8)!.contains("figure"),
      "figure=false 不写进 JSON（省字节）")

print("— 判题")
var ex = Exercise(row: row(good!, doc: "x"))!
check(ex.judge(["C"]) == true, "选对 → 对")
check(ex.judge(["A"]) == false, "选错 → 错")
check(ex.judge(["A", "C"]) == false, "多选了 → 错")
ex.payload.answer = ["A", "C"]
check(ex.judge(["A"]) == false, "多选题少选 → 错")
check(ex.judge(["C", "A"]) == true, "多选题全对（顺序无关）→ 对")
ex.payload.answer = []
check(ex.judge(["A"]) == nil, "没有答案 → 没法判（nil）")
check(Exercise.answerString(["C", "A"]) == "AC", "作答串按字母序")
check(Exercise(row: LibExercise(id: "z", documentId: nil, page: nil, seq: 0, kind: 9, number: "", section: "",
                                payload: p.data(), starred: false, wrong: false, source: "", createdAt: .now,
                                updatedAt: .now)) == nil, "不认识的题型（以后的新题型）解码为 nil，跳过")

print("— 库读写与去重")
let d1 = doc("线代习题", "h1")
let a = ok(input("第一题", answer: "A", src: "book", number: "1", section: "第一章"), seq: 0)!
let b = ok(input("第二题", number: "2", section: "第一章"), seq: 1)!
let ra = row(a, doc: d1.id), rb = row(b, doc: d1.id)
try store.upsertExercises([ra, rb])
check(try store.exercises(documentId: d1.id).map(\.id) == [ra.id, rb.id], "按页内先后读回")
check(try store.exercises(documentId: d1.id, page: 0).count == 2, "按页取")
check(try store.exercises(documentId: d1.id, page: nil).isEmpty, "page IS NULL 那一组是空的")
// 同题号同章节再导一次 → 命中
let again = ok(input("第二题（改）", answer: "B", src: "book", number: "2", section: "第一章"), seq: 1)!
check(ExerciseImport.match(again, in: try store.exercises(documentId: d1.id, page: 0))?.id == rb.id, "题号 + 章节相同 → 认作同一道")
let other = ok(input("第二题", number: "2", section: "第二章"))!
check(ExerciseImport.match(other, in: try store.exercises(documentId: d1.id, page: 0)) == nil, "章节不同的同号题不算同一道")
// 没题号：按规整后的题干认
let n1 = ok(input("无题号 的 题"))!
let rn = row(n1, doc: d1.id)
try store.upsertExercise(rn)
check(ExerciseImport.match(ok(input("无题号的题"))!, in: try store.exercises(documentId: d1.id, page: 0))?.id == rn.id,
      "没题号 → 题干去空白后相同即同一道")
check(ExerciseImport.match(ok(input("无题号的另一题"))!, in: try store.exercises(documentId: d1.id, page: 0)) == nil,
      "题干不同不算")

print("— 收藏 / 错题本不被重导冲掉")
try store.setExerciseStarred(id: rb.id, true)
try store.setExerciseWrong(id: rb.id, true)
var rb2 = row(again, doc: d1.id, id: rb.id)
rb2.starred = false; rb2.wrong = false        // 重导时带的是默认值
try store.upsertExercise(rb2)
let back = try store.exercise(id: rb.id)!
check(back.starred && back.wrong, "upsert 只覆盖内容列，收藏与错题本保持")
check(Exercise(row: back)?.payload.stem == "第二题（改）", "内容确实更新了")

print("— 错题本规则（答错进，只能手动出）")
try store.setExerciseWrong(id: ra.id, false)
try store.recordExerciseAttempt(LibExerciseAttempt(id: UUID().uuidString, exerciseId: ra.id, answer: "A",
                                                   correct: true, elapsedMs: 1200, createdAt: .now))
check(try store.exercise(id: ra.id)?.wrong == false, "答对不进错题本")
try store.recordExerciseAttempt(LibExerciseAttempt(id: UUID().uuidString, exerciseId: ra.id, answer: "B",
                                                   correct: false, elapsedMs: 800,
                                                   createdAt: Date(timeIntervalSinceNow: 1)))
check(try store.exercise(id: ra.id)?.wrong == true, "答错 → 进错题本")
try store.recordExerciseAttempt(LibExerciseAttempt(id: UUID().uuidString, exerciseId: ra.id, answer: "A",
                                                   correct: true, elapsedMs: 500,
                                                   createdAt: Date(timeIntervalSinceNow: 2)))
check(try store.exercise(id: ra.id)?.wrong == true, "之后答对也不自动出")
try store.recordExerciseAttempt(LibExerciseAttempt(id: UUID().uuidString, exerciseId: rn.id, answer: "C",
                                                   correct: nil, elapsedMs: 0, createdAt: .now))
check(try store.exercise(id: rn.id)?.wrong == false, "没答案的题（correct=nil）不进错题本")
try store.setExerciseWrong(id: ra.id, false)
check(try store.exercise(id: ra.id)?.wrong == false, "手动移出")
let attempts = try store.exerciseAttempts(exerciseId: ra.id)
check(attempts.count == 3 && attempts.map(\.answer) == ["A", "B", "A"], "作答记录按时间读回")
check(attempts[1].correct == false && attempts[1].elapsedMs == 800, "作答的对错与用时存对")
check(try store.exerciseAttempts(exerciseId: rn.id).first?.correct == nil, "correct=nil 存成 NULL 读回 nil")

print("— 统计")
let st = try store.exerciseAttemptStats()
let sa = st[ra.id]
check(sa?.attempts == 3 && sa?.correct == 2 && sa?.wrong == 1 && sa?.lastCorrect == true, "做过的题：次数 / 对 / 错 / 最近一次")
check(sa?.lastAnswer == "A" && sa?.lastAt != nil && sa?.markedAnswer == nil, "最近一次在 App 里的作答：选了什么、什么时候")
check(st[rn.id]?.attempts == 1 && st[rn.id]?.lastCorrect == nil, "最近一次没法判 → lastCorrect nil")
check(st[rb.id] == nil, "没做过的题不在统计里")
let c = try store.exerciseCounts()
check(c.total == 3 && c.wrong == 1 && c.starred == 1 && c.byDocument[d1.id] == 3, "侧栏的数：总 3 / 错 1 / 藏 1 / 本篇 3")

print("— 标签范围")
check(ExerciseScope(key: "all") == .all && ExerciseScope(key: "wrong") == .wrong, "范围键回环")
check(ExerciseScope(rowID: ExerciseScope.document("ABC").rowID) == .document("ABC"), "文档范围 rowID 回环")
check(ExerciseScope(key: "doc:") == nil && ExerciseScope(key: "x") == nil, "坏键 → nil")
check(ExerciseScope.wrong.includes(Exercise(row: try store.exercise(id: rb.id)!)!), "错题本范围含错题")
check(!ExerciseScope.starred.includes(Exercise(row: try store.exercise(id: ra.id)!)!), "收藏范围不含没收藏的")

print("— 回收站：删几道题")
let snap1 = tmp.appendingPathComponent("trash1.sqlite").path
let arc = try store.archiveExercises(ids: [ra.id, rb.id], to: snap1)
check(arc.counts.exercise == 2 && arc.counts.total == 2, "归档数到 2 道")
try store.deleteExercises(ids: [ra.id, rb.id])
check(try store.exercises(documentId: d1.id).count == 1, "删掉 2 道，剩 1 道")
check(try store.exerciseAttempts(exerciseId: ra.id).isEmpty, "作答记录随题级联删掉")
let n = try store.restoreTrash(snapshot: snap1, remapDocumentId: nil)
check(n == 5, "恢复 5 行（2 道题 + 3 次作答），实际 \(n)")
check(try store.exerciseAttempts(exerciseId: ra.id).count == 3, "作答记录一起回来")
check(try store.exercise(id: rb.id)?.starred == true, "收藏状态一起回来")
_ = try store.restoreTrash(snapshot: snap1, remapDocumentId: nil)
check(try store.exercises(documentId: d1.id).count == 3 && (try store.exerciseAttempts(exerciseId: ra.id).count) == 3,
      "重复恢复幂等（OR IGNORE 不把作答记录冲掉）")

print("— 回收站：删整篇文档")
let snap2 = tmp.appendingPathComponent("trash2.sqlite").path
let arc2 = try store.archiveDocument(id: d1.id, to: snap2)
check(arc2.counts.exercise == 3, "文档快照里带着 3 道题")
try store.deleteDocument(id: d1.id)
check(try store.exercises().isEmpty, "删文档 → 题级联删掉")
check(try store.exerciseAttemptStats().isEmpty, "作答记录也没了")
_ = try store.restoreTrash(snapshot: snap2, remapDocumentId: nil)
check(try store.exercises(documentId: d1.id).count == 3, "恢复文档 → 题回来")
check(try store.exerciseAttemptStats()[ra.id]?.attempts == 3, "作答记录回来")
// 重新导入过 → 并入现有那篇
let snap3 = tmp.appendingPathComponent("trash3.sqlite").path
_ = try store.archiveDocument(id: d1.id, to: snap3)
try store.deleteDocument(id: d1.id)
let d1b = doc("线代习题（重导）", "h1")
check(try store.trashMergeTarget(snapshot: snap3) == d1b.id, "认出同一份 PDF 已重新导入")
_ = try store.restoreTrash(snapshot: snap3, remapDocumentId: d1b.id)
check(try store.exercises(documentId: d1b.id).count == 3, "题并入现有那篇（document_id 改写）")

print("— 关联为同一文档")
let d2 = doc("另一版", "h2")
let r2 = row(ok(input("第二版里的题"))!, doc: d2.id)
try store.upsertExercise(r2)
check(try store.mergeDocument(sourceId: d2.id, intoTargetId: d1b.id), "合并成功")
check(try store.exercise(id: r2.id)?.documentId == d1b.id, "题跟着挪到目标文档（没被级联删掉）")

// MARK: - 2026-10-11：章节 / 书上的作答 / 重判 / 筛选

print("— 章节：目录查页")
let toc = [
    ExerciseChapterNode(label: "前言", page: 0),
    ExerciseChapterNode(label: " 第一章 函数 ", page: 2, children: [
        ExerciseChapterNode(label: "1.1 映射", page: 3),
        ExerciseChapterNode(label: "1.2 极限", page: 8),
    ]),
    ExerciseChapterNode(label: "第二章 导数", page: nil, children: [   // 自己没落点：按第一个子项算
        ExerciseChapterNode(label: "2.1 定义", page: 15),
        ExerciseChapterNode(label: "2.2 法则", page: 20, children: [ExerciseChapterNode(label: "习题 2.2", page: 24)]),
    ]),
]
check(ExerciseChapter.path(page: 1, in: toc) == ["前言"], "第 2 页在「前言」")
check(ExerciseChapter.path(page: 2, in: toc) == ["第一章 函数"], "章开头、第一小节之前 → 停在章这一级（标题去空白）")
check(ExerciseChapter.path(page: 9, in: toc) == ["第一章 函数", "1.2 极限"], "落在 1.2")
check(ExerciseChapter.path(page: 16, in: toc) == ["第二章 导数", "2.1 定义"], "没落点的章按第一个子项起算")
check(ExerciseChapter.path(page: 30, in: toc) == ["第二章 导数", "2.2 法则", "习题 2.2"], "一直走到最深一级")
check(ExerciseChapter.path(page: 5, in: []) == [], "没目录 → 空")
check(ExerciseChapter.flatten(toc).count == 8 && ExerciseChapter.flatten(toc)[2] == ["第一章 函数", "1.1 映射"],
      "目录摊平：每项是完整路径、先序")
check(ExerciseChapter.clean([" a ", "", "  "]) == ["a"], "路径规整：去空白、丢空段")
check(LibraryStore.chapterPath(LibraryStore.chapterText(["第二章 导数", "2.3 \"引号\""])) == ["第二章 导数", "2.3 \"引号\""],
      "章节列 JSON 回环（含引号）")
check(LibraryStore.chapterText([]) == "" && LibraryStore.chapterPath("") == [], "空路径存空串")

print("— 章节：库读写 / 范围 / 树")
let d3 = doc("高数", "h3")
var c1 = row(ok(input("c1", number: "1"), seq: 0)!, doc: d3.id); c1.chapter = ["第一章 函数", "1.1 映射"]
var c2 = row(ok(input("c2", number: "2"), seq: 1)!, doc: d3.id); c2.chapter = ["第一章 函数", "1.2 极限"]; c2.page = 8
var c3 = row(ok(input("c3", number: "3"), seq: 2)!, doc: d3.id); c3.chapter = ["第一章 函数"]
var c4 = row(ok(input("c4", number: "4"), seq: 3)!, doc: d3.id); c4.page = 40
try store.upsertExercises([c1, c2, c3, c4])
check(try store.exercise(id: c1.id)?.chapter == ["第一章 函数", "1.1 映射"], "章节读回")
let cc = try store.exerciseChapterCounts().filter { $0.documentId == d3.id }
check(cc.count == 4 && cc.first { $0.chapter.isEmpty }?.count == 1, "按章节分组计数（含未分章节）")
check(cc.first { $0.chapter == ["第一章 函数", "1.2 极限"] }?.firstPage == 8, "每组带最早页码")
var stats3: [[String]: ExerciseChapterStat] = [:]
for r in cc { stats3[r.chapter] = ExerciseChapterStat(count: r.count, firstPage: r.firstPage) }
let sum3 = ExerciseSummary(total: 4, byDocument: [d3.id: 4], chapters: [d3.id: stats3])
check(sum3.count(.chapter(d3.id, ["第一章 函数"])) == 3, "章的数 = 它自己 + 各小节")
check(sum3.count(.chapter(d3.id, [])) == 1, "空路径范围只数没设章节的")
let tree = ExerciseChapterTree.build(stats3)
check(tree.count == 1 && tree[0].count == 3 && tree[0].children.map(\.label) == ["1.1 映射", "1.2 极限"],
      "建树：一级「第一章」3 道，下面两个小节按页排")
let e1 = Exercise(row: try store.exercise(id: c1.id)!)!, e3 = Exercise(row: try store.exercise(id: c3.id)!)!
let e4 = Exercise(row: try store.exercise(id: c4.id)!)!
check(ExerciseScope.chapter(d3.id, ["第一章 函数"]).includes(e1), "章范围含其下小节的题")
check(!ExerciseScope.chapter(d3.id, ["第一章 函数", "1.2 极限"]).includes(e1), "小节范围不含兄弟小节")
check(ExerciseScope.chapter(d3.id, []).includes(e4) && !ExerciseScope.chapter(d3.id, []).includes(e3), "未分章节范围")
check(!ExerciseScope.chapter("other", ["第一章 函数"]).includes(e1), "别的书的同名章不算")
let sc = ExerciseScope.chapter(d3.id, ["第一章 函数", "1.1: 冒号"])
check(ExerciseScope(rowID: sc.rowID) == sc, "章节范围键回环（名字里有冒号也行）")
check(ExerciseScope(rowID: ExerciseScope.chapter(d3.id, []).rowID) == .chapter(d3.id, []), "未分章节范围键回环")
try store.setExerciseChapter(ids: [c4.id], ["第三章"])
check(try store.exercise(id: c4.id)?.chapter == ["第三章"], "手动设章节")

print("— 错题本按书 / 按章展开")
try store.setExerciseWrong(id: c1.id, true)
try store.setExerciseWrong(id: c4.id, true)
let cw = try store.exerciseChapterCounts().filter { $0.documentId == d3.id }
check(cw.first { $0.chapter == ["第一章 函数", "1.1 映射"] }?.wrong == 1 && cw.first { $0.chapter == ["第一章 函数", "1.2 极限"] }?.wrong == 0,
      "章节计数带错题数")
var statsW: [[String]: ExerciseChapterStat] = [:]
for r in cw { statsW[r.chapter] = ExerciseChapterStat(count: r.count, firstPage: r.firstPage, wrong: r.wrong) }
let sumW = ExerciseSummary(total: 4, wrong: 2, byDocument: [d3.id: 4], chapters: [d3.id: statsW])
check(sumW.count(.wrongDocument(d3.id)) == 2, "一本书的错题数")
check(sumW.count(.wrongChapter(d3.id, ["第一章 函数"])) == 1 && sumW.count(.chapter(d3.id, ["第一章 函数"])) == 3,
      "一章的错题数（含小节），全部题数不受影响")
let mc = sumW.mistakeChapters(d3.id)
check(Set(mc.keys) == [["第一章 函数", "1.1 映射"], ["第三章"]] && mc.values.allSatisfy { $0.count == 1 },
      "错题本的章节分布：只留有错题的章节，数是错题数")
let wtree = ExerciseChapterTree.build(mc)
check(wtree.map(\.label) == ["第一章 函数", "第三章"] && wtree[0].count == 1 && wtree[0].children.map(\.label) == ["1.1 映射"],
      "错题本底下的章节树（按页排）")
let ew1 = Exercise(row: try store.exercise(id: c1.id)!)!, ew2 = Exercise(row: try store.exercise(id: c2.id)!)!
check(ExerciseScope.wrongChapter(d3.id, ["第一章 函数"]).includes(ew1) && !ExerciseScope.wrongChapter(d3.id, ["第一章 函数"]).includes(ew2),
      "错题本按章：只含这一章里在错题本的")
check(ExerciseScope.wrongDocument(d3.id).includes(ew1) && !ExerciseScope.wrongDocument("other").includes(ew1), "错题本按书")
for sc in [ExerciseScope.wrongDocument(d3.id), .wrongChapter(d3.id, ["第一章 函数", "1.1: 冒号"]), .wrongChapter(d3.id, [])] {
    check(ExerciseScope(rowID: sc.rowID) == sc, "错题范围键回环：\(sc.key)")
}
check(ExerciseScope(key: "wrong:all") == nil && ExerciseScope(key: "wrong:wrong") == nil && ExerciseScope(key: "wrong") == .wrong,
      "错题前缀只接书 / 章，「wrong」本身仍是错题本")
check(ExerciseScope.wrong.isMistakes && ExerciseScope.wrongChapter(d3.id, []).isMistakes && !ExerciseScope.chapter(d3.id, []).isMistakes
      && !ExerciseScope.all.isMistakes, "错题那一支（公用错题标签管的）")
check(ExerciseScope.wrongChapter(d3.id, ["x"]).documentId == d3.id, "错题范围也认得是哪本书（删书时标签跟着退）")

print("— 侧栏 / 平板抽屉的分组（ExerciseGroupNode，安卓模式1 逐条照抄）")
let gdocs: [(id: String, title: String)] = [("nodoc", "没题的书"), (d3.id, "书三")]
let groups = ExerciseGroupNode.build(sumW, documents: gdocs, title: { $0.key }, noChapter: "未分章节")
check(groups.map(\.scope) == [.all, .wrong, .starred, .document(d3.id)], "全部 / 错题本 / 收藏恒在，之后只列有题的书")
check(groups.map(\.count) == [4, 2, 0, 4] && groups[0].title == "all" && groups[3].title == "书三", "各行的数与名字")
check(groups[1].children.map(\.scope) == [.wrongDocument(d3.id)]
      && groups[1].children[0].children.map(\.title) == wtree.map(\.label), "错题本底下：有错题的书 → 错题章节树")
check(groups[1].children[0].children[0].children.map(\.scope) == [.wrongChapter(d3.id, ["第一章 函数", "1.1 映射"])],
      "错题本底下的章节是错题范围")
let gnone = statsW[[]].map { $0.count > 0 } ?? false
check(groups[3].children.map(\.title) == ExerciseChapterTree.build(statsW).map(\.label) + (gnone ? ["未分章节"] : []),
      "书底下的章节树（有没设章节的题时末尾一行「未分章节」）")
let flat = ExerciseGroupNode.flatten(groups)
func countNodes(_ ns: [ExerciseGroupNode]) -> Int { ns.reduce(0) { $0 + 1 + countNodes($1.children) } }
check(flat.count == countNodes(groups) && flat[0].depth == 0 && flat[1].scope == .wrong && flat[2].depth == 1
      && flat[2].scope == .wrongDocument(d3.id) && flat[3].depth == 2, "摊平：先父后子、depth 是缩进层级")
check(ExerciseGroupNode.build(ExerciseSummary(), documents: gdocs, title: { $0.key }, noChapter: "x").isEmpty,
      "没有题 → 整段不出现")

print("— 书上的作答（source = mark）")
let m = ok(input("m", answer: "B", src: "book", number: "9"))!
let rm = row(m, doc: d3.id)
try store.upsertExercise(rm)
func mark(_ id: String, _ ans: String, _ c: Bool?) -> LibExerciseAttempt {
    LibExerciseAttempt(id: UUID().uuidString, exerciseId: id, answer: ans, correct: c, elapsedMs: 0, createdAt: .now,
                       source: LibExerciseAttempt.markSource)
}
try store.recordMarkedAttempts([mark(rm.id, "C", false)])
check(try store.exercise(id: rm.id)?.wrong == true, "书上答错 → 进错题本")
try store.recordMarkedAttempts([mark(rm.id, "B", true)])
let ma = try store.exerciseAttempts(exerciseId: rm.id)
check(ma.count == 1 && ma[0].answer == "B" && ma[0].source == "mark", "每道题书上的作答只留一条（重写替换）")
check(try store.exercise(id: rm.id)?.wrong == true, "书上改成对的也不自动出错题本")
try store.recordExerciseAttempt(LibExerciseAttempt(id: UUID().uuidString, exerciseId: rm.id, answer: "A", correct: false,
                                                   elapsedMs: 100, createdAt: .now))
let ms = try store.exerciseAttemptStats()[rm.id]
check(ms?.attempts == 2 && ms?.markedAnswer == "B" && ms?.markedCorrect == true, "统计：总次数含书上那条，单独给出书上的作答")
check(ms?.lastAnswer == "A", "最近一次只算 App 里练的")
var laterMark = mark(rm.id, "D", false); laterMark.createdAt = Date(timeIntervalSinceNow: 5)
try store.recordMarkedAttempts([laterMark])
check(try store.exerciseAttemptStats()[rm.id]?.lastAnswer == "A", "书上的作答后来重导，也不盖过 App 里的练习")
try store.deleteMarkedAttempt(exerciseId: rm.id)
check(try store.exerciseAttempts(exerciseId: rm.id).map(\.source) == [""], "撤掉书上的作答，App 里的练习记录不动")

print("— 答案后补：重判")
let q = ok(input("q", number: "10"))!          // 先没有答案
let rq = row(q, doc: d3.id)
try store.upsertExercise(rq)
try store.recordMarkedAttempts([mark(rq.id, "A", nil)])
try store.recordExerciseAttempt(LibExerciseAttempt(id: UUID().uuidString, exerciseId: rq.id, answer: "C", correct: nil,
                                                   elapsedMs: 0, createdAt: Date(timeIntervalSinceNow: 1)))
check(try store.exercise(id: rq.id)?.wrong == false, "没答案时作答都没法判，不进错题本")
var withAns = Exercise(row: try store.exercise(id: rq.id)!)!
withAns.payload.answer = ["C"]
let changed = try store.rejudgeExerciseAttempts(exerciseId: rq.id) { withAns.judge(Set($0.map { String($0) })) }
let rj = try store.exerciseAttempts(exerciseId: rq.id)
check(changed == 2 && rj.first { $0.answer == "A" }?.correct == false && rj.first { $0.answer == "C" }?.correct == true,
      "补上答案 C：书上的 A 判错、练习的 C 判对")
check(try store.exercise(id: rq.id)?.wrong == true, "重判出错 → 进错题本")
withAns.payload.answer = ["A"]
_ = try store.rejudgeExerciseAttempts(exerciseId: rq.id) { withAns.judge(Set($0.map { String($0) })) }
check(try store.exercise(id: rq.id)?.wrong == true, "答案改成 A 后 A 变对，错题本不自动出（只能手动）")
check(try store.rejudgeExerciseAttempts(exerciseId: rq.id) { withAns.judge(Set($0.map { String($0) })) } == 0,
      "答案没变再重判：一条不改")

print("— 校验：user_answer / chapter")
check(ok(input("u", answer: "B", src: "book")).map { $0.userAnswer } == .some(nil), "没给 user_answer → nil")
var ui = input("u"); ui.userAnswer = "c, a"
check(ok(ui)?.userAnswer == ["A", "C"], "user_answer 规整排序")
ui.userAnswer = " "
check(ok(ui)?.userAnswer == [], "user_answer 空串 = 撤掉")
ui.userAnswer = "E"
check(reason(ui)?.contains("user_answer key E") == true, "user_answer 不在选项里退回")
var ci = input("c"); ci.chapter = [" 第一章 ", ""]
check(ok(ci)?.chapter == ["第一章"], "chapter 规整")
check(ok(input("c"))?.chapter == nil, "没给 chapter → nil（让 App 按目录自动定）")

print("— 筛选")
let fe = Exercise(row: try store.exercise(id: rq.id)!)!
check(ExerciseFilter.unanswered.includes(fe, attempts: 0) && !ExerciseFilter.unanswered.includes(fe, attempts: 1), "没做过")
check(ExerciseFilter.wrong.includes(fe, attempts: 2) && !ExerciseFilter.starred.includes(fe, attempts: 2), "错题 / 收藏")

print("— 做过的题显示以前的作答")
var pe = Exercise(row: try store.exercise(id: rm.id)!)!      // 答案 B
let peStats = try store.exerciseAttemptStats()[rm.id]
let pa = pe.earlierAnswer(peStats)
check(pa?.chosen == ["A"] && pa?.correct == false, "App 里练过：显示最近一次（A，错）")
if case .practiced(let at)? = pa?.from { check(at != nil, "带那次的时间") } else { check(false, "来源应是 App 里练的") }
let bookOnly = ExerciseAttemptStats(attempts: 1, markedAnswer: "B", markedCorrect: true)
check(pe.earlierAnswer(bookOnly).map { $0.chosen == ["B"] && $0.correct == true && $0.from == .book } == true,
      "App 里没练过：拿书上的作答")
check(pe.earlierAnswer(nil) == nil, "没做过 → nil（等着作答）")
check(pe.earlierAnswer(ExerciseAttemptStats(attempts: 1, markedAnswer: "?", lastAnswer: "")) == nil, "作答串认不出 → 当没做过")
pe.payload.answer = ["A"]
check(pe.earlierAnswer(peStats)?.correct == true, "答案后来改了：按现在的答案判")
pe.payload.answer = []
check(pe.earlierAnswer(peStats).map { $0.correct == nil } == true, "题目没答案：显示作答、不判对错")
check(pe.earlierAnswer(ExerciseAttemptStats(attempts: 1, lastAnswer: "AC"))?.chosen == ["A", "C"], "多选的作答串拆回几个键")

print("— 补列迁移（开发包里已建过 v20 表的库）")
let oldWS = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ex_old_\(UInt64.random(in: 0..<1_000_000))")
try! FileManager.default.createDirectory(at: oldWS.appendingPathComponent("UniReader"), withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: oldWS) }
do {
    let raw = try SQLiteDB(path: oldWS.appendingPathComponent("UniReader/library.sqlite").path)
    try raw.exec("""
    CREATE TABLE exercise (id TEXT PRIMARY KEY, document_id TEXT, page INTEGER, seq INTEGER NOT NULL DEFAULT 0,
      kind INTEGER NOT NULL DEFAULT 0, number TEXT NOT NULL DEFAULT '', section TEXT NOT NULL DEFAULT '',
      payload BLOB NOT NULL, starred INTEGER NOT NULL DEFAULT 0, wrong INTEGER NOT NULL DEFAULT 0,
      source TEXT NOT NULL DEFAULT '', created_at TEXT NOT NULL, updated_at TEXT NOT NULL);
    CREATE TABLE exercise_attempt (id TEXT PRIMARY KEY, exercise_id TEXT NOT NULL, answer TEXT NOT NULL,
      correct INTEGER, elapsed_ms INTEGER NOT NULL DEFAULT 0, created_at TEXT NOT NULL);
    """)
    raw.close()
}
let oldStore = try LibraryStore(workspaceFolder: oldWS)
let od = try! oldStore.findOrCreate(hash: "o1", title: "旧", pageCount: 5, path: "PDFs/o1.pdf", isRelative: false).document
var orow = row(ok(input("o"))!, doc: od.id); orow.chapter = ["补列后"]
try oldStore.upsertExercise(orow)
check(try oldStore.exercise(id: orow.id)?.chapter == ["补列后"], "exercise.chapter 补上了、能写能读")
try oldStore.recordMarkedAttempts([mark(orow.id, "A", nil)])
check(try oldStore.exerciseAttempts(exerciseId: orow.id).first?.source == "mark", "exercise_attempt.source 补上了")
oldStore.close()

print("\n\(pass) 通过，\(fail) 失败")
exit(fail == 0 ? 0 : 1)
